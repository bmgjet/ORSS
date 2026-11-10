; ==================================================================================================
; wmi.asm - water / methanol injection: a pump duty table against boost
;> feature: FEAT_WMI
;> name: Water / methanol injection
;> category: Boost
;> platforms: P13
;> pages: wmi
;> ram: module RAM (3 bytes, the software PWM)
;> about: Drives a water/methanol pump (or its solenoid) on a free output with a duty from a table
;>        against manifold pressure, as the boost controller does for its solenoid: 19.5 Hz, in 4 %
;>        steps. Only above an rpm and throttle and with the coolant warm. Off until enabled.
; ==================================================================================================
ifdef FEAT_WMI

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif
ifndef NEED_SWPWM
define NEED_SWPWM
endif

endif

if XP == XP_TICKSLOT
if SLOT_WMI == TICK_SLOT
                CAL     wmi_tick
endif
endif

if XP == XP_CAL
;@ WmiEnable type=u8 flag=1 on=1 off=0 category="Water/methanol" slot=wmi.enable desc="Water/methanol injection on."
wmi_enable:             DB  000h
;@ WmiOutput type=u8 formula=raw category="Water/methanol" slot=wmi.output desc="The output the pump is on: 0 none, 1 PB.0 (A/C clutch), 2 PB.7 (EVAP purge), 3 PC.2 (A/T), 4 the O2 heater (the CPU's P2A.2), 5 PC.3 (check-engine lamp), 6 none on the P13 (it has no ECU LED), 7 PB.3 (alternator control) high, 8 PB.3 low, 9 PB.0 held off (A/C clutch disengaged), 10 PB.2 (radiator fan), 11 PB.6 (spare; boost control uses it too). The 82C55's ports B and C; not tried on a car."
wmi_out:                DB  002h
;@ WmiRpm type=u16 formula=rpm_period_word category="Water/methanol" slot=wmi.rpm desc="Water / methanol injection only at or above this rpm."
wmi_rpm:                DW  0036eh
;@ WmiThrottle type=u8 formula=tps_pct category="Water/methanol" slot=wmi.tps desc="Only with the throttle at least this."
wmi_tps:                DB  07fh
;@ WmiCoolant type=u8 formula=honda_temp_c category="Water/methanol" slot=wmi.ect desc="Only with the coolant at least this warm."
wmi_ect:                DB  040h
;@ WmiDuty type=u8 count=9 formula=raw unit=% decimals=0 colvalues=-59,974,1987,2999,4011,5024,6036,7049,8061 colunit=mbar category="Water/methanol" slot=wmi.duty desc="Pump duty (0-100 %) against manifold pressure: the raw MAP byte in steps of 32."
wmi_duty:               DB  000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
endif

if XP == XP_CODE
wmi_tick:
                PUSHS   LRB
                MOV     LRB, #SVC_BANKT
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, wmi_out             ; the output (read each time: it can be changed live)
                MOV     DP, #MOD_SWOUT
                STB     A, [DP]
                LCB     A, wmi_enable
                CMPB    A, #000h
                JEQ     wmi_zero
                LCB     A, wmi_tps
                CMPB    ENG_TPS, A
                JLT     wmi_zero
                LCB     A, wmi_ect             ; a larger byte is colder
                CMPB    ENG_ECT, A
                JGT     wmi_zero
                CLR     A
                LC      A, wmi_rpm
                CMP     ENG_RPMP, A
                JGT     wmi_zero
                MOV     X1, #wmi_duty
                LB      A, ENG_MAP
                CAL     mod_lookup9            ; A = duty, %
                SRLB    A                      ; / 4: steps of the 25-step cycle
                SRLB    A
                CMPB    A, #019h
                JLT     wmi_set
                LB      A, #019h
                SJ      wmi_set
wmi_zero:       CLRB    A
wmi_set:        MOV     DP, #MOD_SWDUTY
                STB     A, [DP]
                J       mod_tick_exit
endif

endif
