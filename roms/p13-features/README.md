# Writing a feature module for the P13 skeleton

**Not tested on a car.** The P13 skeleton and these modules were checked in the Rom Sim Studio simulator only.

These are the P30's modules, ported to the P13 (MSM66911). A module is one `.asm` file in this folder, included from
`features.inc`. The skeleton (`../p13-skeleton.asm`) includes `features.inc` at each of its extension points with
`XP` set to the point. The module wraps everything in `ifdef FEAT_NAME` and emits only its part for the current point.
The assembler places the code and the tables, so any mix of modules builds in any order without overlapping. When the
ROM is full the build stops with an error.

The modules use the P30's names for what they read and ask for (`ENG_*`, `SVC_*`, `MOD_*`); `features.inc` gives
each its P13 address. A port to the P13 goes in this folder, P13 code only (`;> platforms: P13`); the P30's stay in
`../p30-features`. `../p13-skeleton.md` has the skeleton's memory map, hooks and services; `CATALOGUE.md` lists
what exists. `tools/skeleton/SkeletonTest` with `SKEL=p13` builds every module, alone and together, and checks each
one in the simulator.

## The header

File > New ROM > Create reads it:

```
;> feature: FEAT_LAUNCH          the define that builds it in
;> name: Launch control (two-step)
;> category: Limits              the group it is listed under
;> platforms: P13                the ECUs it is written for
;> pages: launch                 the HTS page its settings belong to (optional)
;> conflicts: FEAT_A, FEAT_B     cannot be built together with these (optional)
;> requires: FEAT_C              needs these (optional)
;> ram: ...                      the RAM it owns
;> about: What it does, in a sentence or three. Continues on
;>        further ";>" lines.
```

## Extension points

| XP | Where | Context |
| --- | --- | --- |
| `XP_DEFS` | before any code | defines and EQUs only; ask for services here (`define NEED_MODLIB`) |
| `XP_BOOT` | once at power-up, after the requests are cleared | main loop |
| `XP_MAIN` | once per main-loop pass | main loop |
| `XP_FUEL` | each fuel calculation, the final pulse before the dead time in `SVC_FUELPW` (1D0h, 4 us steps) | crank task |
| `XP_IGN` | each spark calculation, the final advance in 2B8h/2B9h ((x - 24) / 4 degrees) | main loop |
| `XP_TICK` | every 2.048 ms | Int14, the 4th general one-shot (or, with `SKEL_TICK_10MS`, five in a row from the stock 10.24 ms interrupt); only the crank capture (Int0) comes in meanwhile, so keep it short |
| `XP_TICKSLOT` | one tick in 16, the module's slot | as `XP_TICK`; `tickslots.inc` jumps to the slot's list |
| `XP_SPARK` | every ignition one-shot interrupt (Int13): the coil switched on, the spark - and on the P13 more than twice a spark | Int13 (built in only with the rolling idle or the tach). P2.2 says which: low, the coil just switched on; high, it just fired |
| `XP_CKP` | a crank tooth, while 0FDh bit 6 asks (the trigger log) | the crank capture interrupt |
| `XP_OUT` | after the main loop writes port B | main loop |
| `XP_CAL` | calibration tables | |
| `XP_CODE` | module code | |

## Limiters and switches: lib.asm

As on the P30: modules that cut fuel or spark, or drive an output, define `NEED_MODLIB` and run from the tick, each
on one tick in 16 (its slot). Scratch registers in a tick module: bank 39h (`SVC_BANKT`, 1C8h-1CFh).

| Routine | Does |
| --- | --- |
| `mod_limit`, `mod_cut`, `mod_cutboth` | A rev limit with hysteresis; a cut as the module decides (C); fuel and spark (C). |
| `mod_switch` | A switch input to A and Z. On the P13: 01h power steering (P4.6), 02h the service connector (port A bit 2), 04h start (P4.5), 08h VTEC pressure (1000h bit 4), 10h A/C (port A bit 0), 40h park/neutral (port A bit 5, an automatic's), 80h always, read at the pins. The brake is not traced yet: it reads off. |
| `mod_output` | One of the outputs on or off (C), on the 82C55's ports B and C through the skeleton's masks: 1 PB.0 A/C clutch, 2 PB.7 purge, 3 PC.2 A/T, 5 PC.3 the lamp, 7/8 PB.3 alternator, 9 PB.0 held off, 10 PB.2 fan, 11 PB.6 spare, and 4 the O2 heater (the CPU's P2A.2; code 27 is not stored while it is held). 6, the ECU LED, is not on the P13. |
| `mod_analog` | 0 O2, 1 ELD (the multiplexer's 3D8h), 2 EGR lift (P5.3), 3 the TCS pin (P5.5) - 0-255 for 0-5 V. |
| `skel_ports_now` | Both 8255 ports written now, with the masks (a module PWM). |
| PB.6 PWM | `NEED_PWM43`: the P30's P4.3 PWM, on PB.6 here. |

Every limiter has its own bit in two words, fuel and spark (lib.asm's); they are folded into the skeleton's
requests, `SVC_FUELCUT` (1C0h) bit 0 and 0FCh bit 0.

## Skeleton hooks

| Ask for it with | The module provides | Called |
| --- | --- | --- |
| `NEED_TPSCAL` | `mod_tpscal` | crank task, the throttle word |
| `NEED_LOADINDEX` | `mod_loadindex` | the ignition and the fuel map lookups: A = the load (288h from MAP; 0E0h, baro, on a MAP fault) |
| `NEED_SPEEDCORR` | `mod_speedcorr` | main loop, once a new road speed is in 0DFh; back with `J skel_vss_back` |
| `NEED_MAPSELECT` / `mod_maplookup` | | the main maps, looked up through DP (P13: DP the map, A the row, r1 the column) |
| `NEED_IACV` | `mod_iacv` | before the idle valve duty is stored |
| `NEED_INJSKIP`, `NEED_INJCUT` | `mod_injskip`, `mod_injcut` | each injector event, the injectors about to open |
| `NEED_VTECHOOK` | `mod_vtec` | crank task, before the stock VTEC decision: C clear the stock decision; C set: A = 0 none, 1 off, 2 on |

`FEAT_CYLTRIM` takes the closed-loop condition off the stock per-cylinder fuel trims (`CylinderIGNCorrect`).

## Module RAM

408h-43Fh (`MOD_RAM_BASE` to `MOD_RAM_END`), taken as on the P30 (`MODRAM_NEXT`). The stack comes down from 47Fh.
Much of the P13's RAM that looks free is not: see "RAM the skeleton and modules use" in `../p13-skeleton.md` before
taking any.

## Byte and word mode

As the MSM66207, the MSM66911 decodes the byte and word forms of most accumulator instructions from one opcode and
tells them apart by its DD flag. `L A` / `CLR A` / `MOV A` / `POPS A` set word mode, `LB A` / `CLRB A` / `MOVB A` byte
mode; `LC` and `LCB` leave it as it was. So after an `L A, ACC` (an index), an `LCB` loads in word mode: put an
`LB A, ACC` after it before any byte work. `SkeletonTest --only ddmode` reads every module for this.

## Rules

- Leave LRB, the register bank, DP, X1 and X2 as you found them. A and the flags are yours.
- Keep tick and spark code short: the crank task waits for them.
- Calibration goes in `XP_CAL` with a `;@` annotation for each value. Modules default to off.
- Write to the 82C55 (8000h, A000h, C000h) only through `mod_output` / `skel_ports_now` or with interrupts held off:
  the main loop and the crank task write it too.
