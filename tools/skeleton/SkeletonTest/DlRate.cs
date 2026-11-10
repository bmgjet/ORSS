// --dlrate [DEFINE...]: how fast the channel stream really goes, and what it costs the engine code, at each baud reload the
// datalog can be set to. A 75h list of 15 channel bytes (DLRATE_N to change it) streamed (71h) at idle, cruise and two
// high rpms: bytes a second on the line, the serial interrupts' own time a byte (mean and worst), their share of the CPU,
// and the main loop's passes a second against the same ROM not streaming. DLRATE_RELOADS (hex, comma) picks the
// reloads; ALLON=1 switches every function on (the heaviest tick).
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

static class DlRate
{
    public static int Run(Skeleton sk, string[] extra)
    {
        var defs = Environment.GetEnvironmentVariable("DLRATE_PLAIN") == "1" ? [.. extra] : SkeletonPresets.Fit(sk, [.. SkeletonPresets.Default, .. extra]);   // DLRATE_PLAIN=1: only the functions named
        var b = sk.Build(defs);
        if (b.Assembly is not { Success: true } asm) { Console.WriteLine(string.Join(" | ", b.Errors)); return 2; }
        var rom = (byte[])asm.Image.Clone();
        if (Environment.GetEnvironmentVariable("ALLON") == "1")
            foreach (var f in DefinitionBuilder.FromAssembly(asm, "dlrate").Items.Where(i => i.Flag && i.Address >= 0 && i.Address < rom.Length && !i.Name.StartsWith("boardopt", StringComparison.OrdinalIgnoreCase)))
            { int v = (int)f.OnRaw; rom[f.Address] = (byte)v; if (f.ElementSize == 2) rom[f.Address + 1] = (byte)(v >> 8); }
        RomChecksum.Balance(rom, asm.ChecksumAddress ?? 0x7FFF);
        int Sym(string n) => asm.Symbols.TryGetValue(n, out var s) ? (int)s.Value : asm.Symbols.Values.FirstOrDefault(x => x.Name.Equals(n, StringComparison.OrdinalIgnoreCase))?.Value is long v ? (int)v : -1;
        var labels = asm.Symbols.Values.Where(x => x.Kind == SymbolKind.Label && x.Value < 0x8000).OrderBy(x => x.Value).ToArray();
        _near = a => labels.LastOrDefault(x => x.Value <= a)?.Name ?? "?";
        Console.WriteLine($"dl_init {Sym("dl_init"):X4} tx {Sym("mod_serial_tx"):X4} main {Sym("hook_main"):X4}");
        _dlinit = Sym("dl_init");
        int tx = Sym("mod_serial_tx"), rx = Sym("mod_serial_rx"), main = Sym("hook_ign");   // the spark calculation (main loop)
        _pass = Sym("hook_main");                                                                               // the main loop's whole pass
        var reloads = (Environment.GetEnvironmentVariable("DLRATE_RELOADS") ?? "f8,fb,fc,fd").Split(',').Select(s => Convert.ToInt32(s.Trim(), 16)).ToArray();
        if (Environment.GetEnvironmentVariable("DLRATE_PROFILE") == "1") _prof = [];
        int nch = int.TryParse(Environment.GetEnvironmentVariable("DLRATE_N"), out var nn) ? Math.Clamp(nn, 1, 15) : 15;
        byte[] chans = [.. new byte[] { 0, 1, 2, 3, 11, 12, 13, 14, 7, 6, 4, 5, 9, 16, 17 }.Take(nch)];
        Console.WriteLine($"{defs.Count} functions{(Environment.GetEnvironmentVariable("ALLON") == "1" ? ", all on" : "")}; {nch} channel bytes a frame ({nch + 4} on the line)");
        Console.WriteLine($"{"reload",6} {"baud",7} {"rpm",5} {"line B/s",9} {"got B/s",8} {"isr us/B",8} {"worst",6} {"cpu %",6} {"free %",7} {"quiet %",7} {"spark/s",7} {"quiet",6} {"pass/s",6} {"quiet",6} {"gap ms",7} {"quiet",6}");
        int bad = 0;
        double sumSpark = 0, sumGap = 0; int nPts = 0;
        foreach (int reload in reloads)
        {
            int baud = (int)(Bus.CpuHz / 8 / (ulong)(256 - reload));
            var points = Environment.GetEnvironmentVariable("DLRATE_RPMS") is { Length: > 0 } rl
                ? rl.Split(',').Select(x => int.Parse(x.Trim())).Select(r => (r, r < 1000 ? 33.0 : r < 4000 ? 60.0 : 100.0, r < 1000 ? 0.0 : r < 4000 ? 20.0 : 100.0)).ToArray()
                : new[] { (850, 33.0, 0.0), (3000, 60.0, 20.0), (4500, 80.0, 50.0), (6000, 100.0, 100.0), (6500, 100.0, 100.0), (8000, 100.0, 100.0) };
            foreach (var (rpm, map, tps) in points)
            {
                var quiet = Measure(rom, reload, baud, rpm, map, tps, null, tx, rx, main);
                var r = Measure(rom, reload, baud, rpm, map, tps, chans, tx, rx, main);
                double line = baud / 10.0;
                Console.WriteLine($"{reload,6:X2} {baud,7} {rpm,5} {line,9:0} {r.BytesPerS,8:0} {r.IsrUsPerByte,8:0.0} {r.WorstUs,6:0} {r.CpuPct,6:0.0} {r.FreePct,7:0.0} {quiet.FreePct,7:0.0} {r.MainPerS,7:0} {quiet.MainPerS,6:0} {r.PassPerS,6:0} {quiet.PassPerS,6:0} {r.MaxGapMs,7:0.0} {quiet.MaxGapMs,6:0.0}{(r.Faulted ? "  FAULT" : "")}");
                if (r.Faulted || r.BytesPerS < 1) bad++;
                if (rpm > 0 && quiet.MainPerS > 0) { sumSpark += r.MainPerS / quiet.MainPerS; sumGap += r.MaxGapMs / Math.Max(1, quiet.MaxGapMs); nPts++; }
                if (_gaps != null) { Console.WriteLine("      gaps over 32 ms (streaming): " + string.Join(", ", _gaps)); _gaps = null; }
                if (_prof != null) { foreach (var (k, c) in _prof.OrderByDescending(x => x.Value).Take(25)) Console.WriteLine($"      {k,-28} {c / (Bus.CpuHz / 1e6) / Math.Max(1, r.BytesPerS * 2),6:0.0} us/B"); _prof.Clear(); }
            }
        }
        if (nPts > 0) Console.WriteLine($"average over the running points: spark calculations {sumSpark / nPts * 100:0.0} % of no logging, longest gap {sumGap / nPts * 100:0.0} %");
        return bad;
    }

    static Func<int, string>? _near;
    static int _dlinit, _dlinitHits;
    static Dictionary<string, ulong>? _prof;
    static ulong _free;
    static int _pass; static long _passes;
    static ulong _lastIgn, _maxGap, _t0;
    static List<string>? _gaps;
    sealed record Result(double BytesPerS, double IsrUsPerByte, double WorstUs, double CpuPct, double MainPerS, double FreePct, bool Faulted) { public double PassPerS, MaxGapMs; }

    static Result Measure(byte[] rom, int reload, int baud, int rpm, double map, double tps, byte[]? chans, int tx, int rx, int main)
    {
        _free = 0; _passes = 0; _lastIgn = 0; _maxGap = 0;
        var sim = new Simulator(); sim.LoadRom(rom);
        var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.VbattVolts = 13.8; e.O2Volts = 0.45;
        e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0; sim.SyncSensors();
        uint hostByte = (uint)(Bus.CpuHz * 10 / (ulong)baud);
        var stack = new List<int>();
        ulong isrCycles = 0, worst = 0, cur = 0; long bytes = 0, mains = 0; bool counting = false;
        void Go(double secs)
        {
            ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz);
            while (sim.Cpu.Cycles < end)
            {
                ushort pc = sim.Cpu.Pc; ulong c0 = sim.Cpu.Cycles;
                var st = sim.StepOne();
                if (st == null) return;
                ulong d = sim.Cpu.Cycles - c0;
                bool serialTop = stack.Count > 0 && (stack[^1] == tx || stack[^1] == rx);
                if (serialTop) { cur += d; if (counting && _prof != null) { var k = _near!(pc); _prof[k] = _prof.GetValueOrDefault(k) + d; } }
                if (counting && stack.Count == 0) _free += d;
                if (counting && pc == main) { mains++; if (_lastIgn != 0) { ulong g = sim.Cpu.Cycles - _lastIgn; _maxGap = Math.Max(_maxGap, g); if (_gaps != null && g > Bus.CpuHz / 1000 * (ulong)(int.TryParse(Environment.GetEnvironmentVariable("DLRATE_GAPMS"), out var gm) ? gm : 32)) _gaps.Add($"{g / (Bus.CpuHz / 1000.0):0.0} ms at {(sim.Cpu.Cycles - _t0) / (double)Bus.CpuHz:0.000} s"); } _lastIgn = sim.Cpu.Cycles; }
                if (counting && pc == _pass) _passes++;
                if (pc == _dlinit) _dlinitHits++;
                if (st.Value.Decoded is { } dd && dd.Mnemonic.StartsWith("RTI", StringComparison.Ordinal) && stack.Count > 0)
                {
                    if (serialTop) { if (counting) { isrCycles += cur; worst = Math.Max(worst, cur); } cur = 0; }
                    stack.RemoveAt(stack.Count - 1);
                }
                if (sim.LastStepInterrupted) stack.Add(sim.Cpu.Pc);
                if ((sim.Cpu.Instructions & 1023) == 0) { sim.SyncSensors(); if (counting) bytes += sim.Bus.TakeSerialTx().Length; }   // (the queue keeps 8 KB)
            }
        }
        Go(6);                                                        // boot (about 5 s) and settle at idle
        if (Environment.GetEnvironmentVariable("DLRATE_DEBUG") == "1") Console.WriteLine($"  after boot: {sim.Cpu.Cycles / (double)Bus.CpuHz:0.00} s, {sim.State}, pc {sim.Cpu.Pc:X4} {_near?.Invoke(sim.Cpu.Pc)}, dl_init ran {_dlinitHits}, STTMC {sim.Bus.Ram[0x4A]:X2} IE {sim.Bus.Ram[0x1A]:X2}{sim.Bus.Ram[0x1B]:X2}");
        sim.Bus.Ram[0x48] = (byte)reload; sim.Bus.Ram[0x49] = (byte)reload;   // the datalog's baud
        e.Rpm = rpm; e.MapKpa = map; e.TpsPct = tps; e.SpeedKmh = rpm > 1000 ? 80 : 0; sim.SyncSensors();
        if (chans != null)
        {
            var list = new List<byte> { (byte)(chans.Length + 1), (byte)chans.Length };
            list.AddRange(chans);
            list.Add((byte)(-list.Sum(x => x) & 0xFF));
            sim.Bus.TakeSerialTx();
            foreach (var x in (byte[])[0x75, .. list]) { sim.Bus.QueueSerialRx([x], hostByte); Go(0.001); }   // a byte at a time, as the app sends it
            Go(0.05);
            var ans = sim.Bus.TakeSerialTx();
            if (Environment.GetEnvironmentVariable("DLRATE_DEBUG") == "1") Console.WriteLine($"  75h list {Convert.ToHexString([0x75, .. list])} -> {Convert.ToHexString(ans)}");
            sim.Bus.QueueSerialRx([0x71], hostByte);
        }
        Go(1.0);
        sim.Bus.TakeSerialTx();
        counting = true; _t0 = sim.Cpu.Cycles; if (Environment.GetEnvironmentVariable("DLRATE_GAPS") == "1") _gaps = [];
        const double secs = 2.0;
        Go(secs);
        bytes += sim.Bus.TakeSerialTx().Length;
        double us = Bus.CpuHz / 1e6;
        return new Result(bytes / secs, bytes == 0 ? 0 : isrCycles / us / bytes, worst / us, isrCycles * 100.0 / (secs * Bus.CpuHz), mains / secs, _free * 100.0 / (secs * Bus.CpuHz), sim.State == RunState.Faulted) { PassPerS = _passes / secs, MaxGapMs = _maxGap / (Bus.CpuHz / 1000.0) };
    }
}
