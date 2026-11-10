using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

/// --simdl file.asm...: boot each ROM in the simulator and datalog it through its serial port, as the app's simulator link does.
static class SimDl
{
    public static int Run(string[] files)
    {
        int bad = 0;
        foreach (var f in files)
        {
            var a = new OkiAssembler().AssembleFile(f);
            var rom = a.Image;
            var r = DatalogLayout.Detect(rom, s => Console.WriteLine("   " + s));
            Console.WriteLine($"{Path.GetFileName(f)}: known {r.Known?.Name ?? "-"}, detected {r.Protocol?.Name ?? "-"}");
            Console.WriteLine(r.Report);
            if (r.Known == null && r.Protocol == null) bad++;
        }
        return bad;
    }
}

/// --hdltest: a logger file written field by field in the order the HTS logger writes them, read back: every channel where it belongs.
static class HdlTest
{
    public static int Run()
    {
        var path = Path.Combine(Path.GetTempPath(), "okirom-hdltest.hdl");
        using (var w = new BinaryWriter(File.Create(path)))
        {
            w.Write("DATALOGGER"u8.ToArray()); w.Write((ushort)6); w.Write((byte)128); w.Write(0);
            for (int k = 0; k < 3; k++)
            {
                w.Write(new byte[] { 0x50, 0x90, 0x60, 0xC8, 0x99, 0xE5 });        // ect iat o2 baro map tps
                w.Write((ushort)(1875000 / 6000));                                  // rpm 6000
                w.Write(new byte[] { 0x09, 7, 8, 11, 0, 0, 0, 0, 120 });            // status (vtec + post fuel), rows 7/8, col 11, dtc, vss 120
                w.Write((ushort)3000);                                              // inj
                w.Write((byte)(24 + 4 * 30)); w.Write((byte)(24 + 4 * 32));         // ign final 30, table 32
                w.Write((byte)0x06); w.Write((byte)0x81); w.Write((byte)0x80); w.Write((byte)0x40); // inputs brake+ac, outputs pump+ac clutch, vtec out, eld
                w.Write((byte)150);                                                 // batt
                w.Write((long)(1000 + k * 50)); w.Write(50L);                       // duration, interval
                w.Write((byte)0x90);                                                // ect fuel +12.5 %
                w.Write((ushort)0x8800); w.Write((ushort)0x7800); w.Write((ushort)0x8000); // o2 short +6.25, long -6.25, iat 0
                w.Write(new byte[] { 0x80, 0x7C, 0x84, 0x80, 0x80, 0x04, 0x10 });   // ve, iat ign -1, ect ign +1, gear ign, gear fuel, inputs (ebc), active (ebc)
                w.Write(new byte[] { 80, 100, 0xB0 });                              // ebc base 40 %, duty 50 %, target
                w.Write(new byte[] { 51, 102, 0, 0, 0 });                           // emulator inputs 1 V, 2 V
                w.Write((byte)0x80); w.Write((byte)51); w.Write((byte)102);         // lean protect active, egr 1 V, b6 2 V
                w.Write(new byte[] { 0, 0, 0 }); w.Write((ushort)0x9000);           // spare, iacv +12.5 %
                w.Write((byte)128);                                                 // wideband byte
                w.Write((ushort)0); w.Write((ushort)0);
                w.Write(false); w.Write(false); w.Write(false);
                w.Write(true); w.Write(812.5f);                                     // egt1
                for (int i = 0; i < 7; i++) { w.Write(false); w.Write(0f); }
                w.Write(0f); w.Write(0f); w.Write((byte)0);
            }
        }
        var frames = LogFile.Load(path);
        var f = frames[0];
        var want = new Dictionary<string, double>
        {
            ["rpm"] = 6010, ["speed_kmh"] = 120, ["vtec"] = 1, ["post_start_fuel"] = 1, ["fuel_row_lo"] = 7, ["fuel_row_hi"] = 8, ["fuel_col"] = 11,
            ["brake"] = 1, ["ac"] = 1, ["fuel_pump"] = 1, ["ac_clutch"] = 1, ["vtec_out"] = 1, ["ect_fuel_pct"] = 12.5, ["o2_short_pct"] = 6.3,
            ["o2_long_pct"] = -6.3, ["iat_ign_deg"] = -1, ["ect_ign_deg"] = 1, ["ebc_input"] = 1, ["ebc_active"] = 1, ["ebc_base_duty_pct"] = 40,
            ["ebc_duty_pct"] = 50, ["lean_protect_active"] = 1, ["egr_v"] = 1, ["b6_v"] = 2, ["iacv_duty_pct"] = 12.5, ["emu_aux1_v"] = 1, ["egt1"] = 812.5,
        };
        int bad = 0;
        foreach (var (k, v) in want)
            if (f.Get(k) is not double got || Math.Abs(got - v) > 0.11) { bad++; Console.WriteLine($"  {k}: {f.Get(k)?.ToString() ?? "missing"}, wanted {v}"); }
        Console.WriteLine($"{frames.Count} frames, {f.Channels().Count()} channels; {(bad == 0 ? "PASS" : bad + " wrong")}");
        return bad;
    }
}

/// --faultdisable file.asm: run the ROM, list the faults it latches, hard-disable each, run again: the bit stays clear and the engine still runs.
static class FaultDisableTest
{
    public static int Run(string path, Skeleton sk)
    {
        var a = path == "skeleton" ? sk.Build(SkeletonPresets.Default).Assembly! : new OkiAssembler().AssembleFile(path);
        var map = a.SourceMap.Select(e => (e.Address, e.Length, e.File, e.Line)).ToList();
        (List<int> Bits, double Inj) Go(byte[] rom)
        {
            var sim = new Simulator { FastForwardDelayLoops = true };
            sim.LoadRom(rom);
            sim.Engine.Rpm = 2500; sim.Engine.MapKpa = 50; sim.Engine.TpsPct = 10; sim.Engine.EctCelsius = 85; sim.Engine.IatCelsius = 25;
            sim.Engine.O2Volts = 0.45; sim.Engine.VbattVolts = 14.2; sim.Engine.SpeedKmh = 50;
            sim.SyncSensors();
            var bits = new HashSet<int>();
            int fb = MilMonitor.FaultFieldBase(rom);
            ulong end = sim.Cpu.Cycles + (ulong)(8 * Bus.CpuHz);
            ulong inj0 = 0;
            while (sim.Cpu.Cycles < end && sim.StepOne() != null)
            {
                if ((sim.Cpu.Instructions & 1023) == 0)
                {
                    sim.SyncSensors();
                    for (int b = 0; b < 48; b++) if ((sim.Bus.Ram[fb + b / 8] >> (b % 8) & 1) != 0 && MilMonitor.FaultBitCode(b) != null) bits.Add(b);
                }
            }
            return ([.. bits.Order()], sim.Cpu.Cycles);
        }
        var (bits, _) = Go(a.Image);
        int fb = MilMonitor.FaultFieldBase(a.Image);
        Console.WriteLine($"{Path.GetFileName(path)}: fault field {fb:X2}h, bits seen: {string.Join(", ", bits.Select(b => $"{b} (code {MilMonitor.FaultBitCode(b)})"))}");
        int bad = 0;
        foreach (var b in bits)
        {
            int code = MilMonitor.FaultBitCode(b)!.Value;
            var sites = FaultDisable.BitsFor(code).SelectMany(x => FaultDisable.Find(a.Image, fb, x, map)).DistinctBy(s => s.Address).ToList();
            var rom = (byte[])a.Image.Clone();
            foreach (var p in FaultDisable.Patches(sites)) rom[p.Address] = p.Value;
            var (after, _) = Go(rom);
            bool gone = !after.Any(x => MilMonitor.FaultBitCode(x) == code);
            Console.WriteLine($"  code {code}: {sites.Count} site(s) {string.Join(", ", sites.Select(s => $"{s.Address:X4}h {s.What} line {s.Line}"))} -> after: {(gone ? "never set" : "STILL SET")}; other bits {string.Join(",", after)}");
            if (!gone || sites.Count == 0) bad++;
        }
        return bad;
    }
}
