; ======================================================
; unetrtl_cold.asm -- "cold" RESOLVE/DNS/ARP/PING frame-building logic,
; assembled SEPARATELY from unetrtl.asm and appended as a trailing
; blob on UNETRTL.DLL's own file (see src/lib/win0cold.asm for the
; loader/dispatcher).  This image is ORG 0x0000 and runs only while
; win0cold.asm's RUN has mapped its page into MMU window 0 -- DI is in
; effect for the whole call and BOTH RST vectors DSS (0x10) and BIOS
; (0x08) are UNREACHABLE (their normal targets, which live at
; 0x0000..0x3FFF, are what this page just replaced).
;
; What lives here vs what stays hot: resolve_lib.asm's WAIT_ARP /
; WAIT_DNS and icmp_lib.asm's WAIT_REPLY all call
; @MAIN.TICK_AND_CHECK_KEY, which does RST DSS (DSS_SCANKEY) whenever
; cancel-key polling is enabled -- so those polling loops, and
; @NETENV.GET_IP (also RST DSS), MUST stay hot.  Everything below is
; the pure register/buffer logic those loops call OUT to before/after
; waiting -- frame building and DNS reply parsing -- which never
; touches DSS/BIOS and so is safe to run with both RST vectors
; unreachable.  This is exactly the boundary already established by
; the RTL8019AS ISA-window discipline elsewhere in this project: never
; call DSS/BIOS while a resource that ISR/DSS also needs is out from
; under them.
;
; Every routine below is a pure function of its register arguments
; plus whatever it reaches through the small COLD_CTX block (see
; src/include/coldctx.inc) -- NEVER an absolute address of the main
; DLL image, because the two images are assembled and relocated
; completely independently and this one has no way to know where the
; other landed.  dns_lib.asm is INCLUDEd below unmodified: every one
; of its routines (ENCODE_NAME/BUILD_QUERY/SKIP_NAME/PARSE_REPLY) is
; already pure register/caller-buffer logic with no fixed address and
; no RST of its own, so it needs no coldctx indirection at all.
;
; Dispatch: WIN0COLD.RUN always CALLs address 0x0000 with A = the
; function code it was given.  DISPATCH below is that fixed entry.
;
; License: BSD 3-Clause
; ======================================================

	INCLUDE "coldctx.inc"

	ORG 0x0000

DISPATCH
	OR	A
	JP	Z,FN_BUILD_ARP_REQUEST
	DEC	A
	JP	Z,FN_BUILD_DNS_QUERY
	DEC	A
	JP	Z,DNS.PARSE_REPLY		; tail-dispatch: signature already matches
	DEC	A
	JP	Z,FN_BUILD_ICMP_ECHO
	DEC	A
	JP	Z,FN_NEXT_HOP
	DEC	A
	JP	Z,FN_DRAIN_ARP
	DEC	A
	JP	Z,FN_DRAIN_DNS
	DEC	A
	JP	Z,FN_DRAIN_ICMP
	DEC	A
	JP	Z,FN_PARSE_LITERAL_IP
	RET				; unknown code: defensive no-op

; ------------------------------------------------------
; CALL_CHECKSUM: invoke the hot @UTIL.CHECKSUM routine (which takes
; IX as its OWN buffer pointer and fully advances it) without losing
; the caller's IX == &COLD_CTX.
;   In:  IX = &COLD_CTX.  HL = buffer pointer.  BC = byte count (even).
;   Out: HL = checksum.  IX restored to &COLD_CTX.
; Trashes A, DE, IY.
; ------------------------------------------------------
CALL_CHECKSUM
	LD	E,(IX+CCTX_CHECKSUM)
	LD	D,(IX+CCTX_CHECKSUM+1)	; DE = &CHECKSUM; HL (buffer ptr, the
					; caller's own arg) is left untouched --
					; an IX-indexed read into H/L would
					; clobber it before it reaches IX below
	PUSH	DE
	POP	IY			; IY = &CHECKSUM
	PUSH	IX			; save COLD_CTX
	PUSH	HL
	POP	IX			; IX = buffer pointer (CHECKSUM's own arg)
	CALL	INDIRECT_IY		; -> HL = checksum
	POP	IX			; restore COLD_CTX
	RET

INDIRECT_IY
	JP	(IY)

; ------------------------------------------------------
; CALL_HOT_IY: call the hot routine whose address is in IY, preserving
; IX (=COLD_CTX) across the call.  Use this for callees that derive
; their OWN IX internally (READ_PACKET, ANSWER_REQUEST -- which in
; turn calls SEND_FRAME) rather than expecting the caller to supply it
; as an argument (that case is CALL_CHECKSUM's, since @UTIL.CHECKSUM
; takes IX as ITS OWN buffer-pointer argument).  RING_HAS_PACKET is
; deliberately never reached this way -- see coldctx.inc's header.
;   In:  IY = target address; other registers = that target's own
;        arguments (never IX).
;   Out: whatever the target returns; IX unchanged.
; ------------------------------------------------------
CALL_HOT_IY
	PUSH	IX
	CALL	INDIRECT_IY
	POP	IX
	RET

; ------------------------------------------------------
; CHARGE_TIMEOUT: 16-bit decrement-and-test of the counter at (HL),
; writing the result back to the same address.  Shared tail for
; FN_DRAIN_ARP/FN_DRAIN_DNS/FN_DRAIN_ICMP's per-frame timeout charge.
;   In:  HL = &counter (2 bytes, little-endian).
;   Out: A = 2 if the counter reached zero (TIMEOUT for the hot
;        caller to report), else A = 0 (MISS -- hot caller keeps
;        draining/polling).
; Trashes A, DE.
; ------------------------------------------------------
CHARGE_TIMEOUT
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	DEC	HL
	DEC	DE
	LD	(HL),E
	INC	HL
	LD	(HL),D
	LD	A,D
	OR	E
	JR	Z,.TIMEOUT
	XOR	A
	RET
.TIMEOUT
	LD	A,2
	RET

; ------------------------------------------------------
; FN_BUILD_ARP_REQUEST (CFN_BUILD_ARP_REQUEST): assemble a 60-byte
; broadcast ARP "who-has" frame at TX_BUF, mirroring arp_lib.asm's
; (excluded-from-DLL) BUILD_REQUEST.
;   In:  IX = &COLD_CTX.  HL = pointer to 4-byte target IP
;        (RESOLVE_NEXT_HOP_IP).
;   Out: frame written to (CCTX_TX_BUF); length is always the fixed
;        ARP_FRAME_LEN(60) the hot caller already knows.
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
FN_BUILD_ARP_REQUEST
	LD	(.TARGET_IP),HL
	LD	L,(IX+CCTX_TX_BUF)
	LD	H,(IX+CCTX_TX_BUF+1)
	PUSH	HL
	POP	DE			; DE = TX_BUF cursor
	LD	A,0xFF
	LD	B,6
.DST
	LD	(DE),A
	INC	DE
	DJNZ	.DST
	LD	L,(IX+CCTX_OUR_MAC)
	LD	H,(IX+CCTX_OUR_MAC+1)
	LD	BC,6
	LDIR
	LD	A,0x08			; EtherType hi (ARP = 0x0806)
	LD	(DE),A
	INC	DE
	LD	A,0x06
	LD	(DE),A
	INC	DE
	XOR	A			; HW type hi
	LD	(DE),A
	INC	DE
	LD	A,1			; HW type lo (Ethernet)
	LD	(DE),A
	INC	DE
	LD	A,0x08			; Proto type hi
	LD	(DE),A
	INC	DE
	XOR	A			; Proto type lo (IPv4)
	LD	(DE),A
	INC	DE
	LD	A,6			; HW size
	LD	(DE),A
	INC	DE
	LD	A,4			; Proto size
	LD	(DE),A
	INC	DE
	XOR	A			; Op hi
	LD	(DE),A
	INC	DE
	LD	A,1			; Op lo (request)
	LD	(DE),A
	INC	DE
	LD	L,(IX+CCTX_OUR_MAC)	; Sender MAC
	LD	H,(IX+CCTX_OUR_MAC+1)
	LD	BC,6
	LDIR
	LD	L,(IX+CCTX_OUR_IP)	; Sender IP
	LD	H,(IX+CCTX_OUR_IP+1)
	LD	BC,4
	LDIR
	XOR	A			; Target MAC = 0*6
	LD	B,6
.TGT_MAC
	LD	(DE),A
	INC	DE
	DJNZ	.TGT_MAC
	LD	HL,(.TARGET_IP)		; Target IP
	LD	BC,4
	LDIR
	XOR	A			; Pad to 60 bytes (42 + 18)
	LD	B,18
.PAD
	LD	(DE),A
	INC	DE
	DJNZ	.PAD
	RET
.TARGET_IP	DW 0

; ------------------------------------------------------
; FN_BUILD_DNS_QUERY (CFN_BUILD_DNS_QUERY): ETH+IP+UDP+DNS query at
; TX_BUF, mirroring resolve_lib.asm's (excluded-from-DLL) BUILD_FRAME.
;   In:  IX = &COLD_CTX.  HL = ASCIIZ hostname.
;        DE = &RESOLVE_DNS_IP (resolve_lib's BSS base -- gives access
;             to RESOLVE_DNS_IP / RESOLVE_NEXT_HOP_MAC / RESOLVE_XID_*
;             via the RSBO_* offsets, see coldctx.inc).
;   Out: CF=0 ok, HL = total Ethernet frame length written at TX_BUF.
;        CF=1 invalid hostname (dns_lib rejects empty/oversize labels).
; Trashes A, BC, DE.
; ------------------------------------------------------
FN_BUILD_DNS_QUERY
	LD	(.HOSTNAME),HL
	LD	(.RESBASE),DE
	LD	L,(IX+CCTX_TX_BUF)
	LD	H,(IX+CCTX_TX_BUF+1)
	LD	(.TXBUF),HL
	; DNS message starts at TX_BUF + 14(ETH) + 20(IP) + 8(UDP) = +42.
	LD	DE,42
	ADD	HL,DE
	LD	(.MSGSTART),HL
	EX	DE,HL			; DE = dest for DNS.BUILD_QUERY
	LD	HL,(.RESBASE)
	LD	BC,RSBO_XID_HI
	ADD	HL,BC
	LD	A,(HL)
	LD	B,A			; XID hi
	INC	HL
	LD	A,(HL)
	LD	C,A			; XID lo
	LD	HL,(.HOSTNAME)
	CALL	DNS.BUILD_QUERY		; In: HL=name,DE=dest,BC=xid(hi,lo)
	RET	C
	; DE = past last byte -> message length -> UDP/IP/frame lengths.
	LD	HL,(.MSGSTART)
	EX	DE,HL
	OR	A
	SBC	HL,DE			; HL = DNS message length
	LD	BC,8
	ADD	HL,BC			; + UDP header
	LD	(.UDPLEN),HL
	LD	BC,20
	ADD	HL,BC			; + IP header
	LD	(.IPTOTAL),HL
	LD	BC,14
	ADD	HL,BC			; + ETH header = total frame length
	PUSH	HL			; saved for the final RET

	; -- Ethernet header --
	LD	HL,(.TXBUF)
	EX	DE,HL			; DE = TX_BUF cursor
	LD	HL,(.RESBASE)
	LD	BC,RSBO_NEXT_HOP_MAC
	ADD	HL,BC
	LD	BC,6
	LDIR
	LD	L,(IX+CCTX_OUR_MAC)
	LD	H,(IX+CCTX_OUR_MAC+1)
	LD	BC,6
	LDIR
	LD	A,0x08			; ETH_TYPE_IPV4 hi
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE

	; -- IPv4 header --
	LD	A,0x45
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	LD	HL,(.IPTOTAL)
	LD	A,H
	LD	(DE),A
	INC	DE
	LD	A,L
	LD	(DE),A
	INC	DE
	XOR	A			; identification
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	INC	DE
	XOR	A			; flags/fragment offset
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	A,64			; TTL
	LD	(DE),A
	INC	DE
	LD	A,17			; IP_PROTO_UDP
	LD	(DE),A
	INC	DE
	XOR	A			; checksum placeholder
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	L,(IX+CCTX_OUR_IP)
	LD	H,(IX+CCTX_OUR_IP+1)
	LD	BC,4
	LDIR
	LD	HL,(.RESBASE)
	LD	BC,RSBO_DNS_IP
	ADD	HL,BC
	LD	BC,4
	LDIR

	; -- UDP header --
	LD	A,0xC2			; DNS_SRC_PORT_HI
	LD	(DE),A
	INC	DE
	XOR	A			; DNS_SRC_PORT_LO
	LD	(DE),A
	INC	DE
	XOR	A			; dst port hi (53 = 0x0035)
	LD	(DE),A
	INC	DE
	LD	A,53
	LD	(DE),A
	INC	DE
	LD	HL,(.UDPLEN)
	LD	A,H
	LD	(DE),A
	INC	DE
	LD	A,L
	LD	(DE),A
	INC	DE
	XOR	A			; csum 0
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE

	; -- IP checksum over TX_BUF+14, 20 bytes --
	LD	HL,(.TXBUF)
	LD	BC,14
	ADD	HL,BC
	PUSH	HL			; IP header start, reused after the call
	LD	BC,20
	CALL	CALL_CHECKSUM		; HL = checksum
	EX	DE,HL			; DE = checksum
	POP	HL			; HL = IP header start
	LD	BC,10
	ADD	HL,BC
	LD	A,D
	LD	(HL),A
	INC	HL
	LD	A,E
	LD	(HL),A

	POP	HL			; total frame length
	OR	A			; CF=0
	RET
.HOSTNAME	DW 0
.RESBASE	DW 0
.TXBUF		DW 0
.MSGSTART	DW 0
.UDPLEN		DW 0
.IPTOTAL	DW 0

; ------------------------------------------------------
; FN_BUILD_ICMP_ECHO (CFN_BUILD_ICMP_ECHO): ETH+IPv4+ICMP echo request
; at TX_BUF, mirroring icmp_lib.asm's (excluded-from-DLL) BUILD_ECHO.
;   In:  IX = &COLD_CTX.  HL = &ICMPLIB_TARGET_IP (icmp_lib's BSS
;        base -- gives access to TARGET_IP/TARGET_MAC/SEQ/PAYLOAD_LEN
;        via the ICMBO_* offsets, see coldctx.inc; icmp_lib's own ECHO
;        has already staged all four there before this call).
;   Out: BC = total Ethernet frame length written at TX_BUF.
; Trashes A, DE, HL.
; ------------------------------------------------------
FN_BUILD_ICMP_ECHO
	LD	(.ICMPBASE),HL
	LD	L,(IX+CCTX_TX_BUF)
	LD	H,(IX+CCTX_TX_BUF+1)
	LD	(.TXBUF),HL
	PUSH	HL
	POP	DE			; DE = TX_BUF cursor

	; -- Ethernet header --
	LD	HL,(.ICMPBASE)
	LD	BC,ICMBO_TARGET_MAC
	ADD	HL,BC
	LD	BC,6
	LDIR
	LD	L,(IX+CCTX_OUR_MAC)
	LD	H,(IX+CCTX_OUR_MAC+1)
	LD	BC,6
	LDIR
	LD	A,0x08			; ETH_TYPE_IPV4 hi
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE

	; -- IPv4 header, total_len = 20 + 8 + payload --
	LD	A,0x45
	LD	(DE),A
	INC	DE
	XOR	A			; DSCP/ECN
	LD	(DE),A
	INC	DE
	LD	HL,(.ICMPBASE)
	LD	BC,ICMBO_PAYLOAD_LEN
	ADD	HL,BC
	LD	A,(HL)
	LD	(.PAYLEN),A
	ADD	A,28			; IP_HDR_LEN(20) + HDR_LEN(8)
	LD	C,A
	LD	B,0
	JR	NC,.IPLEN
	INC	B
.IPLEN
	LD	(.IPTOTAL),BC
	LD	A,B
	LD	(DE),A
	INC	DE
	LD	A,C
	LD	(DE),A
	INC	DE
	XOR	A			; identification
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	INC	DE
	XOR	A			; flags/fragment offset
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	A,64			; TTL
	LD	(DE),A
	INC	DE
	LD	A,1			; IP_PROTO_ICMP
	LD	(DE),A
	INC	DE
	XOR	A			; checksum placeholder
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	L,(IX+CCTX_OUR_IP)
	LD	H,(IX+CCTX_OUR_IP+1)
	LD	BC,4
	LDIR
	LD	HL,(.ICMPBASE)
	LD	BC,ICMBO_TARGET_IP
	ADD	HL,BC
	LD	BC,4
	LDIR

	; -- ICMP echo request header --
	LD	A,8			; T_ECHO_REQ
	LD	(DE),A
	INC	DE
	XOR	A			; code
	LD	(DE),A
	INC	DE
	XOR	A			; checksum placeholder
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	A,0x52			; ECHO_ID_HI 'R'
	LD	(DE),A
	INC	DE
	LD	A,0x54			; ECHO_ID_LO 'T'
	LD	(DE),A
	INC	DE
	LD	HL,(.ICMPBASE)
	LD	BC,ICMBO_SEQ
	ADD	HL,BC
	LD	A,(HL)			; sequence hi (BE)
	LD	(DE),A
	INC	DE
	INC	HL
	LD	A,(HL)			; sequence lo
	LD	(DE),A
	INC	DE

	; -- payload: 0,1,2,... --
	LD	A,(.PAYLEN)
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
	LD	HL,(.TXBUF)
	LD	BC,14
	ADD	HL,BC
	PUSH	HL
	LD	BC,20
	CALL	CALL_CHECKSUM
	EX	DE,HL
	POP	HL
	LD	BC,10
	ADD	HL,BC
	LD	A,D
	LD	(HL),A
	INC	HL
	LD	A,E
	LD	(HL),A

	; -- ICMP checksum over TX_BUF+34, 8 + payload bytes --
	LD	HL,(.TXBUF)
	LD	BC,34
	ADD	HL,BC
	PUSH	HL
	LD	A,(.PAYLEN)
	ADD	A,8			; HDR_LEN
	LD	C,A
	LD	B,0
	JR	NC,.CKLEN
	INC	B
.CKLEN
	CALL	CALL_CHECKSUM
	EX	DE,HL
	POP	HL
	LD	BC,2
	ADD	HL,BC
	LD	A,D
	LD	(HL),A
	INC	HL
	LD	A,E
	LD	(HL),A

	LD	BC,(.IPTOTAL)
	LD	HL,14
	ADD	HL,BC
	LD	B,H
	LD	C,L			; BC = Ethernet frame length
	RET
.ICMPBASE	DW 0
.TXBUF		DW 0
.PAYLEN		DB 0
.IPTOTAL	DW 0

; ------------------------------------------------------
; FN_NEXT_HOP (CFN_NEXT_HOP): pick ARP target based on subnet match,
; mirroring resolve_lib.asm's (excluded-from-DLL) NEXT_HOP.  The
; original advances three parallel pointers (target/our-ip/mask) using
; HL/DE/IX; IX here is &COLD_CTX and must stay put, so this copies the
; three 4-byte fields into local scratch first and only then borrows
; IX for the compare loop (COLD_CTX is not needed again afterward).
;   In:  IX = &COLD_CTX.  HL = &RESOLVE_DNS_IP (resolve_lib's BSS
;        base -- gives access to every RESOLVE_* field this needs via
;        the RSBO_* offsets, see coldctx.inc).
;   Out: RESOLVE_NEXT_HOP_IP (within that same base) filled.
;        CF=0 ok; CF=1 off-subnet and no NET_GW.
; Trashes A, BC, DE, HL, IX.
; ------------------------------------------------------
FN_NEXT_HOP
	LD	(.RESBASE),HL
	LD	L,(IX+CCTX_OUR_IP)
	LD	H,(IX+CCTX_OUR_IP+1)
	LD	DE,.OURIP
	LD	BC,4
	LDIR
	LD	HL,(.RESBASE)
	LD	BC,RSBO_HAS_MASK
	ADD	HL,BC
	LD	A,(HL)
	OR	A
	JR	Z,.DIRECT
	LD	HL,(.RESBASE)
	LD	BC,RSBO_DNS_IP
	ADD	HL,BC
	LD	DE,.TARGET
	LD	BC,4
	LDIR
	LD	HL,(.RESBASE)
	LD	BC,RSBO_NET_MASK
	ADD	HL,BC
	LD	DE,.MASK
	LD	BC,4
	LDIR
	LD	HL,.TARGET
	LD	DE,.OURIP
	LD	IX,.MASK		; COLD_CTX not needed again in this function
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
	LD	HL,(.RESBASE)
	LD	BC,RSBO_DNS_IP
	ADD	HL,BC			; HL = &DNS_IP (source)
	PUSH	HL
	LD	HL,(.RESBASE)
	LD	BC,RSBO_NEXT_HOP_IP
	ADD	HL,BC
	EX	DE,HL			; DE = &NEXT_HOP_IP (dest)
	POP	HL
	LD	BC,4
	LDIR
	OR	A
	RET
.OFFNET
	LD	HL,(.RESBASE)
	LD	BC,RSBO_HAS_GW
	ADD	HL,BC
	LD	A,(HL)
	OR	A
	SCF
	RET	Z
	LD	HL,(.RESBASE)
	LD	BC,RSBO_NET_GW
	ADD	HL,BC			; HL = &NET_GW (source)
	PUSH	HL
	LD	HL,(.RESBASE)
	LD	BC,RSBO_NEXT_HOP_IP
	ADD	HL,BC
	EX	DE,HL			; DE = &NEXT_HOP_IP (dest)
	POP	HL
	LD	BC,4
	LDIR
	OR	A
	RET
.RESBASE	DW 0
.OURIP		DS 4
.TARGET		DS 4
.MASK		DS 4

; ------------------------------------------------------
; FN_DRAIN_ARP (CFN_DRAIN_ARP): read ONE already-confirmed-present RX
; frame and check it against RESOLVE_NEXT_HOP_IP, mirroring
; resolve_lib.asm's (excluded-from-DLL) WAIT_ARP's per-frame body.
; The hot caller has already called the REAL @RTL.RING_HAS_PACKET
; (never reachable from cold -- see coldctx.inc) and confirmed a
; frame is present before making this call, once per frame; this is
; NOT a multi-frame drain loop, precisely so overflow recovery never
; has to run cold.
;   In:  IX = &COLD_CTX.  HL = &RESOLVE_DNS_IP (RESOLVE_BSS_BASE).
;   Out: A = 0 miss (keep polling), 1 match (RESOLVE_NEXT_HOP_MAC
;        filled), 2 timeout (RESOLVE_TIMEOUT_LEFT hit zero).
; Trashes B, C, D, E, H, L.
; ------------------------------------------------------
FN_DRAIN_ARP
	LD	(.RESBASE),HL
	LD	L,(IX+CCTX_READ_PACKET)
	LD	H,(IX+CCTX_READ_PACKET+1)
	PUSH	HL
	POP	IY
	LD	L,(IX+CCTX_RX_HDR)
	LD	H,(IX+CCTX_RX_HDR+1)
	PUSH	HL
	LD	L,(IX+CCTX_RX_BUF)
	LD	H,(IX+CCTX_RX_BUF+1)
	LD	(.RXBUF),HL
	EX	DE,HL			; DE = &RX_BUF
	POP	HL			; HL = &RX_HDR
	LD	BC,RX_BUF_SIZE_LIT
	CALL	CALL_HOT_IY
	JP	C,.MISS
	; EtherType == ARP
	LD	HL,(.RXBUF)
	LD	BC,12
	ADD	HL,BC
	LD	A,(HL)
	CP	0x08
	JP	NZ,.MISS
	INC	HL
	LD	A,(HL)
	CP	0x06
	JP	NZ,.MISS
	; op == reply (hi=0, lo=2)
	LD	HL,(.RXBUF)
	LD	BC,14+6
	ADD	HL,BC
	LD	A,(HL)
	OR	A
	JP	NZ,.MISS
	INC	HL
	LD	A,(HL)
	CP	2
	JP	NZ,.MISS
	; sender protocol address == RESOLVE_NEXT_HOP_IP
	LD	HL,(.RXBUF)
	LD	BC,14+14
	ADD	HL,BC
	LD	(.P1),HL
	LD	HL,(.RESBASE)
	LD	BC,RSBO_NEXT_HOP_IP
	ADD	HL,BC
	LD	(.P2),HL
	LD	HL,(.P1)
	LD	DE,(.P2)
	LD	B,4
.CMPIP
	LD	A,(DE)
	CP	(HL)
	JP	NZ,.MISS
	INC	HL
	INC	DE
	DJNZ	.CMPIP
	; match: copy sender MAC -> RESOLVE_NEXT_HOP_MAC
	LD	HL,(.RXBUF)
	LD	BC,14+8
	ADD	HL,BC
	LD	DE,(.RESBASE)
	LD	BC,RSBO_NEXT_HOP_MAC
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL			; DE = &RESOLVE_NEXT_HOP_MAC, HL = sender MAC in frame
	LD	BC,6
	LDIR
	LD	A,1
	RET
.MISS
	LD	HL,(.RESBASE)
	LD	BC,RSBO_TIMEOUT_LEFT
	ADD	HL,BC
	JP	CHARGE_TIMEOUT
.RESBASE	DW 0
.RXBUF		DW 0
.P1		DW 0
.P2		DW 0

; ------------------------------------------------------
; FN_DRAIN_DNS (CFN_DRAIN_DNS): read ONE already-confirmed-present RX
; frame and check it as the DNS reply for our query, mirroring
; resolve_lib.asm's (excluded-from-DLL) WAIT_DNS's per-frame body.
; Same one-frame-per-call contract as FN_DRAIN_ARP -- see its header.
;   In:  IX = &COLD_CTX.  HL = &RESOLVE_DNS_IP (RESOLVE_BSS_BASE).
;   Out: A = 0 miss, 1 match (RESOLVE_DNS_MSG_PTR/_LEN filled),
;        2 timeout.
; Trashes B, C, D, E, H, L.
; ------------------------------------------------------
FN_DRAIN_DNS
	LD	(.RESBASE),HL
	LD	L,(IX+CCTX_READ_PACKET)
	LD	H,(IX+CCTX_READ_PACKET+1)
	PUSH	HL
	POP	IY
	LD	L,(IX+CCTX_RX_HDR)
	LD	H,(IX+CCTX_RX_HDR+1)
	PUSH	HL
	LD	L,(IX+CCTX_RX_BUF)
	LD	H,(IX+CCTX_RX_BUF+1)
	LD	(.RXBUF),HL
	EX	DE,HL
	POP	HL
	LD	BC,RX_BUF_SIZE_LIT
	CALL	CALL_HOT_IY
	JP	C,.MISS
	; EtherType == IPv4, version/IHL == 0x45, proto == UDP(17)
	LD	HL,(.RXBUF)
	LD	BC,12
	ADD	HL,BC
	LD	A,(HL)
	CP	0x08
	JP	NZ,.MISS
	INC	HL
	LD	A,(HL)
	OR	A
	JP	NZ,.MISS
	LD	HL,(.RXBUF)
	LD	BC,14
	ADD	HL,BC
	LD	A,(HL)
	CP	0x45
	JP	NZ,.MISS
	LD	HL,(.RXBUF)
	LD	BC,14+9
	ADD	HL,BC
	LD	A,(HL)
	CP	17
	JP	NZ,.MISS
	; src IP == RESOLVE_DNS_IP
	LD	HL,(.RXBUF)
	LD	BC,14+12
	ADD	HL,BC
	LD	(.P1),HL
	LD	HL,(.RESBASE)
	LD	BC,RSBO_DNS_IP
	ADD	HL,BC
	LD	(.P2),HL
	LD	HL,(.P1)
	LD	DE,(.P2)
	LD	B,4
.CMPSRC
	LD	A,(DE)
	CP	(HL)
	JP	NZ,.MISS
	INC	HL
	INC	DE
	DJNZ	.CMPSRC
	; src port == 53
	LD	HL,(.RXBUF)
	LD	BC,14+20+0
	ADD	HL,BC
	LD	A,(HL)
	OR	A
	JP	NZ,.MISS
	INC	HL
	LD	A,(HL)
	CP	53
	JP	NZ,.MISS
	; dst port == our fixed DNS_SRC_PORT (0xC2, 0x00)
	LD	HL,(.RXBUF)
	LD	BC,14+20+2
	ADD	HL,BC
	LD	A,(HL)
	CP	0xC2
	JP	NZ,.MISS
	INC	HL
	LD	A,(HL)
	OR	A
	JP	NZ,.MISS
	; UDP length (BE) -> DNS msg length = UDP_LEN - 8
	LD	HL,(.RXBUF)
	LD	BC,14+20+4
	ADD	HL,BC
	LD	A,(HL)
	LD	D,A			; UDP len hi
	INC	HL
	LD	A,(HL)
	LD	E,A			; UDP len lo
	EX	DE,HL			; HL = UDP len
	LD	BC,8
	OR	A
	SBC	HL,BC			; HL = DNS msg length
	LD	(.MSGLEN),HL
	LD	HL,(.RXBUF)
	LD	BC,14+20+8
	ADD	HL,BC
	LD	(.MSGPTR),HL
	LD	HL,(.RESBASE)
	LD	BC,RSBO_DNS_MSG_LEN
	ADD	HL,BC
	LD	DE,(.MSGLEN)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	LD	HL,(.RESBASE)
	LD	BC,RSBO_DNS_MSG_PTR
	ADD	HL,BC
	LD	DE,(.MSGPTR)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	LD	A,1
	RET
.MISS
	LD	HL,(.RESBASE)
	LD	BC,RSBO_TIMEOUT_LEFT
	ADD	HL,BC
	JP	CHARGE_TIMEOUT
.RESBASE	DW 0
.RXBUF		DW 0
.P1		DW 0
.P2		DW 0
.MSGLEN		DW 0
.MSGPTR		DW 0

; ------------------------------------------------------
; FN_DRAIN_ICMP (CFN_DRAIN_ICMP): read ONE already-confirmed-present
; RX frame; if it's an ARP request for us, answer it (mirrors
; icmp_lib.asm's WAIT_REPLY calling @ARP.ANSWER_REQUEST); otherwise
; check it as the echo reply matching our target/id/seq.  Same
; one-frame-per-call contract as FN_DRAIN_ARP -- see its header.
; ANSWER_REQUEST's own CALL to SEND_FRAME is exactly the kind of
; IX-clobbering hot call CALL_HOT_IY exists for.
;   In:  IX = &COLD_CTX.  HL = &ICMPLIB_TARGET_IP (ICMP_BSS_BASE).
;   Out: A = 0 miss, 1 match, 2 timeout.
; Trashes B, C, D, E, H, L.
; ------------------------------------------------------
FN_DRAIN_ICMP
	LD	(.ICMPBASE),HL
	LD	L,(IX+CCTX_READ_PACKET)
	LD	H,(IX+CCTX_READ_PACKET+1)
	PUSH	HL
	POP	IY
	LD	L,(IX+CCTX_RX_HDR)
	LD	H,(IX+CCTX_RX_HDR+1)
	PUSH	HL
	LD	L,(IX+CCTX_RX_BUF)
	LD	H,(IX+CCTX_RX_BUF+1)
	LD	(.RXBUF),HL
	EX	DE,HL
	POP	HL
	LD	BC,RX_BUF_SIZE_LIT
	CALL	CALL_HOT_IY
	JP	C,.MISS
	LD	L,(IX+CCTX_ANSWER_REQUEST)
	LD	H,(IX+CCTX_ANSWER_REQUEST+1)
	PUSH	HL
	POP	IY
	CALL	CALL_HOT_IY
	JP	NC,.MISS		; it was an ARP request for us -- answered, not a reply
	; EtherType == IPv4, version/IHL == 0x45, proto == ICMP(1)
	LD	HL,(.RXBUF)
	LD	BC,12
	ADD	HL,BC
	LD	A,(HL)
	CP	0x08
	JP	NZ,.MISS
	INC	HL
	LD	A,(HL)
	OR	A
	JP	NZ,.MISS
	LD	HL,(.RXBUF)
	LD	BC,14
	ADD	HL,BC
	LD	A,(HL)
	CP	0x45
	JP	NZ,.MISS
	LD	HL,(.RXBUF)
	LD	BC,14+9
	ADD	HL,BC
	LD	A,(HL)
	CP	1
	JP	NZ,.MISS
	; src IP == ICMPLIB_TARGET_IP
	LD	HL,(.RXBUF)
	LD	BC,14+12
	ADD	HL,BC
	LD	(.P1),HL
	LD	HL,(.ICMPBASE)
	LD	BC,ICMBO_TARGET_IP
	ADD	HL,BC
	LD	(.P2),HL
	LD	HL,(.P1)
	LD	DE,(.P2)
	LD	B,4
.CMPIP
	LD	A,(DE)
	CP	(HL)
	JP	NZ,.MISS
	INC	HL
	INC	DE
	DJNZ	.CMPIP
	; ICMP type == echo-reply(0)
	LD	HL,(.RXBUF)
	LD	BC,14+20+0
	ADD	HL,BC
	LD	A,(HL)
	OR	A
	JP	NZ,.MISS
	; id == 'R','T' (ECHO_ID_HI/LO)
	LD	HL,(.RXBUF)
	LD	BC,14+20+4
	ADD	HL,BC
	LD	A,(HL)
	CP	0x52
	JP	NZ,.MISS
	INC	HL
	LD	A,(HL)
	CP	0x54
	JP	NZ,.MISS
	; seq == ICMPLIB_SEQ
	LD	HL,(.RXBUF)
	LD	BC,14+20+6
	ADD	HL,BC
	LD	(.P1),HL
	LD	HL,(.ICMPBASE)
	LD	BC,ICMBO_SEQ
	ADD	HL,BC
	LD	(.P2),HL
	LD	HL,(.P1)
	LD	DE,(.P2)
	LD	B,2
.CMPSEQ
	LD	A,(DE)
	CP	(HL)
	JP	NZ,.MISS
	INC	HL
	INC	DE
	DJNZ	.CMPSEQ
	LD	A,1
	RET
.MISS
	LD	HL,(.ICMPBASE)
	LD	BC,ICMBO_TIMEOUT_LEFT
	ADD	HL,BC
	JP	CHARGE_TIMEOUT
.ICMPBASE	DW 0
.RXBUF		DW 0
.P1		DW 0
.P2		DW 0

; ------------------------------------------------------
; FN_PARSE_LITERAL_IP (CFN_PARSE_LITERAL_IP): dotted-quad literal ->
; 4-byte IPv4, mirroring cmdline_lib.asm's (excluded-from-DLL, see its
; IFNDEF UNET_DLL) PARSE_IPV4.  @UTIL.PARSE_DEC_BYTE never touches IX
; and is RST-free, so CALL_HOT_IY's IX-preserving wrap is defensive
; here rather than strictly required.
;   In:  IX = &COLD_CTX.  HL = ASCIIZ text.  DE = 4-byte dest.
;   Out: CF=0 ok (DE..DE+3 filled); CF=1 not a literal dotted-quad.
; Trashes A, BC, HL.
; ------------------------------------------------------
FN_PARSE_LITERAL_IP
	PUSH	HL			; save text ptr while IY loads
	LD	L,(IX+CCTX_PARSE_DEC_BYTE)
	LD	H,(IX+CCTX_PARSE_DEC_BYTE+1)
	PUSH	HL
	POP	IY			; IY = &PARSE_DEC_BYTE
	POP	HL			; HL = text ptr (restored)
	PUSH	DE
	LD	B,4
.LP
	PUSH	BC
	CALL	CALL_HOT_IY		; In: HL=ptr -> Out: A=byte,HL=advanced,CF
	POP	BC
	JR	C,.BAD
	LD	(DE),A
	INC	DE
	DEC	B
	JR	Z,.OK
	LD	A,(HL)
	CP	'.'
	JR	NZ,.BAD
	INC	HL
	JR	.LP
.OK
	LD	A,(HL)
	OR	A
	JR	NZ,.BAD			; trailing junk
	POP	DE
	OR	A
	RET
.BAD
	POP	DE
	SCF
	RET

; dns_lib.asm's ENCODE_NAME/BUILD_QUERY/SKIP_NAME/PARSE_REPLY: pure
; register/caller-buffer logic, no fixed address, no RST -- included
; unmodified.  (unetrtl.asm does NOT include this file for the hot
; image; see its INCLUDE list.)
	DEFINE USE_DNS
	INCLUDE "dns_lib.asm"
