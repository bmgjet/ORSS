; ==================================================================================================
; gearlimit.asm - rev limit in each gear (HTS120 "Rpm ceilings" by gear)
;> feature: FEAT_GEARLIMIT
;> name: Rev limit by gear
;> category: Limits
;> pages: revlimit
;> requires: FEAT_GEAR
;> ram: 1F2h-1F5h (shared cut requests)
;> about: A rev limit of its own for each gear: lower in first and second to keep a car hooked up, the
;>        full limit in the tall gears. Fuel cut (or ignition) with a 3 % band. Needs gear detection.
;>        Off until enabled.
; ==================================================================================================
ifdef FEAT_GEARLIMIT

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif

endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_GEARLIMIT
                JNE     gearlim_tick_skip
                CAL     gearlim_tick
gearlim_tick_skip:
endif

if XP == XP_CAL
;@ LimitByGearEnable type=u8 flag=1 on=1 off=0 category="Rev limit by gear" slot=revlimit.ceiling.gear.enable desc="Rev limit by gear on."
gearlim_block:          DB  000h
;@ LimitByGearCut type=u8 category="Rev limit by gear" slot=revlimit.ceiling.gear.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
gearlim_cut:            DB  000h
;@ LimitByGear type=u16 count=6 formula=rpm_period_word category="Rev limit by gear" slot=revlimit.ceiling.gear colvalues=0,1,2,3,4,5 colunit=gear desc="The rev limit in each gear (0 = not known). 12500 = none."
gearlim_table:          DW  00096h, 00096h, 00096h, 00096h, 00096h, 00096h
endif

if XP == XP_CODE
gearlim_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, gearlim_block
                CMPB    A, #000h
                JEQ     gearlim_off
                MOV     DP, #MOD_GEAR
                CLR     A
                LB      A, [DP]
                CMPB    A, #006h
                JGE     gearlim_off
                L       A, ACC
                SLL     A
                ADD     A, #gearlim_table
                MOV     X1, A
                LC      A, 00000h[X1]          ; this gear's limit
                L       A, ACC
                ST      A, er2
                L       A, off(MOD_FUELWANT)   ; limiting now?
                OR      A, off(MOD_SPARKWANT)
                AND     A, #MB_GEARLIMIT
                JNE     gearlim_cutting
                L       A, er2
                CMP     0ach, A
                JGT     gearlim_off
                SJ      gearlim_on
gearlim_cutting:
                L       A, er2                 ; back in 3 % under it
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                ADD     A, er2
                CMP     0ach, A
                JGT     gearlim_off
gearlim_on:     MOV     X1, #gearlim_block
                L       A, #MB_GEARLIMIT
                SC
                CAL     mod_cut
                J       mod_tick_exit
gearlim_off:    MOV     X1, #gearlim_block
                L       A, #MB_GEARLIMIT
                RC
                CAL     mod_cut
                J       mod_tick_exit
endif

endif
