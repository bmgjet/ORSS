; ==================================================================================================
; tickburn.asm - a diagnostic, not a function: makes the tick (timer 1 interrupt) take a set time longer
; on chosen ticks, to find how long a tick the ECU tolerates. Nothing here is built unless the build
; defines TICKBURN_US (a loop count: about 3.3 us each) - it is not in the New ROM list.
;   TICKBURN_US     the count burnt on ticks 7 (mod 16)
;   TICKBURN2_US    the count burnt on ticks 8 (mod 16), if set
; ==================================================================================================
ifdef TICKBURN_US

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #007h
                JNE     tickburn_skip1
                CAL     tickburn_run1
tickburn_skip1:
ifdef TICKBURN2_US
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #008h
                JNE     tickburn_skip2
                CAL     tickburn_run2
tickburn_skip2:
endif
endif

if XP == XP_CODE
tickburn_run1:  L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                MOV     X1, #TICKBURN_US
tickburn_loop1: DEC     X1
                JNE     tickburn_loop1
                POPS    A
                MOV     X1, A
                POPS    A
                MOV     DP, A
                RT
ifdef TICKBURN2_US
tickburn_run2:  L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                MOV     X1, #TICKBURN2_US
tickburn_loop2: DEC     X1
                JNE     tickburn_loop2
                POPS    A
                MOV     X1, A
                POPS    A
                MOV     DP, A
                RT
endif
endif

endif
