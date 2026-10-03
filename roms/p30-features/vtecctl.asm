; ==================================================================================================
; vtecctl.asm - VTEC: engage points, conditions, off altogether, and on another output (HTS "VTEC" page)
;> feature: FEAT_VTECCTL
;> name: VTEC control and alternative output
;> category: Outputs
;> pages: vtec
;> ram: none
;> about: The VTEC page as the established tuning software lays it out: switch VTEC off altogether (a
;>        non-VTEC head, or a conversion not wired yet), or engage it on your own points - an engage
;>        rpm at high throttle and one at low throttle, a drop-out margin, and minimum coolant, road
;>        speed and manifold pressure, each check able to be switched off. Can also repeat the VTEC
;>        solenoid on another free output: a VTEC lamp, or a solenoid wired to a different pin. Until
;>        "Use these engage points" is ticked the stock VTEC points decide, as without the module.
; ==================================================================================================
ifdef FEAT_VTECCTL

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif
; the skeleton asks mod_vtec, in the main loop, before its own VTEC decision
ifndef NEED_VTECHOOK
define NEED_VTECHOOK
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
;@ VTECEnable type=u8 flag=1 on=1 off=0 category="VTEC" slot=vtec.enable desc="VTEC engages. Off: the solenoid is never switched on, whatever else is set - a non-VTEC head, or a VTEC conversion not wired yet."
vtecctl_enable:         DB  001h
;@ VTECOwnPoints type=u8 flag=1 on=1 off=0 category="VTEC" slot=vtec.custom desc="Engage on the points and conditions on this page. Off: the stock VTEC points decide (the stock rows below), as a ROM without this module does."
vtecctl_custom:         DB  000h
; the engage rpm against throttle: two points, a straight line between them (vcal_2's table: high, then low)
;@ VTECTpsHigh type=u8 formula=tps_pct min=0 max=100 category="VTEC" slot=vtec.tps.high desc="High load: at or above this throttle, VTEC engages at the high load rpm."
vtecctl_points:         DB  093h                 ; 60 %
;@ VTECRpmHigh type=u8 formula=rpm_axis_byte_log min=1000 max=9500 category="VTEC" slot=vtec.rpm.high desc="High load engage rpm: where VTEC comes in with the throttle at or above the high load throttle. Between the two throttles the engage point is on a straight line between the two rpms."
                        DB  0cdh                 ; 4812 rpm
;@ VTECTpsLow type=u8 formula=tps_pct min=0 max=100 category="VTEC" slot=vtec.tps.low desc="Low load: at or below this throttle, VTEC engages at the low load rpm. Keep it below the high load throttle."
                        DB  042h                 ; 20 %
;@ VTECRpmLow type=u8 formula=rpm_axis_byte_log min=1000 max=9500 category="VTEC" slot=vtec.rpm.low desc="Low load engage rpm: where VTEC comes in with the throttle at or below the low load throttle (cruising)."
                        DB  0d8h                 ; 5500 rpm
;@ VTECDisengage type=u8 formula="x * 62.5" inverse="x / 62.5" unit=rpm decimals=0 min=0 max=1000 category="VTEC" slot=vtec.disengage desc="Once engaged, VTEC stays in until the rpm is this far under the engage point, so it does not chatter on and off at the point (62.5 rpm a step above 4000 rpm, 31.25 below)."
vtecctl_hyst:           DB  003h
;@ VTECMinCoolant type=u8 formula=honda_temp_c category="VTEC" slot=vtec.minect desc="Coolant at least this warm."
vtecctl_minect:         DB  044h
;@ VTECMinSpeed type=u8 formula=speed_kmh_byte min=0 max=250 category="VTEC" slot=vtec.minspeed desc="Road speed at least this: above 0 keeps VTEC out at a standstill (free revving in neutral)."
vtecctl_minspeed:       DB  000h
;@ VTECMinLoad type=u8 formula=map_mbar category="VTEC" slot=vtec.minload desc="Manifold pressure at least this."
vtecctl_minmap:         DB  000h
;@ VTECNoSpeedCheck type=u8 flag=1 on=1 off=0 category="VTEC" slot=vtec.nospeed desc="Leave the road speed out of it (no speed sensor, or a dyno on the front wheels)."
vtecctl_nospeed:        DB  000h
;@ VTECNoTempCheck type=u8 flag=1 on=1 off=0 category="VTEC" slot=vtec.notemp desc="Leave the coolant temperature out of it."
vtecctl_notemp:         DB  000h
;@ VTECNoErrorCheck type=u8 flag=1 on=1 off=0 category="VTEC" slot=vtec.noerror desc="Engage even with a sensor fault stored (the stock ECU keeps VTEC out while the MAP, throttle, coolant, crank or VTEC sensors have a fault). Needs the stock trouble codes built in to matter."
vtecctl_noerror:        DB  000h
;@ VTECAltEnable type=u8 flag=1 on=1 off=0 category="VTEC" slot=vtec.alt.enable desc="Repeat the VTEC solenoid on another output."
vtecctl_alt:            DB  000h
;@ VTECAltOutput type=u8 category="VTEC" slot=vtec.alt.output desc="The output: 0 none, 1 P0.0 (A/C clutch, A15), 2 P0.1 (EVAP purge), 3 P0.4 (A/T lock-up, automatic ECUs), 4 P1.2 (O2 heater), 5 P1.4 (check-engine lamp, A13), 6 P1.5 (ECU LED), 7 P0.2 (alternator control, A16) high, 8 P0.2 low, 9 P0.0 held off (A/C clutch disengaged), 10 P0.3 (radiator fan), 11 P4.3 (pin A17; boost control uses it too)."
vtecctl_output:         DB  006h
;@ VTECAltInvert type=u8 flag=1 on=1 off=0 category="VTEC" slot=vtec.alt.invert desc="Drive it while VTEC is off instead."
vtecctl_invert:         DB  000h
endif

if XP == XP_CODE
; ------------------------------------------------------------------ the decision (skeleton hook, main loop)
; Called before the stock VTEC decision, with the stock's rpm flags and load point worked out. r0, r1, r6
; and r7 are free (the stock code has just used them for its own table lookup); keep the rest.
; Out: C clear - the stock decision goes ahead. C set - A (byte) = 0 VTEC off altogether (as a ROM with no
; VTEC), 1 off for now, 2 on.
mod_vtec:       CLRB    A
                LCB     A, vtecctl_enable
                CMPB    A, #000h
                JEQ     mv_never
                LCB     A, vtecctl_custom
                CMPB    A, #000h
                JNE     mv_own
                RC                             ; the stock points
                RT
mv_never:       CLRB    A
                SC
                RT

mv_own:         L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                CLRB    A
if defined(FEAT_STOCK_DTC)
                LCB     A, vtecctl_noerror     ; the stock fault check: MAP, throttle, coolant, crank, VTEC
                CMPB    A, #000h
                JNE     mv_faults_ok
                MOV     DP, #00112h
                L       A, [DP]
                AND     A, #0c0bch
                JNE     mv_none
                INC     DP
                INC     DP
                LB      A, [DP]
                ANDB    A, #031h
                JNE     mv_none
endif
mv_faults_ok:   LB      A, 0e9h                ; as stock: not in the first seconds after a start
                CMPB    A, #032h
                JLT     mv_off
                LCB     A, vtecctl_notemp
                CMPB    A, #000h
                JNE     mv_temp_ok
                LCB     A, vtecctl_minect      ; coolant: a larger byte is colder
                STB     A, r0
                LB      A, 0c1h
                CMPB    A, r0
                JGT     mv_off
mv_temp_ok:     LCB     A, vtecctl_nospeed
                CMPB    A, #000h
                JNE     mv_speed_ok
                LCB     A, vtecctl_minspeed
                STB     A, r0
                LB      A, 0b4h
                CMPB    A, r0
                JLT     mv_off
mv_speed_ok:    LCB     A, vtecctl_minmap
                STB     A, r0
                LB      A, 0a3h
                CMPB    A, r0
                JLT     mv_off
; the engage point for this throttle: the low point's rpm at or under its throttle, the high point's at or
; over its, a straight line in between (vcal_2 only gets a throttle strictly between the two)
                MOV     X1, #vtecctl_points
                LCB     A, 00002h[X1]
                STB     A, r0
                LB      A, 0b9h
                CMPB    A, r0
                JGT     mv_above_low
                LCB     A, 00003h[X1]
                SJ      mv_point
mv_above_low:   LCB     A, [X1]
                STB     A, r0
                LB      A, 0b9h
                CMPB    A, r0
                JLT     mv_between
                LCB     A, 00001h[X1]
                SJ      mv_point
mv_between:     VCAL    2
mv_point:       STB     A, r0
                MOV     DP, #0011fh            ; engaged now (11Fh bit 2): it holds down to the point less the margin
                MB      C, [DP].2
                JGE     mv_compare
                CLRB    A
                LCB     A, vtecctl_hyst
                STB     A, r1
                LB      A, r0
                SUBB    A, r1
                JGE     mv_hyst_set
                CLRB    A
mv_hyst_set:    STB     A, r0
mv_compare:     MOV     DP, #0012dh            ; the rpm byte the stock points are compared with
                LB      A, [DP]
                CMPB    A, r0
                JLT     mv_off
                LB      A, #002h
                SJ      mv_ret
mv_none:        CLRB    A
                SJ      mv_ret
mv_off:         LB      A, #001h
mv_ret:         STB     A, r1
                POPS    A
                MOV     X1, A
                POPS    A
                MOV     DP, A
                LB      A, r1
                SC
                RT

; ------------------------------------------------------------------ the second output (tick)
; Tick context: only A is free until the registers are saved.
vtecctl_tick:   CLRB    A
                LCB     A, vtecctl_alt
                CMPB    A, #000h
                JNE     vtecctl_used
                RT                             ; not used: the output is left to whatever else drives it
vtecctl_used:   PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
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
