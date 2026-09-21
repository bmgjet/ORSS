namespace OkiRomSim.Calibration;

/// How a logged channel becomes a value in the table: straight through, or a straight line between two voltages (a wideband on an analog input, a knock box, anything else wired in).
public sealed class ChannelScale
{
    /// Channel of the log frame ("afr", "lambda", "o2_v", an aux channel's name...).
    public string Channel = "afr";
    /// Scale a voltage between these two readings; leave Volts false to use the channel as it is.
    public bool Volts;
    public double AtZeroVolts = 10, AtFiveVolts = 20;
    /// Lambda is turned into AFR with this stoichiometric ratio (petrol 14.7, E85 9.8).
    public double Stoich = 14.7;
    /// What the controller really means: a curve of measured -> corrected, from Settings > Targets. Left empty, the reading is taken as it comes.
    public LookupCurve? Correction;

    public double? Value(LogFrame f)
    {
        if (f.Get(Channel) is not double v) return null;
        double value = Volts ? AtZeroVolts + (AtFiveVolts - AtZeroVolts) * Math.Clamp(v, 0, 5) / 5
                     : Channel.Equals("lambda", StringComparison.OrdinalIgnoreCase) ? v * Stoich
                     : v;
        return Correction is { Any: true } c ? c.Apply(value) : value;
    }
}

/// A measured table: what the log says was happening in each cell of a map.
public sealed class LogTable
{
    public required ItemDef Item { get; init; }
    public required string Channel { get; init; }
    public double[] Mean = Array.Empty<double>();
    public double[] Min = Array.Empty<double>(), Max = Array.Empty<double>();
    public int[] Count = Array.Empty<int>();
    public double[] RowAxis = Array.Empty<double>(), ColAxis = Array.Empty<double>();
    public int Frames;
    public int Cells => Mean.Length;
}

/// A change a comparison suggests for one cell.
public readonly record struct CellChange(int Index, double From, double To, double Percent, int Samples);

/// The O2 / lambda and knock tables: what the log measured in each cell of a map, how far that is from the target, and the change that would close the gap.
/// Measured AFR leaner than target means the cell needs more fuel, in proportion: a cell running 15.4 against a target of 14.7 wants 4.8% more. Knock works the other way round - a cell over the threshold wants timing taken out, by a fixed amount per cell rather than a proportion.
public static class LogTables
{
    /// Average the channel into the cells of `item`, using the same axes the map uses.
    public static LogTable Build(DefinitionSet defs, byte[] rom, ItemDef item, IEnumerable<LogFrame> frames, ChannelScale scale,
                                 Func<LogFrame, bool>? filter = null)
    {
        int rows = Math.Max(1, item.Rows), cols = Math.Max(1, item.Cols), n = rows * cols;
        var rowAxis = item.RowAxis == null ? Enumerable.Range(0, rows).Select(i => (double)i).ToArray() : RomData.AxisValues(defs, rom, item.RowAxis, rows);
        var colAxis = item.ColAxis == null ? Enumerable.Range(0, cols).Select(i => (double)i).ToArray() : RomData.AxisValues(defs, rom, item.ColAxis, cols);
        var (_, rget) = LogOverlay.AxisInput(defs, item.RowAxis, true);
        var (_, cget) = LogOverlay.AxisInput(defs, item.ColAxis, false);
        var t = new LogTable
        {
            Item = item, Channel = scale.Channel, Mean = new double[n], Count = new int[n],
            Min = Enumerable.Repeat(double.MaxValue, n).ToArray(), Max = Enumerable.Repeat(double.MinValue, n).ToArray(),
            RowAxis = rowAxis, ColAxis = colAxis,
        };
        var sum = new double[n];
        filter ??= MapSide.Filter(item);       // a Lo map only takes the frames logged on the low cam
        foreach (var f in frames)
        {
            if (filter != null && !filter(f)) continue;
            if (scale.Value(f) is not double v || rget(f) is not double rv) continue;
            int r = rows == 1 ? 0 : LogOverlay.Nearest(rowAxis, rv);
            int c = cols == 1 ? 0 : cget(f) is double cv ? LogOverlay.Nearest(colAxis, cv) : -1;
            if (c < 0) continue;
            int i = r * cols + c;
            sum[i] += v; t.Count[i]++;
            t.Min[i] = Math.Min(t.Min[i], v); t.Max[i] = Math.Max(t.Max[i], v);
            t.Frames++;
        }
        for (int i = 0; i < n; i++)
        {
            t.Mean[i] = t.Count[i] > 0 ? sum[i] / t.Count[i] : double.NaN;
            if (t.Count[i] == 0) { t.Min[i] = double.NaN; t.Max[i] = double.NaN; }
        }
        return t;
    }

    /// How far each cell is from target, as the percentage of fuel it is short (positive) or over (negative). `target` is one AFR for the whole map, or a table of the same shape.
    public static double[] Difference(LogTable measured, double target, double[]? targetTable = null)
    {
        var d = new double[measured.Cells];
        for (int i = 0; i < d.Length; i++)
        {
            double want = targetTable != null && i < targetTable.Length && !double.IsNaN(targetTable[i]) ? targetTable[i] : target;
            d[i] = measured.Count[i] == 0 || want <= 0 || double.IsNaN(measured.Mean[i]) ? double.NaN : (measured.Mean[i] / want - 1) * 100;
        }
        return d;
    }

    /// The fuel changes that would bring each cell to target: only cells with enough samples, and no more than `limitPct` in one pass (a fraction of the gap when `authority` is below 1, the way a tuner would creep up on it).
    public static List<CellChange> FuelOffsets(DefinitionSet defs, byte[] rom, LogTable measured, double target,
                                               double[]? targetTable = null, int minSamples = 3, double limitPct = 15, double authority = 1.0)
    {
        var item = measured.Item;
        var cells = RomData.Read(defs, rom, item);
        var diff = Difference(measured, target, targetTable);
        var changes = new List<CellChange>();
        for (int i = 0; i < diff.Length && i < cells.Length; i++)
        {
            if (measured.Count[i] < minSamples || double.IsNaN(diff[i])) continue;
            double pct = Math.Clamp(diff[i] * authority, -limitPct, limitPct);
            if (Math.Abs(pct) < 0.1) continue;
            double to = cells[i].Value * (1 + pct / 100);
            if (Math.Abs(to - cells[i].Value) < 1e-9) continue;
            changes.Add(new CellChange(i, cells[i].Value, to, pct, measured.Count[i]));
        }
        return changes;
    }

    /// Timing to take out where the knock channel went over the threshold: `degrees` per cell, twice that where it went more than half again over.
    public static List<CellChange> KnockPulls(DefinitionSet defs, byte[] rom, LogTable knock, double threshold,
                                              double degrees = 2, int minSamples = 2)
    {
        var item = knock.Item;
        var cells = RomData.Read(defs, rom, item);
        var changes = new List<CellChange>();
        for (int i = 0; i < knock.Cells && i < cells.Length; i++)
        {
            if (knock.Count[i] < minSamples || double.IsNaN(knock.Max[i]) || knock.Max[i] <= threshold) continue;
            double over = threshold <= 0 ? 1 : knock.Max[i] / threshold;
            double pull = over > 1.5 ? degrees * 2 : degrees;
            double to = cells[i].Value - pull;
            changes.Add(new CellChange(i, cells[i].Value, to, cells[i].Value == 0 ? 0 : -pull / Math.Abs(cells[i].Value) * 100, knock.Count[i]));
        }
        return changes;
    }

    /// One line per cell that would change, for the log and for the user to read before applying.
    public static string Describe(LogTable t, IReadOnlyList<CellChange> changes, string unit)
    {
        if (changes.Count == 0) return "nothing to change: no cell has enough samples away from target";
        var sb = new System.Text.StringBuilder($"{changes.Count} cell(s) from {t.Frames} logged frames:\n");
        foreach (var c in changes.OrderByDescending(c => Math.Abs(c.Percent)).Take(30))
        {
            int r = t.Item.Cols > 0 ? c.Index / t.Item.Cols : 0, col = t.Item.Cols > 0 ? c.Index % t.Item.Cols : 0;
            sb.AppendLine($"  [{r},{col}] {c.From:0.##} -> {c.To:0.##} {unit} ({c.Percent:+0.#;-0.#}%, {c.Samples} samples)");
        }
        if (changes.Count > 30) sb.AppendLine($"  ... {changes.Count - 30} more");
        return sb.ToString();
    }
}

/// Which frames belong in a map. Honda calibrations keep a low-cam and a high-cam copy of every map (the names end in Lo / Hi, or carry "low" / "high"), and the ECU crosses over between them when VTEC engages. A log laid over the low map must only use the frames logged on the low cam, or the crossover smears one map into the other.
public static class MapSide
{
    /// true = the high-cam copy, false = the low-cam copy, null = the map is not one of a pair.
    public static bool? Side(ItemDef item) => Side(item.Name);

    public static bool? Side(string name)
    {
        var n = name.ToLowerInvariant();
        if (n.EndsWith("_hi") || n.EndsWith("hi") || n.Contains("high") || n.Contains("_vtec")) return true;
        if (n.EndsWith("_lo") || n.EndsWith("lo") || n.Contains("low")) return false;
        return null;
    }

    /// The other copy of the same map, if the set has one ("FUEL1_Lo" <-> "FUEL1_Hi").
    public static ItemDef? Other(DefinitionSet defs, ItemDef item)
    {
        if (Side(item) is not bool hi) return null;
        foreach (var (from, to) in hi ? new[] { ("_hi", "_lo"), ("hi", "lo"), ("high", "low") }
                                      : new[] { ("_lo", "_hi"), ("lo", "hi"), ("low", "high") })
        {
            int at = item.Name.LastIndexOf(from, StringComparison.OrdinalIgnoreCase);
            if (at < 0) continue;
            var want = item.Name[..at] + Match(item.Name.Substring(at, from.Length), to) + item.Name[(at + from.Length)..];
            var found = defs.Items.FirstOrDefault(i => i.Name.Equals(want, StringComparison.OrdinalIgnoreCase) && i.Rows == item.Rows && i.Cols == item.Cols);
            if (found != null) return found;
        }
        return null;
    }

    /// Keep the replacement in the case the original was written in ("Lo" -> "Hi", "LO" -> "HI").
    static string Match(string original, string replacement) =>
        original.All(char.IsUpper) ? replacement.ToUpperInvariant()
        : char.IsUpper(original[0]) ? char.ToUpperInvariant(replacement[0]) + replacement[1..]
        : replacement;

    /// Only the frames logged on this map's side of the crossover (all of them when the map is not one of a pair, or when nothing in the log says which cam was engaged).
    public static Func<LogFrame, bool>? Filter(ItemDef item)
    {
        if (Side(item) is not bool hi) return null;
        return f => f.Vtec is not bool v || v == hi;
    }
}
