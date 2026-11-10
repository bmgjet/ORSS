// --importcheck: the skeleton's tables as the calibration list reads them (the ones Show only valid hides), and HTS120's
// maps brought into it each way a table of another size or with other breakpoints can go in.
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;

static class ImportCheck
{
    public static int Run(Skeleton sk, string htsPath)
    {
        int bad = 0;
        var bi = sk.Build([]);
        if (!bi.Success || bi.Assembly == null) { Console.WriteLine("skeleton does not build"); return 1; }
        var here = DefinitionBuilder.FromAssembly(bi.Assembly, "skeleton");
        here.MergeBuiltinFormulas();
        var rom = bi.Assembly.Image;

        Console.WriteLine("== tables the list leaves out with Show only valid");
        foreach (var i in here.Items.Where(i => !i.HasLookup)) Console.WriteLine($"  {i.Name} {i.Rows}x{i.Cols} {i.Formula}");
        foreach (var name in new[] { "IgnitionRpmCorrectionA", "IgnitionRpmCorrectionA2", "IgnitionRpmCorrectionB", "IgnitionRpmCorrectionB2", "HighIdleIgnition", "LowIdleIgnition" })
        {
            var it = here.Find(name);
            if (it == null) { Console.WriteLine($"  MISSING {name}"); bad++; continue; }
            var v = RomData.Read(here, rom, it).Select(c => c.Value).ToArray();
            var ax = RomData.AxisValues(here, rom, it.ColAxis, it.Cols);
            Console.WriteLine($"  {name} at {it.Address:X4} valid={it.HasLookup}: " + string.Join(" ", ax.Zip(v).Take(22).Select(p => $"{p.First:0}:{p.Second:0.##}")));
        }

        var asm = new OkiAssembler().AssembleFile(htsPath);
        var from = DefinitionBuilder.FromAssembly(asm, "hts");
        from.MergeBuiltinFormulas();
        if (HtsLayout.Identify(asm.Image).Layout != HtsLayout.Family.None) HtsLayout.Apply(from, asm.Image);
        var pairs = MapImport.Pair(from, here).Where(p => p.To != null && p.From.IsTable && p.From.Rows > 1 && p.From.Cols > 1).ToList();
        Console.WriteLine($"== {pairs.Count} map(s) paired from {Path.GetFileName(htsPath)}");
        foreach (var p in pairs)
        {
            Console.WriteLine($"  {p.From.Name} {p.From.Rows}x{p.From.Cols} -> {p.To!.Name} {p.To.Rows}x{p.To.Cols}  same layout: {MapImport.SameLayout(from, asm.Image, p.From, here, rom, p.To)}");
            foreach (var mode in Enum.GetValues<MapImport.Scaling>())
            {
                var work = (byte[])rom.Clone();
                var r = MapImport.Apply(from, asm.Image, p.From, here, work, p.To, false, mode);
                var src = RomData.Read(from, asm.Image, p.From);
                var got = RomData.Read(here, work, p.To);
                // Direct: the top left cell is the other table's; Stretch: both corners are
                string corners = $"TL {src[0].Value:0.#}->{got[0].Value:0.#}  BR {src[^1].Value:0.#}->{got[^1].Value:0.#}";
                Console.WriteLine($"    {mode,-11} ok={r.Ok} changed={r.Changed} clamped={r.Clamped}  {corners}  {r.Note}");
                if (!r.Ok) continue;
                double tol(double x) => Math.Max(0.6, Math.Abs(x) * 0.02);
                if (mode != MapImport.Scaling.Breakpoints && Math.Abs(src[0].Value - got[0].Value) > tol(src[0].Value)) { Console.WriteLine("      FAIL: top left corner"); bad++; }
                if (mode == MapImport.Scaling.Stretch && Math.Abs(src[^1].Value - got[^1].Value) > tol(src[^1].Value)) { Console.WriteLine("      FAIL: bottom right corner"); bad++; }
            }
        }
        // a 3 x 3 into a 20 x 10, Direct: the first 3 x 3 cells change, the rest are left
        if (pairs.FirstOrDefault(p => p.To!.ColumnScaleAddress == null) is { } ign)
        {
            var small = new ItemDef
            {
                Name = "small", Address = ign.From.Address, Rows = 3, Cols = 3, Type = ign.From.Type, Formula = ign.From.Formula,
                Stride = ign.From.RowStride,
            };
            var work = (byte[])rom.Clone();
            var before = RomData.Read(here, rom, ign.To!).Select(c => c.Value).ToArray();
            var r = MapImport.Apply(from, asm.Image, small, here, work, ign.To!, false, MapImport.Scaling.Direct);
            var after = RomData.Read(here, work, ign.To!).Select(c => c.Value).ToArray();
            int outside = 0;
            for (int i = 0; i < after.Length; i++) if (!(i / ign.To!.Cols < 3 && i % ign.To.Cols < 3) && Math.Abs(after[i] - before[i]) > 1e-9) outside++;
            Console.WriteLine($"  Direct 3x3 into {ign.To!.Name}: ok={r.Ok} {r.Note}; cells changed outside the 3x3: {outside}");
            if (!r.Ok || outside > 0) { Console.WriteLine("      FAIL"); bad++; }
        }
        Console.WriteLine(bad == 0 ? "IMPORT CHECK PASS" : $"IMPORT CHECK: {bad} failure(s)");
        return bad == 0 ? 0 : 1;
    }
}
