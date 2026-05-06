; ======================================================
; PING.EXE - stage 6 of the Sprinter RTL8019AS network kit.
; ARP-resolves a hardcoded target IP, sends one ICMP echo
; request and waits for a matching echo reply.
;
; v0.1: hardcoded OUR_IP=192.168.7.2, TARGET_IP=192.168.7.1,
;       single ping. NET.CFG and command-line target arrive
;       in v0.2.
;
; Host setup (single-machine via feth pair):
;   sudo ifconfig feth0 create
;   sudo ifconfig feth1 create
;   sudo ifconfig feth0 peer feth1
;   sudo ifconfig feth0 up
;   sudo ifconfig feth1 inet 192.168.7.1/24 up
; macOS kernel will reply to ARP and ICMP for 192.168.7.1.
;
; Stage codes:
;   [P0] INIT
;   [P1] ARP WHO-HAS <target>
;   [P2] ARP REPLY MAC=...
;   [P3] BUILD ICMP
;   [P4] SEND
;   [P5] WAIT REPLY
;   [P6] REPLY id=... seq=...
;
; This version uses the RTL.INIT_NORMAL / RTL.SEND_FRAME /
; RTL.RING_HAS_PACKET / RTL.READ_PACKET helpers from the
; refactored library.
; ======================================================

EXE_VERSION		EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "memmap.inc"
	INCLUDE "rtl8019.inc"

; Pull in the high-level RTL + ARP + NETCFG helpers we need.
	DEFINE USE_RTL_INIT_NORMAL
	DEFINE USE_RTL_SEND_FRAME
	DEFINE USE_RTL_WAIT_PTX
	DEFINE USE_RTL_RING_HAS_PACKET
	DEFINE USE_RTL_READ_PACKET
	DEFINE USE_ARP_BUILD_REQUEST
	DEFINE USE_NETENV
	DEFINE USE_CMDL
	DEFINE CMDLINE_AT_LARGE			; ORG 0x4100 -> cmd line at IX-0x80 = 0x4180

ARP_TIMEOUT_MS	EQU 3000		; ARP reply budget (ms)
ICMP_TIMEOUT_MS	EQU 1000		; per-echo reply budget (ms, default Windows -w)
SCAN_C		EQU 0xAC		; DSS scancode for the C key (observed)

ETH_TYPE_ARP	EQU 0x0806
ETH_TYPE_IPV4	EQU 0x0800
IP_PROTO_ICMP	EQU 1
ICMP_T_ECHO_REQ	EQU 8
ICMP_T_ECHO_REP	EQU 0

ARP_OP_REQUEST	EQU 1
ARP_OP_REPLY	EQU 2

; -- frame sizes --
ARP_FRAME_LEN	EQU 60			; padded
IP_HDR_LEN	EQU 20
ICMP_HDR_LEN	EQU 8
ICMP_PAYLOAD_LEN EQU 32
ICMP_FRAME_LEN	EQU 14 + IP_HDR_LEN + ICMP_HDR_LEN + ICMP_PAYLOAD_LEN	; 74

ECHO_ID_HI	EQU 0x12
ECHO_ID_LO	EQU 0x34
ECHO_SEQ_HI	EQU 0x00
ECHO_SEQ_LO	EQU 0x01

	MODULE MAIN

	; Large-variant EXE header (256 bytes, 0x4100..0x41FF).
	; Required because the small variant's header sits on top of
	; the DSS command line at 0x8080; this utility takes a host
	; argument and must keep that buffer free.
	ORG 0x4100

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0100			; hdr_size = 256
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START
	DW START
	DW 0xBFFF			; stack at top of directly-addressable RAM
	DS 234, 0

	ORG 0x4200

START
	PRINTLN MSG_BANNER

	; Init CANCELLED (BSS; not zeroed by loader).
	XOR	A
	LD	(CANCELLED),A

	; Tokenize the command line; check for help.
	CALL	@CMDL.PARSE
	CALL	@CMDL.IS_HELP
	JP	NC,SHOW_HELP

	; Defaults: count=4 send, payload=32, TTL=64, timeout=1000ms,
	; forever=off.
	LD	A,4
	LD	(COUNT),A
	LD	A,32
	LD	(PAYLOAD_LEN),A
	LD	A,64
	LD	(TTL_VAL),A
	LD	HL,1000
	LD	(TIMEOUT_MS_VAL),HL
	XOR	A
	LD	(FOREVER),A

	; -t: ping forever.
	LD	A,'t'
	CALL	@CMDL.HAS_FLAG
	JR	C,.NO_T
	LD	A,1
	LD	(FOREVER),A
.NO_T

	; -n count (default 4, max 255).  Ignored when -t set.
	LD	A,'n'
	CALL	@CMDL.GET_FLAG_VALUE
	JR	C,.NO_N
	CALL	@CMDL.PARSE_U16
	JP	C,USAGE_ERROR
	LD	A,H
	OR	A
	JR	Z,.SET_N
	LD	L,255
.SET_N
	LD	A,L
	OR	A
	JP	Z,USAGE_ERROR
	LD	(COUNT),A
.NO_N

	; -l size (default 32, cap 255).
	LD	A,'l'
	CALL	@CMDL.GET_FLAG_VALUE
	JR	C,.NO_L
	CALL	@CMDL.PARSE_U16
	JP	C,USAGE_ERROR
	LD	A,H
	OR	A
	JR	Z,.SET_L
	LD	L,255
.SET_L
	LD	A,L
	LD	(PAYLOAD_LEN),A
.NO_L

	; -i TTL (default 64, range 1..255).
	LD	A,'i'
	CALL	@CMDL.GET_FLAG_VALUE
	JR	C,.NO_I
	CALL	@CMDL.PARSE_U16
	JP	C,USAGE_ERROR
	LD	A,H
	OR	A
	JR	Z,.SET_I
	LD	L,255
.SET_I
	LD	A,L
	OR	A
	JP	Z,USAGE_ERROR
	LD	(TTL_VAL),A
.NO_I

	; -w MS (default 1000, range 1..65535).
	LD	A,'w'
	CALL	@CMDL.GET_FLAG_VALUE
	JR	C,.NO_W
	CALL	@CMDL.PARSE_U16
	JP	C,USAGE_ERROR
	LD	A,H
	OR	L
	JP	Z,USAGE_ERROR
	LD	(TIMEOUT_MS_VAL),HL
.NO_W

	; Mandatory positional: target IPv4.
	LD	B,0
	CALL	@CMDL.GET_POSITIONAL
	JP	C,USAGE_ERROR
	LD	DE,TARGET_IP
	CALL	@CMDL.PARSE_IPV4
	JP	C,USAGE_ERROR

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

	; "Pinging X with N bytes of data:"
	PRINT LINE_END
	PRINT MSG_PINGING
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINT MSG_WITH
	LD	A,(PAYLOAD_LEN)
	CALL	PRINT_DEC_A
	PRINTLN MSG_BYTES_DATA

	; Resolve ARP for target (one-time, before loop).
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

	; Init counters and ICMP sequence.
	XOR	A
	LD	(SENT),A
	LD	(RECVD),A
	LD	A,1
	LD	(SEQ_LO),A
	XOR	A
	LD	(SEQ_HI),A

PING_LOOP
	; Stop condition: -t -> never; otherwise SENT < COUNT.
	LD	A,(FOREVER)
	OR	A
	JR	NZ,.LIVE
	LD	A,(SENT)
	LD	HL,COUNT
	CP	(HL)
	JP	NC,PING_LOOP_END
.LIVE
	; Build and send ICMP echo with current SEQ.
	CALL	BUILD_ICMP_ECHO
	LD	HL,TX_BUF
	; BC = 14 + IP_HDR_LEN + ICMP_HDR_LEN + PAYLOAD_LEN = 42 + payload.
	LD	A,(PAYLOAD_LEN)
	ADD	A,42
	LD	C,A
	LD	B,0
	JR	NC,.NO_HC
	INC	B
.NO_HC
	CALL	@RTL.SEND_FRAME
	JP	C,SEND_FAIL
	; Saturate SENT counter at 255 (overflow stays at 255 in -t mode).
	LD	A,(SENT)
	CP	255
	JR	Z,.SENT_SAT
	INC	A
	LD	(SENT),A
.SENT_SAT

	; Wait for matching reply.
	LD	HL,(TIMEOUT_MS_VAL)
	LD	(TIMEOUT_MS_LEFT),HL
	CALL	WAIT_FOR_ICMP_REPLY
	JR	C,.TIMED_OUT

	; "Reply from X.X.X.X: bytes=N time<1ms TTL=...".
	PRINT MSG_REPLY_FROM
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINT MSG_BYTES_EQ
	LD	A,(PAYLOAD_LEN)
	CALL	PRINT_DEC_A
	PRINT MSG_TIME_TTL_PRE
	LD	A,(TTL_VAL)
	CALL	PRINT_DEC_A
	PRINT LINE_END
	LD	A,(RECVD)
	CP	255
	JR	Z,.RECVD_SAT
	INC	A
	LD	(RECVD),A
.RECVD_SAT
	JR	.NEXT_SEQ

.TIMED_OUT
	; If user cancelled, skip the "Request timed out." line
	; and stop the loop -- "Aborted..." is shown by PING_LOOP_END.
	LD	A,(CANCELLED)
	OR	A
	JR	NZ,PING_LOOP_END
	PRINTLN MSG_TIMED_OUT

.NEXT_SEQ
	LD	HL,SEQ_LO
	INC	(HL)
	JP	NZ,PING_LOOP
	INC	HL			; HL = SEQ_HI (adjacent)
	INC	(HL)
	JP	PING_LOOP

PING_LOOP_END
	; If user cancelled mid-loop, mention it before stats.
	LD	A,(CANCELLED)
	OR	A
	JR	Z,.STATS
	PRINTLN MSG_ABORTED
.STATS
	; Statistics block.
	PRINT LINE_END
	PRINT MSG_STATS_HDR
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINTLN MSG_COLON

	PRINT MSG_PACKETS_SENT
	LD	A,(SENT)
	CALL	PRINT_DEC_A
	PRINT MSG_RECEIVED_EQ
	LD	A,(RECVD)
	CALL	PRINT_DEC_A
	PRINT MSG_LOST_EQ
	; lost = sent - received
	LD	A,(SENT)
	LD	B,A
	LD	A,(RECVD)
	LD	C,A
	LD	A,B
	SUB	C
	CALL	PRINT_DEC_A
	PRINTLN MSG_LOSS_END

	; Exit: 0 if any received, 3 if all lost.
	LD	A,(RECVD)
	OR	A
	JR	Z,.ALL_LOST
	CALL	@ISA.ISA_CLOSE
	JP	@UTIL.EXIT_OK
.ALL_LOST
	CALL	@ISA.ISA_CLOSE
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
	JR	NZ,.CANCEL
	PRINTLN MSG_E_ARP
	JP	FAIL_NIC
.CANCEL
	PRINTLN MSG_ABORTED
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


; ------------------------------------------------------
; BUILD_ICMP_ECHO: 74-byte ICMP echo request frame in TX_BUF.
; ------------------------------------------------------
BUILD_ICMP_ECHO
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

	LD	A,0x45
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	; IP total length = IP_HDR_LEN + ICMP_HDR_LEN + payload = 28 + payload.
	LD	A,(PAYLOAD_LEN)
	ADD	A,IP_HDR_LEN + ICMP_HDR_LEN
	LD	C,A
	LD	B,0
	JR	NC,.IPLEN
	INC	B
.IPLEN
	LD	A,B
	LD	(DE),A			; total length hi
	INC	DE
	LD	A,C
	LD	(DE),A			; total length lo
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
	LD	A,(TTL_VAL)
	LD	(DE),A
	INC	DE
	LD	A,IP_PROTO_ICMP
	LD	(DE),A
	INC	DE
	XOR	A
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

	LD	A,ICMP_T_ECHO_REQ
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	A,ECHO_ID_HI
	LD	(DE),A
	INC	DE
	LD	A,ECHO_ID_LO
	LD	(DE),A
	INC	DE
	LD	A,(SEQ_HI)
	LD	(DE),A
	INC	DE
	LD	A,(SEQ_LO)
	LD	(DE),A
	INC	DE

	LD	A,(PAYLOAD_LEN)
	OR	A
	JR	Z,.PAY_DONE
	LD	B,A
	XOR	A
.PAY
	LD	(DE),A
	INC	DE
	INC	A
	DJNZ	.PAY
.PAY_DONE

	; IP checksum over TX_BUF+14, length 20.
	PUSH	IX
	LD	IX,TX_BUF + 14
	LD	BC,IP_HDR_LEN
	CALL	@UTIL.CHECKSUM
	POP	IX
	LD	A,H
	LD	(TX_BUF + 14 + 10),A
	LD	A,L
	LD	(TX_BUF + 14 + 11),A

	; ICMP checksum over TX_BUF+34, length = ICMP_HDR_LEN + payload.
	; Must be even length for CHECKSUM; payload sizes default to even.
	PUSH	IX
	LD	IX,TX_BUF + 14 + IP_HDR_LEN
	LD	A,(PAYLOAD_LEN)
	ADD	A,ICMP_HDR_LEN
	LD	C,A
	LD	B,0
	JR	NC,.CKLEN
	INC	B
.CKLEN
	CALL	@UTIL.CHECKSUM
	POP	IX
	LD	A,H
	LD	(TX_BUF + 14 + IP_HDR_LEN + 2),A
	LD	A,L
	LD	(TX_BUF + 14 + IP_HDR_LEN + 3),A
	RET


; ------------------------------------------------------
; TICK_AND_CHECK_KEY: ~1 ms wait + non-blocking key poll.
; Esc and Ctrl+C cancel the wait.  SCANKEY may switch
; memory pages, so we close the ISA window around the call.
;   Out: CF=0 normal; CF=1 cancelled (CANCELLED byte set).
;   Trashes A, BC, DE.
; ------------------------------------------------------
TICK_AND_CHECK_KEY
	CALL	@UTIL.DELAY_1MS
	CALL	@ISA.ISA_CLOSE
	LD	C,DSS_SCANKEY
	RST	DSS
	JR	Z,.NO_KEY
	; SCANKEY return: E = ASCII (=A), B = modifiers (KB_*),
	; D = scancode.  Cancel checks:
	; - Esc: E = 0x1B (no modifier required).
	; - Ctrl+C: DSS does not deliver 'C' ASCII while Ctrl is
	;   held; we recognise the C-key scancode (SCAN_C) plus a
	;   Ctrl modifier bit in B.
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
; WAIT_FOR_ARP_REPLY: spin on RTL.RING_HAS_PACKET +
; RTL.READ_PACKET, drop anything that isn't a matching ARP
; reply, populate TARGET_MAC on match.
;   TIMEOUT_MS_LEFT must be set before call.
;   Out: CF=0 OK, CF=1 timeout.
; ------------------------------------------------------
WAIT_FOR_ARP_REPLY
.LP
	CALL	@RTL.RING_HAS_PACKET
	JR	NZ,.HAVE
	CALL	TICK_AND_CHECK_KEY	; ~1ms wait + ESC/Ctrl-C poll
	JR	C,.TIMEOUT		; cancelled
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
	JR	C,.LP			; DMA error, drop and continue
	; Filter: ARP reply, sender_ip == TARGET_IP
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
	; Match: copy sender MAC to TARGET_MAC.
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
; WAIT_FOR_ICMP_REPLY: same loop pattern, ICMP echo-reply
; filter, capture id/seq.
;   Out: CF=0 OK, CF=1 timeout.
; ------------------------------------------------------
WAIT_FOR_ICMP_REPLY
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
	; Filter: IPv4 / ICMP / echo reply / matching id.
	LD	A,(RX_BUF + 12)
	CP	HIGH ETH_TYPE_IPV4
	JR	NZ,.LP
	LD	A,(RX_BUF + 13)
	CP	LOW ETH_TYPE_IPV4
	JR	NZ,.LP
	LD	A,(RX_BUF + 14)
	CP	0x45
	JR	NZ,.LP
	LD	A,(RX_BUF + 14 + 9)
	CP	IP_PROTO_ICMP
	JR	NZ,.LP
	LD	HL,RX_BUF + 14 + 12
	LD	DE,TARGET_IP
	LD	B,4
.CMPSRC
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.LP
	INC	HL
	INC	DE
	DJNZ	.CMPSRC
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 0)
	CP	ICMP_T_ECHO_REP
	JR	NZ,.LP
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 4)
	CP	ECHO_ID_HI
	JR	NZ,.LP
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 5)
	CP	ECHO_ID_LO
	JR	NZ,.LP
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 4)
	LD	(REPLY_ID + 0),A
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 5)
	LD	(REPLY_ID + 1),A
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 6)
	LD	(REPLY_SEQ + 0),A
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 7)
	LD	(REPLY_SEQ + 1),A
	OR	A
	RET
.TIMEOUT
	SCF
	RET


; ------------------------------------------------------
; PRINT_IPV4 / PRINT_DEC_A / PUTCHAR / PRINT_REG_DUMP
; (app-local helpers; could be lifted to lib later)
; ------------------------------------------------------
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

; ------- runtime BSS (lives at APP_BSS_BASE, NOT in .EXE) --
OUR_IP		EQU APP_BSS_BASE		; 4 bytes
OUR_MAC		EQU APP_BSS_BASE + 4		; 6 bytes
TARGET_IP	EQU APP_BSS_BASE + 10		; 4 bytes (filled from positional arg)
TARGET_MAC	EQU APP_BSS_BASE + 14		; 6 bytes
TIMEOUT_MS_LEFT	EQU APP_BSS_BASE + 20		; 2 bytes
REPLY_ID	EQU APP_BSS_BASE + 22		; 2 bytes
REPLY_SEQ	EQU APP_BSS_BASE + 24		; 2 bytes
DEC_BUF		EQU APP_BSS_BASE + 26		; 4 bytes scratch for PRINT_DEC_A
COUNT		EQU APP_BSS_BASE + 30		; 1 byte (default 4, max 255)
SENT		EQU APP_BSS_BASE + 31		; 1 byte
RECVD		EQU APP_BSS_BASE + 32		; 1 byte
SEQ_LO		EQU APP_BSS_BASE + 33		; 1 byte (must be adjacent to SEQ_HI)
SEQ_HI		EQU APP_BSS_BASE + 34		; 1 byte
CANCELLED	EQU APP_BSS_BASE + 35		; 1 byte (set by TICK_AND_CHECK_KEY)
PAYLOAD_LEN	EQU APP_BSS_BASE + 36		; 1 byte (-l size, default 32)
TTL_VAL		EQU APP_BSS_BASE + 37		; 1 byte (-i TTL, default 64)
TIMEOUT_MS_VAL	EQU APP_BSS_BASE + 38		; 2 bytes (-w ms, default 1000)
FOREVER		EQU APP_BSS_BASE + 40		; 1 byte (1 if -t set)


; ------- messages -------
MSG_BANNER	DB "RTL8019AS PING v0.2",0
MSG_PINGING	DB "Pinging ",0
MSG_WITH	DB " with ",0
MSG_BYTES_DATA	DB " bytes of data:",0
MSG_REPLY_FROM	DB "Reply from ",0
MSG_BYTES_EQ	DB ": bytes=",0
MSG_TIME_TTL_PRE DB " time<1ms TTL=",0
MSG_TIMED_OUT	DB "Request timed out.",0
MSG_ABORTED	DB "Aborted by user (Esc/Ctrl+C).",0
MSG_STATS_HDR	DB "Ping statistics for ",0
MSG_COLON	DB ":",0
MSG_PACKETS_SENT DB "    Packets: Sent = ",0
MSG_RECEIVED_EQ	DB ", Received = ",0
MSG_LOST_EQ	DB ", Lost = ",0
MSG_LOSS_END	DB ".",0
MSG_REGS	DB "REGS ",0
MSG_E_RESET	DB "[E60] RESET timeout",0
MSG_E_SEND	DB "[E61] DMA write or PTX timeout",0
MSG_E_ARP	DB "[E62] ARP reply timeout",0
MSG_USAGE_ERR	DB "[E] usage: missing or invalid target IPv4",0
MSG_HELP
	DB "Usage:",13,10
	DB "  PING [-t] [-n count] [-l size] [-i TTL] [-w ms] target",13,10
	DB "  PING /?",13,10,13,10
	DB "  -t        ping until interrupted (Esc/Ctrl+C).",13,10
	DB "  -n count  number of echo requests (default 4, max 255).",13,10
	DB "  -l size   payload size in bytes (default 32, max 255).",13,10
	DB "  -i TTL    IP TTL on outgoing requests (default 64).",13,10
	DB "  -w ms     per-reply wait timeout (default 1000 ms).",13,10
	DB "  target    destination IPv4 (e.g. 192.168.7.1).",13,10,0
LINE_END	DB 13,10,0

	ENDMODULE


	; netenv_lib / cmdline_lib transitively DEFINE USE_UTIL_*
	; helpers they need, so they must be included BEFORE util.asm.
	INCLUDE "netenv_lib.asm"
	INCLUDE "cmdline_lib.asm"
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"
	INCLUDE "arp_lib.asm"


PING_IMAGE_END

RX_BUF_SIZE	EQU 1518

	MODULE MAIN

; Largest ICMP echo frame we may send: 14 + 20 + 8 + 255 = 297 bytes.
ICMP_FRAME_MAX	EQU 14 + IP_HDR_LEN + ICMP_HDR_LEN + 255
TX_BUF		EQU PING_IMAGE_END
RX_HDR		EQU TX_BUF + ICMP_FRAME_MAX
RX_BUF		EQU RX_HDR + 4
PING_BSS_END	EQU RX_BUF + RX_BUF_SIZE

	ENDMODULE

	END MAIN.START
