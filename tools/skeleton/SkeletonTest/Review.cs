using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

/// `--review [random-mixes]`: a bug and robustness review of the skeleton (with mixes of its modules) and HTS120 (with
/// mixes of its switches). Each mix is built and run twice in the simulator through a hard drive cycle - cranking,
/// idle, WOT, over-rev, decel, cold and hot, railed sensors, low and high battery, a stall and a restart - once at its
/// defaults and once with every on/off switch it has turned on. Watched all the way:
///   - the CPU never faults (an undefined opcode, a jump into data) and the ROM's own BRK traps never fire
///   - the system stack never reaches the RAM below it (module RAM ends at 430h on the skeleton)
///   - every interrupt handler finishes well inside its period (the 2.048 ms tick above all)
///   - which file's code writes each RAM byte: a module byte written by two files, or a module writing outside the RAM
///     the skeleton gives modules, is listed
/// Writes review.txt beside the program.
static class Review
{
    sealed class Watch
    {
        public ushort MinSsp = 0xFFFF;
        public readonly Dictionary<string, (double MaxUs, long Count)> Isr = [];
        public readonly Dictionary<ushort, HashSet<string>> Writers = [];
        public readonly List<string> Faults = [];
        public double BusyPct;      // share of the over-rev step spent in interrupt handlers
        public readonly List<double> InjPerSec = [];
        /// Interrupt handlers that returned with DP, X1, X2 or USP not as they found them (the code they interrupted
        /// carries on with the wrong value): handler -> what changed.
        public readonly Dictionary<string, string> Clobbers = [];
        /// The deepest the stack went outside interrupts, in the first idle and in the idle at the end: the same
        /// conditions, so a difference is a push without its pop somewhere.
        public ushort IdleSsp1 = 0xFFFF, IdleSsp2 = 0xFFFF;
        public string DeepestAt = "";
        /// Module code run again by a nested interrupt while the code it interrupted was in the same module: a file ->
        /// the interrupt chain it happened in. Scratch banks and module RAM are not safe against that.
        public readonly Dictionary<string, string> Reentered = [];
        public string? TrapFirst;
    }

    record Step(string Name, double Secs, Action<EngineState, double> Set);

    static readonly Step[] Cycle =
    [
        new("crank", 1.0, (e, _) => { e.Cranking = true; e.Rpm = 250; e.VbattVolts = 9.5; e.MapKpa = 90; e.TpsPct = 0; }),
        new("idle", 1.5, (e, _) => { e.Cranking = false; e.Rpm = 850; e.VbattVolts = 14.2; e.MapKpa = 33; }),
        new("idle A/C", 1.0, (e, _) => { e.AcRequest = true; }),
        new("to cruise", 1.0, (e, f) => { e.AcRequest = false; e.Rpm = 850 + 2150 * f; e.MapKpa = 33 + 27 * f; e.TpsPct = 20 * f; e.SpeedKmh = 80 * f; }),
        new("WOT pull", 1.5, (e, f) => { e.Rpm = 3000 + 4000 * f; e.MapKpa = 100; e.TpsPct = 100; e.SpeedKmh = 80 + 60 * f; e.KnockIntensity = 0.5; }),
        new("over-rev", 1.0, (e, _) => { e.Rpm = 9800; e.KnockIntensity = 0; }),
        new("decel", 1.5, (e, f) => { e.Rpm = 6000 - 4500 * f; e.MapKpa = 20; e.TpsPct = 0; e.SpeedKmh = 140 - 80 * f; }),
        new("cold", 1.0, (e, _) => { e.Rpm = 1200; e.MapKpa = 35; e.EctCelsius = -30; e.IatCelsius = -30; e.SpeedKmh = 0; }),
        new("hot WOT", 1.0, (e, _) => { e.Rpm = 5000; e.MapKpa = 100; e.TpsPct = 100; e.EctCelsius = 130; e.IatCelsius = 90; e.SpeedKmh = 100; }),
        new("railed high", 1.0, (e, _) => { e.Rpm = 6000; e.MapKpa = 250; e.O2Volts = 1.1; e.SpeedKmh = 255; e.EctCelsius = 85; e.IatCelsius = 25; }),
        new("railed low", 1.0, (e, _) => { e.Rpm = 900; e.MapKpa = 0; e.TpsPct = 0; e.O2Volts = 0; e.SpeedKmh = 0; }),
        new("low battery", 1.0, (e, _) => { e.Rpm = 3000; e.MapKpa = 50; e.TpsPct = 15; e.O2Volts = 0.45; e.VbattVolts = 8.0; }),
        new("high battery", 1.0, (e, _) => { e.VbattVolts = 17.0; }),
        new("stall", 1.0, (e, _) => { e.Rpm = 0; e.MapKpa = 101; e.TpsPct = 0; e.VbattVolts = 12.4; }),
        new("restart", 1.0, (e, _) => { e.Cranking = true; e.Rpm = 250; e.VbattVolts = 9.5; }),
        new("idle again", 1.5, (e, _) => { e.Cranking = false; e.Rpm = 850; e.MapKpa = 33; e.VbattVolts = 14.2; }),
    ];

    static Watch RunCycle(byte[] rom, AssemblyResult asm, bool ramOwners, bool stopOnTrap = false)
    {
        var w = new Watch();
        var sim = new Simulator(); sim.LoadRom(rom);
        var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0;
        sim.SyncSensors();
        bool booted = false;
        var fileOf = new Dictionary<ushort, string>();
        string File(ushort pc)
        {
            if (!fileOf.TryGetValue(pc, out var f)) fileOf[pc] = f = Path.GetFileName(asm.Lookup(pc)?.File ?? "?");
            return f;
        }
        var open = new Stack<(string Name, ulong At, ushort Dp, ushort X1, ushort X2, ushort Usp)>();
        var nested = new Stack<ulong>();   // cycles spent in handlers nested inside each open one
        var interruptedIn = new Stack<(string File, ushort Lrb, ushort Pc)>();   // what each open handler interrupted
        var chose = new Stack<bool>();   // each open handler has set LRB itself
        static ushort Base(ushort lrb) => (ushort)(((lrb >> 5) << 8) | ((lrb & 0x1F) << 3));
        sim.Bus.OnDataWrite = (addr, _, _) =>
        {
            if (!booted) return;
            if (ramOwners && addr >= 0x0F0 && addr <= 0x47F)
            {
                if (!w.Writers.TryGetValue(addr, out var set)) w.Writers[addr] = set = [];
                set.Add(File(sim.Bus.CurrentPc));
            }
            // a handler writing into the register bank the code it interrupted was working in: that code's registers
            // change under it (the hardware saves LRB, not the bank)
            if (open.Count == 0 || !chose.Peek()) return;
            foreach (var (inFile, inLrb, inPc) in interruptedIn)
            {
                ushort b = Base(inLrb);
                if (addr < b || addr > b + 7) continue;
                var here = File(sim.Bus.CurrentPc);
                if (!IsModuleFile(here) && !IsModuleFile(inFile)) break;
                var key = $"{inFile}:{inLrb:X2}:{here}";
                if (!w.Reentered.ContainsKey(key))
                    w.Reentered[key] = $"bank {inLrb:X2}h ({b:X3}h), {addr:X3}h written at {sim.Bus.CurrentPc:X4} {asm.LabelAt(sim.Bus.CurrentPc)} ({here}) " +
                                       $"in {string.Join(" < ", open.Select(o => o.Name))}, while the code at {inPc:X4} {asm.LabelAt(inPc)} ({inFile}) was using it";
                break;
            }
        };
        int idleStep = 0;
        ulong busy = 0, measureFrom = 0, measureTo = 0;
        void Step1()
        {
            var t = sim.StepOne();
            if (t == null) return;
            if (open.Count > 0 && !sim.LastStepInterrupted && !chose.Peek() && t.Value.Text.Contains("LRB") && t.Value.Text.Contains("MOV")) { chose.Pop(); chose.Push(true); }
            if (booted && sim.Cpu.Ssp < w.MinSsp)
            {
                w.MinSsp = sim.Cpu.Ssp;
                w.DeepestAt = $"{t.Value.Pc:X4} {asm.LabelAt(t.Value.Pc)} ({File(t.Value.Pc)}), inside {string.Join(" < ", open.Select(o => o.Name))}";
            }
            if (open.Count == 0 && !sim.LastStepInterrupted)
            {
                if (idleStep == 1 && sim.Cpu.Ssp < w.IdleSsp1) w.IdleSsp1 = sim.Cpu.Ssp;
                if (idleStep == 2 && sim.Cpu.Ssp < w.IdleSsp2) w.IdleSsp2 = sim.Cpu.Ssp;
            }
            if (t.Value.Decoded is { } d && d.Mnemonic.StartsWith("RTI", StringComparison.Ordinal) && open.Count > 0)
            {
                var (name, at, dp, x1, x2, usp) = open.Pop();
                ulong inner = nested.Pop();
                interruptedIn.Pop();
                chose.Pop();
                ulong total = sim.Cpu.Cycles - at;
                if (nested.Count > 0) nested.Push(nested.Pop() + total);
                var c = sim.Cpu;
                if ((c.Dp != dp || c.X1 != x1 || c.X2 != x2 || c.Usp != usp) && !w.Clobbers.ContainsKey(name))
                    w.Clobbers[name] = string.Join(", ", new[] { ("DP", dp, c.Dp), ("X1", x1, c.X1), ("X2", x2, c.X2), ("USP", usp, c.Usp) }
                        .Where(x => x.Item2 != x.Item3).Select(x => $"{x.Item1} {x.Item2:X4} -> {x.Item3:X4}"))
                        + $" (returning at {t.Value.Pc:X4}, {File(t.Value.Pc)})";
                double us = (total - inner) / (Bus.CpuHz / 1e6);
                var cur = w.Isr.GetValueOrDefault(name);
                w.Isr[name] = (Math.Max(cur.MaxUs, us), cur.Count + 1);
                if (open.Count == 0 && sim.Cpu.Cycles > measureFrom && measureFrom != 0 && at < measureTo) busy += sim.Cpu.Cycles - Math.Max(at, measureFrom);
            }
            if (sim.LastStepInterrupted)
            {
                var name = asm.LabelAt(sim.Cpu.Pc);
                // the registers as the interrupted code had them (the step that took the interrupt changed none of them)
                var c = sim.Cpu;
                open.Push((name.Length > 0 ? name : $"{c.Pc:X4}", c.Cycles, c.Dp, c.X1, c.X2, c.Usp));
                nested.Push(0);
                interruptedIn.Push((File(t.Value.Pc), c.Lrb, t.Value.Pc));
                chose.Push(false);
            }
        }
        // boot: the power-up wait, then the stack has its working value
        for (ulong end = sim.Cpu.Cycles + (ulong)(5 * Bus.CpuHz); sim.Cpu.Cycles < end && sim.State != RunState.Faulted;)
        {
            Step1();
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
        }
        booted = true;
        foreach (var step in Cycle)
        {
            long inj0 = sim.Bus.InjectorEvents.Sum();
            idleStep = step.Name == "idle" ? 1 : step.Name == "idle again" ? 2 : 0;
            if (step.Name == "over-rev") { measureFrom = sim.Cpu.Cycles; measureTo = sim.Cpu.Cycles + (ulong)(step.Secs * Bus.CpuHz); busy = 0; }
            for (double t = 0; t < step.Secs - 1e-9 && sim.State != RunState.Faulted; t += 0.01)
            {
                step.Set(e, t / step.Secs);
                ulong end = sim.Cpu.Cycles + (ulong)(0.01 * Bus.CpuHz);
                while (sim.Cpu.Cycles < end && sim.State != RunState.Faulted)
                {
                    Step1();
                    if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
                }
            }
            if (step.Name == "over-rev") w.BusyPct = 100.0 * busy / Math.Max(1, measureTo - measureFrom);
            w.InjPerSec.Add((sim.Bus.InjectorEvents.Sum() - inj0) / step.Secs);
            if (w.TrapFirst == null && sim.TrapLog.Count > 0) { w.TrapFirst = step.Name; if (stopOnTrap) break; }
            if (sim.State == RunState.Faulted) { w.Faults.Add($"CPU fault in '{step.Name}': {sim.FaultMessage} at {sim.Cpu.Pc:X4} ({File(sim.Cpu.Pc)})"); break; }
        }
        foreach (var ((pc, reason), n) in sim.TrapLog)
            w.Faults.Add($"BRK trap at {pc:X4} {asm.LabelAt(pc)} ({File(pc)}), reason {reason:X2}, {n} time(s), first in '{w.TrapFirst}'");
        return w;
    }

    /// The RAM the skeleton gives modules (features.inc), and the hook outputs they are meant to write.
    static bool ModuleRam(int a) =>
        a is >= 0x0FB and <= 0x0FF or >= 0x1F0 and <= 0x1FF or >= 0x2F7 and <= 0x2FF or >= 0x374 and <= 0x37E
          or >= 0x3DC and <= 0x42F
          or 0x146 or 0x147 or 0x246 or 0x247;     // XP_FUEL's pulse width word, XP_IGN's advance word

    /// Bytes a module owns outright (so a second writer is a clash); the shared request/service bytes are left out.
    static bool Owned(int a) => a is 0x0FB or >= 0x2F7 and <= 0x2F9 or 0x2FE or 0x2FF or >= 0x374 and <= 0x37E or >= 0x3E0 and <= 0x3EF or >= 0x402 and <= 0x42F;

    static bool IsModuleFile(string f) => f != "p30-skeleton.asm" && f != "?" && f != "HTS120.asm";

    public static int Run(Skeleton sk, string hts120, int randomMixes)
    {
        var report = new List<string>();
        int problems = 0;
        void Say(string s) { Console.WriteLine(s); report.Add(s); }
        void Problem(string s) { problems++; Say("  PROBLEM  " + s); }

        // ---------------------------------------------------------------- the skeleton, with mixes of modules
        var modules = sk.Features.Where(f => !f.Stock).Select(f => f.Define).ToList();
        var mixes = new List<(string Name, List<string> Defs)> { ("bare", []) };
        foreach (var m in modules)
        {
            var one = new List<string> { m };
            one.AddRange(sk.Features.First(f => f.Define == m).Requires);
            if (sk.Problems(one).Count == 0) mixes.Add((m, one));
        }
        var rng = new Random(20260926);
        for (int n = 0; n < randomMixes; n++)
        {
            // a random order, each module added if it goes with the rest and still fits: from small mixes to full ROMs
            var mix = new List<string>();
            int want = n % 3 == 0 ? modules.Count : rng.Next(3, 14);
            foreach (var d in modules.OrderBy(_ => rng.Next()))
            {
                if (mix.Count >= want) break;
                var trial = mix.Append(d).ToList();
                if (sk.Problems(trial).Count > 0) continue;
                if (!sk.Build(trial).Success) continue;
                mix = trial;
            }
            mixes.Add(($"mix {n + 1} ({mix.Count})", mix));
        }
        Say($"skeleton: {mixes.Count} builds (bare, each module alone, {randomMixes} random mixes up to a full ROM)");
        var builds = new List<(string Name, List<string> Defs, SkeletonBuildResult R)>();
        foreach (var (name, defs) in mixes)
        {
            var r = sk.Build(defs);
            if (!r.Success) { Problem($"{name}: does not build: {string.Join(" | ", r.Errors.Take(3))}"); continue; }
            var warns = r.Assembly!.Diagnostics.Where(d => d.Severity == Severity.Warning).ToList();
            foreach (var wd in warns.Take(5)) Problem($"{name}: assembler warning {Path.GetFileName(wd.File)}:{wd.Line} {wd.Message}");
            builds.Add((name, defs, r));
        }
        var fullest = builds.OrderBy(b => b.R.FreeBytes).First();
        Say($"  fullest build: {fullest.Name}, {fullest.R.FreeBytes} bytes free");

        // the switches of each build, read before the runs (the definition builder is not for many threads at once)
        var switches = builds.ToDictionary(b => b.Name, b => DefinitionBuilder.FromAssembly(b.R.Assembly!, "mix").Items.Where(i => i.Flag).ToList());
        var results = new System.Collections.Concurrent.ConcurrentBag<(string Name, List<string> Defs, bool On, Watch W)>();
        int done = 0;
        Parallel.ForEach(builds.SelectMany(b => new[] { (b, false), (b, true) }),
            new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Environment.ProcessorCount - 1) }, job =>
        {
            var ((name, defs, r), on) = job;
            var rom = (byte[])r.Assembly!.Image.Clone();
            if (on) foreach (var f in switches[name]) Put(rom, f, f.OnRaw);
            RomChecksum.Balance(rom, r.Assembly.ChecksumAddress ?? 0x7FFF);
            var w = RunCycle(rom, r.Assembly, ramOwners: true);
            results.Add((name, defs, on, w));
            int k = Interlocked.Increment(ref done);
            if (k % 10 == 0) Console.WriteLine($"    {k} of {builds.Count * 2} runs");
        });
        Report(results.Select(x => (x.Name + (x.On ? " [all switches on]" : ""), x.Defs, x.W)).ToList(), 0x430, Problem, Say, ramCheck: true);

        // ---------------------------------------------------------------- HTS120, with mixes of its switches
        var hasm = new OkiAssembler().AssembleFile(hts120);
        if (!hasm.Success) Problem("HTS120 does not build: " + string.Join(" | ", hasm.Diagnostics.Where(d => d.Severity == Severity.Error).Take(3)));
        else
        {
            foreach (var wd in hasm.Diagnostics.Where(d => d.Severity == Severity.Warning).Take(10)) Problem($"HTS120: assembler warning {Path.GetFileName(wd.File)}:{wd.Line} {wd.Message}");
            var flags = DefinitionBuilder.FromAssembly(hasm, "hts120").Items.Where(i => i.Flag).ToList();
            var hmixes = new List<(string Name, List<ItemDef> On)> { ("defaults", []), ("every switch on", flags) };
            for (int n = 0; n < randomMixes; n++) hmixes.Add(($"switch mix {n + 1}", [.. flags.Where(_ => rng.Next(3) == 0)]));
            Say($"HTS120: {hmixes.Count} runs ({flags.Count} on/off switches: defaults, all on, {randomMixes} random mixes)");
            var hres = new System.Collections.Concurrent.ConcurrentBag<(string, List<string>, Watch)>();
            Parallel.ForEach(hmixes, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Environment.ProcessorCount - 1) }, hm =>
            {
                var rom = (byte[])hasm.Image.Clone();
                foreach (var f in hm.On) Put(rom, f, f.OnRaw);
                RomChecksum.Balance(rom, hasm.ChecksumAddress ?? 0x7FFF);
                hres.Add((hm.Name, [.. hm.On.Select(f => f.Name)], RunCycle(rom, hasm, ramOwners: false)));
            });
            Report([.. hres], 0, Problem, Say, ramCheck: false);
        }

        Say(problems == 0 ? "REVIEW: no problems found" : $"REVIEW: {problems} problem(s)");
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, "review.txt"), report);
        Console.WriteLine("report: " + Path.Combine(AppContext.BaseDirectory, "review.txt"));
        return problems == 0 ? 0 : 1;
    }

    /// `--reviewrom file.asm`: one ROM at its defaults, as a baseline (the stock-derived ROMs the others come from).
    public static int One(string path)
    {
        var a = new OkiAssembler().AssembleFile(path);
        if (!a.Success) { Console.WriteLine("does not build"); return 2; }
        var w = RunCycle((byte[])a.Image.Clone(), a, false);
        Console.WriteLine($"{Path.GetFileName(path)}: faults {w.Faults.Count}, deepest stack {w.MinSsp:X3}h at {w.DeepestAt}");
        foreach (var f in w.Faults) Console.WriteLine("  " + f);
        foreach (var (isr, what) in w.Clobbers) Console.WriteLine($"  interrupt {isr} returns with {what}");
        foreach (var (isr, (us, n)) in w.Isr.OrderByDescending(x => x.Value.MaxUs)) Console.WriteLine($"  {isr}: {us:0} us of its own at most, {n} runs");
        Console.WriteLine($"  injections/s per step: {string.Join(", ", w.InjPerSec.Select(x => x.ToString("0")))}");
        return 0;
    }

    /// `--ramuse file.asm`: every RAM byte the ROM reads or writes once booted, through the drive cycle, as ranges; and the
    /// ranges it never touches (candidates for RAM of our own, to be checked against the source).
    public static int RamUse(string path, Skeleton? sk = null, string[]? defines = null)
    {
        var a = sk != null ? sk.Build(defines ?? []).Assembly! : new OkiAssembler().AssembleFile(path);
        var used = new bool[0x480];
        var sim = new Simulator(); sim.LoadRom((byte[])a.Image.Clone());
        bool on = false;
        sim.Bus.OnDataWrite = (addr, _, _) => { if (on && addr < 0x480) used[addr] = true; };
        sim.DataReadHook = addr => { if (on && addr < 0x480) used[addr] = true; };
        var e = sim.Engine; e.EctCelsius = 85; e.Rpm = 850; e.MapKpa = 33; sim.SyncSensors();
        for (ulong end = sim.Cpu.Cycles + (ulong)(5 * Bus.CpuHz); sim.Cpu.Cycles < end;) { sim.StepOne(); if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
        on = true;
        foreach (var step in Cycle)
            for (double t = 0; t < step.Secs - 1e-9; t += 0.01)
            {
                step.Set(e, t / step.Secs);
                ulong end = sim.Cpu.Cycles + (ulong)(0.01 * Bus.CpuHz);
                while (sim.Cpu.Cycles < end) { sim.StepOne(); if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
            }
        Console.WriteLine($"{Path.GetFileName(path)}: RAM never touched once running (80h-47Fh):");
        for (int i = 0x80; i < 0x480;)
        {
            if (used[i]) { i++; continue; }
            int j = i; while (j < 0x480 && !used[j]) j++;
            if (j - i >= 2) Console.WriteLine($"  {i:X3}h-{j - 1:X3}h  ({j - i} bytes)");
            i = j;
        }
        return 0;
    }

    static bool[] Used(AssemblyResult a)
    {
        var used = new bool[0x480];
        var sim = new Simulator(); sim.LoadRom((byte[])a.Image.Clone());
        bool on = false;
        sim.Bus.OnDataWrite = (addr, _, _) => { if (on && addr < 0x480) used[addr] = true; };
        sim.DataReadHook = addr => { if (on && addr < 0x480) used[addr] = true; };
        var e = sim.Engine; e.EctCelsius = 85; e.Rpm = 850; e.MapKpa = 33; sim.SyncSensors();
        for (ulong end = sim.Cpu.Cycles + (ulong)(5 * Bus.CpuHz); sim.Cpu.Cycles < end;) { sim.StepOne(); if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
        on = true;
        foreach (var step in Cycle)
            for (double t = 0; t < step.Secs - 1e-9; t += 0.01)
            {
                step.Set(e, t / step.Secs);
                ulong end = sim.Cpu.Cycles + (ulong)(0.01 * Bus.CpuHz);
                while (sim.Cpu.Cycles < end) { sim.StepOne(); if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
            }
        return used;
    }

    /// `--stockram`: the RAM each stock function uses that nothing else does (all of them built, against all but it).
    public static int StockRam(Skeleton sk)
    {
        var stock = sk.Features.Where(f => f.Stock && f.Define != "FEAT_STOCK_SELFTEST").Select(f => f.Define).ToList();
        var all = Used(sk.Build(stock).Assembly!);
        Parallel.ForEach(stock, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Environment.ProcessorCount - 1) }, f =>
        {
            var without = Used(sk.Build(stock.Where(x => x != f)).Assembly!);
            var only = Enumerable.Range(0x80, 0x400).Where(a => all[a] && !without[a]).ToList();
            Console.WriteLine($"{f,-26} {only.Count,3} bytes of its own: {string.Join(" ", only.Select(a => a.ToString("X3")))}");
        });
        return 0;
    }

    /// `--stackmap [defines...]`: each interrupt handler's own stack use (from the SSP of the code it interrupted to its
    /// deepest point, not counting handlers nested in it), which handlers were seen nested in which, and the deepest
    /// chain those allow - the worst case, not just the case one drive happened to hit. Every switch on.
    public static int StackMap(Skeleton sk, string[] defines)
    {
        if (defines is ["all"] or ["stockall"])
        {
            // every module that goes with the rest and still fits, in catalogue order (after every stock function, for "stockall")
            var mix = defines[0] == "stockall" ? sk.Features.Where(f => f.Stock).Select(f => f.Define).ToList() : new List<string>();
            foreach (var d in sk.Features.Where(f => !f.Stock).Select(f => f.Define))
            {
                var trial = mix.Append(d).ToList();
                if (sk.Problems(trial).Count == 0 && sk.Build(trial).Success) mix = trial;
            }
            defines = [.. mix];
        }
        var r = sk.Build(defines);
        if (!r.Success) { Console.WriteLine(string.Join(" | ", r.Errors)); return 2; }
        Console.WriteLine("defines: " + string.Join(" ", defines));
        var asm = r.Assembly!;
        var rom = (byte[])asm.Image.Clone();
        foreach (var f in DefinitionBuilder.FromAssembly(asm, "x").Items.Where(i => i.Flag)) Put(rom, f, f.OnRaw);
        RomChecksum.Balance(rom, asm.ChecksumAddress ?? 0x7FFF);
        var sim = new Simulator(); sim.LoadRom(rom);
        var e = sim.Engine; e.EctCelsius = 85; e.Rpm = 850; e.MapKpa = 33; sim.SyncSensors();
        var own = new Dictionary<string, int>();
        var pairs = new HashSet<(string Outer, string Inner)>();
        var open = new Stack<(string Name, ushort Entry, ushort Min)>();
        int mainMin = 0x47E; bool on = false;
        void Step()
        {
            var t = sim.StepOne();
            if (t == null) return;
            if (!on) return;
            ushort ssp = sim.Cpu.Ssp;
            if (t.Value.Decoded is { } d && d.Mnemonic.StartsWith("RTI", StringComparison.Ordinal) && open.Count > 0)
            {
                var (name, entry, min) = open.Pop();
                own[name] = Math.Max(own.GetValueOrDefault(name), entry - min);
            }
            else if (open.Count > 0) { var top = open.Pop(); open.Push((top.Name, top.Entry, Math.Min(top.Min, ssp))); }
            else mainMin = Math.Min(mainMin, ssp);
            if (sim.LastStepInterrupted)
            {
                var name = asm.LabelAt(sim.Cpu.Pc);
                // the SSP of the interrupted code: the entry push is part of this handler's cost
                ushort entry = (ushort)(ssp + 8);
                if (open.Count > 0) { var outer = open.Pop(); open.Push((outer.Name, outer.Entry, Math.Min(outer.Min, entry))); pairs.Add((outer.Name, name)); }
                open.Push((name, entry, ssp));
            }
        }
        for (ulong end = sim.Cpu.Cycles + (ulong)(5 * Bus.CpuHz); sim.Cpu.Cycles < end;) { Step(); if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
        on = true;
        foreach (var step in Cycle)
            for (double t = 0; t < step.Secs - 1e-9; t += 0.01)
            {
                step.Set(e, t / step.Secs);
                ulong end = sim.Cpu.Cycles + (ulong)(0.01 * Bus.CpuHz);
                while (sim.Cpu.Cycles < end) { Step(); if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
            }
        Console.WriteLine($"{defines.Length} modules; main code reached {mainMin:X3}h ({0x47E - mainMin} bytes)");
        foreach (var (n, b) in own.OrderByDescending(x => x.Value)) Console.WriteLine($"  {n,-24} {b,3} bytes of its own");
        Console.WriteLine("  seen nested: " + string.Join(", ", pairs.Select(p => $"{p.Inner} in {p.Outer}")));
        // the worst chain: each handler that lets others in may take any handler seen nested anywhere (they are not
        // masked by which one is running), itself included once more
        var nesters = pairs.Select(p => p.Outer).ToHashSet();
        int leaf = own.Where(x => !nesters.Contains(x.Key)).Select(x => x.Value).DefaultIfEmpty(0).Max();
        int chain = nesters.Sum(n => own.GetValueOrDefault(n)) + (pairs.Any(p => p.Outer == p.Inner) ? pairs.Where(p => p.Outer == p.Inner).Max(p => own[p.Outer]) : 0) + leaf;
        Console.WriteLine($"  worst chain: main {0x47E - mainMin} + every handler that lets others in once ({string.Join(" + ", nesters.Select(n => $"{n} {own.GetValueOrDefault(n)}"))})" +
                          $" + one self-nest + the deepest leaf {leaf} = {0x47E - mainMin + chain} bytes -> {0x47E - (0x47E - mainMin + chain):X3}h");
        return 0;
    }

    /// `--htspair file.asm`: HTS 1.15 (or any HTS ROM) with SCCInvert on and the ECT check switched off, as HTS120's
    /// switches do it: does its own check trap too?
    public static int HtsPair(string path)
    {
        var a = new OkiAssembler().AssembleFile(path);
        if (!a.Success) { Console.WriteLine($"{path} does not build: {string.Join(" | ", a.Diagnostics.Take(2))}"); return 2; }
        int scc = (int)a.Symbols.Values.First(x => x.Name.Equals("SCCInvert", StringComparison.OrdinalIgnoreCase)).Value;
        // the ECT check's switch: the immediate of the LB A, #000h just before dtc06_ect_latch
        int latch = (int)a.Symbols.Values.First(x => x.Name.Equals("dtc06_ect_latch", StringComparison.OrdinalIgnoreCase)).Value;
        int at = -1;
        for (int p = latch - 40; p < latch; p++) if (a.Image[p] == 0x77 && a.Image[p + 1] == 0x00 && a.Lookup(p)?.Address == p) { at = p + 1; break; }
        foreach (var (name, pokes) in new[] { ("defaults", new (int, byte)[0]), ("SCCInvert only", [(scc, (byte)0xFF)]), ("ECT check off only", [(at, (byte)0xFF)]), ("both", [(scc, (byte)0xFF), (at, (byte)0xFF)]) })
        {
            var rom = (byte[])a.Image.Clone();
            foreach (var (ad, v) in pokes) rom[ad] = v;
            RomChecksum.Balance(rom, a.ChecksumAddress ?? 0x7FFF);
            var w = RunCycle(rom, a, false);
            Console.WriteLine($"{Path.GetFileName(path)} {name}: {(w.Faults.Count == 0 ? "no trap" : string.Join("; ", w.Faults))}");
        }
        Console.WriteLine($"(SCCInvert at {scc:X4}, ECT check switch at {at:X4})");
        return 0;
    }

    /// `--sumtest file.asm`: does the ROM check its own 8-bit sum, and when? One byte of the image changed without the sum
    /// put right: before power-up, and again only once it is running.
    public static int SumTest(string path)
    {
        var a = new OkiAssembler().AssembleFile(path);
        if (!a.Success) { Console.WriteLine("does not build"); return 2; }
        // a byte nothing reads: the last of a run of FFh bytes
        int at = -1, run = 0;
        for (int i = a.Image.Length - 2; i > 0x100; i--) { run = a.Image[i] == 0xFF ? run + 1 : 0; if (run >= 32) { at = i + 16; break; } }
        if (at < 0) at = 0x7F80;   // no fill to poke (HTS): a byte of the calibration will do for this
        int? sw = a.Symbols.Values.FirstOrDefault(x => x.Name.Equals("RomSumCheck", StringComparison.OrdinalIgnoreCase)) is { } sy ? (int)sy.Value : null;
        Console.WriteLine($"{Path.GetFileName(path)}: sum {RomChecksum.Sum(a.Image):X2}, poking {at:X4}");
        foreach (var when in sw != null ? new[] { "untouched", "before power-up", "once running", "check on, running" } : new[] { "untouched", "before power-up", "once running" })
        {
            var rom = (byte[])a.Image.Clone();
            if (when == "check on, running" && sw is int swa) { rom[swa] = 1; RomChecksum.Balance(rom, a.ChecksumAddress ?? 0x7FFF); }
            if (when == "before power-up") rom[at] ^= 0x5A;
            var sim = new Simulator(); sim.LoadRom(rom);
            var e = sim.Engine; e.EctCelsius = 85; e.Rpm = 850; e.MapKpa = 33; sim.SyncSensors();
            for (ulong end = sim.Cpu.Cycles + (ulong)(6 * Bus.CpuHz); sim.Cpu.Cycles < end && sim.State != RunState.Faulted;) { sim.StepOne(); if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
            if (when is "once running" or "check on, running") { sim.Bus.Rom[at] ^= 0x5A; }
            long inj0 = sim.Bus.InjectorEvents.Sum();
            for (ulong end = sim.Cpu.Cycles + (ulong)(20 * Bus.CpuHz); sim.Cpu.Cycles < end && sim.State != RunState.Faulted;) { sim.StepOne(); if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
            var traps = string.Join(", ", sim.TrapLog.Select(kv => $"BRK {kv.Key.Reason:X2} at {kv.Key.Pc:X4} x{kv.Value}"));
            Console.WriteLine($"  {when,-16}: {(traps.Length == 0 ? "no trap" : traps)}; {(sim.Bus.InjectorEvents.Sum() - inj0) / 20.0:0} injections/s over 20 s; MIL {(sim.Mil.Lamp ? "on" : "off")}{(sim.Mil.LastRound.Count > 0 ? " codes " + string.Join(" ", sim.Mil.LastRound) : "")}");
        }
        return 0;
    }

    /// `--htsbisect`: which of HTS120's switches (on their own, or the fewest together) make its own checks trap.
    public static int Bisect(string hts120)
    {
        var hasm = new OkiAssembler().AssembleFile(hts120);
        var flags = DefinitionBuilder.FromAssembly(hasm, "hts120").Items.Where(i => i.Flag).ToList();
        bool Traps(List<ItemDef> on)
        {
            var rom = (byte[])hasm.Image.Clone();
            foreach (var f in on) Put(rom, f, f.OnRaw);
            RomChecksum.Balance(rom, hasm.ChecksumAddress ?? 0x7FFF);
            var w = RunCycle(rom, hasm, false, stopOnTrap: true);
            return w.TrapFirst != null;
        }
        Console.WriteLine($"all {flags.Count} switches on: {(Traps(flags) ? "traps" : "no trap")}");
        // each alone, in parallel
        var alone = new System.Collections.Concurrent.ConcurrentBag<string>();
        Parallel.ForEach(flags, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Environment.ProcessorCount / 2) }, f =>
        {
            if (Traps([f])) { alone.Add(f.Name); Console.WriteLine($"  traps on its own: {f.Name} @ {f.Address:X4} (on = {f.OnRaw})"); }
        });
        if (!alone.IsEmpty) return 1;
        // together only: take switches away while it still traps
        var set = new List<ItemDef>(flags);
        for (int chunk = set.Count / 2; chunk >= 1; chunk /= 2)
            for (int i = 0; i < set.Count;)
            {
                var without = set.Take(i).Concat(set.Skip(i + chunk)).ToList();
                if (without.Count > 0 && Traps(without)) set = without; else i += chunk;
            }
        Console.WriteLine("traps together: " + string.Join(", ", set.Select(f => $"{f.Name} @ {f.Address:X4} (on = {f.OnRaw})")));
        return 1;
    }

    static void Put(byte[] rom, ItemDef f, double raw)
    {
        int v = (int)raw;
        rom[f.Address] = (byte)v;
        if (f.ElementSize == 2) rom[f.Address + 1] = (byte)(v >> 8);
    }


    static void Report(List<(string Name, List<string> Defs, Watch W)> runs, int stackFloor, Action<string> problem, Action<string> say, bool ramCheck)
    {
        foreach (var (name, _, w) in runs.OrderBy(r => r.Name))
        {
            foreach (var f in w.Faults) problem($"{name}: {f}");
            if (stackFloor > 0 && w.MinSsp < stackFloor + 8) problem($"{name}: the stack reached {w.MinSsp:X3}h (module RAM ends at {stackFloor:X3}h)");
            foreach (var (isr, what) in w.Clobbers) problem($"{name}: interrupt {isr} returns with {what}");
            foreach (var (_, where) in w.Reentered) problem($"{name}: register bank shared across an interrupt: {where}");
            if (w.IdleSsp2 != 0xFFFF && w.IdleSsp1 != 0xFFFF && w.IdleSsp2 + 8 < w.IdleSsp1)
                problem($"{name}: the stack is deeper at the end than at the start ({w.IdleSsp1:X3}h -> {w.IdleSsp2:X3}h at idle): a push without its pop");
            foreach (var (isr, (us, count)) in w.Isr)
            {
                // its own time (nested interrupts not counted): the 2.048 ms tick must leave room to spare, and nothing
                // should hold the CPU for over a millisecond and a half
                // the crank task and the serial/BRG task are where Honda runs its main work: milliseconds long in stock
                // P30 and HTS 1.15 too, so they are held to the bare build's figure (plus a quarter) instead
                if (isr is "int_crank_sync" or "int_serial_rx_BRG")
                {
                    double bare = runs.Where(r => r.Name is "bare" or "defaults").SelectMany(r => r.W.Isr).Where(x => x.Key == isr).Select(x => x.Value.MaxUs).DefaultIfEmpty(0).Max();
                    if (bare > 0 && us > bare * 1.25) problem($"{name}: interrupt {isr} took {us:0} us of its own once, against {bare:0} us in the bare build");
                    continue;
                }
                if (us > (isr == "int_timer_1" ? 1000 : 1500)) problem($"{name}: interrupt {isr} took {us:0} us of its own once ({count} runs)");
            }
            // the engine has to run where it should: idle, cruise, WOT (steps 1, 3, 4)
            if (w.Faults.Count == 0 && !name.Contains("switch") && !name.Contains("all switches") && (w.InjPerSec.ElementAtOrDefault(1) < 5 || w.InjPerSec.ElementAtOrDefault(4) < 5))
                problem($"{name}: the engine did not run (injections/s idle {w.InjPerSec.ElementAtOrDefault(1):0}, WOT {w.InjPerSec.ElementAtOrDefault(4):0})");
        }
        var all = runs.Select(r => r.W).ToList();
        var deepest = runs.OrderBy(r => r.W.MinSsp).First();
        say($"  deepest stack in '{deepest.Name}': {deepest.W.MinSsp:X3}h at {deepest.W.DeepestAt}");
        say($"  deepest stack: {all.Min(w => w.MinSsp):X3}h;  busiest at 9800 rpm: {all.Max(w => w.BusyPct):0}% of the time in interrupts");
        foreach (var g in all.SelectMany(w => w.Isr).GroupBy(kv => kv.Key).OrderByDescending(g => g.Max(x => x.Value.MaxUs)).Take(6))
            say($"  longest {g.Key}: {g.Max(x => x.Value.MaxUs):0} us");
        if (!ramCheck) return;
        // RAM: every module byte with one owner, and no module writing where modules have no business
        var clash = new SortedDictionary<ushort, HashSet<string>>();
        var outside = new SortedDictionary<string, SortedSet<ushort>>();
        foreach (var (rname, _, w) in runs)
            foreach (var (a, files) in w.Writers)
            {
                var mods = files.Where(IsModuleFile).ToList();
                if (Owned(a) && files.Count > 1 && !clash.ContainsKey(a)) { clash[a] = [.. files, "in " + rname]; }
                foreach (var f in mods.Where(_ => !ModuleRam(a) && a < 0x430))
                {
                    if (!outside.TryGetValue(f, out var s)) outside[f] = s = [];
                    s.Add(a);
                }
            }
        foreach (var (a, files) in clash) problem($"RAM {a:X3}h is written by more than one file: {string.Join(", ", files)}");
        foreach (var (f, addrs) in outside) say($"  {f} writes outside module RAM: {string.Join(" ", addrs.Select(a => $"{a:X3}h"))}");
    }
}
