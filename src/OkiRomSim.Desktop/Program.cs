using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;

namespace OkiRomSim.Desktop;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // `OkiRomSimStudio --mcp [--root DIR]... [--read-only]` runs the MCP server over stdio for a
        // local LLM agent instead of opening the window (same tools as okirom-mcp).
        if (args.Contains("--mcp")) return RunMcp(args);
        // Errors on background threads are logged (Debug page and %TEMP%) rather than lost.
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            OkiRomSim.Core.AppLog.Error("app", "unhandled exception" + (e.IsTerminating ? " (fatal)" : ""), e.ExceptionObject as Exception);
            try { File.AppendAllText(Path.Combine(Path.GetTempPath(), "OkiRomSimStudio-errors.log"), $"{DateTime.Now:s} {e.ExceptionObject}\n\n"); } catch { }
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            OkiRomSim.Core.AppLog.Error("app", "background task failed", e.Exception);
            e.SetObserved();
        };
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        return 0;
    }

    static int RunMcp(string[] args)
    {
        var roots = new List<string>();
        for (int i = 0; i < args.Length; i++)
            if (args[i] == "--root" && i + 1 < args.Length) roots.Add(args[++i]);
        if (roots.Count == 0) roots.Add(Directory.GetCurrentDirectory());
        var server = new OkiRomSim.Mcp.McpServer(new OkiRomSim.Mcp.Workspace(roots) { ReadOnly = args.Contains("--read-only") })
        {
            Log = c => Console.Error.WriteLine($"{DateTime.Now:HH:mm:ss} {c.Client} {(c.Ok ? "ok " : "ERR")} {c.Tool} {c.Milliseconds} ms"),
        };
        // stdout carries the protocol and nothing else: anything else that writes to the
        // console goes to stderr, so a stray message cannot corrupt a reply
        var protocolOut = new StreamWriter(Console.OpenStandardOutput(), new System.Text.UTF8Encoding(false));
        Console.SetOut(Console.Error);
        OkiRomSim.Mcp.McpStdio.RunAsync(server, new StreamReader(Console.OpenStandardInput(), System.Text.Encoding.UTF8), protocolOut).GetAwaiter().GetResult();
        return 0;
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}

public sealed class App : Application
{
    public override void Initialize()
    {
        Styles.Add(new FluentTheme());
        // AvaloniaEdit ships its own control theme; without it the editor renders unstyled.
        // The resource path moved between AvaloniaEdit versions, so try both and carry on if
        // neither is there - the editor still works, it just looks plain.
        foreach (var path in new[] { "avares://AvaloniaEdit/Themes/Fluent/AvaloniaEdit.xaml",
                                     "avares://AvaloniaEdit/Themes/Fluent.xaml" })
        {
            try
            {
                Styles.Add(new Avalonia.Markup.Xaml.Styling.StyleInclude(new Uri("avares://OkiRomSimStudio/"))
                {
                    Source = new Uri(path),
                });
                break;
            }
            catch { }
        }
        try
        {
            Styles.Add(new Avalonia.Markup.Xaml.Styling.StyleInclude(new Uri("avares://OkiRomSimStudio/"))
            {
                Source = new Uri("avares://Avalonia.Controls.ColorPicker/Themes/Fluent/Fluent.xaml"),
            });
        }
        catch { }
        RequestedThemeVariant = ThemeVariant.Dark;
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var path = desktop.Args?.FirstOrDefault(a => !a.StartsWith('-'));
            // the title bar is decided before the first window is built
            try { DarkChrome.PreferSystemTitleBar = AppSettings.Load().SystemTitleBar; } catch { }
            desktop.MainWindow = new MainWindow(path);
        }
        base.OnFrameworkInitializationCompleted();
    }
}
