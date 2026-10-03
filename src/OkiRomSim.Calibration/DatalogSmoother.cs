// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Calibration;

/// Takes the noise out of datalog values. For each channel it looks at the last few readings together: a reading far from the middle one (the median) of them - 6000 rpm, 28 rpm, 6000 rpm, a spike on the line rather than the engine - is dropped, and what is left is blended (averaged) into the value shown and recorded. A real change gets through as soon as the next reading agrees with it. The raw frame is left as it came.
public sealed class DatalogSmoother
{
    /// Off: frames pass untouched.
    public bool Enabled { get; set; }

    /// Readings looked at together (3 or more: with fewer a spike cannot be told from a change).
    public int Frames { get => _frames; set => _frames = Math.Clamp(value, 3, 15); }
    int _frames = 3;

    /// A reading further than this (percent of the middle reading, or the channel's floor, whichever is more) from the middle one is a spike.
    public double SpikePercent { get; set; } = 25;

    /// Blend: the good readings averaged. Off: the newest good reading (spikes dropped, nothing averaged).
    public bool Blend { get; set; } = true;

    /// Channels left alone (a narrowband O2 switching rich-lean is meant to jump about).
    public HashSet<string> Skip { get; } = new(StringComparer.OrdinalIgnoreCase) { "o2_v" };

    /// Readings dropped as spikes since the last Reset.
    public long Dropped { get; private set; }

    readonly Dictionary<string, List<double>> _history = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, double> _last = new(StringComparer.OrdinalIgnoreCase);

    /// The smallest change on a channel ever taken for a spike: small readings (a closed throttle, idle ignition) swing by more than a percentage of themselves without being noise.
    public static readonly Dictionary<string, double> Floors = new(StringComparer.OrdinalIgnoreCase)
    {
        ["rpm"] = 250, ["map_kpa"] = 8, ["tps_pct"] = 5, ["ect_c"] = 3, ["iat_c"] = 3, ["batt_v"] = 0.6, ["speed_kmh"] = 8,
        ["baro_kpa"] = 3, ["inj_ms"] = 0.8, ["ign_deg"] = 4, ["ign_table_deg"] = 4, ["afr"] = 0.8, ["lambda"] = 0.06,
    };

    /// Start again (a new connection, a new log): the readings before do not belong with the next ones.
    public void Reset() { _history.Clear(); _last.Clear(); Dropped = 0; }

    public void Apply(LogFrame f)
    {
        if (!Enabled) return;
        foreach (var ch in LogFrame.Fields)
        {
            if (ch is "vtec" or "fuel_pump") continue;
            if (f.Get(ch) is double v) Put(f, ch, v);
        }
        foreach (var ch in f.Extra.Keys.ToList()) Put(f, ch, f.Extra[ch]);
    }

    void Put(LogFrame f, string ch, double v)
    {
        if (Skip.Contains(ch) || double.IsNaN(v) || double.IsInfinity(v)) return;
        if (!_history.TryGetValue(ch, out var h)) _history[ch] = h = [];
        h.Add(v);
        while (h.Count > _frames) h.RemoveAt(0);      // (a loop: with fewer frames asked for, the history shrinks to that now, not never)
        if (h.Count < 3) { _last[ch] = v; return; }        // too few to tell a spike yet: as it came
        // the middle reading: the few readings sorted in a buffer on the stack (this runs for every channel of every frame; a LINQ sort allocated twice each time)
        Span<double> sorted = stackalloc double[15];
        sorted = sorted[..h.Count];
        for (int i = 0; i < h.Count; i++) sorted[i] = h[i];
        sorted.Sort();
        double mid = sorted.Length % 2 == 1 ? sorted[sorted.Length / 2] : (sorted[(sorted.Length / 2) - 1] + sorted[sorted.Length / 2]) / 2;
        double limit = Math.Max(Floors.GetValueOrDefault(ch, 0.5), Math.Abs(mid) * SpikePercent / 100);
        bool newestGood = Math.Abs(v - mid) <= limit;
        if (!newestGood) Dropped++;
        double sum = 0; int n = 0; double newest = double.NaN;
        foreach (var x in h)
            if (Math.Abs(x - mid) <= limit) { sum += x; n++; newest = x; }
        double result = n == 0 ? _last.GetValueOrDefault(ch, v) : Blend ? sum / n : newest;
        result = Math.Round(result, 4);
        _last[ch] = result;
        f.Set(ch, result);
    }
}
