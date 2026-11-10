; ==================================================================================================
; boostcut.asm - overboost cut, hot and cold (HTS "Boost cut" page)
;> feature: FEAT_BOOSTCUT
;> name: Boost cut
;> category: Boost
;> pages: boostcut
;> ram: 1F2h-1F5h (shared cut requests), module RAM (1 byte)
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
bc_point            EQU     MODRAM_NEXT         ; the cut point now (hot or cold, moved over the cable), 0 when off:
undef MODRAM_NEXT                               ; the every-tick look compares the MAP with it alone
define MODRAM_NEXT (bc_point + 1)
endif

if XP == XP_TICKSLOT
if SLOT_BOOSTCUT == TICK_SLOT
                CAL     boostcut_tick          ; its slot: cut, hold or let go
endif
endif
if XP == XP_TICK
                LB      A, SVC_TICK
                ANDB    A, #00fh
                CMPB    A, #SLOT_BOOSTCUT
                JEQ     boostcut_tick_skip
                CAL     boostcut_fast          ; every other tick (2 ms): a quick look for boost past the cut point -
boostcut_tick_skip:                            ; on its slot alone (33 ms) boost can climb 20 kPa past it first
endif

if XP == XP_CAL
;@ BoostCutEnable type=u8 flag=1 on=1 off=0 category="Boost cut" slot=boostcut.enable desc="Cut fuel (or spark) when the boost goes over the limit below - a burst hose or a stuck wastegate cannot hurt the engine. Checked every tick, so it never goes past."
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
; Every tick but its slot: not cutting yet, and the MAP at or past the cut point its slot worked out - the full tick,
; at once. (Kept short: it runs every 2 ms.)
; The tick runs on the timer interrupt's register page (LRB 19h, page 0): off() would reach page 0, not the want words
; at 1F2h-1F5h, so they are read through DP.
boostcut_fast:  L       A, DP                  ; (no registers here: these are the timer interrupt's, kept between ticks)
                PUSHS   A
                MOV     DP, #MOD_FUELWANT
                L       A, [DP]
                MOV     DP, #MOD_SPARKWANT
                OR      A, [DP]
                AND     A, #MB_BOOSTCUT
                JNE     boostcut_fast_pop      ; cutting already: its slot lets go
                MOV     DP, #bc_point
                LB      A, [DP]
                JEQ     boostcut_fast_pop      ; off
                CMPB    ENG_MAP, A                ; MAP - cut point: no borrow once at or above it
                JLT     boostcut_fast_pop
                POPS    A
                MOV     DP, A
                J       boostcut_tick
boostcut_fast_pop:
                POPS    A
                MOV     DP, A
                RT

boostcut_tick:
                PUSHS   LRB
                MOV     LRB, #SVC_BANKT
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, boostcut_block
                CMPB    A, #000h
                JEQ     boostcut_disabled
                LCB     A, boostcut_ect
                CMPB    ENG_ECT, A                ; coolant byte - threshold borrows (C) while warmer than it
                LCB     A, boostcut_hot
                JLT     boostcut_have
                LCB     A, boostcut_cold
boostcut_have:
if defined(FEAT_REMOTE)
                CAL     rc_boost_point         ; set over the datalog cable (remote.asm), never above the tune's own
endif
                STB     A, r4                  ; the cut point
                MOV     DP, #bc_point          ; (for the every-tick look)
                STB     A, [DP]
                L       A, off(MOD_FUELWANT)   ; cutting now?
                OR      A, off(MOD_SPARKWANT)
                AND     A, #MB_BOOSTCUT
                JNE     boostcut_cutting
                CLRB    A
                LB      A, r4
                CMPB    ENG_MAP, A                ; MAP - cut point: no borrow once at or above it
                JLT     boostcut_off
                SJ      boostcut_on
boostcut_cutting:
                CLRB    A
                LB      A, r4
                SUBB    A, #003h               ; back in about 20 mbar under the cut point
                CMPB    ENG_MAP, A
                JLT     boostcut_off
boostcut_on:    MOV     X1, #boostcut_block
                L       A, #MB_BOOSTCUT
                SC
                CAL     mod_cut
                J       mod_tick_exit
boostcut_disabled:
                MOV     DP, #bc_point
                MOVB    [DP], #000h
boostcut_off:   MOV     X1, #boostcut_block
                L       A, #MB_BOOSTCUT
                RC
                CAL     mod_cut
                J       mod_tick_exit
endif

endif
