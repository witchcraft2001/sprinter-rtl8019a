; ======================================================
; Minimal DNS resolver wire-format helpers (RFC 1035).
;
; Provides only the on-the-wire bits: ASCII -> label
; encoding, query message build, and walking a reply to
; the first A record (IPv4).  Higher-level routing
; (next-hop selection, ARP, UDP/IP framing) belongs in
; the caller, which already has those from previous
; stages.
;
; Public API (DEFINE USE_DNS before INCLUDE):
;
;   DNS.ENCODE_NAME   In:  HL = ASCIIZ name (no leading
;                          dot; trailing dot allowed);
;                          DE = destination buffer.
;                     Out: DE = past the terminator (0).
;                          CF=0 ok; CF=1 invalid (empty
;                          label, label > 63).
;                     Trashes A, BC, HL, IX.
;
;   DNS.BUILD_QUERY   In:  HL = ASCIIZ name; DE = dest;
;                          BC = transaction id (B=hi,
;                          C=lo, host order).
;                     Out: DE = past last byte; CF=0 ok;
;                          CF=1 invalid name.
;                     Writes 12-byte header + encoded
;                     QNAME + 4-byte QTYPE/QCLASS suffix.
;                     Trashes A, BC, HL, IX.
;
;   DNS.PARSE_REPLY   In:  HL = start of DNS message
;                          (right after UDP header);
;                          BC = total DNS message length;
;                          DE = 4-byte dest for A record;
;                          IY = expected XID (push order:
;                          B=hi, C=lo after PUSH IY/POP).
;                     Out: CF=0 found, (DE..DE+3) IPv4;
;                          CF=1 mismatched XID, non-zero
;                          RCODE (e.g. NXDOMAIN), no A
;                          record, or parse error.
;                     Trashes A, BC, HL, DE, IX.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_DNS
	DEFINE	_DNS

	MODULE DNS

	IFDEF USE_DNS

DNS_PORT		EQU 53
DNS_TYPE_A		EQU 1
DNS_CLASS_IN		EQU 1
DNS_HDR_LEN		EQU 12


; ------------------------------------------------------
; ENCODE_NAME: encode "x.example.com" as length-prefixed
; labels followed by a trailing 0 byte.  Trailing dot is
; tolerated; consecutive dots ("a..b") are rejected.
;   In:  HL = ASCIIZ name; DE = dest.
;   Out: DE = first byte past the terminator.
;        CF=0 ok; CF=1 invalid.
; ------------------------------------------------------
ENCODE_NAME
	PUSH	IX
.LBL
	LD	A,(HL)
	OR	A
	JR	Z,.END
	; New label: remember length-byte slot in IX.
	PUSH	DE
	POP	IX
	INC	DE
	LD	B,0
.CHR
	LD	A,(HL)
	OR	A
	JR	Z,.LCLOSE
	CP	'.'
	JR	Z,.LCLOSE
	LD	(DE),A
	INC	DE
	INC	HL
	INC	B
	LD	A,B
	CP	64
	JR	NC,.BAD
	JR	.CHR
.LCLOSE
	LD	A,B
	OR	A
	JR	Z,.BAD			; empty label not allowed
	LD	(IX+0),B
	LD	A,(HL)
	OR	A
	JR	Z,.END
	; A is '.' here; consume separator and start next label.
	INC	HL
	JR	.LBL
.END
	XOR	A
	LD	(DE),A
	INC	DE
	POP	IX
	OR	A
	RET
.BAD
	POP	IX
	SCF
	RET


; ------------------------------------------------------
; BUILD_QUERY: write 12-byte header + QNAME + QTYPE/CLASS.
;   In:  HL = name; DE = dest; BC = XID (B=hi, C=lo).
;   Out: DE = past last byte; CF=0 ok / CF=1 invalid name.
; ------------------------------------------------------
BUILD_QUERY
	; ID (B=hi, C=lo)
	LD	A,B
	LD	(DE),A
	INC	DE
	LD	A,C
	LD	(DE),A
	INC	DE
	; Flags = 0x0100 (RD=1)
	LD	A,0x01
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	; QDCOUNT = 1 (BE)
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	INC	DE
	; ANCOUNT, NSCOUNT, ARCOUNT = 0 (6 bytes)
	PUSH	BC
	LD	B,6
	XOR	A
.HZ
	LD	(DE),A
	INC	DE
	DJNZ	.HZ
	POP	BC
	; QNAME
	CALL	ENCODE_NAME
	RET	C
	; QTYPE = 1 (BE)
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,DNS_TYPE_A
	LD	(DE),A
	INC	DE
	; QCLASS = 1 (BE)
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,DNS_CLASS_IN
	LD	(DE),A
	INC	DE
	OR	A
	RET


; ------------------------------------------------------
; SKIP_NAME: advance HL past a DNS name in (HL).  Handles
; both label sequences and 16-bit pointer compression.
;   In:  HL = name pointer.
;   Out: HL = first byte past the name.
; Preserves BC, DE (caller may carry an answer counter in
; B across the call); trashes A.
; ------------------------------------------------------
SKIP_NAME
	PUSH	BC
.LP
	LD	A,(HL)
	OR	A
	JR	Z,.ZERO
	CP	0xC0
	JR	NC,.PTR
	; Plain label: advance len+1.
	LD	C,A
	LD	B,0
	INC	HL			; past length byte
	ADD	HL,BC
	JR	.LP
.ZERO
	INC	HL
	POP	BC
	RET
.PTR
	INC	HL
	INC	HL
	POP	BC
	RET


; ------------------------------------------------------
; PARSE_REPLY: validate header, locate first A record.
;   In:  HL = DNS message start; BC = msg length;
;        DE = 4-byte dest; IY = expected XID.
;   Out: CF=0 found (IP at DE); CF=1 fail.
; ------------------------------------------------------
PARSE_REPLY
	PUSH	DE			; preserve dest IP

	; Min length 12.
	LD	A,B
	OR	A
	JR	NZ,.LOK
	LD	A,C
	CP	DNS_HDR_LEN
	JR	C,.FAIL

.LOK
	; XID match.  PUSH IY/POP BC: B=hi byte, C=lo byte.
	PUSH	IY
	POP	BC
	LD	A,(HL)
	CP	B
	JR	NZ,.FAIL
	INC	HL
	LD	A,(HL)
	CP	C
	JR	NZ,.FAIL
	INC	HL

	; Flags byte 2: QR must be 1.
	LD	A,(HL)
	AND	0x80
	JR	Z,.FAIL
	INC	HL
	; Flags byte 3: low 4 bits are RCODE; must be 0.
	LD	A,(HL)
	AND	0x0F
	JR	NZ,.FAIL
	INC	HL

	; QDCOUNT (skip 2)
	INC	HL
	INC	HL

	; ANCOUNT (BE).  If both bytes 0, fail.
	LD	A,(HL)
	INC	HL
	OR	(HL)
	JR	Z,.FAIL
	; B = ANCOUNT lo (cap; ignore high byte for sanity)
	LD	A,(HL)
	INC	HL
	OR	A
	JR	NZ,.HAVE_B
	LD	A,255			; ANCOUNT > 255 -> cap
.HAVE_B
	LD	B,A

	; NSCOUNT, ARCOUNT (skip 4)
	INC	HL
	INC	HL
	INC	HL
	INC	HL

	; Skip question: NAME + QTYPE(2) + QCLASS(2)
	CALL	SKIP_NAME
	LD	C,4
.SKQ
	INC	HL
	DEC	C
	JR	NZ,.SKQ

	; Walk answers.
.ANS_LP
	LD	A,B
	OR	A
	JR	Z,.FAIL
	DEC	B

	CALL	SKIP_NAME

	; TYPE (BE)
	LD	A,(HL)
	INC	HL
	LD	C,(HL)
	INC	HL
	OR	A
	JR	NZ,.SKIP_RR		; type hi non-zero -> not A
	LD	A,C
	CP	DNS_TYPE_A
	JR	NZ,.SKIP_RR

	; CLASS (skip 2) + TTL (skip 4)
	INC	HL
	INC	HL
	INC	HL
	INC	HL
	INC	HL
	INC	HL

	; RDLENGTH (BE)
	LD	A,(HL)
	INC	HL
	LD	C,(HL)
	INC	HL
	OR	A
	JR	NZ,.SKIP_DATA		; rdlen hi non-zero -> not 4
	LD	A,C
	CP	4
	JR	NZ,.SKIP_DATA

	; A record!  Copy 4 bytes RDATA -> dest.
	POP	DE			; restore dest
	LD	BC,4
	LDIR
	OR	A			; CF=0
	RET

.SKIP_RR
	; HL is past TYPE.  Skip CLASS(2) + TTL(4) = 6 bytes.
	LD	C,6
.SR1
	INC	HL
	DEC	C
	JR	NZ,.SR1
	; RDLENGTH (BE)
	LD	A,(HL)
	INC	HL
	LD	C,(HL)
	INC	HL
.SKIP_DATA
	; Advance HL by (A,C) bytes.
	LD	D,A
	LD	E,C
	ADD	HL,DE
	JR	.ANS_LP

.FAIL
	POP	DE
	SCF
	RET


	ENDIF

	ENDMODULE
	ENDIF
