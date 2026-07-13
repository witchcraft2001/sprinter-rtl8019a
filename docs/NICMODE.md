# NICMODE.EXE

Inspects the RTL8019AS duplex configuration and, only after an explicit
confirmation, changes the persistent `CONFIG3.FUDUP` bit in the on-card
93C46 EEPROM.

## Why this utility exists

RTL8019AS does not auto-negotiate duplex.  Its `FUDUP` bit is loaded from
EEPROM and is read-only during normal operation.  A modern auto-negotiating
switch/router detects a legacy 10BASE-T link as 10 Mbit/s **half-duplex**.
If the card is configured full-duplex, the two ends disagree and frames can
be lost even though the NIC reports `PTX` and `TSR=03`.

## Usage

```text
NICMODE
NICMODE HALF -y
NICMODE FULL -y
NICMODE /?
```

- `NICMODE` is read-only.  Run this first.
- `NICMODE HALF -y` is the normal choice for an auto-negotiating peer.
- `NICMODE FULL -y` is valid only when the peer port is manually forced to
  10 Mbit/s full-duplex.
- Without `-y`, EEPROM is never changed.

## Safety checks

The write path:

1. reads EEPROM word 1 twice;
2. finds the CONFIG3 byte by a unique match of its media/duplex bits to
   active CONFIG3 (HIGH/LOW word-byte order is not assumed);
3. preserves CONFIG4 and every CONFIG3 bit except FUDUP;
4. writes one 16-bit word;
5. waits with the Sprinter ISA window closed;
6. disables further EEPROM writes and reads the word back;
7. applies the verified value with RTL8019AS auto-load.

Any inconsistent read or verify mismatch prints `RESULT FAIL` and stops.
Do not power off the machine while `[W10] EEPROM WRITE` is on screen.

## Expected first run on the affected card

```text
RTL8019AS NICMODE v0.2.16
[N0] Slot/Addr: 0/#300
[N1] RTL ID=Pp
[N2] EEPROM W1=00F0 READ2=00F0
[N3] CONFIG3=70 DUPLEX=FULL
[N4] EEPROM CONFIG3=F0 MAP=LOW
[W03] FUDUP=1: force peer 10M/full or run NICMODE HALF -y
RESULT OK
```

`00F0` is the expected value inferred from the first affected card; `80F0`
is also consistent with its earlier shifted read because the old code lost
D15.  The decisive fields are two equal reads, `CONFIG3=F0 MAP=LOW`, and no
`[E13]`.  Other card EEPROM images may report `MAP=HIGH`.  All word bits are
preserved; only FUDUP (`0x40`) in the detected CONFIG3 byte can change.

Version 0.2.11 incorrectly discarded a separate dummy sample after the READ
address.  The RTL8019AS interface has already exposed the dummy bit during
the last address clock, so that sample was D15 and the returned word was
shifted left.  Its stable `W1=01E0 READ2=01E0` result proved that the serial
link worked, but `[E13]` correctly prohibited an EEPROM write.  Do not use
the 0.2.11 write command.

The real-card read-only test of 0.2.12 returned `W1=00F0 READ2=00F0`,
`CONFIG3=70`, and `EEPROM CONFIG3=F0 MAP=LOW`, exactly confirming the fixed
clock phase and byte mapping.  Version 0.2.13 only removes the duplicate
`RESULT OK/FAIL` line before the write-path field test.

After a successful `NICMODE HALF -y`, run `NICINFO`, then run `IFUP` again
before `PING` or other network utilities.  Expected `NICINFO` values are
`C3=30` and `DUPLEX=HALF` for the card that previously reported `C3=70`;
all bits other than FUDUP remain unchanged.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Status read or requested mode applied successfully |
| 1 | Usage error or missing `-y` confirmation |
| 2 | RTL8019AS not detected |
| 3 | EEPROM read, consistency, write-verify, or auto-load error |
