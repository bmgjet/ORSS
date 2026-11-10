// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Tests;

/// The skeleton ROMs. P30 first: ROMs built from it have run on cars, so its builds are checked byte for byte against the images saved
/// before any change (tools/p13/p30-images.txt, the safety net SkeletonTest --imagehash keeps). The P13 skeleton is work in progress
/// (bench-tested, not road-tested): the same checks run against images saved by these tests (data/p13-images.txt) - a record of what it
/// builds today, so a change shows up, not a statement that those builds are right.
static class SkeletonTests
{
    public static void P30() => Run("p30", T.P30Part, Path.Combine(T.Root, "tools", "p13", "p30-images.txt"));
    public static void P13() => Run("p13", T.P13Part, T.Data("p13-images.txt"));

    static void Run(string skn, Action part, string imagesFile)
    {
        part();
        var sk = Skeleton.Load(T.Roms(skn + "-skeleton.asm"), anyPlatform: true);
        T.Check($"{skn}: the skeleton and its function modules load", sk.Features.Count > 0, $"{sk.Features.Count} functions, {sk.Features.Count(f => f.Stock)} of them stock");

        var bare = sk.Build([]);
        if (!T.Check($"{skn}: the bare skeleton builds", bare.Success && bare.Assembly != null, string.Join("; ", bare.Errors.Take(2)))) return;
        var img = bare.Assembly!.Image;
        T.Check($"{skn}: the bare image is 32 KB and its 8-bit sum is 0", img.Length == Chip.RomSize && T.Sum8(img) == 0, $"{img.Length} bytes, sum {T.Sum8(img):X2}h");
        T.Check($"{skn}: the checksum byte is where the source puts it (7FFFh)", bare.Assembly.ChecksumAddress == 0x7FFF, $"{bare.Assembly.ChecksumAddress:X4}h");

        // the build-info table: every function has a number, and a build's table names exactly what it was built with
        var numbers = SkeletonRebuild.Numbers(sk);
        var unnumbered = sk.Features.Where(f => !numbers.ContainsValue(f.Define)).Select(f => f.Define).ToList();
        T.Check($"{skn}: every function has a build-info number (so Change functions can see it in a .bin)", unnumbered.Count == 0,
            unnumbered.Count == 0 ? $"{numbers.Count} numbered" : "no number: " + string.Join(", ", unnumbered));
        var dbLines = File.ReadAllLines(Path.Combine(sk.FeaturesDir!, "buildinfo.asm"))
            .Select(l => System.Text.RegularExpressions.Regex.Match(l.Trim(), @"^DB\s+0*([0-9A-Fa-f]+)h$")).Where(m => m.Success)
            .Select(m => Convert.ToInt32(m.Groups[1].Value, 16)).Where(n => n != 0).ToList();
        T.Check($"{skn}: no build-info number is used twice", dbLines.Count == dbLines.Distinct().Count(), $"{dbLines.Count} numbers");
        T.Check($"{skn}: the bare build's table names no function", SkeletonRebuild.FunctionsIn(img, sk) is { Count: 0 });

        var wrong = new List<string>();
        int built = 0;
        foreach (var f in sk.Features)
        {
            string[] defs = [f.Define, .. f.Requires];
            if (sk.Problems(defs).Count > 0) continue;
            var b = sk.Build(defs);
            if (!b.Success || b.Assembly == null)
            {
                // a pick that is too big for the ROM is the builder saying so, not a fault (SkeletonTest --hwcheck lists them)
                if (!b.Errors.Any(e => e.Contains("ROM is full"))) wrong.Add($"{f.Define}: does not build ({string.Join("; ", b.Errors.Take(1))})");
                continue;
            }
            built++;
            var image = b.Assembly.Image;
            if (T.Sum8(image) != 0) wrong.Add($"{f.Define}: sum {T.Sum8(image):X2}h");
            var named = SkeletonRebuild.FunctionsIn(image, sk);
            if (named == null || !named.ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(defs)) wrong.Add($"{f.Define}: table names {(named == null ? "nothing" : string.Join(",", named))}");
        }
        T.Check($"{skn}: each function on its own builds, sums to 0, and its build-info table names exactly what it was built with", wrong.Count == 0,
            wrong.Count == 0 ? $"{built} builds" : string.Join("; ", wrong.Take(6)));

        var def = sk.Build([.. SkeletonPresets.Default]);
        T.Check($"{skn}: the Default preset builds and sums to 0", def.Success && def.Assembly != null && T.Sum8(def.Assembly.Image) == 0, string.Join("; ", def.Errors.Take(1)));
        if (def.Assembly != null)
            T.Check($"{skn}: the Default build's table names the Default functions", SkeletonRebuild.FunctionsIn(def.Assembly.Image, sk)?.ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(SkeletonPresets.Default) == true);

        CheckImages(skn, sk, imagesFile);
        CheckSimulation(skn, sk, part);
    }

    /// The builds SkeletonTest --imagehash makes (bare, each function, Default, the biggest that fits, twelve seeded mixes), each image's
    /// SHA-256 against the saved file.
    static void CheckImages(string skn, Skeleton sk, string file)
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
            now[name] = b.Success && b.Assembly is { } a ? T.Sha256(a.Image)[..16] + " " + string.Join(",", defs.Order()) : "FAIL " + string.Join(" | ", b.Errors.Take(2));
        }
        if (!File.Exists(file))
        {
            T.Skip($"{skn}: every build byte for byte as saved", $"no saved images ({file}); write them with --save-images");
            if (Environment.GetCommandLineArgs().Contains("--save-images")) { File.WriteAllLines(file, now.Select(kv => $"{kv.Key}\t{kv.Value}")); Console.WriteLine($"        saved {now.Count} to {file}"); }
            return;
        }
        var saved = T.ReadPairs(file);
        var changed = now.Where(kv => !saved.TryGetValue(kv.Key, out var was) || was.Trim() != kv.Value.Trim()).Select(kv => kv.Key).ToList();
        T.Check($"{skn}: all {now.Count} builds (bare, each function, Default, biggest, 12 mixes) byte for byte as saved", changed.Count == 0,
            changed.Count == 0 ? Path.GetFileName(file) : "changed: " + string.Join(", ", changed.Take(12)));
    }

    /// The bare and Default builds run in the simulator for three million instructions with the engine held still; the machine (RAM,
    /// registers, cycle count) at every half million against the saved run (data/sim-checkpoints.txt).
    static void CheckSimulation(string skn, Skeleton sk, Action part)
    {
        foreach (var (n, defs) in new[] { ("bare", Array.Empty<string>()), ("Default", SkeletonPresets.Default.ToArray()) })
        {
            var b = sk.Build(defs);
            if (b.Assembly == null) continue;
            SimRun.Compare($"{skn}-skeleton {n}", b.Assembly.Image, part);
        }
    }
}

/// A ROM run in the simulator the same way every time, its state hashed at checkpoints and compared with the saved run.
static class SimRun
{
    public const long Steps = 3_000_000, Every = 500_000;

    public static List<string> Run(string name, byte[] image, Action part)
    {
        part();
        var sim = new Simulator { FastForwardDelayLoops = true };
        sim.LoadRom(image);
        var e = sim.Engine;
        e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; e.EctCelsius = 85; e.IatCelsius = 25; e.VbattVolts = 14.2; e.SpeedKmh = 60;
        sim.SyncSensors();
        var lines = new List<string>();
        for (long i = 1; i <= Steps; i++)
        {
            if (sim.StepOne() == null) { lines.Add($"{name}: stopped at {i}: {sim.FaultMessage}"); break; }
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
            if (i % Every == 0)
            {
                var c = sim.Cpu;
                var h = T.Sha256([.. sim.Bus.Ram, .. BitConverter.GetBytes(c.Pc), .. BitConverter.GetBytes(c.A), .. BitConverter.GetBytes(c.Ssp),
                    .. BitConverter.GetBytes(c.Lrb), .. BitConverter.GetBytes(c.PswU16()), .. BitConverter.GetBytes(c.Cycles)])[..16];
                lines.Add($"{name} @{i}: pc {c.Pc:X4} cycles {c.Cycles} traps {sim.TrapLog.Values.Sum()} state {h}");
            }
        }
        return lines;
    }

    public static void Compare(string name, byte[] image, Action part)
    {
        var now = Run(name, image, part);
        var file = T.Data("sim-checkpoints.txt");
        // --save-checkpoints: this ROM's lines recorded again (a skeleton change that is meant: the new run becomes the baseline)
        if (Environment.GetCommandLineArgs().Contains("--save-checkpoints"))
        {
            var kept = File.ReadAllLines(file).Where(l => !l.StartsWith(name + " @") && !l.StartsWith(name + ":")).ToList();
            File.WriteAllLines(file, kept.Concat(now));
            Console.WriteLine($"        saved {now.Count} checkpoints of {name} to {file}");
        }
        var saved = File.ReadAllLines(file).Where(l => l.StartsWith(name + " @") || l.StartsWith(name + ":")).ToList();
        if (saved.Count == 0) { T.Skip($"{name}: runs in the simulator exactly as saved", "not in data/sim-checkpoints.txt"); return; }
        int firstDiff = Enumerable.Range(0, Math.Max(now.Count, saved.Count)).FirstOrDefault(i => i >= now.Count || i >= saved.Count || now[i] != saved[i], -1);
        T.Check($"{name}: runs in the simulator exactly as saved ({Steps / 1_000_000}M instructions, machine state at {saved.Count} checkpoints)", firstDiff < 0,
            firstDiff < 0 ? now.LastOrDefault() ?? "" : $"first difference: {(firstDiff < now.Count ? now[firstDiff] : "(ended)")} - saved {(firstDiff < saved.Count ? saved[firstDiff] : "(nothing)")}");
    }
}
