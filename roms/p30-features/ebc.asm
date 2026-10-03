; ==================================================================================================
; ebc.asm - electronic boost control on P4.3 (HTS "Electronic boost control" page)
;> feature: FEAT_EBC
;> name: Electronic boost control
;> category: Boost
;> pages: ebc
;> conflicts: FEAT_BOOSTMANUAL, FEAT_STOCK_AT
;> ram: module RAM (2 bytes)
;> about: Drives a boost control solenoid on P4.3 (the stock A/T lock-up output) at 19.5 Hz: a base duty
;>        against rpm, corrected towards a target boost against rpm (closed loop, set the gain to 0 for
;>        open loop). Below a throttle opening the solenoid is off and the wastegate holds its spring
;>        pressure. Off until enabled.
; ==================================================================================================
ifdef FEAT_EBC

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_PWM43
define NEED_PWM43
endif
ebc_rpm             EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (ebc_rpm + 1)
ebc_base            EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (ebc_base + 1)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_EBC
                JNE     ebc_tick_skip
                CAL     ebc_tick
ebc_tick_skip:
endif

if XP == XP_CAL
;@ EBCEnable type=u8 flag=1 on=1 off=0 category="Electronic boost control" slot=ebc.enable desc="Boost control on."
ebc_enable:             DB  000h
;@ EBCMinTPS type=u8 formula=tps_pct category="Electronic boost control" slot=ebc.tps desc="Solenoid off below this throttle opening."
ebc_tps:                DB  07dh                 ; 50 %
;@ EBCGain type=u8 category="Electronic boost control" slot=ebc.gain formula=x/16 unit="% per count" decimals=2 desc="Closed loop: duty added for each MAP count under the target (0 = open loop)."
ebc_gain:               DB  000h
;@ EBCMaxDuty type=u8 category="Electronic boost control" slot=ebc.maxduty formula=x unit=% decimals=0 desc="Never more duty than this."
ebc_maxduty:            DB  05ah                 ; 90 %
;@ EBCDuty type=u8 count=9 category="Electronic boost control" slot=ebc.duty formula=x unit=% decimals=0 colvalues=0,1024,2048,3072,4096,5120,6144,7168,8192 colunit=rpm desc="Base duty against rpm."
ebc_duty:               DB  000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
;@ EBCTarget type=u8 count=9 formula=map_mbar category="Electronic boost control" slot=ebc.target colvalues=0,1024,2048,3072,4096,5120,6144,7168,8192 colunit=rpm desc="Target boost against rpm (closed loop)."
ebc_target:             DB  0d8h, 0d8h, 0d8h, 0d8h, 0d8h, 0d8h, 0d8h, 0d8h, 0d8h
endif

if XP == XP_CODE
ebc_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, ebc_enable
                CMPB    A, #000h
                JEQ     ebc_off
                LCB     A, ebc_tps
                CMPB    0b9h, A                ; throttle - minimum borrows while below it
                JLT     ebc_off
                CAL     mod_rpmbyte
                MOV     DP, #ebc_rpm
                STB     A, [DP]
                MOV     X1, #ebc_duty
                CAL     mod_lookup9            ; the base duty
                MOV     DP, #ebc_base
                STB     A, [DP]
                MOV     DP, #ebc_rpm
                LB      A, [DP]
                MOV     X1, #ebc_target
                CAL     mod_lookup9            ; the target
                STB     A, r4
                LB      A, 0a3h
                STB     A, r5
                CLRB    A
                LCB     A, ebc_gain
                STB     A, r0
                LB      A, r4
                CMPB    A, r5
                JLT     ebc_over
                SUBB    A, r5                  ; under the target: more duty
                MULB
                L       A, ACC
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                ST      A, er3
                MOV     DP, #ebc_base
                CLR     A
                LB      A, [DP]
                L       A, ACC
                ADD     A, er3
                SJ      ebc_clamp
ebc_over:       LB      A, r5                  ; over it: less
                SUBB    A, r4
                MULB
                L       A, ACC
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                ST      A, er3
                MOV     DP, #ebc_base
                CLR     A
                LB      A, [DP]
                L       A, ACC
                SUB     A, er3
                JGE     ebc_clamp
                CLR     A
ebc_clamp:      ST      A, er3
                CLR     A
                LCB     A, ebc_maxduty
                CMP     A, er3                 ; maximum - duty borrows when the duty is past it
                JLT     ebc_duty_ok
                L       A, er3
ebc_duty_ok:    ADD     A, #00002h             ; percent to 25 steps
                SRL     A
                SRL     A
                ST      A, er3
                MOV     DP, #MOD_PWMDUTY
                LB      A, r6
                STB     A, [DP]
                J       mod_tick_exit
ebc_off:        MOV     DP, #MOD_PWMDUTY
                MOVB    [DP], #000h
                J       mod_tick_exit
endif

endif
