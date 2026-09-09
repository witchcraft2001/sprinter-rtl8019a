#!/usr/bin/env node
// Phase 4 actual-EXE integration vectors: UNETTEST.EXE, the libman 1.3
// consumer that drives UNETRTL.DLL's public UNET ABI directly.
//
// The full DLL flow runs end to end under the harness: NETINIT (including
// the WIN0COLD cold-overlay load from the DLL's own trailing blob), GETCAPS,
// STATUS, RESOLVE (literal IP), PING (ICMP through the cold overlay),
// CONNECT/SEND/RECV/CLOSE over the scripted TCP peer, UDPOPEN/SEND/RECV
// echo, LISTEN/UNLISTEN arming and bounded accept timeouts, and the
// ASYNCSEND SETOPT+CONNECT+SEND path.  Two paths still need a real network
// peer and are covered by docs/UNETRTL_TESTING_RU.md scenarios D/E instead:
// an actual inbound accept (the harness TCP responder never initiates a
// connection toward the DSS side) and a forced NERR_AGAIN resume (the
// responder ACKs instantly, so SEND always settles with 0 resumes here).
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { runExe } = require('./exe-harness/harness.js');
const { count, caseCount } = require('./exe-harness/test-util.js');

const root = path.resolve(__dirname, '..');
const exe = (name) => path.join(root, 'build', `${name}.EXE`);
const run = (name, args, scenario = {}) => runExe(exe(name), args, scenario);

// ---------------------------------------------------------------------
// UNETTEST.EXE: paths that don't require a successful NETINIT.
// ---------------------------------------------------------------------
{
  const r = run('UNETTEST', '-x', {});
  assert.strictEqual(r.exitCode, 1);
  assert.match(r.output, /UNETTEST - universal network DLL smoke test/);
  assert.match(r.output, /Usage: UNETTEST/);
  count();
}
{ // no DLL file anywhere -> exit 2, with the exe-homedir-then-cwd retry
  // sequence from RESOLVE_DLL_PATH/libman's LR_OPEN fallback both visible
  const r = run('UNETTEST', '', { appDir: 'C:\\NET' });
  assert.strictEqual(r.exitCode, 2);
  assert.match(r.output, /Loading C:\\NET\\UNETRTL\.DLL/);
  assert.match(r.output, /Loading UNETRTL\.DLL/);
  assert.match(r.output, /Cannot load DLL:/);
  assert.match(r.output, /DLL file not found/);
  count();
}
{ // -d picks an explicit DLL path/name, bypassing exe-homedir resolution
  const r = run('UNETTEST', '-d MISSING.DLL', { appDir: 'C:\\NET' });
  assert.strictEqual(r.exitCode, 2);
  assert.match(r.output, /Loading MISSING\.DLL/);
  count();
}

// ---------------------------------------------------------------------
// Full ABI flows through the real UNETRTL.DLL.
// ---------------------------------------------------------------------
const dllBytes = fs.readFileSync(exe('UNETRTL').replace(/\.EXE$/, '.DLL'));
const arpToServer = { '192.168.7.1': 'aa:bb:cc:dd:ee:01' };
const dllScenario = (extra = {}) => ({
  environment: {
    NET_IP: '192.168.7.2', NET_MASK: '255.255.255.0', NET_GW: '192.168.7.1',
    NET_MAC: '02:80:19:11:22:33', NET_RTL_HW: '1/#300', NET: 'RTL',
  },
  appDir: 'C:\\NET',
  files: { 'C:\\NET\\UNETRTL.DLL': dllBytes },
  ...extra,
});

{ // default flow: NETINIT, literal-IP RESOLVE, CONNECT, HEAD, reply, close
  const r = run('UNETTEST', '192.168.7.1 80', dllScenario({
    responders: { arp: arpToServer, tcp: { body: 'hi', status: 200 } },
  }));
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /caps=0x023F/);
  assert.match(r.output, /NETINIT ok/);
  assert.match(r.output, /resolve: 192\.168\.7\.1/);
  assert.match(r.output, /connect 192\.168\.7\.1:80/);
  assert.match(r.output, /request sent/);
  assert.match(r.output, /HTTP\/1\.1 200 OK/);
  assert.match(r.output, /--- closed ---/);
  assert.ok(r.cleanup.isaClosed && r.cleanup.filesClosed);
  count();
}
{ // -u UDP echo: PING through the cold overlay, then a byte-exact
  // UDPOPEN/SEND/RECV round-trip of the 21-byte default payload.
  // (Regression guard for the PUT_DEC_HL DE-clobber that used to send
  // 21 bytes read from address 0x0000 -- see unettest.asm's SEND path.)
  const r = run('UNETTEST', '-u 7777 192.168.7.1', dllScenario({
    responders: { arp: arpToServer, icmp: {}, udp: { port: 7777 } },
  }));
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /ping: \d+ ms/);
  assert.match(r.output, /udp payload: 21 bytes \(default\)/);
  assert.match(r.output, /udp reply: len=21 data=SPRINTER UNETTEST UDP/);
  assert.match(r.output, /udp echo ok/);
  count();
}
{ // -u with a sized pattern payload at the standard-MTU boundary
  const r = run('UNETTEST', '-u 7777 1472 192.168.7.1', dllScenario({
    responders: { arp: arpToServer, udp: { port: 7777 } },
  }));
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /udp payload: 1472 bytes/);
  assert.match(r.output, /udp echo ok/);
  count();
}
{ // -u one byte past UDPLIB_MAX_PAYLOAD: the backend rejects it locally
  // with NERR_PARAM (09) BEFORE opening the ISA window, so nothing may
  // reach the wire.  Belongs here rather than in a real-hardware run:
  // the check never touches the chip, so a live card proves nothing the
  // harness cannot, and here the "no frame transmitted" half is an
  // assertion instead of an eyeballed silent terminal.
  const r = run('UNETTEST', '-u 7777 1473 192.168.7.1', dllScenario({
    responders: { arp: arpToServer, udp: { port: 7777 } },
  }));
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /udp payload: 1473 bytes/);
  assert.match(r.output, /Send failed\./);
  assert.match(r.output, /st=SEND nerr=09/);
  // Only ARP resolution may have gone out; no UDP datagram.
  const udpFrames = r.transmittedFrames.filter((f) => {
    const b = typeof f === 'string' ? Buffer.from(f, 'hex') : Buffer.from(f);
    return b.length > 23 && b[12] === 0x08 && b[13] === 0x00 && b[23] === 17;
  });
  assert.strictEqual(udpFrames.length, 0,
    'an over-length UDP payload must be rejected before anything is transmitted');
  count();
}
{ // -l arms LISTEN, times out on both bounded accept waits (the harness
  // peer never dials in -- docs/UNETRTL_TESTING_RU.md scenario D covers
  // a real inbound accept), then UNLISTENs cleanly.
  const r = run('UNETTEST', '-l 9000 192.168.7.1', dllScenario({
    responders: { arp: arpToServer },
  }));
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /listen on port 9000/);
  assert.match(r.output, /waiting for peer #1/);
  assert.match(r.output, /waiting for peer #2/);
  assert.match(r.output, /no peer connected in time/);
  assert.match(r.output, /unlisten done/);
  count();
}
{ // -a: SETOPT SENDSLICE + CONNECT + 1200-byte SEND. The scripted peer
  // ACKs instantly, so the transfer settles with zero NERR_AGAIN resumes;
  // a forced resume needs a stalling peer (scenario E).
  const r = run('UNETTEST', '-a 192.168.7.1 8080', dllScenario({
    responders: { arp: arpToServer, tcp: {} },
  }));
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /connect 192\.168\.7\.1:8080/);
  assert.match(r.output, /request sent/);
  assert.match(r.output, /resumes needed: 0/);
  count();
}
{ // -a against a refusing peer: CONNECT fails, LASTERR prints, exit 3
  const r = run('UNETTEST', '-a 192.168.7.1 8080', dllScenario({
    responders: { arp: arpToServer, tcp: { mode: 'refuse' } },
  }));
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /Connect failed\./);
  count();
}

// ---------------------------------------------------------------------
// Board reset port on a non-Realtek clone.
//
// UNETRTL.DLL has no image budget for the chip-ID probe that resolves
// RTL_RESET_AUTO in the .EXE builds, so it defaults to SOFT instead: the
// same safe direction, reached by a different route.  This is the DLL half
// of the regression that hung a real Sprinter -- F_NETINIT calls RTL.RESET
// straight after INIT_BASE, so a clone that stalls BASE+0x1F used to take
// the whole machine down before the first ABI call returned.
// ---------------------------------------------------------------------
const clone = { quirks: { variant: 'UM9003', hangOnResetPort: true } };
{ // no NET_RTL_RESET published at all -> must still come up
  const r = run('UNETTEST', '192.168.7.1 80', dllScenario({
    ...clone, responders: { arp: arpToServer, tcp: { body: 'hi', status: 200 } },
  }));
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /NETINIT ok/);
  assert.match(r.output, /HTTP\/1\.1 200 OK/);
  count();
}
{ // NETCFG's published SOFT reaches the DLL the same way
  const base = dllScenario({
    ...clone, responders: { arp: arpToServer, tcp: { body: 'hi', status: 200 } },
  });
  const r = run('UNETTEST', '192.168.7.1 80', {
    ...base, environment: { ...base.environment, NET_RTL_RESET: 'SOFT' },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /NETINIT ok/);
  count();
}
{ // ...and an explicit HARD still forces the pulse, proving the DLL reads
  // the variable rather than ignoring the port unconditionally
  const base = dllScenario({
    ...clone, responders: { arp: arpToServer, tcp: { body: 'hi', status: 200 } },
  });
  assert.throws(
    () => run('UNETTEST', '192.168.7.1 80', {
      ...base, environment: { ...base.environment, NET_RTL_RESET: 'HARD' },
    }),
    /reset port BASE\+0x1F read/,
  );
  count();
}

// ---------------------------------------------------------------------
// Consumer stack in WIN0 vs the cold overlay.
//
// WIN0COLD.RUN remaps PAGE0 to the cold page for every RESOLVE/PING
// cold call.  A consumer whose SP lives in 0x0000..0x3FFF then has the
// memory under its stack swapped out mid-call: before the fix, RUN's
// own PUSH/POP brackets straddled the remap (BC and AF came back as
// whatever bytes sat at the same address in the other page), and the
// cold code's pushes landed in the consumer's page 0.  RUN now runs
// cold calls on the top of the cold page itself and bridges the remap
// on an in-image mini-stack, so any consumer SP is safe.
//
// UNETTEST itself keeps its stack in WIN2, so this test manufactures
// the hostile consumer: it patches the header stack field and the
// matching LD SP,imm16 in a copy of UNETTEST.EXE to 0x3F00 and then
// runs the full ping + HTTP flow through the DLL.
// ---------------------------------------------------------------------
{
  const os = require('os');
  const orig = fs.readFileSync(exe('UNETTEST'));
  const patched = Buffer.from(orig);
  const stackTop = patched.readUInt16LE(0x14);
  assert.ok(stackTop >= 0x8000 && stackTop <= 0xc000,
    `unexpected UNETTEST header stack 0x${stackTop.toString(16)}`);
  // Find the single LD SP,STACK_TOP (0x31 lo hi) that matches the header.
  const needle = Buffer.from([0x31, stackTop & 0xff, stackTop >> 8]);
  const hits = [];
  for (let i = patched.indexOf(needle); i !== -1; i = patched.indexOf(needle, i + 1)) hits.push(i);
  assert.strictEqual(hits.length, 1,
    `expected exactly one LD SP,0x${stackTop.toString(16)} in UNETTEST.EXE, found ${hits.length}`);
  const WIN0_SP = 0x3f00;
  patched.writeUInt16LE(WIN0_SP, 0x14);
  patched.writeUInt16LE(WIN0_SP, hits[0] + 1);
  const tmp = path.join(os.tmpdir(), `unettest-win0-stack-${process.pid}.EXE`);
  fs.writeFileSync(tmp, patched);
  try {
    { // full TCP flow (cold calls: literal parse, next-hop, ARP build+drain)
      const r = runExe(tmp, '192.168.7.1 80', dllScenario({
        responders: { arp: arpToServer, tcp: { body: 'hi', status: 200 } },
      }));
      assert.strictEqual(r.exitCode, 0);
      assert.match(r.output, /NETINIT ok/);
      assert.match(r.output, /resolve: 192\.168\.7\.1/);
      assert.match(r.output, /HTTP\/1\.1 200 OK/);
      assert.match(r.output, /--- closed ---/);
      count();
    }
    { // -u flow: ICMP echo build + drain (the deepest cold paths -- the
      // drain calls back into hot driver code on the switched stack) plus
      // a byte-exact UDP echo.  No tcp responder here: the harness
      // dispatcher hands every frame to responders.tcp when it is
      // configured, so ping and tcp cannot be exercised in one scenario.
      const r = runExe(tmp, '-u 7777 192.168.7.1', dllScenario({
        responders: { arp: arpToServer, icmp: {}, udp: { port: 7777 } },
      }));
      assert.strictEqual(r.exitCode, 0);
      assert.match(r.output, /ping: \d+ ms/);
      assert.match(r.output, /udp reply: len=21 data=SPRINTER UNETTEST UDP/);
      assert.match(r.output, /udp echo ok/);
      count();
    }
  } finally {
    fs.unlinkSync(tmp);
  }
}

// ---------------------------------------------------------------------
// Deep exe-homedir: WIN0COLD.INIT's .OPEN_SELF builds "<homedir>\
// UNETRTL.DLL" into .PATH.  That buffer used to be an in-image DS 65
// while the worst case writes 63 (homedir) + 1 (separator) + 12
// ("UNETRTL.DLL",0) = 76 bytes, so a homedir of 53 characters or more
// ran off the end straight into WIN0COLD.RUN's code -- on the very first
// NETINIT, before anything could report a problem.  .PATH now overlays
// @MAIN.TX_BUF with 80 usable bytes.  Exercise the exact worst case: a
// 63-character homedir, the longest .find_end's 64-byte scan accepts.
// ---------------------------------------------------------------------
{
  const deepDir = `C:\\${'DEEPDIR\\'.repeat(7)}UNET`;
  assert.strictEqual(deepDir.length, 63, 'vector must hit the 63-char worst case');
  const r = run('UNETTEST', '-u 7777 192.168.7.1', {
    environment: {
      NET_IP: '192.168.7.2', NET_MASK: '255.255.255.0', NET_GW: '192.168.7.1',
      NET_MAC: '02:80:19:11:22:33', NET_RTL_HW: '1/#300', NET: 'RTL',
    },
    appDir: deepDir,
    files: { [`${deepDir}\\UNETRTL.DLL`]: dllBytes },
    responders: { arp: arpToServer, icmp: {}, udp: { port: 7777 } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /NETINIT ok/);
  // PING runs through the cold overlay, so a blob that failed to load --
  // or a RUN whose code had been overwritten by the overflow -- shows up
  // here rather than passing silently.
  assert.match(r.output, /ping: \d+ ms/);
  assert.match(r.output, /udp echo ok/);
  count();
}

console.log(`Actual DSS EXE DLL harness: ${caseCount()} UNETTEST checks passed`);
