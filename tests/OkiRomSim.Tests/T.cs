// Copyright (c) bmgjet. All rights reserved.
using System.Security.Cryptography;
using OkiRomSim.Assembler;
using OkiRomSim.Core;

namespace OkiRomSim.Tests;

/// The checks and what the tests share: where the repository is, scratch folders, hashes, assembling.
static class T
{
    public static int Passed, Failed, Skipped;
    public static readonly List<string> Failures = [];
    static string _group = "";

    public static void Group(string name, string about)
    {
        _group = name;
        Console.WriteLine();
        Console.WriteLine($"== {name}: {about}");
    }

    public static bool Check(string what, bool ok, string detail = "")
    {
        Console.WriteLine($"  {(ok ? "PASS" : "FAIL")}  {what}{(detail.Length > 0 ? "  -  " + detail : "")}");
        if (ok) Passed++;
        else { Failed++; Failures.Add($"[{_group}] {what}{(detail.Length > 0 ? " - " + detail : "")}"); }
        return ok;
    }

    public static void Skip(string what, string why)
    {
        Console.WriteLine($"  SKIP  {what}  -  {why}");
        Skipped++;
    }

    /// An action that must throw `TEx` (and nothing else).
    public static bool Throws<TEx>(string what, Action a, Func<TEx, bool>? also = null) where TEx : Exception
    {
        try { a(); return Check(what, false, "no exception"); }
        catch (TEx ex) { return Check(what, also?.Invoke(ex) ?? true, ex.Message); }
        catch (Exception ex) { return Check(what, false, $"{ex.GetType().Name}: {ex.Message}"); }
    }

    /// The repository root: the folder above this program's with roms/ and src/ in it.
    public static string Root { get; } = FindRoot();

    static string FindRoot()
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d != null; d = d.Parent)
            if (Directory.Exists(Path.Combine(d.FullName, "roms")) && Directory.Exists(Path.Combine(d.FullName, "src"))) return d.FullName;
        throw new DirectoryNotFoundException("the repository (roms/ and src/) is not above " + AppContext.BaseDirectory);
    }

    public static string Roms(string name) => Path.Combine(Root, "roms", name);
    public static string Data(string name) => Path.Combine(AppContext.BaseDirectory, "data", name);

    /// A folder of its own under the temp folder, removed when the scope ends.
    public static Scratch NewScratch(string tag) => new(tag);

    public sealed class Scratch : IDisposable
    {
        public string Dir { get; }
        public Scratch(string tag)
        {
            Dir = Path.Combine(Path.GetTempPath(), $"okirom-tests-{tag}-{Environment.ProcessId}-{Guid.NewGuid().ToString("N")[..12]}");
            Directory.CreateDirectory(Dir);
        }
        public string File(string name) => Path.Combine(Dir, name);
        /// A copy of a repository file in this folder, to work on instead of the original.
        public string Copy(string source, string? name = null)
        {
            var to = File(name ?? Path.GetFileName(source));
            System.IO.File.Copy(source, to, overwrite: true);
            return to;
        }
        public void Dispose() { try { Directory.Delete(Dir, true); } catch { } }
    }

    public static string Sha256(byte[] b) => Convert.ToHexString(SHA256.HashData(b));
    public static string Sha256(string file) => Sha256(System.IO.File.ReadAllBytes(file));
    public static int Sum8(byte[] b) { int s = 0; foreach (var x in b) s += x; return s & 0xFF; }

    public static AssemblyResult Assemble(string path)
    {
        var text = System.IO.File.ReadAllText(path);
        (ProcessorProfile.Declared(text) ?? ProcessorProfile.Msm66207()).Apply();
        return new OkiAssembler(new AssemblerOptions()).AssembleFile(path);
    }

    /// The 66207 profile back on (most tests assume the P30's part).
    public static void P30Part() => ProcessorProfile.Msm66207().Apply();
    public static void P13Part() => ProcessorProfile.Msm66911().Apply();

    /// Lines "key<TAB>value" of a data file, # comments and blank lines left out.
    public static Dictionary<string, string> ReadPairs(string file) =>
        System.IO.File.ReadAllLines(file).Where(l => l.Length > 0 && !l.StartsWith('#')).Select(l => l.Split('\t', 2))
            .ToDictionary(p => p[0], p => p.Length > 1 ? p[1] : "");
}
