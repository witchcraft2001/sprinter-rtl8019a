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
    variant: 'RTL8019AS',   // or 'UM9003' (id0/id1 read as 0xFF)
    loopbackToRing: true,   // MAME: loopback frame lands in the RX ring + PRX.
                             // false: real-HW FIFO/RSR path (no PRX).
    isrRstOnStop: false,    // MAME: STP alone does not set ISR.RST.
                             // true: real HW sets it immediately.
    hangOnResetPort: false, // UM9003-style clone: reading BASE+0x1F throws
                             // (proves the driver honours NET_RTL_RESET=SOFT).
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
