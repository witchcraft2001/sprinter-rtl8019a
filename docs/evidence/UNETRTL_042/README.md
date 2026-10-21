# UNETRTL 0.4.2 acceptance

Raw logs, captures, JSON reports and symbol maps mentioned below are local
run outputs and are not stored in Git. This file preserves the acceptance
summary; see the [artifact policy](../README.md).

The final DLL fingerprint and fixed L1 date are recorded in `dll.json`.
`stall6.txt`, `stall15.txt`, and `stall30.txt` are the Battleship reports;
matching `.pcap` files and `capture*.json` contain the wire evidence.
`host.txt` records the final host gate and artifact identity checks.

Reproduce from this repository:

```sh
make test-host package image
PYTHONDONTWRITEBYTECODE=1 python3 tools/dev/run_battleship_n3.py
python3 tools/dev/check_unetrtl_capture.py build/evidence/unetrtl/stall30.pcap
```

The runner reads the sibling Battleship project and creates its own stand
under `build/unet042-battleship/`; it does not modify the sibling. It uses
the existing pcap feth0/feth1 network (host 192.168.7.1, Sprinter 192.168.7.2),
MAME's RTL8019AS ISA slot and the existing DSS system CHD through a private
diff. `processes*.txt` contain only the relevant emulator process records.

Battleship's original consumer abandons a suspended SEND after 20 seconds
and changes its source buffer. This violates the resume contract during a
30-second receiver pause. The runner extends only that caller deadline to
60 seconds (1000 -> 3000 ticks at 50 Hz), in a copy of BSTAND.EXE. The two
modified bytes, file offset and both EXE hashes are in `stand-patch.json`.
Addresses, record lengths, symbols, payload generation and SENDSLICE=50
remain unchanged. The patched EXE retains the valid eight-page record chain.

Each accepted run must deliver exactly 48800 payload bytes after the mode
byte, SHA-256
`acc7ecb1abac048285733e4caaac6a80a48397a91a1679dc2ada20741b16fa75`.
The capture checker reconstructs retransmissions by sequence, rejects
conflicting bytes, full payload retransmissions into zero windows and
empty client ACKs in zero windows, and requires an acknowledged client FIN.
Host EOF and the same payload digest are independently recorded by the server.
Persist intervals still count polling iterations; their measured duration
reflects this stand's pacing. System timer conversion is outside this change.

The host matrix exercises actual DLL code in WIN1 and WIN2, a WIN0 consumer
stack, partial ACKs, zero-window persist (blocking and sliced), lost window
updates, disappearance, stale ACK/window advertisements and sequence wrap,
ACK traffic during SENDSLICE, multi-MSS public-call budgets, channel swaps,
terminal SEND failures and queued-data draining. Passive SYN/SYN-ACK/ACK and
window-limited SEND also run with an empty optional cold section and caller
IFF=0/1; CLOSE must rearm LISTEN. Existing maximum-UDP and FIN/RST paths remain
covered. ISA/IFF checks run in the strict harness throughout.

Before the version bump, all 32 EXEs were rebuilt and compared byte for byte
with pre-map-change copies. The EXE map was identical. Only DLL-specific
regions changed. The core L1 limit remains 0x38C7 code bytes; the optional
cold section is unchanged and TCP persist needs no additional code page.

Earlier diagnostic runs are retained under `mixed-session/`, `previous/`,
and `before-recv-flags/`. They are not the final acceptance artifacts.
The first contains two overlapping client streams and a failed run. The
original 20-second consumer deadline also produced an invalid 30-second
experiment, retained in `previous/`. Corrected stand runs are distinguished
by `stand-patch.json`; final artifacts must match `dll.json`.

Further pre-final records under `before-public-budget/` include a failed
30-second run: the sender eventually treated four probes as unanswered,
while host pcap recorded replies. That capture alone cannot show whether
those packets reached MAME's NIC. No RAM trace was recorded for that failure,
so its cause is not assigned here. The final 30-second run uses the exact
DLL hash in `dll.json`; `tcp-state30.txt` shows live probe responses,
advancing BNRY, a fresh nonzero peer window and resumed sequence progress,
and its capture/report both pass. Earlier runs used different DLL images.

## Final results

| Receiver pause | MAME + capture | Payload bytes | Zero-window probes | Maximum SEND |
| --- | --- | ---: | ---: | ---: |
| 6 s | PASS | 48800 | 1 | 71 ms |
| 15 s | PASS | 48800 | 3 | 71 ms |
| 30 s | PASS | 48800 | 6 | 71 ms |

All three captures contain zero full data retransmissions and zero empty
client ACKs in closed peer windows. Every run ends with one acknowledged
client FIN and no client RST. Full stream hashes match. The host gate has
465 actual-EXE checks, including 100 DLL cases; all pass.

Final DLL SHA-256: `641677d5c0e3bd55b462ceeaf677c55032d9a1a103f55a541a93c630a74aab61`.
Root, build, repeated build, ZIP and FAT12 DLL bytes match exactly.
