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
    server.bind((host, port))
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
    parser.add_argument("--lockstep", action="store_true")
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
