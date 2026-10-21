#!/usr/bin/env python3
"""Extend only BSTAND's consumer-side SEND deadline for long persist tests.

Original BSTAND permits 20 seconds before abandoning an AGAIN transaction
and changing its source buffer. A 30-second peer pause needs a longer caller
lifetime. Patch a copy, keeping addresses and MAME symbols unchanged. The
input EXE and the sibling Battleship project are never modified.
"""
import argparse
import hashlib
import json
import re
import struct
from pathlib import Path


def prepare(exe, symbols, output, seconds=60):
    syms = dict((m[1], int(m[2], 16)) for m in re.finditer(
        r'^(\S+): EQU 0x([0-9A-Fa-f]+)$', Path(symbols).read_text(), re.M))
    original = Path(exe).read_bytes()
    pattern = (b'\xf3\x2a' + struct.pack('<H', syms['ctc_ticks']) + b'\x11\xe8\x03\x19\x22'
               + struct.pack('<H', syms['nt_end']) + b'\xfb')
    if original.count(pattern) != 1:
        raise ValueError('expected exactly one nt_send 20-second deadline')
    offset = original.index(pattern) + 5
    patched = bytearray(original)
    struct.pack_into('<H', patched, offset, seconds * 50)
    Path(output).write_bytes(patched)
    return dict(original_sha256=hashlib.sha256(original).hexdigest(),
                patched_sha256=hashlib.sha256(patched).hexdigest(),
                file_offset=offset, original_ticks=1000, patched_ticks=seconds * 50,
                unchanged_length=len(original) == len(patched))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('exe')
    parser.add_argument('symbols')
    parser.add_argument('output')
    args = parser.parse_args()
    print(json.dumps(prepare(args.exe, args.symbols, args.output), indent=2))
