; ======================================================
; NICRAM.EXE - stage 2 of the Sprinter RTL8019AS network kit.
; Verifies remote DMA write/read against packet RAM at 0x4000
; for byte counts 16, 64, 256, 1536. Generates a deterministic
; pattern (byte i = i & 0xFF), writes, reads back, and prints
; the first mismatch on failure.
;
; Acceptance: every (write, read) pair completes without RDC
; timeout and the readback matches the pattern byte-for-byte.
; ======================================================

EXE_VERSION		EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "rtl8019.inc"

	DEFINE USE_UTIL_EXIT_NO_NIC	; fast-fail "no NIC" path

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

	; [R0] INIT
	PRINT MSG_R0
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.RESET
	JP	C,RESET_OPEN_FAIL
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_DCR_OFF),DCR_INIT
	CALL	@ISA.ISA_CLOSE
	PRINTLN MSG_OK

	; Stage counter for incremental [Rn] codes.
	LD	A,1
	LD	(STAGE_NO),A

	; Iterate through TEST_CASES: address,length pairs ending with address 0.
	; The walker pointer lives in memory, NOT a register: DMA_WRITE /
	; DMA_READ clobber IX (LD IX,(RTL_BASE_PTR)), so an IX-based walker
	; read a bogus size on the 2nd pass -> 0x55FF-byte DMA -> system RAM
	; corruption / power-off.  Reload from TEST_PTR each iteration.
	LD	HL,TEST_CASES
	LD	(TEST_PTR),HL
.NEXT_TEST
	LD	HL,(TEST_PTR)
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	INC	HL
	LD	A,D
	OR	E
	JP	Z,ALL_OK		; 0 marks list end
	LD	(CUR_ADDR),DE
	LD	C,(HL)
	INC	HL
	LD	B,(HL)
	INC	HL
	LD	(TEST_PTR),HL
	LD	(CUR_SIZE),BC

	; Generate pattern in RAM_BUF
	LD	HL,RAM_BUF
	LD	BC,(CUR_SIZE)
	CALL	GEN_PATTERN

	; -- WRITE --
	CALL	PRINT_STAGE		; "[Rn] "
	PRINT MSG_WRITE
	LD	HL,(CUR_ADDR)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT MSG_LEN_EQ
	LD	HL,(CUR_SIZE)
	CALL	@UTIL.PRINT_HEX_HL
	LD	HL,RAM_BUF		; source
	LD	BC,(CUR_SIZE)
	LD	DE,(CUR_ADDR)
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.DMA_WRITE
	JP	C,DMA_WRITE_OPEN_FAIL
	CALL	@ISA.ISA_CLOSE
	LD	A,' '
	CALL	PUTCHAR
	PRINTLN MSG_OK
	LD	A,(STAGE_NO)
	INC	A
	LD	(STAGE_NO),A

	; Trash buffer with sentinel 0xFF so a stale-buffer match
	; cannot be mistaken for a successful readback.
	LD	HL,RAM_BUF
	LD	BC,(CUR_SIZE)
	CALL	FILL_FF

	; -- READ --
	CALL	PRINT_STAGE
	PRINT MSG_READ
	LD	HL,(CUR_ADDR)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT MSG_LEN_EQ
	LD	HL,(CUR_SIZE)
	CALL	@UTIL.PRINT_HEX_HL
	LD	HL,RAM_BUF
	LD	BC,(CUR_SIZE)
	LD	DE,(CUR_ADDR)
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.DMA_READ
	JP	C,DMA_READ_OPEN_FAIL
	CALL	@ISA.ISA_CLOSE
	LD	A,' '
	CALL	PUTCHAR
	PRINTLN MSG_OK
	LD	A,(STAGE_NO)
	INC	A
	LD	(STAGE_NO),A

	; -- COMPARE --
	LD	HL,RAM_BUF
	LD	BC,(CUR_SIZE)
	CALL	CMP_PATTERN
	JP	C,MISMATCH

	JP	.NEXT_TEST

ALL_OK
	PRINTLN MSG_RESULT_OK
	DSS_RETURN EX_OK

RESET_OPEN_FAIL
	CALL	@ISA.ISA_CLOSE
RESET_FAIL
	PRINTLN MSG_E_RESET
	PRINTLN MSG_RESULT_FAIL
	DSS_RETURN EX_NIC_ERR

DMA_WRITE_OPEN_FAIL
	CALL	@RTL.SNAPSHOT_REGS
	CALL	@ISA.ISA_CLOSE
	JP	DMA_WRITE_FAIL

DMA_WRITE_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_WRITE
	CALL	PRINT_REG_DUMP
	PRINTLN MSG_RESULT_FAIL
	DSS_RETURN EX_NIC_ERR

DMA_READ_OPEN_FAIL
	CALL	@RTL.SNAPSHOT_REGS
	CALL	@ISA.ISA_CLOSE
	JP	DMA_READ_FAIL

DMA_READ_FAIL
	PRINT LINE_END
	PRINTLN MSG_E_READ
	CALL	PRINT_REG_DUMP
	PRINTLN MSG_RESULT_FAIL
	DSS_RETURN EX_NIC_ERR

MISMATCH
	; HL = mismatch addr (within RAM_BUF), D = expected, A = actual
	; Compute packet-RAM offset: (HL - RAM_BUF) is the byte index;
	; packet-RAM addr = 0x4000 + index.
	LD	(MISS_GOT),A
	LD	A,D
	LD	(MISS_EXP),A
	LD	BC,RAM_BUF
	OR	A
	SBC	HL,BC
	LD	BC,(CUR_ADDR)
	ADD	HL,BC
	LD	(MISS_ADDR),HL
	CALL	@ISA.ISA_OPEN
	CALL	@RTL.SNAPSHOT_REGS
	CALL	@ISA.ISA_CLOSE

	PRINT LINE_END
	PRINT MSG_E_MISMATCH
	PRINT MSG_ADDR_EQ
	LD	HL,(MISS_ADDR)
	CALL	@UTIL.PRINT_HEX_HL
	PRINT MSG_EXP_EQ
	LD	A,(MISS_EXP)
	CALL	@UTIL.PRINT_HEX_A
	PRINT MSG_GOT_EQ
	LD	A,(MISS_GOT)
	CALL	@UTIL.PRINT_HEX_A
	PRINT LINE_END

	CALL	PRINT_REG_DUMP
	PRINTLN MSG_RESULT_FAIL
	DSS_RETURN EX_NIC_ERR


; ------------------------------------------------------
; Print "[Rn] " where n is decimal STAGE_NO (1..9, then "10".."xx").
; Trashes A.
; ------------------------------------------------------
PRINT_STAGE
	LD	A,'['
	CALL	PUTCHAR
	LD	A,'R'
	CALL	PUTCHAR
	LD	A,(STAGE_NO)
	CALL	PRINT_DEC_A
	LD	A,']'
	CALL	PUTCHAR
	LD	A,' '
	CALL	PUTCHAR
	RET

; ------------------------------------------------------
; Print A as decimal (0..255). Strips leading zeros.
; ------------------------------------------------------
PRINT_DEC_A
	PUSH	AF,BC,DE,HL
	LD	L,A
	LD	H,0
	LD	DE,DEC_BUF + 3
	XOR	A
	LD	(DE),A			; null terminator
	LD	C,10
.LP
	LD	A,L
	; HL / 10 -> HL, remainder in A
	; simple 16-bit / 8-bit: only need 0..255 so just A-mod-10
	; iterate via subtraction
	LD	A,L
	LD	B,0
.SUB
	CP	10
	JR	C,.GOT_REM
	SUB	10
	INC	B
	JR	.SUB
.GOT_REM
	LD	L,B			; quotient
	; A = remainder
	ADD	A,'0'
	DEC	DE
	LD	(DE),A
	LD	A,L
	OR	A
	JR	NZ,.LP

	; Print from DE
	EX	DE,HL
	LD	C,DSS_PCHARS
	RST	DSS
	POP	HL,DE,BC,AF
	RET

; ------------------------------------------------------
; Print one byte (in A) via DSS_PUTCHAR.
; ------------------------------------------------------
PUTCHAR
	PUSH	AF,BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC,AF
	RET

; ------------------------------------------------------
; GEN_PATTERN: fill (HL) with pattern byte_i = i & 0xFF.
; In: HL = buffer, BC = length. Trashes A,D,BC,HL.
; ------------------------------------------------------
GEN_PATTERN
	PUSH	HL,DE,BC
	LD	D,0
.LP
	LD	A,B
	OR	C
	JR	Z,.DONE
	LD	(HL),D
	INC	D
	INC	HL
	DEC	BC
	JR	.LP
.DONE
	POP	BC,DE,HL
	RET

; ------------------------------------------------------
; FILL_FF: fill (HL) with 0xFF.
; In: HL = buffer, BC = length.
; ------------------------------------------------------
FILL_FF
	PUSH	HL,BC
.LP
	LD	A,B
	OR	C
	JR	Z,.DONE
	LD	A,0xFF
	LD	(HL),A
	INC	HL
	DEC	BC
	JR	.LP
.DONE
	POP	BC,HL
	RET

; ------------------------------------------------------
; CMP_PATTERN: compare (HL) against expected pattern (i & 0xFF).
; In: HL = buffer, BC = length.
; Out: CF=0 match, CF=1 mismatch with HL=offending addr,
;      D=expected byte, A=actual byte.
; ------------------------------------------------------
CMP_PATTERN
	LD	D,0
.LP
	LD	A,B
	OR	C
	JR	Z,.OK
	LD	A,(HL)
	CP	D
	JR	NZ,.MISS
	INC	D
	INC	HL
	DEC	BC
	JR	.LP
.OK
	OR	A
	RET
.MISS
	SCF
	RET


; ------------------------------------------------------
; PRINT_REG_DUMP: same format as NICINFO's [N5] line.
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


; ------- valid byte-mode packet-RAM address/length pairs -------
TEST_CASES
	DW 0x4000,16
	DW 0x4000,64
	DW 0x4000,256
	DW 0x4000,1536
	DW 0x4600,64
	DW 0x4600,256
	DW 0x4600,1536
	DW 0x5A00,256
	DW 0x5F00,256
	DW 0


; ------- messages -------
MSG_BANNER	DB "RTL8019AS NICRAM v",PACKAGE_VERSION,0
MSG_R0		DB "[R0] INIT ",0
MSG_OK		DB "OK",0
MSG_WRITE	DB "WRITE ADDR=",0
MSG_READ	DB "READ  ADDR=",0
MSG_LEN_EQ	DB " LEN=",0
MSG_REGS	DB "REGS ",0
MSG_RESULT_OK	DB "RESULT OK",0
MSG_RESULT_FAIL	DB "RESULT FAIL",0
MSG_E_RESET	DB "[E10] RESET timeout",0
MSG_E_WRITE	DB "[E11] DMA write timeout",0
MSG_E_READ	DB "[E12] DMA read timeout",0
MSG_E_MISMATCH	DB "[E13] RAM mismatch ",0
MSG_ADDR_EQ	DB "ADDR=",0
MSG_EXP_EQ	DB " EXP=",0
MSG_GOT_EQ	DB " GOT=",0
LINE_END	DB 13,10,0


	ENDMODULE


; -------- libraries (placed after MAIN code/data) --------
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"


; Root-scope marker at end of emitted image.
NICRAM_IMAGE_END

; -------- runtime BSS (no bytes emitted) --------
	MODULE MAIN

RAM_BUF		EQU NICRAM_IMAGE_END
DEC_BUF		EQU RAM_BUF + 1536	; 4 bytes
STAGE_NO	EQU DEC_BUF + 4		; 1 byte
CUR_SIZE	EQU STAGE_NO + 1	; 2 bytes
CUR_ADDR	EQU CUR_SIZE + 2	; 2 bytes
TEST_PTR	EQU CUR_ADDR + 2	; 2 bytes
MISS_ADDR	EQU TEST_PTR + 2	; 2 bytes
MISS_EXP	EQU MISS_ADDR + 2	; 1 byte
MISS_GOT	EQU MISS_EXP + 1	; 1 byte
NICRAM_BSS_END	EQU MISS_GOT + 1

	ENDMODULE

	END MAIN.START
