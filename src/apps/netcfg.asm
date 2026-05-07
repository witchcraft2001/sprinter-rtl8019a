; ======================================================
; NETCFG.EXE - read NET.CFG and publish parsed values into
; DSS environment variables, or display them.
;
; Usage:
;   NETCFG          show current NET_* env values
;   NETCFG -i       init: load NET.CFG, populate NET_* env
;   NETCFG -c       check NET.CFG syntax (exit 4 on error)
;   NETCFG -d       delete all NET_* env vars
;   NETCFG /? -? -h help
;
; Exit codes:
;   0   OK
;   1   usage error
;   4   NET.CFG missing or invalid (only with -i / -c)
;
; This is the only utility in the kit that touches NET.CFG.
; All other tools read NET_* env vars via netenv_lib.
; ======================================================

EXE_VERSION	EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "memmap.inc"
	INCLUDE "rtl8019.inc"		; for PROM read fallback

	DEFINE USE_NETCFG_LOAD
	DEFINE USE_UTIL_EXIT

	MODULE MAIN

	ORG 0x8080

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0080
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START
	DW START
	DW STACK_TOP
	DS 106, 0

	ORG 0x8100
@STACK_TOP

CMDLINE_BUF	EQU 0x8080		; DSS overwrites EXE header with cmd line
					; after entry: byte 0 = length, then ASCIIZ.

START
	PRINTLN MSG_BANNER

	CALL	PARSE_FLAG
	; A = action code (0=show, 'i'=init, 'c'=check, 'd'=delete, '?'=help, 0xFF=usage err)
	CP	0xFF
	JP	Z,USAGE_ERROR
	CP	'?'
	JP	Z,SHOW_HELP
	CP	'i'
	JP	Z,DO_INIT
	CP	'c'
	JP	Z,DO_CHECK
	CP	'd'
	JP	Z,DO_DELETE
	; Default: show
	JP	DO_SHOW


; ------------------------------------------------------
; PARSE_FLAG: scan command line for first "-x" or "/x".
;   Out: A = lowercased flag char ('i','c','d','v','h')
;        A = '?' for help (any of /? -? /h -h)
;        A = 0  if no flag
;        A = 0xFF for unknown / malformed
;
; Only the first flag found is honored. Subsequent tokens
; are ignored to keep the parser tiny.
; ------------------------------------------------------
PARSE_FLAG
	LD	HL,CMDLINE_BUF
	LD	A,(HL)
	OR	A
	RET	Z			; no args
	LD	B,A			; B = remaining length
	INC	HL
.SCAN
	LD	A,B
	OR	A
	JR	Z,.NONE
	LD	A,(HL)
	OR	A
	JR	Z,.NONE
	CP	' '
	JR	Z,.SKIP
	CP	9
	JR	Z,.SKIP
	CP	'-'
	JR	Z,.GOTPFX
	CP	'/'
	JR	Z,.GOTPFX
	; Non-flag token: skip word.
	JR	.SKIPWORD
.SKIP
	INC	HL
	DEC	B
	JR	.SCAN
.SKIPWORD
	INC	HL
	DEC	B
	JR	Z,.NONE
	LD	A,(HL)
	OR	A
	JR	Z,.NONE
	CP	' '
	JR	Z,.SCAN
	CP	9
	JR	Z,.SCAN
	JR	.SKIPWORD
.GOTPFX
	INC	HL
	DEC	B
	JR	Z,.BAD
	LD	A,(HL)
	; Help shortcut: '?' or 'h'
	CP	'?'
	JR	Z,.HELP
	CP	'H'
	JR	Z,.HELP
	CP	'h'
	JR	Z,.HELP
	; Lowercase A-Z
	CP	'A'
	JR	C,.BAD
	CP	'Z'+1
	JR	C,.LOWER
	CP	'a'
	JR	C,.BAD
	CP	'z'+1
	JR	NC,.BAD
	JR	.OK
.LOWER
	ADD	A,'a'-'A'
.OK
	; Validate known flags: i, c, d, v
	CP	'i'
	JR	Z,.RET
	CP	'c'
	JR	Z,.RET
	CP	'd'
	JR	Z,.RET
	CP	'v'
	JR	Z,.RET
	; unknown flag
.BAD
	LD	A,0xFF
	RET
.HELP
	LD	A,'?'
	RET
.NONE
	XOR	A
	RET
.RET
	RET


; ------------------------------------------------------
; DO_SHOW: GETENV each NET_* var; print "NAME : value".
; Missing values printed as <not set>.
; ------------------------------------------------------
DO_SHOW
	PRINTLN MSG_SHOW_HDR
	LD	HL,VAR_TABLE
.LP
	LD	A,(HL)			; first byte of name = 0 -> table end
	OR	A
	JP	Z,@UTIL.EXIT_OK
	PUSH	HL			; -- save var name ptr (PRINT macro trashes HL) --
	; Print "  "
	LD	HL,MSG_INDENT
	LD	C,DSS_PCHARS
	RST	DSS
	; Print var name
	POP	HL
	PUSH	HL
	LD	C,DSS_PCHARS
	RST	DSS
	; Pad to column 12
	POP	HL
	PUSH	HL
	CALL	PAD_COL_12
	; Print " : "
	LD	HL,MSG_COLON
	LD	C,DSS_PCHARS
	RST	DSS
	; GETENV (HL = name from stack, kept for next iteration)
	POP	HL
	PUSH	HL
	LD	DE,SHOW_VAL_BUF
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	OR	A
	JR	Z,.UNSET
	LD	HL,SHOW_VAL_BUF
	LD	A,(HL)
	OR	A
	JR	Z,.UNSET
	LD	C,DSS_PCHARS
	RST	DSS
	JR	.NL
.UNSET
	LD	HL,MSG_NOT_SET
	LD	C,DSS_PCHARS
	RST	DSS
.NL
	LD	HL,LINE_END
	LD	C,DSS_PCHARS
	RST	DSS
	; Advance HL past current name's NUL.
	POP	HL
.NEXT
	LD	A,(HL)
	INC	HL
	OR	A
	JR	NZ,.NEXT
	JR	.LP


; PAD_COL_12: print spaces until printed name reaches 12 chars.
; HL = name ptr (preserved). Trashes A,BC.
PAD_COL_12
	PUSH	HL
	LD	B,0			; counter = strlen(name)
.CNT
	LD	A,(HL)
	OR	A
	JR	Z,.PAD
	INC	HL
	INC	B
	JR	.CNT
.PAD
	LD	A,12
	SUB	B
	JR	C,.DONE
	JR	Z,.DONE
	LD	B,A
.SP
	LD	A,' '
	PUSH	BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC
	DJNZ	.SP
.DONE
	POP	HL
	RET


; ------------------------------------------------------
; DO_DELETE: SETENV "<NAME>=" for each var to remove.
; ------------------------------------------------------
DO_DELETE
	PRINTLN MSG_DELETING
	LD	HL,VAR_TABLE
.LP
	LD	A,(HL)
	OR	A
	JP	Z,@UTIL.EXIT_OK
	; Build "<NAME>=" in SET_BUF.
	LD	DE,SET_BUF
	CALL	COPY_ASCIIZ		; HL -> next-after-NUL, DE -> after copy
	; Replace the trailing NUL we just wrote with '=' then NUL.
	DEC	DE
	LD	A,'='
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	; SETENV "<NAME>="
	PUSH	HL
	LD	HL,SET_BUF
	LD	B,ENV_SET
	LD	C,DSS_ENVIRON
	RST	DSS
	POP	HL
	JR	.LP


; COPY_ASCIIZ: copy ASCIIZ from HL to DE inclusive of \0.
; Out: HL = past terminator of source; DE = past terminator
; in dest. Trashes A.
COPY_ASCIIZ
.L
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	OR	A
	JR	NZ,.L
	RET


; ------------------------------------------------------
; DO_CHECK: call NETCFG.LOAD; on failure exit 4.
; ------------------------------------------------------
DO_CHECK
	CALL	@NETCFG.LOAD
	JR	C,.MISS
	PRINTLN MSG_CHECK_OK
	JP	@UTIL.EXIT_OK
.MISS
	PRINTLN MSG_CHECK_MISS
	LD	B,4
	JP	@UTIL.EXIT_FAIL


; ------------------------------------------------------
; DO_INIT: load NET.CFG, push values into env vars,
; print summary.
; ------------------------------------------------------
DO_INIT
	PRINTLN MSG_INITIALIZING
	CALL	@NETCFG.LOAD
	JP	C,.MISS
	; If NET.CFG had no RTL_MAC= line (or it was empty), the MAC
	; field is all-zero -- read the PROM and use that.  Failure
	; is non-fatal: we leave MAC zero and SETENV_MAC will delete
	; the env var, so apps that need a MAC will fail with a clear
	; "[E4] N_NET_MAC not set" diagnostic.
	CALL	FILL_MAC_FROM_PROM
	; Always push MAC, NTP, TZ.
	LD	HL,N_NET_MAC
	LD	IX,@NETCFG.OUR_MAC
	CALL	SETENV_MAC
	LD	HL,N_NET_NTP
	LD	IX,@NETCFG.NTP
	CALL	SETENV_STR
	LD	HL,N_NET_TZ
	LD	A,(@NETCFG.TZ)
	CALL	SETENV_TZ

	; IP_SRC and the IP/MASK/GW/DNS group depend on whether
	; NET.CFG asked for DHCP.
	LD	A,(@NETCFG.DHCP_MODE)
	OR	A
	JR	NZ,.DHCP_MODE

	; STATIC: SETENV NET_IP_SRC=STATIC and the four IPv4 fields.
	LD	HL,N_NET_IP_SRC
	LD	DE,V_STATIC
	CALL	SETENV_LITERAL
	LD	HL,N_NET_IP
	LD	IX,@NETCFG.OUR_IP
	CALL	SETENV_IPV4
	LD	HL,N_NET_MASK
	LD	IX,@NETCFG.NETMASK
	CALL	SETENV_IPV4
	LD	HL,N_NET_GW
	LD	IX,@NETCFG.GATEWAY
	CALL	SETENV_IPV4
	LD	HL,N_NET_DNS1
	LD	IX,@NETCFG.DNS1
	CALL	SETENV_IPV4
	LD	HL,N_NET_DNS2
	LD	IX,@NETCFG.DNS2
	CALL	SETENV_IPV4
	JR	.SHOW

.DHCP_MODE
	; DHCP: SETENV NET_IP_SRC=DHCP and clear the dynamic fields
	; (so old leases from a previous run don't linger).  IFUP
	; will populate NET_IP / NET_MASK / NET_GW / NET_DNS* / etc.
	LD	HL,N_NET_IP_SRC
	LD	DE,V_DHCP
	CALL	SETENV_LITERAL
	LD	HL,N_NET_IP
	CALL	DELETE_VAR
	LD	HL,N_NET_MASK
	CALL	DELETE_VAR
	LD	HL,N_NET_GW
	CALL	DELETE_VAR
	LD	HL,N_NET_DNS1
	CALL	DELETE_VAR
	LD	HL,N_NET_DNS2
	CALL	DELETE_VAR

.SHOW
	PRINT LINE_END
	JP	DO_SHOW
.MISS
	PRINTLN MSG_INIT_MISS
	LD	B,4
	JP	@UTIL.EXIT_FAIL


; ------------------------------------------------------
; FILL_MAC_FROM_PROM: if the parsed MAC field is all zero
; (no RTL_MAC line in NET.CFG), find the chip on ISA slot
; 1 or 0, read 32 bytes of PROM, detect direct vs doubled
; layout (each byte aliased twice in 16-bit-mode PROM read),
; and copy bytes 0..5 of the resulting MAC into NETCFG's
; OUR_MAC field.  Failure is silent.
; ------------------------------------------------------
FILL_MAC_FROM_PROM
	; Already configured?  Skip.
	LD	HL,@NETCFG.OUR_MAC
	LD	A,(HL)
	INC	HL
	OR	(HL)
	INC	HL
	OR	(HL)
	INC	HL
	OR	(HL)
	INC	HL
	OR	(HL)
	INC	HL
	OR	(HL)
	RET	NZ
	; INIT_BASE handles ISA slot 1 then 0 and base auto-scan;
	; on success ISA stays open with the right slot/base set.
	LD	A,1
	LD	(@ISA.ISA_SLOT),A
	CALL	@RTL.INIT_BASE
	RET	C			; no chip; silently leave MAC zero
	CALL	@RTL.RESET
	JR	C,.CLOSE
	; Set DCR=0x48 directly via the new IX-relative base.
	; (RTL_BASE_PTR is already populated by INIT_BASE.)
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_DCR_OFF),DCR_INIT
	; Reuse NETCFG_LOAD_BUF as the 32-byte PROM scratch.  By
	; this point NET.CFG has already been parsed so the buffer
	; is no longer needed.
	LD	HL,NETCFG_LOAD_BUF
	CALL	@RTL.READ_PROM
	JR	C,.CLOSE
	; Detect doubled layout: PROM[0]==PROM[1].
	LD	HL,NETCFG_LOAD_BUF
	LD	A,(HL)
	INC	HL
	CP	(HL)
	JR	NZ,.DIRECT
	; Doubled: copy PROM[0,2,4,6,8,10] -> OUR_MAC.
	LD	HL,NETCFG_LOAD_BUF
	LD	DE,@NETCFG.OUR_MAC
	LD	B,6
.DBL_LP
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	HL
	INC	DE
	DJNZ	.DBL_LP
	JR	.CLOSE
.DIRECT
	; Direct: PROM[0..5] -> OUR_MAC.
	LD	HL,NETCFG_LOAD_BUF
	LD	DE,@NETCFG.OUR_MAC
	LD	BC,6
	LDIR
.CLOSE
	CALL	@ISA.ISA_CLOSE
	RET


; ------------------------------------------------------
; DELETE_VAR: SETENV "<NAME>=" to remove the entry.
;   In: HL = ASCIIZ name.
; ------------------------------------------------------
DELETE_VAR
	LD	DE,SET_BUF
	CALL	COPY_ASCIIZ
	DEC	DE
	LD	A,'='
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	LD	HL,SET_BUF
	LD	B,ENV_SET
	LD	C,DSS_ENVIRON
	RST	DSS
	RET


; ------------------------------------------------------
; SETENV_IPV4: build "NAME=A.B.C.D" in SET_BUF, SETENV.
;   In: HL = ASCIIZ name; IX = 4-byte IP.
;   If the IP is 0.0.0.0 (i.e. not configured by NET.CFG and
;   not pre-loaded with a default), DELETE the env var instead
;   of publishing "0.0.0.0", so DO_SHOW marks the field as
;   "<not set>" and downstream apps see N_NET_x missing.
;   Trashes A, BC, DE, HL.
; ------------------------------------------------------
SETENV_IPV4
	; Check for all-zero IP.
	LD	A,(IX+0)
	OR	(IX+1)
	OR	(IX+2)
	OR	(IX+3)
	JR	NZ,.NONZERO
	; Zero IP -> delete the var.  HL still = name.
	JP	DELETE_VAR
.NONZERO
	LD	DE,SET_BUF
	CALL	COPY_ASCIIZ
	DEC	DE			; back over NUL
	LD	A,'='
	LD	(DE),A
	INC	DE
	; Format 4 dotted decimals.
	LD	B,4
.LP
	LD	A,(IX+0)
	PUSH	BC
	CALL	FMT_BYTE_DEC		; trashes BC -- save loop counter
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
	; SETENV
	LD	HL,SET_BUF
	LD	B,ENV_SET
	LD	C,DSS_ENVIRON
	RST	DSS
	RET


; ------------------------------------------------------
; SETENV_MAC: build "NAME=aa:bb:cc:dd:ee:ff" then SETENV.
;   In: HL = name; IX = 6-byte MAC.
;   All-zero MAC -> delete env var (treat as "not configured").
; ------------------------------------------------------
SETENV_MAC
	LD	A,(IX+0)
	OR	(IX+1)
	OR	(IX+2)
	OR	(IX+3)
	OR	(IX+4)
	OR	(IX+5)
	JR	NZ,.NONZERO
	JP	DELETE_VAR
.NONZERO
	LD	DE,SET_BUF
	CALL	COPY_ASCIIZ
	DEC	DE
	LD	A,'='
	LD	(DE),A
	INC	DE
	LD	B,6
.LP
	LD	A,(IX+0)
	CALL	FMT_BYTE_HEX		; 2 lowercase hex digits at DE, DE += 2
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
	LD	HL,SET_BUF
	LD	B,ENV_SET
	LD	C,DSS_ENVIRON
	RST	DSS
	RET


; ------------------------------------------------------
; SETENV_STR: build "NAME=value" using ASCIIZ source at IX.
;   In: HL = name; IX = ASCIIZ value.
;   Empty value -> delete the env var (treat as "not set").
; ------------------------------------------------------
SETENV_STR
	LD	A,(IX+0)
	OR	A
	JP	Z,DELETE_VAR
	LD	DE,SET_BUF
	CALL	COPY_ASCIIZ
	DEC	DE
	LD	A,'='
	LD	(DE),A
	INC	DE
.LP
	LD	A,(IX+0)
	LD	(DE),A
	INC	IX
	INC	DE
	OR	A
	JR	NZ,.LP
	LD	HL,SET_BUF
	LD	B,ENV_SET
	LD	C,DSS_ENVIRON
	RST	DSS
	RET


; ------------------------------------------------------
; SETENV_LITERAL: build "NAME=DE..." using ASCIIZ DE.
;   In: HL = name; DE = ASCIIZ value.
; ------------------------------------------------------
SETENV_LITERAL
	PUSH	DE
	LD	DE,SET_BUF
	CALL	COPY_ASCIIZ
	DEC	DE
	LD	A,'='
	LD	(DE),A
	INC	DE
	POP	HL			; HL = source value
.LP
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	OR	A
	JR	NZ,.LP
	LD	HL,SET_BUF
	LD	B,ENV_SET
	LD	C,DSS_ENVIRON
	RST	DSS
	RET


; ------------------------------------------------------
; SETENV_TZ: build "NAME=+N" or "NAME=-N" from signed A.
;   In: HL = name; A = signed byte.
; ------------------------------------------------------
SETENV_TZ
	LD	C,A			; preserve value
	LD	DE,SET_BUF
	CALL	COPY_ASCIIZ
	DEC	DE
	LD	A,'='
	LD	(DE),A
	INC	DE
	LD	A,C
	BIT	7,A
	JR	NZ,.NEG
	LD	A,'+'
	LD	(DE),A
	INC	DE
	LD	A,C
	JR	.WR
.NEG
	LD	A,'-'
	LD	(DE),A
	INC	DE
	LD	A,C
	NEG
.WR
	CALL	FMT_BYTE_DEC
	XOR	A
	LD	(DE),A
	LD	HL,SET_BUF
	LD	B,ENV_SET
	LD	C,DSS_ENVIRON
	RST	DSS
	RET


; ------------------------------------------------------
; FMT_BYTE_DEC: format byte A as ASCII decimal at (DE),
; no leading zeros (single "0" for zero input). DE advances
; past the digits.
;   Trashes A, BC, H.
; ------------------------------------------------------
FMT_BYTE_DEC
	LD	C,A			; remainder
	LD	H,0			; printed-digit flag
	; -- hundreds --
	LD	B,0
.H_LP
	LD	A,C
	CP	100
	JR	C,.H_END
	SUB	100
	LD	C,A
	INC	B
	JR	.H_LP
.H_END
	LD	A,B
	OR	A
	JR	Z,.NO_H
	ADD	A,'0'
	LD	(DE),A
	INC	DE
	INC	H
.NO_H
	; -- tens --
	LD	B,0
.T_LP
	LD	A,C
	CP	10
	JR	C,.T_END
	SUB	10
	LD	C,A
	INC	B
	JR	.T_LP
.T_END
	LD	A,B
	OR	A
	JR	NZ,.WR_T		; nonzero tens always print
	LD	A,H
	OR	A
	JR	Z,.NO_T			; no hundreds and tens=0 -> skip
	XOR	A			; tens digit is zero
.WR_T
	ADD	A,'0'
	LD	(DE),A
	INC	DE
.NO_T
	; -- ones (always) --
	LD	A,C
	ADD	A,'0'
	LD	(DE),A
	INC	DE
	RET


; ------------------------------------------------------
; FMT_BYTE_HEX: format byte A as 2 lowercase hex digits at
; (DE), DE += 2. Trashes A, BC.
; ------------------------------------------------------
FMT_BYTE_HEX
	LD	C,A
	RRA
	RRA
	RRA
	RRA
	AND	0x0F
	CALL	.NIB
	LD	A,C
	AND	0x0F
.NIB
	CP	10
	JR	C,.D
	ADD	A,'a'-10
	JR	.W
.D
	ADD	A,'0'
.W
	LD	(DE),A
	INC	DE
	RET


; ------------------------------------------------------
; SHOW_HELP, USAGE_ERROR
; ------------------------------------------------------
SHOW_HELP
	PRINT MSG_HELP
	JP	@UTIL.EXIT_OK

USAGE_ERROR
	PRINTLN MSG_USAGE_ERR
	PRINT MSG_HELP
	LD	B,1
	JP	@UTIL.EXIT_FAIL


; ------------------------------------------------------
; Static data
; ------------------------------------------------------
MSG_BANNER	DB "RTL8019AS NETCFG v0.1",0
MSG_SHOW_HDR	DB "NET.CFG:",0
MSG_INDENT	DB "  ",0
MSG_COLON	DB " : ",0
MSG_NOT_SET	DB "<not set>",0
MSG_DELETING	DB "Deleting NET_* environment variables...",0
MSG_INITIALIZING DB "Initializing from NET.CFG...",0
MSG_INIT_MISS	DB "[E] NET.CFG read failed (file missing or unreadable)",0
MSG_CHECK_OK	DB "NET.CFG syntax OK",0
MSG_CHECK_MISS	DB "[E] NET.CFG read failed",0
MSG_USAGE_ERR	DB "[E] usage: unknown or malformed flag",0
MSG_HELP
	DB "Usage:",13,10
	DB "  NETCFG          show current NET_* env values",13,10
	DB "  NETCFG -i       init: load NET.CFG into NET_* env",13,10
	DB "  NETCFG -c       check NET.CFG syntax",13,10
	DB "  NETCFG -d       delete all NET_* env vars",13,10
	DB "  NETCFG /?       this help (-? -h also accepted)",13,10
	DB "Exit codes: 0 ok, 1 usage, 4 config",13,10,0

; Variable name table (ASCIIZ entries; final entry = empty).
; Order matters only for SHOW output.
VAR_TABLE
N_NET_IP_SRC	DB "NET_IP_SRC",0
N_NET_IP	DB "NET_IP",0
N_NET_MASK	DB "NET_MASK",0
N_NET_GW	DB "NET_GW",0
N_NET_MAC	DB "NET_MAC",0
N_NET_DNS1	DB "NET_DNS1",0
N_NET_DNS2	DB "NET_DNS2",0
N_NET_NTP	DB "NET_NTP",0
N_NET_TZ	DB "NET_TZ",0
		DB 0			; table terminator

V_STATIC	DB "STATIC",0
V_DHCP		DB "DHCP",0

LINE_END	DB 13,10,0

; -- runtime work buffers (live in BSS at APP_BSS_BASE, NOT
; in the .EXE; always written before read) --
SET_BUF		EQU APP_BSS_BASE		; "NAME=value\0", up to 290 bytes
SHOW_VAL_BUF	EQU APP_BSS_BASE + 290		; GETENV destination, 256 bytes

	ENDMODULE


	; netcfg_lib pulls UTIL helpers transitively; include before util.asm.
	INCLUDE "netcfg_lib.asm"
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"
