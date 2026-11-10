using OkiRomSim.Calibration;
using OkiRomSim.Core;
static class Probe
{
    /// Called before every instruction of a run's warm-up (probing only).
    public static Action<Simulator>? Warmup;

    public static void Run(RunFn run)
    {
        (double, Action<EngineState, double>) S(double secs, Action<EngineState> set) => (secs, (e, _) => set(e));
        var r = run(["FEAT_WMI"], new() { ["wmi_enable"] = [1], ["wmi_out"] = [2], ["wmi_duty"] = [0, 0, 0, 0, 50, 50, 50, 50, 50] },
            [S(1, e => { e.Rpm = 4000; e.MapKpa = 100; e.TpsPct = 100; e.SpeedKmh = 100; })]);
        var b = r.Sim.Bus; var asm = r.Asm;
        long step = asm.Symbols.Values.First(x => x.Name == "MOD_SWSTEP").Value;
        int lastPin = -1, lastStep = -1; ulong t0 = b.ElapsedCycles; int lines = 0;
        while (b.ElapsedCycles - t0 < (ulong)(0.12 * Bus.CpuHz) && lines < 80)
        {
            r.Sim.StepOne();
            int pin = b.Ram[0x20] & 2, st = b.Ram[step];
            if (pin != lastPin || (st == 0 && lastStep != 0) || st == 12 && lastStep != 12)
            {
                Console.WriteLine($"{(b.ElapsedCycles - t0) / Bus.CyclesPerUs / 1000,8:0.00} ms  step {st,2}  P0.1 {(pin != 0 ? "high" : "low")}  masks {b.Ram[0x3DC]:X2}/{b.Ram[0x3DD]:X2} pc {r.Sim.Cpu.Pc:X4}");
                lines++;
            }
            lastPin = pin; lastStep = st;
        }
    }
}
