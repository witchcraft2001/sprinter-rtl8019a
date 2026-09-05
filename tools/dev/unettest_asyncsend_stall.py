#!/usr/bin/env python3
"""
Host-side stalling TCP peer for verifying UNETRTL.DLL's non-blocking
SEND path (UNET_FN_SETOPT UNET_OPT_SENDSLICE / NERR_AGAIN) via
``UNETTEST -a``.

UNETTEST's -a mode SETOPTs a short SENDSLICE, CONNECTs, and then SENDs a
~1200-byte payload (a few TCP_MSS chunks). To make the DLL's SEND
actually suspend with NERR_AGAIN, the peer's TCP receive window has to
close -- an ordinary echo server that keeps calling recv() never does
that, since the OS ACKs and re-opens the window continuously. This
script forces the window shut instead: it shrinks SO_RCVBUF on the
listening socket (inherited by the accepted connection's initial
window) and then does not call recv() at all for --stall seconds, long
enough for the DLL to fill that window and have at least one SEND
attempt's SENDSLICE quantum expire with no ACK.

If UNETTEST still reports zero NERR_AGAIN resumes, the accepted socket's
logged rcvbuf is almost certainly nowhere near --rcvbuf: macOS's TCP
receive-buffer auto-tuning (`net.inet.tcp.doautorcvbuf`, on by default)
overwrites whatever SO_RCVBUF the listening socket requested as soon as
the connection is accepted -- confirmed by probing loopback, where a
1-byte request still came back as ~320 KB, and matches the ~8.5 KB seen
on feth regardless of --rcvbuf. No amount of --rcvbuf/--stall tuning
works around this; disable auto-tuning for the test instead:

    sudo sysctl -w net.inet.tcp.doautorcvbuf=0
    python3 tools/dev/unettest_asyncsend_stall.py --bind 192.168.7.1 --port 8080 --rcvbuf 256 --stall 3
    sudo sysctl -w net.inet.tcp.doautorcvbuf=1   # restore afterward

(see docs/UNETRTL_TESTING_RU.md).

Usage:
    python3 tools/dev/unettest_asyncsend_stall.py --bind 192.168.7.1 --port 8080
    python3 tools/dev/unettest_asyncsend_stall.py --bind 192.168.7.1 --port 8080 --rcvbuf 128 --stall 3
"""
from __future__ import annotations

import argparse
import socket
import sys
import time


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", file=sys.stderr, flush=True)


def serve_one(server: socket.socket, stall_seconds: float) -> None:
    conn, addr = server.accept()
    actual_rcvbuf = conn.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    log(f"CONN from {addr[0]}:{addr[1]} (accepted socket rcvbuf={actual_rcvbuf})")
    log(f"stalling {stall_seconds}s without reading -- this is what forces NERR_AGAIN")
    time.sleep(stall_seconds)
    conn.settimeout(2.0)
    total = 0
    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            total += len(chunk)
    except socket.timeout:
        pass
    log(f"drained {total} bytes total")
    conn.close()
    log("closed")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bind", default="192.168.7.1", help="Bind address (default: 192.168.7.1).")
    parser.add_argument("--port", type=int, default=8080, help="Bind port (default: 8080).")
    parser.add_argument("--rcvbuf", type=int, default=256, help="Requested SO_RCVBUF in bytes (default: 256; the OS may clamp this up).")
    parser.add_argument("--stall", type=float, default=2.0, help="Seconds to accept-and-not-read before draining (default: 2.0).")
    parser.add_argument("--once", action="store_true", help="Serve exactly one connection, then exit.")
    args = parser.parse_args(argv)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, args.rcvbuf)
    try:
        server.bind((args.bind, args.port))
    except OSError as exc:
        sys.stderr.write(f"bind {args.bind}:{args.port} failed: {exc}\n")
        return 1
    server.listen(1)
    log(f"READY bind={args.bind}:{args.port} requested_rcvbuf={args.rcvbuf} stall={args.stall}s")

    try:
        while True:
            serve_one(server, args.stall)
            if args.once:
                break
    except KeyboardInterrupt:
        log("interrupted")
    finally:
        server.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
