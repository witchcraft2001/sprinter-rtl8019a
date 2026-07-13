; PINGALT.EXE - diagnostic build of PING with the six-page TX buffer moved
; from packet-RAM page 0x40 to 0x46.  All application/protocol logic remains
; identical to PING.EXE; only the non-overlapping TX/RX packet-RAM layout
; changes through rtl8019.inc.

	DEFINE RTL_ALT_TX_LAYOUT
	INCLUDE "ping.asm"
