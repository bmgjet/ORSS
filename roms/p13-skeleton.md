# P13 skeleton ROM

`p13-skeleton.asm` is the base for building a Honda P13 ROM (OKI MSM66911) out of feature modules, the way
`p30-skeleton.asm` is for the P30. Its modules are in `p13-features`: the P30's modules, ported.

**Not tested on a car.** Everything here was checked in the Rom Sim Studio simulator only. Treat a ROM built from it
as you would any new ROM: emulator and wideband first, and expect surprises until someone has run one.

## Where it comes from

- `roms/p13.asm` is the stock P13 ROM, disassembled and made relocatable: every ROM address in the code is a label
  (`tools/p13/P13Build`: `symbolize`, `tables`), so code can be added anywhere and the assembler moves the rest.
  It assembles to the stock bytes, and shifted copies (2, 4 and 64 bytes) run the same in the simulator
  (`RomEquiv` functional mode).
- `p13-skeleton.asm` was generated from it (`P13Build skeleton`) and has been edited by hand since: the free space
  gathered at the end, the extension points, and the services below. With nothing defined it runs as stock P13.

## What it keeps and what it drops

Stock P13 is all still in, but for what these thirteen switches leave out (the same ones as the P30's; all thirteen
together are stock P13):

| Switch | Stock function | Without it |
| --- | --- | --- |
| `FEAT_STOCK_SERIAL` | the Honda diagnostic serial link (`int_serial`, its commands and tables, about 950 bytes) | the serial interrupt only reads and drops a byte; the datalog modules take the port |
| `FEAT_STOCK_DTC` | trouble codes: storage (330h-333h, copies at 110h and 210h, the sum at 334h), the snapshot of the first one (338h-35Dh), the check-engine lamp and code flashing; each code can be switched off on the Check engine codes page | no code is ever stored, shown or flashed. The fault checks and their fail-safe sensor values still work |
| `FEAT_STOCK_O2` | closed-loop control on the narrowband O2 sensor (its correction, 160h) | the correction stays at 100 %: for closed loop on a wideband (which conflicts with it), or open loop throughout |
| `FEAT_STOCK_O2HEATER` | the O2 sensor heater (P2A.2, low = on) and its check (code 27) | the heater off (the pin high); output 4 can drive the pin instead |
| `FEAT_STOCK_EGR` | EGR valve control | no EGR: the target (294h) 0, the valve's PWM pin off. A removed valve's lift sensor (code 11) can be switched off on the Check engine codes page |
| `FEAT_STOCK_KNOCK` | the knock processor (P4.1/P4.2), the knock retard (2B4h) and its enrichment; codes 23, 24 | no knock retard whatever the knock lines say, no knock codes. In the P13 Default, since its engines have the sensor |
| `FEAT_STOCK_VTECPRESSURE` | the VTEC pressure switch check (code 22, which turns VTEC off) | no check: VTEC stays on without oil pressure |
| `FEAT_STOCK_SPEEDLIMIT` | the speed limiter (its limit FFh in this image: none) | no speed limiter |
| `FEAT_STOCK_HICAMVE` | the high-cam VE curves (`VESlopeHigh`, `VEOffsetHigh`) | the low-cam ones (`VESlopeLow`, `VEOffsetLow`) for both cams |
| `FEAT_STOCK_AT` | the automatic: its variant flag (220h/120h bits 0 and 4), park/neutral, lock-up and its port C output, its checks | the ECU runs as a manual |
| `FEAT_STOCK_PURGE` | the EVAP purge cut solenoid (port B bit 7) | the solenoid never on |
| `FEAT_STOCK_AC` | the A/C clutch (port B bit 0) and its idle-up | the A/C request ignored, the clutch never engaged |
| `FEAT_STOCK_SELFTEST` | the self-tests: the registers, stack and PSW, the index registers and a RAM march at boot; in the main loop the RAM test (27Ch, with the clock check), the interrupt mask, the registers and every peripheral and serial register | none of them; the ROM checksum and the PWM counter checks stay |

The checks stock P13 makes of itself, when they are built, keep passing: the serial vector check and the SFR check
of every main-loop pass expect what the skeleton sets up (the datalog link's baud and interrupts when it is built),
and IE includes the bits the skeleton turns on.

## Stock settings found so far

Traced in the stock code and checked in the simulator (each table's values changed and the effect measured). They are
annotated, so the app shows and edits them; the ones with a page slot appear on that page.

| Item | What | Where it is used |
| --- | --- | --- |
| `RevLimitLowCut/Resume`, `RevLimitHighCut/Resume` | the stock rev limiter: 6510/6292 rpm low cam (or with code 22 stored), 7684/7500 rpm with VTEC engaged; the crank interrupt's over-rev cut uses the same cut point | 16Ah/16Ch, page Stock rev limiter |
| `VTECRpmLoad` (`VTECStockLoadOff/On`, `VTECStockAnyOff/On`, `VTECSpeedOff/On`) | the stock VTEC points: with load 4950 rpm (out under 4750), any load 6325 rpm (out under 6200), over 30 km/h (out under 25). Immediates in stock P13: the skeleton reads them from this table | page VTEC |
| `VTECLoad` | the load needed against rpm between the with-load and any-load points | page VTEC |
| `CrankFuel`, `CrankFuelBaro` | the cranking pulse against coolant, and its baro factor | 13Eh, 183h; page Cranking fuel |
| `CoolantFuel`, `CoolantFuel2` | fuel against coolant: the warm-up enrichment (every pulse), and a second one off idle | 17Ah, 17Bh; page ECT corrections |
| `IntakeAirFuel` | fuel against intake air temperature | 152h |
| `InjectorDeadTime` | injector dead time against battery voltage, added to every pulse (0.56 ms at 14 V) | 142h |
| `PostFuel` | after-start fuel against coolant | 158h |
| `DwellBattery` | coil dwell against battery voltage | 2A8h |
| `IgnitionRpmCorrection` | advance added against rpm, on top of the maps | 2B7h |
| `DecelCutRpm`, `DecelResumeRpm` (and `...Auto`) | the overrun fuel cut against coolant: cut above 1400 rpm warm (2400 cold), fuel back below 1100 (2100) | 16Fh, 16Eh |
| `BaroFuel` | fuel added as the barometric pressure falls | 189h |
| `OpenLoopLoad` | the load above which the fuel goes open loop and rich, against rpm | 11Ch.6 |
| `FuelRpmMultLow/High` | a multiplier against rpm on the fuel map's value, per cam | |
| `IdleTarget` | the idle speed target against coolant: 700 rpm warm, 1500 cold | 286h; page Idle |
| `IdleTargetStart` | the target for the first few seconds after a start: 950 rpm warm, 1700 cold | 286h |
| `TipInStanding`, `TipInLowRpm(2)`, `TipInHighRpm(2)` | tip-in fuel: the extra pulse against how fast the throttle opens, standing / moving under and over 1600 rpm | 146h |
| `TipInCoolant`, `TipInBaro` | the tip-in fuel against coolant and barometric pressure | 17Fh, 186h |
| `KnockFallbackLow/High` | the fixed retard used when the knock unit cannot be trusted (the knock unit itself decides the normal retard) | 2B4h |

The map rpm axes (`RpmScalerLow/High`) are crank period words: the maps' rows read as 500-7500 rpm (low cam) and
1300-8013 rpm (high cam). 

### The fuel maps and the VE tables

The P13's base fuel is speed density: for each rpm row, a slope against load and an offset (`VESlopeLow/High`,
`VEOffsetLow/High`, 20 points each along the map rpm axis) - the base pulse is slope x load (135h) / 16 + (offset - 80h)
x 2, interpolated between rows. The fuel maps (`FuelLow/High`) are not fuel amounts like the P30's: they are the
open-loop enrichment on that base, 80h = 100 %. At 80h or under the ECU stays at its closed-loop 100 %; over 80h it
goes open loop and rich by map/128, held to `FuelMapCap` (58h half scale: 137.5 %). So a stock P13 map reads 100 %
across the light loads and rises to about 136 % at full load. (Measured: the whole map at 40h, 60h or 80h gives the
same pulse; A0h gives 125 %; C0h and FFh are held at the cap.)

### The battery

0DBh is the battery voltage (ADCR0 mux position 7, 03D7h): the injector dead time, the dwell and the gates of the
code 17 and code 20 checks read it. 0DDh is the electrical load detector; 0DCh is ADCR2's reading, which the idle's
electrical-load compensation reads. (The simulator now feeds the battery to 03D7h; it left 0DBh at 80h before.)

### The starter signal

P4.5 (pin 51) is the starter signal: high while the starter turns. The stock code copies it to 214h.0 and while it is
on treats the engine as cranking - the cranking flag below 1000-1600 rpm, no tip-in fuel, the start-up idle target, and
on an automatic a fault when it is on out of park/neutral. (The simulator once held it on all the time; it now follows
cranking.)

### The trigger log and the TDC/CYP latches

The trigger log (`FEAT_TRIGLOG`) takes the TDC and CYP pulses from their latches (TRNSIT.7, TRNSIT.6) at each crank tooth;
the stock code reads and clears the same latches, in the crank task and once in the main loop. Wherever it clears one
(`RB TRNSIT.x`), the skeleton keeps a pulse the log has not had yet for the next tooth (`skel_trg_keep_n`), after the
stock's own atomic RB and without touching C (Z put back as the RB left it). SKEL_TRG bits 5 and 4 mark a pulse already
logged, until the stock code takes it.


### Annotations and the board options

`roms/p13.asm`, the stock listing, carries the same annotations where its tables are the stock ones (202; the VTEC
points are annotated on the immediates in the code), and still assembles to the original image byte for byte.

Every stock table the code reads is annotated (`SkeletonTest --only axisprobe` with `PROBE_COVER` lists any that are not):
the maps and curves above with their real axes and scales, the alternate ignition maps, the fuel correction and EGR maps
(11 rpm rows x 10 load columns), the least-advance and VTEC change-over curves, the idle, tip-in, knock and decel tables.
Tables whose role was not traced are under Internal, named `Stock_<label>`, with the code that reads them.

The board options override (`FEAT_CFGOVERRIDE`) forces the P13's variant flags, set from its ID: 220h bit 0 the
automatic, bit 2 the electrical load detector, bit 3 the baro sensor, bit 4 the A/T output checks, bit 6 an idle and
knock variant; 221h bit 0 the VTEC checks, bit 1 the knock unit, bit 2 the load input check without the ELD; 21Fh bits
0, 2, 3 and 5 (the speed limit and fuel check variant, the injector check, the knock table variant, the second
open-loop table). Each has a Board options page (`boardopt.p13...`).


## Memory map

| Where | What |
| --- | --- |
| 0000h-0049h | vectors (Int12 serial: `SKEL_SERIAL_VEC`; Int13 the spark hook, when used; Int14 the module tick) |
| code, tables | stock P13, moved by the assembler as needed |
| `skel_free_start` - 7EFFh | free for modules (the assembler places them) |
| 7F00h | hook slots (`hook_init`, `hook_main`, `hook_fuel`, `hook_ign`, spares) |
| 7FC0h | info block (ROM id `P13-OPENH001`) |
| 7FF0h | the stock factory byte, 00h (it must stay 00h: other values switch stock paths) |
| 7FFFh | checksum byte (the 8-bit sum of the image is 0) |

### RAM the skeleton and modules use

Named in `p13-features/features.inc` (the P30 names, the P13's addresses):

| Name | P13 | What |
| --- | --- | --- |
| `SVC_TICK` | 0F2h | module tick word, +1 every 2.048 ms |
| 0FBh-0FDh | 0FBh-0FDh | rolling idle, spark-cut request, module flags (as the P30) |
| `SKEL_IGNLOAD`, `SKEL_TRG` | 0F9h, 0FAh | extended maps' ignition load; trigger log TDC/CYP latch |
| `SKEL_INJ_SHUT`, `DL_SVC`, `SKEL_OVR_P` | 1BCh, 1BDh, 1BEh | cylinder test mask; service-command state; over-rev period |
| `SVC_FUELCUT` | 1C0h | fuel-cut request (bit 7 the over-rev latch, bit 6 the module rev cap) |
| `SVC_MODLIB` | 1C1h-1C7h | lib.asm's bytes, the service commands' flags |
| `SVC_BANKT` | 1C8h-1CFh | bank 39h, tick modules' scratch |
| `SVC_FUELPW` | 1D0h | final pulse width before the dead time (XP_FUEL) |
| `SKEL_OVR_C/D` | 1D2h, 1D4h | rev-cap scratch |
| `ICM_PHASE/LEFT` | 1D6h, 1D7h | ignition cut modifier |
| `SVC_IGNADV/RET` | 27Ah, 27Bh | advance / retard requests (0.25 degree steps) |
| `MOD_ALOAD`, `MOD_GEAR` | 27Eh, 27Fh | alpha-N load; the gear |
| datalog | 3AAh-3ADh, 3B0h-3B6h (bank 76h) | the stock serial link's RAM (not used then); the stream's channel list takes 16 bytes of module RAM |
| output overrides | 3ECh-3EFh (bank 7Dh) | AND/OR masks for the 82C55's ports B and C |
| `SVC_BANKF` | 400h-407h (bank 80h) | fuel hook and mod_output scratch |
| module RAM | 408h-43Fh | each module's share (the stack, from 47Fh down, was seen no deeper than 449h) |

Not free, though nothing touched them in a test drive: 200h-20Fh (register banks 40h/41h: the SFR check keeps its
expected values there), the countdown timers walked through DP (1A0h-1AAh, 1DCh-1FAh, 2CDh-2FFh, 3B7h-3B8h), the
words at 29Ah, 244h and 246h, 349h-35Dh (values the stock serial link reads out), and 3F0h-3FFh (the main loop
copies the serial link's poke values there, link or no link).

Pointer registers: the P13 keeps X1, X2, DP and USP in RAM, in the set PSWL's low bits pick (80h + 8 x the set). Stock
P13's main loop tests PSW by writing 55h to PSWL for a few instructions - set 5, which is 0A8h-0AFh: the throttle and
rpm bytes. Every skeleton interrupt handler that runs module code (the tick, the spark hook, the serial link) selects
set 2 on entry, as the stock handlers do; one that did not would, in that window, read its own pushed pointers as the
throttle.

## Hooks

| Point | Where on the P13 |
| --- | --- |
| `XP_BOOT` | end of the stock boot (`skel_boot_modules`): requests cleared, module power-up, tick started |
| `XP_MAIN` | once per main-loop pass, before it goes round (`hook_main`) |
| `XP_FUEL` | the crank task, the final pulse before the dead time in `SVC_FUELPW` (`hook_fuel`) |
| `XP_IGN` | the spark calculation, the final advance in 2B8h/2B9h (`skel_ign_service`, `hook_ign`) |
| `XP_TICK`, `XP_TICKSLOT` | the module tick: the 4th general one-shot (OS3, 4Ah) every 2.048 ms from Int14, or with `SKEL_TICK_10MS` five ticks from the stock 10.24 ms interrupt |
| `XP_OUT` | after the main loop writes port B |
| `XP_SPARK` | Int13, the ignition one-shots running out (coil on, spark); turned on only with the rolling idle or the tach output |
| `XP_CKP` | a crank tooth while 0FDh bit 6 asks (the trigger log) |

Module hooks (each only when a module asks for it): `mod_injskip`, `mod_injcut` (the injectors this event opens),
`mod_tpscal` (the throttle word), `mod_loadindex` (the load, for the ignition and the fuel lookups), `mod_mapselect`,
`mod_maplookup` (the main maps; P13 looks maps up through DP), `mod_vtec` (before the VTEC decision, in the crank
task), `mod_speedcorr` (the road speed just stored in 0DFh), `mod_iacv` (the idle valve duty).

## Services

- **Fuel cut**: `SVC_FUELCUT` non-zero cuts at the stock decision (flagged as the rev limiter flags it) and again at
  the injectors - no injector opens, including the asynchronous and prime pulses, while it is set.
- **Spark cut**: 0FCh non-zero stops the coil being switched on (IGNA); the release (IGNB) still runs, so a coil
  already charging is never left on. No igniter answer while a cut is asked for is not code 15.
- **Over-rev latch**: on every crank tooth, from the last six teeth's times (0AEh's sum, worked out at once): over the
  stock limit, bit 7 of `SVC_FUELCUT` until under the resume rpm; the modules' rev cap, bit 6.
- **Timing**: `SVC_IGNRET` and `SVC_IGNADV` move both advance bytes, held to the scale's ends.
- **Outputs** (`NEED_OUTPORT`): the 82C55's port B (copy 225h, written inverted) and port C (226h, XOR 24h) through
  AND/OR masks at every stock write; `skel_ports_now` writes both at once for a module PWM.
  lib.asm's outputs on the P13: 1 PB.0 A/C clutch, 2 PB.7 purge, 3 PC.2 A/T, 5 PC.3 the lamp, 7/8 PB.3 alternator,
  9 PB.0 held off, 10 PB.2 fan, 11 PB.6 spare, and 4 the O2 heater - the CPU's own pin, P2A.2 (low = on), held
  through the stock code's writes to it (`SKEL_OVR_P2A`, 0F5h); while it is held, code 27 (the heater check, which
  compares the pin's feedback with what the stock code wanted) is not stored. 6, the ECU LED, is not on the P13: the
  modules that default to it on the P30 - rpm switch, tach, VTEC's alternative output - default to 11 here.
- **Trouble codes**: `CheckEngineCodes` (three words, one bit per fault check, FFFFh all on) masks the fault words
  98h-9Dh before the stock scan, as on the P30: a code switched off on the Check engine codes page is never stored
  or shown, and its fail-safe still works. Codes 25 and 26 are output checks the automatic variants make (what drives them is not traced), 27 the O2 heater.
- **Cylinder trims** (`FEAT_CYLTRIM`): stock P13 has the P30's per-cylinder table (`CylinderIGNCorrect`, 80h = 100 %,
  on the per-cylinder times 384h-38Ah) and applies it in closed loop only; the module applies it always.
- **Switch inputs**: A/C (the 82C55's port A bit 0), start (P4.5), power steering (P4.6, low = pressure), read at the
  pins: the stock copies (224h, 214h, 22Ch) are refreshed once a main-loop pass, and a module would see a new throttle
  with an old switch meanwhile. Also the service check connector (port A bit 2, high when jumped: stock then blinks the
  codes), park/neutral (port A bit 5, low in P or N; an automatic's - stock reads it only on the A/T variants) and the
  VTEC pressure switch (1000h bit 4, low with pressure). The brake is not traced yet and reads off, so launch control
  and flat shift, which default to it, need another input picked on the P13.
- **Analog inputs** (lib.asm's mod_analog): 0 O2, 1 ELD (the multiplexer's 3D8h, as the P30's), 2 EGR lift (P5.3), 3 the TCS pin (P5.5,
  where the P30 has B6).
- **Datalog link** (`NEED_SERIAL_RX`): `skel_serial` serves receive and transmit from the one interrupt; 39,063 baud
  (07h) or 62,500 (04h) with DatalogFast, set at boot and expected by the SFR check.
- **Extended maps** (`FEAT_EXTMAPS`): the four main maps 20 x 20 on a 20-point load axis (the stock ten among them);
  the correction maps and the alternate ignition tables keep their 10 columns.

## The simulator's P13

Stock P13 watches inputs the first simulator never moved, and logged codes for them (the lamp on, VTEC never engaged).
What the ROM wants of each, and how the simulator now gives it (none of it traced on a board):

| Input | What the ROM wants | Simulated |
| --- | --- | --- |
| P4.1 / P4.2 (the knock processor's, by what the ROM does with them) | sampled on each of the six crank events a cylinder: the cylinder's first sample high, an even number of the other five; the newest ones are the knock retard (2B4h). Otherwise code 24 and a fall-back timing table | high on the first event only: no knock |
| P4.3 | a change every 100 ms while the engine turns (code 24) | a pulse train, 7-23 ms a half |
| P2.5 (TRANSIT bit 5) | a change at least every 16 main-loop passes, or the lamp lights (no code) | every 2 ms while the engine turns |
| 1000h bits 5 and 4 | the VTEC solenoid's feedback and its pressure switch, low while on (codes 21, 22) | follow the solenoid (port C bit 7) |
| ADCR2 | the battery (0DCh) | the battery voltage |
| ADCR3 | EGR lift: the closed valve 0.96-1.8 V, then the lift the ROM asks for (code 12) | 1.2 V plus the ROM's target |
| O2 | lean through a fuel cut | 0.05 V once nothing has been injected for 0.2 s |
| MAP at key-on (3A3h) | a running MAP that differs from it (code 5: a hose off) | the checks key on at 0 rpm and baro before they start |

## How it was checked

- `SkeletonTest --romrun p13-skeleton.asm`: boots, drives cranking to the rev limit and back; resets, faults, the stack,
  RAM no one touched (env: `ROMRUN_DEFS`, `ROMRUN_POKE`, `ROMRUN_WRITES`, `ROMRUN_BREAK`, `ROMRUN_HOT`).
- `SkeletonTest --p13try [--big | --p13preset | --defs] [--run]`: every module built on the P13; the biggest mix; the
  New ROM default preset (it fits, with 1.2 KB spare); the maps the app makes of a build.
- `SKEL=p13 SkeletonTest --only FEAT_`: the P30 modules' own checks, run on the P13 (`SKEL_FILE=` a snapshot).
- `SkeletonTest --imagehash check`: every change to shared code leaves the P30 builds byte for byte as they were.
- New ROM on a P13 pick: its interrupt-time meter runs the pick in a process of its own (`RomSimStudio --isr-timing`),
  on the 66911, whatever the app has open; `OKIROM_UICHECK_NEWROM_P13=1` checks the window with the P13 skeleton.

## Calibration names

The maps carry the P30's names, so the app's pages and the modules find them: `FuelLow`, `FuelHigh`, `IgnitionLow`,
`IgnitionHigh` (20 rows by rpm x 10 load columns; 20 with extended maps), their axes `RpmScalerLow`,
`RpmScalerHigh` (crank periods) and `MapScaler` (the load byte), and the secondary maps `FuelLow2` ... The fuel maps'
values are a share of the base fuel (80h = 100 %), applied in open loop only - in closed loop (part throttle) the
ECU holds 100 % - and the ECU limits how much they add; the ignition maps' cells are degrees ((x - 24) / 4).

`MapSensorZero` / `MapSensorFull` say which MAP sensor is fitted (the stock one: -70 to 1790 mBar); the ECU never reads
them. The P13 is speed density: its base fuel follows the load byte - measured in the simulator, it goes as (load +
26), which with the stock sensor is the manifold pressure - and the fuel maps are an enrichment on top. The stock load
byte, (MAP word - 1800h) >> 7, tops out at 1031 mBar, and stock takes a MAP reading over A1h (about 1100 mBar) for a
faulty sensor (code 3) and runs on a fixed load: an engine without boost. For boost the skeleton has:

- `MapFaultHigh`: that limit (the set-up wizard raises it above the boost).
- `MapLoadGain` / `MapLoadOffset` (and `BaroLoadGain` / `BaroLoadOffset` for the baro byte, on the same scale): the load
  byte is (MAP word x gain) >> 16 + offset - 0200h and -48 give the stock byte exactly.
- `MapSensorFuel`: the base fuel's scale (100 % stock).

A wider sensor (the MAP sensor window, the set-up wizard) gets a load scale whose 255 is its top - up to about 2040 mBar
(15 psi), as far as a base fuel of 199 % goes - and the base fuel to match, so the fuel still goes with the pressure: on
a 3-bar sensor the simulator fuels within 2-4 % (richer) of the stock sensor at part and full load, and on up with the
boost. The wizard's boost then keeps the fuel maps' full-load enrichment in the boost columns, +10 % a bar for a richer
mixture, rather than the fuel a bar a base fuel map needs. Another ECU's fuel maps are not brought across into the
P13's: theirs are base fuel, the P13's an enrichment (the import and the wizard say so); its ignition maps are.

## Still to do

- The P13's own stock functions behind switches (as the P30's are), to free space: they need tracing first - the
  disassembly's names for them are guesses.
- A brake switch: none found. Port A's other bits look like the automatic's (bit 3 is what code 25 checks against a
  driven output; bit 4 turns a calculation's sign), so the P13 may have no brake input at all. What codes 25 and 26
  check, and what really drives P4.1-P4.3 and P2.5.
- Boost on a car: the load scale and base fuel above work in the simulator (which runs the ROM's own code); the
  injectors' duty and the stock fuel limits at high load are not checked there. Wideband and boost cut first.
- A car.
