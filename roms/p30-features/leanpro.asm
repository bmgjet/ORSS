; ==================================================================================================
; leanpro.asm - lean protection on a wideband (HTS "Lean protection" page)
;> feature: FEAT_LEANPRO
;> name: Lean protection
;> category: Protection
;> pages: leanpro
;> ram: module RAM (1 byte), 1F2h-1F5h (shared cut requests)
;> about: Watches a wideband O2 controller on an analog input and cuts the engine when it runs lean
;>        under load: leaner than a set AFR, with manifold pressure and rpm above set points, for longer
;>        than a delay. It stays cut until the pressure falls back, so a lean pull on boost ends at once
;>        instead of melting a piston. Off until enabled.
; ==================================================================================================
ifdef FEAT_LEANPRO

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
leanpro_count       EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (leanpro_count + 1)
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_LEANPRO
                JNE     leanpro_tick_skip
                CAL     leanpro_tick
leanpro_tick_skip:
endif

if XP == XP_CAL
;@ LeanProEnable type=u8 flag=1 on=1 off=0 category="Lean protection" slot=leanpro.enable desc="Lean protection on."
leanpro_block:          DB  000h
;@ LeanProCut type=u8 category="Lean protection" slot=leanpro.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
leanpro_cut:            DB  002h
;@ LeanProInput type=u8 category="Lean protection" slot=leanpro.input desc="The wideband's analog output on: 0 O2 (D14), 1 ELD (D10), 2 EGR (D12), 3 B6."
leanpro_input:          DB  000h
;@ LeanProAFR0 type=u8 formula=x/10 unit=AFR decimals=1 category="Lean protection" slot=leanpro.afr0 desc="The AFR the wideband reports at 0 V."
leanpro_afr0:           DB  064h                 ; 10.0
;@ LeanProAFR5 type=u8 formula=x/10 unit=AFR decimals=1 category="Lean protection" slot=leanpro.afr5 desc="The AFR it reports at 5 V."
leanpro_afr5:           DB  0c8h                 ; 20.0
;@ LeanProAFR type=u8 formula=x/10 unit=AFR decimals=1 category="Lean protection" slot=leanpro.afr desc="Leaner than this counts as lean."
leanpro_afr:            DB  08ch                 ; 14.0
;@ LeanProMAP type=u8 formula=map_mbar category="Lean protection" slot=leanpro.map desc="Only above this manifold pressure."
leanpro_map:            DB  09dh                 ; 1075 mbar
;@ LeanProRPM type=u16 formula=rpm_period_word category="Lean protection" slot=leanpro.rpm desc="Only above this rpm."
leanpro_rpm:            DW  00271h               ; 3000 rpm
;@ LeanProDelay type=u8 formula=x*32 unit=ms decimals=0 category="Lean protection" slot=leanpro.delay desc="Lean for this long before it cuts."
leanpro_delay:          DB  008h                 ; 256 ms
endif

if XP == XP_CODE
leanpro_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, leanpro_block
                CMPB    A, #000h
                JEQ     leanpro_release
                L       A, off(MOD_FUELWANT)   ; cut already: until the pressure falls back
                OR      A, off(MOD_SPARKWANT)
                AND     A, #MB_LEANPRO
                JEQ     leanpro_watch
                CLRB    A
                LCB     A, leanpro_map
                CMPB    0a3h, A
                JLT     leanpro_release
                SJ      leanpro_do_cut
leanpro_watch:  CLRB    A
                LCB     A, leanpro_map         ; under load?
                CMPB    0a3h, A
                JLT     leanpro_reset
                LC      A, leanpro_rpm
                CMP     0ach, A
                JGT     leanpro_reset
                MOV     X1, #leanpro_input
                CAL     mod_afr                ; lean?
                STB     A, r4
                LCB     A, leanpro_afr
                CMPB    A, r4                  ; limit - AFR borrows while leaner than it
                JGE     leanpro_reset
                MOV     DP, #leanpro_count     ; for long enough?
                LB      A, [DP]
                ADDB    A, #001h
                STB     A, [DP]
                STB     A, r4
                LCB     A, leanpro_delay
                CMPB    A, r4
                JLT     leanpro_do_cut
                JEQ     leanpro_do_cut
                J       mod_tick_exit
leanpro_reset:  MOV     DP, #leanpro_count
                MOVB    [DP], #000h
leanpro_release:
                MOV     X1, #leanpro_block
                L       A, #MB_LEANPRO
                RC
                CAL     mod_cut
                J       mod_tick_exit
leanpro_do_cut: MOV     X1, #leanpro_block
                L       A, #MB_LEANPRO
                SC
                CAL     mod_cut
                J       mod_tick_exit
endif

endif
