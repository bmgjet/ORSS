; ==================================================================================================
; dlstream.asm - datalogging: the channel stream
;> feature: FEAT_DLSTREAM
;> name: Datalogging: channel stream
;> category: Diagnostics
;> conflicts: FEAT_STOCK_SERIAL
;> ram: 374h-377h, 3E0h-3EFh
;> about: Logging only what you need, as fast as the line allows: the logger sends the channels it wants and
;>        the ECU streams them back in frames stamped with its own 2.048 ms tick (Datalogging > Channels…
;>        picks them). The app's own protocol, and the fastest; the HTS frame still answers alongside it.
;
; Channel stream protocol
;   7Eh                          identify: 7Eh, version 03h, most channels 10h (8 by address), 00h, checksum
;   70h N a1lo a1hi .. aNlo aNhi chk
;                                set the channel list (N = 0-8 RAM or SFR addresses). chk makes the
;                                sum of N, the address bytes and chk 00h. Answer 70h (taken) or 7Fh
;                                (refused: N over 8 or a bad checksum).
;   71h                          stream frames back to back until any other byte arrives
;   72h                          send one frame
;   73h N c1 .. cN chk           set the channel list as channel numbers (N = 0-16) from dl_channels, the
;                                table below (version 2): more channels in the same RAM. Answer 70h or 7Fh.
;   frame: A5h, seq, tick lo, tick hi, the N channel bytes, chk (the sum of the whole frame is 00h)
;   seq counts frames (a gap in it is a lost frame); the tick is RAM 0FEh-0FFh when the frame started.
;   Version 3 adds channels 35-39: the service state and the four stored trouble-code bytes.
; ==================================================================================================
ifdef FEAT_DLSTREAM

if XP == XP_DEFS
DL_NEWN         EQU     00374h          ; channels in the list being received; bit 7: the list holds channel numbers (73h), not addresses
DL_RXSUM        EQU     00375h          ; its checksum
DL_TICK         EQU     00376h          ; tick word latched when a frame starts
DL_LIST         EQU     003e0h          ; the channel addresses, a word each (70h), or channel numbers, a byte each (73h)
DL_NCHANNELS    EQU     40              ; entries in dl_channels
endif

if XP == XP_CODE
; ------------------------------------------------------------------ a 70h-7Fh command (datalog.asm's receive interrupt)
; In: A (byte) = the command, bank 6Fh, DP pushed. Leaves through datalog.asm's dl_rx_ret / dl_rx_send / dl_rx_start.
dl_rx_streamcmd:
                CMPB    A, #070h
                JEQ     dl_rx_setlist
                CMPB    A, #071h
                JEQ     dl_rx_stream
                CMPB    A, #072h
                JEQ     dl_rx_oneframe
                CMPB    A, #073h
                JEQ     dl_rx_setids
                CMPB    A, #07eh
                JEQ     dl_rx_ident
                J       dl_rx_ret
dl_rx_ident:    MOVB    r2, #005h
                J       dl_rx_start
dl_rx_stream:   MOVB    r2, #002h
                J       dl_rx_start
dl_rx_oneframe: MOVB    r2, #003h
                J       dl_rx_start
dl_rx_setlist:  MOV     DP, #DL_NEWN           ; RAM addresses
                MOVB    [DP], #000h
                MOVB    r0, #001h
                J       dl_rx_ret
dl_rx_setids:   MOV     DP, #DL_NEWN           ; channel numbers
                MOVB    [DP], #080h
                MOVB    r0, #001h
                J       dl_rx_ret
; the channel list, one byte at a time
dl_rx_list:     PUSHS   A                      ; keep the byte
                MOV     DP, #DL_RXSUM
                ADDB    A, [DP]                ; it counts towards the checksum
                STB     A, [DP]
                POPS    A
                LB      A, ACC
                CMPB    r0, #001h
                JNE     dl_rx_addr
                MOV     DP, #DL_NEWN           ; the count: 0-8 addresses, 0-16 channel numbers
                MB      C, [DP].7
                JLT     dl_rx_count16
                CMPB    A, #009h
                JGE     dl_rx_refuse
                SJ      dl_rx_countok
dl_rx_count16:  CMPB    A, #011h
                JGE     dl_rx_refuse
dl_rx_countok:
                MOV     DP, #DL_NEWN
                ORB     A, [DP]                ; (the kind in bit 7 stays)
                STB     A, [DP]
                ANDB    A, #07fh
                MOVB    r1, #000h
                MOVB    r0, #002h
                CMPB    A, #000h
                JEQ     dl_rx_nolist
                J       dl_rx_ret
dl_rx_nolist:   MOVB    r0, #003h              ; no addresses: the checksum is next
                J       dl_rx_ret
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
                ANDB    A, #07fh
                MB      C, [DP].7              ; addresses: two bytes each
                JLT     dl_rx_idsend
                SLLB    A
dl_rx_idsend:   CMPB    A, r1
                JEQ     dl_rx_listend
                J       dl_rx_ret
dl_rx_listend:  MOVB    r0, #003h
                J       dl_rx_ret
dl_rx_check:    MOVB    r0, #000h
                MOV     DP, #DL_RXSUM
                LB      A, [DP]
                MOVB    [DP], #000h
                CMPB    A, #000h
                JNE     dl_rx_refuse2
                MOV     DP, #DL_NEWN
                LB      A, [DP]
                ANDB    A, #07fh
                STB     A, r5                  ; the new list is used from the next frame on
                LB      A, #070h
                J       dl_rx_send
dl_rx_refuse:   MOVB    r0, #000h
                MOV     DP, #DL_RXSUM
                MOVB    [DP], #000h
dl_rx_refuse2:  LB      A, #07fh
                J       dl_rx_send

; ------------------------------------------------------------------ the next byte of a stream frame or the ident (r2 = 2, 3, 5)
dl_next_stream: CMPB    A, #005h
                JEQ     dl_next_ident
; stream frame: A5h, seq, tick lo, tick hi, channels, checksum
                LB      A, r3
                JNE     dl_next_s1
                MOV     DP, #DL_TICK           ; frame start: latch the tick
                L       A, 0feh
                ST      A, [DP]
                LB      A, #0a5h
                J       dl_next_put
dl_next_s1:     CMPB    A, #001h
                JNE     dl_next_s2
                INCB    r6
                LB      A, r6
                J       dl_next_put
dl_next_s2:     CMPB    A, #004h
                JGE     dl_next_s4
                SUBB    A, #002h               ; 0: tick lo, 1: tick hi
                L       A, ACC
                MOV     DP, #DL_TICK
                ADD     DP, A
                LB      A, [DP]
                J       dl_next_put
dl_next_s4:     SUBB    A, #004h               ; channel index
                CMPB    A, r5
                JGE     dl_next_scheck
                MOV     DP, #DL_NEWN
                MB      C, [DP].7
                JGE     dl_next_addr
                J       dl_next_idch           ; channel numbers (out of line: the branches here are short)
dl_next_addr:   L       A, ACC
                SLL     A
                MOV     DP, #DL_LIST
                ADD     DP, A
                L       A, [DP]                ; the channel's address
                MOV     DP, A
                LB      A, [DP]
                J       dl_next_put
dl_next_scheck: CLRB    A
                SUBB    A, r4                  ; the byte that makes the frame sum to 00h
                MOVB    r3, #000h              ; frame done
                MOVB    r4, #000h
                CMPB    r2, #002h              ; streaming: the next frame follows
                JEQ     dl_next_sout
                MOVB    r2, #000h
dl_next_sout:   J       dl_next_out
; identify: 7Eh, version, most channels, 00h, checksum (sum 00h)
dl_next_ident:  LB      A, r3
                CMPB    A, #004h
                JEQ     dl_next_scheck
                MOV     DP, A
                LCB     A, dl_ident[DP]
                J       dl_next_put
; a stream channel by number (73h list)
dl_next_idch:   STB     A, r1                  ; (r1 is only used while a list is received)
                CLR     A
                LB      A, r1
                L       A, ACC
                MOV     DP, #DL_LIST
                ADD     DP, A
                CLR     A
                LB      A, [DP]                ; the channel number
                CMPB    A, #DL_NCHANNELS
                JLT     dl_next_idok
                CLRB    A                      ; not in the table: 00h
                J       dl_next_put
dl_next_idok:   L       A, ACC
                SLL     A
                MOV     DP, A
                LC      A, dl_channels[DP]
                CAL     dl_fetch
                J       dl_next_put
;@ DatalogIdent type=u8 count=4 formula=raw category="Internal" desc="Datalog: the answer to the channel-stream identify command (not a tuning value)."
dl_ident:       DB      07eh, 003h, 010h, 000h
;@ DatalogChannels type=u16 count=40 formula=raw category="Internal" desc="Datalog: the RAM address of each channel number the 73h list can ask for (the app has the same list; not a tuning value)."
dl_channels:
                DW  000ACh, 000ADh, 000A3h, 000B9h, 000C1h              ;  0 crank period lo, crank period hi, MAP, throttle, coolant
                DW  000C0h, 000C3h, 000B4h, 000A4h, 003BEh              ;  5 intake air, battery, road speed, baro, O2
                DW  003C6h, 00146h, 00147h, 00246h, 000A7h              ; 10 ELD, injector lo, injector hi, advance, load byte
                DW  002FEh, 0FF01h, 0FF02h, 0FF03h, 000C8h              ; 15 gear, status: VTEC, switches, fuel pump, idle valve lo
                DW  000C9h, 002FDh, 002FCh, MOD_RAM_BASE, MOD_RAM_BASE + 1 ; 20 idle valve hi, retard request, advance request, fuel trim lo, fuel trim hi (lib.asm's MOD_FUELSUM)
                DW  001F0h, 000FCh, 001F1h, 000FDh, 00020h              ; 25 fuel cut request, spark cut request, module outputs, module flags, P0 latch
                DW  00022h, 0023Bh, 002F7h, 00067h, 00069h              ; 30 P1 latch, ignition correction, alpha-N load, EGR input, B6 input
if defined(FEAT_STOCK_DTC)
                DW  0FF04h, 0031Ah, 0031Bh, 0031Ch, 0031Dh              ; 35 service state, stored trouble codes (four bytes)
else
                DW  0FF04h, 00000h, 00000h, 00000h, 00000h              ; 35 service state (no codes kept: 00h)
endif
endif

endif
