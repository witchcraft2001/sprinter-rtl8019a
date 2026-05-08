# ISAPROBE.EXE

Low-level ISA bus diagnostic.  Reads the entire 14-bit Sprinter
ISA window (I/O `0x0000..0x3FFF`, mapped to memory
`0xC000..0xFFFF` after `ISA_OPEN`) and reports what is responding.
Use it when `NICINFO` cannot find the card at any of the standard
NE2000 bases, to tell apart "card missing", "card on a non-default
base", "card on the other slot", and "ISA bus not driven at all".

## Usage

```
ISAPROBE                   activity map of both ISA slots
ISAPROBE -s N              activity map of a single slot (N = 0 or 1)
ISAPROBE -d ADDR [LEN]     hex dump LEN bytes at I/O ADDR
ISAPROBE -o FILE [-s N]    raw 16 KB binary dump to FILE
ISAPROBE /?                help
```

`ADDR` and `LEN` are hex (a `0x` prefix is accepted but optional).
`LEN` defaults to `0x20` (one NE2000 register block).  The default
slot for `-d` and `-o` is `1` (matches `MAME -isa1`).

> **Warning.** ISAPROBE READS the full 14-bit window.  Some ISA
> registers have read side effects -- for instance, an RTL8019AS
> reset port at `BASE+0x1F` triggers a chip reset on read, and
> reading the NE2000 DMA data port advances the remote-DMA
> pointer.  Run ISAPROBE only when you are diagnosing an
> unresponsive card, never against a device that is in the middle
> of a transfer.

## Activity map

The default mode prints, for each slot, an 8-line summary in
which every character represents one 32-byte block of I/O space
(64 blocks per line, 8 lines per slot, total 16 KB).

| Char | Meaning                                                   |
|------|-----------------------------------------------------------|
| `.`  | Every byte in the block reads as `0xFF` (no responder)    |
| `0`  | Every byte reads as `0x00` (e.g. pulled-low / floating)   |
| `X`  | Mixed values, or a uniform non-trivial value: a live device |

Example with an RTL8019AS at `0x300`, slot 1:

```
ISAPROBE v0.1
Slot 0 activity map (each char = 32 bytes; .=FF 0=00 X=live)
0000: ................................................................
...
3800: ................................................................
Slot 1 activity map (each char = 32 bytes; .=FF 0=00 X=live)
0000: ................................................................
...
3000: X...............................................................
3800: ................................................................
```

The `X` at line `3000:`, column 1 of slot 1 is the 32-byte
register block at I/O `0x300`.

If both slots are entirely `.`: the ISA bus is reading floating;
no card or wrong slot mapping in DSS / Sprinter setup.  Try
reseating the card, swapping slots, or checking +5V.

If a different column lights up (e.g. column 2 → I/O `0x320`):
the card is alive but jumpered or EEPROM-configured to a base
other than the kit's default `0x300`.  Pin the discovered
location in `NET.CFG` (`RTL_HW=1/#320`, `NETCFG -i` to apply)
or just let the auto-scan in `INIT_BASE` find and cache it on
the next utility run -- subsequent utilities then skip the
scan, reading `NET_RTL_HW` from env.

## Hex dump

```
ISAPROBE -d 0x300         32 bytes at I/O 0x300, slot 1
ISAPROBE -d 0x300 0x40    64 bytes
ISAPROBE -d 0 0x4000      whole window in classic hex (large output)
ISAPROBE -d 300 20 -s 0   32 bytes at I/O 0x300 of slot 0
```

Output format is the standard `xxd`-style row:

```
Hex dump @ I/O 0x0300 len 0x20 slot 1
0300: 21 4F 02 4F 00 00 00 00 00 00 50 70 80 00 00 80 | !O.O......Pp....
0310: FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF | ................
```

## Raw dump to file

```
ISAPROBE -o ISA1.BIN          16 KB raw window of slot 1
ISAPROBE -o ISA0.BIN -s 0     same for slot 0
```

The output is a flat 16384-byte binary -- offset 0 is I/O
`0x0000`, offset 0x300 is I/O `0x300`, etc.  Use the existing
overwrite-prompt machinery: if the target file exists, ISAPROBE
asks `[Y/N]` before overwriting.

Inspect the file on the host with any standard hex tool:

```sh
xxd ISA1.BIN | less
od -An -t x1z ISA1.BIN | less
hexdump -C ISA1.BIN | less
```

## Suggested workflow on real hardware

1. Run `NICINFO` first.  If it succeeds, you do not need
   ISAPROBE.
2. If `NICINFO` reports `[E04] no chip at default I/O base`,
   run `ISAPROBE` (no args).  Compare both slots.
3. If both slots are entirely `.`, the issue is below the bus
   (slot/power/wiring), not the I/O base.
4. If one slot has an `X` block at a non-`0x300` column, note the
   I/O base and either reconfigure the card or run
   `ISAPROBE -d <addr> 0x40 -s <slot>` to inspect the region.
5. For deeper analysis, dump the slot to a file with `-o` and
   examine on the host.

## Exit codes

| Code | Meaning                                |
|------|----------------------------------------|
| 0    | OK                                     |
| 1    | Usage (bad flag, bad hex, ...)         |
| 5    | File create / write / close failure (`-o` mode) |
