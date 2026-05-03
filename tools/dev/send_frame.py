#!/usr/bin/env python3
"""
Send a single Ethernet frame to a host interface for stage 5 (NICRX) testing
of the Sprinter RTL8019AS network kit.

Developer-only helper. Not shipped in the distribution package.

Requires `scapy` and pcap-level access on macOS:
    pip install --user scapy
    sudo chmod g+rw /dev/bpf*    # or install Wireshark's ChmodBPF helper

Examples:
    # Smallest case: broadcast 88B5 frame with the default payload.
    sudo python3 tools/dev/send_frame.py --iface en0

    # Unicast to the MAC printed by `rtl8019as: start ... mac=...`.
    sudo python3 tools/dev/send_frame.py --iface en0 \\
        --dst 02:80:19:11:22:33 --payload "SPRINTER NICRX TEST"

    # Higher-throughput burst for OVW debugging (post stage 5).
    sudo python3 tools/dev/send_frame.py --iface en0 --count 16 --interval 0.05
"""
from __future__ import annotations

import argparse
import sys
import time

def _import_scapy():
    try:
        from scapy.all import Ether, sendp  # type: ignore
    except ImportError:
        sys.stderr.write(
            "Error: scapy is not installed. Install with `pip install --user scapy`.\n"
        )
        sys.exit(2)
    return Ether, sendp


DEFAULT_DST = "ff:ff:ff:ff:ff:ff"
DEFAULT_TYPE = 0x88B5            # IEEE Std experimental EtherType, used by NICTX
DEFAULT_PAYLOAD = b"SPRINTER NICRX TEST"


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
        help="Source MAC override; default lets the OS pick the interface MAC.",
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
        help="Payload string (ASCII). Padded to 46 bytes by the OS if shorter.",
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

    Ether, sendp = _import_scapy()

    payload_bytes = args.payload.encode("latin-1")
    eth_kwargs = {"dst": args.dst, "type": args.ethertype}
    if args.src is not None:
        eth_kwargs["src"] = args.src

    frame = Ether(**eth_kwargs) / payload_bytes
    print(
        f"Sending {args.count} frame(s) on {args.iface}: "
        f"dst={args.dst} type=0x{args.ethertype:04X} "
        f"len={len(bytes(frame))} payload={args.payload!r}"
    )

    for i in range(args.count):
        sendp(frame, iface=args.iface, verbose=False)
        if args.interval > 0 and i + 1 < args.count:
            time.sleep(args.interval)

    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
