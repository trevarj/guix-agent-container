# Guix container sandbox for running `claude` and `codex` safely

## Context

Run the LLM coding agents (`claude-code`, `codex`) inside an isolated Guix
container so a misbehaving agent cannot trash the system, read private keys, or
mutate the host Guix store, while still doing real work: edit projects, make
network calls (API + git), run per-project Guix profiles, and produce
**GPG-signed git commits**. Constraints:

- Networking on (outbound HTTPS to api.anthropic.com / api.openai.com / github.com).
- `$HOME` **read-only**; secret dirs masked; agent config RO, agent state RW.
- `~/Workspace` **read-write** so the agent can edit projects.
- Signed commits via a **host-side commit-only signing oracle** — the container
  never sees the gpg-agent socket or private key files.
- Per-project `manifest.scm` files under `~/Workspace` usable inside the container.
- The host Guix store not mutable/exfiltrable from inside.

Verified against this host (Guix System, `gnupg 2.4.8`, channels include
`trevarj` which packages `claude-code` and `codex`) and the Guix manual /
`guix/scripts/environment.scm`. **Implemented and verified end-to-end** (see
Verification).

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
  --preserve=GAC_SIGN_SOCK --preserve=GAC_SIGN_KEY \
  --manifest=.../guix-agent-container/manifest.scm \
  --expose=$HOME                              # $HOME RO (base)
  --expose=$STAGE=/opt/gac                    # RO shim sources
  --expose=$MASK_DIR=$HOME/.gnupg/private-keys-v1.d   # mask secret dirs ...
  --expose=$MASK_DIR=$HOME/.password-store     #   (conditional on existence)
  --expose=$STAGE/ssh=$HOME/.ssh               # staged safe .ssh (no privkeys)
  --share=$HOME/Workspace                     # projects RW
  --expose=$HOME/Workspace/dotfiles           # config symlink target RO
  [--share=$SSH_AUTH_SOCK]                     # only if set on host
  --share=$HOME/.claude/<state...>            # RW state subdirs/files
  --share=$HOME/.codex/<state...>             # RW state subdirs/files
  --share=$SIGN_SOCK                          # private temp oracle socket
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
  manifests work (see above). The `guix` on PATH is filtered (see below).
- `--preserve=GAC_SIGN_SOCK/GAC_SIGN_KEY` — `guix shell --container` strips
  custom env vars by default (verified: a test var came through empty). These
  tell the shim where the oracle socket is and which key to use.
- `--manifest=.../guix-agent-container/manifest.scm` — the container's **base**
  profile (agents + tools). Built from current host channels, so `claude-code`
  and `codex` resolve from the `trevarj` channel.
- `--expose=$HOME` (RO) — agent reads `~/.gitconfig`, `~/.config`, etc.; cannot
  trash the rest of home.
- `--expose=$STAGE=/opt/gac` (RO) — host-staged copies of `bin/gpg-shim.py` and
  `bin/guix-filter.py`. Staging outside `~/Workspace` means the container only
  sees them via a RO bind, so the agent cannot tamper with the shim it executes.
- `--expose=$MASK_DIR=$HOME/<secret>` — masks `~/.gnupg/private-keys-v1.d`,
  `~/.password-store`, `~/.aws`, `~/.local/share/keyring`,
  `~/.config/BraveSoftware`, `~/.config/chromium`, `~/.config/github-copilot`,
  `~/.lnd`, `~/wireguard`, `~/.ollama` (ed25519 keypair) with an empty dir
  (conditional on the path being a dir). Guix bind-mounts in order; the later,
  more-specific mount shadows the real dir. **Verified**: masked
  `private-keys-v1.d` is empty (real holds key files); `~/.ssh` shows only
  `known_hosts`/`config`/`*.pub`.
- `--expose=$STAGE/ssh=$HOME/.ssh` (RO) — a host-staged copy of `~/.ssh`
  containing only `known_hosts`, `config`, `*.pub`, `authorized_keys` (no
  `id_ed25519`/`id_rsa`/`wgkey`). `git push` over SSH works via the SSH agent +
  staged `known_hosts`/`config`. (Masking `.ssh` wholesale then binding
  `known_hosts` as a file under it fails — bwrap can't create the target inside
  a RO empty-dir mount; staging a safe dir and binding it as a dir works, same
  mechanism as the `~/.claude` shares.)
- `--share=$HOME/Workspace` (RW) then `--expose=$HOME/Workspace/dotfiles` (RO) —
  projects RW; dotfiles RO so all symlinked agent config
  (`settings.json`, `CLAUDE.md`, `AGENTS.md`, `agents`, `skills`, `bin`,
  `rules`) is tamper-proof.
- `--share=$HOME/.claude/<state>` / `--share=$HOME/.codex/<state>` (RW) — only
  state subdirs/files shared RW (sessions, cache, projects, todos, history,
  sqlite state + sidecars, …). `~/.claude`/`~/.codex` themselves stay RO (via
  the `$HOME` expose), so config (`settings.json`, `config.toml`, `auth.json`,
  `AGENTS.md`, symlinked `agents`/`skills`/`bin`/`rules`) is read-only.
- `--share=$SIGN_SOCK` (RW) — the oracle Unix socket in a private temp dir, the
  **only** signing path. Deliberately NOT `S.gpg-agent`: the container must not
  reach the host gpg-agent directly.
- `--cwd=$HOME/Workspace` — start in the writable area.

Entrypoint (inside the container, see `gac`) does:
- Sets `XDG_RUNTIME_DIR=/run/user/<uid>` and **pre-claims the
  `on-first-login-executed` flag** so the host Guix-home `on-first-login` (sourced
  by login shells via `~/.profile`) does not start `shepherd` inside the
  container — shepherd would crash `chmod`-ing `~/.local/state` on the RO home.
  **Verified**: `bash -lc` (login shell) survives instead of crashing.
- Resolves the real `gpg`, `guix`, `python3`, `bash` (hard-fail if any missing —
  L1: no silent failures) BEFORE the shims shadow PATH, and exports
  `GAC_REAL_GPG`/`GAC_REAL_GUIX`.
- Writes `gpg` and `guix` wrappers into the writable runtime dir. The wrappers
  use absolute interpreter paths (`#!<profile>/bin/bash` then
  `exec <profile>/bin/python3 /opt/gac/<shim>.py "$@"`) because a non-FHS
  container has no `/usr/bin/env` (verified: `#!/usr/bin/env python3` fails with
  "required file not found"). Prepends the runtime dir to PATH so git/direnv
  pick up the shims transparently.

Not used / why:
- **`--emulate-fhs` (`-F`)** — skipped. The agents are Guix-packaged (not raw
  prebuilt binaries), so FHS layout is unnecessary, and `-F` sets up its own
  `/etc` which risks colliding with the auto-exposed `/etc/hosts`. The absolute-
  interpreter wrappers avoid the `/usr/bin/env` problem `-F` would otherwise
  solve. Add `-F` only if a vendored binary later fails to find libc.
- **`--user=`** — skipped. It remaps home-relative targets to `/home/USER`,
  breaking the RO-home + socket-path goals. Container runs as our real UID
  (`environment.scm` `#:guest-uid (getuid)`).
- **`--link-profile` (`-P`)** — skipped; fails when `~/.guix-profile` exists,
  which it does because `$HOME` is exposed.

## GPG-signed commits (commit-only signing oracle)

Goal: `git commit -S` inside the container signs via the **host gpg-agent**, but
the container never sees the agent socket or private key files, and can only
sign actual git commit/tag objects (not arbitrary data, not with a different
key, and never decrypt). Implemented as three parts:

- **`bin/sign-server.py`** (host) — a Python Unix-socket daemon, started by
  `gac` via `guix shell python gnupg -- python3 …` (host python3 + gpg pulled
  in ad hoc; no global install). Policy:
  - Signs ONLY with the configured `SIGNING_KEY`, regardless of the client's
    requested key id. **Verified**: a direct socket request with key
    `DEADBEEFDEADBEEF` is refused (`key ... != configured signing key`).
  - Signs ONLY data that is structurally a git commit or tag object (regex:
    commit starts `tree <40hex>\n` + `\ncommitter `; tag starts
    `object <40hex>\ntype <word>\ntag <…>\n` + `\ntagger `). **Verified**: a
    direct request with `b"hello world not a commit"` is refused
    (`not a git commit/tag object`); a valid commit object is signed.
  - Never decrypts: it invokes host `gpg --detach-sign --armor` only. Returns
    the armored signature + the `[GNUPG:]` status lines (for git's
    `--status-fd`).
- **`bin/gpg-shim.py`** (container `gpg`) — routes git's detached signing
  (`-b`/`--detach-sign`) to the oracle; passes `--verify`/`--list-*`/`--version`/
  `--import` through to the real gpg; REFUSES `--decrypt`/`-d`/`--clearsign`/
  `--sign` (non-detach)/`--encrypt`/`--symmetric`/`--gen-key`/`--edit-key`/
  `--sign-key`/`--delete-secret-keys`/`--export-secret-keys`/`--import-secret-keys`.
  The key id it sends to the oracle is `GAC_SIGN_KEY` (the configured key), so
  the client's `-u` is ignored — defense in depth with the server's key check.
- **No `S.gpg-agent` in the container** — the real `gpg` has no agent, so on its
  own it can neither sign nor decrypt. **Verified**: real gpg
  `--detach-sign` → `No agent running`; `--decrypt` → fails; the shim refuses
  the private-key ops above.

`git commit -S` flow: git execs `gpg` (the shim) with
`--status-fd=<N> -bsau <key>` and the commit object on stdin; the shim reads
stdin, connects to `GAC_SIGN_SOCK`, sends `{key, obj}`, gets `{sig, status}`,
writes the status to fd `<N>` and the armored sig to stdout. git constructs the
commit with the `gpgsig` block. **Verified end-to-end**: `git commit -S` →
`git verify-commit HEAD` → `Good signature from "Trevor Arjeski …"`
(`verify_rc=0`).

Notes:
- The host gpg-agent must have the key (`A52D68794EBED758`) cached. Run
  `/home/trev/.codex/bin/codex-gpg-unlock` **on the host** before launching
  (never type passphrases into chat). The host then signs with no passphrase.
- The oracle signing a structurally-valid fake commit object is no worse than
  the agent running `git commit -S` itself (it already controls commit
  content); a detached signature of an object not in a repo's history is
  inert. The oracle's value is refusing to sign NON-git data (attestations,
  key certifications, arbitrary files) and refusing other keys.

## guix surface filtering (H4)

`bin/guix-filter.py` is the container `guix`. It allows only
`shell`/`environment`/`search`/`show`/`describe`/`edit` and execs the real guix
(from `--nesting`, path in `GAC_REAL_GUIX`). Everything else (`build`, `gc`,
`archive`, `copy`, `time-machine`, `pull`, `package`, `system`, `home`,
`refresh`, `import`, `lint`, …) is refused. **Verified**: `guix build hello` →
`blocked`; `guix gc` → `blocked`; `guix time-machine` → `blocked`;
`guix describe` → works; `guix shell -m manifest.scm -- python3 --version` →
`Python 3.13.13`. `direnv use guix;` (which runs `guix shell`) works.

## Files (all under `~/Workspace/guix-agent-container/`)

### `manifest.scm` — container base profile

```scheme
(specifications->manifest
 (list
  "claude-code" "codex" "bash" "util-linux" "git" "gnupg" "python" "openssh"
  "github-cli" "forgejo-cli" "direnv" "coreutils" "findutils"
  "ripgrep" "fd" "make" "tzdata" "nss-certs"))
;; gnupg: real gpg for --verify/--list passthrough (no agent in container).
;; python: runtime for the gpg + guix shims.
;; "guix" is added automatically by --nesting (-W).
```

### `bin/` — the three scripts

- `sign-server.py` — host signing oracle (run on host via `guix shell python gnupg`).
- `gpg-shim.py` — container `gpg` (oracle routing + refuse private-key ops).
- `guix-filter.py` — container `guix` (whitelist read-only + shell subcommands).

### Mask dirs — temp dirs used to mask secret dirs

`gac` creates a host temp dir at launch and bind-mounts it (RO) over each masked
secret path; nothing needs to be tracked for this.

### `gac` — launcher + container entrypoint

Starts the host oracle, stages RO shims + a safe `~/.ssh`, creates private temp
dirs for the oracle socket and the mask mounts, builds the mount table (masks,
RO dotfiles, RW state, oracle socket), and runs the entrypoint that writes the
`gpg`/`guix` wrappers. Resolves its own `bin/` + `manifest.scm` relative to the
script, so it works from a checkout or a Guix install. See the file for the
full implementation.

Invocation: `~/Workspace/guix-agent-container/gac claude` (or `codex`, or
`bash`). Run `codex-gpg-unlock` on the host first if you'll be signing commits.

## Nested sandbox inside `codex` / `claude-code` — verified OK

Both agents ship an inner sandbox (codex depends on `bubblewrap`; claude-code
can use bwrap). Inside the outer Guix `--container`, a nested `bwrap` must
create fresh user/mount/pid namespaces. **Verified this works**: `bwrap
--unshare-user --unshare-pid --ro-bind / / --dev /dev --proc /proc true` →
`BWRAP_OK`. So the agents' inner sandboxes nest cleanly; no fallback needed.

## Verification (all passed)

```sh
S=~/Workspace/guix-agent-container
/home/trev/.codex/bin/codex-gpg-unlock        # unlock host agent key once

# mounts / masks / config RO / state RW
$S/gac bash -c 'test -w ~/Workspace && echo W_OK; test -w ~/.bashrc && echo BAD_HOME_RW
  || echo HOME_RO_OK; ls -A ~/.ssh
  [ -z "$(ls -A ~/.gnupg/private-keys-v1.d/)" ] && echo KEYS_MASKED
  ( echo x >> ~/.claude/settings.json ) 2>/dev/null && echo BAD_CFG_RW || echo CFG_RO
  ( touch ~/.claude/sessions/.t && rm -f ~/.claude/sessions/.t ) && echo CLAUDE_STATE_RW
  ( echo x >> ~/.codex/config.toml ) 2>/dev/null && echo BAD_CODEX_CFG || echo CODEX_CFG_RO
  ( touch ~/.codex/sessions/.t && rm -f ~/.codex/sessions/.t ) && echo CODEX_STATE_RW'

# network + per-project manifest (core question) — guix filter passes shell
$S/gac bash -c 'cd ~/Workspace/this-week-in-guix && guix shell -m manifest.scm -- python3 --version'
# gh + fj read auth from RO home and hit their APIs over HTTPS
$S/gac bash -c 'gh api user --jq .login'                       # -> trevarj
$S/gac bash -c 'cd ~/Workspace/gubar && fj repo view -R origin' # -> trevarj/gubar
# nested bwrap (agent inner sandbox) works
$S/gac bash -c 'bwrap --unshare-user --unshare-pid --ro-bind / / --dev /dev --proc /proc true && echo BWRAP_OK'
# guix filter blocks store-mutating/exfil ops
$S/gac bash -c 'guix build hello 2>&1 | head -1; guix gc 2>&1 | head -1; guix time-machine 2>&1 | head -1'

# signing oracle: signed commit, real gpg blocked, policy enforced
$S/gac bash -c 'T=$(mktemp -d ~/Workspace/.st-XXXX); cd $T; git init -q
  git config user.name t; git config user.email t@t; git config gpg.program gpg
  echo x>f; git add f; git commit -q -S -m sigtest; git verify-commit HEAD | rg Good; rm -rf $T'
$S/gac bash -c 'echo hi | gpg --decrypt 2>&1 | head -1'        # -> refused
$S/gac bash -c 'echo hi | gpg --clearsign 2>&1 | head -1'      # -> refused
$S/gac bash -c '"$GAC_REAL_GPG" --batch --detach-sign -u A52D68794EBED758 </dev/null 2>&1 | tail -1' # No agent running
```

## Out of scope / future

- **Git push auth**: only commit *signing* is handled. Pushing over SSH uses the
  SSH agent (`--share=$SSH_AUTH_SOCK` when set — the wrapper does this) + the
  staged `known_hosts`/`config`; HTTPS push needs a token.
- **Root-level agent state files must pre-exist**: the RW state split shares
  specific `~/.claude`/`~/.codex` entries. Root-level state files
  (`daemon.lock`, `history.jsonl`, sqlite sidecars, …) are shared RW only if they
  already exist; a truly fresh agent profile that needs to create a new root
  state file would hit the RO `~/.claude`/`~/.codex` base. In practice the
  user's state already exists. If a fresh profile is needed, share the whole
  `~/.claude`/`~/.codex` RW and rely on the RO dotfiles for config protection.
- **Egress filtering**: `--network` shares the full host net namespace (no
  firewall). Restricting the agent to only api.anthropic.com / api.openai.com /
  github.com needs a separate proxy/firewall layer outside Guix's scope.
