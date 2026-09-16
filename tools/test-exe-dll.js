#!/usr/bin/env node
// Phase 4 actual-EXE integration vectors: UNETTEST.EXE, the libman 1.3
// consumer that drives UNETRTL.DLL's public UNET ABI directly.
//
// The full DLL flow runs end to end under the harness: NETINIT (including
// the WIN0COLD cold-overlay load from the DLL's own trailing blob), GETCAPS,
// STATUS, RESOLVE (literal IP), PING (ICMP through the cold overlay),
// CONNECT/SEND/RECV/CLOSE over the scripted TCP peer, UDPOPEN/SEND/RECV
// echo, LISTEN/UNLISTEN arming and bounded accept timeouts, and the
// ASYNCSEND SETOPT+CONNECT+SEND path. Passive accept still needs a real network
// peer and are covered by docs/UNETRTL_TESTING_RU.md scenarios D/E instead:
// an actual inbound accept (the ordinary responder does not initiate it).
// The early-response matrix below forces NERR_AGAIN and exact ACK geometry.
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
const dllBytes = fs.readFileSync(process.env.UNET_TEST_DLL || exe('UNETRTL').replace(/\.EXE$/, '.DLL'));
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

// Full 8192-byte stream, including data arriving before SEND returns.
for (const mss of [536, 1460]) {
  for (const slice of [0, 25]) {
    for (const combinedAck of [false, true]) {
      for (const finWithData of [false, true]) {
        const r = run('UNETTEST', `-r ${slice} 192.168.7.1 8080`, dllScenario({
          responders: { arp: arpToServer, tcp: {
            body: Buffer.from(Array.from({ length: 8192 }, (_, i) => i & 255)),
            reliableResponse: true, mss, combinedAck, finWithData,
            oversizeFirst: mss > 536, responseDelayMs: slice ? 80 : 1,
            dataAckDelayMs: slice ? 80 : 1,
          } },
        }));
        assert.strictEqual(r.exitCode, 0, JSON.stringify({ mss, slice, combinedAck, finWithData }) + '\n' + r.output);
        assert.match(r.output, /first8=485454502F312E31/);
        assert.match(r.output, /length=8233 crc32=62763860/);
        assert.match(r.output, /RESULT OK/);
        if (slice) assert.match(r.output, /resumes needed: [1-9]/);
        count();
      }
    }
  }
}

// Deterministic packet geometry and public ABI failure paths.
const { probe, BIGPAY_LEN } = require('./exe-harness/unet-probe');
const { parseTcpSegment, buildTcpSegment, respond } = require('./exe-harness/net-builders');
const init = { fn: 3 };
const connect = (a = 0) => ({ fn: 5, a, de: 'HOST', ix: a ? 'PORT2' : 'PORT' });
const send = (a = 0) => ({ fn: 6, a, de: 'PAYLOAD', ix: 7 });
const recv = (size = 1513, a = 0) => ({ fn: 7, a, de: 'BUFFER', ix: size, iy: 10 });
const close = a => ({ fn: 8, a });
const payload = Buffer.from(Array.from({ length: 1460 }, (_, i) => i & 255));
function peer(onData) {
  return card => {
    const sessions = {};
    card.onTransmit = frame => {
      const seg = parseTcpSegment(frame);
      if (!seg) { respond(frame, card, { responders: { arp: arpToServer } }); return; }
      let t = sessions[seg.srcPort];
      if (seg.flags === 2) {
        t = sessions[seg.srcPort] = { clientMac: seg.sourceMac, clientIp: seg.sourceIp, clientPort: seg.srcPort,
          serverMac: seg.destMac, serverIp: seg.destIp, serverPort: seg.dstPort,
          serverSeq: 0x12345679, clientNext: (seg.seq + 1) >>> 0 };
        card.schedule(1, buildTcpSegment(t, { flags: 18, seq: t.serverSeq - 1, ack: t.clientNext }));
      } else if (t) {
        if (seg.payload.length) t.clientNext = (seg.seq + seg.payload.length) >>> 0;
        onData({ card, seg, t, sessions, emit: (opts, delay = 1) => card.schedule(delay,
          buildTcpSegment(t, { flags: 24, seq: t.serverSeq, ack: t.clientNext, ...opts })) });
      }
    };
  };
}
function checkProbe(r) {
  assert.strictEqual(r.exitCode, 0);
  assert.ok(r.cleanup.isaClosed && r.cleanup.filesClosed);
  assert.ok(r.events.every(e => (e.lost || []).every(v => v === 0)), 'no silently discarded TCP payload');
  count();
}
{ // Oversized ACK+payload+FIN: 536 durable, remainder not ACKed; overlap
  // replay must trim the prefix, accept FIN once, and deliver all bytes.
  let original, injected = false;
  const r = probe([init, connect(), send(), recv(64), ...Array.from({length: 30}, () => recv(64)), close(0)], dllScenario(), peer(({ seg, t, emit }) => {
    if (seg.payload.length && !injected) { injected = true; original = t.serverSeq; emit({ flags: 25, payload }); }
    else if (injected && seg.window && seg.ack > original && seg.ack < original + payload.length) {
      emit({ flags: 25, seq: original, payload });
    }
  }));
  assert.deepStrictEqual(Buffer.concat(r.results.slice(3, -1).filter(v => v.a === 0 || v.a === 7).map(v => v.data)), payload);
  const acks = r.transmittedFrames.map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
  assert.ok(acks.some(a => a.ack === original + 536 && a.window === 0));
  assert.ok(acks.some(a => a.ack === original + payload.length + 1));
  checkProbe(r);
}
{ // Final bytes + FIN entirely during SEND, no retransmission needed to
  // make closure observable on the subsequent public RECV.
  const bytes = Buffer.from('final response');
  const r = probe([init, connect(), send(), recv(), recv(), close(0)], dllScenario(), peer(({seg, emit}) => {
    if (seg.payload.length) emit({ flags: 25, payload: bytes });
  }));
  assert.deepStrictEqual(r.results[3].data, bytes);
  assert.strictEqual(r.results[4].a, 7); // NERR_CLOSED
  checkProbe(r);
}
{ // Save payload before a failed ACK transmission, then retry ACK and drain.
  const txError = { attempts: [] };
  let once = false;
  const bytes = Buffer.from('durable before failed ACK');
  const r = probe([init, connect(), send(), recv(), recv(), close(0)], dllScenario({ txError }), peer(({ card, seg, emit }) => {
    if (seg.payload.length && !once) {
      once = true; txError.attempts.push(card.txAttempts + 1);
      emit({ payload: bytes });
    }
  }));
  assert.strictEqual(r.results[2].a, 0);
  assert.strictEqual(r.results[2].de, 7);
  assert.deepStrictEqual(r.results[3].data, bytes);
  checkProbe(r);
}
{ // Full pending queue must not prevent ACKing SEND on the same channel.
  let writes = 0;
  const r = probe([init, connect(), send(), send(), recv(), close(0)], dllScenario(), peer(({seg, emit}) => {
    if (seg.payload.length) {
      writes++;
      emit({ payload: writes === 1 ? payload.subarray(0,536) : payload.subarray(0,100) });
    }
  }));
  assert.strictEqual(r.results[2].de, 7);
  assert.strictEqual(r.results[3].a, 0);
  assert.strictEqual(r.results[3].de, 7);
  assert.deepStrictEqual(r.results[4].data, payload.subarray(0,536));
  checkProbe(r);
}
{ // Payload with a stale ACK is saved immediately, survives AGAIN, and is
  // readable while SEND remains suspended. Resume settles on a duplicate-
  // sequence pure ACK. Its ACK field is independent of receive capacity.
  const bytes = Buffer.from('early data before outgoing ACK');
  const r = probe([init, connect(), {fn: 17, a: 3, de: 25}, send(), recv(), send(), send(), send(), close(0)], dllScenario(), peer(({seg, emit}) => {
    if (seg.payload.length) {
      emit({ ack: seg.seq, payload: bytes });
      emit({ flags: 16 }, 70);
    }
  }));
  assert.strictEqual(r.results[3].a, 15); // NERR_AGAIN
  assert.deepStrictEqual(r.results[4].data, bytes);
  assert.ok(r.results.slice(5,8).some(v => v.a === 0 && v.de === 7));
  checkProbe(r);
}
{ // Two channels: process a 1460-byte foreign segment while waiting for
  // the selected channel's ACK, then reopen the owner's zero window.
  let second, injected = false;
  const bytes = Buffer.from('selected reply');
  const r = probe([init, connect(), connect(1), send(), recv(1513,1), recv(), close(0), close(1)], dllScenario(), peer(({seg, t, sessions, card, emit}) => {
    second = Object.values(sessions).find(v => v.serverPort === 8081);
    if (seg.payload.length && !injected) {
      injected = true;
      card.schedule(1, buildTcpSegment(second, {flags:24,seq:second.serverSeq,ack:second.clientNext,payload}));
      emit({ payload: bytes }, 2);
    }
  }));
  assert.strictEqual(r.results[3].a, 0);
  assert.deepStrictEqual(r.results[4].data, payload.subarray(0,536));
  assert.deepStrictEqual(r.results[5].data, bytes);
  const wire = r.transmittedFrames.map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
  assert.ok(wire.some(v => v.dstPort === 8081 && v.window === 0));
  assert.ok(wire.some(v => v.dstPort === 8081 && v.window === 536));
  assert.ok(wire.some(v => v.dstPort === 8080 && v.window > 0));
  checkProbe(r);
}

{ // A blocking RECV lends its caller buffer to the selected channel's
  // advertised window.  The final ACK deliberately retracts that transient
  // capacity to the durable 536-byte queue; the next active RECV must publish
  // the newly available 2048-byte caller buffer before it waits for data.
  // A segment crossing the caller boundary is split between caller and pending storage;
  // the next call consumes that tail and continues nonblocking instead of
  // returning a tiny fragment.  Every non-final result must therefore fill
  // all 2048 bytes offered by the consumer.
  // Exercise both channels with a peer that obeys receive MSS 536 and sends no
  // farther than the current cumulative ACK + window edge. Without the opening
  // update neither stream can fill a caller buffer per call in this budget.
  const streams = {
    8080: Buffer.from(Array.from({ length: 12000 }, (_, i) => (i * 17 + 3) & 255)),
    8081: Buffer.from(Array.from({ length: 12000 }, (_, i) => (i * 29 + 11) & 255)),
  };
  const flow = new Map();
  const setup = peer(({ card, seg, t, emit }) => {
    let f = flow.get(t.serverPort);
    if (seg.payload.length && !f) {
      f = { base: t.serverSeq, acked: 0, sent: 0, bytes: streams[t.serverPort] };
      flow.set(t.serverPort, f);
      emit({ flags: 16 }, 1);       // settle the client's request SEND
    }
    if (!f) return;
    const acked = (seg.ack - f.base) >>> 0;
    if (acked <= f.bytes.length && acked > f.acked) f.acked = acked;
    const edge = Math.min(f.bytes.length, f.acked + seg.window);
    const delay = 1;
    while (f.sent < edge) {
      const size = Math.min(536, edge - f.sent);
      const last = f.sent + size === f.bytes.length;
      card.schedule(delay, buildTcpSegment(t, {
        flags: 16 | 8 | (last ? 1 : 0),
        seq: (f.base + f.sent) >>> 0,
        ack: t.clientNext,
        payload: Array.from(f.bytes.subarray(f.sent, f.sent + size)),
      }));
      f.sent += size;
    }
  });
  const callsPerChannel = Math.ceil(streams[8080].length / 2048);
  const commands = [init, connect(), connect(1), send(),
    ...Array.from({ length: callsPerChannel }, () => recv(2048)),
    send(1),
    ...Array.from({ length: callsPerChannel }, () => recv(2048, 1)),
    close(0), close(1)];
  const r = probe(commands, dllScenario(), setup);
  const firstRecv = 4;
  const secondRecv = firstRecv + callsPerChannel + 1;
  const got0 = Buffer.concat(r.results.slice(firstRecv, firstRecv + callsPerChannel).map(v => v.data));
  const got1 = Buffer.concat(r.results.slice(secondRecv, secondRecv + callsPerChannel).map(v => v.data));
  assert.deepStrictEqual(got0, streams[8080]);
  assert.deepStrictEqual(got1, streams[8081]);
  for (const results of [
    r.results.slice(firstRecv, firstRecv + callsPerChannel),
    r.results.slice(secondRecv, secondRecv + callsPerChannel),
  ]) {
    for (let i = 0; i < results.length; i++) {
      const expected = Math.min(2048, streams[8080].length - i * 2048);
      assert.strictEqual(results[i].data.length, expected,
        `RECV ${i} returned ${results[i].data.length} bytes instead of filling ${expected}`);
      assert.strictEqual(results[i].ix & 4, 0, 'long receive stream reported UNET_RXF_LOST');
    }
  }
  const wire = r.transmittedFrames.map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
  for (const port of [8080, 8081]) {
    assert.strictEqual(wire.find(v => v.dstPort === port && v.flags === 2)?.mss, 536,
      `channel ${port}: UNETRTL did not advertise receive MSS 536`);
    const acks = wire.filter(v => v.dstPort === port && v.payload.length === 0);
    const reopens = acks.filter((v, i) => acks[i + 1]?.ack === v.ack
      && acks[i + 1].window > v.window);
    assert.ok(reopens.length >= 3,
      `channel ${port}: next active RECV did not repeatedly reopen its durable window`);
  }
  checkProbe(r);
}

{ // While channel 0 owns a 2048-byte direct buffer, a 1460-byte segment for
  // channel 1 may use only channel 1's durable 536-byte queue.  In particular,
  // its ACK must advertise zero rather than borrowing channel 0's capacity.
  let injected = false;
  const r = probe([init, connect(), connect(1), recv(2048), recv(2048, 1), close(0), close(1)],
    dllScenario(), peer(({ card, seg, sessions }) => {
      const foreign = Object.values(sessions).find(v => v.serverPort === 8081);
      if (!injected && foreign && seg.dstPort === 8080 && !seg.payload.length && seg.window === 2584) {
        injected = true;
        card.schedule(1, buildTcpSegment(foreign, {
          flags: 24, seq: foreign.serverSeq, ack: foreign.clientNext, payload,
        }));
      }
    }));
  assert.strictEqual(r.results[3].de, 0);
  assert.ok(r.results[3].ix & 8, 'selected channel did not report UNET_RXF_XCHAN');
  assert.deepStrictEqual(r.results[4].data, payload.subarray(0, 536));
  assert.strictEqual(r.results[3].ix & 4, 0);
  assert.strictEqual(r.results[4].ix & 4, 0);
  const wire = r.transmittedFrames.map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
  const foreignAcks = wire.filter(v => v.dstPort === 8081 && v.payload.length === 0);
  const foreignStoreAck = foreignAcks.find(v => v.ack === 0x12345679 + 536);
  assert.strictEqual(foreignStoreAck?.window, 0,
    'foreign channel borrowed the selected channel caller buffer');
  assert.ok(foreignAcks.some(v => v.ack === foreignStoreAck.ack && v.window > 536),
    'channel did not publish its own caller buffer when it became selected');
  checkProbe(r);
}

{ // The opening window update is a real NIC transmission.  Its failure
  // returns the normal hardware error, keeps the diagnostic snapshot, closes
  // ISA, and the public wrapper retracts the caller buffer before CLOSE.
  const txError = { attempts: [] };
  const open = connect();
  open.after = ({ card }) => txError.attempts.push(card.txAttempts + 1);
  const r = probe([init, open, recv(2048), { fn: 16, de: 'BUFFER', ix: 72 }, close(0)],
    dllScenario({ txError }), peer(() => {}));
  assert.strictEqual(r.results[2].a, 1); // NERR_HW
  assert.strictEqual(r.results[2].de, 0);
  assert.strictEqual(r.results[2].ix, 0);
  const diagEnd = r.results[3].data.indexOf(0);
  const diag = r.results[3].data.subarray(0, diagEnd < 0 ? undefined : diagEnd).toString('ascii');
  assert.match(diag, /st=RECV nerr=01/);
  assert.match(diag, /tx=/);
  const wire = r.transmittedFrames.map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
  assert.ok(wire.some(v => (v.flags & 1) && v.window === 536),
    'failed RECV must not leave caller capacity advertised to CLOSE');
  checkProbe(r);
}

{ // A partially ACKed SEND times out. DE is the confirmed prefix, and
  // saved response bytes remain readable on the error path.
  let once = false;
  const bytes = Buffer.from('reply despite failed send');
  const r = probe([init, connect(), send(), recv(), close(0)], dllScenario(), peer(({seg, emit}) => {
    if (seg.payload.length && !once) {
      once = true;
      emit({ ack: (seg.seq + 3) >>> 0, payload: bytes });
      emit({ flags: 16, ack: (seg.seq + 2) >>> 0 }, 2); // stale: cannot roll back UNA
      emit({ flags: 16, ack: (seg.seq + 8) >>> 0 }, 3); // future: cannot claim SEND success
    }
  }));
  assert.notStrictEqual(r.results[2].a, 0);
  assert.strictEqual(r.results[2].de, 3);
  assert.deepStrictEqual(r.results[3].data, bytes);
  checkProbe(r);
}
{ // RST may carry the final cumulative ACK. The call still reports CLOSED,
  // but DE must include the prefix the peer acknowledged before closing.
  let once = false;
  const r = probe([init, connect(), send()], dllScenario(), peer(({seg, emit}) => {
    if (seg.payload.length && !once) {
      once = true;
      emit({ flags: 20, ack: (seg.seq + 3) >>> 0 });
    }
  }));
  assert.strictEqual(r.results[2].a, 7); // NERR_CLOSED
  assert.strictEqual(r.results[2].de, 3);
  checkProbe(r);
}
{ // During public RECV a failed ACK cannot hide bytes already copied to
  // the caller. Retry the debt on the next call; no duplicate delivery.
  const txError = { attempts: [] };
  const bytes = Buffer.from('public receive survives ACK error');
  let once = false;
  const r = probe([init, connect(), send(), recv(), recv(), close(0)], dllScenario({ txError }), peer(({card, seg, emit}) => {
    if (seg.payload.length && !once) {
      once = true;
      emit({ flags: 16 });
      emit({ payload: bytes }, 2);
      txError.attempts.push(card.txAttempts + 3); // reply ACK, RECV window update, then flush
    }
  }));
  assert.deepStrictEqual(r.results[3].data, bytes);
  assert.strictEqual(r.results[4].de, 0);
  checkProbe(r);
}

{ // Same ABI and receive sink after libman relocates the DLL into WIN2.
  const bytes = Buffer.from('window two final bytes');
  let sent = false;
  const r = probe([init, connect(), send(), recv(), recv(), close(0)], dllScenario(), peer(({seg, emit}) => {
    if (seg.payload.length) emit({ flags: 16 });
    else if (!sent && seg.window === 2049) {
      sent = true;
      emit({ flags: 25, payload: bytes });
    }
  }), 2);
  assert.deepStrictEqual(r.results[3].data, bytes);
  assert.strictEqual(r.results[4].a, 7);
  const wire = r.transmittedFrames.map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
  assert.ok(wire.some(v => v.dstPort === 8080 && !v.payload.length && v.window === 2049),
    'WIN2 relocation did not publish the 1513+536 active RECV window');
  checkProbe(r);
}

for (const dllWindow of [1, 2]) { // SNC layout uses the DLL in WIN2.
  const bytes = Buffer.alloc(8243);
  Buffer.from('HTTP/1.1 207 Multi-Status\r\nContent-Length: 8192\r\n\r\n').copy(bytes);
  for (let i = 51; i < bytes.length; i++) bytes[i] = (i - 51) & 255;
  let flow;
  const setup = peer(({ card, seg, t, emit }) => {
    if (seg.payload.length && !flow) {
      flow = { base: t.serverSeq, acked: 0, sent: 1460, oversize: true };
      emit({ payload: bytes.subarray(0, 1460) }, 1);
      return;
    }
    if (!flow) return;
    const acked = (seg.ack - flow.base) >>> 0;
    if (acked <= bytes.length && acked > flow.acked) flow.acked = acked;
    if (flow.oversize && flow.acked) {
      flow.sent = flow.acked;            // retransmit the unaccepted suffix
      flow.oversize = false;
    }
    const edge = Math.min(bytes.length, flow.acked + seg.window);
    while (flow.sent < edge) {
      const size = Math.min(536, edge - flow.sent);
      const last = flow.sent + size === bytes.length;
      card.schedule(1, buildTcpSegment(t, {
        flags: 16 | 8 | (last ? 1 : 0),
        seq: (flow.base + flow.sent) >>> 0,
        ack: t.clientNext,
        payload: Array.from(bytes.subarray(flow.sent, flow.sent + size)),
      }));
      flow.sent += size;
    }
  });
  const r = probe([init, connect(), send(),
    ...Array.from({ length: 10 }, () => recv(2048)), close(0)],
  dllScenario(), setup, dllWindow);
  const got = Buffer.concat(r.results.slice(3, -1)
    .filter(v => v.a === 0 || v.a === 7).map(v => v.data));
  assert.deepStrictEqual(got, bytes, `DLL WIN${dllWindow}: WebDAV response was truncated`);
  checkProbe(r);
}

for (const dllWindow of [1, 2]) { // OPTIONS close, then PROPFIND reconnect.
  const options = Buffer.from('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n');
  const propfind = Buffer.alloc(8243);
  Buffer.from('HTTP/1.1 207 Multi-Status\r\nContent-Length: 8192\r\n\r\n').copy(propfind);
  for (let i = 51; i < propfind.length; i++) propfind[i] = (i - 51) & 255;
  const flows = new Map();
  let requestNo = 0;
  const setup = peer(({ card, seg, t, emit }) => {
    let flow = flows.get(t.clientPort);
    if (seg.payload.length && !flow) {
      const body = requestNo++ ? propfind : options;
      flow = { base: t.serverSeq, acked: 0, sent: 0, body };
      flows.set(t.clientPort, flow);
    }
    if (!flow) return;
    const acked = (seg.ack - flow.base) >>> 0;
    if (acked <= flow.body.length && acked > flow.acked) flow.acked = acked;
    const edge = Math.min(flow.body.length, flow.acked + seg.window);
    while (flow.sent < edge) {
      const size = Math.min(536, edge - flow.sent);
      const last = flow.sent + size === flow.body.length;
      card.schedule(1, buildTcpSegment(t, {
        flags: 16 | 8 | (last ? 1 : 0),
        seq: (flow.base + flow.sent) >>> 0,
        ack: t.clientNext,
        payload: Array.from(flow.body.subarray(flow.sent, flow.sent + size)),
      }));
      flow.sent += size;
    }
  });
  const r = probe([init,
    connect(), send(), recv(2048), close(0),
    connect(), send(), ...Array.from({ length: 10 }, () => recv(2048)), close(0)],
  dllScenario(), setup, dllWindow);
  assert.deepStrictEqual(r.results[3].data, options,
    `DLL WIN${dllWindow}: OPTIONS response was truncated`);
  const got = Buffer.concat(r.results.slice(7, -1)
    .filter(v => v.a === 0 || v.a === 7).map(v => v.data));
  assert.deepStrictEqual(got, propfind,
    `DLL WIN${dllWindow}: PROPFIND response after reconnect was truncated`);
  checkProbe(r);
}

// Ordered client payload as it reached the wire, retransmissions dropped.
function sentStream(r) {
  const segments = r.transmittedFrames.map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
  const chunks = [];
  let next = null;
  for (const s of segments) {
    if (!s.payload.length) continue;
    if (next === null) next = s.seq;
    if (s.seq !== next) continue;               // retransmission of an older segment
    assert.ok(s.payload.length <= 536, 'outbound segment exceeded the 536-byte MSS');
    chunks.push(Buffer.from(s.payload));
    next = (next + s.payload.length) >>> 0;
  }
  return Buffer.concat(chunks);
}
const bigSend = (a = 0) => ({ fn: 6, a, de: 'BIGPAY', ix: BIGPAY_LEN });
const lasterr = () => ({ fn: 16, de: 'BUFFER', ix: 72 });
const sendslice = ms => ({ fn: 17, a: 3, de: ms });
const expectedBig = (r, blocks) => Buffer.from(Array.from({ length: blocks * BIGPAY_LEN },
  (_, i) => (r.symbols.BIGPAY + i % BIGPAY_LEN) & 255));
function diagLine(result) {
  const end = result.data.indexOf(0);
  return result.data.subarray(0, end < 0 ? undefined : end).toString('ascii');
}

{ // Until the first failure LASTERR follows live state on EVERY call: a
  // healthy poll must not freeze its own line (a first-byte "buffer is
  // non-empty" guard did exactly that), while a failure freezes the line
  // and a later successful call leaves it alone.
  // The peer has to acknowledge the FIN: an unacknowledged close is itself a
  // failure now, and this case needs the final CLOSE to succeed.
  const r = probe([init, lasterr(), connect(), lasterr(), { fn: 6, a: 1, de: 'PAYLOAD', ix: 7 },
    lasterr(), close(0), lasterr()], dllScenario(),
    peer(({ seg, t, emit }) => {
      if (seg.flags & 1) { t.clientNext = (seg.seq + 1) >>> 0; emit({ flags: 16 }); }
    }));
  assert.match(diagLine(r.results[1]), /st=NETINIT nerr=00/);
  assert.match(diagLine(r.results[3]), /st=CONNECT nerr=00/, 'a healthy LASTERR poll froze its own first line');
  assert.strictEqual(r.results[4].a, 11);       // NERR_STATE: channel 1 was never opened
  assert.match(diagLine(r.results[5]), /st=SEND nerr=0B/);
  assert.strictEqual(r.results[6].a, 0);
  assert.match(diagLine(r.results[7]), /st=SEND nerr=0B/, 'a successful CLOSE overwrote the frozen line');
  checkProbe(r);
}

for (const dllWindow of [1, 2]) { // SNC loads the DLL into WIN2.
  { // A long PUT: 20 public SENDs above the MSS with SENDSLICE armed. Every
    // byte reaches the wire once, in sequence, in 536-byte segments, and the
    // final response is readable.
    const BLOCKS = 20;
    const reply = Buffer.from('HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n');
    // Progress is the unique cumulative range by TCP sequence, so a
    // retransmission cannot count twice; the closing reply goes out once.
    let base = null, received = 0, answered = false;
    const r = probe([init, connect(), sendslice(25),
      ...Array.from({ length: BLOCKS }, () => bigSend()), recv(), recv(), close(0)],
    dllScenario(), peer(({ seg, emit }) => {
      if (!seg.payload.length) return;
      if (base === null) base = seg.seq;
      received = Math.max(received, ((seg.seq - base) >>> 0) + seg.payload.length);
      if (received < BLOCKS * BIGPAY_LEN) emit({ flags: 16 });
      else if (!answered) { answered = true; emit({ flags: 25, payload: reply }); }
    }), dllWindow);
    assert.strictEqual(r.results[2].a, 0, 'SETOPT SENDSLICE refused: the slice never armed');
    const sends = r.results.slice(3, 3 + BLOCKS);
    assert.ok(sends.every(v => v.a === 0 && v.de === BIGPAY_LEN),
      `WIN${dllWindow}: a block of the long PUT did not complete: ${JSON.stringify(sends)}`);
    assert.deepStrictEqual(sentStream(r), expectedBig(r, BLOCKS),
      `WIN${dllWindow}: the long PUT corrupted the stream`);
    assert.deepStrictEqual(r.results[3 + BLOCKS].data, reply);
    assert.strictEqual(r.results[4 + BLOCKS].a, 7);   // NERR_CLOSED after the response
    checkProbe(r);
  }
  { // The peer refuses the body it is still being sent: an HTTP status and
    // FIN arrive in one segment while SEND waits for an ACK that will never
    // cover its chunk. This must report the close, not a generic send
    // failure, must not discard the response, and must leave a LASTERR that
    // still describes the SEND after an unrelated call has succeeded.
    const reply = Buffer.from('HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n');
    let once = false;
    // LASTERR is read only AFTER the successful drain, so the assertion
    // cannot pass on a live rebuild: that would report the drain's own
    // st=RECV nerr=00. It is this run's first LASTERR call, so nothing can
    // have cached the line either.
    const r = probe([init, connect(), send(), recv(), lasterr(), recv(), close(0)],
      dllScenario(), peer(({ seg, emit }) => {
        if (seg.payload.length && !once) {
          once = true;
          emit({ flags: 25, ack: (seg.seq + 3) >>> 0, payload: reply });
        }
      }), dllWindow);
    assert.strictEqual(r.results[2].a, 7);        // NERR_CLOSED, never NERR_SEND
    assert.strictEqual(r.results[2].de, 3);       // cumulatively acknowledged prefix
    assert.strictEqual(r.results[3].a, 0);
    assert.deepStrictEqual(r.results[3].data, reply);
    assert.match(diagLine(r.results[4]), /st=SEND nerr=07 tcp=08/,
      `WIN${dllWindow}: the successful drain overwrote the failure diagnostic`);
    assert.strictEqual(r.results[5].a, 7);
    assert.strictEqual(r.results[5].de, 0);
    checkProbe(r);
  }
  { // Same refusal with the response and the FIN in separate segments.
    const reply = Buffer.from('HTTP/1.1 507 Insufficient Storage\r\n\r\n');
    let once = false;
    const r = probe([init, connect(), bigSend(), lasterr(), recv(), recv(), close(0)],
      dllScenario(), peer(({ seg, t, emit }) => {
        if (seg.payload.length && !once) {
          once = true;
          emit({ ack: (seg.seq + 3) >>> 0, payload: reply });
          emit({ flags: 17, seq: (t.serverSeq + reply.length) >>> 0, ack: (seg.seq + 3) >>> 0 }, 2);
        }
      }), dllWindow);
    assert.strictEqual(r.results[2].a, 7);
    assert.strictEqual(r.results[2].de, 3);
    assert.match(diagLine(r.results[3]), /st=SEND nerr=07 tcp=08/);
    assert.deepStrictEqual(r.results[4].data, reply);
    assert.strictEqual(r.results[5].a, 7);
    checkProbe(r);
  }
}

// ---------------------------------------------------------------------
// Close semantics on the wire.  Reported from the field (SNC WebDAV PUT):
// a cancelled PUT was followed by HTTP 423 on the retry because the server
// never learned the first request was over and kept its writer lock.
// ---------------------------------------------------------------------
const tcpOf = r => r.transmittedFrames
  .map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);

{ // A segment that was transmitted but never acknowledged leaves delivery
  // ambiguous: the peer's RCV.NXT is either still the segment's sequence
  // (it never arrived) or one segment past it (it did).  A FIN is wrong at
  // both -- an old duplicate at the first, an out-of-order segment that
  // never reaches end-of-stream at the second -- so the peer would go on
  // waiting for the rest of a body that is never coming.  CLOSE must abort
  // with RST, and cover both candidates, because only an exact RCV.NXT
  // match resets an RFC 5961 peer.
  const r = probe([init, connect(), send(), close(0)], dllScenario(),
    peer(() => {}));                        // peer acknowledges nothing
  const sent = tcpOf(r);
  const data = sent.find(v => v.payload.length === 7);
  assert.ok(data, 'the probe never transmitted its payload');
  assert.strictEqual(r.results[2].a, 5, 'SEND should have reported NERR_SEND');
  assert.ok(!sent.some(v => v.flags & 1), 'an ambiguous close sent a FIN');
  const rsts = sent.filter(v => v.flags & 4);
  assert.deepStrictEqual(rsts.map(v => v.seq).sort(),
    [data.seq, (data.seq + 7) >>> 0].sort(),
    'RST did not cover both candidates for the peer RCV.NXT');
  assert.strictEqual(r.results[3].a, 0, 'an abort that reached the wire reported a failure');
  checkProbe(r);
}

{ // Only one of the two sequences is the peer's RCV.NXT, and which one it is
  // is exactly what cannot be known here -- so a RST that never left the NIC
  // may well have been the one that would have been honoured.  The other must
  // still be attempted, and must not vouch for it.
  const txError = { attempts: [] };
  let payloads = 0;
  const r = probe([init, connect(), send(), close(0)], dllScenario({ txError }),
    peer(({ card, seg }) => {
      // Nothing is acknowledged, so the payload goes out SEND_ATTEMPTS times
      // and the transmit right after the last one is the abort's first RST.
      if (seg.payload.length && ++payloads === 4) txError.attempts.push(card.txAttempts + 1);
    }));
  const rsts = tcpOf(r).filter(v => v.flags & 4);
  assert.strictEqual(rsts.length, 1, 'the second RST was not attempted after the first failed');
  assert.strictEqual(r.results[3].a, 1,
    'CLOSE hid a RST that never went out (NERR_HW expected)');
  checkProbe(r);
}

// A NIC transmit failure says nothing about the EARLIER attempts of the same
// segment.  These vectors pin down which of them may rewind SND_NXT: only a
// first attempt that never left the NIC.  The DLL must not mistake a failed
// retransmission for proof that the first copy was never delivered, or the
// following CLOSE reads the stream as fully acknowledged and sends a FIN at an
// obsolete sequence number -- the peer that DID take the segment then keeps
// the request (and whatever it locked) until its own timeout.
const seqsOf = segs => segs.map(v => v.seq).sort();
const expectAbortAt = (r, closeIx, seq0, msg) => {
  const sent = tcpOf(r);
  assert.ok(!sent.some(v => v.flags & 1), `${msg}: a FIN went out at a possibly-stale sequence`);
  assert.deepStrictEqual(seqsOf(sent.filter(v => v.flags & 4)), seqsOf([{ seq: seq0 }, { seq: (seq0 + 7) >>> 0 }]),
    `${msg}: RST did not cover both candidates for the peer RCV.NXT`);
  assert.strictEqual(r.results[closeIx].a, 0, `${msg}: an abort that reached the wire reported a failure`);
};

{ // First transmit succeeds, its ACK is lost, the first retransmission fails
  // in the NIC.  SEND reports NERR_HW, but the segment is still in flight
  // for all this side can tell, so CLOSE must abort at both candidates.
  const txError = { attempts: [] };
  let payloads = 0;
  const r = probe([init, connect(), send(), close(0)], dllScenario({ txError }),
    peer(({ card, seg }) => {
      // The peer takes the segment and stays silent; the next transmit after
      // the first copy is the retransmit, which is the one that fails.
      if (seg.payload.length && ++payloads === 1) txError.attempts.push(card.txAttempts + 1);
    }));
  const data = tcpOf(r).find(v => v.payload.length === 7);
  assert.ok(data, 'the probe never transmitted its payload');
  assert.strictEqual(payloads, 1, 'the failed retransmit reached the peer');
  assert.strictEqual(r.results[2].a, 1, 'SEND should have reported NERR_HW');
  expectAbortAt(r, 3, data.seq, 'retransmit TX error');
  checkProbe(r);
}

{ // Same, but the retransmission happens after an ASYNCSEND suspension: the
  // slice returns NERR_AGAIN, the resumed call exhausts the attempt and its
  // retransmit fails.  The resume must not have forgotten that the first
  // copy went out.
  const txError = { attempts: [] };
  let payloads = 0;
  const r = probe([init, connect(), sendslice(500), send(), send(), close(0)], dllScenario({ txError }),
    peer(({ card, seg }) => {
      if (seg.payload.length && ++payloads === 1) txError.attempts.push(card.txAttempts + 1);
    }));
  const data = tcpOf(r).find(v => v.payload.length === 7);
  assert.strictEqual(r.results[3].a, 15, 'the sliced SEND did not suspend (NERR_AGAIN expected)');
  assert.strictEqual(r.results[4].a, 1, 'the resumed SEND should have reported NERR_HW');
  assert.strictEqual(payloads, 1, 'the failed retransmit reached the peer');
  expectAbortAt(r, 5, data.seq, 'retransmit TX error after resume');
  checkProbe(r);
}

{ // The first transmit itself fails: nothing ever left the NIC, so the
  // rewind is correct and CLOSE keeps its orderly FIN at the unadvanced
  // sequence -- the one case where a TX error IS proof of non-delivery.
  const txError = { attempts: [] };
  let fins = 0;
  const r = probe([init, connect(), send(), close(0)], dllScenario({ txError }),
    peer(({ card, seg, t, emit }) => {
      if (seg.flags & 16 && !seg.payload.length && !(seg.flags & 1) && !txError.attempts.length) {
        txError.attempts.push(card.txAttempts + 1);   // the handshake ACK; next is the data
      }
      if (seg.flags & 1) { fins += 1; t.clientNext = (seg.seq + 1) >>> 0; emit({ flags: 16 }); }
    }));
  const sent = tcpOf(r);
  assert.ok(!sent.some(v => v.payload.length === 7), 'the failed first transmit reached the peer');
  assert.strictEqual(r.results[2].a, 1, 'SEND should have reported NERR_HW');
  assert.ok(!sent.some(v => v.flags & 4), 'an unsent segment was aborted with RST');
  assert.strictEqual(fins, 1, 'expected exactly one orderly FIN');
  assert.strictEqual(r.results[3].a, 0, 'an orderly close after an unsent segment reported a failure');
  checkProbe(r);
}

{ // Everything acknowledged: an orderly FIN, at the sequence right after
  // the acknowledged data, and exactly one of them.
  let fins = 0;
  const r = probe([init, connect(), send(), close(0)], dllScenario(),
    peer(({ seg, t, emit }) => {
      if (seg.payload.length) { emit({ flags: 16 }); return; }
      if (seg.flags & 1) { fins += 1; t.clientNext = (seg.seq + 1) >>> 0; emit({ flags: 16 }); }
    }));
  const sent = tcpOf(r);
  const data = sent.find(v => v.payload.length === 7);
  const fin = sent.find(v => v.flags & 1);
  assert.strictEqual(fins, 1, 'an acknowledged FIN was retransmitted anyway');
  assert.strictEqual(fin.seq, (data.seq + 7) >>> 0, 'FIN sent at the wrong sequence');
  assert.ok(!sent.some(v => v.flags & 4), 'an orderly close sent a RST');
  checkProbe(r);
}

{ // RTL.SEND_FRAME only proves the NIC transmitted.  Swallow the ACK of the
  // first FIN and the close must retransmit it rather than assume delivery.
  let fins = 0;
  const r = probe([init, connect(), send(), close(0)], dllScenario(),
    peer(({ seg, t, emit }) => {
      if (seg.payload.length) { emit({ flags: 16 }); return; }
      if (seg.flags & 1) {
        fins += 1;
        t.clientNext = (seg.seq + 1) >>> 0;
        if (fins > 1) emit({ flags: 16 });      // acknowledge only the retransmit
      }
    }));
  assert.strictEqual(fins, 2, 'a lost FIN was never retransmitted');
  const fin = tcpOf(r).filter(v => v.flags & 1);
  assert.strictEqual(fin[0].seq, fin[1].seq, 'the retransmitted FIN changed sequence');
  assert.strictEqual(r.results[3].a, 0, 'an acknowledged FIN was reported as a failed close');
  checkProbe(r);
}

{ // Every attempt met with silence.  The channel goes away regardless -- there
  // is nothing left to retry from locally -- but reporting success would tell
  // the consumer the peer had been informed when it had not, which is the
  // residual form of the reported failure: a server still holding its writer
  // lock after the client believes it closed cleanly.
  let fins = 0;
  const r = probe([init, connect(), send(), close(0)], dllScenario(),
    peer(({ seg, emit }) => {
      if (seg.payload.length) { emit({ flags: 16 }); return; }
      if (seg.flags & 1) fins += 1;             // seen, never acknowledged
    }));
  assert.strictEqual(r.results[2].a, 0, 'SEND should have succeeded');
  assert.strictEqual(fins, 3, 'the FIN was not retransmitted for the full attempt budget');
  assert.strictEqual(r.results[3].a, 12,
    'an unacknowledged FIN was reported as a clean close (NERR_TIMEOUT expected)');
  checkProbe(r);
}

{ // A close whose FIN never reached the wire must stay visible in the return
  // status.  The channel is released either way -- there is nothing left to
  // retry from locally -- but reporting success would tell the consumer the
  // peer had been informed when it had not.
  const txError = { attempts: [] };
  let sent = false, armed = false;
  const r = probe([init, connect(), send(), close(0)], dllScenario({ txError }),
    peer(({ card, seg, emit }) => {
      if (seg.payload.length) { sent = true; emit({ flags: 16 }); return; }
      // Once the send is confirmed the client flushes its cumulative ACK;
      // the FIN is the very next transmit, so arm the failure on that one.
      // (The handshake ACK looks identical, hence the `sent` guard.)
      if (sent && seg.flags === 0x10 && !armed) { armed = true; txError.attempts.push(card.txAttempts + 1); }
    }));
  assert.strictEqual(r.results[2].a, 0, 'SEND should have succeeded');
  assert.strictEqual(r.results[3].a, 1, 'CLOSE reported success for a FIN that never went out');
  checkProbe(r);
}

{ // Esc during the FIN wait is not an answer from the peer.  A consumer that
  // armed CANCELKEYS and whose user just cancelled a transfer still has that
  // keypress in the DSS buffer when it calls CLOSE, so the very first tick of
  // the wait ends it -- and calling that a clean close would report success
  // for a teardown the peer never saw.  CANCELKEYS is armed only after the
  // SEND so the key cannot be eaten by an earlier wait loop.
  let fins = 0;
  const r = probe([init, connect(), send(), { fn: 17, a: 1, de: 1 }, close(0)],
    dllScenario({ keys: ['escape'] }),
    peer(({ seg, emit }) => {
      if (seg.payload.length) { emit({ flags: 16 }); return; }
      if (seg.flags & 1) fins += 1;             // seen, never acknowledged
    }));
  assert.strictEqual(r.results[4].a, 8,
    'a cancelled FIN wait was reported as a clean close (NERR_CANCEL expected)');
  assert.strictEqual(fins, 1, 'the cancelled wait retransmitted anyway');
  checkProbe(r);
}

{ // Closing one channel must not cost the other one a reply that arrives
  // while the close is waiting for its FIN ACK.  This is the regression the
  // old blind post-FIN drain caused (FTP's "226 Transfer complete" on the
  // control connection, discarded while the data connection was closing).
  let second, injected = false;
  const bytes = Buffer.from('226 Transfer complete.\r\n');
  const r = probe([init, connect(), connect(1), send(), close(0), recv(1513, 1), close(1)],
    dllScenario(), peer(({ seg, t, sessions, card, emit }) => {
      second = Object.values(sessions).find(v => v.serverPort === 8081);
      if (seg.payload.length) { emit({ flags: 16 }); return; }
      if ((seg.flags & 1) && seg.dstPort === 8080) {
        t.clientNext = (seg.seq + 1) >>> 0;
        if (!injected) {                      // arrives DURING the FIN wait
          injected = true;
          card.schedule(1, buildTcpSegment(second,
            { flags: 24, seq: second.serverSeq, ack: second.clientNext, payload: bytes }));
        }
        emit({ flags: 16 }, 3);               // ACK the FIN only after that
      }
    }));
  assert.strictEqual(r.results[4].a, 0, 'CLOSE of channel 0 failed');
  assert.deepStrictEqual(r.results[5].data, bytes,
    'the other channel lost a segment that arrived during the close');
  checkProbe(r);
}

console.log(`Actual DSS EXE DLL harness: ${caseCount()} UNETTEST checks passed`);
