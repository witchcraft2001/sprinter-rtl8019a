#!/usr/bin/env node
// Phase 2 actual-EXE integration vectors: protocol utilities (ARP, PING,
// PINGALT, UDPTEST, NSLOOKUP, NTP, IFUP, NETCFG, TFTP).
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const assert = require('assert');
const path = require('path');
const { runExe } = require('./exe-harness/harness.js');
const { count, caseCount, checkCleanupClaimedPage } = require('./exe-harness/test-util.js');

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
    assert.strictEqual((r.output.match(/Reply from 192\.168\.7\.1: bytes=32 time<1ms TTL=64/g) || []).length, 2);
    assert.match(r.output, /Packets: Sent = 2, Received = 2, Lost = 0\./);
    assert.match(r.output, /RESULT OK/);
    checkCleanupClaimedPage(r);
  }
  { // custom payload size and TTL
    const r = run(app, '-n 1 -l 64 -i 32 192.168.7.1', { environment: { ...NET_ENV }, responders: arpAndIcmp });
    assert.strictEqual(r.exitCode, 0);
    assert.match(r.output, /Reply from 192\.168\.7\.1: bytes=64 time<1ms TTL=32/);
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
{ // IP=DHCP: only the mode flag is published; stale IP/MASK/GW/DNS are cleared
  const r = run('NETCFG', '-i', netcfgFiles('IP=DHCP\r\nRTL_MAC=02:80:19:11:22:33\r\n'));
  assert.strictEqual(r.exitCode, 0);
  assert.strictEqual(r.environment.NET_IP_SRC, 'DHCP');
  assert.strictEqual(r.environment.NET_IP, undefined);
  assert.strictEqual(r.environment.NET_MASK, undefined);
  assert.strictEqual(r.environment.NET_GW, undefined);
  count();
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
