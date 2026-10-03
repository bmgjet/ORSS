; ==================================================================================================
; fts.asm - full throttle shift, flat shift (HTS "Full throttle shift" page)
;> feature: FEAT_FTS
;> name: Full throttle shift (flat shift)
;> category: Limits
;> pages: fts
;> ram: 1F2h-1F5h (shared cut requests)
;> about: Change gear without lifting: with the throttle past a point and the car moving, pressing the
;>        shift input (the clutch switch, or any switch input) holds the revs at the shift rpm with an
;>        ignition cut, so the turbo stays spooled and the engine does not flare while the clutch is in.
;>        Off until enabled.
; ==================================================================================================
ifdef FEAT_FTS

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_FTS
                JNE     fts_tick_skip
                CAL     fts_tick
fts_tick_skip:
endif

if XP == XP_CAL
;@ FTSEnable type=u8 flag=1 on=1 off=0 category="Full throttle shift" slot=fts.enable desc="Full throttle shift on."
fts_block:              DB  000h
;@ FTSCut type=u8 category="Full throttle shift" slot=fts.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
fts_cut:                DB  001h
;@ FTSRPM type=u16 formula=rpm_period_word category="Full throttle shift" slot=fts.rpm desc="Hold the revs here while the shift input is on."
fts_set:                DW  0015eh               ; 5360 rpm
;@ FTSRPMReset type=u16 formula=rpm_period_word category="Full throttle shift" slot=fts.rpm.reset desc="Back in below this rpm."
fts_reset:              DW  00168h               ; 5210 rpm
;@ FTSInput type=u8 category="Full throttle shift" slot=fts.input desc="The shift input: 01h power steering, 02h service connector, 04h start, 08h VTEC pressure, 10h A/C, 20h brake, 40h park/neutral, 80h always."
fts_input:              DB  020h
;@ FTSInputInvert type=u8 flag=1 on=1 off=0 category="Full throttle shift" slot=fts.input.invert desc="Active while the input is off instead."
fts_invert:             DB  000h
;@ FTSMinTPS type=u8 formula=tps_pct category="Full throttle shift" slot=fts.tps desc="Only with the throttle at least this far open."
fts_tps:                DB  0b3h                 ; 75 %
;@ FTSMinSpeed type=u8 formula=speed_kmh_byte category="Full throttle shift" slot=fts.speed desc="Only above this road speed (below it launch control is the one that applies)."
fts_speed:              DB  00ah
endif

if XP == XP_CODE
fts_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, fts_block           ; off: straight to letting go (the switch is not read)
                CMPB    A, #000h
                JEQ     fts_no
                MOV     X1, #fts_input
                CAL     mod_switch             ; shift input on?
                JEQ     fts_no
                CLRB    A
                LCB     A, fts_tps
                CMPB    0b9h, A                ; throttle - minimum borrows (C) while below it
                JLT     fts_no
                LCB     A, fts_speed
                CMPB    0b4h, A                ; road speed - minimum borrows while below it
                JLT     fts_no
                SC
                SJ      fts_decide
fts_no:         RC
fts_decide:     MOV     X1, #fts_block
                L       A, #MB_FTS
                CAL     mod_limit
                J       mod_tick_exit
endif

endif
