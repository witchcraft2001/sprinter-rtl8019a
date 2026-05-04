#!/usr/bin/env python3
"""
Tiny UDP echo server for stage 7 (UDPTEST) testing of the
Sprinter RTL8019AS network kit.

Listens on 0.0.0.0:<port> and echoes every datagram back to its
sender. By default binds to 192.168.7.1:7777 (matches UDPTEST's
hardcoded TARGET_IP / TARGET_PORT for the feth-pair test setup).

Usage:
    sudo python3 tools/dev/udp_echo.py
    sudo python3 tools/dev/udp_echo.py --bind 192.168.7.1 --port 7777
    sudo python3 tools/dev/udp_echo.py --bind 0.0.0.0
"""
from __future__ import annotations

import argparse
import socket
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="UDP echo server.")
    parser.add_argument(
        "--bind",
        default="192.168.7.1",
        help="Bind address (default: 192.168.7.1).",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=7777,
        help="Bind port (default: 7777).",
    )
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind((args.bind, args.port))
    except OSError as exc:
        sys.stderr.write(f"bind {args.bind}:{args.port} failed: {exc}\n")
        return 1

    print(f"UDP echo listening on {args.bind}:{args.port}")
    try:
        while True:
            data, addr = sock.recvfrom(2048)
            print(f"recv {len(data)} bytes from {addr[0]}:{addr[1]}: {data!r}")
            sock.sendto(data, addr)
    except KeyboardInterrupt:
        print("\nbye")
        return 0


if __name__ == "__main__":
    sys.exit(main())
