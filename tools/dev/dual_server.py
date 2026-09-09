#!/usr/bin/env python3
"""Two-channel TCP peer for ``UNETTEST -2``.

The control socket echoes a reply while the data socket is streaming a
continuous 0..255 counter.  This makes UNETTEST verify that traffic arriving
for one UNET channel is not lost while the other channel is being read.
"""

import argparse
import socket
import sys
import time


def log(message):
    print(message, file=sys.stderr, flush=True)


def listener(host, port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind((host, port))
    except OSError as exc:
        # Almost always an earlier run of this script still holding the
        # socket.  Suspending a responder with Ctrl+Z does NOT release it,
        # and a stopped process ignores SIGTERM until it is resumed, so the
        # hint below spells out the one command that actually works.
        log(f"bind {host}:{port} failed: {exc}")
        log(f"Find the holder:  lsof -nP -iTCP:{port}")
        log("If it is a suspended responder of your own (STAT 'T'), end it with")
        log("kill -9 <pid>  -- plain kill does nothing to a stopped process.")
        log("Use Ctrl+C rather than Ctrl+Z to stop responders in the future.")
        raise SystemExit(1)
    server.listen(1)
    return server


def counter_block(start, size):
    return bytes((start + index) & 0xFF for index in range(size))


def serve(host, control_port, data_port, count, chunk, rate, reply, lockstep):
    control_server = listener(host, control_port)
    data_server = listener(host, data_port)
    log(
        f"UNET dual server: control {host}:{control_port}, "
        f"data {host}:{data_port}, {count} bytes, "
        f"reply {len(reply)} bytes"
    )

    while True:
        control, address = control_server.accept()
        control.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        log(f"control connected from {address[0]}:{address[1]}")
        data, address = data_server.accept()
        data.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        log(f"data connected from {address[0]}:{address[1]}")

        pending = bytearray()
        sent = 0
        replied = False
        # A real FTP data transfer starts after a control command.  Waiting
        # here also prevents an unlimited-rate data sender from filling the
        # NIC FIFO before the client's control SEND can reach its own ACK.
        # The two modes differ only in reply timing: lockstep answers now;
        # the default answers halfway through the ensuing data stream.
        control.settimeout(5.0)
        try:
            block = control.recv(4096)
            if block:
                pending.extend(block)
                log(f"control command received ({len(block)} bytes)")
                if lockstep:
                    control.sendall(reply)
                    replied = True
                    log(f"lockstep: replied immediately ({len(reply)} bytes)")
        except socket.timeout:
            log("no control command arrived within 5 s")
        control.setblocking(False)
        try:
            while sent < count:
                size = min(chunk, count - sent)
                data.sendall(counter_block(sent, size))
                sent += size
                try:
                    block = control.recv(4096)
                    if block:
                        pending.extend(block)
                except (BlockingIOError, InterruptedError):
                    pass

                if pending and not replied and sent >= count // 2:
                    control.sendall(reply)
                    replied = True
                    log(
                        f"control reply sent after {sent} data bytes "
                        f"({len(reply)} bytes)"
                    )
                if rate:
                    time.sleep(size / rate)

            data.shutdown(socket.SHUT_WR)
            log(f"data channel closed after {sent} bytes")
            if not replied:
                control.sendall(reply)
                log(f"control reply sent after transfer ({len(reply)} bytes)")
            time.sleep(1)
        except (BrokenPipeError, ConnectionResetError, OSError) as error:
            log(f"client disconnected: {error}")
        finally:
            control.close()
            data.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--control-port", type=int, default=9099)
    parser.add_argument("--data-port", type=int, default=9100)
    parser.add_argument("--count", type=int, default=4096)
    parser.add_argument("--chunk", type=int, default=536)
    parser.add_argument("--rate", type=int, default=4000)
    # The control reply's LENGTH is a diagnostic knob: if UNETTEST's data
    # byte count exceeds --count by exactly this many bytes, the control
    # channel's payload is leaking into the data channel's stream.  Vary
    # it to tell that apart from a duplicate inside the data stream
    # itself, whose size would not track this option.
    parser.add_argument("--reply", default="CONTROL REPLY DURING TRANSFER")
    # Reply to the control command immediately instead of mid-transfer, so
    # the reply piggybacks on that command's ACK.  This is the FTP
    # USER/PASS shape and the one that exercises SEND's pend-guard
    # ordering; the default mid-transfer reply exercises the
    # foreign-channel receive path instead.  Both are worth running.
    parser.add_argument(
        "--lockstep", action="store_true",
        help="Answer the control command immediately instead of mid-stream, to try to make "
             "the reply ride the ACK of that command (UNETTEST then prints 'reply rode our "
             "ACK - SEND guard path exercised'). Best effort only: this controls when the "
             "APPLICATION replies, not when the KERNEL acknowledges. If the host stack ACKs "
             "before Python gets to reply, UNETTEST prints 'not hit' and the branch was "
             "simply never entered -- not a failure. Measured on macOS 2026-09-09: 'not hit' "
             "either way, including with net.inet.tcp.delayed_ack=1, so do not burn time "
             "chasing it from a macOS host (see docs/UNETRTL_TESTING_RU.md scenario C).")
    args = parser.parse_args()
    if min(args.control_port, args.data_port, args.count, args.chunk) <= 0:
        parser.error("ports, count and chunk must be positive")
    if args.rate < 0:
        parser.error("rate must be zero or positive")
    try:
        serve(
            args.host,
            args.control_port,
            args.data_port,
            args.count,
            args.chunk,
            args.rate,
            args.reply.encode("ascii", "replace") + b"\r\n",
            args.lockstep,
        )
    except KeyboardInterrupt:
        log("stopped")


if __name__ == "__main__":
    main()
