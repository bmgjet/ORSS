; ==================================================================================================
; tach.asm - a tachometer signal on a free output (custom2 tach output)
;> feature: FEAT_TACH
;> name: Tachometer output
;> category: Outputs
;> platforms: P13
;> pages: tach
;> ram: 1C1h bit 3 (its state)
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
;@ TachOutput type=u8 formula=raw category="Tachometer output" slot=tach.output desc="The output: 0 none, 1 PB.0 (A/C clutch), 2 PB.7 (EVAP purge), 3 PC.2 (A/T), 4 the O2 heater (the CPU's P2A.2), 5 PC.3 (check-engine lamp), 6 none on the P13 (it has no ECU LED), 7 PB.3 (alternator control) high, 8 PB.3 low, 9 PB.0 held off (A/C clutch disengaged), 10 PB.2 (radiator fan), 11 PB.6 (spare; boost control uses it too). The 82C55's ports B and C; not tried on a car."
tach_output:            DB  00Bh                ; (P13: PB.6, the spare - there is no ECU LED)
endif

if XP == XP_CODE
tach_spark:     CLRB    A                      ; byte mode (LCB keeps the mode it finds)
                LCB     A, tach_enable
                CMPB    A, #000h
                JEQ     tach_off
; P13: the level follows the coil, not each interrupt - Int13 comes more than twice a spark here. The ignition pin
; says which: low, the coil just switched on (the pulse); high, it just fired (the pulse's end). Nothing to change
; when the level is already that - looked at before anything else is saved, as most interrupts end there (at high
; rpm the crank interrupts leave the P13 little time, and this runs three times a spark).
                L       A, DP
                PUSHS   A
                MOV     DP, #MOD_OUTSTATE
                LB      A, [DP]
                ANDB    A, #008h               ; Z: off now (MB and the jumps leave Z alone)
                MB      C, P2.2
                JLT     tach_lvl_off
                JNE     tach_same              ; on already
                SJ      tach_flip
tach_lvl_off:   JEQ     tach_same              ; off already
; the pin is taken the way mod_output takes one (out of the AND mask), and its level flipped in the OR mask; nothing
; comes in while the masks change. Bit 3 of MOD_OUTSTATE is the level, bit 6 of MOD_FLAGS says the pin is held.
tach_flip:      ANDB    PSWH, #0feh
                L       A, X2
                PUSHS   A
                LB      A, [DP]
                XORB    A, #008h               ; the next level (bit 3)
                STB     A, [DP]
                MOV     DP, #MOD_FLAGS
                SB      [DP].6                 ; the pin is held
                CLR     A
                LCB     A, tach_output
                LB      A, ACC
                CMPB    A, #00ch               ; P13: 11 is on the 8255 too (PB.6)
                JGE     tach_flipped           ; past the list: none
                CMPB    A, #000h
                JEQ     tach_flipped
                L       A, ACC                 ; P13: port B's masks or port C's, as lib.asm's table says
                MOV     X2, A
                MOV     DP, #SVC_OVR
                LCB     A, mod_out_port[X2]
                LB      A, ACC                 ; byte mode again (LCB leaves it as the L above set it: word)
                CMPB    A, #000h
                JEQ     tach_have13
                MOV     DP, #SVC_OVR + 2
tach_have13:    LCB     A, mod_out_mask[X2]    ; the pin's bit
                XORB    A, #0ffh
                ANDB    [DP], A                ; held: out of the AND mask
                XORB    A, #0ffh
                INC     DP
                XORB    [DP], A                ; and its level flipped in the OR mask
                CAL     skel_ports_now         ; out to the 8255 now
tach_flipped:   POPS    A
                MOV     X2, A
                ORB     PSWH, #001h            ; the spark interrupt's own nesting back on
tach_same:      POPS    A
                MOV     DP, A
                RT
; off: the pin it held given back, once
tach_off:       L       A, DP
                PUSHS   A
                MOV     DP, #MOD_FLAGS
                MB      C, [DP].6
                JGE     tach_same
                ANDB    PSWH, #0feh
                L       A, X2
                PUSHS   A
                RB      [DP].6
                CAL     tach_release
                SJ      tach_flipped

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
