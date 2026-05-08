; ======================================================
; Generic helpers: hex print, delays.
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_UTIL
	DEFINE	_UTIL

	INCLUDE "memmap.inc"

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
.HBUF	EQU UTIL_HBUF			; 4 bytes in runtime BSS

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
; Always compiled -- used by rtl8019.asm INIT_BASE for the env
; override "S/#HHH" parser, which every app pulls in.
; ------------------------------------------------------
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
	IFDEF USE_UTIL_PARSE_HEX_BYTE
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

; ------------------------------------------------------
; EXIT helpers: standardized RESULT line + DSS_EXIT.
; All CLI utilities use these to ensure consistent exit
; codes (per CLAUDE.md: 0 ok, 1 usage, 2 no NIC, 3 net,
; 4 config) and a final RESULT line for batch scripts.
;
;   EXIT       In: B = exit code. No print, just exit.
;   EXIT_OK    Print "RESULT OK", exit B=0.
;   EXIT_FAIL  In: B = exit code. Print "RESULT FAIL", exit.
; ------------------------------------------------------
	IFDEF USE_UTIL_PRINT_DEC_32
; ------------------------------------------------------
; PRINT_DEC_32: print 32-bit value as unsigned decimal,
; no leading zeros, via DSS_PUTCHAR.
;   In:  HL = low word, DE = high word
;   Out: trashes A,BC,DE,HL.
; ------------------------------------------------------
PRINT_DEC_32
	; Stash value into UTIL_DEC32_SCRATCH (LE order).
	LD	(UTIL_DEC32_SCRATCH),HL
	LD	(UTIL_DEC32_SCRATCH + 2),DE
	; Special-case zero.
	LD	A,(UTIL_DEC32_SCRATCH)
	LD	B,A
	LD	A,(UTIL_DEC32_SCRATCH + 1)
	OR	B
	LD	B,A
	LD	A,(UTIL_DEC32_SCRATCH + 2)
	OR	B
	LD	B,A
	LD	A,(UTIL_DEC32_SCRATCH + 3)
	OR	B
	JR	NZ,.NZ
	LD	A,'0'
	LD	C,DSS_PUTCHAR
	RST	DSS
	RET
.NZ
	LD	B,0			; digit count
.LP
	CALL	.DIV32_10
	ADD	A,'0'
	PUSH	AF
	INC	B
	; Test value zero.
	LD	A,(UTIL_DEC32_SCRATCH)
	LD	C,A
	LD	A,(UTIL_DEC32_SCRATCH + 1)
	OR	C
	LD	C,A
	LD	A,(UTIL_DEC32_SCRATCH + 2)
	OR	C
	LD	C,A
	LD	A,(UTIL_DEC32_SCRATCH + 3)
	OR	C
	JR	NZ,.LP
.OUT
	POP	AF
	PUSH	BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC
	DJNZ	.OUT
	RET

; .DIV32_10: divide 32-bit LE value at UTIL_DEC32_SCRATCH
; by 10 in place; A = remainder.  Standard MSB-first long
; division.  Preserves B (digit counter).
.DIV32_10
	PUSH	BC
	PUSH	DE
	LD	HL,0			; remainder
	LD	B,32
.DLP
	; Shift the 32-bit value left by 1, MSB -> carry.
	PUSH	HL
	LD	HL,UTIL_DEC32_SCRATCH
	SLA	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	POP	HL
	; remainder = remainder*2 + carry
	ADC	HL,HL
	; If remainder >= 10, subtract 10 and set quotient bit.
	LD	DE,10
	OR	A
	SBC	HL,DE
	JR	NC,.DSUB
	ADD	HL,DE
	JR	.DNEXT
.DSUB
	PUSH	HL
	LD	HL,UTIL_DEC32_SCRATCH
	SET	0,(HL)
	POP	HL
.DNEXT
	DJNZ	.DLP
	LD	A,L
	POP	DE
	POP	BC
	RET
	ENDIF


	; USE_UTIL_TPUT implies USE_UTIL_PRINT_DEC_32 (used to format the
	; bytes / seconds / KB/s numbers).
	IFDEF USE_UTIL_TPUT
	IFNDEF USE_UTIL_PRINT_DEC_32
	DEFINE USE_UTIL_PRINT_DEC_32
	ENDIF
	ENDIF

	IFDEF USE_UTIL_TPUT
; ------------------------------------------------------
; TPUT_NOW: read DSS_SYSTIME and return the wall-clock time
; as 24-bit seconds-of-day.
;   Out: B = high 8 bits, HL = low 16 bits.
; Trashes A, BC, DE, HL.  IX preserved (DSS_SYSTIME clobbers IX).
; ------------------------------------------------------
TPUT_NOW
	PUSH	IX
	LD	C,DSS_SYSTIME
	RST	DSS
	; H = hours, L = minutes, B = seconds.
	PUSH	BC			; stash sec
	PUSH	HL			; stash hr/min
	; Acc (24-bit at UTIL_DEC32_SCRATCH) = 0.
	XOR	A
	LD	(UTIL_DEC32_SCRATCH + 0),A
	LD	(UTIL_DEC32_SCRATCH + 1),A
	LD	(UTIL_DEC32_SCRATCH + 2),A
	; Acc += hours * 3600.
	POP	DE			; D = hours, E = minutes
	PUSH	DE
	LD	A,D
	OR	A
	JR	Z,.SKIP_HH
	LD	B,A
.HH_LP
	LD	HL,(UTIL_DEC32_SCRATCH)
	LD	DE,3600
	ADD	HL,DE
	LD	(UTIL_DEC32_SCRATCH),HL
	JR	NC,.NCHH
	LD	A,(UTIL_DEC32_SCRATCH + 2)
	INC	A
	LD	(UTIL_DEC32_SCRATCH + 2),A
.NCHH
	DJNZ	.HH_LP
.SKIP_HH
	; Acc += minutes * 60.
	POP	DE			; D = hours, E = minutes
	LD	A,E
	OR	A
	JR	Z,.SKIP_MM
	LD	B,A
.MM_LP
	LD	HL,(UTIL_DEC32_SCRATCH)
	LD	DE,60
	ADD	HL,DE
	LD	(UTIL_DEC32_SCRATCH),HL
	JR	NC,.NCMM
	LD	A,(UTIL_DEC32_SCRATCH + 2)
	INC	A
	LD	(UTIL_DEC32_SCRATCH + 2),A
.NCMM
	DJNZ	.MM_LP
.SKIP_MM
	; Acc += seconds.
	POP	BC			; B = seconds
	LD	HL,(UTIL_DEC32_SCRATCH)
	LD	D,0
	LD	E,B
	ADD	HL,DE
	LD	(UTIL_DEC32_SCRATCH),HL
	JR	NC,.NCSS
	LD	A,(UTIL_DEC32_SCRATCH + 2)
	INC	A
	LD	(UTIL_DEC32_SCRATCH + 2),A
.NCSS
	; Return: B = high, HL = low.
	LD	HL,(UTIL_DEC32_SCRATCH)
	LD	A,(UTIL_DEC32_SCRATCH + 2)
	LD	B,A
	POP	IX
	RET

; ------------------------------------------------------
; TPUT_START: capture the current SOD into UTIL_TPUT_START.
; Call once just before the transfer begins.
; Trashes A, BC, DE, HL.  IX preserved.
; ------------------------------------------------------
TPUT_START
	CALL	TPUT_NOW
	LD	(UTIL_TPUT_START),HL
	LD	A,B
	LD	(UTIL_TPUT_START + 2),A
	RET

; ------------------------------------------------------
; TPUT_REPORT: print transfer summary line.
;   In: DE:HL = bytes transferred (DE = high word, HL = low).
;   Output (one of):
;     "  <bytes> bytes in <secs> sec, <K> KB/s\n"   (rate >= 1 KB/s)
;     "  <bytes> bytes in <secs> sec, <N> B/s\n"    (rate < 1 KB/s)
;     "  <bytes> bytes in <secs> sec\n"             (elapsed == 0)
; Trashes everything.
; ------------------------------------------------------
TPUT_REPORT
	; Stash bytes in UTIL_HBUF -- it survives both PRINT_DEC_32
	; calls below (each of those clobbers UTIL_DEC32_SCRATCH but
	; leaves UTIL_HBUF alone).
	LD	(UTIL_HBUF),HL
	LD	(UTIL_HBUF + 2),DE

	; Compute current SOD (B:HL).
	CALL	TPUT_NOW
	; elapsed = current - start (24-bit subtract).
	LD	DE,(UTIL_TPUT_START)
	LD	A,L
	SUB	E
	LD	L,A
	LD	A,H
	SBC	A,D
	LD	H,A
	LD	A,(UTIL_TPUT_START + 2)
	LD	E,A
	LD	A,B
	SBC	A,E
	LD	B,A
	JR	NC,.NO_WRAP
	; current < start: clock crossed midnight, add 86400 (0x015180).
	LD	DE,0x5180
	ADD	HL,DE
	LD	A,B
	ADC	A,1
	LD	B,A
.NO_WRAP
	LD	(UTIL_TPUT_ELAPSED),HL
	LD	A,B
	LD	(UTIL_TPUT_ELAPSED + 2),A

	; --- "  <bytes> bytes in " ---
	LD	HL,_TPUT_S_PREFIX
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,(UTIL_HBUF)
	LD	DE,(UTIL_HBUF + 2)
	CALL	PRINT_DEC_32
	LD	HL,_TPUT_S_BYTES_IN
	LD	C,DSS_PCHARS
	RST	DSS

	; --- elapsed seconds ---
	LD	HL,(UTIL_TPUT_ELAPSED)
	LD	A,(UTIL_TPUT_ELAPSED + 2)
	LD	E,A
	LD	D,0
	CALL	PRINT_DEC_32
	LD	HL,_TPUT_S_SEC
	LD	C,DSS_PCHARS
	RST	DSS

	; --- compute and print rate ---
	; Skip if elapsed[2] != 0 (>18 h, divisor too big) or elapsed == 0.
	LD	A,(UTIL_TPUT_ELAPSED + 2)
	OR	A
	JP	NZ,.NL_ONLY
	LD	A,(UTIL_TPUT_ELAPSED)
	LD	B,A
	LD	A,(UTIL_TPUT_ELAPSED + 1)
	OR	B
	JP	Z,.NL_ONLY

	; B/s = bytes / elapsed (32-bit / 16-bit, in-place).
	LD	HL,(UTIL_HBUF)
	LD	(UTIL_DEC32_SCRATCH),HL
	LD	HL,(UTIL_HBUF + 2)
	LD	(UTIL_DEC32_SCRATCH + 2),HL
	LD	DE,(UTIL_TPUT_ELAPSED)
	CALL	DIV32_BY_DE

	LD	HL,_TPUT_S_COMMA
	LD	C,DSS_PCHARS
	RST	DSS

	; If quotient >= 1024 print as KB/s; otherwise as B/s.
	LD	A,(UTIL_DEC32_SCRATCH + 3)
	OR	A
	JR	NZ,.RATE_KB
	LD	A,(UTIL_DEC32_SCRATCH + 2)
	OR	A
	JR	NZ,.RATE_KB
	LD	A,(UTIL_DEC32_SCRATCH + 1)
	CP	4			; >= 4 in byte 1 means value >= 1024
	JR	NC,.RATE_KB

	; --- B/s ---
	LD	HL,(UTIL_DEC32_SCRATCH)
	LD	DE,(UTIL_DEC32_SCRATCH + 2)
	CALL	PRINT_DEC_32
	LD	HL,_TPUT_S_BPS
	LD	C,DSS_PCHARS
	RST	DSS
	JR	.NL_ONLY

.RATE_KB
	; --- KB/s = quotient >> 10 ---
	LD	HL,(UTIL_DEC32_SCRATCH)
	LD	DE,(UTIL_DEC32_SCRATCH + 2)
	; >> 8: drop the low byte.  HL := (HL_hi : DE_lo); DE := (0 : DE_hi).
	LD	L,H
	LD	H,E
	LD	E,D
	LD	D,0
	; >> 2 more.
	SRL	E
	RR	H
	RR	L
	SRL	E
	RR	H
	RR	L
	CALL	PRINT_DEC_32
	LD	HL,_TPUT_S_KBS
	LD	C,DSS_PCHARS
	RST	DSS

.NL_ONLY
	LD	HL,_TPUT_S_NL
	LD	C,DSS_PCHARS
	RST	DSS
	RET

; ------------------------------------------------------
; DIV32_BY_DE: in-place 32-bit / 16-bit unsigned division.
;   Dividend: 4 bytes at UTIL_DEC32_SCRATCH (LE), replaced by quotient.
;   Divisor:  DE (must be > 0).
;   Out:      HL = remainder.  DE preserved.
; Trashes: A, B, HL, flags.
; ------------------------------------------------------
DIV32_BY_DE
	LD	HL,0			; remainder
	LD	B,32
.LP
	; Shift dividend left in place (low->high), MSB -> CY.
	PUSH	HL
	LD	HL,UTIL_DEC32_SCRATCH
	SLA	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	POP	HL
	; Shift carry into the 16-bit remainder.  ADC HL,HL may itself
	; overflow when remainder*2+bit >= 2^16; in that case the true
	; remainder is in [2^16, 2*divisor) so always >= divisor and we
	; subtract unconditionally.
	ADC	HL,HL
	JR	C,.SUB_FORCE
	OR	A
	SBC	HL,DE
	JR	C,.NOSUB
	JR	.SET
.SUB_FORCE
	OR	A
	SBC	HL,DE			; result fits in 16 bits (< divisor)
.SET
	PUSH	HL
	LD	HL,UTIL_DEC32_SCRATCH
	SET	0,(HL)
	POP	HL
	JR	.NEXT
.NOSUB
	ADD	HL,DE			; restore remainder
.NEXT
	DJNZ	.LP
	RET

_TPUT_S_PREFIX		DB "  ",0
_TPUT_S_BYTES_IN	DB " bytes in ",0
_TPUT_S_SEC		DB " sec",0
_TPUT_S_COMMA		DB ", ",0
_TPUT_S_KBS		DB " KB/s",0
_TPUT_S_BPS		DB " B/s",0
_TPUT_S_NL		DB 13,10,0
	ENDIF


	; USE_UTIL_EXIT_NO_NIC implies USE_UTIL_EXIT (it tail-calls EXIT_FAIL).
	IFDEF USE_UTIL_EXIT_NO_NIC
	IFNDEF USE_UTIL_EXIT
	DEFINE USE_UTIL_EXIT
	ENDIF
	ENDIF

	IFDEF USE_UTIL_EXIT
EXIT
	DSS_EXEC DSS_EXIT
EXIT_OK
	LD	HL,_EXIT_S_OK
	LD	C,DSS_PCHARS
	RST	DSS
	LD	B,0
	DSS_EXEC DSS_EXIT
EXIT_FAIL
	PUSH	BC
	LD	HL,_EXIT_S_FAIL
	LD	C,DSS_PCHARS
	RST	DSS
	POP	BC
	DSS_EXEC DSS_EXIT
_EXIT_S_OK	DB "RESULT OK",13,10,0
_EXIT_S_FAIL	DB "RESULT FAIL",13,10,0
	ENDIF

	IFDEF USE_UTIL_EXIT_NO_NIC
; ------------------------------------------------------
; EXIT_NO_NIC: print a clear "card not detected" line
; (followed by RESULT FAIL) and exit with EX_NO_HW.
; Caller must have the ISA window CURRENTLY OPEN (entered
; via @ISA.ISA_OPEN) -- this helper closes it before any
; DSS_PCHARS, since DSS uses MMU page 3 which the ISA
; window occupies.
; Requires: @ISA.ISA_CLOSE, EX_NO_HW (rtl8019.inc).
; ------------------------------------------------------
EXIT_NO_NIC
	CALL	@ISA.ISA_CLOSE
	LD	HL,_EXIT_S_NO_NIC
	LD	C,DSS_PCHARS
	RST	DSS
	LD	B,EX_NO_HW
	JR	EXIT_FAIL
_EXIT_S_NO_NIC	DB 13,10,"[E] RTL8019AS not detected at I/O base 0x300.",13,10
		DB     "    Card missing, wrong base, or ISA bus not driven.",13,10,0
	ENDIF

	ENDMODULE
	ENDIF
