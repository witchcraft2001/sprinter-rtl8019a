; ======================================================
; Command-line parser, DOS/Windows-style flags.
; - Flags: -x or /x, single ASCII char, case-insensitive.
; - Long flags (--xxx) are NOT supported.
; - Help: /?, -?, -h, /h.
;
; Tokens at 0x8080 are NUL-terminated in-place (whitespace
; replaced with 0). ARGV[i] points to token i in that buffer;
; CONSUMED[i] tracks per-token state.
;
; Typical use:
;   DEFINE USE_CMDL
;   INCLUDE "cmdline_lib.asm"
;
;   CALL @CMDL.PARSE
;
;   ; Help shortcut
;   CALL @CMDL.IS_HELP
;   JR   NC, show_help
;
;   ; Value flags first (consume their value tokens)
;   LD   A,'n'
;   CALL @CMDL.GET_FLAG_VALUE     ; CF=0 -> HL = "5"
;   ...
;
;   ; Boolean flags
;   LD   A,'t'
;   CALL @CMDL.HAS_FLAG           ; CF=0 -> -t was given
;
;   ; Positionals (skips consumed and -/...)
;   LD   B,0
;   CALL @CMDL.GET_POSITIONAL     ; CF=0 -> HL = "192.168.7.1"
;
; Storage: 49 bytes BSS-style (ARGC, ARGV[16], CONSUMED[16]).
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_CMDL
	DEFINE	_CMDL

	INCLUDE "memmap.inc"

; DSS places the command line at IX-0x80, where IX is the entry
; point.  For ORG 0x8080 / entry 0x8100 -> 0x8080 (small variant).
; For ORG 0x4100 / entry 0x4200 -> 0x4180 (large variant).
; Apps using the large variant must DEFINE CMDLINE_AT_LARGE
; BEFORE including cmdline_lib (selects 0x4180 instead of 0x8080).
	IFDEF CMDLINE_AT_LARGE
CMDLINE_AT	EQU 0x4180
	ELSE
CMDLINE_AT	EQU 0x8080
	ENDIF

	IFDEF USE_CMDL
	IFNDEF USE_UTIL_PARSE_DEC_BYTE
	DEFINE USE_UTIL_PARSE_DEC_BYTE
	ENDIF
	IFNDEF USE_UTIL_EXIT
	DEFINE USE_UTIL_EXIT
	ENDIF
	ENDIF

	MODULE CMDL

	IFDEF USE_CMDL

MAX_ARGS	EQU 16

; Storage lives in runtime BSS (memmap.inc), NOT in the .EXE.
; PARSE always rewrites ARGC and zeros CONSUMED at startup.
ARGC		EQU CMDL_ARGC
ARGV		EQU CMDL_ARGV
CONSUMED	EQU CMDL_CONSUMED


; ------------------------------------------------------
; PARSE: tokenize command line at 0x8080 in-place.
;   Trashes A,BC,DE,HL.
; ------------------------------------------------------
PARSE
	XOR	A
	LD	(ARGC),A
	LD	HL,CONSUMED
	LD	B,MAX_ARGS
.ZL
	LD	(HL),0
	INC	HL
	DJNZ	.ZL
	LD	HL,CMDLINE_AT
	LD	A,(HL)
	OR	A
	RET	Z			; empty cmdline
	LD	B,A			; B = bytes left
	INC	HL
.SCAN
	LD	A,B
	OR	A
	RET	Z
	LD	A,(HL)
	OR	A
	RET	Z
	CP	' '
	JR	Z,.SP
	CP	9
	JR	Z,.SP
	; Token start.
	CALL	APPEND
	JR	C,.RET
.WALK
	LD	A,B
	OR	A
	RET	Z
	LD	A,(HL)
	OR	A
	RET	Z
	CP	' '
	JR	Z,.TERM
	CP	9
	JR	Z,.TERM
	INC	HL
	DEC	B
	JR	.WALK
.TERM
	LD	(HL),0
	INC	HL
	DEC	B
	JR	.SCAN
.SP
	INC	HL
	DEC	B
	JR	.SCAN
.RET
	RET


; APPEND: append HL as ARGV[ARGC++].
;   Out: HL preserved. CF=1 if ARGV table full.
;   Trashes A.
APPEND
	PUSH	BC
	PUSH	HL
	LD	A,(ARGC)
	CP	MAX_ARGS
	JR	NC,.FULL
	LD	C,A
	LD	B,0
	SLA	C
	RL	B
	LD	HL,ARGV
	ADD	HL,BC
	POP	BC			; BC = ptr (was on stack)
	LD	(HL),C
	INC	HL
	LD	(HL),B
	LD	HL,ARGC
	INC	(HL)
	LD	H,B
	LD	L,C
	POP	BC
	OR	A
	RET
.FULL
	POP	HL
	POP	BC
	SCF
	RET


; ------------------------------------------------------
; GET_ARGV: A = index. Returns HL = token ptr.
;   Preserves BC, DE. Trashes A.
; (No bounds check.)
; ------------------------------------------------------
GET_ARGV
	PUSH	BC
	LD	C,A
	LD	B,0
	SLA	C
	RL	B
	LD	HL,ARGV
	ADD	HL,BC
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	POP	BC
	RET


; ------------------------------------------------------
; IS_CONSUMED: C = index. CF=1 if CONSUMED[C] != 0.
;   Preserves BC,DE,HL. Trashes A.
; ------------------------------------------------------
IS_CONSUMED
	PUSH	HL
	PUSH	DE
	LD	HL,CONSUMED
	LD	D,0
	LD	E,C
	ADD	HL,DE
	LD	A,(HL)
	OR	A
	POP	DE
	POP	HL
	JR	NZ,.YES
	OR	A
	RET
.YES
	SCF
	RET


; ------------------------------------------------------
; MARK_CONSUMED: C = index. Sets CONSUMED[C] = 1.
;   Preserves BC,DE,HL. Trashes A.
; ------------------------------------------------------
MARK_CONSUMED
	PUSH	HL
	PUSH	DE
	LD	HL,CONSUMED
	LD	D,0
	LD	E,C
	ADD	HL,DE
	LD	(HL),1
	POP	DE
	POP	HL
	RET


; TOLOWER: A -> lowercase if A-Z.
TOLOWER
	CP	'A'
	RET	C
	CP	'Z'+1
	JR	C,.LO
	RET
.LO
	ADD	A,'a'-'A'
	RET


; ------------------------------------------------------
; FIND_FLAG: locate first unconsumed ARGV entry equal to
; "-X" or "/X" (case-insensitive).
;   In:  A = flag char.
;   Out: CF=0, B = ARGV index, HL = token ptr; or CF=1.
;   Trashes A,BC,DE,HL.
; ------------------------------------------------------
FIND_FLAG
	CALL	TOLOWER
	LD	D,A			; D = wanted (lowercase)
	LD	C,0			; ARGV index
.LP
	LD	A,C
	LD	HL,ARGC
	CP	(HL)
	JR	NC,.NF
	CALL	IS_CONSUMED
	JR	C,.SKIP
	LD	A,C
	CALL	GET_ARGV		; HL = token; preserves BC
	LD	A,(HL)
	CP	'-'
	JR	Z,.PFX
	CP	'/'
	JR	NZ,.SKIP
.PFX
	INC	HL
	LD	A,(HL)
	OR	A
	JR	Z,.SKIP			; bare "-" / "/"
	CALL	TOLOWER
	CP	D
	JR	NZ,.SKIP
	INC	HL
	LD	A,(HL)
	OR	A
	JR	NZ,.SKIP		; "-xy", not "-x"
	; Found.
	LD	B,C
	LD	A,C
	CALL	GET_ARGV		; HL = token ptr
	OR	A
	RET
.SKIP
	INC	C
	JR	.LP
.NF
	SCF
	RET


; ------------------------------------------------------
; HAS_FLAG: CF=0 if -A or /A present (and consumed).
;   In: A = flag char. Trashes A,BC,DE,HL.
; ------------------------------------------------------
HAS_FLAG
	CALL	FIND_FLAG
	RET	C
	; B = index. Mark consumed.
	LD	C,B
	CALL	MARK_CONSUMED
	OR	A
	RET


; ------------------------------------------------------
; GET_FLAG_VALUE: CF=0 + HL = next token after -A/A.
; Both flag and value tokens are consumed on success.
;   In: A = flag char.
;   Out: CF=1 if absent or trailing.
;   Trashes A,BC,DE,HL.
; ------------------------------------------------------
GET_FLAG_VALUE
	CALL	FIND_FLAG
	RET	C
	; B = index of flag.
	LD	A,B
	INC	A
	LD	HL,ARGC
	CP	(HL)
	JR	NC,.NOVAL
	; Mark flag consumed.
	LD	C,B
	CALL	MARK_CONSUMED
	; Mark value consumed (index B+1).
	INC	C
	CALL	MARK_CONSUMED
	; Return value ptr.
	LD	A,C
	CALL	GET_ARGV
	OR	A
	RET
.NOVAL
	SCF
	RET


; ------------------------------------------------------
; GET_POSITIONAL: B = N. Returns the N-th unconsumed token
; that does NOT start with - or /.
;   Out: CF=0 + HL = ptr; CF=1 if not enough.
;   Trashes A,BC,DE,HL.
; ------------------------------------------------------
GET_POSITIONAL
	LD	C,0			; ARGV index
.LP
	LD	A,C
	LD	HL,ARGC
	CP	(HL)
	JR	NC,.NF
	CALL	IS_CONSUMED
	JR	C,.SKIP
	LD	A,C
	CALL	GET_ARGV		; HL = token (preserves BC)
	LD	A,(HL)
	CP	'-'
	JR	Z,.SKIP
	CP	'/'
	JR	Z,.SKIP
	; Positional. Match the N-th?
	LD	A,B
	OR	A
	JR	Z,.OK
	DEC	B
.SKIP
	INC	C
	JR	.LP
.OK
	OR	A
	RET
.NF
	SCF
	RET


; ------------------------------------------------------
; IS_HELP: CF=0 if any token is "/?", "-?", "-h", "/h".
;   Trashes A,BC,DE,HL.
; ------------------------------------------------------
IS_HELP
	LD	C,0
.LP
	LD	A,C
	LD	HL,ARGC
	CP	(HL)
	JR	NC,.NF
	LD	A,C
	CALL	GET_ARGV
	LD	A,(HL)
	CP	'-'
	JR	Z,.PFX
	CP	'/'
	JR	NZ,.SKIP
.PFX
	INC	HL
	LD	A,(HL)
	CP	'?'
	JR	Z,.HIT
	CALL	TOLOWER
	CP	'h'
	JR	Z,.HIT_NEXT
.SKIP
	INC	C
	JR	.LP
.HIT_NEXT
	; "-h" only if NUL after.
	INC	HL
	LD	A,(HL)
	OR	A
	JR	NZ,.SKIP
.HIT
	OR	A
	RET
.NF
	SCF
	RET


; ------------------------------------------------------
; PARSE_IPV4: HL = ASCIIZ; DE = 4-byte dest.
;   Out: dest filled, CF=0 ok; CF=1 parse error.
;   HL advanced; DE preserved.
;   Trashes A,BC.
; ------------------------------------------------------
PARSE_IPV4
	PUSH	DE
	LD	B,4
.LP
	PUSH	BC
	CALL	@UTIL.PARSE_DEC_BYTE	; trashes A,BC
	POP	BC
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
	LD	A,(HL)
	OR	A
	JR	NZ,.BAD			; trailing junk
	POP	DE
	OR	A
	RET
.BAD
	POP	DE
	SCF
	RET


; ------------------------------------------------------
; PARSE_U16: HL = ASCIIZ. Out: HL = u16; CF=0 ok / CF=1 bad.
;   Trashes A,BC,DE. Overflow wraps (no saturation).
; ------------------------------------------------------
PARSE_U16
	LD	D,H
	LD	E,L			; DE = src
	LD	HL,0			; accum
	LD	B,0			; digit count
.LP
	LD	A,(DE)
	OR	A
	JR	Z,.END
	SUB	'0'
	JR	C,.BAD
	CP	10
	JR	NC,.BAD
	PUSH	DE
	PUSH	AF
	ADD	HL,HL
	PUSH	HL
	POP	DE
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,DE
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
	JR	Z,.NODIG
	OR	A
	RET
.NODIG
.BAD
	SCF
	RET


; ------------------------------------------------------
; DIE_USAGE: print HL as ASCIIZ usage and exit B=1.
; ------------------------------------------------------
DIE_USAGE
	LD	C,DSS_PCHARS
	RST	DSS
	LD	B,1
	JP	@UTIL.EXIT_FAIL


	ENDIF

	ENDMODULE
	ENDIF
