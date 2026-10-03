; ==================================================================================================
; tpsretard.asm - timing retard on a fast throttle opening (HTS "TPS tip-in retard" page)
;> feature: FEAT_TPSRETARD
;> name: TPS tip-in retard
;> category: Ignition
;> pages: tpsretard
;> ram: module RAM (5 bytes)
;> about: Pulls timing for a moment when the throttle opens quickly, then gives it back a step at a
;>        time: the knock-free way through the lean spike of a sudden tip-in. Only below a set rpm. Off
;>        until enabled.
; ==================================================================================================
ifdef FEAT_TPSRETARD

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_IGNTRIM
define NEED_IGNTRIM
endif
tpsr_trim           EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (tpsr_trim + 2)
tpsr_prev           EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (tpsr_prev + 1)
tpsr_now            EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (tpsr_now + 1)
tpsr_age            EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (tpsr_age + 1)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_TPSRETARD
                JNE     tpsr_tick_skip
                CAL     tpsr_tick
tpsr_tick_skip:
endif

if XP == XP_CAL
;@ TPSRetardEnable type=u8 flag=1 on=1 off=0 category="TPS tip-in retard" slot=tpsretard.enable desc="Tip-in retard on."
tpsr_enable:            DB  000h
;@ TPSRetardRate type=u8 formula=x/2.04 unit="% per 32 ms" decimals=1 category="TPS tip-in retard" slot=tpsretard.rate desc="Opening faster than this."
tpsr_rate:              DB  00ah
;@ TPSRetardAmount type=u8 formula=x/4 unit=deg decimals=2 category="TPS tip-in retard" slot=tpsretard.amount desc="Timing pulled."
tpsr_amount:            DB  010h                 ; 4 degrees
;@ TPSRetardDecay type=u8 formula=x/4 unit="deg per 32 ms" decimals=2 category="TPS tip-in retard" slot=tpsretard.decay desc="Given back this fast."
tpsr_decay:             DB  001h
;@ TPSRetardRPM type=u16 formula=rpm_period_word category="TPS tip-in retard" slot=tpsretard.rpm desc="Only below this rpm."
tpsr_rpm:               DW  00177h               ; 5000 rpm
endif

if XP == XP_CODE
tpsr_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                MOV     DP, #tpsr_age          ; 32 ms steps since the throttle byte last moved, at most 4: the byte
                CLRB    A                      ; only moves as often as the main loop reads the sensor, so a snap
                LB      A, [DP]                ; after a steady spell arrives as one step, however long the spell was
                CMPB    A, #004h
                JGE     tpsr_aged
                ADDB    A, #001h
                STB     A, [DP]
tpsr_aged:      STB     A, r6
                MOV     DP, #tpsr_prev
                LB      A, [DP]
                CMPB    A, #000h
                JNE     tpsr_seeded
                LB      A, 0b9h                ; the first reading after power-up: nothing to compare with yet
                STB     A, [DP]
tpsr_seeded:    STB     A, r4                  ; the throttle when it last moved
                LB      A, 0b9h
                CMPB    A, r4
                JNE     tpsr_moved
                MOVB    r4, #000h              ; not moved: no opening to judge
                SJ      tpsr_judge
tpsr_moved:     STB     A, [DP]
                MOV     DP, #tpsr_age
                MOVB    [DP], #000h
                SUBB    A, r4                  ; the opening since
                JGE     tpsr_rise
                CLRB    A
tpsr_rise:      STB     A, r4
tpsr_judge:     CLRB    A
                LCB     A, tpsr_enable
                CMPB    A, #000h
                JEQ     tpsr_off
                LB      A, r4
                CMPB    A, #000h
                JEQ     tpsr_decay_it
                LC      A, tpsr_rpm
                CMP     0ach, A                ; period past the point's: below the rpm
                JLT     tpsr_decay_it
                CLRB    A                      ; opening at least rate x the time it took?
                LCB     A, tpsr_rate
                STB     A, r0
                LB      A, r6
                MULB
                L       A, ACC
                ST      A, er3
                CLR     A
                LB      A, r4
                L       A, ACC
                CMP     A, er3                 ; opening - rate x time borrows when it opened slower
                JLT     tpsr_decay_it
                CLRB    A
                LCB     A, tpsr_amount
                SJ      tpsr_have
tpsr_decay_it:  MOV     DP, #tpsr_now
                CLRB    A
                LCB     A, tpsr_decay
                STB     A, r5
                LB      A, [DP]
                SUBB    A, r5
                JGE     tpsr_have
tpsr_off:       CLRB    A
tpsr_have:      MOV     DP, #tpsr_now
                STB     A, [DP]
                STB     A, r4
                CLR     A                      ; the retard as a negative trim
                LB      A, r4
                L       A, ACC
                XOR     A, #0ffffh
                ADD     A, #00001h
                MOV     DP, #tpsr_trim
                CAL     mod_igntrim
                J       mod_tick_exit
endif

endif
