namespace P13Build;

public static class Tables
{
    /// Replace `count` little-endian words at `addr` (currently DB bytes, possibly spread over
    /// several DB lines) with "DW label" lines. The bytes before and after on the same lines stay DB.
    /// As ToDw, each word written as `text(i)` (a label, or a number for an entry that is not an address).
    public static void ToDwMixed(Doc doc, int addr, int count, Func<int, string> text, string tableLabel)
    {
        var r = doc.AssembleOrThrow("table");
        var img = r.Image;
        var byLine = Doc.ByLine(r);
        int end = addr + 2 * count;
        var lines = byLine.Where(kv => Doc.IsData(doc.Lines[kv.Key]) && kv.Value.Any(e => e.Address < end && e.Address + e.Length > addr))
                          .Select(kv => kv.Key).OrderBy(x => x).ToList();
        int lo = lines.Min(l => byLine[l].Min(e => e.Address)), hi = lines.Max(l => byLine[l].Max(e => e.Address + e.Length));
        string? firstLabel = Doc.Label(doc.Lines[lines[0]]);
        var outL = new List<string>();
        void Db(int a, int b, string? lab)
        {
            for (int k = a; k < b; k += 8)
            {
                var chunk = Enumerable.Range(k, Math.Min(8, b - k)).Select(i => $"0{img[i]:X2}h");
                outL.Add($"{(k == a && lab != null ? lab + ":" : ""),-16}DB  {string.Join(",", chunk)} ; {k:X4}");
            }
        }
        Db(lo, addr, addr == lo ? null : firstLabel);
        for (int i = 0; i < count; i++)
            outL.Add($"{(i == 0 ? tableLabel + ":" : ""),-16}DW  {text(i),-30}; {addr + 2 * i:X4}");
        Db(end, hi, null);
        doc.Lines.RemoveRange(lines[0], lines[^1] - lines[0] + 1);
        doc.Lines.InsertRange(lines[0], outL);
    }

    public static void ToDw(Doc doc, int addr, int count, IReadOnlyDictionary<int, string> names, string tableLabel)
    {
        var r = doc.AssembleOrThrow("table");
        var img = r.Image;
        var byLine = Doc.ByLine(r);
        int end = addr + 2 * count;
        var lines = byLine.Where(kv => Doc.IsData(doc.Lines[kv.Key]) && kv.Value.Any(e => e.Address < end && e.Address + e.Length > addr))
                          .Select(kv => kv.Key).OrderBy(x => x).ToList();
        if (lines.Count == 0) throw new Exception($"no DB lines at {addr:X4}");
        int lo = lines.Min(l => byLine[l].Min(e => e.Address)), hi = lines.Max(l => byLine[l].Max(e => e.Address + e.Length));
        string? firstLabel = Doc.Label(doc.Lines[lines[0]]);
        var outL = new List<string>();
        void Db(int a, int b, string? lab)
        {
            for (int k = a; k < b; k += 8)
            {
                var chunk = Enumerable.Range(k, Math.Min(8, b - k)).Select(i => $"0{img[i]:X2}h");
                outL.Add($"{(k == a && lab != null ? lab + ":" : ""),-16}DB  {string.Join(",", chunk)} ; {k:X4}");
            }
        }
        Db(lo, addr, firstLabel);
        for (int i = 0; i < count; i++)
        {
            int w = img[addr + 2 * i] | img[addr + 2 * i + 1] << 8;
            if (!names.TryGetValue(w, out var n)) throw new Exception($"table {addr:X4} entry {i}: no label at {w:X4}");
            outL.Add($"{(i == 0 ? tableLabel + ":" : ""),-16}DW  {n,-30}; {addr + 2 * i:X4}");
        }
        Db(end, hi, null);
        // lines are contiguous in the source for a table like this
        doc.Lines.RemoveRange(lines[0], lines[^1] - lines[0] + 1);
        doc.Lines.InsertRange(lines[0], outL);
    }
}
