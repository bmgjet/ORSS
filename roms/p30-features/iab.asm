; ==================================================================================================
; iab.asm - intake air bypass butterflies (HTS "IAB (intake butterflies)" page)
;> feature: FEAT_IAB
;> name: IAB (intake butterflies)
;> category: Outputs
;> pages: iab
;> ram: 1F1h bit 0 (its state)
;> about: Opens the intake manifold's secondary butterflies (IAB, on B16/B18C manifolds) above an rpm
;>        and shuts them again below a lower one, through one of the outputs the skeleton leaves free
;>        (the EVAP purge output is the usual one on a car without purge). Off until enabled.
; ==================================================================================================
ifdef FEAT_IAB

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_IAB
                JNE     iab_tick_skip
                CAL     iab_tick
iab_tick_skip:
endif

if XP == XP_CAL
;@ IABEnable type=u8 flag=1 on=1 off=0 category="Outputs" slot=iab.enable desc="On."
iab_enable:         DB  000h
;@ IABEngage type=u16 formula=rpm_period_word category="Outputs" slot=iab.engage desc="Switch on above this rpm."
iab_engage:         DW  000f6h                 ; 7620 rpm
;@ IABDisengage type=u16 formula=rpm_period_word category="Outputs" slot=iab.disengage desc="Switch off again below this rpm."
iab_disengage:      DW  00100h                 ; 7320 rpm
;@ IABOutput type=u8 category="Outputs" slot=iab.output desc="The output it drives: 0 none, 1 P0.0 (A/C clutch), 2 P0.1 (EVAP purge), 3 P0.4 (A/T lock-up), 4 P1.2 (O2 heater), 5 P1.4 (check-engine lamp), 6 P1.5 (ECU LED)."
iab_output:         DB  002h
;@ IABInvert type=u8 flag=1 on=1 off=0 category="Outputs" slot=iab.invert desc="Drive the output while it is off instead."
iab_invert:         DB  000h
endif

if XP == XP_CODE
iab_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, iab_enable
                CMPB    A, #000h
                JEQ     iab_turn_off_quiet
                CLRB    A
                LB      A, off(MOD_OUTSTATE)
                ANDB    A, #001h
                JNE     iab_is_on
                LC      A, iab_engage     ; off: on once the period is down to the engage point
                CMP     0ach, A
                JGT     iab_drive
                SB      off(MOD_OUTSTATE).0
                SJ      iab_drive
iab_is_on: LC      A, iab_disengage  ; on: off once the period is past the disengage point
                CMP     0ach, A
                JGT     iab_turn_off
                SJ      iab_drive
iab_turn_off:
                RB      off(MOD_OUTSTATE).0
iab_drive: CLRB    A                      ; the state, through the invert, to the output
                LB      A, off(MOD_OUTSTATE)
                ANDB    A, #001h
                STB     A, r3
                LCB     A, iab_invert
                CMPB    A, #000h
                JEQ     iab_noinv
                LB      A, r3
                XORB    A, #001h
                STB     A, r3
iab_noinv: LB      A, r3
                CMPB    A, #000h
                SC
                JNE     iab_set
                RC
iab_set:   CLRB    A
                LCB     A, iab_output
                CAL     mod_output
                J       mod_tick_exit
iab_turn_off_quiet:                       ; disabled: hand the pin back
                RB      off(MOD_OUTSTATE).0
                RC
                SJ      iab_set
endif

endif
