#!/usr/bin/env python3
"""
Scripted TCP peer for verifying UNETRTL.DLL's CONNECT/SEND/RECV path via
UNETTEST.EXE's default (non -u, non -2) exercise.

UNETTEST's default flow sends exactly one request and reads up to four
reply blocks:

    HEAD / HTTP/1.0\\r\\nHost: <host>\\r\\nConnection: close\\r\\n\\r\\n

A plain ``python3 -m http.server`` (see tools/dev/start_wesrv.sh) already
answers that correctly, so this script exists for the two things a generic
HTTP server can't give you:

  --mode echo (default): behaves like a minimal HTTP/1.0 server, but logs
      "CONN"/"REQ"/"REPLIED" so you can see on the terminal whether the DLL
      ever put a byte on the wire at all. If UNETTEST reports a CONNECT/SEND
      failure and this responder's log stays completely empty (no CONN
      line), the failure is local to the DLL/driver (nothing reached the
      wire), not a network problem -- record it as a finding (see
      docs/UNETRTL_TESTING_RU.md).

  --mode abort: accepts the connection (the TCP handshake completes) and
      then aborts it with an immediate RST before reading anything, giving
      a clean example of a genuine post-CONNECT failure to compare against.
      Use this to confirm your reading of UNETTEST's error output when the
      failure is real network trouble rather than the local-guard bug.

Usage:
    python3 tools/dev/unettest_tcp_probe.py
    python3 tools/dev/unettest_tcp_probe.py --bind 192.168.7.1 --port 80
    python3 tools/dev/unettest_tcp_probe.py --mode abort --once
"""
from __future__ import annotations

import argparse
import socket
import struct
import sys
import time

EXPECTED_FIRST_LINE = b"HEAD / HTTP/1.0\r\n"
REQUEST_TERMINATOR = b"\r\n\r\n"
RECV_TIMEOUT_SECONDS = 5.0


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", file=sys.stderr, flush=True)


def looks_like_unettest_request(data: bytes) -> bool:
    """True if `data` is (a prefix of) UNETTEST's BUILD_REQUEST output."""
    if not data.startswith(EXPECTED_FIRST_LINE):
        return False
    return b"Host: " in data


def request_complete(data: bytes) -> bool:
    return REQUEST_TERMINATOR in data


def build_http_response(status: int = 200, reason: str = "OK", body: bytes = b"") -> bytes:
    header = (
        f"HTTP/1.0 {status} {reason}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("ascii")
    return header + body


def force_reset(sock: socket.socket) -> None:
    """Close `sock` with an abortive (RST-generating) close, like a real
    mid-connection failure -- as opposed to a graceful FIN."""
    sock.setsockopt(
        socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
    )
    sock.close()


def read_request(conn: socket.socket, timeout: float) -> bytes:
    conn.settimeout(timeout)
    data = b""
    try:
        while not request_complete(data) and len(data) < 4096:
            chunk = conn.recv(1024)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    return data


def serve_echo(conn: socket.socket, addr, body: bytes) -> None:
    log(f"CONN from {addr[0]}:{addr[1]}")
    data = read_request(conn, RECV_TIMEOUT_SECONDS)
    if not data:
        log("REQ: nothing received before timeout")
    else:
        matched = looks_like_unettest_request(data)
        log(f"REQ ({len(data)} bytes, matches UNETTEST shape={matched}): {data!r}")
    conn.sendall(build_http_response(body=body))
    conn.close()
    log("REPLIED and closed")


def serve_abort(conn: socket.socket, addr) -> None:
    log(f"CONN from {addr[0]}:{addr[1]} -- aborting with RST before any read")
    force_reset(conn)
    log("RST sent")


def serve(args) -> int:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind((args.bind, args.port))
    except OSError as exc:
        sys.stderr.write(f"bind {args.bind}:{args.port} failed: {exc}\n")
        return 1
    server.listen(1)
    log(f"READY mode={args.mode} bind={args.bind}:{args.port}")

    body = args.body.encode("ascii")
    served = 0
    try:
        while True:
            conn, addr = server.accept()
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            if args.mode == "abort":
                serve_abort(conn, addr)
            else:
                serve_echo(conn, addr, body)
            served += 1
            if args.once or (args.count and served >= args.count):
                break
    except KeyboardInterrupt:
        log("interrupted")
    finally:
        server.close()
    log(f"DONE served={served}")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bind", default="192.168.7.1", help="Bind address (default: 192.168.7.1).")
    parser.add_argument("--port", type=int, default=80, help="Bind port (default: 80, UNETTEST's DEF_PORT).")
    parser.add_argument("--mode", choices=("echo", "abort"), default="echo")
    parser.add_argument("--body", default="unettest-tcp-probe\n", help="Response body for --mode echo.")
    parser.add_argument("--once", action="store_true", help="Serve exactly one connection, then exit.")
    parser.add_argument("--count", type=int, default=0, help="Serve exactly N connections, then exit (0 = unbounded).")
    args = parser.parse_args(argv)
    return serve(args)


if __name__ == "__main__":
    sys.exit(main())
