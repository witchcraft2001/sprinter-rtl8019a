; ======================================================
; RTL8019AS / DP8390 driver primitives for Sprinter DSS.
;
; All routines assume ISA.ISA_OPEN has been called: the ISA
; window is mapped into 0xC000..0xFFFF and chip registers are
; accessed as memory at RTL_BASE_A + offset (default 0xC300).
; Routines do NOT toggle the ISA window themselves -- callers
; manage open/close around the inner loops.
;
; Public API:
;   RTL.RESET            full NE2000-style reset.
;                          Out: CF=0 OK, CF=1 ISR.RST timeout.
;   RTL.PROBE_ID         read page-0 8019ID0/ID1.
;                          Out: CF=0 if both 'P','p'; CF=1 otherwise.
;                                A=0 if both match.
;                          Side effect: stores raw bytes in
;                          ID0_RAW, ID1_RAW.
;   RTL.SNAPSHOT_REGS    capture CR/ISR/DCR/RCR/TCR/IMR/PSTART/
;                        PSTOP/BNRY/CURR into REG_SNAPSHOT (10 bytes).
;   RTL.READ_PROM        read 32 bytes of PROM into (HL).
;                          Out: CF=0 OK, CF=1 RDC timeout.
;   RTL.DMA_READ         remote DMA read BC bytes from packet RAM
;                        addr DE into memory at HL.
;                          Out: CF=0 OK, CF=1 RDC timeout.
;   RTL.DMA_WRITE        remote DMA write BC bytes from memory at HL
;                        to packet RAM addr DE.
;                          Out: CF=0 OK, CF=1 RDC timeout.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_RTL8019
	DEFINE	_RTL8019

	INCLUDE "rtl8019.inc"
	INCLUDE "util.asm"

; Timeouts in arbitrary inner-loop units, calibrated empirically.
RTL_RESET_LOOPS		EQU 8000		; ~ ISR.RST poll budget
RTL_RDC_LOOPS		EQU 4000		; remote DMA complete budget

	MODULE RTL

; ------------------------------------------------------
; Full NE2000-style reset:
;   tmp = (RESET)
;   (RESET) = tmp                ; assert
;   delay 2 ms
;   tmp = (RESET)                ; clear
;   wait ISR.RST == 1, timeout
;   (ISR) = 0xFF
; Out: CF=0 OK, CF=1 timeout (ISR.RST never asserted).
; Trashes A,BC,HL.
; ------------------------------------------------------
RESET
	LD	A,(RTL_RESET_A)			; tmp = read reset port
	LD	(RTL_RESET_A),A			; write back -> assert (NE2000 convention)
	CALL	UTIL.DELAY_2MS
	LD	A,(RTL_RESET_A)			; read -> clear (also triggers MAME device_reset)
	; Wait for ISR.RST = 1
	LD	BC,RTL_RESET_LOOPS
.WAIT
	LD	A,(RTL_ISR_A)
	AND	ISR_RST
	JR	NZ,.OK
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.WAIT
	; Timeout
	SCF
	RET
.OK
	LD	A,0xFF
	LD	(RTL_ISR_A),A			; clear all ISR bits
	OR	A				; CF=0
	RET

; ------------------------------------------------------
; Read 8019ID0/8019ID1 from page 0 regs 0x0A/0x0B.
; Side effect: ID0_RAW, ID1_RAW updated with raw bytes.
; Out: CF=0 if (ID0_RAW=='P' && ID1_RAW=='p'), else CF=1.
;       A: 0 on match, non-zero otherwise.
; Trashes A.
; ------------------------------------------------------
PROBE_ID
	; Make sure CR is on page 0; STA so the chip is "running"
	; (any state works for these reads, but be explicit).
	LD	A,CR_PAGE0_START
	LD	(RTL_CR_A),A

	LD	A,(RTL_ID0_A)
	LD	(ID0_RAW),A
	CP	RTL_ID0_VAL
	JR	NZ,.MISS
	LD	A,(RTL_ID1_A)
	LD	(ID1_RAW),A
	CP	RTL_ID1_VAL
	JR	NZ,.MISS
	XOR	A			; A=0, CF=0
	RET
.MISS
	; If we left ID1 unread (mismatch on ID0), capture it now too
	; for diagnostic completeness.
	LD	A,(RTL_ID1_A)
	LD	(ID1_RAW),A
	OR	0xFF			; A != 0
	SCF
	RET

ID0_RAW		DB 0
ID1_RAW		DB 0

; ------------------------------------------------------
; Snapshot 10 useful registers into REG_SNAPSHOT in the same
; order the diagnostic line prints them:
;   [0] CR      page 0, offs 0x00
;   [1] ISR     page 0, offs 0x07
;   [2] DCR     page 2, offs 0x0E   (page-0 read of 0x0E = CNTR1)
;   [3] RCR     page 2, offs 0x0C   (page-0 read of 0x0C = RSR)
;   [4] TCR     page 2, offs 0x0D   (page-0 read of 0x0D = CNTR0)
;   [5] IMR     page 2, offs 0x0F   (page-0 read of 0x0F = CNTR2)
;   [6] PSTART  page 2, offs 0x01
;   [7] PSTOP   page 2, offs 0x02
;   [8] BNRY    page 0, offs 0x03
;   [9] CURR    page 1, offs 0x07
;
; Switches CR pages internally and leaves CR back on page 0
; with STA. Trashes A.
; ------------------------------------------------------
SNAPSHOT_REGS
	; -- page 0 reads --
	LD	A,CR_PAGE0_START
	LD	(RTL_CR_A),A
	LD	A,(RTL_CR_A)
	LD	(REG_SNAPSHOT+0),A
	LD	A,(RTL_ISR_A)
	LD	(REG_SNAPSHOT+1),A
	LD	A,(RTL_BNRY_A)
	LD	(REG_SNAPSHOT+8),A

	; -- page 1 read (CURR) --
	LD	A,CR_PAGE1_STOP
	LD	(RTL_CR_A),A
	LD	A,(RTL_CURR_A)
	LD	(REG_SNAPSHOT+9),A

	; -- page 2 reads (DCR/RCR/TCR/IMR/PSTART/PSTOP) --
	LD	A,CR_PAGE2_STOP
	LD	(RTL_CR_A),A
	LD	A,(RTL_DCR_A)
	LD	(REG_SNAPSHOT+2),A
	LD	A,(RTL_RCR_A)
	LD	(REG_SNAPSHOT+3),A
	LD	A,(RTL_TCR_A)
	LD	(REG_SNAPSHOT+4),A
	LD	A,(RTL_IMR_A)
	LD	(REG_SNAPSHOT+5),A
	LD	A,(RTL_PSTART_A)
	LD	(REG_SNAPSHOT+6),A
	LD	A,(RTL_PSTOP_A)
	LD	(REG_SNAPSHOT+7),A

	; Restore CR to page 0 + STA
	LD	A,CR_PAGE0_START
	LD	(RTL_CR_A),A
	RET

REG_SNAPSHOT	DS 10,0
REG_SNAPSHOT_LEN EQU 10

; ------------------------------------------------------
; Remote DMA read of BC bytes from packet-RAM address DE
; into memory at HL (host-side buffer).
; Out: CF=0 OK, CF=1 RDC timeout.
; Trashes A,BC,DE,HL.
; Pre: caller has done ISA_OPEN.
; ------------------------------------------------------
DMA_READ
	; Ensure abort/clear remote DMA, page 0
	LD	A,CR_PAGE0_START | CR_RD2	; 0x22 -> abort+complete, page 0, STA
	LD	(RTL_CR_A),A
	; Clear stale RDC if any
	LD	A,ISR_RDC
	LD	(RTL_ISR_A),A
	; Program byte count BC -> RBCR0/1
	LD	A,C
	LD	(RTL_RBCR0_A),A
	LD	A,B
	LD	(RTL_RBCR1_A),A
	; Program source address DE -> RSAR0/1
	LD	A,E
	LD	(RTL_RSAR0_A),A
	LD	A,D
	LD	(RTL_RSAR1_A),A
	; Issue remote read command
	LD	A,CR_DMA_READ			; 0x0A
	LD	(RTL_CR_A),A
	; Read BC bytes from data port into (HL)
.LOOP
	LD	A,(RTL_DATA_A)
	LD	(HL),A
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.LOOP
	; Wait for ISR.RDC
	LD	BC,RTL_RDC_LOOPS
.WRDC
	LD	A,(RTL_ISR_A)
	AND	ISR_RDC
	JR	NZ,.OK
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.WRDC
	SCF
	RET
.OK
	LD	A,ISR_RDC
	LD	(RTL_ISR_A),A			; clear RDC
	OR	A
	RET

; ------------------------------------------------------
; Read 32 bytes of PROM into buffer at HL.
;   Implemented as DMA_READ from address 0x0000, length 0x20.
; Out: CF=0 OK, CF=1 RDC timeout.
; ------------------------------------------------------
READ_PROM
	LD	BC,32
	LD	DE,0x0000
	JP	DMA_READ

; ------------------------------------------------------
; Remote DMA write of BC bytes from memory at HL into packet
; RAM address DE.
; Out: CF=0 OK, CF=1 RDC timeout.
; Trashes A,BC,DE,HL.
; Pre: caller has done ISA_OPEN.
; ------------------------------------------------------
DMA_WRITE
	; Abort/clear remote DMA, page 0, STA
	LD	A,CR_PAGE0_START
	LD	(RTL_CR_A),A
	; Clear stale RDC
	LD	A,ISR_RDC
	LD	(RTL_ISR_A),A
	; Program byte count BC -> RBCR0/1
	LD	A,C
	LD	(RTL_RBCR0_A),A
	LD	A,B
	LD	(RTL_RBCR1_A),A
	; Program target address DE -> RSAR0/1
	LD	A,E
	LD	(RTL_RSAR0_A),A
	LD	A,D
	LD	(RTL_RSAR1_A),A
	; Issue remote write command
	LD	A,CR_DMA_WRITE			; 0x12
	LD	(RTL_CR_A),A
	; Push BC bytes from (HL) to data port
.LOOP
	LD	A,(HL)
	LD	(RTL_DATA_A),A
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.LOOP
	; Wait RDC
	LD	BC,RTL_RDC_LOOPS
.WRDC
	LD	A,(RTL_ISR_A)
	AND	ISR_RDC
	JR	NZ,.OK
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.WRDC
	SCF
	RET
.OK
	LD	A,ISR_RDC
	LD	(RTL_ISR_A),A
	OR	A
	RET

	ENDMODULE
	ENDIF
