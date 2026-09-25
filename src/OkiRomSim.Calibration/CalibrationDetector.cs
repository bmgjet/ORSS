// Copyright (c) bmgjet. All rights reserved.
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Core;

namespace OkiRomSim.Calibration;

public sealed record DetectResult(int Added, int Replaced, int Maps, int Switches, List<string> Names)
{
    public string Summary => Added + Replaced == 0 && Switches == 0 ? "nothing new found"
        : $"{Added} added, {Replaced} improved, {Maps} maps from the lookup code, {Switches} switches";
}

/// Finds calibration data in an assembled ROM and adds it to a definition set: maps from the 2D lookup set-up code (with RPM and load axes), labelled DB/DW blocks, tables read with LC/LCB, and on/off switches. Hand-made and imported definitions are never replaced; an earlier rough guess is improved when something better is found at the same address. Shared by the Calibration page and the MCP server.
public static class CalibrationDetector
{
    static readonly Regex LabelData = new(@"^\s*([A-Za-z_][\w]*)\s*:\s*(DB|DW)\b\s*(.*)$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    static readonly Regex MoreData = new(@"^\s+(DB|DW)\b\s*(.*)$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    static readonly Regex DataLine = new(@"^\s*([A-Za-z_][\w]*\s*:)?\s*(DB|DW)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public static DetectResult Detect(DefinitionSet defs, AssemblyResult asm, byte[] rom, IEnumerable<(string Path, string Text)> sources)
    {
        var src = sources.ToList();
        var texts = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
        foreach (var (path, text) in src)
            try { texts[Path.GetFullPath(path)] = text.Split('\n'); } catch { }
        bool IsCode(int a)
        {
            var e = asm.Lookup(a);
            if (e == null) return false;
            return !texts.TryGetValue(e.File, out var lines) || e.Line < 1 || e.Line > lines.Length ? true : !DataLine.IsMatch(lines[e.Line - 1]);
        }
        int added = 0, replaced = 0;
        var names = new List<string>();
        void Put(ItemDef item, bool improves = false)
        {
            var same = defs.Items.FirstOrDefault(i => i.Address == item.Address);
            if (same == null) { defs.Items.Add(item); added++; names.Add(item.Name); return; }
            bool rough = same.Origin?.StartsWith("detected") == true && !(same.Origin?.Contains("2D") ?? false);
            // a map found again with different geometry (a better column count, say) replaces the earlier detection - but never a hand-made or imported definition
            bool restated = same.Origin?.StartsWith("detected") == true && item.Origin?.StartsWith("detected") == true &&
                            (same.Rows != item.Rows || same.Cols != item.Cols || same.Stride != item.Stride);
            if (restated)
            {
                same.Rows = item.Rows; same.Cols = item.Cols; same.Stride = item.Stride;
                if (item.ColAxis != null) same.ColAxis = item.ColAxis;
                if (item.RowAxis != null) same.RowAxis = item.RowAxis;
                replaced++; names.Add(same.Name);
                return;
            }
            if (rough && (improves || item.IsTable && item.Rows > 1 || item.RowAxis != null))
            {
                defs.Items.Remove(same); defs.Items.Add(item); replaced++; names.Add(item.Name);
            }
        }

        // 1. maps from the 2D lookup set-up code, with their axes
        var symbols = asm.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).GroupBy(s => s.Name).ToDictionary(g => g.Key, g => (int)g.First().Value);
        var maps = TableDetector.Detect(src.Select(s => s.Text), symbols, rom, IsCode);
        foreach (var m in maps) Put(m.Item);
        foreach (var m in maps)
            foreach (var (axis, what) in new[] { (m.Item.RowAxis, "rpm axis"), (m.Item.ColAxis, "load axis") })
                if (axis?.Address is int aa && !defs.Items.Any(i => i.Address == aa && i.Category == "Axes"))
                    Put(new ItemDef
                    {
                        Name = axis.Name ?? $"axis_{aa:X4}", Address = aa, Rows = 1, Cols = axis.Count, Formula = axis.Formula, Category = "Axes",
                        Origin = "detected: axis", Description = $"{what} breakpoints of {m.Item.Name}",
                    }, improves: true);

        // 2. labelled data blocks in the source
        foreach (var (_, text) in src)
        {
            var lines = text.Split('\n');
            for (int i = 0; i < lines.Length; i++)
            {
                var mt = LabelData.Match(StripComment(lines[i]));
                if (!mt.Success) continue;
                string name = mt.Groups[1].Value;
                if (name.EndsWith("_vec", StringComparison.OrdinalIgnoreCase) || name == "code_start") continue;
                if (!asm.Symbols.TryGetValue(name, out var sym)) continue;
                bool word = mt.Groups[2].Value.Equals("DW", StringComparison.OrdinalIgnoreCase);
                var elems = Split(mt.Groups[3].Value);
                for (int j = i + 1; j < lines.Length; j++)
                {
                    var mm = MoreData.Match(StripComment(lines[j]));
                    if (!mm.Success || mm.Groups[1].Value.Equals("DW", StringComparison.OrdinalIgnoreCase) != word) break;
                    elems.AddRange(Split(mm.Groups[2].Value));
                }
                if (elems.Count == 0 || elems.Any(e => !IsNumber(e))) continue;     // label tables, strings
                int addr = (int)sym.Value;
                if (addr < 0x38 || defs.Items.Any(x => x.Contains(addr))) continue;
                Put(Guess(name, addr, word, elems.Count));
            }
        }

        // 3. tables the code reads with LC/LCB (covers disassembled images with no data labels)
        var targets = new SortedDictionary<int, bool>();
        foreach (var e in asm.SourceMap)
        {
            var d = Decoder.Decode(true, k => rom[(e.Address + k) & 0x7FFF]);
            if (d == null) continue;
            var op = d.Mnemonic.Split(' ')[0];
            if (op is not ("LC" or "LCB") || !d.Mnemonic.Contains("N16")) continue;
            int t = d.Fields.N16;
            if (t < 0x38 || t >= Bus.RomSize || IsCode(t)) continue;
            targets[t] = op == "LC";
        }
        var keys = targets.Keys.ToList();
        for (int k = 0; k < keys.Count; k++)
        {
            int a = keys[k];
            if (defs.Items.Any(x => x.Contains(a))) continue;
            int next = k + 1 < keys.Count ? keys[k + 1] : a + 16;
            bool word = targets[a];
            int count = Math.Clamp((next - a) / (word ? 2 : 1), 1, 32);
            string name = asm.Symbols.Values.FirstOrDefault(s => s.Value == a && s.Kind == SymbolKind.Label)?.Name ?? $"tbl_{a:X4}";
            Put(Guess(name, a, word, count, "detected: read by LC/LCB"));
        }

        // 4. switches
        int flags = TableDetector.MarkFlags(defs.Items, rom);
        return new DetectResult(added, replaced, maps.Count, flags, names);
    }

    static string StripComment(string line)
    {
        int c = line.IndexOf(';');
        return (c >= 0 ? line[..c] : line).TrimEnd('\r');
    }

    static List<string> Split(string s) =>
        [.. s.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)];

    static bool IsNumber(string s) =>
        Regex.IsMatch(s, @"^(0[0-9A-Fa-f]*[hH]|[0-9][0-9A-Fa-f]*[hH]|[0-9]+|0x[0-9A-Fa-f]+|\$[0-9A-Fa-f]+)$");

    /// A first guess at what a table is from its name: category and formula.
    public static ItemDef Guess(string name, int addr, bool word, int count, string origin = "detected")
    {
        string n = name.ToLowerInvariant();
        string formula = "raw", category = "Detected";
        if (n.Contains("rpm")) { category = "RPM"; if (word) formula = "rpm_period_word"; }
        else if (n.Contains("ign") || n.Contains("timing")) { category = "Ignition"; if (!word) formula = "ign_advance"; }
        else if (n.Contains("fuel") || n.Contains("inj") || n.Contains("dead")) category = "Fuel";
        else if (n.Contains("map") && !word) { category = "Load"; formula = "map_kpa"; }
        else if (n.Contains("tps")) { category = "Throttle"; if (!word) formula = "percent255"; }
        else if (n.Contains("vtec")) category = "VTEC";
        else if (n.Contains("idle") || n.Contains("iac")) category = "Idle";
        else if (n.Contains("bst") || n.Contains("boost")) category = "Boost";
        else if (n.Contains("cut") || n.Contains("limit")) category = "Limits";
        return new ItemDef
        {
            Name = name, Address = addr, Type = word ? CellType.U16 : CellType.U8,
            Rows = count > 1 ? 1 : 0, Cols = count > 1 ? count : 0,
            Formula = formula, Category = category, Origin = origin,
            Description = count > 1 ? $"{count} {(word ? "words" : "bytes")}" : "",
        };
    }
}
