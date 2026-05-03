; ======================================================
; Sprinter ISA bus constants. Code lives in src/lib/isa.asm.
; Split out so consumers can pull constants without dragging
; ISA module code.
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_ISA_INC
	DEFINE	_ISA_INC

PORT_ISA	EQU 0x9FBD
PORT_SYSTEM	EQU 0x1FFD

ISA_BASE_A	EQU 0xC000		; ISA window base in Sprinter memory map

; --- PORT_ISA bits
ISA_A14		EQU 0x01
ISA_A15		EQU 0x02
ISA_A16		EQU 0x04
ISA_A17		EQU 0x08
ISA_A18		EQU 0x10
ISA_A19		EQU 0x20
ISA_AEN		EQU 0x40
ISA_RST		EQU 0x80

	ENDIF
