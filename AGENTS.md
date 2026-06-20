# AGENTS.md

Project guidance for `guix-agent-container`. Extends the global `AGENTS.md`
(Guix System baseline); project rules below override where they conflict.

## What this is

`gac` launches the `claude` and `codex` coding agents inside an isolated Guix
container: read-only home, masked secrets, read-only agent config with
read-write state, a filtered `guix` surface, and GPG-signed commits via a
host-side commit-only signing oracle. The container never sees the gpg-agent
socket or private keys.

## Architecture (the invariants — don't break these)

- **Host oracle, not the agent socket.** `bin/sign-server.py` runs on the host
  (under `guix shell python gnupg`), listens on a private temp Unix socket
  shared into the container. The container's `gpg` shim (`bin/gpg-shim.py`)
  routes *only* `--detach-sign` of verified git commit/tag objects to it.
  Decrypt/clearsign/encrypt/gen-key/export-secret-keys/etc. are refused. The
  real `gpg` (no agent in the container) cannot sign or decrypt on its own.
  **Never** share `S.gpg-agent` or any agent socket into the container.
- **Commit-only oracle.** `sign-server.py` validates the payload is a git
  commit/tag object *and* the requested key matches `GAC_SIGN_KEY` before
  signing. Keep that validation; don't widen it to arbitrary data.
- **Filtered `guix`.** `bin/guix-filter.py` allows only
  `shell`/`environment`/`search`/`show`/`describe`/`edit`. Everything that
  mutates or exfiltrates the store (`build`/`gc`/`archive`/`copy`/
  `time-machine`/`pull`/`package`/`system`/`home`/...) is blocked. Don't add
  mutating commands to `ALLOWED`.
- **RO home, RW state only.** `$HOME` exposed RO; secret dirs masked with an
  empty temp dir; `~/.ssh` replaced by a staged safe copy (known_hosts/config/
  `*.pub`/authorized_keys — no private keys). Only state subdirs/files of
  `~/.claude`/`~/.codex` are shared RW. Agent config stays RO/tamper-proof.
- **No silent failures.** The entrypoint hard-fails if `gpg`/`guix`/`python3`/
  `bash` can't be resolved before the shims shadow PATH. Keep that.

## Files

- `gac` — the launcher + in-container entrypoint. Resolves its own `bin/` +
  `manifest.scm` relative to the script (works from a checkout and a Guix
  install). Uses bash arrays + `local`; the package patches its shebang to the
  store bash.
- `manifest.scm` — the container's base profile (agents + tools; `python` for
  the shims, `gnupg` for verify/list passthrough). Built from current host
  channels — `claude-code`/`codex` resolve from the `trevarj` channel.
- `bin/sign-server.py` — host-side commit-only signing oracle.
- `bin/gpg-shim.py` — container `gpg` (oracle routing + refuse private-key ops).
- `bin/guix-filter.py` — container `guix` (whitelist above).
- `PLAN.md` — full design rationale + verification record.
- `README.md` — user-facing usage.

## Dev workflow

- Run from a checkout: `./gac claude` / `./gac codex` / `./gac bash` (full path
  works too). First launch builds the container profile (cached after).
- Sign commits in the sandbox? Run
  `/home/trev/.codex/bin/codex-gpg-unlock` on the host first to cache the key.
- Installed via the `trevarj` channel package `gac`, so `gac claude` works from
  anywhere once `guix pull`'d.

## Verification before "done"

These exercise the full chain (mounts, shims, oracle, filter). Run from a
checkout and confirm:

```sh
./gac bash -c 'test -w ~/Workspace && echo W_OK; ls -A ~/.ssh; [ -z "$(ls -A ~/.gnupg/private-keys-v1.d/)" ] && echo KEYS_MASKED'
./gac bash -c 'echo x >> ~/.claude/settings.json 2>/dev/null && echo BAD || echo CFG_RO'
./gac bash -c 'guix build hello 2>&1 | head -1'   # -> blocked
./gac bash -c 'echo hi | gpg --decrypt 2>&1 | head -1'   # -> refused
# signed commit through the oracle (unlock host agent first):
./gac bash -c 'T=$(mktemp -d ~/Workspace/.st-XXXX); cd $T; git init -q;
  git config user.name t; git config user.email t@t; git config gpg.program gpg;
  echo x>f; git add f; git commit -q -S -m sigtest; git verify-commit HEAD | rg Good; rm -rf $T'
```

If you change the mount table, shims, or oracle, re-run these and the
end-to-end sign.

## Conventions

- Mimic existing style; brief inline comments explaining intent by default.
- Guix System: never `guix install`; use temp shells / the project manifest.
  Python isn't guaranteed on PATH — `guix shell python -- python3 ...`.
- Search with `rg` / `fd`.
- The launcher is `gac`, not `run.sh` (renamed). Don't reintroduce `run.sh`.
- `MASK_DIR` and `SIGN_DIR` are host temp dirs created/cleaned per launch —
  nothing tracked for them.
- `set -euo pipefail` is on: use `if/then/fi` (not `cond && action`) for
  optional `args+=()` so a missing last item can't abort the launch.

## Git & signing

- Conventional Commits; commit only when asked. This is a personal repo —
  committing to `main` is fine.
- Every commit GPG-signed. If signing fails (key locked), run
  `/home/trev/.codex/bin/codex-gpg-unlock`, then retry the signed commit (up
  to 3×). Never make an unsigned commit.

## Guix package (trevarj channel)

The `gac` package lives in the `trevarj` channel at
`channel/trev-guix/packages/ai.scm` (a separate repo: `~/Workspace/trev-guix`),
not in this repo. It `git-fetch`es this repo at a tag. When bumping:

1. Tag the release here (`vX.Y.Z`) and push the tag.
2. In the channel: bump `version`, re-fetch the hash
   (`guix build -L channel gac` reports the mismatch), commit, push.
3. `guix build -L ~/Workspace/trev-guix/channel gac` must succeed.