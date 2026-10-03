// Copyright (c) bmgjet. All rights reserved.
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Core;

namespace OkiRomSim.Calibration;

public sealed record DetectResult(int Added, int Replaced, int Maps, int Switches, List<string> Names)
{
    /// How many came from known ROMs of the same family (named, sized and scaled as there).
    public int FromReferences { get; init; }
    public string Summary => Added + Replaced == 0 && Switches == 0 ? "nothing new found"
        : $"{Added} added, {Replaced} improved, {FromReferences} named from known ROMs, {Maps} maps from the lookup code, {Switches} switches";
}

/// Finds calibration data in an assembled ROM and adds it to a definition set: maps from the 2D lookup set-up code (with RPM and load axes), labelled DB/DW blocks, tables read with LC/LCB, and on/off switches. Hand-made and imported definitions are never replaced; an earlier rough guess is improved when something better is found at the same address. Shared by the Calibration page and the MCP server.
public static class CalibrationDetector
{
    static readonly Regex LabelData = new(@"^\s*([A-Za-z_][\w]*)\s*:\s*(DB|DW)\b\s*(.*)$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    static readonly Regex MoreData = new(@"^\s+(DB|DW)\b\s*(.*)$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    static readonly Regex DataLine = new(@"^\s*([A-Za-z_][\w]*\s*:)?\s*(DB|DW)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// An address a definition already accounts for: one of its cells, or one of its axis values (an (input, value) pair table's values start a byte after its label, its inputs sit at the label itself).
    static bool Covered(DefinitionSet defs, int a) =>
        defs.Items.Any(x => x.Contains(a) || AxisCovers(x.ColAxis, a) || AxisCovers(x.RowAxis, a));
    static bool AxisCovers(AxisDef? axis, int a) =>
        axis?.Address is int s && a >= s && a < s + Math.Max(1, axis.Count) * (axis.Stride > 0 ? axis.Stride : axis.Type is CellType.U8 or CellType.S8 ? 1 : 2);

    /// `references`: ROMs whose tables are known (<see cref="RomReference.Shipped"/>); their tables are found in this one by lining the two programs up, before anything is guessed. Null: none (a reference being loaded).
    public static DetectResult Detect(DefinitionSet defs, AssemblyResult asm, byte[] rom, IEnumerable<(string Path, string Text)> sources,
                                      IEnumerable<RomReference>? references = null)
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
                bool reshaped = same.Rows != item.Rows || same.Stride != item.Stride;
                same.Rows = item.Rows; same.Cols = item.Cols; same.Stride = item.Stride;
                // the multiplier row follows the last row: when the rows moved (a 20-column map found where the reference has 10), so does it
                if (item.ColumnScaleAddress != null) same.ColumnScaleAddress = item.ColumnScaleAddress;
                else if (same.ColumnScaleAddress != null && reshaped) same.ColumnScaleAddress = same.Address + (same.Rows * (same.Stride > 0 ? same.Stride : same.Cols));
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

        // 000. an HTS-family ROM: the scaling HTS-master gives each field, for the definitions that have none; and headers for the per-gear and per-cylinder lists
        HtsLayout.ScaleFromLayout(defs, rom);
        DefinitionBuilder.IndexAxes(defs);

        // 00. the watermark and the open password (the watermark module): found by the password block's marker, with the watermark just before it when its check word matches - so a ROM with no labels still asks for its password and shows its watermark
        if (RomPassword.Find(rom) is int pwAt and >= 0 && !defs.Items.Any(i => i.Text == "password"))
        {
            Put(new ItemDef
            {
                Name = "RomPassword", Address = pwAt, Type = CellType.U8, Rows = 1, Cols = RomPassword.Bytes, Text = "password",
                Category = "Watermark", Slot = "watermark.password", Origin = "detected: password block",
                Description = "The open password: Rom Sim Studio asks for it before opening this ROM (a salted hash, not the password itself).",
            });
            int wmAt = pwAt - WatermarkCodec.Bytes;
            if (wmAt >= 0 && WatermarkCodec.Decode(rom.AsSpan(wmAt, WatermarkCodec.Bytes)).Intact && !defs.Items.Any(i => i.Text == "watermark"))
                Put(new ItemDef
                {
                    Name = "Watermark", Address = wmAt, Type = CellType.U8, Rows = 1, Cols = WatermarkCodec.Bytes, Text = "watermark",
                    Category = "Watermark", Slot = "watermark.text", Origin = "detected: watermark",
                    Description = "Up to 16 characters, stored scrambled with a check word.",
                });
        }

        // 0. the tables of known ROMs of the same family, where this ROM's code uses them the same way: the reference whose code lines up best goes first, so its names win where two would place something at one address
        int fromRefs = 0;
        var lines = texts.ToDictionary(kv => kv.Key, kv => kv.Value.Select(l => l.TrimEnd((char)13)).ToArray(), StringComparer.OrdinalIgnoreCase);
        // what this ROM's RAM input bytes are (for the input axes of its tables): from its own defined tables, else from the references, the best-matched first
        var inputs = TableShapes.LearnInputs(asm, lines, defs.Items, n => { try { return defs.Formula(n); } catch { return null; } });
        if (references != null)
        {
            var found = references.Select(r =>
            {
                try { var items = ReferenceMatcher.Place(r, asm, lines, IsCode, out int lined, out var ins); return (Ref: r, Items: items, Lined: lined, Inputs: ins); }
                catch { return (Ref: r, Items: new List<ItemDef>(), Lined: 0, Inputs: new Dictionary<int, FormulaDef>()); }
            }).ToList();
            foreach (var f in found.OrderByDescending(f => f.Lined))
                foreach (var (ram, formula) in f.Inputs) inputs.TryAdd(ram, formula);
            // one table per address: a real name before a made-up one, a defined (annotated) reference before a labelled one, then the reference whose code lines up best with this ROM's
            bool hts = HtsLayout.Version(rom) != 0;
            var best = found.SelectMany(f => f.Items.Select(i => (f.Ref, f.Lined, Item: i)))
                .GroupBy(x => x.Item.Address)
                .Select(g => g.OrderByDescending(x => x.Ref.Hts == hts)
                              .ThenByDescending(x => RomReference.Meaningful(x.Item.Name) && !x.Item.Name.StartsWith("tbl_", StringComparison.OrdinalIgnoreCase))
                              .ThenByDescending(x => x.Ref.Annotated).ThenByDescending(x => x.Lined).First())
                .OrderBy(x => x.Item.Address).ToList();
            // the formulas the placed tables (and their axes) use come with them
            void Carry(string? formula, RomReference from)
            {
                if (formula == null || defs.Formulas.Any(f => f.Name.Equals(formula, StringComparison.OrdinalIgnoreCase))) return;
                if (from.Formulas.TryGetValue(formula, out var fd)) defs.Formulas.Add(fd);
            }
            foreach (var (from, _, it) in best) { Carry(it.Formula, from); Carry(it.RowAxis?.Formula, from); Carry(it.ColAxis?.Formula, from); }
            var taken = new HashSet<string>(defs.Items.Select(i => i.Name), StringComparer.OrdinalIgnoreCase);
            foreach (var item in best.Select(x => x.Item))
            {
                if (defs.Items.Any(i => i.Address == item.Address && i.Origin?.StartsWith("detected") != true)) continue;
                if (!taken.Add(item.Name)) continue;            // a name already given to another table
                int before = added + replaced;
                Put(item, improves: true);
                if (added + replaced > before) fromRefs++;
            }
        }

        // 1. maps from the 2D lookup set-up code, with their axes
        var symbols = asm.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).GroupBy(s => s.Name).ToDictionary(g => g.Key, g => (int)g.First().Value);
        var maps = TableDetector.Detect(src.Select(s => s.Text), symbols, rom, IsCode);
        foreach (var m in maps) Put(m.Item);
        // the lookup code is the authority on where the maps are: a map a reference placed elsewhere under the same name as one found here (its code differs from this ROM's) is dropped
        foreach (var m in maps)
        {
            var here = defs.Items.FirstOrDefault(i => i.Address == m.Item.Address);
            if (here == null) continue;
            defs.Items.RemoveAll(i => i != here && i.IsTable && i.Rows > 1 && i.Name.Equals(here.Name, StringComparison.OrdinalIgnoreCase)
                                      && i.Origin?.StartsWith("detected: like") == true && !maps.Any(x => x.Item.Address == i.Address));
        }
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
            var srcLines = text.Split('\n');
            for (int i = 0; i < srcLines.Length; i++)
            {
                var mt = LabelData.Match(StripComment(srcLines[i]));
                if (!mt.Success) continue;
                string name = mt.Groups[1].Value;
                if (name.EndsWith("_vec", StringComparison.OrdinalIgnoreCase) || name == "code_start") continue;
                if (!asm.Symbols.TryGetValue(name, out var sym)) continue;
                bool word = mt.Groups[2].Value.Equals("DW", StringComparison.OrdinalIgnoreCase);
                var elems = Split(mt.Groups[3].Value);
                for (int j = i + 1; j < srcLines.Length; j++)
                {
                    var mm = MoreData.Match(StripComment(srcLines[j]));
                    if (!mm.Success || mm.Groups[1].Value.Equals("DW", StringComparison.OrdinalIgnoreCase) != word) break;
                    elems.AddRange(Split(mm.Groups[2].Value));
                }
                if (elems.Count == 0 || elems.Any(e => !IsNumber(e))) continue;     // label tables, strings
                int addr = (int)sym.Value;
                if (addr < 0x38 || Covered(defs, addr)) continue;
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
            if (Covered(defs, a)) continue;
            int next = k + 1 < keys.Count ? keys[k + 1] : a + 16;
            bool word = targets[a];
            int count = Math.Clamp((next - a) / (word ? 2 : 1), 1, 32);
            string name = asm.Symbols.Values.FirstOrDefault(s => s.Value == a && s.Kind == SymbolKind.Label)?.Name ?? $"tbl_{a:X4}";
            Put(Guess(name, a, word, count, "detected: read by LC/LCB"));
        }

        // 5. tables read through a table routine: a block known only as "N bytes" becomes the tables it holds, each (input, value) list to its input 0, named after the block (Name, Name2...), the input scaled as its RAM byte is
        int shaped = 0;
        bool dbg = Environment.GetEnvironmentVariable("OKI_DEBUG_SHAPES") == "1";
        foreach (var sh in TableShapes.Find(asm, lines, rom, IsCode))
        {
            if (dbg) Console.WriteLine($"shape {sh.AxisAddress:X4} n={sh.Count} stride={sh.Reader.Stride} ram={sh.InputRam:X} covered={string.Join(",", defs.Items.Where(i => i.Contains(sh.AxisAddress) || i.Contains(sh.AxisAddress + 1)).Select(i => i.Name + "/" + i.Origin))}");
            // something that already says what is there (annotated, made by hand, or from a reference) stays (two tables may share bytes: one's last entry the other's first)
            if (defs.Items.Any(i => i.ColStride > 0 && i.ColAxis?.Address == sh.AxisAddress)) continue;
            if (defs.Items.Any(i => i.Origin?.StartsWith("detected") != true && i.Contains(sh.AxisAddress))) continue;
            var blob = defs.Items.FirstOrDefault(i => i.Origin?.StartsWith("detected") == true && i.ColStride == 0 && i.Rows <= 1 && i.Contains(sh.AxisAddress));
            int start = blob?.Address ?? sh.AxisAddress;
            int end = blob != null ? blob.Address + Math.Max(1, blob.Span) : sh.AxisAddress + sh.Count * sh.Reader.Stride;
            var run = TableShapes.Run(rom, start, end, sh.Reader, IsCode);
            if (!run.Any(t => t.Axis == sh.AxisAddress))
            {
                run = TableShapes.Run(rom, sh.AxisAddress, Math.Max(end, sh.AxisAddress + sh.Count * sh.Reader.Stride), sh.Reader, IsCode);
                if (run.Count == 0) continue;
            }
            string baseName = blob != null && blob.Address == run[0].Axis ? blob.Name
                : asm.Symbols.Values.FirstOrDefault(x => x.Value == run[0].Axis && x.Kind == SymbolKind.Label)?.Name ?? $"tbl_{run[0].Axis:X4}";
            string? formula = null;
            if (sh.InputRam is int ram && inputs.TryGetValue(ram, out var fm))
            {
                // a formula only the reference had (an inline one) comes with it
                if (!defs.Formulas.Any(x => x.Name.Equals(fm.Name, StringComparison.OrdinalIgnoreCase))) defs.Formulas.Add(fm);
                formula = fm.Name;
            }
            string category = blob != null && blob.Category is not ("Detected" or "General") ? blob.Category : Category(formula);
            if (blob != null)
            {
                if (blob.Address < run[0].Axis) { blob.Rows = 1; blob.Cols = run[0].Axis - blob.Address; }   // the bytes before the first table stay as they were
                else defs.Items.Remove(blob);
            }
            for (int k = 0; k < run.Count; k++)
            {
                var (axis, count) = run[k];
                string name = k == 0 ? baseName : baseName + (k + 1);
                for (int n = 2; defs.Items.Any(i => i.Name.Equals(name, StringComparison.OrdinalIgnoreCase)); n++) name = (k == 0 ? baseName : baseName + (k + 1)) + "_" + n;
                var item = TableShapes.Define(name, axis, count, sh.Reader, formula, category, "detected: table routine");
                if (sh.InputRam is int r2) item.Description += $" Input: RAM {r2:X2}h" + (formula != null ? $" ({formula})." : ".");
                defs.Items.Add(item); added++; shaped++; names.Add(name);
            }
        }

        // 6. what is left as "N bytes" but read with LC / LCB: each read is a setting of the width it is read at (a block read by index stays one array, of words if it is read as words)
        var reads = new Dictionary<int, (bool Word, bool Indexed)>();
        foreach (var e in asm.SourceMap)
        {
            var d = Decoder.Decode(true, k => rom[(e.Address + k) & 0x7FFF]);
            if (d == null || !d.Mnemonic.Contains("N16")) continue;
            var op = d.Mnemonic.Split(' ')[0];
            if (op is not ("LC" or "LCB")) continue;
            int t = d.Fields.N16;
            bool idx = d.Mnemonic.Contains('[');
            reads[t] = reads.TryGetValue(t, out var was) ? (was.Word || op == "LC", was.Indexed || idx) : (op == "LC", idx);
        }
        foreach (var (a, (word, indexed)) in TableShapes.IndirectReads(asm, lines))
            reads[a] = reads.TryGetValue(a, out var was) ? (was.Word || word, was.Indexed || indexed) : (word, indexed);
        foreach (var blob in defs.Items.Where(i => i.Origin is "detected" or "detected: read by LC/LCB" && i.ColStride == 0 && i.Rows <= 1 && i.Cols > 1).ToList())
        {
            var rs = reads.Where(kv => kv.Key >= blob.Address && kv.Key < blob.Address + blob.Span).OrderBy(kv => kv.Key).ToList();
            if (rs.Count == 0) continue;
            if (rs.Any(r => r.Value.Indexed))
            {
                if (rs.All(r => r.Value.Word) && blob.Type == CellType.U8) { blob.Type = CellType.U16; blob.Cols = Math.Max(1, blob.Cols / 2); }
                // an array: its cells numbered by the index the code reads it with
                blob.Description = $"{blob.Cols} {(blob.Type == CellType.U16 ? "words" : "bytes")}, read by index (0-{blob.Cols - 1})";
                blob.ColAxis ??= new AxisDef { Name = "Index", Count = blob.Cols, Values = [.. Enumerable.Range(0, blob.Cols).Select(x => (double)x)] };
                continue;
            }
            defs.Items.Remove(blob);
            foreach (var (a, (word, _)) in rs)
            {
                string name = a == blob.Address ? blob.Name : $"{blob.Name}_{a - blob.Address}";
                for (int n = 2; defs.Items.Any(i => i.Name.Equals(name, StringComparison.OrdinalIgnoreCase)); n++) name = $"{blob.Name}_{a - blob.Address}_{n}";
                defs.Items.Add(new ItemDef
                {
                    Name = name, Address = a, Type = word ? CellType.U16 : CellType.U8, Formula = "raw", Category = blob.Category,
                    Origin = "detected: read by LC/LCB", Description = $"read as a {(word ? "word" : "byte")} by the code",
                });
            }
        }

        // 4. switches
        int flags = TableDetector.MarkFlags(defs.Items, rom);
        return new DetectResult(added, replaced, maps.Count, flags, names) { FromReferences = fromRefs };
    }

    /// The tables split out of one block (Name, Name2, Name3...) are the same kind of thing: where the first has a value scaling (from a page layout, a reference) and the others do not, they take it.
    public static int ShareScaling(DefinitionSet defs)
    {
        int n = 0;
        // a detected table that a page's own definition (bound to a row) already covers for the most part is the same bytes twice
        foreach (var d in defs.Items.Where(i => i.Origin?.StartsWith("detected") == true && i.Slot == null && i.Span > 1).ToList())
        {
            int span = d.Span;
            bool dup = defs.Items.Any(o => o != d && o.Slot != null && o.Span > 1 &&
                Math.Min(d.Address + span, o.Address + o.Span) - Math.Max(d.Address, o.Address) >= (span + 1) / 2);
            if (dup) { defs.Items.Remove(d); n++; }
        }
        foreach (var i in defs.Items.Where(i => i.Origin == "detected: table routine" && (i.Formula ?? "raw") == "raw"))
        {
            var m = Regex.Match(i.Name, @"^(.*?)(\d+)$");
            if (!m.Success) continue;
            var first = defs.Find(m.Groups[1].Value);
            if (first == null || (first.Formula ?? "raw") == "raw" || first.Type != i.Type || first.ColStride != i.ColStride) continue;
            i.Formula = first.Formula; n++;
        }
        return n;
    }

    /// A category for a table from what its input is.
    static string Category(string? inputFormula) => inputFormula switch
    {
        null => "Detected",
        var f when f.Contains("temp") => "Temperature corrections",
        var f when f.Contains("rpm") => "RPM corrections",
        var f when f.Contains("tps") => "Throttle",
        var f when f.Contains("mbar") || f.Contains("map") || f.Contains("3.6105") => "Load corrections",
        var f when f.Contains("batt") => "Battery",
        var f when f.Contains("kmh") || f.Contains("speed") => "Road speed",
        _ => "Detected",
    };

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
