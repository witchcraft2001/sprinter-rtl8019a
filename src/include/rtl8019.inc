; ======================================================
; RTL8019AS / DP8390 register and constant definitions.
; ISA8 card on Sprinter, default I/O base 0x300.
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_RTL8019_INC
	DEFINE	_RTL8019_INC

; -- I/O base -------------------------------------------------------
; Default base is 0x300; alternative jumpers in MAME: 0x320/0x340/0x360.
RTL_BASE		EQU 0x300

; -- Port offsets within the 0x20-byte window ----------------------
RTL_CR			EQU RTL_BASE+0x00	; Command Register, present on every page
RTL_DATA		EQU RTL_BASE+0x10	; 8-bit remote DMA data port
RTL_RESET		EQU RTL_BASE+0x1F	; Reset port (write to assert, read to clear)

; -- Page 0 registers ----------------------------------------------
; CR.PS = 00 (CR bits 7..6).
RTL_PSTART		EQU RTL_BASE+0x01	; RX ring start page  (W) / CLDA0 (R)
RTL_PSTOP		EQU RTL_BASE+0x02	; RX ring stop  page  (W) / CLDA1 (R)
RTL_BNRY		EQU RTL_BASE+0x03	; RX boundary page    (R/W)
RTL_TPSR		EQU RTL_BASE+0x04	; TX page start       (W) / TSR  (R)
RTL_TBCR0		EQU RTL_BASE+0x05	; TX byte count low   (W) / NCR  (R)
RTL_TBCR1		EQU RTL_BASE+0x06	; TX byte count high  (W) / FIFO (R)
RTL_ISR			EQU RTL_BASE+0x07	; Interrupt Status    (R/W, write-1-to-clear)
RTL_RSAR0		EQU RTL_BASE+0x08	; Remote DMA start lo (W) / CRDA0 (R)
RTL_RSAR1		EQU RTL_BASE+0x09	; Remote DMA start hi (W) / CRDA1 (R)
RTL_RBCR0		EQU RTL_BASE+0x0A	; Remote DMA byte cnt lo (W) / 8019ID0 'P' (R, page 0)
RTL_RBCR1		EQU RTL_BASE+0x0B	; Remote DMA byte cnt hi (W) / 8019ID1 'p' (R, page 0)
RTL_RCR			EQU RTL_BASE+0x0C	; Receive Configuration (W) / RSR (R)
RTL_TCR			EQU RTL_BASE+0x0D	; Transmit Configuration (W) / CNTR0 (R)
RTL_DCR			EQU RTL_BASE+0x0E	; Data Configuration    (W) / CNTR1 (R)
RTL_IMR			EQU RTL_BASE+0x0F	; Interrupt Mask        (W) / CNTR2 (R)

; -- Page 1 registers ----------------------------------------------
; CR.PS = 01.
RTL_PAR0		EQU RTL_BASE+0x01	; MAC byte 0
RTL_PAR1		EQU RTL_BASE+0x02
RTL_PAR2		EQU RTL_BASE+0x03
RTL_PAR3		EQU RTL_BASE+0x04
RTL_PAR4		EQU RTL_BASE+0x05
RTL_PAR5		EQU RTL_BASE+0x06
RTL_CURR		EQU RTL_BASE+0x07	; Current RX page
RTL_MAR0		EQU RTL_BASE+0x08	; Multicast filter 0..7
RTL_MAR7		EQU RTL_BASE+0x0F

; -- CR (Command Register) bits ------------------------------------
CR_STP			EQU 0x01		; Stop
CR_STA			EQU 0x02		; Start
CR_TXP			EQU 0x04		; Transmit Packet
CR_RD0			EQU 0x08		; Remote DMA command bit 0
CR_RD1			EQU 0x10		; Remote DMA command bit 1
CR_RD2			EQU 0x20		; Remote DMA command bit 2
CR_PS0			EQU 0x40		; Page select bit 0
CR_PS1			EQU 0x80		; Page select bit 1

; Useful CR composites (page bits + DMA + start/stop):
CR_PAGE0_STOP		EQU 0x21	; page 0, stop, DMA abort
CR_PAGE0_START		EQU 0x22	; page 0, start, DMA abort
CR_PAGE1_STOP		EQU 0x61	; page 1, stop, DMA abort
CR_PAGE1_START		EQU 0x62	; page 1, start, DMA abort
CR_PAGE2_STOP		EQU 0xA1	; page 2, stop, DMA abort

; Remote DMA commands (low 6 bits, OR with page bits as needed).
; Each value already has STA=1 so the chip stays running.
CR_DMA_READ		EQU 0x0A	; remote read  + STA
CR_DMA_WRITE		EQU 0x12	; remote write + STA
CR_DMA_SEND		EQU 0x1A	; send packet  + STA
CR_DMA_ABORT		EQU 0x22	; abort/complete remote DMA + STA

; -- ISR (Interrupt Status Register) bits --------------------------
ISR_PRX			EQU 0x01		; Packet received OK
ISR_PTX			EQU 0x02		; Packet transmitted OK
ISR_RXE			EQU 0x04		; Receive error
ISR_TXE			EQU 0x08		; Transmit error
ISR_OVW			EQU 0x10		; Overwrite warning
ISR_CNT			EQU 0x20		; Counter overflow
ISR_RDC			EQU 0x40		; Remote DMA complete
ISR_RST			EQU 0x80		; Reset status (set after reset)

; -- DCR (Data Configuration Register) -----------------------------
; WTS=0 mandatory for ISA8; recommended init value combines WTS=0,
; LS=1 (normal, not loopback) and FIFO threshold = 8 bytes.
DCR_INIT		EQU 0x48

; -- RCR (Receive Configuration Register) bits ---------------------
RCR_SEP			EQU 0x01		; Save errored packets
RCR_AR			EQU 0x02		; Accept runt packets
RCR_AB			EQU 0x04		; Accept broadcast
RCR_AM			EQU 0x08		; Accept multicast
RCR_PRO			EQU 0x10		; Promiscuous physical
RCR_MON			EQU 0x20		; Monitor mode (no RX into ring)

RCR_NORMAL		EQU RCR_AB		; broadcast accept, others off

; -- TCR (Transmit Configuration Register) bits / loopback modes ---
TCR_NORMAL		EQU 0x00		; normal TX, FCS appended, no loopback
TCR_LB_INTERNAL		EQU 0x02		; mode 1: internal MAC loopback (TCR.LB = 01)
TCR_LB_EXT_NIC		EQU 0x04		; mode 2: external loopback (NIC)
TCR_LB_EXT_MAU		EQU 0x06		; mode 3: external loopback (MAU)

; -- RTL8019AS ID --------------------------------------------------
; Page 0 register 0x0A reads as 0x50 ('P'); 0x0B reads as 0x70 ('p').
; Confirmed against Realtek RTL8019AS datasheet and MAME dp8390.cpp.
RTL_ID0_VAL		EQU 0x50
RTL_ID1_VAL		EQU 0x70

; -- Packet RAM layout (NE2000-compatible) -------------------------
; Internal packet RAM occupies pages 0x40..0x7F (16 KiB at 0x4000..0x7FFF).
RTL_TPSR_INIT		EQU 0x40		; TX buffer start page
RTL_PSTART_INIT		EQU 0x46		; RX ring start page (TX uses 6 pages)
RTL_PSTOP_INIT		EQU 0x80		; RX ring end (exclusive)
RTL_BNRY_INIT		EQU 0x46		; initial RX boundary
RTL_CURR_INIT		EQU 0x47		; initial CURR (BNRY+1, marks empty ring)

; -- Ethernet frame size limits ------------------------------------
ETH_FRAME_MIN		EQU 60			; pad TX to this many bytes (no FCS)
ETH_FRAME_MAX		EQU 1518		; max frame including header (no FCS)

; -- DSS exit codes (project convention) ---------------------------
EX_OK			EQU 0
EX_USAGE		EQU 1
EX_NO_HW		EQU 2
EX_NIC_ERR		EQU 3
EX_CFG_ERR		EQU 4

	ENDIF
