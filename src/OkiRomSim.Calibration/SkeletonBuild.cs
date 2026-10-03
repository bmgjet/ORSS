// Copyright (c) bmgjet. All rights reserved.
using System.Text;
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;

namespace OkiRomSim.Calibration;

/// One function a skeleton ROM can be built with: a stock function the skeleton took out and can put back (FEAT_STOCK_...), or a feature module from its features folder (FEAT_...).
public sealed record SkeletonFeature(
    string Define, string Name, string Category, string About,
    IReadOnlyList<string> Conflicts, IReadOnlyList<string> Requires, string Ram, string? File, bool Stock, IReadOnlyList<string>? Pages = null);

/// The result of assembling a skeleton with a set of features. FreeBytes: what is left; when the build is too big, how far over it is, as a negative number.
public sealed record SkeletonBuildResult(bool Success, AssemblyResult? Assembly, IReadOnlyList<string> Errors, int UsedBytes, int FreeBytes, int ModuleBytes)
{
    /// Too big by this many bytes (0 when it fits or failed for another reason).
    public int Over => FreeBytes < 0 ? -FreeBytes : 0;

    /// The module RAM this build takes (null when the skeleton has none, or the build stopped before it was laid out).
    public ModuleRam? Ram { get; init; }
}

/// A stretch of module RAM and who has it.
public sealed record RamUse(string Owner, int Start, int Bytes);

/// Module RAM: the block modules take their bytes from (MOD_RAM_BASE up to MOD_RAM_END), how far it is taken (MODRAM_NEXT), and by whom.
public sealed record ModuleRam(int Base, int End, int Next, IReadOnlyList<RamUse> Uses)
{
    public int Size => End - Base;
    public int Used => Math.Max(0, Next - Base);
    public int Free => Size - Used;
    public bool Full => Next > End;
}

/// A skeleton ROM: a stock ROM cut down to what runs the engine, with extension points that feature modules plug into. Built from source, so the assembler places every module's code and tables where there is room: any mix, in any order, never overlapping, until the 32 KB are full. Found by name: "xxx-skeleton.asm", with its modules in the folder its extension points include ("xxx-features/features.inc"). Each module file describes itself in a ";>" header: ;> feature: FEAT_LAUNCH          the define that builds it in ;> name: Launch control          ;> category: Limits          ;> about: what it does (continues on ;> lines) ;> conflicts: FEAT_A, FEAT_B      ;> requires: FEAT_C           ;> ram: the RAM it owns The stock functions are listed in the skeleton's own header as ";     FEAT_STOCK_NAME   what it is".
public sealed class Skeleton
{
    public required string Path { get; init; }
    public required string Name { get; init; }
    public required string Description { get; init; }
    public string? FeaturesDir { get; init; }
    public List<SkeletonFeature> Features { get; } = [];

    public override string ToString() => Name;

    /// The skeleton and its modules kept lexed between builds: the New ROM window builds it once for every function to show what each costs, and only the defines change between those builds.
    readonly SourceCache _cache = new();

    /// Every skeleton in these folders (not their subfolders).
    public static List<Skeleton> Find(params string?[] folders)
    {
        var list = new List<Skeleton>();
        foreach (var dir in folders.Where(d => d != null && Directory.Exists(d)).Distinct(StringComparer.OrdinalIgnoreCase))
            foreach (var f in Directory.GetFiles(dir!, "*-skeleton.asm").OrderBy(f => f, StringComparer.OrdinalIgnoreCase))
                try { list.Add(Load(f)); } catch { }
        return list;
    }

    static readonly Regex StockLine = new(@"^;\s+(FEAT_STOCK_\w+)\s{2,}(\S.*)$");
    static readonly Regex StockMore = new(@"^;\s{20,}(\S.*)$");
    static readonly Regex IncludeLine = new(@"^\s*include\s+""([^""]+)""", RegexOptions.IgnoreCase);

    public static Skeleton Load(string path)
    {
        var lines = File.ReadLines(path).Take(400).ToList();
        // the description: the header comment up to "Putting stock functions back" (or <end>)
        var about = new StringBuilder();
        foreach (var raw in lines)
        {
            var t = raw.Trim();
            if (!t.StartsWith(';')) break;
            var text = t.TrimStart(';').Trim();
            if (text.StartsWith("Putting stock", StringComparison.OrdinalIgnoreCase) || text.Contains("<end>", StringComparison.OrdinalIgnoreCase)) break;
            if (text.Length == 0 || !text.Any(char.IsLetterOrDigit)) { if (about.Length > 0 && about[^1] != '\n') about.Append('\n'); continue; }
            if (about.Length > 0 && about[^1] != '\n') about.Append(' ');
            about.Append(text);
        }
        string name = System.IO.Path.GetFileNameWithoutExtension(path).Replace("-skeleton", "", StringComparison.OrdinalIgnoreCase).ToUpperInvariant() + " skeleton";

        // the features folder: the file the extension points include
        string? featuresInc = null;
        foreach (var l in File.ReadLines(path))
        {
            var m = IncludeLine.Match(l);
            if (m.Success && m.Groups[1].Value.EndsWith("features.inc", StringComparison.OrdinalIgnoreCase))
            { featuresInc = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(path)!, m.Groups[1].Value); break; }
        }
        var sk = new Skeleton { Path = path, Name = name, Description = about.ToString().Trim(), FeaturesDir = featuresInc == null ? null : System.IO.Path.GetDirectoryName(featuresInc) };

        // stock functions from the header
        for (int i = 0; i < lines.Count; i++)
        {
            var m = StockLine.Match(lines[i]);
            if (!m.Success) continue;
            var text = m.Groups[2].Value.Trim();
            while (i + 1 < lines.Count && StockMore.Match(lines[i + 1]) is { Success: true } more && !StockLine.IsMatch(lines[i + 1]))
            { text += " " + more.Groups[1].Value.Trim(); i++; }
            string title = char.ToUpperInvariant(text[0]) + text[1..];
            int cut = title.IndexOfAny([':', '(']);
            sk.Features.Add(new SkeletonFeature(m.Groups[1].Value, "Stock " + (cut > 0 ? title[..cut].Trim() : title).ToLowerInvariant(),
                "Stock functions", title, [], [], "", null, true));
        }

        // modules: every file features.inc includes, in its order
        if (featuresInc != null && File.Exists(featuresInc))
            foreach (var l in File.ReadLines(featuresInc))
            {
                var m = IncludeLine.Match(l);
                if (!m.Success) continue;
                var file = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(featuresInc)!, m.Groups[1].Value);
                if (File.Exists(file) && ReadModule(file) is { } f) sk.Features.Add(f);
            }
        return sk;
    }

    /// A module's ";>" header.
    public static SkeletonFeature? ReadModule(string file)
    {
        var keys = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string? last = null;
        foreach (var raw in File.ReadLines(file).Take(120))
        {
            var t = raw.TrimStart();
            if (!t.StartsWith(";>")) { if (keys.Count > 0 && !t.StartsWith(';')) break; continue; }
            var body = t[2..];
            int colon = body.IndexOf(':');
            var key = colon > 0 ? body[..colon].Trim() : "";
            if (colon > 0 && key.Length > 0 && key.All(c => char.IsLetter(c) || c == '-') && !body[..colon].StartsWith("  "))
            {
                last = key;
                keys[key] = body[(colon + 1)..].Trim();
            }
            else if (last != null) keys[last] += " " + body.Trim();
        }
        if (!keys.TryGetValue("feature", out var define) || define.Length == 0) return null;
        static string[] List(string? s) => (s ?? "").Split([',', ' '], StringSplitOptions.RemoveEmptyEntries)
            .Where(x => x.StartsWith("FEAT_", StringComparison.OrdinalIgnoreCase)).ToArray();
        return new SkeletonFeature(define.Trim(), keys.GetValueOrDefault("name", define), keys.GetValueOrDefault("category", "Other"),
            keys.GetValueOrDefault("about", ""), List(keys.GetValueOrDefault("conflicts")), List(keys.GetValueOrDefault("requires")),
            keys.GetValueOrDefault("ram", ""), file, false,
            keys.GetValueOrDefault("pages", "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
    }

    /// For a ROM built from a skeleton: the calibration pages that belong to modules it was built without (a page key a module's header names, or one of a family of them - "boardopt" is every "boardopt.x"), so "show only valid pages" can leave them out whatever a guess has bound to them. Null when the ROM was not built from a skeleton.
    public static Func<string, bool>? PagesLeftOut(AssemblyResult asm)
    {
        var file = asm.Files.FirstOrDefault(f => f.EndsWith("-skeleton.asm", StringComparison.OrdinalIgnoreCase));
        if (file == null || !System.IO.File.Exists(file)) return null;
        Skeleton sk;
        try { sk = Load(file); } catch { return null; }
        var built = asm.Symbols.Values.Where(s => s.Kind == SymbolKind.Define && s.Value != 0 && s.Name.StartsWith("FEAT_", StringComparison.OrdinalIgnoreCase))
                       .Select(s => s.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var owners = sk.Features.Where(f => !f.Stock && f.Pages is { Count: > 0 }).ToList();
        return key =>
        {
            bool Owns(SkeletonFeature f) => f.Pages!.Any(p => key.Equals(p, StringComparison.OrdinalIgnoreCase) || key.StartsWith(p + ".", StringComparison.OrdinalIgnoreCase));
            var mine = owners.Where(Owns).ToList();
            return mine.Count > 0 && !mine.Any(f => built.Contains(f.Define));
        };
    }

    public SkeletonFeature? Feature(string define) => Features.FirstOrDefault(f => f.Define.Equals(define, StringComparison.OrdinalIgnoreCase));

    /// What stops this set from building: a pair that conflicts, or a feature missing one it needs.
    public List<string> Problems(IEnumerable<string> defines)
    {
        var set = new HashSet<string>(defines, StringComparer.OrdinalIgnoreCase);
        var list = new List<string>();
        foreach (var d in set)
        {
            if (Feature(d) is not { } f) continue;
            foreach (var c in f.Conflicts.Where(set.Contains))
                if (string.CompareOrdinal(d, c) < 0 || Feature(c)?.Conflicts.Contains(d, StringComparer.OrdinalIgnoreCase) != true)
                    list.Add($"{f.Name} and {Feature(c)?.Name ?? c} cannot be built together");
            foreach (var r in f.Requires.Where(r => !set.Contains(r)))
                list.Add($"{f.Name} needs {Feature(r)?.Name ?? r}");
        }
        return list;
    }

    /// Assemble the skeleton with these features, in memory.
    public SkeletonBuildResult Build(IEnumerable<string> defines)
    {
        var o = new AssemblerOptions { Cache = _cache };
        foreach (var d in defines)
        {
            // "NAME=number" sets a define to a value (a diagnostic knob such as TICKBURN_US); anything else is a switch
            int eq = d.IndexOf('=');
            if (eq > 0 && long.TryParse(d[(eq + 1)..], out var val)) o.Defines[d[..eq]] = val; else o.Defines[d] = 1;
        }
        AssemblyResult r;
        try { r = new OkiAssembler(o).AssembleFile(Path); }
        catch (Exception ex) { return new(false, null, [ex.Message], 0, 0, 0); }
        var errors = r.Diagnostics.Where(d => d.Severity == Severity.Error).Select(d => d.ToString()).ToList();
        // too big: that one line says it all (by how many bytes), whatever else it set off
        var fulls = r.Diagnostics.Where(d => d.Severity == Severity.Error && d.Message.StartsWith("the ROM is full")).ToList();
        if (fulls.Count > 0) errors = [(fulls.FirstOrDefault(d => d.Message.Contains("bytes too big")) ?? fulls[0]).Message];
        long Sym(string n, long fallback) => r.Symbols.Values.FirstOrDefault(s => s.Name.Equals(n, StringComparison.OrdinalIgnoreCase))?.Value ?? fallback;
        long free0 = Sym("skel_free_start", -1), freeHi = Sym("skel_free_hi_addr", 0x7EFF);
        // the free block runs from skel_free_start to the byte before the hook table
        long hooks = Sym("hook_init", 0x7F00);
        int free = free0 < 0 ? r.Image.Length - r.UsedBytes : (int)Math.Max(0, hooks - free0);
        // too big: the free space is how far over it is, as a negative number, so costs still add up
        if (Regex.Match(string.Join(" ", errors), @"(\d+) bytes too big") is { Success: true } over) free = -int.Parse(over.Groups[1].Value);
        return new(r.Success, r, errors, r.UsedBytes, free, 0) { Ram = RamOf(r) };
    }

    /// Who has which bytes of module RAM: every name a module file (or lib.asm) puts in the block, in address order, each run of one file's names up to the next file's first.
    ModuleRam? RamOf(AssemblyResult r)
    {
        SymbolInfo? Get(string n) => r.Symbols.Values.FirstOrDefault(s => s.Name.Equals(n, StringComparison.OrdinalIgnoreCase));
        if (Get("MOD_RAM_BASE") is not { } b || Get("MOD_RAM_END") is not { } e) return null;
        int lo = (int)b.Value, hi = (int)e.Value;
        int next = Get("MODRAM_NEXT") is { } n ? (int)n.Value : lo;
        var names = r.Symbols.Values
            .Where(s => s.Kind is SymbolKind.Equate && s.File != null && s.Value >= lo && s.Value < Math.Max(next, lo + 1)
                        && !s.Name.StartsWith("MOD_RAM", StringComparison.OrdinalIgnoreCase))
            .Select(s => (At: (int)s.Value, Owner: OwnerOf(s.File!)))
            .OrderBy(x => x.At).ToList();
        var uses = new List<RamUse>();
        for (int i = 0; i < names.Count; i++)
        {
            int start = names[i].At;
            while (i + 1 < names.Count && names[i + 1].Owner == names[i].Owner) i++;
            int end = i + 1 < names.Count ? names[i + 1].At : next;
            if (end <= start) continue;
            if (uses.Count > 0 && uses[^1].Owner == names[i].Owner) uses[^1] = uses[^1] with { Bytes = end - uses[^1].Start };
            else uses.Add(new RamUse(names[i].Owner, start, end - start));
        }
        return new ModuleRam(lo, hi, next, uses);
    }

    string OwnerOf(string file)
    {
        var name = System.IO.Path.GetFileName(file);
        if (Features.FirstOrDefault(f => f.File != null && System.IO.Path.GetFileName(f.File).Equals(name, StringComparison.OrdinalIgnoreCase)) is { } f) return f.Name;
        return name.Equals("lib.asm", StringComparison.OrdinalIgnoreCase) ? "Shared (the module library)" : name;
    }

    /// The skeleton keeps an engine rev limiter of its own whatever is built (its annotations say so).
    public bool HasOwnRevLimiter => _hasRevLimiter ??= File.ReadLines(Path).Any(l => l.StartsWith(";@", StringComparison.Ordinal) && Regex.IsMatch(l, @"(?i)rev\s*limit"));
    bool? _hasRevLimiter;

    /// The source of a build: the chosen features as defines, then the skeleton. `include` is the skeleton's path as the build file will see it.
    public string BuildSource(IEnumerable<string> defines, string include, string romName) => BuildSourceBase(defines, include, romName);

    const string KeptStart = "; ---- kept by OkiRomSim: set from the app (the ROM's name and version, the watermark) - leave these lines to it";
    const string KeptEnd = "; ---- end of what OkiRomSim keeps";

    /// A build file with the values the app keeps in it brought up to date: the watermark with its password block (46 bytes at watermark_data), written after the include with the define that tells the module to leave its own bytes out. (A name and version at `romIdAt` is kept only as an older build file has it: they are the skeleton's now.) Null leaves that one as the file has it.
    public static string WithKept(string text, byte[]? romId, int romIdAt, byte[]? watermark)
    {
        var nl = text.Contains("\r\n") ? "\r\n" : "\n";
        var lines = text.Replace("\r\n", "\n").Split('\n').ToList();
        // what the block holds now, kept where not given (a file kept by a build from before the name changed has the old markers: they are found too, and written anew)
        int s = lines.FindIndex(l => l.StartsWith(KeptStart) || l.StartsWith("; ---- kept by OkiRomSim:")), e = lines.FindIndex(l => l.StartsWith(KeptEnd) || l.StartsWith("; ---- end of what OkiRomSim keeps"));
        var old = s >= 0 && e > s ? lines.GetRange(s + 1, e - s - 1) : [];
        if (s >= 0 && e > s) lines.RemoveRange(s, e - s + 1);
        while (lines.Count > 0 && lines[^1].Trim().Length == 0) lines.RemoveAt(lines.Count - 1);
        string? Old(string tag) { int k = old.FindIndex(l => l.Contains(tag)); return k >= 0 && k + 1 < old.Count ? old[k + 1] : null; }
        static string Db(byte[] b) => "                DB  " + string.Join(", ", b.Select(x => $"0{x:X2}h"));
        void Define(string name)
        {
            if (lines.Any(l => Regex.IsMatch(l, $@"^\s*define\s+{name}\b", RegexOptions.IgnoreCase))) return;
            int inc = lines.FindIndex(l => IncludeLine.IsMatch(l));
            lines.Insert(inc < 0 ? lines.Count : inc, $"define {name,-26} ; set by the app: the bytes are at the end of this file");
        }
        var block = new List<string>();
        string? idLine = romId != null ? Db(romId) + $"  ; \"{Encoding.ASCII.GetString(romId)}\"" : Old("org 0" + romIdAt.ToString("X4"));
        if (idLine != null) { Define("ROM_ID_SET"); block.Add($"                org 0{romIdAt:X4}h        ; the ROM's name and version"); block.Add(idLine); }
        string? wmLine = watermark != null ? Db(watermark) : Old("org watermark_data");
        if (wmLine != null) { Define("WATERMARK_SET"); block.Add("                org watermark_data   ; the watermark and its password block"); block.Add(wmLine); }
        if (block.Count > 0) { lines.Add(""); lines.Add(KeptStart); lines.AddRange(block); lines.Add(KeptEnd); }
        lines.Add("");
        return string.Join(nl, lines);
    }

    string BuildSourceBase(IEnumerable<string> defines, string include, string romName)
    {
        var chosen = new HashSet<string>(defines, StringComparer.OrdinalIgnoreCase);
        var sb = new StringBuilder();
        sb.AppendLine($"; {romName} - built from {System.IO.Path.GetFileName(Path)} ({Name}) by File > New ROM > Create.");
        sb.AppendLine(";");
        sb.AppendLine("; Each define builds one function into the ROM. Comment one out (put ; in front of it) or remove the ;");
        sb.AppendLine("; from another, then build again: the assembler places everything, and stops with an error when the");
        sb.AppendLine("; ROM is full. The checksum byte is set on every build and kept right by every edit in the app.");
        sb.AppendLine("; <end>");
        foreach (var group in Features.GroupBy(f => f.Category))
        {
            sb.AppendLine();
            sb.AppendLine($"; ---- {group.Key}");
            foreach (var f in group)
                sb.AppendLine($"{(chosen.Contains(f.Define) ? "" : ";")}define {f.Define,-26} ; {f.Name}");
        }
        sb.AppendLine();
        sb.AppendLine($"include \"{include.Replace('\\', '/')}\"");
        return sb.ToString();
    }

    /// The defines a build file has switched on (lines "define FEAT_..." that are not commented out).
    public static List<string> DefinesIn(string buildSource) =>
        [.. buildSource.Split('\n').Select(l => l.Trim())
            .Where(l => l.StartsWith("define ", StringComparison.OrdinalIgnoreCase))
            .Select(l => l[7..].Split(';')[0].Trim().Split(' ', '\t')[0])
            .Where(d => d.StartsWith("FEAT_", StringComparison.OrdinalIgnoreCase))];
}
