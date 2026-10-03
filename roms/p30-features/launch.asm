; ==================================================================================================
; launch.asm - launch control / two-step (HTS "Launch control / 2-step" page)
;> feature: FEAT_LAUNCH
;> name: Launch control (two-step)
;> category: Limits
;> pages: launch
;> ram: 1F2h-1F5h (shared cut requests)
;> about: Holds the revs at a launch rpm while the car is standing (below a road speed) and the launch
;>        input is on - the clutch switch, or any of the switch inputs - so it leaves the line on boost and
;>        in the torque. Past the road speed, or with the input off, the normal limiter is back. Ignition
;>        cut (the usual two-step), fuel cut, or both. Off until enabled.
; ==================================================================================================
ifdef FEAT_LAUNCH

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_LAUNCH
                JNE     launch_tick_skip
                CAL     launch_tick
launch_tick_skip:
endif

if XP == XP_CAL
;@ LaunchEnable type=u8 flag=1 on=1 off=0 category="Launch control" slot=launch.enable desc="Launch control on."
launch_block:           DB  000h
;@ LaunchCut type=u8 category="Launch control" slot=launch.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
launch_cut:             DB  001h
;@ LaunchRPM type=u16 formula=rpm_period_word category="Launch control" slot=launch.rpm desc="Hold the revs here."
launch_set:             DW  00177h               ; 5000 rpm
;@ LaunchRPMReset type=u16 formula=rpm_period_word category="Launch control" slot=launch.rpm.reset desc="Back in below this rpm."
launch_reset:           DW  00181h               ; 4870 rpm
;@ LaunchInput type=u8 category="Launch control" slot=launch.input desc="The input that arms it: 01h power steering, 02h service connector, 04h start, 08h VTEC pressure, 10h A/C, 20h brake, 40h park/neutral, 80h always."
launch_input:           DB  020h
;@ LaunchInputInvert type=u8 flag=1 on=1 off=0 category="Launch control" slot=launch.input.invert desc="Armed while the input is off instead."
launch_invert:          DB  000h
;@ LaunchMaxSpeed type=u8 formula=speed_kmh_byte category="Launch control" slot=launch.speed desc="Only below this road speed."
launch_speed:           DB  005h
endif

if XP == XP_CODE
launch_tick:    PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, launch_block        ; off: straight to letting go (the switch is not read)
                RC
                CMPB    A, #000h
                JEQ     launch_decide
                MOV     X1, #launch_input
                CAL     mod_switch             ; armed?
                RC
                JEQ     launch_decide          ; input off: no launch (C clear)
                CLRB    A                      ; and standing: road speed below the limit
                LCB     A, launch_speed
                CMPB    0b4h, A                ; speed - limit borrows (C set) while below it
launch_decide:  MOV     X1, #launch_block
                L       A, #MB_LAUNCH
                CAL     mod_limit
                J       mod_tick_exit
endif

endif
