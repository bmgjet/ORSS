// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Assembler;
using OkiRomSim.Core;

namespace OkiRomSim.Calibration;

/// How long a ROM's interrupts run, measured by running it in the simulator: the 2.048 ms tick (timer 1, where the skeleton's modules run) above all, which keeps every other interrupt waiting while it runs. A tick that ran too long is what stopped skeleton ROMs with many modules starting on the car; long ones still hold up the crank and spark interrupts at high rpm.
public static class IsrTiming
{
    /// The tick (timer 1) handler.
    public const string Tick = "int_timer_1";
    /// Up to here the tick is comfortable; past Caution it holds the crank interrupts up long enough to matter at high rpm (a crank tooth every few hundred us).
    public const double GoodUs = 200, CautionUs = 330;
    /// The top of the timing run (rpm); ISR_HIGH_RPM sets another, for the harness.
    static int HighRpm => int.TryParse(Environment.GetEnvironmentVariable("ISR_HIGH_RPM"), out var r) ? r : 7000;

    /// Worst and average tick (us, its own time, less what interrupted it), and the share of the CPU interrupts take (the crank task, which runs as an interrupt that lets the others in, among them).
    /// LostTeeth: how often, at 3000 and 7000 rpm, the crank decode gave up on a reading (the stock code's period
    /// saturate path) - 0 on a ROM whose interrupts leave the crank enough time; more means the rpm reading fails at
    /// high rpm (and with it the fuel and the over-rev cut's view of the engine).
    public sealed record Result(double TickWorstUs, double TickAverageUs, double CpuPercent, int LostTeeth = 0);

    /// Run the ROM: booted at idle, then idle, 3000 rpm and 7000 rpm at full throttle, every interrupt timed. `allOn` switches on every setting a module has an on/off switch for first (a module that is off mostly skips its work: the tune will switch them on). Null when it is cancelled or the ROM does not run.
    public static Result? Measure(AssemblyResult asm, bool allOn = true, CancellationToken ct = default)
    {
        var rom = (byte[])asm.Image.Clone();
        if (allOn)
            foreach (var f in DefinitionBuilder.FromAssembly(asm, "timing").Items.Where(i => i.Flag && i.Address >= 0 && i.Address < rom.Length
                                                                                      && i.Slot?.StartsWith("boardopt.", StringComparison.OrdinalIgnoreCase) != true))
            {
                int v = (int)f.OnRaw;
                rom[f.Address] = (byte)v;
                if (f.ElementSize == 2 && f.Address + 1 < rom.Length) rom[f.Address + 1] = (byte)(v >> 8);
            }
        RomChecksum.Balance(rom, asm.ChecksumAddress ?? 0x7FFF);
        var sim = new Simulator();
        sim.LoadRom(rom);
        var e = sim.Engine;
        e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.VbattVolts = 13.8;
        sim.SyncSensors();
        var open = new List<(string Name, ulong Since, ulong Own)>();
        var worst = new Dictionary<string, ulong>();
        ulong tickSum = 0; long tickN = 0, inIsr = 0;
        bool on = false;
        int lostAt = asm.Symbols.TryGetValue("crank_cycle_period_saturate", out var ls) ? (int)ls.Value : -1, lost = 0;
        ulong settled = ulong.MaxValue;     // the rpm is set in one step here, which no engine does: the decode resyncs after it, so it counts once settled
        bool Go(double secs)
        {
            ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz);
            while (sim.Cpu.Cycles < end)
            {
                if ((sim.Cpu.Instructions & 0xFFFF) == 0 && ct.IsCancellationRequested) return false;
                if (on && sim.Cpu.Pc == lostAt && sim.Cpu.Cycles >= settled) lost++;
                var st = sim.StepOne();
                if (st == null || sim.State == RunState.Faulted) return false;
                if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
                if (!on) continue;
                ulong now = sim.Cpu.Cycles;
                if (st?.Decoded is { } d && d.Mnemonic.StartsWith("RTI", StringComparison.Ordinal) && open.Count > 0)
                {
                    var top = open[^1]; open.RemoveAt(open.Count - 1);
                    ulong own = top.Own + (now - top.Since);
                    worst[top.Name] = Math.Max(worst.GetValueOrDefault(top.Name), own);
                    if (top.Name == Tick) { tickSum += own; tickN++; }
                    inIsr += (long)own;
                    if (open.Count > 0) { var o = open[^1]; open[^1] = (o.Name, now, o.Own); }
                }
                if (sim.LastStepInterrupted)
                {
                    if (open.Count > 0) { var o = open[^1]; open[^1] = (o.Name, o.Since, o.Own + (now - o.Since)); }
                    open.Add((asm.LabelAt(sim.Cpu.Pc) ?? $"{sim.Cpu.Pc:X4}", now, 0));
                }
            }
            return true;
        }
        if (!Go(4)) return null;
        on = true;
        ulong t0 = sim.Cpu.Cycles;
        // (5000 rpm on the way up: a step from 3000 straight to the top leaves the stock crank decode resyncing for most of a
        // second, and the rpm readings it drops then are the step's, not the ROM's; only settled readings count)
        // (driving: standing still at 7000 rpm full throttle, every switch on, has launch control cutting far over its point
        // the whole time - no engine stays there, it is held at the launch rpm)
        // (the top three times, 6800 / 7000 / 7200 rpm: the simulator's clocks are exact, and at one rpm the crank events can
        // fall on the other interrupts the same way every turn - a coincidence the car, whose clocks drift, never holds. A
        // ROM is only said to lose the rpm reading when it does at all three.)
        var losses = new List<int>();
        foreach (var (rpm, map, tps, secs, kmh) in new[] { (850, 33.0, 0.0, 0.7, 0.0), (3000, 60.0, 20.0, 0.7, 60.0), (5000, 90.0, 80.0, 0.4, 100.0),
                                                           (HighRpm - 200, 100.0, 100.0, 0.5, 140.0), (HighRpm, 100.0, 100.0, 0.5, 140.0), (HighRpm + 200, 100.0, 100.0, 0.5, 140.0) })
        {
            e.Rpm = rpm; e.MapKpa = map; e.TpsPct = tps; e.SpeedKmh = kmh; sim.SyncSensors();
            bool top = rpm >= HighRpm - 200;
            settled = top ? sim.Cpu.Cycles + (ulong)(0.2 * Bus.CpuHz) : ulong.MaxValue;
            lost = 0;
            if (!Go(secs)) return null;
            if (top) losses.Add(lost);
        }
        lost = losses.Count == 0 ? 0 : losses.Min();
        double us = Bus.CpuHz / 1e6;
        if (!worst.TryGetValue(Tick, out var tw)) return null;
        return new Result(tw / us, tickN == 0 ? 0 : tickSum / (double)tickN / us,
                          inIsr * 100.0 / Math.Max(1, sim.Cpu.Cycles - t0), lost);
    }
}
