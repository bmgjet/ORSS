# P30 skeleton ROM

`roms/p30-skeleton.asm` is stock P30 (Honda OBD1, OKI MSM66207, P28-style board) cut down to what
still runs the engine. It is the base for building a ROM from feature modules: launch control,
shift light, traction control and so on. Each module is a block of code in the free space that
hooks in through a table at a fixed address. `roms/p30-skeleton-features.json` shows the format
with one working module.

**It has not been run on a car.** Everything below was checked in the Oki ROM Studio simulator.
Treat it like any new ROM: use the emulator, a wideband and a bench before driving.

## What it keeps and what it drops

| Kept | Removed |
| --- | --- |
| Boot, ROM checksum | Register, RAM, stack and clock self-tests |
| Crank/TDC/CYP sync, sensors and their conditioning | Serial datalog / diagnostic link (receive handler, command handler, transmitter) |
| Fuel: one VE map for both cams (the low-cam map, as HTS does), cranking, warm-up, IAT/baro/battery, tip-in, decel cut | Trouble-code detection, debounce, storage, the stored-code checksum, the scan-tool snapshot, fail-safe sensor substitution |
| Ignition maps and corrections | Check-engine lamp and code flashing (the lamp and ECU LED stay off) |
| Rev limiter | Closed-loop O2: fuel always takes the open-loop path (O2 correction 1.0) |
| VTEC solenoid control | VTEC oil-pressure switch monitoring |
| Idle air control (IACV) and the fuel pump | Knock control unit interface and knock retard |
| A/C clutch cut, radiator fan, alternator control, O2 heater | Speed limiter |
| | EGR (the valve duty stays at its power-up value, closed), and the EGR maps |
| | Automatic transmission: shift and lock-up control (P0.4, P4.3) |
| | EVAP purge control (P0.1 stays at its power-up level: solenoid off, the stock warm-engine state) |
| | Every calibration table only the removed code read |

Size: 21,470 of 32,768 bytes used (stock P30: 30,894), with **11,098 bytes free** for modules in one
block, plus 200 bytes between the hook table and the info block.

### What that means on the car

- **No fail-safes.** The fault latches are gone, so a failed sensor gives raw readings instead of a
  stock default value, and nothing lights the lamp.
- **No self-tests.** Stock P30 stops at boot (BRK) if the CPU clock, timers, RAM or register banks
  fail their checks. The skeleton skips those checks. One of them guarded against a stopped timer 0,
  which drives injector timing; if you want that protection back, it is a candidate for a module.
- **The calibration moved.** Tables are packed straight after the code, so stock P30 definitions and
  XDFs do not line up. Make definitions for this ROM (for example with `cal_detect` / `cal_save`).
- **Open loop only.** Fuel is the map value with no O2 trim, so tune the VE map with a wideband.

## Memory map

| Address | What |
| --- | --- |
| 0000h-0037h | Vectors (the serial receive vector goes to the spurious-interrupt trap) |
| 0038h-4254h | Skeleton code (this build) |
| 4255h-53A5h | Calibration, packed straight after the code (this build) |
| `skel_free_start`-7EFFh | **Free for modules** (53A6h-7EFFh in this build, 11,098 bytes) |
| 7F00h-7F17h | **Hook table**: eight 3-byte slots |
| 7F18h-7FDFh | Free (200 bytes) |
| 7FE0h-7FFEh | **Skeleton info block** (see below) |
| 7FFFh | **Checksum byte**: the 8-bit sum of the image must be 0, and the ROM checks it while running (BRK 48h) |

Everything from 7F00h up is pinned with `org`, so it stays put when the code above it changes size.
Read `skel_free_start` from the info block rather than hard-coding 53A6h.

### Info block (7FE0h)

| Address | Size | Value |
| --- | --- | --- |
| 7FE0h | 12 | `P30-SKELETON` (ASCII) |
| 7FECh | 2 | layout version, major then minor (2, 0) |
| 7FEEh | 2 | first free byte (`skel_free_start`) |
| 7FF0h | 2 | last free byte (7EFFh) |
| 7FF2h | 2 | first byte of a second free block (0: none in layout 2) |
| 7FF4h | 2 | last byte of a second free block (0: none in layout 2) |
| 7FF6h | 2 | hook table address (7F00h) |
| 7FF8h | 1 | number of hook slots (8) |

An editor can read this block to confirm the base is the skeleton and to find the free space
without hard-coding it.

## Hooks

Every slot is `RT, NOP, NOP` until a module claims it. Installing a module means writing
`J <module>` (03 lo hi) over the slot. The module returns with `RT`, or ends with `J` to the next
module on the same hook, which is how several modules share one hook.

| Slot | Address | Called | Context |
| --- | --- | --- | --- |
| `hook_init` | 7F00h | once, at the end of boot before the main loop | main loop |
| `hook_main` | 7F03h | once per main-loop pass (about 50 per second at idle; far fewer at high rpm) | main loop |
| `hook_fuel` | 7F06h | on each fuel calculation, right after the final pulse width is stored in word **146h** (before dead time) | crank interrupt |
| `hook_ign` | 7F09h | on each spark calculation, with the final advance in bytes **246h/247h**, before they become timer values | main loop |
| `hook_spare1-4` | 7F0Ch-7F15h | not called yet | |

### Rules for module code

- Return with `RT`. Leave LRB, USP and the stack as you found them.
- A and the flags are free. Save DP, X1 and X2 if you use them (`L A, DP` / `PUSHS A` ... `POPS A` / `MOV DP, A`).
- Do not touch the caller's register bank. Switch to your own:
  `PUSHS LRB` / `MOV LRB, #nnh` ... `POPS LRB`. Banks in module RAM: 7Bh (3D8h), 7Ch (3E0h),
  7Dh (3E8h), 7Eh (3F0h), 3Fh (1F8h).
- `hook_fuel` runs inside the crank interrupt, so keep it short.
- The main loop slows down a lot at high rpm (the crank interrupts take most of the time), so
  do not use `hook_main` as a clock. Use the tick instead.
- Module code is plain 66207 code: the skeleton's own code uses `SJ`/`SCAL` where a target is in
  reach, and modules can too.

## Services

These are things a module asks the skeleton to do, instead of patching the fuel or spark code itself.

| RAM | Service |
| --- | --- |
| **1F0h** | Fuel-cut request. While any bit is set, fuel is cut exactly like the rev limiter does it. Give each module its own bit. |
| **2FDh** | Ignition retard request, in the units of the advance bytes (0.25 degrees each). It is subtracted from the final advance, with a floor of 0. |
| **0FEh-0FFh** | Tick: a word that goes up by 1 every 2.048 ms (one IACV PWM period, from timer 1), whatever the rpm or loop speed. Read it; never write it. |

Both requests are cleared at power-up before `hook_init` runs.

Checked in the simulator: 1F0h=01h cuts the injectors at cruise and at 6500 rpm while the spark
keeps running. 2FDh=20h moves the spark 8 degrees later at cruise.

### Other free resources

- RAM: 0FBh-0FDh, 1F1h-1FFh, 2F7h-2F9h, 2FEh-2FFh, 3D6h-3F9h. None of the skeleton's code refers to
  these, and none of them was touched at any test point. Leave 300h-3D5h alone: the boot code
  still initialises parts of it.
- Outputs: **P1.4** (dash check-engine lamp, 1 = on) and **P1.5** (ECU board LED). The crank
  interrupt copies P1 to the board's output port (8255 port C), so `SB P1.4` / `RB P1.4` is all a
  module needs to do. **P0.4** (A/T) and **P0.1** (purge) are no longer driven by the skeleton; a
  module can take them over (P0 bits are active low, and reach 8255 port B).

## Feature files

A module fits the existing `okirom-features` format as-is: code bytes into free space (original
`FF`), the hook slot from `01 00 00` to `03 lo hi`, and `"checksumByte": "7FFF"` so the app keeps
the sum at 0. `roms/p30-skeleton-features.json` has one module, a shift light on the
check-engine lamp above 6000 rpm (hook_main, code at 7E00h). Tested with `cal_features`:

- `list` shows it as Available on the skeleton.
- `apply` writes 18 bytes (including the checksum byte). The image sums to 0, and the lamp is
  off at 2500 rpm and on at 6500 and 8600 rpm.
- `remove` gives back the skeleton byte for byte.

For an editor that combines several modules, the missing parts are free-space allocation
(the info block gives the limits) and chaining when two modules want the same hook.

## How it was checked

The source was changed one subsystem at a time. After each step the simulator ran the skeleton and
stock P30 at 14 operating points: cranking, cold idle, warm idle, 1100 rpm idle, cruise,
3500 rpm part load, WOT at 3000, 6500 rpm WOT with VTEC, 8600 rpm (rev limit), decel, hot WOT,
key-on prime, stall and a throttle snap. It compared fuel pump, VTEC solenoid, injector rate and
pulse width, spark timing relative to TDC, and IACV duty. Unreachable code was then removed
by a reachability pass over the source, and the regression was run again.

Because the calibration moved, every ROM read was also traced in both ROMs and compared per
instruction (which table, which offset), and every indexed table read in the source was checked for
reads that run past its table into the next one. That found one start-up copy loop (RAM 1A9h-1B5h)
that read its values through another table's address; it now has its own 13-byte table with the
stock values.

Some caveats about that comparison:

- **Reference is "healthy" stock.** In the simulator, stock P30 sets codes 14, 19, 24 and 41
  (the simulator does not model the driver feedback pins those checks read). The fail-safes
  those codes trigger make stock's behaviour depend on loop timing. So the reference is stock P30
  with the fault latches disabled.
- **Closed-loop O2 is intentionally gone.** At warm idle, 1100 rpm idle, cruise and part load the
  skeleton runs the map value with no O2 trim (5-15% less fuel than stock at the simulator's fixed
  0.45 V O2 reading). Those four points are compared against the skeleton's own open-loop values.
- **Long injector pulses.** Above about 4300 rpm at high load, the pulse is longer than 180 degrees
  of crank. In that regime the simulator reports odd pulse widths (for example 0.4 ms at 3000 rpm
  WOT) for stock and skeleton alike. The comparison still holds because both behave the same, but
  absolute fuel numbers there are not trustworthy in the simulator.
- **Paths the test points do not reach** (a failed sensor, very cold starts, A/C on, a hot fan
  cycle) were checked by reading the code, not by running it.

## Still in there

Things that could go, but were kept because it was not clear enough what they drive or what
depends on them:

- **Option flags from the board.** At boot (and again each loop) the ROM reads the option bytes at
  the start of the calibration, or, when those say so, the board's configuration resistors
  (ADC readings at 3BFh/3C7h), into the feature flags at 216h/217h/219h/227h. The result depends
  on the ECU hardware, so it was not folded into constants.
- **O2 heater (P1.2).** Its drive and feedback check are wound into the crank-edge code and into
  the flags (219h.3, 223h.x) the injector timing code still reads.
- **P0.5, P0.6, P1.1, P1.6.** Driven by the scheduler and the output block (P0.5 from the
  electrical load detector and the brake switch, P0.6 toggled in a coolant window). The P28 pin
  map used here does not name them.
- The main-loop block that sets the closed-loop enable flags (219h.0, 223h.x) stays, because the
  injector timing, tip-in and dead-time code still reads those flags.
