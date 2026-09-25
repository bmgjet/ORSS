; ==================================================================================================
; datalog.asm - serial datalogging: the HTS / ISR frame, and a subscription stream
;> feature: FEAT_DATALOG
;> name: Datalogging (HTS compatible + channel stream)
;> category: Diagnostics
;> conflicts: FEAT_STOCK_SERIAL
;> ram: 374h-377h, 378h-37Eh (bank 6Fh), 3E0h-3EFh
;> about: 38400 baud on the datalog pins (the HTS wiring). Existing loggers work unchanged:
;>        10h (or ABh) -> CDh, then 20h (or 90h) -> the 51-byte frame and its checksum, C0h+n -> byte n
;>        of it, 40h -> the HTS120 extra packet. The channel stream is for logging only what you need, as
;>        fast as the line allows: the logger sends the RAM addresses it wants and the ECU sends them
;>        back in frames stamped with the ECU's own 2.048 ms tick.
;
; Channel stream protocol
;   7Eh                          identify: 7Eh, version 01h, most channels 08h, 00h, checksum
;   70h N a1lo a1hi .. aNlo aNhi chk
;                                set the channel list (N = 0-8 RAM or SFR addresses). chk makes the
;                                sum of N, the address bytes and chk 00h. Answer 70h (taken) or 7Fh
;                                (refused: N over 8 or a bad checksum).
;   71h                          stream frames back to back until any other byte arrives
;   72h                          send one frame
;   frame: A5h, seq, tick lo, tick hi, the N channel bytes, chk (the sum of the whole frame is 00h)
;   seq counts frames (a gap in it is a lost frame); the tick is RAM 0FEh-0FFh when the frame started.
; ==================================================================================================
ifdef FEAT_DATALOG

if XP == XP_DEFS
ifndef NEED_SERIAL_RX
define NEED_SERIAL_RX
endif
ifndef NEED_SERIAL_TX
define NEED_SERIAL_TX
endif
; RAM (bank 6Fh = 378h-37Fh is the one stock P30 gave its serial link)
DL_STATE        EQU     00378h          ; r0: receive state: 0 command, 1 count, 2 addresses, 3 checksum
DL_RXCNT        EQU     00379h          ; r1: address bytes received
DL_MODE         EQU     0037ah          ; r2: what is being sent: 0 nothing, 1 frame 20h, 2 stream, 3 one stream frame, 4 packet 40h, 5 ident
DL_POS          EQU     0037bh          ; r3: position in what is being sent
DL_SUM          EQU     0037ch          ; r4: running checksum
DL_NCH          EQU     0037dh          ; r5: channels in the stream list
DL_SEQ          EQU     0037eh          ; r6: stream frame counter
DL_NEWN         EQU     00374h          ; channels in the list being received
DL_RXSUM        EQU     00375h          ; its checksum
DL_TICK         EQU     00376h          ; tick word latched when a frame starts
DL_LIST         EQU     003e0h          ; the channel addresses, a word each
endif

if XP == XP_BOOT
                CAL     dl_init
endif

if XP == XP_CAL
;@ DatalogTable type=u16 count=51 category="Datalog" desc="RAM address sent as each byte of the 51-byte 20h frame (FF0xh: a status byte, 0: always 00h)."
dl_frame_table:
                DW  000c1h, 000c0h, 003beh, 00000h, 000a3h, 000b9h, 000ach, 000adh   ;  0 ECT, IAT, O2, baro, MAP, TPS, rpm period lo/hi
                DW  0ff01h, 00000h, 00000h, 00000h, 00000h, 00000h, 00000h, 00000h   ;  8 status (bit 3 VTEC)
                DW  000b4h, 00146h, 00147h, 00246h, 00247h, 0ff02h, 0ff03h, 00000h   ; 16 speed, injector word, advance, advance 2, switches, pump
                DW  00000h, 000c3h, 0024fh, 00000h, 00000h, 00000h, 00000h, 00000h   ; 24 ELD, battery, gear
                DW  00000h, 00000h, 00000h, 00000h, 00000h, 00000h, 00000h, 00000h   ; 32
                DW  00000h, 00000h, 00000h, 00000h, 00000h, 00000h, 00000h, 00000h   ; 40
                DW  00000h, 000c8h, 000c9h                                           ; 48 IACV duty word
endif

if XP == XP_CODE
; ------------------------------------------------------------------ power-up
dl_init:        MOVB    STTM, #0f8h            ; 38400 baud (the HTS setting)
                MOVB    STTMR, #0f8h
                MOVB    STTMC, #012h
                MOVB    STCON, #01ch
                MOVB    SRCON, #08ch
                L       A, DP
                PUSHS   A
                MOV     DP, #DL_NEWN
dl_init_clear:  MOVB    [DP], #000h            ; 374h-37Eh
                INC     DP
                CMP     DP, #0037fh
                JNE     dl_init_clear
                POPS    A
                MOV     DP, A
                RT

; ------------------------------------------------------------------ receive interrupt
mod_serial_rx:  L       A, 0f4h
                ST      A, IE
                MOV     PSW, #00102h
                MOV     LRB, #0006fh           ; r0-r6 = 378h-37Eh
                L       A, DP
                PUSHS   A
                CLR     A
                LB      A, SRBUF
                CMPB    r0, #000h
                JNE     dl_rx_list
; a command byte
                CMPB    r2, #002h              ; a byte from the logger ends a running stream
                JNE     dl_rx_cmd
                CMPB    A, #071h
                JEQ     dl_rx_ret
                MOVB    r2, #000h
dl_rx_cmd:      CMPB    A, #010h
                JEQ     dl_rx_hello
                CMPB    A, #0abh
                JEQ     dl_rx_hello
                CMPB    A, #020h
                JEQ     dl_rx_frame
                CMPB    A, #090h
                JEQ     dl_rx_frame
                CMPB    A, #040h
                JEQ     dl_rx_packet
                CMPB    A, #070h
                JEQ     dl_rx_setlist
                CMPB    A, #071h
                JEQ     dl_rx_stream
                CMPB    A, #072h
                JEQ     dl_rx_oneframe
                CMPB    A, #07eh
                JEQ     dl_rx_ident
                CMPB    A, #0c0h
                JLT     dl_rx_ret
                SUBB    A, #0c0h               ; C0h+n: byte n of the frame
                CMPB    A, #033h
                JGE     dl_rx_ret
                CAL     dl_frame_byte
                SJ      dl_rx_send
dl_rx_hello:    LB      A, #0cdh
dl_rx_send:     STB     A, STBUF               ; one byte: nothing follows it
                MOVB    r2, #000h
dl_rx_ret:      POPS    A
                MOV     DP, A
                L       A, 0f2h
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
dl_rx_frame:    MOVB    r2, #001h
                SJ      dl_rx_start
dl_rx_packet:   MOVB    r2, #004h
                SJ      dl_rx_start
dl_rx_ident:    MOVB    r2, #005h
                SJ      dl_rx_start
dl_rx_stream:   MOVB    r2, #002h
                SJ      dl_rx_start
dl_rx_oneframe: MOVB    r2, #003h
dl_rx_start:    MOVB    r3, #000h
                MOVB    r4, #000h
                CAL     dl_next
                SJ      dl_rx_ret
dl_rx_setlist:  MOVB    r0, #001h
                SJ      dl_rx_ret
; the channel list, one byte at a time
dl_rx_list:     PUSHS   A                      ; keep the byte
                MOV     DP, #DL_RXSUM
                ADDB    A, [DP]                ; it counts towards the checksum
                STB     A, [DP]
                POPS    A
                LB      A, ACC
                CMPB    r0, #001h
                JNE     dl_rx_addr
                CMPB    A, #009h               ; the count: 0-8
                JGE     dl_rx_refuse
                MOV     DP, #DL_NEWN
                STB     A, [DP]
                MOVB    r1, #000h
                MOVB    r0, #002h
                CMPB    A, #000h
                JNE     dl_rx_ret
                MOVB    r0, #003h              ; no addresses: the checksum is next
                SJ      dl_rx_ret
dl_rx_addr:     CMPB    r0, #002h
                JNE     dl_rx_check
                PUSHS   A
                CLR     A
                LB      A, r1
                L       A, ACC
                ADD     A, #DL_LIST
                MOV     DP, A
                POPS    A
                LB      A, ACC
                STB     A, [DP]                ; the address byte
                INCB    r1
                MOV     DP, #DL_NEWN
                LB      A, [DP]
                SLLB    A
                CMPB    A, r1
                JNE     dl_rx_ret
                MOVB    r0, #003h
                SJ      dl_rx_ret
dl_rx_check:    MOVB    r0, #000h
                MOV     DP, #DL_RXSUM
                LB      A, [DP]
                MOVB    [DP], #000h
                CMPB    A, #000h
                JNE     dl_rx_refuse2
                MOV     DP, #DL_NEWN
                LB      A, [DP]
                STB     A, r5                  ; the new list is used from the next frame on
                LB      A, #070h
                J       dl_rx_send
dl_rx_refuse:   MOVB    r0, #000h
                MOV     DP, #DL_RXSUM
                MOVB    [DP], #000h
dl_rx_refuse2:  LB      A, #07fh
                J       dl_rx_send

; ------------------------------------------------------------------ transmit-complete interrupt
mod_serial_tx:  L       A, 0f4h
                ST      A, IE
                MOV     PSW, #00102h
                MOV     LRB, #0006fh
                L       A, DP
                PUSHS   A
                CAL     dl_next
                J       dl_rx_ret

; ------------------------------------------------------------------ the next byte of whatever is being sent (bank 6Fh)
dl_next:        CLR     A
                LB      A, r2
                JNE     dl_next_go
                RT
dl_next_go:
                CMPB    A, #001h
                JEQ     dl_next_frame
                CMPB    A, #004h
                JEQ     dl_next_packet
                CMPB    A, #005h
                JEQ     dl_next_ident
; stream frame: A5h, seq, tick lo, tick hi, channels, checksum
                LB      A, r3
                JNE     dl_next_s1
                MOV     DP, #DL_TICK           ; frame start: latch the tick
                L       A, 0feh
                ST      A, [DP]
                LB      A, #0a5h
                SJ      dl_next_put
dl_next_s1:     CMPB    A, #001h
                JNE     dl_next_s2
                INCB    r6
                LB      A, r6
                SJ      dl_next_put
dl_next_s2:     CMPB    A, #004h
                JGE     dl_next_s4
                SUBB    A, #002h               ; 0: tick lo, 1: tick hi
                L       A, ACC
                MOV     DP, #DL_TICK
                ADD     DP, A
                LB      A, [DP]
                SJ      dl_next_put
dl_next_s4:     SUBB    A, #004h               ; channel index
                CMPB    A, r5
                JGE     dl_next_scheck
                L       A, ACC
                SLL     A
                MOV     DP, #DL_LIST
                ADD     DP, A
                L       A, [DP]                ; the channel's address
                MOV     DP, A
                LB      A, [DP]
                SJ      dl_next_put
dl_next_scheck: CLRB    A
                SUBB    A, r4                  ; the byte that makes the frame sum to 00h
                MOVB    r3, #000h              ; frame done
                MOVB    r4, #000h
                CMPB    r2, #002h              ; streaming: the next frame follows
                JEQ     dl_next_out
                MOVB    r2, #000h
                SJ      dl_next_out
; the 51-byte frame and its checksum (the sum of the 51 bytes)
dl_next_frame:  LB      A, r3
                CMPB    A, #033h
                JGE     dl_next_fsum
                CAL     dl_frame_byte
                SJ      dl_next_put
dl_next_fsum:   LB      A, r4
                MOVB    r2, #000h
                SJ      dl_next_out
; HTS120 40h packet: TC retard, status, gear, raw TPS, checksum
dl_next_packet: LB      A, r3
                CMPB    A, #004h
                JGE     dl_next_fsum
                CMPB    A, #002h
                JLT     dl_next_zero
                JNE     dl_next_ptps
                LB      A, off(0024fh)
                SJ      dl_next_put
dl_next_ptps:   LB      A, 0b9h
                SJ      dl_next_put
dl_next_zero:   CLRB    A
                SJ      dl_next_put
; identify: 7Eh, version, most channels, 00h, checksum (sum 00h)
dl_next_ident:  LB      A, r3
                CMPB    A, #004h
                JEQ     dl_next_scheck
                MOV     DP, A
                LCB     A, dl_ident[DP]
dl_next_put:    STB     A, STBUF
                ADDB    r4, A
                INCB    r3
dl_next_ret:    RT
dl_next_out:    STB     A, STBUF
                RT

; byte A (0-50) of the 51-byte frame, from dl_frame_table
dl_frame_byte:  L       A, ACC
                SLL     A
                MOV     DP, A
                LC      A, dl_frame_table[DP]
                JEQ     dl_fb_zero
                CMP     A, #0ff00h
                JGE     dl_fb_special
                MOV     DP, A
                LB      A, [DP]
                RT
dl_fb_zero:     CLRB    A
                RT
dl_fb_special:  LB      A, ACC
                CMPB    A, #002h
                JEQ     dl_fb_switch
                JGT     dl_fb_pump
                CLRB    A                      ; FF01h: status, bit 3 = VTEC solenoid on
                MB      C, P1.0
                MB      ACC.3, C
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
dl_ident:       DB      07eh, 001h, 008h, 000h
endif

endif
