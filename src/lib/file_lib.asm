; ======================================================
; file_lib - shared file helpers for DSS utilities.
;
; Provides FILE.OPEN_OUTPUT: probe-or-prompt overwrite of
; a target file.  Works around the DSS_CREATE_OVERWRITE
; quirk that the syscall does NOT return an error and does
; NOT truncate when the file already exists; using it as an
; "exists?" probe silently corrupts data.
;
; Usage:
;   DEFINE USE_FILE
;   INCLUDE "file_lib.asm"
;   ...
;   LD  HL,(OUTPUT_PTR)     ; ASCIIZ filename
;   LD  A,(FORCE_FLAG)      ; 0 = prompt, !=0 = silent
;   CALL @FILE.OPEN_OUTPUT
;   ; CF=0 -> A = file handle
;   ; CF=1 -> user declined / I/O error
;
; Requires: @ISA.ISA_CLOSE / @ISA.ISA_OPEN (for the
; keyboard syscall that runs while the ISA window is open).
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_FILE
	DEFINE	_FILE

	IFDEF USE_FILE

	INCLUDE "dss.inc"

	MODULE FILE

; ------------------------------------------------------
; OPEN_OUTPUT
;   In:  HL = ASCIIZ filename, A = force flag
;   Out: CF=0 -> A = handle (FA_ARCHIVE, write)
;        CF=1 -> declined / error
; ------------------------------------------------------
OPEN_OUTPUT
	LD	(.FORCE),A
	LD	(.NAME_PTR),HL
	; Probe existence: read-only OPEN.  CREATE_OVERWRITE
	; cannot be used here -- it silently succeeds on an
	; existing file without truncating.
	LD	A,FA_READONLY
	LD	C,DSS_OPEN_FILE
	RST	DSS
	JR	C,.CREATE_FRESH		; no such file -> create
	; File exists: close the probe handle and decide.
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	LD	A,(.FORCE)
	OR	A
	JR	NZ,.DELETE
	; Prompt user.
	LD	HL,MSG_PRE
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,(.NAME_PTR)
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,MSG_POST
	LD	C,DSS_PCHARS
	RST	DSS
	CALL	WAIT_YES_NO
	JR	C,.USER_NO
.DELETE
	LD	HL,(.NAME_PTR)
	LD	C,DSS_DELETE
	RST	DSS
	; Ignore delete result (file may have race-disappeared).
.CREATE_FRESH
	LD	HL,(.NAME_PTR)
	LD	A,FA_ARCHIVE
	LD	C,DSS_CREATE_OVERWRITE
	RST	DSS
	RET				; CF reflects CREATE result
.USER_NO
	LD	HL,MSG_NO
	LD	C,DSS_PCHARS
	RST	DSS
	SCF
	RET

.NAME_PTR	DW 0
.FORCE		DB 0


; ------------------------------------------------------
; WAIT_YES_NO: clear keyboard buffer, block on a fresh
; key, accept Y/y -> CF=0; any other key -> CF=1.
; Closes the ISA window around the DSS call so the
; keyboard syscall can use page 3 freely.  Echoes the
; typed char + CRLF.
; ------------------------------------------------------
WAIT_YES_NO
	CALL	@ISA.ISA_CLOSE
	LD	B,DSS_WAITKEY		; subfunction: block until key
	LD	C,DSS_K_CLEAR		; clear buffer first
	RST	DSS
	; A = ASCII of the fresh key.
	PUSH	AF
	CALL	@ISA.ISA_OPEN
	POP	AF
	; Echo the typed character followed by CRLF.
	PUSH	AF
	LD	C,DSS_PUTCHAR
	RST	DSS
	LD	A,13
	LD	C,DSS_PUTCHAR
	RST	DSS
	LD	A,10
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	AF
	CP	'Y'
	RET	Z
	CP	'y'
	RET	Z
	SCF
	RET


MSG_PRE		DB "Local file '",0
MSG_POST	DB "' exists. Overwrite [Y/N]? ",0
MSG_NO		DB "Aborted by user.",13,10,0

	ENDMODULE

	ENDIF	; USE_FILE
	ENDIF	; _FILE
