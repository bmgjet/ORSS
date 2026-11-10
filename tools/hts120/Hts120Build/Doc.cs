using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Core;

namespace Hts120Build;

/// An assembly source being transformed: its lines, and what they assemble to.
public sealed class Doc
{
    public List<string> Lines;
    public readonly string Path;   // where it is written (the assembler needs a file name for includes)

    public Doc(string path, IEnumerable<string> lines) { Path = path; Lines = [.. lines]; }

    public AssemblyResult Assemble()
    {
        var text = string.Join("\n", Lines);
        var full = System.IO.Path.GetFullPath(Path);
        var r = new OkiAssembler(new AssemblerOptions { ReadFile = f => f == full ? text : null }).AssembleText(text, full);
        return r;
    }

    public AssemblyResult AssembleOrThrow(string stage)
    {
        var r = Assemble();
        if (!r.Success)
        {
            Save();
            // the first line whose address comment ("; XXXX", in an older source) no longer matches where it assembled
            foreach (var (li, ents) in ByLine(r).OrderBy(k => k.Key))
            {
                var m = Regex.Match(Lines[li], @";\s*([0-9A-F]{4})\b");
                if (m.Success && ents.Count > 0 && Convert.ToInt32(m.Groups[1].Value, 16) != ents[0].Address)
                { Console.WriteLine($"  first drift at line {li + 1}: expected {m.Groups[1].Value}, assembled at {ents[0].Address:X4}: {Lines[li].Trim()}"); break; }
            }
            throw new Exception($"{stage}: does not assemble\n" + string.Join("\n", r.Diagnostics.Where(d => d.Severity == Severity.Error).Take(12)));
        }
        return r;
    }

    public void Save() => File.WriteAllText(Path, string.Join("\n", Lines));

    // ------------------------------------------------------------ line helpers

    static readonly Regex LabelRe = new(@"^([A-Za-z_.?$@][\w.?$@]*):", RegexOptions.Compiled);

    /// The code part of a line (before any ';'), without its label.
    public static string Body(string line)
    {
        var code = line.Split(';', 2)[0];
        var m = LabelRe.Match(code);
        return (m.Success ? code[m.Length..] : code).Trim();
    }

    public static string? Label(string line)
    {
        var m = LabelRe.Match(line);
        return m.Success ? m.Groups[1].Value : null;
    }

    public static bool IsData(string line) => Regex.IsMatch(Body(line), @"^(DB|DW)\b", RegexOptions.IgnoreCase);

    /// source line index (0-based) -> the statements it produced
    public static Dictionary<int, List<SourceMapEntry>> ByLine(AssemblyResult r) =>
        r.SourceMap.GroupBy(e => e.Line - 1).ToDictionary(g => g.Key, g => g.ToList());

    public HashSet<string> LabelNames() =>
        [.. Lines.Select(Label).Where(l => l != null).Select(l => l!)];
}
