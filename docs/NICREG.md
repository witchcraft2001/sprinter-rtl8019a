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
*inside* one pass is an unstable read -- provided the register content is
constant, the pattern really went in, and the chip is on the page the test
thinks it is on.  NICREG checks those three conditions itself and says so
when one of them fails (`load=`, `setup retries=`, `page lost=`), instead of
counting the consequences as misreads.

NICREG sees the bus only through the bus.  It counts accesses that went
wrong and shows what came back; it does not measure a signal, and it cannot
see `IOCHRDY`.  A `RESULT FAIL` means "an access failed in this mode", not
a diagnosis of why.

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
RTL8019AS NICREG v0.3.24
[G0] Slot/Addr: 0/#300 chip=clone
[G1] RW STORAGE stopped, 14 regs x 2048 reads
 bad after-00=0000 after-FF=0000 cond=0000 load=00
[G2] PAGE2 CONFIG  written|and/or after 00|after FF  bad=0000
 PSTOP 60|60/60|60/60 TPSR  40|40/40|40/40
 RCR   04|04/04|C4/C4 TCR   02|02/02|E2/E2
 DCR   48|48/48|C8/C8 IMR   00|00/00|80/80
[G3] PAGE0 STATUS  and/or after 00|after FF  CR bad=0000
 CR    21/21|21/21 CLDA0 00/00|00/00 CLDA1 40/40|40/40 TSR   01/01|01/01
 ...
[G4] PAR=028019112233  per row: 288000 reads, 192000 writes
 row  rd-bad bits wr-lost wr-bad unsure cr-bad rxpages badticks withrx
 stop 0000   00   0000    0000   0000   0000   0000    0000     0000
 deaf 0000   00   0000    0000   0000   0000   0000    0000     0000
 live 0000   00   0000    0000   0000   0000   0012    0000     0000
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
| `[G1]` | stopped | `PAR0..5`, `CURR`, `MAR0..6` hold known patterns and are read back 2048 times each.  All 8 bits of these registers are implemented, so a mismatch is a misread -- unless all 512 reads of a pass return one and the same wrong value, which is a pattern that never went in (`load=`).  The second pass uses the complemented pattern: every bit is checked as a 0 and as a 1. |
| `[G2]` | stopped | Page-2 read-back of the configuration written on page 0.  Bits the DP8390 defines must match (`bad=` counts the ones that do not); reserved bits are only displayed. |
| `[G3]` | stopped | Page-0 status registers.  Only `CR` has a value that can be insisted on.  The rest is there to show which offsets the chip drives at all -- an undecoded offset reads `00/00` in the first pair and `FF/FF` in the second.  `CNT0..2` are read here with the receiver **stopped**, where they mean nothing: a UM9003AF shows a steady `7F` and the same card reports them correctly through `PING` while running. |
| `[G4]` | all three | One read + write/read-back loop against the chip stopped, started but deaf, and live on the LAN.  See below. |
| `[G6]` | deaf, live | The remote-DMA data port instead of the register file: 800 bursts of 128 bytes written into packet RAM and read straight back.  See below. |

In `[G1]` the line `bad after-00= after-FF= cond= load=` gives the misread
totals for the two passes and for the conditioner itself.  `load=` counts
the (register, pass) pairs in which every one of the 512 reads returned the
same wrong value: the register holds that value, so the **write** that
loaded the pattern failed (or a bit is stuck).  Those 512 are kept out of
the misread totals.  Registers that failed are listed below the line (at
most six) with `bits=` -- the bits that came back wrong; a failed load
shows there as `bad=0200`.  A fault confined to one bit points at a data
line; a fault on all bits points at strobe timing.

`[G2]` has no separate load check, but its table shows it: `48|4C/4C|4C/4C`
is a register that steadily holds `4C` after `48` was written -- a failed
write, not 512 misreads.

`RESULT FAIL` means at least one access to a driven bit went wrong.
Undriven bits never fail the run.

### `[G4]`: the same loop against a stopped and a started chip

`[G1]`..`[G3]` test a stopped chip.  On real hardware a chip that reads
back flawlessly while stopped has been seen to fail once it is started --
so `[G4]` runs one fixed loop against three states and lets the rows be
compared:

| Row    | Chip                   | Receiver                                  |
|--------|------------------------|-------------------------------------------|
| `stop` | stopped                | The control row.  Should be all zeros.    |
| `deaf` | started, `RCR=MON`     | Checks addresses, stores nothing: no buffer DMA. |
| `live` | started, `RCR=AB`      | Stores every broadcast on the LAN meanwhile. |

Per row, 1500 windows of 32 sweeps.  One sweep reads `PAR0..5` against the
station address shown in the header, then writes `MAR0..3` with a pattern
that flips every sweep and reads them back.  (`MAR` is unused while
multicast reception is off.)

This is a register hammer, not a model of network traffic: about half a
million accesses per row, a third of them writes to a running chip.  The
network utilities make far fewer register accesses per frame.  A machine
can therefore fail `[G4]` and still run `PING` and `FTP` without visible
trouble, and neither observation disproves the other.

#### How a mismatch gets its name

A read that differs from what was expected proves that **one** access went
wrong -- not which one.  Before it is counted, the register is read twice
more, and each of those reads comes right after a read of a conditioner
(`PAR0`; `PAR1` when `PAR0` is the suspect).  The conditioner's value is
known and unlike anything else in this phase, so it does two jobs: it shows
whether reads work at this very moment, and it replaces what the previous
cycle left on the bus, so that a cycle the chip does not answer cannot
return something that looks like register content.

| Column     | Counted when                                                  |
|------------|---------------------------------------------------------------|
| `rd-bad`   | A re-read returned the expected value.  The register held it all along, so the first read was wrong.  `bits` is the OR of the wrong bits.  This verdict is safe. |
| `wr-lost`  | `MAR` held the **previous sweep's** pattern on both re-reads, and both conditioner reads were right.  Reads demonstrably worked, so the content is real: the write did not go in. |
| `wr-bad`   | The register held something else on both re-reads, conditioner right.  For `MAR`: a garbled write.  For `PAR`: the station address was changed by something -- it is written back at once, so one event counts once. |
| `unsure`   | The re-examination itself failed: a conditioner read was wrong, the two re-reads disagreed, or the "content" was just the conditioner's value (the suspect did not answer).  Several accesses in a row went wrong.  Nothing is concluded about read versus write, and nothing is written. |
| `cr-bad`   | Page switches that were not confirmed at the first attempt.  See below. |
| `rxpages`  | Buffer pages the receiver filled meanwhile.  `0000` in the live row means a silent LAN: repeat with traffic. |
| `badticks` | Windows (of 1500) that contained any failure.                 |
| `withrx`   | How many of those were windows in which a frame arrived (or the window after: a frame still arriving when a window closes moves the ring in the next one).  Compare with chance: with `rxpages=0043` a frame arrives in about 9 windows out of 100, so 15 unrelated bad windows would give `withrx` 1 or 2.  `000C` of `000F` is not chance. |

What `wr-lost` still cannot exclude: a fault that misreads one register,
three times running, as exactly the complement of its content, while the
register next to it reads correctly in between.  No test that looks through
the bus can exclude that.  No known bus fault behaves like it either -- an
unanswered cycle returns the bus leftover, which is now the conditioner.

#### Page switches

Every page switch writes `CR`, then reads offset `03`, then reads `CR`
back.  Offset `03` is `PAR2` on page 1 (must be `19`) and `BNRY` on page 0
(must lie inside the ring); the two cannot be confused.  Reading `CR` back
alone would not do: after a `CR` write the value left on the bus **is** the
value being checked for, so a chip that ignored both the write and the read
would pass.

A switch that fails the check is repeated, up to four times, and counts
once in `cr-bad`.  Which of the three cycles failed is not known, so
`cr-bad` is an access failure, not proof of a lost write.

If four attempts fail, the window is abandoned without touching another
register -- whatever page the chip is on, nothing is written there -- and
the row's chip state is set up again from scratch.  The extra line

```
  page lost=0001 setup retries=0000
```

appears only when that happened.  `setup retries` counts setups that had
to be repeated because the station address did not read back right after
it was written (the setup is verified before the row starts, so a write
that failed during setup is not counted 48000 times as a misread later).
`row aborted` means four setups in a row failed and the row was given up.

Versions up to 0.3.23 carried on after a failed switch.  The sweep then ran
on the wrong page and the ring drain wrote `BNRY` into `PAR2`: the test
damaged the register it was checking and reported tens of thousands of
"misreads".  This was seen on real hardware.

#### The sample lines

The `rd` line lists the first six `PAR` reads that came back wrong,
whatever the verdict: register, **the value that came back**, and after `@`
the sweep number `00`..`1F` inside the window.  A value equal to the
register read just before it (`PAR1=02`: `02` is what `PAR0` holds) means
the chip did not answer that cycle and the host latched what was left on
the bus.  Misreads that are all `PAR0` at `@00` would instead point at the
first access after the window opens.

`rd-bad` also counts misread `MAR` read-backs, and those are not listed:
`0006` with four samples means two of them.

The `wr` line lists the first four `wr-lost`/`wr-bad` events as *wanted*
`>` *held*.  For `MAR`, *held* equal to the complement of *wanted* is the
previous sweep's pattern.  `PAR2=19>4B` is a station-address byte found
holding `4B`.

The `MAR` patterns are `1E 2D 87 36`, complemented on odd sweeps.  No value
is the complement of another.  (Up to 0.3.23 they were `3C C3 69 96`:
`MAR1` and `MAR3` wanted exactly the complement of what `MAR0` and `MAR2`
had just returned, so for those two registers a bus leftover was
indistinguishable from "the previous pattern".)

#### A real run, and what it does and does not prove

UM9003AF on a Sprinter, ordinary home LAN, **NICREG 0.3.20** (older column
set, older classification):

```
 row  rd-bad bits wr-lost wr-bad cr-bad rxpages badticks withrx
 stop 0000   00   0000    0000   0000   0000    0000     0000
 deaf 0011   FF   0007    0000   0000   0000    0012     0000
  rd PAR1=02@0D PAR5=22@06 PAR2=80@1C PAR3=19@1D PAR1=02@1A PAR5=22@05
  wr MAR3=69>96 MAR3=69>96 MAR1=3C>C3 MAR1=C3>3C
 live 0006   FF   000F    0000   0002   0043    000F     000C
  rd PAR3=19@12 PAR0=96@19 PAR5=22@00 PAR1=02@17
  wr MAR1=3C>C3 MAR2=96>69 MAR3=69>96 MAR2=69>96
```

The same card, the same evening, **network cable unplugged**: all three
rows zero, `RESULT OK`.  Cable back: failures back, `withrx=0009` of
`badticks=000D`.

What stands:

- The stopped chip is clean and the started chip is not.
- The failures need frames on the wire; CPU speed does not matter.
- The `rd` samples are bus leftovers (`PAR1=02`, `PAR2=80`, `PAR3=19`: each
  is the value of the register read just before).  The chip sat those
  cycles out.
- `badticks` below the number of failures means they come in bursts inside
  one 1.5 ms window.

What does not stand: the `wr-lost` figures.  0.3.20 called a write lost
after two plain re-reads, and six of the eight `wr` samples are `MAR1` or
`MAR3` -- the two registers where, with the old patterns, an unanswered
read returned precisely "the previous pattern".  A short burst of
unanswered **reads** explains them as well as lost writes do.  Only the
two `MAR2` samples cannot be explained that way.  That a started chip can
miss a write is known independently (the `BNRY`-into-`PAR2` event above
needs a lost `CR` write), but how often is not: repeat the run with 0.3.24
before quoting a number.

The live row of a later run also listed `PAR3=4C`, `PAR3=4D`, `PAR3=56`:
not a bus leftover, but receive-ring page numbers, rising as the ring
filled.  The read collided with the chip's own receive work and returned
the chip's internal value.

A DP8390 holds a host register access off while it is busy (its `ACK`
output; an NE2000 turns that into `IOCHRDY`).  A host that does not wait
would get this picture.  NICREG cannot see `IOCHRDY`, so it shows the
dependence on wire traffic, not the electrical cause.

How to read the rows:

| Pattern                             | Meaning                               |
|-------------------------------------|---------------------------------------|
| all rows zero                       | No access failed in any chip state, in this run. |
| `stop` zero, `deaf` and `live` alike | Access to a **started** chip fails now and then, buffer DMA or not. |
| `stop` zero, `deaf` bad, `live` bad with `withrx` close to `badticks` | The failures follow frames on the wire, stored or not.  **Repeat with the network cable unplugged:** if `deaf` and `live` turn zero, the chip misses host cycles while its receiver is busy with a frame. |
| only `live` bad, `withrx` = `badticks` | Accesses collide with the chip's receive-buffer DMA.      |
| `unsure` high, `rd-bad` low         | The failures last several cycles in a row.  Look at the `rd` samples: a run of equal values is one long unanswered stretch. |
| `badticks=0001` with counts in the tens | One long event: for part of a single window every register answered with the same wrong values (`PAR0..5` all `47`), then the chip recovered by itself.  Seen once (cable unplugged, 7 MHz, `live` row); cause unknown.  Repeat the run and see whether it comes back. |
| `stop` bad too                      | Not related to the chip running; `[G1]` should show it as well.  |

Why `cr-bad` and `wr-lost` matter more than `rd-bad`: a driver can read a
register twice, but a page switch that did not happen sends the writes that
follow into another page.  The driver confirms its page switches for that
reason, and since 0.3.25 it confirms them the way this phase does: each
read-back of `CR` is preceded by a read of another register, so a cycle the
chip sits out returns something other than the value being looked for, and
the whole check is done twice.

## `[G6]`: the remote-DMA data port

```
[G6] DMA DATA PORT, per row: 800 bursts x 128 bytes
 row  bytes  rd-bad mem-bad unsure bursts rdc-to rxpages
 deaf 0000   0000   0000    0000   0000   0000   0000
 live 0000   0000   0000    0000   0000   0000   0018
```

`[G1]`..`[G4]` only ever touch the 16-byte register file.  A real utility
spends almost every ISA cycle somewhere else: the data port at `BASE+0x10`,
pushed and pulled a whole frame at a time with no read-back anywhere.  A
cycle lost there is a corrupted frame, not a register worth retrying, and
nothing above would notice.

Each burst writes 128 bytes of `offset XOR seed` into packet RAM at
`0x4000` -- TX RAM, below `PSTART`, where the receiver never writes -- and
reads them straight back.  The seed changes every burst, so stale contents
cannot pass, and neighbouring bytes always differ, so a cycle the chip does
not answer (the bus then still holds the previous byte) shows up.

| Column    | Meaning                                                      |
|-----------|--------------------------------------------------------------|
| `bytes`   | Bytes that came back wrong, over the whole row.               |
| `rd-bad`  | Of those, the ones a second read pass found intact: the first read lied, packet RAM is fine. |
| `mem-bad` | The second pass found as many wrong again: what sits in packet RAM is wrong, so a **write** cycle was lost. |
| `unsure`  | The second pass agreed with neither, or could not be run.     |
| `bursts`  | Bursts with at least one bad byte or a failed transfer.       |
| `rdc-to`  | Transfers that could not be armed, or that never reported completion. |
| `rxpages` | Buffer pages the receiver filled meanwhile, as in `[G4]`.     |

The two passes are counted, not matched offset by offset, so "as many
again" is a strong hint and not a proof.

There is no stopped row.  Every remote-DMA command carries `STA`, so a
burst starts the chip by definition; the control is `[G4]`'s stop row,
which runs over the same bus under the same window discipline.

Seven register writes have to land before a burst exists, and they are
checked **after** the transfer, never before it: `ISR.RDC` must be set and
`CRDA` must have landed exactly 128 bytes on, which proves that `RSAR`,
`RBCR` and the command all reached the chip.  A burst that fails either
test goes to `rdc-to` and its bytes are not compared at all.

The order matters more than it looks.  Arming a remote DMA makes the chip
prefetch the first byte into its FIFO, and on a UM9003AF anything between
that command and the first data cycle leaves that byte to be popped a
second time -- the whole burst then reads one byte behind, in every burst
of every row, with and without traffic on the wire.  Both a read-back of
`CRDA` in that gap and a second arming after it did it.  So the phase arms
once, touches nothing, and transfers, exactly as the driver does.

A sample line names the first four bad bytes as `offset=written>read`:

```
  dma 0A=5C>5D 1F=41>40
```

### What the first real run said

UM9003AF, ordinary home LAN, NICREG 0.3.28: **both rows zero**, 409600
data-port cycles without a single bad byte, while `[G4]` in the same run
failed 19 reads and 12 writes out of 480000 register cycles in its `deaf`
row alone.  At that rate the data port should have produced about
thirteen.  It produced none, and it is hit *harder*: the transfer loop
touches the chip every 33 T-states against 57 in `[G4]`.

So on this card the fault is not the bus and not the speed of it.  It is
the register file specifically, and only while the receiver is running --
which is the same story the `rd` samples tell when they come back holding
`CURR`.  For a utility that means frame payloads are not what is at risk;
the control registers are.

The same card, two runs back to back, the only difference being the cable:

| Cable      | `[G4]` deaf        | `[G4]` live        | `[G6]`  | Result        |
|------------|--------------------|--------------------|---------|---------------|
| plugged    | 5 rd, 4 wr lost    | 5 rd, 4 wr lost    | clean   | `RESULT FAIL` |
| unplugged  | 0                  | 0                  | clean   | `RESULT OK`   |

Unplugged, 960000 register reads and 640000 writes against a started chip
were all clean.  The `deaf` row stores nothing, yet it fails as often as
`live` when the cable is in.  So the trigger is the chip *looking at*
frames on the wire, not storing them, and a started receiver alone is not
enough.  The error count also varies from run to run with the traffic on
the segment: this run had 9 in `deaf`, the previous one 31.

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

The source address is NICREG's own test address, **not the card's MAC**,
and the destination is broadcast: a capture filter on the card's MAC or on
an IP address (`ether host ...`, `host ...`) hides every one of these
frames.  Filter on the EtherType, or do not filter at all.

Count the frames per mode letter.  `B` arriving in full while `A`
loses frames means that accessing the chip during a transmission disturbs
it.  All three modes losing the same share means the loss is not caused by
how the driver talks to the chip.

`isr=` is the `and/or` of every `ISR` value read while waiting, `tsr=` the
same for the transmit status afterwards.  An `isr=` OR of `FF` would be a
floating-bus read in the middle of a transmission.

## What it writes

`CR`, the page-1 registers (`PAR`, `CURR`, `MAR`; `MAR0..3` a few hundred
thousand times; a `PAR` byte found damaged is written back), and on page 0 the
ordinary configuration registers plus `PSTART` and `BNRY`, which serve as
conditioners and are restored.  The EEPROM is never touched.  The
controller is left stopped.  The station address set by an earlier
`IFUP`/`PING` is overwritten -- the network utilities program it again when
they start, so nothing needs to be redone.

## Exit codes

| Code | Meaning                                                         |
|------|-----------------------------------------------------------------|
| 0    | No failed access (and with `-t` every frame was claimed)        |
| 1    | Usage                                                           |
| 2    | No card found                                                   |
| 3    | A failed access, a reset timeout, or an unclaimed transmit      |
