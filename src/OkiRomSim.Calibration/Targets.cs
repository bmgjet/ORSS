using System.Globalization;
using System.Text;

namespace OkiRomSim.Calibration;

/// A curve given as points, read straight through between them: a wideband's correction, an analog input scaled into the units you actually want, a sensor whose output is not a straight line. Written as "in = out" pairs, one per line or separated by commas:
/// 0 = 10 2.5 = 14.7 5 = 20
/// Below the first point and above the last, the first and last values hold.
public sealed class LookupCurve
{
    public List<(double In, double Out)> Points { get; set; } = new();

    public bool Any => Points.Count > 0;

    public double Apply(double x)
    {
        if (Points.Count == 0) return x;
        var p = Points;
        if (x <= p[0].In) return p[0].Out;
        if (x >= p[^1].In) return p[^1].Out;
        for (int i = 0; i + 1 < p.Count; i++)
        {
            var (x0, y0) = p[i];
            var (x1, y1) = p[i + 1];
            if (x >= x0 && x <= x1) return x1 == x0 ? y0 : y0 + (y1 - y0) * (x - x0) / (x1 - x0);
        }
        return p[^1].Out;
    }

    public static LookupCurve Parse(string? text)
    {
        var curve = new LookupCurve();
        if (string.IsNullOrWhiteSpace(text)) return curve;
        foreach (var part in text.Split(new[] { '\n', ',', ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var bits = part.Split(new[] { '=', ':', '\t' }, 2);
            if (bits.Length != 2) continue;
            if (double.TryParse(bits[0].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var a) &&
                double.TryParse(bits[1].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var b))
                curve.Points.Add((a, b));
        }
        curve.Points.Sort((l, r) => l.In.CompareTo(r.In));
        return curve;
    }

    public string ToText() => string.Join("\n", Points.Select(p => $"{p.In.ToString("0.###", CultureInfo.InvariantCulture)} = {p.Out.ToString("0.###", CultureInfo.InvariantCulture)}"));
}

/// What you want the engine to run, cell by cell: an AFR target across rpm and load, kept for each cam (the low-cam and high-cam maps are tuned to different targets). Written as a small table, which is easy to paste in or out of a spreadsheet:
/// 0 40 80 100 <- load across the top (kPa) 800 14.7 14.7 13.2 12.8 3000 14.7 14.2 12.8 12.4 6000 13.5 13.0 12.4 12.2
/// A reading between breakpoints is read straight through from the four around it; outside the table, the nearest edge holds.
public sealed class TargetMap
{
    public List<double> Rpm { get; set; } = new();
    public List<double> Load { get; set; } = new();
    /// Row per rpm, column per load.
    public List<List<double>> Values { get; set; } = new();

    public bool Any => Rpm.Count > 0 && Load.Count > 0 && Values.Count == Rpm.Count;

    /// The target at this rpm and load.
    public double Target(double rpm, double load, double fallback)
    {
        if (!Any) return fallback;
        var (r0, r1, rf) = Span(Rpm, rpm);
        var (c0, c1, cf) = Span(Load, load);
        double a = Cell(r0, c0) + (Cell(r0, c1) - Cell(r0, c0)) * cf;
        double b = Cell(r1, c0) + (Cell(r1, c1) - Cell(r1, c0)) * cf;
        return a + (b - a) * rf;
    }

    double Cell(int r, int c) => r < Values.Count && c < Values[r].Count ? Values[r][c] : double.NaN;

    static (int Lo, int Hi, double Frac) Span(List<double> axis, double v)
    {
        if (v <= axis[0]) return (0, 0, 0);
        if (v >= axis[^1]) return (axis.Count - 1, axis.Count - 1, 0);
        for (int i = 0; i + 1 < axis.Count; i++)
            if (v >= axis[i] && v <= axis[i + 1])
                return (i, i + 1, axis[i + 1] == axis[i] ? 0 : (v - axis[i]) / (axis[i + 1] - axis[i]));
        return (axis.Count - 1, axis.Count - 1, 0);
    }

    /// One target per cell of `item`, ready for LogTables.Difference.
    public double[] ForTable(DefinitionSet defs, byte[] rom, ItemDef item, double fallback)
    {
        int rows = Math.Max(1, item.Rows), cols = Math.Max(1, item.Cols);
        var rowAxis = item.RowAxis == null ? null : RomData.AxisValues(defs, rom, item.RowAxis, rows);
        var colAxis = item.ColAxis == null ? null : RomData.AxisValues(defs, rom, item.ColAxis, cols);
        var result = new double[rows * cols];
        for (int r = 0; r < rows; r++)
            for (int c = 0; c < cols; c++)
            {
                double rpm = rowAxis != null && r < rowAxis.Length ? rowAxis[r] : r;
                double load = colAxis != null && c < colAxis.Length ? colAxis[c] : c;
                // a load axis in mbar reads in the same numbers as kPa once divided by ten
                if (colAxis != null && colAxis.Length > 0 && colAxis.Max() > 400) load /= 10;
                result[r * cols + c] = Target(rpm, load, fallback);
            }
        return result;
    }

    /// The table as text: the load breakpoints across the top, rpm down the left.
    public string ToText()
    {
        if (!Any) return "";
        var sb = new StringBuilder();
        sb.Append("rpm\\load");
        foreach (var l in Load) sb.Append('\t').Append(l.ToString("0.###", CultureInfo.InvariantCulture));
        sb.AppendLine();
        for (int r = 0; r < Rpm.Count; r++)
        {
            sb.Append(Rpm[r].ToString("0.###", CultureInfo.InvariantCulture));
            for (int c = 0; c < Load.Count; c++) sb.Append('\t').Append(Cell(r, c).ToString("0.###", CultureInfo.InvariantCulture));
            sb.AppendLine();
        }
        return sb.ToString();
    }

    /// Read the same shape back, from tabs, commas or runs of spaces. The first row is the load breakpoints (its first cell is a heading and ignored), the first column the rpm ones.
    public static TargetMap Parse(string? text)
    {
        var map = new TargetMap();
        if (string.IsNullOrWhiteSpace(text)) return map;
        var lines = text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0 && !l.StartsWith('#')).ToList();
        if (lines.Count < 2) return map;
        var head = Split(lines[0]);
        foreach (var h in head.Skip(1))
            if (double.TryParse(h, NumberStyles.Float, CultureInfo.InvariantCulture, out var l)) map.Load.Add(l);
        foreach (var line in lines.Skip(1))
        {
            var cells = Split(line);
            if (cells.Count < 2 || !double.TryParse(cells[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var rpm)) continue;
            var row = new List<double>();
            foreach (var cell in cells.Skip(1))
                row.Add(double.TryParse(cell, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : double.NaN);
            while (row.Count < map.Load.Count) row.Add(row.Count > 0 ? row[^1] : double.NaN);
            map.Rpm.Add(rpm);
            map.Values.Add(row);
        }
        return map;
    }

    static List<string> Split(string line) =>
        line.Split(new[] { '\t', ',', ' ' }, StringSplitOptions.RemoveEmptyEntries).ToList();

    /// A sensible starting point: petrol, richer with load and rpm.
    public static TargetMap Default() => Parse(
        "rpm\\load\t20\t40\t60\t80\t100\n" +
        "800\t14.7\t14.7\t14.7\t13.5\t13.0\n" +
        "2000\t14.7\t14.7\t14.2\t13.2\t12.8\n" +
        "4000\t14.7\t14.4\t13.6\t12.8\t12.5\n" +
        "6000\t14.2\t13.8\t13.0\t12.5\t12.2\n" +
        "8000\t13.8\t13.4\t12.8\t12.3\t12.0\n");
}
