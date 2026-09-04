; ======================================================
; Connected-UDP datagram helper for the Sprinter RTL8019AS
; network kit.
;
; Extracted from the inline UDP framing that TFTP.EXE
; (BUILD_UDP_FRAME / WAIT_FOR_TFTP_DATA), UDPTEST.EXE and
; NTP.EXE each carry their own copy of, generalised for an
; arbitrary payload and made reusable so the UNET DLL can
; offer UDPOPEN / SEND / RECV without duplicating it again.
;
; "Connected" means the remote IP / MAC / port and the local
; port are latched by OPEN; SEND and RECV then need no address
; arguments and RECV filters everything else out.
;
; Caller contract (same as tcp_lib / resolve_lib):
;   - @MAIN.OUR_IP / @MAIN.OUR_MAC populated.
;   - @MAIN.TX_BUF sized >= UDPLIB_MAX_FRAME (1066).
;   - @MAIN.RX_BUF (1518) / @MAIN.RX_HDR (4) present.
;   - @MAIN.TICK_AND_CHECK_KEY exists; CF=1 means cancel.
;   - ISA window OPEN across SEND / RECV (they drive the NIC).
;   - @ARP.ANSWER_REQUEST available (USE_ARP_ANSWER) so the
;     peer can ARP us mid-wait without looking like RX loss.
;
; Guard the include with `DEFINE USE_UDP`.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_UDP_LIB
	DEFINE	_UDP_LIB

	INCLUDE "memmap.inc"

	IFDEF USE_UDP
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

	MODULE UDP

	IFDEF USE_UDP

ETH_TYPE_IPV4	EQU 0x0800
IP_HDR_LEN	EQU 20
UDP_HDR_LEN	EQU 8
IP_PROTO_UDP	EQU 17

; Default local port when the caller does not pick one.  Kept clear
; of resolve_lib's fixed DNS source port (0xC200) so a resolve and a
; user datagram can be in flight in the same session.
DEF_LOCAL_PORT	EQU 0xC400

; LAST_FAIL codes -- same numbering as TCP.LAST_FAIL so a caller can
; map both through one table.
F_NONE		EQU 0
F_SEND		EQU 1
F_TIMEOUT	EQU 2
F_CANCEL	EQU 5
F_OTHER		EQU 6	; head packet belongs to another UNET channel

; ------------------------------------------------------
; OPEN: latch the peer for subsequent SEND / RECV.
;   In:  HL = pointer to 4-byte remote IPv4.
;        DE = pointer to 6-byte next-hop MAC (from
;             RESOLVE.NEXT_HOP_FOR).
;        BC = remote UDP port, host order.
;        IY = local UDP port, host order (0 = default).
;   Out: CF=0 always.  No packet is sent.
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
OPEN
	PUSH	DE				; MAC pointer
	PUSH	BC				; remote port
	LD	DE,UDPLIB_REMOTE_IP
	LD	BC,4
	LDIR
	POP	HL				; remote port
	LD	(UDPLIB_REMOTE_PORT),HL
	POP	HL				; MAC pointer
	LD	DE,UDPLIB_REMOTE_MAC
	LD	BC,6
	LDIR
	PUSH	IY
	POP	HL				; requested local port
	LD	A,H
	OR	L
	JR	NZ,.LOCAL_SET
	LD	HL,DEF_LOCAL_PORT
.LOCAL_SET
	LD	(UDPLIB_LOCAL_PORT),HL
	XOR	A
	LD	(UDPLIB_LAST_FAIL),A
	OR	A				; CF=0
	RET

; ------------------------------------------------------
; CLOSE: forget the peer.  There is nothing on the wire to
; tear down for UDP, so this only clears local state.
; ------------------------------------------------------
CLOSE
	XOR	A
	LD	(UDPLIB_REMOTE_IP),A
	LD	(UDPLIB_LAST_FAIL),A
	RET

; ------------------------------------------------------
; SEND: transmit one datagram to the latched peer.
;   In:  HL = payload, BC = length (0..UDPLIB_MAX_PAYLOAD).
;        ISA window OPEN.
;   Out: CF=0 sent; CF=1 + LAST_FAIL = F_SEND.
; Trashes A, BC, DE, HL, IX.
; ------------------------------------------------------
SEND
	LD	(UDPLIB_PAYLOAD_PTR),HL
	LD	(UDPLIB_PAYLOAD_LEN),BC
	CALL	BUILD_FRAME			; -> BC = total frame length
	IFDEF	UNET_DLL
	; Zero-copy: BUILD_FRAME left the payload in the caller's own
	; buffer (never copied into TX_BUF).  Hand that buffer to
	; SEND_FRAME_SG as the payload descriptor and pass only the
	; 42-byte ETH+IP+UDP header region built in TX_BUF; the DMA
	; write streams both regions into one burst.  BUILD_FRAME's
	; returned total length is unused here -- SEND_FRAME_SG derives
	; it from the header/payload descriptors itself.
	LD	HL,(UDPLIB_PAYLOAD_PTR)
	LD	(@RTL.TX_PAY_PTR),HL
	LD	HL,(UDPLIB_PAYLOAD_LEN)
	LD	(@RTL.TX_PAY_LEN),HL
	LD	HL,@MAIN.TX_BUF
	LD	BC,14 + IP_HDR_LEN + UDP_HDR_LEN
	CALL	@RTL.SEND_FRAME_SG
	ELSE
	LD	HL,@MAIN.TX_BUF
	CALL	@RTL.SEND_FRAME
	ENDIF
	JR	C,.FAIL
	XOR	A
	LD	(UDPLIB_LAST_FAIL),A
	OR	A				; CF=0
	RET
.FAIL
	LD	A,F_SEND
	LD	(UDPLIB_LAST_FAIL),A
	SCF
	RET

; ------------------------------------------------------
; BUILD_FRAME: ETH + IPv4 + UDP + payload in @MAIN.TX_BUF.
; UDP checksum is left 0 (permitted for IPv4).
;   In:  UDPLIB_PAYLOAD_PTR / _LEN, peer state.
;   Out: BC = total Ethernet frame length.
; Trashes A, DE, HL, IX.
; ------------------------------------------------------
BUILD_FRAME
	; -- Ethernet header --
	LD	DE,@MAIN.TX_BUF
	LD	HL,UDPLIB_REMOTE_MAC
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
	LD	HL,(UDPLIB_PAYLOAD_LEN)
	LD	BC,IP_HDR_LEN + UDP_HDR_LEN
	ADD	HL,BC
	PUSH	HL				; save IP total length
	LD	A,0x45
	LD	(DE),A
	INC	DE
	XOR	A				; DSCP/ECN
	LD	(DE),A
	INC	DE
	LD	A,H				; total length (BE)
	LD	(DE),A
	INC	DE
	LD	A,L
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
	LD	A,64				; TTL
	LD	(DE),A
	INC	DE
	LD	A,IP_PROTO_UDP
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
	LD	HL,UDPLIB_REMOTE_IP
	LD	BC,4
	LDIR

	; -- UDP header, udp_len = 8 + payload --
	LD	HL,(UDPLIB_PAYLOAD_LEN)
	LD	BC,UDP_HDR_LEN
	ADD	HL,BC
	PUSH	HL				; save UDP length
	LD	HL,(UDPLIB_LOCAL_PORT)
	LD	A,H				; source port (BE)
	LD	(DE),A
	INC	DE
	LD	A,L
	LD	(DE),A
	INC	DE
	LD	HL,(UDPLIB_REMOTE_PORT)
	LD	A,H				; destination port (BE)
	LD	(DE),A
	INC	DE
	LD	A,L
	LD	(DE),A
	INC	DE
	POP	HL				; UDP length
	LD	A,H
	LD	(DE),A
	INC	DE
	LD	A,L
	LD	(DE),A
	INC	DE
	XOR	A				; UDP checksum = 0 (disabled)
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE

	; -- payload --
	; UNET_DLL streams the payload straight from the caller's buffer
	; via SEND_FRAME_SG (see SEND above) instead of copying it here;
	; TX_BUF holds headers only, so there is nothing to LDIR.
	IFNDEF	UNET_DLL
	LD	HL,(UDPLIB_PAYLOAD_PTR)
	LD	BC,(UDPLIB_PAYLOAD_LEN)
	LD	A,B
	OR	C
	JR	Z,.NO_PAYLOAD
	LDIR
.NO_PAYLOAD
	ENDIF

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

	POP	HL				; IP total length
	LD	BC,14
	ADD	HL,BC
	LD	B,H
	LD	C,L				; BC = Ethernet frame length
	RET

; ------------------------------------------------------
; RECV: wait for one datagram from the latched peer.
;   In:  HL = destination buffer, BC = max bytes,
;        DE = timeout in ms.  ISA window OPEN.
;   Out: CF=0, BC = bytes copied; UDPLIB_RX_FLAGS bit0 set
;             when the datagram was longer than max and the
;             tail was dropped.
;        CF=1 + LAST_FAIL = F_TIMEOUT / F_CANCEL.
; Trashes A, BC, DE, HL, IX.
; ------------------------------------------------------
RECV
	LD	(RECV_DEST),HL
	LD	(RECV_MAX),BC
	EX	DE,HL
	LD	(UDPLIB_TIMEOUT_LEFT),HL
	XOR	A
	LD	(UDPLIB_RX_FLAGS),A
.LP
	; Drain the ring back-to-back, tick only when it is empty or the
	; budget is spent.  Same shape as RESOLVE.WAIT_ARP: without this a
	; broadcast burst buries the reply, and charging one timeout unit
	; per discarded frame keeps the tick-counted timeout honest.
	LD	A,RX_DRAIN_BUDGET
	LD	(RX_DRAIN_LEFT),A
.DRAIN
	CALL	@RTL.RING_HAS_PACKET
	JR	Z,.TICK
	LD	HL,@MAIN.RX_HDR
	LD	DE,@MAIN.RX_BUF
	IFDEF UNET_DLL
	LD	BC,@MAIN.RX_BUF_SIZE
	ELSE
	LD	BC,1518				; see resolve_lib: RX_BUF is 1518
	ENDIF
	IFDEF USE_UDP_MULTICHAN
	CALL	@RTL.PEEK_PACKET
	ELSE
	CALL	@RTL.READ_PACKET
	ENDIF
	JR	C,.MISS
	IFDEF USE_UDP_MULTICHAN
	CALL	MATCH
	JR	NC,.COMMIT_MATCH
	LD	A,2				; caller protocol = UDP
	CALL	@UNET.HANDLE_FOREIGN_FRAME
	JR	NC,.COMMIT_MISS
	OR	A
	JR	Z,.MISS				; consumed/queued by the other channel
	LD	A,F_OTHER			; leave the packet at the ring head
	LD	(UDPLIB_LAST_FAIL),A
	SCF
	RET
.COMMIT_MISS
	LD	HL,@MAIN.RX_HDR
	CALL	@RTL.COMMIT_PACKET
	CALL	@ARP.ANSWER_REQUEST
	JR	NC,.MISS
	JR	.MISS
.COMMIT_MATCH
	LD	HL,@MAIN.RX_HDR
	CALL	@RTL.COMMIT_PACKET
	JR	.DELIVER
	ELSE
	; Answer an ARP request for us while we wait; peers routinely ARP
	; the sender before replying, and ignoring it looks like RX loss.
	CALL	@ARP.ANSWER_REQUEST
	JR	NC,.MISS			; it was ARP: nothing more to do
	CALL	MATCH
	JR	C,.MISS
	; Match: copy min(payload, max) out.
	JR	.DELIVER
	ENDIF
.MISS
	LD	HL,(UDPLIB_TIMEOUT_LEFT)
	DEC	HL
	LD	(UDPLIB_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JR	Z,.TO
	LD	A,(RX_DRAIN_LEFT)
	DEC	A
	LD	(RX_DRAIN_LEFT),A
	JR	NZ,.DRAIN
.TICK						; ring empty or budget spent
	; Consume the budget BEFORE the 1 ms tick, mirroring tcp_lib.asm's
	; RECV: the final pass then returns without a wasted delay.  A
	; non-blocking poll (timeout<=1) against an empty ring costs nothing.
	LD	HL,(UDPLIB_TIMEOUT_LEFT)
	DEC	HL
	LD	(UDPLIB_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JR	Z,.TO
	CALL	@MAIN.TICK_AND_CHECK_KEY
	JR	C,.CANCEL
	JR	.LP
.TO
	LD	A,F_TIMEOUT
	LD	(UDPLIB_LAST_FAIL),A
	SCF
	RET
.CANCEL
	LD	A,F_CANCEL
	LD	(UDPLIB_LAST_FAIL),A
	SCF
	RET
.DELIVER
	; UDPLIB_RX_LEN holds the payload length computed by MATCH.
	LD	HL,(UDPLIB_RX_LEN)
	LD	DE,(RECV_MAX)
	OR	A
	SBC	HL,DE				; CF=1 when payload < max
	JR	C,.FITS
	JR	Z,.FITS
	; Oversized: deliver max bytes and flag the truncation.
	LD	A,1
	LD	(UDPLIB_RX_FLAGS),A
	LD	HL,(RECV_MAX)
	JR	.COPY
.FITS
	LD	HL,(UDPLIB_RX_LEN)
.COPY
	LD	B,H
	LD	C,L
	LD	(UDPLIB_RX_LEN),HL		; actual delivered count
	LD	A,B
	OR	C
	JR	Z,.EMPTY
	PUSH	BC
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + UDP_HDR_LEN
	LD	DE,(RECV_DEST)
	LDIR
	POP	BC
	XOR	A
	LD	(UDPLIB_LAST_FAIL),A
	OR	A				; CF=0
	RET
.EMPTY
	LD	BC,0
	XOR	A
	LD	(UDPLIB_LAST_FAIL),A
	OR	A
	RET

; ------------------------------------------------------
; MATCH: is @MAIN.RX_BUF a UDP datagram from the latched
; peer addressed to our local port?
;   Out: CF=0 match, UDPLIB_RX_LEN = payload length;
;        CF=1 not ours.
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
MATCH
	LD	A,(@MAIN.RX_BUF + 12)
	CP	HIGH ETH_TYPE_IPV4
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 13)
	CP	LOW ETH_TYPE_IPV4
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14)
	CP	0x45				; IPv4, no options
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + 9)
	CP	IP_PROTO_UDP
	JR	NZ,.NO
	; source IP must be the peer
	LD	HL,@MAIN.RX_BUF + 14 + 12
	LD	DE,UDPLIB_REMOTE_IP
	LD	B,4
.CMP_SRC
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.NO
	INC	HL
	INC	DE
	DJNZ	.CMP_SRC
	; destination port must be ours
	LD	HL,(UDPLIB_LOCAL_PORT)
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 2)
	CP	H
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 3)
	CP	L
	JR	NZ,.NO
	; source port must be the peer's
	LD	HL,(UDPLIB_REMOTE_PORT)
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 0)
	CP	H
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 1)
	CP	L
	JR	NZ,.NO
	; payload length = UDP length - 8
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 4)
	LD	H,A
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 5)
	LD	L,A
	LD	DE,UDP_HDR_LEN
	OR	A
	SBC	HL,DE
	JR	C,.NO				; malformed: UDP length < 8
	LD	(UDPLIB_RX_LEN),HL
	OR	A				; CF=0
	RET
.NO
	SCF
	RET

RECV_DEST	DW 0
RECV_MAX	DW 0

	ENDIF

	ENDMODULE
	ENDIF
