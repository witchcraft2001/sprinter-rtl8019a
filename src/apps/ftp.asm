; ======================================================
; FTP.EXE - stage 10 of the Sprinter RTL8019AS network kit.
;
;   FTP host filename [-u user] [-p pass] [-o output] [-y]
;   FTP /?
;
; Stage 1 (this build): cmdline parse, NIC init, resolve,
; ARP, open control TCP to port 21, read server banner,
; close.  Login + PASV + RETR + data transfer arrive in
; later stages.
;
; Test server: pyftpdlib on the host.
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

FTP_CTRL_PORT	EQU 21

HOST_BUF_SIZE	EQU 64

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

	; --- Parse all flags FIRST so that GET_FLAG_VALUE consumes
	; their value tokens.  Otherwise something like
	;   FTP host -u alice -p secret PUT file.bin
	; would have GET_POSITIONAL B=1 return "alice" (the value
	; of -u, still unconsumed at that point) and we'd treat it
	; as the filename / verb.

	; -l / -n: directory-listing mode (no file download).
	XOR	A
	LD	(LIST_MODE),A
	LD	(NLST_MODE),A
	LD	A,'l'
	CALL	@CMDL.HAS_FLAG
	JR	C,.NO_LFLAG
	LD	A,1
	LD	(LIST_MODE),A
.NO_LFLAG
	LD	A,'n'
	CALL	@CMDL.HAS_FLAG
	JR	C,.NO_NFLAG
	LD	A,1
	LD	(LIST_MODE),A
	LD	(NLST_MODE),A
.NO_NFLAG

	; -y / --yes: force overwrite without prompt.
	XOR	A
	LD	(FORCE_FLAG),A
	LD	A,'y'
	CALL	@CMDL.HAS_FLAG
	JR	C,.NO_FORCE
	LD	A,1
	LD	(FORCE_FLAG),A
.NO_FORCE

	; -u user (optional, default = anonymous)
	XOR	A
	LD	(USER_OVERRIDE),A
	LD	A,'u'
	CALL	@CMDL.GET_FLAG_VALUE
	JR	C,.NO_USER
	LD	(USER_PTR),HL
	CALL	STRLEN_FROM_HL
	LD	(USER_LEN),A
	LD	A,1
	LD	(USER_OVERRIDE),A
	JR	.USER_OK
.NO_USER
	LD	HL,DEFAULT_USER
	LD	(USER_PTR),HL
	LD	A,DEFAULT_USER_LEN
	LD	(USER_LEN),A
.USER_OK

	; -p pass (optional)
	;   absent + -u absent -> "anonymous@" (legacy default).
	;   absent + -u given  -> empty (sending "anonymous@" with a
	;                         non-anonymous user is wrong).
	LD	A,'p'
	CALL	@CMDL.GET_FLAG_VALUE
	JR	C,.NO_PASS
	LD	(PASS_PTR),HL
	CALL	STRLEN_FROM_HL
	LD	(PASS_LEN),A
	JR	.PASS_OK
.NO_PASS
	LD	A,(USER_OVERRIDE)
	OR	A
	JR	NZ,.PASS_BLANK
	LD	HL,DEFAULT_PASS
	LD	(PASS_PTR),HL
	LD	A,DEFAULT_PASS_LEN
	LD	(PASS_LEN),A
	JR	.PASS_OK
.PASS_BLANK
	LD	HL,DEFAULT_PASS		; ptr unused when LEN=0
	LD	(PASS_PTR),HL
	XOR	A
	LD	(PASS_LEN),A
.PASS_OK

	; -o name (optional).  Stored for application after we
	; have determined GET vs PUT (the same flag flips the
	; local- or wire-side name depending on the mode).
	XOR	A
	LD	(HAS_OVR_O),A
	LD	A,'o'
	CALL	@CMDL.GET_FLAG_VALUE
	JR	C,.NO_O
	LD	(OVR_O_PTR),HL
	LD	A,1
	LD	(HAS_OVR_O),A
.NO_O

	; --- Now positionals.  Flag values are already marked
	; consumed, so GET_POSITIONAL skips over them.

	; positional 0: host.
	LD	B,0
	CALL	@CMDL.GET_POSITIONAL
	JP	C,USAGE_ERROR
	LD	A,(HL)
	OR	A
	JP	Z,USAGE_ERROR
	LD	(HOST_PTR),HL

	; positional 1: filename, "PUT" verb, or (in list mode) the
	; directory path -- the latter is optional.
	XOR	A
	LD	(PUT_MODE),A
	LD	B,1
	CALL	@CMDL.GET_POSITIONAL
	JR	NC,.HAVE_POS1
	; No positional: only valid in listing modes.
	LD	A,(LIST_MODE)
	OR	A
	JP	Z,USAGE_ERROR
	LD	HL,EMPTY_STR
	LD	(FILENAME_PTR),HL
	XOR	A
	LD	(FILENAME_LEN),A
	JR	.NAME_OK
.HAVE_POS1
	; Is positional 1 the keyword "PUT"?  If so the caller
	; wants an upload; the filename is positional 2.
	CALL	IS_PUT_KW
	JR	NZ,.NOT_PUT
	; PUT + listing flags don't combine.
	LD	A,(LIST_MODE)
	OR	A
	JP	NZ,USAGE_ERROR
	LD	A,1
	LD	(PUT_MODE),A
	LD	B,2
	CALL	@CMDL.GET_POSITIONAL
	JP	C,USAGE_ERROR
.NOT_PUT
	LD	A,(HL)
	OR	A
	JP	Z,USAGE_ERROR
	; Wire-side and local-side defaults depend on mode:
	;   GET: wire = positional verbatim (server path is OK);
	;        local = basename of positional, so a server-side
	;        `pub/foo.zip` saves as `foo.zip` in CWD instead
	;        of trying to CHDIR pub\ locally.
	;   PUT: local = positional verbatim (file_lib CHDIRs
	;        into the directory before opening); wire =
	;        basename only (server has no concept of DSS
	;        paths and would otherwise create
	;        `C:\docs\foo.bin`).
	; -o overrides whichever side is mode-relevant just below.
	LD	A,(PUT_MODE)
	OR	A
	JR	NZ,.PUT_NAMES
	; GET path.
	LD	(FILENAME_PTR),HL
	CALL	STRLEN_FROM_HL
	LD	(FILENAME_LEN),A
	LD	HL,(FILENAME_PTR)
	CALL	@FILE.BASENAME
	LD	(OUTPUT_PTR),HL
	JR	.NAME_OK
.PUT_NAMES
	; PUT path.
	LD	(OUTPUT_PTR),HL
	CALL	@FILE.BASENAME
	LD	(FILENAME_PTR),HL
	CALL	STRLEN_FROM_HL
	LD	(FILENAME_LEN),A
.NAME_OK

	; Apply -o (already parsed and stored above).
	; Listing modes ignore it.
	LD	A,(HAS_OVR_O)
	OR	A
	JR	Z,.OVR_DONE
	LD	A,(LIST_MODE)
	OR	A
	JR	NZ,.OVR_DONE
	LD	HL,(OVR_O_PTR)
	LD	A,(PUT_MODE)
	OR	A
	JR	NZ,.OVR_WIRE
	LD	(OUTPUT_PTR),HL
	JR	.OVR_DONE
.OVR_WIRE
	LD	(FILENAME_PTR),HL
	CALL	STRLEN_FROM_HL
	LD	(FILENAME_LEN),A
.OVR_DONE

	; Pull NET_IP / NET_MAC.
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

	; Resolve host -> TARGET_IP.
	LD	HL,(HOST_PTR)
	LD	DE,TARGET_IP
	CALL	@RESOLVE.HOST
	JP	C,RESOLVE_FAIL

	PRINT MSG_RESOLVED
	LD	HL,(HOST_PTR)
	LD	C,DSS_PCHARS
	RST	DSS
	PRINT MSG_TO
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINT LINE_END

	; ARP next hop for TARGET_IP (gateway when off-subnet) and
	; copy reply MAC into TARGET_MAC.
	LD	HL,TARGET_IP
	CALL	@RESOLVE.NEXT_HOP_FOR
	JP	C,ARP_TIMEOUT
	LD	HL,RESOLVE_NEXT_HOP_MAC
	LD	DE,TARGET_MAC
	LD	BC,6
	LDIR

	; Set up TCP control connection state.
	LD	HL,TARGET_IP
	LD	DE,TCP_REMOTE_IP
	LD	BC,4
	LDIR
	LD	HL,TARGET_MAC
	LD	DE,TCP_REMOTE_MAC
	LD	BC,6
	LDIR
	XOR	A
	LD	(TCP_REMOTE_PORT_HI),A
	LD	A,FTP_CTRL_PORT
	LD	(TCP_REMOTE_PORT_LO),A

	PRINT MSG_CONNECTING
	CALL	@TCP.OPEN
	JP	C,TCP_OPEN_FAIL
	PRINTLN MSG_CONNECTED

	; Read server banner (220 ... \r\n).
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	CALL	EXPECT_2XX
	JP	C,REPLY_BAD

	; USER <username>
	LD	HL,CMD_USER
	LD	BC,CMD_USER_LEN
	LD	DE,(USER_PTR)
	LD	A,(USER_LEN)
	CALL	SEND_CMD_ARG
	JP	C,TCP_FAIL
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	; 2xx -> already authenticated, skip PASS.
	; 3xx -> server wants PASS.
	; Anything else -> auth refused.
	LD	A,(REPLY_CODE)
	CP	'2'
	JR	Z,.AUTH_OK
	CP	'3'
	JP	NZ,REPLY_BAD

	; PASS <password>
	LD	HL,CMD_PASS
	LD	BC,CMD_PASS_LEN
	LD	DE,(PASS_PTR)
	LD	A,(PASS_LEN)
	CALL	SEND_CMD_ARG
	JP	C,TCP_FAIL
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	CALL	EXPECT_2XX
	JP	C,REPLY_BAD
.AUTH_OK

	; TYPE I
	LD	HL,CMD_TYPE_I
	LD	BC,CMD_TYPE_I_LEN
	CALL	SEND_CMD
	JP	C,TCP_FAIL
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	CALL	EXPECT_2XX
	JP	C,REPLY_BAD

	; PASV
	LD	HL,CMD_PASV
	LD	BC,CMD_PASV_LEN
	CALL	SEND_CMD
	JP	C,TCP_FAIL
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	CALL	EXPECT_2XX
	JP	C,REPLY_BAD
	CALL	PARSE_PASV
	JP	C,PASV_FAIL

	PRINT MSG_PASV_HDR
	LD	HL,PASV_IP
	CALL	PRINT_IPV4
	LD	A,':'
	CALL	PUTCHAR
	LD	A,(PASV_PORT_HI)
	LD	H,A
	LD	A,(PASV_PORT_LO)
	LD	L,A
	CALL	PRINT_DEC_HL
	PRINT LINE_END

	; --- Open the local file ---
	;   GET  -> output, with overwrite prompt (file_lib).
	;   PUT  -> input,  read-only.
	;   LIST -> nothing (data streamed to console).
	LD	A,NO_HANDLE
	LD	(OUT_FH),A
	LD	A,(LIST_MODE)
	OR	A
	JR	NZ,.SKIP_FILE_OPEN
	LD	A,(PUT_MODE)
	OR	A
	JR	NZ,.OPEN_PUT
	LD	HL,(OUTPUT_PTR)
	LD	A,(FORCE_FLAG)
	CALL	@FILE.OPEN_OUTPUT
	JP	C,FILE_FAIL
	LD	(OUT_FH),A
	JR	.SKIP_FILE_OPEN
.OPEN_PUT
	LD	HL,(OUTPUT_PTR)
	CALL	@FILE.OPEN_INPUT
	JP	C,FILE_FAIL
	LD	(OUT_FH),A
.SKIP_FILE_OPEN

	; --- Save control session ---
	LD	DE,CTRL_BACKUP
	CALL	@TCP.SAVE_CTX

	; --- Set up data session: PASV_IP / PASV_PORT, MAC same.
	LD	HL,PASV_IP
	LD	DE,TCP_REMOTE_IP
	LD	BC,4
	LDIR
	LD	A,(PASV_PORT_HI)
	LD	(TCP_REMOTE_PORT_HI),A
	LD	A,(PASV_PORT_LO)
	LD	(TCP_REMOTE_PORT_LO),A
	; Reset state for fresh open.
	XOR	A
	LD	(TCP_STATE),A

	PRINTLN MSG_OPENING_DATA
	CALL	@TCP.OPEN
	JP	C,DATA_OPEN_FAIL

	; --- Save data session, restore control to send RETR ---
	LD	DE,DATA_BACKUP
	CALL	@TCP.SAVE_CTX
	LD	HL,CTRL_BACKUP
	CALL	@TCP.RESTORE_CTX

	; RETR / STOR / LIST / NLST depending on mode.
	LD	A,(LIST_MODE)
	OR	A
	JR	NZ,.SEND_LISTING
	LD	A,(PUT_MODE)
	OR	A
	JR	NZ,.SEND_STOR
	LD	HL,CMD_RETR
	LD	BC,CMD_RETR_LEN
	JR	.SEND_DC_CMD
.SEND_STOR
	LD	HL,CMD_STOR
	LD	BC,CMD_STOR_LEN
	JR	.SEND_DC_CMD
.SEND_LISTING
	LD	A,(NLST_MODE)
	OR	A
	JR	NZ,.SEND_NLST
	LD	HL,CMD_LIST
	LD	BC,CMD_LIST_LEN
	JR	.SEND_DC_CMD
.SEND_NLST
	LD	HL,CMD_NLST
	LD	BC,CMD_NLST_LEN
.SEND_DC_CMD
	LD	DE,(FILENAME_PTR)
	LD	A,(FILENAME_LEN)
	CALL	SEND_CMD_ARG
	JP	C,TCP_FAIL
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	; Accept 1xx (preliminary "150 Opening...") or 2xx.
	LD	A,(REPLY_CODE)
	CP	'1'
	JR	Z,.RETR_OK
	CP	'2'
	JR	Z,.RETR_OK
	; If we sent NLST and the server doesn't know it (500), fall
	; back to LIST automatically -- some embedded FTP servers
	; (e.g. dmnas) implement only the "verbose" listing.
	LD	A,(NLST_MODE)
	OR	A
	JP	Z,REPLY_BAD
	LD	A,(REPLY_CODE)
	CP	'5'
	JP	NZ,REPLY_BAD
	; Suppress further NLST attempts and retry with LIST.
	XOR	A
	LD	(NLST_MODE),A
	PRINTLN MSG_NLST_FB
	LD	HL,CMD_LIST
	LD	BC,CMD_LIST_LEN
	JP	.SEND_DC_CMD
.RETR_OK

	; --- Save control, restore data ---
	LD	DE,CTRL_BACKUP
	CALL	@TCP.SAVE_CTX
	LD	HL,DATA_BACKUP
	CALL	@TCP.RESTORE_CTX

	; --- Data-channel transfer ---
	CALL	@UTIL.TPUT_START
	LD	HL,0
	LD	(FTP_DATA_LEN),HL
	LD	(BODY_TOTAL_LO),HL
	LD	(BODY_TOTAL_HI),HL
	LD	A,(PUT_MODE)
	OR	A
	JP	NZ,.PUT_DATA_LOOP

	; GET / LIST: receive bytes from data session.
.DRXLP
	CALL	@TCP.RECV
	JR	NC,.DRX_HAVE
	; CF=1: peer FIN or error.
	LD	A,(TCP_STATE)
	CP	3				; ST_CLOSE_WAIT
	JP	NZ,DATA_RX_FAIL
	; Drain trailing piggyback data if any.
	LD	HL,(TCP_RX_DATA_LEN)
	LD	A,H
	OR	L
	JR	Z,.DRX_DONE
	CALL	HANDLE_DATA_CHUNK
.DRX_DONE
	JR	.DATA_TRANSFER_DONE
.DRX_HAVE
	CALL	HANDLE_DATA_CHUNK
	JR	.DRXLP
.DATA_TRANSFER_DONE
	; LIST mode: nothing local to flush or close.
	LD	A,(LIST_MODE)
	OR	A
	JR	NZ,.NOC
	; PUT mode: only the input handle to close (no flush).
	LD	A,(PUT_MODE)
	OR	A
	JR	NZ,.CLOSE_HANDLE

	; GET: flush buffered output to disk first.
	CALL	FLUSH_DATA
	JP	C,FILE_FAIL

.CLOSE_HANDLE
	LD	A,(OUT_FH)
	CP	NO_HANDLE
	JR	Z,.NOC
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	LD	A,NO_HANDLE
	LD	(OUT_FH),A
.NOC

	; Close data TCP cleanly.
	CALL	@TCP.CLOSE

	; Terminate the progress-dot line emitted by FLUSH_DATA so
	; the server's "226 Transfer complete" banner lands on a
	; fresh line.
	PRINT LINE_END

	; Restore control session.
	LD	HL,CTRL_BACKUP
	CALL	@TCP.RESTORE_CTX

	; The "226 Transfer complete" reply may have arrived on the
	; control session while we were still polling the data
	; session, in which case our IS_TCP_FROM_PEER filter
	; dropped it and the server is now waiting for an exponential-
	; backoff retransmit.  Send a duplicate ACK to provoke a
	; fast retransmit, and cap the read at 3 s -- 226 is
	; informational; if it never arrives we still print the
	; transfer summary and QUIT cleanly.
	CALL	@TCP.SEND_DUP_ACK
	LD	HL,3000
	LD	(@TCP.RECV_TIMEOUT),HL

	; Read 226 (Transfer complete).
	CALL	READ_REPLY
	JR	C,.NO226
	CALL	PRINT_REPLY
.NO226

	; In GET / PUT print byte counter + KB/s.  In LIST skip
	; it -- the listing was already streamed to the console.
	LD	A,(LIST_MODE)
	OR	A
	JR	NZ,.SKIP_SUMMARY
	PRINT MSG_DONE_PRE
	LD	HL,(BODY_TOTAL_LO)
	LD	DE,(BODY_TOTAL_HI)
	CALL	@UTIL.PRINT_DEC_32
	LD	A,(PUT_MODE)
	OR	A
	JR	NZ,.SUM_SENT
	PRINTLN MSG_BYTES
	JR	.SUM_RATE
.SUM_SENT
	PRINTLN MSG_BYTES_SENT
.SUM_RATE
	LD	HL,(BODY_TOTAL_LO)
	LD	DE,(BODY_TOTAL_HI)
	CALL	@UTIL.TPUT_REPORT
.SKIP_SUMMARY

	; QUIT
	LD	HL,CMD_QUIT
	LD	BC,CMD_QUIT_LEN
	CALL	SEND_CMD
	CALL	READ_REPLY
	JR	C,.QDONE
	CALL	PRINT_REPLY
.QDONE

	CALL	@TCP.CLOSE
	CALL	@ISA.ISA_CLOSE
	JP	@UTIL.EXIT_OK


; --------------------------------------------------------------------
; PUT (STOR) data loop.  Read up to FTP_PUT_CHUNK bytes from OUT_FH,
; ship through the data session via TCP.SEND.  Each TCP.SEND posts
; one PSH+ACK segment and returns immediately; after every chunk we
; give the chip a chance to drain a peer ACK so SND_UNA doesn't fall
; arbitrarily far behind SND_NXT.  EOF (DSS_READ -> 0 bytes) jumps
; back to .DATA_TRANSFER_DONE for the unified close-out / 226 read.
; --------------------------------------------------------------------
.PUT_DATA_LOOP
	; Read up to one MSS into FTP_DATA_BUF.
	LD	HL,FTP_DATA_BUF
	LD	DE,FTP_PUT_CHUNK
	LD	A,(OUT_FH)
	LD	C,DSS_READ_FILE
	RST	DSS
	JP	C,FILE_FAIL
	LD	A,D
	OR	E
	JP	Z,.DATA_TRANSFER_DONE	; nothing left to send

	; Send the chunk.  TCP.SEND wants HL=ptr, BC=length.
	LD	HL,FTP_DATA_BUF
	LD	B,D
	LD	C,E
	PUSH	BC
	CALL	@TCP.SEND
	POP	BC
	JP	C,DATA_RX_FAIL

	; BODY_TOTAL += bytes sent.
	LD	HL,(BODY_TOTAL_LO)
	ADD	HL,BC
	LD	(BODY_TOTAL_LO),HL
	JR	NC,.PUT_NOC
	LD	HL,(BODY_TOTAL_HI)
	INC	HL
	LD	(BODY_TOTAL_HI),HL
.PUT_NOC

	; Progress dot per chunk -- briefly close ISA so PUTCHAR
	; reaches the console.
	CALL	@ISA.ISA_CLOSE
	LD	A,'.'
	LD	C,DSS_PUTCHAR
	RST	DSS
	CALL	@ISA.ISA_OPEN

	; Non-blocking ACK drain.  If no packet is queued, skip;
	; otherwise pull one ACK off the ring (1 ms cap).
	CALL	@RTL.RING_HAS_PACKET
	JR	Z,.PUT_NO_ACK
	LD	HL,1
	LD	(@TCP.RECV_TIMEOUT),HL
	CALL	@TCP.RECV
	; CF=1 here means timeout (ok) or peer closed (caught later).
.PUT_NO_ACK
	JP	.PUT_DATA_LOOP


; ------------------------------------------------------
; READ_REPLY: read FTP reply (single- or multi-line).
; Accumulates bytes in ACCUM_BUF until a line of the form
; "ddd <text>" (3 digits + space) is found; that line is
; the final line of the reply.  Multi-line lines (anything
; before the final) are silently discarded.
;   Out: REPLY_CODE = 3 ASCII digits.
;        REPLY_LINE = ASCIIZ text after "ddd ".
;        CF=0 ok; CF=1 connection closed/error.
; ------------------------------------------------------
READ_REPLY
	XOR	A
	LD	(ACCUM_LEN),A
	LD	(ACCUM_LEN + 1),A
.LP
	CALL	FIND_LINE
	JR	NC,.HAVE
	; No \r\n yet -- need more data.
	CALL	@TCP.RECV
	JR	NC,.GOT
	; Conn closed or error.
	SCF
	RET
.GOT
	CALL	APPEND_TO_ACCUM
	JR	.LP
.HAVE
	; A line is in ACCUM_BUF[0..LINE_LEN-1].  The line was
	; already consumed from ACCUM (shifted out).
	; Check first 4 bytes: 3 digits + ' ' = final.
	LD	A,(LINE_LEN)
	LD	B,A
	LD	A,(LINE_LEN + 1)
	OR	B
	JR	Z,.IGNORE		; empty line, skip
	LD	A,(LINE_LEN)
	CP	4
	JR	C,.IGNORE
	LD	HL,ACCUM_BUF
	LD	A,(HL)
	CALL	IS_DIGIT
	JR	NC,.IGNORE
	INC	HL
	LD	A,(HL)
	CALL	IS_DIGIT
	JR	NC,.IGNORE
	INC	HL
	LD	A,(HL)
	CALL	IS_DIGIT
	JR	NC,.IGNORE
	INC	HL
	LD	A,(HL)
	CP	' '
	JR	NZ,.IGNORE		; '-' or other -> continuation
	; Final line!  Copy code + text.
	LD	HL,ACCUM_BUF
	LD	DE,REPLY_CODE
	LD	BC,3
	LDIR
	; Copy text from ACCUM_BUF + 4 .. LINE_LEN-1 into REPLY_LINE.
	LD	HL,(LINE_LEN)
	LD	DE,4
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	LD	A,B
	OR	C
	JR	NZ,.HAS_TEXT
	XOR	A
	LD	(REPLY_LINE),A
	JR	.RDONE
.HAS_TEXT
	LD	HL,ACCUM_BUF + 4
	LD	DE,REPLY_LINE
	LDIR
	XOR	A
	LD	(DE),A
.RDONE
	OR	A			; CF=0
	RET
.IGNORE
	; Continuation or non-code line; just fetch next line.
	JR	.LP


; ------------------------------------------------------
; IS_DIGIT: A is '0'..'9' -> CF=1; else CF=0.
; ------------------------------------------------------
IS_DIGIT
	CP	'0'
	JR	C,.NO
	CP	'9' + 1
	JR	NC,.NO
	SCF
	RET
.NO
	OR	A
	RET


; ------------------------------------------------------
; FIND_LINE: search ACCUM_BUF for the first \r\n.
; If found, copy the line (excluding \r\n) to ACCUM_BUF
; start (in place; line was already at start), set
; LINE_LEN, shift the rest of ACCUM down, and update
; ACCUM_LEN.  Returns CF=0 on success.
; If no \r\n in buffer: CF=1 (caller must read more).
; ------------------------------------------------------
FIND_LINE
	LD	HL,ACCUM_BUF
	LD	BC,(ACCUM_LEN)
.SC
	LD	A,B
	OR	A
	JR	NZ,.HAVE2
	LD	A,C
	CP	2
	JR	C,.NF
.HAVE2
	LD	A,(HL)
	CP	13
	JR	NZ,.NX
	INC	HL
	LD	A,(HL)
	CP	10
	JR	Z,.FOUND
	DEC	HL
.NX
	INC	HL
	DEC	BC
	JR	.SC
.NF
	SCF
	RET
.FOUND
	; HL points to \n; line ends at HL-1 (\r).
	LD	DE,ACCUM_BUF + 1
	PUSH	HL
	OR	A
	SBC	HL,DE
	LD	(LINE_LEN),HL
	POP	HL
	INC	HL			; past \n -> remaining starts here
	; Compute consumed = HL - ACCUM_BUF, remaining = ACCUM_LEN - consumed.
	PUSH	HL			; src ptr
	LD	DE,ACCUM_BUF
	OR	A
	SBC	HL,DE			; HL = consumed
	EX	DE,HL			; DE = consumed
	LD	HL,(ACCUM_LEN)
	OR	A
	SBC	HL,DE			; HL = remaining
	LD	(ACCUM_LEN),HL
	LD	B,H
	LD	C,L
	POP	HL			; HL = src ptr
	LD	A,B
	OR	C
	JR	Z,.DONE
	LD	DE,ACCUM_BUF
	LDIR
.DONE
	OR	A
	RET


; ------------------------------------------------------
; APPEND_TO_ACCUM: copy the bytes returned by TCP.RECV
; into ACCUM_BUF (cap at ACCUM_BUF_SIZE).
; ------------------------------------------------------
APPEND_TO_ACCUM
	LD	BC,(TCP_RX_DATA_LEN)
	LD	A,B
	OR	C
	RET	Z
	; Available = ACCUM_BUF_SIZE - ACCUM_LEN.
	LD	HL,ACCUM_BUF_SIZE
	LD	DE,(ACCUM_LEN)
	OR	A
	SBC	HL,DE			; HL = available
	LD	A,H
	OR	L
	RET	Z			; full -- drop input
	; If available < count, copy only available.
	LD	A,H
	CP	B
	JR	C,.CAP
	JR	NZ,.NOCAP
	LD	A,L
	CP	C
	JR	NC,.NOCAP
.CAP
	LD	B,H
	LD	C,L
.NOCAP
	; Dst = ACCUM_BUF + ACCUM_LEN.  Src = TCP_RX_DATA_PTR.
	LD	HL,ACCUM_BUF
	LD	DE,(ACCUM_LEN)
	ADD	HL,DE
	EX	DE,HL			; DE = dst
	LD	HL,(TCP_RX_DATA_PTR)
	PUSH	BC
	LDIR
	; Update ACCUM_LEN += count.
	POP	BC
	LD	HL,(ACCUM_LEN)
	ADD	HL,BC
	LD	(ACCUM_LEN),HL
	RET


; ------------------------------------------------------
; PRINT_REPLY: print "ddd text" to console.
; ------------------------------------------------------
PRINT_REPLY
	LD	HL,REPLY_CODE
	LD	B,3
.LP
	LD	A,(HL)
	PUSH	HL,BC
	CALL	PUTCHAR
	POP	BC,HL
	INC	HL
	DJNZ	.LP
	LD	A,' '
	CALL	PUTCHAR
	LD	HL,REPLY_LINE
	LD	C,DSS_PCHARS
	RST	DSS
	PRINT LINE_END
	RET


; ------------------------------------------------------
; EXPECT_2XX: return CF=0 if REPLY_CODE starts with '2',
; else CF=1.
; ------------------------------------------------------
EXPECT_2XX
	LD	A,(REPLY_CODE)
	CP	'2'
	JR	NZ,.NO
	OR	A
	RET
.NO
	SCF
	RET


; ------------------------------------------------------
; SEND_CMD: send a fixed verb + \r\n.
;   In: HL = verb string (no \r\n), BC = verb length.
;   Out: CF passed through from TCP.SEND.
; ------------------------------------------------------
SEND_CMD
	LD	DE,CMD_BUF
	PUSH	BC
	LDIR
	LD	A,13
	LD	(DE),A
	INC	DE
	LD	A,10
	LD	(DE),A
	POP	BC
	INC	BC
	INC	BC
	LD	HL,CMD_BUF
	JP	@TCP.SEND


; ------------------------------------------------------
; SEND_CMD_ARG: send "verb argstr\r\n".
;   In: HL = verb (incl trailing space), BC = verb length;
;       DE = arg (ASCIIZ-style with explicit length),
;       A = arg length.
; ------------------------------------------------------
SEND_CMD_ARG
	LD	(.ARG_PTR),DE
	LD	(.ARG_LEN),A
	LD	DE,CMD_BUF
	LDIR				; copy verb (incl trailing space)
	LD	HL,(.ARG_PTR)
	LD	A,(.ARG_LEN)
	OR	A
	JR	Z,.NOARG
	LD	C,A
	LD	B,0
	LDIR				; copy arg
	JR	.CRLF
.NOARG
	; Empty arg: drop the verb's trailing space so we send a
	; bare "LIST\r\n" / "NLST\r\n".  pyftpdlib 2.2.0 does not
	; trim the trailing whitespace and otherwise treats it as
	; a path " " that does not exist (550).
	DEC	DE
.CRLF
	LD	A,13
	LD	(DE),A
	INC	DE
	LD	A,10
	LD	(DE),A
	INC	DE
	; Total length = DE - CMD_BUF.
	LD	HL,CMD_BUF
	EX	DE,HL
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	LD	HL,CMD_BUF
	JP	@TCP.SEND
.ARG_PTR	EQU FTP_SCRATCH + 0
.ARG_LEN	EQU FTP_SCRATCH + 2


; ------------------------------------------------------
; PARSE_PASV: parse "227 ... (h1,h2,h3,h4,p1,p2)" from
; REPLY_LINE.  Fills PASV_IP (4 bytes BE) and
; PASV_PORT_HI/LO (port = p1*256 + p2).
;   Out: CF=0 ok; CF=1 parse error.
; ------------------------------------------------------
PARSE_PASV
	; Find '(' in REPLY_LINE.
	LD	HL,REPLY_LINE
.FP
	LD	A,(HL)
	OR	A
	JR	Z,.BAD
	CP	'('
	JR	Z,.GO
	INC	HL
	JR	.FP
.GO
	INC	HL			; past '('
	LD	DE,PASV_IP
	LD	B,4
.OCT
	CALL	PARSE_DEC_BYTE_LOC
	JR	C,.BAD
	LD	(DE),A
	INC	DE
	DEC	B
	JR	Z,.PORTH
	LD	A,(HL)
	CP	','
	JR	NZ,.BAD
	INC	HL
	JR	.OCT
.PORTH
	LD	A,(HL)
	CP	','
	JR	NZ,.BAD
	INC	HL
	CALL	PARSE_DEC_BYTE_LOC
	JR	C,.BAD
	LD	(PASV_PORT_HI),A
	LD	A,(HL)
	CP	','
	JR	NZ,.BAD
	INC	HL
	CALL	PARSE_DEC_BYTE_LOC
	JR	C,.BAD
	LD	(PASV_PORT_LO),A
	OR	A
	RET
.BAD
	SCF
	RET


; ------------------------------------------------------
; PARSE_DEC_BYTE_LOC: read 1..3 decimal digits at (HL),
; return byte in A; advance HL past digits.
; Preserves DE (caller PARSE_PASV uses it as IP pointer).
;   Out: CF=0 ok; CF=1 no digit consumed.
; ------------------------------------------------------
PARSE_DEC_BYTE_LOC
	PUSH	BC			; preserve caller's BC
	PUSH	DE
	LD	C,0
	LD	B,0			; digit count
.LP
	LD	A,(HL)
	CALL	IS_DIGIT
	JR	NC,.END
	SUB	'0'
	LD	D,A			; D is scratch -- restored by POP DE
	; C = C*10 + D
	LD	A,C
	ADD	A,A			; *2
	ADD	A,A			; *4
	ADD	A,C			; *5
	ADD	A,A			; *10
	ADD	A,D
	LD	C,A
	INC	HL
	INC	B
	LD	A,B
	CP	3
	JR	C,.LP
.END
	LD	A,B
	OR	A
	JR	Z,.BAD
	LD	A,C
	POP	DE
	POP	BC
	OR	A
	RET
.BAD
	POP	DE
	POP	BC
	SCF
	RET


; ------------------------------------------------------
; IS_PUT_KW: ZF=1 if (HL) is exactly "PUT" / "put" (3 chars,
; case-insensitive).  HL preserved.  Trashes A.
; ------------------------------------------------------
IS_PUT_KW
	PUSH	HL
	LD	A,(HL)
	OR	0x20			; force lower-case
	CP	'p'
	JR	NZ,.NO
	INC	HL
	LD	A,(HL)
	OR	0x20
	CP	'u'
	JR	NZ,.NO
	INC	HL
	LD	A,(HL)
	OR	0x20
	CP	't'
	JR	NZ,.NO
	INC	HL
	LD	A,(HL)
	OR	A
	JR	NZ,.NO			; must be terminator
	POP	HL
	XOR	A			; ZF=1
	RET
.NO
	POP	HL
	OR	1			; ZF=0
	RET


; ------------------------------------------------------
; STRLEN_FROM_HL: count bytes from (HL) until NUL.
;   Out: A = length (capped at 255).  HL preserved.
; ------------------------------------------------------
STRLEN_FROM_HL
	PUSH	HL
	LD	B,0
.LP
	LD	A,(HL)
	OR	A
	JR	Z,.D
	INC	HL
	INC	B
	JR	NZ,.LP
.D
	LD	A,B
	POP	HL
	RET


; ------------------------------------------------------
; HANDLE_DATA_CHUNK: dispatch the freshly-received chunk
; to APPEND_DATA (GET mode -- buffer for disk) or to
; PRINT_DATA_CHUNK (LIST mode -- straight to console).
; ------------------------------------------------------
HANDLE_DATA_CHUNK
	LD	A,(LIST_MODE)
	OR	A
	JP	NZ,PRINT_DATA_CHUNK
	JP	APPEND_DATA


; ------------------------------------------------------
; PRINT_DATA_CHUNK: emit TCP_RX_DATA_LEN bytes from
; TCP_RX_DATA_PTR to the console.  ISA window is briefly
; closed for the DSS_PCHARS call (console output uses
; PAGE3); to make PCHARS happy we temporarily null-
; terminate the chunk and restore the byte after.  Each
; chunk is one TCP segment (<= MSS), so the close window
; stays small enough that the chip's RX ring doesn't
; overflow during the print.
; ------------------------------------------------------
PRINT_DATA_CHUNK
	LD	HL,(TCP_RX_DATA_PTR)
	LD	BC,(TCP_RX_DATA_LEN)
	LD	A,B
	OR	C
	RET	Z
	PUSH	HL
	ADD	HL,BC
	LD	A,(HL)
	LD	(.SAVE_BYTE),A		; remember byte at chunk_end
	XOR	A
	LD	(HL),A			; null-terminate chunk for PCHARS
	POP	HL
	PUSH	HL
	PUSH	BC
	CALL	@ISA.ISA_CLOSE
	LD	C,DSS_PCHARS
	RST	DSS
	CALL	@ISA.ISA_OPEN
	POP	BC
	POP	HL
	ADD	HL,BC
	LD	A,(.SAVE_BYTE)
	LD	(HL),A			; restore the byte we clobbered
	; Update BODY_TOTAL too -- TPUT_REPORT uses it (we don't
	; print the count in -l mode, but the counter stays
	; consistent should somebody add a "-l verbose" later).
	LD	BC,(TCP_RX_DATA_LEN)
	LD	HL,(BODY_TOTAL_LO)
	ADD	HL,BC
	LD	(BODY_TOTAL_LO),HL
	RET	NC
	LD	HL,(BODY_TOTAL_HI)
	INC	HL
	LD	(BODY_TOTAL_HI),HL
	RET
.SAVE_BYTE	DB 0


; ------------------------------------------------------
; APPEND_DATA: append TCP_RX_DATA_LEN bytes from
; TCP_RX_DATA_PTR to FTP_DATA_BUF; flush to disk and
; reset on overflow.  Updates BODY_TOTAL.
; ------------------------------------------------------
APPEND_DATA
	LD	BC,(TCP_RX_DATA_LEN)
	LD	A,B
	OR	C
	RET	Z
	; Will (FTP_DATA_LEN + count) exceed FTP_DATA_BUF_SIZE?
	LD	HL,(FTP_DATA_LEN)
	ADD	HL,BC
	LD	DE,FTP_DATA_BUF_SIZE
	OR	A
	SBC	HL,DE
	JR	C,.NO_FLUSH
	; Flush first.
	CALL	FLUSH_DATA
	RET	C
.NO_FLUSH
	; Copy chunk.
	LD	HL,(TCP_RX_DATA_PTR)
	LD	BC,(TCP_RX_DATA_LEN)
	LD	DE,(FTP_DATA_LEN)
	PUSH	HL
	LD	HL,FTP_DATA_BUF
	ADD	HL,DE
	EX	DE,HL			; DE = dst, HL on stack = src
	POP	HL			; HL = src
	PUSH	BC			; save count for body counter
	LDIR
	POP	BC
	; FTP_DATA_LEN += count
	LD	HL,(FTP_DATA_LEN)
	ADD	HL,BC
	LD	(FTP_DATA_LEN),HL
	; BODY_TOTAL += count
	LD	HL,(BODY_TOTAL_LO)
	ADD	HL,BC
	LD	(BODY_TOTAL_LO),HL
	RET	NC
	LD	HL,(BODY_TOTAL_HI)
	INC	HL
	LD	(BODY_TOTAL_HI),HL
	RET


; ------------------------------------------------------
; FLUSH_DATA: write FTP_DATA_BUF to OUT_FH and reset.
;   Out: CF=0 ok, CF=1 DSS_WRITE error.
; ------------------------------------------------------
FLUSH_DATA
	LD	HL,(FTP_DATA_LEN)
	LD	A,H
	OR	L
	RET	Z
	; Console writes (DSS_PUTCHAR) need PAGE3 free, so close
	; ISA briefly just for the dot, then reopen.  DSS_WRITE
	; works fine with ISA still open (its source pointer is in
	; PAGE2 linear RAM, no PAGE3 access required) -- keep it
	; outside the close/open bracket to avoid an extra MMU
	; toggle on a hot path.
	CALL	@ISA.ISA_CLOSE
	LD	A,'.'
	LD	C,DSS_PUTCHAR
	RST	DSS
	CALL	@ISA.ISA_OPEN
	LD	HL,(FTP_DATA_LEN)
	LD	D,H
	LD	E,L
	LD	HL,FTP_DATA_BUF
	LD	A,(OUT_FH)
	LD	C,DSS_WRITE
	RST	DSS
	RET	C			; CF=1 propagated, ISA stays OPEN
	LD	HL,0
	LD	(FTP_DATA_LEN),HL
	OR	A
	RET


; ------------------------------------------------------
; PRINT_CHUNK: legacy debug helper -- print a chunk as
; raw text (used by stage-1-style banner dumps).  Kept
; here so callers in older code paths keep working.
; ------------------------------------------------------
PRINT_CHUNK
	LD	HL,(TCP_RX_DATA_PTR)
	LD	BC,(TCP_RX_DATA_LEN)
.LP
	LD	A,B
	OR	C
	RET	Z
	LD	A,(HL)
	PUSH	HL
	PUSH	BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC
	POP	HL
	INC	HL
	DEC	BC
	JR	.LP


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

REPLY_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_RECV
	JP	FAIL_NIC

REPLY_BAD
	PRINT LINE_END
	PRINTLN MSG_E_BAD_REPLY
	CALL	@TCP.CLOSE
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL

TCP_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_TCP_SEND
	JP	FAIL_NIC

PASV_FAIL
	PRINTLN MSG_E_PASV
	CALL	@TCP.CLOSE
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL

DATA_OPEN_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_DATA_OPEN
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL

DATA_RX_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_DATA_RX
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL

FILE_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_FILE
	LD	A,(OUT_FH)
	CP	NO_HANDLE
	JR	Z,.NF
	LD	C,DSS_CLOSE_FILE
	RST	DSS
.NF
	CALL	@ISA.ISA_CLOSE
	LD	B,1
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


; ------- FTP command literals (no trailing \r\n) -------
CMD_USER	DB "USER "
CMD_USER_LEN	EQU $ - CMD_USER
CMD_PASS	DB "PASS "
CMD_PASS_LEN	EQU $ - CMD_PASS
CMD_TYPE_I	DB "TYPE I"
CMD_TYPE_I_LEN	EQU $ - CMD_TYPE_I
CMD_PASV	DB "PASV"
CMD_PASV_LEN	EQU $ - CMD_PASV
CMD_QUIT	DB "QUIT"
CMD_QUIT_LEN	EQU $ - CMD_QUIT
CMD_LIST	DB "LIST "
CMD_LIST_LEN	EQU $ - CMD_LIST
CMD_NLST	DB "NLST "
CMD_NLST_LEN	EQU $ - CMD_NLST
CMD_STOR	DB "STOR "
CMD_STOR_LEN	EQU $ - CMD_STOR
EMPTY_STR	DB 0
CMD_RETR	DB "RETR "
CMD_RETR_LEN	EQU $ - CMD_RETR
DEFAULT_USER	DB "anonymous"
DEFAULT_USER_LEN EQU $ - DEFAULT_USER
DEFAULT_PASS	DB "anonymous@"
DEFAULT_PASS_LEN EQU $ - DEFAULT_PASS


ACCUM_BUF_SIZE	EQU 512
REPLY_LINE_SIZE	EQU 256
CMD_BUF_SIZE	EQU 256


; ------- runtime BSS -----------------------
OUR_IP		EQU APP_BSS_BASE		; 4
OUR_MAC		EQU APP_BSS_BASE + 4		; 6
TARGET_IP	EQU APP_BSS_BASE + 10		; 4
TARGET_MAC	EQU APP_BSS_BASE + 14		; 6
TIMEOUT_MS_LEFT	EQU APP_BSS_BASE + 20		; 2
HOST_PTR	EQU APP_BSS_BASE + 22		; 2 (-> argv)
CANCELLED	EQU APP_BSS_BASE + 24		; 1
DEC_BUF		EQU APP_BSS_BASE + 26		; 6
ACCUM_LEN	EQU APP_BSS_BASE + 32		; 2
LINE_LEN	EQU APP_BSS_BASE + 34		; 2
REPLY_CODE	EQU APP_BSS_BASE + 36		; 3
PASV_PORT_HI	EQU APP_BSS_BASE + 39		; 1
PASV_PORT_LO	EQU APP_BSS_BASE + 40		; 1
PASV_IP		EQU APP_BSS_BASE + 41		; 4
FTP_SCRATCH	EQU APP_BSS_BASE + 48		; 16 (helper scratch)
FILENAME_PTR	EQU APP_BSS_BASE + 56		; 2
FILENAME_LEN	EQU APP_BSS_BASE + 58		; 1
OUTPUT_PTR	EQU APP_BSS_BASE + 59		; 2
OUT_FH		EQU APP_BSS_BASE + 61		; 1
BODY_TOTAL_LO	EQU APP_BSS_BASE + 62		; 2
ACCUM_BUF	EQU APP_BSS_BASE + 64		; ACCUM_BUF_SIZE
REPLY_LINE	EQU ACCUM_BUF + ACCUM_BUF_SIZE	; REPLY_LINE_SIZE
CMD_BUF		EQU REPLY_LINE + REPLY_LINE_SIZE ; CMD_BUF_SIZE
CTRL_BACKUP	EQU CMD_BUF + CMD_BUF_SIZE	; TCP_CTX_SIZE
DATA_BACKUP	EQU CTRL_BACKUP + TCP_CTX_SIZE	; TCP_CTX_SIZE
BODY_TOTAL_HI	EQU DATA_BACKUP + TCP_CTX_SIZE	; 2
FTP_DATA_LEN	EQU BODY_TOTAL_HI + 2		; 2
FORCE_FLAG	EQU FTP_DATA_LEN + 2		; 1 (-y / --yes)
USER_PTR	EQU FORCE_FLAG + 1		; 2 (-u / default DEFAULT_USER)
USER_LEN	EQU USER_PTR + 2		; 1
USER_OVERRIDE	EQU USER_LEN + 1		; 1 (1 if -u was given)
PASS_PTR	EQU USER_OVERRIDE + 1		; 2
PASS_LEN	EQU PASS_PTR + 2		; 1
LIST_MODE	EQU PASS_LEN + 1		; 1 (1 if -l or -n was given)
NLST_MODE	EQU LIST_MODE + 1		; 1 (1 if -n was given)
PUT_MODE	EQU NLST_MODE + 1		; 1 (1 if "PUT" verb was given)
HAS_OVR_O	EQU PUT_MODE + 1		; 1 (1 if -o was given)
OVR_O_PTR	EQU HAS_OVR_O + 1		; 2 (-> argv when HAS_OVR_O=1)

NO_HANDLE	EQU 0xFF
FTP_DATA_BUF_SIZE EQU 8192		; matches WGET; halves DSS_WRITE count
FTP_PUT_CHUNK	  EQU 536		; one TCP MSS per STOR send


MSG_BANNER	DB "RTL8019AS FTP v0.5",0
MSG_RESOLVED	DB "Resolved ",0
MSG_TO		DB " -> ",0
MSG_CONNECTING	DB "Connecting...",0
MSG_CONNECTED	DB "ok.",0
MSG_BANNER_HDR	DB "Server banner:",13,10,0
MSG_REGS	DB "REGS ",0
MSG_ABORTED	DB "Aborted by user (Esc/Ctrl+C).",0
MSG_E_RESET	DB "[E A0] RESET timeout",0
MSG_E_SEND	DB "[E A1] DMA write or PTX timeout",0
MSG_E_ARP	DB "ARP request timed out.",0
MSG_E_TCP_OPEN	DB "TCP connect failed, code 0x",0
MSG_E_RECV	DB "TCP recv failed.",0
MSG_E_RESOLVE	DB "[E] could not resolve host.",0
MSG_E_BAD_REPLY	DB "[E] FTP server returned non-2xx.",0
MSG_E_TCP_SEND	DB "[E] TCP send failed.",0
MSG_E_PASV	DB "[E] could not parse PASV reply.",0
MSG_PASV_HDR	DB "Data endpoint: ",0
MSG_OPENING_DATA DB "Opening data connection...",0
MSG_NLST_FB	 DB "[W] NLST not supported; retrying with LIST.",0
MSG_DONE_PRE	DB "Done. ",0
MSG_BYTES	DB " bytes received.",0
MSG_BYTES_SENT	DB " bytes sent.",0
MSG_E_DATA_OPEN	DB "[E] data connection failed.",0
MSG_E_DATA_RX	DB "[E] data recv failed.",0
MSG_E_FILE	DB "[E] file create/write failed.",0
MSG_USAGE_ERR	DB "[E] usage: missing host or filename",0
MSG_HELP
	DB "Usage:",13,10
	DB "  FTP host filename     [-u user] [-p pass] [-o output] [-y]",13,10
	DB "  FTP host PUT local    [-u user] [-p pass] [-o remote-name]",13,10
	DB "  FTP host [path] -l    [-u user] [-p pass]",13,10
	DB "  FTP host [path] -n    [-u user] [-p pass]",13,10
	DB "  FTP /?",13,10,13,10
	DB "  host       FTP server (IPv4 or hostname).",13,10
	DB "  filename   remote file to download (default mode).",13,10
	DB "  PUT local  upload local file to server.",13,10
	DB "  path       remote directory to list (default: server CWD).",13,10
	DB "  -l         list a directory (LIST: verbose, ls -l style).",13,10
	DB "  -n         list a directory (NLST: terse, names only).",13,10
	DB "  -u user    FTP username (default: anonymous).",13,10
	DB "  -p pass    FTP password (default: anonymous@; empty",13,10
	DB "             when -u is given without -p).",13,10
	DB "  -o name    GET: alternate local output filename.",13,10
	DB "             PUT: alternate remote name on the server.",13,10
	DB "  -y         overwrite local file without prompt (GET).",13,10,0
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


FTP_IMAGE_END

RX_BUF_SIZE	EQU 1518

	MODULE MAIN

TX_BUF		EQU FTP_IMAGE_END
RX_HDR		EQU TX_BUF + TCP_MAX_FRAME
RX_BUF		EQU RX_HDR + 4
FTP_DATA_BUF	EQU RX_BUF + RX_BUF_SIZE
FTP_BSS_END	EQU FTP_DATA_BUF + FTP_DATA_BUF_SIZE

	ENDMODULE

	END MAIN.START
