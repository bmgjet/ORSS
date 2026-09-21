using System.Text;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Mcp;

/// What changed between two ROMs (.bin or .asm): in function and features (routines found by following the code from the vectors, matched by their code shape so moved code is not reported as changed; for changed ones, what hardware, calls and tables they gained or lost), and in the calibration tables (maps detected in both, compared cell by cell where they sit at the same address), plus a raw byte summary.
public static class RomCompare
{
    public sealed record Options(bool Functions = true, bool Tables = true, int Max = 60);

    sealed record Fn(int Entry, string Name, int Count, string Shape, string Bytes, Explorer.Routine R);

    public static string Compare(Program66k a, Program66k b, Options? o = null)
    {
        o ??= new Options();
        var sb = new StringBuilder();
        string na = Path.GetFileName(a.Path), nb = Path.GetFileName(b.Path);
        sb.AppendLine($"A = {na}   B = {nb}");

        // ---- bytes
        var ranges = new List<(int Start, int End)>();
        int? s = null;
        int n = Math.Min(a.Image.Length, b.Image.Length);
        for (int i = 0; i <= n; i++)
        {
            bool diff = i < n && a.Image[i] != b.Image[i];
            if (diff && s == null) s = i;
            if (!diff && s != null) { ranges.Add((s.Value, i)); s = null; }
        }
        if (ranges.Count == 0) { sb.AppendLine("The images are byte-identical."); return sb.ToString(); }
        int changedBytes = ranges.Sum(r => r.End - r.Start);
        sb.AppendLine($"{changedBytes:N0} bytes differ in {ranges.Count} range(s).");

        // ---- vectors
        var vec = new List<string>();
        for (int v = 0; v < 0x38 / 2; v++)
        {
            int ta = a.Image[v * 2] | a.Image[v * 2 + 1] << 8, tb = b.Image[v * 2] | b.Image[v * 2 + 1] << 8;
            if (ta != tb) vec.Add($"{ProcessorProfile.Current.VectorNames.ElementAtOrDefault(v) ?? $"vector {v}"}: {a.Name(ta)} ({ta:X4}) -> {b.Name(tb)} ({tb:X4})");
        }
        if (vec.Count > 0) { sb.AppendLine(); sb.AppendLine("VECTORS CHANGED"); foreach (var x in vec) sb.AppendLine("  " + x); }

        // ---- tables
        var tableMask = new bool[Bus.RomSize];
        if (o.Tables)
        {
            var (da, db) = (Tables(a), Tables(b));
            sb.AppendLine();
            sb.AppendLine($"TABLES ({da.Items.Count} definitions found in A, {db.Items.Count} in B)");
            int same = 0, shown = 0;
            foreach (var ia in da.Items.Where(i => i.Count > 0).OrderBy(i => i.Address))
            {
                for (int k = ia.Address; k < ia.Address + ia.Span && k < Bus.RomSize; k++) if (k >= 0) tableMask[k] = true;
                var ib = db.Items.FirstOrDefault(x => x.Address == ia.Address && x.Rows == ia.Rows && x.Cols == ia.Cols && x.Type == ia.Type);
                if (ib == null)
                {
                    var moved = db.Items.FirstOrDefault(x => x.Rows == ia.Rows && x.Cols == ia.Cols && x.Rows > 1 && x.Category == ia.Category && x.Address != ia.Address);
                    if (ia.Rows > 1 && shown++ < o.Max)
                        sb.AppendLine(moved != null ? $"  {ia.Name} ({ia.Rows}x{ia.Cols}) moved {ia.Address:X4} -> {moved.Address:X4} ({moved.Name})"
                                                    : $"  {ia.Name} ({ia.Rows}x{ia.Cols} at {ia.Address:X4}) not found in B");
                    continue;
                }
                CellValue[] ca, cb;
                try { ca = RomData.Read(da, a.Image, ia); cb = RomData.Read(da, b.Image, ia); } catch { continue; }
                var diffs = Enumerable.Range(0, ca.Length).Where(k => ca[k].Raw != cb[k].Raw).ToList();
                if (diffs.Count == 0) { same++; continue; }
                if (shown++ >= o.Max) continue;
                double maxD = diffs.Max(k => Math.Abs(cb[k].Value - ca[k].Value));
                double avgD = diffs.Average(k => cb[k].Value - ca[k].Value);
                FormulaDef f; try { f = da.Formula(ia.Formula); } catch { f = Builtin.Raw; }
                sb.AppendLine($"  {ia.Name} [{ia.Category}] at {ia.Address:X4}: {diffs.Count} of {ca.Length} cells changed, average {avgD:+0.##;-0.##} {f.Unit}, largest {maxD:0.##} {f.Unit}");
                foreach (var k in diffs.Take(6))
                {
                    string where = ia.IsTable && ia.Cols > 0 ? $"[{k / ia.Cols},{k % ia.Cols}]" : "";
                    sb.AppendLine($"      {where} {ca[k].Display} -> {cb[k].Display}");
                }
                if (diffs.Count > 6) sb.AppendLine($"      ... {diffs.Count - 6} more");
            }
            foreach (var ib in db.Items.Where(x => x.Rows > 1 && !da.Items.Any(y => y.Address == x.Address)))
                if (shown++ < o.Max) sb.AppendLine($"  new in B: {ib.Name} ({ib.Rows}x{ib.Cols} at {ib.Address:X4}, {ib.Category})");
            sb.AppendLine($"  {same} table(s)/setting(s) identical.");
        }

        // ---- functions
        var codeMask = new bool[Bus.RomSize];
        if (o.Functions)
        {
            var fa = Functions(a); var fb = Functions(b);
            foreach (var f in fa.Values) foreach (var (addr, (d, _)) in f.R.Code) for (int k = 0; k < d.Len; k++) codeMask[(addr + k) & (Bus.RomSize - 1)] = true;
            var byShapeB = fb.Values.GroupBy(f => f.Shape).ToDictionary(g => g.Key, g => g.ToList());
            var matchedB = new HashSet<int>();
            var changed = new List<string>(); var moved = new List<string>(); var removed = new List<string>();
            int identical = 0;
            foreach (var f in fa.Values.OrderBy(f => f.Entry))
            {
                if (fb.TryGetValue(f.Entry, out var g) && g.Shape == f.Shape)
                {
                    matchedB.Add(g.Entry);
                    if (g.Bytes == f.Bytes) identical++;
                    else changed.Add($"  {f.Name} ({f.Entry:X4}): same instructions, different constants/addresses{Delta(f.R, g.R, a, b)}");
                    continue;
                }
                if (byShapeB.TryGetValue(f.Shape, out var cands) && cands.FirstOrDefault(c => !matchedB.Contains(c.Entry)) is { } mv)
                {
                    matchedB.Add(mv.Entry);
                    moved.Add($"  {f.Name} moved {f.Entry:X4} -> {mv.Entry:X4} ({mv.Name}), code unchanged");
                    continue;
                }
                if (fb.TryGetValue(f.Entry, out g))
                {
                    matchedB.Add(g.Entry);
                    changed.Add($"  {f.Name} ({f.Entry:X4}): {f.Count} -> {g.Count} instructions{Delta(f.R, g.R, a, b)}\n      now: {Trim(g.R.Purpose)}");
                    continue;
                }
                removed.Add($"  {f.Name} ({f.Entry:X4}, {f.Count} insns): {Trim(f.R.Purpose)}");
            }
            var added = fb.Values.Where(g => !matchedB.Contains(g.Entry)).OrderBy(g => g.Entry)
                .Select(g => $"  {g.Name} ({g.Entry:X4}, {g.Count} insns): {Trim(g.R.Purpose)}").ToList();
            sb.AppendLine();
            sb.AppendLine($"FUNCTIONS ({fa.Count} routines reached in A, {fb.Count} in B; {identical} identical)");
            void Section(string title, List<string> rows)
            {
                if (rows.Count == 0) return;
                sb.AppendLine($" {title} ({rows.Count}):");
                foreach (var r in rows.Take(o.Max)) sb.AppendLine(r);
                if (rows.Count > o.Max) sb.AppendLine($"  ... {rows.Count - o.Max} more");
            }
            Section("new in B (features added)", added);
            Section("changed", changed);
            Section("only in A (features removed or no longer reached)", removed);
            Section("moved", moved);
        }

        // ---- where the changed bytes are
        int inTables = 0, inCode = 0;
        foreach (var (st, en) in ranges)
            for (int i = st; i < en; i++)
            {
                if (i >= Bus.RomSize) break;
                if (tableMask[i]) inTables++;
                else if (codeMask[i]) inCode++;
            }
        sb.AppendLine();
        sb.AppendLine($"CHANGED BYTES: {inTables:N0} in tables/settings, {inCode:N0} in code, {changedBytes - inTables - inCode:N0} elsewhere (other data, free space).");
        if (inCode == 0 && inTables > 0) sb.AppendLine("Only calibration data changed: the code is the same, so this is a tune of the same ROM.");
        return sb.ToString();
    }

    static string Trim(string s) => s.Length > 160 ? s[..160] + "..." : s;

    static string Delta(Explorer.Routine x, Explorer.Routine y, Program66k a, Program66k b)
    {
        var parts = new List<string>();
        void Diff(string what, IEnumerable<string> ax, IEnumerable<string> bx)
        {
            var plus = bx.Except(ax).Take(6).ToList(); var minus = ax.Except(bx).Take(6).ToList();
            if (plus.Count > 0) parts.Add($"+{what} {string.Join(", ", plus)}");
            if (minus.Count > 0) parts.Add($"-{what} {string.Join(", ", minus)}");
        }
        Diff("hardware", x.Sfr.Concat(x.Bits), y.Sfr.Concat(y.Bits));
        Diff("calls", x.Calls.Select(a.Name), y.Calls.Select(b.Name));
        Diff("RAM writes", x.RamWrite, y.RamWrite);
        Diff("ROM data", x.RomData, y.RomData);
        return parts.Count == 0 ? "" : "; " + string.Join("; ", parts);
    }

    /// Every routine reached from the vectors and VCAL table, following calls and tail jumps.
    static Dictionary<int, Fn> Functions(Program66k p)
    {
        var ex = new Explorer(p);
        var result = new Dictionary<int, Fn>();
        var todo = new Queue<int>();
        for (int v = 0; v < 0x38 / 2; v++)
        {
            int t = p.Image[v * 2] | p.Image[v * 2 + 1] << 8;
            if (t >= 0x38 && t < Bus.RomSize) todo.Enqueue(t);
        }
        while (todo.Count > 0 && result.Count < 3000)
        {
            int e = todo.Dequeue();
            if (result.ContainsKey(e)) continue;
            Explorer.Routine r;
            try { r = ex.Walk(e, 1500); } catch { continue; }
            if (r.Code.Count == 0) continue;
            var shape = new StringBuilder(); var bytes = new StringBuilder();
            foreach (var (addr, (d, _)) in r.Code)
            {
                shape.Append(d.Mnemonic).Append(';');
                for (int i = 0; i < d.Len; i++) bytes.Append(p.Image[(addr + i) & 0x7FFF].ToString("X2"));
            }
            result[e] = new Fn(e, r.Name, r.Code.Count, Hash(shape.ToString()), Hash(bytes.ToString()), r);
            foreach (var c in r.Calls.Concat(r.TailJumps)) if (c >= 0x38 && c < Bus.RomSize && !result.ContainsKey(c)) todo.Enqueue(c);
        }
        return result;
    }

    static string Hash(string s) => Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(Encoding.UTF8.GetBytes(s)));

    static DefinitionSet Tables(Program66k p)
    {
        var defs = new DefinitionSet();
        defs.MergeBuiltinFormulas();
        if (p.Asm == null) return defs;
        try { CalibrationDetector.Detect(defs, p.Asm, p.Image, p.Sources.Select(kv => (kv.Key, string.Join("\n", kv.Value)))); }
        catch (Exception ex) { AppLog.Error("compare", "table detection failed", ex); }
        return defs;
    }
}
