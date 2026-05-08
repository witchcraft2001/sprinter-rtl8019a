#!/usr/bin/env python3
"""Tiny HTTP server that exercises WGET's 3xx redirect path.

Listens on 192.168.7.1:8080 and exposes:

  GET /redir-abs    -> 302, Location: http://192.168.7.1/im2.txt
  GET /redir-rel    -> 302, Location: /im2.txt   (path-only redirect)
  GET /redir-https  -> 302, Location: https://example.com/x  (must
                       be reported as "https not supported")
  GET /redir-loop   -> 302, Location: /redir-loop (exercises hop cap)
  GET /            -> short HTML, 200

Run alongside the existing dnsmasq + main HTTP server (which serves
/im2.txt etc.).  On the Sprinter side:

    WGET http://192.168.7.1:8080/redir-abs
    WGET http://192.168.7.1:8080/redir-rel  -- but note the rel URL
    WGET http://192.168.7.1:8080/redir-https
    WGET http://192.168.7.1:8080/redir-loop
"""

from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8080

REDIRECTS = {
    "/redir-abs":   "http://192.168.7.1/im2.txt",
    "/redir-rel":   "/im2.txt",
    "/redir-https": "https://example.com/never-reached",
    "/redir-loop":  "/redir-loop",
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        target = REDIRECTS.get(self.path)
        if target is not None:
            self.send_response(302, "Found")
            self.send_header("Location", target)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/":
            body = b"<html>redirect harness; try /redir-abs etc.</html>\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def log_message(self, fmt, *args):
        # quieter: one line per request
        print("[%s] %s" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    addr = ("192.168.7.1", PORT)
    print("Redirect harness on http://%s:%d" % addr)
    HTTPServer(addr, Handler).serve_forever()
