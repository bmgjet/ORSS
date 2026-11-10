// Copyright (c) bmgjet. All rights reserved.
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using static OkiRomSim.Mcp.OkiTools;

namespace OkiRomSim.Mcp;

/// The naming standard every annotation follows - by a person, by one model or another - so a ROM named piece by piece reads as
/// one: code in lower_snake_case starting with the part of the ECU it belongs to, calibration data in PascalCase, RAM after what it
/// holds, constants in UPPER_SNAKE_CASE. `Problem` says what is wrong with a name; `IsPlaceholder` spots the names a disassembler
/// or an earlier pass made up (loc_1234, tbl_5e20, int_serial_rx_load_r7_2) that are still waiting for a real one.
public static class Naming
{
    public enum Kind { Code, Data, Ram, Const }

    /// The first word of a code label: the part of the ECU the routine belongs to.
    public static readonly string[] Areas =
    [
        "boot", "main", "tick", "int", "vcal", "timer", "wdt", "selftest", "stack", "clock",
        "crank", "cyl", "tdc", "rpm", "inj", "fuel", "fuelcut", "decel", "accel", "start", "cold", "warm",
        "ign", "spark", "dwell", "knock", "idle", "iacv", "vtec", "revlimit", "load",
        "o2", "ect", "iat", "map", "baro", "tps", "vss", "eld", "gear", "lockup", "at",
        "egr", "purge", "ac", "alt", "fan", "fpump", "cel", "mil", "dtc", "diag",
        "adc", "port", "serial", "dl", "cal", "tbl", "math", "util",
    ];
    static readonly HashSet<string> AreaSet = new(Areas, StringComparer.Ordinal);

    public const string Guide = """
NAMING STANDARD (Rom Sim Studio) - every name you give follows it; name_check tells you whether one does.

CODE LABELS (routines and the places they branch to): lower_snake_case, 2-6 words, at most 48 characters.
  <area>_<what it does>[_<detail>]      fuel_calc_base_pulse, ign_apply_knock_retard, idle_target_rpm_lookup
  The first word is the part of the ECU it belongs to - one of the AREAS below.
  A place inside a routine is named after the routine and what happens there:
      fuel_calc_base_pulse_cold_enrich, fuel_calc_base_pulse_done, crank_sync_lost
  Endings with a fixed meaning: _loop (the top of a loop), _done / _ret (the way out), _skip (jumped over), _wait (a delay),
  _check (decides something), _calc (works out a value), _lookup (reads a table), _apply (puts a value to use),
  _store (saves a result), _init (sets up).
  Interrupt handlers stay int_<source> (int_timer_1, int_serial_rx); the vectors (*_vec) are never renamed.
AREAS: boot main tick int vcal timer wdt selftest stack clock crank cyl tdc rpm inj fuel fuelcut decel accel start cold warm
       ign spark dwell knock idle iacv vtec revlimit load o2 ect iat map baro tps vss eld gear lockup at egr purge ac alt fan
       fpump cel mil dtc diag adc port serial dl cal tbl math util
  (tbl = table lookup helpers, math = arithmetic helpers, util = anything else shared, dl = the datalog link)

CALIBRATION DATA in the ROM (tables, maps, single settings, switches): PascalCase, no underscores, at most 40 characters.
  1-D / 2-D lookup tables end in Tbl:   CrankingFuelTbl, EctIdleRpmTbl, KnockRetardRpmTbl
  The fuel and ignition maps:           FuelLow, FuelHigh, IgnitionLow, IgnitionHigh
  A single setting:                     RevLimitLow, VtecRpmHigh, FuelCutRpm
  An on/off switch ends in Enable:      O2HeaterEnable, KnockSensorEnable
  Known acronyms keep their capitals:   VTEC, ECT, IAT, MAP, TPS, IACV, AFR, EGR, O2 (VTECRpmHigh is fine)
  Give its type, scaling and unit with cal_define (or a ";@" line above it) so it shows on the Calibration page.

RAM (an EQU at 0080h-047Fh): lower_snake_case after the value it holds, not where it is:
  rpm_period, map_raw, ect_filtered, fuel_pulse_final, knock_retard_now, idle_target_rpm
  A byte of flags ends in _flags; say what each bit means in a comment on the EQU line.
  ram_0b4 style names are placeholders: replace them once you know what is kept there.

CONSTANTS (an EQU that is a number, not an address): UPPER_SNAKE_CASE: MAP_COLS, RPM_ROWS, CRANK_TEETH.

COMMENTS: plain English after "; ". What it does and why, with units ("; coolant in degrees C x2 + 40").
  A routine gets a block comment above its label:
      ; fuel_calc_base_pulse: the base injector pulse from the fuel map, before the corrections.
      ; In: 0ACh rpm period, 0A3h MAP. Out: 146h the pulse (3.2 us counts). Uses: er0-er2.

NEVER: put the address in a name (fuel_5a3c), number duplicates (fuel_check_2), echo the instruction (load_r7, if_ne_goto,
  store_acch), use camelCase for code or snake_case for data, or rename the *_vec vectors.

WORKFLOW for annotating a ROM:
  1. annotate_todo        - what is still unnamed, most-used first, and how far the ROM is
  2. explore <label>      - follow the code: what it reads, writes, calls and drives
  3. rename old new       - a better name everywhere it is used (checked against this standard; the app shows it at once)
  4. comment <label> text - what it does, above it (where=above) or on the line
  5. cal_define           - name a table or setting found in the code, with its type, scaling, unit, category
  Repeat. Name what you are sure of; leave a placeholder rather than guess.
""";

    static readonly Regex CodeRx = new(@"^[a-z][a-z0-9]*(_[a-z0-9]+)+$", RegexOptions.CultureInvariant);
    static readonly Regex DataRx = new(@"^[A-Z][A-Za-z0-9]{2,39}$", RegexOptions.CultureInvariant);
    static readonly Regex RamRx = new(@"^[a-z][a-z0-9]*(_[a-z0-9]+)*$", RegexOptions.CultureInvariant);
    static readonly Regex ConstRx = new(@"^[A-Z][A-Z0-9]*(_[A-Z0-9]+)*$", RegexOptions.CultureInvariant);
    static readonly Regex VectorRx = new(@"^(int_\w+_vec|vcal_\d_vec|code_start)$", RegexOptions.CultureInvariant);

    static readonly Regex[] PlaceholderRx =
    [
        new(@"^(loc|sub|tbl|lbl|label|data|byte|word|code|ram|l|j|t)_?[0-9a-f]{3,4}$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
        new(@"_(?=[0-9a-f]*\d)[0-9a-f]{3,4}(_|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
        new(@"_(if_[a-z]+_)?goto(_|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
        new(@"_(load|store|clear|addb|subb|cmpb|cmp|movb|mov|stb|st|lb|ld|inc|dec|and|or|xor|sll|srl)_(r[0-7]|er[0-3]|acc|acch|accl|dp|dp_ind|x1|x2|usp|ssp|lrb|psw[hl]?|ie|ram[0-9a-f]+|rom|stbuf|srbuf|srstat\w*|tcon\d|tmr\d|tm\d|p\d|imm)(_|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
        new(@"_\d+$", RegexOptions.CultureInvariant),
    ];

    /// A name a disassembler or an earlier pass made up, still waiting for a real one.
    public static bool IsPlaceholder(string name) => !VectorRx.IsMatch(name) && PlaceholderRx.Any(r => r.IsMatch(name));

    /// A name that must stay as it is.
    public static bool IsReserved(string name) => VectorRx.IsMatch(name);

    /// What is wrong with a name for a kind of symbol, or null when it follows the standard.
    public static string? Problem(string name, Kind kind)
    {
        if (IsReserved(name)) return null;
        if (IsPlaceholder(name)) return $"'{name}' looks like a placeholder (an address, a number or an echoed instruction in it): name what it does";
        switch (kind)
        {
            case Kind.Code:
                if (name.Length > 48) return "a code label is at most 48 characters";
                if (!CodeRx.IsMatch(name)) return "a code label is lower_snake_case with at least two words: <area>_<what it does>";
                var area = name.Split('_')[0];
                if (!AreaSet.Contains(area)) return $"a code label starts with its area, one of: {string.Join(" ", Areas)} ('{area}' is not one)";
                return name.Split('_').Length > 7 ? "too many words: at most 6 after the area" : null;
            case Kind.Data:
                if (name.Contains('_')) return "calibration data is PascalCase, without underscores (CrankingFuelTbl)";
                if (!DataRx.IsMatch(name) || !name.Any(char.IsLower)) return "calibration data is PascalCase, 3-40 characters (RevLimitLow, CrankingFuelTbl)";
                return null;
            case Kind.Ram:
                if (name.Length > 40) return "a RAM name is at most 40 characters";
                if (!RamRx.IsMatch(name)) return "a RAM name is lower_snake_case after what it holds (rpm_period, ect_filtered)";
                if (Regex.IsMatch(name, @"^ram_?[0-9a-f]{2,4}$")) return "a RAM name says what is kept there, not where (rpm_period, not ram_0ac)";
                return null;
            default:
                return ConstRx.IsMatch(name) ? null : "a constant is UPPER_SNAKE_CASE (MAP_COLS)";
        }
    }

    public static Kind Parse(string? kind) => kind?.ToLowerInvariant() switch
    {
        "data" or "table" or "cal" or "calibration" or "setting" => Kind.Data,
        "ram" or "variable" => Kind.Ram,
        "const" or "constant" => Kind.Const,
        _ => Kind.Code,
    };
}

/// Annotating a ROM: the standard, what is left to name, and renames / comments that go through the app (when the ROM is open
/// there) so its editor, Lookup & breakpoints, disassembly and Calibration pages change as each one is made.
public sealed class AnnotateTools
{
    readonly Workspace _ws;
    readonly McpServer _server;

    public AnnotateTools(Workspace ws, McpServer server) { _ws = ws; _server = server; }

    const string PathArg = ".asm to work on (inside the app: leave out for the ROM open there)";

    public IEnumerable<McpTool> All()
    {
        yield return new McpTool("naming_guide",
            "The naming standard for labels, calibration data, RAM and constants, the comment style, and the annotation workflow. Read it before naming anything.",
            OkiTools.Schema(), _ => Naming.Guide);

        yield return new McpTool("name_check",
            "Whether a name follows the naming standard for its kind (code, data, ram, const), and what to change if not.",
            OkiTools.Schema(("name", "string", "the name", true), ("kind", "string", "code (default), data, ram or const", false)), NameCheck);

        yield return new McpTool("annotate_todo",
            "What is still unnamed (placeholders like loc_1234, tbl_5e20, int_serial_rx_load_r7_2), most-referenced first, with where each is and how far the ROM is named. Work through it with explore, rename and comment.",
            OkiTools.Schema(("path", "string", PathArg, false), ("kind", "string", "only code, data or ram", false), ("area", "string", "only names starting with this", false),
                            ("max", "integer", "how many (default 40)", false)), Todo);

        yield return new McpTool("rename",
            "Rename a label or EQU everywhere it is used (every source file of the build, comments included), checked against the naming standard. Inside the app the editor, Lookup & breakpoints, the disassembly and the Calibration pages show the new name at once; the result says how the build went.",
            OkiTools.Schema(("path", "string", PathArg, false), ("old", "string", "the name now", true), ("new", "string", "the new name", true),
                            ("kind", "string", "code, data, ram or const (default: from where it is defined)", false),
                            ("force", "boolean", "rename even when the new name breaks the standard (say why in a comment)", false)), Rename, ReadOnly: false);

        yield return new McpTool("comment",
            "Write a comment for a label or address: on its line (where=line, replacing the comment there) or as a block above it (where=above; replace=true swaps the block already there). Plain English, units included.",
            OkiTools.Schema(("path", "string", PathArg, false), ("target", "string", "label or hex address", true), ("text", "string", "the comment (several lines for a block)", true),
                            ("where", "string", "line or above (default above for a label, line for an address)", false), ("replace", "boolean", "above: replace the comment block directly above", false)), Comment, ReadOnly: false);
    }

    // ------------------------------------------------------------------ the build being annotated

    sealed record Build(AssemblyResult Asm, string MainFile, bool Session)
    {
        /// Each file's lines, read once (the kind of every name is looked up on its line).
        public Dictionary<string, string[]> Lines { get; } = new(StringComparer.OrdinalIgnoreCase);
    }

    Build Load(JsonObject a)
    {
        var p = S(a, "path");
        if ((string.IsNullOrWhiteSpace(p) || p.Equals("session", StringComparison.OrdinalIgnoreCase)) && _server.Session is { } s && s.Assembly is { } asm && s.RomPath != null)
            return new Build(asm, s.RomPath, true);
        if (string.IsNullOrWhiteSpace(p)) throw new ToolException("'path' is required (no ROM is built in an app session)");
        var file = _ws.Resolve(p);
        if (!file.EndsWith(".asm", StringComparison.OrdinalIgnoreCase)) throw new ToolException("annotate a .asm (disassemble a .bin into one first)");
        Program66k.UsePartOf(file);
        var r = new OkiAssembler(new AssemblerOptions { AllowFile = _ws.Allows, ReadFile = f => _server.Session?.SourceText(f) }).AssembleFile(file);
        return new Build(r, file, false);
    }

    string Read(string path) => _server.Session?.SourceText(path) ?? File.ReadAllText(path);

    /// The source files of a build: every file it read, the main one first.
    static List<string> Files(Build b) =>
        [.. new[] { b.MainFile }.Concat(b.Asm.SourceMap.Select(e => e.File)).Concat(b.Asm.Symbols.Values.Select(s => s.File).OfType<string>())
            .Where(f => f.Length > 0).Select(Path.GetFullPath).Distinct(StringComparer.OrdinalIgnoreCase).Where(File.Exists)];

    /// Write the changed files: through the app in one go when it has the ROM open (one refresh), else to the disk and assembled to check.
    string WriteAll(Build b, List<(string Path, string Text)> changed, string what)
    {
        if (changed.Count == 0) return "nothing changed";
        foreach (var (p, _) in changed) _ws.Resolve(p, mustExist: true, forWrite: true);
        if (_server.Session?.SetSources(changed, what) is { } note) return note;
        foreach (var (p, t) in changed) OkiRomSim.Core.SafeFile.WriteAllText(p, t);
        Program66k.UsePartOf(b.MainFile);
        var r = new OkiAssembler(new AssemblerOptions { AllowFile = _ws.Allows }).AssembleFile(b.MainFile);
        var errors = r.Diagnostics.Where(d => d.Severity == Severity.Error).ToList();
        return errors.Count == 0 ? "assembles cleanly" : $"the build now FAILS ({errors.Count} error(s)):\n" + string.Join("\n", errors.Take(8).Select(d => $"  {_ws.Show(d.File)}:{d.Line}: {d.Message}"));
    }

    Naming.Kind KindOf(Build b, SymbolInfo s)
    {
        if (s.Kind == SymbolKind.Equate)
            return s.Name.All(c => !char.IsLower(c)) ? Naming.Kind.Const : s.Value is >= 0x80 and < 0x480 ? Naming.Kind.Ram : Naming.Kind.Const;
        if (b.Session && _server.Session!.Definitions().Items.Any(i => i.Address == (int)s.Value)) return Naming.Kind.Data;
        // a label on a DB / DW (or with one on the next line) is data
        if (s.File != null && s.Line > 0)
        {
            try
            {
                if (!b.Lines.TryGetValue(s.File, out var lines)) b.Lines[s.File] = lines = Read(s.File).Replace("\r\n", "\n").Split('\n');
                for (int i = s.Line - 1; i < Math.Min(lines.Length, s.Line + 1); i++)
                {
                    var t = lines[i];
                    int c = t.IndexOf(';'); if (c >= 0) t = t[..c];
                    if (i == s.Line - 1 && t.Contains(':')) t = t[(t.IndexOf(':') + 1)..];
                    if (Regex.IsMatch(t, @"^\s*(DB|DW|DS|DEFB|DEFW)\b", RegexOptions.IgnoreCase)) return Naming.Kind.Data;
                    if (t.Trim().Length > 0) break;
                }
            }
            catch (IOException) { }
        }
        return Naming.Kind.Code;
    }

    // ------------------------------------------------------------------ tools

    string NameCheck(JsonObject a)
    {
        var name = Req(a, "name").Trim();
        var kind = Naming.Parse(S(a, "kind"));
        return Naming.Problem(name, kind) is { } p ? $"NO ({kind.ToString().ToLowerInvariant()}): {p}" : $"ok: '{name}' follows the standard for {kind.ToString().ToLowerInvariant()}";
    }

    string Todo(JsonObject a)
    {
        var b = Load(a);
        int max = Math.Clamp(I(a, "max", 40), 1, 400);
        var only = S(a, "kind") is { Length: > 0 } k ? Naming.Parse(k) : (Naming.Kind?)null;
        var area = S(a, "area");
        var files = Files(b);
        var text = string.Join("\n", files.Select(f => { try { return Read(f); } catch (IOException) { return ""; } }));
        var named = b.Asm.Symbols.Values.Where(s => s.Kind is SymbolKind.Label or SymbolKind.Equate && !Naming.IsReserved(s.Name)
                                                    && !s.Name.StartsWith("XP_", StringComparison.Ordinal) && s.File != null).ToList();
        var todo = named.Where(s => Naming.IsPlaceholder(s.Name)).Select(s => (Sym: s, Kind: KindOf(b, s))).ToList();
        int total = named.Count, left = todo.Count;
        todo = [.. todo.Where(t => (only == null || t.Kind == only) && (area == null || t.Sym.Name.StartsWith(area, StringComparison.OrdinalIgnoreCase)))];
        // every word of the source counted once, so each name's uses are a look-up
        var uses = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (Match m in Regex.Matches(text, @"(?<![\w$@.])[A-Za-z_][\w]*")) uses[m.Value] = uses.GetValueOrDefault(m.Value) + 1;
        int Refs(string n) => Math.Max(0, uses.GetValueOrDefault(n) - 1);
        var rows = todo.Select(t => (t.Sym, t.Kind, Refs: Refs(t.Sym.Name)))
                       .OrderBy(t => t.Kind).ThenByDescending(t => t.Refs).ThenBy(t => t.Sym.Value).Take(max).ToList();
        var sb = new StringBuilder();
        sb.AppendLine($"{total - left} of {total} names follow the standard ({(total == 0 ? 100 : 100.0 * (total - left) / total):0.#} %); {left} placeholder(s) left{(todo.Count != left ? $", {todo.Count} matching" : "")}.");
        if (rows.Count == 0) { sb.AppendLine("nothing left to name here."); return sb.ToString(); }
        sb.AppendLine("kind  address  refs  name  (file:line)");
        foreach (var (s, kind, refs) in rows)
            sb.AppendLine($"{kind.ToString().ToLowerInvariant(),-5} {s.Value:X4}h  {refs,4}  {s.Name}  ({_ws.Show(s.File!)}:{s.Line})");
        sb.AppendLine("Next: explore the first one, then rename it (and comment it). naming_guide has the standard.");
        return sb.ToString();
    }

    string Rename(JsonObject a)
    {
        var b = Load(a);
        var old = Req(a, "old").Trim();
        var neu = Req(a, "new").Trim();
        if (old == neu) return "the same name";
        if (!b.Asm.Symbols.TryGetValue(old, out var sym))
        {
            var near = b.Asm.Symbols.Keys.Where(k => k.Equals(old, StringComparison.OrdinalIgnoreCase)).FirstOrDefault();
            throw new ToolException($"no label or EQU '{old}'{(near != null ? $" (names are case-sensitive: '{near}'?)" : "")}");
        }
        if (Naming.IsReserved(old)) throw new ToolException($"'{old}' is a vector name and stays as it is");
        if (b.Asm.Symbols.ContainsKey(neu)) throw new ToolException($"'{neu}' is already used (at {b.Asm.Symbols[neu].Value:X4}h): pick another");
        var kind = S(a, "kind") is { Length: > 0 } k ? Naming.Parse(k) : KindOf(b, sym);
        if (Naming.Problem(neu, kind) is { } problem && !B(a, "force", false))
            throw new ToolException($"'{neu}' does not follow the naming standard for {kind.ToString().ToLowerInvariant()}: {problem}. (naming_guide; force=true if there is a good reason)");
        var rx = new Regex($@"(?<![\w$@.]){Regex.Escape(old)}(?!\w)", RegexOptions.CultureInvariant);
        var changed = new List<(string Path, string Text)>();
        int count = 0;
        foreach (var f in Files(b))
        {
            string t;
            try { t = Read(f); } catch (IOException) { continue; }
            int n = rx.Matches(t).Count;
            if (n == 0) continue;
            count += n;
            changed.Add((f, rx.Replace(t, neu)));
        }
        var note = WriteAll(b, changed, $"rename {old} -> {neu}");
        return $"renamed {old} -> {neu} ({kind.ToString().ToLowerInvariant()} at {sym.Value:X4}h): {count} place(s) in {changed.Count} file(s)\n{note}";
    }

    string Comment(JsonObject a)
    {
        var b = Load(a);
        var target = Req(a, "target").Trim();
        var text = (S(a, "text") ?? "").Replace("\r\n", "\n").Trim('\n');
        if (text.Length == 0) throw new ToolException("'text' is empty");
        string file; int line; bool isLabel;
        if (b.Asm.Symbols.TryGetValue(target, out var sym) && sym.File != null && sym.Line > 0) { file = sym.File; line = sym.Line; isLabel = true; }
        else if (TryHex(target, out int addr) && b.Asm.Lookup(addr) is { } e) { file = e.File; line = e.Line; isLabel = false; }
        else throw new ToolException($"no label '{target}' and no source line at that address");
        var where = (S(a, "where") ?? (isLabel ? "above" : "line")).ToLowerInvariant();
        var raw = Read(file);
        string nl = raw.Contains("\r\n") ? "\r\n" : "\n";
        var lines = raw.Replace("\r\n", "\n").Split('\n').ToList();
        if (line < 1 || line > lines.Count) throw new ToolException($"{_ws.Show(file)} has no line {line}");
        if (where == "line")
        {
            var body = lines[line - 1];
            int c = CommentStart(body);
            var code = (c >= 0 ? body[..c] : body).TrimEnd();
            var one = text.Replace("\n", " ");
            lines[line - 1] = code.Length == 0 ? "; " + one : code.PadRight(Math.Max(code.Length + 2, 40)) + "; " + one;
        }
        else if (where == "above")
        {
            int at = line - 1;
            if (B(a, "replace", false))
                while (at > 0 && lines[at - 1].TrimStart().StartsWith(';') && !lines[at - 1].TrimStart().StartsWith(";@")) { lines.RemoveAt(at - 1); at--; }
            // above any ";@" definition lines that belong to the label
            while (at > 0 && lines[at - 1].TrimStart().StartsWith(";@")) at--;
            lines.InsertRange(at, text.Split('\n').Select(t => "; " + t.TrimStart(';', ' ')));
        }
        else throw new ToolException("where is line or above");
        var note = WriteAll(b, [(Path.GetFullPath(file), string.Join(nl, lines))], $"comment {target}");
        return $"comment {(where == "line" ? "on" : "above")} {target} ({_ws.Show(file)}:{line})\n{note}";
    }

    /// Where a line's comment starts (a ';' outside quotes), or -1.
    static int CommentStart(string s)
    {
        bool q = false; char qc = '\0';
        for (int i = 0; i < s.Length; i++)
        {
            char ch = s[i];
            if (q) { if (ch == qc) q = false; continue; }
            if (ch is '\'' or '"') { q = true; qc = ch; continue; }
            if (ch == ';') return i;
        }
        return -1;
    }

    static bool TryHex(string t, out int v)
    {
        t = t.Trim().TrimStart('@');
        if (t.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) t = t[2..];
        if (t.EndsWith('h') || t.EndsWith('H')) t = t[..^1];
        return int.TryParse(t, System.Globalization.NumberStyles.HexNumber, null, out v);
    }
}
