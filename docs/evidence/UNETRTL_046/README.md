# UNETRTL 0.4.6: fourth-review pending-hint fix

Raw logs, captures, JSON reports and symbol maps mentioned below are local
run outputs and are not stored in Git. This file preserves the acceptance
summary; see the [artifact policy](../README.md).

Baseline: UNETRTL 0.4.5, 18159 bytes, SHA-256
`c801f2d3206b508da0bdea0c38159bb31447b1678832f246cdea72883dc19401`.
The staged work was preserved; no commit or tag was created.

## Changes

PEND_HAS_A first checks the queue length. If no bytes remain, it considers
only the orderly peer-close bit (CH_CLOSED=1), then the existing NIC ring
hint. A terminal SEND failure (CH_CLOSED=2) by itself no longer produces
RXPEND or XCHAN. Thus partially drained responses still request service,
but an empty aborted stream cannot drive an endless cross-channel drain.
DE remains untouched by the helper.

TCP_ABORTED and CH_CLOSED=2 remain set until explicit CLOSE/NETDONE. RECV
does not release an aborted stream: it drains queued response bytes, then
returns CLOSED/DE=0. A fresh SEND is still rejected without transmitting;
CONNECT remains STATE until CLOSE. CLOSE sends abort resets and frees or
rearms the slot. The docs now state this client obligation explicitly.
An orderly FIN retains its receive notification and normal EOF cleanup;
a peer RST retains its immediate release/rearm behavior. A late covering
ACK after a terminal non-covering FIN does not revive the aborted sender.

PEND_LEN/OFF_ADDR_A, CLOSED_ADDR_A and LOST_ADDR_A now increment the full
HL pointer for channel 1, including carry across a 256-byte boundary.
The unreachable repeated ACK_WAIT_ACTIVE check in the DLL-only normal
receive return was removed (8 bytes). The sender/persist implementation,
memory map and frozen UNET ABI are unchanged. Internal ACK_WAIT_STATE
after a terminal error, poll-based timeouts and TIME_WAIT were not changed.

DLL: 18157 bytes, SHA-256
`ce188ae6df65f9548530fb9862af7965388115c0e3cb63704c70a39e6d8f6a8b`.
The hot L1 body is 14530 bytes, leaving 5 under the unchanged 0x38C7 limit.
The 1776-byte cold blob is byte-identical to 0.4.5. All 32 ZIP/FAT12 files
match byte for byte, use 8.3 names and preserve DOS CRLF for text; existing
CP866 conversion handles the Russian note in USAGE.TXT. The packaged
UNETRTL.TXT was also compared against the current rendered source document.
See `dll.json`, `image-list.txt` and `zip-list.txt`.

## Actual-DLL host regressions

`make test-host package image` passed 581 actual-EXE checks, including 216
DLL cases, plus the host Python checks. See `host.txt`.

Twenty-four new cases cover WIN1/WIN2, either channel as owner, empty and
buffered replies, final SEND timeout, non-covering FIN and orderly EOF.
They check pending hints before/after a partial drain, repeated other-channel
TCP/UDP RECV after the final drain, CLOSED/DE=0, no fresh transmission,
slot reservation before CLOSE and successful reconnect after it.

Sixteen terminal-error cases reproduce sticky RXPEND/XCHAN on the baseline;
eight orderly-EOF controls pass there. See `pending-045-before.txt`.
The first draft of the EOF controls expected repeated CLOSED after ordinary
EOF released the slot; it was corrected to expect STATE on later calls,
without asserting unspecified DE on STATE. Those fixture errors are not
counted as DLL regressions; the recorded baseline uses the corrected tests.

## MAME command

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/dev/run_battleship_n3.py \
  --work build/unet046-battleship --evidence build/evidence/UNETRTL_046 \
  --cases n2 n7 n3 --pauses 6 15
```

The runner uses a private stand/image copy and does not edit the sibling
Battleship project. These runs test ordinary network/persist behavior;
the targeted aborted-channel hint cases use the actual-DLL host vectors.

All four MAME runs passed with zero stand failures. The final runner check
confirmed the DLL digest was unchanged throughout. See `mame.txt` and the
individual reports/pcaps.

| Case | Host bytes | Longest SEND | Result |
| --- | ---: | ---: | --- |
| n2 | 8815 | 27 ms | PASS |
| n7 | stand audio/network checks | 19 ms | PASS |
| n3, pause 6 s | 48800 | 71 ms | PASS |
| n3, pause 15 s | 48800 | 71 ms | PASS |

Both n3 streams have SHA-256
`acc7ecb1abac048285733e4caaac6a80a48397a91a1679dc2ada20741b16fa75`.
Capture analysis passed: no client RST, no full data bursts or empty client
ACKs in the closed receive window, and one orderly client FIN. These four
runs are a regression check; all 13 Battleship variants and real hardware
were not rerun for this change.
