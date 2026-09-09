// Strict host model of the RTL8019AS/DP8390 NIC as accessed by this
// project's driver (src/lib/rtl8019.asm) through the Sprinter ISA window.
// SPDX-License-Identifier: BSD-3-Clause
'use strict';

const DEFAULT_MAC = [0x02, 0x80, 0x19, 0x11, 0x22, 0x33];

const ISR_PRX = 0x01, ISR_PTX = 0x02, ISR_RXE = 0x04, ISR_TXE = 0x08,
  ISR_OVW = 0x10, ISR_CNT = 0x20, ISR_RDC = 0x40, ISR_RST = 0x80;

const equal = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);

// buildProm: 32-byte PROM image as returned by RTL.READ_PROM (RSAR=0,
// RBCR=32).  'direct' layout matches a plain byte-mode NE2000 clone;
// 'doubled' duplicates each of the first 16 logical bytes into two
// consecutive raw bytes (mirrors a 16-bit-native PROM read through an
// 8-bit mux); 'unknown' produces neither pattern and no signature.
function buildProm(mac, layout, sigByte = 0x57) {
  const bytes = new Array(32).fill(0);
  if (layout === 'doubled') {
    const logical = new Array(16).fill(0);
    for (let i = 0; i < 6; i++) logical[i] = mac[i];
    logical[14] = sigByte;
    logical[15] = sigByte;
    for (let i = 0; i < 16; i++) { bytes[2 * i] = logical[i]; bytes[2 * i + 1] = logical[i]; }
    return bytes;
  }
  if (layout === 'unknown') {
    for (let i = 0; i < 6; i++) bytes[i] = mac[i];
    bytes[0x0E] = 0x00; bytes[0x0F] = 0x00;
    // Ensure it does not accidentally look doubled.
    bytes[0] = mac[0]; bytes[1] = mac[0] === mac[1] ? (mac[1] ^ 0x01) & 0xff : mac[1];
    return bytes;
  }
  // direct
  for (let i = 0; i < 6; i++) bytes[i] = mac[i];
  bytes[0x0E] = sigByte;
  bytes[0x0F] = sigByte;
  return bytes;
}

class Rtl8019 {
  constructor(scenario) {
    this.scenario = scenario;
    this.present = scenario.cardPresent !== false;
    this.slot = scenario.slot === 0 ? 0 : 1;
    this.base = scenario.base !== undefined ? scenario.base : 0x300;
    this.mac = Array.from(scenario.mac || DEFAULT_MAC);
    const quirks = scenario.quirks || {};
    this.variant = quirks.variant || 'RTL8019AS';
    this.quirks = {
      loopbackToRing: quirks.loopbackToRing !== false, // MAME default: true
      isrRstOnStop: quirks.isrRstOnStop === true, // real HW: true; MAME default: false
      openBusValue: quirks.openBusValue !== undefined ? quirks.openBusValue : 0xff,
      hangOnResetPort: quirks.hangOnResetPort === true, // UM9003-style clone
    };
    this.promLayout = scenario.promLayout || 'direct';
    this.prom = buildProm(this.mac, this.promLayout, scenario.promSignature);
    // 8019ID0/ID1.  A real UM9003AF answers 0x20/0x01, measured on the
    // card -- NOT 0xff, which is also the open-bus value and would let a
    // "clone rejected" test pass for the wrong reason (absent card rather
    // than wrong signature).
    this.id0 = this.variant === 'UM9003' ? 0x20 : 0x50;
    this.id1 = this.variant === 'UM9003' ? 0x01 : 0x70;

    // Page-0 registers (write side / configured value).
    this.cr = 0x21; // PAGE0_STOP
    this.isr = 0;
    this.imrValue = 0;
    this.dcrValue = 0;
    this.tcrValue = 0;
    this.rcrValue = 0;
    this.pstart = 0;
    this.pstop = 0;
    this.bnry = 0;
    this.tpsrValue = 0;
    this.tbcr = 0;
    this.rsar = 0;
    this.rbcr = 0;
    // Page-0 read-side aliases.
    this.tsr = 0;
    this.ncr = 0;
    this.fifo = 0;
    this.rsr = 0;
    this.crda = 0;

    // Page-1 registers.
    this.par = Array.from(this.mac);
    this.curr = 0;
    this.mar = new Array(8).fill(0);

    // Page-3 registers.
    this.cr9346 = 0;
    this.bpage = 0;
    const cfg = scenario.config || {};
    this.config0 = cfg.cfg0 !== undefined ? cfg.cfg0 : 0x00;
    this.config1 = cfg.cfg1 !== undefined ? cfg.cfg1 : 0x80; // IRQEN set, jumperless default
    this.config2 = cfg.cfg2 !== undefined ? cfg.cfg2 : 0x00;
    this.config3 = cfg.cfg3 !== undefined ? cfg.cfg3 : 0x00;
    this.config4 = cfg.cfg4 !== undefined ? cfg.cfg4 : 0x00;
    this.csnsav = 0;
    this.intr = 0;

    // DMA state machine.
    this.dmaActive = false;
    this.dmaDirection = null;

    // RX ring halted after an unrecovered overflow.
    this.rxHalted = false;
    this.stopped = false;

    // 16 KB of NIC-local packet RAM, addresses 0x4000..0x7FFF.
    this.ram = new Uint8Array(0x4000);
    if (scenario.poison !== false) this.ram.fill(0xaa);

    this.transmitted = []; // frames that actually left the wire
    this.txAttempts = 0;
    this.rxDelivered = 0;
    this.stats = { filteredRx: 0, oobDma: 0, overflowEvents: 0 };
    this._dmaByteIndex = 0;

    // Scheduled RX delivery: preloaded scenario.rxFrames plus anything a
    // protocol responder (net-builders.js, via onTransmit) schedules in
    // reaction to a transmitted frame. currentMs is kept in sync with the
    // harness's logicalMs by the run loop after every DELAY_1MS collapse.
    this.currentMs = 0;
    this.pending = (scenario.rxFrames || []).map((f) => ({ atMs: f.afterMs || 0, bytes: f.bytes }));
    this.onTransmit = null; // set by harness.js to net-builders.js's respond()
    this.generated = []; // every reply a responder built, for test introspection
  }

  schedule(delayMs, bytes) {
    this.pending.push({ atMs: this.currentMs + Math.max(0, delayMs || 0), bytes });
  }

  pumpScheduled() {
    if (!this.pending.length) return;
    const ready = [], notYet = [];
    for (const p of this.pending) (p.atMs <= this.currentMs ? ready : notYet).push(p);
    this.pending = notYet;
    for (const p of ready) this.deliverFrame(p.bytes);
  }

  // ---- reset port (BASE+0x1F) ----
  readResetPort() {
    if (this.quirks.hangOnResetPort) {
      throw new Error('reset port BASE+0x1F read on a card that hangs the ISA cycle here ' +
        '(driver must honour NET_RTL_RESET=SOFT and never touch this port)');
    }
    this.cr = 0x21;
    this.isr |= ISR_RST;
    return 0xff;
  }

  writeResetPort() { /* NE2000-style: write-back is a documented no-op */ }

  // ---- CR (offset 0x00) ----
  writeCr(value) {
    value &= 0xff;
    this.cr = value;
    const stp = !!(value & 0x01), sta = !!(value & 0x02), txp = !!(value & 0x04);
    if (stp) {
      this.stopped = true;
      if (this.quirks.isrRstOnStop) this.isr |= ISR_RST;
    } else if (sta && this.stopped) {
      this.stopped = false;
      this.rxHalted = false; // RECOVER_OVERFLOW's STP->STA edge restarts the RX engine
    }
    const rdField = (value >> 3) & 7;
    if (rdField === 1 || rdField === 2) {
      if (!this.dmaActive) { this.crda = this.rsar; this._dmaByteIndex = 0; }
      this.dmaDirection = rdField === 1 ? 'read' : 'write';
      this.dmaActive = true;
      if (this.rbcr === 0) { this.isr |= ISR_RDC; this.dmaActive = false; this.dmaDirection = null; }
    } else if (rdField === 4) {
      this.dmaActive = false;
      this.dmaDirection = null;
    }
    if (txp) this.doTransmit();
  }

  // ---- remote DMA data port (offset 0x10) ----
  readData() {
    if (!this.dmaActive || this.dmaDirection !== 'read' || this.rbcr <= 0) {
      throw new Error('remote DMA data port read with no active read transfer (RBCR=0 or DMA idle)');
    }
    let value = this.ramReadNic(this.crda);
    if (this.scenario.corruptDmaReadAt !== undefined && this._dmaByteIndex === this.scenario.corruptDmaReadAt) {
      value ^= 0x01;
    }
    this._dmaByteIndex++;
    this.crda = (this.crda + 1) & 0xffff;
    this.rbcr--;
    if (this.rbcr === 0) { this.isr |= ISR_RDC; this.dmaActive = false; this.dmaDirection = null; }
    return value;
  }

  writeData(value) {
    if (!this.dmaActive || this.dmaDirection !== 'write' || this.rbcr <= 0) {
      throw new Error('remote DMA data port write with no active write transfer (RBCR=0 or DMA idle)');
    }
    this.ramWriteNic(this.crda, value & 0xff);
    this._dmaByteIndex++;
    this.crda = (this.crda + 1) & 0xffff;
    this.rbcr--;
    if (this.rbcr === 0) { this.isr |= ISR_RDC; this.dmaActive = false; this.dmaDirection = null; }
  }

  ramReadNic(addr) {
    if (addr < 0x4000) return this.prom[addr % this.prom.length];
    if (addr < 0x8000) return this.ram[addr - 0x4000];
    this.stats.oobDma++;
    return this.quirks.openBusValue;
  }

  ramWriteNic(addr, value) {
    if (addr >= 0x4000 && addr < 0x8000) { this.ram[addr - 0x4000] = value; return; }
    this.stats.oobDma++;
  }

  // ---- generic page0/1/2/3 register file, offsets 0x01..0x0F ----
  readReg(offset) {
    if (offset === 0x00) return this.cr;
    if (offset === 0x10) return this.readData();
    if (offset === 0x1f) return this.readResetPort();
    const page = (this.cr >> 6) & 3;
    if (page === 0) {
      switch (offset) {
        case 0x01: return this.crda & 0xff;
        case 0x02: return (this.crda >> 8) & 0xff;
        case 0x03: return this.bnry;
        case 0x04: return this.tsr;
        case 0x05: return this.ncr;
        case 0x06: return this.fifo;
        case 0x07: return this.isr;
        case 0x08: return this.crda & 0xff;
        case 0x09: return (this.crda >> 8) & 0xff;
        case 0x0a: return this.id0;
        case 0x0b: return this.id1;
        case 0x0c: return this.rsr;
        case 0x0d: return 0;
        case 0x0e: return 0;
        case 0x0f: return 0;
        default: throw new Error(`read of unknown page0 offset ${offset.toString(16)}`);
      }
    }
    if (page === 1) {
      if (offset >= 0x01 && offset <= 0x06) return this.par[offset - 1];
      if (offset === 0x07) return this.curr;
      if (offset >= 0x08 && offset <= 0x0f) return this.mar[offset - 8];
      throw new Error(`read of unknown page1 offset ${offset.toString(16)}`);
    }
    if (page === 2) {
      switch (offset) {
        case 0x01: return this.pstart;
        case 0x02: return this.pstop;
        case 0x04: return this.tpsrValue;
        case 0x0c: return this.rcrValue;
        case 0x0d: return this.tcrValue;
        case 0x0e: return this.dcrValue;
        case 0x0f: return this.imrValue;
        default: return 0xff;
      }
    }
    // page 3
    switch (offset) {
      case 0x01: return this.cr9346;
      case 0x02: return this.bpage;
      case 0x03: return this.config0;
      case 0x04: return this.config1;
      case 0x05: return this.config2;
      case 0x06: return this.config3;
      case 0x08: return this.csnsav;
      case 0x0b: return this.intr;
      case 0x0d: return this.config4;
      default: return 0xff;
    }
  }

  writeReg(offset, value) {
    value &= 0xff;
    if (offset === 0x00) return this.writeCr(value);
    if (offset === 0x10) return this.writeData(value);
    if (offset === 0x1f) return this.writeResetPort(value);
    const page = (this.cr >> 6) & 3;
    if (page === 0) {
      switch (offset) {
        case 0x01: this.pstart = value; return;
        case 0x02: this.pstop = value; return;
        case 0x03: this.bnry = value; return;
        case 0x04: this.tpsrValue = value; return;
        case 0x05: this.tbcr = (this.tbcr & 0xff00) | value; return;
        case 0x06: this.tbcr = (this.tbcr & 0x00ff) | (value << 8); return;
        case 0x07: this.isr &= (~value) & 0xff; return; // write-1-to-clear
        case 0x08: this.rsar = (this.rsar & 0xff00) | value; return;
        case 0x09: this.rsar = (this.rsar & 0x00ff) | (value << 8); return;
        case 0x0a: this.rbcr = (this.rbcr & 0xff00) | value; return;
        case 0x0b: this.rbcr = (this.rbcr & 0x00ff) | (value << 8); return;
        case 0x0c: this.rcrValue = value; return;
        case 0x0d: this.tcrValue = value; return;
        case 0x0e:
          if (value & 0x01) throw new Error('DCR.WTS=1 (16-bit word transfer) is forbidden on this ISA8 card');
          this.dcrValue = value; return;
        case 0x0f: this.imrValue = value; return;
        default: throw new Error(`write of unknown page0 offset ${offset.toString(16)}`);
      }
    }
    if (page === 1) {
      if (offset >= 0x01 && offset <= 0x06) { this.par[offset - 1] = value; return; }
      if (offset === 0x07) { this.curr = value; return; }
      if (offset >= 0x08 && offset <= 0x0f) { this.mar[offset - 8] = value; return; }
      throw new Error(`write of unknown page1 offset ${offset.toString(16)}`);
    }
    if (page === 2) throw new Error(`illegal page2 register write at offset ${offset.toString(16)}`);
    // page 3: only 9346CR (EEPROM control) is a normal driver write target.
    if (offset === 0x01) { this.cr9346 = value; return; }
    if (offset === 0x02) { this.bpage = value; return; }
    throw new Error(`illegal page3 register write at offset ${offset.toString(16)} (config regs are read-only without 9346 enable)`);
  }

  // ---- transmit ----
  doTransmit() {
    this.txAttempts++;
    if (this.pstop <= this.tpsrValue) throw new Error('PSTOP must exceed TPSR in 8-bit mode');
    const start = this.tpsrValue * 256 - 0x4000;
    const frame = Array.from(this.ram.slice(start, start + this.tbcr));
    const loopbackActive = (this.tcrValue & 0x06) !== 0 && (this.dcrValue & 0x08) === 0;
    const txError = this.scenario.txError;
    const shouldFail = txError && (txError === true || (txError.attempts || []).includes(this.txAttempts));
    if (shouldFail) {
      this.isr |= ISR_TXE;
      this.cr &= ~0x04;
      return;
    }
    this.isr |= ISR_PTX;
    this.tsr = 0x01;
    if (loopbackActive) {
      if (this.quirks.loopbackToRing) {
        this.deliverFrame(frame, { loopback: true });
      } else {
        this.isr |= ISR_RXE;
        this.rsr = 0x01;
        this.fifo = frame.length ? frame[frame.length - 1] : 0;
      }
    } else {
      this.transmitted.push(frame);
      if (this.onTransmit) this.onTransmit(frame);
    }
    this.cr &= ~0x04; // hardware auto-clears TXP on completion
  }

  // ---- receive ----
  ringSize() { return this.pstop - this.pstart; }

  accepts(frame) {
    if (this.rcrValue & 0x20) return false; // monitor mode: never store
    const dest = frame.slice(0, 6);
    const broadcast = dest.every((v) => v === 0xff);
    if (broadcast) return (this.rcrValue & 0x04) !== 0;
    const multicast = (dest[0] & 0x01) !== 0;
    if (multicast) return (this.rcrValue & 0x08) !== 0 || (this.rcrValue & 0x10) !== 0;
    if (this.rcrValue & 0x10) return true; // promiscuous
    return equal(dest, this.par);
  }

  deliverFrame(frame, options = {}) {
    if (!options.loopback) {
      if (this.rxHalted) { this.stats.filteredRx++; return; }
      if (this.rcrValue & 0x20) { this.stats.filteredRx++; return; }
      if (!this.accepts(frame)) { this.stats.filteredRx++; return; }
    }
    const R = this.ringSize();
    if (R <= 0) {
      // Ring not programmed yet (e.g. a frame arrives during RTL.RESET's
      // settling delay, before INIT_NORMAL sets PSTART/PSTOP): the real
      // chip has nowhere defined to store it either. Drop silently.
      this.stats.filteredRx++;
      return;
    }
    const posOf = (page) => ((page - this.pstart) % R + R) % R;
    const totalLen = frame.length + 4;
    const pagesNeeded = Math.ceil(totalLen / 256);
    const gap = ((posOf(this.bnry) - posOf(this.curr)) % R + R) % R;
    if (pagesNeeded > gap) {
      this.isr |= ISR_OVW;
      this.rxHalted = true;
      this.stats.overflowEvents++;
      return;
    }
    const dest = frame.slice(0, 6);
    const broadcastOrMulti = dest.every((v) => v === 0xff) || (dest[0] & 0x01) !== 0;
    const status = 0x01 | (broadcastOrMulti ? 0x20 : 0x00);
    const nextPage = this.pstart + ((posOf(this.curr) + pagesNeeded) % R);
    const header = [status, nextPage & 0xff, totalLen & 0xff, (totalLen >> 8) & 0xff];
    let addr = this.curr * 256;
    const wrapAddr = (a) => (a >= this.pstop * 256 ? this.pstart * 256 : a);
    for (const byte of header) { this.ramWriteNic(addr, byte); addr = wrapAddr(addr + 1); }
    for (const byte of frame) { this.ramWriteNic(addr, byte); addr = wrapAddr(addr + 1); }
    this.curr = nextPage;
    this.isr |= ISR_PRX;
    this.rxDelivered++;
  }
}

module.exports = { Rtl8019, buildProm, DEFAULT_MAC, ISR_PRX, ISR_PTX, ISR_RXE, ISR_TXE, ISR_OVW, ISR_CNT, ISR_RDC, ISR_RST };
