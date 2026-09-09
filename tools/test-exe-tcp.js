#!/usr/bin/env node
// Phase 3 actual-EXE integration vectors: TCP client utilities (WGET,
// DLDIRECT, DLDIRCP) plus a DLSPEED smoke test through UNETRTL.DLL.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { runExe } = require('./exe-harness/harness.js');
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
// ---------------------------------------------------------------------
for (const app of ['DLDIRECT', 'DLDIRCP']) {
  {
    const r = run(app, 'http://192.168.7.1/file.bin', {
      environment: { ...NET_ENV }, responders: { arp: arpToServer, tcp: { body: '0123456789' } },
    });
    assert.strictEqual(r.exitCode, 0);
    assert.match(r.output, new RegExp(`${app} v`));
    assert.match(r.output, /Connecting to 192\.168\.7\.1:80/);
    assert.match(r.output, /Received: 10 bytes/);
    assert.match(r.output, /Integrity: OK/);
    assert.match(r.output, /RESULT OK/);
    count();
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

console.log(`Actual DSS EXE TCP harness: ${caseCount()} WGET/DLDIRECT/DLDIRCP/DLSPEED checks passed`);
