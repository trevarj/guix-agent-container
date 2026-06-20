#!/usr/bin/env bash
# Launch an LLM coding agent (claude / codex) in an isolated Guix container.
#
# Security posture (see PLAN.md for the full rationale + verification):
#   - networking on (--network: outbound HTTPS + DNS, auto-carries resolv.conf)
#   - $HOME read-only (agent reads ~/.gitconfig etc.; cannot trash home)
#   - ~/Workspace read-write (agent edits projects)
#   - secret dirs under $HOME masked (read-only empty dir shadowed over them):
#       ~/.ssh (then known_hosts + config re-exposed RO so `ssh` push works via
#       the SSH agent), ~/.gnupg/private-keys-v1.d, ~/.password-store, ~/.aws,
#       ~/.local/share/keyring, ~/.config/BraveSoftware, ~/.config/chromium,
#       ~/.config/github-copilot, ~/.lnd, ~/wireguard
#   - agent config read-only, agent state read-write:
#       ~/Workspace/dotfiles exposed RO (all symlinked ~/.claude/~/.codex config
#       lives there: settings.json, CLAUDE.md, AGENTS.md, agents, skills, bin,
#       rules); ~/.claude and ~/.codex exposed RO with only their state
#       subdirs/files shared RW.
#   - signed commits via a HOST-SIDE commit-only signing oracle: the container
#     never sees the gpg-agent socket. A `gpg` shim routes git's detach-sign to
#     the oracle, which signs ONLY verified git commit/tag objects with the
#     configured key; decrypt/clearsign/encrypt/gen-key/etc. are refused.
#   - `guix` surface filtered to shell/search/show/describe/edit (no
#     build/gc/archive/copy/time-machine/pull/...).
#   - --nesting so per-project manifest.scm / direnv use guix work inside.
#
# Usage:  run.sh claude | codex | bash [args...]
# Sign commits?  Run `/home/trev/.codex/bin/codex-gpg-unlock` on the host first so
# the host gpg-agent has the signing key cached (never type passphrases in chat).
set -euo pipefail

HOME_RO="${HOME:?}"
SBX="$HOME_RO/Workspace/guix-agent-container"
WORKSPACE_RW="$HOME_RO/Workspace"
SIGN_KEY="${GAC_SIGN_KEY:-A52D68794EBED758}"
MASK_DIR="$SBX/empty"

mkdir -p "$MASK_DIR"

# --- Stage the RO shims on the HOST (outside any container-shared path) -------
# Copying to a host temp dir the container only ever sees via a RO bind mount
# means the agent cannot tamper with the shim it executes (the RW source under
# ~/Workspace is not the inode the RO bind serves once staged + bound).
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/gac-stage.XXXXXX")"
# Keep the oracle socket in a private temp dir. Some managed shells expose
# /run/user/<uid> read-only, while this exact socket is bind-shared below.
SIGN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gac-sign.XXXXXX")"
SIGN_SOCK="$SIGN_DIR/sign.sock"
cp "$SBX/bin/gpg-shim.py"    "$STAGE/gpg-shim.py"
cp "$SBX/bin/guix-filter.py" "$STAGE/guix-filter.py"
chmod 0755 "$STAGE/gpg-shim.py" "$STAGE/guix-filter.py"

# Stage a safe ~/.ssh: known_hosts + config + public keys + authorized_keys only
# (no private key material). Exposed RO over the real ~/.ssh so `git push` over
# SSH (via the SSH agent) still resolves hosts / applies config aliases without
# ever exposing id_ed25519 / id_rsa / wgkey / etc.
if [ -d "$HOME_RO/.ssh" ]; then
  mkdir -p "$STAGE/ssh"
  cp -p "$HOME_RO/.ssh/known_hosts" "$STAGE/ssh/" 2>/dev/null || true
  cp -p "$HOME_RO/.ssh/config"      "$STAGE/ssh/" 2>/dev/null || true
  cp -p "$HOME_RO/.ssh/"*.pub       "$STAGE/ssh/" 2>/dev/null || true
  cp -p "$HOME_RO/.ssh/authorized_keys" "$STAGE/ssh/" 2>/dev/null || true
  chmod 0700 "$STAGE/ssh"
fi

# --- Start the host signing oracle --------------------------------------------
# Runs on the host (has the gpg-agent); the container connects to $SIGN_SOCK.
guix shell python gnupg -- python3 "$SBX/bin/sign-server.py" "$SIGN_SOCK" "$SIGN_KEY" \
  >/tmp/gac-sign-server.log 2>&1 &
SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true   # server unlinks the socket on exit
  rm -rf "$STAGE" "$SIGN_DIR"
}
trap cleanup EXIT INT TERM

# Wait for the oracle socket to appear (fail hard if it doesn't — L1).
for _ in $(seq 1 100); do [ -S "$SIGN_SOCK" ] && break; sleep 0.1; done
[ -S "$SIGN_SOCK" ] || { echo "run.sh: signing oracle did not start; see /tmp/gac-sign-server.log" >&2; exit 1; }

# Pass the oracle endpoint + key to the container env (guix shell preserves env
# without --pure, so the shim picks these up).
export GAC_SIGN_SOCK="$SIGN_SOCK" GAC_SIGN_KEY="$SIGN_KEY"

# --- Build the mount table ----------------------------------------------------
args=(
  --container --network --nesting
  --preserve=GAC_SIGN_SOCK --preserve=GAC_SIGN_KEY     # oracle endpoint -> container env
  --preserve=TERM --preserve=COLORTERM --preserve=TERM_PROGRAM  # carry host terminal (color + TUI)
  --manifest="$SBX/manifest.scm"
  --expose="$HOME_RO"                                  # $HOME RO (base)
  --expose="$STAGE=/opt/gac"                           # RO shim sources (gpg-shim, guix-filter)
)

# Mask secret DIRS under RO $HOME with an empty dir (conditional on existence).
# .ssh is handled separately below via the staged safe-.ssh bind.
for p in \
  ".gnupg/private-keys-v1.d" ".password-store" ".aws" \
  ".local/share/keyring" ".config/BraveSoftware" ".config/chromium" \
  ".config/github-copilot" ".lnd" "wireguard"; do
  [ -d "$HOME_RO/$p" ] && args+=(--expose="$MASK_DIR=$HOME_RO/$p")
done

# Safe ~/.ssh (staged above) RO over the real one: no private keys, but
# known_hosts/config/*.pub present so ssh push via the SSH agent works.
[ -d "$STAGE/ssh" ] && args+=(--expose="$STAGE/ssh=$HOME_RO/.ssh")

# ~/Workspace RW (projects), then dotfiles RO over it (protects all symlinked
# agent config: settings.json, CLAUDE.md, AGENTS.md, agents, skills, bin, rules).
args+=(--share="$WORKSPACE_RW")
[ -e "$WORKSPACE_RW/dotfiles" ] && args+=(--expose="$WORKSPACE_RW/dotfiles=$WORKSPACE_RW/dotfiles")

# Optional SSH agent for git push over SSH (only if the host exposes one).
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -e "${SSH_AUTH_SOCK}" ]; then
  args+=(--share="${SSH_AUTH_SOCK}")
fi

# --- Agent state: RO config + RW state only (H1/H2) ---------------------------
# Helper: share each existing path RW.
share_rw() { for p in "$@"; do [ -e "$1/$p" ] && args+=(--share="$1/$p"); done; }

# ~/.claude: RO via $HOME expose; share only state dirs/files RW. The symlinked
# config (settings.json, CLAUDE.md, AGENTS.md, agents, skills) resolves to RO
# dotfiles and the .credentials.json stays RO.
share_rw "$HOME_RO/.claude" \
  backups cache daemon file-history jobs paste-cache plans plugins projects \
  session-env sessions shell-snapshots tasks \
  .last-cleanup daemon.lock daemon.log daemon.status.json history.jsonl stats-cache.json

# ~/.codex: RO via $HOME expose (config.toml, auth.json, AGENTS.md, agents, bin,
# rules, .git stay RO); share only state RW.
share_rw "$HOME_RO/.codex" \
  .agents .codex .tmp attachments cache generated_images log memories plugins \
  sessions shell_snapshots skills tmp \
  .personality_migration history.jsonl installation_id models_cache.json \
  session_index.jsonl version.json \
  goals_1.sqlite goals_1.sqlite-shm goals_1.sqlite-wal \
  logs_2.sqlite logs_2.sqlite-shm logs_2.sqlite-wal \
  memories_1.sqlite \
  state_5.sqlite state_5.sqlite-shm state_5.sqlite-wal

# Oracle socket (the only signing path) + start in the writable area.
args+=(--share="$SIGN_SOCK" --cwd="$WORKSPACE_RW")

# --- Entrypoint (runs INSIDE the container) ----------------------------------
entrypoint=$(cat <<'EOSH'
set -euo pipefail
uid=$(id -u)
export XDG_RUNTIME_DIR="/run/user/$uid"

# Pre-claim the Guix-home on-first-login flag so a login shell (sourced via
# ~/.profile) does NOT start shepherd here — it would crash chmod-ing
# ~/.local/state on the RO home. Soft-fail: a missed flag is annoying, not
# load-bearing for the agent.
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
: > "$XDG_RUNTIME_DIR/on-first-login-executed" 2>/dev/null || true

# Resolve the real gpg/guix/python3/bash BEFORE the shims shadow PATH. Hard-fail
# if missing — without these the shim cannot reach real gpg and the guix filter
# cannot reach the real daemon (L1: no silent failures).
real_gpg="$(command -v gpg)"    || { echo "entrypoint: gpg not on PATH" >&2;  exit 1; }
real_guix="$(command -v guix)"  || { echo "entrypoint: guix not on PATH" >&2; exit 1; }
py="$(command -v python3)"      || { echo "entrypoint: python3 not on PATH" >&2; exit 1; }
bash_bin="$(command -v bash)"   || { echo "entrypoint: bash not on PATH" >&2; exit 1; }
export GAC_REAL_GPG="$real_gpg" GAC_REAL_GUIX="$real_guix"

# Write `gpg` and `guix` wrappers in the writable runtime dir. The wrappers use
# absolute interpreter paths (no /usr/bin/env — absent in a non-FHS container)
# to exec the RO shim sources under /opt/gac. Putting the runtime dir first on
# PATH makes git + direnv pick them up transparently.
{
  printf '#!%s\nexec %s /opt/gac/gpg-shim.py "$@"\n' "$bash_bin" "$py"
} > "$XDG_RUNTIME_DIR/gpg"
{
  printf '#!%s\nexec %s /opt/gac/guix-filter.py "$@"\n' "$bash_bin" "$py"
} > "$XDG_RUNTIME_DIR/guix"
chmod 0755 "$XDG_RUNTIME_DIR/gpg" "$XDG_RUNTIME_DIR/guix"
export PATH="$XDG_RUNTIME_DIR:$PATH"
exec "$@"
EOSH
)

guix shell "${args[@]}" -- bash -c "$entrypoint" _ "$@"
