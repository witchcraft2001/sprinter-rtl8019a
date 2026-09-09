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

console.log(`Actual DSS EXE harness: ${caseCount()} header, self-test, NICINFO/NICRAM/NICLB/NICTX/NICRX and ISAPROBE checks passed`);
