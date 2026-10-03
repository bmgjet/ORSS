// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;

namespace OkiRomSim.Calibration;

/// Which MAP sensor a ROM is set up for, and the pressure scale that follows from it: what a load count means in mBar. The ECU works in counts; the app shows them as pressures, so when another sensor is fitted the scale has to move with it. An HTS 1.15 / HTS120 ROM says so in its MAP preset bytes (60FCh, and the custom words at 60FDh / 60FFh); a ROM built from the skeleton in two words of its own (MapSensorZero / MapSensorFull, which the ECU never reads). A sensor is a straight line: mBar at 0 V to mBar at 5 V over the 256 counts. The pressure formulas the sources are written in assume the stock sensor; for any other they are rebuilt here as the stock formula followed by the sensor's line, so every pressure - a load breakpoint, a boost cut, a GIO window - reads true.
public static class MapSensorScale
{
    /// The stock sensor: the scale "map_mbar" is written for (x * 7.221 - 59).
    public static readonly (double Zero, double Full) Stock = (-59, -59 + 255 * 7.221);

    const int HtsPreset = 0x60FC, HtsZero = 0x60FD, HtsFull = 0x60FF;

    /// The pressure formulas written for the stock sensor: their expression, its inverse, and the unit's size in mBar.
    static readonly Dictionary<string, (string Expr, string Inverse, double Unit, string UnitName, int Decimals)> StockForms = new(StringComparer.OrdinalIgnoreCase)
    {
        ["map_mbar"] = ("x * 7.221 - 59", "(x + 59) / 7.221", 1, "mbar", 0),
        ["map_kpa"] = ("(x * 7.221 - 59) / 10", "(x * 10 + 59) / 7.221", 10, "kPa", 1),
        ["map_load_axis_mbar"] = ("x * 3.6105 + 114.3", "(x - 114.3) / 3.6105", 1, "mbar", 0),
    };

    /// A formula that turns a count into a manifold pressure (the ones a sensor swap has to keep true).
    public static bool IsPressure(string? formula) =>
        formula != null && (StockForms.ContainsKey(formula) || formula.StartsWith("map_sensor_preset", StringComparison.OrdinalIgnoreCase));

    /// The sensor this ROM is set up for, or null when it does not say (the stock one, then).
    public static (double Zero, double Full)? Of(DefinitionSet defs, byte[] rom)
    {
        if (CalPage.Bound(defs, "mapsensor.zero") is { } z && CalPage.Bound(defs, "mapsensor.full") is { } f)
            return (RomData.Read(defs, rom, z)[0].Value, RomData.Read(defs, rom, f)[0].Value);
        if (IsHts(rom))
            return rom[HtsPreset] switch
            {
                1 => Stock,
                >= 2 => (Word(rom, HtsZero) - 32768.0, Word(rom, HtsFull) - 32768.0),
                _ => null,
            };
        return null;
    }

    /// Whether the ROM has somewhere to say which sensor is fitted.
    public static bool CanKeep(DefinitionSet defs, byte[] rom) => CalPage.Bound(defs, "mapsensor.zero") != null || IsHts(rom);

    /// Record the sensor fitted where this ROM keeps it. False when the ROM has nowhere to keep it.
    public static bool Write(DefinitionSet defs, byte[] rom, double zero, double full)
    {
        if (CalPage.Bound(defs, "mapsensor.zero") is { } z && CalPage.Bound(defs, "mapsensor.full") is { } f)
        {
            RomData.Write(defs, rom, z, 0, zero);
            RomData.Write(defs, rom, f, 0, full);
            return true;
        }
        if (IsHts(rom))
        {
            // the established software's custom preset: the two ends, stored + 32768
            rom[HtsPreset] = 2;
            PutWord(rom, HtsZero, (int)Math.Round(zero) + 32768);
            PutWord(rom, HtsFull, (int)Math.Round(full) + 32768);
            return true;
        }
        return false;
    }

    /// The ROM's pressure formulas brought in line with its sensor. An HTS ROM's own preset formula is rebuilt from its bytes too.
    public static void ApplyFormulas(DefinitionSet defs, byte[] rom)
    {
        if (IsHts(rom)) HtsLayout.RefreshMapFormulas(defs, rom);
        if (!CanKeep(defs, rom)) return;
        var s = Of(defs, rom) ?? Stock;
        bool stock = Math.Abs(s.Zero - Stock.Zero) < 0.5 && Math.Abs(s.Full - Stock.Full) < 0.5;
        foreach (var (name, f) in StockForms)
        {
            if (stock) { Put(defs, new FormulaDef { Name = name, Expr = f.Expr, Inverse = f.Inverse, Unit = f.UnitName, Decimals = f.Decimals }); continue; }
            Put(defs, Composed(name, f, s));
        }
    }

    /// A MAP sensor swap: every pressure the ROM holds - the load breakpoints of every map and table, and every setting that is a pressure (a boost cut, a GIO window) - moved to the counts that mean the same pressure on the sensor fitted, and the ROM told which sensor that is. Works through each one's own formula, so a load axis kept in another count (the skeleton's load index) moves right too. Changes `rom`; returns what it did.
    public static string Swap(DefinitionSet defs, byte[] rom, (double Zero, double Full) from, (double Zero, double Full) to)
    {
        if (from.Full <= from.Zero || to.Full <= to.Zero) return "each sensor needs a range: what it reads at 5 V has to be above what it reads at 0 V";
        var keep = CanKeep(defs, rom);
        // the pressures as the sensor the ROM was set up for reads them
        if (keep) { Write(defs, rom, from.Zero, from.Full); ApplyFormulas(defs, rom); }
        else ApplyStockAs(defs, from);
        var axes = new Dictionary<int, (AxisDef Axis, int Count, double[] Raw, double[] Mbar)>();
        foreach (var it in defs.Items.Where(i => i.IsTable))
            foreach (var (ax, n) in new[] { (it.RowAxis, it.Rows), (it.ColAxis, it.Cols) })
                if (ax?.Address is int a && n > 1 && IsPressure(ax.Formula) && !axes.ContainsKey(a))
                    axes[a] = (ax, n, RawOf(rom, ax, n), RomData.AxisValues(defs, rom, ax, n));
        // (a definition that is one of those axes itself is moved with the axis, which knows how a Honda axis ends)
        var cells = defs.Items.Where(i => IsPressure(i.Formula) && !i.Flag && i.Text == null && !axes.ContainsKey(i.Address))
                        .Select(i => (Item: i, Values: RomData.Read(defs, rom, i).Select(c => c.Value).ToArray())).ToList();
        // the sensor fitted
        if (keep) { Write(defs, rom, to.Zero, to.Full); ApplyFormulas(defs, rom); }
        else ApplyStockAs(defs, to);
        int moved = 0, clipped = 0;
        foreach (var (addr, (ax, n, raw, mbar)) in axes)
        {
            var f = defs.Formula(ax.Formula);
            int size = ax.Type is CellType.U16 or CellType.S16 or CellType.U16BE or CellType.S16BE ? 2 : 1;
            int step = ax.Stride > 0 ? ax.Stride : size;
            var (lo, hi) = RomData.RawRange(ax.Type);
            // a byte axis that climbs ends on 00 meaning 256 (one past FF); FF itself is the filler after a short one
            bool climbs = size == 1 && n > 1 && raw[1] > raw[0];
            for (int i = 0; i < n; i++)
            {
                if (double.IsNaN(mbar[i]) || (size == 1 && raw[i] == 0xFF)) continue;
                double top = climbs && i > 0 ? 256 : hi, bottom = climbs && i > 0 ? 1 : lo;
                double want = Math.Round(f.ToRaw(mbar[i], lo, top));
                if (want <= bottom || want >= top) clipped++;
                want = Math.Clamp(want, bottom, top);
                double stored = want == 256 ? 0 : want;
                if (stored != raw[i]) { RomData.WriteRaw(rom, addr + i * step, ax.Type, stored); moved++; }
            }
        }
        foreach (var (it, values) in cells)
            for (int i = 0; i < values.Length; i++) RomData.Write(defs, rom, it, i, values[i]);
        if (!keep) ApplyStockAs(defs, Stock);
        return $"MAP sensor {from.Zero:0}..{from.Full:0} -> {to.Zero:0}..{to.Full:0} mBar: {moved} load breakpoint(s) on {axes.Count} axes and {cells.Count} pressure setting(s) moved to the same real pressures" +
               (clipped > 0 ? $", {clipped} at the end of the new sensor's range" : "") +
               (keep ? "" : " (this ROM has nowhere to say which sensor is fitted: its pressures still read on the stock scale)");
    }

    /// A ROM that cannot say which sensor it has: the formulas as if it could, for the length of a swap.
    static void ApplyStockAs(DefinitionSet defs, (double Zero, double Full) s)
    {
        foreach (var (name, f) in StockForms) Put(defs, Composed(name, f, s));
    }

    /// A stock pressure formula followed by a sensor's line: the count as the stock sensor reads it, then that count on the sensor given. Written without a leading or doubled minus (the expression reader takes neither).
    static FormulaDef Composed(string name, (string Expr, string Inverse, double Unit, string UnitName, int Decimals) f, (double Zero, double Full) s)
    {
        static string N(double v) => Math.Abs(v).ToString("0.######", CultureInfo.InvariantCulture);
        double k = (s.Full - s.Zero) / 255;
        if (Math.Abs(k) < 1e-6) k = 1e-6;
        string plusZero = s.Zero < 0 ? $" - {N(s.Zero)}" : $" + {N(s.Zero)}", minusZero = s.Zero < 0 ? $" + {N(s.Zero)}" : $" - {N(s.Zero)}";
        string expr = $"(((({f.Expr}) * {N(f.Unit)} + 59) / 7.221) * {N(k)}{plusZero}) / {N(f.Unit)}";
        string stockY = $"(((x * {N(f.Unit)}{minusZero}) / {N(k)} * 7.221 - 59) / {N(f.Unit)})";
        return new FormulaDef
        {
            Name = name, Expr = expr, Inverse = f.Inverse.Replace("x", stockY), Unit = f.UnitName, Decimals = f.Decimals,
            Notes = $"{name} for the MAP sensor fitted ({s.Zero:0} .. {s.Full:0} mBar)",
        };
    }

    static double[] RawOf(byte[] rom, AxisDef ax, int n)
    {
        int size = ax.Type is CellType.U16 or CellType.S16 or CellType.U16BE or CellType.S16BE ? 2 : 1;
        int step = ax.Stride > 0 ? ax.Stride : size;
        var r = new double[n];
        for (int i = 0; i < n; i++)
        {
            int a = ax.Address!.Value + i * step;
            r[i] = a + size <= rom.Length && (ax.Count == 0 || i < ax.Count) ? RomData.ReadRaw(rom, a, ax.Type) : double.NaN;
        }
        return r;
    }

    /// A load axis: one whose breakpoints are manifold pressures.
    public static bool IsLoadAxis(DefinitionSet defs, AxisDef? axis) => axis?.Address != null && IsPressure(axis.Formula);

    static bool IsHts(byte[] rom) => rom.Length > HtsFull + 1 && HtsLayout.Identify(rom).Layout == HtsLayout.Family.Hts115;
    static int Word(byte[] rom, int a) => rom[a] | (rom[a + 1] << 8);
    static void PutWord(byte[] rom, int a, int v) { rom[a] = (byte)v; rom[a + 1] = (byte)(v >> 8); }

    static void Put(DefinitionSet defs, FormulaDef f)
    {
        defs.Formulas.RemoveAll(x => x.Name.Equals(f.Name, StringComparison.OrdinalIgnoreCase));
        defs.Formulas.Add(f);
    }
}
