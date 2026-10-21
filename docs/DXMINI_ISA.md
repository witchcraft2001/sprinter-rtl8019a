# DX Mini external ISA: field investigation, 2026-10-09

Developer notes; not a shipped document. No electrical fix has yet been
verified on the failing machine.

## Observations

NICREG 0.4.1, full Sprinter DX, RTL8019AS, LL4148 on IOCHRDY/WAIT,
cable connected: all checked counters zero, RESULT OK. Reception was active
(G4 live rxpages=0019; G6 live rxpages=0007).

On the full DX, the UM9003AF had previously failed with the cable connected
and passed with it disconnected. This is the earlier cable-dependent case
in NICREG.md, not evidence that the DX Mini has the same failure.

DX Mini with external ISA, UM9003AF, BAT48 in place of LL4148:

- Turbo off: hangs after the G1 heading, with or without the cable.
- Turbo on: some runs finish, but fail; some hang. Cable removal does not
  cure it. G1-G3 may pass while G4 cannot establish/retain its chip state.
- G4 samples include FF reads and ring-page values in place of PAR bytes;
  bounded setup retries are exhausted. A page switch or its confirmation
  can fail; the display cannot distinguish these electrically.
- G6 samples include 00=01>00, 02=03>02, 04=05>04, 06=07>06. These fit
  several causes, including a read sequence error or bit-0 corruption.
  Four mismatch samples alone cannot distinguish them. mem-bad counts
  repeatable mismatches, not proven packet-RAM corruption.

## Schematic checks

Sources supplied by the user:

- board/spdx_release_v306_25.05.2025/docs/sp-dx-sch.pdf, CPU and ISA sheets.
- ext-isa.pdf, title ext-cpu-isa.SCH, External ISA-8, dated 2025-12-02.
- Main-board sp-dx-mini.net confirms WAIT at CPU U3 pin 11, X28 A38,
  FPGA U12 pin 18 and R37 pin 1.

External VD12: anode on WAIT, cathode on IOCHRDY (ISA A10). The band of a
replacement diode belongs on the IOCHRDY side. External R47 pulls IOCHRDY
up to +5 V through 4.3 kohm; main-board R37 pulls WAIT up through 1 kohm.
When the card pulls IOCHRDY low, it also sinks current from R37 through the
diode. For levels around 0.2/0.6 V, the two pulls total approximately
5.5 mA, excluding any other pull-ups. WAIT low is IOCHRDY low plus diode
forward drop. BAT48 reduces the latter but does not establish the actual
loaded levels or guarantee that a card releases IOCHRDY.

U5 is a 74HC245 data transceiver. Its direction is RD and its enable is
decoded by DD2; it is not permanently enabled. U8/U11 buffer addresses.
The user confirms HC245 parts are installed as drawn. HC uses CMOS input
thresholds; HCT uses TTL thresholds. U5 therefore needs a level-compatibility
check with the card, and U8/U11 with CPU outputs. HCT replacements correct
TTL threshold compatibility, but are not yet a demonstrated cure for this
hang. The passing RTL8019AS run does not prove levels for the UM9003AF.

## Next measurements

Physical measurements are deferred at the user's request until an
oscilloscope and soldering iron are available: the dense assembly cannot
be accessed safely with the available multimeter probes. The steps below
are a continuation plan, not completed measurements.

On the Mini, run NICREG -v with turbo off and no cable; retain the last
printed line. With the machine still hung, use DC volts relative to GND:

| Node | Accessible point | Purpose |
|------|------------------|---------|
| +5 V | ISA B3/B29 | Reference supply |
| IOCHRDY | VD12 cathode / ISA A10 | Card's ready level |
| WAIT | VD12 anode / X1 A38 | CPU's actual wait level |
| IORD | ISA B14 / R194 card side | Persistent read strobe |
| IOWR | ISA B13 / R188 card side | Persistent write strobe |

Use connector pin names, not a guessed physical orientation. Power off
before continuity/resistance checks. Z84C15 specifies input low <=0.8 V
and input high >=2.2 V. A stable low WAIT is consistent with a held bus
cycle; high WAIT rules out a continuously asserted external WAIT at that
instant, not intermittent pulses. A multimeter cannot check strobe width,
glitches, recovery time or clock phase.

Software timeouts cannot release a CPU stalled inside a memory cycle by
WAIT. Do not treat passing host/MAME tests as validation of this external
electrical handshake. The available MAME ISA path supplies fixed bus waits;
it does not simulate the physical IOCHRDY/diode chain.

## Primary references

- Zilog PS018201-0602, DC characteristics, printed p.348:
  https://www.zilog.com/docs/z80/ps0182.pdf
- Nexperia 74HC245/74HCT245, input levels and static characteristics:
  https://assets.nexperia.com/documents/data-sheet/74HC_HCT245.pdf
- ST BAT48, static electrical characteristics (forward drop is nonzero):
  https://www.st.com/resource/en/datasheet/bat48.pdf
