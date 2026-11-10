using OkiRomSim.Calibration;
/// --names: every calibration item a ROM made by New ROM > Create shows, annotated and detected.
static class Names
{
    public static void Run(Skeleton sk)
    {
        var mods = sk.Features.Where(f => !f.Stock).Select(f => f.Define).ToList();
        var mix = new List<string>();
        if (Environment.GetEnvironmentVariable("NAMES_STOCK") == "1") mods.AddRange(sk.Features.Where(f => f.Stock).Select(f => f.Define));
        foreach (var d in mods) if (sk.Problems([.. mix, d]).Count == 0) mix.Add(d);
        var b = sk.Build(mix);
        if (!b.Success) { Console.WriteLine("build: " + string.Join("; ", b.Errors.Take(3))); mix.RemoveAll(d => sk.Features.Any(f => f.Stock && f.Define == d) && d != "FEAT_STOCK_EGR" && d != "FEAT_STOCK_DTC" && d != "FEAT_STOCK_HICAMVE" && d != "FEAT_STOCK_AT"); mix.RemoveAll(d => !d.Contains("STOCK")); b = sk.Build(mix); }
        Console.WriteLine("built: " + string.Join(" ", mix));
        var asm = b.Assembly!;
        var defs = DefinitionBuilder.FromAssembly(asm, "created");
        Console.WriteLine($"==== annotated ({defs.Items.Count})");
        foreach (var i in defs.Items.OrderBy(i => i.Address)) Console.WriteLine($"  {i.Address:X4} {i.Name,-30} {i.Category,-24} {(i.IsTable ? $"{i.Rows}x{i.Cols}" : "")} {i.Description}");
        var sources = asm.SourceMap.Select(e => e.File).Distinct().Where(File.Exists).Select(f => (f, File.ReadAllText(f))).ToList();
        var before = defs.Items.Select(i => i.Name).ToHashSet();
        var r = CalibrationDetector.Detect(defs, asm, asm.Image, sources);
        Console.WriteLine($"==== detected: {r.Summary}");
        foreach (var i in defs.Items.Where(i => !before.Contains(i.Name)).OrderBy(i => i.Address)) Console.WriteLine($"  {i.Address:X4} {i.Name,-30} {i.Category,-24} {(i.IsTable ? $"{i.Rows}x{i.Cols}" : "")} {i.Description}");
        if (Environment.GetEnvironmentVariable("NAMES_OUT") is { } outPath)
            File.WriteAllLines(outPath, defs.Items.Where(i => !before.Contains(i.Name)).OrderBy(i => i.Address).Select(i => DefinitionBuilder.ToAnnotation(i, defs)));
    }
}
