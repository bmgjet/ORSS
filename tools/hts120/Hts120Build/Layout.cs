namespace Hts120Build;

/// Moving things: removing byte runs from DB lines, inserting filler, pinning a region with ORG.
public static class Layout
{
    /// Remove the bytes [lo, hi) from the DB lines that hold them (the rest of each line stays).
    public static void RemoveBytes(Doc doc, int lo, int hi)
    {
        var r = doc.AssembleOrThrow("remove");
        var img = r.Image;
        var hits = Doc.ByLine(r).Where(kv => kv.Value.Any(e => e.Address < hi && e.Address + e.Length > lo)).OrderByDescending(kv => kv.Key).ToList();
        foreach (var (li, ents) in hits)
        {
            if (!Doc.IsData(doc.Lines[li])) throw new Exception($"{lo:X4}-{hi:X4} overlaps code: {doc.Lines[li].Trim()}");
            int a = ents.Min(e => e.Address), b = ents.Max(e => e.Address + e.Length);
            string? lab = Doc.Label(doc.Lines[li]);
            var keep = new List<string>();
            if (a < lo) keep.Add(Db(img, a, lo, lab));
            else if (lab != null) keep.Add(lab + ":");
            if (b > hi) keep.Add(Db(img, hi, b, null));
            doc.Lines.RemoveAt(li);
            doc.Lines.InsertRange(li, keep);
        }
    }

    public static string Db(byte[] img, int a, int b, string? label) =>
        $"{(label != null ? label + ":" : ""),-16}DB  {string.Join(",", Enumerable.Range(a, b - a).Select(i => $"0{img[i]:X2}h"))}";

    /// Index of the source line that assembles at `addr` (first byte).
    public static int LineAt(Doc doc, int addr)
    {
        var r = doc.AssembleOrThrow("line at");
        foreach (var (li, ents) in Doc.ByLine(r).OrderBy(k => k.Key))
            if (ents.Any(e => e.Address == addr)) return li;
        throw new Exception($"no line starts at {addr:X4}");
    }
}
