; ======================================================
; file_lib - shared file helpers for DSS utilities.
;
; Provides FILE.OPEN_OUTPUT: probe-or-prompt overwrite of
; a target file.  Works around the DSS_CREATE_OVERWRITE
; quirk that the syscall does NOT return an error and does
; NOT truncate when the file already exists; using it as an
; "exists?" probe silently corrupts data.
;
; Path support: when the filename contains '/' or '\\',
; OPEN_OUTPUT splits it into directory + basename, CHDIRs
; into the directory, runs the existing probe / create
; flow against the basename, then restores the original
; CWD.  Both relative ("test\file.zip") and absolute
; ("C:\foo\file.zip") paths work.  CHDIR failure is
; surfaced as "[E] directory not found".
;
; Usage:
;   DEFINE USE_FILE
;   INCLUDE "file_lib.asm"
;   ...
;   LD  HL,(OUTPUT_PTR)     ; ASCIIZ filename, optional path
;   LD  A,(FORCE_FLAG)      ; 0 = prompt, !=0 = silent
;   CALL @FILE.OPEN_OUTPUT
;   ; CF=0 -> A = file handle
;   ; CF=1 -> user declined / I/O error / dir missing
;
; Requires: @ISA.ISA_CLOSE / @ISA.ISA_OPEN (for the
; keyboard syscall that runs while the ISA window is open).
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_FILE
	DEFINE	_FILE

	IFDEF USE_FILE

	INCLUDE "memmap.inc"
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
	LD	(.FULL_PTR),HL
	LD	(.NAME_PTR),HL		; updated to basename if path is split
	XOR	A
	LD	(.HAS_DIR),A

	; Save current dir so we can restore on exit.  DSS_CURDIR
	; copies the current path to (HL); 128 bytes is comfortably
	; more than DSS path limits.
	LD	HL,FILE_SAVED_CWD
	LD	C,DSS_CURDIR
	RST	DSS

	; Find last '/' or '\\' in the supplied name.  DE = pointer
	; to that separator (0 if no path).
	LD	HL,(.FULL_PTR)
	LD	DE,0
.SCAN
	LD	A,(HL)
	OR	A
	JR	Z,.SCAN_END
	CP	'/'
	JR	Z,.HIT
	CP	0x5C			; backslash
	JR	NZ,.SCAN_NEXT
.HIT
	LD	D,H
	LD	E,L
.SCAN_NEXT
	INC	HL
	JR	.SCAN
.SCAN_END
	LD	A,D
	OR	E
	JP	Z,.NO_PATH

	; --- We have a path.  Copy [name..separator-1] into
	; FILE_DIR_BUF, null-terminate. ---
	LD	HL,(.FULL_PTR)
	LD	BC,FILE_DIR_BUF
.CP_DIR
	LD	A,L
	CP	E
	JR	NZ,.CP_BYTE
	LD	A,H
	CP	D
	JR	Z,.CP_END
.CP_BYTE
	LD	A,(HL)
	LD	(BC),A
	INC	HL
	INC	BC
	JR	.CP_DIR
.CP_END
	XOR	A
	LD	(BC),A

	; If the dir part is empty (separator was the very first
	; character, e.g. "\file.zip"), substitute "\" so CHDIR
	; targets the volume root.
	LD	HL,FILE_DIR_BUF
	LD	A,(HL)
	OR	A
	JR	NZ,.CHDIR_GO
	LD	(HL),0x5C
	INC	HL
	LD	(HL),0
.CHDIR_GO
	; DSS calls may clobber DE/HL; preserve the separator
	; pointer (DE) across the syscall so .CHDIR_OK below can
	; resolve the basename.
	LD	HL,FILE_DIR_BUF
	PUSH	DE
	LD	C,DSS_CHDIR
	RST	DSS
	POP	DE
	JR	NC,.CHDIR_OK
	; CHDIR failed -- print "[E] directory not found: <dir>".
	; CWD wasn't changed, no restore needed.
	LD	HL,MSG_E_DIR_PRE
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,FILE_DIR_BUF
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,MSG_E_DIR_POST
	LD	C,DSS_PCHARS
	RST	DSS
	SCF
	RET
.CHDIR_OK
	LD	A,1
	LD	(.HAS_DIR),A
	; Basename = char after separator (DE was preserved).
	EX	DE,HL			; HL = separator ptr
	INC	HL
	LD	(.NAME_PTR),HL
	LD	A,(HL)
	OR	A
	JR	NZ,.NO_PATH
	; "dir\" with empty basename -> nothing to create.
	CALL	.RESTORE_CWD
	LD	HL,MSG_E_NOFILE
	LD	C,DSS_PCHARS
	RST	DSS
	SCF
	RET

.NO_PATH
	; ---- existing probe / prompt / create flow ----
	; Probe existence: read-only OPEN.  CREATE_OVERWRITE
	; cannot be used here -- it silently succeeds on an
	; existing file without truncating.
	LD	HL,(.NAME_PTR)
	LD	A,FA_READONLY
	LD	C,DSS_OPEN_FILE
	RST	DSS
	JR	C,.CREATE_FRESH
	; File exists: close the probe handle and decide.
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	LD	A,(.FORCE)
	OR	A
	JR	NZ,.DELETE
	; Prompt user (echo full original path so they see what
	; they typed, not just the basename).
	LD	HL,MSG_PRE
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,(.FULL_PTR)
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
	; CF reflects CREATE.  Restore CWD before returning.
	PUSH	AF
	CALL	.RESTORE_CWD
	POP	AF
	RET
.USER_NO
	LD	HL,MSG_NO
	LD	C,DSS_PCHARS
	RST	DSS
	CALL	.RESTORE_CWD
	SCF
	RET

; ------------------------------------------------------
; .RESTORE_CWD: if a CHDIR happened on the way in, undo it.
; Preserves AF, BC, DE, HL.
; ------------------------------------------------------
.RESTORE_CWD
	LD	A,(.HAS_DIR)
	OR	A
	RET	Z
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	XOR	A
	LD	(.HAS_DIR),A
	LD	HL,FILE_SAVED_CWD
	LD	C,DSS_CHDIR
	RST	DSS
	POP	HL
	POP	DE
	POP	BC
	POP	AF
	RET

.FULL_PTR	DW 0
.NAME_PTR	DW 0
.FORCE		DB 0
.HAS_DIR	DB 0


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
MSG_E_DIR_PRE	DB "[E] directory not found: ",0
MSG_E_DIR_POST	DB 13,10,0
MSG_E_NOFILE	DB "[E] no filename after path separator",13,10,0

	ENDMODULE

	ENDIF	; USE_FILE
	ENDIF	; _FILE
