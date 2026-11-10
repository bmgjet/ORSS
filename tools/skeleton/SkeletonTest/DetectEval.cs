using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

/// --detect: how well Detect names the tables of a ROM opened as a bare .bin. Each known ROM is taken as an image,
/// disassembled the way File > Open does it, and detected against the other ROMs as references (never itself);
/// what it finds is checked against the ROM's own definitions.
static class DetectEval
{
    public static void Run(string root, Action<string, bool, string> check)
    {
        string R(string f) => Path.Combine(root, "roms", f);
        var sk = Skeleton.Load(R("p30-skeleton.asm"));
        var stock = sk.Features.Where(f => f.Stock).ToDictionary(f => f.Define, _ => 1L);
        var refs = new Dictionary<string, RomReference?>
        {
            ["p30 skeleton"] = RomReference.FromFile(R("p30-skeleton.asm"), stock),
            ["HTS120"] = RomReference.FromFile(R("HTS120.asm")),
            ["p72"] = RomReference.FromFile(R("p72-269.asm")),
            ["p08"] = RomReference.FromFile(R("p08-911-243.asm")),
            ["HTS115"] = RomReference.FromFile(R("HTS115.asm")),
            ["CromeGold"] = RomReference.FromFile(R("CromeGold.asm")),
        };
        var shipped = RomReference.Shipped(Path.Combine(root, "src", "OkiRomSim.Desktop", "bin", "Release", "net10.0", "Templates"));
        check("the app's shipped references load (the skeleton with its stock code, HTS120, and the ones in References)", shipped.Count >= 6,
              string.Join(", ", shipped.Select(r => $"{r.Name} {r.Items.Count}")));
        foreach (var (n, r) in refs) Console.WriteLine($"  reference {n}: {(r == null ? "did not load" : $"{r.Items.Count} tables, {r.Instructions} instructions")}");

        // the truth for each target: its own definitions (p30: the skeleton's tables where their stock bytes are)
        var p30 = new OkiAssembler().AssembleFile(R("p30.asm"));
        var skDefs = refs["p30 skeleton"]!.Items;
        var skImg = new OkiAssembler(Opts(stock)).AssembleFile(R("p30-skeleton.asm")).Image;
        var p30Truth = new List<(int, string)>();
        foreach (var i in skDefs.Where(i => i.Span >= 3))
        {
            var bytes = skImg.AsSpan(i.Address, i.Span).ToArray();
            int at = IndexOf(p30.Image, bytes);
            if (at >= 0 && IndexOf(p30.Image, bytes, at + 1) < 0) p30Truth.Add((at, i.Name));
        }
        var targets = new (string Name, byte[] Image, List<(int, string)> Truth, string[] Exclude)[]
        {
            ("p72", new OkiAssembler().AssembleFile(R("p72-269.asm")).Image, refs["p72"]!.Items.Select(i => (i.Address, i.Name)).ToList(), ["p72"]),
            ("p30", p30.Image, [.. p30Truth, .. DataLabels(R("p30.asm"), p30)], ["p30 skeleton"]),
            ("HTS120", new OkiAssembler().AssembleFile(R("HTS120.asm")).Image, refs["HTS120"]!.Items.Where(i => i.Origin?.StartsWith("detected") != true).Select(i => (i.Address, i.Name)).ToList(), ["HTS120", "HTS115"]),
        };
        foreach (var (name, image, truth, exclude) in targets)
        {
            var path = Path.Combine(Path.GetTempPath(), $"detect-{name}.asm");
            var dis = BinDisassembler.Disassemble(image, name + ".bin", text =>
            {
                var r = new OkiAssembler(new AssemblerOptions { ReadFile = f => f == Path.GetFullPath(path) ? text : null }).AssembleText(text, path);
                return (r.Success ? r.Image : null, r.Diagnostics.Where(d => d.Severity == Severity.Error).Select(d => d.Line));
            });
            var asm = new OkiAssembler(new AssemblerOptions { ReadFile = f => f == Path.GetFullPath(path) ? dis.Text : null }).AssembleText(dis.Text, path);
            var use = refs.Where(kv => kv.Value != null && !exclude.Contains(kv.Key)).Select(kv => kv.Value!).ToList();
            var bare = new DefinitionSet();
            CalibrationDetector.Detect(bare, asm, asm.Image, [(Path.GetFullPath(path), dis.Text)], references: null);
            var defs = new DefinitionSet();
            var res = CalibrationDetector.Detect(defs, asm, asm.Image, [(Path.GetFullPath(path), dis.Text)], use);
            var truthAt = truth.GroupBy(t => t.Item1).ToDictionary(g => g.Key, g => g.Select(x => x.Item2).ToList());
            var named = defs.Items.Where(i => i.Origin?.StartsWith("detected: like") == true).ToList();
            int right = named.Count(i => truthAt.TryGetValue(i.Address, out var ns) && ns.Contains(i.Name));
            int atTruth = named.Count(i => truthAt.ContainsKey(i.Address));
            int wrongName = named.Count(i => truthAt.TryGetValue(i.Address, out var ns) && !ns.Contains(i.Name));
            int named0 = bare.Items.Count(i => truthAt.ContainsKey(i.Address));
            Console.WriteLine($"  {name}: {dis.CodeInstructions} instructions; {truth.Count} known tables; without references {bare.Items.Count} found ({named0} at a known table's address, all with made-up names)");
            Console.WriteLine($"    with references: {res.Summary}");
            Console.WriteLine($"    named from references: {named.Count}; at a known table: {atTruth}; the same name: {right}; another name: {wrongName}; not a known table: {named.Count - atTruth}");
            foreach (var i in named.Where(i => truthAt.TryGetValue(i.Address, out var ns) && !ns.Contains(i.Name)).Take(12))
                Console.WriteLine($"      {i.Address:X4} named {i.Name} ({i.Origin}); known as {string.Join("/", truthAt[i.Address])}");
            var sorted = truth.OrderBy(t => t.Item1).ToList();
            foreach (var i in named.Where(i => !truthAt.ContainsKey(i.Address)).Take(name == "p30" ? 25 : 0))
            {
                var near = sorted.LastOrDefault(t => t.Item1 < i.Address);
                Console.WriteLine($"      ? {i.Address:X4} {i.Name} ({i.Origin?.Replace("detected: like ", "")}) - after {near.Item2} at {near.Item1:X4}");
            }
            foreach (var i in defs.Items.Where(i => System.Text.RegularExpressions.Regex.IsMatch(i.Name, "^(Fuel(Low|High)|Ignition(Low|High)2?|VE(Low|High)|RpmScaler|MapScaler)")))
                Console.WriteLine($"      map {i.Address:X4} {i.Name} {i.Rows}x{i.Cols} rows {i.RowAxis?.Address:X4} cols {i.ColAxis?.Address:X4} ({i.Origin})");
            int recall = truthAt.Keys.Count(a => defs.Items.Any(i => i.Address == a));
            Console.WriteLine($"    known tables found (any name): {recall} of {truthAt.Count}, without references {named0}");
            // HTS120 names its own tables differently from the stock ROMs: there only the places are compared
            check($"{name} as a bare image: tables named from references sit where a known table is, under the same name",
                  name == "HTS120" ? atTruth >= named.Count * 0.9 : right >= atTruth * 0.85, $"{right} of {atTruth} the same name, {atTruth} of {named.Count} at a known table");
        }
    }

    /// Every labelled data block of a source (its tables, under whatever names it gives them).
    static IEnumerable<(int, string)> DataLabels(string path, AssemblyResult asm)
    {
        foreach (var l in File.ReadLines(path))
        {
            var m = System.Text.RegularExpressions.Regex.Match(l, @"^([A-Za-z_]\w*):\s*D[BW]");
            if (m.Success && asm.Symbols.TryGetValue(m.Groups[1].Value, out var s)) yield return ((int)s.Value, m.Groups[1].Value);
        }
    }

    static AssemblerOptions Opts(Dictionary<string, long> d) { var o = new AssemblerOptions(); foreach (var (k, v) in d) o.Defines[k] = v; return o; }
    static int IndexOf(byte[] hay, byte[] needle, int from = 0)
    {
        for (int i = from; i + needle.Length <= hay.Length; i++)
            if (hay.AsSpan(i, needle.Length).SequenceEqual(needle)) return i;
        return -1;
    }
}
