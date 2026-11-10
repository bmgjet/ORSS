// RomEquiv: run two builds of a ROM through the same simulated drives and compare what they do.
//
//   RomEquiv <a.asm|bin> <b.asm|bin> [--exact] [--steps N] [--only name] [--coverage out.txt]
//
// --exact  the builds must make the same RAM writes in the same order (outside the system stack,
//          which holds return addresses). Right for a build that only moved code: same instructions,
//          same timing, so anything different is a reference that did not follow the move.
// default  functional: the builds may differ in timing (shorter jumps, new features switched off),
//          so compare what they end up doing at each checkpoint - fuel, spark, VTEC, pump, limiter
//          state, the sensor values the ROM worked out, and the datalog bytes.
using OkiRomSim.Assembler;
using OkiRomSim.Core;

var paths = args.Where((a, i) => !a.StartsWith("--") && (i == 0 || args[i - 1] is not ("--steps" or "--only" or "--coverage" or "--deltas" or "--ignore"))).ToList();
bool exact = args.Contains("--exact");
var ignore = (args.SkipWhile(a => a != "--ignore").Skip(1).FirstOrDefault() ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries).ToList();
long steps = args.SkipWhile(a => a != "--steps").Skip(1).Select(long.Parse).FirstOrDefault(6_000_000);
string? only = args.SkipWhile(a => a != "--only").Skip(1).FirstOrDefault();
string? covOut = args.SkipWhile(a => a != "--coverage").Skip(1).FirstOrDefault();
// relocation offsets of the second build: a write that differs by one of these (low byte) or by a
// carry of 1 (high byte) is a pointer that moved with the code, not a difference in behaviour
var deltas = (args.SkipWhile(a => a != "--deltas").Skip(1).FirstOrDefault() ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries).Select(int.Parse).ToList();
bool Moved(byte a, byte b) => deltas.Count > 0 && (deltas.Any(d => (byte)(a + d) == b) || Math.Abs(a - b) == 1);
if (paths.Count != 2) { Console.WriteLine("RomEquiv a b [--exact] [--steps N] [--only scenario] [--coverage file]"); return 2; }

(byte[] Rom, Dictionary<int, string> Names) Load(string p)
{
    if (!p.EndsWith(".asm", StringComparison.OrdinalIgnoreCase)) return (File.ReadAllBytes(p), []);
    (ProcessorProfile.Declared(File.ReadAllText(p)) ?? ProcessorProfile.Msm66207()).Apply();
    var r = new OkiAssembler().AssembleFile(p);
    if (!r.Success) throw new Exception(string.Join("\n", r.Diagnostics.Take(5)));
    return (r.Image, r.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).GroupBy(s => (int)s.Value).ToDictionary(g => g.Key, g => g.First().Name));
}
var A = Load(paths[0]); var B = Load(paths[1]);

// a scenario is a list of phases: how long, what the engine is doing, and serial bytes to send
var scenarios = new List<(string Name, (double Seconds, Action<EngineState> Set, byte[]? Serial)[] Phases)>
{
    ("cold-crank-idle", new (double, Action<EngineState>, byte[]?)[] {
        (1.0, e => { e.EctCelsius = 15; e.IatCelsius = 15; e.Rpm = 0; e.TpsPct = 0; e.MapKpa = 100; }, null),
        (1.5, e => { e.Cranking = true; e.Rpm = 250; e.MapKpa = 90; }, null),
        (4.0, e => { e.Cranking = false; e.Rpm = 1400; e.MapKpa = 38; }, null),
        (4.0, e => { e.Rpm = 900; e.MapKpa = 34; }, null) }),
    ("warm-idle", new (double, Action<EngineState>, byte[]?)[] {
        (6.0, e => { e.Rpm = 800; e.MapKpa = 33; e.TpsPct = 0; }, null),
        (4.0, e => { e.Rpm = 760; e.MapKpa = 36; }, null) }),
    ("cruise", new (double, Action<EngineState>, byte[]?)[] {
        (5.0, e => { e.Rpm = 2200; e.MapKpa = 45; e.TpsPct = 10; e.SpeedKmh = 60; }, null),
        (5.0, e => { e.Rpm = 3000; e.MapKpa = 55; e.TpsPct = 15; e.SpeedKmh = 90; e.O2Volts = 0.8; }, null),
        (3.0, e => { e.O2Volts = 0.1; }, null) }),
    ("wot-vtec", new (double, Action<EngineState>, byte[]?)[] {
        (4.0, e => { e.Rpm = 3500; e.MapKpa = 98; e.TpsPct = 100; e.SpeedKmh = 70; }, null),
        (4.0, e => { e.Rpm = 6200; e.SpeedKmh = 110; }, null),
        (3.0, e => { e.Rpm = 7600; e.SpeedKmh = 130; }, null) }),
    ("overrev", new (double, Action<EngineState>, byte[]?)[] {
        (5.0, e => { e.Rpm = 8600; e.MapKpa = 98; e.TpsPct = 100; e.SpeedKmh = 140; }, null) }),
    ("overrun-cut", new (double, Action<EngineState>, byte[]?)[] {
        (4.0, e => { e.Rpm = 4500; e.MapKpa = 60; e.TpsPct = 20; e.SpeedKmh = 100; }, null),
        (5.0, e => { e.Rpm = 4000; e.MapKpa = 22; e.TpsPct = 0; e.SpeedKmh = 95; }, null),
        (3.0, e => { e.Rpm = 1100; e.MapKpa = 30; e.SpeedKmh = 20; }, null) }),
    ("speed-ramp", new (double, Action<EngineState>, byte[]?)[] {
        (3.0, e => { e.Rpm = 5000; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = 150; }, null),
        (3.0, e => { e.SpeedKmh = 190; }, null),
        (3.0, e => { e.SpeedKmh = 230; e.Rpm = 6500; }, null) }),
    ("sensor-faults", new (double, Action<EngineState>, byte[]?)[] {
        (4.0, e => { e.Rpm = 2000; e.MapKpa = 45; e.TpsPct = 8; }, null),
        (4.0, e => { e.AnalogOverrides[202] = 4.95; e.AnalogOverrides[102] = 0.05; }, null),
        (4.0, e => { e.AnalogOverrides[7] = 0.0; e.AnalogOverrides[6] = 5.0; }, null) }),
    ("datalog", DatalogPhases()),
};

const int StackLo = 0x0440;
var cover = new HashSet<ushort>();
int failures = 0;
foreach (var (name, phases) in scenarios)
{
    if (only != null && name != only) continue;
    var ra = Run(A.Rom, phases, true); var rb = Run(B.Rom, phases, false);
    string verdict;
    if (exact)
    {
        // --ignore name,name: the writes of routines whose running values depend on where the bytes are (a ROM sum walks
        // the image: once code moves, its partial sums differ though the total is the same) - by label, as the two builds
        // put them at different addresses
        if (ignore.Count > 0)
        {
            bool Keep((ushort Addr, byte Val, ushort Pc) w, Dictionary<int, string> nm) => !ignore.Any(p => Near(nm, w.Pc).StartsWith(p, StringComparison.Ordinal));
            ra = ra with { Writes = [.. ra.Writes.Where(w => Keep(w, A.Names))] };
            rb = rb with { Writes = [.. rb.Writes.Where(w => Keep(w, B.Names))] };
        }
        int n = Math.Min(ra.Writes.Count, rb.Writes.Count), i = 0;
        while (i < n && ra.Writes[i].Addr == rb.Writes[i].Addr && (ra.Writes[i].Val == rb.Writes[i].Val || Moved(ra.Writes[i].Val, rb.Writes[i].Val))) i++;
        bool same = i == n && ra.Writes.Count == rb.Writes.Count && ra.Serial.SequenceEqual(rb.Serial);
        if (same) verdict = $"identical ({n} RAM writes, {ra.Serial.Length} serial bytes)";
        else
        {
            failures++;
            string W(List<(ushort Addr, byte Val, ushort Pc)> w, int k, Dictionary<int, string> nm) =>
                k < w.Count ? $"[{w[k].Addr:X3}]={w[k].Val:X2} at {w[k].Pc:X4} {Near(nm, w[k].Pc)}" : "(ended)";
            verdict = i < n || ra.Writes.Count != rb.Writes.Count
                ? $"DIFFER at write #{i}: A {W(ra.Writes, i, A.Names)} | B {W(rb.Writes, i, B.Names)}"
                : $"DIFFER in serial output ({ra.Serial.Length} vs {rb.Serial.Length} bytes)";
        }
    }
    else
    {
        var diffs = new List<string>();
        for (int k = 0; k < ra.Checkpoints.Count && k < rb.Checkpoints.Count; k++)
            foreach (var (key, va) in ra.Checkpoints[k])
                if (rb.Checkpoints[k].TryGetValue(key, out var vb) && !Close(key, va, vb))
                    diffs.Add($"phase {k + 1} {key}: {va:0.##} vs {vb:0.##}");
        if (!ra.Serial.SequenceEqual(rb.Serial)) diffs.Add($"serial output differs ({ra.Serial.Length} vs {rb.Serial.Length} bytes)");
        if (ra.Traps != rb.Traps) diffs.Add($"traps {ra.Traps} vs {rb.Traps}");
        if (diffs.Count > 0) failures++;
        verdict = diffs.Count == 0 ? "same behaviour" : "DIFFER: " + string.Join("; ", diffs.Take(8));
    }
    Console.WriteLine($"{name,-16} {verdict}");
}
if (covOut != null) File.WriteAllLines(covOut, cover.OrderBy(x => x).Select(x => x.ToString("X4")));
Console.WriteLine(failures == 0 ? "ALL SAME" : $"{failures} scenario(s) differ");
return failures == 0 ? 0 : 1;

static (double, Action<EngineState>, byte[]?)[] DatalogPhases()
{
    var l = new List<(double, Action<EngineState>, byte[]?)>
    {
        (5.0, e => { e.Rpm = 2500; e.MapKpa = 50; e.TpsPct = 12; e.SpeedKmh = 50; }, null),
        (0.4, e => { }, new byte[] { 0x10 }), (0.6, e => { }, new byte[] { 0x20 }),
        // no bare 90h/ABh here: 90h without its address bytes dumps memory at a stale er1 (wherever the
        // last 20h stream stopped), which is a different ROM byte once code moves - host misuse, not ROM behaviour
        (0.4, e => { }, new byte[] { 0x10 }), (0.6, e => { }, new byte[] { 0x20 }),
    };
    foreach (var c in Enumerable.Range(0xC0, 0x40)) l.Add((0.05, e => { }, new[] { (byte)c }));
    return l.ToArray();
}

static string Near(Dictionary<int, string> names, int pc)
{
    for (int a = pc; a >= 0 && a > pc - 0x200; a--) if (names.TryGetValue(a, out var n)) return a == pc ? n : $"{n}+{pc - a:X}";
    return "";
}

// injector pulse widths and spark counts move a little with timing; everything else must match
static bool Close(string key, double a, double b) => key switch
{
    _ when key.StartsWith("inj") => Math.Abs(a - b) <= Math.Max(0.06, Math.Abs(a) * 0.02),
    "sparks/s" or "injections/s" => Math.Abs(a - b) <= Math.Max(3, Math.Abs(a) * 0.05),
    _ => a == b,
};

(List<(ushort Addr, byte Val, ushort Pc)> Writes, byte[] Serial, List<Dictionary<string, double>> Checkpoints, long Traps) Run(
    byte[] rom, (double Seconds, Action<EngineState> Set, byte[]? Serial)[] phases, bool recordCoverage)
{
    var sim = new Simulator(); sim.LoadRom(rom);
    var e = sim.Engine; e.Rpm = 800; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0;
    var writes = new List<(ushort, byte, ushort)>();
    // the pointer registers (X1, X2, DP, USP at 0080h-0087h) hold ROM addresses when code walks a table,
    // and those move with the code; everything computed from what they point at must still match
    sim.Bus.OnDataWrite += (a, o, v) => { if ((a < StackLo || a > 0x47F) && (a < 0x80 || a > 0x87)) writes.Add((a, v, sim.Bus.CurrentPc)); };
    var serial = new List<byte>();
    var cps = new List<Dictionary<string, double>>();
    sim.SyncSensors();
    foreach (var (secs, set, bytes) in phases)
    {
        set(e); sim.SyncSensors();
        if (bytes != null) sim.Bus.QueueSerialRx(bytes, (uint)(Bus.CpuHz * 10 / 38400));
        long inj0 = sim.Bus.InjectorEvents.Sum(), ign0 = sim.Bus.IgnitionEvents;
        ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz);
        while (sim.Cpu.Cycles < end)
        {
            if (recordCoverage) cover.Add(sim.Cpu.Pc);
            if (sim.StepOne() == null) break;
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
        }
        serial.AddRange(sim.Bus.TakeSerialTx());
        var r = sim.Bus.Ram;
        cps.Add(new Dictionary<string, double>
        {
            ["inj_ms"] = sim.Bus.InjectorPulseUs.Max() / 1000.0,
            ["injections/s"] = (sim.Bus.InjectorEvents.Sum() - inj0) / secs,
            ["sparks/s"] = (sim.Bus.IgnitionEvents - ign0) / secs,
            ["fuel_pump"] = sim.Bus.FuelPumpActive ? 1 : 0,
            ["vtec"] = sim.Bus.VtecSolenoidActive ? 1 : 0,
            ["ect_0D9"] = r[0xD9], ["iat_0D8"] = r[0xD8], ["faults_0B0"] = r[0xB0] | (r[0xB1] << 8) | (r[0xB2] << 16),
        });
    }
    return (writes, serial.ToArray(), cps, sim.TrapLog.Values.Sum());
}
