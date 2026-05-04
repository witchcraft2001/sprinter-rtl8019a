; ======================================================
; Lightweight reader for NET_* environment variables.
; Backed by DSS ENVIRON (#46) -- variables live in PAGE 2
; (#E400) and survive across program runs within a session.
;
; Parser of NET.CFG itself lives only in NETCFG.EXE; every
; other utility uses NETENV to read already-loaded values.
;
; Public API (all routines: trash A,BC,DE; HL set as noted):
;   NETENV.GET_RAW   In: HL = ASCIIZ name.
;                    Out: HL = ASCIIZ value (in shared
;                         VAL_BUF, max 255 bytes).
;                         CF=0 found and non-empty;
;                         CF=1 missing or empty.
;
;   NETENV.GET_IP    In: HL = name; DE = 4-byte dest.
;                    Out: dest filled, CF=0 ok;
;                         CF=1 missing/parse error.
;
;   NETENV.GET_MAC   In: HL = name; DE = 6-byte dest.
;                    Out: dest filled, CF=0 ok;
;                         CF=1 missing/parse error.
;
;   NETENV.GET_STR   In: HL = name; DE = dest; B = max len
;                       (incl terminator, must be > 0).
;                    Out: dest = ASCIIZ. CF=0 ok;
;                         CF=1 missing (dest = "").
;
;   NETENV.GET_U16   In: HL = name.
;                    Out: HL = u16 value (LE pair).
;                         CF=0 ok; CF=1 missing/no digit.
;                         Overflow wraps (no saturation).
;
;   NETENV.REQUIRE_IP   As GET_IP; on miss prints
;                       "[E] env var <NAME> not set; run
;                       NETCFG -i first" and DSS_EXIT(B=4)
;                       via UTIL.EXIT_FAIL.
;   NETENV.REQUIRE_MAC  Same shape, for MAC.
;
; To use: DEFINE USE_NETENV before INCLUDE "netenv_lib.asm".
; The library transitively pulls UTIL parse helpers it
; needs.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_NETENV
	DEFINE	_NETENV

	INCLUDE "memmap.inc"

	IFDEF USE_NETENV
	IFNDEF USE_UTIL_PARSE_DEC_BYTE
	DEFINE USE_UTIL_PARSE_DEC_BYTE
	ENDIF
	IFNDEF USE_UTIL_PARSE_HEX_BYTE
	DEFINE USE_UTIL_PARSE_HEX_BYTE
	ENDIF
	IFNDEF USE_UTIL_EXIT
	DEFINE USE_UTIL_EXIT
	ENDIF
	ENDIF

	MODULE NETENV

	IFDEF USE_NETENV

; Internal value buffer shared by all NETENV.* getters --
; lives in runtime BSS (see src/include/memmap.inc), NOT in
; the .EXE image.  DSS limits env value length to 255; +1
; for terminator. Always written by GETENV before read, so
; no zero-init needed.
VAL_BUF		EQU NETENV_VAL_BUF


; ------------------------------------------------------
; GET_RAW: GETENV via DSS ENVIRON #46 / sub #01.
;   In:  HL = name (ASCIIZ).
;   Out: HL = ptr to value (in VAL_BUF, ASCIIZ).
;        CF=0 if found and value non-empty; CF=1 otherwise.
;   Trashes A, BC, DE.
; ------------------------------------------------------
GET_RAW
	LD	DE,VAL_BUF
	LD	B,ENV_GET		; #01
	LD	C,DSS_ENVIRON		; #46
	RST	DSS
	OR	A			; A=0xFF found, 0 not
	LD	HL,VAL_BUF
	JR	Z,.MISS
	LD	A,(HL)
	OR	A
	JR	Z,.MISS
	OR	A			; CF=0
	RET
.MISS
	SCF
	RET


; ------------------------------------------------------
; GET_IP: parse dotted-decimal IPv4.
;   In:  HL = name; DE = 4-byte dest.
;   Out: CF=0 dest filled; CF=1 missing/parse error
;        (dest may be partially written -- treat as garbage).
; ------------------------------------------------------
GET_IP
	PUSH	DE
	CALL	GET_RAW
	JR	C,.NF
	POP	DE
	PUSH	DE
	LD	B,4
.LP
	CALL	@UTIL.PARSE_DEC_BYTE
	JR	C,.BAD
	LD	(DE),A
	INC	DE
	DEC	B
	JR	Z,.OK
	LD	A,(HL)
	CP	'.'
	JR	NZ,.BAD
	INC	HL
	JR	.LP
.OK
	POP	DE
	OR	A
	RET
.BAD
.NF
	POP	DE
	SCF
	RET


; ------------------------------------------------------
; GET_MAC: parse aa:bb:cc:dd:ee:ff hex MAC.
;   In:  HL = name; DE = 6-byte dest.
;   Out: CF=0 dest filled; CF=1 missing/parse error.
; ------------------------------------------------------
GET_MAC
	PUSH	DE
	CALL	GET_RAW
	JR	C,.NF
	POP	DE
	PUSH	DE
	LD	B,6
.LP
	CALL	@UTIL.PARSE_HEX_BYTE
	JR	C,.BAD
	LD	(DE),A
	INC	DE
	DEC	B
	JR	Z,.OK
	LD	A,(HL)
	CP	':'
	JR	NZ,.BAD
	INC	HL
	JR	.LP
.OK
	POP	DE
	OR	A
	RET
.BAD
.NF
	POP	DE
	SCF
	RET


; ------------------------------------------------------
; GET_STR: copy ASCIIZ value into caller-provided buffer.
;   In:  HL = name; DE = dest; B = max len (including
;        terminator). B must be > 0.
;   Out: dest = ASCIIZ. CF=0 found; CF=1 missing.
; ------------------------------------------------------
GET_STR
	PUSH	DE
	PUSH	BC
	CALL	GET_RAW
	POP	BC
	POP	DE
	JR	C,.MISS
	; HL = source value, DE = dest, B = max len.
	DEC	B			; reserve room for terminator
.LP
	LD	A,B
	OR	A
	JR	Z,.TERM
	LD	A,(HL)
	OR	A
	JR	Z,.TERM
	LD	(DE),A
	INC	HL
	INC	DE
	DEC	B
	JR	.LP
.TERM
	XOR	A
	LD	(DE),A
	OR	A			; CF=0
	RET
.MISS
	XOR	A
	LD	(DE),A
	SCF
	RET


; ------------------------------------------------------
; GET_U16: parse decimal u16 (0..65535). Overflow wraps.
;   In:  HL = name.
;   Out: HL = value (LE pair); CF=0 ok.
;        CF=1 missing or no digit consumed.
; ------------------------------------------------------
GET_U16
	CALL	GET_RAW
	RET	C
	PUSH	BC
	LD	D,H
	LD	E,L			; DE = src ptr
	LD	HL,0			; accumulator
	LD	B,0			; digit count
.LP
	LD	A,(DE)
	SUB	'0'
	JR	C,.END
	CP	10
	JR	NC,.END
	PUSH	DE
	PUSH	AF
	ADD	HL,HL			; HL *= 2
	PUSH	HL
	POP	DE			; DE = HL*2
	ADD	HL,HL			; HL *= 4
	ADD	HL,HL			; HL *= 8
	ADD	HL,DE			; HL = orig*10
	POP	AF
	LD	D,0
	LD	E,A
	ADD	HL,DE
	POP	DE
	INC	DE
	INC	B
	JR	.LP
.END
	LD	A,B
	OR	A
	POP	BC
	JR	Z,.NODIG
	OR	A			; CF=0
	RET
.NODIG
	SCF
	RET


; ------------------------------------------------------
; REQUIRE_IP / REQUIRE_MAC: GET_IP/GET_MAC; on miss print
; "[E] env var <NAME> not set; run NETCFG -i first" and
; exit B=4 (config error). Never returns on miss.
; ------------------------------------------------------
REQUIRE_IP
	PUSH	HL			; save name ptr for error msg
	CALL	GET_IP
	JR	C,_MISSING
	POP	HL
	RET

REQUIRE_MAC
	PUSH	HL
	CALL	GET_MAC
	JR	C,_MISSING
	POP	HL
	RET

_MISSING
	; Stack top = name ptr.
	LD	HL,_MSG_PRE
	LD	C,DSS_PCHARS
	RST	DSS
	POP	HL			; HL = name
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,_MSG_POST
	LD	C,DSS_PCHARS
	RST	DSS
	LD	B,4
	JP	@UTIL.EXIT_FAIL

_MSG_PRE	DB "[E] env var ",0
_MSG_POST	DB " not set; run NETCFG -i first",13,10,0


	ENDIF

	ENDMODULE
	ENDIF
