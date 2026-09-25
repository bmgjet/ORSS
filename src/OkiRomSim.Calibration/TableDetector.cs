// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Text.RegularExpressions;

namespace OkiRomSim.Calibration;

/// Finds calibration data by reading the code that uses it, so it works on any source for these ECUs (hand-written, commented or freshly disassembled) without fixed addresses. 2D maps: Honda code sets up the interpolating lookup the same way everywhere: MOVB r0, #stride ; bytes per row MOVB r1, #rows MOVB r2, <column index RAM> MOVB r3, <row index RAM> MOV X1, #map ; possibly several alternatives under flag tests SB/RB PSWL.5 ; set = the map has a per-column multiplier row after it (fuel) CAL lookup The row/column index RAM bytes are written by an axis search a little earlier: MOV X1, #axis ... CAL search ... LB A, r6 / STB A, <index RAM> so following that store back gives each map its RPM and load axes.
public static class TableDetector
{
    public sealed record Found(ItemDef Item, string Why);

    static readonly Regex Label = new(@"^\s*[A-Za-z_][\w]*\s*:\s*", RegexOptions.Compiled);

    /// One instruction line with its label and comment removed, upper-cased operands kept.
    readonly record struct Line(int Index, string Label, string Op, string Args);

    static List<Line> Parse(string text)
    {
        var result = new List<Line>();
        var lines = text.Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            var s = lines[i];
            int c = s.IndexOf(';');
            if (c >= 0) s = s[..c];
            s = s.TrimEnd('\r');
            string label = "";
            var m = Label.Match(s);
            if (m.Success)
            {
                label = m.Value.Trim().TrimEnd(':').Trim();
                s = s[m.Length..];
            }
            s = s.Trim();
            if (s.Length == 0) { if (label.Length > 0) result.Add(new Line(i, label, "", "")); continue; }
            int sp = s.IndexOfAny(new[] { ' ', '\t' });
            string op = (sp < 0 ? s : s[..sp]).ToUpperInvariant();
            string args = sp < 0 ? "" : Regex.Replace(s[sp..].Trim(), @"\s+", " ");
            result.Add(new Line(i, label, op, args));
        }
        return result;
    }

    static bool TryNumber(string s, out int v)
    {
        s = s.Trim().TrimStart('#');
        v = 0;
        if (s.EndsWith("h", StringComparison.OrdinalIgnoreCase))
            return int.TryParse(s[..^1], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v);
        return s.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
            ? int.TryParse(s[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v)
            : int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out v);
    }

    /// The RAM byte an operand names, the same whichever way the source writes it. Hand-written sources give absolute addresses - off(001dfh), (001dfh-00180h)[USP]; a fresh disassembly gives the short encodings - off(0DFh), 95[USP] - which are resolved with the bases the Honda main loop runs with (off page 0100h, USP 0180h).
    const int OffPage = 0x100, UspBase = 0x180;
    static int? Ram(string operand)
    {
        operand = operand.Trim();
        var m = Regex.Match(operand, @"^off\(\s*([0-9A-Fa-f]+h)\s*\)$", RegexOptions.IgnoreCase);
        if (m.Success && TryNumber(m.Groups[1].Value, out var a)) return a >= 0x100 ? a : OffPage | a;
        m = Regex.Match(operand, @"^\(\s*([0-9A-Fa-f]+h)\s*-\s*[0-9A-Fa-f]+h\s*\)\s*\[USP\]$", RegexOptions.IgnoreCase);
        if (m.Success && TryNumber(m.Groups[1].Value, out a)) return a;
        m = Regex.Match(operand, @"^(-?)([0-9]+|[0-9][0-9A-Fa-f]*h)\s*\[USP\]$", RegexOptions.IgnoreCase);
        if (m.Success && TryNumber(m.Groups[2].Value, out a)) return UspBase + (m.Groups[1].Value == "-" ? -a : a);
        return Regex.IsMatch(operand, @"^[0-9][0-9A-Fa-f]*h$", RegexOptions.IgnoreCase) && TryNumber(operand, out a) ? a : null;
    }

    static (string Dst, string Src) Two(string args)
    {
        int c = args.IndexOf(',');
        return c < 0 ? (args.Trim(), "") : (args[..c].Trim(), args[(c + 1)..].Trim());
    }

    /// `word` starts a word of the name: "ign" matches IGN1_Lo, IgnMap, ignmap_2d but not map_sign.
    static bool Hint(string name, string word) =>
        Regex.IsMatch(name, $@"(^|[_\W\d]){word}", RegexOptions.IgnoreCase) ||
        Regex.IsMatch(name, $@"[a-z]{char.ToUpperInvariant(word[0])}{word[1..]}");

    public static List<Found> Detect(IEnumerable<string> sources, IReadOnlyDictionary<string, int> symbols,
                                     byte[] rom, Func<int, bool> isCode)
    {
        var found = new List<Found>();
        var parsed = sources.Select(Parse).ToList();
        // a label, or (in a freshly disassembled image, where data has no labels) a hex number
        int Sym(string name)
        {
            if (symbols.TryGetValue(name, out var a)) return a;
            var ci = symbols.FirstOrDefault(kv => string.Equals(kv.Key, name, StringComparison.OrdinalIgnoreCase));
            return ci.Key != null
                ? ci.Value
                : Regex.IsMatch(name, @"^[0-9][0-9A-Fa-f]*h$|^0x[0-9A-Fa-f]+$", RegexOptions.IgnoreCase) && TryNumber(name, out var n) ? n : -1;
        }

        // ---- 1. which axis table feeds each index RAM byte
        var axisOf = new Dictionary<int, List<string>>();          // index RAM -> axis labels, in code order
        foreach (var lines in parsed)
        {
            var candidates = new List<(string label, int at)>();
            int lastCal = -100, lastR6 = -100, lastR6Count = -100;
            for (int k = 0; k < lines.Count; k++)
            {
                var l = lines[k];
                if (l.Op == "MOV")
                {
                    var (d, s) = Two(l.Args);
                    if ((d.Equals("X1", StringComparison.OrdinalIgnoreCase) || d.Equals("DP", StringComparison.OrdinalIgnoreCase)) &&
                        s.StartsWith('#') && Sym(s[1..]) is int a && a >= 0x38 && !isCode(a))
                    {
                        if (candidates.Count > 0 && k - candidates[^1].at > 12) candidates.Clear();
                        candidates.Add((s[1..], k));
                    }
                }
                else if (l.Op == "CAL") lastCal = k;
                else if (l.Op == "LB" && Regex.IsMatch(l.Args, @"^A\s*,\s*r6$", RegexOptions.IgnoreCase)) lastR6 = k;
                else if (l.Op == "MOVB" && Regex.IsMatch(l.Args, @"^r6\s*,\s*#", RegexOptions.IgnoreCase)) lastR6Count = k;
                // a byte-axis search: MOV X1,#axis / MOVB r6,#count / CAL / ... / LB A,r6 / STB A,<index>
                else if (l.Op == "STB" && k - lastR6 <= 2 && k - lastCal <= 8 && candidates.Count > 0 && k - candidates[^1].at <= 14 &&
                         lastR6Count > candidates[^1].at - 4 && lastR6Count < lastCal)
                {
                    var (_, dst) = Two(l.Args);
                    if (Ram(dst) is int ram && !axisOf.ContainsKey(ram))
                        axisOf[ram] = [.. candidates.Select(c => c.label)];
                    candidates.Clear();
                }
            }
        }

        // ---- 2. the 2D lookups
        var maps = new Dictionary<int, Found>();
        var rowRamOf = new Dictionary<int, int>();
        foreach (var lines in parsed)
        {
            int start = -1, stride = 0, rows = 0, rowRam = -1, colRam = -1;
            bool scaleRow = false;
            var names = new List<string>();
            var tables = new List<(string label, int rows, int rowRam, int colRam)>();
            for (int k = 0; k < lines.Count; k++)
            {
                var l = lines[k];
                if (l.Label.Length > 0 && start >= 0) names.Add(l.Label);
                if (l.Op == "MOVB")
                {
                    var (d, s) = Two(l.Args);
                    if (d.Equals("r0", StringComparison.OrdinalIgnoreCase) && s.StartsWith('#') && TryNumber(s, out var n))
                    {
                        start = k; stride = n; rows = 0; rowRam = colRam = -1; scaleRow = false; tables.Clear(); names.Clear();
                        if (l.Label.Length > 0) names.Add(l.Label);
                        for (int b = k - 1; b >= 0 && b >= k - 6; b--) if (lines[b].Label.Length > 0) names.Add(lines[b].Label);
                        continue;
                    }
                    if (start < 0) continue;
                    if (d.Equals("r1", StringComparison.OrdinalIgnoreCase) && TryNumber(s, out n)) rows = n;
                    else if (d.Equals("r2", StringComparison.OrdinalIgnoreCase)) colRam = Ram(s) ?? colRam;
                    else if (d.Equals("r3", StringComparison.OrdinalIgnoreCase)) rowRam = Ram(s) ?? rowRam;
                }
                if (start < 0) continue;
                if (k - start > 60) { start = -1; continue; }
                if (l.Op == "MOV")
                {
                    var (d, s) = Two(l.Args);
                    if (d.Equals("X1", StringComparison.OrdinalIgnoreCase) && s.StartsWith('#')) tables.Add((s[1..], rows, rowRam, colRam));
                }
                else if (l.Op is "SB" or "RB" && l.Args.Replace(" ", "").Equals("PSWL.5", StringComparison.OrdinalIgnoreCase))
                    scaleRow = l.Op == "SB";
                else if (l.Op == "CAL")
                {
                    if (l.Label.Length > 0) names.Add(l.Label);
                    string context = string.Join(" ", names);
                    if (stride is >= 4 and <= 32)
                        foreach (var (t, tRows, tRowRam, tColRam) in tables.Distinct())
                        {
                            int addr = Sym(t);
                            if (addr < 0x38 || isCode(addr) || tRows is < 2 or > 64 || addr + (tRows * stride) > rom.Length || tRowRam < 0) continue;
                            if (maps.ContainsKey(addr)) continue;
                            int index = tables.Where(x => x.rowRam == tRowRam).Select(x => x.label).Distinct().ToList().IndexOf(t);
                            string tname = Regex.IsMatch(t, @"^[0-9]") ? $"map_{addr:X4}" : t;
                            rowRamOf[addr] = tRowRam;
                            maps[addr] = MakeMap(tname, addr, stride, tRows, scaleRow, context,
                                PickAxis(axisOf, tRowRam, index), PickAxis(axisOf, tColRam, index), Sym, rom);
                        }
                    start = -1;
                }
            }
        }
        // maps that share a column axis have the same width: padding at the end of a row shows up in all of them, a column that merely repeats its neighbour in one map does not
        foreach (var g in maps.Values.Where(m => m.Item.ColAxis?.Address != null).GroupBy(m => m.Item.ColAxis!.Address!.Value))
        {
            int widest = g.Max(m => m.Item.Cols);
            foreach (var m in g)
            {
                int room = m.Item.Stride > 0 ? m.Item.Stride : widest;
                m.Item.Cols = Math.Min(widest, room);
                m.Item.ColAxis?.Count = m.Item.Cols;
            }
        }
        Structural(maps, rowRamOf);
        found.AddRange(maps.Values);
        return found;
    }

    /// For maps with no telling names (a raw disassembly): the higher of the two most used row-index RAM bytes belongs to the high-cam RPM search (so linear scaling), and a map without a multiplier row that shares the fuel maps' RPM axes is an ignition map.
    static void Structural(Dictionary<int, Found> maps, Dictionary<int, int> rowRamOf)
    {
        bool Generic(ItemDef i) => i.Name.StartsWith("map_") && (i.RowAxis?.Name?.StartsWith("rpm_axis_") ?? true);
        var top = rowRamOf.Values.GroupBy(r => r).OrderByDescending(g => g.Count()).Take(2).Select(g => g.Key).ToList();
        int? hiRam = top.Count == 2 ? top.Max() : null;
        var fuelAxes = maps.Values.Where(m => m.Item.ColumnScaleAddress != null && m.Item.RowAxis?.Address != null)
                                  .Select(m => m.Item.RowAxis!.Address!.Value).ToHashSet();
        foreach (var (addr, f) in maps)
        {
            var i = f.Item;
            if (!Generic(i)) continue;
            if (i.RowAxis != null && hiRam != null && rowRamOf.TryGetValue(addr, out var rr))
            {
                bool hi = rr == hiRam;
                i.RowAxis.Formula = hi ? "rpm_axis_byte" : "rpm_axis_byte_log";
                i.Description = i.Description.Replace(hi ? "low-cam rpm" : "high-cam rpm", hi ? "high-cam rpm" : "low-cam rpm");
            }
            if (i.ColumnScaleAddress == null && i.Category == "Maps" && i.RowAxis?.Address is int ra && fuelAxes.Contains(ra))
            {
                i.Category = "Ignition"; i.Formula = "ign_advance";
            }
        }
    }

    static string? PickAxis(Dictionary<int, List<string>> axisOf, int ram, int index)
    {
        return ram < 0 || !axisOf.TryGetValue(ram, out var list) || list.Count == 0 ? null : list[Math.Clamp(index, 0, list.Count - 1)];
    }

    static Found MakeMap(string label, int addr, int stride, int rows, bool scaleRow, string context,
                         string? rowAxis, string? colAxis, Func<string, int> sym, byte[] rom)
    {
        // columns: as many as the load axis rises (the rest of each row is padding), else the stride
        int cols = stride;
        if (colAxis != null && sym(colAxis) is int ca && ca > 0)
        {
            int n = 1;
            int prev = rom[ca];
            for (int i = 1; i < stride && ca + i < rom.Length; i++)
            {
                if (rom[ca + i] == 0xFF) break;          // FF fills the unused end of a scaler table
                int v = rom[ca + i] == 0 ? 256 : rom[ca + i];
                if (v <= prev) break;
                prev = v; n++;
            }
            if (n >= 4) cols = n;
        }
        // Rows are `stride` bytes wide but only the first columns are map data: the tail of every row is padding that repeats one value (other tools keep the real count in a byte of its own; here it comes from the data, so it works on any ROM). Walk in while the last column is identical to the one before it in every row.
        bool SameColumn(int c)          // column c identical to column c-1 down every row
        {
            for (int r = 0; r < rows; r++)
            {
                int b = addr + (r * stride) + c;
                if (b >= rom.Length || b - 1 < 0 || rom[b] != rom[b - 1]) return false;
            }
            return true;
        }
        int first = cols - 1;
        while (first > 4 && SameColumn(first)) first--;
        if (cols - first >= 3) cols = first;      // one repeated column can be real data; a run of them is padding
        bool ign = Hint(label, "ign") || Hint(label, "timing") || (!scaleRow && Hint(context, "ign"));
        bool hi = Hint(label, "hi") || rowAxis != null && Hint(rowAxis, "hi");
        string kind = scaleRow ? "Fuel" : ign ? "Ignition" : Hint(label, "ve") ? "VE" : "Maps";
        var item = new ItemDef
        {
            Name = label, Address = addr, Type = CellType.U8, Rows = rows, Cols = cols, Stride = stride,
            Formula = scaleRow ? "honda_fuel" : ign ? "ign_advance" : kind == "VE" ? "ve_percent" : "raw",
            Category = kind,
            ColumnScaleAddress = scaleRow ? addr + (rows * stride) : null,
            Origin = "detected: 2D lookup",
            Description = $"{rows} x {cols} map ({stride} bytes per row){(scaleRow ? ", column multipliers after the last row" : "")}; " +
                          $"rows: {(hi ? "high" : "low")}-cam rpm{(rowAxis != null ? " (" + rowAxis + ")" : "")}, columns: load{(colAxis != null ? " (" + colAxis + ")" : "")}",
            RowAxis = rowAxis == null ? null : new AxisDef
            {
                Name = Regex.IsMatch(rowAxis, @"^[0-9]") ? $"rpm_axis_{sym(rowAxis):X4}" : rowAxis, Address = sym(rowAxis), Count = rows, Unit = "rpm",
                Formula = hi ? "rpm_axis_byte" : "rpm_axis_byte_log",
            },
            ColAxis = colAxis == null ? null : new AxisDef
            {
                Name = Regex.IsMatch(colAxis, @"^[0-9]") ? $"load_axis_{sym(colAxis):X4}" : colAxis, Address = sym(colAxis), Count = cols, Unit = "mbar", Formula = "map_mbar",
            },
        };
        return new Found(item, "2D lookup");
    }

    static readonly Regex FlagName = new(@"(enable|chk|check|invert|disable|flag|onoff|use[A-Z_]|^use|mode$|select$)", RegexOptions.IgnoreCase);

    /// Mark single-byte settings that look like switches (by name, holding 00/01/FF) as flags.
    public static int MarkFlags(IEnumerable<ItemDef> items, byte[] rom)
    {
        int n = 0;
        foreach (var i in items)
        {
            if (i.IsTable || i.Type != CellType.U8 || i.Flag || i.Address >= rom.Length) continue;
            byte v = rom[i.Address];
            if (v is not (0 or 1 or 0xFF) || !FlagName.IsMatch(i.Name)) continue;
            i.Flag = true;
            i.OffRaw = 0;
            i.OnRaw = v == 1 ? 1 : 0xFF;
            i.Category = i.Category is "Detected" or "General" ? "Switches" : i.Category;
            n++;
        }
        return n;
    }
}
