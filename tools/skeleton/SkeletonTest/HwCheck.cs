using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

/// `--hwcheck [random-mixes]`: the things real hardware does that a plain simulator run forgives, measured from power-up
/// on every build against the build known to work in a car (the skeleton with every stock function):
///   - the longest the internal watchdog (WDT, SFR 11h) goes without its 3Ch/C3h - on the chip that is a reset
///   - the longest the P2.4 heartbeat to the board's external watchdog goes without changing - also a reset
///   - RAM full of rubbish at power-up, as real RAM is, rather than the simulator's zeros
///   - traps (BRK), faults, and whether the engine runs
/// A reset loop - the ECU never finishing its boot, every output strobing - is one of these.
static class HwCheck
{
    static readonly System.Collections.Concurrent.ConcurrentDictionary<string, HashSet<int>> _shared = new(StringComparer.OrdinalIgnoreCase);
    /// The RAM a module file's header says it shares on purpose: ";> shares: 375h-376h (why)".
    static HashSet<int> SharedRam(string file) => _shared.GetOrAdd(file, f =>
    {
        var set = new HashSet<int>();
        if (!File.Exists(f)) return set;
        foreach (var line in File.ReadLines(f).Take(40))
        {
            var m = System.Text.RegularExpressions.Regex.Match(line, @"^;>\s*shares:\s*([0-9A-Fa-f]+)h(?:-([0-9A-Fa-f]+)h)?");
            if (!m.Success) continue;
            int a = Convert.ToInt32(m.Groups[1].Value, 16), b = m.Groups[2].Success ? Convert.ToInt32(m.Groups[2].Value, 16) : a;
            for (int x = a; x <= b; x++) set.Add(x);
        }
        return set;
    });

    public sealed record Result(string Name, double WdtBootMs, double WdtRunMs, string WdtWorstAt, double BeatMs, string BeatWorstAt,
                                List<string> Traps, double InjPerSec, bool Faulted, double BootMs)
    {
        /// Each trap as "BRK rr at|label" and how often: a trap the stock build takes as often (the P13 boots through a BRK
        /// on purpose) is not one to report.
        public Dictionary<string, long> TrapCounts { get; init; } = [];
    }

    /// The traps of a run that the yardstick does not take as often (anything else it reports - a CPU fault - always).
    static IEnumerable<string> NewTraps(Result r, Dictionary<string, long> stockCounts)
    {
        foreach (var t in r.Traps)
        {
            if (!t.StartsWith("BRK ", StringComparison.Ordinal)) { yield return t; continue; }
            var kv = r.TrapCounts.FirstOrDefault(c => t.StartsWith(c.Key.Split('|')[0] + " ", StringComparison.Ordinal) && t.Contains(" " + c.Key.Split('|')[1] + " x", StringComparison.Ordinal));
            if (kv.Key == null || kv.Value > stockCounts.GetValueOrDefault(kv.Key)) yield return t;
        }
    }

    static Dictionary<string, long> MaxCounts(IEnumerable<Result> rs)
    {
        var d = new Dictionary<string, long>();
        foreach (var r in rs) foreach (var (k, v) in r.TrapCounts) d[k] = Math.Max(d.GetValueOrDefault(k), v);
        return d;
    }

    static readonly (string Name, double Secs, Action<EngineState> Set)[] Drive =
    [
        ("idle", 1.5, e => { e.Cranking = false; e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; }),
        ("cruise", 1.0, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; e.SpeedKmh = 80; }),
        ("WOT", 1.0, e => { e.Rpm = 7000; e.MapKpa = 100; e.TpsPct = 100; e.SpeedKmh = 140; e.KnockIntensity = 0.5; }),
        ("over-rev", 1.0, e => { e.Rpm = 9800; e.KnockIntensity = 0; }),
        ("decel", 1.0, e => { e.Rpm = 3000; e.MapKpa = 20; e.TpsPct = 0; }),
        ("cold", 1.0, e => { e.Rpm = 1200; e.MapKpa = 35; e.EctCelsius = -30; e.IatCelsius = -30; e.SpeedKmh = 0; }),
        ("stall", 1.0, e => { e.Rpm = 0; e.MapKpa = 101; e.EctCelsius = 85; e.IatCelsius = 25; }),
        ("crank", 1.0, e => { e.Cranking = true; e.Rpm = 250; e.VbattVolts = 9.5; }),
        ("idle again", 1.0, e => { e.Cranking = false; e.Rpm = 850; e.MapKpa = 33; e.VbattVolts = 14.2; }),
    ];

    public static Result Run(string name, byte[] rom, AssemblyResult asm, int? ramSeed)
    {
        var sim = new Simulator(); sim.LoadRom(rom);
        if (ramSeed is int seed)
        {
            var rng = new Random(seed);
            for (int a = 0x80; a < 0x480; a++) sim.Bus.Ram[a] = (byte)rng.Next(256);
        }
        var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 0; e.MapKpa = 101; e.VbattVolts = 12.4;
        sim.SyncSensors();
        double hz = Bus.CpuHz;
        ulong lastWdt = 0, bootEnd = (ulong)(3 * hz);
        double wdtBoot = 0, wdtRun = 0, beat = 0; string wdtAt = "", beatAt = "";
        ulong lastBeat = 0; long beats = 0;
        double bootMs = -1;
        var ring = new Queue<(ulong At, string What)>();
        string? trapWhy = null;
        sim.Bus.OnDataWrite = (addr, _, val) =>
        {
            if (addr != Bus.SfrWdt || val != 0xC3) return;
            ulong now = sim.Cpu.Cycles;
            double ms = (now - lastWdt) / hz * 1000;
            var where = $"{sim.Bus.CurrentPc:X4} {asm.LabelAt(sim.Bus.CurrentPc)}";
            if (now <= bootEnd) { if (ms > wdtBoot) { wdtBoot = ms; wdtAt = "boot, cleared at " + where; } }
            else if (ms > wdtRun) { wdtRun = ms; if (ms > wdtBoot) wdtAt = "running, cleared at " + where; }
            lastWdt = now;
        };
        void Steps(double secs)
        {
            ulong end = sim.Cpu.Cycles + (ulong)(secs * hz);
            while (sim.Cpu.Cycles < end && sim.State != RunState.Faulted)
            {
                var st = sim.StepOne();
                // the interrupts taken just before a trap: which handler ran long
                if (sim.LastStepInterrupted) ring.Enqueue((sim.Cpu.Cycles, "enter " + asm.LabelAt(sim.Cpu.Pc)));
                else if (st?.Decoded is { } d && d.Mnemonic.StartsWith("RTI", StringComparison.Ordinal)) ring.Enqueue((sim.Cpu.Cycles, $"RTI at {st.Value.Pc:X4} {asm.LabelAt(st.Value.Pc)}"));
                while (ring.Count > 24) ring.Dequeue();
                if (st?.Decoded is { } bd && bd.Mnemonic.StartsWith("BRK", StringComparison.Ordinal) && trapWhy == null)
                    trapWhy = $"before BRK {sim.Bus.Ram[sim.TrapReasonCodeAddr]:X2}: " + string.Join(" | ", ring.Select(r => $"{((long)sim.Cpu.Cycles - (long)r.At) / (hz / 1e6):0}us ago {r.What}"));
                if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
                long c = sim.Bus.Pins.Changes[2, 4];
                if (c != beats)
                {
                    ulong now = sim.Cpu.Cycles;
                    double ms = (now - lastBeat) / hz * 1000;
                    if (beats > 0 && ms > beat) { beat = ms; beatAt = $"{(now <= bootEnd ? "boot" : "running")}, changed at {sim.Bus.Pins.LastDriverPc[2, 4]:X4} {asm.LabelAt(sim.Bus.Pins.LastDriverPc[2, 4])}"; }
                    if (beats == 0 && bootMs < 0) bootMs = now / hz * 1000;
                    beats = c; lastBeat = now;
                }
            }
        }
        // power-up with the key on, the engine still: the boot
        Steps(3);
        long inj0 = 0; double injSecs = 0;
        foreach (var (step, secs, set) in Drive)
        {
            set(e); sim.SyncSensors();
            long before = sim.Bus.InjectorEvents.Sum();
            Steps(secs);
            if (step is "idle" or "cruise" or "WOT") { inj0 += sim.Bus.InjectorEvents.Sum() - before; injSecs += secs; }
            if (sim.State == RunState.Faulted) break;
        }
        // the gap still open at the end counts too: a watchdog that stopped being cleared altogether
        double tailWdt = (sim.Cpu.Cycles - lastWdt) / hz * 1000;
        if (tailWdt > wdtRun) { wdtRun = tailWdt; wdtAt = "never cleared again after " + (lastWdt / hz).ToString("0.00") + " s"; }
        double tailBeat = (sim.Cpu.Cycles - lastBeat) / hz * 1000;
        if (tailBeat > beat) { beat = tailBeat; beatAt = beats == 0 ? "never toggled" : "stopped after " + (lastBeat / hz).ToString("0.00") + " s"; }
        var traps = sim.TrapLog.Select(kv => $"BRK {kv.Key.Reason:X2} at {kv.Key.Pc:X4} {asm.LabelAt(kv.Key.Pc)} x{kv.Value}").ToList();
        if (trapWhy != null && Environment.GetEnvironmentVariable("HWCHECK_WHY") == "1") traps.Add(trapWhy);
        if (sim.State == RunState.Faulted) traps.Add($"CPU fault: {sim.FaultMessage} at {sim.Cpu.Pc:X4} {asm.LabelAt(sim.Cpu.Pc)}");
        var counts = new Dictionary<string, long>();
        foreach (var kv in sim.TrapLog) { var k = $"BRK {kv.Key.Reason:X2} at|{asm.LabelAt(kv.Key.Pc)}"; counts[k] = counts.GetValueOrDefault(k) + kv.Value; }
        return new Result(name, wdtBoot, wdtRun, wdtAt, beat, beatAt, traps, injSecs > 0 ? inj0 / injSecs : 0, sim.State == RunState.Faulted, bootMs) { TrapCounts = counts };
    }

    /// `--hwone [stock] DEFINE...`: one build (with every stock function when "stock" is given), said in full.
    public static int One(Skeleton sk, string[] args)
    {
        var defs = new List<string>();
        foreach (var a in args)
            if (a == "stock") defs.AddRange(sk.Features.Where(f => f.Stock).Select(f => f.Define));
            else defs.Add(a);
        var r = sk.Build(defs);
        if (!r.Success) { Console.WriteLine(string.Join(" | ", r.Errors)); return 2; }
        // module RAM in use: the symbols modules put in it
        var asm0 = r.Assembly!;
        if (asm0.Symbols.Values.FirstOrDefault(x => x.Name.Equals("MOD_RAM_BASE", StringComparison.OrdinalIgnoreCase)) is { } mb)
        {
            var inRam = asm0.Symbols.Values.Where(x => x.Value >= mb.Value && x.Value < 0x480 && x.Kind != SymbolKind.Label && !x.Name.StartsWith("MOD_RAM", StringComparison.OrdinalIgnoreCase)).OrderBy(x => x.Value).ToList();
            Console.WriteLine($"module RAM from {mb.Value:X3}h: {inRam.Count} names, highest {(inRam.Count > 0 ? $"{inRam[^1].Value:X3}h {inRam[^1].Name}" : "-")}");
        }
        {
            var q = new Simulator(); q.LoadRom((byte[])r.Assembly!.Image.Clone());
            q.Engine.EctCelsius = 85; q.SyncSensors();
            for (ulong end = (ulong)(6 * Bus.CpuHz); q.Cpu.Cycles < end && q.State != RunState.Faulted;) { q.StepOne(); if ((q.Cpu.Instructions & 1023) == 0) q.SyncSensors(); }
            Console.WriteLine($"after 6 s: 0FDh = {q.Bus.Ram[0xFD]:X2}, tick word {q.Bus.Ram[0xFE] | (q.Bus.Ram[0xFF] << 8)}");
        }
        // HWONE_ON=1: every on/off switch on, as --pairs and --hwcheck's "[switches on]" run it
        var img = (byte[])r.Assembly!.Image.Clone();
        if (Environment.GetEnvironmentVariable("HWONE_ON") == "1")
        {
            foreach (var f in DefinitionBuilder.FromAssembly(r.Assembly, "hw").Items.Where(i => i.Flag))
            {
                int v = (int)f.OnRaw; img[f.Address] = (byte)v; if (f.ElementSize == 2) img[f.Address + 1] = (byte)(v >> 8);
            }
            RomChecksum.Balance(img, r.Assembly.ChecksumAddress ?? 0x7FFF);
        }
        var z = Run("one", img, r.Assembly, null);
        Console.WriteLine($"wdt {Math.Max(z.WdtBootMs, z.WdtRunMs):0.0} ms ({z.WdtWorstAt}), beat {z.BeatMs:0.0} ms ({z.BeatWorstAt}), inj/s {z.InjPerSec:0}");
        foreach (var t in z.Traps) Console.WriteLine("  " + t);
        return z.Traps.Count == 0 ? 0 : 1;
    }

    /// `--pairs [--quick]`: every two modules File > New ROM lets be ticked together, with every stock function (what goes in a car)
    /// and without (--quick: with only), so no pair is incompatible without the builder knowing:
    ///   - it builds, or stops only for room (too big, module RAM full), which the builder shows and will not create
    ///   - no calibration slot (a page row) is claimed by both, and no fixed RAM byte is named by both
    ///   - from power-up with every switch on it runs as stock does: no trap, the watchdog and heartbeat kept, the engine running
    public static int Pairs(Skeleton sk, bool quick)
    {
        var stock = sk.Features.Where(f => f.Stock).Select(f => f.Define).ToList();
        var modules = sk.Features.Where(f => !f.Stock).Select(f => f.Define).ToList();
        var builds = new List<(string Name, List<string> Defs)>();
        int declared = 0;
        for (int i = 0; i < modules.Count; i++)
            for (int j = i + 1; j < modules.Count; j++)
                foreach (var withStock in quick ? new[] { true } : [true, false])
                {
                    var d = new List<string>(withStock ? stock : []) { modules[i], modules[j] };
                    foreach (var m in new[] { modules[i], modules[j] }) d.AddRange(sk.Feature(m)!.Requires.Where(r => !d.Contains(r)));
                    // a stock function a module cannot be built with makes way for it, as the builder does
                    foreach (var m in new[] { modules[i], modules[j] })
                        d.RemoveAll(x => stock.Contains(x) && (sk.Feature(m)!.Conflicts.Contains(x, StringComparer.OrdinalIgnoreCase) || sk.Feature(x)!.Conflicts.Contains(m, StringComparer.OrdinalIgnoreCase)));
                    if (sk.Problems(d).Count > 0) { declared++; continue; }
                    builds.Add(($"{(withStock ? "stock + " : "")}{modules[i]} + {modules[j]}", d));
                }
        Console.WriteLine($"{modules.Count} modules: {builds.Count} pairs to build, {declared} the builder already keeps apart");
        var problems = new System.Collections.Concurrent.ConcurrentBag<string>();
        void Report(string p) { if (!problems.Contains(p)) { problems.Add(p); Console.WriteLine("PROBLEM "+p); } }
        var jobs = new System.Collections.Concurrent.ConcurrentBag<(string Name, byte[] Rom, AssemblyResult Asm)>();
        int roomOnly = 0, built = 0;
        var moduleFiles = sk.Features.Where(f => f.File != null).Select(f => Path.GetFileName(f.File!)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        static string FileOf(string origin) { int c = origin.LastIndexOf(':'); return Path.GetFileName(c > 1 ? origin[..c] : origin); }
        Parallel.ForEach(builds, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Environment.ProcessorCount - 1) }, b =>
        {
            var r = sk.Build(b.Defs);
            if (!r.Success)
            {
                if (r.Over > 0 || r.Ram is { Full: true } || r.Errors.Any(e => e.Contains("module RAM is full"))) { Interlocked.Increment(ref roomOnly); return; }
                Report($"{b.Name}: does not build: {string.Join(" | ", r.Errors.Take(2))}");
                return;
            }
            Interlocked.Increment(ref built);
            var asm = r.Assembly!;
            // a page row claimed by two modules
            var defs = DefinitionBuilder.FromAssembly(asm, "pairs");
            foreach (var g in defs.Items.Where(x => x.Slot != null && x.Origin != null && moduleFiles.Contains(FileOf(x.Origin)))
                                        .SelectMany(x => x.Slot!.Split(';').Select(s => (Slot: s, File: FileOf(x.Origin!))))
                                        .GroupBy(x => x.Slot, StringComparer.OrdinalIgnoreCase)
                                        .Where(g => g.Select(x => x.File).Distinct(StringComparer.OrdinalIgnoreCase).Count() > 1))
                Report($"{b.Name}: page row '{g.Key}' claimed by {string.Join(" and ", g.Select(x => x.File).Distinct())}");
            // a fixed RAM byte two module files name for themselves (module RAM is handed out, so it cannot clash)
            int lo = r.Ram?.Base ?? 0, hi = r.Ram?.End ?? 0;
            foreach (var g in asm.Symbols.Values
                         .Where(s => s.Kind == SymbolKind.Equate && s.File != null && moduleFiles.Contains(Path.GetFileName(s.File))
                                     && s.Value is >= 0x80 and < 0x480 && !(s.Value >= lo && s.Value < hi))
                         .GroupBy(s => s.Value)
                         .Where(g => !g.Any(s => SharedRam(s.File!).Contains((int)s.Value)))     // shared on purpose: the header says so, and why
                         .Where(g => g.Select(s => Path.GetFileName(s.File!)).Distinct(StringComparer.OrdinalIgnoreCase).Count() > 1))
                Report($"{b.Name}: RAM {g.Key:X3}h named by {string.Join(" and ", g.Select(s => $"{Path.GetFileName(s.File!)} ({s.Name})").Distinct())}");
            var on = (byte[])asm.Image.Clone();
            foreach (var f in defs.Items.Where(i => i.Flag))
            {
                int v = (int)f.OnRaw; on[f.Address] = (byte)v; if (f.ElementSize == 2) on[f.Address + 1] = (byte)(v >> 8);
            }
            RomChecksum.Balance(on, asm.ChecksumAddress ?? 0x7FFF);
            jobs.Add((b.Name, on, asm));
        });
        Console.WriteLine($"{built} build, {roomOnly} stop only for room (the builder says so and will not create them)");
        // the build that works in the car, the yardstick
        var st = sk.Build(stock);
        var baseline = Run("STOCK", (byte[])st.Assembly!.Image.Clone(), st.Assembly, null);
        double wdtLimit = Math.Max(baseline.WdtBootMs, baseline.WdtRunMs), beatLimit = baseline.BeatMs;
        var stockTraps = MaxCounts([baseline]);
        Console.WriteLine($"stock: watchdog cleared at least every {wdtLimit:0.0} ms, heartbeat every {beatLimit:0.0} ms; running {jobs.Count} pairs with every switch on");
        int done = 0;
        Parallel.ForEach(jobs, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Environment.ProcessorCount - 1) }, j =>
        {
            var z = Run(j.Name, j.Rom, j.Asm, null);
            double wdt = Math.Max(z.WdtBootMs, z.WdtRunMs);
            if (wdt > wdtLimit * 1.2 + 1) Report($"{j.Name}: watchdog not cleared for {wdt:0.0} ms ({z.WdtWorstAt})");
            if (z.BeatMs > beatLimit * 1.2 + 1) Report($"{j.Name}: heartbeat still for {z.BeatMs:0.0} ms ({z.BeatWorstAt})");
            foreach (var t in NewTraps(z, stockTraps)) Report($"{j.Name}: {t}");
            if (Interlocked.Increment(ref done) % 100 == 0) Console.WriteLine($"  {done} of {jobs.Count}");
        });
        
        Console.WriteLine(problems.IsEmpty ? $"PAIRS: every pair the builder allows builds and runs ({jobs.Count} run)" : $"PAIRS: {problems.Distinct().Count()} problem(s)");
        return problems.IsEmpty ? 0 : 1;
    }

    public static int Main(Skeleton sk, int randomMixes)
    {
        var stock = sk.Features.Where(f => f.Stock).Select(f => f.Define).ToList();
        var modules = sk.Features.Where(f => !f.Stock).Select(f => f.Define).ToList();
        var mixes = new List<(string Name, List<string> Defs)> { ("bare", []), ("STOCK (works in the car)", stock) };
        foreach (var m in modules)
        {
            foreach (var withStock in new[] { false, true })
            {
                var d = new List<string>(withStock ? stock : []) { m };
                d.AddRange(sk.Feature(m)!.Requires.Where(r => !d.Contains(r)));
                if (sk.Problems(d).Count == 0) mixes.Add(((withStock ? "stock + " : "") + m, d));
            }
        }
        var rng = new Random(20260929);
        for (int n = 0; n < randomMixes; n++)
        {
            bool withStock = n % 2 == 0;
            var mix = new List<string>(withStock ? stock : []);
            int want = n % 4 == 0 ? 999 : rng.Next(2, 10);
            int added = 0;
            foreach (var d in modules.OrderBy(_ => rng.Next()))
            {
                if (added >= want) break;
                var trial = mix.Append(d).ToList();
                if (sk.Problems(trial).Count > 0 || !sk.Build(trial).Success) continue;
                mix = trial; added++;
            }
            mixes.Add(($"{(withStock ? "stock + " : "")}mix {n + 1} ({added} modules)", mix));
        }
        var jobs = new List<(string Name, List<string> Defs, byte[] Rom, AssemblyResult Asm)>();
        foreach (var (name, defs) in mixes)
        {
            var r = sk.Build(defs);
            if (!r.Success) { Console.WriteLine($"{name}: does not build: {string.Join(" | ", r.Errors.Take(2))}"); continue; }
            var asm = r.Assembly!;
            jobs.Add((name, defs, (byte[])asm.Image.Clone(), asm));
            // and with every on/off switch it has turned on
            var on = (byte[])asm.Image.Clone();
            foreach (var f in DefinitionBuilder.FromAssembly(asm, "hw").Items.Where(i => i.Flag))
            {
                int v = (int)f.OnRaw; on[f.Address] = (byte)v; if (f.ElementSize == 2) on[f.Address + 1] = (byte)(v >> 8);
            }
            RomChecksum.Balance(on, asm.ChecksumAddress ?? 0x7FFF);
            jobs.Add((name + " [switches on]", defs, on, asm));
        }
        Console.WriteLine($"{jobs.Count} ROMs, each from power-up with zeroed RAM and with RAM full of rubbish");
        var results = new System.Collections.Concurrent.ConcurrentBag<(Result Zero, Result Junk, List<string> Defs)>();
        int done = 0;
        Parallel.ForEach(jobs, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Environment.ProcessorCount - 1) }, j =>
        {
            var z = Run(j.Name, j.Rom, j.Asm, null);
            var k = Run(j.Name, j.Rom, j.Asm, j.Name.GetHashCode());
            results.Add((z, k, j.Defs));
            if (Interlocked.Increment(ref done) % 20 == 0) Console.WriteLine($"  {done} of {jobs.Count}");
        });
        var all = results.OrderBy(r => r.Zero.Name).ToList();
        var baseline = all.Where(r => r.Zero.Name.StartsWith("STOCK")).ToList();
        double wdtLimit = baseline.Max(b => Math.Max(Math.Max(b.Zero.WdtBootMs, b.Zero.WdtRunMs), Math.Max(b.Junk.WdtBootMs, b.Junk.WdtRunMs)));
        double beatLimit = baseline.Max(b => Math.Max(b.Zero.BeatMs, b.Junk.BeatMs));
        var stockTraps = MaxCounts(baseline.SelectMany(b => new[] { b.Zero, b.Junk }));
        Console.WriteLine($"stock (works in the car): watchdog cleared at least every {wdtLimit:0.0} ms, heartbeat changes at least every {beatLimit:0.0} ms");
        int bad = 0;
        var lines = new List<string>();
        foreach (var (z, k, defs) in all)
        {
            var why = new List<string>();
            foreach (var (r, ram) in new[] { (z, "zero RAM"), (k, "rubbish RAM") })
            {
                double wdt = Math.Max(r.WdtBootMs, r.WdtRunMs);
                if (wdt > wdtLimit * 1.2 + 1) why.Add($"{ram}: watchdog not cleared for {wdt:0.0} ms ({r.WdtWorstAt})");
                if (r.BeatMs > beatLimit * 1.2 + 1) why.Add($"{ram}: heartbeat still for {r.BeatMs:0.0} ms ({r.BeatWorstAt})");
                foreach (var t in NewTraps(r, stockTraps)) why.Add($"{ram}: {t}");
                if (!r.Faulted && r.InjPerSec < 5 && !z.Name.Contains("switches on")) why.Add($"{ram}: engine not running ({r.InjPerSec:0} injections/s)");
            }
            string line = $"{z.Name,-60} wdt {Math.Max(z.WdtBootMs, z.WdtRunMs),6:0.0}/{Math.Max(k.WdtBootMs, k.WdtRunMs),6:0.0} ms  beat {z.BeatMs,6:0.0}/{k.BeatMs,6:0.0} ms  inj/s {z.InjPerSec,4:0}/{k.InjPerSec,4:0}";
            lines.Add(line);
            if (why.Count > 0)
            {
                bad++;
                Console.WriteLine("PROBLEM " + line);
                foreach (var w in why.Distinct()) Console.WriteLine("        " + w);
            }
        }
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, "hwcheck.txt"), lines);
        Console.WriteLine(bad == 0 ? "HWCHECK: nothing worse than stock" : $"HWCHECK: {bad} build(s) worse than stock");
        return bad == 0 ? 0 : 1;
    }
}
