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
    const quirks = scenario.quirks || {};
    this.variant = quirks.variant || 'RTL8019AS';
    this.mac = Array.from(scenario.mac || (this.variant === 'NE1000'
      ? [0x00, 0x00, 0x1b, 0x11, 0x22, 0x33] : DEFAULT_MAC));
    this.quirks = {
      loopbackToRing: quirks.loopbackToRing !== false, // MAME default: true
      isrRstOnStop: quirks.isrRstOnStop === true, // real HW: true; MAME default: false
      openBusValue: quirks.openBusValue !== undefined ? quirks.openBusValue : 0xff,
      hangOnResetPort: quirks.hangOnResetPort === true, // UM9003-style clone
      // UM9003F-style read-back: bits the chip does not drive return whatever
      // the previous register-file cycle left behind (page-2 reserved bits,
      // and the undecoded page-0 8019ID offsets).  NICREG must report these
      // as following the bus, not as unstable reads.
      floatingBits: quirks.floatingBits === true,
      // Genuine marginal-bus fault: every Nth register read on `page` comes
      // back with `xor` flipped.  { page, everyN, xor, offset? } -- offset
      // narrows it to one register.  NICREG must FAIL.
      regReadGlitch: quirks.regReadGlitch || null,
      // Register read colliding with receive-buffer DMA: the Nth register
      // read after a frame was stored comes back with `xor` flipped.
      // { afterReads, xor }.  NICREG must pin it on its "live" row only.
      rxDmaGlitch: quirks.rxDmaGlitch || null,
      // A write the chip never latches: every Nth write of the chosen kind
      // is dropped.  { target: 'cr' | 'reg', everyN, runningOnly }.  Seen on
      // real hardware with a started chip: a dropped "CR := page 0" sent the
      // following BNRY write into PAR2.  NICREG must count these and keep
      // its own page switches safe.  pageSwitchOnly limits a 'cr' drop to
      // plain page selects (STA + abort DMA, no TXP, no remote-DMA start):
      // the class the driver reads back.  A lost remote-DMA start or TXP
      // is caught by the RDC/PTX timeouts instead, and the model's strict
      // data-port checks would stop the run on it.  offset and value narrow
      // the drop to one register write, limit caps the number of drops.
      // burst drops that many qualifying writes in a row (default 1): four
      // lost page switches in a row defeat a retry loop of four.
      regWriteDrop: quirks.regWriteDrop || null,
      // The chip sits out whole bus cycles (measured on a UM9003AF with
      // frames on the wire): every Nth register-file access starts a burst
      // of `burst` accesses it takes no part in.  A read then returns what
      // the previous cycle left on the bus; with kind 'both' a write is not
      // latched either.  { everyN, burst, kind: 'read' | 'both', runningOnly }
      busMiss: quirks.busMiss || null,
      // One write that latches with bits flipped: the `nth` write to
      // `offset` on `page`.  { page, offset, nth, xor }
      regWriteFlip: quirks.regWriteFlip || null,
      // Register content that changes behind the host's back: after that
      // many register-file accesses PAR[index] becomes `value`.
      // { afterAccesses, index, value }
      regPoke: quirks.regPoke || null,
      // The remote-DMA data port at offset 0x10, which the register-file
      // quirks above never touch.  `dmaReadGlitch` corrupts the `nth`
      // data-port READ of the run (1-based, counted across all transfers)
      // without disturbing packet RAM, so reading the same bytes again
      // returns them intact.  `dmaWriteDrop` makes the `nth` data-port
      // WRITE not reach packet RAM while the address still advances, so
      // that one byte stays wrong however often it is read back.
      // { nth, xor } / { nth }
      dmaReadGlitch: quirks.dmaReadGlitch || null,
      dmaWriteDrop: quirks.dmaWriteDrop || null,
      // Early UMC UM9003F (measured 2026-09-17): internal loopback completes
      // PTX but the receive side posts neither PRX nor RXE and leaves the
      // ring alone; only ISR.CNT appears.
      loopbackSilent: quirks.loopbackSilent === true,
      // FIFO-path loopback whose RXE lands this many ms after PTX.
      loopbackStatusDelayMs: quirks.loopbackStatusDelayMs || 0,
      // DP8390/NE1000 keeps STA set in the read-back value after STP.
      staStickyOnStop: quirks.staStickyOnStop !== undefined
        ? quirks.staStickyOnStop === true : this.variant === 'NE1000',
      rstStatusOnly: quirks.rstStatusOnly !== undefined
        ? quirks.rstStatusOnly === true : this.variant === 'NE1000',
      remoteDmaStall: quirks.remoteDmaStall === true,
      chipDeadAfterStall: quirks.chipDeadAfterStall === true,
    };
    this.promLayout = scenario.promLayout || 'direct';
    this.prom = buildProm(this.mac, this.promLayout, scenario.promSignature);
    if (this.variant === 'NE1000') {
      // The original NE1000 has a 16-byte PROM.  READ_PROM still requests
      // 32 bytes; the upper half is open bus on the ISA card.
      const p = new Array(32).fill(0xff);
      for (let i = 0; i < 16; i++) p[i] = this.prom[i];
      this.prom = p;
    }
    // 8019ID0/ID1.  A real UM9003AF answers 0x20/0x01, measured on the
    // card -- NOT 0xff, which is also the open-bus value and would let a
    // "clone rejected" test pass for the wrong reason (absent card rather
    // than wrong signature).
    this.id0 = this.variant === 'UM9003' ? 0x20 : (this.variant === 'NE1000' ? 0xff : 0x50);
    this.id1 = this.variant === 'UM9003' ? 0x01 : (this.variant === 'NE1000' ? 0xff : 0x70);

    // Page-0 registers (write side / configured value).
    this.cr = scenario.chipPreStarted ? 0x22 : 0x21;
    this.isr = this.quirks.rstStatusOnly && !scenario.chipPreStarted ? ISR_RST : 0;
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
    this.stopped = !scenario.chipPreStarted;
    this.everStarted = scenario.chipPreStarted === true;

    // NE1000 has 8 KB at 0x2000..0x3FFF; NE2000-compatible cards use the
    // 8 KB slice at 0x4000..0x5FFF in this project.
    this.ramBase = this.variant === 'NE1000' ? 0x2000 : 0x4000;
    this.ramLimit = this.ramBase + 0x2000;
    this.ram = new Uint8Array(0x2000);
    if (scenario.poison !== false) this.ram.fill(0xaa);

    this.transmitted = []; // frames that actually left the wire
    this.txAttempts = 0;
    this.rxDelivered = 0;
    // regCycles counts every register-file cycle the host spends.  It is
    // the metric that tells a driver change apart from a model change when
    // throughput on real hardware moves and instruction counts do not.
    this.stats = { filteredRx: 0, oobDma: 0, overflowEvents: 0, stopEdges: 0, page3Reads: 0, regCycles: 0, dataCycles: 0 };
    this._dmaByteIndex = 0;
    this._dmaReads = 0;
    this._dmaWrites = 0;
    this.lastBus = 0xff;   // last value seen on the register-file data bus
    this._glitchReads = 0;
    this._rxGlitchIn = 0;  // register reads left until the rxDmaGlitch one
    this._dropWrites = 0;
    this._dropBurstLeft = 0;
    this._missCount = 0;
    this._missLeft = 0;
    this._flipWrites = 0;
    this._accesses = 0;
    this.chipDead = false;

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

  // Timer for a responder, fired from the same clock that delivers frames.
  // A protocol peer needs this to model a retransmission timeout: a real
  // sender resends unacknowledged data when its RTO expires, without any
  // prompting from the receiver. Without a timer a responder can only react
  // to frames it receives, so any test in which the client legitimately
  // falls silent (waiting for data it never got) deadlocks the model rather
  // than the code under test.
  scheduleCallback(delayMs, fn) {
    this.pending.push({ atMs: this.currentMs + Math.max(0, delayMs || 0), fn });
  }

  pumpScheduled() {
    if (!this.pending.length) return;
    // Re-check after each batch: a callback may schedule more work that is
    // already due (an RTO that fires into an even later RTO).
    for (let guard = 0; guard < 64; guard++) {
      const ready = [], notYet = [];
      for (const p of this.pending) (p.atMs <= this.currentMs ? ready : notYet).push(p);
      if (!ready.length) return;
      this.pending = notYet;
      // Deliver frames in scheduled order so a single peer's stream is never
      // reordered on the wire, which Ethernet would not do either.
      ready.sort((a, b) => a.atMs - b.atMs);
      for (const p of ready) { if (p.fn) p.fn(); else this.deliverFrame(p.bytes); }
    }
  }

  // ---- reset port (BASE+0x1F) ----
  readResetPort() {
    if (this.quirks.hangOnResetPort) {
      throw new Error('reset port BASE+0x1F read on a card that hangs the ISA cycle here ' +
        '(driver must honour NET_RTL_RESET=SOFT and never touch this port)');
    }
    this.cr = 0x21;
    this.isr |= ISR_RST;
    this.stopped = true;
    this.everStarted = false;
    this.dmaActive = false;
    this.dmaDirection = null;
    return 0xff;
  }

  writeResetPort() { /* NE2000-style: write-back is a documented no-op */ }

  // ---- CR (offset 0x00) ----
  writeCr(value) {
    value &= 0xff;
    this.cr = value;
    const stp = !!(value & 0x01), sta = !!(value & 0x02), txp = !!(value & 0x04);
    if (stp) {
      if (!this.stopped) this.stats.stopEdges++; // running -> offline
      this.stopped = true;
      if (this.quirks.isrRstOnStop || this.quirks.rstStatusOnly) this.isr |= ISR_RST;
    } else if (sta && this.stopped) {
      this.stopped = false;
      this.everStarted = true;
      if (this.quirks.rstStatusOnly) this.isr &= ~ISR_RST;
      this.rxHalted = false; // RECOVER_OVERFLOW's STP->STA edge restarts the RX engine
    }
    const rdField = (value >> 3) & 7;
    if (rdField === 1 || rdField === 2) {
      this.crda = this.rsar;
      this._dmaByteIndex = 0;
      this.dmaDirection = rdField === 1 ? 'read' : 'write';
      this.dmaActive = true;
      if (this.rbcr === 0) { this.isr |= ISR_RDC; this.dmaActive = false; this.dmaDirection = null; }
    } else if (rdField === 4) {
      this.dmaActive = false;
      this.dmaDirection = null;
    }
    if (txp) this.doTransmit();
  }

  // A data-port access with no transfer behind it is normally a driver bug
  // and stops the run.  It stops being one when the scenario is a bus that
  // drops register writes on purpose: the command then never reached the
  // chip, which is exactly what the program under test has to survive and
  // report.  Real hardware answers such a cycle with the open bus and
  // swallows the write; the count is kept so a test can still see it.
  _strayDma(what) {
    if (!this.quirks.busMiss && !this.quirks.regWriteDrop) {
      throw new Error(`remote DMA data port ${what} with no active transfer (RBCR=0 or DMA idle)`);
    }
    this.stats.strayDma = (this.stats.strayDma || 0) + 1;
  }

  // ---- remote DMA data port (offset 0x10) ----
  readData() {
    if (!this.dmaActive || this.dmaDirection !== 'read' || this.rbcr <= 0) {
      this._strayDma('read');
      return this.quirks.openBusValue;
    }
    let value = this.ramReadNic(this.crda);
    if (this.scenario.corruptDmaReadAt !== undefined && this._dmaByteIndex === this.scenario.corruptDmaReadAt) {
      value ^= 0x01;
    }
    const rg = this.quirks.dmaReadGlitch;
    if (rg && ++this._dmaReads === rg.nth) value ^= rg.xor === undefined ? 0x01 : rg.xor;
    this._dmaByteIndex++;
    this.crda = (this.crda + 1) & 0xffff;
    this.rbcr--;
    if (this.rbcr === 0) {
      if (!this.quirks.remoteDmaStall) this.isr |= ISR_RDC;
      else if (this.quirks.chipDeadAfterStall) this.chipDead = true;
      this.dmaActive = false; this.dmaDirection = null;
    }
    return value;
  }

  writeData(value) {
    if (!this.dmaActive || this.dmaDirection !== 'write' || this.rbcr <= 0) {
      this._strayDma('write');
      return;
    }
    const wd = this.quirks.dmaWriteDrop;
    if (!(wd && ++this._dmaWrites === wd.nth)) this.ramWriteNic(this.crda, value & 0xff);
    this._dmaByteIndex++;
    this.crda = (this.crda + 1) & 0xffff;
    this.rbcr--;
    if (this.rbcr === 0) {
      if (!this.quirks.remoteDmaStall) this.isr |= ISR_RDC;
      else if (this.quirks.chipDeadAfterStall) this.chipDead = true;
      this.dmaActive = false; this.dmaDirection = null;
    }
  }

  ramReadNic(addr) {
    if (addr >= this.ramBase && addr < this.ramLimit) return this.ram[addr - this.ramBase];
    if (addr < this.ramBase) return this.prom[addr % this.prom.length];
    this.stats.oobDma++;
    return this.quirks.openBusValue;
  }

  ramWriteNic(addr, value) {
    if (addr >= this.ramBase && addr < this.ramLimit) { this.ram[addr - this.ramBase] = value; return; }
    this.stats.oobDma++;
  }

  // ---- generic page0/1/2/3 register file, offsets 0x01..0x0F ----
  // true when the chip takes no part in this register-file cycle
  _busMissed(isWrite) {
    const poke = this.quirks.regPoke;
    if (poke && ++this._accesses === poke.afterAccesses) this.par[poke.index] = poke.value;
    const q = this.quirks.busMiss;
    if (!q || (q.runningOnly && this.stopped)) return false;
    if (this._missLeft > 0) this._missLeft--;
    else if (++this._missCount % q.everyN === 0) this._missLeft = (q.burst || 1) - 1;
    else return false;
    if (isWrite && q.kind !== 'both') return false;
    this.stats.missedCycles = (this.stats.missedCycles || 0) + 1;
    return true;
  }

  readReg(offset, cycles) {
    if (offset <= 0x0f) this.stats.regCycles++; else this.stats.dataCycles++;
    if (this.chipDead) return 0xff;
    if (offset <= 0x0f && this._busMissed(false)) return this.lastBus;
    const previous = this.lastBus;
    let value = this._readRegRaw(offset) & 0xff;
    const page = (this.cr >> 6) & 3;
    if (this.quirks.floatingBits && offset >= 0x01 && offset <= 0x0f) {
      // defined-bit masks of the page-2 configuration read-back
      const p2 = { 0x0c: 0x3f, 0x0d: 0x1f, 0x0e: 0x7f, 0x0f: 0x7f };
      if (page === 2 && p2[offset] !== undefined) value = (value & p2[offset]) | (previous & ~p2[offset] & 0xff);
      if (page === 0 && (offset === 0x0a || offset === 0x0b)) value = previous;
    }
    const glitch = this.quirks.regReadGlitch;
    if (glitch && page === glitch.page && offset >= 0x01 && offset <= 0x0f &&
        (glitch.offset === undefined || offset === glitch.offset)) {
      if (++this._glitchReads % glitch.everyN === 0) value ^= glitch.xor;
    }
    // A host register read that lands in the chip's own receive-buffer DMA
    // burst, on a bus that does not honour IOCHRDY: one read goes wrong a
    // fixed number of register reads after a frame was STORED.  A frame the
    // filter rejected (or monitor mode dropped) causes no DMA and no glitch.
    if (this._rxGlitchIn > 0 && offset >= 0x01 && offset <= 0x0f && --this._rxGlitchIn === 0) {
      value ^= this.quirks.rxDmaGlitch.xor;
    }
    this.lastBus = value;
    return value;
  }

  _readRegRaw(offset) {
    if (offset === 0x00) return this.quirks.staStickyOnStop && this.stopped && this.everStarted ? (this.cr | 0x02) : this.cr;
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
    // page 3 -- a Realtek extension; a DP8390 clone has none, so the
    // driver must not read here once it knows the chip is not a Realtek.
    this.stats.page3Reads++;
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

  writeReg(offset, value, cycles) {
    if (offset <= 0x0f) this.stats.regCycles++; else this.stats.dataCycles++;
    if (this.chipDead) return undefined;
    value &= 0xff;
    this.lastBus = value;
    if (offset <= 0x0f && this._busMissed(true)) return undefined;
    const drop = this.quirks.regWriteDrop;
    if (drop && offset <= 0x0f && (!drop.runningOnly || !this.stopped) &&
        (drop.target === 'cr') === (offset === 0x00) &&
        (!drop.pageSwitchOnly || (value & 0x3f) === 0x22) &&
        (drop.offset === undefined || offset === drop.offset) &&
        (drop.value === undefined || value === drop.value) &&
        (drop.limit === undefined || (this.stats.droppedWrites || 0) < drop.limit)) {
      if (this._dropBurstLeft > 0 || ++this._dropWrites % drop.everyN === 0) {
        this._dropBurstLeft = this._dropBurstLeft > 0 ? this._dropBurstLeft - 1 : (drop.burst || 1) - 1;
        this.stats.droppedWrites = (this.stats.droppedWrites || 0) + 1;
        return undefined;
      }
    }
    const flip = this.quirks.regWriteFlip;
    if (flip && offset === flip.offset && ((this.cr >> 6) & 3) === flip.page &&
        ++this._flipWrites === flip.nth) value ^= flip.xor;
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
        case 0x07: {
          const rst = this.isr & ISR_RST;
          this.isr &= (~value) & 0xff;
          if (this.quirks.rstStatusOnly && this.stopped) this.isr |= rst || ISR_RST;
          return;
        }
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
    const start = this.tpsrValue * 256 - this.ramBase;
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
      } else if (this.quirks.loopbackSilent) {
        this.isr |= ISR_CNT;
      } else {
        const post = () => {
          this.isr |= ISR_RXE;
          this.rsr = 0x01;
          this.fifo = frame.length ? frame[frame.length - 1] : 0;
        };
        if (this.quirks.loopbackStatusDelayMs) this.scheduleCallback(this.quirks.loopbackStatusDelayMs, post);
        else post();
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
    if (this.quirks.rxDmaGlitch && !options.loopback) this._rxGlitchIn = this.quirks.rxDmaGlitch.afterReads;
  }
}

module.exports = { Rtl8019, buildProm, DEFAULT_MAC, ISR_PRX, ISR_PTX, ISR_RXE, ISR_TXE, ISR_OVW, ISR_CNT, ISR_RDC, ISR_RST };
