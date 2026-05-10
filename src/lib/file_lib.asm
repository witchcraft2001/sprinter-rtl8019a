; ======================================================
; file_lib - shared file helpers for DSS utilities.
;
; Provides FILE.OPEN_OUTPUT (write-with-prompt for downloads)
; and FILE.OPEN_INPUT (read for uploads / streaming sources).
; Both call into a common SETUP_PATH helper that handles
; relative ("test\file.zip") and absolute ("C:\foo\file.zip",
; "\file.zip") paths: split the name at the last '/' or '\\',
; CHDIR into the directory, run the create/open against the
; basename, then restore CWD before returning.
;
; Works around the DSS_CREATE_OVERWRITE quirk where the
; syscall does NOT return an error and does NOT truncate when
; the file already exists; using it as an "exists?" probe
; silently corrupts data.
;
; Usage:
;   DEFINE USE_FILE
;   INCLUDE "file_lib.asm"
;   ...
;   LD  HL,(OUTPUT_PTR)         ; ASCIIZ filename, optional path
;   LD  A,(FORCE_FLAG)          ; 0 = prompt, !=0 = silent
;   CALL @FILE.OPEN_OUTPUT
;   ; CF=0 -> A = file handle
;
;   LD  HL,(INPUT_PTR)
;   CALL @FILE.OPEN_INPUT
;   ; CF=0 -> A = file handle (read-only)
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
; OPEN_OUTPUT: open a file for writing, with overwrite
; prompt or silent overwrite when force flag is set.
;   In:  HL = ASCIIZ filename, A = force flag (!=0 silent)
;   Out: CF=0 -> A = handle (FA_ARCHIVE, write)
;        CF=1 -> user declined / I/O error / dir missing
; ------------------------------------------------------
OPEN_OUTPUT
	LD	(FORCE_FLAG_BS),A
	CALL	SETUP_PATH
	RET	C				; dir not found, CWD untouched
	; --- existence probe / prompt / create ---
	LD	HL,(NAME_PTR)
	LD	A,FA_READONLY
	LD	C,DSS_OPEN_FILE
	RST	DSS
	JR	C,.CREATE_FRESH
	; File exists: close the probe handle and decide.
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	LD	A,(FORCE_FLAG_BS)
	OR	A
	JR	NZ,.DELETE
	; Prompt user (echo full original path so they see what
	; they typed, not just the basename).
	LD	HL,MSG_PRE
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,(FULL_PTR)
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,MSG_POST
	LD	C,DSS_PCHARS
	RST	DSS
	CALL	WAIT_YES_NO
	JR	C,.USER_NO
.DELETE
	LD	HL,(NAME_PTR)
	LD	C,DSS_DELETE
	RST	DSS
	; Ignore delete result (file may have race-disappeared).
.CREATE_FRESH
	LD	HL,(NAME_PTR)
	LD	A,FA_ARCHIVE
	LD	C,DSS_CREATE_OVERWRITE
	RST	DSS
	; CF reflects CREATE.  Restore CWD before returning.
	PUSH	AF
	CALL	RESTORE_CWD
	POP	AF
	RET
.USER_NO
	LD	HL,MSG_NO
	LD	C,DSS_PCHARS
	RST	DSS
	CALL	RESTORE_CWD
	SCF
	RET


; ------------------------------------------------------
; OPEN_INPUT: open a file for reading.
;   In:  HL = ASCIIZ filename, optional path
;   Out: CF=0 -> A = handle (FA_READONLY)
;        CF=1 -> not found / dir missing
; ------------------------------------------------------
OPEN_INPUT
	CALL	SETUP_PATH
	RET	C
	LD	HL,(NAME_PTR)
	LD	A,FA_READONLY
	LD	C,DSS_OPEN_FILE
	RST	DSS
	PUSH	AF
	CALL	RESTORE_CWD
	POP	AF
	RET


; ------------------------------------------------------
; SETUP_PATH: shared front-end for OPEN_OUTPUT / OPEN_INPUT.
;   In:  HL = ASCIIZ filename (may include path).
;   Out: NAME_PTR points at the basename to feed DSS file
;        syscalls; FULL_PTR keeps the original (so prompts
;        and error messages can echo it).  HAS_DIR=1 if a
;        CHDIR happened (RESTORE_CWD will undo it).
;        CF=0 success.  CF=1 -> CHDIR failed (dir missing
;        / empty basename); the message has been printed,
;        CWD was not changed.
; Trashes A, BC, DE, HL.
; ------------------------------------------------------
SETUP_PATH
	LD	(FULL_PTR),HL
	LD	(NAME_PTR),HL
	XOR	A
	LD	(HAS_DIR),A

	; Save current dir for the eventual restore.
	LD	HL,FILE_SAVED_CWD
	LD	C,DSS_CURDIR
	RST	DSS

	; Find last '/' or '\\' in the name.  DE = pointer to
	; that separator, or 0 if no path component.
	LD	HL,(FULL_PTR)
	LD	DE,0
.SCAN
	LD	A,(HL)
	OR	A
	JR	Z,.SCAN_END
	CP	'/'
	JR	Z,.HIT
	CP	0x5C
	JR	NZ,.NEXT
.HIT
	LD	D,H
	LD	E,L
.NEXT
	INC	HL
	JR	.SCAN
.SCAN_END
	LD	A,D
	OR	E
	JP	Z,.NO_PATH

	; Copy the dir part [name..separator-1] into FILE_DIR_BUF.
	LD	HL,(FULL_PTR)
	LD	BC,FILE_DIR_BUF
.CP
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
	JR	.CP
.CP_END
	XOR	A
	LD	(BC),A

	; Empty dir part (separator at position 0) -> volume root.
	LD	HL,FILE_DIR_BUF
	LD	A,(HL)
	OR	A
	JR	NZ,.CHDIR_GO
	LD	(HL),0x5C
	INC	HL
	LD	(HL),0
.CHDIR_GO
	; DSS calls clobber DE/HL; preserve the separator pointer.
	LD	HL,FILE_DIR_BUF
	PUSH	DE
	LD	C,DSS_CHDIR
	RST	DSS
	POP	DE
	JR	NC,.CHDIR_OK
	; CHDIR failed.
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
	LD	(HAS_DIR),A
	; Basename = char after separator.
	EX	DE,HL
	INC	HL
	LD	(NAME_PTR),HL
	LD	A,(HL)
	OR	A
	JR	NZ,.NO_PATH
	; "dir\" with empty basename -> nothing to open.
	CALL	RESTORE_CWD
	LD	HL,MSG_E_NOFILE
	LD	C,DSS_PCHARS
	RST	DSS
	SCF
	RET
.NO_PATH
	OR	A
	RET


; ------------------------------------------------------
; RESTORE_CWD: if SETUP_PATH did a CHDIR, undo it.
; Preserves AF, BC, DE, HL.
; ------------------------------------------------------
RESTORE_CWD
	LD	A,(HAS_DIR)
	OR	A
	RET	Z
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	XOR	A
	LD	(HAS_DIR),A
	LD	HL,FILE_SAVED_CWD
	LD	C,DSS_CHDIR
	RST	DSS
	POP	HL
	POP	DE
	POP	BC
	POP	AF
	RET


; ------------------------------------------------------
; BASENAME: HL = ASCIIZ path. Skip past the last '/', '\'
; or ':' (DSS drive separator).  Returns HL pointing at
; the basename portion (or unchanged if no separator).
; Preserves AF, BC, DE.
; ------------------------------------------------------
BASENAME
	PUSH	AF
	PUSH	BC
	PUSH	DE
	LD	D,H
	LD	E,L			; DE = best-so-far basename ptr
.SCAN
	LD	A,(HL)
	OR	A
	JR	Z,.DONE
	CP	'/'
	JR	Z,.SEP
	CP	0x5C
	JR	Z,.SEP
	CP	':'
	JR	Z,.SEP
	INC	HL
	JR	.SCAN
.SEP
	INC	HL
	LD	D,H
	LD	E,L
	JR	.SCAN
.DONE
	EX	DE,HL
	POP	DE
	POP	BC
	POP	AF
	RET


FULL_PTR	DW 0
NAME_PTR	DW 0
FORCE_FLAG_BS	DB 0
HAS_DIR		DB 0


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
