// --basemaps: the boost and alpha-N base map tools on skeleton builds, printed before and after, and the boosted ROM run.
using OkiRomSim.Calibration;
using OkiRomSim.Core;

static class BaseMaps
{
    public static int Run(Skeleton sk, Action<string, bool, string> check)
    {
        foreach (var ext in new[] { false, true })
        {
            string[] defs = ext ? ["FEAT_EXTMAPS"] : [];
            var b = sk.Build(defs);
            var d = DefinitionBuilder.FromAssembly(b.Assembly!, "basemaps");
            d.MergeBuiltinFormulas();
            var rom = (byte[])b.Assembly!.Image.Clone();
            MapSensorScale.ApplyFormulas(d, rom);
            // a 3 bar sensor first, as the tool asks
            Console.WriteLine(MapSensorScale.Swap(d, rom, MapSensorScale.Stock, (11, 3155)));
            var (axis, n, maps) = BaseMapScaler.LoadAxis(d)!.Value;
            var fuel = maps.First(m => m.Name == "FuelLow");
            var ign = maps.First(m => m.Name == "IgnitionLow");
            double[] Row(byte[] r, ItemDef m, int row) => [.. RomData.Read(d, r, m).Skip(row * n).Take(n).Select(c => c.Value)];
            var axisBefore = RomData.AxisValues(d, rom, axis, n);
            var fuelBefore = Row(rom, fuel, 15); var ignBefore = Row(rom, ign, 15);
            var work = (byte[])rom.Clone();
            var said = BaseMapScaler.Boost(d, work, new(12, ext ? 8 : 4, 120, 0.75));
            Console.WriteLine($"{(ext ? "20" : "10")} columns: {said}");
            var axisAfter = RomData.AxisValues(d, work, axis, n);
            var fuelAfter = Row(work, fuel, 15); var ignAfter = Row(work, ign, 15);
            string J(double[] v, string fmt) => string.Join(" ", v.Select(x => x.ToString(fmt)));
            Console.WriteLine("  axis   " + J(axisBefore, "0") + "\n      -> " + J(axisAfter, "0"));
            Console.WriteLine("  fuel   " + J(fuelBefore, "0.00") + "\n      -> " + J(fuelAfter, "0.00"));
            Console.WriteLine("  timing " + J(ignBefore, "0.0") + "\n      -> " + J(ignAfter, "0.0"));
            bool climbs = axisAfter.Zip(axisAfter.Skip(1)).All(p => p.Second > p.First);
            int top = Array.FindLastIndex(axisAfter, v => v <= BaseMapScaler.AtmMbar + 10);   // (the last atmospheric breakpoint, as rounded to the axis)
            double fuelAtm = fuelAfter[top], psiTop = (axisAfter[^1] - BaseMapScaler.AtmMbar) / BaseMapScaler.MbarPerPsi;
            double wantFuel = fuelAtm * (1 + (1.2 * (axisAfter[^1] - BaseMapScaler.AtmMbar) / BaseMapScaler.AtmMbar));
            check($"{(ext ? 20 : 10)} columns: the axis climbs to about 12 psi", climbs && Math.Abs(psiTop - 12) < 0.6, $"top {axisAfter[^1]:0} mBar = {psiTop:0.0} psi");
            check("  the fuel at 12 psi: 120 % of the pressure rise over the last atmospheric column", Math.Abs(fuelAfter[^1] / wantFuel - 1) < 0.03 || fuelAfter[^1] >= 1030,
                  $"{fuelAfter[^1]:0.00} against {wantFuel:0.00} (atmospheric {fuelAtm:0.00})");
            check("  the timing at 12 psi: 0.75 deg a psi less", Math.Abs(ignAfter[top] - ignAfter[^1] - (0.75 * psiTop)) < 0.6,
                  $"{ignAfter[top]:0.0} -> {ignAfter[^1]:0.0} deg");
            check("  the atmospheric part keeps its values (the same fuel at the same load)",
                  Enumerable.Range(0, top + 1).All(c => Math.Abs(fuelAfter[c] - Interp(axisBefore, fuelBefore, axisAfter[c])) <= Math.Max(0.05 * fuelAfter[c], 0.1)), "");
            // the boosted ROM runs: idle, cruise and 10 psi in the simulator
            var sim = new Simulator(); var img = (byte[])work.Clone(); RomChecksum.Balance(img, b.Assembly.ChecksumAddress ?? 0x7FFF); sim.LoadRom(img);
            var e = sim.Engine; e.EctCelsius = 85; e.Rpm = 850; e.MapKpa = 33; sim.SyncSensors();
            long inj0 = 0; bool ran = true;
            foreach (var (rpm, kpa, tps) in new[] { (850.0, 33.0, 0.0), (3000.0, 60.0, 30.0), (5000.0, 170.0, 100.0) })
            {
                e.Rpm = rpm; e.MapKpa = kpa; e.TpsPct = tps; sim.SyncSensors();
                inj0 = sim.Bus.InjectorEvents.Sum();
                for (ulong end = sim.Cpu.Cycles + (ulong)(3 * Bus.CpuHz); sim.Cpu.Cycles < end;)
                {
                    if (sim.StepOne() == null || sim.State == RunState.Faulted) { ran = false; break; }
                    if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
                }
            }
            check("  the boosted ROM runs (idle, cruise, 10 psi at 5000 rpm)", ran && sim.Bus.InjectorEvents.Sum() - inj0 > 300, $"{sim.Bus.InjectorEvents.Sum() - inj0} injections in the last 3 s");
        }
        // alpha-N
        {
            var b = sk.Build(["FEAT_ALPHAN"]);
            var d = DefinitionBuilder.FromAssembly(b.Assembly!, "alphan");
            d.MergeBuiltinFormulas();
            var rom = (byte[])b.Assembly!.Image.Clone();
            MapSensorScale.ApplyFormulas(d, rom);
            var (axis, n, maps) = BaseMapScaler.LoadAxis(d)!.Value;
            var said = BaseMapScaler.AlphaN(d, rom, new(600, 20, 6));
            Console.WriteLine("alpha-N: " + said);
            var table = CalPage.Bound(d, "mapindex.alpha")!;
            var tv = RomData.Read(d, rom, table).Select(c => c.Value).ToArray();
            var ax = RomData.AxisValues(d, rom, axis, n);
            Console.WriteLine("  axis   " + string.Join(" ", ax.Select(x => x.ToString("0"))) + "\n  throttle table " + string.Join(" ", tv.Select(x => x.ToString("0"))));
            check("alpha-N: switched on, the throttle table climbs from the crossover to the top load column",
                  RomData.Read(d, rom, CalPage.Bound(d, "mapindex.enable")!)[0].Value != 0 && tv.Zip(tv.Skip(1)).All(p => p.Second >= p.First) && Math.Abs(tv[^1] - ax[^1]) < 15,
                  $"{tv[0]:0} .. {tv[^1]:0} mBar, axis top {ax[^1]:0}");
        }
        return 0;
    }

    static double Interp(double[] axis, double[] row, double x)
    {
        if (x <= axis[0]) return row[0];
        for (int i = 0; i < axis.Length - 1; i++)
            if (x <= axis[i + 1]) return row[i] + ((row[i + 1] - row[i]) * (x - axis[i]) / Math.Max(1e-9, axis[i + 1] - axis[i]));
        return row[^1];
    }
}
