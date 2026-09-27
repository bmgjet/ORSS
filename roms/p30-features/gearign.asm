; ==================================================================================================
; gearign.asm - ignition correction by gear (HTS "Gear corrections" page)
;> feature: FEAT_GEARIGN
;> name: Timing by gear
;> category: Ignition
;> pages: gearcorr
;> requires: FEAT_GEAR
;> ram: module RAM (2 bytes)
;> about: Adds or takes away timing in each gear: less in the low gears where the load builds quickly,
;>        more in the high ones. Needs gear detection. Off until enabled.
; ==================================================================================================
ifdef FEAT_GEARIGN

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_IGNTRIM
define NEED_IGNTRIM
endif
gearign_value       EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (gearign_value + 2)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_GEARIGN
                JNE     gearign_tick_skip
                CAL     gearign_tick
gearign_tick_skip:
endif

if XP == XP_CAL
;@ TimingbygearEnable type=u8 flag=1 on=1 off=0 category="Timing by gear" slot=gearcorr.enable desc="On."
gearign_enable:        DB  000h
;@ Timingbygear type=u8 count=6 formula=(x-128)/4 unit=deg decimals=2 category="Timing by gear" slot=gearcorr.table colvalues=0,1,2,3,4,5 colunit=gear desc="The timing change in each gear (0 = not known)."
gearign_table:         DB  080h, 080h, 080h, 080h, 080h, 080h
endif

if XP == XP_CODE
gearign_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, gearign_enable
                CMPB    A, #000h
                JEQ     gearign_off
                MOV     DP, #MOD_GEAR
                CLR     A
                LB      A, [DP]
                CMPB    A, #006h
                JGE     gearign_off
                L       A, ACC
                ADD     A, #gearign_table
                MOV     X1, A
                CLR     A
                LCB     A, 00000h[X1]
                SUB     A, #00080h
                SJ      gearign_set
gearign_off:   CLR     A
gearign_set:   MOV     DP, #gearign_value
                CAL     mod_igntrim
                J       mod_tick_exit
endif

endif
