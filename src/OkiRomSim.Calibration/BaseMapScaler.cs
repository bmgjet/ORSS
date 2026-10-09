// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Calibration;

/// Base maps for a change of induction, worked out from the maps the ROM has: going from natural aspiration to boost
/// (the load axis given boost columns, fuel and timing written into them from the last atmospheric column), or to
/// alpha-N (the throttle as the load at wide throttle, MAP below the crossover). Each works on the ROM it is given (a copy:
/// the caller diffs it and applies the change as one undo step) and says what it did.
public static class BaseMapScaler
{
    public const double AtmMbar = 1013.25, MbarPerPsi = 68.947573;

    /// The boost plan: the most boost the maps should reach, how many of the load columns go above the air outside, how
    /// the fuel follows the pressure (100 % = in step with the absolute pressure: 1 bar of boost, twice the air, twice
    /// the fuel; 120 % a fifth richer than that), and the timing taken out for every psi of boost.
    public sealed record BoostPlan(double MaxBoostPsi, int BoostColumns, double FuelPercent, double RetardPerPsi);

    /// The alpha-N plan: below the MAP crossover the maps are read on MAP as now; at or above it, or at or above the
    /// throttle crossover, on the throttle. The top `ThrottleColumns` load columns become the throttle's (from the
    /// throttle crossover to wide open).
    public sealed record AlphaNPlan(double MapCrossMbar, double TpsCrossPercent, int ThrottleColumns);

    /// The load axis the main maps are read on (the one most maps have as their columns, in a pressure), and the maps on it.
    public static (AxisDef Axis, int Count, List<ItemDef> Maps)? LoadAxis(DefinitionSet defs)
    {
        var groups = defs.Items.Where(i => i.IsTable && i.Cols > 2 && i.Rows > 1 && i.ColAxis?.Address != null && MapSensorScale.IsPressure(i.ColAxis.Formula))
                               .GroupBy(i => (i.ColAxis!.Address!.Value, i.Cols)).OrderByDescending(g => g.Count()).FirstOrDefault();
        if (groups == null) return null;
        var maps = groups.ToList();
        return (maps[0].ColAxis!, groups.Key.Cols, maps);
    }

    static bool IsFuel(ItemDef i) => (i.Formula ?? "").Contains("fuel", StringComparison.OrdinalIgnoreCase) || i.Name.StartsWith("Fuel", StringComparison.OrdinalIgnoreCase);
    static bool IsIgnition(ItemDef i) => (i.Formula ?? "").Contains("ign", StringComparison.OrdinalIgnoreCase) || i.Name.StartsWith("Ignition", StringComparison.OrdinalIgnoreCase);

    /// Natural aspiration to boost. The load axis: its atmospheric part squeezed into the columns left (the same shape),
    /// then `BoostColumns` evenly up to the most boost. Every map on it resampled onto the new atmospheric columns; in
    /// the boost columns, from its value at the last atmospheric one: the fuel x (1 + FuelPercent x boost / atmosphere),
    /// the timing less RetardPerPsi a psi, anything else held.
    public static string Boost(DefinitionSet defs, byte[] rom, BoostPlan plan)
    {
        if (LoadAxis(defs) is not var (axis, n, maps)) return "no fuel or ignition map with a load axis in a pressure: press Detect on the Calibration page first";
        if (plan.BoostColumns < 1 || plan.BoostColumns > n - 3) return $"the boost columns have to leave at least 3 of the {n} for the atmospheric part";
        if (plan.MaxBoostPsi <= 0) return "the most boost has to be above 0 psi";
        var f = defs.Formula(axis.Formula);
        double sensorTop = f.ToValue(255);
        double target = AtmMbar + (plan.MaxBoostPsi * MbarPerPsi);
        if (target > sensorTop + 1)
            return $"the MAP sensor this ROM is set up for reads up to {sensorTop:0} mBar ({(sensorTop - AtmMbar) / MbarPerPsi:0.0} psi of boost): " +
                   "fit and set a bigger sensor first (Tools > MAP sensor size), then scale for boost";
        var old = RomData.AxisValues(defs, rom, axis, n);
        // the atmospheric part of the axis as it is: the points up to the air outside (a little over, for a stock
        // sensor whose top is just above it)
        var na = old.Where(v => !double.IsNaN(v) && v <= AtmMbar + 30).ToArray();
        if (na.Length < 2) return "the load axis has no atmospheric part to keep";
        int naCols = n - plan.BoostColumns;
        var axisNew = new double[n];
        for (int i = 0; i < naCols; i++)
        {
            double at = (double)i * (na.Length - 1) / (naCols - 1);
            int lo = (int)Math.Floor(at), hi = Math.Min(na.Length - 1, lo + 1);
            axisNew[i] = na[lo] + ((na[hi] - na[lo]) * (at - lo));
        }
        double top = Math.Min(axisNew[naCols - 1], AtmMbar);
        axisNew[naCols - 1] = top;
        for (int k = 1; k <= plan.BoostColumns; k++) axisNew[naCols - 1 + k] = top + ((target - top) * k / plan.BoostColumns);
        // the maps as they read now, before the axis moves
        var before = maps.Select(m => (Map: m, Values: RomData.Read(defs, rom, m).Select(c => c.Value).ToArray())).ToList();
        WriteAxis(defs, rom, axis, axisNew);
        var axisNow = RomData.AxisValues(defs, rom, axis, n);
        int clamped = 0;
        foreach (var (m, v) in before)
        {
            int rows = Math.Max(1, m.Rows);
            var values = new double[rows * n];
            for (int r = 0; r < rows; r++)
            {
                double[] row = [.. v.Skip(r * n).Take(n)];
                double atAtm = Along(old, row, top);
                for (int c = 0; c < n; c++)
                {
                    double p = axisNow[c];
                    if (p <= top + 0.5) { values[(r * n) + c] = Along(old, row, p); continue; }
                    double boostMbar = p - AtmMbar, psi = boostMbar / MbarPerPsi;
                    values[(r * n) + c] = IsFuel(m) ? atAtm * (1 + (plan.FuelPercent / 100 * boostMbar / AtmMbar))
                                        : IsIgnition(m) ? atAtm - (plan.RetardPerPsi * psi)
                                        : atAtm;
                }
            }
            clamped += MapImport.WriteValues(defs, rom, m, values);
        }
        return $"load axis {axis.Name ?? "?"}: {naCols} atmospheric columns ({axisNow[0]:0}-{top:0} mBar) and {plan.BoostColumns} for boost up to " +
               $"{axisNow[^1]:0} mBar ({(axisNow[^1] - AtmMbar) / MbarPerPsi:0.0} psi); {before.Count} map(s) rewritten ({string.Join(", ", maps.Select(m => m.Name))}): " +
               $"fuel {plan.FuelPercent:0} % of the pressure rise, timing {plan.RetardPerPsi:0.##} deg less a psi" +
               (clamped > 0 ? $"; {clamped} cell(s) held at the top of what a cell holds" : "");
    }

    /// Natural aspiration to alpha-N (the ROM built with Maps indexing). The load axis: its lower columns MAP up to the
    /// crossover (the same shape), its top `ThrottleColumns` evenly from the crossover to the top of the sensor - the
    /// loads the throttle table maps the throttle onto, so each of those columns is a throttle position. The maps are
    /// resampled onto the new axis (so they start where they were), and the throttle table, the crossovers and the
    /// switch set.
    public static string AlphaN(DefinitionSet defs, byte[] rom, AlphaNPlan plan)
    {
        ItemDef? Slot(string s) => CalPage.Bound(defs, s);
        if (Slot("mapindex.alpha") is not { } table || Slot("mapindex.enable") is not { } enable)
            return "this ROM has no alpha-N maps indexing: build it in (File > Change functions > Maps indexing (alpha-N)) and come back";
        if (LoadAxis(defs) is not var (axis, n, maps)) return "no fuel or ignition map with a load axis in a pressure: press Detect on the Calibration page first";
        if (plan.ThrottleColumns < 2 || plan.ThrottleColumns > n - 2) return $"the throttle columns have to leave at least 2 of the {n} for MAP";
        if (plan.TpsCrossPercent is < 0 or >= 100) return "the throttle crossover has to be 0-99 %";
        var f = defs.Formula(axis.Formula);
        double sensorTop = f.ToValue(255);
        var old = RomData.AxisValues(defs, rom, axis, n);
        double cross = Math.Clamp(plan.MapCrossMbar, old[0] + 10, sensorTop - 50);
        int mapCols = n - plan.ThrottleColumns;
        var below = old.Where(v => !double.IsNaN(v) && v <= cross).ToArray();
        if (below.Length < 2) below = [old[0], cross];
        var axisNew = new double[n];
        for (int i = 0; i < mapCols; i++)
        {
            double at = (double)i * (below.Length - 1) / Math.Max(1, mapCols - 1);
            int lo = (int)Math.Floor(at), hi = Math.Min(below.Length - 1, lo + 1);
            axisNew[i] = below[lo] + ((below[hi] - below[lo]) * (at - lo));
        }
        axisNew[mapCols - 1] = cross;
        double loadTop = Math.Min(sensorTop, Math.Max(old[^1], AtmMbar));
        for (int k = 1; k <= plan.ThrottleColumns; k++) axisNew[mapCols - 1 + k] = cross + ((loadTop - cross) * k / plan.ThrottleColumns);
        var before = maps.Select(m => (Map: m, Values: RomData.Read(defs, rom, m).Select(c => c.Value).ToArray())).ToList();
        WriteAxis(defs, rom, axis, axisNew);
        var axisNow = RomData.AxisValues(defs, rom, axis, n);
        int clamped = 0;
        foreach (var (m, v) in before)
        {
            int rows = Math.Max(1, m.Rows);
            var values = new double[rows * n];
            for (int r = 0; r < rows; r++)
            {
                double[] row = [.. v.Skip(r * n).Take(n)];
                for (int c = 0; c < n; c++) values[(r * n) + c] = Along(old, row, axisNow[c]);
            }
            clamped += MapImport.WriteValues(defs, rom, m, values);
        }
        // the throttle table: each point's throttle onto the load columns above the crossover; under the throttle
        // crossover the crossover load (MAP still decides there)
        // (its points are evenly spread over the throttle, closed to wide open)
        double[] tps = [.. Enumerable.Range(0, table.Count).Select(i => i * 100.0 / Math.Max(1, table.Count - 1))];
        for (int i = 0; i < table.Count; i++)
        {
            double t = i < tps.Length ? tps[i] : 100;
            double load = t <= plan.TpsCrossPercent ? cross : cross + ((loadTop - cross) * (t - plan.TpsCrossPercent) / (100 - plan.TpsCrossPercent));
            RomData.Write(defs, rom, table, i, Math.Min(load, axisNow[^1]));
        }
        if (Slot("mapindex.crossmap") is { } cm) RomData.Write(defs, rom, cm, 0, cross);
        if (Slot("mapindex.crosstps") is { } ct) RomData.Write(defs, rom, ct, 0, plan.TpsCrossPercent);
        RomData.WriteRawCell(rom, enable, 0, enable.OnRaw, defs);
        return $"load axis {axis.Name ?? "?"}: {mapCols} MAP columns ({axisNow[0]:0}-{cross:0} mBar), then {plan.ThrottleColumns} for the throttle " +
               $"({plan.TpsCrossPercent:0}-100 %, loads {axisNow[mapCols]:0}-{axisNow[^1]:0} mBar); {before.Count} map(s) resampled; throttle table, " +
               $"crossovers ({cross:0} mBar / {plan.TpsCrossPercent:0} %) and alpha-N switched on" + (clamped > 0 ? $"; {clamped} cell(s) held" : "");
    }

    /// A row's value at a load, straight lines between its columns, held at the ends.
    static double Along(double[] axis, double[] row, double x)
    {
        int n = Math.Min(axis.Length, row.Length);
        if (n == 0) return 0;
        if (x <= axis[0]) return row[0];
        for (int i = 0; i < n - 1; i++)
            if (x <= axis[i + 1])
                return axis[i + 1] == axis[i] ? row[i] : row[i] + ((row[i + 1] - row[i]) * (x - axis[i]) / (axis[i + 1] - axis[i]));
        return row[n - 1];
    }

    /// New breakpoints into a load axis, each a step above the one before (a Honda lookup needs them climbing).
    static void WriteAxis(DefinitionSet defs, byte[] rom, AxisDef axis, double[] values)
    {
        var f = defs.Formula(axis.Formula);
        int size = axis.Type is CellType.U16 or CellType.S16 or CellType.U16BE or CellType.S16BE ? 2 : 1;
        int step = axis.Stride > 0 ? axis.Stride : size;
        var (lo, hi) = RomData.RawRange(axis.Type);
        double last = lo - 1;
        for (int i = 0; i < values.Length; i++)
        {
            double raw = Math.Round(f.ToRaw(values[i], lo, hi));
            raw = Math.Clamp(Math.Max(raw, last + 1), lo, hi);
            last = raw;
            RomData.WriteRaw(rom, axis.Address!.Value + (i * step), axis.Type, raw);
        }
    }
}
