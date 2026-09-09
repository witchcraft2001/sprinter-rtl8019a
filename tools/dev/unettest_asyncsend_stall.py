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

**Disable TCP receive-buffer auto-tuning before running this**, or the
test cannot work at all:

    sudo sysctl -w net.inet.tcp.doautorcvbuf=0
    python3 tools/dev/unettest_asyncsend_stall.py --bind 192.168.7.1 --port 8080
    sudo sysctl -w net.inet.tcp.doautorcvbuf=1   # restore afterward

macOS's auto-tuning (`net.inet.tcp.doautorcvbuf`, on by default)
overwrites whatever SO_RCVBUF the listening socket requested, as soon as
the connection is accepted -- confirmed by probing loopback, where a
1-byte request still came back as ~320 KB, and matching the ~8.5 KB seen
on a real LAN regardless of --rcvbuf. With a window that size the whole
payload fits in one go, SEND never suspends, and UNETTEST reports
`resumes needed: 0` -- a result that says nothing about the DLL. No
amount of --rcvbuf/--stall tuning works around it. This script checks
the accepted socket and refuses to pretend otherwise (see the WARNING it
prints), so always read its log before trusting a run.

The defaults are the combination proven to work on real hardware. Two
constraints bound them, and both are easy to violate by hand:

* --rcvbuf must exceed TCP_MSS (536).  A smaller window means no segment
  ever fits, the DLL sends nothing at all, and the drain reports 0 bytes.
* --stall must stay well under ASYNC_MAX_AGAIN * ASYNC_SLICE_MS
  (20 * 150 ms = 3000 ms), or the DLL exhausts its resume budget and the
  send fails outright instead of resuming.

(see docs/UNETRTL_TESTING_RU.md).

Usage:
    python3 tools/dev/unettest_asyncsend_stall.py --bind 192.168.7.1 --port 8080
    python3 tools/dev/unettest_asyncsend_stall.py --bind 192.168.7.1 --port 8080 --rcvbuf 900 --stall 1.5
"""
from __future__ import annotations

import argparse
import socket
import sys
import time


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", file=sys.stderr, flush=True)


# UNETTEST -a sends ASYNC_PAYLOAD_LEN bytes (src/apps/unettest.asm).  Once
# the peer's window is at least this big the whole payload lands in one
# pass and SEND has no reason to suspend, whatever --stall says.
ASYNC_PAYLOAD_LEN = 1200
TCP_MSS = 536


def serve_one(server: socket.socket, stall_seconds: float, requested_rcvbuf: int) -> None:
    conn, addr = server.accept()
    actual_rcvbuf = conn.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    log(f"CONN from {addr[0]}:{addr[1]} (accepted socket rcvbuf={actual_rcvbuf})")
    if actual_rcvbuf >= ASYNC_PAYLOAD_LEN:
        log(f"WARNING: the accepted socket's receive window ({actual_rcvbuf} bytes) holds "
            f"the whole {ASYNC_PAYLOAD_LEN}-byte payload, so SEND will never suspend and "
            f"'resumes needed: 0' will prove NOTHING about the DLL.")
        if actual_rcvbuf > requested_rcvbuf:
            log(f"WARNING: it also ignored the requested {requested_rcvbuf} bytes -- that is "
                f"TCP receive-buffer auto-tuning. Run: "
                f"sudo sysctl -w net.inet.tcp.doautorcvbuf=0   (restore with =1 afterward)")
    elif actual_rcvbuf <= TCP_MSS:
        log(f"WARNING: the accepted socket's receive window ({actual_rcvbuf} bytes) is not "
            f"larger than TCP_MSS ({TCP_MSS}), so no segment can fit and the DLL will send "
            f"nothing at all. Raise --rcvbuf above {TCP_MSS}.")
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
    parser.add_argument("--rcvbuf", type=int, default=700,
                        help="Requested SO_RCVBUF in bytes (default: 700 -- above TCP_MSS 536 so "
                             "segments still fit, below the 1200-byte payload so the window "
                             "closes; the OS overrides this unless doautorcvbuf is off).")
    parser.add_argument("--stall", type=float, default=1.0,
                        help="Seconds to accept-and-not-read before draining (default: 1.0; must "
                             "stay well under the DLL's 3 s resume budget).")
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
            serve_one(server, args.stall, args.rcvbuf)
            if args.once:
                break
    except KeyboardInterrupt:
        log("interrupted")
    finally:
        server.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
