; ======================================================
; tcp_lib.asm -- minimal one-session TCP/IPv4 client.
;
; Scope (stage 1, this file):
;   * TCP.OPEN  -- send SYN, wait SYN+ACK, send ACK, set
;                  state to ESTABLISHED.
;   * TCP.SEND  -- TODO (stage 2)
;   * TCP.RECV  -- TODO (stage 2)
;   * TCP.CLOSE -- TODO (stage 3)
;
; Design choices:
;   - one session.
;   - MSS 536 announced; advertised window 1024.
;   - sequence numbers stored big-endian on disk to match
;     the wire format; arithmetic is done by reading bytes
;     manually (no native 32-bit ops on Z80).
;   - no retransmit timer; per-call overall timeout in ms.
;   - caller ARPs the next hop and writes the MAC into
;     TCP_REMOTE_MAC before TCP.OPEN.
;
; Public API (DEFINE USE_TCP before INCLUDE):
;
;   TCP.OPEN     In:  TCP_REMOTE_IP, TCP_REMOTE_MAC,
;                     TCP_REMOTE_PORT_HI/LO already set.
;                Out: CF=0 ESTAB; CF=1 fail.
;                     TCP_LAST_FAIL holds reason.
;
;   TCP.LAST_FAIL  byte; 0 none, 1 send, 2 recv timeout,
;                  3 RST, 4 unexpected segment, 5 cancel.
;
; Caller responsibilities:
;   - NIC initialised, OUR_IP/OUR_MAC populated.
;   - @MAIN.TICK_AND_CHECK_KEY exists; MAIN.CANCELLED
;     reflects key-cancel state.
;   - @MAIN.TX_BUF region >= TCP_MAX_FRAME bytes.
;   - @MAIN.RX_BUF / @MAIN.RX_HDR available.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_TCP
	DEFINE	_TCP

	IFDEF USE_TCP
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

	MODULE TCP

	IFDEF USE_TCP

OPEN_TIMEOUT_MS		EQU 5000

; Receive window advertised in every outgoing SYN/ACK/DATA segment.
; 8 KB lets the peer pipeline ~14 MSS=536 segments before needing
; an ACK; the chip's ~14.5 KB RX ring tolerates that burst with
; headroom.  Going much higher risks RX-ring overflow on slow drains.
TCP_RECV_WIN_HI		EQU 0x20		; 8192 = 0x2000
TCP_RECV_WIN_LO		EQU 0x00

; Delayed-ACK threshold (RFC 1122 allows up to 2 segments unacked).
; We are slightly more aggressive (4) because the chip RX ring is
; large and the link is local; we still flush an ACK immediately
; whenever the ring drains, so the peer never waits for long.
TCP_ACK_THRESH		EQU 4

ETH_TYPE_IPV4		EQU 0x0800
IP_HDR_LEN		EQU 20
IP_PROTO_TCP		EQU 6

; State values
ST_CLOSED		EQU 0
ST_SYN_SENT		EQU 1
ST_ESTAB		EQU 2
ST_CLOSE_WAIT		EQU 3
ST_LAST_ACK		EQU 4

; TCP flags
TF_FIN			EQU 0x01
TF_SYN			EQU 0x02
TF_RST			EQU 0x04
TF_PSH			EQU 0x08
TF_ACK			EQU 0x10

; LAST_FAIL codes
F_NONE			EQU 0
F_SEND			EQU 1
F_TIMEOUT		EQU 2
F_RST			EQU 3
F_BAD_SEG		EQU 4
F_CANCEL		EQU 5


; ------------------------------------------------------
; SAVE_CTX: copy the entire single-session TCP state into
; a 38-byte caller-supplied buffer.  Combined with
; RESTORE_CTX this lets apps swap between multiple logical
; sessions (e.g. FTP control + data) without paying for a
; full multi-session lib refactor.
;   In:  DE = destination buffer (>= TCP_CTX_SIZE bytes).
;   Out: DE advanced past the saved state.
; ------------------------------------------------------
SAVE_CTX
	LD	HL,TCP_STATE
	LD	BC,TCP_CTX_SIZE
	LDIR
	RET


; ------------------------------------------------------
; RESTORE_CTX: opposite of SAVE_CTX -- write the buffer
; back into the live TCP state.
;   In:  HL = source buffer.
; ------------------------------------------------------
RESTORE_CTX
	LD	DE,TCP_STATE
	LD	BC,TCP_CTX_SIZE
	LDIR
	RET


; ------------------------------------------------------
; OPEN: 3-way handshake.
; ------------------------------------------------------
OPEN
	XOR	A
	LD	(TCP_LAST_FAIL),A
	LD	(RECV_UNACKED),A
	; Pick random local port in the ephemeral range
	; 0xC000..0xFFFF.  Each invocation gets a fresh port so
	; back-to-back runs don't collide on the server side.
	LD	A,R
	LD	(TCP_LOCAL_PORT_LO),A
	LD	HL,0
	ADD	HL,SP
	LD	A,L
	OR	0xC0
	LD	(TCP_LOCAL_PORT_HI),A
	; Generate ISN from R + SP -- 4 mostly-pseudo-random bytes.
	LD	A,R
	LD	(TCP_SND_NXT + 0),A
	LD	HL,0
	ADD	HL,SP
	LD	A,H
	LD	(TCP_SND_NXT + 1),A
	LD	A,L
	LD	(TCP_SND_NXT + 2),A
	LD	A,R
	LD	(TCP_SND_NXT + 3),A
	; Mirror to SND_UNA.
	LD	HL,TCP_SND_NXT
	LD	DE,TCP_SND_UNA
	LD	BC,4
	LDIR
	; RCV_NXT will be set after SYN+ACK arrives; zero for now.
	XOR	A
	LD	HL,TCP_RCV_NXT
	LD	(HL),A
	INC	HL
	LD	(HL),A
	INC	HL
	LD	(HL),A
	INC	HL
	LD	(HL),A
	; State = SYN_SENT (we are about to send).
	LD	A,ST_SYN_SENT
	LD	(TCP_STATE),A

	; Build SYN frame (24-byte TCP header with MSS option).
	CALL	BUILD_SYN
	LD	HL,@MAIN.TX_BUF
	LD	BC,(TCP_TX_LEN)
	CALL	@RTL.SEND_FRAME
	JR	NC,.SENT
	LD	A,F_SEND
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.SENT

	; Wait for SYN+ACK matching our (remote_ip, remote_port,
	; local_port) tuple.
	LD	HL,OPEN_TIMEOUT_MS
	LD	(TCP_TIMEOUT_LEFT),HL
	CALL	WAIT_SYN_ACK
	RET	C

	; Validate that segment ACK matches ISN+1.
	; (BUILD_SYN sent SYN with seq=ISN; SYN+ACK should ACK ISN+1.)
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + 8	; ack number BE
	LD	DE,TCP_SND_NXT
	; Increment SND_NXT by 1 (SYN consumes 1 seq).
	CALL	INC_SEQ32
	LD	DE,TCP_SND_UNA
	CALL	INC_SEQ32
	; Compare segment ACK vs SND_NXT (== ISN+1).
	LD	DE,TCP_SND_NXT
	LD	B,4
.CMPACK
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.BAD
	INC	DE
	INC	HL
	DJNZ	.CMPACK
	; Capture peer ISN -> RCV_NXT, then +1 (SYN).
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + 4	; seq BE
	LD	DE,TCP_RCV_NXT
	LD	BC,4
	LDIR
	LD	DE,TCP_RCV_NXT
	CALL	INC_SEQ32

	; Build & send pure ACK to complete the handshake.
	CALL	BUILD_ACK
	LD	HL,@MAIN.TX_BUF
	LD	BC,(TCP_TX_LEN)
	CALL	@RTL.SEND_FRAME
	JR	NC,.ACK_OK
	LD	A,F_SEND
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.ACK_OK
	LD	A,ST_ESTAB
	LD	(TCP_STATE),A
	OR	A
	RET
.BAD
	LD	A,F_BAD_SEG
	LD	(TCP_LAST_FAIL),A
	SCF
	RET


; ------------------------------------------------------
; INC_SEQ32: 32-bit big-endian increment at (DE).
;   DE = pointer to 4 BE bytes; on return, value+=1.
; Trashes A, B; preserves DE, HL.
; ------------------------------------------------------
INC_SEQ32
	PUSH	HL
	PUSH	DE
	; Move DE to byte 3 (least significant).
	INC	DE
	INC	DE
	INC	DE
	LD	B,4
.LP
	LD	A,(DE)
	INC	A
	LD	(DE),A
	JR	NZ,.DONE
	DEC	DE
	DJNZ	.LP
.DONE
	POP	DE
	POP	HL
	RET


; ------------------------------------------------------
; BUILD_SYN: build SYN segment with MSS option in TX_BUF.
; Sets TCP_TX_LEN to total Ethernet frame length.
; ------------------------------------------------------
BUILD_SYN
	; TCP header = 24 bytes (20 + 4-byte MSS option).
	; TCP segment length = 24, IP total = 44, frame = 58.
	LD	HL,24
	LD	(.TCP_LEN),HL
	; Fill Ethernet + IP.
	LD	BC,24			; TCP segment length
	CALL	BUILD_ETH_IP
	; --- TCP header ---
	; DE points just past IP header (= TX_BUF + 14 + 20).
	; src port
	LD	A,(TCP_LOCAL_PORT_HI)
	LD	(DE),A
	INC	DE
	LD	A,(TCP_LOCAL_PORT_LO)
	LD	(DE),A
	INC	DE
	; dst port
	LD	A,(TCP_REMOTE_PORT_HI)
	LD	(DE),A
	INC	DE
	LD	A,(TCP_REMOTE_PORT_LO)
	LD	(DE),A
	INC	DE
	; seq (BE)
	LD	HL,TCP_SND_NXT
	LD	BC,4
	LDIR
	; ack = 0 (not yet acking anything)
	XOR	A
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	; data offset (6 << 4 = 0x60), reserved = 0
	LD	A,0x60
	LD	(DE),A
	INC	DE
	; flags = SYN
	LD	A,TF_SYN
	LD	(DE),A
	INC	DE
	; advertised window (BE) -- see TCP_RECV_WIN_HI/LO at top.
	LD	A,TCP_RECV_WIN_HI
	LD	(DE),A
	INC	DE
	LD	A,TCP_RECV_WIN_LO
	LD	(DE),A
	INC	DE
	; checksum placeholder (0)
	XOR	A
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	; urgent = 0
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	; MSS option: kind=2, len=4, value=536 (0x0218)
	LD	A,2
	LD	(DE),A
	INC	DE
	LD	A,4
	LD	(DE),A
	INC	DE
	LD	A,0x02
	LD	(DE),A
	INC	DE
	LD	A,0x18
	LD	(DE),A
	INC	DE
	; Compute IP checksum.
	CALL	WRITE_IP_CSUM
	; Compute TCP checksum (with pseudo-header).
	CALL	WRITE_TCP_CSUM
	; Total Ethernet frame length = 14 + 20 + 24 = 58.
	LD	HL,58
	LD	(TCP_TX_LEN),HL
	RET
.TCP_LEN	DW 0


; ------------------------------------------------------
; BUILD_ACK: build pure ACK (20-byte TCP, no payload).
; Sets TCP_TX_LEN.
; ------------------------------------------------------
BUILD_ACK
	; TCP segment length = 20.
	LD	BC,20
	CALL	BUILD_ETH_IP
	; --- TCP header ---
	LD	A,(TCP_LOCAL_PORT_HI)
	LD	(DE),A
	INC	DE
	LD	A,(TCP_LOCAL_PORT_LO)
	LD	(DE),A
	INC	DE
	LD	A,(TCP_REMOTE_PORT_HI)
	LD	(DE),A
	INC	DE
	LD	A,(TCP_REMOTE_PORT_LO)
	LD	(DE),A
	INC	DE
	; seq
	LD	HL,TCP_SND_NXT
	LD	BC,4
	LDIR
	; ack
	LD	HL,TCP_RCV_NXT
	LD	BC,4
	LDIR
	; data offset = 5 << 4 = 0x50
	LD	A,0x50
	LD	(DE),A
	INC	DE
	; flags = ACK
	LD	A,TF_ACK
	LD	(DE),A
	INC	DE
	; advertised window (BE)
	LD	A,TCP_RECV_WIN_HI
	LD	(DE),A
	INC	DE
	LD	A,TCP_RECV_WIN_LO
	LD	(DE),A
	INC	DE
	; csum placeholder
	XOR	A
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	; urgent
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	; checksums
	CALL	WRITE_IP_CSUM
	CALL	WRITE_TCP_CSUM
	; Frame length = 14 + 20 + 20 = 54.
	LD	HL,54
	LD	(TCP_TX_LEN),HL
	RET


; ------------------------------------------------------
; BUILD_ETH_IP: write 14-byte Ethernet + 20-byte IPv4
; header into TX_BUF.  IP checksum left as 0; caller fills
; afterwards via WRITE_IP_CSUM.
;   In:  BC = TCP segment length (header + data).
;   Out: DE = TX_BUF + 14 + IP_HDR_LEN (TCP start).
;        TCP_TX_LEN_BE_TMP holds TCP segment length for
;        pseudo-header use (see WRITE_TCP_CSUM).
; ------------------------------------------------------
BUILD_ETH_IP
	LD	(.TCP_SEG_LEN),BC
	; Ethernet: dst MAC, src MAC, type.
	LD	DE,@MAIN.TX_BUF
	LD	HL,TCP_REMOTE_MAC
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
	; IP total length = IP_HDR_LEN + TCP_SEG_LEN (BE).
	LD	HL,(.TCP_SEG_LEN)
	LD	BC,IP_HDR_LEN
	ADD	HL,BC
	LD	A,H
	LD	(DE),A			; total len hi
	INC	DE
	LD	A,L
	LD	(DE),A			; total len lo
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
	LD	A,IP_PROTO_TCP
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A			; csum hi placeholder
	INC	DE
	LD	(DE),A			; csum lo placeholder
	INC	DE
	LD	HL,@MAIN.OUR_IP
	LD	BC,4
	LDIR
	LD	HL,TCP_REMOTE_IP
	LD	BC,4
	LDIR
	; DE now points at TCP header start.
	RET
.TCP_SEG_LEN	DW 0


; ------------------------------------------------------
; WRITE_IP_CSUM: compute IP header checksum and place
; into TX_BUF + 14 + 10..11.
; ------------------------------------------------------
WRITE_IP_CSUM
	PUSH	IX
	LD	IX,@MAIN.TX_BUF + 14
	LD	BC,IP_HDR_LEN
	CALL	@UTIL.CHECKSUM
	POP	IX
	LD	A,H
	LD	(@MAIN.TX_BUF + 14 + 10),A
	LD	A,L
	LD	(@MAIN.TX_BUF + 14 + 11),A
	RET


; ------------------------------------------------------
; WRITE_TCP_CSUM: compute TCP checksum (with pseudo-header)
; and place it into TX_BUF + 14 + IP_HDR_LEN + 16..17.
; ------------------------------------------------------
WRITE_TCP_CSUM
	; Sum pseudo-header + TCP segment.
	LD	HL,0
	; +OUR_IP[0..3]
	LD	DE,@MAIN.OUR_IP
	LD	BC,4
	CALL	CSUM_ACCUM_BE
	; +REMOTE_IP[0..1], [2..3]
	LD	DE,TCP_REMOTE_IP
	LD	BC,4
	CALL	CSUM_ACCUM_BE
	; +0x0006 (zero byte + protocol)
	LD	BC,0x0006
	ADD	HL,BC
	JR	NC,.PROTO_OK
	INC	HL
.PROTO_OK
	; +TCP segment length (numeric value, real length).
	LD	BC,(BUILD_ETH_IP.TCP_SEG_LEN)
	ADD	HL,BC
	JR	NC,.LEN_OK
	INC	HL
.LEN_OK
	; Sum TCP segment bytes; round up odd length with a
	; virtual 0 byte (we write the pad byte to the next
	; position past the segment in TX_BUF -- safe because
	; TCP_MAX_FRAME leaves room).
	LD	DE,@MAIN.TX_BUF + 14 + IP_HDR_LEN
	LD	BC,(BUILD_ETH_IP.TCP_SEG_LEN)
	LD	A,C
	AND	1
	JR	Z,.EVEN
	; Write 0 at TX_BUF + 14 + 20 + seg_len to make the
	; partial word read as (last_byte << 8) | 0.
	PUSH	DE
	PUSH	BC
	PUSH	HL
	LD	HL,@MAIN.TX_BUF + 14 + IP_HDR_LEN
	ADD	HL,BC
	XOR	A
	LD	(HL),A
	POP	HL
	POP	BC
	POP	DE
	INC	BC
.EVEN
	CALL	CSUM_ACCUM_BE
	; 1's complement.
	LD	A,H
	CPL
	LD	H,A
	LD	A,L
	CPL
	LD	L,A
	; Write to TCP[16..17].
	LD	A,H
	LD	(@MAIN.TX_BUF + 14 + IP_HDR_LEN + 16),A
	LD	A,L
	LD	(@MAIN.TX_BUF + 14 + IP_HDR_LEN + 17),A
	RET


; ------------------------------------------------------
; CSUM_ACCUM_BE: add BC bytes (must be even) at (DE) into
; HL as a running 16-bit BE one's-complement sum.
;   In:  HL = current sum, DE = ptr, BC = byte count (even).
;   Out: HL = updated sum, DE = past last byte.
;        Trashes A, BC.
; ------------------------------------------------------
CSUM_ACCUM_BE
.LP
	LD	A,B
	OR	C
	RET	Z
	PUSH	BC
	LD	A,(DE)
	INC	DE
	LD	B,A
	LD	A,(DE)
	INC	DE
	LD	C,A
	; BC = BE 16-bit word (B=hi, C=lo).
	ADD	HL,BC
	POP	BC
	JR	NC,.NOC
	INC	HL
.NOC
	DEC	BC
	DEC	BC
	JR	.LP


; ------------------------------------------------------
; WAIT_SYN_ACK: poll RX ring for a TCP segment from the
; remote peer with SYN+ACK flags, matching our (local_port,
; remote_ip, remote_port).
;   Out: CF=0 ok (segment in MAIN.RX_BUF);
;        CF=1 timeout/cancel/RST.
; ------------------------------------------------------
WAIT_SYN_ACK
.LP
	CALL	@RTL.RING_HAS_PACKET
	JR	NZ,.HAVE
	CALL	@MAIN.TICK_AND_CHECK_KEY
	JP	C,.CANCEL
	LD	HL,(TCP_TIMEOUT_LEFT)
	DEC	HL
	LD	(TCP_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JP	NZ,.LP
	LD	A,F_TIMEOUT
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.HAVE
	LD	HL,@MAIN.RX_HDR
	LD	DE,@MAIN.RX_BUF
	LD	BC,1518
	CALL	@RTL.READ_PACKET
	JP	C,.LP
	; Validate IPv4 + TCP from remote.
	CALL	IS_TCP_FROM_PEER
	JP	NC,.LP
	; Check flags = SYN | ACK.
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 13)
	AND	(TF_RST | TF_SYN | TF_ACK)
	CP	(TF_SYN | TF_ACK)
	JR	Z,.OK
	; RST -> immediate fail.
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 13)
	AND	TF_RST
	JR	NZ,.RST
	JP	.LP
.OK
	OR	A
	RET
.RST
	LD	A,F_RST
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.CANCEL
	LD	A,F_CANCEL
	LD	(TCP_LAST_FAIL),A
	SCF
	RET


; ------------------------------------------------------
; IS_TCP_FROM_PEER: filter RX_BUF for IPv4/TCP from
; (TCP_REMOTE_IP, TCP_REMOTE_PORT) to TCP_LOCAL_PORT.
;   Out: CF=1 if match; CF=0 otherwise.
;        Returns from caller's caller's perspective: NC = no.
; ------------------------------------------------------
IS_TCP_FROM_PEER
	; EtherType IPv4
	LD	A,(@MAIN.RX_BUF + 12)
	CP	HIGH ETH_TYPE_IPV4
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 13)
	CP	LOW ETH_TYPE_IPV4
	JR	NZ,.NO
	; IP V+IHL = 0x45
	LD	A,(@MAIN.RX_BUF + 14)
	CP	0x45
	JR	NZ,.NO
	; protocol = TCP
	LD	A,(@MAIN.RX_BUF + 14 + 9)
	CP	IP_PROTO_TCP
	JR	NZ,.NO
	; src IP == TCP_REMOTE_IP
	LD	HL,@MAIN.RX_BUF + 14 + 12
	LD	DE,TCP_REMOTE_IP
	LD	B,4
.CMPSRC
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.NO
	INC	HL
	INC	DE
	DJNZ	.CMPSRC
	; TCP src port == TCP_REMOTE_PORT
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 0)
	LD	HL,TCP_REMOTE_PORT_HI
	CP	(HL)
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 1)
	INC	HL
	CP	(HL)
	JR	NZ,.NO
	; TCP dst port == TCP_LOCAL_PORT
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 2)
	LD	HL,TCP_LOCAL_PORT_HI
	CP	(HL)
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 3)
	INC	HL
	CP	(HL)
	JR	NZ,.NO
	SCF
	RET
.NO
	OR	A
	RET


; ------------------------------------------------------
; ADD32_BE_BC: 32-bit big-endian value at (DE) += BC.
; Trashes A; preserves DE, HL.
; ------------------------------------------------------
ADD32_BE_BC
	PUSH	DE
	PUSH	BC
	INC	DE
	INC	DE
	INC	DE
	LD	A,(DE)
	ADD	A,C
	LD	(DE),A
	DEC	DE
	LD	A,(DE)
	ADC	A,B
	LD	(DE),A
	DEC	DE
	LD	A,(DE)
	ADC	A,0
	LD	(DE),A
	DEC	DE
	LD	A,(DE)
	ADC	A,0
	LD	(DE),A
	POP	BC
	POP	DE
	RET


; ------------------------------------------------------
; SEND: send caller's data as one PSH+ACK segment.  No
; ACK-wait at this layer; the next RECV/CLOSE will pick
; up the ACK and update SND_UNA.
;   In:  HL = data ptr, BC = length (1..MSS=536).
;   Out: CF=0 ok; CF=1 fail.
; ------------------------------------------------------
SEND
	LD	(.SAVE_LEN),BC
	LD	(.SAVE_DATA),HL
	; Build the segment.
	CALL	BUILD_DATA
	LD	HL,@MAIN.TX_BUF
	LD	BC,(TCP_TX_LEN)
	CALL	@RTL.SEND_FRAME
	JR	NC,.OK
	LD	A,F_SEND
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.OK
	; Advance SND_NXT by data length.
	LD	BC,(.SAVE_LEN)
	LD	DE,TCP_SND_NXT
	CALL	ADD32_BE_BC
	OR	A
	RET
.SAVE_LEN	DW 0
.SAVE_DATA	DW 0


; ------------------------------------------------------
; RECV: poll until peer sends a segment with payload, FIN,
; or RST; meanwhile silently process pure-ACK / out-of-
; order segments.
;   Out: HL = data ptr (in MAIN.RX_BUF), BC = length;
;        CF=0 ok with payload (length >= 1).
;        CF=1 + state == ST_CLOSE_WAIT: peer FIN seen, no
;        more data.  TCP_RX_DATA_LEN may still be > 0 if
;        the FIN segment carried trailing data (caller must
;        process that data here, then call CLOSE).
;        CF=1 + LAST_FAIL set: error / timeout / RST.
; ------------------------------------------------------
RECV
	LD	HL,30000		; 30 s overall recv budget
	LD	(TCP_TIMEOUT_LEFT),HL
.LP
	CALL	@RTL.RING_HAS_PACKET
	JR	NZ,.HAVE
	CALL	@MAIN.TICK_AND_CHECK_KEY
	JP	C,.CANCEL
	LD	HL,(TCP_TIMEOUT_LEFT)
	DEC	HL
	LD	(TCP_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JP	NZ,.LP
	LD	A,F_TIMEOUT
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.HAVE
	LD	HL,@MAIN.RX_HDR
	LD	DE,@MAIN.RX_BUF
	LD	BC,1518
	CALL	@RTL.READ_PACKET
	JP	C,.LP
	CALL	IS_TCP_FROM_PEER
	JP	NC,.LP
	; Flags.
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 13)
	LD	(.FLAGS),A
	; RST -> immediate fail.
	AND	TF_RST
	JR	Z,.NO_RST
	LD	A,F_RST
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.NO_RST
	; Validate seq == RCV_NXT.  If not, silently drop and
	; loop (out-of-order or duplicate; ACK will retransmit).
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + 4	; seq BE
	LD	DE,TCP_RCV_NXT
	LD	B,4
.CMPSEQ
	LD	A,(DE)
	CP	(HL)
	JP	NZ,.LP
	INC	DE
	INC	HL
	DJNZ	.CMPSEQ
	; If has ACK, copy ack number into SND_UNA.
	LD	A,(.FLAGS)
	AND	TF_ACK
	JR	Z,.NO_ACK
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + 8	; ack BE
	LD	DE,TCP_SND_UNA
	LD	BC,4
	LDIR
.NO_ACK
	; Compute data offset and data length.
	; data_offset_bytes = (TCP[12] >> 4) * 4
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 12)
	AND	0xF0
	RRCA
	RRCA				; A = data_offset * 4
	LD	(.DATA_OFFSET),A
	; ip_total_len = RX_BUF[14+2..14+3] BE
	LD	A,(@MAIN.RX_BUF + 14 + 2)
	LD	H,A
	LD	A,(@MAIN.RX_BUF + 14 + 3)
	LD	L,A			; HL = IP total length
	LD	BC,IP_HDR_LEN
	OR	A
	SBC	HL,BC			; HL = TCP segment length (header + data)
	LD	A,(.DATA_OFFSET)
	LD	C,A
	LD	B,0
	OR	A
	SBC	HL,BC			; HL = data length
	LD	(TCP_RX_DATA_LEN),HL
	; data ptr = RX_BUF + 14 + 20 + data_offset
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN
	LD	A,(.DATA_OFFSET)
	LD	C,A
	LD	B,0
	ADD	HL,BC
	LD	(TCP_RX_DATA_PTR),HL
	; Advance RCV_NXT by data length.
	LD	BC,(TCP_RX_DATA_LEN)
	LD	DE,TCP_RCV_NXT
	CALL	ADD32_BE_BC
	; If FIN set, advance RCV_NXT by 1 and mark CLOSE_WAIT.
	LD	A,(.FLAGS)
	AND	TF_FIN
	JR	Z,.NO_FIN
	LD	DE,TCP_RCV_NXT
	CALL	INC_SEQ32
	LD	A,ST_CLOSE_WAIT
	LD	(TCP_STATE),A
.NO_FIN
	; Decide whether to ACK this segment now.  Force ACK on FIN
	; (state == CLOSE_WAIT here).  Otherwise apply delayed-ACK:
	; bump the unacked counter and skip the ACK so long as more
	; packets remain in the chip's RX ring AND the counter is
	; still below TCP_ACK_THRESH.  Drain-or-threshold flushes
	; the cumulative ACK -- the peer's send window then advances.
	LD	A,(TCP_STATE)
	CP	ST_CLOSE_WAIT
	JR	Z,.SEND_ACK
	LD	A,(RECV_UNACKED)
	INC	A
	LD	(RECV_UNACKED),A
	CP	TCP_ACK_THRESH
	JR	NC,.SEND_ACK
	CALL	@RTL.RING_HAS_PACKET
	JR	Z,.SEND_ACK		; ring empty -> flush ACK now
	; Skip ACK on this packet; keep counter for next iteration.
	JR	.AOK
.SEND_ACK
	XOR	A
	LD	(RECV_UNACKED),A
	CALL	BUILD_ACK
	LD	HL,@MAIN.TX_BUF
	LD	BC,(TCP_TX_LEN)
	CALL	@RTL.SEND_FRAME
	JR	NC,.AOK
	LD	A,F_SEND
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.AOK
	; Decide return.
	;   FIN-with-or-without-data -> CF=1 (caller drains
	;   TCP_RX_DATA_LEN bytes once and exits the loop).
	;   data only                 -> CF=0 (caller processes,
	;   then re-enters RECV for more).
	;   pure ACK (no data, no FIN) -> keep waiting silently.
	LD	A,(TCP_STATE)
	CP	ST_CLOSE_WAIT
	JR	Z,.PEER_FIN
	LD	HL,(TCP_RX_DATA_LEN)
	LD	A,H
	OR	L
	JP	Z,.LP			; pure ACK -- back to wait
	LD	HL,(TCP_RX_DATA_PTR)
	LD	BC,(TCP_RX_DATA_LEN)
	OR	A
	RET
.PEER_FIN
	SCF
	RET
.CANCEL
	LD	A,F_CANCEL
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.FLAGS		DB 0
.DATA_OFFSET	DB 0

; Counter of segments processed since the last outbound ACK.  Reset
; on TCP.OPEN and on every actual ACK send; bumped on every accepted
; (in-sequence) data segment.  See TCP_ACK_THRESH for the cap.
RECV_UNACKED	DB 0


; ------------------------------------------------------
; CLOSE: tear down the connection.
;   In:  TCP_STATE must be ESTAB or CLOSE_WAIT.
;   Out: CF=0 cleanly closed; CF=1 on send/timeout error.
; ------------------------------------------------------
CLOSE
	LD	A,(TCP_STATE)
	CP	ST_CLOSED
	JR	NZ,.NEED_CLOSE
	OR	A			; already closed
	RET
.NEED_CLOSE
	; Send FIN+ACK.
	CALL	BUILD_FIN
	LD	HL,@MAIN.TX_BUF
	LD	BC,(TCP_TX_LEN)
	CALL	@RTL.SEND_FRAME
	JR	NC,.FIN_OK
	LD	A,F_SEND
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.FIN_OK
	; Our FIN consumes 1 sequence number.
	LD	DE,TCP_SND_NXT
	CALL	INC_SEQ32
	LD	A,ST_LAST_ACK
	LD	(TCP_STATE),A
	; Wait briefly for the peer's ACK or FIN+ACK and the
	; final state transition.  We don't strictly need it
	; (kernel will RST our FIN if late), but draining the
	; buffer is polite.
	LD	HL,3000
	LD	(TCP_TIMEOUT_LEFT),HL
.WAITLP
	CALL	@RTL.RING_HAS_PACKET
	JR	NZ,.WHAVE
	CALL	@MAIN.TICK_AND_CHECK_KEY
	JR	C,.CDONE
	LD	HL,(TCP_TIMEOUT_LEFT)
	DEC	HL
	LD	(TCP_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JR	NZ,.WAITLP
.CDONE
	LD	A,ST_CLOSED
	LD	(TCP_STATE),A
	OR	A
	RET
.WHAVE
	; Drain one packet, regardless of contents.
	LD	HL,@MAIN.RX_HDR
	LD	DE,@MAIN.RX_BUF
	LD	BC,1518
	CALL	@RTL.READ_PACKET
	JR	.WAITLP


; ------------------------------------------------------
; BUILD_DATA: TCP segment with PSH+ACK + caller's data.
; Sets TCP_TX_LEN.  Caller's args saved in SEND wrapper.
; ------------------------------------------------------
BUILD_DATA
	; TCP segment length = 20 + data_len.
	LD	HL,(SEND.SAVE_LEN)
	LD	BC,20
	ADD	HL,BC
	LD	B,H
	LD	C,L			; BC = TCP seg len
	CALL	BUILD_ETH_IP
	; --- TCP header ---
	LD	A,(TCP_LOCAL_PORT_HI)
	LD	(DE),A
	INC	DE
	LD	A,(TCP_LOCAL_PORT_LO)
	LD	(DE),A
	INC	DE
	LD	A,(TCP_REMOTE_PORT_HI)
	LD	(DE),A
	INC	DE
	LD	A,(TCP_REMOTE_PORT_LO)
	LD	(DE),A
	INC	DE
	LD	HL,TCP_SND_NXT
	LD	BC,4
	LDIR
	LD	HL,TCP_RCV_NXT
	LD	BC,4
	LDIR
	LD	A,0x50			; data offset = 5 (20 bytes)
	LD	(DE),A
	INC	DE
	LD	A,TF_PSH | TF_ACK
	LD	(DE),A
	INC	DE
	LD	A,TCP_RECV_WIN_HI	; advertised window hi (BE)
	LD	(DE),A
	INC	DE
	LD	A,TCP_RECV_WIN_LO
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A			; csum hi
	INC	DE
	LD	(DE),A			; csum lo
	INC	DE
	LD	(DE),A			; urg hi
	INC	DE
	LD	(DE),A			; urg lo
	INC	DE
	; Copy payload.
	LD	HL,(SEND.SAVE_DATA)
	LD	BC,(SEND.SAVE_LEN)
	LDIR
	; Checksums.
	CALL	WRITE_IP_CSUM
	CALL	WRITE_TCP_CSUM
	; Frame length = 14 + 20 + 20 + data_len.
	LD	HL,(SEND.SAVE_LEN)
	LD	BC,54
	ADD	HL,BC
	LD	(TCP_TX_LEN),HL
	RET


; ------------------------------------------------------
; BUILD_FIN: TCP FIN+ACK segment (no payload).
; ------------------------------------------------------
BUILD_FIN
	LD	BC,20
	CALL	BUILD_ETH_IP
	LD	A,(TCP_LOCAL_PORT_HI)
	LD	(DE),A
	INC	DE
	LD	A,(TCP_LOCAL_PORT_LO)
	LD	(DE),A
	INC	DE
	LD	A,(TCP_REMOTE_PORT_HI)
	LD	(DE),A
	INC	DE
	LD	A,(TCP_REMOTE_PORT_LO)
	LD	(DE),A
	INC	DE
	LD	HL,TCP_SND_NXT
	LD	BC,4
	LDIR
	LD	HL,TCP_RCV_NXT
	LD	BC,4
	LDIR
	LD	A,0x50
	LD	(DE),A
	INC	DE
	LD	A,TF_FIN | TF_ACK
	LD	(DE),A
	INC	DE
	LD	A,0x04
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	CALL	WRITE_IP_CSUM
	CALL	WRITE_TCP_CSUM
	LD	HL,54
	LD	(TCP_TX_LEN),HL
	RET


	ENDIF

	ENDMODULE
	ENDIF
