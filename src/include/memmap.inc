; ======================================================
; Project-wide runtime BSS memory map.
;
; All zero-filled work buffers used by the kit's libraries
; and apps live in directly-addressable Z80 RAM above the
; loaded image and below the 0xC000 banking window.
; sjasmplus does NOT emit bytes for these regions, so they
; stay out of the .EXE on disk -- they are pure runtime
; state, initialized by the code that uses them.
;
; The map is fixed and shared by every utility. Two libraries
; whose buffers overlap MUST NOT be active in the same EXE.
; When adding a new buffer or a new combination of libraries,
; update this map.
; ======================================================

	IFNDEF	_MEMMAP_INC
	DEFINE	_MEMMAP_INC

; ----- Shared library BSS (0xA000..0xAFFF) ---------------

; util.asm: 4-byte hex-print scratch.
UTIL_HBUF		EQU 0xA000

; rtl8019.asm: 10-byte register snapshot scratch.
RTL_REG_SNAPSHOT	EQU 0xA010

; netenv_lib: 256-byte GETENV value buffer.
NETENV_VAL_BUF		EQU 0xA020
NETENV_VAL_BUF_SIZE	EQU 256

; cmdline_lib: ARGC + ARGV[16] (32 bytes) + CONSUMED[16].
CMDL_ARGC		EQU 0xA100
CMDL_ARGV		EQU 0xA101
CMDL_CONSUMED		EQU 0xA121

; netcfg_lib: parsed-field outputs + 1024-byte file read
; buffer.  Active only in NETCFG.EXE -- no other utility
; includes netcfg_lib.
NETCFG_OUR_MAC		EQU 0xA200	; 6 bytes
NETCFG_OUR_IP		EQU 0xA206	; 4 bytes
NETCFG_NETMASK		EQU 0xA20A	; 4 bytes
NETCFG_GATEWAY		EQU 0xA20E	; 4 bytes
NETCFG_DNS1		EQU 0xA212	; 4 bytes
NETCFG_DNS2		EQU 0xA216	; 4 bytes
NETCFG_NTP		EQU 0xA21A	; 32 bytes
NETCFG_TZ		EQU 0xA23A	; 1 byte
NETCFG_LOAD_FH		EQU 0xA23B	; 1 byte
NETCFG_LOAD_BUF		EQU 0xA240	; 1024 bytes
NETCFG_LOAD_BUF_SIZE	EQU 1024
NETCFG_TMP_IP		EQU 0xA640	; 4 bytes (parser scratch)
NETCFG_TMP_MAC		EQU 0xA644	; 6 bytes (parser scratch)

; ----- Per-app private BSS (0xB000+) ---------------------

; Each app lays out its own scratch starting at this base.
; Apps never share BSS (different EXEs, different sessions).
APP_BSS_BASE		EQU 0xB000

	ENDIF
