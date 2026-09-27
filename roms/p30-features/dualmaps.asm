; ==================================================================================================
; dualmaps.asm - a second full set of fuel and ignition maps on a switch (HTS "Secondary maps" page)
;> feature: FEAT_DUALMAPS
;> name: Secondary maps (full fuel and ignition maps)
;> category: Fuel
;> pages: dualmap
;> conflicts: FEAT_MAPSWITCH
;> ram: 0FDh bit 0
;> about: A complete second set of fuel and ignition maps, low and high cam (FuelLow2, FuelHigh2,
;>        IgnitionLow2, IgnitionHigh2), used instead of the first set while a switch input is on and,
;>        if set, above an rpm and a throttle: race fuel and pump fuel, a valet tune, a nitrous or boost
;>        map. They start as copies of the first maps. They are the same size as the first maps (twice
;>        as large with extended maps): about 820 bytes, 1,640 with FEAT_EXTMAPS. Off until enabled.
; ==================================================================================================
ifdef FEAT_DUALMAPS

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_MAPSELECT
define NEED_MAPSELECT
endif
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_DUALMAPS
                JNE     dualmaps_tick_skip
                CAL     dualmaps_tick
dualmaps_tick_skip:
endif

if XP == XP_CAL
;@ SecondMapsEnable type=u8 flag=1 on=1 off=0 category="Secondary maps" slot=dualmap.enable desc="Secondary maps on."
dualmaps_enable:        DB  000h
;@ SecondMapsInput type=u8 formula=raw category="Secondary maps" slot=dualmap.input desc="The switch that selects them: 01h power steering, 02h service connector, 04h start, 08h VTEC pressure, 10h A/C, 20h brake, 40h park/neutral, 80h always."
                        DB  080h
;@ SecondMapsInvert type=u8 flag=1 on=1 off=0 category="Secondary maps" slot=dualmap.input.invert desc="Selected while the input is off instead."
                        DB  000h
;@ SecondMapsRpm type=u16 formula=rpm_period_word category="Secondary maps" slot=dualmap.rpm desc="And only at or above this rpm (the lowest setting: any)."
dualmaps_rpm:           DW  0ffffh
;@ SecondMapsThrottle type=u8 formula=tps_pct category="Secondary maps" slot=dualmap.tps desc="And only with the throttle at least this (the lowest setting: any)."
dualmaps_tps:           DB  000h
endif

if XP == XP_CODE
dualmaps_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, dualmaps_enable
                CMPB    A, #000h
                JEQ     dualmaps_off
                MOV     X1, #dualmaps_enable + 1
                CAL     mod_mapinput           ; A = 1 on (the switch, or the datalog service command)
                JEQ     dualmaps_off
                CLRB    A
                LCB     A, dualmaps_tps
                CMPB    0b9h, A
                JLT     dualmaps_off
                CLR     A
                LC      A, dualmaps_rpm
                CMP     0ach, A                ; period past the point's: below the rpm
                JGT     dualmaps_off
                SB      0fdh.0
                J       mod_tick_exit
dualmaps_off:   RB      0fdh.0
                J       mod_tick_exit

; The skeleton calls it with X1 = the map a lookup is about to use (the crank task and the fuel task): the
; secondary one instead while they are selected. Keeps everything but X1.
mod_mapselect:  MB      C, 0fdh.0
                JGE     mapsel_ret
                PUSHS   A
                L       A, X1
                CMP     A, #FuelLow
                JNE     mapsel_1
                MOV     X1, #FuelLow2
                SJ      mapsel_done
mapsel_1:       CMP     A, #FuelHigh
                JNE     mapsel_2
                MOV     X1, #FuelHigh2
                SJ      mapsel_done
mapsel_2:       CMP     A, #IgnitionLow
                JNE     mapsel_3
                MOV     X1, #IgnitionLow2
                SJ      mapsel_done
mapsel_3:       CMP     A, #IgnitionHigh
                JNE     mapsel_done
                MOV     X1, #IgnitionHigh2
mapsel_done:    POPS    A
mapsel_ret:     RT
endif

endif
