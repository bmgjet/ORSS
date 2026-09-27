; ==================================================================================================
; warnlamp.asm - a warning lamp for hot coolant or a low battery
;> feature: FEAT_WARNLAMP
;> name: Warning lamp (coolant / battery)
;> category: Outputs
;> pages: warnlamp
;> conflicts: FEAT_SHIFTLIGHT
;> ram: 1F1h bit 2 (its state)
;> about: Lights a lamp - the check-engine lamp unless another output is chosen - while the coolant is
;>        hotter than a set temperature, or the battery voltage is low with the engine running (a failed
;>        alternator). The skeleton has no trouble codes, so this is the one warning left on the dash.
;>        Off until enabled.
; ==================================================================================================
ifdef FEAT_WARNLAMP

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
                CMPB    A, #SLOT_WARNLAMP
                JNE     warnlamp_tick_skip
                CAL     warnlamp_tick
warnlamp_tick_skip:
endif

if XP == XP_CAL
;@ WarnLampEnable type=u8 flag=1 on=1 off=0 category="Warning lamp" slot=warnlamp.enable desc="Warning lamp on."
warnlamp_enable:        DB  000h
;@ WarnLampECT type=u8 formula=honda_temp_c category="Warning lamp" slot=warnlamp.ect desc="Light it above this coolant temperature."
warnlamp_ect:           DB  012h                 ; 107 C
;@ WarnLampBattery type=u8 formula=battery_v category="Warning lamp" slot=warnlamp.batt desc="Light it below this battery voltage (engine running)."
warnlamp_batt:          DB  07bh                 ; about 11.8 V
;@ WarnLampOutput type=u8 formula=raw category="Warning lamp" slot=warnlamp.output desc="The output: 0 none, 1 P0.0 (A/C clutch), 2 P0.1 (EVAP purge), 3 P0.4 (A/T lock-up), 4 P1.2 (O2 heater), 5 P1.4 (check-engine lamp), 6 P1.5 (ECU LED)."
warnlamp_output:        DB  005h
endif

if XP == XP_CODE
warnlamp_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, warnlamp_enable
                CMPB    A, #000h
                RC
                JEQ     warnlamp_set
                LCB     A, warnlamp_ect
                CMPB    0c1h, A                ; coolant byte - threshold borrows (C) once hotter
                JLT     warnlamp_set
                L       A, #00ea6h             ; engine running (above 500 rpm)?
                CMP     0ach, A
                JLT     warnlamp_running
                RC
                SJ      warnlamp_set
warnlamp_running:
                CLRB    A
                LCB     A, warnlamp_batt
                CMPB    0c3h, A                ; battery byte - threshold borrows (C) while below it
warnlamp_set:   CLRB    A
                LCB     A, warnlamp_output
                CAL     mod_output
                J       mod_tick_exit
endif

endif
