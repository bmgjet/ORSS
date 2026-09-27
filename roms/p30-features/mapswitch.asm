; ==================================================================================================
; mapswitch.asm - a second tune on a switch (HTS "Secondary maps" page)
;> feature: FEAT_MAPSWITCH
;> name: Secondary tune on a switch
;> category: Fuel
;> pages: dualmap
;> conflicts: FEAT_DUALMAPS
;> ram: module RAM (4 bytes)
;> about: A second tune for a switch input: while it is on, fuel and timing change by two tables against
;>        rpm - race fuel against pump fuel, a valet tune, or a nitrous map with the timing pulled. Off
;>        with the switch off. Off until enabled.
; ==================================================================================================
ifdef FEAT_MAPSWITCH

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_FUELTRIM
define NEED_FUELTRIM
endif
ifndef NEED_IGNTRIM
define NEED_IGNTRIM
endif
mapsw_ftrim         EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (mapsw_ftrim + 2)
mapsw_itrim         EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (mapsw_itrim + 2)
mapsw_rpm           EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (mapsw_rpm + 1)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_MAPSWITCH
                JNE     mapsw_tick_skip
                CAL     mapsw_tick
mapsw_tick_skip:
endif

if XP == XP_CAL
;@ DualMapEnable type=u8 flag=1 on=1 off=0 category="Secondary tune" slot=dualmap.enable desc="Secondary tune on."
mapsw_enable:           DB  000h
;@ DualMapInput type=u8 category="Secondary tune" slot=dualmap.input desc="The switch that selects it: 01h power steering, 02h service connector, 04h start, 08h VTEC pressure, 10h A/C, 20h brake, 40h park/neutral, 80h always."
mapsw_input:            DB  010h
;@ DualMapInvert type=u8 flag=1 on=1 off=0 category="Secondary tune" slot=dualmap.input.invert desc="Selected while the input is off instead."
mapsw_invert:           DB  000h
;@ DualMapFuel type=u8 count=9 formula=(x-128)*100/256 unit=% decimals=1 category="Secondary tune" slot=dualmap.fuel colvalues=0,1024,2048,3072,4096,5120,6144,7168,8192 colunit=rpm desc="The fuel change against rpm."
mapsw_fuel:             DB  080h, 080h, 080h, 080h, 080h, 080h, 080h, 080h, 080h
;@ DualMapIgn type=u8 count=9 formula=(x-128)/4 unit=deg decimals=2 category="Secondary tune" slot=dualmap.ign colvalues=0,1024,2048,3072,4096,5120,6144,7168,8192 colunit=rpm desc="The timing change against rpm."
mapsw_ign:              DB  080h, 080h, 080h, 080h, 080h, 080h, 080h, 080h, 080h
endif

if XP == XP_CODE
mapsw_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, mapsw_enable
                CMPB    A, #000h
                JEQ     mapsw_off
                MOV     X1, #mapsw_input
                CAL     mod_mapinput           ; the switch (or the datalog service command)
                JEQ     mapsw_off
                CAL     mod_rpmbyte
                MOV     DP, #mapsw_rpm
                STB     A, [DP]
                MOV     X1, #mapsw_fuel
                CAL     mod_lookup9
                STB     A, r4
                CLR     A
                LB      A, r4
                L       A, ACC
                SUB     A, #00080h
                MOV     DP, #mapsw_ftrim
                CAL     mod_fueltrim
                MOV     DP, #mapsw_rpm
                CLRB    A
                LB      A, [DP]
                MOV     X1, #mapsw_ign
                CAL     mod_lookup9
                STB     A, r4
                CLR     A
                LB      A, r4
                L       A, ACC
                SUB     A, #00080h
                MOV     DP, #mapsw_itrim
                CAL     mod_igntrim
                J       mod_tick_exit
mapsw_off:      CLR     A
                MOV     DP, #mapsw_ftrim
                CAL     mod_fueltrim
                CLR     A
                MOV     DP, #mapsw_itrim
                CAL     mod_igntrim
                J       mod_tick_exit
endif

endif
