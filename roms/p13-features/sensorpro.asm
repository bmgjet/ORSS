; ==================================================================================================
; sensorpro.asm - engine protection on a sender's reading (oil pressure, fuel pressure, any analog input)
;> feature: FEAT_SENSORPRO
;> name: Sensor protection (oil / fuel pressure)
;> category: Protection
;> platforms: P13
;> pages: sensorpro
;> ram: module RAM (1 byte), 1C2h-1C5h (shared cut requests)
;> about: Watches a sender on an analog input - an oil pressure or fuel pressure sender, a second
;>        wideband - and cuts the engine when its reading is on the wrong side of a level above an rpm
;>        for longer than a delay: oil pressure lost at speed ends the pull at once. It stays cut until
;>        the reading is back, or the rpm is under the point, so the engine idles home. Off until enabled.
; ==================================================================================================
ifdef FEAT_SENSORPRO

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
sensorpro_count     EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (sensorpro_count + 1)
endif

if XP == XP_TICKSLOT
if SLOT_SENSORPRO == TICK_SLOT
                CAL     sensorpro_tick
endif
endif

if XP == XP_CAL
;@ SensorProEnable type=u8 flag=1 on=1 off=0 category="Sensor protection" slot=sensorpro.enable desc="Sensor protection: cut when the input's reading is past the level above the rpm for longer than the delay - oil pressure lost, fuel pressure gone."
sensorpro_block:        DB  000h
;@ SensorProCut type=u8 category="Sensor protection" slot=sensorpro.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
sensorpro_cut:          DB  002h
;@ SensorProInput type=u8 category="Sensor protection" slot=sensorpro.input desc="The sender's analog input: 0 O2, 1 ELD, 2 EGR lift (P5.3), 3 the TCS pin (P5.5), 4-11 serial input 1-8 (sent over the datalog cable: the serial inputs module)."
sensorpro_input:        DB  003h
;@ SensorProSide type=u8 category="Sensor protection" slot=sensorpro.side desc="0 = cut when the reading is below the level (a pressure sender), 1 = above it (a sender that rises with trouble)."
sensorpro_side:         DB  000h
;@ SensorProLevel type=u8 formula=volts_5v_byte category="Sensor protection" slot=sensorpro.level desc="The level, 0-5 V at the input."
sensorpro_level:        DB  033h                 ; 1.0 V
;@ SensorProRPM type=u16 formula=rpm_period_word category="Sensor protection" slot=sensorpro.rpm desc="It only watches above this rpm, and lets go once the rpm is back under it."
sensorpro_rpm:          DW  00271h               ; 3000 rpm
;@ SensorProDelay type=u8 formula=x*32 unit=ms decimals=0 category="Sensor protection" slot=sensorpro.delay desc="Past the level for this long before it cuts: a dip over a bump is not a lost pump."
sensorpro_delay:        DB  010h                 ; 512 ms
endif

if XP == XP_CODE
sensorpro_tick:
                PUSHS   LRB
                MOV     LRB, #SVC_BANKT
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, sensorpro_block
                CMPB    A, #000h
                JEQ     sensorpro_release
                CLR     A                      ; (word mode for the period)
                LC      A, sensorpro_rpm       ; under the rpm: nothing to watch, and a cut lets go
                CMP     ENG_RPMP, A            ; period - the point's: a longer period is a lower rpm
                JGT     sensorpro_reset
                CLRB    A
                LCB     A, sensorpro_input
                CAL     mod_analog             ; the reading (uses DP, and r7 for a serial input)
                STB     A, r4
                LCB     A, sensorpro_level
                CMPB    A, r4                  ; level - reading: borrows (C) when the reading is above the level
                CLRB    A
                MB      ACC.0, C               ; 1: above
                STB     A, r5
                LCB     A, sensorpro_side      ; 0: cut below the level, 1: above it...
                ANDB    A, #001h
                XORB    A, r5                  ; ...so 0 here is the wrong side
                JNE     sensorpro_reset        ; the right side: the count starts over, and a cut lets go
                MOV     DP, #sensorpro_count   ; for long enough?
                LB      A, [DP]
                CMPB    A, #0ffh
                JEQ     sensorpro_counted      ; (held at the top)
                ADDB    A, #001h
                STB     A, [DP]
sensorpro_counted:
                STB     A, r4
                LCB     A, sensorpro_delay
                CMPB    A, r4                  ; delay - count: borrows once the count is past it
                JLT     sensorpro_do_cut
                JEQ     sensorpro_do_cut
                J       mod_tick_exit          ; not yet
sensorpro_reset:
                MOV     DP, #sensorpro_count
                MOVB    [DP], #000h
sensorpro_release:
                MOV     X1, #sensorpro_block
                L       A, #MB_SENSORPRO
                RC
                CAL     mod_cut
                J       mod_tick_exit
sensorpro_do_cut:
                MOV     X1, #sensorpro_block
                L       A, #MB_SENSORPRO
                SC
                CAL     mod_cut
                J       mod_tick_exit
endif

endif
