; ======================================================
; NICMODE.EXE - inspect or explicitly change RTL8019AS duplex mode.
;
; CONFIG3.FUDUP is read-only on RTL8019AS and is loaded from byte 2 of
; the 93C46.  Therefore a persistent half/full-duplex change requires a
; verified read-modify-write of EEPROM word 1.  The CONFIG3 byte position
; in that word is detected from the active register, not assumed.
;
; Usage:
;   NICMODE             show EEPROM word 1 and active duplex mode
;   NICMODE HALF -y     clear CONFIG3.FUDUP in EEPROM
;   NICMODE FULL -y     set CONFIG3.FUDUP in EEPROM
;   NICMODE /?          help
;
; No write is possible without the exact HALF/FULL command and -y.
; Only bit 6 of CONFIG3 is changed; CONFIG4 and every other EEPROM bit
; remain untouched.  The word is read twice before the write and verified
; afterwards.  EEPROM write waits run with the ISA window closed.
; ======================================================

EXE_VERSION	EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "memmap.inc"
	INCLUDE "rtl8019.inc"

	DEFINE USE_CMDL
	DEFINE USE_UTIL_EXIT

NICMODE_EX_USAGE	EQU 1
NICMODE_EX_NO_NIC	EQU 2
NICMODE_EX_NIC_ERR	EQU 3

MODE_SHOW	EQU 0
MODE_HALF	EQU 1
MODE_FULL	EQU 2
EEPROM_CFG_WORD EQU 1			; EEPROM bytes 2 and 3

	MODULE MAIN

	ORG 0x4100

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0100
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START
	DW START
	DW 0xBFFF
	DS 234,0

	ORG 0x4200

START
	LD	(CMDL_SOURCE_PTR),IX	; PSP is supplied by DSS in IX
	PRINTLN MSG_BANNER

	CALL	@CMDL.PARSE
	CALL	@CMDL.IS_HELP
	JP	NC,SHOW_HELP
	CALL	PARSE_MODE
	JP	C,USAGE_ERROR

	; Locate the card.  INIT_BASE leaves the ISA window open.
	LD	A,1
	LD	(@ISA.ISA_SLOT),A
	CALL	@RTL.INIT_BASE
	JP	C,NO_NIC
	CALL	@RTL.PROBE_ID
	JP	C,NO_ID_OPEN

	; Read the EEPROM word twice before trusting it.  READ_WORD leaves the
	; chip stopped on page 0, which is fine for this configuration utility.
	LD	A,EEPROM_CFG_WORD
	CALL	@RTL_EEPROM.READ_WORD
	LD	(WORD_ORIG),HL
	LD	A,EEPROM_CFG_WORD
	CALL	@RTL_EEPROM.READ_WORD
	LD	(WORD_SECOND),HL
	CALL	READ_ACTIVE_CFG3
	LD	(ACTIVE_CFG3),A
	CALL	@ISA.ISA_CLOSE

	CALL	PRINT_LOCATION
	PRINT	MSG_N1
	LD	A,(@RTL.ID0_RAW)
	CALL	PUTCHAR
	LD	A,(@RTL.ID1_RAW)
	CALL	PUTCHAR
	PRINT	LINE_END
	PRINT	MSG_N2
	LD	HL,(WORD_ORIG)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_READ2
	LD	HL,(WORD_SECOND)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	LINE_END
	CALL	PRINT_ACTIVE

	; Reject a floating/unstable EEPROM before any possible write.
	LD	HL,(WORD_ORIG)
	LD	DE,(WORD_SECOND)
	OR	A
	SBC	HL,DE
	JP	NZ,EEPROM_UNSTABLE
	LD	HL,(WORD_ORIG)
	LD	A,H
	CP	0xFF
	JR	NZ,.NOT_FF
	LD	A,L
	CP	0xFF
	JP	Z,EEPROM_INVALID
.NOT_FF
	; FUDUP + LEDS1:0 are EEPROM-loaded in jumper/RT modes.  RTL8019AS
	; EEPROM images in the field do not all describe the byte order the same
	; way, so identify CONFIG3 by matching bits 6:4 against active CONFIG3.
	; Exactly one byte must match; no match or two matches forbids a write.
	CALL	DETECT_CFG3_BYTE
	JP	C,EEPROM_CFG_MISMATCH
	CALL	PRINT_EEPROM_CFG3

	LD	A,(REQUESTED_MODE)
	OR	A
	JP	Z,SHOW_DONE

	; Compute the exact one-bit change in the byte identified as CONFIG3.
	LD	HL,(WORD_ORIG)
	LD	A,(REQUESTED_MODE)
	CP	MODE_HALF
	JR	NZ,.WANT_FULL
	LD	A,(CFG3_MAP)
	OR	A
	JR	NZ,.HALF_LOW
	RES	6,H
	JR	.NEW_READY
.HALF_LOW
	RES	6,L
	JR	.NEW_READY
.WANT_FULL
	LD	A,(CFG3_MAP)
	OR	A
	JR	NZ,.FULL_LOW
	SET	6,H
	JR	.NEW_READY
.FULL_LOW
	SET	6,L
.NEW_READY
	LD	(WORD_NEW),HL
	LD	DE,(WORD_ORIG)
	OR	A
	SBC	HL,DE
	JP	Z,ALREADY_SET

	LD	A,(CONFIRMED)
	OR	A
	JP	Z,CONFIRM_REQUIRED

	PRINT	MSG_W_WRITE
	LD	HL,(WORD_ORIG)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	MSG_ARROW
	LD	HL,(WORD_NEW)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	LINE_END

	; Start one-word programming, close ISA for the EEPROM's internal
	; write cycle, then reopen only for EWDS and verification.
	CALL	@ISA.ISA_OPEN
	LD	A,EEPROM_CFG_WORD
	LD	HL,(WORD_NEW)
	CALL	@RTL_EEPROM.WRITE_WORD
	CALL	@ISA.ISA_CLOSE
	LD	HL,20
	CALL	@UTIL.DELAY_MS

	CALL	@ISA.ISA_OPEN
	CALL	@RTL_EEPROM.WRITE_DISABLE
	LD	A,EEPROM_CFG_WORD
	CALL	@RTL_EEPROM.READ_WORD
	LD	(WORD_VERIFY),HL
	CALL	@ISA.ISA_CLOSE

	PRINT	MSG_N5
	LD	HL,(WORD_VERIFY)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT	LINE_END
	LD	HL,(WORD_VERIFY)
	LD	DE,(WORD_NEW)
	OR	A
	SBC	HL,DE
	JP	NZ,VERIFY_FAILED

	; Apply the verified value through the documented 9346 auto-load mode.
	CALL	@ISA.ISA_OPEN
	CALL	@RTL_EEPROM.AUTOLOAD
	CALL	@ISA.ISA_CLOSE
	LD	HL,10
	CALL	@UTIL.DELAY_MS
	CALL	@ISA.ISA_OPEN
	CALL	READ_ACTIVE_CFG3
	LD	(ACTIVE_CFG3),A
	CALL	@ISA.ISA_CLOSE
	PRINT	MSG_N6
	LD	A,(ACTIVE_CFG3)
	CALL	@UTIL.PRINT_HEX_A
	CALL	PRINT_DUPLEX_ONLY
	PRINT	LINE_END
	CALL	ACTIVE_MATCHES_REQUEST
	JP	NZ,AUTOLOAD_FAILED
	PRINTLN MSG_REINIT
	JP	SUCCESS


; ------------------------------------------------------
; Command-line handling.
; ------------------------------------------------------
PARSE_MODE
	XOR	A
	LD	(REQUESTED_MODE),A
	LD	(CONFIRMED),A
	LD	A,'y'
	CALL	@CMDL.HAS_FLAG
	JR	C,.NO_Y
	LD	A,1
	LD	(CONFIRMED),A
.NO_Y
	LD	B,0
	CALL	@CMDL.GET_POSITIONAL
	JR	C,.NO_MODE
	LD	DE,TOK_HALF
	CALL	STR_EQ_CI
	JR	Z,.HALF
	LD	DE,TOK_FULL
	CALL	STR_EQ_CI
	JR	Z,.FULL
	SCF
	RET


.HALF
	LD	A,MODE_HALF
	JR	.SET
.FULL
	LD	A,MODE_FULL
.SET
	LD	(REQUESTED_MODE),A
	; A second positional is always an error.
	LD	B,1
	CALL	@CMDL.GET_POSITIONAL
	JR	NC,.BAD
	OR	A
	RET
.NO_MODE
	LD	A,(CONFIRMED)
	OR	A
	JR	NZ,.BAD			; bare -y is not meaningful
	OR	A
	RET
.BAD
	SCF
	RET


; Identify which byte of EEPROM word 1 is CONFIG3.
; CFG3_MAP=0 -> high byte, CFG3_MAP=1 -> low byte.
; Exactly one byte must have bits 6:4 equal to active CONFIG3 bits 6:4.
; Out: CF=0 unique match and EEPROM_CFG3 saved; CF=1 ambiguous/no match.
DETECT_CFG3_BYTE
	LD	A,(ACTIVE_CFG3)
	AND	0x70
	LD	B,A
	LD	HL,(WORD_ORIG)
	LD	A,H
	AND	0x70
	CP	B
	JR	NZ,.HIGH_NO
	LD	A,L
	AND	0x70
	CP	B
	JR	Z,.BAD			; both bytes match -- ambiguous
	XOR	A
	LD	(CFG3_MAP),A
	LD	A,H
	LD	(EEPROM_CFG3),A
	OR	A
	RET
.HIGH_NO
	LD	A,L
	AND	0x70
	CP	B
	JR	NZ,.BAD
	LD	A,1
	LD	(CFG3_MAP),A
	LD	A,L
	LD	(EEPROM_CFG3),A
	OR	A
	RET
.BAD
	SCF
	RET


; HL token, DE uppercase ASCIIZ.  ZF=1 if equal, case-insensitive.
STR_EQ_CI
	PUSH	HL,DE
.LP
	LD	A,(HL)
	CP	'a'
	JR	C,.UP
	CP	'z'+1
	JR	NC,.UP
	SUB	'a'-'A'
.UP
	LD	B,A
	LD	A,(DE)
	CP	B
	JR	NZ,.NE
	OR	A
	JR	Z,.EQ
	INC	HL
	INC	DE
	JR	.LP
.NE
	OR	1				; ZF=0
	POP	DE,HL
	RET
.EQ
	XOR	A				; ZF=1
	POP	DE,HL
	RET


; Caller has ISA open.  Returns active CONFIG3 in A and restores page 0.
READ_ACTIVE_CFG3
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_CR_OFF),CR_PAGE3_STOP
	LD	A,(IX+RTL_CONFIG3_OFF)
	PUSH	AF
	LD	(IX+RTL_CR_OFF),CR_PAGE0_STOP
	POP	AF
	RET


; ------------------------------------------------------
; Output helpers.
; ------------------------------------------------------
PRINT_LOCATION
	PRINT	MSG_N0
	LD	A,(@ISA.ISA_SLOT)
	ADD	A,'0'
	CALL	PUTCHAR
	PRINT	MSG_N0_SEP
	LD	HL,(RTL_BASE_PTR)
	LD	A,H
	SUB	HIGH ISA_BASE_A
	AND	0x0F
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
	PRINT	LINE_END
	RET

PUTCHAR
	PUSH	BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC
	RET

PRINT_HEX_NIBBLE
	AND	0x0F
	ADD	A,'0'
	CP	'9'+1
	JR	C,.OUT
	ADD	A,'A'-'0'-10
.OUT
	JP	PUTCHAR

PRINT_ACTIVE
	PRINT	MSG_N3
	LD	A,(ACTIVE_CFG3)
	CALL	@UTIL.PRINT_HEX_A
	CALL	PRINT_DUPLEX_ONLY
	PRINT	LINE_END
	RET

PRINT_EEPROM_CFG3
	PRINT	MSG_N4
	LD	A,(EEPROM_CFG3)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	MSG_MAP
	LD	A,(CFG3_MAP)
	OR	A
	LD	HL,MSG_HIGH
	JR	Z,.OUT
	LD	HL,MSG_LOW
.OUT
	LD	C,DSS_PCHARS
	RST	DSS
	PRINT	LINE_END
	RET

PRINT_DUPLEX_ONLY
	PRINT	MSG_DUPLEX
	LD	A,(ACTIVE_CFG3)
	AND	CFG3_FUDUP
	LD	HL,MSG_HALF
	JR	Z,.OUT
	LD	HL,MSG_FULL
.OUT
	LD	C,DSS_PCHARS
	RST	DSS
	RET

ACTIVE_MATCHES_REQUEST
	LD	A,(REQUESTED_MODE)
	CP	MODE_HALF
	JR	NZ,.FULL
	LD	A,(ACTIVE_CFG3)
	AND	CFG3_FUDUP		; HALF: Z only if bit is clear
	RET
.FULL
	LD	A,(ACTIVE_CFG3)
	AND	CFG3_FUDUP
	OR	A
	JR	Z,.NO
	XOR	A				; FULL and bit set -> Z
	RET
.NO
	OR	1				; FULL and bit clear -> NZ
	RET


ALREADY_SET
	PRINTLN MSG_ALREADY
	JP	SUCCESS

SHOW_DONE
	LD	A,(ACTIVE_CFG3)
	AND	CFG3_FUDUP
	JP	Z,SUCCESS
	PRINTLN MSG_W_FULL
	JP	SUCCESS

CONFIRM_REQUIRED
	PRINTLN MSG_E_CONFIRM
	LD	B,NICMODE_EX_USAGE
	JP	FAIL_EXIT

EEPROM_UNSTABLE
	PRINTLN MSG_E_UNSTABLE
	LD	B,NICMODE_EX_NIC_ERR
	JP	FAIL_EXIT

EEPROM_INVALID
	PRINTLN MSG_E_INVALID
	LD	B,NICMODE_EX_NIC_ERR
	JP	FAIL_EXIT

EEPROM_CFG_MISMATCH
	PRINTLN MSG_E_CFG_MISMATCH
	LD	B,NICMODE_EX_NIC_ERR
	JP	FAIL_EXIT

VERIFY_FAILED
	PRINTLN MSG_E_VERIFY
	LD	B,NICMODE_EX_NIC_ERR
	JP	FAIL_EXIT

AUTOLOAD_FAILED
	PRINTLN MSG_E_AUTOLOAD
	LD	B,NICMODE_EX_NIC_ERR
	JP	FAIL_EXIT

NO_ID_OPEN
	CALL	@ISA.ISA_CLOSE
NO_NIC
	PRINTLN MSG_E_NIC
	LD	B,NICMODE_EX_NO_NIC
	JP	FAIL_EXIT

USAGE_ERROR
	PRINTLN MSG_E_USAGE
	LD	B,NICMODE_EX_USAGE
	JP	FAIL_EXIT

SHOW_HELP
	PRINT	MSG_HELP
	JP	@UTIL.EXIT_OK

SUCCESS
	JP	@UTIL.EXIT_OK

FAIL_EXIT
	JP	@UTIL.EXIT_FAIL


TOK_HALF	DB "HALF",0
TOK_FULL	DB "FULL",0

MSG_BANNER	DB "RTL8019AS NICMODE v",PACKAGE_VERSION,0
MSG_N0		DB "[N0] Slot/Addr: ",0
MSG_N0_SEP	DB "/#",0
MSG_N1		DB "[N1] RTL ID=",0
MSG_N2		DB "[N2] EEPROM W1=",0
MSG_READ2	DB " READ2=",0
MSG_N3		DB "[N3] CONFIG3=",0
MSG_N4		DB "[N4] EEPROM CONFIG3=",0
MSG_MAP		DB " MAP=",0
MSG_HIGH	DB "HIGH",0
MSG_LOW		DB "LOW",0
MSG_N5		DB "[N5] VERIFY W1=",0
MSG_N6		DB "[N6] AUTOLOAD CONFIG3=",0
MSG_DUPLEX	DB " DUPLEX=",0
MSG_HALF	DB "HALF",0
MSG_FULL	DB "FULL",0
MSG_W_WRITE	DB "[W10] EEPROM WRITE W1 ",0
MSG_ARROW	DB "->",0
MSG_W_FULL	DB "[W03] FUDUP=1: force peer 10M/full or run NICMODE HALF -y",0
MSG_ALREADY	DB "[N5] requested duplex already active; EEPROM unchanged",0
MSG_REINIT	DB "[N7] Run IFUP again before network utilities",0
MSG_E_CONFIRM	DB "[E10] EEPROM change requires explicit -y",13,10
		DB "      Use NICMODE HALF -y (recommended for auto-negotiating peers).",0
MSG_E_UNSTABLE	DB "[E11] EEPROM read is unstable; no write performed",0
MSG_E_INVALID	DB "[E12] EEPROM returned FFFF; no write performed",0
MSG_E_CFG_MISMATCH DB "[E13] EEPROM CONFIG3 byte is missing/ambiguous; no write",0
MSG_E_VERIFY	DB "[E14] EEPROM verify mismatch; power off and inspect card",0
MSG_E_AUTOLOAD	DB "[E15] EEPROM verified but auto-load did not apply; power cycle",0
MSG_E_NIC	DB "[E01] RTL8019AS not detected",0
MSG_E_USAGE	DB "[E02] usage error; run NICMODE /?",0
MSG_HELP
	DB "Usage:",13,10
	DB "  NICMODE             show active/EEPROM duplex mode",13,10
	DB "  NICMODE HALF -y     persist half-duplex (normal switch/router)",13,10
	DB "  NICMODE FULL -y     persist full-duplex (peer forced 10M/full)",13,10
	DB "  NICMODE /?          help",13,10,13,10
	DB "Only CONFIG3.FUDUP is changed. EEPROM is read twice and verified.",13,10
	DB "Do not use FULL with an auto-negotiating peer: 10BASE-T parallel",13,10
	DB "detection selects half-duplex on the peer and causes frame loss.",13,10,0
LINE_END	DB 13,10,0

	ENDMODULE


	INCLUDE "cmdline_lib.asm"
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"
	INCLUDE "rtl8019_eeprom.asm"

NICMODE_IMAGE_END

; Runtime BSS: zero bytes are not emitted into the EXE.
REQUESTED_MODE	EQU APP_BSS_BASE
CONFIRMED	EQU APP_BSS_BASE + 1
ACTIVE_CFG3	EQU APP_BSS_BASE + 2
CFG3_MAP	EQU APP_BSS_BASE + 3	; 0=high byte, 1=low byte
WORD_ORIG	EQU APP_BSS_BASE + 4
WORD_SECOND	EQU APP_BSS_BASE + 6
WORD_NEW	EQU APP_BSS_BASE + 8
WORD_VERIFY	EQU APP_BSS_BASE + 10
EEPROM_CFG3	EQU APP_BSS_BASE + 12

	END MAIN.START
