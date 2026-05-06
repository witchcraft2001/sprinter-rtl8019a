#!/usr/bin/env python3
"""
Minimal NTP server for testing NTP.EXE on Sprinter via feth0/feth1.

Listens on UDP 123 on the bind address (default 192.168.7.1, the
feth1 host side).  Responds to any NTP client request with the
host's current time and a fixed stratum so the Sprinter can verify
the round-trip and timestamp parsing.

Run:
    sudo python3 tools/dev/ntp_serve.py
    # or, with custom bind:
    sudo python3 tools/dev/ntp_serve.py --bind 192.168.7.1

Requires root (port 123 < 1024).  Stop with Ctrl+C.

This is a developer aid; not shipped with the kit (excluded from
DIST_*).
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time

NTP_EPOCH_OFFSET = 2208988800  # seconds between 1900-01-01 and 1970-01-01


def now_ntp() -> tuple[int, int]:
    """Current time as (seconds_since_1900, fraction_2^32)."""
    t = time.time()
    secs = int(t) + NTP_EPOCH_OFFSET
    frac = int((t - int(t)) * (1 << 32))
    return secs & 0xFFFFFFFF, frac & 0xFFFFFFFF


def build_reply(rx_secs: int, rx_frac: int, originate_ts: bytes) -> bytes:
    """Build a 48-byte NTPv3 server reply from a client request."""
    li_vn_mode = (0 << 6) | (3 << 3) | 4  # LI=0, VN=3, Mode=4 (server)
    stratum = 2
    poll = 4
    precision = 0xEC  # ~2^-20 sec
    root_delay = 0
    root_disp = 0
    ref_id = b"LOCL"
    ref_ts = struct.pack("!II", rx_secs, rx_frac)
    orig_ts = originate_ts
    recv_ts = struct.pack("!II", rx_secs, rx_frac)
    tx_secs, tx_frac = now_ntp()
    tx_ts = struct.pack("!II", tx_secs, tx_frac)

    parts = bytearray(48)
    parts[0] = li_vn_mode
    parts[1] = stratum
    parts[2] = poll
    parts[3] = precision
    parts[4:8] = struct.pack("!I", root_delay)
    parts[8:12] = struct.pack("!I", root_disp)
    parts[12:16] = ref_id
    parts[16:24] = ref_ts
    parts[24:32] = orig_ts
    parts[32:40] = recv_ts
    parts[40:48] = tx_ts
    return bytes(parts)


def main() -> int:
    ap = argparse.ArgumentParser(description="Tiny NTP responder for Sprinter testing.")
    ap.add_argument("--bind", default="192.168.7.1", help="bind address (default 192.168.7.1)")
    ap.add_argument("--port", type=int, default=123, help="UDP port (default 123)")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind((args.bind, args.port))
    except PermissionError:
        print("ERROR: bind to port < 1024 requires root (sudo).", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    print(f"NTP test server listening on {args.bind}:{args.port}")
    print("Press Ctrl+C to stop.")

    while True:
        try:
            data, addr = sock.recvfrom(1024)
        except KeyboardInterrupt:
            print()
            return 0
        if len(data) < 48:
            print(f"  drop short packet from {addr[0]}:{addr[1]} len={len(data)}")
            continue
        rx_secs, rx_frac = now_ntp()
        # Originate = client's transmit timestamp at offset 40..47.
        orig = data[40:48]
        reply = build_reply(rx_secs, rx_frac, orig)
        sock.sendto(reply, addr)
        print(
            f"  query from {addr[0]}:{addr[1]} -> reply (stratum=2, "
            f"tx={time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime())} UTC)"
        )


if __name__ == "__main__":
    sys.exit(main())
