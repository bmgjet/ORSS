; ==================================================================================================
; boostmanual.asm - fixed duty on a boost solenoid (HTS "Manual boost controller" page)
;> feature: FEAT_BOOSTMANUAL
;> name: Manual boost controller
;> category: Boost
;> pages: boostmanual
;> conflicts: FEAT_EBC, FEAT_STOCK_AT
;> ram: none
;> about: One duty on a boost control solenoid on P4.3, above an rpm and a throttle opening: the
;>        electronic version of a bleed valve, for a second boost level over the wastegate spring. Off
;>        until enabled.
; ==================================================================================================
ifdef FEAT_BOOSTMANUAL

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_PWM43
define NEED_PWM43
endif

endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_EBC
                JNE     boostman_tick_skip
                CAL     boostman_tick
boostman_tick_skip:
endif

if XP == XP_CAL
;@ BoostManualEnable type=u8 flag=1 on=1 off=0 category="Manual boost controller" slot=boostmanual.enable desc="Manual boost controller on."
boostman_enable:        DB  000h
;@ BoostManualDuty type=u8 formula=x unit=% decimals=0 category="Manual boost controller" slot=boostmanual.duty desc="Solenoid duty."
boostman_duty:          DB  032h                 ; 50 %
;@ BoostManualRPM type=u16 formula=rpm_period_word category="Manual boost controller" slot=boostmanual.rpm desc="Only above this rpm."
boostman_rpm:           DW  0020dh               ; 3570 rpm
;@ BoostManualTPS type=u8 formula=tps_pct category="Manual boost controller" slot=boostmanual.tps desc="Only above this throttle opening."
boostman_tps:           DB  07dh                 ; 50 %
endif

if XP == XP_CODE
boostman_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, boostman_enable
                CMPB    A, #000h
                JEQ     boostman_off
                LCB     A, boostman_tps
                CMPB    0b9h, A
                JLT     boostman_off
                LC      A, boostman_rpm
                CMP     0ach, A                ; period past the point's: below the rpm
                JGT     boostman_off
                CLR     A
                LCB     A, boostman_duty
                ADD     A, #00002h
                SRL     A
                SRL     A
                SJ      boostman_set
boostman_off:   CLR     A
boostman_set:   ST      A, er3
                MOV     DP, #MOD_PWMDUTY
                LB      A, r6
                STB     A, [DP]
                J       mod_tick_exit
endif

endif
