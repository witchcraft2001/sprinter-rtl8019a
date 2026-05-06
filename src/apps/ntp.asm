; ======================================================
; NTP.EXE - Stage 8 of the Sprinter RTL8019AS network kit.
; Sends an NTPv3 client query to a numeric IPv4 server,
; receives the reply, prints the server's transmit time.
;
; v0.1 (this commit): network round-trip + raw NTP timestamp.
; v0.2 (next): convert NTP epoch to YYYY-MM-DD HH:MM:SS (UTC).
; v0.3 (next): apply NET_TZ for local time + optional DSS_SETTIME.
;
; Usage:
;   NTP server-ipv4
;   NTP /?
;
; Exit codes: 0 ok, 1 usage, 2 no NIC, 3 ARP/NTP timeout, 4 cfg.
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
	DEFINE USE_RESOLVE
	DEFINE USE_CMDL
	DEFINE CMDLINE_AT_LARGE

ARP_TIMEOUT_MS	EQU 3000
NTP_TIMEOUT_MS	EQU 5000
SCAN_C		EQU 0xAC

ETH_TYPE_ARP	EQU 0x0806
ETH_TYPE_IPV4	EQU 0x0800
IP_PROTO_UDP	EQU 17

ARP_OP_REQUEST	EQU 1
ARP_OP_REPLY	EQU 2

ARP_FRAME_LEN	EQU 60
IP_HDR_LEN	EQU 20
UDP_HDR_LEN	EQU 8
NTP_PAYLOAD_LEN	EQU 48
NTP_FRAME_LEN	EQU 14 + IP_HDR_LEN + UDP_HDR_LEN + NTP_PAYLOAD_LEN	; 90

OUR_PORT_HI	EQU 0xC2
OUR_PORT_LO	EQU 0x00
NTP_PORT_HI	EQU HIGH 123
NTP_PORT_LO	EQU LOW 123

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

	; positional 0: server (IPv4 literal or hostname)
	LD	B,0
	CALL	@CMDL.GET_POSITIONAL
	JP	C,USAGE_ERROR
	LD	(TARGET_HOST_PTR),HL

	; Pull NET_IP / NET_MAC from env (after IFUP).
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

	; Resolve server (literal IPv4 or hostname).
	LD	HL,(TARGET_HOST_PTR)
	LD	DE,TARGET_IP
	CALL	@RESOLVE.HOST
	JP	C,RESOLVE_FAIL

	PRINT LINE_END
	PRINT MSG_QUERY
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINT MSG_FROM
	LD	HL,OUR_IP
	CALL	PRINT_IPV4
	PRINT LINE_END

	; ARP resolve target.
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

	; Build NTP request and send.
	CALL	BUILD_NTP_FRAME
	LD	HL,TX_BUF
	LD	BC,NTP_FRAME_LEN
	CALL	@RTL.SEND_FRAME
	JP	C,SEND_FAIL

	; Wait reply.
	LD	HL,NTP_TIMEOUT_MS
	LD	(TIMEOUT_MS_LEFT),HL
	CALL	WAIT_FOR_NTP_REPLY
	JP	C,NTP_TIMEOUT

	; Print Stratum.
	PRINT MSG_STRATUM
	LD	A,(NTP_REPLY_STRATUM)
	CALL	PRINT_DEC_A
	PRINT LINE_END

	; Print raw NTP transmit timestamp (4-byte seconds since 1900).
	PRINT MSG_NTP_RAW
	LD	A,(NTP_TX_SECS + 0)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,(NTP_TX_SECS + 1)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,(NTP_TX_SECS + 2)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,(NTP_TX_SECS + 3)
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_NTP_RAW_NOTE

	; Convert NTP -> Unix UTC, save a copy for local-time pass.
	CALL	NTP_TO_UNIX
	CALL	SAVE_UTC_BACKUP
	CALL	UNIX_TO_DATE
	PRINT MSG_UTC
	CALL	PRINT_DATE
	PRINT LINE_END

	; Restore WORK_SECS = UTC, apply TZ from NET_TZ, convert again.
	CALL	RESTORE_FROM_UTC_BACKUP
	CALL	APPLY_TZ_FROM_ENV
	CALL	UNIX_TO_DATE
	PRINT MSG_LOCAL
	CALL	PRINT_DATE
	PRINT MSG_TZ_PRE
	CALL	PRINT_TZ_LABEL
	PRINT MSG_TZ_POST
	PRINT LINE_END

	CALL	@ISA.ISA_CLOSE
	JP	@UTIL.EXIT_OK


RESET_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_RESET
	JP	FAIL

SEND_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_SEND
	JP	FAIL

ARP_TIMEOUT
	LD	A,(CANCELLED)
	OR	A
	JR	NZ,.CANCEL
	PRINTLN MSG_E_ARP
	JP	FAIL
.CANCEL
	PRINTLN MSG_ABORTED
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL

NTP_TIMEOUT
	LD	A,(CANCELLED)
	OR	A
	JR	NZ,.CANCEL
	PRINTLN MSG_E_NTP
	JP	FAIL
.CANCEL
	PRINTLN MSG_ABORTED
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL

FAIL
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
; BUILD_NTP_FRAME: assemble a 90-byte frame in TX_BUF.
;   Eth: dst=TARGET_MAC, src=OUR_MAC, type=0x0800
;   IP : standard 20-byte header, src=OUR_IP, dst=TARGET_IP
;   UDP: src=OUR_PORT (random-ish), dst=123, length, checksum=0
;   NTP: 48-byte payload (LI=0/VN=3/Mode=3, rest zero).
; ------------------------------------------------------
BUILD_NTP_FRAME
	; -- Ethernet header
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

	; -- IPv4 header
	LD	A,0x45
	LD	(DE),A
	INC	DE
	XOR	A			; DSCP
	LD	(DE),A
	INC	DE
	LD	A,HIGH (IP_HDR_LEN + UDP_HDR_LEN + NTP_PAYLOAD_LEN)
	LD	(DE),A
	INC	DE
	LD	A,LOW (IP_HDR_LEN + UDP_HDR_LEN + NTP_PAYLOAD_LEN)
	LD	(DE),A
	INC	DE
	XOR	A			; ID hi
	LD	(DE),A
	INC	DE
	LD	A,1			; ID lo (=1 just to be non-zero)
	LD	(DE),A
	INC	DE
	XOR	A			; flags+frag
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	A,64			; TTL
	LD	(DE),A
	INC	DE
	LD	A,IP_PROTO_UDP
	LD	(DE),A
	INC	DE
	XOR	A			; checksum placeholder
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

	; -- UDP header
	LD	A,OUR_PORT_HI
	LD	(DE),A
	INC	DE
	LD	A,OUR_PORT_LO
	LD	(DE),A
	INC	DE
	LD	A,NTP_PORT_HI
	LD	(DE),A
	INC	DE
	LD	A,NTP_PORT_LO
	LD	(DE),A
	INC	DE
	LD	A,HIGH (UDP_HDR_LEN + NTP_PAYLOAD_LEN)
	LD	(DE),A
	INC	DE
	LD	A,LOW (UDP_HDR_LEN + NTP_PAYLOAD_LEN)
	LD	(DE),A
	INC	DE
	XOR	A			; UDP checksum (0 = unused, OK in IPv4)
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE

	; -- NTP payload (48 bytes, mostly zero).
	LD	A,0x1B			; LI=0, VN=3, Mode=3 (client)
	LD	(DE),A
	INC	DE
	; Remaining 47 bytes = 0.
	LD	BC,47
.ZBOD
	XOR	A
	LD	(DE),A
	INC	DE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.ZBOD

	; -- IP checksum over IP header (20 bytes at TX_BUF+14).
	LD	IX,TX_BUF + 14
	LD	BC,IP_HDR_LEN
	CALL	@UTIL.CHECKSUM
	LD	A,H
	LD	(TX_BUF + 14 + 10),A
	LD	A,L
	LD	(TX_BUF + 14 + 11),A
	RET


; ------------------------------------------------------
; WAIT_FOR_ARP_REPLY: same shape as in PING/UDPTEST.
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
; WAIT_FOR_NTP_REPLY: filter for UDP from TARGET_IP, src
; port 123, dst port OUR_PORT.  On success captures the
; Stratum byte and the 4-byte Transmit Timestamp seconds.
; ------------------------------------------------------
WAIT_FOR_NTP_REPLY
.LP
	CALL	@RTL.RING_HAS_PACKET
	JP	NZ,.HAVE
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
	; src IP must equal TARGET_IP
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
	; UDP src port = 123
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 0)
	CP	NTP_PORT_HI
	JP	NZ,.LP
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 1)
	CP	NTP_PORT_LO
	JP	NZ,.LP
	; UDP dst port = OUR_PORT
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 2)
	CP	OUR_PORT_HI
	JP	NZ,.LP
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + 3)
	CP	OUR_PORT_LO
	JP	NZ,.LP
	; Capture stratum (NTP byte 1) + transmit timestamp seconds
	; (NTP bytes 40..43).  NTP payload starts at frame + 14+20+8 = 42.
	LD	A,(RX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN + 1)
	LD	(NTP_REPLY_STRATUM),A
	LD	HL,RX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN + 40
	LD	DE,NTP_TX_SECS
	LD	BC,4
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


; ------------------------------------------------------
; PRINT_IPV4: HL = ptr to 4 bytes -> "a.b.c.d".
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


; ------------------------------------------------------
; PRINT_DEC2: print A as 2-digit decimal (00..99).
; ------------------------------------------------------
PRINT_DEC2
	PUSH	AF,BC,DE
	LD	C,A
	LD	B,0
.LP
	LD	A,C
	CP	10
	JR	C,.GOT
	SUB	10
	LD	C,A
	INC	B
	JR	.LP
.GOT
	LD	A,B
	ADD	A,'0'
	PUSH	BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC
	LD	A,C
	ADD	A,'0'
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	DE,BC,AF
	RET


; ------------------------------------------------------
; PRINT_DEC4: print HL as 4-digit decimal (0000..9999).
; Trashes A, BC, DE.
; ------------------------------------------------------
PRINT_DEC4
	PUSH	HL
	; thousands
	LD	BC,1000
	CALL	.DIV_EMIT
	; hundreds
	LD	BC,100
	CALL	.DIV_EMIT
	; tens
	LD	BC,10
	CALL	.DIV_EMIT
	; units
	LD	A,L
	ADD	A,'0'
	CALL	PUTCHAR
	POP	HL
	RET
.DIV_EMIT
	LD	D,'0'
.SUB
	OR	A
	SBC	HL,BC
	JR	C,.DONE
	INC	D
	JR	.SUB
.DONE
	ADD	HL,BC
	LD	A,D
	JP	PUTCHAR


; ------------------------------------------------------
; NTP_TO_UNIX: NTP_TX_SECS (4 bytes BE) -> WORK_SECS
; (4 bytes LE), with NTP-Unix offset (2208988800 =
; 0x83AA7E80) subtracted.  Trashes A, BC, DE, HL.
; ------------------------------------------------------
NTP_TO_UNIX
	; Convert BE -> LE: WORK[0]=NTP[3], WORK[1]=NTP[2], WORK[2]=NTP[1], WORK[3]=NTP[0]
	LD	A,(NTP_TX_SECS + 3)
	LD	(WORK_SECS + 0),A
	LD	A,(NTP_TX_SECS + 2)
	LD	(WORK_SECS + 1),A
	LD	A,(NTP_TX_SECS + 1)
	LD	(WORK_SECS + 2),A
	LD	A,(NTP_TX_SECS + 0)
	LD	(WORK_SECS + 3),A
	; Subtract 0x83AA7E80 (LE bytes: 80 7E AA 83).
	LD	HL,NTP_OFFSET_LE
	JP	SUB32_HL_FROM_WORK


; ------------------------------------------------------
; SUB32_HL_FROM_WORK: WORK_SECS -= [HL] (4 bytes LE).
; CF=1 if borrow.  Trashes A, advances HL by 4.
; ------------------------------------------------------
SUB32_HL_FROM_WORK
	LD	A,(WORK_SECS + 0)
	SUB	(HL)
	LD	(WORK_SECS + 0),A
	INC	HL
	LD	A,(WORK_SECS + 1)
	SBC	A,(HL)
	LD	(WORK_SECS + 1),A
	INC	HL
	LD	A,(WORK_SECS + 2)
	SBC	A,(HL)
	LD	(WORK_SECS + 2),A
	INC	HL
	LD	A,(WORK_SECS + 3)
	SBC	A,(HL)
	LD	(WORK_SECS + 3),A
	INC	HL
	RET


; ------------------------------------------------------
; TRY_SUB32: subtract [HL] from WORK_SECS only if it
; doesn't underflow.
;   In: HL = ptr to 4-byte LE constant.
;   Out: CF=0 if subtraction taken; CF=1 if underflow (no change).
;   Trashes A, BC, DE, HL.
; ------------------------------------------------------
TRY_SUB32
	; Save WORK_SECS into SAVE_SECS.
	LD	DE,WORK_SECS
	LD	BC,SAVE_SECS
	PUSH	HL
	LD	A,(DE)
	LD	(BC),A
	INC	DE
	INC	BC
	LD	A,(DE)
	LD	(BC),A
	INC	DE
	INC	BC
	LD	A,(DE)
	LD	(BC),A
	INC	DE
	INC	BC
	LD	A,(DE)
	LD	(BC),A
	POP	HL
	; Subtract.
	CALL	SUB32_HL_FROM_WORK
	RET	NC			; CF=0 => taken
	; Restore from SAVE_SECS.
	LD	BC,SAVE_SECS
	LD	DE,WORK_SECS
	LD	A,(BC)
	LD	(DE),A
	INC	BC
	INC	DE
	LD	A,(BC)
	LD	(DE),A
	INC	BC
	INC	DE
	LD	A,(BC)
	LD	(DE),A
	INC	BC
	INC	DE
	LD	A,(BC)
	LD	(DE),A
	SCF
	RET


; ------------------------------------------------------
; UNIX_TO_DATE: split WORK_SECS into Y/M/D/H/M/S.
;   Input: WORK_SECS = Unix seconds (LE).
;   Output: YEAR (2 LE), MONTH, DAY, HOUR, MIN, SEC bytes.
;   Trashes everything.
;
; Algorithm: subtract years (31536000 or 31622400 sec) until
; WORK_SECS < year_secs(year), then months, then days
; (86400), then hours (3600), then minutes (60).
; ------------------------------------------------------
UNIX_TO_DATE
	LD	HL,1970
	LD	(YEAR),HL
.YEAR_LOOP
	LD	HL,(YEAR)
	CALL	IS_LEAP			; A=1 if leap year, 0 otherwise
	OR	A
	JR	NZ,.LEAP_YEAR
	LD	HL,YEAR_SECS_REGULAR
	JR	.TRY_YEAR
.LEAP_YEAR
	LD	HL,YEAR_SECS_LEAP
.TRY_YEAR
	CALL	TRY_SUB32
	JR	C,.YEAR_DONE
	LD	HL,(YEAR)
	INC	HL
	LD	(YEAR),HL
	JR	.YEAR_LOOP
.YEAR_DONE

	; Month loop: pick days table based on leap.
	LD	A,1
	LD	(MONTH),A
.MONTH_LOOP
	; Compute month_secs for current month.
	LD	HL,(YEAR)
	CALL	IS_LEAP
	OR	A
	JR	Z,.NORM_MONTH
	LD	HL,MONTH_DAYS_LEAP
	JR	.HAVE_MONTHS
.NORM_MONTH
	LD	HL,MONTH_DAYS_REGULAR
.HAVE_MONTHS
	LD	A,(MONTH)
	DEC	A
	LD	C,A
	LD	B,0
	ADD	HL,BC
	LD	A,(HL)			; A = days in this month
	; Compute month_secs into TMP_SECS = days*86400.
	; days * 86400 = days * 0x15180.
	; At most 31*86400=2678400=0x28DE80, fits in 24 bits.
	; Use a small multiply: TMP = 0; while days>0: TMP += 86400; days--.
	LD	B,A
	LD	HL,TMP_SECS
	XOR	A
	LD	(HL),A
	INC	HL
	LD	(HL),A
	INC	HL
	LD	(HL),A
	INC	HL
	LD	(HL),A
.MUL_LP
	LD	A,B
	OR	A
	JR	Z,.MUL_DONE
	LD	HL,DAY_SECS_LE
	; TMP_SECS += 86400.
	PUSH	BC
	LD	A,(TMP_SECS + 0)
	ADD	A,(HL)
	LD	(TMP_SECS + 0),A
	INC	HL
	LD	A,(TMP_SECS + 1)
	ADC	A,(HL)
	LD	(TMP_SECS + 1),A
	INC	HL
	LD	A,(TMP_SECS + 2)
	ADC	A,(HL)
	LD	(TMP_SECS + 2),A
	INC	HL
	LD	A,(TMP_SECS + 3)
	ADC	A,(HL)
	LD	(TMP_SECS + 3),A
	POP	BC
	DEC	B
	JR	.MUL_LP
.MUL_DONE
	LD	HL,TMP_SECS
	CALL	TRY_SUB32
	JR	C,.MONTH_DONE
	LD	A,(MONTH)
	INC	A
	LD	(MONTH),A
	JR	.MONTH_LOOP
.MONTH_DONE

	; Days within month: subtract 86400 until <86400.
	XOR	A
	LD	(DAY),A
.DAY_LOOP
	LD	HL,DAY_SECS_LE
	CALL	TRY_SUB32
	JR	C,.DAY_DONE
	LD	A,(DAY)
	INC	A
	LD	(DAY),A
	JR	.DAY_LOOP
.DAY_DONE
	LD	A,(DAY)
	INC	A			; 1-based
	LD	(DAY),A

	; Hours: subtract 3600 until <3600.  WORK fits in 17-bit
	; (max 86399), so only low 24 bits used.
	XOR	A
	LD	(HOUR),A
.HOUR_LOOP
	LD	HL,HOUR_SECS_LE
	CALL	TRY_SUB32
	JR	C,.HOUR_DONE
	LD	A,(HOUR)
	INC	A
	LD	(HOUR),A
	JR	.HOUR_LOOP
.HOUR_DONE

	; Minutes: subtract 60 until <60.  Now WORK fits in 16-bit.
	XOR	A
	LD	(MIN),A
.MIN_LOOP
	LD	HL,MIN_SECS_LE
	CALL	TRY_SUB32
	JR	C,.MIN_DONE
	LD	A,(MIN)
	INC	A
	LD	(MIN),A
	JR	.MIN_LOOP
.MIN_DONE

	; Seconds: WORK_SECS now fits in 8-bit (0..59).
	LD	A,(WORK_SECS + 0)
	LD	(SEC),A
	RET


; ------------------------------------------------------
; IS_LEAP: HL = year, return A=1 if leap year, 0 otherwise.
; Leap if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0.
; Trashes BC, DE, HL.
; ------------------------------------------------------
IS_LEAP
	; year % 400 == 0 ?
	LD	D,H
	LD	E,L
	CALL	MOD_HL_400		; HL = year % 400
	LD	A,H
	OR	L
	JR	Z,.LEAP			; %400==0 -> leap
	; year % 100 == 0 ?
	LD	H,D
	LD	L,E
	CALL	MOD_HL_100
	LD	A,H
	OR	L
	JR	Z,.NOT_LEAP		; %100==0 (and %400!=0) -> not leap
	; year % 4 == 0 ?
	LD	A,E
	AND	3
	JR	Z,.LEAP			; %4==0 -> leap
.NOT_LEAP
	XOR	A
	RET
.LEAP
	LD	A,1
	RET


; MOD_HL_100: HL = HL mod 100. Trashes A, BC.
MOD_HL_100
	LD	BC,100
.LP
	OR	A
	SBC	HL,BC
	JR	NC,.LP
	ADD	HL,BC
	RET

; MOD_HL_400: HL = HL mod 400. Trashes A, BC.
MOD_HL_400
	LD	BC,400
.LP
	OR	A
	SBC	HL,BC
	JR	NC,.LP
	ADD	HL,BC
	RET


; ------------------------------------------------------
; PRINT_DATE: format YYYY-MM-DD HH:MM:SS from BSS fields.
; Trashes everything.
; ------------------------------------------------------
PRINT_DATE
	LD	HL,(YEAR)
	CALL	PRINT_DEC4
	LD	A,'-'
	CALL	PUTCHAR
	LD	A,(MONTH)
	CALL	PRINT_DEC2
	LD	A,'-'
	CALL	PUTCHAR
	LD	A,(DAY)
	CALL	PRINT_DEC2
	LD	A,' '
	CALL	PUTCHAR
	LD	A,(HOUR)
	CALL	PRINT_DEC2
	LD	A,':'
	CALL	PUTCHAR
	LD	A,(MIN)
	CALL	PRINT_DEC2
	LD	A,':'
	CALL	PUTCHAR
	LD	A,(SEC)
	CALL	PRINT_DEC2
	RET


; ------------------------------------------------------
; SAVE_UTC_BACKUP / RESTORE_FROM_UTC_BACKUP: copy WORK_SECS
; into UTC_BACKUP and back.  4 bytes each way.
; ------------------------------------------------------
SAVE_UTC_BACKUP
	LD	HL,WORK_SECS
	LD	DE,UTC_BACKUP
	LD	BC,4
	LDIR
	RET

RESTORE_FROM_UTC_BACKUP
	LD	HL,UTC_BACKUP
	LD	DE,WORK_SECS
	LD	BC,4
	LDIR
	RET


; ------------------------------------------------------
; APPLY_TZ_FROM_ENV: read NET_TZ, parse "+H" / "-H" / "H",
; then add the signed hour offset to WORK_SECS.
; Missing / empty / unparseable NET_TZ => no-op.
; Trashes everything.
; ------------------------------------------------------
APPLY_TZ_FROM_ENV
	XOR	A
	LD	(TZ_NEG),A
	LD	(TZ_HOURS),A
	CALL	PARSE_TZ_FIELDS
	JP	APPLY_TZ_HOURS

; PARSE_TZ_FIELDS: GET_STR NET_TZ, fill TZ_NEG + TZ_HOURS.
;   On any failure, leaves both at 0 (no-op).
PARSE_TZ_FIELDS
	LD	HL,N_NET_TZ
	LD	DE,TZ_BUF
	LD	B,8
	CALL	@NETENV.GET_STR
	RET	C
	LD	HL,TZ_BUF
	LD	A,(HL)
	OR	A
	RET	Z
	CP	'-'
	JR	Z,.NEG
	CP	'+'
	JR	NZ,.DIGITS
	INC	HL
	JR	.DIGITS
.NEG
	LD	A,1
	LD	(TZ_NEG),A
	INC	HL
.DIGITS
	XOR	A
	LD	(TZ_HOURS),A
.LP
	LD	A,(HL)
	SUB	'0'
	RET	C
	CP	10
	RET	NC
	LD	B,A
	LD	A,(TZ_HOURS)
	ADD	A,A
	LD	C,A
	ADD	A,A
	ADD	A,A
	ADD	A,C
	ADD	A,B
	LD	(TZ_HOURS),A
	INC	HL
	JR	.LP


; ------------------------------------------------------
; PRINT_TZ_LABEL: print sign + hours from TZ_NEG/TZ_HOURS.
; ------------------------------------------------------
PRINT_TZ_LABEL
	LD	A,(TZ_NEG)
	OR	A
	JR	NZ,.NEG
	LD	A,'+'
	JR	.PRINT_SIGN
.NEG
	LD	A,'-'
.PRINT_SIGN
	CALL	PUTCHAR
	LD	A,(TZ_HOURS)
	JP	PRINT_DEC_A


; ------------------------------------------------------
; APPLY_TZ_HOURS: WORK_SECS += sign(TZ_NEG) * (TZ_HOURS * 3600).
; Hours <= 14, so abs offset <= 50400 < 65536; 16-bit suffices.
; ------------------------------------------------------
APPLY_TZ_HOURS
	LD	A,(TZ_HOURS)
	OR	A
	RET	Z
	; HL = hours * 3600.
	LD	B,A
	LD	HL,0
	LD	DE,3600
.MUL
	ADD	HL,DE
	DJNZ	.MUL
	; HL now = abs offset in seconds.
	LD	A,(TZ_NEG)
	OR	A
	JR	NZ,.NEGATIVE
	; Add HL to WORK_SECS (32-bit).
	LD	A,(WORK_SECS + 0)
	ADD	A,L
	LD	(WORK_SECS + 0),A
	LD	A,(WORK_SECS + 1)
	ADC	A,H
	LD	(WORK_SECS + 1),A
	LD	A,(WORK_SECS + 2)
	ADC	A,0
	LD	(WORK_SECS + 2),A
	LD	A,(WORK_SECS + 3)
	ADC	A,0
	LD	(WORK_SECS + 3),A
	RET
.NEGATIVE
	; Subtract HL from WORK_SECS.
	LD	A,(WORK_SECS + 0)
	SUB	L
	LD	(WORK_SECS + 0),A
	LD	A,(WORK_SECS + 1)
	SBC	A,H
	LD	(WORK_SECS + 1),A
	LD	A,(WORK_SECS + 2)
	SBC	A,0
	LD	(WORK_SECS + 2),A
	LD	A,(WORK_SECS + 3)
	SBC	A,0
	LD	(WORK_SECS + 3),A
	RET


; ------------------------------------------------------
; Date constants (32-bit LE; sjasmplus DD emits little-endian).
; ------------------------------------------------------
NTP_OFFSET_LE	DD 2208988800			; 1900..1970 epoch offset
YEAR_SECS_REGULAR DD 31536000			; 365*86400
YEAR_SECS_LEAP	DD 31622400			; 366*86400
DAY_SECS_LE	DD 86400
HOUR_SECS_LE	DD 3600
MIN_SECS_LE	DD 60

MONTH_DAYS_REGULAR DB 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
MONTH_DAYS_LEAP    DB 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31


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
N_NET_TZ	DB "NET_TZ",0

; ------- runtime BSS -------
OUR_IP		EQU APP_BSS_BASE		; 4
OUR_MAC		EQU APP_BSS_BASE + 4		; 6
TARGET_IP	EQU APP_BSS_BASE + 10		; 4
TARGET_MAC	EQU APP_BSS_BASE + 14		; 6
TIMEOUT_MS_LEFT	EQU APP_BSS_BASE + 20		; 2
CANCELLED	EQU APP_BSS_BASE + 22		; 1
TARGET_HOST_PTR	EQU APP_BSS_BASE + 23		; 2 bytes (-> argv token)
NTP_REPLY_STRATUM EQU APP_BSS_BASE + 23		; 1
NTP_TX_SECS	EQU APP_BSS_BASE + 24		; 4 (BE seconds since 1900)
DEC_BUF		EQU APP_BSS_BASE + 28		; 4 scratch
WORK_SECS	EQU APP_BSS_BASE + 32		; 4 (LE Unix seconds, working)
SAVE_SECS	EQU APP_BSS_BASE + 36		; 4 (TRY_SUB32 backup)
TMP_SECS	EQU APP_BSS_BASE + 40		; 4 (month_secs build area)
YEAR		EQU APP_BSS_BASE + 44		; 2
MONTH		EQU APP_BSS_BASE + 46		; 1
DAY		EQU APP_BSS_BASE + 47		; 1
HOUR		EQU APP_BSS_BASE + 48		; 1
MIN		EQU APP_BSS_BASE + 49		; 1
SEC		EQU APP_BSS_BASE + 50		; 1
UTC_BACKUP	EQU APP_BSS_BASE + 51		; 4 (Unix UTC backup for second pass)
TZ_BUF		EQU APP_BSS_BASE + 55		; 8 (NET_TZ string)
TZ_NEG		EQU APP_BSS_BASE + 63		; 1
TZ_HOURS	EQU APP_BSS_BASE + 64		; 1


; ------- messages -------
MSG_BANNER	DB "RTL8019AS NTP v0.1",0
MSG_QUERY	DB "Querying NTP at ",0
MSG_FROM	DB " from ",0
MSG_STRATUM	DB "Reply: stratum=",0
MSG_NTP_RAW	DB "NTP transmit timestamp: 0x",0
MSG_NTP_RAW_NOTE DB " (seconds since 1900-01-01)",13,10,0
MSG_UTC		DB "UTC time:   ",0
MSG_LOCAL	DB "Local time: ",0
MSG_TZ_PRE	DB " (TZ ",0
MSG_TZ_POST	DB ")",0
MSG_REGS	DB "REGS ",0
MSG_ABORTED	DB "Aborted by user (Esc/Ctrl+C).",0
MSG_E_RESET	DB "[E100] RESET timeout",0
MSG_E_SEND	DB "[E101] DMA write or PTX timeout",0
MSG_E_ARP	DB "ARP request timed out.",0
MSG_E_NTP	DB "NTP reply timed out.",0
MSG_USAGE_ERR	DB "[E] usage: missing or invalid server",0
MSG_E_RESOLVE	DB "[E] could not resolve host (DNS / ARP timeout or NXDOMAIN).",0
MSG_E_NO_DNS1	DB "[E] NET_DNS1 not set; pass an IPv4 literal or run NETCFG/IFUP first.",0
MSG_E_NO_GW	DB "[E] DNS server is off-subnet but NET_GW is not set.",0
MSG_HELP
	DB "Usage:",13,10
	DB "  NTP server-ipv4",13,10
	DB "  NTP /?",13,10,13,10
	DB "  server-ipv4   numeric IPv4 of the NTP server",13,10
	DB "                (DNS resolver not yet implemented).",13,10,0
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


NTP_IMAGE_END

RX_BUF_SIZE	EQU 1518

	MODULE MAIN

; resolve_lib's DNS query frame may reach RESOLVE_MAX_FRAME (320),
; larger than NTP_FRAME_LEN (90); reserve the bigger of the two.
TX_BUF		EQU NTP_IMAGE_END
RX_HDR		EQU TX_BUF + RESOLVE_MAX_FRAME
RX_BUF		EQU RX_HDR + 4
NTP_BSS_END	EQU RX_BUF + RX_BUF_SIZE

	ENDMODULE

	END MAIN.START
