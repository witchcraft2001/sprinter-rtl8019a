#!/usr/bin/env python3
"""Check complete request framing and byte-exact response/EOF."""
import socket
import threading
import unittest
import zlib
from unettest_response_server import RESPONSE, serve_request


class ResponseServerTest(unittest.TestCase):
    def test_fragmented_request_and_eof(self):
        a, b = socket.socketpair()
        errors = []

        def server():
            with a:
                try:
                    serve_request(a)
                except Exception as exc:
                    errors.append(exc)

        thread = threading.Thread(target=server)
        thread.start()
        with b:
            b.settimeout(5)
            b.sendall(b"PROPFIND / HTTP/1.1\r\nContent-Length: 0\r\n")
            b.sendall(b"\r\n")
            received = bytearray()
            while chunk := b.recv(257):
                received.extend(chunk)
        thread.join(timeout=5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(received, RESPONSE)
        self.assertEqual(len(received), 8233)
        self.assertEqual(zlib.crc32(received), 0x62763860)

    def test_rejects_non_propfind(self):
        a, b = socket.socketpair()
        with a, b:
            b.sendall(b"GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
            with self.assertRaisesRegex(ValueError, "expected PROPFIND"):
                serve_request(a)


if __name__ == "__main__":
    unittest.main()
