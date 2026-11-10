; ==================================================================================================
; burnout.asm - burnout rpm limit (HTS "Burnout control" page)
;> feature: FEAT_BURNOUT
;> name: Burnout control
;> category: Limits
;> platforms: P13
;> pages: burnout
;> ram: 1C2h-1C5h (shared cut requests), the rev cap: 2 bytes of module RAM shared by every rev limit (lib.asm)
;> about: A second standing rpm limit on its own input, for a burnout or a water-box warm-up: while the
;>        input is on and the car is below a road speed, the revs are held at the burnout rpm. Separate
;>        from launch control, so both can be set up on different switches. Off until enabled.
; ==================================================================================================
ifdef FEAT_BURNOUT

if XP == XP_DEFS
ifndef NEED_REVCAP
define NEED_REVCAP                             ; (its rev limit is a hard limit for the crank interrupt too: lib.asm)
endif
ifndef NEED_MODLIB
define NEED_MODLIB
endif
endif

if XP == XP_TICKSLOT
if SLOT_BURNOUT == TICK_SLOT
                CAL     burnout_tick
endif
endif

if XP == XP_CAL
;@ BurnoutEnable type=u8 flag=1 on=1 off=0 category="Burnout control" slot=burnout.enable desc="A lower rev limit for burnouts: the revs held at the point below while the arming input is on and the car is under the speed set."
burnout_block:          DB  000h
;@ BurnoutCut type=u8 category="Burnout control" slot=burnout.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
burnout_cut:            DB  000h
;@ BurnoutRPM type=u16 formula=rpm_period_word category="Burnout control" slot=burnout.rpm desc="The rpm the engine is held at during a burnout."
burnout_set:            DW  001f4h               ; 3750 rpm
;@ BurnoutRPMReset type=u16 formula=rpm_period_word category="Burnout control" slot=burnout.rpm.reset desc="Fuel / spark come back once the rpm falls under this."
burnout_reset:          DW  00200h               ; 3660 rpm
;@ BurnoutInput type=u8 category="Burnout control" slot=burnout.input desc="The input that arms it: 01h power steering, 02h service connector, 04h start, 08h VTEC pressure, 10h A/C, 20h brake, 40h park/neutral, 80h always. On the P13 the brake (20h) is not traced yet and reads off, and park/neutral (40h) is an automatic's (a manual reads off)."
burnout_input:          DB  010h
;@ BurnoutInputInvert type=u8 flag=1 on=1 off=0 category="Burnout control" slot=burnout.input.invert desc="Armed while the input is off instead."
burnout_invert:         DB  000h
;@ BurnoutMaxSpeed type=u8 formula=speed_kmh_byte category="Burnout control" slot=burnout.speed desc="It only works below this road speed; above it the normal rev limit applies."
burnout_speed:          DB  014h
endif

if XP == XP_CODE
burnout_tick:
                PUSHS   LRB
                MOV     LRB, #SVC_BANKT
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
                CMPB    ENG_VSS, A                ; speed - limit borrows (C set) while below it
burnout_decide: MOV     X1, #burnout_block
                L       A, #MB_BURNOUT
                CAL     mod_limit
                J       mod_tick_exit
endif

endif
