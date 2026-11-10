; ==================================================================================================
; iab.asm - intake air bypass butterflies (HTS "IAB (intake butterflies)" page)
;> feature: FEAT_IAB
;> name: IAB (intake butterflies)
;> category: Outputs
;> platforms: P13
;> pages: iab
;> ram: 1C1h bit 0 (its state)
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

if XP == XP_TICKSLOT
if SLOT_IAB == TICK_SLOT
                CAL     iab_tick
endif
endif

if XP == XP_CAL
;@ IABEnable type=u8 flag=1 on=1 off=0 category="Outputs" slot=iab.enable desc="Open the intake air bypass butterflies above the rpm below (the second runner set on IAB intakes)."
iab_enable:         DB  000h
;@ IABEngage type=u16 formula=rpm_period_word category="Outputs" slot=iab.engage desc="The butterflies are opened above this rpm."
iab_engage:         DW  000f6h                 ; 7620 rpm
;@ IABDisengage type=u16 formula=rpm_period_word category="Outputs" slot=iab.disengage desc="Switch off again below this rpm."
iab_disengage:      DW  00100h                 ; 7320 rpm
;@ IABOutput type=u8 category="Outputs" slot=iab.output desc="The output it drives: 0 none, 1 PB.0 (A/C clutch), 2 PB.7 (EVAP purge), 3 PC.2 (A/T), 4 the O2 heater (the CPU's P2A.2), 5 PC.3 (check-engine lamp), 6 none on the P13 (it has no ECU LED), 7 PB.3 (alternator control) high, 8 PB.3 low, 9 PB.0 held off (A/C clutch disengaged), 10 PB.2 (radiator fan), 11 PB.6 (spare; boost control uses it too). The 82C55's ports B and C; not tried on a car."
iab_output:         DB  002h
;@ IABInvert type=u8 flag=1 on=1 off=0 category="Outputs" slot=iab.invert desc="Drive the output while it is off instead."
iab_invert:         DB  000h
endif

if XP == XP_CODE
iab_tick:
                PUSHS   LRB
                MOV     LRB, #SVC_BANKT
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
                CMP     ENG_RPMP, A
                JGT     iab_drive
                SB      off(MOD_OUTSTATE).0
                SJ      iab_drive
iab_is_on: LC      A, iab_disengage  ; on: off once the period is past the disengage point
                CMP     ENG_RPMP, A
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
