# UNETRTL 0.4.6: fifth-review documentation and layout checks

Raw logs, captures, JSON reports and symbol maps mentioned below are local
run outputs and are not stored in Git. This file preserves the acceptance
summary; see the [artifact policy](../../README.md).

The DLL remains byte-identical to the reviewed 0.4.6: 18157 bytes, SHA-256
`ce188ae6df65f9548530fb9862af7965388115c0e3cb63704c70a39e6d8f6a8b`.
The hot-image reserve remains 5 bytes. No version bump, runtime behavior
change, commit or tag was introduced.

Added the client-facing warning that an empty aborted outbound TCP slot can
report STATUS=0 while CONNECT/LISTEN still return NERR_STATE until CLOSE.
The wording specifies outbound TCP because an accepted LISTEN connection
can retain its ACCEPT bit. STATUS alone is not proof the slot is reusable.

Added two assembly-time checks on the literal BSS offsets used by the fixed
INC HL walks in PEND_CLEAR_A:

```text
BSS_PEND_OFF == BSS_PEND_LEN + 4
BSS_LOST == BSS_CLOSED + 2
```

These ASSERTs emit neither image bytes nor relocations. Compared with the
original 0.4.6 source-hash record, only src/dll/unetrtl.asm changed among
the recorded assembly/includes/tools; documentation was updated separately.
The previously noted LOST and CANCEL_PENDING behavior was not changed.

`make test-host package image` passed all 581 actual-EXE checks, including
216 DLL cases, plus the Python checks (`host.txt`). A new private-copy
Battleship n2 smoke run passed: 8815 host bytes, longest SEND 27 ms, zero
stand failures (`mame.txt`, `n2.txt`). Earlier full-network acceptance
reports remain applicable to the identical DLL; the 13-case set was not
rerun here.

The ZIP/FAT12 copies match for all 32 packaged files, use 8.3 names and
DOS CRLF text. Packaged UNETRTL.TXT was compared with the current rendered
source, and all root/build/ZIP/FAT12 DLL copies match. See `artifacts.json`.
Original 0.4.6 evidence in the parent folder was preserved.
