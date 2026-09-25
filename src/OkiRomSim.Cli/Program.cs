// Copyright (c) bmgjet. All rights reserved.
using System.Diagnostics;
using System.Globalization;
using OkiRomSim.Assembler;
using OkiRomSim.Core;
using OkiRomSim.Cli;

static int Usage()
{
    Console.WriteLine("""
okisim - OKI 66207 toolchain and simulator

  Any command: --cpu MSM66207|MSM66911 (default: what the .asm declares with "; processor: NAME").
  okisim asm <file.asm> [-o out.bin] [-D NAME=value] [-I dir] [--compat] [--lst] [--map] [--sym]
      Assemble a .asm into a byte-exact image. --compat enables lenient mode,
      where undefined symbols / out-of-range branches / duplicate labels warn.
  okisim run <file.bin|file.asm> [--steps N] [--until label|addr]
             [--trace N] [--rpm N] [--tps pct] [--map kPa] [--watch addr[,addr]] [--stall]
      Run headless and print a state summary.
  okisim disasm <file.bin|file.asm> [--from addr] [--count N] [--sym file.sym]

""" + CalCommands.Usage);
    return 2;
}

if (args.Length == 0) return Usage();
var cmd = args[0].ToLowerInvariant();
var rest = args.Skip(1).ToList();
string? Opt(string name)
{
    int i = rest.IndexOf(name);
    if (i < 0 || i + 1 >= rest.Count) return null;
    var v = rest[i + 1]; rest.RemoveRange(i, 2); return v;
}
List<string> Opts(string name)
{
    var l = new List<string>();
    while (Opt(name) is { } v) l.Add(v);
    return l;
}
bool Flag(string name) { int i = rest.IndexOf(name); if (i < 0) return false; rest.RemoveAt(i); return true; }
// --cpu NAME, else whatever the .asm declares ("; processor: MSM66911"), else the MSM66207
void UseCpu()
{
    var name = Opt("--cpu");
    var src = rest.FirstOrDefault(a => a.EndsWith(".asm", StringComparison.OrdinalIgnoreCase) && File.Exists(a));
    var p = name != null ? ProcessorProfile.Builtin(name) ?? throw new ArgumentException($"no processor profile called {name}")
          : src != null ? ProcessorProfile.Declared(File.ReadAllText(src)) : null;
    (p ?? ProcessorProfile.Msm66207()).Apply();
    if (p != null) Console.Error.WriteLine($"processor {p.Name}");
}
static ushort ParseAddr(string s, IReadOnlyDictionary<string, long>? syms = null)
{
    var t = s.Trim();
    if (syms != null && syms.TryGetValue(t, out var v)) return (ushort)v;
    if (t.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) t = t[2..];
    else if (t.EndsWith('h') || t.EndsWith('H')) t = t[..^1];
    return ushort.Parse(t, NumberStyles.HexNumber);
}
static int PrintDiags(IEnumerable<Diagnostic> diags, int maxWarnings = 20)
{
    int errors = 0, shown = 0;
    foreach (var d in diags.OrderByDescending(d => d.Severity))
    {
        if (d.Severity == Severity.Error) { errors++; Console.Error.WriteLine(d); }
        else if (shown++ < maxWarnings) Console.WriteLine(d);
    }
    int w = diags.Count(d => d.Severity == Severity.Warning);
    if (w > maxWarnings) Console.WriteLine($"... {w - maxWarnings} more warnings");
    return errors;
}

try
{
    switch (cmd)
    {
        case "asm":
            {
                UseCpu();
                var o = new AssemblerOptions { LenientMode = Flag("--compat") };
                foreach (var d in Opts("-D"))
                {
                    var kv = d.Split('=', 2);
                    o.Defines[kv[0]] = kv.Length > 1 ? long.Parse(kv[1]) : 1;
                }
                foreach (var i in Opts("-I")) o.IncludePaths.Add(Path.GetFullPath(i));
                var output = Opt("-o");
                bool lst = Flag("--lst"), map = Flag("--map"), sym = Flag("--sym");
                if (rest.Count != 1) return Usage();
                var sw = Stopwatch.StartNew();
                var r = new OkiAssembler(o).AssembleFile(rest[0]);
                int errs = PrintDiags(r.Diagnostics);
                if (errs > 0) { Console.Error.WriteLine($"{errs} error(s)"); return 1; }
                output ??= Path.ChangeExtension(rest[0], ".bin");
                File.WriteAllBytes(output, r.Image);
                if (lst) File.WriteAllText(Path.ChangeExtension(output, ".lst"), OkiAssembler.WriteListing(r));
                if (map) File.WriteAllText(Path.ChangeExtension(output, ".map"), OkiAssembler.WriteMap(r));
                if (sym) File.WriteAllText(Path.ChangeExtension(output, ".sym"), OkiAssembler.WriteSymbolFile(r));
                Console.WriteLine($"{output}: {r.UsedBytes} of {r.Image.Length} bytes used, {sw.ElapsedMilliseconds} ms");
                return 0;
            }
        case "run":
            {
                UseCpu();
                long steps = long.Parse(Opt("--steps") ?? "2000000");
                var until = Opt("--until");
                int trace = int.Parse(Opt("--trace") ?? "0");
                var rpm = Opt("--rpm");
                var tps = Opt("--tps");
                var mapKpa = Opt("--map");
                var watch = Opt("--watch");
                bool stall = Flag("--stall");
                int syncEvery = int.Parse(Opt("--sync") ?? "1024");
                if (rest.Count != 1) return Usage();
                var sim = new Simulator();
                IReadOnlyDictionary<string, long>? syms = null;
                var path = rest[0];
                if (path.EndsWith(".asm", StringComparison.OrdinalIgnoreCase))
                {
                    var r = new OkiAssembler().AssembleFile(path);
                    if (PrintDiags(r.Diagnostics, 5) > 0) return 1;
                    sim.LoadRom(r.Image);
                    syms = r.Symbols.ToDictionary(k => k.Key, v => v.Value.Value);
                }
                else sim.LoadRom(File.ReadAllBytes(path));
                if (rpm != null) sim.Engine.Rpm = double.Parse(rpm, CultureInfo.InvariantCulture);
                if (tps != null) sim.Engine.TpsPct = double.Parse(tps, CultureInfo.InvariantCulture);
                if (mapKpa != null) sim.Engine.MapKpa = double.Parse(mapKpa, CultureInfo.InvariantCulture);
                sim.StallInterventionEnabled = stall;
                ushort? stopAt = until != null ? ParseAddr(until, syms) : null;
                var watches = (watch ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries).Select(w => ParseAddr(w, syms)).ToList();
                var ring = new Queue<TraceEntry>();
                var sw = Stopwatch.StartNew();
                long ran = 0;
                if (syncEvery > 0) sim.SyncSensors();
                while (ran < steps)
                {
                    if (stopAt is ushort sa && sim.Cpu.Pc == sa && ran > 0) { Console.WriteLine($"reached {until} at instruction {ran:N0}"); break; }
                    var e = sim.StepOne();
                    if (e == null) break;
                    ran++;
                    if (trace > 0) { ring.Enqueue(e.Value); if (ring.Count > trace) ring.Dequeue(); }
                    if (syncEvery > 0 && ran % syncEvery == 0) sim.SyncSensors();
                    if (sim.State == RunState.Faulted) break;
                }
                sw.Stop();
                string Sym(ushort a) => syms?.FirstOrDefault(kv => kv.Value == a && !OkiAssembler.Sfrs.ContainsKey(kv.Key)).Key ?? "";
                foreach (var e in ring) Console.WriteLine($"  {e.Pc:X4} {Sym(e.Pc),-24} {e.Text}");
                var c = sim.Cpu;
                Console.WriteLine($"ran {ran:N0} instructions in {sw.Elapsed.TotalSeconds:F2}s ({ran / Math.Max(sw.Elapsed.TotalSeconds, 1e-9):N0}/s), simulated {(double)c.Cycles / Bus.CpuHz:F3}s");
                Console.WriteLine($"state {sim.State}{(sim.FaultMessage != null ? ": " + sim.FaultMessage : "")}");
                Console.WriteLine($"PC={c.Pc:X4} {Sym(c.Pc)}  A={c.A:X4}  PSW={c.PswU16():X4}  LRB={c.Lrb:X4}  SSP={c.Ssp:X4}  DD={(c.Dd ? 1 : 0)}");
                Console.WriteLine($"injectors " + string.Join(" ", Enumerable.Range(0, 4).Select(n => $"{sim.Bus.InjectorPulseUs[n] / 1000.0:F2}ms x{sim.Bus.InjectorEvents[n]}")) + $"  sparks {sim.Bus.IgnitionEvents}");
                Console.WriteLine($"P0={sim.Bus.ReadPort(0):X2} P1={sim.Bus.ReadPort(1):X2} P2={sim.Bus.ReadPort(2):X2} P3={sim.Bus.ReadPort(3):X2} P4={sim.Bus.ReadPort(4):X2}  fuel pump={(sim.Bus.FuelPumpActive ? "on" : "off")}  inj PW={sim.Bus.InjectorPulseWidthUs}us");
                foreach (var w in watches) Console.WriteLine($"[{w:X4}] = {sim.Bus.Ram[w]:X2} {sim.Bus.Ram[w + 1]:X2}  (word {sim.Bus.Ram[w] | (sim.Bus.Ram[w + 1] << 8)})");
                var hot = sim.GetHottestRecentPc();
                Console.WriteLine($"hottest recent PC {hot.Address:X4} {Sym(hot.Address)} ({hot.Count}/{hot.WindowFilled}); coverage {sim.Coverage.AddressesExecuted} addresses");
                foreach (var t in sim.TrapLog) Console.WriteLine($"BRK at {t.Key.Pc:X4} {Sym(t.Key.Pc)} reason {t.Key.Reason:X2} x{t.Value}");
                return sim.State == RunState.Faulted ? 1 : 0;
            }
        case "disasm":
            {
                UseCpu();
                ushort from = ParseAddr(Opt("--from") ?? "0");
                int count = int.Parse(Opt("--count") ?? "64");
                var symFile = Opt("--sym");
                if (rest.Count != 1) return Usage();
                byte[] img; Dictionary<int, string> labels = [];
                if (rest[0].EndsWith(".asm", StringComparison.OrdinalIgnoreCase))
                {
                    var r = new OkiAssembler().AssembleFile(rest[0]);
                    img = r.Image;
                    foreach (var s in r.Symbols.Values.Where(s => s.Kind == SymbolKind.Label)) labels.TryAdd((int)s.Value, s.Name);
                }
                else img = File.ReadAllBytes(rest[0]);
                if (symFile != null)
                    foreach (var l in File.ReadAllLines(symFile))
                    {
                        var p2 = l.Split(' ', 2);
                        if (p2.Length == 2 && int.TryParse(p2[0], NumberStyles.HexNumber, null, out var a)) labels.TryAdd(a, p2[1]);
                    }
                bool dd = false;
                int pc = from;
                for (int n = 0; n < count && pc < img.Length; n++)
                {
                    int at = pc;
                    var d = Decoder.Decode(dd, i => at + i < img.Length ? img[at + i] : (byte)0xFF);
                    if (labels.TryGetValue(pc, out var lab)) Console.WriteLine($"{lab}:");
                    if (d == null) { Console.WriteLine($"  {pc:X4}  {img[pc]:X2}              DB {img[pc]:X2}h"); pc++; continue; }
                    var hex = string.Concat(img.Skip(pc).Take(d.Len).Select(b => b.ToString("X2")));
                    var text = Decoder.Format(d, (ushort)(pc + d.Len));
                    Console.WriteLine($"  {pc:X4}  {hex,-12}  {text}");
                    if (d.DdAfter is bool v) dd = v;
                    pc += d.Len;
                }
                return 0;
            }
        case "symbols":
        case "defs":
        case "get":
        case "set":
        case "xref":
        case "formulas":
        case "defs-export":
        case "features":
            return CalCommands.Run(cmd, rest);

        default:
            return Usage();
    }
}
catch (Exception ex) when (ex is IOException or InvalidDataException or FormatException or System.Text.Json.JsonException or UnauthorizedAccessException)
{
    Console.Error.WriteLine("error: " + ex.Message);
    return 1;
}
