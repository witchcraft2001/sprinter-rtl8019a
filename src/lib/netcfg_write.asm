; ======================================================
; netcfg_write.asm -- interactive wizard for NETCFG -w.
;
; Walks the user through RTL_RESET / RTL_HW / (optional card probe) /
; RTL_TYPE / RTL_MAC / IP (or DHCP) / NETMASK / GATEWAY / DNS1 /
; DNS2 / TZ / NTP, then rewrites NET.CFG as a canonical file
; (comments and unrecognized keys such as RTL_IRQ are NOT
; preserved -- this is a full rewrite, not an edit in place).
;
; Public API:
;   NETCFGW.RUN   run the wizard end to end.
;     Out: CF=0 success (NET.CFG written).
;          CF=1, A = EX_CANCEL (Esc) / EX_CFG_ERR (existing
;          NET.CFG unreadable) / EX_FILE_ERR (write failed).
;
; Wrap callsites in `DEFINE USE_NETCFG_WRITE` before
; `INCLUDE "netcfg_write.asm"`.  Requires USE_NETCFG_LOAD and
; USE_CMDL_PARSE (for @CMDL.PARSE_IPV4) to already be defined.
;
; PRINT/PRINTLN (macro.inc) reference a bare LINE_END label
; resolved in the CURRENT module; MAIN's is MAIN.LINE_END, so
; this module defines its own (see zmodem.asm for precedent).
;
; DSS_PUTCHAR/DSS_WAITKEY trash A/BC/IY (some also D/E/HL), so
; every byte of PROMPT_FIELD's line-editor state that must
; survive across a console call lives in NETCFGW_STATE (BSS),
; never in a register.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_NETCFG_WRITE
	DEFINE	_NETCFG_WRITE

	INCLUDE "memmap.inc"

	MODULE NETCFGW

	IFDEF USE_NETCFG_WRITE

; -------- state field aliases (see memmap.inc for layout) --------
ST_LABEL	EQU NETCFGW_STATE + 0		; 2
ST_DEST		EQU NETCFGW_STATE + 2		; 2
ST_VALIDATOR	EQU NETCFGW_STATE + 4		; 2
ST_CAP		EQU NETCFGW_STATE + 6		; 1
ST_FLAGS	EQU NETCFGW_STATE + 7		; 1
ST_EFFCAP	EQU NETCFGW_STATE + 8		; 1
ST_EDITLEN	EQU NETCFGW_STATE + 9		; 1
ST_OVERFLOW	EQU NETCFGW_STATE + 10		; 1
ST_KEYCHAR	EQU NETCFGW_STATE + 11		; 1
ST_SCRATCH_IP	EQU NETCFGW_STATE + 12		; 4 (also TZ NEG/HOURS/MINS)
ST_TZ_NEG	EQU ST_SCRATCH_IP + 0
ST_TZ_HOURS	EQU ST_SCRATCH_IP + 1
ST_TZ_MINS	EQU ST_SCRATCH_IP + 2
ST_SCRATCH_MAC	EQU NETCFGW_STATE + 16		; 6
ST_PATH_PTR	EQU NETCFGW_STATE + 22		; 2

FLAG_ALLOW_DASH	EQU 1				; "-" clears an optional field

; Shared RTL_RESET/IP word constants -- referenced from several routines
; below; kept as one copy each instead of a local DB per call site.
WORD_AUTO	DB "AUTO",0
WORD_SOFT	DB "SOFT",0
WORD_HARD	DB "HARD",0
WORD_NE1000	DB "NE1000",0
WORD_NE2000	DB "NE2000",0
MSG_DHCP	DB "DHCP",0


; ------------------------------------------------------
; RUN: entry point.  See header for CF/A contract.
; Trashes everything.
; ------------------------------------------------------
RUN
	XOR	A
	LD	(.NEWFILE),A
	LD	(NETCFGW_PROBE_VALID),A
	CALL	@NETCFG.LOAD
	JR	NC,.LOADED
	CP	E_FILE_NOT_FOUND
	JR	NZ,.UNREADABLE
	LD	A,1
	LD	(.NEWFILE),A		; missing file -> defaults, treat as new
	JR	.LOADED
.UNREADABLE
	PRINTLN	MSG_UNREADABLE
	LD	A,EX_CFG_ERR
	SCF
	RET
.LOADED
	CALL	FIELDS_FROM_BINARY
	LD	A,(.NEWFILE)
	OR	A
	CALL	NZ,SEED_NEW_FILE_DEFAULTS

	PRINTLN	MSG_INTRO

	; Probe first so a detected address becomes the RTL_HW default.  A second
	; probe after a manually entered address is handled by NETCFG -i.
	LD	IX,F_RESET
	CALL	ASK
	JP	C,.CANCELLED
	CALL	PROMPT_PROBE
	JP	C,.CANCELLED
	LD	IX,F_HW
	CALL	ASK
	JP	C,.CANCELLED
	; If the first broad scan failed, retry immediately with the address the
	; user just supplied.  If a successful probe's address was edited, discard
	; the old MAC/type and probe the new card instead of carrying stale data.
	LD	A,(NETCFGW_PROBE_VALID)
	OR	A
	JR	Z,.REPROBE
	LD	HL,NETCFGW_HW
	LD	DE,NETCFGW_PROBED_HW
	CALL	STREQ
	JR	Z,.PROBE_DONE
	XOR	A
	LD	(NETCFGW_MAC),A
	LD	(NETCFGW_TYPE),A
	LD	(NETCFGW_PROBE_VALID),A
.REPROBE
	LD	A,(NETCFGW_HW)
	OR	A
	CALL	NZ,DO_PROBE
.PROBE_DONE
	LD	IX,F_TYPE
	CALL	ASK
	JP	C,.CANCELLED
	LD	IX,F_MAC
	CALL	ASK
	JP	C,.CANCELLED
	LD	IX,F_IP
	CALL	ASK
	JP	C,.CANCELLED

	; DHCP mode -> skip the four static-only prompts, clear them.
	LD	HL,NETCFGW_IP
	LD	DE,MSG_DHCP
	CALL	STREQ
	JR	NZ,.STATIC

	XOR	A
	LD	(NETCFGW_MASK),A
	LD	(NETCFGW_GW),A
	LD	(NETCFGW_DNS1),A
	LD	(NETCFGW_DNS2),A
	JR	.TZ

.STATIC
	LD	IX,F_MASK
	CALL	ASK
	JP	C,.CANCELLED
	LD	IX,F_GW
	CALL	ASK
	JP	C,.CANCELLED
	LD	IX,F_DNS1
	CALL	ASK
	JP	C,.CANCELLED
	LD	IX,F_DNS2
	CALL	ASK
	JP	C,.CANCELLED

.TZ
	LD	IX,F_TZ
	CALL	ASK
	JP	C,.CANCELLED
	LD	IX,F_NTP
	CALL	ASK
	JP	C,.CANCELLED

	CALL	SERIALIZE
	JP	SAVE

.CANCELLED
	PRINTLN	MSG_CANCELLED
	LD	A,EX_CANCEL
	SCF
	RET

.NEWFILE	DB 0


; ------------------------------------------------------
; ASK: one wizard step -- print the field's hint, then run
; PROMPT_FIELD on it.  The hint is printed here rather than in
; PROMPT_FIELD so that a rejected value re-prompts with the
; one-line "LABEL [default]: " only, not the whole explanation.
;   In:  IX -> field descriptor (see FIELD below).
;   Out: PROMPT_FIELD's CF.  Trashes everything.
; ------------------------------------------------------
ASK
	LD	L,(IX+0)
	LD	H,(IX+1)
	PUSH	IX			; console calls may trash anything
	LD	C,DSS_PCHARS
	RST	DSS
	POP	IX
	LD	E,(IX+4)
	LD	D,(IX+5)
	LD	B,(IX+6)
	LD	C,(IX+7)
	LD	L,(IX+8)
	LD	H,(IX+9)
	PUSH	HL			; validator
	LD	L,(IX+2)
	LD	H,(IX+3)
	POP	IX
	JP	PROMPT_FIELD

; Field descriptor: hint, label, edit buffer, buffer capacity
; (incl NUL), flags, validator.  10 bytes.
	MACRO	FIELD hint, label, dest, cap, flags, validator
	DW	hint, label, dest
	DB	cap, flags
	DW	validator
	ENDM

F_RESET	FIELD	HINT_RESET, MSG_LBL_RTL_RESET, NETCFGW_RESET, 8,  0,               VALIDATE_RESET
F_HW	FIELD	HINT_HW,    MSG_LBL_RTL_HW,    NETCFGW_HW,    12, FLAG_ALLOW_DASH, VALIDATE_RTL_HW
F_TYPE	FIELD	HINT_TYPE,  MSG_LBL_RTL_TYPE,  NETCFGW_TYPE,  8,  FLAG_ALLOW_DASH, VALIDATE_RTL_TYPE
F_MAC	FIELD	HINT_MAC,   MSG_LBL_RTL_MAC,   NETCFGW_MAC,   18, FLAG_ALLOW_DASH, VALIDATE_MAC
F_IP	FIELD	HINT_IP,    MSG_LBL_IP,        NETCFGW_IP,    16, 0,               VALIDATE_IP
F_MASK	FIELD	HINT_MASK,  MSG_LBL_NETMASK,   NETCFGW_MASK,  16, FLAG_ALLOW_DASH, VALIDATE_IPV4
F_GW	FIELD	HINT_GW,    MSG_LBL_GATEWAY,   NETCFGW_GW,    16, FLAG_ALLOW_DASH, VALIDATE_IPV4
F_DNS1	FIELD	HINT_DNS1,  MSG_LBL_DNS1,      NETCFGW_DNS1,  16, FLAG_ALLOW_DASH, VALIDATE_IPV4
F_DNS2	FIELD	HINT_DNS2,  MSG_LBL_DNS2,      NETCFGW_DNS2,  16, FLAG_ALLOW_DASH, VALIDATE_IPV4
F_TZ	FIELD	HINT_TZ,    MSG_LBL_TZ,        NETCFGW_TZ,    8,  FLAG_ALLOW_DASH, VALIDATE_TZ
F_NTP	FIELD	HINT_NTP,   MSG_LBL_NTP,       NETCFGW_NTP,   32, FLAG_ALLOW_DASH, VALIDATE_NTP


; ------------------------------------------------------
; CALL_IX: lets a validator address stored in IX be invoked
; with CALL semantics (Z80 has JP (IX) but no CALL (IX)).
; ------------------------------------------------------
CALL_IX
	JP	(IX)


; ------------------------------------------------------
; SEED_NEW_FILE_DEFAULTS: no NET.CFG existed, so
; FIELDS_FROM_BINARY produced @NETCFG.LOAD's all-empty
; defaults.  Seed the same starting point as
; config/NETSMPL.CFG instead: DHCP, a public NTP pool, and a
; placeholder TZ, so a first-time user has something sane to
; accept or edit rather than a wall of empty prompts.
; Trashes everything.
; ------------------------------------------------------
SEED_NEW_FILE_DEFAULTS
	LD	HL,.D_IP
	LD	DE,NETCFGW_IP
	CALL	@MAIN.COPY_ASCIIZ
	LD	HL,.D_NTP
	LD	DE,NETCFGW_NTP
	CALL	@MAIN.COPY_ASCIIZ
	LD	HL,.D_TZ
	LD	DE,NETCFGW_TZ
	JP	@MAIN.COPY_ASCIIZ
.D_IP	DB "DHCP",0
.D_NTP	DB "pool.ntp.org",0
.D_TZ	DB "+3",0


; ------------------------------------------------------
; FIELDS_FROM_BINARY: convert NETCFG's parsed binary fields
; (already loaded by @NETCFG.LOAD) into the wizard's ASCIIZ
; edit buffers.  Trashes everything.
; ------------------------------------------------------
FIELDS_FROM_BINARY
	LD	HL,@NETCFG.OUR_RTL_HW
	LD	DE,NETCFGW_HW
	CALL	@MAIN.COPY_ASCIIZ
	LD	HL,@NETCFG.OUR_RTL_TYPE
	LD	DE,NETCFGW_TYPE
	CALL	@MAIN.COPY_ASCIIZ

	LD	A,(@NETCFG.OUR_RTL_RESET)
	LD	HL,WORD_AUTO
	CP	RTL_RESET_AUTO
	JR	Z,.RS
	LD	HL,WORD_SOFT
	CP	RTL_RESET_SOFT
	JR	Z,.RS
	LD	HL,WORD_HARD
.RS
	LD	DE,NETCFGW_RESET
	CALL	@MAIN.COPY_ASCIIZ

	LD	IX,@NETCFG.OUR_MAC
	LD	A,(IX+0)
	OR	(IX+1)
	OR	(IX+2)
	OR	(IX+3)
	OR	(IX+4)
	OR	(IX+5)
	LD	DE,NETCFGW_MAC
	JR	NZ,.MAC_NONZERO
	XOR	A
	LD	(DE),A
	JR	.MAC_DONE
.MAC_NONZERO
	LD	B,6
.MAC_LP
	LD	A,(IX+0)
	CALL	@MAIN.FMT_BYTE_HEX
	INC	IX
	DEC	B
	JR	Z,.MAC_END
	LD	A,':'
	LD	(DE),A
	INC	DE
	JR	.MAC_LP
.MAC_END
	XOR	A
	LD	(DE),A
.MAC_DONE

	LD	A,(@NETCFG.DHCP_MODE)
	OR	A
	LD	DE,NETCFGW_IP
	JR	Z,.IP_STATIC
	LD	HL,MSG_DHCP
	CALL	@MAIN.COPY_ASCIIZ
	JR	.IP_DONE
.IP_STATIC
	LD	IX,@NETCFG.OUR_IP
	CALL	FMT_IPV4_TO_DE
.IP_DONE

	LD	IX,@NETCFG.NETMASK
	LD	DE,NETCFGW_MASK
	CALL	FMT_IPV4_TO_DE
	LD	IX,@NETCFG.GATEWAY
	LD	DE,NETCFGW_GW
	CALL	FMT_IPV4_TO_DE
	LD	IX,@NETCFG.DNS1
	LD	DE,NETCFGW_DNS1
	CALL	FMT_IPV4_TO_DE
	LD	IX,@NETCFG.DNS2
	LD	DE,NETCFGW_DNS2
	CALL	FMT_IPV4_TO_DE

	LD	HL,@NETCFG.TZ
	LD	DE,NETCFGW_TZ
	CALL	@MAIN.COPY_ASCIIZ
	LD	HL,@NETCFG.NTP
	LD	DE,NETCFGW_NTP
	CALL	@MAIN.COPY_ASCIIZ

	; Every other field arrives already canonical, because @NETCFG.LOAD
	; parsed it into binary and we formatted it back.  TZ does not: it
	; is a raw string end to end (Stage A), so a malformed TZ= line
	; would show up as the prompt's default and a plain Enter would
	; write it straight back out.  Run it through the validator in
	; place -- it finishes parsing before it writes, so source and
	; destination may be the same buffer -- and blank whatever the
	; validator rejects (empty = UTC, same as an absent key).
	LD	HL,NETCFGW_TZ
	LD	DE,NETCFGW_TZ
	CALL	VALIDATE_TZ
	RET	NC
	XOR	A
	LD	(NETCFGW_TZ),A
	RET



; FMT_IPV4_TO_DE: IX -> 4 raw bytes, DE = ASCIIZ dest.
; All-zero -> empty string ("not set"), matching netcfg.asm's
; SETENV_IPV4 convention.  Trashes A, BC, IX.
FMT_IPV4_TO_DE
	LD	A,(IX+0)
	OR	(IX+1)
	OR	(IX+2)
	OR	(IX+3)
	JR	NZ,.NONZERO
	XOR	A
	LD	(DE),A
	RET
.NONZERO
	LD	B,4
.LP
	LD	A,(IX+0)
	PUSH	BC
	CALL	@MAIN.FMT_BYTE_DEC	; trashes A,BC,H
	POP	BC
	INC	IX
	DEC	B
	JR	Z,.END
	LD	A,'.'
	LD	(DE),A
	INC	DE
	JR	.LP
.END
	XOR	A
	LD	(DE),A
	RET


; ------------------------------------------------------
; FLUSH_KEYS: drop anything typed before this prompt appeared.
; #35 K_CLEAR empties the ring and then dispatches the function
; in B; #33 CTRLKEY only reports the modifier byte, so unlike
; the usual K_CLEAR+WAITKEY pairing this consumes no keystroke
; and the caller can then wait with a cursor on screen.
; ------------------------------------------------------
FLUSH_KEYS
	LD	B,DSS_CTRLKEY
	LD	C,DSS_K_CLEAR
	RST	DSS
	RET


; ------------------------------------------------------
; GETKEY: wait for a keystroke, blinking a cursor meanwhile, so
; the screen says "your turn" instead of looking hung.
;
; DSS draws no cursor for #30 WAITKEY, and the two alternatives
; are both unusable here: #36 K_SETUP's cursor subfunctions are
; absent from the DSS sources this kit is built against, and #32
; ECHOKEY -- which does blink a cursor -- also echoes the key it
; read, including Esc and Enter, which this editor must handle
; itself.  So the cursor is drawn by hand: '_' and ' ' written
; alternately over the same cell, while #37 TESTKEY peeks at the
; keyboard ring WITHOUT popping it.  The key is popped with
; WAITKEY only once the cell has been left blank, so the echo
; that follows lands on a clean screen position.
;   Out: A = key.  Trashes everything.
; ------------------------------------------------------
BLINK_POLLS	EQU 40			; TESTKEY polls per phase, high byte:
					; 40*256 peeks is roughly a 2 Hz blink.
					; Poll-paced rather than timed because
					; DSS's only clock (#21 SYSTIME) has
					; one-second resolution.
GETKEY
	LD	A,1			; start lit, so the cursor is there the
	LD	(.PHASE),A		; instant the prompt finishes printing
.DRAW
	LD	HL,0
	LD	(.TICK),HL
	LD	A,(.PHASE)
	OR	A
	LD	A,' '
	JR	Z,.PUT
	LD	A,'_'
.PUT
	CALL	.PUTBACK
.POLL
	LD	C,DSS_TESTKEY
	RST	DSS
	JR	NZ,.GOT
	LD	HL,(.TICK)
	INC	HL
	LD	(.TICK),HL
	LD	A,H
	CP	BLINK_POLLS
	JR	C,.POLL
	LD	A,(.PHASE)
	XOR	1
	LD	(.PHASE),A
	JR	.DRAW
.GOT
	LD	A,' '			; blank the cell before the echo
	CALL	.PUTBACK
	LD	C,DSS_WAITKEY
	RST	DSS
	RET

; .PUTBACK: print A, then step back onto it, so the next write
; lands on the same cell.  0x08 is cursor-left (the backspace
; handler above relies on the same thing).
.PUTBACK
	LD	C,DSS_PUTCHAR
	RST	DSS
	LD	A,8
	LD	C,DSS_PUTCHAR
	RST	DSS
	RET

.PHASE		DB 0
.TICK		DW 0


; ------------------------------------------------------
; PROMPT_FIELD: labeled prompt + line editor + validator.
;   In: HL = label (ASCIIZ), DE = dest (ASCIIZ default in
;       place), B = dest capacity (incl NUL), C = flags
;       (FLAG_ALLOW_DASH), IX = validator (see below).
;   Out: CF=0 dest updated (or unchanged if Enter pressed with
;        nothing typed); CF=1 Esc pressed (whole wizard exits).
;   Validator contract: In: HL = typed ASCIIZ text, DE = dest,
;        B = dest capacity.  Out: CF=0, dest holds the
;        canonicalized value; CF=1 invalid (dest untouched).
;        May trash everything.
; ------------------------------------------------------
PROMPT_FIELD
	LD	(ST_LABEL),HL
	LD	(ST_DEST),DE
	LD	A,B
	LD	(ST_CAP),A
	LD	A,C
	LD	(ST_FLAGS),A
	LD	(ST_VALIDATOR),IX
	LD	A,B
	DEC	A			; A = max typed chars = cap - 1
	CP	63
	JR	C,.EFFOK
	LD	A,63			; also bounded by NETCFGW_EDIT's own size
.EFFOK
	LD	(ST_EFFCAP),A

.REDRAW
	LD	HL,(ST_LABEL)
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,MSG_BRACKET_OPEN
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,(ST_DEST)
	LD	C,DSS_PCHARS
	RST	DSS
	LD	HL,MSG_BRACKET_COLON
	LD	C,DSS_PCHARS
	RST	DSS

	XOR	A
	LD	(ST_EDITLEN),A
	LD	(ST_OVERFLOW),A

	CALL	FLUSH_KEYS
.KEYLOOP
	CALL	GETKEY
	; Esc must be tested BEFORE any case-fold: ';' folds to Esc (0x1B)
	; under AND 0xDF, see src/lib/file_lib.asm's WAIT_ORC precedent.
	CP	0x1B
	JP	Z,.ESC
	LD	(ST_KEYCHAR),A
	CP	0x0D
	JR	Z,.ENTER
	CP	0x0A
	JR	Z,.ENTER
	CP	0x08
	JR	Z,.BS
	CP	0x7F
	JR	Z,.BS
	CP	' '
	JR	C,.KEYLOOP		; other control chars: ignore
	CP	0x7F
	JR	NC,.KEYLOOP
	; printable character
	LD	A,(ST_EDITLEN)
	LD	HL,ST_EFFCAP
	CP	(HL)
	JR	NC,.SETOVERFLOW
	LD	HL,NETCFGW_EDIT
	LD	E,A
	LD	D,0
	ADD	HL,DE
	LD	A,(ST_KEYCHAR)
	LD	(HL),A
	LD	C,DSS_PUTCHAR
	RST	DSS
	LD	A,(ST_EDITLEN)
	INC	A
	LD	(ST_EDITLEN),A
	JR	.KEYLOOP
.SETOVERFLOW
	LD	A,1
	LD	(ST_OVERFLOW),A
	JR	.KEYLOOP
.BS
	LD	A,(ST_EDITLEN)
	OR	A
	JR	Z,.KEYLOOP
	DEC	A
	LD	(ST_EDITLEN),A
	XOR	A
	LD	(ST_OVERFLOW),A
	LD	A,8
	LD	C,DSS_PUTCHAR
	RST	DSS
	LD	A,' '
	LD	C,DSS_PUTCHAR
	RST	DSS
	LD	A,8
	LD	C,DSS_PUTCHAR
	RST	DSS
	JR	.KEYLOOP
.ENTER
	PRINTLN	MSG_EMPTY
	LD	A,(ST_OVERFLOW)
	OR	A
	JR	NZ,.TOOLONG
	LD	A,(ST_EDITLEN)
	OR	A
	JR	Z,.KEEP_DEFAULT
	; NUL-terminate the typed text.
	LD	HL,NETCFGW_EDIT
	LD	E,A
	LD	D,0
	ADD	HL,DE
	XOR	A
	LD	(HL),A
	; lone "-" on an ALLOW_DASH field clears the destination.
	LD	A,(ST_EDITLEN)
	CP	1
	JR	NZ,.RUNVALIDATOR
	LD	A,(NETCFGW_EDIT)
	CP	'-'
	JR	NZ,.RUNVALIDATOR
	LD	A,(ST_FLAGS)
	AND	FLAG_ALLOW_DASH
	JR	Z,.RUNVALIDATOR
	LD	DE,(ST_DEST)
	XOR	A
	LD	(DE),A
	OR	A
	RET
.RUNVALIDATOR
	LD	HL,NETCFGW_EDIT
	LD	DE,(ST_DEST)
	LD	A,(ST_CAP)
	LD	B,A
	LD	IX,(ST_VALIDATOR)
	CALL	CALL_IX
	JR	C,.INVALID
	OR	A
	RET
.INVALID
	PRINTLN	MSG_INVALID
	JP	.REDRAW
.TOOLONG
	PRINTLN	MSG_TOO_LONG
	JP	.REDRAW
.KEEP_DEFAULT
	OR	A
	RET
.ESC
	PRINTLN	MSG_EMPTY
	SCF
	RET


; ------------------------------------------------------
; PROMPT_PROBE: optional card auto-detect.
;   Runs BEFORE the RTL_HW prompt: a successful probe leaves
;   the discovered "S/#HHH" in NETCFGW_HW, where it becomes that
;   prompt's default -- RTL_HW is asked exactly once.
;   Out: CF=0 continue; CF=1 the user pressed Esc and the whole
;        wizard is cancelled -- same contract as PROMPT_FIELD,
;        so Esc means the same thing at every prompt.  A failed
;        probe is NOT a cancel.
; ------------------------------------------------------
PROMPT_PROBE
	LD	HL,NETCFGW_RESET
	LD	DE,WORD_HARD
	CALL	MATCH_WORD_CI
	JR	NZ,.NOTHARD
	PRINT	MSG_PROBE_WARN_HARD
	XOR	A			; default = No
	JR	.ASK
.NOTHARD
	PRINT	HINT_PROBE
	LD	A,1			; default = Yes
.ASK
	; ST_OVERFLOW is PROMPT_FIELD-only state, idle here: reused as the
	; "default is yes" flag.  DSS_PUTCHAR/WAITKEY trash A/BC/IY, so the
	; typed key is stashed to ST_KEYCHAR immediately, before the first
	; console call, and reloaded from memory after each one -- never
	; carried in a register across RST DSS.
	LD	(ST_OVERFLOW),A
	PRINT	MSG_PROBE_Q
	LD	HL,MSG_PROBE_DEF_Y	; the hint must match the real default
	LD	A,(ST_OVERFLOW)
	OR	A
	JR	NZ,.HINT
	LD	HL,MSG_PROBE_DEF_N
.HINT
	LD	C,DSS_PCHARS
	RST	DSS
	CALL	FLUSH_KEYS
	CALL	GETKEY
	LD	(ST_KEYCHAR),A
	CP	0x1B
	JR	Z,.ESC
	CP	' '
	JR	C,.NOECHO
	LD	C,DSS_PUTCHAR
	RST	DSS
.NOECHO
	PRINTLN	MSG_EMPTY
	LD	A,(ST_KEYCHAR)
	CP	'Y'
	JR	Z,.YES
	CP	'y'
	JR	Z,.YES
	CP	0x0D
	JR	Z,.DEFAULT
	CP	0x0A
	JR	Z,.DEFAULT
.NO
	OR	A			; CF=0: "CP 0x0A" above can leave CF set
	RET
.DEFAULT
	LD	A,(ST_OVERFLOW)
	OR	A
	RET	Z
.YES
	JP	DO_PROBE		; always returns CF=0
.ESC
	PRINTLN	MSG_EMPTY		; nothing was echoed for Esc
	SCF
	RET


; DO_PROBE: publish NET_RTL_HW/NET_RTL_RESET from the current
; wizard buffers, run FILL_MAC_FROM_PROM, and on success show
; the found MAC and leave the discovered slot/base in
; NETCFGW_HW as the default of the RTL_HW prompt that follows.
; On failure NETCFGW_HW is untouched.
;   Out: CF=0 always.  Trashes everything.
DO_PROBE
	LD	A,(NETCFGW_HW)
	OR	A
	LD	A,0
	JR	Z,.PIN_FLAG
	INC	A
.PIN_FLAG
	LD	(NETCFGW_PROBE_PINNED),A	; 1 when a pinned address must match
	LD	HL,NETCFGW_HW
	LD	DE,NETCFGW_PROBED_HW
	CALL	@MAIN.COPY_ASCIIZ
	LD	HL,@MAIN.N_NET_RTL_HW
	LD	IX,NETCFGW_HW
	CALL	@MAIN.SETENV_STR
	LD	HL,NETCFGW_RESET
	LD	DE,WORD_AUTO
	CALL	MATCH_WORD_CI
	LD	IX,.EMPTY
	JR	Z,.RESET_ENV
	LD	IX,NETCFGW_RESET
.RESET_ENV
	LD	HL,@MAIN.N_NET_RTL_RESET
	CALL	@MAIN.SETENV_STR

	XOR	A
	LD	(@NETCFG.OUR_MAC+0),A
	LD	(@NETCFG.OUR_MAC+1),A
	LD	(@NETCFG.OUR_MAC+2),A
	LD	(@NETCFG.OUR_MAC+3),A
	LD	(@NETCFG.OUR_MAC+4),A
	LD	(@NETCFG.OUR_MAC+5),A
	CALL	@MAIN.FILL_MAC_FROM_PROM
	CP	EX_OK
	JR	NZ,.FAIL

	LD	A,(NETCFGW_PROBE_PINNED)
	OR	A
	JR	Z,.AUTO_HW
	; INIT_BASE may self-heal a wrong pinned address by auto-scanning.  That
	; is useful for normal utilities but not for this wizard: it must not
	; replace a newly typed address with some other responding card.
	LD	HL,@MAIN.N_NET_RTL_HW
	LD	DE,NETCFGW_EDIT
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	OR	A
	JR	Z,.WRONG_HW
	LD	HL,NETCFGW_EDIT
	LD	DE,NETCFGW_PROBED_HW
	CALL	STREQ
	JR	Z,.HW_MATCH
.WRONG_HW
	XOR	A
	LD	(@NETCFG.OUR_MAC),A
	LD	(NETCFGW_TYPE),A
	JR	.FAIL
.AUTO_HW
	CALL	BUILD_HW_FROM_PROBE
.HW_MATCH
	LD	HL,NETCFGW_HW
	LD	DE,NETCFGW_PROBED_HW
	CALL	@MAIN.COPY_ASCIIZ
	LD	A,1
	LD	(NETCFGW_PROBE_VALID),A
	LD	A,(RTL_CARD_FLAGS)
	AND	RTL_LAYOUT_FLAG_NE1000
	LD	HL,WORD_NE2000
	JR	Z,.TYPE_FOUND
	LD	HL,WORD_NE1000
.TYPE_FOUND
	LD	DE,NETCFGW_TYPE
	CALL	@MAIN.COPY_ASCIIZ
	PRINT	MSG_PROBE_FOUND
	LD	HL,@NETCFG.OUR_MAC
	CALL	PRINT_MAC_HL
	PRINTLN	MSG_EMPTY
	OR	A
	RET
.FAIL
	PRINTLN	MSG_PROBE_FAILED
	OR	A			; a failed probe is not a cancel
	RET

.EMPTY	DB 0


; BUILD_HW_FROM_PROBE: format "S/#HHH" from @ISA.ISA_SLOT and
; RTL_BASE_PTR into NETCFGW_HW.  Mirrors rtl8019.asm's
; WRITE_ENV_HW arithmetic.  ISA window must already be closed
; (true on every FILL_MAC_FROM_PROM exit path).  Trashes A,HL.
BUILD_HW_FROM_PROBE
	LD	A,(@ISA.ISA_SLOT)
	ADD	A,'0'
	LD	(NETCFGW_HW+0),A
	LD	A,'/'
	LD	(NETCFGW_HW+1),A
	LD	A,'#'
	LD	(NETCFGW_HW+2),A
	LD	HL,(RTL_BASE_PTR)
	LD	A,H
	SUB	HIGH ISA_BASE_A
	AND	0x0F
	CALL	.NIB
	LD	(NETCFGW_HW+3),A
	LD	A,L
	RRCA
	RRCA
	RRCA
	RRCA
	AND	0x0F
	CALL	.NIB
	LD	(NETCFGW_HW+4),A
	LD	A,L
	AND	0x0F
	CALL	.NIB
	LD	(NETCFGW_HW+5),A
	XOR	A
	LD	(NETCFGW_HW+6),A
	RET
.NIB
	CP	10
	JR	C,.D9
	ADD	A,'A'-10
	RET
.D9
	ADD	A,'0'
	RET


; PRINT_MAC_HL: HL -> 6 raw bytes; prints "aa:bb:cc:dd:ee:ff"
; using NETCFGW_EDIT as scratch (idle between field prompts).
; Trashes everything.
PRINT_MAC_HL
	PUSH	HL
	POP	IX
	LD	DE,NETCFGW_EDIT
	LD	B,6
.LP
	LD	A,(IX+0)
	CALL	@MAIN.FMT_BYTE_HEX
	INC	IX
	DEC	B
	JR	Z,.END
	LD	A,':'
	LD	(DE),A
	INC	DE
	JR	.LP
.END
	XOR	A
	LD	(DE),A
	LD	HL,NETCFGW_EDIT
	LD	C,DSS_PCHARS
	RST	DSS
	RET


; ------------------------------------------------------
; Validators.  In: HL=typed text, DE=dest, B=dest capacity.
; Out: CF=0 dest holds canonical value; CF=1 invalid.
; ------------------------------------------------------

; @UTIL.PARSE_DEC_BYTE (used inside @CMDL.PARSE_IPV4) has no overflow
; check -- "999" silently parses to 231 (mod 256) with CF=0, no error.
; So a successful PARSE_IPV4 is not enough: the parsed bytes are
; reformatted to canonical text and compared against what was actually
; typed, and only a match is committed to dest.  ST_SCRATCH_MAC (unused
; during IPv4 validation) stashes the two pointers across the reused DE.
VALIDATE_IPV4
	LD	(ST_SCRATCH_MAC+0),HL	; original typed text
	LD	(ST_SCRATCH_MAC+2),DE	; dest
	LD	DE,ST_SCRATCH_IP
	CALL	@CMDL.PARSE_IPV4
	JR	C,.BAD
	LD	IX,ST_SCRATCH_IP
	LD	DE,NETCFGW_WRITE_BUF	; format into scratch, not dest, until verified
	LD	B,4
.LP
	LD	A,(IX+0)
	PUSH	BC
	CALL	@MAIN.FMT_BYTE_DEC
	POP	BC
	INC	IX
	DEC	B
	JR	Z,.FEND
	LD	A,'.'
	LD	(DE),A
	INC	DE
	JR	.LP
.FEND
	XOR	A
	LD	(DE),A
	LD	HL,NETCFGW_WRITE_BUF
	LD	DE,(ST_SCRATCH_MAC+0)
	CALL	STREQ
	JR	NZ,.BAD
	LD	HL,NETCFGW_WRITE_BUF
	LD	DE,(ST_SCRATCH_MAC+2)
	CALL	@MAIN.COPY_ASCIIZ
	OR	A
	RET
.BAD
	SCF
	RET


VALIDATE_IP
	PUSH	DE
	CALL	@NETCFG.MATCH_DHCP
	POP	DE
	JR	NZ,VALIDATE_IPV4
	LD	HL,MSG_DHCP
	CALL	@MAIN.COPY_ASCIIZ
	OR	A
	RET


VALIDATE_RTL_HW
	PUSH	DE			; PARSE_HW_LINE uses DE as its own
					; hex-accumulator scratch -- save dest.
	XOR	A
	LD	(@NETCFG.OUR_RTL_HW),A
	CALL	@NETCFG.PARSE_HW_LINE
	POP	DE
	LD	A,(@NETCFG.OUR_RTL_HW)
	OR	A
	JR	Z,.BAD
	LD	HL,@NETCFG.OUR_RTL_HW
	CALL	@MAIN.COPY_ASCIIZ
	OR	A
	RET
.BAD
	SCF
	RET

VALIDATE_RTL_TYPE
	LD	A,(HL)
	OR	A
	JR	Z,.AUTO
	PUSH	HL
	LD	DE,WORD_AUTO
	CALL	MATCH_WORD_CI
	POP	HL
	JR	Z,.AUTO
	PUSH	HL
	LD	DE,WORD_NE1000
	CALL	MATCH_WORD_CI
	POP	HL
	JR	Z,.N1000
	LD	DE,WORD_NE2000
	CALL	MATCH_WORD_CI
	JR	Z,.N2000
	SCF
	RET
.AUTO
	LD	DE,(ST_DEST)
	XOR	A
	LD	(DE),A
	RET
.N1000
	LD	HL,WORD_NE1000
	JR	.STORE
.N2000
	LD	HL,WORD_NE2000
.STORE
	LD	DE,(ST_DEST)
	CALL	@MAIN.COPY_ASCIIZ
	OR	A
	RET


VALIDATE_MAC
	PUSH	DE
	LD	DE,ST_SCRATCH_MAC
	LD	B,6
.LP
	CALL	@UTIL.PARSE_HEX_BYTE
	JR	C,.BAD
	LD	(DE),A
	INC	DE
	DEC	B
	JR	Z,.GOTALL
	LD	A,(HL)
	CP	':'
	JR	NZ,.BAD
	INC	HL
	JR	.LP
.GOTALL
	LD	A,(HL)
	OR	A
	JR	NZ,.BAD
	POP	DE
	LD	IX,ST_SCRATCH_MAC
	LD	B,6
.FMT
	LD	A,(IX+0)
	CALL	@MAIN.FMT_BYTE_HEX
	INC	IX
	DEC	B
	JR	Z,.FMT_END
	LD	A,':'
	LD	(DE),A
	INC	DE
	JR	.FMT
.FMT_END
	XOR	A
	LD	(DE),A
	OR	A
	RET
.BAD
	POP	DE
	SCF
	RET


VALIDATE_RESET
	PUSH	DE
	LD	DE,WORD_AUTO
	CALL	MATCH_WORD_CI
	JR	Z,.SET_AUTO
	LD	DE,WORD_SOFT
	CALL	MATCH_WORD_CI
	JR	Z,.SET_SOFT
	LD	DE,WORD_HARD
	CALL	MATCH_WORD_CI
	JR	Z,.SET_HARD
	POP	DE
	SCF
	RET
.SET_AUTO
	LD	HL,WORD_AUTO
	JR	.COPY
.SET_SOFT
	LD	HL,WORD_SOFT
	JR	.COPY
.SET_HARD
	LD	HL,WORD_HARD
.COPY
	POP	DE
	CALL	@MAIN.COPY_ASCIIZ
	OR	A
	RET


VALIDATE_NTP
	PUSH	HL
.CHK
	LD	A,(HL)
	OR	A
	JR	Z,.OK
	CP	' '
	JR	Z,.BAD
	INC	HL
	JR	.CHK
.OK
	POP	HL
	CALL	@MAIN.COPY_ASCIIZ
	OR	A
	RET
.BAD
	POP	HL
	SCF
	RET


; VALIDATE_TZ: "[+|-]H[H][:MM]", minutes exactly two digits
; 00..59, combined offset within -12:00..+14:00.  Mirrors
; ntp.asm's PARSE_TZ_FIELDS, but rejects (rather than silently
; falls back to UTC on) anything malformed, and canonicalizes
; into (DE) instead of three separate bytes.
VALIDATE_TZ
	PUSH	DE
	XOR	A
	LD	(ST_TZ_NEG),A
	LD	(ST_TZ_HOURS),A
	LD	(ST_TZ_MINS),A
	LD	A,(HL)
	CP	'-'
	JR	Z,.ISNEG
	CP	'+'
	JR	NZ,.DIGITS
	INC	HL
	JR	.DIGITS
.ISNEG
	LD	A,1
	LD	(ST_TZ_NEG),A
	INC	HL
.DIGITS
	LD	A,(HL)
	SUB	'0'
	JP	C,.BAD
	CP	10
	JP	NC,.BAD
.HLOOP
	LD	A,(HL)
	SUB	'0'
	JR	C,.RANGE		; NUL (or anything < '0'): end, no minutes
	CP	10
	JR	NC,.CHECKCOLON
	LD	B,A
	LD	A,(ST_TZ_HOURS)
	; A third digit would make the hour >= 100 -- out of range whatever
	; it is, and the 8-bit accumulator would wrap (mod 256) instead of
	; overflowing, so "+264" would quietly become "+8".  Reject here.
	CP	10
	JP	NC,.BAD
	ADD	A,A
	LD	C,A
	ADD	A,A
	ADD	A,A
	ADD	A,C
	ADD	A,B
	LD	(ST_TZ_HOURS),A
	INC	HL
	JR	.HLOOP
.CHECKCOLON
	LD	A,(HL)
	CP	':'
	JR	NZ,.BAD
	INC	HL
	LD	A,(HL)
	SUB	'0'
	JR	C,.BAD
	CP	10
	JR	NC,.BAD
	LD	B,A
	INC	HL
	LD	A,(HL)
	SUB	'0'
	JR	C,.BAD
	CP	10
	JR	NC,.BAD
	LD	C,A
	INC	HL
	LD	A,(HL)
	OR	A
	JR	NZ,.BAD
	LD	A,B
	ADD	A,A
	LD	D,A
	ADD	A,A
	ADD	A,A
	ADD	A,D
	ADD	A,C
	CP	60
	JR	NC,.BAD
	LD	(ST_TZ_MINS),A
.RANGE
	LD	A,(ST_TZ_NEG)
	OR	A
	JR	NZ,.RANGE_NEG
	LD	A,(ST_TZ_HOURS)
	CP	15
	JR	NC,.BAD
	CP	14
	JR	NZ,.CANON
	LD	A,(ST_TZ_MINS)
	OR	A
	JR	NZ,.BAD
	JR	.CANON
.RANGE_NEG
	LD	A,(ST_TZ_HOURS)
	CP	13
	JR	NC,.BAD
	CP	12
	JR	NZ,.CANON
	LD	A,(ST_TZ_MINS)
	OR	A
	JR	NZ,.BAD
.CANON
	POP	DE
	LD	A,(ST_TZ_NEG)
	OR	A
	LD	A,'+'
	JR	Z,.WRSIGN
	LD	A,'-'
.WRSIGN
	LD	(DE),A
	INC	DE
	LD	A,(ST_TZ_HOURS)
	CALL	@MAIN.FMT_BYTE_DEC	; trashes A,BC,H; DE advances
	LD	A,(ST_TZ_MINS)
	OR	A
	JR	Z,.DONE
	LD	A,':'
	LD	(DE),A
	INC	DE
	LD	A,(ST_TZ_MINS)
	CALL	FMT_DEC2
.DONE
	XOR	A
	LD	(DE),A
	OR	A
	RET
.BAD
	POP	DE
	SCF
	RET


; FMT_DEC2: A = 0..59, write 2 zero-padded ASCII digits to
; (DE), DE += 2.  Trashes A, B.
FMT_DEC2
	LD	B,0
.LP
	CP	10
	JR	C,.GOT
	SUB	10
	INC	B
	JR	.LP
.GOT
	PUSH	AF
	LD	A,B
	ADD	A,'0'
	LD	(DE),A
	INC	DE
	POP	AF
	ADD	A,'0'
	LD	(DE),A
	INC	DE
	RET


; ------------------------------------------------------
; MATCH_WORD_CI: HL = ASCIIZ text, DE = ASCIIZ constant word
; (assumed already uppercase).  Z=1 on a case-insensitive
; exact match (HL fully consumed at the word's NUL too).
; HL, DE, BC preserved.  Trashes A.
; ------------------------------------------------------
MATCH_WORD_CI
	PUSH	HL
	PUSH	DE
	PUSH	BC
.LP
	LD	A,(DE)
	OR	A
	JR	Z,.ATEND
	LD	B,A
	LD	A,(HL)
	CP	'a'
	JR	C,.CMP
	CP	'z'+1
	JR	NC,.CMP
	AND	0xDF
.CMP
	CP	B
	JR	NZ,.MISS
	INC	HL
	INC	DE
	JR	.LP
.ATEND
	LD	A,(HL)
	OR	A
	JR	.DONE
.MISS
	OR	1
.DONE
	POP	BC
	POP	DE
	POP	HL
	RET


; ------------------------------------------------------
; STREQ: HL, DE = two ASCIIZ strings.  Z=1 if equal.
; HL, DE, BC preserved.  Trashes A.
; ------------------------------------------------------
STREQ
	PUSH	HL
	PUSH	DE
	PUSH	BC
.LP
	LD	A,(DE)
	LD	B,A
	LD	A,(HL)
	CP	B
	JR	NZ,.MISS
	OR	A
	JR	Z,.MATCH
	INC	HL
	INC	DE
	JR	.LP
.MATCH
	XOR	A
	JR	.DONE
.MISS
	OR	1
.DONE
	POP	BC
	POP	DE
	POP	HL
	RET


; ------------------------------------------------------
; SERIALIZE: build the canonical NET.CFG text (CRLF, 7-bit
; ASCII) into NETCFGW_WRITE_BUF.  Out: HL = buffer, DE = length.
; Trashes everything.
; ------------------------------------------------------
SERIALIZE
	; RTL_RESET=AUTO must go out as an EMPTY value: the parser reads an
	; absent or an empty RTL_RESET as AUTO, but any other word not
	; starting with 'S' as HARD -- so writing the literal "AUTO" would
	; read back as a board reset that hangs some clones.  Blank the
	; buffer in place; SERIALIZE is the last thing that reads it.
	LD	HL,NETCFGW_RESET
	LD	DE,WORD_AUTO
	CALL	MATCH_WORD_CI
	JR	NZ,.RESET_OK
	XOR	A
	LD	(NETCFGW_RESET),A
.RESET_OK

	LD	HL,NETCFGW_WRITE_BUF
	LD	(.CURSOR),HL
	LD	HL,MSG_HDR1		; header comments
	CALL	.PUT_S
	LD	HL,MSG_HDR2
	CALL	.PUT_S

	; One "KEY=" + value + CRLF per .TABLE entry, in file order.
	; .PUT_S / .PUT_CRLF trash only A/HL/DE, so B and IX survive.
	LD	IX,.TABLE
	LD	B,.TABLE_LEN
.KEYLOOP
	LD	L,(IX+0)
	LD	H,(IX+1)
	CALL	.PUT_S			; "KEY="
	LD	L,(IX+2)
	LD	H,(IX+3)
	CALL	.PUT_S			; value (empty string -> nothing)
	CALL	.PUT_CRLF
	LD	DE,4
	ADD	IX,DE
	DJNZ	.KEYLOOP

	LD	HL,(.CURSOR)
	LD	DE,NETCFGW_WRITE_BUF
	OR	A
	SBC	HL,DE
	EX	DE,HL			; DE = length
	LD	HL,NETCFGW_WRITE_BUF
	RET

; .PUT_S: append ASCIIZ at HL to the write buffer at .CURSOR
; (NUL not copied).  Trashes A, HL, DE.
.PUT_S
	LD	DE,(.CURSOR)
.LP
	LD	A,(HL)
	OR	A
	JR	Z,.DONE
	LD	(DE),A
	INC	HL
	INC	DE
	JR	.LP
.DONE
	LD	(.CURSOR),DE
	RET

; .PUT_CRLF: append CR LF. Trashes A, HL, DE.
.PUT_CRLF
	LD	HL,(.CURSOR)
	LD	A,13
	LD	(HL),A
	INC	HL
	LD	A,10
	LD	(HL),A
	INC	HL
	LD	(.CURSOR),HL
	RET

.CURSOR		DW 0
.K_RTL_HW	DB "RTL_HW=",0
.K_RTL_RESET	DB "RTL_RESET=",0
.K_RTL_TYPE	DB "RTL_TYPE=",0
.K_RTL_MAC	DB "RTL_MAC=",0
.K_IP		DB "IP=",0
.K_NETMASK	DB "NETMASK=",0
.K_GATEWAY	DB "GATEWAY=",0
.K_DNS1		DB "DNS1=",0
.K_DNS2		DB "DNS2=",0
.K_TZ		DB "TZ=",0
.K_NTP		DB "NTP=",0

; Canonical file order: {key text, value buffer} per line.
.TABLE
	DW	.K_RTL_HW,    NETCFGW_HW
	DW	.K_RTL_RESET, NETCFGW_RESET
	DW	.K_RTL_TYPE,  NETCFGW_TYPE
	DW	.K_RTL_MAC,   NETCFGW_MAC
	DW	.K_IP,        NETCFGW_IP
	DW	.K_NETMASK,   NETCFGW_MASK
	DW	.K_GATEWAY,   NETCFGW_GW
	DW	.K_DNS1,      NETCFGW_DNS1
	DW	.K_DNS2,      NETCFGW_DNS2
	DW	.K_TZ,        NETCFGW_TZ
	DW	.K_NTP,       NETCFGW_NTP
.TABLE_LEN	EQU 11


; ------------------------------------------------------
; SAVE: write NETCFGW_WRITE_BUF (already SERIALIZEd, HL/DE
; from the call above) to NET.CFG.  DSS_CREATE_OVERWRITE does
; not truncate an existing (longer) file, so DELETE first,
; ignoring its error (file may not exist yet).
;   In: HL = buffer, DE = length.
;   Out: CF=0 success; CF=1, A=EX_FILE_ERR.
; ------------------------------------------------------
SAVE
	PUSH	HL
	PUSH	DE
	CALL	@NETCFG.BUILD_CFG_PATH
	LD	(ST_PATH_PTR),HL
	LD	HL,(ST_PATH_PTR)
	LD	C,DSS_DELETE
	RST	DSS
	LD	HL,(ST_PATH_PTR)
	LD	A,FA_ARCHIVE
	LD	C,DSS_CREATE_OVERWRITE
	RST	DSS
	JR	C,.FAIL_CREATE		; HL/DE (buffer/length) still on the stack
	LD	(.FH),A
	POP	DE			; length
	POP	HL			; buffer -- stack now balanced
	LD	A,(.FH)
	LD	C,DSS_WRITE		; HL=source, DE=count, A=handle
	RST	DSS
	JR	C,.FAIL_CLOSE
	LD	A,(.FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	JR	C,.FAIL_NOPOP
	PRINTLN	MSG_SAVED
	OR	A
	RET
.FAIL_CLOSE
	PUSH	AF
	LD	A,(.FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	POP	AF
.FAIL_NOPOP			; HL/DE already popped above -- do not pop again
	PRINTLN	MSG_SAVE_FAILED
	LD	A,EX_FILE_ERR
	SCF
	RET
.FAIL_CREATE
	POP	DE
	POP	HL
	PRINTLN	MSG_SAVE_FAILED
	LD	A,EX_FILE_ERR
	SCF
	RET
.FH		DB 0


; ------------------------------------------------------
; Static data
; ------------------------------------------------------
MSG_LBL_RTL_HW		DB "RTL_HW",0
MSG_LBL_RTL_RESET	DB "RTL_RESET",0
MSG_LBL_RTL_TYPE	DB "RTL_TYPE",0
MSG_LBL_RTL_MAC		DB "RTL_MAC",0
MSG_LBL_IP		DB "IP",0
MSG_LBL_NETMASK		DB "NETMASK",0
MSG_LBL_GATEWAY		DB "GATEWAY",0
MSG_LBL_DNS1		DB "DNS1",0
MSG_LBL_DNS2		DB "DNS2",0
MSG_LBL_TZ		DB "TZ",0
MSG_LBL_NTP		DB "NTP",0
MSG_BRACKET_OPEN	DB " [",0
MSG_BRACKET_COLON	DB "]: ",0
MSG_INVALID		DB "  invalid value, try again.",0
MSG_TOO_LONG		DB "  too long, try again.",0
MSG_CANCELLED		DB "Cancelled -- NET.CFG left unchanged.",0
MSG_UNREADABLE		DB "[E] NET.CFG exists but could not be read; not overwriting it.",0
MSG_SAVED		DB "NET.CFG written.  Run NETCFG -i to apply.",0
MSG_SAVE_FAILED		DB "[E] could not write NET.CFG.",0
MSG_PROBE_Q		DB "Probe for the card now ",0
MSG_PROBE_DEF_Y		DB "[Y/n]? ",0
MSG_PROBE_DEF_N		DB "[y/N]? ",0
MSG_PROBE_WARN_HARD	DB 13,10
			DB "WARNING: RTL_RESET is HARD, so the probe pulses the reset port.",13,10
			DB "If the computer freezes here: reboot, run NETCFG -w again and",13,10
			DB "choose AUTO or SOFT.",13,10,0
MSG_PROBE_FOUND		DB "Found: MAC=",0
MSG_PROBE_FAILED	DB "Probe failed; set RTL_HW by hand.",0
MSG_EMPTY		DB 0

; Hints.  Each starts with a blank line and ends with CRLF, so it reads
; as a paragraph above its "LABEL [default]: " prompt.  Lines stay under
; 80 columns.  7-bit ASCII only.
MSG_INTRO	DB "Enter keeps the [current] value, ",34,"-",34," clears an optional one, Esc",13,10
		DB "quits without saving.  Nothing is written until the last answer.",0
HINT_RESET	DB 13,10
		DB "How the card is reset each time a network program starts:",13,10
		DB "  AUTO - decide by chip type (recommended, safe on every card)",13,10
		DB "  SOFT - never touch the board reset port",13,10
		DB "  HARD - always pulse it.  This FREEZES the computer on some",13,10
		DB "         NE2000 clones (e.g. UMC UM9003); only for a card that",13,10
		DB "         does not work with AUTO.",13,10,0
HINT_PROBE	DB 13,10
		DB "The probe looks for the card and reads its MAC address.  It is",13,10
		DB "safe here: AUTO pulses the reset port only on a genuine Realtek",13,10
		DB "chip, SOFT never does.",13,10,0
HINT_HW		DB 13,10
		DB "ISA slot and I/O base of the card as S/#HHH, e.g. 1/#300.",13,10
		DB "Empty = find the card automatically at every start.",13,10,0
HINT_TYPE	DB 13,10
		DB "Packet RAM layout: NE1000, NE2000, or AUTO/empty to detect it.",13,10
		DB "Use NE1000 for an 8 KB card whose RAM starts at page 20h.",13,10,0
HINT_MAC	DB 13,10
		DB "MAC address override, aa:bb:cc:dd:ee:ff.  Leave empty to use",13,10
		DB "the card's own address (recommended).",13,10,0
HINT_IP		DB 13,10
		DB "IP address of this computer, e.g. 192.168.1.50 -- or DHCP to get",13,10
		DB "the address, mask, gateway and DNS from the router automatically.",13,10,0
HINT_MASK	DB 13,10
		DB "Network mask, usually 255.255.255.0.",13,10,0
HINT_GW		DB 13,10
		DB "Gateway: the router's address, e.g. 192.168.1.1.  Needed to reach",13,10
		DB "anything outside the local network.",13,10,0
HINT_DNS1	DB 13,10
		DB "DNS server, needed for host names: e.g. 1.1.1.1, or the router.",13,10,0
HINT_DNS2	DB 13,10
		DB "Second DNS server (optional).",13,10,0
HINT_TZ		DB 13,10
		DB "Local time as an offset from UTC: +3, -5, +5:30.  Empty = UTC.",13,10,0
HINT_NTP	DB 13,10
		DB "Time server for NTP.EXE: a host name or an IP address.",13,10,0
MSG_HDR1		DB "# NET.CFG -- written by NETCFG -w.  Run NETCFG -i to apply.",13,10,0
MSG_HDR2		DB "# Empty value = not set.  RTL_RESET empty = AUTO (driver decides).",13,10,0
LINE_END		DB 13,10,0

	ENDIF

	ENDMODULE
	ENDIF
