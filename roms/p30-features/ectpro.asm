; ==================================================================================================
; ectpro.asm - engine protection on coolant temperature (HTS "ECT protection" page)
;> feature: FEAT_ECTPRO
;> name: Coolant temperature protection
;> category: Protection
;> pages: ectpro
;> ram: 1F2h-1F5h (shared cut requests), the rev cap: 2 bytes of module RAM shared by every rev limit (lib.asm)
;> about: Once the coolant is hotter than a set temperature the engine is held to a lower rev limit, so
;>        an overheating engine limps home instead of being driven hard. Fuel cut, ignition cut or both.
;>        And a warm-up limit: a lower rev limit while the coolant is colder than a second temperature,
;>        so a cold engine is not driven hard. Each off until enabled.
; ==================================================================================================
ifdef FEAT_ECTPRO

if XP == XP_DEFS
ifndef NEED_REVCAP
define NEED_REVCAP                             ; (its rev limit is a hard limit for the crank interrupt too: lib.asm)
endif
ifndef NEED_MODLIB
define NEED_MODLIB
endif
endif

if XP == XP_TICKSLOT
if SLOT_ECTPRO == TICK_SLOT
                CAL     ectpro_tick
endif
endif

if XP == XP_CAL
;@ ECTProEnable type=u8 flag=1 on=1 off=0 category="ECT protection" slot=ectpro.enable desc="Coolant temperature protection on."
ectpro_block:           DB  000h
;@ ECTProCut type=u8 category="ECT protection" slot=ectpro.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
ectpro_cut:             DB  000h
;@ ECTProRPM type=u16 formula=rpm_period_word category="ECT protection" slot=ectpro.rpm desc="While the coolant is too hot, the rev limit drops to this."
ectpro_set:             DW  00177h               ; 5000 rpm
;@ ECTProRPMReset type=u16 formula=rpm_period_word category="ECT protection" slot=ectpro.rpm.reset desc="Fuel / spark come back once the rpm falls under this."
ectpro_reset:           DW  00181h               ; 4870 rpm
;@ ECTProTemp type=u8 formula=honda_temp_c category="ECT protection" slot=ectpro.ect desc="Too hot above this coolant temperature."
ectpro_ect:             DB  010h                 ; 110 C
;@ ECTProColdEnable type=u8 flag=1 on=1 off=0 category="ECT protection" slot=ectpro.cold.enable desc="Warm-up rev limit: a lower rev limit until the coolant is warm, so a cold engine is not driven hard."
ectpro_cold_block:      DB  000h
;@ ECTProColdCut type=u8 category="ECT protection" slot=ectpro.cold.cut desc="Warm-up limit: 0 = fuel cut, 1 = ignition cut, 2 = both."
ectpro_cold_cut:        DB  000h
;@ ECTProColdRPM type=u16 formula=rpm_period_word category="ECT protection" slot=ectpro.cold.rpm desc="While the coolant is cold, the rev limit is this."
ectpro_cold_set:        DW  001d5h               ; 4000 rpm
;@ ECTProColdRPMReset type=u16 formula=rpm_period_word category="ECT protection" slot=ectpro.cold.rpm.reset desc="Warm-up limit: fuel / spark come back once the rpm falls under this."
ectpro_cold_reset:      DW  001edh               ; 3800 rpm
;@ ECTProColdTemp type=u8 formula=honda_temp_c category="ECT protection" slot=ectpro.cold.ect desc="Cold below this coolant temperature."
ectpro_cold_ect:        DB  064h                 ; about 40 C (44 on the page's curve)
endif

if XP == XP_CODE
ectpro_tick:
                PUSHS   LRB
                MOV     LRB, #SVC_BANKT
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, ectpro_ect
                CMPB    ENG_ECT, A             ; coolant byte - threshold borrows (C) once hotter than it
                MOV     X1, #ectpro_block      ; too hot: its limit...
                JLT     ectpro_go
                LCB     A, ectpro_cold_ect     ; ...else cold? threshold - coolant byte borrows (C) while colder (a larger byte)
                CMPB    A, ENG_ECT
                MOV     X1, #ectpro_cold_block ; cold: the warm-up limit; neither: that block, let go (C clear)
ectpro_go:      L       A, #MB_ECTPRO
                CAL     mod_limit
                J       mod_tick_exit
endif

endif
