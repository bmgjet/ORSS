// Copyright (c) bmgjet. All rights reserved.
extern alias tuner;
using System.Diagnostics;
using System.Reflection;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Text.Json.Nodes;

namespace OkiRomSim.Tests;

/// The two builds as built by this configuration (both are built before the tests run): what RomSimTuner references and needs at run
/// time - nothing of the simulator, MCP or ASP.NET Core, which is what makes it a build of its own rather than the full program with
/// pages hidden - and each program's own self-tests, run as the programs themselves on copies of the ROMs.
static class BuildTests
{
    static string Configuration => typeof(BuildTests).Assembly.GetCustomAttribute<AssemblyConfigurationAttribute>()?.Configuration ?? "Release";
    static string Output(string project) => Path.Combine(T.Root, "src", project, "bin", Configuration, "net10.0");

    /// The names of the assemblies a .dll references (read from its metadata, without loading it).
    static List<string> References(string dll)
    {
        using var fs = File.OpenRead(dll);
        using var pe = new PEReader(fs);
        var md = pe.GetMetadataReader();
        return [.. md.AssemblyReferences.Select(h => md.GetString(md.GetAssemblyReference(h).Name))];
    }

    static List<string> Frameworks(string runtimeConfig)
    {
        var o = JsonNode.Parse(File.ReadAllText(runtimeConfig))?["runtimeOptions"];
        var list = new List<string>();
        if (o?["framework"]?["name"]?.GetValue<string>() is { } one) list.Add(one);
        if (o?["frameworks"] is JsonArray many) list.AddRange(many.Select(f => f?["name"]?.GetValue<string>() ?? "?"));
        return list;
    }

    public static void Run()
    {
        string tunerDir = Output("OkiRomSim.Tuner"), fullDir = Output("OkiRomSim.Desktop");
        string tuner = Path.Combine(tunerDir, "RomSimTuner.dll"), full = Path.Combine(fullDir, "RomSimStudio.dll");
        if (!T.Check($"both programs are built ({Configuration})", File.Exists(tuner) && File.Exists(full), $"{tuner} / {full}")) return;

        // ---- the tuner on its own
        string[] never = ["OkiRomSim.Sim", "OkiRomSim.Mcp", "RomSimStudio", "AvaloniaEdit", "Microsoft.AspNetCore"];
        var refs = References(tuner);
        var bad = refs.Where(r => never.Any(n => r.StartsWith(n, StringComparison.Ordinal))).ToList();
        T.Check("RomSimTuner.dll references no simulator, MCP, Rom Sim Studio, code-editor or ASP.NET Core assembly", bad.Count == 0,
            bad.Count == 0 ? string.Join(", ", refs.Where(r => r.StartsWith("OkiRomSim", StringComparison.Ordinal))) : string.Join(", ", bad));
        T.Check("... and references the shared parts (Core, Assembler, Calibration)", new[] { "OkiRomSim.Core", "OkiRomSim.Assembler", "OkiRomSim.Calibration" }.All(refs.Contains));
        var deep = new[] { "OkiRomSim.Core", "OkiRomSim.Assembler", "OkiRomSim.Calibration" }
            .SelectMany(d => References(Path.Combine(tunerDir, d + ".dll")).Where(r => never.Any(n => r.StartsWith(n, StringComparison.Ordinal))).Select(r => $"{d} -> {r}")).ToList();
        T.Check("... nor do the shared parts it uses (nothing reaches the simulator the long way round)", deep.Count == 0, string.Join(", ", deep));
        var stray = new[] { "OkiRomSim.Sim.dll", "OkiRomSim.Mcp.dll", "RomSimStudio.dll", "AvaloniaEdit.dll" }.Where(f => File.Exists(Path.Combine(tunerDir, f))).ToList();
        T.Check("the tuner's build folder holds none of them", stray.Count == 0, string.Join(", ", stray));
        var fw = Frameworks(Path.Combine(tunerDir, "RomSimTuner.runtimeconfig.json"));
        T.Check("RomSimTuner needs only the .NET runtime (Microsoft.NETCore.App)", fw.SequenceEqual(["Microsoft.NETCore.App"]), string.Join(", ", fw));
        var fwFull = Frameworks(Path.Combine(fullDir, "RomSimStudio.runtimeconfig.json"));
        T.Check("(Rom Sim Studio needs ASP.NET Core as well, for its MCP server)", fwFull.Contains("Microsoft.NETCore.App") && fwFull.Contains("Microsoft.AspNetCore.App"), string.Join(", ", fwFull));

        TunerSettings();

        // ---- the programs' own self-tests, on copies
        using var s = T.NewScratch("builds");
        var p30 = s.Copy(T.Roms("p30.bin"));
        var p13 = s.Copy(T.Roms("p13.bin"));
        s.Copy(T.Roms("p30-build.asm"));
        s.Copy(T.Roms("p30-skeleton.asm"));
        Directory.CreateDirectory(s.File("p30-features"));
        foreach (var f in Directory.GetFiles(T.Roms("p30-features"))) File.Copy(f, Path.Combine(s.File("p30-features"), Path.GetFileName(f)));
        var build = s.File("p30-build.asm");
        var before = Directory.GetFiles(s.Dir, "*", SearchOption.AllDirectories).ToDictionary(f => f, T.Sha256);

        foreach (var (what, rom) in new[] { ("p30.bin", p30), ("p13.bin", p13), ("p30-build.asm", build) })
            SelfTest($"RomSimTuner --selftest {what}", tuner, ["--selftest", rom], 120_000);
        SelfTest("RomSimStudio --selftest-smooth", full, ["--selftest-smooth"], 60_000);
        SelfTest("RomSimStudio --selftest-project p30-build.asm", full, ["--selftest-project", build], 180_000);
        SelfTest("RomSimStudio --selftest-live p30-build.asm", full, ["--selftest-live", build], 180_000);

        var changed = before.Where(kv => !File.Exists(kv.Key) || T.Sha256(kv.Key) != kv.Value).Select(kv => Path.GetFileName(kv.Key)).ToList();
        T.Check("the self-tests changed none of the files they were given", changed.Count == 0, string.Join(", ", changed));
    }

    /// RomSimTuner keeps its own settings file: its window, its last file and what it saves must not change how Rom Sim Studio starts.
    /// The first time it starts from Rom Sim Studio's settings, read and never written. (Run with the settings folder moved to a
    /// scratch folder through XDG_CONFIG_HOME, so nothing of this PC's settings is touched - which is why it is not run on Windows.)
    static void TunerSettings()
    {
        if (OperatingSystem.IsWindows()) { T.Skip("RomSimTuner keeps a settings file of its own", "the settings folder cannot be moved aside on Windows"); return; }
        var was = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        using var s = T.NewScratch("settings");
        try
        {
            Environment.SetEnvironmentVariable("XDG_CONFIG_HOME", s.Dir);
            var path = tuner::OkiRomSim.Desktop.AppSettings.FilePath;
            if (!T.Check("RomSimTuner's settings file is its own (tuner-settings.json)", Path.GetFileName(path) == "tuner-settings.json" && path.StartsWith(s.Dir, StringComparison.Ordinal), path)) return;
            var studio = Path.Combine(Path.GetDirectoryName(path)!, "settings.json");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(studio, "{ \"LastFile\": \"studio-marker.bin\", \"Theme\": \"light\" }");
            var before = File.ReadAllBytes(studio);
            var first = tuner::OkiRomSim.Desktop.AppSettings.Load();
            T.Check("the first time, it starts from Rom Sim Studio's settings", first.LastFile == "studio-marker.bin" && first.Theme == "light", $"{first.LastFile}, {first.Theme}");
            first.LastFile = "tuner-marker.bin";
            first.Save();
            var again = tuner::OkiRomSim.Desktop.AppSettings.Load();
            T.Check("what it saves goes to its own file, and Rom Sim Studio's is left exactly as it was",
                File.Exists(path) && again.LastFile == "tuner-marker.bin" && File.ReadAllBytes(studio).AsSpan().SequenceEqual(before));
        }
        finally { Environment.SetEnvironmentVariable("XDG_CONFIG_HOME", was); }
    }

    static void SelfTest(string what, string dll, string[] args, int timeoutMs)
    {
        var sw = Stopwatch.StartNew();
        var (exit, output) = RunDll(dll, args, timeoutMs);
        var lines = output.Split('\n').Select(l => l.TrimEnd('\r')).ToList();
        int pass = lines.Count(l => l.TrimStart().StartsWith("PASS", StringComparison.Ordinal));
        var fails = lines.Where(l => l.TrimStart().StartsWith("FAIL", StringComparison.Ordinal)).ToList();
        T.Check($"{what}: exit 0, every check passes", exit == 0 && fails.Count == 0 && pass > 0,
            exit == -1 ? output : fails.Count > 0 ? string.Join(" | ", fails.Take(3)) : $"{pass} checks passed in {sw.Elapsed.TotalSeconds:0.0} s (exit {exit})");
    }

    /// Run a framework-dependent program through the dotnet host that runs these tests.
    static (int Exit, string Output) RunDll(string dll, string[] args, int timeoutMs)
    {
        var psi = new ProcessStartInfo(DotnetHost()) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        psi.ArgumentList.Add("exec");
        psi.ArgumentList.Add(dll);
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(timeoutMs))
        {
            try { p.Kill(entireProcessTree: true); } catch { }
            return (-1, $"timed out after {timeoutMs / 1000} s");
        }
        p.WaitForExit();
        return (p.ExitCode, stdout.Result + stderr.Result);
    }

    static string DotnetHost()
    {
        var exe = OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet";
        if (Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") is { Length: > 0 } h && File.Exists(h)) return h;
        // the runtime these tests run on is <dotnet root>/shared/Microsoft.NETCore.App/<version>/
        var root = Path.GetFullPath(Path.Combine(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory(), "..", "..", ".."));
        return File.Exists(Path.Combine(root, exe)) ? Path.Combine(root, exe) : exe;
    }
}
