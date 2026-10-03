; ==================================================================================================
; rpmswitch.asm - an output switched on rpm and throttle (HTS alternative outputs)
;> feature: FEAT_RPMSWITCH
;> name: Rpm-switched output
;> category: Outputs
;> pages: rpmswitch
;> ram: 1F1h bit 1 (its state)
;> about: A general-purpose switch: an output comes on above one rpm (and above a throttle opening, if
;>        set) and goes off below another - a second shift light, a nitrous arming signal, an
;>        intercooler spray, a relay for a fan. Uses one of the outputs the skeleton leaves free. Off
;>        until enabled.
; ==================================================================================================
ifdef FEAT_RPMSWITCH

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
                CMPB    A, #SLOT_RPMSWITCH
                JNE     rpmsw_tick_skip
                CAL     rpmsw_tick
rpmsw_tick_skip:
endif

if XP == XP_CAL
;@ RpmSwitchEnable type=u8 flag=1 on=1 off=0 category="Outputs" slot=rpmswitch.enable desc="On."
rpmsw_enable:         DB  000h
;@ RpmSwitchOn type=u16 formula=rpm_period_word category="Outputs" slot=rpmswitch.engage desc="Switch on above this rpm."
rpmsw_engage:         DW  0017ah                 ; 4970 rpm
;@ RpmSwitchOff type=u16 formula=rpm_period_word category="Outputs" slot=rpmswitch.disengage desc="Switch off again below this rpm."
rpmsw_disengage:      DW  00187h                 ; 4800 rpm
;@ RpmSwitchOutput type=u8 category="Outputs" slot=rpmswitch.output desc="The output it drives: 0 none, 1 P0.0 (A/C clutch, A15), 2 P0.1 (EVAP purge), 3 P0.4 (A/T lock-up, automatic ECUs), 4 P1.2 (O2 heater), 5 P1.4 (check-engine lamp, A13), 6 P1.5 (ECU LED), 7 P0.2 (alternator control, A16) high, 8 P0.2 low, 9 P0.0 held off (A/C clutch disengaged), 10 P0.3 (radiator fan), 11 P4.3 (pin A17; boost control uses it too)."
rpmsw_output:         DB  006h
;@ RpmSwitchInvert type=u8 flag=1 on=1 off=0 category="Outputs" slot=rpmswitch.invert desc="Drive the output while it is off instead."
rpmsw_invert:         DB  000h
;@ RpmSwitchMinTPS type=u8 formula=tps_pct category="Outputs" slot=rpmswitch.tps desc="Only with the throttle at least this far open (0 = any)."
rpmsw_tps:            DB  019h                 ; 0 %
endif

if XP == XP_CODE
rpmsw_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, rpmsw_enable
                CMPB    A, #000h
                JEQ     rpmsw_turn_off_quiet
                CLRB    A
                LB      A, off(MOD_OUTSTATE)
                ANDB    A, #002h
                JNE     rpmsw_is_on
                LC      A, rpmsw_engage     ; off: on once the period is down to the engage point
                CMP     0ach, A
                JGT     rpmsw_drive
                CLRB    A                      ; and the throttle far enough open
                LCB     A, rpmsw_tps
                CMPB    0b9h, A
                JLT     rpmsw_turn_off
                SB      off(MOD_OUTSTATE).1
                SJ      rpmsw_drive
rpmsw_is_on: LC      A, rpmsw_disengage  ; on: off once the period is past the disengage point
                CMP     0ach, A
                JGT     rpmsw_turn_off
                CLRB    A                      ; and the throttle far enough open
                LCB     A, rpmsw_tps
                CMPB    0b9h, A
                JLT     rpmsw_turn_off
                SJ      rpmsw_drive
rpmsw_turn_off:
                RB      off(MOD_OUTSTATE).1
rpmsw_drive: CLRB    A                      ; the state, through the invert, to the output
                LB      A, off(MOD_OUTSTATE)
                ANDB    A, #002h
                STB     A, r3
                LCB     A, rpmsw_invert
                CMPB    A, #000h
                JEQ     rpmsw_noinv
                LB      A, r3
                XORB    A, #002h
                STB     A, r3
rpmsw_noinv: LB      A, r3
                CMPB    A, #000h
                SC
                JNE     rpmsw_set
                RC
rpmsw_set:   CLRB    A
                LCB     A, rpmsw_output
                CAL     mod_output
                J       mod_tick_exit
rpmsw_turn_off_quiet:                       ; disabled: hand the pin back
                RB      off(MOD_OUTSTATE).1
                RC
                SJ      rpmsw_set
endif

endif
