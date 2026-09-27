// Copyright (c) bmgjet. All rights reserved.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OkiRomSim.Calibration;

/// Where the needle (and each tick) points on a dial, as a direction in screen coordinates - x to the right, y downwards. The scale starts at the lower left, goes over the top and ends at the lower right, which is the way every tacho reads.
public static class Dial
{
    public const double StartAngle = Math.PI * 1.25, Sweep = Math.PI * 1.5;

    public static (double X, double Y) Direction(double fraction)
    {
        double a = StartAngle - (Sweep * Math.Clamp(fraction, 0, 1));
        return (Math.Cos(a), -Math.Sin(a));
    }
}

public enum GaugeKind
{
    /// Round dial with a needle.
    Dial,
    /// Horizontal bar that fills up.
    Bar,
    /// The reading as a big number.
    Number,
    /// A lamp that comes on past the warning level.
    Light,
    /// Line graph of the last few seconds.
    Graph,
    /// The same history drawn as bars.
    BarGraph,
    /// A digital-dash sweep: a thick arc that fills with the reading, the number big in the middle.
    Arc,
    /// A row of shift lights: green, then amber, then red as the reading climbs to the warning level (they flash past it).
    ShiftLights,
    /// A caption on its own: the label in large type, for headings on a dash.
    Text,
}

/// One gauge: which logged channel it shows, the range it covers, and where it sits on the dashboard. Saved as JSON, so a layout can be shared or kept with a project.
public sealed class GaugeSpec
{
    public GaugeKind Kind { get; set; } = GaugeKind.Dial;
    public string Channel { get; set; } = "rpm";
    public string Label { get; set; } = "";
    public string Unit { get; set; } = "";
    public double Min { get; set; }
    public double Max { get; set; } = 8000;
    /// Above this (or below it when `WarnBelow`) the gauge turns amber, and a light comes on. Null: no warning level (JSON has no NaN, so the absence is written as null).
    public double? Warn { get; set; }
    public bool WarnBelow { get; set; }
    public int Decimals { get; set; }
    public double X { get; set; }
    public double Y { get; set; }
    public double Width { get; set; } = 180;
    public double Height { get; set; } = 140;
    /// Seconds of history a graph shows.
    public double Seconds { get; set; } = 20;
    /// Marks around a dial.
    public int Ticks { get; set; } = 10;
    /// Colours as #RRGGBB; empty means the dark theme's own.
    public string FaceColour { get; set; } = "";
    public string AccentColour { get; set; } = "";
    public string TextColour { get; set; } = "";
    /// The background picture: drawn behind the whole gauge (a panel, a carbon weave, a logo). Full path to a png/jpg.
    public string ImagePath { get; set; } = "";
    public double ImageOpacity { get; set; } = 1;
    /// A picture on the dial face itself (inside the dial, under the scale and the needle; the reading area on the other kinds).
    public string FaceImagePath { get; set; } = "";
    /// How solid the face is, 0-1: its colour and its picture. Turn it down to let the background show through.
    public double FaceOpacity { get; set; } = 1;
    /// Where the reading comes from: "log" (the datalog) or the name of an external feed set up in Settings > Emulator & datalog (an HTTP endpoint or a JSON file).
    public string Source { get; set; } = "log";

    public GaugeSpec Clone() => (GaugeSpec)MemberwiseClone();
    public string Title => Label.Length > 0 ? Label : Channel;
}

/// A gauge that lives in its own floating window, and where that window was.
public sealed class GaugeWidget
{
    /// The gauges in the window, laid out as they were on the dashboard. A widget holds the whole collection that was on screen, not one gauge: a dashboard with a dial, a bar and a graph on it pops out as one window with all three in it, which is what you want floating over everything else while you drive.
    public List<GaugeSpec> Gauges { get; set; } = [];
    /// The single gauge older dashboards were saved with. Kept so a file written by an earlier build still opens; Specs() prefers Gauges.
    public GaugeSpec? Gauge { get; set; }
    public double X { get; set; } = 80;
    public double Y { get; set; } = 80;
    public double Width { get; set; } = 200;
    public double Height { get; set; } = 160;
    public bool Topmost { get; set; } = true;
    /// Rolled up to its title bar, or hidden altogether (Hide / Unhide), when the dashboard was saved.
    public bool Hidden { get; set; }
    /// Parented to the main window: it moves and minimizes with it, and X / Y are then pixels from the main window's top-left corner.
    public bool Parented { get; set; }

    /// What is in the window, whichever way the file was written.
    public List<GaugeSpec> Specs() => Gauges.Count > 0 ? Gauges : Gauge is { } g ? [g] : [];

    public string Title => Gauges.Count > 1 ? $"{Gauges.Count} gauges" : Specs().FirstOrDefault()?.Title ?? "gauges";
}

/// A saved dashboard.
public sealed class GaugeLayout
{
    public string Name { get; set; } = "dashboard";
    public List<GaugeSpec> Gauges { get; set; } = [];
    /// Gauges that were popped out into their own floating windows, with where each one sat, so they come back where they were the next time the program starts.
    public List<GaugeWidget> Widgets { get; set; } = [];

    static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public string ToJson() => JsonSerializer.Serialize(this, Json);
    public static GaugeLayout FromJson(string text) => JsonSerializer.Deserialize<GaugeLayout>(text, Json) ?? new GaugeLayout();
    public void Save(string path) => File.WriteAllText(path, ToJson());
    public static GaugeLayout Load(string path) => FromJson(File.ReadAllText(path));

    /// Ready-made dashboards, so there is something to start from.
    public static GaugeLayout Template(string name) => name switch
    {
        "Tacho" => new GaugeLayout
        {
            Name = "Tacho",
            Gauges =
            {
                new GaugeSpec { Kind = GaugeKind.Dial, Channel = "rpm", Label = "RPM", Min = 0, Max = 9000, Warn = 7600, X = 10, Y = 10, Width = 240, Height = 200 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "rpm", Label = "RPM", Unit = "rpm", Min = 0, Max = 9000, X = 264, Y = 10, Width = 150, Height = 80 },
            },
        },
        "Air / fuel" => new GaugeLayout
        {
            Name = "Air / fuel",
            Gauges =
            {
                new GaugeSpec { Kind = GaugeKind.Bar, Channel = "afr", Label = "AFR", Min = 10, Max = 20, Decimals = 1, Warn = 16, X = 10, Y = 10, Width = 260, Height = 70 },
                new GaugeSpec { Kind = GaugeKind.Graph, Channel = "afr", Label = "AFR", Min = 10, Max = 20, Decimals = 1, X = 10, Y = 88, Width = 400, Height = 140 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "inj_ms", Label = "Injector", Unit = "ms", Min = 0, Max = 25, Decimals = 2, X = 280, Y = 10, Width = 130, Height = 70 },
            },
        },
        "Engine" => new GaugeLayout
        {
            Name = "Engine",
            Gauges =
            {
                new GaugeSpec { Kind = GaugeKind.Dial, Channel = "rpm", Label = "RPM", Min = 0, Max = 9000, Warn = 7600, X = 10, Y = 10, Width = 200, Height = 170 },
                new GaugeSpec { Kind = GaugeKind.Dial, Channel = "map_kpa", Label = "MAP", Unit = "kPa", Min = 0, Max = 250, X = 216, Y = 10, Width = 200, Height = 170 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "ect_c", Label = "Coolant", Unit = "°C", Min = -20, Max = 140, Warn = 105, Decimals = 1, X = 10, Y = 188, Width = 130, Height = 70 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "tps_pct", Label = "Throttle", Unit = "%", Min = 0, Max = 100, Decimals = 0, X = 146, Y = 188, Width = 130, Height = 70 },
                new GaugeSpec { Kind = GaugeKind.Light, Channel = "vtec", Label = "VTEC", Min = 0, Max = 1, Warn = 0.5, X = 282, Y = 188, Width = 134, Height = 70 },
            },
        },
        "Wideband tuning" => new GaugeLayout
        {
            Name = "Wideband tuning",
            Gauges =
            {
                new GaugeSpec { Kind = GaugeKind.Graph, Channel = "afr", Label = "AFR", Min = 10, Max = 20, Decimals = 1, Seconds = 30, X = 10, Y = 10, Width = 430, Height = 150 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "afr", Label = "AFR", Min = 10, Max = 20, Decimals = 2, Warn = 16, X = 446, Y = 10, Width = 140, Height = 90 },
                new GaugeSpec { Kind = GaugeKind.Bar, Channel = "tps_pct", Label = "Throttle", Unit = "%", Min = 0, Max = 100, X = 10, Y = 168, Width = 280, Height = 70 },
                new GaugeSpec { Kind = GaugeKind.Bar, Channel = "map_kpa", Label = "Load", Unit = "kPa", Min = 0, Max = 250, X = 296, Y = 168, Width = 290, Height = 70 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "inj_ms", Label = "Injector", Unit = "ms", Min = 0, Max = 25, Decimals = 2, X = 446, Y = 106, Width = 140, Height = 56 },
            },
        },
        "Boost" => new GaugeLayout
        {
            Name = "Boost",
            Gauges =
            {
                new GaugeSpec { Kind = GaugeKind.Dial, Channel = "map_kpa", Label = "Boost", Unit = "kPa", Min = 0, Max = 250, Warn = 200, Ticks = 10, X = 10, Y = 10, Width = 220, Height = 190 },
                new GaugeSpec { Kind = GaugeKind.BarGraph, Channel = "map_kpa", Label = "Load history", Min = 0, Max = 250, Seconds = 25, X = 236, Y = 10, Width = 340, Height = 120 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "rpm", Label = "RPM", Min = 0, Max = 9000, X = 236, Y = 138, Width = 160, Height = 62 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "ign_deg", Label = "Timing", Unit = "°", Min = -10, Max = 50, Decimals = 1, X = 402, Y = 138, Width = 174, Height = 62 },
            },
        },
        "Knock watch" => new GaugeLayout
        {
            Name = "Knock watch",
            Gauges =
            {
                new GaugeSpec { Kind = GaugeKind.Light, Channel = "knock", Label = "KNOCK", Min = 0, Max = 5, Warn = 1, X = 10, Y = 10, Width = 150, Height = 100 },
                new GaugeSpec { Kind = GaugeKind.Graph, Channel = "knock", Label = "Knock", Min = 0, Max = 5, Decimals = 2, Seconds = 30, X = 166, Y = 10, Width = 380, Height = 130 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "ign_deg", Label = "Timing", Unit = "°", Min = -10, Max = 50, Decimals = 1, X = 10, Y = 118, Width = 150, Height = 66 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "ect_c", Label = "Coolant", Unit = "°C", Min = -20, Max = 140, Warn = 105, Decimals = 1, X = 166, Y = 148, Width = 180, Height = 66 },
            },
        },
        "Warm-up" => new GaugeLayout
        {
            Name = "Warm-up",
            Gauges =
            {
                new GaugeSpec { Kind = GaugeKind.Dial, Channel = "ect_c", Label = "Coolant", Unit = "°C", Min = -20, Max = 140, Warn = 105, X = 10, Y = 10, Width = 200, Height = 170 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "iat_c", Label = "Intake", Unit = "°C", Min = -20, Max = 100, Decimals = 1, X = 216, Y = 10, Width = 150, Height = 80 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "batt_v", Label = "Battery", Unit = "V", Min = 8, Max = 16, Decimals = 2, Warn = 11.5, WarnBelow = true, X = 216, Y = 96, Width = 150, Height = 84 },
                new GaugeSpec { Kind = GaugeKind.Graph, Channel = "rpm", Label = "Idle", Min = 0, Max = 3000, Seconds = 60, X = 10, Y = 188, Width = 356, Height = 120 },
            },
        },
        "Simulator" => new GaugeLayout
        {
            Name = "Simulator",
            Gauges =
            {
                new GaugeSpec { Kind = GaugeKind.Dial, Channel = "rpm", Label = "RPM", Min = 0, Max = 9000, Warn = 7600, X = 10, Y = 10, Width = 200, Height = 170 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "inj_ms", Label = "Injector", Unit = "ms", Min = 0, Max = 25, Decimals = 2, X = 216, Y = 10, Width = 150, Height = 80 },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "ign_deg", Label = "Timing", Unit = "°", Min = -10, Max = 50, Decimals = 1, X = 216, Y = 96, Width = 150, Height = 84 },
                new GaugeSpec { Kind = GaugeKind.Light, Channel = "vtec", Label = "VTEC", Min = 0, Max = 1, Warn = 0.5, X = 372, Y = 10, Width = 130, Height = 80 },
                new GaugeSpec { Kind = GaugeKind.Light, Channel = "fuel_pump", Label = "PUMP", Min = 0, Max = 1, Warn = 0.5, X = 372, Y = 96, Width = 130, Height = 84 },
            },
        },
        // ---- digital dashes: black glass, arc sweeps, shift lights and big numbers
        "Digital dash - race" => new GaugeLayout
        {
            Name = "Digital dash - race",
            Gauges =
            {
                new GaugeSpec { Kind = GaugeKind.ShiftLights, Channel = "rpm", Label = "shift", Min = 5000, Max = 8200, Warn = 7800, Ticks = 12, X = 10, Y = 10, Width = 620, Height = 36, FaceColour = "#050608" },
                new GaugeSpec { Kind = GaugeKind.Arc, Channel = "rpm", Label = "RPM", Min = 0, Max = 9000, Warn = 7600, X = 10, Y = 52, Width = 300, Height = 250, FaceColour = "#050608", AccentColour = "#27d3ff" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "speed_kmh", Label = "km/h", Min = 0, Max = 300, X = 318, Y = 52, Width = 150, Height = 120, FaceColour = "#050608", TextColour = "#ffffff" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "gear", Label = "GEAR", Min = 0, Max = 6, X = 476, Y = 52, Width = 154, Height = 120, FaceColour = "#050608", TextColour = "#ffd23f" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "afr", Label = "AFR", Min = 10, Max = 20, Decimals = 1, Warn = 15.5, X = 318, Y = 180, Width = 100, Height = 60, FaceColour = "#050608" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "ect_c", Label = "WATER", Unit = "°C", Min = -20, Max = 140, Warn = 105, X = 424, Y = 180, Width = 100, Height = 60, FaceColour = "#050608" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "batt_v", Label = "VOLTS", Min = 8, Max = 16, Decimals = 1, Warn = 11.5, WarnBelow = true, X = 530, Y = 180, Width = 100, Height = 60, FaceColour = "#050608" },
                new GaugeSpec { Kind = GaugeKind.Bar, Channel = "tps_pct", Label = "THROTTLE", Unit = "%", Min = 0, Max = 100, X = 318, Y = 246, Width = 312, Height = 56, FaceColour = "#050608", AccentColour = "#4ec97a" },
            },
        },
        "Digital dash - street" => new GaugeLayout
        {
            Name = "Digital dash - street",
            Gauges =
            {
                new GaugeSpec { Kind = GaugeKind.Arc, Channel = "rpm", Label = "RPM x1000", Min = 0, Max = 9000, Warn = 7600, X = 10, Y = 10, Width = 260, Height = 230, FaceColour = "#0b0d12", AccentColour = "#ff8a3d" },
                new GaugeSpec { Kind = GaugeKind.Arc, Channel = "speed_kmh", Label = "km/h", Min = 0, Max = 260, X = 380, Y = 10, Width = 260, Height = 230, FaceColour = "#0b0d12", AccentColour = "#ff8a3d" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "gear", Label = "GEAR", Min = 0, Max = 6, X = 276, Y = 20, Width = 98, Height = 100, FaceColour = "#0b0d12", TextColour = "#ffffff" },
                new GaugeSpec { Kind = GaugeKind.Light, Channel = "vtec", Label = "VTEC", Min = 0, Max = 1, Warn = 0.5, X = 276, Y = 126, Width = 98, Height = 56, FaceColour = "#0b0d12", AccentColour = "#ffd23f" },
                new GaugeSpec { Kind = GaugeKind.Bar, Channel = "ect_c", Label = "TEMP", Unit = "°C", Min = 40, Max = 120, Warn = 105, X = 10, Y = 246, Width = 310, Height = 54, FaceColour = "#0b0d12", AccentColour = "#27d3ff" },
                new GaugeSpec { Kind = GaugeKind.Bar, Channel = "batt_v", Label = "BATTERY", Unit = "V", Min = 10, Max = 15, Decimals = 1, Warn = 11.5, WarnBelow = true, X = 330, Y = 246, Width = 310, Height = 54, FaceColour = "#0b0d12", AccentColour = "#27d3ff" },
            },
        },
        "Digital dash - drag" => new GaugeLayout
        {
            Name = "Digital dash - drag",
            Gauges =
            {
                new GaugeSpec { Kind = GaugeKind.ShiftLights, Channel = "rpm", Label = "shift", Min = 6000, Max = 8800, Warn = 8400, Ticks = 10, X = 10, Y = 10, Width = 560, Height = 44, FaceColour = "#000000" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "rpm", Label = "RPM", Min = 0, Max = 9500, Warn = 8400, X = 10, Y = 60, Width = 360, Height = 150, FaceColour = "#000000", TextColour = "#ffffff" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "gear", Label = "GEAR", Min = 0, Max = 6, X = 376, Y = 60, Width = 194, Height = 150, FaceColour = "#000000", TextColour = "#ff3b3b" },
                new GaugeSpec { Kind = GaugeKind.Graph, Channel = "rpm", Label = "RPM trace", Min = 0, Max = 9500, Seconds = 12, X = 10, Y = 216, Width = 360, Height = 110, FaceColour = "#000000", AccentColour = "#ff3b3b" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "map_kpa", Label = "BOOST", Unit = "kPa", Min = 0, Max = 300, X = 376, Y = 216, Width = 194, Height = 52, FaceColour = "#000000" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "afr", Label = "AFR", Min = 10, Max = 20, Decimals = 1, Warn = 13.2, X = 376, Y = 274, Width = 194, Height = 52, FaceColour = "#000000" },
            },
        },
        "Digital dash - track day" => new GaugeLayout
        {
            Name = "Digital dash - track day",
            Gauges =
            {
                new GaugeSpec { Kind = GaugeKind.Text, Channel = "rpm", Label = "TRACK", X = 10, Y = 10, Width = 620, Height = 34, FaceColour = "#101418", TextColour = "#27d3ff" },
                new GaugeSpec { Kind = GaugeKind.Arc, Channel = "rpm", Label = "RPM", Min = 0, Max = 9000, Warn = 7800, X = 10, Y = 50, Width = 240, Height = 210, FaceColour = "#101418", AccentColour = "#7ad96a" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "speed_kmh", Label = "km/h", Min = 0, Max = 300, X = 256, Y = 50, Width = 180, Height = 100, FaceColour = "#101418" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "gear", Label = "GEAR", Min = 0, Max = 6, X = 442, Y = 50, Width = 188, Height = 100, FaceColour = "#101418", TextColour = "#ffd23f" },
                new GaugeSpec { Kind = GaugeKind.Graph, Channel = "afr", Label = "AFR", Min = 10, Max = 20, Decimals = 1, Seconds = 30, X = 256, Y = 156, Width = 374, Height = 104, FaceColour = "#101418", AccentColour = "#27d3ff" },
                new GaugeSpec { Kind = GaugeKind.Bar, Channel = "ect_c", Label = "WATER", Unit = "°C", Min = 40, Max = 120, Warn = 105, X = 10, Y = 266, Width = 200, Height = 54, FaceColour = "#101418" },
                new GaugeSpec { Kind = GaugeKind.Bar, Channel = "iat_c", Label = "INTAKE", Unit = "°C", Min = 0, Max = 80, Warn = 55, X = 216, Y = 266, Width = 200, Height = 54, FaceColour = "#101418" },
                new GaugeSpec { Kind = GaugeKind.Light, Channel = "knock", Label = "KNOCK", Min = 0, Max = 5, Warn = 1, X = 422, Y = 266, Width = 100, Height = 54, FaceColour = "#101418" },
                new GaugeSpec { Kind = GaugeKind.Light, Channel = "vtec", Label = "VTEC", Min = 0, Max = 1, Warn = 0.5, X = 528, Y = 266, Width = 102, Height = 54, FaceColour = "#101418", AccentColour = "#ffd23f" },
            },
        },
        "Digital dash - minimal" => new GaugeLayout
        {
            Name = "Digital dash - minimal",
            Gauges =
            {
                new GaugeSpec { Kind = GaugeKind.Arc, Channel = "rpm", Label = "RPM", Min = 0, Max = 9000, Warn = 7600, X = 10, Y = 10, Width = 220, Height = 200, FaceColour = "#000000", AccentColour = "#ffffff" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "speed_kmh", Label = "km/h", Min = 0, Max = 300, X = 236, Y = 10, Width = 170, Height = 96, FaceColour = "#000000", TextColour = "#ffffff" },
                new GaugeSpec { Kind = GaugeKind.Number, Channel = "afr", Label = "AFR", Min = 10, Max = 20, Decimals = 1, X = 236, Y = 112, Width = 170, Height = 98, FaceColour = "#000000", TextColour = "#ffffff" },
            },
        },
        _ => new GaugeLayout { Name = "empty" },
    };

    public static readonly string[] Templates =
        { "Tacho", "Air / fuel", "Engine", "Wideband tuning", "Boost", "Knock watch", "Warm-up", "Simulator",
          "Digital dash - race", "Digital dash - street", "Digital dash - drag", "Digital dash - track day", "Digital dash - minimal" };
}
