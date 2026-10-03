// Copyright (c) bmgjet. All rights reserved.
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;

namespace OkiRomSim.Calibration;

/// What a carry of one ROM's calibration onto a rebuild did: the settings and maps brought across (and how many of them were tuned away from the factory value), and the ones that could not be (a table that changed size between the two).
public sealed record CarryResult(List<BytePatch> Patches, int Carried, int Tuned, List<string> Skipped, List<string> New);

/// File > Change functions: a ROM built from a skeleton rebuilt with other functions, its tune kept. Which functions a ROM was built with comes from its build file (the define lines), or from the build-info table every skeleton build carries (buildinfo.asm: "OKF", 01h, one number a function, 00h), so a .bin on its own says. The tune goes across setting by setting, by name: everything the two builds both have - the stock maps, every module's settings - lands where the new build put it, and what is new starts at its factory value.
public static class SkeletonRebuild
{
    static readonly byte[] Signature = [0x4F, 0x4B, 0x46, 0x01];

    /// The numbers buildinfo.asm gives the functions (number -> define).
    public static Dictionary<int, string> Numbers(Skeleton sk)
    {
        var map = new Dictionary<int, string>();
        var file = sk.FeaturesDir == null ? null : Path.Combine(sk.FeaturesDir, "buildinfo.asm");
        if (file == null || !File.Exists(file)) return map;
        string? define = null;
        foreach (var raw in File.ReadLines(file))
        {
            var l = raw.Trim();
            var d = Regex.Match(l, @"^if\s+defined\((FEAT_\w+)\)", RegexOptions.IgnoreCase);
            if (d.Success) { define = d.Groups[1].Value; continue; }
            var n = Regex.Match(l, @"^DB\s+0*([0-9A-Fa-f]+)h\b", RegexOptions.IgnoreCase);
            if (define != null && n.Success) { map[Convert.ToInt32(n.Groups[1].Value, 16)] = define; define = null; }
        }
        return map;
    }

    /// The functions an image was built with, read from its build-info table; null when it has none (not built from this skeleton, or built before the table was added).
    public static List<string>? FunctionsIn(byte[] image, Skeleton sk)
    {
        var numbers = Numbers(sk);
        if (numbers.Count == 0) return null;
        List<string>? found = null;
        for (int at = 0; at + Signature.Length < image.Length; at++)
        {
            if (!image.AsSpan(at, Signature.Length).SequenceEqual(Signature)) continue;
            var list = new List<string>();
            int i = at + Signature.Length;
            for (; i < image.Length && i < at + 4 + 255 && image[i] != 0; i++)
            {
                if (!numbers.TryGetValue(image[i], out var d)) { list = null; break; }
                list.Add(d);
            }
            if (list == null || i >= image.Length || image[i] != 0) continue;
            if (found != null) return null;       // two tables: cannot tell which
            found = list;
        }
        return found;
    }

    /// The functions a build file switches on, and the skeleton it includes (null when it is not a skeleton build file).
    public static (string Skeleton, List<string> Defines)? FromBuildFile(string path, string text)
    {
        var inc = text.Split('\n').Select(l => Regex.Match(l, @"^\s*include\s+""([^""]+-skeleton\.asm)""", RegexOptions.IgnoreCase)).FirstOrDefault(m => m.Success);
        if (inc == null) return null;
        var sk = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(path))!, inc.Groups[1].Value.Replace('/', Path.DirectorySeparatorChar)));
        return (sk, Skeleton.DefinesIn(text));
    }

    /// The build file with these functions switched on and the rest off: each define line commented in or out where it is, and a line added (before the include) for any function the file does not list yet. Everything else - comments, other defines, what the app keeps at the end - stays as it is.
    public static string WithFunctions(string text, Skeleton sk, IEnumerable<string> defines)
    {
        var want = new HashSet<string>(defines, StringComparer.OrdinalIgnoreCase);
        var nl = text.Contains("\r\n") ? "\r\n" : "\n";
        var lines = text.Replace("\r\n", "\n").Split('\n').ToList();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var rx = new Regex(@"^(\s*)(;\s*)?define\s+(FEAT_\w+)(.*)$", RegexOptions.IgnoreCase);
        for (int i = 0; i < lines.Count; i++)
        {
            var m = rx.Match(lines[i]);
            if (!m.Success) continue;
            var d = m.Groups[3].Value;
            if (sk.Feature(d) == null) continue;              // not one of the skeleton's: the user's own, left alone
            if (!seen.Add(d)) { if (m.Groups[2].Success == false && !want.Contains(d)) lines[i] = ";" + lines[i].TrimStart(); continue; }
            bool on = !m.Groups[2].Success;
            if (on == want.Contains(d)) continue;
            var rest = $"define {d}{m.Groups[4].Value}";
            lines[i] = m.Groups[1].Value + (want.Contains(d) ? rest : ";" + rest);
        }
        int inc = lines.FindIndex(l => Regex.IsMatch(l, @"^\s*include\s+""[^""]+-skeleton\.asm""", RegexOptions.IgnoreCase));
        var add = sk.Features.Where(f => want.Contains(f.Define) && !seen.Contains(f.Define))
                    .Select(f => $"define {f.Define,-26} ; {f.Name}").ToList();
        if (add.Count > 0) lines.InsertRange(inc < 0 ? lines.Count : inc, ["; ---- added by File > Change functions", .. add, ""]);
        return string.Join(nl, lines);
    }

    /// How closely an image matches a build: the bytes that differ outside the calibration (the settings and maps, and the checksum byte), of the bytes the build uses. A ROM built from the same skeleton with the same functions differs only in its tune, so this is 0; an older skeleton's build differs in its code.
    public static int CodeDifferences(AssemblyResult build, DefinitionSet defs, byte[] image)
    {
        if (image.Length != build.Image.Length) return int.MaxValue;
        var cal = new bool[image.Length];
        foreach (var it in defs.Items)
            foreach (var (a, n) in Spans(it))
                for (int k = 0; k < n && a + k < cal.Length; k++) if (a + k >= 0) cal[a + k] = true;
        int diff = 0;
        for (int i = 0; i < image.Length - 1; i++)             // (the last byte is the checksum)
            if (!cal[i] && image[i] != build.Image[i]) diff++;
        return diff;
    }

    /// Bring the tune across: every setting and map the new build shares with the old one (the same name, the same size) gets the old image's bytes, with its axes. Patches only where the bytes differ.
    public static CarryResult Carry(DefinitionSet oldDefs, byte[] oldImage, DefinitionSet newDefs, byte[] newImage)
    {
        var old = oldDefs.Items.GroupBy(i => i.Name, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
        var patches = new Dictionary<int, byte>();
        var skipped = new List<string>();
        var fresh = new List<string>();
        int carried = 0, tuned = 0;
        foreach (var it in newDefs.Items.DistinctBy(i => i.Name, StringComparer.OrdinalIgnoreCase))
        {
            if (it.Name.Length == 0 || it.Name.StartsWith("item_", StringComparison.Ordinal)) continue;
            if (!old.TryGetValue(it.Name, out var was)) { fresh.Add(it.Name); continue; }
            var from = Spans(was).ToList();
            var to = Spans(it).ToList();
            if (from.Count != to.Count || from.Zip(to).Any(p => p.First.Length != p.Second.Length)) { skipped.Add(it.Name); continue; }
            carried++;
            bool changed = false;
            foreach (var ((fa, n), (ta, _)) in from.Zip(to))
                for (int k = 0; k < n; k++)
                {
                    if (fa + k < 0 || fa + k >= oldImage.Length || ta + k < 0 || ta + k >= newImage.Length) continue;
                    byte v = oldImage[fa + k];
                    if (newImage[ta + k] != v) { patches[ta + k] = v; changed = true; }
                }
            if (changed) tuned++;
        }
        return new CarryResult([.. patches.OrderBy(p => p.Key).Select(p => new BytePatch(p.Key, p.Value))], carried, tuned, skipped, fresh);
    }

    /// The bytes a definition takes up: its cells (with the rows' stride and the multiplier row) and the axes it keeps in the ROM.
    static IEnumerable<(int Address, int Length)> Spans(ItemDef it)
    {
        yield return (it.Address, Math.Max(1, it.Span));
        foreach (var ax in new[] { it.RowAxis, it.ColAxis })
        {
            if (ax?.Address is not int a || ax.Count <= 0) continue;
            int size = ax.Type is CellType.U16 or CellType.S16 or CellType.U16BE or CellType.S16BE ? 2 : 1;
            int step = ax.Stride > 0 ? ax.Stride : size;
            yield return (a, (ax.Count - 1) * step + size);
        }
    }
}
