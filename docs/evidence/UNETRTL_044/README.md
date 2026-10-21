# UNETRTL 0.4.4 review regression fixes

Raw logs, captures, JSON reports and symbol maps mentioned below are local
run outputs and are not stored in Git. This file preserves the acceptance
summary; see the [artifact policy](../README.md).

DLL: **18157 bytes**, SHA-256
`5da40142cba600571a1be0c0cf2a64090935a267352bad22e8557ae351601b47`.
Fixed L1 date: 2026-10-20. The hot L1 body is 14530 bytes, **5 bytes free**
under the unchanged 0x38C7 limit. No extra page was added. `dll.json` records
root/build/ZIP/FAT12 byte identity and the unchanged optional cold blob.
All 32 EXEs matched before the version bump; afterwards their only differences
are substitution of version strings 0.4.3 -> 0.4.4. The staged changes were
preserved; no commit/tag was created.

## Actual DLL regressions

`make test-host package image` passed **545 actual-EXE checks**, including
**180 DLL cases**, 38 added for this review. See `host.txt`. Every new case
executes the assembled DLL through libman with a strict Z80/ISA/NIC model;
TCP, DNS and UNET assembly are not mocked.

1. With SENDSLICE=0 a foreign UDP head is committed/dropped, the UDP channel
   gets a sticky LOST indication, and the same TCP wait continues. There is
   no AGAIN or parked APEND transaction. With a nonzero slice, UDP remains
   protected for its owner's RECV and SEND returns AGAIN. Tests verify both
   policies and successful following SEND, plus UDP SEND and full-IY UDP
   RECV while TCP is suspended.
2. Each DLL DNS attempt rebuilds from the saved hostname and original XID.
   RX scratch may overwrite the old query; it is never a retransmit source.
   Tests drop one/two requests, receive unrelated broadcasts and compare
   every query byte, including checksums/XID, for short and 127-character
   names at both DLL windows. The EXE resolver path is byte-identical.
3. DLL RECV reports F_CLOSED for the FIN being processed, rather than for
   every subsequent ACK in CLOSE_WAIT. Tests cover both a partial ACK of a
   536-byte flight and a full ACK of a 163-byte window-limited flight,
   followed by zero-window probes and resumed tail transmission. Blocking
   and sliced SEND both deliver all 1200 source bytes, with exact DE.
   `half-close-043-before.txt` independently runs these eight vectors against
   the reviewed 0.4.3 DLL using its archived symbol map: each returned CLOSED
   at byte 699. The corrected vectors complete successfully.

The first version of that new test used a Buffer-only method on the peer's
Array payload; that test callback was corrected before the controlled 0.4.3
comparison recorded here. Its failure is not counted as a DLL regression.

Additional review cases now covered:

- FINI cancels a suspended SEND before closing, including a zero-window wait
  where SND_UNA == SND_NXT and no payload was sent. It sends abort RST, not EOF.
- CLOSE/NETDONE drops a foreign UDP head and continues the bounded
  FIN wait. A still-open UDP channel reports LOST; NETDONE frees both. A UDP
  head cannot cause an immediate TIMEOUT without retry/wait.
- Public peer RST returns already copied bytes with CLOSED and actual DE,
  releases remaining queued data and the slot, and prevents a following SEND.
  The foreign RST path uses the same release/queue cleanup and rearms LISTEN;
  STATUS cannot retain an inaccessible RXPEND. Both empty/buffered accepted
  channels are tested.
- CLOSE aborts with RST if unread data was queued before closing or arrives
  while awaiting the FIN ACK, including a data/FIN-bearing ACK covering our
  own FIN. The peer is told those bytes were not read by the application.
- Three FIN transmissions means the first transmission plus two retries.
  UDP SEND during TCP AGAIN and the UDP RECV's independent IY wait are now
  explicit in the documentation.

The hot scratch shrank from 96 to 60 bytes, enough for TCP SYN/ACK/FIN,
UDP and padded ARP headers. DNS, fixed-size PING construction and INIT may
borrow adjacent RX storage before polling. DNS rebuilds on every retry;
ARP already rebuilt retries; PING does not retransmit this shared image.
The diagnostic buffer is 64 bytes; the complete longest line plus NUL needs
63. Tests exercise that boundary and guard the following TX byte. TCP queues,
maximum UDP payload and other features retain their capacities.

## MAME acceptance and scope

```sh
make test-host package image
PYTHONDONTWRITEBYTECODE=1 python3 tools/dev/run_battleship_n3.py \
  --cases n2 n4 n7 n3
```

The runner copies the sibling stand into `build/unet044-battleship`; it
never edits the sibling. It uses the existing feth0/feth1 pcap setup and a
private DSS disk diff. For n3, only the copy's consumer SEND deadline is
extended from 20 to 60 seconds; the exact bytes and EXE hashes are recorded
in `stand-patch.json`. SENDSLICE=50 and payload generation are unchanged.

The new edge cases above are verified by the actual-DLL host harness. The
standard Battleship cases do not exercise blocking SEND/UDP, long DNS retry
or partial ACK after peer FIN. MAME n2/n4/n7 are regression smoke checks;
n3 independently checks a live network, persist probes, resume geometry,
stream integrity and client FIN acknowledgement for pauses 6/15/30 seconds.

The independent expected n3 payload is 48800 bytes:
`(i*13+seed)&255`, i=0..243, seed=200 down through 1. Its full SHA-256 is
`acc7ecb1abac048285733e4caaac6a80a48397a91a1679dc2ada20741b16fa75`.
Captures are reassembled by sequence; conflicting retransmissions, full
payload sent into zero windows, empty ACKs in zero windows, missing bytes
and an unacknowledged client FIN fail acceptance.

## Preserved limits and platform finding

The released channel still has no TIME_WAIT receiver: a peer FIN arriving
only after ACK of our FIN and local release is ignored. That older limitation
was not changed. Timeouts still count poll/work iterations; the measured
stand factor (~1.35) is documented, not presented as a clock guarantee.
The frozen Wi-Fi-origin unet.inc mirror and other backends were not edited;
RTL behavior is described in English UNETRTL.md and the Russian API/testing
documents, rather than inferred from UNET509B's backend-specific comments.

The stand maintainer traced the intermittent CBL gaps to MAME's shared
external/internal Z84C015 IRQ0 state, observed with both cards. This change
makes no ISA/IFF/IRQ modification. The final n7 report records its measured
refill result; a passing n7 is not claimed as an emulator IRQ fix.

## Final results

MAME n2, n4 and n7: **PASS**. Final n7: IN_NET_UNDER=0,
IN_NET_DMAX=554 CTC counts; no IRQ change is inferred from this run.

| Peer pause | MAME + capture | AGAIN returns | Payload bytes | Zero-window probes | Maximum SEND |
| --- | --- | ---: | ---: | ---: | ---: |
| 6 s | PASS | 59 | 48800 | 1 | 71 ms |
| 15 s | PASS | 193 | 48800 | 3 | 71 ms |
| 30 s | PASS | 417 | 48800 | 6 | 71 ms |

Each n3 stream matches the full expected hash, contains no full data or
empty ACKs in a zero peer window, and ends with an acknowledged client FIN
and no client RST. `mame.txt` records the runner result for this exact DLL.
