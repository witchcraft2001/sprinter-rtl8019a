# NICREG.EXE

Tests whether the card's registers read back reliably on this machine.

Use it when register dumps from other utilities do not repeat -- `DCR=48`
in one dump and `DCR=C8` in the next -- and you need to know which of two
very different things you are looking at:

- **The chip does not drive that bit.**  A reserved bit of a clone often
  returns whatever was on the data bus a moment earlier.  Harmless: the
  driver never looks at it.
- **The chip drives the bit and the host misreads it.**  A genuine ISA
  timing fault.  The driver takes decisions from register reads (`ISR`,
  `BNRY`, `CURR`), so this one does hurt.

`NICREG` separates the two.  Immediately before every read of a register
under test it reads a *conditioner* -- a read/write register preset to `00`
in one pass and to `FF` in the other.  A driven bit reads the same in both
passes.  An undriven bit follows the conditioner.  A bit that changes
*inside* one pass is an unstable read.

## Usage

```
NICREG
NICREG -t
NICREG /?
```

| Option | Meaning                                                        |
|--------|----------------------------------------------------------------|
| (none) | Register tests only.  Nothing is transmitted.                  |
| `-t`   | Also send 3 x 20 test frames, to be counted on another host.   |

The card is located the way every other utility locates it: `NET_RTL_HW`
from the environment if set (see `NETCFG.TXT`), otherwise an auto-scan.
`NET_RTL_RESET` is honoured, and a card that does not report the Realtek ID
never has its reset port touched.  Page 3 is never accessed.

The run takes about 15 seconds in turbo mode and about three times as long
at 7 MHz.  **Run it in both modes** (F12+Ctrl+Shift toggles turbo): a fault
that disappears at 7 MHz is a bus-timing fault.

## Output

```
RTL8019AS NICREG v0.3.19
[G0] Slot/Addr: 0/#300 chip=clone
[G1] RW STORAGE stopped, 14 regs x 2048 reads
 bad after-00=0000 after-FF=0000 cond=0000
[G2] PAGE2 CONFIG  written|and/or after 00|after FF  bad=0000
 PSTOP 60|60/60|60/60 TPSR  40|40/40|40/40
 RCR   04|04/04|C4/C4 TCR   02|02/02|E2/E2
 DCR   48|48/48|C8/C8 IMR   00|00/00|80/80
[G3] PAGE0 STATUS  and/or after 00|after FF  CR bad=0000
 CR    21/21|21/21 CLDA0 00/00|00/00 CLDA1 40/40|40/40 TSR   01/01|01/01
 ...
[G4] PAR=028019112233  per row: 288000 reads, 192000 writes
 row  rd-bad bits wr-lost wr-bad cr-bad rxpages badticks withrx
 stop 0000   00   0000    0000   0000   0000    0000     0000
 deaf 0000   00   0000    0000   0000   0000    0000     0000
 live 0000   00   0000    0000   0000   0012    0000     0000
RESULT OK
```

### Reading a value pair

Every value is printed as `and/or`: the bitwise AND and the bitwise OR of
256 consecutive reads.

- `48/48` -- all 256 reads returned `48`.  Stable.
- `48/C8` -- bit 7 was 0 in some reads and 1 in others.  **Unstable.**

There are two pairs per register: the first taken right after the
conditioner read `00`, the second right after it read `FF`.

- `48/48|48/48` -- driven and stable.
- `48/48|C8/C8` -- bit 7 is 0 after `00` and 1 after `FF`, and rock steady
  within each pass: the chip does not drive bit 7.  Benign.  This is what a
  UM9003 shows on the reserved bits of `RCR`, `TCR`, `DCR` and `IMR`.
- `48/C8|...` -- bit 7 changes while nothing else does: a real misread.

### The phases

| Phase  | Chip    | What is checked                                          |
|--------|---------|----------------------------------------------------------|
| `[G1]` | stopped | `PAR0..5`, `CURR`, `MAR0..6` hold known patterns and are read back 2048 times each.  All 8 bits of these registers are implemented, so **any** mismatch is a misread.  The second pass uses the complemented pattern: every bit is checked as a 0 and as a 1. |
| `[G2]` | stopped | Page-2 read-back of the configuration written on page 0.  Bits the DP8390 defines must match (`bad=` counts the ones that do not); reserved bits are only displayed. |
| `[G3]` | stopped | Page-0 status registers.  Only `CR` has a value that can be insisted on.  The rest is there to show which offsets the chip drives at all -- an undecoded offset reads `00/00` in the first pair and `FF/FF` in the second. |
| `[G4]` | all three | One read + write/read-back loop against the chip stopped, started but deaf, and live on the LAN.  See below. |

In `[G1]` the line `bad after-00= after-FF= cond=` gives the misread totals
for the two passes and for the conditioner itself.  Registers that failed
are listed below it (at most six) with `bits=` -- the bits that came back
wrong.  A fault confined to one bit points at a data line; a fault on all
bits points at strobe timing.

`RESULT FAIL` means at least one driven bit was misread, or a write did
not take.  Undriven bits never fail the run.

### `[G4]`: the same loop against a stopped and a started chip

`[G1]`..`[G3]` test a stopped chip.  On real hardware a chip that reads
back flawlessly while stopped has been seen to misread, and to **drop
writes**, once it is started -- so `[G4]` runs one fixed loop against three
states and lets the rows be compared:

| Row    | Chip                   | Receiver                                  |
|--------|------------------------|-------------------------------------------|
| `stop` | stopped                | The control row.  Should be all zeros.    |
| `deaf` | started, `RCR=MON`     | Checks addresses, stores nothing: no buffer DMA. |
| `live` | started, `RCR=AB`      | Stores every broadcast on the LAN meanwhile. |

Per row, 1500 windows of 32 sweeps.  One sweep reads `PAR0..5` against the
station address shown in the header, then writes `MAR0..3` with a pattern
that flips every sweep and reads them back.  (`MAR` is unused while
multicast reception is off.)

A real run, UM9003AF on a Sprinter, ordinary home LAN:

```
[G4] PAR=028019112233  per row: 288000 reads, 192000 writes
 row  rd-bad bits wr-lost wr-bad cr-bad rxpages badticks withrx
 stop 0000   00   0000    0000   0000   0000    0000     0000
 deaf 0011   FF   0007    0000   0000   0000    0012     0000
  rd PAR1=02@0D PAR5=22@06 PAR2=80@1C PAR3=19@1D PAR1=02@1A PAR5=22@05
  wr MAR3=69>96 MAR3=69>96 MAR1=3C>C3 MAR1=C3>3C
 live 0006   FF   000F    0000   0002   0043    000F     000C
  rd PAR3=19@12 PAR0=96@19 PAR5=22@00 PAR1=02@17
  wr MAR1=3C>C3 MAR2=96>69 MAR3=69>96 MAR2=69>96
```

| Column     | Meaning                                                       |
|------------|---------------------------------------------------------------|
| `rd-bad`   | Reads that returned a wrong value.  `bits` is the OR of the wrong bits. |
| `wr-lost`  | Writes the chip did not take: the register still held the previous pattern on two further reads. |
| `wr-bad`   | Writes after which the register held something else.          |
| `cr-bad`   | Page switches (`CR` writes) that did not take.  Each one is detected by reading `CR` back and is repeated, so the test itself stays on the right page. |
| `rxpages`  | Buffer pages the receiver filled meanwhile.  `0000` in the live row means a silent LAN: repeat with traffic. |
| `badticks` | Windows (of 1500) that contained any failure.                 |
| `withrx`   | How many of those were windows in which a frame arrived (or the window after: a frame still arriving when a window closes moves the ring in the next one).  Compare with chance: with `rxpages=0043` a frame arrives in about 9 windows out of 100, so 15 unrelated bad windows would give `withrx` 1 or 2.  `000C` of `000F` is not chance. |

The `rd` line lists the first six misreads: register, **the value that came
back**, and after `@` the sweep number `00`..`1F` inside the window.  A
value equal to the register read just before it (`PAR1=02`: `02` is what
`PAR0` holds; `PAR0=96` is the `MAR3` read-back that ended the previous
sweep) means the chip did not answer that cycle and the host latched what
was left on the bus.  Misreads that are all `PAR0` at `@00` would instead
point at the first access after the window opens.

`rd-bad` also counts misread `MAR` and `CR` read-backs, and those are not
listed: `0006` with four samples means two of them.

The `wr` line lists the first four failed writes as *wanted* `>` *held*.
*Held* equal to the complement of *wanted* is the previous sweep's pattern:
the write never reached the register.

In the run above every failure is a whole bus cycle the chip did not take
part in: reads return the previous value on the bus, writes vanish, nothing
is ever garbled (`wr-bad=0000`), and reads and writes fail at the same rate.
`badticks` below the sum of the failure columns (`0011`+`0007` failures in
`0012` windows) means they come in bursts inside one 1.5 ms window -- the
mark of a cause that lasts a fraction of a millisecond, not of random noise.

The same card, the same evening, **network cable unplugged**, in turbo mode:

```
 stop 0000   00   0000    0000   0000   0000    0000     0000
 deaf 0000   00   0000    0000   0000   0000    0000     0000
 live 0000   00   0000    0000   0000   0000    0000     0000
RESULT OK
```

and with the cable back, still in turbo mode, `deaf 0007/0009` and
`live 000C/0007` with `withrx=0009` of `badticks=000D`.  So the failures
need frames on the wire; the CPU speed does not matter.  The live row of
that run also listed `PAR3=4C`, `PAR3=4D`, `PAR3=56`: not what was left on
the bus, but receive-ring page numbers, rising as the ring filled.  The read
collided with the chip's own receive work and returned the chip's internal
value.

A DP8390 holds a host register access off while it is busy (its `ACK`
output; an NE2000 turns that into `IOCHRDY`).  A host that does not wait
gets exactly this picture.  NICREG cannot see `IOCHRDY`, so it proves the
dependence on wire traffic, not the electrical cause.

How to read the rows:

| Pattern                             | Meaning                               |
|-------------------------------------|---------------------------------------|
| all rows zero                       | Register access is reliable in every chip state. |
| `stop` zero, `deaf` and `live` alike | Access to a **started** chip is unreliable, buffer DMA or not.  A fixed-length bus cycle is now and then too short for the running chip; an ISA host that honours `IOCHRDY` would wait. |
| `stop` zero, `deaf` bad, `live` bad with `withrx` close to `badticks` | The failures follow frames on the wire, stored or not.  **Repeat with the network cable unplugged:** if `deaf` and `live` turn zero, the chip misses host cycles while its receiver is busy with a frame. |
| only `live` bad, `withrx` = `badticks` | Accesses collide with the chip's receive-buffer DMA.      |
| `badticks=0001` with `rd-bad` and `wr-bad` in the tens | One long event: for part of a single window every register answered with the same wrong values (`PAR0..5` all `47`), then the chip recovered by itself.  Seen once (cable unplugged, 7 MHz, `live` row); cause unknown.  Repeat the run and see whether it comes back. |
| `stop` bad too                      | The bus itself is marginal; `[G1]` should show it as well.  |

Why `cr-bad` and `wr-lost` matter more than `rd-bad`: a driver can read a
register twice, but a dropped `CR` page switch sends the writes that follow
into another page.  This was observed on real hardware before page switches
were verified: the ring drain's `BNRY` write landed in `PAR2` and the
station address stayed corrupted for the rest of the row.

## `-t`: is a frame lost on the way out?

```
[G5] TX 3x20, type 88B5 -- count arrivals on the peer
 A poll  ptx=20 isr=00/22 tsr=01/01
 B quiet ptx=20 isr=02/02 tsr=01/01
 C drv   ptx=20
```

Sixty 60-byte broadcast frames, EtherType `88B5`, source
`02:80:19:11:22:33`.  The payload starts with `NICREG TX `, then the mode
letter, then the sequence number as one byte (`01`..`14` hex).

| Mode | How the frame is sent                                            |
|------|------------------------------------------------------------------|
| `A`  | Textbook NE2000 transmit, then `ISR` is read back-to-back until the chip reports completion -- what a polling driver does. |
| `B`  | The same transmit, then **no bus cycle reaches the chip for 2 ms**; one `ISR` read afterwards. |
| `C`  | The kit's own `RTL.SEND_FRAME`, with its read-back and diagnostics. |

`ptx=` is how many frames the chip *claims* to have sent; it should be 20
everywhere.  The figure that matters is how many **arrive**.  Capture on
another host on the same switch:

```
capture filter:  ether proto 0x88b5
display filter:  eth.type == 0x88b5
```

and count the frames per mode letter.  `B` arriving in full while `A`
loses frames means that accessing the chip during a transmission disturbs
it.  All three modes losing the same share means the loss is not caused by
how the driver talks to the chip.

`isr=` is the `and/or` of every `ISR` value read while waiting, `tsr=` the
same for the transmit status afterwards.  An `isr=` OR of `FF` would be a
floating-bus read in the middle of a transmission.

## What it writes

`CR`, the page-1 registers (`PAR`, `CURR`, `MAR`; `MAR0..3` a few hundred
thousand times), and on page 0 the
ordinary configuration registers plus `PSTART` and `BNRY`, which serve as
conditioners and are restored.  The EEPROM is never touched.  The
controller is left stopped.  The station address set by an earlier
`IFUP`/`PING` is overwritten -- the network utilities program it again when
they start, so nothing needs to be redone.

## Exit codes

| Code | Meaning                                                         |
|------|-----------------------------------------------------------------|
| 0    | No misread, no failed write (and with `-t` every frame was claimed) |
| 1    | Usage                                                           |
| 2    | No card found                                                   |
| 3    | A misread, a failed write, a reset timeout, or an unclaimed transmit |
