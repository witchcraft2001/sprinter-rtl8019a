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

PTX_LOOPS	EQU 16000
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

	LD	A,1
	LD	(@ISA.ISA_SLOT),A
	CALL	@ISA.ISA_OPEN

	; [A0] INIT
	PRINT MSG_A0
	CALL	@RTL.RESET
	JP	C,RESET_FAIL
	CALL	CONFIG_NORMAL
	PRINTLN MSG_OK

	; [A1] info banner
	PRINT MSG_FROM_IP
	LD	HL,OUR_IP
	CALL	PRINT_IPV4
	PRINT MSG_OUR_MAC
	LD	HL,OUR_MAC
	CALL	@UTIL.PRINT_MAC
	PRINT LINE_END
	PRINT MSG_TO_IP
	LD	HL,TARGET_IP
	CALL	PRINT_IPV4
	PRINT LINE_END

	; [A2] BUILD
	CALL	BUILD_ARP_REQUEST
	PRINTLN MSG_A2

	; [A3] SEND
	PRINT MSG_A3
	LD	HL,TX_BUF
	LD	BC,FRAME_LEN
	LD	DE,0x4000
	CALL	@RTL.DMA_WRITE
	JP	C,WRITE_FAIL
	LD	A,LOW FRAME_LEN
	LD	(RTL_TBCR0_A),A
	LD	A,HIGH FRAME_LEN
	LD	(RTL_TBCR1_A),A
	LD	A,CR_PAGE0_START | CR_TXP
	LD	(RTL_CR_A),A
	CALL	WAIT_PTX
	JP	C,PTX_FAIL
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

PTX_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_PTX
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
; CONFIG_NORMAL: standard chip init for protocol traffic.
; RCR=0x04 (broadcast accept) so we can hear the broadcast
; ARP request the kernel might emit, plus our own gratuitous
; replies. The reply we care about is unicast to our PAR and
; passes via physical match independently of RCR.AB.
; ------------------------------------------------------
CONFIG_NORMAL
	LD	A,CR_PAGE0_STOP
	LD	(RTL_CR_A),A
	LD	A,DCR_INIT
	LD	(RTL_DCR_A),A
	XOR	A
	LD	(RTL_RBCR0_A),A
	LD	(RTL_RBCR1_A),A
	LD	A,RCR_AB
	LD	(RTL_RCR_A),A
	LD	A,TCR_NORMAL
	LD	(RTL_TCR_A),A
	LD	A,RTL_TPSR_INIT
	LD	(RTL_TPSR_A),A
	LD	A,RTL_PSTART_INIT
	LD	(RTL_PSTART_A),A
	LD	A,RTL_PSTOP_INIT
	LD	(RTL_PSTOP_A),A
	LD	A,RTL_BNRY_INIT
	LD	(RTL_BNRY_A),A
	LD	A,0xFF
	LD	(RTL_ISR_A),A
	XOR	A
	LD	(RTL_IMR_A),A

	LD	A,CR_PAGE1_STOP
	LD	(RTL_CR_A),A
	LD	A,(OUR_MAC + 0)
	LD	(RTL_PAR0_A),A
	LD	A,(OUR_MAC + 1)
	LD	(RTL_PAR1_A),A
	LD	A,(OUR_MAC + 2)
	LD	(RTL_PAR2_A),A
	LD	A,(OUR_MAC + 3)
	LD	(RTL_PAR3_A),A
	LD	A,(OUR_MAC + 4)
	LD	(RTL_PAR4_A),A
	LD	A,(OUR_MAC + 5)
	LD	(RTL_PAR5_A),A
	LD	A,RTL_CURR_INIT
	LD	(RTL_CURR_A),A
	XOR	A
	LD	(RTL_MAR0_A + 0),A
	LD	(RTL_MAR0_A + 1),A
	LD	(RTL_MAR0_A + 2),A
	LD	(RTL_MAR0_A + 3),A
	LD	(RTL_MAR0_A + 4),A
	LD	(RTL_MAR0_A + 5),A
	LD	(RTL_MAR0_A + 6),A
	LD	(RTL_MAR0_A + 7),A

	LD	A,CR_PAGE0_START
	LD	(RTL_CR_A),A
	RET


; ------------------------------------------------------
; BUILD_ARP_REQUEST: assemble 60-byte broadcast ARP "who-has"
; in TX_BUF.
;   ETH header  : DST=ff*6, SRC=OUR_MAC, TYPE=0x0806
;   ARP body    : HW=Eth/IPv4, op=request, sender=us, target_mac=0,
;                 target_ip=TARGET_IP
;   pad to 60   : zero bytes
; ------------------------------------------------------
BUILD_ARP_REQUEST
	LD	DE,TX_BUF
	; DST = FF*6
	LD	A,0xFF
	LD	B,6
.DST
	LD	(DE),A
	INC	DE
	DJNZ	.DST
	; SRC = OUR_MAC
	LD	HL,OUR_MAC
	LD	BC,6
	LDIR
	; EtherType = 0x0806
	LD	A,HIGH ETH_TYPE_ARP
	LD	(DE),A
	INC	DE
	LD	A,LOW ETH_TYPE_ARP
	LD	(DE),A
	INC	DE

	; -- ARP body --
	; HW type = 0x0001 (Ethernet)
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	INC	DE
	; Proto type = 0x0800 (IPv4)
	LD	A,0x08
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	; HW size = 6
	LD	A,6
	LD	(DE),A
	INC	DE
	; Proto size = 4
	LD	A,4
	LD	(DE),A
	INC	DE
	; Op = 0x0001 (request)
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,ARP_OP_REQUEST
	LD	(DE),A
	INC	DE
	; Sender MAC
	LD	HL,OUR_MAC
	LD	BC,6
	LDIR
	; Sender IP
	LD	HL,OUR_IP
	LD	BC,4
	LDIR
	; Target MAC = 0*6
	XOR	A
	LD	B,6
.TGT_MAC
	LD	(DE),A
	INC	DE
	DJNZ	.TGT_MAC
	; Target IP
	LD	HL,TARGET_IP
	LD	BC,4
	LDIR

	; Pad to 60 bytes (current = 14 + 28 = 42; need 18 zero bytes)
	XOR	A
	LD	B,FRAME_LEN - 14 - ARP_BODY_LEN
.PAD
	LD	(DE),A
	INC	DE
	DJNZ	.PAD
	RET


; ------------------------------------------------------
; WAIT_PTX: poll ISR.PTX with PTX_LOOPS budget. Out: CF=0/1.
; ------------------------------------------------------
WAIT_PTX
	LD	BC,PTX_LOOPS
.LP
	LD	A,(RTL_ISR_A)
	AND	ISR_PTX
	JR	NZ,.OK
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.LP
	SCF
	RET
.OK
	LD	A,ISR_PTX
	LD	(RTL_ISR_A),A
	OR	A
	RET


; ------------------------------------------------------
; WAIT_FOR_ARP_REPLY: process incoming frames until either a
; matching ARP reply arrives or the budget expires. Uses ring
; state (BNRY+1 vs CURR) as the primary "data available" signal,
; not ISR.PRX, because PRX is single-shot OR'd and gets cleared
; by us between packets while more may already be queued.
; Out: CF=0 OK (REPLY_MAC populated), CF=1 timeout.
; ------------------------------------------------------
WAIT_FOR_ARP_REPLY
	LD	A,PRX_OUTER
	LD	(OUTER_CTR),A
.MAIN
	CALL	RING_NONEMPTY		; ZF=1 -> empty
	JR	NZ,.HAVE_PKT
	; Ring empty -- wait one tick (~65536 inner) for any signal
	LD	BC,0
.WAIT
	CALL	RING_NONEMPTY		; check during wait too
	JR	NZ,.HAVE_PKT
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.WAIT
	; Tick expired
	LD	A,(OUTER_CTR)
	DEC	A
	LD	(OUTER_CTR),A
	JR	Z,.TIMEOUT
	JR	.MAIN
.HAVE_PKT
	; Clear stale PRX (the bit we use for human-side debugging only).
	LD	A,ISR_PRX
	LD	(RTL_ISR_A),A
	CALL	PROCESS_PACKET
	JR	NC,.MATCHED
	CALL	ADVANCE_BNRY
	JR	.MAIN
.MATCHED
	OR	A
	RET
.TIMEOUT
	SCF
	RET

OUTER_CTR	DB 0


; ------------------------------------------------------
; RING_NONEMPTY: ZF=1 if RX ring is empty (BNRY+1 == CURR),
; ZF=0 otherwise. Trashes A,B,C. Leaves CR back on page 0 STA.
; ------------------------------------------------------
RING_NONEMPTY
	; Read BNRY on page 0 (chip should already be page 0).
	LD	A,(RTL_BNRY_A)
	INC	A
	CP	RTL_PSTOP_INIT
	JR	C,.NW
	LD	A,RTL_PSTART_INIT
.NW
	LD	B,A			; B = expected "next page to read"
	; Switch to page 1, STA so chip keeps running, read CURR.
	LD	A,CR_PAGE1_START
	LD	(RTL_CR_A),A
	LD	A,(RTL_CURR_A)
	LD	C,A
	; Restore page 0 + STA.
	LD	A,CR_PAGE0_START
	LD	(RTL_CR_A),A
	LD	A,B
	CP	C
	RET


; ------------------------------------------------------
; PROCESS_PACKET: read header at (BNRY+1)<<8, read body
; into RX_BUF, classify.
; Out: CF=0 if it is a matching ARP reply, with REPLY_MAC
;        populated and BNRY advanced.
;      CF=1 otherwise; RX_HDR populated but BNRY not yet
;        advanced (caller does ADVANCE_BNRY).
; Trashes A,BC,DE,HL.
; ------------------------------------------------------
PROCESS_PACKET
	; Compute (BNRY+1)<<8 with PSTOP -> PSTART wrap.
	LD	A,(RTL_BNRY_A)
	INC	A
	CP	RTL_PSTOP_INIT
	JR	C,.NW
	LD	A,RTL_PSTART_INIT
.NW
	LD	D,A
	LD	E,0
	; Read 4-byte header.
	PUSH	DE
	LD	HL,RX_HDR
	LD	BC,4
	CALL	@RTL.DMA_READ
	POP	DE
	JR	C,.FAIL
	; Body length = header.len - 4, capped at RX_BUF_SIZE.
	LD	A,(RX_HDR + 2)
	LD	L,A
	LD	A,(RX_HDR + 3)
	LD	H,A
	LD	BC,4
	OR	A
	SBC	HL,BC
	; Cap
	LD	BC,RX_BUF_SIZE
	LD	A,H
	CP	B
	JR	C,.LEN_OK
	JR	NZ,.LEN_CAP
	LD	A,L
	CP	C
	JR	C,.LEN_OK
.LEN_CAP
	LD	HL,RX_BUF_SIZE
.LEN_OK
	LD	(BODY_LEN),HL
	; Body addr = HDR_ADDR + 4 (DE was the header addr)
	INC	DE
	INC	DE
	INC	DE
	INC	DE
	LD	HL,RX_BUF
	LD	BC,(BODY_LEN)
	CALL	@RTL.DMA_READ
	JR	C,.FAIL

	; Classify: EtherType == 0x0806?
	LD	A,(RX_BUF + 12)
	CP	HIGH ETH_TYPE_ARP
	JR	NZ,.MISS
	LD	A,(RX_BUF + 13)
	CP	LOW ETH_TYPE_ARP
	JR	NZ,.MISS

	; ARP op == 2 (reply)?
	LD	A,(RX_BUF + 14 + 6)
	OR	A
	JR	NZ,.MISS
	LD	A,(RX_BUF + 14 + 7)
	CP	ARP_OP_REPLY
	JR	NZ,.MISS

	; Sender IP == TARGET_IP?
	LD	HL,RX_BUF + 14 + 14
	LD	DE,TARGET_IP
	LD	B,4
.CMPIP
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.MISS
	INC	HL
	INC	DE
	DJNZ	.CMPIP

	; Match. Copy sender MAC.
	LD	HL,RX_BUF + 14 + 8
	LD	DE,REPLY_MAC
	LD	BC,6
	LDIR

	; Advance BNRY past this consumed packet.
	CALL	ADVANCE_BNRY
	OR	A
	RET
.MISS
	SCF
	RET
.FAIL
	; DMA error; bail with CF=1 so caller drops/retries.
	SCF
	RET


; ------------------------------------------------------
; ADVANCE_BNRY: BNRY = RX_HDR.next - 1, with PSTART wrap.
; ------------------------------------------------------
ADVANCE_BNRY
	LD	A,(RX_HDR + 1)
	DEC	A
	CP	RTL_PSTART_INIT
	JR	NC,.OK
	LD	A,RTL_PSTOP_INIT - 1
.OK
	LD	(RTL_BNRY_A),A
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
OUR_MAC		DB 0x02, 0x80, 0x19, 0x11, 0x22, 0x33
OUR_IP		DB 192, 168, 7, 2
TARGET_IP	DB 192, 168, 7, 1
REPLY_MAC	DB 0,0,0,0,0,0
BODY_LEN	DW 0


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
MSG_E_WRITE	DB "[E51] DMA write timeout",0
MSG_E_PTX	DB "[E52] PTX timeout",0
MSG_E_REPLY	DB "[E53] ARP reply timeout (no matching reply within budget)",0
LINE_END	DB 13,10,0

	ENDMODULE


	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"


ARP_IMAGE_END

RX_BUF_SIZE	EQU 1518

	MODULE MAIN

TX_BUF		EQU ARP_IMAGE_END
RX_HDR		EQU TX_BUF + FRAME_LEN
RX_BUF		EQU RX_HDR + 4
ARP_BSS_END	EQU RX_BUF + RX_BUF_SIZE

	ENDMODULE

	END MAIN.START
