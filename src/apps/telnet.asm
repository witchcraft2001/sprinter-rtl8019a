; ======================================================
; TELNET.EXE - interactive Telnet / raw ANSI client for
; Sprinter DSS over the RTL8019AS native TCP stack.
;
; Ported from sprinter_wifi/network TELNET. Retains Telnet IAC,
; ANSI/VT100, Zmodem auto-start, Ymodem Alt+D/Alt+U/Alt+G,
; the 80x31 terminal area, status row, and navigation keys.
; License: BSD 3-Clause.
;
; Usage: TELNET host[:port] | host [port]
; Quit: Alt+X
; ======================================================

EXE_VERSION		EQU 1
STACK_TOP		EQU 0x8000	; DSS entry stack; used only until START
					; maps WIN2 and switches to SCROLL_STACK_TOP
SCROLL_STACK_TOP	EQU 0xBFF0	; the one real stack: WIN2, see START
WIN2_BASE		EQU 0x8000
HOST_SIZE		EQU 96
PORT_SIZE		EQU 8
NEG_BUF_SIZE		EQU 96
RECV_POLL_MS		EQU 20
CR			EQU 13
LF			EQU 10

TN_IAC			EQU 255
TN_DONT			EQU 254
TN_DO			EQU 253
TN_WONT			EQU 252
TN_WILL			EQU 251
TN_SB			EQU 250
TN_SE			EQU 240
TNOPT_BINARY		EQU 0
TNOPT_ECHO		EQU 1
TNOPT_SGA		EQU 3
TNOPT_TTYPE		EQU 24
TNOPT_NAWS		EQU 31
TTYPE_IS		EQU 0
TTYPE_SEND		EQU 1

S_NORMAL		EQU 0
S_IAC			EQU 1
S_NEG			EQU 2
S_SB			EQU 3
S_SB_IAC		EQU 4

O_NORMAL		EQU 0
O_ESC			EQU 1
O_CSI			EQU 2
O_OSC			EQU 3
O_OSC_ESC		EQU 4

SCREEN_COLS		EQU 80
SCREEN_ROWS		EQU 32
STATUS_ROWS		EQU 1
TERM_COLS		EQU SCREEN_COLS
TERM_ROWS		EQU SCREEN_ROWS - STATUS_ROWS
STATUS_ROW		EQU SCREEN_ROWS - 1
STATUS_ATTR		EQU 0x17
DEF_ATTR		EQU 0x07
MAX_PARAMS		EQU 8
SC_SPIN			EQU 1
SC_CLOCK		EQU 3
SC_STATE		EQU 13
SC_IDLELBL		EQU 20
SC_IDLENUM		EQU 25
SC_HOST			EQU 31

DSS_LOCATE		EQU 0x52
DSS_SCROLL		EQU 0x55
DSS_WRCHAR		EQU 0x58

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	DEFINE LIBBSS_CUSTOM
LIBBSS_BASE		EQU 0xAB00
CMDL_BSS_BASE		EQU 0xAD00
RESOLVE_BSS_BASE	EQU 0xAE00
TCP_BSS_BASE		EQU 0xAE40
UDP_BSS_BASE		EQU 0xAE80
ICMP_BSS_BASE		EQU 0xAEA0
	INCLUDE "memmap.inc"
	INCLUDE "rtl8019.inc"

	DEFINE USE_UTIL_EXIT_NO_NIC
	DEFINE USE_RTL_INIT_NORMAL
	DEFINE USE_RTL_SEND_FRAME
	DEFINE USE_RTL_WAIT_PTX
	DEFINE USE_RTL_RING_HAS_PACKET
	DEFINE USE_RTL_READ_PACKET
	DEFINE USE_ARP_BUILD_REQUEST
	DEFINE USE_ARP_ANSWER
	DEFINE USE_NETENV
	DEFINE USE_CMDL
	DEFINE USE_RESOLVE
	DEFINE USE_TCP

	MODULE MAIN

	ORG 0x4100

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0100
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START
	DW START
	DW STACK_TOP
	DS 234,0

	ORG 0x4200

START
	; Save the DSS PSP pointer before the allocation syscall can clobber IX.
	LD	(.RESTORE_CMD_PTR + 2),IX
	CALL	INIT_RUNTIME_PAGE
	JP	C,INIT_MEMORY_ERROR
	; From here on the stack lives in the WIN2 page and MUST NEVER move
	; back to STACK_TOP: a stack anywhere in WIN1 is fatal across any DSS
	; console output that scrolls.  DSS PCHARS/Scroll reach BIOS WIN_MOVE,
	; which maps video page 0x50 over WIN1 (SLOT1) for the block copy and
	; then restores SLOT1 with "POP AF / OUT (SLOT1),A" -- the POP happens
	; while WIN1 is still the video page (sprinter_bios
	; FUNC_LOW_PRINT.ASM, WIN_COPY_WIN1 / WIN_RESTORE).  With the stack in
	; WIN1 that POP reads video RAM, SLOT1 is restored to a random page,
	; and the machine dies inside the print.  Only the two syscalls in
	; INIT_RUNTIME_PAGE above run on the WIN1 stack; they print nothing.
	LD	SP,SCROLL_STACK_TOP
.RESTORE_CMD_PTR
	LD	IX,0			; self-modified by the first instruction
	LD	(CMDL_SOURCE_PTR),IX
	PRINTLN	MSG_START
	XOR	A
	LD	(CANCELLED),A
	LD	(SESSION_ACTIVE),A
	LD	(LINK_DOWN),A
	CALL	PARSE_ARGS
	JP	C,USAGE

	LD	HL,N_NET_IP
	LD	DE,OUR_IP
	CALL	@NETENV.REQUIRE_IP
	LD	HL,N_NET_MAC
	LD	DE,OUR_MAC
	CALL	@NETENV.REQUIRE_MAC

	LD	A,1
	LD	(@ISA.ISA_SLOT),A
	CALL	@RTL.INIT_BASE
	JP	C,@UTIL.EXIT_NO_NIC
	CALL	@RTL.RESET
	JP	C,NET_ERROR_OPEN
	LD	HL,OUR_MAC
	LD	A,RCR_AB
	CALL	@RTL.INIT_NORMAL
	LD	HL,OUR_MAC
	LD	(@ARP.OUR_MAC_PTR),HL
	LD	HL,OUR_IP
	LD	(@ARP.OUR_IP_PTR),HL

	LD	HL,HOST_BUFF
	LD	DE,TARGET_IP
	CALL	@RESOLVE.HOST
	JP	C,RESOLVE_ERROR
	LD	HL,TARGET_IP
	CALL	@RESOLVE.NEXT_HOP_FOR
	JP	C,NET_ERROR_OPEN
	LD	HL,RESOLVE_NEXT_HOP_MAC
	LD	DE,TCP_REMOTE_MAC
	LD	BC,6
	LDIR
	LD	HL,TARGET_IP
	LD	DE,TCP_REMOTE_IP
	LD	BC,4
	LDIR
	LD	HL,(PORT_VALUE)
	LD	A,H
	LD	(TCP_REMOTE_PORT_HI),A
	LD	A,L
	LD	(TCP_REMOTE_PORT_LO),A

	CALL	@ISA.ISA_CLOSE
	PRINT	MSG_CONNECTING
	PRINT	HOST_BUFF
	PRINT	MSG_COLON
	PRINTLN	PORT_BUFF
	CALL	@ISA.ISA_OPEN
	CALL	@TCP.OPEN
	JP	C,TCP_OPEN_ERROR
	CALL	@ISA.ISA_CLOSE

	; Runtime BSS is not part of the EXE image. Clear terminal/session state
	; explicitly before the emulator starts using it.
	LD	HL,TN_STATE
	LD	DE,TN_STATE + 1
	LD	BC,TRANSFER_BSS_END - TN_STATE - 1
	LD	(HL),0
	LDIR
	LD	A,0xFF
	LD	(LAST_SEC),A
	LD	A,'H'
	LD	(@ZM.FAIL_STAGE),A

	CALL	INIT_VMODE
	XOR	A
	LD	(TN_STATE),A
	LD	(OUT_STATE),A
	LD	(NEG_LEN),A
	LD	(TX_BINARY),A
	LD	(TN_PEER_SEEN),A
	LD	(TN_BINARY_SENT),A
	LD	(SEND_FAILS),A
	LD	(IDLE_SECS),A
	LD	(SPIN_TICK),A
	LD	(SPIN_IDX),A
	LD	A,1
	LD	(SESSION_ACTIVE),A
	CALL	INIT_SCREEN
	CALL	DRAW_STATUS

MAIN_LOOP
.DRAIN_KEYS
	CALL	HANDLE_KEY
	JR	C,QUIT
	JR	NZ,.DRAIN_KEYS
	LD	A,(LINK_DOWN)
	OR	A
	JP	NZ,REMOTE_CLOSED
	CALL	STATUS_TICK
	; Use the same buffered stream adapter as Z/Ymodem. A transfer can finish
	; with terminal text still in STREAM_LEFT; bypassing this adapter here
	; would strand that prompt forever.
	LD	HL,@ZM.RXBUF
	LD	BC,ZM_RXBUF_SIZE
	LD	DE,RECV_POLL_MS
	CALL	RX_DRAIN_WAIT
	JR	NC,.GOT_DATA
	LD	A,(TCP_STATE)
	CP	3
	JP	Z,REMOTE_CLOSED
	LD	A,(TCP_LAST_FAIL)
	CP	2
	JR	Z,MAIN_LOOP
	LD	A,1
	LD	(CLOSE_ERROR),A
	JP	REMOTE_CLOSED
.GOT_DATA
	XOR	A
	LD	(IDLE_SECS),A
	LD	HL,@ZM.RXBUF
	CALL	PROCESS_RX
	CALL	SYNC_CURSOR
	CALL	FLUSH_NEG
	JR	MAIN_LOOP

REMOTE_CLOSED
	LD	A,1
	LD	(LINK_DOWN),A
	CALL	REDRAW_DYNAMIC
	CALL	NET_CLOSE
	CALL	REST_VMODE
	PRINTLN	MSG_CLOSED
	LD	A,(CLOSE_ERROR)
	OR	A
	JR	NZ,.FAIL
	JP	@UTIL.EXIT_OK
.FAIL
	LD	B,3
	JP	@UTIL.EXIT_FAIL

QUIT
	CALL	NET_CLOSE
	CALL	REST_VMODE
	PRINTLN	MSG_DONE
	JP	@UTIL.EXIT_OK

USAGE
	PRINTLN	MSG_USAGE
	LD	B,1
	JP	@UTIL.EXIT_FAIL

RESOLVE_ERROR
	CALL	@ISA.ISA_CLOSE
	PRINTLN	MSG_RESOLVE_ERROR
	LD	B,3
	JP	@UTIL.EXIT_FAIL

NET_ERROR_OPEN
	CALL	@RTL.SNAPSHOT_REGS
	CALL	@ISA.ISA_CLOSE
	PRINTLN	MSG_NET_ERROR
	LD	B,3
	JP	@UTIL.EXIT_FAIL

TCP_OPEN_ERROR
	CALL	@RTL.SNAPSHOT_REGS
	CALL	@ISA.ISA_CLOSE
	PRINT	MSG_TCP_ERROR
	LD	A,(TCP_LAST_FAIL)
	CALL	@UTIL.PRINT_HEX_A
	PRINTLN	LINE_END
	LD	B,3
	JP	@UTIL.EXIT_FAIL

; ------------------------------------------------------
; HANDLE_KEY: poll the keyboard once.
;   Out: CF=1            -> Alt+X pressed (quit).
;        CF=0, ZF=0 (NZ) -> a key was handled (caller drains for more).
;        CF=0, ZF=1 (Z)  -> no key pending.
; Alt+X is the ONLY quit; every other key is forwarded to the host. Enter is
; sent as the keyboard CR after TRANSMIT-BINARY is accepted, or as NVT CR,LF
; before that. Any other ASCII (including control codes such as Esc 0x1B, Tab,
; Backspace) is sent as-is, so BBSes that navigate with Esc work. Keys with no ASCII
; (E=0) carry a scancode in D - arrows and Home/End/PgUp/PgDn/Del are mapped to
; their ANSI sequences (SEND_SPECIAL_KEY); anything else is consumed.
; ------------------------------------------------------
HANDLE_KEY
	DSS_EXEC	DSS_SCANKEY
	JP	Z,.NO_KEY			; no key pressed
	; Alt+X quits (scancode in D, same check as WTERM).
	LD	A,D
	CP	0xAB
	JR	NZ,.CHECK_YMODEM
	LD	A,B
	AND	KB_ALT
	JR	Z,.SEND
	SCF					; quit
	RET
.CHECK_YMODEM
	LD	A,B
	AND	KB_ALT
	JR	Z,.SEND
	LD	A,D
	AND	0x7F				; DSS sets bit 7 on a pressed positional code
	CP	0x1F				; D position code -> Alt+D: receive from remote sb
	JR	Z,.YMODEM_DOWNLOAD
	CP	0x21				; G position code -> Alt+G: receive Ymodem-G
	JR	Z,.YMODEM_G_DOWNLOAD
	CP	0x16				; U position code -> Alt+U: send to remote rb
	JR	NZ,.SEND
	CALL	YM.SEND
	JR	.YMODEM_DONE
.YMODEM_DOWNLOAD
	CALL	YM.RECEIVE
	JR	.YMODEM_DONE
.YMODEM_G_DOWNLOAD
	CALL	YM.RECEIVE_G
.YMODEM_DONE
	XOR	A
	LD	(ZTRIG),A
	LD	(TN_STATE),A
	LD	(OUT_STATE),A
	LD	(NEG_LEN),A
	CALL	SYNC_CURSOR
	JR	.HANDLED
.SEND
	LD	A,E
	AND	A
	JR	Z,.SPECIAL			; no ASCII -> arrow/navigation key (scancode in D)
	CP	CR
	JR	Z,.SEND_ENTER
	LD	(TX_KEY_BUF),A
	LD	HL,TX_KEY_BUF
	LD	BC,1
	CALL	WIFI.UART_TX_BUFFER
	CALL	NOTE_TX_RESULT
	JR	.HANDLED
.SPECIAL
	CALL	SEND_SPECIAL_KEY		; D = scancode; sends an ANSI seq if known
	CALL	NOTE_TX_RESULT
	JR	.HANDLED
.SEND_ENTER
	LD	A,CR
	LD	(TX_KEY_BUF),A
	LD	BC,1
	LD	A,(TN_PEER_SEEN)
	OR	A
	JR	Z,.SEND_ENTER_BYTES		; raw TCP/PTY: Enter is one keyboard CR
	LD	A,(TX_BINARY)
	OR	A
	JR	NZ,.SEND_ENTER_BYTES		; binary mode has no NVT CR translation
	LD	A,LF
	LD	(TX_KEY_BUF+1),A
	INC	BC				; default NVT newline is CR,LF
.SEND_ENTER_BYTES
	LD	HL,TX_KEY_BUF
	CALL	WIFI.UART_TX_BUFFER
	CALL	NOTE_TX_RESULT
.HANDLED
	OR	1				; ZF=0 (key handled), CF=0
	RET

.NO_KEY
	XOR	A				; ZF=1 (no key), CF=0
	RET

; ------------------------------------------------------
; SEND_SPECIAL_KEY: D = scancode of a non-ASCII key. If it is a known
; navigation key, transmit its ANSI escape sequence to the host; otherwise do
; nothing. Scancodes are the DSS values used by the Sprinter text editor.
; ------------------------------------------------------
SEND_SPECIAL_KEY
	LD	HL,KEYMAP
.scan
	LD	A,(HL)				; scancode entry (0 = end)
	OR	A
	RET	Z				; unknown key -> ignore
	CP	D
	JR	Z,.found
	INC	HL				; skip scancode + 2-byte seq pointer
	INC	HL
	INC	HL
	JR	.scan
.found
	INC	HL
	LD	E,(HL)
	INC	HL
	LD	D,(HL)				; DE -> ASCIIZ sequence
	EX	DE,HL				; HL -> sequence
; SEND_ASCIIZ: transmit the ASCIIZ string at HL over TCP.
SEND_ASCIIZ
	PUSH	HL
	LD	BC,0
.len
	LD	A,(HL)
	OR	A
	JR	Z,.go
	INC	HL
	INC	BC
	JR	.len
.go
	POP	HL
	JP	WIFI.UART_TX_BUFFER

; Scancode -> ANSI sequence map (terminated by scancode 0). Arrows use normal
; cursor-key mode (CSI), the form BBS menus expect.
KEYMAP
	DB	0x58
	DW	SEQ_UP
	DB	0x52
	DW	SEQ_DOWN
	DB	0x56
	DW	SEQ_RIGHT
	DB	0x54
	DW	SEQ_LEFT
	DB	0x57
	DW	SEQ_HOME
	DB	0x51
	DW	SEQ_END
	DB	0x59
	DW	SEQ_PGUP
	DB	0x53
	DW	SEQ_PGDN
	DB	0x4F
	DW	SEQ_DEL
	DB	0
SEQ_UP		DB 27,"[A",0
SEQ_DOWN	DB 27,"[B",0
SEQ_RIGHT	DB 27,"[C",0
SEQ_LEFT	DB 27,"[D",0
SEQ_HOME	DB 27,"[H",0
SEQ_END		DB 27,"[F",0
SEQ_PGUP	DB 27,"[5~",0
SEQ_PGDN	DB 27,"[6~",0
SEQ_DEL		DB 27,"[3~",0


; PROCESS_RX: run BC bytes at HL through the telnet IAC state machine.
; Plain data bytes go to OUTPUT_BYTE; negotiation replies are queued in NEG_BUF.
; ------------------------------------------------------
PROCESS_RX
.NEXT
	LD	A,B
	OR	C
	RET	Z
	LD	A,(HL)
	INC	HL
	DEC	BC
	LD	(ZM_BYTE),A			; keep the raw byte for Zmodem auto-detect
	CP	'C'				; remember rb's CRC request if Alt+U follows
	JR	NZ,.NOT_YM_C
	LD	A,1
	LD	(YM_C_PENDING),A
	JR	.YM_C_TRACKED
.NOT_YM_C
	XOR	A
	LD	(YM_C_PENDING),A
.YM_C_TRACKED
	PUSH	BC,HL
	LD	A,(ZM_BYTE)
	LD	C,A				; C = current byte
	CALL	PROCESS_RX_BYTE
	POP	HL,BC
	; Watch the stream for a Zmodem header start ("*" "*" ZDLE); on a hit hand
	; the rest of the batch (and the live socket) to the Zmodem engine.
	LD	A,(ZM_BYTE)
	CALL	ZM_TRIGGER
	JR	C,.ZMODEM
	JR	.NEXT
.ZMODEM
	PUSH	BC,HL
	CALL	FLUSH_NEG			; finish pending Telnet BINARY replies before raw data
	POP	HL,BC
	CALL	ZM.RECEIVE			; HL=tail ptr, BC=remaining count
	; The binary Zmodem stream (or an aborted transfer) can leave the IAC and
	; ANSI state machines mid-sequence; reset parser state, preserving the
	; transfer log and status row rendered through the terminal emulator.
	XOR	A
	LD	(ZTRIG),A
	LD	(TN_STATE),A
	LD	(OUT_STATE),A
	LD	(NEG_LEN),A
	; Zmodem may have read the server's post-transfer prompt in the same TCP
	; burst as ZFIN/OO. Feed that raw tail back through Telnet/ANSI now.
	CALL	ZM.REPLAY_TAIL
	CALL	SYNC_CURSOR
	RET					; batch consumed by Zmodem; resume terminal

; ZM_TRIGGER: feed one stream byte (A) to the "*" "*" ZDLE detector.
; Out: CF=1 when the sequence just completed (start a Zmodem transfer).
ZM_TRIGGER
	CP	'*'
	JR	Z,.star
	CP	0x18				; ZDLE
	JR	Z,.dle
	XOR	A
	LD	(ZTRIG),A
	OR	A				; CF=0
	RET
.star
	LD	A,(ZTRIG)
	CP	2
	JR	NC,.keep
	INC	A
	LD	(ZTRIG),A
.keep
	OR	A				; CF=0
	RET
.dle
	LD	A,(ZTRIG)
	CP	2
	JR	C,.nofire
	XOR	A
	LD	(ZTRIG),A
	SCF					; fire
	RET
.nofire
	XOR	A
	LD	(ZTRIG),A
	OR	A
	RET

; In: C = byte. Dispatches on TN_STATE.
PROCESS_RX_BYTE
	LD	A,(TN_STATE)
	CP	S_IAC
	JR	Z,.ST_IAC
	CP	S_NEG
	JR	Z,.ST_NEG
	CP	S_SB
	JR	Z,.ST_SB
	CP	S_SB_IAC
	JR	Z,.ST_SB_IAC
; --- S_NORMAL ---
	LD	A,C
	CP	TN_IAC
	JR	Z,.TO_IAC
	JP	OUTPUT_BYTE
.TO_IAC
	LD	A,S_IAC
	LD	(TN_STATE),A
	RET
; --- S_IAC: byte after an IAC ---
.ST_IAC
	CALL	ENSURE_TELNET_BINARY		; a real IAC stream distinguishes Telnet from raw TCP
	LD	A,C
	CP	TN_IAC
	JR	Z,.IAC_LITERAL			; IAC IAC -> literal 0xFF
	CP	TN_SB
	JR	Z,.IAC_SB
	CP	TN_WILL
	JR	C,.IAC_OTHER			; <251 (and !=250): 1-byte command, ignore
	CP	TN_DONT+1
	JR	NC,.IAC_OTHER			; >254: ignore
	; WILL/WONT/DO/DONT -> remember command, expect option next.
	LD	A,C
	LD	(TN_CMD),A
	LD	A,S_NEG
	LD	(TN_STATE),A
	RET
.IAC_LITERAL
	LD	A,S_NORMAL
	LD	(TN_STATE),A
	LD	C,TN_IAC
	JP	OUTPUT_BYTE
.IAC_SB
	XOR	A
	LD	(SB_IDX),A			; start capturing the subnegotiation
	LD	A,S_SB
	LD	(TN_STATE),A
	RET
.IAC_OTHER
	LD	A,S_NORMAL
	LD	(TN_STATE),A
	RET
; --- S_NEG: C = option byte, TN_CMD = WILL..DONT ---
.ST_NEG
	LD	A,S_NORMAL
	LD	(TN_STATE),A
	JP	NEGOTIATE			; uses C = option
; --- S_SB: capture the first two data bytes (option, subcommand), skip the
; rest, until IAC SE. We only need <option><subcommand> to recognise the
; TERMINAL-TYPE SEND request. ---
.ST_SB
	LD	A,C
	CP	TN_IAC
	JR	Z,.SB_TO_IAC
	LD	A,(SB_IDX)
	CP	2
	RET	NC				; already captured option + subcommand
	LD	E,A
	LD	D,0
	LD	HL,SB_OPT			; SB_OPT, SB_SUB are consecutive
	ADD	HL,DE
	LD	(HL),C
	INC	A
	LD	(SB_IDX),A
	RET
.SB_TO_IAC
	LD	A,S_SB_IAC
	LD	(TN_STATE),A
	RET
.ST_SB_IAC
	LD	A,C
	CP	TN_SE
	JR	Z,.SB_END
	; IAC <other> inside SB (e.g. escaped IAC IAC) -> stay in SB.
	LD	A,S_SB
	LD	(TN_STATE),A
	RET
.SB_END
	LD	A,S_NORMAL
	LD	(TN_STATE),A
	; TERMINAL-TYPE SEND -> answer with our terminal type ("ANSI").
	LD	A,(SB_OPT)
	CP	TNOPT_TTYPE
	RET	NZ
	LD	A,(SB_SUB)
	CP	TTYPE_SEND
	RET	NZ
	LD	HL,TTYPE_REPLY
	LD	B,TTYPE_REPLY_LEN
	JP	QUEUE_BYTES

; A raw TCP/PTY service must never receive proactive IAC bytes: they become
; visible shell input. Once the peer itself sends IAC, identify it as Telnet
; and request an 8-bit-clean path in both directions exactly once.
ENSURE_TELNET_BINARY
	LD	A,1
	LD	(TN_PEER_SEEN),A
	LD	A,(TN_BINARY_SENT)
	OR	A
	RET	NZ
	LD	A,1
	LD	(TN_BINARY_SENT),A
	LD	HL,TN_BINARY_INIT
	LD	B,TN_BINARY_INIT_LEN
	JP	QUEUE_BYTES

; ------------------------------------------------------
; NEGOTIATE: respond to an option demand. In: TN_CMD = WILL/WONT/DO/DONT,
; C = option. Minimal converging policy (only demands get a reply):
;   WILL ECHO  -> DO ECHO    (let server echo our keys)
;   WILL SGA   -> DO SGA
;   WILL <x>   -> DONT <x>
;   DO   SGA   -> WILL SGA   (we will suppress go-ahead)
;   DO   TTYPE -> WILL TTYPE (then answer SB SEND with "ANSI" -> full ANSI art)
;   DO   NAWS  -> WILL NAWS  + send our 80x31 window size via SB
;   DO   <x>   -> WONT <x>
;   WONT/DONT  -> ignored    (acks; replying would risk a negotiation loop)
; Reply bytes are appended to NEG_BUF and sent later by FLUSH_NEG.
; ------------------------------------------------------
NEGOTIATE
	; Our initial WILL BINARY takes effect only when the peer answers DO.
	; In binary mode RFC 1123 forbids NVT CR translation, so HANDLE_KEY must
	; know whether Enter is a literal keyboard CR or an NVT CR,LF newline.
	LD	A,C
	CP	TNOPT_BINARY
	JR	NZ,.DISPATCH
	LD	A,(TN_CMD)
	CP	TN_DO
	JR	Z,.TX_BINARY_ON
	CP	TN_DONT
	JR	NZ,.DISPATCH
	XOR	A
	LD	(TX_BINARY),A
	JR	.DISPATCH
.TX_BINARY_ON
	LD	A,1
	LD	(TX_BINARY),A
.DISPATCH
	LD	A,(TN_CMD)
	CP	TN_WILL
	JR	Z,.ON_WILL
	CP	TN_DO
	JR	Z,.ON_DO
	RET					; WONT / DONT -> no reply
.ON_WILL
	LD	A,C
	CP	TNOPT_BINARY
	JR	Z,.REPLY_DO
	CP	TNOPT_ECHO
	JR	Z,.REPLY_DO
	CP	TNOPT_SGA
	JR	Z,.REPLY_DO
	LD	A,TN_DONT
	JP	QUEUE_CMD
.REPLY_DO
	LD	A,TN_DO
	JP	QUEUE_CMD
.ON_DO
	LD	A,C
	CP	TNOPT_BINARY
	JR	Z,.REPLY_WILL
	CP	TNOPT_SGA
	JR	Z,.REPLY_WILL
	CP	TNOPT_TTYPE
	JR	Z,.REPLY_WILL
	CP	TNOPT_NAWS
	JR	Z,.DO_NAWS
	LD	A,TN_WONT
	JP	QUEUE_CMD
.REPLY_WILL
	LD	A,TN_WILL
	JP	QUEUE_CMD
.DO_NAWS
	LD	A,TN_WILL
	CALL	QUEUE_CMD			; IAC WILL NAWS
	LD	HL,NAWS_REPLY			; IAC SB NAWS 0 80 0 25 IAC SE
	LD	B,NAWS_REPLY_LEN
	JP	QUEUE_BYTES

; ------------------------------------------------------
; QUEUE_CMD: append a 3-byte option reply (IAC, cmd in A, opt in C) to NEG_BUF.
; QUEUE_BYTES: append B bytes from HL to NEG_BUF.
; NEG_PUT_BYTE: append the byte in A to NEG_BUF (dropped if full). All three
; preserve BC, DE, HL so callers can loop. NEG_PUT_BYTE clobbers A.
; ------------------------------------------------------
QUEUE_CMD
	PUSH	BC
	LD	B,A				; B = reply command
	LD	A,TN_IAC
	CALL	NEG_PUT_BYTE
	LD	A,B
	CALL	NEG_PUT_BYTE
	LD	A,C
	CALL	NEG_PUT_BYTE
	POP	BC
	RET

QUEUE_BYTES
	LD	A,B
	AND	A
	RET	Z
.LOOP
	LD	A,(HL)
	CALL	NEG_PUT_BYTE
	INC	HL
	DJNZ	.LOOP
	RET

NEG_PUT_BYTE
	PUSH	BC,DE,HL
	LD	C,A				; C = byte to store
	LD	A,(NEG_LEN)
	CP	NEG_BUF_SIZE
	JR	NC,.FULL			; no room - drop it
	LD	E,A
	LD	D,0
	LD	HL,NEG_BUF
	ADD	HL,DE
	LD	(HL),C
	INC	A
	LD	(NEG_LEN),A
.FULL
	POP	HL,DE,BC
	RET

; ------------------------------------------------------
; FLUSH_NEG: send queued negotiation replies (if any) and clear the buffer.
; ------------------------------------------------------
FLUSH_NEG
	LD	A,(NEG_LEN)
	AND	A
	RET	Z
	LD	C,A
	LD	B,0
	LD	HL,NEG_BUF
	CALL	NET_SEND
	XOR	A
	LD	(NEG_LEN),A
	RET

; Subnegotiation reply templates.
TTYPE_REPLY
	DB	TN_IAC,TN_SB,TNOPT_TTYPE,TTYPE_IS,"ANSI",TN_IAC,TN_SE
TTYPE_REPLY_LEN	EQU $-TTYPE_REPLY
; IAC SB NAWS <width16> <height16> IAC SE. Values stay below 255, so none need
; the IAC-doubling NAWS would otherwise require.
NAWS_REPLY
	DB	TN_IAC,TN_SB,TNOPT_NAWS
	DB	high TERM_COLS, low TERM_COLS
	DB	high TERM_ROWS, low TERM_ROWS
	DB	TN_IAC,TN_SE
NAWS_REPLY_LEN	EQU $-NAWS_REPLY

; Request an 8-bit-clean path in both directions. This is harmless for normal
; terminal traffic and mandatory for arbitrary Zmodem file bytes.
TN_BINARY_INIT
	DB	TN_IAC,TN_WILL,TNOPT_BINARY,TN_IAC,TN_DO,TNOPT_BINARY
TN_BINARY_INIT_LEN	EQU $-TN_BINARY_INIT

; ======================================================

OUTPUT_BYTE
	LD	A,(OUT_STATE)
	CP	O_ESC
	JR	Z,.IN_ESC
	CP	O_CSI
	JP	Z,.IN_CSI
	CP	O_OSC
	JR	Z,.IN_OSC
	CP	O_OSC_ESC
	JR	Z,.IN_OSC_ESC
; --- O_NORMAL ---
	LD	A,C
	CP	0x1B				; ESC -> start an escape sequence
	JR	Z,.TO_ESC
	JP	TERM_CHAR			; printable byte or C0 control
.TO_ESC
	LD	A,O_ESC
	LD	(OUT_STATE),A
	RET
; --- O_ESC: '[' starts CSI, ']' starts an OSC metadata string ---
.IN_ESC
	LD	A,C
	CP	'['
	JR	Z,.TO_CSI
	CP	']'
	JR	Z,.TO_OSC
	LD	A,O_NORMAL			; ESC <x>: drop the single byte
	LD	(OUT_STATE),A
	RET
.TO_CSI
	CALL	CSI_RESET
	LD	A,O_CSI
	LD	(OUT_STATE),A
	RET
; OSC carries window titles, hyperlinks and macOS OSC 7 current-directory
; metadata. It has no visual representation on DSS, so consume it through
; BEL or the two-byte ST terminator ESC '\\'.
.TO_OSC
	LD	A,O_OSC
	LD	(OUT_STATE),A
	RET
.IN_OSC
	LD	A,C
	CP	0x07				; BEL terminator
	JR	Z,.OSC_END
	CP	0x1B				; possible ST (ESC '\\')
	RET	NZ
	LD	A,O_OSC_ESC
	LD	(OUT_STATE),A
	RET
.IN_OSC_ESC
	LD	A,C
	CP	92				; '\\'
	JR	Z,.OSC_END
	CP	0x07
	JR	Z,.OSC_END
	CP	0x1B
	RET	Z				; repeated ESC: still waiting for '\\'
	LD	A,O_OSC			; not ST: continue consuming OSC
	LD	(OUT_STATE),A
	RET
.OSC_END
	LD	A,O_NORMAL
	LD	(OUT_STATE),A
	RET
; --- O_CSI: collect parameters, dispatch on the final byte ---
.IN_CSI
	LD	A,C
	CP	'?'
	JR	Z,.PRIV
	CP	'>'
	JR	Z,.PRIV
	CP	'='
	JR	Z,.PRIV
	CP	'<'
	JR	Z,.PRIV
	CP	'0'
	JR	C,.PUNCT
	CP	'9'+1
	JR	NC,.PUNCT
	JR	.DIGIT
.PUNCT
	CP	';'
	JR	Z,.SEP
	CP	0x40
	JR	C,.IGNORE_INT			; 0x20..0x3F intermediate -> ignore, stay
	CP	0x7F
	JR	NC,.CSI_END			; > 0x7E -> abort
	CALL	CSI_DISPATCH			; 0x40..0x7E final byte (C)
.CSI_END
	LD	A,O_NORMAL
	LD	(OUT_STATE),A
	RET
.PRIV
	LD	A,1
	LD	(CSI_PRIV),A
	RET
.IGNORE_INT
	RET
.SEP
	LD	A,1
	LD	(CSI_ANY),A
	LD	A,(CSI_IDX)
	CP	MAX_PARAMS-1
	RET	NC
	INC	A
	LD	(CSI_IDX),A
	RET
.DIGIT
	LD	A,1
	LD	(CSI_ANY),A
	LD	A,(CSI_IDX)
	LD	L,A
	LD	H,0
	LD	DE,CSI_PARAMS
	ADD	HL,DE				; HL -> params[idx]
	LD	A,C
	SUB	'0'
	LD	E,A				; E = new digit
	LD	A,(HL)				; D = old value, A *= 10
	LD	D,A
	ADD	A,A
	JR	C,.DCLAMP
	ADD	A,A
	JR	C,.DCLAMP
	ADD	A,D
	JR	C,.DCLAMP
	ADD	A,A
	JR	C,.DCLAMP
	ADD	A,E
	JR	C,.DCLAMP
	LD	(HL),A
	RET
.DCLAMP
	LD	(HL),255
	RET

; Reset the CSI parameter parser.
CSI_RESET
	XOR	A
	LD	(CSI_IDX),A
	LD	(CSI_PRIV),A
	LD	(CSI_ANY),A
	LD	HL,CSI_PARAMS
	LD	B,MAX_PARAMS
.Z	LD	(HL),0
	INC	HL
	DJNZ	.Z
	RET

; GET_PARAM: A = index -> A = CSI_PARAMS[index].
GET_PARAM
	LD	L,A
	LD	H,0
	LD	DE,CSI_PARAMS
	ADD	HL,DE
	LD	A,(HL)
	RET

; PARAM0_OR1: A = params[0], or 1 if it is 0 (default count).
PARAM0_OR1
	XOR	A
	CALL	GET_PARAM
	OR	A
	RET	NZ
	INC	A
	RET

; CSI_DISPATCH: act on final byte in C. Private (?,>,=,<) sequences are ignored.
CSI_DISPATCH
	LD	A,(CSI_PRIV)
	OR	A
	RET	NZ
	LD	A,C
	CP	'H'
	JP	Z,CUP
	CP	'f'
	JP	Z,CUP
	CP	'A'
	JP	Z,CUU
	CP	'B'
	JP	Z,CUD
	CP	'C'
	JP	Z,CUF
	CP	'D'
	JP	Z,CUB
	CP	'J'
	JP	Z,ED
	CP	'K'
	JP	Z,EL
	CP	'm'
	JP	Z,SGR
	CP	's'
	JP	Z,SCP
	CP	'u'
	JP	Z,RCP
	RET					; unhandled final byte

; --- Cursor movement ---
CUP						; ESC[r;cH / f
	XOR	A
	CALL	GET_PARAM			; row (1-based; 0 = default)
	OR	A
	JR	NZ,.R
	INC	A
.R	DEC	A
	LD	(CUR_ROW),A
	LD	A,1
	CALL	GET_PARAM			; col
	OR	A
	JR	NZ,.C
	INC	A
.C	DEC	A
	LD	(CUR_COL),A
	JP	CLAMP_CURSOR
CUU						; up
	CALL	PARAM0_OR1
	LD	B,A
	LD	A,(CUR_ROW)
	SUB	B
	JR	NC,.OK
	XOR	A
.OK	LD	(CUR_ROW),A
	RET
CUD						; down
	CALL	PARAM0_OR1
	LD	B,A
	LD	A,(CUR_ROW)
	ADD	A,B
	CP	TERM_ROWS
	JR	C,.OK
	LD	A,TERM_ROWS-1
.OK	LD	(CUR_ROW),A
	RET
CUF						; right
	CALL	PARAM0_OR1
	LD	B,A
	LD	A,(CUR_COL)
	ADD	A,B
	CP	TERM_COLS
	JR	C,.OK
	LD	A,TERM_COLS-1
.OK	LD	(CUR_COL),A
	RET
CUB						; left
	CALL	PARAM0_OR1
	LD	B,A
	LD	A,(CUR_COL)
	SUB	B
	JR	NC,.OK
	XOR	A
.OK	LD	(CUR_COL),A
	RET

CLAMP_CURSOR
	LD	A,(CUR_ROW)
	CP	TERM_ROWS
	JR	C,.ROW_OK
	LD	A,TERM_ROWS-1
	LD	(CUR_ROW),A
.ROW_OK
	LD	A,(CUR_COL)
	CP	TERM_COLS
	RET	C
	LD	A,TERM_COLS-1
	LD	(CUR_COL),A
	RET

SCP						; save cursor
	LD	A,(CUR_ROW)
	LD	(SAVED_ROW),A
	LD	A,(CUR_COL)
	LD	(SAVED_COL),A
	RET
RCP						; restore cursor
	LD	A,(SAVED_ROW)
	LD	(CUR_ROW),A
	LD	A,(SAVED_COL)
	LD	(CUR_COL),A
	RET

; --- Erase ---
ED						; ESC[nJ erase in display
	XOR	A
	CALL	GET_PARAM
	OR	A
	JR	Z,.FROM_CUR			; 0: cursor..end
	CP	1
	JR	Z,.TO_CUR			; 1: start..cursor
	CP	2
	RET	NZ
	; 2: clear whole terminal region and home (ANSI.SYS behaviour)
	LD	D,0
	LD	E,0
	LD	H,TERM_ROWS
	LD	L,TERM_COLS
	CALL	CLEAR_RECT
	XOR	A
	LD	(CUR_ROW),A
	LD	(CUR_COL),A
	RET
.FROM_CUR
	CALL	EL_FROM_CUR
	LD	A,(CUR_ROW)
	INC	A
	CP	TERM_ROWS
	RET	NC				; nothing below the cursor row
	LD	D,A
	LD	E,0
	LD	A,TERM_ROWS
	SUB	D
	LD	H,A
	LD	L,TERM_COLS
	JP	CLEAR_RECT
.TO_CUR
	LD	A,(CUR_ROW)
	OR	A
	JR	Z,.TC_LINE
	LD	D,0
	LD	E,0
	LD	H,A				; rows above
	LD	L,TERM_COLS
	CALL	CLEAR_RECT
.TC_LINE
	JP	EL_TO_CUR

EL						; ESC[nK erase in line
	XOR	A
	CALL	GET_PARAM
	OR	A
	JR	Z,EL_FROM_CUR
	CP	1
	JR	Z,EL_TO_CUR
	CP	2
	RET	NZ
	LD	A,(CUR_ROW)
	LD	D,A
	LD	E,0
	LD	H,1
	LD	L,TERM_COLS
	JP	CLEAR_RECT

EL_FROM_CUR					; current line: cursor..EOL
	LD	A,(CUR_ROW)
	LD	D,A
	LD	A,(CUR_COL)
	LD	E,A
	LD	H,1
	LD	A,TERM_COLS
	SUB	E
	LD	L,A
	JP	CLEAR_RECT
EL_TO_CUR					; current line: BOL..cursor
	LD	A,(CUR_ROW)
	LD	D,A
	LD	E,0
	LD	H,1
	LD	A,(CUR_COL)
	INC	A
	LD	L,A
	JP	CLEAR_RECT

; CLEAR_RECT: D=row E=col H=height L=width. Fills with spaces in CUR_ATTR.
CLEAR_RECT
	LD	A,H
	OR	A
	RET	Z
	LD	A,L
	OR	A
	RET	Z
	LD	A,(CUR_ATTR)
	LD	B,A
	LD	A,' '
	LD	C,DSS_CLEAR
	RST	DSS
	RET

; --- SGR colours ---
SGR
	LD	A,(CSI_ANY)
	OR	A
	JR	NZ,.HAVE
	XOR	A				; bare ESC[m == ESC[0m
	CALL	SGR_APPLY
	JP	RECALC_ATTR
.HAVE
	LD	B,0
.LOOP
	LD	A,B
	CALL	GET_PARAM
	CALL	SGR_APPLY
	LD	A,B
	LD	HL,CSI_IDX
	CP	(HL)
	JR	Z,.FIN
	INC	B
	JR	.LOOP
.FIN
	JP	RECALC_ATTR

; SGR_APPLY: fold one SGR code (A) into the FG/BG/BOLD/REV state.
SGR_APPLY
	OR	A
	JR	Z,.RESET
	CP	1
	JR	Z,.BOLD
	CP	2
	JR	Z,.NOBOLD
	CP	7
	JR	Z,.REV
	CP	22
	JR	Z,.NOBOLD
	CP	27
	JR	Z,.NOREV
	CP	39
	JR	Z,.DEFFG
	CP	49
	JR	Z,.DEFBG
	CP	30
	RET	C
	CP	38
	JR	C,.FG				; 30..37
	CP	40
	RET	C				; 38,39 handled/ignored
	CP	48
	JR	C,.BG				; 40..47
	CP	90
	RET	C
	CP	98
	JR	C,.FGBRT			; 90..97
	CP	100
	RET	C
	CP	108
	JR	C,.BGBRT			; 100..107
	RET
.RESET
	LD	A,7
	LD	(ATTR_FG),A
	XOR	A
	LD	(ATTR_BG),A
	LD	(ATTR_BOLD),A
	LD	(ATTR_REV),A
	RET
.BOLD
	LD	A,1
	LD	(ATTR_BOLD),A
	RET
.NOBOLD
	XOR	A
	LD	(ATTR_BOLD),A
	RET
.REV
	LD	A,1
	LD	(ATTR_REV),A
	RET
.NOREV
	XOR	A
	LD	(ATTR_REV),A
	RET
.DEFFG
	LD	A,7
	LD	(ATTR_FG),A
	RET
.DEFBG
	XOR	A
	LD	(ATTR_BG),A
	RET
.FG
	SUB	30
	CALL	ANSI2ZX
	LD	(ATTR_FG),A
	RET
.BG
	SUB	40
	CALL	ANSI2ZX
	LD	(ATTR_BG),A
	RET
.FGBRT
	SUB	90
	CALL	ANSI2ZX
	LD	(ATTR_FG),A
	LD	A,1
	LD	(ATTR_BOLD),A
	RET
.BGBRT
	SUB	100
	CALL	ANSI2ZX
	OR	8
	LD	(ATTR_BG),A
	RET

; ANSI2ZX: A = ANSI colour index 0..7 -> ZX palette index.
ANSI2ZX
	PUSH	HL
	LD	L,A
	LD	H,0
	LD	DE,ANSI2ZX_TAB
	ADD	HL,DE
	LD	A,(HL)
	POP	HL
	RET
ANSI2ZX_TAB
	DB	0,2,4,6,1,3,5,7			; blk,red,grn,yel,blu,mag,cyn,wht

; RECALC_ATTR: CUR_ATTR = (PAPER<<4)|INK from FG/BG/BOLD/REV.
RECALC_ATTR
	LD	A,(ATTR_FG)
	AND	0x07
	LD	B,A				; B = ink (fg)
	LD	A,(ATTR_BOLD)
	OR	A
	JR	Z,.NB
	LD	A,B
	OR	8
	LD	B,A				; bright ink
.NB
	LD	A,(ATTR_BG)
	AND	0x0F
	LD	C,A				; C = paper (bg)
	LD	A,(ATTR_REV)
	OR	A
	JR	Z,.NOREV2
	LD	A,B				; swap ink/paper
	LD	B,C
	LD	C,A
.NOREV2
	LD	A,C
	AND	0x0F
	RLCA
	RLCA
	RLCA
	RLCA					; paper -> high nibble
	LD	C,A
	LD	A,B
	AND	0x0F
	OR	C
	LD	(CUR_ATTR),A
	RET

; --- Character output ---
; TERM_CHAR: render a post-escape data byte (C). Printable bytes (incl. 0x80+
; box-drawing, which the CP866 font renders like CP437) are written at the
; cursor and advance it with auto-wrap; C0 controls move the cursor.
TERM_CHAR
	LD	A,C
	CP	0x20
	JR	C,.CTRL
	CALL	WRITE_GLYPH			; A = glyph
	LD	A,(CUR_COL)
	INC	A
	CP	TERM_COLS
	JR	C,.SETCOL
	XOR	A				; wrap to next line
	LD	(CUR_COL),A
	JP	TERM_LF
.SETCOL
	LD	(CUR_COL),A
	RET
.CTRL
	LD	A,C
	CP	CR
	JR	Z,.CR
	CP	LF
	JR	Z,TERM_LF
	CP	0x08
	JR	Z,.BS
	CP	0x09
	JR	Z,.TAB
	RET					; ignore BEL and other controls
.CR
	XOR	A
	LD	(CUR_COL),A
	RET
.BS
	LD	A,(CUR_COL)
	OR	A
	RET	Z
	DEC	A
	LD	(CUR_COL),A
	RET
.TAB
	LD	A,(CUR_COL)
	OR	7
	INC	A				; next multiple of 8
	CP	TERM_COLS
	JR	C,.TSET
	LD	A,TERM_COLS-1
.TSET
	LD	(CUR_COL),A
	RET

; TERM_LF: move the cursor down one line, scrolling the region if at the bottom.
TERM_LF
	LD	A,(CUR_ROW)
	INC	A
	CP	TERM_ROWS
	JR	C,.SET
	CALL	SCROLL_TERM
	LD	A,TERM_ROWS-1
.SET
	LD	(CUR_ROW),A
	RET

; WRITE_GLYPH: WrChar(A) at the cursor with CUR_ATTR (does not move the cursor).
WRITE_GLYPH
	PUSH	BC,DE,HL
	LD	C,A				; C = glyph
	LD	A,(CUR_ROW)
	LD	D,A
	LD	A,(CUR_COL)
	LD	E,A
	LD	A,(CUR_ATTR)
	LD	B,A
	LD	A,C
	LD	C,DSS_WRCHAR
	RST	DSS
	POP	HL,DE,BC
	RET

; SCROLL_TERM: scroll rows 0..TERM_ROWS-1 up by one and clear the new bottom
; row. Dss.Scroll -> BIOS.WIN_MOVE temporarily repages WIN1, so the stack must
; be in WIN2 for the call -- which it always is (see START).
SCROLL_TERM
	PUSH	BC,DE,HL
	LD	D,0
	LD	E,0
	LD	H,TERM_ROWS
	LD	L,TERM_COLS
	LD	B,1				; scroll up
	XOR	A
	CALL	SCROLL_DSS_SAFE
	LD	D,TERM_ROWS-1
	LD	E,0
	LD	H,1
	LD	L,TERM_COLS
	CALL	CLEAR_RECT
	POP	HL,DE,BC
	RET

; The program stack already lives in WIN2, so this call needs no stack switch.
; Loading SP with SCROLL_STACK_TOP here would reset it to the TOP of the very
; region the live frames occupy, and DSS/BIOS pushes would then overwrite the
; return addresses of the whole PROCESS_RX -> TERM_LF -> SCROLL_TERM chain.
SCROLL_DSS_SAFE
	LD	C,DSS_SCROLL
	RST	DSS
	RET

; SYNC_CURSOR: position the hardware text cursor at CUR_ROW/CUR_COL.
SYNC_CURSOR
	PUSH	BC,DE,HL
	LD	A,(CUR_ROW)
	LD	D,A
	LD	A,(CUR_COL)
	LD	E,A
	LD	C,DSS_LOCATE
	RST	DSS
	POP	HL,DE,BC
	RET

; INIT_SCREEN: reset attributes/cursor and clear the terminal region.
INIT_SCREEN
	XOR	A
	LD	(CUR_ROW),A
	LD	(CUR_COL),A
	LD	(ATTR_BOLD),A
	LD	(ATTR_REV),A
	LD	(ATTR_BG),A
	LD	A,7
	LD	(ATTR_FG),A
	CALL	RECALC_ATTR
	LD	D,0
	LD	E,0
	LD	H,TERM_ROWS
	LD	L,TERM_COLS
	JP	CLEAR_RECT

; DRAW_STATUS: paint the bottom status row (host:port + key hints).
; DRAW_STATUS: paint the static parts of the status row (idle label, host:port)
; then the first dynamic snapshot. Dynamic fields (spinner/clock/state/idle) are
; refreshed by STATUS_TICK / REDRAW_DYNAMIC.
DRAW_STATUS
	LD	D,STATUS_ROW
	LD	E,0
	LD	H,1
	LD	L,TERM_COLS
	LD	A,' '
	LD	B,STATUS_ATTR
	LD	C,DSS_CLEAR
	RST	DSS
	LD	D,STATUS_ROW
	LD	E,SC_IDLELBL
	LD	HL,LBL_IDLE
	CALL	PUTS_STATUS
	LD	D,STATUS_ROW
	LD	E,SC_HOST
	LD	HL,HOST_BUFF
	CALL	PUTS_STATUS
	LD	A,':'
	CALL	PUTC_STATUS
	LD	HL,PORT_BUFF
	CALL	PUTS_STATUS
	JP	REDRAW_DYNAMIC

; ------------------------------------------------------
; STATUS_TICK: called once per main-loop pass. Every 8 passes it advances the
; spinner (proves the program is alive, independent of the RTC) and samples the
; clock; on a new second it bumps the idle counter and repaints the dynamic
; status fields. Self-throttling, so it is cheap to call every iteration.
; ------------------------------------------------------
STATUS_TICK
	PUSH	BC,DE,HL,IX
	LD	A,(SPIN_TICK)
	INC	A
	LD	(SPIN_TICK),A
	AND	7
	JR	NZ,.done
	CALL	ADVANCE_SPINNER
	LD	C,DSS_SYSTIME			; H=hour, L=min, B=sec
	RST	DSS
	LD	A,H
	LD	(T_HOUR),A
	LD	A,L
	LD	(T_MIN),A
	LD	A,B
	LD	(T_SEC),A			; A = seconds
	LD	HL,LAST_SEC
	CP	(HL)
	JR	Z,.done				; same second -> nothing to repaint
	LD	(HL),A
	LD	A,(IDLE_SECS)			; count idle seconds (cap 255)
	CP	255
	JR	NC,.redraw
	INC	A
	LD	(IDLE_SECS),A
.redraw
	CALL	REDRAW_DYNAMIC
.done
	POP	IX,HL,DE,BC
	RET

; ADVANCE_SPINNER: rotate the spinner glyph at SC_SPIN.
ADVANCE_SPINNER
	LD	A,(SPIN_IDX)
	INC	A
	AND	3
	LD	(SPIN_IDX),A
	LD	E,A
	LD	D,0
	LD	HL,SPIN_CHARS
	ADD	HL,DE
	LD	A,(HL)
	LD	D,STATUS_ROW
	LD	E,SC_SPIN
	JP	PUTC_STATUS

; REDRAW_DYNAMIC: repaint clock (HH:MM:SS), state word and idle count.
REDRAW_DYNAMIC
	LD	D,STATUS_ROW
	LD	E,SC_CLOCK
	LD	A,(T_HOUR)
	CALL	STAT_PUT2
	LD	A,':'
	CALL	PUTC_STATUS
	LD	A,(T_MIN)
	CALL	STAT_PUT2
	LD	A,':'
	CALL	PUTC_STATUS
	LD	A,(T_SEC)
	CALL	STAT_PUT2
	LD	D,STATUS_ROW
	LD	E,SC_STATE
	CALL	STATE_PTR
	CALL	PUTS_STATUS
	LD	D,STATUS_ROW
	LD	E,SC_IDLENUM
	LD	A,(IDLE_SECS)
	CALL	STAT_PUT3
	LD	A,'s'
	JP	PUTC_STATUS

; STATE_PTR: HL -> the current link-state string.
STATE_PTR
	LD	A,(LINK_DOWN)
	OR	A
	JR	NZ,.closed
	LD	A,(IDLE_SECS)
	CP	5
	JR	NC,.idle
	LD	HL,ST_ONLINE
	RET
.idle
	LD	HL,ST_IDLE
	RET
.closed
	LD	HL,ST_CLOSED
	RET

; STAT_PUT2: A = 0..99 -> two decimal digits at (D,E); E advances by 2.
STAT_PUT2
	LD	B,'0'-1
.t
	INC	B
	SUB	10
	JR	NC,.t
	ADD	A,10				; A = units value, B = tens digit char
	PUSH	AF
	LD	A,B
	CALL	PUTC_STATUS
	POP	AF
	ADD	A,'0'
	JP	PUTC_STATUS

; STAT_PUT3: A = 0..255 -> three decimal digits at (D,E); E advances by 3.
STAT_PUT3
	LD	B,'0'-1
.h
	INC	B
	SUB	100
	JR	NC,.h
	ADD	A,100				; A = remainder 0..99, B = hundreds digit char
	PUSH	AF
	LD	A,B
	CALL	PUTC_STATUS
	POP	AF
	JP	STAT_PUT2

; NOTE_TX_RESULT: CF from a TCP send. A clean send clears the failure run; two
; consecutive failures (CIPSEND to a dead socket) mark the link down.
NOTE_TX_RESULT
	JR	C,.fail
	XOR	A
	LD	(SEND_FAILS),A
	RET
.fail
	LD	A,(SEND_FAILS)
	INC	A
	LD	(SEND_FAILS),A
	CP	2
	RET	C
	LD	A,1
	LD	(LINK_DOWN),A
	LD	(CLOSE_ERROR),A
	RET

; PUTS_STATUS: write ASCIIZ at HL onto the status row. In: D=row, E=col; E advances.
PUTS_STATUS
	LD	A,(HL)
	OR	A
	RET	Z
	CALL	PUTC_STATUS
	INC	HL
	JR	PUTS_STATUS
; PUTC_STATUS: write char A at (D,E) in STATUS_ATTR, then E++ (clipped at edge).
PUTC_STATUS
	PUSH	BC,HL
	LD	C,A				; C = char
	LD	A,E
	CP	TERM_COLS
	JR	NC,.DONE			; past the right edge: skip the write
	LD	A,C
	LD	B,STATUS_ATTR
	PUSH	DE
	LD	C,DSS_WRCHAR
	RST	DSS
	POP	DE
.DONE
	INC	E
	POP	HL,BC
	RET


; Native TCP transport. Calls enter and leave with the ISA window closed.
NET_SEND
	LD	(SEND_PTR),HL
	LD	(SEND_LEFT),BC
.LOOP
	LD	HL,(SEND_LEFT)
	LD	A,H
	OR	L
	JR	Z,.OK
	LD	BC,536
	LD	A,H
	CP	2
	JR	C,.SHORT
	JR	NZ,.LEN_READY
	LD	A,L
	CP	24
	JR	NC,.LEN_READY
.SHORT
	LD	B,H
	LD	C,L
.LEN_READY
	LD	(SEND_CHUNK),BC
	LD	HL,(SEND_PTR)
	CALL	@ISA.ISA_OPEN
	CALL	@TCP.SEND
	PUSH	AF
	CALL	@ISA.ISA_CLOSE
	POP	AF
	JR	C,.FAIL
	LD	BC,(SEND_CHUNK)
	LD	HL,(SEND_PTR)
	ADD	HL,BC
	LD	(SEND_PTR),HL
	LD	HL,(SEND_LEFT)
	OR	A
	SBC	HL,BC
	LD	(SEND_LEFT),HL
	JR	.LOOP
.OK
	OR	A
	RET
.FAIL
	SCF
	RET

NET_RECV
	CALL	@ISA.ISA_OPEN
	CALL	@TCP.RECV
	PUSH	AF
	PUSH	BC
	PUSH	HL
	CALL	@ISA.ISA_CLOSE
	POP	HL
	POP	BC
	POP	AF
	RET

; RX_DRAIN is the non-blocking stream reader expected by the transferred
; Z/Ymodem engines. RX_DRAIN_WAIT uses DE as its timeout. Both copy at most
; the caller's BC capacity and preserve an oversized TCP payload as pending
; bytes for the next call.
RX_DRAIN
	XOR	A
	LD	(STREAM_WAIT),A
	LD	DE,1
	JR	STREAM_READ

RX_DRAIN_WAIT
	LD	A,1
	LD	(STREAM_WAIT),A

STREAM_READ
	LD	(STREAM_DEST),HL
	LD	(STREAM_MAX),BC
	LD	(STREAM_TIMEOUT),DE
	LD	HL,(STREAM_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.COPY
	LD	A,(STREAM_CLOSED)
	OR	A
	JR	NZ,.CLOSED
	LD	HL,(STREAM_TIMEOUT)
	LD	(@TCP.RECV_TIMEOUT),HL
	CALL	NET_RECV
	JR	NC,.NEW_DATA
	LD	A,(TCP_STATE)
	CP	3
	JR	NZ,.RECV_FAIL
	LD	A,1
	LD	(STREAM_CLOSED),A
	LD	BC,(TCP_RX_DATA_LEN)
	LD	A,B
	OR	C
	JR	Z,.CLOSED
	LD	HL,(TCP_RX_DATA_PTR)
	JR	.STAGE
.RECV_FAIL
	LD	A,(TCP_LAST_FAIL)
	CP	2
	JR	NZ,.CLOSED_MARK
	LD	A,(STREAM_WAIT)
	OR	A
	JR	NZ,.CLOSED
	LD	BC,0
	OR	A
	RET
.CLOSED_MARK
	LD	A,1
	LD	(STREAM_CLOSED),A
.CLOSED
	LD	BC,0
	SCF
	RET
.NEW_DATA
.STAGE
	LD	(STREAM_PTR),HL
	LD	(STREAM_LEFT),BC
.COPY
	LD	HL,(STREAM_LEFT)
	LD	BC,(STREAM_MAX)
	OR	A
	SBC	HL,BC
	JR	NC,.COUNT_READY
	ADD	HL,BC
	LD	B,H
	LD	C,L
.COUNT_READY
	LD	(STREAM_COUNT),BC
	LD	HL,(STREAM_PTR)
	LD	DE,(STREAM_DEST)
	LDIR
	LD	BC,(STREAM_COUNT)
	LD	HL,(STREAM_PTR)
	ADD	HL,BC
	LD	(STREAM_PTR),HL
	LD	HL,(STREAM_LEFT)
	OR	A
	SBC	HL,BC
	LD	(STREAM_LEFT),HL
	OR	A
	RET

NET_CLOSE
	CALL	@ISA.ISA_OPEN
	CALL	@TCP.CLOSE
	PUSH	AF
	CALL	@ISA.ISA_CLOSE
	POP	AF
	RET

; TCP/resolve callback. During setup Esc/Ctrl+C cancels; once online,
; keyboard ownership belongs to HANDLE_KEY and this routine only yields.
TICK_AND_CHECK_KEY
	CALL	@ISA.ISA_CLOSE
	CALL	@UTIL.DELAY_1MS
	LD	A,(SESSION_ACTIVE)
	OR	A
	JR	NZ,.RESUME
	LD	C,DSS_SCANKEY
	RST	DSS
	JR	Z,.RESUME
	LD	A,E
	CP	0x1B
	JR	Z,.CANCEL
	LD	A,B
	AND	KB_CTRL | KB_L_CTRL | KB_R_CTRL
	JR	Z,.RESUME
	LD	A,D
	CP	0xAC
	JR	NZ,.RESUME
.CANCEL
	LD	A,1
	LD	(CANCELLED),A
	CALL	@ISA.ISA_OPEN
	SCF
	RET
.RESUME
	CALL	@ISA.ISA_OPEN
	OR	A
	RET

; DSS GETVMOD returns A = mode and B = the visible screen page (0/1); SETVMOD
; consumes both. Keeping the page is not optional: SETVMOD ends with
; "LD A,B / AND 1 / OUT (SCREEN_SWITCH),A", so calling it with a stale B flips
; the displayed screen and the caller redraws into an invisible page.
INIT_VMODE
	LD	C,DSS_GETVMOD
	RST	DSS
	LD	(SAVE_VMODE),A
	LD	A,B
	LD	(SAVE_VPAGE),A
	LD	A,(SAVE_VMODE)
	CP	DSS_VMOD_T80
	JR	Z,.DONE
	LD	A,DSS_VMOD_T80
	LD	C,DSS_SETVMOD		; B still holds the current screen page
	RST	DSS
.DONE
	RET

REST_VMODE
	; Exit must hand DSS a normal system mapping with interrupts enabled.
	; ISA_CLOSE deliberately preserves the interrupt state when its software
	; flag already says "closed"; after nested terminal/transfer callbacks that
	; is not strong enough for process teardown, and the following FM process
	; can otherwise start with IRQs still disabled.
	CALL	@ISA.ISA_CLOSE
	EI
	LD	A,(SAVE_VMODE)
	CP	DSS_VMOD_T80
	RET	Z			; never changed -> nothing to put back
	LD	A,(SAVE_VPAGE)
	LD	B,A			; B = screen page saved by INIT_VMODE
	LD	A,(SAVE_VMODE)
	LD	C,DSS_SETVMOD
	RST	DSS
	RET

; Reserve and map one 16 KB DSS page into WIN2. Code stays in WIN1; START
; moves the working stack to the top of WIN2, above BSS and transfer buffers.
INIT_RUNTIME_PAGE
	LD	B,1
	LD	C,DSS_GETMEM
	RST	DSS
	RET	C
	LD	B,0
	LD	C,DSS_SETWIN2
	RST	DSS
	RET

INIT_MEMORY_ERROR
	LD	B,3
	LD	C,DSS_EXIT
	RST	DSS

PARSE_ARGS
	CALL	@CMDL.PARSE
	CALL	@CMDL.IS_HELP
	JR	NC,.BAD
	LD	B,0
	CALL	@CMDL.GET_POSITIONAL
	JR	C,.BAD
	LD	DE,HOST_BUFF
	LD	B,HOST_SIZE
	CALL	COPY_LIMITED
	JR	C,.BAD
	XOR	A
	LD	(INLINE_PORT),A
	CALL	SPLIT_INLINE_PORT
	JR	C,.BAD
	LD	B,1
	CALL	@CMDL.GET_POSITIONAL
	JR	C,.DEFAULT_OR_INLINE
	LD	A,(INLINE_PORT)
	OR	A
	JR	NZ,.BAD
	LD	DE,PORT_BUFF
	LD	B,PORT_SIZE
	CALL	COPY_LIMITED
	JR	C,.BAD
	JR	.CHECK_EXTRA
.DEFAULT_OR_INLINE
	LD	A,(INLINE_PORT)
	OR	A
	JR	NZ,.CHECK_EXTRA
	LD	HL,DEFAULT_PORT
	LD	DE,PORT_BUFF
	CALL	COPY_STRING
.CHECK_EXTRA
	LD	B,2
	CALL	@CMDL.GET_POSITIONAL
	JR	NC,.BAD
	LD	HL,PORT_BUFF
	CALL	@CMDL.PARSE_U16
	JR	C,.BAD
	LD	A,H
	OR	L
	JR	Z,.BAD
	LD	(PORT_VALUE),HL
	OR	A
	RET
.BAD
	SCF
	RET

SPLIT_INLINE_PORT
	LD	HL,HOST_BUFF
.SCAN
	LD	A,(HL)
	OR	A
	RET	Z
	CP	':'
	JR	Z,.FOUND
	INC	HL
	JR	.SCAN
.FOUND
	LD	(HL),0
	INC	HL
	LD	A,(HL)
	OR	A
	JR	Z,.BAD
	LD	DE,PORT_BUFF
	LD	B,PORT_SIZE
	CALL	COPY_LIMITED
	RET	C
	LD	A,1
	LD	(INLINE_PORT),A
	OR	A
	RET
.BAD
	SCF
	RET

; HL ASCIIZ -> DE, capacity B including NUL.
COPY_LIMITED
	LD	A,B
	OR	A
	JR	Z,.BAD
.LOOP
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	OR	A
	RET	Z
	DJNZ	.LOOP
.BAD
	SCF
	RET

COPY_STRING
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	OR	A
	JR	NZ,COPY_STRING
	RET

MSG_START	DB "RTL8019AS TELNET v",PACKAGE_VERSION,0
N_NET_IP	DB "NET_IP",0
N_NET_MAC	DB "NET_MAC",0
MSG_USAGE
	DB "Usage: TELNET host[:port] | host [port]",13,10
	DB "Default port 23. Alt+X quit; Zmodem auto;",13,10
	DB "Ymodem Alt+D/Alt+U; Ymodem-G Alt+G.",0
MSG_CONNECTING	DB "Connecting to ",0
MSG_COLON	DB ":",0
MSG_RESOLVE_ERROR DB "[E] could not resolve host.",0
MSG_NET_ERROR	DB "[E] RTL/network operation failed.",0
MSG_TCP_ERROR	DB "[E] TCP connect failed, code 0x",0
MSG_CLOSED	DB "Remote host closed the connection.",0
MSG_DONE	DB "TELNET done.",0
LBL_IDLE	DB "idle:",0
ST_ONLINE	DB "ONLINE",0
ST_IDLE		DB "IDLE  ",0
ST_CLOSED	DB "CLOSED",0
SPIN_CHARS	DB '|','/','-',92
DEFAULT_PORT	DB "23",0
LINE_END	DB 13,10,0

	ENDMODULE

	INCLUDE "netenv_lib.asm"
	INCLUDE "cmdline_lib.asm"
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"
	INCLUDE "arp_lib.asm"
	INCLUDE "resolve_lib.asm"
	INCLUDE "dns_lib.asm"
	INCLUDE "tcp_lib.asm"

; Compatibility shims used by the transport-neutral Z/Ymodem engines.
DSS_KCLEAR	EQU DSS_K_CLEAR
REG_FCR		EQU 0

	MODULE WCOMMON
CANCELLED	EQU @MAIN.CANCELLED
	ENDMODULE

	MODULE WIFI
UART_RX_PAUSE
UART_RX_RESUME
UART_WRITE
	XOR	A
	RET
UART_TX_BUFFER
	JP	@MAIN.NET_SEND
	ENDMODULE

	INCLUDE "zmodem.asm"
	INCLUDE "ymodem.asm"

TELNET_IMAGE_END

RX_BUF_SIZE	EQU 1518

	MODULE MAIN

TX_BUF		EQU APP_BSS_BASE
RX_HDR		EQU TX_BUF + TCP_MAX_FRAME
RX_BUF		EQU RX_HDR + 4
OUR_IP		EQU RX_BUF + RX_BUF_SIZE
OUR_MAC		EQU OUR_IP + 4
TARGET_IP	EQU OUR_MAC + 6
HOST_BUFF	EQU TARGET_IP + 4
PORT_BUFF	EQU HOST_BUFF + HOST_SIZE
PORT_VALUE	EQU PORT_BUFF + PORT_SIZE
CANCELLED	EQU PORT_VALUE + 2
SESSION_ACTIVE	EQU CANCELLED + 1
SAVE_VMODE	EQU SESSION_ACTIVE + 1
SAVE_VPAGE	EQU SAVE_VMODE + 1
INLINE_PORT	EQU SAVE_VPAGE + 1
SEND_PTR	EQU INLINE_PORT + 1
SEND_LEFT	EQU SEND_PTR + 2
SEND_CHUNK	EQU SEND_LEFT + 2
TX_KEY_BUF	EQU SEND_CHUNK + 2

TN_STATE	EQU TX_KEY_BUF + 2
TN_CMD		EQU TN_STATE + 1
SB_IDX		EQU TN_CMD + 1
SB_OPT		EQU SB_IDX + 1
SB_SUB		EQU SB_OPT + 1
OUT_STATE	EQU SB_SUB + 1
TX_BINARY	EQU OUT_STATE + 1
TN_PEER_SEEN	EQU TX_BINARY + 1
TN_BINARY_SENT	EQU TN_PEER_SEEN + 1
NEG_LEN		EQU TN_BINARY_SENT + 1
NEG_BUF		EQU NEG_LEN + 1
CUR_ROW		EQU NEG_BUF + NEG_BUF_SIZE
CUR_COL		EQU CUR_ROW + 1
CUR_ATTR	EQU CUR_COL + 1
SAVED_ROW	EQU CUR_ATTR + 1
SAVED_COL	EQU SAVED_ROW + 1
ATTR_FG		EQU SAVED_COL + 1
ATTR_BG		EQU ATTR_FG + 1
ATTR_BOLD	EQU ATTR_BG + 1
ATTR_REV	EQU ATTR_BOLD + 1
CSI_IDX		EQU ATTR_REV + 1
CSI_PRIV	EQU CSI_IDX + 1
CSI_ANY		EQU CSI_PRIV + 1
CSI_PARAMS	EQU CSI_ANY + 1
T_HOUR		EQU CSI_PARAMS + MAX_PARAMS
T_MIN		EQU T_HOUR + 1
T_SEC		EQU T_MIN + 1
LAST_SEC	EQU T_SEC + 1
IDLE_SECS	EQU LAST_SEC + 1
SPIN_TICK	EQU IDLE_SECS + 1
SPIN_IDX	EQU SPIN_TICK + 1
LINK_DOWN	EQU SPIN_IDX + 1
SEND_FAILS	EQU LINK_DOWN + 1
CLOSE_ERROR	EQU SEND_FAILS + 1
ZTRIG		EQU CLOSE_ERROR + 1
ZM_BYTE		EQU ZTRIG + 1
YM_C_PENDING	EQU ZM_BYTE + 1
STREAM_PTR	EQU YM_C_PENDING + 1
STREAM_LEFT	EQU STREAM_PTR + 2
STREAM_CLOSED	EQU STREAM_LEFT + 2
STREAM_DEST	EQU STREAM_CLOSED + 1
STREAM_MAX	EQU STREAM_DEST + 2
STREAM_TIMEOUT	EQU STREAM_MAX + 2
STREAM_COUNT	EQU STREAM_TIMEOUT + 2
STREAM_WAIT	EQU STREAM_COUNT + 2
TELNET_BSS_END	EQU STREAM_WAIT + 1
ZM_STATE_BASE	EQU TELNET_BSS_END
YM_STATE_BASE	EQU ZM_STATE_BASE + 160
TRANSFER_BSS_END EQU YM_STATE_BASE + 64

	ASSERT TELNET_IMAGE_END < STACK_TOP - 0x0100
	ASSERT TRANSFER_BSS_END < SCROLL_STACK_TOP - 0x0100
	ASSERT SCROLL_STACK_TOP - TRANSFER_BSS_END >= 0x0400

	ENDMODULE

	END MAIN.START
