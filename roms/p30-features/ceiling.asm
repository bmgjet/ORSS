; ==================================================================================================
; ceiling.asm - rpm ceilings by road speed (HTS120 "Rpm ceilings")
;> feature: FEAT_CEILING
;> name: Rpm ceilings by road speed
;> category: Limits
;> pages: revlimit
;> ram: 1F2h-1F5h (shared cut requests)
;> about: A rev limit that depends on road speed: five speeds, falling, each with the rpm the engine may
;>        reach at or above it. For gentle running-in, for keeping a learner under a limit in the low
;>        gears, or for a lower limit at a standstill. Fuel cut (or ignition) with a 3 % band. Off until
;>        enabled.
; ==================================================================================================
ifdef FEAT_CEILING

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_CEILING
                JNE     ceiling_tick_skip
                CAL     ceiling_tick
ceiling_tick_skip:
endif

if XP == XP_CAL
;@ CeilingEnable type=u8 flag=1 on=1 off=0 category="Rpm ceilings" slot=revlimit.ceiling.enable desc="Rpm ceilings on."
ceiling_block:          DB  000h
;@ CeilingCut type=u8 category="Rpm ceilings" slot=revlimit.ceiling.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
ceiling_cut:            DB  000h
;@ CeilingBySpeed type=u8 count=15 category="Rpm ceilings" slot=revlimit.ceiling.speed desc="Five entries, falling road speed: km/h, then the rpm ceiling as a crank period (low, high byte). 96h = 12500 rpm, no ceiling."
ceiling_table:          DB  0c8h, 096h, 000h     ; 200 km/h: 12500 rpm
                        DB  096h, 096h, 000h     ; 150
                        DB  064h, 096h, 000h     ; 100
                        DB  032h, 096h, 000h     ;  50
                        DB  000h, 096h, 000h     ;   0
endif

if XP == XP_CODE
ceiling_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, ceiling_block
                CMPB    A, #000h
                JEQ     ceiling_off
                MOV     X1, #ceiling_table
                MOVB    r5, #005h
ceiling_find:   CLRB    A
                LCB     A, 00000h[X1]          ; the entry's speed
                CMPB    0b4h, A                ; road speed - entry: no borrow at or above it
                JGE     ceiling_found
                INC     X1
                INC     X1
                INC     X1
                DECB    r5
                JNE     ceiling_find
                SJ      ceiling_off            ; below every entry: no ceiling
ceiling_found:  LC      A, 00001h[X1]          ; its ceiling
                L       A, ACC                 ; word mode
                ST      A, er2
                L       A, off(MOD_FUELWANT)   ; limiting now?
                OR      A, off(MOD_SPARKWANT)
                AND     A, #MB_CEILING
                JNE     ceiling_cutting
                L       A, er2
                CMP     0ach, A                ; period above the ceiling's: below the rpm
                JGT     ceiling_off
                SJ      ceiling_on
ceiling_cutting:
                L       A, er2                 ; back in 3 % under it: period + period / 32
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                ADD     A, er2
                CMP     0ach, A
                JGT     ceiling_off
ceiling_on:     MOV     X1, #ceiling_block
                L       A, #MB_CEILING
                SC
                CAL     mod_cut
                J       mod_tick_exit
ceiling_off:    MOV     X1, #ceiling_block
                L       A, #MB_CEILING
                RC
                CAL     mod_cut
                J       mod_tick_exit
endif

endif
