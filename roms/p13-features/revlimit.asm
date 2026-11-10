; ==================================================================================================
; revlimit.asm - rev limiter with its own cut and resume points for each cam (HTS "Rev limits" page)
;> feature: FEAT_REVLIMIT
;> name: Rev limiter (ignition or fuel cut, per cam)
;> category: Limits
;> platforms: P13
;> pages: revlimit
;> ram: 1C2h-1C5h (shared cut requests), the rev cap: 2 bytes of module RAM shared by every rev limit (lib.asm)
;> about: A limiter of your own on top of the skeleton's: it cuts at one rpm and lets the engine back in at
;>        a lower one, separately for the low cam and the high cam (VTEC solenoid on), with fuel cut,
;>        ignition cut or both. Ignition cut keeps fuel flowing, the sharper-sounding "pops and bangs"
;>        limiter; fuel cut is kinder to the catalyst. Off until enabled.
; ==================================================================================================
ifdef FEAT_REVLIMIT

if XP == XP_DEFS
ifndef NEED_REVCAP
define NEED_REVCAP                             ; (its rev limit is a hard limit for the crank interrupt too: lib.asm)
endif
ifndef NEED_MODLIB
define NEED_MODLIB
endif
endif

if XP == XP_TICKSLOT
if SLOT_REVLIMIT == TICK_SLOT
                CAL     revlimit_tick
endif
endif

if XP == XP_CAL
;@ RevLimitEnable type=u8 flag=1 on=1 off=0 category="Rev limits" slot=revlimit.enable desc="Use this rev limiter (the skeleton's own stays in place above it)."
revlimit_low:           DB  000h
;@ RevLimitCut type=u8 category="Rev limits" slot=revlimit.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
revlimit_cut:           DB  001h
;@ RevLimitLowSet type=u16 formula=rpm_period_word category="Rev limits" slot=revlimit.low.set desc="Low cam: cut fuel / spark at this rpm."
revlimit_low_set:       DW  000eah               ; 8000 rpm
;@ RevLimitLowReset type=u16 formula=rpm_period_word category="Rev limits" slot=revlimit.low.reset desc="Low cam: back in below this rpm."
revlimit_low_reset:     DW  000efh               ; 7850 rpm
;@ RevLimitHighEnable type=u8 flag=1 on=1 off=0 category="Rev limits" slot=revlimit.high.enable desc="Same switch for the high cam (normally the same as the low cam's)."
revlimit_high:          DB  000h
;@ RevLimitHighCut type=u8 category="Rev limits" slot=revlimit.high.cut desc="High cam: 0 = fuel cut, 1 = ignition cut, 2 = both."
revlimit_high_cut:      DB  001h
;@ RevLimitHighSet type=u16 formula=rpm_period_word category="Rev limits" slot=revlimit.high.set desc="High cam (VTEC engaged): cut fuel / spark at this rpm."
revlimit_high_set:      DW  000d1h               ; 9000 rpm
;@ RevLimitHighReset type=u16 formula=rpm_period_word category="Rev limits" slot=revlimit.high.reset desc="High cam: back in below this rpm."
revlimit_high_reset:    DW  000d5h               ; 8800 rpm
endif

if XP == XP_CODE
revlimit_tick:  PUSHS   LRB
                MOV     LRB, #SVC_BANKT
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                MOV     X1, #revlimit_low      ; the low cam's block...
                MOV     DP, #0021dh            ; ...unless the high cam is on (P13: 21Dh.1)
                MB      C, [DP].1
                JGE     revlimit_go
                MOV     X1, #revlimit_high
revlimit_go:    L       A, #MB_REVLIMIT
                SC                             ; no condition beyond the rpm
                CAL     mod_limit
                J       mod_tick_exit
endif

endif
