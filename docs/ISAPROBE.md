# ISAPROBE.EXE

Low-level ISA bus diagnostic.  Its default activity map scans the
conventional 10-bit ISA I/O range `0x0000..0x03FF` and reports what is
responding.  Explicit dump modes can address the entire 14-bit Sprinter ISA
window (`0x0000..0x3FFF`, mapped to memory `0xC000..0xFFFF` after
`ISA_OPEN`), but wider reads are potentially unsafe on old cards.
Use it when `NICINFO` cannot find the card at any of the standard
NE2000 bases, to tell apart "card missing", "card on a non-default
base", "card on the other slot", and "ISA bus not driven at all".

## Usage

```
ISAPROBE                   safe 0000..03FF map of both ISA slots
ISAPROBE -s N              safe 0000..03FF map of slot N (0 or 1)
ISAPROBE -n BASE [-s N]    safe NE/DP8390 page-0/page-1 snapshot
ISAPROBE -d ADDR [LEN]     hex dump LEN bytes at I/O ADDR
ISAPROBE -o FILE [-s N]    raw 16 KB binary dump to FILE
ISAPROBE /?                help
```

`ADDR` and `LEN` are hex (a `0x` prefix is accepted but optional).
`LEN` defaults to `0x10` (the NE2000 register core only).  The default
slot for `-d` and `-o` is `1` (matches `MAME -isa1`).

> **Warning.** Explicit wide `-d` and `-o` operations can read the full
> 14-bit window.  Many old ISA cards decode only A0..A9, so addresses above
> `0x3FF` can alias live registers.  A single aliased read may wait forever
> on `IOCHRDY`; software cannot time out a CPU bus cycle that never finishes.
> Registers can also have read side effects -- for example, reading an
> RTL8019AS reset port at `BASE+0x1F` resets the chip.  Prefer the default
> map, then dump only the discovered 32-byte block.

## Activity map

The default mode prints one line per slot.  Every character represents one
32-byte block: 32 characters cover `0x0000..0x03FF`.  Starting with v0.2.19,
only the first 16 bytes of each block are sampled.  This still covers the
NE2000 register core but avoids its DMA data and reset ports in the second
half of the block.

| Char | Meaning                                                   |
|------|-----------------------------------------------------------|
| `.`  | Every sampled byte reads as `0xFF` (no responder)         |
| `0`  | Every sampled byte reads as `0x00` (pulled-low / floating)|
| `X`  | Mixed values, or a uniform non-trivial value: a live device |

Example with an RTL8019AS at `0x300`, slot 1:

```
ISAPROBE v0.2.19
Slot 0 activity map 0000..03FF (32-byte blocks, sample16; .=FF 0=00 X=live)
0000: ................................
Slot 1 activity map 0000..03FF (32-byte blocks, sample16; .=FF 0=00 X=live)
0000: ........................X.......
```

The `X` at character 25 of slot 1 is the 32-byte register block at I/O
`0x300`: zero-based block index 24 multiplied by 32.

Starting with v0.2.17, every 32-byte classification uses a short
`ISA_OPEN`/`ISA_CLOSE` bracket and prints the resulting character only after
the normal DSS page-3 mapping has been restored.  Hex dump mode likewise
captures one 16-byte row into ordinary RAM, closes ISA, and then formats it.
This is required on real Sprinter hardware; older versions could hang or
corrupt DSS state by printing while the ISA window was still mapped.

Starting with v0.2.18, the default activity map no longer scans above
`0x3FF`.  A field test with a UMC UM9003AF found live blocks at `0x300` and
`0x3E0`, then stopped in the block starting at `0x700`.  The latter is the
`0x300` block with address bit A10 set, which is consistent with partial
A0..A9 decoding.  The read itself stalled, so closing the ISA window or a
software timeout could not recover it.  This is a separate hardware probing
hazard, not the DSS-printing bug fixed in v0.2.17.

The next field test showed that v0.2.18 map completed, but a following
`-d 300 20` stopped before its first row.  Two implementation differences
were unsafe: map had already read `0x310..0x31F` (including NE2000 data and
reset ports), and dump used `LDIR` while the successful map used scalar
loads.  Version 0.2.19 samples only `BASE+0..BASE+0x0F`, changes the default
dump length to `0x10`, and replaces ISA-source `LDIR` with explicit scalar
reads.

On real hardware, v0.2.19 then read I/O `0x300..0x30F` reliably:

```
E1 9E 46 34 23 02 9C 00 DC 04 00 38 1F A6 51 02
```

The first byte is CR and `E1` selects page 3, so the remaining bytes are not
a page-0 DP8390 snapshot and must not be decoded as PSTART/BNRY/ISR/etc.  The
result proves stable 8-bit register access only.  It does not yet prove that
the 16-bit UMC card supports byte-wide remote DMA or packet RAM on ISA8.
The second live bucket at `0x3E0` is only another responder; without a
card-absent comparison it is not proven to belong to the UMC adapter.

## NE/DP8390 page snapshot

Version 0.2.20 adds a controlled page-select diagnostic:

```
ISAPROBE -n 300 -s 0
```

It reads the raw CR, writes only standard DP8390 CR values `0x21` and
`0x61`, captures the first 16 registers of page 0 and page 1, then leaves the
core stopped on page 0.  It does not reset the adapter, read the DMA/reset
ports, or start remote DMA.  `[N3] CR page select OK` confirms only the
register-page model; packet-RAM width is a separate later test.

The real UM9003AF test returned:

```
[N0] RAW CR=F1
[N1] PAGE0 F1 9E 46 34 23 02 9C 00 DC 04 00 38 1F A6 51 02
[N2] PAGE1 F1 9E 46 34 23 02 9C 00 DC 04 00 38 1F A6 51 02
[E] CR page select mismatch P0/P1=F1/F1
```

Thus reads are stable but writes of standard CR values do not reach an
active DP8390 core.  The card cannot be used by the current driver in this
state.  The original UMC LANSET documentation calls the UM9003x a 16-bit
jumperless adapter and explicitly mentions repairing an EEPROM "16/8-bit
mark" after slot-width autodetection errors.  Plausible causes are a stale
16-bit EEPROM mode/IO16 setting, an inactive configuration-only decode, or a
failed IOW path on the card.  Do not guess the 93C46 protocol from Sprinter:
use the original LANSET on a real x86 DOS machine with the card in an 8-bit
slot, or read and back up the EEPROM with a programmer before changing it.

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
ISAPROBE -d 0x300         safe 16-byte core at I/O 0x300, slot 1
ISAPROBE -d 300 10 -s 0   safe 16-byte core at I/O 0x300, slot 0
```

Do not use `ISAPROBE -d 0 0x4000` on a card with unknown or partial address
decoding.  It can reach aliases above `0x3FF` and hang in an ISA bus cycle.
Likewise, do not extend a dump at a probable NE2000 base past length `0x10`
unless a destructive read of its DMA/reset ports is explicitly intended.

Output format is the standard `xxd`-style row:

```
Hex dump @ I/O 0x0300 len 0x10 slot 1
0300: 21 4F 02 4F 00 00 00 00 00 00 50 70 80 00 00 80 | !O.O......Pp....
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

Raw mode intentionally remains an expert-only full-window operation.  Do not
run it on the UM9003AF or any unknown card until wide-address decoding has
been established by other means.

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
   `ISAPROBE -d <addr> 0x10 -s <slot>` to inspect its first 16 bytes.
5. Use `-o` only after confirming that the card safely decodes the complete
   14-bit range.  Otherwise keep all explicit dumps inside `0x000..0x3FF`.
6. For a non-RTL NE2000-compatible candidate, run
   `ISAPROBE -n <base> -s <slot>` before attempting reset or remote DMA.

## Exit codes

| Code | Meaning                                |
|------|----------------------------------------|
| 0    | OK                                     |
| 1    | Usage (bad flag, bad hex, ...)         |
| 5    | File create / write / close failure (`-o` mode) |
