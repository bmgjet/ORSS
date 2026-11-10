// --imagehash save|check [file]: the P30 safety net for refactoring the shared modules (the P13 platform layer). Builds the
// bare skeleton, every function on its own (with what it needs), the Default preset, the biggest mix that fits and a few
// seeded random mixes, and writes each image's hash (save) or compares them with the saved ones (check): a P30 build that
// changes by one byte is reported, by build.
using System.Security.Cryptography;
using OkiRomSim.Calibration;

static class ImageHash
{
    public static int Run(Skeleton sk, string mode, string file)
    {
        var builds = new List<(string Name, string[] Defs)> { ("bare", []) };
        foreach (var f in sk.Features) builds.Add((f.Define, [f.Define, .. f.Requires]));
        builds.Add(("Default", [.. SkeletonPresets.Default]));
        var big = new List<string>();
        foreach (var f in sk.Features.Where(f => f.Define is not "FEAT_STOCK_SERIAL" and not "FEAT_DLQD3"))
            if (sk.Problems([.. big, f.Define]).Count == 0 && sk.Build([.. big, f.Define]).Success) big.Add(f.Define);
        builds.Add(("biggest", [.. big]));
        var rnd = new Random(20261010);
        var mods = sk.Features.Where(f => !f.Stock).Select(f => f.Define).ToList();
        for (int k = 0; k < 12; k++)
        {
            var pick = new List<string>();
            foreach (var d in mods.OrderBy(_ => rnd.Next()))
            {
                var f = sk.Feature(d)!;
                var with = pick.Concat([d, .. f.Requires]).Distinct().ToList();
                if (sk.Problems(with).Count == 0 && sk.Build(with).Success) pick = with;
                if (pick.Count >= 8 + k) break;
            }
            builds.Add(($"mix{k}", [.. pick]));
        }
        var now = new Dictionary<string, string>();
        foreach (var (name, defs) in builds)
        {
            var b = sk.Build(defs);
            now[name] = b.Success && b.Assembly is { } a ? Convert.ToHexString(SHA256.HashData(a.Image))[..16] + " " + string.Join(",", defs.Order()) : "FAIL " + string.Join(" | ", b.Errors.Take(2));
        }
        if (mode == "save")
        {
            File.WriteAllLines(file, now.Select(kv => $"{kv.Key}\t{kv.Value}"));
            Console.WriteLine($"IMAGEHASH: {now.Count} builds saved to {file}");
            return 0;
        }
        var saved = File.ReadAllLines(file).Select(l => l.Split('\t', 2)).ToDictionary(p => p[0], p => p[1]);
        int bad = 0;
        foreach (var (name, v) in now)
        {
            if (!saved.TryGetValue(name, out var was)) { Console.WriteLine($"  new build {name}: {v}"); continue; }
            if (was != v) { bad++; Console.WriteLine($"  CHANGED {name}: was {was[..Math.Min(40, was.Length)]}, now {(v.StartsWith("FAIL") ? v : v[..Math.Min(40, v.Length)])}"); }
        }
        Console.WriteLine(bad == 0 ? $"IMAGEHASH: all {now.Count} P30 builds byte for byte as saved" : $"IMAGEHASH: {bad} of {now.Count} builds changed");
        return bad;
    }
}
