// --tickprofile DEFINE...: where the module tick's time goes, every module switched on: the time spent inside the timer 1
// interrupt (not counting the handlers that interrupt it), by source file and by label, per tick and on its worst slot.
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

static class TickProfile
{
    public static int Run(Skeleton sk, string[] defs)
    {
        var b = sk.Build(defs);
        if (b.Assembly is not { Success: true } asm) { Console.WriteLine(string.Join(" | ", b.Errors)); return 2; }
        var rom = (byte[])asm.Image.Clone();
        foreach (var f in DefinitionBuilder.FromAssembly(asm, "tick").Items.Where(i => i.Flag && i.Address >= 0 && i.Address < rom.Length))
        { int v = (int)f.OnRaw; rom[f.Address] = (byte)v; if (f.ElementSize == 2) rom[f.Address + 1] = (byte)(v >> 8); }
        RomChecksum.Balance(rom, asm.ChecksumAddress ?? 0x7FFF);
        var sim = new Simulator(); sim.LoadRom(rom);
        var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 850; e.MapKpa = 33; e.VbattVolts = 13.8; sim.SyncSensors();
        int t1 = (int)asm.Symbols["int_timer_1"].Value;
        // the nearest label at or before an address
        var labels = asm.Symbols.Values.Where(x => x.Kind == SymbolKind.Label && x.Value < 0x8000).OrderBy(x => x.Value).ToArray();
        var keys = labels.Select(x => (int)x.Value).ToArray();
        string Near(int a) { int i = Array.BinarySearch(keys, a); if (i < 0) i = ~i - 1; return i < 0 ? $"{a:X4}" : labels[i].Name; }
        var stack = new List<int>();             // entry addresses of the handlers in progress
        var byFile = new Dictionary<string, ulong>();
        var byLabel = new Dictionary<string, ulong>();
        var perSlot = new ulong[16]; var ticksPerSlot = new long[16];
        bool on = false; long ticks = 0;
        void Go(double secs)
        {
            ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz);
            while (sim.Cpu.Cycles < end && sim.State != RunState.Faulted)
            {
                ushort pc = sim.Cpu.Pc;
                ulong c0 = sim.Cpu.Cycles;
                var st = sim.StepOne();
                if (st == null) break;
                ulong d = sim.Cpu.Cycles - c0;
                if (on && stack.Count > 0 && stack[^1] == t1)
                {
                    var le = asm.Lookup(pc);
                    string file = le == null ? "?" : Path.GetFileNameWithoutExtension(le.File);
                    byFile[file] = byFile.GetValueOrDefault(file) + d;
                    string lab = Near(pc);
                    byLabel[$"{file}: {lab}"] = byLabel.GetValueOrDefault($"{file}: {lab}") + d;
                    perSlot[sim.Bus.Ram[0xFE] & 15] += d;
                }
                if (st.Value.Decoded is { } dd && dd.Mnemonic.StartsWith("RTI", StringComparison.Ordinal) && stack.Count > 0)
                {
                    if (on && stack[^1] == t1) { ticksPerSlot[sim.Bus.Ram[0xFE] & 15]++; ticks++; }
                    stack.RemoveAt(stack.Count - 1);
                }
                if (sim.LastStepInterrupted) stack.Add(sim.Cpu.Pc);
                if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
            }
        }
        Go(5); on = true;
        foreach (var (rpm, map, tps) in new[] { (850, 33.0, 0.0), (3000, 60.0, 20.0), (6000, 100.0, 100.0) })
        { e.Rpm = rpm; e.MapKpa = map; e.TpsPct = tps; sim.SyncSensors(); Go(1.5); }
        double us = Bus.CpuHz / 1e6;
        Console.WriteLine($"{ticks} timer 1 interrupts (ticks and idle valve phases)");
        Console.WriteLine("by file, us per interrupt on average:");
        foreach (var (n, c) in byFile.OrderByDescending(x => x.Value)) Console.WriteLine($"  {n,-20} {c / us / ticks,7:0.0}");
        Console.WriteLine("by slot (0FEh & 15), us per interrupt on average:");
        for (int s = 0; s < 16; s++) Console.WriteLine($"  slot {s,2}: {(ticksPerSlot[s] == 0 ? 0 : perSlot[s] / us / ticksPerSlot[s]),7:0.0}");
        Console.WriteLine("by label, top 30 (us per interrupt on average):");
        foreach (var (n, c) in byLabel.OrderByDescending(x => x.Value).Take(int.TryParse(Environment.GetEnvironmentVariable("TOPN"), out var tn) ? tn : 30)) Console.WriteLine($"  {n,-48} {c / us / ticks,7:0.00}");
        return 0;
    }
}
