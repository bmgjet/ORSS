using System.Text.RegularExpressions;

namespace Hts120Build;

/// J -> SJ and CAL -> SCAL wherever the target is within a signed 8-bit reach. Every change only
/// shrinks the code, so every distance only shrinks: a branch that fits after a pass still fits
/// after the next, and repeating until nothing changes needs no safety margin.
public static class Relax
{
    static readonly Regex Branch = new(@"^(J|CAL)\s+([A-Za-z_.?$@][\w.?$@]*)$", RegexOptions.IgnoreCase);

    public static (int Jumps, int Calls) Run(Doc doc, bool padTimingControl = false)
    {
        int jumps = 0, calls = 0;
        while (true)
        {
            var r = doc.AssembleOrThrow("relax");
            var labels = r.Symbols.Values.Where(s => s.Kind == OkiRomSim.Assembler.SymbolKind.Label)
                .ToDictionary(s => s.Name, s => (int)s.Value, StringComparer.OrdinalIgnoreCase);
            int n = 0;
            foreach (var (li, ents) in Doc.ByLine(r).OrderByDescending(k => k.Key))   // bottom up: a pad line shifts only what follows
            {
                var m = Branch.Match(Doc.Body(doc.Lines[li]));
                if (!m.Success || !labels.TryGetValue(m.Groups[2].Value, out int t)) continue;
                int d = t - (ents[0].Address + 2);
                if (d < -128 || d > 127) continue;
                bool call = m.Groups[1].Value.Equals("CAL", StringComparison.OrdinalIgnoreCase);
                if (padTimingControl && call) continue;
                var parts = doc.Lines[li].Split(';', 2);
                parts[0] = Regex.Replace(parts[0], @"(?<=^|[\s:])" + m.Groups[1].Value + @"(?=\s+" + Regex.Escape(m.Groups[2].Value) + @"\s*$)",
                    call ? "SCAL" : "SJ", RegexOptions.IgnoreCase);
                doc.Lines[li] = string.Join(";", parts);
                // timing control build: the same layout (a NOP nobody executes fills the third byte),
                // only the branch timing changes - tells a timing effect from a wrong target
                if (padTimingControl) { doc.Lines.Insert(li + 1, "                NOP                     ; timing control pad"); }
                if (call) calls++; else jumps++;
                n++;
            }
            if (n == 0) return (jumps, calls);
        }
    }
}
