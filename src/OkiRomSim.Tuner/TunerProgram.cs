// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;

namespace OkiRomSim.Desktop;

/// RomSimTuner: the tuning-only build of Rom Sim Studio. The calibration editor, live datalogging and the ROM emulator - what Rom Sim
/// Studio's Tuner mode shows - built from the same source files with no simulator, MCP server or plugin loader in the program. It
/// has the updater, fed from its own list on the site (index.php?updates&amp;product=tuner, files-tuner/).
public static class TunerProgram
{
    [STAThread]
    public static int Main(string[] args)
    {
        // --selftest <rom.bin|build.asm>: the tuning paths with no window (open, definitions, an edit, undo, the checksum, save) - PASS / FAIL, exit 0 or 1
        if (Array.IndexOf(args, "--selftest") is int st and >= 0 && st + 1 < args.Length) return TunerSelfTest.Run(args[st + 1]);
        // --update-check [folder [site]]: what the start-up update check would offer for the install in that folder (default: this one); a site to check instead of the real one
        if (Array.IndexOf(args, "--update-check") is int uc and >= 0) return Updater.CheckFromCommandLine(uc + 1 < args.Length ? args[uc + 1] : null, uc + 2 < args.Length ? args[uc + 2] : null);
        // Errors on background threads are logged (and kept in %TEMP%) rather than lost.
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            OkiRomSim.Core.AppLog.Error("app", "unhandled exception" + (e.IsTerminating ? " (fatal)" : ""), e.ExceptionObject as Exception);
            try { File.AppendAllText(Path.Combine(Path.GetTempPath(), "RomSimTuner-errors.log"), $"{DateTime.Now:s} {e.ExceptionObject}\n\n"); } catch { }
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            OkiRomSim.Core.AppLog.Error("app", "background task failed", e.Exception);
            e.SetObserved();
        };
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        return 0;
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<TunerApp>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}

public sealed class TunerApp : Application
{
    public override void Initialize()
    {
        var fluent = new FluentTheme();
        AppTheme.Install(fluent);
        Styles.Add(fluent);
        try
        {
            Styles.Add(new Avalonia.Markup.Xaml.Styling.StyleInclude(new Uri("avares://RomSimTuner/"))
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
            var args = desktop.Args ?? [];
            var path = args.FirstOrDefault(a => !a.StartsWith('-'));
            // the title bar, the theme and the language before the first window is built (the tuner's own settings file; the first
            // time, Rom Sim Studio's - see AppSettings.Load)
            try { DarkChrome.PreferSystemTitleBar = AppSettings.Load().SystemTitleBar; } catch { }
            try { AppTheme.Set(AppTheme.Parse(AppSettings.Load().Theme)); } catch { }
            try { Lang.Use(AppSettings.Load().Language); } catch (Exception ex) { OkiRomSim.Core.AppLog.Error("lang", "not loaded", ex); }
            desktop.MainWindow = new TunerWindow(path);
        }
        base.OnFrameworkInitializationCompleted();
    }
}
