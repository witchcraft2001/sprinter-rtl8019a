; ======================================================
; NICEEP.EXE - dump the 93C46 configuration EEPROM of a
; jumperless NE2000 card.
;
; READ ONLY.  Nothing here writes to the EEPROM; the only chip
; writes are to CR and to the EEPROM control register, and they
; are the ones the bit-bang protocol itself requires.
;
; The protocol was taken from the vendor DOS utility LANSET.EXE
; (UMC UM9003x), unpacked and disassembled -- not guessed from a
; generic 93C46 description.  Its ReadWord is:
;
;   CR = 0xE1                       ; page 3, stop, abort DMA
;   shadow = IN(ctrl) | 0x80        ; EEPROM access enable
;   OUT(ctrl, shadow)
;   OUT(ctrl, shadow | EECS)        ; chip select high
;   send 9 bits of (0x180 | addr), MSB first
;   dummy = IN(ctrl) & EEDO         ; MUST read 0, else fail
;   read 16 bits, MSB first
;   OUT(ctrl, shadow)               ; chip select low
;   OUT(ctrl, shadow & 0x7F)        ; access disable
;   CR = 0x21
;
; The dummy-bit test is LANSET's own and is kept: it is a free
; end-to-end check that the bit-bang is really talking to a 93C46
; rather than reading back a floating bus.
;
; Control register location differs per controller:
;   Realtek RTL8019AS  page 3, offset 0x01 (9346CR, datasheet)
;   UMC UM9003x        page 3, offset 0x07 (verified in LANSET)
; The 8019 ID selects between them.
; ======================================================

EXE_VERSION		EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "rtl8019.inc"

	DEFINE USE_UTIL_EXIT_NO_NIC	; fast-fail "no NIC" path

; EEPROM control register bits (identical on both layouts).
EEP_EN		EQU 0x80		; EEPROM access enable
EEP_CS		EQU 0x08		; EECS  chip select
EEP_SK		EQU 0x04		; EESK  clock
EEP_DI		EQU 0x02		; EEDI  data in  (host -> chip)
EEP_DO		EQU 0x01		; EEDO  data out (chip -> host)

EEP_OFF_RTL	EQU 0x01		; page-3 9346CR on RTL8019AS
EEP_OFF_UMC	EQU 0x07		; page-3 control on UM9003x

EEP_WORDS	EQU 64			; 93C46 = 64 x 16 bit
EEP_PER_LINE	EQU 8

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

	LD	A,1
	LD	(@ISA.ISA_SLOT),A
	CALL	@RTL.INIT_BASE
	JP	C,@UTIL.EXIT_NO_NIC
	; Capture the ID while the window is open, then close: nothing
	; below may call DSS with MMU3 still mapped to the ISA card.
	CALL	@RTL.PROBE_ID
	CALL	@ISA.ISA_CLOSE

	; [P0] Slot/Addr: N/#HHH
	PRINT MSG_P0
	LD	A,(@ISA.ISA_SLOT)
	ADD	A,'0'
	CALL	PUTCHAR
	PRINT MSG_SLASH
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
	PRINT LINE_END

	; [P1] pick the control register from the 8019 ID.
	PRINT MSG_P1
	LD	A,(@RTL.ID0_RAW)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,' '
	CALL	PUTCHAR
	LD	A,(@RTL.ID1_RAW)
	CALL	@UTIL.PRINT_HEX_A
	LD	DE,EEP_OFF_UMC
	LD	A,(@RTL.ID0_RAW)
	CP	RTL_ID0_VAL
	JR	NZ,.NOT_RTL
	LD	A,(@RTL.ID1_RAW)
	CP	RTL_ID1_VAL
	JR	NZ,.NOT_RTL
	LD	DE,EEP_OFF_RTL
.NOT_RTL
	LD	(EEP_OFF),DE
	PRINT MSG_CTRL
	; Reload from memory: the PRINT macro ends in RST DSS, and a DSS
	; call is not documented to preserve DE.
	LD	A,(EEP_OFF)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,(EEP_OFF)
	CP	EEP_OFF_RTL
	JR	NZ,.CLONE
	PRINT MSG_LAY_RTL
	JR	.LAY_DONE
.CLONE
	PRINT MSG_LAY_UMC
.LAY_DONE
	PRINT LINE_END

	; -- read all 64 words --
	; One ISA_OPEN/ISA_CLOSE bracket PER WORD.  A whole-dump bracket
	; would hold MMU3 on the card with interrupts off for ~5000 chip
	; accesses, far longer than a 50 Hz tick; each word is a complete,
	; self-contained 93C46 transaction, so splitting is free.
	LD	HL,EEP_BUF
	LD	(DST_PTR),HL
	XOR	A
	LD	(WORD_IDX),A
.READ_LP
	CALL	@ISA.ISA_OPEN
	LD	A,(WORD_IDX)
	CALL	EEP_READ_WORD		; DE = value; CF=1 protocol error
	CALL	@ISA.ISA_CLOSE
	JP	C,EEP_FAIL
	LD	HL,(DST_PTR)
	LD	(HL),E			; low byte first: word N covers
	INC	HL			; PROM bytes 2N (low) and 2N+1 (high)
	LD	(HL),D
	INC	HL
	LD	(DST_PTR),HL
	LD	A,(WORD_IDX)
	INC	A
	LD	(WORD_IDX),A
	CP	EEP_WORDS
	JR	C,.READ_LP

	; -- dump --
	PRINTLN MSG_DUMP_HDR
	LD	HL,EEP_BUF
	LD	(DST_PTR),HL
	XOR	A
	LD	(WORD_IDX),A
.ROW_LP
	PRINT MSG_ROW
	LD	A,(WORD_IDX)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,':'
	CALL	PUTCHAR
	LD	HL,(DST_PTR)
	LD	(ROW_PTR),HL
	LD	B,EEP_PER_LINE
.COL_LP
	PUSH	BC
	LD	A,' '
	CALL	PUTCHAR
	LD	HL,(DST_PTR)
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	INC	HL
	LD	(DST_PTR),HL
	LD	A,D			; print big-endian: the word as a number
	CALL	@UTIL.PRINT_HEX_A
	LD	A,E
	CALL	@UTIL.PRINT_HEX_A
	POP	BC
	DJNZ	.COL_LP
	; ASCII gutter.  Worth the 16 columns: an RTL8019AS EEPROM is an
	; ISA PnP resource block, and its identifier string ("NE2000 PLUG &
	; PLAY ETHERNET CARD" on the card this was written against) is only
	; obvious when the bytes are shown as text.
	PRINT MSG_BAR
	LD	HL,(ROW_PTR)
	LD	B,EEP_PER_LINE * 2
.ASC_LP
	PUSH	BC
	PUSH	HL
	LD	A,(HL)
	CP	' '
	JR	C,.ASC_DOT
	CP	0x7F
	JR	C,.ASC_PUT
.ASC_DOT
	LD	A,'.'
.ASC_PUT
	CALL	PUTCHAR
	POP	HL
	INC	HL
	POP	BC
	DJNZ	.ASC_LP
	PRINT LINE_END
	LD	A,(WORD_IDX)
	ADD	A,EEP_PER_LINE
	LD	(WORD_IDX),A
	CP	EEP_WORDS
	JR	C,.ROW_LP

	; Everything below reads the CLASSIC NE2000 field map (MAC in words
	; 0..2, compatibility marks in 7/8, jumperless config in 0E/0F).
	; RTL8019AS does not use it -- its EEPROM carries ISA PnP resource
	; data instead -- so decoding it there produces confident nonsense
	; (a "MAC" cut out of the PnP serial identifier, marks that are
	; really ASCII spaces).  Print the dump and stop.
	LD	A,(EEP_OFF)
	CP	EEP_OFF_RTL
	JR	NZ,.CLASSIC_MAP
	PRINTLN MSG_NO_MAP1
	PRINTLN MSG_NO_MAP2
	JP	DECODE_DONE
.CLASSIC_MAP

	; [P2] MAC from words 0..2.  The buffer already holds the bytes in
	; PROM order (word low byte first), so PRINT_MAC can read it flat.
	; Cross-check against NICINFO's "PROM MAC=" line.
	PRINT MSG_P2
	LD	HL,EEP_BUF
	CALL	@UTIL.PRINT_MAC
	PRINT LINE_END

	; [P3] the two compatibility marks LANSET maintains.
	PRINT MSG_P3
	LD	HL,EEP_BUF + 7*2
	CALL	PRINT_WORD_AT
	PRINT MSG_P3B
	LD	HL,EEP_BUF + 8*2
	CALL	PRINT_WORD_AT
	PRINT LINE_END
	PRINTLN MSG_P3C

	; [P4] configuration words.
	PRINT MSG_P4
	LD	HL,EEP_BUF + 0x0E*2
	CALL	PRINT_WORD_AT
	PRINT MSG_P4B
	LD	HL,EEP_BUF + 0x0F*2
	CALL	PRINT_WORD_AT
	PRINT LINE_END
	; Config byte 1 = low byte of word 0x0E: bits 0..2 index the I/O
	; base table, bits 3..5 the IRQ table.  Both orderings come from
	; LANSET's own UMC menu, and the base one is confirmed: a card
	; reading index 0 answers at 0x300, which is where [P0] found it.
	PRINT MSG_P5
	LD	A,(EEP_BUF + 0x0E*2)
	AND	0x07
	LD	(CFG_IDX),A
	ADD	A,'0'
	CALL	PUTCHAR
	PRINT MSG_PAREN
	LD	A,(CFG_IDX)
	CP	7			; table has 7 entries, index 7 is undefined
	JR	NC,.BASE_BAD
	ADD	A,A
	LD	E,A
	LD	D,0
	LD	HL,BASE_TAB
	ADD	HL,DE
	LD	A,(HL)
	INC	HL
	LD	D,(HL)
	LD	E,A
	LD	A,D
	CALL	@UTIL.PRINT_HEX_A
	LD	A,E
	CALL	@UTIL.PRINT_HEX_A
	JR	.BASE_DONE
.BASE_BAD
	PRINT MSG_QQ
.BASE_DONE
	PRINT MSG_UNPAREN

	PRINT MSG_P5B
	LD	A,(EEP_BUF + 0x0E*2)
	RRCA
	RRCA
	RRCA
	AND	0x07
	LD	(CFG_IDX),A
	ADD	A,'0'
	CALL	PUTCHAR
	PRINT MSG_PAREN_IRQ
	LD	A,(CFG_IDX)
	LD	E,A
	LD	D,0
	LD	HL,IRQ_TAB
	ADD	HL,DE
	LD	A,(HL)
	CALL	PRINT_DEC_A
	PRINT MSG_UNPAREN
	; IRQ 9..15 live on the 36-pin extension an ISA-8 slot does not
	; have, so an interrupt-driven driver would never see this card.
	; This kit polls, hence a note rather than a warning.
	LD	A,(CFG_IDX)
	CP	4
	JR	C,.IRQ_DONE
	PRINT MSG_NO_ISA8
.IRQ_DONE
	PRINT LINE_END

DECODE_DONE
	PRINTLN MSG_RESULT_OK
	DSS_RETURN EX_OK

EEP_FAIL
	; The dummy bit after the read command was not 0.  Either the
	; control register is at the other offset for this controller, or
	; the card has no 93C46 wired to it.
	PRINT MSG_E_PROTO
	LD	A,(WORD_IDX)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END
	; PRINTLN + DSS_RETURN, not UTIL.EXIT_FAIL: that helper prints
	; "RESULT FAIL" itself and would emit the line twice.
	PRINTLN MSG_RESULT_FAIL
	DSS_RETURN EX_NIC_ERR


; ======================================================
; 93C46 access.  ISA window must be OPEN; no DSS calls here.
; ======================================================

; ------------------------------------------------------
; EEP_READ_WORD: read one 93C46 word.
; In:  A = word address 0..63.
; Out: CF=0, DE = value.  CF=1 = protocol error (dummy bit set).
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
EEP_READ_WORD
	PUSH	AF
	CALL	EEP_ENABLE		; HL -> control register
	LD	A,(EEP_SHADOW)
	OR	EEP_CS
	LD	(HL),A			; chip select high
	POP	AF
	AND	0x3F
	OR	0x80			; low 8 bits of 0x180 | addr
	LD	E,A
	LD	D,1			; DE = 0x180 | addr, 9 bits
	CALL	EEP_SEND_9
	; The 93C46 answers the command with a dummy 0 before the data.
	LD	A,(HL)
	AND	EEP_DO
	JR	NZ,.BAD
	LD	DE,0
	LD	B,16
.LP
	SLA	E
	RL	D
	CALL	EEP_RECV_BIT		; A = 0 or EEP_DO
	OR	A
	JR	Z,.NEXT
	SET	0,E
.NEXT
	DJNZ	.LP
	CALL	EEP_DISABLE
	OR	A			; CF=0
	RET
.BAD
	CALL	EEP_DISABLE
	SCF
	RET

; ------------------------------------------------------
; EEP_ENABLE: select page 3 and raise the EEPROM access bit.
; Out: HL = control register address, EEP_SHADOW = base value
;      (access enabled, EECS/EESK/EEDI all low).
; ------------------------------------------------------
EEP_ENABLE
	LD	HL,(RTL_BASE_PTR)
	LD	(HL),CR_PAGE3_STOP
	LD	DE,(EEP_OFF)
	ADD	HL,DE
	LD	A,(HL)
	OR	EEP_EN
	AND	~(EEP_CS | EEP_SK | EEP_DI) & 0xFF
	LD	(EEP_SHADOW),A
	LD	(HL),A
	RET

; ------------------------------------------------------
; EEP_DISABLE: drop chip select, clear the access bit, return the
; controller to page 0 stopped.
; In: HL = control register address.
; ------------------------------------------------------
EEP_DISABLE
	LD	A,(EEP_SHADOW)
	LD	(HL),A			; EECS low (shadow has it clear)
	AND	~EEP_EN & 0xFF
	LD	(HL),A
	LD	HL,(RTL_BASE_PTR)
	LD	(HL),CR_PAGE0_STOP
	RET

; ------------------------------------------------------
; EEP_SEND_9: clock out the low 9 bits of DE, MSB first.
; In: HL = control register, DE = command.
; Preserves DE, HL.
; ------------------------------------------------------
EEP_SEND_9
	LD	BC,0x0100		; walking mask, bit 8 down to bit 0
.LP
	LD	A,D
	AND	B
	JR	NZ,.ONE
	LD	A,E
	AND	C
	JR	NZ,.ONE
	XOR	A
	JR	.SEND
.ONE
	LD	A,1
.SEND
	CALL	EEP_SEND_BIT
	SRL	B
	RR	C
	LD	A,B
	OR	C
	JR	NZ,.LP
	RET

; ------------------------------------------------------
; EEP_SEND_BIT: one bit out, clocked on the EESK rising edge.
; In: HL = control register, A bit 0 = data.
; Preserves BC, DE, HL.
; ------------------------------------------------------
EEP_SEND_BIT
	PUSH	BC
	RRCA
	JR	NC,.ZERO
	LD	A,(EEP_SHADOW)
	OR	EEP_CS | EEP_DI
	JR	.DRIVE
.ZERO
	LD	A,(EEP_SHADOW)
	OR	EEP_CS
.DRIVE
	LD	C,A
	LD	(HL),A			; data valid, clock low
	OR	EEP_SK
	LD	(HL),A			; rising edge: chip samples EEDI
	LD	A,C
	LD	(HL),A			; clock low again
	POP	BC
	RET

; ------------------------------------------------------
; EEP_RECV_BIT: one bit in, sampled while EESK is high.
; In: HL = control register.
; Out: A = 0 or EEP_DO.  Preserves BC, DE, HL.
; ------------------------------------------------------
EEP_RECV_BIT
	PUSH	BC
	LD	A,(EEP_SHADOW)
	OR	EEP_CS
	LD	(HL),A			; clock low
	OR	EEP_SK
	LD	(HL),A			; clock high
	LD	A,(HL)			; sample EEDO with the clock still high
	LD	C,A
	AND	~EEP_SK & 0xFF
	LD	(HL),A			; clock low
	LD	A,C
	AND	EEP_DO
	POP	BC
	RET


; ======================================================
; Formatting helpers (ISA window CLOSED).
; ======================================================

; PRINT_WORD_AT: print the 16-bit word stored at HL (low byte
; first) as 4 hex digits.  Trashes A, HL.
PRINT_WORD_AT
	INC	HL
	LD	A,(HL)
	CALL	@UTIL.PRINT_HEX_A
	DEC	HL
	LD	A,(HL)
	JP	@UTIL.PRINT_HEX_A

PUTCHAR
	PUSH	AF,BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC,AF
	RET

PRINT_HEX_NIBBLE
	CP	10
	JR	C,.D
	ADD	A,'A' - 10
	JR	PUTCHAR
.D
	ADD	A,'0'
	JR	PUTCHAR

; PRINT_DEC_A: A = 0..99 as decimal, no leading zero.  Trashes AF, BC.
PRINT_DEC_A
	LD	B,'0'
.TENS
	CP	10
	JR	C,.UNITS
	SUB	10
	INC	B
	JR	.TENS
.UNITS
	PUSH	AF
	LD	A,B
	CP	'0'
	JR	Z,.NOTENS
	CALL	PUTCHAR
.NOTENS
	POP	AF
	ADD	A,'0'
	JR	PUTCHAR

; Selector tables, both read out of LANSET's UMC menu block.
BASE_TAB	DW 0x300, 0x240, 0x280, 0x2C0, 0x320, 0x340, 0x360
IRQ_TAB		DB 3, 4, 5, 9, 10, 11, 12, 15	; index 3 is "IRQ 2/9"


MSG_BANNER	DB "RTL8019AS NICEEP v",PACKAGE_VERSION,0
MSG_P0		DB "[P0] Slot/Addr: ",0
MSG_SLASH	DB "/#",0
MSG_P1		DB "[P1] ID=",0
MSG_CTRL	DB " EEPROM ctrl = page3 reg ",0
MSG_LAY_RTL	DB " (RTL8019AS 9346CR)",0
MSG_LAY_UMC	DB " (UM9003x layout)",0
MSG_DUMP_HDR	DB "93C46 contents, 64 words:",0
MSG_ROW		DB "EEP ",0
MSG_BAR		DB " |",0
MSG_NO_MAP1	DB "[P2] no field decode: RTL8019AS does not use the classic",0
MSG_NO_MAP2	DB "     NE2000 EEPROM map.  Read the ASCII column above.",0
MSG_P2		DB "[P2] MAC (words 0-2) = ",0
MSG_P3		DB "[P3] W7=",0
MSG_P3B		DB "  W8=",0
MSG_P3C		DB "     5757='WW' NE2000/16-bit, 4242='BB' NE1000/8-bit",0
MSG_P4		DB "[P4] CFG W0E=",0
MSG_P4B		DB "  W0F=",0
MSG_P5		DB "     base idx=",0
MSG_P5B		DB "  irq idx=",0
MSG_PAREN	DB " (",0
MSG_PAREN_IRQ	DB " (IRQ ",0
MSG_UNPAREN	DB ")",0
MSG_QQ		DB "????",0
MSG_NO_ISA8	DB " - absent on ISA-8",0
MSG_E_PROTO	DB "[E1] no 93C46 answer (dummy bit set) at word ",0
MSG_RESULT_OK	DB "RESULT OK",0
MSG_RESULT_FAIL	DB "RESULT FAIL",0
LINE_END	DB 13,10,0

	ENDMODULE

	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"


; Root-scope marker at end of emitted image.
NICEEP_IMAGE_END

; -------- runtime BSS (no bytes emitted) --------
	MODULE MAIN

EEP_BUF		EQU NICEEP_IMAGE_END	; 64 words, low byte first
EEP_SHADOW	EQU EEP_BUF + 128	; 1 byte
EEP_OFF		EQU EEP_SHADOW + 1	; 2 bytes (control register offset)
WORD_IDX	EQU EEP_OFF + 2		; 1 byte
DST_PTR		EQU WORD_IDX + 1	; 2 bytes
CFG_IDX		EQU DST_PTR + 2		; 1 byte
ROW_PTR		EQU CFG_IDX + 1		; 2 bytes
NICEEP_BSS_END	EQU ROW_PTR + 2

	ASSERT NICEEP_BSS_END < 0xC000

	ENDMODULE

	END MAIN.START
