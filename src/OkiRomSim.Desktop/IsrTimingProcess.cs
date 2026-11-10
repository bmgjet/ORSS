// Copyright (c) bmgjet. All rights reserved.
using System.Diagnostics;
using System.Globalization;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// New ROM's interrupt-time meter for a skeleton on another part than the one the app is running (a P13 pick while a
/// P30 ROM is open): the simulator's part is the whole app's, so the pick is built and timed in a process of its own.
static class IsrTimingProcess
{
    /// Whether this skeleton's builds can be timed here, in the app's own simulator.
    public static bool SamePart(Skeleton sk) =>
        string.Equals(sk.Processor ?? ProcessorProfile.Msm66207().Name, ProcessorProfile.Current.Name, StringComparison.OrdinalIgnoreCase)
        || (sk.Processor == null && !string.Equals(ProcessorProfile.Current.Name, ProcessorProfile.Msm66911().Name, StringComparison.OrdinalIgnoreCase));

    /// The child: build the pick on its own part, time it as New ROM does (switches as built, then all on), print the two.
    public static int Run(string skeleton, string defines)
    {
        try
        {
            var sk = Skeleton.Load(skeleton);
            (ProcessorProfile.Builtin(sk.Processor ?? "") ?? ProcessorProfile.Msm66207()).Apply();
            var b = sk.Build(defines.Split(',', StringSplitOptions.RemoveEmptyEntries));
            if (b.Assembly == null) { Console.WriteLine("ISR none"); return 1; }
            var built = IsrTiming.Measure(b.Assembly, allOn: false);
            var on = built == null ? null : IsrTiming.Measure(b.Assembly, allOn: true);
            Console.WriteLine("ISR " + Line(built) + " | " + Line(on));
            return 0;
        }
        catch (Exception ex) { Console.WriteLine("ISR none " + ex.Message); return 1; }
    }

    static string Line(IsrTiming.Result? r) => r == null ? "-" :
        string.Join(" ", new[] { r.TickWorstUs, r.TickAverageUs, r.CpuPercent, r.LostTeeth, r.Resets }.Select(v => v.ToString(CultureInfo.InvariantCulture)));

    static IsrTiming.Result? Parse(string s)
    {
        var p = s.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (p.Length is < 4 or > 5) return null;
        double D(int i) => double.Parse(p[i], CultureInfo.InvariantCulture);
        return new(D(0), D(1), D(2), (int)D(3), p.Length > 4 ? (int)D(4) : 0);
    }

    /// The parent: run the child (this program, --isr-timing) and read its answer. Null when it does not run, is
    /// cancelled (the child is stopped) or takes more than 90 s.
    public static async Task<(IsrTiming.Result? Built, IsrTiming.Result? On)> Measure(Skeleton sk, IEnumerable<string> defines, CancellationToken ct)
    {
        var (exe, first) = Program.SelfCommand();
        var psi = new ProcessStartInfo(exe) { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in first) psi.ArgumentList.Add(a);
        psi.ArgumentList.Add("--isr-timing"); psi.ArgumentList.Add(sk.Path); psi.ArgumentList.Add(string.Join(",", defines));
        using var p = Process.Start(psi);
        if (p == null) return (null, null);
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(TimeSpan.FromSeconds(90));
        try
        {
            var output = await p.StandardOutput.ReadToEndAsync(limit.Token);
            await p.WaitForExitAsync(limit.Token);
            var line = output.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.StartsWith("ISR ", StringComparison.Ordinal));
            if (line == null || line.StartsWith("ISR none", StringComparison.Ordinal)) return (null, null);
            var halves = line[4..].Split('|');
            return (Parse(halves[0]), halves.Length > 1 ? Parse(halves[1]) : null);
        }
        catch (OperationCanceledException)
        {
            try { p.Kill(true); } catch { }
            ct.ThrowIfCancellationRequested();
            return (null, null);
        }
    }
}
