using OkiRomSim.Calibration;

/// --fuzz: random mixes of functions. A mix either builds, or fails with the one "ROM is full ... N bytes too big"
/// message; the free space it reports goes down (never up) as functions are added; and anything that does not
/// fit gives the byte count.
static class SpaceFuzz
{
    public static void Run(Skeleton sk, Action<string, bool, string> check, int runs)
    {
        var rng = new Random(12345);
        var all = sk.Features.Select(f => f.Define).ToList();
        var otherErrors = new Dictionary<string, List<string>>();
        int built = 0, full = 0, nonMonotonic = 0, noCount = 0;
        var examples = new List<string>();
        for (int n = 0; n < runs; n++)
        {
            // a random order, added one at a time: each step a superset of the one before
            var order = all.OrderBy(_ => rng.Next()).ToList();
            var mix = new List<string>();
            int lastFree = int.MaxValue; bool wasFull = false;
            foreach (var d in order)
            {
                if (sk.Problems([.. mix, d]).Count > 0) continue;
                mix.Add(d);
                var r = sk.Build(mix);
                if (r.Success)
                {
                    built++;
                    if (wasFull) { nonMonotonic++; if (examples.Count < 60) examples.Add($"did not fit, then fitted with {d} added: {string.Join(" ", mix)}"); }
                    if (r.FreeBytes > lastFree && examples.Count < 60) examples.Add($"free went up {lastFree} -> {r.FreeBytes} adding {d}");
                    if (r.FreeBytes > lastFree && d != "FEAT_CYLTRIM") nonMonotonic++;   // cylinder trim takes a 3-byte check out of stock code
                    lastFree = r.FreeBytes;
                    continue;
                }
                var err = string.Join(" | ", r.Errors);
                if (err.StartsWith("the ROM is full")) { full++; wasFull = true; if (!err.Contains("bytes too big")) noCount++; }
                // the other limit: module RAM (56 bytes) - a mix of many RAM-hungry modules runs out of it before the ROM is full
                else if (err.Contains("module RAM is full")) { full++; wasFull = true; }
                else
                {
                    var key = System.Text.RegularExpressions.Regex.Replace(r.Errors.FirstOrDefault() ?? "", @"[0-9A-F]{4}h|\d+", "#");
                    if (!otherErrors.TryGetValue(key, out var l)) otherErrors[key] = l = [];
                    if (l.Count < 3) l.Add($"{err}  <=  {string.Join(" ", mix)}");
                    wasFull = true;
                }
            }
        }
        // "over by N" is exact: from a mix that is too big, taking out one function fits exactly when it frees N or more
        int exact = 0, inexact = 0; var bad = new List<string>();
        var rng2 = new Random(7);
        for (int n = 0; n < Math.Max(3, runs / 3); n++)
        {
            var mix = new List<string>();
            foreach (var d in all.OrderBy(_ => rng2.Next())) if (sk.Problems([.. mix, d]).Count == 0) mix.Add(d);
            var now = sk.Build(mix);
            if (now.Success) continue;
            foreach (var d in mix.OrderBy(_ => rng2.Next()).Take(12))
            {
                var less = mix.Where(x => x != d && sk.Feature(x)?.Requires.Contains(d) != true).ToList();
                if (sk.Problems(less).Count > 0) continue;
                var b = sk.Build(less);
                int freed = b.FreeBytes - now.FreeBytes;
                if ((freed >= now.Over) == b.Success) exact++; else { inexact++; if (bad.Count < 5) bad.Add($"{d}: over {now.Over}, frees {freed}, fits {b.Success}"); }
            }
        }
        foreach (var e in bad) Console.WriteLine("  " + e);
        check("  'over by N' is exact: taking out a function fits exactly when it frees N or more", inexact == 0 && exact > 0, $"{exact} right, {inexact} wrong");
        // builds on several threads at once (the New ROM window works the costs out that way) give the same images
        var mixes = Enumerable.Range(0, 12).Select(i => all.OrderBy(_ => rng2.Next()).Take(6 + i).Where(d => true).ToList()).Where(m => sk.Problems(m).Count == 0).ToList();
        var seq = mixes.Select(m => sk.Build(m)).ToList();
        var par = new SkeletonBuildResult[mixes.Count];
        Parallel.For(0, mixes.Count, i => par[i] = sk.Build(mixes[i]));
        bool same = seq.Zip(par).All(p => p.First.Success == p.Second.Success && p.First.FreeBytes == p.Second.FreeBytes &&
                    (p.First.Assembly == null || p.First.Assembly.Image.AsSpan().SequenceEqual(p.Second.Assembly!.Image)));
        check("  builds run in parallel give the same images as one at a time", same, $"{mixes.Count} mixes");
        foreach (var (k, l) in otherErrors) { Console.WriteLine($"  other error: {k}"); foreach (var e in l) Console.WriteLine($"      {e}"); }
        foreach (var e in examples) Console.WriteLine($"  {e}");
        check($"{runs} random mixes grown one function at a time: every failure is 'the ROM is full' with the byte count (or module RAM full)",
              otherErrors.Count == 0 && noCount == 0, $"{built} built, {full} full, {otherErrors.Count} other kinds of error, {noCount} full without a count");
        check("  and adding a function never makes a mix fit that did not, or frees space", nonMonotonic == 0, $"{nonMonotonic} times");
    }
}
