; p30-build.asm - an example build of the P30 skeleton with features.
;
; Uncomment the features you want, then assemble this file (not p30-skeleton.asm). With every
; line commented out it builds the bare skeleton. See roms/p30-skeleton.md for what each one does.
; Any mix works: the assembler places the code, and stops with an error if the ROM is full.

; ---- stock P30 functions the skeleton removed
;define FEAT_STOCK_SERIAL
;define FEAT_STOCK_DTC
;define FEAT_STOCK_O2
;define FEAT_STOCK_O2HEATER
;define FEAT_STOCK_EGR
;define FEAT_STOCK_KNOCK
;define FEAT_STOCK_VTECPRESSURE
;define FEAT_STOCK_SPEEDLIMIT
;define FEAT_STOCK_HICAMVE
;define FEAT_STOCK_AT
;define FEAT_STOCK_PURGE
;define FEAT_STOCK_AC
;define FEAT_STOCK_SELFTEST

include "p30-skeleton.asm"
