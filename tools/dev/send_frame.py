#!/usr/bin/env python3
"""
Send a single Ethernet frame to a host interface for stage 5 (NICRX) testing
of the Sprinter RTL8019AS network kit.

Developer-only helper.  Not shipped in the distribution package.

No third-party modules.  Frames go out through the raw link layer directly:
/dev/bpf on macOS, AF_PACKET on Linux.  Both need root, so run under sudo
(on macOS you can instead `sudo chmod g+rw /dev/bpf*`, or install
Wireshark's ChmodBPF helper, and drop the sudo).

Examples:
    # Default: unicast 88B5 frame addressed to the driver's PAR
    # (02:80:19:11:22:33), with payload "SPRINTER NICRX TEST".
    sudo python3 tools/dev/send_frame.py --iface en0

    # Broadcast variant (only useful when the driver has RCR.AB set).
    sudo python3 tools/dev/send_frame.py --iface en0 \\
        --dst ff:ff:ff:ff:ff:ff

    # Higher-throughput burst for OVW debugging (post stage 5).
    sudo python3 tools/dev/send_frame.py --iface en0 --count 16 --interval 0.05
"""
from __future__ import annotations

import argparse
import ctypes
import fcntl
import os
import platform
import re
import socket
import struct
import subprocess
import sys
import time

# NICRX uses RCR=0 (physical match only), so the default destination
# is the locally administered MAC the driver programs into PAR0..5.
# Use --dst ff:ff:ff:ff:ff:ff to fall back to broadcast when needed.
DEFAULT_DST = "02:80:19:11:22:33"
DEFAULT_TYPE = 0x88B5            # IEEE Std experimental EtherType, used by NICTX
DEFAULT_PAYLOAD = b"SPRINTER NICRX TEST"

# Minimum Ethernet frame without FCS.  A real NIC pads runts in hardware,
# but a virtual interface (feth, tap) may hand the frame over as-is, and
# the DP8390 drops runts unless RCR.AR is set -- which NICRX does not do.
# Padding here keeps the test deterministic on both.
ETH_MIN_FRAME = 60

# Darwin ioctls, from <net/bpf.h>:
#   BIOCSETIF     = _IOW('B', 108, struct ifreq)   ifreq is 32 bytes
#   BIOCSHDRCMPLT = _IOW('B', 117, u_int)
BIOCSETIF = 0x8020426C
BIOCSHDRCMPLT = 0x80044275


def parse_mac(value: str) -> str:
    parts = value.split(":")
    if len(parts) != 6 or any(len(p) != 2 for p in parts):
        raise argparse.ArgumentTypeError(f"invalid MAC address: {value!r}")
    try:
        for p in parts:
            int(p, 16)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid MAC address: {value!r}") from exc
    return value.lower()


def mac_bytes(value: str) -> bytes:
    return bytes(int(p, 16) for p in value.split(":"))


def parse_ethertype(value: str) -> int:
    try:
        result = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"invalid EtherType (use decimal or 0x..): {value!r}"
        ) from exc
    if not 0 <= result <= 0xFFFF:
        raise argparse.ArgumentTypeError(f"EtherType out of range: {value!r}")
    return result


def iface_mac(iface: str) -> bytes:
    """The interface's own hardware address.

    Needed because we always write header-complete frames (see _open_bpf),
    so nothing else fills the source field in.
    """
    if platform.system() == "Linux":
        try:
            with open(f"/sys/class/net/{iface}/address") as fh:
                return mac_bytes(fh.read().strip())
        except OSError as exc:
            raise RuntimeError(f"cannot read MAC of {iface}: {exc}") from exc
    try:
        out = subprocess.run(
            ["ifconfig", iface],
            capture_output=True, text=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        raise RuntimeError(f"cannot read MAC of {iface}: {exc}") from exc
    found = re.search(r"(?:ether|lladdr)\s+([0-9a-fA-F:]{17})", out)
    if not found:
        raise RuntimeError(
            f"{iface} has no hardware address (not an Ethernet interface?) "
            "-- pass --src explicitly"
        )
    return mac_bytes(found.group(1).lower())


class RawSender:
    """Minimal raw link-layer sender: write() takes a complete frame."""

    def __init__(self, iface: str) -> None:
        self.iface = iface
        system = platform.system()
        if system == "Darwin":
            self._open_bpf(iface)
        elif system == "Linux":
            self._open_packet(iface)
        else:
            raise RuntimeError(f"unsupported platform: {system}")

    def _open_bpf(self, iface: str) -> None:
        self._sock = None
        last_err: OSError | None = None
        for n in range(256):
            path = f"/dev/bpf{n}"
            try:
                self._fd = os.open(path, os.O_RDWR)
            except FileNotFoundError:
                break
            except PermissionError as exc:
                raise RuntimeError(
                    f"{path}: permission denied -- run under sudo, or "
                    "`sudo chmod g+rw /dev/bpf*`"
                ) from exc
            except OSError as exc:          # EBUSY: taken by tcpdump/MAME/...
                last_err = exc
                continue
            break
        else:
            raise RuntimeError(f"no free /dev/bpf* device: {last_err}")

        # struct ifreq: 16-byte name + 16-byte union.
        ifreq = struct.pack("16s16x", iface.encode())
        try:
            fcntl.ioctl(self._fd, BIOCSETIF, ifreq)
        except OSError as exc:
            os.close(self._fd)
            raise RuntimeError(f"BIOCSETIF {iface}: {exc}") from exc
        # Header-complete: the frame we write goes out verbatim.  Always
        # 1 -- the alternative, letting the kernel fill in the source MAC,
        # fails on Darwin with ENXIO ("Device not configured") for
        # DLT_EN10MB writes, so the caller supplies the source instead.
        fcntl.ioctl(self._fd, BIOCSHDRCMPLT, struct.pack("I", 1))

    def _open_packet(self, iface: str) -> None:
        self._fd = None
        self._sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
        self._sock.bind((iface, 0))

    def send(self, frame: bytes) -> None:
        if self._sock is not None:
            self._sock.send(frame)
        else:
            os.write(self._fd, frame)

    def close(self) -> None:
        if self._sock is not None:
            self._sock.close()
        elif self._fd is not None:
            os.close(self._fd)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send a test Ethernet frame for NICRX/NICTX validation.",
    )
    parser.add_argument(
        "--iface",
        required=True,
        help="Host network interface name (see `mame -listnetwork`, `ifconfig`).",
    )
    parser.add_argument(
        "--dst",
        type=parse_mac,
        default=DEFAULT_DST,
        help=f"Destination MAC (default: {DEFAULT_DST}).",
    )
    parser.add_argument(
        "--src",
        type=parse_mac,
        default=None,
        help="Source MAC override; default is the interface's own MAC.",
    )
    parser.add_argument(
        "--type",
        dest="ethertype",
        type=parse_ethertype,
        default=DEFAULT_TYPE,
        help=f"EtherType (default: 0x{DEFAULT_TYPE:04X}).",
    )
    parser.add_argument(
        "--payload",
        default=DEFAULT_PAYLOAD.decode("ascii"),
        help="Payload string (ASCII).",
    )
    parser.add_argument(
        "--no-pad",
        action="store_true",
        help=f"Send the frame as built instead of padding to {ETH_MIN_FRAME} bytes.",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=1,
        help="Number of frames to send (default: 1).",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=0.0,
        help="Seconds to sleep between frames (default: 0).",
    )
    args = parser.parse_args()

    payload = args.payload.encode("latin-1")
    try:
        src = mac_bytes(args.src) if args.src else iface_mac(args.iface)
    except RuntimeError as exc:
        sys.stderr.write(f"Error: {exc}\n")
        return 2
    frame = mac_bytes(args.dst) + src + struct.pack("!H", args.ethertype) + payload
    if not args.no_pad and len(frame) < ETH_MIN_FRAME:
        frame += b"\x00" * (ETH_MIN_FRAME - len(frame))

    try:
        sender = RawSender(args.iface)
    except RuntimeError as exc:
        sys.stderr.write(f"Error: {exc}\n")
        return 2

    print(
        f"Sending {args.count} frame(s) on {args.iface}: "
        f"src={src.hex(':')} dst={args.dst} type=0x{args.ethertype:04X} "
        f"len={len(frame)} payload={args.payload!r}"
    )
    try:
        for i in range(args.count):
            sender.send(frame)
            if args.interval > 0 and i + 1 < args.count:
                time.sleep(args.interval)
    except OSError as exc:
        sys.stderr.write(f"Error: send failed on {args.iface}: {exc}\n")
        return 3
    finally:
        sender.close()

    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
