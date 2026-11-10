using System.Globalization;
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

/// `--offcheck`: an off(...) operand only holds the low byte of its address; the page comes from LRB when the
/// instruction runs. Code that means off(216h) run with a register bank on another page reads or writes somewhere else
/// altogether - on the chip as in the simulator, but nothing complains. Every executed instruction with an off operand
/// is checked, through the drive cycle, on every module with every stock function and on mixes of them.
static class OffCheck
{
    static readonly Regex Off = new(@"off\(\s*([^)]+?)\s*\)", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    static int? Eval(AssemblyResult asm, string e)
    {
        e = e.Trim();
        var m = Regex.Match(e, @"^([A-Za-z_]\w*)\s*(?:([+-])\s*(\d+|[0-9a-fA-F]+h))?$");
        if (m.Success)
        {
            var sym = asm.Symbols.Values.FirstOrDefault(s => s.Name.Equals(m.Groups[1].Value, StringComparison.OrdinalIgnoreCase));
            if (sym == null) return null;
            int v = (int)sym.Value;
            if (m.Groups[3].Success) { int k = Num(m.Groups[3].Value); v = m.Groups[2].Value == "+" ? v + k : v - k; }
            return v;
        }
        return Regex.IsMatch(e, @"^[0-9][0-9a-fA-F]*h$|^\d+$") ? Num(e) : null;
    }

    static int Num(string s) => s.EndsWith('h') || s.EndsWith('H') ? int.Parse(s[..^1], NumberStyles.HexNumber) : int.Parse(s);

    public static int Run(Skeleton sk)
    {
        var stock = sk.Features.Where(f => f.Stock).Select(f => f.Define).ToList();
        var modules = sk.Features.Where(f => !f.Stock).Select(f => f.Define).ToList();
        var builds = new List<List<string>> { stock };
        foreach (var m in modules)
        {
            var d = new List<string>(stock) { m };
            d.AddRange(sk.Feature(m)!.Requires.Where(r => !d.Contains(r)));
            if (sk.Problems(d).Count == 0) builds.Add(d);
            var alone = new List<string> { m }; alone.AddRange(sk.Feature(m)!.Requires);
            if (sk.Problems(alone).Count == 0) builds.Add(alone);
        }
        var found = new System.Collections.Concurrent.ConcurrentDictionary<string, string>();
        var lines = new Dictionary<string, string[]>();
        Parallel.ForEach(builds, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Environment.ProcessorCount - 1) }, defs =>
        {
            var r = sk.Build(defs);
            if (!r.Success) return;
            var asm = r.Assembly!;
            var rom = (byte[])asm.Image.Clone();
            foreach (var f in DefinitionBuilder.FromAssembly(asm, "x").Items.Where(i => i.Flag))
            { int v = (int)f.OnRaw; rom[f.Address] = (byte)v; if (f.ElementSize == 2) rom[f.Address + 1] = (byte)(v >> 8); }
            RomChecksum.Balance(rom, asm.ChecksumAddress ?? 0x7FFF);
            // the page each off() operand means, by instruction address
            var want = new Dictionary<ushort, (int Page, string Where)>();
            foreach (var e in asm.SourceMap)
            {
                string[] text;
                lock (lines) { if (!lines.TryGetValue(e.File, out text!)) lines[e.File] = text = File.ReadAllLines(e.File); }
                if (e.Line - 1 >= text.Length) continue;
                var src = text[e.Line - 1];
                int semi = src.IndexOf(';'); if (semi >= 0) src = src[..semi];
                var m = Off.Match(src);
                if (!m.Success || Eval(asm, m.Groups[1].Value) is not int addr) continue;
                want[(ushort)e.Address] = (addr >> 8, $"{Path.GetFileName(e.File)}:{e.Line}  {src.Trim()}");
            }
            var sim = new Simulator(); sim.LoadRom(rom);
            var eng = sim.Engine; eng.EctCelsius = 85; eng.Rpm = 0; eng.MapKpa = 101; sim.SyncSensors();
            void Go(double secs)
            {
                ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz);
                while (sim.Cpu.Cycles < end && sim.State != RunState.Faulted)
                {
                    ushort pc = sim.Cpu.Pc;
                    if (want.TryGetValue(pc, out var w))
                    {
                        int page = sim.Cpu.Lrb >> 5;
                        if (page != w.Page) found.TryAdd(w.Where, $"meant page {w.Page}, ran with LRB {sim.Cpu.Lrb:X2}h (page {page}) - in {string.Join(" ", defs.Where(d => !stock.Contains(d)).DefaultIfEmpty("stock only"))}");
                    }
                    sim.StepOne();
                    if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
                }
            }
            Go(3);
            foreach (var (rpm, map, tps, secs) in new[] { (850.0, 33.0, 0.0, 1.0), (3000, 60, 20, 1), (7000, 100, 100, 1), (9800, 100, 100, 0.5), (2500, 20, 0, 1), (250, 90, 0, 0.5), (850, 33, 0, 1) })
            {
                eng.Rpm = rpm; eng.MapKpa = map; eng.TpsPct = tps; eng.Cranking = rpm < 400; eng.SpeedKmh = rpm > 2000 ? 90 : 0;
                sim.SyncSensors();
                Go(secs);
            }
        });
        foreach (var (where, why) in found.OrderBy(x => x.Key)) Console.WriteLine($"PROBLEM {where}\n        {why}");
        Console.WriteLine(found.IsEmpty ? $"OFFCHECK: every off() ran on the page it means ({builds.Count} builds)" : $"OFFCHECK: {found.Count} off() operand(s) on the wrong page");
        return found.IsEmpty ? 0 : 1;
    }
}
