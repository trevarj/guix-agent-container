# guix-agent-container

Run `claude` and `codex` inside an isolated Guix container so a misbehaving agent
cannot trash your home or read your private keys, while still letting it do real
work: edit projects, make network calls, and produce GPG-signed git commits.

## What it gives you

- **Networking on** — outbound HTTPS to api.anthropic.com / api.openai.com /
  github.com / codeberg.org (DNS carried automatically).
- **`$HOME` read-only** — the agent can read `~/.gitconfig`, `~/.config`, etc.
  but cannot modify them.
- **`~/.claude` and `~/.codex` read-write** — the agents must persist their own
  state (sessions, todos, logs) to function.
- **`~/Workspace` read-write** — the agent edits your projects.
- **Private keys masked** — `~/.gnupg/private-keys-v1.d` is shadowed by an empty
  dir; private key files never enter the container.
- **Signed commits** — `git commit -S` signs via the **host gpg-agent** socket;
  the container never sees the private key.
- **Per-project manifests** — `--nesting` maps the host guix daemon + store into
  the container, so `guix shell -m <proj>/manifest.scm` and `direnv use guix;`
  work natively inside. They do not auto-load on `cd`; the agent triggers them
  per command (same as on the host).
- **`gh` and `fj`** included for GitHub and Forgejo/Codeberg PRs, issues, API.

## Prerequisites

- Guix System (or Guix with the daemon), with your channels including `trevarj`
  (which packages `claude-code` and `codex`).
- A GPG signing key configured in `~/.gitconfig` (`commit.gpgsign = true`,
  `user.signingkey = <key>`).
- The host gpg-agent must have the signing key cached. Unlock it once on the
  host before launching (never type passphrases into the agent chat):

  ```sh
  /home/trev/.codex/bin/codex-gpg-unlock
  ```

## Usage

```sh
~/Workspace/guix-agent-container/run.sh claude   # launch Claude Code
~/Workspace/guix-agent-container/run.sh codex    # launch Codex
~/Workspace/guix-agent-container/run.sh bash     # drop into a shell to inspect
```

The first launch builds the container profile (cached afterward). The agent
starts in `~/Workspace` with the container's base tools on `PATH`
(`git`, `gh`, `fj`, `gpg`, `direnv`, `rg`, `fd`, `guix`, …).

Optional: if `SSH_AUTH_SOCK` is set on the host, the wrapper shares it into the
container so git push over SSH works.

## Files

- `run.sh` — launcher + in-container entrypoint (the thing you run).
- `manifest.scm` — container base profile (agents + tools).
- `empty/` — empty dir bind-mounted over `~/.gnupg/private-keys-v1.d` to mask
  private keys. Kept in git via `empty/.gitkeep`; `run.sh` recreates it if missing.
- `PLAN.md` — full design rationale and verification record.

## How it works (short version)

`guix shell --container --network --nesting` with:

- `--expose=$HOME` (RO), then `--share` the writable subtrees (`~/.claude`,
  `~/.codex`, `~/Workspace`) so they shadow RO for those paths,
- `--expose=empty=$HOME/.gnupg/private-keys-v1.d` to mask private keys,
- `--share=/run/user/<uid>/gnupg/S.gpg-agent` to reach the host gpg-agent,
- an entrypoint that: pre-claims the Guix-home `on-first-login` flag (so login
  shells don't start `shepherd` and crash on the RO home), `chmod 700`s the gnupg
  socket dir (so gpg finds the bind-mounted socket), and installs a `gpg` shim
  adding `--lock-never --no-random-seed-file --no-permission-warning` so signing
  works against the RO `~/.gnupg`.

## Security notes

- `~/.gnupg` and `~/.ssh` private material is **not readable** (gnupg private keys
  masked; `~/.ssh` not exposed). Signed commits work via the agent socket only.
- The `gh` OAuth token (`~/.config/gh/hosts.yml`) and `fj` keys
  (`~/.local/share/forgejo-cli/keys.json`) **are readable** — the CLIs must read
  them to auth, so a process in the container can too. If that is a concern, use
  scoped/short-lived tokens; masking those paths breaks the CLIs.
- `--network` shares the full host network namespace (no egress filtering).
  Restricting the agent to specific hosts needs a separate proxy/firewall.

## Verify it works

```sh
G=~/Workspace/guix-agent-container
$G/run.sh bash -c 'test -w ~/Workspace && echo W_OK; test -w ~/.claude && echo CLAUDE_RW;
  [ -z "$(ls -A ~/.gnupg/private-keys-v1.d/)" ] && echo KEYS_MASKED;
  test -S /run/user/1000/gnupg/S.gpg-agent && echo SOCK_OK'
$G/run.sh bash -c 'gh api user --jq .login'                       # -> trevarj
$G/run.sh bash -c 'cd ~/Workspace/gubar && fj repo view -R origin' # Codeberg repo info
$G/run.sh bash -c 'cd ~/Workspace/this-week-in-guix && guix shell -m manifest.scm -- python3 --version'
# signed commit via host agent (run codex-gpg-unlock first):
$G/run.sh bash -c 'T=$(mktemp -d ~/Workspace/.st-XXXX); cd $T; git init -q;
  git config user.name t; git config user.email t@t; echo x>f; git add f;
  git commit -q -S -m sigtest; git log -1 --show-signature | rg "Good signature"; rm -rf $T'
```

See `PLAN.md` for the full design, the per-project-manifest mechanism, and the
GPG-via-agent investigation.