#!/usr/bin/env node
// Phase 2 actual-EXE integration vectors: protocol utilities (ARP, PING,
// PINGALT, UDPTEST, NSLOOKUP, NTP, IFUP, NETCFG, TFTP).
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const path = require('path');
const { runExe } = require('./exe-harness/harness.js');
const { count, caseCount, checkCleanup, checkCleanupClaimedPage } = require('./exe-harness/test-util.js');

const root = path.resolve(__dirname, '..');
const exe = (name) => path.join(root, 'build', `${name}.EXE`);
const run = (name, args, scenario = {}) => runExe(exe(name), args, scenario);

const NET_ENV = { NET_IP: '192.168.7.2', NET_MAC: '02:80:19:11:22:33' };

// ---------------------------------------------------------------------
// ARP.EXE
// ---------------------------------------------------------------------
{
  const r = run('ARP', '192.168.7.1', {
    environment: { ...NET_ENV },
    responders: { arp: { mac: [2, 0, 0, 0, 0, 1] } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /ARPING 192\.168\.7\.1 from 192\.168\.7\.2 \(02:80:19:11:22:33\)/);
  // NB: arp.asm has a real BSS overlap bug (REPLY_MAC EQU APP_BSS_BASE+14,
  // 6 bytes, overlaps DEC_BUF EQU APP_BSS_BASE+16, 4 bytes): printing
  // TARGET_IP via PRINT_IPV4 after populating REPLY_MAC clobbers MAC bytes
  // 2-5 before PRINT_MAC reads them. So bytes 0-1 of the printed MAC are
  // reliable; bytes 2-5 are not (reported upstream, not fixed here).
  assert.match(r.output, /Reply from 192\.168\.7\.1: 02:00:/);
  assert.match(r.output, /RESULT OK/);
  checkCleanupClaimedPage(r);
}
{ // no reply -> ARP timeout
  const r = run('ARP', '192.168.7.1', { environment: { ...NET_ENV } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /ARP request timed out\./);
  assert.match(r.output, /RESULT FAIL/);
  checkCleanupClaimedPage(r);
}
{ // dropped reply (arp.drop count) still eventually times out
  const r = run('ARP', '192.168.7.1', {
    environment: { ...NET_ENV },
    responders: { arp: { mode: 'drop' } },
  });
  assert.strictEqual(r.exitCode, 3);
  checkCleanupClaimedPage(r);
}
{ // missing NET_IP -> config error, exit 4
  const r = run('ARP', '192.168.7.1', { environment: { NET_MAC: NET_ENV.NET_MAC } });
  assert.strictEqual(r.exitCode, 4);
  assert.match(r.output, /\[E\] env var NET_IP not set; run NETCFG -i first/);
  checkCleanupClaimedPage(r);
}
{ // missing NET_MAC -> config error, exit 4
  const r = run('ARP', '192.168.7.1', { environment: { NET_IP: NET_ENV.NET_IP } });
  assert.strictEqual(r.exitCode, 4);
  assert.match(r.output, /\[E\] env var NET_MAC not set; run NETCFG -i first/);
  checkCleanupClaimedPage(r);
}
{ // usage error: missing target
  const r = run('ARP', '', { environment: { ...NET_ENV } });
  assert.strictEqual(r.exitCode, 1);
  assert.match(r.output, /\[E\] usage: missing or invalid target IPv4/);
  checkCleanupClaimedPage(r);
}
{ // no NIC
  const r = run('ARP', '192.168.7.1', { environment: { ...NET_ENV }, cardPresent: false });
  assert.strictEqual(r.exitCode, 2);
  checkCleanupClaimedPage(r);
}

// ---------------------------------------------------------------------
// PING.EXE / PINGALT.EXE (wire-identical; PINGALT only differs in banner
// text and NIC packet-RAM TX/RX page layout, per src/apps/pingalt.asm).
// ---------------------------------------------------------------------
for (const app of ['PING', 'PINGALT']) {
  const arpAndIcmp = { arp: { mac: [2, 0, 0, 0, 0, 1] }, icmp: {} };
  {
    const r = run(app, '-n 2 192.168.7.1', { environment: { ...NET_ENV }, responders: arpAndIcmp });
    assert.strictEqual(r.exitCode, 0);
    assert.match(r.output, new RegExp(`RTL8019AS ${app} v`));
    assert.match(r.output, /Pinging 192\.168\.7\.1 with 32 bytes of data:/);
    assert.match(r.output, /Next-hop MAC=02:00:00:00:00:01/);
    // TTL is the REPLY's (the responder sends 63), not our outgoing 64.
    assert.strictEqual((r.output.match(/Reply from 192\.168\.7\.1: bytes=32 time=1ms TTL=63/g) || []).length, 2);
    assert.match(r.output, /Packets: Sent = 2, Received = 2, Lost = 0\./);
    assert.match(r.output, /RESULT OK/);
    checkCleanupClaimedPage(r);
  }
  { // custom payload size and TTL.  -i sets the TTL we TRANSMIT, so that
    // is asserted on the wire; the screen shows the reply's TTL instead,
    // which is the number that tells the user the hop distance.
    const r = run(app, '-n 1 -l 64 -i 32 192.168.7.1', { environment: { ...NET_ENV }, responders: arpAndIcmp });
    assert.strictEqual(r.exitCode, 0);
    const echo = Buffer.from(r.transmittedFrames[1], 'hex');
    assert.strictEqual(echo[14 + 8], 32, '-i must set the outgoing IP TTL');
    assert.match(r.output, /Reply from 192\.168\.7\.1: bytes=64 time=1ms TTL=63/);
    checkCleanupClaimedPage(r);
  }
  { // Round-trip time is MEASURED, not the hardcoded "<1ms" the reply line
    // used to carry: hold the reply back and the printed figure must track
    // the delay.  Two different delays, so a constant cannot pass.
    for (const delay of [25, 120]) {
      const r = run(app, `-n 1 192.168.7.1`, {
        environment: { ...NET_ENV },
        responders: { arp: { mac: [2, 0, 0, 0, 0, 1] }, icmp: { afterMs: delay, ttl: 57 } },
      });
      assert.strictEqual(r.exitCode, 0);
      assert.match(r.output, new RegExp(`bytes=32 time=${delay}ms TTL=57`));
      checkCleanupClaimedPage(r);
    }
    count();
  }
  { // A gateway ARP probe that lands in the 1 s inter-echo gap must be
    // answered inside the gap, BEFORE the next echo goes out.  An idle gap
    // left it in the ring until after echo #2 was sent, so the router
    // dropped that echo's reply while its neighbour check was unanswered
    // (real-hardware loss pattern: rx=1 frame = stale ARP request).
    const r = run(app, '-n 2 192.168.7.1', {
      environment: { ...NET_ENV },
      responders: { arp: { mac: [2, 0, 0, 0, 0, 1] }, icmp: { probeAfterMs: 300 } },
    });
    assert.strictEqual(r.exitCode, 0);
    const kinds = r.transmittedFrames.map((h) => {
      const f = Buffer.from(h, 'hex');
      if (f[12] === 0x08 && f[13] === 0x06) return f[21] === 1 ? 'arp-req' : 'arp-rep';
      return f[23] === 1 && f[34] === 8 ? 'echo' : 'other';
    });
    assert.deepStrictEqual(kinds, ['arp-req', 'echo', 'arp-rep', 'echo'],
      'ARP reply must be sent during the gap, before echo #2');
    const rep = Buffer.from(r.transmittedFrames[2], 'hex');
    assert.strictEqual(rep.subarray(0, 6).toString('hex'), '020000000001');
    assert.strictEqual(rep.subarray(28, 32).toString('hex'), 'c0a80702', 'reply SPA = our IP');
    assert.match(r.output, /Packets: Sent = 2, Received = 2, Lost = 0\./);
    checkCleanupClaimedPage(r);
  }
  { // -b: forces an L2 broadcast destination, unicast IP/ICMP payload unchanged
    const r = run(app, '-b -n 1 192.168.7.1', { environment: { ...NET_ENV }, responders: arpAndIcmp });
    assert.strictEqual(r.exitCode, 0);
    const frame = Buffer.from(r.transmittedFrames[0], 'hex');
    assert.strictEqual(frame.subarray(0, 6).toString('hex'), 'ffffffffffff');
    checkCleanupClaimedPage(r);
  }
  { // -b and -m are mutually exclusive
    const r = run(app, '-b -m 192.168.7.1', { environment: { ...NET_ENV } });
    assert.strictEqual(r.exitCode, 1);
    checkCleanupClaimedPage(r);
  }
  { // ARP for the next hop never answered
    const r = run(app, '192.168.7.1', { environment: { ...NET_ENV } });
    assert.strictEqual(r.exitCode, 3);
    assert.match(r.output, /\[E62\] ARP reply timeout/);
    checkCleanupClaimedPage(r);
  }
  { // The timeout register dump must not take the chip offline.  PING keeps
    // receiving after a lost echo, and SNAPSHOT_REGS used to select pages 1
    // and 2 with STP: an STP->STA restart of the receiver in the middle of a
    // session, which a strict DP8390 clone does not treat as a page switch.
    // Same run with and without the lost echo: the dump adds no stop edges.
    const edges = (drop) => {
      const r = run(app, '-n 2 192.168.7.1', {
        environment: { ...NET_ENV }, responders: { arp: arpAndIcmp.arp, icmp: { drop } },
      });
      assert.match(r.output, new RegExp(`Received = ${2 - drop}, Lost = ${drop}\\.`));
      checkCleanupClaimedPage(r);
      return r.card.stats.stopEdges;
    };
    assert.strictEqual(edges(1), edges(0), 'timeout diagnostics must not write CR.STP');
  }
  { // An ODD -l size is legal and must not hang.  UTIL.CHECKSUM stepped its
    // byte count by two and tested it against zero, so an odd count sailed
    // past zero and the loop ran away through memory -- with the ISA window
    // open, which is how it reached the chip's data port.  RFC 1071 pads the
    // final byte with a zero low half; both checksums must still verify.
    const verify = (bytes) => {
      let sum = 0;
      for (let i = 0; i < bytes.length; i += 2) sum += (bytes[i] << 8) | (bytes[i + 1] || 0);
      while (sum >>> 16) sum = (sum & 0xffff) + (sum >>> 16);
      return sum;
    };
    for (const size of [1, 33, 255]) {
      const r = run(app, `-n 1 -l ${size} 192.168.7.1`, {
        environment: { ...NET_ENV }, responders: arpAndIcmp,
      });
      assert.strictEqual(r.exitCode, 0, `-l ${size}`);
      assert.match(r.output, new RegExp(`bytes=${size} `));
      const frame = Buffer.from(r.transmittedFrames[1], 'hex');
      // Frames below the 60-byte Ethernet minimum are padded by SEND_FRAME.
      assert.strictEqual(frame.length, Math.max(60, 42 + size), `-l ${size} frame length`);
      assert.strictEqual(verify(frame.subarray(14, 34)), 0xffff, `-l ${size} IP checksum`);
      assert.strictEqual(verify(frame.subarray(34, 42 + size)), 0xffff, `-l ${size} ICMP checksum`);
      checkCleanupClaimedPage(r);
    }
    count();
  }
  { // Page 3 (CONFIG0/CONFIG3) exists only on a Realtek.  On a clone the
    // TX path must not select or read it, and the timeout dump must say so
    // instead of printing page-1 MAC bytes as a medium/duplex setting.
    const clone = run(app, '-n 1 192.168.7.1', {
      quirks: { variant: 'UM9003' },
      environment: { ...NET_ENV, NET_RTL_HW: '1/#300' },
      responders: { arp: arpAndIcmp.arp },
    });
    assert.strictEqual(clone.exitCode, 3);
    // TPSR still comes from page 2, which every DP8390 has (PINGALT's
    // alternate packet-RAM layout puts it at 46 rather than 40).
    assert.match(clone.output, /PHY n\/a \(no page 3\) NCR=[0-9A-F]{2} TPSR=4[06]/);
    assert.strictEqual(clone.card.stats.page3Reads, 0, 'no page-3 read on a clone');
    checkCleanupClaimedPage(clone);

    const realtek = run(app, '-n 1 192.168.7.1', {
      environment: { ...NET_ENV }, responders: { arp: arpAndIcmp.arp },
    });
    assert.strictEqual(realtek.exitCode, 3);
    assert.match(realtek.output, /PHY C0=[0-9A-F]{2}>[0-9A-F]{2} C3=/);
    assert.ok(realtek.card.stats.page3Reads > 0, 'a genuine Realtek still gets the PHY capture');
    checkCleanupClaimedPage(realtek);
  }
  { // ARP resolves but no ICMP echo reply ever arrives
    const r = run(app, '-n 1 192.168.7.1', { environment: { ...NET_ENV }, responders: { arp: arpAndIcmp.arp } });
    assert.strictEqual(r.exitCode, 3);
    assert.match(r.output, /Packets: Sent = 1, Received = 0, Lost = 1\./);
    assert.match(r.output, /RESULT FAIL/);
    checkCleanupClaimedPage(r);
  }
  for (const missing of ['NET_IP', 'NET_MAC']) {
    const environment = { ...NET_ENV }; delete environment[missing];
    const r = run(app, '192.168.7.1', { environment });
    assert.strictEqual(r.exitCode, 4);
    assert.match(r.output, new RegExp(`\\[E\\] env var ${missing} not set; run NETCFG -i first`));
    checkCleanupClaimedPage(r);
  }
  { // usage error: missing target
    const r = run(app, '', { environment: { ...NET_ENV } });
    assert.strictEqual(r.exitCode, 1);
    checkCleanupClaimedPage(r);
  }
  { // no NIC
    const r = run(app, '192.168.7.1', { environment: { ...NET_ENV }, cardPresent: false });
    assert.strictEqual(r.exitCode, 2);
    checkCleanupClaimedPage(r);
  }
  { // hostname target requires NET_DNS1
    const r = run(app, 'host.example', { environment: { ...NET_ENV } });
    assert.strictEqual(r.exitCode, 4);
    assert.match(r.output, /NET_DNS1 not set/);
    checkCleanupClaimedPage(r);
  }
}
{ // PINGALT prints its extra alternate-layout diagnostic line
  const r = run('PINGALT', '-n 1 192.168.7.1', {
    environment: { ...NET_ENV }, responders: { arp: { mac: [2, 0, 0, 0, 0, 1] }, icmp: {} },
  });
  assert.match(r.output, /\[D\] TX=46 RX=4C\.\.5F \(alternate packet RAM layout\)/);
  checkCleanupClaimedPage(r);
}

// ---------------------------------------------------------------------
// Driver hardening against missed ISA bus cycles (NICREG measured them on
// real cards with frames on the wire).  Each scenario broke the driver
// before: a lost page switch left the RX poll on page 1 or sent WAIT_PTX's
// ISR write into page 3's TEST register; a stray in-range CURR or BNRY
// read sent READ_PACKET into stale ring pages (hang, DMA outside the
// ring); a lost TPSR write at init transmitted the wrong page for good.
// ---------------------------------------------------------------------
{
  const pingEnv = { environment: { ...NET_ENV }, responders: { arp: { mac: [2, 0, 0, 0, 0, 1] }, icmp: {} } };
  for (const everyN of [13, 31]) { // lost page selects: read back and repeated
    const r = run('PING', '-n 6 192.168.7.1', {
      ...pingEnv, quirks: { regWriteDrop: { target: 'cr', everyN, runningOnly: true, pageSwitchOnly: true } },
    });
    assert.strictEqual(r.exitCode, 0, `page-select drop every ${everyN}`);
    assert.match(r.output, /Received = 6, Lost = 0\./);
    assert.ok(r.card.stats.droppedWrites > 100, 'the driver must keep switching pages after a drop');
    assert.strictEqual(r.card.par, '028019112233');
    checkCleanupClaimedPage(r);
  }
  // Misreads on a ring that has wrapped, so stale frames sit past CURR.
  for (const glitch of [{ page: 1, offset: 0x07, everyN: 7, xor: 0x01 },   // CURR
    { page: 1, offset: 0x07, everyN: 5, xor: 0x03 },
    { page: 0, offset: 0x03, everyN: 3, xor: 0x01 }]) {                    // BNRY
    const r = run('PING', '-n 40 -l 200 192.168.7.1', { ...pingEnv, quirks: { regReadGlitch: glitch } });
    assert.strictEqual(r.exitCode, 0, JSON.stringify(glitch));
    assert.match(r.output, /Received = 40, Lost = 0\./);
    assert.strictEqual(r.card.stats.oobDma, 0, 'no remote DMA outside the ring');
    checkCleanupClaimedPage(r);
  }
  { // the init TPSR write is lost; the per-frame write repairs it
    const r = run('PING', '-n 2 192.168.7.1', {
      ...pingEnv, quirks: { regWriteDrop: { target: 'reg', offset: 0x04, value: 0x40, everyN: 1, limit: 1 } },
    });
    assert.strictEqual(r.card.stats.droppedWrites, 1);
    assert.strictEqual(r.exitCode, 0);
    assert.match(r.output, /Received = 2, Lost = 0\./);
    checkCleanupClaimedPage(r);
  }
}

// ---------------------------------------------------------------------
// UDPTEST.EXE
// ---------------------------------------------------------------------
{
  const r = run('UDPTEST', '192.168.7.1 7777', {
    environment: { ...NET_ENV },
    responders: { arp: { mac: [2, 0, 0, 0, 0, 1] }, udp: { payload: [1, 2, 3, 4] } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Sending UDP to 192\.168\.7\.1:7777 from 192\.168\.7\.2/);
  assert.match(r.output, /Reply: len=4 data=/);
  assert.match(r.output, /RESULT OK/);
  checkCleanupClaimedPage(r);
}
{ // the request's own 16-byte fixed payload, verbatim
  const r = run('UDPTEST', '192.168.7.1 7777', {
    environment: { ...NET_ENV },
    responders: { arp: { mac: [2, 0, 0, 0, 0, 1] }, udp: {} }, // udp.payload unset -> echoes request payload
  });
  assert.strictEqual(r.exitCode, 0);
  const sent = Buffer.from(r.transmittedFrames[1], 'hex');
  assert.strictEqual(sent.subarray(42, 42 + 16).toString('ascii'), 'SPRINTER UDPTEST');
  checkCleanupClaimedPage(r);
}
{ // no reply -> UDP timeout
  const r = run('UDPTEST', '192.168.7.1 7777', {
    environment: { ...NET_ENV }, responders: { arp: { mac: [2, 0, 0, 0, 0, 1] } },
  });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /UDP reply timed out\./);
  checkCleanupClaimedPage(r);
}
{ // port 0 is a usage error
  const r = run('UDPTEST', '192.168.7.1 0', { environment: { ...NET_ENV } });
  assert.strictEqual(r.exitCode, 1);
  assert.match(r.output, /\[E\] usage: missing or invalid arguments/);
  checkCleanupClaimedPage(r);
}
for (const missing of ['NET_IP', 'NET_MAC']) {
  const environment = { ...NET_ENV }; delete environment[missing];
  const r = run('UDPTEST', '192.168.7.1 7777', { environment });
  assert.strictEqual(r.exitCode, 4);
  assert.match(r.output, new RegExp(`\\[E\\] env var ${missing} not set; run NETCFG -i first`));
  checkCleanupClaimedPage(r);
}
{
  const r = run('UDPTEST', '192.168.7.1 7777', { environment: { ...NET_ENV }, cardPresent: false });
  assert.strictEqual(r.exitCode, 2);
  checkCleanupClaimedPage(r);
}

// ---------------------------------------------------------------------
// NSLOOKUP.EXE
// ---------------------------------------------------------------------
const NET_ENV_DNS = { ...NET_ENV, NET_DNS1: '192.168.7.1' };
const arpToDns = { mac: [2, 0, 0, 0, 0, 1] };
{
  const r = run('NSLOOKUP', 'example.com', {
    environment: { ...NET_ENV_DNS },
    responders: { arp: arpToDns, dns: { ip: [93, 184, 216, 34] } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Querying example\.com at 192\.168\.7\.1 from 192\.168\.7\.2/);
  assert.match(r.output, /Name:    example\.com/);
  assert.match(r.output, /Address: 93\.184\.216\.34/);
  assert.match(r.output, /RESULT OK/);
  checkCleanupClaimedPage(r);
}
{ // an explicit server-ip positional overrides NET_DNS1
  const r = run('NSLOOKUP', 'example.com 192.168.7.9', {
    environment: { ...NET_ENV }, // NET_DNS1 deliberately absent
    responders: { arp: arpToDns, dns: { ip: [1, 2, 3, 4] } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Querying example\.com at 192\.168\.7\.9/);
  assert.match(r.output, /Address: 1\.2\.3\.4/);
  checkCleanupClaimedPage(r);
}
{ // NXDOMAIN: nslookup.asm cannot distinguish RCODE values in its message
  const r = run('NSLOOKUP', 'nosuch.example', {
    environment: { ...NET_ENV_DNS }, responders: { arp: arpToDns, dns: { nxdomain: true } },
  });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /DNS reply: NXDOMAIN, no A record, or parse error\./);
  checkCleanupClaimedPage(r);
}
{ // no DNS reply at all
  const r = run('NSLOOKUP', 'example.com', {
    environment: { ...NET_ENV_DNS }, responders: { arp: arpToDns },
  });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /DNS reply timed out\./);
  checkCleanupClaimedPage(r);
}
{ // ARP for the DNS server itself never answered
  const r = run('NSLOOKUP', 'example.com', { environment: { ...NET_ENV_DNS } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /ARP request timed out\./);
  checkCleanupClaimedPage(r);
}
{ // no server-ip arg and no NET_DNS1 -> config error
  const r = run('NSLOOKUP', 'example.com', { environment: { ...NET_ENV } });
  assert.strictEqual(r.exitCode, 4);
  assert.match(r.output, /NET_DNS1 not set; pass server-ip arg or run NETCFG -i first/);
  checkCleanupClaimedPage(r);
}
{ // empty hostname -> usage error
  const r = run('NSLOOKUP', '', { environment: { ...NET_ENV_DNS } });
  assert.strictEqual(r.exitCode, 1);
  checkCleanupClaimedPage(r);
}
{
  const r = run('NSLOOKUP', 'example.com', { environment: { ...NET_ENV_DNS }, cardPresent: false });
  assert.strictEqual(r.exitCode, 2);
  checkCleanupClaimedPage(r);
}

// ---------------------------------------------------------------------
// NTP.EXE
// ---------------------------------------------------------------------
{
  const r = run('NTP', '192.168.7.1', {
    environment: { ...NET_ENV },
    responders: { arp: arpToDns, ntp: { unixSeconds: 1700000000, stratum: 2 } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Querying NTP at 192\.168\.7\.1 from 192\.168\.7\.2/);
  assert.match(r.output, /Reply: stratum=2/);
  assert.match(r.output, /UTC time:   2023-11-14 22:13:20/);
  assert.match(r.output, /Local time: 2023-11-14 22:13:20 \(TZ \+0\)/);
  assert.match(r.output, /RESULT OK/);
  checkCleanupClaimedPage(r);
}
{ // NET_TZ applies a signed hour offset to the locally-displayed time only
  const r = run('NTP', '192.168.7.1', {
    environment: { ...NET_ENV, NET_TZ: '-5' },
    responders: { arp: arpToDns, ntp: { unixSeconds: 1700000000 } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /UTC time:   2023-11-14 22:13:20/);
  assert.match(r.output, /Local time: 2023-11-14 17:13:20 \(TZ -5\)/);
  checkCleanupClaimedPage(r);
}
{ // NET_TZ minute offset rolls the local date/time forward past midnight
  const r = run('NTP', '192.168.7.1', {
    environment: { ...NET_ENV, NET_TZ: '+5:30' },
    responders: { arp: arpToDns, ntp: { unixSeconds: 1700000000 } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /UTC time:   2023-11-14 22:13:20/);
  assert.match(r.output, /Local time: 2023-11-15 03:43:20 \(TZ \+5:30\)/);
  checkCleanupClaimedPage(r);
}
{ // negative NET_TZ minute offset
  const r = run('NTP', '192.168.7.1', {
    environment: { ...NET_ENV, NET_TZ: '-3:30' },
    responders: { arp: arpToDns, ntp: { unixSeconds: 1700000000 } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /UTC time:   2023-11-14 22:13:20/);
  assert.match(r.output, /Local time: 2023-11-14 18:43:20 \(TZ -3:30\)/);
  checkCleanupClaimedPage(r);
}
{ // malformed minute field (single digit) falls back to UTC, does not crash
  const r = run('NTP', '192.168.7.1', {
    environment: { ...NET_ENV, NET_TZ: '+5:3' },
    responders: { arp: arpToDns, ntp: { unixSeconds: 1700000000 } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Local time: 2023-11-14 22:13:20 \(TZ \+0\)/);
  checkCleanupClaimedPage(r);
}
{ // out-of-range minute field falls back to UTC, does not crash
  const r = run('NTP', '192.168.7.1', {
    environment: { ...NET_ENV, NET_TZ: '+5:75' },
    responders: { arp: arpToDns, ntp: { unixSeconds: 1700000000 } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Local time: 2023-11-14 22:13:20 \(TZ \+0\)/);
  checkCleanupClaimedPage(r);
}
{ // a three-digit hour must NOT wrap the 8-bit accumulator: 264 mod 256 = 8,
  // so an unguarded parser would silently shift the clock by +8 hours.
  const r = run('NTP', '192.168.7.1', {
    environment: { ...NET_ENV, NET_TZ: '+264' },
    responders: { arp: arpToDns, ntp: { unixSeconds: 1700000000 } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Local time: 2023-11-14 22:13:20 \(TZ \+0\)/);
  checkCleanupClaimedPage(r);
}
{ // no NTP reply
  const r = run('NTP', '192.168.7.1', { environment: { ...NET_ENV }, responders: { arp: arpToDns } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /NTP reply timed out\./);
  checkCleanupClaimedPage(r);
}
{ // no server argument: falls back to NET_NTP (matches sprinter_wifi's
  // ESP kit and docs/NTP.md, which always documented this as the
  // contract even while the RTL implementation required the argument)
  const r = run('NTP', '', {
    environment: { ...NET_ENV, NET_NTP: '192.168.7.1' },
    responders: { arp: arpToDns, ntp: { unixSeconds: 1700000000, stratum: 2 } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Querying NTP at 192\.168\.7\.1 from 192\.168\.7\.2/);
  assert.match(r.output, /RESULT OK/);
  checkCleanupClaimedPage(r);
}
{ // NET_NTP holding a HOSTNAME, which is what NET.CFG's NTP= line
  // realistically carries (`NTP=pool.ntp.org`).  Exercises the DNS
  // path reached through the env fallback rather than an argument.
  const r = run('NTP', '', {
    environment: { ...NET_ENV_DNS, NET_NTP: 'pool.ntp.org' },
    responders: {
      arp: arpToDns,
      dns: { ip: [192, 168, 7, 1] },
      ntp: { unixSeconds: 1700000000, stratum: 2 },
    },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Querying NTP at 192\.168\.7\.1 from 192\.168\.7\.2/);
  assert.match(r.output, /RESULT OK/);
  checkCleanupClaimedPage(r);
}
{ // DNS is UDP, so a dropped query or reply must not be a hard failure:
  // resolve_lib retransmits up to DNS_RETRIES (3) times.  Two dropped
  // queries still resolve on the third.
  const r = run('NTP', '', {
    environment: { ...NET_ENV_DNS, NET_NTP: 'pool.ntp.org' },
    responders: {
      arp: arpToDns,
      dns: { ip: [192, 168, 7, 1], drop: 2 },
      ntp: { unixSeconds: 1700000000, stratum: 2 },
    },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Querying NTP at 192\.168\.7\.1 from 192\.168\.7\.2/);
  assert.match(r.output, /RESULT OK/);
  checkCleanupClaimedPage(r);
  count();
}
{ // ...and the retry budget is finite: a DNS server that never answers
  // still fails, with LAST_FAIL 5 (reply timeout), after 3 attempts.
  const r = run('NTP', '', {
    environment: { ...NET_ENV_DNS, NET_NTP: 'pool.ntp.org' },
    responders: { arp: arpToDns, dns: { mode: 'drop' } },
  });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /could not resolve host/);
  checkCleanupClaimedPage(r);
  count();
}
{ // NXDOMAIN is an answer, not a loss: it must NOT consume retries.
  // The responder counts queries, so a single one proves no retry.
  const dns = { nxdomain: true };
  const r = run('NTP', '', {
    environment: { ...NET_ENV_DNS, NET_NTP: 'pool.ntp.org' },
    responders: { arp: arpToDns, dns },
  });
  assert.strictEqual(r.exitCode, 3);
  assert.strictEqual(dns._count, 1, 'NXDOMAIN must not be retried');
  checkCleanupClaimedPage(r);
  count();
}
{ // an explicit argument still overrides NET_NTP.  NET_NTP is set to an
  // unresolvable name with no DNS server configured, so reaching the
  // network at all proves the argument won rather than the env.
  const r = run('NTP', '192.168.7.1', {
    environment: { ...NET_ENV, NET_NTP: 'must-not-be-used.invalid' },
    responders: { arp: arpToDns, ntp: { unixSeconds: 1700000000 } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Querying NTP at 192\.168\.7\.1 from 192\.168\.7\.2/);
  checkCleanupClaimedPage(r);
}
{ // no argument AND no NET_NTP -> config error (4), not a usage error:
  // the invocation itself was well-formed
  const r = run('NTP', '', { environment: { ...NET_ENV } });
  assert.strictEqual(r.exitCode, 4);
  assert.match(r.output, /\[E\] no NTP server given and NET_NTP not set/);
  checkCleanupClaimedPage(r);
}
{ // NET_NTP present but empty is treated the same as absent
  const r = run('NTP', '', { environment: { ...NET_ENV, NET_NTP: '' } });
  assert.strictEqual(r.exitCode, 4);
  assert.match(r.output, /\[E\] no NTP server given and NET_NTP not set/);
  checkCleanupClaimedPage(r);
}
for (const missing of ['NET_IP', 'NET_MAC']) {
  const environment = { ...NET_ENV }; delete environment[missing];
  const r = run('NTP', '192.168.7.1', { environment });
  assert.strictEqual(r.exitCode, 4);
  checkCleanupClaimedPage(r);
}
{
  const r = run('NTP', '192.168.7.1', { environment: { ...NET_ENV }, cardPresent: false });
  assert.strictEqual(r.exitCode, 2);
  checkCleanupClaimedPage(r);
}

// ---------------------------------------------------------------------
// IFUP.EXE
// ---------------------------------------------------------------------
{
  const r = run('IFUP', '', { environment: { NET_MAC: NET_ENV.NET_MAC, NET_IP_SRC: 'STATIC', NET_IP: '192.168.7.50' } });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Interface up: IP=192\.168\.7\.50 \(static\)\./);
  assert.match(r.output, /RESULT OK/);
  assert.strictEqual(r.environment.NET, 'RTL');
  count();
}
{ // full DHCP DORA
  const r = run('IFUP', '', {
    environment: { NET_MAC: NET_ENV.NET_MAC, NET_IP_SRC: 'DHCP' },
    responders: { dhcp: { offeredIp: [192, 168, 7, 100], serverIp: [192, 168, 7, 1], lease: 7200, dns2: [9, 9, 9, 9] } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /DHCP: sending DISCOVER\.\.\./);
  assert.match(r.output, /DHCP: got OFFER 192\.168\.7\.100 \(server 192\.168\.7\.1\)/);
  assert.match(r.output, /DHCP: lease IP=192\.168\.7\.100 \(server 192\.168\.7\.1, lease 7200 s\)/);
  assert.match(r.output, /RESULT OK/);
  assert.strictEqual(r.environment.NET_IP, '192.168.7.100');
  assert.strictEqual(r.environment.NET_MASK, '255.255.255.0');
  assert.strictEqual(r.environment.NET_GW, '192.168.7.1');
  assert.strictEqual(r.environment.NET_DNS1, '8.8.8.8');
  assert.strictEqual(r.environment.NET_DNS2, '9.9.9.9');
  assert.strictEqual(r.environment.NET_DHCP_SRV, '192.168.7.1');
  // KNOWN BUG (reported upstream, not fixed here): ifup.asm's FMT_DEC_HL
  // calls DIV_HL_10 without preserving DE (the SET_BUF output pointer);
  // DIV_HL_10's own `LD DE,16` clobbers it, so the lease digits are
  // written to address 0x0000 instead of the env buffer, and whatever
  // stale bytes happen to follow "NET_LEASE_SEC=" in SET_BUF get
  // published instead. The console line (which uses PRINT_DEC_HL, a
  // PUTCHAR-based twin that never touches DE) prints the correct value.
  assert.notStrictEqual(r.environment.NET_LEASE_SEC, '7200');
  count();
}
{ // KNOWN BUG (reported upstream, not fixed here): when the DHCP ACK's
  // option 6 supplies only one DNS server (length 4, not >=8),
  // @DHCP.DNS2 is never written by the parser, but IFUP's SETENV_IPV4
  // publishes it anyway -- as whatever POISON/leftover bytes happen to
  // sit in that BSS slot, not as an absent/all-zero value.
  const r = run('IFUP', '', {
    environment: { NET_MAC: NET_ENV.NET_MAC, NET_IP_SRC: 'DHCP' },
    responders: { dhcp: { offeredIp: [192, 168, 7, 100], serverIp: [192, 168, 7, 1] } }, // no dns2
  });
  assert.strictEqual(r.exitCode, 0);
  assert.notStrictEqual(r.environment.NET_DNS2, undefined);
  assert.notStrictEqual(r.environment.NET_DNS2, '0.0.0.0');
  count();
}
{ // DHCPNAK on the REQUEST is not specially detected -- silently ignored,
  // exactly like no reply at all, until the retry budget is exhausted.
  const r = run('IFUP', '', {
    environment: { NET_MAC: NET_ENV.NET_MAC, NET_IP_SRC: 'DHCP' },
    responders: { dhcp: { offeredIp: [192, 168, 7, 100], serverIp: [192, 168, 7, 1], mode: 'nak' } },
  });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /DHCP timed out \(no OFFER\/ACK from any server\)\./);
  count();
}
{ // no DHCP server at all
  const r = run('IFUP', '', { environment: { NET_MAC: NET_ENV.NET_MAC, NET_IP_SRC: 'DHCP' } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /DHCP timed out \(no OFFER\/ACK from any server\)\./);
  count();
}
{ // static mode still requires NET_IP
  const r = run('IFUP', '', { environment: { NET_MAC: NET_ENV.NET_MAC, NET_IP_SRC: 'STATIC' } });
  assert.strictEqual(r.exitCode, 4);
  assert.match(r.output, /\[E\] env var NET_IP not set; run NETCFG -i first/);
  count();
}
{ // NET_MAC is required in every mode
  const r = run('IFUP', '', { environment: { NET_IP_SRC: 'STATIC', NET_IP: '192.168.7.50' } });
  assert.strictEqual(r.exitCode, 4);
  assert.match(r.output, /\[E\] env var NET_MAC not set; run NETCFG -i first/);
  count();
}
{
  const r = run('IFUP', '', {
    environment: { NET_MAC: NET_ENV.NET_MAC, NET_IP_SRC: 'STATIC', NET_IP: '192.168.7.50' },
    cardPresent: false,
  });
  assert.strictEqual(r.exitCode, 2);
  count();
}

// ---------------------------------------------------------------------
// NETCFG.EXE
// ---------------------------------------------------------------------
const NETCFG_APPDIR = 'C:\\NET';
const netcfgFiles = (contents) => ({ appDir: NETCFG_APPDIR, files: { [`${NETCFG_APPDIR}\\NET.CFG`]: contents } });
const NET_CFG_SAMPLE = 'IP=192.168.7.2\r\nNETMASK=255.255.255.0\r\nGATEWAY=192.168.7.1\r\n' +
  'DNS1=8.8.8.8\r\nRTL_MAC=02:80:19:11:22:33\r\nRTL_HW=1/300\r\nTZ=-5\r\n';
{
  const r = run('NETCFG', '-i', netcfgFiles(NET_CFG_SAMPLE));
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[C0\] CFG=C:\\NET\\NET\.CFG/);
  assert.match(r.output, /RESULT OK/);
  assert.strictEqual(r.environment.NET_IP_SRC, 'STATIC');
  assert.strictEqual(r.environment.NET_IP, '192.168.7.2');
  assert.strictEqual(r.environment.NET_MASK, '255.255.255.0');
  assert.strictEqual(r.environment.NET_GW, '192.168.7.1');
  assert.strictEqual(r.environment.NET_MAC, '02:80:19:11:22:33');
  assert.strictEqual(r.environment.NET_DNS1, '8.8.8.8');
  assert.strictEqual(r.environment.NET_DNS2, undefined); // absent value deletes, never publishes 0.0.0.0
  assert.strictEqual(r.environment.NET_TZ, '-5');
  assert.strictEqual(r.environment.NET_RTL_HW, '1/#300'); // canonicalized uppercase form
  assert.strictEqual(r.environment.NET, 'RTL');
  count();
}
{ // TZ minute offset survives NET.CFG -> NET_TZ verbatim (previously truncated to "+5")
  const r = run('NETCFG', '-i', netcfgFiles(NET_CFG_SAMPLE.replace('TZ=-5', 'TZ=+5:30')));
  assert.strictEqual(r.exitCode, 0);
  assert.strictEqual(r.environment.NET_TZ, '+5:30');
  count();
}
{ // IP=DHCP: only the mode flag is published; stale IP/MASK/GW/DNS are cleared
  const r = run('NETCFG', '-i', netcfgFiles('IP=DHCP\r\nRTL_MAC=02:80:19:11:22:33\r\n'));
  assert.strictEqual(r.exitCode, 0);
  assert.strictEqual(r.environment.NET_IP_SRC, 'DHCP');
  assert.strictEqual(r.environment.NET_IP, undefined);
  assert.strictEqual(r.environment.NET_MASK, undefined);
  assert.strictEqual(r.environment.NET_GW, undefined);
  count();
}
{ // NET.CFG past the 2 KB read buffer: keys at the end must still be read.
  // The loader used to do one 2047-byte read, so a commented 2079-byte file
  // lost its trailing TZ=/NTP= (field report 2026-09-19).
  const fs = require('fs');
  const comment = (n) => Array.from({ length: n }, (_, i) =>
    `# comment line ${String(i).padStart(3, '0')} padding padding padding padding\r\n`).join('');
  const big = 'IP=192.168.7.2\r\nRTL_MAC=02:80:19:11:22:33\r\n' + comment(80) +
    'DNS1=1.1.1.1\r\n' + comment(40) + 'TZ=+3\r\nNTP=pool.ntp.org';  // no final CRLF
  assert.ok(big.length > 6000, `test file too small: ${big.length}`);
  const long = 'RTL_MAC=02:80:19:11:22:33\r\n# ' + 'x'.repeat(2500) + 'IP=10.9.9.9\r\n' +
    'IP=192.168.7.2\r\nNTP=long.example\r\n';
  const sample = fs.readFileSync(path.join(__dirname, '..', 'config', 'NETSMPL.CFG'), 'latin1');
  const cases = [
    ['big', big, {}], ['big-short-reads', big, { fileReadMax: 100 }],
    ['long-line', long, {}], ['sample', sample, {}],
  ];
  for (const [label, text, extra] of cases) {
    const r = run('NETCFG', '-i', { ...netcfgFiles(text), ...extra });
    assert.strictEqual(r.exitCode, 0, `${label}: exit ${r.exitCode}\n${r.output}`);
    if (label === 'long-line') {
      // The tail of the overlong comment must not be parsed as IP=10.9.9.9.
      assert.strictEqual(r.environment.NET_IP, '192.168.7.2', label);
      assert.strictEqual(r.environment.NET_NTP, 'long.example', label);
    } else if (label === 'sample') {
      assert.strictEqual(r.environment.NET_TZ, '+3', label);
      assert.strictEqual(r.environment.NET_NTP, 'pool.ntp.org', label);
    } else {
      assert.strictEqual(r.environment.NET_IP, '192.168.7.2', label);
      assert.strictEqual(r.environment.NET_DNS1, '1.1.1.1', label);
      assert.strictEqual(r.environment.NET_TZ, '+3', label);
      assert.strictEqual(r.environment.NET_NTP, 'pool.ntp.org', label);
    }
    count();
  }
}
{ // unknown keys and comments are silently ignored, not a syntax error
  const r = run('NETCFG', '-c', netcfgFiles('# a comment\r\nBOGUS_KEY=xyz\r\n\r\nIP=192.168.7.2\r\n'));
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /NET\.CFG syntax OK/);
  count();
}
{ // NETCFG -i fails when neither RTL_MAC nor the PROM can supply a MAC
  const r = run('NETCFG', '-i', { ...netcfgFiles('IP=192.168.7.2\r\n'), mac: [0, 0, 0, 0, 0, 0] });
  assert.strictEqual(r.exitCode, 4);
  assert.match(r.output, /\[E4\] no MAC in card PROM; add RTL_MAC= to NET\.CFG/);
  assert.strictEqual(r.environment.NET_MAC, undefined);
  count();
}
{ // NETCFG -i without RTL_MAC falls back to reading the card's PROM
  const r = run('NETCFG', '-i', netcfgFiles('IP=192.168.7.2\r\n'));
  assert.strictEqual(r.exitCode, 0);
  assert.strictEqual(r.environment.NET_MAC, '02:80:19:11:22:33');
  count();
}
{ // no card at all -> exit 2, but NET.CFG's other values are still published
  const r = run('NETCFG', '-i', { ...netcfgFiles('IP=192.168.7.2\r\n'), cardPresent: false });
  assert.strictEqual(r.exitCode, 2);
  assert.match(r.output, /\[E2\] card not found; check RTL_HW in NET\.CFG/);
  assert.strictEqual(r.environment.NET_IP, '192.168.7.2');
  count();
}
{ // A NET.CFG with no RTL_RESET= line on a clone that stalls BASE+0x1F.
  // This is the exact configuration that hung a real Sprinter: the fix is
  // that the driver resolves the mode from the chip ID instead of trusting
  // the absent key, and NETCFG then latches the answer for everything that
  // runs later (UNETRTL.DLL above all -- it has no room for the ID probe).
  const r = run('NETCFG', '-i', {
    ...netcfgFiles('IP=192.168.7.2\r\nRTL_HW=1/#300\r\n'),
    quirks: { variant: 'UM9003', hangOnResetPort: true },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /\[W03\] non-Realtek clone: board reset port skipped/);
  assert.strictEqual(r.environment.NET_RTL_RESET, 'SOFT');
  count();
}
{ // A genuine Realtek leaves NET_RTL_RESET deleted, so the next utility
  // re-probes rather than inheriting a stale HARD across a card swap.
  const r = run('NETCFG', '-i', netcfgFiles('IP=192.168.7.2\r\nRTL_HW=1/#300\r\n'));
  assert.strictEqual(r.exitCode, 0);
  assert.doesNotMatch(r.output, /\[W03\]/);
  assert.strictEqual(r.environment.NET_RTL_RESET, undefined);
  count();
}
{ // RTL_RESET=SOFT in NET.CFG still publishes SOFT verbatim
  const r = run('NETCFG', '-i', netcfgFiles('IP=192.168.7.2\r\nRTL_RESET=SOFT\r\n'));
  assert.strictEqual(r.exitCode, 0);
  assert.strictEqual(r.environment.NET_RTL_RESET, 'SOFT');
  count();
}
{ // RTL_RESET=HARD forces the pulse and is published as such
  const r = run('NETCFG', '-i', netcfgFiles('IP=192.168.7.2\r\nRTL_RESET=HARD\r\n'));
  assert.strictEqual(r.exitCode, 0);
  assert.strictEqual(r.environment.NET_RTL_RESET, 'HARD');
  count();
}
{ // -c on a missing file
  const r = run('NETCFG', '-c', { appDir: NETCFG_APPDIR });
  assert.strictEqual(r.exitCode, 4);
  assert.match(r.output, /\[E\] NET\.CFG read failed/);
  count();
}
{ // -d deletes every NET_* variable unconditionally
  const r = run('NETCFG', '-d', { environment: { NET_IP: '1.2.3.4', NET: 'RTL' } });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Deleting NET_\* environment variables\.\.\./);
  assert.deepStrictEqual(r.environment, {});
  count();
}
{ // no flag: show current (empty) config
  const r = run('NETCFG', '', { appDir: NETCFG_APPDIR });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /NET_IP_SRC   : <not set>/);
  count();
}
{ // unknown flag -> usage error
  const r = run('NETCFG', '-z', {});
  assert.strictEqual(r.exitCode, 1);
  assert.match(r.output, /\[E\] usage: unknown or malformed flag/);
  count();
}

// ---------------------------------------------------------------------
// NETCFG -w (interactive wizard)
// ---------------------------------------------------------------------
const netcfgNoFile = () => ({ appDir: NETCFG_APPDIR, files: {} });
// What the screen actually shows: apply the 0x08 cursor-left the wizard uses
// for its blinking cursor and for Backspace, so assertions read the finished
// line rather than the keystroke-by-keystroke trail that produced it.
const rendered = (text) => {
  const out = [];
  for (const ch of text) { if (ch === '\x08') out.pop(); else out.push(ch); }
  return out.join('');
};
const NETCFG_W_NEW_FILE =
  '# NET.CFG -- written by NETCFG -w.  Run NETCFG -i to apply.\r\n' +
  '# Empty value = not set.  RTL_RESET empty = AUTO (driver decides).\r\n' +
  'RTL_HW=\r\nRTL_RESET=\r\nRTL_MAC=\r\nIP=DHCP\r\nNETMASK=\r\nGATEWAY=\r\n' +
  'DNS1=\r\nDNS2=\r\nTZ=+3\r\nNTP=pool.ntp.org\r\n';
{ // fresh machine, all Enter: NETSMPL.CFG-style defaults, byte-exact file
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['enter', 'n', 'enter', 'enter', 'enter', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /NET\.CFG written\.  Run NETCFG -i to apply\./);
  assert.strictEqual(r.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1'), NETCFG_W_NEW_FILE);
  checkCleanupClaimedPage(r);
}
{ // editing an existing file changes only the touched key
  const existing = 'RTL_HW=1/#300\r\nRTL_RESET=SOFT\r\nRTL_MAC=aa:bb:cc:dd:ee:ff\r\n' +
    'IP=10.0.0.5\r\nNETMASK=255.255.255.0\r\nGATEWAY=10.0.0.1\r\n' +
    'DNS1=8.8.8.8\r\nDNS2=8.8.4.4\r\nTZ=+2\r\nNTP=old.example.com\r\n';
  const r = run('NETCFG', '-w', {
    appDir: NETCFG_APPDIR, files: { [`${NETCFG_APPDIR}\\NET.CFG`]: existing },
    keys: ['enter', 'n', 'enter', 'enter', 'enter', 'enter', 'enter', 'enter', 'enter', 'enter',
           'new.example.com', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  const written = r.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1');
  assert.match(written, /NTP=new\.example\.com/);
  for (const line of ['RTL_HW=1/#300', 'RTL_RESET=SOFT', 'RTL_MAC=aa:bb:cc:dd:ee:ff',
    'IP=10.0.0.5', 'NETMASK=255.255.255.0', 'GATEWAY=10.0.0.1', 'DNS1=8.8.8.8', 'DNS2=8.8.4.4', 'TZ=+2']) {
    assert.ok(written.includes(line + '\r\n'), `expected ${line} unchanged, got:\n${written}`);
  }
  checkCleanupClaimedPage(r);
}
{ // Esc mid-wizard: cancels (exit 7), leaves the existing file byte-identical
  const existing = 'IP=10.0.0.1\r\nNETMASK=255.0.0.0\r\n';
  const r = run('NETCFG', '-w', {
    appDir: NETCFG_APPDIR, files: { [`${NETCFG_APPDIR}\\NET.CFG`]: existing },
    keys: ['enter', 'n', 'enter', 'enter', 'escape'],
  });
  assert.strictEqual(r.exitCode, 7);
  assert.match(r.output, /Cancelled -- NET\.CFG left unchanged\./);
  assert.strictEqual(r.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1'), existing);
  checkCleanupClaimedPage(r);
}
{ // @UTIL.PARSE_DEC_BYTE overflow ("999" -> 231 mod 256) must be rejected,
  // not silently accepted as a wrapped-around address -- the field is
  // reprompted and only the corrected value is committed.
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['enter', 'n', 'enter', 'enter', '999.1.1.1', 'enter', '10.0.0.5', 'enter',
           'enter', 'enter', 'enter', 'enter', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /  invalid value, try again\./);
  const invalidCount = (r.output.match(/invalid value, try again/g) || []).length;
  assert.strictEqual(invalidCount, 1, 'error should print exactly once');
  assert.match(r.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1'), /IP=10\.0\.0\.5/);
  checkCleanupClaimedPage(r);
}
{ // DHCP: the four static-only prompts never appear
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['enter', 'n', 'enter', 'enter', 'enter', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  assert.doesNotMatch(r.output, /NETMASK \[/);
  assert.doesNotMatch(r.output, /GATEWAY \[/);
  assert.doesNotMatch(r.output, /DNS1 \[/);
  assert.doesNotMatch(r.output, /DNS2 \[/);
  count();
}
{ // hints: every step explains itself -- in particular what RTL_RESET is and
  // that HARD can freeze the machine -- and a hint is printed ONCE per field,
  // not again on the re-prompt that follows a rejected value
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['enter', 'n', 'enter', 'enter', '999.1.1.1', 'enter', '10.0.0.5', 'enter',
           'enter', 'enter', 'enter', 'enter', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Esc\r?\nquits without saving/);
  assert.match(r.output, /AUTO - decide by chip type \(recommended/);
  assert.match(r.output, /HARD - always pulse it\.  This FREEZES the computer/);
  assert.match(r.output, /The probe looks for the card[\s\S]*Probe for the card now \[Y\/n\]/);
  assert.strictEqual((r.output.match(/IP address of this computer/g) || []).length, 1);
  assert.strictEqual((r.output.match(/^IP \[/gm) || []).length, 2, 'IP prompt itself repeats');
  for (const line of rendered(r.output).split(/\r?\n/)) assert.ok(line.length < 80, `line too wide: ${line}`);
  checkCleanupClaimedPage(r);
}
{ // DHCP: hints of the skipped static-only fields are not shown either
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['enter', 'n', 'enter', 'enter', 'enter', 'enter', 'enter'],
  });
  assert.doesNotMatch(r.output, /Network mask|Gateway:|DNS server/);
  count();
}
{ // a blinking cursor marks every prompt, so a waiting wizard cannot be
  // mistaken for a hung one.  It is drawn as '_' stepped back over with 0x08,
  // and the cell is blanked again before the keystroke is echoed -- so the
  // finished line must carry no leftover underscore.
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['enter', 'n', '1/#300', 'enter', 'enter', 'enter', 'enter', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /RTL_RESET \[AUTO\]: _\x08/, 'cursor must appear at the field prompt');
  assert.match(r.output, /Probe for the card now \[Y\/n\]\? _\x08/, 'and at the Y/N prompt');
  const screen = rendered(r.output);
  assert.match(screen, /^RTL_HW \[\]: 1\/#300$/m, 'typed text lands on a clean cell');
  assert.match(screen, /^RTL_RESET \[AUTO\]: $/m, 'no cursor left behind on Enter');
  assert.doesNotMatch(screen, /_$/m, 'no line may end with a leftover cursor');
  checkCleanupClaimedPage(r);
}
{ // the pre-prompt flush (K_CLEAR chained to #33 CTRLKEY, which reports
  // modifiers instead of popping the ring) must not swallow a keystroke:
  // exactly as many keys are consumed as the script sends
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['enter', 'n', 'enter', 'enter', 'enter', '+5:30', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1'), /TZ=\+5:30\r\n/);
  checkCleanupClaimedPage(r);
}
{ // Backspace still erases, now that the cursor shares the same cell
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['enter', 'n', 'enter', 'enter', '10.0.0.59', 'backspace', 'enter',
           'enter', 'enter', 'enter', 'enter', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(rendered(r.output), /^IP \[DHCP\]: 10\.0\.0\.5$/m);
  assert.match(r.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1'), /IP=10\.0\.0\.5\r\n/);
  checkCleanupClaimedPage(r);
}
{ // TZ: minute offset accepted; malformed/out-of-range minutes rejected.
  // DHCP (kept via Enter on IP) skips NETMASK/GATEWAY/DNS1/DNS2, so TZ is
  // the very next prompt after IP.
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['enter', 'n', 'enter', 'enter', 'enter',
           '+5:3', 'enter', '+15', 'enter', '+5:30', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  const invalidCount = (r.output.match(/invalid value, try again/g) || []).length;
  assert.strictEqual(invalidCount, 2, `expected 2 rejections, got:\n${r.output}`);
  assert.match(r.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1'), /TZ=\+5:30/);
  checkCleanupClaimedPage(r);
}
{ // TZ: a three-digit hour is rejected rather than wrapped (264 mod 256 = 8,
  // which would otherwise be written to NET.CFG as a plausible-looking "+8")
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['enter', 'n', 'enter', 'enter', 'enter',
           '+264', 'enter', '+5', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  const invalidCount = (r.output.match(/invalid value, try again/g) || []).length;
  assert.strictEqual(invalidCount, 1, `expected 1 rejection, got:\n${r.output}`);
  assert.match(r.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1'), /TZ=\+5\r\n/);
  checkCleanupClaimedPage(r);
}
{ // an invalid TZ= already in NET.CFG must not survive a plain Enter: TZ is
  // the one field @NETCFG.LOAD hands over unparsed, so the wizard validates
  // the loaded default itself and blanks what it cannot canonicalize.
  const existing = 'IP=10.0.0.5\r\nNETMASK=255.255.255.0\r\nTZ=+5:3\r\n';
  const r = run('NETCFG', '-w', {
    appDir: NETCFG_APPDIR, files: { [`${NETCFG_APPDIR}\\NET.CFG`]: existing },
    keys: ['enter', 'n', 'enter', 'enter', 'enter', 'enter', 'enter', 'enter',
           'enter', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  const written = r.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1');
  assert.ok(written.includes('TZ=\r\n'), `expected TZ blanked, got:\n${written}`);
  assert.ok(written.includes('IP=10.0.0.5\r\n'), 'other fields must survive');
  checkCleanupClaimedPage(r);
}
{ // Esc at the probe Y/N prompt cancels the wizard, like Esc at any other
  // prompt -- it does not silently mean "no" and carry on
  const existing = 'IP=10.0.0.1\r\n';
  const r = run('NETCFG', '-w', {
    appDir: NETCFG_APPDIR, files: { [`${NETCFG_APPDIR}\\NET.CFG`]: existing },
    keys: ['enter', 'escape'],
  });
  assert.strictEqual(r.exitCode, 7);
  assert.match(r.output, /Cancelled -- NET\.CFG left unchanged\./);
  assert.strictEqual(r.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1'), existing);
  checkCleanupClaimedPage(r);
}
{ // probe finds the card and updates both RTL_HW (wizard field) and the
  // live NET_RTL_HW env var (INIT_BASE's auto-scan side effect).  The probe
  // runs BEFORE the RTL_HW prompt, so RTL_HW is asked exactly once, with the
  // discovered value as its default.
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['enter', 'y', 'enter', 'enter', 'enter', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Found: MAC=02:80:19:11:22:33/);
  assert.strictEqual((r.output.match(/RTL_HW \[/g) || []).length, 1, `RTL_HW asked more than once:\n${r.output}`);
  assert.match(r.output, /RTL_RESET \[AUTO\][\s\S]*Probe for the card now[\s\S]*Found: MAC=[\s\S]*RTL_HW \[1\/#300\]: /);
  assert.match(r.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1'), /RTL_HW=1\/#300\r\n/);
  assert.ok(r.environment.NET_RTL_HW, 'INIT_BASE auto-scan should have published NET_RTL_HW');
  checkCleanupClaimedPage(r);
}
{ // the probe question's hint shows the REAL default: [Y/n] normally, and a
  // bare Enter then probes...
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['enter', 'enter', 'enter', 'enter', 'enter', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /Probe for the card now \[Y\/n\]\? /);
  assert.match(r.output, /Found: MAC=/);
  checkCleanupClaimedPage(r);
}
{ // ...but [y/N] with a warning when RTL_RESET is HARD, and Enter skips it
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['hard', 'enter', 'enter', 'enter', 'enter', 'enter', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /RTL_RESET is HARD/);
  assert.match(r.output, /Probe for the card now \[y\/N\]\? /);
  assert.doesNotMatch(r.output, /Found: MAC=/);
  assert.match(r.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1'), /RTL_RESET=HARD\r\n/);
  checkCleanupClaimedPage(r);
}
{ // Esc at the RTL_HW prompt that follows a successful probe cancels too
  const r = run('NETCFG', '-w', { ...netcfgNoFile(), keys: ['enter', 'y', 'escape'] });
  assert.strictEqual(r.exitCode, 7);
  assert.match(r.output, /Found: MAC=/);
  assert.strictEqual(r.files[`${NETCFG_APPDIR}\\NET.CFG`], undefined, 'no file may be written');
  checkCleanupClaimedPage(r);
}
{ // probing a clone that hangs on the reset port must not hang the harness
  // (RTL_RESET defaults to AUTO, so the driver's own chip-ID check decides)
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    quirks: { variant: 'UM9003', hangOnResetPort: true },
    keys: ['enter', 'y', 'enter', 'enter', 'enter', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 0);
  count();
}
{ // write failure: exit 5, every opened handle still gets closed
  const r = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    fileWriteFailAt: 1,
    keys: ['enter', 'n', 'enter', 'enter', 'enter', 'enter', 'enter'],
  });
  assert.strictEqual(r.exitCode, 5);
  assert.match(r.output, /\[E\] could not write NET\.CFG\./);
  assert.strictEqual(r.cleanup.filesClosed, true);
  // The lowest SP of the whole run is the WIN1 entry stack (0x8000 down,
  // used only by CLAIM_RUNTIME_PAGE before SP moves to RT_STACK_TOP); it must
  // stay above the image ceiling the app asserts (0x7F80).
  assert.ok(r.minimumSp >= 0x7F80, `stack ran too low: 0x${r.minimumSp.toString(16)}`);
  count();
}
{ // an existing NET.CFG that cannot even be read is never overwritten
  const r = run('NETCFG', '-w', {
    appDir: NETCFG_APPDIR, files: { [`${NETCFG_APPDIR}\\NET.CFG`]: 'IP=10.0.0.1\r\n' },
    fileReadFailAt: 1,
    keys: [],
  });
  assert.strictEqual(r.exitCode, 4);
  assert.match(r.output, /\[E\] NET\.CFG exists but could not be read; not overwriting it\./);
  assert.strictEqual(r.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1'), 'IP=10.0.0.1\r\n');
  count();
}
{ // round-trip: -w's own output re-parses cleanly through -i with every
  // typed value surviving, including the TZ minute offset (Stage A) and
  // an RTL_RESET word the on-disk format special-cases (HARD).
  const w = run('NETCFG', '-w', {
    ...netcfgNoFile(),
    keys: ['hard', 'enter', 'n', '1/#320', 'enter', 'aa:bb:cc:dd:ee:ff', 'enter',
           '10.1.1.5', 'enter', '255.255.0.0', 'enter', '10.1.1.1', 'enter',
           '8.8.8.8', 'enter', '8.8.4.4', 'enter', '+5:45', 'enter', 'ntp.example.org', 'enter'],
  });
  assert.strictEqual(w.exitCode, 0);
  const cfgText = w.files[`${NETCFG_APPDIR}\\NET.CFG`].toString('latin1');
  const i = run('NETCFG', '-i', netcfgFiles(cfgText));
  assert.strictEqual(i.exitCode, 0);
  assert.strictEqual(i.environment.NET_RTL_HW, '1/#320');
  assert.strictEqual(i.environment.NET_RTL_RESET, 'HARD');
  assert.strictEqual(i.environment.NET_MAC, 'aa:bb:cc:dd:ee:ff');
  assert.strictEqual(i.environment.NET_IP, '10.1.1.5');
  assert.strictEqual(i.environment.NET_MASK, '255.255.0.0');
  assert.strictEqual(i.environment.NET_GW, '10.1.1.1');
  assert.strictEqual(i.environment.NET_DNS1, '8.8.8.8');
  assert.strictEqual(i.environment.NET_DNS2, '8.8.4.4');
  assert.strictEqual(i.environment.NET_TZ, '+5:45');
  assert.strictEqual(i.environment.NET_NTP, 'ntp.example.org');
  count(2);
}

// ---------------------------------------------------------------------
// TFTP.EXE
// ---------------------------------------------------------------------
const arpForTftp = { mac: [2, 0, 0, 0, 0, 1] };
{ // GET, single block, RFC-1350 fallback (server ignores blksize option)
  const r = run('TFTP', '192.168.7.1 GET README.TXT', {
    environment: { ...NET_ENV },
    responders: { arp: arpForTftp, tftp: { files: { 'README.TXT': 'Hello TFTP world.\n' } } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /GET README\.TXT from 192\.168\.7\.1/);
  assert.match(r.output, /Done\. 18 bytes received\./);
  assert.match(r.output, /RESULT OK/);
  assert.strictEqual(r.files['C:\\NET\\README.TXT'].data
    ? Buffer.from(r.files['C:\\NET\\README.TXT'].data).toString()
    : Buffer.from(r.files['C:\\NET\\README.TXT']).toString(), 'Hello TFTP world.\n');
  checkCleanupClaimedPage(r);
}
{ // GET with OACK blksize negotiation across multiple blocks
  const body = 'X'.repeat(300) + 'Y'.repeat(300);
  const r = run('TFTP', '192.168.7.1 GET BIG.BIN', {
    environment: { ...NET_ENV },
    responders: { arp: arpForTftp, tftp: { oackBlksize: 256, files: { 'BIG.BIN': body } } },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, new RegExp(`Done\\. ${body.length} bytes received\\.`));
  checkCleanupClaimedPage(r);
}
{ // PUT
  const r = run('TFTP', '192.168.7.1 PUT LOCAL.TXT', {
    environment: { ...NET_ENV },
    files: { 'LOCAL.TXT': 'upload payload\n' },
    responders: { arp: arpForTftp, tftp: {} },
  });
  assert.strictEqual(r.exitCode, 0);
  assert.match(r.output, /PUT LOCAL\.TXT to 192\.168\.7\.1/);
  assert.match(r.output, /Done\. 15 bytes sent\./);
  checkCleanupClaimedPage(r);
}
{
  // KNOWN BUG (reported upstream, not fixed here), HIGH SEVERITY: when the
  // server answers with an OP_ERROR packet, tftp.asm's WAIT_FOR_TFTP_DATA
  // prints "[E] TFTP server: <message>" via DSS_PCHARS directly, without
  // closing the ISA window first (no @ISA.ISA_CLOSE before that PRINT).
  // This violates the project's own core ISA-discipline rule (AGENTS.md:
  // "NEVER call DSS or BIOS while the ISA window is open") on a reachable,
  // ordinary protocol path (server refuses a GET/PUT) -- not just a
  // theoretical corner case. On real hardware this is documented to
  // corrupt chip state or hang/power off the machine. The harness's DSS-
  // while-ISA-open invariant throws instead of silently miscompiling the
  // bug into passing output; once tftp.asm is fixed (ISA_CLOSE before the
  // PRINT, matching every other error path in the file), replace this
  // assert.throws with a normal exit-6 success check.
  assert.throws(() => run('TFTP', '192.168.7.1 GET NOPE.TXT', {
    environment: { ...NET_ENV },
    responders: { arp: arpForTftp, tftp: { files: {} } },
  }), /DSS call while ISA window is open/);
  count();
}
{ // no TFTP reply at all
  const r = run('TFTP', '192.168.7.1 GET README.TXT', {
    environment: { ...NET_ENV }, responders: { arp: arpForTftp },
  });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /TFTP timeout or server error\./);
  checkCleanupClaimedPage(r);
}
{ // ARP for the server never answered
  const r = run('TFTP', '192.168.7.1 GET README.TXT', { environment: { ...NET_ENV } });
  assert.strictEqual(r.exitCode, 3);
  assert.match(r.output, /\[E\] TFTP server:|ARP request timed out\./);
  checkCleanupClaimedPage(r);
}
{ // bad verb -> usage error
  const r = run('TFTP', '192.168.7.1 BOGUS foo.txt', { environment: { ...NET_ENV } });
  assert.strictEqual(r.exitCode, 1);
  assert.match(r.output, /\[E\] usage: missing or invalid arguments/);
  checkCleanupClaimedPage(r);
}
for (const missing of ['NET_IP', 'NET_MAC']) {
  const environment = { ...NET_ENV }; delete environment[missing];
  const r = run('TFTP', '192.168.7.1 GET README.TXT', { environment });
  assert.strictEqual(r.exitCode, 4);
  checkCleanupClaimedPage(r);
}
{
  const r = run('TFTP', '192.168.7.1 GET README.TXT', { environment: { ...NET_ENV }, cardPresent: false });
  assert.strictEqual(r.exitCode, 2);
  checkCleanupClaimedPage(r);
}

console.log(`Actual DSS EXE net-protocol harness: ${caseCount()} ARP/PING/PINGALT/UDPTEST/NSLOOKUP/NTP/IFUP/NETCFG/TFTP checks passed`);
