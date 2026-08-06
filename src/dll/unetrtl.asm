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
	DEFINE	USE_RTL_PEEK_PACKET	; leave another channel's head frame queued
	DEFINE	USE_ARP_BUILD_REQUEST
	DEFINE	USE_ARP_ANSWER
	DEFINE	USE_NETENV
	DEFINE	USE_DNS
	DEFINE	USE_RESOLVE
	DEFINE	USE_TCP
	DEFINE	USE_TCP_RELIABLE_SEND	; bounded per-MSS ACK wait + retransmit
	DEFINE	USE_TCP_CONTEXT_FULL	; all live receive state follows its channel
	DEFINE	USE_TCP_MULTICHAN
	DEFINE	USE_UDP
	DEFINE	USE_UDP_MULTICHAN
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
; LISTEN/TRANSPARENT are v1 gaps.  RAWETH stays clear even
; though the card can do it: slots 0..17 have no raw-frame entry
; point, and advertising a capability with nothing to call would be
; a lie.
UNETRTL_CAPS	EQU UNET_CAP_TCP | UNET_CAP_UDP | UNET_CAP_RESOLVE | UNET_CAP_PING | UNET_CAP_MULTICHAN

UNET_CHANNELS	EQU 2
MAX_HOST_LEN	EQU 128			; matches UNETESP; also bounds the
MAX_PORT_LEN	EQU 15			; resolver's own scratch usage
TCP_MSS		EQU 536			; SEND chunk size, hidden by the ABI
; Measured worst case: "RTL hw=0/#0300 st=NETINIT nerr=09 tcp=00 res=00
; tx=04/02/03/22 regs=22 00 C8 C4 E0 80 46 60 49 4A" + NUL is ~98 bytes
; (NETINIT is the longest stage mnemonic; see ST_* below).  112 keeps
; real headroom while returning the image-budget bytes the v0.2.41
; foreign-channel fix needed (see HANDLE_FOREIGN_FRAME/TCP_ADV_WIN).
LASTERR_SIZE	EQU 112

	ORG 0x0000			; the ONLY ORG; mkdll rewrites it
DLL_IMAGE_ORIGIN	EQU $

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
; tcp 0x35, udp 0x18, icmp 0x10.
; ======================================================
; TX_BUF/RX_BUF sizes below assume zero-copy TX (SEND_FRAME_SG in
; rtl8019.asm, IFDEF UNET_DLL): UDP/TCP-data payloads stream straight
; from the caller's own buffer and are never copied into TX_BUF, so
; TX_BUF only needs to hold the largest frame still built whole --
; the DNS query via resolve_lib, bounded by RESOLVE_MAX_FRAME (320).
; RX_BUF grows to the standard IPv4 MTU (14+20+8+1472=1514) now that
; TX_BUF's shrink pays for it inside the libman 0x38C7 image budget.
; BSS_TCP grew 0x035->0x037 (TCP_ADV_WIN_HI/LO, see memmap.inc) --
; every offset from BSS_UDP onward shifted +2 accordingly.  BSS_LASTERR
; shrank 0x080->0x070 (LASTERR_SIZE 128->112, see its declaration) --
; every offset from BSS_TX_BUF onward shifted a further -16.
; BSS_CH_TCP is SELECT_CHANNEL's swap slot: TCP_STATE..+TCP_CTX_SIZE
; plus TCP_ACK_WAIT_STATE..+TCP_SWAP_TAIL_SIZE = 38+13 = 51 (0x33).
; It must track those two constants, NOT TCP_BSS_SIZE -- the tail of
; the TCP BSS past TCP_RECV_TIMEOUT (TCP_ADV_WIN_HI/LO) is
; session-global and stays out of the swap.  The ASSERT after
; INCLUDE "memmap.inc" enforces the relationship; see the two
; incidents it now covers in TCP_ADV_WIN_HI's memmap.inc comment.
BSS_LIB		EQU 0x0000		; 0x17C util + rtl + netenv + rtl tx + SG desc
BSS_RESOLVE	EQU 0x017C		; 0x029 resolve_lib
BSS_TCP		EQU 0x01A5		; 0x037 tcp_lib
BSS_UDP		EQU 0x01DC		; 0x018 udp_lib
BSS_ICMP	EQU 0x01F4		; 0x010 icmp_lib
BSS_OUR_IP	EQU 0x0204		; 4
BSS_OUR_MAC	EQU 0x0208		; 6
BSS_CANCELLED	EQU 0x020E		; 1
BSS_LASTERR	EQU 0x0210		; 0x070 formatted diagnostic line
BSS_TX_BUF	EQU 0x0280		; 0x140 320 = RESOLVE_MAX_FRAME (largest whole-built frame)
BSS_RX_HDR	EQU 0x03C0		; 4     NE2000 RX ring header
BSS_RX_BUF	EQU 0x03C4		; 0x5EA 1514 = 14+20+8+1472 (standard UDP MTU)
BSS_CH_TCP	EQU 0x09AE		; 0x33 inactive TCP context (salt + adv-win excluded)
BSS_CH_UDP	EQU 0x09E1		; 0x18 inactive-channel UDP context
BSS_PEND_LEN	EQU 0x09F9		; 2 words
BSS_PEND_OFF	EQU 0x09FD		; 2 words
BSS_CLOSED	EQU 0x0A01		; 2 bytes
BSS_LOST	EQU 0x0A03		; 2 bytes
BSS_PEND_BUF	EQU 0x0A05		; 2 * 536-byte TCP receive queues
DLL_BSS_SIZE	EQU 0x0E35		; 3637 total
	ASSERT	BSS_TX_BUF + 0x140 <= BSS_RX_HDR

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
	; TX_BUF must still fit the largest frame BUILD_FRAME-style
	; routines assemble whole (only resolve_lib's DNS query does,
	; under zero-copy TX -- see the layout comment above).
	ASSERT	RESOLVE_MAX_FRAME <= 0x140
	; CH_TCP_CTX must hold SELECT_CHANNEL's full two-slice swap or the
	; second SWAP_BYTES call overruns into CH_UDP_CTX -- which the same
	; call is swapping too, so both get corrupted on every channel
	; switch.  Equality, not >=: a slot LARGER than the swap would mean
	; TCP BSS was added to without deciding whether the new state is
	; per-channel (extend TCP_SWAP_TAIL_SIZE) or global (leave it out,
	; like TCP_ADV_WIN_HI/LO) -- both mistakes have now happened once.
	ASSERT	BSS_CH_UDP - BSS_CH_TCP == TCP_CTX_SIZE + TCP_SWAP_TAIL_SIZE

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
RX_BUF_SIZE	EQU 1514		; 14+20+8+1472 (standard UDP MTU)

CH_TCP_CTX	EQU DLL_BSS + BSS_CH_TCP	; inactive channel swap slot
CH_UDP_CTX	EQU DLL_BSS + BSS_CH_UDP	; inactive channel swap slot
CH_PEND_LEN	EQU DLL_BSS + BSS_PEND_LEN
CH_PEND_OFF	EQU DLL_BSS + BSS_PEND_OFF
CH_CLOSED	EQU DLL_BSS + BSS_CLOSED
CH_LOST		EQU DLL_BSS + BSS_LOST
CH_PEND_BUF	EQU DLL_BSS + BSS_PEND_BUF
CH_PEND_SIZE	EQU 536

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
	CALL	RESET_CHANNEL_STATE
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
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	CALL	CLOSE_CHANNEL
	XOR	A
	RET
F_NETDONE
	CALL	CLOSE_LINK
	XOR	A
	RET

; ------------------------------------------------------
; Function 5 - CONNECT (TCP).
; ------------------------------------------------------
F_CONNECT
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	A,ST_CONNECT
	LD	(STAGE),A
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE
	CALL	GET_CH_STATE
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
	LD	A,(ARG_CH)
	CALL	SELECT_CHANNEL
	LD	A,(ARG_CH)
	CALL	PEND_CLEAR_A
	; Fill the tcp_lib session tuple.
	LD	HL,TARGET_IP
	LD	DE,TCP_REMOTE_IP
	LD	BC,4
	LDIR
	LD	HL,TARGET_MAC
	LD	DE,TCP_REMOTE_MAC
	LD	BC,6
	LDIR
	; TARGET_MAC overlays the foreign-dispatch busy byte.
	XOR	A
	LD	(FOREIGN_BUSY),A
	LD	HL,(ARG_PORT)
	LD	A,H
	LD	(TCP_REMOTE_PORT_HI),A
	LD	A,L
	LD	(TCP_REMOTE_PORT_LO),A
	XOR	A
	LD	(TCP_STATE),A			; force CLOSED before OPEN
	CALL	@ISA.ISA_OPEN
	CALL	@TCP.OPEN
	JR	C,.fail
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	LD	A,1
	CALL	SET_CH_STATE			; 1 = TCP
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
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	A,ST_SEND
	LD	(STAGE),A
	CALL	GET_CH_STATE
	AND	A
	JP	Z,RET_STATE
	LD	A,(ARG_CH)
	CALL	SELECT_CHANNEL
	CALL	GET_CH_STATE
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
	; "Anything left to send?" MUST be tested before the pend guard
	; below, never after.  CAPTURE_SEND_PENDING fills this channel's
	; pend slot with any reply that rode in on our own segment's ACK,
	; so after the FINAL chunk the loop comes back here with the work
	; complete AND the slot occupied.  Guarding first turned that into
	; NERR_BUSY for a send that had already fully landed -- and a
	; consumer reacting to BUSY by draining and retrying then sent the
	; command twice (real FTPC bug report: every FTP login failed, with
	; the server's own reply to the "refused" PASS sitting in the drain
	; buffer).  On a lockstep request/response protocol over a fast
	; link that is the common case, not a corner case.
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
	; The channel's own pend slot must be empty before this chunk's
	; SEND runs.  TCP.SEND's internal wait can receive and ACK
	; payload piggybacked on our peer's ACK; CAPTURE_SEND_PENDING
	; below has nowhere to put it if an earlier RECV was never
	; drained.  That used to silently drop the just-ACKed bytes --
	; an ACK is a promise to the peer that the data is ours for good,
	; so losing it after the fact is a protocol-level bug, not a
	; buffering inconvenience.  Refuse instead: the caller drains via
	; RECV and retries, exactly as the ABI already documents for the
	; ESP backend ("peer data arriving during a send may be dropped -
	; drain RECV before sending").  DE reports bytes sent by EARLIER
	; chunks in this same call, per the ABI's "valid on error paths".
	;
	; Placed here, past the remaining-bytes test, so it can only veto a
	; transmission that has not happened yet.  It costs nothing to sit
	; here: A and HL are both reloaded from memory immediately below,
	; so PEND_LEN_ADDR_A clobbering them is free.
	;
	; NERR_BUSY, deliberately NOT NERR_PARAM: PARAM already means "bad
	; argument" (CHECK_BUF_RANGE above returns it for a rejected
	; buffer), and a consumer keying "drain RECV, then retry" on a
	; code that also covers permanent caller bugs will loop forever on
	; those (real FTPC bug report, 2026-08-05).  BUSY is the frozen
	; ABI's transient-refusal code; NERR_AGAIN is off-limits here
	; because unet.inc reserves it for UNET_CAP_ASYNCSEND backends.
	LD	A,(ARG_CH)
	CALL	PEND_LEN_ADDR_A
	LD	A,(HL)
	INC	HL
	OR	(HL)
	JR	NZ,.busy
	LD	HL,(ARG_DE)
	LD	DE,(SEND_DONE)
	ADD	HL,DE
	LD	BC,(CHUNK_LEN)
	CALL	@TCP.SEND
	JR	C,.fail
	CALL	CAPTURE_SEND_PENDING
	LD	HL,(SEND_DONE)
	LD	BC,(CHUNK_LEN)
	ADD	HL,BC
	LD	(SEND_DONE),HL
	JR	.chunk
.busy
	CALL	@ISA.ISA_CLOSE
	LD	DE,(SEND_DONE)
	LD	A,NERR_BUSY
	JP	RET_A
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
; TCP payload is copied into a private 536-byte queue for the selected
; channel before the shared frame buffer can be reused.  A foreign TCP frame
; may therefore be ACKed and queued while the other channel is waiting; UDP
; frames can remain protected at the NIC ring head until their owner is read.
; ------------------------------------------------------
F_RECV
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	(ARG_IY),IY
	LD	A,ST_RECV
	LD	(STAGE),A
	CALL	GET_CH_STATE
	AND	A
	JR	NZ,.have_state
	; Keep a closed marker observable after the TCP state itself has
	; been released.  This makes the call after a FIN/RST return the
	; frozen NERR_CLOSED result instead of the generic NERR_STATE.
	LD	A,(ARG_CH)
	CALL	CLOSED_ADDR_A
	LD	A,(HL)
	OR	A
	JP	NZ,.closed_no_state
	JP	RET_STATE
.have_state
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	LD	A,(ARG_CH)
	CALL	SELECT_CHANNEL
	CALL	GET_CH_STATE
	CP	2
	JP	Z,.udp
	; -- TCP --
	; A failed cumulative ACK from the preceding drain is retried before
	; touching the pending data or the NIC.  The debt is per-channel because
	; RECV_UNACKED is part of the swapped TCP context.
	CALL	FLUSH_RECV_ACK
	JP	C,.hw
	XOR	A
	LD	(COPY_LEN),A
	LD	(COPY_LEN+1),A
	; Serve the existing remainder first, directly into the caller buffer.
	CALL	COPY_PENDING_ARG
	LD	HL,(ARG_IX)
	LD	A,H
	OR	L
	JP	Z,.return_drain
	; A FIN seen last time with trailing data already delivered.
	LD	A,(ARG_CH)
	CALL	CLOSED_ADDR_A
	LD	A,(HL)
	OR	A
	JR	Z,.no_closed_pending
	LD	HL,(COPY_LEN)
	LD	A,H
	OR	L
	JP	NZ,.return_drain
	JP	.report_closed
.no_closed_pending
	LD	A,0xFF
	LD	(FOREIGN_HINT),A
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
	; Bit 7 is a scoped internal flag.  The low seven bits remain the
	; ordinary receive-ACK debt counter and are flushed on every exit.
	LD	HL,@TCP.RECV_UNACKED
	SET	7,(HL)
.drain_loop
	CALL	@ISA.ISA_OPEN
	CALL	@TCP.RECV			; -> HL=data, BC=len
	JR	C,.rx_err_open
	CALL	@ISA.ISA_CLOSE
	CALL	COPY_RX_ARG
	JP	C,.queue_fail
	; All calls after the first are deliberately one-tick polls.  A
	; caller's original IY is consumed only by the first TCP.RECV.
	LD	HL,1
	LD	(@TCP.RECV_TIMEOUT),HL
	; A segment carrying FIN is the end of the stream even when its data
	; fitted exactly.  COPY_RX_ARG has already delivered the bytes.
	LD	A,(TCP_STATE)
	CP	@TCP.ST_CLOSE_WAIT
	JR	Z,.mark_fin
	LD	HL,(ARG_IX)
	LD	A,H
	OR	L
	JP	Z,.return_drain
	JR	.drain_loop
.mark_fin
	LD	A,(ARG_CH)
	CALL	CLOSED_ADDR_A
	LD	(HL),1
	JP	.return_drain
.rx_err_open
	; TCP.RECV has already captured the relevant chip state in its normal
	; open window.  Formatting is deferred until after ISA_CLOSE.
	CALL	CAPTURE_DIAG
	CALL	@ISA.ISA_CLOSE
	LD	A,(TCP_LAST_FAIL)
	CP	@TCP.F_SEND
	JP	Z,.return_drain
	LD	A,(TCP_STATE)
	CP	@TCP.ST_CLOSE_WAIT
	JP	Z,.peer_fin
	; Timeout is not an error at this layer: idle, link still alive.
	LD	A,(TCP_LAST_FAIL)
	CP	@TCP.F_TIMEOUT
	JP	Z,.idle
	CP	@TCP.F_OTHER
	JP	Z,.idle
	CP	@TCP.F_CANCEL
	JP	Z,.cancelled
	CP	@TCP.F_RST
	JP	Z,.reset_by_peer
	LD	DE,0
	LD	IX,0
	LD	A,NERR_PROTO
	JP	RET_A
.reset_by_peer
	LD	A,(ARG_CH)
	CALL	CLOSED_ADDR_A
	LD	(HL),1
	XOR	A
	CALL	SET_CH_STATE
	LD	HL,(COPY_LEN)
	LD	A,H
	OR	L
	JP	NZ,.return_drain
	JP	.report_closed
.idle
	JP	.return_drain
.cancelled
	XOR	A
	LD	(@MAIN.CANCELLED),A
	CALL	FLUSH_RECV_ACK
	LD	DE,0
	LD	IX,0
	LD	A,NERR_CANCEL
	JP	RET_A
.peer_fin
	; FIN, possibly carrying a last data segment.
	LD	A,(ARG_CH)
	CALL	CLOSED_ADDR_A
	LD	(HL),1
	LD	BC,(TCP_RX_DATA_LEN)
	LD	A,B
	OR	C
	JP	Z,.report_closed
	LD	HL,(TCP_RX_DATA_PTR)
	CALL	COPY_RX_ARG
	JP	C,.queue_fail
	JP	.return_drain
.report_closed
	CALL	FLUSH_RECV_ACK
	JP	C,.hw
	XOR	A
	CALL	SET_CH_STATE
	LD	DE,0
	CALL	BUILD_RECV_FLAGS
	LD	A,NERR_CLOSED
	JP	RET_A
.queue_fail
	CALL	FLUSH_RECV_ACK
	JP	C,.hw
	LD	DE,(COPY_LEN)
	LD	A,D
	OR	E
	JP	NZ,.return_drain_ok
	LD	A,NERR_PROTO
	JP	RET_A
.hw
	LD	DE,0
	LD	IX,0
	LD	A,NERR_HW
	JP	RET_A

.return_drain
	CALL	FLUSH_RECV_ACK
	JR	C,.drain_ack_failed
.return_drain_ok
	CALL	BUILD_RECV_FLAGS
	LD	DE,(COPY_LEN)
	XOR	A
	LD	(LAST_NERR),A
	RET
.drain_ack_failed
	LD	DE,(COPY_LEN)
	LD	A,D
	OR	E
	JP	NZ,.return_drain_ok
	JP	.hw
.closed_no_state
	LD	DE,0
	LD	IX,0
	LD	A,NERR_CLOSED
	JP	RET_A
.udp
	; -- UDP: one datagram per call --
	LD	A,0xFF
	LD	(FOREIGN_HINT),A
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
	CALL	BUILD_RECV_FLAGS
	LD	A,(UDPLIB_RX_FLAGS)
	AND	1
	JR	Z,.udp_ok
	PUSH	IX
	POP	HL
	SET	0,L				; bit0: datagram was truncated
	PUSH	HL
	POP	IX
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
	CP	@UDP.F_TIMEOUT
	JR	Z,.udp_idle
	CP	@UDP.F_OTHER
	JR	NZ,.udp_proto
.udp_idle
	CALL	BUILD_RECV_FLAGS
	XOR	A				; timeout/XCHAN = idle, per the ABI
	RET
.udp_proto
	LD	A,NERR_PROTO
	JP	RET_A
.udp_cancel
	XOR	A
	LD	(@MAIN.CANCELLED),A
	LD	A,NERR_CANCEL
	JP	RET_A

; ------------------------------------------------------
; Scoped receive ACK support.
;
; Bit 7 of TCP.RECV_UNACKED is an internal DLL-only defer flag.  The
; low seven bits count accepted segments whose cumulative ACK has not
; left yet.  FLUSH_RECV_ACK clears the scope and emits exactly one ACK
; when the count is non-zero.  A failed send leaves the low bits intact,
; so the next public RECV can retry it.
; ------------------------------------------------------
FLUSH_RECV_ACK
	LD	HL,@TCP.RECV_UNACKED
	RES	7,(HL)
	LD	A,(HL)
	OR	A
	RET	Z
	CALL	@ISA.ISA_OPEN
	CALL	@TCP.SEND_DUP_ACK
	JR	C,.flush_fail
	CALL	@ISA.ISA_CLOSE
	XOR	A
	LD	(@TCP.RECV_UNACKED),A
	OR	A
	RET
.flush_fail
	CALL	@ISA.ISA_CLOSE
	SCF
	RET

; Add BC bytes to the moving caller destination/remaining capacity and
; the total returned by this F_RECV call.
ADVANCE_COPY_BC
	LD	HL,(ARG_DE)
	ADD	HL,BC
	LD	(ARG_DE),HL
	LD	HL,(ARG_IX)
	OR	A
	SBC	HL,BC
	LD	(ARG_IX),HL
	LD	HL,(COPY_LEN)
	ADD	HL,BC
	LD	(COPY_LEN),HL
	RET

; Copy BC bytes from HL to the moving caller destination and account them.
COPY_ARG_BC
	PUSH	BC
	LD	DE,(ARG_DE)
	LDIR
	POP	BC
	JP	ADVANCE_COPY_BC

; Copy as much of the selected channel's pending queue as fits.  The
; helper updates the moving destination, remaining capacity, total and
; the pending offset/length; no NIC access is involved.
COPY_PENDING_ARG
	LD	A,(ARG_CH)
	CALL	PEND_LEN_ADDR_A
	LD	(QUEUE_LEN),HL
	LD	C,(HL)
	INC	HL
	LD	B,(HL)
	LD	A,B
	OR	C
	RET	Z
	LD	H,B
	LD	L,C
	LD	DE,(ARG_IX)
	OR	A
	SBC	HL,DE
	JR	C,.take
	LD	BC,(ARG_IX)
	JR	.take
.take
	LD	A,(ARG_CH)
	CALL	PEND_BUF_ADDR_A
	EX	DE,HL
	LD	A,(ARG_CH)
	CALL	PEND_OFF_ADDR_A
	LD	C,(HL)
	INC	HL
	LD	B,(HL)
	LD	H,B
	LD	L,C
	ADD	HL,DE
	CALL	COPY_ARG_BC
	; Subtract the copied amount from the pending length.
	LD	HL,(QUEUE_LEN)
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	EX	DE,HL
	LD	E,C
	LD	D,B
	OR	A
	SBC	HL,DE
	PUSH	HL
	LD	HL,(QUEUE_LEN)
	POP	DE
	LD	(HL),E
	INC	HL
	LD	(HL),D
	LD	A,D
	OR	E
	JR	Z,.clear_off
	; Pending remains: advance its offset by the copied amount.
	LD	A,(ARG_CH)
	CALL	PEND_OFF_ADDR_A
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	EX	DE,HL
	LD	E,C
	LD	D,B
	ADD	HL,DE
	EX	DE,HL
	LD	A,(ARG_CH)
	CALL	PEND_OFF_ADDR_A
	LD	(HL),E
	INC	HL
	LD	(HL),D
	RET
.clear_off
	LD	A,(ARG_CH)
	CALL	PEND_OFF_ADDR_A
	XOR	A
	LD	(HL),A
	INC	HL
	LD	(HL),A
	RET

; Copy one TCP_RX_DATA segment directly from RX_BUF.  If the caller
; buffer ends in the middle of it, the unconsumed tail is copied to the
; existing per-channel pend slot before RX_BUF can be reused.
; In: HL=source, BC=segment length.  Out: CF only if pend storage fails.
COPY_RX_ARG
	PUSH	HL
	LD	HL,(ARG_IX)
	OR	A
	SBC	HL,BC
	JR	C,.partial
	POP	HL
	CALL	COPY_ARG_BC
	OR	A
	RET
.partial
	; The caller's remaining capacity is the prefix copied; the original
	; segment length is retained in QUEUE_LEN for deriving the tail.
	POP	HL
	LD	(QUEUE_LEN),BC
	LD	DE,(ARG_IX)
	ADD	HL,DE
	LD	(QUEUE_SRC),HL
	LD	HL,(QUEUE_LEN)
	OR	A
	SBC	HL,DE
	LD	(QUEUE_LEN),HL
	LD	B,D
	LD	C,E
	CALL	ADVANCE_COPY_BC
	LD	HL,(QUEUE_SRC)
	LD	BC,(QUEUE_LEN)
	LD	A,(ARG_CH)
	CALL	QUEUE_TCP_DATA
	RET

; Build IX flags for ARG_CH.  Loss is sticky until reported; the optional
; XCHAN bit is driven by queued data/close on the other channel.
; Out: IX = RECV flag word.  Preserves DE -- four call sites set the
; returned byte count in DE BEFORE calling this (see .report_closed,
; .idle, .reset_by_peer, .queue_fail), so a clobber here silently
; corrupts RECV's return value.  PEND_HAS_A below is the one helper
; that used to break that; keep it DE-clean.
BUILD_RECV_FLAGS
	LD	HL,0
	LD	(RECV_FLAGS),HL
	LD	A,(ARG_CH)
	CALL	PEND_LEN_ADDR_A
	LD	A,(HL)
	INC	HL
	OR	(HL)
	JR	Z,.no_more
	LD	HL,RECV_FLAGS
	SET	1,(HL)
.no_more
	LD	A,(ARG_CH)
	CALL	LOST_ADDR_A
	LD	A,(HL)
	OR	A
	JR	Z,.no_lost
	LD	(HL),0
	LD	HL,RECV_FLAGS
	SET	2,(HL)
.no_lost
	LD	A,(ARG_CH)
	XOR	1
	CALL	PEND_HAS_A
	JR	Z,.no_xchan
	LD	HL,RECV_FLAGS
	SET	3,(HL)
.no_xchan
	LD	IX,(RECV_FLAGS)
	RET

; ------------------------------------------------------
; Function 9 - STATUS.
; A=0xFF reports the network state WITHOUT touching the card, so a
; launcher can poll it cheaply.
; ------------------------------------------------------
F_STATUS
	CP	0xFF
	JR	Z,.netstat
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	CALL	GET_CH_STATE
	AND	A
	LD	DE,0
	JR	Z,.check_pending
	LD	DE,UNET_ST_CONN
.check_pending
	LD	A,(ARG_CH)
	CALL	PEND_HAS_A
	JR	Z,.status_done
	LD	A,E
	OR	UNET_ST_RXPEND
	LD	E,A
.status_done
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
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	(ARG_IY),IY
	LD	A,ST_UDPOPEN
	LD	(STAGE),A
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE
	CALL	GET_CH_STATE
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
	LD	HL,(ARG_LPORT)
	LD	A,H
	OR	L
	JR	NZ,.have_lport
	LD	HL,@UDP.DEF_LOCAL_PORT
	LD	A,(ARG_CH)
	ADD	A,L
	LD	L,A			; defaults: channel 0=C400, channel 1=C401
	LD	(ARG_LPORT),HL
.have_lport
	XOR	A
	LD	(@MAIN.CANCELLED),A
	CALL	RESOLVE_AND_ARP
	JP	C,MAP_RESOLVE_FAIL
	LD	A,(ARG_CH)
	CALL	SELECT_CHANNEL
	LD	A,(ARG_CH)
	CALL	PEND_CLEAR_A
	LD	HL,TARGET_IP
	LD	DE,TARGET_MAC
	LD	BC,(ARG_PORT)
	LD	IY,(ARG_LPORT)
	XOR	A
	LD	(FOREIGN_BUSY),A
	CALL	@UDP.OPEN
	LD	A,2
	CALL	SET_CH_STATE			; 2 = UDP
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
; Channel/context helpers.
; ------------------------------------------------------
CHECK_CHANNEL
	CP	UNET_CHANNELS
	JR	NC,.bad
	LD	(ARG_CH),A
	OR	A
	RET
.bad
	SCF
	RET

CH_STATE_ADDR
	LD	A,(ARG_CH)
	JR	CH_STATE_ADDR_A

CH_STATE_ADDR_A
	LD	HL,CH_STATE
	ADD	A,L
	LD	L,A
	RET

GET_CH_STATE
	CALL	CH_STATE_ADDR
	LD	A,(HL)
	RET

GET_CH_STATE_A
	CALL	CH_STATE_ADDR_A
	LD	A,(HL)
	RET

SET_CH_STATE
	PUSH	AF
	CALL	CH_STATE_ADDR
	POP	AF
	LD	(HL),A
	RET

; Map one channel's complete software-stack state into the libraries' working
; BSS.  With exactly two channels, swapping the working state with one
; inactive slot is smaller than keeping two snapshots.  This is memory-only
; and is safe with either ISA window state.
SELECT_CHANNEL
	LD	B,A
	LD	A,(ACTIVE_CH)
	CP	B
	RET	Z
	CP	UNET_CHANNELS
	JR	NC,.first
	PUSH	BC
	LD	HL,TCP_STATE
	LD	DE,@MAIN.CH_TCP_CTX
	LD	B,TCP_CTX_SIZE
	CALL	SWAP_BYTES
	; TCP_PORT_SALT is deliberately global: otherwise two channels opened
	; against one peer can choose the same local port.  Swap the reliable-send
	; and receive scratch after the two-byte salt as a second slice.
	LD	HL,TCP_ACK_WAIT_STATE
	LD	DE,@MAIN.CH_TCP_CTX + TCP_CTX_SIZE
	LD	B,TCP_SWAP_TAIL_SIZE	; NOT TCP_BSS_SIZE-0x28: the tail past
					; TCP_RECV_TIMEOUT is session-global
	CALL	SWAP_BYTES
	LD	HL,UDPLIB_REMOTE_IP
	LD	DE,@MAIN.CH_UDP_CTX
	LD	B,UDPLIB_BSS_SIZE
	CALL	SWAP_BYTES
	POP	BC
.first
	LD	A,B
	LD	(ACTIVE_CH),A
	RET

SWAP_BYTES
.loop
	LD	A,(DE)
	LD	C,(HL)
	LD	(HL),A
	LD	A,C
	LD	(DE),A
	INC	HL
	INC	DE
	DJNZ	.loop
	RET

PEND_LEN_ADDR_A
	ADD	A,A
	LD	HL,@MAIN.CH_PEND_LEN
	ADD	A,L
	LD	L,A
	RET

PEND_OFF_ADDR_A
	ADD	A,A
	LD	HL,@MAIN.CH_PEND_OFF
	ADD	A,L
	LD	L,A
	RET

PEND_BUF_ADDR_A
	LD	HL,@MAIN.CH_PEND_BUF
	OR	A
	RET	Z
	LD	DE,@MAIN.CH_PEND_SIZE
	ADD	HL,DE
	RET

CLOSED_ADDR_A
	LD	HL,@MAIN.CH_CLOSED
	ADD	A,L
	LD	L,A
	RET

LOST_ADDR_A
	LD	HL,@MAIN.CH_LOST
	ADD	A,L
	LD	L,A
	RET

PEND_CLEAR_A
	PUSH	AF
	CALL	PEND_LEN_ADDR_A
	XOR	A
	LD	(HL),A
	INC	HL
	LD	(HL),A
	POP	AF
	PUSH	AF
	CALL	PEND_OFF_ADDR_A
	XOR	A
	LD	(HL),A
	INC	HL
	LD	(HL),A
	POP	AF
	LD	E,A
	LD	D,0
	LD	HL,@MAIN.CH_CLOSED
	ADD	HL,DE
	XOR	A
	LD	(HL),A
	LD	HL,@MAIN.CH_LOST
	ADD	HL,DE
	LD	(HL),A
	LD	A,(FOREIGN_HINT)
	CP	E
	RET	NZ
	LD	A,0xFF
	LD	(FOREIGN_HINT),A
	RET

; Out: NZ if channel A has buffered bytes or a deferred peer close.
; MUST preserve DE: both callers hold a return value there across the
; call -- BUILD_RECV_FLAGS carries RECV's byte count, F_STATUS carries
; the status word it is still assembling.  The pend length used to be
; read into DE as scratch, which silently overwrote both: RECV reported
; the OTHER channel's queued byte count as bytes received (a closing
; channel returned NERR_CLOSED with DE = the peer channel's pending
; length, so the app counted phantom bytes and read stale buffer), and
; STATUS lost UNET_ST_CONN.  Test the two length bytes through A
; instead; same size, no scratch register.
PEND_HAS_A
	LD	(QUEUE_CH),A
	CALL	PEND_LEN_ADDR_A
	LD	A,(HL)
	INC	HL
	OR	(HL)			; NZ if either length byte is set
	PUSH	AF
	LD	A,(QUEUE_CH)
	CALL	CLOSED_ADDR_A
	POP	AF
	OR	(HL)
	RET	NZ
	LD	A,(FOREIGN_HINT)
	LD	HL,QUEUE_CH
	SUB	(HL)
	JR	NZ,.no_hint
	INC	A			; NZ: the queued ring head belongs to A
	RET
.no_hint
	XOR	A			; Z: no pending work for this channel
	RET

; Append one accepted TCP payload to a channel's private queue.
; In: A=channel, HL=source, BC=length. Out: CF=1 if it cannot fit.
QUEUE_TCP_DATA
	LD	(QUEUE_CH),A
	LD	(QUEUE_SRC),HL
	LD	(QUEUE_LEN),BC
	LD	A,B
	OR	C
	RET	Z
	LD	HL,(QUEUE_LEN)
	LD	DE,@MAIN.CH_PEND_SIZE + 1
	OR	A
	SBC	HL,DE
	JR	NC,.full
	LD	A,(QUEUE_CH)
	CALL	PEND_LEN_ADDR_A
	LD	A,(HL)
	INC	HL
	OR	(HL)
	JR	NZ,.full		; one deferred MSS per channel
	LD	A,(QUEUE_CH)
	CALL	PEND_BUF_ADDR_A
	EX	DE,HL			; DE = destination
	LD	HL,(QUEUE_SRC)
	LD	BC,(QUEUE_LEN)
	LDIR
	LD	A,(QUEUE_CH)
	CALL	PEND_LEN_ADDR_A
	LD	BC,(QUEUE_LEN)
	LD	(HL),C
	INC	HL
	LD	(HL),B
	OR	A
	RET
.full
	LD	A,(QUEUE_CH)
	CALL	LOST_ADDR_A
	LD	(HL),1
	SCF
	RET

; TCP.SEND may receive and ACK peer payload while it waits for the cumulative
; ACK.  Move that payload out of the shared frame buffer before another chunk
; or channel operation overwrites it.
CAPTURE_SEND_PENDING
	LD	A,(TCP_ACK_WAIT_STATE)
	CP	2			; ACK_WAIT_RX_PENDING
	RET	NZ
	LD	HL,(TCP_RX_DATA_PTR)
	LD	BC,(TCP_RX_DATA_LEN)
	LD	A,(ARG_CH)
	CALL	QUEUE_TCP_DATA
	XOR	A
	LD	(TCP_ACK_WAIT_STATE),A
	RET

; Check whether the peeked TCP payload fits the owner's pending queue.
; In: A=owner. Out: CF=0 fits, CF=1 would overflow/malformed.
FOREIGN_TCP_FITS
	LD	(QUEUE_CH),A
	CALL	PEND_LEN_ADDR_A
	LD	A,(HL)
	INC	HL
	OR	(HL)
	JR	NZ,.no
	LD	A,(@MAIN.RX_BUF + 14 + 2)
	LD	H,A
	LD	A,(@MAIN.RX_BUF + 14 + 3)
	LD	L,A
	LD	DE,20
	OR	A
	SBC	HL,DE
	JR	C,.no
	LD	A,(@MAIN.RX_BUF + 14 + 20 + 12)
	AND	0xF0
	RRCA
	RRCA
	LD	E,A
	LD	D,0
	OR	A
	SBC	HL,DE			; HL = payload length
	JR	C,.no
	LD	DE,@MAIN.CH_PEND_SIZE + 1
	OR	A
	SBC	HL,DE
	CCF				; carry when total <= CH_PEND_SIZE
	RET
.no
	SCF
	RET

; Called by tcp_lib/udp_lib after a peeked frame did not match the selected
; context.  A foreign TCP frame is processed recursively under its owner's
; saved context, ACKed, and queued.  Other foreign frames remain protected by
; BNRY and make the outer RECV return XCHAN.
; In: A=1 TCP caller, A=2 UDP caller.
; Out: CF=0 not ours; CF=1/A=0 consumed, CF=1/A=1 leave queued in NIC.
HANDLE_FOREIGN_FRAME
	LD	A,(FOREIGN_BUSY)
	OR	A
	JP	NZ,.blocked
	LD	A,(ACTIVE_CH)
	CP	UNET_CHANNELS
	JP	NC,.not_ours
	LD	(FOREIGN_ORIG),A
	XOR	1
	LD	(FOREIGN_OWNER),A
	CALL	GET_CH_STATE_A
	AND	A
	JP	Z,.not_ours
	LD	(FOREIGN_PROTO),A	; owner protocol
	LD	A,(FOREIGN_OWNER)
	CALL	SELECT_CHANNEL
	LD	A,(FOREIGN_PROTO)
	CP	1
	JR	NZ,.check_udp
	CALL	@TCP.IS_TCP_FROM_PEER
	JP	NC,.restore_not_ours
	; From here until .tcp_done, any ACK BUILD_ACK sends for this
	; swapped-in owner context must tell the truth: the owner is not
	; selected, so its only receive capacity is the single-MSS pend
	; slot, not the normal window this channel advertises while
	; active.  Restored to the default below before switching back.
	LD	A,@TCP.TCP_FOREIGN_WIN_HI
	LD	(TCP_ADV_WIN_HI),A
	LD	A,@TCP.TCP_FOREIGN_WIN_LO
	LD	(TCP_ADV_WIN_LO),A
	LD	A,(FOREIGN_OWNER)
	CALL	FOREIGN_TCP_FITS
	JP	C,.tcp_blocked_drain
	LD	A,1
	LD	(FOREIGN_BUSY),A
	LD	HL,1
	LD	(@TCP.RECV_TIMEOUT),HL
	CALL	@TCP.RECV
	JR	NC,.tcp_data
	LD	A,(TCP_STATE)
	CP	@TCP.ST_CLOSE_WAIT
	JR	Z,.tcp_fin
	LD	A,(TCP_LAST_FAIL)
	CP	@TCP.F_RST
	JR	NZ,.tcp_done		; timeout/F_OTHER after a consumed pure ACK
	LD	A,(FOREIGN_OWNER)
	CALL	CH_STATE_ADDR_A
	LD	(HL),0
	JR	.tcp_done
.tcp_fin
	LD	A,(FOREIGN_OWNER)
	CALL	CLOSED_ADDR_A
	LD	(HL),1
	LD	HL,(TCP_RX_DATA_PTR)
	LD	BC,(TCP_RX_DATA_LEN)
.tcp_data
	LD	A,(FOREIGN_OWNER)
	CALL	QUEUE_TCP_DATA
.tcp_done
	XOR	A
	LD	(FOREIGN_BUSY),A
	LD	A,0xFF
	LD	(FOREIGN_HINT),A
	LD	A,@TCP.TCP_RECV_WIN_HI
	LD	(TCP_ADV_WIN_HI),A
	LD	A,@TCP.TCP_RECV_WIN_LO
	LD	(TCP_ADV_WIN_LO),A
	LD	A,(FOREIGN_ORIG)
	CALL	SELECT_CHANNEL
	XOR	A
	SCF
	RET
.check_udp
	CALL	@UDP.MATCH
	JR	C,.restore_not_ours
	; A UDP datagram remains in the NIC ring.  RECV can switch channels and
	; deliver it without a fixed-size software defer buffer.
.restore_blocked
	LD	A,(FOREIGN_OWNER)
	LD	(FOREIGN_HINT),A
	LD	A,(FOREIGN_ORIG)
	CALL	SELECT_CHANNEL
.blocked
	LD	A,1
	SCF
	RET
.restore_not_ours
	LD	A,(FOREIGN_ORIG)
	CALL	SELECT_CHANNEL
.not_ours
	OR	A
	RET

.tcp_blocked_drain
	; The owner's single-MSS pend slot cannot take this segment: it
	; is still occupied by an earlier undrained one, or (rarely) this
	; segment alone exceeds CH_PEND_SIZE even with an empty slot.
	; Previously this frame was left at the ring head (CF=1/A=1
	; below), which stalls the WHOLE ring -- the DP8390 is a strict
	; FIFO -- until the app happens to read exactly this channel.  If
	; the app is busy on the OTHER channel instead (the common case:
	; e.g. checking a control reply while a data transfer is still
	; landing), every later frame for every channel becomes
	; unreachable forever.  Consume it instead.  Nothing is queued --
	; there is no room -- but re-ACKing the owner's CURRENT RCV_NXT
	; with an honest window (0 while the slot stays occupied,
	; TCP_FOREIGN_WIN once it was just this one oversized segment)
	; tells the peer to slow down instead of silently inviting more
	; data we cannot hold.  RCV_NXT does not advance, so the peer's
	; own retransmit timer resends the segment once the app drains
	; the queue and the window reopens.
	LD	A,(FOREIGN_OWNER)
	CALL	PEND_LEN_ADDR_A
	LD	A,(HL)
	INC	HL
	OR	(HL)
	JR	Z,.drain_ack		; pend empty: only this one segment was too big
	XOR	A
	LD	(TCP_ADV_WIN_HI),A
	LD	(TCP_ADV_WIN_LO),A
.drain_ack
	CALL	@TCP.SEND_DUP_ACK
	LD	HL,@MAIN.RX_HDR
	CALL	@RTL.COMMIT_PACKET
	JR	.tcp_done

; Forget both contexts and their receive queues.  Used after NETINIT has
; closed the old links and reinitialised the card.
RESET_CHANNEL_STATE
	XOR	A
	LD	(CH_STATE),A
	LD	(CH_STATE+1),A
	LD	HL,TCP_STATE
	LD	(HL),A
	LD	DE,TCP_STATE+1
	; = DLL_BSS_SIZE - BSS_TCP - 1.  Literal, NOT a computed
	; difference (relocation rule); recompute by hand and update
	; this comment's numbers whenever DLL_BSS_SIZE or BSS_TCP moves.
	; 0x0E35 - 0x01A5 - 1 = 0x0C8F.
	LD	BC,0x0C8F		; TCP BSS .. end of DLL BSS, minus first byte
	LDIR
	; The bulk zero above also cleared TCP_ADV_WIN_HI/LO (it sits
	; inside the zeroed span); restore it to the normal window --
	; HANDLE_FOREIGN_FRAME only ever overrides it for the duration of
	; one nested call and always restores this same default after.
	LD	A,@TCP.TCP_RECV_WIN_HI
	LD	(TCP_ADV_WIN_HI),A
	LD	A,@TCP.TCP_RECV_WIN_LO
	LD	(TCP_ADV_WIN_LO),A
	LD	A,0xFF			; 0xFF = no live context selected
	LD	(ACTIVE_CH),A
	LD	(FOREIGN_HINT),A
	RET

; Close one selected channel.  Idempotent; pending bytes are discarded.
CLOSE_CHANNEL
	CALL	GET_CH_STATE
	AND	A
	JR	Z,.clear
	LD	A,(ARG_CH)
	CALL	SELECT_CHANNEL
	CALL	GET_CH_STATE
	CP	2
	JR	Z,.udp
	CALL	@ISA.ISA_OPEN
	CALL	@TCP.CLOSE
	CALL	@ISA.ISA_CLOSE
	JR	.clear
.udp
	CALL	@UDP.CLOSE
.clear
	XOR	A
	CALL	SET_CH_STATE
	LD	A,(ARG_CH)
	CALL	PEND_CLEAR_A
	RET

; Close every channel; leave the NIC initialised.
CLOSE_LINK
	LD	A,(ARG_CH)
	PUSH	AF
	XOR	A
	LD	(ARG_CH),A
	CALL	CLOSE_CHANNEL
	LD	A,1
	LD	(ARG_CH),A
	CALL	CLOSE_CHANNEL
	POP	AF
	LD	(ARG_CH),A
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
	CALL	SET_CH_STATE
	LD	A,(ARG_CH)
	CALL	PEND_CLEAR_A
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
; Caller-buffer validation.  Matches the frozen ABI contract in
; unet.inc: WIN0 pointers are accepted -- mapping a caller-owned page
; over DSS/system memory there, and restoring it safely, is entirely
; the caller's duty, not this backend's to police.  Window 3 (the ISA
; aperture) and the DLL's own window are still rejected: a buffer
; there is not merely risky, it is physically the wrong data (the ISA
; window swaps under us mid-call, and our own window holds our code
; and BSS, not the caller's).  Out: CF=1 invalid.  Preserves BC, DE, HL.
; ------------------------------------------------------
CHECK_BUF
	LD	A,H
	AND	0xC0
	CP	0xC0
	JR	Z,.bad				; window 3: ISA (any H in 0xC0..0xFF)
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
CH_STATE	DB 0,0			; per channel: 0 closed, 1 TCP, 2 UDP
ACTIVE_CH	DB 0xFF			; context currently mapped into tcp/udp BSS
ARG_CH		DB 0			; channel argument of the call in progress
CANCEL_MODE	DB 0			; SETOPT CANCELKEYS
STAGE		DB 0			; ST_* of the last operation
LAST_NERR	DB 0			; last status returned
ARG_A		DB 0
ARG_DE		DW 0
ARG_IX		DW 0
ARG_IY		DW 0
ARG_PORT	DW 0
ARG_LPORT	DW 0
SEND_DONE	DW 0
CHUNK_LEN	DW 0
COPY_LEN	DW 0
	; SEND scratch and RECV flag assembly are never live together.
RECV_FLAGS	EQU CHUNK_LEN
FOREIGN_BUSY	DB 0
FOREIGN_ORIG	DB 0
FOREIGN_OWNER	DB 0
FOREIGN_PROTO	DB 0
FOREIGN_HINT	DB 0xFF			; channel owning the current NIC ring head
	; TARGET_IP/MAC are setup scratch: by the time an operation can
	; capture diagnostics, the tuple has already been copied into the
	; protocol context.  Overlay them on the existing call scratch.
TARGET_IP	EQU SEND_DONE
TARGET_MAC	EQU SEND_DONE + 4
QUEUE_CH	EQU ARG_A
QUEUE_SRC	EQU SEND_DONE
QUEUE_LEN	EQU SEND_DONE + 2
DIAG_REGS	EQU TARGET_IP
DIAG_TX		EQU FOREIGN_OWNER

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

; The whole L1 image is a 32-byte header, this code image, and one
; relocation bit per code byte.  0x38C7 is the exact largest code image
; for which 32 + size + ceil(size/8) still fits libman's 16 KiB window.
	ASSERT $ <= DLL_IMAGE_ORIGIN + 0x38C7
