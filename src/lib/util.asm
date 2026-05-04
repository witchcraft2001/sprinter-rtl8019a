; ======================================================
; Generic helpers: hex print, delays.
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_UTIL
	DEFINE	_UTIL

	MODULE UTIL

; ------------------------------------------------------
; Convert byte in C to two ASCII hex chars at (DE), DE += 2.
; Trashes A. Source: classic Z80 DAA-trick (RomychS sprinter_wifi).
; ------------------------------------------------------
HEXB
	LD	A,C
	RRA
	RRA
	RRA
	RRA
	CALL	.NIBBLE
	LD	A,C
.NIBBLE
	AND	0x0F
	ADD	A,0x90
	DAA
	ADC	A,0x40
	DAA
	LD	(DE),A
	INC	DE
	RET

; ------------------------------------------------------
; Print byte in A as 2 hex digits via DSS_PCHARS.
; Preserves A,BC,DE,HL.
; ------------------------------------------------------
PRINT_HEX_A
	PUSH	AF,BC,DE,HL
	LD	C,A
	LD	DE,.HBUF
	CALL	HEXB
	XOR	A
	LD	(DE),A
	LD	HL,.HBUF
	LD	C,DSS_PCHARS
	RST	DSS
	POP	HL,DE,BC,AF
	RET
.HBUF	DS 4,0

; ------------------------------------------------------
; Print word in HL as 4 hex digits.
; ------------------------------------------------------
PRINT_HEX_HL
	PUSH	AF
	LD	A,H
	CALL	PRINT_HEX_A
	LD	A,L
	CALL	PRINT_HEX_A
	POP	AF
	RET

; ------------------------------------------------------
; Print MAC at HL as XX:XX:XX:XX:XX:XX (6 bytes).
; Preserves all.
; ------------------------------------------------------
PRINT_MAC
	PUSH	AF,BC,DE,HL
	LD	B,6
.LP
	LD	A,(HL)
	CALL	PRINT_HEX_A
	INC	HL
	DEC	B
	JR	Z,.DONE
	LD	A,':'
	PUSH	BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC
	JR	.LP
.DONE
	POP	HL,DE,BC,AF
	RET

; ------------------------------------------------------
; Approximate delay loops. Calibrated for Sprinter Z80
; clock; precise duration is not critical for chip resets,
; we just need "definitely more than X ms".
; ------------------------------------------------------
DELAY_1MS
	PUSH	AF,BC
	LD	BC,400
.L1
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.L1
	POP	BC,AF
	RET

DELAY_2MS
	CALL	DELAY_1MS
	JR	DELAY_1MS

; ------------------------------------------------------
; Delay HL milliseconds (HL > 0). For HL=0 returns immediately.
; ------------------------------------------------------
DELAY_MS
	PUSH	AF,HL
	LD	A,H
	OR	L
	JR	Z,.DONE
.LP
	CALL	DELAY_1MS
	DEC	HL
	LD	A,H
	OR	L
	JR	NZ,.LP
.DONE
	POP	HL,AF
	RET

; ------------------------------------------------------
; STARTSWITH: ZF=1 if string at HL starts with the ASCIIZ
; prefix at DE. HL is preserved either way; DE is advanced.
; Trashes A.
; ------------------------------------------------------
	IFDEF USE_UTIL_STARTSWITH
STARTSWITH
	PUSH	HL
.LP
	LD	A,(DE)
	OR	A
	JR	Z,.MATCH
	CP	(HL)
	JR	NZ,.MISS
	INC	HL
	INC	DE
	JR	.LP
.MATCH
	POP	HL
	XOR	A			; ZF=1
	RET
.MISS
	POP	HL
	LD	A,0xFF
	OR	A			; ZF=0
	RET
	ENDIF

; ------------------------------------------------------
; PARSE_DEC_BYTE: read decimal digits at (HL) into A, stopping
; at the first non-digit. Returns A = value (mod 256), HL points
; at the first non-digit byte. Saturates at 255 on overflow.
;   Out: A = byte, HL advanced past digits.
;        CF=1 if no digit consumed (otherwise CF=0).
; Trashes A only. BC preserved (saved/restored on stack).
; ------------------------------------------------------
	IFDEF USE_UTIL_PARSE_DEC_BYTE
PARSE_DEC_BYTE
	PUSH	BC			; save caller's BC
	LD	B,0			; B = local digit-consumed counter
	XOR	A			; accumulator
.LP
	PUSH	AF
	LD	A,(HL)
	SUB	'0'
	JR	C,.END
	CP	10
	JR	NC,.END
	LD	C,A
	POP	AF
	PUSH	BC
	LD	B,A
	ADD	A,A
	ADD	A,A
	ADD	A,B
	ADD	A,A
	POP	BC
	ADD	A,C
	INC	HL
	INC	B
	JR	.LP
.END
	POP	AF
	PUSH	AF
	LD	A,B
	OR	A
	JR	Z,.NODIG
	POP	AF
	POP	BC			; restore caller's BC
	OR	A			; CF=0
	RET
.NODIG
	POP	AF
	POP	BC
	SCF
	RET
	ENDIF

; ------------------------------------------------------
; PARSE_HEX_NIBBLE: A = '0'..'9'/'a'..'f'/'A'..'F' -> 0..15
; Out: A = nibble (low 4 bits). CF=1 if input not a hex digit.
; ------------------------------------------------------
	IFDEF USE_UTIL_PARSE_HEX_BYTE
PARSE_HEX_NIBBLE
	CP	'0'
	JR	C,.BAD
	CP	'9'+1
	JR	C,.D09
	CP	'A'
	JR	C,.BAD
	CP	'F'+1
	JR	C,.DAF
	CP	'a'
	JR	C,.BAD
	CP	'f'+1
	JR	NC,.BAD
	SUB	'a'-10
	OR	A
	RET
.D09
	SUB	'0'
	OR	A
	RET
.DAF
	SUB	'A'-10
	OR	A
	RET
.BAD
	SCF
	RET

; ------------------------------------------------------
; PARSE_HEX_BYTE: read 2 hex digits at (HL), HL += 2.
;   Out: A = byte; CF=1 on bad digit.
; Trashes A only. BC preserved (saved/restored on stack).
; ------------------------------------------------------
PARSE_HEX_BYTE
	PUSH	BC			; save caller's BC
	LD	A,(HL)
	CALL	PARSE_HEX_NIBBLE
	JR	C,.BAD
	RLCA
	RLCA
	RLCA
	RLCA
	AND	0xF0
	LD	B,A
	INC	HL
	LD	A,(HL)
	CALL	PARSE_HEX_NIBBLE
	JR	C,.BAD
	OR	B
	INC	HL
	POP	BC			; restore caller's BC
	OR	A			; CF=0
	RET
.BAD
	POP	BC
	SCF
	RET
	ENDIF

; ------------------------------------------------------
; Internet checksum (RFC 1071): one's-complement sum of
; 16-bit BE words, complemented.
;
; In:  IX = buffer pointer, BC = byte count (must be even).
;      The buffer is read in BIG-ENDIAN order: (IX+0) is high,
;      (IX+1) is low of the first 16-bit word.
; Out: HL = ~accumulator. Store as `H, L` to get the 16-bit
;      checksum in BIG-ENDIAN bytes.
; Trashes: A, BC, DE, IX.
; ------------------------------------------------------
CHECKSUM
	LD	HL,0
.LP
	LD	A,B
	OR	C
	JR	Z,.DONE
	LD	D,(IX+0)
	LD	E,(IX+1)
	INC	IX
	INC	IX
	ADD	HL,DE
	JR	NC,.NC
	INC	HL			; carry-fold (rare second wrap is impossible after one INC)
.NC
	DEC	BC
	DEC	BC
	JR	.LP
.DONE
	LD	A,H
	CPL
	LD	H,A
	LD	A,L
	CPL
	LD	L,A
	RET

	ENDMODULE
	ENDIF
