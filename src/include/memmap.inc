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

; ----- BSS relocation bases ------------------------------
;
; Every address below is <base> + offset.  Executables take the
; defaults and keep the historical absolute map byte for byte.
;
; A libman DLL cannot use absolute 0xA000..0xAFFF: that range sits
; inside window 2, and libman may pack another library into the same
; 16 KB page, so anything past the declared image length may belong
; to somebody else.  src/dll/*.asm therefore sets LIBBSS_CUSTOM and
; points these bases at labels inside its own in-image DS block
; BEFORE including this file.  See the header of src/dll/unetrtl.asm.
;
; Rule for anything derived from these: sizes must be literals, never
; a difference of two addresses.  In a relocatable image the two
; assembler passes are 0x100 apart and such a difference would be
; marked for relocation.
	IFNDEF	LIBBSS_CUSTOM
LIBBSS_BASE		EQU 0xA000	; util + rtl driver + netenv
CMDL_BSS_BASE		EQU 0xA100	; cmdline_lib
RESOLVE_BSS_BASE	EQU 0xA900	; resolve_lib
TCP_BSS_BASE		EQU 0xAA00	; tcp_lib
UDP_BSS_BASE		EQU 0xAA40	; udp_lib   (0xAA26..0xAAFF was free)
ICMP_BSS_BASE		EQU 0xAA60	; icmp_lib
	ENDIF

; ----- Shared library BSS (0xA000..0xAFFF) ---------------

; util.asm: 4-byte hex-print scratch.
UTIL_HBUF		EQU LIBBSS_BASE + 0x000

; util.asm: 4-byte scratch for PRINT_DEC_32 (long-division work).
UTIL_DEC32_SCRATCH	EQU LIBBSS_BASE + 0x004

; util.asm: throughput-metric state, used by USE_UTIL_TPUT.
;   START   = transfer start time (24-bit seconds-of-day, LE)
;   ELAPSED = transfer duration  (24-bit seconds, LE)
; UTIL_HBUF is reused as a 4-byte stash of the bytes-transferred
; argument across the multiple PRINT_DEC_32 calls in TPUT_REPORT
; (each of which destroys UTIL_DEC32_SCRATCH).  UTIL_DEC32_SCRATCH
; in turn doubles as both the SECONDS_OF_DAY accumulator (during
; TPUT_NOW) and the in-place dividend / quotient for DIV32_BY_DE
; (during rate calc) -- safe because the steps are sequential.
UTIL_TPUT_START		EQU LIBBSS_BASE + 0x008	; 3 bytes
UTIL_TPUT_ELAPSED	EQU LIBBSS_BASE + 0x00B	; 3 bytes

; Shared RX wait-loop drain counter (1 byte).  Wait loops in the
; apps/libraries pull packets back-to-back while the ring is
; non-empty, paying the slow per-tick delay+SCANKEY only when the
; ring drains empty or this budget is spent.  Only one wait loop is
; ever active at a time within an EXE, so a single shared byte is
; safe.  Lives in the otherwise-unused tail of the util scratch gap.
RX_DRAIN_LEFT		EQU LIBBSS_BASE + 0x00E	; 1 byte
; Max packets pulled back-to-back before forcing a tick (key/timeout
; poll).  Sized to drain the byte-mode RX ring (PSTOP-PSTART = 26
; pages, so at most ~26 minimum-size frames) in one pass.  Bounds Esc
; latency to ~budget x one DMA read.
RX_DRAIN_BUDGET		EQU 32

; rtl8019.asm: 10-byte register snapshot scratch.
RTL_REG_SNAPSHOT	EQU LIBBSS_BASE + 0x010

; rtl8019.asm: 2-byte runtime chip-window base address (e.g.
; 0xC300 for I/O 0x300, 0xC280 for 0x280).  Loaded by
; RTL.INIT_BASE from the N_NET_RTL_IOBASE env var or via auto-
; scan of NE2000 candidate bases.  Driver functions read this
; into IX on entry and access registers as (IX + RTL_xxx_OFF).
RTL_BASE_PTR		EQU LIBBSS_BASE + 0x01A

; rtl8019.asm: last transmit state, captured without DSS calls so
; a caller can print it after closing the ISA window.
RTL_TX_LAST_STAGE	EQU LIBBSS_BASE + 0x01C	; state/error code (see rtl8019.asm)
RTL_TX_LAST_ISR		EQU LIBBSS_BASE + 0x01D	; raw ISR at completion/failure
RTL_TX_LAST_TSR		EQU LIBBSS_BASE + 0x01E	; raw page-0 TSR
RTL_TX_LAST_CR		EQU LIBBSS_BASE + 0x01F	; raw CR

; netenv_lib: 256-byte GETENV value buffer.
; NOTE (pre-existing, unrelated to the DLL): 0x020 + 256 = 0x120, so the
; tail of this buffer overlaps CMDL_ARGC/CMDL_ARGV at +0x100.  Harmless
; today because every app finishes CMDL parsing before it reads env, and
; because real NET_* values are short.  Left as-is deliberately: moving
; CMDL_BSS_BASE would change the EXE map and break the byte-identity gate
; this parameterization is verified with.  The DLL pulls neither buffer.
NETENV_VAL_BUF		EQU LIBBSS_BASE + 0x020
NETENV_VAL_BUF_SIZE	EQU 256

; cmdline_lib: entry-time DSS command-line pointer + ARGC +
; ARGV[16] (32 bytes) + CONSUMED[16].  DSS supplies the pointer
; in IX; every argument-taking app stores it in CMDL_SOURCE_PTR
; as its very first START instruction, before any CALL/RST DSS.
CMDL_ARGC		EQU CMDL_BSS_BASE + 0x00
CMDL_ARGV		EQU CMDL_BSS_BASE + 0x01
CMDL_CONSUMED		EQU CMDL_BSS_BASE + 0x21
CMDL_SOURCE_PTR		EQU CMDL_BSS_BASE + 0x31	; 2 bytes

; rtl8019.asm: SEND_FRAME retry/read-back state.  Kept outside the
; executable image (rather than local DW/DB storage in the driver).
RTL_TX_SOURCE_PTR	EQU LIBBSS_BASE + 0x134	; 2 bytes, caller's frame buffer
RTL_TX_LENGTH		EQU LIBBSS_BASE + 0x136	; 2 bytes
RTL_TX_RETRY_LEFT	EQU LIBBSS_BASE + 0x138	; 1 byte
RTL_TX_VERIFY_BUF	EQU LIBBSS_BASE + 0x140	; 42 bytes read back from NIC packet RAM
RTL_TX_VERIFY_SIZE	EQU 42
RTL_TX_LAST_CLDA	EQU LIBBSS_BASE + 0x16A	; 2 bytes, page-0 CLDA0/1 after TX
RTL_RX_TO_TX_PENDING	EQU LIBBSS_BASE + 0x16C	; 1 byte, successful RX since last TX
RTL_TX_CFG0_PRE	EQU LIBBSS_BASE + 0x16D	; page-3 CONFIG0 immediately before TXP
RTL_TX_CFG3_PRE	EQU LIBBSS_BASE + 0x16E	; page-3 CONFIG3 immediately before TXP
RTL_TX_CFG0_POST	EQU LIBBSS_BASE + 0x16F	; page-3 CONFIG0 after PTX/TXE
RTL_TX_CFG3_POST	EQU LIBBSS_BASE + 0x170	; page-3 CONFIG3 after PTX/TXE
RTL_TX_LAST_NCR	EQU LIBBSS_BASE + 0x171	; page-0 collision count for last TX
RTL_TX_LAST_TPSR EQU LIBBSS_BASE + 0x172	; page-2 read-back of TX start page before TXP
; RX-ring overflow counter (saturating at 255).  A non-zero value
; tells a stalled transfer apart from a peer that simply went
; quiet.  Cleared by INIT_BASE.
RTL_RX_OVW_COUNT EQU LIBBSS_BASE + 0x173	; 1 byte
; RCR value the app configured via INIT_NORMAL.  RECOVER_OVERFLOW
; must restore exactly this after its stop/restart (NICTX runs
; RCR=0, the TCP utilities RCR_AB).  INIT_BASE defaults it to
; RCR_AB for code paths that touch recovery before INIT_NORMAL.
RTL_RCR_SHADOW	EQU LIBBSS_BASE + 0x174	; 1 byte
; SEND_FRAME/WAIT_PTX failure counter (saturating at 255).
; Printed by the app failure dumps next to ovw: separates a deaf
; receiver (tx=0, silence) from a dead transmitter (tx>0, our
; ACKs never leave).  Cleared by INIT_BASE.
RTL_TX_FAIL_COUNT EQU LIBBSS_BASE + 0x175	; 1 byte

; Total span of the LIBBSS_BASE region (util + rtl + netenv + rtl tx).
LIBBSS_SIZE		EQU 0x176

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
NETCFG_DHCP_MODE	EQU 0xA23C	; 1 byte (1 if IP=DHCP, 0 otherwise)
NETCFG_LOAD_FH		EQU 0xA23B	; 1 byte
; Parser scratch placed BEFORE the big file buffer so the buffer
; can be enlarged without colliding.
NETCFG_TMP_IP		EQU 0xA240	; 4 bytes (parser scratch)
NETCFG_TMP_MAC		EQU 0xA244	; 6 bytes (parser scratch)
NETCFG_OUR_RTL_HW	EQU 0xA24A	; 8 bytes ASCIIZ "S/#HHH" or empty
NETCFG_PATH_BUF		EQU 0xA254	; 280 bytes: "<appdir>\NET.CFG",0 (APPINFO)
; File read buffer: 2 KB so a fully-commented NET.CFG template
; (the shipped sample is ~1.2 KB) is read whole, not truncated.
; Truncation silently dropped trailing keys (DNS/TZ/NTP).  NETCFG.EXE
; pulls no other big-buffer library, so 0xA380..0xAB80 is free here
; and stays below APP_BSS_BASE (0xB000).
NETCFG_LOAD_BUF		EQU 0xA380	; 2048 bytes
NETCFG_LOAD_BUF_SIZE	EQU 2048

; dhcp_lib: parsed-field outputs.  Active only in IFUP.EXE.
DHCP_XID		EQU 0xA800	; 4 bytes (transaction id, host order)
DHCP_MSG_TYPE		EQU 0xA804	; 1 byte (option 53 from reply)
DHCP_OFFERED_IP		EQU 0xA805	; 4 bytes (yiaddr from OFFER/ACK)
DHCP_SERVER_ID		EQU 0xA809	; 4 bytes (option 54)
DHCP_MASK		EQU 0xA80D	; 4 bytes (option 1)
DHCP_ROUTER		EQU 0xA811	; 4 bytes (option 3)
DHCP_DNS1		EQU 0xA815	; 4 bytes (option 6, first)
DHCP_DNS2		EQU 0xA819	; 4 bytes (option 6, second)
DHCP_LEASE_SECS		EQU 0xA81D	; 4 bytes (option 51, BE)

; resolve_lib: private BSS for hostname-or-IP resolution
; (DNS A query helper).  Active only in apps that pull
; resolve_lib (PING / UDPTEST / TFTP / NTP).
RESOLVE_DNS_IP		EQU RESOLVE_BSS_BASE + 0x00	; 4 bytes
RESOLVE_NEXT_HOP_IP	EQU RESOLVE_BSS_BASE + 0x04	; 4 bytes
RESOLVE_NEXT_HOP_MAC	EQU RESOLVE_BSS_BASE + 0x08	; 6 bytes
RESOLVE_NET_MASK	EQU RESOLVE_BSS_BASE + 0x0E	; 4 bytes
RESOLVE_NET_GW		EQU RESOLVE_BSS_BASE + 0x12	; 4 bytes
RESOLVE_HAS_MASK	EQU RESOLVE_BSS_BASE + 0x16	; 1 byte
RESOLVE_HAS_GW		EQU RESOLVE_BSS_BASE + 0x17	; 1 byte
RESOLVE_XID_HI		EQU RESOLVE_BSS_BASE + 0x18	; 1 byte
RESOLVE_XID_LO		EQU RESOLVE_BSS_BASE + 0x19	; 1 byte
RESOLVE_TIMEOUT_LEFT	EQU RESOLVE_BSS_BASE + 0x1A	; 2 bytes
RESOLVE_QFRAME_LEN	EQU RESOLVE_BSS_BASE + 0x1C	; 2 bytes
RESOLVE_DNS_MSG_PTR	EQU RESOLVE_BSS_BASE + 0x1E	; 2 bytes
RESOLVE_DNS_MSG_LEN	EQU RESOLVE_BSS_BASE + 0x20	; 2 bytes
RESOLVE_IP_TOTAL	EQU RESOLVE_BSS_BASE + 0x22	; 2 bytes
RESOLVE_UDP_LEN		EQU RESOLVE_BSS_BASE + 0x24	; 2 bytes
RESOLVE_DEST_PTR	EQU RESOLVE_BSS_BASE + 0x26	; 2 bytes (caller's output IP buffer)
RESOLVE_ARP_RETRY_LEFT	EQU RESOLVE_BSS_BASE + 0x28	; 1 byte

; Maximum DNS query/reply Ethernet frame size.  Apps that
; pull resolve_lib must size their TX_BUF region to at
; least this many bytes so the resolver can build a query.
RESOLVE_MAX_FRAME	EQU 320

; tcp_lib: single-session TCP state.  Active only in apps
; that pull tcp_lib (WGET, future FTP).  Sequence numbers
; stored in network (big-endian) byte order to simplify
; wire-format reads/writes.
TCP_STATE		EQU TCP_BSS_BASE + 0x00	; 1 byte (CLOSED/SYN_SENT/...)
TCP_REMOTE_IP		EQU TCP_BSS_BASE + 0x01	; 4 bytes (set by caller)
TCP_REMOTE_MAC		EQU TCP_BSS_BASE + 0x05	; 6 bytes (next-hop, caller ARPs)
TCP_REMOTE_PORT_HI	EQU TCP_BSS_BASE + 0x0B	; 1 byte (BE)
TCP_REMOTE_PORT_LO	EQU TCP_BSS_BASE + 0x0C	; 1 byte (BE)
TCP_LOCAL_PORT_HI	EQU TCP_BSS_BASE + 0x0D	; 1 byte (BE)
TCP_LOCAL_PORT_LO	EQU TCP_BSS_BASE + 0x0E	; 1 byte (BE)
TCP_SND_NXT		EQU TCP_BSS_BASE + 0x10	; 4 bytes (BE)
TCP_SND_UNA		EQU TCP_BSS_BASE + 0x14	; 4 bytes (BE)
TCP_RCV_NXT		EQU TCP_BSS_BASE + 0x18	; 4 bytes (BE)
TCP_TIMEOUT_LEFT	EQU TCP_BSS_BASE + 0x1C	; 2 bytes
TCP_LAST_FAIL		EQU TCP_BSS_BASE + 0x1E	; 1 byte
TCP_TX_LEN		EQU TCP_BSS_BASE + 0x20	; 2 bytes (last TX segment size)
TCP_RX_DATA_PTR		EQU TCP_BSS_BASE + 0x22	; 2 bytes (-> data inside RX_BUF)
TCP_RX_DATA_LEN		EQU TCP_BSS_BASE + 0x24	; 2 bytes (data byte count)
; Ephemeral-port salt, deliberately OUTSIDE the TCP_CTX_SIZE swap
; block: it must evolve monotonically across every OPEN (including
; FTP's ctrl/data context swaps), never travel with a saved
; context.  Never initialized: the power-on/previous-run RAM
; content is the entropy seed, mixed with R on every OPEN.
TCP_PORT_SALT		EQU TCP_BSS_BASE + 0x26	; 2 bytes

; Synchronous SEND/retransmit scratch.  Also outside TCP_CTX_SIZE because
; the option is currently enabled only by the one-session UNETRTL DLL.
; ACK_WAIT_RX_PENDING may remain live after SEND returns, so a future
; context-swapping consumer must move this state into its saved context.
TCP_ACK_WAIT_STATE	EQU TCP_BSS_BASE + 0x28	; 0 idle, 1 ACK wait, 2 RX pending
TCP_ACK_WAIT_TARGET	EQU TCP_BSS_BASE + 0x29	; 4 bytes (BE cumulative ACK target)
TCP_SEND_SEQ		EQU TCP_BSS_BASE + 0x2D	; 4 bytes (BE sequence used by retries)
TCP_SEND_RETRY_LEFT	EQU TCP_BSS_BASE + 0x31	; 1 byte
TCP_RECV_UNACKED	EQU TCP_BSS_BASE + 0x32	; 1 byte (full-context DLL build)
TCP_RECV_TIMEOUT	EQU TCP_BSS_BASE + 0x33	; 2 bytes (one-shot override)

; Total per-session TCP state size; copied wholesale by
; TCP.SAVE_CTX / TCP.RESTORE_CTX so apps can multiplex
; multiple sessions sequentially (FTP control + data).
; Literal, NOT a difference of two addresses: in a relocatable DLL
; image the operands would be relocated and the size would be wrong.
TCP_CTX_SIZE		EQU 38		; 0x26: TCP_STATE .. TCP_RX_DATA_LEN+1

; Entire tcp_lib BSS span including non-context scratch above.
; Literal for relocatable DLL builds; never derive this from addresses.
TCP_BSS_SIZE		EQU 53		; 0x35 bytes

; tcp_lib max outgoing Ethernet frame: 14 + 20 + 20 + MSS(536)
; = 590 bytes.  Apps that pull tcp_lib must size TX_BUF
; region to at least this.
TCP_MAX_FRAME		EQU 600

; udp_lib: connected-UDP session state.  Active only in code that
; pulls udp_lib (currently the UNET DLL).
UDPLIB_REMOTE_IP		EQU UDP_BSS_BASE + 0x00	; 4 bytes
UDPLIB_REMOTE_MAC		EQU UDP_BSS_BASE + 0x04	; 6 bytes (next-hop)
UDPLIB_REMOTE_PORT		EQU UDP_BSS_BASE + 0x0A	; 2 bytes (host order)
UDPLIB_LOCAL_PORT		EQU UDP_BSS_BASE + 0x0C	; 2 bytes (host order)
UDPLIB_PAYLOAD_PTR		EQU UDP_BSS_BASE + 0x0E	; 2 bytes
UDPLIB_PAYLOAD_LEN		EQU UDP_BSS_BASE + 0x10	; 2 bytes
UDPLIB_TIMEOUT_LEFT	EQU UDP_BSS_BASE + 0x12	; 2 bytes
UDPLIB_RX_LEN		EQU UDP_BSS_BASE + 0x14	; 2 bytes
UDPLIB_LAST_FAIL		EQU UDP_BSS_BASE + 0x16	; 1 byte
UDPLIB_RX_FLAGS		EQU UDP_BSS_BASE + 0x17	; 1 byte (bit0 truncated)
UDPLIB_BSS_SIZE		EQU 0x18

; udp_lib max payload.  Bounded by @MAIN.TX_BUF: 14 + 20 + 8 + 1024
; = 1066 bytes.  Callers that want more must enlarge TX_BUF too.
UDPLIB_MAX_PAYLOAD		EQU 1024
UDPLIB_MAX_FRAME		EQU 1066

; icmp_lib: echo request/reply state.  Active only in code that
; pulls icmp_lib (currently the UNET DLL).
ICMPLIB_TARGET_IP		EQU ICMP_BSS_BASE + 0x00	; 4 bytes
ICMPLIB_TARGET_MAC		EQU ICMP_BSS_BASE + 0x04	; 6 bytes (next-hop)
ICMPLIB_SEQ		EQU ICMP_BSS_BASE + 0x0A	; 2 bytes
ICMPLIB_TIMEOUT_LEFT	EQU ICMP_BSS_BASE + 0x0C	; 2 bytes
ICMPLIB_PAYLOAD_LEN	EQU ICMP_BSS_BASE + 0x0E	; 1 byte
ICMPLIB_LAST_FAIL		EQU ICMP_BSS_BASE + 0x0F	; 1 byte
ICMPLIB_BSS_SIZE		EQU 0x10

; icmp_lib max outgoing frame: 14 + 20 + 8 + payload(<=255) = 297.
ICMPLIB_MAX_FRAME		EQU 300

; pagemem.asm: state for a single allocated paged-RAM block.
; Apps that pull pagemem (currently WGET) get a 32 KB buffer
; backed by 2 paged frames; the cap below is set generously so
; the helper can grow without touching memmap.
;   BLOCK_ID  byte (0xFF = no block held)
;   PHYS      PAGEMEM_MAX_PAGES bytes -- physical page numbers
;             cached at ALLOC time (queried via BIOS EMM_FN4)
;             so callers can program the PAGE0..3 ports directly
;             without further BIOS/DSS calls.
PAGEMEM_BLOCK_ID	EQU 0xAB00	; 1 byte
PAGEMEM_PHYS		EQU 0xAB01	; PAGEMEM_MAX_PAGES bytes

; file_lib: scratch for OPEN_OUTPUT path support.  When the
; supplied filename includes '/' or '\\', file_lib stages the
; directory part in FILE_DIR_BUF, CHDIRs there, creates the
; file with just the basename, and restores CWD from
; FILE_SAVED_CWD before returning.  128 bytes each is enough
; for the DSS path conventions.
FILE_SAVED_CWD		EQU 0xAC00	; 128 bytes
FILE_DIR_BUF		EQU 0xAC80	; 128 bytes

; file_lib OPEN_APPEND (USE_FILE_APPEND): prior size of the
; reopened file (4-byte LE) + handle scratch for the seek.
FILE_APPEND_SIZE	EQU 0xAD00	; 4 bytes
FILE_FH_SCRATCH		EQU 0xAD04	; 1 byte
; Set by OPEN_OUTPUT_ORC when the user answers Cancel, so the
; caller can exit quietly (EX_CANCEL) instead of reporting an
; I/O error.  Cleared at every OPEN_OUTPUT_ORC entry.
FILE_CANCELLED		EQU 0xAD05	; 1 byte

; ----- Per-app private BSS (0xB000+) ---------------------

; Each app lays out its own scratch starting at this base.
; Apps never share BSS (different EXEs, different sessions).
APP_BSS_BASE		EQU 0xB000

; ----- Runtime stack top ---------------------------------

; Stack top for large-variant utilities (image at 0x4200), used
; by the CLAIM_RUNTIME_PAGE macro.  It is deliberately inside
; WIN2 rather than WIN1: a stack in WIN1 does not survive a DSS
; console print that scrolls, because BIOS WIN_MOVE maps the
; video page over WIN1 and restores SLOT1 from a POP taken while
; that page is still mapped.  The page under it is the private
; one claimed by WIN2PAGE.CLAIM, so every app BSS map must stay
; clear of the space below this address.
RT_STACK_TOP		EQU 0xBFF0

	ENDIF
