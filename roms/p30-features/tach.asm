; ==================================================================================================
; tach.asm - a tachometer signal on a free output (custom2 tach output)
;> feature: FEAT_TACH
;> name: Tachometer output
;> category: Outputs
;> pages: tach
;> ram: 1F1h bit 3 (its state)
;> about: A tachometer signal on one of the free outputs, for an aftermarket tacho or a shift light that
;>        wants one: the output changes state at every spark interrupt, two pulses per crank revolution:
;>        the signal a 4-cylinder tacho expects from the igniter. Off until enabled.
; ==================================================================================================
ifdef FEAT_TACH

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif

endif

if XP == XP_SPARK
                CAL     tach_spark
endif

if XP == XP_CAL
;@ TachEnable type=u8 flag=1 on=1 off=0 category="Tachometer output" slot=tach.enable desc="Send a tachometer signal on a free output (for an aftermarket tach or shift light that needs one)."
tach_enable:            DB  000h
;@ TachOutput type=u8 formula=raw category="Tachometer output" slot=tach.output desc="The output: 0 none, 1 P0.0 (A/C clutch, A15), 2 P0.1 (EVAP purge), 3 P0.4 (A/T lock-up, automatic ECUs), 4 P1.2 (O2 heater), 5 P1.4 (check-engine lamp, A13), 6 P1.5 (ECU LED), 7 P0.2 (alternator control, A16) high, 8 P0.2 low, 9 P0.0 held off (A/C clutch disengaged), 10 P0.3 (radiator fan), 11 P4.3 (pin A17; boost control uses it too)."
tach_output:            DB  006h
endif

if XP == XP_CODE
; Every spark interrupt: the output flipped. The pin is taken the way mod_output takes one (out of the AND mask),
; and its level flipped in the OR mask - a few instructions, where mod_output (for any output, either way) took
; most of the interrupt. The spark interrupt lets the timers in while it runs (its 0F4h mask), the module tick
; among them, and the tick changes the same masks: so nothing comes in while this does. Bit 3 of MOD_OUTSTATE is
; the level, bit 6 of MOD_FLAGS says the pin is held: switched off, it is given back once (mod_output, in tach_release).
tach_spark:     ANDB    PSWH, #0feh            ; nothing comes in until the end of this
                L       A, DP
                PUSHS   A
                L       A, X2
                PUSHS   A
                MOV     DP, #MOD_OUTSTATE
                CLR     A                      ; (ACCH 0: the output number is used as a word below)
                LCB     A, tach_enable
                LB      A, ACC
                CMPB    A, #000h
                JNE     tach_on
                MOV     DP, #MOD_FLAGS
                MB      C, [DP].6              ; off: the pin it held given back, once
                JGE     tach_done
                RB      [DP].6
                CAL     tach_release
                SJ      tach_done
tach_on:        LB      A, [DP]
                XORB    A, #008h               ; the next level (bit 3)
                STB     A, [DP]
                MOV     DP, #MOD_FLAGS
                SB      [DP].6                 ; the pin is held
                MOV     DP, #MOD_OUTSTATE
                CLR     A
                LCB     A, tach_output
                LB      A, ACC
                CMPB    A, #00bh
                JLT     tach_port
                JNE     tach_done              ; past the list: none
                MB      C, [DP].3              ; 11: P4.3 itself (DP is still MOD_OUTSTATE)
                MB      P4.3, C
                SJ      tach_done
tach_port:      CMPB    A, #000h
                JEQ     tach_done
                MOV     DP, #SVC_OVR           ; P0's masks (outputs 1-3, 7-10)...
                CMPB    A, #004h
                JLT     tach_have
                CMPB    A, #007h
                JGE     tach_have
                MOV     DP, #SVC_OVR + 2       ; ...or P1's (4-6)
tach_have:      L       A, ACC
                MOV     X2, A
                LCB     A, mod_out_mask[X2]    ; the pin's bit
                LB      A, ACC
                XORB    A, #0ffh
                ANDB    [DP], A                ; held: out of the AND mask
                XORB    A, #0ffh
                INC     DP
                XORB    [DP], A                ; and its level flipped in the OR mask
tach_done:      POPS    A
                MOV     X2, A
                POPS    A
                MOV     DP, A
                ORB     PSWH, #001h            ; the spark interrupt's own nesting back on
                RT

; Switched off: the pin given back to the ECU (mod_output, which uses bank 7Eh's r4-r6, X2 and DP - saved above).
tach_release:   PUSHS   LRB
                MOV     LRB, #SVC_BANKF
                CLRB    A
                LCB     A, tach_output
                RC
                CAL     mod_output
                POPS    LRB
                RT
endif

endif
