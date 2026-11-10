; ==================================================================================================
; nitrous.asm - nitrous (N2O): a second fuel and timing map blended in by the size of the shot
;> feature: FEAT_NITROUS
;> name: Nitrous (N2O)
;> category: Fuel
;> platforms: P13
;> pages: nitrous
;> conflicts: FEAT_DUALMAPS, FEAT_MAPSWITCH
;> ram: 0FDh bit 5 (spraying), module RAM (6 bytes: the shot factor, and the lookup's map, column and first value kept between its two lookups)
;> about: While the arming switch is on, the throttle is open and the rpm is inside its window, the
;>        nitrous maps (a second fuel and ignition map, low and high cam, set up for the base shot - a
;>        50 hp jet, say) are used, and an output can drive the solenoid. A shot input - a voltage on a
;>        free analog pin, or a serial input over the datalog cable - scales how far the nitrous maps are
;>        from the normal ones: 100 % is the maps as tuned, 150 % half as much more fuel and timing out
;>        again (a 75 hp jet), 200 % twice the change (100 hp). The shot table says what each voltage
;>        means, blended between its points. Off until enabled.
; ==================================================================================================
ifdef FEAT_NITROUS

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif
ifndef NEED_MAPLOOKUP
define NEED_MAPLOOKUP
endif
; the shot factor: 64 = the nitrous maps as tuned (100 %), 128 = twice their change (200 %)
nos_k           EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (nos_k + 1)
; (P13) the lookup's inputs kept between its two lookups: the shot map (word), the column, the first value
nos13_map       EQU     ((MODRAM_NEXT + 1) / 2) * 2
nos13_col       EQU     nos13_map + 2
nos13_norm      EQU     nos13_map + 3
undef MODRAM_NEXT
define MODRAM_NEXT (nos13_map + 4)
endif

if XP == XP_TICKSLOT
if SLOT_NITROUS == TICK_SLOT
                CAL     nos_tick
endif
endif

if XP == XP_CAL
;@ NitrousEnable type=u8 flag=1 on=1 off=0 category="Nitrous" slot=nitrous.enable desc="Nitrous mode: the nitrous maps (and the solenoid output) while armed, the throttle open and the rpm inside the window."
nos_enable:             DB  000h
;@ NitrousInput type=u8 category="Nitrous" slot=nitrous.input desc="The arming switch: 01h power steering, 02h service connector, 04h start, 08h VTEC pressure, 10h A/C, 20h brake, 40h park/neutral, 80h always, 00h never, C0h-C7h serial input 1-8 (on while not 0). On the P13 the brake (20h) is not traced yet and reads off, and park/neutral (40h) is an automatic's (a manual reads off)."
nos_input:              DB  000h
;@ NitrousInputInvert type=u8 flag=1 on=1 off=0 category="Nitrous" slot=nitrous.input.invert desc="Armed while the switch is off instead."
nos_invert:             DB  000h
;@ NitrousMinTPS type=u8 formula=tps_pct category="Nitrous" slot=nitrous.tps desc="Only with the throttle at least this far open (nitrous at part throttle is how engines are lost)."
nos_tps:                DB  0d1h                 ; 90 %
;@ NitrousMinRPM type=u16 formula=rpm_period_word category="Nitrous" slot=nitrous.rpm.min desc="Only at or above this rpm (too low and the shot hammers the engine)."
nos_rpm_min:            DW  00271h               ; 3000 rpm
;@ NitrousMaxRPM type=u16 formula=rpm_period_word category="Nitrous" slot=nitrous.rpm.max desc="And only up to this rpm (keep it under the rev limit, so the shot is off before the limiter)."
nos_rpm_max:            DW  0010ch               ; 7000 rpm
;@ NitrousOutput type=u8 category="Nitrous" slot=nitrous.output desc="The output that drives the nitrous solenoid (through a relay): 0 none, 1 PB.0 (A/C clutch), 2 PB.7 (EVAP purge), 3 PC.2 (A/T), 4 the O2 heater (the CPU's P2A.2), 5 PC.3 (check-engine lamp), 6 none on the P13 (it has no ECU LED), 7 PB.3 (alternator control) high, 8 PB.3 low, 9 PB.0 held off (A/C clutch disengaged), 10 PB.2 (radiator fan), 11 PB.6 (spare; boost control uses it too). The 82C55's ports B and C; not tried on a car."
nos_output:             DB  000h
;@ NitrousShotInput type=u8 category="Nitrous" slot=nitrous.shotinput desc="Where the shot size comes from: 0 O2, 1 ELD, 2 EGR lift (P5.3), 3 the TCS pin (P5.5) (each 0-5 V), 4-11 serial input 1-8 (over the datalog cable, 0-255 as 0-5 V), FFh none (the nitrous maps as tuned, 100 %)."
nos_shot_in:            DB  0ffh
;@ NitrousShot type=u8 count=9 formula="x * 100 / 64" inverse="x * 64 / 100" unit=% decimals=0 colvalues=0,0.625,1.25,1.875,2.5,3.125,3.75,4.375,5 colunit=V category="Nitrous" slot=nitrous.shot desc="How much of the nitrous maps' change from the normal maps is used, against the shot input: 100 % is the maps as tuned (the base jet), 150 % half as much more fuel and timing taken out again, 200 % twice the change. Blended between the points."
nos_shot:               DB  040h, 054h, 068h, 07ch, 090h, 0a4h, 0b8h, 0cch, 0e0h   ; +50 % a volt: 1 V 150 %, 2 V 200 %
endif

if XP == XP_CODE
; ------------------------------------------------------------------ the slot: armed, open throttle, inside the window
nos_tick:       PUSHS   LRB
                MOV     LRB, #SVC_BANKT
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, nos_enable
                CMPB    A, #000h
                JEQ     nos_off
                MOV     X1, #nos_input
                CAL     mod_switch             ; armed? (uses DP, r7)
                JEQ     nos_off
                CLRB    A
                LCB     A, nos_tps
                CMPB    ENG_TPS, A                ; throttle - the point: borrows while under it
                JLT     nos_off
                CLR     A
                LC      A, nos_rpm_min
                CMP     ENG_RPMP, A                ; the period past the minimum's: under the rpm
                JGT     nos_off
                LC      A, nos_rpm_max
                CMP     ENG_RPMP, A                ; the period short of the maximum's: over the rpm
                JLT     nos_off
                CLRB    A                      ; the shot factor
                LCB     A, nos_shot_in
                CMPB    A, #0ffh
                JEQ     nos_k100
                CAL     mod_analog             ; A = 0-255 (uses DP, r7)
                MOV     X1, #nos_shot
                CAL     mod_lookup9            ; blended between the points (uses r0-r7, X1)
                SJ      nos_kset
nos_k100:       LB      A, #040h
nos_kset:       MOV     DP, #nos_k
                STB     A, [DP]
                SB      0fdh.5                 ; spraying: the map lookups blend the nitrous maps in
                SC
                SJ      nos_drive
nos_off:        RB      0fdh.5
                RC
nos_drive:      CLRB    A                      ; the solenoid output (0: none)
                LCB     A, nos_output
                CAL     mod_output
                J       mod_tick_exit

; ------------------------------------------------------------------ the map lookups (the skeleton's hook)
; In place of table2d_lookup_interp, with its inputs (X1 the map, er0 and er1 the row and column, er3 and X2
; the fractions, PSWL.5). Spraying, a map with a nitrous one is looked up in both and the value blended:
; normal + (nitrous - normal) x the shot factor / 64. Out: A and er2, as table2d_lookup_interp. The crank task
; and the main loop both look maps up, and the crank task can come in on the main loop's lookup: so
; everything is kept on the stack.
; P13: the skeleton calls it in place of its map lookup (main loop): DP the map, A (byte) the row, r1 the column, X1
; and X2 their fractions (kept by the lookup). Out: A (byte), the normal map's value moved toward the shot map's by
; the shot factor. Uses what the lookup uses (r0-r7, DP).
mod_maplookup:  MB      C, 0fdh.5
                JLT     nos13_blend
                J       SKEL_LOOKUP
nos13_blend:    PUSHS   A                      ; the row
                L       A, DP
                PUSHS   A                      ; the map
                CMP     A, #FuelLow
                JNE     nos13_m1
                L       A, #FuelLow2
                SJ      nos13_have
nos13_m1:       CMP     A, #FuelHigh
                JNE     nos13_m2
                L       A, #FuelHigh2
                SJ      nos13_have
nos13_m2:       CMP     A, #IgnitionLow
                JNE     nos13_m3
                L       A, #IgnitionLow2
                SJ      nos13_have
nos13_m3:       CMP     A, #IgnitionHigh
                JEQ     nos13_m4
                POPS    A                      ; (no shot map: the plain lookup)
                MOV     DP, A
                POPS    A
                LB      A, ACC
                J       SKEL_LOOKUP
nos13_m4:       L       A, #IgnitionHigh2
nos13_have:     MOV     DP, #nos13_map
                ST      A, [DP]
                MOV     DP, #nos13_col
                LB      A, r1
                STB     A, [DP]
                POPS    A
                MOV     DP, A                  ; the normal map...
                POPS    A
                PUSHS   A
                LB      A, ACC                 ; ...at the row
                CAL     SKEL_LOOKUP
                MOV     DP, #nos13_norm
                STB     A, [DP]
                MOV     DP, #nos13_col
                LB      A, [DP]
                STB     A, r1
                MOV     DP, #nos13_map
                L       A, [DP]
                MOV     DP, A                  ; the shot map, at the same place
                POPS    A
                LB      A, ACC
                CAL     SKEL_LOOKUP
                STB     A, r4
                CLRB    r5                     ; er2: the shot map's value
                MOV     DP, #nos13_norm
                LB      A, [DP]
                STB     A, r6
                CLRB    r7                     ; er3: the normal one
                L       A, er2
                SUB     A, er3
                JLT     nos13_less             ; the shot map lower
                CAL     nos_scale
                ADD     A, er3
                SJ      nos13_clip
nos13_less:     L       A, er3
                SUB     A, er2
                CAL     nos_scale
                ST      A, er0
                L       A, er3
                SUB     A, er0
                JGE     nos13_clip
                CLR     A
nos13_clip:     CMP     A, #000ffh
                JLE     nos13_ret
                L       A, #000ffh
nos13_ret:      LB      A, ACC
                RT

; A (word) x the shot factor / 64, held at FFFFh. Uses er0, er1, DP.
nos_scale:      ST      A, er1
                CLR     A
                MOV     DP, #nos_k
                LB      A, [DP]
                L       A, ACC
                ST      A, er0
                L       A, er1
                MUL                            ; er1:A = A x er0
                SRL     er1
                ROR     A
                SRL     er1
                ROR     A
                SRL     er1
                ROR     A
                SRL     er1
                ROR     A
                SRL     er1
                ROR     A
                SRL     er1
                ROR     A
                ST      A, er0
                L       A, er1
                JEQ     nos_scale_ok
                L       A, #0ffffh
                RT
nos_scale_ok:   L       A, er0
                RT
endif

endif
