; ======================================================
; RTL8019AS 9346 / 93C46 Microwire access.
;
; This is intentionally an optional include.  Normal network utilities do
; not need it and the common driver never writes non-volatile state.
;
; The RTL8019AS connects a 1-Kbit 93C46 in 64 x 16-bit organization.  Each
; instruction is MSB first: start bit, two-bit opcode, six-bit word address,
; then (for WRITE) sixteen data bits.  The EEPROM produces a leading zero
; during the final command/address clock; by the first separate IN_BIT call
; D15 is already present on EEDO.  Therefore READ samples exactly sixteen
; bits here -- discarding another "dummy" shifts the word left by one on real
; RTL8019AS hardware.  Callers must have opened the ISA window and populated
; RTL_BASE_PTR with RTL.INIT_BASE.
;
; Public API:
;   RTL_EEPROM.READ_WORD
;       In:  A = word address (0..63)
;       Out: HL = EEPROM word, CF=0
;   RTL_EEPROM.WRITE_WORD
;       In:  A = word address (0..63), HL = word
;       Out: write cycle started, CF=0.  The caller MUST close ISA, wait at
;            least 20 ms, reopen ISA and call WRITE_DISABLE.
;   RTL_EEPROM.WRITE_DISABLE
;       Send EWDS after a completed write cycle.
;   RTL_EEPROM.AUTOLOAD
;       Start RTL8019AS EEPROM auto-load.  Caller must immediately close ISA,
;       wait at least 2 ms, then reopen before reading chip registers.
;
; No routine calls DSS/BIOS or waits for a millisecond with ISA open.
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_RTL8019_EEPROM
	DEFINE	_RTL8019_EEPROM

	INCLUDE "rtl8019.inc"
	INCLUDE "memmap.inc"

	MODULE RTL_EEPROM

; A short pause keeps EESK comfortably below the 93C46 clock limit without
; holding the ISA window open for a system tick.  Preserves all registers.
BIT_PAUSE
	PUSH	BC
	LD	B,8
.LP
	DJNZ	.LP
	POP	BC
	RET


; Enter RTL8019AS EEPROM-programming mode with CS/SK/DI low.
; Trashes A,IX.
ENTER_PROGRAM
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_CR_OFF),CR_PAGE3_STOP
	LD	A,EE_MODE_PROGRAM
	LD	(IX+RTL_9346CR_OFF),A
	CALL	BIT_PAUSE
	RET


; Leave programming mode and return the NIC to page 0 / stopped state.
; Trashes A,IX.
LEAVE_PROGRAM
	LD	IX,(RTL_BASE_PTR)
	LD	A,EE_MODE_PROGRAM
	LD	(IX+RTL_9346CR_OFF),A	; CS low first
	CALL	BIT_PAUSE
	XOR	A
	LD	(IX+RTL_9346CR_OFF),A
	LD	(IX+RTL_CR_OFF),CR_PAGE0_STOP
	RET


; Start a Microwire command (CS rising with SK/DI low).
BEGIN_COMMAND
	LD	A,EE_MODE_PROGRAM
	LD	(IX+RTL_9346CR_OFF),A
	CALL	BIT_PAUSE
	OR	EE_PIN_CS
	LD	(IX+RTL_9346CR_OFF),A
	CALL	BIT_PAUSE
	RET


; End a Microwire command.  CS falling starts an EEPROM WRITE cycle.
END_COMMAND
	LD	A,EE_MODE_PROGRAM
	LD	(IX+RTL_9346CR_OFF),A
	CALL	BIT_PAUSE
	RET


; Clock one output bit.  Input bit is CF (0/1).  Trashes A.
OUT_BIT
	LD	A,EE_MODE_PROGRAM | EE_PIN_CS
	JR	NC,.ZERO
	OR	EE_PIN_DI
.ZERO
	LD	(IX+RTL_9346CR_OFF),A
	CALL	BIT_PAUSE
	OR	EE_PIN_SK
	LD	(IX+RTL_9346CR_OFF),A
	CALL	BIT_PAUSE
	AND	0xFF - EE_PIN_SK
	LD	(IX+RTL_9346CR_OFF),A
	CALL	BIT_PAUSE
	RET


; Clock one input bit and return EEDO in CF.  Trashes A.
IN_BIT
	LD	A,EE_MODE_PROGRAM | EE_PIN_CS
	LD	(IX+RTL_9346CR_OFF),A
	CALL	BIT_PAUSE
	OR	EE_PIN_SK
	LD	(IX+RTL_9346CR_OFF),A
	CALL	BIT_PAUSE
	LD	A,(IX+RTL_9346CR_OFF)
	PUSH	AF
	LD	A,EE_MODE_PROGRAM | EE_PIN_CS
	LD	(IX+RTL_9346CR_OFF),A
	CALL	BIT_PAUSE
	POP	AF
	RRCA				; EEDO bit 0 -> CF
	RET


; Send six-bit word address from C, bit 5 first.  Trashes A,B,C.
OUT_ADDRESS
	LD	A,C
	ADD	A,A
	ADD	A,A			; original A5 is now bit 7
	LD	C,A
	LD	B,6
.LP
	SLA	C
	CALL	OUT_BIT
	DJNZ	.LP
	RET


; Send 16-bit word from DE, bit 15 first.  Trashes A,B,D,E.
OUT_WORD
	LD	B,16
.LP
	SLA	E
	RL	D				; original D7 -> CF
	CALL	OUT_BIT
	DJNZ	.LP
	RET


; Send EWEN = 1 00 11xxxx (x16 organization, 9 clocks).
SEND_EWEN
	CALL	BEGIN_COMMAND
	SCF
	CALL	OUT_BIT			; start 1
	OR	A
	CALL	OUT_BIT			; opcode 0
	OR	A
	CALL	OUT_BIT			; opcode 0
	SCF
	CALL	OUT_BIT			; address prefix 1
	SCF
	CALL	OUT_BIT			; address prefix 1
	LD	B,4
.ZERO_LP
	OR	A
	CALL	OUT_BIT
	DJNZ	.ZERO_LP
	JP	END_COMMAND


; Send EWDS = 1 00 00xxxx (x16 organization, 9 clocks).
SEND_EWDS
	CALL	BEGIN_COMMAND
	SCF
	CALL	OUT_BIT			; start 1
	OR	A
	CALL	OUT_BIT			; opcode 0
	OR	A
	CALL	OUT_BIT			; opcode 0
	LD	B,6
.ZERO_LP
	OR	A
	CALL	OUT_BIT
	DJNZ	.ZERO_LP
	JP	END_COMMAND


; ------------------------------------------------------
; READ_WORD
; ------------------------------------------------------
READ_WORD
	PUSH	BC,DE
	AND	0x3F
	LD	C,A
	CALL	ENTER_PROGRAM
	CALL	BEGIN_COMMAND
	SCF
	CALL	OUT_BIT			; start 1
	SCF
	CALL	OUT_BIT			; READ opcode bit 1
	OR	A
	CALL	OUT_BIT			; READ opcode bit 0
	CALL	OUT_ADDRESS
	LD	HL,0
	LD	B,16
.READ_LP
	CALL	IN_BIT
	ADC	HL,HL
	DJNZ	.READ_LP
	CALL	END_COMMAND
	CALL	LEAVE_PROGRAM
	POP	DE,BC
	OR	A
	RET


; ------------------------------------------------------
; WRITE_WORD
; ------------------------------------------------------
WRITE_WORD
	PUSH	BC,DE
	AND	0x3F
	LD	C,A
	LD	D,H
	LD	E,L
	CALL	ENTER_PROGRAM
	CALL	SEND_EWEN
	CALL	BEGIN_COMMAND
	SCF
	CALL	OUT_BIT			; start 1
	OR	A
	CALL	OUT_BIT			; WRITE opcode bit 0
	SCF
	CALL	OUT_BIT			; WRITE opcode bit 1
	CALL	OUT_ADDRESS
	CALL	OUT_WORD
	CALL	END_COMMAND		; CS falling starts programming
	CALL	LEAVE_PROGRAM
	POP	DE,BC
	OR	A
	RET


; ------------------------------------------------------
; WRITE_DISABLE
; ------------------------------------------------------
WRITE_DISABLE
	CALL	ENTER_PROGRAM
	CALL	SEND_EWDS
	CALL	LEAVE_PROGRAM
	OR	A
	RET


; ------------------------------------------------------
; AUTOLOAD
; ------------------------------------------------------
AUTOLOAD
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_CR_OFF),CR_PAGE3_STOP
	LD	A,EE_MODE_AUTOLOAD
	LD	(IX+RTL_9346CR_OFF),A
	OR	A
	RET

	ENDMODULE
	ENDIF
