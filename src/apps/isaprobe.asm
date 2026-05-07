; ======================================================
; ISAPROBE.EXE - ISA bus diagnostic for Sprinter.
;
; Modes:
;   ISAPROBE                   activity map of both ISA slots
;   ISAPROBE -s N              activity map of single slot (N=0/1)
;   ISAPROBE -d ADDR [LEN]     hex dump of LEN bytes at I/O ADDR
;                              (ADDR/LEN are hex; LEN default 0x20)
;   ISAPROBE -o FILE [-s N]    raw 16 KB binary window to FILE
;   ISAPROBE /?                this help
;
; The Sprinter ISA window is 14 bits wide (16 KB), mapping
; I/O 0x0000..0x3FFF to memory 0xC000..0xFFFF after ISA_OPEN.
; ISAPROBE walks that whole window.
;
; WARNING: reading some ISA registers has side effects --
; e.g. RTL8019AS reset port at BASE+0x1F triggers chip reset
; on read.  Run ISAPROBE only when diagnosing absence of a
; response, not against an actively running device.
;
; License: BSD 3-Clause
; ======================================================

EXE_VERSION		EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "memmap.inc"
	INCLUDE "isa.inc"

	DEFINE USE_UTIL_EXIT
	DEFINE USE_CMDL
	DEFINE USE_FILE
	DEFINE CMDLINE_AT_LARGE

WINDOW_BYTES		EQU 0x4000		; 16 KB I/O window
BLOCK_SIZE		EQU 32			; activity-map granularity
BLOCKS_PER_LINE		EQU 64			; 64 * 32 = 2048 bytes/line
LINES_TOTAL		EQU 8			; 8 * 2048 = 16 KB

CHUNK_SIZE		EQU 512			; file write chunk

EX_USAGE		EQU 1
EX_NIC_ERR		EQU 3			; not used here, but kept consistent
EX_FILE			EQU 5

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
	DS 234, 0

	ORG 0x4200

START
	PRINTLN MSG_BANNER

	CALL	@CMDL.PARSE
	CALL	@CMDL.IS_HELP
	JP	NC,SHOW_HELP

	; Mode dispatch -- use GET_FLAG_VALUE so the flag's value
	; token is captured in HL on the same call (HAS_FLAG would
	; consume the flag and a subsequent GET_FLAG_VALUE would
	; then miss it).  -d takes priority, then -o, else map.
	LD	A,'d'
	CALL	@CMDL.GET_FLAG_VALUE
	JP	NC,MODE_DUMP		; HL -> ADDR string
	LD	A,'o'
	CALL	@CMDL.GET_FLAG_VALUE
	JP	NC,MODE_FILE		; HL -> FILE string
	JP	MODE_MAP


; ------------------------------------------------------
; MODE_MAP: print activity map for one or both slots.
; ------------------------------------------------------
MODE_MAP
	CALL	GET_SLOT_OR_BOTH
	; A = 0 / 1 / 0xFF (both)
	CP	0xFF
	JR	NZ,.SINGLE
	; Both slots.
	XOR	A
	CALL	MAP_ONE_SLOT
	LD	A,1
	CALL	MAP_ONE_SLOT
	JP	@UTIL.EXIT_OK
.SINGLE
	CALL	MAP_ONE_SLOT
	JP	@UTIL.EXIT_OK


; A = slot id.
MAP_ONE_SLOT
	PUSH	AF
	; Heading.
	PRINT MSG_SLOT_PRE
	POP	AF
	PUSH	AF
	ADD	A,'0'
	CALL	PUTCHAR
	PRINT MSG_SLOT_POST
	POP	AF
	LD	(@ISA.ISA_SLOT),A
	CALL	@ISA.ISA_OPEN

	; Outer line loop: 8 lines, each line covers 0x800 bytes.
	LD	HL,ISA_BASE_A		; window start
	LD	B,LINES_TOTAL
.LINE_LP
	PUSH	BC
	PUSH	HL
	; Print line addr (I/O addr = HL - ISA_BASE_A).
	LD	A,H
	SUB	HIGH ISA_BASE_A
	CALL	PRINT_HEX_BYTE
	LD	A,L
	CALL	PRINT_HEX_BYTE
	LD	A,':'
	CALL	PUTCHAR
	LD	A,' '
	CALL	PUTCHAR
	POP	HL

	; Inner: 64 blocks per line.
	LD	C,BLOCKS_PER_LINE
.BLOCK_LP
	PUSH	BC
	PUSH	HL
	CALL	CLASSIFY_BLOCK	; in: HL, out: A = '.', '0', or 'X'
	CALL	PUTCHAR
	POP	HL
	; Advance HL by BLOCK_SIZE.
	LD	DE,BLOCK_SIZE
	ADD	HL,DE
	POP	BC
	DEC	C
	JR	NZ,.BLOCK_LP

	; End of line.
	PUSH	HL
	PRINT LINE_END
	POP	HL
	POP	BC
	DJNZ	.LINE_LP

	CALL	@ISA.ISA_CLOSE
	RET


; ------------------------------------------------------
; CLASSIFY_BLOCK: read 32 bytes at HL.
;   '.' if all bytes == 0xFF
;   '0' if all bytes == 0x00
;   'X' otherwise (live: at least two distinct values seen,
;       OR one stable non-trivial value)
; HL preserved.  Trashes A, BC, DE.
; ------------------------------------------------------
CLASSIFY_BLOCK
	PUSH	HL
	LD	B,BLOCK_SIZE
	LD	A,(HL)
	LD	D,A			; D = first byte (reference)
	; flag: 0 = all-equal-to-D, 1 = saw difference
	LD	E,0
.LP
	LD	A,(HL)
	CP	D
	JR	Z,.SAME
	LD	E,1
.SAME
	INC	HL
	DJNZ	.LP
	POP	HL
	; Decide.
	LD	A,E
	OR	A
	JR	NZ,.MIXED
	; Uniform block: D holds the common value.
	LD	A,D
	CP	0xFF
	JR	Z,.DOT
	OR	A
	JR	Z,.ZERO
	; A single non-trivial repeating value still counts as activity
	; (e.g. a register that holds a constant after reset).
	JR	.MIXED
.DOT
	LD	A,'.'
	RET
.ZERO
	LD	A,'0'
	RET
.MIXED
	LD	A,'X'
	RET


; ------------------------------------------------------
; MODE_DUMP: -d ADDR [LEN] -- classic hex dump.
;   On entry: HL -> ADDR ASCIIZ (already consumed from cmdline).
; ------------------------------------------------------
MODE_DUMP
	CALL	PARSE_HEX_WORD		; in: HL, out: BC
	JP	C,USAGE_ERROR
	LD	(DUMP_ADDR),BC

	; Optional LEN: try to read positional 0 (may be the LEN).
	; Default 0x20.
	LD	BC,0x20
	LD	(DUMP_LEN),BC
	LD	B,0
	CALL	@CMDL.GET_POSITIONAL
	JR	C,.LEN_OK
	CALL	PARSE_HEX_WORD
	JR	C,.LEN_OK
	LD	A,B
	OR	C
	JR	Z,.LEN_OK
	LD	(DUMP_LEN),BC
.LEN_OK

	; Slot.
	CALL	GET_SLOT_OR_DEFAULT
	LD	(@ISA.ISA_SLOT),A
	; Heading.
	PRINT MSG_DUMP_PRE
	LD	BC,(DUMP_ADDR)
	CALL	PRINT_HEX_WORD_BC
	PRINT MSG_DUMP_LEN
	LD	BC,(DUMP_LEN)
	CALL	PRINT_HEX_WORD_BC
	PRINT MSG_DUMP_SLOT
	LD	A,(@ISA.ISA_SLOT)
	ADD	A,'0'
	CALL	PUTCHAR
	PRINT LINE_END

	CALL	@ISA.ISA_OPEN

	; Walk dump bytes 16 at a time.
	LD	BC,(DUMP_ADDR)
	; HL = ISA_BASE_A + ADDR
	LD	HL,ISA_BASE_A
	ADD	HL,BC
	LD	BC,(DUMP_LEN)
.LP
	LD	A,B
	OR	C
	JR	Z,.DONE
	; One row.
	CALL	DUMP_ROW	; uses HL ptr, BC remaining; returns advanced.
	JR	.LP
.DONE
	CALL	@ISA.ISA_CLOSE
	JP	@UTIL.EXIT_OK


; DUMP_ROW: print one row "AAAA: HH HH ... | ASCII".
; In:  HL = window ptr, BC = remaining bytes (at least 1)
; Out: HL += 16 (or BC), BC -= consumed
DUMP_ROW
	; Print I/O addr = HL - ISA_BASE_A.
	PUSH	BC
	PUSH	HL
	LD	A,H
	SUB	HIGH ISA_BASE_A
	CALL	PRINT_HEX_BYTE
	LD	A,L
	CALL	PRINT_HEX_BYTE
	LD	A,':'
	CALL	PUTCHAR
	LD	A,' '
	CALL	PUTCHAR
	POP	HL
	POP	BC

	; First pass: hex part, up to 16 bytes, padded.
	; Save HL,BC for ASCII pass.
	PUSH	BC
	PUSH	HL
	LD	D,16			; D = max bytes to print
	LD	E,0			; E = bytes actually printed
.HEX_LP
	LD	A,B
	OR	C
	JR	Z,.HEX_PAD
	LD	A,(HL)
	PUSH	HL
	PUSH	DE
	PUSH	BC
	CALL	PRINT_HEX_BYTE
	LD	A,' '
	CALL	PUTCHAR
	POP	BC
	POP	DE
	POP	HL
	INC	HL
	DEC	BC
	INC	E
	DEC	D
	JR	NZ,.HEX_LP
	JR	.HEX_END
.HEX_PAD
	; Pad with "   " for missing bytes.
	LD	A,' '
	CALL	PUTCHAR
	CALL	PUTCHAR
	CALL	PUTCHAR
	DEC	D
	JR	NZ,.HEX_PAD
.HEX_END
	; '|' separator.
	LD	A,'|'
	CALL	PUTCHAR
	LD	A,' '
	CALL	PUTCHAR

	; Restore HL,BC to row start; print E ASCII bytes.
	POP	HL
	POP	BC
	PUSH	BC
	PUSH	HL
	LD	D,E
	LD	A,D
	OR	A
	JR	Z,.ASC_END
.ASC_LP
	LD	A,(HL)
	CP	0x20
	JR	C,.DOT
	CP	0x7F
	JR	NC,.DOT
	JR	.SHOW
.DOT
	LD	A,'.'
.SHOW
	PUSH	HL
	PUSH	DE
	PUSH	BC
	CALL	PUTCHAR
	POP	BC
	POP	DE
	POP	HL
	INC	HL
	DEC	D
	JR	NZ,.ASC_LP
.ASC_END
	PRINT LINE_END
	; Re-pop HL/BC to advance them by the consumed count.
	POP	HL
	POP	BC
	; HL += E, BC -= E (E in low byte of saved DE; we've trashed DE
	; but we know E was up to 16 and equal to min(BC, 16) at the
	; start of the row).  Recompute consumed = min(BC, 16).
	LD	A,B
	OR	A
	JR	NZ,.GE16
	LD	A,C
	CP	16
	JR	C,.LT16
.GE16
	LD	A,16
.LT16
	; A = consumed bytes
	LD	E,A
	LD	D,0
	ADD	HL,DE
	; BC -= consumed
	LD	A,C
	SUB	E
	LD	C,A
	LD	A,B
	SBC	A,0
	LD	B,A
	RET


; ------------------------------------------------------
; MODE_FILE: -o FILE [-s N] -- raw 16 KB to file.
;   On entry: HL -> FILE ASCIIZ (already consumed from cmdline).
; ------------------------------------------------------
MODE_FILE
	LD	(OUTPUT_PTR),HL

	CALL	GET_SLOT_OR_DEFAULT
	LD	(@ISA.ISA_SLOT),A

	PRINT MSG_FILE_PRE
	LD	HL,(OUTPUT_PTR)
	LD	C,DSS_PCHARS
	RST	DSS
	PRINT MSG_DUMP_SLOT
	LD	A,(@ISA.ISA_SLOT)
	ADD	A,'0'
	CALL	PUTCHAR
	PRINT LINE_END

	; Open output via FILE.OPEN_OUTPUT (no -y here; always prompt
	; if the file exists).  FORCE flag passed as 0.
	LD	HL,(OUTPUT_PTR)
	XOR	A
	CALL	@FILE.OPEN_OUTPUT
	JP	C,FILE_FAIL
	LD	(OUT_FH),A

	; Write 16 KB in CHUNK_SIZE-byte chunks: open ISA, copy chunk
	; to scratch, close ISA, write chunk.
	LD	HL,ISA_BASE_A		; window source ptr
	LD	(SRC_PTR),HL
	LD	BC,WINDOW_BYTES / CHUNK_SIZE
	LD	(CHUNKS_LEFT),BC
.CHUNK_LP
	; Read CHUNK_SIZE bytes from window into CHUNK_BUF.
	CALL	@ISA.ISA_OPEN
	LD	HL,(SRC_PTR)
	LD	DE,CHUNK_BUF
	LD	BC,CHUNK_SIZE
	LDIR
	LD	(SRC_PTR),HL
	CALL	@ISA.ISA_CLOSE
	; Write to file.
	LD	A,(OUT_FH)
	LD	DE,CHUNK_SIZE
	LD	HL,CHUNK_BUF
	LD	C,DSS_WRITE
	RST	DSS
	JP	C,FILE_FAIL
	; Decrement chunk counter.
	LD	BC,(CHUNKS_LEFT)
	DEC	BC
	LD	(CHUNKS_LEFT),BC
	LD	A,B
	OR	C
	JR	NZ,.CHUNK_LP

	; Close file.
	LD	A,(OUT_FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	PRINTLN MSG_FILE_DONE
	JP	@UTIL.EXIT_OK


FILE_FAIL
	PRINTLN MSG_E_FILE
	; Best-effort close.
	LD	A,(OUT_FH)
	CP	0xFF
	JR	Z,.NF
	LD	C,DSS_CLOSE_FILE
	RST	DSS
.NF
	LD	B,EX_FILE
	JP	@UTIL.EXIT_FAIL


; ------------------------------------------------------
; GET_SLOT_OR_BOTH: A = 0, 1, or 0xFF (both).
; GET_SLOT_OR_DEFAULT: A = 0 or 1; default 1.
; ------------------------------------------------------
GET_SLOT_OR_BOTH
	LD	A,'s'
	CALL	@CMDL.GET_FLAG_VALUE
	JR	NC,.HAVE
	LD	A,0xFF
	RET
.HAVE
	; HL -> ASCIIZ digit
	LD	A,(HL)
	CP	'0'
	JR	Z,.S0
	CP	'1'
	JR	Z,.S1
	JP	USAGE_ERROR
.S0
	XOR	A
	RET
.S1
	LD	A,1
	RET

GET_SLOT_OR_DEFAULT
	CALL	GET_SLOT_OR_BOTH
	CP	0xFF
	RET	NZ
	LD	A,1
	RET


; ------------------------------------------------------
; PARSE_HEX_WORD: HL -> ASCIIZ "[0x]HHHH".  1..4 hex digits.
;   Out: BC = value, HL advanced.  CF=1 if no digit consumed.
; Trashes A,DE.
; ------------------------------------------------------
PARSE_HEX_WORD
	; Optional 0x / 0X prefix.
	LD	A,(HL)
	CP	'0'
	JR	NZ,.NOPRE
	INC	HL
	LD	A,(HL)
	OR	0x20
	CP	'x'
	JR	Z,.AFTX
	DEC	HL			; '0' was a digit, not prefix
	JR	.START
.AFTX
	INC	HL
.NOPRE
.START
	LD	BC,0
	LD	D,0			; D = digits parsed
.LP
	LD	A,(HL)
	; Hex digit?
	CP	'0'
	JR	C,.END
	CP	'9'+1
	JR	C,.D09
	CP	'A'
	JR	C,.END
	CP	'F'+1
	JR	C,.DAF
	CP	'a'
	JR	C,.END
	CP	'f'+1
	JR	NC,.END
	SUB	'a'-10
	JR	.ACC
.D09
	SUB	'0'
	JR	.ACC
.DAF
	SUB	'A'-10
.ACC
	; (BC << 4) | A
	PUSH	AF
	SLA	C
	RL	B
	SLA	C
	RL	B
	SLA	C
	RL	B
	SLA	C
	RL	B
	POP	AF
	OR	C
	LD	C,A
	INC	HL
	INC	D
	JR	.LP
.END
	LD	A,D
	OR	A
	RET	NZ			; CF=0
	SCF
	RET


; ------------------------------------------------------
; PUTCHAR: A -> screen via DSS_PUTCHAR. Preserves AF,BC,HL.
; ------------------------------------------------------
PUTCHAR
	PUSH	AF
	PUSH	BC
	PUSH	HL
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL
	POP	BC
	POP	AF
	RET


; ------------------------------------------------------
; PRINT_HEX_BYTE: A -> "HH" (2 chars) via PUTCHAR.
; PRINT_HEX_WORD_BC: BC -> "HHHH".
; ------------------------------------------------------
PRINT_HEX_BYTE
	PUSH	AF
	RRCA
	RRCA
	RRCA
	RRCA
	CALL	.NIB
	POP	AF
.NIB
	AND	0x0F
	ADD	A,'0'
	CP	'9'+1
	JR	C,.OUT
	ADD	A,'A'-'0'-10
.OUT
	JP	PUTCHAR

PRINT_HEX_WORD_BC
	LD	A,B
	CALL	PRINT_HEX_BYTE
	LD	A,C
	JP	PRINT_HEX_BYTE


; ------------------------------------------------------
; Error / help paths.
; ------------------------------------------------------
USAGE_ERROR
	PRINTLN MSG_USAGE_ERR
	LD	HL,MSG_HELP
	LD	C,DSS_PCHARS
	RST	DSS
	LD	B,EX_USAGE
	JP	@UTIL.EXIT_FAIL

SHOW_HELP
	LD	HL,MSG_HELP
	LD	C,DSS_PCHARS
	RST	DSS
	JP	@UTIL.EXIT_OK


; ------------------------------------------------------
; Messages.
; ------------------------------------------------------
MSG_BANNER	DB "ISAPROBE v0.1",0
MSG_SLOT_PRE	DB "Slot ",0
MSG_SLOT_POST	DB " activity map (each char = 32 bytes; .=FF 0=00 X=live)",13,10,0
MSG_DUMP_PRE	DB "Hex dump @ I/O 0x",0
MSG_DUMP_LEN	DB " len 0x",0
MSG_DUMP_SLOT	DB " slot ",0
MSG_FILE_PRE	DB "Writing 16 KB ISA window to ",0
MSG_FILE_DONE	DB "Done.",0
MSG_USAGE_ERR	DB "[E] usage error -- see help below.",0
MSG_E_FILE	DB "[E] file create / write / close failed.",0
MSG_HELP
	DB "Usage:",13,10
	DB "  ISAPROBE                 activity map of both ISA slots",13,10
	DB "  ISAPROBE -s N            single slot (N = 0 or 1)",13,10
	DB "  ISAPROBE -d ADDR [LEN]   hex dump LEN bytes at I/O ADDR (hex)",13,10
	DB "  ISAPROBE -o FILE [-s N]  16 KB raw window to FILE",13,10
	DB "  ISAPROBE /?              this help",13,10,13,10
	DB "ADDR / LEN are hex (0x prefix optional). Default LEN 0x20.",13,10
	DB "Default slot for -d / -o is 1.",13,10
	DB "WARNING: ISAPROBE READS the full 14-bit I/O window.  Active",13,10
	DB "  ISA devices (RTL8019AS in particular) may be reset or",13,10
	DB "  perturbed by side-effect reads.  Use only for diagnosing",13,10
	DB "  absent / unresponsive cards.",13,10,0
LINE_END	DB 13,10,0

	ENDMODULE


	INCLUDE "cmdline_lib.asm"
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "file_lib.asm"


; ------- runtime BSS -----------------------
DUMP_ADDR	EQU APP_BSS_BASE		; 2
DUMP_LEN	EQU APP_BSS_BASE + 2		; 2
OUTPUT_PTR	EQU APP_BSS_BASE + 4		; 2
OUT_FH		EQU APP_BSS_BASE + 6		; 1
SRC_PTR		EQU APP_BSS_BASE + 7		; 2
CHUNKS_LEFT	EQU APP_BSS_BASE + 9		; 2
CHUNK_BUF	EQU APP_BSS_BASE + 16		; CHUNK_SIZE
