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

console.log(`Actual DSS EXE DLL harness: ${caseCount()} UNETTEST checks passed`);
