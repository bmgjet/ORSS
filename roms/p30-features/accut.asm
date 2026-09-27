; ==================================================================================================
; accut.asm - the A/C compressor off under load (HTS "A/C" cut-off)
;> feature: FEAT_ACCUT
;> name: A/C load disable
;> category: Outputs
;> pages: ac
;> requires: FEAT_STOCK_AC
;> ram: module RAM (1 byte)
;> about: Keeps the A/C compressor clutch off at wide throttle, above an rpm, or below an rpm (at a low
;>        idle, where it could stall the engine), and for a hold time after. Needs the stock A/C control
;>        built in. Off until enabled.
; ==================================================================================================
ifdef FEAT_ACCUT

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif
accut_timer         EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (accut_timer + 1)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_ACCUT
                JNE     accut_tick_skip
                CAL     accut_tick
accut_tick_skip:
endif

if XP == XP_CAL
;@ AcCutEnable type=u8 flag=1 on=1 off=0 category="A/C cut-off" slot=ac.cutoff.enable desc="A/C cut-off on."
accut_enable:           DB  000h
;@ AcCutThrottle type=u8 formula=tps_pct category="A/C cut-off" slot=ac.cutoff.tps desc="Off at or above this throttle."
accut_tps:              DB  0c0h
;@ AcCutRpmHigh type=u16 formula=rpm_period_word category="A/C cut-off" slot=ac.cutoff.rpm desc="Off at or above this rpm."
accut_rpm_hi:           DW  00177h
;@ AcCutRpmLow type=u16 formula=rpm_period_word category="A/C cut-off" slot=ac.idlecut desc="Off below this rpm (a low idle)."
accut_rpm_lo:           DW  0ffffh
;@ AcCutHold type=u8 formula="x * 32.8" inverse="x / 32.8" unit=ms decimals=0 category="A/C cut-off" slot=ac.cutoff.hold desc="Kept off this long after."
accut_hold:             DB  01eh
endif

if XP == XP_CODE
accut_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, accut_enable
                CMPB    A, #000h
                JEQ     accut_release
                LCB     A, accut_tps
                CMPB    0b9h, A
                JGE     accut_cut
                CLR     A
                LC      A, accut_rpm_hi
                CMP     0ach, A                ; period at or below the high point's: above that rpm
                JLE     accut_cut
                CLR     A
                LC      A, accut_rpm_lo
                CMP     0ach, A                ; period past the low point's: below that rpm
                JGT     accut_cut
                MOV     DP, #accut_timer       ; none of them: back on once the hold runs out
                CLRB    A
                LB      A, [DP]
                CMPB    A, #000h
                JEQ     accut_release
                SUBB    A, #001h
                STB     A, [DP]
                J       mod_tick_exit
accut_cut:      MOV     DP, #accut_timer
                CLRB    A
                LCB     A, accut_hold
                STB     A, [DP]
                SB      off(MOD_FLAGS).4       ; (taken)
                SC
                SJ      accut_drive
accut_release:  JBS     off(MOD_FLAGS).4, accut_giveback
                J       mod_tick_exit          ; not taken: the stock control is left alone
accut_giveback: RB      off(MOD_FLAGS).4
                RC
accut_drive:    LB      A, #009h               ; P0.0 held off (the clutch disengaged), or handed back
                CAL     mod_output
                J       mod_tick_exit
endif

endif
