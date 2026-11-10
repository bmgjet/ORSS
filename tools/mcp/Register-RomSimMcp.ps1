#Requires -Version 7.0
<#
.SYNOPSIS
    Point Claude Code at this project's MCP server, check the link works, and say what to do next.

.DESCRIPTION
    There are three ways to serve the Rom Sim Studio tools, and they are not interchangeable:

      http   The server inside the running desktop app (Settings > MCP server). This is the only
             one with a live session, so it is the only one where `app_open`, `rom_upload`,
             `rom_download`, `simulator` and `datalog` work - the agent reads and changes the ROM that is
             open in the window, and you watch it happen. Use this when the app and the agent are on
             different computers, which is what the transfer_dir / file_upload / app_open round trip
             is for.

      stdio  `RomSimStudio --mcp --root DIR`, or the standalone `romsim-mcp`. The agent starts it
             itself, so it only works when the agent is on the same machine as the files. No window,
             no session: disassembly, assembly, table detection, file edits and ROM comparison all
             work; anything that needs the app does not.

      httpself  The standalone `romsim-mcp --http`. An HTTP server without a window - same tool set
             as stdio, reachable across a network.

    The script writes the server into .mcp.json (project scope), which is the shape Claude Code
    reads whatever version it is, and can also register it with `claude mcp add` when that CLI is on
    the PATH. With -Test it only probes and writes nothing.

.PARAMETER Mode
    http (default: the running app), stdio, or httpself.

.PARAMETER ComputerName
    Where the app is. Defaults to 127.0.0.1, which is right only when the agent is on the same
    machine as the app; give the app machine's name or address otherwise.

.PARAMETER Port
    Defaults to the port in the app's settings, else 8765.

.PARAMETER Password
    The password from Settings > MCP server. On the app's own machine, and as the same Windows user,
    the script can read it out of the settings file; from anywhere else you have to pass it.

.PARAMETER UseEnvToken
    Write `Bearer ${OKIROM_MCP_TOKEN}` into .mcp.json instead of the password itself, and set the
    variable for you in this session. Claude Code expands ${VAR} when it reads the file, so the
    password never lands in a file that might get shared.

.PARAMETER Root
    Workspace folder for the stdio and httpself modes. Defaults to the repository root.

.PARAMETER Test
    Probe and report; change nothing.

.PARAMETER Call
    Instead of registering anything, call one tool and print what it says - the quickest way to see
    whether the far end is really working. Try `-Call help`, `-Call session_info`, `-Call transfer_dir`.

.PARAMETER CallArgs
    Arguments for -Call, as JSON: -Call file_list -CallArgs '{"path":"."}'

.EXAMPLE
    ./Register-RomSimMcp.ps1
    The app is running on this machine: read the port and password from its settings, check the
    link, and write .mcp.json.

.EXAMPLE
    ./Register-RomSimMcp.ps1 -ComputerName tuning-pc -Password 'the-password' -UseEnvToken
    The agent is here, the app and the ECU are on tuning-pc.

.EXAMPLE
    ./Register-RomSimMcp.ps1 -ComputerName tuning-pc -Password 'pw' -Call transfer_dir
    Where on that machine can I put a file?
#>
[CmdletBinding()]
param(
    [ValidateSet('http', 'stdio', 'httpself')]
    [string] $Mode = 'http',
    [Alias('AppHost')]
    [string] $ComputerName,
    [int]    $Port,
    [string] $Password,
    [switch] $UseEnvToken,
    [string] $Root,
    [string] $Exe,
    [string] $Name = 'okirom',
    [string] $ConfigPath,
    [switch] $Test,
    [switch] $Force,
    [string] $Call,
    [string] $CallArgs = '{}'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Root)       { $Root = $RepoRoot }
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot '.mcp.json' }

function Write-Step { param([string] $Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Text) Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn { param([string] $Text) Write-Host "    $Text" -ForegroundColor Yellow }
function Write-Bad  { param([string] $Text) Write-Host "    $Text" -ForegroundColor Red }
function Write-Note { param([string] $Text) Write-Host "    $Text" -ForegroundColor DarkGray }

# ---------------------------------------------------------------- the app's own settings

function Get-SettingsPath {
    if ($IsWindows -or $null -eq $IsWindows) { return Join-Path $env:APPDATA 'RomSimStudio/settings.json' }
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    Join-Path $base 'RomSimStudio/settings.json'
}

function Get-AppSettings {
    $path = Get-SettingsPath
    if (-not (Test-Path $path)) { return $null }
    try { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json }
    catch { Write-Warn "could not read $path ($($_.Exception.Message))"; $null }
}

# The app keeps the password encrypted for the Windows user that set it (DPAPI), so this only
# works on that machine as that user. Anywhere else, -Password is the way in.
function Unprotect-StoredPassword {
    param([string] $Stored)
    if ([string]::IsNullOrEmpty($Stored)) { return $null }
    if (-not $Stored.StartsWith('dpapi:')) { return $Stored }
    if (-not ($IsWindows -or $null -eq $IsWindows)) { return $null }
    try {
        Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop
        $bytes = [Convert]::FromBase64String($Stored.Substring(6))
        $clear = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, 'CurrentUser')
        [System.Text.Encoding]::UTF8.GetString($clear)
    }
    catch {
        Write-Note "the stored password could not be decrypted here ($($_.Exception.Message)); pass -Password"
        $null
    }
}

# ---------------------------------------------------------------- talking to the server

$script:RpcId = 0

function Invoke-Mcp {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Method,
        [hashtable] $Parameters,
        [string] $Token
    )
    $script:RpcId++
    $body = @{ jsonrpc = '2.0'; id = $script:RpcId; method = $Method }
    if ($Parameters) { $body.params = $Parameters }
    $headers = @{ 'Content-Type' = 'application/json'; 'Accept' = 'application/json' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    $json = $body | ConvertTo-Json -Depth 12 -Compress
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Post -Headers $headers -Body $json `
                               -SkipHttpErrorCheck -TimeoutSec 20
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Status = 0; Error = $_.Exception.Message; Result = $null }
    }
    if ($r.StatusCode -ne 200) {
        $why = switch ([int]$r.StatusCode) {
            401 { 'the password was wrong or missing (Settings > MCP server)' }
            429 { 'too many failed logins from here; the server locks an address out for five minutes' }
            405 { 'that URL wants a POST - check the path ends in /mcp' }
            default { $r.Content }
        }
        return [pscustomobject]@{ Ok = $false; Status = [int]$r.StatusCode; Error = $why; Result = $null }
    }
    $reply = $r.Content | ConvertFrom-Json
    if ($reply.PSObject.Properties.Name -contains 'error' -and $reply.error) {
        return [pscustomobject]@{ Ok = $false; Status = 200; Error = $reply.error.message; Result = $null }
    }
    [pscustomobject]@{ Ok = $true; Status = 200; Error = $null; Result = $reply.result }
}

function Test-McpServer {
    param([string] $Url, [string] $Token)

    # the banner at / needs no password, so it separates "cannot reach it" from "wrong password"
    $root = ($Url -replace '/mcp/?$', '/')
    try {
        $banner = Invoke-WebRequest -Uri $root -Method Get -SkipHttpErrorCheck -TimeoutSec 10
        if ($banner.Content -notmatch 'romsim-mcp') {
            Write-Warn "something answered $root but it does not look like the Rom Sim Studio server"
        }
    }
    catch {
        Write-Bad "nothing answered $root"
        Write-Note "The app has to be running with Settings > MCP server switched on. If it is on another"
        Write-Note "machine, tick 'Allow remote connections' there (which needs a password of 8+ characters)"
        Write-Note "and let the port through that machine's firewall:"
        Write-Note "  New-NetFirewallRule -DisplayName 'Rom Sim Studio MCP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port"
        return $null
    }

    $init = Invoke-Mcp -Url $Url -Method 'initialize' -Token $Token -Parameters @{
        protocolVersion = '2025-06-18'
        capabilities    = @{}
        clientInfo      = @{ name = 'Register-RomSimMcp.ps1'; version = '1' }
    }
    if (-not $init.Ok) { Write-Bad "initialize failed: $($init.Error)"; return $null }
    $info = $init.Result.serverInfo
    Write-Ok "$($info.name) $($info.version), protocol $($init.Result.protocolVersion)"

    $tools = Invoke-Mcp -Url $Url -Method 'tools/list' -Token $Token
    if (-not $tools.Ok) { Write-Bad "tools/list failed: $($tools.Error)"; return $null }
    $names = @($tools.Result.tools | ForEach-Object { $_.name })
    Write-Ok "$($names.Count) tools"

    # Every server LISTS app_open, rom_upload and the rest; only the one inside the window can
    # actually run them, and it is session_info that says which this is. That is the difference
    # between "an agent can edit files here" and "an agent can work on the ROM you have open".
    $session = $false
    $d = Invoke-Mcp -Url $Url -Method 'tools/call' -Token $Token -Parameters @{ name = 'session_info'; arguments = @{} }
    if ($d.Ok) {
        $text = $d.Result.content[0].text
        $session = $text -notmatch 'no app session'
        if ($session) {
            Write-Ok 'the server inside the app: it works on the ROM open in the window'
            foreach ($line in ($text -split "`n")) { if ($line.Trim()) { Write-Note $line.Trim() } }
        }
        else {
            Write-Warn 'a head-less server: no window behind it.'
            Write-Warn 'app_open, rom_upload/rom_download, simulator and datalog are listed but will refuse;'
            Write-Warn 'the file, disassembly, assembly and calibration tools all work (pass `path` to each).'
            Write-Note 'For an agent to work on the ROM you have open, point this at the app instead:'
            Write-Note 'in the app, Settings > MCP server, then run this script with that port and password.'
        }
    }
    $t = Invoke-Mcp -Url $Url -Method 'tools/call' -Token $Token -Parameters @{ name = 'transfer_dir'; arguments = @{} }
    if ($t.Ok) { Write-Ok (($t.Result.content[0].text -split "`n")[0]) }
    [pscustomobject]@{ Tools = $names; Server = "$($info.name) $($info.version)"; Session = $session }
}

# ---------------------------------------------------------------- .mcp.json

function Write-McpConfig {
    param([string] $Path, [string] $ServerName, [hashtable] $Entry)

    $config = [ordered]@{ mcpServers = [ordered]@{} }
    if (Test-Path $Path) {
        try {
            $existing = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable
            if ($existing) {
                $config = [ordered]@{}
                foreach ($k in $existing.Keys) { $config[$k] = $existing[$k] }
                if (-not $config.Contains('mcpServers')) { $config['mcpServers'] = [ordered]@{} }
            }
        }
        catch { Write-Warn "$Path is not valid JSON; it will be replaced (a copy is kept as .bak)" }
        if ($config['mcpServers'] -and $config['mcpServers'].Keys -contains $ServerName -and -not $Force) {
            Write-Warn "'$ServerName' is already in $Path"
            $answer = Read-Host "    replace it? [y/N]"
            if ($answer -notmatch '^(y|yes)$') { Write-Note 'left alone'; return $false }
        }
        Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
    }
    $config['mcpServers'][$ServerName] = $Entry
    $json = $config | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $Path -Value $json -Encoding utf8NoBOM
    Write-Ok "wrote $Path"
    return $true
}

# ---------------------------------------------------------------- find the executables

function Find-Exe {
    param([string] $AssemblyName, [string] $Project)
    if ($Exe -and (Test-Path $Exe)) { return (Resolve-Path $Exe).Path }
    $suffix = if ($IsWindows -or $null -eq $IsWindows) { '.exe' } else { '' }
    foreach ($cfg in 'Release', 'Debug') {
        $p = Join-Path $RepoRoot "src/$Project/bin/$cfg/net10.0/$AssemblyName$suffix"
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    $null
}

# ---------------------------------------------------------------- go

Write-Host ''
Write-Step "Rom Sim Studio MCP -> Claude Code  ($Mode)"

$settings = Get-AppSettings
if ($settings -and $Mode -eq 'http') {
    if (-not $Port) { $Port = $settings.McpPort }
    if (-not $Password) { $Password = Unprotect-StoredPassword $settings.McpPasswordStored }
    if (-not $settings.McpEnabled) {
        Write-Warn "this machine's settings say the MCP server is switched off."
        Write-Note "In the app: Settings > MCP server > 'Run the HTTP MCP server while the app is open'."
        Write-Note "(Harmless if the app you are aiming at is on another machine.)"
    }
    if ($settings.McpReadOnly) { Write-Warn "that server is read-only: the agent may read and run, not write" }
}
if (-not $Port) { $Port = 8765 }
if (-not $ComputerName) { $ComputerName = '127.0.0.1' }

$probe = $null
switch ($Mode) {
    'http' {
        $url = "http://${ComputerName}:$Port/mcp"
        Write-Step "checking $url"
        if (-not $Password) {
            Write-Warn "no password. If the server has one set, every call comes back 401."
        }
        elseif ($ComputerName -ne '127.0.0.1' -and $ComputerName -ne 'localhost') {
            Write-Note "plain HTTP across a network: fine on a trusted LAN, otherwise put it behind a VPN,"
            Write-Note "an SSH tunnel or an HTTPS reverse proxy."
        }
        $probe = Test-McpServer -Url $url -Token $Password
        if (-not $probe) { Write-Host ''; exit 1 }

        if ($Call) {
            Write-Step "calling $Call"
            $arguments = if ($CallArgs) { $CallArgs | ConvertFrom-Json -AsHashtable } else { @{} }
            $r = Invoke-Mcp -Url $url -Method 'tools/call' -Token $Password -Parameters @{ name = $Call; arguments = $arguments }
            if (-not $r.Ok) { Write-Bad $r.Error; exit 1 }
            Write-Host ''
            $r.Result.content | ForEach-Object { $_.text } | Write-Host
            Write-Host ''
            exit 0
        }
        if ($Test) { Write-Host ''; Write-Ok 'the link is good; nothing was written (-Test)'; Write-Host ''; exit 0 }

        $token = $Password
        if ($UseEnvToken -and $Password) {
            $env:OKIROM_MCP_TOKEN = $Password
            $token = '${OKIROM_MCP_TOKEN}'
            Write-Ok 'OKIROM_MCP_TOKEN set for this shell; the config will refer to it rather than hold the password'
            Write-Note 'For it to survive a reboot, set it for good:'
            Write-Note "  [Environment]::SetEnvironmentVariable('OKIROM_MCP_TOKEN','<password>','User')"
        }
        $entry = [ordered]@{ type = 'http'; url = $url }
        if ($token) { $entry['headers'] = [ordered]@{ Authorization = "Bearer $token" } }
        $written = Write-McpConfig -Path $ConfigPath -ServerName $Name -Entry $entry
        if ($written -and -not $UseEnvToken -and $Password) {
            Write-Warn "$ConfigPath now holds the password in clear. Keep it out of anything you share,"
            Write-Warn "or run this again with -UseEnvToken."
        }
    }

    'stdio' {
        $exePath = Find-Exe 'RomSimStudio' 'OkiRomSim.Desktop'
        if (-not $exePath) {
            Write-Bad 'RomSimStudio was not built. Run: dotnet build OkiRomSim.sln -c Release'
            exit 1
        }
        Write-Ok "server: $exePath --mcp --root $Root"
        Write-Warn 'stdio has no window behind it: app_open, rom_upload, simulator and datalog are not available.'
        if ($Test) { Write-Host ''; exit 0 }
        $entry = [ordered]@{ command = $exePath; args = @('--mcp', '--root', $Root) }
        Write-McpConfig -Path $ConfigPath -ServerName $Name -Entry $entry | Out-Null
    }

    'httpself' {
        $exePath = Find-Exe 'romsim-mcp' 'OkiRomSim.McpHost'
        if (-not $exePath) {
            Write-Bad 'romsim-mcp was not built. Run: dotnet build OkiRomSim.sln -c Release'
            exit 1
        }
        $remote = ($ComputerName -ne '127.0.0.1' -and $ComputerName -ne 'localhost')
        if ($remote -and (-not $Password -or $Password.Length -lt 8)) {
            Write-Bad 'a server on all interfaces needs a password of at least 8 characters'
            exit 1
        }
        Write-Step 'start the server on that machine with:'
        $line = "  `$env:OKIROMSIM_MCP_PASSWORD = '<password>'; & '$exePath' --http --port $Port --root '$Root'"
        if ($remote) { $line += ' --remote' }
        Write-Host $line
        Write-Note 'The password goes in the environment variable so it stays out of process listings.'
        Write-Note 'Then register it here with:  ./Register-RomSimMcp.ps1 -ComputerName <that machine> -Password <password>'
        Write-Host ''
        exit 0
    }
}

# ---------------------------------------------------------------- the CLI, if it is about

Write-Host ''
Write-Step 'Claude Code'
$cli = Get-Command claude -ErrorAction SilentlyContinue
if ($cli) {
    Write-Ok "found $($cli.Source)"
    Write-Note 'The .mcp.json above is picked up when Claude Code opens this folder, so nothing else is needed.'
    Write-Note 'To add it for every folder instead:'
    if ($Mode -eq 'http') {
        Write-Note "  claude mcp add --transport http $Name `"http://${ComputerName}:$Port/mcp`" --header `"Authorization: Bearer <password>`""
    }
    else {
        Write-Note "  claude mcp add $Name -- `"$(Find-Exe 'RomSimStudio' 'OkiRomSim.Desktop')`" --mcp --root `"$Root`""
    }
    Write-Note 'Check with:  claude mcp list'
}
else {
    Write-Note 'The `claude` CLI is not on the PATH (the desktop app carries its own copy).'
    Write-Note 'Nothing to do: .mcp.json is read by whichever Claude Code opens this folder.'
}

Write-Host ''
Write-Step 'In a session, ask the agent to'
Write-Note "  - call `"help`" on the $Name server first; it lists every tool and the order to use them in"
if ($Mode -eq 'http' -and $probe -and $probe.Session) {
    Write-Note '  - work across machines like this, when the app is not on the agent''s computer:'
    Write-Note '      transfer_dir              where can I put a file on that machine?'
    Write-Note '      file_upload               send the .bin/.asm there in chunks (offset + sha256)'
    Write-Note '      app_open                  open what was sent, in the window'
    Write-Note '      file_download             bring a file back the same way'
    Write-Note '  - then cal_detect, cal_read/cal_write, simulator, datalog, emulator on the ROM that is open'
}
Write-Note '  - and remember every change it makes shows up in the window, and Undo puts it back'
Write-Host ''
