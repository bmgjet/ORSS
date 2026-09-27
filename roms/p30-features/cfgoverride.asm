; ==================================================================================================
; cfgoverride.asm - board options set in software (the configuration resistors overridden)
;> feature: FEAT_CFGOVERRIDE
;> name: Board options override
;> category: Options
;> pages: boardopt
;> ram: none
;> about: The ECU reads its equipment options (automatic, knock sensor, O2 closed loop, VTEC pressure
;>        switch...) from the option bytes or, when those say so, from resistors on the board. This sets
;>        any of them in software instead: force a flag on or off whatever the board says, for a swapped
;>        engine or a board with the wrong resistors fitted. Nothing is forced until a box is ticked.
; ==================================================================================================
ifdef FEAT_CFGOVERRIDE

if XP == XP_DEFS
ifndef NEED_CFGOVERRIDE
define NEED_CFGOVERRIDE
endif

endif

if XP == XP_CAL
;@ AltKnockShiftTablesForceOn type=bit0 category="Board options" slot=boardopt.altknockshift.on desc="Second knock levels and shift points: forced on (flag 216h bit 0), whatever the option bytes or the board's resistors say. Picks the second half of the knock level table and the other A/T shift-point tables; also part of the model code the diagnostic link reports."
;@ Unused216Bit1ForceOn type=bit1 category="Board options" slot=boardopt.unused2161.on desc="Unused flag: forced on (flag 216h bit 1), whatever the option bytes or the board's resistors say. Set from its option byte at power-up; nothing in the code reads it."
;@ LowSpeedRetardCapForceOn type=bit2 category="Board options" slot=boardopt.lowspeedretardcap.on desc="Knock retard cap below 45 km/h: forced on (flag 216h bit 2), whatever the option bytes or the board's resistors say. Caps the knock retard (at 7Ah) below 45 km/h, has the stored fuel values checked against the fault flag, handles code 13 (0A0h.0) and is part of the model code."
;@ AutomaticTransmissionForceOn type=bit3 category="Board options" slot=boardopt.automatictransmission.on desc="Automatic transmission: forced on (flag 216h bit 3), whatever the option bytes or the board's resistors say. The A/T shift and lock-up control, the A/T idle, decel-cut, tip-in and knock tables, and the A/T checks (codes 17, 19, 30)."
;@ VtecChecksForceOn type=bit4 category="Board options" slot=boardopt.vtecchecks.on desc="VTEC solenoid and pressure checks (codes 21, 22): forced on (flag 216h bit 4), whatever the option bytes or the board's resistors say. Checks the VTEC solenoid feedback (code 21) and the VTEC pressure switch result."
;@ KnockSensorForceOn type=bit5 category="Board options" slot=boardopt.knocksensor.on desc="Knock sensor (codes 23, 26): forced on (flag 216h bit 5), whatever the option bytes or the board's resistors say. Reads the knock sensor, sets codes 23 and 26, and has the scheduler run the knock task."
;@ AlternatorControlCheckForceOn type=bit6 category="Board options" slot=boardopt.altcontrolcheck.on desc="Alternator control check: forced on (flag 216h bit 6), whatever the option bytes or the board's resistors say. With flag 219h bit 1: the alternator control (ALTC) check; also a condition of the closed-loop O2 gate."
;@ EgrSystemForceOn type=bit7 category="Board options" slot=boardopt.egr.on desc="EGR system: forced on (flag 216h bit 7), whatever the option bytes or the board's resistors say. The EGR valve control and its maps, and which housekeeping task runs."
cfg_on_216:          DB  000h
;@ KnockWindowAlwaysOpenForceOn type=bit3 category="Board options" slot=boardopt.knockwindow.on desc="Knock window open at any rpm: forced on (flag 217h bit 3), whatever the option bytes or the board's resistors say. The knock window is open whatever the rpm (otherwise only below the 6000h period point)."
;@ IdleValveType2ForceOn type=bit6 category="Board options" slot=boardopt.idlevalvealt.on desc="Second idle valve type: forced on (flag 217h bit 6), whatever the option bytes or the board's resistors say. The idle valve PID gains and tables for the other valve type, and the intake air check (code 10) skipped."
cfg_on_217:          DB  000h
;@ SecondSensorInputsForceOn type=bit1 category="Board options" slot=boardopt.secondinputs.on desc="Knock and O2 on the second inputs: forced on (flag 219h bit 1), whatever the option bytes or the board's resistors say. Knock read from 3CCh instead of 0C7h, the O2 closed-loop gate on 39Bh, codes 10 and 25, and (with 216h bit 6) the alternator control check."
;@ ClosedLoopOffForceOn type=bit4 category="Board options" slot=boardopt.closedloopoff.on desc="Closed loop off: forced on (flag 219h bit 4), whatever the option bytes or the board's resistors say. The closed-loop O2 trim is held off."
cfg_on_219:          DB  000h
;@ IdleStrategy2ForceOn type=bit1 category="Board options" slot=boardopt.idlealt.on desc="Second idle strategy: forced on (flag 227h bit 1), whatever the option bytes or the board's resistors say. The other idle speed and state logic (2C2h-2C8h) and the idle coolant correction."
;@ SpeedChecksOffForceOn type=bit2 category="Board options" slot=boardopt.speedchecksoff.on desc="Road speed checks off (code 17): forced on (flag 227h bit 2), whatever the option bytes or the board's resistors say. The A/T task and the road speed / A/T input checks (code 17) are skipped."
;@ GearDetectionForceOn type=bit3 category="Board options" slot=boardopt.geardetect.on desc="Gear detection: forced on (flag 227h bit 3), whatever the option bytes or the board's resistors say. Gear detection from rpm and road speed, the A/T lock-up state and the alternator control override."
;@ BaroSensorForceOn type=bit4 category="Board options" slot=boardopt.barosensor.on desc="Barometric pressure sensor (code 13): forced on (flag 227h bit 4), whatever the option bytes or the board's resistors say. Reads the baro sensor; without it baro is the fixed value F9h."
;@ IgnitionMapSelectForceOn type=bit5 category="Board options" slot=boardopt.ignmapselect.on desc="Ignition map select: forced on (flag 227h bit 5), whatever the option bytes or the board's resistors say. Picks the ignition map of the 2-D lookup, and the knock threshold bank."
;@ VtecPressureSwitchForceOn type=bit6 category="Board options" slot=boardopt.vtecpressureswitch.on desc="VTEC pressure switch (code 22): forced on (flag 227h bit 6), whatever the option bytes or the board's resistors say. Reads the VTEC oil-pressure switch (code 22), and gates the knock (code 23) check and the road-speed input."
;@ KnockRetardByIntakeAirForceOn type=bit7 category="Board options" slot=boardopt.knockretardiat.on desc="Knock retard limited by intake air: forced on (flag 227h bit 7), whatever the option bytes or the board's resistors say. The knock retard is limited by the intake air temperature (none above B5h)."
cfg_on_227:          DB  000h
;@ AltKnockShiftTablesForceOff type=bit0 category="Board options" slot=boardopt.altknockshift.off desc="Second knock levels and shift points: forced off (flag 216h bit 0), whatever the option bytes or the board's resistors say. Picks the second half of the knock level table and the other A/T shift-point tables; also part of the model code the diagnostic link reports."
;@ Unused216Bit1ForceOff type=bit1 category="Board options" slot=boardopt.unused2161.off desc="Unused flag: forced off (flag 216h bit 1), whatever the option bytes or the board's resistors say. Set from its option byte at power-up; nothing in the code reads it."
;@ LowSpeedRetardCapForceOff type=bit2 category="Board options" slot=boardopt.lowspeedretardcap.off desc="Knock retard cap below 45 km/h: forced off (flag 216h bit 2), whatever the option bytes or the board's resistors say. Caps the knock retard (at 7Ah) below 45 km/h, has the stored fuel values checked against the fault flag, handles code 13 (0A0h.0) and is part of the model code."
;@ AutomaticTransmissionForceOff type=bit3 category="Board options" slot=boardopt.automatictransmission.off desc="Automatic transmission: forced off (flag 216h bit 3), whatever the option bytes or the board's resistors say. The A/T shift and lock-up control, the A/T idle, decel-cut, tip-in and knock tables, and the A/T checks (codes 17, 19, 30)."
;@ VtecChecksForceOff type=bit4 category="Board options" slot=boardopt.vtecchecks.off desc="VTEC solenoid and pressure checks (codes 21, 22): forced off (flag 216h bit 4), whatever the option bytes or the board's resistors say. Checks the VTEC solenoid feedback (code 21) and the VTEC pressure switch result."
;@ KnockSensorForceOff type=bit5 category="Board options" slot=boardopt.knocksensor.off desc="Knock sensor (codes 23, 26): forced off (flag 216h bit 5), whatever the option bytes or the board's resistors say. Reads the knock sensor, sets codes 23 and 26, and has the scheduler run the knock task."
;@ AlternatorControlCheckForceOff type=bit6 category="Board options" slot=boardopt.altcontrolcheck.off desc="Alternator control check: forced off (flag 216h bit 6), whatever the option bytes or the board's resistors say. With flag 219h bit 1: the alternator control (ALTC) check; also a condition of the closed-loop O2 gate."
;@ EgrSystemForceOff type=bit7 category="Board options" slot=boardopt.egr.off desc="EGR system: forced off (flag 216h bit 7), whatever the option bytes or the board's resistors say. The EGR valve control and its maps, and which housekeeping task runs."
cfg_off_216:          DB  000h
;@ KnockWindowAlwaysOpenForceOff type=bit3 category="Board options" slot=boardopt.knockwindow.off desc="Knock window open at any rpm: forced off (flag 217h bit 3), whatever the option bytes or the board's resistors say. The knock window is open whatever the rpm (otherwise only below the 6000h period point)."
;@ IdleValveType2ForceOff type=bit6 category="Board options" slot=boardopt.idlevalvealt.off desc="Second idle valve type: forced off (flag 217h bit 6), whatever the option bytes or the board's resistors say. The idle valve PID gains and tables for the other valve type, and the intake air check (code 10) skipped."
cfg_off_217:          DB  000h
;@ SecondSensorInputsForceOff type=bit1 category="Board options" slot=boardopt.secondinputs.off desc="Knock and O2 on the second inputs: forced off (flag 219h bit 1), whatever the option bytes or the board's resistors say. Knock read from 3CCh instead of 0C7h, the O2 closed-loop gate on 39Bh, codes 10 and 25, and (with 216h bit 6) the alternator control check."
;@ ClosedLoopOffForceOff type=bit4 category="Board options" slot=boardopt.closedloopoff.off desc="Closed loop off: forced off (flag 219h bit 4), whatever the option bytes or the board's resistors say. The closed-loop O2 trim is held off."
cfg_off_219:          DB  000h
;@ IdleStrategy2ForceOff type=bit1 category="Board options" slot=boardopt.idlealt.off desc="Second idle strategy: forced off (flag 227h bit 1), whatever the option bytes or the board's resistors say. The other idle speed and state logic (2C2h-2C8h) and the idle coolant correction."
;@ SpeedChecksOffForceOff type=bit2 category="Board options" slot=boardopt.speedchecksoff.off desc="Road speed checks off (code 17): forced off (flag 227h bit 2), whatever the option bytes or the board's resistors say. The A/T task and the road speed / A/T input checks (code 17) are skipped."
;@ GearDetectionForceOff type=bit3 category="Board options" slot=boardopt.geardetect.off desc="Gear detection: forced off (flag 227h bit 3), whatever the option bytes or the board's resistors say. Gear detection from rpm and road speed, the A/T lock-up state and the alternator control override."
;@ BaroSensorForceOff type=bit4 category="Board options" slot=boardopt.barosensor.off desc="Barometric pressure sensor (code 13): forced off (flag 227h bit 4), whatever the option bytes or the board's resistors say. Reads the baro sensor; without it baro is the fixed value F9h."
;@ IgnitionMapSelectForceOff type=bit5 category="Board options" slot=boardopt.ignmapselect.off desc="Ignition map select: forced off (flag 227h bit 5), whatever the option bytes or the board's resistors say. Picks the ignition map of the 2-D lookup, and the knock threshold bank."
;@ VtecPressureSwitchForceOff type=bit6 category="Board options" slot=boardopt.vtecpressureswitch.off desc="VTEC pressure switch (code 22): forced off (flag 227h bit 6), whatever the option bytes or the board's resistors say. Reads the VTEC oil-pressure switch (code 22), and gates the knock (code 23) check and the road-speed input."
;@ KnockRetardByIntakeAirForceOff type=bit7 category="Board options" slot=boardopt.knockretardiat.off desc="Knock retard limited by intake air: forced off (flag 227h bit 7), whatever the option bytes or the board's resistors say. The knock retard is limited by the intake air temperature (none above B5h)."
cfg_off_227:          DB  000h
endif

if XP == XP_CODE
; The skeleton calls it each time it has read the option bytes / board resistors into the feature flags (at
; power-up and every main-loop pass, bank page 2): forced-off bits cleared, forced-on bits set.
mod_cfgoverride:
                CLRB    A
                LCB     A, cfg_off_216
                XORB    A, #0ffh
                ANDB    A, off(00216h)
                STB     A, off(00216h)
                LCB     A, cfg_on_216
                ORB     A, off(00216h)
                STB     A, off(00216h)
                CLRB    A
                LCB     A, cfg_off_217
                XORB    A, #0ffh
                ANDB    A, off(00217h)
                STB     A, off(00217h)
                LCB     A, cfg_on_217
                ORB     A, off(00217h)
                STB     A, off(00217h)
                CLRB    A
                LCB     A, cfg_off_219
                XORB    A, #0ffh
                ANDB    A, off(00219h)
                STB     A, off(00219h)
                LCB     A, cfg_on_219
                ORB     A, off(00219h)
                STB     A, off(00219h)
                CLRB    A
                LCB     A, cfg_off_227
                XORB    A, #0ffh
                ANDB    A, off(00227h)
                STB     A, off(00227h)
                LCB     A, cfg_on_227
                ORB     A, off(00227h)
                STB     A, off(00227h)
                RT
endif

endif
