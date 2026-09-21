using System.Text;

namespace OkiRomSim.Assembler;

public enum Severity { Info, Warning, Error }

public sealed record Diagnostic(Severity Severity, string File, int Line, int Col, string Message)
{
    public override string ToString() =>
        $"{File}({Line},{Col + 1}): {Severity.ToString().ToLowerInvariant()}: {Message}";
}

public enum SymbolKind { Label, Equate, Sfr, Define }

public sealed record SymbolInfo(string Name, long Value, SymbolKind Kind, string? File, int Line);

/// One emitted statement: where it came from and what it produced.
public sealed record SourceMapEntry(int Address, int Length, string File, int Line, string Module);

/// A ";@ ..." annotation comment and the address it sits at. Used by the calibration layer to describe settings and tables; ordinary assemblers ignore it because it is just a comment.
public sealed record Annotation(int Address, string Text, string File, int Line);

public sealed class ModuleUsage
{
    public required string Name;
    public int Bytes;
    public List<(int Start, int End)> Ranges { get; } = new();
    internal void Add(int addr, int len)
    {
        Bytes += len;
        if (Ranges.Count > 0 && Ranges[^1].End == addr) Ranges[^1] = (Ranges[^1].Start, addr + len);
        else Ranges.Add((addr, addr + len));
    }
}

public sealed class AssemblerOptions
{
    /// Symbols predefined before assembly (feature flags from a firmware project, -D on the CLI).
    public Dictionary<string, long> Defines { get; } = new();
    /// Include search paths, in addition to the including file's directory.
    public List<string> IncludePaths { get; } = new();
    public int RomSize { get; set; } = 0x8000;
    public byte FillByte { get; set; } = 0xFF;
    /// Lenient mode: undefined symbols, out-of-range branches and duplicate labels become warnings (producing a silently-wrong image) instead of errors.
    public bool LenientMode { get; set; }
    /// Warn when an 8-bit operand is outside -128..255 (it is silently truncated).
    public bool WarnTruncation { get; set; } = true;
    /// Virtual file system hook (the IDE assembles unsaved editor buffers).
    public Func<string, string?>? ReadFile { get; set; }
    /// Sandbox for include / incbin (the MCP server confines agents to their workspace): a file this refuses is an error rather than being read.
    public Func<string, bool>? AllowFile { get; set; }
}

public sealed class AssemblyResult
{
    public required byte[] Image;
    public required bool[] Used;
    public List<Diagnostic> Diagnostics { get; } = new();
    public Dictionary<string, SymbolInfo> Symbols { get; } = new();
    public List<SourceMapEntry> SourceMap { get; } = new();
    public List<Annotation> Annotations { get; } = new();
    public Dictionary<string, ModuleUsage> Modules { get; } = new();
    public List<string> Files { get; } = new();
    public bool Success => Diagnostics.All(d => d.Severity != Severity.Error);
    public int UsedBytes => Used.Count(u => u);

    public IEnumerable<(int Start, int End)> FreeRegions(int minSize = 16)
    {
        int? s = null;
        for (int a = 0; a <= Used.Length; a++)
        {
            bool free = a < Used.Length && !Used[a] && Image[a] == 0xFF;
            if (free && s == null) s = a;
            if (!free && s != null) { if (a - s.Value >= minSize) yield return (s.Value, a); s = null; }
        }
    }

    public SourceMapEntry? Lookup(int address)
    {
        // entries are appended in address order within a region; binary search is not safe
        // across ORGs, so keep a lazily built index.
        _index ??= BuildIndex();
        return address >= 0 && address < _index.Length ? _index[address] : null;
    }
    SourceMapEntry?[]? _index;
    SourceMapEntry?[] BuildIndex()
    {
        var idx = new SourceMapEntry?[Image.Length];
        foreach (var e in SourceMap)
            for (int i = 0; i < e.Length && e.Address + i < idx.Length; i++) idx[e.Address + i] ??= e;
        return idx;
    }

    public string LabelAt(int address) =>
        Symbols.Values.Where(s => s.Kind == SymbolKind.Label && s.Value == address).Select(s => s.Name).FirstOrDefault() ?? "";
}

/// Two-pass assembler for the OKI MSM66207, plus extensions for modular firmware: include, if/ifdef/else/endif, module/endmodule, ds, align, incbin, assert, error/warning, string DB, romsize.
public sealed class OkiAssembler
{
    readonly AssemblerOptions _opt;
    public OkiAssembler(AssemblerOptions? options = null) { _opt = options ?? new AssemblerOptions(); }

    /// SFR names the assembler predefines. The MSM66207 set by default; a processor profile (OkiRomSim.Core.ProcessorProfile) can replace it for another 66K part.
    public static IReadOnlyDictionary<string, int> Sfrs { get; private set; } = BuildSfrs();
    public static IReadOnlyDictionary<string, int> DefaultSfrs { get; } = BuildSfrs();
    public static void UseSfrs(IReadOnlyDictionary<string, int>? sfrs) =>
        Sfrs = sfrs is { Count: > 0 } ? new Dictionary<string, int>(sfrs) : DefaultSfrs;
    static Dictionary<string, int> BuildSfrs()
    {
        var d = new Dictionary<string, int>();
        int i = 0;
        void mk(string n) => d[n] = i++;
        i = 0x00; foreach (var n in new[] { "ASSP", "SSPH", "ALRB", "LRBH", "PSW", "zp_PSWH", "ACC", "ACCH" }) mk(n);
        i = 0x10; foreach (var n in new[] { "SBYCON", "WDT", "PRPHF", "STPACP" }) mk(n);
        i = 0x18; foreach (var n in new[] { "IRQ", "IRQH", "IE", "IEH", "EXION" }) mk(n);
        i = 0x20; foreach (var n in new[] { "P0", "P0IO", "P1", "P1IO", "P2", "P2IO", "P2SF" }) mk(n);
        i = 0x28; foreach (var n in new[] { "P3", "P3IO", "P3SF" }) mk(n);
        i = 0x2c; foreach (var n in new[] { "P4", "P4IO", "P4SF", "P5",
            "TM0", "TM0H", "TMR0", "TMR0H", "TM1", "TM1H", "TMR1", "TMR1H",
            "TM2", "TM2H", "TMR2", "TMR2H", "TM3", "TM3H", "TMR3", "TMR3H",
            "TCON0", "TCON1", "TCON2", "TCON3" }) mk(n);
        i = 0x46; mk("TRNSIT");
        i = 0x48; foreach (var n in new[] { "STTM", "STTMR", "STTMC" }) mk(n);
        i = 0x4c; foreach (var n in new[] { "SRTM", "SRTMR", "SRTMC" }) mk(n);
        i = 0x50; foreach (var n in new[] { "STCON", "STBUF" }) mk(n);
        i = 0x54; foreach (var n in new[] { "SRCON", "SRBUF", "SRSTAT" }) mk(n);
        i = 0x58; foreach (var n in new[] { "ADSCAN", "ADSEL" }) mk(n);
        i = 0x60;
        for (int k = 0; k < 8; k++) { mk($"ADCR{k}"); mk($"ADCR{k}H"); }
        foreach (var n in new[] { "PWMC0", "PWMC0H", "PWMR0", "PWMR0H", "PWMC1", "PWMC1H", "PWMR1", "PWMR1H", "PWCON0" }) mk(n);
        i = 0x7a; mk("PWCON1");
        return d;
    }

    // ------------------------------------------------------------------ state
    sealed class Src { public required string Path; public required string[] Lines; }
    sealed class CondFrame { public bool Active; public bool Taken; public bool ParentActive; public bool SeenElse; public int Line; public string File = ""; }

    readonly Dictionary<string, long> _syms = new(StringComparer.Ordinal);
    readonly Dictionary<string, SymbolInfo> _symInfo = new(StringComparer.Ordinal);
    readonly HashSet<string> _definedThisPass = new(StringComparer.Ordinal);
    readonly Dictionary<string, Src> _files = new(StringComparer.Ordinal);
    AssemblyResult _res = null!;
    bool _final;
    long _pc;
    int _romSize;
    string _module = "(main)";
    readonly Stack<string> _moduleStack = new();
    readonly HashSet<(string, int, string)> _diagSeen = new();
    int[] _owner = Array.Empty<int>(); // line id that wrote each byte (final pass), for overlap detection
    readonly List<string> _ownerDesc = new();

    public AssemblyResult AssembleFile(string path)
    {
        var full = Path.GetFullPath(path);
        return Run(full, null);
    }

    public AssemblyResult AssembleText(string text, string virtualPath = "input.asm")
    {
        var full = Path.GetFullPath(virtualPath);
        return Run(full, text);
    }

    AssemblyResult Run(string root, string? rootText)
    {
        _romSize = _opt.RomSize;
        _res = new AssemblyResult { Image = new byte[_romSize], Used = new bool[_romSize] };
        Array.Fill(_res.Image, _opt.FillByte);
        if (rootText != null) _files[root] = new Src { Path = root, Lines = SplitLines(rootText) };
        for (int pass = 1; pass <= 2; pass++)
        {
            _final = pass == 2;
            _pc = 0;
            _module = "(main)";
            _moduleStack.Clear();
            _definedThisPass.Clear();
            if (_final)
            {
                _owner = new int[_romSize];
                _ownerDesc.Clear(); _ownerDesc.Add("");
                // keep label values from pass 1 for forward references, but reset SFR/defines
            }
            foreach (var (k, v) in Sfrs) SetSym(k, v, SymbolKind.Sfr, null, 0, silent: true);
            foreach (var (k, v) in _opt.Defines) SetSym(k, v, SymbolKind.Define, null, 0, silent: true);
            var conds = new Stack<CondFrame>();
            try { ProcessFile(root, conds, 0); }
            catch (FatalAsm) { break; }
            if (conds.Count > 0)
            {
                var c = conds.Peek();
                Report(Severity.Error, c.File, c.Line, 0, "'if' without matching 'endif'");
            }
            if (_moduleStack.Count > 0) Report(Severity.Error, root, 0, 0, $"module '{_module}' not closed with endmodule");
            if (_res.Diagnostics.Any(d => d.Severity == Severity.Error) && !_final) break;
        }
        foreach (var (k, info) in _symInfo) _res.Symbols[k] = info with { Value = _syms[k] };
        return _res;
    }

    sealed class FatalAsm : Exception { }

    static string[] SplitLines(string text) => text.Replace("\r\n", "\n").Split('\n');

    Src? LoadSrc(string path)
    {
        if (_files.TryGetValue(path, out var s)) return s;
        string? text = _opt.ReadFile?.Invoke(path);
        if (text == null)
        {
            if (!File.Exists(path)) return null;
            text = File.ReadAllText(path, Encoding.Latin1);
        }
        s = new Src { Path = path, Lines = SplitLines(text) };
        _files[path] = s;
        if (!_res.Files.Contains(path)) _res.Files.Add(path);
        return s;
    }

    string? ResolveInclude(string fromFile, string name)
    {
        var cands = new List<string> { Path.Combine(Path.GetDirectoryName(fromFile) ?? ".", name) };
        cands.AddRange(_opt.IncludePaths.Select(p => Path.Combine(p, name)));
        foreach (var c in cands)
        {
            var f = Path.GetFullPath(c);
            if (_files.ContainsKey(f) || (_opt.ReadFile?.Invoke(f) != null) || File.Exists(f))
            {
                if (_opt.AllowFile != null && !_opt.AllowFile(f)) throw new AsmException($"'{name}' is outside the folders this assembly may read");
                return f;
            }
        }
        return null;
    }

    void ProcessFile(string path, Stack<CondFrame> conds, int depth)
    {
        if (depth > 32) { Report(Severity.Error, path, 0, 0, "include nesting too deep (recursive include?)"); throw new FatalAsm(); }
        var src = LoadSrc(path);
        if (src == null) { Report(Severity.Error, path, 0, 0, "cannot open file"); throw new FatalAsm(); }
        if (depth == 0 && !_res.Files.Contains(path)) _res.Files.Insert(0, path);
        for (int ln = 0; ln < src.Lines.Length; ln++)
        {
            try { ProcessLine(src, ln + 1, src.Lines[ln], conds, depth); }
            catch (AsmException ex) { Report(Severity.Error, path, ln + 1, 0, ex.Message); }
        }
    }

    bool Active(Stack<CondFrame> conds) => conds.Count == 0 || conds.Peek().Active;

    static bool IsWord(Token t, string w) =>
        (t.Kind == Tk.Symbol || t.Kind == Tk.Keyword || t.Kind == Tk.Mnemonic) && t.Text.Equals(w, StringComparison.OrdinalIgnoreCase);

    static readonly HashSet<string> CondWords = new(StringComparer.OrdinalIgnoreCase)
    { "if", "ifdef", "ifndef", "elseif", "elif", "else", "endif" };
    static readonly HashSet<string> Directives = new(StringComparer.OrdinalIgnoreCase)
    { "include", "incbin", "module", "endmodule", "ds", "align", "assert", "error", "warning", "define", "undef", "message" };

    void ProcessLine(Src src, int line, string text, Stack<CondFrame> conds, int depth)
    {
        // ";@ key=value ..." annotations describe calibration items at the current address.
        int at = text.IndexOf(";@", StringComparison.Ordinal);
        if (at >= 0 && _final && Active(conds))
            _res.Annotations.Add(new Annotation((int)_pc, text[(at + 2)..].Trim(), src.Path, line));
        var toks = Lexer.Tokenize(text, out var lexErr);
        if (lexErr != null)
        {
            if (Active(conds)) Report(Severity.Error, src.Path, line, 0, lexErr);
            return;
        }
        int p = 0;
        // conditional directives are recognised even when inactive
        if (toks[0].Kind == Tk.Symbol && CondWords.Contains(toks[0].Text) && !(toks[1].Kind == Tk.Punct && toks[1].Text == ":")
            && !IsWord(toks[1], "equ"))
        {
            HandleCond(src, line, toks, conds);
            return;
        }
        if (!Active(conds)) return;

        // labels (any number, "name:")
        while (toks[p].Kind == Tk.Symbol && toks[p + 1].Kind == Tk.Punct && toks[p + 1].Text == ":")
        {
            DefineLabel(toks[p].Text, _pc, src.Path, line, toks[p].Col);
            p += 2;
        }
        var t = toks[p];
        if (t.Kind == Tk.End) return;

        // SYMBOL EQU expr
        if (t.Kind == Tk.Symbol && toks[p + 1].Kind == Tk.Keyword && toks[p + 1].Text == "EQU")
        {
            int q = p + 2;
            var e = ExprParser.Parse(toks, ref q, extended: true);
            ExpectEnd(toks, q);
            long v = Eval(e, src.Path, line, out _);
            if (_symInfo.TryGetValue(t.Text, out var old) && old.Kind is SymbolKind.Label && _definedThisPass.Contains(t.Text))
                Report(Severity.Error, src.Path, line, t.Col, $"'{t.Text}' already defined as a label ({old.File}:{old.Line})");
            SetSym(t.Text, v, SymbolKind.Equate, src.Path, line);
            return;
        }

        if (t.Kind == Tk.Symbol && Directives.Contains(t.Text))
        {
            HandleDirective(src, line, t.Text.ToLowerInvariant(), toks, p + 1, conds, depth);
            return;
        }

        switch (t.Kind)
        {
            case Tk.Keyword when t.Text == "ORG":
                {
                    int q = p + 1;
                    var e = ExprParser.Parse(toks, ref q, true);
                    ExpectEnd(toks, q);
                    long v = Eval(e, src.Path, line, out var undef);
                    if (undef) throw new AsmException("org address must be defined before use");
                    if (v < 0 || v > _romSize) throw new AsmException($"org {v:X} outside ROM (0..{_romSize:X})");
                    _pc = v;
                    return;
                }
            case Tk.Keyword when t.Text == "DB" || t.Text == "DW":
                {
                    var bytes = new List<byte>();
                    int q = p + 1;
                    while (true)
                    {
                        if (toks[q].Kind == Tk.String && t.Text == "DB")
                        {
                            bytes.AddRange(Encoding.Latin1.GetBytes(toks[q].Text)); q++;
                        }
                        else
                        {
                            var e = ExprParser.Parse(toks, ref q, true);
                            long v = Eval(e, src.Path, line, out _);
                            if (t.Text == "DB")
                            {
                                if (_final && _opt.WarnTruncation && (v < -128 || v > 255))
                                    Report(Severity.Warning, src.Path, line, e.Col, $"DB value {v} truncated to {v & 0xFF:X2}h");
                                bytes.Add((byte)v);
                            }
                            else
                            {
                                if (_final && _opt.WarnTruncation && (v < -32768 || v > 65535))
                                    Report(Severity.Warning, src.Path, line, e.Col, $"DW value {v} truncated");
                                bytes.Add((byte)v); bytes.Add((byte)(v >> 8));
                            }
                        }
                        if (toks[q].Kind == Tk.Punct && toks[q].Text == ",") { q++; continue; }
                        break;
                    }
                    ExpectEnd(toks, q);
                    Emit(bytes.ToArray(), src.Path, line);
                    return;
                }
            case Tk.Keyword when t.Text == "PRELOAD":
                {
                    if (toks[p + 1].Kind != Tk.String) throw new AsmException("preload expects a quoted file name");
                    if (_final)
                    {
                        var f = ResolveInclude(src.Path, toks[p + 1].Text);
                        if (f == null) throw new AsmException($"preload: can't open {toks[p + 1].Text}");
                        var data = File.ReadAllBytes(f);
                        Array.Copy(data, _res.Image, Math.Min(data.Length, _romSize));
                    }
                    return;
                }
            case Tk.Keyword when t.Text == "ROMSIZE":
                {
                    int q = p + 1;
                    long v = Eval(ExprParser.Parse(toks, ref q, true), src.Path, line, out _);
                    if (v != _romSize) Report(Severity.Warning, src.Path, line, 0, $"romsize {v} ignored; project ROM size is {_romSize}");
                    return;
                }
            case Tk.Mnemonic:
                AssembleInstruction(src, line, toks, p);
                return;
        }
        throw new AsmException(t.Kind == Tk.Symbol
            ? $"unknown instruction or directive '{t.Text}' (missing ':' after a label?)"
            : $"syntax error at '{t.Text}'");
    }

    void ExpectEnd(List<Token> toks, int q)
    {
        if (toks[q].Kind != Tk.End) throw new AsmException($"unexpected '{toks[q].Text}'");
    }

    void HandleCond(Src src, int line, List<Token> toks, Stack<CondFrame> conds)
    {
        var w = toks[0].Text.ToLowerInvariant();
        bool parent = Active(conds);
        bool EvalCond()
        {
            int q = 1;
            if (w is "ifdef" or "ifndef")
            {
                if (toks[1].Kind != Tk.Symbol) throw new AsmException($"{w} expects a symbol name");
                bool def = IsDefined(toks[1].Text);
                return w == "ifdef" ? def : !def;
            }
            var e = ExprParser.Parse(toks, ref q, true);
            ExpectEnd(toks, q);
            var ctx = MakeCtx();
            long v = e.Eval(ctx);
            if (ctx.Undefined.Count > 0)
                throw new AsmException($"'{ctx.Undefined[0]}' must be defined before it is used in a condition (use ifdef or defined())");
            return v != 0;
        }
        switch (w)
        {
            case "if": case "ifdef": case "ifndef":
                {
                    bool v = parent && EvalCond();
                    conds.Push(new CondFrame { ParentActive = parent, Active = v, Taken = v, Line = line, File = src.Path });
                    return;
                }
            case "elseif": case "elif":
                {
                    if (conds.Count == 0) throw new AsmException("elseif without if");
                    var f = conds.Peek();
                    if (f.SeenElse) throw new AsmException("elseif after else");
                    if (f.Taken || !f.ParentActive) { f.Active = false; return; }
                    f.Active = EvalCond(); f.Taken = f.Active;
                    return;
                }
            case "else":
                {
                    if (conds.Count == 0) throw new AsmException("else without if");
                    var f = conds.Peek();
                    if (f.SeenElse) throw new AsmException("duplicate else");
                    f.SeenElse = true;
                    f.Active = f.ParentActive && !f.Taken; f.Taken = true;
                    return;
                }
            case "endif":
                if (conds.Count == 0) throw new AsmException("endif without if");
                conds.Pop();
                return;
        }
    }

    void HandleDirective(Src src, int line, string d, List<Token> toks, int q, Stack<CondFrame> conds, int depth)
    {
        switch (d)
        {
            case "include":
                {
                    if (toks[q].Kind != Tk.String) throw new AsmException("include expects a quoted file name");
                    var f = ResolveInclude(src.Path, toks[q].Text) ?? throw new AsmException($"include file not found: {toks[q].Text}");
                    int before = conds.Count;
                    ProcessFile(f, conds, depth + 1);
                    if (conds.Count != before) Report(Severity.Error, f, 0, 0, "unbalanced if/endif in included file");
                    return;
                }
            case "incbin":
                {
                    if (toks[q].Kind != Tk.String) throw new AsmException("incbin expects a quoted file name");
                    var f = ResolveInclude(src.Path, toks[q].Text) ?? throw new AsmException($"incbin file not found: {toks[q].Text}");
                    Emit(File.ReadAllBytes(f), src.Path, line);
                    return;
                }
            case "module":
                {
                    if (toks[q].Kind != Tk.Symbol) throw new AsmException("module expects a name");
                    _moduleStack.Push(_module);
                    _module = toks[q].Text;
                    if (_final && !_res.Modules.ContainsKey(_module)) _res.Modules[_module] = new ModuleUsage { Name = _module };
                    return;
                }
            case "endmodule":
                if (_moduleStack.Count == 0) throw new AsmException("endmodule without module");
                _module = _moduleStack.Pop();
                return;
            case "ds":
                {
                    long n = Eval(ExprParser.Parse(toks, ref q, true), src.Path, line, out var u);
                    if (u) throw new AsmException("ds size must be defined before use");
                    long fill = _opt.FillByte;
                    if (toks[q].Kind == Tk.Punct && toks[q].Text == ",") { q++; fill = Eval(ExprParser.Parse(toks, ref q, true), src.Path, line, out _); }
                    ExpectEnd(toks, q);
                    if (n < 0 || n > _romSize) throw new AsmException("bad ds size");
                    var b = new byte[n]; Array.Fill(b, (byte)fill);
                    Emit(b, src.Path, line);
                    return;
                }
            case "align":
                {
                    long n = Eval(ExprParser.Parse(toks, ref q, true), src.Path, line, out _);
                    if (n <= 0) throw new AsmException("align must be positive");
                    long pad = (n - _pc % n) % n;
                    var b = new byte[pad]; Array.Fill(b, _opt.FillByte);
                    Emit(b, src.Path, line);
                    return;
                }
            case "assert":
                {
                    var e = ExprParser.Parse(toks, ref q, true);
                    string msg = "assertion failed";
                    if (toks[q].Kind == Tk.Punct && toks[q].Text == "," && toks[q + 1].Kind == Tk.String) msg = toks[q + 1].Text;
                    if (_final && Eval(e, src.Path, line, out _) == 0) Report(Severity.Error, src.Path, line, 0, msg);
                    return;
                }
            case "error":
            case "warning":
            case "message":
                {
                    string msg = toks[q].Kind == Tk.String ? toks[q].Text : d;
                    if (_final) Report(d == "error" ? Severity.Error : d == "warning" ? Severity.Warning : Severity.Info, src.Path, line, 0, msg);
                    return;
                }
            case "define":
                {
                    if (toks[q].Kind != Tk.Symbol) throw new AsmException("define expects a symbol name");
                    string name = toks[q].Text; q++;
                    long v = 1;
                    if (toks[q].Kind != Tk.End) v = Eval(ExprParser.Parse(toks, ref q, true), src.Path, line, out _);
                    SetSym(name, v, SymbolKind.Define, src.Path, line);
                    return;
                }
            case "undef":
                if (toks[q].Kind == Tk.Symbol) { _syms.Remove(toks[q].Text); _symInfo.Remove(toks[q].Text); }
                return;
        }
    }

    bool IsDefined(string name) => _syms.ContainsKey(name) &&
        (!_symInfo.TryGetValue(name, out var i) || i.Kind != SymbolKind.Label || _definedThisPass.Contains(name));

    EvalContext MakeCtx() => new()
    {
        Pc = _pc,
        Lookup = n => _syms.TryGetValue(n, out var v) ? (true, v) : (false, 0),
        IsDefined = IsDefined,
    };

    long Eval(Expr e, string file, int line, out bool undefined)
    {
        var ctx = MakeCtx();
        long v = e.Eval(ctx);
        undefined = ctx.Undefined.Count > 0;
        if (undefined && _final)
            foreach (var u in ctx.Undefined.Distinct())
                Report(_opt.LenientMode ? Severity.Warning : Severity.Error, file, line, e.Col,
                    _opt.LenientMode ? $"uninitialized symbol {u} used here (value 0)" : $"undefined symbol '{u}'");
        return v;
    }

    void DefineLabel(string name, long value, string file, int line, int col)
    {
        if (Lexer.IsReservedWord(name))
            throw new AsmException($"'{name}' is a reserved word and cannot be used as a label");
        if (_definedThisPass.Contains(name))
        {
            var old = _symInfo[name];
            if (_final)
                Report(_opt.LenientMode ? Severity.Warning : Severity.Error, file, line, col,
                    $"duplicate label '{name}' (first defined at {Path.GetFileName(old.File)}:{old.Line})");
            if (!_opt.LenientMode) return;
        }
        if (_final && _syms.TryGetValue(name, out var prev) && prev != value && _symInfo[name].Kind == SymbolKind.Label
            && !_res.Diagnostics.Any(d => d.Severity == Severity.Error))
            Report(Severity.Error, file, line, col, $"label '{name}' moved between passes ({prev:X4} -> {value:X4}); an if/ds/align depends on a forward reference");
        SetSym(name, value, SymbolKind.Label, file, line);
    }

    void SetSym(string name, long v, SymbolKind kind, string? file, int line, bool silent = false)
    {
        _syms[name] = v;
        _definedThisPass.Add(name);
        if (!silent || !_symInfo.ContainsKey(name)) _symInfo[name] = new SymbolInfo(name, v, kind, file, line);
    }

    void AssembleInstruction(Src src, int line, List<Token> toks, int p)
    {
        var mn = toks[p].Text;
        if (mn == "VCAL")
        {
            int q = p + 1;
            var e = ExprParser.Parse(toks, ref q);
            ExpectEnd(toks, q);
            long v = Eval(e, src.Path, line, out _);
            if (_final && (v < 0 || v > 7)) Report(Severity.Error, src.Path, line, e.Col, "invalid VCAL (0..7)");
            Emit(new[] { (byte)(0x10 + v) }, src.Path, line);
            return;
        }
        Rule? rule = null;
        Dictionary<int, Expr>? exprs = null;
        foreach (var r in Grammar.Instance.RulesFor(mn))
        {
            exprs = Grammar.Match(r, toks, p + 1);
            if (exprs != null) { rule = r; break; }
        }
        if (rule == null || exprs == null)
        {
            var forms = Grammar.Instance.RulesFor(mn).Take(6).Select(r => r.Display);
            throw new AsmException($"invalid operands for {mn}. Valid forms include: {string.Join(" | ", forms)}");
        }
        var bytes = (byte[])rule.Template.Clone();
        foreach (var (kind, idx, pos, relSize) in rule.Actions)
        {
            var e = exprs[pos];
            long v = Eval(e, src.Path, line, out bool undef);
            switch (kind)
            {
                case 'B':
                    bool isOff = pos - 2 > 0 && rule.Symbols[pos - 3] == "OFFSET";
                    if (_final && !undef && !isOff && _opt.WarnTruncation && (v < -128 || v > 255))
                        Report(Severity.Warning, src.Path, line, e.Col, $"value {v:X}h does not fit in 8 bits; assembled as {v & 0xFF:X2}h");
                    bytes[idx] = (byte)v; break;
                case 'W':
                    if (_final && !undef && _opt.WarnTruncation && (v < -32768 || v > 65535))
                        Report(Severity.Warning, src.Path, line, e.Col, $"value {v:X}h does not fit in 16 bits");
                    bytes[idx] = (byte)v; bytes[idx + 1] = (byte)(v >> 8); break;
                case 'R':
                    {
                        long x = (int)(v - _pc - relSize);
                        if (_final && !undef && (x < -128 || x > 127))
                            Report(_opt.LenientMode ? Severity.Warning : Severity.Error, src.Path, line, e.Col,
                                $"branch target {v:X4}h out of range ({x:+#;-#;0} bytes, limit -128..+127); use J/SJ or move the target");
                        bytes[idx] = (byte)x; break;
                    }
            }
        }
        Emit(bytes, src.Path, line);
    }

    void Emit(byte[] bytes, string file, int line)
    {
        if (bytes.Length == 0) return;
        if (_final)
        {
            if (_pc + bytes.Length > _romSize)
            {
                Report(Severity.Error, file, line, 0, $"code exceeds ROM size ({_romSize} bytes) at {_pc:X4}h");
                _pc += bytes.Length;
                return;
            }
            _ownerDesc.Add($"{Path.GetFileName(file)}:{line}");
            int id = _ownerDesc.Count - 1;
            for (int i = 0; i < bytes.Length; i++)
            {
                int a = (int)_pc + i;
                if (_res.Used[a])
                {
                    Report(Severity.Error, file, line, 0, $"overlaps address {a:X4}h already written by {_ownerDesc[_owner[a]]}");
                    break;
                }
            }
            for (int i = 0; i < bytes.Length; i++)
            {
                int a = (int)_pc + i;
                _res.Image[a] = bytes[i];
                _res.Used[a] = true;
                _owner[a] = id;
            }
            _res.SourceMap.Add(new SourceMapEntry((int)_pc, bytes.Length, file, line, _module));
            if (!_res.Modules.TryGetValue(_module, out var mu)) _res.Modules[_module] = mu = new ModuleUsage { Name = _module };
            mu.Add((int)_pc, bytes.Length);
        }
        _pc += bytes.Length;
    }

    void Report(Severity s, string file, int line, int col, string msg)
    {
        if (!_final && s != Severity.Error) return;
        if (!_diagSeen.Add((file, line, msg))) return;
        // pass-1 errors are real (syntax); undefined symbols are only reported in the final pass
        _res.Diagnostics.Add(new Diagnostic(s, file, line, col, msg));
    }

    // ------------------------------------------------------------------ output writers

    public static string WriteSymbolFile(AssemblyResult r) =>
        string.Join("\n", r.Symbols.Values.Where(s => s.Kind != SymbolKind.Sfr)
            .OrderBy(s => s.Value).ThenBy(s => s.Name)
            .Select(s => $"{s.Value & 0xFFFF:X4} {s.Name}")) + "\n";

    public static string WriteListing(AssemblyResult r)
    {
        var sb = new StringBuilder();
        var byFileLine = r.SourceMap.GroupBy(e => (e.File, e.Line)).ToDictionary(g => g.Key, g => g.ToList());
        foreach (var f in r.Files)
        {
            sb.AppendLine($";==== {f}");
            string[] lines;
            try { lines = File.ReadAllLines(f, Encoding.Latin1); } catch { continue; }
            for (int i = 0; i < lines.Length; i++)
            {
                string prefix = new(' ', 28);
                if (byFileLine.TryGetValue((f, i + 1), out var es))
                {
                    var e = es[0];
                    var hex = string.Concat(r.Image.Skip(e.Address).Take(Math.Min(e.Length, 8)).Select(b => b.ToString("X2")));
                    if (e.Length > 8) hex += "+";
                    prefix = $"{e.Address:X4}  {hex,-21} ";
                }
                sb.Append(prefix).Append($"{i + 1,6}  ").AppendLine(lines[i]);
            }
        }
        return sb.ToString();
    }

    public static string WriteMap(AssemblyResult r)
    {
        var sb = new StringBuilder();
        int used = r.UsedBytes;
        sb.AppendLine($"ROM size {r.Image.Length} bytes, used {used} ({100.0 * used / r.Image.Length:F1}%), free {r.Image.Length - used}");
        sb.AppendLine();
        sb.AppendLine("Module                          Bytes   Ranges");
        foreach (var m in r.Modules.Values.OrderByDescending(m => m.Bytes))
            sb.AppendLine($"{m.Name,-30} {m.Bytes,6}   {string.Join(" ", m.Ranges.Take(8).Select(x => $"{x.Start:X4}-{x.End - 1:X4}"))}{(m.Ranges.Count > 8 ? " ..." : "")}");
        sb.AppendLine();
        sb.AppendLine("Free regions (>= 16 bytes of FF not written by the source):");
        foreach (var (s, e) in r.FreeRegions()) sb.AppendLine($"  {s:X4}-{e - 1:X4}  {e - s,6} bytes");
        return sb.ToString();
    }
}
