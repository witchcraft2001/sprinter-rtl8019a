# Host-side EXE test harness (developer-only)

This document is developer-only: it lives in `docs/` for discoverability
but is **not** added to `DIST_DOC_FILES` in `tools/artifacts.sh` and does
not ship in the ZIP or the floppy image.

## What it is

`tools/exe-harness/` executes real, built Sprinter DSS `.EXE` files from
`build/` under a JavaScript Z80 interpreter ([Z80core.js][z80core], MIT,
Molly Howell -- see `THIRD_PARTY.md`), with strict host-side models of:

- **Memory & paging**: a flat 1 MB backing store split into 4 x 16 KB
  windows (`WIN0..WIN3`), matching Sprinter's MMU. `GETMEM`/`FREEMEM`/
  `SETWIN1..3`/`SETWIN` (DSS) and the BIOS `EMM_FN4` (physical-page lookup)
  are modeled, so `CLAIM_RUNTIME_PAGE` (`src/lib/win2page.asm`) and any
  future paged-memory consumer (`pagemem.asm`) work without special-casing.
- **The Sprinter ISA window** (`src/lib/isa.asm`): `PORT_SYSTEM` (0x1FFD),
  `PORT_ISA` (0x9FBD) and the `PAGE0..3` MMU ports (0x82/0xA2/0xC2/0xE2),
  including the IFF2 sample/restore contract around `ISA_OPEN`/`ISA_CLOSE`.
- **The RTL8019AS/DP8390 chip** (`tools/exe-harness/rtl8019-model.js`):
  register file (all 4 CR pages), PROM (direct/doubled layout), remote DMA,
  the TX path (including padding/verify), the RX ring (wrap, overflow +
  recovery), and clone quirks (`UM9003`, MAME-vs-real-hardware loopback and
  ISR.RST-on-STOP behavior).
- **DSS/BIOS**: the function surface these utilities actually use (file
  I/O, `ENVIRON`, `APPINFO`, `GETMEM`/`SETWIN`, `WAITKEY`/`SCANKEY`, console
  output, `EXIT`) plus the RST 8 `EMM_FN4` call.

It runs real compiled binaries, not a reimplementation of the driver, so it
exercises the exact bytes `tools/build.sh` produces.

[z80core]: https://github.com/DrGoldfire/Z80.js

## Why

There is no MAME-free way to test a Z80 DSS program otherwise. The harness
lets driver, stack and app changes be checked in seconds instead of a
MAME-boot-and-screenshot cycle, and it makes intermittent, hard-to-repro
bugs (RX ring overflow ordering, ISA discipline violations, DSS ABI
mismatches) into fast, deterministic, CI-friendly test vectors. It is a
*strong signal*, not a MAME/hardware replacement -- see `AGENTS.md`'s
Testing Guidelines for the full acceptance policy.

## Running it

```sh
make test-host              # full gate: syntax checks, checksum pin,
                             # build, and all test suites
node tools/test-exe-harness.js   # NIC-diagnostics suite (NICINFO, NICRAM,
                                  # NICLB, NICTX, NICRX, ISAPROBE)
node tools/test-exe-net.js       # protocol-app suite (ARP, PING, PINGALT,
                                  # UDPTEST, NSLOOKUP, NTP, IFUP, NETCFG, TFTP)
node tools/test-exe-tcp.js       # TCP client suite (WGET, DLDIRECT, DLDIRCP,
                                  # DLSPEED via UNETRTL.DLL)
node tools/test-exe-dll.js       # libman/UNETRTL.DLL consumer (UNETTEST)
```

`tools/exe-harness/net-builders.js` adds reactive protocol responders (ARP,
ICMP, UDP echo, DNS, NTP, DHCP, TFTP) on top of the chip/DSS/ISA models:
declare `scenario.responders = {arp: {...}, icmp: {...}, ...}` and the
harness answers the driver's own transmitted frames instead of requiring a
pre-scripted `rxFrames` list. See the responder option shapes inline in
`net-builders.js` and the vectors in `tools/test-exe-net.js` for examples.

For ad hoc debugging of a single EXE:

```sh
node tools/exe-harness/run.js build/NICINFO.EXE "" scenario.json
```

`scenario.json` is optional; omit it (or pass `{}`) for the default
scenario (card present, slot 1, base 0x300, default MAC/PROM). The command
prints the full result object as JSON and exits 0 iff the EXE's own exit
code was 0.

## Scenario schema (informal)

```js
{
  cardPresent: true,        // false -> no chip responds anywhere
  slot: 1,                  // 0 or 1
  base: 0x300,              // 0x200..0x3E0, step 0x20
  mac: [0x02,0x80,0x19,0x11,0x22,0x33],
  promLayout: 'direct',     // 'direct' | 'doubled' | 'unknown'
  promSignature: 0x57,      // 0x57 ('W','W') or 0x42 ('B','B')
  quirks: {
    variant: 'RTL8019AS',   // or 'UM9003' (id0/id1 read as 0x20/0x01,
                             // measured on the card -- not 0xFF, which is
                             // the open-bus value an absent card gives)
    loopbackToRing: true,   // MAME: loopback frame lands in the RX ring + PRX.
                             // false: real-HW FIFO/RSR path (no PRX).
    isrRstOnStop: false,    // MAME: STP alone does not set ISR.RST.
                             // true: real HW sets it immediately.
    hangOnResetPort: false, // UM9003-style clone: reading BASE+0x1F throws.
                             // Models a stalled ISA cycle, which on real
                             // hardware freezes the machine outright, so
                             // "did not throw" is the assertion.  Used to
                             // prove the driver only pulses that port on a
                             // card that reports the Realtek ID.
  },
  config: { cfg0, cfg1, cfg2, cfg3, cfg4 }, // page-3 CONFIG raw bytes
  txError: true,             // or {attempts:[1,2]} to fail specific TXP attempts
  corruptDmaReadAt: 3,       // flip a bit in the Nth byte streamed back
                             // through the remote-DMA data port
  rxFrames: [{ bytes: 'hex-or-array', afterMs: 3 }],
  environment: { NET_RTL_HW: '1/#300', ... },
  files: { 'C:\\NET\\FOO.TXT': 'contents' },
  currentDir: 'C:\\NET',
  appDir: 'C:\\NET',
  key: 'escape',             // simulated WAITKEY/SCANKEY input
  keyAtScan: 3,               // which SCANKEY poll delivers it
  strictClosedChipAccess: true, // default; false disables invariant #8
  fastDelayLoops: true,      // default; false disables DELAY_1MS fast-forward
  poison: true,               // default; fills RAM/NIC-RAM with 0xAA first
  stepLimit: 200000000,
  traceCpu: false, traceDss: false, dumpMemory: [[addr, len], ...],
}
```

## Result shape (informal)

```js
{
  exitCode, output,                 // stdout text, DSS_EXIT code
  transmittedFrames: ['hex', ...],  // frames the driver actually sent
  cleanup: { isaClosed, pagesFreed, filesClosed },
  card: { slot, base, present, mac, par, cr, isr, bnry, curr,
          rxHalted, txAttempts, rxDelivered, stats },
  environment, currentDir, files,
  steps, minimumSp, logicalMs,
  closedChipAccesses: [{ address, pc, dir }, ...],
}
```

`cleanup.pagesFreed` reflects whether the app explicitly freed its DSS
pages **before** `EXIT` -- it is `false` (and not a bug) for any
`CLAIM_RUNTIME_PAGE` consumer (`src/lib/win2page.asm`), since real DSS
`EXEC`/`LEAVE` reclaims those automatically. Use
`checkCleanupClaimedPage()` (`tools/exe-harness/test-util.js`) instead of
`checkCleanup()` for those apps.

## Invariants (the harness throws when violated)

1. A DSS call (`RST 0x10`) while the ISA window is open. (Both RST
   vectors count as service entry points only while window 0 still holds
   the system page; a program that remaps window 0 -- win0cold.asm's
   cold-overlay RUN does -- turns 0x0008/0x0010 into plain memory its own
   code may legitimately execute across.)
2. `EXIT` with the ISA window open, or with any file handle still open.
3. Interrupts enabled (`IFF1=1`) at any access to the chip's 32-byte
   register aperture while the ISA window is open.
4. `util.asm`'s `DELAY_1MS` loop executing while the ISA window is open
   ("never delay with the window open").
5. Malformed `PORT_SYSTEM`/`PORT_ISA` sequences.
6. Chip-model-level protocol violations (remote DMA data port access with
   `RBCR=0`, an illegal page-2/3 register write, `DCR.WTS=1`, etc.) --
   these throw from `rtl8019-model.js` itself.
7. An unknown I/O port, `strictPc` (PC escaped the loaded image), or the
   step limit.
8. (Opt-in only, `strictClosedChipAccess: true`) a read/write that lands in
   the chip's register aperture address range while the ISA window is
   closed. **Off by default** and recorded (not thrown) otherwise: the chip
   is only ever reachable through the `isaOpen`-gated path, by
   construction, so this can never observe a real "forgot to open ISA"
   bug -- it is ordinary window-3 DSS paged memory that happens to share
   the address range (e.g. `libman13.asm`'s DLL loader legitimately
   `SETWIN3`s a scratch block there). Kept as an opt-in for a scenario
   that specifically wants to assert nothing else ever maps that range.

Bugs the harness would have caught automatically, for reference: the
`LISTEN` ACK off-by-one, the `WIN0COLD.RUN` `BC` clobber, and the
`RTL.READ_PACKET` blind-clear of `ISR.OVW` (see `MEMORY.md`-style project
notes and `docs/UNETRTL.md`'s changelog).

## Writing new vectors

Follow the existing style in `tools/test-exe-harness.js`: build a scenario,
call `runExe`, assert on `output` (regex against the exact `[Xn]`/`[Ey]`
message text the app prints), `exitCode`, and `cleanup`. Prefer asserting
on the app's own documented diagnostic output over reaching into internal
`card` state, except for a few deliberate white-box checks (e.g. confirming
`card.curr`/`card.bnry` after a drain) where black-box output does not
carry enough detail.

When a new test reveals an actual driver/stack bug, do not fix it silently
in the same change that adds the harness coverage: report it so scope stays
separated (harness work vs. bug fixes).

## UNETRTL early-response regression (0.3.1)

The DLL suite runs `UNETTEST -r SLICE HOST PORT` through the real loader
and compares all 8233 HTTP bytes (8192-byte body), CRC32 `62763860`, first
8 bytes, EOF, and the absence of LOST. Its 16-case matrix combines blocking
and genuinely suspended SEND, separate/piggybacked ACK, 536/1460-byte
segments, and separate/payload-bearing FIN. The 1460-byte first flight
intentionally violates advertised MSS/window to test defensive reception.
The optional `reliableResponse` responder tracks cumulative ACK and receive
window, retransmitting an unacknowledged suffix instead of advancing on
every ACK. Ordinary socket servers cannot guarantee this packet geometry.

`exe-harness/unet-probe.js` assembles a small libman consumer for further
public-ABI vectors: 64-byte RECV, filled queue, overlapping retransmissions,
second channel, payload before ACK followed by AGAIN/resume, failed ACK in
SEND and RECV, FIN in SEND, and partial outgoing ACK followed by timeout.
Stale/future ACKs must not roll back progress or claim success. A second
placement runs the DLL relocated into WIN2 with its consumer in WIN1.
An ACK-bearing RST also verifies that SEND returns `NERR_CLOSED` with `DE`
equal to the cumulative progress acknowledged before closure.

Read-only CPU snapshots at assembled SEND/RECV/sink boundaries contain
receive sequence, send ACK, window, ACK wait state, accepted length, both
pending lengths and LOST. Public return records contain A/DE/IX, and wire
frames retain full sequence/ACK/window. To save these diagnostic records:

```sh
UNET_TRACE=/tmp/unet-rx.jsonl node tools/test-exe-dll.js
UNET_TEST_DLL=/path/to/old/UNETRTL.DLL node tools/test-exe-dll.js
```

Trace output appends one JSON line per low-level probe. The old 18084-byte
0.3.0 DLL fails the exact same 8 KiB test on an ACK carrying 1460 bytes;
0.3.1 passes. The socket helper has its own fragmented-request/EOF tests
in `tools/dev/test_unettest_response_server.py`, included in `make test-host`.
MAME/physical-card and original SNC/WebDAV acceptance remain separate.

## UNETRTL receive-window throughput regressions (0.3.2--0.3.7)

The DLL probe also drives both TCP channels through 12000-byte deterministic
streams using repeated blocking 2048-byte RECV calls. Its peer obeys receive
MSS 536, the cumulative ACK and advertised window exactly. The test checks the
complete byte stream, zero LOST reports, receive MSS 536 in each SYN, a full 2048-byte
result for every non-final call, and a same-ACK wire update from the durable
window at the end of one call to the larger active window at the start of the
next. A segment crossing the caller boundary is split between caller and
pending storage before ACK. Separate oversized-segment vectors exercise the
same rule. The 0.3.4
experiment advertised MSS 512/window 2560 to align a 2048-byte application
buffer, but was retired in 0.3.5: it increased per-segment CPU/DMA overhead and
tuned TCP framing to one consumer's buffer size. Version 0.3.6 tried Ethernet
receive MSS 1460 while retaining the 536-byte durable queue, but real MAME
throughput exposed a stop/start regression in the synchronous DLL window.
Version 0.3.7 restores DLL receive MSS 536; direct clients keep MSS 1460.

A fault-injected transmit failure on that opening window update must produce
NERR_HW with DE=0 and IX=0, preserve a RECV/LASTERR diagnostic, restore the
caller's receive scope, and leave ISA closed. Existing vectors continue to
cover foreign-channel capacity (0/536 only), pre-ACK payload and FIN, overlap
retransmission, failed final ACK, and relocation of the DLL into WIN1 or WIN2.
