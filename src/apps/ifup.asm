; ======================================================
; IFUP.EXE - bring the network interface up.
;
; Phase A scope: send a single DHCPDISCOVER, wait for an
; OFFER from any DHCP server in the broadcast domain, print
; what was offered, exit OK.  Does NOT yet send REQUEST or
; apply the offer to env vars.
;
; Usage:
;   IFUP            run DHCP DISCOVER/OFFER probe
;   IFUP /?         help
;
; Exit codes: 0 OK, 1 usage, 2 no NIC, 3 DHCP timeout/cancel,
;             4 config (NET_MAC missing).
; ======================================================

EXE_VERSION	EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "memmap.inc"
	INCLUDE "rtl8019.inc"

	DEFINE USE_UTIL_EXIT_NO_NIC
	DEFINE USE_RTL_INIT_NORMAL
	DEFINE USE_RTL_SEND_FRAME
	DEFINE USE_RTL_WAIT_PTX
	DEFINE USE_RTL_RING_HAS_PACKET
	DEFINE USE_RTL_READ_PACKET
	DEFINE USE_NETENV
	DEFINE USE_CMDL
	DEFINE USE_DHCP
	DEFINE CMDLINE_AT_LARGE

DHCP_TIMEOUT_MS	EQU 10000		; total OFFER wait budget
SCAN_C		EQU 0xAC

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
	DW 0xBFFF
	DS 234, 0

	ORG 0x4200

START
	PRINTLN MSG_BANNER

	XOR	A
	LD	(CANCELLED),A
	LD	(MODE_DHCP),A

	CALL	@CMDL.PARSE
	CALL	@CMDL.IS_HELP
	JP	NC,SHOW_HELP

	; -- Phase 1: read all env vars BEFORE opening ISA.  DSS
	; functions that touch the state page (ENVIRON, file I/O,
	; SCANKEY) re-map MMU3 and trash the ISA window if open.

	LD	HL,N_NET_MAC
	LD	DE,OUR_MAC
	CALL	@NETENV.REQUIRE_MAC

	LD	HL,N_NET_IP_SRC
	LD	DE,SRC_BUF
	LD	B,16
	CALL	@NETENV.GET_STR
	JR	C,.SET_STATIC
	CALL	IS_DHCP
	JR	NZ,.SET_STATIC
	; DHCP mode: don't read NET_IP (it's empty until ACK).
	LD	A,1
	LD	(MODE_DHCP),A
	JR	.PHASE2
.SET_STATIC
	LD	HL,N_NET_IP
	LD	DE,STATIC_IP
	CALL	@NETENV.REQUIRE_IP

.PHASE2
	; -- Phase 2: open ISA, init NIC.
	LD	A,1
	LD	(@ISA.ISA_SLOT),A
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.PROBE_PRESENT
	JP	C,@UTIL.EXIT_NO_NIC
	CALL	@RTL.RESET
	JP	C,RESET_FAIL
	LD	HL,OUR_MAC
	LD	A,RCR_AB
	CALL	@RTL.INIT_NORMAL

	LD	A,(MODE_DHCP)
	OR	A
	JR	NZ,.DHCP_FLOW

	; -- STATIC: just announce.
	CALL	@ISA.ISA_CLOSE
	PRINT LINE_END
	PRINT MSG_STATIC_PRE
	LD	HL,STATIC_IP
	CALL	PRINT_IPV4
	PRINTLN MSG_STATIC_POST
	JP	@UTIL.EXIT_OK

.DHCP_FLOW
	PRINT LINE_END
	PRINTLN MSG_DISCOVER

	; -- DISCOVER --
	LD	DE,TX_BUF
	LD	HL,OUR_MAC
	CALL	@DHCP.BUILD_DISCOVER	; BC = total length
	LD	(SEND_LEN),BC
	LD	HL,TX_BUF
	LD	BC,(SEND_LEN)
	CALL	@RTL.SEND_FRAME
	JP	C,SEND_FAIL

	LD	HL,DHCP_TIMEOUT_MS
	LD	(TIMEOUT_MS_LEFT),HL
	LD	A,2				; DHCPOFFER
	LD	(EXPECT_TYPE),A
	CALL	WAIT_FOR_DHCP
	JP	C,DHCP_TIMEOUT

	PRINT MSG_OFFER_PRE
	LD	HL,@DHCP.OFFERED_IP
	CALL	PRINT_IPV4
	PRINT MSG_OFFER_FROM
	LD	HL,@DHCP.SERVER_ID
	CALL	PRINT_IPV4
	PRINTLN MSG_CLOSE_PAREN

	; -- REQUEST --
	LD	DE,TX_BUF
	LD	HL,OUR_MAC
	CALL	@DHCP.BUILD_REQUEST
	LD	(SEND_LEN),BC
	LD	HL,TX_BUF
	LD	BC,(SEND_LEN)
	CALL	@RTL.SEND_FRAME
	JP	C,SEND_FAIL

	LD	HL,DHCP_TIMEOUT_MS
	LD	(TIMEOUT_MS_LEFT),HL
	LD	A,5				; DHCPACK
	LD	(EXPECT_TYPE),A
	CALL	WAIT_FOR_DHCP
	JP	C,DHCP_TIMEOUT

	; -- Phase 3: ACK in hand.  Close ISA so subsequent DSS
	; SETENV calls don't fight over MMU3.

	CALL	@ISA.ISA_CLOSE

	LD	HL,N_NET_IP
	LD	IX,@DHCP.OFFERED_IP
	CALL	SETENV_IPV4
	LD	HL,N_NET_MASK
	LD	IX,@DHCP.MASK
	CALL	SETENV_IPV4
	LD	HL,N_NET_GW
	LD	IX,@DHCP.ROUTER
	CALL	SETENV_IPV4
	LD	HL,N_NET_DNS1
	LD	IX,@DHCP.DNS1
	CALL	SETENV_IPV4
	LD	HL,N_NET_DNS2
	LD	IX,@DHCP.DNS2
	CALL	SETENV_IPV4
	LD	HL,N_NET_DHCP_SRV
	LD	IX,@DHCP.SERVER_ID
	CALL	SETENV_IPV4
	LD	HL,N_NET_LEASE_SEC
	LD	IX,@DHCP.LEASE_SECS
	CALL	SETENV_DEC32_BE

	PRINT MSG_ACK_PRE
	LD	HL,@DHCP.OFFERED_IP
	CALL	PRINT_IPV4
	PRINT MSG_ACK_FROM
	LD	HL,@DHCP.SERVER_ID
	CALL	PRINT_IPV4
	PRINT MSG_ACK_LEASE
	LD	HL,(@DHCP.LEASE_SECS + 2)
	LD	A,L
	LD	L,H
	LD	H,A
	CALL	PRINT_DEC_HL
	PRINTLN MSG_ACK_LEASE_S

	JP	@UTIL.EXIT_OK


RESET_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_RESET
	JP	FAIL

SEND_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_SEND
	JP	FAIL

DHCP_TIMEOUT
	LD	A,(CANCELLED)
	OR	A
	JR	NZ,.CANCEL
	PRINTLN MSG_E_DHCP
	JP	FAIL
.CANCEL
	PRINTLN MSG_ABORTED
	CALL	@ISA.ISA_CLOSE
	LD	B,EX_NET_ERR
	JP	@UTIL.EXIT_FAIL

FAIL
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


; ------------------------------------------------------
; WAIT_FOR_DHCP: poll the RX ring; succeed when a DHCP reply
; with MSG_TYPE == EXPECT_TYPE arrives.  Other DHCP replies
; (NAK, etc.) and non-DHCP frames are dropped silently.
;   TIMEOUT_MS_LEFT must be set; EXPECT_TYPE in BSS.
;   Out: CF=0 OK; CF=1 timeout / cancel.
; ------------------------------------------------------
WAIT_FOR_DHCP
.LP
	CALL	@RTL.RING_HAS_PACKET
	JP	NZ,.HAVE
	CALL	TICK_AND_CHECK_KEY
	JP	C,.TIMEOUT
	LD	HL,(TIMEOUT_MS_LEFT)
	DEC	HL
	LD	(TIMEOUT_MS_LEFT),HL
	LD	A,H
	OR	L
	JP	NZ,.LP
	JP	.TIMEOUT
.HAVE
	LD	HL,RX_HDR
	LD	DE,RX_BUF
	LD	BC,RX_BUF_SIZE
	CALL	@RTL.READ_PACKET
	JR	C,.LP
	LD	HL,RX_BUF
	LD	DE,0
	CALL	@DHCP.PARSE_REPLY
	JP	C,.LP
	LD	A,(@DHCP.MSG_TYPE)
	LD	HL,EXPECT_TYPE
	CP	(HL)
	JP	NZ,.LP
	OR	A
	RET
.TIMEOUT
	SCF
	RET


; ------------------------------------------------------
; IS_DHCP: ZF=1 if SRC_BUF starts with "DHCP" / "dhcp".
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
IS_DHCP
	LD	HL,SRC_BUF
	LD	A,(HL)
	OR	0x20
	CP	'd'
	JR	NZ,.NO
	INC	HL
	LD	A,(HL)
	OR	0x20
	CP	'h'
	JR	NZ,.NO
	INC	HL
	LD	A,(HL)
	OR	0x20
	CP	'c'
	JR	NZ,.NO
	INC	HL
	LD	A,(HL)
	OR	0x20
	CP	'p'
	JR	NZ,.NO
	XOR	A
	RET
.NO
	OR	1
	RET


; ------------------------------------------------------
; SETENV_* helpers: build "NAME=VALUE" in SET_BUF and call
; DSS ENVIRON / SET.  Same shape as the routines in NETCFG.EXE,
; duplicated here to keep IFUP self-contained for now.
; ------------------------------------------------------

; In: HL=name, IX=4 byte IP source.
SETENV_IPV4
	LD	DE,SET_BUF
	CALL	COPY_ASCIIZ
	DEC	DE
	LD	A,'='
	LD	(DE),A
	INC	DE
	LD	B,4
.LP
	LD	A,(IX+0)
	PUSH	BC
	CALL	FMT_BYTE_DEC
	POP	BC
	INC	IX
	DEC	B
	JR	Z,.END
	LD	A,'.'
	LD	(DE),A
	INC	DE
	JR	.LP
.END
	XOR	A
	LD	(DE),A
	JP	DO_SETENV

; In: HL=name, IX=4 byte BE 32-bit value.
SETENV_DEC32_BE
	LD	DE,SET_BUF
	CALL	COPY_ASCIIZ
	DEC	DE
	LD	A,'='
	LD	(DE),A
	INC	DE
	; Convert IX[0..3] BE to a HL u16 by taking only low 16 bits
	; (lease > 65535s is rare for our use; truncation is acceptable
	; until we wire a real u32 printer).
	LD	A,(IX+2)
	LD	H,A
	LD	A,(IX+3)
	LD	L,A
	; Format HL as decimal into SET_BUF.
	CALL	FMT_DEC_HL
	XOR	A
	LD	(DE),A
	JP	DO_SETENV

; FMT_DEC_HL: write HL as ASCII decimal at (DE), advancing DE.
; Trashes A, BC, HL.
FMT_DEC_HL
	LD	A,H
	OR	L
	JR	NZ,.NZ
	LD	A,'0'
	LD	(DE),A
	INC	DE
	RET
.NZ
	LD	B,0
.LP
	LD	A,H
	OR	L
	JR	Z,.PRT
	PUSH	BC
	CALL	DIV_HL_10
	POP	BC
	ADD	A,'0'
	PUSH	AF
	INC	B
	JR	.LP
.PRT
	LD	A,B
	OR	A
	RET	Z
.OUTL
	POP	AF
	LD	(DE),A
	INC	DE
	DJNZ	.OUTL
	RET


DO_SETENV
	LD	HL,SET_BUF
	LD	B,ENV_SET
	LD	C,DSS_ENVIRON
	RST	DSS
	RET

; FMT_BYTE_DEC: A as decimal at (DE).  Trashes A, BC, H.
FMT_BYTE_DEC
	LD	C,A
	LD	H,0
	LD	B,0
.H_LP
	LD	A,C
	CP	100
	JR	C,.H_END
	SUB	100
	LD	C,A
	INC	B
	JR	.H_LP
.H_END
	LD	A,B
	OR	A
	JR	Z,.NO_H
	ADD	A,'0'
	LD	(DE),A
	INC	DE
	INC	H
.NO_H
	LD	B,0
.T_LP
	LD	A,C
	CP	10
	JR	C,.T_END
	SUB	10
	LD	C,A
	INC	B
	JR	.T_LP
.T_END
	LD	A,B
	OR	A
	JR	NZ,.WR_T
	LD	A,H
	OR	A
	JR	Z,.NO_T
	XOR	A
.WR_T
	ADD	A,'0'
	LD	(DE),A
	INC	DE
.NO_T
	LD	A,C
	ADD	A,'0'
	LD	(DE),A
	INC	DE
	RET

COPY_ASCIIZ
.L
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	OR	A
	JR	NZ,.L
	RET


; ------------------------------------------------------
; TICK_AND_CHECK_KEY: ~1 ms wait + Esc/Ctrl+C poll.
; ------------------------------------------------------
TICK_AND_CHECK_KEY
	CALL	@UTIL.DELAY_1MS
	CALL	@ISA.ISA_CLOSE
	LD	C,DSS_SCANKEY
	RST	DSS
	JR	Z,.NO_KEY
	LD	A,E
	CP	0x1B
	JR	Z,.CANCEL
	LD	A,B
	AND	KB_CTRL | KB_L_CTRL | KB_R_CTRL
	JR	Z,.NO_KEY
	LD	A,D
	CP	SCAN_C
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
; PRINT_IPV4: HL = ptr to 4 bytes; print "a.b.c.d".
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

; PRINT_DEC_A: A as 0..255 decimal.
PRINT_DEC_A
	PUSH	AF,BC,DE,HL
	LD	C,A
	LD	HL,DEC_BUF + 3
	LD	(HL),0
.LP
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

PUTCHAR
	PUSH	AF,BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC,AF
	RET

; PRINT_DEC_HL: HL as decimal, no leading zeros.
PRINT_DEC_HL
	PUSH	HL
	LD	A,H
	OR	L
	JR	NZ,.NZ
	LD	A,'0'
	CALL	PUTCHAR
	POP	HL
	RET
.NZ
	LD	B,0
.LP
	LD	A,H
	OR	L
	JR	Z,.PRT
	PUSH	BC
	CALL	DIV_HL_10
	POP	BC
	ADD	A,'0'
	PUSH	AF
	INC	B
	JR	.LP
.PRT
	LD	A,B
	OR	A
	JR	Z,.DONE
.OUTL
	POP	AF
	CALL	PUTCHAR
	DJNZ	.OUTL
.DONE
	POP	HL
	RET

DIV_HL_10
	LD	BC,0
	LD	DE,16
.LP
	ADD	HL,HL
	RL	C
	LD	A,C
	CP	10
	JR	C,.NS
	SUB	10
	LD	C,A
	INC	L
.NS
	DEC	E
	JR	NZ,.LP
	LD	A,C
	RET


; ------------------------------------------------------
; PRINT_REG_DUMP: same pattern as PING/ARP/UDPTEST.
; ------------------------------------------------------
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
N_NET_IP_SRC	DB "NET_IP_SRC",0
N_NET_IP	DB "NET_IP",0
N_NET_MASK	DB "NET_MASK",0
N_NET_GW	DB "NET_GW",0
N_NET_MAC	DB "NET_MAC",0
N_NET_DNS1	DB "NET_DNS1",0
N_NET_DNS2	DB "NET_DNS2",0
N_NET_DHCP_SRV	DB "NET_DHCP_SRV",0
N_NET_LEASE_SEC	DB "NET_LEASE_SEC",0

; ------- runtime BSS ------
OUR_MAC		EQU APP_BSS_BASE		; 6 bytes
TIMEOUT_MS_LEFT	EQU APP_BSS_BASE + 6		; 2 bytes
SEND_LEN	EQU APP_BSS_BASE + 8		; 2 bytes
CANCELLED	EQU APP_BSS_BASE + 10		; 1 byte
EXPECT_TYPE	EQU APP_BSS_BASE + 11		; 1 byte
MODE_DHCP	EQU APP_BSS_BASE + 12		; 1 byte (1=DHCP, 0=STATIC)
STATIC_IP	EQU APP_BSS_BASE + 13		; 4 bytes (NET_IP for static mode)
DEC_BUF		EQU APP_BSS_BASE + 17		; 4 bytes
SRC_BUF		EQU APP_BSS_BASE + 21		; 16 bytes (NET_IP_SRC reader)
SET_BUF		EQU APP_BSS_BASE + 40		; 64 bytes (NAME=VALUE for SETENV)


; ------- messages -------
MSG_BANNER	DB "RTL8019AS IFUP v0.2",0
MSG_STATIC_PRE	DB "Interface up: IP=",0
MSG_STATIC_POST	DB " (static).",0
MSG_DISCOVER	DB "DHCP: sending DISCOVER...",0
MSG_OFFER_PRE	DB "DHCP: got OFFER ",0
MSG_OFFER_FROM	DB " (server ",0
MSG_CLOSE_PAREN	DB ")",0
MSG_ACK_PRE	DB "DHCP: lease IP=",0
MSG_ACK_FROM	DB " (server ",0
MSG_ACK_LEASE	DB ", lease ",0
MSG_ACK_LEASE_S	DB " s)",0
MSG_REGS	DB "REGS ",0
MSG_ABORTED	DB "Aborted by user (Esc/Ctrl+C).",0
MSG_E_RESET	DB "[E90] RESET timeout",0
MSG_E_SEND	DB "[E91] DMA write or PTX timeout",0
MSG_E_DHCP	DB "DHCP timed out (no OFFER/ACK from any server).",0
MSG_HELP
	DB "Usage:",13,10
	DB "  IFUP        bring interface up per NET_IP_SRC",13,10
	DB "              (DHCP runs DISCOVER/REQUEST cycle;",13,10
	DB "               STATIC just announces NET_IP).",13,10
	DB "  IFUP /?     this help",13,10,13,10
	DB "Run NETCFG -i first to populate NET_IP_SRC and friends.",13,10,0
LINE_END	DB 13,10,0

	ENDMODULE


	; netenv_lib / cmdline_lib / dhcp transitively DEFINE
	; USE_UTIL_* helpers; include BEFORE util.asm.
	INCLUDE "netenv_lib.asm"
	INCLUDE "cmdline_lib.asm"
	INCLUDE "dhcp.asm"
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"


IFUP_IMAGE_END

RX_BUF_SIZE	EQU 1518

	MODULE MAIN

TX_BUF		EQU IFUP_IMAGE_END
RX_HDR		EQU TX_BUF + 320		; DHCP frame ~292 bytes
RX_BUF		EQU RX_HDR + 4
IFUP_BSS_END	EQU RX_BUF + RX_BUF_SIZE

	ENDMODULE

	END MAIN.START
