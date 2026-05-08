; ======================================================
; NICINFO.EXE - stage 1 of the Sprinter RTL8019AS network kit.
; Detects the card on ISA1, performs an NE2000-style reset,
; reads the page-0 8019ID0/ID1 ('P','p'), reads 32 bytes of
; PROM via remote DMA, prints MAC, signature bytes, detected
; PROM layout, and a register snapshot.
;
; Acceptance (per AGENTS.md and sprinter_rtl8019_soft.md):
;   FAIL only if neither ID nor a plausible MAC can be read,
;   or RESET times out, or PROM remote DMA times out.
;   Signature mismatch is WARN, not FAIL.
; ======================================================

EXE_VERSION		EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "rtl8019.inc"		; pure EQUs (also pulls isa.inc)

	DEFINE USE_UTIL_EXIT_NO_NIC	; fast-fail "no NIC" path

	MODULE MAIN

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
	DW STACK_TOP
	DS 106, 0

	ORG 0x8100
@STACK_TOP

START
	PRINTLN MSG_BANNER

	; Try to find the chip on slot 1, then slot 0; INIT_BASE
	; populates RTL_BASE_PTR and leaves ISA OPEN on success.
	LD	A,1
	LD	(@ISA.ISA_SLOT),A
	CALL	@RTL.INIT_BASE
	JP	C,SCAN_FAIL

	; [N0] Slot/Addr: N/#HHH  -- canonical form, matches the
	; NET_RTL_HW env var written by INIT_BASE.
	PRINT MSG_N0
	LD	A,(@ISA.ISA_SLOT)
	ADD	A,'0'
	CALL	PUTCHAR
	PRINT MSG_N0_SEP
	LD	HL,(RTL_BASE_PTR)
	LD	A,H
	SUB	HIGH ISA_BASE_A
	AND	0x0F			; high hex nibble of the I/O addr
	CALL	PRINT_HEX_NIBBLE
	LD	A,L
	RRCA
	RRCA
	RRCA
	RRCA
	AND	0x0F
	CALL	PRINT_HEX_NIBBLE
	LD	A,L
	AND	0x0F
	CALL	PRINT_HEX_NIBBLE
	PRINT LINE_END

	; Diagnostic scan of all 16 candidate bases on the active
	; slot.  RTL_BASE_PTR is already set by INIT_BASE.
	CALL	SCAN_BASES

	; [N1] RESET
	PRINT MSG_N1
	CALL	@RTL.RESET
	JP	C,RESET_FAIL
	PRINTLN MSG_OK

	; Mandatory: DCR=0x48 via the runtime base.
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_DCR_OFF),DCR_INIT

	; [N2] CR=xx ISR=xx
	PRINT MSG_N2
	LD	A,(IX+RTL_CR_OFF)
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_ISR_EQ
	LD	A,(IX+RTL_ISR_OFF)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END

	; [N3] RTL ID
	CALL	@RTL.PROBE_ID
	PRINT MSG_N3
	LD	A,(@RTL.ID0_RAW)
	CALL	PRINT_PRINTABLE
	LD	A,(@RTL.ID1_RAW)
	CALL	PRINT_PRINTABLE
	PRINT MSG_PAREN_OPEN
	LD	A,(@RTL.ID0_RAW)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,' '
	CALL	PUTCHAR
	LD	A,(@RTL.ID1_RAW)
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_PAREN_CLOSE
	PRINT LINE_END

	; PROM read (32 bytes from address 0x0000)
	LD	HL,PROM_BUF
	CALL	@RTL.READ_PROM
	JP	C,PROM_FAIL

	CALL	DETECT_LAYOUT
	LD	(LAYOUT),A

	LD	A,(LAYOUT)
	CP	1
	CALL	Z,BUILD_DOUBLED_MAC

	; [N4] PROM MAC=xx:xx:xx:xx:xx:xx
	PRINT MSG_N4
	LD	A,(LAYOUT)
	CP	1
	JR	NZ,.MAC_DIRECT
	LD	HL,MAC_BUF
	JR	.MAC_PRINT
.MAC_DIRECT
	LD	HL,PROM_BUF
.MAC_PRINT
	CALL	@UTIL.PRINT_MAC
	PRINT LINE_END

	; PROM[0E..0F]=xx yy
	PRINT MSG_PROM_SIG
	LD	A,(PROM_BUF + 0x0E)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,' '
	CALL	PUTCHAR
	LD	A,(PROM_BUF + 0x0F)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END

	; PROM_LAYOUT=...
	PRINT MSG_LAYOUT
	LD	A,(LAYOUT)
	OR	A
	JR	NZ,.LY1
	PRINT MSG_DIRECT
	JR	.LY_DONE
.LY1
	CP	1
	JR	NZ,.LY2
	PRINT MSG_DOUBLED
	JR	.LY_DONE
.LY2
	PRINT MSG_UNKNOWN
.LY_DONE
	PRINT LINE_END

	; [N5] register snapshot
	CALL	@RTL.SNAPSHOT_REGS
	CALL	PRINT_REG_DUMP

	; -- determine RESULT --
	LD	A,(@RTL.ID0_RAW)
	CP	RTL_ID0_VAL
	JR	NZ,ID_BAD
	LD	A,(@RTL.ID1_RAW)
	CP	RTL_ID1_VAL
	JR	NZ,ID_BAD

	; ID OK -- check signature
	LD	A,(PROM_BUF + 0x0E)
	CP	0x57
	JR	NZ,SIG_WARN
	LD	A,(PROM_BUF + 0x0F)
	CP	0x57
	JR	NZ,SIG_WARN

	PRINTLN MSG_RESULT_OK
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_OK

SIG_WARN
	PRINTLN MSG_W_SIG
	PRINTLN MSG_RESULT_OK
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_OK

ID_BAD
	PRINTLN MSG_E_ID
	CALL	VALIDATE_MAC
	JR	C,NO_HW
	PRINTLN MSG_W_NO_ID
	PRINTLN MSG_RESULT_OK
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_OK

NO_HW
	PRINTLN MSG_RESULT_FAIL
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_NO_HW

RESET_FAIL
	PRINTLN MSG_E_RESET
	PRINTLN MSG_RESULT_FAIL
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_NIC_ERR

PROM_FAIL
	PRINTLN MSG_E_PROM
	PRINTLN MSG_RESULT_FAIL
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_NIC_ERR

SCAN_FAIL
	; The default base 0x300 did not respond.  Either the card
	; is missing entirely or it is jumpered to one of the
	; alternates -- which one (if any) the user can read off the
	; "Scan:" line above.  The driver is currently hard-wired to
	; 0x300, so we cannot continue here either way.
	PRINTLN MSG_E_SCAN
	PRINTLN MSG_RESULT_FAIL
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_NO_HW


; ------------------------------------------------------
; SCAN_BASES: probe each candidate I/O base and print one
; line of the form
;   "Scan: 300=ok 320=- 340=- 360=-"
; (or "no" instead of "-" if a probe fails after starting
; to write -- not currently distinguished, both are "-").
;
; Out: CF=0 if the default base 0x300 responded; CF=1 if
;      0x300 did not respond (the caller's normal flow
;      cannot continue because the rest of the driver is
;      hard-wired to 0x300).  Other bases that responded
;      are still printed in the table, so a user who has
;      jumpered the card to e.g. 0x320 still sees a clue.
; Trashes A,BC,DE,HL.
; ------------------------------------------------------
SCAN_BASES
	PRINT MSG_SCAN_HDR
	XOR	A
	LD	(.AT_300),A
	LD	(.SEEN),A
	LD	HL,SCAN_TABLE
.LP
	; Read entry into DE; advance HL.  HL is the table cursor.
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	INC	HL
	LD	A,D
	OR	E
	JR	Z,.DONE
	; Every 8 entries: line break + small indent for readability.
	LD	A,(.SEEN)
	OR	A
	JR	Z,.NO_BREAK
	AND	0x07
	JR	NZ,.NO_BREAK
	PUSH	HL
	PUSH	DE
	PRINT LINE_END
	PRINT MSG_SCAN_INDENT
	POP	DE
	POP	HL
.NO_BREAK
	LD	A,(.SEEN)
	INC	A
	LD	(.SEEN),A
	; Save cursor + entry across DSS calls.  RST DSS does NOT
	; preserve IX/IY (and may not preserve all GP regs); the
	; stack is the only safe stash.
	PUSH	HL			; cursor
	PUSH	DE			; window addr
	; Print "<I/O base>=" by stripping the ISA window high byte.
	LD	A,D
	SUB	HIGH ISA_BASE_A
	CALL	@UTIL.PRINT_HEX_A
	LD	A,E
	CALL	@UTIL.PRINT_HEX_A
	LD	A,'='
	CALL	PUTCHAR
	; Probe at the saved window addr.
	POP	DE
	PUSH	DE			; keep it for the 0x300 check
	LD	H,D
	LD	L,E
	CALL	PROBE_AT_HL
	JR	C,.MISS
	PRINT MSG_SCAN_OK
	POP	DE			; window addr just probed
	LD	A,D
	CP	HIGH (ISA_BASE_A + 0x300)
	JR	NZ,.AFTER
	LD	A,E
	CP	LOW (ISA_BASE_A + 0x300)
	JR	NZ,.AFTER
	LD	A,1
	LD	(.AT_300),A
.AFTER
	POP	HL			; restore cursor
	JR	.LP
.MISS
	POP	DE			; discard saved window addr
	PRINT MSG_SCAN_NO
	POP	HL			; restore cursor
	JR	.LP
.DONE
	PRINT LINE_END
	LD	A,(.AT_300)
	OR	A
	RET	NZ			; CF=0, default base ok
	SCF
	RET
.AT_300	DB 0
.SEEN	DB 0


; ------------------------------------------------------
; PROBE_AT_HL: presence probe at window address HL (HL =
; e.g. 0xC300 for I/O base 0x300).  Same idea as
; @RTL.PROBE_PRESENT but parameterized so we can test
; alternate bases without rebuilding the driver.
;
; Layout used: HL+0 = CR, HL+3 = BNRY (R/W), HL+4 = TPSR (W).
; The two-port write/read trick defeats the ISA-bus latch:
; an absent card retains the last byte driven onto the
; bus, so a same-port round-trip falsely looks like a hit.
; We write to BNRY, clobber via TPSR, then read BNRY back.
;
; Out: CF=0 chip responding at this base; CF=1 absent.
; Trashes A.  HL preserved.
; ------------------------------------------------------
PROBE_AT_HL
	PUSH	HL
	; Stop the chip on this candidate base.
	LD	A,CR_PAGE0_STOP
	LD	(HL),A			; CR
	INC	HL
	INC	HL
	INC	HL			; HL -> BNRY
	; Round 1: BNRY=0xAA, clobber bus via TPSR=0x55, read BNRY.
	LD	A,0xAA
	LD	(HL),A
	INC	HL			; HL -> TPSR
	LD	A,0x55
	LD	(HL),A
	DEC	HL			; HL -> BNRY
	LD	A,(HL)
	CP	0xAA
	JR	NZ,.MISS
	; Round 2: invert.
	LD	A,0x55
	LD	(HL),A
	INC	HL
	LD	A,0xAA
	LD	(HL),A
	DEC	HL
	LD	A,(HL)
	CP	0x55
	JR	NZ,.MISS
	POP	HL
	OR	A
	RET
.MISS
	POP	HL
	SCF
	RET


; Full 16-entry NE2000 / RTL8019AS jumperless candidate
; set, 32-byte stride.  All within Sprinter's 14-bit ISA
; window (PORT_ISA=0 maps I/O 0x0000..0x3FFF to memory
; 0xC000..0xFFFF), so no window remap is needed.
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
; Print one byte (in A) as printable ASCII or '.'
; ------------------------------------------------------
PRINT_PRINTABLE
	PUSH	AF,BC
	CP	32
	JR	C,.DOT
	CP	127
	JR	NC,.DOT
	JR	.OK
.DOT
	LD	A,'.'
.OK
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC,AF
	RET

PUTCHAR
	PUSH	AF,BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC,AF
	RET

; ------------------------------------------------------
; PRINT_HEX_NIBBLE: A = 0..15 -> '0'..'9' or 'A'..'F'.
; ------------------------------------------------------
PRINT_HEX_NIBBLE
	CP	10
	JR	C,.D
	ADD	A,'A' - 10
	JR	PUTCHAR
.D
	ADD	A,'0'
	JR	PUTCHAR

; ------------------------------------------------------
; DETECT_LAYOUT: A = 0 direct, 1 doubled, 2 unknown.
; ------------------------------------------------------
DETECT_LAYOUT
	LD	HL,PROM_BUF
	LD	A,(HL)
	INC	HL
	CP	(HL)
	JR	NZ,.NOT_DOUBLED
	INC	HL
	LD	A,(HL)
	INC	HL
	CP	(HL)
	JR	NZ,.NOT_DOUBLED
	INC	HL
	LD	A,(HL)
	INC	HL
	CP	(HL)
	JR	NZ,.NOT_DOUBLED
	LD	A,1
	RET
.NOT_DOUBLED
	LD	A,(PROM_BUF + 0x0E)
	CP	0x57
	JR	NZ,.UNK
	LD	A,(PROM_BUF + 0x0F)
	CP	0x57
	JR	NZ,.UNK
	XOR	A
	RET
.UNK
	LD	A,2
	RET

BUILD_DOUBLED_MAC
	LD	HL,PROM_BUF
	LD	DE,MAC_BUF
	LD	B,6
.LP
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	INC	HL
	INC	HL
	DJNZ	.LP
	RET

VALIDATE_MAC
	PUSH	BC,DE,HL
	LD	A,(LAYOUT)
	CP	1
	JR	NZ,.SRC_DIRECT
	LD	HL,MAC_BUF
	JR	.HAVE_SRC
.SRC_DIRECT
	LD	HL,PROM_BUF
.HAVE_SRC
	LD	A,(HL)
	AND	0x01
	JR	NZ,.BAD
	PUSH	HL
	LD	B,6
	XOR	A
.OR
	OR	(HL)
	INC	HL
	DJNZ	.OR
	POP	HL
	JR	Z,.BAD
	PUSH	HL
	LD	B,6
	LD	A,0xFF
.AN
	AND	(HL)
	INC	HL
	DJNZ	.AN
	POP	HL
	CP	0xFF
	JR	Z,.BAD
	OR	A
	POP	HL,DE,BC
	RET
.BAD
	POP	HL,DE,BC
	SCF
	RET

PRINT_REG_DUMP
	PRINT MSG_N5
	LD	HL,REG_NAMES
	LD	DE,@RTL.REG_SNAPSHOT
	LD	B,@RTL.REG_SNAPSHOT_LEN
.LP
	PUSH	BC,DE
.NCHR
	LD	A,(HL)
	INC	HL
	OR	A
	JR	Z,.NDONE
	CALL	PUTCHAR
	JR	.NCHR
.NDONE
	LD	A,'='
	CALL	PUTCHAR
	POP	DE,BC
	LD	A,(DE)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,' '
	CALL	PUTCHAR
	INC	DE
	DJNZ	.LP
	PRINT LINE_END
	RET

REG_NAMES
	DB "CR",0
	DB "ISR",0
	DB "DCR",0
	DB "RCR",0
	DB "TCR",0
	DB "IMR",0
	DB "PSTART",0
	DB "PSTOP",0
	DB "BNRY",0
	DB "CURR",0


; ------- messages -------
MSG_BANNER	DB "RTL8019AS NICINFO v0.1",0
MSG_N0		DB "[N0] Slot/Addr: ",0
MSG_N0_SEP	DB "/#",0
MSG_N1		DB "[N1] RESET ",0
MSG_OK		DB "OK",0
MSG_N2		DB "[N2] CR=",0
MSG_ISR_EQ	DB " ISR=",0
MSG_N3		DB "[N3] RTL ID=",0
MSG_PAREN_OPEN	DB " (",0
MSG_PAREN_CLOSE	DB ")",0
MSG_N4		DB "[N4] PROM MAC=",0
MSG_PROM_SIG	DB "PROM[0E..0F]=",0
MSG_LAYOUT	DB "PROM_LAYOUT=",0
MSG_DIRECT	DB "direct",0
MSG_DOUBLED	DB "doubled",0
MSG_UNKNOWN	DB "unknown",0
MSG_N5		DB "[N5] REG ",0
MSG_RESULT_OK	DB "RESULT OK",0
MSG_RESULT_FAIL	DB "RESULT FAIL",0
MSG_E_ID	DB "[E02] RTL ID mismatch",0
MSG_E_RESET	DB "[E01] RESET timeout",0
MSG_E_PROM	DB "[E03] PROM read failed",0
MSG_W_SIG	DB "[W01] PROM[0E..0F] != 57 57 (NE2000 signature mismatch)",0
MSG_W_NO_ID	DB "[W02] ID mismatch but MAC plausible -- continuing",0
MSG_SCAN_HDR	DB "Scan: ",0
MSG_SCAN_INDENT	DB "      ",0
MSG_SCAN_OK	DB "ok ",0
MSG_SCAN_NO	DB "-- ",0
MSG_E_SCAN	DB "[E04] no chip at default I/O base 0x300.",13,10
		DB "      If the Scan line shows another base responding, the card",13,10
		DB "      is jumpered there but the driver is currently hard-wired",13,10
		DB "      to 0x300 -- rejumper the card or wait for RTL_IOBASE",13,10
		DB "      override support.  Otherwise the card is missing.",0
LINE_END	DB 13,10,0

	ENDMODULE


; -------- libraries (placed after MAIN code/data) --------
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"


; Root-scope marker at end of emitted image. BSS labels live past
; this point so they never overlap with lib code or data.
NICINFO_IMAGE_END

; -------- runtime BSS (no bytes emitted) --------
	MODULE MAIN

PROM_BUF	EQU NICINFO_IMAGE_END
MAC_BUF		EQU PROM_BUF + 32
LAYOUT		EQU MAC_BUF + 6
NICINFO_BSS_END	EQU LAYOUT + 1

	ENDMODULE

	END MAIN.START
