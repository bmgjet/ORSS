// Copyright (c) bmgjet. All rights reserved.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OkiRomSim.Calibration;

/// How the power is worked out. Inertia: the car spins a roller of known inertia and its acceleration says the power. Strip: the car itself is the mass, run on a straight, flat stretch, with its air drag and rolling resistance added back.
public enum DynoMode { Inertia, Strip }

/// Where the road speed comes from. Learned: engine rpm times the ratio the run itself shows between rpm and the speed sensor (fine steps from the rpm, right scale from the sensor - one gear, no clutch slip). Sensor: the road speed sensor alone (coarse: whole km/h). Fixed: engine rpm times a speed per 1000 rpm typed in (no speed sensor needed).
public enum DynoSpeed { Learned, Sensor, Fixed }

/// The correction to standard air: what the engine would make on a standard day.
public enum DynoCorrection { None, SaeJ1349, Din70020, SaeJ607, Ece }

/// One condition of a trigger: a key held (Space), or a channel against a value.
public sealed class DynoTrigger
{
    /// "key" (the hotkey), or a channel: "tps_pct", "map_kpa", "boost_psi", "speed_kmh", "rpm", "gear", or any logged channel.
    public string Channel { get; set; } = "tps_pct";
    /// ">", ">=", "<", "<=", "=", "!=".
    public string Op { get; set; } = ">";
    public double Value { get; set; } = 90;

    public bool Test(DynoSample s, bool keyDown)
    {
        if (Channel.Equals("key", StringComparison.OrdinalIgnoreCase)) return keyDown;
        if (s.Value(Channel) is not double v) return false;
        return Op switch
        {
            ">" => v > Value, ">=" => v >= Value, "<" => v < Value, "<=" => v <= Value,
            "=" or "==" => Math.Abs(v - Value) < 0.5, "!=" => Math.Abs(v - Value) >= 0.5,
            _ => false,
        };
    }

    public override string ToString() => Channel.Equals("key", StringComparison.OrdinalIgnoreCase)
        ? "hotkey pressed"
        : $"{VirtualDyno.TriggerChannels.FirstOrDefault(c => c.Channel == Channel).Label ?? Channel} {Op} {Value:0.##}";
}

/// Everything a dyno run is worked out with: the mode, the car or the roller, the air, the losses, the AFR channel, the triggers and how the graph looks. Saved by name as a profile.
public sealed class DynoProfile
{
    public string Name { get; set; } = "New profile";
    public DynoMode Mode { get; set; } = DynoMode.Strip;
    public string Car { get; set; } = "";

    // the car (strip)
    public double VehicleKg { get; set; } = 1050;
    public double DriverKg { get; set; } = 80;
    public double FuelKg { get; set; } = 20;
    /// The wheels, axles and gearbox spun up with the car, as a share of its mass (more in low gears).
    public double RotatingPct { get; set; } = 5;
    public double DragCd { get; set; } = 0.32;
    public double FrontalM2 { get; set; } = 1.85;
    public double RollingCrr { get; set; } = 0.012;

    // the roller (inertia)
    /// The roller's moment of inertia (kg m²), from the dyno maker's sheet.
    public double RollerInertia { get; set; } = 330;
    public double RollerDiameterM { get; set; } = 1.2192;
    /// The car's own wheels and drivetrain spun with the roller, as an equivalent mass at the tyre (kg).
    public double WheelsKg { get; set; } = 25;
    /// The dyno's own friction, a force at the roller surface (N).
    public double ParasiticN { get; set; } = 0;

    // speed
    public DynoSpeed Speed { get; set; } = DynoSpeed.Learned;
    public double KmhPer1000 { get; set; } = 30;

    // air
    public DynoCorrection Correction { get; set; } = DynoCorrection.SaeJ1349;
    /// Air temperature and pressure from the ECU's intake air and baro sensors when it logs them; else the values below.
    public bool AirFromEcu { get; set; } = true;
    public double AirC { get; set; } = 25;
    public double BaroKpa { get; set; } = 101.3;
    public double HumidityPct { get; set; } = 40;

    // results
    /// Drivetrain loss, to show an estimate at the crank as well as at the wheels.
    public double DrivetrainLossPct { get; set; } = 15;
    public bool ShowCrank { get; set; }
    /// "kW", "hp" or "PS"; "Nm" or "lbft".
    public string PowerUnit { get; set; } = "hp";
    public string TorqueUnit { get; set; } = "Nm";
    /// 0 (raw) to 10: how much the acceleration is smoothed.
    public int Smoothing { get; set; } = 5;
    public double RpmStep { get; set; } = 100;

    // AFR
    /// The channel the AFR comes from: "afr" (a wideband on its own port or an aux channel), "o2_v", "egr_in_v", "b6_in_v", "serin1"...
    public string AfrChannel { get; set; } = "afr";
    /// The channel is volts: AFR = at 0 V + (at 5 V - at 0 V) x V / 5. Else it is an AFR already.
    public bool AfrFromVolts { get; set; }
    public double AfrAt0V { get; set; } = 10;
    public double AfrAt5V { get; set; } = 20;
    public double AfrOffset { get; set; }

    // triggers
    public List<DynoTrigger> Start { get; set; } = [new() { Channel = "tps_pct", Op = ">", Value = 90 }];
    /// The key that starts and ends a run by hand (or, when a start condition is "Hotkey pressed", gets it ready).
    public string HotKey { get; set; } = "Space";
    /// True: every start condition must hold; false: any one is enough.
    public bool StartAll { get; set; } = true;
    public List<DynoTrigger> Stop { get; set; } = [new() { Channel = "tps_pct", Op = "<", Value = 80 }];
    public bool StopAll { get; set; }
    /// A run shorter than this is thrown away (a stab of the throttle).
    public double MinRunS { get; set; } = 1.0;
    /// One shot: after a run, auto start goes off - one pull is logged, then it stops and waits while the run is looked at (Auto start arms it again). Off: it waits for the next pull straight away.
    public bool OneShot { get; set; } = true;
    /// Channels drawn under the curves against rpm.
    public List<string> Overlays { get; set; } = ["afr"];

    public DynoProfile Clone() => JsonSerializer.Deserialize<DynoProfile>(JsonSerializer.Serialize(this, VirtualDyno.Json), VirtualDyno.Json)!;
}

/// One reading during a run.
public sealed class DynoSample
{
    public double T { get; set; }
    public double Rpm { get; set; }
    public double? Kmh { get; set; }
    public double? Tps { get; set; }
    public double? MapKpa { get; set; }
    public double? BaroKpa { get; set; }
    public double? IatC { get; set; }
    public double? Gear { get; set; }
    /// Everything else logged (AFR, ignition, injector time...), by channel.
    public Dictionary<string, double> Ch { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public double? Value(string channel) => channel.ToLowerInvariant() switch
    {
        "rpm" => Rpm, "speed_kmh" or "speed" => Kmh, "tps_pct" or "tps" => Tps, "map_kpa" or "map" => MapKpa,
        "boost_psi" => MapKpa is double m ? (m - (BaroKpa ?? 101.3)) * 0.145038 : null,
        "baro_kpa" => BaroKpa, "iat_c" => IatC, "gear" => Gear, "t" => T,
        var c => Ch.TryGetValue(c, out var v) ? v : null,
    };

    public static DynoSample From(LogFrame f)
    {
        var s = new DynoSample
        {
            T = f.T, Rpm = f.Rpm ?? 0, Kmh = f.SpeedKmh, Tps = f.TpsPct, MapKpa = f.MapKpa, BaroKpa = f.BaroKpa, IatC = f.IatC, Gear = f.Get("gear"),
        };
        foreach (var k in LogFrame.Fields.Concat(["afr", "lambda", "egr_in_v", "b6_in_v", "knock"]))
            if (k is not ("rpm" or "speed_kmh" or "tps_pct" or "map_kpa" or "baro_kpa" or "iat_c") && f.Get(k) is double v) s.Ch[k] = v;
        for (int i = 1; i <= 8; i++) if (f.Get($"serin{i}") is double v) s.Ch[$"serin{i}"] = v;
        foreach (var (k, v) in f.Extra) s.Ch.TryAdd(k, v);
        return s;
    }
}

/// A recorded run: the readings, and the profile it was recorded with (so it can be worked out again, or with another).
public sealed class DynoRun
{
    public string Name { get; set; } = "";
    public DateTime When { get; set; } = DateTime.Now;
    public string Notes { get; set; } = "";
    public DynoProfile Profile { get; set; } = new();
    public List<DynoSample> Samples { get; set; } = [];
    /// How this run is drawn and worked out on the graph (right-click its line): null for the defaults.
    public DynoStyle? Style { get; set; }
}

/// One run's own settings on the graph: its colour and line, which curves show, and the sums done differently for it alone (another correction, its own smoothing or drivetrain loss). Null fields follow the dyno's settings.
public sealed class DynoStyle
{
    /// #RRGGBB, or empty for the next colour of the palette.
    public string Colour { get; set; } = "";
    public double Width { get; set; } = 2.2;
    public bool ShowPower { get; set; } = true;
    public bool ShowTorque { get; set; } = true;
    public bool Dashed { get; set; }
    public DynoCorrection? Correction { get; set; }
    public int? Smoothing { get; set; }
    public double? DrivetrainLossPct { get; set; }
    public double? RpmStep { get; set; }
    /// Power and torque scaled by this (a known offset between dynos, a calibration factor): 1 for none.
    public double Factor { get; set; } = 1;
    public DynoStyle Clone() => (DynoStyle)MemberwiseClone();
}

/// The dyno's settings that are the same for every profile (Settings > Dyno): how results are shown and worked out, where the AFR comes from, the hotkey. A profile keeps the car, the roller, the air on the day and the triggers.
public sealed class DynoSettings
{
    public bool ShowCrank { get; set; }
    public double DrivetrainLossPct { get; set; } = 15;
    public int Smoothing { get; set; } = 5;
    public double RpmStep { get; set; } = 100;
    public string XAxis { get; set; } = "rpm";
    public DynoCorrection Correction { get; set; } = DynoCorrection.SaeJ1349;
    /// Air temperature and pressure from the ECU's intake air and baro sensors when it logs them; else the profile's own.
    public bool AirFromEcu { get; set; } = true;
    public double HumidityPct { get; set; } = 40;
    public string AfrChannel { get; set; } = "afr";
    public bool AfrFromVolts { get; set; }
    public double AfrAt0V { get; set; } = 10;
    public double AfrAt5V { get; set; } = 20;
    public double AfrOffset { get; set; }
    public string HotKey { get; set; } = "Space";
    /// Auto start is on when the dyno opens.
    public bool ArmOnOpen { get; set; } = true;

    /// These settings onto a profile (a copy is worked out with them).
    public void ApplyTo(DynoProfile p)
    {
        p.ShowCrank = ShowCrank; p.DrivetrainLossPct = DrivetrainLossPct; p.Smoothing = Smoothing; p.RpmStep = RpmStep;
        p.Correction = Correction; p.AirFromEcu = AirFromEcu; p.HumidityPct = HumidityPct;
        p.AfrChannel = AfrChannel; p.AfrFromVolts = AfrFromVolts; p.AfrAt0V = AfrAt0V; p.AfrAt5V = AfrAt5V; p.AfrOffset = AfrOffset;
        p.HotKey = HotKey;
        p.PowerUnit = Units.Now.Power; p.TorqueUnit = Units.Now.Torque;
    }

    public DynoSettings Clone() => (DynoSettings)MemberwiseClone();
}

/// One point of a worked-out run.
public sealed record DynoPoint(double T, double Rpm, double Kmh, double WheelW, double CrankW, double TorqueNm, double CrankTorqueNm, double? Afr, Dictionary<string, double> Ch);

/// A run worked out: every point, the curve by rpm, and the peaks.
public sealed record DynoResult(List<DynoPoint> Points, List<DynoPoint> Curve, double PeakW, double PeakWRpm, double PeakNm, double PeakNmRpm,
                                double Correction, double KmhPer1000, string Note);

/// A car the profiles start from.
public sealed record DynoCarPreset(string Name, string Chassis, string Market, double Kg, double Cd, double FrontalM2);

/// A chassis dyno the profiles start from (example figures: use the maker's own).
public sealed record DynoRollerPreset(string Name, double Inertia, double DiameterM);

/// The virtual dyno's sums and its presets.
public static class VirtualDyno
{
    public static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter() }, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    const double G = 9.80665;

    /// Curb weights (kg) as the makers quote them, base trims with a manual gearbox; drag and frontal area typical for the body.
    public static readonly DynoCarPreset[] Cars =
    [
        new("Civic EF hatchback (88-91, JDM / EDM)", "EF", "JDM", 900, 0.34, 1.80),
        new("Civic EF DX hatchback (90-91, USDM)", "EF", "USDM", 979, 0.34, 1.80),
        new("Civic EF Si hatchback (88-91, USDM)", "EF", "USDM", 1000, 0.34, 1.80),
        new("CRX EF (88-91)", "EF", "all", 860, 0.32, 1.70),
        new("Civic EG6 SiR / VTi hatchback (92-95, JDM / EDM)", "EG", "JDM", 1040, 0.33, 1.85),
        new("Civic EG Si hatchback (92-95, USDM)", "EG", "USDM", 1055, 0.33, 1.85),
        new("Civic EG sedan (92-95)", "EG", "all", 1080, 0.32, 1.90),
        new("Civic EK9 Type R (97-00, JDM)", "EK", "JDM", 1050, 0.33, 1.90),
        new("Civic EK4 SiR / VTi hatchback (96-00, JDM / EDM)", "EK", "JDM", 1090, 0.33, 1.90),
        new("Civic EM1 Si coupe (99-00, USDM)", "EK", "USDM", 1185, 0.32, 1.92),
        new("Civic EK hatchback (96-00, USDM)", "EK", "USDM", 1040, 0.33, 1.90),
        new("Integra DA6 / DA9 hatchback (90-93)", "DA", "all", 1155, 0.33, 1.85),
        new("Integra DA sedan (90-93)", "DA", "all", 1183, 0.33, 1.88),
        new("Integra DB2 GS-R hatchback (92-93, USDM)", "DB", "USDM", 1205, 0.33, 1.85),
        new("Integra DB8 GS-R sedan (94-01, USDM)", "DB", "USDM", 1200, 0.33, 1.90),
        new("Integra DC2 GS-R hatchback (94-01, USDM)", "DC", "USDM", 1167, 0.32, 1.88),
        new("Integra DC2 LS / GS hatchback (94-01, USDM)", "DC", "USDM", 1199, 0.32, 1.88),
        new("Integra DC2 Type R (96-01, JDM)", "DC", "JDM", 1060, 0.32, 1.88),
        new("Integra DC2 Type R (97-01, USDM)", "DC", "USDM", 1197, 0.32, 1.88),
        new("Accord CB7 sedan (90-93, USDM)", "CB", "USDM", 1240, 0.34, 2.05),
        new("Accord CB coupe (90-93, USDM)", "CB", "USDM", 1280, 0.34, 2.00),
        new("Accord CD sedan (94-97)", "CD", "all", 1305, 0.33, 2.05),
        new("Accord CD coupe (94-97, USDM)", "CD", "USDM", 1280, 0.33, 2.00),
        new("Accord CL1 Euro R (00-02, JDM)", "CL", "JDM", 1330, 0.31, 2.08),
        new("Accord CL sedan (98-02, JDM / EDM)", "CL", "JDM", 1300, 0.31, 2.08),
        new("Accord CG sedan (98-02, USDM)", "CG", "USDM", 1346, 0.31, 2.10),
        new("Prelude BA4 / BA8 Si (88-91)", "BA", "all", 1165, 0.34, 1.85),
        new("Prelude BA Si 4WS (88-91)", "BA", "all", 1240, 0.34, 1.85),
        new("Prelude BB1 VTEC / Si VTEC (92-96)", "BB", "all", 1240, 0.33, 1.90),
        new("Prelude BB2 Si (92-96)", "BB", "all", 1270, 0.33, 1.90),
        new("Prelude BB6 base (97-01, USDM)", "BB", "USDM", 1340, 0.32, 1.92),
        new("Prelude BB6 Type SH (97-01, USDM)", "BB", "USDM", 1380, 0.32, 1.92),
        new("Prelude BB6 SiR (97-01, JDM)", "BB", "JDM", 1270, 0.32, 1.92),
    ];

    /// Example rollers: a single 48 inch drum and a lighter 30 inch twin-roller set. Check the inertia against your dyno's own sheet.
    public static readonly DynoRollerPreset[] Rollers =
    [
        new("48 in (1.22 m) single drum, heavy", 330, 1.2192),
        new("40 in (1.02 m) single drum", 180, 1.016),
        new("Twin 8.5 in rollers, light", 6, 0.216),
        new("Custom (type it in)", 100, 1.0),
    ];

    /// The trigger channels offered, with what each is.
    public static readonly (string Channel, string Label)[] TriggerChannels =
    [
        ("key", "Hotkey pressed"), ("tps_pct", "Throttle"), ("map_kpa", "MAP"), ("boost_psi", "Boost"),
        ("speed_kmh", "Speed"), ("rpm", "Engine rpm"), ("gear", "Gear"),
    ];

    /// The unit a trigger channel's value is kept in ("" for none): what the window converts to the units picked.
    public static string TriggerUnit(string channel) => channel switch
    {
        "tps_pct" => "%", "map_kpa" => "kPa", "boost_psi" => "psi g", "speed_kmh" => "km/h", "rpm" => "rpm", _ => "",
    };

    /// What a trigger on each channel may be set to: the lowest, the highest, the step, and the value a new one starts at.
    public static (double Min, double Max, double Step, double Start) TriggerRange(string channel) => channel switch
    {
        "tps_pct" => (0, 100, 1, 90),
        "map_kpa" => (10, 400, 1, 90),
        "boost_psi" => (-15, 45, 0.5, 2),
        "speed_kmh" => (0, 300, 1, 30),
        "rpm" => (0, 12500, 100, 2500),
        "gear" => (0, 6, 1, 3),
        _ => (0, 1, 1, 1),
    };

    /// The hotkeys the dyno offers (Space by default).
    public static readonly string[] HotKeys = ["Space", "Enter", "F9", "F10", "F11", "F12", "Insert", "Home", "End", "PageDown"];

    /// The AFR of a sample, through the profile's conversion.
    public static double? Afr(DynoSample s, DynoProfile p)
    {
        if (s.Value(p.AfrChannel) is not double v) return null;
        double afr = p.AfrFromVolts ? p.AfrAt0V + ((p.AfrAt5V - p.AfrAt0V) * v / 5) : v;
        return afr + p.AfrOffset;
    }

    /// The air density (kg/m³) from temperature, pressure and humidity.
    public static double AirDensity(double tempC, double kpa, double humidityPct)
    {
        double tK = tempC + 273.15;
        double psat = 0.61078 * Math.Exp(17.27 * tempC / (tempC + 237.3));      // kPa
        double pv = Math.Clamp(humidityPct, 0, 100) / 100 * psat;
        double pd = kpa - pv;
        return ((pd * 1000) / (287.058 * tK)) + ((pv * 1000) / (461.495 * tK));
    }

    /// The correction factor to standard air for this temperature, pressure and humidity.
    public static double CorrectionFactor(DynoCorrection c, double tempC, double kpa, double humidityPct)
    {
        double tK = tempC + 273.15;
        double psat = 0.61078 * Math.Exp(17.27 * tempC / (tempC + 237.3));
        double pd = kpa - (Math.Clamp(humidityPct, 0, 100) / 100 * psat);
        return c switch
        {
            DynoCorrection.SaeJ1349 => (1.18 * (99 / pd) * Math.Sqrt(tK / 298)) - 0.18,
            DynoCorrection.Din70020 => (101.3 / kpa) * Math.Sqrt(tK / 293),
            DynoCorrection.SaeJ607 => (101.325 / kpa) * Math.Sqrt(tK / 288.6),
            DynoCorrection.Ece => Math.Pow(99 / pd, 1.2) * Math.Pow(tK / 298, 0.6),
            _ => 1,
        };
    }

    public static double ToPower(double w, string unit) => unit switch { "kW" => w / 1000, "PS" => w / 735.499, _ => w / 745.7 };
    public static double ToTorque(double nm, string unit) => unit switch { "lbft" or "lb-ft" => nm * 0.737562, "kgf·m" => nm / 9.80665, _ => nm };
    public static string TorqueLabel(string unit) => unit is "lbft" or "lb-ft" ? "lb-ft" : unit;

    /// Profiles to start from (Settings > Dyno > Restore the default profiles puts these back).
    public static List<DynoProfile> DefaultProfiles()
    {
        DynoProfile Strip(string name, string car)
        {
            var c = Cars.First(x => x.Name.StartsWith(car, StringComparison.Ordinal));
            return new DynoProfile { Name = name, Mode = DynoMode.Strip, Car = c.Name, VehicleKg = c.Kg, DragCd = c.Cd, FrontalM2 = c.FrontalM2 };
        }
        DynoProfile Roller(string name, string roller)
        {
            var r = Rollers.First(x => x.Name.StartsWith(roller, StringComparison.Ordinal));
            return new DynoProfile
            {
                Name = name, Mode = DynoMode.Inertia, Car = "", RollerInertia = r.Inertia, RollerDiameterM = r.DiameterM,
                Start = [new() { Channel = "tps_pct", Op = ">", Value = 90 }, new() { Channel = "rpm", Op = ">", Value = 2500 }],
            };
        }
        return
        [
            Strip("Strip - Civic EG6 SiR", "Civic EG6"),
            Strip("Strip - Civic EK9 Type R", "Civic EK9"),
            Strip("Strip - Integra DC2 Type R (JDM)", "Integra DC2 Type R (96"),
            Strip("Strip - CRX EF", "CRX EF"),
            Roller("Inertia - 48 in drum", "48 in"),
            Roller("Inertia - twin 8.5 in rollers", "Twin 8.5"),
        ];
    }

    /// Every run in a log, found with the profile's triggers as the logger would have found them live (a hotkey cannot fire in a recorded log: a "Hotkey pressed" condition counts as held). Each is the readings of one pull.
    public static List<List<DynoSample>> RunsIn(IEnumerable<LogFrame> frames, DynoProfile p)
    {
        var t = new DynoTriggers { Armed = true, ArmAgain = true, KeyDown = true };
        var found = new List<List<DynoSample>>();
        foreach (var f in frames)
        {
            if (f.Rpm == null) continue;
            t.KeyDown = true;
            if (t.Feed(DynoSample.From(f), p) is { } run) found.Add(run);
        }
        return found;
    }

    /// Work a run out: the speed (and from it the acceleration) smoothed over a window, the force that took, the power and torque, the correction, and the curve by rpm step.
    public static DynoResult Compute(IReadOnlyList<DynoSample> raw, DynoProfile p)
    {
        var s = raw.Where(x => x.Rpm > 300).OrderBy(x => x.T).ToList();
        for (int i = s.Count - 1; i > 0; i--) if (s[i].T <= s[i - 1].T) s.RemoveAt(i);
        if (s.Count < 5) return new([], [], 0, 0, 0, 0, 1, 0, "not enough readings yet");

        // the speed: the rpm with the ratio the run shows against the speed sensor, the sensor alone, or a fixed ratio
        string note = "";
        double kPer = p.KmhPer1000;          // km/h per 1000 rpm
        var speed = p.Speed;
        if (speed == DynoSpeed.Learned)
        {
            var pairs = s.Where(x => x.Kmh is > 8 && x.Rpm > 1500).ToList();
            if (pairs.Count >= 5)
            {
                double num = pairs.Sum(x => x.Kmh!.Value * x.Rpm), den = pairs.Sum(x => x.Rpm * x.Rpm);
                kPer = num / den * 1000;
                note = $"speed from rpm x {kPer:0.00} km/h per 1000 rpm, learned from the speed sensor";
            }
            else { speed = s.Count(x => x.Kmh is > 0) > s.Count / 2 ? DynoSpeed.Sensor : DynoSpeed.Fixed; note = "too little road speed logged to learn the ratio"; }
        }
        double V(DynoSample x) => speed == DynoSpeed.Sensor ? (x.Kmh ?? 0) / 3.6 : x.Rpm / 1000 * kPer / 3.6;
        if (speed == DynoSpeed.Fixed && note.Length == 0) note = $"speed from rpm x {kPer:0.00} km/h per 1000 rpm";
        if (speed == DynoSpeed.Sensor) note = "speed from the road speed sensor";

        // the mass the engine accelerates, and what holds it back
        double massKg = p.Mode == DynoMode.Strip
            ? (p.VehicleKg + p.DriverKg + p.FuelKg) * (1 + (p.RotatingPct / 100))
            : (p.RollerInertia / Math.Pow(Math.Max(0.01, p.RollerDiameterM / 2), 2)) + p.WheelsKg;
        double air = AirC(s, p), kpa = AirKpa(s, p);
        double rho = AirDensity(air, kpa, p.HumidityPct);
        double cf = CorrectionFactor(p.Correction, air, kpa, p.HumidityPct);
        double loss = Math.Clamp(p.DrivetrainLossPct, 0, 60) / 100;

        // the slope of the speed over a window either side of each reading (a straight line through them): its value and its slope
        double win = 0.12 + (Math.Clamp(p.Smoothing, 0, 10) * 0.08);
        var pts = new List<DynoPoint>(s.Count);
        int lo = 0, hi = 0;
        for (int i = 0; i < s.Count; i++)
        {
            double t0 = s[i].T;
            while (s[lo].T < t0 - (win / 2)) lo++;
            while (hi + 1 < s.Count && s[hi + 1].T <= t0 + (win / 2)) hi++;
            int n = hi - lo + 1;
            if (n < 3) continue;
            double st = 0, sv = 0, stt = 0, stv = 0;
            for (int k = lo; k <= hi; k++) { double t = s[k].T - t0, v = V(s[k]); st += t; sv += v; stt += t * t; stv += t * v; }
            double den = (n * stt) - (st * st);
            if (den <= 1e-12) continue;
            double a = ((n * stv) - (st * sv)) / den;
            double v0 = (sv - (a * st)) / n;
            double resist = p.Mode == DynoMode.Strip
                ? (0.5 * rho * p.DragCd * p.FrontalM2 * v0 * v0) + (p.RollingCrr * (p.VehicleKg + p.DriverKg + p.FuelKg) * G)
                : p.ParasiticN;
            double wheelW = ((massKg * a) + resist) * v0 * cf;
            double omega = s[i].Rpm * 2 * Math.PI / 60;
            double torque = omega > 1 ? wheelW / omega : 0;
            var ch = new Dictionary<string, double>(s[i].Ch, StringComparer.OrdinalIgnoreCase);
            foreach (var k in new[] { "map_kpa", "tps_pct", "boost_psi", "speed_kmh", "gear", "iat_c" })
                if (s[i].Value(k) is double cv) ch[k] = cv;
            pts.Add(new DynoPoint(s[i].T, s[i].Rpm, v0 * 3.6, wheelW, wheelW / (1 - loss), torque, torque / (1 - loss), Afr(s[i], p), ch));
        }
        if (pts.Count == 0) return new([], [], 0, 0, 0, 0, cf, kPer, note);

        // the curve: the points in steps of rpm, averaged, then a light smoothing across the steps
        double step = Math.Max(10, p.RpmStep);
        var curve = pts.GroupBy(x => Math.Round(x.Rpm / step) * step).OrderBy(g => g.Key)
            .Select(g =>
            {
                var ch = g.SelectMany(x => x.Ch).GroupBy(kv => kv.Key, StringComparer.OrdinalIgnoreCase)
                          .ToDictionary(k => k.Key, k => k.Average(kv => kv.Value), StringComparer.OrdinalIgnoreCase);
                var afrs = g.Where(x => x.Afr != null).Select(x => x.Afr!.Value).ToList();
                return new DynoPoint(g.Average(x => x.T), g.Key, g.Average(x => x.Kmh), g.Average(x => x.WheelW), g.Average(x => x.CrankW),
                                     g.Average(x => x.TorqueNm), g.Average(x => x.CrankTorqueNm), afrs.Count > 0 ? afrs.Average() : null, ch);
            }).ToList();
        if (p.Smoothing > 0 && curve.Count > 4)
        {
            var sm = new List<DynoPoint>(curve.Count);
            for (int i = 0; i < curve.Count; i++)
            {
                var w = curve.Skip(Math.Max(0, i - 1)).Take(i == 0 || i == curve.Count - 1 ? 2 : 3).ToList();
                sm.Add(curve[i] with
                {
                    WheelW = w.Average(x => x.WheelW), CrankW = w.Average(x => x.CrankW),
                    TorqueNm = w.Average(x => x.TorqueNm), CrankTorqueNm = w.Average(x => x.CrankTorqueNm),
                });
            }
            curve = sm;
        }
        var pk = curve.MaxBy(x => x.WheelW)!;
        var tq = curve.MaxBy(x => x.TorqueNm)!;
        return new DynoResult(pts, curve, pk.WheelW, pk.Rpm, tq.TorqueNm, tq.Rpm, cf, kPer, note);
    }

    static double AirC(List<DynoSample> s, DynoProfile p)
    {
        if (p.AirFromEcu && s.Where(x => x.IatC != null).Select(x => x.IatC!.Value).ToList() is { Count: > 0 } t) return t.Average();
        return p.AirC;
    }

    static double AirKpa(List<DynoSample> s, DynoProfile p)
    {
        if (p.AirFromEcu && s.Where(x => x.BaroKpa is > 50 and < 115).Select(x => x.BaroKpa!.Value).ToList() is { Count: > 0 } b) return b.Average();
        return p.BaroKpa;
    }
}

/// Watches the readings for the start and stop of a run, as the profile's triggers say.
public sealed class DynoTriggers
{
    public enum State { Waiting, Running }
    public State Now { get; private set; } = State.Waiting;
    public List<DynoSample> Current { get; } = [];
    public bool KeyDown { get; set; }
    /// Must be armed for a run to start (the window arms it; a finished run disarms it until armed again, when ArmAgain is off).
    public bool Armed { get; set; } = true;
    public bool ArmAgain { get; set; } = true;

    /// A finished run (long enough to keep), or null.
    public List<DynoSample>? Feed(DynoSample s, DynoProfile p)
    {
        bool Holds(List<DynoTrigger> list, bool all) => list.Count > 0 && (all ? list.All(t => t.Test(s, KeyDown)) : list.Any(t => t.Test(s, KeyDown)));
        if (Now == State.Waiting)
        {
            if (Armed && Holds(p.Start, p.StartAll)) { Now = State.Running; Current.Clear(); Current.Add(s); }
            return null;
        }
        Current.Add(s);
        // stopped by a stop condition, or by the start conditions no longer holding when there are no stop conditions
        bool stop = p.Stop.Count > 0 ? Holds(p.Stop, p.StopAll) : !Holds(p.Start, p.StartAll);
        if (!stop) return null;
        Now = State.Waiting;
        KeyDown = false;
        if (!ArmAgain) Armed = false;
        var run = Current.ToList();
        Current.Clear();
        return run.Count > 2 && run[^1].T - run[0].T >= p.MinRunS ? run : null;
    }

    public void Cancel() { Now = State.Waiting; Current.Clear(); KeyDown = false; }

    /// Start a run now, by hand (the button or the hotkey): the next readings are its first.
    public void StartNow() { Now = State.Running; Current.Clear(); }

    /// End the run now and hand it over (null when there was none, or it was too short).
    public List<DynoSample>? EndNow(DynoProfile p)
    {
        if (Now != State.Running) return null;
        Now = State.Waiting;
        KeyDown = false;
        var run = Current.ToList();
        Current.Clear();
        return run.Count > 2 && run[^1].T - run[0].T >= p.MinRunS ? run : null;
    }

    /// Each start or end condition with whether it holds for this reading: what the window shows while it waits.
    public IEnumerable<(DynoTrigger Trigger, bool Holds)> Check(DynoSample s, List<DynoTrigger> list) => list.Select(t => (t, t.Test(s, KeyDown)));
}
