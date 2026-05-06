; ======================================================
; Minimal DHCP/BOOTP client library.
;
; Phase A scope:
;   DHCP.BUILD_DISCOVER    build DHCPDISCOVER frame in caller's TX_BUF
;   DHCP.BUILD_REQUEST     build DHCPREQUEST referencing earlier OFFER
;   DHCP.PARSE_REPLY       validate Eth/IPv4/UDP/BOOTP and extract
;                          options into DHCP_* fields (memmap.inc)
;
; Frame layout (broadcast):
;   Eth: dst=ff*6, src=NET_MAC, type=0x0800
;   IPv4: VHL=0x45 TTL=64 proto=17 src=0.0.0.0 dst=255.255.255.255
;   UDP:  src=68 dst=67 chksum=0
;   BOOTP: 240 bytes fixed (op, htype, ..., chaddr, sname, file,
;          magic cookie 0x63825363)
;   Options: 53 (msg type), 50/54 (req IP/server id, REQUEST only),
;            55 (param request list), 255 (end)
;
; Caller responsibilities:
;   - TX_BUF must have room for ~300 bytes.
;   - Pass NET_MAC pointer in HL to BUILD_DISCOVER / BUILD_REQUEST.
;   - DHCP.PARSE_REPLY expects HL = start of Ethernet frame in
;     RX_BUF.  Returns CF=0 + DHCP_MSG_TYPE valid; CF=1 on rejection
;     (not for us, wrong xid, malformed, etc.).
;
; Storage uses DHCP_* labels in src/include/memmap.inc; the library
; never emits .EXE bytes for them.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_DHCP_LIB
	DEFINE	_DHCP_LIB

	INCLUDE "memmap.inc"

	IFDEF USE_DHCP

; -- Wire constants --------------------------------------
ETH_TYPE_IPV4	EQU 0x0800
IP_PROTO_UDP	EQU 17
DHCP_CLIENT_PORT EQU 68
DHCP_SERVER_PORT EQU 67

DHCP_OP_REQUEST	EQU 1			; BOOTREQUEST
DHCP_OP_REPLY	EQU 2

DHCP_HTYPE_ETH	EQU 1
DHCP_HLEN_ETH	EQU 6
DHCP_FLAGS_BCAST EQU 0x8000

DHCP_MAGIC_0	EQU 0x63
DHCP_MAGIC_1	EQU 0x82
DHCP_MAGIC_2	EQU 0x53
DHCP_MAGIC_3	EQU 0x63

; Message types (option 53)
DHCPDISCOVER	EQU 1
DHCPOFFER	EQU 2
DHCPREQUEST	EQU 3
DHCPACK		EQU 5
DHCPNAK		EQU 6

; Options
OPT_PAD		EQU 0
OPT_MASK	EQU 1
OPT_ROUTER	EQU 3
OPT_DNS		EQU 6
OPT_REQUESTED_IP EQU 50
OPT_LEASE_TIME	EQU 51
OPT_MSG_TYPE	EQU 53
OPT_SERVER_ID	EQU 54
OPT_PARAM_REQ	EQU 55
OPT_END		EQU 255

; Frame layout offsets relative to TX_BUF (Ethernet start).
DHCP_ETH_DST	EQU 0
DHCP_ETH_SRC	EQU 6
DHCP_ETH_TYPE	EQU 12
DHCP_IP_OFF	EQU 14		; IPv4 header
DHCP_IP_LEN	EQU 20
DHCP_UDP_OFF	EQU 14 + 20
DHCP_UDP_LEN	EQU 8
DHCP_BOOTP_OFF	EQU 14 + 20 + 8	; 42
DHCP_BOOTP_HDR_LEN EQU 236		; BOOTP header up to (excluding) magic cookie
DHCP_BOOTP_FIXED EQU 240		; BOOTP header + magic cookie (offset to options)
DHCP_OPT_OFF	EQU DHCP_BOOTP_OFF + DHCP_BOOTP_FIXED	; 282

	MODULE DHCP

	IFDEF USE_DHCP

; -- Public field aliases (memmap-backed) -----------------
XID		EQU DHCP_XID
MSG_TYPE	EQU DHCP_MSG_TYPE
OFFERED_IP	EQU DHCP_OFFERED_IP
SERVER_ID	EQU DHCP_SERVER_ID
MASK		EQU DHCP_MASK
ROUTER		EQU DHCP_ROUTER
DNS1		EQU DHCP_DNS1
DNS2		EQU DHCP_DNS2
LEASE_SECS	EQU DHCP_LEASE_SECS


; ------------------------------------------------------
; GEN_XID: generate a 4-byte transaction id from MAC[2..5]
; XOR'd with the Z80 R refresh counter and SP low byte.
; No DSS calls -- safe with ISA window open.
;   In:  HL = pointer to 6-byte source MAC.
;   Out: 4 bytes written to XID.
;   Trashes A, BC, DE, HL.
; ------------------------------------------------------
GEN_XID
	PUSH	HL
	INC	HL
	INC	HL			; HL -> MAC[2]
	LD	DE,XID
	LD	BC,4
	LDIR
	; Mix XID[0] with R (refresh counter; advances on every fetch).
	LD	A,R
	LD	HL,XID
	XOR	(HL)
	LD	(HL),A
	; Mix XID[3] with SP low byte for additional entropy.
	LD	HL,0
	ADD	HL,SP
	LD	A,L
	LD	HL,XID + 3
	XOR	(HL)
	LD	(HL),A
	POP	HL
	RET


; ------------------------------------------------------
; BUILD_DISCOVER: build DHCPDISCOVER frame in (DE).
;   In:  DE = TX_BUF base; HL = ptr to 6-byte source MAC.
;   Out: BC = total frame length (in bytes).
;   Trashes A, BC, DE, HL, IX.
; ------------------------------------------------------
BUILD_DISCOVER
	PUSH	DE			; save TX_BUF (GEN_XID trashes DE!)
	PUSH	HL			; save MAC ptr
	CALL	GEN_XID
	POP	HL			; HL = MAC ptr
	POP	DE			; DE = TX_BUF base again

	PUSH	DE			; save again for FINISH_FRAME
	; Fill the BOOTP header + base wire boilerplate.
	CALL	FILL_HEADERS

	; Now DE points just past the BOOTP fixed (after magic cookie).
	; Append DISCOVER-specific options.
	LD	A,OPT_MSG_TYPE
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	INC	DE
	LD	A,DHCPDISCOVER
	LD	(DE),A
	INC	DE
	CALL	APPEND_PARAM_REQ_LIST
	LD	A,OPT_END
	LD	(DE),A
	INC	DE

	; DE now points past last option byte.  Compute lengths and
	; finalize IP/UDP headers + checksum.
	POP	HL			; HL = TX_BUF base
	CALL	FINISH_FRAME		; sets BC = total length
	RET


; ------------------------------------------------------
; BUILD_REQUEST: build DHCPREQUEST referencing earlier OFFER.
; Requires OFFERED_IP and SERVER_ID populated by PARSE_REPLY.
;   In:  DE = TX_BUF base; HL = ptr to source MAC.
;   Out: BC = total frame length.
;   Trashes A, BC, DE, HL, IX.
; ------------------------------------------------------
BUILD_REQUEST
	PUSH	DE
	CALL	FILL_HEADERS		; xid stays from DISCOVER
	LD	A,OPT_MSG_TYPE
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	INC	DE
	LD	A,DHCPREQUEST
	LD	(DE),A
	INC	DE
	; option 50: requested IP = OFFERED_IP
	LD	A,OPT_REQUESTED_IP
	LD	(DE),A
	INC	DE
	LD	A,4
	LD	(DE),A
	INC	DE
	LD	HL,OFFERED_IP
	LD	BC,4
	LDIR
	; option 54: server identifier
	LD	A,OPT_SERVER_ID
	LD	(DE),A
	INC	DE
	LD	A,4
	LD	(DE),A
	INC	DE
	LD	HL,SERVER_ID
	LD	BC,4
	LDIR
	CALL	APPEND_PARAM_REQ_LIST
	LD	A,OPT_END
	LD	(DE),A
	INC	DE

	POP	HL
	CALL	FINISH_FRAME
	RET


; ------------------------------------------------------
; FILL_HEADERS: populate Eth+IP+UDP+BOOTP fixed in (DE).
; Caller passes DE = TX_BUF base, HL = MAC source ptr.
; XID must already be in DHCP.XID.
; Returns DE pointing past the magic cookie (start of options).
; Trashes A, BC.  HL preserved as the MAC ptr (still needed?).
; ------------------------------------------------------
FILL_HEADERS
	; Save MAC ptr -- the first LDIR below advances HL past MAC,
	; but chaddr further down needs the original MAC again.
	PUSH	HL
	; Ethernet: dst broadcast.
	LD	B,6
	LD	A,0xFF
.E_DST
	LD	(DE),A
	INC	DE
	DJNZ	.E_DST
	; Ethernet: src = MAC.
	POP	HL
	PUSH	HL			; keep saved
	LD	BC,6
	LDIR			; LDIR HL->DE.  DE advances by 6.
	; EtherType IPv4.
	LD	A,HIGH ETH_TYPE_IPV4
	LD	(DE),A
	INC	DE
	LD	A,LOW ETH_TYPE_IPV4
	LD	(DE),A
	INC	DE

	; -- IPv4 header (20 bytes; total length filled by FINISH_FRAME).
	LD	A,0x45			; ver+IHL
	LD	(DE),A
	INC	DE
	XOR	A			; DSCP
	LD	(DE),A
	INC	DE
	LD	(DE),A			; total length placeholder hi
	INC	DE
	LD	(DE),A			; total length placeholder lo
	INC	DE
	LD	(DE),A			; id
	INC	DE
	LD	(DE),A
	INC	DE
	LD	(DE),A			; flags+frag
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
	; src IP = 0.0.0.0
	LD	B,4
.IP_S
	XOR	A
	LD	(DE),A
	INC	DE
	DJNZ	.IP_S
	; dst IP = 255.255.255.255
	LD	B,4
	LD	A,0xFF
.IP_D
	LD	(DE),A
	INC	DE
	DJNZ	.IP_D

	; -- UDP header (length filled later, checksum 0).
	LD	A,HIGH DHCP_CLIENT_PORT
	LD	(DE),A
	INC	DE
	LD	A,LOW DHCP_CLIENT_PORT
	LD	(DE),A
	INC	DE
	LD	A,HIGH DHCP_SERVER_PORT
	LD	(DE),A
	INC	DE
	LD	A,LOW DHCP_SERVER_PORT
	LD	(DE),A
	INC	DE
	XOR	A			; UDP length hi (filled in FINISH)
	LD	(DE),A
	INC	DE
	LD	(DE),A			; UDP length lo
	INC	DE
	LD	(DE),A			; UDP checksum (0 = unused, IPv4 ok)
	INC	DE
	LD	(DE),A
	INC	DE

	; -- BOOTP fixed (240 bytes).
	LD	A,DHCP_OP_REQUEST
	LD	(DE),A
	INC	DE
	LD	A,DHCP_HTYPE_ETH
	LD	(DE),A
	INC	DE
	LD	A,DHCP_HLEN_ETH
	LD	(DE),A
	INC	DE
	XOR	A			; hops
	LD	(DE),A
	INC	DE
	; xid (4 bytes from DHCP.XID)
	PUSH	HL
	LD	HL,XID
	LD	BC,4
	LDIR
	POP	HL
	; secs = 0
	XOR	A
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	; flags = 0x8000 (broadcast bit, BE)
	LD	A,HIGH DHCP_FLAGS_BCAST
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	; ciaddr/yiaddr/siaddr/giaddr = 0 (16 bytes)
	LD	B,16
.ZERO_ADDRS
	XOR	A
	LD	(DE),A
	INC	DE
	DJNZ	.ZERO_ADDRS
	; chaddr = MAC (6) + 10 zero bytes.  HL was advanced past
	; MAC earlier; reload from the saved entry copy.
	POP	HL			; HL = MAC again
	LD	BC,6
	LDIR
	LD	B,10
.PAD_CHADDR
	XOR	A
	LD	(DE),A
	INC	DE
	DJNZ	.PAD_CHADDR
	; sname (64) + file (128) = 192 zero bytes
	LD	BC,192
.PAD_SNAME
	XOR	A
	LD	(DE),A
	INC	DE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.PAD_SNAME
	; magic cookie
	LD	A,DHCP_MAGIC_0
	LD	(DE),A
	INC	DE
	LD	A,DHCP_MAGIC_1
	LD	(DE),A
	INC	DE
	LD	A,DHCP_MAGIC_2
	LD	(DE),A
	INC	DE
	LD	A,DHCP_MAGIC_3
	LD	(DE),A
	INC	DE
	RET


; APPEND_PARAM_REQ_LIST: option 55 with [mask, router, dns, lease].
; Writes 6 bytes at (DE), advances DE.
APPEND_PARAM_REQ_LIST
	LD	A,OPT_PARAM_REQ
	LD	(DE),A
	INC	DE
	LD	A,4
	LD	(DE),A
	INC	DE
	LD	A,OPT_MASK
	LD	(DE),A
	INC	DE
	LD	A,OPT_ROUTER
	LD	(DE),A
	INC	DE
	LD	A,OPT_DNS
	LD	(DE),A
	INC	DE
	LD	A,OPT_LEASE_TIME
	LD	(DE),A
	INC	DE
	RET


; ------------------------------------------------------
; FINISH_FRAME: patch IP and UDP length fields and IP
; checksum.  HL = TX_BUF base; DE = address just past last
; option byte.
;   Out: BC = total Ethernet frame length.
;   Trashes A, BC, DE, HL, IX.
; ------------------------------------------------------
FINISH_FRAME
	PUSH	DE
	; Total frame length = DE - HL.  IP total length = frame - 14.
	LD	A,E
	SUB	L
	LD	C,A
	LD	A,D
	SBC	A,H
	LD	B,A			; BC = total frame length
	; UDP length = frame - 14 - 20 = total - 34
	PUSH	BC
	LD	A,C
	SUB	34
	LD	C,A
	LD	A,B
	SBC	A,0
	LD	B,A			; BC = UDP length
	; Patch UDP length at offset 14+20+4..+5
	PUSH	HL
	LD	DE,DHCP_UDP_OFF + 4
	ADD	HL,DE
	LD	(HL),B
	INC	HL
	LD	(HL),C
	POP	HL
	POP	BC			; restore total length
	; IP total length = total - 14
	PUSH	BC
	LD	A,C
	SUB	14
	LD	E,A
	LD	A,B
	SBC	A,0
	LD	D,A			; DE = IP total length (BE host order)
	PUSH	HL
	LD	BC,DHCP_IP_OFF + 2
	ADD	HL,BC
	LD	(HL),D
	INC	HL
	LD	(HL),E
	POP	HL
	; IP checksum: sum 16-bit words of header, store complement.
	PUSH	HL
	LD	BC,DHCP_IP_OFF
	ADD	HL,BC
	PUSH	HL
	POP	IX			; IX = IPv4 header start
	LD	BC,DHCP_IP_LEN
	CALL	@UTIL.CHECKSUM		; HL = ~sum (BE: H high, L low)
	POP	DE			; DE = TX_BUF base
	; Write checksum at IP+10.
	PUSH	HL
	LD	HL,DHCP_IP_OFF + 10
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	LD	A,H
	LD	(DE),A
	INC	DE
	LD	A,L
	LD	(DE),A
	POP	BC			; total frame length
	; Pad to 60 if shorter (Ethernet min frame).
	LD	A,B
	OR	A
	JR	NZ,.NO_PAD
	LD	A,C
	CP	60
	JR	NC,.NO_PAD
	; not expected for DHCP frames (~292 bytes); stub left for safety
.NO_PAD
	POP	DE
	RET


; ------------------------------------------------------
; PARSE_REPLY: validate reply at HL (Ethernet start) is a
; DHCP reply for our XID.  On success populates fields and
; sets MSG_TYPE; CF=0.  On rejection CF=1, fields untouched.
;   In:  HL = RX_BUF (Ethernet frame).
;        DE = total frame length (currently unused).
;   Out: CF=0 valid + fields populated.
;   Trashes A, BC, DE, HL, IX.
; ------------------------------------------------------
PARSE_REPLY
	; EtherType IPv4?
	LD	BC,12
	ADD	HL,BC
	LD	A,(HL)
	CP	HIGH ETH_TYPE_IPV4
	JP	NZ,.NO
	INC	HL
	LD	A,(HL)
	CP	LOW ETH_TYPE_IPV4
	JP	NZ,.NO
	INC	HL			; HL -> IP header

	; IP version+IHL must be 0x45 (we don't handle options).
	LD	A,(HL)
	CP	0x45
	JP	NZ,.NO
	; Check protocol = UDP at offset 9.
	PUSH	HL
	LD	BC,9
	ADD	HL,BC
	LD	A,(HL)
	POP	HL
	CP	IP_PROTO_UDP
	JP	NZ,.NO
	; Skip IP header to UDP.
	PUSH	HL
	LD	BC,DHCP_IP_LEN
	ADD	HL,BC			; HL -> UDP
	; Check UDP src = 67 (server), dst = 68 (client).
	LD	A,(HL)
	CP	HIGH DHCP_SERVER_PORT
	JP	NZ,.NO_POP
	INC	HL
	LD	A,(HL)
	CP	LOW DHCP_SERVER_PORT
	JP	NZ,.NO_POP
	INC	HL
	LD	A,(HL)
	CP	HIGH DHCP_CLIENT_PORT
	JP	NZ,.NO_POP
	INC	HL
	LD	A,(HL)
	CP	LOW DHCP_CLIENT_PORT
	JP	NZ,.NO_POP
	; Skip rest of UDP header (4 more bytes: length + checksum).
	LD	BC,5
	ADD	HL,BC			; HL -> BOOTP

	; BOOTP op = 2 (BOOTREPLY)?
	LD	A,(HL)
	CP	DHCP_OP_REPLY
	JP	NZ,.NO_POP

	; Compare xid (offset 4..7) to DHCP.XID.
	PUSH	HL
	LD	BC,4
	ADD	HL,BC			; HL -> xid
	LD	DE,XID
	LD	B,4
.CMP_XID
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.NO_POP2
	INC	HL
	INC	DE
	DJNZ	.CMP_XID
	POP	HL			; HL -> BOOTP base

	; Capture yiaddr (offset 16..19).
	PUSH	HL
	LD	BC,16
	ADD	HL,BC
	LD	DE,OFFERED_IP
	LD	BC,4
	LDIR
	POP	HL

	; Walk options starting at offset 240 (after magic cookie at 236..239).
	PUSH	HL
	LD	BC,DHCP_BOOTP_HDR_LEN	; 236
	ADD	HL,BC
	; Verify magic cookie.
	LD	A,(HL)
	CP	DHCP_MAGIC_0
	JR	NZ,.NO_POP3
	INC	HL
	LD	A,(HL)
	CP	DHCP_MAGIC_1
	JR	NZ,.NO_POP3
	INC	HL
	LD	A,(HL)
	CP	DHCP_MAGIC_2
	JR	NZ,.NO_POP3
	INC	HL
	LD	A,(HL)
	CP	DHCP_MAGIC_3
	JR	NZ,.NO_POP3
	INC	HL			; HL -> first option byte

	CALL	WALK_OPTS

	POP	BC			; clear pushed BOOTP base
	POP	BC			; clear pushed earlier IP base
	OR	A			; CF=0
	RET

.NO_POP3
	POP	BC			; drop BOOTP base (options walk)
	JR	.NO_POP			; then drop IP header
.NO_POP2
	POP	BC			; drop BOOTP base (xid compare)
.NO_POP
	POP	BC			; drop IP header
.NO
	SCF
	RET


; ------------------------------------------------------
; WALK_OPTS: parse BOOTP options at HL until 0xFF (END).
; Updates DHCP fields based on option codes we recognise.
; Stops at OPT_END or after 320 bytes (sanity cap).
; Trashes A, BC, DE.
; ------------------------------------------------------
WALK_OPTS
	LD	BC,320
.LP
	LD	A,B
	OR	C
	RET	Z
	LD	A,(HL)
	CP	OPT_END
	RET	Z
	CP	OPT_PAD
	JR	Z,.PAD
	; Generic TLV: opcode, length, data.
	LD	A,(HL)
	INC	HL
	LD	D,(HL)			; D = length
	INC	HL
	; Dispatch on opcode (in A).
	CP	OPT_MSG_TYPE
	JR	Z,.MSG_TYPE
	CP	OPT_MASK
	JR	Z,.MASK
	CP	OPT_ROUTER
	JR	Z,.ROUTER
	CP	OPT_DNS
	JR	Z,.DNS
	CP	OPT_LEASE_TIME
	JR	Z,.LEASE
	CP	OPT_SERVER_ID
	JR	Z,.SERVER
	; Unknown: skip data bytes.
	JR	.SKIP
.PAD
	INC	HL
	DEC	BC
	JR	.LP

.MSG_TYPE
	; First byte of data.
	LD	A,(HL)
	LD	(MSG_TYPE),A
	JR	.SKIP
.MASK
	PUSH	BC
	PUSH	DE
	LD	DE,MASK
	LD	BC,4
	LDIR
	POP	DE
	POP	BC
	; HL advanced by 4; rewind so .SKIP can advance by D bytes uniformly.
	LD	A,4
	JR	.SKIP_FROM_LOOP
.ROUTER
	PUSH	BC
	PUSH	DE
	LD	DE,ROUTER
	LD	BC,4
	LDIR
	POP	DE
	POP	BC
	LD	A,4
	JR	.SKIP_FROM_LOOP
.DNS
	; Copy up to 4+4 bytes into DNS1, DNS2.
	PUSH	BC
	PUSH	DE
	LD	DE,DNS1
	LD	BC,4
	LDIR
	POP	DE
	POP	BC
	LD	A,4
	; If length >= 8, copy second DNS too.
	PUSH	AF
	LD	A,D
	CP	8
	JR	C,.DNS_ONE
	PUSH	BC
	PUSH	DE
	LD	DE,DNS2
	LD	BC,4
	LDIR
	POP	DE
	POP	BC
	POP	AF
	LD	A,8
	JR	.SKIP_FROM_LOOP
.DNS_ONE
	POP	AF
	JR	.SKIP_FROM_LOOP
.LEASE
	PUSH	BC
	PUSH	DE
	LD	DE,LEASE_SECS
	LD	BC,4
	LDIR
	POP	DE
	POP	BC
	LD	A,4
	JR	.SKIP_FROM_LOOP
.SERVER
	PUSH	BC
	PUSH	DE
	LD	DE,SERVER_ID
	LD	BC,4
	LDIR
	POP	DE
	POP	BC
	LD	A,4
	JR	.SKIP_FROM_LOOP

; A = bytes consumed by data copy; HL already advanced;
; D = original option length; advance HL by remaining (D - A).
.SKIP_FROM_LOOP
	LD	E,A
	LD	A,D
	SUB	E			; remaining
	JR	Z,.AFTER
	LD	D,0
	LD	E,A
	ADD	HL,DE
	JR	.AFTER

; Default skip path: HL advanced past TLV header; skip D bytes.
.SKIP
	LD	E,D
	LD	D,0
	ADD	HL,DE
.AFTER
	; Account for opcode + length + data bytes in the cap.
	; (Imprecise -- we just decrement BC by 2 + length below.)
	LD	A,C
	SUB	2
	LD	C,A
	LD	A,B
	SBC	A,0
	LD	B,A
	LD	A,B
	OR	C
	JP	NZ,.LP
	RET


	ENDIF				; inner USE_DHCP
	ENDMODULE
	ENDIF				; outer USE_DHCP (constants block)
	ENDIF				; _DHCP_LIB include guard
