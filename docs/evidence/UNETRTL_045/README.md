# UNETRTL 0.4.5: third-review FIN fixes

Raw logs, captures, JSON reports and symbol maps mentioned below are local
run outputs and are not stored in Git. This file preserves the acceptance
summary; see the [artifact policy](../README.md).

The baseline DLL was 0.4.4, 18157 bytes, SHA-256
`5da40142cba600571a1be0c0cf2a64090935a267352bad22e8557ae351601b47`.
The staged and unstaged work was preserved; no commit or tag was created.

## Changes and targeted coverage

- A duplicate or out-of-order segment cannot return F_CLOSED for its rejected
  FIN. The DLL clears the local FIN flag before the shared receive return;
  RCV_NXT and the durable peer-close latch remain unchanged.
- A newly accepted FIN with a non-covering ACK still returns NERR_CLOSED and
  the confirmed byte count. That failed SEND now marks the stream aborted:
  a fresh SEND returns CLOSED/DE=0 without overwriting the outstanding range.
  Queued response bytes remain readable; CLOSE/NETDONE performs abort cleanup.
- CH_STATE_ADDR_A now increments the full HL pointer for channel 1. An
  intermediate layout put CH_STATE at the last byte of a 256-byte page; the
  old low-byte-only addition wrote into code. Ordinary DLL smoke tests caught
  this intermediate failure before packaging.
- Corrected ring/TX scratch comments and documented suspended TCP/listener
  RECV, UDP head-of-ring blocking and NERR_STATE after a released peer RST.
  The frozen unet.inc mirror remains unchanged, including its stale backend
  capability comments; GETCAPS remains 0x023F.

Twelve new actual-DLL vectors cover WIN1/WIN2, a queued RECV prefix followed
by a future FIN and recovery, future and duplicate FIN during blocking/sliced
SEND, and a fresh SEND after an accepted non-covering FIN. Every vector
failed against the original 0.4.4 DLL; see `fin-044-before.txt`. The RECV
recovery test initially required both prefix and tail in a single call;
it now permits separate successful drains and verifies the complete stream.
The baseline still fails earlier with NERR_PROTO at the rejected FIN.

The new DLL is 18159 bytes, SHA-256
`c801f2d3206b508da0bdea0c38159bb31447b1678832f246cdea72883dc19401`.
The hot L1 body occupies 14532 bytes, leaving 3 under the unchanged 0x38C7
limit. No additional page or receive-buffer reduction was introduced.

`make test-host package image` passed 557 actual-EXE checks, including 192
DLL cases, plus the host Python checks; see `host.txt`. The root/build DLL
and copies extracted from ZIP/FAT12 are byte-identical. All 32 packaged
files match between ZIP and FAT12 and use 8.3 names. DOS text uses CRLF;
the existing explicit UTF-8-to-CP866 conversion handles the Russian note
in USAGE.TXT, while UNETRTL.TXT remains ASCII. See `dll.json` and the two
directory listings for the artifact checks.

## MAME acceptance

Attempted with the existing private-copy runner:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/dev/run_battleship_n3.py \
  --work build/unet045-battleship --evidence build/evidence/UNETRTL_045 \
  --cases n2 n7 n3 --pauses 6 15
```

All four runs passed, with zero stand failures. The runner's final DLL
digest check also passed. See `mame.txt`, the individual reports and pcaps.

| Case | Host bytes | Longest SEND | Result |
| --- | ---: | ---: | --- |
| n2 | 8815 | 28 ms | PASS |
| n7 | stand audio/network checks | 19 ms | PASS |
| n3, peer pause 6 s | 48800 | 71 ms | PASS |
| n3, peer pause 15 s | 48800 | 71 ms | PASS |

Both n3 streams have SHA-256
`acc7ecb1abac048285733e4caaac6a80a48397a91a1679dc2ada20741b16fa75`.
Packet checks passed: no full payload bursts or empty client ACKs in the
closed receive window, no client RST, and one orderly client FIN. This
stand does not generate the targeted FIN loss/duplicate scenarios; those
are exercised by the actual-DLL host vectors above. This is a four-run
regression check, not a rerun of all 13 Battleship variants or hardware
acceptance.

The initial attempt could not start because feth0/feth1 were absent and
sudo required an interactive password. After the user restored the pair,
the complete command above was rerun successfully. `mame-setup.txt` retains
the initial setup failure; the individual MAME logs contain the final runs.
