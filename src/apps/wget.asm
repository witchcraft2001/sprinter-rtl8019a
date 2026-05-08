; ======================================================
; WGET.EXE - stage 9 of the Sprinter RTL8019AS network kit.
;
;   WGET url [-o output]
;   WGET /?
;
; Stage 1 (this build): URL parse, resolve, ARP target,
; TCP 3-way handshake.  Prints "Connected" on ESTABLISHED
; and exits OK.  Send / receive / file write arrive in
; later stages.
;
; URL syntax: http://host[:port][/path]   (lowercase or
; uppercase "http" both accepted; default port 80, default
; path "/").
; ======================================================

EXE_VERSION		EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "memmap.inc"
	INCLUDE "rtl8019.inc"
	INCLUDE "sprinter.inc"		; PAGE0/PAGE3 ports for pagemem use

	DEFINE USE_UTIL_EXIT_NO_NIC
	DEFINE USE_RTL_INIT_NORMAL
	DEFINE USE_RTL_SEND_FRAME
	DEFINE USE_RTL_WAIT_PTX
	DEFINE USE_RTL_RING_HAS_PACKET
	DEFINE USE_RTL_READ_PACKET
	DEFINE USE_ARP_BUILD_REQUEST
	DEFINE USE_NETENV
	DEFINE USE_CMDL
	DEFINE USE_RESOLVE
	DEFINE USE_TCP
	DEFINE USE_FILE
	DEFINE USE_UTIL_PRINT_DEC_32
	DEFINE USE_UTIL_TPUT
	DEFINE CMDLINE_AT_LARGE

ARP_TIMEOUT_MS	EQU 3000
SCAN_C		EQU 0xAC

ETH_TYPE_ARP	EQU 0x0806
ETH_TYPE_IPV4	EQU 0x0800
ARP_OP_REPLY	EQU 2

ARP_FRAME_LEN	EQU 60
IP_HDR_LEN	EQU 20

HOST_BUF_SIZE	EQU 64
PATH_BUF_SIZE	EQU 256

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

	XOR	A
	LD	(CANCELLED),A

	CALL	@CMDL.PARSE
	CALL	@CMDL.IS_HELP
	JP	NC,SHOW_HELP

	; positional 0: URL
	LD	B,0
	CALL	@CMDL.GET_POSITIONAL
	JP	C,USAGE_ERROR
	CALL	PARSE_URL
	JP	C,USAGE_ERROR

	; -o: optional output filename override
	LD	A,'o'
	CALL	@CMDL.GET_FLAG_VALUE
	JR	C,.NO_OUT
	LD	(OUTPUT_PTR),HL
	JR	.OUT_DONE
.NO_OUT
	; Default: derive from path basename.
	CALL	DERIVE_OUTPUT
.OUT_DONE

	; -y / --yes: force overwrite without prompt.
	XOR	A
	LD	(FORCE_FLAG),A
	LD	A,'y'
	CALL	@CMDL.HAS_FLAG
	JR	C,.NO_FORCE
	LD	A,1
	LD	(FORCE_FLAG),A
.NO_FORCE

	; Pull NET_IP, NET_MAC.
	LD	HL,N_NET_IP
	LD	DE,OUR_IP
	CALL	@NETENV.REQUIRE_IP
	LD	HL,N_NET_MAC
	LD	DE,OUR_MAC
	CALL	@NETENV.REQUIRE_MAC

	; Allocate the 32 KB paged-RAM disk-write buffer (2 frames).
	; Done before INIT_BASE because GETMEM is a DSS syscall and
	; we want the buffer ready before any chip activity starts.
	LD	B,2
	CALL	@PAGEMEM.ALLOC
	JP	C,PAGEMEM_FAIL
	LD	HL,0
	LD	(WGET_BUF_LEN),HL

	; Init NIC.
	LD	A,1
	LD	(@ISA.ISA_SLOT),A
	CALL	@RTL.INIT_BASE
	JP	C,@UTIL.EXIT_NO_NIC
	CALL	@RTL.RESET
	JP	C,RESET_FAIL
	LD	HL,OUR_MAC
	LD	A,RCR_AB
	CALL	@RTL.INIT_NORMAL
	LD	HL,OUR_MAC
	LD	(@ARP.OUR_MAC_PTR),HL
	LD	HL,OUR_IP
	LD	(@ARP.OUR_IP_PTR),HL

	; Resolve host.
	LD	HL,HOST_BUF
	LD	DE,TARGET_IP
	CALL	@RESOLVE.HOST
	JP	C,RESOLVE_FAIL

	; "Resolved host -> X.X.X.X port P"
	PRINT MSG_RESOLVED_PRE
	LD	HL,HOST_BUF
	LD	C,DSS_PCHARS
	RST	DSS
	PRINT MSG_TO
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINT MSG_PORT
	LD	HL,(PORT)
	CALL	PRINT_DEC_HL
	PRINT LINE_END

	; ARP target IP directly (assumes on-subnet for stage 1).
	LD	DE,TX_BUF
	LD	HL,TARGET_IP
	CALL	@ARP.BUILD_REQUEST
	LD	HL,TX_BUF
	LD	BC,ARP_FRAME_LEN
	CALL	@RTL.SEND_FRAME
	JP	C,SEND_FAIL
	LD	HL,ARP_TIMEOUT_MS
	LD	(TIMEOUT_MS_LEFT),HL
	CALL	WAIT_FOR_ARP_REPLY
	JP	C,ARP_TIMEOUT

	; Stage TCP state.
	LD	HL,TARGET_IP
	LD	DE,TCP_REMOTE_IP
	LD	BC,4
	LDIR
	LD	HL,TARGET_MAC
	LD	DE,TCP_REMOTE_MAC
	LD	BC,6
	LDIR
	LD	A,(PORT + 1)			; PORT stored LE; +1 = high byte
	LD	(TCP_REMOTE_PORT_HI),A
	LD	A,(PORT)
	LD	(TCP_REMOTE_PORT_LO),A

	; Connect.
	PRINT MSG_CONNECTING
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINT MSG_PORT
	LD	HL,(PORT)
	CALL	PRINT_DEC_HL
	PRINT MSG_DOTS
	CALL	@TCP.OPEN
	JP	C,TCP_OPEN_FAIL
	PRINTLN MSG_CONNECTED

	; Open output file (prompt-or-overwrite via @FILE.OPEN_OUTPUT).
	LD	A,NO_HANDLE
	LD	(OUT_FH),A
	LD	HL,(OUTPUT_PTR)
	LD	A,(FORCE_FLAG)
	CALL	@FILE.OPEN_OUTPUT
	JP	C,FILE_FAIL
	LD	(OUT_FH),A

	; Capture transfer-start timestamp for end-of-run KB/s metric.
	CALL	@UTIL.TPUT_START

	; Build and send GET request.
	CALL	BUILD_GET
	; HL = REQUEST_BUF, BC = length.
	CALL	@TCP.SEND
	JP	C,TCP_FAIL

	; Init HTTP parser + body counter + write buffer.
	XOR	A
	LD	(HSTATE),A
	LD	HL,0
	LD	(BODY_TOTAL_LO),HL
	LD	(BODY_TOTAL_HI),HL
	LD	(WGET_BUF_LEN),HL

	; Receive loop.
.RXLP
	CALL	@TCP.RECV
	JR	NC,.HAVE_DATA
	; CF=1: peer FIN or error.
	LD	A,(TCP_STATE)
	CP	2				; ST_ESTAB constant from tcp_lib
	JR	Z,.RXFAIL			; still ESTAB but CF=1 -> error
	; CLOSE_WAIT: maybe trailing data in this final segment.
	LD	HL,(TCP_RX_DATA_LEN)
	LD	A,H
	OR	L
	JR	Z,.DRAIN_DONE
	CALL	PROCESS_CHUNK
.DRAIN_DONE
	JR	.DONE_RX
.HAVE_DATA
	CALL	PROCESS_CHUNK
	; If RECV piggyback'd a FIN with this data segment,
	; TCP_STATE is already CLOSE_WAIT -- stop now instead
	; of looping back into another (timeout-bound) RECV.
	LD	A,(TCP_STATE)
	CP	3				; ST_CLOSE_WAIT
	JR	Z,.DONE_RX
	JR	.RXLP
.DONE_RX

	; Flush any buffered body bytes to disk.
	CALL	FLUSH_BUF
	JP	C,FILE_FAIL

	; Close output file.
	LD	A,(OUT_FH)
	CP	NO_HANDLE
	JR	Z,.NOCLOSE
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	LD	A,NO_HANDLE
	LD	(OUT_FH),A
.NOCLOSE
	; Close TCP cleanly.
	CALL	@TCP.CLOSE

	; Print summary.
	PRINT MSG_DONE_PRE
	LD	HL,(BODY_TOTAL_LO)
	LD	DE,(BODY_TOTAL_HI)
	CALL	@UTIL.PRINT_DEC_32
	PRINTLN MSG_BYTES
	LD	HL,(BODY_TOTAL_LO)
	LD	DE,(BODY_TOTAL_HI)
	CALL	@UTIL.TPUT_REPORT

	CALL	@ISA.ISA_CLOSE
	JP	@UTIL.EXIT_OK
.RXFAIL
	; Error during recv (timeout, RST, etc.)
	PRINT LINE_END
	PRINT MSG_E_RECV
	LD	A,(TCP_LAST_FAIL)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END
	; Best-effort close of file/conn.
	LD	A,(OUT_FH)
	CP	NO_HANDLE
	JR	Z,.RX_NF
	LD	C,DSS_CLOSE_FILE
	RST	DSS
.RX_NF
	JP	FAIL_NIC


; ------------------------------------------------------
; BUILD_GET: assemble HTTP/1.0 GET request in REQUEST_BUF.
; Returns HL = REQUEST_BUF, BC = total length.
; ------------------------------------------------------
BUILD_GET
	LD	DE,REQUEST_BUF
	LD	HL,LIT_GET
	LD	BC,LIT_GET_LEN
	LDIR
	LD	HL,PATH_BUF
	CALL	COPY_ASCIIZ
	LD	HL,LIT_HTTP
	LD	BC,LIT_HTTP_LEN
	LDIR
	LD	HL,LIT_HOST
	LD	BC,LIT_HOST_LEN
	LDIR
	LD	HL,HOST_BUF
	CALL	COPY_ASCIIZ
	LD	HL,LIT_REST
	LD	BC,LIT_REST_LEN
	LDIR
	; Compute final length = DE - REQUEST_BUF.
	LD	HL,REQUEST_BUF
	EX	DE,HL
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	LD	HL,REQUEST_BUF
	RET

LIT_GET		DB "GET "
LIT_GET_LEN	EQU $ - LIT_GET
LIT_HTTP	DB " HTTP/1.0",13,10
LIT_HTTP_LEN	EQU $ - LIT_HTTP
LIT_HOST	DB "Host: "
LIT_HOST_LEN	EQU $ - LIT_HOST
LIT_REST	DB 13,10,"Connection: close",13,10,13,10
LIT_REST_LEN	EQU $ - LIT_REST


COPY_ASCIIZ
.LP
	LD	A,(HL)
	OR	A
	RET	Z
	LD	(DE),A
	INC	HL
	INC	DE
	JR	.LP


; ------------------------------------------------------
; PROCESS_CHUNK: feed bytes through HTTP header state
; machine; once headers are skipped (HSTATE == 4), write
; the rest to OUT_FH and advance BODY_TOTAL.
;   Reads TCP_RX_DATA_PTR, TCP_RX_DATA_LEN.
; ------------------------------------------------------
PROCESS_CHUNK
	LD	HL,(TCP_RX_DATA_PTR)
	LD	BC,(TCP_RX_DATA_LEN)
	LD	A,B
	OR	C
	RET	Z
	LD	A,(HSTATE)
	CP	4
	JR	Z,.WRITE_ALL
	; Header parse loop.
.HLP
	LD	A,(HL)
	CALL	HDR_TRANSITION
	LD	A,(HSTATE)
	CP	4
	JR	Z,.HEND
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	RET	Z
	JR	.HLP
.HEND
	; The byte we just consumed is the final \n; body
	; starts at HL+1.
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	RET	Z
.WRITE_ALL
	; Append BC bytes from (HL) to the in-RAM file buffer;
	; the buffer is flushed to disk when full and at end
	; of stream, drastically reducing per-segment DSS I/O.
	JP	APPEND_TO_BUF


; ------------------------------------------------------
; APPEND_TO_BUF: append BC bytes from (HL) into the 32 KB
; paged-memory write buffer (2 logical pages, see PAGEMEM).
; Auto-flushes when adding the chunk would overflow.
;
; The buffer lives in a DSS-allocated 2-page block.  At call
; time ISA is OPEN (chip register window on PAGE3), so to
; copy bytes into the buffer we briefly map the relevant
; logical page into WIN0 (0x0000..0x3FFF) via direct PAGE0
; port writes -- DI bracketed because while WIN0 holds the
; user buffer, DSS code at 0x0000 is unreachable and any
; interrupt would crash.
;
; The copy is split into 256-byte bursts so the DI window
; stays in the millisecond range.
;   Out: CF=0 ok; CF=1 flush failure.
; Trashes A,BC,DE,HL.
; ------------------------------------------------------
APPEND_TO_BUF
	LD	A,B
	OR	C
	RET	Z
	; Body-byte counter: counts bytes that arrive at the
	; buffer regardless of whether a flush happens mid-copy.
	; Update once up-front; the actual append below cannot
	; partially fail (only FLUSH_BUF can fail, and we call
	; it before the copy starts).
	PUSH	HL
	PUSH	BC
	LD	HL,(BODY_TOTAL_LO)
	ADD	HL,BC
	LD	(BODY_TOTAL_LO),HL
	JR	NC,.NOC
	LD	HL,(BODY_TOTAL_HI)
	INC	HL
	LD	(BODY_TOTAL_HI),HL
.NOC
	; Would (buf_len + count) exceed WGET_FILE_BUF_SIZE (32K)?
	LD	HL,(WGET_BUF_LEN)
	ADD	HL,BC
	LD	DE,WGET_FILE_BUF_SIZE
	OR	A
	SBC	HL,DE
	JR	C,.FITS
	CALL	FLUSH_BUF
	JP	C,.FAIL
.FITS
	POP	BC
	POP	HL
	LD	(.SRC),HL
	LD	(.REMAIN),BC

.NEXT_CHUNK
	LD	HL,(.REMAIN)
	LD	A,H
	OR	L
	JP	Z,.ALL_DONE

	; page_idx = (WGET_BUF_LEN >> 14) & 1; offset = WGET_BUF_LEN & 0x3FFF.
	LD	HL,(WGET_BUF_LEN)
	LD	A,H
	AND	0x40
	JR	Z,.PG_0
	LD	A,1
	JR	.PG_DONE
.PG_0
	XOR	A
.PG_DONE
	LD	(.PG_IDX),A
	LD	A,H
	AND	0x3F
	LD	H,A			; HL = offset_in_page (0..0x3FFF)
	LD	(.OFFSET),HL

	; pg_avail = 0x4000 - offset
	EX	DE,HL			; DE = offset
	LD	HL,0x4000
	OR	A
	SBC	HL,DE			; HL = pg_avail (1..0x4000)

	; chunk = min(REMAIN, pg_avail).
	LD	DE,(.REMAIN)
	LD	A,H
	CP	D
	JR	C,.USE_HL
	JR	NZ,.USE_DE
	LD	A,L
	CP	E
	JR	C,.USE_HL
.USE_DE
	LD	HL,(.REMAIN)
	JR	.HAVE_CHUNK
.USE_HL
	; HL already holds the smaller value.
.HAVE_CHUNK
	; Cap chunk to 256 bytes so the DI/EI critical section
	; stays under ~1.5 ms.
	LD	A,H
	OR	A
	JR	Z,.NOCAP
	LD	HL,256
.NOCAP
	LD	(.CHUNK_LEN),HL

	; Get phys-page byte for current logical index.
	LD	A,(.PG_IDX)
	LD	B,A
	CALL	@PAGEMEM.PHYS_OF
	LD	(.MAP_PHYS),A
	; Save current PAGE0 byte (whatever DSS held there).
	CALL	@PAGEMEM.SAVE_PAGE0
	LD	(.SAVE_P0),A

	; ---- critical section: WIN0 displaced to user buffer ----
	DI
	LD	A,(.MAP_PHYS)
	LD	BC,PAGE0
	OUT	(C),A
	LD	HL,(.SRC)
	LD	DE,(.OFFSET)
	LD	BC,(.CHUNK_LEN)
	LDIR
	LD	A,(.SAVE_P0)
	LD	BC,PAGE0
	OUT	(C),A
	EI
	; ---------------------------------------------------------

	; Advance bookkeeping by chunk_len.
	LD	BC,(.CHUNK_LEN)
	LD	HL,(.SRC)
	ADD	HL,BC
	LD	(.SRC),HL
	LD	HL,(.REMAIN)
	OR	A
	SBC	HL,BC
	LD	(.REMAIN),HL
	LD	HL,(WGET_BUF_LEN)
	ADD	HL,BC
	LD	(WGET_BUF_LEN),HL

	JP	.NEXT_CHUNK

.ALL_DONE
	OR	A
	RET
.FAIL
	POP	BC
	POP	HL
	SCF
	RET

.SRC		DW 0
.REMAIN		DW 0
.OFFSET		DW 0
.CHUNK_LEN	DW 0
.PG_IDX		DB 0
.MAP_PHYS	DB 0
.SAVE_P0	DB 0


; ------------------------------------------------------
; FLUSH_BUF: write the buffered bytes to OUT_FH.  Buffer
; lives in 2 paged-RAM frames; we close the ISA window
; (DSS_WRITE needs PAGE3 free), then for each filled page
; ask DSS to map it into WIN3 and write up to 16 KB out of
; 0xC000.  Reopens ISA on success or failure.
;   Out: CF=0 ok; CF=1 DSS_WRITE error.
; ------------------------------------------------------
FLUSH_BUF
	LD	HL,(WGET_BUF_LEN)
	LD	A,H
	OR	L
	RET	Z
	CALL	@ISA.ISA_CLOSE

	; Decide split: page 0 (up to 16 KB), then page 1 if anything left.
	LD	HL,(WGET_BUF_LEN)
	LD	DE,0x4000
	OR	A
	SBC	HL,DE
	JR	NC,.SPLIT		; HL >= 16 KB after sub
	; All in page 0; restore HL to original count.
	LD	HL,(WGET_BUF_LEN)
	LD	(.PG0_LEN),HL
	LD	HL,0
	LD	(.PG1_LEN),HL
	JR	.WRITE_PAGES
.SPLIT
	; HL now = WGET_BUF_LEN - 16384 = page 1 length.
	LD	(.PG1_LEN),HL
	LD	HL,0x4000
	LD	(.PG0_LEN),HL

.WRITE_PAGES
	; Page 0.
	LD	A,(PAGEMEM_BLOCK_ID)
	LD	B,0
	LD	C,DSS_SETWIN3
	RST	DSS
	LD	HL,0xC000
	LD	DE,(.PG0_LEN)
	LD	A,(OUT_FH)
	LD	C,DSS_WRITE
	RST	DSS
	JR	C,.ERR

	; Page 1, if non-empty.
	LD	HL,(.PG1_LEN)
	LD	A,H
	OR	L
	JR	Z,.OK
	LD	A,(PAGEMEM_BLOCK_ID)
	LD	B,1
	LD	C,DSS_SETWIN3
	RST	DSS
	LD	HL,0xC000
	LD	DE,(.PG1_LEN)
	LD	A,(OUT_FH)
	LD	C,DSS_WRITE
	RST	DSS
	JR	C,.ERR

.OK
	LD	HL,0
	LD	(WGET_BUF_LEN),HL
	CALL	@ISA.ISA_OPEN
	OR	A
	RET
.ERR
	CALL	@ISA.ISA_OPEN
	SCF
	RET

.PG0_LEN	DW 0
.PG1_LEN	DW 0


; ------------------------------------------------------
; HDR_TRANSITION: advance HSTATE on byte A.
; Looks for "\r\n\r\n" sequence; once found HSTATE = 4.
; The byte is stashed in a memory slot to avoid clobbering
; B (which the caller uses as the high byte of the chunk
; counter).
; ------------------------------------------------------
HDR_TRANSITION
	LD	(.IN_BYTE),A
	LD	A,(HSTATE)
	OR	A
	JR	Z,.S0
	CP	1
	JR	Z,.S1
	CP	2
	JR	Z,.S2
	CP	3
	JR	Z,.S3
	RET				; >= 4: nothing
.S0
	LD	A,(.IN_BYTE)
	CP	13
	RET	NZ
	LD	A,1
	LD	(HSTATE),A
	RET
.S1
	LD	A,(.IN_BYTE)
	CP	10
	JR	NZ,.S1B
	LD	A,2
	LD	(HSTATE),A
	RET
.S1B
	CP	13
	JR	NZ,.S1C
	LD	A,1
	LD	(HSTATE),A
	RET
.S1C
	XOR	A
	LD	(HSTATE),A
	RET
.S2
	LD	A,(.IN_BYTE)
	CP	13
	JR	NZ,.S2B
	LD	A,3
	LD	(HSTATE),A
	RET
.S2B
	XOR	A
	LD	(HSTATE),A
	RET
.S3
	LD	A,(.IN_BYTE)
	CP	10
	JR	NZ,.S3B
	LD	A,4
	LD	(HSTATE),A
	RET
.S3B
	CP	13
	JR	NZ,.S3C
	LD	A,1
	LD	(HSTATE),A
	RET
.S3C
	XOR	A
	LD	(HSTATE),A
	RET
.IN_BYTE	DB 0


FILE_FAIL
	PRINT MSG_E_FILE
	PRINT LINE_END
	LD	A,(OUT_FH)
	CP	NO_HANDLE
	JR	Z,.NF
	LD	C,DSS_CLOSE_FILE
	RST	DSS
.NF
	CALL	@ISA.ISA_CLOSE
	LD	B,1
	JP	@UTIL.EXIT_FAIL


TCP_FAIL
	PRINT LINE_END
	PRINT MSG_E_TCP_SEND
	LD	A,(TCP_LAST_FAIL)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END
	JP	FAIL_NIC


; ------------------------------------------------------
; PARSE_URL: parse "http://host[:port][/path]" from (HL).
; Outputs HOST_BUF (ASCIIZ), PORT (LE u16), PATH_BUF (ASCIIZ).
;   Out: CF=0 ok; CF=1 invalid URL.
; ------------------------------------------------------
PARSE_URL
	; Check "http://" (case insensitive).
	LD	DE,URL_PFX
	LD	B,7
.PFX
	LD	A,(DE)
	INC	DE
	LD	C,A
	LD	A,(HL)
	OR	A
	JP	Z,.BAD
	CALL	TOLOWER
	CP	C
	JP	NZ,.BAD
	INC	HL
	DJNZ	.PFX
	; Copy host until ':', '/', or '\0' (cap at HOST_BUF_SIZE-1).
	LD	DE,HOST_BUF
	LD	B,HOST_BUF_SIZE - 1
.HOST
	LD	A,B
	OR	A
	JR	Z,.HOSTFULL
	LD	A,(HL)
	OR	A
	JR	Z,.HOSTEND
	CP	':'
	JR	Z,.HOSTEND
	CP	'/'
	JR	Z,.HOSTEND
	LD	(DE),A
	INC	DE
	INC	HL
	DEC	B
	JR	.HOST
.HOSTFULL
	; Skip rest until delimiter (don't write).
	LD	A,(HL)
	OR	A
	JR	Z,.HOSTEND
	CP	':'
	JR	Z,.HOSTEND
	CP	'/'
	JR	Z,.HOSTEND
	INC	HL
	JR	.HOSTFULL
.HOSTEND
	XOR	A
	LD	(DE),A
	; Default port.
	LD	BC,80
	LD	(PORT),BC
	; Check delimiter.
	LD	A,(HL)
	OR	A
	JR	Z,.DEFAULT_PATH
	CP	'/'
	JR	Z,.PATH
	CP	':'
	JR	NZ,.BAD
	INC	HL
	; Parse port: stash HL in .SRC, accumulate in HL'-style pattern.
	LD	(.SRC),HL
	LD	HL,0			; HL = port accumulator
.PORTLP
	LD	BC,(.SRC)
	LD	A,(BC)
	SUB	'0'
	JP	C,.PORTEND
	CP	10
	JP	NC,.PORTEND
	; HL = HL*10 + digit.
	LD	D,H
	LD	E,L
	ADD	HL,HL			; *2
	ADD	HL,HL			; *4
	ADD	HL,DE			; *5
	ADD	HL,HL			; *10
	LD	D,0
	LD	E,A
	ADD	HL,DE
	LD	BC,(.SRC)
	INC	BC
	LD	(.SRC),BC
	JR	.PORTLP
.PORTEND
	LD	(PORT),HL
	LD	HL,(.SRC)
	LD	A,(HL)
	OR	A
	JR	Z,.DEFAULT_PATH
	CP	'/'
	JR	NZ,.BAD
.PATH
	; Copy "/..." into PATH_BUF.
	LD	DE,PATH_BUF
	LD	B,PATH_BUF_SIZE - 1
.PCP
	LD	A,B
	OR	A
	JR	Z,.PEND
	LD	A,(HL)
	OR	A
	JR	Z,.PEND
	LD	(DE),A
	INC	DE
	INC	HL
	DEC	B
	JR	.PCP
.PEND
	XOR	A
	LD	(DE),A
	OR	A			; CF=0
	RET
.DEFAULT_PATH
	LD	HL,DEFAULT_PATH
	LD	DE,PATH_BUF
	LD	BC,2
	LDIR
	OR	A
	RET
.BAD
	SCF
	RET
.SRC	DW 0


URL_PFX		DB "http://"
DEFAULT_PATH	DB "/",0


; ------------------------------------------------------
; TOLOWER: A = ASCII char; if uppercase, lowercase it.
; ------------------------------------------------------
TOLOWER
	CP	'A'
	RET	C
	CP	'Z' + 1
	RET	NC
	ADD	A,32
	RET


; ------------------------------------------------------
; DERIVE_OUTPUT: pick output filename from PATH_BUF
; (basename after last '/').  Stub for stage 1: use
; "OUTPUT.BIN" placeholder.
; ------------------------------------------------------
DERIVE_OUTPUT
	LD	HL,DEFAULT_OUTPUT
	LD	(OUTPUT_PTR),HL
	RET

DEFAULT_OUTPUT	DB "OUTPUT.BIN",0


; ------------------------------------------------------
; WAIT_FOR_ARP_REPLY (matches TARGET_IP -> TARGET_MAC).
; ------------------------------------------------------
WAIT_FOR_ARP_REPLY
.LP
	CALL	@RTL.RING_HAS_PACKET
	JR	NZ,.HAVE
	CALL	TICK_AND_CHECK_KEY
	JR	C,.TIMEOUT
	LD	HL,(TIMEOUT_MS_LEFT)
	DEC	HL
	LD	(TIMEOUT_MS_LEFT),HL
	LD	A,H
	OR	L
	JR	NZ,.LP
	JR	.TIMEOUT
.HAVE
	LD	HL,RX_HDR
	LD	DE,RX_BUF
	LD	BC,RX_BUF_SIZE
	CALL	@RTL.READ_PACKET
	JR	C,.LP
	LD	A,(RX_BUF + 12)
	CP	HIGH ETH_TYPE_ARP
	JR	NZ,.LP
	LD	A,(RX_BUF + 13)
	CP	LOW ETH_TYPE_ARP
	JR	NZ,.LP
	LD	A,(RX_BUF + 14 + 6)
	OR	A
	JR	NZ,.LP
	LD	A,(RX_BUF + 14 + 7)
	CP	ARP_OP_REPLY
	JR	NZ,.LP
	LD	HL,RX_BUF + 14 + 14
	LD	DE,TARGET_IP
	LD	B,4
.CMPIP
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.LP
	INC	HL
	INC	DE
	DJNZ	.CMPIP
	LD	HL,RX_BUF + 14 + 8
	LD	DE,TARGET_MAC
	LD	BC,6
	LDIR
	OR	A
	RET
.TIMEOUT
	SCF
	RET


; ------------------------------------------------------
; TICK_AND_CHECK_KEY: ~1 ms wait + Esc/Ctrl+C poll.
; ------------------------------------------------------
TICK_AND_CHECK_KEY
	CALL	@UTIL.DELAY_1MS
	CALL	@ISA.ISA_CLOSE
	LD	C,DSS_SCANKEY
	RST	DSS
	JR	Z,.NO_KEY
	LD	A,E
	CP	0x1B
	JR	Z,.CANCEL
	LD	A,B
	AND	KB_CTRL | KB_L_CTRL | KB_R_CTRL
	JR	Z,.NO_KEY
	LD	A,D
	CP	SCAN_C
	JR	Z,.CANCEL
	JR	.NO_KEY
.CANCEL
	LD	A,1
	LD	(CANCELLED),A
	CALL	@ISA.ISA_OPEN
	SCF
	RET
.NO_KEY
	CALL	@ISA.ISA_OPEN
	OR	A
	RET


PAGEMEM_FAIL
	; PAGEMEM.ALLOC failed; ISA hasn't been touched yet so just
	; print + exit with a config-style status.
	PRINTLN MSG_E_PAGEMEM
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL

RESET_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_RESET
	JP	FAIL_NIC

SEND_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_SEND
	JP	FAIL_NIC

ARP_TIMEOUT
	LD	A,(CANCELLED)
	OR	A
	JR	NZ,.CAN
	PRINTLN MSG_E_ARP
	JP	FAIL_NIC
.CAN
	PRINTLN MSG_ABORTED
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL

TCP_OPEN_FAIL
	PRINT LINE_END
	PRINT MSG_E_TCP_OPEN
	LD	A,(TCP_LAST_FAIL)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END
	JP	FAIL_NIC

RESOLVE_FAIL
	PRINTLN MSG_E_RESOLVE
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL

FAIL_NIC
	CALL	@RTL.SNAPSHOT_REGS
	CALL	PRINT_REG_DUMP
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL


SHOW_HELP
	LD	HL,MSG_HELP
	LD	C,DSS_PCHARS
	RST	DSS
	JP	@UTIL.EXIT_OK


USAGE_ERROR
	PRINTLN MSG_USAGE_ERR
	LD	HL,MSG_HELP
	LD	C,DSS_PCHARS
	RST	DSS
	LD	B,1
	JP	@UTIL.EXIT_FAIL


PRINT_IPV4
	PUSH	HL,BC
	LD	B,4
.LP
	LD	A,(HL)
	CALL	PRINT_DEC_A
	INC	HL
	DEC	B
	JR	Z,.D
	PUSH	BC
	LD	A,'.'
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC
	JR	.LP
.D
	POP	BC,HL
	RET


PRINT_DEC_HL
	PUSH	HL
	LD	A,H
	OR	L
	JR	NZ,.NZ
	LD	A,'0'
	CALL	PUTCHAR
	POP	HL
	RET
.NZ
	LD	B,0
.LP
	LD	A,H
	OR	L
	JR	Z,.PRT
	PUSH	BC
	CALL	DIV_HL_10
	POP	BC
	ADD	A,'0'
	PUSH	AF
	INC	B
	JR	.LP
.PRT
	LD	A,B
	OR	A
	JR	Z,.D
.OL
	POP	AF
	CALL	PUTCHAR
	DJNZ	.OL
.D
	POP	HL
	RET

DIV_HL_10
	LD	BC,0
	LD	DE,16
.LP
	ADD	HL,HL
	RL	C
	LD	A,C
	CP	10
	JR	C,.NS
	SUB	10
	LD	C,A
	INC	L
.NS
	DEC	E
	JR	NZ,.LP
	LD	A,C
	RET


PRINT_DEC_A
	PUSH	AF,BC,DE,HL
	LD	C,A
	LD	HL,DEC_BUF + 5
	LD	(HL),0
.LP
	LD	A,C
	LD	B,0
.SUB
	CP	10
	JR	C,.GOT
	SUB	10
	INC	B
	JR	.SUB
.GOT
	ADD	A,'0'
	DEC	HL
	LD	(HL),A
	LD	C,B
	LD	A,B
	OR	A
	JR	NZ,.LP
	LD	C,DSS_PCHARS
	RST	DSS
	POP	HL,DE,BC,AF
	RET


PUTCHAR
	PUSH	AF,BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC,AF
	RET


PRINT_REG_DUMP
	PRINT MSG_REGS
	LD	HL,REG_NAMES
	LD	DE,@RTL.REG_SNAPSHOT
	LD	B,@RTL.REG_SNAPSHOT_LEN
.LP
	PUSH	BC,DE
.NCHR
	LD	A,(HL)
	INC	HL
	OR	A
	JR	Z,.ND
	CALL	PUTCHAR
	JR	.NCHR
.ND
	LD	A,'='
	CALL	PUTCHAR
	POP	DE,BC
	LD	A,(DE)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,' '
	CALL	PUTCHAR
	INC	DE
	DJNZ	.LP
	PRINT LINE_END
	RET

REG_NAMES
	DB "CR",0
	DB "ISR",0
	DB "DCR",0
	DB "RCR",0
	DB "TCR",0
	DB "IMR",0
	DB "PSTART",0
	DB "PSTOP",0
	DB "BNRY",0
	DB "CURR",0


N_NET_IP	DB "NET_IP",0
N_NET_MAC	DB "NET_MAC",0


NO_HANDLE	EQU 0xFF
REQUEST_BUF_SIZE EQU 256


; ------- runtime BSS -----------------------
OUR_IP		EQU APP_BSS_BASE		; 4
OUR_MAC		EQU APP_BSS_BASE + 4		; 6
TARGET_IP	EQU APP_BSS_BASE + 10		; 4
TARGET_MAC	EQU APP_BSS_BASE + 14		; 6
TIMEOUT_MS_LEFT	EQU APP_BSS_BASE + 20		; 2
PORT		EQU APP_BSS_BASE + 22		; 2 (LE)
OUTPUT_PTR	EQU APP_BSS_BASE + 24		; 2
CANCELLED	EQU APP_BSS_BASE + 26		; 1
OUT_FH		EQU APP_BSS_BASE + 27		; 1 (NO_HANDLE if closed)
HSTATE		EQU APP_BSS_BASE + 28		; 1 (HTTP header state)
BODY_TOTAL_LO	EQU APP_BSS_BASE + 29		; 2
BODY_TOTAL_HI	EQU APP_BSS_BASE + 31		; 2
DEC_BUF		EQU APP_BSS_BASE + 33		; 6
FORCE_FLAG	EQU APP_BSS_BASE + 39		; 1 (-y / --yes)
HOST_BUF	EQU APP_BSS_BASE + 64		; HOST_BUF_SIZE
PATH_BUF	EQU HOST_BUF + HOST_BUF_SIZE	; PATH_BUF_SIZE
REQUEST_BUF	EQU PATH_BUF + PATH_BUF_SIZE	; REQUEST_BUF_SIZE
WGET_BUF_LEN	EQU REQUEST_BUF + REQUEST_BUF_SIZE	; 2 bytes


MSG_BANNER	DB "RTL8019AS WGET v0.2.1",0
MSG_RESOLVED_PRE DB "Resolved ",0
MSG_TO		DB " -> ",0
MSG_PORT	DB " port ",0
MSG_CONNECTING	DB "Connecting to ",0
MSG_DOTS	DB "...",0
MSG_CONNECTED	DB "ESTABLISHED.",0
MSG_REGS	DB "REGS ",0
MSG_ABORTED	DB "Aborted by user (Esc/Ctrl+C).",0
MSG_E_RESET	DB "[E90] RESET timeout",0
MSG_E_PAGEMEM	DB "[E] could not allocate paged-RAM write buffer (DSS GETMEM failed).",0
MSG_E_SEND	DB "[E91] DMA write or PTX timeout",0
MSG_E_ARP	DB "ARP request timed out.",0
MSG_E_TCP_OPEN	DB "TCP connect failed, code 0x",0
MSG_E_TCP_SEND	DB "TCP send failed, code 0x",0
MSG_E_RECV	DB "TCP recv failed, code 0x",0
MSG_E_FILE	DB "[E] file create/write failed.",0
MSG_E_RESOLVE	DB "[E] could not resolve host.",0
MSG_DONE_PRE	DB "Done. ",0
MSG_BYTES	DB " bytes received.",0
MSG_USAGE_ERR	DB "[E] usage: missing or invalid URL",0
MSG_HELP
	DB "Usage:",13,10
	DB "  WGET url [-o output] [-y]",13,10
	DB "  WGET /?",13,10,13,10
	DB "  url     http://host[:port][/path]",13,10
	DB "  -o file write body to <file> (default: derived from URL).",13,10
	DB "  -y      overwrite local file without prompt.",13,10,0
LINE_END	DB 13,10,0

	ENDMODULE


	INCLUDE "netenv_lib.asm"
	INCLUDE "cmdline_lib.asm"
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"
	INCLUDE "arp_lib.asm"
	INCLUDE "resolve_lib.asm"
	INCLUDE "dns_lib.asm"
	INCLUDE "tcp_lib.asm"
	INCLUDE "file_lib.asm"
	INCLUDE "pagemem.asm"


WGET_IMAGE_END

RX_BUF_SIZE	EQU 1518

	MODULE MAIN

TX_BUF		EQU WGET_IMAGE_END
RX_HDR		EQU TX_BUF + TCP_MAX_FRAME
RX_BUF		EQU RX_HDR + 4
; The disk-write coalescing buffer lives in 2 paged-RAM frames
; (DSS-allocated at startup, see PAGEMEM_BLOCK_ID); only the
; size constant is referenced here.  No linear RAM consumed.
WGET_FILE_BUF_SIZE EQU 32768
WGET_BSS_END	EQU RX_BUF + RX_BUF_SIZE

	ENDMODULE

	END MAIN.START
