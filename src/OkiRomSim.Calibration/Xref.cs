using System.Globalization;
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Core;

namespace OkiRomSim.Calibration;

/// Builds a DefinitionSet from assembled source: every label becomes a lookup symbol, and
/// `;@ ...` annotation comments become editable items.
/// ;@ name=rev_limit type=u16 formula=rpm_period_word desc="Rev limiter" category=Limits rev_limit_value: dw 1500
/// ;@ name=ign_map rows=16 cols=20 type=u8 formula=ign_advance \ rows.axis=map_axis rows.formula=map_kpa cols.axis=rpm_axis cols.formula=rpm_axis_byte ign_map_low: db ...
/// Annotations are ordinary comments, so annotated files still assemble unchanged.
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

        // Consecutive ";@" lines at the same address are one annotation, so a long definition
        // can be wrapped over several lines (a trailing "\\" is optional).
        var merged = new List<Annotation>();
        foreach (var a in asm.Annotations)
        {
            var body = a.Text.TrimEnd().TrimEnd('\\').Trim();
            if (merged.Count > 0 && merged[^1].Address == a.Address && merged[^1].File == a.File && a.Line - merged[^1].Line <= 1)
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
        if (item.Formula != null && !Regex.IsMatch(item.Formula, @"^[A-Za-z_]\w*$"))
        {
            var inline = new FormulaDef
            {
                Name = "inline_" + Math.Abs(item.Formula.GetHashCode()).ToString("x8"),
                Expr = item.Formula,
                Inverse = Get("inverse"),
                Unit = Get("unit") ?? "",
                Decimals = GetInt("decimals") ?? 2,
                Step = GetDouble("step") ?? 0,
                Notes = $"inline formula from {item.Name}",
            };
            if (!defs.Formulas.Any(f => f.Name == inline.Name)) defs.Formulas.Add(inline);
            item.Formula = inline.Name;
        }
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
        return item;
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
        var axis = new AxisDef { Count = count, Name = Get("name") ?? axisRef, Unit = Get("unit") ?? "", Formula = Get("formula") };
        if (axisRef != null && defs.TryResolve(axisRef, out var a)) axis.Address = a;
        if (Get("type") is { } t && ParseType(t, out _) is { } ct) axis.Type = ct;
        if (values != null)
            axis.Values = values.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(x => double.Parse(x, CultureInfo.InvariantCulture)).ToArray();
        return axis;
    }
}

public sealed record XrefHit(int Address, string Label, string Text, int Operand, string Kind, string? Source);

/// Finds the code that touches an address — the practical way to work out what a byte means and what formula applies to it.
public static class Xref
{
    /// `boundaries` are known instruction start addresses (from an assembled source map). When
    /// none are supplied the ROM is swept linearly from `sweepFrom`, which can drift through
    /// data blocks, so treat those hits as hints.
    public static List<XrefHit> Find(byte[] rom, int target, IEnumerable<int>? boundaries = null,
        Func<int, string>? labelAt = null, Func<int, string?>? sourceAt = null, int sweepFrom = 0x38, int maxHits = 200)
    {
        var hits = new List<XrefHit>();
        var starts = boundaries?.OrderBy(x => x).ToList();
        bool dd = false;
        int pc = sweepFrom;
        var addresses = starts ?? new List<int>();
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
                if ((bytes[i] | bytes[i + 1] << 8) == target) kind = "word operand";
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
