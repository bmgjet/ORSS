; ==================================================================================================
; cfgoverride.asm - the ECU's variant flags set in software (the P13)
;> feature: FEAT_CFGOVERRIDE
;> name: Board options override
;> category: Options
;> platforms: P13
;> pages: boardopt
;> ram: none
;> about: The ECU decides its equipment variant (automatic, baro sensor, electrical load detector, knock
;>        unit, VTEC checks...) from its ID at power-up. This sets any of those flags in software instead:
;>        force one on or off whatever the ID says, for a swapped engine or another board. Nothing is
;>        forced until a box is ticked.
; ==================================================================================================
ifdef FEAT_CFGOVERRIDE

if XP == XP_DEFS
ifndef NEED_CFGOVERRIDE
define NEED_CFGOVERRIDE
endif

endif

if XP == XP_CAL
;@ P13AutomaticForceOn type=bit0 category="Board options" slot=boardopt.p13automatic.on desc="Automatic transmission: forced on (flag 220h bit 0), whatever the ECU's ID decides. The automatic: the park/neutral switch, lock-up and its port C output, its tables and checks. (Built without FEAT_STOCK_AT the skeleton clears it; forcing it on brings that stock code back into use.)"
;@ P13EldForceOn type=bit2 category="Board options" slot=boardopt.p13eld.on desc="Electrical load detector (code 20): forced on (flag 220h bit 2), whatever the ECU's ID decides. Reads the electrical load detector (code 20) for the idle, purge and timing corrections; without it the ECU uses a fixed load reading (25h)."
;@ P13BaroForceOn type=bit3 category="Board options" slot=boardopt.p13baro.on desc="Barometric pressure sensor (code 13): forced on (flag 220h bit 3), whatever the ECU's ID decides. Reads the barometric pressure sensor (code 13); without it baro is the fixed value F9h."
;@ P13AtchecksForceOn type=bit4 category="Board options" slot=boardopt.p13atchecks.on desc="A/T output checks (codes 25, 26): forced on (flag 220h bit 4), whatever the ECU's ID decides. Checks the automatic's outputs (codes 25, 26)."
;@ P13IdleknockForceOn type=bit6 category="Board options" slot=boardopt.p13idleknock.on desc="Idle and knock variant (220h bit 6): forced on (flag 220h bit 6), whatever the ECU's ID decides. The idle valve's step size and step count, and a knock retard limit check that only runs with it."
cfg13_on_220:      DB  000h
;@ P13VtecchecksForceOn type=bit0 category="Board options" slot=boardopt.p13vtecchecks.on desc="VTEC solenoid and pressure checks (codes 21, 22): forced on (flag 221h bit 0), whatever the ECU's ID decides. Checks the VTEC solenoid (code 21) and the VTEC pressure switch result (code 22)."
;@ P13KnockForceOn type=bit1 category="Board options" slot=boardopt.p13knock.on desc="Knock control unit (codes 23, 24): forced on (flag 221h bit 1), whatever the ECU's ID decides. Uses the knock control unit: its retard (2B4h) and its checks (codes 23, 24). (Built without FEAT_STOCK_KNOCK the retard is held at none whatever this says.)"
;@ P13Eld2ForceOn type=bit2 category="Board options" slot=boardopt.p13eld2.on desc="Load input check without the ELD (221h bit 2): forced on (flag 221h bit 2), whatever the ECU's ID decides. Without the electrical load detector, checks the load input (3D8h) against 9Ah instead (flag 218h bit 3)."
cfg13_on_221:      DB  000h
;@ P13Flag21f0ForceOn type=bit0 category="Board options" slot=boardopt.p13flag21f0.on desc="Speed limit and fuel check variant (21Fh bit 0): forced on (flag 21Fh bit 0), whatever the ECU's ID decides. The stock speed limiter's path, the stored fuel values checked against flag 0A0h bit 0, and that flag set by trouble code 30."
;@ P13InjcheckForceOn type=bit2 category="Board options" slot=boardopt.p13injcheck.on desc="Injector check (code 16) (21Fh bit 2): forced on (flag 21Fh bit 2), whatever the ECU's ID decides. Checks the injector drive (code 16)."
;@ P13Flag21f3ForceOn type=bit3 category="Board options" slot=boardopt.p13flag21f3.on desc="Injector check and knock tables variant (21Fh bit 3): forced on (flag 21Fh bit 3), whatever the ECU's ID decides. Checks the injector drive (code 16), picks the other knock level tables, and moves a coolant point of the closed-loop gate (35h to 70h)."
;@ P13Openloop2ForceOn type=bit5 category="Board options" slot=boardopt.p13openloop2.on desc="Second open-loop load table (21Fh bit 5): forced on (flag 21Fh bit 5), whatever the ECU's ID decides. Uses the second open-loop load table (all FFh in this image: never) as the load the fuel goes rich above, and flag 11Ch bit 5."
cfg13_on_21f:      DB  000h
;@ P13AutomaticForceOff type=bit0 category="Board options" slot=boardopt.p13automatic.off desc="Automatic transmission: forced off (flag 220h bit 0), whatever the ECU's ID decides. The automatic: the park/neutral switch, lock-up and its port C output, its tables and checks. (Built without FEAT_STOCK_AT the skeleton clears it; forcing it on brings that stock code back into use.)"
;@ P13EldForceOff type=bit2 category="Board options" slot=boardopt.p13eld.off desc="Electrical load detector (code 20): forced off (flag 220h bit 2), whatever the ECU's ID decides. Reads the electrical load detector (code 20) for the idle, purge and timing corrections; without it the ECU uses a fixed load reading (25h)."
;@ P13BaroForceOff type=bit3 category="Board options" slot=boardopt.p13baro.off desc="Barometric pressure sensor (code 13): forced off (flag 220h bit 3), whatever the ECU's ID decides. Reads the barometric pressure sensor (code 13); without it baro is the fixed value F9h."
;@ P13AtchecksForceOff type=bit4 category="Board options" slot=boardopt.p13atchecks.off desc="A/T output checks (codes 25, 26): forced off (flag 220h bit 4), whatever the ECU's ID decides. Checks the automatic's outputs (codes 25, 26)."
;@ P13IdleknockForceOff type=bit6 category="Board options" slot=boardopt.p13idleknock.off desc="Idle and knock variant (220h bit 6): forced off (flag 220h bit 6), whatever the ECU's ID decides. The idle valve's step size and step count, and a knock retard limit check that only runs with it."
cfg13_off_220:      DB  000h
;@ P13VtecchecksForceOff type=bit0 category="Board options" slot=boardopt.p13vtecchecks.off desc="VTEC solenoid and pressure checks (codes 21, 22): forced off (flag 221h bit 0), whatever the ECU's ID decides. Checks the VTEC solenoid (code 21) and the VTEC pressure switch result (code 22)."
;@ P13KnockForceOff type=bit1 category="Board options" slot=boardopt.p13knock.off desc="Knock control unit (codes 23, 24): forced off (flag 221h bit 1), whatever the ECU's ID decides. Uses the knock control unit: its retard (2B4h) and its checks (codes 23, 24). (Built without FEAT_STOCK_KNOCK the retard is held at none whatever this says.)"
;@ P13Eld2ForceOff type=bit2 category="Board options" slot=boardopt.p13eld2.off desc="Load input check without the ELD (221h bit 2): forced off (flag 221h bit 2), whatever the ECU's ID decides. Without the electrical load detector, checks the load input (3D8h) against 9Ah instead (flag 218h bit 3)."
cfg13_off_221:      DB  000h
;@ P13Flag21f0ForceOff type=bit0 category="Board options" slot=boardopt.p13flag21f0.off desc="Speed limit and fuel check variant (21Fh bit 0): forced off (flag 21Fh bit 0), whatever the ECU's ID decides. The stock speed limiter's path, the stored fuel values checked against flag 0A0h bit 0, and that flag set by trouble code 30."
;@ P13InjcheckForceOff type=bit2 category="Board options" slot=boardopt.p13injcheck.off desc="Injector check (code 16) (21Fh bit 2): forced off (flag 21Fh bit 2), whatever the ECU's ID decides. Checks the injector drive (code 16)."
;@ P13Flag21f3ForceOff type=bit3 category="Board options" slot=boardopt.p13flag21f3.off desc="Injector check and knock tables variant (21Fh bit 3): forced off (flag 21Fh bit 3), whatever the ECU's ID decides. Checks the injector drive (code 16), picks the other knock level tables, and moves a coolant point of the closed-loop gate (35h to 70h)."
;@ P13Openloop2ForceOff type=bit5 category="Board options" slot=boardopt.p13openloop2.off desc="Second open-loop load table (21Fh bit 5): forced off (flag 21Fh bit 5), whatever the ECU's ID decides. Uses the second open-loop load table (all FFh in this image: never) as the load the fuel goes rich above, and flag 11Ch bit 5."
cfg13_off_21f:      DB  000h
endif

if XP == XP_CODE
; The skeleton calls it each main-loop pass, once the stock code has set the variant flags from the ID (220h, 21Fh,
; 221h, each with its copy at 120h, 11Fh, 121h): forced-off bits cleared, forced-on bits set, in both. Interrupts
; off meanwhile, as the stock code writes them; bank page 2, USP 180h. A is free.
mod_cfgoverride:
                RB      PSWH.0
                CLRB    A
                LCB     A, cfg13_off_220
                XORB    A, #0ffh
                ANDB    A, off(00220h)
                STB     A, off(00220h)
                LCB     A, cfg13_on_220
                ORB     A, off(00220h)
                STB     A, off(00220h)
                STB     A, (00120h-00180h)[USP]
                CLRB    A
                LCB     A, cfg13_off_21f
                XORB    A, #0ffh
                ANDB    A, off(0021fh)
                STB     A, off(0021fh)
                LCB     A, cfg13_on_21f
                ORB     A, off(0021fh)
                STB     A, off(0021fh)
                STB     A, (0011fh-00180h)[USP]
                CLRB    A
                LCB     A, cfg13_off_221
                XORB    A, #0ffh
                ANDB    A, off(00221h)
                STB     A, off(00221h)
                LCB     A, cfg13_on_221
                ORB     A, off(00221h)
                STB     A, off(00221h)
                STB     A, (00121h-00180h)[USP]
                SB      PSWH.0
                RT
endif

endif
