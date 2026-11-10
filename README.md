# Rom Sim Studio

Version 0.0.0.8

A desktop toolchain for OKI MSM66207 / 66201 Honda OBD1 ECU ROMs, and the
MSM66911 of the P13: emulator, disassembler, assembler, calibration editor,
datalogging, a ROM builder (the P30 and P13 skeletons and their feature modules)
and an MCP server for AI-assisted tuning. Windows, Linux and macOS.

How to use it: the guide in `Website/docs` (start at `index.html`), also on the
website. Questions and bug reports: https://discord.gg/xynkH3ymkH

## What is in here

| Project | What it does |
| --- | --- |
| `src/OkiRomSim.Core` | The part's settings (clock, peripheral set, ROM and RAM size), instruction decoding and disassembly, processor profiles, MIL code tables - nothing of the simulator |
| `src/OkiRomSim.Sim` | The simulator: MSM66207/66911 CPU emulation, bus, peripherals, engine and drive-cycle model; datalog layout detection and interrupt timing |
| `src/OkiRomSim.Assembler` | Byte-exact assembler driven by the machine-generated instruction grammar |
| `src/OkiRomSim.Calibration` | Table/setting definitions, table detection, feature patches, XDF export, datalog formats |
| `src/OkiRomSim.Desktop` | Rom Sim Studio, the full Avalonia desktop app: simulator, calibration views, gauges, graphs, tuning windows, MCP server, plugins |
| `src/OkiRomSim.Tuner` | RomSimTuner, the tuning-only build: calibration editor, live datalogging and the ROM emulator, from the same source files as Rom Sim Studio (linked, built with `TUNER_ONLY`) - no simulator, MCP server or plugins in it; its own settings and updater |
| `src/OkiRomSim.Cli` | `okisim` command-line tool (asm, run, disasm, symbols, defs, xref, ...) |
| `src/OkiRomSim.Mcp` / `McpHost` | MCP tool server (stdio and password-protected HTTP) |
| `tests/OkiRomSim.Tests` | Regression tests for both programs (see Testing) |

## Building

Requires the .NET 10 SDK.

```
dotnet build OkiRomSim.sln
```

Run the desktop app with `dotnet run --project src/OkiRomSim.Desktop`, the tuning-only build with
`dotnet run --project src/OkiRomSim.Tuner`, or the CLI with `dotnet run --project src/OkiRomSim.Cli -- <args>`.

## Release builds

`build-release.bat` (Windows) and `build-release.sh` (Linux, macOS) build Rom Sim Studio, RomSimTuner or both,
each into a folder of its own under `dist` with a zip beside it:

```
build-release.bat [full|tuner|all] [RID] [sc|single] [test] [nozip] [noweb]
./build-release.sh [full|tuner|all] [--rid RID] [--self-contained] [--single-file] [--test] [--no-zip] [--no-web]
```

With no RID they also lay out `dist/website`, ready to copy to the web host as it is: the `Website` folder (the page and the
guide, without dot-files or Thumbs.db), both zips, and each program's files for its updater - `files/` (Rom Sim Studio,
`index.php?updates`) and `files-tuner/` (RomSimTuner, `index.php?updates&product=tuner`). The site works out each file's
SHA-256 and version itself and keeps them in `.versions.json` in each of those folders, so they must be writable by PHP;
replace `files/` and `files-tuner/` whole on the host, so a file taken out of the build leaves the list too.
To check the staged site before uploading it, serve it (`php -S 127.0.0.1:8098 -t dist/website`) and run
`RomSimStudio --update-check <install folder> http://127.0.0.1:8098/` (or `RomSimTuner ...`): it prints what that install would be offered.
Delete the `.versions.json` files the check leaves in `files/` and `files-tuner/` before uploading.

| Build | Output folder | What it is |
| --- | --- | --- |
| (no RID) | `dist/RomSimStudio`, `dist/RomSimTuner` | The bundle: framework-dependent, the libraries inside the program's own .dll, every platform's native files in `runtimes`. One download runs on Windows, Linux and macOS where the .NET 10 runtime is installed. |
| RID | `dist/RomSimStudio-win-x64` ... | Framework-dependent for one platform: only its native files, much smaller. |
| RID + `sc` | `...-win-x64-sc` | Self-contained: the .NET runtime goes in too, so nothing has to be installed first. The largest. |
| RID + `single` | `...-win-x64-single` | One executable beside the `Templates` and `lang` folders (framework-dependent). For RomSimTuner; Rom Sim Studio's updater and plugins expect its files laid out as in the other builds. |

Neither script is needed: they run plain `dotnet` commands, for example

```
dotnet publish src/OkiRomSim.Desktop/OkiRomSim.Desktop.csproj -c Release -p:Bundle=true -o dist/RomSimStudio
dotnet publish src/OkiRomSim.Tuner/OkiRomSim.Tuner.csproj -c Release -r win-x64 -p:SelfContained=true -p:IntermediateOutputPath=obj/publish-win-x64-sc/ -p:OutputPath=bin/publish-win-x64-sc/ -o dist/RomSimTuner-win-x64-sc
dotnet publish src/OkiRomSim.Tuner/OkiRomSim.Tuner.csproj -c Release -r linux-x64 -p:SelfContained=false -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:IntermediateOutputPath=obj/publish-linux-x64-single/ -p:OutputPath=bin/publish-linux-x64-single/ -o dist/RomSimTuner-linux-x64-single
```

(Rom Sim Studio also gets the ScanTool plugin: `dotnet build src/Plugins/ScanTool/ScanTool.csproj -c Release`, then
`RomSim.ScanTool.dll` into the output's `Plugins` folder.) Each kind of build keeps its own `obj`/`bin` folders: a
self-contained build left in the default ones is picked up by the next build of another kind. `-p:Bundle=true` is for the
no-RID build only - it takes the libraries into the program's .dll, which a self-contained or single-file build cannot run from.

Trade-offs: framework-dependent builds are small and take .NET security updates from the installed runtime, but need it
installed first: the .NET 10 Runtime for RomSimTuner, and for Rom Sim Studio the ASP.NET Core 10 Runtime as well (its MCP
server; the program's runtimeconfig.json lists both). Self-contained builds run with nothing installed, at the cost of size, and are updated only by a new build.
Nothing is trimmed or compiled ahead of time: the user interface binds by reflection, settings and projects are read and
written with reflection-based JSON, plugins load at run time and the simulator's state is saved by reflection - all of which
trimming or native AOT would break without a warning at build time.

## Testing

`tests/OkiRomSim.Tests` checks both programs: `dotnet run --project tests/OkiRomSim.Tests -c Release` runs every group
(`-- --list` names them, `-- --only p30,emulator` picks some); the exit code is the number of failures. The P30 skeleton
first - every build byte for byte against the images saved before any change (`tools/p13/p30-images.txt`) and the
simulator's machine state at checkpoints - then the P13 skeleton against its own recorded images, the reference ROM files
(SHA-256, and each source assembling to its image), core and assembler fixes, definitions of every shipped source and
skeleton build against a saved snapshot, datalogging over a scripted link, the ROM emulator against a mock Ostrich on a
pseudo-terminal (Linux and macOS; skipped on Windows), the MCP server, and both builds: what RomSimTuner references and needs
at run time, and both programs' own self-tests run as the programs. No test writes to the repository or to hardware: every
file a test changes is a copy in a temporary folder. The recorded baselines are in `tests/OkiRomSim.Tests/data`.

The skeleton ROMs and their modules have their own harness, `tools/skeleton/SkeletonTest`
(`dotnet run --project tools/skeleton/SkeletonTest -- <mode>`). With no mode it runs the
whole suite (every module builds, keeps the checksum, runs in the simulator and does what
it says) on the P30 skeleton; set `SKEL=p13` for the same on the P13 skeleton. Modes:

| Mode | Checks |
| --- | --- |
| `--hwcheck N` | Every build from power-up as real hardware sees it (RAM full of rubbish, watchdog and heartbeat gaps against the stock build, traps): the check that finds a reset loop |
| `--offcheck` | Every executed `off(...)` operand ran on the RAM page its source meant |
| `--pairs [--quick]` | Every pair of modules the New ROM window allows, built and run with every switch on |
| `--limitscheck` | Every value in the shipped ROMs is inside the safe limits the editors enforce |
| `--modecheck` | Every build driven hard (over-rev, boost, launch, hot, low battery): byte/word instructions run in the mode their source says, no traps, resets or stack overflow (`MODECHECK_DEFS`, `MODECHECK_HOT=phase`, `MODECHECK_LAST=1` to dig in) |
| `--cutlatency` | How far past a rev limit or boost cut the last injection fires, at several climb rates |
| `--deadcode`, `--fallcheck` | Skeleton code no build reaches; stock-function combinations that fall into code they were not written to meet |
| `--ticktime DEFINES` | New ROM's interrupt-time measure for a pick (worst tick, CPU share, lost rpm readings, self-resets) |
| `--advice [stock] DEFINES` | What File > New ROM > Create says about a pick, and its module RAM |
| `--docs` | Regenerates the guide's page of every function (`Website/docs/modules.html`) from the module headers |

The app checks itself without a window: `RomSimStudio --selftest-live|--selftest-project <build.asm>`
and `--selftest-smooth`, and `RomSimTuner --selftest <rom.bin|build.asm>` runs the tuning-only build's paths (open,
definitions, an edit with its checksum, undo and redo, a save to the temp folder) on a copy of nothing but what it is given; `--ui-check <folder>` opens every window, saves a picture of each and lists
controls that are off-screen or overlap (the website's screenshots are taken this way).
`tools/hts120/FeatureTest` checks the HTS120 modules; `tools/claude` holds the Claude extension and its test (`npm test`).

## Versioning

The single source of truth for the version is `src/Directory.Build.props`;
every part of the program (title bar, Settings, Debug page, MCP handshake)
reports it through `OkiRomSim.Core.BuildInfo`.

## Author

Copyright (c) bmgjet. All rights reserved.
