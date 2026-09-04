#!/usr/bin/env python3
"""
Timing probe for UNETRTL.DLL's LISTEN re-arm (UNETTEST -l).

Connects to the Sprinter's listening port TWICE, back to back with NO
deliberate delay, printing high-resolution wall-clock timestamps around
each attempt. Used to measure exactly how long DSS's second
accept-wait actually lasts in practice, without relying on a human
reaction time or a guessed `sleep` value.

Usage:
    python3 tools/dev/unettest_listen_timing.py --host 192.168.7.2 --port 9000
"""
from __future__ import annotations

import argparse
import socket
import sys
import time

DEFAULT_MESSAGE = b"hello from unettest_listen_timing\n"


def dial(host: str, port: int, message: bytes, timeout: float, label: str) -> None:
    t0 = time.monotonic()
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
    except OSError as exc:
        t1 = time.monotonic()
        print(f"[{label}] t=+{t1 - t0:.3f}s connect FAILED: {exc}")
        return
    t1 = time.monotonic()
    print(f"[{label}] t=+{t1 - t0:.3f}s connected")
    sock.sendall(message)
    try:
        reply = sock.recv(4096)
    except socket.timeout:
        reply = b""
    t2 = time.monotonic()
    print(f"[{label}] t=+{t2 - t0:.3f}s reply: {reply!r}")
    sock.close()
    t3 = time.monotonic()
    print(f"[{label}] t=+{t3 - t0:.3f}s closed")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="192.168.7.2")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--timeout", type=float, default=35.0,
                         help="Per-connect timeout; kept above the 30s nominal DSS accept budget (default: 35.0).")
    args = parser.parse_args(argv)

    overall_start = time.monotonic()
    dial(args.host, args.port, DEFAULT_MESSAGE, args.timeout, "dial-1")
    gap_start = time.monotonic()
    print(f"[gap] {gap_start - overall_start:.3f}s elapsed since start, dialing again immediately")
    dial(args.host, args.port, DEFAULT_MESSAGE, args.timeout, "dial-2")
    return 0


if __name__ == "__main__":
    sys.exit(main())
