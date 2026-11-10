// --svcprobe FEAT_... : the service state command (5Fh) and a GIO toggle on a build, with what came back
using OkiRomSim.Core;

static class SvcProbe
{
    public static int Run(RunFn run, string[] defs)
    {
        int k = 0;
        var said = new List<string>();
        var cal = defs.Contains("FEAT_GIO1") ? new Dictionary<string, byte[]> { ["gio1_block"] = [1, 6, 0, 0x80, 0, 0xEA, 0x00, 0xF0, 0x00, 0, 255, 0, 255, 255, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0] } : new Dictionary<string, byte[]>();
        var r = run(defs, cal, [(4, (e, _) => { e.Rpm = 850; e.MapKpa = 33; })], sim =>
        {
            double t = ++k * 0.01;
            foreach (var b in sim.Bus.TakeSerialTx()) said.Add($"{b:X2}@{t:0.00}");
            if (k % 50 == 0) said.Add($"[P1 {sim.Bus.Ram[0x22]:X2}]");
            if (k == 100 || k == 200 || k == 300) sim.Bus.QueueSerialRx([k == 100 ? (byte)0x5F : (byte)0x58], (uint)(Bus.CpuHz * 10 / 38400));
        });
        Console.WriteLine($"{string.Join(" ", defs)}: halted {r.Halted}, {r.InjPerSec[^1]:0} inj/s; said {string.Join(" ", said)}; P1 {r.Sim.Bus.Ram[0x22]:X2}");
        return 0;
    }
}
