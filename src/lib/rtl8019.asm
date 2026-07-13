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

	; INIT_BASE's TRY_ENV_OVERRIDE parses the canonical
	; "S/#HHH" env value via UTIL.PARSE_HEX_NIBBLE; ensure it
	; is enabled before util.asm is pulled in.
	IFNDEF USE_UTIL_PARSE_HEX_BYTE
	DEFINE USE_UTIL_PARSE_HEX_BYTE
	ENDIF

	INCLUDE "rtl8019.inc"
	INCLUDE "isa.inc"
	INCLUDE "util.asm"
	INCLUDE "dss.inc"		; DSS_ENVIRON, ENV_GET/SET

; Timeouts in arbitrary inner-loop units, calibrated empirically.
RTL_RESET_LOOPS		EQU 8000		; ~ ISR.RST poll budget
RTL_RDC_LOOPS		EQU 4000		; remote DMA complete budget
RTL_PROBE_TRIES		EQU 3			; presence-probe attempts (cold HW)
RTL_PROBE_SETTLE	EQU 64			; DJNZ count: ISA settle before read-back
RTL_HDR_RETRIES	EQU 4			; RX header re-read attempts before drop
; Inter-byte busy waits do not lengthen the active ISA strobe.  They only keep
; MMU3 mapped to ISA with interrupts disabled; SETTLE=32 held a max-frame DMA
; open for longer than a 50 Hz system tick on real Sprinter hardware.
RTL_DMA_SETTLE		EQU 0

	MODULE RTL

; ------------------------------------------------------
; INIT_BASE: locate the chip, open the right ISA slot, set
; RTL_BASE_PTR to its window address.
;
; Two-stage strategy:
;  1. Try the env override "NET_RTL_HW" (canonical "S/#HHH";
;     written by NETCFG from net.cfg's RTL_HW= line, or
;     persisted by an earlier successful auto-scan).  If the
;     value parses cleanly AND the chip responds at that
;     slot/base, accept it -- no scan, no ISA churn.
;  2. Otherwise scan the 16 standard NE2000 jumperless bases
;     (0x200..0x3E0 step 0x20) on the currently-selected ISA
;     slot, then the other slot.  First responder wins, and
;     its discovered slot/base is written back to env so
;     subsequent utilities in the same DSS session take the
;     fast path.
;
; ISA must be CLOSED at entry (caller comes here before any
; chip activity).  On success ISA is left OPEN and ISA_SLOT
; reflects the chosen slot.  On failure ISA is CLOSED.
;
; Out: CF=0 -> RTL_BASE_PTR populated, IX = base, ISA OPEN.
;      CF=1 -> no chip on any slot/base, ISA CLOSED.
; Trashes A, BC, DE, HL, IX.
; ------------------------------------------------------
INIT_BASE
	; RTL_BASE_PTR lives in uninitialized BSS; clear it so the
	; helpers see a clean slate.
	LD	HL,0
	LD	(RTL_BASE_PTR),HL

	; Stage 1: env override.
	CALL	TRY_ENV_OVERRIDE
	RET	NC			; ISA OPEN, base accepted

	; Stage 2: auto-scan currently-selected slot, then the other.
	CALL	@ISA.ISA_OPEN
	CALL	.SCAN_BASES
	JR	NC,.SCAN_OK
	CALL	@ISA.ISA_CLOSE
	LD	A,(@ISA.ISA_SLOT)
	XOR	1
	LD	(@ISA.ISA_SLOT),A
	CALL	@ISA.ISA_OPEN
	CALL	.SCAN_BASES
	JR	NC,.SCAN_OK
	CALL	@ISA.ISA_CLOSE
	SCF
	RET
.SCAN_OK
	; Persist S/#HHH to env so subsequent utilities in the same
	; DSS session take the fast path.  This may overwrite a
	; (wrong) net.cfg-supplied value -- the user has already
	; been warned by TRY_ENV_OVERRIDE; fixing net.cfg on disk
	; is their responsibility, but in-memory the session is
	; self-healing so each program doesn't need to re-scan.
	; WRITE_ENV_HW briefly closes/reopens ISA around the SETENV
	; call (DSS env data lives at 0xE400 which is in PAGE3, our
	; ISA window).
	CALL	WRITE_ENV_HW
	OR	A
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
; TRY_ENV_OVERRIDE: parse N_NET_RTL_HW (if set) into a slot
; and an I/O base, configure ISA, and probe.
; Pre-condition: ISA closed at entry.
;   Out: CF=0 -> env valid AND chip responded; ISA OPEN,
;                @ISA.ISA_SLOT and RTL_BASE_PTR populated.
;        CF=1 -> env missing/malformed/no-response; ISA CLOSED,
;                RTL_BASE_PTR cleared, ISA_SLOT untouched.
; Trashes A, BC, DE, HL, IX.
; Uses NETENV_VAL_BUF as the GETENV destination (always
; defined in memmap.inc; safe to reference here without
; pulling in netenv_lib).
; ------------------------------------------------------
TRY_ENV_OVERRIDE
	LD	HL,N_RTL_HW
	LD	DE,NETENV_VAL_BUF
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	OR	A			; A=0xFF found, 0 not
	JR	Z,.SILENT		; env not set: silent fallback
	LD	HL,NETENV_VAL_BUF
	LD	A,(HL)
	OR	A
	JR	Z,.SILENT		; "found" but value empty
	CALL	PARSE_HW_VALUE		; A=slot, DE=addr on success
	JR	C,.WARN			; malformed
	; Configure ISA + RTL_BASE_PTR from parsed value.
	LD	(@ISA.ISA_SLOT),A
	LD	HL,ISA_BASE_A
	ADD	HL,DE
	LD	(RTL_BASE_PTR),HL
	PUSH	HL
	POP	IX
	CALL	@ISA.ISA_OPEN
	CALL	PROBE_AT_IX
	JR	C,.PROBE_NO
	OR	A
	RET
.PROBE_NO
	CALL	@ISA.ISA_CLOSE
.WARN
	; Env had a value but either parsing failed or no chip
	; responded.  Print a warning so the user notices the
	; net.cfg setting was bypassed, then fall through to the
	; auto-scan path.  ISA is CLOSED here either way.
	LD	HL,0
	LD	(RTL_BASE_PTR),HL
	LD	HL,MSG_HW_FALLBACK_PRE
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,NETENV_VAL_BUF
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,MSG_HW_FALLBACK_POST
	LD	C,DSS_PCHARS
	RST	DSS
.SILENT
	SCF
	RET

MSG_HW_FALLBACK_PRE	DB "[W] NET_RTL_HW=",0
MSG_HW_FALLBACK_POST	DB " not usable, auto-scanning.",13,10,0


; ------------------------------------------------------
; PARSE_HW_VALUE: ASCIIZ at HL holds "S/N", "S/#N",
; "S/0xN" or "S/0XN".  S in {0,1}; N is 1..3 hex digits
; in {0x200..0x3E0 step 0x20}.
;   Out: CF=0 -> A = slot, DE = I/O address.
;        CF=1 -> malformed.
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
PARSE_HW_VALUE
	LD	A,(HL)
	SUB	'0'
	CP	2
	JR	NC,.BAD
	LD	(.SLOT),A
	INC	HL
	LD	A,(HL)
	CP	'/'
	JR	NZ,.BAD
	INC	HL
	LD	A,(HL)
	CP	'#'
	JR	NZ,.NH
	INC	HL
	JR	.HEX
.NH
	CP	'0'
	JR	NZ,.HEX
	; '0' could be "0x"/"0X" prefix or a leading-zero hex digit.
	PUSH	HL
	INC	HL
	LD	A,(HL)
	CP	'x'
	JR	Z,.PFX
	CP	'X'
	JR	Z,.PFX
	POP	HL
	JR	.HEX
.PFX
	INC	HL
	POP	DE			; discard saved
.HEX
	LD	DE,0
	LD	B,3
.HLP
	LD	A,(HL)
	CALL	@UTIL.PARSE_HEX_NIBBLE
	JR	C,.HEND
	LD	C,A
	EX	DE,HL
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	LD	A,L
	OR	C
	LD	L,A
	EX	DE,HL
	INC	HL
	DJNZ	.HLP
.HEND
	; Validate range and 0x20 alignment.
	LD	A,D
	CP	2
	JR	C,.BAD
	CP	4
	JR	NC,.BAD
	LD	A,E
	AND	0x1F
	JR	NZ,.BAD
	LD	A,(.SLOT)
	OR	A			; CF=0
	RET
.BAD
	SCF
	RET
.SLOT		DB 0


; ------------------------------------------------------
; WRITE_ENV_HW: format the current slot/base as
; "NET_RTL_HW=S/#HHH\0" and SETENV.  ISA must be OPEN at
; entry; we briefly close it for the SETENV call (DSS env
; storage lives at 0xE400 which is in PAGE3) and reopen.
; CF and any DSS error are silently absorbed -- the override
; is best-effort persistence, not load-bearing.
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
WRITE_ENV_HW
	CALL	@ISA.ISA_CLOSE
	; Build "NET_RTL_HW=S/#HHH\0" in NETENV_VAL_BUF (reused).
	LD	HL,N_RTL_HW
	LD	DE,NETENV_VAL_BUF
.CN
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	OR	A
	JR	NZ,.CN
	DEC	DE			; back to NUL
	LD	A,'='
	LD	(DE),A
	INC	DE
	LD	A,(@ISA.ISA_SLOT)
	ADD	A,'0'
	LD	(DE),A
	INC	DE
	LD	A,'/'
	LD	(DE),A
	INC	DE
	LD	A,'#'
	LD	(DE),A
	INC	DE
	; Address = (RTL_BASE_PTR - ISA_BASE_A); 12 valid bits,
	; printed as 3 uppercase hex digits.
	LD	HL,(RTL_BASE_PTR)
	LD	A,H
	SUB	HIGH ISA_BASE_A
	AND	0x0F
	CALL	.NIB
	LD	(DE),A
	INC	DE
	LD	A,L
	RRCA
	RRCA
	RRCA
	RRCA
	AND	0x0F
	CALL	.NIB
	LD	(DE),A
	INC	DE
	LD	A,L
	AND	0x0F
	CALL	.NIB
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	; SETENV.
	LD	HL,NETENV_VAL_BUF
	LD	B,ENV_SET
	LD	C,DSS_ENVIRON
	RST	DSS
	JP	@ISA.ISA_OPEN

.NIB
	CP	10
	JR	C,.D9
	ADD	A,'A' - 10
	RET
.D9
	ADD	A,'0'
	RET


N_RTL_HW	DB "NET_RTL_HW",0


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
	; Retry the R/W test a few times.  On a cold real RTL8019AS the
	; very first ISA accesses can return stale/floating data (and a
	; read-back issued immediately after a write may sample before
	; the bus settles), so a single pass produced false "absent"
	; results on hardware while MAME -- which makes registers R/W
	; instantly -- always passed.  Each pass inserts a short
	; settling delay before the read-back; a single good pass is
	; enough to declare the chip present.  See followup: cold probe.
	LD	B,RTL_PROBE_TRIES
.ATTEMPT
	PUSH	BC
	CALL	.ONE_PASS
	POP	BC
	RET	NC			; chip responded
	DJNZ	.ATTEMPT
	SCF				; all attempts failed -> absent
	RET

.ONE_PASS
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
	; Read BNRY back (after a settling delay).
	DEC	HL
	CALL	.SETTLE
	LD	A,(HL)
	CP	0xAA
	JR	NZ,.MISS
	; Round 2: invert.
	LD	(HL),0x55
	INC	HL
	LD	(HL),0xAA
	DEC	HL
	CALL	.SETTLE
	LD	A,(HL)
	POP	HL
	CP	0x55
	JR	NZ,.MISS_NOPOP
	; A floating or mirrored ISA window can pass the simple R/W
	; test above.  The real target is RTL8019AS, so require the
	; page-0 ID bytes as well before accepting an auto-scan hit.
	PUSH	IX
	POP	HL
	LD	(HL),CR_PAGE0_STOP
	LD	DE,RTL_ID0_OFF
	ADD	HL,DE
	CALL	.SETTLE
	LD	A,(HL)
	CP	RTL_ID0_VAL
	JR	NZ,.MISS_NOPOP
	INC	HL
	CALL	.SETTLE
	LD	A,(HL)
	CP	RTL_ID1_VAL
	JR	NZ,.MISS_NOPOP
	OR	A
	RET
.MISS
	POP	HL
.MISS_NOPOP
	SCF
	RET

; Short ISA-settling busy-wait.  No DSS calls -- safe with the ISA
; window open.  Preserves every register the probe relies on.
.SETTLE
	PUSH	BC
	LD	B,RTL_PROBE_SETTLE
.SD
	DJNZ	.SD
	POP	BC
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
	; MMU3 must not remain mapped to ISA across millisecond delays.
	; RESET is a public primitive that enters/exits with ISA open, so
	; briefly close it for pacing and reopen before the second access.
	CALL	@ISA.ISA_CLOSE
	CALL	UTIL.DELAY_2MS
	CALL	@ISA.ISA_OPEN
	LD	HL,(RTL_BASE_PTR)
	LD	DE,RTL_RESET_OFF
	ADD	HL,DE
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
	; Page 0 readable state.
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
	; Page 2 provides the actual readable values for the page-0
	; write-side configuration registers.  Read hardware, not software
	; shadows, so a lost/corrupt write remains visible in diagnostics.
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
	CALL	DMA_SETTLE		; let the chip prefetch the first FIFO byte
.LOOP
	CALL	DMA_SETTLE		; let the FIFO present the next byte
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
	LD	(IX+RTL_CR_OFF),CR_DMA_ABORT	; leave a clean, non-DMA state
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
	CALL	DMA_SETTLE		; let the chip arm the remote-write FIFO
.LOOP
	LD	A,(HL)
	LD	(IX+RTL_DATA_OFF),A
	CALL	DMA_SETTLE		; let the FIFO drain to packet RAM
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
	LD	(IX+RTL_CR_OFF),CR_DMA_ABORT	; leave a clean, non-DMA state
	OR	A
	RET


; ------------------------------------------------------
; DMA_SETTLE: short busy-wait giving the chip's remote-DMA FIFO
; time to present (read) or accept (write) a byte.  No DSS calls,
; no chip access -- safe with the ISA window open.  Preserves all
; registers the DMA loops rely on (A, BC, DE, HL, IX).
; ------------------------------------------------------
DMA_SETTLE
	IF RTL_DMA_SETTLE > 0
	PUSH	AF
	PUSH	BC
	LD	B,RTL_DMA_SETTLE
.SD
	DJNZ	.SD
	POP	BC
	POP	AF
	ENDIF
	RET


; ======================================================
; High-level helpers, each gated by USE_RTL_<name>.
; ======================================================

PTX_LOOPS	EQU 16000
TX_IDLE_LOOPS	EQU 16000
TX_CLEAR_TRIES	EQU 32
TX_DMA_TRIES	EQU 3
TX_VERIFY_PREFIX EQU 42			; ETH + IPv4/ARP header prefix
TX_STATUS_BITS	EQU ISR_PTX | ISR_TXE
RX_TO_TX_GUARD_MS EQU 20		; one 50 Hz system-tick interval

; TX_LAST_STAGE values.  Success walks 01 -> 04; E* values
; identify the exact failed transition for capture-then-print
; diagnostics after the caller closes the ISA window.
TX_STAGE_IDLE	EQU 0x01
TX_STAGE_DMA	EQU 0x02
TX_STAGE_ARMED	EQU 0x03
TX_STAGE_DONE	EQU 0x04
TX_ERR_DMA	EQU 0xE0
TX_ERR_BUSY	EQU 0xE1
TX_ERR_STALE_ISR EQU 0xE2
TX_ERR_CMD	EQU 0xE3			; reserved: old TXP re-trigger probe
TX_ERR_TIMEOUT	EQU 0xE4
TX_ERR_TXE	EQU 0xE5
TX_ERR_VERIFY	EQU 0xE6

TX_LAST_STAGE	EQU RTL_TX_LAST_STAGE
TX_LAST_ISR	EQU RTL_TX_LAST_ISR
TX_LAST_TSR	EQU RTL_TX_LAST_TSR
TX_LAST_CR	EQU RTL_TX_LAST_CR
TX_SOURCE_PTR	EQU RTL_TX_SOURCE_PTR
TX_LENGTH	EQU RTL_TX_LENGTH
TX_RETRY_LEFT	EQU RTL_TX_RETRY_LEFT
TX_VERIFY_BUF	EQU RTL_TX_VERIFY_BUF
TX_LAST_CLDA	EQU RTL_TX_LAST_CLDA
TX_CFG0_PRE	EQU RTL_TX_CFG0_PRE
TX_CFG3_PRE	EQU RTL_TX_CFG3_PRE
TX_CFG0_POST	EQU RTL_TX_CFG0_POST
TX_CFG3_POST	EQU RTL_TX_CFG3_POST
TX_LAST_NCR	EQU RTL_TX_LAST_NCR
TX_LAST_TPSR	EQU RTL_TX_LAST_TPSR

; ------------------------------------------------------
; INIT_NORMAL: full chip init for normal TX/RX.
;   In:  HL = pointer to 6-byte MAC for PAR0..5.
;        A  = RCR value (RCR_AB / 0).
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
	IFDEF USE_RTL_INIT_NORMAL
INIT_NORMAL
	LD	(.RCR_VALUE),A
	XOR	A
	LD	(RTL_RX_TO_TX_PENDING),A
	PUSH	HL
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_CR_OFF),CR_PAGE0_STOP
	LD	(IX+RTL_DCR_OFF),DCR_INIT
	LD	(IX+RTL_RBCR0_OFF),0
	LD	(IX+RTL_RBCR1_OFF),0
	; Keep RX out of the ring while PAR/CURR/MAR are still being
	; programmed.  Enabling normal receive too early is harmless in
	; MAME but unstable on real DP8390/RTL8019AS hardware.
	LD	(IX+RTL_RCR_OFF),RCR_MON
	LD	(IX+RTL_TCR_OFF),TCR_LB_INTERNAL
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
	LD	(IX+RTL_TCR_OFF),TCR_NORMAL
	LD	A,(.RCR_VALUE)
	LD	(IX+RTL_RCR_OFF),A
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
	XOR	A
	LD	(RTL_RX_TO_TX_PENDING),A
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
; WAIT_PTX: wait for a NEW transmit result.  SEND_FRAME has
; already verified that stale PTX/TXE bits were clear before
; issuing TXP, so either bit here belongs to this transmission.
; PTX succeeds; TXE is an immediate failure (do not burn the
; whole timeout waiting for PTX after the chip reported an error).
; ------------------------------------------------------
	IFDEF USE_RTL_WAIT_PTX
WAIT_PTX
	LD	IX,(RTL_BASE_PTR)
	LD	BC,PTX_LOOPS
.LP
	LD	A,(IX+RTL_ISR_OFF)
	AND	TX_STATUS_BITS
	JR	NZ,.EVENT
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.LP
	LD	A,TX_ERR_TIMEOUT
	LD	(TX_LAST_STAGE),A
	CALL	CAPTURE_TX_STATE
	SCF
	RET
.EVENT
	CALL	CAPTURE_TX_STATE
	CALL	CAPTURE_TX_PHY_POST
	LD	A,(TX_LAST_ISR)
	AND	ISR_TXE
	JR	NZ,.TX_ERROR
	LD	A,TX_STATUS_BITS
	LD	(IX+RTL_ISR_OFF),A
	LD	A,TX_STAGE_DONE
	LD	(TX_LAST_STAGE),A
	OR	A
	RET
.TX_ERROR
	LD	A,TX_STATUS_BITS
	LD	(IX+RTL_ISR_OFF),A
	LD	A,TX_ERR_TXE
	LD	(TX_LAST_STAGE),A
	SCF
	RET
	ENDIF


; ------------------------------------------------------
; SEND_FRAME: DMA-write BC bytes from (HL) to the packet RAM
; page selected by RTL_TPSR_INIT, set TBCR, trigger TX, wait PTX.
;   In: HL = source, BC = length.
; ------------------------------------------------------
	IFDEF USE_RTL_SEND_FRAME
SEND_FRAME
	LD	(TX_SOURCE_PTR),HL
	LD	(TX_LENGTH),BC
	; Mark per-attempt PHY diagnostics invalid until their exact phase is
	; reached.  This prevents a pre-TX failure from printing values left by
	; an older frame.
	LD	A,0xFF
	LD	(TX_CFG0_PRE),A
	LD	(TX_CFG3_PRE),A
	LD	(TX_CFG0_POST),A
	LD	(TX_CFG3_POST),A
	LD	(TX_LAST_NCR),A
	LD	(TX_LAST_TPSR),A
	; A successful RX immediately followed by TX is unreliable on the
	; real Sprinter/RTL8019AS combination.  The v0.2.6 A/B test proved
	; that one extra post-ARP screen line makes the same unicast ICMP
	; frame work.  Replace that accidental delay with an explicit guard
	; while the ISA window is CLOSED and system interrupts are enabled.
	LD	A,(RTL_RX_TO_TX_PENDING)
	OR	A
	JR	Z,.NO_RX_GUARD
	XOR	A
	LD	(RTL_RX_TO_TX_PENDING),A
	CALL	@ISA.ISA_CLOSE
	LD	HL,RX_TO_TX_GUARD_MS
	CALL	UTIL.DELAY_MS
	CALL	@ISA.ISA_OPEN
.NO_RX_GUARD
	LD	IX,(RTL_BASE_PTR)
	; Never overwrite TPSR packet RAM while an earlier transmit is
	; still active.  More importantly, this establishes a clean
	; transition instead of treating the previous packet's PTX as
	; completion of the new one.
	LD	BC,TX_IDLE_LOOPS
.WAIT_IDLE
	LD	A,(IX+RTL_CR_OFF)
	AND	CR_TXP
	JR	Z,.IDLE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.WAIT_IDLE
	LD	A,TX_ERR_BUSY
	LD	(TX_LAST_STAGE),A
	CALL	CAPTURE_TX_STATE
	SCF
	RET
.IDLE
	LD	A,TX_STAGE_IDLE
	LD	(TX_LAST_STAGE),A
	LD	A,TX_DMA_TRIES
	LD	(TX_RETRY_LEFT),A
.DMA_ATTEMPT
	LD	HL,(TX_SOURCE_PTR)
	LD	D,RTL_TPSR_INIT
	LD	E,0
	LD	BC,(TX_LENGTH)
	CALL	DMA_WRITE
	JR	C,.DMA_ERROR
	; A successful RDC only proves that the byte count reached zero.
	; Read back the protocol/header prefix before TXP so a marginal ISA
	; write cannot silently turn into PTX=success for a malformed frame.
	; The short (max 42-byte) verification keeps the ISA-open interval
	; bounded; it covers both MAC addresses, EtherType and the complete
	; IPv4 header (or most of an ARP body).
	LD	HL,(TX_SOURCE_PTR)
	LD	BC,(TX_LENGTH)
	CALL	VERIFY_TX_PREFIX
	JR	NC,.DMA_OK
	LD	A,TX_ERR_VERIFY
	JR	.DMA_RETRY
.DMA_ERROR
	LD	A,TX_ERR_DMA
.DMA_RETRY
	LD	(TX_LAST_STAGE),A
	LD	HL,TX_RETRY_LEFT
	DEC	(HL)
	JR	NZ,.DMA_ATTEMPT
	CALL	CAPTURE_TX_STATE
	SCF
	RET
.DMA_OK
	; Stage 02 now means DMA write AND prefix read-back both passed.
	LD	A,TX_STAGE_DMA
	LD	(TX_LAST_STAGE),A
	; DMA_WRITE loaded IX; reuse it for status/TBCR/CR.
	LD	IX,(RTL_BASE_PTR)
	LD	BC,(TX_LENGTH)
	LD	(IX+RTL_TBCR0_OFF),C
	LD	(IX+RTL_TBCR1_OFF),B
	; ISR is write-one-to-clear.  Clear BOTH terminal TX bits and
	; read them back until clear.  The old code wrote PTX once and
	; immediately polled it after TXP; a delayed or lost clear can let
	; the previous ARP's PTX masquerade as completion of the following
	; ICMP frame.  The field retest will show whether this was the
	; observed failure or only a latent repeat-TX bug.
	LD	B,TX_CLEAR_TRIES
.CLEAR_STATUS
	LD	A,TX_STATUS_BITS
	LD	(IX+RTL_ISR_OFF),A
	LD	A,(IX+RTL_ISR_OFF)
	AND	TX_STATUS_BITS
	JR	Z,.STATUS_CLEAR
	DJNZ	.CLEAR_STATUS
	LD	A,TX_ERR_STALE_ISR
	LD	(TX_LAST_STAGE),A
	CALL	CAPTURE_TX_STATE
	SCF
	RET
.STATUS_CLEAR
	; Capture the medium actually selected and duplex configuration at the
	; physical TX boundary.  Page 3 is read-only here; restore page 0 before
	; issuing the single TXP command.
	CALL	CAPTURE_TX_PHY_PRE
	; TXP is an edge-like command and MUST be written exactly once.
	; Do not re-issue it when an immediate CR/ISR read has not yet
	; exposed TXP/PTX: on real hardware those reads can lag, and the
	; old three-try "acceptance" probe produced three ARP frames and
	; could disturb an in-progress unicast transmission.  WAIT_PTX
	; proves acceptance by observing a new PTX/TXE; no event -> E4.
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START | CR_TXP
	LD	A,TX_STAGE_ARMED
	LD	(TX_LAST_STAGE),A
	JP	WAIT_PTX
	ENDIF


; ------------------------------------------------------
; VERIFY_TX_PREFIX: compare the first min(BC,42) bytes of
; packet RAM at RTL_TPSR_INIT*256 with the caller's source buffer.
; A short read-back detects corrupted Ethernet/IP/ARP headers
; without doubling the ISA-open time for a maximum-size frame.
;   In: HL = source, BC = full frame length.
;   Out: CF=0 identical + RDC; CF=1 mismatch/RDC timeout.
; ------------------------------------------------------
VERIFY_TX_PREFIX
	LD	A,B
	OR	A
	JR	NZ,.CAP_LENGTH
	LD	A,C
	CP	TX_VERIFY_PREFIX + 1
	JR	C,.HAVE_LENGTH
.CAP_LENGTH
	LD	BC,TX_VERIFY_PREFIX
.HAVE_LENGTH
	LD	DE,TX_VERIFY_BUF
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START
	LD	(IX+RTL_ISR_OFF),ISR_RDC
	LD	(IX+RTL_RBCR0_OFF),C
	LD	(IX+RTL_RBCR1_OFF),B
	LD	(IX+RTL_RSAR0_OFF),0
	LD	(IX+RTL_RSAR1_OFF),RTL_TPSR_INIT
	LD	(IX+RTL_CR_OFF),CR_DMA_READ
	CALL	DMA_SETTLE
.COMPARE
	LD	A,(IX+RTL_DATA_OFF)
	LD	(DE),A
	INC	DE
	CP	(HL)
	JR	NZ,.MISMATCH
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.COMPARE
	LD	BC,RTL_RDC_LOOPS
.WAIT_RDC
	LD	A,(IX+RTL_ISR_OFF)
	AND	ISR_RDC
	JR	NZ,.OK
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.WAIT_RDC
	LD	(IX+RTL_CR_OFF),CR_DMA_ABORT
	SCF
	RET
.MISMATCH
	LD	(IX+RTL_CR_OFF),CR_DMA_ABORT
	LD	(IX+RTL_ISR_OFF),ISR_RDC
	SCF
	RET
.OK
	LD	(IX+RTL_ISR_OFF),ISR_RDC
	LD	(IX+RTL_CR_OFF),CR_DMA_ABORT
	OR	A
	RET


; ------------------------------------------------------
; CAPTURE_TX_STATE: snapshot page-0 TX status without printing.
; Requires ISA open; capture-then-print discipline applies.
; ------------------------------------------------------
CAPTURE_TX_STATE
	LD	IX,(RTL_BASE_PTR)
	; SEND_FRAME/WAIT_PTX always operate on page 0.  Read CR before
	; anything else and do not rewrite it here: on a busy timeout a
	; write without TXP would destroy the state we are diagnosing.
	LD	A,(IX+RTL_CR_OFF)
	LD	(TX_LAST_CR),A
	LD	A,(IX+RTL_ISR_OFF)
	LD	(TX_LAST_ISR),A
	LD	A,(IX+RTL_TSR_OFF)
	LD	(TX_LAST_TSR),A
	LD	A,(IX+RTL_NCR_OFF)
	LD	(TX_LAST_NCR),A
	; Page-0 offsets 01/02 are read-side CLDA0/CLDA1.  Capture the raw
	; local-DMA address for diagnostics only.  It is shared with local
	; receive activity and is not a TX byte counter; traffic arriving
	; before this snapshot can move it away from TPSR + TBCR.
	LD	A,(IX+RTL_PSTART_OFF)
	LD	(TX_LAST_CLDA + 0),A
	LD	A,(IX+RTL_PSTOP_OFF)
	LD	(TX_LAST_CLDA + 1),A
	RET


; ------------------------------------------------------
; CAPTURE_TX_PHY_PRE / POST: read RTL8019AS CONFIG0 and
; CONFIG3 around TXP.  These snapshots distinguish a stable
; UTP/half-duplex configuration from TP/CX auto-detect changing
; medium while the frame is being transmitted.  Requires ISA open;
; no DSS calls, no EEPROM writes.  Transmission is not active when
; either routine is called, so changing CR page bits is safe.
; ------------------------------------------------------
CAPTURE_TX_PHY_PRE
	LD	IX,(RTL_BASE_PTR)
	; Page 2 exposes the write-only-on-page-0 TPSR value.  Capture it at
	; the exact TX boundary so PTX cannot hide transmission from a stale or
	; corrupted packet-RAM page.
	LD	(IX+RTL_CR_OFF),CR_PAGE2_START
	LD	A,(IX+RTL_TPSR_OFF)
	LD	(TX_LAST_TPSR),A
	LD	(IX+RTL_CR_OFF),CR_PAGE3_START
	LD	A,(IX+RTL_CONFIG0_OFF)
	LD	(TX_CFG0_PRE),A
	LD	A,(IX+RTL_CONFIG3_OFF)
	LD	(TX_CFG3_PRE),A
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START
	RET

CAPTURE_TX_PHY_POST
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_CR_OFF),CR_PAGE3_START
	LD	A,(IX+RTL_CONFIG0_OFF)
	LD	(TX_CFG0_POST),A
	LD	A,(IX+RTL_CONFIG3_OFF)
	LD	(TX_CFG3_POST),A
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START
	RET


; ------------------------------------------------------
; RING_HAS_PACKET: ZF=1 if RX ring is empty (BNRY+1==CURR).
; ------------------------------------------------------
	IFDEF USE_RTL_RING_HAS_PACKET
RING_HAS_PACKET
	LD	IX,(RTL_BASE_PTR)
	; Service an RX-ring overflow before reporting ring state.  When
	; CURR catches BNRY the DP8390/RTL8019AS sets ISR.OVW and STOPS
	; storing further frames until the documented overflow-recovery
	; runs -- otherwise RX is wedged for good (classic "got one packet
	; then nothing" symptom).  Every wait loop polls through here, so
	; recovering at this single point keeps all utilities unwedged
	; under load (busy LAN, slow drain) without touching the apps.
	; ISR == 0xFF is a floating-bus glitch read (all latched bits set
	; incl. RST is implausible during normal RX), not a real overflow
	; -- skip recovery so a glitch does not trigger a needless
	; stop/restart.
	LD	A,(IX+RTL_ISR_OFF)
	CP	0xFF
	JR	Z,.GLITCH
	AND	ISR_OVW
	CALL	NZ,RECOVER_OVERFLOW
	; Read BNRY and validate it is a real ring page.  On marginal
	; silicon a register read can float to 0xFF (undriven ISA bus);
	; an out-of-range BNRY/CURR is such a glitch.  Treat it as "ring
	; empty" so the caller ticks (window closed -> bus/IRQ recover)
	; instead of DMA-reading garbage from page 0 (BNRY=FF -> address
	; 0x0000 = PROM/registers), which corrupts ring state and stalls.
	LD	A,(IX+RTL_BNRY_OFF)
	CP	RTL_PSTART_INIT
	JR	C,.GLITCH
	CP	RTL_PSTOP_INIT
	JR	NC,.GLITCH
	INC	A
	CP	RTL_PSTOP_INIT
	JR	C,.NW
	LD	A,RTL_PSTART_INIT
.NW
	LD	B,A
	LD	(IX+RTL_CR_OFF),CR_PAGE1_START
	LD	A,(IX+RTL_CURR_OFF)
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START
	; Validate CURR likewise.
	CP	RTL_PSTART_INIT
	JR	C,.GLITCH
	CP	RTL_PSTOP_INIT
	JR	NC,.GLITCH
	LD	C,A
	LD	A,B
	CP	C
	RET
.GLITCH
	; Impossible register read (floating 0xFF): report ring empty.
	XOR	A
	RET

; ------------------------------------------------------
; RECOVER_OVERFLOW: DP8390/RTL8019AS RX-ring overflow recovery.
; Follows the National DP8390 datasheet sequence: stop the chip,
; let any in-flight DMA finish, mask the ring with internal
; loopback, flush every queued frame by re-syncing BNRY/CURR,
; clear ISR.OVW and resume normal RX.  Flushing (rather than
; reading the queued frames out) costs us the packets that were
; in the ring at overflow time -- acceptable: the higher-level
; retransmit/retry recovers them, and the alternative (a wedged
; receiver) loses every subsequent frame.  This driver polls TX
; to completion before entering any RX wait, so no transmit is
; ever in progress here and the datasheet "resend" step is moot.
; In:  IX = chip base.  Trashes A.  (DELAY_2MS preserves IX/DE/HL.)
; ------------------------------------------------------
RECOVER_OVERFLOW
	LD	(IX+RTL_CR_OFF),CR_PAGE0_STOP	; STP + abort DMA
	; Wait with the system page restored and IRQs enabled.  Reopen the
	; same slot/base and reload IX before touching the NIC again.
	CALL	@ISA.ISA_CLOSE
	CALL	UTIL.DELAY_2MS			; wait out any in-flight RX/TX DMA (~1.6ms)
	CALL	@ISA.ISA_OPEN
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_RBCR0_OFF),0
	LD	(IX+RTL_RBCR1_OFF),0
	LD	(IX+RTL_TCR_OFF),TCR_LB_INTERNAL	; loopback: no new frames enter the ring
	; Flush the ring while stopped: drop everything, re-sync pointers.
	LD	(IX+RTL_BNRY_OFF),RTL_BNRY_INIT
	LD	(IX+RTL_CR_OFF),CR_PAGE1_STOP
	LD	(IX+RTL_CURR_OFF),RTL_CURR_INIT
	LD	(IX+RTL_CR_OFF),CR_PAGE0_STOP
	LD	(IX+RTL_ISR_OFF),0xFF		; clear OVW + all latched status
	LD	(IX+RTL_TCR_OFF),TCR_NORMAL
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START	; resume normal RX
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
	LD	A,RTL_HDR_RETRIES
	LD	(.HDR_TRIES),A
	; Read 4-byte header.
.READ_HDR
	LD	HL,(.HDR_PTR)
	LD	BC,4
	CALL	DMA_READ
	RET	C
	; Validate RX status and next-page before trusting length.
	LD	HL,(.HDR_PTR)
	LD	A,(HL)			; status
	AND	ISR_PRX
	JP	Z,.BAD_HEADER_RETRY
	INC	HL
	LD	A,(HL)			; next page
	CALL	VALID_RX_PAGE_A
	JP	C,.BAD_HEADER_RETRY
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
	JP	C,.BAD_HEADER_RETRY
	; Require a plausible Ethernet frame body.  The body length
	; here excludes the DP8390's stored CRC.
	LD	A,H
	OR	A
	JR	NZ,.MIN_OK
	LD	A,L
	CP	14
	JP	C,.BAD_HEADER_RETRY
.MIN_OK
	; Reject frames that do not fit the caller's buffer.  Do not
	; cap silently: a corrupt RX header would make us read from the
	; wrong ring area and poison subsequent protocol parsing.
	LD	BC,(.MAX_LEN)
	LD	A,B
	CP	H
	JP	C,.BAD_HEADER_RETRY
	JR	NZ,.LEN_OK
	LD	A,C
	CP	L
	JP	C,.BAD_HEADER_RETRY
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
	CALL	SET_BNRY_FROM_NEXT_A
	LD	(IX+RTL_ISR_OFF),ISR_PRX | ISR_RXE | ISR_OVW
	LD	A,1
	LD	(RTL_RX_TO_TX_PENDING),A
	LD	BC,(.BODY_LEN)
	OR	A
	RET
.BAD_HEADER_RETRY
	LD	HL,.HDR_TRIES
	DEC	(HL)
	JP	NZ,.READ_HDR
.BAD_HEADER
	; Bad status/length usually means a transient remote-DMA read
	; glitch.  Re-reading above handles the transient case.  If the
	; stored next page is sane, drop just this ring slot; otherwise
	; advance BNRY by one page.  Avoid resyncing to CURR here: on
	; real hardware a single bad header read can otherwise discard a
	; whole burst of queued ARP/DHCP replies.
	LD	HL,(.HDR_PTR)
	INC	HL
	LD	A,(HL)
	CALL	VALID_RX_PAGE_A
	JP	C,.DROP_ONE_PAGE
	CALL	SET_BNRY_FROM_NEXT_A
	LD	(IX+RTL_ISR_OFF),ISR_PRX | ISR_RXE | ISR_OVW
	SCF
	RET
.DROP_ONE_PAGE
	LD	IX,(RTL_BASE_PTR)
	LD	HL,(.PKT_ADDR)
	LD	A,H
	LD	(IX+RTL_BNRY_OFF),A
	LD	(IX+RTL_ISR_OFF),ISR_PRX | ISR_RXE | ISR_OVW
	SCF
	RET
.HDR_PTR	DW 0
.BODY_PTR	DW 0
.MAX_LEN	DW 0
.PKT_ADDR	DW 0
.BODY_LEN	DW 0
.BODY_ADDR	DW 0
.FIRST_LEN	DW 0
.HDR_TRIES	DB 0

; VALID_RX_PAGE_A: CF=0 if A is in [PSTART, PSTOP), CF=1 otherwise.
VALID_RX_PAGE_A
	CP	RTL_PSTART_INIT
	JR	C,.BAD
	CP	RTL_PSTOP_INIT
	JR	NC,.BAD
	OR	A
	RET
.BAD
	SCF
	RET

; SET_BNRY_FROM_NEXT_A: A = packet next page (or CURR for resync).
; Writes BNRY = A-1, wrapping PSTART -> PSTOP-1.  Requires IX = base.
SET_BNRY_FROM_NEXT_A
	DEC	A
	CP	RTL_PSTART_INIT
	JR	NC,.OK
	LD	A,RTL_PSTOP_INIT - 1
.OK
	LD	(IX+RTL_BNRY_OFF),A
	RET
	ENDIF


	ENDMODULE
	ENDIF
