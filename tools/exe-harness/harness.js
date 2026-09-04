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
  if (headerSize !== 128 && headerSize !== 256) throw new Error(`unsupported DSS EXE header size ${headerSize}`);
  if (entry !== entry2) throw new Error('unsupported DSS EXE header layout (entry mismatch)');
  const loadAddress = entry - headerSize;
  if (loadAddress < 0 || loadAddress + exe.length > 0x10000) throw new Error('EXE image does not fit in the 64K address space');

  // ---- paged memory: 1 MB backing store, 4 x 16 KB windows ----
  const mem = new Uint8Array(0x100000);
  if (scenario.poison !== false) mem.fill(0xaa);
  const win = [0, 1, 2, 3];
  const lin = (a) => win[(a >> 14) & 3] * 0x4000 + (a & 0x3fff);

  const card = new Rtl8019(scenario);
  if (scenario.responders) card.onTransmit = (frame) => netBuilders.respond(frame, card, scenario);
  let systemIsa = false, isaOpen = false, selectedSlot = 0;
  const closedChipAccesses = [];
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
        if (inChipAperture) {
          if (cpu.getState().iff1) {
            throw new Error(`interrupts enabled (IFF1=1) during chip access at PC=${cpu.getState().pc.toString(16)}`);
          }
          if (selectedSlot === card.slot && card.present) return card.readReg(off);
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
        if (inChipAperture) {
          if (cpu.getState().iff1) {
            throw new Error(`interrupts enabled (IFF1=1) during chip access at PC=${cpu.getState().pc.toString(16)}`);
          }
          if (selectedSlot === card.slot && card.present) card.writeReg(off, value);
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

  for (let i = 0; i < exe.length; i++) mem[lin(loadAddress + i)] = exe[i];

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
      throw new Error(`unknown I/O read ${port.toString(16)}`);
    },
    io_write: (port, value) => {
      port &= 0xffff; value &= 0xff;
      // Same low-byte decode as io_read above -- `OUT (n),A` drives A on the
      // high address byte too, so e.g. libman13.asm's `OUT (0xE2),A` (used
      // to restore a saved window-3 page) appears here as port
      // `(savedValue<<8)|0xE2`, not bare 0x00E2.
      const lowPort = port & 0xff;
      if (lowPort === 0x82) { win[0] = value; return; }
      if (lowPort === 0xa2) { win[1] = value; return; }
      if (lowPort === 0xc2) { win[2] = value; return; }
      if (lowPort === 0xe2) {
        if (systemIsa && (value === 0xd4 || value === 0xd6)) { selectedSlot = (value - 0xd4) >> 1; return; }
        win[3] = value;
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
      throw new Error(`unknown I/O write ${port.toString(16)}=${value.toString(16)}`);
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
  let fileReadCalls = 0, fileWriteCalls = 0, totalWritten = 0, clockReads = 0, scanCount = 0;

  // ---- paged memory allocation (GETMEM/FREEMEM/SETWIN1-3) ----
  let nextBank = 16;
  const allocations = new Map(); // base bank id -> page count
  const allocatedBank = (bank) => {
    for (const [base, count] of allocations) if (bank >= base && bank < base + count) return true;
    return false;
  };

  const dssEvents = [];
  let stdout = '', exitCode = null, steps = 0, minimumSp = stack, logicalMs = 0;
  let pagesFreedBeforeExit = true;
  const pcTrace = [];

  const dss = () => {
    if (isaOpen) {
      const s0 = cpu.getState();
      throw new Error(`DSS call while ISA window is open (fn=0x${s0.c.toString(16)} return-to=0x${(rd(s0.sp) | (rd((s0.sp + 1) & 0xffff) << 8)).toString(16)})`);
    }
    const s = cpu.getState(), fn = s.c;
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
        const key = scenario.key || 'n';
        s.a = key === 'escape' ? 0x1b : key === 'ctrl-c' ? 0x03 : key.charCodeAt(0);
        setCarry(s, false); return ret(s);
      }
      case 0x31: { // SCANKEY: ZF=1 no key; else A=E=ascii, D=scan, B=modifiers
        scanCount++;
        if (scenario.key && scanCount === (scenario.keyAtScan || 1)) {
          if (scenario.key === 'escape') { s.b = 0; s.d = 1; s.e = 0x1b; }
          else if (scenario.key === 'ctrl-c') { s.b = 0x20; s.d = 0xac; s.e = 0; }
          else throw new Error(`unknown simulated key ${scenario.key}`);
          s.a = s.e; s.flags.Z = 0; setCarry(s, false); return ret(s);
        }
        s.a = 0; s.b = 0; s.d = 0; s.e = 0; s.flags.Z = 1; setCarry(s, false); return ret(s);
      }
      case 0x35: { // K_CLEAR: B = chained subfunction (WAITKEY/SCANKEY)
        s.c = s.b; cpu.setState(s); return dss();
      }
      case 0x38: { // SETWIN: A=block, B=index, H=window*0x40
        const windowIndex = (s.h >> 6) & 3;
        const page = s.a + s.b;
        if (!allocatedBank(page)) throw new Error(`SETWIN of unallocated page ${page}`);
        win[windowIndex] = page; setCarry(s, false); return ret(s);
      }
      case 0x39:
      case 0x3a:
      case 0x3b: { // SETWIN1/2/3 shortcuts
        const windowIndex = fn - 0x38;
        const page = s.a + s.b;
        if (!allocatedBank(page)) throw new Error(`SETWIN${windowIndex} of unallocated page ${page}`);
        win[windowIndex] = page; setCarry(s, false); return ret(s);
      }
      case 0x3d: { // GETMEM: B = page count -> A = base bank id
        const count = s.b || 1;
        const base = nextBank; nextBank += count;
        allocations.set(base, count);
        setCarry(s, false); s.a = base; return ret(s);
      }
      case 0x3e: { // FREEMEM
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
      case 0x5b: stdout += String.fromCharCode(s.a); setCarry(s, false); return ret(s);
      case 0x5c: stdout += cstr((s.h << 8) | s.l); setCarry(s, false); return ret(s);
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
      s.a = (s.a + s.b) & 0xff;
      retB(); return;
    }
    throw new Error(`unknown BIOS call 0x${fn.toString(16)}`);
  };

  try {
    const limit = scenario.stepLimit || 200_000_000;
    for (;;) {
      const st0 = cpu.getState();
      minimumSp = Math.min(minimumSp, st0.sp);
      if (scenario.stopPc !== undefined && st0.pc === scenario.stopPc) {
        throw new Error(`stop PC=${st0.pc.toString(16)} SP=${st0.sp.toString(16)} A=${st0.a.toString(16)} ` +
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
      if (pc === 0x0010 && win[0] === 0) dss();
      else if (pc === 0x0008 && win[0] === 0) bios();
      else cpu.run_instruction();

      if (++steps > limit) {
        throw new Error(`step limit at PC=${cpu.getState().pc.toString(16)} SP=${cpu.getState().sp.toString(16)} ` +
          `trace=${pcTrace.map((v) => v.toString(16)).join(',')}`);
      }
    }
  } catch (error) {
    if (!error || !error.dssExit) throw error;
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
      rxHalted: card.rxHalted, txAttempts: card.txAttempts, rxDelivered: card.rxDelivered,
      stats: { ...card.stats },
    },
    environment: { ...environment },
    currentDir,
    files: Object.fromEntries([...files].map(([name, data]) => [name, Buffer.from(data)])),
    ...(scenario.traceDss ? { dssEvents } : {}),
    ...(scenario.dumpMemory ? {
      memory: Object.fromEntries(scenario.dumpMemory.map(([start, length]) => [
        start.toString(16), hex(Array.from({ length }, (_, i) => rd((start + i) & 0xffff))),
      ])),
    } : {}),
    steps,
    minimumSp,
    logicalMs,
    closedChipAccesses,
  };
}

module.exports = { runExe, normalizeFrame };
