; ======================================================
; tcp_ooo.asm -- DLOOO3-only two-segment TCP OOO queue.
;
; This is not part of the general TCP library contract.  It is included
; only by the direct single-session 1460/4380 experiment.  Payload bytes
; are copied from MAIN.RX_BUF while the ISA window is closed, then the
; caller's previous open state is restored before TCP sends its duplicate
; ACK.  The queue is deliberately small: it bridges one missing segment,
; not a substitute for a receive reassembly implementation.
; ======================================================

	IFDEF USE_TCP_RX_OOO
	MODULE TCP_OOO

OOO_WINDOW	EQU 4380

; RESET is used by OPEN and starts a fresh measurement.  CLOSE/RST/cancel
; use RELEASE below: it frees slots but deliberately keeps the counters.
RESET
	LD	HL,TCP_OOO_SLOT0_META
	LD	BC,TCP_OOO_BSS_SIZE	; metadata, diagnostics, and scratch
.CLEAR
	XOR	A
	LD	(HL),A
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.CLEAR
	RET

RELEASE
	XOR	A
	LD	(TCP_OOO_SLOT0_META),A
	LD	(TCP_OOO_SLOT1_META),A
	LD	(TCP_OOO_USED_NOW),A
	LD	(TCP_OOO_RESULT),A
	RET

; STORE -- save an ahead-of-RCV_NXT segment if it wholly fits the advertised
; window and does not overlap an occupied slot.
; In: HL payload pointer, BC payload length, A TCP flags.
; Out: CF=0 saved; CF=1 rejected (duplicate, old, invalid, or no slot).
STORE
	LD	(TCP_OOO_TEMP_PTR),HL
	LD	(TCP_OOO_TEMP_LEN),BC
	LD	(TCP_OOO_TEMP_FLAGS),A
	; Payload may be empty only for a FIN.  No slot ever accepts > MSS.
	LD	A,B
	CP	5
	JR	C,.LEN_OK
	JP	NZ,.BAD_LENGTH
	LD	A,C
	CP	0xB5
	JR	C,.LEN_OK
	JP	.BAD_LENGTH
.LEN_OK
	LD	A,B
	OR	C
	JP	NZ,.HAVE_CONTENT
	LD	A,(TCP_OOO_TEMP_FLAGS)
	AND	0x01
	JP	Z,.BAD_LENGTH
.HAVE_CONTENT
	; delta = incoming SEQ - RCV_NXT, modulo 2^32.  The accepted
	; receive window is only 4380 bytes, so a non-zero high word is
	; necessarily an old/negative sequence, including wrap-around.
	LD	A,(@MAIN.RX_BUF + 14 + 20 + 7)
	LD	C,A
	LD	A,(TCP_RCV_NXT + 3)
	LD	B,A
	LD	A,C
	SUB	B
	LD	E,A
	LD	A,(@MAIN.RX_BUF + 14 + 20 + 6)
	LD	C,A
	LD	A,(TCP_RCV_NXT + 2)
	LD	B,A
	LD	A,C
	SBC	A,B
	LD	D,A
	LD	A,(@MAIN.RX_BUF + 14 + 20 + 5)
	LD	C,A
	LD	A,(TCP_RCV_NXT + 1)
	LD	B,A
	LD	A,C
	SBC	A,B
	JP	NZ,.REJECT
	LD	A,(@MAIN.RX_BUF + 14 + 20 + 4)
	LD	C,A
	LD	A,(TCP_RCV_NXT + 0)
	LD	B,A
	LD	A,C
	SBC	A,B
	JP	NZ,.REJECT
	LD	A,D
	OR	E
	JP	Z,.REJECT
	LD	(TCP_OOO_TEMP_DELTA),DE
	; delta + payload + FIN must not exceed the last successfully advertised
	; right edge.  DLOOO3 has a fixed 4380-byte edge; DLTUNE derives the
	; current width from EDGE-RCV_NXT, including sequence wrap.
	EX	DE,HL
	LD	BC,(TCP_OOO_TEMP_LEN)
	ADD	HL,BC
	LD	A,(TCP_OOO_TEMP_FLAGS)
	AND	0x01
	JR	Z,.NO_FIN_LEN
	INC	HL
.NO_FIN_LEN
	LD	(TCP_OOO_TEMP_END),HL
	IFDEF USE_TCP_RX_TUNE
	LD	A,(TCP_TUNE_EDGE+3)
	LD	C,A
	LD	A,(TCP_RCV_NXT+3)
	LD	B,A
	LD	A,C
	SUB	B
	LD	E,A
	LD	A,(TCP_TUNE_EDGE+2)
	LD	C,A
	LD	A,(TCP_RCV_NXT+2)
	LD	B,A
	LD	A,C
	SBC	A,B
	LD	D,A
	ELSE
	LD	DE,OOO_WINDOW
	ENDIF
	OR	A
	SBC	HL,DE
	JR	C,.IN_WIN
	JR	Z,.IN_WIN
	JP	.BAD_WINDOW
.IN_WIN
	; Reject every actual interval intersection, but retain the old slot.
	LD	HL,TCP_OOO_SLOT0_META
	CALL	CHECK_SLOT
	JR	NC,.OVERLAP_REJECT
	LD	HL,TCP_OOO_SLOT1_META
	CALL	CHECK_SLOT
	JR	NC,.OVERLAP_REJECT
	; Find an empty slot.  CHECK_SLOT leaves CF=1 for empty/nonoverlap.
	LD	HL,TCP_OOO_SLOT0_META
	LD	A,(HL)
	OR	A
	JR	Z,.SLOT0
	LD	HL,TCP_OOO_SLOT1_META
	LD	A,(HL)
	OR	A
	JR	Z,.SLOT1
	LD	HL,TCP_OOO_NOSPACE
	CALL	INC_SAT16
	SCF
	RET
.SLOT0
	LD	DE,TCP_OOO_SLOT0_DATA
	JR	.SAVE
.SLOT1
	LD	DE,TCP_OOO_SLOT1_DATA
.SAVE
	PUSH	HL			; metadata pointer
	PUSH	DE			; destination payload pointer
	CALL	@ISA.ISA_CLOSE
	LD	HL,(TCP_OOO_TEMP_PTR)
	LD	BC,(TCP_OOO_TEMP_LEN)
	POP	DE
	LD	A,B
	OR	C
	CALL	NZ,.COPY
	CALL	@ISA.ISA_OPEN
	POP	HL
	LD	(HL),1
	INC	HL
	PUSH	HL
	LD	HL,@MAIN.RX_BUF + 14 + 20 + 4
	POP	DE
	LD	BC,4
	LDIR
	EX	DE,HL			; HL = metadata + 5 (LEN)
	LD	DE,(TCP_OOO_TEMP_LEN)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	INC	HL
	LD	A,(TCP_OOO_TEMP_FLAGS)
	AND	1
	LD	(HL),A
	LD	HL,TCP_OOO_SAVED
	CALL	INC_SAT16
	LD	HL,TCP_OOO_USED_NOW
	INC	(HL)
	LD	A,(HL)
	LD	HL,TCP_OOO_MAX_USED
	CP	(HL)
	JR	C,.DONE
	LD	(HL),A
.DONE
	OR	A
	RET
	RET
.OVERLAP_REJECT
	LD	HL,TCP_OOO_OVERLAP
	CALL	INC_SAT16
	SCF
	RET
.BAD_LENGTH
	LD	HL,TCP_OOO_BADLEN
	CALL	INC_SAT16
	SCF
	RET
.BAD_WINDOW
	LD	HL,TCP_OOO_OOWIN
	CALL	INC_SAT16
	SCF
	RET
.REJECT
	LD	HL,TCP_OOO_DUP
	CALL	INC_SAT16
	SCF
	RET
.COPY
	LDIR
	RET

; CHECK_SLOT: CF=0 iff an occupied slot intersects TEMP's range.  Both
; ranges are represented as unsigned offsets from the current RCV_NXT;
; this makes the test correct across the 32-bit sequence wrap.
CHECK_SLOT
	LD	A,(HL)
	OR	A
	SCF
	RET	Z
	; slot_delta = slot.SEQ - RCV_NXT.  Subtract from the least
	; significant byte towards the most significant so borrow propagation
	; remains valid for wrapped sequence numbers.
	PUSH	HL
	INC	HL
	INC	HL
	INC	HL
	INC	HL			; metadata + 4 = SEQ low byte
	LD	A,(HL)
	LD	C,A
	LD	A,(TCP_RCV_NXT+3)
	LD	B,A
	LD	A,C
	SUB	B
	LD	E,A
	DEC	HL
	LD	A,(HL)
	LD	C,A
	LD	A,(TCP_RCV_NXT+2)
	LD	B,A
	LD	A,C
	SBC	A,B
	LD	D,A
	DEC	HL
	LD	A,(HL)
	LD	C,A
	LD	A,(TCP_RCV_NXT+1)
	LD	B,A
	LD	A,C
	SBC	A,B
	JR	NZ,.NO_INTERSECT_POP
	DEC	HL
	LD	A,(HL)
	LD	C,A
	LD	A,(TCP_RCV_NXT+0)
	LD	B,A
	LD	A,C
	SBC	A,B
	JR	NZ,.NO_INTERSECT_POP
	LD	(TCP_OOO_SLOT_DELTA),DE
	POP	HL
	; slot_end = slot_delta + slot LEN + FIN
	LD	BC,5
	ADD	HL,BC
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	INC	HL
	LD	A,(HL)
	PUSH	AF
	LD	HL,(TCP_OOO_SLOT_DELTA)
	ADD	HL,DE
	POP	AF
	AND	1
	JR	Z,.SLOT_END_READY
	INC	HL
.SLOT_END_READY
	LD	(TCP_OOO_SLOT_END),HL
	; incoming_start < slot_end && slot_start < incoming_end
	LD	HL,(TCP_OOO_TEMP_DELTA)
	LD	DE,(TCP_OOO_SLOT_END)
	OR	A
	SBC	HL,DE
	JR	NC,.NO_INTERSECT
	LD	HL,(TCP_OOO_SLOT_DELTA)
	LD	DE,(TCP_OOO_TEMP_END)
	OR	A
	SBC	HL,DE
	JR	NC,.NO_INTERSECT
	OR	A
	RET
.NO_INTERSECT
	SCF
	RET
.NO_INTERSECT_POP
	POP	HL
	SCF
	RET

; PRUNE -- after ordinary in-order reception advances RCV_NXT, remove a
; queued range it completely covered or trim the accepted prefix of a
; partially covered slot.  A FIN is retained when its data prefix alone was
; covered, so it is consumed exactly once when it becomes contiguous.
PRUNE
	LD	HL,TCP_OOO_SLOT0_META
	LD	DE,TCP_OOO_SLOT0_DATA
	CALL	PRUNE_SLOT
	LD	HL,TCP_OOO_SLOT1_META
	LD	DE,TCP_OOO_SLOT1_DATA
	JP	PRUNE_SLOT

PRUNE_SLOT
	LD	A,(HL)
	OR	A
	RET	Z
	LD	(TCP_OOO_WORK_META),HL
	LD	(TCP_OOO_WORK_DATA),DE
	; delta = RCV_NXT - slot.SEQ, low byte first.  A non-zero high word
	; means the slot is still ahead (possibly across sequence wrap).
	INC	HL
	INC	HL
	INC	HL
	INC	HL
	LD	A,(HL)
	LD	C,A
	LD	A,(TCP_RCV_NXT+3)
	SUB	C
	LD	E,A
	DEC	HL
	LD	A,(HL)
	LD	C,A
	LD	A,(TCP_RCV_NXT+2)
	SBC	A,C
	LD	D,A
	DEC	HL
	LD	A,(HL)
	LD	C,A
	LD	A,(TCP_RCV_NXT+1)
	SBC	A,C
	RET	NZ
	DEC	HL
	LD	A,(HL)
	LD	C,A
	LD	A,(TCP_RCV_NXT+0)
	SBC	A,C
	RET	NZ
	LD	(TCP_OOO_TEMP_DELTA),DE
	LD	A,D
	OR	E
	RET	Z			; exactly ready; DELIVER owns it

	LD	HL,(TCP_OOO_WORK_META)
	LD	BC,5
	ADD	HL,BC
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	(TCP_OOO_TEMP_LEN),DE
	INC	HL
	LD	A,(HL)
	LD	(TCP_OOO_TEMP_FLAGS),A
	LD	H,D
	LD	L,E
	AND	1
	JR	Z,.SPAN_READY
	INC	HL
.SPAN_READY
	LD	DE,(TCP_OOO_TEMP_DELTA)
	OR	A
	SBC	HL,DE			; complete slot span - accepted prefix
	JR	C,.FREE
	JR	Z,.FREE

	; Retain the suffix.  Its sequence now starts at RCV_NXT.
	LD	HL,(TCP_OOO_TEMP_LEN)
	LD	DE,(TCP_OOO_TEMP_DELTA)
	OR	A
	SBC	HL,DE
	LD	(TCP_OOO_TEMP_LEN),HL
	LD	A,H
	OR	L
	JR	Z,.META			; data covered, queued FIN remains
	LD	B,H
	LD	C,L
	LD	HL,(TCP_OOO_WORK_DATA)
	ADD	HL,DE			; source = slot data + covered prefix
	LD	DE,(TCP_OOO_WORK_DATA)
	CALL	@ISA.ISA_CLOSE
	LDIR
	CALL	@ISA.ISA_OPEN
.META
	LD	HL,(TCP_OOO_WORK_META)
	INC	HL
	LD	D,H
	LD	E,L
	LD	HL,TCP_RCV_NXT
	CALL	@TCP.COPY_SEQ32
	LD	HL,(TCP_OOO_WORK_META)
	LD	DE,5
	ADD	HL,DE
	LD	DE,(TCP_OOO_TEMP_LEN)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	RET

.FREE
	LD	HL,(TCP_OOO_WORK_META)
	LD	(HL),0
	LD	HL,TCP_OOO_USED_NOW
	LD	A,(HL)
	OR	A
	RET	Z
	DEC	(HL)
	RET

; VALIDATE_FRAME -- validate the complete Ethernet/IPv4/TCP envelope before
; RECV reads flags, sequence numbers or ports.  BC is the actual body length
; returned by READ_PACKET.  IPv4 options remain intentionally unsupported;
; TCP options are accepted through Data Offset and are excluded from payload.
VALIDATE_FRAME
	LD	A,1
	LD	(TCP_OOO_RESULT),A
	LD	A,B
	OR	A
	JR	NZ,.SIZE_OK
	LD	A,C
	CP	54
	JP	C,.BAD
.SIZE_OK
	LD	A,2
	LD	(TCP_OOO_RESULT),A
	LD	A,(@MAIN.RX_BUF+12)
	CP	0x08
	JP	NZ,.BAD
	LD	A,(@MAIN.RX_BUF+13)
	CP	0x00
	JP	NZ,.BAD
	LD	A,(@MAIN.RX_BUF+14)
	AND	0xF0
	CP	0x40
	JP	NZ,.BAD
	LD	A,(@MAIN.RX_BUF+14)
	AND	0x0F
	CP	5
	JP	NZ,.BAD
	; No MF flag and no fragment offset.
	LD	A,(@MAIN.RX_BUF+20)
	AND	0x3F
	JP	NZ,.BAD
	LD	A,(@MAIN.RX_BUF+21)
	OR	A
	JP	NZ,.BAD
	LD	A,(@MAIN.RX_BUF+23)
	CP	6
	JP	NZ,.BAD
	; IP total length >= 40 and <= actual Ethernet payload.
	LD	A,3
	LD	(TCP_OOO_RESULT),A
	LD	A,(@MAIN.RX_BUF+16)
	LD	H,A
	LD	A,(@MAIN.RX_BUF+17)
	LD	L,A
	LD	DE,40
	OR	A
	SBC	HL,DE
	JP	C,.BAD
	PUSH	HL
	LD	H,B
	LD	L,C
	LD	DE,14
	OR	A
	SBC	HL,DE
	POP	DE
	OR	A
	SBC	HL,DE
	JP	C,.BAD
	LD	A,31
	LD	(TCP_OOO_RESULT),A
	; Re-read total and subtract the fixed IPv4 header.
	LD	A,(@MAIN.RX_BUF+16)
	LD	H,A
	LD	A,(@MAIN.RX_BUF+17)
	LD	L,A
	LD	DE,20
	OR	A
	SBC	HL,DE		; TCP segment bytes
	; TCP data offset is at least 20 and must fit that segment.
	LD	A,4
	LD	(TCP_OOO_RESULT),A
	LD	A,(@MAIN.RX_BUF+14+20+12)
	AND	0xF0
	RRCA
	RRCA
	LD	C,A
	LD	B,0
	LD	(TCP_OOO_RESULT),A
	LD	A,C
	CP	20
	JR	C,.BAD
	PUSH	HL
	OR	A
	SBC	HL,BC
	POP	DE
	JP	C,.BAD
	LD	A,21
	LD	(TCP_OOO_RESULT),A
	; payload = TCP segment - TCP header, maximum one MSS.
	EX	DE,HL
	LD	E,C
	LD	D,0
	OR	A
	SBC	HL,DE
	JP	C,.BAD
	LD	A,22
	LD	(TCP_OOO_RESULT),A
	LD	A,H
	CP	5
	JR	C,.PAYLOAD_OK
	JR	NZ,.BAD
	LD	A,L
	CP	0xB5
	JR	NC,.BAD
.PAYLOAD_OK
	; Incoming source/destination must be this connection.
	LD	A,5
	LD	(TCP_OOO_RESULT),A
	LD	HL,@MAIN.RX_BUF+14+12
	LD	DE,TCP_REMOTE_IP
	LD	B,4
	CALL	CMP_BYTES
	JR	C,.BAD
	LD	HL,@MAIN.RX_BUF+14+16
	LD	DE,TCP_REMOTE_IP
	LD	B,4
	; Destination is local IP in the direct client's MAIN map.
	LD	DE,@MAIN.OUR_IP
	CALL	CMP_BYTES
	JR	C,.BAD
	LD	HL,@MAIN.RX_BUF+14+20
	LD	DE,TCP_REMOTE_PORT_HI
	LD	B,2
	CALL	CMP_BYTES
	JR	C,.BAD
	LD	HL,@MAIN.RX_BUF+14+22
	LD	DE,TCP_LOCAL_PORT_HI
	LD	B,2
	CALL	CMP_BYTES
	JR	C,.BAD
	OR	A
	RET
.BAD
	SCF
	RET
CMP_BYTES
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	INC	DE
	INC	HL
	DJNZ	CMP_BYTES
	OR	A
	RET

; DELIVER -- publish exactly one queued segment whose SEQ == RCV_NXT.
; It is called before NIC polling.  CF=0 => HL/BC valid; CF=1 => none.
DELIVER
	XOR	A
	LD	(TCP_OOO_RESULT),A
	LD	HL,TCP_OOO_SLOT0_META
	CALL	FIND_READY
	JR	NC,.FOUND
	LD	HL,TCP_OOO_SLOT1_META
	CALL	FIND_READY
	RET	C
.FOUND
	LD	(TCP_OOO_WORK_META),HL
	LD	DE,TCP_OOO_SLOT0_DATA
	LD	A,H
	CP	HIGH TCP_OOO_SLOT1_META
	JR	NZ,.DATA
	LD	A,L
	CP	LOW TCP_OOO_SLOT1_META
	JR	NZ,.DATA
	LD	DE,TCP_OOO_SLOT1_DATA
.DATA
	PUSH	DE
	INC	HL
	INC	HL
	INC	HL
	INC	HL
	INC	HL			; LEN
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	(TCP_OOO_TEMP_LEN),DE
	POP	HL
	LD	BC,(TCP_OOO_TEMP_LEN)
	PUSH	BC
	CALL	@ISA.ISA_CLOSE
	LD	DE,@MAIN.RX_BUF
	LD	A,B
	OR	C
	CALL	NZ,.COPY2
	CALL	@ISA.ISA_OPEN
	POP	BC
	LD	HL,@MAIN.RX_BUF
	LD	(TCP_RX_DATA_PTR),HL
	LD	(TCP_RX_DATA_LEN),BC
	LD	DE,TCP_RCV_NXT
	CALL	@TCP.ADD32_BE_BC
	IFDEF USE_TCP_RX_TUNE
	CALL	@TCP.TUNE_ADVANCE
	ENDIF
	LD	HL,(TCP_OOO_WORK_META)
	INC	HL
	INC	HL
	INC	HL
	INC	HL
	INC	HL
	INC	HL
	INC	HL			; FIN
	LD	A,(HL)
	PUSH	AF
	LD	HL,(TCP_OOO_WORK_META)
	XOR	A
	LD	(HL),A
	LD	HL,TCP_OOO_USED_NOW
	DEC	(HL)
	LD	HL,TCP_OOO_DELIVERED
	CALL	INC_SAT16
	POP	AF
	OR	A
	JR	Z,.ACK
	LD	DE,TCP_RCV_NXT
	CALL	@TCP.INC_SEQ32
	LD	A,@TCP.ST_CLOSE_WAIT
	LD	(TCP_STATE),A
	CALL	RELEASE			; nothing after FIN may be delivered
.ACK
	CALL	@TCP.BUILD_ACK
	CALL	@TCP.XMIT_TX_BUF
	JR	NC,.ACK_OK
	IFDEF USE_TCP_RX_TUNE
	CALL	@TCP.TUNE_ROLLBACK
	ENDIF
	LD	A,2
	LD	(TCP_OOO_RESULT),A
	LD	HL,TCP_OOO_ACKFAIL
	CALL	INC_SAT16
	SCF
	RET
.ACK_OK
	LD	HL,(TCP_RX_DATA_PTR)
	LD	BC,(TCP_RX_DATA_LEN)
	OR	A
	RET
.COPY2
	LDIR
	RET

; FIND_READY: HL metadata in, CF=0 if its SEQ is TCP_RCV_NXT.
FIND_READY
	LD	A,(HL)
	OR	A
	SCF
	RET	Z
	INC	HL
	LD	DE,TCP_RCV_NXT
	LD	B,4
.CMP
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.NO
	INC	DE
	INC	HL
	DJNZ	.CMP
	; Initial INC to SEQ plus four compare increments = metadata + 5.
	; Return USED's address, used by DELIVER for both slot selection and free.
	DEC	HL
	DEC	HL
	DEC	HL
	DEC	HL
	DEC	HL
	OR	A
	RET
.NO
	SCF
	RET

INC_SAT
	LD	A,(HL)
	CP	0xFF
	RET	Z
	INC	(HL)
	RET

INC_SAT16
	LD	A,(HL)
	CP	0xFF
	JR	NZ,.LOW
	INC	HL
	LD	A,(HL)
	CP	0xFF
	RET	Z
	INC	(HL)
	DEC	HL
	LD	(HL),0
	RET
.LOW
	INC	(HL)
	RET

	ENDMODULE
	ENDIF
