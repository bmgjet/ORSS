; ==================================================================================================
; gearfuel.asm - fuel correction by gear (HTS120 fuel_gearcorrect)
;> feature: FEAT_GEARFUEL
;> name: Fuel by gear
;> category: Fuel
;> pages: gearfuel
;> requires: FEAT_GEAR
;> ram: module RAM (2 bytes)
;> about: Adds or takes away fuel in each gear: the long pull in top gear leaner or richer than the
;>        short ones. Needs gear detection. Off until enabled.
; ==================================================================================================
ifdef FEAT_GEARFUEL

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_FUELTRIM
define NEED_FUELTRIM
endif
gearfuel_value      EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (gearfuel_value + 2)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_GEARFUEL
                JNE     gearfuel_tick_skip
                CAL     gearfuel_tick
gearfuel_tick_skip:
endif

if XP == XP_CAL
;@ FuelbygearEnable type=u8 flag=1 on=1 off=0 category="Fuel by gear" slot=gearfuel.enable desc="On."
gearfuel_enable:        DB  000h
;@ Fuelbygear type=u8 count=6 formula=(x-128)*100/256 unit=% decimals=1 category="Fuel by gear" slot=gearfuel.table colvalues=0,1,2,3,4,5 colunit=gear desc="The fuel change in each gear (0 = not known)."
gearfuel_table:         DB  080h, 080h, 080h, 080h, 080h, 080h
endif

if XP == XP_CODE
gearfuel_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, gearfuel_enable
                CMPB    A, #000h
                JEQ     gearfuel_off
                MOV     DP, #MOD_GEAR
                CLR     A
                LB      A, [DP]
                CMPB    A, #006h
                JGE     gearfuel_off
                L       A, ACC
                ADD     A, #gearfuel_table
                MOV     X1, A
                CLR     A
                LCB     A, 00000h[X1]
                SUB     A, #00080h
                SJ      gearfuel_set
gearfuel_off:   CLR     A
gearfuel_set:   MOV     DP, #gearfuel_value
                CAL     mod_fueltrim
                J       mod_tick_exit
endif

endif
