#!/usr/bin/env python3
"""Pure standard-library checks for unettest_tcp_probe.py's framing logic.

No network access and no root required -- exercises only the request
matcher and response builder against byte strings shaped exactly like
UNETTEST.EXE's BUILD_REQUEST output (src/apps/unettest.asm).
"""

import unettest_tcp_probe as probe


def main() -> None:
    request = b"HEAD / HTTP/1.0\r\nHost: 192.168.7.1\r\nConnection: close\r\n\r\n"
    assert probe.looks_like_unettest_request(request)
    assert probe.request_complete(request)

    partial = b"HEAD / HTTP/1.0\r\nHost: 192.168.7.1\r\n"
    assert probe.looks_like_unettest_request(partial)
    assert not probe.request_complete(partial)

    assert not probe.looks_like_unettest_request(b"GET / HTTP/1.0\r\n\r\n")
    assert not probe.looks_like_unettest_request(b"HEAD / HTTP/1.0\r\n\r\n")  # no Host:
    assert not probe.looks_like_unettest_request(b"")

    response = probe.build_http_response(body=b"hello")
    assert response.startswith(b"HTTP/1.0 200 OK\r\n")
    assert b"Content-Length: 5\r\n" in response
    assert b"Connection: close\r\n" in response
    assert response.endswith(b"\r\n\r\nhello")

    empty_response = probe.build_http_response()
    assert b"Content-Length: 0\r\n" in empty_response
    assert empty_response.endswith(b"\r\n\r\n")

    print("unettest_tcp_probe: request matcher and response framing checks passed")


if __name__ == "__main__":
    main()
