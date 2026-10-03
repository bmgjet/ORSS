// Copyright (c) bmgjet. All rights reserved.
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Loader;

namespace OkiRomSim.Desktop;

/// A distribution build (dotnet publish -p:Bundle=true) carries its libraries - Avalonia, the assembler, the calibration code, and the rest - inside RomSimStudio.dll, so there are only a few files to hand out. They are loaded from there the first time they are needed. What differs between platforms stays in the runtimes folder beside it: the native libraries (drawing, text) and the per-platform builds of a few libraries (serial ports), picked for the machine it runs on. Nothing in here may touch Avalonia: it runs before anything else, to be ready when the first library is asked for.
static class EmbeddedLibraries
{
    const string Prefix = "deps/";
    static readonly Assembly Self = typeof(EmbeddedLibraries).Assembly;
    static readonly string Dir = AppContext.BaseDirectory;

    [ModuleInitializer]
    internal static void Install()
    {
        if (!Self.GetManifestResourceNames().Any(n => n.StartsWith(Prefix, StringComparison.Ordinal))) return;   // an ordinary build
        AssemblyLoadContext.Default.Resolving += (context, name) => Load(context, name);
        AssemblyLoadContext.Default.ResolvingUnmanagedDll += (_, lib) => Native(lib);
    }

    /// The platform names the runtimes folder uses, most specific first ("win-x64", "win").
    static IEnumerable<string> Platforms()
    {
        string os = OperatingSystem.IsWindows() ? "win" : OperatingSystem.IsMacOS() ? "osx" : OperatingSystem.IsLinux() ? "linux" : "unix";
        string arch = RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant();
        yield return $"{os}-{arch}";
        if (os is "linux" or "osx") { yield return $"unix-{arch}"; yield return os; yield return "unix"; }
        else yield return os;
    }

    static Assembly? Load(AssemblyLoadContext context, AssemblyName name)
    {
        var file = name.Name + ".dll";
        // a library with a build of its own for this platform (serial ports on Windows / Linux / macOS): that one
        foreach (var p in Platforms())
        {
            var libDir = Path.Combine(Dir, "runtimes", p, "lib");
            if (!Directory.Exists(libDir)) continue;
            var found = Directory.GetDirectories(libDir).OrderByDescending(d => d, StringComparer.Ordinal)
                                 .Select(d => Path.Combine(d, file)).FirstOrDefault(File.Exists);
            if (found != null) return context.LoadFromAssemblyPath(found);
        }
        // one beside the app (a newer copy dropped in) wins over the one inside
        var beside = Path.Combine(Dir, file);
        if (File.Exists(beside)) return context.LoadFromAssemblyPath(beside);
        using var s = Self.GetManifestResourceStream(Prefix + file);
        if (s == null) return null;
        var bytes = new byte[s.Length];
        s.ReadExactly(bytes);
        return context.LoadFromStream(new MemoryStream(bytes));
    }

    /// A native library (SkiaSharp, HarfBuzz...): from runtimes/{platform}/native.
    static IntPtr Native(string lib)
    {
        string[] names = OperatingSystem.IsWindows() ? [lib + ".dll", lib]
                       : OperatingSystem.IsMacOS() ? [lib + ".dylib", "lib" + lib + ".dylib", lib]
                       : [lib + ".so", "lib" + lib + ".so", lib];
        foreach (var p in Platforms())
            foreach (var n in names)
            {
                var path = Path.Combine(Dir, "runtimes", p, "native", n);
                if (File.Exists(path) && NativeLibrary.TryLoad(path, out var h)) return h;
            }
        return IntPtr.Zero;
    }
}
