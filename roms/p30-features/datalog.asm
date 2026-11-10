; ==================================================================================================
; datalog.asm - serial datalogging: the link every datalog part shares (NEED_DATALOG), and the HTS / ISR frame
;> feature: FEAT_DATALOG
;> name: Datalogging: HTS / ISR frame
;> category: Diagnostics
;> conflicts: FEAT_STOCK_SERIAL, FEAT_DLQD3
;> pages: datalog
;> ram: 374h-37Eh (378h-37Eh is bank 6Fh), 0FDh bit 7 and module RAM (1 byte): the byte budget
;> about: The HTS / ISR protocol on the datalog pins at 38400 baud (the HTS wiring; 62,500 with DatalogFast): existing loggers work
;>        unchanged. 10h (or ABh) -> CDh, then 20h (or 90h) -> the 51-byte frame and its checksum, C0h+n ->
;>        byte n of it, 40h -> the HTS120 extra packet. The QD3 frame is a different protocol on the same
;>        pins: one or the other. The channel stream and the service commands go with either. Whatever is
;>        sent, the main loop's spark calculation sets how many bytes may go before the next one: fewer the
;>        higher the rpm, so logging can never take the time the engine code needs.
;
; The serial link itself (the port set up, the interrupts, what is being sent) is built whenever any datalog part is
; (NEED_DATALOG, set in features.inc); the parts add their commands to it.
;
; The 51-byte frame: byte 8 status (bit 3 VTEC, 4 check-engine lamp; with the service commands 5 injectors off,
;   6 timing locked), 11 the service state, 12-15 the stored trouble codes (with FEAT_STOCK_DTC: 31Ah-31Dh, bit i
;   the code the ROM flashes for it - i+1, but 24 is 35, 25 is 36, 26 is 41, 28 is 43; the bytes HTS ROMs send
;   there too).
; A frame table entry is a RAM or SFR address, or: 0 always 00h; FExxh the constant xx; FF01h-FF05h a status
;   byte (dl_fb_special); 4000h + address the low byte of a word, read with its high byte in one go and the
;   high byte kept; 2000h + address that high byte (the one kept, when its low byte was the byte just before).
;   A word sent a byte at a time otherwise pairs one reading's low byte with the next one's high byte: the
;   crank period read that way can jump by 256 counts for a frame.
;
; Receive states (r0): 0 a command, 1-3 the stream's channel list (dlstream.asm), 4-5 a serial input
; (dlserialin.asm), 6-8 a memory read (dlmemread.asm).
; ==================================================================================================
ifdef NEED_DATALOG

if XP == XP_DEFS
ifndef NEED_SERIAL_RX
define NEED_SERIAL_RX
endif
ifndef NEED_SERIAL_TX
define NEED_SERIAL_TX
endif
; RAM (bank 6Fh = 378h-37Fh is the one stock P30 gave its serial link)
DL_BANK         EQU     0006fh
DL_STATE        EQU     00378h
DL_KEEP         EQU     00376h          ; word: a word's high byte kept between its two bytes (and the stream's tick)
DL_LOW          EQU     00374h          ; the first of datalog RAM below the bank (374h-377h, dlstream.asm)
                                        ; r0: receive state: 0 command, 1 count, 2 addresses, 3 checksum (the stream's list)
DL_RXCNT        EQU     DL_STATE + 1    ; r1: address bytes received
DL_MODE         EQU     DL_STATE + 2    ; r2: what is being sent: 0 nothing, 1 frame 20h, 2 stream, 3 one stream frame,
                                        ;     4 packet 40h, 5 ident, 6 QD3 frame, 7 a memory block, 8 the trigger log
DL_POS          EQU     DL_STATE + 3    ; r3: position in what is being sent
DL_SUM          EQU     DL_STATE + 4    ; r4: running checksum
DL_NCH          EQU     DL_STATE + 5    ; r5: channels in the stream list
DL_SEQ          EQU     DL_STATE + 6    ; r6: stream frame counter
                                        ; (r7 of this bank is not free: P30, a pointer register set; P13, a timer)
DL_BUDGET       EQU     MODRAM_NEXT     ; module RAM: bytes that may still go before the next spark calculation
undef MODRAM_NEXT
define MODRAM_NEXT (DL_BUDGET + 1)
endif

if XP == XP_BOOT
                CAL     dl_init
endif

if XP == XP_IGN
                CAL     dl_budget              ; every spark calculation: the bytes that may go before the next
endif

if XP == XP_MAIN
                CAL     dl_budget_stopped      ; the engine stopped: no spark calculations, the main loop's pass instead
endif

if XP == XP_CAL
;@ DatalogFast type=u8 flag=1 on=1 off=0 category="Datalog" slot=datalog.fast desc="The datalog line at 62,500 baud instead of 38,400 (39,063 really): each frame comes in sooner, and more of them with the engine stopped. With the engine running, how many bytes go is set by the ECU's own pacing (a few each time it works out the spark), not the line. Only with a cable that can be set to 62,500 exactly (an FTDI one can; 57,600 will not do), with the same rate picked in Settings > Datalog. HTS and other loggers, and a Demon, want 38,400: leave this off for them. Takes effect at the next power-up."
dl_fast:        DB  000h
if defined(FEAT_DATALOG)
;@ DatalogTable type=u16 count=51 category="Datalog" desc="RAM address sent as each byte of the 51-byte 20h frame (FF0xh: a status byte, FExxh: the constant xx, 0: always 00h; 4000h + address: a word's low byte, read with its high byte, and 2000h + address: that high byte, so the two are one reading)."
dl_frame_table:
                DW  000c1h, 000c0h, 003beh, 00000h, 000a3h, 000b9h, 040ach, 020adh   ;  0 ECT, IAT, O2, baro, MAP, TPS, rpm period lo/hi
if defined(FEAT_STOCK_DTC)
                DW  0ff01h, 00000h, 00000h, 0ff04h, 0031ah, 0031bh, 0031ch, 0031dh   ;  8 status, 11 service state, 12-15 stored codes
else
                DW  0ff01h, 00000h, 00000h, 0ff04h, 00000h, 00000h, 00000h, 00000h   ;  8 status, 11 service state (no codes kept)
endif
                DW  000b4h, 04146h, 02147h, 00246h, 00247h, 0ff02h, 0ff03h, 00000h   ; 16 speed, injector word, advance, advance 2, switches, pump
                DW  00000h, 000c3h, 0024fh, 00000h, 00000h, 00000h, 00000h, 00000h   ; 24 ELD, battery, gear
                DW  00000h, 00000h, 00000h, 00000h, 00000h, 00000h, 00000h, 00000h   ; 32
                DW  00000h, 00000h, 00000h, 00000h, 00000h, 00000h, 00000h, 00000h   ; 40
                DW  00000h, 040c8h, 020c9h                                           ; 48 IACV duty word
endif
endif

if XP == XP_CODE
; ------------------------------------------------------------------ power-up
; The baud rate is the machine clock (2.5 MHz) / 8 / (256 - the reload): F8h 39,063 (the "38400" every logger uses,
; 1.7 % off, well inside what a UART takes), FBh 62,500 exactly. FCh 78,125 and FDh 104,167 work too, but with the
; byte budget (below) setting how much goes, a faster line only makes each byte arrive sooner.
dl_init:
                LCB     A, dl_fast
                LB      A, ACC                 ; (byte mode: LCB leaves the mode as it was)
                JEQ     dl_init_38k
                LB      A, #0fbh               ; 62,500 baud (DatalogFast)
                SJ      dl_init_baud
dl_init_38k:    LB      A, #0f8h               ; 38400 baud (the HTS setting)
dl_init_baud:   STB     A, STTM
                STB     A, STTMR
                MOVB    STTMC, #012h
                MOVB    STCON, #01ch
                MOVB    SRCON, #08ch
                L       A, DP
                PUSHS   A
                MOV     DP, #00374h
dl_init_clear:  MOVB    [DP], #000h            ; 374h-37Eh
                INC     DP
                CMP     DP, #0037fh
                JNE     dl_init_clear
                POPS    A
                MOV     DP, A
                RT

; ------------------------------------------------------------------ receive interrupt
mod_serial_rx:
                L       A, 0f4h
                ST      A, IE
                MOV     PSW, #00102h
                MOV     LRB, #DL_BANK          ; r0-r6 = 378h-37Eh
                L       A, DP
                PUSHS   A
                CLR     A
                LB      A, SRBUF
                CMPB    r0, #000h
                JEQ     dl_rx_command
if defined(FEAT_DLSERIALIN) || defined(FEAT_DLMEMREAD) || defined(FEAT_REMOTE)
                CMPB    r0, #004h
                JLT     dl_rx_inlist
                J       dl_rx_more             ; states 4 and up: a serial input, a memory read, a remote value
dl_rx_inlist:
endif
if defined(FEAT_DLSTREAM)
                J       dl_rx_list             ; a byte of the stream's channel list (dlstream.asm)
else
                MOVB    r0, #000h
                J       dl_rx_ret
endif
; a command byte
dl_rx_command:
if defined(FEAT_DLSERIALIN)
                CMPB    A, #0ffh               ; FFh: a serial input follows (dlserialin.asm); a running stream goes on
                JNE     dl_rx_notin
                MOVB    r0, #004h
                J       dl_rx_ret
dl_rx_notin:
endif
if defined(FEAT_DLSTREAM)
                CMPB    r2, #002h              ; a byte from the logger ends a running stream
                JNE     dl_rx_cmd
                CMPB    A, #071h
                JEQ     dl_rx_ret
                MOVB    r2, #000h
endif
dl_rx_cmd:
if defined(FEAT_DLMEMREAD)
                CMPB    A, #060h               ; 60h: a block of RAM (dlmemread.asm)
                JNE     dl_rx_notmem
                J       dl_rx_memcmd
dl_rx_notmem:
endif
if defined(FEAT_DLSERVICE)
                CMPB    A, #063h               ; 63h-67h: the cylinder test (dlservice.asm)
                JLT     dl_rx_notcyl
                CMPB    A, #068h
                JGE     dl_rx_notcyl
                J       dl_rx_cylcut
dl_rx_notcyl:
endif
if defined(FEAT_TRIGLOG)
                CMPB    A, #061h               ; 61h / 62h: the trigger pattern log (triglog.asm)
                JNE     dl_rx_nottrg1
                J       dl_rx_trgarm
dl_rx_nottrg1:  CMPB    A, #062h
                JNE     dl_rx_nottrg2
                J       dl_rx_trgread
dl_rx_nottrg2:
endif
if defined(FEAT_DATALOG)
                CMPB    A, #010h               ; the HTS / ISR frame
                JEQ     dl_rx_hello
                CMPB    A, #0abh
                JEQ     dl_rx_hello
                CMPB    A, #020h
                JEQ     dl_rx_frame
                CMPB    A, #090h
                JEQ     dl_rx_frame
                CMPB    A, #040h
                JEQ     dl_rx_packet
endif
if defined(FEAT_DLQD3)
                CMPB    A, #0abh               ; the QD3 frame (dlqd3.asm)
                JNE     dl_rx_notab
                J       dl_rx_qd3hello
dl_rx_notab:    CMPB    A, #046h
                JNE     dl_rx_notqd3
                J       dl_rx_qd3
dl_rx_notqd3:
endif
if defined(FEAT_DLSTREAM)
                CMPB    A, #070h               ; 70h-7Fh: the channel stream (dlstream.asm)
                JLT     dl_rx_notstream
                CMPB    A, #080h
                JGE     dl_rx_notstream
                J       dl_rx_streamcmd
dl_rx_notstream:
endif
if defined(FEAT_REMOTE)
                CMPB    A, #02bh               ; 2Bh-3Fh: the remote control commands (remote.asm)
                JLT     dl_rx_notrc
                CMPB    A, #040h
                JGE     dl_rx_notrc
                J       dl_rx_remote
dl_rx_notrc:
endif
if defined(FEAT_DLSERVICE)
                CMPB    A, #050h               ; 50h-5Fh: the service commands (dlservice.asm)
                JLT     dl_rx_notsvc
                CMPB    A, #060h
                JGE     dl_rx_notsvc
                J       dl_rx_service
dl_rx_notsvc:
endif
if defined(FEAT_DATALOG)
                CMPB    A, #0c0h
                JLT     dl_rx_ret
                SUBB    A, #0c0h               ; C0h+n: byte n of the frame
                CMPB    A, #033h
                JGE     dl_rx_ret
                CAL     dl_frame_byte
                SJ      dl_rx_send
dl_rx_hello:    LB      A, #0cdh
                SJ      dl_rx_send
endif
                SJ      dl_rx_ret              ; nothing this ROM answers
dl_rx_send:     STB     A, STBUF               ; one byte: nothing follows it
                MOVB    r2, #000h
dl_rx_ret:      POPS    A
                MOV     DP, A
                L       A, 0f2h
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
if defined(FEAT_DATALOG)
dl_rx_frame:    MOVB    r2, #001h
                SJ      dl_rx_start
dl_rx_packet:   MOVB    r2, #004h
endif
; start sending what r2 says, from its first byte (the other parts come here too)
dl_rx_start:    RB      0fdh.7                 ; (the line is busy again: the spark calculation must not send)
                MOVB    r3, #000h
                MOVB    r4, #000h
                CAL     dl_next
                SJ      dl_rx_ret
if defined(FEAT_DLSERIALIN) || defined(FEAT_DLMEMREAD) || defined(FEAT_REMOTE)
; receive states 4 and up
dl_rx_more:
if defined(FEAT_REMOTE)
                CMPB    r0, #009h              ; 9-12 (remote.asm)
                JLT     dl_rx_more_lo
                J       dl_rx_rcarg
dl_rx_more_lo:
endif
if defined(FEAT_DLSERIALIN)
                CMPB    r0, #006h
                JGE     dl_rx_more6
                J       dl_rx_serin            ; 4-5 (dlserialin.asm)
dl_rx_more6:
endif
if defined(FEAT_DLMEMREAD)
                J       dl_rx_memrd            ; 6-8 (dlmemread.asm)
else
                MOVB    r0, #000h
                J       dl_rx_ret
endif
endif

; ------------------------------------------------------------------ transmit-complete interrupt
mod_serial_tx:
                L       A, 0f4h
                ST      A, IE
                MOV     PSW, #00102h
                MOV     LRB, #DL_BANK
                L       A, DP
                PUSHS   A
                MOV     DP, #DL_BUDGET         ; the byte budget (below): spent, and the line rests until the next
                LB      A, [DP]                ; spark calculation sends on
                JNE     dl_tx_ok
                SB      0fdh.7
                J       dl_rx_ret
dl_tx_ok:       SUBB    A, #001h
                STB     A, [DP]
if defined(FEAT_DLSTREAM)
                CMPB    r2, #002h              ; streaming a version 4 list (75h): the short way (dlstream.asm)
                JNE     dl_tx_any
                J       dl5_tx
endif
dl_tx_any:      CAL     dl_next
                J       dl_rx_ret

; ------------------------------------------------------------------ the byte budget (every spark calculation, main loop)
; At high rpm the interrupts leave the main loop (the spark calculation, the idle valve, the fail-safes) little time:
; in the simulator at 8000 rpm about a tenth of it. Every byte sent costs the transmit interrupt about 0.1 ms, and a
; stream (or a logger asking for frame after frame) sent flat out took most of what was left - the spark worked out 3
; times a second instead of 19. So each spark calculation (XP_IGN) sets how many bytes may go before the next one,
; fewer the higher the rpm (with the engine stopped, the main loop's pass does); the transmit interrupt spends one a byte, and with none left sends nothing (0FDh bit 7: a
; byte waiting) - the next calculation sends it, here, with the interrupts off so nothing else is sending. Bytes, not
; frames: a frame spread over a few calculations never lands on one in a lump. A main loop that stops stops the line.
; Measured in the simulator (SkeletonTest --dlrate): the longest wait between two spark calculations, and how often
; the spark is worked out, as with no logging at all (within the simulator's own rpm-to-rpm spread), at any rpm and
; either line speed.
dl_budget:      L       A, DP
                PUSHS   A
                L       A, ENG_RPMP                ; the crank period: larger is slower
                CMP     A, #004e2h             ; under 1500 rpm (FFFFh, no reading, too): 32 bytes, the CPU mostly free
                JGE     dl_budget_32
                CMP     A, #00218h             ; 1500-3500 rpm: 8
                JGE     dl_budget_8
                CMP     A, #00177h             ; 3500-5000 rpm: 4
                JGE     dl_budget_4
                CMP     A, #00120h             ; 5000-6500 rpm: 2
                JGE     dl_budget_2
                LB      A, #001h               ; over 6500 rpm: 1
                SJ      dl_budget_set
dl_budget_2:    LB      A, #002h
                SJ      dl_budget_set
dl_budget_4:    LB      A, #004h
                SJ      dl_budget_set
dl_budget_8:    LB      A, #008h
                SJ      dl_budget_set
dl_budget_32:   LB      A, #020h
dl_budget_set:  MOV     DP, #DL_BUDGET
                STB     A, [DP]
                MB      C, 0fdh.7              ; a byte waiting for it?
                JGE     dl_budget_ret
                L       A, PSW                 ; the interrupts as they were, put back after
                PUSHS   A
                RB      PSWH.0                 ; interrupts off
                MB      C, 0fdh.7              ; (still waiting: a byte from the logger may have started something)
                JGE     dl_budget_on
                RB      0fdh.7
                MOV     DP, #DL_BUDGET
                LB      A, [DP]
                SUBB    A, #001h
                STB     A, [DP]
                PUSHS   LRB
                MOV     LRB, #DL_BANK
                CAL     dl_next                ; the byte; the transmit interrupt sends the rest
                POPS    LRB
dl_budget_on:   POPS    A
                ST      A, PSW
dl_budget_ret:  POPS    A
                MOV     DP, A
                RT
; The engine stopped (or cranking under 400 rpm, or no reading): the spark is not worked out, so the main loop's
; every pass gives the budget instead - the CPU has time to spare, and the logger still hears the ECU with the key on.
dl_budget_stopped:
                L       A, ENG_RPMP
                CMP     A, #01250h             ; (400 rpm)
                JLT     dl_budget_none
                J       dl_budget
dl_budget_none: RT

; ------------------------------------------------------------------ the next byte of whatever is being sent (bank 6Fh)
dl_next:        CLR     A
                LB      A, r2
                JNE     dl_next_go
                RT
dl_next_go:
if defined(FEAT_DATALOG)
                CMPB    A, #001h
                JEQ     dl_next_frame
                CMPB    A, #004h
                JEQ     dl_next_packet
endif
if defined(FEAT_DLQD3)
                CMPB    A, #006h
                JNE     dl_next_notqd3
                J       dl_next_qd3            ; dlqd3.asm
dl_next_notqd3:
endif
if defined(FEAT_DLMEMREAD)
                CMPB    A, #007h
                JNE     dl_next_notmem
                J       dl_next_mem            ; dlmemread.asm
dl_next_notmem:
endif
if defined(FEAT_TRIGLOG)
                CMPB    A, #008h
                JNE     dl_next_nottrg
                J       dl_next_trg            ; triglog.asm
dl_next_nottrg:
endif
if defined(FEAT_DLSTREAM)
                J       dl_next_stream         ; 2, 3, 5: dlstream.asm
else
                MOVB    r2, #000h              ; nothing else is sent
                RT
endif
if defined(FEAT_DATALOG)
; the 51-byte frame and its checksum (the sum of the 51 bytes)
dl_next_frame:  LB      A, r3
                CMPB    A, #033h
                JGE     dl_next_fsum
                CAL     dl_frame_byte
                SJ      dl_next_put
endif
; the sum of what was sent, and the end
dl_next_fsum:   LB      A, r4
                MOVB    r2, #000h
                SJ      dl_next_out
if defined(FEAT_DATALOG)
; HTS120 40h packet: TC retard, status, gear, raw TPS, checksum
dl_next_packet: LB      A, r3
                CMPB    A, #004h
                JGE     dl_next_fsum
                CMPB    A, #002h
                JLT     dl_next_zero
                JNE     dl_next_ptps
                LB      A, off(0024fh)
                SJ      dl_next_put
dl_next_ptps:   LB      A, ENG_TPS
                SJ      dl_next_put
dl_next_zero:   CLRB    A
                SJ      dl_next_put
endif
; one byte out, counted in the checksum
dl_next_put:    STB     A, STBUF
                ADDB    r4, A
                INCB    r3
dl_next_ret:    RT
dl_next_out:    STB     A, STBUF
                RT

if defined(FEAT_DATALOG)
; byte A (0-50) of the 51-byte frame, from dl_frame_table
dl_frame_byte:  L       A, ACC
                SLL     A
                MOV     DP, A
                LC      A, dl_frame_table[DP]
                SJ      dl_fetch
endif
; the byte at address A (word): 0 is always 00h, FExxh the constant xx, FF0xh a status byte, 4000h + address a
; word's low byte (its high byte kept), 2000h + address that high byte. Uses DP (and 376h-377h for the word).
dl_fetch:       CMP     A, #01000h             ; a RAM or SFR address (the most of them) first
                JGE     dl_fb_notram
                CMP     A, #00000h
                JEQ     dl_fb_zero
                MOV     DP, A
                LB      A, [DP]
                RT
dl_fb_notram:   CMP     A, #0fe00h
                JGE     dl_fb_high
                CMP     A, #02000h
                JGE     dl_fb_word
                SJ      dl_fb_user
dl_fb_zero:     CLRB    A
                RT
; 1000h + n: the RAM address picked in DatalogUserAddress n+1 (dlextra.asm); 00h when it is not a RAM address
; (80h-47Fh: a special function register could be upset by being read)
dl_fb_user:
if defined(FEAT_DLEXTRA)
                AND     A, #00007h
                SLL     A
                MOV     DP, A
                LC      A, dlx_user[DP]
                CMP     A, #00080h
                JLT     dl_fb_zero
                CMP     A, #00480h
                JGE     dl_fb_zero
                MOV     DP, A
                LB      A, [DP]
                RT
else
                SJ      dl_fb_zero
endif
; a word's low byte: both bytes read at once, the high one kept in 377h and 376h 00h (FFh: nothing kept). Every
; table has a word's 2000h entry straight after its 4000h one, so what is kept is that word's. The tick latched
; at a stream frame's start lives there too, sent before any channel (and 376h set FFh after it).
dl_fb_word:     CMP     A, #04000h
                JLT     dl_fb_whigh
                AND     A, #01fffh
                MOV     DP, A
                L       A, [DP]                ; the word, in one read
                MOV     DP, #DL_KEEP
                ST      A, [DP]                ; 377h: its high byte
                MOVB    [DP], #000h            ; 376h: kept
                LB      A, ACC                 ; its low byte
                RT
; a word's high byte: the one kept with its low byte (once), else read now
dl_fb_whigh:    AND     A, #01fffh
                PUSHS   A                      ; its address (word mode)
                MOV     DP, #DL_KEEP
                LB      A, [DP]
                JNE     dl_fb_wread
                MOVB    [DP], #0ffh            ; used: nothing kept now
                INC     DP
                POPS    A
                LB      A, [DP]
                RT
dl_fb_wread:    POPS    A                      ; not kept: read now
                MOV     DP, A
                LB      A, [DP]
                RT
dl_fb_high:     CMP     A, #0ff00h
                JGE     dl_fb_special
                LB      A, ACC                 ; FExxh: the constant
                RT
dl_fb_special:  LB      A, ACC
                CMPB    A, #002h
                JEQ     dl_fb_switch
                JLT     dl_fb_status
                CMPB    A, #004h
                JLT     dl_fb_pump
                JEQ     dl_fb_service
                CLRB    A                      ; FF05h: bit 0 VTEC solenoid on (the QD3 frame's layout)
                MB      C, P1.0
                MB      ACC.0, C
                RT
dl_fb_service:                                 ; FF04h: the service state (dlservice.asm; 00h without it)
if defined(FEAT_DLSERVICE)
                MOV     DP, #DL_SVC
                LB      A, [DP]
else
                CLRB    A
endif
                RT
dl_fb_status:   CLRB    A                      ; FF01h: status, bit 3 VTEC solenoid on, 4 check-engine lamp lit,
                MB      C, P1.0                ; 5 injectors off, 6 timing locked (the service commands)
                MB      ACC.3, C
                MB      C, P1.4
                MB      ACC.4, C
if defined(FEAT_DLSERVICE)
                MOV     DP, #DL_SVC
                MB      C, [DP].0
                MB      ACC.5, C
                MB      C, [DP].1
                MB      ACC.6, C
endif
                RT
dl_fb_switch:   CLRB    A                      ; FF02h: bit 0 park/neutral, bit 1 brake, bit 2 A/C request
                MB      C, off(00211h).5
                MB      ACC.0, C
                MB      C, off(00211h).4
                MB      ACC.1, C
                MB      C, off(00211h).2
                MB      ACC.2, C
                RT
dl_fb_pump:     CLRB    A                      ; FF03h: bit 0 fuel pump on (P0.7 low)
                MB      C, P0.7
                XORB    PSWH, #080h
                MB      ACC.0, C
                RT
endif

endif
