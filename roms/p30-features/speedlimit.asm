; ==================================================================================================
; speedlimit.asm - road speed limiter, always or on a switch (HTS120 "Speed limiter by switch")
;> feature: FEAT_SPEEDLIMIT
;> name: Speed limiter (always or by switch)
;> category: Limits
;> pages: revlimit
;> ram: 1F2h-1F5h (shared cut requests)
;> about: Cuts fuel at a road speed - all the time (a valet or a learner setting), or only while a
;>        switch input is on (a pit-lane limiter on a button). Lets it back in 2 km/h under the limit.
;>        Off until enabled.
; ==================================================================================================
ifdef FEAT_SPEEDLIMIT

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_SPEEDLIMIT
                JNE     speedlim_tick_skip
                CAL     speedlim_tick
speedlim_tick_skip:
endif

if XP == XP_CAL
;@ SwLimitEnable type=u8 flag=1 on=1 off=0 category="Speed limiter" slot=revlimit.swlimit.enable desc="Speed limiter on."
speedlim_block:         DB  000h
;@ SwLimitCut type=u8 category="Speed limiter" slot=revlimit.swlimit.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
speedlim_cut:           DB  000h
;@ SwLimitSpeed type=u8 formula=speed_kmh_byte category="Speed limiter" slot=revlimit.swlimit.speed desc="Cut at this road speed. 255 = off."
speedlim_speed:         DB  060h                 ; 96 km/h
;@ SwLimitInput type=u8 category="Speed limiter" slot=revlimit.swlimit.input desc="While this input is on: 01h power steering, 02h service connector, 04h start, 08h VTEC pressure, 10h A/C, 20h brake, 40h park/neutral, 80h always."
speedlim_input:         DB  080h
;@ SwLimitInvert type=u8 flag=1 on=1 off=0 category="Speed limiter" slot=revlimit.swlimit.invert desc="Limit while the input is off instead."
speedlim_invert:        DB  000h
endif

if XP == XP_CODE
speedlim_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, speedlim_block
                CMPB    A, #000h
                JEQ     speedlim_off
                MOV     X1, #speedlim_input
                CAL     mod_switch
                JEQ     speedlim_off
                CLRB    A
                LCB     A, speedlim_speed
                CMPB    A, #0ffh
                JEQ     speedlim_off
                STB     A, r4
                L       A, off(MOD_FUELWANT)   ; limiting now?
                OR      A, off(MOD_SPARKWANT)
                AND     A, #MB_SPEEDLIMIT
                JNE     speedlim_cutting
                CLRB    A
                LB      A, r4
                CMPB    0b4h, A                ; speed - limit: no borrow at or above it
                JLT     speedlim_off
                SJ      speedlim_on
speedlim_cutting:
                CLRB    A
                LB      A, r4
                SUBB    A, #002h
                CMPB    0b4h, A
                JLT     speedlim_off
speedlim_on:    MOV     X1, #speedlim_block
                L       A, #MB_SPEEDLIMIT
                SC
                CAL     mod_cut
                J       mod_tick_exit
speedlim_off:   MOV     X1, #speedlim_block
                L       A, #MB_SPEEDLIMIT
                RC
                CAL     mod_cut
                J       mod_tick_exit
endif

endif
