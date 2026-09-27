; ==================================================================================================
; antistall.asm - anti-stall: the engine held up when the rpm drops too low
;> feature: FEAT_ANTISTALL
;> name: Anti-stall
;> category: Idle
;> pages: antistall
;> ram: 0FDh bit 2, module RAM (3 bytes)
;> about: When the rpm drops below a point with the engine running, it does what it can to keep it
;>        going: the idle valve opened to a set duty, timing added, and optionally the A/C compressor
;>        and the alternator switched off to take their load away. Back to normal above a higher rpm,
;>        after a hold time. Off until enabled.
; ==================================================================================================
ifdef FEAT_ANTISTALL

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif
ifndef NEED_IGNTRIM
define NEED_IGNTRIM
endif
ifndef NEED_IACV
define NEED_IACV
endif
antistall_trim      EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (antistall_trim + 2)
antistall_timer     EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (antistall_timer + 1)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_ANTISTALL
                JNE     antistall_tick_skip
                CAL     antistall_tick
antistall_tick_skip:
endif

if XP == XP_CAL
;@ AntiStallEnable type=u8 flag=1 on=1 off=0 category="Anti-stall" slot=antistall.enable desc="Anti-stall on."
antistall_enable:       DB  000h
;@ AntiStallRpm type=u16 formula=rpm_period_word category="Anti-stall" slot=antistall.rpm desc="Acts below this rpm."
antistall_rpm:          DW  00c35h
;@ AntiStallRecover type=u16 formula=rpm_period_word category="Anti-stall" slot=antistall.recover desc="Back to normal above this rpm."
antistall_recover:      DW  00b16h
;@ AntiStallRunning type=u16 formula=rpm_period_word category="Anti-stall" slot=antistall.running desc="Only with the engine above this rpm (not while cranking or stopped)."
antistall_running:      DW  01869h
;@ AntiStallAdvance type=u8 formula=x/4 unit=deg decimals=2 category="Anti-stall" slot=antistall.advance desc="Timing added."
antistall_advance:      DB  014h
;@ AntiStallIdleDuty type=u16 formula=raw category="Anti-stall" slot=antistall.iacv desc="The idle valve duty word used at least (the stock top of its range is 091Fh)."
antistall_iacv:         DW  0091fh
;@ AntiStallAcOff type=u8 flag=1 on=1 off=0 category="Anti-stall" slot=antistall.ac desc="The A/C compressor off (with the stock A/C built in)."
antistall_ac:           DB  001h
;@ AntiStallAltOff type=u8 formula=raw category="Anti-stall" slot=antistall.alt desc="The alternator: 0 left alone, 7 control line P0.5 high, 8 P0.5 low (the level that turns charging down)."
antistall_alt:          DB  000h
;@ AntiStallHold type=u8 formula="x * 32.8" inverse="x / 32.8" unit=ms decimals=0 category="Anti-stall" slot=antistall.hold desc="Kept on this long after the rpm has recovered."
antistall_hold:         DB  00fh
endif

if XP == XP_CODE
antistall_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, antistall_enable
                CMPB    A, #000h
                JEQ     antistall_off
                CLR     A
                LC      A, antistall_running
                CMP     0ach, A                ; not running (period past the point's): off
                JGT     antistall_off
                MB      C, 0fdh.2
                JLT     antistall_active
                CLR     A
                LC      A, antistall_rpm       ; engage below the rpm
                CMP     0ach, A
                JLE     antistall_quiet
                SJ      antistall_on
antistall_active:
                CLR     A
                LC      A, antistall_recover   ; still low (period past the recover point's): stay on
                CMP     0ach, A
                JGT     antistall_on
                MOV     DP, #antistall_timer   ; recovered: off once the hold runs out
                CLRB    A
                LB      A, [DP]
                CMPB    A, #000h
                JEQ     antistall_off
                SUBB    A, #001h
                STB     A, [DP]
                J       mod_tick_exit
antistall_on:   MOV     DP, #antistall_timer
                CLRB    A
                LCB     A, antistall_hold
                STB     A, [DP]
                SB      0fdh.2
                CLR     A
                LCB     A, antistall_advance
                MOV     DP, #antistall_trim
                CAL     mod_igntrim
                SC
                CAL     antistall_outputs
                J       mod_tick_exit
antistall_off:  RB      0fdh.2
                CLR     A
                MOV     DP, #antistall_trim
                CAL     mod_igntrim
                RC
                CAL     antistall_outputs
antistall_quiet:
                J       mod_tick_exit

; C = take the A/C and the alternator (as set), or hand them back
antistall_outputs:
                JLT     antistall_take
                JBS     off(MOD_FLAGS).5, antistall_give
                RT                             ; never taken: the stock control is left alone
antistall_give: RB      off(MOD_FLAGS).5
                RC
                SJ      antistall_out_go
antistall_take: SB      off(MOD_FLAGS).5
                SC
antistall_out_go:
                CLRB    A
                MB      ACC.0, C
                STB     A, r7
                LCB     A, antistall_ac
                CMPB    A, #000h
                JEQ     antistall_out_alt
                LB      A, r7
                SRLB    A                      ; C = the request
                LB      A, #009h               ; P0.0 held off
                CAL     mod_output
antistall_out_alt:
                CLRB    A
                LCB     A, antistall_alt
                CMPB    A, #000h
                JEQ     antistall_out_done
                STB     A, r6
                LB      A, r7
                SRLB    A
                LB      A, r6
                CAL     mod_output
antistall_out_done:
                RT

; The skeleton calls it with A, the idle valve duty word, before it is stored (main loop): raised to the
; anti-stall duty while anti-stall is on. er0 is free there.
mod_iacv:       MB      C, 0fdh.2
                JGE     mod_iacv_ret
                ST      A, er0
                LC      A, antistall_iacv
                L       A, ACC
                CMP     A, er0
                JGE     mod_iacv_ret
                L       A, er0
mod_iacv_ret:   RT
endif

endif
