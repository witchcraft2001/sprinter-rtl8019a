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

	; Open output file once -- it stays empty across redirects
	; (body bytes are suppressed for non-2xx responses), and the
	; final 2xx hop fills it.
	LD	A,NO_HANDLE
	LD	(OUT_FH),A
	LD	HL,(OUTPUT_PTR)
	LD	A,(FORCE_FLAG)
	CALL	@FILE.OPEN_OUTPUT
	JP	C,FILE_FAIL
	LD	(OUT_FH),A

	; Total wall-clock includes any redirect hops -- start the
	; timer here, before the hop loop.
	CALL	@UTIL.TPUT_START

	XOR	A
	LD	(HOP_COUNT),A

; ====================================================================
; HOP_LOOP: one iteration per HTTP request.  3xx redirects parse the
; Location header into a fresh HOST_BUF / PATH_BUF / PORT and jump
; back here; 2xx falls through to .DONE_RX; 4xx/5xx jumps to HTTP_FAIL.
; ====================================================================
.HOP_LOOP
	; Resolve host.
	LD	HL,HOST_BUF
	LD	DE,TARGET_IP
	CALL	@RESOLVE.HOST
	JP	C,RESOLVE_FAIL

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

	; ARP the next hop and copy its MAC into TARGET_MAC.
	LD	HL,TARGET_IP
	CALL	@RESOLVE.NEXT_HOP_FOR
	JP	C,ARP_TIMEOUT
	LD	HL,RESOLVE_NEXT_HOP_MAC
	LD	DE,TARGET_MAC
	LD	BC,6
	LDIR

	; Stage TCP state.
	LD	HL,TARGET_IP
	LD	DE,TCP_REMOTE_IP
	LD	BC,4
	LDIR
	LD	HL,TARGET_MAC
	LD	DE,TCP_REMOTE_MAC
	LD	BC,6
	LDIR
	LD	A,(PORT + 1)
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

	; Build and send GET request.
	CALL	BUILD_GET
	CALL	@TCP.SEND
	JP	C,TCP_FAIL

	; Reset per-hop parser + buffer state.
	XOR	A
	LD	(HSTATE),A
	LD	(STATUS_DONE),A
	LD	(HTTP_ABORT),A
	LD	(HTTP_REDIRECT),A
	LD	(HDR_LINE_LEN),A
	LD	(REDIRECT_URL_BUF),A
	LD	HL,0
	LD	(STATUS_CODE),HL
	LD	(BODY_TOTAL_LO),HL
	LD	(BODY_TOTAL_HI),HL
	LD	(WGET_BUF_LEN),HL

	; Receive loop.
.RXLP
	CALL	@TCP.RECV
	JR	NC,.HAVE_DATA
	; CF=1: peer FIN or error.
	LD	A,(TCP_STATE)
	CP	2
	JP	Z,.RXFAIL
	LD	HL,(TCP_RX_DATA_LEN)
	LD	A,H
	OR	L
	JR	Z,.DRAIN_DONE
	CALL	PROCESS_CHUNK
.DRAIN_DONE
	JR	.HOP_RX_DONE
.HAVE_DATA
	CALL	PROCESS_CHUNK
	LD	A,(HTTP_ABORT)
	OR	A
	JP	NZ,HTTP_FAIL
	LD	A,(TCP_STATE)
	CP	3
	JR	Z,.HOP_RX_DONE
	JR	.RXLP
.HOP_RX_DONE
	; TCP closes either way -- next hop opens a fresh session.
	CALL	@TCP.CLOSE

	; If a 3xx was seen with a usable Location, follow it.
	LD	A,(HTTP_REDIRECT)
	OR	A
	JR	Z,.DONE_RX			; 2xx -> finish download
	; Was Location actually present?
	LD	A,(REDIRECT_URL_BUF)
	OR	A
	JP	Z,REDIRECT_NO_LOC
	; Hop budget.
	LD	A,(HOP_COUNT)
	CP	MAX_REDIRECT_HOPS
	JP	NC,REDIRECT_TOO_MANY
	INC	A
	LD	(HOP_COUNT),A
	; Parse Location into HOST_BUF / PATH_BUF / PORT.
	LD	HL,REDIRECT_URL_BUF
	CALL	APPLY_REDIRECT_URL
	JP	C,REDIRECT_BAD
	JP	.HOP_LOOP
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
	; (TCP already CLOSEd by .HOP_RX_DONE.)

	; Terminate the progress-dot line emitted by FLUSH_BUF, then
	; print summary.
	PRINT LINE_END
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
	JR	Z,.MAYBE_WRITE
	; Header parse loop.
.HLP
	LD	A,(HL)
	; Feed the byte first to the line capturer (which tracks
	; status line + every header line into HDR_LINE_BUF, parses
	; on \r, and may set HTTP_ABORT / HTTP_REDIRECT) and then to
	; the \r\n\r\n state machine.
	CALL	CAPTURE_HDR_BYTE
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
.MAYBE_WRITE
	; If status was 4xx/5xx (HTTP_ABORT) or 3xx (HTTP_REDIRECT,
	; body is the redirect HTML), suppress writing the body --
	; the main loop will either fail or follow the Location
	; URL on a fresh GET.
	LD	A,(HTTP_ABORT)
	OR	A
	RET	NZ
	LD	A,(HTTP_REDIRECT)
	OR	A
	RET	NZ
	; Append BC bytes from (HL) to the in-RAM file buffer;
	; the buffer is flushed to disk when full and at end
	; of stream, drastically reducing per-segment DSS I/O.
	JP	APPEND_TO_BUF


; ------------------------------------------------------
; CAPTURE_HDR_BYTE: accumulate one byte of the response into
; HDR_LINE_BUF (shared between the status line and every
; header line).  On CR the accumulated line is dispatched:
;   - first time (STATUS_DONE=0) -> PARSE_STATUS_LINE;
;     STATUS_DONE flips to 1.
;   - subsequent times          -> CHECK_LOCATION_HEADER.
; LF is silently skipped; appends past HDR_LINE_BUF_SIZE-1
; are dropped (truncate-on-overflow).
; Trashes A only -- BC, DE, HL preserved (PROCESS_CHUNK uses
; them as src ptr / remaining count across the call).
; ------------------------------------------------------
CAPTURE_HDR_BYTE
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	B,A
	CP	10
	JR	Z,.OUT			; ignore LF (only \r ends the line)
	CP	13
	JR	Z,.EOL
	; Append, with size cap.
	LD	A,(HDR_LINE_LEN)
	CP	HDR_LINE_BUF_SIZE - 1
	JR	NC,.OUT
	LD	E,A
	LD	D,0
	LD	HL,HDR_LINE_BUF
	ADD	HL,DE
	LD	(HL),B
	LD	A,(HDR_LINE_LEN)
	INC	A
	LD	(HDR_LINE_LEN),A
	JR	.OUT
.EOL
	; Null-terminate the captured line.
	LD	A,(HDR_LINE_LEN)
	LD	E,A
	LD	D,0
	LD	HL,HDR_LINE_BUF
	ADD	HL,DE
	XOR	A
	LD	(HL),A
	; Dispatch.
	LD	A,(STATUS_DONE)
	OR	A
	JR	NZ,.HDR_DISPATCH
	CALL	PARSE_STATUS_LINE
	LD	A,1
	LD	(STATUS_DONE),A
	JR	.RESET
.HDR_DISPATCH
	CALL	CHECK_LOCATION_HEADER
.RESET
	XOR	A
	LD	(HDR_LINE_LEN),A
.OUT
	POP	HL
	POP	DE
	POP	BC
	RET


; ------------------------------------------------------
; CHECK_LOCATION_HEADER: HDR_LINE_BUF holds an ASCIIZ
; header line ("Name: value").  If the name (case-
; insensitive) is "location", copy the value into
; REDIRECT_URL_BUF and set HTTP_REDIRECT.
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
CHECK_LOCATION_HEADER
	; Compare HDR_LINE_BUF prefix with "location:".
	LD	HL,HDR_LINE_BUF
	LD	DE,LIT_LOCATION
.PFX
	LD	A,(DE)
	OR	A
	JR	Z,.PFX_OK		; matched whole prefix
	LD	C,A			; expected (already lowercase)
	LD	A,(HL)
	OR	A
	RET	Z
	CALL	TOLOWER
	CP	C
	RET	NZ			; mismatch -> not Location
	INC	HL
	INC	DE
	JR	.PFX
.PFX_OK
	; HL now past "Location:".  Skip leading whitespace.
.SKIPSP
	LD	A,(HL)
	CP	' '
	JR	Z,.ADV
	CP	9
	JR	NZ,.COPY
.ADV
	INC	HL
	JR	.SKIPSP
.COPY
	LD	DE,REDIRECT_URL_BUF
	LD	B,REDIRECT_URL_BUF_SIZE - 1
.CL
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
	JR	.CL
.TERM
	XOR	A
	LD	(DE),A
	LD	A,1
	LD	(HTTP_REDIRECT),A
	RET

LIT_LOCATION	DB "location:",0


; ------------------------------------------------------
; PARSE_STATUS_LINE: read HDR_LINE_BUF ("HTTP/1.x NNN ...")
; and put the 16-bit numeric code into STATUS_CODE.
;   200..299 -> success, no flag set.
;   300..399 -> HTTP_REDIRECT=1; main loop will look for the
;               Location header and re-issue GET.
;   else     -> HTTP_ABORT=1, "[E] <line>" printed.
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
PARSE_STATUS_LINE
	LD	HL,HDR_LINE_BUF
	; Find the first space after "HTTP/1.x".
.FSP
	LD	A,(HL)
	OR	A
	RET	Z			; malformed: leave both flags clear
	CP	' '
	JR	Z,.SAW_SP
	INC	HL
	JR	.FSP
.SAW_SP
	INC	HL
.SKIP
	LD	A,(HL)
	CP	' '
	JR	NZ,.DIGITS
	INC	HL
	JR	.SKIP
.DIGITS
	LD	DE,0
.DLP
	LD	A,(HL)
	SUB	'0'
	JR	C,.DEND
	CP	10
	JR	NC,.DEND
	LD	B,A
	PUSH	HL
	LD	H,D
	LD	L,E
	ADD	HL,HL			; *2
	LD	D,H
	LD	E,L
	ADD	HL,HL			; *4
	ADD	HL,HL			; *8
	ADD	HL,DE			; *10
	LD	D,0
	LD	E,B
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	INC	HL
	JR	.DLP
.DEND
	LD	(STATUS_CODE),DE
	; Classify the 16-bit code via D/E (a single 8-bit CP would
	; truncate the 300/400 thresholds at 0x2C/0x90).
	LD	A,D
	CP	1
	JR	Z,.D1
	JR	NC,.NOT_2XX		; D >= 2 -> 5xx+ -> abort
	; D = 0 (codes 0..255): only 200..255 count as 2xx.
	LD	A,E
	CP	200
	JR	C,.NOT_2XX
	JR	.OK_2XX
.D1
	; D = 1 (codes 256..511).
	LD	A,E
	CP	44			; 256+44 = 300
	JR	C,.OK_2XX		; 256..299 -> 2xx
	CP	144			; 256+144 = 400
	JR	C,.IS_3XX		; 300..399 -> 3xx
.NOT_2XX
	; 1xx (unexpected in HTTP/1.0 reply) or 4xx/5xx -> abort.
	PRINT MSG_E_HTTP_PRE
	LD	HL,HDR_LINE_BUF
	LD	C,DSS_PCHARS
	RST	DSS
	PRINT LINE_END
	LD	A,1
	LD	(HTTP_ABORT),A
	RET
.IS_3XX
	; Mark redirect; the actual Location is captured later by
	; CHECK_LOCATION_HEADER.  Print the status line so the user
	; can see the redirect happening.
	PRINT MSG_REDIRECT_PRE
	LD	HL,HDR_LINE_BUF
	LD	C,DSS_PCHARS
	RST	DSS
	PRINT LINE_END
	; Tentatively mark redirect; cleared if Location is absent.
	LD	A,1
	LD	(HTTP_REDIRECT),A
.OK_2XX
	RET


; ------------------------------------------------------
; APPEND_TO_BUF: append BC bytes from (HL) to WGET_FILE_BUF.
; If the chunk would not fit, flush the current buffer
; first, then copy.  On flush errors returns CF=1.
; ------------------------------------------------------
APPEND_TO_BUF
	LD	A,B
	OR	C
	RET	Z
	; Would (buf_len + chunk_len) exceed buf_size?
	PUSH	HL
	PUSH	BC
	LD	HL,(WGET_BUF_LEN)
	ADD	HL,BC
	LD	DE,WGET_FILE_BUF_SIZE
	OR	A
	SBC	HL,DE			; CF=1 if (buf_len + count) < size
	JR	C,.FITS
	; Doesn't fit: flush first.
	CALL	FLUSH_BUF
	JR	C,.FAIL
.FITS
	POP	BC
	POP	HL
	; Copy chunk into buffer at offset WGET_BUF_LEN.
	LD	DE,(WGET_BUF_LEN)
	PUSH	HL
	LD	HL,WGET_FILE_BUF
	ADD	HL,DE
	EX	DE,HL			; DE = dst, HL = ?
	POP	HL			; HL = src
	PUSH	BC			; save count for body counter
	LDIR
	POP	BC
	; buf_len += count
	LD	HL,(WGET_BUF_LEN)
	ADD	HL,BC
	LD	(WGET_BUF_LEN),HL
	; body_total += count (32-bit)
	LD	HL,(BODY_TOTAL_LO)
	ADD	HL,BC
	LD	(BODY_TOTAL_LO),HL
	JR	NC,.NOC
	LD	HL,(BODY_TOTAL_HI)
	INC	HL
	LD	(BODY_TOTAL_HI),HL
.NOC
	OR	A
	RET
.FAIL
	POP	BC
	POP	HL
	SCF
	RET


; ------------------------------------------------------
; FLUSH_BUF: write the accumulated buffer to OUT_FH and
; reset the fill counter.  No-op when the buffer is empty.
;   Out: CF=0 ok; CF=1 DSS_WRITE error.
; ------------------------------------------------------
FLUSH_BUF
	LD	HL,(WGET_BUF_LEN)
	LD	A,H
	OR	L
	RET	Z
	; Console writes (DSS_PUTCHAR) need PAGE3 free, so close
	; ISA briefly just for the dot.  DSS_WRITE works fine with
	; ISA still open (source pointer is in PAGE2 linear RAM),
	; so keep it outside the close/open bracket -- one less MMU
	; toggle pair on a hot path.
	CALL	@ISA.ISA_CLOSE
	LD	A,'.'
	LD	C,DSS_PUTCHAR
	RST	DSS
	CALL	@ISA.ISA_OPEN
	LD	HL,(WGET_BUF_LEN)
	LD	D,H
	LD	E,L			; DE = byte count
	LD	HL,WGET_FILE_BUF
	LD	A,(OUT_FH)
	LD	C,DSS_WRITE
	RST	DSS
	RET	C
	LD	HL,0
	LD	(WGET_BUF_LEN),HL
	OR	A
	RET


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
; HTTP_FAIL: server returned a non-2xx status.  The error
; line was already printed by PARSE_STATUS_LINE.  Close
; gracefully (no flush -- the buffered bytes are the
; server's error body, not the user's file), delete the
; freshly-created output file so a 404 doesn't leave a
; truncated/empty file behind, then exit B=EX_NET_ERR.
; ------------------------------------------------------
HTTP_FAIL
	; Drop any body bytes we accidentally let in before the
	; abort flag was checked.
	LD	HL,0
	LD	(WGET_BUF_LEN),HL
	; Close + delete the output file.
	LD	A,(OUT_FH)
	CP	NO_HANDLE
	JR	Z,.NCL
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	LD	A,NO_HANDLE
	LD	(OUT_FH),A
.NCL
	LD	HL,(OUTPUT_PTR)
	LD	A,(HL)
	OR	A
	JR	Z,.NDEL
	LD	HL,(OUTPUT_PTR)
	LD	C,DSS_DELETE
	RST	DSS
.NDEL
	; TCP close (best-effort -- peer may already FIN).
	CALL	@TCP.CLOSE
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL


REDIRECT_NO_LOC
	PRINTLN MSG_E_NO_LOC
	JP	HTTP_FAIL

REDIRECT_BAD
	PRINTLN MSG_E_BAD_LOC
	JP	HTTP_FAIL

REDIRECT_TOO_MANY
	PRINTLN MSG_E_TOO_MANY
	JP	HTTP_FAIL


; ------------------------------------------------------
; APPLY_REDIRECT_URL: take a Location header value (ASCIIZ
; at HL) and update HOST_BUF / PATH_BUF / PORT in place.
;
; Two forms accepted:
;   - absolute "http://host[:port][/path]" -> PARSE_URL
;     replaces all three.
;   - path-only "/new/path"               -> only PATH_BUF
;     is rewritten; HOST_BUF and PORT carry over from the
;     previous hop.
;
; Anything else (relative path without leading slash, or a
; non-http scheme) returns CF=1 -- main loop fails the
; whole transfer.
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
APPLY_REDIRECT_URL
	; Try as full URL first.  PARSE_URL trashes HL on failure
	; via the "PFX" mismatch path, so save+restore.
	PUSH	HL
	CALL	PARSE_URL
	POP	HL
	JR	C,.NOT_FULL
	OR	A
	RET
.NOT_FULL
	; Detect https:// (case-insensitive) so the user gets a
	; clear "no TLS" error instead of a vague "cannot parse".
	PUSH	HL
	LD	DE,HTTPS_PFX
	LD	B,8
.PHL
	LD	A,(DE)
	OR	A
	JR	Z,.HTTPS
	LD	C,A
	LD	A,(HL)
	OR	A
	JR	Z,.NOT_HTTPS
	CALL	TOLOWER
	CP	C
	JR	NZ,.NOT_HTTPS
	INC	HL
	INC	DE
	JR	.PHL
.HTTPS
	POP	HL
	; HTTPS redirects can't be followed (no TLS).  Print the
	; specific message and jump straight to HTTP_FAIL so the
	; main-loop's generic "cannot parse Location" doesn't fire
	; on top.
	PRINTLN MSG_E_HTTPS
	JP	HTTP_FAIL
.NOT_HTTPS
	POP	HL
	; Path-only?  Must start with '/'.
	LD	A,(HL)
	CP	'/'
	JR	NZ,.BAD
	LD	DE,PATH_BUF
	LD	B,PATH_BUF_SIZE - 1
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
	OR	A
	RET
.BAD
	SCF
	RET


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
HTTPS_PFX	DB "https://",0
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
STATUS_DONE	EQU APP_BSS_BASE + 40		; 1 (1 once status line parsed)
HTTP_ABORT	EQU APP_BSS_BASE + 41		; 1 (1 if status 4xx/5xx)
STATUS_CODE	EQU APP_BSS_BASE + 42		; 2 (parsed numeric code)
HDR_LINE_LEN	EQU APP_BSS_BASE + 44		; 1 (current line capture fill)
HTTP_REDIRECT	EQU APP_BSS_BASE + 45		; 1 (1 if status 3xx + Location)
HOP_COUNT	EQU APP_BSS_BASE + 46		; 1 (redirect hops so far)
HDR_LINE_BUF_SIZE EQU 256
REDIRECT_URL_BUF_SIZE EQU 256
MAX_REDIRECT_HOPS EQU 5
HOST_BUF	EQU APP_BSS_BASE + 64		; HOST_BUF_SIZE
PATH_BUF	EQU HOST_BUF + HOST_BUF_SIZE	; PATH_BUF_SIZE
REQUEST_BUF	EQU PATH_BUF + PATH_BUF_SIZE	; REQUEST_BUF_SIZE
WGET_BUF_LEN	EQU REQUEST_BUF + REQUEST_BUF_SIZE	; 2 bytes
HDR_LINE_BUF	EQU WGET_BUF_LEN + 2		; HDR_LINE_BUF_SIZE bytes
REDIRECT_URL_BUF EQU HDR_LINE_BUF + HDR_LINE_BUF_SIZE	; REDIRECT_URL_BUF_SIZE bytes


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
MSG_E_SEND	DB "[E91] DMA write or PTX timeout",0
MSG_E_ARP	DB "ARP request timed out.",0
MSG_E_TCP_OPEN	DB "TCP connect failed, code 0x",0
MSG_E_TCP_SEND	DB "TCP send failed, code 0x",0
MSG_E_RECV	DB "TCP recv failed, code 0x",0
MSG_E_FILE	DB "[E] file create/write failed.",0
MSG_E_HTTP_PRE	DB "[E] ",0
MSG_REDIRECT_PRE DB "Redirect: ",0
MSG_E_NO_LOC	DB "[E] redirect with no Location header",0
MSG_E_BAD_LOC	DB "[E] cannot parse redirect Location",0
MSG_E_TOO_MANY	DB "[E] too many redirects (cap = 5)",0
MSG_E_HTTPS	DB "[E] redirect to https:// is not supported (no TLS).",0
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


WGET_IMAGE_END

RX_BUF_SIZE	EQU 1518

	MODULE MAIN

TX_BUF		EQU WGET_IMAGE_END
RX_HDR		EQU TX_BUF + TCP_MAX_FRAME
RX_BUF		EQU RX_HDR + 4
; 8 KB write-coalescing buffer placed in directly-addressable
; RAM after the RX area; flushed to disk on overflow and at
; end of stream to amortise DSS_WRITE per-call overhead.
WGET_FILE_BUF_SIZE EQU 8192
WGET_FILE_BUF	EQU RX_BUF + RX_BUF_SIZE
WGET_BSS_END	EQU WGET_FILE_BUF + WGET_FILE_BUF_SIZE

	ENDMODULE

	END MAIN.START
