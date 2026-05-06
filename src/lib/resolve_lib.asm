; ======================================================
; resolve_lib.asm - hostname-or-IPv4 -> IPv4 helper.
;
; RESOLVE.HOST tries to parse the input as a dotted-quad
; literal first; on failure it issues a DNS A-record
; query to NET_DNS1 and returns the first answer.  The
; routine reuses the surrounding utility's TX_BUF / RX_BUF
; / RX_HDR (in MODULE MAIN), the app's
; TICK_AND_CHECK_KEY for poll/cancel, and the app's
; OUR_IP / OUR_MAC for source addresses.  ARP for the DNS
; server's next hop is performed inside the library so it
; does not collide with the app's own ARP cycle for the
; final target.
;
; Public API (DEFINE USE_RESOLVE before INCLUDE):
;
;   RESOLVE.HOST     In:  HL = ASCIIZ host (literal IP or
;                         hostname; trailing dot allowed);
;                         DE = 4-byte dest.
;                    Out: CF=0 ok ((DE..DE+3) filled);
;                         CF=1 fail.  RESOLVE.LAST_FAIL
;                         indicates the cause (see below).
;
;   RESOLVE.LAST_FAIL  byte; reason of last fail:
;                       0 - none / no fail
;                       1 - usage (empty / too long name)
;                       2 - NET_DNS1 not set
;                       3 - off-subnet but NET_GW unset
;                       4 - ARP timeout
;                       5 - DNS reply timeout
;                       6 - DNS reply parse error / RCODE
;                       7 - cancelled by user (Esc/Ctrl+C)
;
; Caller responsibilities:
;   - NIC must be initialized: ISA_OPEN, RTL.RESET,
;     RTL.INIT_NORMAL.
;   - @MAIN.OUR_IP / @MAIN.OUR_MAC populated.
;   - @ARP.OUR_MAC_PTR / @ARP.OUR_IP_PTR set.
;   - @MAIN.TICK_AND_CHECK_KEY exists; MAIN.CANCELLED
;     reflects key-cancel state.
;   - @MAIN.TX_BUF region sized >= RESOLVE_MAX_FRAME.
;   - @MAIN.RX_BUF / @MAIN.RX_HDR / @MAIN.RX_BUF_SIZE
;     defined and accessible.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_RESOLVE
	DEFINE	_RESOLVE

	IFDEF USE_RESOLVE
	IFNDEF USE_RTL_SEND_FRAME
	DEFINE USE_RTL_SEND_FRAME
	ENDIF
	IFNDEF USE_RTL_RING_HAS_PACKET
	DEFINE USE_RTL_RING_HAS_PACKET
	ENDIF
	IFNDEF USE_RTL_READ_PACKET
	DEFINE USE_RTL_READ_PACKET
	ENDIF
	IFNDEF USE_ARP_BUILD_REQUEST
	DEFINE USE_ARP_BUILD_REQUEST
	ENDIF
	IFNDEF USE_NETENV
	DEFINE USE_NETENV
	ENDIF
	IFNDEF USE_CMDL
	DEFINE USE_CMDL
	ENDIF
	IFNDEF USE_DNS
	DEFINE USE_DNS
	ENDIF
	ENDIF

	MODULE RESOLVE

	IFDEF USE_RESOLVE

ARP_TIMEOUT_MS	EQU 3000
DNS_TIMEOUT_MS	EQU 3000

ETH_TYPE_ARP	EQU 0x0806
ETH_TYPE_IPV4	EQU 0x0800
ARP_FRAME_LEN	EQU 60
IP_HDR_LEN	EQU 20
UDP_HDR_LEN	EQU 8
IP_PROTO_UDP	EQU 17
ARP_OP_REPLY	EQU 2

DNS_SRC_PORT_HI	EQU 0xC2
DNS_SRC_PORT_LO	EQU 0x00


; ------------------------------------------------------
; LAST_FAIL - reason byte readable by caller.
LAST_FAIL	DB 0


; ------------------------------------------------------
; HOST: resolve ASCIIZ input -> IPv4 at (DE).
;   In:  HL = name; DE = dest.
;   Out: CF=0 ok; CF=1 fail.
; ------------------------------------------------------
HOST
	XOR	A
	LD	(LAST_FAIL),A
	; First, try parsing as a literal IPv4.
	PUSH	HL
	PUSH	DE
	CALL	@CMDL.PARSE_IPV4		; in: HL ASCIIZ, DE dest
	JR	C,.NOT_LIT
	POP	DE
	POP	HL
	OR	A
	RET
.NOT_LIT
	POP	DE
	POP	HL

	; Empty string?
	LD	A,(HL)
	OR	A
	JR	NZ,.HAVE_NAME
	LD	A,1
	LD	(LAST_FAIL),A
	SCF
	RET
.HAVE_NAME

	; Save dest pointer for later.
	LD	(RESOLVE_DEST_PTR),DE
	; Save name pointer on stack throughout.
	PUSH	HL

	; NET_DNS1 (required).
	LD	HL,N_DNS1
	LD	DE,RESOLVE_DNS_IP
	CALL	@NETENV.GET_IP
	JR	NC,.HAVE_DNS
	POP	HL
	LD	A,2
	LD	(LAST_FAIL),A
	SCF
	RET
.HAVE_DNS

	; NET_MASK (optional).
	LD	HL,N_MASK
	LD	DE,RESOLVE_NET_MASK
	CALL	@NETENV.GET_IP
	LD	A,0
	JR	C,.NMSK
	LD	A,1
.NMSK
	LD	(RESOLVE_HAS_MASK),A

	; NET_GW (optional).
	LD	HL,N_GW
	LD	DE,RESOLVE_NET_GW
	CALL	@NETENV.GET_IP
	LD	A,0
	JR	C,.NGW
	LD	A,1
.NGW
	LD	(RESOLVE_HAS_GW),A

	; Pick next-hop.
	CALL	NEXT_HOP
	JR	NC,.NHOK
	POP	HL
	LD	A,3
	LD	(LAST_FAIL),A
	SCF
	RET
.NHOK

	; ARP next-hop -> RESOLVE_NEXT_HOP_MAC.
	LD	DE,@MAIN.TX_BUF
	LD	HL,RESOLVE_NEXT_HOP_IP
	CALL	@ARP.BUILD_REQUEST
	LD	HL,@MAIN.TX_BUF
	LD	BC,ARP_FRAME_LEN
	CALL	@RTL.SEND_FRAME
	JR	NC,.AS_OK
	POP	HL
	LD	A,4
	LD	(LAST_FAIL),A
	SCF
	RET
.AS_OK
	LD	HL,ARP_TIMEOUT_MS
	LD	(RESOLVE_TIMEOUT_LEFT),HL
	CALL	WAIT_ARP
	JR	NC,.A_OK
	POP	HL
	; LAST_FAIL set inside WAIT_ARP.
	SCF
	RET
.A_OK

	; XID = R XOR low(SP).
	LD	A,R
	LD	B,A
	LD	HL,0
	ADD	HL,SP
	LD	A,L
	XOR	B
	LD	(RESOLVE_XID_LO),A
	LD	A,H
	XOR	B
	LD	(RESOLVE_XID_HI),A

	; Build full ETH+IP+UDP+DNS frame.  HL still on stack.
	POP	HL				; HL = name
	PUSH	HL
	CALL	BUILD_FRAME
	JR	NC,.BF_OK
	POP	HL
	LD	A,1				; invalid name (long label)
	LD	(LAST_FAIL),A
	SCF
	RET
.BF_OK

	LD	HL,@MAIN.TX_BUF
	LD	BC,(RESOLVE_QFRAME_LEN)
	CALL	@RTL.SEND_FRAME
	JR	NC,.SF_OK
	POP	HL
	LD	A,4
	LD	(LAST_FAIL),A
	SCF
	RET
.SF_OK

	; Wait DNS reply.
	LD	HL,DNS_TIMEOUT_MS
	LD	(RESOLVE_TIMEOUT_LEFT),HL
	CALL	WAIT_DNS
	JR	NC,.W_OK
	POP	HL
	; LAST_FAIL set inside WAIT_DNS.
	SCF
	RET
.W_OK

	; Parse.  IY = expected XID, HL = msg ptr, BC = msg len,
	; DE = caller's dest.
	LD	A,(RESOLVE_XID_HI)
	LD	H,A
	LD	A,(RESOLVE_XID_LO)
	LD	L,A
	PUSH	HL
	POP	IY
	LD	HL,(RESOLVE_DNS_MSG_PTR)
	LD	BC,(RESOLVE_DNS_MSG_LEN)
	LD	DE,(RESOLVE_DEST_PTR)
	CALL	@DNS.PARSE_REPLY
	JR	NC,.PARSE_OK
	POP	HL
	LD	A,6
	LD	(LAST_FAIL),A
	SCF
	RET
.PARSE_OK
	POP	HL
	OR	A
	RET


; ------------------------------------------------------
; NEXT_HOP: pick ARP target based on subnet match.
;   Out: RESOLVE_NEXT_HOP_IP filled.
;        CF=0 ok; CF=1 off-subnet and no NET_GW.
; ------------------------------------------------------
NEXT_HOP
	LD	A,(RESOLVE_HAS_MASK)
	OR	A
	JR	Z,.DIRECT
	LD	HL,RESOLVE_DNS_IP
	LD	DE,@MAIN.OUR_IP
	LD	IX,RESOLVE_NET_MASK
	LD	B,4
.LP
	LD	A,(IX+0)
	AND	(HL)
	LD	C,A
	LD	A,(DE)
	AND	(IX+0)
	CP	C
	JR	NZ,.OFFNET
	INC	HL
	INC	DE
	INC	IX
	DJNZ	.LP
.DIRECT
	LD	HL,RESOLVE_DNS_IP
	LD	DE,RESOLVE_NEXT_HOP_IP
	LD	BC,4
	LDIR
	OR	A
	RET
.OFFNET
	LD	A,(RESOLVE_HAS_GW)
	OR	A
	SCF
	RET	Z
	LD	HL,RESOLVE_NET_GW
	LD	DE,RESOLVE_NEXT_HOP_IP
	LD	BC,4
	LDIR
	OR	A
	RET


; ------------------------------------------------------
; BUILD_FRAME: ETH+IP+UDP+DNS query at @MAIN.TX_BUF.
;   In:  HL = name ptr (preserved on stack by caller).
;   Out: CF=0 ok; CF=1 invalid name.  Frame length stored
;        at RESOLVE_QFRAME_LEN.
; ------------------------------------------------------
BUILD_FRAME
	; DNS message at @MAIN.TX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN.
	LD	A,(RESOLVE_XID_HI)
	LD	B,A
	LD	A,(RESOLVE_XID_LO)
	LD	C,A
	LD	DE,@MAIN.TX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN
	CALL	@DNS.BUILD_QUERY
	RET	C
	; DE = past last byte.  Compute lengths.
	LD	HL,@MAIN.TX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN
	EX	DE,HL
	OR	A
	SBC	HL,DE
	LD	(RESOLVE_DNS_MSG_LEN),HL
	LD	BC,UDP_HDR_LEN
	ADD	HL,BC
	LD	(RESOLVE_UDP_LEN),HL
	LD	BC,IP_HDR_LEN
	ADD	HL,BC
	LD	(RESOLVE_IP_TOTAL),HL
	LD	BC,14
	ADD	HL,BC
	LD	(RESOLVE_QFRAME_LEN),HL

	; Ethernet header.
	LD	DE,@MAIN.TX_BUF
	LD	HL,RESOLVE_NEXT_HOP_MAC
	LD	BC,6
	LDIR
	LD	HL,@MAIN.OUR_MAC
	LD	BC,6
	LDIR
	LD	A,HIGH ETH_TYPE_IPV4
	LD	(DE),A
	INC	DE
	LD	A,LOW ETH_TYPE_IPV4
	LD	(DE),A
	INC	DE

	; IPv4 header.
	LD	A,0x45
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,(RESOLVE_IP_TOTAL + 1)
	LD	(DE),A
	INC	DE
	LD	A,(RESOLVE_IP_TOTAL)
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
	XOR	A
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	HL,@MAIN.OUR_IP
	LD	BC,4
	LDIR
	LD	HL,RESOLVE_DNS_IP
	LD	BC,4
	LDIR

	; UDP header.
	LD	A,DNS_SRC_PORT_HI
	LD	(DE),A
	INC	DE
	LD	A,DNS_SRC_PORT_LO
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A				; dst port hi (53 = 0x0035)
	INC	DE
	LD	A,53
	LD	(DE),A
	INC	DE
	LD	A,(RESOLVE_UDP_LEN + 1)
	LD	(DE),A
	INC	DE
	LD	A,(RESOLVE_UDP_LEN)
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A				; csum 0
	INC	DE
	LD	(DE),A
	INC	DE

	; IP checksum.
	PUSH	IX
	LD	IX,@MAIN.TX_BUF + 14
	LD	BC,IP_HDR_LEN
	CALL	@UTIL.CHECKSUM
	POP	IX
	LD	A,H
	LD	(@MAIN.TX_BUF + 14 + 10),A
	LD	A,L
	LD	(@MAIN.TX_BUF + 14 + 11),A
	OR	A
	RET


; ------------------------------------------------------
; WAIT_ARP: poll for ARP reply matching RESOLVE_NEXT_HOP_IP;
; on match copy MAC into RESOLVE_NEXT_HOP_MAC.
;   Out: CF=0 ok; CF=1 timeout / cancel; LAST_FAIL set.
; ------------------------------------------------------
WAIT_ARP
.LP
	CALL	@RTL.RING_HAS_PACKET
	JR	NZ,.HAVE
	CALL	@MAIN.TICK_AND_CHECK_KEY
	JR	C,.CANCEL
	LD	HL,(RESOLVE_TIMEOUT_LEFT)
	DEC	HL
	LD	(RESOLVE_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JR	NZ,.LP
	LD	A,4
	LD	(LAST_FAIL),A
	SCF
	RET
.HAVE
	LD	HL,@MAIN.RX_HDR
	LD	DE,@MAIN.RX_BUF
	LD	BC,1518
	CALL	@RTL.READ_PACKET
	JR	C,.LP
	LD	A,(@MAIN.RX_BUF + 12)
	CP	HIGH ETH_TYPE_ARP
	JR	NZ,.LP
	LD	A,(@MAIN.RX_BUF + 13)
	CP	LOW ETH_TYPE_ARP
	JR	NZ,.LP
	LD	A,(@MAIN.RX_BUF + 14 + 6)
	OR	A
	JR	NZ,.LP
	LD	A,(@MAIN.RX_BUF + 14 + 7)
	CP	ARP_OP_REPLY
	JR	NZ,.LP
	LD	HL,@MAIN.RX_BUF + 14 + 14
	LD	DE,RESOLVE_NEXT_HOP_IP
	LD	B,4
.CMP
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.LP
	INC	HL
	INC	DE
	DJNZ	.CMP
	LD	HL,@MAIN.RX_BUF + 14 + 8
	LD	DE,RESOLVE_NEXT_HOP_MAC
	LD	BC,6
	LDIR
	OR	A
	RET
.CANCEL
	LD	A,7
	LD	(LAST_FAIL),A
	SCF
	RET


; ------------------------------------------------------
; WAIT_DNS: poll for UDP packet src=DNS_IP:53 -> our port.
; Captures DNS payload pointer/length to RESOLVE_DNS_*.
;   Out: CF=0 ok; CF=1 timeout / cancel; LAST_FAIL set.
; ------------------------------------------------------
WAIT_DNS
.LP
	CALL	@RTL.RING_HAS_PACKET
	JR	NZ,.HAVE
	CALL	@MAIN.TICK_AND_CHECK_KEY
	JP	C,.CANCEL
	LD	HL,(RESOLVE_TIMEOUT_LEFT)
	DEC	HL
	LD	(RESOLVE_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JP	NZ,.LP
	LD	A,5
	LD	(LAST_FAIL),A
	SCF
	RET
.HAVE
	LD	HL,@MAIN.RX_HDR
	LD	DE,@MAIN.RX_BUF
	LD	BC,1518
	CALL	@RTL.READ_PACKET
	JP	C,.LP
	LD	A,(@MAIN.RX_BUF + 12)
	CP	HIGH ETH_TYPE_IPV4
	JP	NZ,.LP
	LD	A,(@MAIN.RX_BUF + 13)
	CP	LOW ETH_TYPE_IPV4
	JP	NZ,.LP
	LD	A,(@MAIN.RX_BUF + 14)
	CP	0x45
	JP	NZ,.LP
	LD	A,(@MAIN.RX_BUF + 14 + 9)
	CP	IP_PROTO_UDP
	JP	NZ,.LP
	; src IP == DNS_IP
	LD	HL,@MAIN.RX_BUF + 14 + 12
	LD	DE,RESOLVE_DNS_IP
	LD	B,4
.CMPSRC
	LD	A,(DE)
	CP	(HL)
	JP	NZ,.LP
	INC	HL
	INC	DE
	DJNZ	.CMPSRC
	; src port == 53
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 0)
	OR	A
	JP	NZ,.LP
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 1)
	CP	53
	JP	NZ,.LP
	; dst port == DNS_SRC_PORT
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 2)
	CP	DNS_SRC_PORT_HI
	JP	NZ,.LP
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 3)
	CP	DNS_SRC_PORT_LO
	JP	NZ,.LP
	; UDP length BE -> DNS msg length = UDP_LEN - 8.
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 5)
	LD	L,A
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 4)
	LD	H,A
	LD	BC,8
	OR	A
	SBC	HL,BC
	LD	(RESOLVE_DNS_MSG_LEN),HL
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN
	LD	(RESOLVE_DNS_MSG_PTR),HL
	OR	A
	RET
.CANCEL
	LD	A,7
	LD	(LAST_FAIL),A
	SCF
	RET


; -------- env var name strings --------
N_DNS1		DB "NET_DNS1",0
N_MASK		DB "NET_MASK",0
N_GW		DB "NET_GW",0


	ENDIF

	ENDMODULE
	ENDIF
