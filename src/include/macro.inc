; ======================================================
; Macros for Sprinter RTL8019AS network kit utilities
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_MACRO
	DEFINE	_MACRO

	; Print ASCIIZ string at HL to screen (DSS_PCHARS).
	MACRO 	PRINT_HL
	LD      C,DSS_PCHARS
	RST     DSS
	ENDM

	; Print ASCIIZ string at HL, then CR/LF.
	MACRO 	PRINTLN_HL
	PRINT_HL
	LD	HL,LINE_END
	PRINT_HL
	ENDM

	; Print ASCIIZ string by label.
	MACRO 	PRINT	data
	LD	HL,data
	PRINT_HL
	ENDM

	; Print ASCIIZ string by label, then CR/LF.
	MACRO 	PRINTLN	data
	LD	HL,data
	PRINTLN_HL
	ENDM

	; Execute a DSS function (8-bit code in C, or 16-bit in BC).
	MACRO	DSS_EXEC	func
		IF func>255
			LD	BC,func
		ELSE
			LD	C,func
		ENDIF
		RST	DSS
	ENDM

	; Exit to DSS with return code in B.
	MACRO	DSS_RETURN	code
		LD	B,code
		DSS_EXEC DSS_EXIT
	ENDM

	ENDIF
