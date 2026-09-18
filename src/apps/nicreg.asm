; ======================================================
; NICREG.EXE - NIC register read-stability diagnostic.
;
; Question it answers: when a register read comes back different
; from one dump to the next, is the chip DRIVING that bit and the
; host misreading it (a real bus fault), or is the bit simply not
; driven at all, so the read returns whatever was on the bus a
; moment earlier (harmless)?
;
; Method: every read of a target register is immediately preceded
; by a read of a "conditioner" -- a read/write register preset to
; 0x00 in one pass and 0xFF in the other.  A driven bit reads the
; same in both passes.  An undriven bit follows the conditioner.
; A bit that differs WITHIN one pass is a genuine unstable read.
;
; Phases (chip stopped unless noted):
;   [G1] read/write storage: PAR0..5, CURR, MAR0..6 hold known
;        patterns; every misread is counted.  This is the ground
;        truth -- all 8 bits of these registers are implemented.
;   [G2] page-2 read-back of the configuration written on page 0.
;        Defined bits must match; reserved bits are only reported.
;   [G3] page-0 status registers: reported, only CR is checked.
;   [G4] one read + write/read-back loop against the chip
;        stopped, started but deaf (RCR=MON), and live on the
;        LAN.  Counts misreads, lost and garbled writes, and
;        dropped page switches.
;   [G5] only with -t: 3 x 20 test frames, EtherType 88B5, to be
;        counted on a peer:  A = minimal TX + tight ISR polling,
;        B = minimal TX + no chip access for 2 ms, C = the kit's
;        own RTL.SEND_FRAME.  Marker byte + sequence in the payload.
;
; ISA discipline: the window is opened per 256-read burst (about
; 1.5 ms at 21 MHz), never across a DSS call or a delay.  The
; alternate register set is used only inside one such burst, with
; interrupts off.  No page-3 access, no reset-port access beyond
; what RTL.RESET decides for the detected chip.
; ======================================================

EXE_VERSION		EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "memmap.inc"
	INCLUDE "rtl8019.inc"

	DEFINE USE_UTIL_EXIT_NO_NIC	; fast-fail "no NIC" path
	DEFINE USE_CMDL
	DEFINE USE_RTL_INIT_NORMAL
	DEFINE USE_RTL_SEND_FRAME
	DEFINE USE_RTL_WAIT_PTX

; -- test sizing --
G1_REGS		EQU 14			; PAR0..5, CURR, MAR0..6 (MAR7 conditions)
G1_BURSTS	EQU 2			; x256 reads per (pattern, residue) pass
					; => 2 patterns * 2 residues * 512 = 2048/reg
G4_TICKS	EQU 1500		; ~1 ms each
G4_ITER		EQU 32			; PAR0..5 sweeps per tick => 288000 reads
	ASSERT G4_TICKS * G4_ITER * 6 == 288000	; keep MSG_G4_TAIL in step
G4_SAMPLES	EQU 6			; misreads kept verbatim per row
G4_WR_REGS	EQU 4			; MAR0..3: on a wrong page these offsets
					; are RSAR/RBCR, harmless without a DMA command
G4_WSAMPLES	EQU 4			; failed writes kept verbatim per row
	ASSERT G4_TICKS * G4_ITER * G4_WR_REGS == 192000
CR_VERIFY_MASK	EQU 0xC3		; page select + STA/STP
TX_FRAMES	EQU 20
TX_GAP_MS	EQU 10
PTX_POLLS	EQU 16000
FRAME_LEN	EQU 60
ETH_TYPE	EQU 0x88B5		; IEEE local experimental
SETTLE_LOOPS	EQU 64			; write recovery, as RTL.PROBE_AT_IX does

; Configuration written before [G2] and read back on page 2.
G2_RCR_VAL	EQU RCR_AB
G2_TCR_VAL	EQU TCR_LB_INTERNAL	; nothing can reach the wire while stopped

TBL_ENTRY_SIZE	EQU 8			; offset, expected, mask, 5-char name

	MODULE MAIN

	; Small variant: no arguments beyond one short flag.  The stack
	; lives at the top of our own WIN2 page, not at 0x8100, so it
	; cannot run down into the command line that CMDL.PARSE
	; tokenizes in place.
	ORG 0x8080

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0080
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START
	DW START
	DW RT_STACK_TOP
	DS 106, 0

	ORG 0x8100

START
	LD	(CMDL_SOURCE_PTR),IX	; must precede every CALL/RST DSS
	PRINTLN MSG_BANNER
	CALL	@CMDL.PARSE
	CALL	@CMDL.IS_HELP
	JP	NC,SHOW_HELP
	CALL	CLEAR_STATE
	LD	A,'t'
	CALL	@CMDL.HAS_FLAG
	JR	C,.NO_T
	LD	A,1
	LD	(OPT_TX),A
.NO_T
	LD	A,1
	LD	(@ISA.ISA_SLOT),A
	CALL	@RTL.INIT_BASE		; leaves ISA OPEN on success
	JP	C,@UTIL.EXIT_NO_NIC
	CALL	@RTL.RESET
	JP	C,RESET_FAIL
	CALL	STOP_SETUP
	CALL	@ISA.ISA_CLOSE

	; [G0] Slot/Addr: N/#HHH chip=...
	PRINT	MSG_G0
	LD	A,(@ISA.ISA_SLOT)
	ADD	A,'0'
	CALL	PUTCHAR
	PRINT	MSG_G0_SEP
	LD	HL,(RTL_BASE_PTR)
	LD	A,H
	SUB	HIGH ISA_BASE_A
	CALL	PUT_NIBBLE
	LD	A,L
	RRCA
	RRCA
	RRCA
	RRCA
	CALL	PUT_NIBBLE
	LD	A,L
	CALL	PUT_NIBBLE
	LD	HL,MSG_CHIP_CLONE
	LD	A,(RTL_CHIP_KIND)
	CP	RTL_CHIP_REALTEK
	JR	NZ,.KIND
	LD	HL,MSG_CHIP_REALTEK
.KIND
	PRINTLN_HL

	CALL	PHASE_G1
	CALL	PHASE_G2
	CALL	PHASE_G3
	CALL	PHASE_G4
	LD	A,(OPT_TX)
	OR	A
	CALL	NZ,PHASE_G5

	; Leave the controller stopped, as we found it.
	CALL	@ISA.ISA_OPEN
	LD	HL,(RTL_BASE_PTR)
	LD	A,CR_PAGE0_STOP
	CALL	WR
	CALL	@ISA.ISA_CLOSE

	LD	A,(FAILED)
	OR	A
	JR	NZ,RESULT_FAIL
	PRINTLN	MSG_RESULT_OK
	DSS_RETURN EX_OK

RESET_FAIL
	CALL	@ISA.ISA_CLOSE
	PRINTLN	MSG_E_RESET
RESULT_FAIL
	PRINTLN	MSG_RESULT_FAIL
	DSS_RETURN EX_NIC_ERR

SHOW_HELP
	PRINT	MSG_HELP
	DSS_RETURN EX_OK


; ------------------------------------------------------
; CLEAR_STATE: BSS is not zeroed by the loader.
; ------------------------------------------------------
CLEAR_STATE
	LD	HL,BSS_START
	LD	DE,BSS_START + 1
	LD	BC,BSS_CLEAR_LEN - 1
	LD	(HL),0
	LDIR
	LD	A,0xFF			; AND accumulators start saturated
	LD	(TXA_ISR_AND),A
	LD	(TXA_TSR_AND),A
	LD	(TXB_ISR_AND),A
	LD	(TXB_TSR_AND),A
	RET


; ------------------------------------------------------
; REG_ADDR: HL = chip window base + A.  Trashes A.
; ------------------------------------------------------
REG_ADDR
	LD	HL,(RTL_BASE_PTR)
	ADD	A,L
	LD	L,A
	RET	NC
	INC	H
	RET

; ------------------------------------------------------
; WR: (HL) = A, then a write-recovery pause.  A clone that
; needs I/O recovery time swallows the second of two
; back-to-back writes, and this test depends on its writes.
; Preserves everything but flags.  ISA open; no DSS.
; ------------------------------------------------------
WR
	LD	(HL),A
	PUSH	BC
	LD	B,SETTLE_LOOPS
.SD
	DJNZ	.SD
	POP	BC
	RET

; ------------------------------------------------------
; STOP_SETUP: stopped chip with a known configuration.
; ISA open.  Trashes A, DE, HL.
; ------------------------------------------------------
STOP_SETUP
	LD	HL,(RTL_BASE_PTR)
	LD	A,CR_PAGE0_STOP
	CALL	WR
	LD	DE,STOP_CFG
.LP
	LD	A,(DE)
	CP	0xFF
	RET	Z
	INC	DE
	CALL	REG_ADDR
	LD	A,(DE)
	INC	DE
	CALL	WR
	JR	.LP

STOP_CFG
	DB RTL_DCR_OFF, DCR_INIT
	DB RTL_RBCR0_OFF, 0
	DB RTL_RBCR1_OFF, 0
	DB RTL_RCR_OFF, G2_RCR_VAL
	DB RTL_TCR_OFF, G2_TCR_VAL
	DB RTL_TPSR_OFF, RTL_TPSR_INIT
	DB RTL_PSTART_OFF, RTL_PSTART_INIT
	DB RTL_PSTOP_OFF, RTL_PSTOP_INIT
	DB RTL_BNRY_OFF, RTL_BNRY_INIT
	DB RTL_ISR_OFF, 0xFF
	DB RTL_IMR_OFF, 0
	DB 0xFF

; ------------------------------------------------------
; WRITE_P0: write A to page-0 register C.  Opens and closes
; the window itself.  Trashes A, B, HL.
; ------------------------------------------------------
WRITE_P0
	LD	B,A
	CALL	@ISA.ISA_OPEN
	LD	HL,(RTL_BASE_PTR)
	LD	A,CR_PAGE0_STOP
	CALL	WR
	LD	A,C
	CALL	REG_ADDR
	LD	A,B
	CALL	WR
	JP	@ISA.ISA_CLOSE


; ------------------------------------------------------
; BURST: 256 conditioned reads of one target register.
;   In:  HL = conditioner address, DE = target address,
;        C = expected target value (already masked),
;        B' = AND accumulator, C' = OR accumulator,
;        DE' = misread count; COND_EXP / TGT_MASK patched.
; The conditioner read and the target read are one EX AF,AF'
; apart -- nothing else touches the bus in between.  Global
; labels throughout: the two patch slots below would
; otherwise capture the local-label scope.
; ISA open, interrupts off; no DSS.
; ------------------------------------------------------
BURST
	LD	B,0			; 256 passes
BURST_LP
	LD	A,(HL)			; conditioner: leaves a known value behind
	EX	AF,AF'
	LD	A,(DE)			; target
	EXX
	LD	L,A
	AND	B
	LD	B,A
	LD	A,L
	OR	C
	LD	C,A
	LD	A,L
	EXX
	AND	0xFF
TGT_MASK EQU $-1
	CP	C
	JR	Z,BURST_T_OK
	EXX
	INC	DE
	EXX
BURST_T_OK
	EX	AF,AF'
	CP	0
COND_EXP EQU $-1
	CALL	NZ,BURST_COND_MISS
	DJNZ	BURST_LP
	RET
BURST_COND_MISS
	PUSH	HL
	LD	HL,(COND_BAD)
	INC	HL
	LD	(COND_BAD),HL
	POP	HL
	RET

; ------------------------------------------------------
; RUN_BURSTS: A bursts of 256 reads against TGT_ADDR with
; COND_ADDR as conditioner, page CUR_PAGE_CR.  Accumulates
; into ACC_AND / ACC_OR / ACC_BAD.  One ISA window per burst;
; the alternate set never survives a window.
; ------------------------------------------------------
RUN_BURSTS
	PUSH	AF
	CALL	@ISA.ISA_OPEN
	LD	HL,(RTL_BASE_PTR)
	LD	A,(CUR_PAGE_CR)
	CALL	WR
	EXX
	LD	A,(ACC_AND)
	LD	B,A
	LD	A,(ACC_OR)
	LD	C,A
	LD	DE,(ACC_BAD)
	EXX
	LD	A,(TGT_EXP)
	LD	C,A
	LD	HL,(COND_ADDR)
	LD	DE,(TGT_ADDR)
	CALL	BURST
	EXX
	LD	A,B
	LD	(ACC_AND),A
	LD	A,C
	LD	(ACC_OR),A
	LD	(ACC_BAD),DE
	EXX
	LD	HL,(RTL_BASE_PTR)
	LD	A,CR_PAGE0_STOP
	CALL	WR
	CALL	@ISA.ISA_CLOSE
	POP	AF
	DEC	A
	JR	NZ,RUN_BURSTS
	RET

ACC_RESET
	LD	A,0xFF
	LD	(ACC_AND),A
	XOR	A
	LD	(ACC_OR),A
	LD	(ACC_BAD),A
	LD	(ACC_BAD + 1),A
	RET


; ======================================================
; [G1] read/write storage.
; ======================================================
PHASE_G1
	XOR	A
	LD	(PASS_PAT),A
G1_PAT_LOOP
	XOR	A
	LD	(PASS_RES),A
G1_RES_LOOP
	CALL	G1_LOAD
	LD	A,(PASS_RES)
	LD	(COND_EXP),A
	LD	A,0xFF
	LD	(TGT_MASK),A
	XOR	A
	LD	(REG_INDEX),A
G1_REG_LOOP
	LD	A,(REG_INDEX)
	INC	A			; PAR0 is offset 1
	CALL	REG_ADDR
	LD	(TGT_ADDR),HL
	LD	A,(REG_INDEX)
	CALL	G1_EXPECTED
	LD	(TGT_EXP),A
	CALL	ACC_RESET
	LD	A,G1_BURSTS
	CALL	RUN_BURSTS
	CALL	G1_FOLD
	LD	HL,REG_INDEX
	INC	(HL)
	LD	A,(HL)
	CP	G1_REGS
	JR	C,G1_REG_LOOP
	LD	A,(PASS_RES)
	CPL
	LD	(PASS_RES),A
	OR	A
	JR	NZ,G1_RES_LOOP		; 00 -> FF runs again, FF -> 00 is done
	LD	A,(PASS_PAT)
	CPL
	LD	(PASS_PAT),A
	OR	A
	JR	NZ,G1_PAT_LOOP
	JP	G1_PRINT

; G1_EXPECTED: A = index -> A = pattern byte for this pass.
; Preserves BC, DE, HL.
G1_EXPECTED
	PUSH	HL,DE
	LD	E,A
	LD	D,0
	LD	HL,G1_PATTERN
	ADD	HL,DE
	LD	A,(PASS_PAT)
	XOR	(HL)
	POP	DE,HL
	RET

; G1_LOAD: write the patterns and the conditioner (MAR7).
G1_LOAD
	CALL	@ISA.ISA_OPEN
	LD	HL,(RTL_BASE_PTR)
	LD	A,CR_PAGE1_STOP
	CALL	WR
	LD	BC,G1_REGS * 256	; B = count, C = index
.LP
	LD	A,C
	INC	A
	CALL	REG_ADDR
	LD	A,C
	CALL	G1_EXPECTED
	CALL	WR
	INC	C
	DJNZ	.LP
	LD	A,RTL_MAR7_OFF
	CALL	REG_ADDR
	LD	(COND_ADDR),HL
	LD	A,(PASS_RES)
	CALL	WR
	LD	HL,(RTL_BASE_PTR)
	LD	A,CR_PAGE0_STOP
	CALL	WR
	LD	A,CR_PAGE1_STOP
	LD	(CUR_PAGE_CR),A
	JP	@ISA.ISA_CLOSE

; G1_FOLD: fold one (register, pass) result into the totals.
G1_FOLD
	; wrong bits = (exp & ~AND) | (~exp & OR)
	LD	A,(ACC_AND)
	CPL
	LD	B,A
	LD	A,(TGT_EXP)
	AND	B
	LD	C,A
	LD	A,(TGT_EXP)
	CPL
	LD	B,A
	LD	A,(ACC_OR)
	AND	B
	OR	C
	LD	C,A
	LD	A,(REG_INDEX)
	LD	E,A
	LD	D,0
	LD	HL,G1_ERR
	ADD	HL,DE
	LD	A,C
	OR	(HL)
	LD	(HL),A
	; per-register misread count
	LD	HL,G1_BAD
	ADD	HL,DE
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	PUSH	HL
	LD	HL,(ACC_BAD)
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	LD	(HL),D
	DEC	HL
	LD	(HL),E
	; per-residue total
	LD	HL,G1_TOT00
	LD	A,(PASS_RES)
	OR	A
	JR	Z,.TOT
	LD	HL,G1_TOTFF
.TOT
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	PUSH	HL
	LD	HL,(ACC_BAD)
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	LD	(HL),D
	DEC	HL
	LD	(HL),E
	RET

G1_PRINT
	PRINTLN	MSG_G1
	PRINT	MSG_G1_00
	LD	HL,(G1_TOT00)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_G1_FF
	LD	HL,(G1_TOTFF)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_COND
	LD	HL,(COND_BAD)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	LINE_END
	; any misread at all fails the run
	LD	HL,(G1_TOT00)
	LD	DE,(G1_TOTFF)
	LD	A,H
	OR	L
	OR	D
	OR	E
	LD	HL,(COND_BAD)
	OR	H
	OR	L
	CALL	NZ,SET_FAILED
	; list the offenders (at most 6 lines: the screen is one photo)
	XOR	A
	LD	(REG_INDEX),A
	LD	A,6
	LD	(LINES_LEFT),A
.LP
	LD	A,(REG_INDEX)
	LD	E,A
	LD	D,0
	LD	HL,G1_BAD
	ADD	HL,DE
	ADD	HL,DE
	LD	A,(HL)
	INC	HL
	OR	(HL)
	JR	Z,.NEXT
	LD	A,(LINES_LEFT)
	OR	A
	JR	Z,.NEXT
	DEC	A
	LD	(LINES_LEFT),A
	LD	A,' '
	CALL	PUTCHAR
	; name = G1_NAMES + index * 5
	LD	A,(REG_INDEX)
	LD	E,A
	ADD	A,A
	ADD	A,A
	ADD	A,E
	LD	E,A
	LD	D,0
	LD	HL,G1_NAMES
	ADD	HL,DE
	CALL	PUT_NAME5
	PRINT	MSG_BAD_EQ
	LD	A,(REG_INDEX)
	LD	E,A
	LD	D,0
	LD	HL,G1_BAD
	ADD	HL,DE
	ADD	HL,DE
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_BITS_EQ
	LD	A,(REG_INDEX)
	LD	E,A
	LD	D,0
	LD	HL,G1_ERR
	ADD	HL,DE
	LD	A,(HL)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	LINE_END
.NEXT
	LD	HL,REG_INDEX
	INC	(HL)
	LD	A,(HL)
	CP	G1_REGS
	JR	C,.LP
	RET

SET_FAILED
	LD	A,1
	LD	(FAILED),A
	RET


; ======================================================
; Table-driven phases [G2] and [G3].
; ======================================================

; RUN_TABLE: measure every table entry after a 00 and after
; an FF conditioner read.
;   In:  HL = table, DE = results (4 bytes/entry: and00, or00,
;        andFF, orFF), B = entry count; CUR_PAGE_CR, COND_ADDR
;        and COND_WR_OFF (page-0 write offset of the conditioner)
;        already set.
;   Out: TBL_BAD = defined-bit misreads + conditioner misreads.
RUN_TABLE
	LD	(TBL_BASE),HL
	LD	(RES_BASE),DE
	LD	A,B
	LD	(TBL_COUNT),A
	LD	HL,0
	LD	(TBL_BAD),HL
	LD	(COND_BAD),HL
	XOR	A
	LD	(PASS_RES),A
RT_RES_LOOP
	LD	A,(COND_WR_OFF)
	LD	C,A
	LD	A,(PASS_RES)
	CALL	WRITE_P0
	LD	A,(PASS_RES)
	LD	(COND_EXP),A
	LD	HL,(TBL_BASE)
	LD	(TBL_PTR),HL
	LD	HL,(RES_BASE)
	LD	(RES_PTR),HL
	LD	A,(TBL_COUNT)
	LD	(TBL_LEFT),A
RT_ENT_LOOP
	LD	HL,(TBL_PTR)
	LD	E,(HL)			; register offset
	INC	HL
	LD	C,(HL)			; expected
	INC	HL
	LD	A,(HL)			; mask of defined bits
	LD	(TGT_MASK),A
	AND	C
	LD	(TGT_EXP),A
	LD	A,E
	CALL	REG_ADDR
	LD	(TGT_ADDR),HL
	CALL	ACC_RESET
	LD	A,1
	CALL	RUN_BURSTS
	LD	HL,(RES_PTR)
	LD	A,(PASS_RES)
	OR	A
	JR	Z,RT_SLOT
	INC	HL
	INC	HL
RT_SLOT
	LD	A,(ACC_AND)
	LD	(HL),A
	INC	HL
	LD	A,(ACC_OR)
	LD	(HL),A
	LD	HL,(TBL_BAD)
	LD	DE,(ACC_BAD)
	ADD	HL,DE
	LD	(TBL_BAD),HL
	LD	HL,(TBL_PTR)
	LD	DE,TBL_ENTRY_SIZE
	ADD	HL,DE
	LD	(TBL_PTR),HL
	LD	HL,(RES_PTR)
	LD	DE,4
	ADD	HL,DE
	LD	(RES_PTR),HL
	LD	HL,TBL_LEFT
	DEC	(HL)
	JR	NZ,RT_ENT_LOOP
	LD	A,(PASS_RES)
	CPL
	LD	(PASS_RES),A
	OR	A
	JP	NZ,RT_RES_LOOP
	; a misread conditioner is a misread register like any other
	LD	HL,(TBL_BAD)
	LD	DE,(COND_BAD)
	ADD	HL,DE
	LD	(TBL_BAD),HL
	LD	A,H
	OR	L
	CALL	NZ,SET_FAILED
	RET

; PRINT_TABLE: one token per entry, C tokens per line.
;   In: HL = table, DE = results, B = count, C = tokens/line,
;       A != 0 -> show the written value first ("ww|").
PRINT_TABLE
	LD	(PT_SHOW_EXP),A
	LD	A,C
	LD	(PT_PER_LINE),A
	LD	(PT_COL),A
.ENT
	LD	A,' '
	CALL	PUTCHAR
	PUSH	HL
	INC	HL
	INC	HL
	INC	HL
	CALL	PUT_NAME5
	POP	HL
	LD	A,' '
	CALL	PUTCHAR
	LD	A,(PT_SHOW_EXP)
	OR	A
	JR	Z,.NOEXP
	INC	HL
	LD	A,(HL)
	DEC	HL
	CALL	@UTIL.PRINT_HEX_A
	LD	A,'|'
	CALL	PUTCHAR
.NOEXP
	LD	A,(DE)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,'/'
	CALL	PUTCHAR
	INC	DE
	LD	A,(DE)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,'|'
	CALL	PUTCHAR
	INC	DE
	LD	A,(DE)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,'/'
	CALL	PUTCHAR
	INC	DE
	LD	A,(DE)
	CALL	@UTIL.PRINT_HEX_A
	INC	DE
	PUSH	DE
	LD	DE,TBL_ENTRY_SIZE
	ADD	HL,DE
	POP	DE
	LD	A,(PT_COL)
	DEC	A
	JR	NZ,.SAME_LINE
	CALL	PUT_CRLF
	LD	A,(PT_PER_LINE)
.SAME_LINE
	LD	(PT_COL),A
	DJNZ	.ENT
	; close a partly filled last line
	LD	A,(PT_PER_LINE)
	LD	C,A
	LD	A,(PT_COL)
	CP	C
	RET	Z
	JP	PUT_CRLF


PHASE_G2
	LD	A,CR_PAGE2_STOP
	LD	(CUR_PAGE_CR),A
	LD	A,RTL_PSTART_OFF	; written on page 0, read back on page 2
	LD	(COND_WR_OFF),A
	CALL	REG_ADDR
	LD	(COND_ADDR),HL
	LD	HL,G2_TABLE
	LD	DE,G2_RES
	LD	B,G2_COUNT
	CALL	RUN_TABLE
	LD	C,RTL_PSTART_OFF
	LD	A,RTL_PSTART_INIT
	CALL	WRITE_P0
	PRINT	MSG_G2
	LD	HL,(TBL_BAD)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	LINE_END
	LD	HL,G2_TABLE
	LD	DE,G2_RES
	LD	BC,G2_COUNT * 256 + 2
	LD	A,1
	JP	PRINT_TABLE

PHASE_G3
	LD	A,CR_PAGE0_STOP
	LD	(CUR_PAGE_CR),A
	LD	A,RTL_BNRY_OFF
	LD	(COND_WR_OFF),A
	CALL	REG_ADDR
	LD	(COND_ADDR),HL
	LD	HL,G3_TABLE
	LD	DE,G3_RES
	LD	B,G3_COUNT
	CALL	RUN_TABLE
	LD	C,RTL_BNRY_OFF
	LD	A,RTL_BNRY_INIT
	CALL	WRITE_P0
	PRINT	MSG_G3
	LD	HL,(TBL_BAD)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	LINE_END
	LD	HL,G3_TABLE
	LD	DE,G3_RES
	LD	BC,G3_COUNT * 256 + 4
	XOR	A
	JP	PRINT_TABLE


; ======================================================
; [G4] the same access loop against three chip states:
;   stop  chip stopped -- the control row;
;   deaf  started, RCR=MON: addresses are checked, nothing
;         is stored, so there is no local DMA into the ring;
;   live  started, RCR=AB: broadcasts are buffered meanwhile.
; Per sweep: read PAR0..5 against TEST_MAC, then write
; MAR0..3 (unused while RCR.AM=0) with a pattern that flips
; every sweep and read them back.  A read-back that differs
; is re-read twice: the wanted value now = it was a misread;
; the previous pattern both times = the write was lost;
; anything else = the write was garbled.
; Every page switch goes through SET_PAGE.  Real hardware
; has shown why: a dropped "CR := page 0" sent the BNRY
; write of the ring drain into PAR2.
; ======================================================
PHASE_G4
	PRINT	MSG_G4
	LD	HL,TEST_MAC
	LD	B,6
.MAC
	LD	A,(HL)
	CALL	@UTIL.PRINT_HEX_A
	INC	HL
	DJNZ	.MAC
	PRINTLN	MSG_G4_TAIL
	PRINTLN	MSG_G4_HEAD
	LD	A,RTL_PAR0_OFF
	CALL	REG_ADDR
	LD	(PAR_ADDR),HL
	LD	A,RTL_MAR0_OFF
	CALL	REG_ADDR
	LD	(MAR_ADDR),HL
	LD	HL,CR_PAGE1_STOP * 256 + CR_PAGE0_STOP
	LD	A,RCR_MON
	LD	DE,MSG_G4_STOP
	CALL	G4_ROW
	LD	HL,CR_PAGE1_START * 256 + CR_PAGE0_START
	LD	A,RCR_MON
	LD	DE,MSG_G4_DEAF
	CALL	G4_ROW
	LD	HL,CR_PAGE1_START * 256 + CR_PAGE0_START
	LD	A,RCR_AB
	LD	DE,MSG_G4_LIVE
	; fall through

; ------------------------------------------------------
; G4_ROW: one row of [G4].
;   In: A = RCR value, H = page-1 CR value, L = page-0 CR
;       value (START or STOP flavour), DE = row label.
; Leaves the chip in that state.
; ------------------------------------------------------
G4_ROW
	LD	(G4_LABEL),DE
	LD	(G4_RCR),A
	LD	(ROW_CR_P0),HL		; L -> ROW_CR_P0, H -> ROW_CR_P1
	LD	HL,G4_ROW_STATE
	LD	DE,G4_ROW_STATE + 1
	LD	BC,G4_ROW_LEN - 1
	LD	(HL),0
	LDIR
	CALL	@ISA.ISA_OPEN
	LD	HL,TEST_MAC
	LD	A,0
G4_RCR	EQU $-1
	CALL	@RTL.INIT_NORMAL
	LD	A,(ROW_CR_P0)
	CALL	SET_PAGE
	CALL	@ISA.ISA_CLOSE
	LD	A,RTL_CURR_INIT
	LD	(LAST_CURR),A
	LD	HL,G4_TICKS
	LD	(TICKS_LEFT),HL
G4_TICK
	XOR	A
	LD	(TICK_MISS),A
	LD	(SWEEP_NO),A
	CALL	@ISA.ISA_OPEN
	LD	A,(ROW_CR_P1)
	CALL	SET_PAGE
G4_IT
	LD	HL,(PAR_ADDR)
	LD	DE,TEST_MAC
	LD	B,6
G4_RD
	LD	A,(HL)			; exactly one chip read per sample
	LD	C,A
	LD	A,(DE)
	XOR	C
	CALL	NZ,G4_MISS		; A = wrong bits, C = value, B = 6 - reg
	INC	HL
	INC	DE
	DJNZ	G4_RD

	; All four writes first, the read-backs after: a lost write
	; must not be hidden by its own data still sitting on the bus.
	LD	A,(SWEEP_NO)
	RRCA
	SBC	A,A
	LD	C,A			; 00 on even sweeps, FF on odd ones
	LD	HL,(MAR_ADDR)
	LD	DE,G4_WR_BASE
	LD	B,G4_WR_REGS
G4_WR
	LD	A,(DE)
	XOR	C
	LD	(HL),A			; exactly one chip write per sample
	INC	HL
	INC	DE
	DJNZ	G4_WR
	LD	HL,(MAR_ADDR)
	LD	DE,G4_WR_BASE
	LD	B,G4_WR_REGS
G4_RB
	LD	A,(DE)
	XOR	C
	LD	(RB_WANT),A
	LD	A,(HL)			; one chip read
	CP	0
RB_WANT	EQU $-1
	CALL	NZ,G4_WMISS		; A = value read, HL = register
	INC	HL
	INC	DE
	DJNZ	G4_RB

	LD	A,(SWEEP_NO)
	INC	A
	LD	(SWEEP_NO),A
	CP	G4_ITER
	JP	NZ,G4_IT
	CALL	DRAIN_RING
	LD	(TICK_MOVED),A
	CALL	@ISA.ISA_CLOSE

	; Tie the failures to reception.  A frame that was still
	; arriving when the window closed moves the ring in the
	; NEXT tick, so a bad tick stays pending for one tick.
	LD	A,(TICK_MISS)
	OR	A
	JR	Z,.NOMISS
	LD	HL,G4_BADTICKS
	CALL	BUMP
.NOMISS
	LD	A,(TICK_MOVED)
	OR	A
	JR	Z,.QUIET
	LD	A,(TICK_MISS)
	LD	HL,MISS_PENDING
	ADD	A,(HL)			; 0..2 bad ticks this frame explains
	LD	(HL),0
	LD	HL,(G4_WITHRX)
	ADD	A,L
	LD	L,A
	JR	NC,.NC
	INC	H
.NC
	LD	(G4_WITHRX),HL
	JR	.PACE
.QUIET
	LD	A,(TICK_MISS)
	LD	(MISS_PENDING),A
.PACE
	CALL	@UTIL.DELAY_1MS		; window closed: the 50 Hz IRQ gets its turn
	LD	HL,(TICKS_LEFT)
	DEC	HL
	LD	(TICKS_LEFT),HL
	LD	A,H
	OR	L
	JP	NZ,G4_TICK

	; " stop 0000   00   0000    0000   0000   0000    0000     0000"
	LD	HL,0
G4_LABEL EQU $-2
	PRINT_HL
	LD	HL,(G4_BAD)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_SP3
	LD	A,(G4_ERRBITS)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	MSG_SP3
	LD	HL,(G4_WR_LOST)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_SP4
	LD	HL,(G4_WR_BAD)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_SP3
	LD	HL,(G4_CR_BAD)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_SP3
	LD	HL,(RX_PAGES)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_SP4
	LD	HL,(G4_BADTICKS)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_SP5
	LD	HL,(G4_WITHRX)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	LINE_END

	; Any failed access fails the run.
	LD	HL,(G4_BAD)
	LD	DE,(G4_CR_BAD)
	LD	A,H
	OR	L
	OR	D
	OR	E
	LD	HL,(G4_WR_LOST)
	LD	DE,(G4_WR_BAD)
	OR	H
	OR	L
	OR	D
	OR	E
	RET	Z
	CALL	SET_FAILED

	; "  rd PAR3=EE@01 ...": register, what the read returned,
	; sweep number inside its 32-sweep window.
	; DSS console calls return with A, BC, DE and HL trashed: load
	; the loop counter only after the PRINT.
	LD	A,(G4_NSAMP)
	OR	A
	JR	Z,.NO_RD
	PRINT	MSG_RD
	LD	A,(G4_NSAMP)
	LD	B,A
	LD	HL,G4_SAMP
.SAMP
	PUSH	BC,HL
	PRINT	MSG_PAR
	POP	HL,BC
	LD	A,(HL)
	CALL	PUT_NIBBLE
	LD	A,'='
	CALL	PUTCHAR
	INC	HL
	LD	A,(HL)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,'@'
	CALL	PUTCHAR
	INC	HL
	LD	A,(HL)
	CALL	@UTIL.PRINT_HEX_A
	INC	HL
	DJNZ	.SAMP
	CALL	PUT_CRLF
.NO_RD
	; "  wr MAR1=C3>3C ...": register, wanted > what it holds.
	LD	A,(G4_NWSAMP)
	OR	A
	RET	Z
	PRINT	MSG_WR
	LD	A,(G4_NWSAMP)
	LD	B,A
	LD	HL,G4_WSAMP
.WSAMP
	PUSH	BC,HL
	PRINT	MSG_MAR
	POP	HL,BC
	LD	A,(HL)
	CALL	PUT_NIBBLE
	LD	A,'='
	CALL	PUTCHAR
	INC	HL
	LD	A,(HL)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,'>'
	CALL	PUTCHAR
	INC	HL
	LD	A,(HL)
	CALL	@UTIL.PRINT_HEX_A
	INC	HL
	DJNZ	.WSAMP
	JP	PUT_CRLF

; BUMP: saturating increment of the 16-bit counter at HL.
; Trashes HL.  Plain RAM only.
BUMP
	INC	(HL)
	RET	NZ
	INC	HL
	INC	(HL)
	RET	NZ
	DEC	(HL)			; FFFF stays FFFF
	DEC	HL
	DEC	(HL)
	RET

; G4_MISS: count one misread, remember the bits and keep the
; first G4_SAMPLES verbatim.  In: A = wrong bits, C = the value
; read, B = 6 - register index.  Preserves BC, DE, HL.
; Plain RAM only -- it runs with the ISA window open.
G4_MISS
	PUSH	HL
	PUSH	DE
	LD	HL,G4_ERRBITS
	OR	(HL)
	LD	(HL),A
	LD	A,1
	LD	(TICK_MISS),A
	LD	HL,G4_BAD
	CALL	BUMP
	LD	A,(G4_NSAMP)
	CP	G4_SAMPLES
	JR	NC,.FULL
	LD	E,A
	INC	A
	LD	(G4_NSAMP),A
	LD	A,E
	ADD	A,A
	ADD	A,E			; 3 bytes per sample
	LD	E,A
	LD	D,0
	LD	HL,G4_SAMP
	ADD	HL,DE
	LD	A,6
	SUB	B
	LD	(HL),A
	INC	HL
	LD	(HL),C
	INC	HL
	LD	A,(SWEEP_NO)
	LD	(HL),A
.FULL
	POP	DE
	POP	HL
	RET

; G4_WMISS: a MAR read-back differed.  In: A = the value read,
; (RB_WANT) = the value written, HL = register.  Two more reads
; decide what happened (see the [G4] header).  Preserves BC, DE,
; HL.  Plain RAM only.
G4_WMISS
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	C,A			; first read
	LD	E,(HL)			; second read
	LD	B,(HL)			; third read
	LD	A,1
	LD	(TICK_MISS),A
	LD	A,(RB_WANT)
	LD	D,A
	CP	E
	JR	Z,.MISREAD
	CP	B
	JR	Z,.MISREAD
	CPL				; the previous sweep's pattern
	CP	E
	JR	NZ,.GARBLED
	CP	B
	JR	NZ,.GARBLED
	LD	HL,G4_WR_LOST
	JR	.COUNT
.GARBLED
	LD	HL,G4_WR_BAD
.COUNT
	CALL	BUMP
	LD	A,(G4_NWSAMP)
	CP	G4_WSAMPLES
	JR	NC,.DONE
	LD	C,A
	INC	A
	LD	(G4_NWSAMP),A
	LD	A,C
	ADD	A,A
	ADD	A,C			; 3 bytes per sample
	LD	C,A
	LD	B,0
	LD	HL,G4_WSAMP
	ADD	HL,BC
	EX	(SP),HL			; HL = register, sample pointer on the stack
	LD	A,(MAR_ADDR)
	LD	C,A
	LD	A,L
	SUB	C			; register index 0..3
	EX	(SP),HL
	LD	(HL),A
	INC	HL
	LD	(HL),D
	INC	HL
	LD	(HL),E
	JR	.DONE
.MISREAD
	LD	A,C
	XOR	D			; the bits the first read got wrong
	LD	HL,G4_ERRBITS
	OR	(HL)
	LD	(HL),A
	LD	HL,G4_BAD
	CALL	BUMP
.DONE
	POP	HL
	POP	DE
	POP	BC
	RET

; ------------------------------------------------------
; SET_PAGE: CR := A, verified.  On this bus a started chip
; now and then drops a write, and a dropped page switch
; sends whatever is written next into another page.  CR is
; read back; two wrong read-backs in a row count as a lost
; write (cr-bad) and the write is repeated, at most 4 times.
; A single wrong read-back is an ordinary misread (rd-bad).
; ISA open.  Trashes A, BC, IX.  Plain RAM only.
; ------------------------------------------------------
SET_PAGE
	LD	IX,(RTL_BASE_PTR)
	LD	C,A
	LD	B,4
.TRY
	LD	(IX+RTL_CR_OFF),C
	LD	A,(IX+RTL_CR_OFF)
	XOR	C
	AND	CR_VERIFY_MASK
	RET	Z
	LD	A,1
	LD	(TICK_MISS),A
	LD	A,(IX+RTL_CR_OFF)
	XOR	C
	AND	CR_VERIFY_MASK
	JR	Z,.MISREAD
	PUSH	HL
	LD	HL,G4_CR_BAD
	CALL	BUMP
	POP	HL
	DJNZ	.TRY
	RET
.MISREAD
	PUSH	HL
	LD	HL,G4_BAD
	CALL	BUMP
	POP	HL
	RET

; ------------------------------------------------------
; DRAIN_RING: throw away whatever the receiver stored, so
; the ring cannot overflow while we are not reading frames:
; BNRY := CURR - 1.  CURR is read twice and used only when
; both reads agree, and both page switches are verified.
; ISA open; uses the current row's CR values.
;   Out: A = pages the ring moved since the last call
;        (0 also when CURR could not be read).
; Trashes BC, IX.
; ------------------------------------------------------
DRAIN_RING
	LD	A,(ROW_CR_P1)
	CALL	SET_PAGE
	LD	A,(IX+RTL_CURR_OFF)
	LD	(DRAIN_CURR),A
	LD	A,(IX+RTL_CURR_OFF)
	LD	(DRAIN_CURR2),A
	LD	A,(ROW_CR_P0)
	CALL	SET_PAGE
	LD	A,0
DRAIN_CURR2 EQU $-1
	LD	C,0
DRAIN_CURR EQU $-1
	CP	C
	JR	NZ,.SKIP
	CP	RTL_PSTART_INIT
	JR	C,.SKIP			; implausible: leave the ring alone
	CP	RTL_PSTOP_INIT
	JR	NC,.SKIP
	LD	A,(LAST_CURR)
	LD	B,A
	LD	A,C
	LD	(LAST_CURR),A
	SUB	B
	JR	NC,.NOWRAP
	ADD	A,RTL_PSTOP_INIT - RTL_PSTART_INIT
.NOWRAP
	LD	B,A			; pages moved
	PUSH	HL
	LD	HL,(RX_PAGES)
	ADD	A,L
	LD	L,A
	JR	NC,.NC
	INC	H
.NC
	LD	(RX_PAGES),HL
	POP	HL
	LD	A,C
	DEC	A
	CP	RTL_PSTART_INIT
	JR	NC,.BOK
	LD	A,RTL_PSTOP_INIT - 1
.BOK
	LD	(IX+RTL_BNRY_OFF),A
	; Acknowledge what we just discarded, OVW excluded, so the ISR
	; values [G5] reports are about the transmit and nothing else.
	LD	(IX+RTL_ISR_OFF),ISR_PRX | ISR_RXE
	LD	A,B
	RET
.SKIP
	XOR	A
	RET


; ======================================================
; [G5] transmit A/B/C (only with -t).
; ======================================================
PHASE_G5
	PRINTLN	MSG_G5
	CALL	BUILD_FRAME
	LD	A,'A'
	LD	(TX_MODE),A
G5_MODE_LOOP
	LD	A,1
	LD	(TX_SEQ),A
G5_FRAME_LOOP
	LD	A,(TX_MODE)
	LD	(TX_BUF + 14 + MARK_OFF),A
	LD	A,(TX_SEQ)
	LD	(TX_BUF + 14 + MARK_OFF + 1),A
	CALL	@ISA.ISA_OPEN
	CALL	DRAIN_RING
	LD	A,(TX_MODE)
	CP	'C'
	JR	Z,G5_DRV
	CALL	TX_MINIMAL
	JR	C,G5_SENT
	LD	A,(TX_MODE)
	CP	'A'
	JR	NZ,G5_QUIET
	CALL	WAIT_POLL
	JR	G5_SENT
G5_QUIET
	CALL	WAIT_QUIET
	JR	G5_SENT
G5_DRV
	LD	HL,TX_BUF
	LD	BC,FRAME_LEN
	CALL	@RTL.SEND_FRAME
	JR	C,G5_SENT
	LD	HL,TXC_DONE
	INC	(HL)
G5_SENT
	CALL	@ISA.ISA_CLOSE
	LD	HL,TX_GAP_MS
	CALL	@UTIL.DELAY_MS
	LD	HL,TX_SEQ
	INC	(HL)
	LD	A,(HL)
	CP	TX_FRAMES + 1
	JR	C,G5_FRAME_LOOP
	LD	HL,TX_MODE
	INC	(HL)
	LD	A,(HL)
	CP	'C' + 1
	JR	C,G5_MODE_LOOP

	PRINT	MSG_G5_A
	LD	A,(TXA_DONE)
	CALL	PUT_DEC2
	PRINT	MSG_ISR_EQ
	LD	HL,TXA_ISR_AND
	CALL	PUT_PAIR
	PRINT	MSG_TSR_EQ
	LD	HL,TXA_TSR_AND
	CALL	PUT_PAIR
	PRINT	LINE_END
	PRINT	MSG_G5_B
	LD	A,(TXB_DONE)
	CALL	PUT_DEC2
	PRINT	MSG_ISR_EQ
	LD	HL,TXB_ISR_AND
	CALL	PUT_PAIR
	PRINT	MSG_TSR_EQ
	LD	HL,TXB_TSR_AND
	CALL	PUT_PAIR
	PRINT	LINE_END
	PRINT	MSG_G5_C
	LD	A,(TXC_DONE)
	CALL	PUT_DEC2
	PRINT	LINE_END
	; the chip must at least CLAIM every frame
	LD	A,(TXA_DONE)
	CP	TX_FRAMES
	CALL	NZ,SET_FAILED
	LD	A,(TXB_DONE)
	CP	TX_FRAMES
	CALL	NZ,SET_FAILED
	LD	A,(TXC_DONE)
	CP	TX_FRAMES
	CALL	NZ,SET_FAILED
	RET

; TX_MINIMAL: the textbook NE2000 transmit and nothing else --
; no read-back, no page switching between the load and TXP.
; ISA open.  Out: CF=1 remote DMA failed.  IX = base.
TX_MINIMAL
	LD	HL,TX_BUF
	LD	DE,RTL_TPSR_INIT * 256
	LD	BC,FRAME_LEN
	CALL	@RTL.DMA_WRITE
	RET	C
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_TBCR0_OFF),FRAME_LEN
	LD	(IX+RTL_TBCR1_OFF),0
	LD	(IX+RTL_ISR_OFF),ISR_PTX | ISR_TXE
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START | CR_TXP
	OR	A
	RET

; WAIT_POLL: mode A.  Read ISR back-to-back for the whole
; transmission, exactly as the driver's WAIT_PTX does, and
; keep the AND/OR of every value seen.
WAIT_POLL
	LD	BC,PTX_POLLS
	LD	DE,0xFF00		; D = AND, E = OR
.P
	LD	A,(IX+RTL_ISR_OFF)
	LD	H,A
	AND	D
	LD	D,A
	LD	A,H
	OR	E
	LD	E,A
	LD	A,H
	AND	ISR_PTX | ISR_TXE
	JR	NZ,.EV
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.P
	XOR	A			; timed out: nothing claimed
.EV
	LD	HL,TXA_ISR_AND
	LD	C,A
	JR	TX_FOLD

; WAIT_QUIET: mode B.  Not one bus cycle reaches the chip
; while it transmits: window closed, 2 ms, then one ISR read.
WAIT_QUIET
	CALL	@ISA.ISA_CLOSE
	CALL	@UTIL.DELAY_2MS
	CALL	@ISA.ISA_OPEN
	LD	IX,(RTL_BASE_PTR)
	LD	A,(IX+RTL_ISR_OFF)
	LD	D,A
	LD	E,A
	AND	ISR_PTX | ISR_TXE
	LD	C,A
	LD	HL,TXB_ISR_AND
	; fall through

; TX_FOLD: HL -> {isr_and, isr_or, tsr_and, tsr_or, done},
; D/E = ISR and/or of this frame, C = its PTX|TXE bits.
TX_FOLD
	LD	A,(HL)
	AND	D
	LD	(HL),A
	INC	HL
	LD	A,(HL)
	OR	E
	LD	(HL),A
	INC	HL
	LD	B,(IX+RTL_TSR_OFF)
	LD	A,(HL)
	AND	B
	LD	(HL),A
	INC	HL
	LD	A,(HL)
	OR	B
	LD	(HL),A
	INC	HL
	LD	A,C
	AND	ISR_PTX
	JR	Z,.NOT_DONE
	INC	(HL)
.NOT_DONE
	LD	(IX+RTL_ISR_OFF),ISR_PTX | ISR_TXE
	RET

; BUILD_FRAME: broadcast, EtherType 88B5, tagged payload.
BUILD_FRAME
	LD	HL,TX_BUF
	LD	B,6
.DST
	LD	(HL),0xFF
	INC	HL
	DJNZ	.DST
	EX	DE,HL
	LD	HL,TEST_MAC
	LD	BC,6
	LDIR
	LD	A,HIGH ETH_TYPE
	LD	(DE),A
	INC	DE
	LD	A,LOW ETH_TYPE
	LD	(DE),A
	INC	DE
	LD	HL,PAYLOAD
	LD	BC,PAYLOAD_LEN
	LDIR
	LD	B,FRAME_LEN - 14 - PAYLOAD_LEN
	XOR	A
.PAD
	LD	(DE),A
	INC	DE
	DJNZ	.PAD
	RET


; ------------------------------------------------------
; Console helpers.  All preserve every register: they are
; called from inside table walks.  ISA must be closed.
; ------------------------------------------------------
PUTCHAR
	PUSH	AF,BC,DE,HL
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL,DE,BC,AF
	RET

PUT_CRLF
	PUSH	AF,BC,DE,HL
	LD	HL,LINE_END
	LD	C,DSS_PCHARS
	RST	DSS
	POP	HL,DE,BC,AF
	RET

PUT_NIBBLE
	PUSH	AF
	AND	0x0F
	ADD	A,0x90
	DAA
	ADC	A,0x40
	DAA
	CALL	PUTCHAR
	POP	AF
	RET

; PUT_NAME5: five characters at HL.  HL += 5.
PUT_NAME5
	PUSH	AF,BC
	LD	B,5
.LP
	LD	A,(HL)
	CALL	PUTCHAR
	INC	HL
	DJNZ	.LP
	POP	BC,AF
	RET

; PUT_PAIR: "aa/oo" from (HL), (HL+1).
PUT_PAIR
	LD	A,(HL)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,'/'
	CALL	PUTCHAR
	INC	HL
	LD	A,(HL)
	JP	@UTIL.PRINT_HEX_A

; PUT_DEC2: A (0..99) as two decimal digits.
PUT_DEC2
	PUSH	BC
	LD	B,'0'
.T
	CP	10
	JR	C,.U
	SUB	10
	INC	B
	JR	.T
.U
	LD	C,A
	LD	A,B
	CALL	PUTCHAR
	LD	A,C
	ADD	A,'0'
	CALL	PUTCHAR
	POP	BC
	RET


; ------- in-EXE data -------
TEST_MAC	DB 0x02, 0x80, 0x19, 0x11, 0x22, 0x33
; [G4] write patterns, complemented on odd sweeps.  Neighbours differ,
; so a read-back that returns the register read just before it shows.
G4_WR_BASE	DB 0x3C, 0xC3, 0x69, 0x96
	ASSERT $ - G4_WR_BASE == G4_WR_REGS

PAYLOAD		DB "NICREG TX "
MARK_OFF	EQU $ - PAYLOAD		; mode letter, then the sequence byte
		DB "?", 0
PAYLOAD_LEN	EQU $ - PAYLOAD

; One byte per [G1] register; the second pass uses the complement,
; so every bit of every register is checked as a 0 and as a 1.
G1_PATTERN
	DB 0x55, 0xAA, 0x33, 0xCC, 0x0F, 0xF0, 0x5A
	DB 0xA5, 0x3C, 0xC3, 0x69, 0x96, 0x81, 0x7E
	ASSERT $ - G1_PATTERN == G1_REGS

G1_NAMES
	DB "PAR0 PAR1 PAR2 PAR3 PAR4 PAR5 CURR "
	DB "MAR0 MAR1 MAR2 MAR3 MAR4 MAR5 MAR6 "
	ASSERT $ - G1_NAMES == G1_REGS * 5

; offset, written value, mask of defined bits, name
G2_TABLE
	DB RTL_PSTOP_OFF, RTL_PSTOP_INIT, 0xFF, "PSTOP"
	DB RTL_TPSR_OFF,  RTL_TPSR_INIT,  0xFF, "TPSR "
	DB RTL_RCR_OFF,   G2_RCR_VAL,     0x3F, "RCR  "
	DB RTL_TCR_OFF,   G2_TCR_VAL,     0x1F, "TCR  "
	DB RTL_DCR_OFF,   DCR_INIT,       0x7F, "DCR  "
	DB RTL_IMR_OFF,   0x00,           0x7F, "IMR  "
G2_COUNT	EQU ($ - G2_TABLE) / TBL_ENTRY_SIZE

; Page-0 read side.  Only CR has a value we can insist on; mask 0
; means "report, never count".  BNRY (the conditioner), the data
; port and the reset port are deliberately absent.
G3_TABLE
	DB 0x00, CR_PAGE0_STOP, 0xFF, "CR   "
	DB 0x01, 0, 0, "CLDA0"
	DB 0x02, 0, 0, "CLDA1"
	DB 0x04, 0, 0, "TSR  "
	DB 0x05, 0, 0, "NCR  "
	DB 0x06, 0, 0, "FIFO "
	DB 0x07, 0, 0, "ISR  "
	DB 0x08, 0, 0, "CRDA0"
	DB 0x09, 0, 0, "CRDA1"
	DB 0x0A, 0, 0, "ID0  "
	DB 0x0B, 0, 0, "ID1  "
	DB 0x0C, 0, 0, "RSR  "
	DB 0x0D, 0, 0, "CNT0 "
	DB 0x0E, 0, 0, "CNT1 "
	DB 0x0F, 0, 0, "CNT2 "
G3_COUNT	EQU ($ - G3_TABLE) / TBL_ENTRY_SIZE


; ------- messages -------
MSG_BANNER	DB "RTL8019AS NICREG v",PACKAGE_VERSION,0
MSG_G0		DB "[G0] Slot/Addr: ",0
MSG_G0_SEP	DB "/#",0
MSG_CHIP_REALTEK DB " chip=Realtek",0
MSG_CHIP_CLONE	DB " chip=clone",0
MSG_G1		DB "[G1] RW STORAGE stopped, 14 regs x 2048 reads",0
MSG_G1_00	DB " bad after-00=",0
MSG_G1_FF	DB " after-FF=",0
MSG_COND	DB " cond=",0
MSG_BAD_EQ	DB " bad=",0
MSG_BITS_EQ	DB " bits=",0
MSG_G2		DB "[G2] PAGE2 CONFIG  written|and/or after 00|after FF  bad=",0
MSG_G3		DB "[G3] PAGE0 STATUS  and/or after 00|after FF  CR bad=",0
MSG_G4		DB "[G4] PAR=",0
MSG_G4_TAIL	DB "  per row: 288000 reads, 192000 writes",0
MSG_G4_HEAD	DB " row  rd-bad bits wr-lost wr-bad cr-bad rxpages badticks withrx",0
MSG_G4_STOP	DB " stop ",0
MSG_G4_DEAF	DB " deaf ",0
MSG_G4_LIVE	DB " live ",0
MSG_SP3		DB "   ",0
MSG_SP4		DB "    ",0
MSG_SP5		DB "     ",0
MSG_RD		DB "  rd",0
MSG_WR		DB "  wr",0
MSG_PAR		DB " PAR",0
MSG_MAR		DB " MAR",0
MSG_G5		DB "[G5] TX 3x20, type 88B5 -- count arrivals on the peer",0
MSG_G5_A	DB " A poll  ptx=",0
MSG_G5_B	DB " B quiet ptx=",0
MSG_G5_C	DB " C drv   ptx=",0
MSG_ISR_EQ	DB " isr=",0
MSG_TSR_EQ	DB " tsr=",0
MSG_RESULT_OK	DB "RESULT OK",0
MSG_RESULT_FAIL	DB "RESULT FAIL",0
MSG_E_RESET	DB "[E40] RESET timeout",0
MSG_HELP
	DB "Usage:",13,10
	DB "  NICREG        register read-stability test (no transmit)",13,10
	DB "  NICREG -t     also send 3x20 test frames, type 88B5",13,10
	DB "  NICREG /?",13,10,13,10
	DB "Each value is shown as and/or over 256 reads: equal = stable.",13,10
	DB "A bit that is 0 after 00 and 1 after FF is not driven by the",13,10
	DB "chip at all; a bit that differs inside one pair is unstable.",13,10,0
LINE_END	DB 13,10,0

	ENDMODULE


	; cmdline_lib transitively DEFINEs the USE_UTIL_* helpers it
	; needs, so it must come before util.asm.
	INCLUDE "cmdline_lib.asm"
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"


NICREG_IMAGE_END
	ASSERT NICREG_IMAGE_END <= LIBBSS_BASE

	MODULE MAIN

; ------- runtime BSS (APP_BSS_BASE, not in the .EXE) -------
BSS_START	EQU APP_BSS_BASE
OPT_TX		EQU BSS_START + 0	; 1
FAILED		EQU BSS_START + 1	; 1
ACC_AND		EQU BSS_START + 2	; 1
ACC_OR		EQU BSS_START + 3	; 1
ACC_BAD		EQU BSS_START + 4	; 2
CUR_PAGE_CR	EQU BSS_START + 6	; 1
COND_WR_OFF	EQU BSS_START + 7	; 1
COND_ADDR	EQU BSS_START + 8	; 2
TGT_ADDR	EQU BSS_START + 10	; 2
TGT_EXP		EQU BSS_START + 12	; 1
PASS_PAT	EQU BSS_START + 13	; 1
PASS_RES	EQU BSS_START + 14	; 1
REG_INDEX	EQU BSS_START + 15	; 1
COND_BAD	EQU BSS_START + 16	; 2
G1_TOT00	EQU BSS_START + 18	; 2
G1_TOTFF	EQU BSS_START + 20	; 2
LINES_LEFT	EQU BSS_START + 22	; 1
TBL_COUNT	EQU BSS_START + 23	; 1
TBL_LEFT	EQU BSS_START + 24	; 1
PT_SHOW_EXP	EQU BSS_START + 25	; 1
PT_PER_LINE	EQU BSS_START + 26	; 1
PT_COL		EQU BSS_START + 27	; 1
TBL_BASE	EQU BSS_START + 28	; 2
RES_BASE	EQU BSS_START + 30	; 2
TBL_PTR		EQU BSS_START + 32	; 2
RES_PTR		EQU BSS_START + 34	; 2
TBL_BAD		EQU BSS_START + 36	; 2
TICK_MISS	EQU BSS_START + 38	; 1
TICK_MOVED	EQU BSS_START + 39	; 1
SWEEP_NO	EQU BSS_START + 40	; 1
LAST_CURR	EQU BSS_START + 41	; 1
; G4_ROW stores both with one LD (nn),HL -- keep them adjacent.
ROW_CR_P0	EQU BSS_START + 42	; 1
ROW_CR_P1	EQU BSS_START + 43	; 1
MAR_ADDR	EQU BSS_START + 61	; 2
PAR_ADDR	EQU BSS_START + 44	; 2
TICKS_LEFT	EQU BSS_START + 46	; 2
TX_MODE		EQU BSS_START + 48	; 1
TX_SEQ		EQU BSS_START + 49	; 1
; TX_FOLD walks these five in order -- keep each group contiguous.
TXA_ISR_AND	EQU BSS_START + 50	; 1
TXA_ISR_OR	EQU BSS_START + 51	; 1
TXA_TSR_AND	EQU BSS_START + 52	; 1
TXA_TSR_OR	EQU BSS_START + 53	; 1
TXA_DONE	EQU BSS_START + 54	; 1
TXB_ISR_AND	EQU BSS_START + 55	; 1
TXB_ISR_OR	EQU BSS_START + 56	; 1
TXB_TSR_AND	EQU BSS_START + 57	; 1
TXB_TSR_OR	EQU BSS_START + 58	; 1
TXB_DONE	EQU BSS_START + 59	; 1
TXC_DONE	EQU BSS_START + 60	; 1
G1_BAD		EQU BSS_START + 64	; G1_REGS words
G1_ERR		EQU BSS_START + 92	; G1_REGS bytes
G2_RES		EQU BSS_START + 106	; G2_COUNT * 4
G3_RES		EQU BSS_START + 130	; G3_COUNT * 4
TX_BUF		EQU BSS_START + 190	; FRAME_LEN
; G4_ROW clears these in one go at the start of each row.
G4_ROW_STATE	EQU BSS_START + 250
G4_BAD		EQU G4_ROW_STATE + 0	; 2
G4_ERRBITS	EQU G4_ROW_STATE + 2	; 1
RX_PAGES	EQU G4_ROW_STATE + 3	; 2
G4_BADTICKS	EQU G4_ROW_STATE + 5	; 2
G4_WITHRX	EQU G4_ROW_STATE + 7	; 2
G4_NSAMP	EQU G4_ROW_STATE + 9	; 1
MISS_PENDING	EQU G4_ROW_STATE + 10	; 1
G4_SAMP		EQU G4_ROW_STATE + 11	; G4_SAMPLES * 3
G4_WR_LOST	EQU G4_ROW_STATE + 29	; 2
G4_WR_BAD	EQU G4_ROW_STATE + 31	; 2
G4_CR_BAD	EQU G4_ROW_STATE + 33	; 2
G4_NWSAMP	EQU G4_ROW_STATE + 35	; 1
G4_WSAMP	EQU G4_ROW_STATE + 36	; G4_WSAMPLES * 3
G4_ROW_LEN	EQU 48
BSS_CLEAR_LEN	EQU 300
	ASSERT G1_BAD + G1_REGS * 2 <= G1_ERR
	ASSERT G1_ERR + G1_REGS <= G2_RES
	ASSERT G2_RES + G2_COUNT * 4 <= G3_RES
	ASSERT G3_RES + G3_COUNT * 4 <= TX_BUF
	ASSERT TX_BUF + FRAME_LEN <= G4_ROW_STATE
	ASSERT G4_SAMP + G4_SAMPLES * 3 <= G4_WR_LOST
	ASSERT G4_WSAMP + G4_WSAMPLES * 3 <= G4_ROW_STATE + G4_ROW_LEN
	ASSERT ROW_CR_P1 == ROW_CR_P0 + 1
	ASSERT G4_ROW_STATE + G4_ROW_LEN <= BSS_START + BSS_CLEAR_LEN
	ASSERT BSS_START + BSS_CLEAR_LEN < RT_STACK_TOP - 0x200

	ENDMODULE

	END MAIN.START
