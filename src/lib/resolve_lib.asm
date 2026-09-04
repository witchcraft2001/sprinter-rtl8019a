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
;   RESOLVE.NEXT_HOP_FOR
;                    In:  HL = pointer to a 4-byte IPv4 target.
;                    Out: CF=0 -> RESOLVE_NEXT_HOP_IP and
;                         RESOLVE_NEXT_HOP_MAC populated for
;                         the right next hop (target itself
;                         when on-subnet, NET_GW otherwise);
;                         apps copy NEXT_HOP_MAC into their
;                         per-session TARGET_MAC.
;                         CF=1 -> off-subnet + no NET_GW (3) or
;                         ARP timeout (4); LAST_FAIL set.
;                    Reads NET_MASK / NET_GW from env each
;                    call; safe to use without RESOLVE.HOST
;                    (literal-IP apps that don't need DNS).
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
ARP_RETRIES	EQU 3
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
	IFDEF	UNET_DLL
	LD	IX,@UNET.COLD_CTX
	LD	A,CFN_PARSE_LITERAL_IP
	CALL	@WIN0COLD.RUN
	ELSE
	CALL	@CMDL.PARSE_IPV4		; in: HL ASCIIZ, DE dest
	ENDIF
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
	CALL	@ISA.ISA_CLOSE
	LD	HL,N_DNS1
	LD	DE,RESOLVE_DNS_IP
	CALL	@NETENV.GET_IP
	CALL	@ISA.ISA_OPEN
	JR	NC,.HAVE_DNS
	POP	HL
	LD	A,2
	LD	(LAST_FAIL),A
	SCF
	RET
.HAVE_DNS

	; NET_MASK (optional).
	CALL	@ISA.ISA_CLOSE
	LD	HL,N_MASK
	LD	DE,RESOLVE_NET_MASK
	CALL	@NETENV.GET_IP
	CALL	@ISA.ISA_OPEN
	LD	A,0
	JR	C,.NMSK
	LD	A,1
.NMSK
	LD	(RESOLVE_HAS_MASK),A

	; NET_GW (optional).
	CALL	@ISA.ISA_CLOSE
	LD	HL,N_GW
	LD	DE,RESOLVE_NET_GW
	CALL	@NETENV.GET_IP
	CALL	@ISA.ISA_OPEN
	LD	A,0
	JR	C,.NGW
	LD	A,1
.NGW
	LD	(RESOLVE_HAS_GW),A

	; Pick next-hop.
	IFDEF	UNET_DLL
	LD	IX,@UNET.COLD_CTX
	LD	HL,RESOLVE_DNS_IP
	LD	A,CFN_NEXT_HOP
	CALL	@WIN0COLD.RUN
	ELSE
	CALL	NEXT_HOP
	ENDIF
	JR	NC,.NHOK
	POP	HL
	LD	A,3
	LD	(LAST_FAIL),A
	SCF
	RET
.NHOK

	; ARP next-hop -> RESOLVE_NEXT_HOP_MAC.
.ARP_START
	LD	A,ARP_RETRIES
	LD	(RESOLVE_ARP_RETRY_LEFT),A
.ARP_SEND
	IFDEF	UNET_DLL
	LD	IX,@UNET.COLD_CTX
	LD	HL,RESOLVE_NEXT_HOP_IP
	LD	A,CFN_BUILD_ARP_REQUEST
	CALL	@WIN0COLD.RUN
	ELSE
	LD	DE,@MAIN.TX_BUF
	LD	HL,RESOLVE_NEXT_HOP_IP
	CALL	@ARP.BUILD_REQUEST
	ENDIF
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
	LD	A,(LAST_FAIL)
	CP	7
	JR	Z,.A_FAIL
	LD	HL,RESOLVE_ARP_RETRY_LEFT
	DEC	(HL)
	JR	NZ,.ARP_SEND
.A_FAIL
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
	IFDEF	UNET_DLL
	LD	IX,@UNET.COLD_CTX
	LD	DE,RESOLVE_DNS_IP
	LD	A,CFN_BUILD_DNS_QUERY
	CALL	@WIN0COLD.RUN		; -> HL = frame length
	LD	(RESOLVE_QFRAME_LEN),HL
	ELSE
	CALL	BUILD_FRAME
	ENDIF
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
	IFDEF	UNET_DLL
	LD	IX,@UNET.COLD_CTX
	LD	A,CFN_PARSE_DNS_REPLY
	CALL	@WIN0COLD.RUN
	ELSE
	CALL	@DNS.PARSE_REPLY
	ENDIF
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
; NEXT_HOP_FOR: subnet-check + ARP for an arbitrary target.
; Public so apps that bypass HOST (or that need to ARP a
; second target -- redirects, FTP PASV peer, etc.) get the
; same on-subnet / via-gateway logic as the DNS-server hop.
;   In:  HL = pointer to 4-byte target IPv4.
;   Out: CF=0 -> RESOLVE_NEXT_HOP_IP / _MAC populated.
;        CF=1 -> LAST_FAIL = 3 (no GW) or 4 (ARP timeout).
; Trashes A, BC, DE, HL, IX.
; ------------------------------------------------------
NEXT_HOP_FOR
	; Stage the target into RESOLVE_DNS_IP -- NEXT_HOP reads
	; from there to do its subnet compare.  We're not in a DNS
	; lookup at this point so the slot is free.
	LD	DE,RESOLVE_DNS_IP
	LD	BC,4
	LDIR
	; Re-load NET_MASK / NET_GW from env (caller may not have
	; come through HOST in this call chain).
	CALL	@ISA.ISA_CLOSE
	LD	HL,N_MASK
	LD	DE,RESOLVE_NET_MASK
	CALL	@NETENV.GET_IP
	CALL	@ISA.ISA_OPEN
	LD	A,0
	JR	C,.NM
	LD	A,1
.NM
	LD	(RESOLVE_HAS_MASK),A
	CALL	@ISA.ISA_CLOSE
	LD	HL,N_GW
	LD	DE,RESOLVE_NET_GW
	CALL	@NETENV.GET_IP
	CALL	@ISA.ISA_OPEN
	LD	A,0
	JR	C,.NG
	LD	A,1
.NG
	LD	(RESOLVE_HAS_GW),A
	IFDEF	UNET_DLL
	LD	IX,@UNET.COLD_CTX
	LD	HL,RESOLVE_DNS_IP
	LD	A,CFN_NEXT_HOP
	CALL	@WIN0COLD.RUN
	ELSE
	CALL	NEXT_HOP
	ENDIF
	JR	NC,.DOARP
	; Off-subnet and NET_GW absent.
	LD	A,3
	LD	(LAST_FAIL),A
	SCF
	RET
.DOARP
	LD	A,ARP_RETRIES
	LD	(RESOLVE_ARP_RETRY_LEFT),A
.ARP_SEND
	IFDEF	UNET_DLL
	LD	IX,@UNET.COLD_CTX
	LD	HL,RESOLVE_NEXT_HOP_IP
	LD	A,CFN_BUILD_ARP_REQUEST
	CALL	@WIN0COLD.RUN
	ELSE
	LD	DE,@MAIN.TX_BUF
	LD	HL,RESOLVE_NEXT_HOP_IP
	CALL	@ARP.BUILD_REQUEST
	ENDIF
	LD	HL,@MAIN.TX_BUF
	LD	BC,ARP_FRAME_LEN
	CALL	@RTL.SEND_FRAME
	JR	NC,.WAIT
	LD	A,4
	LD	(LAST_FAIL),A
	SCF
	RET
.WAIT
	LD	HL,ARP_TIMEOUT_MS
	LD	(RESOLVE_TIMEOUT_LEFT),HL
	CALL	WAIT_ARP
	RET	NC
	LD	A,(LAST_FAIL)
	CP	7
	JR	Z,.ARP_FAIL
	LD	HL,RESOLVE_ARP_RETRY_LEFT
	DEC	(HL)
	JR	NZ,.ARP_SEND
.ARP_FAIL
	; LAST_FAIL set inside WAIT_ARP.
	SCF
	RET


; ------------------------------------------------------
; NEXT_HOP: pick ARP target based on subnet match.  Excluded from
; UNET_DLL builds (image budget): HOST/NEXT_HOP_FOR redirect to the
; WIN0 cold blob's FN_NEXT_HOP instead (see win0cold.asm /
; unetrtl_cold.asm) -- pure register/buffer logic with no RST, safe
; to run with DSS/BIOS unreachable.
;   Out: RESOLVE_NEXT_HOP_IP filled.
;        CF=0 ok; CF=1 off-subnet and no NET_GW.
; ------------------------------------------------------
	IFNDEF	UNET_DLL
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
	ENDIF


; ------------------------------------------------------
; BUILD_FRAME: ETH+IP+UDP+DNS query at @MAIN.TX_BUF.  Excluded from
; UNET_DLL builds (image budget): the DLL's HOST redirects to the
; WIN0 cold blob's FN_BUILD_DNS_QUERY instead (see win0cold.asm /
; unetrtl_cold.asm) -- pure register/buffer logic with no RST, safe
; to run with DSS/BIOS unreachable.
;   In:  HL = name ptr (preserved on stack by caller).
;   Out: CF=0 ok; CF=1 invalid name.  Frame length stored
;        at RESOLVE_QFRAME_LEN.
; ------------------------------------------------------
	IFNDEF	UNET_DLL
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
	ENDIF


; ------------------------------------------------------
; WAIT_ARP: poll for ARP reply matching RESOLVE_NEXT_HOP_IP;
; on match copy MAC into RESOLVE_NEXT_HOP_MAC.
;   Out: CF=0 ok; CF=1 timeout / cancel; LAST_FAIL set.
; ------------------------------------------------------
WAIT_ARP
.LP
	; Drain the ring back-to-back (see WAIT_FOR_ICMP_REPLY rationale):
	; pull up to RX_DRAIN_BUDGET frames while non-empty, tick only when
	; empty or budget spent.  Keeps the ARP reply from being buried by
	; a broadcast burst.
	LD	A,RX_DRAIN_BUDGET
	LD	(RX_DRAIN_LEFT),A
.DRAIN
	; RING_HAS_PACKET (never reachable from cold: it can call
	; RECOVER_OVERFLOW, which toggles ISA_CLOSE/ISA_OPEN with a real
	; EI -- unsafe while WIN0COLD.RUN still has PAGE0 mapped to the
	; cold blob, see coldctx.inc) always runs hot, once per frame; only
	; the per-frame read+match (FN_DRAIN_ARP) moves cold.
	CALL	@RTL.RING_HAS_PACKET
	JR	Z,.TICK
	IFDEF	UNET_DLL
	LD	IX,@UNET.COLD_CTX
	LD	HL,RESOLVE_DNS_IP
	LD	A,CFN_DRAIN_ARP
	CALL	@WIN0COLD.RUN
	CP	1
	JR	Z,.A_MATCHED
	CP	2
	JR	Z,.TO
	LD	A,(RX_DRAIN_LEFT)
	DEC	A
	LD	(RX_DRAIN_LEFT),A
	JR	NZ,.DRAIN
	JR	.TICK
	ELSE
	LD	HL,@MAIN.RX_HDR
	LD	DE,@MAIN.RX_BUF
	LD	BC,1518			; @MAIN.RX_BUF_SIZE is documented but the
					; apps define RX_BUF_SIZE outside MODULE MAIN,
					; so it is not referenceable here.  All callers
					; (apps and the UNET DLL) size RX_BUF at 1518.
	CALL	@RTL.READ_PACKET
	JR	C,.MISS
	LD	A,(@MAIN.RX_BUF + 12)
	CP	HIGH ETH_TYPE_ARP
	JR	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 13)
	CP	LOW ETH_TYPE_ARP
	JR	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 14 + 6)
	OR	A
	JR	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 14 + 7)
	CP	ARP_OP_REPLY
	JR	NZ,.MISS
	LD	HL,@MAIN.RX_BUF + 14 + 14
	LD	DE,RESOLVE_NEXT_HOP_IP
	LD	B,4
.CMP
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.MISS
	INC	HL
	INC	DE
	DJNZ	.CMP
	LD	HL,@MAIN.RX_BUF + 14 + 8
	LD	DE,RESOLVE_NEXT_HOP_MAC
	LD	BC,6
	LDIR
	OR	A
	RET
.MISS
	; Charge one timeout unit per frame (see WAIT_FOR_ICMP_REPLY) so a
	; broadcast flood cannot stall the tick-counted timeout.
	LD	HL,(RESOLVE_TIMEOUT_LEFT)
	DEC	HL
	LD	(RESOLVE_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JR	Z,.TO
	LD	A,(RX_DRAIN_LEFT)
	DEC	A
	LD	(RX_DRAIN_LEFT),A
	JR	NZ,.DRAIN
	ENDIF
.TICK					; ring empty or budget spent: tick + key poll
	CALL	@MAIN.TICK_AND_CHECK_KEY
	JR	C,.CANCEL
	LD	HL,(RESOLVE_TIMEOUT_LEFT)
	DEC	HL
	LD	(RESOLVE_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JR	NZ,.LP
.TO
	LD	A,4
	LD	(LAST_FAIL),A
	SCF
	RET
.CANCEL
	LD	A,7
	LD	(LAST_FAIL),A
	SCF
	RET
	IFDEF	UNET_DLL
.A_MATCHED
	OR	A
	RET
	ENDIF


; ------------------------------------------------------
; WAIT_DNS: poll for UDP packet src=DNS_IP:53 -> our port.
; Captures DNS payload pointer/length to RESOLVE_DNS_*.
;   Out: CF=0 ok; CF=1 timeout / cancel; LAST_FAIL set.
; ------------------------------------------------------
WAIT_DNS
.LP
	; Drain the ring back-to-back (see WAIT_FOR_ICMP_REPLY rationale):
	; pull up to RX_DRAIN_BUDGET frames while non-empty, tick only when
	; empty or budget spent.
	LD	A,RX_DRAIN_BUDGET
	LD	(RX_DRAIN_LEFT),A
.DRAIN
	; RING_HAS_PACKET never runs cold -- see WAIT_ARP's comment and
	; coldctx.inc's header (RECOVER_OVERFLOW's ISA_CLOSE/OPEN would EI
	; while PAGE0 is still the cold blob).
	CALL	@RTL.RING_HAS_PACKET
	JP	Z,.TICK
	IFDEF	UNET_DLL
	LD	IX,@UNET.COLD_CTX
	LD	HL,RESOLVE_DNS_IP
	LD	A,CFN_DRAIN_DNS
	CALL	@WIN0COLD.RUN
	CP	1
	JP	Z,.D_MATCHED
	CP	2
	JP	Z,.TO
	LD	A,(RX_DRAIN_LEFT)
	DEC	A
	LD	(RX_DRAIN_LEFT),A
	JP	NZ,.DRAIN
	JP	.TICK
	ELSE
	LD	HL,@MAIN.RX_HDR
	LD	DE,@MAIN.RX_BUF
	LD	BC,1518			; @MAIN.RX_BUF_SIZE is documented but the
					; apps define RX_BUF_SIZE outside MODULE MAIN,
					; so it is not referenceable here.  All callers
					; (apps and the UNET DLL) size RX_BUF at 1518.
	CALL	@RTL.READ_PACKET
	JP	C,.MISS
	LD	A,(@MAIN.RX_BUF + 12)
	CP	HIGH ETH_TYPE_IPV4
	JP	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 13)
	CP	LOW ETH_TYPE_IPV4
	JP	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 14)
	CP	0x45
	JP	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 14 + 9)
	CP	IP_PROTO_UDP
	JP	NZ,.MISS
	; src IP == DNS_IP
	LD	HL,@MAIN.RX_BUF + 14 + 12
	LD	DE,RESOLVE_DNS_IP
	LD	B,4
.CMPSRC
	LD	A,(DE)
	CP	(HL)
	JP	NZ,.MISS
	INC	HL
	INC	DE
	DJNZ	.CMPSRC
	; src port == 53
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 0)
	OR	A
	JP	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 1)
	CP	53
	JP	NZ,.MISS
	; dst port == DNS_SRC_PORT
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 2)
	CP	DNS_SRC_PORT_HI
	JP	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 3)
	CP	DNS_SRC_PORT_LO
	JP	NZ,.MISS
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
.MISS
	; Charge one timeout unit per frame (see WAIT_FOR_ICMP_REPLY).
	LD	HL,(RESOLVE_TIMEOUT_LEFT)
	DEC	HL
	LD	(RESOLVE_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JP	Z,.TO
	LD	A,(RX_DRAIN_LEFT)
	DEC	A
	LD	(RX_DRAIN_LEFT),A
	JP	NZ,.DRAIN
	ENDIF
.TICK					; ring empty or budget spent: tick + key poll
	CALL	@MAIN.TICK_AND_CHECK_KEY
	JP	C,.CANCEL
	LD	HL,(RESOLVE_TIMEOUT_LEFT)
	DEC	HL
	LD	(RESOLVE_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JP	NZ,.LP
.TO
	LD	A,5
	LD	(LAST_FAIL),A
	SCF
	RET
.CANCEL
	LD	A,7
	LD	(LAST_FAIL),A
	SCF
	RET
	IFDEF	UNET_DLL
.D_MATCHED
	OR	A
	RET
	ENDIF


; -------- env var name strings --------
N_DNS1		DB "NET_DNS1",0
N_MASK		DB "NET_MASK",0
N_GW		DB "NET_GW",0


	ENDIF

	ENDMODULE
	ENDIF
