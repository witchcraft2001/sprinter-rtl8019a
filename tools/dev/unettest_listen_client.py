#!/usr/bin/env python3
"""
Host-side peer for verifying UNETRTL.DLL's passive-open path
(UNET_FN_LISTEN / UNET_FN_UNLISTEN) via ``UNETTEST -l LISTENPORT``.

UNETTEST's -l mode arms LISTENPORT on the DSS side and then accepts and
serves exactly two peers in a row on the same channel, to prove that
CLOSE re-arms LISTEN automatically (docs/UNETRTL.md, "Passive open
(LISTEN)"). This script is the peer: it connects out to the Sprinter,
sends one line, prints whatever comes back, and exits. Run it TWICE
(the DSS side waits up to LISTEN_ACCEPT_TRIES * 2s = 30s between peers)
to exercise both the initial accept and the re-arm.

Usage:
    python3 tools/dev/unettest_listen_client.py --host 192.168.7.2 --port 9000
    python3 tools/dev/unettest_listen_client.py --host 192.168.7.2 --port 9000
    (run a second time for the re-arm)
"""
from __future__ import annotations

import argparse
import socket
import sys

DEFAULT_MESSAGE = b"hello from unettest_listen_client\n"


def run(host: str, port: int, message: bytes, timeout: float) -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
    except OSError as exc:
        sys.stderr.write(f"connect {host}:{port} failed: {exc}\n")
        return 1
    print(f"connected to {host}:{port}")
    sock.sendall(message)
    print(f"sent {len(message)} bytes")
    try:
        reply = sock.recv(4096)
    except socket.timeout:
        print("no reply within timeout")
        reply = b""
    if reply:
        print(f"reply ({len(reply)} bytes): {reply!r}")
    sock.close()
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="192.168.7.2", help="Sprinter's IP (default: 192.168.7.2).")
    parser.add_argument("--port", type=int, required=True, help="LISTENPORT passed to UNETTEST -l.")
    parser.add_argument("--message", default=DEFAULT_MESSAGE.decode("ascii"))
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args(argv)
    return run(args.host, args.port, args.message.encode("ascii"), args.timeout)


if __name__ == "__main__":
    sys.exit(main())
