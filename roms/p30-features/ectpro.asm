; ==================================================================================================
; ectpro.asm - engine protection on coolant temperature (HTS "ECT protection" page)
;> feature: FEAT_ECTPRO
;> name: Coolant temperature protection
;> category: Protection
;> pages: ectpro
;> ram: 1F2h-1F5h (shared cut requests)
;> about: Once the coolant is hotter than a set temperature the engine is held to a lower rev limit, so
;>        an overheating engine limps home instead of being driven hard. Fuel cut, ignition cut or both.
;>        Off until enabled.
; ==================================================================================================
ifdef FEAT_ECTPRO

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_ECTPRO
                JNE     ectpro_tick_skip
                CAL     ectpro_tick
ectpro_tick_skip:
endif

if XP == XP_CAL
;@ ECTProEnable type=u8 flag=1 on=1 off=0 category="ECT protection" slot=ectpro.enable desc="Coolant temperature protection on."
ectpro_block:           DB  000h
;@ ECTProCut type=u8 category="ECT protection" slot=ectpro.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
ectpro_cut:             DB  000h
;@ ECTProRPM type=u16 formula=rpm_period_word category="ECT protection" slot=ectpro.rpm desc="Rev limit while too hot."
ectpro_set:             DW  00177h               ; 5000 rpm
;@ ECTProRPMReset type=u16 formula=rpm_period_word category="ECT protection" slot=ectpro.rpm.reset desc="Back in below this rpm."
ectpro_reset:           DW  00181h               ; 4870 rpm
;@ ECTProTemp type=u8 formula=honda_temp_c category="ECT protection" slot=ectpro.ect desc="Too hot above this coolant temperature."
ectpro_ect:             DB  010h                 ; 110 C
endif

if XP == XP_CODE
ectpro_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, ectpro_ect
                CMPB    0c1h, A                ; coolant byte - threshold borrows (C) once hotter than it
                MOV     X1, #ectpro_block
                L       A, #MB_ECTPRO
                CAL     mod_limit
                J       mod_tick_exit
endif

endif
