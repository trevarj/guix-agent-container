# Guix container sandbox for running `claude` and `codex` safely

## Context

Run the LLM coding agents (`claude-code`, `codex`) inside an isolated Guix
container so a misbehaving agent cannot trash the system or exfiltrate secrets,
while still doing real work: edit projects, make network calls (API + git), and
produce **GPG-signed git commits**. Constraints:

- Networking on (outbound HTTPS to api.anthropic.com / api.openai.com / github.com).
- `$HOME` **read-only** so the agent can read `~/.gitconfig`, `~/.config` etc.
  but cannot trash home or read private keys.
- `~/.claude` and `~/.codex` **read-write** — the agents must persist their own
  runtime state (sessions, todos, logs, cache) to function.
- `~/Workspace` **read-write** so the agent can edit projects.
- Signed commits via the host's `gpg-agent`, without the container ever seeing
  the private key files.
- Per-project `manifest.scm` files under `~/Workspace` usable inside the container.

Verified against this host (Guix System, `gnupg 2.4.8`, channels include
`trevarj` which packages `claude-code` and `codex`) and the Guix manual /
`guix/scripts/environment.scm`. **Implemented and verified end-to-end.**

## Answer to the core question (per-project manifests)

A Guix container's profile is fixed at launch from whatever manifest/profile you
pass to `guix shell --container`. Inside a plain `-C` container there is **no
guix daemon and no `/gnu/store`**, so a nested `guix shell -m manifest.scm` or
`direnv use guix;` would fail. They do **not** auto-load on `cd`.

The fix is **`--nesting` / `-W`**: it maps the host guix daemon socket, the whole
`/gnu/store`, the `guix` command, and `~/.cache/guix` into the container. Then
`guix shell -m ~/Workspace/<proj>/manifest.scm` (and `direnv use guix;`) work
**natively** inside — they talk to the host daemon, reuse/build profiles, and
layer search paths on top of the container's base, still confined by the outer
container's mount/net namespace. A nested `guix shell` does **not** spawn a
nested container unless `-C` is passed again. The agent triggers per-project deps
per-command (mirroring the host workflow `guix shell <pkg> -- cmd` from
AGENTS.md); `-W` is what makes that work. **Verified**: `python3` (absent from
the base container profile) appears inside a nested
`guix shell -m ~/Workspace/this-week-in-guix/manifest.scm`.

## Architecture (flag choices)

```
guix shell --container --network --nesting \
  --manifest=.../guix-agent-container/manifest.scm \
  --expose=$HOME \
  --expose=<emptydir>=$HOME/.gnupg/private-keys-v1.d \
  --share=$HOME/.claude \
  --share=$HOME/.codex \
  --share=$HOME/Workspace \
  --share=/run/user/1000/gnupg/S.gpg-agent \
  [--share=$SSH_AUTH_SOCK]            # only if set on host
  --cwd=$HOME/Workspace \
  -- bash -c <entrypoint> _ "$@"
```

Why each:
- `--container` — mount + network namespace isolation (default: loopback only,
  dummy tmpfs home, same UID/GID).
- `--network` / `-N` — shares host net namespace; outbound HTTPS + DNS work.
  Auto-carries `/etc/resolv.conf`, `/etc/hosts`, `/etc/nsswitch.conf`,
  `/etc/services` (`%network-file-mappings`). No manual resolv.conf exposure.
- `--nesting` / `-W` — host guix daemon + store + `guix` inside, so per-project
  manifests work (see above).
- `--manifest=.../guix-agent-container/manifest.scm` — the container's **base** profile
  (agents + tools). Built from current host channels, so `claude-code` and
  `codex` resolve from the `trevarj` channel.
- `--expose=$HOME` (RO) — agent reads `~/.gitconfig`, `~/.config`, etc.; cannot
  trash the rest of home.
- `--share=$HOME/.claude`, `--share=$HOME/.codex` (RW) — the agents must persist
  their own runtime state. Without this, codex warns
  `could not update PATH: Read-only file system` and neither agent can save state.
  Everything else in home stays RO; this preserves the security goal (no writing to
  arbitrary home, private keys unreadable) while letting the agents function.
- `--expose=<emptydir>=$HOME/.gnupg/private-keys-v1.d` — **masks the private key
  files**. Guix bind-mounts in command-line order; the later, more-specific mount
  shadows the real dir. Private keys never enter the container. **Verified**:
  masked dir is empty (the real one holds 4 `.key` files).
- `--share=$HOME/Workspace` (RW) — agent edits projects. Order matters: expose
  `$HOME` first, then share the subtrees so RW shadows RO there.
- `--share=/run/user/1000/gnupg/S.gpg-agent` — the host gpg-agent socket, RW, for
  signed commits (see GPG section). Guix creates the parent dir.
- `--cwd=$HOME/Workspace` — start in the writable area.

Entrypoint (inside the container, see `run.sh`) does three things:
- Sets `XDG_RUNTIME_DIR=/run/user/<uid>` and **pre-claims the
  `on-first-login-executed` flag** so the host Guix-home `on-first-login` (sourced
  by login shells via `~/.profile`) does not start `shepherd` inside the
  container — shepherd would crash `chmod`-ing `~/.local/state` on the RO home.
  **Verified**: `bash -lc` (login shell) now survives instead of crashing.
- `chmod 700 /run/user/<uid>/gnupg` — Guix creates it as 755 when bind-mounting
  the socket, and gnupg rejects a non-700 socket dir (falling back to a homedir
  socket that misses our bind mount). **Verified**: `gpgconf --list-dirs
  agent-socket` then reports `/run/user/1000/gnupg/S.gpg-agent`.
- Builds a `gpg` shim on `PATH` adding `--lock-never --no-random-seed-file
  --no-permission-warning` so signing works against the RO `~/.gnupg`. `git`
  resolves `gpg.program` (default `gpg`) via `PATH` and picks up the shim.

Not used / why:
- **`--emulate-fhs` (`-F`)** — skipped. The agents are Guix-packaged (not raw
  prebuilt binaries), so FHS layout is unnecessary, and `-F` sets up its own
  `/etc` which risks colliding with the auto-exposed `/etc/hosts`. Add `-F` only
  if a vendored binary later fails to find libc.
- **`--user=`** — skipped. It remaps home-relative targets to `/home/USER`,
  breaking the RO-home + socket-path goals. Container runs as our real UID
  (`environment.scm` `#:guest-uid (getuid)`), so UID 1000 inside == 1000 on host,
  which is why the host gpg-agent accepts the connection.
- **`--link-profile` (`-P`)** — skipped; fails when `~/.guix-profile` exists,
  which it does because `$HOME` is exposed.

## GPG-signed commits (investigated design)

`git commit -S` inside the container signs via the **host gpg-agent**; the
container never sees `private-keys-v1.d/*.key`. Verified against gnupg 2.4.8:

- **Socket location**: with `GNUPGHOME` unset and `XDG_RUNTIME_DIR=/run/user/uid`,
  `gpgconf --list-dirs agent-socket` = `/run/user/1000/gnupg/S.gpg-agent` (under
  `/run/user`, not `$HOME`). Bind-mounting that one socket makes gpg connect to
  the host agent. Do **not** set a custom `GNUPGHOME` — that moves the computed
  socketdir to a hashed path and breaks the match.
- **No keyboxd needed**: `use-keyboxd` is unset (no `~/.gnupg/common.conf`), so gpg
  reads `pubring.kbx` directly. Only `S.gpg-agent` is required.
- **Private key absence is fine**: gpg computes the keygrip from the **public**
  key in `pubring.kbx` and sends `SIGKEY <keygrip>` to the agent; the agent holds
  the private key and performs `PKSIGN`. gpg never reads `private-keys-v1.d` —
  masking it is a pure security measure, not functional. **Verified**: key shows
  as `sec` (agent has it) and `git commit -S` produces a `Good signature`.
- **RO homedir + no lock writes**: `~/.gnupg` is RO. A sign op would normally
  create `.#lk*` / `pubring.kbx.lock` / `random_seed` writes, which fail on RO.
  Suppressed via the gpg shim flags `--lock-never`, `--no-random-seed-file`,
  `--no-permission-warning` (the last must be on the command line, not in
  `gpg.conf`). A `trustdb not writable` note is emitted and harmless.
- **`git commit -S`** calls OpenPGP `gpg` (not `gpgsm`/dirmngr).
- **Host key unlock**: run `/home/trev/.codex/bin/codex-gpg-unlock` **on the
  host** before launching the container so the host agent has the key
  (`A52D68794EBED758`) cached. The container signs with no passphrase, per
  AGENTS.md (never type passphrases into chat).

## Files (all under `~/Workspace/guix-agent-container/`)

### `manifest.scm` — container base profile

```scheme
(specifications->manifest
 (list
  "claude-code"   ;; from trevarj channel (trev-guix/packages/ai.scm)
  "codex"         ;; from trevarj channel (depends on bubblewrap)
  "bash"          ;; shell for the entrypoint + agent subprocesses
  "util-linux"    ;; mount, findmnt, lsblk (agent + debugging)
  "git"
  "gnupg"         ;; gpg for signed commits (via host agent socket)
  "openssh"       ;; ssh client for git push
  "github-cli"    ;; `gh` — GitHub PRs/issues/API (AGENTS.md: GitHub remote)
  "forgejo-cli"   ;; `fj` — Forgejo/Codeberg PRs/issues/API (AGENTS.md: Codeberg remote)
  "direnv"
  "coreutils"
  "findutils"
  "ripgrep"
  "fd"
  "make"
  "tzdata"        ;; TZ=Etc/UTC resolves
  "nss-certs"     ;; CA bundle for HTTPS
  ;; "guix" is added automatically by --nesting (-W)
  ))
```

### `empty/` — empty dir used to mask private keys

`mkdir -p ~/Workspace/guix-agent-container/empty` (leave empty).

### `run.sh` — launcher + container entrypoint

```sh
#!/usr/bin/env bash
# Launch an LLM coding agent (claude / codex) in an isolated Guix container.
#   - $HOME read-only; ~/.claude & ~/.codex RW; ~/Workspace RW
#   - ~/.gnupg/private-keys-v1.d masked; signed commits via host gpg-agent
#   - --nesting so per-project manifest.scm / direnv use guix work inside
# Usage:  run.sh claude | codex | bash
# Sign commits?  Run /home/trev/.codex/bin/codex-gpg-unlock on the host first.
set -euo pipefail

HOME_RO="${HOME:?}"
SBX="$HOME_RO/Workspace/guix-agent-container"
WORKSPACE_RW="$HOME_RO/Workspace"
AGENT_SOCK="/run/user/$(id -u)/gnupg/S.gpg-agent"

EXTRA=()
[ -n "${SSH_AUTH_SOCK:-}" ] && [ -e "${SSH_AUTH_SOCK}" ] && EXTRA+=(--share="${SSH_AUTH_SOCK}")

entrypoint=$(cat <<'EOSH'
set -euo pipefail
uid=$(id -u)
export XDG_RUNTIME_DIR="/run/user/$uid"
# Pre-claim on-first-login flag -> host Guix-home shepherd does NOT start here
# (it would crash chmod-ing ~/.local/state on the RO home).
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
: > "$XDG_RUNTIME_DIR/on-first-login-executed" 2>/dev/null || true
# gnupg needs a 700 socket dir; Guix makes /run/user/<uid>/gnupg 755 -> fix it
# so gpgconf reports the /run socket we bind-mounted.
chmod 700 "$XDG_RUNTIME_DIR/gnupg" 2>/dev/null || true
# gpg shim: sign via host agent without writing to RO ~/.gnupg.
real_gpg="$(command -v gpg)"
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
  --network --nesting \
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
```

Invocation: `~/Workspace/guix-agent-container/run.sh claude` (or `codex`, or `bash`).

## Nested sandbox inside `codex` / `claude-code` — verified OK

Both agents ship an inner sandbox (codex depends on `bubblewrap`; claude-code can
use bwrap). Inside the outer Guix `--container`, a nested `bwrap` must create
fresh user/mount/pid namespaces. **Verified this works**: `unshare --user
--map-root-user -- true` succeeds, and `bwrap --unshare-user --unshare-pid
--ro-bind / / --dev /dev --proc /proc true` succeeds. So the agents' inner
sandboxes nest cleanly; **no fallback needed**. (If a future kernel/container
change breaks nesting, the fallback is to disable the agent's inner sandbox and
rely on the Guix container as the boundary.)

## Verification (all passed)

```sh
S=~/Workspace/guix-agent-container
/home/trev/.codex/bin/codex-gpg-unlock        # unlock host agent key once

# mounts / state dirs / keys / socket
$S/run.sh bash -c 'test -w ~/Workspace && echo W_OK; test -w ~/.claude && echo CLAUDE_RW;
  test -w ~/.codex && echo CODEX_RW; test -w ~/.bashrc && echo BAD_HOME_RW;
  [ -z "$(ls -A ~/.gnupg/private-keys-v1.d/)" ] && echo KEYS_MASKED;
  test -S /run/user/1000/gnupg/S.gpg-agent && echo SOCK_OK'
# network + DNS
$S/run.sh bash -c 'getent hosts api.anthropic.com'
# per-project manifest loads inside (core question) — python3 not in base profile
$S/run.sh bash -c 'cd ~/Workspace/this-week-in-guix && guix shell -m manifest.scm -- python3 --version'
# signed commit via host agent, private keys never visible
$S/run.sh bash -c 'T=$(mktemp -d ~/Workspace/.st-XXXX); cd $T; git init -q;
  git config user.name t; git config user.email t@t; echo x>f; git add f;
  git commit -q -S -m sigtest; git log -1 --show-signature | rg "Good signature"; rm -rf $T'
# nested bwrap (agent inner sandbox) works
$S/run.sh bash -c 'bwrap --unshare-user --unshare-pid --ro-bind / / --dev /dev --proc /proc true && echo BWRAP_OK'
# gh + fj read auth from RO home and hit their APIs over HTTPS
$S/run.sh bash -c 'gh api user --jq .login'                       # -> trevarj
$S/run.sh bash -c 'cd ~/Workspace/gubar && fj repo view -R origin' # -> Codeberg repo info
```

## Forge CLIs (`gh`, `fj`) — verified functional

Both are in the manifest (`github-cli` → `gh`, `forgejo-cli` → `fj`) and work
inside the container:
- `gh` reads its token from `~/.config/gh/hosts.yml` (RO); `gh api user` →
  `trevarj`, `gh repo view` → repo JSON. Note: `gh --version` prints an empty
  version string (Guix build didn't embed the version) — cosmetic; gh functions.
- `fj` reads auth from `~/.local/share/forgejo-cli/keys.json` (RO);
  `fj repo view -R origin` and `fj issue search -R origin -s all` return real
  Codeberg data. `fj` resolves the host from the local git remote (`-R origin`).

**Trade-off**: the `gh` OAuth token and `fj` keys are *readable* by the agent
(they live under RO `~/.config`/`~/.local/share`, which are exposed). This is
required — the CLIs must read the token to call the API, so a process running
in the container can read it. If exfiltration of forge tokens is a concern,
mask `~/.config/gh` and `~/.local/share/forgejo-cli` (the agent then can't auth)
or use scoped/short-lived tokens. Unlike `~/.gnupg`/`~/.ssh`, these were not
masked because masking them breaks the CLIs.

## Out of scope / future

- **Git push auth**: only commit *signing* is handled. Pushing over SSH needs an
  SSH agent (`--share=$SSH_AUTH_SOCK` when set — the wrapper already does this) or
  an HTTPS token.
- **Stricter isolation**: keep `~/.claude`/`~/.codex` RO and relocate agent state
  to a writable dir via `CLAUDE_CONFIG_DIR` / `CODEX_HOME` (seeded with symlinks
  to the RO host config). Only if letting the agent write its own dirs is
  unacceptable for your threat model.
- **Egress filtering**: `--network` shares the full host net namespace (no
  firewall). Restricting the agent to only api.anthropic.com / api.openai.com /
  github.com needs a separate proxy/firewall layer outside Guix's scope.