; ======================================================
; Ymodem send/receive for the TELNET raw TCP stream.
; CRC-16 mode, 128-byte metadata blocks and 1 KB data blocks.
; Started explicitly by Alt+D (download) / Alt+U (upload), because a Ymodem
; sender waits silently for the receiver's initial 'C'.
;
; Shares the allocated WIN2 buffers and file/UI helpers with module ZM.
; Adapted from sprinter_wifi/network. License: BSD 3-Clause.
; ======================================================

	IFNDEF	_YMODEM
	DEFINE	_YMODEM

YM_SOH		EQU 0x01
YM_STX		EQU 0x02
YM_EOT		EQU 0x04
YM_ACK		EQU 0x06
YM_NAK		EQU 0x15
YM_CAN		EQU 0x18
YM_CRC_REQ	EQU 'C'
YM_G_REQ	EQU 'G'
YM_PAD		EQU 0x1A
YM_META_SIZE	EQU 128
YM_DATA_SIZE	EQU 1024
YM_RETRIES	EQU 10

YM_ERR_NONE	EQU 0
YM_ERR_TIMEOUT	EQU 1
YM_ERR_CANCEL	EQU 2
YM_ERR_NAK	EQU 3
YM_ERR_TX	EQU 4
YM_ERR_FILE	EQU 5
YM_ERR_SIZE	EQU 6

YM_EV_PACKET	EQU 0
YM_EV_EOT	EQU 1
YM_EV_CAN	EQU 2

	MODULE YM

; ------------------------------------------------------
; Public entry points
; ------------------------------------------------------
RECEIVE
	XOR	A
	LD	(G_MODE),A
	JR	RECEIVE_START
RECEIVE_G
	LD	A,1
	LD	(G_MODE),A
RECEIVE_START
	CALL	SESSION_INIT
	XOR	A
	LD	(MAIN.YM_C_PENDING),A
	LD	A,(G_MODE)
	OR	A
	LD	HL,MSG_DOWNLOAD
	JR	Z,.show_mode
	LD	HL,MSG_DOWNLOAD_G
.show_mode
	CALL	ZM.ZPRINTLN
.next_file
	CALL	SEND_RX_REQUEST
	LD	B,YM_RETRIES
.wait_header
	PUSH	BC
	CALL	RECV_PACKET
	POP	BC
	JR	NC,.header_event
	LD	A,(G_MODE)
	OR	A
	JP	NZ,SESSION_ABORT
	CALL	SEND_RX_REQUEST
	DJNZ	.wait_header
	JP	SESSION_ABORT
.header_event
	OR	A
	JP	NZ,SESSION_ABORT
	LD	A,(RX_BLOCK)
	OR	A
	JR	Z,.header_ok
	LD	A,(G_MODE)
	OR	A
	JP	NZ,SESSION_ABORT
	LD	A,YM_NAK
	CALL	SEND_BYTE
	DJNZ	.wait_header
	JP	SESSION_ABORT
.header_ok
	LD	A,(ZM.DATA_BUF)
	OR	A
	JP	Z,.batch_done
	CALL	PARSE_FILE_SIZE
	CALL	ZM.OPEN_OUTPUT
	JP	C,SESSION_ABORT
	CALL	RESET_FILE_POS
	LD	A,YM_ACK
	LD	C,A
	LD	A,(G_MODE)
	OR	A
	JR	NZ,.header_g
	LD	A,C
	CALL	SEND_BYTE
.header_g
	CALL	SEND_RX_REQUEST
	LD	A,1
	LD	(EXPECT_BLOCK),A
.data_wait
	LD	B,YM_RETRIES
.data_retry
	PUSH	BC
	CALL	RECV_PACKET
	POP	BC
	JR	NC,.data_event
	LD	A,(G_MODE)
	OR	A
	JP	NZ,SESSION_ABORT
	LD	A,YM_NAK
	CALL	SEND_BYTE
	DJNZ	.data_retry
	JP	SESSION_ABORT
.data_event
	CP	YM_EV_EOT
	JR	Z,.first_eot
	CP	YM_EV_CAN
	JP	Z,SESSION_ABORT
	LD	A,(EXPECT_BLOCK)
	LD	C,A
	LD	A,(RX_BLOCK)
	CP	C
	JR	Z,.new_block
	LD	A,(G_MODE)
	OR	A
	JP	NZ,SESSION_ABORT
	LD	A,(RX_BLOCK)
	DEC	C
	CP	C
	JR	Z,.duplicate
	LD	A,YM_NAK
	CALL	SEND_BYTE
	DJNZ	.data_retry
	JP	SESSION_ABORT
.duplicate
	LD	A,YM_ACK
	CALL	SEND_BYTE
	JR	.data_wait
.new_block
	CALL	WRITE_BLOCK
	JP	C,SESSION_ABORT
	CALL	ZM.SHOW_PROGRESS
	LD	A,(G_MODE)
	OR	A
	JR	NZ,.block_done
	LD	A,YM_ACK
	CALL	SEND_BYTE
.block_done
	LD	A,(EXPECT_BLOCK)
	INC	A
	LD	(EXPECT_BLOCK),A
	JR	.data_wait
.first_eot
.file_done
	CALL	FLUSH_UNKNOWN_LAST_BLOCK
	JP	C,SESSION_ABORT
	CALL	CHECK_FILE_COMPLETE
	JP	C,SESSION_ABORT
	CALL	CLOSE_RECEIVED_FILE
	JR	NC,.file_closed
	LD	A,YM_ERR_FILE
	LD	(ABORT_REASON),A
	JP	SESSION_ABORT
.file_closed
	LD	A,YM_ACK
	CALL	SEND_BYTE
	LD	HL,ZM.MSG_FILE_OK
	CALL	ZM.ZPRINTLN
	XOR	A
	LD	(ZM.PROGRESS_SHOWN),A
	JP	.next_file
.batch_done
	LD	A,(G_MODE)
	OR	A
	JP	NZ,SESSION_DONE		; Ymodem-G sender never waits ACK for a sector
	LD	A,YM_ACK
	CALL	SEND_BYTE
	JP	SESSION_DONE

SEND
	CALL	SESSION_INIT
	LD	HL,MSG_UPLOAD
	CALL	ZM.ZPRINTLN
	CALL	ZM.PROMPT_FILENAME
	JP	C,SESSION_CANCEL
	CALL	ZM.OPEN_INPUT
	JR	NC,.input_open
	LD	A,YM_ERR_FILE
	LD	(ABORT_REASON),A
	JP	SESSION_ABORT
.input_open
	CALL	WAIT_C
	JP	C,SESSION_ABORT
	; Block 0: basename NUL, decimal size and standard metadata fields.
	LD	HL,ZM.DATA_BUF
	LD	DE,ZM.DATA_BUF+1
	LD	BC,YM_META_SIZE-1
	LD	(HL),0
	LDIR
	CALL	ZM.BUILD_FILE_INFO
	XOR	A
	LD	(TX_BLOCK),A
	LD	A,YM_RETRIES
	LD	(RETRY_COUNT),A
.send_meta
	LD	A,YM_SOH
	LD	DE,YM_META_SIZE
	CALL	SEND_CURRENT_PACKET
	JR	NC,.meta_sent
	LD	A,YM_ERR_TX
	LD	(ABORT_REASON),A
	JP	SESSION_ABORT
.meta_sent
	CALL	WAIT_ACK_OR_NAK
	JR	C,.meta_retry
	CP	YM_ACK
	JR	Z,.meta_acked
.meta_retry
	LD	A,(RETRY_COUNT)
	DEC	A
	LD	(RETRY_COUNT),A
	JR	NZ,.send_meta
	JP	SESSION_ABORT
.meta_acked
	CALL	WAIT_C
	JP	C,SESSION_ABORT
	LD	A,1
	LD	(TX_BLOCK),A
.read
	CALL	ZM.READ_INPUT
	JR	NC,.read_ok
	LD	A,YM_ERR_FILE
	LD	(ABORT_REASON),A
	JP	SESSION_ABORT
.read_ok
	LD	A,D
	OR	E
	JR	Z,.eot
	LD	(TX_COUNT),DE
	CALL	PAD_DATA_BLOCK
	LD	A,YM_RETRIES
	LD	(RETRY_COUNT),A
.send_data
	LD	A,YM_STX
	LD	DE,YM_DATA_SIZE
	CALL	SEND_CURRENT_PACKET
	JR	NC,.data_sent
	LD	A,YM_ERR_TX
	LD	(ABORT_REASON),A
	JP	SESSION_ABORT
.data_sent
	CALL	WAIT_ACK_OR_NAK
	JR	C,.data_retry_send
	CP	YM_ACK
	JR	Z,.data_acked
	LD	A,YM_ERR_NAK
	LD	(ABORT_REASON),A
.data_retry_send
	LD	A,(RETRY_COUNT)
	DEC	A
	LD	(RETRY_COUNT),A
	JR	NZ,.send_data
	JP	SESSION_ABORT
.data_acked
	LD	DE,(TX_COUNT)
	CALL	ZM.ADD_FPOS
	CALL	ZM.SHOW_PROGRESS
	LD	A,(TX_BLOCK)
	INC	A
	LD	(TX_BLOCK),A
	JR	.read
.eot
	LD	A,YM_EOT
	CALL	SEND_BYTE
	CALL	WAIT_ACK_OR_NAK
	JP	C,SESSION_ABORT
	CP	YM_ACK
	JR	Z,.wait_final_c
	LD	A,YM_EOT
	CALL	SEND_BYTE
	CALL	WAIT_ACK
	JP	C,SESSION_ABORT
.wait_final_c
	CALL	WAIT_C
	JP	C,SESSION_ABORT
	; Empty block 0 terminates a Ymodem batch.
	LD	HL,ZM.DATA_BUF
	LD	DE,ZM.DATA_BUF+1
	LD	BC,YM_META_SIZE-1
	LD	(HL),0
	LDIR
	XOR	A
	LD	(TX_BLOCK),A
	LD	A,YM_RETRIES
	LD	(RETRY_COUNT),A
.send_final_meta
	LD	A,YM_SOH
	LD	DE,YM_META_SIZE
	CALL	SEND_CURRENT_PACKET
	JR	NC,.final_meta_sent
	LD	A,YM_ERR_TX
	LD	(ABORT_REASON),A
	JP	SESSION_ABORT
.final_meta_sent
	CALL	WAIT_ACK_OR_NAK
	JR	C,.final_retry
	CP	YM_ACK
	JR	Z,.final_acked
.final_retry
	LD	A,(RETRY_COUNT)
	DEC	A
	LD	(RETRY_COUNT),A
	JR	NZ,.send_final_meta
	JP	SESSION_ABORT
.final_acked
	JP	SESSION_DONE

; ------------------------------------------------------
; Session/UI
; ------------------------------------------------------
SESSION_INIT
	XOR	A
	LD	(ABORT_REASON),A
	LD	(ZM.ABORTED),A
	LD	(ZM.FH_OPEN),A
	LD	(ZM.PROGRESS_SHOWN),A
	LD	(ZM.SRC_PTR),A
	LD	(ZM.SRC_PTR+1),A
	LD	(ZM.SRC_CNT),A
	LD	(ZM.SRC_CNT+1),A
	LD	(PENDING_UNKNOWN),A
	CALL	RESET_FILE_POS
	CALL	ZM.SET_SAFE_RX_TRIGGER
	CALL	ZM.ZNEWLINE
	LD	HL,MSG_DETECT
	JP	ZM.ZPRINTLN

RESET_FILE_POS
	LD	HL,0
	LD	(ZM.FPOS),HL
	LD	(ZM.FPOS+2),HL
	RET

SESSION_DONE
	XOR	A
	LD	(MAIN.YM_C_PENDING),A
	CALL	ZM.CLOSE_OUTPUT
	CALL	WIFI.UART_RX_PAUSE
	CALL	ZM.RESTORE_RX_TRIGGER
	CALL	ZM.END_PROGRESS_LINE
	LD	HL,MSG_DONE
	CALL	ZM.ZPRINTLN
	OR	A
	RET

SESSION_CANCEL
	XOR	A
	LD	(MAIN.YM_C_PENDING),A
	CALL	SEND_CANCEL
	CALL	ZM.CLOSE_OUTPUT
	CALL	WIFI.UART_RX_PAUSE
	CALL	ZM.RESTORE_RX_TRIGGER
	CALL	ZM.END_PROGRESS_LINE
	OR	A
	RET

SESSION_ABORT
	XOR	A
	LD	(MAIN.YM_C_PENDING),A
	CALL	ZM.ABORT_TRANSFER	; cancel and drain queued file bytes before terminal mode
	CALL	WIFI.UART_RX_PAUSE
	CALL	ZM.RESTORE_RX_TRIGGER
	CALL	ZM.END_PROGRESS_LINE
	LD	A,(ABORT_REASON)
	CP	YM_ERR_TIMEOUT
	LD	HL,MSG_ABORT_TIMEOUT
	JR	Z,.print_abort
	CP	YM_ERR_CANCEL
	LD	HL,MSG_ABORT_CANCEL
	JR	Z,.print_abort
	CP	YM_ERR_NAK
	LD	HL,MSG_ABORT_NAK
	JR	Z,.print_abort
	CP	YM_ERR_TX
	LD	HL,MSG_ABORT_TX
	JR	Z,.print_abort
	CP	YM_ERR_FILE
	LD	HL,MSG_ABORT_FILE
	JR	Z,.print_abort
	CP	YM_ERR_SIZE
	LD	HL,MSG_ABORT_SIZE
	JR	Z,.print_abort
	LD	HL,MSG_ABORT
.print_abort
	CALL	ZM.ZPRINTLN
	SCF
	RET

SEND_CANCEL
	LD	B,8
.loop
	LD	A,YM_CAN
	CALL	SEND_BYTE
	DJNZ	.loop
	RET

SEND_RX_REQUEST
	LD	A,(G_MODE)
	OR	A
	LD	A,YM_CRC_REQ
	JR	Z,.send
	LD	A,YM_G_REQ
.send
	JP	SEND_BYTE

; ------------------------------------------------------
; Receive packets
; ------------------------------------------------------
; Out: A=YM_EV_*, CF=0. CF=1 on timeout, malformed packet or bad CRC.
RECV_PACKET
.scan
	CALL	ZM.GETBYTE
	RET	C
	CP	YM_SOH
	JR	Z,.soh
	CP	YM_STX
	JR	Z,.stx
	CP	YM_EOT
	JR	Z,.eot
	CP	YM_CAN
	JR	Z,.can
	JR	.scan
.soh
	LD	HL,YM_META_SIZE
	LD	(RX_LENGTH),HL
	JR	.header
.stx
	LD	HL,YM_DATA_SIZE
	LD	(RX_LENGTH),HL
.header
	CALL	ZM.GETBYTE
	RET	C
	LD	(RX_BLOCK),A
	LD	C,A
	CALL	ZM.GETBYTE
	RET	C
	CPL
	CP	C
	JR	NZ,.bad
	LD	HL,ZM.DATA_BUF
	LD	(RX_PTR),HL
	LD	HL,(RX_LENGTH)
	LD	(RX_LEFT),HL
	LD	HL,0
	LD	(RX_CRC),HL
.data
	CALL	ZM.GETBYTE
	RET	C
	LD	C,A
	LD	HL,(RX_PTR)
	LD	(HL),A
	INC	HL
	LD	(RX_PTR),HL
	LD	A,C
	LD	HL,(RX_CRC)
	CALL	ZM.CRC_UPD
	LD	(RX_CRC),HL
	LD	HL,(RX_LEFT)
	DEC	HL
	LD	(RX_LEFT),HL
	LD	A,H
	OR	L
	JR	NZ,.data
	CALL	ZM.GETBYTE
	RET	C
	LD	HL,RX_CRC+1
	CP	(HL)
	JR	NZ,.bad
	CALL	ZM.GETBYTE
	RET	C
	LD	HL,RX_CRC
	CP	(HL)
	JR	NZ,.bad
	LD	A,YM_EV_PACKET
	OR	A
	RET
.eot
	LD	A,YM_EV_EOT
	OR	A
	RET
.can
	LD	A,YM_EV_CAN
	OR	A
	RET
.bad
	SCF
	RET

; ------------------------------------------------------
; Download metadata and disk output
; ------------------------------------------------------
PARSE_FILE_SIZE
	XOR	A
	LD	(SIZE_KNOWN),A
	LD	HL,0
	LD	(FILE_LEFT),HL
	LD	(FILE_LEFT+2),HL
	LD	HL,ZM.DATA_BUF
.name
	LD	A,(HL)
	INC	HL
	OR	A
	JR	NZ,.name
	LD	A,(HL)
	CP	'0'
	RET	C
	CP	'9'+1
	RET	NC
	LD	A,1
	LD	(SIZE_KNOWN),A
.digit
	LD	A,(HL)
	CP	'0'
	JR	C,.done
	CP	'9'+1
	JR	NC,.done
	SUB	'0'
	PUSH	HL
	CALL	SIZE_MUL10_ADD
	POP	HL
	INC	HL
	JR	.digit
.done
	RET

; FILE_LEFT = FILE_LEFT * 10 + A.
SIZE_MUL10_ADD
	LD	(SIZE_DIGIT),A
	LD	HL,FILE_LEFT
	LD	DE,SIZE_OLD
	LD	BC,4
	LDIR
	LD	HL,0
	LD	(FILE_LEFT),HL
	LD	(FILE_LEFT+2),HL
	LD	B,10
.add_old
	LD	HL,(FILE_LEFT)
	LD	DE,(SIZE_OLD)
	ADD	HL,DE
	LD	(FILE_LEFT),HL
	LD	HL,(FILE_LEFT+2)
	LD	DE,(SIZE_OLD+2)
	ADC	HL,DE
	LD	(FILE_LEFT+2),HL
	DJNZ	.add_old
	LD	A,(SIZE_DIGIT)
	LD	E,A
	LD	D,0
	LD	HL,(FILE_LEFT)
	ADD	HL,DE
	LD	(FILE_LEFT),HL
	RET	NC
	LD	HL,(FILE_LEFT+2)
	INC	HL
	LD	(FILE_LEFT+2),HL
	RET

WRITE_BLOCK
	LD	DE,(RX_LENGTH)
	LD	A,(SIZE_KNOWN)
	OR	A
	JP	Z,QUEUE_UNKNOWN_BLOCK
	LD	HL,(FILE_LEFT+2)
	LD	A,H
	OR	L
	JR	NZ,.count_ready
	LD	HL,(FILE_LEFT)
	OR	A
	SBC	HL,DE
	JR	NC,.count_ready
	LD	DE,(FILE_LEFT)
.count_ready
	LD	(WRITE_COUNT),DE
	LD	A,D
	OR	E
	JR	Z,.written
	CALL	WIFI.UART_RX_PAUSE
	LD	A,(ZM.FH)
	LD	HL,ZM.DATA_BUF
	LD	C,DSS_WRITE
	RST	DSS
	JR	NC,.write_ok
	LD	A,YM_ERR_FILE
	LD	(ABORT_REASON),A
	SCF
	RET
.write_ok
	; Real DSS variants do not consistently preserve/report the written count
	; in DE on success. The requested count is authoritative when CF is clear;
	; exact final length is verified against Ymodem metadata at EOT.
	LD	DE,(WRITE_COUNT)
	CALL	ZM.ADD_FPOS
	LD	A,(SIZE_KNOWN)
	OR	A
	JR	Z,.written
	CALL	SUB_FILE_LEFT
.written
	OR	A
	RET

; If block 0 omitted the exact byte size, retain one block instead of writing
; it immediately. Once another block arrives the retained one is known not to
; be final and can be written in full. At EOT the final block is trimmed using
; the Ymodem CPMEOF (0x1A) padding convention.
QUEUE_UNKNOWN_BLOCK
	LD	(CURRENT_UNKNOWN_LEN),DE
	LD	A,(PENDING_UNKNOWN)
	OR	A
	JR	Z,.store_current
	LD	DE,(PENDING_UNKNOWN_LEN)
	LD	HL,ZM.TXDATA_BUF
	CALL	WRITE_TRACKED
	RET	C
.store_current
	LD	HL,ZM.DATA_BUF
	LD	DE,ZM.TXDATA_BUF
	LD	BC,(CURRENT_UNKNOWN_LEN)
	LDIR
	LD	HL,(CURRENT_UNKNOWN_LEN)
	LD	(PENDING_UNKNOWN_LEN),HL
	LD	A,1
	LD	(PENDING_UNKNOWN),A
	OR	A
	RET

FLUSH_UNKNOWN_LAST_BLOCK
	LD	A,(PENDING_UNKNOWN)
	OR	A
	RET	Z
	LD	DE,(PENDING_UNKNOWN_LEN)
	LD	HL,ZM.TXDATA_BUF
	LD	A,D
	OR	E
	JR	Z,.clear
	ADD	HL,DE
.trim
	DEC	HL
	LD	A,(HL)
	CP	YM_PAD
	JR	NZ,.write
	DEC	DE
	LD	A,D
	OR	E
	JR	NZ,.trim
	JR	.clear
.write
	LD	HL,ZM.TXDATA_BUF
	CALL	WRITE_TRACKED
	RET	C
	CALL	ZM.SHOW_PROGRESS
.clear
	XOR	A
	LD	(PENDING_UNKNOWN),A
	OR	A
	RET

; Write DE bytes from HL and account them in the displayed file position.
WRITE_TRACKED
	LD	(WRITE_COUNT),DE
	LD	A,D
	OR	E
	RET	Z
	CALL	WIFI.UART_RX_PAUSE
	LD	A,(ZM.FH)
	LD	C,DSS_WRITE
	RST	DSS
	JR	NC,.ok
	LD	A,YM_ERR_FILE
	LD	(ABORT_REASON),A
	SCF
	RET
.ok
	LD	DE,(WRITE_COUNT)
	CALL	ZM.ADD_FPOS
	OR	A
	RET

; A known metadata size must reach exactly zero before EOT. Without this check
; a truncated archive was reported as OK and only failed at its final member.
CHECK_FILE_COMPLETE
	LD	A,(SIZE_KNOWN)
	OR	A
	RET	Z
	LD	HL,(FILE_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.incomplete
	LD	HL,(FILE_LEFT+2)
	LD	A,H
	OR	L
	RET	Z
.incomplete
	LD	A,YM_ERR_SIZE
	LD	(ABORT_REASON),A
	SCF
	RET

; Preserve DSS_CLOSE_FILE status: ZM.CLOSE_OUTPUT intentionally ignores it for
; cleanup paths, but a successful Ymodem receive must not hide a flush error.
CLOSE_RECEIVED_FILE
	LD	A,(ZM.FH_OPEN)
	OR	A
	RET	Z
	LD	A,(ZM.FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	PUSH	AF
	XOR	A
	LD	(ZM.FH_OPEN),A
	POP	AF
	RET

SUB_FILE_LEFT
	LD	HL,(FILE_LEFT)
	OR	A
	SBC	HL,DE
	LD	(FILE_LEFT),HL
	RET	NC
	LD	HL,(FILE_LEFT+2)
	DEC	HL
	LD	(FILE_LEFT+2),HL
	RET

; ------------------------------------------------------
; Upload packet construction
; ------------------------------------------------------
PAD_DATA_BLOCK
	LD	HL,ZM.DATA_BUF
	ADD	HL,DE
	LD	BC,YM_DATA_SIZE
	LD	A,C
	SUB	E
	LD	C,A
	LD	A,B
	SBC	A,D
	LD	B,A
	LD	A,B
	OR	C
	RET	Z
	LD	A,YM_PAD
	LD	(HL),A
	LD	D,H
	LD	E,L
	INC	DE
	DEC	BC
	LDIR
	RET

; A=start byte, DE=payload size, TX_BLOCK selects block number.
SEND_CURRENT_PACKET
	LD	(PACKET_START),A
	LD	(PACKET_LEFT),DE
	LD	HL,ZM.DATA_BUF
	LD	(PACKET_PTR),HL
	LD	HL,ZM.TXDATA_BUF
	LD	(NET_PTR),HL
	LD	HL,0
	LD	(TX_CRC),HL
	LD	A,(PACKET_START)
	CALL	NET_PUT
	LD	A,(TX_BLOCK)
	CALL	NET_PUT
	LD	A,(TX_BLOCK)
	CPL
	CALL	NET_PUT
.payload
	LD	HL,(PACKET_LEFT)
	LD	A,H
	OR	L
	JR	Z,.crc
	DEC	HL
	LD	(PACKET_LEFT),HL
	LD	HL,(PACKET_PTR)
	LD	A,(HL)
	INC	HL
	LD	(PACKET_PTR),HL
	PUSH	AF
	LD	HL,(TX_CRC)
	CALL	ZM.CRC_UPD
	LD	(TX_CRC),HL
	POP	AF
	CALL	NET_PUT
	JR	.payload
.crc
	LD	HL,(TX_CRC)
	LD	A,H
	CALL	NET_PUT
	LD	HL,(TX_CRC)
	LD	A,L
	CALL	NET_PUT
	LD	HL,(NET_PTR)
	LD	DE,ZM.TXDATA_BUF
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	LD	HL,ZM.TXDATA_BUF
	JP	WIFI.UART_TX_BUFFER

; Append A, doubling Telnet IAC only when the peer is a real Telnet server.
NET_PUT
	PUSH	AF,HL
	LD	HL,(NET_PTR)
	LD	(HL),A
	INC	HL
	LD	(NET_PTR),HL
	CP	0xFF
	JR	NZ,.done
	LD	A,(MAIN.TN_PEER_SEEN)
	OR	A
	JR	Z,.done
	LD	(HL),0xFF
	INC	HL
	LD	(NET_PTR),HL
.done
	POP	HL,AF
	RET

; ------------------------------------------------------
; Control byte helpers
; ------------------------------------------------------
SEND_BYTE
	PUSH	BC
	LD	(CONTROL_BYTE),A
	LD	HL,CONTROL_BYTE
	LD	BC,1
	CALL	WIFI.UART_TX_BUFFER
	POP	BC
	RET

WAIT_C
	LD	A,(MAIN.YM_C_PENDING)
	OR	A
	JR	Z,.wait
	XOR	A
	LD	(MAIN.YM_C_PENDING),A
	RET
.wait
	LD	C,YM_CRC_REQ
	JR	WAIT_CONTROL
WAIT_ACK
	LD	C,YM_ACK
WAIT_CONTROL
	LD	B,YM_RETRIES
.retry
	PUSH	BC
.scan
	CALL	ZM.GETBYTE
	JR	C,.timeout
	CP	YM_CAN
	JR	Z,.cancel
	CP	C
	JR	Z,.match
	JR	.scan
.timeout
	POP	BC
	DJNZ	.retry
	LD	A,YM_ERR_TIMEOUT
	LD	(ABORT_REASON),A
	SCF
	RET
.cancel
	POP	BC
	LD	A,YM_ERR_CANCEL
	LD	(ABORT_REASON),A
	SCF
	RET
.match
	POP	BC
	OR	A
	RET

WAIT_ACK_OR_NAK
	LD	B,1			; packet caller owns retransmit count; one 10 s wait
.retry
	PUSH	BC
.scan
	CALL	ZM.GETBYTE
	JR	C,.timeout
	CP	YM_ACK
	JR	Z,.match
	CP	YM_NAK
	JR	Z,.match
	CP	YM_CAN
	JR	Z,.cancel
	JR	.scan
.timeout
	POP	BC
	DJNZ	.retry
	LD	A,YM_ERR_TIMEOUT
	LD	(ABORT_REASON),A
	SCF
	RET
.cancel
	POP	BC
	LD	A,YM_ERR_CANCEL
	LD	(ABORT_REASON),A
	SCF
	RET
.match
	POP	BC
	OR	A
	RET

; ------------------------------------------------------
; Messages and state
; ------------------------------------------------------
MSG_DETECT	DB "Ymodem started (Esc aborts)...",0
MSG_DOWNLOAD	DB "Ymodem download.",0
MSG_DOWNLOAD_G	DB "Ymodem-G download.",0
MSG_UPLOAD	DB "Ymodem upload.",0
MSG_DONE	DB "Ymodem done.",0
MSG_ABORT	DB "Ymodem aborted.",0
MSG_ABORT_TIMEOUT DB "Ymodem aborted: receiver timeout.",0
MSG_ABORT_CANCEL DB "Ymodem aborted: receiver cancelled.",0
MSG_ABORT_NAK	DB "Ymodem aborted: receiver rejected the block.",0
MSG_ABORT_TX	DB "Ymodem aborted: UART send timeout.",0
MSG_ABORT_FILE	DB "Ymodem aborted: file read/write error.",0
MSG_ABORT_SIZE	DB "Ymodem aborted: file ended before advertised size.",0

RX_BLOCK	EQU @MAIN.YM_STATE_BASE + 0
EXPECT_BLOCK	EQU @MAIN.YM_STATE_BASE + 1
TX_BLOCK	EQU @MAIN.YM_STATE_BASE + 2
RETRY_COUNT	EQU @MAIN.YM_STATE_BASE + 3
G_MODE	EQU @MAIN.YM_STATE_BASE + 4
ABORT_REASON	EQU @MAIN.YM_STATE_BASE + 5
SIZE_KNOWN	EQU @MAIN.YM_STATE_BASE + 6
SIZE_DIGIT	EQU @MAIN.YM_STATE_BASE + 7
CONTROL_BYTE	EQU @MAIN.YM_STATE_BASE + 8
RX_PTR	EQU @MAIN.YM_STATE_BASE + 9
RX_LEFT	EQU @MAIN.YM_STATE_BASE + 11
RX_LENGTH	EQU @MAIN.YM_STATE_BASE + 13
RX_CRC	EQU @MAIN.YM_STATE_BASE + 15
FILE_LEFT	EQU @MAIN.YM_STATE_BASE + 17
SIZE_OLD	EQU @MAIN.YM_STATE_BASE + 21
WRITE_COUNT	EQU @MAIN.YM_STATE_BASE + 25
PENDING_UNKNOWN	EQU @MAIN.YM_STATE_BASE + 27
PENDING_UNKNOWN_LEN	EQU @MAIN.YM_STATE_BASE + 28
CURRENT_UNKNOWN_LEN	EQU @MAIN.YM_STATE_BASE + 30
TX_COUNT	EQU @MAIN.YM_STATE_BASE + 32
PACKET_START	EQU @MAIN.YM_STATE_BASE + 34
PACKET_PTR	EQU @MAIN.YM_STATE_BASE + 35
PACKET_LEFT	EQU @MAIN.YM_STATE_BASE + 37
TX_CRC	EQU @MAIN.YM_STATE_BASE + 39
NET_PTR	EQU @MAIN.YM_STATE_BASE + 41

	ENDMODULE

	ENDIF
