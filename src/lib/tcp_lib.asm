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
;   - direct clients announce receive MSS 1460 and advertise
;     2920 = 2 * MSS by default. UNETRTL keeps receive MSS 536 because its
;     synchronous caller buffer is transient and its durable queue is
;     exactly one 536-byte segment; its window is computed at runtime.
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
;                  3 RST, 4 unexpected segment, 5 cancel,
;                  6 foreign channel, 7 slice expired,
;                  8 peer FIN (UNET_DLL builds only).
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

	IFDEF USE_TCP_LISTEN
	INCLUDE "coldctx.inc"
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

; Orderly close (UNET_DLL): a FIN that only reached the NIC proves
; nothing -- if it is lost, the peer keeps the connection, and whatever
; request it carries, open until its own idle timeout.  Wait for the
; peer to acknowledge our FIN, retransmitting it a bounded number of
; times.  Three 500 ms attempts cost nothing on a healthy LAN (the ACK
; arrives in about a millisecond) and cap a dead peer at 1.5 s.
CLOSE_ATTEMPTS		EQU 3
CLOSE_ACK_TIMEOUT_MS	EQU 500

ACK_WAIT_IDLE		EQU 0
ACK_WAIT_ACTIVE		EQU 1
ACK_WAIT_RX_PENDING	EQU 2

; Receive geometry. Direct clients own their receive buffer for the whole
; connection, so a full Ethernet MSS reduces per-frame DMA/poll/ACK work.
; UNETRTL may borrow a caller buffer only until public RECV returns and has
; one durable 536-byte pending slot. Keeping its MSS equal to that slot makes
; 2048/2144-byte consumers expose four whole segments per active call and
; avoids the zero-window stop/start regression seen with MSS 1460.
; Receive geometry. Direct clients use MSS 1460 with a two-segment
; 2920-byte window; UNETRTL keeps 536 for its transient buffers.
;
; USE_TCP_RX_SMALL drops a direct client to MSS 536 / window 2680 / ACK
; every fourth segment. It exists for ONE reason: a host that loses frames
; ahead of the card. Measured on the MAME stand (2026-09-13, 380 KB FTP
; GET over a feth pair), MSS 1460 lost a segment out of every burst, each
; loss cost a full server RTO because this stack keeps no out-of-order
; queue, the backoff grew 0.14 -> 26 s and the transfer died on the
; receive timeout -- while `ovw` stayed 0, i.e. the frames never reached
; the card's ring at all. The same transfer at MSS 536 ran clean.
;
; That is NOT a protocol-level limit, and the default must not be lowered
; for it: driven straight into the emulated card (tools/test-exe-ftp.js,
; disk writes costed at 0/30/100/200/400 ms) MSS 1460 completes the same
; 380 KB byte-perfect at every setting -- including 400 ms flushes where
; the card's own ring overflows ten times and recovery handles it -- and
; is 2.5x faster than MSS 536 when the disk is not the bottleneck. The
; loss is specific to the host capture path in front of the emulator; fix
; it there, and use this switch only while stuck with such a host.
	IFDEF UNET_DLL
TCP_RECV_MSS_HI		EQU 0x02		; 536 = 0x0218
TCP_RECV_MSS_LO		EQU 0x18
	ELSE
	IFDEF USE_TCP_RX_SMALL
TCP_RECV_MSS_HI		EQU 0x02		; 536 = 0x0218
TCP_RECV_MSS_LO		EQU 0x18
	ELSE
TCP_RECV_MSS_HI		EQU 0x05		; 1460 = 0x05B4
TCP_RECV_MSS_LO		EQU 0xB4
	ENDIF
	ENDIF

; Direct, single-session clients keep TWO full frames in flight.
; The byte-mode ring has 25 storable 256-byte pages; one maximum frame plus
; its DP8390 header takes 6 pages, so two outstanding segments occupy 12 and
; leave 13 pages for broadcasts and the latency of an 8 KB disk flush -- the
; window the peer may fill while the client is away writing. Three segments
; (the earlier value) occupied 18 of 25 and left only 7, which a single
; stray broadcast plus one flush tipped into an RX-ring overflow; because
; this stack keeps no out-of-order queue, that overflow cost a whole window
; and an RTO, and on a real card the transfer stalled and timed out (the
; 2026-09-14 "ovw 0x03" hardware capture). Two segments is exactly what the
; sibling 3C509B kit settled on for the same reason. MSS stays 1460, so the
; per-byte receive cost -- the actual throughput lever -- is unchanged; on
; the host harness the two-segment window is if anything slightly faster
; (fewer overflow-recovery stalls). UNETRTL ignores this fixed value in its
; builders and computes an honest caller+pending window capped at 2680.
; USE_TCP_RX_WIN3 is an opt-in DLWIN3 throughput experiment, NOT a new
; default: only the advertised window changes; MSS and ACK policy stay put.
	IFDEF USE_TCP_RX_TUNE
TCP_RECV_WIN_HI		EQU 0x11
TCP_RECV_WIN_LO		EQU 0x1C
	ELSE
	IFDEF USE_TCP_RX_WIN3
	IFDEF UNET_DLL
	ASSERT 0, "USE_TCP_RX_WIN3 is for direct diagnostics only"
	ENDIF
	IFDEF USE_TCP_RX_OOO
	IFNDEF USE_TCP_RX_WIN3
	ASSERT 0, "USE_TCP_RX_OOO requires the 4380-byte experiment window"
	ENDIF
	IFDEF UNET_DLL
	ASSERT 0, "USE_TCP_RX_OOO is for direct diagnostics only"
	ENDIF
	IFDEF USE_TCP_RX_SMALL
	ASSERT 0, "USE_TCP_RX_OOO requires MSS 1460"
	ENDIF
	IFDEF USE_TCP_MULTICHAN
	ASSERT 0, "USE_TCP_RX_OOO is for one session only"
	ENDIF
	ENDIF
	IFDEF USE_TCP_RX_SMALL
	ASSERT 0, "USE_TCP_RX_WIN3 requires MSS 1460"
	ENDIF
	IFDEF USE_TCP_MULTICHAN
	ASSERT 0, "USE_TCP_RX_WIN3 is for single-session diagnostics only"
	ENDIF
	ENDIF
	IFDEF UNET_DLL
TCP_RECV_WIN_HI		EQU 0x0A		; fallback/cap documentation: 2680
TCP_RECV_WIN_LO		EQU 0x78
	ELSE
	IFDEF USE_TCP_RX_SMALL
TCP_RECV_WIN_HI		EQU 0x0A		; 2680 = 0x0A78 (5 * MSS 536)
TCP_RECV_WIN_LO		EQU 0x78
	ELSE
	IFDEF USE_TCP_RX_WIN3
TCP_RECV_WIN_HI		EQU 0x11		; 4380 = 0x111C (3 * 1460), experimental
TCP_RECV_WIN_LO		EQU 0x1C
	ELSE
TCP_RECV_WIN_HI		EQU 0x0B		; 2920 = 0x0B68 (2 * 1460)
TCP_RECV_WIN_LO		EQU 0x68
	ENDIF
	ENDIF
	ENDIF
	ENDIF

; Multichannel only: the honest window while an ACK is built for a
; FOREIGN channel's segment (see TCP_ADV_WIN_HI/LO in memmap.inc and
; HANDLE_FOREIGN_FRAME in unetrtl.asm). That channel is not selected,
; so its only receive capacity is the single 536-byte CH_PEND_SIZE slot,
; not the normal TCP_RECV_WIN_HI/LO this connection would
; advertise while actively selected.
TCP_FOREIGN_WIN_HI	EQU 0x02		; 536 = 0x0218 (one MSS, one pend slot)
TCP_FOREIGN_WIN_LO	EQU 0x18

; ACK at least every second full-sized segment, as required by RFC 1122.
; With the two-segment direct window this acks the pair the peer holds in
; flight together, letting it refill promptly. An empty ring still flushes
; immediately. ACKing every single segment (threshold 1) was measured to be
; slightly worse -- it advances the peer's window faster, so more data lands
; while the client is off flushing to disk, raising ring pressure.
	IFDEF USE_TCP_MULTICHAN
TCP_ACK_THRESH		EQU 1		; another channel's ring traffic must not defer us
	ELSE
	IFDEF USE_TCP_RX_SMALL
TCP_ACK_THRESH		EQU 4		; five 536-byte segments fit the 2680 window
	ELSE
TCP_ACK_THRESH		EQU 2
	ENDIF
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
; USE_TCP_LISTEN passive-open states.  An accepted connection is
; plain ST_ESTAB -- these two are transient, before the first peer
; is seen (ST_LISTEN) and while its handshake is completing
; (ST_SYN_RCVD).  Requires USE_TCP_MULTICHAN (the only definer,
; UNETRTL.DLL, always sets both).
ST_LISTEN		EQU 5
ST_SYN_RCVD		EQU 6

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
F_AGAIN			EQU 7	; USE_TCP_ASYNCSEND: silent for one slice, budget remains
F_CLOSED		EQU 8	; UNET_DLL: RECV returned on a peer FIN (orderly close).
				; Every other CF=1 exit of RECV assigns its own reason,
				; so leaving this one unassigned made the FIN inherit
				; whatever the previous operation left behind -- an ACK
				; wait inside SEND then read F_NONE and reported a
				; generic send failure for an orderly close.  The
				; payload that FIN carried is already queued by
				; STORE_TCP_PAYLOAD, so the reason must stay distinct
				; from F_RST: the caller has data left to drain.


; ------------------------------------------------------
; SAVE_CTX: copy the entire single-session TCP state into
; a 38-byte caller-supplied buffer.  Combined with
; RESTORE_CTX this lets apps swap between multiple logical
; sessions (e.g. FTP control + data) without paying for a
; full multi-session lib refactor.
;   In:  DE = destination buffer (>= TCP_CTX_SIZE bytes).
;   Out: DE advanced past the saved state.
; ------------------------------------------------------
; Excluded from UNETRTL.DLL (libman image budget): only FTP.EXE swaps
; whole TCP contexts this way; the DLL uses SELECT_CHANNEL instead.
	IFNDEF	UNET_DLL
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
	ENDIF



; ------------------------------------------------------
; OPEN: 3-way handshake.
; ------------------------------------------------------
OPEN
	XOR	A
	LD	(TCP_LAST_FAIL),A
	LD	(RECV_UNACKED),A
	IFDEF USE_TCP_RX_OOO
	CALL	@TCP_OOO.RESET
	ENDIF
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
	IFDEF	USE_TCP_LISTEN
	; The salt-stir + ISN draw + SND_UNA mirror is shared with
	; LISTEN_POLL's passive open via GEN_ISN (image budget); only the
	; ephemeral-port derivation from the stirred salt stays here.
	; Byte order and semantics match the inline ELSE branch exactly.
	CALL	GEN_ISN			; -> HL = stirred salt
	LD	A,L
	LD	(TCP_LOCAL_PORT_LO),A
	LD	A,H
	OR	0xC0
	LD	(TCP_LOCAL_PORT_HI),A
	ELSE
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
	CALL	COPY_SEQ32
	ENDIF
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
	CALL	XMIT_TX_BUF
	JR	NC,.SENT
	JP	FAIL_SEND
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
	CALL	COPY_SEQ32
	LD	DE,TCP_RCV_NXT
	CALL	INC_SEQ32
	IFDEF USE_TCP_RX_TUNE
	CALL	TUNE_INIT_EDGE
	ENDIF

	; Build & send pure ACK to complete the handshake.
	CALL	BUILD_ACK
	CALL	XMIT_TX_BUF
	JR	NC,.ACK_OK
	JP	FAIL_SEND
.ACK_OK
	LD	A,ST_ESTAB
	LD	(TCP_STATE),A
	OR	A
	RET
.BAD
	LD	A,F_BAD_SEG
	JP	FAIL_A
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
; FAIL_SEND / FAIL_A: record a failure reason and return CF=1.  Image-
; budget helper for the "LD A,F_x / LD (TCP_LAST_FAIL),A / SCF / RET"
; tail that ended 21 routines; FAIL_SEND is the RTL.SEND_FRAME case,
; which alone accounted for six of them.
; ------------------------------------------------------
FAIL_SEND
	LD	A,F_SEND
FAIL_A
	LD	(TCP_LAST_FAIL),A
	SCF
	RET

; ------------------------------------------------------
; COPY_SEQ32: copy the 4-byte big-endian sequence number at (HL) to
; (DE).  Image-budget helper -- the two-instruction form stood at 26
; call sites; contract is LDIR's own, so HL/DE advance past the field
; and BC comes back zero.
; ------------------------------------------------------
COPY_SEQ32
	LD	BC,4
	LDIR
	RET

; ------------------------------------------------------
; XMIT_TX_BUF: put the frame BUILD_* just assembled in TX_BUF on the
; wire.  Image-budget helper: this exact three-instruction sequence
; stood at nine call sites.  CF/A are RTL.SEND_FRAME's.
; ------------------------------------------------------
XMIT_TX_BUF
	LD	HL,@MAIN.TX_BUF
	LD	BC,(TCP_TX_LEN)
	JP	@RTL.SEND_FRAME

; ------------------------------------------------------
; COMMIT_RX: release the NIC ring slot holding the frame just read or
; peeked through MAIN.RX_HDR.  Same image-budget rationale; ten sites.
; Guarded like every other COMMIT_PACKET reference: the peek/commit
; split exists only in builds that pull USE_RTL_PEEK_PACKET.
; ------------------------------------------------------
	IFDEF	USE_RTL_PEEK_PACKET
COMMIT_RX
	LD	HL,@MAIN.RX_HDR
	JP	@RTL.COMMIT_PACKET
	ENDIF


	IFDEF	UNET_DLL
; ------------------------------------------------------
; BUILD_TCP_PORTS_SEQ (UNET_DLL only, image budget): the local/remote
; port pair and the 4-byte big-endian SND_NXT sequence number --
; BUILD_SYN/BUILD_ACK/BUILD_FIN build this leading 12-byte span
; identically before diverging (ack/flags/options/window differ per
; segment type).  Non-DLL builds keep each copy inline byte-identical
; to before; this shared copy exists only under UNET_DLL, so it costs
; nothing there.
;   In:  DE = TCP header start (BUILD_ETH_IP's own "DE = TX_BUF + 14
;        + 20" contract).
;   Out: DE advanced past the sequence number (+12).
; Trashes A, BC, HL.
; ------------------------------------------------------
BUILD_TCP_PORTS_SEQ
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
	CALL	COPY_SEQ32
	RET
	ENDIF

; ------------------------------------------------------
; BUILD_SYN: build SYN segment with MSS option in TX_BUF.
; Sets TCP_TX_LEN to total Ethernet frame length.
;
; BUILD_SYN.SYNACK_ENTRY (USE_TCP_LISTEN, called as
; "CALL BUILD_SYN.SYNACK_ENTRY") is the same builder with flags
; SYN|ACK and ack=TCP_RCV_NXT instead of SYN alone and ack=0 -- the
; passive-open reply to an unsolicited SYN.  A non-LISTEN build never
; sees the extra entry point or the .SYNACK_FLAG byte; every
; instruction below this comment stays byte-identical for it.
; ------------------------------------------------------
BUILD_SYN
	IFDEF	USE_TCP_LISTEN
	XOR	A
	LD	(.SYNACK_FLAG),A
	JR	.BODY
.SYNACK_ENTRY
	LD	A,1
	LD	(.SYNACK_FLAG),A
.BODY
	ENDIF
	; TCP header = 24 bytes (20 + 4-byte MSS option).
	; TCP segment length = 24, IP total = 44, frame = 58.
	LD	HL,24
	LD	(.TCP_LEN),HL
	; Fill Ethernet + IP.
	LD	BC,24			; TCP segment length
	CALL	BUILD_ETH_IP
	; --- TCP header ---
	; DE points just past IP header (= TX_BUF + 14 + 20).
	; src port, dst port, seq (BE): identical in BUILD_SYN/BUILD_ACK/
	; BUILD_FIN.  IFDEF UNET_DLL shares it via BUILD_TCP_PORTS_SEQ
	; (image budget); non-DLL builds keep this inline, byte-identical
	; to before.
	IFDEF	UNET_DLL
	CALL	BUILD_TCP_PORTS_SEQ
	ELSE
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
	CALL	COPY_SEQ32
	ENDIF
	; ack = 0 (not yet acking anything), or TCP_RCV_NXT for a
	; SYNACK_ENTRY reply (peer's seq+1, already set by the caller).
	IFDEF	USE_TCP_LISTEN
	LD	A,(.SYNACK_FLAG)
	OR	A
	JR	Z,.ACK_ZERO
	LD	HL,TCP_RCV_NXT
	CALL	COPY_SEQ32
	JR	.ACK_DONE
.ACK_ZERO
	ENDIF
	XOR	A
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	IFDEF	USE_TCP_LISTEN
.ACK_DONE
	ENDIF
	; data offset (6 << 4 = 0x60), reserved = 0
	LD	A,0x60
	LD	(DE),A
	INC	DE
	; flags = SYN, or SYN|ACK for a SYNACK_ENTRY reply
	IFDEF	USE_TCP_LISTEN
	LD	A,(.SYNACK_FLAG)
	OR	A
	LD	A,TF_SYN
	JR	Z,.FLAGS_OK
	LD	A,TF_SYN | TF_ACK
.FLAGS_OK
	ELSE
	LD	A,TF_SYN
	ENDIF
	LD	(DE),A
	INC	DE
	; advertised window (BE) -- see TCP_RECV_WIN_HI/LO at top.
	IFDEF UNET_DLL
	CALL	WRITE_RX_WINDOW
	ELSE
	LD	A,TCP_RECV_WIN_HI
	LD	(DE),A
	INC	DE
	LD	A,TCP_RECV_WIN_LO
	LD	(DE),A
	INC	DE
	ENDIF
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
	; MSS option: kind=2, len=4. Direct builds advertise 1460; UNETRTL
	; advertises 536 to match its durable pending slot and synchronous
	; caller-buffer lifetime. Outbound SEND chunking is independent.
	LD	A,2
	LD	(DE),A
	INC	DE
	LD	A,4
	LD	(DE),A
	INC	DE
	LD	A,TCP_RECV_MSS_HI
	LD	(DE),A
	INC	DE
	LD	A,TCP_RECV_MSS_LO
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
	IFDEF	USE_TCP_LISTEN
.SYNACK_FLAG	DB 0
	ENDIF


; ------------------------------------------------------
; SEND_DUP_ACK: build + transmit a pure ACK on the current
; session.  Used after a session swap to nudge the peer's
; TCP into fast-retransmit, so any reply that landed in
; the chip's RX ring (and was dropped by the other-session
; filter) gets re-sent without waiting for the slow
; exponential backoff timer.
;   Out: CF set on send error.
; ------------------------------------------------------
	IFDEF UNET_DLL
WRITE_RX_WINDOW
	CALL	@UNET.RX_WINDOW
	LD	A,H
	LD	(DE),A
	INC	DE
	LD	A,L
	LD	(DE),A
	INC	DE
	RET
	ENDIF

	IFDEF USE_TCP_RX_TUNE
; DLTUNE window control.  TCP_TUNE_EDGE is the right edge of the last
; successfully transmitted announcement; it is never moved backwards.
TUNE_INIT_EDGE
	LD	HL,TCP_RCV_NXT
	LD	DE,TCP_TUNE_EDGE
	CALL	COPY_SEQ32
	LD	BC,4380
	LD	DE,TCP_TUNE_EDGE
	CALL	ADD32_BE_BC
	RET

TUNE_ADVANCE
	; Keep the last successfully advertised edge recoverable until TX
	; succeeds.  Callers restore it with TUNE_ROLLBACK on send failure.
	LD	HL,TCP_TUNE_EDGE
	LD	DE,TCP_TUNE_PREV
	CALL	COPY_SEQ32
	LD	HL,TCP_RCV_NXT
	LD	DE,TCP_TUNE_CAND
	CALL	COPY_SEQ32
	LD	BC,(TCP_TUNE_WMAX)
	LD	DE,TCP_TUNE_CAND
	CALL	ADD32_BE_BC
	LD	HL,TCP_TUNE_EDGE
	LD	DE,TCP_TUNE_TMP
	CALL	COPY_SEQ32
	LD	BC,2920
	LD	DE,TCP_TUNE_TMP
	CALL	ADD32_BE_BC
	LD	HL,TCP_TUNE_TMP
	LD	DE,TCP_TUNE_CAND
	CALL	CMP32_SEQ
	JR	NC,.CAND_READY
	LD	HL,TCP_TUNE_TMP
	LD	DE,TCP_TUNE_CAND
	CALL	COPY_SEQ32
.CAND_READY
	LD	HL,TCP_TUNE_EDGE
	LD	DE,TCP_TUNE_CAND
	CALL	CMP32_SEQ
	RET	NC
	LD	HL,TCP_TUNE_CAND
	LD	DE,TCP_TUNE_EDGE
	JP	COPY_SEQ32

; CMP32_SEQ: RFC-style modulo-2^32 sequence comparison.  CF means that
; the value at HL precedes the value at DE (signed (HL-DE) < 0).  Every
; DLTUNE distance is at most 13140, safely below the half-space boundary.
CMP32_SEQ
	PUSH	HL
	PUSH	DE
	INC	HL
	INC	HL
	INC	HL
	INC	DE
	INC	DE
	INC	DE
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	SUB	C
	DEC	HL
	DEC	DE
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	SBC	A,C
	DEC	HL
	DEC	DE
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	SBC	A,C
	DEC	HL
	DEC	DE
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	SBC	A,C
	POP	DE
	POP	HL
	RLCA				; sign bit -> carry
	RET

TUNE_ROLLBACK
	LD	HL,TCP_TUNE_PREV
	LD	DE,TCP_TUNE_EDGE
	JP	COPY_SEQ32

TUNE_KEEP_EDGE
	; Pure/repeated ACKs advertise the current edge but must not expand it.
	; Snapshot it anyway so the common TX-failure rollback is harmless.
	LD	HL,TCP_TUNE_EDGE
	LD	DE,TCP_TUNE_PREV
	JP	COPY_SEQ32

; DE points at the two-byte TCP window field in an outgoing header.
WRITE_TUNE_WINDOW
	LD	A,(TCP_TUNE_EDGE+3)
	LD	C,A
	LD	A,(TCP_RCV_NXT+3)
	LD	B,A
	LD	A,C
	SUB	B
	LD	C,A
	LD	A,(TCP_TUNE_EDGE+2)
	LD	H,A
	LD	A,(TCP_RCV_NXT+2)
	LD	B,A
	LD	A,H
	SBC	A,B
	LD	(DE),A
	INC	DE
	LD	A,C
	LD	(DE),A
	INC	DE
	RET
	ENDIF

SEND_DUP_ACK
	CALL	BUILD_ACK
	JP	XMIT_TX_BUF


; ------------------------------------------------------
; BUILD_ACK: build pure ACK (20-byte TCP, no payload).
; Sets TCP_TX_LEN.
; ------------------------------------------------------
BUILD_ACK
	; TCP segment length = 20.
	LD	BC,20
	CALL	BUILD_ETH_IP
	; --- TCP header ---
	IFDEF	UNET_DLL
	CALL	BUILD_TCP_PORTS_SEQ
	ELSE
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
	CALL	COPY_SEQ32
	ENDIF
	; ack
	LD	HL,TCP_RCV_NXT
	CALL	COPY_SEQ32
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
	IFDEF UNET_DLL
	CALL	WRITE_RX_WINDOW
	ELSE
	IFDEF USE_TCP_MULTICHAN
	LD	A,(TCP_ADV_WIN_HI)
	LD	(DE),A
	INC	DE
	LD	A,(TCP_ADV_WIN_LO)
	LD	(DE),A
	INC	DE
	ELSE
	IFDEF USE_TCP_RX_TUNE
	CALL	WRITE_TUNE_WINDOW
	ELSE
	LD	A,TCP_RECV_WIN_HI
	LD	(DE),A
	INC	DE
	LD	A,TCP_RECV_WIN_LO
	LD	(DE),A
	INC	DE
	ENDIF
	ENDIF
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
	CALL	COPY_SEQ32
	LD	HL,TCP_REMOTE_IP
	CALL	COPY_SEQ32
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
	JP	FAIL_A
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
	JP	FAIL_A
.COMMIT_OTHER
	CALL	COMMIT_RX
	IFDEF USE_ARP_ANSWER
	CALL	@ARP.ANSWER_REQUEST
	ENDIF
	JP	.TICK
.COMMIT_PEER
	CALL	COMMIT_RX
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
	JP	FAIL_A
.CANCEL
	LD	A,F_CANCEL
	JP	FAIL_A


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


	IFDEF	USE_TCP_LISTEN
; ------------------------------------------------------
; GEN_ISN: draw a fresh initial sequence number into TCP_SND_NXT and
; mirror it to TCP_SND_UNA.  Shared by OPEN's per-attempt draw (its
; IFDEF USE_TCP_LISTEN branch) and LISTEN_POLL's passive open; OPEN
; additionally derives its ephemeral port from the stirred salt this
; returns, LISTEN's local port is fixed by LISTEN_INIT instead.
;   Out: HL = the stirred TCP_PORT_SALT value.
; Trashes A, BC, DE.
; ------------------------------------------------------
GEN_ISN
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
	LD	A,R
	LD	(TCP_SND_NXT + 0),A
	LD	A,H
	LD	(TCP_SND_NXT + 1),A
	LD	A,L
	LD	(TCP_SND_NXT + 2),A
	LD	A,R
	LD	(TCP_SND_NXT + 3),A
	; Mirror to SND_UNA, preserving the salt in HL for OPEN.
	PUSH	HL
	LD	HL,TCP_SND_NXT
	LD	DE,TCP_SND_UNA
	CALL	COPY_SEQ32
	POP	HL
	RET


; ------------------------------------------------------
; IS_TCP_SYN_TO_LPORT: filter RX_BUF for an unsolicited IPv4/TCP SYN
; (SYN set, ACK/RST/FIN clear) addressed to TCP_LOCAL_PORT.  Unlike
; IS_TCP_FROM_PEER this does not check the source tuple -- ST_LISTEN
; has no peer yet; this segment is what establishes one.
;   Out: CF=1 if match; CF=0 otherwise.
; ------------------------------------------------------
IS_TCP_SYN_TO_LPORT
	LD	A,(@MAIN.RX_BUF + 12)
	CP	HIGH ETH_TYPE_IPV4
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 13)
	CP	LOW ETH_TYPE_IPV4
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14)
	CP	0x45
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + 9)
	CP	IP_PROTO_TCP
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 2)		; dst port
	LD	HL,TCP_LOCAL_PORT_HI
	CP	(HL)
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 3)
	INC	HL
	CP	(HL)
	JR	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 13)	; flags
	AND	(TF_RST | TF_SYN | TF_ACK | TF_FIN)
	CP	TF_SYN
	JR	NZ,.NO
	SCF
	RET
.NO
	OR	A
	RET


; ------------------------------------------------------
; LISTEN_INIT: arm a fresh passive-open TCB on port HL (host order,
; 1..65535).  Caller (unetrtl.asm) has already verified the channel
; is closed.  Also the re-arm path: closing an accepted connection
; calls this again with the same port.
; ------------------------------------------------------
LISTEN_INIT
	XOR	A
	LD	(TCP_LAST_FAIL),A
	LD	(RECV_UNACKED),A
	IFDEF	USE_TCP_RELIABLE_SEND
	LD	(TCP_ACK_WAIT_STATE),A
	ENDIF
	LD	A,H
	LD	(TCP_LOCAL_PORT_HI),A
	LD	A,L
	LD	(TCP_LOCAL_PORT_LO),A
	LD	A,ST_LISTEN
	LD	(TCP_STATE),A
	RET


; ------------------------------------------------------
; LISTEN_POLL: progress a passive-open channel by one bounded poll.
; ST_LISTEN: accept an unsolicited SYN to TCP_LOCAL_PORT (fills
;   TCP_REMOTE_IP/MAC/PORT and TCP_RCV_NXT from it), reply with a
;   SYN+ACK, and move to ST_SYN_RCVD.  ST_SYN_RCVD: a duplicate SYN
;   re-sends the SAME SYN+ACK (idempotent, same ISN); RST drops back
;   to ST_LISTEN; the final ACK completes the handshake (ST_ESTAB).
;   A data- or FIN-bearing final ACK is left UNCOMMITTED at the ring
;   head instead of being consumed here, so the normal established-
;   connection RECV path delivers its payload in order -- reprocessing
;   the ACK field there is idempotent (SND_UNA already equals it).
; Foreign frames follow WAIT_SYN_ACK's multichan etiquette. Budget is
; decrement-before-tick (RECV's shape): a non-blocking poll against
; an idle ring costs nothing.
;   In: TCP_TIMEOUT_LEFT already set by the caller (RECV-style budget).
;   Out: CF=0 A=0 idle (budget spent, nothing progressed);
;        CF=0 A=1 accepted (TCP_STATE==ST_ESTAB; caller re-reads via
;                  the normal RECV path for any uncommitted payload);
;        CF=1 fail (TCP_LAST_FAIL: F_CANCEL, F_SEND, F_OTHER).
; Requires USE_TCP_MULTICHAN (PEEK_PACKET/COMMIT_PACKET/
; HANDLE_FOREIGN_FRAME) -- always true, UNETRTL.DLL is the only
; definer of USE_TCP_LISTEN and always sets both.
; ------------------------------------------------------
LISTEN_POLL
.LP
	CALL	@RTL.RING_HAS_PACKET
	JR	NZ,.HAVE
.TICK
	LD	HL,(TCP_TIMEOUT_LEFT)
	DEC	HL
	LD	(TCP_TIMEOUT_LEFT),HL
	LD	A,H
	OR	L
	JR	Z,.IDLE
	CALL	@MAIN.TICK_AND_CHECK_KEY
	JP	C,.CANCEL
	JR	.LP
.IDLE
	XOR	A
	RET
.HAVE
	LD	HL,@MAIN.RX_HDR
	LD	DE,@MAIN.RX_BUF
	LD	BC,@MAIN.RX_BUF_SIZE
	CALL	@RTL.PEEK_PACKET
	JR	C,.TICK
	LD	A,(TCP_STATE)
	CP	ST_SYN_RCVD
	JP	Z,.RCVD
	; -- ST_LISTEN: look for an unsolicited SYN to our port --
	CALL	IS_TCP_SYN_TO_LPORT
	JR	C,.GOT_SYN
	CALL	.HANDLE_FOREIGN
	RET	C
	JP	.TICK
.GOT_SYN
	CALL	COMMIT_RX
	LD	HL,@MAIN.RX_BUF + 6			; Ethernet src MAC
	LD	DE,TCP_REMOTE_MAC
	LD	BC,6
	LDIR
	LD	HL,@MAIN.RX_BUF + 14 + 12		; IP src
	LD	DE,TCP_REMOTE_IP
	CALL	COPY_SEQ32
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + 0	; TCP src port
	LD	DE,TCP_REMOTE_PORT_HI
	LD	BC,2
	LDIR
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + 4	; seq (BE)
	LD	DE,TCP_RCV_NXT
	CALL	COPY_SEQ32
	LD	DE,TCP_RCV_NXT
	CALL	INC_SEQ32
	CALL	GEN_ISN			; SND_NXT = SND_UNA = ISN
	; The final ACK that completes the handshake acks ISN+1 (our SYN
	; consumes one sequence number), so keep SND_UNA one ahead for
	; .CMPACK below.  SND_NXT stays at ISN while in ST_SYN_RCVD so a
	; duplicate-SYN resend (see .RCVD) rebuilds the SAME SYN+ACK;
	; .ACCEPTED advances it once the handshake completes.
	LD	DE,TCP_SND_UNA
	CALL	INC_SEQ32
.SEND_SYNACK
	CALL	BUILD_SYN.SYNACK_ENTRY
	CALL	XMIT_TX_BUF
	JR	C,.SYNACK_FAIL
	LD	A,ST_SYN_RCVD
	LD	(TCP_STATE),A
	JP	.TICK
.SYNACK_FAIL
	JP	FAIL_SEND
.RCVD
	; -- ST_SYN_RCVD: wait for the final ACK from the SAME peer.  A
	; duplicate SYN (the peer never saw our SYN+ACK) re-sends the
	; SAME-ISN SYN+ACK -- see .CHK_ACK; RST drops back to ST_LISTEN;
	; any other non-ACK segment is dropped. --
	CALL	IS_TCP_FROM_PEER
	JR	C,.PEER_SEG
	CALL	.HANDLE_FOREIGN
	RET	C
	JP	.TICK
.PEER_SEG
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 13)	; flags
	LD	B,A
	AND	TF_RST
	JR	Z,.CHK_ACK
	CALL	COMMIT_RX
	LD	A,ST_LISTEN
	LD	(TCP_STATE),A
	JP	.TICK
.CHK_ACK
	LD	A,B
	AND	TF_ACK
	JR	NZ,.HAS_ACK
	; No ACK: a duplicate SYN means our SYN+ACK was lost in transit --
	; commit it and re-send the SAME-ISN SYN+ACK (SND_NXT still holds
	; the ISN, RCV_NXT the peer's seq+1: a true retransmission carries
	; the same peer ISN, and a genuinely NEW attempt with a different
	; one gets a stale ack it answers with RST, which resets us to
	; ST_LISTEN for its next SYN).  Anything else without ACK: drop.
	LD	A,B
	AND	TF_SYN
	JR	Z,.DROP
	CALL	COMMIT_RX
	JP	.SEND_SYNACK
.HAS_ACK
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + 8		; ack BE
	LD	DE,TCP_SND_UNA
	LD	B,4
.CMPACK
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.DROP
	INC	DE
	INC	HL
	DJNZ	.CMPACK
	; Accepted.  Commit only a payload-free, non-FIN final ACK here;
	; anything else is left at the ring head for the normal RECV path.
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 12)
	AND	0xF0
	RRCA
	RRCA					; A = data_offset * 4
	LD	C,A
	LD	B,0
	LD	A,(@MAIN.RX_BUF + 14 + 2)
	LD	H,A
	LD	A,(@MAIN.RX_BUF + 14 + 3)
	LD	L,A				; HL = IP total length
	LD	DE,IP_HDR_LEN
	OR	A
	SBC	HL,DE
	OR	A
	SBC	HL,BC				; HL = segment payload length
	LD	A,H
	OR	L
	JR	NZ,.ACCEPTED
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 13)
	AND	TF_FIN
	JR	NZ,.ACCEPTED
	CALL	COMMIT_RX
.ACCEPTED
	; Our SYN consumed one sequence number: advance SND_NXT to ISN+1
	; (SND_UNA is already there, see .GOT_SYN) so the first byte we
	; send is numbered where the peer expects it.
	LD	DE,TCP_SND_NXT
	CALL	INC_SEQ32
	LD	A,ST_ESTAB
	LD	(TCP_STATE),A
	LD	A,1
	RET
.DROP
	CALL	COMMIT_RX
	JP	.TICK
.CANCEL
	LD	A,F_CANCEL
	JP	FAIL_A
; Shared by both ST_LISTEN and ST_SYN_RCVD's "not ours" exit: queue
; or drop a frame belonging to the other channel, matching
; WAIT_SYN_ACK's multichan etiquette.
;   Out: CF=0 -> caller should JP .TICK; CF=1 -> propagate to the
;        caller of LISTEN_POLL (F_OTHER already set).
.HANDLE_FOREIGN
	LD	A,1				; caller protocol = TCP
	CALL	@UNET.HANDLE_FOREIGN_FRAME
	JR	NC,.HF_COMMIT
	OR	A
	JR	Z,.HF_OK
	LD	A,F_OTHER
	JP	FAIL_A
.HF_COMMIT
	CALL	COMMIT_RX
	CALL	@ARP.ANSWER_REQUEST
.HF_OK
	OR	A
	RET
	ENDIF

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
; UNET saves peer data through its pre-ACK sink, including on AGAIN/error.
; Other reliable-send builds keep ACK_WAIT_RX_PENDING in RX_BUF until the
; caller drains it through RECV.
;   In:  HL = data ptr, BC = length (1..outbound chunk size 536).
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
	JP	FAIL_A
.READY
	; Save the first sequence and calculate the cumulative ACK target.
	LD	HL,TCP_SND_NXT
	LD	DE,TCP_SEND_SEQ
	CALL	COPY_SEQ32
	LD	HL,TCP_SEND_SEQ
	LD	DE,TCP_ACK_WAIT_TARGET
	CALL	COPY_SEQ32
	LD	BC,(.SAVE_LEN)
	LD	DE,TCP_ACK_WAIT_TARGET
	CALL	ADD32_BE_BC
	LD	A,SEND_ATTEMPTS
	LD	(TCP_SEND_RETRY_LEFT),A
.TRY
	IFDEF	USE_TCP_ASYNCSEND
	; Fresh per-attempt silence budget.  USE_TCP_ASYNCSEND slices this
	; into smaller waits (see .WAIT_ACK); reaching zero is what lets a
	; retry/retransmit happen, exactly as SEND_ACK_TIMEOUT_MS alone
	; used to gate it.
	LD	HL,SEND_ACK_TIMEOUT_MS
	LD	(TCP_ATTEMPT_MS_LEFT),HL
	ENDIF
	; BUILD_DATA reads TCP_SND_NXT.  Put the original sequence there
	; for the build, then restore the post-segment value before the
	; frame goes on the wire.  Every retry therefore carries the same
	; sequence number and is safely de-duplicated by the peer.
	IFDEF UNET_DLL
	CALL	.REWIND_SEND
	ELSE
	CALL	.RESTORE_SEQ
	ENDIF
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
	CALL	XMIT_TX_BUF
	ENDIF
	JR	NC,.WAIT_ACK
	; A transmit failure proves nothing about EARLIER attempts of this
	; same segment.  Rewinding SND_NXT to SND_UNA is right only when no
	; attempt ever left the NIC; after a retransmit failure the first
	; copy may well have reached the peer, and rewinding would make
	; CLOSE read the stream as fully acknowledged and send a FIN at an
	; obsolete sequence number -- exactly the peer-keeps-the-request
	; failure the dual-RST abort exists to prevent.  RETRY_LEFT is
	; decremented only at .ATTEMPT_EXHAUSTED, so it still equals
	; SEND_ATTEMPTS here if and only if this was the first attempt.
	LD	A,(TCP_SEND_RETRY_LEFT)
	CP	SEND_ATTEMPTS
	CALL	Z,.RESTORE_SEQ		; only the first attempt never left the NIC
	XOR	A
	LD	(TCP_ACK_WAIT_STATE),A
	JP	FAIL_SEND
.WAIT_ACK
	LD	A,ACK_WAIT_ACTIVE
	LD	(TCP_ACK_WAIT_STATE),A
	IFDEF	USE_TCP_ASYNCSEND
	; Quantum for this wait: the whole remaining attempt budget when
	; blocking (@UNET.OPT_SLICE=0, byte-identical to the pre-ASYNCSEND
	; behavior below), or the smaller of the remaining budget and the
	; slice when the caller armed UNET_OPT_SENDSLICE.
	LD	HL,(TCP_ATTEMPT_MS_LEFT)
	LD	DE,(@UNET.OPT_SLICE)
	LD	A,D
	OR	E
	JR	Z,.QUANTUM_READY
	OR	A
	SBC	HL,DE
	JR	C,.RESTORE_BUDGET
	EX	DE,HL
	JR	.QUANTUM_READY
.RESTORE_BUDGET
	ADD	HL,DE
.QUANTUM_READY
	LD	(.QUANTUM),HL
	ELSE
	LD	HL,SEND_ACK_TIMEOUT_MS
	ENDIF
	LD	(RECV_TIMEOUT),HL
	CALL	RECV
	JR	C,.WAIT_FAIL
	; A pure ACK returns BC=0.  Payload piggybacked on the ACK is
	; already published through TCP_RX_DATA_PTR/LEN by RECV.
	CALL	ACK_TARGET_MATCH
	JR	NZ,.UNACKED_DATA
	IFNDEF UNET_DLL
	LD	A,B
	OR	C
	LD	A,ACK_WAIT_IDLE
	JR	Z,.SET_WAIT_STATE
	LD	A,ACK_WAIT_RX_PENDING
.SET_WAIT_STATE
	ELSE
	XOR	A
	ENDIF
	LD	(TCP_ACK_WAIT_STATE),A
	XOR	A
	LD	(TCP_LAST_FAIL),A
	OR	A
	RET
.WAIT_FAIL
	IFDEF UNET_DLL
	CALL	ACK_TARGET_MATCH
	JR	NZ,.UNCONFIRMED
	XOR	A
	LD	(TCP_ACK_WAIT_STATE),A
	LD	(TCP_LAST_FAIL),A
	RET
.UNCONFIRMED
	ENDIF
	XOR	A
	LD	(TCP_ACK_WAIT_STATE),A
	LD	A,(TCP_LAST_FAIL)
	CP	F_TIMEOUT
	JR	NZ,.FATAL
	IFDEF	USE_TCP_ASYNCSEND
	; Consume the quantum just waited from this attempt's budget.  RECV
	; only returns F_TIMEOUT after waiting its full requested
	; RECV_TIMEOUT, so .QUANTUM is exactly the elapsed silence.
	LD	HL,(TCP_ATTEMPT_MS_LEFT)
	LD	DE,(.QUANTUM)
	OR	A
	SBC	HL,DE
	LD	(TCP_ATTEMPT_MS_LEFT),HL
	LD	A,H
	OR	L
	JR	Z,.ATTEMPT_EXHAUSTED	; whole attempt budget spent: fall
					; into the existing retry ladder below
	; Silence within the attempt but budget remains: suspend without
	; burning a retry or retransmitting.  SEND_RESUME re-enters
	; .WAIT_ACK directly for this same outstanding segment.
	LD	A,F_AGAIN
	JP	FAIL_A
.ATTEMPT_EXHAUSTED
	ENDIF
	LD	A,(TCP_SEND_RETRY_LEFT)
	DEC	A
	LD	(TCP_SEND_RETRY_LEFT),A
	; USE_TCP_ASYNCSEND's extra code between here and .TRY pushes the
	; back-branch out of JR range; plain USE_TCP_RELIABLE_SEND builds
	; (dldirect/dldircp) keep the shorter JR unchanged.
	IFDEF	USE_TCP_ASYNCSEND
	JP	NZ,.TRY
	ELSE
	JR	NZ,.TRY
	ENDIF
	; Keep SND_NXT and SND_UNA at the first unacknowledged byte on
	; failure.  A caller that elects to
	; retry the same application write will therefore fill the same
	; TCP sequence hole rather than creating an unrecoverable new one.
	IFNDEF UNET_DLL
	CALL	.RESTORE_SEQ
	ENDIF
	LD	A,F_TIMEOUT
	JP	FAIL_A
.FATAL
	; RST/cancel/ACK-transmit failures terminate the attempt.  Restore
	; the unacknowledged sequence for a consistent local state.
	IFNDEF UNET_DLL
	CALL	.RESTORE_SEQ
	ENDIF
	SCF
	RET
.UNACKED_DATA
	IFDEF UNET_DLL
	JP	.WAIT_ACK
	ELSE
	; Full-duplex peer data with an ACK below our target is retained,
	; but RX_BUF cannot be reused for a further ACK wait until the caller
	; drains it.  Report a bounded protocol failure instead of silently
	; overwriting the peer data or claiming this send was acknowledged.
	LD	A,ACK_WAIT_RX_PENDING
	LD	(TCP_ACK_WAIT_STATE),A
	CALL	.RESTORE_SEQ
	LD	A,F_BAD_SEG
	JP	FAIL_A
	ENDIF
.RESTORE_SEQ
	IFDEF UNET_DLL
	LD	HL,TCP_SND_UNA
	JR	.COPY_SEQ
.REWIND_SEND
	LD	HL,TCP_SEND_SEQ
.COPY_SEQ
	LD	DE,TCP_SND_NXT
	JP	COPY_SEQ32
	ELSE
	LD	HL,TCP_SEND_SEQ
	LD	DE,TCP_SND_NXT
	CALL	COPY_SEQ32
	LD	HL,TCP_SEND_SEQ
	LD	DE,TCP_SND_UNA
	CALL	COPY_SEQ32
	RET
	ENDIF
.RESTORE_TARGET
	LD	HL,TCP_ACK_WAIT_TARGET
	LD	DE,TCP_SND_NXT
	JP	COPY_SEQ32
	ELSE
	; Compact legacy path for size-constrained stand-alone clients.
	; UNETRTL defines USE_TCP_RELIABLE_SEND and does not use this path.
	CALL	BUILD_DATA
	CALL	XMIT_TX_BUF
	JR	NC,.BEST_EFFORT_OK
	JP	FAIL_SEND
.BEST_EFFORT_OK
	LD	BC,(.SAVE_LEN)
	LD	DE,TCP_SND_NXT
	CALL	ADD32_BE_BC
	OR	A
	RET
	ENDIF
.SAVE_LEN	DW 0
.SAVE_DATA	DW 0
	IFDEF	USE_TCP_ASYNCSEND
.QUANTUM	DW 0
	ENDIF


; ------------------------------------------------------
; SEND_RESUME: continue a SEND transaction that suspended with
; F_AGAIN.  Same contract as SEND (In: HL = data ptr, BC = length --
; the SAME data/length the suspended SEND was called with).  The
; segment already on the wire is NOT retransmitted; only the ACK
; wait continues, so a resume can never duplicate stream bytes.
; TCP_SEND_SEQ/TCP_ACK_WAIT_TARGET/TCP_SEND_RETRY_LEFT/
; TCP_ATTEMPT_MS_LEFT are exactly as SEND left them.
;   Out: CF=0 ok; CF=1 fail (TCP_LAST_FAIL holds reason, F_AGAIN
;        included -- the caller may need to suspend again).
; ------------------------------------------------------
	IFDEF	USE_TCP_ASYNCSEND
SEND_RESUME
	LD	(SEND.SAVE_LEN),BC
	LD	(SEND.SAVE_DATA),HL
	JP	SEND.WAIT_ACK
	ENDIF


	IFDEF USE_TCP_RELIABLE_SEND
; ------------------------------------------------------
; ACK_TARGET_MATCH: ZF=1 when SND_UNA reached the target of
; the active SEND.  Preserves all registers and CF is irrelevant.
; ------------------------------------------------------
	IFDEF UNET_DLL
; ------------------------------------------------------
; SND_UNA_IS_NXT: ZF=1 when nothing we transmitted is still
; unacknowledged.  The standard TCP invariant, and CLOSE's test for
; whether an orderly FIN is meaningful at all.  Same contract as
; ACK_TARGET_MATCH below: all registers preserved, CF irrelevant.
; ------------------------------------------------------
SND_UNA_IS_NXT
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	DE,TCP_SND_NXT
	JR	ACK_TARGET_MATCH.CMP
	ENDIF
ACK_TARGET_MATCH
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	DE,TCP_ACK_WAIT_TARGET
.CMP
	LD	HL,TCP_SND_UNA
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
	IFDEF UNET_DLL
; ACK is independent of incoming payload capacity/sequence. Ignore stale
; or future ACKs; signed modulo-32 differences also handle sequence wrap.
UPDATE_SEND_ACK
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + 11
	LD	DE,TCP_SND_UNA+3
	CALL	.ACK_DIFF
	RET	M
	LD	HL,TCP_SND_NXT+3
	LD	DE,@MAIN.RX_BUF + 14 + IP_HDR_LEN + 11
	CALL	.ACK_DIFF
	RET	M
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + 8
	LD	DE,TCP_SND_UNA
	CALL	COPY_SEQ32
	RET
.ACK_DIFF
	LD	B,4
	OR	A
.loop
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	SBC	A,C
	DEC	HL
	DEC	DE
	DJNZ	.loop
	RET
	ENDIF

RECV
	IFNDEF UNET_DLL
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
	ENDIF
	IFDEF USE_TCP_RX_OOO
	; A filled hole may make an already-buffered segment contiguous.  Always
	; expose that byte range before asking the NIC for another frame.
	CALL	@TCP_OOO.DELIVER
	JR	C,.OOO_EMPTY
	LD	A,(TCP_STATE)
	CP	ST_CLOSE_WAIT
	JR	Z,.OOO_FIN
	OR	A
	RET
.OOO_FIN
	SCF
	RET
.OOO_EMPTY
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
	JP	FAIL_A
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
	IFDEF USE_TCP_RX_OOO
	LD	(.FRAME_LEN),BC
	ENDIF
	CALL	IS_TCP_FROM_PEER
	IFDEF USE_TCP_MULTICHAN
	JR	C,.COMMIT_PEER
	LD	A,1			; caller protocol = TCP
	CALL	@UNET.HANDLE_FOREIGN_FRAME
	JR	NC,.COMMIT_OTHER
	; Foreign frame consumed (saved prefix, any unaccepted tail re-ACKed).  Go to .TICK, NOT
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
	CALL	COMMIT_RX
	IFDEF USE_ARP_ANSWER
	CALL	@ARP.ANSWER_REQUEST	; see WAIT_SYN_ACK for rationale
	ENDIF
	JP	.TICK
.COMMIT_PEER
	CALL	COMMIT_RX
	JR	.PEER_SEG
	ELSE
	JR	C,.PEER_SEG
	IFDEF USE_ARP_ANSWER
	CALL	@ARP.ANSWER_REQUEST	; see WAIT_SYN_ACK for rationale
	ENDIF
	JP	.TICK
	ENDIF
.PEER_SEG
	IFDEF USE_TCP_RX_OOO
	LD	BC,(.FRAME_LEN)
	CALL	@TCP_OOO.VALIDATE_FRAME
	JP	C,.BAD_FRAME
	ENDIF
	; Flags.
	LD	A,(@MAIN.RX_BUF + 14 + IP_HDR_LEN + 13)
	LD	(.FLAGS),A
	IFDEF UNET_DLL
	; Account for a valid cumulative ACK even when this segment also closes
	; the connection.  SEND's error return must still report confirmed bytes.
	AND	TF_ACK
	CALL	NZ,UPDATE_SEND_ACK
	LD	A,(.FLAGS)
	ENDIF
	; RST -> immediate fail.
	AND	TF_RST
	JR	Z,.NO_RST
	IFDEF USE_TCP_RX_OOO
	CALL	@TCP_OOO.RELEASE
	ENDIF
	LD	A,F_RST
	JP	FAIL_A
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
	IFNDEF UNET_DLL
	; If has ACK, copy ack number into SND_UNA.
	LD	A,(.FLAGS)
	AND	TF_ACK
	JR	Z,.NO_ACK
	LD	HL,@MAIN.RX_BUF + 14 + IP_HDR_LEN + 8	; ack BE
	LD	DE,TCP_SND_UNA
	CALL	COPY_SEQ32
.NO_ACK
	ENDIF
	; Publish the (possibly trimmed) payload.
	LD	HL,(.SEG_LEN)
	LD	(TCP_RX_DATA_LEN),HL
	LD	HL,(.SEG_PTR)
	LD	(TCP_RX_DATA_PTR),HL
	IFDEF UNET_DLL
	; Save only the sequential prefix that fits; never ACK unsaved bytes.
	CALL	@UNET.STORE_TCP_PAYLOAD
	LD	HL,(.SEG_LEN)
	LD	DE,(TCP_RX_DATA_LEN)
	OR	A
	SBC	HL,DE
	JR	Z,.STORED_ALL
	LD	HL,.FLAGS
	RES	0,(HL)		; FIN follows the unaccepted suffix
.STORED_ALL
	ENDIF
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
	IFDEF UNET_DLL
	CALL	@UNET.PEER_CLOSED
	ENDIF
.NO_FIN
	IFDEF USE_TCP_RX_OOO
	LD	A,(.FLAGS)
	AND	TF_FIN
	JR	Z,.OOO_PRUNE
	CALL	@TCP_OOO.RELEASE	; FIN is final; discard every later slot
	JR	.OOO_PRUNED
.OOO_PRUNE
	CALL	@TCP_OOO.PRUNE
.OOO_PRUNED
	ENDIF
		; Decide whether to ACK this segment now.  Force ACK on FIN
	; (state == CLOSE_WAIT here).  Otherwise apply delayed-ACK:
	; bump the unacked counter and skip the ACK so long as more
	; packets remain in the chip's RX ring AND the counter is
	; still below TCP_ACK_THRESH.  Drain-or-threshold flushes
	; the cumulative ACK -- the peer's send window then advances.
	LD	A,(TCP_STATE)
	CP	ST_CLOSE_WAIT
	JR	Z,.SEND_ACK
	IFDEF USE_TCP_MULTICHAN
		; The multichannel build's normal threshold is one: only the
		; scoped bit-7 path needs the counter-aware branch here.
		LD	A,(RECV_UNACKED)
		RLCA
		JR	NC,.SEND_ACK
		RRCA
	ELSE
		LD	A,(RECV_UNACKED)
		BIT	7,A
		JR	NZ,.DEFER_ACK
		INC	A
		LD	(RECV_UNACKED),A
		IFDEF USE_TCP_RX_TUNE
		LD	A,(TCP_TUNE_ACK_MODE)
		CP	TCP_ACK_THRESH
		ELSE
		CP	TCP_ACK_THRESH
		ENDIF
		JR	NC,.SEND_ACK
		CALL	@RTL.RING_HAS_PACKET
		JR	Z,.SEND_ACK		; ring empty -> flush ACK now
		; Skip ACK on this packet; keep counter for next iteration.
		JR	.AOK
	ENDIF
.DEFER_ACK
		; Public UNETRTL RECV sets bit 7 while it drains several
		; segments into the caller's buffer.  Keep the low seven bits
		; as the debt counter, but never let the ordinary threshold path
		; emit an ACK in the middle of that scoped drain.
		INC	A
		LD	(RECV_UNACKED),A
		JR	.AOK
.SEND_ACK
	IFDEF USE_TCP_RX_TUNE
		LD	HL,(TCP_RX_DATA_LEN)
		LD	A,H
		OR	L
		JR	NZ,.TUNE_GROW
		LD	A,(.FLAGS)
		AND	TF_FIN
		JR	NZ,.TUNE_GROW
		CALL	TUNE_KEEP_EDGE
		JR	.TUNE_READY
.TUNE_GROW
		CALL	TUNE_ADVANCE
.TUNE_READY
	ENDIF
		; Preserve the scoped-defer bit on a forced FIN ACK.  On a
		; transmit failure preserve the complete debt byte so the DLL
		; can retry its cumulative ACK on the next public RECV.
		CALL	BUILD_ACK
		CALL	XMIT_TX_BUF
		JR	C,.ACK_SEND_FAIL
		LD	A,(RECV_UNACKED)
		AND	0x80
		LD	(RECV_UNACKED),A
		JR	.AOK
.ACK_SEND_FAIL
	IFDEF USE_TCP_RX_TUNE
		CALL	TUNE_ROLLBACK
	ENDIF
		; Count the ACK that just failed as debt.  In the scoped drain this
		; turns a lone defer bit (for example FIN+data as the first segment)
		; into a flushable 0x81 instead of silently losing the retry.
		LD	HL,RECV_UNACKED
		INC	(HL)
		JP	FAIL_SEND
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
	IFDEF UNET_DLL
	LD	A,(TCP_ACK_WAIT_STATE)
	CP	ACK_WAIT_ACTIVE
	JP	Z,.TICK		; payload already durable, continue bounded ACK wait
	ENDIF
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
	IFDEF UNET_DLL
	; Stand-alone apps classify this return by TCP_STATE == ST_CLOSE_WAIT
	; and keep their historical LAST_FAIL values untouched; the DLL needs
	; a reason code because its SEND wait cannot ask "was the FIN mine?"
	; by state alone (the state survives the call that observed it).
	LD	A,F_CLOSED
	LD	(TCP_LAST_FAIL),A
	ENDIF
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
	IFDEF UNET_DLL
	JR	NZ,.NOT_EXACT
	LD	A,(.FLAGS)
	AND	TF_FIN
	JP	Z,.OUT_OF_ORDER
	LD	A,(TCP_STATE)
	CP	ST_CLOSE_WAIT
	JP	Z,.OUT_OF_ORDER
	OR	A			; equality accepted: no borrow
.NOT_EXACT
	ELSE
	JP	Z,.OUT_OF_ORDER			; exact duplicate
	ENDIF
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
	IFDEF USE_TCP_RX_OOO
		; STORE accepts only a future, complete, in-window segment and
		; never advances RCV_NXT.  A duplicate ACK below remains mandatory
		; for both saved and rejected arrivals.
		LD	HL,(.SEG_PTR)
		LD	BC,(.SEG_LEN)
		LD	A,(.FLAGS)
		CALL	@TCP_OOO.STORE
	ENDIF
		; A duplicate/out-of-order segment still gets an immediate ACK,
		; even inside a scoped drain.  Restore bit 7 afterwards so the
		; public caller can flush the remaining cumulative debt at exit.
		CALL	BUILD_ACK
		CALL	XMIT_TX_BUF		; best-effort; the next copy re-triggers
		JP	C,.TICK			; retain the complete scoped ACK debt
		LD	A,(RECV_UNACKED)
		AND	0x80
		LD	(RECV_UNACKED),A
	IFDEF UNET_DLL
		LD	HL,0
		LD	(TCP_RX_DATA_LEN),HL
		JP	.AOK
	ELSE
	JP	.TICK
	ENDIF
	IFDEF USE_TCP_RX_OOO
.BAD_FRAME
	LD	HL,TCP_OOO_BADFRAME
	CALL	@TCP_OOO.INC_SAT16
	LD	A,F_BAD_SEG
	JP	FAIL_A
	ENDIF
.CANCEL
	IFDEF USE_TCP_RX_OOO
	CALL	@TCP_OOO.RELEASE
	ENDIF
	LD	A,F_CANCEL
	JP	FAIL_A
.FLAGS		DB 0
.DATA_OFFSET	DB 0
.SEG_PTR	DW 0		; payload ptr/length of the segment being
.SEG_LEN	DW 0		; classified (trimmed on overlap)
.DELTA_LO	DW 0		; low 16 bits of RCV_NXT - seq
	IFDEF USE_TCP_RX_OOO
.FRAME_LEN	DW 0
	ENDIF

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
	IFDEF USE_TCP_RX_OOO
	CALL	@TCP_OOO.RELEASE
	ENDIF
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
	IFDEF UNET_DLL
	; Bytes we transmitted are still unacknowledged (SND_UNA !=
	; SND_NXT): a SEND was cancelled, or gave up, while its segment was
	; in flight, so whether the peer accepted it is unknowable from
	; here.  RFC 1122 4.2.2.13 calls that an ABORT, not an orderly
	; close, and FIN really is the wrong tool: sent at SND_UNA it is an
	; old duplicate if the peer took the segment, sent at SND_NXT it is
	; an out-of-order segment the peer queues without ever reaching
	; end-of-stream if it did not.  Either way the peer keeps waiting
	; for the rest of a request body that will never come, holding
	; whatever resource that request locked.  RST is accepted at
	; exactly one sequence number -- the peer's RCV_NXT -- and both
	; candidates for it are known here, so send one at each.
	CALL	SND_UNA_IS_NXT
	JR	NZ,.ABORT
	LD	A,TF_FIN | TF_ACK
	ENDIF
	; Send FIN+ACK.
	CALL	BUILD_FIN
	CALL	XMIT_TX_BUF
	JR	C,.XMIT_FAIL
	; Our FIN consumes 1 sequence number.
	LD	DE,TCP_SND_NXT
	CALL	INC_SEQ32
	IFDEF UNET_DLL
	; AWAIT_FIN_ACK owns the rest of the teardown: it waits for the
	; peer to acknowledge this FIN, retransmits while it does not, and
	; ends the session either way -- returning CF=1 when every attempt
	; went unanswered, so CLOSE never reports a clean close on the
	; strength of a FIN that merely reached the NIC.
	;
	; The old code went straight to CLOSED here, skipping any post-FIN
	; wait, because the drain it replaced read and DISCARDED ring
	; packets for ~3 s -- including packets belonging to the OTHER
	; session (FTP's "226 Transfer complete" on the control connection
	; arriving while the data connection was closing).  AWAIT_FIN_ACK
	; waits through RECV instead, which hands foreign frames to
	; HANDLE_FOREIGN_FRAME to be queued rather than dropped, so the
	; wait is safe to have back.  Builds without the multichannel
	; queues keep the one-shot teardown below.
	LD	A,ST_LAST_ACK
	LD	(TCP_STATE),A
	JP	AWAIT_FIN_ACK
	ELSE
	LD	A,ST_CLOSED
	LD	(TCP_STATE),A
	OR	A
	RET
	ENDIF
.XMIT_FAIL
	JP	FAIL_SEND
	IFDEF UNET_DLL
.ABORT
	; RST at SND_NXT first: TCP_SND_NXT is the source BUILD_FIN reads,
	; and the rewind below overwrites it with SND_UNA for the second.
	; Both transmissions are accounted for.  Only one of the two
	; sequence numbers is the peer's RCV_NXT, and which one it is is
	; exactly what cannot be known here, so a RST that never left the
	; NIC may well have been the one that would have been honoured --
	; report it rather than let the survivor vouch for both.
	CALL	.RST_AT_NXT
	PUSH	AF			; first RST's CF
	CALL	SEND.RESTORE_SEQ	; SND_NXT := SND_UNA
	CALL	.RST_AT_NXT
	LD	A,ST_CLOSED
	LD	(TCP_STATE),A		; LD does not disturb CF
	POP	BC			; C = flags pushed above
	JR	C,.XMIT_FAIL
	RR	C			; CF = the first RST's CF
	RET	NC
	JR	.XMIT_FAIL
.RST_AT_NXT
	LD	A,TF_RST | TF_ACK
	CALL	BUILD_FIN
	JP	XMIT_TX_BUF


; ------------------------------------------------------
; AWAIT_FIN_ACK (UNET_DLL): wait for the peer to acknowledge the FIN
; CLOSE just sent, retransmitting it up to CLOSE_ATTEMPTS times.
; RTL.SEND_FRAME only proves the NIC transmitted; a FIN lost on the
; wire leaves the peer holding the connection open, so the one-shot
; close used to report success while the server still waited for the
; rest of a request body.
;
; The wait runs through RECV so a frame belonging to the OTHER channel
; is queued by HANDLE_FOREIGN_FRAME instead of discarded.  On entry
; SND_NXT is already past the FIN, so SND_UNA == SND_NXT is exactly
; "our FIN was acknowledged" -- and SND_UNA is the FIN's own sequence
; number until then, which is what a retransmit rebuilds from.
;
; The session ends here whatever happens -- there is no local state
; left to retry from -- but the outcome is reported: CF=1 (LAST_FAIL =
; F_TIMEOUT) means every attempt was met with silence, i.e. the peer
; was never confirmed to have been told, and whatever the connection
; was holding stays held until its own idle timeout.  An RST, a peer
; FIN carrying the ACK, or the user cancelling all end the wait early
; and count as an answer: the peer is demonstrably alive and has seen
; our traffic.
; ------------------------------------------------------
AWAIT_FIN_ACK
	; Arm the same cumulative-ACK wait SEND uses, so RECV returns the
	; moment the ACK lands instead of sitting out the full timeout on
	; every healthy close: the FIN's target is SND_NXT, already past it.
	LD	HL,TCP_SND_NXT
	LD	DE,TCP_ACK_WAIT_TARGET
	CALL	COPY_SEQ32
	LD	A,ACK_WAIT_ACTIVE
	LD	(TCP_ACK_WAIT_STATE),A
	LD	A,CLOSE_ATTEMPTS
.ARM
	LD	(.LEFT),A
	LD	HL,CLOSE_ACK_TIMEOUT_MS
	LD	(RECV_TIMEOUT),HL
	CALL	RECV
	CALL	ACK_TARGET_MATCH
	JR	Z,.ANSWERED		; FIN acknowledged
	LD	A,(TCP_LAST_FAIL)
	CP	F_TIMEOUT
	JR	Z,.SILENT
	; The peer answered: an RST, a FIN of its own, or a segment whose
	; ACK does not cover ours yet.  It is alive and has seen our
	; traffic, so retransmitting into that is pointless.
	;
	; F_CANCEL and F_OTHER (5, 6) are the exceptions -- there the wait
	; stopped for a LOCAL reason and the peer said nothing at all.
	; F_CANCEL is the likely one: a consumer that armed CANCELKEYS and
	; whose user just cancelled a transfer still has that keypress in
	; the DSS buffer when it calls CLOSE, so the very first tick of
	; the wait ends it.  Calling that a confirmed close would report
	; success for a teardown the peer never saw, which is exactly the
	; failure this routine exists to make visible.
	CP	F_CANCEL
	JR	C,.ANSWERED
	CP	F_AGAIN
	JR	C,.UNANSWERED
.ANSWERED
	OR	A
	JR	.GONE
.SILENT
	LD	A,0
.LEFT	EQU $-1
	DEC	A
	JR	NZ,.RETRANSMIT
.UNANSWERED
	SCF			; TCP_LAST_FAIL names which of the two it was
.GONE
	; End the session on both outcomes, preserving the verdict across
	; the writes.  The ACK wait is disarmed here rather than in CLOSE
	; so that every exit clears it exactly once.
	PUSH	AF
	XOR	A
	LD	(TCP_ACK_WAIT_STATE),A
	LD	A,ST_CLOSED
	LD	(TCP_STATE),A
	POP	AF
	RET
.RETRANSMIT
	PUSH	AF
	; SND_UNA still holds the FIN's own sequence number -- rebuild from
	; it, then put SND_NXT back.  UPDATE_SEND_ACK discards any ACK
	; NEWER than SND_NXT, so leaving SND_NXT rewound to the FIN makes
	; the very acknowledgement this loop waits for unrecognisable.
	CALL	SEND.RESTORE_SEQ
	LD	A,TF_FIN | TF_ACK
	CALL	BUILD_FIN
	CALL	XMIT_TX_BUF
	LD	DE,TCP_SND_NXT
	CALL	INC_SEQ32
	POP	AF
	JR	.ARM
	ENDIF


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
	CALL	COPY_SEQ32
	LD	HL,TCP_RCV_NXT
	CALL	COPY_SEQ32
	LD	A,0x50			; data offset = 5 (20 bytes)
	LD	(DE),A
	INC	DE
	LD	A,TF_PSH | TF_ACK
	LD	(DE),A
	INC	DE
	IFDEF UNET_DLL
	CALL	WRITE_RX_WINDOW
	ELSE
	IFDEF USE_TCP_RX_TUNE
	CALL	WRITE_TUNE_WINDOW
	ELSE
	LD	A,TCP_RECV_WIN_HI
	LD	(DE),A
	INC	DE
	LD	A,TCP_RECV_WIN_LO
	LD	(DE),A
	INC	DE
	ENDIF
	ENDIF
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
; BUILD_FIN: TCP FIN+ACK segment (no payload), built at TCP_SND_NXT.
; UNET_DLL: A = the TCP flag byte, so the same builder emits CLOSE's
; orderly FIN+ACK and its RST+ACK abort (the two differ in one bit and
; nothing else).  Other builds always emit FIN+ACK and ignore A.
; ------------------------------------------------------
BUILD_FIN
	IFDEF	UNET_DLL
	LD	(.FLAGS),A
	ENDIF
	LD	BC,20
	CALL	BUILD_ETH_IP
	IFDEF	UNET_DLL
	CALL	BUILD_TCP_PORTS_SEQ
	ELSE
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
	CALL	COPY_SEQ32
	ENDIF
	LD	HL,TCP_RCV_NXT
	CALL	COPY_SEQ32
	LD	A,0x50
	LD	(DE),A
	INC	DE
	LD	A,TF_FIN | TF_ACK
	IFDEF	UNET_DLL
.FLAGS	EQU $-1				; caller's flag byte, see header
	ENDIF
	LD	(DE),A
	INC	DE
	IFDEF UNET_DLL
	CALL	WRITE_RX_WINDOW
	XOR	A
	ELSE
	IFDEF USE_TCP_RX_TUNE
	CALL	WRITE_TUNE_WINDOW
	XOR	A
	ELSE
	LD	A,TCP_RECV_WIN_HI
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	ENDIF
	ENDIF
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
