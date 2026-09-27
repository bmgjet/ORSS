; ==================================================================================================
; boostcut.asm - overboost cut, hot and cold (HTS "Boost cut" page)
;> feature: FEAT_BOOSTCUT
;> name: Boost cut
;> category: Boost
;> pages: boostcut
;> ram: 1F2h-1F5h (shared cut requests)
;> about: Cuts fuel (or spark) the moment manifold pressure reaches the cut point - a lower one while
;>        the engine is cold - and lets it back in once the pressure has dropped a little under it. The
;>        safety net for a wastegate that sticks or a boost controller that runs away. Needs a MAP
;>        sensor that reads boost (a 2.5 or 3 bar sensor, with the MAP sensor scaling to match). Off
;>        until enabled.
; ==================================================================================================
ifdef FEAT_BOOSTCUT

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_BOOSTCUT
                JNE     boostcut_tick_skip
                CAL     boostcut_tick
boostcut_tick_skip:
endif

if XP == XP_CAL
;@ BoostCutEnable type=u8 flag=1 on=1 off=0 category="Boost cut" slot=boostcut.enable desc="Boost cut on."
boostcut_block:         DB  000h
;@ BoostCutCut type=u8 category="Boost cut" slot=boostcut.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
boostcut_cut:           DB  000h
;@ BoostCutHot type=u8 formula=map_mbar category="Boost cut" slot=boostcut.hot desc="Cut at this pressure (engine warm)."
boostcut_hot:           DB  0f5h                 ; the top of the sensor's range
;@ BoostCutCold type=u8 formula=map_mbar category="Boost cut" slot=boostcut.cold desc="Cut at this pressure while the engine is cold."
boostcut_cold:          DB  0c8h
;@ BoostCutColdECT type=u8 formula=honda_temp_c category="Boost cut" slot=boostcut.ect desc="Cold below this coolant temperature."
boostcut_ect:           DB  045h                 ; 60 C
endif

if XP == XP_CODE
boostcut_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, boostcut_block
                CMPB    A, #000h
                JEQ     boostcut_off
                LCB     A, boostcut_ect
                CMPB    0c1h, A                ; coolant byte - threshold borrows (C) while warmer than it
                LCB     A, boostcut_hot
                JLT     boostcut_have
                LCB     A, boostcut_cold
boostcut_have:  STB     A, r4                  ; the cut point
                L       A, off(MOD_FUELWANT)   ; cutting now?
                OR      A, off(MOD_SPARKWANT)
                AND     A, #MB_BOOSTCUT
                JNE     boostcut_cutting
                CLRB    A
                LB      A, r4
                CMPB    0a3h, A                ; MAP - cut point: no borrow once at or above it
                JLT     boostcut_off
                SJ      boostcut_on
boostcut_cutting:
                CLRB    A
                LB      A, r4
                SUBB    A, #003h               ; back in about 20 mbar under the cut point
                CMPB    0a3h, A
                JLT     boostcut_off
boostcut_on:    MOV     X1, #boostcut_block
                L       A, #MB_BOOSTCUT
                SC
                CAL     mod_cut
                J       mod_tick_exit
boostcut_off:   MOV     X1, #boostcut_block
                L       A, #MB_BOOSTCUT
                RC
                CAL     mod_cut
                J       mod_tick_exit
endif

endif
