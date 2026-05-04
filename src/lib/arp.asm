; ======================================================
; ARP frame helpers for the Sprinter RTL8019AS network kit.
; Currently provides only request-frame construction; the
; receive-side filter and ring-loop stay in each app since
; the matching predicate (ARP reply for our target IP) is
; trivial enough to inline.
;
; Caller must populate the pointer slots once at startup:
;   LD   HL, OUR_MAC
;   LD   (@ARP.OUR_MAC_PTR), HL
;   LD   HL, OUR_IP
;   LD   (@ARP.OUR_IP_PTR), HL
;
; Then to build a 60-byte broadcast ARP request:
;   LD   DE, TX_BUF
;   LD   HL, TARGET_IP
;   CALL @ARP.BUILD_REQUEST
;
; Guard the include with `DEFINE USE_ARP_BUILD_REQUEST`
; before `INCLUDE "arp.asm"` so the body is emitted only in
; apps that actually need it.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_ARP
	DEFINE	_ARP

	MODULE ARP

	IFDEF USE_ARP_BUILD_REQUEST

; Pointer storage. Caller writes OUR_MAC_PTR (->6 bytes) and
; OUR_IP_PTR (->4 bytes) before BUILD_REQUEST.
OUR_MAC_PTR	DW 0
OUR_IP_PTR	DW 0

; ------------------------------------------------------
; ARP.BUILD_REQUEST: assemble a 60-byte broadcast ARP
; "who-has" frame at (DE).
;   In:  DE = destination buffer.
;        HL = pointer to 4-byte target IP.
;   Out: (DE..DE+59) populated with frame; DE = DE + 60.
; Trashes A, BC, HL.
; ------------------------------------------------------
BUILD_REQUEST
	PUSH	HL			; save target_ip_ptr
	; DST = FF*6
	LD	A,0xFF
	LD	B,6
.DST
	LD	(DE),A
	INC	DE
	DJNZ	.DST
	; SRC = (OUR_MAC_PTR)
	LD	HL,(OUR_MAC_PTR)
	LD	BC,6
	LDIR
	; EtherType = 0x0806 (BE)
	LD	A,0x08
	LD	(DE),A
	INC	DE
	LD	A,0x06
	LD	(DE),A
	INC	DE
	; -- ARP body --
	XOR	A			; HW type hi
	LD	(DE),A
	INC	DE
	LD	A,1			; HW type lo (Ethernet)
	LD	(DE),A
	INC	DE
	LD	A,0x08			; Proto type hi
	LD	(DE),A
	INC	DE
	XOR	A			; Proto type lo (IPv4 = 0x0800)
	LD	(DE),A
	INC	DE
	LD	A,6			; HW size
	LD	(DE),A
	INC	DE
	LD	A,4			; Proto size
	LD	(DE),A
	INC	DE
	XOR	A			; Op hi
	LD	(DE),A
	INC	DE
	LD	A,1			; Op lo (request)
	LD	(DE),A
	INC	DE
	; Sender MAC = (OUR_MAC_PTR)
	LD	HL,(OUR_MAC_PTR)
	LD	BC,6
	LDIR
	; Sender IP = (OUR_IP_PTR)
	LD	HL,(OUR_IP_PTR)
	LD	BC,4
	LDIR
	; Target MAC = 0*6
	XOR	A
	LD	B,6
.TGT_MAC
	LD	(DE),A
	INC	DE
	DJNZ	.TGT_MAC
	; Target IP from saved HL (4 bytes)
	POP	HL
	LD	BC,4
	LDIR
	; Pad to 60 bytes (14 ETH + 28 ARP = 42; 18 bytes of zero pad).
	XOR	A
	LD	B,18
.PAD
	LD	(DE),A
	INC	DE
	DJNZ	.PAD
	RET

	ENDIF

	ENDMODULE
	ENDIF
