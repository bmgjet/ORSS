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
| Boot, register/RAM/clock/peripheral self-tests, ROM checksum | Serial datalog / diagnostic link (receive handler, command handler, transmitter) |
| Crank/TDC/CYP sync, sensors and their conditioning | Trouble-code detection, debounce, storage, the stored-code checksum, the scan-tool snapshot |
| Fuel: maps, cranking, warm-up, IAT/baro/battery, tip-in, decel cut | Check-engine lamp and code flashing (the lamp and ECU LED stay off) |
| Ignition maps and corrections | Closed-loop O2: fuel always takes the open-loop path (O2 correction 1.0) |
| Rev limiter | EGR (the valve duty stays at its power-up value, closed) |
| VTEC, with its oil-pressure-switch check at idle | Automatic transmission shift control and lock-up (P0.5, P4.3) |
| Idle air control (IACV) and the fuel pump | |
| The stock calibration, byte for byte at 6000h-7649h | |

Because the calibration keeps its P30 addresses, P30 definitions and XDFs still line up.
The fault latches are gone, so no fail-safe substitution ever runs. A failed sensor gives raw
readings instead of a stock default value.

Size: 27,237 of 32,768 bytes used (stock P30: 30,894), with 5.3 KB free for modules.

## Memory map

| Address | What |
| --- | --- |
| 0000h-0037h | Vectors (the serial receive vector goes to the spurious-interrupt trap) |
| 0038h-53E2h | Skeleton code |
| 53E3h-5EFFh | **Free for modules** (`skel_free_start` to 5EFFh, 2,845 bytes) |
| 5F00h-5F17h | **Hook table**: eight 3-byte slots |
| 5F18h-5FDFh | Free (200 bytes) |
| 5FE0h-5FFEh | **Skeleton info block** (see below) |
| 6000h-7649h | Calibration, unchanged from P30 |
| 764Ah-7FFEh | **Free for modules** (2,485 bytes) |
| 7FFFh | **Checksum byte**: the 8-bit sum of the image must be 0, and the ROM checks it while running (BRK 48h) |

### Info block (5FE0h)

| Address | Size | Value |
| --- | --- | --- |
| 5FE0h | 12 | `P30-SKELETON` (ASCII) |
| 5FECh | 2 | layout version, major then minor (1, 0) |
| 5FEEh | 2 | first free byte below the calibration |
| 5FF0h | 2 | last free byte below the calibration (5EFFh) |
| 5FF2h | 2 | first free byte above the calibration (764Ah) |
| 5FF4h | 2 | last free byte above the calibration (7FFEh) |
| 5FF6h | 2 | hook table address (5F00h) |
| 5FF8h | 1 | number of hook slots (8) |

An editor can read this block to confirm the base is the skeleton and to find the free space
without hard-coding it.

## Hooks

Every slot is `RT, NOP, NOP` until a module claims it. Installing a module means writing
`J <module>` (03 lo hi) over the slot. The module returns with `RT`, or ends with `J` to the next
module on the same hook, which is how several modules share one hook.

| Slot | Address | Called | Context |
| --- | --- | --- | --- |
| `hook_init` | 5F00h | once, at the end of boot before the main loop | main loop |
| `hook_main` | 5F03h | once per main-loop pass (about 50 per second at idle; far fewer at high rpm) | main loop |
| `hook_fuel` | 5F06h | on each fuel calculation, right after the final pulse width is stored in word **146h** (before dead time) | crank interrupt |
| `hook_ign` | 5F09h | on each spark calculation, with the final advance in bytes **246h/247h**, before they become timer values | main loop |
| `hook_spare1-4` | 5F0Ch-5F15h | not called yet | |

### Rules for module code

- Return with `RT`. Leave LRB, USP and the stack as you found them.
- A and the flags are free. Save DP, X1 and X2 if you use them (`L A, DP` / `PUSHS A` ... `POPS A` / `MOV DP, A`).
- Do not touch the caller's register bank. Switch to your own:
  `PUSHS LRB` / `MOV LRB, #nnh` ... `POPS LRB`. Banks in module RAM: 7Bh (3D8h), 7Ch (3E0h),
  7Dh (3E8h), 7Eh (3F0h), 3Fh (1F8h).
- `hook_fuel` runs inside the crank interrupt, so keep it short.
- The main loop slows down a lot at high rpm (the crank interrupts take most of the time), so
  do not use `hook_main` as a clock. Use the tick instead.

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
  still initialises and checks parts of it.
- Outputs: **P1.4** (dash check-engine lamp, 1 = on) and **P1.5** (ECU board LED). The crank
  interrupt copies P1 to the board's output port (8255 port C), so `SB P1.4` / `RB P1.4` is all a
  module needs to do.

## Feature files

A module fits the existing `okirom-features` format as-is: code bytes into free space (original
`FF`), the hook slot from `01 00 00` to `03 lo hi`, and `"checksumByte": "7FFF"` so the app keeps
the sum at 0. `roms/p30-skeleton-features.json` has one module, a shift light on the
check-engine lamp above 6000 rpm (hook_main, code at 5E00h). Tested with `cal_features`:

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

Some caveats about that comparison:

- **Reference is "healthy" stock.** In the simulator, stock P30 sets codes 14, 19, 24 and 41
  (the simulator does not model the driver feedback pins those checks read). The fail-safes
  those codes trigger make stock's behaviour depend on loop timing. So the reference is stock P30
  with the fault latches disabled.
- **Closed-loop O2 is intentionally gone.** At warm idle, 1100 rpm idle, cruise and part load the
  skeleton runs the map value with no O2 trim (5-15% less fuel than stock at the simulator's fixed
  0.45 V O2 reading). Those four points are compared against the skeleton's own open-loop values.
- **Clock self-test.** The simulator can take an interrupt inside the clock self-test's
  one-instruction window, which fails it (BRK 4Bh) now and then. The test harness patches that one
  failure out in the simulator only. The ROM keeps the test, because a stopped timer 0 would leave
  an injector open.
- **Long injector pulses.** Above about 4300 rpm at high load, the pulse is longer than 180 degrees
  of crank. In that regime the simulator reports odd pulse widths (for example 0.4 ms at 3000 rpm
  WOT) for stock and skeleton alike. The comparison still holds because both behave the same, but
  absolute fuel numbers there are not trustworthy in the simulator.

## Still in there

Things that could go, but were kept because it was not clear enough what they drive:

- The sensor checks in the main loop still work out their fault conditions; only the latches are
  gone. Some of that code also conditions the sensor values, so it needs splitting by hand.
- Boot still runs the stored-code initialisation and checks (`cfgvariant_*`).
- Port B bit 6 (P0.6) is toggled from the scheduler within a coolant window, gated on the VTEC
  pressure flags. The P28 pin map here does not name it (O2 heater? purge?).
- The main-loop block that sets the closed-loop enable flags (219h.0, 223h.x) stays, because the
  injector timing, tip-in and dead-time code still reads those flags.
- The option bytes at 6000h-601Bh are unchanged. Several of them now select code that is gone
  (serial, A/T); they are harmless.
