; ==================================================================================================
; gear.asm - gear detection from rpm and road speed (HTS "Transmission" page)
;> feature: FEAT_GEAR
;> name: Gear detection
;> category: Sensors
;> pages: transmission
;> ram: 2FEh (the gear)
;> about: Works out the gear from the ratio of rpm to road speed, for everything that depends on the
;>        gear: rpm ceilings, fuel and timing by gear, traction control, the gear-based shift light. Set
;>        the boundaries between gears for the gearbox and tyres fitted. Gear 0 below a road speed, or
;>        with the clutch in (a ratio no gear has).
; ==================================================================================================
ifdef FEAT_GEAR

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif

endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_GEAR
                JNE     gear_tick_skip
                CAL     gear_tick
gear_tick_skip:
endif

if XP == XP_CAL
;@ GearMinSpeed type=u8 formula=speed_kmh_byte category="Transmission" slot=transmission.minspeed desc="Below this road speed the gear is 0 (not known)."
gear_minspeed:          DB  005h
;@ GearBounds type=u16 count=5 formula="29297/max(x,1)" unit="rpm per km/h" decimals=1 category="Transmission" slot=transmission.bounds desc="rpm per km/h between gears 1-2, 2-3, 3-4 and 4-5, then the least any gear gives (below it: clutch in, gear 0)."
gear_bounds:            DW  0010fh, 001afh, 00256h, 00303h, 00494h
endif

if XP == XP_CODE
gear_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, gear_minspeed
                CMPB    0b4h, A                ; road speed - minimum borrows (C) while below it
                JLT     gear_zero
                CLR     A                      ; period x speed / 64, the inverse of rpm per km/h
                LB      A, 0b4h
                L       A, ACC
                ST      A, er0
                L       A, 0ach
                MUL
                MOVB    r7, #006h
gear_shift:     SRL     er1
                ROR     A
                DECB    r7
                JNE     gear_shift
                ST      A, er2
                L       A, er1
                JNE     gear_zero              ; far past any gear (clutch in, or the engine barely turning)
                MOV     X1, #gear_bounds
                LC      A, 00008h[X1]          ; past the least any gear gives: clutch in
                CMP     A, er2
                JLT     gear_zero
                MOVB    r6, #001h
                MOVB    r7, #004h              ; (r4-r5 hold the value)
gear_find:      LC      A, 00000h[X1]
                CMP     A, er2                 ; boundary - value borrows while the value is past it: a higher gear
                JGE     gear_store
                INCB    r6
                INC     X1
                INC     X1
                DECB    r7
                JNE     gear_find
                SJ      gear_store
gear_zero:      MOVB    r6, #000h
gear_store:     MOV     DP, #MOD_GEAR
                LB      A, r6
                STB     A, [DP]
                J       mod_tick_exit
endif

endif
