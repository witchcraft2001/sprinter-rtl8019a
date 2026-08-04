; ======================================================
; UNETRTL.DLL - RTL8019AS network backend for the UNET
; universal network API.  libman 1.3 / L1 relocatable library.
;
; Implements the frozen UNET contract in src/include/unet.inc on
; top of this kit's own driver and stack (rtl8019 / arp / dns /
; resolve / tcp / udp / icmp).  Function numbers, register ABI
; and NERR_* codes are identical to UNETESP.DLL, so one consumer
; binary drives either card: pick the DLL by name at run time.
;
; Build (see tools/build.sh):
;   sprinter-mkdll build src/dll/unetrtl.asm --format l1 --target 1.3 \
;     --assembler sjasmplus -I src/include -I src/lib \
;     --name "UNETRTL v0.2.20" --version 0.2 --no-compress \
;     -o build/UNETRTL.DLL
;
; The L1 header has a compact, encoded major.minor version plus a
; 15-byte human-readable name field.  tools/build.sh writes the full
; PACKAGE_VERSION into that field as `UNETRTL v<version>` so consumers
; can identify the exact DLL revision without decoding the header.
;
; --- Layout notes (read before editing) ---------------------------
;
; * Exactly ONE `ORG` may appear in this file, and it must be the
;   first one: sprinter-mkdll rewrites only the first ORG line it
;   finds, to 0x20 and 0x120 for the two relocation passes (the
;   32-byte L1 header precedes the code image).
; * The two passes must produce byte-identical LENGTHS; mkdll diffs
;   them to build the relocation bitmap.  Never make a DS or a
;   conditional depend on anything pass-sensitive.
; * Sizes must be literals, never a difference of two addresses -
;   in a relocatable image both operands get relocated.
; * The first bytes of the code image are the 24-entry JP table.
;   Dispatch is image_base + 0x20 + 3*function.
;
; --- Why the BSS lives INSIDE the image ---------------------------
;
; AGENTS.md forbids zero-filled buffers inside an .EXE, because
; `--raw` emits them to disk for nothing.  For a DLL the trade-off
; inverts and the rule is deliberately reversed here:
;
;   - libman relocates us into window 1 (0x4000) or window 2
;     (0x8000).  The kit's absolute BSS map (0xA000..0xAFFF) is
;     INSIDE window 2 - a DLL loaded there would write its own
;     state over its own code.
;   - libman packs several DLLs into one 16 KB page, so memory past
;     our declared image length may belong to another library.
;   - DSS paged memory is not an escape either: paged blocks map
;     through WIN0..WIN3, and WIN3 is the ISA window whenever the
;     driver is active.
;
; So all state is `DS n,0` inside the image, and memmap.inc is
; pointed at it via LIBBSS_CUSTOM.  A useful side effect: every
; l_load re-zeroes the whole thing from the file, so l_free +
; l_load is a guaranteed clean reset with no stale state.
;
; --- ISA window discipline ----------------------------------------
;
; @ISA.ISA_OPEN does DI and maps the card at 0xC000..0xFFFF;
; @ISA.ISA_CLOSE restores MMU3 and does EI.  ISA.IS_OPEN is a flag,
; not a nesting counter, so library-internal close/reopen pairs nest
; correctly inside our bracket.  EVERY UNET function returns with
; the window CLOSED and interrupts ENABLED.  Functions that only
; read the environment (GETCAPS, STATUS, GETINFO, LASTERR, SETOPT,
; RXPAUSE, RXRESUME) never open it at all - DSS lives in page 3,
; which the ISA window occupies.
;
; Window 3 is refused at load time for the same reason UNETESP
; refuses it: we would page ourselves out during every call.
; ======================================================

	DEFINE	UNET_DLL
	DEFINE	LIB_NO_CONSOLE		; no DSS_PCHARS / DSS_EXIT from libraries

; Library slices this DLL needs.  Deliberately NOT: USE_CMDL (the argv
; machinery and DIE_USAGE's print-and-exit -- we take only the
; USE_CMDL_PARSE slice, which resolve_lib needs for PARSE_IPV4),
; USE_FILE, USE_UTIL_EXIT*, USE_DHCP, USE_NETCFG_LOAD.
	DEFINE	USE_RTL_INIT_NORMAL
	DEFINE	USE_RTL_SEND_FRAME
	DEFINE	USE_RTL_WAIT_PTX
	DEFINE	USE_RTL_RING_HAS_PACKET
	DEFINE	USE_RTL_READ_PACKET
	DEFINE	USE_ARP_BUILD_REQUEST
	DEFINE	USE_ARP_ANSWER
	DEFINE	USE_NETENV
	DEFINE	USE_DNS
	DEFINE	USE_RESOLVE
	DEFINE	USE_TCP
	DEFINE	USE_TCP_RELIABLE_SEND	; bounded per-MSS ACK wait + retransmit
	DEFINE	USE_UDP
	DEFINE	USE_ICMP
	DEFINE	USE_UTIL_FORMAT
	DEFINE	USE_CMDL_PARSE		; resolve_lib calls CMDL.PARSE_IPV4
	DEFINE	USE_UTIL_PARSE_DEC_BYTE
	DEFINE	USE_UTIL_PARSE_HEX_BYTE

	INCLUDE "dss.inc"
	INCLUDE "sprinter.inc"
	INCLUDE "isa.inc"
	INCLUDE "rtl8019.inc"
	INCLUDE "unet.inc"

; Capability mask.  RXFLOW is CLEAR: the card buffers receive in its
; ~6.4 KB byte-mode ring, so RXPAUSE/RXRESUME are genuine no-ops here (unlike
; the ESP backend, where the consumer must honour them).
; MULTICHAN/LISTEN/TRANSPARENT are v1 gaps.  RAWETH stays clear even
; though the card can do it: slots 0..17 have no raw-frame entry
; point, and advertising a capability with nothing to call would be
; a lie.
UNETRTL_CAPS	EQU UNET_CAP_TCP | UNET_CAP_UDP | UNET_CAP_RESOLVE | UNET_CAP_PING

MAX_HOST_LEN	EQU 128			; matches UNETESP; also bounds the
MAX_PORT_LEN	EQU 15			; resolver's own scratch usage
TCP_MSS		EQU 536			; SEND chunk size, hidden by the ABI
LASTERR_SIZE	EQU 128

	ORG 0x0000			; the ONLY ORG; mkdll rewrites it

; ======================================================
; libman export table.  Entry N is at image_base + 0x20 + 3*N.
; ======================================================
	MODULE UNET

	JP	INIT			; 0  load hook
	JP	FINI			; 1  free hook
	JP	F_GETCAPS		; 2
	JP	F_NETINIT		; 3
	JP	F_NETDONE		; 4
	JP	F_CONNECT		; 5
	JP	F_SEND			; 6
	JP	F_RECV			; 7
	JP	F_CLOSE			; 8
	JP	F_STATUS		; 9
	JP	F_UDPOPEN		; 10
	JP	F_RESOLVE		; 11
	JP	F_PING			; 12
	JP	F_RXPAUSE		; 13
	JP	F_RXRESUME		; 14
	JP	F_GETINFO		; 15
	JP	F_LASTERR		; 16
	JP	F_SETOPT		; 17
	JP	F_NOTSUP		; 18 reserved
	JP	F_NOTSUP		; 19 reserved
	JP	F_NOTSUP		; 20 reserved
	JP	F_NOTSUP		; 21 reserved
	JP	F_NOTSUP		; 22 reserved
	JP	F_NOTSUP		; 23 reserved

	ENDMODULE

; ======================================================
; In-image BSS.  Placed immediately after the jump table so every
; symbol derived from it is a BACKWARD reference by the time
; memmap.inc and the libraries are assembled - no forward-referenced
; EQU chains for mkdll's two-pass byte diff to trip over.
;
; Offsets are literals on purpose (see the layout notes above).  The
; region sizes come from memmap.inc: LIBBSS_SIZE 0x176, resolve 0x29,
; tcp 0x32, udp 0x18, icmp 0x10.
; ======================================================
BSS_LIB		EQU 0x0000		; 0x176 util + rtl + netenv + rtl tx
BSS_RESOLVE	EQU 0x0176		; 0x029 resolve_lib
BSS_TCP		EQU 0x019F		; 0x032 tcp_lib
BSS_UDP		EQU 0x01D1		; 0x018 udp_lib
BSS_ICMP	EQU 0x01E9		; 0x010 icmp_lib
BSS_OUR_IP	EQU 0x01F9		; 4
BSS_OUR_MAC	EQU 0x01FD		; 6
BSS_CANCELLED	EQU 0x0203		; 1
BSS_LASTERR	EQU 0x0208		; 0x080 formatted diagnostic line
BSS_TX_BUF	EQU 0x0288		; 0x42A 1066 = 14+20+8+1024 (UDP cap)
BSS_RX_HDR	EQU 0x06B2		; 4     NE2000 RX ring header
BSS_RX_BUF	EQU 0x06B6		; 0x5EE 1518 = max Ethernet frame
DLL_BSS_SIZE	EQU 0x0CA4		; 3236 total

DLL_BSS
	DS	DLL_BSS_SIZE, 0

	DEFINE	LIBBSS_CUSTOM
LIBBSS_BASE		EQU DLL_BSS + BSS_LIB
CMDL_BSS_BASE		EQU DLL_BSS + BSS_LIB	; unused: the USE_CMDL_PARSE
						; slice is pure code, no BSS
RESOLVE_BSS_BASE	EQU DLL_BSS + BSS_RESOLVE
TCP_BSS_BASE		EQU DLL_BSS + BSS_TCP
UDP_BSS_BASE		EQU DLL_BSS + BSS_UDP
ICMP_BSS_BASE		EQU DLL_BSS + BSS_ICMP

	INCLUDE "memmap.inc"

; ======================================================
; The @MAIN contract the stack libraries compile against
; (see src/lib/resolve_lib.asm:48-57 and src/lib/tcp_lib.asm:31-36).
; In an EXE these come from the app; here the DLL supplies them.
; ======================================================
	MODULE MAIN

OUR_IP		EQU DLL_BSS + BSS_OUR_IP	; 4, from NET_IP
OUR_MAC		EQU DLL_BSS + BSS_OUR_MAC	; 6, from NET_MAC
CANCELLED	EQU DLL_BSS + BSS_CANCELLED	; 1
TX_BUF		EQU DLL_BSS + BSS_TX_BUF
RX_HDR		EQU DLL_BSS + BSS_RX_HDR
RX_BUF		EQU DLL_BSS + BSS_RX_BUF
RX_BUF_SIZE	EQU 1518

; ------------------------------------------------------
; TICK_AND_CHECK_KEY: ~1 ms pace + optional cancel poll, called
; from every wait loop in tcp_lib / resolve_lib / udp_lib / icmp_lib.
;
; The ISA window MUST be closed across the delay so the 50 Hz system
; interrupt is serviced (it runs from the page the window covers),
; and DSS_SCANKEY may remap page 3 outright.
;
; Unlike an EXE, a library never grabs the keyboard uninvited: the
; key poll happens only after the consumer asked for it with
; SETOPT CANCELKEYS.  Esc, Ctrl+C and Ctrl+Z are all accepted so a
; portable consumer behaves the same on the ESP and RTL backends.
;   Out: CF=0 continue; CF=1 cancelled (CANCELLED set).
;   Trashes A, BC, DE.
; ------------------------------------------------------
TICK_AND_CHECK_KEY
	CALL	@ISA.ISA_CLOSE			; window closed + EI, THEN delay
	CALL	@UTIL.DELAY_1MS
	LD	A,(UNET.CANCEL_MODE)
	OR	A
	JR	Z,.NO_KEY
	LD	C,DSS_SCANKEY
	RST	DSS
	JR	Z,.NO_KEY
	LD	A,E
	CP	0x1B				; Esc
	JR	Z,.CANCEL
	CP	0x07				; Ctrl+G (ESP backend's key)
	JR	Z,.CANCEL
	CP	0x03				; Ctrl+C (this kit's key)
	JR	Z,.CANCEL
	CP	0x1A				; Ctrl+Z
	JR	NZ,.NO_KEY
	LD	A,B
	AND	KB_CTRL | KB_L_CTRL | KB_R_CTRL
	JR	Z,.NO_KEY
.CANCEL
	LD	A,1
	LD	(CANCELLED),A
	CALL	@ISA.ISA_OPEN
	SCF
	RET
.NO_KEY
	CALL	@ISA.ISA_OPEN
	OR	A				; CF=0
	RET

	ENDMODULE

; ======================================================
; UNET function bodies
; ======================================================
	MODULE UNET

; ------------------------------------------------------
; Function 0 - INIT (libman load hook).
; libman propagates THIS function's carry as the load error, so it
; is the one place where CF is meaningful.  Learn our own window by
; popping the return address of a local CALL, and refuse window 3.
; ------------------------------------------------------
INIT
	CALL	.here
.here
	POP	HL				; HL = our real runtime address
	LD	A,H
	AND	0xC0
	LD	(WIN_BASE),A
	CP	0xC0
	JR	Z,.refuse
	XOR	A				; CF=0, A=0: loaded
	RET
.refuse
	LD	A,NERR_HW
	SCF
	RET

; ------------------------------------------------------
; Function 1 - FINI (libman free hook).
; ------------------------------------------------------
FINI
	CALL	CLOSE_LINK
	XOR	A
	RET

; ------------------------------------------------------
; Function 2 - GETCAPS.  Callable before NETINIT.
; ------------------------------------------------------
F_GETCAPS
	LD	DE,UNETRTL_CAPS
	LD	IX,UNET_ABI_VERSION
	XOR	A
	RET

; ------------------------------------------------------
; Function 3 - NETINIT.  Bring the card up.
; NERR_BUSY is never returned on this backend: there is no remote
; firmware that can still be warming up.
; ------------------------------------------------------
F_NETINIT
	XOR	A
	LD	(@MAIN.CANCELLED),A
	LD	A,ST_NETINIT
	LD	(STAGE),A
	CALL	CLOSE_LINK			; a repeated NETINIT is safe
	CALL	ENV_IS_UP
	JP	C,RET_NONET
	; NET_IP / NET_MAC into the @MAIN contract slots.
	LD	HL,ENVN_IP
	LD	DE,@MAIN.OUR_IP
	CALL	@NETENV.GET_IP
	JP	C,RET_NONET
	LD	HL,ENVN_MAC
	LD	DE,@MAIN.OUR_MAC
	CALL	@NETENV.GET_MAC
	JP	C,RET_NONET
	LD	HL,@MAIN.OUR_MAC
	LD	(@ARP.OUR_MAC_PTR),HL
	LD	HL,@MAIN.OUR_IP
	LD	(@ARP.OUR_IP_PTR),HL
	; Card.  INIT_BASE honours NET_RTL_HW, else auto-scans both ISA
	; slots; it leaves the window OPEN on success, CLOSED on failure.
	LD	A,1				; default slot ISA1, as the apps do
	LD	(@ISA.ISA_SLOT),A
	CALL	@RTL.INIT_BASE
	JP	C,RET_HW
	CALL	@RTL.RESET
	JR	C,.hw_fail
	LD	HL,@MAIN.OUR_MAC
	LD	A,RCR_AB
	CALL	@RTL.INIT_NORMAL
	CALL	CAPTURE_DIAG			; snapshot while the window is open
	CALL	@ISA.ISA_CLOSE
	LD	A,1
	LD	(INITED),A
	XOR	A
	LD	(LAST_NERR),A
	RET
.hw_fail
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	JP	RET_HW

; ------------------------------------------------------
; Function 8 - CLOSE / Function 4 - NETDONE (shared tail).
; ------------------------------------------------------
F_CLOSE
	AND	A
	JP	NZ,RET_PARAM			; v1: channel 0 only
F_NETDONE
	CALL	CLOSE_LINK
	XOR	A
	RET

; ------------------------------------------------------
; Function 5 - CONNECT (TCP).
; ------------------------------------------------------
F_CONNECT
	AND	A
	JP	NZ,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	A,ST_CONNECT
	LD	(STAGE),A
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE
	LD	A,(CH_STATE)
	AND	A
	JP	NZ,RET_STATE			; already open
	CALL	CHECK_HOST_PORT
	JP	C,RET_PARAM
	LD	HL,(ARG_IX)
	CALL	PARSE_U16			; port string -> HL
	JP	C,RET_PARAM
	LD	A,H
	OR	L
	JP	Z,RET_PARAM			; port 0 is not connectable
	LD	(ARG_PORT),HL
	XOR	A
	LD	(@MAIN.CANCELLED),A
	CALL	RESOLVE_AND_ARP			; ISA open .. close inside
	JP	C,MAP_RESOLVE_FAIL
	; Fill the tcp_lib session tuple.
	LD	HL,TARGET_IP
	LD	DE,TCP_REMOTE_IP
	LD	BC,4
	LDIR
	LD	HL,TARGET_MAC
	LD	DE,TCP_REMOTE_MAC
	LD	BC,6
	LDIR
	LD	HL,(ARG_PORT)
	LD	A,H
	LD	(TCP_REMOTE_PORT_HI),A
	LD	A,L
	LD	(TCP_REMOTE_PORT_LO),A
	XOR	A
	LD	(TCP_STATE),A			; force CLOSED before OPEN
	LD	(PEND_LEN),A
	LD	(PEND_LEN+1),A
	LD	(CLOSED_PEND),A
	CALL	@ISA.ISA_OPEN
	CALL	@TCP.OPEN
	JR	C,.fail
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	LD	A,1
	LD	(CH_STATE),A			; 1 = TCP
	XOR	A
	LD	(LAST_NERR),A
	RET
.fail
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	JP	MAP_TCP_FAIL

; ------------------------------------------------------
; Function 6 - SEND.
; TCP payloads are chunked at the MSS; the ABI hides that exactly
; as UNETESP hides its 2048-byte CIPSEND cap.  A UDP channel sends
; one datagram per call.
;   Out: DE = bytes actually sent, valid on the error paths too.
; ------------------------------------------------------
F_SEND
	AND	A
	JP	NZ,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	A,ST_SEND
	LD	(STAGE),A
	LD	A,(CH_STATE)
	AND	A
	JP	Z,RET_STATE
	CP	2
	JP	Z,.udp
	; -- TCP --
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	LD	HL,0
	LD	(SEND_DONE),HL
	CALL	@ISA.ISA_OPEN
.chunk
	LD	HL,(ARG_IX)
	LD	DE,(SEND_DONE)
	OR	A
	SBC	HL,DE				; HL = remaining
	LD	A,H
	OR	L
	JR	Z,.done
	LD	DE,TCP_MSS
	OR	A
	SBC	HL,DE				; CF=1 when remaining < MSS
	JR	C,.small
	LD	BC,TCP_MSS
	JR	.have
.small
	ADD	HL,DE				; restore remaining
	LD	B,H
	LD	C,L
.have
	LD	(CHUNK_LEN),BC
	LD	HL,(ARG_DE)
	LD	DE,(SEND_DONE)
	ADD	HL,DE
	LD	BC,(CHUNK_LEN)
	CALL	@TCP.SEND
	JR	C,.fail
	LD	HL,(SEND_DONE)
	LD	BC,(CHUNK_LEN)
	ADD	HL,BC
	LD	(SEND_DONE),HL
	JR	.chunk
.done
	CALL	@ISA.ISA_CLOSE
	LD	DE,(SEND_DONE)
	XOR	A
	LD	(LAST_NERR),A
	RET
.fail
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	CALL	MAP_TCP_SEND_FAIL		; A = NERR_*, CF=0
	LD	DE,(SEND_DONE)
	RET
.udp
	; One datagram; the cap is set by TX_BUF, not by the protocol.
	LD	HL,UDPLIB_MAX_PAYLOAD
	LD	DE,(ARG_IX)
	OR	A
	SBC	HL,DE
	JP	C,RET_PARAM
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	CALL	@ISA.ISA_OPEN
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	@UDP.SEND
	JR	C,.udp_fail
	CALL	@ISA.ISA_CLOSE
	LD	DE,(ARG_IX)
	XOR	A
	LD	(LAST_NERR),A
	RET
.udp_fail
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	LD	DE,0
	LD	A,NERR_SEND
	JP	RET_A

; ------------------------------------------------------
; Function 7 - RECV.
;
; A TCP segment larger than the caller's buffer is NOT dropped: the
; remainder stays in RX_BUF and is served from PEND_PTR on the next
; call with no NIC access, which is exactly what IX bit1 tells the
; caller.  Likewise a FIN that carried a final data segment delivers
; the data first and reports NERR_CLOSED on the following call, so
; the tail is never lost (the ABI guarantees this).
;
; IX bit0 (oversized datagram truncated) is set only on a UDP
; channel; bit2 (UART overrun) is always 0 - there is no UART here,
; so ESP-written consumers see a benign zero.
; ------------------------------------------------------
F_RECV
	AND	A
	JP	NZ,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	(ARG_IY),IY
	LD	A,ST_RECV
	LD	(STAGE),A
	LD	A,(CH_STATE)
	AND	A
	JP	Z,RET_STATE
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	LD	A,(CH_STATE)
	CP	2
	JP	Z,.udp
	; -- TCP: serve any pending remainder first, no NIC access --
	LD	HL,(PEND_LEN)
	LD	A,H
	OR	L
	JP	NZ,.serve_pending
	; A FIN seen last time with trailing data already delivered.
	LD	A,(CLOSED_PEND)
	AND	A
	JP	NZ,.report_closed
	XOR	A
	LD	(@MAIN.CANCELLED),A
	; IY = 0 would be read by tcp_lib as "use the 30 s default", so
	; clamp it: the ABI means "poll, do not block".
	LD	HL,(ARG_IY)
	LD	A,H
	OR	L
	JR	NZ,.have_to
	LD	HL,1
.have_to
	LD	(@TCP.RECV_TIMEOUT),HL
	CALL	@ISA.ISA_OPEN
	CALL	@TCP.RECV			; -> HL=data, BC=len
	JR	C,.rx_err
	CALL	@ISA.ISA_CLOSE
	LD	(PEND_PTR),HL
	LD	(PEND_LEN),BC
	JP	.serve_pending
.rx_err
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	LD	A,(TCP_STATE)
	CP	@TCP.ST_CLOSE_WAIT
	JR	Z,.peer_fin
	; Timeout is not an error at this layer: idle, link still alive.
	LD	A,(TCP_LAST_FAIL)
	CP	@TCP.F_TIMEOUT
	JR	Z,.idle
	CP	@TCP.F_CANCEL
	JR	Z,.cancelled
	CP	@TCP.F_RST
	JR	Z,.reset_by_peer
	CP	@TCP.F_SEND
	JR	Z,.hw
	LD	DE,0
	LD	IX,0
	LD	A,NERR_PROTO
	JP	RET_A
.hw
	; Our own ACK could not be transmitted: the NIC, not the peer.
	LD	DE,0
	LD	IX,0
	LD	A,NERR_HW
	JP	RET_A
.reset_by_peer
	XOR	A
	LD	(CH_STATE),A
	LD	DE,0
	LD	IX,0
	LD	A,NERR_CLOSED
	JP	RET_A
.idle
	LD	DE,0
	LD	IX,0
	XOR	A
	RET
.cancelled
	XOR	A
	LD	(@MAIN.CANCELLED),A
	LD	DE,0
	LD	IX,0
	LD	A,NERR_CANCEL
	JP	RET_A
.peer_fin
	; FIN, possibly carrying a last data segment.
	LD	A,1
	LD	(CLOSED_PEND),A
	LD	HL,(TCP_RX_DATA_LEN)
	LD	A,H
	OR	L
	JP	Z,.report_closed
	LD	(PEND_LEN),HL
	LD	HL,(TCP_RX_DATA_PTR)
	LD	(PEND_PTR),HL
	JP	.serve_pending
.report_closed
	XOR	A
	LD	(CLOSED_PEND),A
	LD	(CH_STATE),A
	LD	DE,0
	LD	IX,0
	LD	A,NERR_CLOSED
	JP	RET_A
.serve_pending
	; n = min(PEND_LEN, max)
	LD	HL,(PEND_LEN)
	LD	DE,(ARG_IX)
	OR	A
	SBC	HL,DE
	JR	C,.take_all
	JR	Z,.take_all
	LD	BC,(ARG_IX)
	JR	.copy_out
.take_all
	LD	BC,(PEND_LEN)
.copy_out
	LD	(COPY_LEN),BC
	LD	A,B
	OR	C
	JR	Z,.nothing
	LD	HL,(PEND_PTR)
	LD	DE,(ARG_DE)
	LDIR					; HL/DE advance past the copy
	LD	(PEND_PTR),HL
.nothing
	; PEND_LEN -= COPY_LEN
	LD	HL,(PEND_LEN)
	LD	DE,(COPY_LEN)
	OR	A
	SBC	HL,DE
	LD	(PEND_LEN),HL
	LD	IX,0
	LD	A,H
	OR	L
	JR	Z,.no_more
	LD	IX,2				; bit1: more data pending
.no_more
	LD	DE,(COPY_LEN)
	XOR	A
	LD	(LAST_NERR),A
	RET
.udp
	; -- UDP: one datagram per call --
	XOR	A
	LD	(@MAIN.CANCELLED),A
	CALL	@ISA.ISA_OPEN
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	LD	DE,(ARG_IY)
	; UNET defines IY=0 as a non-blocking poll.  udp_lib uses a
	; decrementing 16-bit budget, where zero would underflow to
	; 0xFFFF and wait about 65 seconds.  Match the TCP adapter:
	; inspect the ring once, then expire on its first 1 ms tick.
	LD	A,D
	OR	E
	JR	NZ,.udp_have_to
	INC	DE
.udp_have_to
	CALL	@UDP.RECV
	JR	C,.udp_err
	CALL	@ISA.ISA_CLOSE
	LD	IX,0
	LD	A,(UDPLIB_RX_FLAGS)
	AND	1
	JR	Z,.udp_ok
	LD	IX,1				; bit0: datagram was truncated
.udp_ok
	LD	DE,(UDPLIB_RX_LEN)
	XOR	A
	LD	(LAST_NERR),A
	RET
.udp_err
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	LD	IX,0
	LD	DE,0
	LD	A,(UDPLIB_LAST_FAIL)
	CP	@UDP.F_CANCEL
	JR	Z,.udp_cancel
	XOR	A				; timeout = idle, per the ABI
	RET
.udp_cancel
	XOR	A
	LD	(@MAIN.CANCELLED),A
	LD	A,NERR_CANCEL
	JP	RET_A

; ------------------------------------------------------
; Function 9 - STATUS.
; A=0xFF reports the network state WITHOUT touching the card, so a
; launcher can poll it cheaply.
; ------------------------------------------------------
F_STATUS
	CP	0xFF
	JR	Z,.netstat
	AND	A
	JP	NZ,RET_PARAM
	LD	A,(CH_STATE)
	AND	A
	JR	Z,.closed
	LD	DE,2				; connected
	XOR	A
	RET
.closed
	LD	DE,0
	XOR	A
	RET
.netstat
	CALL	ENV_IS_UP
	JR	C,.notup
	LD	DE,1				; bit0: configured
	LD	A,(INITED)
	AND	A
	JR	Z,.cfg
	LD	DE,3				; bit0 | bit1: NETINIT done
.cfg
	XOR	A
	RET
.notup
	LD	DE,0
	LD	A,NERR_NONET
	JP	RET_A

; ------------------------------------------------------
; Function 10 - UDPOPEN.
; ------------------------------------------------------
F_UDPOPEN
	AND	A
	JP	NZ,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	(ARG_IY),IY
	LD	A,ST_UDPOPEN
	LD	(STAGE),A
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE
	LD	A,(CH_STATE)
	AND	A
	JP	NZ,RET_STATE
	CALL	CHECK_HOST_PORT
	JP	C,RET_PARAM
	LD	HL,(ARG_IX)
	CALL	PARSE_U16			; remote port
	JP	C,RET_PARAM
	LD	A,H
	OR	L
	JP	Z,RET_PARAM
	LD	(ARG_PORT),HL
	; Optional local port string; 0 selects udp_lib's default.
	LD	HL,0
	LD	(ARG_LPORT),HL
	LD	HL,(ARG_IY)
	LD	A,H
	OR	L
	JR	Z,.no_lport
	LD	DE,MAX_PORT_LEN
	CALL	CHECK_STRARG
	JP	C,RET_PARAM
	LD	HL,(ARG_IY)
	CALL	PARSE_U16
	JP	C,RET_PARAM
	LD	(ARG_LPORT),HL
.no_lport
	XOR	A
	LD	(@MAIN.CANCELLED),A
	CALL	RESOLVE_AND_ARP
	JP	C,MAP_RESOLVE_FAIL
	LD	HL,TARGET_IP
	LD	DE,TARGET_MAC
	LD	BC,(ARG_PORT)
	LD	IY,(ARG_LPORT)
	CALL	@UDP.OPEN
	LD	A,2
	LD	(CH_STATE),A			; 2 = UDP
	XOR	A
	LD	(LAST_NERR),A
	RET

; ------------------------------------------------------
; Function 11 - RESOLVE.
; CAP_RESOLVE is set AND works on this backend: software DNS via
; dns_lib / resolve_lib.  Never NERR_NOTSUP (unlike UNETESP on
; firmware without AT+CIPDOMAIN).
; ------------------------------------------------------
F_RESOLVE
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	A,ST_RESOLVE
	LD	(STAGE),A
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE			; the resolver needs the NIC
	LD	HL,(ARG_DE)
	LD	DE,MAX_HOST_LEN
	CALL	CHECK_STRARG
	JP	C,RET_PARAM
	LD	HL,(ARG_IX)
	LD	BC,16
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	XOR	A
	LD	(@MAIN.CANCELLED),A
	CALL	@ISA.ISA_OPEN
	LD	HL,(ARG_DE)
	LD	DE,TARGET_IP
	CALL	@RESOLVE.HOST
	JR	C,.fail
	CALL	@ISA.ISA_CLOSE
	LD	HL,TARGET_IP
	LD	DE,(ARG_IX)
	CALL	@UTIL.FORMAT_IPV4
	XOR	A
	LD	(LAST_NERR),A
	RET
.fail
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	JP	MAP_RESOLVE_FAIL

; ------------------------------------------------------
; Function 12 - PING.
; DE returns an approximate round-trip time: this stack has no
; millisecond clock, so it is the poll-loop tick count consumed.
; A reply on the first drain pass reports 0.
; ------------------------------------------------------
F_PING
	LD	(ARG_DE),DE
	LD	(ARG_IY),IY
	LD	A,ST_PING
	LD	(STAGE),A
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE
	LD	HL,(ARG_DE)
	LD	DE,MAX_HOST_LEN
	CALL	CHECK_STRARG
	JP	C,RET_PARAM
	XOR	A
	LD	(@MAIN.CANCELLED),A
	CALL	RESOLVE_AND_ARP
	JP	C,MAP_RESOLVE_FAIL
	LD	HL,(ARG_IY)
	LD	A,H
	OR	L
	JR	NZ,.have_to
	LD	HL,1000				; sane default if the caller passed 0
.have_to
	PUSH	HL
	CALL	@ISA.ISA_OPEN
	POP	BC				; timeout ms
	LD	HL,TARGET_IP
	LD	DE,TARGET_MAC
	LD	A,32				; payload bytes (even, per CHECKSUM)
	CALL	@ICMP.ECHO			; -> DE = tick-count RTT
	JR	C,.fail
	PUSH	DE
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	POP	DE
	XOR	A
	LD	(LAST_NERR),A
	RET
.fail
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	LD	DE,0
	LD	A,(ICMPLIB_LAST_FAIL)
	CP	@ICMP.F_CANCEL
	JR	Z,.cancel
	CP	@ICMP.F_SEND
	JR	Z,.hw
	LD	A,NERR_TIMEOUT
	JP	RET_A
.hw
	LD	A,NERR_HW
	JP	RET_A
.cancel
	XOR	A
	LD	(@MAIN.CANCELLED),A
	LD	A,NERR_CANCEL
	JP	RET_A

; ------------------------------------------------------
; Functions 13 / 14 - RXPAUSE / RXRESUME.
;
; Genuine no-ops: the card buffers receive in its own ~14.5 KB ring
; and there is no flow-control state a consumer could get wrong.
; They return NERR_OK even before NETINIT - UNETESP returns
; NERR_STATE there because its UART base is not yet known, but
; mirroring that would make a portable consumer that pauses early
; fail on exactly one backend.  CAP_RXFLOW is clear, so a consumer
; that checks capabilities skips these entirely.
; ------------------------------------------------------
F_RXPAUSE
F_RXRESUME
	XOR	A
	RET

; ------------------------------------------------------
; Function 15 - GETINFO.
; Field 0 is the backend tag; 1..12 map onto the NET_* variables
; published by NETCFG / IFUP.  SSID (8) and BAUD (9) are Wi-Fi-only
; and return an empty string, as the ABI expects for a backend that
; has no such property.
; ------------------------------------------------------
F_GETINFO
	LD	(ARG_A),A
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	HL,(ARG_IX)
	LD	A,H
	OR	L
	JP	Z,RET_PARAM			; max=0 has no room for the NUL
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	LD	A,(ARG_A)
	AND	A
	JR	Z,.backend
	CP	INFO_FIELD_COUNT
	JR	NC,.empty
	; index the env-name table with (field - 1)
	LD	L,A
	LD	H,0
	DEC	HL
	ADD	HL,HL
	LD	DE,INFO_NAME_TABLE
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	A,D
	OR	E
	JR	Z,.empty			; SSID / BAUD: no RTL equivalent
	EX	DE,HL				; HL = env var name
	CALL	@NETENV.GET_RAW			; HL -> value in NETENV_VAL_BUF
	JR	NC,.copyout
	LD	HL,LIT_EMPTY
	JR	.copyout
.backend
	LD	HL,LIT_RTL
	JR	.copyout
.empty
	LD	HL,LIT_EMPTY
.copyout
	LD	DE,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	COPY_LIMITED
	XOR	A
	RET

; ------------------------------------------------------
; Function 16 - LASTERR.
;
; There is no AT-command transcript to echo on this backend, so we
; return the RTL equivalent: the chip and stack state captured at
; the moment of failure.  CAPTURE_DIAG snapshots it with the ISA
; window still open; this function is a pure formatter and touches
; no hardware, so it can never report a chip that has since moved on.
;
; Layout (head-truncated, unlike UNETESP which keeps the tail: this
; string is fixed-format, so the high-value fields come first and a
; short caller buffer still sees hw / st / nerr / tcp / res):
;   RTL hw=1/#0300 st=CONNECT nerr=04 tcp=02 res=00
;       tx=E4/42/01/22 regs=22 42 40 04 02 00 46 60 4A 4B
; regs are CR ISR DCR RCR TCR IMR PSTART PSTOP BNRY CURR.
; ------------------------------------------------------
F_LASTERR
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	HL,(ARG_IX)
	LD	A,H
	OR	L
	JP	Z,RET_PARAM
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	CALL	BUILD_LASTERR
	LD	HL,LASTERR_BUF
	LD	DE,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	COPY_LIMITED
	XOR	A
	RET

; ------------------------------------------------------
; Function 17 - SETOPT.
; RXTRIG is a valid option id in the shared ABI that this backend
; simply has no hardware for, which is what NERR_NOTSUP means -
; NERR_PARAM would wrongly suggest the consumer passed garbage.
; ------------------------------------------------------
F_SETOPT
	CP	UNET_OPT_CANCELKEYS
	JR	Z,.cancelkeys
	CP	UNET_OPT_RXTRIG
	JP	Z,RET_NOTSUP
	JP	RET_PARAM
.cancelkeys
	LD	A,D
	OR	E
	JR	Z,.off
	LD	A,1
	LD	(CANCEL_MODE),A
	XOR	A
	RET
.off
	XOR	A
	LD	(CANCEL_MODE),A
	RET

; ------------------------------------------------------
; Reserved slots 18..23.
; ------------------------------------------------------
F_NOTSUP
	LD	A,NERR_NOTSUP
	OR	A
	RET

; ======================================================
; Shared exits.  Reached via JP C / JP Z, so CF is cleared
; explicitly: every UNET function returns status in A with CF=0.
; (The libman dispatcher drops the callee carry, but the Turbo
; Pascal LibCall propagates it.)
; ======================================================
RET_A						; A already set
	LD	(LAST_NERR),A
	OR	A
	RET
RET_PARAM
	LD	A,NERR_PARAM
	JR	RET_A
RET_STATE
	LD	A,NERR_STATE
	JR	RET_A
RET_NOTSUP
	LD	A,NERR_NOTSUP
	JR	RET_A
RET_NONET
	LD	A,NERR_NONET
	JR	RET_A
RET_HW
	LD	A,NERR_HW
	JR	RET_A

; ======================================================
; Helpers
; ======================================================

; ------------------------------------------------------
; CLOSE_LINK: tear down whatever channel is open.  Idempotent.
; ------------------------------------------------------
CLOSE_LINK
	LD	A,(CH_STATE)
	AND	A
	RET	Z
	CP	2
	JR	Z,.udp
	CALL	@ISA.ISA_OPEN
	CALL	@TCP.CLOSE
	CALL	@ISA.ISA_CLOSE
	JR	.done
.udp
	CALL	@UDP.CLOSE
.done
	XOR	A
	LD	(CH_STATE),A
	LD	(PEND_LEN),A
	LD	(PEND_LEN+1),A
	LD	(CLOSED_PEND),A
	RET

; ------------------------------------------------------
; ENV_IS_UP: is the network configured?
; Accepts both the recommended marker (NET=RTL, published by
; NETCFG -i / IFUP) and the legacy state (no NET at all, but
; NET_IP and NET_MAC present) so a machine configured by an older
; build of the kit still works.
;   Out: CF=0 up; CF=1 not configured.  Trashes A, BC, DE, HL.
; ------------------------------------------------------
ENV_IS_UP
	LD	HL,ENVN_NET
	CALL	@NETENV.GET_RAW
	JR	C,.no_marker			; unset: fall back to legacy
	LD	DE,VAL_RTL
	CALL	STRMATCH
	JR	NZ,.bad				; NET is set to something else
.no_marker
	LD	HL,ENVN_IP
	CALL	@NETENV.GET_RAW
	JR	C,.bad
	LD	HL,ENVN_MAC
	CALL	@NETENV.GET_RAW
	JR	C,.bad
	OR	A				; CF=0
	RET
.bad
	SCF
	RET

; ------------------------------------------------------
; CHECK_HOST_PORT: validate the host (DE) and port (IX) strings
; stashed in ARG_DE / ARG_IX.  Out: CF=1 if either is bad.
; ------------------------------------------------------
CHECK_HOST_PORT
	LD	HL,(ARG_DE)
	LD	DE,MAX_HOST_LEN
	CALL	CHECK_STRARG
	RET	C
	LD	HL,(ARG_IX)
	LD	DE,MAX_PORT_LEN
	JP	CHECK_STRARG

; ------------------------------------------------------
; RESOLVE_AND_ARP: host string in ARG_DE -> TARGET_IP, then find
; the next hop -> TARGET_MAC.  Opens and closes the ISA window.
;   Out: CF=0 ok; CF=1 with RESOLVE.LAST_FAIL set.
; ------------------------------------------------------
RESOLVE_AND_ARP
	CALL	@ISA.ISA_OPEN
	LD	HL,(ARG_DE)
	LD	DE,TARGET_IP
	CALL	@RESOLVE.HOST
	JR	C,.fail
	LD	HL,TARGET_IP
	CALL	@RESOLVE.NEXT_HOP_FOR
	JR	C,.fail
	LD	HL,RESOLVE_NEXT_HOP_MAC
	LD	DE,TARGET_MAC
	LD	BC,6
	LDIR
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	OR	A				; CF=0
	RET
.fail
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	SCF
	RET

; ------------------------------------------------------
; MAP_RESOLVE_FAIL: RESOLVE.LAST_FAIL -> NERR_*.
;   1 usage, 2 no NET_DNS1, 6 DNS parse/RCODE -> NERR_DNS
;   3 off-subnet with no gateway, 4 ARP timeout -> NERR_CONNECT
;     (the name may be fine; we cannot reach the next hop)
;   5 DNS timeout -> NERR_TIMEOUT
;   7 cancelled  -> NERR_CANCEL
; ------------------------------------------------------
MAP_RESOLVE_FAIL
	LD	A,(@RESOLVE.LAST_FAIL)
	CP	7
	JR	Z,.cancel
	CP	5
	JR	Z,.timeout
	CP	3
	JR	Z,.connect
	CP	4
	JR	Z,.connect
	LD	A,NERR_DNS
	JP	RET_A
.connect
	LD	A,NERR_CONNECT
	JP	RET_A
.timeout
	LD	A,NERR_TIMEOUT
	JP	RET_A
.cancel
	XOR	A
	LD	(@MAIN.CANCELLED),A
	LD	A,NERR_CANCEL
	JP	RET_A

; ------------------------------------------------------
; MAP_TCP_FAIL: TCP.LAST_FAIL -> NERR_*.
; F_SEND means RTL.SEND_FRAME itself failed, i.e. the NIC never put
; the segment on the wire - that is hardware, not a refused
; connection, so it maps to NERR_HW and LASTERR carries the TX stage.
; ------------------------------------------------------
MAP_TCP_FAIL
	LD	A,(TCP_LAST_FAIL)
	CP	@TCP.F_CANCEL
	JR	Z,.cancel
	CP	@TCP.F_SEND
	JR	Z,.hw
	LD	A,NERR_CONNECT
	JP	RET_A
.hw
	LD	A,NERR_HW
	JP	RET_A
.cancel
	XOR	A
	LD	(@MAIN.CANCELLED),A
	LD	A,NERR_CANCEL
	JP	RET_A

; ------------------------------------------------------
; MAP_TCP_SEND_FAIL: SEND has one additional failure class:
; the NIC transmitted locally, but the cumulative peer ACK did not
; arrive after the bounded retransmits.  Report that as NERR_SEND,
; while retaining the hardware/cancel distinctions above.
; ------------------------------------------------------
MAP_TCP_SEND_FAIL
	LD	A,(TCP_LAST_FAIL)
	CP	@TCP.F_CANCEL
	JR	Z,.cancel
	CP	@TCP.F_SEND
	JR	Z,.hw
	CP	@TCP.F_RST
	JR	Z,.closed
	LD	A,NERR_SEND
	JP	RET_A
.closed
	XOR	A
	LD	(CH_STATE),A
	LD	A,NERR_CLOSED
	JP	RET_A
.hw
	LD	A,NERR_HW
	JP	RET_A
.cancel
	XOR	A
	LD	(@MAIN.CANCELLED),A
	LD	A,NERR_CANCEL
	JP	RET_A

; ------------------------------------------------------
; CAPTURE_DIAG: snapshot chip + stack state for LASTERR.  MUST be
; called with the ISA window OPEN (SNAPSHOT_REGS drives the chip);
; the formatting happens later, with the window closed.
; ------------------------------------------------------
CAPTURE_DIAG
	CALL	@RTL.SNAPSHOT_REGS
	LD	HL,RTL_REG_SNAPSHOT
	LD	DE,DIAG_REGS
	LD	BC,10
	LDIR
	LD	HL,RTL_TX_LAST_STAGE
	LD	DE,DIAG_TX
	LD	BC,4
	LDIR
	RET

; ------------------------------------------------------
; BUILD_LASTERR: format the captured diagnostic into LASTERR_BUF.
; Touches no hardware.
; ------------------------------------------------------
BUILD_LASTERR
	LD	DE,LASTERR_BUF
	LD	HL,S_RTL_HW
	CALL	APPEND
	LD	A,(@ISA.ISA_SLOT)
	ADD	A,'0'
	LD	(DE),A
	INC	DE
	LD	HL,S_SLASH_HASH
	CALL	APPEND
	; I/O base = window address - ISA_BASE_A
	LD	HL,(RTL_BASE_PTR)
	LD	A,H
	OR	L
	JR	Z,.no_base
	LD	BC,ISA_BASE_A
	OR	A
	SBC	HL,BC
	LD	A,H
	CALL	@UTIL.FORMAT_HEX_A
	LD	A,L
	CALL	@UTIL.FORMAT_HEX_A
	JR	.stage
.no_base
	LD	HL,S_NONE
	CALL	APPEND
.stage
	LD	HL,S_ST
	CALL	APPEND
	LD	A,(STAGE)
	CALL	APPEND_STAGE
	LD	HL,S_NERR
	CALL	APPEND
	LD	A,(LAST_NERR)
	CALL	@UTIL.FORMAT_HEX_A
	LD	HL,S_TCP
	CALL	APPEND
	LD	A,(TCP_LAST_FAIL)
	CALL	@UTIL.FORMAT_HEX_A
	LD	HL,S_RES
	CALL	APPEND
	LD	A,(@RESOLVE.LAST_FAIL)
	CALL	@UTIL.FORMAT_HEX_A
	LD	HL,S_TX
	CALL	APPEND
	LD	B,4
	LD	HL,DIAG_TX
.tx_loop
	LD	A,(HL)
	INC	HL
	PUSH	BC
	PUSH	HL
	CALL	@UTIL.FORMAT_HEX_A
	POP	HL
	POP	BC
	DEC	B
	JR	Z,.regs
	LD	A,'/'
	LD	(DE),A
	INC	DE
	JR	.tx_loop
.regs
	LD	HL,S_REGS
	CALL	APPEND
	LD	B,10
	LD	HL,DIAG_REGS
.reg_loop
	LD	A,(HL)
	INC	HL
	PUSH	BC
	PUSH	HL
	CALL	@UTIL.FORMAT_HEX_A
	POP	HL
	POP	BC
	DEC	B
	JR	Z,.term
	LD	A,' '
	LD	(DE),A
	INC	DE
	JR	.reg_loop
.term
	XOR	A
	LD	(DE),A
	RET

; APPEND: copy the ASCIIZ at HL to (DE), DE past the last char.
; Trashes A, HL.  The NUL is not written.
APPEND
	LD	A,(HL)
	AND	A
	RET	Z
	LD	(DE),A
	INC	DE
	INC	HL
	JR	APPEND

; APPEND_STAGE: A = ST_* -> mnemonic at (DE).
APPEND_STAGE
	CP	ST_COUNT
	JR	C,.ok
	XOR	A				; unknown: report NONE
.ok
	LD	L,A
	LD	H,0
	ADD	HL,HL
	LD	BC,STAGE_TABLE
	ADD	HL,BC
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	JP	APPEND

; ------------------------------------------------------
; COPY_LIMITED: copy the ASCIIZ at HL to (DE), at most BC bytes
; INCLUDING the terminator.  BC=0 is rejected by the callers.
; ------------------------------------------------------
COPY_LIMITED
	DEC	BC				; reserve room for the NUL
.loop
	LD	A,B
	OR	C
	JR	Z,.term
	LD	A,(HL)
	AND	A
	JR	Z,.term
	LD	(DE),A
	INC	HL
	INC	DE
	DEC	BC
	JR	.loop
.term
	XOR	A
	LD	(DE),A
	RET

; ------------------------------------------------------
; STRMATCH: compare the ASCIIZ at HL with the one at DE.
;   Out: ZF=1 if equal.  Trashes A, DE, HL.
; ------------------------------------------------------
STRMATCH
	LD	A,(DE)
	LD	B,A
	LD	A,(HL)
	CP	B
	RET	NZ
	AND	A
	RET	Z				; both terminated: equal
	INC	HL
	INC	DE
	JR	STRMATCH

; ------------------------------------------------------
; PARSE_U16: ASCIIZ decimal at HL -> HL.
;   Out: CF=0 ok; CF=1 on an empty string, a non-digit or overflow.
; Trashes A, BC, DE.
;
; Deliberately local rather than @CMDL.PARSE_U16: cmdline_lib is
; ~440 bytes of argv machinery for one number conversion, and
; sjasmplus has no dead-code elimination.
; ------------------------------------------------------
PARSE_U16
	LD	DE,0
	LD	A,(HL)
	AND	A
	JR	Z,.bad				; empty string
.loop
	LD	A,(HL)
	AND	A
	JR	Z,.done
	SUB	'0'
	JR	C,.bad
	CP	10
	JR	NC,.bad
	; DE = DE*10 + digit, rejecting a 16-bit overflow
	PUSH	HL
	LD	H,D
	LD	L,E
	ADD	HL,HL				; x2
	JR	C,.ovf
	ADD	HL,HL				; x4
	JR	C,.ovf
	ADD	HL,DE				; x5
	JR	C,.ovf
	ADD	HL,HL				; x10
	JR	C,.ovf
	LD	E,A
	LD	D,0
	ADD	HL,DE
	JR	C,.ovf
	EX	DE,HL
	POP	HL
	INC	HL
	JR	.loop
.ovf
	POP	HL
.bad
	SCF
	RET
.done
	EX	DE,HL
	OR	A				; CF=0
	RET

; ------------------------------------------------------
; Caller-buffer validation, mirroring UNETESP so both backends
; accept and reject exactly the same arguments.
;
; CHECK_BUF: reject window 0 (DSS), window 3 (the ISA aperture) and
; the DLL's own window.  Out: CF=1 invalid.  Preserves BC, DE, HL.
; ------------------------------------------------------
CHECK_BUF
	LD	A,H
	AND	0xC0
	JR	Z,.bad				; window 0: system
	CP	0xC0
	JR	Z,.bad				; window 3: ISA
	LD	A,(WIN_BASE)
	XOR	H
	AND	0xC0
	JR	Z,.bad				; our own window
	OR	A				; CF=0
	RET
.bad
	SCF
	RET

; CHECK_BUF_RANGE: both ends of [HL, HL+BC-1] must be usable, and
; the range must not wrap past 0xFFFF.  BC=0 checks the start only.
;   Out: CF=1 invalid.  Trashes A, BC, HL.
CHECK_BUF_RANGE
	CALL	CHECK_BUF
	RET	C
	LD	A,B
	OR	C
	RET	Z				; empty: CF=0 from OR
	DEC	BC
	ADD	HL,BC
	RET	C				; wrapped
	JP	CHECK_BUF

; CHECK_STRARG: the string at HL must start and terminate inside a
; usable window and be at most DE bytes long (this bounds what the
; resolver and the frame builders have to cope with).
;   Out: CF=1 invalid.  Preserves HL.  Trashes A, B, DE.
CHECK_STRARG
	CALL	CHECK_BUF
	RET	C
	PUSH	HL
	INC	DE				; the NUL may sit at max+1
.scan
	LD	A,(HL)
	AND	A
	JR	Z,.ends
	INC	HL
	DEC	DE
	LD	A,D
	OR	E
	JR	NZ,.scan
	POP	HL
	SCF					; too long
	RET
.ends
	CALL	CHECK_BUF			; terminator still in range
	POP	HL
	RET

; ======================================================
; Literals
; ======================================================
LIT_RTL		DB "RTL",0
LIT_EMPTY	DB 0

ENVN_NET	DB "NET",0
VAL_RTL		DB "RTL",0
ENVN_IP		DB "NET_IP",0
ENVN_MASK	DB "NET_MASK",0
ENVN_GW		DB "NET_GW",0
ENVN_MAC	DB "NET_MAC",0
ENVN_DNS1	DB "NET_DNS1",0
ENVN_DNS2	DB "NET_DNS2",0
ENVN_IPSRC	DB "NET_IP_SRC",0
ENVN_NTP	DB "NET_NTP",0
ENVN_TZ		DB "NET_TZ",0
ENVN_RTL_HW	DB "NET_RTL_HW",0

; GETINFO fields 1..12 (field 0 is the backend literal).  Zero means
; "no equivalent on this backend" -> empty string: 8 = SSID and
; 9 = BAUD are Wi-Fi properties.
INFO_NAME_TABLE
	DW ENVN_IP, ENVN_MASK, ENVN_GW, ENVN_MAC, ENVN_DNS1, ENVN_DNS2
	DW ENVN_IPSRC, 0, 0, ENVN_NTP, ENVN_TZ, ENVN_RTL_HW
INFO_FIELD_COUNT	EQU 13

S_RTL_HW	DB "RTL hw=",0
S_SLASH_HASH	DB "/#",0
S_NONE		DB "none",0
S_ST		DB " st=",0
S_NERR		DB " nerr=",0
S_TCP		DB " tcp=",0
S_RES		DB " res=",0
S_TX		DB " tx=",0
S_REGS		DB " regs=",0

; Stage mnemonics for LASTERR.
ST_NONE		EQU 0
ST_NETINIT	EQU 1
ST_CONNECT	EQU 2
ST_SEND		EQU 3
ST_RECV		EQU 4
ST_UDPOPEN	EQU 5
ST_RESOLVE	EQU 6
ST_PING		EQU 7
ST_COUNT	EQU 8

STAGE_TABLE
	DW S_ST_NONE, S_ST_NETINIT, S_ST_CONNECT, S_ST_SEND
	DW S_ST_RECV, S_ST_UDPOPEN, S_ST_RESOLVE, S_ST_PING
S_ST_NONE	DB "NONE",0
S_ST_NETINIT	DB "NETINIT",0
S_ST_CONNECT	DB "CONNECT",0
S_ST_SEND	DB "SEND",0
S_ST_RECV	DB "RECV",0
S_ST_UDPOPEN	DB "UDPOPEN",0
S_ST_RESOLVE	DB "RESOLVE",0
S_ST_PING	DB "PING",0

; ======================================================
; State.  Initialised data inside the image, so every l_load
; resets it; only the big buffers live in the DS block.
; ======================================================
WIN_BASE	DB 0			; top 2 bits of our load address
INITED		DB 0			; NETINIT completed
CH_STATE	DB 0			; 0 closed, 1 TCP, 2 UDP
CANCEL_MODE	DB 0			; SETOPT CANCELKEYS
STAGE		DB 0			; ST_* of the last operation
LAST_NERR	DB 0			; last status returned
CLOSED_PEND	DB 0			; FIN seen; report it on the next RECV
ARG_A		DB 0
ARG_DE		DW 0
ARG_IX		DW 0
ARG_IY		DW 0
ARG_PORT	DW 0
ARG_LPORT	DW 0
SEND_DONE	DW 0
CHUNK_LEN	DW 0
COPY_LEN	DW 0
PEND_PTR	DW 0			; unread tail inside RX_BUF
PEND_LEN	DW 0
TARGET_IP	DS 4, 0
TARGET_MAC	DS 6, 0
DIAG_REGS	DS 10, 0		; CR ISR DCR RCR TCR IMR PSTART PSTOP BNRY CURR
DIAG_TX		DS 4, 0			; TX stage / ISR / TSR / CR

LASTERR_BUF	EQU DLL_BSS + BSS_LASTERR

	ENDMODULE

; ======================================================
; Reused kit libraries, in the same order the apps use: the modules
; that force USE_UTIL_* flags (netenv_lib, cmdline_lib) must precede
; util.asm, or the helpers they need are gated out.
; ======================================================
	INCLUDE "netenv_lib.asm"
	INCLUDE "cmdline_lib.asm"
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"
	INCLUDE "arp_lib.asm"
	INCLUDE "resolve_lib.asm"
	INCLUDE "dns_lib.asm"
	INCLUDE "tcp_lib.asm"
	INCLUDE "udp_lib.asm"
	INCLUDE "icmp_lib.asm"

; The whole image (code + relocation bitmap) must fit 16 KiB.  The
; bitmap is one bit per code byte, so guard the code at 0x3800:
; 0x3800 + 0x3800/8 = 0x3F00 < 0x4000.
	ASSERT $ <= 0x3800
