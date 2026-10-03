; ==================================================================================================
; outtest.asm - a diagnostic, not a module: flashes one output, about once a second, to find out on the car
; what each one drives. Built only with OUTTEST=n defined (SkeletonBuild takes "OUTTEST=5"):
;   0-7    P0.0-P0.7: the P0 latch, copied to the 8255's port B
;   8-15   P1.0-P1.7: the P1 latch, copied to the 8255's port C
;   16     P4.3 (the boost solenoid output of EBC / manual boost)
;   17     P4.2
; On for 524 ms, off for 524 ms (bit 8 of the tick), from power-up, engine running or not. A P0/P1 bit is taken
; with the output overrides (so nothing else in the ROM drives it meanwhile) and written to the 8255 at once.
; ==================================================================================================
ifdef OUTTEST

if XP == XP_DEFS
if OUTTEST < 16
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif
endif
OUTTEST_BIT     EQU     (1 << (OUTTEST & 7))
endif

if XP == XP_TICK
                CAL     outtest_tick
endif

if XP == XP_CODE
; Tick context: only A is free; DP is kept.
outtest_tick:
if OUTTEST < 16
                LB      A, 0feh
                JEQ     outtest_go             ; once every 256 ticks (524 ms)
                RT
else
                MB      C, 0ffh.0              ; P4: the pin itself, every tick (the stock code writes P4 whole now and
if OUTTEST < 17                                ; then, as EBC's PWM finds)
                MB      P4.3, C
else
                MB      P4.2, C
endif
                RT
endif
outtest_go:     L       A, DP
                PUSHS   A
if OUTTEST < 16
if OUTTEST < 8
                MOV     DP, #003dch            ; P0's AND mask: the pin is the test's
else
                MOV     DP, #003deh            ; P1's
endif
                LB      A, [DP]
                ANDB    A, #(0ffh - OUTTEST_BIT)
                STB     A, [DP]
                INC     DP                     ; the OR mask: its level, high while bit 8 of the tick is set
                LB      A, [DP]
                ANDB    A, #(0ffh - OUTTEST_BIT)
                MB      C, 0ffh.0
                JGE     outtest_low
                ORB     A, #OUTTEST_BIT
outtest_low:    STB     A, [DP]
if OUTTEST < 8
                LB      A, P0                  ; out to the 8255 now
                CAL     skel_ovr_p0
                MOV     DP, #01f00h
else
                LB      A, P1
                CAL     skel_ovr_p1
                MOV     DP, #02f00h
endif
                STB     A, [DP]
endif
                POPS    A
                MOV     DP, A
                RT
endif

endif
