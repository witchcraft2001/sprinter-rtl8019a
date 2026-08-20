; ======================================================
; ISAPROBE.EXE - ISA bus diagnostic for Sprinter.
;
; Modes:
;   ISAPROBE                   safe 0x000..0x3FF map of both slots
;   ISAPROBE -s N              safe 0x000..0x3FF map of slot N
;   ISAPROBE -n BASE [-s N]    safe NE/DP8390 page-0/page-1 snapshot
;   ISAPROBE -d ADDR [LEN]     hex dump of LEN bytes at I/O ADDR
;                              (ADDR/LEN are hex; LEN default 0x10)
;   ISAPROBE -o FILE [-s N]    raw 16 KB binary window to FILE
;   ISAPROBE /?                this help
;
; The Sprinter ISA window is 14 bits wide (16 KB), mapping
; I/O 0x0000..0x3FFF to memory 0xC000..0xFFFF after ISA_OPEN.
; The default activity map deliberately stops at 0x3FF.  Explicit
; -d and -o modes can still access the wider window when required.
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

WINDOW_BYTES		EQU 0x4000		; 16 KB I/O window
BLOCK_SIZE		EQU 32			; activity-map granularity
BLOCK_PROBE_BYTES	EQU 16			; avoid NE2000 data/reset ports
; Default map is intentionally limited to conventional 10-bit ISA I/O.
; Many old cards decode only A0..A9, so probing 0x400+ reaches aliases of
; live registers.  UM9003AF at 0x300 can hold IOCHRDY on its 0x700 alias.
BLOCKS_PER_LINE		EQU 32			; 32 * 32 = 1024 bytes
LINES_TOTAL		EQU 1			; safe map: I/O 0x0000..0x03FF

CHUNK_SIZE		EQU 512			; file write chunk

NE_CR_PAGE0_STOP	EQU 0x21		; page 0, stop, abort remote DMA
NE_CR_PAGE1_STOP	EQU 0x61		; page 1, stop, abort remote DMA

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
	DW 0x8000			; entry stack in WIN1 (own page);
					; START moves it into WIN2
	DS 234, 0

	ORG 0x4200

START
	CLAIM_RUNTIME_PAGE		; WIN2 is the caller's page until this runs
	LD	(CMDL_SOURCE_PTR),IX	; must precede every CALL/RST DSS
	LD	A,0xFF
	LD	(OUT_FH),A
	PRINTLN MSG_BANNER

	CALL	@CMDL.PARSE
	CALL	@CMDL.IS_HELP
	JP	NC,SHOW_HELP

	; Mode dispatch -- use GET_FLAG_VALUE so the flag's value
	; token is captured in HL on the same call (HAS_FLAG would
	; consume the flag and a subsequent GET_FLAG_VALUE would
	; then miss it).  -n takes priority, then -d, -o, else map.
	LD	A,'n'
	CALL	@CMDL.GET_FLAG_VALUE
	JP	NC,MODE_NECORE		; HL -> BASE string
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

	; Safe default map: conventional ISA I/O 0000..03FF.
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

	; Inner: 32 blocks per line.
	LD	C,BLOCKS_PER_LINE
.BLOCK_LP
	PUSH	BC
	PUSH	HL
	; Keep each ISA mapping bracket short.  In particular, DSS_PUTCHAR
	; must run only after ISA_CLOSE restored the system page-3 mapping.
	CALL	@ISA.ISA_OPEN
	CALL	CLASSIFY_BLOCK	; in: HL, out: A = '.', '0', or 'X'
	CALL	@ISA.ISA_CLOSE
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

	RET


; ------------------------------------------------------
; CLASSIFY_BLOCK: sample the first 16 bytes of a 32-byte block at HL.
; The second half of a NE2000 block contains the DMA data port and reset
; port.  Merely reading BASE+0x1F can change device state, so the default
; activity map must not touch it.
;   '.' if all bytes == 0xFF
;   '0' if all bytes == 0x00
;   'X' otherwise (live: at least two distinct values seen,
;       OR one stable non-trivial value)
; HL preserved.  Trashes A, BC, DE.
; ------------------------------------------------------
CLASSIFY_BLOCK
	PUSH	HL
	LD	B,BLOCK_PROBE_BYTES
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
	; Default 0x10: page-0 register core only.  A 0x20 dump would also
	; read the NE2000 DMA data and reset ports.
	LD	BC,0x10
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

	; Walk dump bytes 16 at a time.  Capture each row with ISA mapped,
	; close the window, then format it through DSS.
	LD	BC,(DUMP_ADDR)
	LD	HL,ISA_BASE_A
	ADD	HL,BC
	LD	(SRC_PTR),HL
	LD	BC,(DUMP_LEN)
	LD	(DUMP_REMAIN),BC
.LP
	LD	BC,(DUMP_REMAIN)
	LD	A,B
	OR	C
	JR	Z,.DONE

	; ROW_LEN = min(remaining, 16).
	LD	A,B
	OR	A
	JR	NZ,.FULL_ROW
	LD	A,C
	CP	16
	JR	C,.HAVE_ROW_LEN
.FULL_ROW
	LD	A,16
.HAVE_ROW_LEN
	LD	(ROW_LEN),A

	; Capture row into ordinary Z80 RAM while ISA is open.
	CALL	@ISA.ISA_OPEN
	LD	HL,(SRC_PTR)
	LD	DE,CHUNK_BUF
	LD	A,(ROW_LEN)
	LD	C,A
	LD	B,0
	CALL	COPY_FROM_ISA
	LD	(SRC_PTR),HL
	CALL	@ISA.ISA_CLOSE

	CALL	DUMP_ROW

	; Advance printable I/O address and remaining byte count.
	LD	A,(ROW_LEN)
	LD	E,A
	LD	D,0
	LD	HL,(DUMP_ADDR)
	ADD	HL,DE
	LD	(DUMP_ADDR),HL
	LD	HL,(DUMP_REMAIN)
	OR	A
	SBC	HL,DE
	LD	(DUMP_REMAIN),HL
	JR	.LP
.DONE
	JP	@UTIL.EXIT_OK


; ------------------------------------------------------
; MODE_NECORE: -n BASE [-s N]
; Select standard DP8390 page 0 and page 1 and capture the first 16
; registers from each.  No reset, DMA data-port or BASE+0x1F access.
; This is a destructive STOP/page-select operation, but leaves the core
; stopped on page 0 and is safe for pre-driver hardware identification.
; ------------------------------------------------------
MODE_NECORE
	CALL	PARSE_HEX_WORD
	JP	C,USAGE_ERROR
	LD	(DUMP_ADDR),BC

	CALL	GET_SLOT_OR_DEFAULT
	LD	(@ISA.ISA_SLOT),A

	PRINT	MSG_NE_PRE
	LD	BC,(DUMP_ADDR)
	CALL	PRINT_HEX_WORD_BC
	PRINT	MSG_DUMP_SLOT
	LD	A,(@ISA.ISA_SLOT)
	ADD	A,'0'
	CALL	PUTCHAR
	PRINT	LINE_END

	LD	BC,(DUMP_ADDR)
	LD	HL,ISA_BASE_A
	ADD	HL,BC
	LD	(SRC_PTR),HL

	; Raw CR before anything is written.
	CALL	@ISA.ISA_OPEN
	LD	HL,(SRC_PTR)
	LD	A,(HL)
	LD	(NE_RAW_CR),A
	CALL	@ISA.ISA_CLOSE
	PRINT	MSG_NE_RAW
	LD	A,(NE_RAW_CR)
	CALL	PRINT_HEX_BYTE
	PRINT	LINE_END

	; Recovery-delay sweep.  The vendor's own DOS driver for the UMC
	; UM9003AF puts THREE `in al,61h` bus cycles (~3 us) between every
	; pair of register writes, and LANSET.EXE exposes a /T=rate knob
	; "on un-stable machines" whose history notes the I/O timing was
	; tripled "for some critical machines".  The old fixed two NOPs
	; here are ~0.4 us, so a clone that needs real recovery time looks
	; identical to a dead write path: reads return plausible values and
	; the page-select write appears to be ignored.  Sweep instead of
	; guessing -- the first delay that works is the answer, and "none
	; of them works" is an equally useful result that rules timing out.
	PRINTLN	MSG_NE_SWEEP
	XOR	A
	LD	(SWEEP_IDX),A
.SWEEP
	LD	A,(SWEEP_IDX)
	CP	NE_WAIT_COUNT
	JP	NC,.SWEEP_DONE
	LD	E,A
	LD	D,0
	LD	HL,NE_WAIT_TABLE
	ADD	HL,DE
	LD	A,(HL)
	LD	(NE_WAIT),A

	; Capture everything first; DSS is called only after ISA_CLOSE.
	CALL	@ISA.ISA_OPEN
	LD	HL,(SRC_PTR)
	LD	(HL),NE_CR_PAGE0_STOP
	CALL	NE_SETTLE
	LD	HL,(SRC_PTR)
	LD	DE,NE_PAGE0
	LD	BC,16
	CALL	COPY_FROM_ISA

	LD	HL,(SRC_PTR)
	LD	(HL),NE_CR_PAGE1_STOP
	CALL	NE_SETTLE
	LD	HL,(SRC_PTR)
	LD	DE,NE_PAGE1
	LD	BC,16
	CALL	COPY_FROM_ISA

	; Leave the generic DP8390 stopped, page 0, remote DMA aborted.
	LD	HL,(SRC_PTR)
	LD	(HL),NE_CR_PAGE0_STOP
	CALL	@ISA.ISA_CLOSE

	; One line per delay: "  w=NNN P0=HH P1=HH ok|--"
	PRINT	MSG_NE_W
	LD	A,(NE_WAIT)
	CALL	PRINT_HEX_BYTE
	PRINT	MSG_NE_WP0
	LD	A,(NE_PAGE0)
	CALL	PRINT_HEX_BYTE
	PRINT	MSG_NE_WP1
	LD	A,(NE_PAGE1)
	CALL	PRINT_HEX_BYTE
	CALL	NE_CHECK_PAGES		; CF=0 when page select took effect
	JR	C,.SWEEP_BAD
	PRINTLN	MSG_NE_WOK
	JP	.SWEEP_HIT
.SWEEP_BAD
	PRINTLN	MSG_NE_WNO
	LD	A,(SWEEP_IDX)
	INC	A
	LD	(SWEEP_IDX),A
	JP	.SWEEP

.SWEEP_HIT
	CALL	NE_PRINT_PAGES
	PRINT	MSG_NE_OK
	LD	A,(NE_WAIT)
	CALL	PRINT_HEX_BYTE
	PRINT	LINE_END
	JP	@UTIL.EXIT_OK

.SWEEP_DONE
	; Nothing in the table worked.  Show the last capture in full so a
	; screenshot still carries the register contents, and report the
	; largest delay tried -- that is what rules the timing theory out.
	CALL	NE_PRINT_PAGES
	PRINT	MSG_NE_FAIL
	LD	A,(NE_PAGE0)
	CALL	PRINT_HEX_BYTE
	LD	A,'/'
	CALL	PUTCHAR
	LD	A,(NE_PAGE1)
	CALL	PRINT_HEX_BYTE
	PRINT	MSG_NE_MAXW
	LD	A,(NE_WAIT)
	CALL	PRINT_HEX_BYTE
	PRINT	LINE_END
	LD	B,EX_NIC_ERR
	JP	@UTIL.EXIT_FAIL

; NE_CHECK_PAGES: validate only page-select and STOP bits.  Remote-DMA
; command bits are implementation-dependent on readback.
;   Out: CF=0 page select took effect; CF=1 mismatch.
NE_CHECK_PAGES
	LD	A,(NE_PAGE0)
	AND	0xC3
	CP	0x01
	JR	NZ,.NO
	LD	A,(NE_PAGE1)
	AND	0xC3
	CP	0x41
	JR	NZ,.NO
	OR	A
	RET
.NO
	SCF
	RET

; NE_PRINT_PAGES: dump both captured register pages.  ISA must be closed.
NE_PRINT_PAGES
	PRINT	MSG_NE_P0
	LD	HL,NE_PAGE0
	CALL	PRINT_16_BYTES
	PRINT	MSG_NE_P1
	LD	HL,NE_PAGE1
	CALL	PRINT_16_BYTES
	RET

; NE_SETTLE: NE_WAIT DJNZ iterations of pure CPU delay.  Calls nothing,
; so it is safe with the ISA window open (no DSS, no page-3 remap).
; NE_WAIT = 0 reproduces the historical "no delay" behaviour.
NE_SETTLE
	PUSH	BC
	LD	A,(NE_WAIT)
	OR	A
	JR	Z,.DONE
	LD	B,A
.SD
	DJNZ	.SD
.DONE
	POP	BC
	RET

; Delay ladder in DJNZ iterations.  At the Sprinter's clock one
; iteration is well under a microsecond, so 0xFF still lands far above
; the ~3 us the vendor driver uses -- if even that fails, the write path
; is not a recovery-time problem.
NE_WAIT_TABLE	DB 0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0xFF
NE_WAIT_COUNT	EQU 10


; DUMP_ROW: print one captured row "AAAA: HH HH ... | ASCII".
; Input is DUMP_ADDR, ROW_LEN and CHUNK_BUF.  ISA must be closed.
DUMP_ROW
	LD	BC,(DUMP_ADDR)
	CALL	PRINT_HEX_WORD_BC
	LD	A,':'
	CALL	PUTCHAR
	LD	A,' '
	CALL	PUTCHAR

	; Hex part, padded to 16 columns.
	LD	HL,CHUNK_BUF
	LD	A,(ROW_LEN)
	LD	C,A			; bytes left to print
	LD	B,16			; columns left
.HEX_LP
	LD	A,C
	OR	A
	JR	Z,.HEX_PAD
	LD	A,(HL)
	CALL	PRINT_HEX_BYTE
	LD	A,' '
	CALL	PUTCHAR
	INC	HL
	DEC	C
	DEC	B
	JR	NZ,.HEX_LP
	JR	.HEX_END
.HEX_PAD
	; Pad with "   " for missing bytes.
	LD	A,' '
	CALL	PUTCHAR
	CALL	PUTCHAR
	CALL	PUTCHAR
	DEC	B
	JR	NZ,.HEX_PAD
.HEX_END
	; '|' separator.
	LD	A,'|'
	CALL	PUTCHAR
	LD	A,' '
	CALL	PUTCHAR

	; ASCII part from the captured row.
	LD	HL,CHUNK_BUF
	LD	A,(ROW_LEN)
	LD	B,A
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
	CALL	PUTCHAR
	INC	HL
	DEC	B
	JR	NZ,.ASC_LP
.ASC_END
	PRINT LINE_END
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
	CALL	COPY_FROM_ISA
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
; COPY_FROM_ISA: copy BC bytes from mapped ISA memory at HL to RAM at DE.
; ISA must already be open.  Do not use Z80 block-transfer instructions
; here: real Sprinter + UM9003AF completed scalar reads in activity-map but
; stalled when the same registers were read with LDIR.
; Out: HL/DE advanced, BC=0.  Trashes AF.
; ------------------------------------------------------
COPY_FROM_ISA
	LD	A,B
	OR	C
	RET	Z
.LP
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.LP
	RET


; HL -> 16 captured bytes in ordinary RAM.  ISA must be closed.
PRINT_16_BYTES
	LD	B,16
.LP
	LD	A,(HL)
	CALL	PRINT_HEX_BYTE
	LD	A,' '
	CALL	PUTCHAR
	INC	HL
	DJNZ	.LP
	PRINT	LINE_END
	RET


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
MSG_BANNER	DB "ISAPROBE v",PACKAGE_VERSION,0
MSG_SLOT_PRE	DB "Slot ",0
MSG_SLOT_POST	DB " activity map 0000..03FF (32-byte blocks, sample16; .=FF 0=00 X=live)",13,10,0
MSG_DUMP_PRE	DB "Hex dump @ I/O 0x",0
MSG_DUMP_LEN	DB " len 0x",0
MSG_DUMP_SLOT	DB " slot ",0
MSG_NE_PRE	DB "NE core @ I/O 0x",0
MSG_NE_RAW	DB "[N0] RAW CR=",0
MSG_NE_P0	DB "[N1] PAGE0 ",0
MSG_NE_P1	DB "[N2] PAGE1 ",0
MSG_NE_OK	DB "[N3] CR page select OK at wait=",0
MSG_NE_FAIL	DB "[E] CR page select mismatch P0/P1=",0
MSG_NE_SWEEP	DB "[N*] recovery-delay sweep (wait = DJNZ count)",0
MSG_NE_W	DB "  w=",0
MSG_NE_WP0	DB " P0=",0
MSG_NE_WP1	DB " P1=",0
MSG_NE_WOK	DB " ok",0
MSG_NE_WNO	DB " --",0
MSG_NE_MAXW	DB " at max wait=",0
MSG_FILE_PRE	DB "Writing 16 KB ISA window to ",0
MSG_FILE_DONE	DB "Done.",0
MSG_USAGE_ERR	DB "[E] usage error -- see help below.",0
MSG_E_FILE	DB "[E] file create / write / close failed.",0
MSG_HELP
	DB "Usage:",13,10
	DB "  ISAPROBE                 safe 0000..03FF map of both slots",13,10
	DB "  ISAPROBE -s N            safe 0000..03FF map of slot N",13,10
	DB "  ISAPROBE -n BASE [-s N]  safe NE page-0/page-1 snapshot",13,10
	DB "  ISAPROBE -d ADDR [LEN]   hex dump LEN bytes at I/O ADDR (hex)",13,10
	DB "  ISAPROBE -o FILE [-s N]  16 KB raw window to FILE",13,10
	DB "  ISAPROBE /?              this help",13,10,13,10
	DB "ADDR / LEN are hex (0x prefix optional). Default LEN 0x10.",13,10
	DB "Default slot for -d / -o is 1.",13,10
	DB "WARNING: wide -d / -o reads may access the 14-bit window.",13,10
	DB "  Partial address decoding can alias live registers and hang",13,10
	DB "  a bus cycle; side-effect reads may reset a device.  Prefer",13,10
	DB "  the safe map, then dump only a discovered 32-byte block.",13,10,0
LINE_END	DB 13,10,0

	ENDMODULE


	INCLUDE "win2page.asm"
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
DUMP_REMAIN	EQU APP_BSS_BASE + 11		; 2
ROW_LEN		EQU APP_BSS_BASE + 13		; 1
CHUNK_BUF	EQU APP_BSS_BASE + 16		; CHUNK_SIZE
NE_RAW_CR	EQU CHUNK_BUF			; 1
NE_PAGE0	EQU CHUNK_BUF + 1		; 16
NE_PAGE1	EQU CHUNK_BUF + 17		; 16
NE_WAIT		EQU CHUNK_BUF + 33		; 1  current sweep delay
SWEEP_IDX	EQU CHUNK_BUF + 34		; 1  index into NE_WAIT_TABLE
