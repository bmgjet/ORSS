; ==================================================================================================
; flexfuel.asm - flex fuel: fuel and timing on the ethanol content (HTS "Flex fuel" page)
;> feature: FEAT_FLEX
;> name: Flex fuel
;> category: Fuel
;> pages: flexfuel
;> ram: module RAM (5 bytes)
;> about: Reads the ethanol content from an ethanol sensor through an analog converter (0-5 V) on an
;>        analog input, and adds fuel and timing against it from two tables, so the car runs on anything
;>        from pump fuel to E85 without a retune. A sensor with a frequency output needs a converter to
;>        a voltage. Off until enabled.
; ==================================================================================================
ifdef FEAT_FLEX

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_FUELTRIM
define NEED_FUELTRIM
endif
ifndef NEED_IGNTRIM
define NEED_IGNTRIM
endif
flex_ftrim          EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (flex_ftrim + 2)
flex_itrim          EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (flex_itrim + 2)
flex_eth            EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (flex_eth + 1)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_FLEX
                JNE     flex_tick_skip
                CAL     flex_tick
flex_tick_skip:
endif

if XP == XP_CAL
;@ FlexEnable type=u8 flag=1 on=1 off=0 category="Flex fuel" slot=flexfuel.enable desc="Flex fuel on."
flex_enable:            DB  000h
;@ FlexInput type=u8 category="Flex fuel" slot=flexfuel.input desc="The ethanol signal on: 0 O2 (D14), 1 ELD (D10), 2 EGR (D12), 3 B6."
flex_input:             DB  003h
;@ FlexV0 type=u8 formula=volts_5v_byte category="Flex fuel" slot=flexfuel.v0 desc="The voltage at 0 % ethanol."
flex_v0:                DB  01ah                 ; 0.5 V
;@ FlexV100 type=u8 formula=volts_5v_byte category="Flex fuel" slot=flexfuel.v100 desc="The voltage at 100 % ethanol."
flex_v100:              DB  0e6h                 ; 4.5 V
;@ FlexFuel type=u8 count=9 formula=x*100/256 unit=% decimals=1 category="Flex fuel" slot=flexfuel.fuel colvalues=0,12.5,25,37.5,50,62.5,75,87.5,100 colunit="% ethanol" desc="Extra fuel against ethanol content."
flex_fuel:              DB  000h, 00ch, 018h, 024h, 030h, 03ch, 048h, 054h, 060h
;@ FlexIgn type=u8 count=9 formula=x/4 unit=deg decimals=2 category="Flex fuel" slot=flexfuel.ign colvalues=0,12.5,25,37.5,50,62.5,75,87.5,100 colunit="% ethanol" desc="Timing added against ethanol content."
flex_ign:               DB  000h, 002h, 004h, 006h, 008h, 00ah, 00ch, 00eh, 010h
endif

if XP == XP_CODE
flex_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, flex_enable
                CMPB    A, #000h
                JNE     flex_on
                MOVB    r4, #000h
                SJ      flex_have          ; disabled: as for 0 % (and 0 trims below)
flex_on:        LCB     A, flex_input
                CAL     mod_analog
                STB     A, r4                  ; the signal
                CLRB    A
                LCB     A, flex_v0
                STB     A, r5
                LCB     A, flex_v100
                SUBB    A, r5
                STB     A, r0                  ; the span
                LB      A, r4
                CMPB    A, r5
                JGE     flex_above0
                MOVB    r4, #000h              ; below the 0 % voltage
                SJ      flex_have
flex_above0:    SUBB    A, r5
                CMPB    A, r0
                JLT     flex_scale
                MOVB    r4, #0ffh              ; past the 100 % voltage
                SJ      flex_have
flex_scale:     STB     A, r4
                LB      A, r0                  ; ethanol = (signal - v0) x 255 / span
                STB     A, r6
                LB      A, r4
                MOVB    r0, #0ffh
                MULB
                L       A, ACC
                MOVB    r0, r6
                DIVB
                ST      A, er3
                LB      A, r6
                STB     A, r4                  ; the ethanol content, 0-255
flex_have:      MOV     DP, #flex_eth
                LB      A, r4
                STB     A, [DP]
                CLRB    A
                LCB     A, flex_enable
                CMPB    A, #000h
                JEQ     flex_trims_off
                MOV     DP, #flex_eth
                LB      A, [DP]
                MOV     X1, #flex_fuel
                CAL     mod_lookup9
                STB     A, r4
                CLR     A
                LB      A, r4
                L       A, ACC
                MOV     DP, #flex_ftrim
                CAL     mod_fueltrim
                MOV     DP, #flex_eth
                CLRB    A
                LB      A, [DP]
                MOV     X1, #flex_ign
                CAL     mod_lookup9
                STB     A, r4
                CLR     A
                LB      A, r4
                L       A, ACC
                MOV     DP, #flex_itrim
                CAL     mod_igntrim
                J       mod_tick_exit
flex_trims_off: CLR     A
                MOV     DP, #flex_ftrim
                CAL     mod_fueltrim
                CLR     A
                MOV     DP, #flex_itrim
                CAL     mod_igntrim
                J       mod_tick_exit
endif

endif
