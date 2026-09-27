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
;@ TachEnable type=u8 flag=1 on=1 off=0 category="Tachometer output" slot=tach.enable desc="Tachometer output on."
tach_enable:            DB  000h
;@ TachOutput type=u8 formula=raw category="Tachometer output" slot=tach.output desc="The output: 0 none, 1 P0.0 (A/C clutch), 2 P0.1 (EVAP purge), 3 P0.4 (A/T), 4 P1.2 (O2 heater), 5 P1.4 (check-engine lamp), 6 P1.5 (ECU LED)."
tach_output:            DB  006h
endif

if XP == XP_CODE
tach_spark:     PUSHS   LRB
                MOV     LRB, #0007eh           ; scratch bank (interrupts do not nest here)
                L       A, DP
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, tach_enable
                CMPB    A, #000h
                RC
                JEQ     tach_drive
                MOV     DP, #MOD_OUTSTATE      ; the next state
                LB      A, [DP]
                XORB    A, #008h
                STB     A, [DP]
                ANDB    A, #008h
                CMPB    A, #000h
                SC
                JNE     tach_drive
                RC
tach_drive:     CLRB    A
                LCB     A, tach_output
                CAL     mod_output
                POPS    A
                MOV     X2, A
                POPS    A
                MOV     DP, A
                POPS    LRB
                RT
endif

endif
