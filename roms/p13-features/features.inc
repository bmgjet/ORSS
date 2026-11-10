; ==================================================================================================
; p13-features/features.inc - the feature modules for roms/p13-skeleton.asm (ported from p30-features).
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
; The ECU's RAM the modules read and write, by name: the P13's (MSM66911). These are the modules of p30-features,
; ported to the P13 skeleton (p13-skeleton.asm): the same names, the P13's addresses and code where it differs.
; NOT TESTED ON A CAR - the simulator only.
; ---- P13 (MSM66911). The sensor bytes are the same kind as the P30's (raw 8-bit readings of the same Honda
;      sensors, the same rpm period) except MAP and the map load, whose scales the app takes from the platform.
PLATFORM_IS_P13 EQU     1               ; (for the app: this build is for the P13 - its MAP and load scales)
ENG_RPMP        EQU     000aeh          ; word: crank period, rpm = 1875000 / period (FFFFh: no reading)
ENG_RPMPREV     EQU     0037ch          ; word: the reading before it
ENG_MAP         EQU     000a5h          ; MAP sensor, raw high byte (P13's own sensor: -70..1790 mbar)
ENG_LOAD        EQU     00288h          ; the load byte the maps are looked up on: (MAP word - 1800h) >> 7 (page 2;
                                        ; the P13's barometric byte, 0E0h, is on the same scale and stands in for it
                                        ; while MAP has a fault)
ENG_TPS         EQU     000abh          ; throttle, raw byte (19h closed, E5h wide open)
ENG_ECT         EQU     000d9h          ; coolant, raw thermistor byte (smoothed)
ENG_IAT         EQU     000d8h          ; intake air, raw thermistor byte (smoothed)
ENG_BATT        EQU     000dch          ; battery, raw byte
ENG_VSS         EQU     000dfh          ; road speed, km/h
SVC_TICK        EQU     000f2h          ; word: the module tick, +1 every 2.048 ms (page 0; 0FEh is the P13's own)
SVC_FUELCUT     EQU     001c0h          ; byte: fuel-cut request, any bit set = no fuel (page 1)
SVC_MODLIB      EQU     001c1h          ; lib.asm's 6 bytes, then the datalog service commands' flags (1C7h)
SVC_BANKT       EQU     00039h          ; register bank 1C8h-1CFh: scratch for tick modules
SVC_FUELPW      EQU     001d0h          ; word: the final pulse width, before the dead time (XP_FUEL may change it; the
                                        ; skeleton's copy of the crank task's own, put back after the hooks)
SVC_IGNADV      EQU     0027ah          ; byte: ignition advance request, advance-byte units (page 2)
SVC_IGNRET      EQU     0027bh          ; byte: ignition retard request, advance-byte units (page 2)
SVC_ADVF        EQU     002b8h          ; the final advance, two bytes the spark timer is built from (page 2)
SVC_BANKF       EQU     00080h          ; register bank 400h-407h: scratch for the fuel hook and mod_output
MOD_ALOAD       EQU     0027eh          ; the load the maps were looked up on (FEAT_ALPHAN; page 2)
ICM_PHASE       EQU     001d6h          ; ignition cut modifier: the phase
ICM_LEFT        EQU     001d7h          ; ignition cut modifier: ticks left
MOD_GEAR        EQU     0027fh          ; the gear, 0 when not known (FEAT_GEAR; page 2)
DL_SVC          EQU     001bdh          ; datalog service commands: their state
SKEL_OVR_P2A    EQU     000f5h          ; output 4, the O2 heater pin (P2A.2, low = on): bit 0 held by a module, bit 1 the pin's level (bit 7: the skeleton's scratch)
SVC_OVR         EQU     003ech          ; output overrides: AND / OR masks, port B then port C (NEED_OUTPORT)
OUT_LAMP_MASK   EQU     003eeh          ; the check-engine lamp's override masks (port C's)...
OUT_LAMP        EQU     008h            ; ...its bit (PC.3)...
OUT_LAMP_COPY   EQU     00226h          ; ...and the stock code's copy of its port
; ---------------------------------------------------------------------------------------------------
; RAM. The skeleton and stock P13 never touch these, whichever stock functions are built back in,
; so each module owns its bytes outright and any mix of modules is safe. (The P30's modules keep the same
; things at the P30's addresses: see p30-features/features.inc. The modules use the names, never the numbers.)
;
;   0F2h-0F3h   service: tick, +1 every 2.048 ms (read only; SVC_TICK - 0FEh-0FFh are the P13's own)
;   0F5h        output 4's hold on the O2 heater pin (SKEL_OVR_P2A)
;   0F9h        the ignition map's load, kept for the 20-column map (FEAT_EXTMAPS)
;   0FAh        the trigger log's TDC / CYP marks (SKEL_TRG)
;   0FBh        rolling idle: events to the next one left out (page zero: direct from any context)
;   0FCh        service: spark-cut request, any bit set = no spark (NEED_SPARKCUT); bit 0 is lib.asm's, bit 1 rolling idle's
;   0FDh        module flags (page zero, bit-addressable from anywhere): 0 secondary maps on, 1 the overrun fuel cut
;               held off, 2 anti-stall on, 3 rolling idle skips injectors, 4 rolling idle skips sparks, 5 nitrous
;               spraying, 6 the crank and TDC hooks wanted (the trigger pattern log, capturing), 7 a datalog byte
;               waiting for the next spark calculation (datalog.asm's byte budget)
;   1BCh        the injectors the cylinder test keeps shut (SKEL_INJ_SHUT)
;   1BDh        datalog service commands: their state (DL_SVC, dlservice.asm)
;   1BEh-1BFh   the over-rev latch's newest period (SKEL_OVR_P)
;   1C0h        service: fuel-cut request, any bit set = no fuel (SVC_FUELCUT); bit 0 is lib.asm's, 6 the modules'
;               rev cap, 7 the skeleton's over-rev latch
;   1C1h-1C6h   lib.asm (NEED_MODLIB, SVC_MODLIB): output states, the fuel and spark want words, flags
;   1C7h        datalog service commands: the lamp taken, clear the codes (dlservice.asm)
;   1C8h-1CFh   bank 39h (SVC_BANKT): scratch for tick modules (nothing kept between calls)
;   1D0h-1D1h   service: the final pulse width before the dead time (SVC_FUELPW, the fuel hook)
;   1D2h-1D5h   the modules' rev cap as a period (SKEL_OVR_C, SKEL_OVR_D)
;   1D6h-1D7h   ignition cut modifier: phase and ticks left (FEAT_IGNCUTMOD)
;   27Ah        service: ignition advance request (advance-byte units, SVC_IGNADV)
;   27Bh        service: ignition retard request (SVC_IGNRET)
;   27Eh        maps indexing: the load the maps were looked up on (FEAT_ALPHAN, MOD_ALOAD)
;   27Fh        the gear (FEAT_GEAR, MOD_GEAR)
;   3AAh-3ADh   datalog: the HTS frame's link RAM (DL_LOW, DL_KEEP)
;   3B0h-3B6h   datalog: bank 76h, the stock diagnostic link's RAM (the two cannot be built together; 3B7h is not free)
;   3ECh-3EFh   service: output overrides, port B's masks then port C's (SVC_OVR, NEED_OUTPORT)
;   400h-407h   bank 80h (SVC_BANKF): scratch for the fuel hook and mod_output (lib.asm)
;   module RAM  408h-43Fh: lib.asm's first 8 bytes, then each module takes its share from MODRAM_NEXT (the datalog
;               channel list, DL_LIST, and the serial inputs' values are here too: 3E0h-3EFh and 3F0h-3FFh, where the
;               P30 keeps them, are not free on the P13)
;
; Limiters do not share bits of 1C0h / 0FCh: each has its own bit in lib.asm's want words (MB_...), and
; lib.asm folds them into bit 0 of each request. See README.md.
; Module RAM: 408h-43Fh. The stack (from 47Fh down) was seen no deeper than 45Bh with the module tick running; the
; stock serial link's own RAM (3F0h-3F8h, 3B0h-3BFh), the RAM test's walk and the register banks are kept clear of
; (p13-skeleton.md, "RAM the skeleton and modules use").
MOD_RAM_BASE    EQU     00408h
MOD_RAM_END     EQU     00440h
; the next free byte of module RAM (see README.md: a module takes its bytes and moves this on); lib.asm has
; the first 8 (the P30 keeps two more empty for its stock self-test, which the P13 has no need of: with them the
; trigger log, the channel stream and a rev limit did not fit together)
MOD_LIB_END     EQU     MOD_RAM_BASE + 8
define MODRAM_NEXT (MOD_RAM_BASE + 8)
; ---------------------------------------------------------------------------------------------------
; Tick slots. A module's tick code runs on one tick in 16 (its slot), about 30 times a second, and a slot
; that holds several modules makes that tick long: the tick is the timer 1 interrupt, which keeps every
; other interrupt waiting while it runs. On the car a tick over about 330 us made the ECU hard to start
; (every output strobing), whatever mix of modules was in. So the modules that are built take slots in
; turn, the heaviest first (measured, worst run in us, in the order below), and the slots are dealt out
; back and forth (0..15, 15..0, 0..15): the heaviest ones have a slot each, the light ones share.
; A new module goes in this list where its cost puts it.
define TICKSLOT_N 0
; the remote control commands: the heaviest (measured 2026-10-07: about 250 us each half), in two halves on two slots
if defined(FEAT_REMOTE)
TS_REMOTE       EQU     TICKSLOT_N
SLOT_REMOTE     EQU     ((TS_REMOTE & 15) + ((TS_REMOTE >> 4) & 1) * (15 - 2 * (TS_REMOTE & 15)))
TS_REMOTE2      EQU     TS_REMOTE + 1
SLOT_REMOTE2    EQU     ((TS_REMOTE2 & 15) + ((TS_REMOTE2 >> 4) & 1) * (15 - 2 * (TS_REMOTE2 & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_REMOTE + 2)
endif
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
if defined(FEAT_SENSORPRO)
TS_SENSORPRO    EQU     TICKSLOT_N
SLOT_SENSORPRO  EQU     ((TS_SENSORPRO & 15) + ((TS_SENSORPRO >> 4) & 1) * (15 - 2 * (TS_SENSORPRO & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_SENSORPRO + 1)
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
if defined(FEAT_NITROUS)
TS_NITROUS      EQU     TICKSLOT_N
SLOT_NITROUS    EQU     ((TS_NITROUS & 15) + ((TS_NITROUS >> 4) & 1) * (15 - 2 * (TS_NITROUS & 15)))
undef TICKSLOT_N
define TICKSLOT_N (TS_NITROUS + 1)
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
if defined(FEAT_DATALOG) || defined(FEAT_DLSTREAM) || defined(FEAT_DLQD3) || defined(FEAT_DLSERVICE) || defined(FEAT_DLSERIALIN) || defined(FEAT_DLMEMREAD) || defined(FEAT_TRIGLOG)
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
include "triglog.asm"
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
include "sensorpro.asm"
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
; nitrous: the secondary maps (the skeleton builds them for it too), blended in by the shot
include "nitrous.asm"
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
; the remote control commands (after the limiters and dlservice.asm: its limits are one more cut request)
include "remote.asm"
; a diagnostic that lengthens the tick when TICKBURN_US is defined (not a module)
include "tickburn.asm"
; a diagnostic that flashes one output when OUTTEST is defined (not a module)
include "outtest.asm"
; last: the modules above ask for it in their XP_DEFS part
include "buildinfo.asm"
include "lib.asm"
