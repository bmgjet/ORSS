// --p13try [FEAT_X...]: the porting harness for the P13 skeleton. Loads roms/p13-skeleton.asm with every module, whatever
// its "platforms:" line says, builds each function on its own (with what it needs) and reports which build and which do
// not (the first errors), and which say they are for the P13. With --run, each one that builds is driven through
// RomRun's steps too (resets and faults only).
using OkiRomSim.Calibration;
using OkiRomSim.Core;

static class P13Try
{
    public static int Run(string root, string[] args)
    {
        ProcessorProfile.Msm66911().Apply();      // the 66911's own register names: a module using a P30 one does not build
        var sk = Skeleton.Load(Path.Combine(root, "roms", "p13-skeleton.asm"), anyPlatform: true);
        bool run = args.Contains("--run");
        if (args.Contains("--p13preset"))
        {
            // the New ROM "Default" preset as far as it goes on the P13, and the room left
            var fit = SkeletonPresets.Fit(sk, SkeletonPresets.Default);
            var bf = sk.Build(fit);
            Console.WriteLine($"P13 DEFAULT: {string.Join(" ", fit)}");
            Console.WriteLine($"  left out: {string.Join(" ", SkeletonPresets.ForSkeleton(sk, SkeletonPresets.Default).Except(fit))}");
            if (bf.Assembly != null && bf.Assembly.Symbols.TryGetValue("skel_free_start", out var fs))
                Console.WriteLine($"  free: {0x7F00 - fs.Value} bytes from {fs.Value:X4}");
            if (bf.Assembly != null && args.Contains("--run")) Console.WriteLine(RomRun.Drive(bf.Assembly.Image, bf.Assembly, 0xAE) == 0 ? "  runs" : "  RUN PROBLEM");
            ProcessorProfile.Msm66207().Apply();
            return 0;
        }
        if (args.Contains("--big"))
        {
            // as many functions together as fit, in the catalogue's order: the biggest build there is
            var big = new List<string>();
            foreach (var f in sk.Features.Where(f => f.Platforms.Contains("P13", StringComparer.OrdinalIgnoreCase)))
            {
                List<string> with = [.. big, f.Define, .. f.Requires];
                with = [.. with.Distinct()];
                if (sk.Problems(with).Count != 0) { Console.WriteLine($"  left out {f.Define}: {sk.Problems(with)[0]}"); continue; }
                var bb = sk.Build(with);
                if (!bb.Success) { Console.WriteLine($"  left out {f.Define}: {bb.Errors.FirstOrDefault()}"); continue; }
                big = with;
            }
            var fin = sk.Build(big);
            Console.WriteLine($"P13 BIG: {big.Count} functions, {(fin.Success ? "builds" : "FAILS")}");
            if (fin.Success && args.Contains("--run"))
            {
                int r = RomRun.Drive(fin.Assembly!.Image, fin.Assembly, 0xAE);
                Console.WriteLine(r == 0 ? "  runs" : "  RUN PROBLEM");
            }
            ProcessorProfile.Msm66207().Apply();
            return fin.Success ? 0 : 1;
        }
        if (args.Contains("--defs"))
        {
            // the definitions the app makes of a P13 build: the maps and their axes, read back
            var bd = sk.Build(["FEAT_DUALMAPS"]);
            if (bd.Assembly == null) { Console.WriteLine(string.Join(" | ", bd.Errors.Take(3))); return 1; }
            var defs = DefinitionBuilder.FromAssembly(bd.Assembly, "p13");
            foreach (var it in defs.Items.Where(i => i.Rows > 1 || i.Name.Contains("Scaler")))
            {
                var cells = RomData.Read(defs, bd.Assembly.Image, it);
                Console.WriteLine($"  {it.Name,-14} {it.Address:X4} {it.Rows}x{it.Cols} {it.Formula,-20} first {cells[0].Value:0.##} last {cells[^1].Value:0.##}" +
                    (it.RowAxis != null ? $"  rows {it.RowAxis.Name}" : "") + (it.ColAxis != null ? $"  cols {it.ColAxis.Name}" : ""));
            }
            ProcessorProfile.Msm66207().Apply();
            return 0;
        }
        var only = args.Where(a => a.StartsWith("FEAT_", StringComparison.Ordinal)).ToHashSet();
        int ok = 0, bad = 0;
        foreach (var f in sk.Features.Where(f => only.Count == 0 || only.Contains(f.Define)))
        {
            string[] defs = [f.Define, .. f.Requires];
            var b = sk.Build(defs);
            bool p13 = f.Platforms.Contains("P13", StringComparer.OrdinalIgnoreCase);
            if (!b.Success || b.Assembly == null)
            {
                bad++;
                Console.WriteLine($"  FAIL {f.Define,-22}{(p13 ? " [P13]" : "")} {string.Join(" | ", b.Errors.Take(3).Select(e => e.Replace(Path.Combine(root, "roms"), "")))}");
                continue;
            }
            ok++;
            string extra = "";
            if (run)
            {
                var w = new StringWriter(); var old = Console.Out; Console.SetOut(w);
                int r;
                try { r = RomRun.Drive(b.Assembly.Image, b.Assembly, 0xAE); } finally { Console.SetOut(old); }
                extra = r == 0 ? " runs" : " RUN PROBLEM: " + string.Join(" / ", w.ToString().Split('\n').Where(l => l.Contains("FAULT") || System.Text.RegularExpressions.Regex.IsMatch(l, @"\s[1-9]\d*\s+\S+\s*$")).Take(2).Select(l => l.Trim()));
            }
            Console.WriteLine($"  ok   {f.Define,-22}{(p13 ? " [P13]" : "")}{extra}");
        }
        Console.WriteLine($"P13TRY: {ok} build, {bad} do not");
        ProcessorProfile.Msm66207().Apply();
        return bad;
    }
}
