# Pointing Claude Code at the Rom Sim Studio MCP server

Two scripts, same job. Use whichever suits the machine the **agent** is on:

| | |
|---|---|
| `Register-RomSimMcp.ps1` | Windows / PowerShell 7. Can read the port and password out of the app's own settings. |
| `register-romsim-mcp.sh` | Linux, macOS, Git Bash. Needs `curl` and a working `python3`. |

Both write the server into `.mcp.json` at the repository root, which is what Claude Code reads when
it opens this folder — no CLI needed, whatever version is installed. They probe the link first and
refuse to write a config that does not work.

## Which server

This matters more than anything else in the setup.

**The server inside the app** (Settings → MCP server) is the only one with a live session. It is the
only one where `app_open`, `rom_upload`, `rom_download`, `simulator` and `datalog` do anything: the
agent works on the ROM that is open in the window, its edits go through the same undo stack as
yours, and you watch them happen. Use this one.

**A head-less server** (`RomSimStudio --mcp`, or `romsim-mcp`) has no window behind it. The file,
disassembly, assembly, calibration and comparison tools all work — you pass a `path` to each — but
the six session tools are listed and then refuse. The scripts tell you which kind answered.

## The usual cases

Agent and app on the same machine:

```bash
# PowerShell
./Register-RomSimMcp.ps1
```

It reads the port from `%APPDATA%\OkiRomSim\settings.json` and, as the Windows user that set it,
decrypts the password too.

Agent here, app and ECU on another machine — the case the transfer tools exist for:

```bash
./Register-RomSimMcp.ps1 -ComputerName tuning-pc -Password 'the-password' -UseEnvToken
./register-romsim-mcp.sh --host tuning-pc --password 'the-password' --env-token
```

On the app's machine first: Settings → MCP server → tick **Run the HTTP MCP server**, tick **Allow
remote connections** (which requires a password of 8+ characters), and let the port through the
firewall:

```powershell
New-NetFirewallRule -DisplayName 'Rom Sim Studio MCP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8765
```

No app, agent on the same machine as the files:

```bash
./Register-RomSimMcp.ps1 -Mode stdio
./register-romsim-mcp.sh --stdio
```

## Checking and troubleshooting

```bash
./Register-RomSimMcp.ps1 -ComputerName tuning-pc -Password pw -Test            # probe, write nothing
./Register-RomSimMcp.ps1 -ComputerName tuning-pc -Password pw -Call help       # every tool, and the order to use them
./Register-RomSimMcp.ps1 -ComputerName tuning-pc -Password pw -Call session_info
./Register-RomSimMcp.ps1 -ComputerName tuning-pc -Password pw -Call transfer_dir
./Register-RomSimMcp.ps1 -Port 8765 -Call cal_list                             # what the open ROM has defined
```

`--call` / `-Call` sends one `tools/call` and prints the answer, which separates "the network is
wrong" from "the tool is unhappy" in one step. The scripts translate the server's own refusals:
401 is the password, 429 is the five-minute lockout after five bad attempts, 405 means the URL lost
its `/mcp`.

## The password and `.mcp.json`

`.mcp.json` is a project file. Written plainly it holds the bearer token in clear, so both scripts
offer `-UseEnvToken` / `--env-token`, which writes `Bearer ${OKIROM_MCP_TOKEN}` instead — Claude
Code expands `${VAR}` when it reads the file. Set the variable where your shell will find it:

```powershell
[Environment]::SetEnvironmentVariable('OKIROM_MCP_TOKEN', '<password>', 'User')
```

```bash
export OKIROM_MCP_TOKEN='<password>'
```

The link is plain HTTP. On a trusted LAN that is fine; across anything else put it behind a VPN, an
SSH tunnel or an HTTPS reverse proxy (the standalone `romsim-mcp` also takes `--cert file.pfx`).

## Working across machines, once it is wired up

The agent has no path in common with the app's machine, so a local file name means nothing to it.
The round trip is:

1. `transfer_dir` — a folder on the app's machine that is always in the workspace and always writable.
2. `file_upload` — the `.bin` or `.asm` in chunks, with `offset` and a `sha256` to check against.
3. `app_open` — open what was just sent, exactly as the File menu would.
4. then `cal_detect`, `cal_read` / `cal_write`, `simulator`, `datalog`, `emulator` on the open ROM.
5. `file_download` brings a file back the same way.

Ask the agent to call `help` first; it lists all 41 tools with the recommended order.
