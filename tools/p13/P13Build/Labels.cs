using System.Text.RegularExpressions;

namespace P13Build;

public static class Labels
{
    /// Put `name` on the byte at `addr`, which must be inside a DB line (the line is split there).
    /// Returns the name actually used (an existing label at that byte wins).
    public static string At(Doc doc, int addr, string name)
    {
        var r = doc.AssembleOrThrow("label");
        foreach (var s in r.Symbols.Values)
            if (s.Kind == OkiRomSim.Assembler.SymbolKind.Label && s.Value == addr) return s.Name;
        var img = r.Image;
        foreach (var (li, ents) in Doc.ByLine(r))
        {
            var e = ents.FirstOrDefault(x => addr >= x.Address && addr < x.Address + x.Length);
            if (e == null) continue;
            if (!Doc.IsData(doc.Lines[li])) throw new Exception($"{addr:X4} is inside an instruction: {doc.Lines[li].Trim()}");
            if (addr == e.Address && Doc.Label(doc.Lines[li]) == null)
            {
                doc.Lines[li] = (name + ":").PadRight(16) + doc.Lines[li].TrimStart();
                return name;
            }
            // split: bytes before stay on the line (with its label), the rest get the new label
            int lo = e.Address, hi = e.Address + e.Length;
            string? lab = Doc.Label(doc.Lines[li]);
            string Db(int a, int b, string? l) => $"{(l != null ? l + ":" : ""),-16}DB  {string.Join(",", Enumerable.Range(a, b - a).Select(i => $"0{img[i]:X2}h"))} ; {a:X4}";
            doc.Lines[li] = Db(lo, addr, lab);
            doc.Lines.Insert(li + 1, Db(addr, hi, name));
            return name;
        }
        throw new Exception($"nothing assembles at {addr:X4}");
    }

    /// In code lines matching `lineFilter`, replace the immediate/address `#0XXXXh` (or bare
    /// `0XXXXh`) equal to `addr` with `name`. Returns how many were replaced.
    public static int Refer(Doc doc, int addr, string name, Regex lineFilter)
    {
        int n = 0;
        var num = new Regex(@"(?<![\w])(#?)0*" + addr.ToString("X4") + @"h\b", RegexOptions.IgnoreCase);
        for (int i = 0; i < doc.Lines.Count; i++)
        {
            var parts = doc.Lines[i].Split(';', 2);
            if (Doc.IsData(doc.Lines[i]) || !lineFilter.IsMatch(parts[0])) continue;
            var nc = num.Replace(parts[0], m => { n++; return m.Groups[1].Value + name; });
            if (nc != parts[0]) doc.Lines[i] = nc + (parts.Length > 1 ? ";" + parts[1] : "");
        }
        return n;
    }
}
