; ======================================================
; RTL8019AS / DP8390 register and constant definitions.
;
; ISA8 card on Sprinter, default I/O base 0x300.
; On Sprinter, ISA peripherals are memory-mapped into the
; 0xC000..0xFFFF window after ISA.ISA_OPEN, so all driver
; code accesses RTL8019AS registers as MEMORY locations,
; NOT as Z80 I/O ports. Constants below are memory addresses.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_RTL8019_INC
	DEFINE	_RTL8019_INC

	INCLUDE "isa.inc"		; brings in ISA_BASE_A

; -- I/O base on the ISA bus (jumper-selectable; MAME exposes
; 0x300/0x320/0x340/0x360). The corresponding memory address
; in the Sprinter ISA window is RTL_BASE_A.
RTL_BASE	EQU 0x300
RTL_BASE_A	EQU ISA_BASE_A + RTL_BASE	; 0xC300 by default

; -- Register window (page-selected via CR.PS) ---------------------
RTL_CR_A	EQU RTL_BASE_A + 0x00	; Command Register
RTL_DATA_A	EQU RTL_BASE_A + 0x10	; 8-bit remote DMA data port
RTL_RESET_A	EQU RTL_BASE_A + 0x1F	; Reset (write asserts, read clears)

; -- Page 0 register addresses (CR.PS = 00) ----------------------------
RTL_PSTART_A	EQU RTL_BASE_A + 0x01	; W: RX ring start page
RTL_PSTOP_A	EQU RTL_BASE_A + 0x02	; W: RX ring stop  page
RTL_BNRY_A	EQU RTL_BASE_A + 0x03	; R/W: RX boundary page
RTL_TPSR_A	EQU RTL_BASE_A + 0x04	; W: TX page start
RTL_TBCR0_A	EQU RTL_BASE_A + 0x05	; W: TX byte count low
RTL_TBCR1_A	EQU RTL_BASE_A + 0x06	; W: TX byte count high
RTL_ISR_A	EQU RTL_BASE_A + 0x07	; R/W: Interrupt Status (write-1-clear)
RTL_RSAR0_A	EQU RTL_BASE_A + 0x08	; W: Remote DMA start lo
RTL_RSAR1_A	EQU RTL_BASE_A + 0x09	; W: Remote DMA start hi
RTL_RBCR0_A	EQU RTL_BASE_A + 0x0A	; W: Remote DMA byte cnt lo / R: 8019ID0 'P'
RTL_RBCR1_A	EQU RTL_BASE_A + 0x0B	; W: Remote DMA byte cnt hi / R: 8019ID1 'p'
RTL_RCR_A	EQU RTL_BASE_A + 0x0C	; W: Receive Configuration
RTL_TCR_A	EQU RTL_BASE_A + 0x0D	; W: Transmit Configuration
RTL_DCR_A	EQU RTL_BASE_A + 0x0E	; W: Data Configuration
RTL_IMR_A	EQU RTL_BASE_A + 0x0F	; W: Interrupt Mask

; Page 0 ID-register aliases (read-only on RTL8019AS).
RTL_ID0_A	EQU RTL_RBCR0_A
RTL_ID1_A	EQU RTL_RBCR1_A

; -- Page 1 register addresses (CR.PS = 01) ----------------------------
RTL_PAR0_A	EQU RTL_BASE_A + 0x01
RTL_PAR1_A	EQU RTL_BASE_A + 0x02
RTL_PAR2_A	EQU RTL_BASE_A + 0x03
RTL_PAR3_A	EQU RTL_BASE_A + 0x04
RTL_PAR4_A	EQU RTL_BASE_A + 0x05
RTL_PAR5_A	EQU RTL_BASE_A + 0x06
RTL_CURR_A	EQU RTL_BASE_A + 0x07
RTL_MAR0_A	EQU RTL_BASE_A + 0x08
RTL_MAR7_A	EQU RTL_BASE_A + 0x0F

; -- CR (Command Register) bits ------------------------------------
CR_STP		EQU 0x01	; Stop
CR_STA		EQU 0x02	; Start
CR_TXP		EQU 0x04	; Transmit Packet
CR_RD0		EQU 0x08	; Remote DMA command bit 0
CR_RD1		EQU 0x10	; Remote DMA command bit 1
CR_RD2		EQU 0x20	; Remote DMA command bit 2
CR_PS0		EQU 0x40	; Page select bit 0
CR_PS1		EQU 0x80	; Page select bit 1

; Useful CR composites (page bits + DMA + start/stop):
CR_PAGE0_STOP	EQU 0x21	; page 0, stop, DMA abort
CR_PAGE0_START	EQU 0x22	; page 0, start, DMA abort
CR_PAGE1_STOP	EQU 0x61	; page 1, stop, DMA abort
CR_PAGE1_START	EQU 0x62	; page 1, start, DMA abort
CR_PAGE2_STOP	EQU 0xA1	; page 2, stop, DMA abort

; Remote DMA commands (low 6 bits, OR with page select bits if needed).
; All include STA so the chip stays running.
CR_DMA_READ	EQU 0x0A	; remote read  + STA
CR_DMA_WRITE	EQU 0x12	; remote write + STA
CR_DMA_SEND	EQU 0x1A	; send packet  + STA
CR_DMA_ABORT	EQU 0x22	; abort/complete remote DMA + STA

; -- ISR (Interrupt Status Register) bits --------------------------
ISR_PRX		EQU 0x01	; Packet received OK
ISR_PTX		EQU 0x02	; Packet transmitted OK
ISR_RXE		EQU 0x04	; Receive error
ISR_TXE		EQU 0x08	; Transmit error
ISR_OVW		EQU 0x10	; Overwrite warning
ISR_CNT		EQU 0x20	; Counter overflow
ISR_RDC		EQU 0x40	; Remote DMA complete
ISR_RST		EQU 0x80	; Reset status (set after reset)

; -- DCR (Data Configuration Register) -----------------------------
; WTS=0 mandatory for ISA8; mandatory init value combines WTS=0,
; LS=1 (normal, not loopback) and FIFO threshold = 8 bytes.
DCR_INIT	EQU 0x48
; Loopback testing: same as DCR_INIT but with LS=0 (bit 3 cleared).
; MAME's LOOPBACK macro requires DCR.LS=0 AND TCR.LB!=0.
DCR_LOOPBACK	EQU 0x40

; -- RCR (Receive Configuration Register) bits ---------------------
RCR_SEP		EQU 0x01	; Save errored packets
RCR_AR		EQU 0x02	; Accept runt packets
RCR_AB		EQU 0x04	; Accept broadcast
RCR_AM		EQU 0x08	; Accept multicast
RCR_PRO		EQU 0x10	; Promiscuous physical
RCR_MON		EQU 0x20	; Monitor mode (no RX into ring)

RCR_NORMAL	EQU RCR_AB	; broadcast accept, others off

; -- TCR (Transmit Configuration Register) / loopback modes --------
TCR_NORMAL	EQU 0x00	; normal TX, FCS appended, no loopback
TCR_LB_INTERNAL	EQU 0x02	; mode 1: internal MAC loopback
TCR_LB_EXT_NIC	EQU 0x04	; mode 2: external loopback (NIC)
TCR_LB_EXT_MAU	EQU 0x06	; mode 3: external loopback (MAU)

; -- RTL8019AS ID --------------------------------------------------
; Page 0 register 0x0A reads as 0x50 ('P'); 0x0B reads as 0x70 ('p').
; Confirmed against Realtek RTL8019AS datasheet and MAME dp8390.cpp.
RTL_ID0_VAL	EQU 0x50
RTL_ID1_VAL	EQU 0x70

; -- Packet RAM layout (NE2000-compatible) -------------------------
; Internal packet RAM occupies pages 0x40..0x7F (16 KiB at 0x4000..0x7FFF).
RTL_TPSR_INIT	EQU 0x40		; TX buffer start page
RTL_PSTART_INIT	EQU 0x46		; RX ring start page (TX uses 6 pages)
RTL_PSTOP_INIT	EQU 0x80		; RX ring end (exclusive)
RTL_BNRY_INIT	EQU 0x46		; initial RX boundary
RTL_CURR_INIT	EQU 0x47		; initial CURR (BNRY+1, marks empty ring)

; -- Ethernet frame size limits ------------------------------------
ETH_FRAME_MIN	EQU 60			; pad TX to this many bytes (no FCS)
ETH_FRAME_MAX	EQU 1518		; max frame including header (no FCS)

; -- DSS exit codes (project convention) ---------------------------
EX_OK		EQU 0
EX_USAGE	EQU 1
EX_NO_HW	EQU 2
EX_NIC_ERR	EQU 3
EX_CFG_ERR	EQU 4

	ENDIF
