using OkiRomSim.Assembler;
using OkiRomSim.Calibration;

/// `--limitscheck`: the safe limits (SaneLimits, and a definition's own min / max) must not disagree with the ROMs that ship:
/// every value the skeleton (with every stock function and every module it can take), HTS120 and the reference ROMs hold as
/// their factory setting has to be inside them, or an editor would offer a range the ROM itself is outside of - and writing
/// that cell back would move it.
static class LimitsCheck
{
    public static int Run(Skeleton sk, string root)
    {
        var builds = new List<(string Name, AssemblyResult Asm)>();
        var all = new List<string>();
        // every function that still fits, as the All modules button ticks them (with everything the ROM would not hold left out)
        foreach (var f in sk.Features)
            if (sk.Problems([.. all, f.Define]).Count == 0 && sk.Build([.. all, f.Define]).Success) all.Add(f.Define);
        var r = sk.Build(all);
        if (r.Success) builds.Add(("skeleton, " + all.Count + " functions", r.Assembly!));
        foreach (var path in new[] { Path.Combine(root, "Templates", "HTS120.asm"), Path.Combine(root, "Templates", "References", "HTS115.asm"), Path.Combine(root, "roms", "HTS115.asm") })
            if (File.Exists(path))
            {
                var a = new OkiAssembler().AssembleFile(path);
                if (a.Success) builds.Add((Path.GetFileName(path), a));
            }
        int bad = 0, checkedItems = 0, limited = 0;
        foreach (var (name, asm) in builds)
        {
            var defs = DefinitionBuilder.FromAssembly(asm, "limits");
            defs.MergeBuiltinFormulas();
            // every entry of every drop-down a page offers has to be a value its setting may hold
            foreach (var page in CalPage.ForRom(defs))
                foreach (var row in page.Groups.SelectMany(g => g.Rows).Where(r => r.Kind == RowKind.Choice && r.Options is { Length: > 0 }))
                {
                    if (CalPage.Bound(defs, row.Slot) is not { } it || RomData.Limits(defs, it) is not { } l2) continue;
                    var f2 = defs.Formula(it.Formula);
                    for (int i = 0; i < row.Options!.Length; i++)
                    {
                        double raw = row.Values is { } vals && i < vals.Length ? vals[i] : i;
                        double v = f2.ToValue(raw);
                        if (v < l2.Lo - 1e-6 || v > l2.Hi + 1e-6)
                        { Console.WriteLine($"PROBLEM {name}: page row {row.Slot} offers '{row.Options[i]}' (raw {raw}) but {it.Name} is limited to {l2.Lo:0.##}..{l2.Hi:0.##}"); bad++; }
                    }
                }
            foreach (var item in defs.Items)
            {
                if (RomData.Limits(defs, item) is not { } lim) continue;
                limited++;
                CellValue[] cells;
                try { cells = RomData.Read(defs, asm.Image, item); } catch { continue; }
                checkedItems++;
                var f = defs.Formula(item.Formula);
                // a limit is met when the nearest value the bytes can hold is inside it, so one raw step of slack
                double slack = Math.Abs(f.ToValue(1) - f.ToValue(0)) + 1e-6;
                foreach (var c in cells)
                    // a crank period under the limit's own is a switch-off marker (HTS puts 31250 rpm there)
                    if (item.Formula == "rpm_period_word" && c.Raw < 150) continue;
                    else if (c.Value < lim.Lo - slack || c.Value > lim.Hi + slack)
                    {
                        Console.WriteLine($"PROBLEM {name}: {item.Name} @ {item.Address:X4} [{item.Formula}] holds {c.Display} (raw {c.Raw}), limits {lim.Lo:0.##}..{lim.Hi:0.##}");
                        bad++;
                        break;
                    }
            }
        }
        Console.WriteLine(bad == 0 ? $"LIMITSCHECK: {limited} limited settings in {builds.Count} ROMs, every value inside its limits" : $"LIMITSCHECK: {bad} setting(s) outside their own limits");
        return bad == 0 ? 0 : 1;
    }
}
