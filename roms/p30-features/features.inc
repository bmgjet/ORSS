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
;   0FBh        rolling idle: events to the next one left out (page zero: direct from any context)
;   0FCh        service: spark-cut request, any bit set = no spark (NEED_SPARKCUT); bit 0 is lib.asm's, bit 1 rolling idle's
;   0FDh        module flags (page zero, bit-addressable from anywhere): 0 secondary maps on, 2 anti-stall on,
;               3 rolling idle skips injectors, 4 rolling idle skips sparks
;   0FEh-0FFh   service: tick, +1 every 2.048 ms (read only)
;   1F0h        service: fuel-cut request, any bit set = no fuel; bit 0 is lib.asm's
;   1F1h-1F6h   lib.asm (NEED_MODLIB): output states, the fuel and spark want words, flags
;   1F7h        datalog service commands: the lamp taken, clear the codes (dlservice.asm)
;   1F8h-1FFh   bank 3Fh: scratch for tick modules (nothing kept between calls)
;   2F7h        maps indexing: the load the maps were looked up on (FEAT_ALPHAN)
;   2F8h-2F9h   ignition cut modifier: phase and ticks left (FEAT_IGNCUTMOD)
;   2FCh        service: ignition advance request (0.25 deg steps)
;   2FDh        service: ignition retard request (0.25 deg steps)
;   2FEh        module RAM (the gear, FEAT_GEAR)
;   2FFh        datalog service commands: their state (dlservice.asm)
;   374h-37Eh   datalog (RAM of the stock serial link; the two cannot be built together)
;   3DCh-3DFh   service: output overrides (NEED_OUTPORT)
;   3E0h-3EFh   datalog channel list
;   3F0h-3F7h   bank 7Eh: scratch for the fuel hook (lib.asm)
;   module RAM  lib.asm's first 10 bytes, then each module takes its share from MODRAM_NEXT:
;               31Ah-351h without the stock trouble-code function (FEAT_STOCK_DTC), whose RAM it is and which
;               nothing else touches; 3F8h-42Fh with it built in
;
; Limiters do not share bits of 1F0h / 0FCh: each has its own bit in lib.asm's want words (MB_...), and
; lib.asm folds them into bit 0 of each request. See README.md.
; Module RAM. Stock P30 keeps 3D7h-47Fh for the system stack, and with interrupts nesting deep at high rpm
; (the crank task inside itself, then spark, idle valve, road speed and the tick) the stack can reach well
; into it. So module RAM goes where the stack never is: the trouble-code function's RAM, 31Ah-351h, free
; whenever that function is not built (nothing else in the ROM touches it but the power-up clear). With
; FEAT_STOCK_DTC built in there is nowhere else: module RAM stays at 3F8h-42Fh and the build says so.
if defined(FEAT_STOCK_DTC)
MOD_RAM_BASE    EQU     003f8h
MOD_RAM_END     EQU     00430h          ; (the top of module RAM: the stack is not far above)
else
MOD_RAM_BASE    EQU     0031ah
MOD_RAM_END     EQU     00352h
endif
; the next free byte of module RAM (see README.md: a module takes its bytes and moves this on); lib.asm has
; the first 10
define MODRAM_NEXT (MOD_RAM_BASE + 10)
; ---------------------------------------------------------------------------------------------------
; The datalog's parts share the serial link (datalog.asm, NEED_DATALOG): any of them brings it in
if defined(FEAT_DATALOG) || defined(FEAT_DLSTREAM) || defined(FEAT_DLQD3) || defined(FEAT_DLSERVICE)
ifndef NEED_DATALOG
define NEED_DATALOG
endif
endif
; Modules that cannot be built together
if defined(NEED_DATALOG) && defined(FEAT_STOCK_SERIAL)
                error   "the datalog modules and FEAT_STOCK_SERIAL both need the serial port: pick one"
endif
if defined(FEAT_MAPSWITCH) && defined(FEAT_DUALMAPS)
                error   "the secondary tune (FEAT_MAPSWITCH) and the secondary maps (FEAT_DUALMAPS) are two ways of doing one thing, on the same page rows: pick one"
endif
if defined(FEAT_DATALOG) && defined(FEAT_DLQD3)
                error   "the HTS / ISR frame (FEAT_DATALOG) and the QD3 frame (FEAT_DLQD3) are two protocols on the one port: pick one"
endif
endif

include "shiftlight.asm"
include "datalog.asm"
include "dlstream.asm"
include "dlqd3.asm"
include "revlimit.asm"
include "launch.asm"
include "fts.asm"
include "burnout.asm"
include "boostcut.asm"
include "ectpro.asm"
include "antistart.asm"
include "speedlimit.asm"
include "ceiling.asm"
include "iab.asm"
include "rpmswitch.asm"
include "warnlamp.asm"
include "gear.asm"
include "ebc.asm"
include "boostmanual.asm"
include "gio1.asm"
include "gio2.asm"
include "gio3.asm"
include "gio4.asm"
include "leanpro.asm"
include "wbcl.asm"
include "flexfuel.asm"
include "fueltrim.asm"
include "gearfuel.asm"
include "gearign.asm"
include "tpsretard.asm"
include "traction.asm"
include "vtecctl.asm"
include "mapswitch.asm"
include "tach.asm"
include "gearlimit.asm"
include "extmaps.asm"
include "dualmaps.asm"
include "watermark.asm"
include "cfgoverride.asm"
include "smartalt.asm"
include "accut.asm"
include "antistall.asm"
include "wmi.asm"
include "rollidle.asm"
include "cyltrim.asm"
include "alphan.asm"
include "tpscal.asm"
include "speedcorr.asm"
; after the limiters: it shapes the spark cut they ask for
include "igncutmod.asm"
; after igncutmod.asm: a timing locked for service wins over a static cut timing
include "dlservice.asm"
; last: the modules above ask for it in their XP_DEFS part
include "lib.asm"
