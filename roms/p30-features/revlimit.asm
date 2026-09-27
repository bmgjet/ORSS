; ==================================================================================================
; revlimit.asm - rev limiter with its own cut and resume points for each cam (HTS "Rev limits" page)
;> feature: FEAT_REVLIMIT
;> name: Rev limiter (ignition or fuel cut, per cam)
;> category: Limits
;> pages: revlimit
;> ram: 1F2h-1F5h (shared cut requests)
;> about: A limiter of your own on top of the skeleton's: it cuts at one rpm and lets the engine back in at
;>        a lower one, separately for the low cam and the high cam (VTEC solenoid on), with fuel cut,
;>        ignition cut or both. Ignition cut keeps fuel flowing, the sharper-sounding "pops and bangs"
;>        limiter; fuel cut is kinder to the catalyst. Off until enabled.
; ==================================================================================================
ifdef FEAT_REVLIMIT

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_REVLIMIT
                JNE     revlimit_tick_skip
                CAL     revlimit_tick
revlimit_tick_skip:
endif

if XP == XP_CAL
;@ RevLimitEnable type=u8 flag=1 on=1 off=0 category="Rev limits" slot=revlimit.enable desc="Use this rev limiter (the skeleton's own stays in place above it)."
revlimit_low:           DB  000h
;@ RevLimitCut type=u8 category="Rev limits" slot=revlimit.cut desc="0 = fuel cut, 1 = ignition cut, 2 = both."
revlimit_cut:           DB  001h
;@ RevLimitLowSet type=u16 formula=rpm_period_word category="Rev limits" slot=revlimit.low.set desc="Low cam: cut at this rpm."
revlimit_low_set:       DW  000eah               ; 8000 rpm
;@ RevLimitLowReset type=u16 formula=rpm_period_word category="Rev limits" slot=revlimit.low.reset desc="Low cam: back in below this rpm."
revlimit_low_reset:     DW  000efh               ; 7850 rpm
;@ RevLimitHighEnable type=u8 flag=1 on=1 off=0 category="Rev limits" slot=revlimit.high.enable desc="Same switch for the high cam (normally the same as the low cam's)."
revlimit_high:          DB  000h
;@ RevLimitHighCut type=u8 category="Rev limits" slot=revlimit.high.cut desc="High cam: 0 = fuel cut, 1 = ignition cut, 2 = both."
revlimit_high_cut:      DB  001h
;@ RevLimitHighSet type=u16 formula=rpm_period_word category="Rev limits" slot=revlimit.high.set desc="High cam: cut at this rpm."
revlimit_high_set:      DW  000d1h               ; 9000 rpm
;@ RevLimitHighReset type=u16 formula=rpm_period_word category="Rev limits" slot=revlimit.high.reset desc="High cam: back in below this rpm."
revlimit_high_reset:    DW  000d5h               ; 8800 rpm
endif

if XP == XP_CODE
revlimit_tick:  PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                MOV     X1, #revlimit_low      ; the low cam's block...
                MB      C, P1.0                ; ...unless the VTEC solenoid is open
                JGE     revlimit_go
                MOV     X1, #revlimit_high
revlimit_go:    L       A, #MB_REVLIMIT
                SC                             ; no condition beyond the rpm
                CAL     mod_limit
                J       mod_tick_exit
endif

endif
