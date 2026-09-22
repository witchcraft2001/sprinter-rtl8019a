; ======================================================
; NICLB.EXE - stage 3 of the Sprinter RTL8019AS network kit.
; Internal MAC loopback test (TCR=0x02, DCR.LS=0). Builds a
; 60-byte broadcast Ethernet frame and transmits it.  Patched
; MAME stores the looped frame in RX SRAM, so that path reads
; and compares it byte-for-byte.  A real RTL8019AS keeps a
; loopback receive in the diagnostic FIFO instead and does not
; set ISR.PRX (RTL8019AS datasheet section 6.6.2); that path
; captures ISR/RSR/FIFO and treats ISR.RXE as the expected
; receive-side observation after PTX.
;
; Acceptance: PTX plus either MAME RX-ring payload match, or
; real-chip FIFO loopback status. External RX SRAM is tested
; separately by NICRX.EXE.
;
; The receive status is polled for LOOP_WAIT_MS rather than read
; once, and a failure prints what the chip DID report (ISR, RSR,
; TSR, FIFO, tally counters).  An early UMC UM9003F answers PTX
; with neither PRX nor RXE and raises only ISR.CNT, while the
; UM9003AF passes; without these values the two cannot be told
; apart from a screenshot.
; ======================================================

EXE_VERSION		EQU 1		; DSS executable format version, not app version

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "rtl8019.inc"

	DEFINE USE_UTIL_EXIT_NO_NIC	; fast-fail "no NIC" path

	DEFINE USE_RTL_INIT_LOOPBACK
	DEFINE USE_RTL_SEND_FRAME
	DEFINE USE_RTL_WAIT_PTX
	DEFINE USE_RTL_SNAPSHOT_TALLY	; tally counters around the loop

; -- frame layout in TX_BUF --
FRAME_LEN	EQU 60			; min Ethernet frame, no FCS
ETH_TYPE	EQU 0x88B5		; experimental EtherType per spec stage 4
LOOP_WAIT_MS	EQU 50			; receive-status wait after PTX

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
	CALL	@RTL.INIT_BASE
	JP	C,@UTIL.EXIT_NO_NIC
	CALL	@ISA.ISA_CLOSE

	; [L0] INIT
	PRINT MSG_L0
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.RESET
	JP	C,RESET_OPEN_FAIL
	CALL	@ISA.ISA_CLOSE
	PRINTLN MSG_OK

	; [L1] CFG -- internal loopback configuration
	PRINT MSG_L1_PREFIX
	LD	A,DCR_LOOPBACK
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_L1_RCR
	LD	A,RCR_AB
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_L1_TCR
	LD	A,TCR_LB_INTERNAL
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_L1_PSTART
	LD	A,(RTL_PSTART_PAGE)
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_L1_PSTOP
	LD	A,(RTL_PSTOP_PAGE)
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_L1_BNRY
	LD	A,(RTL_PSTART_PAGE)
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_L1_CURR
	LD	A,(RTL_PSTART_PAGE)
	INC	A
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_L1_CLOSE
	LD	HL,TEST_MAC
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.INIT_LOOPBACK
	; Read-to-clear the tally counters (and ISR.CNT) so the values
	; printed after the loop belong to this one frame.
	LD	HL,TALLY_BUF
	CALL	@RTL.SNAPSHOT_TALLY
	CALL	@ISA.ISA_CLOSE
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
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.SEND_FRAME
	JP	C,WRITE_OPEN_FAIL
	CALL	@ISA.ISA_CLOSE
	PRINTLN MSG_OK

	; [L4] PTX done by SEND_FRAME above, just confirm.
	PRINTLN MSG_L4_OK

	; [L5] Inspect the completed loopback receive.  Patched MAME sets
	; PRX and writes RX SRAM.  Real RTL8019AS does not store loopback
	; frames in SRAM; it exposes the tail in FIFO and, for this test
	; shape, reports RXE after the already-confirmed PTX.
	; The status is polled: a clone may post it later than PTX.  The
	; window is closed across each 1 ms delay (ISA discipline).
	PRINT MSG_L5
	LD	B,LOOP_WAIT_MS
.WAIT_STATUS
	PUSH	BC
	CALL	@ISA.ISA_OPEN
	LD	IX,(RTL_BASE_PTR)
	LD	A,(IX+RTL_ISR_OFF)
	LD	(LOOP_ISR),A
	POP	BC
	AND	ISR_PRX | ISR_RXE
	JR	NZ,.STATUS_SEEN
	DEC	B
	JR	Z,.STATUS_SEEN		; timed out, window still open
	PUSH	BC
	CALL	@ISA.ISA_CLOSE
	CALL	@UTIL.DELAY_1MS
	POP	BC
	JR	.WAIT_STATUS
.STATUS_SEEN
	LD	A,(LOOP_ISR)
	AND	ISR_PRX
	JP	NZ,.LOOP_SRAM
	LD	A,(IX+RTL_RSR_OFF)
	LD	(LOOP_RSR),A
	LD	HL,FIFO_BUF
	LD	B,8
.FIFO_READ
	LD	A,(IX+RTL_FIFO_OFF)
	LD	(HL),A
	INC	HL
	DJNZ	.FIFO_READ
	LD	HL,TALLY_BUF
	CALL	@RTL.SNAPSHOT_TALLY
	LD	A,(LOOP_ISR)
	AND	ISR_RXE
	JP	Z,PRX_OPEN_FAIL
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_ISR_OFF),ISR_RXE
	CALL	@ISA.ISA_CLOSE
	PRINT	MSG_FIFO_OK
	CALL	PRINT_LOOP_DIAG
	PRINTLN MSG_L6_NA
	PRINTLN MSG_L7_NA
	PRINTLN MSG_L8_NA
	PRINTLN MSG_RESULT_OK
	DSS_RETURN EX_OK

.LOOP_SRAM
	LD	(IX+RTL_ISR_OFF),ISR_PRX
	CALL	@ISA.ISA_CLOSE
	PRINTLN MSG_SRAM_OK

	; [L6] RX HDR -- read 4-byte header from 0x4700 (initial CURR<<8)
	LD	HL,RX_HDR
	LD	BC,4
	LD	A,(RTL_PSTART_PAGE)
	INC	A
	LD	D,A
	LD	E,0
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.DMA_READ
	JP	C,READ_OPEN_FAIL
	CALL	@ISA.ISA_CLOSE

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
	LD	A,(RTL_PSTART_PAGE)
	INC	A
	LD	D,A
	LD	E,4
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.DMA_READ
	JP	C,READ_OPEN_FAIL
	CALL	@ISA.ISA_CLOSE
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
	DSS_RETURN EX_OK

; ------- error exits -------
RESET_OPEN_FAIL
	CALL	@RTL.SNAPSHOT_REGS
	CALL	@ISA.ISA_CLOSE
RESET_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_RESET
	JP	FAIL_CAPTURED

WRITE_OPEN_FAIL
	CALL	@RTL.SNAPSHOT_REGS
	CALL	@ISA.ISA_CLOSE

WRITE_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_WRITE
	JP	FAIL_CAPTURED

PRX_OPEN_FAIL
	CALL	@RTL.SNAPSHOT_REGS
	CALL	@ISA.ISA_CLOSE

PRX_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_PRX
	PRINT	MSG_LOOP_INDENT
	CALL	PRINT_LOOP_DIAG
	JP	FAIL_CAPTURED

READ_OPEN_FAIL
	CALL	@RTL.SNAPSHOT_REGS
	CALL	@ISA.ISA_CLOSE

READ_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_READ
	JP	FAIL_CAPTURED

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
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.SNAPSHOT_REGS
	CALL	@ISA.ISA_CLOSE
FAIL_CAPTURED
	CALL	PRINT_REG_DUMP
	PRINTLN MSG_RESULT_FAIL
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


; ------------------------------------------------------
; PRINT_LOOP_DIAG: what the receive side reported after PTX.
;   "ISR=xx RSR=xx TSR=xx FIFO=xx xx xx xx xx xx xx xx"
;   " NIC fae=xx crc=xx mpc=xx"
; ISR is the value the wait loop ended on, TSR the one WAIT_PTX
; captured at completion, the counters this frame's delta.
; ------------------------------------------------------
PRINT_LOOP_DIAG
	PRINT	MSG_ISR_EQ
	LD	A,(LOOP_ISR)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	MSG_RSR_EQ
	LD	A,(LOOP_RSR)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	MSG_TSR_EQ
	LD	A,(RTL_TX_LAST_TSR)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	MSG_FIFO_EQ
	LD	HL,FIFO_BUF
	LD	B,8
.FIFO
	LD	A,(HL)
	CALL	@UTIL.PRINT_HEX_A
	INC	HL
	DEC	B
	JR	Z,.FIFO_DONE
	PUSH	HL			; DSS output does not preserve HL
	LD	A,' '
	CALL	PUTCHAR
	POP	HL
	JR	.FIFO
.FIFO_DONE
	PRINT	LINE_END
	PRINT	MSG_NIC_FAE
	LD	A,(TALLY_BUF + 0)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	MSG_NIC_CRC
	LD	A,(TALLY_BUF + 1)
	CALL	@UTIL.PRINT_HEX_A
	PRINT	MSG_NIC_MPC
	LD	A,(TALLY_BUF + 2)
	CALL	@UTIL.PRINT_HEX_A
	; A clone without tally counters answers them all with one fixed
	; value; printing that as an error rate invents a broken cable.
	LD	A,(TALLY_BUF + 4)
	OR	A
	JR	Z,.REAL
	PRINT	MSG_NIC_NA
.REAL
	PRINT	LINE_END
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
MSG_BANNER	DB "RTL8019AS NICLB v",PACKAGE_VERSION,0
MSG_L0		DB "[L0] INIT ",0
MSG_OK		DB "OK",0
MSG_L1_PREFIX	DB "[L1] CFG (DCR=",0
MSG_L1_RCR	DB " RCR=",0
MSG_L1_TCR	DB " TCR=",0
MSG_L1_PSTART	DB " PSTART=",0
MSG_L1_PSTOP	DB " PSTOP=",0
MSG_L1_BNRY	DB " BNRY=",0
MSG_L1_CURR	DB " CURR=",0
MSG_L1_CLOSE	DB ") ",0
MSG_L2		DB "[L2] FRAME LEN=",0
MSG_TYPE_EQ	DB " TYPE=",0
MSG_L3		DB "[L3] WRITE TX ",0
MSG_L4_OK	DB "[L4] PTX OK",0
MSG_L5		DB "[L5] LOOP ",0
MSG_SRAM_OK	DB "SRAM OK",0
MSG_FIFO_OK	DB "FIFO OK ",0
MSG_LOOP_INDENT	DB " ",0
MSG_ISR_EQ	DB "ISR=",0
MSG_RSR_EQ	DB " RSR=",0
MSG_TSR_EQ	DB " TSR=",0
MSG_FIFO_EQ	DB " FIFO=",0
MSG_NIC_FAE	DB " NIC fae=",0
MSG_NIC_CRC	DB " crc=",0
MSG_NIC_MPC	DB " mpc=",0
MSG_NIC_NA	DB " (no tally counters on this chip)",0
MSG_L6		DB "[L6] RX HDR",0
MSG_STS_EQ	DB " STS=",0
MSG_NEXT_EQ	DB " NEXT=",0
MSG_LEN_EQ	DB " LEN=",0
MSG_L7		DB "[L7] READ RX ",0
MSG_L8		DB "[L8] CMP ",0
MSG_L6_NA	DB "[L6] RX SRAM N/A (real RTL8019AS loopback uses FIFO)",0
MSG_L7_NA	DB "[L7] READ RX N/A",0
MSG_L8_NA	DB "[L8] CMP N/A; run NICRX for external RX SRAM",0
MSG_REGS	DB "REGS ",0
MSG_RESULT_OK	DB "RESULT OK",0
MSG_RESULT_FAIL	DB "RESULT FAIL",0
MSG_E_RESET	DB "[E20] RESET timeout",0
MSG_E_WRITE	DB "[E21] DMA write or PTX timeout",0
MSG_E_PRX	DB "[E23] loopback produced neither PRX nor RXE in 50 ms",0
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

; Not right after the image: DSS scribbles on the 0x9xxx area while
; printing on real hardware (NICINFO lost a captured byte at 0x910F
; that way), and these values are printed across many DSS calls.
TX_BUF		EQU APP_BSS_BASE
RX_HDR		EQU TX_BUF + FRAME_LEN
RX_BUF		EQU RX_HDR + 4
FIFO_BUF	EQU RX_BUF + FRAME_LEN	; 8-byte real-chip diagnostic FIFO capture
LOOP_ISR	EQU FIFO_BUF + 8
LOOP_RSR	EQU LOOP_ISR + 1
TALLY_BUF	EQU LOOP_RSR + 1	; CNTR0..2 + RSR + "no tallies" flag
NICLB_BSS_END	EQU TALLY_BUF + 5

	ENDMODULE

	END MAIN.START
