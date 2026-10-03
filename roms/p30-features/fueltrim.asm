; ==================================================================================================
; fueltrim.asm - injector size scaling and a global fuel trim (HTS "Injectors" page)
;> feature: FEAT_FUELTRIM
;> name: Injector size and fuel trim
;> category: Fuel
;> pages: injector
;> ram: module RAM (4 bytes)
;> about: Scales every pulse width for injectors of a different size (the size the calibration was
;>        written for against the size fitted) and adds a trim of its own, so a change of injectors or
;>        fuel is one setting instead of a new VE map. Off until enabled.
;
; The size scaling multiplies the fuel - every other module's trims included - and is not one more trim in
; the sum: with injectors twice the size, a +10 % trim (flex fuel, the wideband loop, this module's own) is
; still +10 % of what the engine gets. As one more trim in the sum it would have been +10 % of the fuel for
; the old injectors, +20 % of what was asked for. The dead time is added after the scaling (RAM 13Ch), so a
; bigger injector's pulse is shortened without its opening time.
; ==================================================================================================
ifdef FEAT_FUELTRIM

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_FUELTRIM
define NEED_FUELTRIM
endif
fueltrim_value      EQU     MODRAM_NEXT         ; the trim, with the other modules' (1/256ths)
undef MODRAM_NEXT
define MODRAM_NEXT (fueltrim_value + 2)
fueltrim_scale      EQU     MODRAM_NEXT         ; stock / fitted, 8000h = x 1.0 (0: off)
undef MODRAM_NEXT
define MODRAM_NEXT (fueltrim_scale + 2)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_FUELTRIM
                JNE     fueltrim_tick_skip
                CAL     fueltrim_tick
fueltrim_tick_skip:
endif

if XP == XP_FUEL
                CAL     fueltrim_fuel_apply    ; the injector size, on the final pulse width
endif

if XP == XP_CAL
;@ InjectorScaling type=u8 flag=1 on=1 off=0 category="Injectors" slot=injector.enable desc="Scale the fuel for injectors of a different size (and add the trim). Off leaves the fuel maps as they are - it never switches the injectors off."
fueltrim_enable:        DB  000h
;@ InjectorStock type=u16 formula=x unit=cc decimals=0 min=50 max=3000 category="Injectors" slot=injector.stock desc="The injectors the fuel maps were written for (cc/min). The scaling is held to between 1/16 and double the fuel."
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
                LC      A, fueltrim_fitted     ; the scale: stock x 8000h / fitted
                L       A, ACC
                JEQ     fueltrim_off
                ST      A, er2
                MOV     er0, #08000h
                LC      A, fueltrim_stock
                L       A, ACC
                JEQ     fueltrim_off           ; no size set: leave the fuel alone (0 would take it all away)
                MUL                            ; er1:A = stock x 8000h
                MOV     er0, er1
                DIV                            ; er0:A = that / fitted
                ST      A, er3
                L       A, er0
                JNE     fueltrim_scale_max     ; x 2 or more
                L       A, er3
                CMP     A, #00800h
                JGE     fueltrim_scale_set
                L       A, #00800h             ; held to 1/16 of the fuel (3000 cc for 190 cc maps)...
                SJ      fueltrim_scale_set
fueltrim_scale_max:
                L       A, #0ffffh             ; ...and to double it
fueltrim_scale_set:
                MOV     DP, #fueltrim_scale
                ST      A, [DP]
                CLR     A
                LCB     A, fueltrim_trim       ; the trim goes in with the other modules' trims (centred on 80h)
                SUB     A, #00080h
                SJ      fueltrim_set
fueltrim_off:   MOV     DP, #fueltrim_scale
                CLR     A
                ST      A, [DP]                ; no scaling
fueltrim_set:   MOV     DP, #fueltrim_value
                CAL     mod_fueltrim
                J       mod_tick_exit

; The injector size on the final pulse width (word 146h, before the dead time is added). Crank interrupt:
; works in the scratch bank, as lib's mod_fuel_apply does.
fueltrim_fuel_apply:
                PUSHS   LRB
                MOV     LRB, #0007eh
                L       A, DP
                PUSHS   A
                MOV     DP, #fueltrim_scale
                L       A, [DP]
                JEQ     fueltrim_fuel_done     ; off
                CMP     A, #08000h
                JEQ     fueltrim_fuel_done     ; x 1.0
                ST      A, er0
                MOV     DP, #00146h
                L       A, [DP]
                MUL                            ; er1:A = pulse x scale
                SLL     A                      ; / 8000h
                ROL     er1
                JLT     fueltrim_fuel_max
                L       A, er1
                SJ      fueltrim_fuel_store
fueltrim_fuel_max:
                L       A, #0ffffh
fueltrim_fuel_store:
                ST      A, [DP]
fueltrim_fuel_done:
                POPS    A
                MOV     DP, A
                POPS    LRB
                RT
endif

endif
