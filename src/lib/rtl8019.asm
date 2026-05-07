; ======================================================
; RTL8019AS / DP8390 driver primitives for Sprinter DSS.
;
; All routines assume ISA.ISA_OPEN has been called: the ISA
; window is mapped into 0xC000..0xFFFF and chip registers are
; accessed as memory at the chip's base address + offset.
;
; The chip's window base is held at runtime in RTL_BASE_PTR
; (memmap.inc).  Every public driver function loads IX from
; that variable on entry and addresses registers as
; `(IX + RTL_xxx_OFF)`.  Apps must call RTL.INIT_BASE before
; any other RTL.* function so RTL_BASE_PTR is populated -- it
; either reads N_NET_RTL_IOBASE from the env or auto-scans the
; standard NE2000 candidate bases (0x200..0x3E0 step 0x20).
;
; Routines do NOT toggle the ISA window themselves -- callers
; manage open/close around the inner loops.
;
; Public API (low-level chip primitives are always assembled;
; higher-level helpers are gated by USE_RTL_<name>):
;   RTL.INIT_BASE        find chip / honour RTL_IOBASE; set
;                        RTL_BASE_PTR.  CF=0 OK, CF=1 no chip.
;   RTL.RESET            full NE2000-style reset.
;   RTL.PROBE_ID         read 8019ID0/ID1 -> ID0_RAW, ID1_RAW.
;   RTL.PROBE_PRESENT    bus-latch-defeating presence test.
;   RTL.SNAPSHOT_REGS    capture 10 diagnostic regs.
;   RTL.READ_PROM        read 32 bytes of PROM into (HL).
;   RTL.DMA_READ         remote DMA read.
;   RTL.DMA_WRITE        remote DMA write.
;   RTL.INIT_NORMAL      full chip init for normal TX/RX.
;   RTL.INIT_LOOPBACK    chip init for internal MAC loopback.
;   RTL.WAIT_PTX         poll ISR.PTX with timeout.
;   RTL.SEND_FRAME       DMA-write + TX trigger + wait PTX.
;   RTL.RING_HAS_PACKET  is RX ring non-empty?
;   RTL.READ_PACKET      read 4-byte header + body, advance BNRY.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_RTL8019
	DEFINE	_RTL8019

	INCLUDE "rtl8019.inc"
	INCLUDE "isa.inc"
	INCLUDE "util.asm"

; Timeouts in arbitrary inner-loop units, calibrated empirically.
RTL_RESET_LOOPS		EQU 8000		; ~ ISR.RST poll budget
RTL_RDC_LOOPS		EQU 4000		; remote DMA complete budget

	MODULE RTL

; ------------------------------------------------------
; INIT_BASE: locate the chip, open the right ISA slot, set
; RTL_BASE_PTR to its window address.
;
; Behaviour:
;  - If RTL_BASE_PTR is already non-zero (caller pre-set
;    it from env or NICINFO's manual scan), open ISA and
;    verify the chip responds at that base; if yes, keep it.
;  - Otherwise scan the 16 standard NE2000 jumperless bases
;    (0x200..0x3E0 step 0x20), first on ISA slot 1 (or
;    whatever value the caller put in @ISA.ISA_SLOT), then
;    on the OTHER slot.  First responder wins.
;
; On success ISA is left OPEN and ISA_SLOT correctly set,
; so the caller can continue with RTL.RESET etc.
; On failure ISA is CLOSED.
;
; Out: CF=0 -> RTL_BASE_PTR populated, IX = base, ISA OPEN.
;      CF=1 -> no chip on any slot/base, ISA CLOSED.
; Trashes A, BC, DE, HL, IX.
; ------------------------------------------------------
INIT_BASE
	; RTL_BASE_PTR lives in uninitialized BSS, so we MUST clear it
	; before scanning -- otherwise leftover stack/heap garbage would
	; pose as a pre-set base and the helper PROBE_AT_IX, hitting
	; plain Z80 RAM, would falsely "succeed".  RTL_IOBASE env-var
	; override (followup #24) will be honoured here once wired up.
	LD	HL,0
	LD	(RTL_BASE_PTR),HL
	; Try the currently-selected slot first.
	CALL	@ISA.ISA_OPEN
	CALL	.SCAN_BASES
	RET	NC			; found, ISA stays OPEN
	CALL	@ISA.ISA_CLOSE
	; Flip slot (0 <-> 1) and try again.
	LD	A,(@ISA.ISA_SLOT)
	XOR	1
	LD	(@ISA.ISA_SLOT),A
	CALL	@ISA.ISA_OPEN
	CALL	.SCAN_BASES
	RET	NC
	CALL	@ISA.ISA_CLOSE
	SCF
	RET

; Helper: walk SCAN_TABLE, set RTL_BASE_PTR to first hit.
; Out: CF=0 + IX = base on hit; CF=1 if nothing responds.
.SCAN_BASES
	LD	HL,SCAN_TABLE
.SLP
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	INC	HL
	LD	A,D
	OR	E
	JR	Z,.SNONE
	PUSH	HL			; save table cursor
	LD	H,D
	LD	L,E
	PUSH	HL
	POP	IX
	CALL	PROBE_AT_IX
	POP	HL			; restore table cursor
	JR	C,.SLP
	; Hit: IX still = window addr.
	PUSH	IX
	POP	HL
	LD	(RTL_BASE_PTR),HL
	OR	A
	RET
.SNONE
	SCF
	RET

; Standard NE2000 jumperless I/O bases (in ISA window
; 0xC000..0xFFFF).  Sentinel = DW 0.
SCAN_TABLE
	DW ISA_BASE_A + 0x200
	DW ISA_BASE_A + 0x220
	DW ISA_BASE_A + 0x240
	DW ISA_BASE_A + 0x260
	DW ISA_BASE_A + 0x280
	DW ISA_BASE_A + 0x2A0
	DW ISA_BASE_A + 0x2C0
	DW ISA_BASE_A + 0x2E0
	DW ISA_BASE_A + 0x300
	DW ISA_BASE_A + 0x320
	DW ISA_BASE_A + 0x340
	DW ISA_BASE_A + 0x360
	DW ISA_BASE_A + 0x380
	DW ISA_BASE_A + 0x3A0
	DW ISA_BASE_A + 0x3C0
	DW ISA_BASE_A + 0x3E0
	DW 0


; ------------------------------------------------------
; PROBE_AT_IX: presence test at chip window address in IX.
; HL-based addressing for compatibility with MAME's Sprinter
; ISA emulation (which appeared to mishandle some IX+d
; chip-register accesses in v3.06; see followup #25).
;
; Out: CF=0 chip responds; CF=1 absent.
; Trashes A, BC, DE, HL.  IX preserved.
; ------------------------------------------------------
PROBE_AT_IX
	PUSH	IX
	POP	HL			; HL = base
	; CR (offset 0x00).
	LD	(HL),CR_PAGE0_STOP
	; BNRY (offset 0x03).
	PUSH	HL
	LD	DE,RTL_BNRY_OFF
	ADD	HL,DE
	LD	(HL),0xAA
	; TPSR (offset 0x04).
	INC	HL
	LD	(HL),0x55
	; Read BNRY back.
	DEC	HL
	LD	A,(HL)
	CP	0xAA
	JR	NZ,.MISS
	; Round 2: invert.
	LD	(HL),0x55
	INC	HL
	LD	(HL),0xAA
	DEC	HL
	LD	A,(HL)
	POP	HL
	CP	0x55
	JR	NZ,.MISS_NOPOP
	OR	A
	RET
.MISS
	POP	HL
.MISS_NOPOP
	SCF
	RET

; ------------------------------------------------------
; PROBE_PRESENT: legacy public name, equivalent to
; PROBE_AT_IX with the current RTL_BASE_PTR.  Apps that
; pre-date INIT_BASE may still call this.
; Out: CF=0 chip responds; CF=1 absent.
; ------------------------------------------------------
PROBE_PRESENT
	LD	HL,(RTL_BASE_PTR)
	PUSH	HL
	POP	IX
	JP	PROBE_AT_IX


; ------------------------------------------------------
; Full NE2000-style reset:
;   tmp = (RESET); (RESET) = tmp; delay 2 ms;
;   tmp = (RESET); wait ISR.RST = 1; (ISR) = 0xFF.
; Out: CF=0 OK, CF=1 timeout.
; Trashes A, BC, DE, HL.
; HL-based addressing (rather than IX+d) -- required because
; MAME's Sprinter ISA emulation v3.06 mishandles IX-relative
; chip register access for the RTL8019AS reset port (the read
; that should trigger device_reset() does not always reach
; isa_r()).  See followup #25.
; ------------------------------------------------------
RESET
	LD	HL,(RTL_BASE_PTR)
	LD	DE,RTL_RESET_OFF
	ADD	HL,DE			; HL = RESET port addr
	LD	A,(HL)			; read RESET (release in MAME -> device_reset)
	LD	(HL),A			; write back (no-op on MAME)
	PUSH	HL
	CALL	UTIL.DELAY_2MS
	POP	HL
	LD	A,(HL)			; read RESET again -> device_reset
	; Switch HL to ISR.
	LD	HL,(RTL_BASE_PTR)
	LD	DE,RTL_ISR_OFF
	ADD	HL,DE			; HL = ISR
	LD	BC,RTL_RESET_LOOPS
.WAIT
	LD	A,(HL)
	AND	ISR_RST
	JR	NZ,.OK
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.WAIT
	SCF
	RET
.OK
	LD	A,0xFF
	LD	(HL),A
	OR	A
	RET


; ------------------------------------------------------
; PROBE_ID: read 8019ID0/8019ID1.  Side effect: stores raw
; bytes in ID0_RAW / ID1_RAW.  Out: CF=0 if both 'P','p',
; A=0 on match; otherwise CF=1, A != 0.
; ------------------------------------------------------
PROBE_ID
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START
	LD	A,(IX+RTL_ID0_OFF)
	LD	(ID0_RAW),A
	CP	RTL_ID0_VAL
	JR	NZ,.MISS
	LD	A,(IX+RTL_ID1_OFF)
	LD	(ID1_RAW),A
	CP	RTL_ID1_VAL
	JR	NZ,.MISS
	XOR	A
	RET
.MISS
	LD	A,(IX+RTL_ID1_OFF)
	LD	(ID1_RAW),A
	OR	0xFF
	SCF
	RET

ID0_RAW		DB 0
ID1_RAW		DB 0


; ------------------------------------------------------
; SNAPSHOT_REGS: capture diagnostic registers in fixed order.
; ------------------------------------------------------
SNAPSHOT_REGS
	LD	IX,(RTL_BASE_PTR)
	; Page 0 reads.
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START
	LD	A,(IX+RTL_CR_OFF)
	LD	(REG_SNAPSHOT+0),A
	LD	A,(IX+RTL_ISR_OFF)
	LD	(REG_SNAPSHOT+1),A
	LD	A,(IX+RTL_BNRY_OFF)
	LD	(REG_SNAPSHOT+8),A
	; Page 1 read (CURR).
	LD	(IX+RTL_CR_OFF),CR_PAGE1_STOP
	LD	A,(IX+RTL_CURR_OFF)
	LD	(REG_SNAPSHOT+9),A
	; Page 2 reads (DCR/RCR/TCR/IMR/PSTART/PSTOP).
	LD	(IX+RTL_CR_OFF),CR_PAGE2_STOP
	LD	A,(IX+RTL_DCR_OFF)
	LD	(REG_SNAPSHOT+2),A
	LD	A,(IX+RTL_RCR_OFF)
	LD	(REG_SNAPSHOT+3),A
	LD	A,(IX+RTL_TCR_OFF)
	LD	(REG_SNAPSHOT+4),A
	LD	A,(IX+RTL_IMR_OFF)
	LD	(REG_SNAPSHOT+5),A
	LD	A,(IX+RTL_PSTART_OFF)
	LD	(REG_SNAPSHOT+6),A
	LD	A,(IX+RTL_PSTOP_OFF)
	LD	(REG_SNAPSHOT+7),A
	; Restore CR to page 0 + STA.
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START
	RET

REG_SNAPSHOT	EQU RTL_REG_SNAPSHOT	; 10 bytes in runtime BSS
REG_SNAPSHOT_LEN EQU 10


; ------------------------------------------------------
; DMA_READ: remote DMA read of BC bytes from packet-RAM
; address DE into memory at HL.
; Out: CF=0 OK, CF=1 RDC timeout.
; Trashes A,BC,DE,HL.
; ------------------------------------------------------
DMA_READ
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START | CR_RD2
	LD	(IX+RTL_ISR_OFF),ISR_RDC
	LD	(IX+RTL_RBCR0_OFF),C
	LD	(IX+RTL_RBCR1_OFF),B
	LD	(IX+RTL_RSAR0_OFF),E
	LD	(IX+RTL_RSAR1_OFF),D
	LD	(IX+RTL_CR_OFF),CR_DMA_READ
.LOOP
	LD	A,(IX+RTL_DATA_OFF)
	LD	(HL),A
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.LOOP
	LD	BC,RTL_RDC_LOOPS
.WRDC
	LD	A,(IX+RTL_ISR_OFF)
	AND	ISR_RDC
	JR	NZ,.OK
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.WRDC
	SCF
	RET
.OK
	LD	(IX+RTL_ISR_OFF),ISR_RDC
	OR	A
	RET


; ------------------------------------------------------
; READ_PROM: 32 bytes from PROM (RSAR=0x0000, RBCR=32) into (HL).
; ------------------------------------------------------
READ_PROM
	LD	BC,32
	LD	DE,0x0000
	JP	DMA_READ


; ------------------------------------------------------
; DMA_WRITE: remote DMA write of BC bytes from (HL) to
; packet-RAM address DE.
; Out: CF=0 OK, CF=1 RDC timeout.
; ------------------------------------------------------
DMA_WRITE
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START
	LD	(IX+RTL_ISR_OFF),ISR_RDC
	LD	(IX+RTL_RBCR0_OFF),C
	LD	(IX+RTL_RBCR1_OFF),B
	LD	(IX+RTL_RSAR0_OFF),E
	LD	(IX+RTL_RSAR1_OFF),D
	LD	(IX+RTL_CR_OFF),CR_DMA_WRITE
.LOOP
	LD	A,(HL)
	LD	(IX+RTL_DATA_OFF),A
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.LOOP
	LD	BC,RTL_RDC_LOOPS
.WRDC
	LD	A,(IX+RTL_ISR_OFF)
	AND	ISR_RDC
	JR	NZ,.OK
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.WRDC
	SCF
	RET
.OK
	LD	(IX+RTL_ISR_OFF),ISR_RDC
	OR	A
	RET


; ======================================================
; High-level helpers, each gated by USE_RTL_<name>.
; ======================================================

PTX_LOOPS	EQU 16000

; ------------------------------------------------------
; INIT_NORMAL: full chip init for normal TX/RX.
;   In:  HL = pointer to 6-byte MAC for PAR0..5.
;        A  = RCR value (RCR_AB / 0).
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
	IFDEF USE_RTL_INIT_NORMAL
INIT_NORMAL
	LD	(.RCR_VALUE),A
	PUSH	HL
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_CR_OFF),CR_PAGE0_STOP
	LD	(IX+RTL_DCR_OFF),DCR_INIT
	LD	(IX+RTL_RBCR0_OFF),0
	LD	(IX+RTL_RBCR1_OFF),0
	LD	A,(.RCR_VALUE)
	LD	(IX+RTL_RCR_OFF),A
	LD	(IX+RTL_TCR_OFF),TCR_NORMAL
	LD	(IX+RTL_TPSR_OFF),RTL_TPSR_INIT
	LD	(IX+RTL_PSTART_OFF),RTL_PSTART_INIT
	LD	(IX+RTL_PSTOP_OFF),RTL_PSTOP_INIT
	LD	(IX+RTL_BNRY_OFF),RTL_BNRY_INIT
	LD	(IX+RTL_ISR_OFF),0xFF
	LD	(IX+RTL_IMR_OFF),0
	; Page 1: PAR + CURR + MAR.
	LD	(IX+RTL_CR_OFF),CR_PAGE1_STOP
	POP	HL
	; LDIR target (DE) = IX + PAR0_OFF.
	PUSH	IX
	POP	DE
	LD	A,RTL_PAR0_OFF
	ADD	A,E
	LD	E,A
	LD	A,0
	ADC	A,D
	LD	D,A
	LD	BC,6
	LDIR
	LD	(IX+RTL_CURR_OFF),RTL_CURR_INIT
	LD	(IX+RTL_MAR0_OFF + 0),0
	LD	(IX+RTL_MAR0_OFF + 1),0
	LD	(IX+RTL_MAR0_OFF + 2),0
	LD	(IX+RTL_MAR0_OFF + 3),0
	LD	(IX+RTL_MAR0_OFF + 4),0
	LD	(IX+RTL_MAR0_OFF + 5),0
	LD	(IX+RTL_MAR0_OFF + 6),0
	LD	(IX+RTL_MAR0_OFF + 7),0
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START
	RET
.RCR_VALUE	DB 0
	ENDIF


; ------------------------------------------------------
; INIT_LOOPBACK: init for internal MAC loopback test.
;   DCR=0x40, TCR=0x02, RCR=RCR_AB.
; In: HL = MAC ptr.
; ------------------------------------------------------
	IFDEF USE_RTL_INIT_LOOPBACK
INIT_LOOPBACK
	PUSH	HL
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_CR_OFF),CR_PAGE0_STOP
	LD	(IX+RTL_DCR_OFF),DCR_LOOPBACK
	LD	(IX+RTL_RBCR0_OFF),0
	LD	(IX+RTL_RBCR1_OFF),0
	LD	(IX+RTL_RCR_OFF),RCR_AB
	LD	(IX+RTL_TCR_OFF),TCR_LB_INTERNAL
	LD	(IX+RTL_TPSR_OFF),RTL_TPSR_INIT
	LD	(IX+RTL_PSTART_OFF),RTL_PSTART_INIT
	LD	(IX+RTL_PSTOP_OFF),RTL_PSTOP_INIT
	LD	(IX+RTL_BNRY_OFF),RTL_BNRY_INIT
	LD	(IX+RTL_ISR_OFF),0xFF
	LD	(IX+RTL_IMR_OFF),0
	LD	(IX+RTL_CR_OFF),CR_PAGE1_STOP
	POP	HL
	PUSH	IX
	POP	DE
	LD	A,RTL_PAR0_OFF
	ADD	A,E
	LD	E,A
	LD	A,0
	ADC	A,D
	LD	D,A
	LD	BC,6
	LDIR
	LD	(IX+RTL_CURR_OFF),RTL_CURR_INIT
	LD	(IX+RTL_MAR0_OFF + 0),0
	LD	(IX+RTL_MAR0_OFF + 1),0
	LD	(IX+RTL_MAR0_OFF + 2),0
	LD	(IX+RTL_MAR0_OFF + 3),0
	LD	(IX+RTL_MAR0_OFF + 4),0
	LD	(IX+RTL_MAR0_OFF + 5),0
	LD	(IX+RTL_MAR0_OFF + 6),0
	LD	(IX+RTL_MAR0_OFF + 7),0
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START
	RET
	ENDIF


; ------------------------------------------------------
; WAIT_PTX: poll ISR.PTX with timeout.
; ------------------------------------------------------
	IFDEF USE_RTL_WAIT_PTX
WAIT_PTX
	LD	IX,(RTL_BASE_PTR)
	LD	BC,PTX_LOOPS
.LP
	LD	A,(IX+RTL_ISR_OFF)
	AND	ISR_PTX
	JR	NZ,.OK
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.LP
	SCF
	RET
.OK
	LD	(IX+RTL_ISR_OFF),ISR_PTX
	OR	A
	RET
	ENDIF


; ------------------------------------------------------
; SEND_FRAME: DMA-write BC bytes from (HL) to packet RAM
; 0x4000, set TBCR, trigger TX, wait PTX.
;   In: HL = source, BC = length.
; ------------------------------------------------------
	IFDEF USE_RTL_SEND_FRAME
SEND_FRAME
	LD	(.LEN),BC
	LD	DE,0x4000
	CALL	DMA_WRITE
	RET	C
	; DMA_WRITE loaded IX; reuse it for TBCR/CR.
	LD	BC,(.LEN)
	LD	(IX+RTL_TBCR0_OFF),C
	LD	(IX+RTL_TBCR1_OFF),B
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START | CR_TXP
	JP	WAIT_PTX
.LEN	DW 0
	ENDIF


; ------------------------------------------------------
; RING_HAS_PACKET: ZF=1 if RX ring is empty (BNRY+1==CURR).
; ------------------------------------------------------
	IFDEF USE_RTL_RING_HAS_PACKET
RING_HAS_PACKET
	LD	IX,(RTL_BASE_PTR)
	LD	A,(IX+RTL_BNRY_OFF)
	INC	A
	CP	RTL_PSTOP_INIT
	JR	C,.NW
	LD	A,RTL_PSTART_INIT
.NW
	LD	B,A
	LD	(IX+RTL_CR_OFF),CR_PAGE1_START
	LD	A,(IX+RTL_CURR_OFF)
	LD	C,A
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START
	LD	A,B
	CP	C
	RET
	ENDIF


; ------------------------------------------------------
; READ_PACKET: read 4-byte RX header at (BNRY+1)<<8, body
; bytes at +4.  Auto-advances BNRY = header.next - 1.
;   In:  HL = header buffer (4 bytes).
;        DE = body buffer.
;        BC = max body length.
;   Out: CF=0 + BC = body length read; CF=1 DMA error.
; ------------------------------------------------------
	IFDEF USE_RTL_READ_PACKET
READ_PACKET
	LD	(.HDR_PTR),HL
	LD	(.BODY_PTR),DE
	LD	(.MAX_LEN),BC
	LD	IX,(RTL_BASE_PTR)
	; Compute hdr_addr = (BNRY+1)<<8 with PSTOP wrap.
	LD	A,(IX+RTL_BNRY_OFF)
	INC	A
	CP	RTL_PSTOP_INIT
	JR	C,.NW
	LD	A,RTL_PSTART_INIT
.NW
	LD	D,A
	LD	E,0
	LD	(.PKT_ADDR),DE
	; Read 4-byte header.
	LD	HL,(.HDR_PTR)
	LD	BC,4
	CALL	DMA_READ
	RET	C
	; body_len_candidate = (hdr.len) - 4.
	LD	HL,(.HDR_PTR)
	INC	HL
	INC	HL
	LD	A,(HL)
	LD	C,A
	INC	HL
	LD	A,(HL)
	LD	B,A
	LD	H,B
	LD	L,C
	LD	BC,4
	OR	A
	SBC	HL,BC
	; Cap at MAX_LEN.
	LD	BC,(.MAX_LEN)
	LD	A,H
	CP	B
	JR	C,.LEN_OK
	JR	NZ,.LEN_CAP
	LD	A,L
	CP	C
	JR	C,.LEN_OK
.LEN_CAP
	LD	H,B
	LD	L,C
.LEN_OK
	LD	(.BODY_LEN),HL
	; Compute body source address.
	LD	DE,(.PKT_ADDR)
	INC	DE
	INC	DE
	INC	DE
	INC	DE
	LD	(.BODY_ADDR),DE
	; remaining_in_ring = PSTOP*256 - body_addr.
	LD	HL,RTL_PSTOP_INIT * 256
	OR	A
	SBC	HL,DE
	LD	(.FIRST_LEN),HL
	; Compare remaining vs body_len.
	LD	BC,(.BODY_LEN)
	LD	A,H
	CP	B
	JR	C,.DO_SPLIT
	JR	NZ,.DO_SINGLE
	LD	A,L
	CP	C
	JR	C,.DO_SPLIT
.DO_SINGLE
	LD	BC,(.BODY_LEN)
	LD	DE,(.BODY_ADDR)
	LD	HL,(.BODY_PTR)
	CALL	DMA_READ
	RET	C
	JR	.READ_DONE
.DO_SPLIT
	LD	BC,(.FIRST_LEN)
	LD	DE,(.BODY_ADDR)
	LD	HL,(.BODY_PTR)
	CALL	DMA_READ
	RET	C
	LD	HL,(.BODY_LEN)
	LD	BC,(.FIRST_LEN)
	OR	A
	SBC	HL,BC
	LD	B,H
	LD	C,L
	LD	A,B
	OR	C
	JR	Z,.READ_DONE
	LD	HL,(.BODY_PTR)
	PUSH	BC
	LD	BC,(.FIRST_LEN)
	ADD	HL,BC
	POP	BC
	LD	DE,RTL_PSTART_INIT * 256
	CALL	DMA_READ
	RET	C
.READ_DONE
	; Advance BNRY = hdr.next - 1, wrap PSTART -> PSTOP-1.
	LD	IX,(RTL_BASE_PTR)
	LD	HL,(.HDR_PTR)
	INC	HL
	LD	A,(HL)
	DEC	A
	CP	RTL_PSTART_INIT
	JR	NC,.OK_BNRY
	LD	A,RTL_PSTOP_INIT - 1
.OK_BNRY
	LD	(IX+RTL_BNRY_OFF),A
	LD	BC,(.BODY_LEN)
	OR	A
	RET
.HDR_PTR	DW 0
.BODY_PTR	DW 0
.MAX_LEN	DW 0
.PKT_ADDR	DW 0
.BODY_LEN	DW 0
.BODY_ADDR	DW 0
.FIRST_LEN	DW 0
	ENDIF


	ENDMODULE
	ENDIF
