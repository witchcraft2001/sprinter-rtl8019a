#!/usr/bin/env node
// Actual-EXE integration vectors for FTP.EXE.
//
// FTP is the only utility that runs TWO concurrent TCP sessions through one
// set of TCP state variables (SAVE_CTX/RESTORE_CTX), and the only one whose
// main path interleaves chip access with console output on every server
// reply. It had no coverage at all, which is how five ISA-discipline
// violations (DSS console/clock calls made with the ISA window mapped over
// 0xC000-0xFFFF) survived on the download path -- the failure mode they
// produce in MAME and on hardware is a transfer that freezes part-way.
//
// The scenarios below drive a real passive-mode FTP server model and, in
// the bulk-download vector, make the disk write cost wire time so the peer
// really does stream into the advertised window while the client is away
// flushing -- the condition under which the transfer used to die.
// PUT is covered with a file larger than one application buffer so an upload
// cannot silently overwrite the fixed library BSS at 0xA000.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const path = require('path');
const { runExe } = require('./exe-harness/harness.js');
const { parseTcpSegment } = require('./exe-harness/net-builders.js');
const { count, caseCount, checkCleanupClaimedPage } = require('./exe-harness/test-util.js');

const root = path.resolve(__dirname, '..');
const exe = (name) => path.join(root, 'build', `${name}.EXE`);
const run = (args, scenario = {}) => runExe(exe('FTP'), args, scenario);

const NET_ENV = { NET_IP: '192.168.7.2', NET_MAC: '02:80:19:11:22:33' };
const arpToServer = { mac: [2, 0, 0, 0, 0, 1] };

// Deterministic printable payload: the harness carries FTP bodies as
// latin1 strings, so keeping every byte in 0x20..0x7d makes the round trip
// through the responder exact and any mismatch a real defect.
const payload = (n) => {
  const b = Buffer.alloc(n);
  for (let i = 0; i < n; i++) b[i] = 32 + ((i * 7 + (i >> 8)) % 94);
  return b;
};

const MODLAND_GREETING = [
  '220-      __  ___               __ __                      __',
  '220-    //  \\/   \\             |  |  |  .: welcome to :.  |  |',
  '220-   |          |  _____   __|  |  |  _____   _____   __|  |',
  '220-..:|          |// ,   |// ,   |  |// ,   |//     |// ,   |:..',
  '220-   |___,__,__/|______/|______/|__|____,__|____,__|______/',
  '220-',
  '220-Welcome to Modland - probably the largest module archive in the world.',
  '220-Currently there are 516118 modules online in 409 different formats,',
  '220-old and new! If you are a module freak like us, feel free to download!',
  '220-If you have no idea what a module is, then you are in the wrong place!',
  '220-',
  '220-If you find any duplicates or other errors, or you have something to',
  '220-add to the collection, or just a question - join our Discord at:',
  '220-https://discord.com/invite/AJ2xV8X',
  '220-',
  '220-Modland is administered by Menace and Ziphoid.',
  '220-For anything else, get in touch at admins@modland.com.',
  '220 Only anonymous FTP is allowed here',
].join('\r\n');

{ // ftp.modland.com sends its whole >512-byte multiline greeting in one
  // TCP segment. FTP must retain the final "220 " line instead of ACKing
  // and silently dropping the tail beyond its reply accumulator.
  const file = payload(64);
  const r = run('192.168.7.1 ALLMODS -y', {
    environment: { ...NET_ENV },
    responders: { arp: arpToServer, ftp: { file, greeting: MODLAND_GREETING } },
  });
  assert.strictEqual(r.exitCode, 0, 'long multiline FTP greeting must be parsed');
  assert.match(r.output, /220 Only anonymous FTP is allowed here/);
  assert.match(r.output, /RESULT OK/);
  checkCleanupClaimedPage(r);
}

{ // Small download: the whole control dialogue plus a one-flush transfer.
  const file = payload(4096);
  const r = run('192.168.7.1 SMALL.BIN -y', {
    environment: { ...NET_ENV },
    responders: { arp: arpToServer, ftp: { file } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /220 harness FTP server ready\./);
  assert.match(r.output, /230 Guest login ok/);
  assert.match(r.output, /227 Entering Passive Mode/);
  assert.match(r.output, /226 Transfer complete\./);
  assert.match(r.output, /Done\. 4096 bytes received\./);
  assert.match(r.output, /RESULT OK/);
  const data = r.files['C:\\NET\\SMALL.BIN'] || r.files['C:\\SMALL.BIN'];
  assert.ok(data, 'expected the downloaded file to exist');
  assert.ok(Buffer.from(data.data || data).equals(file), 'downloaded file must be byte-identical');
  checkCleanupClaimedPage(r);
}

{ // The field case: a 380 KB file (the im2.txt of the bug reports) with
  // disk writes that cost real wire time, so the server streams into the
  // window across every flush. This is the vector that reproduced the
  // "freezes at 7KB / 34KB" hang; it must run to completion and the file
  // must match exactly, with no RX-ring overflow left unrecovered.
  const file = payload(389579);
  const r = run('192.168.7.1 IM2.TXT -y', {
    environment: { ...NET_ENV },
    diskWriteMs: 30,
    stepLimit: 900_000_000,
    responders: { arp: arpToServer, ftp: { file } },
  });
  assert.strictEqual(r.exitCode, 0, 'bulk download must not stall');
  assert.match(r.output, /Done\. 389579 bytes received\./);
  assert.match(r.output, /RESULT OK/);
  const data = r.files['C:\\NET\\IM2.TXT'] || r.files['C:\\IM2.TXT'];
  assert.ok(Buffer.from(data.data || data).equals(file),
    'a 380 KB download must arrive byte-identical');
  checkCleanupClaimedPage(r);
}

{ // Same transfer with the dot-progress switch: -d takes a different
  // console path (PUTCHAR per flush instead of the repainted counter),
  // which is its own opportunity to print through an open ISA window.
  const file = payload(65536);
  const r = run('192.168.7.1 DOTS.BIN -y -d', {
    environment: { ...NET_ENV }, diskWriteMs: 20, stepLimit: 900_000_000,
    responders: { arp: arpToServer, ftp: { file } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Done\. 65536 bytes received\./);
  const data = r.files['C:\\NET\\DOTS.BIN'] || r.files['C:\\DOTS.BIN'];
  assert.ok(Buffer.from(data.data || data).equals(file));
  checkCleanupClaimedPage(r);
}

{ // -o redirects the local filename.
  const file = payload(1024);
  const r = run('192.168.7.1 REMOTE.BIN -y -o LOCAL.BIN', {
    environment: { ...NET_ENV },
    responders: { arp: arpToServer, ftp: { file } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.ok(r.files['C:\\NET\\LOCAL.BIN'] || r.files['C:\\LOCAL.BIN'],
    'expected -o to choose the local output name');
  checkCleanupClaimedPage(r);
}

{ // PUT crosses multiple file-buffer fills and preserves every source byte.
  // A former 8192-byte buffer started at 0x8054 and ended at 0xA054, so every
  // full read overwrote RTL_BASE_PTR and the first 84 bytes of library state.
  const file = payload(14090);
  const ftp = {};
  const r = run('192.168.7.1 PUT FTP.EXE -o FTP_TEST.EXE', {
    environment: { ...NET_ENV }, files: { 'FTP.EXE': file },
    stepLimit: 900_000_000,
    responders: { arp: arpToServer, ftp },
  });
  assert.strictEqual(r.exitCode, 0, 'multi-block FTP upload must complete');
  assert.match(r.output, /Done\. 14090 bytes sent\./);
  assert.match(r.output, /RESULT OK/);
  assert.ok(ftp.uploads?.['FTP_TEST.EXE'], 'server must receive the STOR target');
  assert.ok(ftp.uploads['FTP_TEST.EXE'].equals(file), 'uploaded file must be byte-identical');
  checkCleanupClaimedPage(r);
}

{ // A non-default control port must be carried through to the SYN.
  const file = payload(512);
  const r = run('192.168.7.1:2121 P.BIN -y', {
    environment: { ...NET_ENV },
    responders: { arp: arpToServer, ftp: { file, port: 2121 } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /RESULT OK/);
  checkCleanupClaimedPage(r);
}

{ // Receive geometry: direct clients advertise MSS 1460 with a
  // two-segment (2920-byte) window. This is a deliberate default and is
  // checked so it cannot drift silently in either direction.
  //
  // MSS was briefly lowered to 536 after a MAME stand lost a segment out
  // of every burst; that was the wrong fix (it halves per-frame
  // efficiency to work around a host-side capture drop, and builds stuck
  // behind such a host define USE_TCP_RX_SMALL instead). The WINDOW,
  // however, was lowered from three segments to two on purpose: three
  // occupied 18 of the ring's 25 usable pages, so one stray broadcast
  // plus an 8 KB disk flush overflowed the ring, and with no out-of-order
  // queue that cost a whole window and stalled the transfer on real
  // hardware (the 2026-09-14 "ovw 0x03" capture). Two segments occupy 12
  // pages, keep MSS 1460 (so throughput is unchanged), and match what the
  // sibling 3C509B kit uses.
  const r = run('192.168.7.1 G.BIN -y', {
    environment: { ...NET_ENV },
    responders: { arp: arpToServer, ftp: { file: payload(64) } },
  });
  assert.strictEqual(r.exitCode, 0);
  const syn = r.transmittedFrames
    .map((f) => parseTcpSegment(Buffer.from(f, 'hex')))
    .filter(Boolean).find((s) => s.flags === 2);
  assert.strictEqual(syn?.mss, 1460, 'FTP must advertise receive MSS 1460');
  assert.strictEqual(syn?.window, 2920, 'FTP must advertise the two-MSS receive window');
  checkCleanupClaimedPage(r);
}

{ // LIST streams the listing straight to the console instead of a file,
  // which is a different console path again (PRINT_DATA_CHUNK) and skips
  // the byte/rate summary.
  const r = run('192.168.7.1 -l', {
    environment: { ...NET_ENV }, stepLimit: 900_000_000,
    responders: { arp: arpToServer, ftp: { file: Buffer.alloc(0) } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /im2\.txt/);
  assert.match(r.output, /226 Transfer complete\./);
  assert.match(r.output, /RESULT OK/);
  checkCleanupClaimedPage(r);
}

{ // Usage and environment failures stay clean (no page/file leaks).
  const r = run('', { environment: { ...NET_ENV } });
  assert.strictEqual(r.exitCode, 1);
  checkCleanupClaimedPage(r);
}
{
  const r = run('192.168.7.1 F.BIN -y', { environment: { ...NET_ENV }, cardPresent: false });
  assert.strictEqual(r.exitCode, 2);
  checkCleanupClaimedPage(r);
}
for (const missing of ['NET_IP', 'NET_MAC']) {
  const environment = { ...NET_ENV }; delete environment[missing];
  const r = run('192.168.7.1 F.BIN -y', { environment });
  assert.strictEqual(r.exitCode, 4);
  checkCleanupClaimedPage(r);
}

count();
console.log(`Actual DSS EXE FTP harness: ${caseCount()} FTP checks passed`);
