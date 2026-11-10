; ==================================================================================================
; rollidle.asm - rolling idle: a lumpy, cammy idle from skipped injector or spark events
;> feature: FEAT_ROLLIDLE
;> name: Rolling idle
;> category: Idle
;> platforms: P13
;> pages: rollidle
;> ram: 0FBh (event count), 0FCh bit 1, 0FDh bits 3-4, module RAM (4 bytes)
;> about: At idle, one injector opening (or one spark) in every few is left out, so a different cylinder
;>        misses each time round and the idle rolls and lopes like a big-cam engine. Only below an rpm
;>        and a throttle, at a standstill, with the coolant warm and (optionally) a switch on. Skipping
;>        an injector is the gentle way; skipping a spark sends that cylinder's fuel into the exhaust.
;>        Off until enabled.
; ==================================================================================================
ifdef FEAT_ROLLIDLE

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_INJSKIP
define NEED_INJSKIP
endif
rollidle_hold       EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (rollidle_hold + 1)
rollidle_last       EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (rollidle_last + 1)
rollidle_cyl        EQU     MODRAM_NEXT         ; the event left out last, for the datalog: its injector as a 1 bit (P2.0-P2.3), E0h a spark
rollidle_drops      EQU     MODRAM_NEXT + 1     ; ...and how many have been left out (counts round)
undef MODRAM_NEXT
define MODRAM_NEXT (rollidle_cyl + 2)
endif

if XP == XP_TICK
                CAL     rollidle_every_tick
endif
if XP == XP_TICKSLOT
if SLOT_ROLLIDLE == TICK_SLOT
                CAL     rollidle_tick
endif
endif

if XP == XP_SPARK
                CAL     rollidle_spark
endif

if XP == XP_CAL
;@ RollingIdleEnable type=u8 flag=1 on=1 off=0 category="Rolling idle" slot=rollidle.enable desc="Rolling idle: a lumpy, cammy idle made by leaving out one injector opening or spark in every few, only while idling."
rollidle_enable:        DB  000h
;@ RollingIdleMode type=u8 formula=raw category="Rolling idle" slot=rollidle.mode desc="What is left out: 0 an injector opening, 1 a spark."
rollidle_mode:          DB  000h
;@ RollingIdleEvery type=u8 formula=raw min=3 max=19 category="Rolling idle" slot=rollidle.every desc="Leave out one event in this many (3-19, odd: an even number is taken as the odd one above it, so the miss moves round all four cylinders instead of wearing one). 5 or 7 rolls, 3 is rough."
rollidle_every:         DB  005h
;@ RollingIdleInput type=u8 formula=raw category="Rolling idle" slot=rollidle.input desc="A switch that must be on: 01h power steering, 02h service connector, 04h start, 08h VTEC pressure, 10h A/C, 20h brake, 40h park/neutral, 80h always (no switch needed). On the P13 the brake (20h) is not traced yet and reads off, and park/neutral (40h) is an automatic's (a manual reads off)."
rollidle_input:         DB  080h
;@ RollingIdleInputInvert type=u8 flag=1 on=1 off=0 category="Rolling idle" slot=rollidle.input.invert desc="The switch must be off instead."
rollidle_invert:        DB  000h
;@ RollingIdleRpmMax type=u16 formula=rpm_period_word category="Rolling idle" slot=rollidle.rpm.max desc="It only works below this rpm (an idle, not while driving)."
rollidle_rpm_max:       DW  004e2h                 ; 1500 rpm
;@ RollingIdleRpmMin type=u16 formula=rpm_period_word category="Rolling idle" slot=rollidle.rpm.min desc="Only above this rpm (so it lets go before a stall)."
rollidle_rpm_min:       DW  00ea6h                 ; 500 rpm
;@ RollingIdleThrottle type=u8 formula=tps_pct category="Rolling idle" slot=rollidle.tps desc="Only with the throttle below this."
rollidle_tps:           DB  01fh                   ; 3 %
;@ RollingIdleSpeed type=u8 formula=speed_kmh_byte category="Rolling idle" slot=rollidle.speed desc="Only at or below this road speed."
rollidle_speed:         DB  000h
;@ RollingIdleCoolant type=u8 formula=honda_temp_c category="Rolling idle" slot=rollidle.ect desc="Only with the coolant at least this warm."
rollidle_ect:           DB  040h
endif

if XP == XP_CODE
; Every 32 ms: decide whether it is on, and which of the two event hooks does the skipping (0FDh.3 the
; injectors, 0FDh.4 the sparks).
rollidle_tick:
                PUSHS   LRB
                MOV     LRB, #SVC_BANKT
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, rollidle_enable
if defined(FEAT_REMOTE)
                MOV     DP, #rc_ri_en          ; on or off over the cable (remote.asm)
                CAL     rc_byte_less1
endif
                CMPB    A, #000h
                JEQ     rollidle_off
                MOV     X1, #rollidle_input
                CAL     mod_switch             ; A = 1: the switch agrees (uses DP, r7)
                JEQ     rollidle_off
                CLRB    A
                LCB     A, rollidle_tps        ; throttle below the point
                CMPB    ENG_TPS, A
                JGE     rollidle_off
                LCB     A, rollidle_speed      ; standing (or slower than the point)
                CMPB    ENG_VSS, A
                JGT     rollidle_off
                LCB     A, rollidle_ect        ; warm: a larger byte is colder
                CMPB    ENG_ECT, A
                JGT     rollidle_off
                CLR     A
                LC      A, rollidle_rpm_max    ; below the rpm: the period is longer than the point's
                CMP     ENG_RPMP, A
                JLE     rollidle_off
                CLR     A
                LC      A, rollidle_rpm_min    ; above the floor: the period is shorter
                CMP     ENG_RPMP, A
                JGE     rollidle_off
                CLRB    A
                LCB     A, rollidle_mode
if defined(FEAT_REMOTE)
                MOV     DP, #rc_ri_mode        ; what it leaves out, over the cable (remote.asm)
                CAL     rc_byte_less1
endif
                CMPB    A, #000h
                JNE     rollidle_sparks
                RB      0fdh.4
                SB      0fdh.3
                SJ      rollidle_done
rollidle_sparks:
                RB      0fdh.3
                SB      0fdh.4
                SJ      rollidle_done
rollidle_off:   RB      0fdh.3
                RB      0fdh.4
                ANDB    0fch, #0fdh            ; no spark left out
rollidle_done:  J       mod_tick_exit

; The count down to the next event left out: 3 to 19 events apart, always odd. With four cylinders an even
; count lands every miss on the same one or two cylinders (wear, plug fouling, a hot or washed bore); an odd
; one moves it round all four. An even setting is taken as the odd number above it.
rollidle_reload:
if defined(FEAT_REMOTE)
                L       A, DP                  ; (an interrupt: the caller's DP kept; 0FBh, set below anyway, the scratch)
                PUSHS   A
                MOV     DP, #rc_ri_every       ; one in n set over the cable (remote.asm)...
                CLRB    A
                LB      A, [DP]
                JNE     rollidle_reload_rc
                LCB     A, rollidle_every      ; ...or the tune's
rollidle_reload_rc:
                STB     A, 0fbh
                POPS    A
                MOV     DP, A
                CLRB    A
                LB      A, 0fbh
else
                CLRB    A
                LCB     A, rollidle_every
endif
                CMPB    A, #003h
                JGE     rollidle_reload_hi
                LB      A, #003h
rollidle_reload_hi:
                CMPB    A, #013h
                JLT     rollidle_reload_st
                LB      A, #013h
rollidle_reload_st:
                ORB     A, #001h
                STB     A, 0fbh
                RT

; The skeleton calls it with A (byte), the injectors about to open (a 0 bit opens one), in the injector
; interrupt. Returns A; FFh opens none. Only A and the flags are used; the counter is 0FBh.
mod_injskip:    MB      C, 0fdh.3
                JGE     rollidle_inj_ret
                PUSHS   A
                ORB     A, #0f0h
                CMPB    A, #0ffh
                JEQ     rollidle_inj_keep      ; none opening: not an event
                LB      A, 0fbh
                SUBB    A, #001h
                STB     A, 0fbh
                JEQ     rollidle_inj_skip
                JLT     rollidle_inj_skip      ; (a count left over from before: start again)
rollidle_inj_keep:
                POPS    A                      ; (sets word mode: the caller goes on in byte mode)
                LB      A, ACC
rollidle_inj_ret:
                RT
rollidle_inj_skip:
                CAL     rollidle_reload
                POPS    A                      ; the pattern (word mode): 0 bits open, with those already open
                LB      A, ACC
                XORB    A, #0ffh
                ANDB    A, #00fh               ; a 1 bit: P2.0 injector 1, P2.1 3, P2.2 4, P2.3 2
                XCHGB   A, 0fbh                ; that into 0FBh for a moment, the count into A
                PUSHS   A
                L       A, DP
                PUSHS   A
                MOV     DP, #rollidle_cyl
                LB      A, 0fbh
                STB     A, [DP]                ; the injector left out (for the datalog)
                INC     DP
                LB      A, [DP]
                ADDB    A, #001h
                STB     A, [DP]                ; one more left out
                POPS    A
                MOV     DP, A
                POPS    A                      ; the count back
                LB      A, ACC
                STB     A, 0fbh
                LB      A, #0ffh               ; this one opens nothing
                RT

; Every spark interrupt (XP_SPARK). There are two to a spark: the coil switched on (the dwell starts),
; then off (it fires) a few ms later. An interrupt that comes less than half a spark interval after the one
; before is a spark. The spark to leave out is counted there, and from then bit 1 of the spark-cut request
; is held for one and a half intervals: over the next dwell's start, so the coil is never switched on for
; that spark, and gone again before the one after. Half an interval in 2.048 ms ticks is the high byte of
; the crank period. A and the flags are free here.
rollidle_spark: MB      C, 0fdh.4
                JGE     rollidle_spark_ret
                L       A, DP
                PUSHS   A
                MOV     DP, #rollidle_last
                LB      A, SVC_TICK
                SUBB    A, [DP]                ; ticks since the last spark interrupt
                PUSHS   A
                LB      A, SVC_TICK
                STB     A, [DP]
                POPS    A
                LB      A, ACC                 ; (byte mode again after POPS)
                MB      C, P2.2                ; (P13: the ignition pin says which: low, the coil just switched on; high,
                JGE     rollidle_spark_done    ; it just let go - a spark, or the one left out)
                LB      A, 0fbh                ; a spark: count it
                SUBB    A, #001h
                STB     A, 0fbh
                JEQ     rollidle_spark_out
                JLT     rollidle_spark_out
                SJ      rollidle_spark_done
rollidle_spark_out:
                CAL     rollidle_reload
                MOV     DP, #rollidle_cyl      ; for the datalog: a spark left out, and one more of them
                MOVB    [DP], #0e0h
                INC     DP
                LB      A, [DP]
                ADDB    A, #001h
                STB     A, [DP]
                MOV     DP, #rollidle_hold
                LB      A, ENG_RPMP + 1        ; hold: three quarters of an interval (P13 arms the next dwell later in
                SRLB    A                      ; the interval, at a crank tooth)
                ADDB    A, ENG_RPMP + 1
                JGE     rollidle_hold_set
                LB      A, #0ffh
rollidle_hold_set:
                STB     A, [DP]
                ORB     0fch, #002h
rollidle_spark_done:
                POPS    A
                MOV     DP, A
rollidle_spark_ret:
                RT

; Every tick: a spark left out is let back in once its hold has run down.
rollidle_every_tick:
                MB      C, 0fch.1
                JGE     rollidle_every_ret
                L       A, DP
                PUSHS   A
                MOV     DP, #rollidle_hold
                LB      A, [DP]
                JEQ     rollidle_every_in
                SUBB    A, #001h
                STB     A, [DP]
                SJ      rollidle_every_done
rollidle_every_in:
                ANDB    0fch, #0fdh
rollidle_every_done:
                POPS    A
                MOV     DP, A
rollidle_every_ret:
                RT
endif

endif
