// Copyright (c) bmgjet. All rights reserved.
using System.Text;

namespace OkiRomSim.Calibration;

/// One byte the ROM would have to change.
public readonly record struct BytePatch(int Address, byte Value);

/// What a scaling would do, before anything is written: the bytes, and what to tell the user.
public sealed record ScaleReport(string Summary, int CellsChanged, int Clipped, int ColumnsRescaled, IReadOnlyList<BytePatch> Patches)
{
    public static ScaleReport Nothing(string why) => new(why, 0, 0, 0, []);
    public bool Any => Patches.Count > 0;

    public ScaleReport Merge(ScaleReport other) => new(
        Summary.Length == 0 ? other.Summary : other.Summary.Length == 0 ? Summary : Summary + "\n" + other.Summary,
        CellsChanged + other.CellsChanged, Clipped + other.Clipped, ColumnsRescaled + other.ColumnsRescaled,
        [.. Patches, .. other.Patches]);
}

/// Scaling whole sections of a calibration at once: a table by a percentage, the fuel maps for a different injector size, the load axis for a different MAP sensor, and the rescale that gives a maxed-out fuel map room to grow again. A fuel map cell is not the whole story: each column is multiplied by a byte in a multiplier row, so a column that has run out of range (cells at FF) can carry on by raising that byte and dividing its cells to match - the delivered fuel is unchanged, but there is room above it. That is what "rescale" does here, and every scaling uses it so values stop flat-topping at the end of the scale. Nothing writes to the ROM: each call returns the bytes to patch, so the caller can show them, make them one undo step, or refuse them.
public static class Rescale
{
    /// Multiply every cell of `item` by `factor` (1.10 = +10%). Tables with a multiplier row keep their delivered values in range by raising the multiplier of any column that would otherwise clip; other tables clamp, and the report says how many cells hit the end.
    public static ScaleReport ScaleTable(DefinitionSet defs, byte[] rom, ItemDef item, double factor, bool rescaleColumns = true)
    {
        if (factor <= 0 || double.IsNaN(factor)) return ScaleReport.Nothing("the factor has to be greater than 0");
        if (item.Type is not (CellType.U8 or CellType.S8 or CellType.U16 or CellType.S16 or CellType.U16BE or CellType.S16BE))
            return ScaleReport.Nothing($"{item.Name} is not a numeric table");

        var (lo, hi) = RomData.RawRange(item.Type);
        int cols = item.IsTable ? item.Cols : 1, count = item.Count;
        var patches = new List<BytePatch>();
        int changed = 0, clipped = 0, rescaled = 0;

        // what each cell should hold, before the multiplier row is taken into account
        var wanted = new double[count];
        for (int i = 0; i < count; i++)
        {
            int a = item.CellAddress(i);
            if (a < 0 || a + item.ElementSize > rom.Length) return ScaleReport.Nothing($"{item.Name} runs past the end of the ROM");
            wanted[i] = RomData.ReadRaw(rom, a, item.Type, item.Bit) * factor;
        }

        if (item.ColumnScaleAddress is int mrow && item.IsTable && item.ElementSize == 1)
        {
            for (int c = 0; c < cols; c++)
            {
                int ma = mrow + c;
                if (ma >= rom.Length) break;
                int mult = Math.Max(1, (int)rom[ma]);
                double peak = 0;
                for (int r = 0; r < item.Rows; r++) peak = Math.Max(peak, wanted[(r * cols) + c]);
                int newMult = mult;
                if (rescaleColumns && peak > hi)
                {
                    // raise the column's multiplier just enough for its biggest cell to fit
                    newMult = (int)Math.Min(255, Math.Ceiling(mult * peak / hi));
                    if (newMult != mult)
                    {
                        patches.Add(new BytePatch(ma, (byte)newMult));
                        rescaled++;
                    }
                }
                double share = (double)mult / newMult;      // cells shrink by as much as the multiplier grew
                for (int r = 0; r < item.Rows; r++)
                {
                    int i = (r * cols) + c;
                    double raw = Math.Round(wanted[i] * share);
                    if (raw > hi) { raw = hi; clipped++; }
                    if (raw < lo) { raw = lo; clipped++; }
                    changed += Put(rom, item, i, raw, patches);
                }
            }
        }
        else
        {
            for (int i = 0; i < count; i++)
            {
                double raw = Math.Round(wanted[i]);
                if (raw > hi) { raw = hi; clipped++; }
                if (raw < lo) { raw = lo; clipped++; }
                changed += Put(rom, item, i, raw, patches);
            }
        }

        var sb = new StringBuilder($"{item.Name} x {factor:0.###}: {changed} cell(s)");
        if (rescaled > 0) sb.Append($", {rescaled} column multiplier(s) raised so nothing maxes out");
        if (clipped > 0) sb.Append($", {clipped} cell(s) hit the end of the scale");
        return new ScaleReport(sb.ToString(), changed, clipped, rescaled, patches);
    }

    /// Writing cells of a map whose columns carry a multiplier. A cell that would run past the top of its range does not stop there: the column's multiplier goes up and every other cell in that column comes down to match, so those values stay exactly where they were and the one being raised carries on climbing - the way a tuner expects a fuel map to behave. `values` are in the item's units (raw = the stored byte times the multiplier). Cells not listed keep the value they have now.
    public static ScaleReport WriteWithRollover(DefinitionSet defs, byte[] rom, ItemDef item,
                                                IReadOnlyList<(int Index, double Value)> values, bool raw = false)
    {
        if (item.ColumnScaleAddress is not int mrow || !item.IsTable || item.ElementSize != 1 || item.Cols <= 0)
            return ScaleReport.Nothing("that table has no column multipliers");
        var f = defs.Formula(item.Formula);
        var (lo, hi) = RomData.RawRange(item.Type);
        var now = RomData.Read(defs, rom, item);

        // what every cell should deliver after this write, as an effective raw number (stored byte x multiplier), which is what the multiplier row scales
        var want = new double[item.Count];
        for (int i = 0; i < item.Count; i++)
        {
            int col = i % item.Cols;
            double mult = Math.Max(1, (int)rom[(mrow + col) & (rom.Length - 1)]);
            want[i] = now[i].Raw * mult;
        }
        var asked = new HashSet<int>();
        foreach (var (index, v) in values)
        {
            if (index < 0 || index >= item.Count) continue;
            asked.Add(index);
            // `want` is in effective raw units - the stored byte times the column's multiplier. A raw write (the +/- nudge keys, or "r120" typed into a cell) names the stored byte, so it has to be multiplied up to get there; taking it as an effective value instead divided every nudge by the multiplier, which is why adding fuel did next to nothing.
            want[index] = raw ? v * Math.Max(1, (int)rom[(mrow + (index % item.Cols)) & (rom.Length - 1)])
                              : f.ToRaw(v, lo, hi * 255);
        }

        var patches = new List<BytePatch>();
        int changed = 0, clipped = 0, rescaled = 0;
        var touched = values.Select(v => v.Index % item.Cols).Distinct();
        foreach (int col in touched)
        {
            int ma = mrow + col;
            if (ma >= rom.Length) continue;
            int mult = Math.Max(1, (int)rom[ma]);
            double peak = 0;
            for (int r = 0; r < item.Rows; r++) peak = Math.Max(peak, want[(r * item.Cols) + col]);
            int newMult = peak > hi * mult ? (int)Math.Min(255, Math.Ceiling(peak / hi)) : mult;
            if (newMult != mult) { patches.Add(new BytePatch(ma, (byte)newMult)); rescaled++; }
            for (int r = 0; r < item.Rows; r++)
            {
                int i = (r * item.Cols) + col;
                // the cells nobody asked to change are only being restated against a bigger multiplier: round them up, so a rescale never quietly takes fuel away from them (this is what the established tuning software does, and rounding to nearest here dropped a count off cells that were not being edited at all)
                double exact = want[i] / newMult;
                double stored = asked.Contains(i) || newMult == mult ? Math.Round(exact) : Math.Ceiling(exact - 1e-9);
                if (stored > hi) { stored = hi; clipped++; }
                if (stored < lo) { stored = lo; clipped++; }
                changed += Put(rom, item, i, stored, patches);
            }
        }
        var note = rescaled > 0
            ? $"{item.Name}: {changed} cell(s); {rescaled} column multiplier(s) raised so the values could keep climbing"
            : $"{item.Name}: {changed} cell(s)";
        return new ScaleReport(note + (clipped > 0 ? $", {clipped} at the end of the scale" : ""), changed, clipped, rescaled, patches);
    }

    /// Leave the delivered values exactly as they are, but move each column's cells down (or up) the scale and change its multiplier to match, so the biggest cell sits near `targetPeak` out of 255. Room to add fuel without flat-topping.
    public static ScaleReport Headroom(DefinitionSet defs, byte[] rom, ItemDef item, int targetPeak = 200)
    {
        if (item.ColumnScaleAddress is not int mrow || !item.IsTable || item.ElementSize != 1)
            return ScaleReport.Nothing($"{item.Name} has no column multipliers, so there is nothing to rescale (scale it by a percentage instead)");
        targetPeak = Math.Clamp(targetPeak, 16, 250);

        var patches = new List<BytePatch>();
        int changed = 0, rescaled = 0, clipped = 0;
        for (int c = 0; c < item.Cols; c++)
        {
            int ma = mrow + c;
            if (ma >= rom.Length) break;
            int mult = Math.Max(1, (int)rom[ma]);
            double peak = 0;
            for (int r = 0; r < item.Rows; r++) peak = Math.Max(peak, RomData.ReadRaw(rom, item.CellAddress((r * item.Cols) + c), item.Type));
            if (peak <= 0) continue;
            int newMult = (int)Math.Clamp(Math.Round(mult * peak / targetPeak), 1, 255);
            if (newMult == mult) continue;
            patches.Add(new BytePatch(ma, (byte)newMult));
            rescaled++;
            double share = (double)mult / newMult;
            for (int r = 0; r < item.Rows; r++)
            {
                int i = (r * item.Cols) + c;
                double raw = Math.Round(RomData.ReadRaw(rom, item.CellAddress(i), item.Type) * share);
                if (raw > 255) { raw = 255; clipped++; }
                changed += Put(rom, item, i, raw, patches);
            }
        }
        return new ScaleReport(
            rescaled == 0 ? $"{item.Name} already sits in a sensible part of the scale" :
            $"{item.Name}: {rescaled} column(s) rescaled around a peak of {targetPeak}/255, {changed} cell(s) restated (the values the ECU uses are unchanged)",
            changed, clipped, rescaled, patches);
    }

    /// Bigger injectors flow more, so the same air needs a shorter pulse: every fuel table is scaled by old/new. Sizes are whatever unit both are in (cc/min, lb/hr).
    public static ScaleReport Injectors(DefinitionSet defs, byte[] rom, IEnumerable<ItemDef> fuelTables, double oldSize, double newSize)
    {
        if (oldSize <= 0 || newSize <= 0) return ScaleReport.Nothing("both injector sizes have to be greater than 0");
        double factor = oldSize / newSize;
        var report = new ScaleReport($"injectors {oldSize:0.##} -> {newSize:0.##}: fuel x {factor:0.###}", 0, 0, 0, []);
        foreach (var t in fuelTables) report = report.Merge(ScaleTable(defs, rom, t, factor));
        return report;
    }

    /// A different MAP sensor reads a different pressure at the same voltage, so the load breakpoints have to move to stay at the same real pressure: every axis count is scaled by old range / new range. Axes shared by several maps are patched once.
    public static ScaleReport MapSensor(DefinitionSet defs, byte[] rom, IEnumerable<ItemDef> maps, double oldFullScale, double newFullScale)
    {
        if (oldFullScale <= 0 || newFullScale <= 0) return ScaleReport.Nothing("both sensor ranges have to be greater than 0");
        double factor = oldFullScale / newFullScale;
        var done = new HashSet<int>();
        var report = new ScaleReport($"MAP sensor {oldFullScale:0.##} -> {newFullScale:0.##}: load axes x {factor:0.###}", 0, 0, 0, []);
        foreach (var m in maps)
        {
            if (m.ColAxis is not { Address: int addr } axis) continue;
            if (!done.Add(addr)) continue;
            report = report.Merge(ScaleAxis(rom, axis, m.Cols, factor));
        }
        return report;
    }

    /// A MAP sensor swap the way the tuning software does it: a sensor is described by what it reads at 0 V and at 5 V, and every load breakpoint is moved to the count that stands for the same real pressure on the new one. A breakpoint holding count b means oldMin + (oldMax - oldMin) * b / 255 on the old sensor; the count that means the same pressure on the new one is (p - newMin) * 255 / (newMax - newMin). This is not the same as scaling by a ratio: a sensor with an offset (a 3 bar reading -431 mbar at 0 V, say) needs the offset taken out and the new one put back, which a ratio cannot do.
    public static ScaleReport MapSensorRange(DefinitionSet defs, byte[] rom, IEnumerable<ItemDef> maps,
                                             double oldMin, double oldMax, double newMin, double newMax)
    {
        if (oldMax <= oldMin || newMax <= newMin) return ScaleReport.Nothing("each sensor needs a range: what it reads at 5 V has to be above what it reads at 0 V");
        var done = new HashSet<int>();
        var report = new ScaleReport(
            $"MAP sensor {oldMin:0}..{oldMax:0} -> {newMin:0}..{newMax:0} mbar: load breakpoints moved to the same real pressures", 0, 0, 0, []);
        foreach (var m in maps)
        {
            if (m.ColAxis is not { Address: int addr } axis) continue;
            if (!done.Add(addr)) continue;
            report = report.Merge(RemapAxis(rom, axis, m.Cols, b =>
            {
                double p = oldMin + ((oldMax - oldMin) * b / 255);
                return (p - newMin) * 255 / (newMax - newMin);
            }));
        }
        return report.Patches.Count == 0
            ? ScaleReport.Nothing("none of the maps has a load axis in the ROM to move (their columns are fixed in the definitions)")
            : report;
    }

    /// Put every breakpoint of an axis through a function of its stored count.
    public static ScaleReport RemapAxis(byte[] rom, AxisDef axis, int count, Func<double, double> map)
    {
        if (axis.Address is not int addr) return ScaleReport.Nothing("that axis has no address in the ROM (its values are fixed in the definition)");
        int size = axis.Type is CellType.U16 or CellType.S16 or CellType.U16BE or CellType.S16BE ? 2 : 1;
        var (lo, hi) = RawRange(axis.Type);
        int n = axis.Count > 0 ? Math.Min(axis.Count, count) : count;
        var patches = new List<BytePatch>();
        int changed = 0, clipped = 0;
        for (int i = 0; i < n; i++)
        {
            int a = addr + (i * size);
            if (a + size > rom.Length) break;
            double raw = RomData.ReadRaw(rom, a, axis.Type);
            if (raw == 0xFF && size == 1) continue;           // the filler that marks the end of a short axis
            double want = Math.Round(map(raw));
            if (want > hi) { want = hi; clipped++; }
            if (want < lo) { want = lo; clipped++; }
            changed += PutRaw(rom, a, axis.Type, want, patches);
        }
        return new ScaleReport($"axis at {addr:X4}: {changed} breakpoint(s) moved" + (clipped > 0 ? $", {clipped} at the end of the scale" : ""),
            changed, clipped, 0, patches);
    }

    static (double min, double max) RawRange(CellType t) => RomData.RawRange(t);

    /// Scale an axis's stored counts (its formula turns them into kPa / rpm as before).
    public static ScaleReport ScaleAxis(byte[] rom, AxisDef axis, int count, double factor)
    {
        if (axis.Address is not int addr) return ScaleReport.Nothing("that axis has no address in the ROM (its values are fixed in the definition)");
        int size = axis.Type is CellType.U16 or CellType.S16 or CellType.U16BE or CellType.S16BE ? 2 : 1;
        var (lo, hi) = RomData.RawRange(axis.Type);
        int n = axis.Count > 0 ? Math.Min(axis.Count, count) : count;
        var patches = new List<BytePatch>();
        int changed = 0, clipped = 0;
        for (int i = 0; i < n; i++)
        {
            int a = addr + (i * size);
            if (a + size > rom.Length) break;
            double raw = RomData.ReadRaw(rom, a, axis.Type);
            if (raw == 0xFF && size == 1) continue;           // the filler that marks the end of a short axis
            double want = Math.Round(raw * factor);
            if (want > hi) { want = hi; clipped++; }
            if (want < lo) { want = lo; clipped++; }
            changed += PutRaw(rom, a, axis.Type, want, patches);
        }
        return new ScaleReport($"axis at {addr:X4} x {factor:0.###}: {changed} breakpoint(s)" + (clipped > 0 ? $", {clipped} at the end of the scale" : ""),
            changed, clipped, 0, patches);
    }

    /// Apply a report's bytes to a ROM image (the desktop app writes them through its undo stack instead; this is for tools and tests).
    public static void Apply(byte[] rom, ScaleReport report)
    {
        foreach (var p in report.Patches) if (p.Address >= 0 && p.Address < rom.Length) rom[p.Address] = p.Value;
    }

    // ------------------------------------------------------------------ helpers

    static int Put(byte[] rom, ItemDef item, int index, double raw, List<BytePatch> patches)
        => PutRaw(rom, item.CellAddress(index), item.Type, raw, patches);

    /// Turn a raw value into the bytes it occupies, comparing with what is there now.
    static int PutRaw(byte[] rom, int addr, CellType type, double raw, List<BytePatch> patches)
    {
        var scratch = new byte[2];
        int size = type is CellType.U16 or CellType.S16 or CellType.U16BE or CellType.S16BE ? 2 : 1;
        if (addr < 0 || addr + size > rom.Length) return 0;
        Array.Copy(rom, addr, scratch, 0, size);
        RomData.WriteRaw(scratch, 0, type, raw);
        bool any = false;
        for (int b = 0; b < size; b++)
            if (scratch[b] != rom[addr + b]) { patches.Add(new BytePatch(addr + b, scratch[b])); any = true; }
        return any ? 1 : 0;
    }
}
