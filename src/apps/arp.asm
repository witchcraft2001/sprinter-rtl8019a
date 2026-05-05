; ======================================================
; ARP.EXE - additional utility (on the path to stage 6 PING).
; Sends one ARP "who-has" request for a hardcoded target IP
; (192.168.7.1) and waits for a matching ARP reply, printing
; the resolved MAC.
;
; Hardcodes: OUR_IP = 192.168.7.2, OUR_MAC = 02:80:19:11:22:33,
; TARGET_IP = 192.168.7.1. NET.CFG-driven configuration and
; command-line target are coming with the PING stage.
;
; Host setup (single-machine via feth pair):
;   sudo ifconfig feth0 create
;   sudo ifconfig feth1 create
;   sudo ifconfig feth0 peer feth1
;   sudo ifconfig feth0 up
;   sudo ifconfig feth1 inet 192.168.7.1/24 up
; Then bind MAME to feth0 (Tab -> Network Devices) and run ARP.
; macOS kernel will reply to ARP for 192.168.7.1.
;
; Stage codes:
;   [A0] INIT           reset + chip config (RCR=0x04, broadcast accept)
;   [A1] PROBE          print our IP/MAC and target IP
;   [A2] BUILD          frame composed in TX_BUF
;   [A3] SEND           DMA write + TX, wait PTX
;   [A4] WAIT REPLY     poll PRX, drop non-ARP / non-matching
;   [A5] REPLY MAC=...  print resolved target MAC
; ======================================================

EXE_VERSION		EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "memmap.inc"
	INCLUDE "rtl8019.inc"

	DEFINE USE_RTL_INIT_NORMAL
	DEFINE USE_RTL_SEND_FRAME
	DEFINE USE_RTL_WAIT_PTX
	DEFINE USE_RTL_RING_HAS_PACKET
	DEFINE USE_RTL_READ_PACKET
	DEFINE USE_ARP_BUILD_REQUEST
	DEFINE USE_NETENV
	DEFINE USE_CMDL
	DEFINE CMDLINE_AT_LARGE			; ORG 0x4100 -> cmd line at IX-0x80 = 0x4180

ARP_TIMEOUT_MS	EQU 3000		; ARP reply budget (ms)
SCAN_C		EQU 0xAC		; DSS scancode for the C key

ETH_TYPE_ARP	EQU 0x0806

ARP_OP_REQUEST	EQU 1
ARP_OP_REPLY	EQU 2

FRAME_LEN	EQU 60			; min Ethernet frame (no FCS)
ARP_BODY_LEN	EQU 28

	MODULE MAIN

	; Large EXE header (256 bytes, 0x4100..0x41FF).
	ORG 0x4100

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0100			; hdr_size = 256
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START
	DW START
	DW 0xBFFF			; stack at top of directly-addressable RAM
	DS 234, 0

	ORG 0x4200

START
	PRINTLN MSG_BANNER

	; Init CANCELLED (BSS; not zeroed by loader).
	XOR	A
	LD	(CANCELLED),A

	; Tokenize and check help.
	CALL	@CMDL.PARSE
	CALL	@CMDL.IS_HELP
	JP	NC,SHOW_HELP

	; Mandatory positional: target IPv4.
	LD	B,0
	CALL	@CMDL.GET_POSITIONAL
	JP	C,USAGE_ERROR
	LD	DE,TARGET_IP
	CALL	@CMDL.PARSE_IPV4
	JP	C,USAGE_ERROR

	; Pull NET_IP / NET_MAC from env (populated by NETCFG -i).
	LD	HL,N_NET_IP
	LD	DE,OUR_IP
	CALL	@NETENV.REQUIRE_IP
	LD	HL,N_NET_MAC
	LD	DE,OUR_MAC
	CALL	@NETENV.REQUIRE_MAC

	; Init NIC.
	LD	A,1
	LD	(@ISA.ISA_SLOT),A
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.RESET
	JP	C,RESET_FAIL
	LD	HL,OUR_MAC
	LD	A,RCR_AB
	CALL	@RTL.INIT_NORMAL
	LD	HL,OUR_MAC
	LD	(@ARP.OUR_MAC_PTR),HL
	LD	HL,OUR_IP
	LD	(@ARP.OUR_IP_PTR),HL

	; "ARPING X from Y (MAC)"
	PRINT LINE_END
	PRINT MSG_ARPING
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINT MSG_FROM_IP
	LD	HL,OUR_IP
	CALL	PRINT_IPV4
	PRINT MSG_OPEN_PAREN
	LD	HL,OUR_MAC
	CALL	@UTIL.PRINT_MAC
	PRINTLN MSG_CLOSE_PAREN

	; Build and send ARP request.
	LD	DE,TX_BUF
	LD	HL,TARGET_IP
	CALL	@ARP.BUILD_REQUEST
	LD	HL,TX_BUF
	LD	BC,FRAME_LEN
	CALL	@RTL.SEND_FRAME
	JP	C,WRITE_FAIL

	; Wait for reply (ms timeout, key-cancellable).
	LD	HL,ARP_TIMEOUT_MS
	LD	(TIMEOUT_MS_LEFT),HL
	CALL	WAIT_FOR_ARP_REPLY
	JP	C,REPLY_TIMEOUT

	; "Reply from X.X.X.X: aa:bb:..."
	PRINT MSG_REPLY_FROM
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINT MSG_COLON
	LD	HL,REPLY_MAC
	CALL	@UTIL.PRINT_MAC
	PRINT LINE_END
	CALL	@ISA.ISA_CLOSE
	JP	@UTIL.EXIT_OK


RESET_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_RESET
	JP	FAIL_NIC

WRITE_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_WRITE
	JP	FAIL_NIC

REPLY_TIMEOUT
	LD	A,(CANCELLED)
	OR	A
	JR	NZ,.CANCEL
	PRINTLN MSG_E_REPLY
	JP	FAIL_NIC
.CANCEL
	PRINTLN MSG_ABORTED
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL

FAIL_NIC
	CALL	@RTL.SNAPSHOT_REGS
	CALL	PRINT_REG_DUMP
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL


SHOW_HELP
	LD	HL,MSG_HELP
	LD	C,DSS_PCHARS
	RST	DSS
	JP	@UTIL.EXIT_OK


USAGE_ERROR
	PRINTLN MSG_USAGE_ERR
	LD	HL,MSG_HELP
	LD	C,DSS_PCHARS
	RST	DSS
	LD	B,1
	JP	@UTIL.EXIT_FAIL


; ------------------------------------------------------
; TICK_AND_CHECK_KEY: ~1 ms wait + non-blocking key poll.
; Esc and Ctrl+C cancel the wait.  SCANKEY may switch
; memory pages, so we close the ISA window around the call.
;   Out: CF=0 normal; CF=1 cancelled (CANCELLED set).
; ------------------------------------------------------
TICK_AND_CHECK_KEY
	CALL	@UTIL.DELAY_1MS
	CALL	@ISA.ISA_CLOSE
	LD	C,DSS_SCANKEY
	RST	DSS
	JR	Z,.NO_KEY
	LD	A,E
	CP	0x1B			; Esc
	JR	Z,.CANCEL
	LD	A,B
	AND	KB_CTRL | KB_L_CTRL | KB_R_CTRL
	JR	Z,.NO_KEY
	LD	A,D
	CP	SCAN_C			; Ctrl+C
	JR	Z,.CANCEL
	JR	.NO_KEY
.CANCEL
	LD	A,1
	LD	(CANCELLED),A
	CALL	@ISA.ISA_OPEN
	SCF
	RET
.NO_KEY
	CALL	@ISA.ISA_OPEN
	OR	A
	RET


; ------------------------------------------------------
; BUILD_ARP_REQUEST: assemble 60-byte broadcast ARP "who-has"
; in TX_BUF.
;   ETH header  : DST=ff*6, SRC=OUR_MAC, TYPE=0x0806
;   ARP body    : HW=Eth/IPv4, op=request, sender=us, target_mac=0,
;                 target_ip=TARGET_IP
;   pad to 60   : zero bytes
; ------------------------------------------------------
; ------------------------------------------------------
; WAIT_FOR_ARP_REPLY: spin on RTL.RING_HAS_PACKET +
; RTL.READ_PACKET, drop anything that isn't a matching ARP
; reply, populate REPLY_MAC on match.
;   Out: CF=0 OK, CF=1 timeout.
; ------------------------------------------------------
WAIT_FOR_ARP_REPLY
.LP
	CALL	@RTL.RING_HAS_PACKET
	JR	NZ,.HAVE
	CALL	TICK_AND_CHECK_KEY	; ~1 ms + Esc/Ctrl+C poll
	JR	C,.TIMEOUT		; cancelled
	LD	HL,(TIMEOUT_MS_LEFT)
	DEC	HL
	LD	(TIMEOUT_MS_LEFT),HL
	LD	A,H
	OR	L
	JR	NZ,.LP
	JR	.TIMEOUT
.HAVE
	LD	HL,RX_HDR
	LD	DE,RX_BUF
	LD	BC,RX_BUF_SIZE
	CALL	@RTL.READ_PACKET
	JR	C,.LP			; DMA error, drop and continue
	; Filter: ARP reply for TARGET_IP.
	LD	A,(RX_BUF + 12)
	CP	HIGH ETH_TYPE_ARP
	JR	NZ,.LP
	LD	A,(RX_BUF + 13)
	CP	LOW ETH_TYPE_ARP
	JR	NZ,.LP
	LD	A,(RX_BUF + 14 + 6)
	OR	A
	JR	NZ,.LP
	LD	A,(RX_BUF + 14 + 7)
	CP	ARP_OP_REPLY
	JR	NZ,.LP
	LD	HL,RX_BUF + 14 + 14
	LD	DE,TARGET_IP
	LD	B,4
.CMPIP
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.LP
	INC	HL
	INC	DE
	DJNZ	.CMPIP
	; Match: copy sender MAC.
	LD	HL,RX_BUF + 14 + 8
	LD	DE,REPLY_MAC
	LD	BC,6
	LDIR
	OR	A
	RET
.TIMEOUT
	SCF
	RET


; ------------------------------------------------------
; PRINT_IPV4: HL points at 4 bytes; print as "a.b.c.d".
; ------------------------------------------------------
PRINT_IPV4
	PUSH	HL,BC
	LD	B,4
.LP
	LD	A,(HL)
	CALL	PRINT_DEC_A
	INC	HL
	DEC	B
	JR	Z,.DONE
	PUSH	BC
	LD	A,'.'
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC
	JR	.LP
.DONE
	POP	BC,HL
	RET

; ------------------------------------------------------
; PRINT_DEC_A: print A as decimal 0..255 (no leading zeros).
; ------------------------------------------------------
PRINT_DEC_A
	PUSH	AF,BC,DE,HL
	LD	C,A			; C = remaining dividend
	LD	HL,DEC_BUF + 3
	LD	(HL),0			; null terminator
.LP
	; A = C mod 10, B = C div 10
	LD	A,C
	LD	B,0
.SUB
	CP	10
	JR	C,.GOT
	SUB	10
	INC	B
	JR	.SUB
.GOT
	ADD	A,'0'
	DEC	HL
	LD	(HL),A
	LD	C,B
	LD	A,B
	OR	A
	JR	NZ,.LP
	LD	C,DSS_PCHARS
	RST	DSS
	POP	HL,DE,BC,AF
	RET

DEC_BUF		EQU APP_BSS_BASE + 16		; 4 bytes scratch for PRINT_DEC_A


; ------------------------------------------------------
PUTCHAR
	PUSH	AF,BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC,AF
	RET

PRINT_REG_DUMP
	PRINT MSG_REGS
	LD	HL,REG_NAMES
	LD	DE,@RTL.REG_SNAPSHOT
	LD	B,@RTL.REG_SNAPSHOT_LEN
.LP
	PUSH	BC,DE
.NCHR
	LD	A,(HL)
	INC	HL
	OR	A
	JR	Z,.NDONE
	CALL	PUTCHAR
	JR	.NCHR
.NDONE
	LD	A,'='
	CALL	PUTCHAR
	POP	DE,BC
	LD	A,(DE)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,' '
	CALL	PUTCHAR
	INC	DE
	DJNZ	.LP
	PRINT LINE_END
	RET

REG_NAMES
	DB "CR",0
	DB "ISR",0
	DB "DCR",0
	DB "RCR",0
	DB "TCR",0
	DB "IMR",0
	DB "PSTART",0
	DB "PSTOP",0
	DB "BNRY",0
	DB "CURR",0


; ------- in-EXE data -------
N_NET_IP	DB "NET_IP",0
N_NET_MAC	DB "NET_MAC",0

; ------- runtime BSS (lives at APP_BSS_BASE, NOT in .EXE) --
OUR_IP		EQU APP_BSS_BASE		; 4 bytes, filled by REQUIRE_IP
OUR_MAC		EQU APP_BSS_BASE + 4		; 6 bytes, filled by REQUIRE_MAC
TARGET_IP	EQU APP_BSS_BASE + 10		; 4 bytes, filled from positional arg
REPLY_MAC	EQU APP_BSS_BASE + 14		; 6 bytes, filled by ARP reply parser
TIMEOUT_MS_LEFT	EQU APP_BSS_BASE + 20		; 2 bytes
CANCELLED	EQU APP_BSS_BASE + 22		; 1 byte


; ------- messages -------
MSG_BANNER	DB "RTL8019AS ARP v0.2",0
MSG_ARPING	DB "ARPING ",0
MSG_FROM_IP	DB " from ",0
MSG_OPEN_PAREN	DB " (",0
MSG_CLOSE_PAREN	DB ")",0
MSG_REPLY_FROM	DB "Reply from ",0
MSG_COLON	DB ": ",0
MSG_REGS	DB "REGS ",0
MSG_ABORTED	DB "Aborted by user (Esc/Ctrl+C).",0
MSG_E_RESET	DB "[E50] RESET timeout",0
MSG_E_WRITE	DB "[E51] DMA write or PTX timeout",0
MSG_E_REPLY	DB "ARP request timed out.",0
MSG_USAGE_ERR	DB "[E] usage: missing or invalid target IPv4",0
MSG_HELP
	DB "Usage:",13,10
	DB "  ARP target",13,10
	DB "  ARP /?",13,10,13,10
	DB "  target  destination IPv4 (e.g. 192.168.7.1).",13,10,0
LINE_END	DB 13,10,0

	ENDMODULE


	; netenv_lib / cmdline_lib transitively DEFINE USE_UTIL_*
	; helpers they need, so they must be included BEFORE util.asm.
	INCLUDE "netenv_lib.asm"
	INCLUDE "cmdline_lib.asm"
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"
	INCLUDE "arp_lib.asm"


ARP_IMAGE_END

RX_BUF_SIZE	EQU 1518

	MODULE MAIN

TX_BUF		EQU ARP_IMAGE_END
RX_HDR		EQU TX_BUF + FRAME_LEN
RX_BUF		EQU RX_HDR + 4
ARP_BSS_END	EQU RX_BUF + RX_BUF_SIZE

	ENDMODULE

	END MAIN.START
