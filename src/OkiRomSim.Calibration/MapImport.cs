// Copyright (c) bmgjet. All rights reserved.
using System.Text.RegularExpressions;

namespace OkiRomSim.Calibration;

/// Bringing maps and settings across from another ROM (a tune for a different ROM family, say) into the one being built: which of its tables goes where in this one, and the bytes that put it there. Values move in real units - milliseconds, degrees, percent - through each ROM's own formula, and a map whose breakpoints differ from this ROM's is resampled onto this ROM's axes (straight lines between the other ROM's points, the ends held), the way Paste table does. Nothing is written here: a Plan is a list of byte patches for the caller to apply in one step.
public static partial class MapImport
{
    /// What a table is for, read from its formula, its name and its description, so tables of the same job pair up across ROM families that name them differently (FUEL1_Lo, FuelLow, fuelmap_base_lookup_tbl).
    public sealed record Role(string Kind, string Cam, int Set);

    /// One table of the other ROM and where it would go in this one; To is null when nothing here is a good match.
    public sealed record Pairing(ItemDef From, ItemDef? To, string Why, int Score);

    public static Role RoleOf(ItemDef i)
    {
        string f = (i.Formula ?? "").ToLowerInvariant(), n = i.Name.ToLowerInvariant(), d = i.Description.ToLowerInvariant();
        string kind = f switch
        {
            "honda_fuel" => "fuel",
            "ign_advance" => "ignition",
            "ve_percent" => "ve",
            _ => i.Category.ToLowerInvariant(),
        };
        // low or high cam: the name first (Lo / Low / Hi / High as a word or after _), then what the detector says the rows are
        string cam = HighName().IsMatch(n) ? "high" : LowName().IsMatch(n) ? "low"
                   : d.Contains("high-cam") ? "high" : d.Contains("low-cam") ? "low" : "";
        // the second set of maps (HTS FUEL2 / IGN2, the dual-map modules, IgnitionLow2)
        int set = SecondSet().IsMatch(n) ? 2 : 1;
        return new Role(kind, cam, set);
    }

    [GeneratedRegex(@"(^|[_\d]|[a-z])(hi|high)(\d|_|$)|high", RegexOptions.IgnoreCase)] private static partial Regex HighName();
    [GeneratedRegex(@"(^|[_\d]|[a-z])(lo|low)(\d|_|$)|low", RegexOptions.IgnoreCase)] private static partial Regex LowName();
    [GeneratedRegex(@"(fuel|ign|ignition|ve|map)2|2($|_)|_2\b", RegexOptions.IgnoreCase)] private static partial Regex SecondSet();

    static bool IsMap(ItemDef i) => i.IsTable && i.Rows > 1 && i.Cols > 1;

    /// The same shape of thing: a map with a map, a one-row table with a one-row table, a single value with a single value.
    static bool Compatible(ItemDef a, ItemDef b) =>
        IsMap(a) == IsMap(b) && a.IsTable == b.IsTable && a.Flag == b.Flag && a.Text == null && b.Text == null;

    /// Where each of the other ROM's tables and settings would go here: the same feature page row, else the same name, else the same job (a low-cam fuel map with the low-cam fuel map). Each of this ROM's tables is used once.
    public static List<Pairing> Pair(DefinitionSet from, DefinitionSet to)
    {
        var taken = new HashSet<ItemDef>();
        var result = new List<Pairing>();
        var targets = to.Items.Where(i => i.Text == null).ToList();
        ItemDef? Take(ItemDef? t) { if (t != null) taken.Add(t); return t; }
        static IEnumerable<string> Slots(ItemDef i) => (i.Slot ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        // the strongest matches first, over every table, so a weak match cannot take a table a strong one needs
        var pending = from.Items.Where(i => i.Text == null).ToList();
        var chosen = new Dictionary<ItemDef, (ItemDef To, string Why, int Score)>();
        foreach (var src in pending)
            if (Slots(src).FirstOrDefault(s => targets.Any(t => !taken.Contains(t) && Compatible(src, t) && Slots(t).Contains(s))) is { } slot)
                chosen[src] = (Take(targets.First(t => !taken.Contains(t) && Compatible(src, t) && Slots(t).Contains(slot)))!, $"the same page row ({slot})", 100);
        foreach (var src in pending.Where(s => !chosen.ContainsKey(s)))
            if (targets.FirstOrDefault(t => !taken.Contains(t) && Compatible(src, t) && t.Name.Equals(src.Name, StringComparison.OrdinalIgnoreCase)) is { } byName)
                chosen[src] = (Take(byName)!, "the same name", 90);
        // maps by what they do: kind, cam and set all agree (the biggest first, so a 20x10 finds the 20x10)
        foreach (var src in pending.Where(s => !chosen.ContainsKey(s) && IsMap(s)).OrderByDescending(s => s.Count))
        {
            var r = RoleOf(src);
            if (r.Cam.Length == 0 || r.Kind is not ("fuel" or "ignition" or "ve")) continue;
            var hit = targets.Where(t => !taken.Contains(t) && IsMap(t) && RoleOf(t) == r).OrderBy(t => Math.Abs(t.Count - src.Count)).FirstOrDefault();
            if (hit != null) chosen[src] = (Take(hit)!, $"the same job ({r.Kind}, {r.Cam} cam{(r.Set == 2 ? ", second set" : "")})", 70);
        }
        foreach (var src in pending)
            result.Add(chosen.TryGetValue(src, out var c) ? new Pairing(src, c.To, c.Why, c.Score) : new Pairing(src, null, "nothing here matches it", 0));
        return result;
    }

    /// This ROM's tables the other one's could go to, the likely ones first.
    public static List<ItemDef> Candidates(ItemDef from, DefinitionSet to)
    {
        var r = RoleOf(from);
        return [.. to.Items.Where(t => Compatible(from, t))
                          .OrderByDescending(t => RoleOf(t).Kind == r.Kind)
                          .ThenByDescending(t => t.Category.Equals(from.Category, StringComparison.OrdinalIgnoreCase))
                          .ThenBy(t => Math.Abs(t.Count - from.Count))
                          .ThenBy(t => t.Name, StringComparer.OrdinalIgnoreCase)];
    }

    /// What one table would change: the note to show, and whether its values had to be resampled onto different axes.
    public sealed record Result(bool Ok, string Note, bool Resampled, int Clamped, int Changed);

    /// How a table goes into one of a different size, or with different breakpoints: Breakpoints - each cell here takes the other table's value at this cell's rpm and load (straight lines between its points, the ends held): the engine sees the same numbers at the same rpm and load. Stretch     - the other table is stretched (or squeezed) end to end over this one, whatever the breakpoints say. Direct      - cell for cell from the top left corner; cells this table has beyond the other's are left as they are.
    public enum Scaling { Breakpoints, Stretch, Direct }

    /// The two tables line up exactly (same size, same breakpoints): there is nothing to choose.
    public static bool SameLayout(DefinitionSet fromDefs, byte[] fromRom, ItemDef from, DefinitionSet toDefs, byte[] rom, ItemDef to)
    {
        int fr = from.IsTable ? Math.Max(1, from.Rows) : 1, fc = from.IsTable ? from.Cols : 1, tr = to.IsTable ? Math.Max(1, to.Rows) : 1, tc = to.IsTable ? to.Cols : 1;
        if (fr != tr || fc != tc) return false;
        double[] Ax(DefinitionSet d, byte[] r, AxisDef? a, int n) => a == null ? [.. Enumerable.Range(0, n).Select(i => (double)i)] : RomData.AxisValues(d, r, a, n);
        return Near(Ax(fromDefs, fromRom, from.RowAxis, fr), Ax(toDefs, rom, to.RowAxis, tr)) && Near(Ax(fromDefs, fromRom, from.ColAxis, fc), Ax(toDefs, rom, to.ColAxis, tc));
    }

    /// Write `from`'s values (read from `fromRom`) into `work`, a copy of this ROM, at `to`. With copyAxes, this ROM's breakpoints become the other ROM's first (when they are in the ROM and have as many points); then the values are resampled onto whatever breakpoints this ROM has. A Honda fuel map's column multipliers come across with its cells when the columns line up, so the milliseconds arrive exactly rather than rounded to this ROM's multipliers.
    public static Result Apply(DefinitionSet fromDefs, byte[] fromRom, ItemDef from, DefinitionSet toDefs, byte[] work, ItemDef to, bool copyAxes,
                               Scaling scaling = Scaling.Breakpoints)
    {
        if (!Compatible(from, to)) return new(false, "not the same shape of thing (a map, a table, a single value)", false, 0, 0);
        var before = (byte[])work.Clone();
        var src = RomData.Read(fromDefs, fromRom, from).Select(c => c.Value).ToArray();
        int fr = Math.Max(1, from.Rows), fc = from.IsTable ? from.Cols : 1, tr = Math.Max(1, to.Rows), tc = to.IsTable ? to.Cols : 1;
        if (!from.IsTable) { fr = fc = 1; }
        if (!to.IsTable) { tr = tc = 1; }
        var notes = new List<string>();

        // the breakpoints, in real units
        double[] Axis(DefinitionSet d, byte[] rom, AxisDef? a, int n) => a == null ? [.. Enumerable.Range(0, n).Select(i => (double)i)] : RomData.AxisValues(d, rom, a, n);
        string Unit(DefinitionSet d, AxisDef? a) => a == null ? "" : a.Unit.Length > 0 ? a.Unit : SafeUnit(d, a.Formula);
        bool haveAxes(ItemDef i) => (i.Rows <= 1 || i.RowAxis != null) && (i.Cols <= 1 || i.ColAxis != null);

        if (copyAxes && from.IsTable && to.IsTable)
        {
            int copied = 0;
            if (from.Rows > 1 && to.RowAxis?.Address != null && from.RowAxis != null && from.Rows == to.Rows) copied += CopyAxis(fromDefs, fromRom, from.RowAxis, from.Rows, toDefs, work, to.RowAxis);
            if (from.Cols > 1 && to.ColAxis?.Address != null && from.ColAxis != null && from.Cols == to.Cols) copied += CopyAxis(fromDefs, fromRom, from.ColAxis, from.Cols, toDefs, work, to.ColAxis);
            if (copied > 0)
            {
                notes.Add($"{copied} breakpoint(s) of the axes brought across");
                var shared = toDefs.Items.Where(i => i != to && i.IsTable &&
                        ((i.RowAxis?.Address is int ra && (ra == to.RowAxis?.Address || ra == to.ColAxis?.Address)) ||
                         (i.ColAxis?.Address is int ca && (ca == to.RowAxis?.Address || ca == to.ColAxis?.Address))))
                    .Select(i => i.Name).Distinct().ToList();
                if (shared.Count > 0) notes.Add($"the same axes are used by {string.Join(", ", shared.Take(6))}{(shared.Count > 6 ? $" and {shared.Count - 6} more" : "")}, which now line up against the new breakpoints too");
            }
        }

        double[] fRow = Axis(fromDefs, fromRom, from.RowAxis, fr), fCol = Axis(fromDefs, fromRom, from.ColAxis, fc);
        double[] tRow = Axis(toDefs, work, to.RowAxis, tr), tCol = Axis(toDefs, work, to.ColAxis, tc);
        bool sameShape = fr == tr && fc == tc;
        bool colsLineUp = fc == tc && Near(fCol, tCol);
        bool sameAxes = sameShape && Near(fRow, tRow) && Near(fCol, tCol);
        bool resampled = false;
        var values = new double[tr * tc];
        // cells Direct leaves as they are (beyond the other table's size)
        var keep = new bool[tr * tc];
        if (!sameAxes && scaling == Scaling.Direct)
        {
            var now = RomData.Read(toDefs, work, to).Select(c => c.Value).ToArray();
            for (int r = 0; r < tr; r++)
                for (int c = 0; c < tc; c++)
                {
                    int i = (r * tc) + c;
                    if (r < fr && c < fc) values[i] = src[(r * fc) + c];
                    else { values[i] = i < now.Length ? now[i] : 0; keep[i] = true; }
                }
            notes.Add(sameShape ? "copied cell for cell (the breakpoints differ: each cell keeps its place, not its rpm and load)"
                                : $"copied cell for cell from the top left ({Math.Min(fr, tr)} x {Math.Min(fc, tc)}){(keep.Any(k => k) ? "; the rest of this table left as it was" : "")}");
        }
        else if (!sameAxes && scaling == Scaling.Stretch && !(sameShape && fr * fc == 1))
        {
            // positions 0..1 along each table, first point to first, last to last
            double[] Pos(int n) => n <= 1 ? [0] : [.. Enumerable.Range(0, n).Select(i => (double)i / (n - 1))];
            var grid = new double[fr][];
            for (int r = 0; r < fr; r++) grid[r] = [.. src.Skip(r * fc).Take(fc)];
            double[] fp = Pos(fr), fq = Pos(fc), tp = Pos(tr), tq = Pos(tc);
            for (int r = 0; r < tr; r++)
                for (int c = 0; c < tc; c++)
                    values[(r * tc) + c] = Bilinear(fp, fq, grid, tp[r], tq[c]);
            resampled = !sameShape;
            notes.Add(sameShape ? "copied cell for cell (stretched end to end: the same size)" : $"a {fr} x {fc} table stretched end to end over this {tr} x {tc} one");
        }
        else if (sameAxes || (sameShape && !(haveAxes(from) && haveAxes(to))))
        {
            Array.Copy(src, values, Math.Min(src.Length, values.Length));
            if (!sameAxes) notes.Add("the same size, copied cell for cell (the axes are not both known, so they could not be compared)");
        }
        else
        {
            if (!haveAxes(from) || !haveAxes(to))
                return new(false, $"a {fr} x {fc} table into a {tr} x {tc} one, and without both sets of axes it cannot be matched by breakpoints: pick Stretch or Direct", false, 0, 0);
            // the axes have to be in the same units to line up (rpm with rpm, the load in the same measure)
            foreach (var (fa, ta, which) in new[] { (from.RowAxis, to.RowAxis, "row"), (from.ColAxis, to.ColAxis, "column") })
            {
                string fu = Unit(fromDefs, fa), tu = Unit(toDefs, ta);
                if (fu.Length > 0 && tu.Length > 0 && !fu.Equals(tu, StringComparison.OrdinalIgnoreCase))
                    return new(false, $"the {which} axes are in different units ({fu} there, {tu} here): they cannot be matched by breakpoints - pick Stretch or Direct", false, 0, 0);
            }
            var grid = new double[fr][];
            for (int r = 0; r < fr; r++) grid[r] = [.. src.Skip(r * fc).Take(fc)];
            for (int r = 0; r < tr; r++)
                for (int c = 0; c < tc; c++)
                    values[(r * tc) + c] = Bilinear(fRow, fCol, grid, tRow[r], tCol[c]);
            resampled = true;
            notes.Add(sameShape ? "resampled onto this ROM's breakpoints" : $"a {fr} x {fc} table resampled onto this {tr} x {tc} one");
        }

        // write, and count what did not fit this ROM's range (held at its limit)
        int clamped = 0;
        var tf = toDefs.Formula(to.Formula);
        // a Honda fuel map scales each column by its own multiplier (the row after the last): each column gets the smallest one that holds its values - the finest steps that fit. Resampled columns mix the other ROM's columns, so its multipliers would not do.
        if (to.ColumnScaleAddress is int tm && to.IsTable)
        {
            double unit = Math.Abs(tf.ToValue(1) - tf.ToValue(0)), zero = tf.ToValue(0);
            if (unit > 0)
                for (int c = 0; c < to.Cols; c++)
                {
                    // a column Direct leaves as it was keeps its multiplier
                    if (Enumerable.Range(0, tr).All(r => keep[(r * tc) + c])) continue;
                    // the columns line up: the other ROM's own multiplier, so its values arrive exactly
                    if (colsLineUp && from.ColumnScaleAddress is int fm)
                    {
                        work[(tm + c) & (work.Length - 1)] = (byte)Math.Max(1, (int)fromRom[(fm + c) & (fromRom.Length - 1)]);
                        continue;
                    }
                    double top = 0;
                    for (int r = 0; r < tr; r++) top = Math.Max(top, values[(r * tc) + c]);
                    int mult = (int)Math.Clamp(Math.Ceiling(((top - zero) / unit / 255.0) - 1e-9), 1, 255);
                    work[(tm + c) & (work.Length - 1)] = (byte)mult;
                }
            notes.Add(colsLineUp && from.ColumnScaleAddress != null ? "its column multipliers brought across" : "each column's multiplier set to hold its values");
        }
        for (int i = 0; i < values.Length && i < to.Count; i++)
        {
            // a cell Direct leaves alone stays as it is - unless its column's multiplier changed, when it is written again so its value holds
            if (keep[i] && !(to.ColumnScaleAddress is int km && work[(km + (i % to.Cols)) & (work.Length - 1)] != before[(km + (i % to.Cols)) & (before.Length - 1)])) continue;
            RomData.Write(toDefs, work, to, i, values[i]);
            double got = RomData.Read(toDefs, work, to)[i].Value;
            // one step of this cell: the formula's, times the column multiplier a Honda fuel map has (so rounding to a step is not taken for the value not fitting)
            double mult = to.ColumnScaleAddress is int cm && to.IsTable ? Math.Max(1, (int)work[(cm + (i % to.Cols)) & (work.Length - 1)]) : 1;
            double step = Math.Abs(tf.ToValue(1) - tf.ToValue(0)) * mult;
            if (Math.Abs(got - values[i]) > Math.Max(step * 0.75, Math.Abs(values[i]) * 0.01) + 1e-9) clamped++;
        }
        if (clamped > 0) notes.Add($"{clamped} cell(s) beyond what this ROM's table holds were held at its limit");
        int changed = 0;
        for (int i = 0; i < work.Length; i++) if (work[i] != before[i]) changed++;
        return new(true, notes.Count == 0 ? "copied as it is" : string.Join("; ", notes), resampled, clamped, changed);
    }

    static string SafeUnit(DefinitionSet d, string? formula)
    {
        try { return formula == null ? "" : d.Formula(formula).Unit; } catch { return ""; }
    }

    static bool Near(double[] a, double[] b) =>
        a.Length == b.Length && a.Zip(b).All(p => Math.Abs(p.First - p.Second) <= Math.Max(0.5, Math.Abs(p.Second) * 0.005));

    /// The other ROM's breakpoints written into this ROM's axis (the same number of points): how many changed.
    static int CopyAxis(DefinitionSet fromDefs, byte[] fromRom, AxisDef fromAxis, int n, DefinitionSet toDefs, byte[] work, AxisDef toAxis)
    {
        var vals = RomData.AxisValues(fromDefs, fromRom, fromAxis, n);
        var before = RomData.AxisValues(toDefs, work, toAxis, n);
        // the axis as a one-row table at its own address, so the normal write (formula, range) does the work
        var asTable = new ItemDef
        {
            Name = "axis", Address = toAxis.Address!.Value, Rows = 1, Cols = n, Type = toAxis.Type, Formula = toAxis.Formula,
            ColStride = toAxis.Stride,
        };
        int changed = 0;
        for (int i = 0; i < n; i++)
        {
            if (double.IsNaN(vals[i])) continue;
            // a Honda byte axis that climbs to 256 stores it as 00: leave that last point alone rather than write FF
            if (Math.Abs(vals[i] - before[i]) < 1e-9) continue;
            RomData.Write(toDefs, work, asTable, i, vals[i]);
            changed++;
        }
        return changed;
    }

    static double Bilinear(double[] ra, double[] ca, double[][] v, double r, double c)
    {
        static (int, int, double) Bracket(double[] axis, double x)
        {
            if (axis.Length == 1) return (0, 0, 0);
            bool up = axis[^1] >= axis[0];
            for (int i = 0; i < axis.Length - 1; i++)
            {
                double a = axis[i], b = axis[i + 1];
                bool inside = up ? x >= a && x <= b : x <= a && x >= b;
                if (inside) return (i, i + 1, b == a ? 0 : (x - a) / (b - a));
            }
            bool below = up ? x < axis[0] : x > axis[0];
            return below ? (0, 0, 0) : (axis.Length - 1, axis.Length - 1, 0);
        }
        var (r0, r1, fr) = Bracket(ra, r);
        var (c0, c1, fc) = Bracket(ca, c);
        return (v[r0][c0] * (1 - fr) * (1 - fc)) + (v[r0][c1] * (1 - fr) * fc) + (v[r1][c0] * fr * (1 - fc)) + (v[r1][c1] * fr * fc);
    }

    /// The byte changes between this ROM and the worked copy: what to apply, in one step.
    public static List<BytePatch> Diff(byte[] original, byte[] work)
    {
        var list = new List<BytePatch>();
        for (int i = 0; i < Math.Min(original.Length, work.Length); i++) if (original[i] != work[i]) list.Add(new BytePatch(i, work[i]));
        return list;
    }
}
