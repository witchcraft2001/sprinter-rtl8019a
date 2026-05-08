; ======================================================
; TFTP.EXE - stage 7 of the Sprinter RTL8019AS network kit.
; Downloads a hardcoded file ("TEST.TXT") via TFTP read
; (octet mode, 512-byte default block size) from a hardcoded
; server (192.168.7.1:69) and writes the bytes into a DSS
; file ("TEST.TXT" in current directory).
;
; v0.1: hardcoded everything. NET.CFG / cmdline filename arrive
;       in v0.2.
;
; Host setup (single-machine via feth pair):
;   sudo ifconfig feth0 create
;   sudo ifconfig feth1 create
;   sudo ifconfig feth0 peer feth1
;   sudo ifconfig feth0 up
;   sudo ifconfig feth1 inet 192.168.7.1/24 up
;   echo "hello tftp" > /tmp/test.txt
;   sudo python3 tools/dev/tftp_serve.py --root /tmp
;
; Stage codes:
;   [F0] INIT
;   [F1] RRQ <filename>
;   [F2] DATA BLK=<n> LEN=<bytes>
;   [F3] ACK BLK=<n>
;   ... loop ...
;   [Fn] DONE SIZE=<total>
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
	DEFINE USE_RESOLVE
	DEFINE USE_CMDL
	DEFINE USE_FILE
	DEFINE USE_UTIL_PRINT_DEC_32
	DEFINE USE_UTIL_TPUT
	DEFINE CMDLINE_AT_LARGE

ARP_TIMEOUT_MS	EQU 3000
TFTP_TIMEOUT_MS	EQU 5000		; per-DATA reply budget
SCAN_C		EQU 0xAC

ETH_TYPE_ARP	EQU 0x0806
ETH_TYPE_IPV4	EQU 0x0800
IP_PROTO_UDP	EQU 17

ARP_OP_REQUEST	EQU 1
ARP_OP_REPLY	EQU 2

ARP_FRAME_LEN	EQU 60
IP_HDR_LEN	EQU 20
UDP_HDR_LEN	EQU 8

OUR_PORT_HI	EQU 0xC1
OUR_PORT_LO	EQU 0x00
TFTP_SRV_PORT_HI EQU 0
TFTP_SRV_PORT_LO EQU 69

; -- TFTP opcodes
OP_RRQ		EQU 1
OP_DATA		EQU 3
OP_ACK		EQU 4
OP_ERROR	EQU 5
OP_OACK		EQU 6				; RFC 2347 option ACK

; -- TFTP defaults
TFTP_BLOCK_DEFAULT	EQU 512			; RFC 1350 fallback
TFTP_BLOCK_REQ		EQU 1428		; RFC 2348 negotiated request
TFTP_BLOCK_MAX		EQU 1468		; Ethernet MTU - IP/UDP/TFTP hdr

NO_HANDLE	EQU 0xFF

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

	; positional 0: host (IPv4 literal or hostname)
	LD	B,0
	CALL	@CMDL.GET_POSITIONAL
	JP	C,USAGE_ERROR
	LD	(TARGET_HOST_PTR),HL

	; positional 1: subcommand "GET" (only mode supported in v0.2)
	LD	B,1
	CALL	@CMDL.GET_POSITIONAL
	JP	C,USAGE_ERROR
	CALL	IS_GET
	JP	NZ,USAGE_ERROR

	; positional 2: filename (must fit FILENAME_BUF / 8.3 limits).
	LD	B,2
	CALL	@CMDL.GET_POSITIONAL
	JP	C,USAGE_ERROR
	; Copy ASCIIZ filename into FILENAME_BUF.
	LD	DE,FILENAME_BUF
	LD	B,FILENAME_BUF_SIZE - 1
.CPF
	LD	A,(HL)
	OR	A
	JR	Z,.CPF_DONE
	LD	(DE),A
	INC	HL
	INC	DE
	DEC	B
	JR	NZ,.CPF
.CPF_DONE
	XOR	A
	LD	(DE),A

	; -y / --yes: force overwrite without prompt.
	XOR	A
	LD	(FORCE_FLAG),A
	LD	A,'y'
	CALL	@CMDL.HAS_FLAG
	JR	C,.NO_FORCE
	LD	A,1
	LD	(FORCE_FLAG),A
.NO_FORCE

	; Pull NET_IP / NET_MAC from env (populated by NETCFG -i).
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

	; Resolve target host (literal IPv4 or hostname).
	LD	HL,(TARGET_HOST_PTR)
	LD	DE,TARGET_IP
	CALL	@RESOLVE.HOST
	JP	C,RESOLVE_FAIL

	; Init TFTP state.
	LD	A,NO_HANDLE
	LD	(OUT_FH),A
	LD	HL,1
	LD	(EXPECTED_BLOCK),HL
	XOR	A
	LD	(SERVER_PORT_HI),A
	LD	(SERVER_PORT_LO),A
	LD	HL,0
	LD	(TOTAL_BYTES_LO),HL
	LD	(TOTAL_BYTES_HI),HL
	; Default block size (RFC 1350) -- overwritten by an OACK
	; reply if the server accepts our blksize=1428 option.
	LD	HL,TFTP_BLOCK_DEFAULT
	LD	(NEG_BLKSIZE),HL

	; Banner: "GET FILENAME from HOST"
	PRINT LINE_END
	PRINT MSG_GET_HDR
	LD	HL,FILENAME_BUF
	PRINT_HL
	PRINT MSG_FROM_HOST
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINT LINE_END

	; ARP resolve.
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

	; Open output file (prompt-or-overwrite via @FILE.OPEN_OUTPUT).
	LD	HL,FILENAME_BUF
	LD	A,(FORCE_FLAG)
	CALL	@FILE.OPEN_OUTPUT
	JP	C,FILE_FAIL
	LD	(OUT_FH),A

	; Capture transfer-start timestamp for end-of-run KB/s metric.
	CALL	@UTIL.TPUT_START

	; Send RRQ.
	CALL	BUILD_RRQ_PAYLOAD
	; Set up frame parameters and build full UDP-over-IP frame.
	LD	HL,TFTP_BUF
	LD	(TFTP_PAYLOAD_PTR),HL
	LD	HL,(RRQ_LEN)
	LD	(TFTP_PAYLOAD_LEN),HL
	LD	A,TFTP_SRV_PORT_HI
	LD	(TFTP_DST_PORT_HI),A
	LD	A,TFTP_SRV_PORT_LO
	LD	(TFTP_DST_PORT_LO),A
	CALL	BUILD_UDP_FRAME		; returns frame length in BC
	LD	HL,TX_BUF
	CALL	@RTL.SEND_FRAME
	JP	C,SEND_FAIL

	; -- Block loop --
.BLOCK_LOOP
	LD	HL,TFTP_TIMEOUT_MS
	LD	(TIMEOUT_MS_LEFT),HL
	CALL	WAIT_FOR_TFTP_DATA
	JP	C,TFTP_TIMEOUT

	; A = OP_DATA or OP_OACK.
	CP	OP_OACK
	JR	NZ,.NOT_OACK

	; OACK: parse options, ACK block 0, loop and expect DATA blk=1.
	CALL	PARSE_OACK
	; Send ACK(0).  EXPECTED_BLOCK is currently 1; temporarily 0
	; for the OACK confirmation, then restore.
	LD	HL,(EXPECTED_BLOCK)
	PUSH	HL
	LD	HL,0
	LD	(EXPECTED_BLOCK),HL
	CALL	BUILD_ACK_PAYLOAD
	LD	HL,TFTP_BUF
	LD	(TFTP_PAYLOAD_PTR),HL
	LD	HL,4
	LD	(TFTP_PAYLOAD_LEN),HL
	LD	A,(SERVER_PORT_HI)
	LD	(TFTP_DST_PORT_HI),A
	LD	A,(SERVER_PORT_LO)
	LD	(TFTP_DST_PORT_LO),A
	CALL	BUILD_UDP_FRAME
	LD	HL,TX_BUF
	CALL	@RTL.SEND_FRAME
	JP	C,SEND_FAIL
	POP	HL
	LD	(EXPECTED_BLOCK),HL
	JP	.BLOCK_LOOP

.NOT_OACK
	; Write data to file.
	LD	BC,(DATA_LEN)
	LD	A,B
	OR	C
	JR	Z,.NO_WRITE
	LD	HL,RX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN + 4
	LD	A,(OUT_FH)
	LD	D,B
	LD	E,C
	LD	C,DSS_WRITE
	RST	DSS
	JP	C,FILE_FAIL
	; Accumulate total bytes (32-bit add: TOTAL_BYTES += DATA_LEN).
	LD	HL,(DATA_LEN)
	LD	BC,(TOTAL_BYTES_LO)
	ADD	HL,BC
	LD	(TOTAL_BYTES_LO),HL
	LD	HL,(TOTAL_BYTES_HI)
	LD	BC,0
	ADC	HL,BC				; propagate carry from low add
	LD	(TOTAL_BYTES_HI),HL
.NO_WRITE

	; Send ACK for current block.
	CALL	BUILD_ACK_PAYLOAD
	LD	HL,TFTP_BUF
	LD	(TFTP_PAYLOAD_PTR),HL
	LD	HL,4
	LD	(TFTP_PAYLOAD_LEN),HL
	LD	A,(SERVER_PORT_HI)
	LD	(TFTP_DST_PORT_HI),A
	LD	A,(SERVER_PORT_LO)
	LD	(TFTP_DST_PORT_LO),A
	CALL	BUILD_UDP_FRAME
	LD	HL,TX_BUF
	CALL	@RTL.SEND_FRAME
	JP	C,SEND_FAIL

	; If DATA_LEN < negotiated block size, this was the last block.
	LD	HL,(DATA_LEN)
	LD	DE,(NEG_BLKSIZE)
	LD	A,H
	CP	D
	JR	C,.DONE
	JR	NZ,.MORE
	LD	A,L
	CP	E
	JR	C,.DONE
.MORE
	LD	HL,(EXPECTED_BLOCK)
	INC	HL
	LD	(EXPECTED_BLOCK),HL
	JP	.BLOCK_LOOP

.DONE
	; Close file.
	LD	A,(OUT_FH)
	CP	NO_HANDLE
	JR	Z,.NOCLOSE
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	LD	A,NO_HANDLE
	LD	(OUT_FH),A
.NOCLOSE
	PRINT MSG_DONE
	LD	HL,(TOTAL_BYTES_LO)
	LD	DE,(TOTAL_BYTES_HI)
	CALL	@UTIL.PRINT_DEC_32
	PRINTLN MSG_BYTES_RECV
	LD	HL,(TOTAL_BYTES_LO)
	LD	DE,(TOTAL_BYTES_HI)
	CALL	@UTIL.TPUT_REPORT

	CALL	@ISA.ISA_CLOSE
	JP	@UTIL.EXIT_OK


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
	JR	NZ,.CANCEL
	PRINTLN MSG_E_ARP
	JP	FAIL_NIC
.CANCEL
	PRINTLN MSG_ABORTED
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL

TFTP_TIMEOUT
	LD	A,(CANCELLED)
	OR	A
	JR	NZ,.CANCEL
	PRINTLN MSG_E_TFTP
	JP	FAIL_FILE
.CANCEL
	PRINTLN MSG_ABORTED
	JP	FAIL_FILE

FILE_FAIL
	PRINTLN MSG_E_FILE
	JP	FAIL_FILE

FAIL_FILE
	; Best-effort close
	LD	A,(OUT_FH)
	CP	NO_HANDLE
	JR	Z,.NOC
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	LD	A,NO_HANDLE
	LD	(OUT_FH),A
.NOC
	JP	FAIL_NIC

FAIL_NIC
	CALL	@RTL.SNAPSHOT_REGS
	CALL	PRINT_REG_DUMP
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL


RESOLVE_FAIL
	LD	A,(@RESOLVE.LAST_FAIL)
	CP	1
	JR	Z,.USG
	CP	2
	JR	Z,.NDNS
	CP	3
	JR	Z,.NGW
	CP	7
	JR	Z,.CAN
	PRINTLN MSG_E_RESOLVE
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL
.USG
	CALL	@ISA.ISA_CLOSE
	JP	USAGE_ERROR
.NDNS
	PRINTLN MSG_E_NO_DNS1
	CALL	@ISA.ISA_CLOSE
	LD	B,4
	JP	@UTIL.EXIT_FAIL
.NGW
	PRINTLN MSG_E_NO_GW
	CALL	@ISA.ISA_CLOSE
	LD	B,4
	JP	@UTIL.EXIT_FAIL
.CAN
	PRINTLN MSG_ABORTED
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


; ------------------------------------------------------
; IS_GET: HL = ASCIIZ token. ZF=1 if equals "GET" / "get"
; (case-insensitive, exactly 3 chars).  Trashes A, BC.
; HL preserved.
; ------------------------------------------------------
IS_GET
	PUSH	HL
	LD	A,(HL)
	CALL	UPCASE
	CP	'G'
	JR	NZ,.NO
	INC	HL
	LD	A,(HL)
	CALL	UPCASE
	CP	'E'
	JR	NZ,.NO
	INC	HL
	LD	A,(HL)
	CALL	UPCASE
	CP	'T'
	JR	NZ,.NO
	INC	HL
	LD	A,(HL)
	OR	A			; must be terminator
	JR	NZ,.NO
	POP	HL
	XOR	A			; ZF=1
	RET
.NO
	POP	HL
	OR	1			; ZF=0
	RET

UPCASE
	CP	'a'
	RET	C
	CP	'z'+1
	RET	NC
	SUB	'a'-'A'
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


; ------------------------------------------------------
; BUILD_RRQ_PAYLOAD: TFTP_BUF = opcode_RRQ(BE) + filename + 0
; + "octet" + 0 + "blksize" + 0 + "1428" + 0.
; Sets RRQ_LEN.  RFC 2348 option negotiation: server may
; reply OACK with the accepted blksize, or DATA blk=1 to
; ignore options (we then fall back to the 512-byte default).
; ------------------------------------------------------
BUILD_RRQ_PAYLOAD
	LD	DE,TFTP_BUF
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,OP_RRQ
	LD	(DE),A
	INC	DE
	; Filename + 0
	LD	HL,FILENAME_BUF
	CALL	COPY_ASCIIZ
	; "octet" + 0
	LD	HL,MODE_OCTET
	CALL	COPY_ASCIIZ
	; "blksize" + 0
	LD	HL,OPT_BLKSIZE
	CALL	COPY_ASCIIZ
	; "1428" + 0
	LD	HL,OPT_VAL_BLK
	CALL	COPY_ASCIIZ
	; Compute length: DE - TFTP_BUF
	LD	HL,TFTP_BUF
	OR	A
	EX	DE,HL
	SBC	HL,DE			; HL = end - start
	LD	(RRQ_LEN),HL
	RET

; COPY_ASCIIZ: copy ASCIIZ string from HL to DE (including
; the trailing zero). Trashes A, advances HL and DE.
COPY_ASCIIZ
.LP
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	OR	A
	JR	NZ,.LP
	RET


; ------------------------------------------------------
; BUILD_ACK_PAYLOAD: TFTP_BUF = opcode_ACK(BE) + EXPECTED_BLOCK(BE).
; Length is fixed at 4 bytes.
; ------------------------------------------------------
BUILD_ACK_PAYLOAD
	LD	DE,TFTP_BUF
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,OP_ACK
	LD	(DE),A
	INC	DE
	LD	HL,(EXPECTED_BLOCK)
	LD	A,H
	LD	(DE),A
	INC	DE
	LD	A,L
	LD	(DE),A
	INC	DE
	RET


; ------------------------------------------------------
; PARSE_OACK: walk the OACK option list in RX_BUF and, if a
; "blksize" option is present, store the accepted value into
; NEG_BLKSIZE (clamped to TFTP_BLOCK_DEFAULT..TFTP_BLOCK_MAX).
; If no "blksize" option is found, NEG_BLKSIZE is left as the
; pre-existing default.  Other options are ignored.
; Trashes A,BC,DE,HL.
; ------------------------------------------------------
PARSE_OACK
	; End ptr = RX_BUF + 14 + IP_HDR_LEN + UDP_LEN.
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 4)
	LD	D,A
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 5)
	LD	E,A			; DE = UDP length (BE)
	LD	HL,RX_BUF + 14 + IP_HDR_LEN
	ADD	HL,DE
	LD	(OACK_END_PTR),HL
	; Cursor: first byte after the OACK opcode.
	LD	HL,RX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN + 2
.LP
	; If HL >= end -> done.
	LD	DE,(OACK_END_PTR)
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	HL
	JR	NC,.DONE
	; Compare key at HL to "blksize" (case-insensitive).
	PUSH	HL
	CALL	OACK_KEY_IS_BLKSIZE
	JR	C,.SKIP			; no match
	POP	DE			; discard saved HL (HL already advanced)
	; HL points to value start.
	CALL	OACK_PARSE_DEC_WORD	; out: DE = value, HL advanced past digits
	; Skip the trailing zero of the value, then we are done with
	; this option -- and we accept the first blksize we see.
	LD	A,(HL)
	OR	A
	JR	NZ,.CLAMP		; malformed but harmless
	INC	HL
.CLAMP
	; Clamp DE into [TFTP_BLOCK_DEFAULT, TFTP_BLOCK_MAX].
	; If DE < 8 (sanity), keep default.
	LD	HL,8
	OR	A
	SBC	HL,DE
	JR	NC,.DONE		; DE < 8: ignore
	LD	HL,TFTP_BLOCK_MAX
	OR	A
	SBC	HL,DE
	JR	NC,.STORE
	LD	DE,TFTP_BLOCK_MAX	; cap
.STORE
	LD	(NEG_BLKSIZE),DE
	RET
.SKIP
	POP	HL
	; Skip key (find \0).
	CALL	OACK_SKIP_ASCIIZ
	; Skip value (find \0).
	CALL	OACK_SKIP_ASCIIZ
	JR	.LP
.DONE
	RET

; OACK_KEY_IS_BLKSIZE: HL -> key string.  CF=0 if matches
; "blksize" exactly (then HL advanced past trailing \0); CF=1
; otherwise (HL undefined; caller restores from saved copy).
OACK_KEY_IS_BLKSIZE
	LD	DE,LIT_BLKSIZE
.CMP
	LD	A,(DE)
	OR	A
	JR	Z,.LIT_END
	LD	B,A			; B = expected (already lowercase)
	LD	A,(HL)
	OR	A
	JR	Z,.NO			; key shorter than literal
	OR	0x20			; force ASCII letter to lowercase
	CP	B
	JR	NZ,.NO
	INC	HL
	INC	DE
	JR	.CMP
.LIT_END
	LD	A,(HL)
	OR	A
	JR	NZ,.NO			; key longer than "blksize"
	INC	HL			; past the \0
	OR	A			; CF=0
	RET
.NO
	SCF
	RET
LIT_BLKSIZE	DB "blksize",0

; OACK_SKIP_ASCIIZ: HL -> string; advances HL past the \0.
OACK_SKIP_ASCIIZ
	LD	A,(HL)
	INC	HL
	OR	A
	JR	NZ,OACK_SKIP_ASCIIZ
	RET

; OACK_PARSE_DEC_WORD: HL -> ASCIIZ decimal.  Out: DE = value,
; HL advanced past the digits (NOT past the \0).
; Trashes A.
OACK_PARSE_DEC_WORD
	LD	DE,0
.LP
	LD	A,(HL)
	CP	'0'
	RET	C
	CP	'9'+1
	RET	NC
	SUB	'0'
	PUSH	HL
	PUSH	AF
	; DE *= 10  via HL = DE*2 + DE*8
	LD	H,D
	LD	L,E
	ADD	HL,HL			; HL = DE*2
	ADD	HL,HL			; HL = DE*4
	ADD	HL,DE			; HL = DE*5
	ADD	HL,HL			; HL = DE*10
	EX	DE,HL			; DE = DE*10
	POP	AF
	LD	H,0
	LD	L,A
	ADD	HL,DE
	EX	DE,HL			; DE = DE*10 + digit
	POP	HL
	INC	HL
	JR	.LP


; ------------------------------------------------------
; BUILD_UDP_FRAME: assemble ETH + IPv4 + UDP + TFTP payload
; in TX_BUF. Inputs (set in module data before call):
;   TFTP_PAYLOAD_PTR  -- DW pointer to payload bytes
;   TFTP_PAYLOAD_LEN  -- DW payload length in bytes
;   TFTP_DST_PORT_HI/LO -- destination UDP port (BE bytes)
; Out: BC = total ETH frame length (14 + 20 + 8 + payload_len).
; UDP checksum is set to 0 (allowed in IPv4).
; ------------------------------------------------------
BUILD_UDP_FRAME
	; ETH header
	LD	DE,TX_BUF
	LD	HL,TARGET_MAC
	LD	BC,6
	LDIR
	LD	HL,OUR_MAC
	LD	BC,6
	LDIR
	LD	A,HIGH ETH_TYPE_IPV4
	LD	(DE),A
	INC	DE
	LD	A,LOW ETH_TYPE_IPV4
	LD	(DE),A
	INC	DE

	; IPv4 header. total_len = 20 + 8 + payload_len.
	LD	HL,(TFTP_PAYLOAD_LEN)
	LD	BC,IP_HDR_LEN + UDP_HDR_LEN
	ADD	HL,BC
	LD	(IP_TOTAL_LEN),HL
	LD	A,0x45
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,H
	LD	(DE),A
	INC	DE
	LD	A,L
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	A,64
	LD	(DE),A
	INC	DE
	LD	A,IP_PROTO_UDP
	LD	(DE),A
	INC	DE
	XOR	A			; csum placeholder
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	HL,OUR_IP
	LD	BC,4
	LDIR
	LD	HL,TARGET_IP
	LD	BC,4
	LDIR

	; UDP header. udp_len = 8 + payload_len.
	LD	HL,(TFTP_PAYLOAD_LEN)
	LD	BC,UDP_HDR_LEN
	ADD	HL,BC
	LD	(UDP_LEN),HL
	LD	A,OUR_PORT_HI
	LD	(DE),A
	INC	DE
	LD	A,OUR_PORT_LO
	LD	(DE),A
	INC	DE
	LD	A,(TFTP_DST_PORT_HI)
	LD	(DE),A
	INC	DE
	LD	A,(TFTP_DST_PORT_LO)
	LD	(DE),A
	INC	DE
	LD	A,H
	LD	(DE),A
	INC	DE
	LD	A,L
	LD	(DE),A
	INC	DE
	XOR	A			; UDP csum = 0 (disabled)
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE

	; TFTP payload
	LD	HL,(TFTP_PAYLOAD_PTR)
	LD	BC,(TFTP_PAYLOAD_LEN)
	LD	A,B
	OR	C
	JR	Z,.NOPL
	LDIR
.NOPL
	; Compute IP checksum over TX_BUF+14, length 20.
	PUSH	IX
	LD	IX,TX_BUF + 14
	LD	BC,IP_HDR_LEN
	CALL	@UTIL.CHECKSUM
	POP	IX
	LD	A,H
	LD	(TX_BUF + 14 + 10),A
	LD	A,L
	LD	(TX_BUF + 14 + 11),A

	; Total frame length = 14 + IP total length.
	LD	HL,(IP_TOTAL_LEN)
	LD	BC,14
	ADD	HL,BC
	LD	B,H
	LD	C,L
	RET


; ------------------------------------------------------
; WAIT_FOR_ARP_REPLY: same pattern as PING/UDPTEST.
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
; WAIT_FOR_TFTP_DATA: poll for incoming UDP from TARGET_IP
; with TFTP opcode DATA (3) or OACK (6).
;  - First DATA / OACK from server captures SERVER_PORT.
;  - For DATA: validate block# == EXPECTED_BLOCK; on match
;    set DATA_LEN = (UDP body) - 4.
;  - For OACK: leaves the packet in RX_BUF for PARSE_OACK.
; Out: CF=0 + A = OP_DATA or OP_OACK; CF=1 on timeout / ERROR.
; ------------------------------------------------------
WAIT_FOR_TFTP_DATA
.LP
	CALL	@RTL.RING_HAS_PACKET
	JR	NZ,.HAVE
	CALL	TICK_AND_CHECK_KEY
	JP	C,.TIMEOUT
	LD	HL,(TIMEOUT_MS_LEFT)
	DEC	HL
	LD	(TIMEOUT_MS_LEFT),HL
	LD	A,H
	OR	L
	JP	NZ,.LP
	JP	.TIMEOUT
.HAVE
	LD	HL,RX_HDR
	LD	DE,RX_BUF
	LD	BC,RX_BUF_SIZE
	CALL	@RTL.READ_PACKET
	JP	C,.LP
	LD	A,(RX_BUF + 12)
	CP	HIGH ETH_TYPE_IPV4
	JP	NZ,.LP
	LD	A,(RX_BUF + 13)
	CP	LOW ETH_TYPE_IPV4
	JP	NZ,.LP
	LD	A,(RX_BUF + 14)
	CP	0x45
	JP	NZ,.LP
	LD	A,(RX_BUF + 14 + 9)
	CP	IP_PROTO_UDP
	JP	NZ,.LP
	; src IP == TARGET_IP
	LD	HL,RX_BUF + 14 + 12
	LD	DE,TARGET_IP
	LD	B,4
.CMPSRC
	LD	A,(DE)
	CP	(HL)
	JP	NZ,.LP
	INC	HL
	INC	DE
	DJNZ	.CMPSRC
	; UDP dst_port == OUR_PORT
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 2)
	CP	OUR_PORT_HI
	JP	NZ,.LP
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 3)
	CP	OUR_PORT_LO
	JP	NZ,.LP
	; If SERVER_PORT not yet captured, capture src_port now.
	LD	A,(SERVER_PORT_HI)
	OR	A
	JR	NZ,.HAVE_PORT
	LD	A,(SERVER_PORT_LO)
	OR	A
	JR	NZ,.HAVE_PORT
	; capture
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 0)
	LD	(SERVER_PORT_HI),A
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 1)
	LD	(SERVER_PORT_LO),A
.HAVE_PORT
	; UDP src_port must match SERVER_PORT.
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 0)
	LD	HL,SERVER_PORT_HI
	CP	(HL)
	JP	NZ,.LP
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 1)
	LD	HL,SERVER_PORT_LO
	CP	(HL)
	JP	NZ,.LP
	; TFTP opcode (BE) at offset +14+IP_HDR+UDP_HDR..+1.
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN + 0)
	OR	A
	JP	NZ,.LP_OR_ERR
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN + 1)
	CP	OP_OACK
	JR	Z,.IS_OACK
	CP	OP_DATA
	JP	NZ,.LP_OR_ERR
	; Block# (BE) at offset +14+IP_HDR+UDP_HDR+2..+3.
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN + 2)
	LD	H,A
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN + 3)
	LD	L,A
	; Compare to EXPECTED_BLOCK
	LD	DE,(EXPECTED_BLOCK)
	LD	A,H
	CP	D
	JP	NZ,.LP
	LD	A,L
	CP	E
	JP	NZ,.LP
	; Compute DATA_LEN = UDP_LEN - 8 - 4 (UDP header + TFTP header).
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 5)
	LD	L,A
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 4)
	LD	H,A
	LD	BC,UDP_HDR_LEN + 4
	OR	A
	SBC	HL,BC
	LD	(DATA_LEN),HL
	LD	A,OP_DATA
	OR	A			; CF=0
	RET
.IS_OACK
	; OACK: caller will parse options.  No DATA_LEN to compute.
	LD	A,OP_OACK
	OR	A			; CF=0
	RET
.LP_OR_ERR
	; If TFTP opcode is ERROR, bail with timeout (caller will fail).
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN + 1)
	CP	OP_ERROR
	JR	Z,.TFTP_ERROR
	JP	.LP
.TFTP_ERROR
	SCF
	RET
.TIMEOUT
	SCF
	RET


PRINT_IPV4
	PUSH	HL,BC
	LD	B,4
.LP
	LD	A,(HL)
	CALL	PRINT_DEC_A
	INC	HL
	DEC	B
	JR	Z,.DONE
	PUSH	BC
	LD	A,'.'
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC
	JR	.LP
.DONE
	POP	BC,HL
	RET


PRINT_DEC_A
	PUSH	AF,BC,DE,HL
	LD	C,A
	LD	HL,DEC_BUF + 3
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

DEC_BUF		EQU APP_BSS_BASE + 48 + FILENAME_BUF_SIZE	; 4 bytes scratch for PRINT_DEC_A


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
	JR	Z,.NDONE
	CALL	PUTCHAR
	JR	.NCHR
.NDONE
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


; ------- in-EXE data -------
N_NET_IP	DB "NET_IP",0
N_NET_MAC	DB "NET_MAC",0
MODE_OCTET	DB "octet",0
OPT_BLKSIZE	DB "blksize",0
OPT_VAL_BLK	DB "1428",0

; ------- runtime BSS (lives at APP_BSS_BASE, NOT in .EXE) --
FILENAME_BUF_SIZE EQU 80		; 8.3 + path room
OUR_IP		 EQU APP_BSS_BASE		; 4 bytes
OUR_MAC		 EQU APP_BSS_BASE + 4		; 6 bytes
TARGET_IP	 EQU APP_BSS_BASE + 10		; 4 bytes (from positional arg)
TARGET_MAC	 EQU APP_BSS_BASE + 14		; 6 bytes
TIMEOUT_MS_LEFT	 EQU APP_BSS_BASE + 20		; 2 bytes
SERVER_PORT_HI	 EQU APP_BSS_BASE + 22		; 1 byte
SERVER_PORT_LO	 EQU APP_BSS_BASE + 23		; 1 byte
EXPECTED_BLOCK	 EQU APP_BSS_BASE + 24		; 2 bytes
DATA_LEN	 EQU APP_BSS_BASE + 26		; 2 bytes
TOTAL_BYTES_LO	 EQU APP_BSS_BASE + 28		; 2 bytes (32-bit accumulator, low word)
TOTAL_BYTES_HI	 EQU APP_BSS_BASE + 30		; 2 bytes (high word)
RRQ_LEN		 EQU APP_BSS_BASE + 32		; 2 bytes
IP_TOTAL_LEN	 EQU APP_BSS_BASE + 34		; 2 bytes
UDP_LEN		 EQU APP_BSS_BASE + 36		; 2 bytes
OUT_FH		 EQU APP_BSS_BASE + 38		; 1 byte (set to NO_HANDLE at startup)
CANCELLED	 EQU APP_BSS_BASE + 39		; 1 byte
FORCE_FLAG	 EQU APP_BSS_BASE + 40		; 1 byte (-y / --yes)
TARGET_HOST_PTR	 EQU APP_BSS_BASE + 42		; 2 bytes (-> argv token; reused below)
TFTP_PAYLOAD_PTR EQU APP_BSS_BASE + 42		; 2 bytes
TFTP_PAYLOAD_LEN EQU APP_BSS_BASE + 44		; 2 bytes
TFTP_DST_PORT_HI EQU APP_BSS_BASE + 46		; 1 byte
TFTP_DST_PORT_LO EQU APP_BSS_BASE + 47		; 1 byte
FILENAME_BUF	 EQU APP_BSS_BASE + 48		; FILENAME_BUF_SIZE bytes
; (DEC_BUF lives at APP_BSS_BASE + 48 + FILENAME_BUF_SIZE, 4 bytes)
NEG_BLKSIZE	 EQU APP_BSS_BASE + 52 + FILENAME_BUF_SIZE	; 2 bytes (negotiated block)
OACK_END_PTR	 EQU NEG_BLKSIZE + 2		; 2 bytes (parser end ptr)


; ------- messages -------
MSG_BANNER	DB "RTL8019AS TFTP v0.4",0
MSG_GET_HDR	DB "GET ",0
MSG_FROM_HOST	DB " from ",0
MSG_DONE	DB "Done. ",0
MSG_BYTES_RECV	DB " bytes received.",0
MSG_REGS	DB "REGS ",0
MSG_ABORTED	DB "Aborted by user (Esc/Ctrl+C).",0
MSG_E_RESET	DB "[E80] RESET timeout",0
MSG_E_SEND	DB "[E81] DMA write or PTX timeout",0
MSG_E_ARP	DB "ARP request timed out.",0
MSG_E_TFTP	DB "TFTP timeout or server error.",0
MSG_E_FILE	DB "[E] file create/write/close failed",0
MSG_USAGE_ERR	DB "[E] usage: missing or invalid arguments",0
MSG_E_RESOLVE	DB "[E] could not resolve host (DNS / ARP timeout or NXDOMAIN).",0
MSG_E_NO_DNS1	DB "[E] NET_DNS1 not set; pass an IPv4 literal or run NETCFG/IFUP first.",0
MSG_E_NO_GW	DB "[E] DNS server is off-subnet but NET_GW is not set.",0
MSG_HELP
	DB "Usage:",13,10
	DB "  TFTP host GET filename [-y]",13,10
	DB "  TFTP /?",13,10,13,10
	DB "  host      TFTP server IPv4 (e.g. 192.168.7.1).",13,10
	DB "  GET       fetch operation (only mode supported).",13,10
	DB "  filename  remote file (saved locally with same name).",13,10
	DB "  -y        overwrite local file without prompt.",13,10,13,10
	DB "RFC 2348 blksize=1428 is requested in the RRQ; servers",13,10
	DB "that ignore options fall back to RFC 1350 512-byte blocks.",13,10,0
LINE_END	DB 13,10,0

	ENDMODULE


	; netenv_lib / cmdline_lib transitively DEFINE USE_UTIL_*
	; helpers; include BEFORE util.asm.
	INCLUDE "netenv_lib.asm"
	INCLUDE "cmdline_lib.asm"
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"
	INCLUDE "arp_lib.asm"
	INCLUDE "resolve_lib.asm"
	INCLUDE "dns_lib.asm"
	INCLUDE "file_lib.asm"


TFTP_IMAGE_END

RX_BUF_SIZE	EQU 1518
TFTP_BUF_SIZE	EQU 128			; RRQ + blksize options ~40, room to spare

	MODULE MAIN

TX_BUF		EQU TFTP_IMAGE_END
RX_HDR		EQU TX_BUF + 1518	; max ETH frame (RRQ/ACK fits, DATA up to 558)
RX_BUF		EQU RX_HDR + 4
TFTP_BUF	EQU RX_BUF + RX_BUF_SIZE
TFTP_BSS_END	EQU TFTP_BUF + TFTP_BUF_SIZE

	ENDMODULE

	END MAIN.START
