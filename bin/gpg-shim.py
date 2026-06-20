#!/usr/bin/env python3
"""Container-side `gpg` shim for guix-agent-container.

Installed as `gpg` on PATH inside the container. Routes git's detached signing
of commit/tag objects to the host signing oracle (GAC_SIGN_SOCK); everything
else goes to the real gpg. The real gpg has NO agent socket in the container, so
on its own it cannot sign or decrypt — the oracle is the only signing path and
it validates that the payload is a git object first.

Env:
  GAC_SIGN_SOCK  oracle Unix socket path (shared into the container)
  GAC_SIGN_KEY   the key id the oracle is configured to sign with

Behavior:
  - detach-sign (`-b`/`--detach-sign`)             -> oracle (validates git object)
  - --verify / --list-* / --version / --import ...  -> real gpg (no private-key use)
  - decrypt / clearsign / sign / encrypt / symmetric / gen-key / edit-key /
    export-secret-keys / sign-key / delete-secret-keys  -> REFUSED (exit 2)
"""
import os
import socket
import struct
import sys


def refuse(msg):
    sys.stderr.write(f"gpg-shim: {msg}\n")
    sys.exit(2)


# Ops that touch private keys or materialize secrets. The shim never forwards these.
BLOCKED = {
    "--decrypt", "-d", "--clearsign", "--clear-sign",
    "--sign", "-s", "--encrypt", "-e", "--symmetric", "-c",
    "--gen-key", "--generate-key", "--quick-gen-key", "--quick-generate-key",
    "--edit-key", "--passwd", "--change-passphrase",
    "--delete-secret-keys", "--delete-secret-and-public-keys",
    "--export-secret-keys", "--export-secret-subkeys",
    "--sign-key", "--lsign-key", "--import-secret-keys",
}


def find_keyid(args):
    """Extract the -u/--local-user key id from git's gpg argv."""
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--local-user" and i + 1 < len(args):
            return args[i + 1]
        if a.startswith("--local-user="):
            return a.split("=", 1)[1]
        if a.startswith("-") and not a.startswith("--") and len(a) > 1:
            cluster = a[1:]
            if "u" in cluster:
                rest = cluster[cluster.index("u") + 1:]
                if rest:  # -uKEY attached
                    return rest
                if i + 1 < len(args):  # -u KEY separate (e.g. -bsau KEY)
                    return args[i + 1]
            # short opt that takes a value: -u handled above; -o/-r etc. skip next
            if cluster[-1] in ("o", "r", "R"):
                i += 2
                continue
        i += 1
    return None


def find_status_fd(args):
    for a in args:
        if a.startswith("--status-fd="):
            try:
                return int(a.split("=", 1)[1])
            except ValueError:
                pass
    return 2


def find_output(args):
    """Return (output_path_or_None, remaining_args_without_-o/--output)."""
    out = []
    target = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-o" and i + 1 < len(args):
            target = args[i + 1]; i += 2; continue
        if a == "--output" and i + 1 < len(args):
            target = args[i + 1]; i += 2; continue
        if a.startswith("--output="):
            target = a.split("=", 1)[1]; i += 1; continue
        if a.startswith("-") and not a.startswith("--") and "o" in a[1:]:
            cluster = a[1:]
            rest = cluster[cluster.index("o") + 1:]
            if rest:
                target = rest; out.append("-" + cluster.replace("o", "")); i += 1; continue
            target = args[i + 1]; i += 2; continue
        out.append(a); i += 1
    return target, out


def is_detach_sign(args):
    for a in args:
        if a == "--detach-sign" or a.startswith("--detach-sign="):
            return True
        if a.startswith("-") and not a.startswith("--") and "b" in a[1:]:
            return True
    return False


def is_verify(args):
    return any(a == "--verify" or a.startswith("--verify=") for a in args)


def oracle_sign(args):
    sock_path = os.environ.get("GAC_SIGN_SOCK")
    key = os.environ.get("GAC_SIGN_KEY") or find_keyid(args) or ""
    if not sock_path:
        refuse("GAC_SIGN_SOCK not set; cannot sign")
    obj = sys.stdin.buffer.read()
    status_fd = find_status_fd(args)
    out_target, _ = find_output(args)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
    except OSError as e:
        refuse(f"cannot reach signing oracle at {sock_path}: {e}")
    req = (
        struct.pack(">I", len(key.encode())) + key.encode()
        + struct.pack(">I", len(obj)) + obj
    )
    try:
        s.sendall(req)
        # read response
        (code,) = struct.unpack(">I", _rec(s, 4))
        (mlen,) = struct.unpack(">I", _rec(s, 4))
        msg = _rec(s, mlen)
        if code != 0:
            sys.stderr.write(msg.decode("utf-8", "replace") + "\n")
            sys.exit(2)
        (slen,) = struct.unpack(">I", _rec(s, 4))
        sig = _rec(s, slen)
        (stlen,) = struct.unpack(">I", _rec(s, 4))
        status = _rec(s, stlen)
    finally:
        s.close()
    # Emit gpg status to the fd git asked for (it parses [GNUPG:] lines there).
    try:
        os.write(status_fd, status)
    except OSError:
        sys.stderr.buffer.write(status)
    if out_target:
        with open(out_target, "wb") as f:
            f.write(sig)
    else:
        sys.stdout.buffer.write(sig)
    sys.exit(0)


def _rec(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise OSError("oracle closed connection")
        buf += chunk
    return buf


def main():
    args = sys.argv[1:]
    # Refuse private-key / secret ops up front.
    for a in args:
        if a in BLOCKED or a.startswith("--decrypt") or a.startswith("--clearsign") \
                or a.startswith("--clear-sign") or a.startswith("--symmetric"):
            refuse(f"refused in sandbox: {a} (private-key/secret op)")
        # -d alone or as part of a short cluster
        if a.startswith("-") and not a.startswith("--") and "d" in a[1:] and "b" not in a[1:]:
            # -d is decrypt only when not combined with -b (detach); guard anyway
            refuse(f"refused in sandbox: decrypt (-d) in {a}")
    if is_detach_sign(args):
        oracle_sign(args)
    # Everything else (verify, list, version, import, ...) -> real gpg.
    # The real gpg has no agent here, so it still can't sign/decrypt on its own.
    real = os.environ.get("GAC_REAL_GPG") or shutil_which("gpg")
    if not real:
        refuse("real gpg not found on PATH")
    os.execv(real, ["gpg"] + args)


def shutil_which(name):
    p = os.environ.get("PATH", "").split(":")
    shim_dir = os.path.dirname(os.path.abspath(__file__))
    for d in p:
        if os.path.abspath(d) == shim_dir:
            continue  # skip ourselves to avoid recursion
        cand = os.path.join(d, name)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


if __name__ == "__main__":
    main()