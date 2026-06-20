#!/usr/bin/env python3
"""Host-side commit-only signing oracle for guix-agent-container.

Listens on a Unix socket. The container's `gpg` shim connects here to sign git
commit/tag objects. This server is the ONLY thing with access to the host
gpg-agent; the container never sees the OpenPGP agent socket.

Policy:
  - Sign ONLY with the configured signing key (SIGNING_KEY), regardless of what
    the client requests.
  - Sign ONLY data that is structurally a git commit or tag object. This blocks
    signing arbitrary attacker-controlled bytes (fake attestations, key
    certifications, arbitrary files) while still letting `git commit -S` /
    `git tag -s` work (the agent already controls commit/tag content, so signing
    a valid-structure git object is equivalent to it running git commit -S).
  - Never decrypt: no PKDECRYPT path exists here. The host gpg is invoked only
    with --detach-sign.

Protocol (length-prefixed, big-endian uint32):
  request:  keyid_len | keyid | obj_len | obj_bytes
  response: code(4) | msg_len | msg | [sig_len | sig | status_len | status]
    code 0 = ok, 1 = error. On ok, sig is the armored detached signature and
    status is the [GNUPG:] status lines from gpg (for git's --status-fd).

Usage: sign-server.py <socket_path> <signing_key>
"""
import os
import re
import socket
import struct
import subprocess
import sys


def die(msg):
    sys.stderr.write(f"sign-server: {msg}\n")
    sys.exit(1)


# A git commit object content (what git hashes/signs) starts with
# `tree <40hex>\n` and contains a `committer ` line. A tag object starts with
# `object <40hex>\ntype <word>\ntag <...>\n` and contains a `tagger ` line.
# These checks reject arbitrary text while accepting real git objects.
COMMIT_RE = re.compile(rb"^tree [0-9a-f]{40}\n(?:parent [0-9a-f]{40}\n)*.*\ncommitter [^\n]+\n", re.S)
TAG_RE = re.compile(rb"^object [0-9a-f]{40}\ntype (commit|tree|blob|tag)\ntag [^\n]+\n.*\ntagger [^\n]+\n", re.S)


def looks_like_git_object(obj: bytes) -> bool:
    return bool(COMMIT_RE.match(obj) or TAG_RE.match(obj))


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None  # connection closed
        buf += chunk
    return buf


def read_request(sock):
    hdr = recv_exact(sock, 4)
    if hdr is None:
        return None
    (keyid_len,) = struct.unpack(">I", hdr)
    keyid = recv_exact(sock, keyid_len)
    if keyid is None:
        return None
    (obj_len,) = struct.unpack(">I", recv_exact(sock, 4) or b"\0\0\0\0")
    obj = recv_exact(sock, obj_len)
    if obj is None:
        return None
    return keyid.decode("utf-8", "replace"), obj


def send(sock, code, msg, sig=b"", status=b""):
    out = struct.pack(">I", code) + struct.pack(">I", len(msg)) + msg
    if code == 0:
        out += struct.pack(">I", len(sig)) + sig + struct.pack(">I", len(status)) + status
    sock.sendall(out)


def sign(signing_key, keyid, obj):
    # Run host gpg to produce an armored detached signature of obj.
    proc = subprocess.run(
        ["gpg", "--status-fd=2", "--detach-sign", "--armor",
         "--batch", "--no-tty", "--local-user", signing_key],
        input=obj, capture_output=True,
    )
    if proc.returncode != 0:
        return None, (proc.stderr.decode("utf-8", "replace") or "gpg failed").strip()
    sig = proc.stdout
    # Status = the [GNUPG:] lines gpg wrote to stderr (what git parses).
    status = b"\n".join(
        line for line in proc.stderr.splitlines() if line.startswith(b"[GNUPG:] ")
    ) + b"\n"
    return sig, status


def handle(sock, signing_key):
    req = read_request(sock)
    if req is None:
        return
    keyid, obj = req
    # Policy 1: only the configured key.
    if keyid != signing_key:
        send(sock, 1, f"refused: key {keyid} != configured signing key".encode())
        return
    # Policy 2: only git commit/tag objects.
    if not looks_like_git_object(obj):
        send(sock, 1, b"refused: payload is not a git commit/tag object")
        return
    sig, status_or_err = sign(signing_key, keyid, obj)
    if sig is None:
        send(sock, 1, status_or_err.encode("utf-8", "replace"))
        return
    send(sock, 0, b"ok", sig, status_or_err if isinstance(status_or_err, bytes) else b"")
    sys.stderr.write(f"sign-server: signed {keyid} obj_len={len(obj)}\n")


def main():
    if len(sys.argv) != 3:
        die("usage: sign-server.py <socket_path> <signing_key>")
    sock_path, signing_key = sys.argv[1], sys.argv[2]
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    parent = os.path.dirname(sock_path)
    os.makedirs(parent, exist_ok=True)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(sock_path)
    os.chmod(sock_path, 0o600)  # only our uid can connect
    s.listen(8)
    sys.stderr.write(f"sign-server: listening on {sock_path} key={signing_key}\n")
    try:
        while True:
            conn, _ = s.accept()
            try:
                handle(conn, signing_key)
            except Exception as e:  # never let one bad request kill the server
                sys.stderr.write(f"sign-server: error: {e}\n")
                try:
                    send(conn, 1, f"server error: {e}".encode())
                except Exception:
                    pass
            finally:
                conn.close()
    except KeyboardInterrupt:
        pass
    finally:
        s.close()
        if os.path.exists(sock_path):
            os.unlink(sock_path)


if __name__ == "__main__":
    main()