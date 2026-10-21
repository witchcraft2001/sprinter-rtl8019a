# UNETRTL 0.4.3 follow-up acceptance

Raw logs, captures, JSON reports and symbol maps mentioned below are local
run outputs and are not stored in Git. This file preserves the acceptance
summary; see the [artifact policy](../README.md).

Final DLL: **18126 bytes**, SHA-256
`472c3112f69ab00e48cd80952a69be12e96d21a3d7a3c39bb3532802dd547bb7`.
Fixed L1 date: 2026-10-20. `dll.json` and `artifacts.json` record the image,
root/build/ZIP/FAT12 identity, repeated assembly and EXE comparison.
The previous staged changes are preserved; no commit or tag was created.

## Changes and host verification

`make test-host package image` passed **507 actual-EXE checks**, including
**142 DLL cases** (42 added for this follow-up). Full output: `host.txt`.

- A matching suspended SEND resumes after peer FIN, keeping its cumulative
  confirmed-byte result. Fresh SEND remains allowed on an orderly half-close;
  STATUS retains CONN until normal RECV queue draining releases the channel.
- CLOSE requires a cumulative ACK covering its FIN, or a peer RST. Other ACKs,
  echo data and FIN consume the remaining attempt budget. They neither report
  success nor spend all three FIN transmissions immediately. Both stale
  `TCP_LAST_FAIL=0` and `=2` are tested in WIN1/WIN2, with FIN retransmissions
  at the bounded interval and correct success/timeout status.
- CLOSE on a suspended SEND's owner cancels it through RST; NETDONE cancels
  and closes both channels. CLOSE on the other channel remains BUSY. Tests
  cover both owners and an accepted LISTEN channel with no cold overlay;
  cancellation rearms the listener and leaves teardown callable.
- A foreign UDP head yields SEND with AGAIN, allowing that datagram to be
  drained and the identical TCP call resumed. The owner's ACK/FIN/RST remains
  reserved for its SEND. Both TCP/UDP channel assignments and delayed RST
  are exercised in both DLL windows.
- A late FIN processed through a foreign UDP receive cannot clear the
  terminal SEND-failure marker or restore STATUS.CONN. The queue still drains,
  further SEND returns CLOSED/DE=0, and CLOSE aborts. This regression was
  reproduced before the guard (`late-fin-before.txt`). The original stranded
  resume regression is recorded in `resume-fin-before.txt`.
- IFF is checked inside actual polling delays, with caller IFF=0/1, timer
  interrupts and cold PING/ARP callbacks. The maximum-length DNS query tests
  the temporary TX/RX scratch overlap in both relocation windows.

Only DLL scratch addresses changed. All 32 default EXEs matched byte for byte
before the version bump; after it, every EXE still matches after substituting
only `0.4.2` -> `0.4.3` in version strings. The hot TX scratch is 96 bytes;
DNS may borrow adjacent dead RX scratch while constructing its query, before
receiving a frame. Queues and maximum UDP payload remain unchanged. The cold
blob is byte-identical to the reviewed 0.4.2 binary. No additional page was
introduced. The L1 body has 14503 bytes, leaving **32 bytes** under the unchanged
0x38C7 limit.

`unet.inc` remains the frozen ABI mirror. RTL-specific AGAIN, cancellation,
terminal-error and half-close semantics are documented in English
`docs/UNETRTL.md` and Russian `docs/UNETRTL_TESTING_RU.md` /
`docs/UNET_API_RU.md`; other backends were not edited. Timing still uses poll
iterations. The documentation includes the measured stand factor (~1.35),
rather than claiming SENDSLICE is a wall-clock maximum.

## MAME reproduction

The runner reads the sibling Battleship project and makes a private copy in
`build/unet043-battleship`; it does not edit the sibling. It uses the existing
pcap feth0/feth1 setup, host 192.168.7.1, guest 192.168.7.2, RTL8019AS in ISA1,
and the DSS system CHD through a private diff. The n3 consumer deadline is
extended from 20 to 60 seconds in the copy only; `stand-patch.json` records
the two patched bytes and EXE hashes. Its payload and SENDSLICE=50 are intact.

```sh
make test-host package image
sjasmplus --nologo -I src/include -I src/lib \
  --sym=build/unet043-observer.sym src/dll/unetrtl.asm
PYTHONDONTWRITEBYTECODE=1 BS_ISATRACE=1 \
  BS_DLL_SYM="$PWD/build/unet043-observer.sym" \
  python3 tools/dev/run_battleship_n3.py --cases n7 n2 n4 n3 \
  --observer tools/dev/observe_unetrtl_iff.lua
```

`n2.txt`, `n4.txt`, `n7.txt` record echo/idle RECV/CLOSE, LISTEN/rearm and
keyboard/PCM checks. For these cases, the stand report is the acceptance
result; the capture JSON just records its exit status. The n3 capture checker
reconstructs the stream by sequence and validates window/probe/ACK/FIN
geometry. Full captures and reports are retained for each pause. The expected
48800-byte payload SHA-256 is independently derived from the stand formula
`(i*13 + seed) & 255`, i=0..243, seed=200 down through 1:
`acc7ecb1abac048285733e4caaac6a80a48397a91a1679dc2ada20741b16fa75`.

## IRQ finding remains unconfirmed

No ISA/IFF change was made based on the intermittent 0.4.2 audio-gap report.
In final n7, IN_NET_UNDER=0 and IN_NET_DMAX=5978 CTC counts (~6.83 ms).
`n7.txt.iff.txt` records **5037 poll reopens**, all with SAVE_IFF=1; all other
observed opens also saved 1. The I/O observer reads the IFF2 sample which
ISA_OPEN took before DI, at the following OUT (#1FFD),#11. IFF1/IFF2 are
necessarily zero at that OUT, while SAVE_IFF reports the caller's state.
Since this is the reopen after the closed-window delay, a persistent DI
state through those delays would appear as SAVE_IFF=0. The reported 15-loop
DI gap did not recur. This run does not establish the cause or fix that
intermittent observation. Host tests separately check IFF1 at DELAY_1MS itself.

## Final results

MAME n2, n4 and n7: **PASS**. Final n3 runs:

| Peer pause | MAME + capture | AGAIN returns | Payload bytes | Zero-window probes | Maximum SEND |
| --- | --- | ---: | ---: | ---: | ---: |
| 6 s | PASS | 61 | 48800 | 1 | 71 ms |
| 15 s | PASS | 194 | 48800 | 3 | 71 ms |
| 30 s | PASS | 417 | 48800 | 6 | 71 ms |

All three streams match the full expected SHA-256 above. Each ends with one
acknowledged client FIN, no client RST, no full data in a closed peer window
and no empty ACKs in that window. Root, build, ZIP and FAT12 DLL bytes agree.
`mame.txt` records the runner exit results for this exact DLL hash.
