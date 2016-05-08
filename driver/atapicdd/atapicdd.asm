;*******************************************************************************
;
;  ATAPICDD - ATAPI CD Driver for DOS
;  Written by Kenneth J. Davis <jeremyd@computer.org>, 2001-2003
;  Released to public domain  [ U.S. Definition ]
;
;  ATAPI code based on public domain C code from Hale Landis' ATADRVR
;
;  Use at own risk, author assumes no liability nor responsibility
;  for use, misuse, lack of use, or anything else as a result
;  of this program.  No warranty or other implied nor given.
;
;  Please send bug reports to me so that they may hopefully be fixed.
;  If possible please include your contact information (email address)
;  so I may ask you further details or to verify it as fixed.
;  Fixes will be supplied as my time permits.
;
   ReleaseStr    EQU 'v0.2.6 ALPHA'
   DRIVERVERSION EQU 0,2,6
;  Version # = major.minor.developement (0 for dev == released version)
;
;  Still to do, add support for optional commands to play/stop/resume audio
;  Also add support for buffering/prefetching to enhance performance and
;  support for direct control strings to be sent to CD
;  Future, enhance for DVD and/or CD/DVD writers
;  Consider refactoring to support custom base I/O addresses, presently
;  only handle default base I/O addresses with status at base + 0x0206
;  WARNING not re-entrant! presently relies on global data & own single stack
;
;*******************************************************************************

LOCALS	; needed by TASM to enable @@ local symbols to work
JUMPS		; automatically handle case where conditional jump short is too far away

code segment para public 'CODE' use16
	assume cs:code, ds:nothing, es:nothing

; General EQUATES

; Uncomment this for development/testing releases only!
DEBUG EQU 01h

; device driver request header
DEVREQ_LENGTH	EQU 00h	; byte
DEVREQ_UNIT		EQU 01h	; byte
DEVREQ_CMD		EQU 02h	; byte
DEVREQ_STATUS	EQU 03h	; word
DEVREQ_RESERVED	EQU 05h	; 8 bytes
DEVREQ_DATA		EQU 0Dh	; variable size

; flags for setting status bits in request header (assume status dw 0 on entry)
STATUS_ERROR	EQU 8000h	; Should be set if error, with low 8bits == error code
STATUS_BUSY		EQU 0200h	; Should always be set if in audio play mode
STATUS_DONE		EQU 0100h	; Indicates done processing request

; error values when STATUS_ERROR is set (byte)
ERROR_UNKNOWNUNIT		EQU 01h	; unknown (or unsupported) unit specified
ERROR_DEVICENOTREADY	EQU 02h	; device not ready
ERROR_UNKNOWNCMD		EQU 03h	; unknown (or unsupported) command
ERROR_SECTORNOTFOUND	EQU 08h	; sector not found
ERROR_READERROR		EQU 0Bh	; error reading
ERROR_GENERALFAILURE	EQU 0Ch	; general failure
ERROR_INVLDDSKCHNGE 	EQU 0Fh	; invalid disk change

; offsets in the device request header's data section for init request
DEVREQI_UNITS	EQU 00h	; # of subunits, not set by character devices (or set to 0) (byte)
DEVREQI_ENDADDR	EQU 01h	; end of resident code (dword)
DEVREQI_PBPB	EQU 05h	; pointer to BPB array, not set by character devices (dword)
DEVREQI_CMDLINE	EQU 05h	; on entry BPB points to info in CONFIG.SYS after = (ends with \n,\r, or \r\n)
DEVREQI_DRIVE	EQU 09h	; drive number [block device number, 0 for character device] (byte)
DEVREQI_CFGFLG	EQU 10h	; CONFIG.SYS Error Message control flag (word)

; offsets in the device request header's data section for read/prefetch requests
DEVREQR_ADDRMODE	EQU 00h	; addressing mode (byte)
DEVREQR_TRANSADDR	EQU 01h	; transfer address (dword)
DEVREQR_SECTCNT	EQU 05h	; number (count) of sectors to read in (word)
DEVREQR_START	EQU 07h	; starting sector number (dword)
DEVREQR_MODE	EQU 0Bh	; read mode (byte)
DEVREQR_ILSIZE	EQU 0Ch	; interleave size
DEVREQR_ILSKIP	EQU 0Dh	; interleave skip factor

; offsets in the device request header's data section for seek requests
DEVREQS_ADDRMODE	EQU 00h	; addressing mode (byte)
DEVREQS_TRANSADDR	EQU 01h	; transfer address (dword) == 0
DEVREQS_SECTCNT	EQU 05h	; number (count) of sectors to read in (word) == 0
DEVREQS_START	EQU 07h	; starting sector number

; offsets from control block (specified by transfer address in device request)
; for both Cmd_IOCTL_input and Cmd_IOCTL_output requests
CBLK_CMDCODE      	EQU 00h	; command code (control block code), i.e. command to perform

; for Cmd_IOCTL_input's command codes, offset in control block, note 00h is always CBLK_CMDCODE
; format is:  code (number of bytes to transfer, i.e. sizeof(control block)) description

; GetDevHdr code 0 (5 bytes) return address of device header
CBLK_DEVHDRADDR	EQU 01h	; offset to place address of device driver header
; HeadLoc code 1 (6 bytes) location of head
CBLK_ADDRMODE	EQU 01h	; byte specifying addressing mode
CBLK_LOCHEAD	EQU 02h	; DD specifying current location of the drive head
; Reserved code 2 (? bytes) reserved, return unknown command
; ErrStats code 3 (? bytes) error statistics
; AudioChannel code 4 (9 bytes) audio channel information
; ReadDrvB code 5 (130 bytes) read drive bytes
; DevStatus code 6 (5 bytes) device status
; SectorSize code 7 (4 bytes) return size of sectors
; VolumeSize code 8 (5 bytes) return size of volume
; MediaChanged code 9 (2 bytes) media changed
CBLK_MEDIABYTE	EQU 01h	; byte specifying if disc changed (-1 yes, 0 don't know, 1 no)
; AudioDisk code 10 (7 bytes) audio disk information
CBLK_LOWTRACKNUM	EQU 01h	; byte, lowest track number  (binary, not BCD)
CBLK_HIGHTRACKNUM	EQU 02h	; byte, highest track number (binary, not BCD)
CBLK_STARTLOTRACK	EQU 03h	; DD (MSF) of Starting point of the lead-out track
; AudioTrack code 11 (7 bytes) audio track information
CBLK_TRACKNUM	EQU 01h	; byte, track number
CBLK_STARTTRACK	EQU 02h	; DD (MSF) of starting point of the track
CBLK_TRACKCTRL	EQU 06h	; byte, track control information
; AudioQCh code 12 (11 bytes) audio Q-Channel information
; AudioSubCh code 13 (13 bytes) audio Sub-Channel information
; UPC code 14 (11 bytes) UPC code
; AudioStatus code 15 (11 bytes) audio status information
; codes 16-255 (? bytes) reserved, return unknown command


; ATA commands see Information Technology - AT Attachment with Packet Interface - 6 (ATA/ATAPI-6) [draft 1410 rev 3a]
CMD_IDENTIFY_DEVICE		EQU 0ECh
CMD_IDENTIFY_DEVICE_PACKET	EQU 0A1h
CMD_IDENTIFY_PACKET_DEVICE	EQU 0A1h
CMD_NOP				EQU 00h
CMD_PACKET				EQU 0A0h

; ATAPI Packet Commands	see INF-8090i [5.4]  ATA Packet Interface for DVD (and CD) ROM, RAM, R, & RW devices
;                       see also obsolete INF-8020i [E]  ATA Packet Interface for CD-ROMs
AC_BLANK                EQU 0A1h
AC_CLOSETRACKSESSION    EQU 5Bh
AC_COMPARE              EQU 39h
AC_ERASE10              EQU 2Ch
AC_FORMATUNIT           EQU 04h
AC_GETCONFIGURATION     EQU 46h
AC_GETEVENTSTATUSNOTIFY EQU 4Ah
AC_GETPERFORMANCE       EQU 0ACh
AC_INQUIRY              EQU 12h
AC_LOADUNLOADMEDIUM     EQU 0A6h
AC_LOCKUNLOCKCACHE      EQU 36h
AC_LOGSELECT            EQU 4Ch
AC_LOGSENSE             EQU 4Dh
AC_MECHANISMSTATUS      EQU 0BDh
AC_MODESELECT           EQU 55h
AC_MODESENSE            EQU 5Ah
AC_PAUSERESUME          EQU 4Bh
AC_PLAYAUDIO            EQU 45h
AC_PLAYAUDIOMSF         EQU 47h
AC_PLAYCD               EQU 0BCh
AC_PREFETCH             EQU 34h
AC_MEDIUMREMOVAL        EQU 1Eh
AC_READ10               EQU 28h
AC_READ12               EQU 0A8h
AC_READBUFFER           EQU 3Ch
AC_READBUFFERCAPACITY   EQU 5Ch
AC_READCAPACITY         EQU 25h
AC_READCD               EQU 0BEh
AC_READCDMSF            EQU 0B9h
AC_READDISCINFO         EQU 51h
AC_READDVDSTRUCTURE     EQU 0ADh
AC_READFORMATCAPACITIES EQU 23h
AC_READHEADER           EQU 44h
AC_READSUBCHANNEL       EQU 42h
AC_READTOC              EQU 43h
AC_READTRACKINFO        EQU 52h
AC_RECEIVEDIAGRESULTS   EQU 1Ch
AC_RELEASE6             EQU 17h
AC_RELEASE10            EQU 57h
AC_REPAIRRZONE          EQU 58h
AC_REPORTKEY            EQU 0A4h
AC_REQUESTSENSE         EQU 03h
AC_RESERVE6             EQU 16h
AC_RESERVE10            EQU 56h
AC_RESERVETRACK         EQU 53h
AC_SCAN                 EQU 0BAh
AC_SEEK                 EQU 2Bh
AC_SENDCUESHEET         EQU 5Dh
AC_SENDDIAGNOSTIC       EQU 1Dh
AC_SENDDVDSTRUCTURE     EQU 0BFh
AC_SENDEVENT            EQU 0A2h
AC_SENDKEY              EQU 0A3h
AC_SENDOPCINFO          EQU 54h
AC_SETCDSPEED           EQU 0BBh
AC_SETREADAHEAD         EQU 0A7h
AC_SETSTREAMING         EQU 0B6h
AC_STARTSTOPUNIT        EQU 1Bh
AC_STOPPLAYSCAN         EQU 4Eh
AC_SYNCCACHE            EQU 35h
AC_TESTUNITREADY        EQU 00h
AC_VERIFY10             EQU 2Fh
AC_WRITE10              EQU 2Ah
AC_WRITE12              EQU 0AAh
AC_WRITEANDVERIFY10     EQU 2Eh
AC_WRITEBUFFER          EQU 3Bh

; ATAPI Packet Command causes Input or Output of data
APC_INPUT	EQU 0h
APC_OUTPUT	EQU 1h
APC_DONE	EQU -1

; Address Mode
AM_HSG	EQU 0h	; HSG addressing mode (logical block address as defined by High Sierra)
AM_RED	EQU 01h	; Red Book addressing mode (minute/second/frame)
; 02h through 0FFh are reserved
; logical block (sector) = 75 * (minute*60 + second) + frame - 150

; Data Mode
DM_COOKED	EQU 0h	; cooked, 2048 byte sectors, device handles EDC/ECC (errors)
DM_RAW	EQU 01h	; as much data of raw sectors as device can give aligned to 2352 byte sectors
; 02h through 0FFh are reserved


; ATA register set, command block & control block regs, ofsets into pio_reg_addrs[]
CB_DATA	EQU 0   ; data reg         in/out pio_base_addr1+0
CB_ERR	EQU 1   ; error            in     pio_base_addr1+1
CB_FR		EQU 1   ; feature reg         out pio_base_addr1+1
CB_SC		EQU 2   ; sector count     in/out pio_base_addr1+2
CB_SN		EQU 3   ; sector number    in/out pio_base_addr1+3
CB_CL		EQU 4   ; cylinder low     in/out pio_base_addr1+4
CB_CH		EQU 5   ; cylinder high    in/out pio_base_addr1+5
CB_DH		EQU 6   ; device head      in/out pio_base_addr1+6
CB_STAT	EQU 7   ; primary status   in     pio_base_addr1+7
CB_CMD	EQU 7   ; command             out pio_base_addr1+7
CB_ASTAT	EQU 8   ; alternate status in     pio_base_addr2+6
CB_DC		EQU 8   ; device control      out pio_base_addr2+6
CB_DA		EQU 9   ; device address   in     pio_base_addr2+7

; device control reg (CB_DC) bits
CB_DC_HOB	EQU 80h	; High Order Byte (48-bit LBA)
CB_DC_HD15	EQU 00h	; bit 3 is reserved, (old definition was 08h)
CB_DC_SRST	EQU 04h	; soft reset
CB_DC_NIEN	EQU 02h	; disable interrupts

; value for device control register, presently we don't use/enable interrupts
devCtrl EQU CB_DC_HD15 OR CB_DC_NIEN

; ATAPI Interrupt Reason bits in the Sector Count reg (CB_SC)
CB_SC_P_TAG	EQU 0F8h	; ATAPI tag (mask)
CB_SC_P_REL	EQU 04h	; ATAPI release
CB_SC_P_IO	EQU 02h	; ATAPI I/O
CB_SC_P_CD	EQU 01h	; ATAPI C/D

; bits 7-4 of the device/head (CB_DH) reg
CB_DH_LBA		EQU 40h	; LBA bit
CB_DH_DEV0		EQU 00h	; select device 0 (master), formally 0A0h
CB_DH_DEV1		EQU 10h	; select device 1 (slave),  formally 0B0h

; status reg (CB_STAT and CB_ASTAT) bits
CB_STAT_BSY		EQU 80h	; busy
CB_STAT_RDY		EQU 40h	; ready
CB_STAT_DF		EQU 20h	; device fault
CB_STAT_WFT		EQU 20h	; write fault (old name)
CB_STAT_SKC		EQU 10h	; seek complete
CB_STAT_SERV	EQU 10h	; service
CB_STAT_DRQ		EQU 08h	; data request
CB_STAT_CORR	EQU 04h	; corrected
CB_STAT_IDX		EQU 02h	; index
CB_STAT_ERR		EQU 01h	; error (ATA)
CB_STAT_CHK		EQU 01h	; check (ATAPI)

; bits and values used in determining media status via AC_EVENTSTATUSNOTIFY
STATUS_MEDIA_UNKNOWN 	EQU -1	; word value
STATUS_MEDIA_NOCHANGE	EQU 0		; LSB byte
STATUS_MEDIA_CHANGED 	EQU 1		; LSB byte
STATUS_NEA 			EQU 80h	; mask for No Event Available flag
STATUS_CLASS 		EQU 07h	; mask for notification class
STATUS_MEDIA 		EQU 04h	; the class value for media status


; use IFDEF DEBUG ENDIF for debug blocks or below print macros
; use IFDEF DDEBUG ENDIF for disabled/dummy debug blocks you don't want to remove

; Prints specified character if DEBUG defined, else assembles to empty text
DEBUG_PrintChar MACRO z
	IFDEF DEBUG
	push AX
	mov  AL, z
	call PrintChar
	pop  AX
	ENDIF
ENDM DEBUG_PrintChar

; dummy or disabled version
DDEBUG_PrintChar MACRO z
ENDM DDEBUG_PrintChar

; Prints specified number (byte) if DEBUG defined, else assembles to empty text
DEBUG_PrintNumber MACRO z
	IFDEF DEBUG
	push AX
	mov  AL, z
	call PrintNumber
	pop  AX
	ENDIF
ENDM DEBUG_PrintNumber

; dummy or disabled version
DDEBUG_PrintNumber MACRO z
ENDM DDEBUG_PrintNumber


;*******************************************************************************

; Normal device driver header with CD-ROM character device extension
devHdr:
	DD -1			; point to next driver in chain, -1 for end of chain
	DW 0C800h		; device attributes
				;  Bit 15         1       - Character device
				;  Bit 14         1       - IOCTL supported
				;  Bit 13         0       - Output 'till  busy
				;  Bit 12         0       - Reserved
				;  Bit 11         1       - OPEN/CLOSE/RM supported
				;  Bit 10-4       0       - Reserved
				;  Bit  3         0       - Dev is CLOCK
				;  Bit  2         0       - Dev is NUL
				;  Bit  1         0       - Dev is STO (standard output)
				;  Bit  0         0       - Dev is STI (standard input)
		DW OFFSET StrategyProc	; device driver Strategy entry point
		DW OFFSET InterruptProc	; device driver Interrupt entry point
devName	DB "ATAPICDD"		; device name (overridden by /D:name command line option, e.g. /D:FDCD0001)
;devName	DB "FDCD0000"
CDDevHdrExt:
		DW 0		; reserved (should be 0)
driveLetter	DB 0		; the 1st CD-ROM's drive letter (initially 0, set by MSCDEX or equiv)
units		DB -1		; how many drives found (number of units)
				; -1 for us indicates not yet initalized

; mark this driver as mine
myMarker	DB 'KJD PD$',0
myVersion	DW DRIVERVERSION

; Other DOS device driver related resident data
devRequest	DD 0		; stores the device request address (DOS, set by strategy, used by int proc)

oldSS DW 0			; store original stack, replaced with local one during invocation
oldSP DW 0

; Other CD driver implementation specific resident data
devAccess	DW 0		; number of active users of device driver, serves no
				; purpose other than a counter, for DevOpen & DevClose

unitReq	DB ?		; which unit (index into structure that follows) action requested for
		DB ?		; padding


; Default locations to look for ATA/ATAPI devices
;	controller    base    interrupt
;	primary       0x1F0   0x76 (IRQ14)
;	secondary     0x170   0x77 (IRQ15), or maybe 0x72 (IRQ10)
;	tertiary      0x1E8   0x74 (IRQ12), or maybe 0x73 (IRQ11)
;	quaternary    0x168   0x72 (IRQ10), or maybe 0x71 (IRQ9)
; default base locations we look for (base2 == base + 0x200, i.e. status == base + 0x206)
MAX_CONTROLLERS	EQU	04h	; we know about 4 standard base I/O addresses to search for controllers

FLG_NONE		EQU	00h	; used in flags to indicate if device exists
FLG_MASTER		EQU	01h
FLG_SLAVE		EQU	02h
FLG_MATAPI		EQU	04h	; master is an ATAPI device
FLG_SATAPI		EQU	08h	; slave is an ATAPI device
FLG_MATA		EQU	10h	; master is an ATA (not ATAPI) device
FLG_SATA		EQU	20h	; slave is an ATA device (not ATAPI)

pio_reg_addrs_base DW 01F0h, 0170h, 01E8h, 0168h
; initially assume no devices exist for each base I/O address
pio_reg_flags DB FLG_NONE, FLG_NONE, FLG_NONE, FLG_NONE

; support up to MAX_CONTROLLERS * 2 devices; 1 master + 1 slave per controller
MAX_DEVICES		EQU	MAX_CONTROLLERS*2	
; unitReq is a logical unit which is used as an index into these arrays
lun_map_addrs	DB MAX_DEVICES dup (0)	; pio_reg_addrs_base[lun_map_addrs[unitReq]] == base I/O address
							; pio_reg_flags[lun_map_addrs[unitReq]] & FLG_??? == device exists
lun_map_dev		DB MAX_DEVICES dup (0)	; indicates which device (slave or master) this unit refers to

media_changed_timeout DW MAX_DEVICES dup (2 dup (0))	; for devices that don't report media change
force_media_change DB MAX_DEVICES dup (0)			; counter, non-zero indicates call to check media returns changed,
									; if nonzero then decremented (i.e. is a counter)

; sets force media change indicator
setMediaChanged MACRO fmc_count
	push BX
	xor  BH, BH							; get lun (index) into BX
	mov  BL, CS:[unitReq]
	mov  CS:force_media_change[BX], fmc_count		; set appropriate entry in our array
	pop  BX
ENDM setMediaChanged

; gets force media change indicator into AL and decrements stored value (if != 0)
getMediaChanged MACRO
	push BX
	xor  BH, BH							; get lun (index) into BX
	mov  BL, CS:[unitReq]
	mov  AL, CS:force_media_change[BX]			; copy appropriate entry from our array into AL
	jz   @@getMediaChanged_xzy				; check if zero
	dec  CS:force_media_change[BX]			; no, well then decrement it
	@@getMediaChanged_xzy:
	pop  BX
ENDM getMediaChanged



ALIGN 16
; information used by PerformATAPIPacketCmd to send device commands and get/send data
; storage for ATAPI packet request, current 12 bytes, but reserve room for future 16 byte packets
packet	DB 16 dup (0)
packetsize	DB 12					; indicate packet length is old 12 byte kind or new 16 byte kind
datadir	DB 0					; indicate if pkt cmd inputs or outputs data (data transfer direction)
packetbufseg	DW ?				; segment of buffer, for data transfer (input or output)
packetbufoff	DW ?				; offset of buffer,  we assume it's large enough for requested data

ALIGN 16
buffer	DB 256 dup (0)			; buffer for various packet requests

ALIGN 16
; Jump table for requests
jumpTable:
	DW Cmd_Init			; Cmd 0  - init (required)
	DW Cmd_NA			; Cmd 1  - media check (block)
	DW Cmd_NA			; Cmd 2  - Build BPB (block)
	DW Cmd_IOCTL_input	; Cmd 3  - IOCTL input (required)
	DW Cmd_NA			; Cmd 4  - input read
	DW Cmd_NA			; Cmd 5  - nondestructive input (no wait)
	DW Cmd_NA			; Cmd 6  - input status
	DW Cmd_InputFlush		; Cmd 7  - input flush (required)
	DW Cmd_NA			; Cmd 8  - output write
	DW Cmd_NA			; Cmd 9  - output with verify
	DW Cmd_NA			; Cmd 10 - output status
	DW Cmd_NA			; Cmd 11 - output flush (erasable CD-ROM)
	DW Cmd_IOCTL_output	; Cmd 12 - IOCTL output (required)
	DW Cmd_DevOpen		; Cmd 13 - device open (required)
	DW Cmd_DevClose		; Cmd 14 - device close (required)
	; 15-24 route to Cmd_NA
					; Cmd 15 - removable media (block)
					; Cmd 16 - output until busy
					; Cmd 17-18 Reserved ???
					; Cmd 19 - Generic IOCTL request (if attribute bit 6 set)
					; Cmd 20-22 Reserved ???
					; Cmd 23 - get logical device (if attribute bit 6 set) (block)
					; Cmd 24 - set logical device (if attribute bit 6 set) (block)
					; Cmd 25-127 Reserved ???
extJumpTable:
	DW Cmd_ReadLong		; Cmd 128 - read long (required)
	DW Cmd_NA			; Cmd 129 - Reserved
	DW Cmd_ReadLongPrefetch	; Cmd 130 - read long prefetch (required)
	DW Cmd_Seek			; Cmd 131 - seek (required)
	DW Cmd_PlayAudio		; Cmd 132 - play audio (optional)
	DW Cmd_StopAudio		; Cmd 133 - stop audio (optional)
	DW Cmd_NA			; Cmd 134 - write long (erasable CD-ROM)
	DW Cmd_NA			; Cmd 135 - write long verify (erasable CD-ROM)
	DW Cmd_ResumeAudio	; Cmd 136 - resume audio (optional)


;*******************************************************************************

; Strategy routine - simply store request (ES:BX == Device Request Block)
StrategyProc proc far
	mov  word ptr CS:[devRequest], BX
	mov  word ptr CS:[devRequest+2], ES
	retf
StrategyProc endp


;*******************************************************************************

; Interrupt routine - process stored request 
; (CS:devRequest == Device Request Block), moved into DS:BX then
; calls command to perform action (expects DS:BX & CS to be unchanged on return)
; AX, CX, DX, DI, SI, & ES may all be modified by command called.
; TODO: add check for valid unit in request
InterruptProc proc far
	pushf			; save flags
	push AX		; save registers
	push BX
	push CX
	push DX
	push DI
	push SI
	push DS
	push ES

	cld			; set direction flag for increments
	sti			; reenable interrupts (if they were disabled)

	; set to my stack
	mov  CS:[oldSS], SS
	mov  CS:[oldSP], SP
	mov  AX, CS
	mov  DX, OFFSET mystacktop
	mov  SS, AX
	mov  SP, DX

	; load Device Request Block into DS:BX
	lds  BX, CS:[devRequest]

	; initialize status (for shsucdx which will continue to fail once set otherwise)
	mov  word ptr [BX+DEVREQ_STATUS], 0	; clear status

	; verify if unit action requested for is valid (note: units==-1 before init call)
	mov  AL, [BX+DEVREQ_UNIT]	; get unit action requested for
	cmp  AL, CS:[units]		; compare with our count of units we handle
	jb   @@getRequestedCmd		; if less than our count then proceed (jb on purpose so ok for units==-1)
	call Cmd_BADUNIT			; set failure status of unknown unit
	jmp @@done				; and return/exit

@@getRequestedCmd:
	mov  CS:[unitReq], AL		; store unit action requested for

	xor  AH, AH					; prepare so can extend AL into word
	mov  AL, [BX+DEVREQ_CMD]	
DEBUG_PrintChar '?'
DEBUG_PrintNumber al

IF 0	; docs indicate we should do this, but seems unneeded (for shsucdx) and slows things down
	; also probably will screw up at least some other programs
	; query device and determine if disk change has occurred, if so report this and exit
	push AX					; don't loose command
	cmp  AL, 0					; 1st make sure this isn't an init request
	je   @@endCheck				; if so proceed without check

DEBUG_PrintChar '|'
	call getMediaStatus			; issue ATAPI media event status request
pushf
DEBUG_PrintChar '|'
popf
	jc   @@endCheck				; if error of any sort then ignore this check
	cmp  AL, STATUS_MEDIA_NOCHANGE	; media has not changed since last time we checked
	je   @@endCheck
	pop  AX					; pop off stack
	setMediaChanged 01h			; indicate next check should indicate changed
	call Cmd_DiskChanged			; yes it has, so exit with an error and let CDEX retry
	jmp  @@done
	@@endCheck:
	pop  AX					; restore command
ENDIF

	shl  AL, 1					; get index into jump table (multiply by 2)
							; also makes it easy to determine if is one of 
							; new commands (128+)

	jnc  @@normalCmd				; shl sets carry to high bit, if not carry then cmd < 128
	cmp  AL, 16					; Commands 128-136 use extended jump table 
							; Offset/Cmd: 0/128,2/129,4/130,6/131,...
	ja   @@unknownCmd				; if above 16 then cmd is greater than 136 so unknown
	add  AL, (extJumpTable - jumpTable)	; update index to refer to extended
							; jump table (add length of jumpTable)
	jmp  @@callCommand

@@normalCmd:
	cmp  AL, 30		; (30=2*15) Commands 0-14 use jump table
	jb   @@callCommand

@@unknownCmd:
	call Cmd_NA		; consider invalid command
	jmp  @@done

@@callCommand:
	mov  DI, AX
	add  DI, OFFSET jumpTable	; add index to start of jumpTable
	call word ptr CS:[DI]		; perform the call

@@done:
	or  [BX+DEVREQ_STATUS], STATUS_DONE	; mark request as completed.
	DEBUG_PrintChar '/'
	DEBUG_PrintNumber [BX+DEVREQ_STATUS+1]
	DEBUG_PrintNumber [BX+DEVREQ_STATUS]
	DEBUG_PrintChar '/'

	; restore original stack
	cli
	mov  AX, CS:[oldSS]
	mov  DX, CS:[oldSP]
	mov  SS, AX
	mov  SP, DX
	sti

	pop  ES		; restore registers
	pop  DS
	pop  SI
	pop  DI
	pop  DX
	pop  CX
	pop  BX
	pop  AX
	popf			; restore flags
	retf
InterruptProc endp


;*******************************************************************************

; called when disk change and need to return invalid disk change
; ie if since last request the CD-ROM in the drive has changed,
; MSCDEX or equiv will determine if it should retry the request or abort it
Cmd_DiskChanged proc near
	mov AX, [BX+DEVREQ_STATUS]	; get current status value
	or  AX, STATUS_ERROR		; set error flag
	mov AL, ERROR_INVLDDSKCHNGE	; set error to invalid disk change
	mov [BX+DEVREQ_STATUS], AX	; set returned status value
	retn
Cmd_DiskChanged endp


;*******************************************************************************
;*******************************************************************************

; Command not available - simply return error
Cmd_NA proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_Cmd_NA
	call PrintMsg
ENDIF
	mov AX, [BX+DEVREQ_STATUS]	; get current status value
	or  AX, STATUS_ERROR		; set error flag
	mov AL, ERROR_UNKNOWNCMD	; set error to unknown cmd
	mov [BX+DEVREQ_STATUS], AX	; set returned status value
	retn
Cmd_NA endp


Cmd_GeneralError proc near
	mov AX, [BX+DEVREQ_STATUS]	; get current status value
	or  AX, STATUS_ERROR		; set error flag
	mov AL, ERROR_GENERALFAILURE	; set error to general failure
	mov [BX+DEVREQ_STATUS], AX	; set returned status value
	retn
Cmd_GeneralError endp


; Unit specified is invalid, return error
Cmd_BADUNIT proc near
	mov AX, [BX+DEVREQ_STATUS]	; get current status value
	or  AX, STATUS_ERROR		; set error flag
	mov AL, ERROR_UNKNOWNUNIT	; set error to unknown/invalid unit
	mov [BX+DEVREQ_STATUS], AX	; set returned status value
	retn
Cmd_BADUNIT endp


; Unit specified is invalid, return error
Cmd_NotReady proc near
	mov AX, [BX+DEVREQ_STATUS]	; get current status value
	or  AX, STATUS_ERROR		; set error flag
	mov AL, ERROR_DEVICENOTREADY	; set error to unknown/invalid unit
	mov [BX+DEVREQ_STATUS], AX	; set returned status value
	retn
Cmd_NotReady endp

;*******************************************************************************
;*******************************************************************************

; Perform programmed I/O with IDE (ATA/ATAPI) device

; given which device register to use in DX and which device to access in [unitReq]
; sets DX to actual port # to use, no other registers modified
get_pio_port proc near
	push AX					; save registers for restoration at end of procedure
	push BX

	; determine if register requested is in base or status (base+0x200) register set
	cmp  DX, 7					; register 8 & 9 map to 6 & 7 of status register set
	jbe  @@addbaseIO				; if 0-7 then skip ahead
	add  DX, 200h - 2h			; i.e. register I/O address == base + 0x200 + (DX - 2)
	@@addbaseIO:
	; AX = pio_reg_addrs_base[lun_map_addrs[unitReq]] == base I/O address
	mov  BL, CS:[unitReq]			; get lun of device requested
	xor  BH, BH					; expand into BX
	mov  AL, CS:lun_map_addrs[BX]		; index into our map to determine index of base I/O address
	cbw						; expand into AX
	mov  BX, AX
	shl  BX, 1					; multiply by 2 to adjust index for word array
	mov  AX, CS:pio_reg_addrs_base[BX]	; actually get base I/O address
	add  DX, AX

	pop  BX					; restore the ones we modified, except DX of course
	pop  AX
	retn						; don't forget me!  return to caller :-)
get_pio_port endp

; input a byte from given register in ATA register set
; DX=which device register to use, unitReq is which device to access
; returns with AL=data byte inputted, all other registers unchanged
pio_inbyte proc near
	push DX					; store it for restoration after call
	call get_pio_port				; convert DX to actual port #
	in  AL, DX					; get data byte (AL) from device on I/O port (DX)
	pop  DX					; restore DX to device register & not true port

IFDEF DDEBUG
push dx
push ax
cmp dx, 8
je @@noprint
mov al, 'p'
call PrintChar
mov al, dl
call PrintNumber
mov al, '='
call PrintChar
pop ax
push ax
call PrintNumber
mov al, ' '
call PrintChar
@@noprint:
pop  ax
pop  dx
ENDIF

	retn
pio_inbyte endp

; sets DX to device register, returns with AL byte inputted
call_pio_inbyte MACRO reg_ndx
	; AL = pio_inbyte( reg_ndx );
	mov  DX, reg_ndx
	call pio_inbyte
ENDM call_pio_inbyte


; output a byte to given register in ATA register set
; AL=data to output, DX=which device register to use, unitReq is which device to access
; all other registers unchanged
pio_outbyte proc near
	push DX					; save it
	call get_pio_port				; convert DX to actual port #
	out  DX, AL					; send data byte (AL) to device on I/O port (DX)
	pop  DX					; and restore it

IFDEF DDEBUG
push dx
push ax
mov al, 'o'
call PrintChar
mov al, dl
call PrintNumber
mov al, ':'
call PrintChar
pop ax
push ax
call PrintNumber
mov al, ' '
call PrintChar
pop  ax
pop  dx
ENDIF

	retn
pio_outbyte endp

; sets DX to device register and AL to byte to output
call_pio_outbyte MACRO reg_ndx, data
	; pio_outbyte( reg_ndx, data );
	push AX
	mov  DX, reg_ndx
	mov  AL, data
	call pio_outbyte
	pop  AX
ENDM call_pio_outbyte


;// This macro provides a small delay that is used in several
;// places in the ATA command protocols:
;// 1) It is recommended that the host delay 400ns after
;//    writing the command register.
;// 2) ATA-4 has added a new requirement that the host delay
;//    400ns if the DEV bit in the Device/Head register is
;//    changed.  This was not recommended or required in ATA-1,
;//    ATA-2 or ATA-3.  This is the easy way to do that since it
;//    works in all PIO modes.
;// 3) ATA-4 has added another new requirement that the host delay
;//    after the last word of a data transfer before checking the
;//    status register.  This was not recommended or required in
;//    ATA-1, ATA-2 or ATA-3.  This is the easy to do that since it
;//    works in all PIO modes.
; assumes [unitReq] refers to a valid device, which is what delay based upon
; no registers modified
DELAY400NS MACRO
	push AX
	push DX
	REPT 4
		call_pio_inbyte CB_ASTAT;
	ENDM
	pop  DX
	pop  AX
ENDM DELAY400NS


; return BIOS time in DX:AX, no other registers modified
getBIOStime proc near
	push ES				; save other registers
	push BX

	mov  BX, 40h			; BIOS timer value, a DD at 0040:006C
	mov  ES, BX
	mov  BX, 6Ch

	pushf					; disable interrupts
	cli

	mov  AX, word ptr ES:[BX]	; get low word into AX
	add  BX, 2				; point to high word
	mov  DX, word ptr ES:[BX]	; get high word into DX

	popf					; reenable interrupts if enabled before calling us

	pop  BX				; and restore them
	pop  ES

	retn
getBIOStime endp


; sets a timeout value, number of timer ticks relative to current BIOS time (timer ticks)
; later a call to check_BIOS_timeout can be used to see if its expired
; only a single timeout value is maintained, so if called again then all
; calls to check_BIOS_timeout will refer to new timeout value!
; NOTE: the single timeout maintained below is meant for use within a single
;       device request call, as the next call may refer to a different device
; input AX is number of timer ticks before timeout expires
; no registers modified, updates [timeout] with new expiration count
timeout DW 2 dup (0)
set_BIOS_timeout proc near
	push DX				; save modified registers
	push BX
	push AX

	mov  BX, AX				; store timeout count
	call getBIOStime			; get BIOS timer value DD into DX:AX
	add  AX, BX				; wait at least 2 timer ticks
	jnc  @@nocarry			; handle carry in addition
	inc  DX
	@@nocarry:				; now DX:AX has timeout value

	; TODO check crossing over midnight case!!!

	mov  CS:[timeout+2], DX		; store timeout count DX:AX into [timeout]
	mov  CS:[timeout], AX	

	pop  AX				; restore registers
	pop  BX
	pop  DX
	retn
set_BIOS_timeout endp

; determines if timeout has expired, see set_BIOS_timeout
; no registers modified, sets carry if timeout expired, carry cleared otherwise
check_BIOS_timeout proc near
	push DX					; save modified registers
	push BX
	push AX

	call getBIOStime				; get current time

	cmp  DX, word ptr CS:[timeout+2]	; see if its passed our timeout, high word 1st
	jb   @@notyet				; high word of current time still less than timeout
	ja   @@timeoutexpired			; if high word is greater, assume timeout passed
	cmp  AX, word ptr CS:[timeout]	; now check low word (least significant portion)
	jb   @@notyet				; jmp if current time still < set timer value

	; set carry flag here, remember cmp will alter it!!!
	@@timeoutexpired:
	DDEBUG_PrintChar 'x'
	stc						; mark timeout expired
	jmp  @@done

	@@notyet:
	DDEBUG_PrintChar 'o'
	clc						; mark timeout not expired yet

	@@done:
	pop  AX					; restore them
	pop  BX
	pop  DX
	retn
check_BIOS_timeout endp

; switch timeout with media_changed_timeout so set & check routines can be used
swap_timeouts proc near
	push BX
	xor  BH, BH						; load index into media timeout array
	mov  BL, CS:[unitReq]
	shl  BX, 2						; multiply by 4 (sizeof DD == sizeof DW 2 dup ?)
	xchg AX, CS:[timeout]				; switch standard timeout with array's timeout
	xchg DX, CS:[timeout+2]
	xchg AX, CS:[BX+media_changed_timeout]
	xchg DX, CS:[BX+media_changed_timeout+2]
	xchg AX, CS:[timeout]
	xchg DX, CS:[timeout+2]
	pop  BX
	retn
swap_timeouts endp

; set timeout value for how long media is considered unchanged
; for devices that don't indicate if media changed, we call
; this whenever LBA sector 10h is read to set the media unchanged time period
; NOTE: since this value is intended to be used across device request calls
;       (i.e. any future calls before timeout expires return media unchanged)
;       we must store the timeout per lun, otherwise access to one drive
;       will cause false results for another drive
set_media_timeout proc near
	push AX
	call swap_timeouts		; switch our timeout with appropriate media timeout
	mov  AX, 2*18			; # sec * 18ticks/sec
	call set_BIOS_timeout		; use basic set timeout to calc our media timeout
	call swap_timeouts		; restore (switch back) the two timeouts
	pop  AX
	retn
set_media_timeout endp

; determines if we still consider media unchanged, carry set if we consider changed
check_media_timeout proc near
	call swap_timeouts		; switch our timeout value with appropriate device's
	call check_BIOS_timeout		; media time out value and then call basic check timeout
	pushf					; save carry flag
	call swap_timeouts		; restore (switch back) the two timeouts
	popf					; and restore it
	retn
check_media_timeout endp


; delay for at least 2 timer ticks, ~110ms == ~1/9 second (2 ticks / 18.2 ticks per second)
; we dont use set_BIOS_timeout & check_BIOS_timeout so can be intermixed with atapi_delay calls
; no registers changed
atapi_delay proc near
	push DX				; save modified registers
	push CX
	push BX
	push AX

	call getBIOStime			; get BIOS timer value DD into DX:AX
	add  AX, 2				; wait at least 2 timer ticks
	jnc  @@nocarry			; handle carry in addition
	inc  DX
	@@nocarry:				; now DX:AX has timeout value
	; TODO check crossing over midnight case!!!

	mov  CX, DX				; store in CX:BX
	mov  BX, AX

	@@delayloop:
	call getBIOStime			; get current time
	cmp  DX, CX				; see if its passed our timeout, high word 1st
	jb   @@delayloop
	ja   @@delaydone			; if high word is greater, assume timeout passed
	cmp  AX, BX				; now check low word (least significant portion)
	jb   @@delayloop			; keep looping until current time > set timer value
	@@delaydone:

	pop  AX				; restore them
	pop  BX
	pop  CX
	pop  DX
	retn
atapi_delay endp


; wait for an interrupt/error or poll til not busy/error  (error == timeout)
; only modifies AL
; on entry BH contains error code for interrupt error and BL error code for poll error
; and time-out value should already be set via set_BIOS_timeout
; on return AL is 0 for all's ok, otherwise
; if a interrupt error/timeout occurred, AL is set to BH
; if an timeout/error occurred during polling, AL is set to BL
reg_wait_poll proc near
	; if (interruptErr && use interrupts)
	; TODO do that loop when we add interrupt support!

	@@loop_wait_not_busy:
	call_pio_inbyte CB_ASTAT			; get status, check for not busy
	test AL, CB_STAT_BSY
	jz   @@done_ok

	call check_BIOS_timeout				; if timeout, set error code
	jnc  @@loop_wait_not_busy

	mov  AL, BL						; set error
	jmp  @@done

	@@done_ok:
	mov  AL, 0						; indicate no error

	@@done:
	ret
reg_wait_poll endp

call_reg_wait_poll MACRO timeoutErr, pollErr
	push BX
	mov  BH, timeoutErr
	mov  BL, pollErr
	call reg_wait_poll
	pop  BX
ENDM call_reg_wait_poll


; sets AL to value for master or slave, depending on what unitReq is
; i.e. on return only AL is modified and set to one of CB_DH_DEV0 or CB_DH_DEV1
GetDeviceFlag proc near
	push BX					; save all registers other than AL

	; get device # in AL
	mov  BL, CS:[unitReq]			; get lun of device requested
	xor  BH, BH					; expand into BX
	mov  AL, CS:lun_map_dev[BX]		; index into our map to determine device #

	pop  BX					; restore them

	; dev ? CB_DH_DEV1 : CB_DH_DEV0
	cmp  AL, FLG_SLAVE
	je   @@slave

	;@@master:
	mov  AL, CB_DH_DEV0
	retn

	@@slave:
	mov  AL, CB_DH_DEV1
	retn
GetDeviceFlag endp


; selects device (0 or 1 -- master or slave)
; no registers modified
; Waits for not BUSY, selects drive, then waits for READY and SEEK COMPLETE status.
; TODO: implement waits, for now do basic selections
SelectDevice proc near
	push AX
	push DX

	; set AL to CB_DH_DEV# where # is 0 or 1 (master or slave)
	call GetDeviceFlag

	; issue device device select request
	@@sdr:
	call_pio_outbyte CB_DH, AL
      DELAY400NS;

	pop  DX
	pop  AX
	ret
SelectDevice endp


; Sends Packet command to device (unitReq), 
; then gets (or sends) data for (from) buffer
; AH is undefined on return
; carry set on error with AL == error code
; if no error then AL == 0
; all other registers preserved
PerformATAPIPacketCmd proc near
	push BX
	push CX
	push DX
	push DS
	push ES
	push SI
	push DI

	DDEBUG_PrintChar 'P'
	; initialize timeout counter
	mov  AX, 20*18				; default 20 seconds * 18 ticks/second
	call set_BIOS_timeout			; read BIOS 

	; force command packet size to 12 or 16,  (should we eventually extend with 0 padding?)
	cmp  CS:[packetsize], 12
	jbe  @@lbl_pkt12

	;@@lbl_pkt16:
	mov  CS:[packetsize], 16		; force 16 byte size command packet
	jmp  @@selectdev

	@@lbl_pkt12:
	mov  CS:[packetsize], 12		; force 12 byte size command packet

	@@selectdev:				; indicate if command for master or slave
	call SelectDevice				; uses unitReq and issues device select call
	DDEBUG_PrintChar 'a'

	@@setupregs:				; send data to all registers except command regiser
	call_pio_outbyte CB_DC, CB_DC_NIEN	; change to 0 if we add support for interrupts

	; below varies depending on if communicating in LBA 28, LBA 48 mode, or ATA CHS/ATAPI LBA32 mode
	; but since we are an ATAPI device we of course only support ATA CHS/ATAPI LBA32 mode
	call_pio_outbyte CB_FR, 0				; if support DMA OR with 0x01  (feature register)
	call_pio_outbyte CB_SC, 0				; sector count, tag # for command queuing when supported, 0-31 only
	call_pio_outbyte CB_SN, 0				; sector number, not applicable
	mov  AX, 0FFFFh						; set cyl value to max transmit size per PIO DRQ transfer (==0xFFFE)
	call_pio_outbyte CB_CH, AH				; i.e. max value transfered per rep insw/outsw request
	call_pio_outbyte CB_CL, AL				; must be even if < data count, odd ok if >= data count
	call GetDeviceFlag					; AL = CB_DH_DEV#
	call_pio_outbyte CB_DH, AL				; CB_DH_DEV# | ( reg_atapi_reg_dh & 0x0f /* i.e. only low bits */ )

	; if support interrupt mode, then
	; Take over INT 7x and initialize interrupt controller and reset interrupt flag.
	; call int_save_int_vect

	DDEBUG_PrintChar 'c'
	; Start the command by setting the Command register.  The drive
	; should immediately set BUSY status.
	call_pio_outbyte CB_CMD, CMD_PACKET

	; Waste some time by reading the alternate status a few times.
	; This gives the drive time to set BUSY in the status register on
	; really fast systems.  If we don't do this, a slow drive on a fast
	; system may not set BUSY fast enough and we would think it had
	; completed the command when it really had not even started the
	; command yet.

	DELAY400NS;

	DDEBUG_PrintChar 'k'
	; Command packet transfer...
	; Check for protocol failures,
	; the device should have BSY=1 or
	; if BSY=0 then either DRQ=1 or CHK=1.
	call atapi_delay
	call_pio_inbyte CB_ASTAT
	test AL, CB_STAT_BSY
	jnz  @@next1				; if busy is set (BSY==1) then all's ok
	test AL, CB_STAT_DRQ OR CB_STAT_ERR
	jnz  @@next1				; if not busy but DRQ or ERR set then all's ok

	; some sort of failure
	; reg_cmd_info.failbits |= FAILBIT0;  // not OK
	DEBUG_PrintChar '#'
	DEBUG_PrintChar '0'


	@@next1:
	; Command packet transfer...
	; Poll Alternate Status for BSY=0.
	call_pio_inbyte CB_ASTAT		; poll for not busy
	test AL, CB_STAT_BSY
	jz   @@next2
	call check_BIOS_timeout			; carry set if our timer expired
	jc   @@timeout1
	jmp  @@next1

	@@timeout1:
	; reg_cmd_info.to = 1;
	DEBUG_PrintChar 't'
	DEBUG_PrintChar '1'
	mov  AL, 51					; set error code
	mov  CS:[datadir], APC_DONE		; indicate command done
	jmp  @@done

	@@next2:  ; Command packet transfer...
	; Check for protocol failures... no interrupt here please!
	; Clear any interrupt the command packet transfer may have caused.

	; if ( int_intr_flag )
	;   reg_cmd_info.failbits |= FAILBIT1;
	; int_intr_flag = 0;


	DDEBUG_PrintChar 'e'
	@@next3:  ; Command packet transfer...
	; If no error, transfer the command packet.

	; Read the primary status register and the other ATAPI registers.
	call_pio_inbyte CB_STAT
	mov  BL, AL					; status
	call_pio_inbyte CB_SC
	mov  BH, AL					; reason
	call_pio_inbyte CB_CL
	mov  CL, AL					; lowCyl
	call_pio_inbyte CB_CH
	mov  CH, AL					; highCyl

	; check status: must have BSY=0, DRQ=1 now
	and  BL, CB_STAT_BSY OR CB_STAT_DRQ OR CB_STAT_ERR
	test BL, CB_STAT_DRQ
	jnz  @@next4

	DEBUG_PrintChar 'e'
	DEBUG_PrintNumber 52
	mov  AL, 52					; set error code
	mov  CS:[datadir], APC_DONE		; indicate command done
	jmp  @@done

	@@next4:  ; Command packet transfer...
	DDEBUG_PrintChar 't'
	; Check for protocol failures...
	; check: C/nD=1, IO=0.
	test BH, CB_SC_P_TAG OR CB_SC_P_REL OR CB_SC_P_IO
	jnz   @@next4_fail1
	test BH, CB_SC_P_CD
	jnz  @@next4a

	@@next4_fail1:
	; reg_cmd_info.failbits |= FAILBIT2;
	DEBUG_PrintChar '#'
	DEBUG_PrintChar '2'

	@@next4a:
	cmp  CX, 0FFFFh				; are low & high cyl same as value we inputted, ~min(data buffer size, 0xffff)
	je   @@next4b

	@@next4_fail2:
	; reg_cmd_info.failbits |= FAILBIT3;
	DEBUG_PrintChar '#'
	DEBUG_PrintChar '3'
	DEBUG_PrintNumber ch
	DEBUG_PrintNumber cl

	@@next4b:
	DDEBUG_PrintChar '-'
	; xfer the command packet (the cdb)
	; pio_drq_block_out( CB_DATA, cpseg, cpoff, cpbc >> 1 );
	mov  DX, CB_DATA				; get I/O address of data register
	call get_pio_port
	xor  CX, CX
	mov  CL, CS:[packetsize]		; CX is the buffer count, in _words_
	shr  CX, 1
	push CS					; DS:SI is the address of the buffer
	pop  DS
	mov  SI, OFFSET CS:packet
	; cld						; direction flag should already be set
.186	; REQUIRED for outsw, for 8086 compatible driver replace with outsb logic
	rep  outsw					; actually transfer the data, a word at a time
.8086	; RETURN to 8086 compatible mode

	DELAY400NS;    				; delay so device can get the status updated


	@@next5:  ; Data transfer loop...
	DDEBUG_PrintChar '-'
	; If there is no error, enter the data transfer loop.
	; First adjust the I/O buffer address so we are able to
	; transfer large amounts of data (more than 64K).

	mov  AX, CS:[packetbufoff]		; get segment:offset of data buffer into DS:SI and normalize it
	shr  AX, 4					; drop lower 4 bits
	add  AX, CS:[packetbufseg]		; adjust segment value
	mov  DS, AX					; and place in DS
	mov  SI, CS:[packetbufoff]		; load offset
	and  SI, 0Fh				; use only the lower 4 bits (upper bits part of segment)

	DDEBUG_PrintChar 'D'
	DDEBUG_PrintChar 'A'
	DDEBUG_PrintChar 'T'
	DDEBUG_PrintChar 'A'
	DDEBUG_PrintChar ' '

	@@transferdata_looptop:			; loop while no errors & data to send

	DDEBUG_PrintChar 'P'
	; Wait for INT 7x -or- wait for not BUSY -or- wait for time out.
	call atapi_delay
	call_reg_wait_poll 53, 54

	; If there was a time out error, exit the data transfer loop.
	cmp  AL, 0					; if ( reg_cmd_info.ec )
	jz   @@tdl_1
	
	mov  CS:[datadir], APC_DONE		; indicate command done
	jmp  @@done

	@@tdl_1:


	DDEBUG_PrintChar 'a'
	; Read the primary status register and the other ATAPI registers.
	call_pio_inbyte CB_STAT
	mov  BL, AL					; status
	call_pio_inbyte CB_SC
	mov  BH, AL					; reason
	call_pio_inbyte CB_CL
	mov  CL, AL					; lowCyl
	call_pio_inbyte CB_CH
	mov  CH, AL					; highCyl


	; Exit the read data loop if the device indicates this is the end of the command.
	test BL, CB_STAT_BSY OR CB_STAT_DRQ
	jnz  @@tdl_2

	mov  CS:[datadir], APC_DONE		; indicate command done
	jmp  @@transferdata_loopend

	@@tdl_2:


	DDEBUG_PrintChar 'c'
	; The device must want to transfer data...
	; check status: must have BSY=0, DRQ=1 now.
	and  BL, CB_STAT_BSY OR CB_STAT_DRQ
	cmp  BL, CB_STAT_DRQ
	je  @@tdl_3

	DEBUG_PrintChar 'e'
	DEBUG_PrintNumber 55
	mov  AL, 55					; set error code
	mov  CS:[datadir], APC_DONE		; indicate command done
	jmp  @@done

	@@tdl_3:
	DDEBUG_PrintChar 'k'
	; Check for protocol failures...
	; check: C/nD=0, IO=1 (read) or IO=0 (write).
;*** TODO ***
;         if ( ( reason &  ( CB_SC_P_TAG | CB_SC_P_REL ) )
;              || ( reason &  CB_SC_P_CD )
;            )
;            reg_cmd_info.failbits |= FAILBIT4;
	@@tdl_4:
;         if ( ( reason & CB_SC_P_IO ) && dir )
;            reg_cmd_info.failbits |= FAILBIT5;
	@@tdl_5:


	; do the slow data transfer thing
;      if ( reg_slow_xfer_flag )
;      {
;         slowXferCntr ++ ;
;         if ( slowXferCntr <= reg_slow_xfer_flag )
;         {
;            sub_xfer_delay();
;            reg_slow_xfer_flag = 0;
;         }
;      }
	DDEBUG_PrintChar 'e'
	@@tdl_6:


	; get the byte count, check for zero...
	cmp  CX, 1						; if ( ((highCyl << 8)|lowCyl) < 1 )
	jge   @@tdl_7

	DEBUG_PrintChar 'e'
	DEBUG_PrintNumber 59
	mov  AL, 59					; set error code
	mov  CS:[datadir], APC_DONE		; indicate command done
	jmp  @@done

	@@tdl_7:

	DDEBUG_PrintChar 't'
	; and check protocol failures...
;      if ( byteCnt > dpbc )
;         reg_cmd_info.failbits |= FAILBIT6;
	@@tdl_8:
;      reg_cmd_info.failbits |= prevFailBit7;
;      prevFailBit7 = 0;
;      if ( byteCnt & 0x0001 )
;         prevFailBit7 = FAILBIT7;
	@@tdl_9:


	; quit if buffer overrun.
;*** TODO ***
;      if ( ( reg_cmd_info.totalBytesXfer + byteCnt ) > reg_buffer_size )
;      {
	jmp  @@tdl_10
	DEBUG_PrintChar 'e'
	DEBUG_PrintNumber 61
	mov  AL, 61					; set error code
	mov  CS:[datadir], APC_DONE		; indicate command done
	jmp  @@done
;      }
	@@tdl_10:


	; increment number of DRQ packets
;      reg_cmd_info.drqPackets ++ ;


	; transfer the data and update the i/o buffer address
	; and the number of bytes transfered.
	DDEBUG_PrintChar 'c'
	DDEBUG_PrintNumber ch
	DDEBUG_PrintNumber cl
	DDEBUG_PrintChar ' '
	push CX					; save byte count
	mov  DX, CX					; wordCnt = ( byteCnt >> 1 ) + ( byteCnt & 0x0001 );
	and  DX, 01h
	shr  CX, 1
	add  CX, DX
      
;      reg_cmd_info.totalBytesXfer += ( wordCnt << 1 );

	; do actual transfer
	; CX is the word count and DS:SI is the address of buffer with data to transfer
	; cld						; direction flag should already be set
	mov  DX, CB_DATA				; get I/O address of data register
	call get_pio_port

	DDEBUG_PrintChar ' '
	mov  AL, CS:[datadir]			; do input or output based on direction indicated
	cmp  AL, APC_INPUT			; or do nothing on other values (e.g. APC_DONE)
	je   @@do_pio_drq_block_in
	cmp  AL, APC_OUTPUT
	je   @@do_pio_drq_block_out
	jmp  @@updatecount			; important, make sure we pop cx

	; The maximum ATA DRQ block is 65536 bytes or 32768 words.
	; The maximun ATAPI DRQ block is 131072 bytes or 65536 words.
	; REP INSW/REP OUTSW will fail if wordCnt > 65535,
	; so the transfer should be split in such cases
	; however, since our byte count is limited to CX, our word count is always <= 65535

	@@do_pio_drq_block_out:
	; pio_drq_block_out( CB_DATA, dpseg, dpoff, wordCnt );
	push SI
.186	; REQUIRED for outsw, for 8086 compatible driver replace with outsb logic
	rep  outsw					; actually transfer the data, a word at a time
.8086	; RETURN to 8086 compatible mode
	pop  SI
	jmp @@updatecount

	@@do_pio_drq_block_in:
	; pio_drq_block_in( CB_DATA, dpseg, dpoff, wordCnt );
	mov  DI, SI
	push DS					; mov ES, DS
	pop  ES
.186	; REQUIRED for outsw, for 8086 compatible driver replace with outsb logic
	rep  insw					; actually transfer the data, a word at a time
.8086	; RETURN to 8086 compatible mode
	;jmp @@updatecount


	; dpaddr = dpaddr + byteCnt;
	@@updatecount:
	pop  CX					; restore byte count
	add  SI, CX					; add byte count to offset
	mov  AX, SI					; normalize segment:offset
	shr  AX, 4					; adjust segment
	mov  DX, DS
	add  AX, DX
	mov  DS, AX
	and  SI, 0Fh				; adjust offset

      DELAY400NS;    // delay so device can get the status updated

	jmp  @@transferdata_looptop
	@@transferdata_loopend:


	; End of command...
	; Wait for interrupt or poll for BSY=0,
	; but don't do this if there was any error or if this
	; was a commmand that did not transfer data.
IFDEF 0	; comment out as test should always be true
	cmp  CS:[datadir], APC_DONE
	je  @@finalchk

	call atapi_delay
	call_reg_wait_poll 56, 57

	cmp  AL, 0
	jnz  @@done
ENDIF

	; Final status check, only if no previous error.
	@@finalchk:

	; Read the primary status register and the other ATAPI registers.
	call_pio_inbyte CB_STAT
	mov  BL, AL					; status
	call_pio_inbyte CB_SC
	mov  BH, AL					; reason
	call_pio_inbyte CB_CL
	mov  CL, AL					; lowCyl
	call_pio_inbyte CB_CH
	mov  CH, AL					; highCyl

	; check for any error.
	test BL, CB_STAT_BSY OR CB_STAT_DRQ OR CB_STAT_ERR
	jz   @@finalchk_protocol

IFDEF DEBUG
	DEBUG_PrintChar 'e'
	DEBUG_PrintNumber 58
	DEBUG_PrintChar ':'
	DEBUG_PrintNumber bl
	test BL, CB_STAT_BSY
	jz @@1
	DEBUG_PrintChar 'B'
	@@1:
	test BL, CB_STAT_DRQ
	jz @@2
	DEBUG_PrintChar 'D'
	@@2:
	test BL, CB_STAT_ERR
	jz @@3
	DEBUG_PrintChar 'E'
	@@3:
	call_pio_inbyte CB_ERR	; see what error is
	DEBUG_PrintChar 'v'
	DEBUG_PrintNumber AL
ENDIF
	mov  AL, 58			; most often means seems to indicate device not ready yet
	;mov AL, 0			; force success
	jmp  @@done

	@@finalchk_protocol:
	; Check for protocol failures...
	; check: C/nD=1, IO=1.
	test BH, CB_SC_P_TAG OR CB_SC_P_REL
	jnz  @@fail_finalchk_protocol
	test BH, CB_SC_P_IO
	jz   @@fail_finalchk_protocol
	test BH, CB_SC_P_CD
	jnz  @@end_finalchk_protocol
	
	@@fail_finalchk_protocol:
	; reg_cmd_info.failbits |= FAILBIT8;
	DEBUG_PrintChar '#'
	DEBUG_PrintChar '8'

	@@end_finalchk_protocol:
	; indicate no errors (though may have failed some checks)
	mov  AL, 0

	; at this point, AL == error code, if AL is NOT 0 then set carry and return
	@@done:

	; For interrupt mode, restore the INT 7x vector.
	; int_restore_int_vect();

	DEBUG_PrintChar '{'
	DEBUG_PrintNumber al
	DEBUG_PrintChar '}'

	pop  DI
	pop  SI
	pop  ES
	pop  DS
	pop  DX
	pop  CX
	pop  BX

	; set return status and error (carry) flag
	cmp  AL, 0
	jnz   @@failure
	clc						; carry clear unless error occurred
	retn
	@@failure:
	stc						; error occurred
	retn
PerformATAPIPacketCmd endp


; clears the packet and sets packet size
; input is CX with packetsize (12 or 16 only)
; no other registers modified, on output
; sets CS:[packetsize] to CX and CS:[packet] through CS:[packet+CX] to zero (0)
; also sets CS:[datadir] to APC_DONE (i.e. no data transfer) and clears packet data buffer pointer (seg:off)
; meant to be called to initialize packet, then set just specific parts or when a zero packet is required.
clearPacket proc near
	push BX

	mov  CS:[packetsize], CL						; indicate packet length is old 12/16 byte kind

	shr  CX, 1									; convert packet size into word count
	mov  BX, OFFSET CS:packet
	@@looptop:
	mov  word ptr CS:[BX], 0
	inc  BX
	inc  BX
	loop @@looptop

	mov  CS:[datadir], APC_DONE						; indicate pkt cmd transfers no data
	mov  CS:[packetbufseg], 0						; set buffer to 0x0000:0x000
	mov  CS:[packetbufoff], 0

	pop  BX
	retn
clearPacket endp

; performs an initPacket, all registers preserved
call_clearPacket MACRO pktSize
	push CX
	mov  CX, pktSize
	call clearPacket
	pop  CX
ENDM call_clearPacket


; sets 1st N words of our working buffer to 0
; no registers modified except CX, which is count of words to clear on input
clearBuffer proc near
	push BX

	mov  BX, OFFSET CS:buffer
	@@looptop:
	mov  word ptr CS:[BX], 0
	inc  BX
	inc  BX
	loop @@looptop

	pop  BX
	retn
clearBuffer endp

call_clearBuffer MACRO N
	push CX
	mov  CX, N
	call clearBuffer
	pop  CX
ENDM call_clearBuffer
	

; Command to test for unit ready
; on exit AL is set to 0 for ready or nonzero error value
; and carry is either cleared (ready) or set (not ready)
testUnitReady proc near
	push CX
	push BX

	; issue AC_TESTUNITREADY (0x00) command, packet is all zeros
	call_clearPacket 12
	call PerformATAPIPacketCmd	; handles sending packet to device and reading returned data into buffer

	pop  BX
	pop  CX
	retn
testUnitReady endp


; Command to determine status (drive open/closed, media found, ...)
; only input is the [unitReq] refers to valid drive
; if any error or this packet command unsupported returns with
; carry set and AX==STATUS_MEDIA_UNKNOWN==-1
; on success returns with carry clear
; AH = media status byte, bit 0=tray open(1)/closed(0), bit 1=media present yes(1)/no(0), bits 2-7 reserved
; AL is either STATUS_MEDIA_NOCHANGE (same media as last call) or STATUS_MEDIA_CHANGED
getMediaStatus proc near
	call_clearPacket 12					; initialize ATAPI command packet
	call_clearBuffer 4					; set our working buffer to zero [only portion used, in words]

	mov  CS:[packet], AC_GETEVENTSTATUSNOTIFY		; get device event/status notification
	mov  CS:[packet+1], 01h					; no lun, reserved, imm=1 (poll mode, maximize supported devices)
									; bytes 2-3 reserved
	mov  CS:[packet+4], 10h					; set notification class to media
	mov  AX, 8							; bytes 5-6 reserved
	mov  CS:[packet+7], AH					; max notification bytes to get, MSB
	mov  CS:[packet+8], AL					; recommended at >= 8 (so event cleared on all drives), LSB
									; bytes 9-12 misc (vendor, reserved, ...) and padding
	mov  CS:[datadir], APC_INPUT				; indicate pkt cmd inputs data
	mov  AX, CS
	mov  CS:[packetbufseg], AX				; set buffer to our working buffer
	mov  CS:[packetbufoff], OFFSET CS:buffer
	call PerformATAPIPacketCmd	; handles sending packet to device and reading returned data into buffer
	jc   @@assumeNotSupported

	test CS:[buffer+2], STATUS_NEA			; see if No Event Available indicates if media status supported
	jnz  @@assumeNotSupported

	mov  AH, CS:[buffer]					; see if we got all the data we wanted, value stored BIG Endian
	mov  AL, CS:[buffer+1]					; note the value is number of bytes following this field, so
	cmp  AX, 6							; subtract 2 from expected value including header
	jl   @@assumeNotSupported

	mov  AL, CS:[buffer+2]					; we should only get media status event, but check to be sure
	and  AL, STATUS_CLASS					; mask the notification class event
	cmp  AL, STATUS_MEDIA					; see if was media status event
	jne  @@assumeNotSupported
									; CS:[buffer+3] indicates supported event classes
	; here we assume we actually got media status information
	; so return the information in expected format
	mov  AH, CS:[buffer+5]					; set AH to media status byte, bits 2-7 reserved, 1=media, 0=tray
	mov  AL, CS:[buffer+4]					; lower 4 bits indicate media event
	and  AL, 0Fh
	jz   @@notChanged						; if AL&0x0F == 0 then no change

	mov  AL, STATUS_MEDIA_CHANGED				; assume changed for remaining values (eject request,
	clc								; new media, media removal, media change, & reserved)
	jmp  @@done

	@@notChanged:
	mov  AL, STATUS_MEDIA_NOCHANGE			; same media still there!
	clc
	jmp  @@done

	@@assumeNotSupported:
	; indicate we failed/status unknown
	mov  AX, STATUS_MEDIA_UNKNOWN
	stc

	@@done:
	retn
getMediaStatus endp


; issues IDENTIFY DEVICE command and fills in buffer accordingly
identifyDevice proc near
	call_clearBuffer 128					; set our working buffer to zero [only portion used, in words]
	retn
identifyDevice endp


;*******************************************************************************
;*******************************************************************************

; Command to flush input - should free all buffers & clear any pending requests
; Currently we have nothing to free/clear so simply return
; TODO: add once we support prefetching or other buffering
Cmd_InputFlush proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_IOCTLCmd_InputFlush
	call PrintMsg
ENDIF
	retn
Cmd_InputFlush endp


;*******************************************************************************

; Command to indicate caller is using this driver - does not have to do anything
Cmd_DevOpen proc near
	inc  word ptr CS:[devAccess]	; increment count of those accessing
	retn
Cmd_DevOpen endp


;*******************************************************************************

; Command to indicate caller is no longer using this driver - may do nothing
Cmd_DevClose proc near
	dec  word ptr CS:[devAccess]	; decrement count of those accessing
	retn
Cmd_DevClose endp


;*******************************************************************************
;*******************************************************************************

; jump table for IOCTL input's command
IOCTLI_jumpTable:
	DW	CmdI_GetDevHdr	; 0  = return the address of the device header
	DW	CmdI_HeadLoc	; 1  = location of head
	DW	CmdI_Reserved	; 2  = reserved, return unknown command
	DW	CmdI_ErrStats	; 3  = error statistics
	DW	CmdI_AudioChannel	; 4  = audio channel information
	DW	CmdI_ReadDrvB	; 5  = read drive bytes
	DW	CmdI_DevStatus	; 6  = device status
	DW	CmdI_SectorSize	; 7  = return size of sectors
	DW	CmdI_VolumeSize	; 8  = return size of volume
	DW	CmdI_MediaChanged	; 9  = media changed
	DW	CmdI_AudioDisk	; 10 = audio disk information
	DW	CmdI_AudioTrack	; 11 = audio track information
	DW	CmdI_AudioQCh	; 12 = audio Q-Channel information
	DW	CmdI_AudioSubCh	; 13 = audio Sub-Channel information
	DW	CmdI_UPC		; 14 = UPC code
	DW	CmdI_AudioStatus	; 15 = audio status information
					; commands 16-255 are reserved and call CmdI_Reserved


; Command to perform input or get information from the device driver
; Command called with DS:BX pointing to device request and sets
; ES:DI pointing to transfer address (subcommand request information)
; DS:BX & CS must be preserved, ES:DI, SI, AX, and CX may all be altered.
Cmd_IOCTL_input proc near
	mov  SI, OFFSET IOCTLI_jumpTable			; load offset of jump table
	les  DI, [BX+DEVREQ_DATA+DEVREQR_TRANSADDR]	; load ES:DI with transfer address

DEBUG_PrintChar '@'
	mov  AL, ES:[DI]		; get subcommand code
DEBUG_PrintNumber al
	cmp  AL, 15			; see if valid (one of the 0-15 commands supported)
	ja   @@unknownCmd

	xor  AH, AH			; zero AH so can extend AL into word
	shl  AX, 1			; convert command code into index in jump table
	add  SI, AX			; add index to start of jump table
	call CS:[SI]		; perform the command
	jmp  @@done

@@unknownCmd:
	call CmdI_Reserved

@@done:

	retn
Cmd_IOCTL_input endp


;***************************************

; 0  = return the address of the device header
; ES:DI points to control block on entry
CmdI_GetDevHdr proc near
	; point (ES:DI) to return address (DD size) field of control block
	INC DI	; ADD  DI, CBLK_DEVHDRADDR

	; store device header addr at DD pointed to by ES:DI
	xor  AX, AX			; offset should be 0, i.e. mov  word ptr ES:[DI], OFFSET devHdr
	stosw				; store into ES:DI and increment DI
	mov  AX, CS			; segment should be same as CS, i.e. mov  word ptr ES:[DI+2], SEG devHdr
	stosw				; store into ES:DI

	retn
CmdI_GetDevHdr endp


;***************************************

; 1  = location of head
; TODO: implement me
CmdI_HeadLoc proc near
	; point (ES:DI) to adress mode field
	INC DI	; ADD  DI, CBLK_ADDRMODE

	; point (ES:DI) to field to store address (location) of head
	INC DI	; DI == CBLK_LOCHEAD

	; store device header addr at DD pointed to by ES:DI
	xor  AX, AX			; offset should be 0, i.e. mov  word ptr ES:[DI], OFFSET devHdr
	stosw				; store into ES:DI and increment DI
	mov  AX, CS			; segment should be same as CS, i.e. mov  word ptr ES:[DI+2], SEG devHdr
	stosw				; store into ES:DI

	retn
CmdI_HeadLoc endp


;***************************************

; 2, 16-255  = reserved, return unknown command
; only need to set error flag & error code to unknown command
CmdI_Reserved proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdI_Reserved
	call PrintMsg
ENDIF

	call Cmd_NA
	retn
CmdI_Reserved endp


;***************************************

; 3  = error statistics - the return format is undefined.
; so we can only return command unknown.  Should not cause problems.
; If format found then we can implement.
CmdI_ErrStats proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdI_ErrStats
	call PrintMsg
ENDIF

	call CmdI_Reserved
	retn
CmdI_ErrStats endp


;***************************************

; 4  = audio channel information
; TODO: implement me
CmdI_AudioChannel proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdI_AudioChannel
	call PrintMsg
ENDIF

	retn
CmdI_AudioChannel endp


;***************************************

; 5  = read drive bytes
; TODO: implement me
CmdI_ReadDrvB proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdI_ReadDrvB
	call PrintMsg
ENDIF

	retn
CmdI_ReadDrvB endp


;***************************************

; 6  = device status
; TODO: implement me
CmdI_DevStatus proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdI_DevStatus
	call PrintMsg
ENDIF

	retn
CmdI_DevStatus endp


;***************************************

; 7  = return size of sectors
; TODO: implement me
CmdI_SectorSize proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdI_SectorSize
	call PrintMsg
ENDIF

	retn
CmdI_SectorSize endp


;***************************************

; 8  = return size of volume
; TODO: implement me
CmdI_VolumeSize proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdI_VolumeSize
	call PrintMsg
ENDIF

	retn
CmdI_VolumeSize endp


;***************************************

; 9  = media changed
; TODO: if drive supports locking or other method to ensure no change, then return no change
;       for now we always report don't know, but adding real support will enhance performance
; Set media byte to one of:  0 is safe, 1 should only be returned if sure, 
; and -1 will causes CD-ROM info to be reloaded by CDEX
;   1         Media not changed
;   0         Don't know if changed
;  -1 (0FFh)  Media changed
CmdI_MediaChanged proc near
	; point (ES:DI) to media byte of control block
	INC DI	; ADD  DI, CBLK_MEDIABYTE

	; check if we want to force media has changed
	getMediaChanged				; get force counter and decrement if != 0
	cmp  AL, 0
	jz   @@nextcheck1
	mov  byte ptr ES:[DI], -1		; media has changed
DEBUG_PrintChar '<'
	jmp  @@done

	@@nextcheck1:

	; attempt to query device for status
	; query device and determine if disk change has occurred, if so report this and exit
	call getMediaStatus			; issue ATAPI media event status request
	jc   @@nextcheck2				; if error of any sort then ignore this check
	cmp  AL, STATUS_MEDIA_NOCHANGE	; media has not changed since last time we checked (made getMediaStatus call)
	je   @@nochange
	mov byte ptr ES:[DI], -1 		; device reports value that effectively means media changed
DEBUG_PrintChar '-'
	jmp  @@done
	@@nochange:
	mov byte ptr ES:[DI], 1 		; device itself reports unchanged
DEBUG_PrintChar '+'
	jmp  @@done

	@@nextcheck2:

	; check if drive is ready, any error we assume media changed (really assume drive not ready/no disc)
	call testUnitReady
	jnc  @@nextcheck3
	mov  byte ptr ES:[DI], -1
DEBUG_PrintChar '>'
	jmp  @@done

	@@nextcheck3:
	; if our media check timeout has not expired say not changed, else don't know
	call check_media_timeout
	jc   @@dontknow
	mov byte ptr ES:[DI], 1 	; guess its unchanged
DEBUG_PrintChar '='
	jmp  @@done

	@@dontknow:
	mov  byte ptr ES:[DI], 0	; indicate we don't know
DEBUG_PrintChar '?'

	@@done:
	retn
CmdI_MediaChanged endp


;***************************************

ALIGN 16
TOCbuffer DB MAX_DEVICES dup (816 dup (0))		; buffered TOC per device, 804 bytes ==
									; 4byte header + 99*8byte Track data 
									; + 8byte Lead Out data + 12 bytes padding

; returns in AX the offset of current lun's Table Of Contents buffer
getTOC proc near
	push CX
	push DX
	xor  CH, CH							; get lun into CX
	mov  CL, CS:[unitReq]
	mov  AX, 816						; size of TOC buffer itself
	mul  CX							; get appropriate one (816 * unitReq)
	add  AX, OFFSET CS:TOCbuffer				; AX = OFFSET TOCbuffer + (unitReq * 816)
	pop  DX							; ignore DX, 816*MAX_DEVICES should never > 65535
	pop  CX
	retn
getTOC endp

; no registers modified, clear TOC of current requested unit (lun)
clearTOC proc near
	push AX
	push CX

	call getTOC							; set AX to start (offset) of TOC for unitReq
	xchg AX, BX							; store BX in AX, and set BX to AX
	mov  CX, 408						; size of TOC buffer in words (816/2)

	@@looptop:							; loop CX times setting each word to zero (0)
	mov  word ptr CS:[BX], 0
	inc  BX
	inc  BX
	loop @@looptop

	xchg AX, BX							; restore BX and other registers
	pop  CX
	pop  AX
	retn
clearTOC endp

; 10 = audio disk information
CmdI_AudioDisk proc near
	push BX

IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdI_AudioDisk
	call PrintMsg
ENDIF

	call_clearPacket 12					; initialize ATAPI command packet
	call clearTOC						; clear the stored TOC for [unitReq]

	mov  CS:[packet], AC_READTOC				; read TOC, may fail during play if drive doesn't cache TOC
	mov  CS:[packet+1], 02h					; indicate MSF format (bit 1 set)
	mov  CS:[packet+2], 00h					; format 00b
	mov  CS:[packet+6], 0AAh				; starting track/session #, track must be 0-99 track or AAh leadout
	mov  CS:[packet+7], 03h					; allocation length MSB (support up to 816(0x330) bytes data)
	mov  CS:[packet+8], 30h					; allocation length LSB
	;mov  CS:[packet+9], 00h				; old format field, high two bits, now part of vendor reserved

	mov  CS:[datadir], APC_INPUT				; indicate pkt cmd inputs data
	mov  AX, CS
	mov  CS:[packetbufseg], AX				; set buffer to our working buffer
	call getTOC							; returns offset in AX of [unitReq]'s Table of Contents buffer
	mov  CS:[packetbufoff], AX


	; to simplify logic here a little, we issue the request twice, 1st we
	; get the TOC with only the lead out track (which is all the information we need for this command)
	; then we issue it again with starting track # (we still use 0 so we get all of them)
	; so our buffer contains full TOC (for use by CmdI_AudioTrack and perhaps others)

	call PerformATAPIPacketCmd	; handles sending packet to device and reading returned data into buffer
	jc   @@assumeNotSupported

	call getTOC							; BX should be TOC offset since we pushed AX/popped BX it
	mov  BX, AX
	cmp  word ptr CS:[BX], 10				; ensure we actually got data (size of data returned - 2 for cnt)
	jl   @@assumeNotSupported				; didn't get remaining 2 bytes for header + 8 bytes for lead out data
	mov  AX, word ptr CS:[BX+2]				; mov start into AL and end into AH (low addr=start, high addr=end)
	mov  byte ptr ES:[DI+CBLK_LOWTRACKNUM], AL	; set starting track #
DEBUG_PrintNumber AL
	mov  byte ptr ES:[DI+CBLK_HIGHTRACKNUM], AH	; set last track #
DEBUG_PrintNumber AH
	mov  AX, word ptr CS:[BX+4]				; MSB bytes
	xchg AH, AL							; swap for little endian order
	mov  word ptr ES:[DI+CBLK_STARTLOTRACK+2], AX	; set MSF of lead out track (MSB)
	mov  AX, word ptr CS:[BX+6]				; MSB bytes
	xchg AH, AL							; swap for little endian order
	mov  word ptr ES:[DI+CBLK_STARTLOTRACK], AX	; set MSF of lead out track (LSB)

	; load full TOC
DEBUG_PrintChar 'T'
DEBUG_PrintChar 'O'
DEBUG_PrintChar 'C'
	mov  CS:[packet+6], 00h					; starting track/session #, track must be 0-99 track or AAh leadout
	mov  CS:[datadir], APC_INPUT				; indicate pkt cmd inputs data
	call PerformATAPIPacketCmd
	jnc  @@done
	
	@@assumeNotSupported:
DEBUG_PrintChar 'a'
	mov  byte ptr ES:[DI+CBLK_LOWTRACKNUM], 0		; clear data and return error
	mov  byte ptr ES:[DI+CBLK_HIGHTRACKNUM], 0
	mov  word ptr ES:[DI+CBLK_STARTLOTRACK], 0
	mov  word ptr ES:[DI+CBLK_STARTLOTRACK+2], 0
	call Cmd_NA

	@@done:
	pop  BX
	retn
CmdI_AudioDisk endp


;***************************************

; 11 = audio track information
;CBLK_TRACKNUM	EQU 01h	; byte, track number
;CBLK_STARTTRACK	EQU 02h	; DD (MSF) of starting point of the track
;CBLK_TRACKCTRL	EQU 06h	; byte, track control information
CmdI_AudioTrack proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdI_AudioTrack
	call PrintMsg
ENDIF

	retn
CmdI_AudioTrack endp


;***************************************

; 12 = audio Q-Channel information
; TODO: implement me
CmdI_AudioQCh proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdI_AudioQCh
	call PrintMsg
ENDIF

	retn
CmdI_AudioQCh endp


;***************************************

; 13 = audio Sub-Channel information
; TODO: implement me
CmdI_AudioSubCh proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdI_AudioSubCh
	call PrintMsg
ENDIF

	retn
CmdI_AudioSubCh endp


;***************************************

; 14 = UPC code
; TODO: implement me, possibly initially returning 0
CmdI_UPC proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdI_UPC
	call PrintMsg
ENDIF

	retn
CmdI_UPC endp


;***************************************

; 15 = audio status information
; TODO: implement me
CmdI_AudioStatus proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdI_AudioStatus
	call PrintMsg
ENDIF

	retn
CmdI_AudioStatus endp


;*******************************************************************************
;*******************************************************************************

; jump table for IOCTL outputs's command
IOCTLO_jumpTable:
	DW	CmdO_EjectDisk	; 0  = eject the disk (opens the tray)
	DW	CmdO_DoorLock	; 1  = lock or unlock the door
	DW	CmdO_ResetDrive	; 2  = resets the drive and this driver
	DW	CmdO_AudioChCtrl	; 3  = audio channel control
	DW	CmdO_DirectCtrl	; 4  = allows programs to have direct control
	DW	CmdO_CloseTray	; 5  = close the tray (opposite of eject disk)
					; commands 6-255 are reserved and call CmdO_Reserved


; Command to perform output or control the cd drive
; Command called with DS:BX pointing to device request and
; ES:DI pointing to transfer address (subcommand request information)
; DS:BX must not be changed, ES:DI, SI, AX, and CX may all be changed.
Cmd_IOCTL_output proc near
	mov  SI, OFFSET IOCTLO_jumpTable			; load offset of jump table
	les  DI, [BX+DEVREQ_DATA+DEVREQR_TRANSADDR]	; load ES:DI with transfer address

DEBUG_PrintChar '&'
	mov  AL, ES:[DI]		; get subcommand code
DEBUG_PrintNumber al
	cmp  AL, 5			; see if valid (one of the 0-5 commands supported)
	ja   @@unknownCmd

	xor  AH, AH			; zero AH so can extend AL into word
	shl  AX, 1			; convert command code into index in jump table
	add  SI, AX			; add index to start of jump table
	call CS:[SI]		; perform the command
	jmp  @@done

@@unknownCmd:
	call CmdO_Reserved

@@done:

	retn
Cmd_IOCTL_output endp


;***************************************

; 6-255 = reserved, returns unknown command
; only need to set error flag & error code to unknown command
CmdO_Reserved proc near
IFDEF DEBUG
	mov DX, OFFSET DbgMsg_CmdO_Reserved
	call PrintMsg
ENDIF

	call Cmd_NA
	retn
CmdO_Reserved endp


;***************************************

; issue STARTSTOP packet command
; on input expects AX to indicate eject/close flags
; on return carry set on error (clear otherwise) and AX is error or 0 on success
startStopCmd proc near
	mov  CS:[packet], AC_STARTSTOPUNIT					; set command
	mov  CS:[packet+1], 00h							; set immediate flag [lun=0,reserved=0,immed=1/wait=0]
	mov  word ptr CS:[packet+2], 0					; reserved
	mov  word ptr CS:[packet+4], AX					; eject/load flags [power=0,res=0,LoEj=?,start=?]
	mov  CS:[packet+6], 0							; reserved, misc (vender, reserved, ...)
	mov  CS:[packet+7], 0							; remaining is padding
	mov  word ptr CS:[packet+8], 0
	mov  word ptr CS:[packet+10], 0

	mov  CS:[packetsize], 12						; indicate packet length is old 12 byte kind
	mov  CS:[datadir], APC_DONE						; indicate pkt cmd transfers no data
	mov  CS:[packetbufseg], 0						; packet data seg:off == 0:0
	mov  CS:[packetbufoff], 0
	call PerformATAPIPacketCmd	; handles sending packet to device and reading returned data into buffer
	retn
startStopCmd endp


; 0  = eject the disk (opens the tray)
; will fail if disk is currently locked!
CmdO_EjectDisk proc near
	; TODO, test our lock status, if locked immediately return with error (instead of waiting for drive to do so)
	; alternately, update our lock status depending on success or failure of command.
	; or decide based on device and us...

	mov  AX, 02h								; LoEj=1, Start=0; open tray
	call startStopCmd
	jnc   @@done								; handle errors
	call  Cmd_NotReady

	@@done:
	retn
CmdO_EjectDisk endp


; 5  = closes the tray (opposite of eject disk)
; will fail if disk is currently locked!
CmdO_CloseTray proc near
	; TODO, test our lock status, if locked immediately return with error (instead of waiting for drive to do so)
	; alternately, update our lock status depending on success or failure of command.
	; or decide based on device and us...

	mov  AX, 03h								; LoEj=1, Start=1; close tray (?and start, read TOC?)
	call startStopCmd
	jnc   @@done								; handle errors
	call  Cmd_NotReady

	@@done:
	retn
CmdO_CloseTray endp


;***************************************

; 1  = lock or unlock the door
; TODO: implement me
CmdO_DoorLock proc near
	; ??? should we use ATAPI prevent media removal or ATA lock method ???
	retn
CmdO_DoorLock endp


;***************************************

; 2  = resets the drive and this driver
CmdO_ResetDrive proc near
	; resets both drives on this controller   TODO: probably should change to just reset unitReq drive
	call reg_reset

	retn
CmdO_ResetDrive endp


;***************************************

; 3  = audio channel control
; TODO: implement me
CmdO_AudioChCtrl proc near
	retn
CmdO_AudioChCtrl endp


;***************************************

; 4  = allows programs to have direct control
; on Entry ES:DI points to subcommand 4, followed by N dup (?) bytes defined by driver & device
; For this driver only! subject to change if a known convention is found
; Direct Control Header (immediately follows subcommand 4)
; 0 marker	DB 'JH'			; if this is not there, assume app expects different format
; 2 command	DW ?				; specifies action to take, see below
; 4 status	DW ?				; set to error code before returning, 0==OK, -1==general error
; 6 reserved DW ?				; may contain future flags like disable DMA/Interrupt support
; 8 varies	DB ? DUP (?)		; remainding field varies in size depending on command
;
; If marker field does not match or a unsupported command is specified then call
; device driver call returns same as command not available (Cmd_NA)
; currently only 1 command is defined
; 0 Send ATAPI Packet Cmd
;   packetsize	DB 12			; size of packet to send, 12 or 16 bytes
;   datadir       DB ?			; one of APC_INPUT, APC_OUTPUT, APC_DONE indicating if data input/output/not
;   packetbufseg	DW ?			; segment and offset of buffer used for data transer (may be 0:0 for APC_DONE)
;   packetbufoff  DW ?			;
;   packet		DB 12 DUP (?)	; 12 (or packetsize) bytes with filled in packet data
						; byte count must equal packetsize bytes
						; actual contents depend on ATAPI command
; The contents of above are copied to local fields and PerformATAPIPacketCmd called,
; then the above status field is set with its return code (AX)
;
; on return AX, CX, and DI are undefined
CmdO_DirectCtrl proc near
	inc  DI							; point to start of Direct Control Header

	mov  AX, ES:[DI]						; verify if application and us speaking same language
	cmp  AX, 'HJ'
	jne  @@unsupported

	mov  AX, ES:[DI+2]					; get command (for now we only support cmd 0)
	cmp  AX, 0
	jne  @@unsupported
	
	mov  word ptr ES:[DI+4], 0				; clear status

	xor  CH, CH
	mov  CL, ES:[DI+6+0]					; get packetsize (store in CL for later packet copy)
	cmp  CX, 16							; just a safety check so we don't overwrite our pkt buffer
	ja   @@unsupported
	call_clearPacket CX					; initialize ATAPI command packet

	mov  AL, ES:[DI+6+1]					; get datadir
	mov  CS:[datadir], AL					; indicate if packet cmd inputs/outputs data or not

	mov  AX, ES:[DI+6+2]					; get packet buffer pointer segment
	mov  CS:[packetbufseg], AX				; set buffer to our working buffer
	mov  AX, ES:[DI+6+4]					; get packet buffer pointer offset
	mov  CS:[packetbufoff], AX

	; copy packet
	push DI
	add  DI, 6+8						; start of packet itself
	@@copyPktLoop:						; CX already set to packet size
	mov  AX, word ptr ES:[DI]				; get byte from user specified packet
	mov  word ptr CS:[packet+DI], AX			; store locally
	add  DI, 2							; next word
	loop @@copyPktLoop
	pop  DI

	call PerformATAPIPacketCmd	; handles sending packet to device and reading returned data into buffer
	jnc  @@done
	mov  ES:[DI+4], AX					; store error code for callee
	jmp  @@done

	@@unsupported:
	call Cmd_NA

	@@done:
	retn
CmdO_DirectCtrl endp


;*******************************************************************************
;*******************************************************************************

; Command to read data
; AX and DX modified, other registers preserved
; We do not support interleave, so interleave size & skip factor are ignored
;	DEVREQR_ILSIZE	EQU 0Ch	; interleave size
;	DEVREQR_ILSKIP	EQU 0Dh	; interleave skip factor
; TODO add support for MSF redbook mode
Cmd_ReadLong proc near
	DEBUG_PrintChar 'R'
	DEBUG_PrintChar 'L'
	mov  AX, word ptr [BX+DEVREQ_DATA+DEVREQR_SECTCNT]		; number (count) of sectors to read in (word)
	DEBUG_PrintNumber AH
	DEBUG_PrintNumber AL
	DEBUG_PrintChar '-'
	mov  AX, word ptr [BX+DEVREQ_DATA+DEVREQR_START+2]		; high word starting sector
	DEBUG_PrintNumber AH
	DEBUG_PrintNumber AL
	DEBUG_PrintChar ':'
	mov  AX, word ptr [BX+DEVREQ_DATA+DEVREQR_START]		; low word starting sector
	DEBUG_PrintNumber AH
	DEBUG_PrintNumber AL

	cmp  byte ptr [BX+DEVREQ_DATA+DEVREQR_ADDRMODE], AM_HSG	; see if LBA mode (High Sierra Group)
	jne  @@checkMSF
	DEBUG_PrintChar 'L'
	DEBUG_PrintChar 'B'
	DEBUG_PrintChar 'A'

	cmp  byte ptr [BX+DEVREQ_DATA+DEVREQR_MODE], DM_COOKED	; let device handle error correction, 2048
	jne  @@checkRAW

	; cooked mode LBA read request
IFDEF DEBUG
	mov  DX, OFFSET @@cooked
	call PrintMsg
ENDIF

	; ************ send cooked LBA read request ***************
	mov  CS:[packet], AC_READ10						; set command
	mov  CS:[packet+1], 0							; set various flag fields
	mov  AX, word ptr [BX+DEVREQ_DATA+DEVREQR_START+2]		; set LBA start address (big endian MSB 1st)
	xchg AH, AL
	mov  word ptr CS:[packet+2], AX
	mov  AX, word ptr [BX+DEVREQ_DATA+DEVREQR_START]		; low word of LBA start address (MSB 1st)
	xchg AH, AL
	mov  word ptr CS:[packet+4], AX
	mov  CS:[packet+6], 0							; reserved, MSB of length for AC_READ12
	mov  AX, word ptr [BX+DEVREQ_DATA+DEVREQR_SECTCNT]		; number (count) of sectors to read in (word)
	mov  CS:[packet+7], AH							; MSB of length for AC_READ10
	mov  CS:[packet+8], AL
	mov  CS:[packet+9], 0							; LSB of length for AC_READ12, misc for AC_READ10
	mov  CS:[packet+10], 0							; misc for AC_READ12, padding for AC_READ10
	mov  CS:[packet+11], 0

	mov  CS:[packetsize], 12						; indicate packet length is old 12 byte kind
	mov  CS:[datadir], APC_INPUT						; indicate pkt cmd inputs data
	mov  AX, word ptr [BX+DEVREQ_DATA+DEVREQR_TRANSADDR+2]	; buffer ptr segment (we assume large enough)
	mov  CS:[packetbufseg], AX
	mov  AX, word ptr [BX+DEVREQ_DATA+DEVREQR_TRANSADDR]		; buffer ptr offset
	mov  CS:[packetbufoff], AX
	call PerformATAPIPacketCmd	; handles sending packet to device and reading returned data into buffer
	jc   @@devError								; handle errors

	; hack, if sector 10h (VTOC) was read then reset our timeout for media changed
	mov  AX, word ptr [BX+DEVREQ_DATA+DEVREQR_START+2]		; high word starting sector
	cmp  AX, 0
	jnz  @@skiphack_s10lba
	mov  AX, word ptr [BX+DEVREQ_DATA+DEVREQR_START]
	cmp  AX, 10h
	jnz  @@skiphack_s10lba
	call set_media_timeout
	@@skiphack_s10lba:

	retn
	@@cooked DB 'cooked', 0Dh, 0Ah, '$'


	@@checkRAW:
	cmp  byte ptr [BX+DEVREQ_DATA+DEVREQR_MODE], DM_RAW		; raw 2352 sectors
	jne  @@unsupportedOption

	mov  DX, OFFSET @@raw
	call PrintMsg

	; ************ implement me ***************
	jmp  @@devError			; for now just say device not ready
	@@raw DB 'raw', 0Dh, 0Ah, '$'


	@@checkMSF:
	cmp  byte ptr [BX+DEVREQ_DATA+DEVREQR_ADDRMODE], AM_RED	; see if MSF mode (Redbook)
	jne  @@unsupportedOption
	; presently we don't support minute/second/frame mode
	DEBUG_PrintChar 'R'
	DEBUG_PrintChar 'E'
	DEBUG_PrintChar 'D'

	; ************ implement me ***************

	@@unsupportedOption:		; addrmode, mode, or other option not supported
	call Cmd_NA
	retn

	@@devError:				; errors such as no media or whatever
	; we always return not ready as the most common case will be no
	; CD in drive or unable to read CD, either way SHSUCDX only checks
	; if driver returns all ok (0x100) or not (anything else).
	setMediaChanged 1			; force media change check to indicate changed
	call Cmd_NotReady
	;call Cmd_DiskChanged
	;call Cmd_GeneralError
	retn
Cmd_ReadLong endp


;*******************************************************************************

; Command to indicate if possible drive should prefetch or at least seek
; to indicated sector.  
; Note: It is optional for this command to do anything, but doing so will
; generally lead to better performance.
; presently we just initiate a seek request
; TODO: add support to buffer requests if not busy
Cmd_ReadLongPrefetch proc near
	call Cmd_Seek

	retn
Cmd_ReadLongPrefetch endp


;*******************************************************************************

; Command used to tell drive to seek to particular location
; Given address mode & starting sector number, initiate moving head
; to that location and return immediately (ie don't wait for seek to
; complete, note: next command requiring disk activity will have to wait)
; Ignore the transfer address & sectors to read fields in request (should be 0)
Cmd_Seek proc near
	push AX

	mov  CS:[packet], AC_SEEK						; set command
	mov  CS:[packet+1], 0							; set various flag fields
	mov  AX, word ptr [BX+DEVREQ_DATA+DEVREQS_START+2]		; set LBA start address (big endian MSB 1st)
	xchg AH, AL
	mov  word ptr CS:[packet+2], AX
	mov  AX, word ptr [BX+DEVREQ_DATA+DEVREQS_START]		; low word of LBA start address (MSB 1st)
	xchg AH, AL
	mov  word ptr CS:[packet+4], AX
	mov  word ptr CS:[packet+6], 0					; remaining packet is reserved/padding
	mov  word ptr CS:[packet+8], 0
	mov  word ptr CS:[packet+10], 0

	mov  CS:[packetsize], 12						; indicate packet length is old 12 byte kind
	mov  CS:[datadir], APC_DONE						; indicate pkt cmd transfers no data
	mov  CS:[packetbufseg], 0						; packet data seg:off == 0:0
	mov  CS:[packetbufoff], 0
	call PerformATAPIPacketCmd	; handles sending packet to device and reading returned data into buffer
	; ignore errors for now

	pop  AX
	retn
Cmd_Seek endp


;*******************************************************************************
;*******************************************************************************


; plays audio
Cmd_PlayAudio proc near
	call Cmd_NA
	retn
Cmd_PlayAudio endp

; pauses if currently playing, else stops
Cmd_StopAudio proc near
	call Cmd_NA
	retn
Cmd_StopAudio endp

; resumes if paused
Cmd_ResumeAudio proc near
	push CX
	push BX

	; device call to pause/resume, however CDEX docs indicate pause/resume should
	; work slightly differently, stop when playing is pause with saved location,
	; then resume issues play with saved value
	call_clearPacket 12
	mov  CS:[packet], AC_PAUSERESUME			; indicate we want audio playing to pause or resume
	mov  CS:[packet+8], 1					; bit 0, if set then resume, if clear then pause
	call PerformATAPIPacketCmd	; handles sending packet to device and reading returned data into buffer

	pop  BX
	pop  CX
	retn
Cmd_ResumeAudio endp


;*******************************************************************************
;*******************************************************************************


; Command to perform initalization
; Note: On the first call this command calls the nonresident init code,
; further calls will simply return
Cmd_Init proc near
	mov  AL, CS:[units]
	cmp  AL, -1
	jne  @@done
	call Init
@@done:
	retn
Cmd_Init endp


IFDEF DEBUG

; Strings displayed during a debug build
DbgMsg_Newline			DB 0Dh, 0Ah, "$"
DbgMsg_EnterIntProc		DB "DBG: Entering Interrupt Procedure!", 0Dh, 0Ah, "$"
DbgMsg_LeaveIntProc		DB "DBG: Leaving Interrupt Procedure!", 0Dh, 0Ah, "$"
DbgMsg_UnknownIOCTLCmd		DB "DBG: Unknown IOCTL Cmd", 0Dh, 0Ah, "$"
DbgMsg_CallingIOCTLCmd		DB "DBG: Invoking IOCTL Cmd", 0Dh, 0Ah, "$"
DbgMsg_Cmd_NA			DB "DBG: Invalid or Unimplemented [IOCTL] Cmd", 0Dh, 0Ah, "$"
DbgMsg_Cmd_BADUNIT		DB "DBG: Invalid or unknown unit specified", 0Dh, 0Ah, "$"
DbgMsg_DevReqUnit			DB "DBG: Called with IOCTL Device Unit of 0x$"
DbgMsg_DevReqCmd			DB "DBG: Called with IOCTL Device Request Cmd of 0x$"
DbgMsg_IOCTLCmd_Init		DB "DBG: IOCTL Initialization", 0Dh, 0Ah, "$"
DbgMsg_IOCTLCmd_Input		DB "DBG: IOCTL Input", 0Dh, 0Ah, "$"
DbgMsg_IOCTLCmd_Output		DB "DBG: IOCTL Output", 0Dh, 0Ah, "$"
DbgMsg_IOCTLCmd_InputFlush	DB "DBG: IOCTL Input Flush", 0Dh, 0Ah, "$"
DbgMsg_IOCTLCmd_DevOpen		DB "DBG: IOCTL Device Open", 0Dh, 0Ah, "$"
DbgMsg_IOCTLCmd_DevClose	DB "DBG: IOCTL Device Close", 0Dh, 0Ah, "$"
DbgMsg_IOCTLCmd_ReadLong	DB "DBG: Cmd Read Long", 0Dh, 0Ah, "$"
DbgMsg_CmdI_Reserved		DB "DBG: Cmd Input Reserved", 0Dh, 0Ah, "$"
DbgMsg_CmdI_GetDevHdr		DB "DBG: CmdI Get Device Header", 0Dh, 0Ah, "$"
DbgMsg_CmdI_HeadLoc		DB "DBG: CmdI Head Location", 0Dh, 0Ah, "$"
DbgMsg_CmdI_ErrStats		DB "DBG: CmdI Error Statistics", 0Dh, 0Ah, "$"
DbgMsg_CmdI_AudioChannel	DB "DBG: CmdI Audio Channel", 0Dh, 0Ah, "$"
DbgMsg_CmdI_ReadDrvB		DB "DBG: CmdI Read Drive Bytes", 0Dh, 0Ah, "$"
DbgMsg_CmdI_DevStatus		DB "DBG: CmdI Device Status", 0Dh, 0Ah, "$"
DbgMsg_CmdI_SectorSize		DB "DBG: CmdI Sector Size", 0Dh, 0Ah, "$"
DbgMsg_CmdI_VolumeSize		DB "DBG: CmdI Volume Size", 0Dh, 0Ah, "$"
DbgMsg_CmdI_MediaChanged	DB "DBG: CmdI Media Changed", 0Dh, 0Ah, "$"
DbgMsg_CmdI_AudioDisk		DB "DBG: CmdI Audio Disk", 0Dh, 0Ah, "$"
DbgMsg_CmdI_AudioTrack		DB "DBG: CmdI Audio Track", 0Dh, 0Ah, "$"
DbgMsg_CmdI_AudioQCh		DB "DBG: CmdI Audio Q Channel", 0Dh, 0Ah, "$"
DbgMsg_CmdI_AudioSubCh		DB "DBG: CmdI Audio SubChannel", 0Dh, 0Ah, "$"
DbgMsg_CmdI_UPC			DB "DBG: CmdI UPC", 0Dh, 0Ah, "$"
DbgMsg_CmdI_AudioStatus		DB "DBG: CmdI Audio Status", 0Dh, 0Ah, "$"
DbgMsg_CmdO_Reserved		DB "DBG: Cmd Output Reserved", 0Dh, 0Ah, "$"
DbgMsg_CmdO_ResetDrive		DB "DBG: CmdO Reset Drive", 0Dh, 0Ah, "$"
;IFDEF DEBUG
;	mov DX, OFFSET DbgMsg_
;	call PrintMsg
;ENDIF

ENDIF 	; DEBUG


; Uses PrintChar to display the number in AL
; only AL used for input, all registers preserved
PrintNumber proc near
	push AX		; store value so we can process a nibble at a time

	; print upper nibble
	shr  AL, 4		; move upper nibble into lower nibble
	cmp  AL, 09h	; if greater than 9, then don't base on '0', base on 'A'
	jbe @@printme
	add  AL, 7		; convert to character A-F
	@@printme:
	add  AL, '0'	; convert to character 0-9
	call PrintChar

	pop  AX		; restore for other nibble
	push AX		; but save so we can restore original AL

	; print lower nibble
	and  AL, 0Fh	; ignore upper nibble
	cmp  AL, 09h	; if greater than 9, then don't base on '0', base on 'A'
	jbe @@printme2
	add  AL, 7		; convert to character A-F
	@@printme2:
	add  AL, '0'	; convert to character 0-9
	call PrintChar

	pop  AX
	retn
PrintNumber endp


; Prints a character using BIOS int 10h video teletype function
; All registers are preserved
; Expects character to print in AL
PrintChar proc near
	push BP		; for BIOSes that screw it up if text scrolls window
	push BX
	push AX

	; get current active page
	mov  AH, 0Fh	; get current video mode
	int  10h		; perform Video - BIOS request
				; on return AH=screen width (# of columns),
				; AL=display mode, and *** BH=active page # ***
	mov  BL, 07h	; ensure sane color in case in graphics mode
	pop  AX
	push AX
	mov  AH, 0Eh	; Video - Teletype output
	int  10h		; invoke request

	pop AX
	pop BX
	pop BP
	retn
PrintChar endp


; display string using PrintChar
; we don't use DOS print string as it trashes our request header
; expects CS:DX to point to $ terminated string
; all registers preserved
PrintMsg proc near
	push BX		; save registers modified
	push AX

	mov  BX, DX

	@@next:
	mov  AL, CS:[BX]
	inc  BX
	cmp  AL, '$'
	je   @@done
	call PrintChar
	jmp  @@next

	@@done:

	pop  AX		; restore registers we changed
	pop  BX
	retn
PrintMsg endp


; perform ATA software reset
; reset done on both devices (if exists) as determined by base of [unitReq]
; ;devRtn (which device is set in CB_DH) is determined by which unitReq actually refers to
; no registers are modified
reg_reset proc near
	push AX
	push BX
	push DX

	; ensure a small delay before accessing any ATA registers
	DELAY400NS;

	; initialize timeout value
	MAXSECS EQU 10				; max seconds, originally 20
	mov  AX, MAXSECS*18			; max seconds * 18 clock ticks / second == clock ticks to wait
	call set_BIOS_timeout
	
	; Set and then reset the soft reset bit in the Device Control
	; register.  This causes device 0 be selected.
	; callee may want this skipped
	mov  AL, devCtrl
	or   AL, CB_DC_SRST
      call_pio_outbyte CB_DC, AL		; devCtrl | CB_DC_SRST
      DELAY400NS;
      call_pio_outbyte CB_DC, devCtrl
      DELAY400NS;

	mov  BL, CS:[unitReq]			; get lun of device requested
	xor  BH, BH					; expand into BX
	DDEBUG_PrintChar 'l'
	DDEBUG_PrintNumber bl
	mov  BL, CS:lun_map_addrs[BX]		; map to one of the controllers
	xor  BH, BH					; expand into BX
	DDEBUG_PrintChar 'c'
	DDEBUG_PrintNumber bl

	; if there is a MASTER device
	mov  AL, CS:pio_reg_flags[BX]		; get flag that indicates if master & slave (probably) exist
	DDEBUG_PrintChar 'f'
	DDEBUG_PrintNumber al
	test AL, FLG_MASTER
	jz   @@checkslave

	;call atapi_delay

	@@loopwhilebusyMaster:			; loop while busy flag set or until timeout
	call_pio_inbyte CB_STAT
	test AL, CB_STAT_BSY
	jz   @@endbusyloopMaster
	; check for timeout
	call check_BIOS_timeout
	jc   @@timeout_1
	jmp @@loopwhilebusyMaster
	@@timeout_1:
;            reg_cmd_info.to = 1;		; indicate time-out
;            reg_cmd_info.ec = 1;		; error code = 1
	@@endbusyloopMaster:


@@checkslave:
	; if there is a SLAVE device
	mov  AL, CS:pio_reg_flags[BX]		; get flag that indicates if master & slave (probably) exist
	test AL, FLG_SLAVE
	jz   @@resetdone

	;call atapi_delay

	@@loopwhilebusySlave:			; wait until allows register access
	call_pio_outbyte CB_DH, CB_DH_DEV1
	DELAY400NS;
	call_pio_inbyte CB_SC
	xchg AH, AL
	call_pio_inbyte CB_SN
	cmp  AX, 0101h
	je @@endbusyloopSlave
	; check for timeout
	call check_BIOS_timeout
	jc   @@timeout_2
	jmp @@loopwhilebusySlave
	@@timeout_2:
;            reg_cmd_info.to = 1;		; indicate time-out
;            reg_cmd_info.ec = 2;		; error code = 2
	@@endbusyloopSlave:

	; if no error or timeout (error code still 0) so far, then check if drive 1 set BSY=0
	call_pio_inbyte CB_STAT
	test AL, CB_STAT_BSY
	jz   @@resetdone
;		 // reg_cmd_info.to = 0;
;            reg_cmd_info.ec = 3;

	@@resetdone:			;RESET_DONE:


	; done, but select caller expected device
	;call_pio_outbyte CB_DH, CB_DH_DEV?
	DELAY400NS;

	; select a device that exists (if possible), preferably device 0

	; 1st select slave, if exists
	mov  AL, CS:pio_reg_flags[BX]		; get flag that indicates if master & slave (probably) exist
	test  AL, FLG_SLAVE
	jz   @@next1
	call_pio_outbyte CB_DH, CB_DH_DEV1
	DELAY400NS;
	@@next1:
	; now try selecting master, if exists
	mov  AL, CS:pio_reg_flags[BX]		; get flag that indicates if master & slave (probably) exist
	test  Al, FLG_MASTER
	jz   @@next2
	call_pio_outbyte CB_DH, CB_DH_DEV0
	DELAY400NS;
	@@next2:

	pop  DX
	pop  BX
	pop  AX
	retn
reg_reset endp


EVEN
mystack DW 1000 dup (03h)
mystacktop:


;*******************************************************************************
; End of Resident Code
;*******************************************************************************
endOfResidentCode:


;*******************************************************************************

; Strings displayed at startup
AtapiCDDMsg		DB "Public Domain ATAPI CD-ROM Driver ", ReleaseStr, ", KJD 2001-2003"
newlineMsg		DB 0Dh, 0Ah, "$"

DrivesFoundMsg	DB " IDE/ATAPI Drives", 0Dh, 0Ah, "$"
NoDrivesFoundMsg	DB "Failure!  No IDE/ATAPI Drives found!", 0Dh, 0Ah, "$"

FoundMsg		DB "Found $"
Dev0Msg		DB "Master $"
Dev1Msg		DB "Slave $"
NoDevMsg		DB "No device $"
BaseIOMsg		DB "at base I/O: 0x", "$"
StatusIOMsg		DB ", status I/O: 0x", "$"
UnknownMsg		DB "[Phantom] $"
ATAFoundMsg		DB "[ATA, not ATAPI device] $"
ATAPIFoundMsg	DB "[ATAPI device] $"


; prints the info stored about the unit
; [unitReq] specifies device to print info about
; no registers changed
printUnitInfo proc near
	push DX
	push BX
	push AX

	mov  BL, CS:[unitReq]			; get lun of device requested
	xor  BH, BH					; expand into BX

	; print master or slave & ATAPI or ATA
	mov  AH, CS:lun_map_dev[BX]		; device (master, slave, or none)
	mov  BL, CS:lun_map_addrs[BX]		; index into our map to determine index of controller data
	xor  BH, BH					; expand into BX
	mov  AL, CS:pio_reg_flags[BX]		; type (ATAPI, ATA, or unknown)

	
	cmp  AH, FLG_MASTER 			; check device type (master or slave)
	je   @@printMaster
	cmp  AH, FLG_SLAVE			; see if actually a slave
	je   @@printSlave
	mov  DX, OFFSET NoDevMsg		; no master or slave, either init pre-detection or
	jmp  @@printtype				; init no device found, otherwise its a bug

	@@printSlave:
	mov  DX, OFFSET Dev1Msg			; load slave message
	call PrintMsg				; and print it
	test AL, FLG_SATAPI			; see if slave is ATAPI
	jnz  @@printATAPI
	test AL, FLG_SATA				; or maybe its ATA
	jnz  @@printATA
	jmp  @@printUnknown

	@@printMaster:
	mov  DX, OFFSET Dev0Msg			; load master message
	call PrintMsg				; and print it
	test AL, FLG_MATAPI			; see if master is ATAPI
	jnz  @@printATAPI
	test AL, FLG_MATA				; ok check if ATA
	jnz  @@printATA

	@@printUnknown:
	mov  DX, OFFSET UnknownMsg		; neither ATAPI nor ATA, but still found
	jmp  @@printtype

	@@printATA:
	mov  DX, OFFSET ATAFoundMsg		; load ATA message
	jmp  @@printtype

	@@printATAPI:
	mov  DX, OFFSET ATAPIFoundMsg		; load ATAPI message
	;jmp  @@printtype

	@@printtype:
	call PrintMsg	


	; print the base I/O address
	mov  DX, OFFSET BaseIOMsg		; load base register I/O address message
	call PrintMsg

	; use same method other code uses, base I/O address same as register 0
	mov  DX, 0
	call get_pio_port
	mov  AX, DX
	xchg AH, AL				; print the high byte 1st
	call PrintNumber
	xchg AL, AH				; now the low byte
	call PrintNumber

	mov  DX, OFFSET StatusIOMsg	; print the status register I/O address (base2)
	call PrintMsg			; note this is status register base I/O address
						; NOT the more common status register itself I/O address (differ by 6)
	add  AX, 200h			; presently we assume 0x200 from base I/O address
	xchg AL, AH				; print the high byte 1st
	call PrintNumber
	xchg AL, AH				; now the low byte
	call PrintNumber

	mov  DX, OFFSET newlineMsg	; and of course move the cursor to the next line for pretty output :-)
	call PrintMsg

	pop  AX
	pop  BX
	pop  DX
	retn
printUnitInfo endp


; Determines if device exists & if so if its an ATAPI one
; expects on entry
; lun_map_addrs, pio_reg_addrs_base to be set
; on exit will have set
; pio_reg_flags, but lun_map_dev still requires being set
; no registers changed
reg_config proc near
	push AX
	push BX

	mov  BL, CS:[unitReq]			; get lun of device requested
	xor  BH, BH					; expand into BX
	mov  BL, CS:lun_map_addrs[BX]		; map to one of the controllers
	xor  BH, BH					; expand into BX

	; initialize to no devices on this controller
	mov  pio_reg_flags[BX], FLG_NONE

	; set up Device Control register
	call_pio_outbyte CB_DC, devCtrl

	; lets see if there is a device (master)
	call_pio_outbyte CB_DH, CB_DH_DEV0	; select device 0 (master)
	DELAY400NS;
	call_pio_outbyte CB_SC, 055h
	call_pio_outbyte CB_SN, 0aah
	call_pio_outbyte CB_SC, 0aah
	call_pio_outbyte CB_SN, 055h
	call_pio_outbyte CB_SC, 055h
	call_pio_outbyte CB_SN, 0aah
	call_pio_inbyte CB_SC			; al = sector count
	mov  AH, AL
	call_pio_inbyte CB_SN			; al = sector number
	cmp  AX, 55AAh				; sector count == 0x55  &&  sector number == 0xaa
	jne  @@notfound_1				; device not found, check again after reset
	or   pio_reg_flags[BX], FLG_MASTER	; indicate a master device was found
	DDEBUG_PrintChar 'M'
	@@notfound_1:

	; lets see if there is a device (slave)
	call_pio_outbyte CB_DH, CB_DH_DEV1	; select device 1 (slave)
	DELAY400NS;
	call_pio_outbyte CB_SC, 055h
	call_pio_outbyte CB_SN, 0aah
	call_pio_outbyte CB_SC, 0aah
	call_pio_outbyte CB_SN, 055h
	call_pio_outbyte CB_SC, 055h
	call_pio_outbyte CB_SN, 0aah
	call_pio_inbyte CB_SC			; al = sector count
	mov  AH, AL
	call_pio_inbyte CB_SN			; al = sector number
	cmp  AX, 55AAh				; sector count == 0x55  &&  sector number == 0xaa
	jne  @@notfound_2				; device not found, check again after reset
	or   pio_reg_flags[BX], FLG_SLAVE	; indicate a slave device was found
	DDEBUG_PrintChar 'S'
	@@notfound_2:

	; now we think we know which devices, if any are there,
	; so lets try a soft reset (ignoring any errors).
	call_pio_outbyte CB_DH, CB_DH_DEV0
	DELAY400NS;
	DDEBUG_PrintChar '{'
	call reg_reset
	DDEBUG_PrintChar '}'

	; lets check device 0 again, is the device really there?
	; is it ATA or ATAPI?
	call_pio_outbyte CB_DH, CB_DH_DEV0	; select device 0 (master)
	DELAY400NS;
	call_pio_inbyte CB_SC		; al = sector count
	mov  AH, AL
	call_pio_inbyte CB_SN		; al = sector number
	; if ( (sector count == 0x01) && (sector number == 0x01) ) // device found, check type
	DDEBUG_PrintChar 'D'
	DDEBUG_PrintChar '0'
	DDEBUG_PrintChar 'S'
	DDEBUG_PrintChar 'C'
	DDEBUG_PrintNumber ah
	DDEBUG_PrintChar 'S'
	DDEBUG_PrintChar 'N'
	DDEBUG_PrintNumber al
	cmp  AX, 0101h
	je   @@checktypedev0		; see if its really an ATAPI device

	; indicate not really a device there
	and  pio_reg_flags[BX], NOT FLG_MASTER
	jmp  @@checkdev1			; device 0 not found, proceed to recheck device 1

	@@checktypedev0:
	DDEBUG_PrintChar 'm'
	; we are sure there is a device, mark it (in case not already done so)
	or   pio_reg_flags[BX], FLG_MASTER

	; see if ATAPI
	call_pio_inbyte CB_CL		; al = cylinder low byte
	mov  AH, AL
	call_pio_inbyte CB_CH		; al = cylinder high byte
	; if ( (cyl low == 0x14) && (cyl high == 0xEB) ) // ATAPI device found
	DDEBUG_PrintChar 'D'
	DDEBUG_PrintChar '0'
	DDEBUG_PrintChar 'C'
	DDEBUG_PrintChar 'H'
	DDEBUG_PrintNumber al
	DDEBUG_PrintChar 'C'
	DDEBUG_PrintChar 'L'
	DDEBUG_PrintNumber ah
	cmp  AX, 14EBh
	jne  @@isatafounddev0		; ignore, either unknown or ATA device found

	; we found an ATAPI device, so mark it as such
	or   pio_reg_flags[BX], FLG_MATAPI
	jmp  @@checkdev1

	@@isatafounddev0:
      ;if ( ( cl == 0x00 ) && ( ch == 0x00 ) && ( st != 0x00 ) )
	cmp  AX, 0				; compare cyl low and cyl high to 0x00
	jne  @@checkdev1			; no, then some unknown device
	call_pio_inbyte CB_STAT
	DDEBUG_PrintChar 'S'
	DDEBUG_PrintChar 'T'
	DDEBUG_PrintNumber al
	cmp  AL, 0
	jz   @@checkdev1			; if not zero then we found an ATA device (e.g. hard drive)
	or   pio_reg_flags[BX], FLG_MATA	
	;jmp @@ checkdev1

	@@checkdev1:
	; lets check device 1 again, is the device really there?
	; is it ATA or ATAPI?
	call_pio_outbyte CB_DH, CB_DH_DEV1	; select device 1 (slave)
	DELAY400NS;
	call_pio_inbyte CB_SC		; al = sector count
	mov  AH, AL
	call_pio_inbyte CB_SN		; al = sector number
	; if ( (sector count == 0x01) && (sector number == 0x01) ) // device found, check type
	DDEBUG_PrintChar 'D'
	DDEBUG_PrintChar '1'
	DDEBUG_PrintChar 'S'
	DDEBUG_PrintChar 'C'
	DDEBUG_PrintNumber ah
	DDEBUG_PrintChar 'S'
	DDEBUG_PrintChar 'N'
	DDEBUG_PrintNumber al
	cmp  AX, 0101h
	je   @@checktypedev1		; see if its really an ATAPI device

	; indicate not really a device there
	and  pio_reg_flags[BX], NOT FLG_SLAVE
	jmp  @@done				; device 1 not found, proceed to end

	@@checktypedev1:
	DDEBUG_PrintChar 's'
	; we are sure there is a device, mark it (in case not already done so)
	or   pio_reg_flags[BX], FLG_SLAVE

	; see if ATAPI
	call_pio_inbyte CB_CL		; al = cylinder low byte
	mov  AH, AL
	call_pio_inbyte CB_CH		; al = cylinder high byte
	; if ( (cyl low == 0x14) && (cyl high == 0xEB) ) // ATAPI device found
	DDEBUG_PrintChar 'D'
	DDEBUG_PrintChar '1'
	DDEBUG_PrintChar 'C'
	DDEBUG_PrintChar 'H'
	DDEBUG_PrintNumber al
	DDEBUG_PrintChar 'C'
	DDEBUG_PrintChar 'L'
	DDEBUG_PrintNumber ah
	cmp  AX, 14EBh
	jne  @@isatafounddev1		; ignore, either unknown or ATA device found

	; we found an ATAPI device, so mark it as such
	or   pio_reg_flags[BX], FLG_SATAPI
	jmp  @@done

	@@isatafounddev1:
      ;if ( ( cl == 0x00 ) && ( ch == 0x00 ) && ( st != 0x00 ) )
	cmp  AX, 0				; compare cyl low and cyl high to 0x00
	jne  @@done				; no, then some unknown device
	call_pio_inbyte CB_STAT
	DDEBUG_PrintChar 'S'
	DDEBUG_PrintChar 'T'
	DDEBUG_PrintNumber al
	cmp  AL, 0
	jz   @@done				; if not zero then we found an ATA device (e.g. hard drive)
	or   pio_reg_flags[BX], FLG_SATA	
	;jmp @@done

	@@done:

	DDEBUG_PrintChar 0Dh			; print newline to seperate debug prints from normal messages
	DDEBUG_PrintChar 0Ah

	; select a device that exists (if possible), preferably device 0

	; 1st select slave, if exists
	mov  AL, CS:pio_reg_flags[BX]		; get flag that indicates if master & slave (probably) exist
	test  AL, FLG_SLAVE
	jz   @@next
	call_pio_outbyte CB_DH, CB_DH_DEV1
	DELAY400NS;
	@@next:
	; now try selecting master, if exists
	mov  AL, CS:pio_reg_flags[BX]		; get flag that indicates if master & slave (probably) exist
	test  Al, FLG_MASTER
	jz   @@next2
	call_pio_outbyte CB_DH, CB_DH_DEV0
	DELAY400NS;
	@@next2:

	pop  BX
	pop  AX
	retn
reg_config endp


; init time options, defaults to 1 device, check all controllers
; see also devName DB 8 dup (?) which corresonds with /D:<name> option
lookfor_N_devices DB 1						; corresponds with /N:# option
; a flag per controller, if nonzero then we skip looking for a device on that controller
skip_controller_check DB MAX_CONTROLLERS dup (0)	; set with /K:#

; processes command line as specified in DS:BX
; no registers modified
; assumes default values already set
; will update variables as switches encountered going from left to right
; invalid options will be silently ignored (and may screw up rest of processing)
; Currently supported options:
;   /D:<name>
;     - will set the device name field (DOS device) to <name>
;     - if <name> is less than 8 characters then space ' ' padded on right to 8 bytes
;     - if <name> is more than 8 characters, the rest are ignored
;   /N:#
;     - specifies to look for # devices
;     - default is 1 (as per spec)
;     - maximum value is 8 (or up to MAX_CONTROLLERS*2 are supported), higher values are ok
;     - a value of 0 indicates search for maximum devices
;     - # is a single HEX digit, remaining characters are ignored
;   /K:#
;     - specifies to ignore (Kill) controller #
;     - # is the index into the controller table, which normally refers to IDE 0,1,2,3
;     - # is a single HEX digit, remaining characters are ignored
;     - if # refers to a value < 0 or >= MAX_CONTROLLERS it is ignored
;   /C:#,<baseIO>[,<irq>[,<drive>]]   [ TODO ]
;     - overrides default value of base I/O address of controller #
;     - # see /K for description of # (controller index)
;     - , is required separator, as future revisions may expand # to larger than nibble
;     - <baseIO> is HEX base I/O port address, e.g. 1F0
;     - <irq> determines the interrupt to use; presently ignored as we don't use one
;     - <drive> indicates if drive is master==0 or slave==1; also ignored
;   /P:<baseIO>[,<irq>[,<device>]]   [TODO]
;     - speed up startup by specifying the controller ({P}ort) to check for CDROM on
;     - convienence command, same as /C:0,<baseIO>[,<irq>[,<drive>]] /K:1 /K:2 /K:3
;     - <baseIO> is HEX base I/O port address, e.g. 1F0
;     - <irq> determines the interrupt to use; presently ignored as we don't use one
;     - <device> indicates if drive is master==0 or slave==1; also ignored
;     - this must be the only (or last) option on the command line
;   /S:<baseIO>,<irq>,<device>   [TODO]
;     - speed up startup by {S}electing the controller and device for CDROM drive
;     - while similar to /P, this option bypasses the detection phase and assumes
;       correct information is given.  It is therefore even faster than /P, but
;       the <irq> and <drive> must be specified.
;     - currently <irq> is ignored, however for future compatibility, the correct
;       value should be given when this switch is used (for when interrupts are used)
;     - <device> indicates if device is the master or slave
;     - this must be the only (or last) option on the command line
;   one should be suggest port the other skip detection and assume port /P or /S ???
;   /I???  [ reserved, [dis]enable interrupt mode once we support interrupt based I/O ]
; Only /D and /N are specified by CDEX document, the remaining are extensions
; and subject to change in future revisions (to avoid conflicts with existing practice)
processCmdLine proc near
	push AX
	push BX
	push DI

	@@loopstart:
	mov  AL, byte ptr [BX]
DEBUG_PrintChar al
DEBUG_PrintChar ' '
	cmp  AL, '/'			; check for switch character (TODO: can we use DOS switchar in CONFIG.SYS?)
	je   @@checkswitch
	cmp  AL, 0Dh			; \r end of line marker
	je   @@loopend
	cmp  AL, 0Ah			; \n end of line marker
	je   @@loopend
	cmp  AL, 0				; safety check for \0, not valid so exceeded end of line
	je   @@loopend

	; we silently ignore everything except end of line marker and switch character!
	@@next:
	inc  BX				; check next character
	jmp  @@loopstart

	@@checkswitch:
	inc  BX				; point to character after switch
	mov  AL, byte ptr [BX]
	cmp  AL, 'D'		; device name
	je   @@optD
	cmp  AL, 'N'		; number of devices
	je   @@optN
	cmp  AL, 'K'		; ignore controller
	je   @@optK
	cmp  AL, 'C'		; change controller base I/O port address
	je   @@optC
	cmp  AL, 'I'		; change interrupt # to use
	je   @@optI
	jmp  @@loopstart			; not a supported option, so check it for EOL or start of new switch markers

	@@optD:
	inc  BX				; point to : after /D
mov al, [bx]
DEBUG_PrintChar al
	xor  DI, DI				; counter, we copy at most 8 characters (or pad to 8 characters)
	@@Dloop:
	inc  BX				; point to next character on command line
	mov  AL, [BX]
	cmp  AL, ' '			; space marks end of device name (all spaces is ok with us, but may mess up others)
	je   @@pad
DEBUG_PrintChar al
	mov  CS:devName[DI], AL		; store portion of new name
	inc  DI				; increment our counter so we know when devName is full (8 characters max)
	cmp  DI, 8				; see if we've maxed out our array
	jb   @@Dloop			; not yet, so get next character
	@@pad:
	cmp  DI, 8				; see if we need to pad
	jae  @@next				; so we inc BX before continuing
DEBUG_PrintChar '.'
	mov  CS:devName[DI], ' '	; pad with a space
	inc  DI
	jmp  @@pad

	@@optN:
	inc  BX				; point to : after /N
mov al, [bx]
DEBUG_PrintChar al
	inc  BX				; point to # after :
mov al, [bx]
DEBUG_PrintChar al
	mov  AL, [BX]			; get the number, '0'-'9' are 0-9, >= 'A'&0FDh are 10+, so G is valid sorta
	cmp  AL, 'A'			; see if letter (A-F) or number (0-9) specified
	jae  @@NcapLetter
	cmp  AL, 'a'
	jae  @@NlowLetter
	sub  AL, '0'			; hex digit is 0-9, so adjust based on letter zero (0)
	or   AL, AL				; see if 0, in which case set to maximum supported
	jnz  @@NsetN
	mov  AL, MAX_DEVICES
	jmp  @@NsetN
	@@Ncapletter:
	sub  AL, 'A'+10			; hex digit is A-F, so adjust based on A
	jmp  @@NsetN
	@@Nlowletter:
	sub  AL, 'a'+10			; hex digit is A-F, so adjust based on A
	@@NsetN:				; store the new value for max units to look for
	mov  CS:[lookfor_N_devices], AL
DEBUG_PrintChar '*'
DEBUG_PrintNumber AL
DEBUG_PrintChar '*'
	jmp  @@next				; so we inc BX before continuing

	@@optK:
	inc  BX				; point to : after /K
	inc  BX				; point to # after :
	mov  AL, [BX]			; get the number, '0'-'9' are 0-9, >= 'A'&0FDh are 10+, so G is valid sorta
	cmp  AL, 'A'			; see if letter (A-F) or number (0-9) specified
	jae  @@KcapLetter
	cmp  AL, 'a'			; see if letter (a-f)
	jae  @@KlowLetter
	sub  AL, '0'			; hex digit is 0-9, so adjust based on letter zero (0)
	jmp  @@KsetIgnore
	@@KlowLetter:
	sub  AL, 'a'+10			; hex digit is A-F, so adjust based on A
	jmp  @@KsetIgnore
	@@KcapLetter:
	sub  AL, 'A'+10			; hex digit is A-F, so adjust based on A
	@@KsetIgnore:			; mark flag to ignore controller in AL
	cmp  AL, MAX_CONTROLLERS	; ignore if invalid valid
	ja   @@next
	cbw					; sign extend AL into AX
	mov  DI, AX
	mov  CS:skip_controller_check[DI], 1
	jmp  @@next				; so we inc BX before continuing

	@@optC:
	inc  BX				; point to : after /C
	inc  BX				; point to # after :
	inc  BX				; point to , after #
	inc  BX				; point to start of <baseIO> after ,
	; TODO, implement me
	jmp  @@next				; so we inc BX before continuing

	@@optI:				; not currently used/supported, set interrupt
	inc  BX				; point to : after /I
	; TODO, implement me
	jmp  @@next				; so we inc BX before continuing

	@@loopend:

DEBUG_PrintChar 0Dh
DEBUG_PrintChar 0Ah

	pop  DI
	pop  BX
	pop  AX
	retn
processCmdLine endp


; performs one time initialization
; detects number of drives using standard controller port addresses
; must preserve CS, DS:BX, all other registers may be modified
; also will process command line options
; presently only support /D:devname
; TODO: we don't support arbitrary ATA/ATAPI controller I/O addresses,
; however one can override a default value as long as the secondary
; controller (base2, status register, ...) is offset +0x200 from base I/O
; 
Init proc near
	mov  DX, OFFSET AtapiCDDMsg
	call PrintMsg

	; peform command line processing
	push DS						; save these registers, we use them later
	push BX
	lds  BX, [BX+DEVREQ_DATA+DEVREQI_CMDLINE]	; set DS:BX to cmd line
	call processCmdLine
	pop  BX
	pop  DS

	; initially no units detected
	mov  CS:[units], 0

	;	// cycle through all possible combinations supported,
	;	// detecting master & slave at roughly the same time
	;	for (int i=0; (i < MAX_CONTROLLERS); i++)
	xor  CX, CX					; i = 0
	push BX
@@loop_finddrives:

	; store (for use by pio io functions) which register set we are currently testing
	mov  AL, CS:[units]
	mov  CS:[unitReq], AL

	; add entry to our mapping table to correspond with current controller
	cbw						; copy AL (current logical unit) into BX
	mov  BX, AX
	mov  CS:lun_map_addrs[BX], CL		; set entry to index of current controller in pio_reg_*
	mov  CS:lun_map_dev[BX], 0		; init to no device (neither slave nor master)

IFDEF DDEBUG
	; this should show no devices and what I/O address we are testing
	call printUnitInfo
ENDIF

	; check for device specified by unitReq indexing into pio_reg_*
	call reg_config

IFDEF DEBUG
	; print what devices, including unknown & ATA we found
	mov  BL, CS:lun_map_addrs[BX]		; map to one of the controllers
	xor  BH, BH					; expand into BX
	mov  AL, pio_reg_flags[BX]		; get flags, indicates if slave & master present
	mov  AH, AL
	mov  BL, CS:[unitReq]
	xor  BH, BH
	and  AL, FLG_MASTER			; determine if master present
	mov  CS:lun_map_dev[BX], AL
	call printUnitInfo			; and print master's type
	and  AH, FLG_SLAVE			; determine if slave present
	mov  CS:lun_map_dev[BX], AH
	call printUnitInfo			; and print slave's type
	mov  CS:lun_map_dev[BX], 0		; restore this value
ENDIF

	mov  BL, CS:lun_map_addrs[BX]		; map to one of the controllers
	xor  BH, BH					; expand into BX
	; see if any drives detected
	test pio_reg_flags[BX], FLG_MATAPI OR FLG_SATAPI
	jz   @@loop_continue			; if 0 then we didn't find a device
	
	; if master ATAPI device, set it to this lun
	test pio_reg_flags[BX], FLG_MATAPI
	jz   @@slave_atapi

	; mark this lun as the master
	mov  DX, BX					; save BX
	mov  BL, CS:[unitReq]			; get lun index
	xor  BH, BH
	mov  CS:lun_map_dev[BX], FLG_MASTER
	mov  BX, DX					; restore
	
	; we found an ATAPI device, so lets increment our counter & tell the user
	inc  CS:[units]				; increment counter, units++

	mov  DX, OFFSET FoundMsg		; describe what found to user
	call PrintMsg
	call printUnitInfo

	; if there is a slave, we need to duplicate the controller mapping
	test pio_reg_flags[BX], FLG_SATAPI
	jz   @@loop_continue
	inc  CS:unitReq				; point to next entry

	@@slave_atapi:
	mov  BL, CS:[unitReq]			; get lun index
	xor  BH, BH
	; set entry to index of current controller in pio_reg_*
	mov  CS:lun_map_addrs[BX], CL		; if there's a master we are setting the duplicate entry
	; mark this lun as the slave
	mov  CS:lun_map_dev[BX], FLG_SLAVE
	
	; we found an ATAPI device, so lets increment our counter & tell the user
	inc  CS:[units]				; increment counter, units++

	mov  DX, OFFSET FoundMsg		; describe what found to user
	call PrintMsg
	call printUnitInfo

@@loop_continue:
	inc  CX					; i++
	cmp  CX, MAX_CONTROLLERS		; i < MAX_CONTROLLERS
	jae  @@loop_end
	mov  BX, CX					; if (skip_controller_check[i]) i++
	cmp  CS:skip_controller_check[BX], 0
	jnz  @@loop_continue
	mov  AL, CS:[units]			; units < N
	cmp  AL, CS:[lookfor_N_devices]
	jae  @@loop_end
	jmp  @@loop_finddrives
@@loop_end:
	pop BX

	cmp  CS:[units], 0			; if (!units) return success
	jz   @@failure				; else return success


	; give device a chance to spin up (if there is a CD-ROM in there)
	mov  CX, 3
	mov  CS:[unitReq], 0			; set to a drive we found (assumes units > 0)
	@@testSpinUp:				; assumes if one drive spins up, others had 
	call testUnitReady			; time as well, though could actually check
	jnc  @@endSpinUpDelay			; all drives found (for i=0;i<units;i++) if desired
	loop @@testSpinUp
	@@endSpinUpDelay:
	; loop through all found devices and issue start (& close tray) command
	mov  CL, 0
	@@startSpinUp:
	mov  CS:[unitReq], CL
	mov  AX, 01h				; LoEj=0, Start=1; (don't close tray) start & read TOC
	call startStopCmd
	call getMediaStatus			; issue ATAPI media event status request so next call has correct value
	inc  CL
	cmp  CL, CS:[units]
	jl   @@startSpinUp


@@success:
	; set Config flag that we succeeded
	mov word ptr [BX+DEVREQ_DATA+DEVREQI_CFGFLG], 0
	; tell DOS we support 0 units (since we are character device)
	mov word ptr [BX+DEVREQ_DATA+DEVREQI_UNITS], 0
	; specify where end of resident section is
	mov word ptr [BX+DEVREQ_DATA+DEVREQI_ENDADDR], OFFSET endOfResidentCode
	mov word ptr [BX+DEVREQ_DATA+DEVREQI_ENDADDR+2], CS

	mov  DX, OFFSET FoundMsg
	call PrintMsg
	mov  AL, CS:[units]
	call PrintNumber
	mov  DX, OFFSET DrivesFoundMsg
	call PrintMsg

	jmp @@done

@@failure:
	; indicate general failure error of in device request header
	call Cmd_GeneralError
	; set Config.sys flag that we failed, since no drives were found
	mov word ptr [BX+DEVREQ_DATA+DEVREQI_CFGFLG], 1
	; tell DOS we support 0 units (since we are character device)
	mov word ptr [BX+DEVREQ_DATA+DEVREQI_UNITS], 0
	; specify to keep none of the program resident
	mov word ptr [BX+DEVREQ_DATA+DEVREQI_ENDADDR], 0
	mov word ptr [BX+DEVREQ_DATA+DEVREQI_ENDADDR+2], CS

	mov DX, OFFSET NoDrivesFoundMsg
	call PrintMsg

@@done:
	retn
Init endp

;*******************************************************************************

code ends

end devHdr
