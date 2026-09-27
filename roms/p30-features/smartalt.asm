; ==================================================================================================
; smartalt.asm - the alternator off under heavy load
;> feature: FEAT_SMARTALT
;> name: Smart alternator
;> category: Outputs
;> pages: smartalt
;> ram: module RAM (1 byte)
;> about: Turns the alternator's charging down (the alternator control line, P0.5) under heavy load -
;>        wide throttle or high boost above an rpm - for the power it takes, and back to normal once the
;>        load has gone for the hold time or if the battery falls below a minimum. Which level of P0.5
;>        turns charging down depends on the alternator and wiring: check it on the car. Off until
;>        enabled.
; ==================================================================================================
ifdef FEAT_SMARTALT

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif
smartalt_timer      EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (smartalt_timer + 1)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_SMARTALT
                JNE     smartalt_tick_skip
                CAL     smartalt_tick
smartalt_tick_skip:
endif

if XP == XP_CAL
;@ SmartAltEnable type=u8 flag=1 on=1 off=0 category="Smart alternator" slot=smartalt.enable desc="Smart alternator on."
smartalt_enable:        DB  000h
;@ SmartAltThrottle type=u8 formula=tps_pct category="Smart alternator" slot=smartalt.tps desc="Heavy load: throttle at least this..."
smartalt_tps:           DB  0c0h
;@ SmartAltMap type=u8 formula=map_mbar category="Smart alternator" slot=smartalt.map desc="...or manifold pressure at least this."
smartalt_map:           DB  0ffh
;@ SmartAltRpm type=u16 formula=rpm_period_word category="Smart alternator" slot=smartalt.rpm desc="And at or above this rpm."
smartalt_rpm:           DW  00177h
;@ SmartAltBatteryMin type=u8 formula=battery_v category="Smart alternator" slot=smartalt.batt desc="Never below this battery voltage: charging back on."
smartalt_batt:          DB  07dh
;@ SmartAltHold type=u8 formula="x * 32.8" inverse="x / 32.8" unit=ms decimals=0 category="Smart alternator" slot=smartalt.hold desc="Back to normal this long after the load has gone."
smartalt_hold:          DB  00fh
;@ SmartAltLevel type=u8 formula=raw category="Smart alternator" slot=smartalt.level desc="The alternator control level that turns charging down: 7 = P0.5 high, 8 = P0.5 low."
smartalt_out:           DB  007h
endif

if XP == XP_CODE
smartalt_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, smartalt_enable
                CMPB    A, #000h
                JEQ     smartalt_release
                LCB     A, smartalt_batt       ; the battery first
                CMPB    0c3h, A
                JLT     smartalt_release
                LCB     A, smartalt_tps        ; heavy: throttle...
                CMPB    0b9h, A
                JGE     smartalt_rpmchk
                LCB     A, smartalt_map        ; ...or MAP
                CMPB    0a3h, A
                JLT     smartalt_light
smartalt_rpmchk:
                CLR     A
                LC      A, smartalt_rpm
                CMP     0ach, A                ; period past the point's: below the rpm
                JGT     smartalt_light
                MOV     DP, #smartalt_timer    ; heavy: charging down, the hold restarts
                CLRB    A
                LCB     A, smartalt_hold
                STB     A, [DP]
                SB      off(MOD_FLAGS).3       ; (taken)
                SC
                SJ      smartalt_drive
smartalt_light: MOV     DP, #smartalt_timer    ; light: charging back once the hold runs out
                CLRB    A
                LB      A, [DP]
                CMPB    A, #000h
                JEQ     smartalt_release
                SUBB    A, #001h
                STB     A, [DP]
                J       mod_tick_exit
smartalt_release:
                JBS     off(MOD_FLAGS).3, smartalt_giveback
                J       mod_tick_exit          ; not taken: the stock control is left alone
smartalt_giveback:
                RB      off(MOD_FLAGS).3
                RC
smartalt_drive: CLRB    A
                LCB     A, smartalt_out
                CAL     mod_output
                J       mod_tick_exit
endif

endif
