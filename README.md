# Rom Sim Studio

Version 0.0.0.6

A desktop toolchain for OKI MSM66207 / 66201 Honda OBD1 ECU ROMs:
emulator, disassembler, assembler, calibration editor, datalogging and an
MCP server for AI-assisted tuning. Windows, Linux and macOS.

How to use it: the guide in `Website/docs` (start at `index.html`), also on the
website. Questions and bug reports: https://discord.gg/xynkH3ymkH

## What is in here

| Project | What it does |
| --- | --- |
| `src/OkiRomSim.Core` | MSM66207/66911 CPU emulation, bus, peripherals, engine and drive-cycle model |
| `src/OkiRomSim.Assembler` | Byte-exact assembler driven by the machine-generated instruction grammar |
| `src/OkiRomSim.Calibration` | Table/setting definitions, table detection, feature patches, XDF export, datalog formats |
| `src/OkiRomSim.Desktop` | Avalonia desktop app: simulator, calibration views, gauges, graphs, tuning windows |
| `src/OkiRomSim.Cli` | `okisim` command-line tool (asm, run, disasm, symbols, defs, xref, ...) |
| `src/OkiRomSim.Mcp` / `McpHost` | MCP tool server (stdio and password-protected HTTP) |

## Building

Requires the .NET 10 SDK.

```
dotnet build OkiRomSim.sln
```

Run the desktop app with `dotnet run --project src/OkiRomSim.Desktop`
or the CLI with `dotnet run --project src/OkiRomSim.Cli -- <args>`.

## Testing

The skeleton ROM and its modules have their own harness, `tools/skeleton/SkeletonTest`
(`dotnet run --project tools/skeleton/SkeletonTest -- <mode>`). With no mode it runs the
whole suite (every module builds, keeps the checksum, runs in the simulator and does what
it says). Modes:

| Mode | Checks |
| --- | --- |
| `--hwcheck N` | Every build from power-up as real hardware sees it (RAM full of rubbish, watchdog and heartbeat gaps against the stock build, traps): the check that finds a reset loop |
| `--offcheck` | Every executed `off(...)` operand ran on the RAM page its source meant |
| `--pairs [--quick]` | Every pair of modules the New ROM window allows, built and run with every switch on |
| `--limitscheck` | Every value in the shipped ROMs is inside the safe limits the editors enforce |
| `--advice [stock] DEFINES` | What File > New ROM > Create says about a pick, and its module RAM |
| `--docs` | Regenerates the guide's page of every function (`Website/docs/modules.html`) from the module headers |

The app checks itself without a window: `RomSimStudio --selftest-live|--selftest-project <build.asm>`
and `--selftest-smooth`; `--ui-check <folder>` opens every window, saves a picture of each and lists
controls that are off-screen or overlap (the website's screenshots are taken this way).
`tools/hts120/FeatureTest` checks the HTS120 modules; `tools/claude` holds the Claude extension and its test (`npm test`).

## Versioning

The single source of truth for the version is `src/Directory.Build.props`;
every part of the program (title bar, Settings, Debug page, MCP handshake)
reports it through `OkiRomSim.Core.BuildInfo`.

## Author

Copyright (c) bmgjet. All rights reserved.
