; ======================================================
; NET.CFG parser for the Sprinter RTL8019AS network kit.
;
; Loads the DSS file `NET.CFG` from the current directory
; and parses recognized keys into binary fields. Defaults are
; applied first, so a missing or unparseable file leaves the
; module in a sane state.
;
; Recognized keys (one per line, "KEY=value", `#` = comment):
;   IP, NETMASK, GATEWAY, DNS1, DNS2 -- dotted IPv4.
;   RTL_MAC                          -- aa:bb:cc:dd:ee:ff (empty
;                                       value -> default MAC).
;   TZ                               -- signed integer hours.
;   NTP                              -- ASCIIZ host (<=31 chars).
;
; Output (module data):
;   NETCFG.OUR_MAC   (6 bytes)
;   NETCFG.OUR_IP    (4 bytes)
;   NETCFG.NETMASK   (4 bytes)
;   NETCFG.GATEWAY   (4 bytes)
;   NETCFG.DNS1      (4 bytes)
;   NETCFG.DNS2      (4 bytes)
;   NETCFG.NTP       (32 bytes ASCIIZ)
;   NETCFG.TZ        (signed byte)
;
; Public API:
;   NETCFG.LOAD          read+parse NET.CFG. CF=0 file ok,
;                        CF=1 missing/error (defaults still
;                        applied).
;
; Wrap callsites in `DEFINE USE_NETCFG_LOAD` before
; `INCLUDE "netcfg_lib.asm"` so the body is emitted only in
; apps that need it.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_NETCFG
	DEFINE	_NETCFG

	INCLUDE "memmap.inc"

	IFDEF USE_NETCFG_LOAD
; Transitive util-helper deps. IFNDEF guards keep multipass quiet.
	IFNDEF USE_UTIL_STARTSWITH
	DEFINE USE_UTIL_STARTSWITH
	ENDIF
	IFNDEF USE_UTIL_PARSE_DEC_BYTE
	DEFINE USE_UTIL_PARSE_DEC_BYTE
	ENDIF
	IFNDEF USE_UTIL_PARSE_HEX_BYTE
	DEFINE USE_UTIL_PARSE_HEX_BYTE
	ENDIF
	ENDIF

NETCFG_BUF_SIZE	EQU 1024

	MODULE NETCFG

	IFDEF USE_NETCFG_LOAD

; -------- output fields & internals --------
; All NETCFG buffers live in runtime BSS (memmap.inc), NOT
; the .EXE.  APPLY_DEFAULTS / LOAD always write before read.
OUR_MAC		EQU NETCFG_OUR_MAC
OUR_IP		EQU NETCFG_OUR_IP
NETMASK		EQU NETCFG_NETMASK
GATEWAY		EQU NETCFG_GATEWAY
DNS1		EQU NETCFG_DNS1
DNS2		EQU NETCFG_DNS2
NTP		EQU NETCFG_NTP
TZ		EQU NETCFG_TZ
LOAD_FH		EQU NETCFG_LOAD_FH
LOAD_BUF	EQU NETCFG_LOAD_BUF


; ------------------------------------------------------
; LOAD: applies defaults, then reads NET.CFG from current
; directory and overrides fields parsed from it.
;   Out: CF=0 file present and read OK.
;        CF=1 file missing or read error (defaults remain).
; ------------------------------------------------------
LOAD
	CALL	APPLY_DEFAULTS
	; Open NET.CFG read-only.
	LD	HL,.FILENAME
	LD	A,FM_READ
	LD	C,DSS_OPEN_FILE
	RST	DSS
	RET	C
	LD	(LOAD_FH),A
	; Read up to NETCFG_BUF_SIZE-1 bytes.
	LD	HL,LOAD_BUF
	LD	DE,NETCFG_BUF_SIZE - 1
	LD	C,DSS_READ_FILE
	RST	DSS
	JR	C,.READ_ERR
	; DE holds actual bytes read. Null-terminate at end.
	LD	HL,LOAD_BUF
	ADD	HL,DE
	LD	(HL),0
	; Close.
	LD	A,(LOAD_FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	; Parse buffer.
	LD	HL,LOAD_BUF
	CALL	PARSE
	OR	A			; CF=0
	RET
.READ_ERR
	PUSH	AF
	LD	A,(LOAD_FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	POP	AF
	SCF
	RET

.FILENAME	DB "NET.CFG",0


; ------------------------------------------------------
; APPLY_DEFAULTS: copy hardcoded defaults into the output
; fields. Called by LOAD before parsing.
; ------------------------------------------------------
APPLY_DEFAULTS
	LD	HL,.D_MAC
	LD	DE,OUR_MAC
	LD	BC,6
	LDIR
	LD	HL,.D_IP
	LD	DE,OUR_IP
	LD	BC,4
	LDIR
	LD	HL,.D_NETMASK
	LD	DE,NETMASK
	LD	BC,4
	LDIR
	LD	HL,.D_GATEWAY
	LD	DE,GATEWAY
	LD	BC,4
	LDIR
	LD	HL,.D_DNS1
	LD	DE,DNS1
	LD	BC,4
	LDIR
	LD	HL,.D_DNS2
	LD	DE,DNS2
	LD	BC,4
	LDIR
	LD	HL,.D_NTP
	LD	DE,NTP
	LD	BC,13			; "pool.ntp.org" + null
	LDIR
	LD	A,3
	LD	(TZ),A
	RET

.D_MAC		DB 0x02, 0x80, 0x19, 0x11, 0x22, 0x33
.D_IP		DB 192, 168, 7, 2
.D_NETMASK	DB 255, 255, 255, 0
.D_GATEWAY	DB 192, 168, 7, 1
.D_DNS1		DB 1, 1, 1, 1
.D_DNS2		DB 8, 8, 8, 8
.D_NTP		DB "pool.ntp.org",0


; ------------------------------------------------------
; PARSE: walks the zero-terminated buffer at HL line by
; line, dispatching to per-key handlers.
; ------------------------------------------------------
PARSE
.LINE
	; Skip leading whitespace.
	CALL	SKIP_WS
	LD	A,(HL)
	OR	A
	RET	Z
	CP	13
	JR	Z,.NEXT
	CP	10
	JR	Z,.NEXT
	CP	'#'
	JR	Z,.SKIP

	; Try each key.
	LD	DE,.K_IP
	CALL	@UTIL.STARTSWITH
	JR	Z,.IP
	LD	DE,.K_NETMASK
	CALL	@UTIL.STARTSWITH
	JR	Z,.NETMASK
	LD	DE,.K_GATEWAY
	CALL	@UTIL.STARTSWITH
	JR	Z,.GATEWAY
	LD	DE,.K_DNS1
	CALL	@UTIL.STARTSWITH
	JR	Z,.DNS1
	LD	DE,.K_DNS2
	CALL	@UTIL.STARTSWITH
	JR	Z,.DNS2
	LD	DE,.K_MAC
	CALL	@UTIL.STARTSWITH
	JR	Z,.MAC
	LD	DE,.K_TZ
	CALL	@UTIL.STARTSWITH
	JR	Z,.TZ
	LD	DE,.K_NTP
	CALL	@UTIL.STARTSWITH
	JP	Z,.NTPLINE

.SKIP
	CALL	SKIP_TO_NEXT_LINE
	JP	.LINE
.NEXT
	INC	HL
	JP	.LINE

.IP
	LD	BC,3			; len("IP=")
	ADD	HL,BC
	LD	DE,OUR_IP
	CALL	PARSE_IPV4_LINE
	JP	.LINE
.NETMASK
	LD	BC,8
	ADD	HL,BC
	LD	DE,NETMASK
	CALL	PARSE_IPV4_LINE
	JP	.LINE
.GATEWAY
	LD	BC,8
	ADD	HL,BC
	LD	DE,GATEWAY
	CALL	PARSE_IPV4_LINE
	JP	.LINE
.DNS1
	LD	BC,5
	ADD	HL,BC
	LD	DE,DNS1
	CALL	PARSE_IPV4_LINE
	JP	.LINE
.DNS2
	LD	BC,5
	ADD	HL,BC
	LD	DE,DNS2
	CALL	PARSE_IPV4_LINE
	JP	.LINE
.MAC
	LD	BC,8			; len("RTL_MAC=")
	ADD	HL,BC
	LD	DE,OUR_MAC
	CALL	PARSE_MAC_LINE
	JP	.LINE
.TZ
	LD	BC,3			; len("TZ=")
	ADD	HL,BC
	CALL	PARSE_TZ_LINE
	JP	.LINE
.NTPLINE
	LD	BC,4			; len("NTP=")
	ADD	HL,BC
	LD	DE,NTP
	LD	B,31
	CALL	COPY_VALUE
	JP	.LINE

.K_IP		DB "IP=",0
.K_NETMASK	DB "NETMASK=",0
.K_GATEWAY	DB "GATEWAY=",0
.K_DNS1		DB "DNS1=",0
.K_DNS2		DB "DNS2=",0
.K_MAC		DB "RTL_MAC=",0
.K_TZ		DB "TZ=",0
.K_NTP		DB "NTP=",0


; ------------------------------------------------------
; SKIP_WS: advance HL past spaces/tabs (but stop at CR/LF/0).
; ------------------------------------------------------
SKIP_WS
	LD	A,(HL)
	CP	' '
	JR	Z,.S
	CP	9
	RET	NZ
.S
	INC	HL
	JR	SKIP_WS

; ------------------------------------------------------
; SKIP_TO_NEXT_LINE: advance HL past current line (until
; CR/LF or terminator). Handles CR, LF, CR+LF.
; ------------------------------------------------------
SKIP_TO_NEXT_LINE
	LD	A,(HL)
	OR	A
	RET	Z
	CP	10
	JR	Z,.SAW10
	CP	13
	JR	Z,.SAW13
	INC	HL
	JR	SKIP_TO_NEXT_LINE
.SAW13
	INC	HL
	LD	A,(HL)
	CP	10
	RET	NZ
.SAW10
	INC	HL
	RET


; ------------------------------------------------------
; PARSE_IPV4_LINE: HL points just past "KEY=" of a config
; line; DE points at 4-byte destination.
;   On invalid input the destination is left untouched.
;   HL is left pointing somewhere after the line (.LINE
;   loop will skip remaining bytes).
; ------------------------------------------------------
PARSE_IPV4_LINE
	; Save dest -- we'll only commit on full parse success.
	PUSH	DE
	LD	BC,4
	; tmp byte buffer at TMP_IP
	LD	DE,.TMP_IP
.LP
	CALL	@UTIL.PARSE_DEC_BYTE
	JR	C,.BAD
	LD	(DE),A
	INC	DE
	DEC	BC
	LD	A,B
	OR	C
	JR	Z,.DONE
	; Expect '.'
	LD	A,(HL)
	CP	'.'
	JR	NZ,.BAD
	INC	HL
	JR	.LP
.DONE
	; Copy TMP_IP -> caller's dest.
	POP	DE
	LD	HL,.TMP_IP
	LD	BC,4
	LDIR
	JP	SKIP_TO_NEXT_LINE
.BAD
	POP	DE
	JP	SKIP_TO_NEXT_LINE

.TMP_IP		EQU NETCFG_TMP_IP	; 4 bytes in runtime BSS


; ------------------------------------------------------
; PARSE_MAC_LINE: HL points just past "RTL_MAC=" of a line;
; DE points at 6-byte destination. Empty value (CR/LF/0
; immediately) leaves destination untouched (default kept).
; ------------------------------------------------------
PARSE_MAC_LINE
	; If first char is end-of-line, value empty -> keep default.
	LD	A,(HL)
	OR	A
	JR	Z,.SKIP
	CP	13
	JR	Z,.SKIP
	CP	10
	JR	Z,.SKIP

	PUSH	DE
	LD	BC,6
	LD	DE,.TMP_MAC
.LP
	CALL	@UTIL.PARSE_HEX_BYTE
	JR	C,.BAD
	LD	(DE),A
	INC	DE
	DEC	BC
	LD	A,B
	OR	C
	JR	Z,.DONE
	LD	A,(HL)
	CP	':'
	JR	NZ,.BAD
	INC	HL
	JR	.LP
.DONE
	POP	DE
	LD	HL,.TMP_MAC
	LD	BC,6
	LDIR
	JP	SKIP_TO_NEXT_LINE
.BAD
	POP	DE
.SKIP
	JP	SKIP_TO_NEXT_LINE

.TMP_MAC	EQU NETCFG_TMP_MAC	; 6 bytes in runtime BSS


; ------------------------------------------------------
; PARSE_TZ_LINE: HL just past "TZ=", parse signed integer
; (-12..14) into NETCFG.TZ.
; ------------------------------------------------------
PARSE_TZ_LINE
	LD	A,(HL)
	CP	'+'
	JR	Z,.POS
	CP	'-'
	JR	Z,.NEG
	; No sign -> positive
	CALL	@UTIL.PARSE_DEC_BYTE
	JR	C,.SKIP
	LD	(TZ),A
	JP	SKIP_TO_NEXT_LINE
.POS
	INC	HL
	CALL	@UTIL.PARSE_DEC_BYTE
	JR	C,.SKIP
	LD	(TZ),A
	JP	SKIP_TO_NEXT_LINE
.NEG
	INC	HL
	CALL	@UTIL.PARSE_DEC_BYTE
	JR	C,.SKIP
	NEG
	LD	(TZ),A
	JP	SKIP_TO_NEXT_LINE
.SKIP
	JP	SKIP_TO_NEXT_LINE


; ------------------------------------------------------
; COPY_VALUE: copy ASCIIZ value into (DE), max B bytes,
; null-terminated. Stops at CR, LF, 0. HL ends pointing at
; the first non-value byte; SKIP_TO_NEXT_LINE will reach
; the next line on next iteration.
; ------------------------------------------------------
COPY_VALUE
.LP
	LD	A,B
	OR	A
	JR	Z,.NOROOM
	LD	A,(HL)
	OR	A
	JR	Z,.END
	CP	13
	JR	Z,.END
	CP	10
	JR	Z,.END
	LD	(DE),A
	INC	DE
	INC	HL
	DEC	B
	JR	.LP
.NOROOM
	; advance HL past oversize value remainder
	LD	A,(HL)
	OR	A
	JR	Z,.END
	CP	13
	JR	Z,.END
	CP	10
	JR	Z,.END
	INC	HL
	JR	.NOROOM
.END
	XOR	A
	LD	(DE),A			; null terminator
	RET

	ENDIF

	ENDMODULE
	ENDIF
