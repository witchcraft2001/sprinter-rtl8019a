; ======================================================
; NICRX.EXE - stage 5 of the Sprinter RTL8019AS network kit.
; Polls ISR.PRX for one incoming Ethernet frame and prints
; its source MAC, EtherType, length, and payload as
; printable text (control bytes shown as '.').
;
; The chip is configured with RCR=0 (physical match only,
; broadcast/multicast rejected at the hardware level). This
; filters out the noisy real-network broadcast traffic that
; pcap would otherwise deliver. The host must therefore send
; a UNICAST frame addressed to our PAR (02:80:19:11:22:33);
; tools/dev/send_frame.py defaults to exactly that.
;
; Host side:
;   sudo python3 tools/dev/send_frame.py --iface en0
;
; Acceptance: PRX fires within the timeout, RX header is
; sane (status byte has PRX bit set), body bytes match what
; the host sent.
; ======================================================

EXE_VERSION		EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "rtl8019.inc"

	DEFINE USE_UTIL_EXIT_NO_NIC	; fast-fail "no NIC" path

	DEFINE USE_RTL_INIT_NORMAL

PRX_OUTER	EQU 64			; ~30s with ISA wait states
RDC_LOOPS	EQU 8000

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

	; [X0] INIT
	PRINT MSG_X0
	CALL	@RTL.RESET
	JP	C,RESET_FAIL
	LD	HL,OUR_MAC
	XOR	A			; RCR = 0: physical match only.
	CALL	@RTL.INIT_NORMAL
	PRINTLN MSG_OK

	; [X1] WAIT RX -- prompt user to send a frame from the host.
	PRINTLN MSG_X1
	PRINTLN MSG_X1_HINT

	CALL	WAIT_PRX_LONG
	JP	C,PRX_TIMEOUT

	; Read RX header (4 bytes) from page (BNRY+1)<<8 = 0x4700.
	LD	HL,RX_HDR
	LD	BC,4
	LD	DE,0x4700
	CALL	@RTL.DMA_READ
	JP	C,READ_FAIL

	; Sanity-check: STS bit 0 (PRX) should be set, len in range.
	LD	A,(RX_HDR + 0)
	AND	1
	JP	Z,STS_BAD

	; Body length = header.len - 4. header.len at offsets [2]=lo [3]=hi.
	LD	A,(RX_HDR + 2)
	LD	L,A
	LD	A,(RX_HDR + 3)
	LD	H,A
	; HL = header.len. Subtract 4 to get body length.
	LD	BC,4
	OR	A
	SBC	HL,BC
	LD	(BODY_LEN),HL

	; Cap body length at our buffer size (defensive; shouldn't hit
	; on normal traffic up to 1518).
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
	LD	(BODY_LEN),HL
.LEN_OK

	; Read body from 0x4704 into RX_BUF.
	LD	HL,RX_BUF
	LD	BC,(BODY_LEN)
	LD	DE,0x4704
	CALL	@RTL.DMA_READ
	JP	C,READ_FAIL

	; [X2] RX LEN=xxxx SRC=xx:xx:xx:xx:xx:xx TYPE=xxxx
	PRINT MSG_X2_LEN
	LD	HL,(BODY_LEN)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT MSG_SRC_EQ
	LD	HL,RX_BUF + 6
	CALL	@UTIL.PRINT_MAC
	PRINT MSG_TYPE_EQ
	LD	A,(RX_BUF + 12)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,(RX_BUF + 13)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END

	; [X3] PAYLOAD=...
	PRINT MSG_X3
	LD	HL,RX_BUF + 14		; payload starts after Ethernet header
	LD	BC,(BODY_LEN)
	LD	DE,14
	OR	A
	SBC	HL,DE			; HL = RX_BUF + 14
	LD	HL,RX_BUF + 14
	LD	BC,(BODY_LEN)
	LD	A,B
	OR	C
	JR	Z,.PAY_DONE
	; subtract 14 from BC (payload-only length)
	LD	A,C
	SUB	14
	LD	C,A
	LD	A,B
	SBC	A,0
	LD	B,A
	; Cap at 64 chars to avoid noisy 1518-byte dumps.
	LD	A,B
	OR	A
	JR	NZ,.CAP64
	LD	A,C
	CP	64
	JR	C,.PAY_PRINT
.CAP64
	LD	BC,64
.PAY_PRINT
.PLP
	LD	A,B
	OR	C
	JR	Z,.PAY_DONE
	LD	A,(HL)
	CALL	PRINT_PRINTABLE
	INC	HL
	DEC	BC
	JR	.PLP
.PAY_DONE
	PRINT LINE_END

	; [X4] HDR STS=xx NEXT=xx LEN=xxxx (informational)
	PRINT MSG_X4
	LD	A,(RX_HDR + 0)
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_NEXT_EQ
	LD	A,(RX_HDR + 1)
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_HDRLEN_EQ
	LD	A,(RX_HDR + 3)
	CALL	@UTIL.PRINT_HEX_A
	LD	A,(RX_HDR + 2)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END

	PRINTLN MSG_RESULT_OK
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_OK


RESET_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_RESET
	JP	FAIL_NIC

PRX_TIMEOUT
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

FAIL_NIC
	CALL	@RTL.SNAPSHOT_REGS
	CALL	PRINT_REG_DUMP
	PRINTLN MSG_RESULT_FAIL
	CALL	@ISA.ISA_CLOSE
	DSS_RETURN EX_NIC_ERR


; ------------------------------------------------------
; WAIT_PRX_LONG: poll ISR.PRX with a generous timeout
; (PRX_OUTER * 65536 inner iterations).
; CF=0 OK (PRX cleared), CF=1 timeout.
; ------------------------------------------------------
WAIT_PRX_LONG
	LD	D,PRX_OUTER
.OUTER
	LD	BC,0			; 65536 iterations
.LP
	LD	A,(RTL_ISR_A)
	AND	ISR_PRX
	JR	NZ,.GOT
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.LP
	DEC	D
	JR	NZ,.OUTER
	SCF
	RET
.GOT
	LD	A,ISR_PRX
	LD	(RTL_ISR_A),A		; clear PRX
	OR	A
	RET


PRINT_PRINTABLE
	PUSH	AF,BC
	CP	32
	JR	C,.DOT
	CP	127
	JR	NC,.DOT
	JR	.OK
.DOT
	LD	A,'.'
.OK
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC,AF
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
; Local PAR/MAC value -- needed only for unicast filtering. Broadcast
; reception works regardless. Future: read from PROM via NICINFO logic.
OUR_MAC		DB 0x02, 0x80, 0x19, 0x11, 0x22, 0x33

BODY_LEN	DW 0


; ------- messages -------
MSG_BANNER	DB "RTL8019AS NICRX v0.1",0
MSG_X0		DB "[X0] INIT ",0
MSG_OK		DB "OK",0
MSG_X1		DB "[X1] WAIT RX",0
MSG_X1_HINT	DB "     send a unicast 88B5 frame to 02:80:19:11:22:33 from host, e.g.:",13,10,"     sudo python3 tools/dev/send_frame.py --iface en0",0
MSG_X2_LEN	DB "[X2] RX LEN=",0
MSG_SRC_EQ	DB " SRC=",0
MSG_TYPE_EQ	DB " TYPE=",0
MSG_X3		DB "[X3] PAYLOAD=",0
MSG_X4		DB "[X4] HDR STS=",0
MSG_NEXT_EQ	DB " NEXT=",0
MSG_HDRLEN_EQ	DB " LEN=",0
MSG_REGS	DB "REGS ",0
MSG_RESULT_OK	DB "RESULT OK",0
MSG_RESULT_FAIL	DB "RESULT FAIL",0
MSG_E_RESET	DB "[E40] RESET timeout",0
MSG_E_PRX	DB "[E41] PRX timeout (no frame received within ~30s)",0
MSG_E_READ	DB "[E42] DMA read timeout",0
MSG_E_STS	DB "[E43] RX status mismatch (PRX bit clear), STS=",0
LINE_END	DB 13,10,0

	ENDMODULE


	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"


NICRX_IMAGE_END

RX_BUF_SIZE	EQU 1518

	MODULE MAIN

RX_HDR		EQU NICRX_IMAGE_END
RX_BUF		EQU RX_HDR + 4
NICRX_BSS_END	EQU RX_BUF + RX_BUF_SIZE

	ENDMODULE

	END MAIN.START
