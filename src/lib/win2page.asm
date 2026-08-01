; ======================================================
; win2page.asm -- claim the WIN2 runtime page.
;
; DSS EXEC maps only as many pages as the EXE image itself
; needs, starting at the window of the load address.  A utility
; loaded at 0x4200 whose image fits in one page therefore owns
; WIN1 only: WIN2 (0x8000..0xBFFF) still holds the CALLER's
; page.  Every large-variant utility keeps its BSS (LIBBSS_BASE,
; APP_BSS_BASE, per-library regions) and its stack there, so it
; must claim a page of its own before touching any of it.
;
; Without this the utility writes straight into the launcher.
; The Sprinter File Manager runs its manager code at 0x8000
; (FM-SRC/FM/LOAD.ASM maps page_manager into PAGE_2 and jumps to
; 0x8000), so it is destroyed by every such utility and hangs as
; soon as the child returns.  DSS restores SLOT1..SLOT3 at EXIT,
; but nothing can undo the writes.
;
; DSS releases the block and restores SLOT2 on EXIT #41 (LEAVE
; frees every block owned by the task, then reloads the slots
; from the exec stack), so there is no teardown entry point.
;
; Public API (DEFINE USE_WIN2PAGE before INCLUDE, then use the
; CLAIM_RUNTIME_PAGE macro from macro.inc):
;
;   WIN2PAGE.CLAIM
;       Out: CF=0 -> one page allocated and mapped over WIN2;
;            CF=1 -> DSS refused (no free pages), WIN2 untouched.
;       Trashes A, BC.  Preserves DE, HL, IX.
;
;   WIN2PAGE.NO_PAGE_EXIT
;       Terminates with status 3.  Deliberately silent: the entry
;       stack still lives in WIN1, and a console print that
;       scrolls destroys a WIN1 stack (BIOS WIN_MOVE restores
;       SLOT1 from a POP taken while the video page is still
;       mapped over WIN1).
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_WIN2PAGE
	DEFINE	_WIN2PAGE

	INCLUDE "dss.inc"

	MODULE	WIN2PAGE

CLAIM
	LD	B,1			; one 16 KB page
	LD	C,DSS_GETMEM
	RST	DSS
	RET	C			; A = DSS error code
	LD	B,0			; A = block id, page index 0
	LD	C,DSS_SETWIN2
	RST	DSS
	RET

NO_PAGE_EXIT
	LD	B,3
	LD	C,DSS_EXIT
	RST	DSS

	ENDMODULE
	ENDIF
