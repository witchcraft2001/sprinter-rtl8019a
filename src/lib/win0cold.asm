; ======================================================
; win0cold.asm -- load and invoke "cold" executable code appended to
; this DLL's own file, via a page mapped into MMU window 0.
;
; UNETRTL.DLL's own image is capped at a hard 16 KB libman budget
; (see unetrtl.asm's ASSERT).  Pure register/buffer logic with no
; DSS/BIOS dependency (currently the RESOLVE/DNS/ARP/PING frame
; builders and per-frame reply matchers, see unetrtl_cold.asm) can
; instead live in a SEPARATE blob appended to the end of the .DLL
; file itself (after the L1 header + code image + relocation bitmap
; that libman actually loads) and be paged in on demand:
;
;   [normal L1 DLL: header + code image + reloc bitmap]
;   [2-byte LE length of the cold blob]
;   [cold blob bytes, assembled with ORG 0x0000]
;
; INIT (once, at NETINIT):
;   1. DSS_GETMEM one page; BIOS_EMM_FN4 its physical byte (both RST
;      DSS/RST BIOS calls happen here, BEFORE anything touches WIN0 --
;      see point 3).
;   2. Re-open this DLL's own file (exe-homedir first, bare name
;      fallback -- the same tolerance RESOLVE_DLL_PATH/NETCFG use,
;      since libman's vendored loader does not record which
;      convention the host app used to find us).
;   3. Read the L1 header's file_size field (offset 2), which for an
;      uncompressed image equals the byte offset where our own
;      trailing data starts.  Seek there, read the 2-byte length
;      prefix, then read that many bytes STRAIGHT INTO THE ALLOCATED
;      PAGE STAGED OVER WIN3 (0xC000) -- the one DSS-file-I/O
;      target address this codebase has already proven safe to use
;      while a block is mapped there (libman13.asm's own l_load does
;      exactly this).  WIN3 is free to use here: this all happens
;      before RTL.INIT_BASE ever calls ISA_OPEN.
;   4. Close the file, restore WIN3 to whatever it held before.
;
; RUN (every cold invocation, e.g. once per RESOLVE frame build or
; per received frame in a PING/ARP/DNS wait loop):
;   DI, save SP and switch to a private stack on the cold page itself
;   (see the comment inside RUN: the consumer's stack may live in WIN0,
;   which is about to be remapped, so the cold code must not push
;   there), save PAGE0, write our cached physical byte to PAGE0
;   (one OUT, no DSS/BIOS call -- both RST vectors are UNREACHABLE
;   once this executes, because the DLL's normal PAGE0 content, which
;   is where they live, is what just got replaced), CALL the cold
;   image's entry point at offset 0, restore PAGE0, SP, and IFF.
;
;   The cold code touches NOTHING by absolute address: every buffer
;   it reads/writes and every hot routine it needs (BUILD_ETH_IP,
;   the checksum writers, SEND_FRAME, COMMIT_PACKET, ...) is handed
;   to it as a POINTER in a small parameter block the hot caller
;   builds first (see unetrtl_cold.asm's header for the exact
;   layout).  This is what lets ONE cold blob work regardless of
;   which window (WIN1 or WIN2) the DLL itself was relocated into --
;   there is no baked-in address arithmetic to get wrong.  The cold
;   code must never touch DSS/BIOS (RST 0x10/RST 0x08 are both
;   unreachable) and must never EI -- CALL restores interrupts itself
;   on return.
;
; Public API (DEFINE USE_WIN0COLD before INCLUDE):
;
;   WIN0COLD.INIT
;       Out: CF=0 ready; CF=1 unavailable (DSS/BIOS refused the
;            allocation, the file could not be reopened, or it
;            carries no trailing blob) -- F_RESOLVE/F_PING then
;            report NERR_NOTSUP for the session (they gate on READY)
;            rather than running against a missing blob.
;       Trashes A, BC, DE, HL, IX.
;
;   WIN0COLD.RUN
;       In:  A = cold function code (dispatched by the blob's own
;            offset-0 table); IX = pointer to this call's parameter
;            block (meaning defined per function code); other
;            registers per that function's own contract.
;       Out: per that function's own contract.
;       Trashes nothing beyond what the specific cold function
;       documents; DI/EI, the stack switch and the WIN0 remap are
;       invisible to the caller (any consumer SP is safe, WIN0
;       included).  CF=1 without touching the parameter block if INIT
;       never succeeded (defensive; callers are expected to check
;       INIT's own result once and not call afterward).
;
;       Interrupt contract matches isa.asm's ISA_OPEN/ISA_CLOSE (and
;       for the same reason: every current caller runs this WHILE the
;       ISA window is open, PAGE3 mapped to the card).  RUN samples
;       the caller's real IFF2 before its own DI and restores exactly
;       that state afterward (EI only if the caller had interrupts
;       enabled) -- it must never unconditionally EI, or it would
;       re-enable interrupts out from under a still-open ISA window
;       and risk the ISR corrupting the chip, exactly the class of
;       bug the ISA_OPEN/ISA_CLOSE IFF discipline exists to prevent.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_WIN0COLD
	DEFINE	_WIN0COLD

	INCLUDE "dss.inc"
	INCLUDE "sprinter.inc"

	MODULE	WIN0COLD

READY		DB 0			; 1 once INIT has loaded the blob
BLOCK_ID	DB 0xFF
PHYS_BYTE	DB 0

; ------------------------------------------------------
; INIT: see header comment.
; ------------------------------------------------------
INIT
	LD	A,(READY)
	OR	A
	RET	NZ			; idempotent: a repeated NETINIT must not
					; leak another DSS_GETMEM page
	LD	B,1
	LD	C,DSS_GETMEM
	RST	DSS
	RET	C
	LD	(BLOCK_ID),A
	LD	B,0
	LD	C,BIOS_EMM_FN4
	RST	BIOS
	JR	C,.free_block
	LD	(PHYS_BYTE),A
	CALL	.LOAD_BLOB
	JR	C,.free_block
	LD	A,1
	LD	(READY),A
	OR	A
	RET
.free_block
	LD	A,(BLOCK_ID)
	LD	C,DSS_FREEMEM
	RST	DSS
	LD	A,0xFF
	LD	(BLOCK_ID),A
	SCF
	RET

; ------------------------------------------------------
; .LOAD_BLOB: reopen our own file, find the trailing blob, copy it
; into the allocated page staged over WIN3.  ISA is guaranteed
; closed here (INIT runs from F_NETINIT before RTL.INIT_BASE).
;   Out: CF=0 loaded; CF=1 (file/format problem -- best-effort,
;        LISTEN just stays unavailable).
; ------------------------------------------------------
.LOAD_BLOB
	CALL	.OPEN_SELF
	RET	C
	LD	(.FH),A
	; A freshly opened handle is already positioned at 0.  L1 header:
	; the 2-byte "file_size" at offset 2 is the byte offset where our
	; own trailing data starts (uncompressed image: header + code +
	; reloc bitmap together equal exactly file_size).
	LD	HL,.HDRBUF
	LD	DE,8
	LD	C,DSS_READ_FILE
	RST	DSS			; A still = handle from .OPEN_SELF's return
	JR	C,.close_fail
	LD	IX,(.HDRBUF+2)		; file_size = tail offset (low word)
	LD	A,(.FH)
	LD	B,SEEK_SET
	LD	HL,0			; offset high word
	LD	C,DSS_MOVE_FP
	RST	DSS
	JR	C,.close_fail
	; 2-byte LE length prefix of the cold blob.
	LD	A,(.FH)
	LD	HL,.HDRBUF
	LD	DE,2
	LD	C,DSS_READ_FILE
	RST	DSS
	JR	C,.close_fail
	LD	HL,(.HDRBUF)
	LD	A,H
	OR	L
	JR	Z,.close_fail		; zero-length: nothing to run
	LD	(.BLOBLEN),HL
	; Stage the page over WIN3, save+restore its prior mapping.
	LD	BC,PAGE3
	IN	A,(C)
	LD	(.SAVE_WIN3),A
	LD	A,(PHYS_BYTE)
	LD	BC,PAGE3
	OUT	(C),A
	LD	A,(.FH)
	LD	HL,PAGE3_ADDR
	LD	DE,(.BLOBLEN)
	LD	C,DSS_READ_FILE
	RST	DSS
	PUSH	AF
	LD	A,(.SAVE_WIN3)
	LD	BC,PAGE3
	OUT	(C),A
	POP	AF
	JR	C,.close_fail
	LD	A,(.FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	OR	A
	RET
.close_fail
	LD	A,(.FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	SCF
	RET
; INIT-time scratch overlays @MAIN.TX_BUF instead of occupying image
; bytes: INIT runs once, from F_NETINIT, before RTL.INIT_BASE and long
; before the first frame is built, so TX_BUF (320 bytes) is guaranteed
; dead for its whole lifetime; a repeated NETINIT returns on the READY
; check before touching any of this.  Two reasons, both real:
;   1. The libman image budget.  These 77 bytes are what pays for the
;      cold-call stack switch in RUN below.
;   2. .PATH used to be DS 65 in the image, but .OPEN_SELF may write
;      up to 63 bytes of APPINFO homedir + '\' + "UNETRTL.DLL",0 = 77
;      bytes into it -- a homedir >= 53 characters overflowed the old
;      buffer straight into RUN's code.  In TX_BUF the buffer is 80
;      bytes with dead scratch beyond it, so the worst case is safe.
.FH		EQU @MAIN.TX_BUF + 0	; 1
.SAVE_WIN3	EQU @MAIN.TX_BUF + 1	; 1
.BLOBLEN	EQU @MAIN.TX_BUF + 2	; 2
.HDRBUF		EQU @MAIN.TX_BUF + 4	; 8
.PATH		EQU @MAIN.TX_BUF + 12	; 80 (63 dir + sep + 12 name + NUL slack)

; ------------------------------------------------------
; .OPEN_SELF: try "<exe_home>\UNETRTL.DLL", then the bare name --
; the same tolerance RESOLVE_DLL_PATH (unettest.asm) and NETCFG's
; path loader already apply, since libman's vendored loader records
; no path a re-opener could rely on.
;   Out: CF=0 -> A = handle; CF=1 -> both attempts failed.
; ------------------------------------------------------
.OPEN_SELF
	LD	HL,.PATH
	LD	B,APPINFO_EXE_HOMEDIR
	LD	C,DSS_APPINFO
	RST	DSS
	JR	C,.bare
	LD	HL,.PATH
	LD	B,64
.find_end
	LD	A,(HL)
	OR	A
	JR	Z,.have_end
	INC	HL
	DJNZ	.find_end
	JR	.bare			; overlong/malformed
.have_end
	LD	A,(.PATH)
	OR	A
	JR	Z,.bare			; empty result
	DEC	HL
	LD	A,(HL)
	INC	HL
	CP	92			; '\'
	JR	Z,.append
	CP	'/'
	JR	Z,.append
	LD	(HL),92
	INC	HL
.append
	EX	DE,HL
	LD	HL,.NAME
	CALL	.STRCPY
	LD	A,FA_READONLY
	LD	HL,.PATH
	LD	C,DSS_OPEN_FILE
	RST	DSS
	RET	NC
.bare
	LD	A,FA_READONLY
	LD	HL,.NAME
	LD	C,DSS_OPEN_FILE
	RST	DSS
	RET
.STRCPY
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	OR	A
	JR	NZ,.STRCPY
	RET
.NAME		DB "UNETRTL.DLL",0

; ------------------------------------------------------
; RUN: see header comment's "CALL" entry (named RUN here -- "CALL" is
; a Z80 mnemonic and cannot double as a label).
; ------------------------------------------------------
RUN
	LD	(.SAVE_A),A		; the caller's function code; also keeps
					; the READY check off the caller's stack
	LD	A,(READY)
	OR	A
	JR	NZ,.go
	SCF
	RET
.go
	; Sample the caller's real IFF2 BEFORE the DI below, mirroring
	; isa.asm's ISA_OPEN (NMOS erratum: a maskable interrupt can land
	; mid "LD A,I" and misreport P/V once; if it did, its handler has
	; already returned with EI, so a second read correctly sees 1).
	LD	A,I
	JP	PE,.IFF_ON
	LD	A,I
	JP	PE,.IFF_ON
	XOR	A
	JR	.IFF_SAMPLED
.IFF_ON
	LD	A,1
.IFF_SAMPLED
	LD	(.SAVE_IFF),A
	DI
	; --- Stack switch.  The consumer's SP may point anywhere,
	; including WIN0 (0x0000..0x3FFF) -- the very window about to be
	; repointed at the cold page.  Without a switch, the cold code's
	; own pushes would land on the consumer's page and scar whatever
	; sat at those addresses.  sprinter-3C509B solves this with a
	; 96-byte private stack in its DLL BSS; this image has no such
	; budget, so the cold call instead runs on the TOP OF THE COLD
	; PAGE ITSELF (SP=0x4000 while it is mapped): ~14 KB of
	; guaranteed-private depth above the blob, at zero image cost --
	; important, because cold drains call back into hot SEND_FRAME and
	; the whole driver TX path runs on this stack.
	;
	; The remap/un-map brackets could use NEITHER stack (the consumer's
	; may be in WIN0; the cold page's does not exist yet / dies with
	; the un-map), so they use NO STACK AT ALL: PAGE0 is an 8-bit port
	; (0x82), which lets the immediate IN/OUT form carry the port
	; without BC -- exactly what libman13.asm's own loader does on real
	; hardware with 0xE2 -- and the one register that must survive the
	; un-map, A, parks in an inline slot instead of a push.  Nothing
	; between the cold RET and the caller's RET touches F either, so
	; the cold function's CF/ZF reach the caller untouched.
	; Interrupts are off throughout, so no ISR can land on either stack.
	LD	(.SAVE_SP),SP
	IN	A,(PAGE0)		; BC is a live pass-through in BOTH
	LD	(.SAVE_PAGE0),A		; directions (CFN_PARSE_DNS_REPLY takes
	LD	A,(PHYS_BYTE)		; the length in BC, CFN_BUILD_ICMP_ECHO
	OUT	(PAGE0),A		; returns it) -- immediate I/O never
					; touches it, so no bracket is needed.
	LD	SP,0x4000		; top of the now-mapped cold page
	; The .SAVE_*/.RESULT_A slots live INSIDE the immediate operands of
	; their reload instructions (written by the LD (label) stores) --
	; no separate data bytes, and an immediate load is cheaper than a
	; LD from memory.  Safe here: RUN is not reentrant and IRQs are off
	; for the whole store..reload window.
	LD	A,0
.SAVE_A		EQU $-1
	CALL	0x0000
	; Results live in AF/BC/HL/DE/IX per the function's contract and the
	; cold stack has fully unwound.  Park A (the only register the
	; un-map needs) in-image, un-map, put it back.
	LD	(.RESULT_A),A
	LD	A,0
.SAVE_PAGE0	EQU $-1
	OUT	(PAGE0),A
	LD	A,0
.RESULT_A	EQU $-1
	; Consumer page 0 is back; the consumer stack is valid again
	; wherever it lives.
	LD	SP,0
.SAVE_SP	EQU $-2
	PUSH	AF
	LD	A,0
.SAVE_IFF	EQU $-1
	OR	A
	JR	Z,.no_ei
	EI
.no_ei
	POP	AF
	RET

	ENDMODULE
	ENDIF
