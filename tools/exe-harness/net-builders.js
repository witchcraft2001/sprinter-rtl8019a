// Protocol frame builders and reactive responders for the actual-EXE test
// suites. Pure functions of (request bytes, options) -> reply bytes, plus
// a top-level respond(frame, card, scenario) dispatcher wired as the
// RTL8019 model's onTransmit hook by harness.js.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const DEFAULT_SERVER_MAC = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01];
const BROADCAST_MAC = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff];

function checksum(bytes) {
  let sum = 0;
  for (let i = 0; i < bytes.length; i += 2) {
    sum += (bytes[i] << 8) | (bytes[i + 1] || 0);
    sum = (sum & 0xffff) + (sum >>> 16);
  }
  return (~sum) & 0xffff;
}

function putChecksum(bytes, offset, length, field) {
  bytes[field] = 0; bytes[field + 1] = 0;
  const value = checksum(bytes.slice(offset, offset + length));
  bytes[field] = value >> 8; bytes[field + 1] = value & 255;
}

function padTo60(frame) {
  while (frame.length < 60) frame.push(0);
  return frame;
}

// ---------------------------------------------------------------------
// ARP: request/reply layout exactly matches src/lib/arp_lib.asm.
//   ETH: dst(6) src(6) type(2)=0x0806
//   ARP: htype(2)=1 ptype(2)=0x0800 hlen(1)=6 plen(1)=4 op(2)
//        sha(6) spa(4) tha(6) tpa(4)
// ---------------------------------------------------------------------
function isArpRequest(frame) {
  return frame.length >= 42 && frame[12] === 0x08 && frame[13] === 0x06 &&
    frame[14] === 0 && frame[15] === 1 && frame[16] === 0x08 && frame[17] === 0 &&
    frame[18] === 6 && frame[19] === 4 && frame[20] === 0 && frame[21] === 1;
}

function buildArpReply(request, options = {}) {
  const senderMac = options.mac || DEFAULT_SERVER_MAC;
  const senderIp = options.ip || request.slice(38, 42); // default: answer for the requested TPA
  const requesterMac = request.slice(22, 28), requesterIp = request.slice(28, 32);
  const frame = [...requesterMac, ...senderMac, 0x08, 0x06,
    0, 1, 0x08, 0, 6, 4, 0, 2,
    ...senderMac, ...senderIp, ...requesterMac, ...requesterIp];
  if (options.badOpcode) frame[21] = 1;
  if (options.foreignDestination) frame.splice(0, 6, ...[2, 9, 9, 9, 9, 9]);
  return padTo60(frame);
}

function buildArpRequest(targetIp, options = {}) {
  const senderMac = options.mac || DEFAULT_SERVER_MAC;
  const senderIp = options.ip || [192, 168, 7, 1];
  const frame = [...BROADCAST_MAC, ...senderMac, 0x08, 0x06,
    0, 1, 0x08, 0, 6, 4, 0, 1,
    ...senderMac, ...senderIp, ...Array(6).fill(0), ...targetIp];
  return padTo60(frame);
}

// ---------------------------------------------------------------------
// ICMP echo: 14 (ETH) + 20 (IPv4) + 8+ (ICMP). Ethernet/IPv4 headers are
// protocol-generic; only the echo-specific fields differ per app.
// ---------------------------------------------------------------------
function icmpEchoRequest(frame) {
  if (frame.length < 42 || frame[12] !== 8 || frame[13] !== 0) return null;
  const ihl = (frame[14] & 15) * 4;
  if (frame[14] >> 4 !== 4 || frame[23] !== 1) return null;
  if (frame[14 + ihl] !== 8) return null; // ICMP type 8 = echo request
  return {
    ihl,
    sourceIp: frame.slice(26, 30),
    destIp: frame.slice(30, 34),
    sourceMac: frame.slice(6, 12),
    destMac: frame.slice(0, 6),
    icmp: frame.slice(14 + ihl),
  };
}

function buildIcmpReply(request, echo, options = {}) {
  // echo.sourceMac/sourceIp are the REQUESTER's (the DSS app under test);
  // echo.destMac/destIp are who the request was addressed to, i.e. us
  // (the simulated responder), unless overridden.
  const requesterMac = echo.sourceMac, requesterIp = echo.sourceIp;
  const responderMac = options.mac || echo.destMac;
  const responderIp = options.ip || echo.destIp;
  const icmp = echo.icmp.slice();
  icmp[0] = 0; // echo reply
  putChecksum(icmp, 0, icmp.length, 2);
  if (options.badChecksum) icmp[2] ^= 1;
  const total = 20 + icmp.length;
  const ip = [0x45, 0, total >> 8, total & 255, 0x43, 0x21, 0x40, 0,
    options.ttl || 63, 1, 0, 0, ...responderIp, ...requesterIp];
  putChecksum(ip, 0, 20, 10);
  const frame = [...requesterMac, ...responderMac, 8, 0, ...ip, ...icmp];
  return padTo60(frame);
}

function buildIcmpUnreachable(request, echo, options = {}) {
  const requesterMac = echo.sourceMac, requesterIp = echo.sourceIp;
  const routerMac = options.mac || echo.destMac;
  const routerIp = options.routerIp || [192, 168, 7, 1];
  const quote = request.slice(14, 14 + echo.ihl + 8);
  const icmp = [3, options.code !== undefined ? options.code : 1, 0, 0, 0, 0, 0, 0, ...quote];
  putChecksum(icmp, 0, icmp.length, 2);
  const total = 20 + icmp.length;
  const ip = [0x45, 0, total >> 8, total & 255, 0x22, 0x22, 0x40, 0,
    64, 1, 0, 0, ...routerIp, ...requesterIp];
  putChecksum(ip, 0, 20, 10);
  const frame = [...requesterMac, ...routerMac, 8, 0, ...ip, ...icmp];
  return padTo60(frame);
}

// ---------------------------------------------------------------------
// UDP datagram parsing/building. Generic IPv4/UDP; payload is opaque.
// ---------------------------------------------------------------------
function udpDatagram(frame) {
  if (frame.length < 42 || frame[12] !== 8 || frame[13] !== 0) return null;
  const ip = frame.slice(14);
  if (ip[0] !== 0x45 || ip[9] !== 17) return null;
  const total = (ip[2] << 8) | ip[3];
  if (total < 28 || total > ip.length) return null;
  const udp = ip.slice(20, total), udpLength = (udp[4] << 8) | udp[5];
  if (udpLength !== udp.length || udpLength < 8) return null;
  return {
    sourceMac: frame.slice(6, 12), destMac: frame.slice(0, 6),
    sourceIp: ip.slice(12, 16), destIp: ip.slice(16, 20),
    sourcePort: (udp[0] << 8) | udp[1], destPort: (udp[2] << 8) | udp[3],
    payload: udp.slice(8),
  };
}

function buildUdpReply(datagram, payload, options = {}) {
  const sourceMac = options.mac || DEFAULT_SERVER_MAC;
  const sourceIp = options.ip || datagram.destIp;
  const destinationIp = options.destinationIp || datagram.sourceIp;
  const destinationMac = options.destinationMac || datagram.sourceMac;
  const sourcePort = options.sourcePort ?? datagram.destPort;
  const destinationPort = options.destinationPort ?? datagram.sourcePort;
  const body = Array.from(payload);
  const udpLength = 8 + body.length;
  const udp = [sourcePort >> 8, sourcePort & 255, destinationPort >> 8, destinationPort & 255,
    udpLength >> 8, udpLength & 255, 0, 0, ...body];
  let udpSum = checksum([...sourceIp, ...destinationIp, 0, 17, udpLength >> 8, udpLength & 255, ...udp]);
  if (!udpSum) udpSum = 0xffff;
  udp[6] = udpSum >> 8; udp[7] = udpSum & 255;
  const total = 20 + udpLength;
  const ip = [0x45, 0, total >> 8, total & 255, 0x63, 0x21, 0x40, 0, options.ttl || 61,
    17, 0, 0, ...sourceIp, ...destinationIp];
  putChecksum(ip, 0, 20, 10);
  const frame = [...destinationMac, ...sourceMac, 8, 0, ...ip, ...udp];
  if (options.badUdpChecksum) frame[40] ^= 1;
  if (options.badIpChecksum) frame[24] ^= 1;
  return padTo60(frame);
}

// ---------------------------------------------------------------------
// DNS (A record only). Query format per src/lib/dns_lib.asm: 12-byte
// header (ID, flags, QDCOUNT=1, AN/NS/ARCOUNT=0) + QNAME + QTYPE(2)=1 +
// QCLASS(2)=1. The client's XID is unpredictable (derived from Z80 R/SP
// at call time) so a responder must echo back whatever ID it received.
// ---------------------------------------------------------------------
function parseDnsQuery(payload) {
  const id = (payload[0] << 8) | payload[1];
  let i = 12;
  while (payload[i] !== 0) i += payload[i] + 1;
  const qnameEnd = i; // offset of the terminating 0x00 label
  return { id, qname: payload.slice(12, qnameEnd + 1) };
}

function buildDnsResponse(datagram, options = {}) {
  const query = parseDnsQuery(datagram.payload);
  const rcode = options.rcode !== undefined ? options.rcode : (options.nxdomain ? 3 : 0);
  const answers = options.answers || (options.ip ? [options.ip] : (rcode === 0 && !options.noAnswer ? [[93, 184, 216, 34]] : []));
  const ancount = answers.length;
  const header = [
    (query.id >> 8) & 0xff, query.id & 0xff,
    0x81, 0x80 | (rcode & 0x0f),
    0, 1, (ancount >> 8) & 0xff, ancount & 0xff, 0, 0, 0, 0,
  ];
  const question = [...query.qname, 0, 1, 0, 1];
  const body = [...header, ...question];
  for (const ip of answers) body.push(0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, ...ip);
  if (options.badXid) body[0] ^= 1;
  // NB: options.ip means "the resolved A-record answer" here, NOT the
  // responder's own source address (buildUdpReply's `ip` option) -- do not
  // spread the whole options object across that naming collision.
  return buildUdpReply(datagram, body, {
    sourcePort: 53, mac: options.mac, ttl: options.ttl,
    badIpChecksum: options.badIpChecksum, badUdpChecksum: options.badUdpChecksum,
  });
}

// ---------------------------------------------------------------------
// NTP (client is a minimal NTPv3 client, src/apps/ntp.asm): request is a
// fixed 48-byte all-zero payload except byte0=0x1B (LI=0,VN=3,Mode=3). The
// client only reads the reply's Stratum (byte 1) and Transmit Timestamp
// seconds (bytes 40..43, BE, NTP epoch 1900) -- everything else is ignored.
// ---------------------------------------------------------------------
const NTP_EPOCH_OFFSET = 2208988800; // 1900-01-01 -> 1970-01-01, seconds

function buildNtpResponse(datagram, options = {}) {
  const unixSeconds = options.unixSeconds !== undefined ? options.unixSeconds : Math.floor(Date.now() / 1000);
  const ntpSeconds = (unixSeconds + NTP_EPOCH_OFFSET) >>> 0;
  const body = new Array(48).fill(0);
  body[0] = options.liVnMode !== undefined ? options.liVnMode : 0x1c; // LI=0,VN=3,Mode=4(server)
  body[1] = options.stratum !== undefined ? options.stratum : 1;
  body[40] = (ntpSeconds >>> 24) & 0xff;
  body[41] = (ntpSeconds >>> 16) & 0xff;
  body[42] = (ntpSeconds >>> 8) & 0xff;
  body[43] = ntpSeconds & 0xff;
  return buildUdpReply(datagram, body, {
    sourcePort: 123, mac: options.mac, ttl: options.ttl,
    badIpChecksum: options.badIpChecksum, badUdpChecksum: options.badUdpChecksum,
  });
}

// ---------------------------------------------------------------------
// DHCP (src/lib/dhcp.asm client, BOOTP wire format). Server replies are
// broadcast at L3 (unicast at L2 back to the requesting MAC, matching
// common real-world DHCP server behavior) since the client has no IP yet.
// ---------------------------------------------------------------------
function parseDhcpOptions(payload, start) {
  const opts = {};
  let i = start;
  while (i < payload.length) {
    const code = payload[i++];
    if (code === 255) break;
    if (code === 0) continue;
    const len = payload[i++];
    opts[code] = payload.slice(i, i + len);
    i += len;
  }
  return opts;
}

function isDhcpMessage(payload) {
  return payload.length >= 240 &&
    payload[236] === 0x63 && payload[237] === 0x82 && payload[238] === 0x53 && payload[239] === 0x63;
}

function dhcpMsgType(payload) {
  if (!isDhcpMessage(payload)) return 0;
  const opts = parseDhcpOptions(payload, 240);
  return opts[53] ? opts[53][0] : 0;
}

function buildDhcpReply(datagram, type, options = {}) {
  const serverMac = options.mac || DEFAULT_SERVER_MAC;
  const serverIp = options.serverIp || [192, 168, 7, 1];
  const offeredIp = options.offeredIp || [192, 168, 7, 100];
  const mask = options.mask || [255, 255, 255, 0];
  const router = options.router || serverIp;
  const dns1 = options.dns1 || [8, 8, 8, 8];
  const dns2 = options.dns2;
  const lease = options.lease !== undefined ? options.lease : 3600;
  const req = datagram.payload;
  const bootp = new Array(240).fill(0);
  bootp[0] = 2; bootp[1] = 1; bootp[2] = 6; bootp[3] = 0;
  for (let i = 0; i < 4; i++) bootp[4 + i] = req[4 + i]; // xid, echoed verbatim
  if (type !== 6) for (let i = 0; i < 4; i++) bootp[16 + i] = offeredIp[i]; // yiaddr (not on NAK)
  for (let i = 0; i < 4; i++) bootp[20 + i] = serverIp[i]; // siaddr
  for (let i = 0; i < 6; i++) bootp[28 + i] = req[28 + i]; // chaddr
  bootp[236] = 0x63; bootp[237] = 0x82; bootp[238] = 0x53; bootp[239] = 0x63;
  const opts = [53, 1, type, 54, 4, ...serverIp];
  if (type !== 6) {
    const dnsList = dns2 ? [...dns1, ...dns2] : [...dns1];
    opts.push(1, 4, ...mask, 3, 4, ...router, 6, dnsList.length, ...dnsList);
    const leaseBytes = [(lease >>> 24) & 255, (lease >>> 16) & 255, (lease >>> 8) & 255, lease & 255];
    opts.push(51, 4, ...leaseBytes);
  }
  opts.push(255);
  const body = [...bootp, ...opts];
  return buildUdpReply(datagram, body, {
    sourcePort: 67, destinationPort: 68, mac: serverMac, ip: serverIp,
    destinationIp: [255, 255, 255, 255],
  });
}

// ---------------------------------------------------------------------
// TFTP (RFC 1350 + RFC 2347 blksize option). src/apps/tftp.asm always
// requests blksize=1428 on both RRQ and WRQ; a server may OACK a smaller
// value (>=8) or ignore the option (RFC-1350 512-byte fallback). State is
// kept on the responders.tftp object itself, mutated across calls.
// ---------------------------------------------------------------------
const TFTP_OP_RRQ = 1, TFTP_OP_WRQ = 2, TFTP_OP_DATA = 3, TFTP_OP_ACK = 4, TFTP_OP_ERROR = 5, TFTP_OP_OACK = 6;

function tftpReadCString(bytes, start) {
  let end = bytes.indexOf(0, start);
  if (end < 0) end = bytes.length;
  return { text: Buffer.from(bytes.slice(start, end)).toString('ascii'), next: end + 1 };
}

function respondTftp(datagram, card, tftp) {
  const opcode = datagram.payload.length >= 2 ? (datagram.payload[0] << 8) | datagram.payload[1] : 0;
  const serverListenPort = tftp.port || 69;
  const session = tftp._session;
  const fromKnownSession = session && datagram.destPort === session.serverPort;
  if (!fromKnownSession && datagram.destPort !== serverListenPort) return;

  const files = tftp.files || {};
  const findFile = (name) => {
    const key = Object.keys(files).find((k) => k.toUpperCase() === name.toUpperCase());
    return key === undefined ? null : (Buffer.isBuffer(files[key]) ? files[key] : Buffer.from(files[key]));
  };
  const serverPort = tftp.serverPort || 0xbeef;
  const blockSizeDefault = 512;
  const negotiated = tftp.oackBlksize; // undefined -> ignore option, RFC-1350 fallback

  const send = (body) => {
    const reply = buildUdpReply(datagram, body, { sourcePort: tftp._session ? tftp._session.serverPort : serverPort, mac: tftp.mac });
    card.generated.push(reply);
    card.schedule(tftp.afterMs ?? 1, reply);
  };

  if (opcode === TFTP_OP_RRQ || opcode === TFTP_OP_WRQ) {
    const { text: name, next } = tftpReadCString(datagram.payload, 2);
    const { next: afterMode } = tftpReadCString(datagram.payload, next);
    let cursor = afterMode, requestedBlksize;
    while (cursor < datagram.payload.length) {
      const { text: key, next: afterKey } = tftpReadCString(datagram.payload, cursor);
      if (!key) break;
      const { text: value, next: afterValue } = tftpReadCString(datagram.payload, afterKey);
      if (key.toLowerCase() === 'blksize') requestedBlksize = parseInt(value, 10);
      cursor = afterValue;
    }
    tftp._session = {
      mode: opcode === TFTP_OP_RRQ ? 'get' : 'put', name,
      blockSize: negotiated !== undefined ? negotiated : blockSizeDefault,
      serverPort, expected: 1, chunks: [],
    };
    if (opcode === TFTP_OP_RRQ) {
      const file = findFile(name);
      if (file === null) { send([0, 5, 0, 1, ...Buffer.from('File not found'), 0]); tftp._session = null; return; }
      tftp._session.file = file;
      if (negotiated !== undefined && requestedBlksize) {
        tftp._session.blockSize = negotiated;
        send([0, 6, ...Buffer.from('blksize'), 0, ...Buffer.from(String(negotiated)), 0]);
      } else {
        const start = 0, data = file.subarray(start, start + tftp._session.blockSize);
        if (data.length < tftp._session.blockSize) tftp._session.finalBlock = 1;
        send([0, 3, 0, 1, ...data]);
      }
    } else {
      if (negotiated !== undefined && requestedBlksize) {
        send([0, 6, ...Buffer.from('blksize'), 0, ...Buffer.from(String(negotiated)), 0]);
      } else {
        send([0, 4, 0, 0]);
      }
    }
    return;
  }

  if (!session) return;
  if (opcode === TFTP_OP_ACK && session.mode === 'get' && datagram.payload.length === 4) {
    const ack = (datagram.payload[2] << 8) | datagram.payload[3];
    if (session.finalBlock === ack) { tftp._session = null; return; } // transfer complete, no more replies
    const nextBlock = (ack + 1) & 0xffff;
    const start = (nextBlock - 1) * session.blockSize;
    const data = session.file.subarray(start, start + session.blockSize);
    if (data.length < session.blockSize) session.finalBlock = nextBlock;
    send([0, 3, (nextBlock >> 8) & 255, nextBlock & 255, ...data]);
    return;
  }
  if (opcode === TFTP_OP_DATA && session.mode === 'put' && datagram.payload.length >= 4) {
    const block = (datagram.payload[2] << 8) | datagram.payload[3];
    const data = Buffer.from(datagram.payload.slice(4));
    if (block === session.expected) {
      session.chunks.push(data);
      session.expected = (session.expected + 1) & 0xffff;
      if (data.length < session.blockSize) {
        tftp.uploads = tftp.uploads || {};
        tftp.uploads[session.name] = Buffer.concat(session.chunks);
      }
    }
    send([0, 4, datagram.payload[2], datagram.payload[3]]);
    return;
  }
}

// ---------------------------------------------------------------------
// TCP (src/lib/tcp_lib.asm client, single session). Server-side state is
// kept per client-port session on responders.tcp._sessions. Every client
// build sends its configured receive MSS in the SYN, TTL=64, and no DF.
// Direct clients use MSS=1460/window=2920 (two segments); multichannel UNETRTL
// uses MSS=536 and computes its window from transient caller plus durable storage.
// ---------------------------------------------------------------------
const TF_FIN = 0x01, TF_SYN = 0x02, TF_RST = 0x04, TF_PSH = 0x08, TF_ACK = 0x10;

function readU32BE(bytes, offset) {
  return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
}

function parseTcpSegment(frame) {
  if (frame.length < 34 || frame[12] !== 8 || frame[13] !== 0) return null;
  const ihl = (frame[14] & 15) * 4;
  if (frame[23] !== 6) return null; // protocol != TCP
  const tcpStart = 14 + ihl;
  const dataOffset = (frame[tcpStart + 12] >> 4) * 4;
  const ipTotalLen = (frame[16] << 8) | frame[17];
  const segEnd = 14 + ipTotalLen;
  const mss = dataOffset >= 24 && frame[tcpStart + 20] === 2 && frame[tcpStart + 21] === 4
    ? (frame[tcpStart + 22] << 8) | frame[tcpStart + 23] : undefined;
  return {
    sourceMac: frame.slice(6, 12), destMac: frame.slice(0, 6),
    sourceIp: frame.slice(26, 30), destIp: frame.slice(30, 34),
    srcPort: (frame[tcpStart] << 8) | frame[tcpStart + 1],
    dstPort: (frame[tcpStart + 2] << 8) | frame[tcpStart + 3],
    seq: readU32BE(frame, tcpStart + 4), ack: readU32BE(frame, tcpStart + 8),
    flags: frame[tcpStart + 13], window: (frame[tcpStart + 14] << 8) | frame[tcpStart + 15], mss,
    payload: Array.from(frame.slice(tcpStart + dataOffset, Math.max(segEnd, tcpStart + dataOffset))),
  };
}

function buildTcpSegment(session, opts) {
  const { flags, seq, ack, payload = [], window = 2680, mss } = opts;
  const options = mss !== undefined ? [2, 4, (mss >> 8) & 255, mss & 255] : [];
  const tcp = [
    (session.serverPort >> 8) & 255, session.serverPort & 255,
    (session.clientPort >> 8) & 255, session.clientPort & 255,
    (seq >>> 24) & 255, (seq >>> 16) & 255, (seq >>> 8) & 255, seq & 255,
    (ack >>> 24) & 255, (ack >>> 16) & 255, (ack >>> 8) & 255, ack & 255,
    (((20 + options.length) / 4) << 4) & 255, flags & 255,
    (window >> 8) & 255, window & 255,
    0, 0, 0, 0,
    ...options, ...payload,
  ];
  const tcpLen = tcp.length;
  const pseudo = [...session.serverIp, ...session.clientIp, 0, 6, (tcpLen >> 8) & 255, tcpLen & 255, ...tcp];
  const csum = checksum(pseudo);
  tcp[16] = csum >> 8; tcp[17] = csum & 255;
  const totalIpLen = 20 + tcpLen;
  const ip = [0x45, 0, (totalIpLen >> 8) & 255, totalIpLen & 255, 0, 0, 0, 0, 64, 6, 0, 0,
    ...session.serverIp, ...session.clientIp];
  putChecksum(ip, 0, 20, 10);
  return [...session.clientMac, ...session.serverMac, 8, 0, ...ip, ...tcp];
}

function buildHttpResponse(tcp) {
  const status = tcp.status || 200;
  const statusText = tcp.statusText ||
    { 200: 'OK', 206: 'Partial Content', 301: 'Moved Permanently', 404: 'Not Found', 500: 'Internal Server Error' }[status] || 'Error';
  const body = tcp.body !== undefined ? Buffer.from(tcp.body) : Buffer.alloc(0);
  const lines = [`HTTP/1.1 ${status} ${statusText}`];
  if (tcp.omitContentLength !== true && !Object.keys(tcp.headers || {}).some((k) => k.toLowerCase() === 'content-length')) {
    lines.push(`Content-Length: ${body.length}`);
  }
  for (const [k, v] of Object.entries(tcp.headers || {})) lines.push(`${k}: ${v}`);
  return Buffer.concat([Buffer.from(lines.join('\r\n') + '\r\n\r\n', 'ascii'), body]);
}

function tcpSendNextChunk(session, card, tcp) {
  // Segment server -> client data at the MSS advertised by the client SYN.
  // A test may still force tcp.mss to exercise smaller or hostile geometry.
  const mss = tcp.mss ?? session.clientMss ?? 536;
  if (session.sendOffset >= session.responseBytes.length) {
    if (!session.finSent) {
      session.finSent = true;
      const fin = buildTcpSegment(session, { flags: TF_FIN | TF_ACK, seq: session.serverSeq, ack: session.clientNext });
      card.generated.push(fin);
      card.schedule(tcp.afterMs ?? 1, fin);
    }
    return;
  }
  const chunk = session.responseBytes.subarray(session.sendOffset, session.sendOffset + mss);
  const seg = buildTcpSegment(session, {
    flags: TF_PSH | TF_ACK, seq: session.serverSeq, ack: session.clientNext, payload: Array.from(chunk),
  });
  session.serverSeq = (session.serverSeq + chunk.length) >>> 0;
  session.sendOffset += chunk.length;
  card.generated.push(seg);
  card.schedule(tcp.afterMs ?? 1, seg);
}

// Optional cumulative-ACK/window-aware deterministic stream peer. One flight
// at a time; a partial ACK replays the unacknowledged suffix (or an overlap).
// oversizeFirst deliberately violates MSS/window to test defensive reception.
function tcpReliableNext(session, card, tcp, seg) {
  const total = session.responseBytes.length;
  const acked = (seg.ack - session.responseSeq) >>> 0;
  // Ignore stale/future ACKs. Math.min() made a wrapped stale ACK look like
  // a cumulative ACK for the entire response and hid retransmission bugs.
  if (acked <= total && acked > session.ackedOffset) session.ackedOffset = acked;
  if (session.finAcked) return;
  if (session.finSent && seg.ack === ((session.responseSeq + total + 1) >>> 0)) {
    session.finAcked = true;
    return;
  }
  if (!seg.window) return;
  let start = session.ackedOffset;
  const peerMss = tcp.mss ?? session.clientMss ?? 536;
  let size = Math.min(peerMss, seg.window, total - start);
  if (!session.responseStarted && tcp.oversizeFirst) size = Math.min(total, peerMss);
  if (tcp.overlap && session.flightStart < start && start < session.flightEnd) {
    size += start - session.flightStart;
    start = session.flightStart;
    size = Math.min(size, peerMss);
  }
  const fin = start + size === total && (tcp.finWithData || !size);
  if (fin) session.finSent = true;
  session.flightStart = start;
  session.flightEnd = start + size;
  const reply = buildTcpSegment(session, {
    flags: TF_ACK | (size ? TF_PSH : 0) | (fin ? TF_FIN : 0),
    seq: (session.responseSeq + start) >>> 0,
    ack: tcp.earlyPayload && !session.responseStarted ? session.requestStart : session.clientNext,
    payload: Array.from(session.responseBytes.subarray(start, start + size)),
  });
  const delay = !session.responseStarted ? (tcp.responseDelayMs ?? 1) : (tcp.afterMs ?? 1);
  card.generated.push(reply);
  card.schedule(delay, reply);
  if (!session.responseStarted && tcp.earlyPayload) {
    const ack = buildTcpSegment(session, { flags: TF_ACK, seq: session.responseSeq, ack: session.clientNext });
    card.generated.push(ack);
    card.schedule(tcp.dataAckDelayMs ?? 80, ack);
  }
  session.responseStarted = true;
}

// streamAhead: a peer that behaves like a real bulk server (pyftpdlib, an
// HTTP server) instead of the lock-step responders above. It keeps the
// client's advertised window full -- on every ACK it emits as many MSS
// segments as the window still admits, without waiting for each one to be
// acknowledged. This is the only shape that can actually fill the NIC's
// 26-page RX ring, which is what happens in the field whenever the client
// stops draining for a while (a flush of the download buffer to disk).
// Retransmission: segments the client never acknowledges are resent once
// the RTO elapses with no forward progress, exactly as a real sender does.
function tcpStreamAhead(session, card, tcp, seg) {
  const total = session.responseBytes.length;
  const mss = tcp.mss ?? session.clientMss ?? 536;
  const window = tcp.ignoreWindow ? Infinity : (seg.window || 0);
  if (session.sentOffset === undefined) { session.sentOffset = 0; session.ackedOffset = 0; }
  const acked = (seg.ack - session.responseSeq) >>> 0;
  if (acked <= total && acked > session.ackedOffset) {
    session.ackedOffset = acked;
    session.lastProgressMs = card.currentMs;
    // Forward progress: anything still unacknowledged is in flight, not lost.
    session.rtoPending = false;
  }
  if (session.ackedOffset >= total) {
    if (!session.finSent) {
      session.finSent = true;
      const fin = buildTcpSegment(session, { flags: TF_FIN | TF_ACK, seq: (session.responseSeq + total) >>> 0, ack: session.clientNext });
      card.generated.push(fin);
      card.schedule(tcp.afterMs ?? 1, fin);
    }
    return;
  }
  // Fast retransmit: duplicate ACKs that do not advance mean the client is
  // missing the segment at ackedOffset. Rewind and resend from there.
  if (session.sentOffset > session.ackedOffset && seg.ack === session.lastAck) {
    session.dupAcks = (session.dupAcks || 0) + 1;
    if (session.dupAcks >= (tcp.dupAckRetransmit ?? 2)) { session.sentOffset = session.ackedOffset; session.dupAcks = 0; }
  } else session.dupAcks = 0;
  session.lastAck = seg.ack;
  streamEmit(session, card, tcp, mss, window, total);
}

// Emit as many segments as the window admits, strictly in order: every
// segment is scheduled after the previously scheduled one (session.nextMs),
// so overlapping bursts triggered by successive ACKs can never deliver the
// stream out of order -- a switched Ethernet path does not reorder one
// sender's stream, and pretending otherwise tests a case that cannot happen.
function streamEmit(session, card, tcp, mss, window, total) {
  let emitted = 0;
  const gap = tcp.segmentGapMs ?? 1;
  while (session.sentOffset < total &&
         (session.sentOffset - session.ackedOffset) + mss <= window &&
         emitted < (tcp.maxBurst ?? 8)) {
    const size = Math.min(mss, total - session.sentOffset);
    const payload = Array.from(session.responseBytes.subarray(session.sentOffset, session.sentOffset + size));
    const segOut = buildTcpSegment(session, {
      flags: TF_PSH | TF_ACK, seq: (session.responseSeq + session.sentOffset) >>> 0,
      ack: session.clientNext, payload,
    });
    session.sentOffset += size;
    session.nextMs = Math.max((session.nextMs ?? 0), card.currentMs + (tcp.afterMs ?? 1)) + (emitted ? gap : 0);
    card.generated.push(segOut);
    card.schedule(session.nextMs - card.currentMs, segOut);
    emitted++;
  }
  armRto(session, card, tcp, mss, window, total);
}

// Retransmission timeout: a real sender resends its oldest unacknowledged
// segment when the RTO expires without forward progress, needing nothing
// from the receiver. This is what rescues a transfer whenever the client
// legitimately drops a segment (no room in the RX ring, an out-of-order
// arrival it cannot buffer), so a model without it reports a permanent
// deadlock where real hardware recovers a moment later.
// Like a real sender (RFC 6298 / Linux), the timer backs off exponentially
// while consecutive retransmissions go unacknowledged and resets as soon as
// any progress is made; only a long run of CONSECUTIVE losses -- not a count
// over the whole transfer -- makes the peer give up. A cap on the total used
// to sit here and made the model peer fall silent part-way through any run
// with more than 20 recoveries, which no server does.
function armRto(session, card, tcp, mss, window, total) {
  if (session.rtoArmed) return;
  if (session.sentOffset <= session.ackedOffset) return;
  session.rtoArmed = true;
  const base = tcp.rtoMs ?? 200;
  const atOffset = session.ackedOffset;
  const backoff = session.backoff || 0;
  const rto = Math.min(base * (1 << backoff), tcp.rtoMaxMs ?? 60000);
  card.scheduleCallback(rto, () => {
    session.rtoArmed = false;
    if (session.ackedOffset > atOffset) { session.backoff = 0; armRto(session, card, tcp, mss, window, total); return; }
    if (session.ackedOffset >= total) return;
    session.retransmits = (session.retransmits || 0) + 1;
    session.backoff = backoff + 1;
    if (session.backoff > (tcp.maxRetransmits ?? 15)) return;
    session.sentOffset = session.ackedOffset;   // go back to the last acked byte
    session.nextMs = card.currentMs;
    // RTO collapses the congestion window to one segment: only the oldest
    // unacknowledged segment is resent, and the window refills once it is
    // acknowledged. Re-emitting the whole window here doubled the ring
    // pressure of every timeout, which real senders never do.
    streamEmit(session, card, { ...tcp, maxBurst: 1 }, mss, window, total);
  });
}

// ---------------------------------------------------------------------
// FTP server: a passive-mode peer with TWO concurrent TCP sessions, which
// is the shape no other responder here produces. FTP.EXE multiplexes a
// control and a data connection through ONE set of TCP state variables
// (SAVE_CTX/RESTORE_CTX), and while it is draining the data session every
// control-session frame that arrives is filtered out and dropped. Nothing
// else in the kit exercises that, so the whole class of two-session
// interference bugs was invisible to the test suite.
//
// Control port 21 speaks the minimal dialogue FTP.EXE drives: greeting,
// USER/PASS, TYPE, SIZE, PASV, RETR, QUIT. The data connection streams the
// file with the same window-filling sender and RTO timer as streamAhead.
// ---------------------------------------------------------------------
function ftpReply(session, card, ftp, text) {
  const bytes = Buffer.from(text + '\r\n', 'latin1');
  const seg = buildTcpSegment(session, {
    flags: TF_PSH | TF_ACK, seq: session.serverSeq, ack: session.clientNext,
    payload: Array.from(bytes),
  });
  session.serverSeq = (session.serverSeq + bytes.length) >>> 0;
  card.generated.push(seg);
  card.schedule(ftp.afterMs ?? 1, seg);
}

function ftpStartData(card, ftp) {
  const session = ftp._dataSession;
  if (!session || !ftp._retrIssued || session.streaming) return;
  session.streaming = true;
  session.responseBytes = ftp._fileBytes;
  session.responseSeq = session.serverSeq;
  session.sentOffset = 0;
  session.ackedOffset = 0;
  streamEmit(session, card, ftp, ftp.mss ?? session.clientMss ?? 1460,
    ftp.ignoreWindow ? Infinity : (session.lastWindow || 2920), session.responseBytes.length);
}

function respondFtp(frame, card, ftp) {
  const seg = parseTcpSegment(frame);
  if (!seg) return;
  ftp._sessions = ftp._sessions || {};
  ftp._fileBytes = ftp._fileBytes ||
    (Buffer.isBuffer(ftp.file) ? ftp.file : Buffer.from(ftp.file ?? '', 'latin1'));
  ftp._pasvPort = ftp._pasvPort ?? (ftp.pasvPort ?? 55797);
  const isControl = seg.dstPort === (ftp.port ?? 21);
  let session = ftp._sessions[seg.srcPort];

  if (seg.flags === TF_SYN) {
    const isn = (ftp.isn ?? 0x20000000) + (isControl ? 0 : 0x1000);
    session = ftp._sessions[seg.srcPort] = {
      clientMac: seg.sourceMac, clientIp: seg.sourceIp, clientPort: seg.srcPort,
      serverMac: ftp.mac || DEFAULT_SERVER_MAC, serverIp: seg.destIp, serverPort: seg.dstPort,
      serverSeq: isn, clientNext: (seg.seq + 1) >>> 0, clientMss: seg.mss,
      control: isControl, state: 'syn-rcvd',
    };
    const synAck = buildTcpSegment(session, { flags: TF_SYN | TF_ACK, seq: isn, ack: session.clientNext, mss: ftp.mss ?? 1460 });
    card.generated.push(synAck);
    card.schedule(ftp.afterMs ?? 1, synAck);
    return;
  }
  if (!session) return;
  if (seg.flags & TF_RST) { session.state = 'closed'; return; }
  session.lastWindow = seg.window;

  if (session.state === 'syn-rcvd' && (seg.flags & TF_ACK) && !seg.payload.length) {
    session.state = 'established';
    session.serverSeq = (session.serverSeq + 1) >>> 0;
    if (session.control) ftpReply(session, card, ftp, ftp.greeting ?? '220 harness FTP server ready.');
    else { ftp._dataSession = session; ftpStartData(card, ftp); }
    return;
  }

  if (!session.control) {
    // Data connection: pure streaming, plus the 226 once the client has
    // acknowledged everything (the server closes the data connection first).
    if (session.streaming && !(seg.flags & TF_FIN)) {
      tcpStreamAhead(session, card, ftp, seg);
      if (session.finSent && !ftp._sent226 && session.ackedOffset >= session.responseBytes.length) {
        ftp._sent226 = true;
        const ctrl = Object.values(ftp._sessions).find((s) => s.control);
        if (ctrl) ftpReply(ctrl, card, ftp, '226 Transfer complete.');
      }
    }
    return;
  }

  // Control connection: parse whole command lines.
  if (seg.payload.length) {
    if (seg.seq === session.clientNext) {
      session.clientNext = (seg.seq + seg.payload.length) >>> 0;
      session.request = Buffer.concat([session.request || Buffer.alloc(0), Buffer.from(seg.payload)]);
    }
    const ack = buildTcpSegment(session, { flags: TF_ACK, seq: session.serverSeq, ack: session.clientNext });
    card.generated.push(ack);
    card.schedule(ftp.dataAckDelayMs ?? 1, ack);

    let text = (session.request || Buffer.alloc(0)).toString('latin1');
    while (text.includes('\r\n')) {
      const line = text.slice(0, text.indexOf('\r\n'));
      text = text.slice(text.indexOf('\r\n') + 2);
      const verb = line.split(' ')[0].toUpperCase();
      ftp.commands = ftp.commands || [];
      ftp.commands.push(line);
      if (verb === 'USER') ftpReply(session, card, ftp, '331 Guest login ok, send your email address as password.');
      else if (verb === 'PASS') ftpReply(session, card, ftp, '230 Guest login ok, access restrictions apply.');
      else if (verb === 'TYPE') ftpReply(session, card, ftp, '200 Type set to I.');
      else if (verb === 'SIZE') ftpReply(session, card, ftp, `213 ${ftp._fileBytes.length}`);
      else if (verb === 'PASV') {
        const p = ftp._pasvPort, ip = session.serverIp;
        ftpReply(session, card, ftp, `227 Entering Passive Mode (${ip[0]},${ip[1]},${ip[2]},${ip[3]},${p >> 8},${p & 255})`);
      } else if (verb === 'RETR') {
        ftpReply(session, card, ftp, `150 Opening BINARY mode data connection for '${line.slice(5)}' (${ftp._fileBytes.length} bytes).`);
        ftp._retrIssued = true;
        ftpStartData(card, ftp);
      } else if (verb === 'LIST' || verb === 'NLST') {
        // A listing is streamed over the same data connection; the client
        // prints it straight to the console instead of writing a file.
        ftp._fileBytes = Buffer.from(ftp.listing ??
          '-rw-r--r--   1 root  wheel     2048 May  6 15:28 2k.bin\r\n' +
          '-rw-r--r--   1 root  wheel   389579 May  6 15:28 im2.txt\r\n', 'latin1');
        ftpReply(session, card, ftp, '150 Opening ASCII mode data connection for file list.');
        ftp._retrIssued = true;
        ftpStartData(card, ftp);
      } else if (verb === 'QUIT') ftpReply(session, card, ftp, '221 Goodbye.');
      else ftpReply(session, card, ftp, '200 ok.');
    }
    session.request = Buffer.from(text, 'latin1');
  }
}

function respondTcp(frame, card, tcp) {
  const seg = parseTcpSegment(frame);
  if (!seg) return;
  tcp._sessions = tcp._sessions || {};
  let session = tcp._sessions[seg.srcPort];

  if (seg.flags === TF_SYN) { // new connection attempt
    if (tcp.mode === 'drop' || tcp.mode === 'refuse') {
      if (tcp.mode === 'refuse') {
        const rst = buildTcpSegment({
          clientMac: seg.sourceMac, clientIp: seg.sourceIp, clientPort: seg.srcPort,
          serverMac: tcp.mac || DEFAULT_SERVER_MAC, serverIp: seg.destIp, serverPort: seg.dstPort,
        }, { flags: TF_RST | TF_ACK, seq: 0, ack: (seg.seq + 1) >>> 0 });
        card.generated.push(rst);
        card.schedule(tcp.afterMs ?? 1, rst);
      }
      return;
    }
    const isn = tcp.isn !== undefined ? tcp.isn >>> 0 : 0x12345678;
    session = tcp._sessions[seg.srcPort] = {
      clientMac: seg.sourceMac, clientIp: seg.sourceIp, clientPort: seg.srcPort,
      serverMac: tcp.mac || DEFAULT_SERVER_MAC, serverIp: seg.destIp, serverPort: seg.dstPort,
      state: 'syn-rcvd', serverSeq: isn, clientNext: (seg.seq + 1) >>> 0,
      clientMss: seg.mss, sendOffset: 0, finSent: false,
    };
    const synAck = buildTcpSegment(session, { flags: TF_SYN | TF_ACK, seq: isn, ack: session.clientNext, mss: tcp.mss ?? 536 });
    card.generated.push(synAck);
    card.schedule(tcp.afterMs ?? 1, synAck);
    return;
  }

  if (!session) return;
  if (seg.flags & TF_RST) {
    // A hardened (RFC 5961) peer honours a RST only at exactly RCV.NXT;
    // anything else in the window earns a challenge ACK and nothing more.
    // Record every RST either way so a test can assert which sequence
    // numbers the client reset at.
    (session.resets = session.resets || []).push(seg.seq >>> 0);
    if (seg.seq === session.clientNext) { session.state = 'closed'; session.aborted = true; }
    return;
  }
  if (seg.flags & TF_FIN) {
    session.finsSeen = (session.finsSeen || 0) + 1;
    // Only an in-sequence FIN is end-of-stream. Below RCV.NXT it is an old
    // duplicate; above it, it leaves a hole and the peer keeps waiting for
    // the missing bytes -- which is precisely the failure a rewound close
    // produces, so the model has to reproduce both.
    if (seg.seq === session.clientNext) {
      session.eof = true;
      session.clientNext = (seg.seq + seg.payload.length + 1) >>> 0;
    }
    // dropFinAcks: swallow the first N acknowledgements so a test can check
    // that the client retransmits its FIN instead of assuming delivery.
    if ((session.finsSeen || 0) > (tcp.dropFinAcks ?? 0)) {
      const finAck = buildTcpSegment(session, { flags: TF_ACK, seq: session.serverSeq, ack: session.clientNext });
      card.generated.push(finAck);
      card.schedule(tcp.afterMs ?? 1, finAck);
    }
    return;
  }

  if (session.state === 'syn-rcvd' && (seg.flags & TF_ACK) && seg.payload.length === 0) {
    session.state = 'established';
    session.serverSeq = (session.serverSeq + 1) >>> 0; // our SYN consumed one sequence number
    // tcp.greeting: bytes the server pushes the moment the handshake closes,
    // before the client has sent anything -- what every IRC server does with
    // its "NOTICE AUTH :*** Looking up your hostname" banner. It makes the
    // client's first SEND wait for its ACK while unsolicited peer data with a
    // LOWER ack number arrives first, which is the full-duplex case a
    // request/response peer never produces.
    // greeting is one line or a list of them; greetingMs is the spacing, so a
    // list models a server still talking while the client's own first lines
    // are waiting for their ACKs.
    const greetingLines = tcp.greeting ? [].concat(tcp.greeting) : [];
    greetingLines.forEach((line, index) => {
      const bytes = Buffer.from(line, 'latin1');
      const seg2 = buildTcpSegment(session, {
        flags: TF_PSH | TF_ACK, seq: session.serverSeq, ack: session.clientNext,
        payload: Array.from(bytes),
      });
      session.serverSeq = (session.serverSeq + bytes.length) >>> 0;
      card.generated.push(seg2);
      card.schedule((tcp.greetingMs ?? 1) * (index + 1), seg2);
    });
    return;
  }

  if (tcp.streamAhead) {
    if (seg.payload.length) {
      if (seg.seq === session.clientNext) {
        session.clientNext = (seg.seq + seg.payload.length) >>> 0;
        session.request = Buffer.concat([session.request || Buffer.alloc(0), Buffer.from(seg.payload)]);
      }
      if (!session.responseBytes && session.request?.includes('\r\n\r\n')) {
        session.responseBytes = buildHttpResponse(tcp);
        session.responseSeq = session.serverSeq;
      }
      const ack = buildTcpSegment(session, { flags: TF_ACK, seq: session.serverSeq, ack: session.clientNext });
      card.generated.push(ack);
      card.schedule(tcp.dataAckDelayMs ?? 1, ack);
    }
    if (session.responseBytes && !(seg.flags & TF_FIN)) tcpStreamAhead(session, card, tcp, seg);
    return;
  }

  if (tcp.reliableResponse) {
    if (seg.payload.length) {
      if (seg.seq === session.clientNext) {
        session.requestStart = seg.seq;
        session.clientNext = (seg.seq + seg.payload.length) >>> 0;
        session.request = Buffer.concat([session.request || Buffer.alloc(0), Buffer.from(seg.payload)]);
      }
      if (!session.responseBytes && session.request?.includes('\r\n\r\n')) {
        session.responseBytes = buildHttpResponse(tcp);
        session.responseSeq = session.serverSeq;
        session.ackedOffset = 0;
      }
      if (!tcp.combinedAck || !session.responseBytes) {
        const ack = buildTcpSegment(session, { flags: TF_ACK, seq: session.serverSeq, ack: session.clientNext });
        card.generated.push(ack);
        card.schedule(tcp.dataAckDelayMs ?? 1, ack);
      }
    }
    if (session.responseBytes && !(seg.flags & TF_FIN)) tcpReliableNext(session, card, tcp, seg);
    return;
  }

  if (seg.payload.length > 0) {
    session.clientNext = (seg.seq + seg.payload.length) >>> 0;
    session.request = Buffer.concat([session.request || Buffer.alloc(0), Buffer.from(seg.payload)]);
    if (!session.responseBytes && session.request.includes('\r\n\r\n')) {
      session.responseBytes = buildHttpResponse(tcp);
    }
    if (!tcp.dropDataAck) {
      const ack = buildTcpSegment(session, { flags: TF_ACK, seq: session.serverSeq, ack: session.clientNext });
      card.generated.push(ack);
      card.schedule(tcp.afterMs ?? 1, ack);
    }
    if (session.responseBytes) tcpSendNextChunk(session, card, tcp);
    return;
  }

  if (seg.flags & TF_ACK && seg.payload.length === 0) {
    if (session.responseBytes) tcpSendNextChunk(session, card, tcp);
  }
}

// ---------------------------------------------------------------------
// Top-level dispatcher: called by the RTL8019 model whenever the driver
// actually transmits a frame. Reads scenario.responders and schedules
// replies via card.schedule(delayMs, bytes). Keeps rtl8019-model.js
// protocol-agnostic.
// ---------------------------------------------------------------------
function respond(frame, card, scenario) {
  const responders = scenario.responders || {};
  const record = (bytes) => { card.generated.push(bytes); return bytes; };

  if (responders.arp && isArpRequest(frame)) {
    const arp = responders.arp;
    arp._count = (arp._count || 0) + 1;
    if ((arp.drop || 0) >= arp._count || arp.mode === 'drop') return;
    const reply = record(buildArpReply(frame, arp));
    card.schedule(arp.afterMs ?? 1, reply);
    return;
  }

  // Only claim frames that really are TCP.  This branch used to swallow
  // every non-ARP frame whenever a tcp responder was configured, which
  // made it impossible to combine `tcp` with `dns` (or any other UDP
  // responder) in one scenario -- and WGET resolving a hostname before
  // opening its HTTP session needs exactly that combination.
  if (responders.ftp && parseTcpSegment(frame)) {
    respondFtp(frame, card, responders.ftp);
    return;
  }

  if (responders.tcp && parseTcpSegment(frame)) {
    respondTcp(frame, card, responders.tcp);
    return;
  }

  const echo = icmpEchoRequest(frame);
  if (responders.icmp && echo) {
    const icmp = responders.icmp;
    icmp._count = (icmp._count || 0) + 1;
    if ((icmp.drop || 0) >= icmp._count || icmp.mode === 'drop') return;
    const reply = icmp.mode === 'unreachable'
      ? record(buildIcmpUnreachable(frame, echo, icmp))
      : record(buildIcmpReply(frame, echo, icmp));
    card.schedule(icmp.afterMs ?? 1, reply);
    return;
  }

  const datagram = udpDatagram(frame);
  if (responders.dhcp && datagram && datagram.destPort === 67 && isDhcpMessage(datagram.payload)) {
    const dhcp = responders.dhcp;
    const type = dhcpMsgType(datagram.payload);
    const isDiscover = type === 1, isRequest = type === 3;
    if (!isDiscover && !isRequest) return;
    const countKey = isDiscover ? '_discoverCount' : '_requestCount';
    dhcp[countKey] = (dhcp[countKey] || 0) + 1;
    const dropKey = isDiscover ? 'dropDiscover' : 'dropRequest';
    if ((dhcp[dropKey] || 0) >= dhcp[countKey] || dhcp.mode === 'drop') return;
    const replyType = isDiscover ? 2 : (dhcp.mode === 'nak' ? 6 : 5);
    const reply = record(buildDhcpReply(datagram, replyType, dhcp));
    card.schedule(dhcp.afterMs ?? 1, reply);
    return;
  }

  if (responders.dns && datagram && datagram.destPort === 53) {
    const dns = responders.dns;
    dns._count = (dns._count || 0) + 1;
    if ((dns.drop || 0) >= dns._count || dns.mode === 'drop') return;
    const reply = record(buildDnsResponse(datagram, dns));
    card.schedule(dns.afterMs ?? 1, reply);
    return;
  }

  if (responders.ntp && datagram && datagram.destPort === 123) {
    const ntp = responders.ntp;
    ntp._count = (ntp._count || 0) + 1;
    if ((ntp.drop || 0) >= ntp._count || ntp.mode === 'drop') return;
    const reply = record(buildNtpResponse(datagram, ntp));
    card.schedule(ntp.afterMs ?? 1, reply);
    return;
  }

  if (responders.tftp && datagram) { respondTftp(datagram, card, responders.tftp); return; }

  if (responders.udp && datagram &&
      (!responders.udp.port || datagram.destPort === responders.udp.port)) {
    const udp = responders.udp;
    udp._count = (udp._count || 0) + 1;
    if ((udp.drop || 0) >= udp._count || udp.mode === 'drop') return;
    const payload = udp.payload !== undefined ? udp.payload : datagram.payload;
    const reply = record(buildUdpReply(datagram, payload, udp));
    card.schedule(udp.afterMs ?? 1, reply);
    return;
  }
}

module.exports = {
  checksum, putChecksum, padTo60,
  isArpRequest, buildArpReply, buildArpRequest,
  icmpEchoRequest, buildIcmpReply, buildIcmpUnreachable,
  udpDatagram, buildUdpReply,
  parseDhcpOptions, isDhcpMessage, dhcpMsgType, buildDhcpReply,
  parseDnsQuery, buildDnsResponse,
  buildNtpResponse,
  respondTftp,
  parseTcpSegment, buildTcpSegment, buildHttpResponse, respondTcp, respondFtp,
  respond,
  DEFAULT_SERVER_MAC, BROADCAST_MAC,
};
