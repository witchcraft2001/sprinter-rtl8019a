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
	CALL	@ISA.ISA_CLOSE		; all formatting/DSS calls require MMU3 restored

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

	; [N1] RESET
	PRINT MSG_N1
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.RESET
	JP	C,RESET_OPEN_FAIL

	; Mandatory: DCR=0x48 via the runtime base.
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_DCR_OFF),DCR_INIT
	LD	A,(IX+RTL_CR_OFF)
	LD	(CR_RAW),A
	LD	A,(IX+RTL_ISR_OFF)
	LD	(ISR_RAW),A

	; Capture ID, PROM and actual registers while ISA is open;
	; formatting starts only after the window is closed again.
	CALL	@RTL.PROBE_ID
	LD	HL,PROM_BUF
	CALL	@RTL.READ_PROM
	JP	C,PROM_OPEN_FAIL
	CALL	@RTL.SNAPSHOT_REGS
	CALL	CAPTURE_PAGE3
	CALL	@ISA.ISA_CLOSE
	PRINTLN MSG_OK

	; [N2] CR=xx ISR=xx
	PRINT MSG_N2
	LD	A,(CR_RAW)
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_ISR_EQ
	LD	A,(ISR_RAW)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END

	; [N3] RTL ID
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

	; Raw 32-byte PROM image.  Mandatory on a non-Realtek clone: the
	; NE2000 signature sits at 0E/0F only in the DIRECT layout (1C/1E
	; when doubled), and a wrong layout guess silently yields a wrong
	; MAC with no other symptom than a network that never answers.
	; Two rows of 16 bytes.
	LD	HL,PROM_BUF
	XOR	A
	CALL	PRINT_PROM_ROW
	LD	HL,PROM_BUF + 0x10
	LD	A,0x10
	CALL	PRINT_PROM_ROW

	; [N5] register snapshot captured before ISA_CLOSE.
	CALL	PRINT_REG_DUMP

	; [N6..N8] RTL8019AS board/EEPROM configuration.  This is
	; especially important on real hardware: an accidental full-duplex
	; setting or TP/CX fallback can lose frames even though TSR reports
	; PTX success.  Capture happened above while ISA was open; all
	; formatting is deliberately done with the system mapping restored.
	CALL	PRINT_PAGE3

	; -- determine RESULT --
	LD	A,(@RTL.ID0_RAW)
	CP	RTL_ID0_VAL
	JR	NZ,ID_BAD
	LD	A,(@RTL.ID1_RAW)
	CP	RTL_ID1_VAL
	JR	NZ,ID_BAD

	; ID OK -- check signature.  Its position depends on the layout:
	; adjacent bytes 0E/0F when direct, every other byte 1C/1E when
	; the PROM image comes back doubled.
	LD	HL,PROM_BUF + 0x0E
	LD	DE,1
	LD	A,(LAYOUT)
	CP	1
	JR	NZ,.SIG_AT
	LD	HL,PROM_BUF + 0x1C
	LD	E,2
.SIG_AT
	LD	A,(HL)
	CP	0x57
	JR	NZ,SIG_WARN
	ADD	HL,DE
	LD	A,(HL)
	CP	0x57
	JR	NZ,SIG_WARN

	PRINTLN MSG_RESULT_OK
	DSS_RETURN EX_OK

SIG_WARN
	PRINTLN MSG_W_SIG
	PRINTLN MSG_RESULT_OK
	DSS_RETURN EX_OK

ID_BAD
	PRINTLN MSG_E_ID
	CALL	VALIDATE_MAC
	JR	C,NO_HW
	PRINTLN MSG_W_NO_ID
	PRINTLN MSG_RESULT_OK
	DSS_RETURN EX_OK

NO_HW
	PRINTLN MSG_RESULT_FAIL
	DSS_RETURN EX_NO_HW

RESET_FAIL
	PRINTLN MSG_E_RESET
	PRINTLN MSG_RESULT_FAIL
	DSS_RETURN EX_NIC_ERR

PROM_FAIL
	PRINTLN MSG_E_PROM
	PRINTLN MSG_RESULT_FAIL
	DSS_RETURN EX_NIC_ERR

SCAN_FAIL
	; The default base 0x300 did not respond.  Either the card
	; is missing entirely or it is jumpered to one of the
	; alternates -- which one (if any) the user can read off the
	; "Scan:" line above.  The driver is currently hard-wired to
	; 0x300, so we cannot continue here either way.
	PRINTLN MSG_E_SCAN
	PRINTLN MSG_RESULT_FAIL
	DSS_RETURN EX_NO_HW

RESET_OPEN_FAIL
	CALL	@ISA.ISA_CLOSE
	JP	RESET_FAIL

PROM_OPEN_FAIL
	CALL	@RTL.SNAPSHOT_REGS
	CALL	@ISA.ISA_CLOSE
	JP	PROM_FAIL


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
; PRINT_PROM_ROW: one 16-byte row of the raw PROM image as
; "PROM oo: xx xx ...".
; In: HL = source bytes, A = offset printed in the label.
; Trashes AF, BC, DE, HL (the PRINT macro clobbers HL, so the
; caller reloads it for the second row).
; ------------------------------------------------------
PRINT_PROM_ROW
	PUSH	HL
	PUSH	AF
	PRINT MSG_PROM_ROW
	POP	AF
	CALL	@UTIL.PRINT_HEX_A
	LD	A,':'
	CALL	PUTCHAR
	POP	HL
	LD	B,16
.LP
	LD	A,' '
	PUSH	HL
	CALL	PUTCHAR			; preserves AF/BC but not HL
	POP	HL
	LD	A,(HL)
	INC	HL
	CALL	@UTIL.PRINT_HEX_A	; preserves everything
	DJNZ	.LP
	PRINT LINE_END
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


; ------------------------------------------------------
; CAPTURE_PAGE3: read the RTL8019AS-specific configuration
; registers.  Caller has the ISA window open.  No DSS/BIOS calls.
; The common driver remains in normal page 0/start state on return.
; ------------------------------------------------------
CAPTURE_PAGE3
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_CR_OFF),CR_PAGE3_START
	LD	A,(IX+RTL_9346CR_OFF)
	LD	(P3_9346),A
	LD	A,(IX+RTL_CONFIG0_OFF)
	LD	(P3_CFG0),A
	LD	A,(IX+RTL_CONFIG1_OFF)
	LD	(P3_CFG1),A
	LD	A,(IX+RTL_CONFIG2_OFF)
	LD	(P3_CFG2),A
	LD	A,(IX+RTL_CONFIG3_OFF)
	LD	(P3_CFG3),A
	LD	A,(IX+RTL_CONFIG4_OFF)
	LD	(P3_CFG4),A
	LD	A,(IX+RTL_INTR_OFF)
	LD	(P3_INTR),A
	LD	(IX+RTL_CR_OFF),CR_PAGE0_START
	RET


; ------------------------------------------------------
; PRINT_PAGE3: print raw CONFIG values and a compact decode.
; A full-duplex or non-UTP selection is a warning, not a fatal
; NICINFO result: it may be intentional on another board/network.
; ------------------------------------------------------
PRINT_PAGE3
	PRINT	MSG_N6
	LD	A,(P3_9346)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	MSG_CFG0
	LD	A,(P3_CFG0)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	MSG_CFG1
	LD	A,(P3_CFG1)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	MSG_CFG2
	LD	A,(P3_CFG2)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	MSG_CFG3
	LD	A,(P3_CFG3)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	MSG_CFG4
	LD	A,(P3_CFG4)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	MSG_INTR
	LD	A,(P3_INTR)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	LINE_END

	PRINT	MSG_N7
	LD	A,(P3_CFG0)
	AND	CFG0_JP
	JR	NZ,.MODE_JUMPER
	LD	A,(P3_CFG3)
	AND	CFG3_PNP
	JR	NZ,.MODE_PNP
	PRINT	MSG_MODE_RT
	JR	.MODE_DONE
.MODE_JUMPER
	PRINT	MSG_MODE_JUMPER
	JR	.MODE_DONE
.MODE_PNP
	PRINT	MSG_MODE_PNP
.MODE_DONE
	PRINT	MSG_MEDIA
	LD	A,(P3_CFG0)
	AND	CFG0_AUI
	JR	NZ,.MEDIA_AUI
	LD	A,(P3_CFG0)
	AND	CFG0_BNC
	JR	NZ,.MEDIA_BNC
	PRINT	MSG_MEDIA_UTP
	JR	.MEDIA_DONE
.MEDIA_AUI
	PRINT	MSG_MEDIA_AUI
	JR	.MEDIA_DONE
.MEDIA_BNC
	PRINT	MSG_MEDIA_BNC
.MEDIA_DONE
	PRINT	MSG_PL
	LD	A,(P3_CFG2)
	AND	CFG2_PL_MASK
	CP	CFG2_PL_10BT_NLT
	JR	Z,.PL_UTP_NLT
	CP	CFG2_PL_10B5
	JR	Z,.PL_AUI
	CP	CFG2_PL_10B2
	JR	Z,.PL_BNC
	PRINT	MSG_PL_AUTO
	JR	.PL_DONE
.PL_UTP_NLT
	PRINT	MSG_PL_UTP_NLT
	JR	.PL_DONE
.PL_AUI
	PRINT	MSG_PL_AUI
	JR	.PL_DONE
.PL_BNC
	PRINT	MSG_PL_BNC
.PL_DONE
	PRINT	MSG_DUPLEX
	LD	A,(P3_CFG3)
	AND	CFG3_FUDUP
	JR	Z,.DUPLEX_HALF
	PRINT	MSG_DUPLEX_FULL
	JR	.DUPLEX_DONE
.DUPLEX_HALF
	PRINT	MSG_DUPLEX_HALF
.DUPLEX_DONE
	PRINT	LINE_END

	PRINT	MSG_N8
	LD	A,(P3_CFG3)
	AND	CFG3_PWRDN
	JR	NZ,.POWER_DOWN
	LD	A,(P3_CFG3)
	AND	CFG3_SLEEP
	JR	NZ,.POWER_SLEEP
	PRINT	MSG_POWER_NORMAL
	JR	.POWER_DONE
.POWER_DOWN
	PRINT	MSG_POWER_DOWN
	JR	.POWER_DONE
.POWER_SLEEP
	PRINT	MSG_POWER_SLEEP
.POWER_DONE
	PRINT	MSG_ACTIVEB
	LD	A,(P3_CFG3)
	AND	CFG3_ACTIVEB
	CALL	PRINT_BOOL
	PRINT	MSG_IRQEN
	LD	A,(P3_CFG1)
	AND	CFG1_IRQEN
	CALL	PRINT_BOOL
	PRINT	MSG_IOMS
	LD	A,(P3_CFG4)
	AND	CFG4_IOMS
	CALL	PRINT_BOOL
	PRINT	LINE_END

	LD	A,(P3_CFG3)
	AND	CFG3_FUDUP
	JR	Z,.NO_FUDUP_WARN
	PRINTLN MSG_W_FUDUP
.NO_FUDUP_WARN
	LD	A,(P3_CFG0)
	AND	CFG0_AUI | CFG0_BNC
	JR	Z,.NO_MEDIA_WARN
	PRINTLN MSG_W_MEDIA
.NO_MEDIA_WARN
	LD	A,(P3_CFG3)
	AND	CFG3_PWRDN
	RET	Z
	PRINTLN MSG_W_PWRDN
	RET


; A=0 -> '0', A!=0 -> '1'.
PRINT_BOOL
	OR	A
	LD	A,'0'
	JR	Z,.OUT
	INC	A
.OUT
	JP	PUTCHAR

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
MSG_BANNER	DB "RTL8019AS NICINFO v",PACKAGE_VERSION,0
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
MSG_PROM_ROW	DB "PROM ",0
MSG_DIRECT	DB "direct",0
MSG_DOUBLED	DB "doubled",0
MSG_UNKNOWN	DB "unknown",0
MSG_N5		DB "[N5] REG RAW ",0
MSG_N6		DB "[N6] P3 9346=",0
MSG_CFG0	DB " C0=",0
MSG_CFG1	DB " C1=",0
MSG_CFG2	DB " C2=",0
MSG_CFG3	DB " C3=",0
MSG_CFG4	DB " C4=",0
MSG_INTR	DB " INTR=",0
MSG_N7		DB "[N7] MODE=",0
MSG_MODE_JUMPER DB "JUMPER",0
MSG_MODE_PNP	DB "PNP",0
MSG_MODE_RT	DB "RT-JUMPERLESS",0
MSG_MEDIA	DB " MEDIA=",0
MSG_MEDIA_UTP	DB "UTP",0
MSG_MEDIA_AUI	DB "AUI",0
MSG_MEDIA_BNC	DB "BNC",0
MSG_PL		DB " PL=",0
MSG_PL_AUTO	DB "AUTO",0
MSG_PL_UTP_NLT DB "UTP-NOLINK",0
MSG_PL_AUI	DB "AUI",0
MSG_PL_BNC	DB "BNC",0
MSG_DUPLEX	DB " DUPLEX=",0
MSG_DUPLEX_HALF DB "HALF",0
MSG_DUPLEX_FULL DB "FULL",0
MSG_N8		DB "[N8] POWER=",0
MSG_POWER_NORMAL DB "NORMAL",0
MSG_POWER_SLEEP DB "SLEEP",0
MSG_POWER_DOWN DB "DOWN",0
MSG_ACTIVEB	DB " ACTIVEB=",0
MSG_IRQEN	DB " IRQEN=",0
MSG_IOMS	DB " IOMS=",0
MSG_RESULT_OK	DB "RESULT OK",0
MSG_RESULT_FAIL	DB "RESULT FAIL",0
MSG_E_ID	DB "[E02] RTL ID mismatch",0
MSG_E_RESET	DB "[E01] RESET timeout",0
MSG_E_PROM	DB "[E03] PROM read failed",0
MSG_W_SIG	DB "[W01] PROM signature != 57 57 (NE2000 mismatch)",0
MSG_W_NO_ID	DB "[W02] ID mismatch but MAC plausible -- continuing",0
MSG_W_FUDUP	DB "[W03] FUDUP=1: peer switch port must be forced 10M/full",0
MSG_W_MEDIA	DB "[W04] selected medium is not UTP; check PL/link/cable",0
MSG_W_PWRDN	DB "[W05] PWRDN=1: Ethernet transceiver is disabled",0
MSG_SCAN_HDR	DB "Scan: ",0
MSG_SCAN_INDENT	DB "      ",0
MSG_SCAN_OK	DB "ok ",0
MSG_SCAN_NO	DB "-- ",0
MSG_E_SCAN	DB "[E04] no RTL8019AS responded.",13,10
		DB "      Scanned all 16 I/O bases (0x200..0x3E0) on both ISA",13,10
		DB "      slots; none answered the presence probe.  Set NET_RTL_HW",13,10
		DB "      to force a slot/base, or check the card seating, 5V and",13,10
		DB "      ISA bus timing.  If IFUP/PING find the card moments later,",13,10
		DB "      the cold presence probe is marginal -- retest and report.",0
LINE_END	DB 13,10,0

	ENDMODULE


; -------- libraries (placed after MAIN code/data) --------
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"


; Root-scope marker at end of emitted image (size diagnostics only).
NICINFO_IMAGE_END

; -------- runtime BSS (no bytes emitted) --------
	MODULE MAIN

; Do not place writable state immediately after this small EXE.  DSS uses
; memory in the 0x9xxx area while formatting output on real hardware; the
; old P3_CFG3 at 0x910F changed from raw 0x20 to a value with bit 0x40 set
; between two PRINT calls and falsely reported full duplex.  APP_BSS_BASE is
; the project-wide reserved per-app region and remains below the ISA window.
PROM_BUF	EQU APP_BSS_BASE
MAC_BUF		EQU PROM_BUF + 32
LAYOUT		EQU MAC_BUF + 6
CR_RAW		EQU LAYOUT + 1
ISR_RAW		EQU CR_RAW + 1
P3_9346		EQU ISR_RAW + 1
P3_CFG0		EQU P3_9346 + 1
P3_CFG1		EQU P3_CFG0 + 1
P3_CFG2		EQU P3_CFG1 + 1
P3_CFG3		EQU P3_CFG2 + 1
P3_CFG4		EQU P3_CFG3 + 1
P3_INTR		EQU P3_CFG4 + 1
NICINFO_BSS_END	EQU P3_INTR + 1

	ENDMODULE

	END MAIN.START
