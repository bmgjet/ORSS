; ==================================================================================================
; burnout.asm - burnout rpm limit (HTS "Burnout control" page)
;> feature: FEAT_BURNOUT
;> name: Burnout control
;> category: Limits
;> pages: burnout
;> ram: 1F2h-1F5h (shared cut requests)
;> about: A second standing rpm limit on its own input, for a burnout or a water-box warm-up: while the
;>        input is on and the car is below a road speed, the revs are held at the burnout rpm. Separate
;>        from launch control, so both can be set up on different switches. Off until enabled.
; ==================================================================================================
ifdef FEAT_BURNOUT

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_BURNOUT
                JNE     burnout_tick_skip
                CAL     burnout_tick
burnout_tick_skip:
endif

if XP == XP_CAL
;@ BurnoutEnable type=u8 flag=1 on=1 off=0 category="Burnout control" slot=burnout.enable desc="Burnout control on."
burnout_block:          DB  000h
;@ BurnoutCut type=u8 category="Burnout control" slot=burnout.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
burnout_cut:            DB  000h
;@ BurnoutRPM type=u16 formula=rpm_period_word category="Burnout control" slot=burnout.rpm desc="Hold the revs here."
burnout_set:            DW  001f4h               ; 3750 rpm
;@ BurnoutRPMReset type=u16 formula=rpm_period_word category="Burnout control" slot=burnout.rpm.reset desc="Back in below this rpm."
burnout_reset:          DW  00200h               ; 3660 rpm
;@ BurnoutInput type=u8 category="Burnout control" slot=burnout.input desc="The input that arms it: 01h power steering, 02h service connector, 04h start, 08h VTEC pressure, 10h A/C, 20h brake, 40h park/neutral, 80h always."
burnout_input:          DB  010h
;@ BurnoutInputInvert type=u8 flag=1 on=1 off=0 category="Burnout control" slot=burnout.input.invert desc="Armed while the input is off instead."
burnout_invert:         DB  000h
;@ BurnoutMaxSpeed type=u8 formula=speed_kmh_byte category="Burnout control" slot=burnout.speed desc="Only below this road speed."
burnout_speed:          DB  014h
endif

if XP == XP_CODE
burnout_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                MOV     X1, #burnout_input
                CAL     mod_switch
                RC
                JEQ     burnout_decide
                CLRB    A
                LCB     A, burnout_speed
                CMPB    0b4h, A                ; speed - limit borrows (C set) while below it
burnout_decide: MOV     X1, #burnout_block
                L       A, #MB_BURNOUT
                CAL     mod_limit
                J       mod_tick_exit
endif

endif
