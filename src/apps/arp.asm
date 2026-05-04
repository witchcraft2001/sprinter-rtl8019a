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
	INCLUDE "rtl8019.inc"

	DEFINE USE_RTL_INIT_NORMAL
	DEFINE USE_RTL_SEND_FRAME
	DEFINE USE_RTL_WAIT_PTX
	DEFINE USE_RTL_RING_HAS_PACKET
	DEFINE USE_RTL_READ_PACKET
	DEFINE USE_ARP_BUILD_REQUEST
	DEFINE USE_NETCFG_LOAD

PRX_OUTER	EQU 32			; ~15s budget for ARP reply

ETH_TYPE_ARP	EQU 0x0806

ARP_OP_REQUEST	EQU 1
ARP_OP_REPLY	EQU 2

FRAME_LEN	EQU 60			; min Ethernet frame (no FCS)
ARP_BODY_LEN	EQU 28

	MODULE MAIN

	ORG 0x8080

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0080
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START
	DW START
	DW STACK_TOP
	DS 106, 0

	ORG 0x8100
@STACK_TOP

START
	PRINTLN MSG_BANNER

	; Read NET.CFG (defaults applied if file missing).
	CALL	@NETCFG.LOAD

	LD	A,1
	LD	(@ISA.ISA_SLOT),A
	CALL	@ISA.ISA_OPEN

	; [A0] INIT
	PRINT MSG_A0
	CALL	@RTL.RESET
	JP	C,RESET_FAIL
	LD	HL,@NETCFG.OUR_MAC
	LD	A,RCR_AB
	CALL	@RTL.INIT_NORMAL
	; Configure ARP module pointers (once).
	LD	HL,@NETCFG.OUR_MAC
	LD	(@ARP.OUR_MAC_PTR),HL
	LD	HL,@NETCFG.OUR_IP
	LD	(@ARP.OUR_IP_PTR),HL
	PRINTLN MSG_OK

	; [A1] info banner
	PRINT MSG_FROM_IP
	LD	HL,@NETCFG.OUR_IP
	CALL	PRINT_IPV4
	PRINT MSG_OUR_MAC
	LD	HL,@NETCFG.OUR_MAC
	CALL	@UTIL.PRINT_MAC
	PRINT LINE_END
	PRINT MSG_TO_IP
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINT LINE_END

	; [A2] BUILD via @ARP.BUILD_REQUEST.
	LD	DE,TX_BUF
	LD	HL,TARGET_IP
	CALL	@ARP.BUILD_REQUEST
	PRINTLN MSG_A2

	; [A3] SEND (DMA + TBCR + CR.TXP + wait PTX)
	PRINT MSG_A3
	LD	HL,TX_BUF
	LD	BC,FRAME_LEN
	CALL	@RTL.SEND_FRAME
	JP	C,WRITE_FAIL
	PRINTLN MSG_OK

	; [A4] WAIT REPLY
	PRINTLN MSG_A4
	CALL	WAIT_FOR_ARP_REPLY
	JP	C,REPLY_TIMEOUT

	; [A5] REPLY
	PRINT MSG_A5
	LD	HL,REPLY_MAC
	CALL	@UTIL.PRINT_MAC
	PRINT LINE_END

	PRINTLN MSG_RESULT_OK
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_OK


RESET_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_RESET
	JP	FAIL_NIC

WRITE_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_WRITE
	JP	FAIL_NIC

REPLY_TIMEOUT
	PRINTLN MSG_E_REPLY
	JP	FAIL_NIC

FAIL_NIC
	CALL	@RTL.SNAPSHOT_REGS
	CALL	PRINT_REG_DUMP
	PRINTLN MSG_RESULT_FAIL
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_NIC_ERR


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
	LD	HL,PRX_OUTER
	LD	(OUTER_LEFT),HL
.MAIN
	CALL	@RTL.RING_HAS_PACKET
	JR	NZ,.HAVE
	LD	BC,0
.WAIT
	CALL	@RTL.RING_HAS_PACKET
	JR	NZ,.HAVE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.WAIT
	LD	HL,(OUTER_LEFT)
	DEC	HL
	LD	(OUTER_LEFT),HL
	LD	A,H
	OR	L
	JR	Z,.TIMEOUT
	JR	.MAIN
.HAVE
	LD	HL,RX_HDR
	LD	DE,RX_BUF
	LD	BC,RX_BUF_SIZE
	CALL	@RTL.READ_PACKET
	JR	C,.MAIN			; DMA error, drop and continue
	; Filter: ARP reply for TARGET_IP.
	LD	A,(RX_BUF + 12)
	CP	HIGH ETH_TYPE_ARP
	JR	NZ,.MAIN
	LD	A,(RX_BUF + 13)
	CP	LOW ETH_TYPE_ARP
	JR	NZ,.MAIN
	LD	A,(RX_BUF + 14 + 6)
	OR	A
	JR	NZ,.MAIN
	LD	A,(RX_BUF + 14 + 7)
	CP	ARP_OP_REPLY
	JR	NZ,.MAIN
	LD	HL,RX_BUF + 14 + 14
	LD	DE,TARGET_IP
	LD	B,4
.CMPIP
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.MAIN
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

OUTER_LEFT	DW 0


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

DEC_BUF		DS 4,0


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
; OUR_MAC / OUR_IP now live in @NETCFG.* (loaded by NETCFG.LOAD).
TARGET_IP	DB 192, 168, 7, 1
REPLY_MAC	DB 0,0,0,0,0,0


; ------- messages -------
MSG_BANNER	DB "RTL8019AS ARP v0.1",0
MSG_A0		DB "[A0] INIT ",0
MSG_OK		DB "OK",0
MSG_FROM_IP	DB "     from ",0
MSG_OUR_MAC	DB " (",0
MSG_TO_IP	DB "     who-has ",0
MSG_A2		DB "[A2] BUILD OK",0
MSG_A3		DB "[A3] SEND ",0
MSG_A4		DB "[A4] WAIT REPLY",0
MSG_A5		DB "[A5] REPLY MAC=",0
MSG_REGS	DB "REGS ",0
MSG_RESULT_OK	DB "RESULT OK",0
MSG_RESULT_FAIL	DB "RESULT FAIL",0
MSG_E_RESET	DB "[E50] RESET timeout",0
MSG_E_WRITE	DB "[E51] DMA write or PTX timeout",0
MSG_E_REPLY	DB "[E53] ARP reply timeout (no matching reply within budget)",0
LINE_END	DB 13,10,0

	ENDMODULE


	; netcfg_lib transitively DEFINEs USE_UTIL_* helpers it needs,
	; so it must be included BEFORE util.asm.
	INCLUDE "netcfg_lib.asm"
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
