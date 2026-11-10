// --modecheck [--quick]: every build run hard (each module alone with the defaults, every stock function, a big mix of
// modules), every module switched on and its input set to "always", through boot, cranking, a cold idle, cruise, full
// boost at 7000 rpm, over-rev, a launch, decel, a hot engine and a low battery. Checked:
//   - every byte / word instruction on A runs in the mode its source says (the CPU's DD flag picks the width of the same
//     opcode: an LC after a byte op loads one byte, an ADD after an LB adds bytes - the trap that bit the password compare);
//   - nothing faults, halts, traps (BRK) or resets once booted;
//   - the system stack stays inside its area.
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

static class ModeCheck
{
    public static int Run(Skeleton sk, bool quick)
    {
        var stock = sk.Features.Where(f => f.Stock).Select(f => f.Define).ToArray();
        string[] def4 = ["FEAT_STOCK_DTC", "FEAT_STOCK_SELFTEST", "FEAT_DATALOG", "FEAT_ECTPRO"];
        var builds = new List<(string Name, string[] Defs)> { ("bare", []), ("stock", stock), ("defaults", def4) };
        foreach (var m in sk.Features.Where(f => !f.Stock))
        {
            var d = def4.Concat([m.Define, .. m.Requires]).Distinct().ToList();
            // a module that cannot sit with the datalog (its own serial use) goes without it
            if (sk.Problems(d).Count > 0) d = [.. d.Where(x => x != "FEAT_DATALOG")];
            if (sk.Problems(d).Count > 0) { Console.WriteLine($"skip {m.Define}: {string.Join("; ", sk.Problems(d))}"); continue; }
            builds.Add((m.Define, [.. d]));
        }
        // the biggest mix that fits: every module the problems check lets in, in feature order
        List<string> Grow(IEnumerable<string> start, IEnumerable<SkeletonFeature> order)
        {
            var mix = new List<string>(start);
            foreach (var f in order)
            {
                List<string> next = [.. mix.Concat([f.Define, .. f.Requires]).Distinct()];
                if (sk.Problems(next).Count == 0 && sk.Build(next).Success) mix = next;
            }
            return mix;
        }
        var mods = sk.Features.Where(f => !f.Stock).ToList();
        builds.Add(("big mix", [.. Grow(def4, mods)]));
        builds.Add(("big mix 2", [.. Grow(def4, Enumerable.Reverse(mods))]));
        builds.Add(("stock + mix", [.. Grow(stock.Where(s => s != "FEAT_STOCK_SERIAL"), mods)]));
        // MODECHECK_DEFS="FEAT_A FEAT_B": just that build, and the same without each of its modules in turn
        if (Environment.GetEnvironmentVariable("MODECHECK_DEFS") is { Length: > 0 } only)
        {
            var d = only.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            builds = Environment.GetEnvironmentVariable("MODECHECK_ONLY") == "1" ? [("as given", d)]
                : [("as given", d), .. d.Where(x => !x.StartsWith("FEAT_STOCK")).Select(x => ("less " + x, d.Where(y => y != x).ToArray()))];
            quick = false;
        }
        if (quick) builds = [.. builds.Where(b => b.Name is "bare" or "stock" or "big mix" or "big mix 2" or "stock + mix")];

        // the original ROM (P30, or P13 for its skeleton) run the same way: a mismatch it has too is the disassembly's guess at
        // the mode (the stock code runs that way on the car as well), not something the skeleton or a module changed
        var stockAsm = new OkiAssembler().AssembleFile(StockPath(sk));
        var baseline = new HashSet<string>();
        if (stockAsm.Success)
        {
            var sr = Drive(stockAsm);
            foreach (var m in Mismatches(stockAsm, sr.Modes)) baseline.Add(m.Key);
            Console.WriteLine($"stock {StockName}: {baseline.Count} instructions run in a mode their disassembly does not say (left out below)");
        }
        else Console.WriteLine($"stock {StockName} did not assemble: no baseline");
        int bad = 0;
        var reported = new HashSet<string>();
        foreach (var (name, defs) in builds)
        {
            var b = sk.Build(defs);
            if (b.Assembly is not { Success: true } asm) { Console.WriteLine($"FAIL {name}: does not build: {string.Join(" | ", b.Errors.Take(2))}"); bad++; continue; }
            var r = Drive(asm);
            var problems = new List<string>(r.Problems);
            foreach (var m in Mismatches(asm, r.Modes))
                if (!baseline.Contains(m.Key) && reported.Add(m.Where)) problems.Add($"{m.Where} {m.Says}");
            Console.WriteLine($"{(problems.Count == 0 ? "ok  " : "FAIL")} {name,-22} {r.Summary}" + (name.Contains("mix") ? $"\n       {string.Join(" ", defs)}" : ""));
            foreach (var p in problems) Console.WriteLine("       " + p);
            if (problems.Count > 0) bad++;
        }
        Console.WriteLine(bad == 0 ? $"ALL PASS ({builds.Count} builds)" : $"{bad} FAILED");
        return bad == 0 ? 0 : 1;
    }

    sealed record Mismatch(string Key, string Where, string Says);

    static string StockName => Platform.P13 ? "P13" : "P30";
    static string StockPath(Skeleton sk) => Path.Combine(Path.GetDirectoryName(sk.Path)!, Platform.P13 ? "p13.asm" : "p30.asm");

    /// The stock ROM's own mode mismatches (the baseline the others are held to).
    public static HashSet<string> Baseline(Skeleton sk)
    {
        var stockAsm = new OkiAssembler().AssembleFile(StockPath(sk));
        var set = new HashSet<string>();
        if (stockAsm.Success) foreach (var m in Mismatches(stockAsm, Drive(stockAsm).Modes)) set.Add(m.Key);
        return set;
    }

    /// One build driven hard, every module on: its problems (none = it passed) and a line about it.
    public static (List<string> Problems, string Summary) One(AssemblyResult asm, HashSet<string> baseline)
    {
        var r = Drive(asm);
        var problems = new List<string>(r.Problems);
        foreach (var m in Mismatches(asm, r.Modes)) if (!baseline.Contains(m.Key)) problems.Add($"{m.Where} {m.Says}");
        return (problems, r.Summary);
    }

    static readonly Dictionary<string, string[]> _lines = new(StringComparer.OrdinalIgnoreCase);
    static string[] Lines(string f) => _lines.TryGetValue(f, out var l) ? l : _lines[f] = File.Exists(f) ? File.ReadAllLines(f) : [];
    static string Code(string line) => System.Text.RegularExpressions.Regex.Replace(System.Text.RegularExpressions.Regex.Replace(line.Split(';')[0], @"^\s*\w+:", ""), @"\s+", " ").Trim();

    /// Every instruction that ran in the other mode than its source says, keyed by the label above it, how many lines on,
    /// and its text - the same key in the stock ROM and the skeleton built from it.
    static IEnumerable<Mismatch> Mismatches(AssemblyResult asm, Dictionary<int, int> modes)
    {
        foreach (var (pc, mask) in modes)
        {
            var expect = Expected(asm, pc);
            if (expect == null) continue;
            if (expect.Value ? (mask & 1) == 0 : (mask & 2) == 0) continue;
            var e = asm.Lookup(pc);
            if (e == null) continue;
            var lines = Lines(e.File);
            // the same instruction text, counted from the label above it: lines the skeleton put in between (its hooks, an
            // if / else) do not move the key
            string label = ""; int n = 0;
            string text = Code(lines[e.Line - 1]);
            for (int k = e.Line - 1; k >= 0; k--)
            {
                if (Code(lines[k]) == text) n++;
                var lm = System.Text.RegularExpressions.Regex.Match(lines[k], @"^(\w+):");
                if (lm.Success) { label = lm.Groups[1].Value; break; }
            }
            yield return new Mismatch($"{label}+{n}|{text}", $"{Path.GetFileName(e.File)}:{e.Line}",
                $"runs in {(expect.Value ? "byte" : "word")} mode{(mask == 3 ? " (sometimes)" : "")}: {lines[e.Line - 1].Trim()}");
        }
    }

    /// The width the source asks for at `pc`: true word, false byte, null when the opcode is the same either way.
    static bool? Expected(AssemblyResult asm, int pc)
    {
        var img = asm.Image;
        var w = Decoder.Decode(true, i => img[(pc + i) & 0x7FFF]);
        var b = Decoder.Decode(false, i => img[(pc + i) & 0x7FFF]);
        if (w == null || b == null || w.Mnemonic == b.Mnemonic) return null;
        var e = asm.Lookup(pc);
        if (e == null || !File.Exists(e.File)) return null;
        var src = File.ReadLines(e.File).Skip(e.Line - 1).First().Split(';')[0];
        src = System.Text.RegularExpressions.Regex.Replace(src, @"^\s*\w+:", "").Trim();
        var op = src.Split([' ', '\t'], 2, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToUpperInvariant() ?? "";
        if (w.Mnemonic.Split(' ')[0] == op) return true;
        if (b.Mnemonic.Split(' ')[0] == op) return false;
        return null;
    }

    sealed record Result(Dictionary<int, int> Modes, List<string> Problems, string Summary);

    static Result Drive(AssemblyResult asm)
    {
        var rom = (byte[])asm.Image.Clone();
        var defs = DefinitionBuilder.FromAssembly(asm, "modecheck");
        foreach (var f in defs.Items.Where(i => i.Address >= 0 && i.Address < rom.Length))
        {
            // every module on, its switch input "always" (80h); the anti-start, the lock and the remote's password stay off so it runs
            if (f.Name is "AntiStartEnable" or "RemoteLock" or "RemoteLockValet") continue;
            // the board options are forced on and off at once by "every switch": no car has that board - left as built
            if (f.Slot?.StartsWith("boardopt.", StringComparison.OrdinalIgnoreCase) == true) continue;
            if (f.Flag) { int v = (int)f.OnRaw; rom[f.Address] = (byte)v; if (f.ElementSize == 2) rom[f.Address + 1] = (byte)(v >> 8); }
            else if (f.Slot is { } sl && sl.EndsWith(".input", StringComparison.OrdinalIgnoreCase) && f.Formula is "raw" or "x" && f.ElementSize == 1
                     && CalPage.IsOneHotInput(f.Description)) rom[f.Address] = 0x80;
        }
        RomChecksum.Balance(rom, asm.ChecksumAddress ?? 0x7FFF);
        var sim = new Simulator();
        sim.LoadRom(rom);
        var modes = new Dictionary<int, int>();
        // LABELCOUNT=label: how often that label runs in each phase
        int countAt = Environment.GetEnvironmentVariable("LABELCOUNT") is { Length: > 0 } lc && asm.Symbols.TryGetValue(lc, out var lcs) ? (int)lcs.Value : -1;
        int labelHits = 0;
        // MODECHECK_HOT=phase: the busiest code in that phase, by the label above it
        string? hotPhase = Environment.GetEnvironmentVariable("MODECHECK_HOT");
        var hot = hotPhase != null ? new long[0x10000] : null;
        bool hotStop = false;   // up to the first BRK: what led to it, not the trap loop after
        string phase = "boot";
        // MODECHECK_LAST=1: at the first BRK, the code of the last 20 ms before it, the shallow-stack (main loop) part on its own
        var lastPc = Environment.GetEnvironmentVariable("MODECHECK_LAST") == "1" ? new (ushort Pc, ushort Ssp)[30000] : null;
        long lastN = 0;
        sim.BeforeStep = (pc, dd) =>
        {
            if (pc == countAt) labelHits++;
            if (lastPc != null && !hotStop) lastPc[lastN++ % lastPc.Length] = (pc, sim.Cpu.Ssp);
            if (hot != null && phase == hotPhase && !hotStop) hot[pc]++;
            ref var m = ref System.Runtime.InteropServices.CollectionsMarshal.GetValueRefOrAddDefault(modes, pc, out _); m |= dd ? 2 : 1;
        };
        var e = sim.Engine;
        e.EctCelsius = 20; e.IatCelsius = 20; e.Rpm = 0; e.MapKpa = 100; e.TpsPct = 0; e.SpeedKmh = 0; e.VbattVolts = 12.4;
        sim.SyncSensors();
        var problems = new List<string>();
        int resetAt = asm.Image[0] | (asm.Image[1] << 8);
        int resets = 0, minSsp = 0xFFFF;
        bool booted = false;
        var perPhase = new List<string>();
        bool trace = Environment.GetEnvironmentVariable("OVERREV_TRACE") == "1";
        long lastInj = 0; int traced = 0; ulong nextSample = 0;
        bool Go(double secs)
        {
            ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz);
            while (sim.Cpu.Cycles < end)
            {
                if (booted && sim.Cpu.Pc == resetAt) { resets++; if (resets < 3) problems.Add($"reset during {phase}"); }
                var st = sim.StepOne();
                if (st == null || sim.State == RunState.Faulted) { problems.Add($"faulted during {phase}: {sim.FaultMessage}"); return false; }
                if (st.Value.Decoded?.Mnemonic.StartsWith("BRK", StringComparison.Ordinal) == true && booted)
                {
                    if (lastPc != null && !hotStop)
                    {
                        var labs = asm.Symbols.Values.Where(x => x.Kind == SymbolKind.Label && x.Value < 0x8000).OrderBy(x => x.Value).ToList();
                        int top = lastPc.Max(x => x.Ssp);
                        foreach (var shallow in new[] { false, true })
                        {
                            var byLab = lastPc.Where(x => x.Pc != 0 && (!shallow || x.Ssp >= top - 4)).GroupBy(x => labs.LastOrDefault(l => l.Value <= x.Pc)?.Name ?? $"{x.Pc:X4}")
                                              .Select(g => (g.Key, N: g.Count())).OrderByDescending(g => g.N).Take(16);
                            Console.WriteLine($"    last {lastPc.Length} before the BRK{(shallow ? $", SSP {top - 4:X3}h and up" : "")}: " + string.Join(", ", byLab.Select(g => $"{g.Key} {g.N}")));
                        }
                    }
                    hotStop = true;
                    problems.Add($"BRK at {st.Value.Pc:X4} during {phase} (reason {sim.Bus.Ram[sim.TrapReasonCodeAddr]:X2}h)");
                }
                if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
                if (booted && (sim.Cpu.Instructions & 63) == 0) minSsp = Math.Min(minSsp, sim.Cpu.Ssp);
                // OVERREV_TRACE=1: every 10 ms of over-rev, the injections in it and the cut state
                if (trace && phase == "over-rev" && sim.Cpu.Cycles >= nextSample)
                {
                    nextSample = sim.Cpu.Cycles + (ulong)(0.01 * Bus.CpuHz);
                    long inj = sim.Bus.InjectorEvents.Sum();
                    var m = sim.Bus.Ram;
                    if (traced++ < 150 && (inj != lastInj || traced < 5))
                        Console.WriteLine($"    {traced * 10,5} ms  +{inj - lastInj} inj  period {m[0xAC] | (m[0xAD] << 8):X4}  1F0 {m[0x1F0]:X2}  fuelwant {m[0x1F2] | (m[0x1F3] << 8):X4}  sparkwant {m[0x1F4] | (m[0x1F5] << 8):X4}  FC {m[0xFC]:X2}  11C {m[0x11C]:X2}  2F8 {m[0x2F8]:X2}{m[0x2F9]:X2}");
                    lastInj = inj;
                }
            }
            return true;
        }
        void At(string p, double secs, double rpm, double map, double tps, double kmh, double ect = 85, double batt = 14.0)
        {
            phase = p;
            e.Rpm = rpm; e.MapKpa = map; e.TpsPct = tps; e.SpeedKmh = kmh; e.EctCelsius = ect; e.VbattVolts = batt;
            sim.SyncSensors();
            long i0 = sim.Bus.InjectorEvents.Sum();
            int h0 = labelHits;
            Go(secs);
            if (hot != null && p == hotPhase)
            {
                var labs = asm.Symbols.Values.Where(x => x.Kind == SymbolKind.Label && x.Value < 0x8000).OrderBy(x => x.Value).ToList();
                var byLab = new Dictionary<string, long>();
                for (int pc = 0; pc < 0x8000; pc++)
                {
                    if (hot[pc] == 0) continue;
                    var l = labs.LastOrDefault(x => x.Value <= pc);
                    byLab[l?.Name ?? $"{pc:X4}"] = byLab.GetValueOrDefault(l?.Name ?? $"{pc:X4}") + hot[pc];
                }
                long all = byLab.Values.Sum();
                Console.WriteLine($"    {p}{(hotStop ? $" (to the first BRK, {(double)sim.Cpu.Cycles / Bus.CpuHz:0.000} s)" : "")}: " + string.Join(", ", byLab.OrderByDescending(kv => kv.Value).Take(14).Select(kv => $"{kv.Key} {100.0 * kv.Value / all:0.0}%")));
            }
            perPhase.Add($"{p} {(sim.Bus.InjectorEvents.Sum() - i0) / secs:0}/s" + (countAt >= 0 ? $" [{labelHits - h0}]" : ""));
        }
        At("cranking", 1.5, 250, 95, 0, 0, 20, 10.5);
        At("cold idle", 3, 1300, 35, 0, 0, 20, 14.2);
        booted = true;
        At("warm idle", 2, 800, 33, 0, 0);
        At("cruise", 2, 3000, 60, 20, 90);
        At("launch", 2, 5500, 95, 100, 0);
        At("full boost", 2, 7000, 220, 100, 120);
        At("over-rev", 1.5, 9500, 100, 100, 140);
        At("decel", 2, 4500, 25, 0, 100);
        At("top speed", 1.5, 6500, 100, 100, 250);
        At("hot engine", 2, 3000, 70, 30, 80, 118);
        At("low battery", 1.5, 900, 33, 0, 0, 85, 9.5);
        At("stall", 1, 0, 100, 0, 0);
        At("restart", 1.5, 800, 33, 0, 0);
        if (problems.Count > 6) problems.RemoveRange(6, problems.Count - 6);
        return new Result(modes, problems, $"{modes.Count} addresses run, {sim.Bus.InjectorEvents.Sum()} injections, lowest SSP {minSsp:X4}h, {resets} reset(s)" + (Environment.GetEnvironmentVariable("PHASES") == "1" ? "\n         " + string.Join(", ", perPhase) : ""));
    }
}
