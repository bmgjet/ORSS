; ==================================================================================================
; fueltrim.asm - injector size scaling and a global fuel trim (HTS "Injectors" page)
;> feature: FEAT_FUELTRIM
;> name: Injector size and fuel trim
;> category: Fuel
;> pages: injector
;> ram: module RAM (2 bytes)
;> about: Scales every pulse width for injectors of a different size (the size the calibration was
;>        written for against the size fitted) and adds a trim of its own, so a change of injectors or
;>        fuel is one setting instead of a new VE map. Off until enabled.
; ==================================================================================================
ifdef FEAT_FUELTRIM

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_FUELTRIM
define NEED_FUELTRIM
endif
fueltrim_value      EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (fueltrim_value + 2)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_FUELTRIM
                JNE     fueltrim_tick_skip
                CAL     fueltrim_tick
fueltrim_tick_skip:
endif

if XP == XP_CAL
;@ InjectorScaling type=u8 flag=1 on=1 off=0 category="Injectors" slot=injector.enable desc="Scale the fuel for injectors of a different size (and add the trim). Off leaves the fuel maps as they are - it never switches the injectors off."
fueltrim_enable:        DB  000h
;@ InjectorStock type=u16 formula=x unit=cc decimals=0 min=50 max=3000 category="Injectors" slot=injector.stock desc="The injectors the fuel maps were written for (cc/min). The scaling is held to between half and double the fuel."
fueltrim_stock:         DW  000f0h               ; 240 cc
;@ InjectorFitted type=u16 formula=x unit=cc decimals=0 min=50 max=3000 category="Injectors" slot=injector.fitted desc="The injectors fitted (cc/min)."
fueltrim_fitted:        DW  000f0h
;@ InjectorTrim type=u8 formula=(x-128)*100/256 unit=% decimals=1 category="Injectors" slot=injector.trim desc="A trim on top, either way."
fueltrim_trim:          DB  080h
endif

if XP == XP_CODE
fueltrim_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, fueltrim_enable
                CMPB    A, #000h
                JEQ     fueltrim_off
                LC      A, fueltrim_fitted     ; stock x 256 / fitted
                L       A, ACC
                JEQ     fueltrim_off
                ST      A, er2
                MOV     er0, #00100h
                LC      A, fueltrim_stock
                L       A, ACC
                JEQ     fueltrim_off           ; no size set: leave the fuel alone (0 would take it all away)
                MUL
                MOV     er0, er1
                DIV
                SUB     A, #00100h             ; the change, in 1/256ths
                ST      A, er3
                CLR     A
                LCB     A, fueltrim_trim       ; plus the trim (centred on 80h)
                SUB     A, #00080h
                ADD     A, er3
                SJ      fueltrim_set
fueltrim_off:   CLR     A
fueltrim_set:   MOV     DP, #fueltrim_value
                CAL     mod_fueltrim
                J       mod_tick_exit
endif

endif
