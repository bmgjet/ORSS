; ==================================================================================================
; igncutmod.asm - ignition cut time, re-fire, enrichment and static timing (HTS "Rev limit" page)
;> feature: FEAT_IGNCUTMOD
;> name: Ignition cut modifier
;> category: Limits
;> pages: revlimit
;> ram: 2F8h-2F9h, module RAM (2 bytes)
;> about: Shapes every ignition cut the limiters ask for (rev limit, launch, full throttle shift...):
;>        the cut lasts a time (its own for launch and for the shift), then sparks come back for the
;>        re-fire time, and again while the limiter holds. While any ignition cut is wanted it can add
;>        fuel and hold the timing at one value, for the pops and bangs of a two-step. Re-fire 0 keeps
;>        the plain cut. Off until enabled.
; ==================================================================================================
ifdef FEAT_IGNCUTMOD

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_FUELTRIM
define NEED_FUELTRIM
endif
icm_trimword        EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (icm_trimword + 2)
endif

if XP == XP_BOOT
                CAL     icm_init
endif

if XP == XP_TICK
                CAL     icm_tick
endif

if XP == XP_IGN
                CAL     icm_ign
endif

if XP == XP_CAL
;@ IgnCutModEnable type=u8 flag=1 on=1 off=0 category="Ignition cut" slot=revlimit.icmod desc="Shape the ignition cuts."
icm_enable:             DB  000h
;@ IgnCutTime type=u8 formula="x * 2.048" inverse="x / 2.048" unit=ms decimals=0 category="Ignition cut" slot=revlimit.cutdelay desc="How long each cut lasts (rev limit and the rest)."
icm_cut_main:           DB  031h
;@ IgnCutTimeLaunch type=u8 formula="x * 2.048" inverse="x / 2.048" unit=ms decimals=0 category="Ignition cut" slot=revlimit.cutdelay.launch desc="How long each launch cut lasts."
icm_cut_launch:         DB  031h
;@ IgnCutTimeFts type=u8 formula="x * 2.048" inverse="x / 2.048" unit=ms decimals=0 category="Ignition cut" slot=revlimit.cutdelay.fts desc="How long each full throttle shift cut lasts."
icm_cut_fts:            DB  031h
;@ IgnCutRefire type=u8 formula="x * 2.048" inverse="x / 2.048" unit=ms decimals=0 category="Ignition cut" slot=revlimit.refire desc="Sparks back for this long between cuts (0 = a plain cut)."
icm_refire:             DB  000h
;@ IgnCutEnrich type=u8 formula=(x-128)*100/256 unit=% decimals=1 category="Ignition cut" slot=revlimit.icenrich desc="Extra fuel while an ignition cut is wanted."
icm_enrich:             DB  080h
;@ IgnCutStaticOn type=u8 flag=1 on=1 off=0 category="Ignition cut" slot=revlimit.icstatic.on desc="Hold the timing at one value while an ignition cut is wanted."
icm_static_on:          DB  000h
;@ IgnCutStatic type=u8 formula=ign_advance category="Ignition cut" slot=revlimit.icstatic desc="The timing then."
icm_static:             DB  018h
endif

if XP == XP_CODE
; Every tick. lib.asm leaves 0FCh bit 0 (the spark cut) to this: while a limiter wants the spark cut it is
; on for the cut time, off for the re-fire time, and so on.
icm_tick:
                PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                MOV     DP, #MOD_SPARKWANT
                L       A, [DP]
                ST      A, er0                 ; who wants the spark cut
                JEQ     icm_none
                CLRB    A
                LCB     A, icm_enable
                CMPB    A, #000h
                JEQ     icm_cut                ; off: the plain cut
                LCB     A, icm_refire
                CMPB    A, #000h
                JEQ     icm_cut                ; no re-fire: the plain cut
                MOV     DP, #002f9h            ; ticks left in this phase
                LB      A, [DP]
                JEQ     icm_flip
                SUBB    A, #001h
                STB     A, [DP]
                SJ      icm_phase_now
icm_flip:       MOV     DP, #002f8h            ; the phase: 0 cut, 1 re-fire
                LB      A, [DP]
                XORB    A, #001h
                STB     A, [DP]
                CMPB    A, #000h
                JNE     icm_to_fire
                LB      A, r0                  ; into a cut: its time by who asked
                ANDB    A, #002h               ; MB_LAUNCH
                JEQ     icm_notlaunch
                LCB     A, icm_cut_launch
                SJ      icm_settime
icm_notlaunch:  LB      A, r0
                ANDB    A, #004h               ; MB_FTS
                JEQ     icm_main
                LCB     A, icm_cut_fts
                SJ      icm_settime
icm_main:       LCB     A, icm_cut_main
                SJ      icm_settime
icm_to_fire:    LCB     A, icm_refire
icm_settime:    MOV     DP, #002f9h
                STB     A, [DP]
icm_phase_now:  MOV     DP, #002f8h
                LB      A, [DP]
                CMPB    A, #000h
                JNE     icm_fire
icm_cut:        LB      A, 0fch
                ORB     A, #001h
                STB     A, 0fch
                SJ      icm_enrich_on
icm_fire:       LB      A, 0fch
                ANDB    A, #0feh
                STB     A, 0fch
icm_enrich_on:  CLRB    A                      ; extra fuel while any spark cut is wanted
                LCB     A, icm_enable
                CMPB    A, #000h
                JEQ     icm_trim0
                CLR     A
                LCB     A, icm_enrich
                SUB     A, #00080h
                SJ      icm_trim
icm_none:       LB      A, 0fch
                ANDB    A, #0feh
                STB     A, 0fch
                MOV     DP, #002f8h            ; the next cut starts with its cut time
                MOVB    [DP], #001h
                INC     DP
                MOVB    [DP], #000h
icm_trim0:      CLR     A
icm_trim:       ST      A, er3
                MOV     DP, #icm_trimword
                L       A, [DP]
                CMP     A, er3
                JEQ     icm_exit
                L       A, er3
                CAL     mod_fueltrim
icm_exit:       J       mod_tick_exit

icm_init:       L       A, DP
                PUSHS   A
                MOV     DP, #002f8h            ; the first cut starts with its cut time
                MOVB    [DP], #001h
                INC     DP
                MOVB    [DP], #000h
                POPS    A
                MOV     DP, A
                RT

; Every spark calculation (page 2): the static timing while an ignition cut is wanted.
icm_ign:        L       A, DP
                PUSHS   A
                MOV     DP, #MOD_SPARKWANT
                L       A, [DP]
                JEQ     icm_ign_done
                CLRB    A
                LCB     A, icm_enable
                CMPB    A, #000h
                JEQ     icm_ign_done
                LCB     A, icm_static_on
                CMPB    A, #000h
                JEQ     icm_ign_done
                LCB     A, icm_static
                STB     A, off(00246h)
                STB     A, off(00247h)
icm_ign_done:   POPS    A
                MOV     DP, A
                RT
endif

endif
