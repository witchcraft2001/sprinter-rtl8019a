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
; ANSWER_REQUEST (gated by USE_ARP_ANSWER) is the receive-side
; counterpart: reply to "who-has <our IP>" seen in @MAIN.RX_BUF
; while a higher-level wait loop is running.  Routers routinely
; ARP for the sender before returning ICMP/UDP replies, and
; ignoring that request looks exactly like RX loss.  It lives
; here rather than in icmp_lib/udp_lib because it is pure ARP
; and both of them (plus PING.EXE) need the same behaviour.
;
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_ARP
	DEFINE	_ARP

	MODULE ARP

	IFDEF USE_ARP_ANSWER			; implies the pointer slots
	IFNDEF USE_ARP_BUILD_REQUEST
	DEFINE USE_ARP_BUILD_REQUEST
	ENDIF
	ENDIF

	IFDEF USE_ARP_BUILD_REQUEST

ETH_TYPE_ARP	EQU 0x0806
ETH_TYPE_IPV4	EQU 0x0800
ARP_OP_REQUEST	EQU 1
ARP_OP_REPLY	EQU 2
ARP_FRAME_LEN	EQU 60

; Pointer storage. Caller writes OUR_MAC_PTR (->6 bytes) and
; OUR_IP_PTR (->4 bytes) before BUILD_REQUEST.
OUR_MAC_PTR	DW 0
OUR_IP_PTR	DW 0

; ------------------------------------------------------
; ARP.BUILD_REQUEST: assemble a 60-byte broadcast ARP
; "who-has" frame at (DE).  Excluded from UNET_DLL builds (image
; budget): resolve_lib.asm's DLL-mode callers redirect to the WIN0
; cold blob's FN_BUILD_ARP_REQUEST instead (see win0cold.asm /
; unetrtl_cold.asm) -- pure register/buffer logic with no RST, safe
; to run with DSS/BIOS unreachable.
;   In:  DE = destination buffer.
;        HL = pointer to 4-byte target IP.
;   Out: (DE..DE+59) populated with frame; DE = DE + 60.
; Trashes A, BC, HL.
; ------------------------------------------------------
	IFNDEF	UNET_DLL
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

	ENDIF

	IFDEF USE_ARP_ANSWER

; ------------------------------------------------------
; ARP.ANSWER_REQUEST: if @MAIN.RX_BUF holds an ARP request
; for our IP, build and transmit the reply.
;   In:  @MAIN.RX_BUF holds a received Ethernet frame.
;        OUR_MAC_PTR / OUR_IP_PTR populated.
;        ISA window OPEN (SEND_FRAME is called).
;   Out: CF=0 a reply was sent (or attempted);
;        CF=1 the frame was not an ARP request for us.
; Trashes A, BC, DE, HL, IX.
; ------------------------------------------------------
ANSWER_REQUEST
	LD	A,(@MAIN.RX_BUF + 12)
	CP	HIGH ETH_TYPE_ARP
	JP	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 13)
	CP	LOW ETH_TYPE_ARP
	JP	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + 0)	; htype hi
	OR	A
	JP	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + 1)	; htype lo = Ethernet
	CP	1
	JP	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + 2)	; ptype hi
	CP	HIGH ETH_TYPE_IPV4
	JP	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + 3)	; ptype lo
	CP	LOW ETH_TYPE_IPV4
	JP	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + 4)	; hlen
	CP	6
	JP	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + 5)	; plen
	CP	4
	JP	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + 6)	; op hi
	OR	A
	JP	NZ,.NO
	LD	A,(@MAIN.RX_BUF + 14 + 7)	; op lo
	CP	ARP_OP_REQUEST
	JP	NZ,.NO
	; Target protocol address must be ours.
	LD	HL,@MAIN.RX_BUF + 14 + 24
	LD	DE,(OUR_IP_PTR)
	LD	B,4
.CMP_TPA
	LD	A,(DE)
	CP	(HL)
	JP	NZ,.NO
	INC	HL
	INC	DE
	DJNZ	.CMP_TPA

	; -- Ethernet header --
	LD	DE,@MAIN.TX_BUF
	LD	HL,@MAIN.RX_BUF + 14 + 8	; DST = requester SHA
	LD	BC,6
	LDIR
	LD	HL,(OUR_MAC_PTR)		; SRC = our MAC
	LD	BC,6
	LDIR
	LD	A,HIGH ETH_TYPE_ARP
	LD	(DE),A
	INC	DE
	LD	A,LOW ETH_TYPE_ARP
	LD	(DE),A
	INC	DE
	; -- ARP body --
	XOR	A
	LD	(DE),A				; htype hi
	INC	DE
	LD	A,1
	LD	(DE),A				; htype lo
	INC	DE
	LD	A,HIGH ETH_TYPE_IPV4
	LD	(DE),A
	INC	DE
	LD	A,LOW ETH_TYPE_IPV4
	LD	(DE),A
	INC	DE
	LD	A,6
	LD	(DE),A				; hlen
	INC	DE
	LD	A,4
	LD	(DE),A				; plen
	INC	DE
	XOR	A
	LD	(DE),A				; op hi
	INC	DE
	LD	A,ARP_OP_REPLY
	LD	(DE),A				; op lo
	INC	DE
	LD	HL,(OUR_MAC_PTR)		; sender MAC
	LD	BC,6
	LDIR
	LD	HL,(OUR_IP_PTR)			; sender IP
	LD	BC,4
	LDIR
	LD	HL,@MAIN.RX_BUF + 14 + 8	; target MAC = requester SHA
	LD	BC,6
	LDIR
	LD	HL,@MAIN.RX_BUF + 14 + 14	; target IP = requester SPA
	LD	BC,4
	LDIR
	XOR	A
	LD	B,18
.PAD2
	LD	(DE),A
	INC	DE
	DJNZ	.PAD2
	LD	HL,@MAIN.TX_BUF
	LD	BC,ARP_FRAME_LEN
	CALL	@RTL.SEND_FRAME
	OR	A				; CF=0: handled
	RET
.NO
	SCF
	RET

	ENDIF

	ENDMODULE
	ENDIF
