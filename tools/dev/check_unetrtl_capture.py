#!/usr/bin/env python3
"""Check a Battleship n3 Ethernet pcap; no third-party modules required.

The first stream byte is mode S. The following 48800 bytes must hash to the
stand's counting-pattern digest. Duplicate data, including persist probes,
is reassembled by sequence. Invoke with the pcap path; emits a JSON report.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path


def check(path):
    raw = Path(path).read_bytes()
    magic = raw[:4]
    endian = '<' if magic in (b'\xd4\xc3\xb2\xa1', b'\x4d\x3c\xb2\xa1') else '>'
    if magic not in (b'\xd4\xc3\xb2\xa1', b'\xa1\xb2\xc3\xd4', b'\x4d\x3c\xb2\xa1', b'\xa1\xb2\x3c\x4d'):
        raise ValueError('expected classic pcap')
    if struct.unpack_from(endian + 'I', raw, 20)[0] != 1:
        raise ValueError('expected Ethernet capture')
    packets = []
    pos = 24
    while pos < len(raw):
        sec, frac, size, _ = struct.unpack_from(endian + 'IIII', raw, pos)
        frame = raw[pos + 16:pos + 16 + size]
        pos += 16 + size
        if frame[12:14] != b'\x08\x00' or len(frame) < 54 or frame[23] != 6:
            continue
        iplen = (frame[14] & 15) * 4
        t = 14 + iplen
        sport, dport, seq, ack = struct.unpack_from('!HHII', frame, t)
        if 7777 not in (sport, dport):
            continue
        total = struct.unpack_from('!H', frame, 16)[0]
        header = (frame[t + 12] >> 4) * 4
        packets.append(dict(time=sec + frac / (1e9 if magic in (b'\x4d\x3c\xb2\xa1', b'\xa1\xb2\x3c\x4d') else 1e6),
                            client=dport == 7777, seq=seq, ack=ack,
                            flags=frame[t + 13], window=struct.unpack_from('!H', frame, t + 14)[0],
                            payload=frame[t + header:14 + total]))
    base = None
    stream = {}
    window = None
    zero_full = []
    probes = []
    zero_acks = 0
    client_acks = 0
    fins = 0
    rsts = 0
    final_ack = 0
    for p in packets:
        if not p['client']:
            window = p['window']
            if base is not None:
                final_ack = max(final_ack, (p['ack'] - base) & 0xffffffff)
            continue
        if p['flags'] & 2:
            base = (p['seq'] + 1) & 0xffffffff
            continue
        if base is None:
            raise ValueError('capture is missing the handshake')
        data = p['payload']
        if data:
            offset = (p['seq'] - base) & 0xffffffff
            if offset > 48801:
                raise ValueError('sequence hole outside expected stream')
            for i, byte in enumerate(data):
                if offset + i in stream and stream[offset + i] != byte:
                    raise ValueError('conflicting retransmission')
                stream[offset + i] = byte
            if window == 0:
                if len(data) > 1:
                    zero_full.append([p['time'], offset, len(data)])
                else:
                    probes.append(p['time'])
        elif p['flags'] == 16:
            client_acks += 1
            zero_acks += window == 0
        fins += bool(p['flags'] & 1)
        rsts += bool(p['flags'] & 4)
    data = bytes(stream[i] for i in range(len(stream)))
    digest = hashlib.sha256(data[1:]).hexdigest()
    result = dict(packets=len(packets), bytes=len(data) - 1, sha256=digest,
                  zero_window_probes=len(probes), probe_intervals_s=[round(b - a, 3) for a, b in zip(probes, probes[1:])],
                  full_data_in_zero_window=zero_full, empty_client_acks=client_acks,
                  empty_client_acks_in_zero_window=zero_acks, client_fins=fins, client_rsts=rsts,
                  final_ack_offset=final_ack)
    result['passed'] = (data[:1] == b'S' and len(data) == 48801 and digest.startswith('acc7ecb1abac0482')
                        and not zero_full and zero_acks == 0 and client_acks <= 4 and fins == 1 and rsts == 0
                        and final_ack >= 48802)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pcap')
    args = parser.parse_args()
    report = check(args.pcap)
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report['passed'] else 1)
