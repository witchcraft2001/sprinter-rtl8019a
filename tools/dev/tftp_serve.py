#!/usr/bin/env python3
"""
Minimal TFTP read-only server for stage 7 (TFTP) testing of the
Sprinter RTL8019AS network kit.

Serves files from a chosen directory over UDP/69. Supports
RRQ in octet mode with the default 512-byte block size; ACK
handling, single retransmit on timeout. Does NOT implement
write requests, options, error retries beyond the basic cycle
or RFC 2347 OACK; that's intentional -- the goal is a small,
predictable target for the DSS-side TFTP client.

Usage:
    sudo python3 tools/dev/tftp_serve.py
    sudo python3 tools/dev/tftp_serve.py --bind 192.168.7.1 --root .

Default bind: 192.168.7.1:69 (matches TFTP.EXE hardcoded target).

Note: port 69 is privileged. Run with sudo, or change --port.
"""
from __future__ import annotations

import argparse
import os
import socket
import struct
import sys
import time

OP_RRQ = 1
OP_WRQ = 2
OP_DATA = 3
OP_ACK = 4
OP_ERROR = 5

BLOCK_SIZE = 512
ACK_TIMEOUT = 2.0


def serve_file(client_addr, path):
    """Send a file to client, one block per cycle, waiting for ACK."""
    print(f"[serve] {client_addr[0]}:{client_addr[1]} GET {path}")
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        print(f"[serve] open failed: {exc}")
        return

    # Bind a per-transfer ephemeral socket as our TID.
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", 0))
    sock.settimeout(ACK_TIMEOUT)

    block_no = 1
    pos = 0
    while True:
        chunk = data[pos : pos + BLOCK_SIZE]
        packet = struct.pack(">HH", OP_DATA, block_no) + chunk
        for retry in range(3):
            sock.sendto(packet, client_addr)
            try:
                ack, addr = sock.recvfrom(1024)
                if addr != client_addr:
                    continue
                if len(ack) < 4:
                    continue
                op, n = struct.unpack(">HH", ack[:4])
                if op == OP_ACK and n == block_no:
                    break
            except socket.timeout:
                print(f"[serve] timeout block={block_no} retry={retry}")
                continue
        else:
            print(f"[serve] giving up at block {block_no}")
            sock.close()
            return

        if len(chunk) < BLOCK_SIZE:
            print(f"[serve] done, sent {pos + len(chunk)} bytes in {block_no} block(s)")
            sock.close()
            return

        pos += BLOCK_SIZE
        block_no = (block_no + 1) & 0xFFFF


def parse_rrq(payload):
    """Return (filename, mode) or raise ValueError on malformed packet."""
    parts = payload.split(b"\x00")
    if len(parts) < 3:
        raise ValueError("malformed RRQ")
    return parts[0].decode("latin-1"), parts[1].decode("latin-1").lower()


def main() -> int:
    parser = argparse.ArgumentParser(description="Minimal TFTP read-only server.")
    parser.add_argument("--bind", default="192.168.7.1", help="Bind address.")
    parser.add_argument("--port", type=int, default=69, help="Bind port (default 69, needs sudo).")
    parser.add_argument("--root", default=".", help="Directory to serve files from.")
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind((args.bind, args.port))
    except OSError as exc:
        sys.stderr.write(f"bind {args.bind}:{args.port} failed: {exc}\n")
        return 1
    print(f"TFTP server listening on {args.bind}:{args.port}, root={os.path.abspath(args.root)}")

    try:
        while True:
            packet, addr = sock.recvfrom(1024)
            if len(packet) < 2:
                continue
            opcode = struct.unpack(">H", packet[:2])[0]
            if opcode == OP_RRQ:
                try:
                    fname, mode = parse_rrq(packet[2:])
                except ValueError as exc:
                    print(f"[recv] {addr}: bad RRQ: {exc}")
                    continue
                if mode != "octet":
                    print(f"[recv] {addr}: refusing mode={mode!r}")
                    err = struct.pack(">HH", OP_ERROR, 0) + b"only octet mode supported\x00"
                    sock.sendto(err, addr)
                    continue
                # Resolve filename safely (no path traversal).
                safe = os.path.basename(fname)
                full = os.path.join(args.root, safe)
                if not os.path.isfile(full):
                    print(f"[recv] {addr}: not found: {fname}")
                    err = struct.pack(">HH", OP_ERROR, 1) + b"file not found\x00"
                    sock.sendto(err, addr)
                    continue
                # Spawn (synchronous) transfer.
                serve_file(addr, full)
            elif opcode == OP_WRQ:
                err = struct.pack(">HH", OP_ERROR, 2) + b"write not supported\x00"
                sock.sendto(err, addr)
            else:
                print(f"[recv] {addr}: opcode {opcode} ignored")
    except KeyboardInterrupt:
        print("\nbye")
        return 0


if __name__ == "__main__":
    sys.exit(main())
