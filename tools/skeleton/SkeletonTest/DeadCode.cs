// --deadcode: code in the skeleton that no build can reach. Each build is followed the way the CPU runs it (from the
// vectors, the VCAL table, the hook slots and every label whose address is taken - a DW, a #label, an indirect jump),
// both sides of every branch; an assembled code line that is never reached, in any build that assembles it, is listed.
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

static class DeadCode
{
    static readonly Regex Data = new(@"^\s*(\w+:)?\s*(DB|DW|DS|ORG|EQU)\b", RegexOptions.IgnoreCase);
    static readonly Regex Direct = new(@"^(J|SJ|JEQ|JNE|JLT|JGE|JGT|JLE|JBS|JBR|JRNZ|CAL|SCAL|DJNZ)\b", RegexOptions.IgnoreCase);

    public static int Run(Skeleton sk, string skeletonPath, string[] args)
    {
        var builds = new List<(string Name, string[] Defs)> { ("bare", []) };
        var stock = sk.Features.Where(f => f.Stock).Select(f => f.Define).ToArray();
        builds.Add(("stock", stock));
        foreach (var s in stock) builds.Add((s, [s]));
        string[] def4 = ["FEAT_STOCK_DTC", "FEAT_STOCK_SELFTEST", "FEAT_DATALOG", "FEAT_ECTPRO"];
        foreach (var m in sk.Features.Where(f => !f.Stock)) builds.Add((m.Define, [.. def4, m.Define, .. m.Requires]));
        builds.Add(("bigmix", [.. stock.Where(d => d != "FEAT_STOCK_SERIAL"), "FEAT_DATALOG", "FEAT_ECTPRO", "FEAT_REVLIMIT", "FEAT_SHIFTLIGHT", "FEAT_FUELTRIM", "FEAT_GEAR"]));

        var file = Path.GetFullPath(skeletonPath);
        var lines = File.ReadAllLines(file);
        var assembled = new HashSet<int>();     // skeleton lines (1-based) assembled as code in some build
        var reached = new HashSet<int>();       // ... and reached in some build
        var bytesOf = new Dictionary<int, int>();
        int ok = 0;
        foreach (var (name, defs) in builds)
        {
            SkeletonBuildResult b;
            try { b = sk.Build(defs.Distinct()); } catch (Exception ex) { Console.WriteLine($"{name}: {ex.Message}"); continue; }
            if (b.Assembly is not { Success: true } asm) { Console.WriteLine($"{name}: did not build"); continue; }
            ok++;
            var hit = Walk(asm);
            int lost = 0;
            var lostRuns = new List<(int Line, int Bytes)>();
            foreach (var e in asm.SourceMap)
            {
                if (string.Equals(Path.GetFullPath(e.File), file, StringComparison.OrdinalIgnoreCase) && e.Line >= 1 && e.Line <= lines.Length
                    && !Data.IsMatch(lines[e.Line - 1]) && e.Length > 0 && !hit.Contains(e.Address)) { lost += e.Length; lostRuns.Add((e.Line, e.Length)); }
            }
            if (name is "bare" or "stock" or "bigmix" or "FEAT_DATALOG" || args.Contains("--all"))
            {
                Console.WriteLine($"{name}: {lost} bytes of skeleton code assembled but not reachable in this build");
                foreach (var g in lostRuns.GroupBy(r => r.Line / 25).OrderByDescending(g => g.Sum(r => r.Bytes)).Take(12))
                    Console.WriteLine($"    near line {g.Min(r => r.Line)}: {g.Sum(r => r.Bytes)} bytes  {lines[g.Min(r => r.Line) - 1].Trim()}");
            }
            foreach (var e in asm.SourceMap)
            {
                if (!string.Equals(Path.GetFullPath(e.File), file, StringComparison.OrdinalIgnoreCase) || e.Line < 1 || e.Line > lines.Length) continue;
                if (Data.IsMatch(lines[e.Line - 1]) || e.Length == 0) continue;
                assembled.Add(e.Line);
                bytesOf[e.Line] = e.Length;
                if (hit.Contains(e.Address)) reached.Add(e.Line);
            }
        }
        // runs of lines never reached
        var dead = assembled.Where(l => !reached.Contains(l)).OrderBy(l => l).ToList();
        int total = 0, runs = 0;
        for (int i = 0; i < dead.Count;)
        {
            int j = i;
            // a run: dead lines with nothing but comments, blank lines and directives between them
            while (j + 1 < dead.Count && Enumerable.Range(dead[j] + 1, dead[j + 1] - dead[j] - 1).All(k => !assembled.Contains(k))) j++;
            int bytes = dead.Skip(i).Take(j - i + 1).Sum(l => bytesOf[l]);
            total += bytes; runs++;
            string first = lines[dead[i] - 1].Trim();
            Console.WriteLine($"{dead[i],6}-{dead[j],-6} {bytes,4} bytes  {(first.Length > 90 ? first[..90] : first)}");
            i = j + 1;
        }
        Console.WriteLine($"{ok} builds; {runs} unreached runs, {total} bytes of skeleton code no build reaches");
        return 0;
    }

    /// --fallcheck: every instruction that can fall through to the next, and where it lands, in each build: one that lands
    /// somewhere it lands in neither the bare build nor the all-stock build (code under one condition running into code under another
    /// it was never written to meet) is listed.
    public static int FallCheck(Skeleton sk, string skeletonPath)
    {
        var file = Path.GetFullPath(skeletonPath);
        var lines = File.ReadAllLines(file);
        var stock = sk.Features.Where(f => f.Stock).Select(f => f.Define).ToArray();
        var builds = new List<(string Name, string[] Defs)> { ("bare", []), ("stock", stock) };
        foreach (var f in stock) { builds.Add(("only " + f, [f])); builds.Add(("all but " + f, [.. stock.Where(x => x != f)])); }
        string[] def4 = ["FEAT_STOCK_DTC", "FEAT_STOCK_SELFTEST", "FEAT_DATALOG", "FEAT_ECTPRO"];
        builds.Add(("defaults", def4));
        var maps = new List<(string Name, Dictionary<int, int> Next)>();
        foreach (var (name, defs) in builds)
        {
            var b = sk.Build(defs);
            if (b.Assembly is not { Success: true } asm) { Console.WriteLine($"{name}: did not build"); continue; }
            var next = new Dictionary<int, int>();
            var entries = asm.SourceMap.Where(e => e.Length > 0).OrderBy(e => e.Address).ToList();
            for (int i = 0; i + 1 < entries.Count; i++)
            {
                var e = entries[i];
                if (!string.Equals(Path.GetFullPath(e.File), file, StringComparison.OrdinalIgnoreCase) || e.Line < 1 || e.Line > lines.Length) continue;
                var text = Regex.Replace(lines[e.Line - 1].Split(';')[0], @"^\s*\w+:", "").Trim();
                if (text.Length == 0 || Data.IsMatch(lines[e.Line - 1]) || Regex.IsMatch(text, @"^(J|SJ|RT|RTI|BRK|BR)\b", RegexOptions.IgnoreCase)) continue;
                var n = entries[i + 1];
                if (n.Address != e.Address + e.Length) continue;
                next[e.Line] = string.Equals(Path.GetFullPath(n.File), file, StringComparison.OrdinalIgnoreCase) ? n.Line : -1;
            }
            maps.Add((name, next));
        }
        var bare = maps.First(m => m.Name == "bare").Next;
        var all = maps.First(m => m.Name == "stock").Next;
        int bad = 0;
        foreach (var (name, next) in maps.Skip(2))
            foreach (var (line, to) in next)
            {
                bool okBare = bare.TryGetValue(line, out var tb) && tb == to, okAll = all.TryGetValue(line, out var ta) && ta == to;
                if (okBare || okAll) continue;
                if (!bare.ContainsKey(line) && !all.ContainsKey(line)) continue;     // module glue (a NEED_ block): no reference to hold it to
                bad++;
                Console.WriteLine($"{name}: line {line} falls into {(to < 0 ? "a module" : "line " + to)} (bare: {(bare.ContainsKey(line) ? tb.ToString() : "-")}, all stock: {(all.ContainsKey(line) ? ta.ToString() : "-")})  {lines[line - 1].Trim()}");
            }
        Console.WriteLine($"{maps.Count} builds; {bad} fall-throughs that land somewhere new");
        return bad == 0 ? 0 : 1;
    }

    /// The instruction starts reached from the vectors, the VCAL table, the hook slots and every address-taken label.
    static HashSet<int> Walk(AssemblyResult asm)
    {
        var img = asm.Image;
        var texts = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
        string? Src(int a)
        {
            var e = asm.Lookup(a);
            if (e == null) return null;
            if (!texts.TryGetValue(e.File, out var t)) texts[e.File] = t = File.Exists(e.File) ? File.ReadAllLines(e.File) : [];
            return e.Line >= 1 && e.Line <= t.Length ? t[e.Line - 1] : null;
        }
        var todo = new Stack<int>();
        for (int v = 0; v < 0x38; v += 2) todo.Push(img[v] | (img[v + 1] << 8));
        var labels = asm.Symbols.Values.Where(s => s.Kind == SymbolKind.Label && s.Value < Bus.RomSize).ToList();
        foreach (var s in labels.Where(s => s.Name.StartsWith("hook_", StringComparison.Ordinal))) todo.Push((int)s.Value);
        // address-taken labels: named anywhere but as the target of a direct jump or call
        var byName = labels.GroupBy(s => s.Name, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => (int)g.First().Value, StringComparer.OrdinalIgnoreCase);
        foreach (var f in asm.Files.Distinct())
        {
            if (!File.Exists(f)) continue;
            foreach (var raw in File.ReadAllLines(f))
            {
                var code = raw.Split(';')[0];
                var m = Regex.Match(code, @"^\s*\w+:");
                if (m.Success) code = code[m.Length..];
                code = code.Trim();
                if (code.Length == 0) continue;
                var words = Regex.Matches(code, @"[A-Za-z_]\w*").Select(x => x.Value).ToList();
                bool direct = Direct.IsMatch(code) && !code.Contains('[');
                // a direct jump or call: only its last operand is a target; anything else named on it is taken
                var taken = direct ? words.Skip(1).SkipLast(1) : words;
                foreach (var w in taken) if (byName.TryGetValue(w, out var a)) todo.Push(a);
            }
        }
        var seen = new HashSet<int>();
        while (todo.Count > 0)
        {
            int pc = todo.Pop();
            while (pc >= 0x38 && pc < Bus.RomSize && seen.Add(pc))
            {
                var d = Decode(img, pc, Src(pc));
                if (d == null) break;
                string op = d.Mnemonic.Split(' ')[0];
                int next = pc + d.Len;
                if (op is "RT" or "RTI" or "BRK") break;
                if (op == "VCAL") { pc = next; continue; }
                bool branch = Direct.IsMatch(d.Mnemonic);
                if (branch && !d.Mnemonic.Contains('['))
                {
                    if (d.Mnemonic.Contains("rel8")) todo.Push(next + d.Fields.Rel8);
                    else if (d.Mnemonic.Contains("addr16")) todo.Push(d.Fields.Addr16);
                }
                if (op is "J" or "SJ" || branch && d.Mnemonic.Contains('[') && op is not ("CAL" or "SCAL")) break;
                pc = next;
            }
        }
        return seen;
    }

    static Decoded? Decode(byte[] img, int addr, string? src)
    {
        Decoded? Try(bool dd) => Decoder.Decode(dd, i => img[(addr + i) & (Bus.RomSize - 1)]);
        var w = Try(true); var b = Try(false);
        if (w == null) return b;
        if (b == null || w.Mnemonic == b.Mnemonic && w.Len == b.Len) return w;
        if (src != null)
        {
            var code = Regex.Replace(src.Split(';')[0], @"^\s*\w+:", "").Trim();
            var op = code.Split([' ', '\t'], 2, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToUpperInvariant() ?? "";
            if (w.Mnemonic.Split(' ')[0] == op) return w;
            if (b.Mnemonic.Split(' ')[0] == op) return b;
        }
        return w;
    }
}
