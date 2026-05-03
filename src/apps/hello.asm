; ======================================================
; HELLO.EXE - stage 0 sanity check for the Sprinter RTL8019AS
; network kit. Verifies that the build pipeline produces a
; runnable DSS executable; does not touch the NIC.
;
; Expected output on Sprinter DSS:
;   RTL8019AS DEV HELLO v0.1
;   RESULT OK
; Exit code: 0 (success).
; ======================================================

EXE_VERSION		EQU 1

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"

	MODULE MAIN

	ORG 0x8080

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0080		; flags / size hint, see sprinter_wifi/network header layout
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START		; entry point
	DW START
	DW STACK_TOP
	DS 106, 0

	ORG 0x8100
@STACK_TOP

START
	PRINTLN MSG_BANNER
	PRINTLN MSG_RESULT_OK
	DSS_RETURN 0

MSG_BANNER	DB "RTL8019AS DEV HELLO v0.1",0
MSG_RESULT_OK	DB "RESULT OK",0
LINE_END	DB 13,10,0

	ENDMODULE
