# Rom Sim Studio extension for Claude

A Claude Desktop extension (`.mcpb`) that lets Claude use **Rom Sim Studio** (Rom Sim Studio, [bmgjet/ORSS](https://github.com/bmgjet/ORSS)),
the OKI MSM66207 / 66201 Honda OBD1 ECU toolchain. With it, Claude can assemble, disassemble, explore code, run the simulator,
find and edit calibration tables, drive the Moates emulator and tune from datalogs.

Rom Sim Studio already contains the MCP server with all the tools. This extension handles the connection so Claude can reach it:

| Mode | What Claude talks to | What it can do |
| --- | --- | --- |
| **app** | The running desktop app, over its HTTP MCP server | Everything. It works on the ROM open in the app (edits show up live), plus `simulator`, `emulator` (Ostrich / Demon) and `datalog` |
| **local** | `romsim-mcp.exe` or `RomSimStudio.exe --mcp`, started by the extension | Files in the workspace folders: `arch`, `opcode`, `assemble`, `disassemble`, `explore`, `xref`, `run`, `cal_*`, `compare`... |
| **auto** (default) | The app if it is running, otherwise the local server | If neither is available, it waits for the app and its tools appear as soon as it is opened |

## Install in Claude Desktop

1. In Rom Sim Studio open **Settings > MCP server**, tick **Run the HTTP MCP server while the app is open** and set a password.
2. Double-click `romsim-studio.mcpb` (or drag it onto **Claude Desktop > Settings > Extensions**) and click **Install**.
3. Fill in the settings:
   - **Desktop app MCP password**: the password from step 1.
   - **Desktop app MCP address**: leave it as `http://127.0.0.1:8765/mcp` unless you changed the port. The app can also run on another PC with **Allow remote connections** ticked; then use `http://<that-pc>:<port>/mcp`.
   - **Local server** *(optional)*: `romsim-mcp.exe` or `RomSimStudio.exe`, so Claude can still work on files when the app is closed.
   - **Workspace folders** *(local server only)*: the folders holding your `.asm` / `.bin` files. The app uses its own folder list.
4. Ask Claude something like *"Open p28.bin, find the fuel maps and explain what the VTEC routine does"*.

The server tells Claude to start with `help` and `arch`, so it learns the 66K instruction set before it edits anything.

## Use from Claude Code

Talk to the running app directly, since Claude Code supports HTTP servers:

```
claude mcp add --transport http okirom http://127.0.0.1:8765/mcp --header "Authorization: Bearer <password>"
```

Or run the head-less server on a folder of ROMs:

```
claude mcp add okirom -- "C:\Tools\OkiRomStudio\romsim-mcp.exe" --root "D:\Roms"
```

Or use this extension's launcher to get auto mode (the app when it is open, otherwise the local server):

```
claude mcp add okirom -e OKIROM_APP_PASSWORD=<password> -e OKIROM_EXECUTABLE="C:\Tools\OkiRomStudio\romsim-mcp.exe" -- node "C:\path\to\OkiRomStudio-Claude\server\index.js" "D:\Roms"
```

Launcher settings (environment variables): `OKIROM_MODE` (`auto`/`app`/`local`), `OKIROM_APP_URL`, `OKIROM_APP_PASSWORD`,
`OKIROM_EXECUTABLE` and `OKIROM_READ_ONLY`. Workspace folders are passed as arguments.

## Building `romsim-mcp.exe`

From the ORSS repository (needs the .NET 10 SDK):

```
dotnet publish src/OkiRomSim.McpHost -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o publish
```

`RomSimStudio.exe` works as the local server too. The extension starts it with `--mcp`, so no window opens.

## Developing

```
npm test          # launcher tests against stand-ins for the app's HTTP server and the stdio server
npm run validate  # check manifest.json
npm run pack      # rebuild romsim-studio.mcpb
```

The launcher (`server/index.js`) has no dependencies and needs Node 18 or newer. Claude Desktop ships its own Node.
