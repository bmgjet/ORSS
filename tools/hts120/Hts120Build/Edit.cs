using System.Text.RegularExpressions;

namespace Hts120Build;

/// Line-level edits that must hit exactly the line they mean: each checks it matched once.
public static class Edit
{
    /// The one line whose code (label and comment aside) matches `body`, optionally only on the line
    /// labelled `label`. With `with` null the instruction is dropped (its label, if any, stays).
    public static void Replace(Doc doc, string body, string? with, string? label = null)
    {
        int i = Find(doc, body, label);
        var line = doc.Lines[i];
        var lab = Doc.Label(line);
        var comment = line.Contains(';') ? " ;" + line.Split(';', 2)[1] : "";
        if (with == null) { if (lab != null) doc.Lines[i] = lab + ":"; else doc.Lines.RemoveAt(i); return; }
        doc.Lines[i] = ((lab != null ? lab + ":" : "").PadRight(16) + with).PadRight(52) + (with.StartsWith("CAL") ? "; HTS120 hook" : comment.Trim());
    }

    /// Insert `lines` `skip` lines after the one line matching `body` (1 = straight after it).
    public static void InsertAfter(Doc doc, string body, int skip, params string[] lines)
    {
        int i = Find(doc, body, null);
        doc.Lines.InsertRange(i + skip, lines);
    }

    public static int ReplaceAll(Doc doc, string pattern, MatchEvaluator ev)
    {
        int n = 0;
        var re = new Regex(pattern, RegexOptions.IgnoreCase);
        for (int i = 0; i < doc.Lines.Count; i++)
        {
            if (Doc.IsData(doc.Lines[i])) continue;
            var parts = doc.Lines[i].Split(';', 2);
            var nc = re.Replace(parts[0], m => { n++; return ev(m); });
            if (nc != parts[0]) doc.Lines[i] = nc + (parts.Length > 1 ? ";" + parts[1] : "");
        }
        return n;
    }

    static int Find(Doc doc, string body, string? label)
    {
        var re = new Regex(body, RegexOptions.IgnoreCase);
        var hits = Enumerable.Range(0, doc.Lines.Count)
            .Where(i => re.IsMatch(Doc.Body(doc.Lines[i])) && (label == null || Doc.Label(doc.Lines[i]) == label)).ToList();
        if (hits.Count != 1) throw new Exception($"expected one line matching /{body}/{(label != null ? " at " + label : "")}, found {hits.Count}");
        return hits[0];
    }
}
