; ==================================================================================================
; vtecctl.asm - VTEC off, and VTEC on another output (HTS "VTEC" page)
;> feature: FEAT_VTECCTL
;> name: VTEC control and alternative output
;> category: Outputs
;> pages: vtec
;> ram: none
;> about: Switches VTEC off altogether (for a non-VTEC head, or a VTEC conversion not wired yet), and
;>        repeats the VTEC solenoid on another free output - a VTEC lamp, or a solenoid wired to a
;>        different pin. The engage points stay in the skeleton's own VTEC calibration. Off until
;>        enabled.
; ==================================================================================================
ifdef FEAT_VTECCTL

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
                CMPB    A, #SLOT_VTECCTL
                JNE     vtecctl_tick_skip
                CAL     vtecctl_tick
vtecctl_tick_skip:
endif

if XP == XP_CAL
;@ VTECDisable type=u8 flag=1 on=1 off=0 category="VTEC" slot=vtec.disable desc="VTEC never engages (the solenoid stays off)."
vtecctl_disable:        DB  000h
;@ VTECAltEnable type=u8 flag=1 on=1 off=0 category="VTEC" slot=vtec.alt.enable desc="Repeat the VTEC solenoid on another output."
vtecctl_alt:            DB  000h
;@ VTECAltOutput type=u8 category="VTEC" slot=vtec.alt.output desc="The output: 0 none, 1 P0.0 (A/C clutch), 2 P0.1 (EVAP purge), 3 P0.4 (A/T), 4 P1.2 (O2 heater), 5 P1.4 (check-engine lamp), 6 P1.5 (ECU LED)."
vtecctl_output:         DB  006h
;@ VTECAltInvert type=u8 flag=1 on=1 off=0 category="VTEC" slot=vtec.alt.invert desc="Drive it while VTEC is off instead."
vtecctl_invert:         DB  000h
endif

if XP == XP_CODE
vtecctl_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                MOV     DP, #003deh            ; P1.0: take it (off) or hand it back
                CLRB    A
                LCB     A, vtecctl_disable
                CMPB    A, #000h
                JEQ     vtecctl_release
                RB      [DP].0
                INC     DP
                RB      [DP].0
                SJ      vtecctl_alt_out
vtecctl_release:
                SB      [DP].0
                INC     DP
                RB      [DP].0
vtecctl_alt_out:
                CLRB    A
                LCB     A, vtecctl_alt
                CMPB    A, #000h
                RC
                JEQ     vtecctl_drive
                MB      C, P1.0                ; the solenoid as it goes out
                CLRB    A
                MB      ACC.0, C
                STB     A, r3
                LCB     A, vtecctl_invert
                ANDB    A, #001h
                XORB    A, r3
                CMPB    A, #000h
                SC
                JNE     vtecctl_drive
                RC
vtecctl_drive:  CLRB    A
                LCB     A, vtecctl_output
                CAL     mod_output
                J       mod_tick_exit
endif

endif
