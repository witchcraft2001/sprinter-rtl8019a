; ======================================================
; NICLB.EXE - stage 3 of the Sprinter RTL8019AS network kit.
; Internal MAC loopback test (TCR=0x02, DCR.LS=0). Builds a
; 60-byte broadcast Ethernet frame, transmits it, waits for
; both ISR.PTX and ISR.PRX, then reads the looped frame back
; from the RX ring and compares it byte-for-byte against the
; original TX buffer.
;
; Acceptance: PTX OK, PRX OK, RX header STS/LEN as expected,
; body bytes match. Requires the patched MAME (dp8390.cpp:85)
; that injects loopback TX into recv().
; ======================================================

EXE_VERSION		EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "rtl8019.inc"

	DEFINE USE_UTIL_EXIT_NO_NIC	; fast-fail "no NIC" path

	DEFINE USE_RTL_INIT_LOOPBACK
	DEFINE USE_RTL_SEND_FRAME
	DEFINE USE_RTL_WAIT_PTX

; -- timeouts --
PRX_LOOPS	EQU 8000

; -- frame layout in TX_BUF --
FRAME_LEN	EQU 60			; min Ethernet frame, no FCS
ETH_TYPE	EQU 0x88B5		; experimental EtherType per spec stage 4

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
	CALL	@RTL.PROBE_PRESENT
	JP	C,@UTIL.EXIT_NO_NIC

	; [L0] INIT
	PRINT MSG_L0
	CALL	@RTL.RESET
	JP	C,RESET_FAIL
	PRINTLN MSG_OK

	; [L1] CFG -- internal loopback configuration
	PRINT MSG_L1
	LD	HL,TEST_MAC
	CALL	@RTL.INIT_LOOPBACK
	PRINTLN MSG_OK

	; [L2] FRAME -- build 60-byte broadcast frame in TX_BUF
	CALL	BUILD_FRAME
	PRINT MSG_L2
	LD	HL,FRAME_LEN
	CALL	@UTIL.PRINT_HEX_HL
	PRINT MSG_TYPE_EQ
	LD	HL,ETH_TYPE
	CALL	@UTIL.PRINT_HEX_HL
	PRINT LINE_END

	; [L3] WRITE TX (DMA + TBCR + CR.TXP + wait PTX)
	PRINT MSG_L3
	LD	HL,TX_BUF
	LD	BC,FRAME_LEN
	CALL	@RTL.SEND_FRAME
	JP	C,WRITE_FAIL
	PRINTLN MSG_OK

	; [L4] PTX done by SEND_FRAME above, just confirm.
	PRINTLN MSG_L4_OK

	; [L5] PRX (loopback frame should already be in RX ring)
	PRINT MSG_L5
	CALL	WAIT_PRX
	JP	C,PRX_FAIL
	PRINTLN MSG_OK

	; [L6] RX HDR -- read 4-byte header from 0x4700 (initial CURR<<8)
	LD	HL,RX_HDR
	LD	BC,4
	LD	DE,0x4700
	CALL	@RTL.DMA_READ
	JP	C,READ_FAIL

	PRINT MSG_L6
	PRINT MSG_STS_EQ
	LD	A,(RX_HDR + 0)
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_NEXT_EQ
	LD	A,(RX_HDR + 1)
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_LEN_EQ
	LD	A,(RX_HDR + 3)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,(RX_HDR + 2)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END

	; Verify status byte: expect 0x21 (PRX | PHY for broadcast match)
	LD	A,(RX_HDR + 0)
	CP	0x21
	JP	NZ,STS_BAD

	; Verify length: expect 64 (= FRAME_LEN + 4 header bytes)
	LD	A,(RX_HDR + 2)
	CP	LOW (FRAME_LEN + 4)
	JP	NZ,LEN_BAD
	LD	A,(RX_HDR + 3)
	CP	HIGH (FRAME_LEN + 4)
	JP	NZ,LEN_BAD

	; [L7] READ RX body from 0x4704
	PRINT MSG_L7
	LD	HL,RX_BUF
	LD	BC,FRAME_LEN
	LD	DE,0x4704
	CALL	@RTL.DMA_READ
	JP	C,READ_FAIL
	PRINTLN MSG_OK

	; [L8] CMP body byte-for-byte vs TX_BUF
	PRINT MSG_L8
	LD	HL,TX_BUF
	LD	DE,RX_BUF
	LD	BC,FRAME_LEN
	CALL	CMP_BUF
	JP	C,BODY_BAD
	PRINTLN MSG_OK

	PRINTLN MSG_RESULT_OK
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_OK

; ------- error exits -------
RESET_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_RESET
	JP	FAIL_NIC

WRITE_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_WRITE
	JP	FAIL_NIC

PRX_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_PRX
	JP	FAIL_NIC

READ_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_READ
	JP	FAIL_NIC

STS_BAD
	PRINT LINE_END
	PRINT MSG_E_STS
	LD	A,(RX_HDR + 0)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END
	JP	FAIL_NIC

LEN_BAD
	PRINT LINE_END
	PRINT MSG_E_LEN
	LD	A,(RX_HDR + 3)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,(RX_HDR + 2)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END
	JP	FAIL_NIC

BODY_BAD
	PRINT LINE_END
	PRINTLN MSG_E_BODY
	; HL=mismatch addr in TX_BUF, DE=corresponding addr in RX_BUF, B=expected, A=actual
	; (CMP_BUF leaves these on mismatch; show offset and bytes)
	; fall through to FAIL_NIC

FAIL_NIC
	CALL	@RTL.SNAPSHOT_REGS
	CALL	PRINT_REG_DUMP
	PRINTLN MSG_RESULT_FAIL
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_NIC_ERR


; ------------------------------------------------------
; BUILD_FRAME: assemble a 60-byte broadcast frame in TX_BUF.
;   [0..5]   DST = FF:FF:FF:FF:FF:FF
;   [6..11]  SRC = TEST_MAC
;   [12..13] EtherType = ETH_TYPE (BE)
;   [14..]   payload "SPRINTER NICLB TEST", zero-padded to 60.
; ------------------------------------------------------
; LDIR copies (HL) -> (DE), so DE is the destination cursor and HL
; is the source pointer. We walk DE through TX_BUF and pull DST/SRC/
; payload bytes from constants via HL.
BUILD_FRAME
	LD	DE,TX_BUF
	; DST = FF*6
	LD	B,6
.DST
	LD	A,0xFF
	LD	(DE),A
	INC	DE
	DJNZ	.DST
	; SRC = TEST_MAC
	LD	HL,TEST_MAC
	LD	BC,6
	LDIR
	; EtherType (big endian)
	LD	A,HIGH ETH_TYPE
	LD	(DE),A
	INC	DE
	LD	A,LOW ETH_TYPE
	LD	(DE),A
	INC	DE
	; Payload
	LD	HL,PAYLOAD
	LD	BC,PAYLOAD_LEN
	LDIR
	; Zero-pad up to FRAME_LEN
	LD	BC,FRAME_LEN - 14 - PAYLOAD_LEN
	LD	A,B
	OR	C
	RET	Z
.PAD
	XOR	A
	LD	(DE),A
	INC	DE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.PAD
	RET


; ------------------------------------------------------
; WAIT_PRX: poll ISR.PRX. CF=0 OK, CF=1 timeout. Trashes A,BC.
; ------------------------------------------------------
WAIT_PRX
	LD	BC,PRX_LOOPS
.LP
	LD	A,(RTL_ISR_A)
	AND	ISR_PRX
	JR	NZ,.OK
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.LP
	SCF
	RET
.OK
	LD	A,ISR_PRX
	LD	(RTL_ISR_A),A
	OR	A
	RET


; ------------------------------------------------------
; CMP_BUF: compare BC bytes at (HL) vs (DE).
; Out: CF=0 match, CF=1 mismatch.
; Preserved on mismatch: HL=expected addr, DE=actual addr.
; ------------------------------------------------------
CMP_BUF
.LP
	LD	A,B
	OR	C
	JR	Z,.OK
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.MISS
	INC	HL
	INC	DE
	DEC	BC
	JR	.LP
.OK
	OR	A
	RET
.MISS
	SCF
	RET


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
TEST_MAC	DB 0x02, 0x80, 0x19, 0x11, 0x22, 0x33

PAYLOAD		DB "SPRINTER NICLB TEST"
PAYLOAD_LEN	EQU $ - PAYLOAD


; ------- messages -------
MSG_BANNER	DB "RTL8019AS NICLB v0.1",0
MSG_L0		DB "[L0] INIT ",0
MSG_OK		DB "OK",0
MSG_L1		DB "[L1] CFG (DCR=40 RCR=04 TCR=02 PSTART=46 PSTOP=80 BNRY=46 CURR=47) ",0
MSG_L2		DB "[L2] FRAME LEN=",0
MSG_TYPE_EQ	DB " TYPE=",0
MSG_L3		DB "[L3] WRITE TX ",0
MSG_L4_OK	DB "[L4] PTX OK",0
MSG_L5		DB "[L5] PRX ",0
MSG_L6		DB "[L6] RX HDR",0
MSG_STS_EQ	DB " STS=",0
MSG_NEXT_EQ	DB " NEXT=",0
MSG_LEN_EQ	DB " LEN=",0
MSG_L7		DB "[L7] READ RX ",0
MSG_L8		DB "[L8] CMP ",0
MSG_REGS	DB "REGS ",0
MSG_RESULT_OK	DB "RESULT OK",0
MSG_RESULT_FAIL	DB "RESULT FAIL",0
MSG_E_RESET	DB "[E20] RESET timeout",0
MSG_E_WRITE	DB "[E21] DMA write or PTX timeout",0
MSG_E_PRX	DB "[E23] PRX timeout (loopback frame did not appear in RX ring)",0
MSG_E_READ	DB "[E24] DMA read timeout",0
MSG_E_STS	DB "[E25] RX status mismatch, got STS=",0
MSG_E_LEN	DB "[E26] RX len mismatch, got LEN=",0
MSG_E_BODY	DB "[E27] RX body mismatch",0
LINE_END	DB 13,10,0

	ENDMODULE


	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"


NICLB_IMAGE_END

	MODULE MAIN

TX_BUF		EQU NICLB_IMAGE_END
RX_HDR		EQU TX_BUF + FRAME_LEN
RX_BUF		EQU RX_HDR + 4
NICLB_BSS_END	EQU RX_BUF + FRAME_LEN

	ENDMODULE

	END MAIN.START
