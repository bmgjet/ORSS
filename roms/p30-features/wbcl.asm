; ==================================================================================================
; wbcl.asm - closed-loop fuel on a wideband (HTS "Closed loop" page)
;> feature: FEAT_WBCL
;> name: Closed loop on a wideband
;> category: Fuel
;> pages: closeloop
;> conflicts: FEAT_STOCK_O2
;> ram: module RAM (3 bytes)
;> about: Trims the fuel towards a target AFR read from a wideband O2 controller on an analog input: a
;>        target against manifold pressure, only with the engine warm and inside an rpm and throttle
;>        window, and never further than a set limit either way. Outside the window the trim goes back
;>        to nothing. Off until enabled.
; ==================================================================================================
ifdef FEAT_WBCL

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_FUELTRIM
define NEED_FUELTRIM
endif
wbcl_trim           EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (wbcl_trim + 2)
wbcl_afr            EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (wbcl_afr + 1)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_WBCL
                JNE     wbcl_tick_skip
                CAL     wbcl_tick
wbcl_tick_skip:
endif

if XP == XP_CAL
;@ CloseLoopEnable type=u8 flag=1 on=1 off=0 category="Closed loop (wideband)" slot=closeloop.enable desc="Wideband closed loop on."
wbcl_enable:            DB  000h
;@ CloseLoopInput type=u8 category="Closed loop (wideband)" slot=closeloop.input desc="The wideband's analog output on: 0 O2 (D14), 1 ELD (D10), 2 EGR (D12), 3 B6, 4-11 serial input 1-8 (sent over the datalog cable: the serial inputs module)."
wbcl_input:             DB  000h
;@ CloseLoopAFR0 type=u8 formula=x/10 unit=AFR decimals=1 category="Closed loop (wideband)" slot=closeloop.afr0 desc="The AFR the wideband reports at 0 V."
wbcl_afr0:              DB  064h
;@ CloseLoopAFR5 type=u8 formula=x/10 unit=AFR decimals=1 category="Closed loop (wideband)" slot=closeloop.afr5 desc="The AFR it reports at 5 V."
wbcl_afr5:              DB  0c8h
;@ CloseLoopTarget type=u8 count=9 formula=x/10 unit=AFR decimals=1 category="Closed loop (wideband)" slot=closeloop.target colvalues=-6,17,40,63,86,109,132,155,178 colunit=kPa desc="Target AFR against manifold pressure."
wbcl_target:            DB  093h, 093h, 093h, 093h, 08ch, 082h, 07dh, 078h, 078h
;@ CloseLoopECT type=u8 formula=honda_temp_c category="Closed loop (wideband)" slot=closeloop.ect desc="Only with the coolant warmer than this."
wbcl_ect:               DB  045h                 ; 60 C
;@ CloseLoopRPMMin type=u16 formula=rpm_period_word category="Closed loop (wideband)" slot=closeloop.rpm.min desc="Only above this rpm."
wbcl_rpmmin:            DW  00ea6h               ; 500 rpm
;@ CloseLoopRPMMax type=u16 formula=rpm_period_word category="Closed loop (wideband)" slot=closeloop.rpm.max desc="Only below this rpm."
wbcl_rpmmax:            DW  000fah               ; 7500 rpm
;@ CloseLoopTPSMax type=u8 formula=tps_pct category="Closed loop (wideband)" slot=closeloop.tps desc="Only below this throttle opening."
wbcl_tps:               DB  0ffh
;@ CloseLoopLimit type=u8 formula=x*100/256 unit=% decimals=1 category="Closed loop (wideband)" slot=closeloop.limit desc="The trim goes no further than this, either way."
wbcl_limit:             DB  026h                 ; 15 %
;@ CloseLoopGain type=u8 formula=x*100/256 unit="% per AFR" decimals=2 category="Closed loop (wideband)" slot=closeloop.gain desc="Trim added each 32 ms for each 0.1 AFR off target."
wbcl_gain:              DB  001h
endif

if XP == XP_CODE
wbcl_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, wbcl_enable
                CMPB    A, #000h
                JEQ     wbcl_off
                LCB     A, wbcl_ect            ; warm (a smaller byte is warmer)
                CMPB    0c1h, A
                JGE     wbcl_off
                LCB     A, wbcl_tps
                CMPB    0b9h, A
                JGT     wbcl_off
                LC      A, wbcl_rpmmin         ; rpm window
                CMP     0ach, A
                JGT     wbcl_off
                LC      A, wbcl_rpmmax
                CMP     0ach, A
                JLT     wbcl_off
                MOV     X1, #wbcl_input
                CAL     mod_afr
                MOV     DP, #wbcl_afr
                STB     A, [DP]
                LB      A, 0a3h
                MOV     X1, #wbcl_target
                CAL     mod_lookup9
                STB     A, r4                  ; target
                MOV     DP, #wbcl_afr
                LB      A, [DP]
                STB     A, r5                  ; measured
                CLRB    A
                LCB     A, wbcl_gain
                STB     A, r0
                LB      A, r5
                CMPB    A, r4
                JLT     wbcl_rich
                SUBB    A, r4                  ; lean: more fuel
                MULB
                L       A, ACC
                ST      A, er3
                MOV     DP, #wbcl_trim
                L       A, [DP]
                ADD     A, er3
                SJ      wbcl_limit_it
wbcl_rich:      LB      A, r4                  ; rich: less
                SUBB    A, r5
                MULB
                L       A, ACC
                ST      A, er3
                MOV     DP, #wbcl_trim
                L       A, [DP]
                SUB     A, er3
wbcl_limit_it:  ST      A, er3
                CLR     A
                LCB     A, wbcl_limit
                ST      A, er2                 ; + limit
                XOR     A, #0ffffh
                ADD     A, #00001h
                ST      A, er1                 ; - limit
                L       A, er3
                MB      C, ACCH.7
                JLT     wbcl_neg
                CMP     A, er2
                JLE     wbcl_set
                L       A, er2
                SJ      wbcl_set
wbcl_neg:       CMP     A, er1
                JGE     wbcl_set
                L       A, er1
                SJ      wbcl_set
wbcl_off:       CLR     A
wbcl_set:       MOV     DP, #wbcl_trim
                CAL     mod_fueltrim
                J       mod_tick_exit
endif

endif
