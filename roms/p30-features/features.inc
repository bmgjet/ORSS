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
;   392h-39Ah   datalog serial inputs, when FEAT_STOCK_DTC (whose own RAM it is) is not built; module RAM when it is
;   3DCh-3DFh   service: output overrides (NEED_OUTPORT)
;   3E0h-3EFh   datalog channel list (or the stream's two channel masks)
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
; Tick slots. A module's tick code runs on one tick in 16 (its slot), about 30 times a second, and a slot
; that holds several modules makes that tick long: the tick is the timer 1 interrupt, which keeps every
; other interrupt waiting while it runs. On the car a tick over about 330 us made the ECU hard to start
; (every output strobing), whatever mix of modules was in. So the modules that are built take slots in
; turn, the heaviest first (measured, worst run in us, in the order below), and the slots are dealt out
; back and forth (0..15, 15..0, 0..15): the heaviest ones have a slot each, the light ones share.
; A new module goes in this list where its cost puts it.
define TICKSLOT_N 0
if defined(FEAT_FLEX)
TS_FLEX         EQU     TICKSLOT_N
SLOT_FLEX       EQU     ((TS_FLEX & 15) + ((TS_FLEX >> 4) & 1) * (15 - 2 * (TS_FLEX & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_FLEX + 1)
endif
if defined(FEAT_FTS)
TS_FTS          EQU     TICKSLOT_N
SLOT_FTS        EQU     ((TS_FTS & 15) + ((TS_FTS >> 4) & 1) * (15 - 2 * (TS_FTS & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_FTS + 1)
endif
if defined(FEAT_LAUNCH)
TS_LAUNCH       EQU     TICKSLOT_N
SLOT_LAUNCH     EQU     ((TS_LAUNCH & 15) + ((TS_LAUNCH >> 4) & 1) * (15 - 2 * (TS_LAUNCH & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_LAUNCH + 1)
endif
if defined(FEAT_BURNOUT)
TS_BURNOUT      EQU     TICKSLOT_N
SLOT_BURNOUT    EQU     ((TS_BURNOUT & 15) + ((TS_BURNOUT >> 4) & 1) * (15 - 2 * (TS_BURNOUT & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_BURNOUT + 1)
endif
if defined(FEAT_MAPSWITCH)
TS_MAPSWITCH    EQU     TICKSLOT_N
SLOT_MAPSWITCH  EQU     ((TS_MAPSWITCH & 15) + ((TS_MAPSWITCH >> 4) & 1) * (15 - 2 * (TS_MAPSWITCH & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_MAPSWITCH + 1)
endif
if defined(FEAT_RPMSWITCH)
TS_RPMSWITCH    EQU     TICKSLOT_N
SLOT_RPMSWITCH  EQU     ((TS_RPMSWITCH & 15) + ((TS_RPMSWITCH >> 4) & 1) * (15 - 2 * (TS_RPMSWITCH & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_RPMSWITCH + 1)
endif
if defined(FEAT_TPSRETARD)
TS_TPSRETARD    EQU     TICKSLOT_N
SLOT_TPSRETARD  EQU     ((TS_TPSRETARD & 15) + ((TS_TPSRETARD >> 4) & 1) * (15 - 2 * (TS_TPSRETARD & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_TPSRETARD + 1)
endif
if defined(FEAT_WARNLAMP)
TS_WARNLAMP     EQU     TICKSLOT_N
SLOT_WARNLAMP   EQU     ((TS_WARNLAMP & 15) + ((TS_WARNLAMP >> 4) & 1) * (15 - 2 * (TS_WARNLAMP & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_WARNLAMP + 1)
endif
if defined(FEAT_IAB)
TS_IAB          EQU     TICKSLOT_N
SLOT_IAB        EQU     ((TS_IAB & 15) + ((TS_IAB >> 4) & 1) * (15 - 2 * (TS_IAB & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_IAB + 1)
endif
if defined(FEAT_TRACTION)
TS_TRACTION     EQU     TICKSLOT_N
SLOT_TRACTION   EQU     ((TS_TRACTION & 15) + ((TS_TRACTION >> 4) & 1) * (15 - 2 * (TS_TRACTION & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_TRACTION + 1)
endif
if defined(FEAT_ANTISTALL)
TS_ANTISTALL    EQU     TICKSLOT_N
SLOT_ANTISTALL  EQU     ((TS_ANTISTALL & 15) + ((TS_ANTISTALL >> 4) & 1) * (15 - 2 * (TS_ANTISTALL & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_ANTISTALL + 1)
endif
if defined(FEAT_ECTPRO)
TS_ECTPRO       EQU     TICKSLOT_N
SLOT_ECTPRO     EQU     ((TS_ECTPRO & 15) + ((TS_ECTPRO >> 4) & 1) * (15 - 2 * (TS_ECTPRO & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_ECTPRO + 1)
endif
if defined(FEAT_REVLIMIT)
TS_REVLIMIT     EQU     TICKSLOT_N
SLOT_REVLIMIT   EQU     ((TS_REVLIMIT & 15) + ((TS_REVLIMIT >> 4) & 1) * (15 - 2 * (TS_REVLIMIT & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_REVLIMIT + 1)
endif
if defined(FEAT_ANTISTART)
TS_ANTISTART    EQU     TICKSLOT_N
SLOT_ANTISTART  EQU     ((TS_ANTISTART & 15) + ((TS_ANTISTART >> 4) & 1) * (15 - 2 * (TS_ANTISTART & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_ANTISTART + 1)
endif
if defined(FEAT_BOOSTCUT)
TS_BOOSTCUT     EQU     TICKSLOT_N
SLOT_BOOSTCUT   EQU     ((TS_BOOSTCUT & 15) + ((TS_BOOSTCUT >> 4) & 1) * (15 - 2 * (TS_BOOSTCUT & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_BOOSTCUT + 1)
endif
if defined(FEAT_CEILING)
TS_CEILING      EQU     TICKSLOT_N
SLOT_CEILING    EQU     ((TS_CEILING & 15) + ((TS_CEILING >> 4) & 1) * (15 - 2 * (TS_CEILING & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_CEILING + 1)
endif
if defined(FEAT_LEANPRO)
TS_LEANPRO      EQU     TICKSLOT_N
SLOT_LEANPRO    EQU     ((TS_LEANPRO & 15) + ((TS_LEANPRO >> 4) & 1) * (15 - 2 * (TS_LEANPRO & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_LEANPRO + 1)
endif
if defined(FEAT_SPEEDLIMIT)
TS_SPEEDLIMIT   EQU     TICKSLOT_N
SLOT_SPEEDLIMIT EQU     ((TS_SPEEDLIMIT & 15) + ((TS_SPEEDLIMIT >> 4) & 1) * (15 - 2 * (TS_SPEEDLIMIT & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_SPEEDLIMIT + 1)
endif
if defined(FEAT_FUELTRIM)
TS_FUELTRIM     EQU     TICKSLOT_N
SLOT_FUELTRIM   EQU     ((TS_FUELTRIM & 15) + ((TS_FUELTRIM >> 4) & 1) * (15 - 2 * (TS_FUELTRIM & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_FUELTRIM + 1)
endif
if defined(FEAT_WBCL)
TS_WBCL         EQU     TICKSLOT_N
SLOT_WBCL       EQU     ((TS_WBCL & 15) + ((TS_WBCL >> 4) & 1) * (15 - 2 * (TS_WBCL & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_WBCL + 1)
endif
if defined(FEAT_WMI)
TS_WMI          EQU     TICKSLOT_N
SLOT_WMI        EQU     ((TS_WMI & 15) + ((TS_WMI >> 4) & 1) * (15 - 2 * (TS_WMI & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_WMI + 1)
endif
if defined(FEAT_EBC) || defined(FEAT_BOOSTMANUAL)
TS_EBC          EQU     TICKSLOT_N
SLOT_EBC        EQU     ((TS_EBC & 15) + ((TS_EBC >> 4) & 1) * (15 - 2 * (TS_EBC & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_EBC + 1)
endif
if defined(FEAT_ROLLIDLE)
TS_ROLLIDLE     EQU     TICKSLOT_N
SLOT_ROLLIDLE   EQU     ((TS_ROLLIDLE & 15) + ((TS_ROLLIDLE >> 4) & 1) * (15 - 2 * (TS_ROLLIDLE & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_ROLLIDLE + 1)
endif
if defined(FEAT_GIO1)
TS_GIO1         EQU     TICKSLOT_N
SLOT_GIO1       EQU     ((TS_GIO1 & 15) + ((TS_GIO1 >> 4) & 1) * (15 - 2 * (TS_GIO1 & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_GIO1 + 1)
endif
if defined(FEAT_GIO2)
TS_GIO2         EQU     TICKSLOT_N
SLOT_GIO2       EQU     ((TS_GIO2 & 15) + ((TS_GIO2 >> 4) & 1) * (15 - 2 * (TS_GIO2 & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_GIO2 + 1)
endif
if defined(FEAT_GIO3)
TS_GIO3         EQU     TICKSLOT_N
SLOT_GIO3       EQU     ((TS_GIO3 & 15) + ((TS_GIO3 >> 4) & 1) * (15 - 2 * (TS_GIO3 & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_GIO3 + 1)
endif
if defined(FEAT_GIO4)
TS_GIO4         EQU     TICKSLOT_N
SLOT_GIO4       EQU     ((TS_GIO4 & 15) + ((TS_GIO4 >> 4) & 1) * (15 - 2 * (TS_GIO4 & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_GIO4 + 1)
endif
if defined(FEAT_GEAR)
TS_GEAR         EQU     TICKSLOT_N
SLOT_GEAR       EQU     ((TS_GEAR & 15) + ((TS_GEAR >> 4) & 1) * (15 - 2 * (TS_GEAR & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_GEAR + 1)
endif
if defined(FEAT_GEARLIMIT)
TS_GEARLIMIT    EQU     TICKSLOT_N
SLOT_GEARLIMIT  EQU     ((TS_GEARLIMIT & 15) + ((TS_GEARLIMIT >> 4) & 1) * (15 - 2 * (TS_GEARLIMIT & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_GEARLIMIT + 1)
endif
if defined(FEAT_GEARIGN)
TS_GEARIGN      EQU     TICKSLOT_N
SLOT_GEARIGN    EQU     ((TS_GEARIGN & 15) + ((TS_GEARIGN >> 4) & 1) * (15 - 2 * (TS_GEARIGN & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_GEARIGN + 1)
endif
if defined(FEAT_GEARFUEL)
TS_GEARFUEL     EQU     TICKSLOT_N
SLOT_GEARFUEL   EQU     ((TS_GEARFUEL & 15) + ((TS_GEARFUEL >> 4) & 1) * (15 - 2 * (TS_GEARFUEL & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_GEARFUEL + 1)
endif
if defined(FEAT_DUALMAPS)
TS_DUALMAPS     EQU     TICKSLOT_N
SLOT_DUALMAPS   EQU     ((TS_DUALMAPS & 15) + ((TS_DUALMAPS >> 4) & 1) * (15 - 2 * (TS_DUALMAPS & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_DUALMAPS + 1)
endif
if defined(FEAT_ACCUT)
TS_ACCUT        EQU     TICKSLOT_N
SLOT_ACCUT      EQU     ((TS_ACCUT & 15) + ((TS_ACCUT >> 4) & 1) * (15 - 2 * (TS_ACCUT & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_ACCUT + 1)
endif
if defined(FEAT_SMARTALT)
TS_SMARTALT     EQU     TICKSLOT_N
SLOT_SMARTALT   EQU     ((TS_SMARTALT & 15) + ((TS_SMARTALT >> 4) & 1) * (15 - 2 * (TS_SMARTALT & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_SMARTALT + 1)
endif
if defined(FEAT_DLSERIALIN)
TS_DLSERIALIN   EQU     TICKSLOT_N
SLOT_DLSERIALIN EQU     ((TS_DLSERIALIN & 15) + ((TS_DLSERIALIN >> 4) & 1) * (15 - 2 * (TS_DLSERIALIN & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_DLSERIALIN + 1)
endif
if defined(FEAT_DLSERVICE)
TS_DLSERVICE    EQU     TICKSLOT_N
SLOT_DLSERVICE  EQU     ((TS_DLSERVICE & 15) + ((TS_DLSERVICE >> 4) & 1) * (15 - 2 * (TS_DLSERVICE & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_DLSERVICE + 1)
endif
; (VTEC control last: it came after the others were laid out, and taking a slot in the middle would move theirs)
if defined(FEAT_VTECCTL)
TS_VTECCTL      EQU     TICKSLOT_N
SLOT_VTECCTL    EQU     ((TS_VTECCTL & 15) + ((TS_VTECCTL >> 4) & 1) * (15 - 2 * (TS_VTECCTL & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_VTECCTL + 1)
endif
; how many modules hold a tick slot (the tick time the advice reports comes from it)
TICK_MODULES    EQU     TICKSLOT_N
; ---------------------------------------------------------------------------------------------------
; The datalog's parts share the serial link (datalog.asm, NEED_DATALOG): any of them brings it in
if defined(FEAT_DATALOG) || defined(FEAT_DLSTREAM) || defined(FEAT_DLQD3) || defined(FEAT_DLSERVICE) || defined(FEAT_DLSERIALIN) || defined(FEAT_DLMEMREAD)
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
include "dlserialin.asm"
include "dlmemread.asm"
include "dlextra.asm"
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
; a diagnostic that lengthens the tick when TICKBURN_US is defined (not a module)
include "tickburn.asm"
; a diagnostic that flashes one output when OUTTEST is defined (not a module)
include "outtest.asm"
; last: the modules above ask for it in their XP_DEFS part
include "buildinfo.asm"
include "lib.asm"
