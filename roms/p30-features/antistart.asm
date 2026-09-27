; ==================================================================================================
; antistart.asm - anti-start (HTS120 "Anti-start" page)
;> feature: FEAT_ANTISTART
;> name: Anti-start
;> category: Protection
;> pages: antistart
;> ram: 1F2h-1F6h (shared cut requests, lock flag)
;> about: The ECU powers up with fuel and spark cut, and stays that way until the secret is given: a
;>        switch input on (or off, inverted) with the throttle pressed past a point, before cranking.
;>        The A/C switch by default: throttle alone would clash with clearing a flooded engine, and
;>        nobody reaches for the A/C to start a car. Any of the switch inputs can be picked instead.
;>        Once unlocked it stays unlocked until the ignition is switched off. Off until enabled.
; ==================================================================================================
ifdef FEAT_ANTISTART

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_ANTISTART
                JNE     antistart_tick_skip
                CAL     antistart_tick
antistart_tick_skip:
endif

if XP == XP_CAL
;@ AntiStartEnable type=u8 flag=1 on=1 off=0 category="Anti-start" slot=antistart.enable desc="Anti-start on."
antistart_enable:       DB  000h
;@ AntiStartTPS type=u8 formula=tps_pct category="Anti-start" slot=antistart.tps desc="Unlock with the switch on and the throttle at least this far open."
antistart_tps:          DB  0d0h                 ; about 90 %
;@ AntiStartInput type=u8 formula=raw category="Anti-start" slot=antistart.input desc="The switch that unlocks it (with the throttle): 01h power steering, 02h service connector, 04h start, 08h VTEC pressure, 10h A/C, 20h brake, 40h park/neutral, 80h none (the throttle alone)."
antistart_input:        DB  010h                 ; A/C
;@ AntiStartInputInvert type=u8 flag=1 on=1 off=0 category="Anti-start" slot=antistart.input.invert desc="The switch must be off instead."
antistart_invert:       DB  000h
endif

if XP == XP_CODE
antistart_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LB      A, off(MOD_FLAGS)
                ANDB    A, #002h
                JNE     antistart_checked
                SB      off(MOD_FLAGS).1       ; the first tick after power-up: lock, if enabled
                CLRB    A
                LCB     A, antistart_enable
                CMPB    A, #000h
                JEQ     antistart_checked
                SB      off(MOD_FLAGS).0
antistart_checked:
                CLRB    A
                LB      A, off(MOD_FLAGS)
                ANDB    A, #001h
                JEQ     antistart_free         ; not locked
                MOV     X1, #antistart_input   ; locked: the switch on...
                CAL     mod_switch             ; A = 1: on, after the invert (uses DP, r7)
                JEQ     antistart_hold
                CLRB    A
                LCB     A, antistart_tps       ; ...with the throttle past the point unlocks it
                CMPB    0b9h, A                ; throttle - point borrows while below it
                JLT     antistart_hold
                RB      off(MOD_FLAGS).0
antistart_free: L       A, #MB_ANTISTART
                RC
                CAL     mod_cutboth
                J       mod_tick_exit
antistart_hold: L       A, #MB_ANTISTART
                SC
                CAL     mod_cutboth
                J       mod_tick_exit
endif

endif
