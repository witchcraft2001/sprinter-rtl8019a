#!/usr/bin/env node
// Phase 1 actual-EXE integration vectors: NIC diagnostics (NICINFO, NICRAM,
// NICLB, NICTX, NICRX), ISAPROBE, and harness self-tests.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { runExe } = require('./exe-harness/harness.js');
const { count, caseCount, checkCleanup, checkCleanupClaimedPage } = require('./exe-harness/test-util.js');

const root = path.resolve(__dirname, '..');
const exe = (name) => path.join(root, 'build', `${name}.EXE`);
const run = (name, args, scenario = {}) => runExe(exe(name), args, scenario);

// ---------------------------------------------------------------------
// Preflight: every built EXE has a structurally valid DSS header.
// ---------------------------------------------------------------------
const builtExes = fs.readdirSync(path.join(root, 'build')).filter((f) => f.endsWith('.EXE'));
assert.ok(builtExes.length > 0, 'no build/*.EXE found -- run tools/build.sh first');
for (const name of builtExes) {
  const image = fs.readFileSync(path.join(root, 'build', name));
  assert.strictEqual(image.toString('ascii', 0, 3), 'EXE', name);
  assert.strictEqual(image[3], 1, `${name}: unexpected EXE_VERSION`);
  const headerSize = image.readUInt16LE(4);
  assert.ok(headerSize === 128 || headerSize === 256, `${name}: header size ${headerSize}`);
  const entry = image.readUInt16LE(16), entry2 = image.readUInt16LE(18);
  assert.strictEqual(entry, entry2, `${name}: entry/entry2 mismatch`);
  const loadAddress = entry - headerSize;
  assert.ok(loadAddress >= 0 && loadAddress + image.length <= 0x10000, `${name}: image out of range`);
  count();
}

// ---------------------------------------------------------------------
// HELLO: smallest possible end-to-end smoke test (no NIC touched).
// ---------------------------------------------------------------------
const hello = run('HELLO', '');
assert.strictEqual(hello.exitCode, 0);
assert.match(hello.output, /RTL8019AS DEV HELLO v/);
assert.match(hello.output, /RESULT OK/);
checkCleanup(hello);

// ---------------------------------------------------------------------
// Harness self-tests: prove the invariants actually fire.
// ---------------------------------------------------------------------
function buildRawExe(codeBytes) {
  const header = Buffer.alloc(128, 0);
  header.write('EXE', 0, 'ascii');
  header[3] = 1;
  header.writeUInt16LE(0x0080, 4); // header size
  header.writeUInt16LE(0x8100, 16); // entry
  header.writeUInt16LE(0x8100, 18); // entry2
  header.writeUInt16LE(0x8100, 20); // stack top
  const file = Buffer.concat([header, Buffer.from(codeBytes)]);
  const tmp = path.join(os.tmpdir(), `harness-selftest-${process.pid}-${Math.random().toString(36).slice(2)}.EXE`);
  fs.writeFileSync(tmp, file);
  return tmp;
}

// Corrupted header: wrong signature must be rejected before any execution.
{
  const bad = Buffer.alloc(160, 0);
  bad.write('XXX', 0, 'ascii');
  const tmp = path.join(os.tmpdir(), `harness-selftest-badhdr-${process.pid}.EXE`);
  fs.writeFileSync(tmp, bad);
  assert.throws(() => runExe(tmp, ''), /invalid DSS EXE header/);
  fs.unlinkSync(tmp);
  count();
}

// DSS call while the ISA window is still open must throw. Minimal program:
//   LD BC,0x1FFD / LD A,0x11 / OUT (C),A      ; PORT_SYSTEM: enter ISA mode
//   LD BC,0x00E2 / LD A,0xD6 / OUT (C),A      ; select ISA slot 1
//   LD BC,0x9FBD / XOR A     / OUT (C),A      ; PORT_ISA: map the window
//   RST 0x10                                  ; DSS call with window open
{
  const code = [
    0x01, 0xfd, 0x1f, 0x3e, 0x11, 0xed, 0x79,
    0x01, 0xe2, 0x00, 0x3e, 0xd6, 0xed, 0x79,
    0x01, 0xbd, 0x9f, 0xaf, 0xed, 0x79,
    0xd7,
  ];
  const tmp = buildRawExe(code);
  assert.throws(() => runExe(tmp, ''), /DSS call while ISA window is open/);
  fs.unlinkSync(tmp);
  count();
}

// Interrupts enabled while touching the chip aperture must throw, even
// without a DSS call: EI, then read chip base 0xC300 (CR register).
//   ...same ISA_OPEN sequence... / EI / LD HL,0xC300 / LD A,(HL)
{
  const code = [
    0x01, 0xfd, 0x1f, 0x3e, 0x11, 0xed, 0x79,
    0x01, 0xe2, 0x00, 0x3e, 0xd6, 0xed, 0x79,
    0x01, 0xbd, 0x9f, 0xaf, 0xed, 0x79,
    0xfb, // EI
    0x21, 0x00, 0xc3, // LD HL,0xC300
    0x7e, // LD A,(HL)
  ];
  const tmp = buildRawExe(code);
  assert.throws(() => runExe(tmp, ''), /interrupts enabled.*chip access/);
  fs.unlinkSync(tmp);
  count();
}

// DELAY_1MS executing with the ISA window open must throw. Sequence:
//   ...ISA_OPEN... / LD BC,400 / DEC BC / LD A,B / OR C / JR NZ,-5
{
  const code = [
    0x01, 0xfd, 0x1f, 0x3e, 0x11, 0xed, 0x79,
    0x01, 0xe2, 0x00, 0x3e, 0xd6, 0xed, 0x79,
    0x01, 0xbd, 0x9f, 0xaf, 0xed, 0x79,
    0x01, 0x90, 0x01, // LD BC,400
    0x0b, 0x78, 0xb1, 0x20, 0xfb, // DEC BC / LD A,B / OR C / JR NZ,-5
  ];
  const tmp = buildRawExe(code);
  assert.throws(() => runExe(tmp, ''), /DELAY_1MS executed with ISA window open/);
  fs.unlinkSync(tmp);
  count();
}

// ---------------------------------------------------------------------
// NICINFO
// ---------------------------------------------------------------------
{
  const r = run('NICINFO', '');
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[N0\] Slot\/Addr: 1\/#300/);
  assert.match(r.output, /\[N3\] RTL ID=Pp \(50 70\)/);
  assert.match(r.output, /PROM_LAYOUT=direct/);
  assert.match(r.output, /RESULT OK/);
  assert.doesNotMatch(r.output, /\[W/);
  checkCleanup(r);
}
{ // card lives on slot 0; INIT_BASE's auto-scan must find it there
  const r = run('NICINFO', '', { slot: 0 });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[N0\] Slot\/Addr: 0\/#300/);
  checkCleanup(r);
}
for (const base of [0x200, 0x320, 0x3e0]) {
  const r = run('NICINFO', '', { base });
  assert.strictEqual(r.exitCode, 0, `base ${base}`);
  assert.match(r.output, new RegExp(`\\[N0\\] Slot/Addr: 1/#${base.toString(16).toUpperCase()}`));
  checkCleanup(r);
}
{ // doubled PROM layout: same acceptance criteria as direct, no warning
  const r = run('NICINFO', '', { promLayout: 'doubled' });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /PROM_LAYOUT=doubled/);
  assert.match(r.output, /RESULT OK/);
  assert.doesNotMatch(r.output, /\[W/);
  checkCleanup(r);
}
{ // unrecognized PROM signature -> WARN, not FAIL
  const r = run('NICINFO', '', { promLayout: 'unknown' });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[W01\]/);
  assert.match(r.output, /RESULT OK/);
  checkCleanup(r);
}
// .SCAN_BASES additionally demands the Realtek ID before accepting a hit
// (a UM9003AF clone can never produce it), so a non-Realtek clone is only
// reachable via the explicit NET_RTL_HW pin -- matching the documented
// driver design (INIT_BASE's TRY_ENV_OVERRIDE comment).
{ // UM9003-style clone, pinned via env: ID mismatch but a plausible MAC -> WARN, not FAIL
  const r = run('NICINFO', '', { quirks: { variant: 'UM9003' }, environment: { NET_RTL_HW: '1/#300' } });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[E02\] RTL ID mismatch/);
  assert.match(r.output, /\[W02\]/);
  assert.match(r.output, /RESULT OK/);
  // Page 3 is a Realtek extension: on a clone it is not decoded, so no
  // MEDIA/POWER guesses and no medium/duplex/power warnings.
  assert.match(r.output, /\[N6\] P3 N\/A: no Realtek ID, CONFIG not decoded/);
  assert.doesNotMatch(r.output, /\[N7\]|\[N8\]|\[W0[345]\]/);
  checkCleanup(r);
}
{ // NICINFO is a non-publishing verifier: without NET_RTL_TYPE the selected
  // default disagrees with an NE1000 RAM probe and produces W06.
  const r = run('NICINFO', '', {
    quirks: { variant: 'NE1000' },
    environment: { NET_RTL_HW: '1/#300' },
  });
  assert.strictEqual(r.exitCode, 0, r.output);
  assert.match(r.output, /CARD_TYPE=NE2000/);
  assert.match(r.output, /TYPE_PROBE=NE1000/);
  assert.match(r.output, /\[W06\]/);
  assert.match(r.output, /PROM_LAYOUT=direct/);
  assert.strictEqual(r.environment.NET_RTL_TYPE, undefined);
  checkCleanup(r);
}
{ // An explicit matching type is still verified and remains warning-free.
  const r = run('NICINFO', '', {
    quirks: { variant: 'NE1000' },
    environment: { NET_RTL_HW: '1/#300', NET_RTL_TYPE: 'NE1000' },
  });
  assert.strictEqual(r.exitCode, 0, r.output);
  assert.match(r.output, /CARD_TYPE=NE1000/);
  assert.match(r.output, /TYPE_PROBE=NE1000/);
  assert.doesNotMatch(r.output, /\[W06\]/);
  assert.doesNotMatch(r.output, /\[E02\]|\[W02\]/);
  assert.strictEqual(r.environment.NET_RTL_TYPE, 'NE1000');
  checkCleanup(r);
}
{ // A stale explicit NE2000 setting is diagnosed rather than trusted.
  const r = run('NICINFO', '', {
    quirks: { variant: 'NE1000' },
    environment: { NET_RTL_HW: '1/#300', NET_RTL_TYPE: 'NE2000' },
  });
  assert.strictEqual(r.exitCode, 0, r.output);
  assert.match(r.output, /TYPE_PROBE=NE1000/);
  assert.match(r.output, /\[W06\]/);
  checkCleanup(r);
}
{ // a genuine RTL8019AS still gets the page-3 decode
  const r = run('NICINFO', '');
  assert.match(r.output, /\[N6\] P3 9346=/);
  assert.match(r.output, /\[N7\] MODE=/);
  assert.match(r.output, /\[N8\] POWER=/);
  checkCleanup(r);
}
{ // ID mismatch AND an implausible (all-zero) MAC -> FAIL
  const r = run('NICINFO', '', {
    quirks: { variant: 'UM9003' }, mac: [0, 0, 0, 0, 0, 0], environment: { NET_RTL_HW: '1/#300' },
  });
  assert.strictEqual(r.exitCode, 2);
  assert.match(r.output, /RESULT FAIL/);
  checkCleanup(r);
}
// ---------------------------------------------------------------------
// Board reset port (BASE+0x1F) vs non-Realtek clones.
//
// A UM9003AF stalls the ISA cycle on that port: the Z80 stops inside the
// bus cycle, so no software timeout can recover and the machine simply
// dies with nothing on screen.  The driver therefore refuses to touch
// BASE+0x1F unless the chip identifies itself as a genuine Realtek
// RTL8019AS (RTL_RESET_AUTO, the default).  hangOnResetPort models the
// stall as a throw, so "did not throw" IS the assertion here.
// ---------------------------------------------------------------------
const cloneHangs = {
  quirks: { variant: 'UM9003', hangOnResetPort: true },
  environment: { NET_RTL_HW: '1/#300' },
};
{ // the regression: a clone with no NET_RTL_RESET at all must not hang
  const r = run('NICINFO', '', cloneHangs);
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /RESULT OK/);
  checkCleanup(r);
}
{ // an explicit SOFT reaches the same place, and says so
  const r = run('NICINFO', '', {
    ...cloneHangs, environment: { ...cloneHangs.environment, NET_RTL_RESET: 'SOFT' },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[W02\] soft reset: port 1F skipped/);
  assert.match(r.output, /RESULT OK/);
  checkCleanup(r);
}
{ // AUTO must not degrade into "always soft": a genuine Realtek still
  // gets the board reset, which this card models as a stall so the
  // throw proves the hard path really ran.
  assert.throws(
    () => run('NICINFO', '', {
      quirks: { hangOnResetPort: true }, environment: { NET_RTL_HW: '1/#300' },
    }),
    /reset port BASE\+0x1F read/,
  );
  count();
}
{ // RTL_RESET=HARD is the escape hatch: force the pulse on a clone
  assert.throws(
    () => run('NICINFO', '', {
      ...cloneHangs, environment: { ...cloneHangs.environment, NET_RTL_RESET: 'HARD' },
    }),
    /reset port BASE\+0x1F read/,
  );
  count();
}
{ // no card at all on either slot/base
  const r = run('NICINFO', '', { cardPresent: false });
  assert.strictEqual(r.exitCode, 2);
  assert.match(r.output, /\[E04\] no RTL8019AS responded/);
  assert.match(r.output, /RESULT FAIL/);
  checkCleanup(r);
}
{ // NET_RTL_HW fast path: env pins the exact slot/base, no 16-base scan needed
  const withEnv = run('NICINFO', '', { environment: { NET_RTL_HW: '1/#300' } });
  const withoutEnv = run('NICINFO', '', {});
  assert.strictEqual(withEnv.exitCode, 0);
  assert.match(withEnv.output, /RESULT OK/);
  assert.ok(withEnv.steps < withoutEnv.steps,
    `expected the env fast path (${withEnv.steps} steps) to be cheaper than auto-scan (${withoutEnv.steps} steps)`);
  checkCleanup(withEnv);
}
{ // malformed env value: warn and fall back to auto-scan, which still finds the card
  const r = run('NICINFO', '', { environment: { NET_RTL_HW: 'garbage' } });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[W\] NET_RTL_HW=garbage not usable, auto-scanning/);
  assert.match(r.output, /RESULT OK/);
  checkCleanup(r);
}

// ---------------------------------------------------------------------
// NICRAM
// ---------------------------------------------------------------------
{
  const r = run('NICRAM', '');
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[R18\] READ  ADDR=5F00 LEN=0100 OK/);
  assert.match(r.output, /RESULT OK/);
  checkCleanup(r);
}
{ // corrupted remote-DMA readback byte must be caught as a RAM mismatch
  const r = run('NICRAM', '', { corruptDmaReadAt: 3 });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /\[E13\] RAM mismatch/);
  assert.match(r.output, /RESULT FAIL/);
  checkCleanup(r);
}
{
  const r = run('NICRAM', '', { cardPresent: false });
  assert.strictEqual(r.exitCode, 2);
  checkCleanup(r);
}

// ---------------------------------------------------------------------
// NICLB: both the MAME (loopback-to-ring) and real-hardware (FIFO) quirk
// branches must be exercised, since NICLB.EXE handles both explicitly.
// ---------------------------------------------------------------------
{
  const r = run('NICLB', '', { quirks: { loopbackToRing: true } });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[L5\] LOOP SRAM OK/);
  assert.match(r.output, /\[L6\] RX HDR STS=21 NEXT=48 LEN=0040/);
  assert.match(r.output, /\[L8\] CMP OK/);
  assert.match(r.output, /RESULT OK/);
  checkCleanup(r);
}
{
  const r = run('NICLB', '', { quirks: { loopbackToRing: false } });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[L5\] LOOP FIFO OK ISR=/);
  assert.match(r.output, /\[L6\] RX SRAM N\/A/);
  assert.match(r.output, /RESULT OK/);
  checkCleanup(r);
}
{ // receive status posted 20 ms after PTX: the wait must catch it
  const r = run('NICLB', '', { quirks: { loopbackToRing: false, loopbackStatusDelayMs: 20 } });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[L5\] LOOP FIFO OK ISR=04 RSR=01 TSR=01 FIFO=00 00 00 00 00 00 00 00\r?\n NIC fae=00 crc=00 mpc=00/);
  assert.match(r.output, /RESULT OK/);
  checkCleanup(r);
}
{ // UM9003F: PTX, then neither PRX nor RXE, only ISR.CNT.  The failure
  // must show what the chip did report, not just the register dump.
  const r = run('NICLB', '', { quirks: { loopbackToRing: false, loopbackSilent: true } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /\[E23\] loopback produced neither PRX nor RXE in 50 ms\r?\n ISR=20 RSR=00 TSR=01 FIFO=00 00 00 00 00 00 00 00\r?\n NIC fae=00 crc=00 mpc=00\r?\nREGS /);
  assert.match(r.output, /RESULT FAIL/);
  checkCleanup(r);
}
{
  const r = run('NICLB', '', { cardPresent: false });
  assert.strictEqual(r.exitCode, 2);
  checkCleanup(r);
}

// ---------------------------------------------------------------------
// NICTX
// ---------------------------------------------------------------------
{
  const r = run('NICTX', '');
  assert.strictEqual(r.exitCode, 0);
  assert.strictEqual(r.transmittedFrames.length, 1);
  const frame = Buffer.from(r.transmittedFrames[0], 'hex');
  assert.strictEqual(frame.length, 60);
  assert.strictEqual(frame.subarray(0, 6).toString('hex'), 'ffffffffffff'); // broadcast dest
  assert.strictEqual(frame.subarray(6, 12).toString('hex'), '028019112233'); // SRC_MAC
  assert.strictEqual(frame.readUInt16BE(12), 0x88b5); // EtherType
  assert.match(r.output, /RESULT OK/);
  checkCleanup(r);
}
{
  const r = run('NICTX', '', { txError: true });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /\[E31\]/);
  assert.match(r.output, /RESULT FAIL/);
  checkCleanup(r);
}
{
  const r = run('NICTX', '', { cardPresent: false });
  assert.strictEqual(r.exitCode, 2);
  checkCleanup(r);
}

// ---------------------------------------------------------------------
// NICRX: RCR=0 means physical-match only, so broadcast must be rejected.
// ---------------------------------------------------------------------
const nicrxOurMac = [0x02, 0x80, 0x19, 0x11, 0x22, 0x33];
function unicastFrame(payload = 'PAYLOAD') {
  const bytes = [...nicrxOurMac, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x88, 0xb5,
    ...Buffer.from(payload, 'ascii')];
  while (bytes.length < 60) bytes.push(0);
  return bytes;
}
{
  const frame = unicastFrame('HELLO-NICRX');
  const r = run('NICRX', '', { rxFrames: [{ bytes: frame, afterMs: 3 }] });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[X2\] RX LEN=003C SRC=02:00:00:00:00:01 TYPE=88B5/);
  assert.match(r.output, /RESULT OK/);
  checkCleanup(r);
}
{ // broadcast frame must be silently dropped (RCR=0, no AB bit) -> timeout
  const broadcast = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 2, 0, 0, 0, 0, 1, 0x88, 0xb5];
  while (broadcast.length < 60) broadcast.push(0);
  const r = run('NICRX', '', { rxFrames: [{ bytes: broadcast, afterMs: 3 }] });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /\[E41\] PRX timeout/);
  checkCleanup(r);
}
{
  const r = run('NICRX', '');
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /\[E41\] PRX timeout/);
  checkCleanup(r);
}
{
  const r = run('NICRX', '', { cardPresent: false });
  assert.strictEqual(r.exitCode, 2);
  checkCleanup(r);
}

// ---------------------------------------------------------------------
// ISAPROBE: large-header EXE + CLAIM_RUNTIME_PAGE + cmdline_lib smoke.
// ---------------------------------------------------------------------
{
  const r = run('ISAPROBE', '');
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Slot 0 activity map/);
  assert.match(r.output, /Slot 1 activity map/);
  assert.match(r.output, /RESULT OK/);
  checkCleanupClaimedPage(r);
}
{ // the card's true base (0x300) must show live on slot 1's map, not slot 0's
  const r = run('ISAPROBE', '');
  assert.strictEqual(r.exitCode, 0);
  const lines = r.output.split(/\r\n/).filter((l) => l.startsWith('0000:'));
  assert.strictEqual(lines.length, 2, 'expected one activity-map line per slot');
  assert.ok(!lines[0].includes('X'), `slot 0 map should be all quiet: ${lines[0]}`);
  assert.ok(lines[1].includes('X'), `slot 1 map should show the card live: ${lines[1]}`);
  checkCleanupClaimedPage(r);
}
{
  const r = run('ISAPROBE', '-n 300');
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[N3\] CR page select OK/);
  checkCleanupClaimedPage(r);
}
{
  const r = run('ISAPROBE', '-d 300 10');
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /0300:/);
  checkCleanupClaimedPage(r);
}
{
  const r = run('ISAPROBE', '', { cardPresent: false });
  assert.strictEqual(r.exitCode, 0); // ISAPROBE's default map mode never fails
  checkCleanupClaimedPage(r);
}

// ---------------------------------------------------------------------
// NICREG: register read-stability diagnostic.  Its whole point is to tell
// an UNDRIVEN bit (returns whatever the previous bus cycle left behind --
// harmless, and normal for a clone's reserved bits) from a DRIVEN bit that
// is misread (a genuine marginal-bus fault).  Every target read is preceded
// by a read of a conditioner register preset to 00 and then to FF.
// ---------------------------------------------------------------------
const G4_CLEAN = '0000   00   0000    0000   0000   0000   0000    0000     0000';
{ // healthy card: every pair equal, nothing transmitted without -t
  const r = run('NICREG', '');
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[G0\] Slot\/Addr: 1\/#300 chip=Realtek/);
  assert.match(r.output, /bad after-00=0000 after-FF=0000 cond=0000 load=00/);
  assert.match(r.output, /\[G2\] PAGE2 CONFIG .* bad=0000/);
  assert.match(r.output, /RCR   04\|04\/04\|04\/04 TCR   02\|02\/02\|02\/02/);
  assert.match(r.output, /CR    21\/21\|21\/21/);
  assert.match(r.output, /\[G4\] PAR=028019112233  per row: 288000 reads, 192000 writes/);
  assert.match(r.output, / row  rd-bad bits wr-lost wr-bad unsure cr-bad rxpages badticks withrx/);
  for (const row of ['stop', 'deaf', 'live']) assert.match(r.output, new RegExp(` ${row} ${G4_CLEAN}`));
  assert.doesNotMatch(r.output, /^  (rd|wr|page) /m);
  assert.match(r.output, /RESULT OK/);
  assert.strictEqual(r.transmittedFrames.length, 0, 'NICREG must not transmit unless asked');
  // The diagnostic leaves the controller stopped, as it found it.
  assert.strictEqual(r.card.cr & 0x3f, 0x21);
  checkCleanup(r);
}
{ // UM9003F-style read-back: reserved bits follow the bus.  That is NOT an
  // unstable read and must not fail the run: the value after a 00 conditioner
  // and the value after an FF conditioner differ, but each pair is equal.
  const r = run('NICREG', '', {
    quirks: { variant: 'UM9003', hangOnResetPort: true, floatingBits: true },
    environment: { NET_RTL_HW: '1/#300' },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /chip=clone/);
  assert.match(r.output, /RCR   04\|04\/04\|C4\/C4 TCR   02\|02\/02\|E2\/E2/);
  assert.match(r.output, /DCR   48\|48\/48\|C8\/C8 IMR   00\|00\/00\|80\/80/);
  assert.match(r.output, /ID0   00\/00\|FF\/FF ID1   00\/00\|FF\/FF/);
  assert.match(r.output, /bad after-00=0000 after-FF=0000 cond=0000/);
  assert.match(r.output, /RESULT OK/);
  // A clone has no page 3, and its reset port may hang the machine.
  assert.strictEqual(r.card.stats.page3Reads, 0);
  checkCleanup(r);
}
{ // genuine fault: a DRIVEN bit of a read/write register comes back wrong
  // now and then.  Counted, attributed to its bit, and fatal.
  const r = run('NICREG', '', { quirks: { regReadGlitch: { page: 1, everyN: 997, xor: 0x80 } } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /bad after-00=000E after-FF=000E/);
  assert.match(r.output, /PAR0  bad=0001 bits=80/);
  // A fault that does not care about the chip's state shows in ALL [G4]
  // rows, the stopped control included, and in ticks where the ring never
  // moved; the misreads are kept verbatim.  No write is blamed for it and
  // nothing is left undecided: the re-read returns the wanted value.  A
  // glitch that lands in a page-switch confirmation counts as cr-bad.
  for (const row of ['stop', 'deaf', 'live']) {
    const m = r.output.match(new RegExp(` ${row} ([0-9A-F]{4})   80   0000    0000   0000   ([0-9A-F]{4})   0000    ([0-9A-F]{4})     0000`));
    assert.ok(m, `${row} row`);
    assert.strictEqual(parseInt(m[1], 16) + parseInt(m[2], 16), parseInt(m[3], 16), 'one glitch, one bad window');
    assert.ok(parseInt(m[1], 16) > 0x1c0);
  }
  // Six samples, one register apart, two sweeps apart: the glitch strides
  // through PAR0..5 at a fixed period.  The absolute sweep number depends on
  // how many accesses the setup spent before the loop, which is not the
  // point being tested here.
  {
    const m = r.output.match(/ {2}rd PAR0=82@([0-9A-F]{2}) PAR1=00@([0-9A-F]{2}) PAR2=99@/);
    assert.ok(m, 'rd sample line');
    assert.strictEqual((parseInt(m[1], 16) + 2) & 0x1f, parseInt(m[2], 16));
  }
  assert.doesNotMatch(r.output, /^  (wr|page) /m);
  // 0.3.18 loaded the sample counter into B and THEN printed the "  rd"
  // label; real DSS console calls trash B, and hardware printed 256 samples
  // of stray memory.  The model trashes B the same way: the line must stop
  // at the six samples that were kept.
  const rdLines = r.output.split(/\r?\n/).filter((l) => l.startsWith('  rd'));
  assert.strictEqual(rdLines.length, 3);
  for (const l of rdLines) assert.match(l, /^  rd( PAR[0-5]=[0-9A-F]{2}@[01][0-9A-F]){6}$/);
  assert.match(r.output, /RESULT FAIL/);
  checkCleanup(r);
}
{ // register reads that collide with the chip's receive-buffer DMA (a host
  // that does not honour IOCHRDY): clean while the receiver is deaf, bad only
  // while frames are stored, and every bad tick is a tick the ring moved in.
  const bc = (n) => ({
    afterMs: 100 + n * 100,
    bytes: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 2, 0, 0, 0, 0, 9, 0x08, 0x06, ...new Array(46).fill(n)],
  });
  const r = run('NICREG', '', {
    // one frame per 100 ms across all three rows (3 x 1500 ticks of 1 ms)
    rxFrames: Array.from({ length: 45 }, (_, i) => bc(i)),
    quirks: { rxDmaGlitch: { afterReads: 14, xor: 0xff } },
  });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /bad after-00=0000 after-FF=0000 cond=0000/);
  assert.match(r.output, new RegExp(` stop ${G4_CLEAN}`));
  assert.match(r.output, new RegExp(` deaf ${G4_CLEAN}`));
  const live = r.output.match(/ live ([0-9A-F]{4})   FF   0000    0000   0000   0000   ([0-9A-F]{4})    ([0-9A-F]{4})     ([0-9A-F]{4})/);
  assert.ok(live, 'live row with misreads expected');
  assert.ok(parseInt(live[1], 16) > 0);
  assert.strictEqual(live[2], live[1], 'one stored frame, one page, one misread');
  assert.strictEqual(live[3], live[1]);
  assert.strictEqual(live[4], live[1], 'every bad tick must be tied to reception');
  // 14th register read after the frame: the page-identity read of SET_PAGE,
  // 6 PAR + 4 MAR read-backs, then PAR2 of the second sweep (0x19 ^ 0xFF)
  assert.match(r.output, /  rd PAR2=E6@01 /);
  assert.ok(r.card.stats.filteredRx > 0, 'the deaf row must have had traffic to ignore');
  checkCleanup(r);
}
{ // Writes a started chip never latches (seen on real hardware).  MAR0..3
  // keep the previous sweep's pattern: counted as LOST, not as misreads, and
  // only in the rows where the chip runs.
  const r = run('NICREG', '', { quirks: { regWriteDrop: { target: 'reg', everyN: 10007, runningOnly: true } } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, new RegExp(` stop ${G4_CLEAN}`));
  assert.match(r.output, / deaf 0000   00   0013    0000   0000   0000   0000    0013     0000/);
  assert.match(r.output, / live 0000   00   0013    0000   0000   0000   0000    0013     0000/);
  assert.match(r.output, /  wr MAR2=87>78 MAR3=C9>36 MAR0=E1>1E MAR1=2D>D2/);
  // same counter-across-a-DSS-print trap as the "  rd" line: four, not 256
  const wrLines = r.output.split(/\r?\n/).filter((l) => l.startsWith('  wr'));
  assert.strictEqual(wrLines.length, 2);
  for (const l of wrLines) assert.match(l, /^  wr( MAR[0-3]=[0-9A-F]{2}>[0-9A-F]{2}){4}$/);
  assert.match(r.output, /RESULT FAIL/);
  checkCleanup(r);
}
{ // The dangerous one: a dropped page switch.  Unverified, the ring drain's
  // BNRY/ISR writes would land in PAR2/CURR (this is what real hardware
  // showed).  SET_PAGE must notice, repeat the write and count it -- and the
  // station address must survive.
  const r = run('NICREG', '', { quirks: { regWriteDrop: { target: 'cr', everyN: 1201, runningOnly: true } } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, new RegExp(` stop ${G4_CLEAN}`));
  assert.match(r.output, / deaf 0000   00   0000    0000   0000   0003   0000    0003     0000/);
  assert.match(r.output, / live 0000   00   0000    0000   0000   0004   0000    0004     0000/);
  assert.doesNotMatch(r.output, /^  page /m);
  assert.ok(r.card.stats.droppedWrites >= 6);
  assert.strictEqual(r.card.par, '028019112233', 'PAR must not be hit by a stray BNRY write');
  assert.strictEqual(r.card.curr, 0x47, 'CURR must not be hit by a stray ISR write');
  assert.match(r.output, /RESULT FAIL/);
  checkCleanup(r);
}
// --- the test must not manufacture its own evidence (code review, 0.3.24) ---
{ // FOUR page switches lost in a row defeat the retry loop.  0.3.23 carried on
  // regardless: its sweep ran on page 0, the drain wrote BNRY into PAR2, and
  // the row reported C0 misreads and 80 garbled writes that never happened.
  // Now the window is abandoned, the row is set up again and says so.
  const r = run('NICREG', '', { quirks: { regWriteDrop: { target: 'cr', everyN: 1201, burst: 4, limit: 4, runningOnly: true } } });
  assert.strictEqual(r.exitCode, 3);
  assert.strictEqual(r.card.stats.droppedWrites, 4);
  assert.match(r.output, / deaf 0000   00   0000    0000   0000   0001   0000    0001     0000\r?\n  page lost=0001 setup retries=0000/);
  assert.match(r.output, new RegExp(` live ${G4_CLEAN}`));
  assert.doesNotMatch(r.output, /^  (rd|wr) /m);
  assert.strictEqual(r.card.par, '028019112233');
  assert.strictEqual(r.card.curr, 0x47);
  checkCleanup(r);
}
{ // The chip sits out bursts of 16 cycles, reads and writes alike, often
  // enough to hit page switches: whatever else is reported, no register may
  // be written on an unconfirmed page.
  const r = run('NICREG', '', { quirks: { busMiss: { everyN: 3220, burst: 16, kind: 'both', runningOnly: true } } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /  page lost=0004 setup retries=0000/);
  assert.strictEqual(r.card.par, '028019112233');
  assert.strictEqual(r.card.curr, 0x47);
  checkCleanup(r);
}
{ // READS the chip does not answer, three cycles in a row; every write is
  // fine.  The unanswered read returns what the previous cycle left on the
  // bus.  0.3.23 took two such re-reads for proof and reported 17 lost and 16
  // garbled writes here (its MAR1/MAR3 patterns were the complements of
  // MAR0/MAR2, so the leftover even looked like "the previous pattern").
  // No write may be blamed now.
  const r = run('NICREG', '', { quirks: { busMiss: { everyN: 5003, burst: 3, kind: 'read', runningOnly: true } } });
  assert.strictEqual(r.exitCode, 3);
  assert.ok(r.card.stats.missedCycles > 600);
  assert.match(r.output, new RegExp(` stop ${G4_CLEAN}`));
  for (const row of ['deaf', 'live']) {
    assert.match(r.output, new RegExp(` ${row} 00[0-9A-F]{2}   [0-9A-F]{2}   0000    0000   [0-9A-F]{4}   [0-9A-F]{4}   0000 `));
  }
  assert.doesNotMatch(r.output, /^  wr /m);
  checkCleanup(r);
}
{ // One bit flipped in the single write that loads PAR2 for the stop row.
  // Every later read returns the register's true content; 0.3.23 compared it
  // with the pattern and reported BB80 "misreads".  The setup is read back
  // now and repeated.
  const r = run('NICREG', '', { quirks: { regWriteFlip: { page: 1, offset: 3, nth: 5, xor: 0x01 } } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, / stop 0000   00   0000    0000   0000   0001   0000    0000     0000\r?\n  page lost=0000 setup retries=0001/);
  assert.match(r.output, new RegExp(` deaf ${G4_CLEAN}`));
  assert.doesNotMatch(r.output, /^  (rd|wr) /m);
  checkCleanup(r);
}
{ // the same flip in a [G1] pattern load: 512 identical wrong reads are a
  // failed load, not 512 misreads
  const r = run('NICREG', '', { quirks: { regWriteFlip: { page: 1, offset: 3, nth: 1, xor: 0x01 } } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /bad after-00=0000 after-FF=0000 cond=0000 load=01/);
  assert.match(r.output, /PAR2  bad=0200 bits=01/);
  checkCleanup(r);
}
{ // PAR2 changes behind the host's back in the middle of the deaf row.  One
  // event, one count: the content is proven wrong (the conditioner reads
  // right), reported as wanted>held, and written back.
  const r = run('NICREG', '', { quirks: { regPoke: { afterAccesses: 900000, index: 2, value: 0x46 } } });
  assert.strictEqual(r.exitCode, 3);
  // The sweep the poke lands in depends on how many accesses the row spent
  // setting itself up, which is not what this case is about.
  assert.match(r.output, / deaf 0000   00   0000    0001   0000   0000   0000    0001     0000\r?\n  rd PAR2=46@[0-9A-F]{2}\r?\n  wr PAR2=19>46/);
  assert.match(r.output, new RegExp(` live ${G4_CLEAN}`));
  assert.strictEqual(r.card.par, '028019112233', 'the damage must be repaired');
  checkCleanup(r);
}
{ // [G6]: one corrupted READ of the remote-DMA data port.  Packet RAM is
  // untouched, so the second pass finds the byte intact -- the read lied.
  const r = run('NICREG', '', { quirks: { dmaReadGlitch: { nth: 500, xor: 0x01 } } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, / deaf 0001   0001   0000    0000   0001   0000   0000/);
  assert.match(r.output, /^ {2}dma [0-9A-F]{2}=([0-9A-F]{2})>([0-9A-F]{2}) $/m);
  const [, want, got] = r.output.match(/^ {2}dma [0-9A-F]{2}=([0-9A-F]{2})>([0-9A-F]{2}) $/m);
  assert.strictEqual(parseInt(want, 16) ^ parseInt(got, 16), 0x01);
  assert.match(r.output, / live 0000   0000   0000    0000   0000   0000/);
  checkCleanup(r);
}
{ // [G6]: one WRITE that never reached packet RAM.  Both read passes find the
  // same byte wrong, so the content is blamed and not the reads.
  const r = run('NICREG', '', { quirks: { dmaWriteDrop: { nth: 700 } } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, / deaf 0001   0000   0001    0000   0001   0000   0000/);
  assert.match(r.output, / live 0000   0000   0000    0000   0000   0000/);
  checkCleanup(r);
}
{ // [G6]: the whole run is clean on a healthy chip, and the phase must not
  // touch the receive ring it shares the chip with.
  const r = run('NICREG', '');
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[G6\] DMA DATA PORT, per row: 800 bursts x 128 bytes/);
  assert.match(r.output, / deaf 0000   0000   0000    0000   0000   0000   0000/);
  assert.doesNotMatch(r.output, /^ {2}dma /m);
  checkCleanup(r);
}
{ // a misread page-2 DEFINED bit fails too (reserved ones never do)
  const r = run('NICREG', '', { quirks: { regReadGlitch: { page: 2, everyN: 501, xor: 0x04 } } });
  assert.strictEqual(r.exitCode, 3);
  assert.doesNotMatch(r.output, /\[G2\] PAGE2 CONFIG .* bad=0000/);
  assert.match(r.output, /RESULT FAIL/);
  checkCleanup(r);
}
{ // -t: 3 x 20 tagged frames, in order, while live broadcast traffic is
  // drained so the ring cannot overflow under the test.
  // The stop and deaf rows of [G4] take the first 3000 ms; aim the traffic at
  // the live row and at the transmit phase after it.
  const bc = (n) => ({
    afterMs: 3100 + n * 40,
    bytes: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 2, 0, 0, 0, 0, 9, 0x08, 0x06, ...new Array(46).fill(n)],
  });
  const r = run('NICREG', '-t', { rxFrames: Array.from({ length: 60 }, (_, i) => bc(i)) });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, / A poll  ptx=20 /);
  assert.match(r.output, / B quiet ptx=20 /);
  assert.match(r.output, / C drv   ptx=20/);
  assert.match(r.output, / live 0000   00   0000    0000   0000   0000   (?!0000)[0-9A-F]{4}    0000     0000/);
  assert.strictEqual(r.transmittedFrames.length, 60);
  const marks = r.transmittedFrames.map((h) => {
    const f = Buffer.from(h, 'hex');
    assert.strictEqual(f.length, 60);
    assert.strictEqual(f.readUInt16BE(12), 0x88b5);
    assert.strictEqual(f.subarray(14, 24).toString('latin1'), 'NICREG TX ');
    return String.fromCharCode(f[24]) + f[25];
  });
  const expected = ['A', 'B', 'C'].flatMap((m) => Array.from({ length: 20 }, (_, i) => m + (i + 1)));
  assert.deepStrictEqual(marks, expected);
  assert.strictEqual(r.card.stats.overflowEvents, 0);
  checkCleanup(r);
}
{ // a transmitter that does not complete is a failure of the -t phase
  const r = run('NICREG', '-t', { txError: true });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, / A poll  ptx=00 /);
  assert.match(r.output, /RESULT FAIL/);
  checkCleanup(r);
}
{ // help and "no card" paths
  const h = run('NICREG', '/?');
  assert.strictEqual(h.exitCode, 0);
  assert.match(h.output, /NICREG -t/);
  checkCleanup(h);
  const n = run('NICREG', '', { cardPresent: false });
  assert.strictEqual(n.exitCode, 2);
  checkCleanup(n);
}

// ---------------------------------------------------------------------
// NE1000 runtime layout with the direct remote-DMA write sequence used by
// the Crynwr NE1000/NE2000 packet drivers and stock MAME.
// ---------------------------------------------------------------------
for (const app of ['NICRAM', 'NICLB', 'NICTX', 'NICREG']) {
  const r = run(app, '', {
    environment: { NET_RTL_HW: '1/#300', NET_RTL_TYPE: 'NE1000' },
    quirks: {
      variant: 'NE1000', chipPreStarted: true,
    },
  });
  assert.strictEqual(r.exitCode, 0, `${app}: ${r.output}`);
  assert.match(r.output, /RESULT OK/);
  if (app === 'NICRAM') assert.match(r.output, /ADDR=3F00 LEN=0100 OK/);
  checkCleanup(r);
  count();
}

console.log(`Actual DSS EXE harness: ${caseCount()} header, self-test, NICINFO/NICRAM/NICLB/NICTX/NICRX, ISAPROBE and NICREG checks passed`);
