// --ramfree [DEFINE...]: which RAM bytes (80h-47Fh) a build never touches once it is running. Every stock function and every
// module that fits (or the ones named), every switch on, driven through idle, cruise, full throttle, the rev limit and back,
// with the datalog streaming; a byte read or written after the power-up clear is in use. Lists the untouched runs.
using OkiRomSim.Calibration;
using OkiRomSim.Core;

static class RamUse
{
    public static int Run(Skeleton sk, string[] named)
    {
        var defs = named.Length > 0 ? [.. named] : Biggest(sk);
        var b = sk.Build(defs);
        if (b.Assembly is not { Success: true } asm) { Console.WriteLine(string.Join(" | ", b.Errors)); return 2; }
        var rom = (byte[])asm.Image.Clone();
        foreach (var f in DefinitionBuilder.FromAssembly(asm, "ramuse").Items.Where(i => i.Flag && i.Address >= 0 && i.Address < rom.Length && !i.Name.StartsWith("boardopt", StringComparison.OrdinalIgnoreCase)))
        { int v = (int)f.OnRaw; rom[f.Address] = (byte)v; if (f.ElementSize == 2) rom[f.Address + 1] = (byte)(v >> 8); }
        RomChecksum.Balance(rom, asm.ChecksumAddress ?? 0x7FFF);
        var sim = new Simulator(); sim.LoadRom(rom);
        var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.VbattVolts = 13.8; e.O2Volts = 0.45; e.Rpm = 850; e.MapKpa = 33; sim.SyncSensors();
        var used = new bool[0x480];
        bool on = false;
        sim.Bus.OnDataRead = a => { if (on && a < 0x480) used[a] = true; };
        sim.Bus.OnDataWrite = (a, _, _) => { if (on && a < 0x480) used[a] = true; };
        void Go(double secs) { ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz); while (sim.Cpu.Cycles < end && sim.StepOne() != null) if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
        Go(6);
        on = true;
        if (defs.Contains("FEAT_DLSTREAM"))
            foreach (var x in new byte[] { 0x75, 0x10, 0x0F, 0, 1, 2, 3, 11, 12, 13, 14, 7, 6, 4, 5, 9, 16, 17, 0x69, 0x71 }) { sim.Bus.QueueSerialRx([x], 640); Go(0.002); }
        foreach (var (rpm, map, tps, kmh) in new[] { (850, 33.0, 0.0, 0.0), (3000, 60.0, 20.0, 90.0), (6500, 100.0, 100.0, 120.0), (8200, 100.0, 100.0, 140.0), (2000, 30.0, 0.0, 60.0), (0, 101.0, 0.0, 0.0), (250, 90.0, 0.0, 0.0), (900, 35.0, 0.0, 0.0) })
        { e.Rpm = rpm; e.MapKpa = map; e.TpsPct = tps; e.SpeedKmh = kmh; e.Cranking = rpm is > 0 and < 400; sim.SyncSensors(); Go(2.5); sim.Bus.TakeSerialTx(); }
        Console.WriteLine($"{defs.Count} functions; bytes 80h-47Fh never read or written after power-up (runs of 4 or more; single bytes below 100h):");
        int total = 0;
        for (int a = 0x80; a < 0x480;)
        {
            if (used[a]) { a++; continue; }
            int s = a; while (a < 0x480 && !used[a]) a++;
            if (a - s >= (s < 0x100 ? 1 : 4)) { Console.WriteLine($"  {s:X3}h-{a - 1:X3}h  {a - s} bytes"); total += a - s; }
        }
        Console.WriteLine($"{total} bytes in those runs; lowest SSP seen is the stack's reach (it grows down from 47Fh)");
        return 0;
    }

    static List<string> Biggest(Skeleton sk)
    {
        var pick = new List<string>();
        foreach (var f in sk.Features.Where(f => f.Stock && f.Define != "FEAT_STOCK_SERIAL")) if (sk.Problems([.. pick, f.Define]).Count == 0) pick.Add(f.Define);
        foreach (var f in sk.Features.Where(f => !f.Stock && f.Define is not "FEAT_DLQD3"))
            if (sk.Problems([.. pick, f.Define]).Count == 0 && sk.Build([.. pick, f.Define]).Success) pick.Add(f.Define);
        return pick;
    }
}
