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
;        LAN.  Every mismatch is re-examined before it is given
;        a name: misread, lost write, wrong content, or -- when
;        the re-examination itself fails -- unsure.
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
	CALL	PHASE_G6

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
	; Every read of the pass wrong, and all of them alike: the register
	; holds that value.  It never took the pattern (or a bit is stuck),
	; which is a failed WRITE -- keep it out of the misread totals.
	LD	HL,(ACC_BAD)
	LD	DE,G1_BURSTS * 256
	OR	A
	SBC	HL,DE
	JR	NZ,.MISREADS
	LD	A,(ACC_AND)
	LD	B,A
	LD	A,(ACC_OR)
	CP	B
	JR	NZ,.MISREADS
	LD	HL,G1_LOAD_BAD
	INC	(HL)
	RET
.MISREADS
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
	PRINT	MSG_LOAD
	LD	A,(G1_LOAD_BAD)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	LINE_END
	; any misread at all fails the run, and so does a failed load
	LD	HL,(G1_TOT00)
	LD	DE,(G1_TOTFF)
	LD	A,H
	OR	L
	OR	D
	OR	E
	LD	HL,(COND_BAD)
	OR	H
	OR	L
	LD	HL,G1_LOAD_BAD
	OR	(HL)
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
; every sweep and read them back.
;
; A mismatch proves only that ONE access went wrong, not
; which one.  G4_RECHECK therefore reads the register twice
; more, each time right after a conditioner whose value is
; known, and only then gives the event a name:
;   rd-bad   the wanted value came back: the first read lied;
;   wr-lost  MAR holds the previous sweep's pattern, and the
;            conditioner proves that reads work right now;
;   wr-bad   the register holds something else, reads proven
;            the same way.  A PAR byte found like this is
;            written back, so one event counts once;
;   unsure   the re-examination itself failed.  Nothing is
;            concluded and nothing is written.
; Every page switch goes through SET_PAGE and the loop
; never touches a register on a page it could not confirm.
; Real hardware has shown why: a dropped "CR := page 0"
; sent the BNRY write of the ring drain into PAR2.
; ======================================================
RC_MISREAD	EQU 0
RC_HELD		EQU 1
RC_UNSURE	EQU 2

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
	CALL	G4_SETUP
	CALL	@ISA.ISA_CLOSE
	JP	C,G4_ABORT
	LD	HL,G4_TICKS
	LD	(TICKS_LEFT),HL
G4_TICK
	XOR	A
	LD	(TICK_MISS),A
	LD	(TICK_MOVED),A
	LD	(SWEEP_NO),A
	CALL	@ISA.ISA_OPEN
	LD	A,(ROW_CR_P1)
	CALL	SET_PAGE
	JP	C,G4_PAGE_LOST
G4_IT
	LD	HL,(PAR_ADDR)
	LD	DE,TEST_MAC
	LD	B,6
G4_RD
	LD	A,(HL)			; exactly one chip read per sample
	LD	C,A
	LD	A,(DE)
	CP	C
	CALL	NZ,G4_MISS		; C = value, HL = register, DE -> wanted
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
	JR	C,G4_PAGE_LOST
	LD	(TICK_MOVED),A
	CALL	@ISA.ISA_CLOSE
	JR	G4_TICK_END

	; A page switch that four attempts could not confirm.  Whatever
	; page the chip is on, this window touches no register any more:
	; the row's state is set up from scratch instead.
G4_PAGE_LOST
	LD	HL,G4_PG_LOST
	CALL	BUMP
	CALL	G4_SETUP
	CALL	@ISA.ISA_CLOSE		; preserves AF
	JR	C,G4_ABORT

	; Tie the failures to reception.  A frame that was still
	; arriving when the window closed moves the ring in the
	; NEXT tick, so a bad tick stays pending for one tick.
G4_TICK_END
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
	JR	G4_PRINT

G4_ABORT
	LD	A,1
	LD	(G4_ABORTED),A

	; " stop 0000   00   0000    0000   0000   0000   0000    0000     0000"
G4_PRINT
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
	LD	HL,(G4_UNSURE)
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
	LD	HL,G4_FAIL_FIRST
	LD	B,G4_FAIL_LEN
	XOR	A
.ANY
	OR	(HL)
	INC	HL
	DJNZ	.ANY
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
	; "  wr MAR1=D2>2D PAR2=19>4B ...": register, wanted > what it holds.
	LD	A,(G4_NWSAMP)
	OR	A
	JR	Z,.NO_WR
	PRINT	MSG_WR
	LD	A,(G4_NWSAMP)
	LD	B,A
	LD	HL,G4_WSAMP
.WSAMP
	PUSH	BC,HL
	LD	A,(HL)			; page-1 offset: PAR = 1..6, MAR = 8..B
	LD	HL,MSG_PAR
	CP	RTL_MAR0_OFF
	JR	C,.WNAME
	LD	HL,MSG_MAR
.WNAME
	PRINT_HL
	POP	HL,BC
	LD	A,(HL)
	CP	RTL_MAR0_OFF
	JR	NC,.WINDEX
	DEC	A			; PAR0 is offset 1
.WINDEX
	AND	0x07			; MAR0 is offset 8
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
	CALL	PUT_CRLF
.NO_WR
	CALL	PRINT_PG_LOST
	LD	A,(G4_ABORTED)
	OR	A
	RET	Z
	PRINTLN	MSG_G4_ABORTED
	RET

; ------------------------------------------------------
; PRINT_PG_LOST: "  page lost=0001 setup retries=0002",
; and nothing at all when both are zero.  Shared by the
; phases that drive rows through SET_PAGE and G4_SETUP.
; ------------------------------------------------------
PRINT_PG_LOST
	LD	HL,(G4_PG_LOST)
	LD	DE,(G4_SETUP_RETRY)
	LD	A,H
	OR	L
	OR	D
	OR	E
	RET	Z
	PRINT	MSG_PG_LOST
	LD	HL,(G4_PG_LOST)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_SETUP_RETRY
	LD	HL,(G4_SETUP_RETRY)
	CALL	@UTIL.PRINT_HEX_HL
	JP	PUT_CRLF

; ------------------------------------------------------
; G4_SETUP: bring the chip into this row's state and PROVE
; it: the page-1 switch is confirmed, PAR0..5 are read back
; against TEST_MAC, the page-0 switch is confirmed.  The
; rows count every later PAR mismatch, so a station address
; that never went in would otherwise be counted 48000 times
; as a misread.  Any doubt repeats the whole setup, at most
; 4 times.
;   Out: CF = the state could not be established.
; ISA open.  Trashes A, BC, DE, HL, IX.  Plain RAM only.
; Global labels: G4_RCR would capture the local-label scope.
; ------------------------------------------------------
G4_SETUP
	LD	B,4
G4_SETUP_TRY
	PUSH	BC
	LD	HL,TEST_MAC
	LD	A,0
G4_RCR	EQU $-1
	CALL	@RTL.INIT_NORMAL
	LD	A,RTL_CURR_INIT
	LD	(LAST_CURR),A
	LD	A,(ROW_CR_P1)
	CALL	SET_PAGE
	JR	C,G4_SETUP_AGAIN
	LD	HL,(PAR_ADDR)
	LD	DE,TEST_MAC
	LD	B,6
G4_SETUP_CHK
	LD	A,(DE)
	CP	(HL)
	JR	NZ,G4_SETUP_AGAIN
	INC	HL
	INC	DE
	DJNZ	G4_SETUP_CHK
	LD	A,(ROW_CR_P0)
	CALL	SET_PAGE
	JR	C,G4_SETUP_AGAIN
	POP	BC
	RET				; NC
G4_SETUP_AGAIN
	LD	HL,G4_SETUP_RETRY
	CALL	BUMP
	LD	A,1
	LD	(TICK_MISS),A
	POP	BC
	DJNZ	G4_SETUP_TRY
	SCF
	RET

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

; ------------------------------------------------------
; G4_RECHECK: a read of (HL) did not return D.  Find out
; what can honestly be said about it.  The register is read
; twice more, each time right after a conditioner: PAR0, or
; PAR1 when PAR0 is the suspect.  The conditioner's value is
; known and differs from everything else this phase reads,
; so it does two jobs: it proves that the read path works at
; this very moment, and it replaces what is left on the bus,
; so that a cycle the chip does not answer cannot return
; something that looks like register content.
;   In:  HL = register, D = wanted value.
;   Out: A = RC_MISREAD  the wanted value came back;
;            RC_HELD     both conditioner reads were right and
;                        both re-reads returned E, which is
;                        neither D nor the conditioner's value;
;            RC_UNSURE   anything else.
; Preserves D, HL.  Trashes BC, E, IX.  Plain RAM only.
; ------------------------------------------------------
G4_RECHECK
	PUSH	HL
	LD	IX,(PAR_ADDR)
	LD	A,(TEST_MAC)
	LD	(.COND_VAL),A
	LD	BC,(PAR_ADDR)
	OR	A
	SBC	HL,BC
	POP	HL
	JR	NZ,.GO
	INC	IX
	LD	A,(TEST_MAC + 1)
	LD	(.COND_VAL),A
.GO
	PUSH	HL
	LD	B,(IX+0)		; conditioner
	LD	E,(HL)			; second read of the suspect
	LD	C,(IX+0)		; conditioner
	LD	H,(HL)			; third read
	LD	A,D
	CP	E
	JR	Z,.MISREAD
	CP	H
	JR	Z,.MISREAD
	LD	A,0
.COND_VAL EQU $-1
	CP	B
	JR	NZ,.UNSURE
	CP	C
	JR	NZ,.UNSURE
	CP	E			; the suspect did not answer at all
	JR	Z,.UNSURE
	LD	A,E
	CP	H
	JR	NZ,.UNSURE
	LD	A,RC_HELD
	POP	HL
	RET
.MISREAD
	XOR	A			; RC_MISREAD
	POP	HL
	RET
.UNSURE
	LD	A,RC_UNSURE
	POP	HL
	RET

; ------------------------------------------------------
; G4_MISS: a PAR read differed.  In: C = the value read,
; HL = register, DE -> wanted byte, B = 6 - register index.
; The first G4_SAMPLES are kept verbatim whatever the
; verdict.  Content found wrong is written back: the damage
; is counted once, not on every sweep that follows.
; Preserves BC, DE, HL.  Plain RAM only -- the window is open.
; ------------------------------------------------------
G4_MISS
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	A,1
	LD	(TICK_MISS),A
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
	POP	HL
	POP	DE
	PUSH	DE
	PUSH	HL
	LD	A,(DE)
	LD	D,A
	PUSH	BC			; C = the first read
	CALL	G4_RECHECK
	POP	BC
	OR	A
	JR	Z,G4_VERDICT_MISREAD
	DEC	A
	JR	NZ,G4_VERDICT_UNSURE
	LD	(HL),D			; repair
	LD	BC,G4_WR_BAD
	JR	G4_VERDICT_HELD

; ------------------------------------------------------
; G4_WMISS: a MAR read-back differed.  In: A = the value
; read, (RB_WANT) = the value written, HL = register.
; Preserves BC, DE, HL.  Plain RAM only.
; The three G4_VERDICT_* tails are shared with G4_MISS; they
; expect BC, DE, HL of the caller on the stack, HL = register,
; C = first read, D = wanted, E = held.
; ------------------------------------------------------
G4_WMISS
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	C,A
	LD	A,1
	LD	(TICK_MISS),A
	LD	A,(RB_WANT)
	LD	D,A
	PUSH	BC
	CALL	G4_RECHECK
	POP	BC
	OR	A
	JR	Z,G4_VERDICT_MISREAD
	DEC	A
	JR	NZ,G4_VERDICT_UNSURE
	LD	BC,G4_WR_BAD
	LD	A,D
	CPL				; the previous sweep's pattern
	CP	E
	JR	NZ,G4_VERDICT_HELD
	LD	BC,G4_WR_LOST
	; fall through

; BC = counter.  Keep the first G4_WSAMPLES: page-1 offset of the
; register, wanted, held.
G4_VERDICT_HELD
	PUSH	HL
	LD	H,B
	LD	L,C
	CALL	BUMP
	POP	HL
	LD	A,(G4_NWSAMP)
	CP	G4_WSAMPLES
	JR	NC,G4_VERDICT_DONE
	LD	C,A
	INC	A
	LD	(G4_NWSAMP),A
	LD	A,(RTL_BASE_PTR)
	LD	B,A
	LD	A,L
	SUB	B			; page-1 offset of the register
	LD	L,A
	LD	A,C
	ADD	A,A
	ADD	A,C			; 3 bytes per sample
	LD	C,A
	LD	B,0
	LD	A,L
	LD	HL,G4_WSAMP
	ADD	HL,BC
	LD	(HL),A
	INC	HL
	LD	(HL),D
	INC	HL
	LD	(HL),E
	JR	G4_VERDICT_DONE
G4_VERDICT_UNSURE
	LD	HL,G4_UNSURE
	CALL	BUMP
	JR	G4_VERDICT_DONE
G4_VERDICT_MISREAD
	LD	A,C
	XOR	D			; the bits the first read got wrong
	LD	HL,G4_ERRBITS
	OR	(HL)
	LD	(HL),A
	LD	HL,G4_BAD
	CALL	BUMP
G4_VERDICT_DONE
	POP	HL
	POP	DE
	POP	BC
	RET

; ------------------------------------------------------
; SET_PAGE: CR := A, confirmed by TWO different registers.
; Reading CR back is not enough on a bus where the chip now
; and then sits out a cycle: a read it does not answer
; returns what the previous cycle left on the bus, and after
; a CR write that is the very value being checked for.  So
; offset 3 is read in between.  On page 1 it is PAR2 and must
; hold TEST_MAC2; on page 0 it is BNRY and must lie inside
; the ring; the two ranges are disjoint, and either value
; takes the written byte off the bus before CR is read.
; A switch that needed a second attempt counts once in
; cr-bad -- which of the three cycles failed is not known.
;   Out: CF = four attempts and still not confirmed.  The
;        caller must not touch any page-dependent register.
; ISA open.  Trashes A, BC, IX.  Plain RAM only.
; ------------------------------------------------------
SET_PAGE
	LD	IX,(RTL_BASE_PTR)
	LD	C,A
	LD	B,4
.TRY
	LD	(IX+RTL_CR_OFF),C
	LD	A,(IX+RTL_BNRY_OFF)
	BIT	6,C
	JR	Z,.PAGE0
	CP	TEST_MAC2
	JR	NZ,.BAD
	JR	.CR
.PAGE0
	SUB	RTL_PSTART_INIT
	CP	RTL_PSTOP_INIT - RTL_PSTART_INIT
	JR	NC,.BAD
.CR
	LD	A,(IX+RTL_CR_OFF)
	XOR	C
	AND	CR_VERIFY_MASK
	RET	Z			; AND left CF clear
.BAD
	LD	A,1
	LD	(TICK_MISS),A
	LD	A,B
	CP	4
	JR	NZ,.COUNTED
	PUSH	HL
	LD	HL,G4_CR_BAD
	CALL	BUMP
	POP	HL
.COUNTED
	DJNZ	.TRY
	SCF
	RET

; ------------------------------------------------------
; DRAIN_RING: throw away whatever the receiver stored, so
; the ring cannot overflow while we are not reading frames:
; BNRY := CURR - 1.  CURR is read twice and used only when
; both reads agree, and both page switches are confirmed.
; ISA open; uses the current row's CR values.
;   Out: CF = a page switch could not be confirmed; nothing
;        was written after it.  Otherwise A = pages the ring
;        moved since the last call (0 also when CURR could
;        not be read).
; Trashes BC, IX.
; ------------------------------------------------------
DRAIN_RING
	LD	A,(ROW_CR_P1)
	CALL	SET_PAGE
	RET	C
	LD	A,(IX+RTL_CURR_OFF)
	LD	(DRAIN_CURR),A
	LD	A,(IX+RTL_CURR_OFF)
	LD	(DRAIN_CURR2),A
	LD	A,(ROW_CR_P0)
	CALL	SET_PAGE
	RET	C
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
	OR	A			; NC
	RET
.SKIP
	XOR	A
	RET


; ======================================================
; [G6] the remote-DMA data port.
;
; [G1]..[G4] only ever touch the 16-byte register file.  A
; real utility spends almost every ISA cycle somewhere else:
; the data port at BASE+0x10, pushed and pulled hundreds of
; bytes at a time with no read-back anywhere.  A cycle lost
; there is a corrupted frame, not a register worth retrying.
;
; Each burst writes G6_LEN bytes of "offset XOR seed" into
; packet RAM below PSTART -- TX RAM, which the receiver never
; touches -- and reads them straight back.  The seed changes
; every burst so stale contents cannot pass, and neighbouring
; bytes always differ, so a cycle the chip does not answer
; (the bus then holds the previous byte) shows up.
;
; When the read-back differs the same bytes are read a second
; time and the two counts name the event:
;   rd-bad   the second pass was clean: the first read lied;
;   mem-bad  the second pass found as many: what sits in
;            packet RAM is wrong, so a write cycle was lost;
;   unsure   the second pass agreed with neither.
; The passes are counted, not matched offset by offset, so
; "as many" is a strong hint and not a proof.
;
; There is no stopped row: every remote-DMA command carries
; STA, so a burst starts the chip by definition.  The control
; is [G4]'s stop row, which uses the same bus and the same
; window discipline.
; ======================================================
G6_BURSTS	EQU 800
G6_LEN		EQU 128			; bytes per burst, each way
G6_ADDR		EQU 0x4000		; TX RAM: below PSTART, never received into
G6_SAMPLES	EQU 4
G6_RDC_POLLS	EQU 250
	ASSERT G6_BURSTS == 800 && G6_LEN == 128	; MSG_G6 says so
	ASSERT G6_ADDR + G6_LEN <= RTL_PSTART_INIT * 256

PHASE_G6
	PRINTLN	MSG_G6
	PRINTLN	MSG_G6_HEAD
	LD	A,RTL_DATA_OFF
	CALL	REG_ADDR
	LD	(G6_PORT),HL
	LD	(G6_PORTW),HL
	LD	HL,CR_PAGE1_START * 256 + CR_PAGE0_START
	LD	A,RCR_MON
	LD	DE,MSG_G4_DEAF
	CALL	G6_ROW
	LD	HL,CR_PAGE1_START * 256 + CR_PAGE0_START
	LD	A,RCR_AB
	LD	DE,MSG_G4_LIVE
	; fall through

; ------------------------------------------------------
; G6_ROW: one row of [G6].  Same arguments as G4_ROW, and
; the same shared row state, so SET_PAGE, G4_SETUP and
; DRAIN_RING work here unchanged.
; ------------------------------------------------------
G6_ROW
	LD	(G6_LABEL),DE
	LD	(G4_RCR),A
	LD	(ROW_CR_P0),HL		; L -> ROW_CR_P0, H -> ROW_CR_P1
	LD	HL,G4_ROW_STATE		; RX_PAGES and the page-loss counters
	LD	DE,G4_ROW_STATE + 1
	LD	BC,G4_ROW_LEN - 1
	LD	(HL),0
	LDIR
	LD	HL,G6_ROW_STATE
	LD	DE,G6_ROW_STATE + 1
	LD	BC,G6_ROW_LEN - 1
	LD	(HL),0
	LDIR
	CALL	@ISA.ISA_OPEN
	CALL	G4_SETUP
	CALL	@ISA.ISA_CLOSE
	JP	C,G6_ABORT
	LD	HL,G6_BURSTS
	LD	(G6_LEFT),HL
G6_NEXT
	XOR	A
	LD	(G6_DIRTY),A
	CALL	@ISA.ISA_OPEN
	LD	A,(ROW_CR_P0)
	CALL	SET_PAGE
	JR	C,G6_PAGE_LOST
	CALL	G6_BURST
	CALL	DRAIN_RING		; keep the ring from overflowing
	JR	C,G6_PAGE_LOST
	CALL	@ISA.ISA_CLOSE
	JR	G6_PACE

	; Same contract as [G4]: an unconfirmed page means this window
	; touches nothing more, and the row is set up from scratch.
G6_PAGE_LOST
	LD	HL,G4_PG_LOST
	CALL	BUMP
	CALL	G4_SETUP
	CALL	@ISA.ISA_CLOSE		; preserves AF
	JR	C,G6_ABORT
G6_PACE
	LD	A,(G6_DIRTY)
	OR	A
	JR	Z,.CLEAN
	LD	HL,G6_BURSTS_BAD
	CALL	BUMP
.CLEAN
	CALL	@UTIL.DELAY_1MS		; window closed: the 50 Hz IRQ gets its turn
	LD	HL,(G6_LEFT)
	DEC	HL
	LD	(G6_LEFT),HL
	LD	A,H
	OR	L
	JP	NZ,G6_NEXT
	JR	G6_PRINT

G6_ABORT
	LD	A,1
	LD	(G6_ABORTED),A

	; " deaf 0000   0000   0000    0000   0000   0000   0000"
G6_PRINT
	LD	HL,0
G6_LABEL EQU $-2
	PRINT_HL
	LD	HL,(G6_BAD)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_SP3
	LD	HL,(G6_RD_BAD)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_SP3
	LD	HL,(G6_MEM_BAD)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_SP4
	LD	HL,(G6_UNSURE)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_SP3
	LD	HL,(G6_BURSTS_BAD)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_SP3
	LD	HL,(G6_RDC_BAD)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_SP3
	LD	HL,(RX_PAGES)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	LINE_END

	LD	HL,G6_FAIL_FIRST
	LD	B,G6_FAIL_LEN
	XOR	A
.ANY
	OR	(HL)
	INC	HL
	DJNZ	.ANY
	JR	Z,.OK
	CALL	SET_FAILED
.OK
	; "  dma 0A=5C>5D ...": offset inside the burst, the byte that
	; was written there, the byte that came back.
	LD	A,(G6_NSAMP)
	OR	A
	JR	Z,.NO_SAMP
	PRINT	MSG_G6_DMA
	LD	A,(G6_NSAMP)
	LD	B,A
	LD	HL,G6_SAMP
.SAMP
	PUSH	BC,HL
	LD	A,(HL)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,'='
	CALL	PUTCHAR
	POP	HL,BC
	INC	HL
	PUSH	BC,HL
	LD	A,(HL)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,'>'
	CALL	PUTCHAR
	POP	HL,BC
	INC	HL
	PUSH	BC,HL
	LD	A,(HL)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,' '
	CALL	PUTCHAR
	POP	HL,BC
	INC	HL
	DJNZ	.SAMP
	CALL	PUT_CRLF
.NO_SAMP
	CALL	PRINT_PG_LOST
	LD	A,(G6_ABORTED)
	OR	A
	RET	Z
	PRINTLN	MSG_G4_ABORTED
	RET

; ------------------------------------------------------
; G6_BURST: write G6_LEN pattern bytes through the data
; port and read them back.  ISA open, page 0 confirmed,
; IX = base.  Leaves the chip on page 0.
; ------------------------------------------------------
G6_BURST
	; The pattern is built in plain RAM first and the comparison is
	; done in plain RAM afterwards, so that the loop that touches the
	; data port does nothing but move bytes -- the same three
	; instructions, through the same fixed-address DE, as the
	; driver's DMA_WRITE/DMA_READ.  The first version computed each
	; byte inside the transfer loop; on a UM9003AF every burst then
	; came back one byte behind (2026-09-21), while the driver's own
	; 1536-byte round trips on the same card were exact.  A phase
	; that does not access the port the way the driver does measures
	; something no utility ever performs.
	LD	HL,G6_SEED
	INC	(HL)
	LD	C,(HL)
	LD	HL,G6_PAT
	LD	E,0
	LD	B,G6_LEN
.FILL
	LD	A,E
	XOR	C
	LD	(HL),A
	INC	HL
	INC	E
	DJNZ	.FILL
	LD	A,CR_DMA_WRITE
	CALL	G6_DMA_START
	LD	HL,G6_PAT
	LD	DE,0
G6_PORTW EQU $-2
	LD	B,G6_LEN
G6_BURST_WR				; global: G6_PORTW ended the local scope
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	DJNZ	G6_BURST_WR
	CALL	G6_DMA_END
	RET	C			; packet RAM holds something unknown now
	LD	A,1
	LD	(G6_SAMPOK),A
	CALL	G6_READ_PASS
	OR	A
	RET	Z
	LD	D,A			; mismatching bytes, first pass
	LD	A,1
	LD	(G6_DIRTY),A
	LD	A,D
	LD	HL,G6_BAD
	CALL	ADDW
	XOR	A
	LD	(G6_SAMPOK),A
	PUSH	DE
	CALL	G6_READ_PASS
	POP	DE
	LD	HL,G6_UNSURE		; no LD affects the flags below
	JR	C,G6_NAMED		; the second pass never ran
	LD	HL,G6_RD_BAD
	OR	A
	JR	Z,G6_NAMED		; second pass clean: the reads lied
	LD	HL,G6_MEM_BAD
	CP	D
	JR	Z,G6_NAMED		; as many again: packet RAM holds it wrong
	LD	HL,G6_UNSURE
G6_NAMED
	LD	A,D
	JP	ADDW

; ------------------------------------------------------
; G6_READ_PASS: read the burst back and compare.
;   In:  (G6_SAMPOK) = keep samples.
;   Out: A = mismatching bytes, saturated at 255;
;        CF = the pass could not be run at all.
; ISA open, IX = base.  Trashes A, BC, DE, HL.
; ------------------------------------------------------
G6_READ_PASS
	LD	A,CR_DMA_READ
	CALL	G6_DMA_START
	LD	HL,G6_RB
	LD	DE,0
G6_PORT	EQU $-2
	LD	B,G6_LEN
G6_READ_LOOP				; global: G6_PORT ended the local scope
	LD	A,(DE)
	LD	(HL),A
	INC	HL
	DJNZ	G6_READ_LOOP
	CALL	G6_DMA_END
	JR	C,G6_READ_VOID
	; Plain RAM from here on; the window is still open but nothing
	; below touches the chip.
	XOR	A
	LD	(G6_NBAD),A
	LD	HL,G6_PAT
	LD	DE,G6_RB
	LD	BC,G6_LEN * 256		; B = bytes left, C = offset
G6_CMP
	LD	A,(DE)
	CP	(HL)
	CALL	NZ,G6_BYTE_BAD
	INC	HL
	INC	DE
	INC	C
	DJNZ	G6_CMP
	LD	A,(G6_NBAD)
	OR	A			; clears CF: the pass did run
	RET

; A burst the chip did not carry out: the bytes that came back mean
; nothing, so they are not compared at all.
G6_READ_VOID
	XOR	A
	SCF
	RET

G6_DMA_FAILED
	LD	HL,G6_RDC_BAD
	CALL	BUMP
	LD	A,1
	LD	(G6_DIRTY),A
	RET

; ------------------------------------------------------
; G6_BYTE_BAD: one byte did not match.
;   In: A = read, (HL) = written, C = offset.
; Preserves every register pair.  Trashes A.
; ------------------------------------------------------
G6_BYTE_BAD
	PUSH	HL
	PUSH	DE
	PUSH	BC
	LD	D,A			; read
	LD	E,(HL)			; written
	LD	A,(G6_NBAD)
	INC	A
	JR	Z,.SAT			; 255 stays 255
	LD	(G6_NBAD),A
.SAT
	LD	A,(G6_SAMPOK)
	OR	A
	JR	Z,.DONE
	LD	A,(G6_NSAMP)
	CP	G6_SAMPLES
	JR	NC,.DONE
	INC	A
	LD	(G6_NSAMP),A
	DEC	A
	LD	B,A
	ADD	A,A
	ADD	A,B			; 3 bytes per sample
	LD	HL,G6_SAMP
	ADD	A,L
	LD	L,A
	JR	NC,.NC
	INC	H
.NC
	LD	(HL),C
	INC	HL
	LD	(HL),E
	INC	HL
	LD	(HL),D
.DONE
	POP	BC
	POP	DE
	POP	HL
	RET

; ------------------------------------------------------
; G6_DMA_START: arm a remote DMA of G6_LEN bytes at G6_ADDR
; and hand the data port straight to the transfer loop.
;
; Arming prefetches: the chip pulls the first byte into its
; FIFO the moment the command lands.  Anything that happens
; between that command and the first data cycle can leave
; that byte in the FIFO to be popped a second time, and the
; whole burst then reads one byte behind.  Measured twice on
; a UM9003AF (2026-09-21), in all 800 bursts of both rows,
; with and without traffic: first with three register reads
; sitting in that gap, then with the chip armed a second
; time after them.  Offset 0 matched in both cases -- the
; stale byte is the one at G6_ADDR -- and everything after
; it was the previous byte.  So: arm once, touch nothing,
; transfer.  The driver does exactly that.
;
; Nothing is checked beforehand, because G6_DMA_END checks
; more afterwards: CRDA landing exactly G6_LEN bytes on
; proves RSAR, RBCR and the command all reached the chip.
;   In: A = the CR command.  ISA open, IX = base.
; Trashes A.  Preserves BC, DE, HL.
; Global labels: G6_DMA_CMD would capture the local scope.
; ------------------------------------------------------
G6_DMA_START
	LD	(G6_DMA_CMD),A
	LD	(IX+RTL_CR_OFF),CR_DMA_ABORT
	LD	(IX+RTL_ISR_OFF),ISR_RDC
	LD	(IX+RTL_RBCR0_OFF),G6_LEN
	LD	(IX+RTL_RBCR1_OFF),0
	LD	(IX+RTL_RSAR0_OFF),G6_ADDR & 0xFF
	LD	(IX+RTL_RSAR1_OFF),G6_ADDR >> 8
	LD	A,0
G6_DMA_CMD EQU $-1
	LD	(IX+RTL_CR_OFF),A
	RET

; ------------------------------------------------------
; G6_DMA_END: the transfer is already over by the time we get
; here, so this only confirms that it happened -- RDC set, and
; the DMA address exactly G6_LEN bytes on.  The second arm in
; G6_DMA_START is the one write sequence nothing could check
; beforehand; this is where it gets checked, after the data
; cycles rather than in the middle of them.
;   Out: CF = the burst did not complete.  It is counted under
;        rdc-to and its byte comparisons are thrown away.
; ISA open, IX = base.  Trashes A, B, HL.
; ------------------------------------------------------
G6_DMA_END
	LD	B,G6_RDC_POLLS
.LP
	LD	A,(IX+RTL_ISR_OFF)
	AND	ISR_RDC
	JR	NZ,.RDC
	DJNZ	.LP
	JR	.BAD
.RDC
	LD	(IX+RTL_ISR_OFF),ISR_RDC
	LD	A,(IX+RTL_CRDA0_OFF)
	CP	(G6_ADDR + G6_LEN) & 0xFF
	JR	NZ,.BAD
	LD	A,(IX+RTL_CRDA1_OFF)
	CP	(G6_ADDR + G6_LEN) >> 8
	RET	Z			; equal leaves CF clear
.BAD
	CALL	G6_DMA_FAILED
	LD	(IX+RTL_CR_OFF),CR_DMA_ABORT	; next burst starts clean
	SCF
	RET

; ADDW: the 16-bit counter at HL += A, saturating at FFFF.
; Trashes A, HL.  Plain RAM only.
; BUMP's trick of decrementing back does not work here: the low
; byte is not 0 after the carry, so both bytes are set outright.
ADDW
	ADD	A,(HL)
	LD	(HL),A
	RET	NC
	INC	HL
	INC	(HL)
	RET	NZ
	LD	(HL),0xFF		; FFFF stays FFFF
	DEC	HL
	LD	(HL),0xFF
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
TEST_MAC2	EQU 0x19		; SET_PAGE tells page 1 by it
TEST_MAC	DB 0x02, 0x80, TEST_MAC2, 0x11, 0x22, 0x33
	ASSERT TEST_MAC2 < RTL_PSTART_INIT || TEST_MAC2 >= RTL_PSTOP_INIT
; [G4] write patterns, complemented on odd sweeps.  No value is the
; complement of another one: a cycle the chip does not answer returns
; what the previous cycle left on the bus, and that must never look
; like "the previous sweep's pattern", i.e. like a lost write.  (The
; first version used 3C C3 69 96, where MAR1 and MAR3 had exactly that
; flaw.)  None of the eight values is a TEST_MAC byte, a ring page or
; a CR value either.
G4_WR_BASE	DB 0x1E, 0x2D, 0x87, 0x36
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
MSG_LOAD	DB " load=",0
MSG_BAD_EQ	DB " bad=",0
MSG_BITS_EQ	DB " bits=",0
MSG_G2		DB "[G2] PAGE2 CONFIG  written|and/or after 00|after FF  bad=",0
MSG_G3		DB "[G3] PAGE0 STATUS  and/or after 00|after FF  CR bad=",0
MSG_G4		DB "[G4] PAR=",0
MSG_G4_TAIL	DB "  per row: 288000 reads, 192000 writes",0
MSG_G4_HEAD	DB " row  rd-bad bits wr-lost wr-bad unsure cr-bad rxpages badticks withrx",0
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
MSG_PG_LOST	DB "  page lost=",0
MSG_SETUP_RETRY	DB " setup retries=",0
MSG_G4_ABORTED	DB "  row aborted: the chip state could not be set up",0
MSG_G6		DB "[G6] DMA DATA PORT, per row: 800 bursts x 128 bytes",0
MSG_G6_HEAD	DB " row  bytes  rd-bad mem-bad unsure bursts rdc-to rxpages",0
MSG_G6_DMA	DB "  dma ",0
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
G1_LOAD_BAD	EQU BSS_START + 63	; 1
G1_BAD		EQU BSS_START + 64	; G1_REGS words
G1_ERR		EQU BSS_START + 92	; G1_REGS bytes
G2_RES		EQU BSS_START + 106	; G2_COUNT * 4
G3_RES		EQU BSS_START + 130	; G3_COUNT * 4
TX_BUF		EQU BSS_START + 190	; FRAME_LEN
; G4_ROW clears these in one go at the start of each row.
G4_ROW_STATE	EQU BSS_START + 250
RX_PAGES	EQU G4_ROW_STATE + 0	; 2
G4_BADTICKS	EQU G4_ROW_STATE + 2	; 2
G4_WITHRX	EQU G4_ROW_STATE + 4	; 2
G4_NSAMP	EQU G4_ROW_STATE + 6	; 1
MISS_PENDING	EQU G4_ROW_STATE + 7	; 1
G4_NWSAMP	EQU G4_ROW_STATE + 8	; 1
G4_ERRBITS	EQU G4_ROW_STATE + 9	; 1
; G4_PRINT ORs this block together: any non-zero byte fails the run.
G4_FAIL_FIRST	EQU G4_ROW_STATE + 10
G4_BAD		EQU G4_FAIL_FIRST + 0	; 2
G4_WR_LOST	EQU G4_FAIL_FIRST + 2	; 2
G4_WR_BAD	EQU G4_FAIL_FIRST + 4	; 2
G4_UNSURE	EQU G4_FAIL_FIRST + 6	; 2
G4_CR_BAD	EQU G4_FAIL_FIRST + 8	; 2
G4_PG_LOST	EQU G4_FAIL_FIRST + 10	; 2
G4_SETUP_RETRY	EQU G4_FAIL_FIRST + 12	; 2
G4_ABORTED	EQU G4_FAIL_FIRST + 14	; 1
G4_FAIL_LEN	EQU 15
G4_SAMP		EQU G4_ROW_STATE + 25	; G4_SAMPLES * 3
G4_WSAMP	EQU G4_ROW_STATE + 43	; G4_WSAMPLES * 3
G4_ROW_LEN	EQU 55
; G6_ROW clears these in one go at the start of each row.
G6_ROW_STATE	EQU BSS_START + 306
G6_SEED		EQU G6_ROW_STATE + 0	; 1
G6_DIRTY	EQU G6_ROW_STATE + 1	; 1
G6_SAMPOK	EQU G6_ROW_STATE + 2	; 1
G6_NSAMP	EQU G6_ROW_STATE + 3	; 1
G6_LEFT		EQU G6_ROW_STATE + 4	; 2
; G6_PRINT ORs this block together: any non-zero byte fails the run.
G6_FAIL_FIRST	EQU G6_ROW_STATE + 6
G6_BAD		EQU G6_FAIL_FIRST + 0	; 2
G6_RD_BAD	EQU G6_FAIL_FIRST + 2	; 2
G6_MEM_BAD	EQU G6_FAIL_FIRST + 4	; 2
G6_UNSURE	EQU G6_FAIL_FIRST + 6	; 2
G6_BURSTS_BAD	EQU G6_FAIL_FIRST + 8	; 2
G6_RDC_BAD	EQU G6_FAIL_FIRST + 10	; 2
G6_ABORTED	EQU G6_FAIL_FIRST + 12	; 1
G6_FAIL_LEN	EQU 13
G6_SAMP		EQU G6_ROW_STATE + 19	; G6_SAMPLES * 3
G6_NBAD		EQU G6_ROW_STATE + 31	; 1, per read pass
G6_ROW_LEN	EQU 32
BSS_CLEAR_LEN	EQU 338
; Written before read, every burst: outside the cleared area.
G6_PAT		EQU BSS_START + 340	; G6_LEN, what went to the chip
G6_RB		EQU G6_PAT + G6_LEN	; G6_LEN, what came back
	ASSERT G1_BAD + G1_REGS * 2 <= G1_ERR
	ASSERT G1_ERR + G1_REGS <= G2_RES
	ASSERT G2_RES + G2_COUNT * 4 <= G3_RES
	ASSERT G3_RES + G3_COUNT * 4 <= TX_BUF
	ASSERT TX_BUF + FRAME_LEN <= G4_ROW_STATE
	ASSERT G4_FAIL_FIRST + G4_FAIL_LEN <= G4_SAMP
	ASSERT G4_SAMP + G4_SAMPLES * 3 <= G4_WSAMP
	ASSERT G4_WSAMP + G4_WSAMPLES * 3 <= G4_ROW_STATE + G4_ROW_LEN
	ASSERT ROW_CR_P1 == ROW_CR_P0 + 1
	ASSERT G4_ROW_STATE + G4_ROW_LEN <= G6_ROW_STATE
	ASSERT G6_FAIL_FIRST + G6_FAIL_LEN <= G6_SAMP
	ASSERT G6_SAMP + G6_SAMPLES * 3 <= G6_NBAD
	ASSERT G6_ROW_STATE + G6_ROW_LEN <= BSS_START + BSS_CLEAR_LEN
	ASSERT BSS_START + BSS_CLEAR_LEN <= G6_PAT
	ASSERT G6_RB + G6_LEN < RT_STACK_TOP - 0x200
	ASSERT BSS_START + BSS_CLEAR_LEN < RT_STACK_TOP - 0x200

	ENDMODULE

	END MAIN.START
