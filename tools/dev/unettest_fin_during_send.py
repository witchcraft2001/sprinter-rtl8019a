#!/usr/bin/env python3
"""
Host-side peer that answers and half-closes WHILE the Sprinter is still
sending, for verifying UNETRTL.DLL 0.3.8's peer-FIN-during-SEND path via
``UNETTEST -a``.

This reproduces the WebDAV ``PUT`` failure reported against 0.3.7: a
server rejects a request before it has consumed the declared body, so the
HTTP status and the FIN arrive while the client's SEND is still waiting
for the acknowledgement of an outstanding chunk.  Before 0.3.8 the DLL
reported that as ``nerr=05 tcp=00`` (a generic send failure with no TCP
reason at all); it must now report ``nerr=07`` (NERR_CLOSED) with
``tcp=08`` (F_CLOSED).

An ordinary socket server cannot produce this: the kernel acknowledges
everything it receives, so by the time the response goes out the client's
chunk is already acknowledged and SEND simply succeeds.  Two things make
the timing deterministic here:

* a small SO_RCVBUF on the LISTENING socket (inherited by the accepted
  connection), so the receive window closes once this script stops
  reading -- the client's last chunk then stays unacknowledged;
* ``shutdown(SHUT_WR)`` rather than ``close()``.  A closed socket with
  unread data makes the kernel answer further segments with RST, which
  takes the DLL down its OTHER (destructive) close path and proves
  nothing about this fix.  The socket is therefore held open until the
  client goes away.

**Disable TCP receive-buffer auto-tuning before running this**, exactly
as for tools/dev/unettest_asyncsend_stall.py, or the window never closes:

    sudo sysctl -w net.inet.tcp.doautorcvbuf=0
    python3 tools/dev/unettest_fin_during_send.py --bind 192.168.7.1 --port 8080
    sudo sysctl -w net.inet.tcp.doautorcvbuf=1   # restore afterward

Read the log before trusting a run: the script reports the accepted
socket's real receive buffer and how many bytes were still unread when it
sent the FIN, and warns when either value means the vector did not fire.

Timing constraint: --delay must stay well under the DLL's resume budget
(ASYNC_MAX_AGAIN * ASYNC_SLICE_MS = 20 * 150 ms = 3000 ms in UNETTEST's
-a mode), or the send fails with a plain timeout before the FIN arrives.

(see docs/UNETRTL_TESTING_RU.md, scenario H)

Usage:
    python3 tools/dev/unettest_fin_during_send.py --bind 192.168.7.1 --port 8080
    python3 tools/dev/unettest_fin_during_send.py --status 507 --delay 0.4
"""
from __future__ import annotations

import argparse
import socket
import sys
import time

try:
    import fcntl
    import termios
    FIONREAD = termios.FIONREAD
except (ImportError, AttributeError):       # pragma: no cover - non-BSD hosts
    fcntl = None
    FIONREAD = None

import struct


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", file=sys.stderr, flush=True)


# UNETTEST -a sends ASYNC_PAYLOAD_LEN bytes (src/apps/unettest.asm).
ASYNC_PAYLOAD_LEN = 1200
TCP_MSS = 536
REASONS = {400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
           409: "Conflict", 413: "Payload Too Large", 507: "Insufficient Storage"}


def unread_bytes(conn: socket.socket) -> int | None:
    if fcntl is None or FIONREAD is None:
        return None
    try:
        return struct.unpack("I", fcntl.ioctl(conn, FIONREAD, struct.pack("I", 0)))[0]
    except OSError:
        return None


def serve_one(server: socket.socket, args, requested_rcvbuf: int) -> None:
    conn, addr = server.accept()
    actual_rcvbuf = conn.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    log(f"CONN from {addr[0]}:{addr[1]} (accepted socket rcvbuf={actual_rcvbuf})")
    if actual_rcvbuf >= ASYNC_PAYLOAD_LEN:
        log(f"WARNING: the accepted socket's receive window ({actual_rcvbuf} bytes) holds the "
            f"whole {ASYNC_PAYLOAD_LEN}-byte payload, so every chunk gets acknowledged and the "
            f"FIN will NOT land inside a SEND. The run proves nothing about this fix.")
        if actual_rcvbuf > requested_rcvbuf:
            log(f"WARNING: it also ignored the requested {requested_rcvbuf} bytes -- that is "
                f"TCP receive-buffer auto-tuning. Run: "
                f"sudo sysctl -w net.inet.tcp.doautorcvbuf=0   (restore with =1 afterward)")
    elif actual_rcvbuf <= TCP_MSS:
        log(f"WARNING: the accepted socket's receive window ({actual_rcvbuf} bytes) is not larger "
            f"than TCP_MSS ({TCP_MSS}), so no segment fits and the client sends nothing at all. "
            f"Raise --rcvbuf above {TCP_MSS}.")

    # Do NOT read: let the window fill while the client is mid-transfer.
    log(f"holding {args.delay}s without reading -- the client's last chunk stays unacknowledged")
    time.sleep(args.delay)

    queued = unread_bytes(conn)
    if queued is not None:
        log(f"{queued} bytes queued unread at FIN time (of {ASYNC_PAYLOAD_LEN} the client sends)")
        if queued == 0:
            log("WARNING: nothing arrived yet -- the client had not started sending. "
                "Raise --delay, or start the DSS side after this script is READY.")
        elif queued >= ASYNC_PAYLOAD_LEN:
            log("WARNING: the whole payload already arrived, so the SEND had finished before the "
                "FIN. Lower --rcvbuf (it must stay above TCP_MSS 536) or lower --delay.")

    body = args.body.encode() if args.body else b""
    reason = REASONS.get(args.status, "Error")
    response = (f"HTTP/1.1 {args.status} {reason}\r\n"
                f"Content-Length: {len(body)}\r\n"
                f"Connection: close\r\n\r\n").encode() + body
    conn.sendall(response)
    log(f"sent {len(response)}-byte response: HTTP/1.1 {args.status} {reason}")
    conn.shutdown(socket.SHUT_WR)
    log("FIN sent (shutdown SHUT_WR; socket kept OPEN so the kernel cannot answer with RST)")

    # Keep the window shut a little longer, so the FIN -- not a late ACK --
    # is what ends the client's send.
    time.sleep(args.grace)
    conn.settimeout(args.linger)
    total = 0
    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                log("client closed its side")
                break
            total += len(chunk)
    except socket.timeout:
        log("client still open after --linger; closing anyway")
    log(f"drained {total} bytes after the FIN")
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
    parser.add_argument("--delay", type=float, default=0.6,
                        help="Seconds to wait after accept before answering and sending FIN "
                             "(default: 0.6; must stay well under the DLL's 3 s resume budget).")
    parser.add_argument("--grace", type=float, default=1.0,
                        help="Seconds to keep the window shut after the FIN, so a late ACK cannot "
                             "settle the send instead (default: 1.0).")
    parser.add_argument("--linger", type=float, default=5.0,
                        help="Seconds to wait for the client's own close (default: 5.0).")
    parser.add_argument("--status", type=int, default=400, help="HTTP status to answer with (default: 400).")
    parser.add_argument("--body", default="", help="Optional response body (default: empty).")
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
    log(f"READY bind={args.bind}:{args.port} requested_rcvbuf={args.rcvbuf} "
        f"delay={args.delay}s status={args.status}")

    try:
        while True:
            serve_one(server, args, args.rcvbuf)
            if args.once:
                break
    except KeyboardInterrupt:
        log("interrupted")
    finally:
        server.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
