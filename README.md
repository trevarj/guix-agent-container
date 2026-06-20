# guix-agent-container

Run `claude` and `codex` inside an isolated Guix container so a misbehaving agent
cannot trash your home, read your private keys, or mutate the host Guix store —
while still doing real work: edit projects, make network calls, run per-project
Guix profiles, and produce GPG-signed git commits.

## What it gives you

- **Networking on** — outbound HTTPS to api.anthropic.com / api.openai.com /
  github.com / codeberg.org (DNS carried automatically by `--network`).
- **`$HOME` read-only** — the agent reads `~/.gitconfig`, `~/.config`, etc. but
  cannot modify them.
- **Secret dirs masked** — `~/.ssh` (replaced by a staged safe copy: only
  `known_hosts`, `config`, `*.pub`, `authorized_keys` — no private keys),
  `~/.gnupg/private-keys-v1.d`, `~/.password-store`, `~/.aws`,
  `~/.local/share/keyring`, `~/.config/BraveSoftware`, `~/.config/chromium`,
  `~/.config/github-copilot`, `~/.lnd`, `~/wireguard`, `~/.ollama` (holds an
  ed25519 keypair) are shadowed by an empty dir. Private key material never
  enters the container.
- **Agent config read-only, state read-write** — `~/Workspace/dotfiles` is
  exposed RO (all symlinked `~/.claude`/`~/.codex` config lives there:
  `settings.json`, `CLAUDE.md`, `AGENTS.md`, `agents`, `skills`, `bin`,
  `rules`). `~/.claude` and `~/.codex` are RO with only their state
  subdirs/files shared RW (sessions, cache, projects, todos, history, sqlite
  state, …). The agent cannot rewrite its own config.
- **`~/Workspace` read-write** — the agent edits your projects.
- **Signed commits via a host-side commit-only signing oracle** — `git commit -S`
  signs through a `gpg` shim → host server → host gpg-agent. The container
  never sees the gpg-agent socket. The oracle signs ONLY verified git
  commit/tag objects with the configured key; decrypt/clearsign/encrypt/
  gen-key/edit-key/export-secret-keys are refused, and the real `gpg`
  (which has no agent) cannot sign or decrypt on its own.
- **`guix` surface filtered** — inside the container `guix` is a shim that
  allows only `shell`/`environment`/`search`/`show`/`describe`/`edit`.
  `build`/`gc`/`archive`/`copy`/`time-machine`/`pull`/`package`/`system`/… are
  blocked, so the agent cannot mutate or exfiltrate the host store.
- **Per-project manifests** — `--nesting` maps the host guix daemon + store
  into the container, so `guix shell -m <proj>/manifest.scm` and
  `direnv use guix;` work natively inside (the `guix` filter passes `shell`
  through). They do not auto-load on `cd`; the agent triggers them per command.
- **`gh` and `fj`** included for GitHub and Forgejo/Codeberg PRs, issues, API.
- **`ollama`** included — the CLI talks to the host's `ollama serve` over the
  shared net namespace (`OLLAMA_HOST=127.0.0.1:11434`), so `ollama run`/`list`
  use the host's models without running a second server. `~/.ollama` (which
  holds an ed25519 keypair) is masked.

## Prerequisites

- Guix System (or Guix with the daemon), channels including `trevarj` (packages
  `claude-code` and `codex`).
- A GPG signing key configured in `~/.gitconfig` (`commit.gpgsign = true`,
  `user.signingkey = <key>`). The default signing key is
  `A52D68794EBED758`; override with `GAC_SIGN_KEY=<key>`.
- The host gpg-agent must have the signing key cached. Unlock it once on the
  host before launching (never type passphrases into the agent chat):

  ```sh
  /home/trev/.codex/bin/codex-gpg-unlock
  ```

- The host signing server runs under `guix shell python gnupg -- python3 …`
  (host python3 is pulled in automatically; no global install needed).

## Usage

```sh
~/Workspace/guix-agent-container/gac claude   # launch Claude Code
~/Workspace/guix-agent-container/gac codex    # launch Codex
~/Workspace/guix-agent-container/gac bash     # drop into a shell to inspect
```

Installed via the `trevarj` Guix channel (package `gac`), the launcher is on
`PATH`, so `gac claude` / `gac codex` / `gac bash` work from anywhere. Run from a
checkout with the full path as above.

The first launch builds the container profile (cached afterward). The agent
starts in `~/Workspace` with the container's base tools on `PATH`
(`git`, `gh`, `fj`, `gpg`→shim, `guix`→filter, `direnv`, `rg`, `fd`, …).

`gac` starts a host signing server (backgrounded, killed on exit), stages RO
shims in a host temp dir, creates a private temp dir for the oracle socket, and
launches the container. Optional: if
`SSH_AUTH_SOCK` is set on the host, the wrapper shares it into the container so
git push over SSH works (the staged `~/.ssh` provides `known_hosts`/`config`;
the SSH agent provides the key — no private key file is exposed).

## Files

- `gac` — launcher + in-container entrypoint (the thing you run).
- `manifest.scm` — container base profile (agents + tools, incl. `python` for
  the shims).
- `bin/sign-server.py` — host-side commit-only signing oracle (runs on host).
- `bin/gpg-shim.py` — container `gpg`: routes git detach-sign to the oracle,
  refuses private-key/secret ops, passes verify/list/version to real gpg.
- `bin/guix-filter.py` — container `guix`: whitelists shell/search/show/
  describe/edit.
- Mask dirs are host temp dirs created at launch (bind-mounted RO over masked
  secret paths); nothing needs to be tracked for them.
- `PLAN.md` — full design rationale and verification record.

## How it works (short version)

`guix shell --container --network --nesting` with:

- `--expose=$HOME` (RO), then `--share` the writable subtrees (`~/Workspace`)
  and `--expose` masked empty dirs + the staged safe `~/.ssh` over secret paths,
- `--expose=$STAGE=/opt/gac` (RO) holding the shim sources,
- `--share` the RW state subdirs of `~/.claude` / `~/.codex`,
- `--expose ~/Workspace/dotfiles` RO (config tamper-proofing),
- `--share` the private temp oracle socket (the only signing path — NOT the
  gpg-agent socket),
- `--preserve=GAC_SIGN_SOCK/GAC_SIGN_KEY` so the shim reaches the oracle,
  `--preserve=TERM/COLORTERM/TERM_PROGRAM` so color + the agent TUIs work
  (`--container` otherwise resets `TERM=dumb`),
- an entrypoint that: pre-claims the Guix-home `on-first-login` flag (so login
  shells don't start `shepherd` and crash on the RO home), resolves the real
  `gpg`/`guix`/`python3`/`bash` and writes `gpg`/`guix` wrappers (absolute
  interpreters — no `/usr/bin/env` in a non-FHS container) into the writable
  runtime dir, and prepends that dir to `PATH`.

The host `sign-server.py` validates that the payload is a git commit/tag object
and that the requested key matches the configured signing key before invoking
host `gpg --detach-sign`; it returns the armored signature + `[GNUPG:]` status
lines. The container `gpg` shim emits them where git expects (`--status-fd`).

## Security notes

- Private key material (`~/.ssh/id_*`, `~/.gnupg/private-keys-v1.d/*.key`,
  password store, AWS, keyring, browser profiles, wireguard keys) is **not
  readable**. SSH push works via the SSH agent + staged `known_hosts`/`config`.
- The container has **no gpg-agent socket**. Signing goes only through the
  oracle, which signs only git commit/tag objects with the configured key.
  Direct `gpg --decrypt`/`--clearsign`/`--sign`/`--gen-key`/`--edit-key`/
  `--export-secret-keys` are refused by the shim; the real `gpg` cannot reach an
  agent. Verified: `git commit -S` → `Good signature`; real `gpg --detach-sign`
  → `No agent running`; oracle refuses wrong key / non-git payloads.
- Agent config is RO; only state is RW. Residual: a deliberately malicious agent
  could `rm` a symlinked config entry in RW state and write a replacement file
  only if that entry's parent were RW — here the config entries live under the
  RO `~/Workspace/dotfiles` or the RO `~/.claude`/`~/.codex` base, so they
  cannot be replaced.
- The `gh` token (`~/.config/gh/hosts.yml`) and `fj` keys
  (`~/.local/share/forgejo-cli/keys.json`) **are readable** — the CLIs must read
  them to auth, so a process in the container can too. Use scoped/short-lived
  tokens if exfiltration is a concern (masking those paths breaks the CLIs).
- `--network` shares the full host network namespace (no egress filtering).
  Restricting the agent to specific hosts needs a separate proxy/firewall.

## Verify it works

```sh
G=~/Workspace/guix-agent-container
$G/gac bash -c 'test -w ~/Workspace && echo W_OK; test -w ~/.bashrc && echo BAD_HOME_RW;
  ls -A ~/.ssh; [ -z "$(ls -A ~/.gnupg/private-keys-v1.d/)" ] && echo KEYS_MASKED'
$G/gac bash -c 'echo x >> ~/.claude/settings.json 2>/dev/null && echo BAD || echo CFG_RO;
  ( touch ~/.claude/sessions/.t && rm -f ~/.claude/sessions/.t ) && echo STATE_RW'
$G/gac bash -c 'gh api user --jq .login'                       # -> trevarj
$G/gac bash -c 'cd ~/Workspace/gubar && fj repo view -R origin' # Codeberg repo
$G/gac bash -c 'cd ~/Workspace/this-week-in-guix && guix shell -m manifest.scm -- python3 --version'
$G/gac bash -c 'guix build hello 2>&1 | head -1'              # -> blocked
$G/gac bash -c 'echo hi | gpg --decrypt 2>&1 | head -1'       # -> refused
# signed commit via the oracle (run codex-gpg-unlock on the host first):
$G/gac bash -c 'T=$(mktemp -d ~/Workspace/.st-XXXX); cd $T; git init -q;
  git config user.name t; git config user.email t@t; git config gpg.program gpg;
  echo x>f; git add f; git commit -q -S -m sigtest; git verify-commit HEAD | rg Good;
  rm -rf $T'
```

See `PLAN.md` for the full design, the per-project-manifest mechanism, and the
signing-oracle investigation.
