; ==================================================================================================
; dlstream.asm - datalogging: the channel stream
;> feature: FEAT_DLSTREAM
;> name: Datalogging: channel stream
;> category: Diagnostics
;> conflicts: FEAT_STOCK_SERIAL
;> ram: 374h-377h, 3E0h-3EFh
;> about: Logging only what you need, as fast as the line allows: the logger says which channels it wants
;>        and the ECU streams them back in frames stamped with its own 2.048 ms tick (Datalogging >
;>        Channels… picks them). Fast channels go in every frame; slow ones (temperatures, battery, codes)
;>        take turns, one a frame, so a frame stays short. Word values (rpm, injector time) are read in one
;>        go, never half old and half new. The app's own protocol, and the fastest; the HTS frame still
;>        answers alongside it.
;
; Channel stream protocol
;   7Eh                          identify: 7Eh, version 04h, channels in the table, what else is built in (bit 0
;                                fast and slow channels (74h), 1 serial inputs, 2 memory read, 3 service
;                                commands), checksum (the five bytes sum to 00h)
;   75h N F c1 .. c(N-1) chk     (version 4) the channels as a list: N its length (F's byte counted, 16 at most),
;                                F how many of them are fast, then the fast channel numbers, then the slow ones. chk
;                                makes N, the list and it sum to 00h. Answer 75h or 7Fh. The least work a byte: the
;                                way for up to 15 channel bytes. F with bit 7 set (ident bit 4): the list's last two bytes
;                                are a range, first and last: every channel in it is slow, in turn (any number of them:
;                                "log everything").
;   74h f0..f7 s0..s7 chk        (version 4) the channels as two masks, channel n in bit n mod 8 of byte n / 8:
;                                f the fast ones, s the slow ones (channels 0-55: bytes f7 and s7 are not used).
;                                chk makes the 16 bytes and it sum to 00h. Answer 74h (taken) or 7Fh (a bad checksum).
;   71h                          stream frames back to back until any other byte arrives (FFh serial inputs
;                                excepted)
;   72h                          send one frame
;   version 4 frame: A5h, tick lo, tick hi, every fast channel in channel order, then (with any slow ones) the
;                    slow channel's number and its byte, checksum (the whole frame sums to 00h). The slow
;                    channels take turns, one a frame, in channel order. The tick is RAM 0FEh-0FFh when the
;                    frame started: frames lost show as a gap in it.
;   Older loggers (versions 1-3, still answered):
;   70h N a1lo a1hi .. aNlo aNhi chk   the list as RAM or SFR addresses (N = 0-8)
;   73h N c1 .. cN chk                 the list as channel numbers (N = 0-16)
;   version 1-3 frame: A5h, seq, tick lo, tick hi, the N bytes, chk
; ==================================================================================================
ifdef FEAT_DLSTREAM

if XP == XP_DEFS
DL_NEWN         EQU     00374h          ; the list: its length (bits 0-5); bit 7: channel numbers (73h, 74h), not
                                        ; addresses; bit 6: the two masks (74h)
DL_RXSUM        EQU     00375h          ; a list's checksum while it comes in; streaming version 4, the slow channel
DL_TICK         EQU     00376h          ; tick word latched when a frame starts (then datalog.asm's word kept)
DL_LIST         EQU     003e0h          ; the channel addresses, a word each (70h), channel numbers (73h), or the
                                        ; fast mask (3E0h-3E7h) and the slow one (3E8h-3EFh) (74h)
if defined(FEAT_DLEXTRA)
DL_NCHANNELS    EQU     188             ; entries in dl_channels (dlextra.asm adds 53-131, and 132-187: every byte of module RAM)
else
DL_NCHANNELS    EQU     53              ; entries in dl_channels
endif
if defined(FEAT_DLSERIALIN)
DL_CAP_IN       EQU     002h
else
DL_CAP_IN       EQU     000h
endif
if defined(FEAT_DLMEMREAD)
DL_CAP_MEM      EQU     004h
else
DL_CAP_MEM      EQU     000h
endif
if defined(FEAT_DLSERVICE)
DL_CAP_SVC      EQU     008h
else
DL_CAP_SVC      EQU     000h
endif
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
                CMPB    A, #074h
                JEQ     dl_rx_setmasks
                CMPB    A, #075h
                JEQ     dl_rx_setv4list
                CMPB    A, #07eh
                JEQ     dl_rx_ident
                J       dl_rx_ret
dl_rx_ident:    MOVB    r2, #005h
                J       dl_rx_start
dl_rx_stream:   MOVB    r2, #002h
                SJ      dl_rx_go
dl_rx_oneframe: MOVB    r2, #003h
dl_rx_go:       MOV     DP, #DL_RXSUM          ; version 4: the slow channels from the first (a memory read may have
                MOVB    [DP], #0feh            ; used the byte since)
                J       dl_rx_start
dl_rx_setlist:  CLRB    A                      ; RAM addresses
                SJ      dl_rx_newlist
dl_rx_setids:   LB      A, #080h               ; channel numbers
                SJ      dl_rx_newlist
dl_rx_setv4list:
                LB      A, #0a0h               ; channel numbers, the version 4 list (how many fast first)
dl_rx_newlist:  MOV     DP, #DL_NEWN
                STB     A, [DP]
                MOVB    r0, #001h              ; the count next
dl_rx_sum0:     MOV     DP, #DL_RXSUM          ; (streaming, it held the slow channel)
                MOVB    [DP], #000h
                J       dl_rx_ret
dl_rx_setmasks: MOV     DP, #DL_NEWN           ; the two masks: 16 bytes, no count
                MOVB    [DP], #0d0h
                MOVB    r1, #000h
                MOVB    r0, #002h
                SJ      dl_rx_sum0
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
                ANDB    A, #01fh
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
                ANDB    A, #01fh
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
                MOVB    [DP], #000h            ; (version 4: the slow channels from the first)
                CMPB    A, #000h
                JNE     dl_rx_refuse2
                MOV     DP, #DL_NEWN
                LB      A, [DP]
                ANDB    A, #01fh
                STB     A, r5                  ; the new list is used from the next frame on
                LB      A, #075h
                MB      C, [DP].5
                JLT     dl_rx_taken            ; the version 4 list
                LB      A, #070h
                MB      C, [DP].6
                JGE     dl_rx_taken
                MOV     DP, #DL_LIST           ; the masks: which of their bytes have any
                CAL     dl_rx_bitmap
                MOV     DP, #DL_LIST + 8
                CAL     dl_rx_bitmap
                LB      A, #074h
dl_rx_taken:    J       dl_rx_send
dl_rx_refuse:   MOVB    r0, #000h
                MOV     DP, #DL_RXSUM
                MOVB    [DP], #000h
dl_rx_refuse2:  LB      A, #07fh
                J       dl_rx_send

; ------------------------------------------------------------------ the next byte of a stream frame or the ident (r2 = 2, 3, 5)
dl_next_stream: CMPB    A, #005h
                JEQ     dl_next_ident
                MOV     DP, #DL_NEWN
                MB      C, [DP].6
                JGE     dl_next_notm
                J       dl4_next               ; the masks: version 4 frames
dl_next_notm:   MB      C, [DP].5
                JGE     dl_next_v3
                J       dl5_next               ; the version 4 list: the same frames
; version 1-3 frame: A5h, seq, tick lo, tick hi, channels, checksum
dl_next_v3:     LB      A, r3
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
                CMPB    r3, #003h
                JNE     dl_next_s2put
                MOV     DP, #DL_TICK           ; after the tick: no word's high byte kept
                MOVB    [DP], #0ffh
dl_next_s2put:  J       dl_next_put
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
; identify: 7Eh, version, channels, what is built in, checksum (sum 00h)
dl_next_ident:  LB      A, r3
                CMPB    A, #004h
                JEQ     dl_next_scheck
                MOV     DP, A
                LCB     A, dl_ident[DP]
                J       dl_next_put
; a stream channel by number (73h list). A (byte, ACCH clear: dl_next starts with CLR A) = the index in the list.
; (r1 is the receive interrupt's: a serial input can come in while the stream runs.)
dl_next_idch:   L       A, ACC
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

; ------------------------------------------------------------------ version 4 frames (r3 = the position)
; r3: 0 A5h, 1-2 the tick, 3 + c fast channel c, 43h the slow channel's number, 44h its byte, 45h the checksum.
; Each byte goes out with the next channel already found (one look-up a byte at most: the interrupt stays short).
; The masks: fast 3E0h-3E6h, slow 3E8h-3EEh (channels 0-55); their 8th bytes (3E7h, 3EFh) say which of the seven
; have any channel (made when the list is taken). 375h is the slow channel to send next (FEh: from the first).
; r5 and r6 are scratch (version 4 has no count or sequence).
dl4_next:       LB      A, r3
                JNE     dl4_n1
                MOV     DP, #DL_TICK           ; frame start: latch the tick
                L       A, 0feh
                ST      A, [DP]
                LB      A, #0a5h
                J       dl_next_put
dl4_n1:         CMPB    A, #003h
                JGE     dl4_scan
                MOV     DP, #DL_TICK
                CMPB    A, #001h
                JEQ     dl4_tick
                INC     DP                     ; 2: the tick's high byte...
                LB      A, [DP]
                MOV     DP, #DL_TICK
                MOVB    [DP], #0ffh            ; ...and from now 376h says which word 377h holds (FFh none)
                STB     A, STBUF
                ADDB    r4, A
                CLRB    A                      ; the first fast channel next
                SJ      dl4_nextfast
dl4_tick:       LB      A, [DP]
                J       dl_next_put
; 3 + c: fast channel c, and the next one found
dl4_scan:       CMPB    A, #043h
                JGE     dl4_slow
                SUBB    A, #003h
                CAL     dl4_chan
                STB     A, STBUF
                ADDB    r4, A
                LB      A, r3
                SUBB    A, #002h               ; from the channel after it
dl4_nextfast:   MOVB    r6, #000h              ; the fast mask
                CAL     dl4_find
                JLT     dl4_fastat
                LB      A, #040h               ; none left: the slow channel next (43h)
dl4_fastat:     ADDB    A, #003h
                STB     A, r3
                RT
dl4_slow:       CMPB    A, #044h
                JEQ     dl4_slowval
                JGE     dl4_check
; 43h: the slow channel's number
                MOV     DP, #DL_RXSUM
                LB      A, [DP]
                CMPB    A, #0feh
                JNE     dl4_slownum
                CLRB    A                      ; from the first
                MOVB    r6, #008h
                CAL     dl4_find
                JGE     dl4_check              ; no slow channels: the checksum
                MOV     DP, #DL_RXSUM
                STB     A, [DP]
dl4_slownum:    J       dl_next_put
; 44h: its byte, and the next slow channel found for the next frame
dl4_slowval:    MOV     DP, #DL_RXSUM
                LB      A, [DP]
                CAL     dl4_chan
                STB     A, STBUF
                ADDB    r4, A
                MOV     DP, #DL_RXSUM
                LB      A, [DP]
                ADDB    A, #001h
                MOVB    r6, #008h
                CAL     dl4_find
                JLT     dl4_slownext
                LB      A, #0feh               ; none after it: from the first next time
dl4_slownext:   MOV     DP, #DL_RXSUM
                STB     A, [DP]
                MOVB    r3, #045h
                RT
; the byte that makes the frame sum to 00h
dl4_check:      CLRB    A
                SUBB    A, r4
                MOVB    r3, #000h
                MOVB    r4, #000h
                CMPB    r2, #002h              ; streaming: the next frame follows
                JEQ     dl4_out
                MOVB    r2, #000h
dl4_out:        J       dl_next_out

; In: A (byte) = the first channel to look at, r6 = the mask (0 fast, 8 slow). Out: C set and A = the first channel
; at or after it in the mask; C clear when there is none. A few table look-ups, no loops. Uses r5, DP.
dl4_find:       CMPB    A, #038h               ; the masks hold channels 0-55
                JGE     dl4_f_none
                STB     A, r5
                CLR     A
                LB      A, r5
                ANDB    A, #007h
                L       A, ACC
                MOV     DP, A
                LCB     A, dl4_from[DP]        ; its bit and the ones above it...
                L       A, ACC
                PUSHS   A
                CLR     A
                LB      A, r5
                SRLB    A
                SRLB    A
                SRLB    A
                ADDB    A, r6
                L       A, ACC
                ADD     A, #DL_LIST
                MOV     DP, A                  ; (its byte of the mask)
                POPS    A
                LB      A, ACC
                ANDB    A, [DP]                ; ...that are set
                JNE     dl4_f_here
                CLR     A                      ; none: the next byte of the mask with any (its 8th byte says which)
                LB      A, r5
                SRLB    A
                SRLB    A
                SRLB    A
                L       A, ACC
                MOV     DP, A
                LCB     A, dl4_after[DP]       ; the bytes after it...
                L       A, ACC
                PUSHS   A
                CLR     A
                LB      A, r6
                L       A, ACC
                ADD     A, #DL_LIST + 7
                MOV     DP, A
                POPS    A
                LB      A, ACC
                ANDB    A, [DP]                ; ...with any set
                JEQ     dl4_f_none
                L       A, ACC
                MOV     DP, A
                LCB     A, dl4_lsb[DP]         ; the first of them
                LB      A, ACC                 ; (byte mode: LCB leaves the mode as it was)
                STB     A, r5
                ADDB    A, r6
                L       A, ACC
                ADD     A, #DL_LIST
                MOV     DP, A
                CLR     A
                LB      A, [DP]                ; its channels
                L       A, ACC
                MOV     DP, A
                LCB     A, dl4_lsb[DP]         ; the first of those
                LB      A, ACC                 ; (byte mode: LCB leaves the mode as it was)
                STB     A, r6                  ; (r6 is done with)
                LB      A, r5                  ; that byte's first channel...
                SLLB    A
                SLLB    A
                SLLB    A
                ADDB    A, r6                  ; ...and the bit
                SC
                RT
dl4_f_here:     L       A, ACC
                MOV     DP, A
                LCB     A, dl4_lsb[DP]         ; the lowest set
                LB      A, ACC                 ; (byte mode: LCB leaves the mode as it was)
                STB     A, r6                  ; (r6 is done with)
                LB      A, r5
                ANDB    A, #0f8h               ; its byte's first channel...
                ADDB    A, r6                  ; ...and the bit
                SC
                RT
dl4_f_none:     RC
                RT

; DP = a mask (3E0h or 3E8h): its 8th byte made to say which of bytes 0-6 have any channel (the list just taken).
; Uses r1 (the receive interrupt's).
dl_rx_bitmap:   MOVB    r1, #000h
                LB      A, [DP]
                JEQ     dl_bm1
                SB      r1.0
dl_bm1:         INC     DP
                LB      A, [DP]
                JEQ     dl_bm2
                SB      r1.1
dl_bm2:         INC     DP
                LB      A, [DP]
                JEQ     dl_bm3
                SB      r1.2
dl_bm3:         INC     DP
                LB      A, [DP]
                JEQ     dl_bm4
                SB      r1.3
dl_bm4:         INC     DP
                LB      A, [DP]
                JEQ     dl_bm5
                SB      r1.4
dl_bm5:         INC     DP
                LB      A, [DP]
                JEQ     dl_bm6
                SB      r1.5
dl_bm6:         INC     DP
                LB      A, [DP]
                JEQ     dl_bm7
                SB      r1.6
dl_bm7:         INC     DP
                LB      A, r1
                STB     A, [DP]
                RT

; bit n and the ones above it (n = 8: none)
dl4_from:       DB      0ffh, 0feh, 0fch, 0f8h, 0f0h, 0e0h, 0c0h, 080h
; the ones above bit n
dl4_after:      DB      0feh, 0fch, 0f8h, 0f0h, 0e0h, 0c0h, 080h, 000h
; the lowest bit set in a byte
dl4_lsb:
                DB      000h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      004h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      005h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      004h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      006h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      004h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      005h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      004h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      007h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      004h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      005h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      004h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      006h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      004h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      005h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h
                DB      004h, 000h, 001h, 000h, 002h, 000h, 001h, 000h, 003h, 000h, 001h, 000h, 002h, 000h, 001h, 000h

; ------------------------------------------------------------------ version 4 frames from the list (75h)
; The list (DL_LIST): how many fast channels (F), then the fast ones, then the slow ones; r5 its length (F's byte
; counted). r3: 0 A5h, 1-2 the tick, 3 + i fast channel i, 43h the slow channel's number, 44h its byte, 45h the
; checksum; 375h the slow one's place among the slow ones. No searching: the shortest interrupt of the three.
dl5_next:       LB      A, r3
                JNE     dl5_n1
                MOV     DP, #DL_TICK           ; frame start: latch the tick
                L       A, 0feh
                ST      A, [DP]
                LB      A, #0a5h
                J       dl_next_put
dl5_n1:         CMPB    A, #003h
                JGE     dl5_ch
                MOV     DP, #DL_TICK
                CMPB    A, #001h
                JEQ     dl5_tick
                INC     DP                     ; 2: the tick's high byte, then no word kept
                LB      A, [DP]
                MOV     DP, #DL_TICK
                MOVB    [DP], #0ffh
                J       dl_next_put
dl5_tick:       LB      A, [DP]
                J       dl_next_put
dl5_ch:         CMPB    A, #043h
                JGE     dl5_slow
                SUBB    A, #003h               ; i
                STB     A, r6                  ; (r6 is free here: dl5_slowat takes it only after the fast ones)
                MOV     DP, #DL_LIST
                LB      A, [DP]                ; F, less its range flag (bit 7)
                ANDB    A, #07fh
                CMPB    A, r6
                JLE     dl5_endfast            ; F <= i: past the fast ones
                LB      A, r6                  ; i (a load sets Z: after the branch)
                L       A, ACC                 ; (ACCH clear: dl_next starts with CLR A)
                ADD     DP, A
                INC     DP
                LB      A, [DP]                ; the channel
                CAL     dl4_chan
                J       dl_next_put
dl5_endfast:    MOVB    r3, #043h
                LB      A, #043h
dl5_slow:       CMPB    A, #044h
                JEQ     dl5_slowval
                JGE     dl5_sum
                CAL     dl5_slowat             ; 43h: the slow channel's number
                JGE     dl5_sum                ; (none: the checksum)
                LB      A, [DP]
                J       dl_next_put
dl5_slowval:    CAL     dl5_slowat             ; 44h: its byte, and the next slow one for the next frame
                LB      A, [DP]
                CAL     dl4_chan
                STB     A, STBUF
                ADDB    r4, A
                MOV     DP, #DL_RXSUM
                INCB    [DP]
                MOVB    r3, #045h
                RT
dl5_sum:        J       dl4_check
; DP = the list's place of the slow channel to send; C clear when the list has none. Uses A, r6.
dl5_slowat:     MOV     DP, #DL_LIST
                MB      C, [DP].7              ; F's bit 7: the slow ones are a range (the list's last two bytes)
                JLT     dl5_range
                LB      A, r5
                SUBB    A, #001h
                SUBB    A, [DP]                ; how many slow ones
                JLT     dl5_none
                JEQ     dl5_none
                STB     A, r6
                MOV     DP, #DL_RXSUM
                LB      A, [DP]
                CMPB    A, r6
                JLT     dl5_at
                CLRB    A                      ; past the last (or FEh at the start): the first
                STB     A, [DP]
dl5_at:         MOV     DP, #DL_LIST
                ADDB    A, [DP]
                ADDB    A, #001h               ; its place: after F's byte and the fast ones
                L       A, ACC                 ; (ACCH clear: dl_next starts with CLR A)
                ADD     A, #DL_LIST
                MOV     DP, A
                SC
                RT
dl5_none:       RC
                RT
; The slow channels as a range, from the list's second-last byte to its last: 375h holds the channel number itself,
; and DP is left on it (the caller sends it, then adds 1 for the next frame). Out of the range (FEh at the start): the
; first. In: DP = DL_LIST. Uses A, r6.
dl5_range:      LB      A, r5
                SUBB    A, #002h
                L       A, ACC                 ; (ACCH clear: dl_next starts with CLR A)
                ADD     DP, A                  ; the range's first channel
                LB      A, [DP]
                STB     A, r6
                INC     DP
                LB      A, [DP]                ; its last
                MOV     DP, #DL_RXSUM
                CMPB    A, [DP]
                JLT     dl5_rlo                ; past the last: back to the first
                LB      A, [DP]
                CMPB    A, r6
                JGE     dl5_rok
dl5_rlo:        LB      A, r6
                STB     A, [DP]
dl5_rok:        SC
                RT

; A (byte) = a channel number: its byte now (00h past the table). Uses DP.
dl4_chan:       CMPB    A, #DL_NCHANNELS
                JLT     dl4_chan_ok
                CLRB    A
                RT
dl4_chan_ok:    L       A, ACC
                AND     A, #000ffh             ; (whatever was in ACCH: no scratch register, the list's length is in r5)
                SLL     A
                MOV     DP, A
                LC      A, dl_channels[DP]
                J       dl_fetch               ; (its RT is this one's)

;@ DatalogIdent type=u8 count=4 formula=raw category="Internal" desc="Datalog: the answer to the channel-stream identify command (not a tuning value)."
dl_ident:       DB      07eh, 004h, DL_NCHANNELS, 001h | DL_CAP_IN | DL_CAP_MEM | DL_CAP_SVC | 010h
if defined(FEAT_DLEXTRA)
;@ DatalogChannels type=u16 count=188 formula=raw category="Internal" desc="Datalog: what each channel number of the stream sends (the app has the same list; not a tuning value). An address, or as the 20h frame's table: 4000h + a word's low byte, 2000h + its high byte."
else
;@ DatalogChannels type=u16 count=53 formula=raw category="Internal" desc="Datalog: what each channel number of the stream sends (the app has the same list; not a tuning value). An address, or as the 20h frame's table: 4000h + a word's low byte, 2000h + its high byte."
endif
dl_channels:
                DW  040ACh, 020ADh, 000A3h, 000B9h, 000C1h              ;  0 crank period lo, crank period hi, MAP, throttle, coolant
                DW  000C0h, 000C3h, 000B4h, 000A4h, 003BEh              ;  5 intake air, battery, road speed, baro, O2
                DW  003C6h, 04146h, 02147h, 00246h, 000A7h              ; 10 ELD, injector lo, injector hi, advance, load byte
                DW  002FEh, 0FF01h, 0FF02h, 0FF03h, 040C8h              ; 15 gear, status: VTEC, switches, fuel pump, idle valve lo
                DW  020C9h, 002FDh, 002FCh, 04000h + MOD_RAM_BASE, 02000h + MOD_RAM_BASE + 1 ; 20 idle valve hi, retard request, advance request, fuel trim lo, fuel trim hi (lib.asm's MOD_FUELSUM)
                DW  001F0h, 000FCh, 001F1h, 000FDh, 00020h              ; 25 fuel cut request, spark cut request, module outputs, module flags, P0 latch
                DW  00022h, 0023Bh, 002F7h, 00067h, 00069h              ; 30 P1 latch, ignition correction, alpha-N load, EGR input, B6 input
if defined(FEAT_STOCK_DTC)
                DW  0FF04h, 0031Ah, 0031Bh, 0031Ch, 0031Dh              ; 35 service state, stored trouble codes (four bytes)
else
                DW  0FF04h, 00000h, 00000h, 00000h, 00000h              ; 35 service state (no codes kept: 00h)
endif
if defined(FEAT_DLSERIALIN)
                DW  SERIN_RAM, SERIN_RAM + 1, SERIN_RAM + 2, SERIN_RAM + 3, SERIN_RAM + 4 ; 40 serial inputs 1-8 (dlserialin.asm)...
                DW  SERIN_RAM + 5, SERIN_RAM + 6, SERIN_RAM + 7, SERIN_AGE                ; 45 ... and how long since one came
else
                DW  00000h, 00000h, 00000h, 00000h, 00000h              ; 40 (no serial inputs)
                DW  00000h, 00000h, 00000h, 00000h
endif
                DW  04000h + MOD_RAM_BASE + 4, 02000h + MOD_RAM_BASE + 5 ; 49 the modules' timing trims added up (lib.asm's MOD_IGNSUM)
                DW  MOD_RAM_BASE + 7, 001F6h                            ; 51 boost solenoid duty (MOD_PWMDUTY), module flags 2 (MOD_FLAGS)
if defined(FEAT_DLEXTRA)
; (dlextra.asm) everything else worth logging. The app has the same list (DatalogChannels.cs): append, never reorder.
                DW  00138h, 0414Ah, 0214Bh, 0413Ch, 0213Dh              ; 53 fuel map value, post-start fuel (word), injector dead time (word)
                DW  04144h, 02145h, 0414Ch, 0214Dh, 04150h              ; 58 coolant injector correction (word), intake air fuel (word), knock fuel (word)...
                DW  02151h, 00156h, 0015Ah, 0015Bh, 0015Ch              ; 63 ...knock fuel, baro fuel 2, warm-up 1-3
                DW  0015Dh, 0015Eh, 0016Fh, 0016Dh, 0016Eh              ; 68 warm-up 4, 6, 5, acceleration fuel, baro fuel
                DW  00171h, 00173h, 00174h, 00175h, 041E6h              ; 73 baro fuel 3, acceleration scale low / high, tip-in scale, tip-in coolant (word)...
                DW  021E7h, 001ECh, 0023Ah, 0023Ch, 0023Dh              ; 78 ...tip-in coolant, acceleration limit, ignition: intake air, throttle, cold
                DW  0023Eh, 0023Fh, 00238h, 00245h, 00254h              ; 83 ignition: rpm retard, knock retard, knock retard 2, rpm correction, knock coolant
                DW  0024Ah, 0024Bh, 04258h, 02259h, 04274h              ; 88 dwell rpm, dwell battery, target idle (word), idle decel air (word)...
                DW  02275h, 0427Eh, 0227Fh, 00290h, 00294h              ; 93 ...idle decel air, idle intake air (word), idle baro, idle rpm threshold
                DW  00158h, 00159h, 0011Fh, 00128h, 0011Ch              ; 98 VTEC load needed, VTEC baro offset, VTEC flags, VTEC rpm flags, fuel cut flags
                DW  001F2h, 001F3h, 001F4h, 001F5h, 0012Dh              ; 103 limiters wanting fuel cut (2), spark cut (2) (lib.asm), rpm index
                DW  0012Ch, 000E9h, 000A0h, 00111h, 00116h              ; 108 load index, time since start, flags A0h, 111h, 116h
                DW  00117h, 00118h, 00119h, 0011Dh, 00123h              ; 113 flags 117h-119h, 11Dh, 123h
                DW  00124h, 00125h, 00126h, 00216h, 00217h              ; 118 flags 124h-126h, 216h, 217h
                DW  00227h, 01000h, 01001h, 01002h, 01003h              ; 123 flags 227h, the addresses you pick (DatalogUserAddress 1-4)...
                DW  01004h, 01005h, 01006h, 01007h                      ; 128 ...5-8
; 132-187: every byte of module RAM, where each function keeps its state (the app names them from the build's symbols)
                DW  MOD_RAM_BASE + 0, MOD_RAM_BASE + 1, MOD_RAM_BASE + 2, MOD_RAM_BASE + 3, MOD_RAM_BASE + 4, MOD_RAM_BASE + 5, MOD_RAM_BASE + 6, MOD_RAM_BASE + 7 ; 132 module RAM +0..+7
                DW  MOD_RAM_BASE + 8, MOD_RAM_BASE + 9, MOD_RAM_BASE + 10, MOD_RAM_BASE + 11, MOD_RAM_BASE + 12, MOD_RAM_BASE + 13, MOD_RAM_BASE + 14, MOD_RAM_BASE + 15 ; 140 module RAM +8..+15
                DW  MOD_RAM_BASE + 16, MOD_RAM_BASE + 17, MOD_RAM_BASE + 18, MOD_RAM_BASE + 19, MOD_RAM_BASE + 20, MOD_RAM_BASE + 21, MOD_RAM_BASE + 22, MOD_RAM_BASE + 23 ; 148 module RAM +16..+23
                DW  MOD_RAM_BASE + 24, MOD_RAM_BASE + 25, MOD_RAM_BASE + 26, MOD_RAM_BASE + 27, MOD_RAM_BASE + 28, MOD_RAM_BASE + 29, MOD_RAM_BASE + 30, MOD_RAM_BASE + 31 ; 156 module RAM +24..+31
                DW  MOD_RAM_BASE + 32, MOD_RAM_BASE + 33, MOD_RAM_BASE + 34, MOD_RAM_BASE + 35, MOD_RAM_BASE + 36, MOD_RAM_BASE + 37, MOD_RAM_BASE + 38, MOD_RAM_BASE + 39 ; 164 module RAM +32..+39
                DW  MOD_RAM_BASE + 40, MOD_RAM_BASE + 41, MOD_RAM_BASE + 42, MOD_RAM_BASE + 43, MOD_RAM_BASE + 44, MOD_RAM_BASE + 45, MOD_RAM_BASE + 46, MOD_RAM_BASE + 47 ; 172 module RAM +40..+47
                DW  MOD_RAM_BASE + 48, MOD_RAM_BASE + 49, MOD_RAM_BASE + 50, MOD_RAM_BASE + 51, MOD_RAM_BASE + 52, MOD_RAM_BASE + 53, MOD_RAM_BASE + 54, MOD_RAM_BASE + 55 ; 180 module RAM +48..+55
endif
endif

endif
