# Functions for the P30 skeleton

Every function found in the ROMs in `roms/`, and where each one stands for the skeleton. File > New ROM >
Create lists every module and stock function marked below. Pick only what the car needs: there are more
functions than 32 KB holds.

Sources: HTS120 (the main source) and HTS115, CromeGold, custom1, custom2, P13, and stock P30 / P08.

Status:
- **Module**: a feature module in this folder, tested in the simulator by `tools/skeleton/SkeletonTest`.
- **Stock**: stock P30 code that the skeleton can put back (`FEAT_STOCK_...`).
- **Skeleton**: always in the skeleton; its settings are in the skeleton's own calibration.
- **Not portable**: does not fit the P30; the note says why.

## Limits

| Function | Source | Status | Define |
| --- | --- | --- | --- |
| Rev limiter per cam (fuel, ignition or both) | HTS120 | Module | `FEAT_REVLIMIT` |
| Stock rev limiter (fuel cut) | P30 | Skeleton | |
| Launch control (two-step) | HTS120 | Module | `FEAT_LAUNCH` |
| Full throttle shift | HTS120 | Module | `FEAT_FTS` |
| Burnout control | HTS120 | Module | `FEAT_BURNOUT` |
| Rpm ceilings by road speed | HTS120 | Module | `FEAT_CEILING` |
| Rev limit by gear | HTS120 | Module | `FEAT_GEARLIMIT` |
| Speed limiter, always or on a switch | HTS120 | Module | `FEAT_SPEEDLIMIT` |
| Stock speed limiter | P30 | Stock | `FEAT_STOCK_SPEEDLIMIT` |
| Ignition cut time (main, launch, FTS) and re-fire | HTS120 | Module | `FEAT_IGNCUTMOD` |
| Enrichment and static timing on ignition cut | HTS120 | Module | `FEAT_IGNCUTMOD` |

## Protection

| Function | Source | Status | Define |
| --- | --- | --- | --- |
| Anti-start (unlocked by any switch input, or inverted, with the throttle) | HTS120, custom2 | Module | `FEAT_ANTISTART` |
| Coolant temperature protection | HTS120 | Module | `FEAT_ECTPRO` |
| Lean protection (wideband on an analog input) | HTS115/120, custom2 | Module | `FEAT_LEANPRO` |
| Boost cut, hot and cold | HTS120 | Module | `FEAT_BOOSTCUT` |
| Warning lamp (coolant, battery) | new | Module | `FEAT_WARNLAMP` |
| Knock retard | P30, CromeGold | Stock | `FEAT_STOCK_KNOCK` |
| Trouble codes, fail-safes, check-engine lamp | P30 | Stock | `FEAT_STOCK_DTC` |
| Each code switched off for the check-engine lamp (not stored or shown; its fail-safe still works) | new | Stock | `FEAT_STOCK_DTC` (CheckEngineCodes) |
| CPU / RAM / clock self-tests | P30 | Stock | `FEAT_STOCK_SELFTEST` |
| VTEC oil-pressure switch monitoring | P30 | Stock | `FEAT_STOCK_VTECPRESSURE` |
| Freeze frame | CromeGold, HTS120 | Stock | `FEAT_STOCK_DTC` (part of the stock trouble-code logic) |

## Boost

| Function | Source | Status | Define |
| --- | --- | --- | --- |
| Electronic boost control (P4.3, base duty and target against rpm) | HTS120, custom2 | Module | `FEAT_EBC` |
| Manual boost controller (one duty) | HTS120 | Module | `FEAT_BOOSTMANUAL` |

## Fuel

| Function | Source | Status | Define |
| --- | --- | --- | --- |
| Closed loop on a wideband | HTS120 | Module | `FEAT_WBCL` |
| Closed-loop O2 (narrowband) | P30 | Stock | `FEAT_STOCK_O2` |
| Flex fuel (fuel and timing on ethanol content) | HTS120, custom2 | Module | `FEAT_FLEX` |
| Injector size scaling and a global trim | HTS120 | Module | `FEAT_FUELTRIM` |
| Fuel by gear | HTS120 | Module | `FEAT_GEARFUEL` |
| Secondary maps: a full second set of fuel and ignition maps on a switch | HTS120, custom2, CromeGold | Module | `FEAT_DUALMAPS` (about 820 bytes; 1,640 with extended maps) |
| Secondary tune trims: fuel and timing against rpm on a switch | HTS120 | Module | `FEAT_MAPSWITCH` (small: two 9-point tables) |
| Extended maps: 20 load columns instead of 10 | CromeGold | Module | `FEAT_EXTMAPS` (about 1,000 bytes) |
| Separate high-cam VE map | P30 | Stock | `FEAT_STOCK_HICAMVE` |
| VE map, cranking fuel, warm-up, IAT / baro / battery, tip in / out, decel fuel cut, injector dead times | P30 | Skeleton | |
| Individual cylinder fuel trims | HTS120, P13 | Module | `FEAT_CYLTRIM` |
| Maps indexing (MAP, alpha-N, TPS load) | HTS120 | Module | `FEAT_ALPHAN` |

## Ignition

| Function | Source | Status | Define |
| --- | --- | --- | --- |
| Traction control | HTS120, custom2 | Module | `FEAT_TRACTION` |
| Timing by gear | HTS120 | Module | `FEAT_GEARIGN` |
| TPS tip-in retard | HTS120 | Module | `FEAT_TPSRETARD` |
| Ignition maps, dwell, coolant / intake-air / idle corrections | P30 | Skeleton | |
| Per-cylinder timing trims | HTS120 | Not portable | The P30 works out one advance for every cylinder; HTS120's per-cylinder index belongs to another ECU's layout. |

## Outputs

| Function | Source | Status | Define |
| --- | --- | --- | --- |
| GIO 1-4: programmable outputs, each its own function and page | HTS120 | Module | `FEAT_GIO1` - `FEAT_GIO4` |
| Smart alternator: charging down under heavy load | new | Module | `FEAT_SMARTALT` |
| A/C load disable: the compressor off at full throttle, high or low rpm | HTS120 | Module | `FEAT_ACCUT` (needs `FEAT_STOCK_AC`) |
| Water / methanol injection: a pump duty table against boost | new | Module | `FEAT_WMI` |
| IAB (intake butterflies) | HTS120 | Module | `FEAT_IAB` |
| Rpm-switched output | HTS120 | Module | `FEAT_RPMSWITCH` |
| Shift light on the check-engine lamp (per gear with gear detection) | HTS120 | Module | `FEAT_SHIFTLIGHT` |
| VTEC off, VTEC on another output | HTS120 | Module | `FEAT_VTECCTL` |
| Tachometer output | custom2 | Module | `FEAT_TACH` |
| VTEC engage points, radiator fan, idle air control, fuel pump, alternator | P30 | Skeleton | |
| A/C clutch and idle-up | P30 | Stock | `FEAT_STOCK_AC` |
| EVAP purge | P30 | Stock | `FEAT_STOCK_PURGE` |
| EGR | P30 | Stock | `FEAT_STOCK_EGR` |
| O2 sensor heater | P30 | Stock | `FEAT_STOCK_O2HEATER` |
| Automatic transmission shift and lock-up | P30 | Stock | `FEAT_STOCK_AT` |

## Sensors

| Function | Source | Status | Define |
| --- | --- | --- | --- |
| Gear detection (rpm / road speed) | CromeGold, custom2, HTS120 | Module | `FEAT_GEAR` |
| MAP sensor scaling (2, 2.5, 3 bar) | HTS120 | Skeleton | Calibration > Scale > MAP sensor. |
| Road speed correction | HTS120 | Module | `FEAT_SPEEDCORR` |
| TPS sensor end points | HTS120 | Module | `FEAT_TPSCAL` |

## Idle

| Function | Source | Status | Define |
| --- | --- | --- | --- |
| Anti-stall: idle valve opened, timing added, A/C and alternator off when the rpm drops | new | Module | `FEAT_ANTISTALL` |
| Rolling idle: one injector opening (or one spark) in every few left out at idle | new | Module | `FEAT_ROLLIDLE` |

## Options

| Function | Source | Status | Define |
| --- | --- | --- | --- |
| Board options set in software (the configuration resistors overridden) | new | Module | `FEAT_CFGOVERRIDE` |
| Watermark: 16 characters, scrambled, with a check word the app verifies | new | Module | `FEAT_WATERMARK` (a mark only: the ROM runs the same either way) |

## Diagnostics and logging

| Function | Source | Status | Define |
| --- | --- | --- | --- |
| Datalogging core: the serial link at 38400 and the HTS 10h/20h frame, C0h+n, 40h packet (stored codes in bytes 12-15) | HTS120, p30-features | Module | `FEAT_DATALOG` |
| Datalogging: channel stream (version 3: 16 bytes of channels, picked in Datalog > Channels…, the stored codes and the service state among them) | p30-features | Module | `FEAT_DLSTREAM` |
| Datalogging: QD3 frame (ABh -> BCh, 46h -> 40 bytes and a checksum) | p30-features | Module | `FEAT_DLQD3` |
| Datalogging: service commands: clear the codes (50h), injectors off, timing locked for a timing light, maps chosen, GIO 1-4 forced on; the check-engine lamp flashes quickly while injectors are off or timing is locked. Datalogging > Codes and service… | p30-features | Module | `FEAT_DLSERVICE` |
| Stock Honda tester link (diagnostic connector) | P30 | Stock | `FEAT_STOCK_SERIAL` |
| ROM checksum | P30 | Skeleton | Set by the assembler; kept right by the app on every edit and save. |
