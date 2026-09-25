// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;
using static OkiRomSim.Mcp.OkiTools;

namespace OkiRomSim.Mcp;

/// Calibration, comparison, datalog, emulator and simulator tools. Every calibration tool works on a file (`path`: a .bin, or a .asm that is assembled) or - inside the desktop app, with `path` left out - on the ROM open there, so the user watches the agent's edits land. File mode keeps definitions next to the ROM as <rom>.okidef.json (created by cal_detect or cal_define). Edits to a .bin are written straight back to it (a .bak is kept once); edits to a .asm image stay in memory until cal_save writes a .bin.
public sealed class CalTools
{
    readonly Workspace _ws;
    readonly McpServer _server;
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    readonly Dictionary<string, (DateTime Stamp, Target T)> _files = new(StringComparer.OrdinalIgnoreCase);

    public CalTools(Workspace ws, McpServer server) { _ws = ws; _server = server; }

    IMcpSession? Session => _server.Session;

    /// A ROM being calibrated: its image, definitions, and how changes are kept.
    sealed class Target
    {
        public required string Name;
        public required DefinitionSet Defs;
        public required byte[] Rom;
        public AssemblyResult? Asm;
        public IReadOnlyList<(string Path, string Text)> Sources = [];
        public IMcpSession? Session;
        public string? File;          // file mode
        public string? DefsFile;
        public bool Backed;
        public bool Dirty;
    }

    // ------------------------------------------------------------------ targets

    Target Open(JsonObject a, string key = "path")
    {
        var p = S(a, key);
        if (string.IsNullOrWhiteSpace(p) || p.Equals("session", StringComparison.OrdinalIgnoreCase))
        {
            var s = Session ?? throw new ToolException($"'{key}' is required (no ROM is open in an app session: pass the .bin or .asm to work on)");
            return s.RomPath == null
                ? throw new ToolException("nothing is open in the app: open a ROM there first, or pass a path")
                : new Target
            {
                Name = Path.GetFileName(s.RomPath), Defs = s.Definitions(), Rom = s.Rom(), Asm = s.Assembly, Sources = s.Sources(), Session = s,
            };
        }
        var full = _ws.Resolve(p);
        var stamp = System.IO.File.GetLastWriteTimeUtc(full);
        if (_files.TryGetValue(full, out var c) && c.Stamp == stamp) return c.T;
        var prog = Program66k.Load(full, _ws.Allows);
        var defsFile = Path.ChangeExtension(full, null) + ".okidef.json";
        DefinitionSet defs;
        if (System.IO.File.Exists(defsFile)) defs = DefinitionSet.Load(defsFile);
        else if (prog.Asm != null && !prog.FromBinary) defs = DefinitionBuilder.FromAssembly(prog.Asm, Path.GetFileName(full));
        else defs = new DefinitionSet { Name = Path.GetFileName(full) };
        defs.MergeBuiltinFormulas();
        var t = new Target
        {
            Name = Path.GetFileName(full), Defs = defs, Rom = [.. prog.Image], Asm = prog.Asm, File = full, DefsFile = defsFile,
            Sources = prog.Sources.Select(kv => (kv.Key, string.Join("\n", kv.Value))).ToList(),
        };
        _files[full] = (stamp, t);
        return t;
    }

    void SaveDefs(Target t)
    {
        if (t.Session != null || t.DefsFile == null) return;
        _ws.Resolve(t.DefsFile, mustExist: false, forWrite: true);
        t.Defs.Save(t.DefsFile);
    }

    /// Persist a file-mode image change: .bin written back (with a one-time .bak).
    string CommitRom(Target t)
    {
        if (t.Session != null || t.File == null) return "patched in the app's running ROM (the Calibration page shows it)";
        t.Dirty = true;
        if (!t.File.EndsWith(".bin", StringComparison.OrdinalIgnoreCase) && !t.File.EndsWith(".rom", StringComparison.OrdinalIgnoreCase))
            return "kept in memory: call cal_save to write a .bin (the .asm source text is not changed)";
        _ws.Resolve(t.File, mustExist: true, forWrite: true);
        if (!t.Backed) { System.IO.File.Copy(t.File, t.File + ".bak", overwrite: true); t.Backed = true; }
        System.IO.File.WriteAllBytes(t.File, t.Rom);
        _files[t.File] = (System.IO.File.GetLastWriteTimeUtc(t.File), t);
        t.Dirty = false;
        return $"written to {_ws.Show(t.File)} (original kept as .bak)";
    }

    static ItemDef Item(Target t, string name) =>
        t.Defs.Find(name) ?? t.Defs.Items.FirstOrDefault(i => i.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
        ?? throw new ToolException($"no setting or table named '{name}' (cal_list shows them; cal_detect finds maps; cal_define adds one)");

    static FormulaDef Formula(Target t, ItemDef item)
    {
        try { return t.Defs.Formula(item.Formula); } catch { return Builtin.Raw; }
    }

    // ------------------------------------------------------------------ tool list

    static readonly (string, string, string, bool) PathArg = ("path", "string", ".bin or .asm to work on; leave out inside the desktop app to use the ROM open there", false);

    public IEnumerable<McpTool> All()
    {
        yield return new McpTool("session_info", "What the desktop app has open (ROM, build, unsaved edits, emulator, datalog). Only inside the app.",
            Schema(), _ => Session?.Describe() ?? "no app session: this server works on files (pass `path` to each tool)");

        yield return new McpTool("cal_list", "List the calibration definitions (settings, tables, axes, switches) with address, size, type and formula.",
            Schema(PathArg, ("filter", "string", "substring of name/category/description", false), ("category", "string", "only this category", false),
                   ("max", "integer", "max rows (default 300)", false)), CalList);

        yield return new McpTool("cal_read", "Read a setting or table: values through its formula, with the row/column axes (rpm / load) and the raw bytes if asked.",
            Schema(PathArg, ("name", "string", "setting or table name", true), ("raw", "boolean", "also show raw stored numbers", false)), CalRead);

        yield return new McpTool("cal_write",
            "Change calibration values. Pick cells with row/col (single, or ranges 'a-b'), index, cells [[row,col,value],...], or grid (2D array written from row/col); " +
            "op set|add|mul|pct applies `value` to the picked cells (default set). Values are in the item's units unless raw=true. " +
            "Returns before -> after for the cells changed. In the app the change is live (and uploaded to the emulator when auto-upload is on).",
            Schema(PathArg, ("name", "string", "setting or table", true), ("value", "number", "value (or amount for add/mul/pct)", false),
                   ("op", "string", "set (default), add, mul, pct", false), ("row", "string", "row index or range 'a-b'", false), ("col", "string", "column index or range 'a-b'", false),
                   ("index", "integer", "flat cell index", false), ("cells", "array", "[[row, col, value], ...]", false), ("grid", "array", "2D array of values starting at row/col (default 0,0)", false),
                   ("raw", "boolean", "values are raw stored numbers", false)), CalWrite, ReadOnly: false);

        yield return new McpTool("cal_scale",
            "Scale a whole section instead of cell by cell. op=table scales one table by `percent`; op=headroom rescales a fuel table around `peak` " +
            "(each column's multiplier is raised and its cells divided, so the ECU delivers the same fuel with room to grow instead of maxing out at the top of the scale); " +
            "op=injectors scales every fuel table by old/new injector size; op=map_sensor moves the load axes for a different MAP sensor full scale. " +
            "preview=true reports the change without writing it.",
            Schema(PathArg, ("op", "string", "table, headroom, injectors or map_sensor", true), ("name", "string", "table to scale (op=table / headroom)", false),
                   ("percent", "number", "change in percent (op=table)", false), ("peak", "integer", "where the biggest cell should sit, 32-250 (op=headroom, default 200)", false),
                   ("old", "number", "injector size / sensor full scale in the calibration", false), ("new", "number", "injector size / sensor full scale fitted", false),
                   ("preview", "boolean", "work it out but do not write it", false)), CalScale, ReadOnly: false);

        yield return new McpTool("cal_define",
            "Add or edit a definition: a setting (rows=cols=0), a table (rows x cols, optional row stride), its formula, row axis (rpm) and column axis (load) " +
            "by label or hex address with their formulas, a per-column multiplier row (Honda fuel maps), switch settings, category and description. " +
            "new_name renames. Name tables after the code that uses them (see cal_explain).",
            Schema(PathArg, ("name", "string", "name (existing to edit, new to add)", true), ("new_name", "string", "rename to", false),
                   ("address", "string", "label or hex address (required for a new item)", false), ("type", "string", "u8 s8 u16 s16 u16be s16be bit", false),
                   ("rows", "integer", "table rows (0 = single value)", false), ("cols", "integer", "table columns", false), ("stride", "integer", "bytes per row (0 = packed)", false),
                   ("formula", "string", "formula name (cal_formulas)", false), ("row_axis", "string", "row axis label/address ('' removes)", false),
                   ("row_axis_formula", "string", "row axis formula", false), ("col_axis", "string", "column axis label/address ('' removes)", false),
                   ("col_axis_formula", "string", "column axis formula", false), ("column_multiplier", "string", "address of a per-column multiplier row ('' removes)", false),
                   ("category", "string", "group (Fuel, Ignition, VTEC, Idle, Limits...)", false), ("description", "string", "what it does", false),
                   ("flag", "boolean", "on/off switch", false), ("on_raw", "number", "raw value for on (switches)", false), ("off_raw", "number", "raw value for off", false),
                   ("bit", "integer", "bit number (type bit)", false)), CalDefine, ReadOnly: false);

        yield return new McpTool("cal_delete", "Remove a definition (the ROM bytes are not touched).",
            Schema(PathArg, ("name", "string", "definition to remove", true)), CalDelete, ReadOnly: false);

        yield return new McpTool("cal_detect",
            "Find calibration data from the code: maps set up for the 2D lookup (rows, columns, stride, fuel multiplier row, rpm and load axes), labelled DB/DW blocks, " +
            "tables read with LC/LCB, and on/off switches. Adds what is new; never replaces a hand-made definition.",
            Schema(PathArg), CalDetect, ReadOnly: false);

        yield return new McpTool("cal_explain",
            "Which code reads a setting or table, what that code appears to do (hardware, calls, loops), and the axes: the evidence for naming it after its function.",
            Schema(PathArg, ("name", "string", "definition, or a hex address/label", true), ("max", "integer", "max references (default 12)", false)), CalExplain);

        yield return new McpTool("cal_formulas", "List scaling formulas (name, expression in x, inverse, unit), or add/replace one with name + expr.",
            Schema(PathArg, ("name", "string", "formula to add or replace", false), ("expr", "string", "value from raw x, e.g. 'x * 0.25 - 6'", false),
                   ("inverse", "string", "raw from value x (optional; searched when missing)", false), ("unit", "string", "unit", false), ("decimals", "integer", "decimals shown", false)),
            CalFormulas, ReadOnly: false);

        yield return new McpTool("cal_save",
            "Save: format bin (the image with every edit), defs (definitions JSON), xdf (TunerPro XDF of every definition), or all. " +
            "In the app, bin saves the running ROM; output defaults next to the ROM.",
            Schema(PathArg, ("format", "string", "bin, defs, xdf or all (default bin)", false), ("output", "string", "output file (bin/defs/xdf: extension is set per format)", false)),
            CalSave, ReadOnly: false);

        yield return new McpTool("cal_features",
            "Code patches from a feature file (roms/features.json by default): list them with whether each fits this ROM (on / off / partial / not for this ROM), " +
            "or apply / remove one by id - disable a trouble code, MIL off, known base-ROM fixes. Every site is checked against the bytes it expects first, " +
            "and removing restores exactly what was there. In the app the change is one undo step on the running ROM.",
            Schema(PathArg, ("action", "string", "list (default), apply, remove or show", false), ("id", "string", "feature id for apply/remove/show", false),
                   ("file", "string", "feature file (default: features.json next to the program)", false)), CalFeatures, ReadOnly: false);

        yield return new McpTool("compare",
            "What changed between two ROMs (.bin or .asm; 'session' = the app's): routines added/removed/changed/moved (with the hardware, calls and tables they gained or lost), " +
            "vectors, and every calibration table that differs cell by cell. mode: all (default), functions, tables.",
            Schema(("a", "string", "first ROM (or 'session')", true), ("b", "string", "second ROM (or 'session')", true),
                   ("mode", "string", "all, functions or tables", false), ("max", "integer", "max rows per section (default 60)", false), ("output", "string", "also write the report here", false)),
            Compare);

        yield return new McpTool("datalog",
            "Datalogging. In the app: status, start (port, protocol auto/the tuning software/ISR/QD3/..., or 'simulator' for the virtual ECU), stop, latest (the newest frame, every channel), " +
            "frames (from/count, channels), clear, load (a log file into the app). Anywhere: detect_layout (how a ROM datalogs, worked out by reading its serial " +
            "code and probing it in a simulator), overlay (a channel such as afr / knock / o2_v averaged in each cell of a table, " +
            "from the app's frames or a `log` file; with target_afr it also suggests the fuel change per cell) and stats (min/avg/max per channel).",
            Schema(PathArg, ("action", "string", "status, start, stop, latest, frames, clear, load, overlay, stats, protocols", true),
                   ("log", "string", "log file (.csv or the tuning software datalog) instead of the app's frames", false), ("port", "string", "serial port for start ('simulator' = virtual ECU)", false),
                   ("protocol", "string", "auto, the tuning software, ISR, QD3, 'the tuning software single-byte', 'Raw 10h frame'", false),
                   ("table", "string", "table for overlay", false), ("channel", "string", "channel for overlay (afr, lambda, o2_v, knock, inj_ms, ...)", false),
                   ("target_afr", "number", "wanted AFR for fuel suggestions", false), ("min_samples", "integer", "cells need this many samples (default 3)", false),
                   ("from", "integer", "first frame for frames", false), ("count", "integer", "frames to return (default 20)", false),
                   ("channels", "string[]", "channels for frames/stats", false)), Datalog, ReadOnly: false);

        yield return new McpTool("emulator",
            "Moates Ostrich 2.0 / Demon ROM emulator in the app: status, connect (port), upload (the running ROM), disconnect, auto_upload_on / auto_upload_off " +
            "(upload every calibration change as it is made, so the car runs it straight away).",
            Schema(("action", "string", "status, connect, upload, disconnect, auto_upload_on, auto_upload_off", true), ("port", "string", "serial port for connect", false)),
            a => (Session ?? throw new ToolException("the emulator is only available inside the desktop app")).Emulator(Req(a, "action"), S(a, "port")), ReadOnly: false);

        yield return new McpTool("simulator",
            "The app's simulator: state, run, pause, reset, step, or inputs (rpm, map_kpa, tps_pct, ect_c, iat_c, o2_v, batt_v, speed_kmh) to set the engine it simulates. " +
            "Use with datalog (port 'simulator') to log the ROM as if it were in a car.",
            Schema(("action", "string", "state, run, pause, reset, step, inputs", true), ("rpm", "number", "", false), ("map_kpa", "number", "", false),
                   ("tps_pct", "number", "", false), ("ect_c", "number", "", false), ("iat_c", "number", "", false), ("o2_v", "number", "", false),
                   ("batt_v", "number", "", false), ("speed_kmh", "number", "", false), ("count", "integer", "instructions for step", false)),
            a => (Session ?? throw new ToolException("the simulator control is only available inside the desktop app (use `run` for a headless run)")).Simulator(Req(a, "action"), a),
            ReadOnly: false);
    }

    // ------------------------------------------------------------------ list / read

    string CalList(JsonObject a)
    {
        var t = Open(a);
        string f = S(a, "filter") ?? "", cat = S(a, "category") ?? "";
        int max = Math.Clamp(I(a, "max", 300), 1, 5000);
        var items = t.Defs.Items.Where(i => (cat.Length == 0 || i.Category.Equals(cat, StringComparison.OrdinalIgnoreCase)) &&
            (f.Length == 0 || i.Name.Contains(f, StringComparison.OrdinalIgnoreCase) || i.Category.Contains(f, StringComparison.OrdinalIgnoreCase) ||
             i.Description.Contains(f, StringComparison.OrdinalIgnoreCase))).OrderBy(i => i.Category).ThenBy(i => i.Address).ToList();
        if (t.Defs.Items.Count == 0) return $"{t.Name}: no definitions yet. Run cal_detect to find the maps from the code, or cal_define to add one.";
        var sb = new StringBuilder($"{t.Name}: {items.Count} of {t.Defs.Items.Count} definitions\n");
        sb.AppendLine("name | category | address | size | type | formula | axes | origin");
        foreach (var i in items.Take(max))
            sb.AppendLine($"{i.Name} | {i.Category} | {i.Address:X4} | {(i.IsTable ? $"{i.Rows}x{i.Cols}{(i.Stride > 0 ? $" stride {i.Stride}" : "")}" : i.Flag ? "switch" : "1")} | " +
                          $"{i.Type.ToString().ToLowerInvariant()} | {i.Formula ?? "raw"} | " +
                          $"{(i.RowAxis?.Address is int ra ? $"rows {ra:X4}({i.RowAxis.Formula})" : "")}{(i.ColAxis?.Address is int ca ? $" cols {ca:X4}({i.ColAxis.Formula})" : "")}" +
                          $"{(i.ColumnScaleAddress is int m ? $" mult {m:X4}" : "")} | {i.Origin ?? ""}");
        if (items.Count > max) sb.AppendLine($"... {items.Count - max} more (filter or raise max)");
        return sb.ToString();
    }

    string CalRead(JsonObject a)
    {
        var t = Open(a);
        var item = Item(t, Req(a, "name"));
        var f = Formula(t, item);
        bool raw = B(a, "raw", false);
        var cells = RomData.Read(t.Defs, t.Rom, item);
        var sb = new StringBuilder();
        sb.AppendLine($"{item.Name} [{item.Category}] @ {item.Address:X4}  {(item.IsTable ? $"{item.Rows}x{item.Cols}" : "setting")}  {item.Type.ToString().ToLowerInvariant()}  " +
                      $"formula {f.Name} = {f.Expr}{(f.Unit.Length > 0 ? $" ({f.Unit})" : "")}");
        if (item.Description.Length > 0) sb.AppendLine(item.Description);
        if (!item.IsTable || item.Count == 1)
        {
            sb.AppendLine($"value {cells[0].Display}   raw {cells[0].Raw:0} (0x{(long)cells[0].Raw:X2})" + (item.Flag ? $"   switch: {(cells[0].Raw != item.OffRaw ? "ON" : "off")}" : ""));
            return sb.ToString();
        }
        var rowAxis = item.RowAxis == null ? null : RomData.AxisValues(t.Defs, t.Rom, item.RowAxis, item.Rows);
        var colAxis = item.ColAxis == null ? null : RomData.AxisValues(t.Defs, t.Rom, item.ColAxis, item.Cols);
        string Unit(AxisDef? ax) { if (ax == null) return ""; if (ax.Unit.Length > 0) return ax.Unit; try { return t.Defs.Formula(ax.Formula).Unit; } catch { return ""; } }
        sb.AppendLine($"rows: {(rowAxis == null ? "index" : Unit(item.RowAxis))}   columns: {(colAxis == null ? "index" : Unit(item.ColAxis))}" +
                      (item.ColumnScaleAddress is int ms ? $"   (each column multiplied by the byte at {ms:X4}+col before scaling)" : ""));
        int w = Math.Max(7, f.Decimals + 5);
        sb.Append(new string(' ', 9));
        for (int c = 0; c < item.Cols; c++) sb.Append((colAxis != null && c < colAxis.Length ? colAxis[c].ToString("0.#", Inv) : c.ToString()).PadLeft(w));
        sb.AppendLine();
        for (int r = 0; r < item.Rows; r++)
        {
            sb.Append((rowAxis != null && r < rowAxis.Length ? rowAxis[r].ToString("0", Inv) : r.ToString()).PadLeft(7)).Append("  ");
            for (int c = 0; c < item.Cols; c++)
            {
                var cv = cells[(r * item.Cols) + c];
                sb.Append((raw ? cv.Raw.ToString("0", Inv) : cv.Value.ToString("F" + Math.Clamp(f.Decimals, 0, 3), Inv)).PadLeft(w));
            }
            sb.AppendLine();
        }
        if (raw) sb.AppendLine("(raw stored numbers)");
        return sb.ToString();
    }

    // ------------------------------------------------------------------ write

    static (int Lo, int Hi)? Range(string? s, int n)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        var p = s.Split('-', 2);
        if (!int.TryParse(p[0].Trim(), out var lo)) throw new ToolException($"bad index '{s}'");
        int hi = lo;
        if (p.Length == 2 && !int.TryParse(p[1].Trim(), out hi)) throw new ToolException($"bad range '{s}'");
        if (lo > hi) (lo, hi) = (hi, lo);
        return lo < 0 || hi >= n ? throw new ToolException($"'{s}' is outside 0-{n - 1}") : ((int Lo, int Hi)?)(lo, hi);
    }

    static double Num(JsonNode? n) => n is JsonValue v && v.TryGetValue<double>(out var d) ? d
        : double.TryParse(n?.ToString(), NumberStyles.Float, Inv, out d) ? d : throw new ToolException($"'{n}' is not a number");

    string CalWrite(JsonObject a)
    {
        var t = Open(a);
        var item = Item(t, Req(a, "name"));
        bool raw = B(a, "raw", false);
        string op = (S(a, "op") ?? "set").ToLowerInvariant();
        int rows = Math.Max(1, item.Rows), cols = Math.Max(1, item.Cols);
        var before = RomData.Read(t.Defs, t.Rom, item);
        var target = new Dictionary<int, double>();       // cell -> new value (in item units, or raw)
        double Cur(int i) => raw ? before[i].Raw : before[i].Value;
        double Apply(int i, double v) => op switch
        {
            "set" => v, "add" => Cur(i) + v, "mul" => Cur(i) * v, "pct" => Cur(i) * (1 + (v / 100)),
            _ => throw new ToolException($"unknown op '{op}' (set, add, mul, pct)"),
        };

        if (a["cells"] is JsonArray cellList)
        {
            foreach (var c in cellList)
            {
                if (c is not JsonArray triple || triple.Count != 3) throw new ToolException("cells must be [[row, col, value], ...]");
                int r = (int)Num(triple[0]), cc = (int)Num(triple[1]);
                if (r < 0 || r >= rows || cc < 0 || cc >= cols) throw new ToolException($"cell [{r},{cc}] is outside {rows}x{cols}");
                target[(r * cols) + cc] = Apply((r * cols) + cc, Num(triple[2]));
            }
        }
        else if (a["grid"] is JsonArray grid)
        {
            int r0 = Range(S(a, "row"), rows)?.Lo ?? 0, c0 = Range(S(a, "col"), cols)?.Lo ?? 0;
            for (int dr = 0; dr < grid.Count; dr++)
            {
                var line = grid[dr] as JsonArray ?? new JsonArray(grid[dr]?.DeepClone());
                for (int dc = 0; dc < line.Count; dc++)
                {
                    int r = r0 + dr, cc = c0 + dc;
                    if (r >= rows || cc >= cols) throw new ToolException($"grid runs past the table ({rows}x{cols}) at [{r},{cc}]");
                    target[(r * cols) + cc] = Apply((r * cols) + cc, Num(line[dc]));
                }
            }
        }
        else
        {
            double v = a["value"] is { } vn ? Num(vn) : throw new ToolException("'value' is required (or cells / grid)");
            if (a["index"] != null)
            {
                int i = I(a, "index", 0);
                if (i < 0 || i >= item.Count) throw new ToolException($"index {i} is outside 0-{item.Count - 1}");
                target[i] = Apply(i, v);
            }
            else
            {
                var rr = Range(S(a, "row"), rows) ?? (0, rows - 1);
                var cr = Range(S(a, "col"), cols) ?? (0, cols - 1);
                if (item.IsTable && item.Count > 1 && S(a, "row") == null && S(a, "col") == null && op == "set")
                    throw new ToolException("give row and/or col (or index / cells / grid): setting a whole table to one value is almost never meant");
                for (int r = rr.Item1; r <= rr.Item2; r++)
                    for (int c = cr.Item1; c <= cr.Item2; c++) target[(r * cols) + c] = Apply((r * cols) + c, v);
            }
        }
        if (target.Count == 0) return "no cells picked";

        string where;
        if (t.Session != null)
        {
            t.Session.WriteBatch(item, target.Select(kv => (kv.Key, kv.Value)).ToList(), raw, $"{op} by MCP");
            t.Rom = t.Session.Rom();
            where = "patched in the app's running ROM (the Calibration page shows it)";
        }
        else
        {
            foreach (var (i, v) in target)
            {
                if (raw) RomData.WriteRawCell(t.Rom, item, i, v);
                else RomData.Write(t.Defs, t.Rom, item, i, v);
            }
            where = CommitRom(t);
        }
        var after = RomData.Read(t.Defs, t.Rom, item);
        var sb = new StringBuilder($"{item.Name}: {target.Count} cell(s) {op}, {where}\n");
        int shown = 0;
        foreach (var i in target.Keys.OrderBy(k => k))
        {
            if (shown++ >= 24) { sb.AppendLine($"  ... {target.Count - 24} more"); break; }
            string at = item.IsTable && item.Count > 1 ? $"[{i / cols},{i % cols}]" : "";
            string note = Math.Abs(after[i].Value - (raw ? after[i].Value : target[i])) > 1e-6 && !raw ? $" (asked {target[i]:0.###}: nearest the ROM stores)" : "";
            sb.AppendLine($"  {at} {before[i].Display} -> {after[i].Display}{note}");
        }
        return sb.ToString();
    }

    /// Scaling a section: works out the bytes with Rescale, then writes them as one undo step (in the app) or back to the file.
    string CalScale(JsonObject a)
    {
        var t = Open(a);
        string op = (S(a, "op") ?? "").ToLowerInvariant();
        double D(string key, double fallback) => a[key] is { } n ? Num(n) : fallback;
        var work = t.Rom.ToArray();                     // the report is built against a copy
        ScaleReport report = op switch
        {
            "table" => Rescale.ScaleTable(t.Defs, work, Item(t, Req(a, "name")), 1 + (D("percent", 0) / 100)),
            "headroom" => Rescale.Headroom(t.Defs, work, Item(t, Req(a, "name")), (int)D("peak", 200)),
            "injectors" => Rescale.Injectors(t.Defs, work, FuelTables(t), D("old", 0), D("new", 0)),
            "map_sensor" or "map" => Rescale.MapSensor(t.Defs, work,
                t.Defs.Items.Where(i => i.IsTable && i.Cols > 1 && i.ColAxis?.Address != null), D("old", 0), D("new", 0)),
            _ => throw new ToolException($"unknown op '{op}' (table, headroom, injectors, map_sensor)"),
        };
        if (!report.Any) return report.Summary;
        if (B(a, "preview", false))
            return report.Summary + $"\n{report.Patches.Count} byte(s) would change (preview only, nothing written).";

        string where;
        if (t.Session != null)
        {
            t.Session.ApplyPatches(report.Patches, $"MCP {op} scale");
            t.Rom = t.Session.Rom();
            where = "patched in the app's running ROM (the Calibration page shows it)";
        }
        else
        {
            Rescale.Apply(t.Rom, report);
            where = CommitRom(t);
        }
        return report.Summary + $"\n{report.Patches.Count} byte(s) written, {where}";
    }

    string CalFeatures(JsonObject a)
    {
        var t = Open(a);
        var file = S(a, "file") ?? FeatureFile.DefaultPath;
        if (!File.Exists(file)) throw new ToolException($"no feature file at {file}");
        var ff = FeatureFile.Load(file);
        string action = (S(a, "action") ?? "list").ToLowerInvariant();
        if (action == "list")
        {
            var sb = new System.Text.StringBuilder();
            foreach (var f in ff.Features)
            {
                var c = FeaturePatches.Check(f, t.Rom);
                sb.AppendLine($"{f.Id,-30} {c.State,-13} {f.Name}");
            }
            return sb.ToString();
        }
        var id = Req(a, "id");
        var feat = ff.Features.FirstOrDefault(f => f.Id.Equals(id, StringComparison.OrdinalIgnoreCase)) ?? throw new ToolException($"no feature '{id}'");
        var check = FeaturePatches.Check(feat, t.Rom);
        if (action == "show")
            return $"{feat.Name} [{feat.Category}] - {check.Detail}\n{feat.Description}\nChecked: {feat.Verified}\n" +
                   string.Join("\n", (check.Variant?.Sites ?? []).Select(x => $"  {x.Address}: {x.Original} -> {x.Patched} {x.Note}"));
        if (action is not ("apply" or "remove")) throw new ToolException($"unknown action '{action}' (list, show, apply, remove)");
        if (check.State == FeatureState.NotApplicable) throw new ToolException($"{id} does not fit this ROM");
        var patches = FeaturePatches.Patches(feat, t.Rom, action == "remove", ff.ChecksumByte);
        if (patches.Count == 0) return $"{id}: already {(action == "remove" ? "off" : "on")}";
        string where;
        if (t.Session != null)
        {
            t.Session.ApplyPatches(patches, $"MCP {action} feature {id}");
            t.Rom = t.Session.Rom();
            where = "in the app's running ROM (Undo takes it back)";
        }
        else
        {
            foreach (var p in patches) t.Rom[p.Address] = p.Value;
            where = CommitRom(t);
        }
        return $"{id}: {patches.Count} byte(s) {(action == "remove" ? "restored" : "written")} {where}";
    }

    static IEnumerable<ItemDef> FuelTables(Target t) =>
        t.Defs.Items.Where(i => i.IsTable && i.Count > 1 &&
            (i.ColumnScaleAddress != null || i.Category.Equals("Fuel", StringComparison.OrdinalIgnoreCase)));

    // ------------------------------------------------------------------ define / delete / detect

    int Addr(Target t, string text)
    {
        text = text.Trim();
        if (t.Defs.TryResolve(text, out var a)) return a;
        if (t.Asm != null && t.Asm.Symbols.TryGetValue(text, out var s)) return (int)s.Value;
        var hex = text.EndsWith("h", StringComparison.OrdinalIgnoreCase) ? text[..^1] : text.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? text[2..] : text;
        return int.TryParse(hex, NumberStyles.HexNumber, Inv, out a)
            ? a
            : throw new ToolException($"cannot resolve '{text}' (a label or a hex address)");
    }

    string CalDefine(JsonObject a)
    {
        var t = Open(a);
        string name = Req(a, "name");
        string Change(DefinitionSet defs)
        {
            var item = defs.Find(name) ?? defs.Items.FirstOrDefault(i => i.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
            bool created = item == null;
            if (item == null)
            {
                if (S(a, "address") is not { Length: > 0 } ad) throw new ToolException($"'{name}' does not exist yet: give its address to add it");
                item = new ItemDef { Name = name, Address = Addr(t, ad), Type = CellType.U8, Formula = "raw", Category = "User", Origin = "mcp" };
                defs.Items.Add(item);
            }
            if (S(a, "new_name") is { Length: > 0 } nn)
            {
                if (defs.Items.Any(i => i != item && i.Name.Equals(nn, StringComparison.OrdinalIgnoreCase))) throw new ToolException($"'{nn}' is already used");
                item.Name = nn;
            }
            if (!created && S(a, "address") is { Length: > 0 } ad2) item.Address = Addr(t, ad2);
            if (S(a, "type") is { Length: > 0 } ty)
                item.Type = Enum.TryParse<CellType>(ty, true, out var ct) ? ct : throw new ToolException($"unknown type '{ty}' (u8 s8 u16 s16 u16be s16be bit)");
            if (a["rows"] != null) item.Rows = Math.Clamp(I(a, "rows", 0), 0, 256);
            if (a["cols"] != null) item.Cols = Math.Clamp(I(a, "cols", 0), 0, 256);
            if (item.Rows > 0 != item.Cols > 0) { item.Rows = Math.Max(item.Rows, 1); item.Cols = Math.Max(item.Cols, 1); }
            if (a["stride"] != null) item.Stride = Math.Clamp(I(a, "stride", 0), 0, 4096);
            if (S(a, "formula") is { Length: > 0 } fo) { try { defs.Formula(fo); } catch { throw new ToolException($"no formula '{fo}' (cal_formulas lists them)"); } item.Formula = fo; }
            AxisDef? Axis(string key, string fkey, AxisDef? old, int count)
            {
                if (a[key] == null) { if (old != null && S(a, fkey) is { Length: > 0 } of) old.Formula = of; old?.Count = count; return old; }
                var text = S(a, key) ?? "";
                if (text.Trim().Length == 0) return null;
                var f = S(a, fkey) ?? old?.Formula ?? "raw";
                string unit = ""; try { unit = defs.Formula(f).Unit; } catch { }
                return new AxisDef { Name = Regex.IsMatch(text, @"^(0x)?[0-9A-Fa-f]+h?$") ? null : text, Address = Addr(t, text), Count = count, Formula = f, Unit = unit };
            }
            item.RowAxis = Axis("row_axis", "row_axis_formula", item.RowAxis, item.Rows);
            item.ColAxis = Axis("col_axis", "col_axis_formula", item.ColAxis, item.Cols);
            if (a["column_multiplier"] != null) item.ColumnScaleAddress = (S(a, "column_multiplier") ?? "").Trim().Length == 0 ? null : Addr(t, S(a, "column_multiplier")!);
            if (S(a, "category") is { Length: > 0 } cat) item.Category = cat;
            if (a["description"] != null) item.Description = S(a, "description") ?? "";
            if (a["flag"] != null) item.Flag = B(a, "flag", false);
            if (a["on_raw"] != null) item.OnRaw = D(a, "on_raw", 0xFF);
            if (a["off_raw"] != null) item.OffRaw = D(a, "off_raw", 0);
            if (a["bit"] != null) item.Bit = Math.Clamp(I(a, "bit", 0), 0, 7);
            return item.Address < 0 || item.Address + item.Span > Math.Max(t.Rom.Length, Bus.RomSize)
                ? throw new ToolException($"{item.Name} would run past the end of the ROM")
                : $"{(created ? "added" : "updated")} {item.Name}: {item.Address:X4} {(item.IsTable ? $"{item.Rows}x{item.Cols}" : "setting")} {item.Type.ToString().ToLowerInvariant()} " +
                   $"formula {item.Formula ?? "raw"} [{item.Category}]" +
                   (item.RowAxis?.Address is int ra ? $", rows {ra:X4}" : "") + (item.ColAxis?.Address is int ca ? $", cols {ca:X4}" : "");
        }
        string result = t.Session != null ? t.Session.Edit(Change, "MCP cal_define " + name, S(a, "new_name") ?? name) : Change(t.Defs);
        SaveDefs(t);
        return result + (t.Session == null ? $" (definitions saved to {_ws.Show(t.DefsFile!)})" : "");
    }

    string CalDelete(JsonObject a)
    {
        var t = Open(a);
        string name = Req(a, "name");
        string Change(DefinitionSet defs)
        {
            var item = defs.Find(name) ?? defs.Items.FirstOrDefault(i => i.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
                       ?? throw new ToolException($"no definition '{name}'");
            defs.Items.Remove(item);
            return $"removed {item.Name} ({item.Address:X4}); the ROM bytes are unchanged";
        }
        var r = t.Session != null ? t.Session.Edit(Change, "MCP cal_delete " + name) : Change(t.Defs);
        SaveDefs(t);
        return r;
    }

    string CalDetect(JsonObject a)
    {
        var t = Open(a);
        if (t.Asm == null) throw new ToolException("the ROM has no assembly (it did not assemble / disassemble cleanly), so the code cannot be followed");
        DetectResult Run(DefinitionSet defs) => CalibrationDetector.Detect(defs, t.Asm, t.Rom, t.Sources);
        var r = t.Session != null ? t.Session.Edit(Run, "MCP cal_detect") : Run(t.Defs);
        SaveDefs(t);
        var sb = new StringBuilder($"{t.Name}: {r.Summary}.\n");
        foreach (var n in r.Names.Take(80))
        {
            var i = t.Defs.Find(n);
            if (i != null) sb.AppendLine($"  {i.Name} [{i.Category}] {i.Address:X4} {(i.IsTable ? $"{i.Rows}x{i.Cols}" : "")} {i.Formula}");
        }
        sb.AppendLine("Check types and formulas; cal_explain shows what code reads each one (rename with cal_define new_name).");
        return sb.ToString();
    }

    string CalFormulas(JsonObject a)
    {
        var t = Open(a);
        if (S(a, "name") is { Length: > 0 } name && S(a, "expr") is { Length: > 0 } expr)
        {
            try { Expression.Parse(expr).Eval(1); } catch (Exception ex) { throw new ToolException($"bad expression: {ex.Message}"); }
            var f = new FormulaDef { Name = name, Expr = expr, Inverse = S(a, "inverse"), Unit = S(a, "unit") ?? "", Decimals = I(a, "decimals", 2) };
            string Change(DefinitionSet defs) { defs.Formulas.RemoveAll(x => x.Name == name); defs.Formulas.Add(f); return $"formula {name} = {expr}"; }
            var r = t.Session != null ? t.Session.Edit(Change, "MCP formula " + name) : Change(t.Defs);
            SaveDefs(t);
            return r;
        }
        var sb = new StringBuilder("name | value from raw x | inverse | unit | notes\n");
        foreach (var f in t.Defs.Formulas.OrderBy(f => f.Name))
            sb.AppendLine($"{f.Name} | {f.Expr} | {f.Inverse ?? "(searched)"} | {f.Unit} | {f.Notes}");
        return sb.ToString();
    }

    // ------------------------------------------------------------------ explain

    string CalExplain(JsonObject a)
    {
        var t = Open(a);
        var what = Req(a, "name");
        int max = Math.Clamp(I(a, "max", 12), 1, 60);
        var item = t.Defs.Find(what) ?? t.Defs.Items.FirstOrDefault(i => i.Name.Equals(what, StringComparison.OrdinalIgnoreCase));
        int addr = item?.Address ?? Addr(t, what);
        var prog = t.Asm != null ? Program66k.FromAssembly(t.Name, t.Rom, t.Asm, t.Sources) : Program66k.FromImage(t.Rom, t.Name);
        var ex = new Explorer(prog);
        var sb = new StringBuilder();
        sb.AppendLine(item == null ? $"{addr:X4} ({prog.Name(addr)})" :
            $"{item.Name} [{item.Category}] @ {addr:X4}, {(item.IsTable ? $"{item.Rows}x{item.Cols}" : "single value")}, formula {item.Formula ?? "raw"}");
        var targets = new List<(int A, string What)> { (addr, "the data") };
        if (item?.RowAxis?.Address is int ra) targets.Add((ra, "its row axis"));
        if (item?.ColAxis?.Address is int ca) targets.Add((ca, "its column axis"));
        if (item?.ColumnScaleAddress is int ms) targets.Add((ms, "its column multiplier"));
        var labels = prog.Labels;
        var boundaries = t.Asm?.SourceMap.Select(e => e.Address);
        var seenRoutines = new HashSet<int>();
        foreach (var (ta, whatRef) in targets)
        {
            var hits = Xref.Find(t.Rom, ta, boundaries, x => labels.GetValueOrDefault(x, ""), null, maxHits: max);
            sb.AppendLine();
            sb.AppendLine($"{whatRef} ({ta:X4}): {hits.Count} reference(s)");
            foreach (var h in hits.Take(max))
            {
                int entry = labels.Keys.Where(k => k <= h.Address).DefaultIfEmpty(h.Address).Max();
                sb.AppendLine($"  {h.Address:X4} in {prog.Name(h.Address)}: {h.Text}  ({h.Kind})");
                if (seenRoutines.Add(entry))
                {
                    try
                    {
                        var r = ex.Walk(entry, 500);
                        sb.AppendLine($"      routine {r.Name}: {r.Purpose}");
                        var callers = Xref.Find(t.Rom, entry, boundaries, x => labels.GetValueOrDefault(x, ""), null, maxHits: 4);
                        if (callers.Count > 0) sb.AppendLine($"      called from {string.Join(", ", callers.Select(c => prog.Name(c.Address)))}");
                    }
                    catch { }
                }
            }
        }
        if (item?.RowAxis != null || item?.ColAxis != null)
        {
            sb.AppendLine();
            if (item.RowAxis != null) sb.AppendLine($"row axis values: {string.Join(" ", RomData.AxisValues(t.Defs, t.Rom, item.RowAxis, item.Rows).Select(v => v.ToString("0.#", Inv)))}");
            if (item.ColAxis != null) sb.AppendLine($"column axis values: {string.Join(" ", RomData.AxisValues(t.Defs, t.Rom, item.ColAxis, item.Cols).Select(v => v.ToString("0.#", Inv)))}");
        }
        sb.AppendLine();
        sb.AppendLine("Name it after what the reading routine does (e.g. fuel_main_lo_cam, ign_high_cam, vtec_engage_rpm, idle_target_rpm), then cal_define name=... new_name=... category=... description=...");
        return sb.ToString();
    }

    // ------------------------------------------------------------------ save

    string CalSave(JsonObject a)
    {
        var t = Open(a);
        string format = (S(a, "format") ?? "bin").ToLowerInvariant();
        string baseName = S(a, "output") is { Length: > 0 } o ? o
            : t.File != null ? Path.ChangeExtension(t.File, null)
            : t.Session?.RomPath is { } rp ? Path.ChangeExtension(rp, null) + ".tuned" : "tuned";
        if (Path.HasExtension(baseName) && format != "all") baseName = Path.ChangeExtension(baseName, null);
        var done = new List<string>();
        if (format is "bin" or "all")
        {
            var outPath = _ws.Resolve(baseName + ".bin", mustExist: false, forWrite: true);
            if (t.Session != null) done.Add(t.Session.SaveRom(outPath));
            else
            {
                if (File.Exists(outPath) && outPath.Equals(t.File, StringComparison.OrdinalIgnoreCase) && !t.Backed) File.Copy(outPath, outPath + ".bak", true);
                File.WriteAllBytes(outPath, t.Rom);
                done.Add($"image -> {_ws.Show(outPath)}");
            }
        }
        if (format is "defs" or "all")
        {
            var outPath = _ws.Resolve(baseName + ".okidef.json", mustExist: false, forWrite: true);
            t.Defs.Save(outPath);
            done.Add($"definitions -> {_ws.Show(outPath)}");
        }
        if (format is "xdf" or "all")
        {
            var outPath = _ws.Resolve(baseName + ".xdf", mustExist: false, forWrite: true);
            File.WriteAllText(outPath, XdfExport.Write(t.Defs, t.Rom, Path.GetFileNameWithoutExtension(baseName)));
            done.Add($"TunerPro XDF -> {_ws.Show(outPath)} ({t.Defs.Items.Count} definitions)");
        }
        return done.Count == 0
            ? throw new ToolException($"unknown format '{format}' (bin, defs, xdf, all)")
            : "saved: " + string.Join("; ", done);
    }

    // ------------------------------------------------------------------ compare

    Program66k Prog(string? which)
    {
        if (string.IsNullOrWhiteSpace(which) || which.Equals("session", StringComparison.OrdinalIgnoreCase))
        {
            var s = Session ?? throw new ToolException("'session' needs the desktop app");
            var asm = s.Assembly;
            var rom = s.Rom();
            return asm != null ? Program66k.FromAssembly(s.RomPath ?? "session", rom, asm, s.Sources()) : Program66k.FromImage(rom, s.RomPath ?? "session");
        }
        return Program66k.Load(_ws.Resolve(which), _ws.Allows);
    }

    string Compare(JsonObject a)
    {
        var pa = Prog(S(a, "a")); var pb = Prog(S(a, "b"));
        string mode = (S(a, "mode") ?? "all").ToLowerInvariant();
        var report = RomCompare.Compare(pa, pb, new RomCompare.Options(mode is "all" or "functions", mode is "all" or "tables", Math.Clamp(I(a, "max", 60), 1, 2000)));
        if (S(a, "output") is { Length: > 0 } o)
        {
            var path = _ws.Resolve(o, mustExist: false, forWrite: true);
            File.WriteAllText(path, report);
            report += $"\n(report written to {_ws.Show(path)})";
        }
        if (report.Length > 12000)
        {
            var path = _ws.Resolve(Path.Combine(".okirom", "compare.txt"), mustExist: false, forWrite: true);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, report);
            return report[..11000] + $"\n... (full report in {_ws.Show(path)}; page it with file_read)";
        }
        return report;
    }

    // ------------------------------------------------------------------ datalog

    string Datalog(JsonObject a)
    {
        string action = Req(a, "action").ToLowerInvariant();
        switch (action)
        {
            case "protocols":
                return string.Join("\n", DatalogProtocol.All().Select(p => $"{p.Name}: {p.Description}, {p.Baud} baud")) +
                       "\nauto tries each in turn. The ROM must contain datalogging code (stock ROMs do not).";
            case "overlay": return Overlay(a);
            case "stats": return Stats(a);
            case "detect_layout":
                {
                    var target = Open(a);
                    var r = DatalogLayout.Detect(target.Rom);
                    if (r.Known != null) return $"{target.Name} speaks {r.Known.Name}: {r.Known.Description}\n\n{r.Report}";
                    return r.Protocol != null
                        ? $"{target.Name}: {r.Protocol.Description}\n\n{r.Report}"
                        : $"{target.Name}: no datalogging found.\n\n{r.Report}";
                }
        }
        var s = Session ?? throw new ToolException($"datalog {action} needs the desktop app (overlay and stats also work on a `log` file)");
        return s.Datalog(action, a);
    }

    List<LogFrame> Frames(JsonObject a)
    {
        if (S(a, "log") is { Length: > 0 } log) return LogFile.Load(_ws.Resolve(log));
        var s = Session ?? throw new ToolException("give `log` (a .csv or the tuning software datalog file)");
        var f = s.DatalogFrames().ToList();
        return f.Count == 0
            ? throw new ToolException("the app has no datalog frames yet: start logging (datalog action=start) or load a log")
            : f;
    }

    string Stats(JsonObject a)
    {
        var frames = Frames(a);
        var channels = (a["channels"] as JsonArray)?.Select(x => x!.ToString()).ToList() ?? [.. frames.SelectMany(f => f.Channels()).Distinct()];
        var sb = new StringBuilder($"{frames.Count} frames, {frames[^1].T - frames[0].T:0.0} s{(frames[0].Protocol != null ? $", {frames[0].Protocol}" : "")}\nchannel | min | avg | max | samples\n");
        foreach (var c in channels)
        {
            var v = frames.Select(f => f.Get(c)).Where(x => x is double d && !double.IsNaN(d)).Select(x => x!.Value).ToList();
            if (v.Count > 0) sb.AppendLine($"{c} | {v.Min():0.###} | {v.Average():0.###} | {v.Max():0.###} | {v.Count}");
        }
        return sb.ToString();
    }

    string Overlay(JsonObject a)
    {
        var t = Open(a);
        var item = Item(t, Req(a, "table"));
        if (!item.IsTable) throw new ToolException($"{item.Name} is not a table");
        string channel = S(a, "channel") ?? "afr";
        var frames = Frames(a);
        int minN = Math.Max(1, I(a, "min_samples", 3));
        var ov = LogOverlay.Compute(t.Defs, t.Rom, item, frames, channel);
        if (ov.Frames == 0) throw new ToolException($"no frame has both '{channel}' and the table's axis inputs ({ov.RowSource}, {ov.ColSource}); channels logged: {string.Join(", ", frames.SelectMany(f => f.Channels()).Distinct())}");
        var rowAxis = item.RowAxis == null ? [.. Enumerable.Range(0, item.Rows).Select(i => (double)i)] : RomData.AxisValues(t.Defs, t.Rom, item.RowAxis, item.Rows);
        var colAxis = item.ColAxis == null ? [.. Enumerable.Range(0, item.Cols).Select(i => (double)i)] : RomData.AxisValues(t.Defs, t.Rom, item.ColAxis, item.Cols);
        var sb = new StringBuilder(ov.Render(rowAxis, colAxis));
        if (a["target_afr"] != null)
        {
            double target = D(a, "target_afr", 14.7);
            var cells = RomData.Read(t.Defs, t.Rom, item);
            bool lambda = channel.Equals("lambda", StringComparison.OrdinalIgnoreCase);
            sb.AppendLine();
            sb.AppendLine($"Fuel suggestion for target {target} {(lambda ? "lambda" : "AFR")} (cells with {minN}+ samples): new = current x measured / target");
            int n = 0;
            for (int i = 0; i < ov.Mean.Length; i++)
            {
                if (ov.Count[i] < minN || double.IsNaN(ov.Mean[i])) continue;
                double factor = ov.Mean[i] / target;
                if (Math.Abs(factor - 1) < 0.01) continue;
                if (n++ < 60)
                    sb.AppendLine($"  [{i / item.Cols},{i % item.Cols}] {rowAxis[i / item.Cols]:0} x {colAxis[i % item.Cols]:0.#}: measured {ov.Mean[i]:0.00} ({ov.Count[i]}), " +
                                  $"{cells[i].Value:0.##} -> {cells[i].Value * factor:0.##} ({(factor - 1) * 100:+0.0;-0.0}%)");
            }
            sb.AppendLine(n == 0 ? "  every sampled cell is within 1% of the target" :
                $"  {n} cell(s) to change. Apply with cal_write cells=[[row,col,value],...] (review first: transient and closed-loop frames skew the averages).");
        }
        return sb.ToString();
    }
}
