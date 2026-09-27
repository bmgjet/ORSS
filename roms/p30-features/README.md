# Writing a feature module for the P30 skeleton

A module is one `.asm` file in this folder, included from `features.inc`. The skeleton includes
`features.inc` at each of its extension points with `XP` set to the point. The module wraps everything in
`ifdef FEAT_NAME` and emits only its part for the current point. The assembler places the code and the
tables, so any mix of modules builds in any order without overlapping. When the ROM is full the build stops
with an error.

`CATALOGUE.md` lists what exists and what is still to port. `tools/skeleton/SkeletonTest` builds every
module, alone and together, and checks each one in the simulator.

## The header

File > New ROM > Create reads it:

```
;> feature: FEAT_LAUNCH          the define that builds it in
;> name: Launch control (two-step)
;> category: Limits              the group it is listed under
;> pages: launch                 the HTS page its settings belong to (optional)
;> conflicts: FEAT_A, FEAT_B     cannot be built together with these (optional)
;> requires: FEAT_C              needs these (optional)
;> ram: 1F2h-1F5h                the RAM it owns
;> about: What it does, in a sentence or three. Continues on
;>        further ";>" lines.
```

## Extension points

| XP | Where | Context |
| --- | --- | --- |
| `XP_DEFS` | before any code | defines and EQUs only; ask for services here (`define NEED_MODLIB`) |
| `XP_BOOT` | once at power-up, after the requests are cleared | main loop |
| `XP_MAIN` | once per main-loop pass | main loop; only a few passes a second at high rpm |
| `XP_FUEL` | each fuel calculation, final pulse width in word 146h | crank interrupt |
| `XP_IGN` | each spark calculation, final advance in 246h/247h | main loop |
| `XP_TICK` | every 2.048 ms | timer-1 interrupt; does not nest, so keep it short |
| `XP_OUT` | after the output block | main loop |
| `XP_CAL` | calibration tables | |
| `XP_CODE` | module code | |

## Limiters and switches: lib.asm

Modules that cut fuel or spark, or drive an output, define `NEED_MODLIB` and run from the tick. Each module
has its own slot (`SLOT_...` in `lib.asm`): the tick is the same whatever the rpm, while the main loop drops
to a few passes a second at high rpm. A tick module looks like this:

```
if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_LAUNCH
                JNE     launch_tick_skip
                CAL     launch_tick
launch_tick_skip:
endif
...
launch_tick:    PUSHS   LRB                    ; bank 3Fh: r0-r7 (1F8h-1FFh) are scratch, off() reaches 100h-1FFh
                MOV     LRB, #0003fh
                L       A, DP                  ; DP, X1 and X2 are the module's once saved
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                ...                            ; work out the condition into C
                MOV     X1, #launch_block      ; enable, cut type, cut period, resume period
                L       A, #MB_LAUNCH          ; this module's bit
                CAL     mod_limit
                J       mod_tick_exit          ; puts it all back and returns to the tick
```

| Routine | Does |
| --- | --- |
| `mod_limit` | A rev limit with hysteresis, while the module's condition (C) holds. |
| `mod_cut` | Cut or not, as the module decides (C), with the block's cut type. |
| `mod_cutboth` | Fuel and spark cut or not (C). |
| `mod_switch` | A switch input (one-hot select and invert, as HTS selects them) to A and Z. |
| `mod_output` | Drive one of the free outputs on or off (C). Handing a pin back puts its latch at the idle level, so do it on a change only, not every call: other code may drive that pin. |
| `mod_gio` | One GIO channel from its block (`NEED_GIO`). |
| software PWM | `NEED_SWPWM`: 19.5 Hz, 25 steps, on any free output, written straight to the 8255. |

Every limiter has its own bit in two words, fuel (1F2h) and spark (1F4h). They are folded into the
skeleton's requests, 1F0h bit 0 (fuel) and 0FCh bit 0 (spark), so two limiters never undo each other.

| Service | Ask for it with | Does |
| --- | --- | --- |
| `mod_fueltrim` | `NEED_FUELTRIM` | The module's fuel trim (1/256ths, signed) into a running total. The fuel hook multiplies the final pulse width by it. |
| `mod_igntrim` | `NEED_IGNTRIM` | The module's timing trim (0.25 degree steps, + = advance) into a total that goes to the skeleton's advance (2FCh) or retard (2FDh). |
| `mod_analog` / `mod_afr` | | An analog input (0 O2, 1 ELD, 2 EGR, 3 B6) as 0-255, or as an AFR from a wideband's two end points. |
| `mod_rpmbyte`, `mod_lookup9` | | Rpm / 32 as a byte, and a 9-point table looked up with a straight line between points. |
| P4.3 PWM | `NEED_PWM43` | Every tick, a 25-step cycle (19.5 Hz) on P4.3, on for `MOD_PWMDUTY` steps: for a boost solenoid. |
| Gear | `requires: FEAT_GEAR` | The gear in `MOD_GEAR` (2FEh), 0 when not known. |

`XP_SPARK` runs at every timer-3 (spark) interrupt: crank-synchronous, twice per spark event.

## Skeleton hooks

Some functions have to change a value where the skeleton works it out. The skeleton calls a routine the
module provides, only when the module asks for it in its `XP_DEFS` part. One module provides each.

| Ask for it with | The module provides | Called | Does |
| --- | --- | --- | --- |
| `NEED_TPSCAL` | `mod_tpscal` | crank task, bank 40h, after the TPS fault check | er0 (the throttle A/D word) rescaled. Keep er1-er3. |
| `NEED_LOADINDEX` | `mod_loadindex` | crank task, bank 40h, twice (ignition and fuel map lookups) | A (byte) = the map load; stock is MAP, 0A7h. Keep every register. |
| `NEED_SPEEDCORR` | `mod_speedcorr` | main loop, bank 41h, jumped to once a new road speed is in 0B4h | Correct 0B4h, keep A and the registers, then `J vss_calc_gate2_if_ram231_bit3_set`. |
| `NEED_MAPSELECT` | `mod_mapselect` | before every fuel and ignition map lookup | X1 = the map about to be used; swap it for another. Keep the rest. |
| `NEED_IACV` | `mod_iacv` | main loop, before the idle valve duty word is stored | A = the duty word; raise or replace it. er0 is free. |
| `NEED_CFGOVERRIDE` | `mod_cfgoverride` | each time the option bytes / board resistors are decoded (bank page 2) | Change the feature flags 216h/217h/219h/227h. |
| `NEED_INJSKIP` | `mod_injskip` | injector interrupt, each time injectors are about to open | A (byte) = the injectors to open (a 0 bit opens one); return it, FFh opens none. Keep every register, and return in byte mode (after `POPS A`, `LB A, ACC`). |
| `NEED_DECELPOP` | | | A hook in the skeleton with no module using it. |

`FEAT_CYLTRIM` takes the closed-loop condition off the stock per-cylinder fuel trims. `FEAT_IGNCUTMOD` takes
over 0FCh bit 0 from lib.asm: it drives the spark cut every tick from the spark want word.

## Module RAM

Module RAM is 31Ah-351h: the stock trouble-code function's RAM, which nothing else touches, and well clear of the
system stack (stock P30 keeps 3D7h-47Fh for it, and deep interrupt nesting at high rpm reaches far into that). With
`FEAT_STOCK_DTC` built in there is nowhere else, so module RAM is 3F8h-42Fh and the build warns. Either way it runs
from `MOD_RAM_BASE` to `MOD_RAM_END`; lib.asm has the first 10 bytes and clears it all at power-up, before any
module's own `XP_BOOT` code. 2F7h-2F9h (page 2, reached with off() from the crank task and the main
loop) are taken by maps indexing and the ignition cut modifier. A module takes its bytes in its `XP_DEFS` part:

```
launch_state        EQU     MODRAM_NEXT
undef MODRAM_NEXT
define MODRAM_NEXT (launch_state + 1)
```

The build stops with an error if the modules chosen need more than there is.

## Byte and word mode

The MSM66207 decodes the byte and word forms of most accumulator instructions from one opcode:
`SLLB`/`SLL`, `CMPB`/`CMP A,#`, `ANDB`/`AND`, `STB A,rN`/`ST A,erN` and others. It tells them apart by its
DD flag. Only the plain loads set that flag: `LB`/`CLRB` for byte, `L`/`CLR` for word. `LC` and `LCB` leave
it alone.

So start every stretch of byte work with `CLRB A` (or an `LB`), and every stretch of word work with an `L`
or `CLR`. The assembler cannot see a wrong mode, and neither can a quick test on the bench. It shows up as
an instruction decoded one byte long or short, and the ECU runs off into the weeds.

## Rules

- Leave LRB, the register bank, DP, X1 and X2 as you found them. A and the flags are yours.
- Keep tick code short: the crank interrupt waits for it.
- Calibration goes in `XP_CAL` with a `;@` annotation for each value (name, type, formula, category,
  `slot=` for the HTS page row, `desc=`). Modules default to off, so building one in changes nothing until
  it is enabled.
- RAM: take it from the free list in `features.inc` and name it in the header.
