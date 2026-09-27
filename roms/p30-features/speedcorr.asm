; ==================================================================================================
; speedcorr.asm - road speed correction (HTS "Transmission" page, speed correction)
;> feature: FEAT_SPEEDCORR
;> name: Road speed correction
;> category: Sensors
;> pages: transmission
;> ram: none
;> about: Corrects the road speed for a different final drive or tyre size, so the speedometer signal
;>        the ECU works from (speed limits, gear detection, launch, the datalog) reads true. 100 %
;>        changes nothing.
; ==================================================================================================
ifdef FEAT_SPEEDCORR

if XP == XP_DEFS
ifndef NEED_SPEEDCORR
define NEED_SPEEDCORR
endif

endif

if XP == XP_CAL
;@ SpeedCorrection type=u8 formula="x * 100 / 128" inverse="x * 128 / 100" unit=% decimals=1 category="Transmission" slot=transmission.speedcorr desc="The road speed times this (100 % = as measured)."
speedcorr_factor:       DB  080h
endif

if XP == XP_CODE
; The skeleton jumps here (main loop) once it has stored a new road speed (km/h) in 0B4h: 0B4h x the
; factor / 128, at most 255, then on where it was going. Keeps A and er0.
mod_speedcorr:  PUSHS   A
                L       A, er0
                PUSHS   A
                CLRB    A
                LCB     A, speedcorr_factor
                STB     A, r0
                LB      A, 0b4h
                MULB
                L       A, ACC                 ; word mode: speed x factor
                SLL     A                      ; / 128: one bit left, the high byte
                JLT     speedcorr_max
                LB      A, ACCH
                SJ      speedcorr_store
speedcorr_max:  LB      A, #0ffh
speedcorr_store:
                STB     A, 0b4h
                POPS    A
                L       A, ACC
                ST      A, er0
                POPS    A
                L       A, ACC
                J       vss_calc_gate2_if_ram231_bit3_set
endif

endif
