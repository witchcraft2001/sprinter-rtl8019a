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

	DEFINE USE_RTL_INIT_NORMAL
	DEFINE USE_RTL_SEND_FRAME
	DEFINE USE_RTL_WAIT_PTX
	DEFINE USE_RTL_RING_HAS_PACKET
	DEFINE USE_RTL_READ_PACKET
	DEFINE USE_ARP_BUILD_REQUEST
	DEFINE USE_NETENV
	DEFINE USE_CMDL
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

; -- TFTP defaults
TFTP_BLOCK	EQU 512

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

	; positional 0: host (IPv4)
	LD	B,0
	CALL	@CMDL.GET_POSITIONAL
	JP	C,USAGE_ERROR
	LD	DE,TARGET_IP
	CALL	@CMDL.PARSE_IPV4
	JP	C,USAGE_ERROR

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
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.RESET
	JP	C,RESET_FAIL
	LD	HL,OUR_MAC
	LD	A,RCR_AB
	CALL	@RTL.INIT_NORMAL
	LD	HL,OUR_MAC
	LD	(@ARP.OUR_MAC_PTR),HL
	LD	HL,OUR_IP
	LD	(@ARP.OUR_IP_PTR),HL
	; Init TFTP state.
	LD	A,NO_HANDLE
	LD	(OUT_FH),A
	LD	HL,1
	LD	(EXPECTED_BLOCK),HL
	XOR	A
	LD	(SERVER_PORT_HI),A
	LD	(SERVER_PORT_LO),A
	LD	HL,0
	LD	(TOTAL_BYTES),HL

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

	; Open output file.
	LD	HL,FILENAME_BUF
	LD	A,FA_ARCHIVE
	LD	C,DSS_CREATE_OVERWRITE
	RST	DSS
	JP	C,FILE_FAIL
	LD	(OUT_FH),A

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
	; Accumulate total bytes.
	LD	HL,(DATA_LEN)
	LD	BC,(TOTAL_BYTES)
	ADD	HL,BC
	LD	(TOTAL_BYTES),HL
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

	; If DATA_LEN < 512, this was the last block.
	LD	HL,(DATA_LEN)
	LD	DE,TFTP_BLOCK
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
	LD	HL,(TOTAL_BYTES)
	CALL	PRINT_DEC_HL
	PRINTLN MSG_BYTES_RECV

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
; PRINT_DEC_HL: print HL as unsigned decimal, no leading zeros.
; Trashes A, BC, DE.
; ------------------------------------------------------
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
	LD	B,0			; B = digit count
.LP
	LD	A,H
	OR	L
	JR	Z,.PRT
	PUSH	BC			; DIV_HL_10 trashes BC
	CALL	DIV_HL_10
	POP	BC
	ADD	A,'0'
	PUSH	AF
	INC	B
	JR	.LP
.PRT
	LD	A,B
	OR	A
	JR	Z,.DONE
.OUTL
	POP	AF
	CALL	PUTCHAR
	DJNZ	.OUTL
.DONE
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


; ------------------------------------------------------
; BUILD_RRQ_PAYLOAD: TFTP_BUF = opcode_RRQ(BE) + filename + 0
; + "octet" + 0. Sets RRQ_LEN.
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
; with TFTP DATA opcode (3) and matching block#. On match:
;  - capture server source port into SERVER_PORT (first packet).
;  - validate block# == EXPECTED_BLOCK.
;  - set DATA_LEN = (UDP body) - 4 (TFTP header).
;  - body bytes are at RX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN + 4.
; Out: CF=0 OK, CF=1 timeout.
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
	OR	A
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

DEC_BUF		EQU APP_BSS_BASE + 44 + FILENAME_BUF_SIZE	; 4 bytes scratch for PRINT_DEC_A


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
TOTAL_BYTES	 EQU APP_BSS_BASE + 28		; 2 bytes
RRQ_LEN		 EQU APP_BSS_BASE + 30		; 2 bytes
IP_TOTAL_LEN	 EQU APP_BSS_BASE + 32		; 2 bytes
UDP_LEN		 EQU APP_BSS_BASE + 34		; 2 bytes
OUT_FH		 EQU APP_BSS_BASE + 36		; 1 byte (set to NO_HANDLE at startup)
CANCELLED	 EQU APP_BSS_BASE + 37		; 1 byte
TFTP_PAYLOAD_PTR EQU APP_BSS_BASE + 38		; 2 bytes
TFTP_PAYLOAD_LEN EQU APP_BSS_BASE + 40		; 2 bytes
TFTP_DST_PORT_HI EQU APP_BSS_BASE + 42		; 1 byte
TFTP_DST_PORT_LO EQU APP_BSS_BASE + 43		; 1 byte
FILENAME_BUF	 EQU APP_BSS_BASE + 44		; FILENAME_BUF_SIZE bytes


; ------- messages -------
MSG_BANNER	DB "RTL8019AS TFTP v0.2",0
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
MSG_HELP
	DB "Usage:",13,10
	DB "  TFTP host GET filename",13,10
	DB "  TFTP /?",13,10,13,10
	DB "  host      TFTP server IPv4 (e.g. 192.168.7.1).",13,10
	DB "  GET       fetch operation (only mode supported).",13,10
	DB "  filename  remote file (saved locally with same name).",13,10,0
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


TFTP_IMAGE_END

RX_BUF_SIZE	EQU 1518
TFTP_BUF_SIZE	EQU 32			; RRQ <= 17, ACK = 4

	MODULE MAIN

TX_BUF		EQU TFTP_IMAGE_END
RX_HDR		EQU TX_BUF + 1518	; max ETH frame (RRQ/ACK fits, DATA up to 558)
RX_BUF		EQU RX_HDR + 4
TFTP_BUF	EQU RX_BUF + RX_BUF_SIZE
TFTP_BSS_END	EQU TFTP_BUF + TFTP_BUF_SIZE

	ENDMODULE

	END MAIN.START
