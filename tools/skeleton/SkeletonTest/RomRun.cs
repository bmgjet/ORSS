// --romrun file.asm [file.asm...]: boot a ROM on the part it declares ("; processor: MSM66911"), drive it through cranking,
// idle, cruise, full throttle, the rev limit and back to idle, and report each step: injections and sparks a second, the
// injector pulse, the rpm word the ROM keeps, and every reset (a jump to the start vector after boot) or fault.
// ROMRUN_DEFS=NAME,...: defined first; ROMRUN_WATCH=hex: a word's rate; ROMRUN_POKE=addr=val@step,...: RAM bytes set per step; ROMRUN_INJ=1: each injector.
using OkiRomSim.Assembler;
using OkiRomSim.Core;

static class RomRun
{
    public static int Run(string[] files)
    {
        int bad = 0;
        foreach (var f in files)
        {
            var src = File.ReadAllText(f);
            var prof = ProcessorProfile.Declared(src) ?? ProcessorProfile.Msm66207();
            prof.Apply();
            // ROMRUN_DEFS=NAME,NAME: defined ahead of the source (the skeleton's NEED_ switches, say)
            var defs = (Environment.GetEnvironmentVariable("ROMRUN_DEFS") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries);
            var a = defs.Length == 0 ? new OkiAssembler().AssembleFile(f)
                : new OkiAssembler().AssembleText(string.Concat(defs.Select(d => $"define {d.Trim()}\n")) + src, f);
            if (!a.Success) { Console.WriteLine($"{Path.GetFileName(f)}: does not assemble: {string.Join(" | ", a.Diagnostics.Where(d => d.Severity == Severity.Error).Take(3))}"); bad++; continue; }
            Console.WriteLine($"{Path.GetFileName(f)} on {prof.Name} ({Bus.CpuHz / 1e6:0.###} MHz machine clock), {a.Image.Length} bytes");
            // unused space: runs of FFh (or 00h) of 32 bytes and more
            var runs = new List<string>(); int total = 0;
            for (int i = 0; i < a.Image.Length;)
            {
                byte v = a.Image[i]; int j = i;
                while (j < a.Image.Length && a.Image[j] == v) j++;
                if ((v == 0xFF || v == 0x00) && j - i >= 32) { runs.Add($"{i:X4}-{j - 1:X4} ({j - i} x {v:X2})"); total += j - i; }
                i = Math.Max(j, i + 1);
            }
            Console.WriteLine($"  unused runs: {total} bytes: {string.Join(", ", runs)}");
            bad += Drive(a.Image, a, Environment.GetEnvironmentVariable("ROMRUN_RPMWORD") is { } w ? Convert.ToInt32(w, 16) : (Bus.Is66911 ? 0xAE : 0xAC));
        }
        ProcessorProfile.Msm66207().Apply();
        return bad;
    }

    public static int Drive(byte[] rom, AssemblyResult? asm, int rpmWord)
    {
        var sim = new Simulator(); sim.LoadRom(rom);
        var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.VbattVolts = 13.8; e.O2Volts = 0.45; e.BaroKpa = 101;
        var used = new bool[0x480]; bool track = false;
        // the RAM test walks every byte (P13 does it in the background): its own accesses are not a use
        var skip = new bool[0x10000];
        if (asm != null)
        {
            var labs = asm.Symbols.Values.Where(x => x.Kind == SymbolKind.Label && x.Value < 0x8000).OrderBy(x => x.Value).ToList();
            for (int k = 0; k < labs.Count; k++)
                if (labs[k].Name.StartsWith("calchecksum_loop", StringComparison.Ordinal))
                    for (long pc = labs[k].Value; pc < (k + 1 < labs.Count ? labs[k + 1].Value : labs[k].Value + 1); pc++) skip[pc] = true;
        }
        // ...but the test's own variables (its pointer, the byte it saved) are: an address the test code touches on most
        // passes, not once a walk, counts (more than 200 times over the run)
        var testHits = new int[0x480];
        sim.Bus.OnDataRead += x => { if (track && x < 0x480) { if (!skip[sim.Bus.CurrentPc]) used[x] = true; else testHits[x]++; } };
        sim.Bus.OnDataWrite += (x, _, _) => { if (track && x < 0x480) { if (!skip[sim.Bus.CurrentPc]) used[x] = true; else testHits[x]++; } };
        int start = rom[0] | (rom[1] << 8);
        int resets = 0; bool booted = false;
        int minSsp = 0xFFFF;
        // the spark's crank angle: cycles from the last TDC pulse to each spark, averaged over the step
        // ROMRUN_HOT=1: the busiest code of each step, by nearest label
        var hot = Environment.GetEnvironmentVariable("ROMRUN_HOT") == "1" ? new long[0x10000] : null;
        var hotLabs = asm?.Symbols.Values.Where(x => x.Kind == SymbolKind.Label && x.Value < 0x8000).OrderBy(x => x.Value).ToList();
        // ROMRUN_WRITES=hex[@secs]: the first 40 writes that change that RAM byte (from that time on), with the code that made them
        if (Environment.GetEnvironmentVariable("ROMRUN_WRITES") is { } wr)
        {
            var wparts = wr.Split('@');
            int wa = Convert.ToInt32(wparts[0], 16), shown = 0;
            ulong wfrom = wparts.Length > 1 ? (ulong)(double.Parse(wparts[1], System.Globalization.CultureInfo.InvariantCulture) * Bus.CpuHz) : 0;
            sim.Bus.OnDataWrite += (x, was, now) =>
            {
                if (x != wa || was == now || shown >= 40 || sim.Cpu.Cycles < wfrom) return;
                shown++;
                int pc = sim.Bus.CurrentPc;
                var l = hotLabs?.LastOrDefault(y => y.Value <= pc);
                Console.WriteLine($"    {wa:X3}h {was:X2} -> {now:X2} at {pc:X4} ({l?.Name}+{pc - (l?.Value ?? 0)}), {(double)sim.Cpu.Cycles / Bus.CpuHz:0.000} s");
            };
        }
        // ROMRUN_BREAK=label: the registers the first 3 times the code gets there
        string? brkName = Environment.GetEnvironmentVariable("ROMRUN_BREAK");
        int brk = brkName != null && asm != null && asm.Symbols.TryGetValue(brkName, out var bs) ? (int)bs.Value : -1, brkShown = 0;
        ulong tdcN = 0, tdcAt = 0; long sparkN = 0; double sparkSum = 0; int sparkCount = 0;
        sim.BeforeStep = (pc, _) =>
        {
            if (booted && pc == start) resets++;
            if (booted) { int ssp = sim.Cpu.Ssp; if (ssp >= 0x80 && ssp < minSsp) minSsp = ssp; }
            if (hot != null) hot[pc]++;
            if (brk >= 0 && pc == brk && brkShown < 3)
            {
                brkShown++;
                Console.WriteLine($"    at {brkName}: A={sim.Cpu.A:X4} DP={sim.Cpu.Dp:X4} X1={sim.Cpu.X1:X4} X2={sim.Cpu.X2:X4} LRB={sim.Cpu.Lrb:X4} SSP={sim.Cpu.Ssp:X4} 27C={sim.Bus.Ram[0x27C] | sim.Bus.Ram[0x27D] << 8:X4}, {(double)sim.Cpu.Cycles / Bus.CpuHz:0.000000} s");
            }
            if (e.TdcPulseCount != tdcN) { tdcN = e.TdcPulseCount; tdcAt = sim.Cpu.Cycles; }
            if (sim.Bus.IgnitionEvents != sparkN) { sparkN = sim.Bus.IgnitionEvents; if (tdcAt != 0) { sparkSum += sim.Cpu.Cycles - tdcAt; sparkCount++; } }
        };
        void Go(double secs)
        {
            ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz);
            while (sim.Cpu.Cycles < end && sim.StepOne() != null) if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
        }
        e.Rpm = 0; e.MapKpa = 101; sim.SyncSensors();
        Go(2.0);
        booted = true; track = true;
        int bad = 0;
        Console.WriteLine($"  {"step",-22} {"inj/s",7} {"ign/s",7} {"pulse ms",9} {"rpm word",9} {"=rpm",6} {"resets",6} {"spark",7}");
        foreach (var (what, rpm, map, tps, kmh, crank) in new[]
        {
            ("cranking 250", 250, 95.0, 0.0, 0.0, true), ("idle 850", 850, 33.0, 0.0, 0.0, false), ("cruise 3000", 3000, 55.0, 15.0, 90.0, false),
            ("WOT 6000", 6000, 100.0, 100.0, 120.0, false), ("WOT 8000", 8000, 100.0, 100.0, 140.0, false), ("rev limit 9000", 9000, 100.0, 100.0, 140.0, false),
            ("decel 3000", 3000, 25.0, 0.0, 90.0, false), ("idle 850", 850, 33.0, 0.0, 0.0, false),
        })
        {
            e.Rpm = rpm; e.MapKpa = map; e.TpsPct = tps; e.SpeedKmh = kmh; e.Cranking = crank; sim.SyncSensors();
            // ROMRUN_POKE=addr=val@step[,...]: a RAM byte set to val at the start of the steps whose name holds
            // that text, to 00 at the others' - a module's request, say (written once: the P13 RAM test reads back what it writes)
            var poke = new Dictionary<int, byte>();
            foreach (var pk in (Environment.GetEnvironmentVariable("ROMRUN_POKE") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries))
            {
                var m = System.Text.RegularExpressions.Regex.Match(pk, @"^([0-9a-fA-F]+)=([0-9a-fA-F]+)@(.+)$");
                if (!m.Success) continue;
                int pa = Convert.ToInt32(m.Groups[1].Value, 16);
                if (what.Contains(m.Groups[3].Value)) poke[pa] = Convert.ToByte(m.Groups[2].Value, 16);
                else poke.TryAdd(pa, 0);
            }
            foreach (var (pa, pv) in poke) sim.Bus.Ram[pa] = pv;
            int r0 = resets;
            Go(1.0);
            long inj0 = sim.Bus.InjectorEvents.Sum(), ign0 = sim.Bus.IgnitionEvents;
            var each0 = sim.Bus.InjectorEvents.ToArray();
            sparkSum = 0; sparkCount = 0;
            int watch = Environment.GetEnvironmentVariable("ROMRUN_WATCH") is { } wv ? Convert.ToInt32(wv, 16) : -1;
            int w0 = watch < 0 ? 0 : sim.Bus.Ram[watch] | sim.Bus.Ram[watch + 1] << 8;
            Go(2.0);
            if (watch >= 0) Console.WriteLine($"    word {watch:X3}h: {((sim.Bus.Ram[watch] | sim.Bus.Ram[watch + 1] << 8) - w0 + 65536) % 65536 / 2.0:0} a second");
            double inj = (sim.Bus.InjectorEvents.Sum() - inj0) / 2.0, ign = (sim.Bus.IgnitionEvents - ign0) / 2.0;
            int word = sim.Bus.Ram[rpmWord] | (sim.Bus.Ram[rpmWord + 1] << 8);
            double rr = word is 0 or 0xFFFF ? 0 : 1875000.0 / word;
            // degrees of crank from the TDC pulse to the spark (the pulse's own place on the crank is the ROM's business:
            // the column is for comparing runs - a retard moves it later, a bigger number)
            string spk = sparkCount == 0 ? "-" : (sparkSum / sparkCount / Bus.CpuHz * rpm / 60.0 * 360.0).ToString("0.0");
            Console.WriteLine($"  {what,-22} {inj,7:0} {ign,7:0} {sim.Bus.InjectorPulseWidthUs / 1000.0,9:0.00} {word,9:X4} {rr,6:0} {resets - r0,6} {spk,7}{(sim.State == RunState.Faulted ? "  FAULT " + sim.FaultMessage : "")}");
            if (hot != null)
            {
                var byLab = new Dictionary<string, long>();
                for (int pc = 0; pc < 0x10000; pc++)
                {
                    if (hot[pc] == 0) continue;
                    var l = hotLabs?.LastOrDefault(x => x.Value <= pc);
                    string n = l == null ? $"{pc:X4}" : l.Name;
                    byLab[n] = byLab.GetValueOrDefault(n) + hot[pc];
                }
                Console.WriteLine($"    D4h={sim.Bus.Ram[0xD4]:X2} hot: " + string.Join(", ", byLab.OrderByDescending(kv => kv.Value).Take(8).Select(kv => $"{kv.Key} {kv.Value}")));
                Array.Clear(hot);
            }
            // ROMRUN_DUMP=hex,hex: those RAM words at the step's end
            if (Environment.GetEnvironmentVariable("ROMRUN_DUMP") is { } dump)
                Console.WriteLine("    " + string.Join("  ", dump.Split(',').Select(h => Convert.ToInt32(h, 16)).Select(a => $"{a:X3}h={sim.Bus.Ram[a] | sim.Bus.Ram[a + 1] << 8:X4}")));
            if (Environment.GetEnvironmentVariable("ROMRUN_INJ") == "1")
                Console.WriteLine($"    each injector a second: {string.Join(" ", sim.Bus.InjectorEvents.Select((n, k) => ((n - each0[k]) / 2.0).ToString("0")))}");
            if (sim.State == RunState.Faulted || resets > r0) bad++;
            if (sim.State == RunState.Faulted) break;
        }
        var runs = new List<string>(); int total = 0;
        for (int x = 0; x < 0x480; x++) if (testHits[x] > 200) used[x] = true;
        for (int x = 0x80; x < 0x480;) { if (used[x]) { x++; continue; } int st = x; while (x < 0x480 && !used[x]) x++; if (x - st >= 2) { runs.Add($"{st:X3}-{x - 1:X3}({x - st})"); total += x - st; } }
        Console.WriteLine($"  lowest SSP after boot: {minSsp:X3}h (the stack grows down from the top of RAM)");
        Console.WriteLine($"  RAM never touched after boot (80h-47Fh, runs of 2+): {total} bytes: {string.Join(" ", runs)}");
        return bad;
    }
}
