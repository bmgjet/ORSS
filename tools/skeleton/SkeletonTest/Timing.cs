using System.Diagnostics;
using OkiRomSim.Calibration;

static class Timing
{
    public static void Run(Skeleton sk)
    {
        var sw = Stopwatch.StartNew();
        var r = sk.Build(["FEAT_STOCK_DTC"]);
        Console.WriteLine($"first build {sw.ElapsedMilliseconds} ms, free {r.FreeBytes}");
        sw.Restart();
        for (int i = 0; i < 5; i++) sk.Build(["FEAT_STOCK_DTC"]);
        Console.WriteLine($"build avg {sw.ElapsedMilliseconds / 5} ms; features {sk.Features.Count}; alloc/build {GC.GetTotalAllocatedBytes() / 7 / 1048576} MB, gen0 {GC.CollectionCount(0)} gen2 {GC.CollectionCount(2)}");
        sw.Restart();
        Parallel.ForEach(sk.Features, new ParallelOptions { MaxDegreeOfParallelism = Math.Clamp(Environment.ProcessorCount / 2, 1, 4) }, f => sk.Build(["FEAT_STOCK_DTC", f.Define]));
        Console.WriteLine($"costs {sw.ElapsedMilliseconds} ms (cores {Environment.ProcessorCount})");
    }
}
