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
; ======================================================

EXE_VERSION		EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "rtl8019.inc"

PTX_LOOPS	EQU 16000
ARP_OUTER	EQU 32			; ~15s ARP budget
ICMP_OUTER	EQU 32			; ~15s ICMP reply budget

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

; -- echo identifiers --
ECHO_ID_HI	EQU 0x12
ECHO_ID_LO	EQU 0x34
ECHO_SEQ_HI	EQU 0x00
ECHO_SEQ_LO	EQU 0x01

	MODULE MAIN

	ORG 0x8080

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0080
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START
	DW START
	DW STACK_TOP
	DS 106, 0

	ORG 0x8100
@STACK_TOP

START
	PRINTLN MSG_BANNER

	LD	A,1
	LD	(@ISA.ISA_SLOT),A
	CALL	@ISA.ISA_OPEN

	; [P0] INIT
	PRINT MSG_P0
	CALL	@RTL.RESET
	JP	C,RESET_FAIL
	CALL	CONFIG_NORMAL
	PRINTLN MSG_OK

	PRINT MSG_PING_HDR
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINT MSG_FROM
	LD	HL,OUR_IP
	CALL	PRINT_IPV4
	PRINT LINE_END

	; [P1] ARP
	PRINT MSG_P1
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINT LINE_END

	CALL	BUILD_ARP_REQUEST
	LD	BC,ARP_FRAME_LEN
	CALL	SEND_FRAME
	JP	C,SEND_FAIL

	LD	HL,ARP_OUTER
	LD	(OUTER_LEFT),HL
	CALL	WAIT_FOR_ARP_REPLY
	JP	C,ARP_TIMEOUT

	; [P2] ARP REPLY
	PRINT MSG_P2
	LD	HL,TARGET_MAC
	CALL	@UTIL.PRINT_MAC
	PRINT LINE_END

	; [P3] BUILD ICMP
	CALL	BUILD_ICMP_ECHO
	PRINTLN MSG_P3

	; [P4] SEND
	PRINT MSG_P4
	LD	BC,ICMP_FRAME_LEN
	CALL	SEND_FRAME
	JP	C,SEND_FAIL
	PRINTLN MSG_OK

	; [P5] WAIT REPLY
	PRINTLN MSG_P5
	LD	HL,ICMP_OUTER
	LD	(OUTER_LEFT),HL
	CALL	WAIT_FOR_ICMP_REPLY
	JP	C,ICMP_TIMEOUT

	; [P6] REPLY id=xxxx seq=xxxx
	PRINT MSG_P6_ID
	LD	A,(REPLY_ID + 0)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,(REPLY_ID + 1)
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_SEQ_EQ
	LD	A,(REPLY_SEQ + 0)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,(REPLY_SEQ + 1)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END

	PRINTLN MSG_RESULT_OK
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_OK


RESET_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_RESET
	JP	FAIL_NIC

SEND_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_SEND
	JP	FAIL_NIC

ARP_TIMEOUT
	PRINTLN MSG_E_ARP
	JP	FAIL_NIC

ICMP_TIMEOUT
	PRINTLN MSG_E_ICMP
	JP	FAIL_NIC

FAIL_NIC
	CALL	@RTL.SNAPSHOT_REGS
	CALL	PRINT_REG_DUMP
	PRINTLN MSG_RESULT_FAIL
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_NIC_ERR


; ------------------------------------------------------
; CONFIG_NORMAL: standard chip init.
; ------------------------------------------------------
CONFIG_NORMAL
	LD	A,CR_PAGE0_STOP
	LD	(RTL_CR_A),A
	LD	A,DCR_INIT
	LD	(RTL_DCR_A),A
	XOR	A
	LD	(RTL_RBCR0_A),A
	LD	(RTL_RBCR1_A),A
	LD	A,RCR_AB
	LD	(RTL_RCR_A),A
	LD	A,TCR_NORMAL
	LD	(RTL_TCR_A),A
	LD	A,RTL_TPSR_INIT
	LD	(RTL_TPSR_A),A
	LD	A,RTL_PSTART_INIT
	LD	(RTL_PSTART_A),A
	LD	A,RTL_PSTOP_INIT
	LD	(RTL_PSTOP_A),A
	LD	A,RTL_BNRY_INIT
	LD	(RTL_BNRY_A),A
	LD	A,0xFF
	LD	(RTL_ISR_A),A
	XOR	A
	LD	(RTL_IMR_A),A

	LD	A,CR_PAGE1_STOP
	LD	(RTL_CR_A),A
	LD	A,(OUR_MAC + 0)
	LD	(RTL_PAR0_A),A
	LD	A,(OUR_MAC + 1)
	LD	(RTL_PAR1_A),A
	LD	A,(OUR_MAC + 2)
	LD	(RTL_PAR2_A),A
	LD	A,(OUR_MAC + 3)
	LD	(RTL_PAR3_A),A
	LD	A,(OUR_MAC + 4)
	LD	(RTL_PAR4_A),A
	LD	A,(OUR_MAC + 5)
	LD	(RTL_PAR5_A),A
	LD	A,RTL_CURR_INIT
	LD	(RTL_CURR_A),A
	XOR	A
	LD	(RTL_MAR0_A + 0),A
	LD	(RTL_MAR0_A + 1),A
	LD	(RTL_MAR0_A + 2),A
	LD	(RTL_MAR0_A + 3),A
	LD	(RTL_MAR0_A + 4),A
	LD	(RTL_MAR0_A + 5),A
	LD	(RTL_MAR0_A + 6),A
	LD	(RTL_MAR0_A + 7),A

	LD	A,CR_PAGE0_START
	LD	(RTL_CR_A),A
	RET


; ------------------------------------------------------
; SEND_FRAME: DMA_WRITE BC bytes from TX_BUF to packet RAM
; 0x4000, set TBCR=BC, trigger TX, wait PTX.
; In: BC = frame length.
; Out: CF=0 OK, CF=1 fail.
; ------------------------------------------------------
SEND_FRAME
	LD	(TX_LEN),BC
	LD	HL,TX_BUF
	LD	DE,0x4000
	CALL	@RTL.DMA_WRITE
	RET	C
	LD	HL,(TX_LEN)
	LD	A,L
	LD	(RTL_TBCR0_A),A
	LD	A,H
	LD	(RTL_TBCR1_A),A
	LD	A,CR_PAGE0_START | CR_TXP
	LD	(RTL_CR_A),A
	; fall through to WAIT_PTX

WAIT_PTX
	LD	BC,PTX_LOOPS
.LP
	LD	A,(RTL_ISR_A)
	AND	ISR_PTX
	JR	NZ,.OK
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.LP
	SCF
	RET
.OK
	LD	A,ISR_PTX
	LD	(RTL_ISR_A),A
	OR	A
	RET


; ------------------------------------------------------
; BUILD_ARP_REQUEST: 60-byte broadcast ARP "who-has" in TX_BUF.
; ------------------------------------------------------
BUILD_ARP_REQUEST
	LD	DE,TX_BUF
	; DST = FF*6
	LD	A,0xFF
	LD	B,6
.DST
	LD	(DE),A
	INC	DE
	DJNZ	.DST
	; SRC = OUR_MAC
	LD	HL,OUR_MAC
	LD	BC,6
	LDIR
	; EtherType = 0x0806
	LD	A,HIGH ETH_TYPE_ARP
	LD	(DE),A
	INC	DE
	LD	A,LOW ETH_TYPE_ARP
	LD	(DE),A
	INC	DE
	; ARP body: HW=Ethernet, Proto=IPv4, sizes, op=request
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	INC	DE
	LD	A,0x08
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,6
	LD	(DE),A
	INC	DE
	LD	A,4
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,ARP_OP_REQUEST
	LD	(DE),A
	INC	DE
	LD	HL,OUR_MAC
	LD	BC,6
	LDIR
	LD	HL,OUR_IP
	LD	BC,4
	LDIR
	XOR	A
	LD	B,6
.TGT_MAC
	LD	(DE),A
	INC	DE
	DJNZ	.TGT_MAC
	LD	HL,TARGET_IP
	LD	BC,4
	LDIR
	; pad zero up to 60
	XOR	A
	LD	B,ARP_FRAME_LEN - 14 - 28
.PAD
	LD	(DE),A
	INC	DE
	DJNZ	.PAD
	RET


; ------------------------------------------------------
; BUILD_ICMP_ECHO: 74-byte ICMP echo request frame in TX_BUF.
; Layout:
;   [0..5]   DST MAC = TARGET_MAC (resolved by ARP)
;   [6..11]  SRC MAC = OUR_MAC
;   [12..13] EtherType = 0x0800
;   [14..33] IPv4 header (20 bytes)
;   [34..41] ICMP header (8 bytes: type, code, csum, id, seq)
;   [42..73] ICMP payload (32 bytes: 0..31)
; Computes IP and ICMP checksums in place.
; ------------------------------------------------------
BUILD_ICMP_ECHO
	; Ethernet
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

	; IPv4 header at TX_BUF + 14
	LD	A,0x45			; version 4, IHL 5
	LD	(DE),A
	INC	DE
	XOR	A			; TOS
	LD	(DE),A
	INC	DE
	LD	A,HIGH (IP_HDR_LEN + ICMP_HDR_LEN + ICMP_PAYLOAD_LEN)
	LD	(DE),A
	INC	DE
	LD	A,LOW (IP_HDR_LEN + ICMP_HDR_LEN + ICMP_PAYLOAD_LEN)
	LD	(DE),A
	INC	DE
	XOR	A			; ID = 0x0001
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	INC	DE
	XOR	A			; flags+frag = 0
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	A,64			; TTL
	LD	(DE),A
	INC	DE
	LD	A,IP_PROTO_ICMP
	LD	(DE),A
	INC	DE
	XOR	A			; csum placeholder lo/hi
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	HL,OUR_IP		; src IP
	LD	BC,4
	LDIR
	LD	HL,TARGET_IP		; dst IP
	LD	BC,4
	LDIR

	; ICMP header at TX_BUF + 34
	LD	A,ICMP_T_ECHO_REQ
	LD	(DE),A
	INC	DE
	XOR	A			; code
	LD	(DE),A
	INC	DE
	XOR	A			; csum placeholder
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
	LD	A,ECHO_SEQ_HI
	LD	(DE),A
	INC	DE
	LD	A,ECHO_SEQ_LO
	LD	(DE),A
	INC	DE

	; ICMP payload: bytes 0..31
	LD	B,ICMP_PAYLOAD_LEN
	XOR	A
.PAY
	LD	(DE),A
	INC	DE
	INC	A
	DJNZ	.PAY

	; -- compute IP checksum over TX_BUF+14, length 20 --
	PUSH	IX
	LD	IX,TX_BUF + 14
	LD	BC,IP_HDR_LEN
	CALL	@UTIL.CHECKSUM
	POP	IX
	; HL = ~accum, store as BE bytes at TX_BUF + 14 + 10
	LD	A,H
	LD	(TX_BUF + 14 + 10),A
	LD	A,L
	LD	(TX_BUF + 14 + 11),A

	; -- compute ICMP checksum over TX_BUF+34, length 40 --
	PUSH	IX
	LD	IX,TX_BUF + 14 + IP_HDR_LEN
	LD	BC,ICMP_HDR_LEN + ICMP_PAYLOAD_LEN
	CALL	@UTIL.CHECKSUM
	POP	IX
	LD	A,H
	LD	(TX_BUF + 14 + IP_HDR_LEN + 2),A
	LD	A,L
	LD	(TX_BUF + 14 + IP_HDR_LEN + 3),A
	RET


; ------------------------------------------------------
; WAIT_FOR_ARP_REPLY: ring-state-based wait, drops non-ARP-
; reply frames, populates TARGET_MAC on match.
; OUTER_LEFT must be initialized before call.
; Out: CF=0 OK, CF=1 timeout.
; ------------------------------------------------------
WAIT_FOR_ARP_REPLY
.MAIN
	CALL	RING_NONEMPTY
	JR	NZ,.HAVE
	LD	BC,0
.WAIT
	CALL	RING_NONEMPTY
	JR	NZ,.HAVE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.WAIT
	LD	HL,(OUTER_LEFT)
	DEC	HL
	LD	(OUTER_LEFT),HL
	LD	A,H
	OR	L
	JR	Z,.TIMEOUT
	JR	.MAIN
.HAVE
	LD	A,ISR_PRX
	LD	(RTL_ISR_A),A
	CALL	READ_RX
	JR	C,.DROP
	; Filter: ARP reply matching TARGET_IP.
	LD	A,(RX_BUF + 12)
	CP	HIGH ETH_TYPE_ARP
	JR	NZ,.DROP
	LD	A,(RX_BUF + 13)
	CP	LOW ETH_TYPE_ARP
	JR	NZ,.DROP
	LD	A,(RX_BUF + 14 + 6)
	OR	A
	JR	NZ,.DROP
	LD	A,(RX_BUF + 14 + 7)
	CP	ARP_OP_REPLY
	JR	NZ,.DROP
	LD	HL,RX_BUF + 14 + 14
	LD	DE,TARGET_IP
	LD	B,4
.CMPIP
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.DROP
	INC	HL
	INC	DE
	DJNZ	.CMPIP
	; Match: copy sender MAC to TARGET_MAC.
	LD	HL,RX_BUF + 14 + 8
	LD	DE,TARGET_MAC
	LD	BC,6
	LDIR
	CALL	ADVANCE_BNRY
	OR	A
	RET
.DROP
	CALL	ADVANCE_BNRY
	JR	.MAIN
.TIMEOUT
	SCF
	RET


; ------------------------------------------------------
; WAIT_FOR_ICMP_REPLY: ring-state-based wait, drops anything
; that isn't an ICMP echo reply matching our identifier.
; Populates REPLY_ID, REPLY_SEQ on match.
; Out: CF=0 OK, CF=1 timeout.
; ------------------------------------------------------
WAIT_FOR_ICMP_REPLY
.MAIN
	CALL	RING_NONEMPTY
	JR	NZ,.HAVE
	LD	BC,0
.WAIT
	CALL	RING_NONEMPTY
	JR	NZ,.HAVE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.WAIT
	LD	HL,(OUTER_LEFT)
	DEC	HL
	LD	(OUTER_LEFT),HL
	LD	A,H
	OR	L
	JR	Z,.TIMEOUT
	JR	.MAIN
.HAVE
	LD	A,ISR_PRX
	LD	(RTL_ISR_A),A
	CALL	READ_RX
	JR	C,.DROP
	; Filter: IPv4 / ICMP / echo reply / matching id.
	LD	A,(RX_BUF + 12)
	CP	HIGH ETH_TYPE_IPV4
	JR	NZ,.DROP
	LD	A,(RX_BUF + 13)
	CP	LOW ETH_TYPE_IPV4
	JR	NZ,.DROP
	; IP version+IHL: must be 0x45 (no options for our path).
	LD	A,(RX_BUF + 14)
	CP	0x45
	JR	NZ,.DROP
	; protocol == ICMP
	LD	A,(RX_BUF + 14 + 9)
	CP	IP_PROTO_ICMP
	JR	NZ,.DROP
	; src IP == TARGET_IP
	LD	HL,RX_BUF + 14 + 12
	LD	DE,TARGET_IP
	LD	B,4
.CMPSRC
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.DROP
	INC	HL
	INC	DE
	DJNZ	.CMPSRC
	; ICMP type == 0 (echo reply)
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 0)
	CP	ICMP_T_ECHO_REP
	JR	NZ,.DROP
	; identifier match
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 4)
	CP	ECHO_ID_HI
	JR	NZ,.DROP
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 5)
	CP	ECHO_ID_LO
	JR	NZ,.DROP
	; Capture id and seq for printing.
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 4)
	LD	(REPLY_ID + 0),A
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 5)
	LD	(REPLY_ID + 1),A
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 6)
	LD	(REPLY_SEQ + 0),A
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 7)
	LD	(REPLY_SEQ + 1),A
	CALL	ADVANCE_BNRY
	OR	A
	RET
.DROP
	CALL	ADVANCE_BNRY
	JP	.MAIN
.TIMEOUT
	SCF
	RET


; ------------------------------------------------------
; READ_RX: read header at (BNRY+1)<<8 + body into RX_HDR / RX_BUF.
; Out: CF=0 OK, BODY_LEN populated.
;      CF=1 DMA error (caller drops).
; ------------------------------------------------------
READ_RX
	LD	A,(RTL_BNRY_A)
	INC	A
	CP	RTL_PSTOP_INIT
	JR	C,.NW
	LD	A,RTL_PSTART_INIT
.NW
	LD	D,A
	LD	E,0
	PUSH	DE
	LD	HL,RX_HDR
	LD	BC,4
	CALL	@RTL.DMA_READ
	POP	DE
	RET	C
	; body length = header.len - 4, capped
	LD	A,(RX_HDR + 2)
	LD	L,A
	LD	A,(RX_HDR + 3)
	LD	H,A
	LD	BC,4
	OR	A
	SBC	HL,BC
	LD	BC,RX_BUF_SIZE
	LD	A,H
	CP	B
	JR	C,.OKLEN
	JR	NZ,.CAPLEN
	LD	A,L
	CP	C
	JR	C,.OKLEN
.CAPLEN
	LD	HL,RX_BUF_SIZE
.OKLEN
	LD	(BODY_LEN),HL
	INC	DE
	INC	DE
	INC	DE
	INC	DE
	LD	HL,RX_BUF
	LD	BC,(BODY_LEN)
	JP	@RTL.DMA_READ


; ------------------------------------------------------
; RING_NONEMPTY: ZF=1 if (BNRY+1)==CURR.
; ------------------------------------------------------
RING_NONEMPTY
	LD	A,(RTL_BNRY_A)
	INC	A
	CP	RTL_PSTOP_INIT
	JR	C,.NW
	LD	A,RTL_PSTART_INIT
.NW
	LD	B,A
	LD	A,CR_PAGE1_START
	LD	(RTL_CR_A),A
	LD	A,(RTL_CURR_A)
	LD	C,A
	LD	A,CR_PAGE0_START
	LD	(RTL_CR_A),A
	LD	A,B
	CP	C
	RET


ADVANCE_BNRY
	LD	A,(RX_HDR + 1)
	DEC	A
	CP	RTL_PSTART_INIT
	JR	NC,.OK
	LD	A,RTL_PSTOP_INIT - 1
.OK
	LD	(RTL_BNRY_A),A
	RET


; ------------------------------------------------------
; PRINT_IPV4: HL points at 4 bytes; print "a.b.c.d".
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

DEC_BUF		DS 4,0


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
OUR_MAC		DB 0x02, 0x80, 0x19, 0x11, 0x22, 0x33
OUR_IP		DB 192, 168, 7, 2
TARGET_IP	DB 192, 168, 7, 1
TARGET_MAC	DB 0,0,0,0,0,0
TX_LEN		DW 0
BODY_LEN	DW 0
OUTER_LEFT	DW 0
REPLY_ID	DW 0
REPLY_SEQ	DW 0


; ------- messages -------
MSG_BANNER	DB "RTL8019AS PING v0.1",0
MSG_PING_HDR	DB "PING ",0
MSG_FROM	DB " from ",0
MSG_P0		DB "[P0] INIT ",0
MSG_OK		DB "OK",0
MSG_P1		DB "[P1] ARP WHO-HAS ",0
MSG_P2		DB "[P2] ARP REPLY MAC=",0
MSG_P3		DB "[P3] BUILD ICMP OK",0
MSG_P4		DB "[P4] SEND ",0
MSG_P5		DB "[P5] WAIT REPLY",0
MSG_P6_ID	DB "[P6] REPLY id=",0
MSG_SEQ_EQ	DB " seq=",0
MSG_REGS	DB "REGS ",0
MSG_RESULT_OK	DB "RESULT OK",0
MSG_RESULT_FAIL	DB "RESULT FAIL",0
MSG_E_RESET	DB "[E60] RESET timeout",0
MSG_E_SEND	DB "[E61] DMA write or PTX timeout",0
MSG_E_ARP	DB "[E62] ARP reply timeout",0
MSG_E_ICMP	DB "[E63] ICMP echo reply timeout",0
LINE_END	DB 13,10,0

	ENDMODULE


	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"


PING_IMAGE_END

RX_BUF_SIZE	EQU 1518

	MODULE MAIN

TX_BUF		EQU PING_IMAGE_END
RX_HDR		EQU TX_BUF + ICMP_FRAME_LEN
RX_BUF		EQU RX_HDR + 4
PING_BSS_END	EQU RX_BUF + RX_BUF_SIZE

	ENDMODULE

	END MAIN.START
