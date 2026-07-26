; ======================================================
; ICMP echo (ping) helper for the Sprinter RTL8019AS
; network kit.
;
; Extracted from PING.EXE (BUILD_ICMP_ECHO / WAIT_FOR_ICMP_REPLY)
; so the UNET DLL can implement UNET_FN_PING without a second
; copy of the framing.  Deliberately WITHOUT the parts of
; PING.EXE that are diagnostics rather than protocol: the -b/-m
; forced broadcast/multicast destinations, the TTL override,
; CAPTURE_RX_DIAG and the TX register snapshots all stay in the
; tool where they belong.
;
; Caller contract (same as tcp_lib / resolve_lib / udp_lib):
;   - @MAIN.OUR_IP / @MAIN.OUR_MAC populated.
;   - @MAIN.TX_BUF sized >= ICMPLIB_MAX_FRAME (300).
;   - @MAIN.RX_BUF (1518) / @MAIN.RX_HDR (4) present.
;   - @MAIN.TICK_AND_CHECK_KEY exists; CF=1 means cancel.
;   - ISA window OPEN across ECHO.
;   - @ARP.ANSWER_REQUEST available (USE_ARP_ANSWER).
;
; Guard the include with `DEFINE USE_ICMP`.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_ICMP_LIB
	DEFINE	_ICMP_LIB

	INCLUDE "memmap.inc"

	IFDEF USE_ICMP
	IFNDEF USE_ARP_ANSWER
	DEFINE USE_ARP_ANSWER
	ENDIF
	IFNDEF USE_RTL_SEND_FRAME
	DEFINE USE_RTL_SEND_FRAME
	ENDIF
	IFNDEF USE_RTL_RING_HAS_PACKET
	DEFINE USE_RTL_RING_HAS_PACKET
	ENDIF
	IFNDEF USE_RTL_READ_PACKET
	DEFINE USE_RTL_READ_PACKET
	ENDIF
	ENDIF

	MODULE ICMP

	IFDEF USE_ICMP

ETH_TYPE_IPV4	EQU 0x0800
IP_HDR_LEN	EQU 20
IP_PROTO_ICMP	EQU 1
HDR_LEN		EQU 8			; type, code, csum, id, seq
T_ECHO_REQ	EQU 8
T_ECHO_REP	EQU 0
TTL		EQU 64

; Echo identifier.  Fixed per session: the reply filter matches on
; id+seq, and a single outstanding request at a time is enough.
ECHO_ID_HI	EQU 0x52		; 'R'
ECHO_ID_LO	EQU 0x54		; 'T'

; LAST_FAIL codes -- same numbering as TCP.LAST_FAIL / UDP.LAST_FAIL.
F_NONE		EQU 0
F_SEND		EQU 1
F_TIMEOUT	EQU 2
F_CANCEL	EQU 5

; ------------------------------------------------------
; ECHO: send one echo request and wait for its reply.
;   In:  HL = pointer to 4-byte target IPv4.
;        DE = pointer to 6-byte next-hop MAC (from
;             RESOLVE.NEXT_HOP_FOR).
;        A  = payload length, 0..255 (even sizes preferred;
;             the checksum helper wants an even byte count).
;        BC = timeout in ms.
;        ISA window OPEN.
;   Out: CF=0 + DE = elapsed tick count (approximate RTT in ms).
;        CF=1 + LAST_FAIL = F_SEND / F_TIMEOUT / F_CANCEL.
; Trashes A, BC, DE, HL, IX.
;
; The RTT is derived from the poll loop, not a hardware timer:
; DE is (timeout - timeout_left), where each unit is one
; TICK_AND_CHECK_KEY pass (~1 ms) or one discarded frame.  A reply
; that arrives on the first drain pass therefore reports 0.  Treat
; it as coarse; this stack has no millisecond clock.
; ------------------------------------------------------
ECHO
	PUSH	AF				; payload length
	PUSH	BC				; timeout
	PUSH	DE				; MAC pointer
	LD	DE,ICMPLIB_TARGET_IP
	LD	BC,4
	LDIR
	POP	HL				; MAC pointer
	LD	DE,ICMPLIB_TARGET_MAC
	LD	BC,6
	LDIR
	POP	HL				; timeout
	LD	(ICMPLIB_TIMEOUT_LEFT),HL
	LD	(TIMEOUT_START),HL
	POP	AF				; payload length
	LD	(ICMPLIB_PAYLOAD_LEN),A
	XOR	A
	LD	(ICMPLIB_LAST_FAIL),A
	; Fresh sequence number for this request.
	LD	HL,(ICMPLIB_SEQ)
	INC	HL
	LD	(ICMPLIB_SEQ),HL

	CALL	BUILD_ECHO			; -> BC = frame length
	LD	HL,@MAIN.TX_BUF
	CALL	@RTL.SEND_FRAME
	JR	C,.SEND_FAIL
	CALL	WAIT_REPLY
	RET	C				; LAST_FAIL already set
	; Elapsed = start - left.
	LD	HL,(TIMEOUT_START)
	LD	DE,(ICMPLIB_TIMEOUT_LEFT)
	OR	A
	SBC	HL,DE
	EX	DE,HL				; DE = elapsed ticks
	OR	A				; CF=0
	RET
.SEND_FAIL
	LD	A,F_SEND
	LD	(ICMPLIB_LAST_FAIL),A
	SCF
	RET

; ------------------------------------------------------
; BUILD_ECHO: ETH + IPv4 + ICMP echo request in @MAIN.TX_BUF.
;   Out: BC = total Ethernet frame length.
; Trashes A, DE, HL, IX.
; ------------------------------------------------------
BUILD_ECHO
	; -- Ethernet header --
	LD	DE,@MAIN.TX_BUF
	LD	HL,ICMPLIB_TARGET_MAC
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

	; -- IPv4 header, total_len = 20 + 8 + payload --
	LD	A,0x45
	LD	(DE),A
	INC	DE
	XOR	A				; DSCP/ECN
	LD	(DE),A
	INC	DE
	LD	A,(ICMPLIB_PAYLOAD_LEN)
	ADD	A,IP_HDR_LEN + HDR_LEN
	LD	C,A
	LD	B,0
	JR	NC,.IPLEN
	INC	B
.IPLEN
	PUSH	BC				; save IP total length
	LD	A,B
	LD	(DE),A
	INC	DE
	LD	A,C
	LD	(DE),A
	INC	DE
	XOR	A				; identification
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	INC	DE
	XOR	A				; flags / fragment offset
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	A,TTL
	LD	(DE),A
	INC	DE
	LD	A,IP_PROTO_ICMP
	LD	(DE),A
	INC	DE
	XOR	A				; checksum placeholder
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	HL,@MAIN.OUR_IP
	LD	BC,4
	LDIR
	LD	HL,ICMPLIB_TARGET_IP
	LD	BC,4
	LDIR

	; -- ICMP echo request header --
	LD	A,T_ECHO_REQ
	LD	(DE),A
	INC	DE
	XOR	A				; code
	LD	(DE),A
	INC	DE
	XOR	A				; checksum placeholder
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
	LD	HL,(ICMPLIB_SEQ)
	LD	A,H				; sequence (BE)
	LD	(DE),A
	INC	DE
	LD	A,L
	LD	(DE),A
	INC	DE

	; -- payload: 0,1,2,... --
	LD	A,(ICMPLIB_PAYLOAD_LEN)
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

	; -- IPv4 header checksum over TX_BUF+14, 20 bytes --
	PUSH	IX
	LD	IX,@MAIN.TX_BUF + 14
	LD	BC,IP_HDR_LEN
	CALL	@UTIL.CHECKSUM
	POP	IX
	LD	A,H
	LD	(@MAIN.TX_BUF + 14 + 10),A
	LD	A,L
	LD	(@MAIN.TX_BUF + 14 + 11),A

	; -- ICMP checksum over TX_BUF+34, 8 + payload bytes --
	PUSH	IX
	LD	IX,@MAIN.TX_BUF + 14 + IP_HDR_LEN
	LD	A,(ICMPLIB_PAYLOAD_LEN)
	ADD	A,HDR_LEN
	LD	C,A
	LD	B,0
	JR	NC,.CKLEN
	INC	B
.CKLEN
	CALL	@UTIL.CHECKSUM
	POP	IX
	LD	A,H
	LD	(@MAIN.TX_BUF + 14 + IP_HDR_LEN + 2),A
	LD	A,L
	LD	(@MAIN.TX_BUF + 14 + IP_HDR_LEN + 3),A

	POP	BC				; IP total length
	LD	HL,14
	ADD	HL,BC
	LD	B,H
	LD	C,L				; BC = Ethernet frame length
	RET

; ------------------------------------------------------
; WAIT_REPLY: poll for the echo reply matching our id+seq.
;   Out: CF=0 matched; CF=1 + LAST_FAIL set.
; Trashes A, BC, DE, HL, IX.
; ------------------------------------------------------
WAIT_REPLY
.LP
	; Drain the ring back-to-back, ticking only when it is empty or
	; the budget is spent, and charging one timeout unit per frame.
	; Without this a broadcast burst buries the reply and stretches
	; the tick-counted timeout to tens of seconds (see PING.EXE).
	LD	A,RX_DRAIN_BUDGET
	LD	(RX_DRAIN_LEFT),A
.DRAIN
	CALL	@RTL.RING_HAS_PACKET
	JP	Z,.TICK
	LD	HL,@MAIN.RX_HDR
	LD	DE,@MAIN.RX_BUF
	LD	BC,1518				; see resolve_lib: RX_BUF is 1518
	CALL	@RTL.READ_PACKET
	JP	C,.MISS
	CALL	@ARP.ANSWER_REQUEST
	JR	NC,.MISS			; it was an ARP request for us
	LD	A,(@MAIN.RX_BUF + 12)
	CP	HIGH ETH_TYPE_IPV4
	JR	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 13)
	CP	LOW ETH_TYPE_IPV4
	JR	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 14)
	CP	0x45
	JR	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 14 + 9)
	CP	IP_PROTO_ICMP
	JR	NZ,.MISS
	LD	HL,@MAIN.RX_BUF + 14 + 12	; source IP == target
	LD	DE,ICMPLIB_TARGET_IP
	LD	B,4
.CMP_SRC
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.MISS
	INC	HL
	INC	DE
	DJNZ	.CMP_SRC
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 0)
	CP	T_ECHO_REP
	JR	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 4)
	CP	ECHO_ID_HI
	JP	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 5)
	CP	ECHO_ID_LO
	JP	NZ,.MISS
	LD	HL,(ICMPLIB_SEQ)
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 6)
	CP	H
	JP	NZ,.MISS
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 7)
	CP	L
	JP	NZ,.MISS
	OR	A				; CF=0: matched
	RET
.MISS
	LD	HL,(ICMPLIB_TIMEOUT_LEFT)
	DEC	HL
	LD	(ICMPLIB_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JP	Z,.TO
	LD	A,(RX_DRAIN_LEFT)
	DEC	A
	LD	(RX_DRAIN_LEFT),A
	JP	NZ,.DRAIN
.TICK						; ring empty or budget spent
	CALL	@MAIN.TICK_AND_CHECK_KEY
	JR	C,.CANCEL
	LD	HL,(ICMPLIB_TIMEOUT_LEFT)
	DEC	HL
	LD	(ICMPLIB_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JP	NZ,.LP
.TO
	LD	A,F_TIMEOUT
	LD	(ICMPLIB_LAST_FAIL),A
	SCF
	RET
.CANCEL
	LD	A,F_CANCEL
	LD	(ICMPLIB_LAST_FAIL),A
	SCF
	RET

TIMEOUT_START	DW 0

	ENDIF

	ENDMODULE
	ENDIF
