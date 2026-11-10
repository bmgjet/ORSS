// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AlphaEmuPlugin;

/// How the plugin reaches the ALPHAemu / ALPHA NextGEN hardware.
public enum AlphaTransport
{
    /// USB serial straight to the emulator's bridge chip.
    DirectUsb,
    /// An ESP32 (or similar) Bluetooth serial bridge between the laptop and the emulator.
    BluetoothBridge,
    /// The built-in ALPHA NextGEN device: the same commands, answered by a simulated ECU, so every
    /// ALPHAemu screen works with nothing plugged in. Frames come from the same 24 s drive cycle
    /// the ALPHAlink demo used to run.
    BuiltInDevice,
}

/// What one ALPHAemu analog input is used for. The scaling is the ALPHA hardware's: 0-5 V at the pin.
public enum AlphaAnalogRole
{
    Disabled, WidebandAfr, NarrowbandO2, Ect, Iat, Map, Tps, Battery, FuelPressure, Boost, RawVolts,
}

/// One analog input: what it is called, what it is wired for, and the last reading it gave.
public sealed class AlphaAnalogInput
{
    public int Index { get; set; }
    public bool Enabled { get; set; }
    public AlphaAnalogRole Role { get; set; } = AlphaAnalogRole.Disabled;
    /// The channel an enabled input writes into the datalog ("alpha_a3_v"...).
    public string Channel => "alpha_a" + (Index + 1) + "_v";
    public string Name => "ALPHAemu Analog " + (Index + 1);

    /// Raw ADC counts, the voltage at the ADC, and the voltage at the sensor (after its amplifier).
    public int Raw { get; set; }
    public double AdcVolts { get; set; }
    public double SourceVolts { get; set; }
    public DateTime LastSeen { get; set; }
    public bool Fresh => (DateTime.Now - LastSeen).TotalSeconds < 2;

    public static readonly (AlphaAnalogRole Role, string Label, string Unit, string Tip)[] Roles =
    [
        (AlphaAnalogRole.Disabled, "Disabled", "", "The input is read but nothing is done with it."),
        (AlphaAnalogRole.WidebandAfr, "Wideband AFR", "AFR", "Squashed through the wideband profile (Settings > ALPHAemu > Wideband)."),
        (AlphaAnalogRole.NarrowbandO2, "Narrowband O2", "V", "The 0-1 V switch sensor, passed through as volts."),
        (AlphaAnalogRole.Ect, "Coolant (ECT)", "°C", "The ECU's thermistor curve, the same one the datalog decodes."),
        (AlphaAnalogRole.Iat, "Intake air (IAT)", "°C", "The ECU's thermistor curve, the same one the datalog decodes."),
        (AlphaAnalogRole.Map, "Manifold pressure", "kPa", "0-5 V across the sensor's range (a 3 bar sensor reads 0-300 kPa)."),
        (AlphaAnalogRole.Tps, "Throttle (TPS)", "%", "0.5 V closed to 4.5 V wide open, the ECU's own window."),
        (AlphaAnalogRole.Battery, "Battery", "V", "5 V at the pin is 40 V at the terminal (the ECU's divider)."),
        (AlphaAnalogRole.FuelPressure, "Fuel pressure", "psi", "1 psi per 0.1 V: 5 V is 50 psi."),
        (AlphaAnalogRole.Boost, "Boost", "psi g", "-14 to +44 psi across 0.5-4.5 V (a 3 bar MAP on the rail)."),
        (AlphaAnalogRole.RawVolts, "Raw volts", "V", "Just the volts, named as a channel of its own."),
    ];

    public static string LabelOf(AlphaAnalogRole role) => Roles.First(r => r.Role == role).Label;
    public static string UnitOf(AlphaAnalogRole role) => Roles.First(r => r.Role == role).Unit;
    public static string TipOf(AlphaAnalogRole role) => Roles.First(r => r.Role == role).Tip;

    /// Volts at the pin -> the engineering value the role asks for. NaN when the role means "nothing".
    public double? Value(double volts, AlphaWideband wideband) => Role switch
    {
        AlphaAnalogRole.Disabled => null,
        AlphaAnalogRole.WidebandAfr => Math.Round(wideband.Afr(volts), 2),
        AlphaAnalogRole.NarrowbandO2 => Math.Round(volts, 3),
        AlphaAnalogRole.Ect => Math.Round(OkiRomSim.Calibration.HondaDatalog.ThermistorC((byte)Math.Clamp(volts / 5.0 * 255, 0, 255)), 1),
        AlphaAnalogRole.Iat => Math.Round(OkiRomSim.Calibration.HondaDatalog.ThermistorC((byte)Math.Clamp(volts / 5.0 * 255, 0, 255)), 1),
        AlphaAnalogRole.Map => Math.Round(volts / 5.0 * 300, 1),
        AlphaAnalogRole.Tps => Math.Round((volts - 0.5) / 4.0 * 100, 1),
        AlphaAnalogRole.Battery => Math.Round(volts * 8, 2),
        AlphaAnalogRole.FuelPressure => Math.Round(volts * 10, 1),
        AlphaAnalogRole.Boost => Math.Round(-14 + (volts - 0.5) / 4.0 * 58, 2),
        AlphaAnalogRole.RawVolts => Math.Round(volts, 3),
        _ => null,
    };

    /// Where it also goes in the app's own engine model (Settings > Inputs), or null for "nowhere".
    public string? SimulatorInput => Role switch
    {
        AlphaAnalogRole.Ect => "ect", AlphaAnalogRole.Iat => "iat", AlphaAnalogRole.Map => "map",
        AlphaAnalogRole.Tps => "tps", AlphaAnalogRole.Battery => "vbatt", AlphaAnalogRole.NarrowbandO2 => "o2",
        _ => null,
    };
}

/// A remembered device: what answered, on what port, with what firmware and how big its image is.
public sealed class AlphaDeviceProfile
{
    public string DeviceId { get; set; } = "";
    public string Kind { get; set; } = "";
    public string Port { get; set; } = "";
    public int Baud { get; set; } = 921_600;
    public string Firmware { get; set; } = "";
    public int RomSize { get; set; }
    public int SlotCount { get; set; } = 4;
    public string[] Capabilities { get; set; } = [];
    public DateTime LastSeen { get; set; }
    public string Registration { get; set; } = "unknown";
}

/// What the emulator says about itself and its map slots.
public sealed record AlphaIdentity(string DeviceId, string Kind, string Firmware, string Protocol, int RomSize,
                                   int SlotCount, int ActiveSlot, int TargetSlot, string[] Capabilities,
                                   AlphaRegistration Registration);

/// The identity/authorisation record the device reports. Shown as a health check: the plugin reports
/// what the hardware says, it does not hide any feature behind it.
public sealed class AlphaRegistration
{
    public bool Registered { get; set; }
    public string Status { get; set; } = "unknown";
    public string Serial { get; set; } = "";
    public string Tier { get; set; } = "";
    public string CertificateId { get; set; } = "";
    public string ExpiresAt { get; set; } = "";
    public string Source { get; set; } = "device";
    public string[] Features { get; set; } = [];
    public override string ToString() => Registered ? $"registered ({(Tier.Length > 0 ? Tier + " tier" : "device")})" : Status;
}

/// One multi-map slot as the plugin keeps it: what is staged on the laptop, and what the device says.
public sealed class AlphaSlot
{
    public int Id { get; set; }
    public string Label { get; set; } = "";
    public string Filename { get; set; } = "";
    public long StagedBytes { get; set; }
    public string Sha256 { get; set; } = "";
    public DateTime? StagedAt { get; set; }
    public bool Verified { get; set; }
    public bool Committed { get; set; }
    public string LastResult { get; set; } = "";

    [JsonIgnore] public byte[]? Bytes { get; set; }
    public bool Loaded => Bytes is { Length: > 0 };
    public string ShortSha => Sha256.Length > 10 ? Sha256[..10] : Sha256;
}

/// Everything the plugin remembers, in one JSON file in its own data folder.
public sealed class AlphaState
{
    // link
    /// How the laptop reaches the real emulator: USB or a Bluetooth bridge (never the simulated one, which is Simulate).
    public AlphaTransport Transport = AlphaTransport.DirectUsb;
    /// The built-in simulated ALPHA NextGEN instead of the real device: off unless switched on, on the Device page.
    public bool Simulate = false;
    /// What Connect opens: the simulated device when it is switched on, else the real one.
    [System.Text.Json.Serialization.JsonIgnore] public AlphaTransport Link => Simulate ? AlphaTransport.BuiltInDevice : Transport;
    /// There is something to connect to without asking: a port picked for the real device, or the simulation switched on.
    [System.Text.Json.Serialization.JsonIgnore] public bool CanConnect => Simulate || Port.Length > 0;
    public string Port = "";
    public int Baud = 921_600;
    public string DatalogPort = "";
    public int DatalogBaud = 38_400;
    public bool AutoConnect = true;
    public int ReconnectAttempts = 10;
    public int ReconnectDelayMs = 1000;

    // what feeds the app
    public bool FeedDatalog = true;
    public int DatalogHz = 20;
    public bool DriveSimulator = false;
    public bool FeedWideband = true;

    // real-time update
    public bool AutoRealtime = true;
    public int RealtimeDelayMs = 150;
    public int MaxPatchBytes = 2048;
    public bool ConfirmActiveSlot = true;

    // analog inputs
    public List<AlphaAnalogInput> Analog = [];
    public int AnalogPollMs = 100;
    public bool AnalogToSimulator = true;

    // wideband
    public string WidebandProfile = AlphaWideband.DefaultProfile;
    public double WidebandStoich = 14.7;
    public double WidebandOffset;
    public int WidebandInput = 0;                       // which analog input carries the wideband
    public List<AlphaWidebandPoint> WidebandCustom = [];

    // multi-map manager
    public List<AlphaSlot> Slots = [];
    public int SelectedSlot = 0;

    // remembered hardware
    public Dictionary<string, AlphaDeviceProfile> Devices = new(StringComparer.OrdinalIgnoreCase);

    // session habits
    public bool InsightsEnabled = true;
    public bool AutoSnapshotOnDeploy = true;
    public int MaxSnapshots = 24;
    public bool AutosnapshotOnRealtime = false;
    public string[] ScopeChannels = ["rpm", "tps_pct", "map_kpa", "afr", "ign_deg"];

    public static readonly string[] SlotLabels = ["Map 1 - Street", "Map 2 - Dyno", "Map 3 - Lean test", "Map 4 - Spare"];

    public AlphaState()
    {
        for (int i = 0; i < 8; i++) Analog.Add(new AlphaAnalogInput { Index = i, Role = i == 0 ? AlphaAnalogRole.WidebandAfr : AlphaAnalogRole.Disabled, Enabled = i == 0 });
        for (int i = 0; i < 4; i++) Slots.Add(new AlphaSlot { Id = i, Label = SlotLabels[i] });
        WidebandCustom = AlphaWideband.DefaultCustomRows();
    }

    /// Clamp anything read from disk back into the ranges the plugin assumes.
    public void Sanitise()
    {
        // the simulated device was once a transport of its own: a saved choice of it goes back to the real link,
        // and the simulation is switched on (or not) on the Device page
        if (Transport == AlphaTransport.BuiltInDevice) Transport = AlphaTransport.DirectUsb;
        Baud = Math.Clamp(Baud, 1200, 3_000_000);
        DatalogBaud = Math.Clamp(DatalogBaud, 1200, 3_000_000);
        DatalogHz = Math.Clamp(DatalogHz, 1, 100);
        AnalogPollMs = Math.Clamp(AnalogPollMs, 20, 2000);
        RealtimeDelayMs = Math.Clamp(RealtimeDelayMs, 0, 5000);
        MaxPatchBytes = Math.Clamp(MaxPatchBytes, 16, 16 * 1024);
        ReconnectAttempts = Math.Clamp(ReconnectAttempts, 1, 50);
        ReconnectDelayMs = Math.Clamp(ReconnectDelayMs, 100, 10_000);
        MaxSnapshots = Math.Clamp(MaxSnapshots, 1, 200);
        WidebandStoich = Math.Clamp(WidebandStoich, 5, 25);
        WidebandOffset = Math.Clamp(WidebandOffset, -5, 5);
        WidebandInput = Math.Clamp(WidebandInput, 0, 7);
        SelectedSlot = Math.Clamp(SelectedSlot, 0, Math.Max(0, Slots.Count - 1));
        while (Analog.Count < 8) Analog.Add(new AlphaAnalogInput { Index = Analog.Count });
        while (Slots.Count < 4) Slots.Add(new AlphaSlot { Id = Slots.Count, Label = SlotLabels[Math.Min(3, Slots.Count)] });
        foreach (var a in Analog) a.Index = Analog.IndexOf(a);
        foreach (var s in Slots) s.Id = Slots.IndexOf(s);
        if (WidebandCustom.Count == 0) WidebandCustom = AlphaWideband.DefaultCustomRows();
    }

    // ---------------------------------------------------------------- persistence

    static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true, IncludeFields = true, Converters = { new JsonStringEnumConverter() },
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static AlphaState Load(string folder)
    {
        var path = Path.Combine(folder, "alphaemu.json");
        try
        {
            if (File.Exists(path))
            {
                var s = JsonSerializer.Deserialize<AlphaState>(File.ReadAllText(path), Json) ?? new AlphaState();
                s.Root = folder;                  // so SlotFile / RestoreStaged work straight away
                s.Sanitise();
                return s;
            }
        }
        catch { }
        return new AlphaState { Root = folder };
    }

    public void Save(string folder)
    {
        try
        {
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, "alphaemu.json"), JsonSerializer.Serialize(this, Json));
        }
        catch { }
    }

    /// A staged slot's bytes live beside the settings, not inside them.
    public string SlotFile(int slot) => Path.Combine(SlotFolder, $"slot{slot}.bin");
    string SlotFolder
    {
        get
        {
            var dir = Path.Combine(Root!, "slots");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }
    /// Where the plugin keeps its files (set once, when the state is loaded).
    public string? Root { get; set; }

    public void StageBytes(int slot, byte[] bytes, string filename)
    {
        var s = Slots[slot];
        s.Bytes = bytes;
        s.Filename = filename;
        s.StagedBytes = bytes.Length;
        s.Sha256 = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        s.StagedAt = DateTime.Now;
        s.Verified = s.Committed = false;
        s.LastResult = "staged";
        try { File.WriteAllBytes(SlotFile(slot), bytes); }
        catch (Exception ex) { s.LastResult = "staged in memory only - the file could not be written: " + ex.Message; }
    }

    /// Bring back whatever was staged last time the app ran (bytes are read lazily when needed).
    public void RestoreStaged()
    {
        foreach (var s in Slots)
            if (s.StagedBytes > 0 && File.Exists(SlotFile(s.Id)))
            {
                try
                {
                    var b = File.ReadAllBytes(SlotFile(s.Id));
                    if (b.LongLength == s.StagedBytes) s.Bytes = b;
                    else { s.Bytes = null; s.LastResult = "staged file is the wrong size"; }
                }
                catch { s.Bytes = null; }
            }
    }

    public static string Bytes(long n) => n switch
    {
        >= 1024 * 1024 => (n / 1024.0 / 1024.0).ToString("0.##", CultureInfo.InvariantCulture) + " MB",
        >= 1024 => (n / 1024.0).ToString("0.#", CultureInfo.InvariantCulture) + " KB",
        _ => n + " B",
    };
}


