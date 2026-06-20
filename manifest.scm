;; Container base profile for the LLM-agent sandbox.
;; Built from the current host channels; `claude-code` and `codex` resolve
;; from the `trevarj` channel (trev-guix/packages/ai.scm).
;; `guix` itself is added automatically by `--nesting` (-W), so not listed.
(specifications->manifest
 (list
  "claude-code"   ;; LLM agent (trevarj channel)
  "codex"         ;; LLM agent (trevarj channel; depends on bubblewrap)
  "bash"         ;; shell for the entrypoint + agent subprocesses
  "util-linux"   ;; mount, findmnt, lsblk (handy for the agent + debugging)
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
  "nss-certs"     ;; CA bundle for HTTPS to Anthropic/OpenAI/GitHub
  ))