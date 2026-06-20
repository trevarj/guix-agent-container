#!/usr/bin/env bash
# Launch an LLM coding agent (claude / codex) in an isolated Guix container.
#
#   - networking on (--network: outbound HTTPS + DNS, auto-carries resolv.conf)
#   - $HOME read-only (agent reads ~/.gitconfig etc.; cannot trash home)
#   - ~/.claude and ~/.codex read-write (agents must persist their own state)
#   - ~/.gnupg/private-keys-v1.d masked (private keys never enter the container)
#   - ~/Workspace read-write (agent edits projects)
#   - --nesting so per-project manifest.scm / direnv use guix work inside
#   - signed commits via the host gpg-agent socket (--share S.gpg-agent)
#
# Usage:  run.sh claude | codex | bash
# Sign commits?  Run `/home/trev/.codex/bin/codex-gpg-unlock` on the host first.
set -euo pipefail

HOME_RO="${HOME:?}"
SBX="$HOME_RO/Workspace/guix-agent-container"
WORKSPACE_RW="$HOME_RO/Workspace"
AGENT_SOCK="/run/user/$(id -u)/gnupg/S.gpg-agent"

# The empty dir used to mask ~/.gnupg/private-keys-v1.d must exist as a
# bind-mount source; create it if missing (keeps the repo self-contained).
mkdir -p "$SBX/empty"

EXTRA=()
# Optional SSH agent for git push over SSH (only if the host exposes one).
[ -n "${SSH_AUTH_SOCK:-}" ] && [ -e "${SSH_AUTH_SOCK}" ] \
  && EXTRA+=(--share="${SSH_AUTH_SOCK}")

# Entrypoint runs INSIDE the container: build a `gpg` shim that adds the
# RO-homedir-safe flags (--lock-never / --no-random-seed-file /
# --no-permission-warning), prepend it to PATH, then exec the agent. git
# resolves gpg.program (default `gpg`) via PATH and transparently picks up
# the shim; host ~/.gitconfig (RO) already sets commit.gpgsign + signingkey.
entrypoint=$(cat <<'EOSH'
set -euo pipefail
uid=$(id -u)
export XDG_RUNTIME_DIR="/run/user/$uid"

# Prevent the host Guix-home "on-first-login" (sourced by login shells via
# ~/.profile) from starting shepherd inside the container. on-first-login only
# launches shepherd if it can O_CREAT|O_EXCL $XDG_RUNTIME_DIR/on-first-login-
# executed; pre-creating that flag makes the claim fail, so shepherd never
# starts (it would otherwise crash chmod-ing ~/.local/state on the RO home).
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
: > "$XDG_RUNTIME_DIR/on-first-login-executed" 2>/dev/null || true
# gnupg rejects a socket dir that is not mode 700; Guix creates
# /run/user/<uid>/gnupg as 755 when bind-mounting the agent socket, which makes
# gpg fall back to a homedir socket (~/.gnupg/S.gpg-agent) and miss our
# bind-mounted host socket. Fix the mode so gpgconf reports the /run path.
chmod 700 "$XDG_RUNTIME_DIR/gnupg" 2>/dev/null || true

# gpg shim: sign via the host gpg-agent without writing to the RO ~/.gnupg.
real_gpg="$(command -v gpg)"          # resolve BEFORE prepending the shim dir
mkdir -p /tmp/gnupg-bin
cat > /tmp/gnupg-bin/gpg <<EOF
#!/bin/sh
exec "$real_gpg" --lock-never --no-random-seed-file --no-permission-warning "\$@"
EOF
chmod +x /tmp/gnupg-bin/gpg
export PATH="/tmp/gnupg-bin:$PATH"
exec "$@"
EOSH
)

exec guix shell --container \
  --network \
  --nesting \
  --manifest="$SBX/manifest.scm" \
  --expose="$HOME_RO" \
  --expose="$SBX/empty=$HOME_RO/.gnupg/private-keys-v1.d" \
  --share="$HOME_RO/.claude" \
  --share="$HOME_RO/.codex" \
  --share="$WORKSPACE_RW" \
  --share="$AGENT_SOCK" \
  "${EXTRA[@]}" \
  --cwd="$WORKSPACE_RW" \
  -- bash -c "$entrypoint" _ "$@"