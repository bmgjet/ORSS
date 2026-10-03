; ==================================================================================================
; buildinfo.asm - which functions this ROM was built with (always built in)
;
; A short table in the free space: "OKF" and its version (01h), then one byte for each function built
; in - its number below - and 00h. A .bin saved from the ROM carries it, so File > Change functions...
; can tell what to rebuild it from and carry its tune across. Numbers are never changed or reused: a
; new function takes the next one. 5 bytes, and one more for each function.
; ==================================================================================================
if XP == XP_CAL
skel_buildinfo: DB      04fh, 04bh, 046h, 001h
if defined(FEAT_STOCK_SERIAL)
                DB      001h
endif
if defined(FEAT_STOCK_DTC)
                DB      002h
endif
if defined(FEAT_STOCK_O2)
                DB      003h
endif
if defined(FEAT_STOCK_O2HEATER)
                DB      004h
endif
if defined(FEAT_STOCK_EGR)
                DB      005h
endif
if defined(FEAT_STOCK_KNOCK)
                DB      006h
endif
if defined(FEAT_STOCK_VTECPRESSURE)
                DB      007h
endif
if defined(FEAT_STOCK_SPEEDLIMIT)
                DB      008h
endif
if defined(FEAT_STOCK_HICAMVE)
                DB      009h
endif
if defined(FEAT_STOCK_AT)
                DB      00Ah
endif
if defined(FEAT_STOCK_PURGE)
                DB      00Bh
endif
if defined(FEAT_STOCK_AC)
                DB      00Ch
endif
if defined(FEAT_STOCK_SELFTEST)
                DB      00Dh
endif
if defined(FEAT_ACCUT)
                DB      00Eh
endif
if defined(FEAT_ALPHAN)
                DB      00Fh
endif
if defined(FEAT_ANTISTALL)
                DB      010h
endif
if defined(FEAT_ANTISTART)
                DB      011h
endif
if defined(FEAT_BOOSTCUT)
                DB      012h
endif
if defined(FEAT_BOOSTMANUAL)
                DB      013h
endif
if defined(FEAT_BURNOUT)
                DB      014h
endif
if defined(FEAT_CEILING)
                DB      015h
endif
if defined(FEAT_CFGOVERRIDE)
                DB      016h
endif
if defined(FEAT_CYLTRIM)
                DB      017h
endif
if defined(FEAT_DATALOG)
                DB      018h
endif
if defined(FEAT_DLMEMREAD)
                DB      019h
endif
if defined(FEAT_DLQD3)
                DB      01Ah
endif
if defined(FEAT_DLSERIALIN)
                DB      01Bh
endif
if defined(FEAT_DLSERVICE)
                DB      01Ch
endif
if defined(FEAT_DLSTREAM)
                DB      01Dh
endif
if defined(FEAT_DUALMAPS)
                DB      01Eh
endif
if defined(FEAT_EBC)
                DB      01Fh
endif
if defined(FEAT_ECTPRO)
                DB      020h
endif
if defined(FEAT_EXTMAPS)
                DB      021h
endif
if defined(FEAT_FLEX)
                DB      022h
endif
if defined(FEAT_FTS)
                DB      023h
endif
if defined(FEAT_FUELTRIM)
                DB      024h
endif
if defined(FEAT_GEAR)
                DB      025h
endif
if defined(FEAT_GEARFUEL)
                DB      026h
endif
if defined(FEAT_GEARIGN)
                DB      027h
endif
if defined(FEAT_GEARLIMIT)
                DB      028h
endif
if defined(FEAT_GIO1)
                DB      029h
endif
if defined(FEAT_GIO2)
                DB      02Ah
endif
if defined(FEAT_GIO3)
                DB      02Bh
endif
if defined(FEAT_GIO4)
                DB      02Ch
endif
if defined(FEAT_IAB)
                DB      02Dh
endif
if defined(FEAT_IGNCUTMOD)
                DB      02Eh
endif
if defined(FEAT_LAUNCH)
                DB      02Fh
endif
if defined(FEAT_LEANPRO)
                DB      030h
endif
if defined(FEAT_MAPSWITCH)
                DB      031h
endif
if defined(FEAT_REVLIMIT)
                DB      032h
endif
if defined(FEAT_ROLLIDLE)
                DB      033h
endif
if defined(FEAT_RPMSWITCH)
                DB      034h
endif
if defined(FEAT_SHIFTLIGHT)
                DB      035h
endif
if defined(FEAT_SMARTALT)
                DB      036h
endif
if defined(FEAT_SPEEDCORR)
                DB      037h
endif
if defined(FEAT_SPEEDLIMIT)
                DB      038h
endif
if defined(FEAT_TACH)
                DB      039h
endif
if defined(FEAT_TPSCAL)
                DB      03Ah
endif
if defined(FEAT_TPSRETARD)
                DB      03Bh
endif
if defined(FEAT_TRACTION)
                DB      03Ch
endif
if defined(FEAT_VTECCTL)
                DB      03Dh
endif
if defined(FEAT_WARNLAMP)
                DB      03Eh
endif
if defined(FEAT_WATERMARK)
                DB      03Fh
endif
if defined(FEAT_WBCL)
                DB      040h
endif
if defined(FEAT_WMI)
                DB      041h
endif
if defined(FEAT_DLEXTRA)
                DB      042h
endif
                DB      000h
endif
