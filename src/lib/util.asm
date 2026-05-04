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
