using System.Text;
using System.Text.RegularExpressions;
using OkiRomSim.Core;
using Decoder = OkiRomSim.Core.Decoder;

namespace P13Build;

/// Turns DB bytes that are really code back into instructions with labels, and code addresses
/// written as numbers into label references - so the code can be moved.
public static class Symbolize
{
    public static int? Target(Decoded d, int pcAfter)
    {
        if (d.Mnemonic.Contains("addr16")) return d.Fields.Addr16;
        if (d.Mnemonic.Contains("rel8")) return (ushort)(pcAfter + d.Fields.Rel8);
        return null;
    }

    static string Op(Decoded d) => d.Mnemonic.Split(' ')[0];
    static bool Terminal(Decoded d) => Op(d) is "J" or "SJ" or "RT" or "RTI" or "BRK";

    static readonly Regex OffDirect = new(@"\boff (0[0-9A-F]+h)", RegexOptions.Compiled);
    static readonly Regex Hex4 = new(@"\b0([0-9A-F]{4})h\b", RegexOptions.Compiled);

    /// Decode `entries` (address, DD flag) inside bytes that are currently DB, follow their branches
    /// while they stay in DB bytes, and follow "MOV er0/DP/X1, #addr" when addr is a DB byte in
    /// `continuationRange` (a state machine that keeps its next step as a code address).
    /// Returns how many instructions were recovered.
    public static int Run(Doc doc, IEnumerable<(int Addr, bool Dd)> entries, (int Lo, int Hi) continuationRange, string labelPrefix)
    {
        var r = doc.AssembleOrThrow("symbolize (before)");
        var img = r.Image;
        var byLine = Doc.ByLine(r);
        // which bytes are DB, and which line produced each
        var dataLine = new int[img.Length];
        Array.Fill(dataLine, -1);
        foreach (var (li, ents) in byLine)
            if (Doc.IsData(doc.Lines[li]))
                foreach (var e in ents) for (int k = 0; k < e.Length; k++) dataLine[e.Address + k] = li;

        var insns = new SortedDictionary<int, (Decoded D, bool Dd)>();
        var owner = new int[img.Length]; Array.Fill(owner, -1);
        var targets = new HashSet<int>();
        var work = new Stack<(int, bool)>(entries);
        foreach (var (a, _) in entries) targets.Add(a);
        while (work.Count > 0)
        {
            var (start, dd0) = work.Pop();
            int pc = start; bool dd = dd0;
            while (pc < img.Length && dataLine[pc] >= 0 && owner[pc] < 0)
            {
                int at = pc;
                var d = Decoder.Decode(dd, i => at + i < img.Length ? img[at + i] : (byte)0xFF);
                if (d == null) break;
                bool ok = true;
                for (int k = 0; k < d.Len; k++) if (at + k >= img.Length || dataLine[at + k] < 0 || owner[at + k] >= 0) ok = false;
                if (!ok) break;
                for (int k = 0; k < d.Len; k++) owner[at + k] = at;
                insns[at] = (d, dd);
                if (d.DdAfter is bool v) dd = v;
                int next = at + d.Len;
                if (Target(d, next) is int t)
                {
                    if (t < img.Length && dataLine[t] >= 0 && owner[t] < 0) work.Push((t, dd));
                    targets.Add(t);
                }
                // a state machine's next step: "MOV er0, #addr" (44 98 lo hi) and friends
                if (d.Mnemonic.Contains("#N16") && d.Fields.N16 >= continuationRange.Lo && d.Fields.N16 < continuationRange.Hi)
                {
                    int c = d.Fields.N16;
                    if (dataLine[c] >= 0 && owner[c] < 0) work.Push((c, true));
                    targets.Add(c);
                }
                if (Terminal(d) || d.Mnemonic.Contains('[') && Op(d) == "J") break;
                pc = next;
            }
        }
        if (insns.Count == 0) return 0;

        // labels for every entry and branch target that is now code (keep existing names)
        var existing = new Dictionary<int, string>();
        foreach (var (li, ents) in byLine)
            if (Doc.Label(doc.Lines[li]) is string l && ents.Count > 0) existing.TryAdd(ents[0].Address, l);
        foreach (var s in r.Symbols.Values.Where(s => s.Kind == OkiRomSim.Assembler.SymbolKind.Label))
            existing.TryAdd((int)s.Value, s.Name);
        var names = new Dictionary<int, string>(existing);
        foreach (var t in targets.Where(t => insns.ContainsKey(t)).OrderBy(t => t))
            names.TryAdd(t, $"{labelPrefix}_{t:X4}");

        // rewrite every DB line that now holds code
        var touched = insns.Keys.Select(a => dataLine[a]).Distinct().OrderByDescending(x => x).ToList();
        foreach (var li in touched)
        {
            var ents = byLine[li];
            int lo = ents.Min(e => e.Address), hi = ents.Max(e => e.Address + e.Length);
            var outLines = new List<string>();
            var pending = new List<byte>(); int pendStart = lo;
            string? lineLabel = Doc.Label(doc.Lines[li]);
            void Flush()
            {
                for (int k = 0; k < pending.Count; k += 8)
                {
                    var chunk = pending.Skip(k).Take(8).Select(b => $"0{b:X2}h");
                    outLines.Add($"                DB  {string.Join(",", chunk)} ; {pendStart + k:X4}");
                }
                pending.Clear();
            }
            for (int a = lo; a < hi;)
            {
                // the tail of an instruction that started on the line before: already emitted there
                if (owner[a] >= 0 && owner[a] < a && owner[a] < lo) { a++; continue; }
                bool code = insns.TryGetValue(a, out var ins) && owner[a] == a;
                bool labelled = names.ContainsKey(a) && (code || targets.Contains(a));
                string? lab = labelled ? names[a] : null;
                if (a == lo && lineLabel != null)
                {
                    // the line's own label stays; a new name for the same byte becomes an alias
                    if (lab != null && lab != lineLabel) outLines.Add($"{lab}:");
                    lab = lineLabel;
                }
                if (lab != null || code) { Flush(); pendStart = a; }
                if (code)
                {
                    var text = Syntax(Decoder.Format(ins.D, (ushort)(a + ins.D.Len)), ins.D, a + ins.D.Len, names);
                    outLines.Add($"{(lab != null ? lab + ":" : ""),-16}{text}");
                    a += ins.D.Len; pendStart = a;
                }
                else
                {
                    if (lab != null) outLines.Add($"{lab}:");
                    if (pending.Count == 0) pendStart = a;
                    pending.Add(img[a]); a++;
                }
            }
            Flush();
            doc.Lines.RemoveAt(li);
            doc.Lines.InsertRange(li, outLines);
        }
        return insns.Count;
    }

    static string Syntax(string text, Decoded d, int pcAfter, Dictionary<int, string> names)
    {
        text = OffDirect.Replace(text, "off($1)");
        if (Target(d, pcAfter) is int t && names.TryGetValue(t, out var n))
            text = Hex4.Replace(text, m => Convert.ToInt32(m.Groups[1].Value, 16) == t ? n : m.Value, 1);
        // only pointer loads: "ADD er1, #2" is a number even though a vector sits at 0002h
        else if (d.Mnemonic.Contains("#N16") && Op(d) == "MOV" && d.Fields.N16 >= 0x100 && names.TryGetValue(d.Fields.N16, out var c))
            text = text.Replace($"#0{d.Fields.N16:X4}h", "#" + c);
        return text;
    }

    /// Anywhere in the file: "#0XXXXh" immediates in instructions whose value is one of `addrs`
    /// (code that is now labelled) become the label - the numbers a moved routine would leave behind.
    public static int LabelImmediates(Doc doc, IReadOnlyDictionary<int, string> addrs, Func<string, bool>? onlyIf = null)
    {
        int n = 0;
        for (int i = 0; i < doc.Lines.Count; i++)
        {
            var line = doc.Lines[i];
            if (Doc.IsData(line)) continue;
            var parts = line.Split(';', 2);
            var code = parts[0];
            if (onlyIf != null && !onlyIf(code)) continue;
            var nc = Regex.Replace(code, @"#0*([0-9A-Fa-f]{4,5})h\b", m =>
            {
                int v = Convert.ToInt32(m.Groups[1].Value, 16);
                if (addrs.TryGetValue(v, out var l)) { n++; return "#" + l; }
                return m.Value;
            });
            if (nc != code) doc.Lines[i] = nc + (parts.Length > 1 ? ";" + parts[1] : "");
        }
        return n;
    }
}
