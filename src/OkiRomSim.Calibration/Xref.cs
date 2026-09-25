// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Core;

namespace OkiRomSim.Calibration;

/// Builds a DefinitionSet from assembled source: every label becomes a lookup symbol, and `;@ ...` annotation comments become editable items. ;@ name=rev_limit type=u16 formula=rpm_period_word desc="Rev limiter" category=Limits rev_limit_value: dw 1500 ;@ name=ign_map rows=16 cols=20 type=u8 formula=ign_advance \ rows.axis=map_axis rows.formula=map_kpa cols.axis=rpm_axis cols.formula=rpm_axis_byte ign_map_low: db ... Annotations are ordinary comments, so annotated files still assemble unchanged.
public static class DefinitionBuilder
{
    static readonly Regex KeyValue = new(@"([A-Za-z_][\w.]*)\s*=\s*(""[^""]*""|\S+)");

    public static DefinitionSet FromAssembly(AssemblyResult asm, string name = "")
    {
        var defs = new DefinitionSet { Name = name, RomSize = asm.Image.Length };
        defs.MergeBuiltinFormulas();
        foreach (var s in asm.Symbols.Values)
            if (s.Kind is SymbolKind.Label or SymbolKind.Equate)
                defs.Symbols[s.Name] = (int)s.Value;

        // Consecutive ";@" lines at the same address are one annotation, so a long definition can be wrapped over several lines (a trailing "\\" is optional). A line that starts with a bare name is a definition of its own (a run of "at=" definitions all sit at one address).
        var merged = new List<Annotation>();
        foreach (var a in asm.Annotations)
        {
            var body = a.Text.TrimEnd().TrimEnd('\\').Trim();
            bool named = Regex.IsMatch(body, @"^[A-Za-z_]\w*(\s|$)");
            if (!named && merged.Count > 0 && merged[^1].Address == a.Address && merged[^1].File == a.File && a.Line - merged[^1].Line <= 1)
                merged[^1] = merged[^1] with { Text = merged[^1].Text + " " + body, Line = a.Line };
            else merged.Add(a with { Text = body });
        }
        foreach (var a in merged)
        {
            var item = Parse(a.Text, defs, a.Address);
            if (item == null) continue;
            item.Origin = $"{Path.GetFileName(a.File)}:{a.Line}";
            if (item.Name.Length == 0)
                item.Name = defs.Symbols.FirstOrDefault(kv => kv.Value == item.Address).Key ?? $"item_{item.Address:X4}";
            defs.Items.Add(item);
        }
        defs.Items.Sort((x, y) => x.Address.CompareTo(y.Address));
        return defs;
    }

    /// Parse one annotation body (everything after ";@").
    public static ItemDef? Parse(string text, DefinitionSet defs, int address)
    {
        text = text.Trim();
        if (text.Length == 0) return null;
        var item = new ItemDef { Address = address };
        // an optional bare first word is the name
        var first = Regex.Match(text, @"^([A-Za-z_]\w*)(\s|$)");
        if (first.Success && !text.TrimStart().StartsWith(first.Groups[1].Value + "="))
            item.Name = first.Groups[1].Value;
        var kv = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (Match m in KeyValue.Matches(text))
            kv[m.Groups[1].Value] = m.Groups[2].Value.Trim('"');

        string? Get(params string[] keys)
        {
            foreach (var k in keys) if (kv.TryGetValue(k, out var v)) return v;
            return null;
        }
        int? GetInt(params string[] keys) =>
            Get(keys) is { } s && int.TryParse(s, out var v) ? v : null;
        double? GetDouble(params string[] keys) =>
            Get(keys) is { } s && double.TryParse(s, NumberStyles.Any, CultureInfo.InvariantCulture, out var v) ? v : null;

        if (Get("name") is { } n) item.Name = n;
        if (Get("at", "address", "addr") is { } at && defs.TryResolve(at, out var resolved)) item.Address = resolved;
        item.Description = Get("desc", "description") ?? "";
        item.Category = Get("category", "cat") ?? "General";
        item.Formula = Get("formula", "scale", "conv");
        // "formula=x/100 unit=s" - an inline expression rather than a named formula
        item.Formula = Inline(defs, item.Formula, Get("inverse"), Get("unit"), GetInt("decimals"), GetDouble("step"), item.Name);
        item.Label = Get("label");
        item.Min = GetDouble("min");
        item.Max = GetDouble("max");
        item.Rows = GetInt("rows") ?? 0;
        item.Cols = GetInt("cols") ?? 0;
        if (Get("size") is { } size && Regex.Match(size, @"^(\d+)x(\d+)$") is { Success: true } sm)
        { item.Rows = int.Parse(sm.Groups[1].Value); item.Cols = int.Parse(sm.Groups[2].Value); }
        if (Get("count", "length", "len") is { } cnt && int.TryParse(cnt, out var c1))
        { item.Rows = 1; item.Cols = c1; }
        if (item.Rows > 0 && item.Cols == 0) item.Cols = 1;
        if (Get("type") is { } t) item.Type = ParseType(t, out int bit) ?? item.Type;
        item.Bit = GetInt("bit") ?? BitFrom(Get("type"));
        item.RowAxis = ParseAxis(kv, defs, "rows", item.Rows);
        item.ColAxis = ParseAxis(kv, defs, "cols", item.Cols);
        item.Slot = Get("slot");
        item.Stride = GetInt("stride") ?? 0;
        item.ColStride = GetInt("colstride", "cstride") ?? 0;
        if (Get("colscale") is { } cs && defs.TryResolve(cs, out var csa)) item.ColumnScaleAddress = csa;
        if (Get("flag") is { } fl)
        {
            item.Flag = fl is "1" or "true" or "yes";
            item.OnRaw = GetDouble("on") ?? item.OnRaw;
            item.OffRaw = GetDouble("off") ?? item.OffRaw;
        }
        return item;
    }

    /// A formula given as an expression rather than a name becomes a formula of its own, named from a stable hash of the expression (string.GetHashCode is randomised per run).
    static string? Inline(DefinitionSet defs, string? expr, string? inverse, string? unit, int? decimals, double? step, string owner)
    {
        if (expr == null || Regex.IsMatch(expr, @"^[A-Za-z_]\w*$")) return expr;
        uint h = 2166136261;
        foreach (char ch in expr + "|" + inverse + "|" + unit) h = (h ^ ch) * 16777619;
        var inline = new FormulaDef
        {
            Name = "inline_" + h.ToString("x8"), Expr = expr, Inverse = inverse, Unit = unit ?? "",
            Decimals = decimals ?? 2, Step = step ?? 0, Notes = $"inline formula from {owner}",
        };
        if (!defs.Formulas.Any(f => f.Name == inline.Name)) defs.Formulas.Add(inline);
        return inline.Name;
    }

    static readonly HashSet<string> BuiltinFormulas = BuildBuiltins();
    static HashSet<string> BuildBuiltins() { var d = new DefinitionSet(); d.MergeBuiltinFormulas(); return [.. d.Formulas.Select(f => f.Name)]; }

    /// The ";@" annotation body that Parse reads back into the same definition (name first, then key=value pairs; a formula that is not a built-in one is written out inline).
    public static string ToAnnotation(ItemDef item, DefinitionSet defs)
    {
        var sb = new System.Text.StringBuilder(item.Name);
        void Add(string key, string? value)
        {
            if (string.IsNullOrEmpty(value)) return;
            value = value.Replace('"', '\'');
            sb.Append(' ').Append(key).Append('=').Append(value.Any(char.IsWhiteSpace) ? $"\"{value}\"" : value);
        }
        string Type(CellType t, int bit) => t switch
        {
            CellType.U8 => "u8", CellType.S8 => "s8", CellType.U16 => "u16", CellType.S16 => "s16",
            CellType.U16BE => "u16be", CellType.S16BE => "s16be", _ => $"bit{bit}",
        };
        string Addr(int a) => defs.Symbols.FirstOrDefault(kv => kv.Value == a).Key ?? $"0{a:X4}h";
        void Formula(string prefix, string? name)
        {
            if (name == null) return;
            var f = defs.Formulas.FirstOrDefault(x => x.Name == name);
            if (f == null || BuiltinFormulas.Contains(name)) { Add(prefix + "formula", name); return; }
            // a bare name would read back as a formula name: (x) is the same expression
            string Expr(string? e) => e != null && Regex.IsMatch(e, @"^[A-Za-z_]\w*$") ? $"({e})" : e ?? "";
            Add(prefix + "formula", Expr(f.Expr)); Add(prefix + "inverse", f.Inverse == null ? null : Expr(f.Inverse)); Add(prefix + "unit", f.Unit);
            if (f.Decimals != 2) Add(prefix + "decimals", f.Decimals.ToString(CultureInfo.InvariantCulture));
            if (f.Step > 0) Add(prefix + "step", f.Step.ToString(CultureInfo.InvariantCulture));
        }
        Add("type", Type(item.Type, item.Bit));
        if (item.IsTable)
        {
            if (item.Rows == 1) Add("count", item.Cols.ToString(CultureInfo.InvariantCulture));
            else Add("size", $"{item.Rows}x{item.Cols}");
        }
        if (item.Stride > 0) Add("stride", item.Stride.ToString(CultureInfo.InvariantCulture));
        if (item.ColStride > 0) Add("colstride", item.ColStride.ToString(CultureInfo.InvariantCulture));
        if (item.ColumnScaleAddress is int c) Add("colscale", Addr(c));
        Formula("", item.Formula);
        if (item.Min is double mn) Add("min", mn.ToString(CultureInfo.InvariantCulture));
        if (item.Max is double mx) Add("max", mx.ToString(CultureInfo.InvariantCulture));
        if (item.Flag)
        {
            Add("flag", "1");
            Add("on", item.OnRaw.ToString(CultureInfo.InvariantCulture));
            Add("off", item.OffRaw.ToString(CultureInfo.InvariantCulture));
        }
        foreach (var (prefix, axis) in new[] { ("rows.", item.RowAxis), ("cols.", item.ColAxis) })
        {
            if (axis == null) continue;
            if (axis.Address is int aa) Add(prefix + "axis", Addr(aa));
            else Add(prefix + "name", axis.Name);
            if (axis.Values is { Length: > 0 } v) Add(prefix + "values", string.Join(",", v.Select(x => x.ToString(CultureInfo.InvariantCulture))));
            if (axis.Type != CellType.U8) Add(prefix + "type", Type(axis.Type, 0));
            if (axis.Stride > 0) Add(prefix + "stride", axis.Stride.ToString(CultureInfo.InvariantCulture));
            Formula(prefix, axis.Formula);
            Add(prefix + "unit", axis.Unit);
        }
        Add("label", item.Label);
        Add("category", item.Category == "General" ? null : item.Category);
        Add("slot", item.Slot);
        Add("desc", item.Description);
        return sb.ToString();
    }

    static int BitFrom(string? type)
    {
        var m = type == null ? Match.Empty : Regex.Match(type, @"^bit(\d)$", RegexOptions.IgnoreCase);
        return m.Success ? int.Parse(m.Groups[1].Value) : 0;
    }

    static CellType? ParseType(string t, out int bit)
    {
        bit = BitFrom(t);
        return t.ToLowerInvariant() switch
        {
            "u8" or "byte" or "db" => CellType.U8,
            "s8" or "sbyte" => CellType.S8,
            "u16" or "word" or "dw" => CellType.U16,
            "s16" or "short" => CellType.S16,
            "u16be" or "wordbe" => CellType.U16BE,
            "s16be" => CellType.S16BE,
            _ when t.StartsWith("bit", StringComparison.OrdinalIgnoreCase) => CellType.Bit,
            _ => null,
        };
    }

    static AxisDef? ParseAxis(Dictionary<string, string> kv, DefinitionSet defs, string prefix, int count)
    {
        string? Get(string k) => kv.TryGetValue(prefix + "." + k, out var v) ? v :
                                 kv.TryGetValue(prefix[..^1] + k, out var v2) ? v2 : null;   // rowAxis / colAxis
        var axisRef = Get("axis") ?? Get("Axis");
        var values = Get("values");
        if (axisRef == null && values == null && Get("formula") == null && Get("name") == null) return null;
        var axis = new AxisDef
        {
            Count = count, Name = Get("name") ?? axisRef, Unit = Get("unit") ?? "",
            Formula = Inline(defs, Get("formula"), Get("inverse"), Get("unit"), int.TryParse(Get("decimals"), out var dc) ? dc : null, null, prefix + " axis"),
            Stride = int.TryParse(Get("stride"), out var st) ? st : 0,
        };
        if (axisRef != null && defs.TryResolve(axisRef, out var a)) axis.Address = a;
        if (Get("type") is { } t && ParseType(t, out _) is { } ct) axis.Type = ct;
        if (values != null)
            axis.Values = [.. values.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries).Select(x => double.Parse(x, CultureInfo.InvariantCulture))];
        return axis;
    }
}

public sealed record XrefHit(int Address, string Label, string Text, int Operand, string Kind, string? Source);

/// Finds the code that touches an address — the practical way to work out what a byte means and what formula applies to it.
public static class Xref
{
    /// `boundaries` are known instruction start addresses (from an assembled source map). When none are supplied the ROM is swept linearly from `sweepFrom`, which can drift through data blocks, so treat those hits as hints.
    public static List<XrefHit> Find(byte[] rom, int target, IEnumerable<int>? boundaries = null,
        Func<int, string>? labelAt = null, Func<int, string?>? sourceAt = null, int sweepFrom = 0x38, int maxHits = 200)
    {
        var hits = new List<XrefHit>();
        var starts = boundaries?.OrderBy(x => x).ToList();
        bool dd = false;
        int pc = sweepFrom;
        var addresses = starts ?? [];
        if (starts == null)
        {
            while (pc < rom.Length && addresses.Count < 40000)
            {
                addresses.Add(pc);
                int at = pc;
                var dec = Decoder.Decode(dd, i => at + i < rom.Length ? rom[at + i] : (byte)0xFF);
                if (dec == null) { pc++; continue; }
                if (dec.DdAfter is bool v) dd = v;
                pc += dec.Len;
            }
        }
        dd = false;
        foreach (var a in addresses)
        {
            if (a < 0 || a >= rom.Length) continue;
            int at = a;
            var d = Decoder.Decode(dd, i => at + i < rom.Length ? rom[at + i] : (byte)0xFF)
                    ?? Decoder.Decode(!dd, i => at + i < rom.Length ? rom[at + i] : (byte)0xFF);
            if (d == null) continue;
            if (d.DdAfter is bool v2) dd = v2;
            var bytes = Enumerable.Range(0, d.Len).Select(i => at + i < rom.Length ? rom[at + i] : (byte)0xFF).ToArray();
            string kind = "";
            // 16-bit operand anywhere in the instruction
            for (int i = 0; i + 1 < bytes.Length; i++)
                if ((bytes[i] | (bytes[i + 1] << 8)) == target) kind = "word operand";
            // zero-page / SFR byte operand
            if (kind.Length == 0 && target < 0x100)
                for (int i = 1; i < bytes.Length; i++)
                    if (bytes[i] == target) kind = "direct/zero-page operand";
            if (kind.Length == 0) continue;
            var text = Decoder.Format(d, (ushort)(at + d.Len));
            hits.Add(new XrefHit(at, labelAt?.Invoke(at) ?? "", text, target, kind, sourceAt?.Invoke(at)));
            if (hits.Count >= maxHits) break;
        }
        return hits;
    }
}
