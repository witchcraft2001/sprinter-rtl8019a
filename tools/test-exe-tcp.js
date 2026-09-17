#!/usr/bin/env node
// Phase 3 actual-EXE integration vectors: TCP client utilities (WGET,
// DLDIRECT, DLDIRCP, DLWIN3, DLOOO3) plus a DLSPEED smoke test through UNETRTL.DLL.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { runExe } = require('./exe-harness/harness.js');
const { parseTcpSegment, buildHttpResponse } = require('./exe-harness/net-builders.js');
const { count, caseCount, checkCleanup, checkCleanupClaimedPage } = require('./exe-harness/test-util.js');

const root = path.resolve(__dirname, '..');
const exe = (name) => path.join(root, 'build', `${name}.EXE`);
const run = (name, args, scenario = {}) => runExe(exe(name), args, scenario);

const NET_ENV = { NET_IP: '192.168.7.2', NET_MAC: '02:80:19:11:22:33' };
const arpToServer = { mac: [2, 0, 0, 0, 0, 1] };

// ---------------------------------------------------------------------
// WGET.EXE
// ---------------------------------------------------------------------
{
  const r = run('WGET', 'http://192.168.7.1/file.txt -y', {
    environment: { ...NET_ENV },
    responders: { arp: arpToServer, tcp: { body: 'Hello from a fake HTTP server.\n' } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Resolved 192\.168\.7\.1 -> 192\.168\.7\.1 port 80/);
  assert.match(r.output, /Connecting to 192\.168\.7\.1 port 80\.\.\.ESTABLISHED\./);
  assert.match(r.output, /Done\. 31 bytes received\./);
  assert.match(r.output, /RESULT OK/);
  const data = r.files['C:\\NET\\FILE.TXT'];
  assert.strictEqual(Buffer.from(data.data || data).toString(), 'Hello from a fake HTTP server.\n');
  checkCleanupClaimedPage(r);
}
{ // Download through a HOSTNAME, not a literal IP.  Every other WGET
  // vector passes a dotted quad, so the DNS-then-TCP sequence -- resolve
  // over UDP, then open a TCP session on the same NIC and ring -- was
  // never exercised end to end.  That is exactly the shape that fails in
  // the field ("Resolved ... ESTABLISHED ... TCP recv failed 0x02"), so
  // it needs to be a standing vector rather than a manual check.
  const r = run('WGET', 'http://example.com/file.txt -y', {
    environment: { ...NET_ENV, NET_DNS1: '192.168.7.1' },
    responders: {
      arp: arpToServer,
      dns: { ip: [192, 168, 7, 1] },
      tcp: { body: 'Hello from a fake HTTP server.\n' },
    },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Resolved example\.com -> 192\.168\.7\.1 port 80/);
  assert.match(r.output, /ESTABLISHED\./);
  assert.match(r.output, /Done\. 31 bytes received\./);
  const data = r.files['C:\\NET\\FILE.TXT'];
  assert.strictEqual(Buffer.from(data.data || data).toString(), 'Hello from a fake HTTP server.\n');
  checkCleanupClaimedPage(r);
}
{ // ...and the same download when the first two DNS queries are lost, so
  // the retransmit path in resolve_lib runs immediately before the TCP
  // session rather than on its own.
  const r = run('WGET', 'http://example.com/file.txt -y', {
    environment: { ...NET_ENV, NET_DNS1: '192.168.7.1' },
    responders: {
      arp: arpToServer,
      dns: { ip: [192, 168, 7, 1], drop: 2 },
      tcp: { body: 'Hello from a fake HTTP server.\n' },
    },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Done\. 31 bytes received\./);
  checkCleanupClaimedPage(r);
}
{ // -o overrides the derived output filename
  const r = run('WGET', 'http://192.168.7.1/file.txt -y -o OUT.BIN', {
    environment: { ...NET_ENV }, responders: { arp: arpToServer, tcp: { body: 'x' } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.ok(r.files['C:\\NET\\OUT.BIN'], 'expected -o output filename to be used');
  checkCleanupClaimedPage(r);
}
{
  // KNOWN BUG (reported upstream, not fixed here), HIGH SEVERITY: on any
  // non-2xx HTTP status, wget.asm's PARSE_STATUS_LINE prints
  // "[E] <status line>" (the .NOT_2XX branch) or "Redirect: <status line>"
  // (.IS_3XX) via DSS_PCHARS/RST DSS WITHOUT closing the ISA window first
  // -- the exact same ISA-discipline violation class as the tftp.asm bug
  // above, and far more commonly reachable (any 404/500/301/302 response).
  // The adjacent .OK_2XX branch a few lines below in the same function
  // DOES bracket its own PRINTLN with @ISA.ISA_CLOSE/@ISA.ISA_OPEN,
  // showing the fix pattern already exists in the same file. Once fixed,
  // replace this assert.throws with a normal exit-6 success check.
  assert.throws(() => run('WGET', 'http://192.168.7.1/missing.txt -y', {
    environment: { ...NET_ENV }, responders: { arp: arpToServer, tcp: { status: 404, body: 'not found' } },
  }), /DSS call while ISA window is open/);
  count();
}
{ // -r resume: existing partial file + Range request, server answers 206
  const r = run('WGET', 'http://192.168.7.1/file.bin -r', {
    environment: { ...NET_ENV },
    files: { 'C:\\NET\\FILE.BIN': Buffer.from('0123456789') },
    responders: { arp: arpToServer, tcp: { status: 206, body: 'ABCDEF' } },
  });
  assert.strictEqual(r.exitCode, 0);
  const data = r.files['C:\\NET\\FILE.BIN'];
  assert.strictEqual(Buffer.from(data.data || data).toString(), '0123456789ABCDEF');
  checkCleanupClaimedPage(r);
}
// KNOWN BUG (reported upstream, not fixed here): wget.asm opens the local
// output file (OUT_FH) once, before the resolve/ARP/connect sequence for
// the first hop -- but RESOLVE_FAIL, ARP_TIMEOUT, and TCP_OPEN_FAIL all
// exit without closing it (unlike HTTP_FAIL/FILE_FAIL/USER_ABORT, which
// do). The harness's "EXIT with unclosed files" invariant throws instead
// of silently accepting the leak. Once fixed (close OUT_FH on these three
// paths too, matching the others in the same file), replace these
// assert.throws with normal exit-3 checks asserting cleanup.filesClosed.
{ // no TCP peer at all -> ARP resolves but connect never completes
  assert.throws(() => run('WGET', 'http://192.168.7.1/file.txt -y', {
    environment: { ...NET_ENV }, responders: { arp: arpToServer },
  }), /EXIT with unclosed files/);
  count();
}
{ // ARP for the server never answered
  assert.throws(() => run('WGET', 'http://192.168.7.1/file.txt -y', { environment: { ...NET_ENV } }),
    /EXIT with unclosed files/);
  count();
}
{
  const r = run('WGET', '', { environment: { ...NET_ENV } });
  assert.strictEqual(r.exitCode, 1);
  assert.match(r.output, /\[E\] usage: missing or invalid URL/);
  checkCleanupClaimedPage(r);
}
for (const missing of ['NET_IP', 'NET_MAC']) {
  const environment = { ...NET_ENV }; delete environment[missing];
  const r = run('WGET', 'http://192.168.7.1/file.txt -y', { environment });
  assert.strictEqual(r.exitCode, 4);
  checkCleanupClaimedPage(r);
}
{
  const r = run('WGET', 'http://192.168.7.1/file.txt -y', { environment: { ...NET_ENV }, cardPresent: false });
  assert.strictEqual(r.exitCode, 2);
  checkCleanupClaimedPage(r);
}

// ---------------------------------------------------------------------
// DLDIRECT.EXE / DLDIRCP.EXE (byte-identical protocol; DLDIRCP only adds
// an extra memcpy of each segment before parsing, per src/apps/dldircp.asm)
// DLWIN3 changes only the advertised receive window to three MSS.
// ---------------------------------------------------------------------
for (const app of ['DLDIRECT', 'DLDIRCP', 'DLWIN3']) {
  const receiveWindow = app === 'DLWIN3' ? 4380 : 2920;
  // Existing direct BUILD_FIN clears the window low byte. Preserve that
  // unrelated close-path behavior in this receive-window-only experiment.
  const expectedWindow = v => (v.flags & 1) ? (receiveWindow & 0xff00) : receiveWindow;
  {
    const body = Buffer.from(Array.from({ length: 4096 }, (_, i) => i & 255));
    const r = run(app, 'http://192.168.7.1/file.bin', {
      environment: { ...NET_ENV }, responders: { arp: arpToServer, tcp: { body } },
    });
    assert.strictEqual(r.exitCode, 0);
    assert.match(r.output, new RegExp(`${app} v`));
    assert.match(r.output, /Connecting to 192\.168\.7\.1:80/);
    assert.match(r.output, /Received: 4096 bytes/);
    assert.match(r.output, /Integrity: OK/);
    assert.match(r.output, /RESULT OK/);
    const sent = r.transmittedFrames
      .map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
    const syn = sent.find(v => v.flags === 2);
    assert.strictEqual(syn?.mss, 1460, `${app} did not advertise receive MSS 1460`);
    assert.strictEqual(syn?.window, receiveWindow, `${app} SYN receive window`);
    assert.ok(sent.filter(v => v.flags & 0x10).every(v => v.window === expectedWindow(v)),
      `${app} ACK/data/FIN receive window`);
    if (app === 'DLWIN3') assert.match(r.output, /EXPERIMENT RXWIN=4380/);
    const received = r.generatedFrames
      .map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
    assert.ok(received.some(v => v.payload.length === 1460),
      `${app} was not exercised with a full 1460-byte receive segment`);
    count();
  }
  for (const afterMs of [1, 100]) { // Full-window bursts on fast and delayed paths.
    const body = Buffer.alloc(64 * 1024, 0x5a);
    const r = run(app, 'http://192.168.7.1/file.bin', {
      environment: { ...NET_ENV },
      responders: { arp: arpToServer, tcp: { body, streamAhead: true, afterMs } },
    });
    assert.strictEqual(r.exitCode, 0, r.output);
    assert.match(r.output, /Received: 65536 bytes/);
    assert.match(r.output, /RESULT OK/);
    const sent = r.transmittedFrames
      .map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
    assert.ok(sent.every(v => v.window === expectedWindow(v)), `${app} bulk receive window`);
    const received = r.generatedFrames
      .map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
    assert.ok(received.filter(v => v.payload.length === 1460).length > 40);
    assert.strictEqual(r.card.stats.overflowEvents, 0, `${app} RX overflow at ${afterMs} ms`);
    checkCleanupClaimedPage(r);
  }
  if (app === 'DLWIN3') {
    const r = run(app, '/?', { environment: { ...NET_ENV } });
    assert.strictEqual(r.exitCode, 0);
    assert.match(r.output, /Usage: DLWIN3\.EXE/);
    assert.strictEqual(r.transmittedFrames.length, 0);
    checkCleanupClaimedPage(r);
  }
  { // HTTP/1.1 request includes a non-default port in the Host header
    // (unlike WGET, which never appends the port to Host at all).
    const r = run(app, 'http://192.168.7.1:8080/file.bin', {
      environment: { ...NET_ENV },
      responders: { arp: arpToServer, tcp: { port: 8080, body: 'x' } },
    });
    assert.strictEqual(r.exitCode, 0);
    count();
  }
  {
    // KNOWN BUG (reported upstream, not fixed here): TCP_ERROR_OPEN (this
    // app's shared failure handler for BOTH tcp_lib-level connect/send
    // errors and dlspeed_http.asm/DHTTP.CONSUME-level HTTP parse errors)
    // always prints TCP_LAST_FAIL, never the API_STATUS byte it captures
    // one line above (`LD (API_STATUS),A` at dldirect.asm:199) from
    // RECEIVE_BODY's return value. TCP_LAST_FAIL is F_NONE(0) whenever
    // OPEN/SEND actually succeeded and the failure is purely an HTTP
    // parse error, so every DHTTP_ERR_* (missing Content-Length=2,
    // rejected Transfer-Encoding=4, bad status=1, ...) is misreported as
    // "TCP/HTTP error #00" regardless of the real cause. Confirmed for
    // both the missing-Content-Length and non-2xx-status cases below;
    // API_STATUS is otherwise unused dead state. Once fixed (print
    // API_STATUS here instead of/alongside TCP_LAST_FAIL), update these
    // two regexes to the real DHTTP_ERR_LENGTH_MISSING(2)/STATUS(1) codes.
    const r = run(app, 'http://192.168.7.1/file.bin', {
      environment: { ...NET_ENV },
      responders: { arp: arpToServer, tcp: { body: 'x', omitContentLength: true } },
    });
    assert.strictEqual(r.exitCode, 3);
    assert.match(r.output, /TCP\/HTTP error #00/);
    count();
  }
  { // non-2xx status is rejected outright (no redirect-following at all)
    const r = run(app, 'http://192.168.7.1/file.bin', {
      environment: { ...NET_ENV }, responders: { arp: arpToServer, tcp: { status: 404, body: 'nope' } },
    });
    assert.strictEqual(r.exitCode, 3);
    assert.match(r.output, /TCP\/HTTP error #00/); // see KNOWN BUG comment above
    count();
  }
  {
    const r = run(app, 'http://192.168.7.1/file.bin', { environment: { ...NET_ENV } });
    assert.strictEqual(r.exitCode, 3);
    count();
  }
  {
    const r = run(app, '', { environment: { ...NET_ENV } });
    assert.strictEqual(r.exitCode, 1);
    count();
  }
  {
    const r = run(app, 'http://192.168.7.1/file.bin', { environment: { ...NET_ENV }, cardPresent: false });
    assert.strictEqual(r.exitCode, 2);
    count();
  }
}

// ---------------------------------------------------------------------
// DLOOO3.EXE -- the 4380-byte DLWIN3 experiment plus exactly two durable
// out-of-order slots.  These vectors use a response body whose bytes are
// deliberately non-repeating; a mere Content-Length success cannot hide a
// reordered/corrupted parser input in the responder trace.
// ---------------------------------------------------------------------
for (const order of [[1, 2, 0], [2, 1, 0]]) {
  const body = Buffer.from(Array.from({ length: 3 * 1460 + 311 }, (_, i) => (i * 37 + 11) & 255));
  const tcp = { body, streamAhead: true, oooOrder: order, afterMs: 1 };
  const parserBytes = [];
  const r = run('DLOOO3', 'http://192.168.7.1/file.bin', {
    environment: { ...NET_ENV }, responders: { arp: arpToServer, tcp },
    // RECEIVE_BODY's CALL DHTTP.CONSUME in the large DLDIRECT layout.
    // Capture the actual HL/BC slices supplied to the parser, not merely
    // its final Content-Length result, so a duplicate/skip/reorder cannot
    // pass this vector accidentally.
    cpuProbes: { 0x4448: ({ state, read }) => {
      const ptr = (state.h << 8) | state.l;
      const len = (state.b << 8) | state.c;
      parserBytes.push(Buffer.from(Array.from({ length: len }, (_, i) => read((ptr + i) & 0xffff))));
    } },
  });
  assert.strictEqual(r.exitCode, 0, r.output);
  assert.match(r.output, /DLOOO3 v.*RXWIN=4380 OOO=2/);
  assert.match(r.output, /OOO saved=2 delivered=2 nospace=0 max=2/);
  assert.match(r.output, /ovw=[0-9]+ txfail=[0-9]+/);
  assert.match(r.output, new RegExp(`Received: ${body.length} bytes`));
  assert.match(r.output, /Integrity: OK/);
  assert.deepStrictEqual(Buffer.concat(parserBytes), buildHttpResponse(tcp),
    'HTTP parser did not receive the exact reordered response byte stream');
  const sent = r.transmittedFrames.map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
  const syn = sent.find(v => v.flags === 2);
  assert.strictEqual(syn?.mss, 1460);
  assert.strictEqual(syn?.window, 4380);
  // Before the missing first segment arrives every ACK stays at its old
  // cumulative point; no ACK may claim either saved segment prematurely.
  const dataAcks = sent.filter(v => (v.flags & 0x10) && !(v.flags & 2));
  const initialAck = 0x12345679; // harness responder's server ISN + SYN
  assert.ok(dataAcks.filter(v => v.ack === initialAck).length >= 2,
    'saved segments must produce duplicate ACKs at the hole, not ACK through it');
  assert.ok(r.generatedFrames.length >= 4, 'expected a three-segment reordered flight');
  checkCleanupClaimedPage(r);
  count();
}
{ // Queue-full path: after a hole, a third ahead segment must be ACKed but not copied.
  const body = Buffer.alloc(5 * 1460 + 17, 0x6d);
  const r = run('DLOOO3', 'http://192.168.7.1/file.bin', {
    environment: { ...NET_ENV },
    responders: { arp: arpToServer, tcp: { body, streamAhead: true, oooOrder: [1, 2, 0], maxBurst: 4, afterMs: 1 } },
  });
  assert.strictEqual(r.exitCode, 0, r.output);
  assert.match(r.output, /OOO saved=2 delivered=2 nospace=[0-9]+ max=2/);
  checkCleanupClaimedPage(r);
  count();
}

// ---------------------------------------------------------------------
// DLTUNE.EXE -- runtime window/ACK experiment.  The parser accepts flags
// on either side of the URL, while malformed/repeated options fail before
// the NIC is touched.
// ---------------------------------------------------------------------
function checkTuneWindows(sent, wmax) {
  const acks = sent.filter(v => (v.flags & 0x10) && !(v.flags & 2));
  assert.ok(acks.length > 4, 'DLTUNE bulk vector did not exercise window growth');
  let previousAck = acks[0].ack >>> 0;
  let edge = (previousAck + 4380) >>> 0;
  for (const seg of acks) {
    const ack = seg.ack >>> 0;
    const advance = (ack - previousAck) >>> 0;
    if (advance && advance < 0x80000000) {
      const stepEdge = (edge + 2920) >>> 0;
      const limitEdge = (ack + wmax) >>> 0;
      const stepFromEdge = (stepEdge - edge) >>> 0;
      const limitFromEdge = (limitEdge - edge) >>> 0;
      if (limitFromEdge < 0x80000000)
        edge = (edge + Math.min(stepFromEdge, limitFromEdge)) >>> 0;
      previousAck = ack;
    }
    assert.strictEqual(seg.window, (edge - ack) >>> 0,
      `wrong DLTUNE edge at ACK ${ack.toString(16)}`);
    assert.ok(seg.window <= wmax, `window exceeded max: ${seg.window}`);
  }
}

for (const w of [3, 6, 9]) for (const a of [1, 2]) for (const afterMs of [1, 100]) {
  const body = Buffer.alloc(64 * 1024, 0x74);
  const r = run('DLTUNE', `http://192.168.7.1/file.bin -a ${a} -w ${w}`, {
    environment: { ...NET_ENV },
    responders: { arp: arpToServer, tcp: { body, streamAhead: true, afterMs } },
  });
  assert.strictEqual(r.exitCode, 0, r.output);
  assert.match(r.output, new RegExp(`RXWIN_MAX=${w * 1460} ACK=${a} OOO=2 EDGE_STEP=2920`));
  assert.match(r.output, /Received: 65536 bytes/);
  const sent = r.transmittedFrames.map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
  assert.strictEqual(sent.find(v => v.flags === 2)?.window, 4380);
  checkTuneWindows(sent, w * 1460);
  if (w === 3)
    assert.strictEqual(r.card.stats.overflowEvents, 0,
      `DLTUNE -w ${w} -a ${a} RX overflow at ${afterMs} ms`);
  count();
}
{ // The advertised right edge and its comparisons stay correct across wrap.
  const body = Buffer.alloc(16 * 1024, 0x77);
  const r = run('DLTUNE', 'http://192.168.7.1/file.bin -a 2 -w 9', {
    environment: { ...NET_ENV },
    responders: { arp: arpToServer, tcp: { body, streamAhead: true, afterMs: 1, isn: 0xfffff000 } },
  });
  assert.strictEqual(r.exitCode, 0, r.output);
  assert.match(r.output, /Received: 16384 bytes/);
  const sent = r.transmittedFrames.map(f => parseTcpSegment(Buffer.from(f, 'hex'))).filter(Boolean);
  checkTuneWindows(sent, 9 * 1460);
  assert.ok(sent.some(v => v.ack < 0x1000), 'DLTUNE wrap vector did not cross sequence zero');
  count();
}
{ // Once -w 6 has grown beyond 4380, a valid far-ahead segment must use
  // the advertised edge rather than DLOOO3's fixed three-MSS limit.  Keep
  // the remainder of the original flight delayed so the injected segment
  // arrives with an end offset of 5840 from the current RCV_NXT.
  const body = Buffer.alloc(64 * 1024, 0x78);
  const r = run('DLTUNE', 'http://192.168.7.1/file.bin -a 1 -w 6', {
    environment: { ...NET_ENV },
    responders: { arp: arpToServer, tcp: {
      body, streamAhead: true, afterMs: 1, segmentGapMs: 100, maxBurst: 4,
      oooAfterOffset: 1460, oooOrder: [1, 0],
    } },
  });
  assert.strictEqual(r.exitCode, 0, r.output);
  assert.match(r.output, /Received: 65536 bytes/);
  assert.match(r.output, /OOO saved=[1-9][0-9]* delivered=[1-9][0-9]*/);
  assert.match(r.output, /oowin=0/);
  assert.match(r.output, /ovw=[0-9]+ txfail=[0-9]+/);
  assert.match(r.output, /Integrity: OK/);
  count();
}
{ // Exercise the high byte of every OOO event counter.  The old increment
  // helper pinned DELIVERED at 255 and advanced the other u16 counters by
  // 256 whenever their low byte wrapped.
  const body = Buffer.alloc(2 * 1024 * 1024, 0x79);
  const r = run('DLTUNE', 'http://192.168.7.1/file.bin -a 1 -w 3', {
    maxInstructions: 750000000,
    environment: { ...NET_ENV },
    responders: { arp: arpToServer, tcp: {
      body, streamAhead: true, afterMs: 1, maxBurst: 2,
      oooOrder: [1, 0], oooRepeat: true,
    } },
  });
  assert.strictEqual(r.exitCode, 0, r.output);
  assert.match(r.output, /Received: 2097152 bytes/);
  const counters = r.output.match(/OOO saved=([0-9]+) delivered=([0-9]+)/);
  assert.ok(counters, 'missing DLTUNE OOO counters');
  assert.ok(Number(counters[1]) > 255, `saved counter did not cross 255: ${counters[1]}`);
  assert.strictEqual(counters[2], counters[1], 'queued segments were not delivered exactly once');
  assert.match(r.output, /Integrity: OK/);
  count();
}
for (const args of [
  '-w 4 http://192.168.7.1/file.bin',
  '-a 3 http://192.168.7.1/file.bin',
  '-w 3 -w 6 http://192.168.7.1/file.bin',
  '-a 1 -a 2 http://192.168.7.1/file.bin',
]) {
  const r = run('DLTUNE', args, { environment: { ...NET_ENV } });
  assert.strictEqual(r.exitCode, 1);
  assert.match(r.output, /Usage: DLTUNE/);
  count();
}

// ---------------------------------------------------------------------
// DLSPEED.EXE (loads UNETRTL.DLL via libman13.asm)
// ---------------------------------------------------------------------
const dllBytes = fs.readFileSync(exe('UNETRTL').replace(/\.EXE$/, '.DLL'));
const dllScenario = (extra = {}) => ({
  environment: { ...NET_ENV, NET_RTL_HW: '1/#300', NET: 'RTL' },
  appDir: 'C:\\NET',
  files: { 'C:\\NET\\UNETRTL.DLL': dllBytes },
  ...extra,
});
{
  // Full download through the DLL: NETINIT, CONNECT, HTTP GET, RECV,
  // CLOSE. (Regression guard for the CHECK_ASYNC_PEND A-clobber that
  // once made every CONNECT/CLOSE/UDPOPEN/LISTEN/UNLISTEN fail with
  // NERR_PARAM: the helper returned with A=0xFF -- APEND_CH's idle
  // sentinel -- instead of the caller's channel argument, and the
  // CHECK_CHANNEL right after it read that A as the channel number.
  // It now preserves A across the check.)
  const r = run('DLSPEED', 'http://192.168.7.1/file.bin', dllScenario({
    responders: { arp: arpToServer, tcp: { body: '0123456789' } },
  }));
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Received: 10 bytes/);
  assert.match(r.output, /Integrity: OK/);
  assert.match(r.output, /RESULT OK/);
  assert.ok(r.cleanup.isaClosed && r.cleanup.filesClosed);
  count();
}
{ // NETINIT alone succeeds without any responder wired up
  const r = run('DLSPEED', 'http://192.168.7.1/file.bin', dllScenario());
  assert.match(r.output, /Loading UNETRTL\.DLL/);
  assert.doesNotMatch(r.output, /NETINIT failed/);
  assert.doesNotMatch(r.output, /Network not configured/);
  count();
}
{ // NETINIT correctly reports NERR_NONET when NET_RTL_HW is absent
  const r = run('DLSPEED', 'http://192.168.7.1/file.bin', dllScenario({
    environment: { ...NET_ENV, NET: 'RTL' }, // no NET_RTL_HW
  }));
  assert.strictEqual(r.exitCode, 4);
  assert.match(r.output, /Network error #2/); // NERR_NONET
  count();
}
{ // missing DLL file
  const r = run('DLSPEED', 'http://192.168.7.1/file.bin', {
    environment: { ...NET_ENV, NET_RTL_HW: '1/#300', NET: 'RTL' }, appDir: 'C:\\NET',
  });
  assert.strictEqual(r.exitCode, 2);
  assert.match(r.output, /Could not load UNETRTL\.DLL\./);
  count();
}
{
  const r = run('DLSPEED', '', dllScenario());
  assert.strictEqual(r.exitCode, 1);
  count();
}

console.log(`Actual DSS EXE TCP harness: ${caseCount()} WGET/DLDIRECT/DLDIRCP/DLWIN3/DLOOO3/DLTUNE/DLSPEED checks passed`);
