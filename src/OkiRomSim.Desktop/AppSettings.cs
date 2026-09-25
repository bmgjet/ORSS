// Copyright (c) bmgjet. All rights reserved.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OkiRomSim.Desktop;

/// Everything the app remembers between runs, in %APPDATA%\OkiRomSim\settings.json (~/.config/OkiRomSim on Linux/macOS). Unknown or missing fields fall back to defaults, so an older file never stops the app starting.
public sealed class AppSettings
{
    // window and layout
    public double? WindowX { get; set; }
    public double? WindowY { get; set; }
    public double WindowWidth { get; set; } = 1500;
    public double WindowHeight { get; set; } = 950;
    public bool Maximized { get; set; } = true;
    /// Grid sizes as GridLength strings ("3*", "420"): left, centre, right columns; bottom panel.
    public string LeftColumn { get; set; } = "3*";
    public string CentreColumn { get; set; } = "4*";
    public string RightColumn { get; set; } = "3*";
    /// Height of the tabbed panel under the source: a share of the window unless you have dragged it (then pixels).
    public string BottomPanel { get; set; } = "1.5*";
    public string SelectedTab { get; set; } = "Problems";
    public int SpeedIndex { get; set; } = 2;
    public string Package { get; set; } = "Sdip64";
    public string? LastFile { get; set; }
    public bool ReopenLastFile { get; set; } = true;

    // appearance
    public double UiScale { get; set; } = 1.0;
    /// Pick the UI scale and the panel layout for the screen the app starts on (ScreenFit).
    public bool FitToScreen { get; set; } = true;
    /// The screen they were last picked for ("1366x728@1"): a different screen picks them again.
    public string FittedFor { get; set; } = "";
    /// Let the window manager draw the title bar instead of the dark one drawn here. Only needed on a Linux desktop whose window manager ignores the "border only" hint.
    public bool SystemTitleBar { get; set; }
    /// Minutes between automatic restore points (0 = off).
    public int AutoSaveMinutes { get; set; } = 5;
    public double EditorFontSize { get; set; } = 13;
    public string TableLow { get; set; } = "#80FFFF";
    public string TableMid { get; set; } = "#62FF62";
    public string TableHigh { get; set; } = "#FFFF00";
    public string TableMax { get; set; } = "#FF0000";
    public string TraceColour { get; set; } = "#00FFFF";
    public string TrailColour { get; set; } = "#00FF00";
    public string HitCodeColour { get; set; } = "#3CC85A";
    public string HitDataColour { get; set; } = "#468CFF";

    /// Zoom of each panel (Ctrl + mouse wheel over it): "Source", "Pinout", "Inputs", "Right", "Calibration", "Datalog", "Trace", ... -> scale.
    public Dictionary<string, double> PanelZoom { get; set; } = [];
    /// Tuner mode: the calibration editor as the main page with datalogging beside it.
    public bool TunerMode { get; set; }

    // simulation
    public bool FastBoot { get; set; } = true;
    public bool LiveTrace { get; set; } = true;
    public bool FollowReads { get; set; } = true;
    public double TrailSeconds { get; set; } = 1.0;
    /// Processor profile the app starts with (a built-in name); projects carry their own.
    public string Processor { get; set; } = "MSM66207";

    // datalog
    public string DatalogPort { get; set; } = "";
    public int DatalogBaud { get; set; } = 38400;
    /// "auto" or a protocol name (see DatalogProtocol.All).
    public string DatalogProtocol { get; set; } = "auto";
    public int DatalogIntervalMs { get; set; } = 0;
    public bool DatalogDrivesSimulator { get; set; } = true;
    /// Readings from somewhere other than the ECU: an HTTP endpoint or a JSON file, polled in the background and offered to the gauges as `name.key` channels.
    public List<ExternalFeedSettings> ExternalFeeds { get; set; } = [];

    // ---- tuning targets (Settings > Targets)
    /// AFR you want the engine to run, across rpm and load, for each cam. Text in the same shape a spreadsheet pastes: load across the top, rpm down the left.
    public string AfrTargetLow { get; set; } = "";
    public string AfrTargetHigh { get; set; } = "";
    /// Wideband correction: measured = corrected, one pair per line.
    public string WidebandCorrection { get; set; } = "";
    /// Curves for analog inputs, so an aux channel reads in the units you want: "name: 0=0, 2.5=50, 5=100", one per line.
    public string AnalogCurves { get; set; } = "";
    /// Frames kept in memory while logging. Each frame holds its raw bytes and every channel, so this is the app's biggest single use of memory: 50,000 frames is about an hour.
    public int DatalogKeepFrames { get; set; } = 50_000;
    /// Wideband controller on its own serial port: "none", "AEM", "Zeitronix", "TechEdge", "PLX", "Spartan", "Innovate".
    public string WidebandType { get; set; } = "none";
    public string WidebandPort { get; set; } = "";
    public int WidebandBaud { get; set; } = 9600;
    public double StoichAfr { get; set; } = 14.7;
    public List<AuxChannelSetting> AuxChannels { get; set; } = [];
    public string OverlayChannel { get; set; } = "afr";
    /// A datalog layout worked out from the ROM (Datalog page > Detect layout), as JSON.
    public string? DetectedLayout { get; set; }

    // ---- how the serial link is driven (the numbers the established tuning software exposes)
    /// Milliseconds to wait for the bytes of one frame before giving up on it.
    public int SerialTimeoutMs { get; set; } = 120;
    /// Milliseconds to wait for a write to go out.
    public int SerialWriteTimeoutMs { get; set; } = 300;
    /// A pause after writing a command before the answer is read. Some USB-serial cables need it; 10 ms is what the tuning software uses.
    public int PostWritePauseMs { get; set; } = 10;
    /// How many times a handshake or a frame is retried before the link is called dead.
    public int SerialRetries { get; set; } = 3;
    /// Raise DTR and RTS when the port is opened. Most OBD1 cables do not care; a few take their power from these lines.
    public bool SerialDtrRts { get; set; }

    // hit trace and the ROM emulator
    /// Which emulator is in the ROM socket: "Ostrich", "Demon", "ROMulator", "PGMFI RTP", "CobraRTP", "ECU-Tamer", "Moates1" or "auto".
    public string EmulatorType { get; set; } = "auto";
    /// Emulator baud rate. The Ostrich / Demon family speak 115200 or 921600; a PGMFI RTP speaks 38400.
    public int EmulatorBaud { get; set; } = 921600;
    public string MoatesPort { get; set; } = "";
    public string MoatesBase { get; set; } = "8000";
    public bool HitSkipRepeats { get; set; } = true;
    public bool HitColourSource { get; set; } = true;
    public bool EmulatorAutoUpload { get; set; }

    // hot keys: action -> gesture ("F5", "Ctrl+B", "Shift+F11")
    public Dictionary<string, string> HotKeys { get; set; } = DefaultHotKeys();

    public static Dictionary<string, string> DefaultHotKeys() => new()
    {
        ["Run / pause"] = "F5",
        ["Step"] = "F11",
        ["Step over"] = "F10",
        ["Step into"] = "Ctrl+F11",
        ["Step out"] = "Shift+F11",
        ["Reset"] = "Ctrl+R",
        ["Build"] = "Ctrl+B",
        ["Toggle breakpoint"] = "F9",
        ["Open"] = "Ctrl+O",
        ["Save"] = "Ctrl+S",
        ["Save project"] = "Ctrl+Shift+S",
        ["Expand lower tabs"] = "Ctrl+E",
        ["Settings"] = "Ctrl+OemComma",
        ["Tuner mode"] = "Ctrl+T",
        ["Compare"] = "Ctrl+Shift+C",
    };

    // MCP server (for LLM agents)
    public bool McpEnabled { get; set; }
    public int McpPort { get; set; } = 8765;
    public bool McpRemote { get; set; }
    /// Stored encrypted for the current Windows user (DPAPI); plain elsewhere.
    public string McpPasswordStored { get; set; } = "";
    [JsonIgnore]
    public string McpPassword
    {
        get
        {
            if (McpPasswordStored.Length == 0) return "";
            if (!OperatingSystem.IsWindows() || !McpPasswordStored.StartsWith("dpapi:")) return McpPasswordStored;
            try
            {
                var bytes = System.Security.Cryptography.ProtectedData.Unprotect(Convert.FromBase64String(McpPasswordStored[6..]), null,
                    System.Security.Cryptography.DataProtectionScope.CurrentUser);
                return System.Text.Encoding.UTF8.GetString(bytes);
            }
            catch { return ""; }
        }
        set
        {
            if (string.IsNullOrEmpty(value)) { McpPasswordStored = ""; return; }
            if (!OperatingSystem.IsWindows()) { McpPasswordStored = value; return; }
            var enc = System.Security.Cryptography.ProtectedData.Protect(System.Text.Encoding.UTF8.GetBytes(value), null,
                System.Security.Cryptography.DataProtectionScope.CurrentUser);
            McpPasswordStored = "dpapi:" + Convert.ToBase64String(enc);
        }
    }
    public List<string> McpRoots { get; set; } = [];
    public bool McpReadOnly { get; set; }

    // ------------------------------------------------------------------ load / save

    /// Folder holding the settings, the restore points and anything else kept between runs.
    [JsonIgnore]
    public static string Dir => Path.GetDirectoryName(FilePath)!;

    [JsonIgnore]
    public static string FilePath
    {
        get
        {
            var dir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrEmpty(dir)) dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
            return Path.Combine(dir, "OkiRomSim", "settings.json");
        }
    }

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var s = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), Json) ?? new AppSettings();
                foreach (var (k, v) in DefaultHotKeys()) s.HotKeys.TryAdd(k, v);
                return s;
            }
        }
        catch { /* a damaged file just means defaults */ }
        return new AppSettings();
    }

    public void Save()
    {
        if (UiCheck.Active) return;   // the layout check resizes everything: it must not become your layout
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Json));
        }
        catch { }
    }

    public AppSettings Clone() => JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(this, Json), Json)!;

    public double Zoom(string panel) => PanelZoom.TryGetValue(panel, out var z) ? Math.Clamp(z, 0.5, 3) : 1.0;

    /// The settings that belong with a ROM (saved in projects): no window layout, no secrets.
    public AppSettings RomScoped()
    {
        var c = Clone();
        c.McpPasswordStored = ""; c.McpRoots = []; c.McpEnabled = false;
        c.WindowX = c.WindowY = null; c.LastFile = null;
        return c;
    }
}

/// An extra datalog channel (see OkiRomSim.Calibration.AuxChannel).
public sealed class AuxChannelSetting
{
    public string Name { get; set; } = "aux1";
    public string Unit { get; set; } = "V";
    public string Source { get; set; } = "byte:24";
    public string Expr { get; set; } = "x * 5 / 255";
    public OkiRomSim.Calibration.AuxChannel ToChannel() => new() { Name = Name, Unit = Unit, Source = Source, Expr = Expr };
}
