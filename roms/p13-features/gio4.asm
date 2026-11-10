; ==================================================================================================
; gio4.asm - programmable output 4 (HTS "GPO 4" page)
;> feature: FEAT_GIO4
;> name: GIO 4: programmable output
;> category: Outputs
;> platforms: P13
;> pages: gpo4
;> ram: 1C1h bit 7, module RAM (1 byte)
;> about: An output of your choice, switched on when every condition set for it holds: a switch input,
;>        rpm (with hysteresis), throttle, manifold pressure, coolant, intake air, road speed, gear and
;>        battery windows, with an on and an off delay, or flashing while the conditions hold. A nitrous
;>        arming relay, an intercooler spray, a second fan, a warning light. Each of GIO 1-4 is its own
;>        function with its own page. Off until enabled.
; ==================================================================================================
ifdef FEAT_GIO4

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
gio4_timer          EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (gio4_timer + 1)
endif

if XP == XP_TICKSLOT
if SLOT_GIO4 == TICK_SLOT
                CAL     gio4_tick
endif
endif

if XP == XP_CAL
;@ GIO4Enable type=u8 flag=1 on=1 off=0 category="GIO 4" slot=gpo4.enable desc="Programmable output 4: drive the chosen output while every condition below is met (an rpm window, throttle, speed, gear, battery)."
gio4_block:              DB  000h
;@ GIO4Output type=u8 formula=raw category="GIO 4" slot=gpo4.output desc="The output it drives: 0 none, 1 PB.0 (A/C clutch), 2 PB.7 (EVAP purge), 3 PC.2 (A/T), 4 the O2 heater (the CPU's P2A.2), 5 PC.3 (check-engine lamp), 6 none on the P13 (it has no ECU LED), 7 PB.3 (alternator control) high, 8 PB.3 low, 9 PB.0 held off (A/C clutch disengaged), 10 PB.2 (radiator fan), 11 PB.6 (spare; boost control uses it too). The 82C55's ports B and C; not tried on a car."
                        DB  000h
;@ GIO4OutputInvert type=u8 flag=1 on=1 off=0 category="GIO 4" slot=gpo4.output.invert desc="Drive the output while the conditions are not met, instead of while they are."
                        DB  000h
;@ GIO4Input type=u8 formula=raw category="GIO 4" slot=gpo4.input desc="A switch input that must be on: 01h power steering, 02h service connector, 04h start, 08h VTEC pressure, 10h A/C, 20h brake, 40h park/neutral, 80h always (80h: no input needed). On the P13 the brake (20h) is not traced yet and reads off, and park/neutral (40h) is an automatic's (a manual reads off)."
                        DB  080h
;@ GIO4InputInvert type=u8 flag=1 on=1 off=0 category="GIO 4" slot=gpo4.input.invert desc="The input must be off instead."
                        DB  000h
;@ GIO4RpmOn type=u16 formula=rpm_period_word category="GIO 4" slot=gpo4.rpm.on desc="On at or above this rpm (off again below the off point)."
                        DW  0ffffh
;@ GIO4RpmOff type=u16 formula=rpm_period_word category="GIO 4" slot=gpo4.rpm.off desc="Once on, off again below this rpm (set it a little under the on rpm)."
                        DW  0ffffh
;@ GIO4ThrottleMin type=u8 formula=tps_pct category="GIO 4" slot=gpo4.tps.min desc="Throttle at least this open."
                        DB  000h
;@ GIO4ThrottleMax type=u8 formula=tps_pct category="GIO 4" slot=gpo4.tps.max desc="Throttle no more than this open."
                        DB  0ffh
;@ GIO4MapMin type=u8 formula=map_mbar category="GIO 4" slot=gpo4.map.min desc="Manifold pressure at least this."
                        DB  000h
;@ GIO4MapMax type=u8 formula=map_mbar category="GIO 4" slot=gpo4.map.max desc="Manifold pressure no more than this."
                        DB  0ffh
;@ GIO4CoolantMin type=u8 formula=honda_temp_c category="GIO 4" slot=gpo4.ect.min desc="Coolant at least this warm (the coldest setting: any)."
                        DB  0ffh
;@ GIO4CoolantMax type=u8 formula=honda_temp_c category="GIO 4" slot=gpo4.ect.max desc="Coolant no warmer than this (the hottest setting: any)."
                        DB  000h
;@ GIO4IntakeAirMin type=u8 formula=honda_temp_c category="GIO 4" slot=gpo4.iat.min desc="Intake air at least this warm (the coldest setting: any)."
                        DB  0ffh
;@ GIO4SpeedMin type=u8 formula=speed_kmh_byte category="GIO 4" slot=gpo4.speed.min desc="Road speed at least this."
                        DB  000h
;@ GIO4SpeedMax type=u8 formula=speed_kmh_byte category="GIO 4" slot=gpo4.speed.max desc="Road speed no more than this."
                        DB  0ffh
;@ GIO4GearMin type=u8 formula=raw category="GIO 4" slot=gpo4.gear.min desc="Gear at least this (needs gear detection; 0 = neutral or not known)."
                        DB  000h
;@ GIO4GearMax type=u8 formula=raw category="GIO 4" slot=gpo4.gear.max desc="Gear no higher than this (needs gear detection)."
                        DB  0ffh
;@ GIO4BatteryMin type=u8 formula=battery_v category="GIO 4" slot=gpo4.batt.min desc="Battery at least this many volts."
                        DB  000h
;@ GIO4OnDelay type=u8 formula="x * 32.8" inverse="x / 32.8" unit=ms decimals=0 category="GIO 4" slot=gpo4.delay.on desc="The conditions must hold this long before it switches on (flash mode: the time on and off)."
                        DB  000h
;@ GIO4OffDelay type=u8 formula="x * 32.8" inverse="x / 32.8" unit=ms decimals=0 category="GIO 4" slot=gpo4.delay.off desc="And stop holding this long before it switches off."
                        DB  000h
;@ GIO4Flash type=u8 flag=1 on=1 off=0 category="GIO 4" slot=gpo4.flash desc="Flash the output (on and off, each for the on delay) while the conditions hold: a warning light."
                        DB  000h
endif

if XP == XP_CODE
gio4_tick:
                PUSHS   LRB
                MOV     LRB, #SVC_BANKT
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                MOV     X1, #gio4_block
                MOV     X2, #gio4_timer
                LB      A, #080h                ; its bit in MOD_OUTSTATE
                CAL     mod_gio
                J       mod_tick_exit
endif

endif
