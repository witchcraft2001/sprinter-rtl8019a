#!/usr/bin/env python3
"""
Packet-level probe for UNETRTL.DLL's LISTEN re-arm (UNETTEST -l).

Same two back-to-back dials as unettest_listen_timing.py, but with a
tcpdump running alongside, so the second (re-armed) accept can be judged
from the wire instead of from the screen.  What the capture answers:

  * did the Sprinter answer the second SYN with a SYN+ACK, and when;
  * did our final ACK reach it -- if the Sprinter keeps RETRANSMITTING
    the SYN+ACK, it never accepted that ACK and is stuck in SYN_RCVD;
  * how long the Sprinter stayed in the accept loop -- the last frame it
    emits marks the moment it gave up, which settles "instant vs 30 s"
    without relying on eyeballing the DSS screen.

tcpdump needs read access to /dev/bpf* (same requirement as
tools/dev/send_frame.py); run with sudo if the BPF nodes are not opened
up for your user.

Usage:
    python3 tools/dev/unettest_listen_capture.py --iface feth1 \
        --host 192.168.7.2 --port 9000
"""
from __future__ import annotations

import argparse
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

DEFAULT_MESSAGE = b"hello from unettest_listen_capture\n"


def dial(host: str, port: int, message: bytes, timeout: float, label: str, t0: float) -> None:
    """One dial; timestamps are relative to the shared capture start."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
    except OSError as exc:
        print(f"[{label}] t=+{time.monotonic() - t0:.3f}s connect FAILED: {exc}")
        return
    print(f"[{label}] t=+{time.monotonic() - t0:.3f}s connected")
    try:
        sock.sendall(message)
    except OSError as exc:
        print(f"[{label}] t=+{time.monotonic() - t0:.3f}s send FAILED: {exc}")
        sock.close()
        return
    try:
        reply = sock.recv(4096)
    except (socket.timeout, OSError):
        reply = b""
    print(f"[{label}] t=+{time.monotonic() - t0:.3f}s reply: {reply!r}")
    sock.close()
    print(f"[{label}] t=+{time.monotonic() - t0:.3f}s closed")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--iface", required=True,
                        help="Host interface MAME's pcap backend is attached to (e.g. feth1).")
    parser.add_argument("--host", default="192.168.7.2")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--timeout", type=float, default=35.0,
                        help="Per-dial timeout; keep above the 30 s nominal DSS accept budget.")
    parser.add_argument("--linger", type=float, default=5.0,
                        help="Extra seconds to keep capturing after the second dial returns, "
                             "so a late SYN+ACK retransmission or give-up is still recorded.")
    parser.add_argument("--keep", action="store_true",
                        help="Keep the raw .pcap instead of deleting it.")
    args = parser.parse_args(argv)

    tcpdump = shutil.which("tcpdump")
    if tcpdump is None:
        print("Error: tcpdump not found in PATH", file=sys.stderr)
        return 1

    pcap_fd, pcap_path = tempfile.mkstemp(prefix="unettest-listen-", suffix=".pcap")
    os.close(pcap_fd)
    expr = f"host {args.host} and (tcp port {args.port} or arp)"
    cap = subprocess.Popen([tcpdump, "-i", args.iface, "-n", "-p", "-U", "-s", "128",
                            "-w", pcap_path, expr],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    # tcpdump needs a moment to open the BPF device and install the filter;
    # dialing before that silently loses the first handshake.
    time.sleep(1.5)
    if cap.poll() is not None:
        err = cap.stderr.read().decode("utf-8", "replace").strip()
        print(f"Error: tcpdump exited immediately: {err}", file=sys.stderr)
        os.unlink(pcap_path)
        return 1

    t0 = time.monotonic()
    try:
        dial(args.host, args.port, DEFAULT_MESSAGE, args.timeout, "dial-1", t0)
        print(f"[gap] t=+{time.monotonic() - t0:.3f}s dialing again immediately")
        dial(args.host, args.port, DEFAULT_MESSAGE, args.timeout, "dial-2", t0)
        print(f"[linger] t=+{time.monotonic() - t0:.3f}s capturing {args.linger:.1f}s more")
        time.sleep(args.linger)
    finally:
        cap.send_signal(signal.SIGINT)
        cap.wait(timeout=10)

    print("\n=== capture (relative timestamps) ===")
    subprocess.run([tcpdump, "-n", "-ttt", "-r", pcap_path],
                   stderr=subprocess.DEVNULL, check=False)
    if args.keep:
        print(f"\npcap kept at {pcap_path}")
    else:
        os.unlink(pcap_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
