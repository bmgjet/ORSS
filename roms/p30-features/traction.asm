; ==================================================================================================
; traction.asm - traction control on the rate the rpm climbs (HTS120 traction control)
;> feature: FEAT_TRACTION
;> name: Traction control
;> category: Ignition
;> pages: tcc
;> requires: FEAT_GEAR
;> ram: module RAM (4 bytes)
;> about: Watches how fast the rpm climbs in each gear: faster than the car can accelerate means the
;>        tyres have let go, and timing is pulled a step at a time until the climb slows, then given
;>        back. Needs gear detection. Off until enabled.
; ==================================================================================================
ifdef FEAT_TRACTION

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_IGNTRIM
define NEED_IGNTRIM
endif
tc_trim             EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (tc_trim + 2)
tc_prev             EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (tc_prev + 1)
tc_now              EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (tc_now + 1)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_TRACTION
                JNE     tc_tick_skip
                CAL     tc_tick
tc_tick_skip:
endif

if XP == XP_CAL
;@ TCEnable type=u8 flag=1 on=1 off=0 category="Traction control" slot=tcc.enable desc="Traction control on."
tc_enable:              DB  000h
;@ TCRateByGear type=u8 count=6 formula=x*1000 unit="rpm/s" decimals=0 category="Traction control" slot=tcc.rate colvalues=0,1,2,3,4,5 colunit=gear desc="In each gear, an rpm climb faster than this is wheelspin (0 = not in that gear)."
tc_rate:                DB  000h, 004h, 003h, 003h, 002h, 002h
;@ TCStep type=u8 formula=x/4 unit=deg decimals=2 category="Traction control" slot=tcc.step desc="Timing pulled each 32 ms while it spins."
tc_step:                DB  008h                 ; 2 degrees
;@ TCMax type=u8 formula=x/4 unit=deg decimals=2 category="Traction control" slot=tcc.max desc="No more than this pulled."
tc_max:                 DB  028h                 ; 10 degrees
;@ TCDecay type=u8 formula=x/4 unit="deg per 32 ms" decimals=2 category="Traction control" slot=tcc.decay desc="Given back this fast once it grips."
tc_decay:               DB  002h
;@ TCMinSpeed type=u8 formula=speed_kmh_byte category="Traction control" slot=tcc.speed desc="Only above this road speed."
tc_speed:               DB  005h
;@ TCMinTPS type=u8 formula=tps_pct category="Traction control" slot=tcc.tps desc="Only above this throttle opening."
tc_tps:                 DB  04ah                 ; 25 %
endif

if XP == XP_CODE
tc_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CAL     mod_rpmbyte            ; the climb since last time, in rpm / 32
                STB     A, r4
                MOV     DP, #tc_prev
                LB      A, [DP]
                STB     A, r5
                LB      A, r4
                STB     A, [DP]
                SUBB    A, r5
                JGE     tc_climb
                CLRB    A
tc_climb:       STB     A, r4
                CLRB    A
                LCB     A, tc_enable
                CMPB    A, #000h
                JEQ     tc_off
                LCB     A, tc_speed
                CMPB    0b4h, A
                JLT     tc_decay_it
                LCB     A, tc_tps
                CMPB    0b9h, A
                JLT     tc_decay_it
                MOV     DP, #MOD_GEAR          ; this gear's limit
                CLR     A
                LB      A, [DP]
                CMPB    A, #006h
                JGE     tc_decay_it
                L       A, ACC
                ADD     A, #tc_rate
                MOV     X1, A
                CLRB    A
                LCB     A, 00000h[X1]
                CMPB    A, #000h
                JEQ     tc_decay_it
                CMPB    A, r4                  ; limit - climb borrows when it climbs faster
                JGE     tc_decay_it
                MOV     DP, #tc_now            ; spinning: more retard
                CLRB    A
                LCB     A, tc_step
                ADDB    A, [DP]
                STB     A, r5
                LCB     A, tc_max
                CMPB    A, r5
                JGE     tc_under_max
                STB     A, r5
tc_under_max:   LB      A, r5
                SJ      tc_have
tc_decay_it:    MOV     DP, #tc_now
                CLRB    A
                LCB     A, tc_decay
                STB     A, r5
                LB      A, [DP]
                SUBB    A, r5
                JGE     tc_have
tc_off:         CLRB    A
tc_have:        MOV     DP, #tc_now
                STB     A, [DP]
                STB     A, r4
                CLR     A
                LB      A, r4
                L       A, ACC
                XOR     A, #0ffffh
                ADD     A, #00001h
                MOV     DP, #tc_trim
                CAL     mod_igntrim
                J       mod_tick_exit
endif

endif
