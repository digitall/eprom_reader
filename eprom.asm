;	EPROM and Flash Reader
; 	Copyright 2008 Kevin Timmerman
;	http://www.compendiumarcana.com/eprom
;
;    This program is free software; you can redistribute it and/or modify
;    it under the terms of the GNU General Public License as published by
;    the Free Software Foundation; either version 3 of the License, or
;    (at your option) any later version.
;
;    This program is distributed in the hope that it will be useful,
;    but WITHOUT ANY WARRANTY; without even the implied warranty of
;    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;    GNU General Public License for more details.
;
;    You should have received a copy of the GNU General Public License
;    along with this program.  If not, see <http://www.gnu.org/licenses/>.
;
; r  Read EPROM
; b  Binary
; h  Hex
; o  Configuration
; `   1K 82S181, RY1133 (512B TBP28S42N)
; !   2K 82S191, TPB28L166, MB7138
; 1   2K 27C16
; 2   4K 27C32
; 3   8K 27C64
; 4  16K 27C128
; 5  32K 27C256
; 6  64K 27C512
; 7 128K 27C010
; 8 256K 27C020
; 9 512K 27C040
; 0   1M 27C080

#ifdef __18F4550
#include <p18f4550.inc>
#endif

; --- Configuration Fuses
	__config	_CONFIG1L, _PLLDIV_1_1L & _CPUDIV_OSC1_PLL2_1L & _USBDIV_2_1L
	__config	_CONFIG1H, _FOSC_INTOSC_EC_1H & _FCMEM_ON_1H & _IESO_OFF_1H
	__config	_CONFIG2L, _PWRT_ON_2L & _BOR_ON_ACTIVE_2L & _BORV_21_2L & _VREGEN_ON_2L
; *** Change _WDT_OFF_2H -> _WDT_ON_2H for release build
	__config	_CONFIG2H, _WDT_OFF_2H & _WDTPS_1_2H
	__config	_CONFIG3H, _MCLRE_ON_3H & _LPT1OSC_OFF_3H & _PBADEN_OFF_3H & _CCP2MX_OFF_3H
; *** Change _DEBUG_ON_4L -> _DEBUG_OFF_4L for release build
	__config	_CONFIG4L, _STVREN_OFF_4L & _LVP_OFF_4L & _ICPRT_OFF_4L & _XINST_OFF_4L & _DEBUG_OFF_4L
	__config	_CONFIG5L, _CP0_OFF_5L & _CP1_OFF_5L & _CP2_OFF_5L & _CP3_OFF_5L
	__config	_CONFIG5H, _CPB_OFF_5H & _CPD_OFF_5H
	__config	_CONFIG6L, _WRT0_OFF_6L & _WRT1_OFF_6L & _WRT2_OFF_6L & _WRT3_OFF_6L
	__config	_CONFIG6H, _WRTB_OFF_6H & _WRTC_OFF_6H & _WRTD_OFF_6H
	__config	_CONFIG7L, _EBTR0_OFF_7L & _EBTR1_OFF_7L & _EBTR2_OFF_7L & _EBTR3_OFF_7L
	__config	_CONFIG7H, _EBTRB_OFF_7H

; Set default radix to decimal
	radix dec

; --- I/O
pAddr		equ	LATB								; EEPROM/Flash high address (A12->A19)

pReset		equ	LATC								; 4040 Reset
bReset		equ	0
pClk		equ	LATC								; 4040 Clock
bClk		equ	1

pData		equ	PORTD								; EPROM/Flash data bus

pOE			equ	LATE								; EPROM/Flash Output Enable
bOE			equ	0
pCE			equ	LATE								; EPROM/Flash Chip Enable
bCE			equ	1
pPWR32		equ	LATE								; Power control for pin 32
bPWR32		equ	2

; --- Register usage

	cblock 0x00										;
	temp											; Temps
	temp1											;
	temp2											;
	flags											; Flags
													;
													; - Chip config
	size_l											; Chip size low
	size_m											; Chip size mid
	size_h											; Chip size high
	pgm_mask										; PGM mask
	pwr_mask										; Power mask
	ctl_mask										; Control line mask
													;
													; - Read
	addr_l											; Address low (0->7)
	addr_m											; Address mid (8->15)
	addr_h											; Address high (16->23)
	len_l											; Length low
	len_m											; Length mid
	len_h											; Length high
													;
													; - Hex
	data_len										; Hex line data length
	rec_type										; Hex line record type
	hex_count										; Hex line byte index
	chksum											; Checksum
													;
													; - XYModem
	xy_block										; XYModem block
	xy_count										; XYModem block byte count
	xy_chksum										; XModem cheksum
	xy_crc_h										; XYModem CRC
	xy_crc_l										;
	endc											;
													;
fHex		equ	0									; Hex upload flag
fXYModem	equ	1									; XYModem flag
fAbort		equ	4									; Abort XYModem flag
fCRC		equ	5									; Use CRC flag (YModem,XModem-1K)
fFilename	equ	6									; Send file name flag (YModem)
fNoAck		equ	7									; No ACK flag (YModem-G)
													;
fcOE		equ	0									; Set OE high
fcCE		equ	1									; Set CE high
fcA10		equ 2									; Set A10 high
fcA11asA10	equ	3									; Use A11 as A10

; Control chars used by XYModem
SOH			equ	0x01
EOT			equ	0x04
ACK			equ	0x06
NAK			equ	0x15
CAN			equ	0x18

; ----- Reset -----
	org			0
	; Goto main code
	bra			Start

; ----- ISR -----
	org			8
	retfie	; Enable global interrupts and return

; ----- Main starts here -----
Start
	movlw		(1<<IRCF2) | (1<<IRCF1) | (1<<IRCF0) | (1<<SCS1); Setup prescaler for 8 MHz internal clock (1 MHz default)
	movwf		OSCCON

	movlw		(1<<PCFG3) | (1<<PCFG2) | (1<<PCFG1) | (1<<PCFG0) ; Make all ADC pins digital
	movwf		ADCON1

; Setup port A - All outputs low
	clrf		LATA
	clrf		TRISA

	movlw		(1<<(17-12)) | (1<<(13-12))	; Setup port B - All outputs low
	movwf		pAddr	;  (A13 and A17 are inverted)
	clrf		TRISB

; Setup port C - Serial I/O as input, all others output
	clrf		LATC
	movlw		(1<<RX) | (1<<TX)
	movwf		TRISC

; Setup port D - All outputs
	clrf		LATD
	clrf		TRISD

	clrf		LATE
	bsf			pPWR32,bPWR32						; Turn off power
	clrf		TRISE								; Setup port E - All outputs

	;movlw		52-1	; 8000000 / 16 / 52 =   9,615
	;movlw		26-1	; 8000000 / 16 / 26 =  19,231
	movlw		13-1	; 8000000 / 16 / 13 =  38,462
	movwf		SPBRG
	movlw		0
	movwf		BAUDCON
	movlw		(1<<TXEN) | (1<<BRGH)
	movwf		TXSTA
	movlw		(1<<SPEN) | (1<<CREN)
	movwf		RCSTA

;DEBUG
;loopy
;	movlw		0xFF
;	movwf		PORTA
;
;	movlw		10
;	call		Delay_ms
;
;	movlw		0x00
;	movwf		PORTA
;
;	movlw		10
;	call		Delay_ms
;
;	goto loopy

	clrf		flags
; Default to hex upload
	bsf			flags,fHex

; Default chip selection
	call		Setup27C256

	movlw		'r'
	call		SerTx
	movlw		's'
	call		SerTx
	movlw		't'
	call		SerTx
	call		CRLF

	call		ShowHelp

GetCmd
	movlw		'>'
	call		SerTx

	call		SerRx
	call		DispatchCmd
	goto		GetCmd

DispatchCmd
	movwf		temp

	xorlw		'C'
	btfsc		STATUS,Z
	goto		XYModemCRC
	xorlw		'C'^'G'
	btfsc		STATUS,Z
	goto		YModemG
	xorlw		'G'^NAK
	btfsc		STATUS,Z
	goto		XModem

	movf		temp,W
	call		SerTx
	call		CRLF
	movf		temp,W

	xorlw		'r'
	btfsc		STATUS,Z
	goto		UploadEprom
	xorlw		'r'^'o'
	btfsc		STATUS,Z
	goto		ShowOptions
	xorlw		'o'^'h'
	bz			SetHexMode
	xorlw		'h'^'b'
	bz			SetBinaryMode
	xorlw		'b'^'1'
	bz			Setup27C16
	xorlw		'1'^'2'
	bz			Setup27C32
	xorlw		'2'^'3'
	bz			Setup27C64
	xorlw		'3'^'4'
	bz			Setup27C128
	xorlw		'4'^'5'
	bz			Setup27C256
	xorlw		'5'^'6'
	bz			Setup27C512
	xorlw		'6'^'7'
	bz			Setup27C010
	xorlw		'7'^'8'
	bz			Setup27C020
	xorlw		'8'^'9'
	bz			Setup27C040
	xorlw		'9'^'0'
	bz			Setup27C080
	xorlw		'0'^'`'
	bz			Setup82S181
	xorlw		'`'^'!'
	bz			Setup82S191;

	movlw		'W'
	call		SerTx
	movlw		'T'
	call		SerTx
	movlw		'F'
	call		SerTx
	movlw		'?'
	call		SerTx
	call		CRLF
	call		ShowHelp
	goto		CRLF

SetHexMode
	bsf			flags,fHex
	return

SetBinaryMode
	bcf			flags,fHex
	return

Setup27C16											; Setup for 27C16 - 2K byte
	clrf		size_h								; Size
	movlw		16/2
	movwf		size_m
	clrf		size_l

	clrf		pgm_mask

	movlw		1<<(13-12)							; A13/PWR
	movwf		pwr_mask

	clrf		ctl_mask							; Enable
	return

Setup27C32											; Setup for 27C32 - 4K byte
	clrf		size_h								; Size
	movlw		32/2								;
	movwf		size_m								;
	clrf		size_l								;
													;
	clrf		pgm_mask							;
													;
	movlw		1<<(13-12)							; A13/PWR
	movwf		pwr_mask							;
													;
	clrf		ctl_mask							; Enable
													;
	return											;

Setup27C64											; Setup for 27C64 - 8K byte
	clrf		size_h								; Size
	movlw		64/2								;
	movwf		size_m								;
	clrf		size_l								;
													;
	movlw		1<<(14-12)							; A14/*PGM
	movwf		pgm_mask							;
													;
	movlw		1<<(17-12)							; A17/PWR
	movwf		pwr_mask							;
													;
	clrf		ctl_mask							; Enable
													;
	return											;

Setup27C128											; Setup for 27C128 - 16K byte
	clrf		size_h								; Size
	movlw		128/2								;
	movwf		size_m								;
	clrf		size_l								;
													;
	movlw		1<<(14-12)							; A14/*PGM
	movwf		pgm_mask							;
													;
	movlw		1<<(17-12)							; A17/PWR
	movwf		pwr_mask							;
													;
	clrf		ctl_mask							; Enable
													;
	return											;

Setup27C256											; Setup for 27C256 - 32K byte
	clrf		size_h								; Size
	movlw		256/2								;
	movwf		size_m								;
	clrf		size_l								;
													;
	clrf		pgm_mask							;
													;
	movlw		1<<(17-12)							; A17/PWR
	movwf		pwr_mask							;
													;
	clrf		ctl_mask							; Enable
													;
	return											;

Setup27C512											; Setup for 27C512 - 64K byte
	movlw		1									; Size
	movwf		size_h								;
	clrf		size_m								;
	clrf		size_l								;
													;
	clrf		pgm_mask							;
													;
	movlw		1<<(17-12)							; A17/PWR
	movwf		pwr_mask							;
													;
	clrf		ctl_mask							; Enable
													;
	return											;

Setup27C010											; Setup for 27C010 - 128K byte
	movlw		2									; Size
	movwf		size_h								;
	clrf		size_m								;
	clrf		size_l								;
													;
	movlw		1<<(18-12)							; A18/*PGM
	movwf		pgm_mask							;
													;
	clrf		pwr_mask							;
													;
	clrf		ctl_mask							; Enable
													;
	return											;

Setup27C020											; Setup for 27C020 - 256K byte
	movlw		4									; Size
	movwf		size_h								;
	clrf		size_m								;
	clrf		size_l								;
													;
	movlw		1<<(18-12)							; A18/*PGM
	movwf		pgm_mask							;
													;
	clrf		pwr_mask							;
													;
	clrf		ctl_mask							; Enable
													;
	return											;

Setup27C040											; Setup for 27C040 - 512K byte
	movlw		8									; Size
	movwf		size_h								;
	clrf		size_m								;
	clrf		size_l								;
													;
	clrf		pgm_mask							;
													;
	clrf		pwr_mask							;
													;
	clrf		ctl_mask							; Enable
													;
	return											;

Setup27C080											; Setup for 27C080 - 1M byte
	movlw		16									; Size
	movwf		size_h								;
	clrf		size_m								;
	clrf		size_l								;
													;
	clrf		pgm_mask							;
													;
	clrf		pwr_mask							;
													;
	clrf		ctl_mask							; Enable
													;
	return											;

Setup82S181											; Setup for 82S181 - 1K byte
	clrf		size_h								; Size
	movlw		8/2									;
	movwf		size_m								;
	clrf		size_l								;
													;
	clrf		pgm_mask							;
													;
	movlw		1<<(13-12)							; A13/PWR
	movwf		pwr_mask							;
													;
	movlw		(1<<fcA10)|(1<<fcCE)				; Enable
	movwf		ctl_mask							;
													;
	return											;

Setup82S191											; Setup for 82S191 - 2K byte
	clrf		size_h								; Size
	movlw		16/2								;
	movwf		size_m								;
	clrf		size_l								;
													;
	clrf		pgm_mask							;
													;
	movlw		1<<(13-12)							; A13/PWR
	movwf		pwr_mask							;
													;
	movlw		(1<<fcA10)|(1<<fcA11asA10)|(1<<fcCE); Enable
	movwf		ctl_mask							;

	return

ShowHelp
	movlw		'H'
	call		SerTx
	movlw		'e'
	call		SerTx
	movlw		'l'
	call		SerTx
	movlw		'p'
	call		SerTx
	call		ColonSpace
	call		CRLF

; r  Read EPROM
	movlw		'r'
	call		SerTx
	call		ColonSpace
	movlw		'R'
	call		SerTx
	movlw		'e'
	call		SerTx
	movlw		'a'
	call		SerTx
	movlw		'd'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'E'
	call		SerTx
	movlw		'P'
	call		SerTx
	movlw		'R'
	call		SerTx
	movlw		'O'
	call		SerTx
	movlw		'M'
	call		SerTx
	call		CRLF

; b  Binary
	movlw		'b'
	call		SerTx
	call		ColonSpace
	movlw		'B'
	call		SerTx
	movlw		'i'
	call		SerTx
	movlw		'n'
	call		SerTx
	movlw		'a'
	call		SerTx
	movlw		'r'
	call		SerTx
	movlw		'y'
	call		SerTx
	call		CRLF

; h  Hex
	movlw		'h'
	call		SerTx
	call		ColonSpace
	movlw		'H'
	call		SerTx
	movlw		'e'
	call		SerTx
	movlw		'x'
	call		SerTx
	call		CRLF

; o  Configuration
	movlw		'o'
	call		SerTx
	call		ColonSpace
	movlw		'C'
	call		SerTx
	movlw		'o'
	call		SerTx
	movlw		'n'
	call		SerTx
	movlw		'f'
	call		SerTx
	movlw		'i'
	call		SerTx
	movlw		'g'
	call		SerTx
	movlw		'u'
	call		SerTx
	movlw		'r'
	call		SerTx
	movlw		'a'
	call		SerTx
	movlw		't'
	call		SerTx
	movlw		'i'
	call		SerTx
	movlw		'o'
	call		SerTx
	movlw		'n'
	call		SerTx
	call		CRLF

; `   1K 82S181, RY1133 (512B TBP28S42N)
	movlw		'`'
	call		SerTx
	call		ColonSpace
	movlw		'1'
	call		SerTx
	movlw		'K'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'8'
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'S'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		'8'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		','
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'R'
	call		SerTx
	movlw		'Y'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		'3'
	call		SerTx
	movlw		'3'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'('
	call		SerTx
	movlw		'5'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'B'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'T'
	call		SerTx
	movlw		'B'
	call		SerTx
	movlw		'P'
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'8'
	call		SerTx
	movlw		'S'
	call		SerTx
	movlw		'4'
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'N'
	call		SerTx
	movlw		')'
	call		SerTx
	call		CRLF

; !   2K 82S191, TPB28L166, MB7138
	movlw		'!'
	call		SerTx
	call		ColonSpace
	movlw		'2'
	call		SerTx
	movlw		'K'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'8'
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'S'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		'9'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		','
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'T'
	call		SerTx
	movlw		'P'
	call		SerTx
	movlw		'B'
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'8'
	call		SerTx
	movlw		'L'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		'6'
	call		SerTx
	movlw		'6'
	call		SerTx
	movlw		','
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'M'
	call		SerTx
	movlw		'B'
	call		SerTx
	movlw		'7'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		'3'
	call		SerTx
	movlw		'8'
	call		SerTx
	call		CRLF

; 1   2K 27C16
	movlw		'1'
	call		SerTx
	call		ColonSpace
	movlw		'2'
	call		SerTx
	movlw		'K'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'7'
	call		SerTx
	movlw		'C'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		'6'
	call		SerTx
	call		CRLF

; 2   4K 27C32
	movlw		'2'
	call		SerTx
	call		ColonSpace
	movlw		'4'
	call		SerTx
	movlw		'K'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'7'
	call		SerTx
	movlw		'C'
	call		SerTx
	movlw		'3'
	call		SerTx
	movlw		'2'
	call		SerTx
	call		CRLF

; 3   8K 27C64
	movlw		'3'
	call		SerTx
	call		ColonSpace
	movlw		'8'
	call		SerTx
	movlw		'K'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'7'
	call		SerTx
	movlw		'C'
	call		SerTx
	movlw		'6'
	call		SerTx
	movlw		'4'
	call		SerTx
	call		CRLF

; 4  16K 27C128
	movlw		'4'
	call		SerTx
	call		ColonSpace
	movlw		'1'
	call		SerTx
	movlw		'6'
	call		SerTx
	movlw		'K'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'7'
	call		SerTx
	movlw		'C'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'8'
	call		SerTx
	call		CRLF

; 5  32K 27C256
	movlw		'5'
	call		SerTx
	call		ColonSpace
	movlw		'3'
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'K'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'7'
	call		SerTx
	movlw		'C'
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'5'
	call		SerTx
	movlw		'6'
	call		SerTx
	call		CRLF

; 6  64K 27C512
	movlw		'6'
	call		SerTx
	call		ColonSpace
	movlw		'6'
	call		SerTx
	movlw		'4'
	call		SerTx
	movlw		'K'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'7'
	call		SerTx
	movlw		'C'
	call		SerTx
	movlw		'5'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		'2'
	call		SerTx
	call		CRLF

; 7 128K 27C010
	movlw		'7'
	call		SerTx
	call		ColonSpace
	movlw		'1'
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'8'
	call		SerTx
	movlw		'K'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'7'
	call		SerTx
	movlw		'C'
	call		SerTx
	movlw		'0'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		'0'
	call		SerTx
	call		CRLF

; 8 256K 27C020
	movlw		'8'
	call		SerTx
	call		ColonSpace
	movlw		'2'
	call		SerTx
	movlw		'5'
	call		SerTx
	movlw		'6'
	call		SerTx
	movlw		'K'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'7'
	call		SerTx
	movlw		'C'
	call		SerTx
	movlw		'0'
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'0'
	call		SerTx
	call		CRLF

; 9 512K 27C040
	movlw		'9'
	call		SerTx
	call		ColonSpace
	movlw		'5'
	call		SerTx
	movlw		'1'
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'K'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'7'
	call		SerTx
	movlw		'C'
	call		SerTx
	movlw		'0'
	call		SerTx
	movlw		'4'
	call		SerTx
	movlw		'0'
	call		SerTx
	call		CRLF

; 0   1M 27C080
	movlw		'0'
	call		SerTx
	call		ColonSpace
	movlw		'1'
	call		SerTx
	movlw		'M'
	call		SerTx
	movlw		' '
	call		SerTx
	movlw		'2'
	call		SerTx
	movlw		'7'
	call		SerTx
	movlw		'C'
	call		SerTx
	movlw		'0'
	call		SerTx
	movlw		'8'
	call		SerTx
	movlw		'0'
	call		SerTx
	call		CRLF

	return

ShowOptions
	movlw		'S'
	call		SerTx
	movlw		'i'
	call		SerTx
	movlw		'z'
	call		SerTx
	movlw		'e'
	call		SerTx
	call		ColonSpace
	movf		size_h,W
	call		tx_hex_byte
	movf		size_m,W
	call		tx_hex_byte
	movf		size_l,W
	call		tx_hex_byte
	call		CRLF
	movlw		'P'									;
	call		SerTx								;
	movlw		'w'									;
	call		SerTx								;
	movlw		'r'									;
	call		SerTx								;
	call		ColonSpace							;
	movf		pwr_mask,W							;
	call		tx_hex_byte							;
	call		CRLF								;	
	movlw		'P'									;
	call		SerTx								;
	movlw		'g'									;
	call		SerTx								;
	movlw		'm'									;
	call		SerTx								;
	call		ColonSpace							;
	movf		pgm_mask,W							;
	call		tx_hex_byte							;
	call		CRLF								;	
	movlw		'C'									;
	call		SerTx								;
	movlw		't'									;
	call		SerTx								;
	movlw		'l'									;
	call		SerTx								;
	call		ColonSpace							;
	movf		ctl_mask,W							;
	call		tx_hex_byte							;
	call		CRLF								;	
	return											;

SetupLen											;
	movff		size_h,len_h						;
	movff		size_m,len_m						;
	movff		size_l,len_l						;
	return											;

YModemG												; --- X/Y Modem ---
	bsf			flags,fNoAck						;
XYModemCRC											;
	bsf			flags,fFilename						;
	bsf			flags,fCRC							;
XModem												;
	bsf			flags,fXYModem						;
	call		UploadEprom							;
	bcf			flags,fXYModem						;
	bcf			flags,fAbort						;
	bcf			flags,fCRC							;
	bcf			flags,fFilename						;
	bcf			flags,fNoAck						;
	return											;

UploadEprom											; --- Read EPROM and send to host ---
													;
	call		PowerOn								;
													;
	movlw		100									;
	call		Delay_ms							;
													;
	call		SetupLen							;
	call		ResetAddress						;
													;
	call		BeginUpload							;
													;
read_loop											;
	movf		pData,W								;
	call		UploadByte							;
													;
	call		IncAddress							; Increment address
													;
	decf		len_l,F								; Decrement length
	btfss		STATUS,C							;
	decf		len_m,F								;
	btfss		STATUS,C							;
	decf		len_h,F								;
													; 
	movf		len_l,W								; Check if length is zero
	iorwf		len_m,W								;
	iorwf		len_h,W								;
													;
	btfss		STATUS,Z							;
	goto		read_loop							;
													;
	call		ResetAddress						;
													;
	call		EndUpload							;
													;
	movlw		250									;
	call		Delay_ms							;
													;
	call		PowerOff							;
													;
	return											;

PowerOn												;
	bcf			pPWR32,bPWR32						; Turn on pin 32
	call		set_addr							; Turn on other power pins (if used)
	movlw		0xFF								; Make data lines inputs
	movwf		TRISD								;
	bsf			PORTE,RDPU							; Enable weak pullups on data lines
	btfsc		ctl_mask,fcCE						; CE high
	bsf			pCE,bCE								;
	btfsc		ctl_mask,fcOE						; OE high
	bsf			pOE,bOE								;
	return											;

PowerOff											;
	bcf			pClk,bClk							; Reset 4040
	bsf			pReset,bReset						;
	bcf			pReset,bReset						; Release 4040 reset
	clrf		LATD								; Make data lines low
	bcf			pOE,bOE								; Make control lines low
	bcf			pCE,bCE								;
	bcf			PORTE,RDPU							; Disable weak pullups on data lines
	clrf		TRISD								; Make data lines outputs
	movlw		(1<<(17-12)) | (1<<(13-12))			; A13, A17, PGM off
	movwf		pAddr								;
	bsf			pPWR32,bPWR32						; Pin 32 off
	return											;

Delay_ms											; Wait W milliseconds
	movwf		temp								;
ms1													;
	movlw		249									;
	movwf		temp1								;
	goto		$+2									;
ms2													;
	goto		$+2									;
	nop												;
	nop												;
	decfsz		temp1,F								;
	goto		ms2									;
	decfsz		temp,F								;
	goto		ms1									;
	return											;

ResetAddress										;
	bcf			pClk,bClk							; Reset 4040
	bsf			pReset,bReset						;
	clrf		addr_l								; Clear address registers
	clrf		addr_m								;
	clrf		addr_h								;
	bcf			pReset,bReset						; Release 4040 reset
													;
	btfsc		ctl_mask,fcA10						; Set A10 high
	call		inc1k								;
	goto		set_addr							; Do high address bits...
													;
inc1k												; - Increment 4040 address by 1K
	clrf		temp								; 256 iterations
pclk4												;
	call		clk_addr							; Pulse 4040 clk 4 times
	call		clk_addr							;
	call		clk_addr							;
	call		clk_addr							;
	decfsz		temp,F								; Loop...
	goto		pclk4								;
	return											;
													;
clk_addr											; - Pulse 4040 clk
	bsf			pClk,bClk							;
	goto		$+2									;
	bcf			pClk,bClk							;
	return											;
													;
IncAddress											;
	bsf			pClk,bClk							; Clock 4040
	incf		addr_l,F							; Inc address registers
	btfsc		STATUS,C							;
	incf		addr_m,F							;
	btfsc		STATUS,C							;
	incf		addr_h,F							;
	bcf			pClk,bClk							; Release 4040 clock
	btfss		ctl_mask,fcA11asA10					;
	goto		set_addr							;
													;
	movf		addr_l,W							;
	iorwf		addr_h,W							;
	bnz			set_addr							; 00xx00
	movf		addr_m,W							;
	xorlw		0x04								; xx04xx
	bnz			set_addr							;
	call		inc1k								;
													;
set_addr											;
	swapf		addr_m,W							; Get bits 12->15 to bits 0->3
	andlw		0x0F								;
	movwf		temp								;
	swapf		addr_h,W							; Get bits 16->19 to bits 4->7
	andlw		0xF0								;
	iorwf		temp,W								; Merge
	iorwf		pgm_mask,W							; Use PGM mask
	iorwf		pwr_mask,W							; Use PWR mask
	xorlw		(1<<(17-12))|(1<<(13-12))			; Invert lines driven by transistors
	movwf		pAddr								; Output
	return											;

BeginUpload											; --- Upload ---
	btfsc		flags,fXYModem						;
	call		BeginXYModem						;
													;
	btfsc		flags,fHex							;
	call		BeginHex							;
													;
	return											;

EndUpload											;
	btfsc		flags,fHex							;
	call		EndHex								;
													;
	btfsc		flags,fXYModem						;
	call		EndXYModem							;
													;
	return											;
													;
UploadByte											;
	btfsc		flags,fHex							;
	goto		TxHex								;
	btfsc		flags,fXYModem						;
	goto		TxXYModem							;
	goto		SerTx								;

; --- Hex ---
BeginHex											;
	movlw		16									; Setup line length
	movwf		data_len							;
	movlw		0									; Set record type to 'data'
	movwf		rec_type							;
	clrf		hex_count							; Reset line byte count
	return											;
													;
EndHex												;
	clrf		data_len							; - Send end record
	movlw		1									;
	movwf		rec_type							;
	call		BOL									;
	call		EOL									;
	return											;
													;
TxHex												; - Send hex byte
	movwf		temp								;
													;
	movf		hex_count,F							;
	btfsc		STATUS,Z							;
	call		BOL									;
													;
	movf		temp,W								;
	call		tx_hex_byte							;
													;
	incf		hex_count,F							;
	movf		hex_count,W							;
	xorwf		data_len,W							;
	btfsc		STATUS,Z							;
	call		EOL									;
	return											;
													;
BOL													; - Begin a hex line
	movlw		':'									; Start char
	call		tx_char								;
	clrf		chksum								; Init checksum
	movf		data_len,W							; Length
	call		tx_hex_byte							;
	movf		addr_m,W							; Address
	call		tx_hex_byte							;
	movf		addr_l,W							;
	call		tx_hex_byte							;
	movf		rec_type,W							; Record type
	goto		tx_hex_byte							;
													;
													;
EOL													; - End a hex line
	clrf		hex_count							; Reset byte count
	comf		chksum,W							; Checksum
	addlw		1									;
	call		tx_hex_byte							;
	movlw		13									; CR
	call		tx_char								;
	movlw		10									; LF
	goto		tx_char								;
													;
tx_hex_byte											;
	addwf		chksum,F							;
	movwf		temp1								;
	swapf		temp1,W								;
	rcall		tx_hex_nibble						;
	movf		temp1,W								;
	;bra		tx_hex_nibble						;
													;
tx_hex_nibble										;
	andlw		0x0F								;
	addlw		-10									;
	btfsc		STATUS,C							;
	addlw		'A'-'9'-1							;
	addlw		10+'0'								;
tx_char												;
	btfsc		flags,fXYModem						;
	bra			TxXYModem							;
	goto		SerTx								;

; --- XYModem ---
BeginXYModem										; - Begin XYModem
	clrf		xy_count							;
	clrf		xy_block							;
													;
	btfsc		flags,fFilename						;
	goto		beginY								;
													;
	incf		xy_block,F							; XModem begins with block 1
	return											;
													;
beginY												; - Send file name (YModem(-G) only)
	movlw		'e'									;
	call		TxXYModem							;
	movlw		'p'									;
	call		TxXYModem							;
	movlw		'r'									;
	call		TxXYModem							;
	movlw		'o'									;
	call		TxXYModem							;
	movlw		'm'									;
	call		TxXYModem							;
	movlw		'.'									;
	call		TxXYModem							;
	movlw		'h'									;
	btfss		flags,fHex							;
	movlw		'b'									;
	call		TxXYModem							;
	movlw		'e'									;
	btfss		flags,fHex							;
	movlw		'i'									;
	call		TxXYModem							;
	movlw		'x'									;
	btfss		flags,fHex							;
	movlw		'n'									;
	call		TxXYModem							;
	movlw		0									;
	call		TxXYModem							;
													;
	call		EndXYBlock							;
													;
	call		SerRx								;
													;
	return											;
													;
													;
													;
EndXYModem											;
	movf		xy_count,F							; Finish incomplete block
	btfss		STATUS,Z							;
	call		EndXYBlock							;
													;
	movlw		EOT									; EOT
	call		SerTx								;
	call		SerRx								;
													;
	btfss		flags,fFilename						;
	return											;
													;
	call		SerRx								;
	clrf		xy_block							; Send empty block 0 (filename) to end YModem upload
null_block											;
	movlw		0									;
	call		TxXYModem							;
	movf		xy_count,F							;
	bnz			null_block							;

	return

BeginXYBlock										; - Begin a XYModem block
	clrf		xy_chksum							; Init checksum
	clrf		xy_crc_h							; Init CRC
	clrf		xy_crc_l							;
	movlw		1									; SOH
	call		SerTx								;
	movf		xy_block,W							; Block #
	call		SerTx								;
	comf		xy_block,W							; Block # compliment
	goto		SerTx								;

xy_pad												;
	movlw		0x1A								; EOF (Ctrl-Z)
	call		UpdateCRC							;
	movlw		0x1A								;
	call		SerTx								;
	incf		xy_count,F							;
EndXYBlock											; - End a XYModem block
	btfss		xy_count,7							; Pad to 128 bytes
	goto		xy_pad								;

	movf		xy_chksum,W							; Send checksum/CRC
	btfsc		flags,fCRC							;
	movf		xy_crc_h,W							;
	call		SerTx								;
	movf		xy_crc_l,W							;
	btfsc		flags,fCRC							;
	call		SerTx								;

	clrf		xy_count							; Reset block byte count
	incf		xy_block,F							; Increment block #

	btfss		flags,fNoAck
	call		SerRx

	return

TxXYModem											; - Send a byte using XYModem
	movwf		temp2								; Save byte to send

	movf		xy_count,F							; Begin new block if byte count is zero
	btfsc		STATUS,Z
	call		BeginXYBlock

	movf		temp2,W								;
	addwf		xy_chksum							; Update checksum
	btfsc		flags,fCRC							; Update CRC
	call		UpdateCRC							;
	movf		temp2,W								; Send saved byte
	call		SerTx

	incf		xy_count,F							; Inc byte count
	btfsc		xy_count,7							; End block if byte count is >= 128
	call		EndXYBlock

	return

UpdateCRC
; Simple CRC routine
; from John Payson 1998-10-23
;
; 1021 << 0 ==   10 21
; 1021 << 1 ==   20 42
; 1021 << 2 ==   40 84
; 1021 << 3 ==   81 08
; 1021 << 4 == 1 02 10 ^ 10 21 == 1 12 31
; 1021 << 5 == 2 04 20 ^ 20 42 == 2 24 62
; 1021 << 6 == 4 08 40 ^ 40 84 == 4 48 C4
; 1021 << 7 == 8 10 80 ^ 81 08 == 8 91 88

	xorwf		xy_crc_h							; Add new data to CRC
													;
	movlw		0									; Compute the LSB first [based upon MSB]
	btfsc		xy_crc_h,0							;
	xorlw		0x21								;
	btfsc		xy_crc_h,1							;
	xorlw		0x42								;
	btfsc		xy_crc_h,2							;
	xorlw		0x84								;
	btfsc		xy_crc_h,3							;
	xorlw		0x08								;
	btfsc		xy_crc_h,4							;
	xorlw		0x31								;
	btfsc		xy_crc_h,5							;
	xorlw		0x62								;
	btfsc		xy_crc_h,6							;
	xorlw		0xC4								;
	btfsc		xy_crc_h,7							;
	xorlw		0x88								;

	; Swap xy_crc_l with W
	xorwf		xy_crc_l,F
	xorwf		xy_crc_l,W
	xorwf		xy_crc_l,F

	; Next compute the MSB [note W holds old LSB]
	btfsc		xy_crc_h,0
	xorlw		0x10
	btfsc		xy_crc_h,1
	xorlw		0x20
	btfsc		xy_crc_h,2
	xorlw		0x40
	btfsc		xy_crc_h,3
	xorlw		0x81
	btfsc		xy_crc_h,4
	xorlw		0x12
	btfsc		xy_crc_h,5
	xorlw		0x24
	btfsc		xy_crc_h,6
	xorlw		0x48
	btfsc		xy_crc_h,7
	xorlw		0x91
	movwf		xy_crc_h

	return

; --- Receive from hardware UART
SerRx
	clrwdt
	btfss		PIR1,RCIF		; Wait for a rx char
	bra			SerRx
	movf		RCSTA,W
	andlw		(1<<FERR) | (1<<OERR)
	bz			no_com_error
	bcf			RCSTA,CREN
	bsf			RCSTA,CREN
	bra			SerRx								; rx error...
no_com_error
	movf		RCREG,W								; Get rx char
	return

; --- Transmit with hardware UART
SerTx
	clrwdt
	btfss		PIR1,TXIF		; Wait for a tx buffer available
	bra			SerTx

	movwf		TXREG		; Send char
	return

ColonSpace
	movlw		':'
	rcall		SerTx
	movlw		' '
	bra			SerTx

CRLF
	movlw		13
	rcall		SerTx
	movlw		10
	bra			SerTx

	end

