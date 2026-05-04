; ======================================================
; RTL8019AS / DP8390 driver primitives for Sprinter DSS.
;
; All routines assume ISA.ISA_OPEN has been called: the ISA
; window is mapped into 0xC000..0xFFFF and chip registers are
; accessed as memory at RTL_BASE_A + offset (default 0xC300).
; Routines do NOT toggle the ISA window themselves -- callers
; manage open/close around the inner loops.
;
; Public API. Low-level chip primitives below are always
; assembled. High-level helpers further down are guarded by
; explicit `IFDEF USE_RTL_<name>` flags -- caller defines
; `USE_RTL_INIT_NORMAL EQU 1` (and similar) BEFORE
; `INCLUDE "rtl8019.asm"` to pull in only what it uses.
; This keeps RAM usage tight on the 64K Z80 target.
;
; Low-level chip primitives:
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
; High-level helpers (post-refactor; use these in new code):
;   RTL.INIT_NORMAL      In: HL = pointer to 6-byte MAC.
;                            A = RCR value (e.g. RCR_AB or 0).
;                        Full chip init: DCR=0x48, TCR=0, RCR=A,
;                        packet RAM layout, MAC, MAR=0, CR=0x22.
;   RTL.INIT_LOOPBACK    In: HL = MAC ptr. DCR=0x40, TCR=0x02 for
;                        internal MAC loopback (NICLB).
;   RTL.SEND_FRAME       In: HL = source buffer in DSS RAM.
;                            BC = byte count.
;                        DMA_WRITE -> TBCR -> CR.TXP -> wait PTX.
;                          Out: CF=0 OK, CF=1 DMA or PTX timeout.
;   RTL.WAIT_PTX         poll ISR.PTX with timeout. CF=0 OK, CF=1
;                        timeout. ISR.PTX cleared on success.
;   RTL.RING_HAS_PACKET  ZF=1 if RX ring is empty (BNRY+1==CURR),
;                        ZF=0 if a packet is queued. Trashes A,B,C.
;   RTL.READ_PACKET      In: HL = header buffer (4 bytes).
;                            DE = body buffer.
;                            BC = max body length.
;                        Reads 4-byte RX header at (BNRY+1)<<8 then
;                        body at +4. Auto-advances BNRY past this
;                        packet (with PSTOP wrap).
;                          Out: CF=0 OK, BC = body length read.
;                                CF=1 DMA error.
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


; ======================================================
; High-level helpers. Each block is guarded by an explicit
; USE_RTL_<name> symbol so an .EXE only emits the bytes it
; references -- caller defines `USE_RTL_INIT_NORMAL EQU 1`
; (and similar) BEFORE the `INCLUDE "rtl8019.asm"` line.
; This keeps RAM usage tight on the 64K Z80 target.
;
; Dependency rule: if you DEFINE USE_RTL_SEND_FRAME, also
; DEFINE USE_RTL_WAIT_PTX (SEND_FRAME tail-calls WAIT_PTX).
; ======================================================

PTX_LOOPS	EQU 16000

; ------------------------------------------------------
; INIT_NORMAL: full chip init for normal TX/RX.
;   In:  HL = pointer to 6-byte MAC for PAR0..5.
;        A  = RCR value to load (e.g. RCR_AB for broadcast,
;             0 for physical-only).
;   Side effects: TCR=0, DCR=DCR_INIT, packet RAM layout
;        defaults (TPSR/PSTART/PSTOP/BNRY/CURR), MAR0..7=0,
;        ISR cleared, IMR=0, CR=0x22 on exit.
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
	IFDEF USE_RTL_INIT_NORMAL
INIT_NORMAL
	; Save RCR value and MAC pointer for later use.
	LD	(.RCR_VALUE),A
	PUSH	HL
	; Page 0 stop, abort.
	LD	A,CR_PAGE0_STOP
	LD	(RTL_CR_A),A
	LD	A,DCR_INIT
	LD	(RTL_DCR_A),A
	XOR	A
	LD	(RTL_RBCR0_A),A
	LD	(RTL_RBCR1_A),A
	LD	A,(.RCR_VALUE)
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
	; Page 1: PAR + CURR + MAR.
	LD	A,CR_PAGE1_STOP
	LD	(RTL_CR_A),A
	POP	HL
	LD	DE,RTL_PAR0_A
	LD	BC,6
	LDIR
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
	; Back to page 0 START.
	LD	A,CR_PAGE0_START
	LD	(RTL_CR_A),A
	RET
.RCR_VALUE	DB 0
	ENDIF


; ------------------------------------------------------
; INIT_LOOPBACK: chip init for internal MAC loopback test.
;   DCR=0x40 (LS=0 enables loopback in MAME's macro), TCR=0x02
;   (internal MAC loopback), RCR=RCR_AB so broadcast frames can
;   be routed back via recv() in the patched dp8390.
;   In: HL = MAC pointer.
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
	IFDEF USE_RTL_INIT_LOOPBACK
INIT_LOOPBACK
	PUSH	HL
	LD	A,CR_PAGE0_STOP
	LD	(RTL_CR_A),A
	LD	A,DCR_LOOPBACK
	LD	(RTL_DCR_A),A
	XOR	A
	LD	(RTL_RBCR0_A),A
	LD	(RTL_RBCR1_A),A
	LD	A,RCR_AB
	LD	(RTL_RCR_A),A
	LD	A,TCR_LB_INTERNAL
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
	POP	HL
	LD	DE,RTL_PAR0_A
	LD	BC,6
	LDIR
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
	ENDIF


; ------------------------------------------------------
; WAIT_PTX: poll ISR.PTX. CF=0 OK (PTX cleared), CF=1 timeout.
; Trashes A,BC.
; ------------------------------------------------------
	IFDEF USE_RTL_WAIT_PTX
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
	ENDIF


; ------------------------------------------------------
; SEND_FRAME: DMA-write BC bytes from (HL) to packet RAM 0x4000,
; load TBCR=BC, trigger TX, wait PTX.
;   In:  HL = source buffer, BC = length.
;   Out: CF=0 OK, CF=1 DMA write or PTX timeout.
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
	IFDEF USE_RTL_SEND_FRAME
SEND_FRAME
	LD	(.LEN),BC
	LD	DE,0x4000
	CALL	DMA_WRITE
	RET	C
	LD	BC,(.LEN)
	LD	A,C
	LD	(RTL_TBCR0_A),A
	LD	A,B
	LD	(RTL_TBCR1_A),A
	LD	A,CR_PAGE0_START | CR_TXP
	LD	(RTL_CR_A),A
	JP	WAIT_PTX
.LEN	DW 0
	ENDIF


; ------------------------------------------------------
; RING_HAS_PACKET: ZF=1 if RX ring is empty (BNRY+1 wrap == CURR),
; ZF=0 otherwise. Switches CR briefly to page 1 to read CURR
; (with STA, so the chip keeps running) then restores page 0 STA.
; Trashes A, B, C.
; ------------------------------------------------------
	IFDEF USE_RTL_RING_HAS_PACKET
RING_HAS_PACKET
	LD	A,(RTL_BNRY_A)
	INC	A
	CP	RTL_PSTOP_INIT
	JR	C,.NW
	LD	A,RTL_PSTART_INIT
.NW
	LD	B,A
	LD	A,CR_PAGE1_START
	LD	(RTL_CR_A),A
	LD	A,(RTL_CURR_A)
	LD	C,A
	LD	A,CR_PAGE0_START
	LD	(RTL_CR_A),A
	LD	A,B
	CP	C
	RET
	ENDIF


; ------------------------------------------------------
; READ_PACKET: read 4-byte RX header at (BNRY+1)<<8 then body
; bytes at offset +4. Auto-advances BNRY = header.next - 1
; with PSTART wrap.
;   In:  HL = header buffer ptr (4 bytes).
;        DE = body buffer ptr.
;        BC = max body length to read.
;   Out: CF=0 OK; BC = actual body length read.
;        CF=1 DMA timeout.
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
	IFDEF USE_RTL_READ_PACKET
READ_PACKET
	LD	(.HDR_PTR),HL
	LD	(.BODY_PTR),DE
	LD	(.MAX_LEN),BC
	; Compute hdr_addr = (BNRY+1)<<8 with PSTOP wrap.
	LD	A,(RTL_BNRY_A)
	INC	A
	CP	RTL_PSTOP_INIT
	JR	C,.NW
	LD	A,RTL_PSTART_INIT
.NW
	LD	D,A
	LD	E,0
	LD	(.PKT_ADDR),DE
	; Read 4-byte header into HDR_PTR.
	LD	HL,(.HDR_PTR)
	LD	BC,4
	CALL	DMA_READ
	RET	C
	; body_len_candidate = (hdr.len) - 4
	LD	HL,(.HDR_PTR)
	INC	HL
	INC	HL			; HL -> hdr[2] = len_lo
	LD	A,(HL)
	LD	C,A
	INC	HL
	LD	A,(HL)
	LD	B,A
	; BC = hdr.len; subtract 4 -> HL.
	LD	H,B
	LD	L,C
	LD	BC,4
	OR	A
	SBC	HL,BC
	; Cap at MAX_LEN.
	LD	BC,(.MAX_LEN)
	LD	A,H
	CP	B
	JR	C,.LEN_OK
	JR	NZ,.LEN_CAP
	LD	A,L
	CP	C
	JR	C,.LEN_OK
.LEN_CAP
	LD	H,B
	LD	L,C
.LEN_OK
	LD	(.BODY_LEN),HL
	; Read body.
	LD	DE,(.PKT_ADDR)
	INC	DE
	INC	DE
	INC	DE
	INC	DE
	LD	HL,(.BODY_PTR)
	LD	BC,(.BODY_LEN)
	CALL	DMA_READ
	RET	C
	; Advance BNRY = hdr.next - 1, wrap PSTART -> PSTOP-1.
	LD	HL,(.HDR_PTR)
	INC	HL			; hdr[1] = next
	LD	A,(HL)
	DEC	A
	CP	RTL_PSTART_INIT
	JR	NC,.OK_BNRY
	LD	A,RTL_PSTOP_INIT - 1
.OK_BNRY
	LD	(RTL_BNRY_A),A
	; Return body length in BC.
	LD	BC,(.BODY_LEN)
	OR	A
	RET
.HDR_PTR	DW 0
.BODY_PTR	DW 0
.MAX_LEN	DW 0
.PKT_ADDR	DW 0
.BODY_LEN	DW 0
	ENDIF


	ENDMODULE
	ENDIF
