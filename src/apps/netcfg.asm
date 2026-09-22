; ======================================================
; NETCFG.EXE - read NET.CFG and publish parsed values into
; DSS environment variables, or display them.
;
; Usage:
;   NETCFG          show current NET_* env values
;   NETCFG -i       init: load NET.CFG, populate NET_* env
;   NETCFG -c       check NET.CFG syntax (exit 4 on error)
;   NETCFG -d       delete all NET_* env vars
;   NETCFG -w       interactive wizard: create/edit NET.CFG
;   NETCFG /? -? -h help
;
; Exit codes:
;   0   OK
;   1   usage error
;   4   NET.CFG missing or invalid (only with -i / -c / -w)
;   5   NET.CFG write failed (only with -w)
;   7   -w cancelled by the user (Esc)
;
; This is the only utility in the kit that touches NET.CFG.
; All other tools read NET_* env vars via netenv_lib.
; ======================================================

EXE_VERSION	EQU 1			; DSS executable format version, not app version

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "memmap.inc"
	INCLUDE "rtl8019.inc"		; for PROM read fallback

	DEFINE USE_NETCFG_LOAD
	DEFINE USE_UTIL_EXIT
	DEFINE USE_NETCFG_WRITE
	DEFINE USE_CMDL_PARSE

	MODULE MAIN

	; Large-variant header.  NETCFG takes one short flag and used the small
	; layout (ORG 0x8080) until the -w wizard and its per-field hints
	; outgrew the 8 KB between 0x8080 and LIBBSS_BASE.  Code now lives in
	; WIN1; BSS and the stack live in a claimed WIN2 page.
	ORG 0x4100

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0100
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START
	DW START
	DW 0x8000			; entry stack in WIN1 (own page);
					; START moves it into WIN2
	DS 234, 0

	ORG 0x4200

START
	CLAIM_RUNTIME_PAGE		; WIN2 is the caller's page until this runs
	; DSS supplies [length,text...] through IX.  Capture it before
	; PRINTLN (RST DSS) or any CALL can clobber IX.
	LD	(CMDL_SOURCE_PTR),IX
	; DO_SHOW is the common exit for both `-i` and the bare show, and it
	; reads this byte to choose the exit code.  Only DO_INIT ever sets
	; it, so clear it here for every other path.
	XOR	A
	LD	(INIT_FAIL_CODE),A
	LD	(AUTO_TYPE),A
	DEC	A
	LD	(AUTO_DET_RESULT),A
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
	CP	'w'
	JP	Z,DO_WRITE
	; Default: show
	JP	DO_SHOW


; ------------------------------------------------------
; PARSE_FLAG: scan the length-prefixed command line whose entry-time
; pointer was captured from IX.  Do not derive the PSP address from the
; EXE entry point and do not fetch it after a DSS call: IX is volatile.
;   Out: A = lowercased flag char ('i','c','d','v','h')
;        A = '?' for help (any of /? -? /h -h)
;        A = 0  if no flag
;        A = 0xFF for unknown / malformed
;
; Only the first flag found is honored. Subsequent tokens
; are ignored to keep the parser tiny.
; ------------------------------------------------------
PARSE_FLAG
	LD	HL,(CMDL_SOURCE_PTR)
	LD	A,(HL)
	OR	A
	RET	Z
	LD	B,A
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
	; Validate known flags: i, c, d, v, w
	CP	'i'
	JR	Z,.RET
	CP	'c'
	JR	Z,.RET
	CP	'd'
	JR	Z,.RET
	CP	'v'
	JR	Z,.RET
	CP	'w'
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
; FINISH: common exit for DO_SHOW.  Fails with the code DO_INIT
; recorded, so `NETCFG -i` that could not produce NET_MAC stops the
; batch flow instead of reporting success.
; ------------------------------------------------------
FINISH
	LD	A,(INIT_FAIL_CODE)
	OR	A
	JP	Z,@UTIL.EXIT_OK
	LD	B,A
	JP	@UTIL.EXIT_FAIL


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
	JP	Z,FINISH
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
; DO_WRITE: run the interactive NET.CFG wizard.
; ------------------------------------------------------
DO_WRITE
	CALL	PRINT_CFG_PATH
	CALL	@NETCFGW.RUN
	JP	NC,@UTIL.EXIT_OK
	LD	B,A
	JP	@UTIL.EXIT_FAIL


; ------------------------------------------------------
; DO_CHECK: call NETCFG.LOAD; on failure exit 4.
; ------------------------------------------------------
DO_CHECK
	CALL	PRINT_CFG_PATH
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
	CALL	PRINT_CFG_PATH
	CALL	@NETCFG.LOAD
	JP	C,.MISS
	; The two variables that tell the driver WHERE the card is and HOW
	; to reset it must reach the environment BEFORE anything touches the
	; hardware -- FILL_MAC_FROM_PROM below calls INIT_BASE, whose
	; TRY_ENV_OVERRIDE reads NET_RTL_HW, and whose READ_RESET_MODE reads
	; NET_RTL_RESET.  With these SETENVs after the probe (as they were
	; through v0.2.50) the FIRST `NETCFG -i` of a session fell back to the
	; auto-scan, which rejects any card without the Realtek 8019 ID; the
	; MAC then came out unset and every later utility died with
	; "run NETCFG -i first", while a second `NETCFG -i` worked because by
	; then the variables were in the environment.
	;
	; RTL_HW: ASCIIZ "S/#HHH" if NET.CFG specified it; SETENV_STR
	; deletes the env var when the buffer is empty, so the driver
	; falls back to its auto-scan.
	LD	HL,N_NET_RTL_HW
	LD	IX,@NETCFG.OUR_RTL_HW
	CALL	SETENV_STR
	; RTL_RESET: publish the mode NET.CFG asked for.  AUTO (no
	; RTL_RESET= line) pushes the empty string so SETENV_STR deletes
	; any stale variable and every utility re-derives the mode from
	; the chip ID, exactly as this run is about to.
	LD	IX,V_RESET_NONE
	LD	A,(@NETCFG.OUR_RTL_RESET)
	CP	RTL_RESET_SOFT
	JR	NZ,.RESET_NOT_SOFT
	LD	IX,V_RESET_SOFT
	JR	.RESET_ENV
.RESET_NOT_SOFT
	CP	RTL_RESET_HARD
	JR	NZ,.RESET_ENV
	LD	IX,V_RESET_HARD
.RESET_ENV
	LD	HL,N_NET_RTL_RESET
	CALL	SETENV_STR
	LD	HL,N_NET_RTL_TYPE
	LD	IX,@NETCFG.OUR_RTL_TYPE
	CALL	SETENV_STR

	; If NET.CFG had no RTL_MAC= line (or it was empty), the MAC
	; field is all-zero -- read the PROM and use that.
	CALL	FILL_MAC_FROM_PROM
	PUSH	AF
	CALL	REPORT_CARD_TYPE
	; Auto-detection selected the runtime layout.  Publish only an
	; unambiguous detector result; AMBIGUOUS/UNKNOWN keep the variable
	; absent and use NE2000 only as the runtime fallback.
	LD	A,(@NETCFG.OUR_RTL_TYPE)
	OR	A
	JR	NZ,.TYPE_PUBLISHED
	LD	A,(AUTO_TYPE)
	OR	A
	JR	Z,.TYPE_PUBLISHED
	CP	1
	LD	IX,V_RTL_TYPE_2000
	JR	NZ,.TYPE_STORE
	LD	IX,V_RTL_TYPE_1000
.TYPE_STORE
	LD	HL,N_NET_RTL_TYPE
	CALL	SETENV_STR
.TYPE_PUBLISHED
	; FILL_MAC_FROM_PROM ran RTL.RESET, which resolves an AUTO mode in
	; place.  If it came back SOFT while NET.CFG said nothing, the card
	; did not identify as a Realtek and the board reset port was skipped
	; on the driver's own judgement.  Say so: it is the difference
	; between a card that works and a machine that hangs, and the user
	; has no other way to find out which happened.
	LD	A,(@NETCFG.OUR_RTL_RESET)
	CP	RTL_RESET_AUTO
	JR	NZ,.RESET_REPORTED
	LD	A,(RTL_SOFT_RESET)
	CP	RTL_RESET_SOFT
	JR	NZ,.RESET_REPORTED
	PRINTLN MSG_CLONE_RESET
	; Latch the answer in the environment.  Only the SOFT outcome is
	; published: it is the safe direction, it saves every later utility
	; the ID probe, and it is the one UNETRTL.DLL cannot work out for
	; itself.  A HARD outcome deliberately leaves the variable deleted
	; so the next utility re-probes -- otherwise swapping a Realtek for
	; a clone would carry a stale "HARD" over and hang the machine.
	LD	HL,N_NET_RTL_RESET
	LD	IX,V_RESET_SOFT
	CALL	SETENV_STR
.RESET_REPORTED
	POP	AF
	; A = 0, or the exit code for why no MAC could be obtained.  Without
	; NET_MAC nothing downstream can run, so this is fatal: NETCFG's job
	; is to leave a usable environment behind, and it did not.  Report
	; the reason now and remember the code -- the remaining variables are
	; still published (so `NETCFG` show afterwards reflects NET.CFG), but
	; the exit at the end of DO_SHOW carries this code instead of 0.
	LD	(INIT_FAIL_CODE),A
	OR	A
	JR	Z,.MAC_OK
	CP	EX_NO_HW
	JR	NZ,.MAC_E3
	PRINTLN MSG_E_NO_CARD
	JR	.MAC_OK
.MAC_E3
	CP	EX_NIC_ERR
	JR	NZ,.MAC_E4
	PRINTLN MSG_E_PROM
	JR	.MAC_OK
.MAC_E4
	PRINTLN MSG_E_NO_MAC
.MAC_OK
	; Always push MAC, NTP, TZ.
	LD	HL,N_NET_MAC
	LD	IX,@NETCFG.OUR_MAC
	CALL	SETENV_MAC
	LD	HL,N_NET_NTP
	LD	IX,@NETCFG.NTP
	CALL	SETENV_STR
	LD	HL,N_NET_TZ
	LD	IX,@NETCFG.TZ
	CALL	SETENV_STR
	; NET=RTL is the backend marker a launcher reads to decide which
	; UNET DLL to load (the Wi-Fi kit publishes NET=WIFI).  UNETRTL.DLL
	; also accepts the legacy state -- no NET at all, but NET_IP and
	; NET_MAC present -- so an older configuration keeps working.
	LD	HL,N_NET
	LD	DE,V_RTL
	CALL	SETENV_LITERAL

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
; PRINT_CFG_PATH: show the exact path NETCFG.LOAD will open.  This makes
; APPINFO/path failures diagnosable on a real Sprinter without a debugger.
; NETCFG.LOAD rebuilds the same path immediately afterwards.
; ------------------------------------------------------
PRINT_CFG_PATH
	PRINT	MSG_CFG_PATH
	CALL	@NETCFG.BUILD_CFG_PATH
	LD	C,DSS_PCHARS
	RST	DSS
	PRINT	LINE_END
	RET


; ------------------------------------------------------
; FILL_MAC_FROM_PROM: touch the card when either the parsed MAC is empty
; or RTL_TYPE is AUTO.  An AUTO run detects and selects the packet-RAM
; layout even when RTL_MAC was supplied; PROM is read only when the MAC is
; empty.  Return A = EX_* and always close ISA before returning.
; ------------------------------------------------------
; ------------------------------------------------------
; MAC_IS_ZERO: Z if NETCFG's MAC field is all zero.
; Trashes A, HL.
; ------------------------------------------------------
MAC_IS_ZERO
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
	RET


FILL_MAC_FROM_PROM
	; No hardware is needed only when both values are explicit.
	CALL	MAC_IS_ZERO
	JR	Z,.NEED_HW
	LD	A,(@NETCFG.OUR_RTL_TYPE)
	OR	A
	LD	A,EX_OK
	RET	NZ
.NEED_HW
	; INIT_BASE handles ISA slot 1 then 0 and base auto-scan;
	; on success ISA stays open with the right slot/base set.
	LD	A,1
	LD	(@ISA.ISA_SLOT),A
	CALL	@RTL.INIT_BASE
	JR	NC,.FOUND
	CP	RTL_INIT_BAD_TYPE
	JR	Z,.BAD_CFG
	LD	A,EX_NO_HW
	RET
.BAD_CFG
	LD	A,EX_CFG_ERR
	RET
.FOUND
	; Belt and braces.  The caller now publishes NET_RTL_RESET before
	; calling us, so INIT_BASE's READ_RESET_MODE has already set this
	; flag from the environment.  Re-apply the parsed value anyway: if
	; that ordering is ever broken again, the failure mode here is not a
	; missing MAC but a stalled ISA cycle inside RESET -- a hung machine
	; with no diagnostic, which is far too harsh a price for 6 bytes.
	LD	A,(@NETCFG.OUR_RTL_RESET)
	LD	(RTL_SOFT_RESET),A
	CALL	@RTL.RESET
	JP	C,.NIC_ERR
	CALL	@RTLDET.ENTER_PROBE_MODE
	; AUTO type: distinguish the 8 KB NE1000 RAM window from the
	; NE2000/RTL8019 layout before the PROM read.  An explicit
	; NET_RTL_TYPE skips the destructive probe and uses that layout.
	LD	A,(RTL_CARD_FLAGS)
	AND	RTL_LAYOUT_FLAG_ENV
	JR	NZ,.TYPE_READY
	CALL	@RTLDET.DETECT
	LD	(AUTO_DET_RESULT),A	; LD preserves detector CF
	JP	C,.NIC_ERR
	CP	RTL_DET_NE1000
	JR	NZ,.NOT_AUTO_1000
	LD	A,1
	LD	(AUTO_TYPE),A
	LD	A,RTL_LAYOUT_NE1000
	JR	.APPLY_TYPE
.NOT_AUTO_1000
	CP	RTL_DET_NE2000
	JR	NZ,.AUTO_FALLBACK
	LD	A,2
	LD	(AUTO_TYPE),A
.AUTO_FALLBACK
	XOR	A			; ambiguous/unknown fall back to NE2000
.APPLY_TYPE
	CALL	@RTL.SET_LAYOUT
.TYPE_READY
	; A configured MAC must survive AUTO detection unchanged.  DETECT has
	; already established the stopped postcondition required before close.
	CALL	MAC_IS_ZERO
	JR	Z,.READ_PROM
	CALL	@RTLDET.STOP_AND_CHECK
	JP	C,.NIC_ERR
	CALL	@ISA.ISA_CLOSE
	LD	A,EX_OK
	RET
.READ_PROM
	; Set DCR=0x48 directly via the new IX-relative base.
	; (RTL_BASE_PTR is already populated by INIT_BASE.)
	LD	IX,(RTL_BASE_PTR)
	LD	(IX+RTL_DCR_OFF),DCR_INIT
	; Reuse NETCFG_LOAD_BUF as the 32-byte PROM scratch.  By
	; this point NET.CFG has already been parsed so the buffer
	; is no longer needed.
	LD	HL,NETCFG_LOAD_BUF
	CALL	@RTL.READ_PROM
	JP	C,.NIC_ERR
	LD	HL,NETCFG_LOAD_BUF+32
	CALL	@RTL.READ_PROM
	JP	C,.NIC_ERR
	CALL	PROM_READS_EQUAL
	JR	Z,.PROM_STABLE
	; One retry prevents a single bus glitch from changing the selected
	; direct/doubled interpretation.
	LD	HL,NETCFG_LOAD_BUF+32
	CALL	@RTL.READ_PROM
	JP	C,.NIC_ERR
	CALL	PROM_READS_EQUAL
	JP	NZ,.NIC_ERR
.PROM_STABLE
	CALL	@RTLDET.STOP_AND_CHECK
	JP	C,.NIC_ERR
	CALL	DECODE_PROM_LAYOUT
	CP	2
	JR	Z,.PROM_CFG_ERR
	OR	A
	JR	Z,.DIRECT
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
	JR	.DONE
.DIRECT
	; Direct: PROM[0..5] -> OUR_MAC.
	LD	HL,NETCFG_LOAD_BUF
	LD	DE,@NETCFG.OUR_MAC
	LD	BC,6
	LDIR
.DONE
	CALL	@ISA.ISA_CLOSE
	; The card answered and its PROM was read, but a PROM full of zeros
	; still yields no usable address.  That one is the user's to fix
	; with RTL_MAC=, hence a config error rather than a NIC error.
	CALL	PROM_MAC_VALID
	LD	A,EX_OK
	RET	NC
	LD	A,EX_CFG_ERR
	RET
.PROM_CFG_ERR
	CALL	@ISA.ISA_CLOSE
	LD	A,EX_CFG_ERR
	RET
.NIC_ERR
	CALL	@ISA.ISA_CLOSE
	LD	A,EX_NIC_ERR
	RET

; Report the configured or detected family after ISA has been closed.
; AUTO warnings intentionally do not publish a fallback type.
REPORT_CARD_TYPE
	LD	A,(@NETCFG.OUR_RTL_TYPE)
	OR	A
	JR	Z,.AUTO
	PRINT MSG_CARD_TYPE
	LD	A,(@NETCFG.OUR_RTL_TYPE+2)
	CP	'1'
	JR	NZ,.CFG_2000
	PRINT MSG_NE1000
	JR	.CFG_DONE
.CFG_2000
	PRINT MSG_NE2000
.CFG_DONE
	PRINTLN MSG_TYPE_CFG
	RET
.AUTO
	LD	A,(AUTO_DET_RESULT)
	CP	RTL_DET_NE1000
	JR	Z,.AUTO_1000
	CP	RTL_DET_NE2000
	JR	Z,.AUTO_2000
	CP	RTL_DET_AMBIGUOUS
	JR	Z,.AMBIG
	CP	RTL_DET_UNKNOWN
	RET	NZ
	PRINTLN MSG_W_TYPE_UNKNOWN
	RET
.AMBIG
	PRINTLN MSG_W_TYPE_AMBIG
	RET
.AUTO_1000
	PRINT MSG_CARD_TYPE
	PRINT MSG_NE1000
	PRINTLN MSG_TYPE_AUTO_20
	RET
.AUTO_2000
	PRINT MSG_CARD_TYPE
	PRINT MSG_NE2000
	PRINTLN MSG_TYPE_AUTO_40
	RET

; Z when the two 32-byte PROM reads match.
PROM_READS_EQUAL
	LD	HL,NETCFG_LOAD_BUF
	LD	DE,NETCFG_LOAD_BUF+32
	LD	B,32
.LP
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	INC	HL
	INC	DE
	DJNZ	.LP
	RET

; A=0 direct, A=1 doubled, A=2 ambiguous.  This implements the format
; rules from NE1000_PLAN 4.9 and never infers doubling from one equal pair.
DECODE_PROM_LAYOUT
	LD	HL,NETCFG_LOAD_BUF
	LD	B,16
.PAIR
	LD	A,(HL)
	INC	HL
	CP	(HL)
	JR	NZ,.DIRECT
	INC	HL
	DJNZ	.PAIR
	; All pairs match.  Record the two possible logical signature sites.
	XOR	A
	LD	C,A			; bit0 direct signature, bit1 doubled
	LD	A,(NETCFG_LOAD_BUF+14)
	LD	D,A
	LD	A,(NETCFG_LOAD_BUF+15)
	CP	D
	JR	NZ,.SIG_X
	CP	0x57
	JR	Z,.SET_D
	CP	0x42
	JR	NZ,.SIG_X
.SET_D
	SET	0,C
.SIG_X
	LD	A,(NETCFG_LOAD_BUF+28)
	LD	D,A
	LD	A,(NETCFG_LOAD_BUF+30)
	CP	D
	JR	NZ,.REDUCE
	CP	0x57
	JR	Z,.SET_X
	CP	0x42
	JR	NZ,.REDUCE
.SET_X
	SET	1,C
.REDUCE
	LD	A,C
	CP	1
	JR	Z,.DIRECT
	CP	2
	JR	NZ,.NE1000_EVIDENCE
	LD	A,(RTL_CARD_FLAGS)
	AND	RTL_LAYOUT_FLAG_NE1000
	LD	A,2
	RET	NZ			; contradictory: NE1000 but doubled-only
	LD	A,1
	RET
.NE1000_EVIDENCE
	LD	A,(RTL_CARD_FLAGS)
	AND	RTL_LAYOUT_FLAG_NE1000
	LD	A,2
	RET	Z
.DIRECT
	XOR	A
	RET

; CF=0 for a usable unicast MAC; CF=1 for zero, broadcast or multicast.
PROM_MAC_VALID
	LD	HL,@NETCFG.OUR_MAC
	BIT	0,(HL)
	JR	NZ,.BAD
	LD	B,6
	XOR	A
.OR
	OR	(HL)
	INC	HL
	DJNZ	.OR
	JR	Z,.BAD
	LD	HL,@NETCFG.OUR_MAC
	LD	B,6
.FF
	LD	A,(HL)
	CP	0xFF
	JR	NZ,.OK
	INC	HL
	DJNZ	.FF
.BAD
	SCF
	RET
.OK
	OR	A
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
MSG_BANNER	DB "RTL8019AS NETCFG v",PACKAGE_VERSION,0
MSG_SHOW_HDR	DB "NET.CFG:",0
MSG_INDENT	DB "  ",0
MSG_COLON	DB " : ",0
MSG_NOT_SET	DB "<not set>",0
MSG_DELETING	DB "Deleting NET_* environment variables...",0
MSG_INITIALIZING DB "Initializing from NET.CFG...",0
MSG_CFG_PATH	DB "[C0] CFG=",0
MSG_INIT_MISS	DB "[E] NET.CFG read failed (file missing or unreadable)",0
MSG_CHECK_OK	DB "NET.CFG syntax OK",0
MSG_CHECK_MISS	DB "[E] NET.CFG read failed",0
MSG_USAGE_ERR	DB "[E] usage: unknown or malformed flag",0
MSG_E_NO_CARD	DB "[E2] card not found; check RTL_HW in NET.CFG",0
MSG_E_PROM	DB "[E3] card found but PROM read failed",0
MSG_E_NO_MAC	DB "[E4] no MAC in card PROM; add RTL_MAC= to NET.CFG",0
MSG_CLONE_RESET	DB "[W03] non-Realtek clone: board reset port skipped",0
MSG_HELP
	DB "Usage:",13,10
	DB "  NETCFG          show current NET_* env values",13,10
	DB "  NETCFG -i       init: load NET.CFG into NET_* env",13,10
	DB "  NETCFG -c       check NET.CFG syntax",13,10
	DB "  NETCFG -d       delete all NET_* env vars",13,10
	DB "  NETCFG -w       interactive wizard: create/edit NET.CFG",13,10
	DB "  NETCFG /?       this help (-? -h also accepted)",13,10
	DB "Exit: 0 ok, 1 usage, 2 no card, 3 NIC, 4 config, 5 write, 7 cancel",13,10,0

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
N_NET_RTL_HW	DB "NET_RTL_HW",0
N_NET_RTL_RESET	DB "NET_RTL_RESET",0
N_NET_RTL_TYPE	DB "NET_RTL_TYPE",0
N_NET		DB "NET",0
		DB 0			; table terminator

; Values, NOT names -- these must stay OUTSIDE VAR_TABLE.  V_RESET_SOFT
; once sat between N_NET_RTL_RESET and N_NET, which made DO_SHOW print a
; bogus "SOFT : <not set>" row, and V_RESET_NONE (an empty string) read
; as the table terminator, hiding NET from the listing entirely.
V_RESET_SOFT	DB "SOFT",0
V_RESET_HARD	DB "HARD",0
V_RESET_NONE	DB 0
V_STATIC	DB "STATIC",0
V_DHCP		DB "DHCP",0
V_RTL		DB "RTL",0
V_RTL_TYPE_1000	DB "NE1000",0
V_RTL_TYPE_2000	DB "NE2000",0
MSG_CARD_TYPE	DB "card type: ",0
MSG_NE1000	DB "NE1000",0
MSG_NE2000	DB "NE2000",0
MSG_TYPE_CFG	DB " (NET.CFG)",0
MSG_TYPE_AUTO_20 DB " (auto: RAM at 2000)",0
MSG_TYPE_AUTO_40 DB " (auto: RAM at 4000 or Realtek ID)",0
MSG_W_TYPE_UNKNOWN DB "[W04] card type not detected; assuming NE2000; set RTL_TYPE",0
MSG_W_TYPE_AMBIG DB "[W05] packet RAM answers at both 2000 and 4000; assuming NE2000",0

LINE_END	DB 13,10,0

; -- runtime work buffers (live in BSS at APP_BSS_BASE, NOT
; in the .EXE; always written before read) --
SET_BUF		EQU APP_BSS_BASE		; "NAME=value\0", up to 290 bytes
SHOW_VAL_BUF	EQU APP_BSS_BASE + 290		; GETENV destination, 256 bytes
INIT_FAIL_CODE	EQU APP_BSS_BASE + 546		; 1 byte: exit code for FINISH
AUTO_TYPE	EQU APP_BSS_BASE + 547		; 0=no publish, 1=NE1000, 2=NE2000
AUTO_DET_RESULT EQU APP_BSS_BASE + 548	; RTL_DET_* or FF if not probed

	ENDMODULE


	; netcfg_write.asm calls into MAIN/NETCFG/CMDL/UTIL/ISA/RTL, all of
	; which are only fully defined once their own INCLUDE runs, but
	; sjasmplus resolves labels across the whole multi-pass assembly
	; regardless of INCLUDE order -- listed first only because that is
	; where the wizard conceptually sits, closest to the app itself.
	INCLUDE "netcfg_write.asm"
	; netcfg_lib pulls UTIL helpers transitively; include before util.asm.
	INCLUDE "netcfg_lib.asm"
	INCLUDE "isa.asm"
	INCLUDE "util.asm"
	INCLUDE "rtl8019.asm"
	DEFINE USE_RTL_DETECT
	INCLUDE "rtl_detect.asm"
	INCLUDE "cmdline_lib.asm"
	INCLUDE "win2page.asm"

	ASSERT $ <= 0x7F80			; image must stay inside WIN1
	ASSERT MAIN.AUTO_DET_RESULT + 1 < RT_STACK_TOP - 0x0100
