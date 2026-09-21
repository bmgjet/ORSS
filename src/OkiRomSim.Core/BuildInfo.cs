using System.Reflection;

namespace OkiRomSim.Core;

/// The version of this build, so someone running it can say which one they have. It comes from Directory.Build.props at the top of the tree; bump it there and every part of the program (title bar, Settings, Debug page, MCP handshake) reports the new one.
public static class BuildInfo
{
    public static string Version { get; } = Read();

    /// "Oki ROM Studio 0.0.0.1"
    public static string Full => $"{Product} {Version}";

    public const string Product = "Oki ROM Studio";

    static string Read()
    {
        var asm = Assembly.GetEntryAssembly() ?? typeof(BuildInfo).Assembly;
        var v = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (string.IsNullOrWhiteSpace(v)) v = asm.GetName().Version?.ToString() ?? "0.0.0.0";
        // strip a source-revision suffix if the build added one ("0.0.0.1+abc123")
        int plus = v.IndexOf('+');
        return plus > 0 ? v[..plus] : v;
    }
}
