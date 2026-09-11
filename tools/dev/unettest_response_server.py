#!/usr/bin/env python3
"""Deterministic bytes for UNETTEST -r SLICE HOST PORT (not TCP segmentation).

No authentication or WebDAV service is needed. Body byte i is i & 255.
Use packet capture / the EXE harness to establish TCP segment geometry.
"""
import argparse
import socket
import zlib

HEADER = b"HTTP/1.1 200 OK\r\nContent-Length: 8192\r\n\r\n"
RESPONSE = HEADER + bytes(range(256)) * 32


def serve_request(conn):
    conn.settimeout(10)
    request = bytearray()
    while b"\r\n\r\n" not in request:
        block = conn.recv(4096)
        if not block:
            raise ValueError("peer closed before request headers")
        request.extend(block)
        if len(request) > 16384:
            raise ValueError("request headers exceed 16 KiB")
    if not request.startswith(b"PROPFIND "):
        raise ValueError("expected PROPFIND")
    if b"content-length: 0\r\n" not in request.lower():
        raise ValueError("expected an empty request body")
    conn.sendall(RESPONSE)
    conn.shutdown(socket.SHUT_WR)
    return len(request)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    print(f"response length={len(RESPONSE)} body=8192 crc32={zlib.crc32(RESPONSE):08X}", flush=True)
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((args.bind, args.port))
        listener.listen(2)
        print(f"listening on {listener.getsockname()}", flush=True)
        while True:
            conn, addr = listener.accept()
            with conn:
                try:
                    size = serve_request(conn)
                    print(f"{addr}: PROPFIND {size} bytes, response sent", flush=True)
                except (OSError, ValueError) as exc:
                    print(f"{addr}: {exc}", flush=True)
            if args.once:
                break


if __name__ == "__main__":
    main()
