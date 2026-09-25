; ==================================================================================================
; p30-features/features.inc - the feature modules for roms/p30-skeleton.asm.
;
; p30-skeleton.asm includes this file at each of its extension points, with XP set to the point
; (XP_DEFS, XP_BOOT, XP_MAIN, XP_FUEL, XP_IGN, XP_TICK, XP_OUT, XP_CAL, XP_CODE). Every module
; below is wrapped in "ifdef FEAT_<name>" and assembles only its part for the current point, so
; a build with no FEAT_ defined is the bare skeleton, and modules can be added in any order and
; any combination. The assembler places the code and the tables, so modules never overlap; when
; the ROM is full the build stops with an error.
;
; Writing a module: see README.md in this folder.
; ==================================================================================================

if XP == XP_DEFS
; ---------------------------------------------------------------------------------------------------
; RAM. The skeleton and stock P30 never touch these, whichever stock functions are built back in,
; so each module owns its bytes outright and any mix of modules is safe.
;
;   0FBh        module RAM (page zero: direct from any context)
;   0FCh        service: spark-cut request, any bit set = no spark (NEED_SPARKCUT)
;   0FDh        module RAM (page zero)
;   0FEh-0FFh   service: tick, +1 every 2.048 ms (read only)
;   1F0h        service: fuel-cut request, any bit set = no fuel
;   1F1h-1FFh   module RAM
;   2FDh        service: ignition retard request (0.25 deg steps)
;   2FEh-2FFh   module RAM
;   374h-37Eh   datalog (RAM of the stock serial link; the two cannot be built together)
;   3DCh-3DFh   service: output overrides (NEED_OUTPORT)
;   3E0h-3EFh   datalog channel list
;   3F0h-3F9h   module RAM
;
; Bits of the shared request bytes (fuel cut 1F0h, spark cut 0FCh), one per module:
FC_LAUNCH       EQU     0       ; launch control / full-throttle shift / burnout
FC_REVLIMIT     EQU     1       ; ignition-cut rev limiter, rpm ceilings, ECT protection
FC_BOOSTCUT     EQU     2       ; boost cut
FC_SPEEDLIMIT   EQU     3       ; speed limiter by switch
FC_LEANPRO      EQU     4       ; lean protection
FC_ANTISTART    EQU     5       ; anti-start
FC_TRACTION     EQU     6       ; traction control
FC_SPARE        EQU     7
; ---------------------------------------------------------------------------------------------------
; Modules that cannot be built together
if defined(FEAT_DATALOG) && defined(FEAT_STOCK_SERIAL)
                error   "FEAT_DATALOG and FEAT_STOCK_SERIAL both need the serial port: pick one"
endif
endif

include "shiftlight.asm"
