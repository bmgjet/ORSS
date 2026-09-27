; ==================================================================================================
; alphan.asm - load from the throttle instead of MAP (HTS "Maps indexing" page)
;> feature: FEAT_ALPHAN
;> name: Maps indexing (alpha-N)
;> category: Fuel
;> pages: mapindex
;> ram: 2F7h (the load used)
;> about: Looks up the fuel and ignition maps on a load worked out from the throttle (alpha-N) instead
;>        of from MAP: for individual throttle bodies and big cams, where MAP barely moves. Crossover
;>        points pick where it takes over: at or above either the throttle or the MAP point the throttle
;>        table is used, below both the MAP sensor as stock. A throttle point of 0 % means always. Off
;>        until enabled.
; ==================================================================================================
ifdef FEAT_ALPHAN

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_LOADINDEX
define NEED_LOADINDEX
endif

endif

if XP == XP_CAL
;@ AlphaNEnable type=u8 flag=1 on=1 off=0 category="Maps indexing" slot=mapindex.enable desc="Use the throttle for the map load."
alphan_enable:          DB  000h
;@ AlphaNTpsCross type=u8 formula=tps_pct category="Maps indexing" slot=mapindex.crosstps desc="At or above this throttle the throttle table is used (0 % = always)."
alphan_tpscross:        DB  019h
;@ AlphaNMapCross type=u8 formula="x * 3.6 + 114" inverse="(x - 114) / 3.6" unit=mbar decimals=0 category="Maps indexing" slot=mapindex.crossmap desc="Or at or above this MAP (the top of the scale = never on MAP)."
alphan_mapcross:        DB  0ffh
;@ AlphaNTable type=u8 count=9 formula="x * 3.6 + 114" inverse="(x - 114) / 3.6" unit=mbar decimals=0 colvalues=0,12.5,25,37.5,50,62.5,75,87.5,100 colunit="% throttle" category="Maps indexing" slot=mapindex.alpha desc="The load the maps are looked up on, against the throttle: what MAP would read there."
alphan_table:           DB  03ch, 053h, 06bh, 082h, 099h, 0b0h, 0c8h, 0dfh, 0f6h
endif

if XP == XP_CODE
; The skeleton calls it where the maps take their load (crank task): A (byte) = the load, MAP's or the
; throttle table's. Everything else is kept.
mod_loadindex:  L       A, er0
                PUSHS   A
                L       A, er1
                PUSHS   A
                L       A, er2
                PUSHS   A
                L       A, er3
                PUSHS   A
                L       A, X1
                PUSHS   A
                CLRB    A
                LCB     A, alphan_enable
                CMPB    A, #000h
                JEQ     alphan_map
                LCB     A, alphan_tpscross
                STB     A, r0
                LB      A, 0b9h                ; throttle
                CMPB    A, r0
                JGE     alphan_tps
                LCB     A, alphan_mapcross
                STB     A, r0
                LB      A, 0a7h                ; MAP load
                CMPB    A, r0
                JGE     alphan_tps
alphan_map:     LB      A, 0a7h
                SJ      alphan_done
alphan_tps:     LB      A, 0b9h                ; throttle 0-100 % (19h-E5h) as 0-255
                SUBB    A, #019h
                JGE     alphan_tps_pos
                CLRB    A
alphan_tps_pos: STB     A, r0
                SRLB    A                      ; x 1.25
                SRLB    A
                ADDB    A, r0
                JGE     alphan_tps_in
                LB      A, #0ffh
alphan_tps_in:  MOV     X1, #alphan_table
                CAL     mod_lookup9
alphan_done:    STB     A, off(002f7h)         ; (page 2: the crank task's bank)
                POPS    A
                MOV     X1, A
                POPS    A
                L       A, ACC
                ST      A, er3
                POPS    A
                L       A, ACC
                ST      A, er2
                POPS    A
                L       A, ACC
                ST      A, er1
                POPS    A
                L       A, ACC
                ST      A, er0
                LB      A, off(002f7h)
                RT
endif

endif
