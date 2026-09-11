// Actual libman consumer for deterministic public-ABI fault/ordering vectors.
// Each command is assembled into the EXE; no TCP or DLL routine is mocked.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { runExe } = require('./harness');
const root = path.resolve(__dirname, '../..');
function symbols(file) {
  return Object.fromEntries(fs.readFileSync(file, 'utf8').trim().split('\n').flatMap(line => {
    const m = line.match(/^(\S+): EQU 0x([0-9A-F]+)/i);
    return m ? [[m[1], parseInt(m[2], 16)]] : [];
  }));
}
function probe(commands, scenario, setupPeer, dllWindow = 1) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'unet-rx-'));
  try {
    let asm = ` DEVICE NOSLOT64K
 INCLUDE "dss.inc"
 INCLUDE "unet.inc"
 ORG 0x8080
 DB "EXE",1
 DW 128,0,0,0,0,0,START,START,0xBFFF
 DS 106,0
 ORG 0x8100
START
 LD HL,DLL_NAME
 LD A,1
 CALL LIBMAN.l_load
 JP C,FAIL
 LD (HANDLE),HL
${commands.map((c, i) => ` LD A,${c.a || 0}
 LD DE,${c.de || 0}
 LD IX,${c.ix || 0}
 LD IY,${c.iy || 0}
 LD B,${c.fn}
 LD HL,(HANDLE)
 CALL LIBMAN.l_call
PROBE_${i}
 NOP`).join('\n')}
 LD HL,(HANDLE)
 CALL LIBMAN.l_free
 LD B,0
 JR EXIT
FAIL
 LD B,3
EXIT
 LD C,DSS_EXIT
 RST DSS
DLL_NAME DB "UNETRTL.DLL",0
HOST DB "192.168.7.1",0
PORT DB "8080",0
PORT2 DB "8081",0
PAYLOAD DB "request"
 INCLUDE "libman13.asm"
 ASSERT $ < 0xA000
HANDLE EQU 0xA000
BUFFER EQU 0xA100
`;
    if (dllWindow === 2) asm = asm.replaceAll('0x8080', '0x4080').replaceAll('0x8100', '0x4100').replaceAll('0xBFFF', '0x7FFF').replaceAll('0xA000', '0x6000').replaceAll('0xA100', '0x6100').replace(' LD A,1\n CALL LIBMAN.l_load', ' LD A,2\n CALL LIBMAN.l_load');
    const dllBase = dllWindow * 0x4000 + 0x20;
    fs.writeFileSync(path.join(tmp, 'probe.asm'), asm);
    const assemble = (source, raw, sym) => execFileSync('sjasmplus', ['--nologo', '-I', path.join(root, 'src/include'), '-I', path.join(root, 'src/lib'), `--raw=${raw}`, `--sym=${sym}`, source], { stdio: 'pipe' });
    assemble(path.join(tmp, 'probe.asm'), path.join(tmp, 'probe.EXE'), path.join(tmp, 'probe.sym'));
    assemble(path.join(root, 'src/dll/unetrtl.asm'), path.join(tmp, 'dll.bin'), path.join(tmp, 'dll.sym'));
    const syms = symbols(path.join(tmp, 'probe.sym'));
    const dll = symbols(path.join(tmp, 'dll.sym'));
    const events = [], results = [], cpuProbes = {};
    const snapshot = (ctx, label) => {
      const byte = name => ctx.read(dll[name] + dllBase);
      const word = name => byte(name) | (ctx.read(dll[name] + dllBase + 1) << 8);
      const seq = name => Array.from({ length: 4 }, (_, i) => ctx.read(dll[name] + dllBase + i)).reduce((n, v) => (n * 256 + v) >>> 0, 0);
      events.push({ label, ms: ctx.logicalMs, channel: byte('UNET.ACTIVE_CH'),
        seq: seq('TCP_RCV_NXT'), ack: seq('TCP_SND_UNA'), window: byte('TCP_ADV_WIN_HI') * 256 + byte('TCP_ADV_WIN_LO'),
        ackWait: byte('TCP_ACK_WAIT_STATE'), rxLength: word('TCP_RX_DATA_LEN'),
        pending: [word('MAIN.CH_PEND_LEN'), ctx.read(dll['MAIN.CH_PEND_LEN'] + dllBase + 2) | ctx.read(dll['MAIN.CH_PEND_LEN'] + dllBase + 3) << 8],
        lost: [byte('MAIN.CH_LOST'), ctx.read(dll['MAIN.CH_LOST'] + dllBase + 1)],
      });
    };
    for (const name of ['UNET.F_SEND', 'UNET.F_RECV', 'UNET.STORE_TCP_PAYLOAD']) {
      cpuProbes[dll[name] + dllBase] = ctx => {
        snapshot(ctx, name);
        const ret = ctx.read(ctx.state.sp) | ctx.read(ctx.state.sp + 1) << 8;
        const old = cpuProbes[ret];
        cpuProbes[ret] = c => { cpuProbes[ret] = old; snapshot(c, `${name}:return`); old?.(c); };
      };
    }
    cpuProbes[syms.START] = ({ card }) => setupPeer?.(card);
    commands.forEach((command, i) => {
      cpuProbes[syms[`PROBE_${i}`]] = ctx => {
        const s = ctx.state;
        const result = { a: s.a, de: s.d * 256 + s.e, ix: s.ix, data: Buffer.from(Array.from({ length: Math.min(s.d * 256 + s.e, 2048) }, (_, j) => ctx.read(syms.BUFFER + j))) };
        results.push(result);
        events.push({ label: `ABI ${command.fn} #${i}`, ms: ctx.logicalMs, a: result.a, de: result.de, ix: result.ix });
        command.after?.(ctx, result);
      };
    });
    const r = runExe(path.join(tmp, 'probe.EXE'), '', { ...scenario, cpuProbes });
    if (process.env.UNET_TRACE) fs.appendFileSync(process.env.UNET_TRACE, JSON.stringify({ dllWindow, events, results, transmittedFrames: r.transmittedFrames }) + '\n');
    return { ...r, events, results };
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
}
module.exports = { probe };
