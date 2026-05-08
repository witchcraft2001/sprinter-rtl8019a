; ======================================================
; pagemem.asm -- Sprinter paged-RAM helper.
;
; Allocates a paged-memory block via DSS_GETMEM (#3D), then
; queries BIOS_EMM_FN4 (#C4) once per logical page and caches
; the physical page numbers locally.  Callers can subsequently
; map any logical page into any of the four 16 KB MMU windows
; by writing the cached byte directly to PAGE0..PAGE3 ports
; (0x82 / 0xA2 / 0xC2 / 0xE2) -- no further BIOS/DSS calls
; required.  This is mandatory once the user buffer is mapped
; over WIN0 (0x0000..0x3FFF), since DSS code that lives there
; is no longer reachable.
;
; Caller is responsible for DI/EI bracketing around any
; "map -> copy -> restore" sequence.  The library does not
; touch the interrupt flag.
;
; Public API (DEFINE USE_PAGEMEM before INCLUDE):
;
;   PAGEMEM.ALLOC
;       In:  B = number of 16 KB pages (1..PAGEMEM_MAX_PAGES).
;       Out: CF=0 ok, A = block_id;
;            CF=1 -> alloc failed (DSS or BIOS); BLOCK_ID stays
;                    NO_BLOCK and any partial allocation is
;                    rolled back via FREEMEM.
;       Trashes A, BC, DE, HL, IX.
;
;   PAGEMEM.FREE
;       Frees the block held in PAGEMEM_BLOCK_ID; no-op when no
;       block is held.  Out: CF=0 ok.
;       Trashes A, BC.
;
;   PAGEMEM.PHYS_OF
;       In:  B = logical page index (no bounds check).
;       Out: A = physical page byte (write to PAGE0..3 ports).
;       Preserves BC, DE; trashes HL.
;
;   PAGEMEM.SAVE_PAGE0  (read current PAGE0 mapping)
;       Out: A = current PAGE0 byte.  Trashes BC.
;
;   PAGEMEM.SAVE_PAGE3
;       Out: A = current PAGE3 byte.  Trashes BC.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_PAGEMEM
	DEFINE	_PAGEMEM

	INCLUDE "memmap.inc"
	INCLUDE "dss.inc"
	INCLUDE "sprinter.inc"

PAGEMEM_MAX_PAGES	EQU 8			; cap on how many phys bytes we cache

	MODULE PAGEMEM

NO_BLOCK	EQU 0xFF


; ------------------------------------------------------
; ALLOC: see header comment.
; ------------------------------------------------------
ALLOC
	; Validate page count: 1..PAGEMEM_MAX_PAGES.
	LD	A,B
	OR	A
	JR	Z,.BAD
	CP	PAGEMEM_MAX_PAGES + 1
	JR	NC,.BAD
	LD	(.SAVED_N),A
	; DSS GETMEM #3D -- B = pages already set.
	LD	C,DSS_GETMEM
	RST	DSS
	JR	C,.BAD			; alloc rejected, leave BLOCK_ID intact
	LD	(PAGEMEM_BLOCK_ID),A
	; Walk logical indices 0..N-1, store BIOS_EMM_FN4(block_id,i).
	LD	IX,PAGEMEM_PHYS
	LD	A,(.SAVED_N)
	LD	D,A			; D = N
	LD	E,0			; E = current index i
.LP
	LD	A,(PAGEMEM_BLOCK_ID)
	LD	B,E
	LD	C,BIOS_EMM_FN4
	RST	BIOS
	JR	C,.ROLLBACK
	LD	(IX+0),A
	INC	IX
	INC	E
	LD	A,E
	CP	D
	JR	C,.LP
	; Done: A = block_id, CF = 0.
	LD	A,(PAGEMEM_BLOCK_ID)
	OR	A
	RET
.ROLLBACK
	; BIOS query failed: free the block, mark unallocated.
	LD	A,(PAGEMEM_BLOCK_ID)
	LD	C,DSS_FREEMEM
	RST	DSS
	LD	A,NO_BLOCK
	LD	(PAGEMEM_BLOCK_ID),A
.BAD
	SCF
	RET
.SAVED_N	DB 0


; ------------------------------------------------------
; FREE: see header comment.
; ------------------------------------------------------
FREE
	LD	A,(PAGEMEM_BLOCK_ID)
	CP	NO_BLOCK
	JR	Z,.NO_OP
	LD	C,DSS_FREEMEM
	RST	DSS
	LD	A,NO_BLOCK
	LD	(PAGEMEM_BLOCK_ID),A
.NO_OP
	OR	A			; CF=0
	RET


; ------------------------------------------------------
; PHYS_OF: see header comment.
; ------------------------------------------------------
PHYS_OF
	LD	HL,PAGEMEM_PHYS
	LD	A,B
	ADD	A,L
	LD	L,A
	LD	A,0
	ADC	A,H
	LD	H,A
	LD	A,(HL)
	RET


; ------------------------------------------------------
; SAVE_PAGE0 / SAVE_PAGE3: read the current MMU byte of the
; given window so the caller can restore it after copying.
; ------------------------------------------------------
SAVE_PAGE0
	LD	BC,PAGE0
	IN	A,(C)
	RET

SAVE_PAGE3
	LD	BC,PAGE3
	IN	A,(C)
	RET


	ENDMODULE
	ENDIF
