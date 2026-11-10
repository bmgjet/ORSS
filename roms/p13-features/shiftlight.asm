; ==================================================================================================
; shiftlight.asm - MIL shift light (HTS "MIL shift light" page)
;> feature: FEAT_SHIFTLIGHT
;> name: Shift light on the check-engine lamp
;> category: Driver aids
;> platforms: P13
;> pages: shiftlight
;> ram: none
;> about: Lights the dash check-engine lamp (PC.3) above a shift rpm, one rpm for every gear or one
;>        per gear. Below it the lamp is left to whatever else drives it (the stock trouble codes, when
;>        they are built in).
; ==================================================================================================
ifdef FEAT_SHIFTLIGHT

if XP == XP_DEFS
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif
endif

if XP == XP_MAIN
                CAL     shiftlight_main
endif

if XP == XP_CAL
;@ MILShiftLight type=u8 flag=1 on=255 off=0 category="MIL shift light" slot=shiftlight.enable desc="Shift light on the check-engine lamp."
shiftlight_enable:      DB  000h
;@ MILShiftLightGear type=u8 flag=1 on=255 off=0 category="MIL shift light" slot=shiftlight.gearbased desc="A shift rpm for each gear: the shift light comes on earlier or later by gear (needs gear detection)."
shiftlight_gearbased:   DB  000h
;@ MILShiftLightRPM type=u16 formula=rpm_period_word category="MIL shift light" slot=shiftlight.rpm desc="Shift rpm (and the gear-0 entry)."
shiftlight_rpm:         DW  000EAh
;@ MILShiftLightIndex type=u16 count=5 formula=rpm_period_word category="MIL shift light" slot=shiftlight.gear desc="The shift rpm in gears 1-5."
shiftlight_rpm_gear:    DW  000EAh, 000EAh, 000EAh, 000EAh, 000EAh
endif

if XP == XP_CODE
; once per main-loop pass
shiftlight_main:
if defined(FEAT_REMOTE)
                L       A, DP                  ; the caller's DP kept: the point set over the cable is read with it
                PUSHS   A
                CAL     shiftlight_body
                POPS    A
                MOV     DP, A
                RT
shiftlight_body:
endif
                CLRB    A                      ; byte mode: the main loop can call in either
                LCB     A, shiftlight_enable
                CMPB    A, #000h
                JEQ     shiftlight_release
                LCB     A, shiftlight_gearbased
                CMPB    A, #000h
                JNE     shiftlight_by_gear
                CLR     A
                LC      A, shiftlight_rpm
                SJ      shiftlight_compare
shiftlight_by_gear:
                CLR     A
                LB      A, off(MOD_GEAR)       ; gear from gear detection, 0 when it is not known
                L       A, ACC
                SLL     A
                LC      A, shiftlight_rpm[ACC] ; the gear table follows the single rpm word
shiftlight_compare:
if defined(FEAT_REMOTE)
                PUSHS   A                      ; the tune's point...
                MOV     DP, #rc_shift_per
                L       A, [DP]
                JEQ     shiftlight_tune
                MOV     DP, A                  ; ...or the one set over the cable (remote.asm)
                POPS    A
                L       A, DP
                SJ      shiftlight_compare_now
shiftlight_tune:
                POPS    A
shiftlight_compare_now:
endif
                CMP     ENG_RPMP, A                ; crank period below the shift period = rpm above the shift point
                JGE     shiftlight_release
                L       A, DP                  ; lamp on: take PC.3 (1 = on)
                PUSHS   A
                MOV     DP, #SVC_OVR + 2       ; (P13: port C's PC.3)
                RB      [DP].3
                INC     DP
                SB      [DP].3
                POPS    A
                MOV     DP, A
                RT
shiftlight_release:
                L       A, DP                  ; give PC.3 back
                PUSHS   A
                MOV     DP, #SVC_OVR + 2       ; (P13: port C's PC.3, and its copy's bit off)
                SB      [DP].3
                INC     DP
                RB      [DP].3
                MOV     DP, #00226h
                RB      [DP].3
                POPS    A
                MOV     DP, A
                RT
endif

endif
