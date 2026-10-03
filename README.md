# Rom Sim Studio
<br>
Download from https://romsimstudio.com/
<br>


Version 0.0.0.5

A desktop toolchain for OKI MSM66207 / 66201 Honda OBD1 ECU ROMs:
emulator, disassembler, assembler, calibration editor, datalogging and an
MCP server for other tuning tools. Windows, Linux and macOS.

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


## Versioning

The single source of truth for the version is `src/Directory.Build.props`;
every part of the program (title bar, Settings, Debug page, MCP handshake)
reports it through `OkiRomSim.Core.BuildInfo`.

## Author

Copyright (c) bmgjet. All rights reserved.
