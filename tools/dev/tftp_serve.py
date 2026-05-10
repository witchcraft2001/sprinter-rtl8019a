#!/usr/bin/env python3
"""
Minimal TFTP server for stage-7 (TFTP) testing of the Sprinter
RTL8019AS network kit.  Supports both RRQ (download) and WRQ
(upload) in octet mode with the default 512-byte block size
and RFC 2348 blksize negotiation (server replies with OACK and
the accepted block size, clamped to 8..1468 bytes).  ACK
handling has a few retransmits on timeout.  Does NOT implement
RFC 2349 timeout/tsize options or RFC 7440 windowsize.

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
OP_OACK = 6

DEFAULT_BLOCK_SIZE = 512
MIN_BLOCK_SIZE = 8
MAX_BLOCK_SIZE = 1468  # Ethernet MTU 1500 - IP(20) - UDP(8) - TFTP(4)
ACK_TIMEOUT = 2.0


def serve_file(client_addr, path, options):
    """Send a file to client, one block per cycle, waiting for ACK.

    `options` is a dict of accepted RFC 2347 options (lowercase keys
    to string values).  If non-empty we send an OACK first and wait
    for ACK block 0 before transmitting DATA blocks.
    """
    block_size = int(options.get("blksize", DEFAULT_BLOCK_SIZE))
    print(f"[serve] {client_addr[0]}:{client_addr[1]} GET {path} blksize={block_size}")
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

    if options:
        # Send OACK; expect ACK block=0 before starting DATA.
        oack_payload = b""
        for k, v in options.items():
            oack_payload += k.encode("ascii") + b"\x00" + str(v).encode("ascii") + b"\x00"
        oack = struct.pack(">H", OP_OACK) + oack_payload
        for retry in range(3):
            sock.sendto(oack, client_addr)
            try:
                ack, addr = sock.recvfrom(1024)
                if addr != client_addr or len(ack) < 4:
                    continue
                op, n = struct.unpack(">HH", ack[:4])
                if op == OP_ACK and n == 0:
                    break
            except socket.timeout:
                print(f"[serve] OACK timeout retry={retry}")
                continue
        else:
            print(f"[serve] giving up on OACK")
            sock.close()
            return

    block_no = 1
    pos = 0
    while True:
        chunk = data[pos : pos + block_size]
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

        if len(chunk) < block_size:
            print(f"[serve] done, sent {pos + len(chunk)} bytes in {block_no} block(s)")
            sock.close()
            return

        pos += block_size
        block_no = (block_no + 1) & 0xFFFF


def receive_file(client_addr, path, options):
    """Receive a file from `client_addr` and write it to `path`.

    Mirror of serve_file: send OACK / ACK(0) to start, then loop
    receiving DATA(N), writing to disk, replying ACK(N).  Stop
    when DATA shorter than blksize arrives.
    """
    block_size = int(options.get("blksize", DEFAULT_BLOCK_SIZE))
    print(f"[recv] {client_addr[0]}:{client_addr[1]} PUT {path} blksize={block_size}")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", 0))
    sock.settimeout(ACK_TIMEOUT)

    if options:
        oack_payload = b""
        for k, v in options.items():
            oack_payload += k.encode("ascii") + b"\x00" + str(v).encode("ascii") + b"\x00"
        first_reply = struct.pack(">H", OP_OACK) + oack_payload
    else:
        first_reply = struct.pack(">HH", OP_ACK, 0)

    try:
        out = open(path, "wb")
    except OSError as exc:
        print(f"[recv] open for write failed: {exc}")
        err = struct.pack(">HH", OP_ERROR, 2) + str(exc).encode("ascii", "replace") + b"\x00"
        sock.sendto(err, client_addr)
        sock.close()
        return

    try:
        # Send the start packet (OACK or ACK 0); expect DATA(1) back.
        expected_block = 1
        for retry in range(5):
            sock.sendto(first_reply, client_addr)
            try:
                pkt, addr = sock.recvfrom(4 + MAX_BLOCK_SIZE)
                if addr != client_addr or len(pkt) < 4:
                    continue
                op, n = struct.unpack(">HH", pkt[:4])
                if op == OP_DATA and n == expected_block:
                    body = pkt[4:]
                    out.write(body)
                    sock.sendto(struct.pack(">HH", OP_ACK, expected_block), client_addr)
                    if len(body) < block_size:
                        print(f"[recv] done after {expected_block} block(s), "
                              f"{out.tell()} bytes")
                        return
                    expected_block = (expected_block + 1) & 0xFFFF
                    break
            except socket.timeout:
                print(f"[recv] start retry {retry}")
                continue
        else:
            print(f"[recv] giving up at start")
            return

        # Steady-state loop.
        while True:
            for retry in range(5):
                try:
                    pkt, addr = sock.recvfrom(4 + MAX_BLOCK_SIZE)
                except socket.timeout:
                    print(f"[recv] block {expected_block} timeout (resend ACK)")
                    sock.sendto(struct.pack(">HH", OP_ACK, expected_block - 1), client_addr)
                    continue
                if addr != client_addr or len(pkt) < 4:
                    continue
                op, n = struct.unpack(">HH", pkt[:4])
                if op == OP_DATA and n == expected_block:
                    body = pkt[4:]
                    out.write(body)
                    sock.sendto(struct.pack(">HH", OP_ACK, expected_block), client_addr)
                    if len(body) < block_size:
                        print(f"[recv] done after {expected_block} block(s), "
                              f"{out.tell()} bytes")
                        return
                    expected_block = (expected_block + 1) & 0xFFFF
                    break
                # Duplicate of previous block: re-ACK silently.
                if op == OP_DATA and n == ((expected_block - 1) & 0xFFFF):
                    sock.sendto(struct.pack(">HH", OP_ACK, n), client_addr)
                    continue
            else:
                print(f"[recv] giving up at block {expected_block}")
                return
    finally:
        out.close()
        sock.close()


def parse_rrq(payload):
    """Return (filename, mode, options) or raise ValueError on malformed packet.

    `options` is a dict of negotiated/accepted RFC 2347 options keyed by
    lowercase option name; only options we actually understand are
    populated.  Currently only "blksize" (RFC 2348) is recognised.
    """
    parts = payload.split(b"\x00")
    # The trailing \x00 makes the last element empty; drop it.
    if parts and parts[-1] == b"":
        parts = parts[:-1]
    if len(parts) < 2:
        raise ValueError("malformed RRQ")
    fname = parts[0].decode("latin-1")
    mode = parts[1].decode("latin-1").lower()
    options: dict[str, str] = {}
    rest = parts[2:]
    if len(rest) % 2 != 0:
        raise ValueError("malformed RRQ options")
    for i in range(0, len(rest), 2):
        key = rest[i].decode("latin-1").lower()
        val = rest[i + 1].decode("latin-1")
        if key == "blksize":
            try:
                n = int(val)
            except ValueError:
                continue
            if n < MIN_BLOCK_SIZE:
                n = MIN_BLOCK_SIZE
            if n > MAX_BLOCK_SIZE:
                n = MAX_BLOCK_SIZE
            options["blksize"] = str(n)
        # silently ignore unknown options per RFC 2347
    return fname, mode, options


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
                    fname, mode, options = parse_rrq(packet[2:])
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
                serve_file(addr, full, options)
            elif opcode == OP_WRQ:
                try:
                    fname, mode, options = parse_rrq(packet[2:])
                except ValueError as exc:
                    print(f"[recv] {addr}: bad WRQ: {exc}")
                    continue
                if mode != "octet":
                    print(f"[recv] {addr}: refusing mode={mode!r}")
                    err = struct.pack(">HH", OP_ERROR, 0) + b"only octet mode supported\x00"
                    sock.sendto(err, addr)
                    continue
                safe = os.path.basename(fname)
                full = os.path.join(args.root, safe)
                receive_file(addr, full, options)
            else:
                print(f"[recv] {addr}: opcode {opcode} ignored")
    except KeyboardInterrupt:
        print("\nbye")
        return 0


if __name__ == "__main__":
    sys.exit(main())
