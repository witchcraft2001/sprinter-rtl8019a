; ======================================================
; tcp_lib.asm -- minimal one-session TCP/IPv4 client.
;
; Scope:
;   * TCP.OPEN  -- send SYN, wait SYN+ACK, send ACK, set
;                  state to ESTABLISHED.
;   * TCP.SEND  -- one PSH+ACK segment (1..MSS bytes); with
;                  USE_TCP_RELIABLE_SEND, wait cumulative ACK
;                  and retransmit on timeout.
;   * TCP.RECV  -- poll for payload/FIN/RST, delayed ACKs.
;   * TCP.CLOSE -- send FIN+ACK, no post-FIN drain.
;   * TCP.SAVE_CTX / RESTORE_CTX -- swap the single session
;     state so apps can multiplex sessions (FTP ctrl+data).
;
; Design choices:
;   - one session.
;   - MSS 536 announced; advertised window 2680 = 5 * MSS (a
;     full in-flight window must fit the 8-bit-mode RX ring
;     with slack to spare, see TCP_RECV_WIN_HI).
;   - sequence numbers stored big-endian on disk to match
;     the wire format; arithmetic is done by reading bytes
;     manually (no native 32-bit ops on Z80).
;   - optional bounded stop-and-wait retransmit for outbound data;
;     receive waits retain their per-call overall timeout in ms.
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

; Connect = up to SYN_ATTEMPTS handshake tries of SYN_TIMEOUT_MS
; each (~5 s total, the old single-shot budget).  A lone lost SYN
; or SYN+ACK on a real LAN used to fail the whole connect; every
; retry now also draws a FRESH local port + ISN, so a server-side
; TIME_WAIT collision (same tuple as a recent run) or a stray RST
; self-heals instead of failing the run.
SYN_ATTEMPTS		EQU 3
SYN_TIMEOUT_MS		EQU 1700

; USE_TCP_RELIABLE_SEND uses a deliberately small stop-and-wait sender: one
; MSS segment is outstanding at a time, with a bounded cumulative-ACK
; wait.  Four one-second attempts cover a lost data segment and a lost
; ACK without introducing an unbounded wait into SEND.  The original
; caller buffer remains valid for the whole synchronous call, so every
; retry can rebuild the exact segment without a second 536-byte buffer.
SEND_ATTEMPTS		EQU 4
SEND_ACK_TIMEOUT_MS	EQU 1000

ACK_WAIT_IDLE		EQU 0
ACK_WAIT_ACTIVE		EQU 1
ACK_WAIT_RX_PENDING	EQU 2

; Receive window advertised in every outgoing SYN/ACK/DATA segment.
; Must fit the chip's RX ring: with the 8-bit-mode ring (PSTART
; 0x46, PSTOP 0x60) usable capacity is ~25 pages = 6.4 KB, and one
; full MSS=536 segment costs 3 pages (590 B frame + 4 B RX header).
; 3.5 KB caps the peer at ~7 in-flight segments = 21 pages, leaving
; 4 pages of headroom for broadcasts and drain latency.  Advertising
; more (the old 8 KB was sized for the pre-PSTOP-fix 14.5 KB ring)
; makes every server burst overflow the ring; overflow recovery then
; flushes ALL queued frames, amplifying one loss into a stall.
; Advertised receive window vs the RX ring, in 256-byte NIC pages:
; the ring is 26 pages (0x46..0x5F) minus 1 for the BNRY!=CURR
; empty-slot convention = 25 storable.  One MSS-536 frame occupies
; 3 pages (14+40+536+4 = 594 bytes).  The peer may send a full
; window in one burst while we are busy (disk flush, slow 8-bit
; DMA drain), and RCR_AB adds every LAN broadcast on top, so the
; window must leave real slack:
;   3584 (old) -> 7 segments -> 21 pages, slack 4: overflowed on
;   busy LANs / boards with slow ISA timing (mid-file stalls).
;   2680 = 5 * MSS -> 15 pages, slack 10: a whole burst plus ten
;   broadcast frames fit even during a flush pause.
; Exactly 5 segments also meshes with TCP_ACK_THRESH = 4: the ACK
; for segment 4 leaves while segment 5 is still in flight, so the
; peer refills without a stop-and-go gap (a non-multiple-of-MSS
; window such as 2048 = 3.8 MSS stalls the pipe on every window
; exhaustion and cost 10-15 KB/s).  Throughput here is CPU/DMA-
; bound per segment; RECOVER_OVERFLOW remains as the backstop.
TCP_RECV_WIN_HI		EQU 0x0A		; 2680 = 0x0A78 (5 * MSS 536)
TCP_RECV_WIN_LO		EQU 0x78

; Multichannel only: the honest window while an ACK is built for a
; FOREIGN channel's segment (see TCP_ADV_WIN_HI/LO in memmap.inc and
; HANDLE_FOREIGN_FRAME in unetrtl.asm).  That channel is not selected,
; so its only receive capacity is the single CH_PEND_SIZE slot -- one
; MSS -- not the normal TCP_RECV_WIN_HI/LO this connection would
; advertise while actively selected.
TCP_FOREIGN_WIN_HI	EQU 0x02		; 536 = 0x0218 (one MSS, one pend slot)
TCP_FOREIGN_WIN_LO	EQU 0x18

; Delayed-ACK threshold (RFC 1122 allows up to 2 segments unacked).
; We are slightly more aggressive (4) because the chip RX ring is
; large and the link is local; we still flush an ACK immediately
; whenever the ring drains, so the peer never waits for long.
	IFDEF USE_TCP_MULTICHAN
TCP_ACK_THRESH		EQU 1		; another channel's ring traffic must not defer us
	ELSE
TCP_ACK_THRESH		EQU 4
	ENDIF

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
F_OTHER			EQU 6	; head packet belongs to another UNET channel


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
	IFDEF USE_TCP_RELIABLE_SEND
	LD	(TCP_ACK_WAIT_STATE),A
	ENDIF
	LD	A,SYN_ATTEMPTS
	LD	(.TRIES),A
.ATTEMPT
	; Fresh ephemeral port for EVERY attempt, drawn from a 14-bit
	; salted sequence (0xC000..0xFFFF).  The old scheme (LO = R,
	; HI = fixed SP byte) had a 128-port pool with the high byte
	; identical on every run of the same app -- back-to-back runs
	; collided with the server's TIME_WAIT of the previous session
	; and the connect timed out.  TCP_PORT_SALT lives outside the
	; context-swap block and is intentionally never initialized:
	; leftover RAM is the seed, R stirs it per attempt.
	LD	HL,(TCP_PORT_SALT)
	LD	D,H
	LD	E,L
	ADD	HL,HL
	ADD	HL,DE			; salt *= 3
	LD	A,R
	LD	E,A
	LD	D,0
	ADD	HL,DE			; += R
	LD	DE,0x9E37
	ADD	HL,DE			; += odd constant (full-period walk)
	LD	(TCP_PORT_SALT),HL
	LD	A,L
	LD	(TCP_LOCAL_PORT_LO),A
	LD	A,H
	OR	0xC0
	LD	(TCP_LOCAL_PORT_HI),A
	; Fresh ISN per attempt (R + salt): a retried handshake must
	; not look like a duplicate of the aborted one to the server.
	LD	A,R
	LD	(TCP_SND_NXT + 0),A
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
	; local_port) tuple.  A late SYN+ACK for a PREVIOUS attempt
	; is filtered by the port match (each attempt has a new port).
	LD	HL,SYN_TIMEOUT_MS
	LD	(TCP_TIMEOUT_LEFT),HL
	CALL	WAIT_SYN_ACK
	JR	NC,.GOT_SYNACK
	; Esc/Ctrl+C aborts immediately; timeout and RST burn one
	; attempt and retry with a fresh port + ISN.
	LD	A,(TCP_LAST_FAIL)
	CP	F_CANCEL
	SCF
	RET	Z
	LD	A,(.TRIES)
	DEC	A
	LD	(.TRIES),A
	JP	NZ,.ATTEMPT
	SCF
	RET
.GOT_SYNACK

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
.TRIES	DB 0


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
; SEND_DUP_ACK: build + transmit a pure ACK on the current
; session.  Used after a session swap to nudge the peer's
; TCP into fast-retransmit, so any reply that landed in
; the chip's RX ring (and was dropped by the other-session
; filter) gets re-sent without waiting for the slow
; exponential backoff timer.
;   Out: CF set on send error.
; ------------------------------------------------------
SEND_DUP_ACK
	CALL	BUILD_ACK
	LD	HL,@MAIN.TX_BUF
	LD	BC,(TCP_TX_LEN)
	JP	@RTL.SEND_FRAME


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
	; advertised window (BE).  Multichannel: runtime TCP_ADV_WIN_HI/LO
	; (see its declaration in memmap.inc) instead of the fixed
	; constant, so an ACK built while processing a foreign channel's
	; segment can advertise that channel's true one-MSS pend capacity.
	IFDEF USE_TCP_MULTICHAN
	LD	A,(TCP_ADV_WIN_HI)
	LD	(DE),A
	INC	DE
	LD	A,(TCP_ADV_WIN_LO)
	LD	(DE),A
	INC	DE
	ELSE
	LD	A,TCP_RECV_WIN_HI
	LD	(DE),A
	INC	DE
	LD	A,TCP_RECV_WIN_LO
	LD	(DE),A
	INC	DE
	ENDIF
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

	IFDEF	UNET_DLL
; ------------------------------------------------------
; WRITE_TCP_CSUM_DATA_SG: zero-copy counterpart to WRITE_TCP_CSUM,
; used ONLY by BUILD_DATA (UNET_DLL build).  BUILD_SYN/ACK/FIN build
; their whole (payload-free) segment contiguously in TX_BUF and keep
; using plain WRITE_TCP_CSUM above unchanged; only a DATA segment has
; a payload living outside TX_BUF (SEND.SAVE_DATA/SAVE_LEN, set by
; SEND before BUILD_DATA runs), so only this path needs the split.
; Sums pseudo-header + the 20-byte TCP header (always even, straight
; from TX_BUF) + the payload (from the caller's own buffer).  A
; trailing odd payload byte is folded as (byte << 8) directly into
; HL -- numerically identical to WRITE_TCP_CSUM's write-a-zero-then-
; sum trick, but without writing into any buffer.
; ------------------------------------------------------
WRITE_TCP_CSUM_DATA_SG
	LD	HL,0
	LD	DE,@MAIN.OUR_IP
	LD	BC,4
	CALL	CSUM_ACCUM_BE
	LD	DE,TCP_REMOTE_IP
	LD	BC,4
	CALL	CSUM_ACCUM_BE
	LD	BC,0x0006
	ADD	HL,BC
	JR	NC,.PROTO_OK
	INC	HL
.PROTO_OK
	LD	BC,(BUILD_ETH_IP.TCP_SEG_LEN)
	ADD	HL,BC
	JR	NC,.LEN_OK
	INC	HL
.LEN_OK
	LD	DE,@MAIN.TX_BUF + 14 + IP_HDR_LEN
	LD	BC,20
	CALL	CSUM_ACCUM_BE
	LD	BC,(SEND.SAVE_LEN)
	LD	A,C
	AND	0xFE
	LD	C,A			; BC = even portion of the payload length
	LD	DE,(SEND.SAVE_DATA)
	CALL	CSUM_ACCUM_BE		; DE ends up at the odd trailing byte, if any
	LD	A,(SEND.SAVE_LEN)
	AND	1
	JR	Z,.EVEN
	LD	A,(DE)
	LD	B,A
	LD	C,0
	ADD	HL,BC
	JR	NC,.EVEN
	INC	HL
.EVEN
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
	ENDIF


; ------------------------------------------------------
; CSUM_ACCUM_BE: add BC bytes (must be even) at (DE) into
; HL as a running 16-bit BE one's-complement sum.
;   In:  HL = current sum, DE = ptr, BC = byte count (even).
;   Out: HL = updated sum, DE = past last byte.
;        Trashes A, BC.
;
; Chained-ADC implementation, ~55 T/word vs ~103 T/word for
; the naive PUSH/POP word loop (the TCP checksum runs over
; every outgoing segment, so this is on the hot send path).
; Carry out of the low-byte add joins the next word's
; high-byte add; carry out of the high-byte add is the
; end-around carry and joins the same word's low-byte add;
; the trailing carry is folded after the loop.
; ------------------------------------------------------
CSUM_ACCUM_BE
	LD	A,B
	OR	C
	RET	Z
	EX	DE,HL			; HL = ptr, DE = accumulated sum
	SRL	B
	RR	C			; BC = word count (>= 1)
	; Split into DJNZ chunks: inner = C words (0 -> 256), plus
	; B extra 256-word chunks (one fewer when C = 0).  Stored as
	; count+1 so the loop tail can test with a CF-preserving DEC.
	LD	A,C
	OR	A
	LD	A,B
	JR	NZ,.HAVE_OUT
	DEC	A
.HAVE_OUT
	INC	A
	LD	(.OUTREM + 1),A		; self-mod: outer chunks + 1
	LD	B,C			; inner word counter (0 -> 256)
	OR	A			; clear CF for the first ADC
.WLP
	LD	A,D
	ADC	A,(HL)			; high byte (+ carry from prev word)
	LD	D,A
	INC	HL
	LD	A,E
	ADC	A,(HL)			; low byte (+ end-around carry)
	LD	E,A
	INC	HL
	DJNZ	.WLP
.OUTREM
	LD	A,0			; self-modified: chunks remaining + 1
	DEC	A			; preserves CF
	JR	Z,.FOLD
	LD	(.OUTREM + 1),A
	JR	.WLP			; B = 0 -> next chunk is 256 words
.FOLD
	; Fold the trailing carry end-around into D:E.
	LD	A,D
	ADC	A,0
	LD	D,A
	JR	NC,.FOLDED
	INC	E
	JR	NZ,.FOLDED
	INC	D
.FOLDED
	EX	DE,HL			; HL = sum, DE = past last byte
	RET


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
.TICK					; reached every pass: tick + key poll
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
	IFDEF UNET_DLL
	LD	BC,@MAIN.RX_BUF_SIZE
	ELSE
	LD	BC,1518			; @MAIN.RX_BUF_SIZE is documented but the
					; apps define RX_BUF_SIZE outside MODULE MAIN,
					; so it is not referenceable here.  All callers
					; (apps and the UNET DLL) size RX_BUF at 1518.
	ENDIF
	IFDEF USE_TCP_MULTICHAN
	CALL	@RTL.PEEK_PACKET
	ELSE
	CALL	@RTL.READ_PACKET
	ENDIF
	JP	C,.TICK
	; Validate IPv4 + TCP from remote.
	CALL	IS_TCP_FROM_PEER
	IFDEF USE_TCP_MULTICHAN
	JR	C,.COMMIT_PEER
	LD	A,1
	CALL	@UNET.HANDLE_FOREIGN_FRAME
	JR	NC,.COMMIT_OTHER
	OR	A
	JP	Z,.TICK			; consumed: charge the budget, see RECV
	LD	A,F_OTHER
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.COMMIT_OTHER
	LD	HL,@MAIN.RX_HDR
	CALL	@RTL.COMMIT_PACKET
	IFDEF USE_ARP_ANSWER
	CALL	@ARP.ANSWER_REQUEST
	ENDIF
	JP	.TICK
.COMMIT_PEER
	LD	HL,@MAIN.RX_HDR
	CALL	@RTL.COMMIT_PACKET
	JR	.PEER_SEG
	ELSE
	JR	C,.PEER_SEG
	IFDEF USE_ARP_ANSWER
	; Not our segment: if it is an ARP request for our IP, answer
	; it.  Peers re-validate their ARP entry mid-session; staying
	; silent here kills the connection on a real LAN.  (The reply
	; clobbers TX_BUF -- safe: every outgoing TCP segment is
	; rebuilt in TX_BUF from scratch before sending.)
	CALL	@ARP.ANSWER_REQUEST
	ENDIF
	JP	.TICK
	ENDIF
.PEER_SEG
	; Check flags = SYN | ACK.
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 13)
	AND	(TF_RST | TF_SYN | TF_ACK)
	CP	(TF_SYN | TF_ACK)
	JR	Z,.OK
	; RST -> immediate fail.
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 13)
	AND	TF_RST
	JR	NZ,.RST
	JP	.TICK
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
; SEND: send caller's data as one PSH+ACK segment, wait for
; its cumulative ACK, and retransmit the same sequence on a
; bounded timeout.  Only one segment is outstanding at once.
;
; If peer data is piggybacked on the ACK, RECV processes and
; acknowledges it here, then ACK_WAIT_RX_PENDING makes the next
; public RECV return that same RX_BUF payload without touching the
; NIC.  A caller must drain such pending data before another SEND.
;   In:  HL = data ptr, BC = length (1..MSS=536).
;   Out: CF=0 ok; CF=1 fail.
; ------------------------------------------------------
SEND
	LD	(.SAVE_LEN),BC
	LD	(.SAVE_DATA),HL
	IFDEF USE_TCP_RELIABLE_SEND
	; RX_BUF already holds data captured by the preceding SEND.  Reading
	; more ACKs would overwrite it, so make the caller drain RECV first.
	LD	A,(TCP_ACK_WAIT_STATE)
	CP	ACK_WAIT_RX_PENDING
	JR	NZ,.READY
	LD	A,F_BAD_SEG
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.READY
	; Save the first sequence and calculate the cumulative ACK target.
	LD	HL,TCP_SND_NXT
	LD	DE,TCP_SEND_SEQ
	LD	BC,4
	LDIR
	LD	HL,TCP_SEND_SEQ
	LD	DE,TCP_ACK_WAIT_TARGET
	LD	BC,4
	LDIR
	LD	BC,(.SAVE_LEN)
	LD	DE,TCP_ACK_WAIT_TARGET
	CALL	ADD32_BE_BC
	LD	A,SEND_ATTEMPTS
	LD	(TCP_SEND_RETRY_LEFT),A
.TRY
	; BUILD_DATA reads TCP_SND_NXT.  Put the original sequence there
	; for the build, then restore the post-segment value before the
	; frame goes on the wire.  Every retry therefore carries the same
	; sequence number and is safely de-duplicated by the peer.
	CALL	.RESTORE_SEQ
	CALL	BUILD_DATA
	CALL	.RESTORE_TARGET
	IFDEF	UNET_DLL
	; Zero-copy: TX_BUF holds only the 14+20+20=54-byte header built
	; by BUILD_DATA; the payload streams straight from the caller's
	; own buffer (still valid here -- SAVE_DATA/SAVE_LEN are re-read
	; on every retry, same invariant as BUILD_DATA's own LDIR used to
	; rely on).
	LD	HL,(SEND.SAVE_DATA)
	LD	(@RTL.TX_PAY_PTR),HL
	LD	HL,(SEND.SAVE_LEN)
	LD	(@RTL.TX_PAY_LEN),HL
	LD	HL,@MAIN.TX_BUF
	LD	BC,54
	CALL	@RTL.SEND_FRAME_SG
	ELSE
	LD	HL,@MAIN.TX_BUF
	LD	BC,(TCP_TX_LEN)
	CALL	@RTL.SEND_FRAME
	ENDIF
	JR	NC,.WAIT_ACK
	CALL	.RESTORE_SEQ
	XOR	A
	LD	(TCP_ACK_WAIT_STATE),A
	LD	A,F_SEND
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.WAIT_ACK
	LD	A,ACK_WAIT_ACTIVE
	LD	(TCP_ACK_WAIT_STATE),A
	LD	HL,SEND_ACK_TIMEOUT_MS
	LD	(RECV_TIMEOUT),HL
	CALL	RECV
	JR	C,.WAIT_FAIL
	; A pure ACK returns BC=0.  Payload piggybacked on the ACK is
	; already published through TCP_RX_DATA_PTR/LEN by RECV.
	CALL	ACK_TARGET_MATCH
	JR	NZ,.UNACKED_DATA
	LD	A,B
	OR	C
	LD	A,ACK_WAIT_IDLE
	JR	Z,.SET_WAIT_STATE
	LD	A,ACK_WAIT_RX_PENDING
.SET_WAIT_STATE
	LD	(TCP_ACK_WAIT_STATE),A
	XOR	A
	LD	(TCP_LAST_FAIL),A
	OR	A
	RET
.WAIT_FAIL
	XOR	A
	LD	(TCP_ACK_WAIT_STATE),A
	LD	A,(TCP_LAST_FAIL)
	CP	F_TIMEOUT
	JR	NZ,.FATAL
	LD	A,(TCP_SEND_RETRY_LEFT)
	DEC	A
	LD	(TCP_SEND_RETRY_LEFT),A
	JR	NZ,.TRY
	; Keep SND_NXT and SND_UNA at the first unacknowledged byte on
	; failure.  A caller that elects to
	; retry the same application write will therefore fill the same
	; TCP sequence hole rather than creating an unrecoverable new one.
	CALL	.RESTORE_SEQ
	LD	A,F_TIMEOUT
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.FATAL
	; RST/cancel/ACK-transmit failures terminate the attempt.  Restore
	; the unacknowledged sequence for a consistent local state.
	CALL	.RESTORE_SEQ
	SCF
	RET
.UNACKED_DATA
	; Full-duplex peer data with an ACK below our target is retained,
	; but RX_BUF cannot be reused for a further ACK wait until the caller
	; drains it.  Report a bounded protocol failure instead of silently
	; overwriting the peer data or claiming this send was acknowledged.
	LD	A,ACK_WAIT_RX_PENDING
	LD	(TCP_ACK_WAIT_STATE),A
	CALL	.RESTORE_SEQ
	LD	A,F_BAD_SEG
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.RESTORE_SEQ
	LD	HL,TCP_SEND_SEQ
	LD	DE,TCP_SND_NXT
	LD	BC,4
	LDIR
	LD	HL,TCP_SEND_SEQ
	LD	DE,TCP_SND_UNA
	LD	BC,4
	LDIR
	RET
.RESTORE_TARGET
	LD	HL,TCP_ACK_WAIT_TARGET
	LD	DE,TCP_SND_NXT
	LD	BC,4
	LDIR
	RET
	ELSE
	; Compact legacy path for size-constrained stand-alone clients.
	; UNETRTL defines USE_TCP_RELIABLE_SEND and does not use this path.
	CALL	BUILD_DATA
	LD	HL,@MAIN.TX_BUF
	LD	BC,(TCP_TX_LEN)
	CALL	@RTL.SEND_FRAME
	JR	NC,.BEST_EFFORT_OK
	LD	A,F_SEND
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.BEST_EFFORT_OK
	LD	BC,(.SAVE_LEN)
	LD	DE,TCP_SND_NXT
	CALL	ADD32_BE_BC
	OR	A
	RET
	ENDIF
.SAVE_LEN	DW 0
.SAVE_DATA	DW 0


	IFDEF USE_TCP_RELIABLE_SEND
; ------------------------------------------------------
; ACK_TARGET_MATCH: ZF=1 when SND_UNA reached the target of
; the active SEND.  Preserves all registers and CF is irrelevant.
; ------------------------------------------------------
ACK_TARGET_MATCH
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	HL,TCP_SND_UNA
	LD	DE,TCP_ACK_WAIT_TARGET
	LD	B,4
.LP
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.DONE
	INC	DE
	INC	HL
	DJNZ	.LP
.DONE
	POP	HL
	POP	DE
	POP	BC
	RET
	ENDIF


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
	IFDEF USE_TCP_RELIABLE_SEND
	; SEND may have consumed a payload-bearing ACK while waiting for
	; its own cumulative ACK.  Deliver that payload exactly once before
	; reading another NIC frame, otherwise RX_BUF would be overwritten.
	LD	A,(TCP_ACK_WAIT_STATE)
	CP	ACK_WAIT_RX_PENDING
	JR	NZ,.START_WAIT
	XOR	A
	LD	(TCP_ACK_WAIT_STATE),A
	LD	(TCP_LAST_FAIL),A
	LD	HL,(TCP_RX_DATA_PTR)
	LD	BC,(TCP_RX_DATA_LEN)
	OR	A
	RET
.START_WAIT
	ENDIF
	; Initial budget: caller's RECV_TIMEOUT (set via the public
	; knob) or the 30 000 ms default if the caller didn't touch
	; it.  After consuming the budget we re-arm the default so
	; the override is one-shot.
	LD	HL,(RECV_TIMEOUT)
	LD	A,H
	OR	L
	JR	NZ,.HAVE_TO
	LD	HL,30000
.HAVE_TO
	LD	(TCP_TIMEOUT_LEFT),HL
	LD	HL,0
	LD	(RECV_TIMEOUT),HL
.LP
	CALL	@RTL.RING_HAS_PACKET
	JR	NZ,.HAVE
.TICK					; reached every pass
	; Consume the budget BEFORE the 1 ms tick: the final pass then
	; returns without a wasted delay.  This matters for the ACK
	; drain pattern (RECV_TIMEOUT=1 with a queued packet): the ACK
	; is consumed and RECV returns immediately instead of always
	; paying a full tick on the way out.
	LD	HL,(TCP_TIMEOUT_LEFT)
	DEC	HL
	LD	(TCP_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JR	Z,.TIMED_OUT
	CALL	@MAIN.TICK_AND_CHECK_KEY
	JP	C,.CANCEL
	JP	.LP
.TIMED_OUT
	LD	A,F_TIMEOUT
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.HAVE
	LD	HL,@MAIN.RX_HDR
	LD	DE,@MAIN.RX_BUF
	IFDEF UNET_DLL
	LD	BC,@MAIN.RX_BUF_SIZE
	ELSE
	LD	BC,1518			; @MAIN.RX_BUF_SIZE is documented but the
					; apps define RX_BUF_SIZE outside MODULE MAIN,
					; so it is not referenceable here.  All callers
					; (apps and the UNET DLL) size RX_BUF at 1518.
	ENDIF
	IFDEF USE_TCP_MULTICHAN
	CALL	@RTL.PEEK_PACKET
	ELSE
	CALL	@RTL.READ_PACKET
	ENDIF
	JP	C,.TICK
	CALL	IS_TCP_FROM_PEER
	IFDEF USE_TCP_MULTICHAN
	JR	C,.COMMIT_PEER
	LD	A,1			; caller protocol = TCP
	CALL	@UNET.HANDLE_FOREIGN_FRAME
	JR	NC,.COMMIT_OTHER
	; Foreign frame consumed (queued, or dropped+dup-ACKed by
	; HANDLE_FOREIGN_FRAME's blocked-drain path).  Go to .TICK, NOT
	; .LP: .LP skips the timeout decrement, and the blocked-drain
	; path's dup-ACK provokes an immediate peer retransmit, so a
	; blocked channel can refill the ring as fast as we empty it --
	; looping on .LP then never expires and never returns to the app
	; (only Esc breaks out).  A tick per foreign frame is the price
	; of a bounded wait.
	OR	A
	JP	Z,.TICK
	LD	A,F_OTHER		; foreign queue full: leave head in NIC ring
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.COMMIT_OTHER
	LD	HL,@MAIN.RX_HDR
	CALL	@RTL.COMMIT_PACKET
	IFDEF USE_ARP_ANSWER
	CALL	@ARP.ANSWER_REQUEST	; see WAIT_SYN_ACK for rationale
	ENDIF
	JP	.TICK
.COMMIT_PEER
	LD	HL,@MAIN.RX_HDR
	CALL	@RTL.COMMIT_PACKET
	JR	.PEER_SEG
	ELSE
	JR	C,.PEER_SEG
	IFDEF USE_ARP_ANSWER
	CALL	@ARP.ANSWER_REQUEST	; see WAIT_SYN_ACK for rationale
	ENDIF
	JP	.TICK
	ENDIF
.PEER_SEG
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
	; Segment geometry first: the sequence classification below
	; needs the payload length to recognise a retransmit that
	; OVERLAPS RCV_NXT (see .SEQ_MISMATCH).
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
	SBC	HL,BC			; HL = data length as sent
	LD	(.SEG_LEN),HL
	; data ptr = RX_BUF + 14 + 20 + data_offset
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN
	LD	A,(.DATA_OFFSET)
	LD	C,A
	LD	B,0
	ADD	HL,BC
	LD	(.SEG_PTR),HL

	; Validate seq == RCV_NXT.
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + 4	; seq BE
	LD	DE,TCP_RCV_NXT
	LD	B,4
.CMPSEQ
	LD	A,(DE)
	CP	(HL)
	JP	NZ,.SEQ_MISMATCH
	INC	DE
	INC	HL
	DJNZ	.CMPSEQ
.SEQ_OK
	; If has ACK, copy ack number into SND_UNA.
	LD	A,(.FLAGS)
	AND	TF_ACK
	JR	Z,.NO_ACK
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + 8	; ack BE
	LD	DE,TCP_SND_UNA
	LD	BC,4
	LDIR
.NO_ACK
	; Publish the (possibly trimmed) payload.
	LD	HL,(.SEG_LEN)
	LD	(TCP_RX_DATA_LEN),HL
	LD	HL,(.SEG_PTR)
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
	IFDEF USE_TCP_RELIABLE_SEND
	; Internal SEND wait: a pure cumulative ACK is a successful
	; zero-length return to SEND instead of an idle RECV timeout.
	LD	A,(TCP_ACK_WAIT_STATE)
	CP	ACK_WAIT_ACTIVE
	JR	NZ,.NORMAL_RETURN
	CALL	ACK_TARGET_MATCH
	JR	NZ,.NORMAL_RETURN
	LD	HL,(TCP_RX_DATA_LEN)
	LD	A,H
	OR	L
	JR	NZ,.RETURN_DATA
	LD	HL,0
	LD	BC,0
	OR	A
	RET
.NORMAL_RETURN
	ENDIF
	LD	HL,(TCP_RX_DATA_LEN)
	LD	A,H
	OR	L
	JP	Z,.TICK			; pure ACK -- back to wait
.RETURN_DATA
	LD	HL,(TCP_RX_DATA_PTR)
	LD	BC,(TCP_RX_DATA_LEN)
	OR	A
	RET
.PEER_FIN
	SCF
	RET
.SEQ_MISMATCH
	; seq != RCV_NXT.  Three cases -- only the third is new, and
	; getting it wrong deadlocks a transfer for good:
	;   seq > RCV_NXT           -> a hole; we cannot buffer out of
	;                              order, so dup-ACK and wait.
	;   seq + len <= RCV_NXT    -> pure duplicate; dup-ACK.
	;   seq < RCV_NXT < seq+len -> the peer retransmitted a segment
	;                              that STARTS before what we have
	;                              but carries new data past it
	;                              (senders coalesce queued data on
	;                              retransmit).  Rejecting it means
	;                              the peer resends the same bytes
	;                              forever while we dup-ACK, until
	;                              RECV times out -- the "transfer
	;                              dies mid-file" failure.  RFC 793
	;                              says trim the overlap and accept
	;                              the remainder.
	; delta = RCV_NXT - seq, LSB-first over the big-endian fields.
	; Only LD instructions sit between the SBCs, so the borrow
	; chains correctly across all four bytes.
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 4 + 3)
	LD	B,A
	LD	A,(TCP_RCV_NXT + 3)
	SUB	B
	LD	(.DELTA_LO),A
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 4 + 2)
	LD	B,A
	LD	A,(TCP_RCV_NXT + 2)
	SBC	A,B
	LD	(.DELTA_LO + 1),A
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 4 + 1)
	LD	B,A
	LD	A,(TCP_RCV_NXT + 1)
	SBC	A,B
	LD	C,A				; third byte of the difference
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 4 + 0)
	LD	B,A
	LD	A,(TCP_RCV_NXT + 0)
	SBC	A,B
	JP	C,.OUT_OF_ORDER			; borrow: seq is AHEAD (hole)
	OR	C
	JP	NZ,.OUT_OF_ORDER		; delta >= 65536: ancient copy
	; delta (low 16 bits) vs segment length.
	LD	HL,(.DELTA_LO)
	LD	A,H
	OR	L
	JP	Z,.OUT_OF_ORDER			; delta 0 cannot reach here
	EX	DE,HL				; DE = delta
	LD	HL,(.SEG_LEN)
	OR	A
	SBC	HL,DE				; seg_len - delta
	JP	Z,.OUT_OF_ORDER			; exact duplicate
	JP	C,.OUT_OF_ORDER			; wholly old data
	; Overlap: keep the tail.  new_len = seg_len - delta,
	; new_ptr = seg_ptr + delta.
	LD	(.SEG_LEN),HL
	LD	HL,(.SEG_PTR)
	ADD	HL,DE
	LD	(.SEG_PTR),HL
	JP	.SEQ_OK

.OUT_OF_ORDER
	; Out-of-order or duplicate segment.  Never drop it silently:
	; immediately re-ACK RCV_NXT so the peer re-syncs.  Silent drop
	; deadlocks the session -- if our cumulative ACK is lost (or was
	; still deferred by delayed-ACK when the RX ring overflowed and
	; got flushed), the peer retransmits OLD data with exponential
	; backoff and we would ignore every copy until RECV times out.
	; The dup-ACK also fires the peer's fast retransmit on a lost
	; data segment instead of waiting out its RTO.
	XOR	A
	LD	(RECV_UNACKED),A	; cumulative ACK pays the delayed-ACK debt
	CALL	BUILD_ACK
	LD	HL,@MAIN.TX_BUF
	LD	BC,(TCP_TX_LEN)
	CALL	@RTL.SEND_FRAME		; best-effort; the next copy re-triggers
	JP	.TICK
.CANCEL
	LD	A,F_CANCEL
	LD	(TCP_LAST_FAIL),A
	SCF
	RET
.FLAGS		DB 0
.DATA_OFFSET	DB 0
.SEG_PTR	DW 0		; payload ptr/length of the segment being
.SEG_LEN	DW 0		; classified (trimmed on overlap)
.DELTA_LO	DW 0		; low 16 bits of RCV_NXT - seq

; Counter of segments processed since the last outbound ACK.  Reset
; on TCP.OPEN and on every actual ACK send; bumped on every accepted
; (in-sequence) data segment.  See TCP_ACK_THRESH for the cap.
	IFDEF USE_TCP_CONTEXT_FULL
RECV_UNACKED	EQU TCP_RECV_UNACKED
	ELSE
RECV_UNACKED	DB 0
	ENDIF

; One-shot RECV timeout override, in ms.  Caller writes here just
; before calling RECV; on entry RECV consumes the value and clears
; the slot back to 0 (= "use 30 000 ms default").
	IFDEF USE_TCP_CONTEXT_FULL
RECV_TIMEOUT	EQU TCP_RECV_TIMEOUT
	ELSE
RECV_TIMEOUT	DW 0
	ENDIF


; ------------------------------------------------------
; CLOSE: tear down the connection.
;   In:  TCP_STATE must be ESTAB or CLOSE_WAIT.
;   Out: CF=0 cleanly closed; CF=1 on send/timeout error.
; ------------------------------------------------------
CLOSE
	IFDEF USE_TCP_RELIABLE_SEND
	XOR	A
	LD	(TCP_ACK_WAIT_STATE),A
	ENDIF
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
	; Skip the post-FIN drain.  We used to read+discard ring
	; packets for ~3 sec to wait for the peer's final ACK, but
	; that also discarded packets belonging to OTHER sessions
	; (e.g. FTP's "226 Transfer complete" on the control conn
	; arriving while we were closing the data conn).  The peer
	; will retransmit if our FIN is in flight; not draining is
	; fine for a one-shot teardown.
	LD	A,ST_CLOSED
	LD	(TCP_STATE),A
	OR	A
	RET


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
	; Copy payload.  UNET_DLL streams it straight from the caller's
	; buffer via SEND_FRAME_SG (see SEND) instead of copying it here;
	; TX_BUF holds the 20-byte TCP header only, so there is nothing
	; to LDIR, and the checksum is summed over the two regions
	; separately by WRITE_TCP_CSUM_DATA_SG below.
	IFNDEF	UNET_DLL
	LD	HL,(SEND.SAVE_DATA)
	LD	BC,(SEND.SAVE_LEN)
	LDIR
	ENDIF
	; Checksums.
	CALL	WRITE_IP_CSUM
	IFDEF	UNET_DLL
	CALL	WRITE_TCP_CSUM_DATA_SG
	ELSE
	CALL	WRITE_TCP_CSUM
	ENDIF
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
	LD	A,TCP_RECV_WIN_HI
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
