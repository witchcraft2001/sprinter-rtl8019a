; ======================================================
; coldctx.inc -- shared field layout for the WIN0-cold-code parameter
; block, agreed between src/dll/unetrtl.asm (which builds the block
; once, in its own relocatable data area, and passes its address as
; IX to WIN0COLD.RUN) and src/dll/unetrtl_cold.asm (which reads it
; via +offset from IX -- the cold blob never touches an absolute
; address of the main DLL image directly, only via pointers handed
; to it in this block or in registers at call time, since the two
; are assembled and relocated independently).
;
; This block carries the handful of pointers reused across MULTIPLE
; cold functions (TX_BUF/OUR_MAC/OUR_IP/CHECKSUM for the frame
; builders; RX_HDR/RX_BUF/READ_PACKET/ANSWER_REQUEST for the
; WAIT_ARP/WAIT_DNS/WAIT_REPLY drain functions); anything specific to
; one call (a hostname pointer, resolve_lib's or icmp_lib's own BSS
; base) rides in registers instead, computed by the hot caller with
; an ordinary "LD reg,label" right before the call -- that
; instruction is just as relocatable as any other, so there is no
; need to pre-stage it here.  Literal offsets only, never a computed
; difference of two addresses (this project's relocation rule -- see
; AGENTS.md).
;
; RING_HAS_PACKET is deliberately NOT reachable from cold code: on a
; truly empty ring with ISR.OVW latched it calls RECOVER_OVERFLOW,
; which does ISA_CLOSE (unconditional EI if the caller had interrupts
; enabled) / DELAY / ISA_OPEN in a poll loop.  If that EI fired while
; WIN0COLD.RUN still has PAGE0 mapped to this cold blob, an interrupt
; landing in that instant would vector into cold-blob bytes instead
; of the real Z80 interrupt entry -- worse than the ISA-window hazard
; this project's ISA_OPEN/ISA_CLOSE discipline already guards against,
; since it corrupts the interrupt path itself.  The hot caller always
; calls the real RING_HAS_PACKET itself (so any needed overflow
; recovery runs hot, PAGE0 normal) and only enters a cold DRAIN
; function once a frame is already confirmed present.
; ======================================================

	IFNDEF	_COLDCTX_INC
	DEFINE	_COLDCTX_INC

; ---- offsets within the COLD_CTX block itself ----
CCTX_TX_BUF		EQU 0		; DW: &@MAIN.TX_BUF
CCTX_OUR_MAC		EQU 2		; DW: &@MAIN.OUR_MAC
CCTX_OUR_IP		EQU 4		; DW: &@MAIN.OUR_IP
CCTX_CHECKSUM		EQU 6		; DW: &@UTIL.CHECKSUM
CCTX_RX_HDR		EQU 8		; DW: &@MAIN.RX_HDR
CCTX_RX_BUF		EQU 10		; DW: &@MAIN.RX_BUF
CCTX_READ_PACKET	EQU 12		; DW: &@RTL.READ_PACKET
CCTX_ANSWER_REQUEST	EQU 14		; DW: &@ARP.ANSWER_REQUEST
CCTX_PARSE_DEC_BYTE	EQU 16		; DW: &@UTIL.PARSE_DEC_BYTE
CCTX_SIZE		EQU 18

; RX_BUF_SIZE mirrors unetrtl.asm's MODULE MAIN RX_BUF_SIZE literally
; (the cold blob is a separate assembly and cannot see that EQU) --
; if that value ever changes, this one must change with it.
RX_BUF_SIZE_LIT		EQU 1514

; ---- offsets from a passed &RESOLVE_DNS_IP (resolve_lib's BSS base),
; mirroring src/include/memmap.inc's RESOLVE_* block exactly.  Only
; the fields the cold DNS/ARP builders need are listed here. ----
RSBO_DNS_IP		EQU 0x00	; 4
RSBO_NEXT_HOP_IP	EQU 0x04	; 4
RSBO_NEXT_HOP_MAC	EQU 0x08	; 6
RSBO_NET_MASK		EQU 0x0E	; 4
RSBO_NET_GW		EQU 0x12	; 4
RSBO_HAS_MASK		EQU 0x16	; 1
RSBO_HAS_GW		EQU 0x17	; 1
RSBO_XID_HI		EQU 0x18	; 1
RSBO_XID_LO		EQU 0x19	; 1
RSBO_TIMEOUT_LEFT	EQU 0x1A	; 2
RSBO_DNS_MSG_PTR	EQU 0x1E	; 2
RSBO_DNS_MSG_LEN	EQU 0x20	; 2

; ---- offsets from a passed &ICMPLIB_TARGET_IP (icmp_lib's BSS base),
; mirroring memmap.inc's ICMPLIB_* block exactly. ----
ICMBO_TARGET_IP		EQU 0x00	; 4
ICMBO_TARGET_MAC	EQU 0x04	; 6
ICMBO_SEQ		EQU 0x0A	; 2
ICMBO_TIMEOUT_LEFT	EQU 0x0C	; 2
ICMBO_PAYLOAD_LEN	EQU 0x0E	; 1

; ---- cold dispatch function codes (A on WIN0COLD.RUN entry) ----
CFN_BUILD_ARP_REQUEST	EQU 0
CFN_BUILD_DNS_QUERY	EQU 1
CFN_PARSE_DNS_REPLY	EQU 2
CFN_BUILD_ICMP_ECHO	EQU 3
CFN_NEXT_HOP		EQU 4
CFN_DRAIN_ARP		EQU 5
CFN_DRAIN_DNS		EQU 6
CFN_DRAIN_ICMP		EQU 7
CFN_PARSE_LITERAL_IP	EQU 8

	ENDIF
