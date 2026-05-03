; ======================================================
; Sprinter ISA bus access library.
; ISA peripherals are memory-mapped into 0xC000..0xFFFF after
; ISA_OPEN; restored by ISA_CLOSE. The selected ISA slot is
; stored as the self-modifying byte ISA_SLOT (0=ISA0, 1=ISA1).
; Adapted from sprinter_wifi/network/src/lib/isa.asm
; (Roman Boykov, BSD 3-Clause).
; ======================================================

	IFNDEF	_ISA
	DEFINE	_ISA

	INCLUDE "sprinter.inc"
	INCLUDE "isa.inc"

	MODULE	ISA

; ------------------------------------------------------
; Open access to ISA ports as memory.
; Uses ISA_SLOT (self-modifying byte): 0 = ISA0, 1 = ISA1.
; All RTL8019AS register accesses (port window + DMA data port +
; reset port) fit within the 14-bit memory window, so PORT_ISA
; stays at 0 (A14..A19 = 0, AEN = 0).
; Saves MMU page 3 in SAVE_MMU3 for ISA_CLOSE to restore.
; ------------------------------------------------------
ISA_OPEN
	PUSH	AF,BC
	LD	BC,PAGE3
	IN	A,(C)
	LD	(SAVE_MMU3),A
	LD	BC,PORT_SYSTEM
	LD	A,0x11
	OUT	(C),A
ISA_SLOT EQU $+1
	LD	A,0x00
	SLA	A
	OR	A,0xD4		; 0xD4 = ISA1 mem, 0xD6 = ISA2 mem
	LD	BC,PAGE3
	OUT	(C),A
	LD	BC,PORT_ISA
	XOR	A
	OUT	(C),A
	POP	BC,AF
	RET

; ------------------------------------------------------
; Close access to ISA ports.
; Restores MMU page 3 from SAVE_MMU3.
; ------------------------------------------------------
ISA_CLOSE
	PUSH	AF,BC
	LD	A,0x01
	LD	BC,PORT_SYSTEM
	OUT	(C),A
	LD	BC,PAGE3
	LD	A,(SAVE_MMU3)
	OUT	(C),A
	POP	BC,AF
	RET

SAVE_MMU3	DB 0

	ENDMODULE
	ENDIF
