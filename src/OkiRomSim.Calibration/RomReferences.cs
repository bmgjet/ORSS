// Copyright (c) bmgjet. All rights reserved.
using System.Text.Json;
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Core;

namespace OkiRomSim.Calibration;

/// A ROM whose tables are known (annotated with ";@" definitions, or at least labelled), kept as its code and its definitions so that another ROM of the same family, with no labels at all, can be matched against it. Honda ECUs of one generation share most of their code: the instruction that reads a table in one ROM reads the same table in another, only at a different address. Lining the two programs up instruction by instruction and reading the operands side by side says where each known table is in the unknown ROM.
public sealed class RomReference
{
    public required string Name { get; init; }
    /// The code, one entry per instruction in address order: its shape (operands abstracted) and the value of each operand.
    internal List<CodeLine> Code { get; init; } = [];
    /// How many instructions of it can be lined up with another ROM's.
    public int Instructions => Code.Count;
    /// The tables and settings, at the reference's own addresses.
    public required List<ItemDef> Items { get; init; }
    /// Its tables are defined (";@": sizes, scaling, pages), not only labelled: it goes before the ones that are only labelled.
    public bool Annotated { get; init; }
    /// An HTS ROM: its code reads HTS's own settings where a stock ROM reads its option bytes, so it names a stock ROM's tables only after the stock references have had their turn (and an HTS ROM's before them).
    public bool Hts { get; init; }
    /// What its RAM input bytes are: the axis formula of the tables read on each (TableShapes.LearnInputs).
    public Dictionary<int, FormulaDef> Inputs { get; init; } = [];
    /// The reference's own formulas (its inline ones among them), so a table placed from it keeps its scaling.
    public Dictionary<string, FormulaDef> Formulas { get; init; } = new(StringComparer.OrdinalIgnoreCase);

    internal sealed record CodeLine(int Addr, string Key, long?[] Values)
    {
        /// For each value: a direct operand (an address), not an immediate ("#n").
        public bool[] Direct()
        {
            var d = new List<bool>();
            for (int i = 0; i < Key.Length; i++)
                if (Key[i] == '#') { bool imm = i + 1 < Key.Length && Key[i + 1] == '#'; d.Add(!imm); if (imm) i++; }
            return [.. d];
        }
    }

    static readonly Regex DataLine = new(@"^\s*([A-Za-z_][\w]*\s*:)?\s*(DB|DW|DS)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    static readonly Regex Atom = new(@"[A-Za-z_][A-Za-z0-9_]*(?:[+-](?:0x)?[0-9A-Fa-f]+[hH]?)?|\$?[0-9][0-9A-Fa-f]*[hH]?", RegexOptions.Compiled);
    static readonly Regex LeadLabel = new(@"^\s*[A-Za-z_][\w]*\s*:", RegexOptions.Compiled);
    static readonly HashSet<string> Regs = new(StringComparer.OrdinalIgnoreCase)
    {
        "a", "acc", "acch", "er0", "er1", "er2", "er3", "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "x1", "x2", "dp", "usp", "ssp",
        "lrb", "psw", "pswh", "pswl", "c", "off",
    };

    /// The code of an assembled program, from its source lines (so any two sources written in this assembler's syntax compare alike).
    internal static List<CodeLine> CodeOf(AssemblyResult asm, IReadOnlyDictionary<string, string[]> texts)
    {
        var list = new List<CodeLine>();
        int last = -1;
        foreach (var e in asm.SourceMap.OrderBy(e => e.Address))
        {
            if (e.Address == last) continue;
            if (!texts.TryGetValue(e.File, out var lines) || e.Line < 1 || e.Line > lines.Length) continue;
            var text = lines[e.Line - 1];
            int c = text.IndexOf(';');
            if (c >= 0) text = text[..c];
            if (DataLine.IsMatch(text)) continue;
            while (LeadLabel.Match(text) is { Success: true } m) text = text[m.Length..];
            text = text.Trim();
            if (text.Length == 0) continue;
            var parts = text.Split((char[])[' ', '\t'], 2, StringSplitOptions.RemoveEmptyEntries);
            var values = new List<long?>();
            string ops = parts.Length > 1 ? Atom.Replace(parts[1], m =>
            {
                var t = m.Value;
                if (Regs.Contains(t)) return t.ToLowerInvariant();
                if (asm.Symbols.TryGetValue(t, out var sfr) && sfr.Kind == SymbolKind.Sfr) return t.ToUpperInvariant();
                values.Add(Value(t, asm));
                return "#";
            }) : "";
            list.Add(new CodeLine(e.Address, parts[0].ToUpperInvariant() + " " + Regex.Replace(ops, @"\s+", ""), [.. values]));
            last = e.Address;
        }
        return list;
    }

    static long? Value(string t, AssemblyResult asm)
    {
        var m = Regex.Match(t, @"^([A-Za-z_]\w*)(?:([+-])((?:0x)?[0-9A-Fa-f]+[hH]?))?$");
        if (m.Success)
        {
            if (!asm.Symbols.TryGetValue(m.Groups[1].Value, out var s)) return null;
            long off = m.Groups[3].Success ? Number(m.Groups[3].Value) ?? 0 : 0;
            return m.Groups[2].Value == "-" ? s.Value - off : s.Value + off;
        }
        return Number(t);
    }

    static long? Number(string t)
    {
        t = t.TrimStart('$');
        if (t.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) return long.TryParse(t[2..], System.Globalization.NumberStyles.HexNumber, null, out var x) ? x : null;
        if (t.EndsWith('h') || t.EndsWith('H')) return long.TryParse(t[..^1], System.Globalization.NumberStyles.HexNumber, null, out var h) ? h : null;
        return long.TryParse(t, out var d) ? d : null;
    }

    internal static Dictionary<string, string[]> Texts(AssemblyResult asm, Func<string, string?>? read = null)
    {
        var texts = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in asm.SourceMap.Select(e => e.File).Distinct())
        {
            string? t = read?.Invoke(f);
            if (t == null && File.Exists(f)) t = File.ReadAllText(f);
            if (t != null) texts[f] = t.Replace("\r\n", "\n").Split('\n');
        }
        return texts;
    }

    /// A name worth carrying to another ROM: one a person (or the annotations) gave, not one made up from an address or a routine.
    public static bool Meaningful(string n) =>
        !Regex.IsMatch(n, @"^(tbl|loc|sub|map|axis|item|lbl|data|rpm_axis|load_axis)_[0-9A-Fa-f]{4}$|_(tbl|data|const|table|tab)(_\d+)?$|_tbl_|^code_start$|_vec$|_(if|load|store|cmp|goto|call|set|clear)_|ram[0-9a-f]{3}", RegexOptions.IgnoreCase);

    /// Load a reference from an assembled program: its ";@" definitions, and (for a source that has only labels) its labelled data blocks and the tables its code reads, kept only where they carry a real name.
    public static RomReference? From(string name, AssemblyResult asm, Func<string, string?>? read = null)
    {
        if (!asm.Success) return null;
        var texts = Texts(asm, read);
        var defs = DefinitionBuilder.FromAssembly(asm, name);
        var annotated = defs.Items.Count;
        CalibrationDetector.Detect(defs, asm, asm.Image, texts.Select(kv => (kv.Key, string.Join("\n", kv.Value))), references: null);
        var items = defs.Items.Where(i => i.Origin?.StartsWith("detected") != true || Meaningful(i.Name)).ToList();
        if (items.Count == 0) return null;
        return new RomReference { Name = name, Code = CodeOf(asm, texts), Items = items, Annotated = annotated > 20, Hts = HtsLayout.Version(asm.Image) != 0,
                                  Formulas = defs.Formulas.GroupBy(f => f.Name, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase),
                                  Inputs = TableShapes.LearnInputs(asm, texts, items, n => { try { return defs.Formula(n); } catch { return null; } }) };
    }

    /// Assemble a source and load it as a reference.
    public static RomReference? FromFile(string path, IDictionary<string, long>? defines = null)
    {
        try
        {
            var o = new AssemblerOptions();
            if (defines != null) foreach (var (k, v) in defines) o.Defines[k] = v;
            var asm = new OkiAssembler(o).AssembleFile(path);
            return From(Path.GetFileName(path), asm);
        }
        catch { return null; }
    }

    /// The references the app ships (next to it, in Templates): every skeleton with all its stock functions built back in, and every other annotated or labelled source there and in Templates/References. Loaded once.
    public static IReadOnlyList<RomReference> Shipped(string? folder = null)
    {
        folder ??= Path.Combine(AppContext.BaseDirectory, "Templates");
        lock (Cache)
        {
            if (Cache.TryGetValue(folder, out var have)) return have;
            var list = new List<RomReference>();
            if (Directory.Exists(folder))
            {
                foreach (var sk in Skeleton.Find(folder))
                    if (FromFile(sk.Path, sk.Features.Where(f => f.Stock).ToDictionary(f => f.Define, _ => 1L)) is { } r) list.Add(r);
                var more = Directory.GetFiles(folder, "*.asm").Where(f => !f.EndsWith("-skeleton.asm", StringComparison.OrdinalIgnoreCase)).ToList();
                var refs = Path.Combine(folder, "References");
                if (Directory.Exists(refs)) more.AddRange(Directory.GetFiles(refs, "*.asm"));
                foreach (var f in more.OrderBy(f => f, StringComparer.OrdinalIgnoreCase))
                    if (FromFile(f) is { } r) list.Add(r);
            }
            Cache[folder] = list;
            return list;
        }
    }
    /// The shipped references, less the target itself (a ROM is not its own reference).
    public static IReadOnlyList<RomReference> ShippedFor(string? targetPath) =>
        [.. Shipped().Where(r => targetPath == null || !Path.GetFileName(targetPath).Equals(r.Name, StringComparison.OrdinalIgnoreCase))];

    static readonly Dictionary<string, IReadOnlyList<RomReference>> Cache = new(StringComparer.OrdinalIgnoreCase);
}

/// Places a reference's tables in another ROM (see <see cref="RomReference"/>).
public static class ReferenceMatcher
{
    /// Pairs of (reference index, target index) of instructions that line up: runs of identical instruction shapes, anchored on runs that occur once in each program, and extended outwards while the shapes still agree.
    internal static List<(int A, int B)> Align(IReadOnlyList<string> a, IReadOnlyList<string> b)
    {
        var pairs = new List<(int, int)>();
        AlignRange(a, b, 0, a.Count, 0, b.Count, 8, pairs, 0);
        pairs.Sort();
        return pairs;
    }

    static void AlignRange(IReadOnlyList<string> a, IReadOnlyList<string> b, int a0, int a1, int b0, int b1, int k, List<(int, int)> pairs, int depth)
    {
        if (a1 - a0 < k || b1 - b0 < k) return;
        string Gram(IReadOnlyList<string> s, int i) => string.Join("|", Enumerable.Range(i, k).Select(x => s[x]));
        var ca = new Dictionary<string, int>(); var ia = new Dictionary<string, int>();
        for (int i = a0; i + k <= a1; i++) { var g = Gram(a, i); ca[g] = ca.GetValueOrDefault(g) + 1; ia[g] = i; }
        var cb = new Dictionary<string, int>(); var ib = new Dictionary<string, int>();
        for (int j = b0; j + k <= b1; j++) { var g = Gram(b, j); cb[g] = cb.GetValueOrDefault(g) + 1; ib[g] = j; }
        var anchors = ca.Where(kv => kv.Value == 1 && cb.GetValueOrDefault(kv.Key) == 1).Select(kv => (A: ia[kv.Key], B: ib[kv.Key])).OrderBy(x => x.A).ToList();
        // the longest chain of anchors in order in both programs
        var chain = Lis(anchors);
        // runs: each anchor, extended both ways while the shapes agree
        var runs = new List<(int A, int B, int Len)>();
        foreach (var (x, y) in chain)
        {
            if (runs.Count > 0 && x - y == runs[^1].A - runs[^1].B && x < runs[^1].A + runs[^1].Len) continue;
            int s = 0; while (x - s - 1 >= a0 && y - s - 1 >= b0 && a[x - s - 1] == b[y - s - 1] && (runs.Count == 0 || x - s - 1 >= runs[^1].A + runs[^1].Len && y - s - 1 >= runs[^1].B + runs[^1].Len)) s++;
            int e = k; while (x + e < a1 && y + e < b1 && a[x + e] == b[y + e]) e++;
            runs.Add((x - s, y - s, s + e));
        }
        int pa = a0, pb = b0;
        foreach (var (x, y, len) in runs)
        {
            if (x < pa || y < pb) continue;
            if (depth < 2 && k > 3) AlignRange(a, b, pa, x, pb, y, Math.Max(3, k / 2), pairs, depth + 1);
            for (int t = 0; t < len; t++) pairs.Add((x + t, y + t));
            pa = x + len; pb = y + len;
        }
        if (depth < 2 && k > 3) AlignRange(a, b, pa, a1, pb, b1, Math.Max(3, k / 2), pairs, depth + 1);
    }

    static List<(int A, int B)> Lis(List<(int A, int B)> xs)
    {
        var tails = new List<int>(); var prev = new int[xs.Count]; var tailIdx = new List<int>();
        for (int i = 0; i < xs.Count; i++)
        {
            int lo = 0, hi = tails.Count;
            while (lo < hi) { int mid = (lo + hi) / 2; if (tails[mid] < xs[i].B) lo = mid + 1; else hi = mid; }
            prev[i] = lo > 0 ? tailIdx[lo - 1] : -1;
            if (lo == tails.Count) { tails.Add(xs[i].B); tailIdx.Add(i); } else { tails[lo] = xs[i].B; tailIdx[lo] = i; }
        }
        var outp = new List<(int, int)>();
        for (int i = tailIdx.Count > 0 ? tailIdx[^1] : -1; i >= 0; i = prev[i]) outp.Add(xs[i]);
        outp.Reverse();
        return outp;
    }

    /// The reference's tables at their places in the target: copies of the reference definitions with the target's addresses, sized to fit (never into the target's code or the next table found), axes carried over when their tables were found too. Only a place that the operands of lined-up code agree on is used.
    public static List<ItemDef> Place(RomReference r, AssemblyResult target, IReadOnlyDictionary<string, string[]> texts, Func<int, bool> isCode)
        => Place(r, target, texts, isCode, out _, out _);

    /// As above; `lined` = how many instructions lined up (how alike the two programs are), `inputs` = this ROM's RAM input bytes that are the reference's known inputs, with their axis formulas.
    public static List<ItemDef> Place(RomReference r, AssemblyResult target, IReadOnlyDictionary<string, string[]> texts, Func<int, bool> isCode,
                                      out int lined, out Dictionary<int, FormulaDef> inputs)
    {
        var code = RomReference.CodeOf(target, texts);
        var pairs = Align([.. r.Code.Select(c => c.Key)], [.. code.Select(c => c.Key)]);
        lined = pairs.Count;
        // which of the reference's RAM bytes each of this ROM's is (the same operand of lined-up code)
        var ramVotes = new Dictionary<int, Dictionary<int, int>>();
        foreach (var (ia, ib) in pairs)
        {
            var ca = r.Code[ia]; var cb = code[ib];
            if (ca.Values.Length != cb.Values.Length) continue;
            var da = ca.Direct();
            for (int k = 0; k < ca.Values.Length && k < da.Length; k++)
                if (da[k] && ca.Values[k] is long x && cb.Values[k] is long y && x < 0x400 && y < 0x400)
                {
                    if (!ramVotes.TryGetValue((int)y, out var v)) ramVotes[(int)y] = v = [];
                    v[(int)x] = v.GetValueOrDefault((int)x) + 1;
                }
        }
        inputs = [];
        foreach (var (mine, v) in ramVotes)
        {
            var best = v.OrderByDescending(kv => kv.Value).First();
            if (r.Inputs.TryGetValue(best.Key, out var formula) && best.Value * 2 > v.Values.Sum()) inputs[mine] = formula;
        }
        var spans = r.Items.Where(i => i.Address >= 0x38).Select(i => (Item: i, End: i.Address + Math.Max(1, i.Span))).OrderBy(x => x.Item.Address).ToList();
        var votes = new Dictionary<ItemDef, Dictionary<int, int>>();
        foreach (var (ia, ib) in pairs)
        {
            var va = r.Code[ia].Values; var vb = code[ib].Values;
            if (va.Length != vb.Length) continue;
            for (int k = 0; k < va.Length; k++)
            {
                if (va[k] is not long x || vb[k] is not long y || x < 0x38 || y < 0x38 || y >= Bus.RomSize) continue;
                foreach (var (item, end) in spans)
                {
                    if (x < item.Address || x >= end) continue;
                    int at = (int)(y - (x - item.Address));
                    if (!votes.TryGetValue(item, out var v)) votes[item] = v = [];
                    v[at] = v.GetValueOrDefault(at) + 1;
                }
            }
        }
        // each reference item: its best place (a clear winner only)
        var placed = new Dictionary<ItemDef, int>();
        foreach (var (item, v) in votes)
        {
            var best = v.OrderByDescending(kv => kv.Value).ToList();
            if (best[0].Key < 0x38 || best.Count > 1 && best[1].Value * 2 >= best[0].Value) continue;
            if (isCode(best[0].Key)) continue;
            placed[item] = best[0].Key;
        }
        // one item per target address: the one with the most votes
        var byAddr = placed.GroupBy(kv => kv.Value).Select(g => g.OrderByDescending(kv => votes[kv.Key][kv.Value]).First()).ToDictionary(kv => kv.Key, kv => kv.Value);
        var starts = byAddr.Values.OrderBy(a => a).ToList();
        var result = new List<ItemDef>();
        foreach (var (item, at) in byAddr.OrderBy(kv => kv.Value))
        {
            int next = starts.FirstOrDefault(s => s > at, Bus.RomSize);
            int room = 0;
            while (at + room < next && at + room < Bus.RomSize && !isCode(at + room)) room++;
            var copy = Clone(item);
            copy.Address = at;
            int span = Math.Max(1, item.Span);
            if (room < span)
            {
                int w = item.Type is CellType.U16 or CellType.S16 ? 2 : 1;
                if (item.Rows > 1 || room < w) continue;                  // a map that does not fit: not this one
                copy.Rows = 1; copy.Cols = room / w;
            }
            copy.RowAxis = Move(item.RowAxis, r, byAddr);
            copy.ColAxis = Move(item.ColAxis, r, byAddr);
            // a map is only as sure as its axes: one whose axes were not found here is not taken on its own word
            if (item.Rows > 1 && (item.RowAxis?.Address != null && copy.RowAxis?.Address == null || item.ColAxis?.Address != null && copy.ColAxis?.Address == null)) continue;
            if (item.ColumnScaleAddress is int cs) copy.ColumnScaleAddress = MoveAddr(cs, r, byAddr);
            copy.Origin = $"detected: like {item.Name} in {r.Name}";
            copy.Slot = item.Slot;
            result.Add(copy);
        }
        return result;
    }

    static AxisDef? Move(AxisDef? axis, RomReference r, Dictionary<ItemDef, int> placed)
    {
        if (axis == null) return null;
        var a = JsonSerializer.Deserialize<AxisDef>(JsonSerializer.Serialize(axis, DefinitionSet.Json), DefinitionSet.Json)!;
        if (axis.Address is int ad) a.Address = MoveAddr(ad, r, placed);
        return a;
    }

    static int? MoveAddr(int addr, RomReference r, Dictionary<ItemDef, int> placed)
    {
        foreach (var (item, at) in placed)
            if (addr >= item.Address && addr < item.Address + Math.Max(1, item.Span)) return at + (addr - item.Address);
        return null;
    }

    static ItemDef Clone(ItemDef i) => JsonSerializer.Deserialize<ItemDef>(JsonSerializer.Serialize(i, DefinitionSet.Json), DefinitionSet.Json)!;
}
