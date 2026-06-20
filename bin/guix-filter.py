#!/usr/bin/env python3
"""Container-side `guix` filter for guix-agent-container.

Installed as `guix` on PATH inside the container (ahead of the real guix from
--nesting). Whitelists only read-only / shell subcommands so the agent cannot
mutate or exfiltrate the host store: blocks `build`, `gc`, `archive`, `copy`,
`time-machine`, `pull`, `package`, `system`, `home`, `refresh`, `import`,
`lint`, etc. Allows `shell`/`environment` (per-project manifests) and
`search`/`show`/`describe`/`edit` (read-only). The real guix path comes from
GAC_REAL_GUIX (resolved by the entrypoint before this shim shadows PATH).
"""
import os
import sys

ALLOWED = {"shell", "environment", "search", "show", "describe", "edit"}

real = os.environ.get("GAC_REAL_GUIX")
if not real or not os.path.isfile(real):
    sys.stderr.write("guix-filter: GAC_REAL_GUIX not set or invalid\n")
    sys.exit(1)

args = sys.argv[1:]
cmd = args[0] if args else ""
rest = args[1:]

if not cmd:
    os.execv(real, [real])
elif cmd in ALLOWED:
    os.execv(real, [real, cmd, *rest])
else:
    sys.stderr.write(
        f'guix-filter: "{cmd}" blocked in sandbox '
        f'(allowed: {" ".join(sorted(ALLOWED))})\n'
    )
    sys.exit(1)