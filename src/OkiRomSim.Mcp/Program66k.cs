// Copyright (c) bmgjet. All rights reserved.
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Core;

namespace OkiRomSim.Mcp;

/// A ROM loaded for the tools: its bytes, and when there is source (a .asm, or a .bin disassembled on the fly) the assembly result with symbols and the source text, so every address can be named and traced to a line.
public sealed class Program66k
{
    public required string Path { get; init; }
    public required byte[] Image { get; init; }
    public AssemblyResult? Asm { get; init; }
    /// source file (full path or the virtual name of a disassembly) -> lines
    public Dictionary<string, string[]> Sources { get; } = new(StringComparer.OrdinalIgnoreCase);
    public bool FromBinary { get; init; }

    static readonly Dictionary<string, (DateTime Stamp, Program66k Program)> Cache = new(StringComparer.OrdinalIgnoreCase);
    static readonly Regex DataLine = new(@"^\s*([A-Za-z_][\w]*\s*:)?\s*(DB|DW|DS)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// Load a .asm (assembled) or .bin/.rom (disassembled, then assembled from that text).
    public static Program66k Load(string fullPath, Func<string, bool>? allowInclude = null)
    {
        var stamp = File.GetLastWriteTimeUtc(fullPath);
        lock (Cache)
            if (Cache.TryGetValue(fullPath, out var c) && c.Stamp == stamp) return c.Program;
        Program66k p;
        if (fullPath.EndsWith(".asm", StringComparison.OrdinalIgnoreCase) || fullPath.EndsWith(".inc", StringComparison.OrdinalIgnoreCase))
        {
            var asm = new OkiAssembler(new AssemblerOptions { AllowFile = allowInclude }).AssembleFile(fullPath);
            if (!asm.Success)
            {
                var first = asm.Diagnostics.Where(d => d.Severity == Severity.Error).Take(5).Select(d => $"{System.IO.Path.GetFileName(d.File)}:{d.Line}: {d.Message}");
                throw new ToolException("the source does not assemble; fix these first (see `assemble`):\n  " + string.Join("\n  ", first));
            }
            p = new Program66k { Path = fullPath, Image = asm.Image, Asm = asm };
            foreach (var f in asm.SourceMap.Select(e => e.File).Distinct())
                if (File.Exists(f)) p.Sources[f] = File.ReadAllLines(f);
        }
        else
        {
            var bytes = File.ReadAllBytes(fullPath);
            if (bytes.Length > Bus.RomSize + 1) throw new ToolException($"{System.IO.Path.GetFileName(fullPath)} is {bytes.Length} bytes; a 66207 image is at most {Bus.RomSize}");
            p = FromImage(bytes, fullPath);
        }
        lock (Cache) Cache[fullPath] = (stamp, p);
        return p;
    }

    /// An image in memory (disassembled, then assembled from that text for symbols and lines).
    public static Program66k FromImage(byte[] bytes, string path)
    {
        var image = new byte[Bus.RomSize];
        Array.Fill(image, (byte)0xFF);
        Array.Copy(bytes, image, Math.Min(bytes.Length, Bus.RomSize));
        string virt = System.IO.Path.ChangeExtension(System.IO.Path.GetFullPath(path), ".disasm.asm");
        var dis = Disassemble(image, path, virt);
        var asm = new OkiAssembler(new AssemblerOptions { ReadFile = f => string.Equals(f, virt, StringComparison.OrdinalIgnoreCase) ? dis.Text : null })
            .AssembleText(dis.Text, virt);
        var p = new Program66k { Path = path, Image = image, Asm = asm.Success ? asm : null, FromBinary = true };
        p.Sources[virt] = dis.Text.Replace("\r", "").Split('\n');
        return p;
    }

    /// An assembly built elsewhere (the desktop app's), with the source text as it is on screen.
    public static Program66k FromAssembly(string path, byte[] image, AssemblyResult asm, IEnumerable<(string Path, string Text)> sources)
    {
        var p = new Program66k { Path = path, Image = [.. image], Asm = asm };
        foreach (var (f, text) in sources)
            try { p.Sources[System.IO.Path.GetFullPath(f)] = text.Replace("\r", "").Split('\n'); } catch { }
        foreach (var f in asm.SourceMap.Select(e => e.File).Distinct())
            if (!p.Sources.ContainsKey(f) && File.Exists(f)) p.Sources[f] = File.ReadAllLines(f);
        return p;
    }

    public static BinDisassembly Disassemble(byte[] image, string title, string virtualPath) =>
        BinDisassembler.Disassemble(image, System.IO.Path.GetFileName(title), text =>
        {
            var r = new OkiAssembler(new AssemblerOptions { ReadFile = f => string.Equals(f, virtualPath, StringComparison.OrdinalIgnoreCase) ? text : null })
                .AssembleText(text, virtualPath);
            return (r.Success ? r.Image : null, r.Diagnostics.Where(d => d.Severity == Severity.Error).Select(d => d.Line));
        });

    // ------------------------------------------------------------------ names and lines

    public Dictionary<int, string> Labels => field ??= Asm?.Symbols.Values.Where(s => s.Kind == SymbolKind.Label)
        .GroupBy(s => (int)s.Value).ToDictionary(g => g.Key, g => g.OrderBy(s => s.Name.Length).First().Name) ?? [];
    int[]? _labelAddrs;

    public string Name(int addr)
    {
        if (Labels.TryGetValue(addr, out var n)) return n;
        _labelAddrs ??= [.. Labels.Keys.OrderBy(a => a)];
        int i = Array.BinarySearch(_labelAddrs, addr);
        if (i < 0) i = ~i - 1;
        if (i < 0) return $"{addr:X4}h";
        int b = _labelAddrs[i];
        return addr - b < 0x400 ? $"{Labels[b]}+{addr - b:X}h" : $"{addr:X4}h";
    }

    public bool TryResolve(string text, out int addr)
    {
        text = text.Trim();
        addr = 0;
        if (Asm != null && Asm.Symbols.TryGetValue(text, out var s)) { addr = (int)s.Value; return true; }
        if (Asm != null)
        {
            var ci = Asm.Symbols.Values.FirstOrDefault(x => string.Equals(x.Name, text, StringComparison.OrdinalIgnoreCase));
            if (ci != null) { addr = (int)ci.Value; return true; }
        }
        var t = text.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? text[2..] : text.EndsWith("h", StringComparison.OrdinalIgnoreCase) ? text[..^1] : text;
        return int.TryParse(t, System.Globalization.NumberStyles.HexNumber, null, out addr);
    }

    public int Resolve(string text) => TryResolve(text, out var a) ? a : throw new ToolException($"cannot resolve '{text}' (a label, or a hex address like 3DDE / 3DDEh)");

    public (string File, int Line, string Text)? SourceAt(int addr)
    {
        var e = Asm?.Lookup(addr);
        return e == null || !Sources.TryGetValue(e.File, out var lines) || e.Line < 1 || e.Line > lines.Length
            ? null
            : (e.File, e.Line, lines[e.Line - 1]);
    }

    /// Code, as opposed to DB/DW data, according to the source.
    public bool IsCode(int addr)
    {
        var s = SourceAt(addr);
        return s != null && !DataLine.IsMatch(s.Value.Text);
    }

    /// Decode the instruction at `addr`, using the source line to settle the DD ambiguity (the source says LB or L, ADDB or ADD...). Without source, `ddHint` decides.
    public Decoded? DecodeAt(int addr, bool ddHint = true)
    {
        Decoded? Try(bool dd) => Decoder.Decode(dd, i => Image[(addr + i) & (Bus.RomSize - 1)]);
        var w = Try(true); var b = Try(false);
        if (w == null) return b;
        if (b == null || w.Mnemonic == b.Mnemonic && w.Len == b.Len) return w;
        var src = SourceAt(addr)?.Text;
        if (src != null)
        {
            var code = StripLabel(src);
            var op = code.Split(new[] { ' ', '\t' }, 2, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToUpperInvariant() ?? "";
            if (w.Mnemonic.Split(' ')[0] == op) return w;
            if (b.Mnemonic.Split(' ')[0] == op) return b;
        }
        return ddHint ? w : b;
    }

    public static string StripLabel(string line)
    {
        int c = line.IndexOf(';');
        if (c >= 0) line = line[..c];
        var m = Regex.Match(line, @"^\s*[A-Za-z_][\w]*\s*:");
        return (m.Success ? line[m.Length..] : line).Trim();
    }
}
