// Copyright (c) bmgjet. All rights reserved.
using System.Reflection;
using System.Runtime.Loader;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// A plugin: a .dll picked in Settings > Plugins with a public class that implements this. It is made once when the app starts (or when it is added), Start is called on the UI thread with everything it may use, and Stop when the app closes or the plugin is switched off. A plugin runs inside the app with the app's own rights: it can read and change the ROM, the definitions and the simulator, add menu entries, buttons, tabs, windows, pages and settings, and feed the datalog. To make one: a class library for the same .NET as the app that references OkiRomStudio's RomSimStudio.dll (with Private=false, so the app's own copy is used), and a class like public sealed class MyPlugin : IOkiPlugin { public string Name => "My plugin"; public string Description => "What it does."; public string Version => "1.0"; public void Start(PluginContext app) => app.AddMenuItem("Say hello", () => app.SetStatus("hello")); public void Stop() { } } The ScanTool plugin (src/Plugins/ScanTool) is a complete one to start from.
public interface IOkiPlugin
{
    string Name { get; }
    string Description { get; }
    string Version { get; }
    /// Called once, on the UI thread, when the plugin is loaded.
    void Start(PluginContext app);
    /// Called on the UI thread when the app closes or the plugin is switched off: stop threads, close ports.
    void Stop();
}

/// What a plugin is given: the whole app (the window, the simulator and ROM, the calibration editor, the datalog, the settings) and a few ways in that keep what it adds tidy - its own menu entries, buttons, tabs, pages, settings and a folder and settings of its own. Everything here is used on the UI thread; from another thread, go through Ui(). An emulator a plugin drives in place of the app's own (TakeOverEmulator): while it is in charge, the Emulator menu (connect, download, upload, validate, real-time update), the Datalogging menu's and the datalog page's Connect, and both status dots go to it. Called on the UI thread; long work belongs on the plugin's own threads.
public interface IEmulatorTakeover
{
    /// What it is ("ALPHAemu"), for the menus and the tooltips.
    string Name { get; }
    /// The link to the device is up.
    bool Connected { get; }
    /// Connecting or reconnecting right now.
    bool Connecting { get; }
    /// One line on how the link is, for the tooltips.
    string Status { get; }
    /// Connect (the emulator and the datalog that comes over it), or disconnect when connected.
    void ToggleConnect();
    /// Read the ROM out of the device and open it.
    void Download();
    /// Send the ROM open here to the device.
    void Upload();
    /// Check the device's ROM against the one here.
    void Validate();
    /// Changes go to the running image as they are made.
    bool RealtimeUpdate { get; }
    void ToggleRealtime();
}

public sealed class PluginContext
{
    readonly PluginManager _manager;
    internal PluginContext(PluginManager manager, string name) { _manager = manager; Name = name; }

    /// The plugin's name (as it gives it).
    public string Name { get; }
    /// The main window: the whole UI, for anything the helpers here do not cover.
    public Window Window => _manager.Window;
    /// The ROM, its definitions and the simulator: read and write anything (RomCopy, Defs, ReadItem, WriteCells, EditDefinitions, Sim...).
    public SimHost Sim => _manager.Sim;
    /// The calibration editor.
    public CalibrationView Calibration => _manager.Calibration;
    /// The datalog page.
    public DatalogView Datalog => _manager.Datalog;
    /// The datalog engine: its frames, and Inject to feed it frames of your own (BeginExternal / Inject / EndExternal).
    public DatalogEngine DatalogEngine => _manager.Datalog.Engine;
    /// The app's settings as they are now.
    public AppSettings Settings => _manager.Settings();

    /// A folder of the plugin's own for anything it keeps (under the app's settings folder).
    public string DataFolder
    {
        get
        {
            var dir = Path.Combine(AppSettings.Dir, "plugins", string.Concat(Name.Where(c => char.IsLetterOrDigit(c) || c is '-' or '_')));
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    /// A setting of the plugin's own, kept with the app's settings.
    public string? GetSetting(string key) =>
        Settings.PluginSettings.TryGetValue(Name, out var d) && d.TryGetValue(key, out var v) ? v : null;
    public void SetSetting(string key, string value)
    {
        var s = Settings;
        if (!s.PluginSettings.TryGetValue(Name, out var d)) s.PluginSettings[Name] = d = [];
        d[key] = value;
        s.Save();
    }

    /// An entry in the Plugins menu on the bar.
    public void AddMenuItem(string text, Action run, string tip = "", string icon = "🧩")
    {
        var entry = new Toolbar.Entry(icon, text, tip.Length > 0 ? tip : $"{Name}: {text}", Guard(run));
        _manager.MenuItems.Add(entry);
        _undo.Add(() => _manager.MenuItems.Remove(entry));
    }

    /// A button on the main bar (both modes): made by `make` once for each bar, since a control sits in one place only.
    public void AddToolbarButton(string icon, string text, string tip, Action run) =>
        _undo.Add(_manager.AddToolbarButton(() => Toolbar.Button(icon, text, tip, Guard(run))));

    /// A tab among the lower tabs of the simulator workbench.
    public void AddTab(string header, Control content, string tip = "") =>
        _undo.Add(_manager.AddTab(header, content, tip.Length > 0 ? tip : $"{Name}: {header}"));

    /// A window of the plugin's own, in the app's dark style, over the main window.
    public Window OpenWindow(string title, Control content, double width = 720, double height = 520)
    {
        var w = new Window { Title = title, Width = width, Height = height, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var chrome = DarkChrome.Apply(w, title);
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(content, 1); g.Children.Add(content);
        w.Content = g;
        w.Show(Window);
        return w;
    }

    /// A page in the calibration editor's list (under its own category).
    public void AddCalibrationPage(CalPage page)
    {
        CalPage.Extra.Add(page); Calibration.Refresh();
        _undo.Add(() => { CalPage.Extra.Remove(page); Calibration.Refresh(); });
    }

    /// Something added to the bottom of a feature page (by its key, "*" for every page): made each time the page is shown.
    public void AddPageSection(string pageKey, Func<CalPage, Control?> build)
    {
        FeaturePageView.Extensions.Add((pageKey, build));
        _undo.Add(() => FeaturePageView.Extensions.Remove((pageKey, build)));
    }

    /// A page of the Settings window.
    public void AddSettingsPage(string title, Func<Control> build)
    {
        _manager.SettingsPages.Add((title, build));
        _undo.Add(() => _manager.SettingsPages.Remove((title, build)));
    }

    /// Drive the emulator and its datalog from this plugin: the app's Emulator and Datalogging controls go to it (and the app's own emulator link is closed) until the plugin is switched off or calls ReleaseEmulator.
    public void TakeOverEmulator(IEmulatorTakeover takeover)
    {
        _manager.SetEmulator(takeover);
        _undo.Add(() => _manager.ClearEmulator(takeover));
    }

    /// Hand the Emulator and Datalogging controls back to the app.
    public void ReleaseEmulator(IEmulatorTakeover takeover) => _manager.ClearEmulator(takeover);

    /// Tell the app the takeover's state changed (connected, real-time...): the menus and the dots follow.
    public void EmulatorChanged() => Dispatcher.UIThread.Post(() => _manager.RaiseEmulatorChanged());

    /// A line on the status bar (and in the Debug page's log).
    public void SetStatus(string text) => _manager.SetStatus($"{Name}: {text}");

    /// A line in the Debug page's log.
    public void Log(string text) => AppLog.Info(Name, text);
    public void LogError(string text, Exception? ex = null) => AppLog.Error(Name, text, ex);

    /// Run on the UI thread (from a plugin's own thread).
    public void Ui(Action run) => Dispatcher.UIThread.Post(Guard(run));

    /// A ROM was opened or built: its path.
    public event Action<string>? RomLoaded;
    /// Every frame the datalog gets (on the datalog's thread).
    public event Action<LogFrame>? Frame
    {
        add { DatalogEngine.Frame += value; _undo.Add(() => DatalogEngine.Frame -= value); }
        remove => DatalogEngine.Frame -= value;
    }

    internal void RaiseRomLoaded(string path) { try { RomLoaded?.Invoke(path); } catch (Exception ex) { LogError("RomLoaded handler failed", ex); } }

    /// How to take back each thing the plugin added (its buttons, menu lines, tabs, pages, frame handlers).
    readonly List<Action> _undo = [];

    /// The plugin has been switched off: everything it put in the app comes out again.
    internal void TakeBack()
    {
        for (int i = _undo.Count - 1; i >= 0; i--)
            try { _undo[i](); } catch (Exception ex) { AppLog.Error("plugins", $"{Name}: could not take something back out", ex); }
        _undo.Clear();
        RomLoaded = null;
    }

    /// A plugin's mistake costs its action, not the app.
    Action Guard(Action run) => () =>
    {
        try { run(); }
        catch (Exception ex) { LogError("failed", ex); _manager.SetStatus($"{Name} failed: {ex.Message}"); }
    };
}

/// Loads the plugins picked in Settings > Plugins, each in a load context of its own (its own dependencies beside it; the app's assemblies shared), and keeps what they add.
public sealed class PluginManager
{
    internal readonly Window Window;
    internal readonly SimHost Sim;
    internal readonly CalibrationView Calibration;
    internal readonly DatalogView Datalog;
    internal readonly Func<AppSettings> Settings;
    internal readonly Action<string> SetStatus;
    readonly Func<string, Control, string, Action> _addTab;
    readonly List<Panel> _bars = [];
    readonly List<(Func<Button> Make, List<Button> Made)> _buttons = [];

    public readonly List<Toolbar.Entry> MenuItems = [];
    public readonly List<(string Title, Func<Control> Build)> SettingsPages = [];
    public readonly List<Loaded> Plugins = [];

    /// The plugin in charge of the emulator and its datalog, or null for the app's own.
    public IEmulatorTakeover? Emulator { get; private set; }
    /// It changed hands, or its state changed.
    public event Action? EmulatorChanged;

    internal void SetEmulator(IEmulatorTakeover t) { Emulator = t; RaiseEmulatorChanged(); AppLog.Action("plugins", $"{t.Name} drives the emulator and its datalog"); }
    internal void ClearEmulator(IEmulatorTakeover t) { if (ReferenceEquals(Emulator, t)) { Emulator = null; RaiseEmulatorChanged(); AppLog.Action("plugins", $"{t.Name} handed the emulator back"); } }
    internal void RaiseEmulatorChanged() { try { EmulatorChanged?.Invoke(); } catch (Exception ex) { AppLog.Error("plugins", "emulator change handler failed", ex); } }

    public sealed record Loaded(string Path, IOkiPlugin Plugin, PluginContext Context);

    internal PluginManager(Window window, SimHost sim, CalibrationView cal, DatalogView log, Func<AppSettings> settings,
                           Action<string> status, Func<string, Control, string, Action> addTab)
    {
        Window = window; Sim = sim; Calibration = cal; Datalog = log; Settings = settings; SetStatus = status; _addTab = addTab;
    }

    /// A bar that plugin buttons go on (the simulator's and Tuner mode's).
    internal void AddBar(Panel bar)
    {
        _bars.Add(bar);
        foreach (var (make, made) in _buttons) { var b = make(); made.Add(b); bar.Children.Add(b); }
    }

    /// A plugin button on every bar; what is returned takes them all off again.
    internal Action AddToolbarButton(Func<Button> make)
    {
        var entry = (Make: make, Made: new List<Button>());
        _buttons.Add(entry);
        foreach (var bar in _bars) { var b = make(); entry.Made.Add(b); bar.Children.Add(b); }
        return () =>
        {
            _buttons.Remove(entry);
            foreach (var b in entry.Made) (b.Parent as Panel)?.Children.Remove(b);
        };
    }

    internal Action AddTab(string header, Control content, string tip) => _addTab(header, content, tip);

    /// Load every plugin that is switched on in Settings.
    public void LoadAll()
    {
        foreach (var p in Settings().Plugins.Where(p => p.Enabled)) Load(p.Path);
    }

    /// Load one plugin .dll and start what is in it; the reason when it cannot be.
    public string? Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return $"{System.IO.Path.GetFileName(path)} is not there any more";
            if (Plugins.Any(p => string.Equals(p.Path, path, StringComparison.OrdinalIgnoreCase))) return null;
            var found = Create(path, out var error);
            if (found.Count == 0) return error ?? $"{System.IO.Path.GetFileName(path)} has no plugin in it (a public class that implements IOkiPlugin)";
            foreach (var plugin in found)
            {
                var ctx = new PluginContext(this, plugin.Name);
                // a Start that fails half way has already added some of its buttons and pages: they come out again, or nothing could ever remove them
                try { plugin.Start(ctx); }
                catch { ctx.TakeBack(); throw; }
                Plugins.Add(new Loaded(path, plugin, ctx));
                AppLog.Action("plugins", $"started {plugin.Name} {plugin.Version} from {path}");
            }
            return null;
        }
        catch (Exception ex)
        {
            AppLog.Error("plugins", "could not load " + path, ex);
            return $"{System.IO.Path.GetFileName(path)}: {(ex is TargetInvocationException { InnerException: { } inner } ? inner.Message : ex.Message)}";
        }
    }

    /// Switch a plugin off without restarting the app: stopped, and its buttons, menu lines, tabs and pages taken out.
    public void Unload(string path)
    {
        foreach (var p in Plugins.Where(p => string.Equals(p.Path, path, StringComparison.OrdinalIgnoreCase)).ToList())
        {
            try { p.Plugin.Stop(); } catch (Exception ex) { AppLog.Error("plugins", p.Plugin.Name + " did not stop cleanly", ex); }
            p.Context.TakeBack();
            Plugins.Remove(p);
            AppLog.Action("plugins", $"stopped {p.Plugin.Name} ({path})");
        }
    }

    /// Stop every plugin (the app is closing).
    public void StopAll()
    {
        foreach (var p in Plugins)
            try { p.Plugin.Stop(); } catch (Exception ex) { AppLog.Error("plugins", p.Plugin.Name + " did not stop cleanly", ex); }
        Plugins.Clear();
    }

    public void RaiseRomLoaded(string path) { foreach (var p in Plugins) p.Context.RaiseRomLoaded(path); }

    /// What a plugin .dll holds (name, version, description), without starting it: for the Settings page.
    public static List<(string Name, string Version, string Description)> Inspect(string path, out string? error)
    {
        error = null;
        var ctx = new PluginLoadContext(path, collectible: true);
        try
        {
            var asm = ctx.LoadFromAssemblyPath(System.IO.Path.GetFullPath(path));
            return [.. PluginTypes(asm).Select(t => Activator.CreateInstance(t) as IOkiPlugin).OfType<IOkiPlugin>().Select(p => (p.Name, p.Version, p.Description))];
        }
        catch (Exception ex) { error = ex.Message; return []; }
        finally { ctx.Unload(); }
    }

    static List<IOkiPlugin> Create(string path, out string? error)
    {
        error = null;
        var asm = new PluginLoadContext(path, collectible: false).LoadFromAssemblyPath(System.IO.Path.GetFullPath(path));
        var list = new List<IOkiPlugin>();
        foreach (var t in PluginTypes(asm))
            if (Activator.CreateInstance(t) is IOkiPlugin p) list.Add(p);
        return list;
    }

    static IEnumerable<Type> PluginTypes(Assembly asm)
    {
        Type[] types;
        try { types = asm.GetTypes(); } catch (ReflectionTypeLoadException ex) { types = [.. ex.Types.OfType<Type>()]; }
        return types.Where(t => t is { IsClass: true, IsAbstract: false, IsPublic: true } && typeof(IOkiPlugin).IsAssignableFrom(t) && t.GetConstructor(Type.EmptyTypes) != null);
    }

    /// A plugin's own dependencies come from beside it; anything the app has already loaded (the app itself, Avalonia, the assembler...) is the app's copy, so the types a plugin is handed are the ones it expects.
    sealed class PluginLoadContext(string path, bool collectible) : AssemblyLoadContext(System.IO.Path.GetFileNameWithoutExtension(path), collectible)
    {
        readonly AssemblyDependencyResolver _resolver = new(System.IO.Path.GetFullPath(path));

        protected override Assembly? Load(AssemblyName name)
        {
            if (Default.Assemblies.Any(a => AssemblyName.ReferenceMatchesDefinition(a.GetName(), name) || a.GetName().Name == name.Name)) return null;
            return _resolver.ResolveAssemblyToPath(name) is { } p ? LoadFromAssemblyPath(p) : null;
        }

        protected override IntPtr LoadUnmanagedDll(string unmanagedDllName) =>
            _resolver.ResolveUnmanagedDllToPath(unmanagedDllName) is { } p ? LoadUnmanagedDllFromPath(p) : IntPtr.Zero;
    }
}

/// One plugin in Settings > Plugins.
public sealed class PluginSetting
{
    public string Path { get; set; } = "";
    public bool Enabled { get; set; } = true;
}
