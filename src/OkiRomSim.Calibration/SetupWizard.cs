// Copyright (c) bmgjet. All rights reserved.
using System.Text.Json;
using OkiRomSim.Assembler;

namespace OkiRomSim.Calibration;

/// The stock ECU a ROM's maps can be started from: its engine and the settings that go with it (the wizard fills its pages from them).
public sealed record BaseMapPreset(string Ecu, string Rom, string Country, string Engine, string Note, bool Vtec, int RevLimit, int VtecRpm, int InjectorCc, int FuelTrimPct, string File)
{
    public override string ToString() => $"{Ecu}{(Rom.Length > 0 ? "-" + Rom : "")}  {Engine}{(Country.Length > 0 ? "  " + Country : "")}{(Note.Length > 0 ? "  " + Note : "")}";
}

/// An injector's dead time (lag) against battery voltage, 7 points, the way the stock lag table holds it.
public sealed record InjectorPreset(string Name, double[] Volts, double[] LagMs)
{
    public override string ToString() => Name;
}

/// A gearbox: the boundaries between gears 1-2, 2-3, 3-4 and 4-5 as the established tuning software stores them (km/h per rpm, x 7324).
public sealed record GearboxPreset(string Name, int[] Bounds)
{
    public override string ToString() => Name;
}

/// The presets the set-up wizard offers, from Templates/Presets/presets.json: the stock ECUs whose maps a ROM can start from (their maps in the .stock files beside it), injector lag curves and gearboxes.
public sealed class PresetLibrary
{
    public string Folder { get; private init; } = "";
    public List<BaseMapPreset> BaseMaps { get; private init; } = [];
    public List<InjectorPreset> Injectors { get; private init; } = [];
    public List<GearboxPreset> Gearboxes { get; private init; } = [];

    sealed class FileShape
    {
        public List<BaseMapPreset> BaseMaps { get; set; } = [];
        public List<InjectorPreset> Injectors { get; set; } = [];
        public List<GearboxPreset> Gearboxes { get; set; } = [];
    }

    public static PresetLibrary Load(string folder)
    {
        var path = Path.Combine(folder, "presets.json");
        var f = JsonSerializer.Deserialize<FileShape>(File.ReadAllText(path), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new FileShape();
        return new PresetLibrary { Folder = folder, BaseMaps = f.BaseMaps.Where(b => File.Exists(Path.Combine(folder, b.File))).ToList(), Injectors = f.Injectors, Gearboxes = f.Gearboxes };
    }

    /// A stock ECU's calibration block: 144 bytes of load breakpoints (three sets of 24 words, mBar), then the bytes HTS 1.15 keeps from 6E17h.
    public byte[] StockBlock(BaseMapPreset p) =>
        [.. File.ReadAllText(Path.Combine(Folder, p.File)).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(byte.Parse)];
}

/// What the wizard was told, page by page. Null leaves that part of the ROM as it is.
public sealed class SetupChoices
{
    /// Start from this stock ECU's fuel and ignition maps.
    public BaseMapPreset? BaseMap { get; set; }
    /// The engine has VTEC (false switches it off where the ROM can), and where it engages.
    public bool? Vtec { get; set; }
    public double VtecRpm { get; set; } = 5500;
    public double? RevLimit { get; set; }
    /// The injectors the maps were written for and the ones fitted (cc/min).
    public double? StockCc { get; set; }
    public double? FittedCc { get; set; }
    public InjectorPreset? Lag { get; set; }
    public double? OverallTrim { get; set; }
    public double? CrankTrim { get; set; }
    public double? PostStartTrim { get; set; }
    public double? TipInTrim { get; set; }
    /// The MAP sensor the ROM was set up for and the one fitted: mBar at 0 V and at 5 V.
    public (double Zero, double Full)? OldSensor { get; set; }
    public (double Zero, double Full)? NewSensor { get; set; }
    public int? Gearbox { get; set; }
    /// Forced induction: the most boost (psi), the fuel added for each bar of boost (%), the timing taken out for each psi, and a boost cut (psi, 0 = none).
    public double? BoostPsi { get; set; }
    public double BoostFuelPerBar { get; set; } = 100;
    public double BoostRetardPerPsi { get; set; } = 1.25;
    public double BoostCutPsi { get; set; }
    /// Switches by page slot: on or off.
    public Dictionary<string, bool> Switches { get; } = new(StringComparer.OrdinalIgnoreCase);
}

/// The set-up wizard's work, done on a copy of the ROM in the order the established tuning software does it: the base maps, then VTEC and the rev limit, the injectors, the MAP sensor and the gearbox, boost, and the switches. Every setting is written through its page slot, so the same choices work on an HTS 1.15 / HTS120 ROM and on one built from the skeleton - where a ROM has no such setting, the report says so and nothing is written. The caller applies the bytes that changed as one undo step.
public static class SetupPlanner
{
    public sealed record Plan(byte[] Image, List<string> Done, List<string> NotHere);

    const double SeaLevel = 1013;
    const int HtsBlockStart = 0x6E17, HtsBlockEnd = 0x7FEE, HtsPMapScalar = 0x6E59, HtsSMapScalar = 0x6E17;

    public static Plan Make(DefinitionSet defs, byte[] rom, SetupChoices c, PresetLibrary? lib, string? htsTemplate)
    {
        // the formulas are the plan's own (a MAP sensor swap rebuilds the pressure ones): the caller's are left as they are until it applies
        defs = new DefinitionSet { Name = defs.Name, RomId = defs.RomId, RomSize = defs.RomSize, Formulas = [.. defs.Formulas], Items = defs.Items, Symbols = defs.Symbols, Labels = defs.Labels };
        var work = (byte[])rom.Clone();
        var done = new List<string>();
        var notHere = new List<string>();
        bool hts = HtsLayout.Identify(rom).Layout == HtsLayout.Family.Hts115;

        // ---- base maps
        if (c.BaseMap is { } bm && lib != null)
        {
            var block = lib.StockBlock(bm);
            if (hts) done.Add(StockIntoHts(defs, work, block, bm));
            else if (htsTemplate != null && File.Exists(htsTemplate)) done.Add(StockByImport(defs, work, block, bm, htsTemplate));
            else notHere.Add("base maps: the HTS120 template is needed to bring a stock ECU's maps into this ROM");
        }

        // ---- VTEC and the rev limit
        if (c.Vtec is bool vtec)
        {
            if (!vtec)
            {
                if (Switch(defs, work, "vtec.enable", false)) done.Add("VTEC switched off");
                else notHere.Add("VTEC off: this ROM has no switch for it (on a ROM built from the skeleton, build in VTEC control: File > Change functions)");
            }
            else
            {
                Switch(defs, work, "vtec.enable", true);
                double point = c.VtecRpm, cruise = Math.Min(point + 300, (c.RevLimit ?? 9000) - 300);
                if (Has(defs, "vtec.rpm.high"))
                {
                    Switch(defs, work, "vtec.custom", true);
                    Set(defs, work, "vtec.rpm.high", point);
                    Set(defs, work, "vtec.rpm.low", cruise);
                    done.Add($"VTEC on: engages at {point:0} rpm with the throttle open, {cruise:0} cruising");
                }
                else if (Has(defs, "vtec.stock.load.on"))
                {
                    Set(defs, work, "vtec.stock.load.on", point);
                    Set(defs, work, "vtec.stock.load.off", point - 190);
                    Set(defs, work, "vtec.stock.any.on", point + 700);
                    Set(defs, work, "vtec.stock.any.off", point + 510);
                    done.Add($"VTEC (the stock points): engages from {point:0} rpm with load, {point + 700:0} whatever the load");
                }
                else notHere.Add("VTEC engage point: this ROM has no setting for it");
            }
        }
        if (c.RevLimit is double rl)
        {
            if (Has(defs, "revlimit.low.set"))
            {
                Switch(defs, work, "revlimit.enable", true);
                foreach (var cam in new[] { "low", "high" })
                {
                    Set(defs, work, $"revlimit.{cam}.set", rl);
                    Set(defs, work, $"revlimit.{cam}.reset", rl - 70);
                }
                done.Add($"rev limit {rl:0} rpm (back in at {rl - 70:0})");
            }
            else notHere.Add("rev limit: this ROM keeps only its own fixed limiter (build in Rev limits: File > Change functions)");
        }

        // ---- injectors
        if (c.StockCc is double sc && c.FittedCc is double fc && sc > 0 && fc > 0)
        {
            double mult = sc / fc;
            if (Has(defs, "injector.fitted"))
            {
                bool scale = Math.Abs(mult - 1) > 1e-6 || (c.OverallTrim ?? 0) != 0;
                Switch(defs, work, "injector.enable", scale);
                Set(defs, work, "injector.stock", sc);
                Set(defs, work, "injector.fitted", fc);
                if (c.OverallTrim is double ot) Set(defs, work, "injector.trim", ot);
                done.Add($"injectors {sc:0} cc -> {fc:0} cc: every pulse x {mult:0.000}" + (c.OverallTrim is double t && t != 0 ? $", trim {t:+0.#;-0.#} %" : ""));
            }
            else if (Has(defs, "injector.multiplier"))
            {
                // the ROM's multiplier word holds up to x2 (FFFFh / 8000h): past that, the fuel maps take the rest
                const double most = 65535.0 / 32768;
                Set(defs, work, "injector.multiplier", Math.Min(mult, most));
                if (c.OverallTrim is double ot) Set(defs, work, "injector.overall", ot);
                int n = 0;
                if (mult > most)
                    foreach (var t in FuelMaps(defs)) { foreach (var p in Rescale.ScaleTable(defs, work, t, mult / most).Patches) work[p.Address] = p.Value; n++; }
                done.Add($"injectors {sc:0} cc -> {fc:0} cc: multiplier {Math.Min(mult, most):0.000}" + (n > 0 ? $", and {n} fuel map(s) x {mult / most:0.000} for the rest" : ""));
            }
            else if (Math.Abs(mult - 1) > 1e-6)
            {
                int n = 0;
                foreach (var t in FuelMaps(defs))
                {
                    foreach (var p in Rescale.ScaleTable(defs, work, t, mult).Patches) work[p.Address] = p.Value;
                    n++;
                }
                done.Add($"injectors {sc:0} cc -> {fc:0} cc: {n} fuel map(s) scaled x {mult:0.000}");
            }
        }
        foreach (var (slot, value, what) in new[] { ("injector.crank", c.CrankTrim, "cranking trim"), ("injector.postfuel", c.PostStartTrim, "post start trim"), ("injector.tipin", c.TipInTrim, "tip-in trim") })
            if (value is double v)
            {
                if (Has(defs, slot)) { Set(defs, work, slot, v); done.Add($"{what} {v:+0.#;-0.#;0} %"); }
                else if (v != 0) notHere.Add($"{what}: no such setting in this ROM");
            }
        if (c.Lag is { } lag)
        {
            if (InjectorLag.Write(defs, work, lag)) done.Add($"injector lag: {lag.Name}");
            else notHere.Add("injector lag: this ROM has no lag table bound");
        }

        // ---- sensors
        if (c.NewSensor is { } ns)
        {
            var os = c.OldSensor ?? MapSensorScale.Of(defs, work) ?? MapSensorScale.Stock;
            if (Math.Abs(os.Zero - ns.Zero) > 0.5 || Math.Abs(os.Full - ns.Full) > 0.5)
            {
                // every pressure moved to the same real pressure on the sensor fitted, and the ROM told which sensor that is (so the boost below is worked out in true pressures)
                done.Add(MapSensorScale.Swap(defs, work, os, ns));
                if (!MapSensorScale.CanKeep(defs, work)) notHere.Add("MAP sensor: this ROM has nowhere to say which sensor is fitted, so the app still shows its pressures on the stock scale");
            }
        }
        if (c.Gearbox is int g && lib != null && g >= 0 && g < lib.Gearboxes.Count)
        {
            var gb = lib.Gearboxes[g];
            if (Has(defs, "transmission.ratio"))
            {
                var it = CalPage.Bound(defs, "transmission.ratio")!;
                for (int i = 0; i < Math.Min(it.Count, gb.Bounds.Length); i++) RomData.WriteRawCell(work, it, i, gb.Bounds[i]);
                if (CalPage.Bound(defs, "transmission.preset") is { } pi) RomData.WriteRawCell(work, pi, 0, g);
                done.Add($"gearbox: {gb.Name}");
            }
            else if (Has(defs, "transmission.bounds"))
            {
                // the skeleton's gear detection keeps 29297 / (rpm per km/h): four times the established software's numbers
                var it = CalPage.Bound(defs, "transmission.bounds")!;
                for (int i = 0; i < Math.Min(4, it.Count); i++) RomData.WriteRawCell(work, it, i, gb.Bounds[i] * 4);
                if (it.Count > 4) RomData.WriteRawCell(work, it, 4, Math.Round(gb.Bounds[3] * 4 * 1.5));
                done.Add($"gearbox: {gb.Name}");
            }
            else notHere.Add("gearbox: this ROM does not work out the gear (build in Gear detection: File > Change functions)");
        }

        // ---- boost
        if (c.BoostPsi is double psi && psi > 0) done.AddRange(Boost(defs, work, psi, c.BoostFuelPerBar, c.BoostRetardPerPsi, notHere));
        if (c.BoostCutPsi > 0)
        {
            double mbar = SeaLevel + c.BoostCutPsi / 0.0145038;
            if (Has(defs, "boostcut.hot"))
            {
                Switch(defs, work, "boostcut.enable", true);
                Set(defs, work, "boostcut.hot", mbar);
                Set(defs, work, "boostcut.cold", mbar);
                done.Add($"boost cut at {c.BoostCutPsi:0.#} psi ({mbar:0} mBar)");
            }
            else notHere.Add("boost cut: build in Boost cut (File > Change functions)");
        }

        // ---- switches
        foreach (var (slot, on) in c.Switches)
            if (Switch(defs, work, slot, on)) done.Add($"{slot}: {(on ? "on" : "off")}");
        return new Plan(work, done, notHere);
    }

    static bool Has(DefinitionSet defs, string slot) => CalPage.Bound(defs, slot) != null;

    static void Set(DefinitionSet defs, byte[] work, string slot, double value)
    {
        foreach (var it in CalPage.BoundAll(defs, slot)) RomData.Write(defs, work, it, 0, value);
    }

    static IEnumerable<ItemDef> FuelMaps(DefinitionSet defs) =>
        defs.Items.Where(i => i.IsTable && i.Count > 1 && (i.ColumnScaleAddress != null || i.Category.Equals("Fuel", StringComparison.OrdinalIgnoreCase)) && i.Formula == "honda_fuel");

    /// A switch row: the definition's own on and off values (a flag), or 1 and 0.
    static bool Switch(DefinitionSet defs, byte[] work, string slot, bool on)
    {
        var all = CalPage.BoundAll(defs, slot);
        foreach (var it in all)
        {
            double raw = it.Flag ? (on ? it.OnRaw : it.OffRaw) : on ? 1 : 0;
            RomData.WriteRaw(work, it.Address, it.Type, raw, it.Bit);
        }
        return all.Count > 0;
    }

    /// An HTS 1.15 / HTS120 ROM: the stock ECU's calibration block where it came from (6E17h-7FEEh), then its load breakpoints in mBar through this ROM's MAP formula - what the established software's base map does.
    static string StockIntoHts(DefinitionSet defs, byte[] work, byte[] block, BaseMapPreset bm)
    {
        for (int a = HtsBlockStart; a <= HtsBlockEnd && 144 + a - HtsBlockStart < block.Length; a++) work[a] = block[144 + a - HtsBlockStart];
        foreach (var (at, from) in new[] { (HtsPMapScalar, 0), (HtsSMapScalar, 48) })
        {
            var it = defs.Items.FirstOrDefault(i => i.Address == at && i.Count > 1);
            if (it == null) continue;
            for (int i = 0; i < Math.Min(it.Count, 24); i++) RomData.Write(defs, work, it, i, BitConverter.ToInt16(block, from + i * 2));
        }
        return $"base maps from the stock {bm}: the whole calibration block";
    }

    /// Any other ROM: the stock ECU's maps put in the HTS120 template where they came from, then brought across the way Import maps does it - each map to the one here that does the same job, through real units, onto this ROM's breakpoints.
    static string StockByImport(DefinitionSet defs, byte[] work, byte[] block, BaseMapPreset bm, string htsTemplate)
    {
        var asm = TemplateBuild(htsTemplate);
        var from = DefinitionBuilder.FromAssembly(asm, "base");
        from.MergeBuiltinFormulas();
        var src = (byte[])asm.Image.Clone();
        HtsLayout.Apply(from, src);
        StockIntoHts(from, src, block, bm);
        var pairs = MapImport.Pair(from, defs).Where(p => p.To != null && p.From.IsTable && p.From.Rows > 1 && p.From.Cols > 1
                                                          && MapImport.RoleOf(p.From).Kind is "fuel" or "ignition").ToList();
        foreach (var p in pairs) MapImport.Apply(from, src, p.From, defs, work, p.To!, false, MapImport.Scaling.Breakpoints);
        return $"base maps from the stock {bm}: {string.Join(", ", pairs.Select(p => p.To!.Name))}";
    }

    static readonly Dictionary<string, (DateTime When, AssemblyResult Asm)> Templates = new(StringComparer.OrdinalIgnoreCase);
    static AssemblyResult TemplateBuild(string path)
    {
        var when = File.GetLastWriteTimeUtc(path);
        lock (Templates)
        {
            if (Templates.TryGetValue(path, out var t) && t.When == when) return t.Asm;
            var asm = new OkiAssembler().AssembleFile(path);
            Templates[path] = (when, asm);
            return asm;
        }
    }

    /// Boost: on every fuel and ignition map read against a load (mBar) axis, the load columns spread to the boost wanted - the columns up to the air outside kept where they were as far as there is room - and the cells past the air outside filled from the last column below it: fuel added for each bar of boost, timing taken out for each psi.
    static List<string> Boost(DefinitionSet defs, byte[] work, double psi, double fuelPerBar, double retardPerPsi, List<string> notHere)
    {
        var done = new List<string>();
        double top = SeaLevel + psi / 0.0145038;
        var maps = defs.Items.Where(i => i.IsTable && i.Rows > 1 && i.Cols > 3 && i.ColAxis?.Address != null && MapImport.RoleOf(i).Kind is "fuel" or "ignition"
                                         && (defs.Formula(i.ColAxis.Formula).Unit.Contains("bar", StringComparison.OrdinalIgnoreCase) || (i.ColAxis.Formula ?? "").Contains("mbar", StringComparison.OrdinalIgnoreCase)))
                       .ToList();
        if (maps.Count == 0) { notHere.Add("boost: no fuel or ignition map with a load axis in mBar"); return done; }
        foreach (var group in maps.GroupBy(m => m.ColAxis!.Address!.Value))
        {
            var first = group.First();
            var axis = first.ColAxis!;
            int cols = first.Cols;
            var f = defs.Formula(axis.Formula);
            var now = RomData.AxisValues(defs, work, axis, cols);
            double reach = f.ToValue(axis.Type == CellType.U8 ? 255 : 65535);
            double want = Math.Min(top, reach);
            if (want < top - 1) notHere.Add($"boost: the MAP sensor reads up to {reach:0} mBar, short of {top:0} (fit a bigger sensor on the Sensors page)");
            // the new breakpoints: as many boost columns as it takes (2-4), the rest the old ones up to the air outside
            int boostCols = Math.Clamp((int)Math.Ceiling(psi / 4), 2, 4);
            var na = now.Where(v => v <= SeaLevel + 40).ToList();
            int keep = cols - boostCols;
            var keepPts = na.Count <= keep ? na : Enumerable.Range(0, keep).Select(i => na[(int)Math.Round(i * (na.Count - 1) / (double)(keep - 1))]).ToList();
            while (keepPts.Count < keep) keepPts.Add(keepPts[^1] + 10);
            double atm = Math.Max(keepPts[^1], SeaLevel);
            var pts = keepPts.Concat(Enumerable.Range(1, cols - keepPts.Count).Select(i => atm + (want - atm) * i / (cols - keepPts.Count))).ToList();
            // read every map against the old breakpoints first, then move the axis, then write each map back resampled
            var before = group.Select(m => (Map: m, Cells: RomData.Read(defs, work, m).Select(x => x.Value).ToArray())).ToList();
            int step = axis.Stride > 0 ? axis.Stride : (axis.Type is CellType.U16 or CellType.S16 ? 2 : 1);
            for (int i = 0; i < cols; i++) RomData.WriteRaw(work, axis.Address!.Value + i * step, axis.Type, f.ToRaw(pts[i], 0, axis.Type == CellType.U8 ? 255 : 65535));
            var newPts = RomData.AxisValues(defs, work, axis, cols);
            foreach (var (map, cells) in before)
            {
                bool fuel = MapImport.RoleOf(map).Kind == "fuel";
                var want2 = new double[map.Rows * cols];
                for (int r = 0; r < map.Rows; r++)
                {
                    double At(double mbar)
                    {
                        // the old row, a straight line between its points, the ends held
                        if (mbar <= now[0]) return cells[r * cols];
                        for (int k = 1; k < cols; k++)
                            if (mbar <= now[k] || k == cols - 1)
                            {
                                double t = now[k] == now[k - 1] ? 1 : Math.Clamp((mbar - now[k - 1]) / (now[k] - now[k - 1]), 0, 1);
                                return cells[r * cols + k - 1] + (cells[r * cols + k] - cells[r * cols + k - 1]) * t;
                            }
                        return cells[r * cols + cols - 1];
                    }
                    double baseAt = At(Math.Min(SeaLevel, now.Max()));
                    for (int k = 0; k < cols; k++)
                    {
                        double p = newPts[k], v;
                        if (p <= SeaLevel + 40) v = At(p);
                        else if (fuel) v = baseAt * (1 + (p - SeaLevel) / 1000 * fuelPerBar / 100);
                        else v = Math.Max(0, baseAt - (p - SeaLevel) * 0.0145038 * retardPerPsi);
                        want2[r * cols + k] = v;
                    }
                }
                // a Honda fuel map stores a byte times its column's multiplier: each column gets the smallest multiplier its biggest value fits under, so the fuel past the air outside is not cut off at 255 counts
                if (map.ColumnScaleAddress is int ms)
                {
                    var mf = defs.Formula(map.Formula);
                    for (int k = 0; k < cols; k++)
                    {
                        double most = Enumerable.Range(0, map.Rows).Max(r => mf.ToRaw(want2[r * cols + k], 0, 255 * 255));
                        work[ms + k] = (byte)Math.Clamp(Math.Ceiling(most / 255), 1, 255);
                    }
                }
                for (int i = 0; i < want2.Length; i++) RomData.Write(defs, work, map, i, want2[i]);
            }
            done.Add($"boost to {psi:0.#} psi: load columns of {string.Join(", ", group.Select(m => m.Name))} spread to {newPts[^1]:0} mBar, " +
                     $"+{fuelPerBar:0} % fuel a bar, -{retardPerPsi:0.##} deg a psi");
        }
        return done;
    }
}
