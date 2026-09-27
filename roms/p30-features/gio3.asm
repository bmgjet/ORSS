; ==================================================================================================
; gio3.asm - programmable output 3 (HTS "GPO 3" page)
;> feature: FEAT_GIO3
;> name: GIO 3: programmable output
;> category: Outputs
;> pages: gpo3
;> ram: 1F1h bit 6, module RAM (1 byte)
;> about: An output of your choice, switched on when every condition set for it holds: a switch input,
;>        rpm (with hysteresis), throttle, manifold pressure, coolant, intake air, road speed, gear and
;>        battery windows, with an on and an off delay, or flashing while the conditions hold. A nitrous
;>        arming relay, an intercooler spray, a second fan, a warning light. Each of GIO 1-4 is its own
;>        function with its own page. Off until enabled.
; ==================================================================================================
ifdef FEAT_GIO3

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif
ifndef NEED_GIO
define NEED_GIO
endif
gio3_timer          EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (gio3_timer + 1)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_GIO3
                JNE     gio3_tick_skip
                CAL     gio3_tick
gio3_tick_skip:
endif

if XP == XP_CAL
;@ GIO3Enable type=u8 flag=1 on=1 off=0 category="GIO 3" slot=gpo3.enable desc="Programmable output 3 on."
gio3_block:              DB  000h
;@ GIO3Output type=u8 formula=raw category="GIO 3" slot=gpo3.output desc="The output it drives: 0 none, 1 P0.0 (A/C clutch), 2 P0.1 (EVAP purge), 3 P0.4 (A/T lock-up), 4 P1.2 (O2 heater), 5 P1.4 (check-engine lamp), 6 P1.5 (ECU LED), 7 P0.5 (alternator control) high, 8 P0.5 low, 9 P0.0 held off (A/C clutch disengaged)."
                        DB  000h
;@ GIO3OutputInvert type=u8 flag=1 on=1 off=0 category="GIO 3" slot=gpo3.output.invert desc="Drive the output while the conditions are not met, instead of while they are."
                        DB  000h
;@ GIO3Input type=u8 formula=raw category="GIO 3" slot=gpo3.input desc="A switch input that must be on: 01h power steering, 02h service connector, 04h start, 08h VTEC pressure, 10h A/C, 20h brake, 40h park/neutral, 80h always (80h: no input needed)."
                        DB  080h
;@ GIO3InputInvert type=u8 flag=1 on=1 off=0 category="GIO 3" slot=gpo3.input.invert desc="The input must be off instead."
                        DB  000h
;@ GIO3RpmOn type=u16 formula=rpm_period_word category="GIO 3" slot=gpo3.rpm.on desc="On at or above this rpm."
                        DW  0ffffh
;@ GIO3RpmOff type=u16 formula=rpm_period_word category="GIO 3" slot=gpo3.rpm.off desc="Once on, off again below this rpm (set it a little under the on rpm)."
                        DW  0ffffh
;@ GIO3ThrottleMin type=u8 formula=tps_pct category="GIO 3" slot=gpo3.tps.min desc="Throttle at least this."
                        DB  000h
;@ GIO3ThrottleMax type=u8 formula=tps_pct category="GIO 3" slot=gpo3.tps.max desc="Throttle no more than this."
                        DB  0ffh
;@ GIO3MapMin type=u8 formula=map_mbar category="GIO 3" slot=gpo3.map.min desc="Manifold pressure at least this."
                        DB  000h
;@ GIO3MapMax type=u8 formula=map_mbar category="GIO 3" slot=gpo3.map.max desc="Manifold pressure no more than this."
                        DB  0ffh
;@ GIO3CoolantMin type=u8 formula=honda_temp_c category="GIO 3" slot=gpo3.ect.min desc="Coolant at least this warm (the coldest setting: any)."
                        DB  0ffh
;@ GIO3CoolantMax type=u8 formula=honda_temp_c category="GIO 3" slot=gpo3.ect.max desc="Coolant no warmer than this (the hottest setting: any)."
                        DB  000h
;@ GIO3IntakeAirMin type=u8 formula=honda_temp_c category="GIO 3" slot=gpo3.iat.min desc="Intake air at least this warm (the coldest setting: any)."
                        DB  0ffh
;@ GIO3SpeedMin type=u8 formula=speed_kmh_byte category="GIO 3" slot=gpo3.speed.min desc="Road speed at least this."
                        DB  000h
;@ GIO3SpeedMax type=u8 formula=speed_kmh_byte category="GIO 3" slot=gpo3.speed.max desc="Road speed no more than this."
                        DB  0ffh
;@ GIO3GearMin type=u8 formula=raw category="GIO 3" slot=gpo3.gear.min desc="Gear at least this (needs gear detection; 0 = neutral or not known)."
                        DB  000h
;@ GIO3GearMax type=u8 formula=raw category="GIO 3" slot=gpo3.gear.max desc="Gear no more than this."
                        DB  0ffh
;@ GIO3BatteryMin type=u8 formula=battery_v category="GIO 3" slot=gpo3.batt.min desc="Battery at least this."
                        DB  000h
;@ GIO3OnDelay type=u8 formula="x * 32.8" inverse="x / 32.8" unit=ms decimals=0 category="GIO 3" slot=gpo3.delay.on desc="The conditions must hold this long before it switches on (flash mode: the time on and off)."
                        DB  000h
;@ GIO3OffDelay type=u8 formula="x * 32.8" inverse="x / 32.8" unit=ms decimals=0 category="GIO 3" slot=gpo3.delay.off desc="And stop holding this long before it switches off."
                        DB  000h
;@ GIO3Flash type=u8 flag=1 on=1 off=0 category="GIO 3" slot=gpo3.flash desc="Flash the output (on and off, each for the on delay) while the conditions hold: a warning light."
                        DB  000h
endif

if XP == XP_CODE
gio3_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                MOV     X1, #gio3_block
                MOV     X2, #gio3_timer
                LB      A, #040h                ; its bit in MOD_OUTSTATE
                CAL     mod_gio
                J       mod_tick_exit
endif

endif
