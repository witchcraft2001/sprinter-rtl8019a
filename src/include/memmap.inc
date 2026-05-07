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

; util.asm: 4-byte scratch for PRINT_DEC_32 (long-division work).
UTIL_DEC32_SCRATCH	EQU 0xA004

; rtl8019.asm: 10-byte register snapshot scratch.
RTL_REG_SNAPSHOT	EQU 0xA010

; rtl8019.asm: 2-byte runtime chip-window base address (e.g.
; 0xC300 for I/O 0x300, 0xC280 for 0x280).  Loaded by
; RTL.INIT_BASE from the N_NET_RTL_IOBASE env var or via auto-
; scan of NE2000 candidate bases.  Driver functions read this
; into IX on entry and access registers as (IX + RTL_xxx_OFF).
RTL_BASE_PTR		EQU 0xA01A

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
NETCFG_DHCP_MODE	EQU 0xA23C	; 1 byte (1 if IP=DHCP, 0 otherwise)
NETCFG_LOAD_FH		EQU 0xA23B	; 1 byte
NETCFG_LOAD_BUF		EQU 0xA240	; 1024 bytes
NETCFG_LOAD_BUF_SIZE	EQU 1024
NETCFG_TMP_IP		EQU 0xA640	; 4 bytes (parser scratch)
NETCFG_TMP_MAC		EQU 0xA644	; 6 bytes (parser scratch)

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
RESOLVE_DNS_IP		EQU 0xA900	; 4 bytes
RESOLVE_NEXT_HOP_IP	EQU 0xA904	; 4 bytes
RESOLVE_NEXT_HOP_MAC	EQU 0xA908	; 6 bytes
RESOLVE_NET_MASK	EQU 0xA90E	; 4 bytes
RESOLVE_NET_GW		EQU 0xA912	; 4 bytes
RESOLVE_HAS_MASK	EQU 0xA916	; 1 byte
RESOLVE_HAS_GW		EQU 0xA917	; 1 byte
RESOLVE_XID_HI		EQU 0xA918	; 1 byte
RESOLVE_XID_LO		EQU 0xA919	; 1 byte
RESOLVE_TIMEOUT_LEFT	EQU 0xA91A	; 2 bytes
RESOLVE_QFRAME_LEN	EQU 0xA91C	; 2 bytes
RESOLVE_DNS_MSG_PTR	EQU 0xA91E	; 2 bytes
RESOLVE_DNS_MSG_LEN	EQU 0xA920	; 2 bytes
RESOLVE_IP_TOTAL	EQU 0xA922	; 2 bytes
RESOLVE_UDP_LEN		EQU 0xA924	; 2 bytes
RESOLVE_DEST_PTR	EQU 0xA926	; 2 bytes (caller's output IP buffer)

; Maximum DNS query/reply Ethernet frame size.  Apps that
; pull resolve_lib must size their TX_BUF region to at
; least this many bytes so the resolver can build a query.
RESOLVE_MAX_FRAME	EQU 320

; tcp_lib: single-session TCP state.  Active only in apps
; that pull tcp_lib (WGET, future FTP).  Sequence numbers
; stored in network (big-endian) byte order to simplify
; wire-format reads/writes.
TCP_STATE		EQU 0xAA00	; 1 byte (CLOSED/SYN_SENT/...)
TCP_REMOTE_IP		EQU 0xAA01	; 4 bytes (set by caller)
TCP_REMOTE_MAC		EQU 0xAA05	; 6 bytes (next-hop, caller ARPs)
TCP_REMOTE_PORT_HI	EQU 0xAA0B	; 1 byte (BE)
TCP_REMOTE_PORT_LO	EQU 0xAA0C	; 1 byte (BE)
TCP_LOCAL_PORT_HI	EQU 0xAA0D	; 1 byte (BE)
TCP_LOCAL_PORT_LO	EQU 0xAA0E	; 1 byte (BE)
TCP_SND_NXT		EQU 0xAA10	; 4 bytes (BE)
TCP_SND_UNA		EQU 0xAA14	; 4 bytes (BE)
TCP_RCV_NXT		EQU 0xAA18	; 4 bytes (BE)
TCP_TIMEOUT_LEFT	EQU 0xAA1C	; 2 bytes
TCP_LAST_FAIL		EQU 0xAA1E	; 1 byte
TCP_TX_LEN		EQU 0xAA20	; 2 bytes (last TX segment size)
TCP_RX_DATA_PTR		EQU 0xAA22	; 2 bytes (-> data inside RX_BUF)
TCP_RX_DATA_LEN		EQU 0xAA24	; 2 bytes (data byte count)

; Total per-session TCP state size; copied wholesale by
; TCP.SAVE_CTX / TCP.RESTORE_CTX so apps can multiplex
; multiple sessions sequentially (FTP control + data).
TCP_CTX_SIZE		EQU 0xAA26 - 0xAA00	; 38 bytes

; tcp_lib max outgoing Ethernet frame: 14 + 20 + 20 + MSS(536)
; = 590 bytes.  Apps that pull tcp_lib must size TX_BUF
; region to at least this.
TCP_MAX_FRAME		EQU 600

; ----- Per-app private BSS (0xB000+) ---------------------

; Each app lays out its own scratch starting at this base.
; Apps never share BSS (different EXEs, different sessions).
APP_BSS_BASE		EQU 0xB000

	ENDIF
