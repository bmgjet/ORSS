// FeatureTest: drives roms/HTS120.asm through the simulator with each HTS120 feature switched on by
// calibration, and checks it does what it says - against the same run with the feature off.
//
//   FeatureTest [path-to-HTS120.asm]
using OkiRomSim.Assembler;
using OkiRomSim.Core;

var path = args.FirstOrDefault(a => !a.StartsWith("--")) ?? Path.Combine(FindRoot(), "roms", "HTS120.asm");
ProcessorProfile.Msm66207().Apply();
var asm = new OkiAssembler().AssembleFile(path);
if (!asm.Success) { Console.WriteLine(string.Join("\n", asm.Diagnostics.Take(5))); return 2; }
int Sym(string n) => (int)asm.Symbols.Values.First(s => s.Name == n).Value;
int failures = 0;
void Check(string what, bool ok, string detail)
{
    Console.WriteLine($"  {(ok ? "PASS" : "FAIL")}  {what,-58} {detail}");
    if (!ok) failures++;
}

// ------------------------------------------------------------------ a run
// cal: calibration bytes to change (symbol + offset -> value). steps: (seconds, engine setup), each
// run in 10 ms slices so a ramp is a ramp; watch is called after every slice.
RunResult Run(Dictionary<(string, int), byte> cal, IEnumerable<(double Secs, Action<EngineState, double> Set)> steps, Action<Simulator>? watch = null, Action<Simulator>? watchBoot = null)
{
    var rom = (byte[])asm.Image.Clone();
    foreach (var ((name, off), v) in cal) rom[Sym(name) + off] = v;
    var sim = new Simulator(); sim.LoadRom(rom);
    var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 800; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0;
    sim.SyncSensors();
    var s = new RunResult(sim);
    // the ROM's power-up wait (the P2/ADC loop at adc_wait_loop) takes about 4 s here: boot under the
    // first step's conditions before anything is measured
    var first = steps.First().Set;
    first(e, 0); sim.SyncSensors();
    for (ulong end = sim.Cpu.Cycles + (ulong)(5 * Bus.CpuHz); sim.Cpu.Cycles < end;)
    {
        if (sim.StepOne() == null) break;
        if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
        watchBoot?.Invoke(sim);
    }
    foreach (var (secs, set) in steps)
    {
        long inj0 = sim.Bus.InjectorEvents.Sum();
        for (double t = 0; t < secs - 1e-9; t += 0.01)
        {
            set(e, t / secs);
            ulong end = sim.Cpu.Cycles + (ulong)(0.01 * Bus.CpuHz);
            while (sim.Cpu.Cycles < end) { if (sim.StepOne() == null) break; if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
            watch?.Invoke(sim);
            s.Ign.Add((sim.Bus.Ram[0x248], sim.Bus.Ram[0xFC]));   // 248h: the timing igntiming_ramp_step settles on
        }
        s.InjPerSec.Add((sim.Bus.InjectorEvents.Sum() - inj0) / secs);
    }
    return s;
}
static (double, Action<EngineState, double>) Hold(double secs, Action<EngineState> set) => (secs, (e, _) => set(e));

// ------------------------------------------------------------------ speed correction
Console.WriteLine("speed correction (SpeedCorrection, 8000h = 100%)");
foreach (var (word, expect) in new[] { (0x8000, 100.0), (0x8CCD, 110.0), (0x7333, 90.0) })
{
    var s = Run(new() { [("SpeedCorrection", 0)] = (byte)word, [("SpeedCorrection", 1)] = (byte)(word >> 8) },
        [Hold(4, e => { e.Rpm = 3000; e.MapKpa = 50; e.TpsPct = 15; e.SpeedKmh = 100; })]);
    int kmh = s.Sim.Bus.Ram[0xCC];
    Check($"{word:X4}h at 100 km/h reads {expect} km/h", Math.Abs(kmh - expect) <= 1.5, $"0CCh = {kmh}");
}

// ------------------------------------------------------------------ traction control
Console.WriteLine("traction control (rpm rise per sample against TcRateByGear)");
{
    // 2nd gear, 40 km/h at 4000 rpm; then the tyres let go: rpm climbs 6000 rpm/s, road speed stays put
    var spin = new List<(double, Action<EngineState, double>)>
    {
        Hold(3, e => { e.Rpm = 4000; e.MapKpa = 95; e.TpsPct = 90; e.SpeedKmh = 40; }),
        (0.5, (e, f) => { e.Rpm = 4000 + 3000 * f; }),
        Hold(0.5, e => { e.Rpm = 7000; }),
        Hold(3.0, e => { e.Rpm = 4000; }),
    };
    // a hard but normal 2nd-gear pull: rpm and speed together, 1500 rpm/s
    var pull = new List<(double, Action<EngineState, double>)>
    {
        Hold(3, e => { e.Rpm = 3000; e.MapKpa = 95; e.TpsPct = 90; e.SpeedKmh = 30; }),
        (2.0, (e, f) => { e.Rpm = 3000 + 3000 * f; e.SpeedKmh = 30 + 30 * f; }),
    };
    var cruise = new List<(double, Action<EngineState, double>)> { Hold(6, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 30; e.SpeedKmh = 90; }) };
    var on = new Dictionary<(string, int), byte> { [("TcEnable", 0)] = 1 };
    int maxRetard = 0, gear = 0;
    var tOn = Run(on, spin, sim => { maxRetard = Math.Max(maxRetard, sim.Bus.Ram[0xFC]); if (sim.Bus.Ram[0xFC] > 0) gear = sim.Bus.Ram[0x24F]; });
    var tOff = Run(new(), spin);
    int retardOff = tOff.Sim.Bus.Ram[0xFC];
    int maxCeil = asm.Image[Sym("TcMaxRetard")];
    // 0.1 s after the spin: the ROM's own tip-in retard is gone, TC's is still decaying
    int at = tOn.Ign.Count - 290;
    int ignOn = tOn.Ign[at].Ign, ignOff = tOff.Ign[at].Ign, fcAt = tOn.Ign[at].Retard;
    Check("wheelspin (6000 rpm/s at steady road speed) pulls timing", maxRetard > 0, $"retard up to {maxRetard / 4.0} deg in gear {gear}, ceiling {maxCeil / 4.0} deg");
    Check("retard stays within TcMaxRetard", maxRetard <= maxCeil, $"{maxRetard} <= {maxCeil}");
    Check("the timing the ROM applies drops by it", fcAt > 0 && Math.Abs(ignOff - ignOn - fcAt) <= 2, $"0.1 s after: timing {ignOn} vs {ignOff} with TC off, retard {fcAt} (0.25 deg units)");
    Check("retard decays back to 0 once the spin stops", tOn.Sim.Bus.Ram[0xFC] == 0, $"0FCh = {tOn.Sim.Bus.Ram[0xFC]} 3 s later");
    Check("TcEnable = 0: no retard", retardOff == 0, $"0FCh = {retardOff}");
    int pullRetard = 0, cruiseRetard = 0;
    Run(on, pull, sim => pullRetard = Math.Max(pullRetard, sim.Bus.Ram[0xFC]));
    Run(on, cruise, sim => cruiseRetard = Math.Max(cruiseRetard, sim.Bus.Ram[0xFC]));
    Check("a hard normal pull (1500 rpm/s in 2nd, speed rising) is left alone", pullRetard == 0, $"0FCh peak {pullRetard}");
    Check("steady cruise is left alone", cruiseRetard == 0, $"0FCh peak {cruiseRetard}");
}

// ------------------------------------------------------------------ rpm ceilings (LimitBySpeed / LimitByGear)
Console.WriteLine("rpm ceilings by road speed and by gear (LimitBySpeed / LimitByGear)");
{
    const int P3000 = 1875000 / 3000;   // 625 = 0271h
    var run4000 = new List<(double, Action<EngineState, double>)> { Hold(3, e => { e.Rpm = 800; }), Hold(3, e => { e.Rpm = 4000; e.MapKpa = 70; e.TpsPct = 40; e.SpeedKmh = 80; }) };
    var run2500 = new List<(double, Action<EngineState, double>)> { Hold(3, e => { e.Rpm = 800; }), Hold(3, e => { e.Rpm = 2500; e.MapKpa = 70; e.TpsPct = 40; e.SpeedKmh = 80; }) };
    var bySpeed = new Dictionary<(string, int), byte>();
    for (int k = 0; k < 5; k++) { bySpeed[("LimitBySpeed", 3 * k + 1)] = P3000 & 0xFF; bySpeed[("LimitBySpeed", 3 * k + 2)] = P3000 >> 8; }
    var byGear = new Dictionary<(string, int), byte>();
    for (int k = 0; k < 6; k++) { byGear[("LimitByGear", 2 * k)] = P3000 & 0xFF; byGear[("LimitByGear", 2 * k + 1)] = P3000 >> 8; }
    double baseInj = Run(new(), run4000).InjPerSec[1];
    double spdInj = Run(bySpeed, run4000).InjPerSec[1], spdLow = Run(bySpeed, run2500).InjPerSec[1];
    double gearInj = Run(byGear, run4000).InjPerSec[1], gearLow = Run(byGear, run2500).InjPerSec[1];
    Check("defaults (96h everywhere = 12500 rpm) leave 4000 rpm alone", baseInj > 100, $"{baseInj:0} injections/s");
    Check("LimitBySpeed 3000 rpm: 4000 rpm is cut", spdInj < baseInj * 0.3, $"{spdInj:0} injections/s");
    Check("LimitBySpeed 3000 rpm: 2500 rpm runs", spdLow > 60, $"{spdLow:0} injections/s");
    Check("LimitByGear 3000 rpm: 4000 rpm is cut", gearInj < baseInj * 0.3, $"{gearInj:0} injections/s");
    Check("LimitByGear 3000 rpm: 2500 rpm runs", gearLow > 60, $"{gearLow:0} injections/s");
}

// ------------------------------------------------------------------ anti-start
Console.WriteLine("anti-start (locked at power-up until A/C on + throttle down)");
{
    var arm = new Dictionary<(string, int), byte> { [("AntiStartEnable", 0)] = 1 };
    // key on (5 s boot), then whatever the driver does with the engine off, then crank and idle
    List<(double, Action<EngineState, double>)> Start(double tps, bool ac) =>
    [
        Hold(1.0, e => { e.Rpm = 0; e.MapKpa = 100; e.TpsPct = tps; e.AcRequest = ac; }),
        Hold(0.5, e => { e.TpsPct = 0; e.AcRequest = false; }),
        Hold(1.5, e => { e.Cranking = true; e.Rpm = 250; e.MapKpa = 90; }),
        Hold(3.0, e => { e.Cranking = false; e.Rpm = 900; e.MapKpa = 35; }),
    ];
    var off = Run(new(), Start(0, false));
    Check("anti-start off: engine runs", off.InjPerSec[3] > 10, $"{off.InjPerSec[3]:0} injections/s at idle");
    foreach (var (tps, ac, what) in new[] { (0.0, false, "nothing"), (100.0, false, "full throttle only (the code-flash request)"), (0.0, true, "A/C only"), (60.0, true, "A/C + 60% throttle") })
    {
        var r = Run(arm, Start(tps, ac));
        Check($"armed, {what}: no fuel", r.InjPerSec[2] < 1 && r.InjPerSec[3] < 1, $"cranking {r.InjPerSec[2]:0}/s, idle {r.InjPerSec[3]:0}/s; 0FDh = {r.Sim.Bus.Ram[0xFD]:X2}");
    }
    var ok = Run(arm, Start(100, true));
    Check("armed, A/C on + full throttle before cranking: runs", ok.InjPerSec[3] > 10, $"{ok.InjPerSec[3]:0} injections/s at idle; 0FDh = {ok.Sim.Bus.Ram[0xFD]:X2}");
}

// ------------------------------------------------------------------ speed limiter by switch
Console.WriteLine("speed limiter by switch (SwLimitSpeed / SwLimitInput / SwLimitInvert)");
{
    // 3B0h bit 2 is the A/C request; 100 km/h limit
    var lim = new Dictionary<(string, int), byte> { [("SwLimitSpeed", 0)] = 100, [("SwLimitInput", 0)] = 2 };
    List<(double, Action<EngineState, double>)> Drive(double kmh, bool ac) =>
    [
        Hold(2, e => { e.Rpm = 3500; e.MapKpa = 60; e.TpsPct = 30; e.SpeedKmh = kmh; e.AcRequest = ac; }),
        Hold(3, e => { }),
    ];
    double Inj(Dictionary<(string, int), byte> cal, double kmh, bool ac) => Run(cal, Drive(kmh, ac)).InjPerSec[1];
    double offCal = Inj(new(), 120, true), acOff = Inj(lim, 120, false), acOn = Inj(lim, 120, true), under = Inj(lim, 80, true);
    Check("default (FFh = off): A/C on at 120 km/h runs", offCal > 60, $"{offCal:0} injections/s");
    Check("100 km/h on A/C: A/C off at 120 km/h runs", acOff > 60, $"{acOff:0} injections/s");
    Check("100 km/h on A/C: A/C on at 120 km/h cuts", acOn < offCal * 0.3, $"{acOn:0} injections/s");
    Check("100 km/h on A/C: A/C on at 80 km/h runs", under > 60, $"{under:0} injections/s");
    var inv = new Dictionary<(string, int), byte>(lim) { [("SwLimitInvert", 0)] = 1 };
    double invOff = Inj(inv, 120, false), invOn = Inj(inv, 120, true);
    Check("inverted: A/C off at 120 km/h cuts", invOff < offCal * 0.3, $"{invOff:0} injections/s");
    Check("inverted: A/C on at 120 km/h runs", invOn > 60, $"{invOn:0} injections/s");
}

// ------------------------------------------------------------------ datalog
Console.WriteLine("datalog (40h: TC packet; 20h unchanged)");
{
    byte[] Ask(Simulator sim, byte cmd)
    {
        sim.Bus.TakeSerialTx();
        sim.Bus.QueueSerialRx([cmd], (uint)(Bus.CpuHz * 10 / 38400));
        for (ulong end = sim.Cpu.Cycles + (ulong)(0.1 * Bus.CpuHz); sim.Cpu.Cycles < end;) if (sim.StepOne() == null) break;
        return sim.Bus.TakeSerialTx();
    }
    var on = new Dictionary<(string, int), byte> { [("TcEnable", 0)] = 1 };
    var spin = new List<(double, Action<EngineState, double>)>
    {
        Hold(3, e => { e.Rpm = 4000; e.MapKpa = 95; e.TpsPct = 90; e.SpeedKmh = 40; }),
        (0.5, (e, f) => { e.Rpm = 4000 + 3000 * f; }),
    };
    var r = Run(on, spin);
    var sim = r.Sim;
    var p40 = Ask(sim, 0x40);
    var ram = sim.Bus.Ram;
    bool sum40 = p40.Length == 5 && (byte)(p40[0] + p40[1] + p40[2] + p40[3]) == p40[4];
    Check("40h answers 4 bytes + checksum", sum40, Convert.ToHexString(p40));
    // RAM is read 0.1 s after the request went out: the retard may have moved a step since
    Check("  TC retard, status, gear, TPS match RAM", sum40 && p40[0] > 0 && Math.Abs(p40[0] - ram[0xFC]) <= 8 && p40[1] == ram[0xFD] && p40[2] == ram[0x24F] && Math.Abs(p40[3] - sim.Bus.ReadDataU8(0x6F)) <= 2,
        sum40 ? $"packet: retard {p40[0] * 0.25} deg, status {p40[1]:X2}, gear {p40[2]}, TPS {p40[3]:X2}; RAM: {ram[0xFC] * 0.25} deg, {ram[0xFD]:X2}, {ram[0x24F]}, {sim.Bus.ReadDataU8(0x6F):X2}" : "");
    Ask(sim, 0x10);
    var p20 = Ask(sim, 0x20);
    Check("20h still answers the 51-byte frame + checksum", p20.Length == 52 && OkiRomSim.Calibration.HondaDatalog.Checksum(p20, 51) == p20[51], $"{p20.Length} bytes");
}

Console.WriteLine(failures == 0 ? "ALL PASS" : $"{failures} check(s) failed");
return failures == 0 ? 0 : 1;

static string FindRoot()
{
    var d = AppContext.BaseDirectory;
    while (d != null && !Directory.Exists(Path.Combine(d, "roms"))) d = Path.GetDirectoryName(d);
    return d ?? throw new Exception("cannot find the repository root (a folder with roms/)");
}

sealed class RunResult(Simulator sim)
{
    public Simulator Sim { get; } = sim;
    public List<double> InjPerSec { get; } = [];
    public List<(int Ign, int Retard)> Ign { get; } = [];     // per 10 ms slice
}
