// Execute a real Sprinter DSS EXE against strict DSS/ISA/RTL8019AS models.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const fs = require('fs');
global.window = {};
const Z80 = require('./Z80core.js');
const { Rtl8019 } = require('./rtl8019-model.js');
const netBuilders = require('./net-builders.js');

const u16 = (buf, off) => buf[off] | (buf[off + 1] << 8);
const hex = (bytes) => Buffer.from(bytes).toString('hex');

function normalizeFrame(frame) {
  if (typeof frame === 'string') return Array.from(Buffer.from(frame.replace(/[^0-9a-f]/gi, ''), 'hex'));
  return Array.from(frame);
}

// Opcode pattern of util.asm's DELAY_1MS inner loop:
//   .L1: DEC BC / LD A,B / OR C / JR NZ,.L1
// matched at the loop TOP (not the initial LD BC,400), so it fires once per
// pass through the loop regardless of which call site reached it.
function isDelayLoopTop(rd, pc) {
  return rd(pc) === 0x0b && rd(pc + 1) === 0x78 && rd(pc + 2) === 0xb1 &&
    rd(pc + 3) === 0x20 && rd(pc + 4) === 0xfb;
}

function runExe(exePath, args = '', inputScenario = {}) {
  const scenario = { ...inputScenario };
  scenario.rxFrames = (scenario.rxFrames || []).map((f) => (
    f && typeof f === 'object' && !Array.isArray(f) && typeof f !== 'string'
      ? { bytes: normalizeFrame(f.bytes), afterMs: f.afterMs || 0 }
      : { bytes: normalizeFrame(f), afterMs: 0 }
  ));

  const exe = fs.readFileSync(exePath);
  if (exe.length <= 128 || exe.toString('ascii', 0, 3) !== 'EXE' || exe[3] !== 1) {
    throw new Error('invalid DSS EXE header');
  }
  const headerSize = u16(exe, 4), entry = u16(exe, 16), entry2 = u16(exe, 18), stack = u16(exe, 20);
  if (headerSize !== 128 && headerSize !== 256 && headerSize !== 512) {
    throw new Error(`unsupported DSS EXE header size ${headerSize}`);
  }
  if (entry !== entry2) throw new Error('unsupported DSS EXE header layout (entry mismatch)');
  // PRELOAD (win0_exe.py, OFFCOD=512): LOADER (u16 at offset 8) is the size of
  // a stage-1 loader placed at `entry`, DSS loads ONLY that loader and leaves
  // the .EXE file open positioned right after it -- the loader itself streams
  // the rest (a size table + up to 3 window blobs) via DSS_READ. See the
  // SprinTalk port plan's win0 migration and lib/win0/loader.c.
  const loaderSize = u16(exe, 8);
  const loadAddress = entry - headerSize;
  const residentLength = loaderSize > 0 ? headerSize + loaderSize : exe.length;
  if (loadAddress < 0 || loadAddress + residentLength > 0x10000) {
    throw new Error('EXE image does not fit in the 64K address space');
  }

  // ---- paged memory: 1 MB backing store, 4 x 16 KB windows ----
  const mem = new Uint8Array(0x100000);
  if (scenario.poison !== false) mem.fill(0xaa);
  const win = [0, 1, 2, 3];
  const lin = (a) => win[(a >> 14) & 3] * 0x4000 + (a & 0x3fff);

  const card = new Rtl8019(scenario);
  if (scenario.responders) card.onTransmit = (frame) => netBuilders.respond(frame, card, scenario);
  let systemIsa = false, isaOpen = false, selectedSlot = 0;
  // Simulated keyboard input: `key` delivers one key, `keys` a sequence on
  // successive SCANKEY pops (SprinTalk needs two ESCs to quit, for one).
  // An entry is a name ('escape', 'ctrl-c', 'enter', 'backspace', 'tab') or a
  // literal string, which expands to one keypress per character -- so a test
  // can type a command line and press Enter.
  const NAMED_KEYS = {
    escape: [0, 1, 0x1b], 'ctrl-c': [0x20, 0xac, 0], enter: [0, 0, 0x0d],
    backspace: [0, 0, 0x08], tab: [0, 0x0f, 0x09],
  };
  const expandKey = (k) => (NAMED_KEYS[k] || k.length === 1 ? [k] : [...k]);
  const keyQueue = (scenario.keys ? scenario.keys.flatMap(expandKey)
    : (scenario.key ? [scenario.key] : []));
  const loadKeyRegs = (s, name) => {
    const named = NAMED_KEYS[name];
    if (named) { [s.b, s.d, s.e] = named; }
    else if (typeof name === 'string' && name.length === 1) { s.b = 0; s.d = 0; s.e = name.charCodeAt(0); }
    else throw new Error(`unknown simulated key ${name}`);
    s.a = s.e;
  };
  const closedChipAccesses = [];
  const chipTrace = [];
  // Off by default: the chip is only ever reachable through the isaOpen-gated
  // path below (by construction), so a closed-window access at this address
  // is never a "forgot to open ISA" bug -- it is ordinary window-3 DSS paged
  // memory (e.g. libman's DLL loader legitimately SETWIN3's a scratch block
  // to this same physical range). closedChipAccesses is still recorded for
  // callers that want to inspect it; strictClosedChipAccess:true opts in to
  // throwing, for a scenario that specifically wants to assert nothing else
  // ever shares this address range.
  const strictClosedChipAccess = scenario.strictClosedChipAccess === true;

  const cardWindowOffset = (address) => address - (0xc000 + card.base);

  const rd = (address) => {
    address &= 0xffff;
    if (address >= 0xc000) {
      const off = cardWindowOffset(address);
      const inChipAperture = off >= 0 && off < 0x20;
      if (isaOpen) {
        if (scenario.traceChip) chipTrace.push({ cycles, pc: cpu.getState().pc, address, dir: 'read' });
        if (inChipAperture) {
          if (cpu.getState().iff1) {
            throw new Error(`interrupts enabled (IFF1=1) during chip access at PC=${cpu.getState().pc.toString(16)}`);
          }
          if (selectedSlot === card.slot && card.present) return card.readReg(off, cycles);
          return card.quirks.openBusValue;
        }
        return card.quirks.openBusValue;
      }
      if (inChipAperture) {
        closedChipAccesses.push({ address, pc: cpu.getState().pc, dir: 'read' });
        if (strictClosedChipAccess) {
          throw new Error(`chip aperture read at 0x${address.toString(16)} with ISA window CLOSED (PC=${cpu.getState().pc.toString(16)})`);
        }
      }
    }
    return mem[lin(address)];
  };
  const wr = (address, value) => {
    address &= 0xffff; value &= 0xff;
    if (address >= 0xc000) {
      const off = cardWindowOffset(address);
      const inChipAperture = off >= 0 && off < 0x20;
      if (isaOpen) {
        if (scenario.traceChip) chipTrace.push({ cycles, pc: cpu.getState().pc, address, dir: 'write', value });
        if (inChipAperture) {
          if (cpu.getState().iff1) {
            throw new Error(`interrupts enabled (IFF1=1) during chip access at PC=${cpu.getState().pc.toString(16)}`);
          }
          if (selectedSlot === card.slot && card.present) card.writeReg(off, value, cycles);
          return;
        }
        return;
      }
      if (inChipAperture) {
        closedChipAccesses.push({ address, pc: cpu.getState().pc, dir: 'write' });
        if (strictClosedChipAccess) {
          throw new Error(`chip aperture write at 0x${address.toString(16)} with ISA window CLOSED (PC=${cpu.getState().pc.toString(16)})`);
        }
      }
    }
    mem[lin(address)] = value;
  };

  // scenario.dumpAt: {label: address} -- read as a 16-bit LE word whenever a
  // debugging build wants ad-hoc visibility into specific globals at the
  // moment of a crash (any of the "unknown ..." throws below). Debugging aid
  // only; empty/absent in every normal scenario.
  const dumpAtStr = () => Object.entries(scenario.dumpAt || {})
    .map(([k, a]) => `${k}=0x${(rd(a) | (rd((a + 1) & 0xffff) << 8)).toString(16)}`).join(' ');

  for (let i = 0; i < residentLength; i++) mem[lin(loadAddress + i)] = exe[i];

  const cpu = new Z80({
    mem_read: rd,
    mem_write: wr,
    io_read: (port) => {
      port &= 0xffff;
      // MMU ports are decoded by the LOW byte only on real Sprinter hardware;
      // the short Z80 form `IN A,(n)` drives the CURRENT A on the high
      // address byte (port = A<<8 | n), so the high byte varies with
      // whatever A happened to hold and must be ignored here.
      const lowPort = port & 0xff;
      if (lowPort === 0x82) return win[0] & 0xff;
      if (lowPort === 0xa2) return win[1] & 0xff;
      if (lowPort === 0xc2) return win[2] & 0xff;
      if (lowPort === 0xe2) return win[3] & 0xff;
      throw new Error(`unknown I/O read ${port.toString(16)} PC=0x${cpu.getState().pc.toString(16)} ${dumpAtStr()} ` +
        `trace=${pcTrace.map((v) => v.toString(16)).join(',')}`);
    },
    io_write: (port, value) => {
      port &= 0xffff; value &= 0xff;
      // Same low-byte decode as io_read above -- `OUT (n),A` drives A on the
      // high address byte too, so e.g. libman13.asm's `OUT (0xE2),A` (used
      // to restore a saved window-3 page) appears here as port
      // `(savedValue<<8)|0xE2`, not bare 0x00E2.
      const lowPort = port & 0xff;
      // ROM overlay control (win0's stage-1 loader clears it before jumping
      // into the payload, lib/win0/loader.c: "out (#0x3C),a ; ROM overlay
      // off"). This harness models flat RAM only -- no ROM ever occupies any
      // window -- so there is nothing to toggle; accept and ignore.
      if (lowPort === 0x3c) return;
      // A window port takes a PHYSICAL page number. The backing store models
      // 1 MB = 64 pages, so anything above that is out of range -- in practice
      // a DSS block id (GETMEM's return, numbered separately under
      // scenario.distinctBlockIds) used where a page number is required. Fail
      // loudly instead of silently reading/writing off the end of the array.
      const mapWindow = (index, page) => {
        if (page >= 0x100000 / 0x4000) {
          throw new Error(`window ${index} mapped to page ${page}, past the harness's ` +
            `1 MB backing store (64 pages) -- a DSS block id used as a physical page? ` +
            `PC=0x${cpu.getState().pc.toString(16)}`);
        }
        win[index] = page;
      };
      if (lowPort === 0x82) { mapWindow(0, value); return; }
      if (lowPort === 0xa2) { mapWindow(1, value); return; }
      if (lowPort === 0xc2) { mapWindow(2, value); return; }
      if (lowPort === 0xe2) {
        if (systemIsa && (value === 0xd4 || value === 0xd6)) { selectedSlot = (value - 0xd4) >> 1; return; }
        mapWindow(3, value);
        return;
      }
      if (port === 0x1ffd) {
        if (value === 0x11) { systemIsa = true; return; }
        if (value === 0x01) { systemIsa = false; isaOpen = false; return; }
        throw new Error(`unknown PORT_SYSTEM value ${value.toString(16)}`);
      }
      if (port === 0x9fbd) {
        if (!systemIsa || value !== 0) throw new Error('invalid ISA mapping sequence (PORT_ISA write without PORT_SYSTEM=0x11)');
        isaOpen = true;
        return;
      }
      throw new Error(`unknown I/O write ${port.toString(16)}=${value.toString(16)} PC=0x${cpu.getState().pc.toString(16)} ${dumpAtStr()} ` +
        `trace=${pcTrace.map((v) => v.toString(16)).join(',')}`);
    },
  });

  // ---- command line: length-prefixed bytes at a fixed WIN0 address ----
  // Never remapped by CLAIM_RUNTIME_PAGE (which only touches WIN2), so this
  // stays valid for both the small-header and large-header EXE layouts.
  const cmdAddress = 0x3f00;
  const cmdLength = Buffer.byteLength(args, 'ascii');
  if (cmdLength > 255) throw new Error('command line exceeds DSS byte length');
  // DSS's real command-tail buffer is a fixed, zero-padded structure (like a
  // CP/M-style PSP): the byte right after the argument text is always 0, and
  // cmdline_lib.asm's tokenizer relies on that (it walks the length-prefixed
  // bytes and only NUL-terminates a token when a separating space is found,
  // never the final token). Zero the whole 256-byte buffer here -- this is
  // DSS-owned memory, not app BSS, so it is exempt from POISON.
  for (let i = 0; i < 256; i++) wr(cmdAddress + i, 0);
  wr(cmdAddress, cmdLength);
  for (let i = 0; i < args.length; i++) wr(cmdAddress + 1 + i, args.charCodeAt(i));
  // Real DSS's PSP continues past the cmdline text with the full path this
  // .EXE was launched from (used by lib/win0/loader.c's own APPINFO-free app
  // directory resolution: `psp + psp[0] + 3`, see the SprinTalk port plan).
  // Optional -- most scenarios don't need it and the 3-byte gap stays zero.
  if (scenario.pspPath) {
    const pathBytes = Buffer.from(scenario.pspPath, 'ascii');
    const pathAddress = (cmdAddress + cmdLength + 3) & 0xffff;
    for (let i = 0; i < pathBytes.length; i++) wr(pathAddress + i, pathBytes[i]);
    wr(pathAddress + pathBytes.length, 0);
  }

  let state = cpu.getState();
  state.pc = entry; state.sp = stack; state.ix = cmdAddress;
  cpu.setState(state);

  const setCarry = (s, value) => { s.flags.C = value ? 1 : 0; };
  const ret = (s) => {
    const lo = rd(s.sp), hi = rd((s.sp + 1) & 0xffff);
    s.sp = (s.sp + 2) & 0xffff; s.pc = lo | (hi << 8); cpu.setState(s);
  };
  const cstr = (address) => {
    let result = '';
    for (let guard = 0; guard < 0x4000; guard++) {
      const value = rd(address++);
      if (!value) return result;
      result += String.fromCharCode(value);
    }
    throw new Error('unterminated DSS string');
  };
  const writeCstr = (address, value) => {
    const bytes = Buffer.from(value, 'ascii');
    for (let i = 0; i < bytes.length; i++) wr(address + i, bytes[i]);
    wr(address + bytes.length, 0);
  };

  // ---- virtual filesystem ----
  const environment = { ...(scenario.environment || {}) };
  const envKey = (name) => name.toUpperCase();
  let currentDir = (scenario.currentDir || 'C:\\NET').replace(/\//g, '\\').toUpperCase();
  const canonicalName = (name) => {
    const normalized = name.replace(/\//g, '\\').toUpperCase();
    if (/^[A-Z]:\\/.test(normalized) || normalized.startsWith('\\')) return normalized;
    return `${currentDir}${currentDir.endsWith('\\') ? '' : '\\'}${normalized}`;
  };
  const files = new Map(Object.entries(scenario.files || {}).map(([name, data]) => [
    canonicalName(name), Buffer.isBuffer(data) ? Buffer.from(data) : Buffer.from(data, 'utf8'),
  ]));
  const openFiles = new Map();
  let nextHandle = 4, envSetCount = 0, clockSecond = scenario.clockSecond || 0;
  // scenario.keyIntervalScans: minimum keyboard polls between two delivered
  // keys, i.e. a typing speed. Without it the queue empties as fast as the
  // program polls, which for a program that drains its whole key buffer per
  // pass means the entire script arrives in one iteration -- nothing like a
  // person at a keyboard, and it starves whatever the test meant to observe
  // between keystrokes. 0 (the default) keeps the old back-to-back behaviour.
  let lastKeyScan = -1e9;
  const keyReady = () => keyQueue.length
    && scanCount >= (scenario.keyAtScan || 1)
    && (scanCount - lastKeyScan) >= (scenario.keyIntervalScans || 0);
  let fileReadCalls = 0, fileWriteCalls = 0, totalWritten = 0, clockReads = 0, scanCount = 0;
  // Input-latency profile: the Z80 cycle count at every keyboard peek. An
  // interactive program polls the keyboard once per main-loop pass, so the
  // gaps between consecutive entries ARE the worst-case time a keystroke can
  // sit unserviced. Cheap enough to always collect.
  const keyPollCycles = [];

  // ---- PRELOAD: leave the .EXE file itself open, positioned right after the
  // loader, with its handle at psp[-3] (CLP_FM) -- exactly what a real DSS
  // EXEC does for a two-stage EXE. loader.c reads both from IX (== cmdAddress
  // here, per the existing PSP setup above).
  if (loaderSize > 0) {
    const handle = nextHandle++;
    openFiles.set(handle, { name: '<SELF>', data: Buffer.from(exe), offset: headerSize + loaderSize });
    wr((cmdAddress - 3) & 0xffff, handle);
  }

  // ---- paged memory allocation (GETMEM/FREEMEM/SETWIN1-3) ----
  // Real DSS hands out a BLOCK ID (1..255, BIOS EMM_FN2), which is NOT a
  // physical page number: only SETWIN (block, index) understands one, while
  // the window ports #82/#A2/#C2/#E2 take physical pages. Programs that cache
  // a page for later raw OUTs must read it back (inp(port) after a SETWIN, or
  // BIOS EMM_FN4) -- see lib/win0/loader.c and libman's _L_CALL.
  //
  // By default this model keeps block id == first physical page, which is
  // convenient but silently forgives that confusion. scenario.distinctBlockIds
  // numbers block ids from a separate space so a raw OUT of a block id maps a
  // page that was never allocated and the program fails loudly, as on hardware.
  let nextBank = 16;
  let nextBlockId = 200;
  const allocations = new Map(); // block id -> [physical pages]
  const blockPage = (block, index) => {
    const pages = allocations.get(block);
    if (!pages) throw new Error(`SETWIN of unknown block id ${block}`);
    if (index >= pages.length) throw new Error(`SETWIN page ${index} past block ${block} (${pages.length} pages)`);
    return pages[index];
  };

  const dssEvents = [];
  let stdout = '', exitCode = null, steps = 0, minimumSp = stack, logicalMs = 0, stopHits = 0;
  let pagesFreedBeforeExit = true;
  const pcTrace = [];

  // Per-function DSS call counts. Divided by keyPollCycles.length this is
  // "syscalls per main-loop pass", the cheapest honest measure of how much
  // work an interactive program repeats every iteration.
  const dssCalls = {};
  // Wire time that passes while the CPU is busy inside a slow DSS service.
  // Without this the model is unphysical: a DSS_WRITE of 8 KB to disk costs
  // the real machine tens of milliseconds, during which the NIC keeps
  // storing arriving frames into its own SRAM (the ISA window being closed
  // is irrelevant -- reception is independent of CPU mapping). Modelling
  // those calls as instantaneous meant the RX ring could never fill while
  // the program was away, so the exact condition that stalls a bulk
  // download on real hardware and in MAME -- peer streams into the
  // advertised window while we are writing a flush buffer to disk -- was
  // unreachable from the harness. scenario.diskWriteMs / consoleMs give
  // those services a cost in wire time.
  const advanceWireMs = (ms) => {
    for (let i = 0; i < ms; i++) {
      logicalMs++;
      card.currentMs = logicalMs;
      card.pumpScheduled();
    }
  };
  const dss = () => {
    if (isaOpen) {
      const s0 = cpu.getState();
      throw new Error(`DSS call while ISA window is open (fn=0x${s0.c.toString(16)} return-to=0x${(rd(s0.sp) | (rd((s0.sp + 1) & 0xffff) << 8)).toString(16)})`);
    }
    const s = cpu.getState(), fn = s.c;
    dssCalls[fn] = (dssCalls[fn] || 0) + 1;
    switch (fn) {
      case 0x02: s.a = 2; setCarry(s, false); return ret(s); // CURDISK -> C:
      case 0x0a:
      case 0x0b: {
        const name = canonicalName(cstr((s.h << 8) | s.l));
        if (fn === 0x0b && files.has(name)) { s.a = 7; setCarry(s, true); return ret(s); }
        // DSS_CREATE_OVERWRITE does NOT truncate an existing file (project
        // quirk); only DSS_CREATE_FILE(0x0B)'s "already exists" check differs.
        const data = fn === 0x0a && files.has(name) ? files.get(name) : Buffer.alloc(0);
        files.set(name, data);
        const handle = nextHandle++;
        openFiles.set(handle, { name, data, offset: 0 });
        if (scenario.traceDss) dssEvents.push(`CREATE ${name} (existing=${data.length})`);
        s.a = handle; setCarry(s, false); return ret(s);
      }
      case 0x0e: {
        const name = canonicalName(cstr((s.h << 8) | s.l));
        if (!files.delete(name)) { s.a = 3; setCarry(s, true); return ret(s); }
        if (scenario.traceDss) dssEvents.push(`DELETE ${name}`);
        setCarry(s, false); return ret(s);
      }
      case 0x11: {
        const name = canonicalName(cstr((s.h << 8) | s.l));
        const data = files.get(name);
        if (scenario.traceDss) dssEvents.push(`OPEN ${name} ${data ? data.length : 'missing'}`);
        if (!data || ![0, 1, 2].includes(s.a)) { s.a = 3; setCarry(s, true); return ret(s); }
        const handle = nextHandle++;
        openFiles.set(handle, { name, data, offset: 0 });
        s.a = handle; setCarry(s, false); return ret(s);
      }
      case 0x12: {
        if (!openFiles.delete(s.a)) throw new Error(`CLOSE_FILE of unknown handle ${s.a}`);
        setCarry(s, false); return ret(s);
      }
      case 0x13: {
        const file = openFiles.get(s.a);
        if (!file) throw new Error(`READ_FILE of unknown handle ${s.a}`);
        fileReadCalls++;
        if (scenario.fileReadFailAt === fileReadCalls) { s.a = 1; setCarry(s, true); return ret(s); }
        let requested = (s.d << 8) | s.e;
        if (scenario.fileReadMax) requested = Math.min(requested, scenario.fileReadMax);
        const chunk = file.data.subarray(file.offset, file.offset + requested);
        const destination = (s.h << 8) | s.l;
        for (let i = 0; i < chunk.length; i++) wr(destination + i, chunk[i]);
        file.offset += chunk.length;
        if (scenario.traceDss) dssEvents.push(`READ ${file.name} ${chunk.length}/${requested}`);
        s.d = chunk.length >> 8; s.e = chunk.length & 0xff;
        setCarry(s, false); return ret(s);
      }
      case 0x14: {
        const file = openFiles.get(s.a);
        if (!file) throw new Error(`WRITE of unknown handle ${s.a}`);
        fileWriteCalls++;
        const requested = (s.d << 8) | s.e;
        if (scenario.fileWriteFailAt === fileWriteCalls ||
            (scenario.diskFullAfter !== undefined && totalWritten + requested > scenario.diskFullAfter)) {
          s.a = 1; setCarry(s, true); return ret(s);
        }
        const source = (s.h << 8) | s.l;
        const end = file.offset + requested;
        const data = Buffer.alloc(Math.max(file.data.length, end));
        file.data.copy(data);
        for (let i = 0; i < requested; i++) data[file.offset + i] = rd(source + i);
        file.data = data; file.offset = end; files.set(file.name, data); totalWritten += requested;
        if (scenario.traceDss) dssEvents.push(`WRITE ${file.name} ${requested}`);
        // The disk write costs wire time: frames keep arriving meanwhile.
        if (scenario.diskWriteMs) advanceWireMs(scenario.diskWriteMs);
        setCarry(s, false); return ret(s);
      }
      case 0x15: { // MOVE_FP: A=handle B=whence(0/1/2) HL:IX=offset(32-bit) -> HL:IX=pos
        const file = openFiles.get(s.a);
        if (!file) throw new Error(`MOVE_FP of unknown handle ${s.a}`);
        const off = ((s.h << 8) | s.l) * 0x10000 + s.ix;
        const base = s.b === 0 ? 0 : s.b === 2 ? file.data.length : file.offset;
        file.offset = base + off;
        s.h = (file.offset >>> 24) & 0xff; s.l = (file.offset >>> 16) & 0xff;
        s.ix = file.offset & 0xffff;
        if (scenario.traceDss) dssEvents.push(`MOVE_FP ${file.name} whence=${s.b} off=${off} -> ${file.offset}`);
        setCarry(s, false); return ret(s);
      }
      case 0x1d: {
        const requested = cstr((s.h << 8) | s.l).replace(/\//g, '\\').toUpperCase();
        if ((scenario.missingDirs || []).map((v) => v.toUpperCase()).includes(requested)) {
          s.a = 3; setCarry(s, true); return ret(s);
        }
        currentDir = /^[A-Z]:\\/.test(requested) || requested.startsWith('\\') ? requested : canonicalName(requested);
        if (scenario.traceDss) dssEvents.push(`CHDIR ${currentDir}`);
        setCarry(s, false); return ret(s);
      }
      case 0x1e:
        writeCstr((s.h << 8) | s.l, currentDir); setCarry(s, false); return ret(s);
      case 0x21: { // SYSTIME: documented ABI quirk -- clobbers IX.
        const now = Math.floor(clockSecond) % 86400;
        s.h = Math.floor(now / 3600); s.l = Math.floor(now / 60) % 60; s.b = now % 60;
        const frozen = scenario.clockFreezeAfterReads !== undefined && clockReads >= scenario.clockFreezeAfterReads;
        clockSecond = (clockSecond + (frozen ? 0 : (scenario.timeStepSeconds ?? 1))) % 86400;
        clockReads++;
        s.ix = 0x0000;
        setCarry(s, false); return ret(s);
      }
      case 0x22: setCarry(s, false); return ret(s); // SETTIME stub
      case 0x30: { // WAITKEY (blocking; returns key in A)
        // Real WAITKEY blocks until a key arrives, so a scripted `scenario.keys`
        // queue must be CONSUMED here, one entry per call -- unlike SCANKEY/
        // TESTKEY's keyReady() gate (scanCount, keyAtScan, keyIntervalScans),
        // which models an interactive poll loop that WAITKEY-based programs
        // never run. A program that WAITKEYs past the end of a scripted queue
        // has a real bug (it is asking for a keystroke the test never planned
        // to send), so that is a hard error with the transcript so far,
        // instead of silently freezing on a fabricated key for 200M steps.
        if (keyQueue.length) {
          loadKeyRegs(s, keyQueue.shift());
          setCarry(s, false); return ret(s);
        }
        if (scenario.keys) {
          throw new Error(`WAITKEY: scripted key queue exhausted (stdout so far:\n${stdout})`);
        }
        loadKeyRegs(s, scenario.key || 'n');
        setCarry(s, false); return ret(s);
      }
      case 0x31: { // SCANKEY: ZF=1 no key; else A=E=ascii, D=scan, B=modifiers
        scanCount++;
        if (keyReady()) {
          lastKeyScan = scanCount;
          loadKeyRegs(s, keyQueue.shift());
          s.flags.Z = 0; setCarry(s, false); return ret(s);
        }
        s.a = 0; s.b = 0; s.d = 0; s.e = 0; s.flags.Z = 1; setCarry(s, false); return ret(s);
      }
      case 0x37: { // TESTKEY: same registers as SCANKEY, but does NOT consume.
        // Interactive DSS apps peek with #37 and only pop with #31 once they
        // know a key is there (see the Sprinter SDK's dss_testkey/dss_scankey
        // and SprinTalk's main loop), so a harness without this stops any such
        // program dead at its first idle poll.
        scanCount++;              // a peek is a poll: a program that only ever
                                  // peeks while idle must still reach keyAtScan
        keyPollCycles.push(cycles);
        if (keyReady()) {
          loadKeyRegs(s, keyQueue[0]);
          s.flags.Z = 0; setCarry(s, false); return ret(s);
        }
        s.a = 0; s.b = 0; s.d = 0; s.e = 0; s.flags.Z = 1; setCarry(s, false); return ret(s);
      }
      case 0x33: { // CTRLKEY: modifier snapshot. Peeks, never pops the ring.
        // Chained after K_CLEAR (#35) this is "drop stale input without
        // reading a key". The scripted queue holds only the keys a test MEANT
        // to send, so a flush is deliberately a no-op on it -- the point of
        // modelling #33 is that it must not eat the next scripted keystroke.
        s.a = keyQueue.length ? 0xff : 0x00;
        s.b = 0; s.c = 0;
        setCarry(s, false); return ret(s);
      }
      case 0x35: { // K_CLEAR: B = chained subfunction (WAITKEY/SCANKEY)
        s.c = s.b; cpu.setState(s); return dss();
      }
      case 0x38: { // SETWIN: A=block, B=index, H=window*0x40
        const windowIndex = (s.h >> 6) & 3;
        const page = blockPage(s.a, s.b);
        win[windowIndex] = page; setCarry(s, false);
        if (scenario.traceDss) dssEvents.push(`SETWIN${windowIndex} <- ${page}`);
        return ret(s);
      }
      case 0x39:
      case 0x3a:
      case 0x3b: { // SETWIN1/2/3 shortcuts
        const windowIndex = fn - 0x38;
        const page = blockPage(s.a, s.b);
        win[windowIndex] = page; setCarry(s, false);
        if (scenario.traceDss) dssEvents.push(`SETWIN${windowIndex} <- ${page}`);
        return ret(s);
      }
      case 0x3d: { // GETMEM: B = page count -> A = block id
        const count = s.b || 1;
        const base = nextBank; nextBank += count;
        const pages = Array.from({ length: count }, (_, i) => base + i);
        const block = scenario.distinctBlockIds ? nextBlockId++ : base;
        allocations.set(block, pages);
        setCarry(s, false); s.a = block;
        if (scenario.traceDss) dssEvents.push(`GETMEM ${count} -> block ${block} (pages ${pages.join(',')})`);
        return ret(s);
      }
      case 0x3e: { // FREEMEM
        if (scenario.traceDss) dssEvents.push(`FREEMEM ${s.a}`);
        if (!allocations.delete(s.a)) throw new Error(`FREEMEM of unknown block ${s.a}`);
        setCarry(s, false); return ret(s);
      }
      case 0x41:
        exitCode = s.b;
        if (isaOpen) throw new Error('EXIT with ISA window open');
        if (openFiles.size) throw new Error('EXIT with unclosed files');
        // Real DSS EXEC/LEAVE frees every DSS page still owned by the task
        // (win2page.asm's CLAIM_RUNTIME_PAGE relies on exactly this and
        // never calls FREEMEM itself) -- leaving pages allocated at EXIT
        // is normal, not a leak. cleanup.pagesFreed reports the pre-exit
        // state for tests that care whether the app freed explicitly.
        pagesFreedBeforeExit = allocations.size === 0;
        allocations.clear();
        cpu.setState(s);
        throw { dssExit: true };
      case 0x46: { // ENVIRON
        if (s.b === 1) {
          const name = envKey(cstr((s.h << 8) | s.l));
          if (!Object.prototype.hasOwnProperty.call(environment, name)) {
            s.a = 0; setCarry(s, false); return ret(s);
          }
          writeCstr((s.d << 8) | s.e, String(environment[name]));
          s.a = 0xff; setCarry(s, false); return ret(s);
        }
        if (s.b === 2) {
          envSetCount++;
          if (scenario.envFailAt && envSetCount === scenario.envFailAt) { s.a = 1; setCarry(s, true); return ret(s); }
          const assignment = cstr((s.h << 8) | s.l);
          const split = assignment.indexOf('=');
          if (split < 1) throw new Error(`invalid ENV_SET '${assignment}'`);
          const name = envKey(assignment.slice(0, split)), value = assignment.slice(split + 1);
          if (value === '') delete environment[name]; else environment[name] = value;
          if (scenario.traceDss) dssEvents.push(`ENV_SET ${name}=${value}`);
          s.a = 0; setCarry(s, false); return ret(s);
        }
        throw new Error(`unknown ENVIRON subfunction ${s.b}`);
      }
      case 0x47: { // APPINFO
        if (s.b === 0) { writeCstr((s.h << 8) | s.l, args); setCarry(s, false); return ret(s); }
        if (s.b === 1) { writeCstr((s.h << 8) | s.l, scenario.appDir || 'C:\\NET'); setCarry(s, false); return ret(s); }
        if (s.b === 2) { writeCstr((s.h << 8) | s.l, `${scenario.appDir || 'C:\\NET'}\\APP.EXE`); setCarry(s, false); return ret(s); }
        throw new Error(`unknown APPINFO subfunction ${s.b}`);
      }
      case 0x52: setCarry(s, false); return ret(s); // GOTOXY: no screen to model, stub ok
      case 0x56: setCarry(s, false); return ret(s); // CLEAR: no screen to model, stub ok
      // Console output does NOT preserve registers on real DSS: RST 10h
      // saves nothing, PUTCHAR/PCHARS load B with the shell colour, C with
      // the BIOS function and IY with 0, and tail into BIOS LP_PR_LINE_DIR
      // (Estex-DSS API/PutChar.asm, API/PChars.asm).  PCHARS also zeroes D
      // and returns HL just past the terminator.  A model that preserved
      // them let NICREG 0.3.18 ship `LD B,count / PRINT / ... DJNZ`, which
      // printed 256 samples on hardware.  B = 0 is the value that makes such
      // a loop as loud as possible.
      case 0x5b:
        stdout += String.fromCharCode(s.a);
        s.a = 0; s.b = 0; s.c = 0xe0; s.iy = 0;
        setCarry(s, false); return ret(s);
      case 0x5c: {
        const text = cstr((s.h << 8) | s.l);
        stdout += text;
        const next = (((s.h << 8) | s.l) + text.length + 1) & 0xffff;
        s.h = next >> 8; s.l = next & 0xff;
        s.a = 0; s.b = 0; s.c = 0xe0; s.d = 0; s.e = 0; s.iy = 0;
        setCarry(s, false); return ret(s);
      }
      default: throw new Error(`unknown DSS call 0x${fn.toString(16)}`);
    }
  };

  const bios = () => {
    if (isaOpen) {
      const s0 = cpu.getState();
      throw new Error(`BIOS call while ISA window is open (fn=0x${s0.c.toString(16)} return-to=0x${(rd(s0.sp) | (rd((s0.sp + 1) & 0xffff) << 8)).toString(16)})`);
    }
    const s = cpu.getState(), fn = s.c;
    const retB = () => {
      const lo = rd(s.sp), hi = rd((s.sp + 1) & 0xffff);
      s.sp = (s.sp + 2) & 0xffff; s.pc = lo | (hi << 8); cpu.setState(s);
    };
    if (fn === 0xc4) { // EMM_FN4: A=block_id, B=index -> A=phys page
      // Must go through the allocation table, exactly like SETWIN: this is
      // the other half of "a block id is not a page". UNETRTL.DLL's own INIT
      // GETMEMs a page and then EMM_FN4s it before OUTing to port 0xE2, so
      // returning block+index here handed it a number no window can take.
      s.a = blockPage(s.a, s.b);
      retB(); return;
    }
    throw new Error(`unknown BIOS call 0x${fn.toString(16)} return-to=0x${(rd(s.sp) | (rd((s.sp + 1) & 0xffff) << 8)).toString(16)} ${dumpAtStr()} ` +
      `trace=${pcTrace.map((v) => v.toString(16)).join(',')}`);
  };

  // ---- 50 Hz IM1 timer interrupt (scenario.timerInterrupt) ----------------
  // Off by default so existing scenarios keep their exact instruction
  // streams. Real DSS drives the frame interrupt the whole time a program
  // runs, and under the win0 layout EVERY one of them is routed through the
  // program's own RST 0x38 trampoline (lib/win0/win0_rt.s) instead of
  // landing straight in the system page -- which is the one interaction a
  // pure software model otherwise never exercises. It matters most during a
  // UNET DLL call: the DLL re-enables interrupts around its 1 ms pacing
  // delay (TICK_AND_CHECK_KEY -> ISA_CLOSE -> DELAY_1MS), so a frame
  // interrupt lands with WIN1 still holding the DLL.
  //
  // The handler itself is modelled, not executed: the system page holds no
  // real DSS code here. It just returns like EI + RETI. It does NOT touch
  // window 3, even though a DSS *call* is free to: the "map a page into
  // WIN3, copy, restore" idiom is used by libman's own loader, by this
  // kit's win0cold.asm and by SprinTalk's scrollback, none of which bracket
  // it against interrupts -- so the frame handler has to hand window 3 back.
  // timerInterrupt.clobberWin3 turns the pessimistic model on anyway.
  // The clock is the Z80 cycle counter, not logicalMs: logicalMs only moves
  // when the DELAY_1MS fast-forward fires, so a program busy in its own code
  // would never see a tick. cyclesPerMs is the conversion the fast-forward
  // uses to keep the two in step.
  const timer = scenario.timerInterrupt
    ? { ms: 20, cyclesPerMs: 3500, clobberWin3: false,
        ...(scenario.timerInterrupt === true ? {} : scenario.timerInterrupt) }
    : null;
  let interruptsFired = 0, interruptsTaken = 0, cycles = 0;
  // scenario.pcSample = N: bucket the program counter every N instructions.
  // A statistical profile is the only practical way to ask "where does an
  // interactive DSS program actually spend its main-loop time", since the
  // cycle cost is spread over library code, the DLL and the RST trampolines.
  // Key is `pc` for program code and `pc|0x10000` while the ISA window is
  // open, which is exactly the time spent inside the network DLL.
  const pcSamples = scenario.pcSample ? new Map() : null;
  let sampleTick = 0;
  let nextTickCycles = timer ? timer.ms * timer.cyclesPerMs : Infinity;
  let scratchPage = 63;   // a real page, just not one this program mapped
  if (timer) {
    const s = cpu.getState();
    s.imode = 1;          // DSS leaves the machine in IM 1; the core resets to IM 0
    cpu.setState(s);
  }

  try {
    const limit = scenario.stepLimit || 200_000_000;
    for (;;) {
      if (timer && cycles >= nextTickCycles) {
        nextTickCycles = cycles + timer.ms * timer.cyclesPerMs;
        interruptsFired++;
        const before = cpu.getState().pc;
        cpu.interrupt(false, 0xff);
        if (cpu.getState().pc !== before) interruptsTaken++;
      }
      const st0 = cpu.getState();
      if (pcSamples && ++sampleTick >= scenario.pcSample) {
        sampleTick = 0;
        const key = (st0.pc & 0xfff0) | (isaOpen ? 0x10000 : 0);
        pcSamples.set(key, (pcSamples.get(key) || 0) + 1);
      }
      // Test-only observation/injection at actual assembled instruction boundaries.
      scenario.cpuProbes?.[st0.pc]?.({ state: st0, read: rd, card, win, logicalMs });
      minimumSp = Math.min(minimumSp, st0.sp);
      if (scenario.stopPc !== undefined && st0.pc === scenario.stopPc &&
          (scenario.stopWin0 === undefined || win[0] === scenario.stopWin0) &&
          (!scenario.stopWin || win[scenario.stopWin[0]] === scenario.stopWin[1]) &&
          (++stopHits >= (scenario.stopHit || 1))) {
        // scenario.dumpAt: {label: address} -- read as a 16-bit LE word at
        // stop time, for ad-hoc inspection of specific globals (debugging
        // aid; a thrown stopPc otherwise only reports registers/PC trace).
        const at = Object.entries(scenario.dumpAt || {})
          .map(([k, a]) => `${k}=0x${(rd(a) | (rd((a + 1) & 0xffff) << 8)).toString(16)}`).join(' ');
        throw new Error(`stop PC=${st0.pc.toString(16)} SP=${st0.sp.toString(16)} A=${st0.a.toString(16)} ` +
          `HL=${st0.h.toString(16)}${st0.l.toString(16).padStart(2, '0')} ` +
          `DE=${st0.d.toString(16)}${st0.e.toString(16).padStart(2, '0')} ` +
          `BC=${st0.b.toString(16)}${st0.c.toString(16).padStart(2, '0')} ` +
          `win=${win.map((v) => v.toString(16)).join(',')} ${at} ` +
          `trace=${pcTrace.map((v) => v.toString(16)).join(',')}`);
      }
      if (scenario.strictPc && st0.pc !== 0x0008 && st0.pc !== 0x0010 && st0.pc < loadAddress
          && !(st0.pc < 0x4000 && win[0] !== 0)) { // window 0 remapped: low PCs are overlay code
        throw new Error(`PC escaped image: PC=${st0.pc.toString(16)} SP=${st0.sp.toString(16)} ` +
          `trace=${pcTrace.map((v) => v.toString(16)).join(',')}`);
      }
      if (scenario.traceCpu) { pcTrace.push(st0.pc); if (pcTrace.length > 32) pcTrace.shift(); }

      if (scenario.fastDelayLoops !== false && isDelayLoopTop(rd, st0.pc) && ((st0.b << 8) | st0.c) > 1) {
        if (isaOpen) throw new Error(`DELAY_1MS executed with ISA window open at PC=${st0.pc.toString(16)}`);
        st0.b = 0; st0.c = 1; cpu.setState(st0);
        logicalMs++;
        if (timer) cycles += timer.cyclesPerMs;
        card.currentMs = logicalMs;
        card.pumpScheduled();
      }

      // The RST vectors are service entry points ONLY while window 0 holds
      // the system page (win[0] === 0). A program that remaps window 0 to
      // its own page (win0cold.asm's cold-overlay RUN does exactly this)
      // makes both vectors plain memory: the overlay's own code legitimately
      // executes across addresses 0x0008/0x0010 (its DEC A/JP Z dispatch
      // chain crosses both), and on real hardware DSS/BIOS are simply
      // unreachable until the page is restored. Treating every PC=0x0008/
      // 0x0010 arrival as a service call produced false "BIOS/DSS call
      // while ISA window is open" throws for every cold-overlay dispatch.
      const pc = cpu.getState().pc;
      if (pc === 0x0010 && win[0] === 0) { dss(); cycles += 200; }
      else if (pc === 0x0008 && win[0] === 0) { bios(); cycles += 200; }
      else if (timer && pc === 0x0038 && win[0] === 0) {
        // Modelled DSS frame handler: scribble on window 3 and RETI.
        if (isaOpen) throw new Error('frame interrupt reached DSS with the ISA window open');
        if (timer.clobberWin3) win[3] = scratchPage;
        const s = cpu.getState();
        s.pc = rd(s.sp) | (rd((s.sp + 1) & 0xffff) << 8);
        s.sp = (s.sp + 2) & 0xffff;
        s.iff1 = 1; s.iff2 = 1;        // the real handler EIs before its RETI
        cpu.setState(s);
      } else cycles += cpu.run_instruction() || 0;

      if (++steps > limit) {
        // A scripted run that spins here has almost always run out of keys: the
      // wizard's cursor loop peeks with TESTKEY, which (unlike WAITKEY) has no
      // "queue exhausted" error to raise, so say it here instead.
      const starved = scenario.keys && !keyQueue.length
        ? ' (scripted key queue is empty -- the program is still polling for input)' : '';
      throw new Error(`step limit${starved} at PC=${cpu.getState().pc.toString(16)} SP=${cpu.getState().sp.toString(16)} ` +
          `trace=${pcTrace.map((v) => v.toString(16)).join(',')}`);
      }
    }
  } catch (error) {
    if (!error || !error.dssExit) {
      // Preserve whatever the program printed/did before a genuine crash --
      // the thrown Error otherwise loses it, which makes diagnosing "why"
      // much harder than it needs to be (see e.g. the win0 migration's own
      // debugging session for this harness).
      if (error && typeof error === 'object') {
        error.partialOutput = stdout;
        error.partialDssEvents = dssEvents;
        error.partialKeyPollCycles = keyPollCycles;
        error.partialPcSamples = pcSamples;
        error.partialDssCalls = dssCalls;
      }
      throw error;
    }
  }

  return {
    exitCode,
    output: stdout,
    transmittedFrames: card.transmitted.map(hex),
    generatedFrames: card.generated.map(hex),
    rxPending: card.pending.length,
    cleanup: {
      isaClosed: !isaOpen,
      pagesFreed: pagesFreedBeforeExit,
      filesClosed: openFiles.size === 0,
    },
    card: {
      slot: card.slot, base: card.base, present: card.present, mac: hex(card.mac),
      par: hex(card.par), cr: card.cr, isr: card.isr, bnry: card.bnry, curr: card.curr,
      tpsrValue: card.tpsrValue, pstart: card.pstart, pstop: card.pstop,
      rxHalted: card.rxHalted, txAttempts: card.txAttempts, rxDelivered: card.rxDelivered,
      stats: { ...card.stats },
    },
    environment: { ...environment },
    currentDir,
    files: Object.fromEntries([...files].map(([name, data]) => [name, Buffer.from(data)])),
    ...(scenario.traceDss ? { dssEvents } : {}),
    ...(scenario.traceChip ? { chipTrace } : {}),
    ...(scenario.dumpMemory ? {
      memory: Object.fromEntries(scenario.dumpMemory.map(([start, length]) => [
        start.toString(16), hex(Array.from({ length }, (_, i) => rd((start + i) & 0xffff))),
      ])),
    } : {}),
    steps,
    keyPollCycles,
    dssCalls,
    pcSamples,
    interruptsFired,
    interruptsTaken,
    minimumSp,
    logicalMs,
    closedChipAccesses,
  };
}

module.exports = { runExe, normalizeFrame };
