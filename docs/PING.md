# PING.EXE

Sends ICMP echo requests, prints replies and per-run statistics.

## Usage

```
PING [-t] [-b|-m] [-r] [-n count] [-l size] [-i TTL] [-w ms] target
PING /?
```

| Option   | Meaning                                                |
|----------|--------------------------------------------------------|
| `-t`     | Ping until interrupted (Esc / Ctrl+C).                 |
| `-b`     | Diagnostic: force Ethernet destination to broadcast.  |
| `-m`     | Diagnostic: use IPv4 all-hosts multicast destination.  |
| `-r`     | Diagnostic: reset/reinit NIC before each ICMP transmit. |
| `-n N`   | Number of echo requests (default 4, max 255).          |
| `-l N`   | Payload size in bytes (default 32, max 255, odd sizes allowed). |
| `-i TTL` | IP TTL on outgoing requests (default 64).              |
| `-w MS`  | Per-reply wait timeout in milliseconds (default 4000). |
| `target` | Destination IPv4 or hostname.                          |

`-t` and `-n` are mutually compatible: when `-t` is supplied, the
count from `-n` is ignored and the loop continues until the user
cancels.

## Example

```
RTL8019AS PING v0.2.16

Pinging 192.168.7.1 with 32 bytes of data:
Reply from 192.168.7.1: bytes=32 time=1ms TTL=63
Reply from 192.168.7.1: bytes=32 time<1ms TTL=63
Reply from 192.168.7.1: bytes=32 time=2ms TTL=63
Reply from 192.168.7.1: bytes=32 time=1ms TTL=63

Ping statistics for 192.168.7.1:
    Packets: Sent = 4, Received = 4, Lost = 0.
RESULT OK
```

`time=` is the measured round trip, taken from the same ~1 ms poll
tick that drives the reply timeout, so its resolution is one
millisecond. A reply that arrives before the first tick prints
`time<1ms`. The figure can only err high, never low: the receive
loop charges one unit per non-matching frame it drains, so heavy
broadcast traffic inflates the number rather than hiding a slow
reply.

`TTL=` is the TTL of the reply packet, which is what shows how many
hops away the peer is. It is not the TTL of the request; use `-i`
to set that one.

## Exit codes

| Code | Meaning                                                  |
|------|----------------------------------------------------------|
| 0    | At least one reply was received                          |
| 1    | Usage                                                    |
| 2    | RTL8019AS not detected                                   |
| 3    | All requests timed out / cancelled                       |
| 4    | Config                                                   |

On a transmit failure PING also prints the driver snapshot:

```text
TX stage=E4 ISR=00 TSR=01 CR=22
```

Stages `E0..E6` distinguish remote-DMA failure, busy transmitter,
stale uncleared ISR status, timeout, TXE, and TX packet-RAM prefix
read-back mismatch (`E3` is reserved for old builds).  Stage `04` means that the
DMA read-back and the complete hardware transmit state machine passed.
On timeout PING also decodes the 42-byte prefix read back from NIC packet
RAM and prints raw CLDA.  For the default 74-byte echo frame the expected
decoded values include `len=004A`, `type=0800`, and ICMP type `08`.
PING saves a private copy of the ICMP TX snapshot immediately after
`SEND_FRAME`.  A later ARP reply sent while waiting for ICMP therefore cannot
replace the timeout diagnostics.  The expected saved EtherType is `0800`;
`0806` would now identify an actual snapshot bug rather than a later reply.
CLDA is shared local-DMA state that may already reflect RX traffic; it is
not a TX byte counter and no fixed `TPSR + length` value is expected.
The following `PHY C0=pre>post C3=pre>post NCR=xx` line captures page-3
`CONFIG0`/`CONFIG3` immediately around TXP and the page-0 collision count.
On the affected physical card, v0.2.10 measured stable
`C0=08>08 C3=70>70 NCR=00`: UTP stayed selected but FUDUP remained enabled.
A changed `C0` would instead indicate TP/CX auto-detect switching away from
UTP while the frame is sent.

Page 3 is a Realtek extension.  On a chip that does not report the
Realtek ID the driver does not select or read it at all, and the line
reads `PHY n/a (no page 3) NCR=xx TPSR=xx` instead.  A UMC UM9003
answers page-3 reads with a copy of page 1, so the old unconditional
capture printed MAC bytes (`C0=95 C3=3D`) dressed up as a medium and
duplex setting.  `NCR` and `TPSR` come from pages 0 and 2, which every
DP8390 has, so they are still shown.

## The `NIC` line: what the card threw away

Every timeout ends with the card's own error account:

```text
 NIC fae=00 crc=02 mpc=00 rsr=21
```

These are the page-0 tally counters (`CNTR0`/`CNTR1`/`CNTR2`) plus `RSR`.
They answer the question the rest of the dump cannot.  `(rx=0 frames)` with
an unchanged `CURR` proves only that nothing was *stored*: a frame the
receiver rejects is discarded before it reaches the ring, so it moves no
pointer and leaves no trace anywhere else.

| Field | Meaning when non-zero                                            |
|-------|------------------------------------------------------------------|
| `fae` | Frame alignment errors -- damaged frames on the wire.            |
| `crc` | CRC errors -- same class: cable, port, duplex, marginal PHY.     |
| `mpc` | Missed packets -- no ring space, or the receiver was halted.     |
| `rsr` | Receive status of the last *stored* frame (not a counter).       |

So `fae`/`crc` non-zero means the reply may well have arrived and been
dropped on the floor by the PHY; `mpc` non-zero points at this driver
rather than the network; all-zero says the NIC genuinely saw nothing and
the loss is upstream of this machine.

If the line ends with `(no tally counters on this chip)`, the three
figures mean nothing: the chip answered with a fixed value and did not
clear it on reading, so it has no counters.  Only `rsr` is still
meaningful there.

The counters are cleared by reading, and PING samples them at the end of
*every* echo -- successful ones included.  The printed figures therefore
cover the lost echo's wait alone, not the whole run.  `ISR` bit 5 (`CNT`)
is cleared with them, so a later `ISR=20` means a counter overflowed
again rather than at some forgotten point during startup.

The `-b` switch changes only the Ethernet destination to
`FF:FF:FF:FF:FF:FF`; the target IPv4 address and ICMP packet remain intact.
It is intended for real-hardware diagnosis.  Seeing the IPv4 request in a
packet capture is sufficient for this test; the destination host is not
required to answer an IP unicast packet carried in an Ethernet broadcast.
The driver enforces a 20 ms RX-to-TX guard after consuming a received frame.
The ISA window is closed and system interrupts remain enabled during this
guard; it applies to all utilities using `RTL.SEND_FRAME`, not just PING.

The mutually exclusive `-m` switch uses `01:00:5E:00:00:01`.  Unlike the
all-ones broadcast address it contains zero bits, but an Ethernet bridge
should still distribute it as the IPv4 all-hosts group.  It distinguishes
destination-byte corruption from ordinary unicast bridge forwarding.

The `-r` switch preserves the ARP-resolved target MAC in CPU RAM, then resets
and reinitializes the RTL8019AS immediately before every ICMP transmit.  It
tests the real-card condition where the broadcast ARP is visible on the wire,
the following unicast ICMP is absent, but the NIC nevertheless reports
`PTX/TSR=03`.  Timeout diagnostics also print page-2 `TPSR`; the expected
value is `40`, matching the verified TXRAM address `0x4000`.
