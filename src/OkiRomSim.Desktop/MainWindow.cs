// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// The whole window is built in C# rather than XAML: fewer moving parts, and everything the UI does is visible in one place. Left: chip pinout and engine inputs. Centre: the source and the Problems/Trace/Memory/Calibration/Lookup/Breakpoints/Datalog/Hit trace/Debug tabs. Right: CPU, call stack, disassembly, outputs and ports. Tuner mode swaps all of that for the calibration editor with datalogging beside it.
public sealed class MainWindow : Window
{
    readonly SimHost _host = new();
    string? _target;                               // .asm that Build assembles

    // centre
    readonly TextBlock _docHeader = new() { FontSize = 12, Margin = new Thickness(8, 4), Opacity = 0.85, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly CodeEditor _editor = new();
    readonly DataList _problems = new(new("", 26), new("Severity", 80), new("Where", 240), new("Message", 300))
    {
        Empty = "Build (Ctrl+B) to check the source: errors and warnings appear here. Click one to go to its line.",
    };
    readonly TextBox _trace = Readonly();
    readonly TextBox _memory = Readonly();
    readonly TextBox _memAddr = Mono(new TextBox { Text = "0080", Width = 80 });
    readonly DataList _bpList = new(new("", 26), new("Address", 70), new("Label", 220), new("Source", 260))
    {
        Empty = "No breakpoints. Type a label or an address above and press Break, double-click a disassembly line, or F9 on a source line.",
    };
    readonly TextBox _lookupQ = new() { Watermark = "label, setting or address (3DDE, 0d9h, fuelpump)", Width = 300 };
    readonly ListBox _lookupList = new();
    readonly DataList _traceList = new(new("PC", 70), new("Routine", 230), new("Instruction", 300))
    {
        Empty = "Run or step the simulator: the instructions it executes appear here, the newest at the bottom.",
    };
    readonly DataList _lookupData = new(new("Address", 80), new("Name", 280), new("Kind", 110), new("Instruction", 240), new("Source", 160))
    {
        Empty = "Type a label, a setting or an address above: Look up finds it, Find references lists every instruction that uses it.",
    };
    readonly TabControl _bottom = new();
    readonly CalibrationView _calibration;
    readonly HitTraceView _hitView;
    readonly DatalogView _datalog;
    readonly DebugView _debug;
    readonly Dictionary<string, ZoomHost> _zoom = [];
    ProcessorProfile _profile = ProcessorProfile.Current;
    readonly Control? _simRoot, _tunerRoot;
    bool _tuner;
    ZoomHost? _zCalibration, _zDatalog, _zTunerDatalog, _zInputs;
    StackPanel? _leftStack;
    readonly Border _miniInputs = new() { Padding = new Thickness(8, 6), IsVisible = false };
    readonly TextBlock _chipTitle = Header("MSM66207");

    // left
    readonly ChipView _chip;
    readonly ComboBox _package = new() { Width = 170 };
    readonly StackPanel _inputs = new();

    // right
    readonly CpuView _cpu = new();
    readonly DataList _callList = new(new("", 44), new("Entry", 52), new("Routine", 210), new("Returns to", 90))
    {
        RowHeight = 18, Empty = "top level: no routine entered",
    };
    const int CallStackLines = 7;
    readonly DataList _disList = new(new("", 20), new("Addr", 52), new("Bytes", 86), new("Label", 150), new("Instruction", 250)) { RowHeight = 18 };
    readonly TextBox _disAddr = Mono(new TextBox { Watermark = "addr/label", Width = 110, FontSize = 11.5, MinHeight = 24, Padding = new Thickness(6, 2) });
    readonly DataList _outList = new(new("Output", 150), new("Pin", 96), new("State", 84), new("Detail", 230)) { RowHeight = 18 };
    readonly DataList _portList = new(new("Pin", 52), new("Level", 46), new("Dir", 40), new("Changes/s", 80), new("High ms", 66), new("Low ms", 66), new("Function", 170), new("Driven by", 230)) { RowHeight = 18 };

    // toolbar / status
    readonly TextBlock _status = new() { Text = "ready", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
    string _sticky = "";
    readonly bool _ready;
    readonly Button _run, _pause, _step, _over, _into, _out, _reset, _buildBtn;
    AppSettings _settings = AppSettings.Load();
    readonly LayoutTransformControl _scaler = new();
    OkiRomSim.Mcp.McpHttp? _mcpHttp;
    string _mcpState = "off";
    /// Where an MCP client on another machine can always put a file, and read one back.
    public static string McpTransferDir => Path.Combine(AppSettings.Dir, "transfer");

    readonly Dictionary<string, string> _buffers = [];        // open file -> text as on screen
    readonly HashSet<string> _dirty = [];                     // differs from the file on disk
    string? _current;
    List<Diagnostic> _diags = [];
    List<(string file, int line)> _problemLoc = [];
    List<int> _disasmAddrs = [];
    List<(string Name, int Address, int Offset, string Kind)> _lookupRows = [];
    List<string> _lookupLines = [];

    // build state: what the loaded image was built from, to decide whether Build is needed
    Dictionary<string, string> _builtTexts = [];
    byte[]? _builtImage;
    readonly DispatcherTimer _checkTimer = new() { Interval = TimeSpan.FromMilliseconds(600) };
    int _checkGeneration;

    static TextBox Mono(TextBox b) { b.FontFamily = MonoFont; return b; }
    static TextBlock Mono(TextBlock b) { b.FontFamily = MonoFont; return b; }
    static TextBlock Small(string t) => new() { Text = t, FontSize = 11, Opacity = 0.75, TextWrapping = TextWrapping.Wrap };
    static TextBox Readonly() => Mono(new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, FontSize = 12 });
    public static readonly FontFamily MonoFont = new("Cascadia Mono,Consolas,DejaVu Sans Mono,Menlo,monospace");
    static string Hex(long v, int n = 4) => v.ToString("X" + n);
    static T Tip<T>(T c, string tip) where T : Control { ToolTip.SetTip(c, tip); return c; }

    public MainWindow(string? openPath)
    {
        Title = $"OkiRomSim Studio {BuildInfo.Version}";
        AppLog.Info("app", $"{BuildInfo.Product} {BuildInfo.Version} starting on {Environment.OSVersion} ({Environment.ProcessorCount} cores, .NET {Environment.Version})");
        MinWidth = 900; MinHeight = 600;
        // the UI scale and panel layout picked for this screen, the first time the app starts on it
        try
        {
            var scr = (_settings.WindowX is double sx && _settings.WindowY is double sy ? Screens.ScreenFromPoint(new PixelPoint((int)sx, (int)sy)) : null) ?? Screens.Primary;
            if (ScreenFit.Fit(_settings, scr)) _settings.Save();
            if (scr != null) { MinWidth = Math.Min(MinWidth, ScreenFit.Dip(scr).Width * 0.9); MinHeight = Math.Min(MinHeight, ScreenFit.Dip(scr).Height * 0.9); }
        }
        catch (Exception ex) { AppLog.Error("app", "could not fit the window to the screen", ex); }
        Width = Math.Max(MinWidth, _settings.WindowWidth); Height = Math.Max(MinHeight, _settings.WindowHeight);
        if (_settings.WindowX is double wx && _settings.WindowY is double wy)
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Position = new PixelPoint((int)wx, (int)wy);
        }
        WindowState = _settings.Maximized ? WindowState.Maximized : WindowState.Normal;

        // the processor profile first: it sets the clock and the names everything else uses
        try { _profile = ProcessorProfile.Builtin(_settings.Processor) ?? ProcessorProfile.Msm66207(); _profile.Apply(); }
        catch (Exception ex) { AppLog.Error("processor", "profile failed; using the MSM66207", ex); ProcessorProfile.Msm66207().Apply(); }
        _chip = new ChipView(_host);
        _chip.Message += m => SetStatus(m);
        _calibration = new CalibrationView(_host, () => _buffers.Select(kv => (kv.Key, kv.Value)), () => GetTopLevel(this));
        _calibration.GoToAddress += GoToAddress;
        // favourites belong to a ROM: kept by its file name (a built ROM and its .bin share it)
        string FavKey() => Path.GetFileNameWithoutExtension(_host.LoadedPath ?? "").ToLowerInvariant();
        _calibration.OpenSettingsPage += page => OpenSettings(page);
        _host.ItemWritten += item => Dispatcher.UIThread.Post(() => KeepInBuildFile(item));
        _calibration.GetFavourites = () => _settings.Favourites.TryGetValue(FavKey(), out var l) ? l : [];
        _calibration.SaveFavourites = list => { _settings.Favourites[FavKey()] = list; _settings.Save(); };
        _calibration.StretchChanged += on => { _settings.TableStretch = on; _settings.Save(); };
        _hitView = new HitTraceView(_host, _traceList, f => ReadBuffer(Path.GetFullPath(f)) ?? (File.Exists(f) ? File.ReadAllText(f) : null));
        _hitView.GoToAddress += GoToAddress;
        _datalog = new DatalogView(_host, () => GetTopLevel(this), () => _settings);
        _datalog.GoToAddress += GoToAddress;
        _debug = new DebugView(() => GetTopLevel(this));
        _calibration.ExpandRequested += ToggleExpand;
        _calibration.CompareRequested += OpenCompare;
        _calibration.OverlayFrames = () => _datalog.Frames();
        _calibration.DatalogMenu = (live, setLive) => _datalog.MenuEntries(live, setLive);
        _calibration.DatalogState = _datalog.LinkStatus;
        _datalog.CurrentFrameChanged += f => { if (_tuner || _datalog.Engine.Running && _datalog.Engine.Source != "simulator") _calibration.SetEngineState(f); };
        // an .rlog carries the ROM the car was running: offer to open it
        _datalog.RomFromLog += async (rom, name) =>
        {
            // an .rlog carries the tune the car was running: never quietly replace what is open
            bool load = await Dialogs.Confirm(this, "Load the tune from the log?",
                $"{name} carries the ROM the car was running ({rom.Length:N0} bytes).\n\n" +
                (_current == null ? "Open it now?" : $"Open it in place of {Label(_current)}? The log itself is loaded either way."),
                "Open it", "Keep what I have");
            if (!load) { SetStatus("the log's frames are loaded; the ROM it carries was left alone", sticky: true); return; }
            if (await ConfirmReplaceCurrent(name + ".bin")) OpenRomImage(rom, name);
        };
        _datalog.DetectedLayoutChanged += p =>
        {
            _settings.DatalogProtocol = _datalog.Protocol;
            _settings.DetectedLayout = p == null ? null : System.Text.Json.JsonSerializer.Serialize(p);
            _settings.Save();
        };
        Closing += (_, _) =>
        {
            SaveLayout();
            _datalog.Gauges.SaveLast();
            _external.Dispose();
            _datalog.Gauges.CloseWidgets();
            _hitView.Shutdown(); _datalog.Shutdown(); StopMcp(); _host.EmulatorDisconnect();
            _plugins?.StopAll();
        };
        // every button pressed goes to the Debug page's action log
        Button.ClickEvent.AddClassHandler<Button>((b, _) =>
        {
            string text = b.Content switch { string t => t, TextBlock tb => tb.Text ?? "", _ => b.Content?.ToString() ?? "" };
            if (text.Length > 0) AppLog.Action("ui", $"pressed '{text}'");
        });

        _buildBtn = ToolButton("Build (Ctrl+B)", () => Build(),
            "Assemble the source on screen and load it into the simulator. Enabled only when the source would produce different bytes from what is loaded.");
        _run = ToolButton("▶ Run (F5)", () => Control("run"), "Run the simulator from the current instruction (F5 toggles run/pause).");
        _pause = ToolButton("❚❚ Pause", () => Control("pause"), "Stop the simulator where it is.");
        _step = ToolButton("Step (F11)", () => Control("step"), "Execute exactly one instruction; follows calls and interrupts into their code.");
        _over = ToolButton("Over (F10)", () => Control("stepover"),
            "Step over what is under the PC: a call (CAL/VCAL) runs to completion; a jump is skipped and a conditional branch is not taken, so you carry on at the next instruction.");
        _into = ToolButton("Into (Ctrl+F11)", () => Control("stepinto"),
            "Follow the jump under the PC even when its condition says otherwise: a conditional branch is forced taken, so you can walk the path the flags are not taking.");
        _out = ToolButton("Out (Shift+F11)", () => Control("stepout"), "Run until the current routine or interrupt handler returns to its caller.");
        _reset = ToolButton("↻ Reset", () => Control("reset"), "Reset the CPU to the reset vector; the loaded image, breakpoints and inputs are kept.");

        var chrome = DarkChrome.Apply(this, Title!);
        var shell = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(chrome, 0); shell.Children.Add(chrome);
        _simRoot = BuildLayout();
        _tunerRoot = BuildTunerLayout();
        _scaler.Child = _simRoot;
        Grid.SetRow(_scaler, 1); shell.Children.Add(_scaler);
        Content = shell;
        KeyDown += OnKeyDown;
        // the pinout never takes more than about half the window height, whatever the screen
        SizeChanged += (_, e) => _chip.MaxHeight = Math.Max(240, e.NewSize.Height * 0.46);
        _editor.TextChanged += (_, _) => OnEditorChanged();
        _editor.WordDoubleClicked += OnWordDoubleClicked;
        _checkTimer.Tick += (_, _) => { _checkTimer.Stop(); CheckBuildNeeded(); };

        // the shipped ROM sources: the formulas of tables Detect places from them
        DefinitionBuilder.FormulaSources.Add(Path.Combine(AppContext.BaseDirectory, "Templates"));
        ApplySettings(first: true);
        // the program files an update moved aside are not in use any more
        Updater.ClearOld();
        if (_settings.CheckUpdatesAtStart && !UiCheck.Active) CheckUpdatesQuietly();
        // plugins: made once the window is built, so what they add has somewhere to go
        _plugins = new PluginManager(this, _host, _calibration, _datalog, () => _settings, m => SetStatus(m),
            (header, content, tip) =>
            {
                var tab = Tab(header, content, tip);
                _bottom.Items.Add(tab);
                return () => _bottom.Items.Remove(tab);
            });
        _calibration.OpenDownloaded += OpenDownloaded;
        _calibration.EmulatorClosed += DemonClosed;
        _calibration.DatalogPortInUse = () => _datalog.Engine.Running && _datalog.Engine.Source is { } src && !src.StartsWith("emulator") && src != "simulator" ? src : null;
        _plugins.AddBar(_pluginBarSim);
        _plugins.AddBar(_pluginBarTuner);
        foreach (var p in _settings.Plugins.Where(p => p.Enabled))
            if (_plugins.Load(p.Path) is { } why) SetStatus("plugin not loaded: " + why);
        UpdatePluginsMenu();
        try
        {
            if (openPath == null && _settings.ReopenLastFile && _settings.LastFile is { } last && File.Exists(last)) openPath = last;
            if (openPath != null && File.Exists(openPath)) OpenFile(Path.GetFullPath(openPath));
            else UpdateDocHeader();
        }
        catch (Exception ex) { SetStatus("could not open " + openPath + ": " + ex.Message); }

        // A bug in a handler should cost one action, not the session: log it and carry on.
        Dispatcher.UIThread.UnhandledException += (_, e) =>
        {
            e.Handled = true;
            AppLog.Error("ui", "unhandled error in a handler", e.Exception);
            try { File.AppendAllText(Path.Combine(Path.GetTempPath(), "OkiRomSimStudio-errors.log"), $"{DateTime.Now:s} {e.Exception}\n\n"); } catch { }
            SetStatus("internal error (see the Debug page): " + e.Exception.Message);
        };
        // the view it opens in: the welcome screen's answer (Settings > General), or whichever was used last
        bool startTuner = _settings.StartIn switch { "simulator" => false, "tuner" => true, _ => _settings.TunerMode };
        if (startTuner) SetTunerMode(true);
        if (!_settings.FirstRunDone && !UiCheck.Active) Opened += (_, _) => Dispatcher.UIThread.Post(Welcome, DispatcherPriority.Background);

        _ready = true;
        if (_target == null) UpdateBuildButton(false, "Nothing to build yet: open a .asm or .bin.");
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        timer.Tick += (_, _) =>
        {
            // nothing to show while minimized; and with the simulator stopped and nothing logging or replaying, the screen only changes when you do something, so it is looked at less often
            if (WindowState == WindowState.Minimized) return;
            SafeRefresh();
            DemonDatalog();
            bool busy = _host.IsRunning || _host.PlaybackActive || _datalog.Engine.Running;
            var want = TimeSpan.FromMilliseconds(busy ? Perf.BusyMs : Perf.IdleMs);
            if (timer.Interval != want) timer.Interval = want;
        };
        timer.Start();
    }

    /// The first start: what the app is for, which sets the view it opens in.
    async void Welcome()
    {
        if (_settings.FirstRunDone) return;
        try
        {
            var w = new WelcomeWindow();
            await Dialogs.ShowModal(w, this);
            _settings.FirstRunDone = true;
            if (w.Choice is { } c)
            {
                _settings.StartIn = c;
                SetTunerMode(c == "tuner");
                SetStatus(c == "tuner"
                    ? "Tuner: open a .bin (File > Open), Detect its maps, then connect the datalog and the emulator"
                    : "Simulator: open a .asm or .bin (File > Open), or File > New ROM to start from the skeleton");
            }
            _settings.Save();
            AppLog.Action("app", $"welcome: {w.Choice ?? "decide later"}");
        }
        catch (Exception ex) { AppLog.Error("app", "welcome screen failed", ex); }
    }

    /// The File drop-down: the things done once in a while, out of the way of the everyday buttons.
    Button FileMenu() => Toolbar.Menu("File", Toolbar.Open, () => [
        new Toolbar.Entry(Toolbar.Project, "New ROM…",
            "Start a new ROM: copy a template from the Templates folder (HTS120 and friends) to a file of your own and open it.", NewRom),
        new Toolbar.Entry(Toolbar.Open, "Open…  (Ctrl+O)", "Open a .asm source, a .bin/.rom image (disassembled to source) or a saved project .zip.", OpenFileDialog),
        Toolbar.Entry.Submenu(Toolbar.Restore, "Recent", "The last ten files opened.", RecentEntries),
        new Toolbar.Entry(Toolbar.Save, "Save  (Ctrl+S)", "Write the source on screen to its file.", SaveCurrent),
        new Toolbar.Entry(Toolbar.SaveAs, "Save as…", "Write the source on screen to a new file - or, picking .bin, the ROM image assembled from it.", SaveAs),
        Toolbar.Entry.Line,
        new Toolbar.Entry(Toolbar.Project, "Save project…  (Ctrl+Shift+S)",
            "Save everything exactly as it is to a .zip: all source buffers (saved or not), the editor position, the full simulator state (registers, RAM, patched ROM, inputs, breakpoints), calibration definitions, and the Trace, Memory, Lookup and Breakpoint views. Open the .zip to carry on.", SaveProject),
        new Toolbar.Entry(Toolbar.Restore, "Restore last auto save",
            "Open the newest automatic restore point (Settings > General sets how often one is written).", RestoreLastAutoSave),
        Toolbar.Entry.Line,
        new Toolbar.Entry(Toolbar.Clear, "Clear project",
            "Close the ROM and let go of everything - sources, definitions, machine state, hits, datalog frames and caches - leaving the app idle and using as little memory as possible (handy before handing it to an MCP client).", ClearProject),
        new Toolbar.Entry(Toolbar.SaveAs, "Bin tool…",
            "32 KB ROMs and 64 KB (512) chips: pad a ROM into the upper half of a 64 KB image, combine two ROMs on one chip, or split a 64 KB image into its two 32 KB halves.",
            OpenBinTool),
        new Toolbar.Entry(Toolbar.Compare, "Compare…",
            "Compare the ROM open here with another .bin or .asm: what changed in the code (routines added, removed, changed) and in the tables.", OpenCompare),
        Toolbar.Entry.Line,
        _tuner
            ? new Toolbar.Entry(Toolbar.Tuner, "Simulator mode", "Back to the full workbench: source, simulator, disassembly and every tab.", () => SetTunerMode(false))
            : new Toolbar.Entry(Toolbar.Tuner, "Tuner mode", "The calibration editor as the main page with datalogging beside it.", () => SetTunerMode(true)),
        new Toolbar.Entry(Toolbar.Settings, "Settings…",
            "UI scale, panel zoom, colours, hot keys, simulation speed, datalogging, the emulator, the processor profile, plugins and the MCP server for other programs.", OpenSettings),
    ]);

    void OpenBinTool()
    {
        var w = new BinToolWindow(() => _host.LoadedPath == null ? null : _host.RomCopy(), Path.GetFileName(_host.LoadedPath ?? ""));
        _ = Dialogs.ShowModal(w, this);
    }

    Button ToolButton(string text, Action onClick, string tip)
    {
        var b = new Button { Content = text, Margin = new Thickness(2, 0) };
        b.Click += (_, _) => onClick();
        ToolTip.SetTip(b, tip);
        return b;
    }

    // ------------------------------------------------------------------ layout

    Control BuildLayout()
    {
        var toolbar = new WrapPanel { Margin = new Thickness(6, 4) };
        toolbar.Children.Add(FileMenu());
        toolbar.Children.Add(_pluginsMenuSim);
        toolbar.Children.Add(new Separator { Width = 8 });
        toolbar.Children.Add(_buildBtn.WithIcon(Toolbar.Build));
        toolbar.Children.Add(ToolButton("⚡ Patch live (Ctrl+Shift+B)", () => PatchLive(false),
            "Assemble the source on screen and put only the bytes that changed into the ROM that is running - no reset: the program carries on, " +
            "RAM and all, with the new code and tables at once. With the emulator uploading changes, the car gets them too."));
        toolbar.Children.Add(new Separator { Width = 8 });
        toolbar.Children.Add(_run); toolbar.Children.Add(_pause); toolbar.Children.Add(_step);
        toolbar.Children.Add(_over); toolbar.Children.Add(_into); toolbar.Children.Add(_out); toolbar.Children.Add(_reset);
        toolbar.Children.Add(_pluginBarSim);

        // ---- left: chip + engine inputs
        _package.ItemsSource = new[] { "64-pin shrink DIP (SDIP)", "64-pin QFP (SMD)" };
        _package.SelectedIndex = 0;
        _package.SelectionChanged += (_, _) => _chip.CurrentPackage = _package.SelectedIndex == 1 ? ChipView.Package.Qfp64 : ChipView.Package.Sdip64;
        Tip(_package, "Package drawing: through-hole shrink DIP or the surface-mount QFP. Pin numbers follow the MSM66207 datasheet.");
        var legend = Small("green = output (bright high), blue = input (bright high), purple = on-chip peripheral, orange = analog (brighter = higher voltage), red outline = set by hand. Hover a pin for its reading; click an input to change it.");
        var left = _leftStack = new StackPanel { Margin = new Thickness(12, 6, 6, 6) };
        var chipHead = new StackPanel { Orientation = Orientation.Horizontal };
        _chipTitle.Text = _profile.Name.ToUpperInvariant();
        chipHead.Children.Add(_chipTitle);
        chipHead.Children.Add(_package);
        var chipBox = new StackPanel();
        chipBox.Children.Add(chipHead);
        chipBox.Children.Add(legend);
        chipBox.Children.Add(_chip);
        left.Children.Add(Zoomable("Pinout", chipBox));
        var inHead = new DockPanel { LastChildFill = false };
        inHead.Children.Add(Header("Engine inputs"));
        var reset = ToolButton("Reset defaults", ResetInputs, "Put every engine input back to its default: 800 rpm idle, 33 kPa, closed throttle, 85 °C coolant, 25 °C air, 0.45 V O2, 14.2 V, standing still, starter off, oil pressure on.");
        reset.FontSize = 11; reset.Padding = new Thickness(6, 1); reset.Margin = new Thickness(0, 6, 0, 0);
        DockPanel.SetDock(reset, Dock.Right);
        inHead.Children.Add(reset);
        var mil = ToolButton("Check engine…", OpenMil, "The check-engine lamp: what it is flashing, the codes the ECU has stored and the faults it sees now.");
        mil.FontSize = 11; mil.Padding = new Thickness(6, 1); mil.Margin = new Thickness(0, 6, 6, 0);
        DockPanel.SetDock(mil, Dock.Right);
        inHead.Children.Add(mil);
        BuildInputs();
        var inputsBox = new StackPanel();
        inputsBox.Children.Add(inHead);
        inputsBox.Children.Add(_inputs);
        _zInputs = Zoomable("Inputs", inputsBox);
        left.Children.Add(_zInputs);

        // ---- centre
        _problems.Picked += r => { if (r.Tag is ValueTuple<string, int> at) ShowSourceLine(at.Item1, at.Item2); };
        Tip(_problems, "Build errors and warnings. Click one to jump to its line (it is highlighted in the editor).");
        Tip(_trace, "The last instructions executed, oldest first.");
        Tip(_editor, "The source being simulated. Ctrl+B builds, F9 toggles a breakpoint on the caret line.");
        // no padding round the pages: the theme's left a strip down the left of every page, the calibration list pushed in from its edge
        _bottom.Padding = new Thickness(0);
        _bottom.Items.Add(Tab("Problems", Zoomable("Problems", ProblemsPanel()), "Build errors and warnings"));
        _traceList.Activated += r => { if (r.Address >= 0) GoToAddress(r.Address); };
        ToolTip.SetTip(_traceList, "The last instructions executed, oldest first. Double-click one to go to it in the source.");
        _bottom.Items.Add(Tab("Trace", Zoomable("Trace", _hitView),
            "Recently executed instructions; tick Hit trace for the ROM bytes fetched as well (simulator, or a real ECU through a Moates Ostrich 2.0 / Demon)"));
        _bottom.Items.Add(Tab("Memory", Zoomable("Memory", MemoryPanel()), "RAM / ROM hex view"));
        _zCalibration = Zoomable("Calibration", _calibration);
        _bottom.Items.Add(Tab("Calibration", _zCalibration, "Settings and tables: define, detect, edit, export, emulator"));
        _bottom.Items.Add(Tab("Lookup & breakpoints", Zoomable("Lookup", LookupPanel()),
            "Find labels, settings and every instruction that references an address, and set breakpoints on them"));
        _zDatalog = Zoomable("Datalog", _datalog);
        _bottom.Items.Add(Tab("Datalog", _zDatalog, "Log a car (any of the OBD1 protocols) or the simulated ROM, load a datalog, and drive the simulator with it"));
        _bottom.Items.Add(Tab("Debug", Zoomable("Debug", _debug), "Everything that happened: actions, errors, MCP calls (and where they came from), serial traffic"));
        // SelectionChanged bubbles: lists inside the tabs raise it too, so react only to the tab strip itself
        _bottom.SelectionChanged += (_, e) => { if (ReferenceEquals(e.Source, _bottom) && SelectedTab() == "Calibration") _calibration.Refresh(); };

        var centre = _centre = new Grid { RowDefinitions = new RowDefinitions("Auto,*,4,1.5*") };
        Grid.SetRow(_docHeader, 0); centre.Children.Add(_docHeader);
        var zEditor = new ZoomHost("Source", _editor, z => _editor.SetFontSize(_settings.EditorFontSize * z));
        zEditor.ZoomChanged += RememberZoom;
        _zoom["Source"] = zEditor;
        Grid.SetRow(zEditor, 1); centre.Children.Add(zEditor);
        var hs = new GridSplitter { Height = 4, ResizeDirection = GridResizeDirection.Rows }; Grid.SetRow(hs, 2); centre.Children.Add(hs);
        Grid.SetRow(_bottom, 3); centre.Children.Add(_bottom);

        // ---- right
        _disAddr.KeyDown += (_, e) => { if (e.Key == Key.Enter) RefreshDisassembly(true); };
        Tip(_disAddr, "Address or label to disassemble from; empty follows the PC.");
        _disList.Activated += r =>
        {
            if (r.Address < 0) return;
            _host.ToggleBreakpoint(Hex(r.Address));
            RefreshDisassembly(true);
        };
        _disList.Picked += r => { if (r.Address >= 0 && _host.Assembly?.Lookup(r.Address) is { } src) ShowSourceLine(src.File, src.Line, select: false); };
        _callList.Activated += r => { if (r.Address >= 0) GoToAddress(r.Address); };
        Tip(_disList, "Instructions around the PC (highlighted) with breakpoints (●). Click a line to show it in the source; double-click to toggle a breakpoint.");
        Tip(_cpu, "The PC and the routine it is in, the registers (orange: changed by the last step), the PSW flags (lit when set), the interrupt request (IRQ) and enable (IE) masks.");
        Tip(_callList, "Call stack, innermost first: routines entered with CAL/VCAL and interrupt handlers, with where each returns to. Double-click one to go to it.");
        Tip(_outList, "What the ROM is driving: fuel pump, VTEC, injectors (pulse, rate, duty), ignition timer events, watchdog, mux, PWM.");
        Tip(_portList, "Every port pin: level, direction (in/out/sf = on-chip peripheral), changes per second, last high/low time, board function, and the routine that last wrote it.");
        var right = new StackPanel { Margin = new Thickness(8, 8, 8, 0) };
        right.Children.Add(Panels.Card("CPU", _cpu));
        // fixed height, so the panels below do not jump as calls come and go
        _callList.Height = (CallStackLines * 18) + 26;
        right.Children.Add(Panels.Card("Call stack", _callList));
        _disList.Height = 300;
        var go = Panels.Button("Go", () => RefreshDisassembly(true), "Disassemble from the address or label typed (empty follows the PC).");
        go.Padding = new Thickness(8, 1);
        right.Children.Add(Panels.Card("Disassembly", _disList, _disAddr, go));
        right.Children.Add(Panels.Card("Outputs", _outList));
        right.Children.Add(Panels.Card("Ports", _portList));

        var main = _mainGrid = new Grid { ColumnDefinitions = new ColumnDefinitions("3*,4,4*,4,3*") };
        var leftScroll = _leftPane = new ScrollViewer { Content = left };
        // the tables in it scroll sideways on their own: the panel itself keeps to its width
        var rightScroll = _rightPane = new ScrollViewer { Content = Zoomable("Right", right), HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        Grid.SetColumn(leftScroll, 0); main.Children.Add(leftScroll);
        // expanded view: a narrow strip keeps the engine inputs at hand
        var miniScroll = new ScrollViewer { Content = _miniInputs };
        _miniInputs.Tag = miniScroll;
        miniScroll.IsVisible = false;
        Grid.SetColumn(miniScroll, 0); main.Children.Add(miniScroll);
        var s1 = _split1 = new GridSplitter { Width = 4 }; Grid.SetColumn(s1, 1); main.Children.Add(s1);
        Grid.SetColumn(centre, 2); main.Children.Add(centre);
        var s2 = _split2 = new GridSplitter { Width = 4 }; Grid.SetColumn(s2, 3); main.Children.Add(s2);
        Grid.SetColumn(rightScroll, 4); main.Children.Add(rightScroll);
        _editorSplit = hs;

        _status.TextTrimming = TextTrimming.CharacterEllipsis;
        var statusBar = new Border
        {
            Child = _status, Padding = new Thickness(4, 3),
            BorderThickness = new Thickness(0, 1, 0, 0), BorderBrush = new SolidColorBrush(Color.FromArgb(60, 255, 255, 255)),
        };
        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto") };
        Grid.SetRow(toolbar, 0); root.Children.Add(toolbar);
        Grid.SetRow(main, 1); root.Children.Add(main);
        Grid.SetRow(statusBar, 2); root.Children.Add(statusBar);
        return root;
    }

    Grid? _centre, _mainGrid;
    Control? _leftPane, _rightPane, _split1, _split2, _editorSplit;
    bool _expanded;
    GridLength[]? _savedColumns;
    GridLength[]? _savedRows;

    /// A panel that zooms on its own with Ctrl + mouse wheel (remembered in the settings).
    ZoomHost Zoomable(string key, Control child)
    {
        var z = new ZoomHost(key, child) { Zoom = _settings.Zoom(key) };
        z.ZoomChanged += RememberZoom;
        _zoom[key] = z;
        return z;
    }

    void RememberZoom(string key, double zoom)
    {
        _settings.PanelZoom[key] = zoom;
        SetStatus($"{key} zoom {zoom * 100:0}% (Ctrl + wheel; reset in Settings > Panel zoom)");
    }

    /// Tuner mode: the calibration editor fills the window, datalogging beside it.
    Control BuildTunerLayout()
    {
        var bar = new WrapPanel { Margin = new Thickness(6, 4) };
        bar.Children.Add(FileMenu());
        bar.Children.Add(new Separator { Width = 8 });
        // the calibration editor's Tools, Emulator, Datalogging, Back, Undo and Redo come onto this line in Tuner mode;
        // the status goes beside its Definition bar (and to the Debug page's log)
        bar.Children.Add(_tunerSlot);
        bar.Children.Add(_pluginsMenuTuner);
        bar.Children.Add(_pluginBarTuner);
        _zTunerDatalog = new ZoomHost("Tuner datalog", new Panel()) { Zoom = _settings.Zoom("Tuner datalog") };
        _zTunerDatalog.ZoomChanged += RememberZoom;
        _zoom["Tuner datalog"] = _zTunerDatalog;
        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("*,4,520") };
        var calHost = new ContentControl { Tag = "tuner-calibration" };
        Grid.SetColumn(calHost, 0); body.Children.Add(calHost);
        var gs = new GridSplitter { Width = 4 }; Grid.SetColumn(gs, 1); body.Children.Add(gs);
        Grid.SetColumn(_zTunerDatalog, 2); body.Children.Add(_zTunerDatalog);
        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(bar, 0); root.Children.Add(bar);
        Grid.SetRow(body, 1); root.Children.Add(body);
        _tunerCalHost = calHost;
        return root;
    }
    ContentControl? _tunerCalHost;
    readonly StackPanel _tunerSlot = new() { Orientation = Orientation.Horizontal };
    // plugin buttons, one row on each bar
    readonly StackPanel _pluginBarSim = new() { Orientation = Orientation.Horizontal }, _pluginBarTuner = new() { Orientation = Orientation.Horizontal };
    PluginManager? _plugins;
    // the Plugins drop-down on each bar: shown only while a plugin is loaded (Settings > Plugins picks them)
    Button? _pluginsMenuSimField, _pluginsMenuTunerField;
    Button _pluginsMenuSim => _pluginsMenuSimField ??= PluginsMenu();
    Button _pluginsMenuTuner => _pluginsMenuTunerField ??= PluginsMenu();
    void UpdatePluginsMenu()
    {
        bool any = _plugins?.Plugins.Count > 0;
        _pluginsMenuSim.IsVisible = any;
        _pluginsMenuTuner.IsVisible = any;
    }

    /// The Plugins drop-down: what the loaded plugins add, and the Settings page that picks them.
    Button PluginsMenu() => Toolbar.Menu("Plugins", "🧩", () =>
    [
        .. _plugins?.MenuItems ?? [],
        .. (_plugins?.MenuItems.Count > 0 ? new[] { Toolbar.Entry.Line } : []),
        new Toolbar.Entry("🧩", "Manage plugins…", "Settings > Plugins: pick the plugin .dlls to load, and switch them on or off.", () => OpenSettings("Plugins")),
    ]);

    /// Tuner mode: what only the workbench shows is let go - the lists it fills, and in Low performance mode the source editor's copy of the text (the text itself is kept: it comes back into the editor with the workbench) - and the memory handed back, so a small laptop has it for the datalog.
    void ReleaseWorkbench()
    {
        _traceList.SetRows([]); _traceShown = -1;
        _disList.SetRows([]); _callList.SetRows([]); _outList.SetRows([]); _portList.SetRows([]);
        _lastPcShown = -1; _lastSourceShown = "";
        if (Perf.Low && _current != null && !_editorParked)
        {
            _buffers[_current] = _editor.Text ?? "";
            _editorParked = true;
            _suppressEdit = true; _editor.Text = ""; _suppressEdit = false;
        }
        Dispatcher.UIThread.Post(() =>
        {
            System.Runtime.GCSettings.LargeObjectHeapCompactionMode = System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
        }, DispatcherPriority.Background);
    }

    /// The editor's text was let go in Tuner mode (it is in _buffers): what is shown is read from there.
    bool _editorParked;
    string EditorText => _editorParked && _current != null && _buffers.TryGetValue(_current, out var t) ? t : _editor.Text ?? "";

    void SetTunerMode(bool on)
    {
        if (_tunerRoot == null || _simRoot == null || _zCalibration == null || _zDatalog == null || _zTunerDatalog == null || _tunerCalHost == null) return;
        if (on == _tuner && _scaler.Child == (on ? _tunerRoot : _simRoot)) return;
        _tuner = on;
        _settings.TunerMode = on;
        if (on)
        {
            if (_expanded) ToggleExpand();
            SelectTab("Problems");
            SetTabContent("Calibration", null);
            SetTabContent("Datalog", null);
            _zDatalog.Child = null;
            UpdateLayout();                       // let the tabs drop them before they move
            _tunerCalHost.Content = UiStyles.Adopt(_zCalibration);
            _zTunerDatalog.Child = UiStyles.Adopt(_datalog);
            _datalog.SetCompact(true);
            _scaler.Child = _tunerRoot;
            if (_host.IsRunning) _host.Control("pause");
            ReleaseWorkbench();
        }
        else
        {
            // leaving tuner mode: a replay driving the simulator has nowhere to show, so stop it
            _datalog.StopPlayback();
            _tunerCalHost.Content = null;
            _zTunerDatalog.Child = null;
            UpdateLayout();
            _zDatalog.Child = UiStyles.Adopt(_datalog);
            _datalog.SetCompact(false);
            // the source back into the editor
            if (_editorParked && _current != null && _buffers.TryGetValue(_current, out var parked))
            {
                _editorParked = false;
                _suppressEdit = true; _editor.Text = parked; _suppressEdit = false;
            }
            _lastPcShown = -1; _lastSourceShown = "";
            SetTabContent("Calibration", UiStyles.Adopt(_zCalibration));
            SetTabContent("Datalog", UiStyles.Adopt(_zDatalog));
            _scaler.Child = _simRoot;
        }
        _calibration.SetTunerMode(on);
        _calibration.MoveBarItems(on ? _tunerSlot : null);
        _calibration.Refresh();
        AppLog.Action("ui", on ? "tuner mode" : "simulator mode");
        SetStatus(on ? "Tuner mode: open a .bin, Detect its maps, connect the datalog (Settings > Emulator & datalog) and the emulator" : "Simulator mode");
    }

    void SetTabContent(string header, Control? content)
    {
        foreach (var item in _bottom.Items)
            if (item is TabItem t && (t.Tag as string) == header) t.Content = content;
    }

    /// Give the lower tabs (calibration editor, datalog, hit trace) the whole window, or put the layout back exactly as it was (including any splitter positions).
    void ToggleExpand()
    {
        if (_centre == null || _mainGrid == null) return;
        _expanded = !_expanded;
        if (_expanded)
        {
            _savedColumns = [.. _mainGrid.ColumnDefinitions.Select(c => c.Width)];
            _savedRows = [.. _centre.RowDefinitions.Select(r => r.Height)];
            _mainGrid.ColumnDefinitions[0].Width = new GridLength(0);
            _mainGrid.ColumnDefinitions[1].Width = new GridLength(0);
            _mainGrid.ColumnDefinitions[2].Width = GridLength.Star;
            _mainGrid.ColumnDefinitions[3].Width = new GridLength(0);
            _mainGrid.ColumnDefinitions[4].Width = new GridLength(0);
            _centre.RowDefinitions[1].Height = new GridLength(0);
            _centre.RowDefinitions[2].Height = new GridLength(0);
            _centre.RowDefinitions[3].Height = GridLength.Star;
            // keep the engine inputs beside the expanded tabs (the simulator is still running)
            _mainGrid.ColumnDefinitions[0].Width = new GridLength(250);
            if (_zInputs != null) _miniInputs.Child = UiStyles.Adopt(_zInputs);
        }
        else
        {
            if (_zInputs != null && _leftStack != null && _miniInputs.Child == _zInputs) _leftStack.Children.Add(UiStyles.Adopt(_zInputs));
            if (_savedColumns != null) for (int i = 0; i < _savedColumns.Length; i++) _mainGrid.ColumnDefinitions[i].Width = _savedColumns[i];
            if (_savedRows != null) for (int i = 0; i < _savedRows.Length; i++) _centre.RowDefinitions[i].Height = _savedRows[i];
        }
        foreach (var c in new[] { _leftPane, _rightPane, _split1, _split2, _editorSplit, _zoom["Source"] })
            c?.IsVisible = !_expanded;
        _miniInputs.IsVisible = _expanded;
        if (_miniInputs.Tag is Control mini) mini.IsVisible = _expanded;
        _calibration.SetExpanded(_expanded);
    }

    // ------------------------------------------------------------------ settings

    void OpenSettings() => OpenSettings(null);

    void OpenSettings(string? page)
    {
        SaveLayout();
        var original = _settings;
        var originalProfile = _profile;
        bool previewed = false;
        var w = new SettingsWindow(_settings, () => _mcpState, _profile, FuelMapAxes, _plugins);
        // Apply: show the changes now without writing them to disk; Cancel puts back what was there
        w.Applied += (s, profile) => { previewed = true; UseSettings(s, profile, save: false); SetStatus("settings applied (Save keeps them)"); };
        w.Closed += (_, _) =>
        {
            if (w.Result == null)
            {
                if (previewed) { UseSettings(original, originalProfile != _profile ? originalProfile : null, save: false); SetStatus("settings put back"); }
                return;
            }
            UseSettings(w.Result, w.ResultProfile, save: true);
            // plugins switched off or removed in the window: stopped and taken off the bars now; switched on: loaded now
            if (_plugins != null)
            {
                foreach (var gone in _plugins.Plugins.Select(l => l.Path).Distinct().ToList()
                                             .Where(path => !_settings.Plugins.Any(p => p.Enabled && SamePath(p.Path, path))))
                    _plugins.Unload(gone);
                foreach (var p in _settings.Plugins.Where(p => p.Enabled && !_plugins.Plugins.Any(l => SamePath(l.Path, p.Path))))
                    if (_plugins.Load(p.Path) is { } why) SetStatus("plugin not loaded: " + why);
            }
            UpdatePluginsMenu();
            SetStatus("settings saved");
            AppLog.Action("settings", "saved");
        };
        if (page != null) w.ShowPage(page);
        w.ShowDialog(this);
    }

    /// Put settings from the Settings window into effect, keeping the window and layout values it does not edit; `save` writes them to disk.
    void UseSettings(AppSettings r, ProcessorProfile? profile, bool save)
    {
        var pw = r.McpPassword;
        if (!ReferenceEquals(r, _settings))
        {
            r.WindowX = _settings.WindowX; r.WindowY = _settings.WindowY;
            r.WindowWidth = _settings.WindowWidth; r.WindowHeight = _settings.WindowHeight; r.Maximized = _settings.Maximized;
            r.LeftColumn = _settings.LeftColumn; r.CentreColumn = _settings.CentreColumn; r.RightColumn = _settings.RightColumn;
            r.BottomPanel = _settings.BottomPanel; r.SelectedTab = _settings.SelectedTab;
            r.PanelSizes = _settings.PanelSizes; r.Favourites = _settings.Favourites;
            r.Package = _settings.Package; r.LastFile = _settings.LastFile;
        }
        bool tunerChanged = r.TunerMode != _tuner;
        // "Fit to the screen" ticked again: pick the scale and the layout for this screen now
        bool refit = r.FitToScreen && r.FittedFor.Length == 0 && ScreenFit.Fit(r, Screens.ScreenFromWindow(this) ?? Screens.Primary);
        _settings = r;
        _settings.McpPassword = pw;
        if (refit) ApplyLayout();
        if (save) _settings.Save();
        if (profile != null) ApplyProfile(profile);
        ApplySettings(first: false);
        if (tunerChanged) SetTunerMode(_settings.TunerMode);
    }

    /// The RPM and load breakpoints of the ROM's own fuel map, so the AFR target table on the Settings page can be laid out on the very same axes as the map it is tuning. Empty arrays when nothing suitable is open.
    (double[] Rpm, double[] Load) FuelMapAxes()
    {
        try
        {
            var defs = _host.Defs();
            // the low-cam fuel map first (it is the one a target table is normally built around), then any map with both axes in the ROM
            var item = defs.Items.FirstOrDefault(i => i.IsTable && i.Rows > 1 && i.Cols > 1 && i.ColumnScaleAddress != null && MapSide.Side(i) != true)
                       ?? defs.Items.FirstOrDefault(i => i.IsTable && i.Rows > 1 && i.Cols > 1 && i.ColumnScaleAddress != null)
                       ?? defs.Items.FirstOrDefault(i => i.IsTable && i.Rows > 1 && i.Cols > 1 && i.RowAxis?.Address != null && i.ColAxis?.Address != null);
            if (item == null) return ([], []);
            var rpm = _host.AxisValues(item.RowAxis, item.Rows).Where(v => !double.IsNaN(v)).ToArray();
            var load = _host.AxisValues(item.ColAxis, item.Cols).Where(v => !double.IsNaN(v)).ToArray();
            // a load axis kept in mbar reads in the same numbers as kPa once divided by ten, which is the unit the targets and the datalog both use
            if (load.Length > 0 && load.Max() > 400) load = [.. load.Select(v => Math.Round(v / 10, 1))];
            return (rpm, load);
        }
        catch (Exception ex) { AppLog.Error("settings", "could not read the fuel map axes", ex); return ([], []); }
    }

    /// Put the settings into effect: layout (at start), scale, fonts, colours, simulation options, ports, and the MCP server.
    void ApplySettings(bool first)
    {
        var s = _settings;
        Perf.Set(s.LowPerformance ?? Perf.Suggested);
        if (first) ApplyLayout();
        ApplyRest(s, first);
    }

    /// The column widths and the bottom panel's height from the settings.
    void ApplyLayout()
    {
        var s = _settings;
        if (_mainGrid != null && _centre != null)
        {
            GridLength G(string v, GridLength fallback) { try { return GridLength.Parse(v); } catch { return fallback; } }
            _mainGrid.ColumnDefinitions[0].Width = G(s.LeftColumn, new GridLength(3, GridUnitType.Star));
            _mainGrid.ColumnDefinitions[2].Width = G(s.CentreColumn, new GridLength(4, GridUnitType.Star));
            _mainGrid.ColumnDefinitions[4].Width = G(s.RightColumn, new GridLength(3, GridUnitType.Star));
            // the old fixed 360 left a map two rows high on a 1080p screen: an untouched default now takes three fifths of the height, whatever the screen
            _centre.RowDefinitions[3].Height = s.BottomPanel == "360" ? new GridLength(1.5, GridUnitType.Star) : G(s.BottomPanel, new GridLength(1.5, GridUnitType.Star));
            _package.SelectedIndex = s.Package == nameof(ChipView.Package.Qfp64) ? 1 : 0;
            if (s.SelectedTab.Length > 0) SelectTab(s.SelectedTab);
        }
    }

    void ApplyRest(AppSettings s, bool first)
    {
        double scale = Math.Clamp(s.UiScale, 0.5, 3);
        ScreenFit.UiScale = scale;
        _scaler.LayoutTransform = Math.Abs(scale - 1) < 0.001 ? null : new ScaleTransform(scale, scale);
        foreach (var (key, z) in _zoom) z.Zoom = s.Zoom(key);        // the source editor's zoom sets its font size
        _datalog.ApplyGaugeZoom();
        _host.Speed = s.SpeedIndex switch { 0 => 0.1, 1 => 0.5, 2 => 1, 3 => 4, 4 => 0, _ => 1 };
        TableModel.SetColours(SettingsWindow.Parse(s.TableLow), SettingsWindow.Parse(s.TableMid), SettingsWindow.Parse(s.TableHigh),
            SettingsWindow.Parse(s.TableMax), SettingsWindow.Parse(s.TraceColour), SettingsWindow.Parse(s.TrailColour));
        CodeEditor.SetHitColours(SettingsWindow.Parse(s.HitCodeColour), SettingsWindow.Parse(s.HitDataColour));
        _host.FastBoot = s.FastBoot;
        _calibration.SetOptions(s.LiveTrace, s.FollowReads, s.TrailSeconds);
        _calibration.TableStretch = s.TableStretch;
        TouchMode.Set(s.TouchMode);
        _calibration.TargetLow = TargetMap.Parse(s.AfrTargetLow);
        _calibration.TargetHigh = TargetMap.Parse(s.AfrTargetHigh);
        _calibration.WidebandCorrection = LookupCurve.Parse(s.WidebandCorrection);
        // a Demon datalogs over the emulator's own port: the datalog goes through it (or logs the simulator), whatever port was set before
        _datalog.Port = s.EmulatorType == "Demon" && s.DatalogPort != "simulator" ? "emulator" : s.DatalogPort;
        _datalog.Baud = s.DatalogBaud; _datalog.Protocol = s.DatalogProtocol;
        OkiRomSim.Calibration.ChannelStream.Selected = s.DatalogStreamChannels is { Count: > 0 } sc ? sc : [.. OkiRomSim.Calibration.DatalogChannels.Defaults];
        _datalog.GetStreamChannels = () => _settings.DatalogStreamChannels;
        _datalog.SetStreamChannels = list => { _settings.DatalogStreamChannels = list; _settings.Save(); };
        if (s.DetectedLayout is { Length: > 0 } dl)
            try { _datalog.Engine.Detected = System.Text.Json.JsonSerializer.Deserialize<OkiRomSim.Calibration.DetectedProtocol>(dl); }
            catch (Exception ex) { AppLog.Error("datalog", "saved layout could not be read", ex); }
        _datalog.DriveSimulator = s.DatalogDrivesSimulator;
        _external.Start(s.ExternalFeeds);
        _datalog.Gauges.External = _external;
        var eng = _datalog.Engine;
        eng.IntervalMs = s.DatalogIntervalMs; eng.KeepFrames = s.DatalogKeepFrames;
        var curves = ParseNamedCurves(s.AnalogCurves);
        eng.AuxChannels = [.. s.AuxChannels.Select(a =>
        {
            var ch = a.ToChannel();
            if (curves.TryGetValue(ch.Name, out var curve)) ch.Curve = curve;
            return ch;
        })];
        eng.Wideband.Stoich = s.StoichAfr;
        if (s.WidebandType != "none" && s.WidebandPort.Length > 0 && (eng.Wideband.Type != s.WidebandType || !eng.Wideband.Running))
        {
            var (type, port, baud) = (s.WidebandType, s.WidebandPort, s.WidebandBaud);
            Task.Run(() =>
            {
                try { eng.Wideband.Start(type, port, baud); }
                catch (Exception ex)
                {
                    AppLog.Error("wideband", "could not open " + port, ex);
                    Dispatcher.UIThread.Post(() => SetStatus("wideband: " + ex.Message));
                }
            });
        }
        else if (s.WidebandType == "none") Task.Run(() => { try { eng.Wideband.Stop(); } catch { } });
        _hitView.SetOptions(s.MoatesPort, s.MoatesBase, s.HitSkipRepeats, s.HitColourSource);
        var sm = eng.Smooth;
        sm.Frames = s.DatalogSmoothFrames; sm.SpikePercent = s.DatalogSmoothSpikePercent; sm.Blend = s.DatalogSmoothBlend;
        sm.Skip.Clear();
        foreach (var c in s.DatalogSmoothSkip.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)) sm.Skip.Add(c);
        if (sm.Enabled != s.DatalogSmooth) _datalog.SetSmoothing(s.DatalogSmooth);
        // the emulator link: which device, how fast, and how patient to be with the cable
        var emu = _host.Emulator;
        emu.Kind = s.EmulatorType; emu.Baud = s.EmulatorBaud;
        emu.PostWritePauseMs = Math.Clamp(s.PostWritePauseMs, 0, 500);
        emu.TimeoutMs = Math.Clamp(s.SerialTimeoutMs * 3, 100, 5000);
        emu.Retries = Math.Clamp(s.SerialRetries, 0, 20);
        if (int.TryParse(s.MoatesBase, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var emuBase)) emu.Base = emuBase;
        // the same numbers drive the car's datalog link
        DatalogProtocol.TimeoutMsDefault = Math.Clamp(s.SerialTimeoutMs, 20, 5000);
        DatalogProtocol.PostWritePauseMsDefault = Math.Clamp(s.PostWritePauseMs, 0, 500);
        DatalogProtocol.RetriesDefault = Math.Clamp(s.SerialRetries, 0, 20);
        SerialLink.RaiseDtrRts = s.SerialDtrRts;
        SerialLink.WriteTimeoutMs = Math.Clamp(s.SerialWriteTimeoutMs, 50, 10000);
        _calibration.EmulatorPort = s.MoatesPort;
        _datalog.EmulatorPort = s.MoatesPort;
        if (first) _host.AutoUpload = s.EmulatorAutoUpload;
        _calibration.UpdateEmulator();
        TableKeys.Use(s.TableHotKeys);
        LinkSupervisor.Attempts = Math.Clamp(s.ReconnectAttempts, 1, 100);
        LinkSupervisor.DelayMs = Math.Clamp(s.ReconnectDelayMs, 200, 30000);
        _hotKeys = s.HotKeys.Where(kv => kv.Value.Length > 0)
            .Select(kv => { try { return (kv.Key, Gesture: KeyGesture.Parse(kv.Value)); } catch { return (kv.Key, Gesture: (KeyGesture?)null); } })
            .Where(x => x.Gesture != null).ToDictionary(x => x.Key, x => x.Gesture!);
        StartAutoSave();
        _ = RestartMcpAsync();
    }
    /// "name: 0=0, 2.5=50, 5=100" per line, from Settings > Targets.
    static Dictionary<string, LookupCurve> ParseNamedCurves(string text)
    {
        var map = new Dictionary<string, LookupCurve>(StringComparer.OrdinalIgnoreCase);
        foreach (var raw in (text ?? "").Split('\n'))
        {
            var line = raw.Trim();
            int colon = line.IndexOf(':');
            if (colon <= 0) continue;
            var curve = LookupCurve.Parse(line[(colon + 1)..]);
            if (curve.Any) map[line[..colon].Trim()] = curve;
        }
        return map;
    }

    Dictionary<string, KeyGesture> _hotKeys = [];
    /// Readings polled from outside the ECU (Settings > Emulator & datalog), shown on the gauges.
    readonly ExternalData _external = new();

    /// Remember the window and panel layout for next time.
    void SaveLayout()
    {
        var s = _settings;
        s.Maximized = WindowState == WindowState.Maximized;
        if (WindowState == WindowState.Normal)
        {
            s.WindowWidth = Width; s.WindowHeight = Height;
            s.WindowX = Position.X; s.WindowY = Position.Y;
        }
        if (_mainGrid != null && _centre != null)
        {
            var cols = _expanded && _savedColumns != null ? _savedColumns : [.. _mainGrid.ColumnDefinitions.Select(c => c.Width)];
            var rows = _expanded && _savedRows != null ? _savedRows : [.. _centre.RowDefinitions.Select(r => r.Height)];
            s.LeftColumn = cols[0].ToString(); s.CentreColumn = cols[2].ToString(); s.RightColumn = cols[4].ToString();
            s.BottomPanel = rows[3].ToString();
        }
        s.SelectedTab = SelectedTab();
        s.Package = _chip.CurrentPackage.ToString();
        s.TunerMode = _tuner;
        s.LastFile = _target != null && File.Exists(_target) ? _target : _current;
        s.Save();
    }

    // ------------------------------------------------------------------ MCP server

    async Task RestartMcpAsync()
    {
        StopMcp();
        var s = _settings;
        if (!s.McpEnabled) { _mcpState = "off"; return; }
        try
        {
            var roots = s.McpRoots.Where(Directory.Exists).ToList();
            if (roots.Count == 0)
                roots.Add(Path.GetDirectoryName(_target ?? _current ?? "") is { Length: > 0 } d ? d : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments));
            // A client may be on another computer altogether, with no path in common with this one. This folder is always in the workspace and always writable, so such a client can send a file across with file_upload and then ask for it with app_open, whatever else is or is not configured.
            var transfer = McpTransferDir;
            try { Directory.CreateDirectory(transfer); if (!roots.Contains(transfer)) roots.Add(transfer); }
            catch (Exception ex) { AppLog.Error("mcp", "could not make the transfer folder", ex); }
            var session = new AppMcpSession(_host, _datalog,
                () => { if (_current != null) _buffers[_current] = EditorText; return _buffers.Select(kv => (kv.Key, kv.Value)).ToList(); },
                m => Dispatcher.UIThread.Post(() => SetStatus(m)),
                () => (_settings.DatalogPort, _settings.DatalogProtocol, _settings.DatalogBaud),
                (rom, name) => OpenRomImage(rom, name),
                path => OpenFile(path));
            var workspace = new OkiRomSim.Mcp.Workspace(roots) { ReadOnly = s.McpReadOnly, TransferDir = transfer };
            // a client on another machine can ask for a folder here; the user decides
            workspace.AskToAddRoot = (folder, why) => Dispatcher.UIThread.Invoke(async () =>
            {
                bool yes = await Dialogs.Confirm(this, "Let a client read this folder?",
                    $"An MCP client is asking to use files in:\n\n{folder}\n\nWhy: {why}\n\n" +
                    "Allowing it lets the client read (and, unless the server is read-only, write) files in that folder until this program is closed.",
                    "Allow", "Refuse");
                AppLog.Write(LogKind.Mcp, "mcp", $"workspace_allow {folder}: {(yes ? "allowed" : "refused")}", why);
                if (yes) { _settings.McpRoots = [.. _settings.McpRoots.Append(folder).Distinct()]; _settings.Save(); }
                return yes;
            }).GetAwaiter().GetResult();
            var server = new OkiRomSim.Mcp.McpServer(workspace, session)
            {
                Log = c => Dispatcher.UIThread.Post(() => SetStatus($"MCP {c.Client}: {c.Tool} {(c.Ok ? "ok" : "failed")} ({c.Milliseconds} ms)")),
            };
            var http = new OkiRomSim.Mcp.McpHttp(server, new OkiRomSim.Mcp.McpHttpOptions { Port = s.McpPort, AllowRemote = s.McpRemote, Password = s.McpPassword });
            await http.StartAsync();
            _mcpHttp = http;
            _mcpState = $"running at {http.Url}, workspace {string.Join(", ", roots)}{(s.McpPassword.Length > 0 ? ", password required" : ", NO password")}";
            SetStatus("MCP server " + _mcpState);
        }
        catch (Exception ex)
        {
            _mcpState = "could not start: " + ex.Message;
            SetStatus("MCP server " + _mcpState);
        }
    }

    void StopMcp()
    {
        var h = _mcpHttp;
        _mcpHttp = null;
        if (h != null) _ = h.DisposeAsync().AsTask();
    }

    void SetItems(ListBox list, IEnumerable<string> items, int? select = null)
    {
        var snapshot = items.ToList();
        var key = string.Join("\n", snapshot);
        if (_lastItems.TryGetValue(list, out var previous) && previous == key && select == null) return;
        _lastItems[list] = key;
        Dispatcher.UIThread.Post(() =>
        {
            if (_updatingLists.Contains(list)) return;
            _updatingLists.Add(list);
            try
            {
                list.ItemsSource = snapshot;
                if (select is int i && i >= 0 && i < snapshot.Count) list.SelectedIndex = i;
            }
            catch (Exception ex) { _status.Text = ex.Message; }
            finally { _updatingLists.Remove(list); }
        }, DispatcherPriority.Background);
    }
    readonly HashSet<ListBox> _updatingLists = [];
    readonly Dictionary<ListBox, string> _lastItems = [];

    static TextBlock Header(string t) => new()
    {
        Text = t.ToUpperInvariant(), FontSize = 10, Opacity = 0.6, Margin = new Thickness(0, 8, 6, 2),
        VerticalAlignment = VerticalAlignment.Center,
    };
    static TabItem Tab(string header, Control content, string tip)
    {
        var t = new TabItem
        {
            Header = new TextBlock { Text = header, FontSize = 13 }, Tag = header, Content = content,
            MinHeight = 28, Padding = new Thickness(10, 2),
        };
        ToolTip.SetTip(t, tip);
        return t;
    }
    string SelectedTab() => (_bottom.SelectedItem as TabItem)?.Tag as string ?? "";
    static string Label(string path) => Path.GetFileName(path);

    Control MemoryPanel()
    {
        var bar = new WrapPanel { Margin = new Thickness(4) };   // wraps on a narrow panel instead of pushing the buttons out of sight
        bar.Children.Add(new TextBlock { Text = "Address ", VerticalAlignment = VerticalAlignment.Center });
        Tip(_memAddr, "Start address (hex) or a label.");
        bar.Children.Add(_memAddr);
        bar.Children.Add(ToolButton("Go", RefreshMemory, "Show 256 bytes from the address."));
        bar.Children.Add(Small("  RAM 0000-0FFF, ROM above 0480"));
        Tip(_memory, "Live hex dump; refreshes while this tab is open.");
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(bar, 0); g.Children.Add(bar);
        Grid.SetRow(_memory, 1); g.Children.Add(_memory);
        // the map (what each byte is, its value, what writes it) first; the hex dump beside it
        _memMap = new MemoryMapView(_host);
        _memMap.GoToCode += GoToAddress;
        _memMap.Status += m => SetStatus(m);
        var tabs = new TabControl();
        tabs.Items.Add(new TabItem { Header = "Map", Content = _memMap });
        tabs.Items.Add(new TabItem { Header = "Hex", Content = g });
        foreach (var t in tabs.Items.OfType<TabItem>()) { t.FontSize = 12; t.MinHeight = 24; t.Padding = new Thickness(8, 1); }
        ToolTip.SetTip((TabItem)tabs.Items[0]!, "Every RAM byte the ROM uses, by name, with its value in real units and the code that writes it. Double-click to change one.");
        return tabs;
    }
    MemoryMapView? _memMap;

    long _traceShown = -1;

    /// Problems: the build's errors and warnings, the worst first.
    Control ProblemsPanel()
    {
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        var bar = Panels.BarAround(_problemSummary);
        Grid.SetRow(bar, 0); g.Children.Add(bar);
        Grid.SetRow(_problems, 1); g.Children.Add(_problems);
        return g;
    }
    readonly TextBlock _problemSummary = new() { Text = "not built yet", FontSize = 12, Margin = new Thickness(10, 6), Opacity = 0.85 };

    void ShowProblems(List<Diagnostic> ordered)
    {
        _problemLoc = [.. ordered.Select(d => (d.File, d.Line))];
        int errors = ordered.Count(d => d.Severity == Severity.Error), warnings = ordered.Count(d => d.Severity == Severity.Warning);
        _problemSummary.Text = ordered.Count == 0 ? "✔  the source builds clean: no errors, no warnings"
            : $"{(errors > 0 ? $"✖  {errors} error{(errors == 1 ? "" : "s")}" : "✔  no errors")}   ·   {warnings} warning{(warnings == 1 ? "" : "s")}" +
              (ordered.Count - errors - warnings is > 0 and var n ? $"   ·   {n} note{(n == 1 ? "" : "s")}" : "");
        _problemSummary.Foreground = errors > 0 ? DataList.Error : warnings > 0 ? DataList.Warning : DataList.Good;
        _problems.Empty = "No errors or warnings: the last build was clean.";
        _problems.SetRows([.. ordered.Select(d =>
        {
            var ink = d.Severity == Severity.Error ? DataList.Error : d.Severity == Severity.Warning ? DataList.Warning : DataList.Data;
            return new DataList.Row(
                [new(d.Severity == Severity.Error ? "✖" : d.Severity == Severity.Warning ? "▲" : "i", ink, true), new(d.Severity.ToString().ToLowerInvariant(), ink),
                 new($"{Path.GetFileName(d.File)}:{d.Line}", DataList.Address), new(d.Message, DataList.Text)],
                ink, -1, $"{d.File}:{d.Line}\n{d.Message}", Tag: (d.File, d.Line));
        })]);
    }

    /// The breakpoint to act on: the one picked in the list, else what is typed, else the lookup result picked.
    string? BreakTarget() =>
        (_lookupQ.Text ?? "").Trim() is { Length: > 0 } t ? t
        : _lookupData.Selected is { Address: >= 0 } r ? Hex(r.Address) : null;

    Control LookupPanel()
    {
        Tip(_lookupQ, "Type a label, a calibration name or an address; Enter looks it up. Break puts a breakpoint on it.");
        _lookupQ.FontSize = 12; _lookupQ.MinHeight = 26;
        _lookupQ.KeyDown += (_, e) => { if (e.Key == Key.Enter) DoLookup(); };
        void Break()
        {
            if (BreakTarget() is not { } text) { SetStatus("type a label or a hex address, or pick a result, first"); return; }
            var r = _host.AddBreakpoint(text);
            SetStatus(r.ok ? r.added ? $"breakpoint set at {Hex(r.address)}" : $"there is already a breakpoint at {Hex(r.address)}" : r.error);
            if (r.ok) RefreshDisassembly(true);
        }
        void Toggle()
        {
            if (BreakTarget() is not { } text) { SetStatus("type a label or a hex address, or pick a result, first"); return; }
            var r = _host.ToggleBreakpoint(text);
            SetStatus(r.ok ? $"breakpoint {(r.enabled ? "set" : "cleared")} at {Hex(r.address)}" : r.error);
            if (r.ok) RefreshDisassembly(true);
        }
        void Remove()
        {
            if (_bpList.Selected is not { Address: >= 0 } row) { SetStatus("pick a breakpoint in the list first"); return; }
            _host.RemoveBreakpoint(row.Address);
            SetStatus($"breakpoint at {Hex(row.Address)} removed");
            RefreshDisassembly(true);
        }
        var bar = Panels.Bar(_lookupQ,
            Panels.Button("Look up", DoLookup, "Find labels and settings matching the text, or what lives at an address.", "🔍"),
            Panels.Button("Find references", DoXref, "List every instruction that reads or writes the address.", "⇄"),
            Panels.Divider(),
            Panels.Button("Break", Break, "Set a breakpoint on the label or address typed (or the result picked below). It stays set if it is already there.", "●"),
            Panels.Button("Toggle", Toggle, "Set a breakpoint on the label or address typed (or the result picked), or clear it if it is already there."),
            Panels.Button("Remove", Remove, "Remove the breakpoint picked in the Breakpoints list, leaving the rest alone."),
            Panels.Button("Clear all", () => { _host.ClearBreakpoints(); RefreshDisassembly(true); }, "Remove every breakpoint."));
        _bpList.Activated += r => { if (r.Address >= 0) GoToAddress(r.Address); };
        Tip(_bpList, "Breakpoints. Double-click one to show it in the source; right-click to switch it off (kept, not stopped at) or on again, or remove it. Double-click a disassembly line to toggle one; F9 toggles at the source caret.");
        _lookupList.FontFamily = MonoFont;
        _lookupList.DoubleTapped += (_, _) =>
        {
            int i = _lookupList.SelectedIndex;
            if (i >= 0 && i < _lookupRows.Count) GoToAddress(_lookupRows[i].Address);
            else if (i >= 0 && i < _lookupLines.Count && int.TryParse(_lookupLines[i].Split(' ')[0], NumberStyles.HexNumber, null, out var a)) GoToAddress(a);
        };
        _lookupData.Activated += r => { if (r.Address >= 0) GoToAddress(r.Address); };
        // right-click: the result as a breakpoint, and the rest of what can be done with it
        (string, Action) SetBreak(int a) => ($"● Add {Hex(a)} as a breakpoint", () =>
        {
            var r = _host.AddBreakpoint(Hex(a));
            SetStatus(r.ok ? r.added ? $"breakpoint set at {Hex(r.address)}" : $"there is already a breakpoint at {Hex(r.address)}" : r.error);
            _bpShown = null;
            if (r.ok) RefreshDisassembly(true);
        });
        _lookupData.Menu = r => r.Address < 0 ? [] : new (string, Action)[]
        {
            SetBreak(r.Address),
            ("Go to it in the source", () => GoToAddress(r.Address)),
            ("Find references to it", () => { _lookupQ.Text = Hex(r.Address); DoXref(); }),
            ("Copy the address", () => _ = Clipboard?.SetTextAsync(Hex(r.Address))),
        };
        _traceList.Menu = r => r.Address < 0 ? [] : new (string, Action)[] { SetBreak(r.Address), ("Go to it in the source", () => GoToAddress(r.Address)) };
        _disList.Menu = r => r.Address < 0 ? [] : new (string, Action)[] { SetBreak(r.Address), ("Go to it in the source", () => GoToAddress(r.Address)) };
        _bpList.Menu = r => r.Address < 0 ? [] : new (string, Action)[]
        {
            r.Tag is false
                ? ($"Enable the breakpoint at {Hex(r.Address)}", () => { _host.SetBreakpointEnabled(r.Address, true); _bpShown = null; SetStatus($"breakpoint at {Hex(r.Address)} on"); RefreshDisassembly(true); })
                : ($"Disable the breakpoint at {Hex(r.Address)}", () => { _host.SetBreakpointEnabled(r.Address, false); _bpShown = null; SetStatus($"breakpoint at {Hex(r.Address)} off: kept, not stopped at"); RefreshDisassembly(true); }),
            ($"Remove the breakpoint at {Hex(r.Address)}", () => { _host.RemoveBreakpoint(r.Address); _bpShown = null; SetStatus($"breakpoint at {Hex(r.Address)} removed"); RefreshDisassembly(true); }),
            ("Go to it in the source", () => GoToAddress(r.Address)),
        };
        ToolTip.SetTip(_lookupData, "Results. Double-click one to go to it in the source (and the disassembly); pick one and press Break to stop there.");
        // the results and the breakpoints side by side, the splitter between them
        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("3*,6,2*"), Margin = new Thickness(8, 8, 8, 0) };
        var results = Panels.Card("Results", _lookupData);
        Grid.SetColumn(results, 0); body.Children.Add(results);
        var gs = new GridSplitter { Width = 6, Background = Brushes.Transparent }; Grid.SetColumn(gs, 1); body.Children.Add(gs);
        var bps = Panels.Card("Breakpoints", _bpList);
        Grid.SetColumn(bps, 2); body.Children.Add(bps);
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(bar, 0); g.Children.Add(bar);
        Grid.SetRow(body, 1); g.Children.Add(body);
        return g;
    }

    void BuildInputs()
    {
        (string key, string label, double min, double max, double val, string tip)[] defs =
        {
            ("rpm", "RPM", 0, 9000, 800, "Engine speed: drives the crank (CKP), TDC and CYP signals."),
            ("map", "MAP kPa", 10, 250, 33, "Manifold pressure on AI6."),
            ("tps", "TPS %", 0, 100, 0, "Throttle position on AI7 (0.5-4.5 V)."),
            ("ect", "ECT °C", -40, 120, 85, "Coolant temperature (thermistor on mux B channel 2). The ROM filters it and ignores a sudden drop while running, so lowering it takes effect slowly or not at all - raise it, or reset, to see a new value."),
            ("iat", "IAT °C", -40, 120, 25, "Intake air temperature (thermistor on mux A channel 2)."),
            ("o2", "O2 V", 0, 1, 0.45, "Oxygen sensor voltage (mux A channel 0)."),
            ("vbatt", "Battery V", 8, 16, 14.2, "Battery voltage (mux A channel 7, through the ECU divider)."),
            ("speed", "km/h", 0, 250, 0, "Road speed: drives the vehicle speed sensor pulses on INT0."),
            ("baro", "Baro kPa", 60, 105, 101, "Barometric pressure (mux A channel 3). Sea level is about 101 kPa."),
            ("eld", "ELD V", 0, 5, 1.5, "Electrical load detector (mux B channel 0): lower volts = more electrical load."),
            ("egr", "EGR lift %", 0, 100, 0, "EGR valve lift feedback on AI3 (0.5-4.5 V)."),
            ("crankvbatt", "Crank batt V", 6, 12, 9.2, "Battery voltage while the starter is engaged (replaces Battery V when cranking is ticked)."),
        };
        foreach (var (key, label, min, max, val, tip) in defs)
        {
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("76,*,50"), Margin = new Thickness(0, -3) };
            var name = new TextBlock { Text = label, FontSize = 10.5, VerticalAlignment = VerticalAlignment.Center };
            var slider = new Slider { Minimum = min, Maximum = max, Value = val, Margin = new Thickness(0, -4) };
            _defaults[key] = val;
            var read = Mono(new TextBlock { FontSize = 10.5, VerticalAlignment = VerticalAlignment.Center, TextAlignment = TextAlignment.Right });
            read.Text = val.ToString("0.##", CultureInfo.InvariantCulture);
            ToolTip.SetTip(row, tip);
            slider.PropertyChanged += (_, e) =>
            {
                if (e.Property == Slider.ValueProperty)
                {
                    read.Text = slider.Value.ToString("0.##", CultureInfo.InvariantCulture);
                    if (!_syncingSliders) _host.SetInput(key, slider.Value);
                }
            };
            _host.SetInput(key, val);
            _sliders[key] = slider;
            Grid.SetColumn(name, 0); row.Children.Add(name);
            Grid.SetColumn(slider, 1); row.Children.Add(slider);
            Grid.SetColumn(read, 2); row.Children.Add(read);
            _inputs.Children.Add(row);
        }
        var checks = new WrapPanel();
        CheckBox Box(string key, string text, bool on, string tip)
        {
            var b = Tip(new CheckBox { Content = text, FontSize = 10.5, IsChecked = on, Margin = new Thickness(0, 0, 12, 0) }, tip);
            b.IsCheckedChanged += (_, _) => _host.SetInput(key, b.IsChecked == true ? 1 : 0);
            _host.SetInput(key, on ? 1 : 0);
            _boxes[key] = (b, on);
            checks.Children.Add(b);
            return b;
        }
        Box("cranking", "cranking (starter on)", false, "Starter engaged: battery sags. Start at a few hundred rpm for a realistic engine start.");
        Box("oilpressure", "VTEC oil pressure", true, "Oil pressure reaches the VTEC spool when the solenoid opens; untick to simulate a failed switch or low oil.");
        Box("power", "ignition on", true, "Main relay holding (P4.1 low). Untick for key-off: the ROM runs its shutdown path.");
        Box("ac", "A/C switch", false, "A/C request (pin B5): bit 2 of the 4700h switch buffer on the P28.");
        Box("starter", "starter signal (P13)", false, "P13 only: starter signal on port 4 pin 51.");
        Box("psp", "PS pressure (P13)", false, "P13 only: power-steering pressure switch on port 4 pin 52.");
        _inputs.Children.Add(checks);

        // the P28's two switch buffers, as the pins read (traced from the ROMs' 3B0h status byte, their GIO input selector and HTS's names). Bits the simulator drives itself are shown but locked.
        void Bits(string key, string label, byte start, string tip, (string Name, string Tip, string? Owner)[] bits)
        {
            _inputs.Children.Add(Tip(new TextBlock { Text = label, FontSize = 10.5, FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 4, 0, 0) }, tip));
            var grid = new Avalonia.Controls.Primitives.UniformGrid { Columns = 2 };
            var boxes = new CheckBox[8];
            byte Value() { byte v = 0; for (int i = 0; i < 8; i++) if (boxes[i].IsChecked == true) v |= (byte)(1 << i); return v; }
            for (int i = 0; i < 8; i++)
            {
                var (name, bitTip, owner) = bits[i];
                var bx = new CheckBox { Content = $"{i} {name}", FontSize = 9.5, Margin = new Thickness(0, -2), IsChecked = (start & (1 << i)) != 0 };
                ToolTip.SetTip(bx, $"{label} bit {i}: {bitTip}" + (owner != null ? $"\nDriven by the simulator: {owner}" : "\nTicked = pin high."));
                if (owner != null) bx.IsEnabled = false;
                bx.IsCheckedChanged += (_, _) => _host.SetInput(key, Value());
                boxes[i] = bx; grid.Children.Add(bx);
            }
            _host.SetInput(key, start);
            _bitRows[key] = (boxes, start);
            _inputs.Children.Add(grid);
        }
        Bits("porta", "Switches: 8255 port A", 0x38, "P28 8255 port A pins. The ROM stores them XOR 38h at RAM 210h.",
        [
            ("knock det. A", "knock detector output, sampled at every spark into the history the knock check reads (0ECh)", null),
            ("knock det. B", "second knock detector output, sampled with bit 0", null),
            ("code 24 pulse", "has to keep changing, or code 24 sets; together with bits 0/1 it is the knock circuit's check", "a 10 Hz square wave from the board model"),
            ("PS pressure", "power-steering pressure switch (B8); logged inverted as 3B0h bit 7", null),
            ("spare", "unused by the P28 ROMs (the P08 reads it as a feedback behind its fault bit 14)", null),
            ("VTEC feedback", "VTEC solenoid feedback: low while the solenoid is energised (code 21)", "follows the VTEC solenoid"),
            ("O2 heater fb", "O2 sensor heater feedback: has to follow the heater output, or code 41 sets", null),
            ("service check", "service check connector (D4); logged as 3B0h bit 5", null),
        ]);
        Bits("sw4700", "Switches: 4700h buffer", 0x00, "P28 second switch buffer at 4700h. The ROM stores it XOR 1Ah at RAM 211h.",
        [
            ("start signal", "start signal (B9); logged as 3B0h bit 4", "on while cranking is ticked"),
            ("VTEC pressure", "VTEC oil-pressure switch (D6): low = pressure (code 22)", "low while the solenoid is open and VTEC oil pressure is ticked"),
            ("A/C", "A/C request (B5); logged as 3B0h bit 2", "the A/C switch box above"),
            ("unused", "not read by any of the ROMs", null),
            ("brake", "brake switch (D2); logged as 3B0h bit 1", null),
            ("park/neutral", "park/neutral input (B7); logged as 3B0h bit 0", null),
            ("A/T shift 1", "A/T shift position input 1 (A/T ROMs read it in the timing task)", null),
            ("A/T shift 2", "A/T shift position input 2", null),
        ]);
    }
    MilWindow? _milWindow;
    void OpenMil()
    {
        if (_milWindow != null) { _milWindow.Activate(); return; }
        // the service check jumper is port A bit 7: set it through the panel's own box so both agree
        _milWindow = new MilWindow(_host, on => { if (_bitRows.TryGetValue("porta", out var r)) r.Bits[7].IsChecked = on; });
        _milWindow.Closed += (_, _) => _milWindow = null;
        _milWindow.Show(this);
    }

    readonly Dictionary<string, (CheckBox Box, bool Default)> _boxes = [];
    readonly Dictionary<string, (CheckBox[] Bits, byte Default)> _bitRows = [];
    readonly Dictionary<string, Slider> _sliders = [];
    readonly Dictionary<string, double> _defaults = [];
    bool _syncingSliders;

    void ResetInputs()
    {
        foreach (var (k, v) in _defaults)
            if (_sliders.TryGetValue(k, out var sl)) { sl.Value = v; _host.SetInput(k, v); }
        foreach (var (b, on) in _boxes.Values) b.IsChecked = on;
        foreach (var (bits, v) in _bitRows.Values)
            for (int i = 0; i < 8; i++) bits[i].IsChecked = (v & (1 << i)) != 0;
        SetStatus("engine inputs back to their defaults");
    }

    /// Move the sliders to the inputs the simulator has (a datalog may be driving them).
    void SyncSliders()
    {
        var inputs = _host.Inputs();
        _syncingSliders = true;
        try
        {
            foreach (var (k, sl) in _sliders)
                if (inputs.TryGetValue(k, out var v) && Math.Abs(sl.Value - v) > 1e-6 && !sl.IsPointerOver)
                    sl.Value = Math.Clamp(v, sl.Minimum, sl.Maximum);
        }
        finally { _syncingSliders = false; }
    }

    // ------------------------------------------------------------------ files

    async void NewRom()
    {
        var w = new NewRomWindow();
        await w.ShowDialog(this);
        if (w.Created is { } path && await ConfirmReplaceCurrent(path)) OpenFile(path);
    }

    async void OpenFileDialog()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            AllowMultiple = false,
            Title = "Open ROM source, image or project",
            FileTypeFilter = new[]
            {
                new FilePickerFileType("ROM source, image or project") { Patterns = new[] { "*.asm", "*.bin", "*.rom", "*.zip" } },
                new FilePickerFileType("Assembler source") { Patterns = new[] { "*.asm", "*.inc" } },
                new FilePickerFileType("ROM image") { Patterns = new[] { "*.bin", "*.rom" } },
                new FilePickerFileType("OkiRomSim project") { Patterns = new[] { "*.zip" } },
                new FilePickerFileType("All files") { Patterns = new[] { "*" } },
            },
        });
        var f = files.FirstOrDefault()?.TryGetLocalPath();
        if (f != null && await ConfirmReplaceCurrent(f)) OpenFile(f);
    }

    /// Would opening `path` replace what is loaded (rather than just show another source file of the same build)?
    bool ReplacesCurrentRom(string path)
    {
        if (_current == null && _target == null) return false;
        if (path.EndsWith(".bin", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".rom", StringComparison.OrdinalIgnoreCase)
            || path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) return true;
        return !path.EndsWith(".asm", StringComparison.OrdinalIgnoreCase)
            ? false
            : !SamePath(path, _target) && !(_host.Assembly?.SourceMap.Any(e => SamePath(e.File, path)) ?? false);
    }

    /// Before replacing what is open: offer to save the source files edited on screen and any calibration changes made to the ROM. False means the user chose to stay where they are.
    async Task<bool> ConfirmReplaceCurrent(string incoming)
    {
        if (!ReplacesCurrentRom(incoming)) return true;
        var dirtyFiles = _dirty.Where(f => _buffers.ContainsKey(f)).ToList();
        bool cal = _host.RomDirty;
        if (dirtyFiles.Count == 0 && !cal) return true;

        var what = new List<string>();
        if (dirtyFiles.Count > 0) what.Add(dirtyFiles.Count == 1 ? Label(dirtyFiles[0]) + " has unsaved edits" : $"{dirtyFiles.Count} source files have unsaved edits");
        if (cal) what.Add("the ROM has calibration changes that are not in a file yet");
        var answer = await Dialogs.Ask(this, "Save your changes?",
            $"Opening {Label(incoming)} will replace what is open, and {string.Join(", and ", what)}.\n\n" +
            "Save first, discard the changes, or stay with the file you have open?",
            "Save", "Discard", "Cancel");
        if (answer != "Save" && answer != "Discard") return false;
        if (answer == "Discard") return true;

        if (_current != null && _dirty.Contains(_current)) SaveCurrent();
        foreach (var f in dirtyFiles)
        {
            if (_current != null && SamePath(f, _current)) continue;
            try { File.WriteAllText(f, _buffers[f]); _dirty.Remove(f); }
            catch (Exception ex) { SetStatus($"could not save {Label(f)}: {ex.Message}"); AppLog.Error("app", "save before open failed", ex); return false; }
        }
        if (cal)
        {
            var saved = await _calibration.SaveRomAsync();
            if (!saved) return false;              // the save dialog was cancelled: stay put
        }
        UpdateDocHeader();
        return true;
    }

    /// Open a file, asking about unsaved work first when it would replace what is loaded.
    public async void OpenFileAsked(string path)
    {
        if (await ConfirmReplaceCurrent(path)) OpenFile(path);
    }

    /// Open a .asm (edit and build it), a .bin/.rom (disassemble it to source, then build that, so the simulator runs exactly the image's bytes with labels and line tracking), or a saved project .zip. Open a file: a ROM with an open password set (the watermark module) asks for it first.
    void OpenFile(string path) => _ = OpenFileChecked(path);

    async Task OpenFileChecked(string path)
    {
        try
        {
            if (!await PasswordAllows(path)) { SetStatus($"{Label(path)} was not opened: it is protected with a password"); return; }
        }
        catch (Exception ex)
        {
            // could not tell whether it has a password: it stays closed rather than opening without asking
            AppLog.Error("app", "password check failed", ex);
            SetStatus($"{Label(path)} was not opened: could not check its password ({ex.Message})");
            return;
        }
        OpenFileNow(path);
    }

    /// The ROM image a file would open (a .bin, a project's ROM, or a main source assembled quietly) and, when that has a password set, whether it was given.
    async Task<bool> PasswordAllows(string path)
    {
        byte[]? image = null;
        if (path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) image = ProjectFile.Load(path).Rom;
        else if (path.EndsWith(".bin", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".rom", StringComparison.OrdinalIgnoreCase)) image = File.ReadAllBytes(path);
        else if (path.EndsWith(".asm", StringComparison.OrdinalIgnoreCase) && !SamePath(path, _target)
                 && !(_host.Assembly?.SourceMap.Any(e => SamePath(e.File, path)) ?? false))
        {
            var p = path;
            var snapshot = _buffers.ToDictionary(kv => Path.GetFullPath(kv.Key), kv => kv.Value, StringComparer.OrdinalIgnoreCase);
            image = await Task.Run(() =>
            {
                try { var r = new OkiAssembler(new AssemblerOptions { ReadFile = f => snapshot.GetValueOrDefault(f) }).AssembleFile(p); return r.Image; }
                catch { return null; }
            });
        }
        return image == null || image.Length == 0 || await RomPasswordUi.Unlock(this, image, Label(path));
    }

    /// File > Recent: the last ten files opened, newest first (those no longer there are left out).
    Toolbar.Entry[] RecentEntries()
    {
        var list = _settings.RecentFiles.Where(File.Exists).Take(10).ToList();
        if (list.Count == 0) return [new Toolbar.Entry("", "(nothing yet)", "Files you open appear here.", () => { })];
        return [.. list.Select((p, i) => new Toolbar.Entry(i < 9 ? $"{i + 1}" : "0", Path.GetFileName(p), p, () => OpenFile(p))),
                Toolbar.Entry.Line,
                new Toolbar.Entry(Toolbar.Clear, "Clear the list", "Forget the files opened lately.", () => { _settings.RecentFiles.Clear(); _settings.Save(); })];
    }

    void RememberRecent(string path)
    {
        try
        {
            var full = Path.GetFullPath(path);
            _settings.RecentFiles.RemoveAll(p => SamePath(p, full));
            _settings.RecentFiles.Insert(0, full);
            if (_settings.RecentFiles.Count > 10) _settings.RecentFiles.RemoveRange(10, _settings.RecentFiles.Count - 10);
            _settings.Save();
        }
        catch { }
    }

    void OpenFileNow(string path)
    {
        RememberRecent(path);
        try
        {
            if (path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) { OpenProject(path); return; }
            if (path.EndsWith(".bin", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".rom", StringComparison.OrdinalIgnoreCase))
            {
                OpenBinary(path);
                return;
            }
            if (!_buffers.ContainsKey(path)) _buffers[path] = File.ReadAllText(path);
            bool isMain = path.EndsWith(".asm", StringComparison.OrdinalIgnoreCase) && !SamePath(path, _target)
                          && !(_host.Assembly?.SourceMap.Any(e => SamePath(e.File, path)) ?? false);
            if (isMain) ResetForNewRom(path);
            ShowBuffer(path);
            if (isMain)
            {
                // a source that says which part it is for ("; processor: MSM66911") gets that part, or its SFR names would resolve against whatever profile happened to be active
                if (ProcessorProfile.Declared(_buffers[path]) is { } declared && !declared.Name.Equals(_profile.Name, StringComparison.OrdinalIgnoreCase))
                    ApplyProfile(declared);
                _target = path;
                Build();
                _ = AfterOpen(path);
            }
        }
        catch (Exception ex) { SetStatus(ex.Message); }
    }

    readonly HashSet<string> _skeletonUpdateDeclined = new(StringComparer.OrdinalIgnoreCase);

    /// A ROM made by New ROM > Create keeps its name and version and its watermark (with the password) in its build file, so they survive saving the source and building it again: written there as soon as they are changed. The build file is saved at once when it had nothing else unsaved; otherwise it is left marked as changed.
    void KeepInBuildFile(ItemDef item)
    {
        try
        {
            if (_target == null || item.Text is not ("watermark" or "password")) return;
            var text = ReadBuffer(Path.GetFullPath(_target)) ?? (File.Exists(_target) ? File.ReadAllText(_target) : null);
            if (text == null || !text.Contains("by File > New ROM > Create")) return;
            var defs = _host.Defs();
            byte[]? id = null, wm = null;
            if (defs.Items.FirstOrDefault(i => i.Text == "watermark") is { } w && defs.Items.Any(i => i.Text == "password" && i.Address == w.Address + WatermarkCodec.Bytes))
                wm = _host.RomBytes(w.Address, WatermarkCodec.Bytes + RomPassword.Bytes);
            if (id == null && wm == null) return;
            var updated = Skeleton.WithKept(text, id, defs.Items.FirstOrDefault(i => i.Name == "RomId")?.Address ?? 0x7FE0, wm);
            if (updated == text) return;
            var key = _buffers.Keys.FirstOrDefault(k => SamePath(k, _target)) ?? _target;
            bool clean = !_dirty.Any(d => SamePath(d, _target));
            _buffers[key] = updated;
            if (_current != null && SamePath(_current, _target) && !_editorParked) { _suppressEdit = true; _editor.Text = updated; _suppressEdit = false; }
            if (clean) File.WriteAllText(_target, updated);
            else _dirty.Add(key);
            // the image already holds these bytes: the build is still the source's
            _builtTexts[Path.GetFullPath(_target)] = updated;
            UpdateDocHeader();
            AppLog.Action("app", $"{Label(_target)}: {(id != null ? "name and version" : "watermark")} kept in the build file{(clean ? "" : " (unsaved)")}");
        }
        catch (Exception ex) { AppLog.Error("app", "could not keep the value in the build file", ex); }
    }

    /// A ROM just created or opened: bring its skeleton up to date if there is a newer one, then offer to run Detect on it.
    async Task AfterOpen(string path)
    {
        _plugins?.RaiseRomLoaded(path);
        await OfferSkeletonUpdate(path);
        await OfferDetect(path);
    }

    async Task OfferDetect(string path)
    {
        try
        {
            if (!_settings.AskDetectOnOpen || _host.Assembly == null || _host.LoadedPath is not { } loaded || !SamePath(loaded, path)) return;
            var defs = _host.Defs();
            int items = defs.Items.Count, onPages = CalPage.All().SelectMany(p => p.Slots()).Count(s => CalPage.Bound(defs, s) != null);
            string what = items == 0
                ? "It has no definitions yet: the calibration list and the feature pages are empty until Detect has found its tables and settings."
                : $"It has {items} definition(s) from its source already ({onPages} page row(s) filled in). Detect looks for the tables and settings the source does not describe.";
            var pick = await Dialogs.Ask(this, "Run Detect?",
                $"{Label(path)} is open. Run Detect on it?\n\n{what}\n\nIt lines the ROM up with the known ROMs and follows the code that reads each table; it takes a few seconds. " +
                "It can be run again at any time from the calibration editor's Detect button.",
                "Run Detect", "Not now", "Don't ask again");
            if (pick == "Don't ask again") { _settings.AskDetectOnOpen = false; _settings.Save(); SetStatus("Detect will not be offered again (Settings > General turns it back on)"); return; }
            if (pick != "Run Detect") return;
            SelectTab("Calibration");
            await _calibration.DetectAsync();
        }
        catch (Exception ex) { AppLog.Error("app", "detect offer failed", ex); }
    }

    /// A ROM made by New ROM > Create builds on its own copy of the skeleton and modules. When the app has a newer skeleton (fixes, new modules, better table names), offer to bring that copy up to date. The old copy is kept in a backup folder; the ROM's choice of functions (its define lines) is not touched.
    async Task OfferSkeletonUpdate(string path)
    {
        try
        {
            var text = _buffers.TryGetValue(path, out var t) ? t : File.ReadAllText(path);
            if (!text.Contains("by File > New ROM > Create")) return;
            var m = System.Text.RegularExpressions.Regex.Match(text, @"^\s*include\s+""([^""]+)""", System.Text.RegularExpressions.RegexOptions.Multiline);
            if (!m.Success) return;
            var local = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(path)!, m.Groups[1].Value));
            if (!File.Exists(local) || _skeletonUpdateDeclined.Contains(local)) return;
            var app = Skeleton.Find(NewRomWindow.Templates()).FirstOrDefault(k => Path.GetFileName(k.Path).Equals(Path.GetFileName(local), StringComparison.OrdinalIgnoreCase));
            if (app == null || Path.GetFullPath(app.Path).Equals(local, StringComparison.OrdinalIgnoreCase)) return;
            var localFeatures = app.FeaturesDir == null ? null : Path.Combine(Path.GetDirectoryName(local)!, Path.GetFileName(app.FeaturesDir));
            bool Same(string a, string b) => File.Exists(a) && File.Exists(b) && File.ReadAllBytes(a).AsSpan().SequenceEqual(File.ReadAllBytes(b));
            bool differs = !Same(app.Path, local) || (app.FeaturesDir != null && localFeatures != null &&
                Directory.GetFiles(app.FeaturesDir).Any(f => !Same(f, Path.Combine(localFeatures, Path.GetFileName(f)))));
            if (!differs) return;
            bool yes = await Dialogs.Confirm(this, "Update the skeleton?",
                $"{Path.GetFileName(path)} was made from an older copy of {Path.GetFileName(local)} and its modules. The app has a newer one " +
                "(fixes, new functions, readable table names).\n\nUpdate this ROM's copy? The functions it uses (its define lines) stay as they are. " +
                "The old copy goes to a backup folder beside it. Tuning saved to a .bin is not affected; values typed into the skeleton's own " +
                "source by hand would be in the backup.", "Update", "Not now");
            if (!yes) { _skeletonUpdateDeclined.Add(local); return; }
            var dir = Path.GetDirectoryName(local)!;
            var backup = Path.Combine(dir, $"skeleton-backup-{DateTime.Now:yyyyMMdd-HHmmss}");
            Directory.CreateDirectory(backup);
            File.Copy(local, Path.Combine(backup, Path.GetFileName(local)));
            if (localFeatures != null && Directory.Exists(localFeatures))
            {
                var bf = Path.Combine(backup, Path.GetFileName(localFeatures));
                Directory.CreateDirectory(bf);
                foreach (var f in Directory.GetFiles(localFeatures)) File.Copy(f, Path.Combine(bf, Path.GetFileName(f)));
            }
            File.Copy(app.Path, local, overwrite: true);
            if (app.FeaturesDir != null && localFeatures != null)
            {
                Directory.CreateDirectory(localFeatures);
                foreach (var f in Directory.GetFiles(app.FeaturesDir)) File.Copy(f, Path.Combine(localFeatures, Path.GetFileName(f)), overwrite: true);
            }
            foreach (var k in _buffers.Keys.Where(k => k.StartsWith(dir, StringComparison.OrdinalIgnoreCase) && !SamePath(k, path)).ToList()) _buffers.Remove(k);
            AppLog.Action("new rom", $"skeleton of {path} updated (backup in {backup})");
            SetStatus($"skeleton updated - the old copy is in {Path.GetFileName(backup)}");
            Build();
        }
        catch (Exception ex) { AppLog.Error("new rom", "skeleton update failed", ex); SetStatus("skeleton update failed: " + ex.Message); }
    }

    /// A ROM image that came from somewhere other than a file the user picked (the PROG entry of an .rlog, or an MCP client uploading one): keep it beside the log / in the temp folder and open it like any other .bin.
    public void OpenRomImage(byte[] rom, string name)
    {
        try
        {
            var dir = Path.Combine(Path.GetTempPath(), "OkiRomSim");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, Path.GetFileNameWithoutExtension(name) + ".bin");
            File.WriteAllBytes(path, rom);
            OpenFile(path);
            SetStatus($"opened the ROM carried in the log ({rom.Length} bytes) as {path}", sticky: true);
        }
        catch (Exception ex) { SetStatus("could not open the ROM from the log: " + ex.Message); AppLog.Error("app", "ROM from log failed", ex); }
    }

    async void OpenBinary(string path)
    {
        var bytes = File.ReadAllBytes(path);
        // a 64 KB (512) chip image holds two ROMs: open the half the ECU would run
        if (bytes.Length == Bus.RomSize * 2)
        {
            bool lowBlank = bytes[..Bus.RomSize].All(b => b == 0xFF) || bytes[..Bus.RomSize].All(b => b == 0);
            var pick = lowBlank ? "Upper half" : await Dialogs.Ask(this, "64 KB image",
                $"{Label(path)} is a 64 KB (512) chip image: two 32 KB ROMs, 0000-7FFF and 8000-FFFF. A board with the top address line tied high runs the upper half. Which one?",
                "Cancel", "Lower half", "Upper half");
            if (pick is null or "Cancel") return;
            bool upper = pick == "Upper half";
            bytes = upper ? bytes[Bus.RomSize..] : bytes[..Bus.RomSize];
            var half = Path.Combine(Path.GetDirectoryName(path)!, Path.GetFileNameWithoutExtension(path) + (upper ? "_high" : "_low") + ".bin");
            File.WriteAllBytes(half, bytes);
            SetStatus($"{Label(path)}: the {(upper ? "upper" : "lower")} half, saved as {Path.GetFileName(half)} and opened" + (lowBlank ? " (the lower half is blank)" : ""));
            path = half;
        }
        ResetForNewRom(path);
        if (bytes.Length == Bus.RomSize + 1 && bytes[^1] == 0) bytes = bytes[..Bus.RomSize];
        if (bytes.Length > Bus.RomSize)
        { SetStatus($"{Label(path)} is {bytes.Length} bytes; a 66207 ROM image is at most {Bus.RomSize}"); return; }
        string note = bytes.Length < Bus.RomSize ? $" (short image, padded from {bytes.Length} bytes with FF)" : "";

        var asmPath = Path.ChangeExtension(path, ".asm");
        if (File.Exists(asmPath)) asmPath = Path.ChangeExtension(path, ".disasm.asm");
        SetStatus("disassembling…");
        DefinitionSet? saved = null;
        var sidecar = DefinitionsFileFor(path);
        if (File.Exists(sidecar))
            try { saved = DefinitionSet.Load(sidecar); }
            catch (Exception ex) { AppLog.Error("app", "definitions file unreadable", ex); SetStatus($"{Path.GetFileName(sidecar)} could not be read: {ex.Message}"); }
        Dictionary<int, string>? names = null;
        if (saved != null)
        {
            names = [];
            foreach (var (n, a) in saved.Labels ?? []) names.TryAdd(a, n);
            foreach (var it in saved.Items) names.TryAdd(it.Address, it.Name);
        }
        var dis = BinDisassembler.Disassemble(bytes, Path.GetFileName(path), text =>
        {
            var r = new OkiAssembler(new AssemblerOptions { ReadFile = f => f == Path.GetFullPath(asmPath) ? text : null })
                .AssembleText(text, asmPath);
            return (r.Success ? r.Image : null, r.Diagnostics.Where(d => d.Severity == Severity.Error).Select(d => d.Line));
        }, names);
        _buffers[asmPath] = dis.Text;
        _dirty.Add(asmPath);
        _target = asmPath;
        ShowBuffer(asmPath);
        Build();
        if (saved != null)
        {
            _host.ReplaceDefinitions(saved);
            _calibration.Refresh();
            SetStatus($"{Label(path)}: names, tables and page bindings put back from {Path.GetFileName(sidecar)} ({saved.Items.Count} definitions)", sticky: true);
            return;
        }
        string opened;
        if (HtsLayout.Describe(bytes) is { Length: > 0 } kind) { opened = $"{Label(path)} is {kind}"; AppLog.Info("app", opened); }
        else opened = $"{Label(path)}: {dis.CodeInstructions:N0} instructions found by following the code, " +
                      $"{dis.DataBytes:N0} bytes kept as data" +
                      (dis.RoundTrips ? "; rebuilds byte-identical" : " -- " + dis.Note) + note +
                      $". Unsaved: Ctrl+S writes {Label(asmPath)}";
        SetStatus(opened, sticky: true);
        // no definitions file beside it: its maps are found now, the way Detect finds them - a .bin read out of the
        // emulator or off a chip opens with its tables, not with an empty list that looks as if nothing came back
        if (_host.Assembly != null && _host.Defs().Items.Count == 0) _ = DetectOnOpen(opened);
    }

    async Task DetectOnOpen(string opened)
    {
        await _calibration.DetectAsync();
        int n = _host.Defs().Items.Count;
        SetStatus(n > 0 ? $"{opened}  -  Detect found {n} maps and settings (Calibration page)" : opened + "  -  Detect found no maps in it", sticky: true);
    }

    /// The .bin Download read out of the emulator: opening it keeps the emulator and the datalog connected.
    string? _keepLinksFor;

    async void OpenDownloaded(string path)
    {
        if (!await ConfirmReplaceCurrent(path)) { SetStatus($"the emulator's ROM is saved as {path}; open it from File when you are ready"); return; }
        _keepLinksFor = path;
        OpenFile(path);
    }

    /// Opening another ROM: forget the one before it (definitions, undo, hits, traces, its source buffers), so Detect and the Calibration page cannot mix the two.
    void ResetForNewRom(string path)
    {
        var keep = Path.GetFullPath(path);
        foreach (var k in _buffers.Keys.ToList())
            if (!SamePath(k, keep) && !_dirty.Contains(k)) _buffers.Remove(k);
        _diags.Clear();
        _problemLoc.Clear();
        _problems.SetRows([]); _problemSummary.Text = "not built yet"; _problemSummary.Foreground = DataList.Text;
        _builtTexts = [];
        _builtImage = null;
        _lookupRows = []; _lookupLines = [];
        SetItems(_lookupList, []); _lookupData.SetRows([]);
        _lastSourceShown = ""; _lastPcShown = -1;
        // the emulator and the datalog belong to the ROM that was open: a different project starts with both disconnected -
        // except the ROM just read out of the emulator, which is the one the car is running
        _datalog.StopPlayback();
        if (_keepLinksFor != null && SamePath(_keepLinksFor, path)) _keepLinksFor = null;
        else
        {
            bool linked = _host.Emulator.Connected || _datalog.Engine.Running || _datalog.Engine.Watch.Wanted;
            _calibration.DisconnectEmulator();
            if (_datalog.Engine.Running || _datalog.Engine.Watch.Wanted) _datalog.Stop();
            if (linked) SetStatus("another ROM: the emulator and the datalog were disconnected");
        }
        _host.ResetRomState();
        _calibration.ResetForNewRom();
        _trace.Text = ""; _traceList.SetRows([]); _traceShown = -1;
        AppLog.Action("app", "opening " + Path.GetFileName(path) + ": previous ROM state cleared");
    }

    /// Close everything and sit idle in as little memory as possible.
    void ClearProject()
    {
        _host.Clear();
        _buffers.Clear();
        _dirty.Clear();
        _current = null; _target = null;
        _diags.Clear(); _problemLoc.Clear();
        _problems.SetRows([]); _problemSummary.Text = "not built yet"; _problemSummary.Foreground = DataList.Text;
        _lookupRows = []; _lookupLines = [];
        SetItems(_lookupList, []); _lookupData.SetRows([]);
        _disList.SetRows([]);
        _bpList.SetRows([]);
        _problemSummary.Text = "not built yet"; _problemSummary.Foreground = DataList.Text;
        _builtTexts = []; _builtImage = null;
        _suppressEdit = true;
        _editor.Text = "";
        _editorParked = false;
        _suppressEdit = false;
        _editor.SetDiagnostics(new List<(int, bool)>());
        _editor.SetHits(null);
        _trace.Text = ""; _traceList.SetRows([]); _traceShown = -1; _memory.Text = "";
        _calibration.ResetForNewRom();
        _datalog.ClearAll();
        _settings.LastFile = null;
        UpdateDocHeader();
        UpdateBuildButton(false, "Nothing to build yet: open a .asm or .bin.");
        SetStatus("project cleared: no ROM open, memory released");
    }

    void ShowBuffer(string path)
    {
        if (_current != null && _buffers.ContainsKey(_current)) _buffers[_current] = EditorText;
        _current = path;
        _editorParked = false;
        _suppressEdit = true;
        _editor.Text = _buffers[path];
        _suppressEdit = false;
        _editor.SetReadOnly(false);
        _editor.SetDiagnostics(_diags.Where(d => SamePath(d.File, _current)).Select(d => (d.Line, d.Severity == Severity.Error)).ToList());
        UpdateDocHeader();
    }
    bool _suppressEdit;

    static bool SamePath(string? a, string? b)
    {
        if (a == null || b == null) return false;
        try { return string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }

    /// Open (or switch to) a file and put the caret on a line; `select` highlights the line.
    void ShowSourceLine(string file, int line, bool select = true)
    {
        string? key = _buffers.Keys.FirstOrDefault(k => SamePath(k, file)) ?? (File.Exists(file) ? file : null);
        if (key == null) return;
        if (!SamePath(_current, key)) OpenFile(key);
        if (select) _editor.HighlightLine(line); else _editor.GoToLine(line);
    }

    /// Show an address in the source (and the disassembly).
    void GoToAddress(int addr)
    {
        _disAddr.Text = Hex(addr);
        RefreshDisassembly(true);
        if (_host.Assembly?.Lookup(addr) is { } src)
        {
            ShowSourceLine(src.File, src.Line);
            SetStatus($"{Hex(addr)} is {Label(src.File)} line {src.Line}");
        }
        else SetStatus($"{Hex(addr)} has no source line (data, or not in the assembled file); shown in the disassembly");
    }

    void OnEditorChanged()
    {
        if (_suppressEdit || _current == null) return;
        _buffers[_current] = EditorText;
        _dirty.Add(_current);
        UpdateDocHeader();
        _checkTimer.Stop();
        _checkTimer.Start();
    }

    void UpdateDocHeader()
    {
        if (_current == null)
        {
            _docHeader.Text = "No file open. Open a .asm source, a .bin ROM image or a project .zip (Ctrl+O).";
            Title = $"OkiRomSim Studio {BuildInfo.Version}";
            return;
        }
        bool dirty = _dirty.Contains(_current);
        bool onDisk = File.Exists(_current);
        _docHeader.Text = $"{_current}{(dirty ? "   ● unsaved" : "")}{(onDisk ? "" : "   (not on disk yet)")}" +
                          (_target != null && !SamePath(_target, _current) ? $"   ·   builds {Label(_target)}" : "");
        ToolTip.SetTip(_docHeader, dirty ? "The text on screen differs from the file on disk (Ctrl+S saves it)." : "Matches the file on disk.");
        Title = $"OkiRomSim Studio {BuildInfo.Version} — {Label(_current)}{(dirty ? " ●" : "")}";
    }

    void SaveCurrent()
    {
        if (_current == null) return;
        _buffers[_current] = EditorText;
        File.WriteAllText(_current, _buffers[_current]);
        _dirty.Remove(_current);
        UpdateDocHeader();
        SetStatus($"saved {_current}");
    }

    async void SaveAs()
    {
        if (_current == null) return;
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Save source as",
            SuggestedFileName = Label(_current),
            DefaultExtension = "asm",
            FileTypeChoices = new[]
            {
                new FilePickerFileType("Assembler source") { Patterns = new[] { "*.asm" } },
                new FilePickerFileType("ROM image, assembled from the source (32 KB)") { Patterns = new[] { "*.bin" } },
            },
        });
        var path = file?.TryGetLocalPath();
        if (path == null) return;
        if (path.EndsWith(".bin", StringComparison.OrdinalIgnoreCase)) { SaveAssembledBin(path); return; }
        var text = EditorText;
        _buffers.Remove(_current);
        _dirty.Remove(_current);
        if (SamePath(_target, _current)) _target = path;
        _current = path;
        _buffers[path] = text;
        File.WriteAllText(path, text);
        UpdateDocHeader();
        SetStatus($"saved {path} (build to point breakpoints and line tracking at the new file)");
        CheckBuildNeeded();
    }

    /// Save As .bin: the ROM image of the source. When the image running now was built from the source as it is on screen, that image is saved (with every calibration change made since, the checksum kept right); otherwise the source is assembled as it is on screen, unsaved changes and all.
    async void SaveAssembledBin(string path)
    {
        if (_current != null) _buffers[_current] = EditorText;
        var target = _target ?? _current;
        if (target == null) return;
        bool upToDate = _builtImage != null && _builtTexts.All(kv => (ReadBuffer(kv.Key) ?? kv.Value) == kv.Value)
                        && _host.LoadedPath is { } lp && SamePath(lp, target);
        try
        {
            if (upToDate)
            {
                _host.SaveRom(path);
                SetStatus($"saved {path}: the ROM running now, built from {Label(target)}, with the calibration changes made since");
                await OfferDefinitionsFile(path, _host.Defs(), _host.Assembly);
                return;
            }
            var r = new OkiAssembler(new AssemblerOptions { ReadFile = ReadBuffer }).AssembleFile(target);
            if (!r.Success)
            {
                var first = r.Diagnostics.FirstOrDefault(d => d.Severity == Severity.Error);
                SetStatus($"not saved: {Label(target)} does not assemble ({first?.Message})");
                return;
            }
            if (File.Exists(path)) File.Copy(path, path + ".bak", overwrite: true);
            File.WriteAllBytes(path, r.Image);
            SetStatus($"saved {path}: {Label(target)} assembled ({r.UsedBytes:N0} bytes used)");
            await OfferDefinitionsFile(path, DefinitionBuilder.FromAssembly(r, Path.GetFileName(path)), r);
        }
        catch (Exception ex) { SetStatus("could not save the image: " + ex.Message); }
    }

    /// The definitions file that goes with a .bin: name.okidef.json beside it.
    static string DefinitionsFileFor(string bin) => Path.ChangeExtension(bin, null) + ".okidef.json";

    /// A .bin was saved: offer the definitions file that keeps its names. A .bin is only bytes, and opened again it comes back as loc_1234 and unnamed tables; with the definitions file beside it, every label, table, scaling and page binding comes back with it.
    public async Task OfferDefinitionsFile(string bin, DefinitionSet defs, AssemblyResult? asm)
    {
        try
        {
            var file = DefinitionsFileFor(bin);
            var pick = await Dialogs.Ask(this, "Save a definitions file too?",
                $"{Path.GetFileName(bin)} is saved. Also save {Path.GetFileName(file)} beside it?\n\n" +
                "A .bin holds only the bytes. Opened again on its own, every label is gone - the code comes back as loc_1234 and sub_5678, the tables " +
                "and settings have no names, scaling or page bindings, and Detect has to guess them again.\n\n" +
                $"The definitions file keeps all of that ({defs.Items.Count} definitions, {defs.Symbols.Count} labels). Keep it next to the .bin with the " +
                "same name, and opening the .bin puts everything back.",
                "Save definitions too", "Just the .bin");
            if (pick != "Save definitions too") return;
            if (File.Exists(file)) File.Copy(file, file + ".bak", overwrite: true);
            if (asm != null)
                defs.Labels = asm.Symbols.Values.Where(x => x.Kind == SymbolKind.Label && x.Value >= 0 && x.Value < asm.Image.Length)
                                 .GroupBy(x => x.Name).ToDictionary(g => g.Key, g => (int)g.First().Value);
            defs.Save(file);
            SetStatus($"saved {Path.GetFileName(bin)} and {Path.GetFileName(file)} - open the .bin to get every name back");
            AppLog.Action("app", "definitions saved to " + file);
        }
        catch (Exception ex) { SetStatus("could not save the definitions file: " + ex.Message); AppLog.Error("app", "definitions file failed", ex); }
    }

    // ------------------------------------------------------------------ build

    string? ReadBuffer(string fullPath) => _buffers.FirstOrDefault(kv => SamePath(kv.Key, fullPath)).Value;

    void Build()
    {
        if (_current != null) _buffers[_current] = EditorText;
        UpdateDocHeader();
        var target = _target ?? _current;
        if (target == null || !target.EndsWith(".asm", StringComparison.OrdinalIgnoreCase))
        { SetStatus("open a .asm (or a .bin) to build"); return; }

        SetStatus("building…");
        var res = _host.Build(target, ReadBuffer);
        _diags = res.Diagnostics;
        var ordered = _diags.OrderByDescending(d => d.Severity).ToList();
        ShowProblems(ordered);
        if (res.Success && res.Assembly != null)
        {
            // remember exactly what was built, to tell later whether the screen differs
            var files = res.Assembly.SourceMap.Select(e => e.File).Append(Path.GetFullPath(target)).Distinct(StringComparer.OrdinalIgnoreCase);
            _builtTexts = files.ToDictionary(f => f, f => ReadBuffer(f) ?? (File.Exists(f) ? File.ReadAllText(f) : ""), StringComparer.OrdinalIgnoreCase);
            _builtImage = [.. res.Assembly.Image];
            UpdateBuildButton(false, "Up to date: the loaded image was built from the source on screen.");
            SetStatus($"build ok: {res.Assembly.UsedBytes} / {res.Assembly.Image.Length} bytes " +
                      $"({100.0 * res.Assembly.UsedBytes / res.Assembly.Image.Length:F1}%), " +
                      $"{_diags.Count(d => d.Severity == Severity.Warning)} warnings, {res.Milliseconds} ms", sticky: true);
        }
        else
        {
            UpdateBuildButton(true, "The last build failed; fix the highlighted lines and build again.");
            SelectTab("Problems");
            var first = _diags.FirstOrDefault(d => d.Severity == Severity.Error);
            if (first != null) ShowSourceLine(first.File, first.Line);
            SetStatus($"build failed: {_diags.Count(d => d.Severity == Severity.Error)} error(s) - " +
                      (first != null ? $"first at {Label(first.File)}:{first.Line}: {first.Message}" : "see Problems"), sticky: true);
        }
        _editor.SetDiagnostics(_diags.Where(d => SamePath(d.File, _current)).Select(d => (d.Line, d.Severity == Severity.Error)).ToList());
        if (SelectedTab() == "Calibration") _calibration.Refresh();
        _lastSourceShown = "";
        RefreshDisassembly(true);
    }

    /// Build and patch the running ROM with what changed (SimHost.PatchBuild): code and tables take effect without a reset.
    async void PatchLive(bool force)
    {
        if (_current != null) _buffers[_current] = EditorText;
        var target = _target ?? _current;
        if (target == null || !target.EndsWith(".asm", StringComparison.OrdinalIgnoreCase)) { SetStatus("open a .asm to patch from"); return; }
        SetStatus("assembling to patch live…");
        var res = await Task.Run(() => _host.PatchBuild(target, ReadBuffer, force));
        _diags = res.Diagnostics;
        var ordered = _diags.OrderByDescending(d => d.Severity).ToList();
        ShowProblems(ordered);
        if (res.RunningInside && !res.Success)
        {
            var pick = await Dialogs.Ask(this, "Patch the code it is running?",
                $"The program is running inside code that changes ({res.Note}). Patched under it, it may carry on from the middle of an " +
                "instruction or return into moved code. Patch it anyway, or reset after patching (the simulator starts again from power-up, the " +
                "new code throughout)?", "Cancel", "Patch anyway", "Patch and reset");
            if (pick is null or "Cancel") { SetStatus("not patched"); return; }
            res = await Task.Run(() => _host.PatchBuild(target, ReadBuffer, true));
            if (res.Success && pick == "Patch and reset") _host.Control("reset");
        }
        if (!res.Success)
        {
            SetStatus("not patched: " + res.Note, sticky: true);
            if (res.Diagnostics.Any(d => d.Severity == Severity.Error)) SelectTab("Problems");
            return;
        }
        var files = res.Assembly!.SourceMap.Select(e => e.File).Append(Path.GetFullPath(target)).Distinct(StringComparer.OrdinalIgnoreCase);
        _builtTexts = files.ToDictionary(f => f, f => ReadBuffer(f) ?? (File.Exists(f) ? File.ReadAllText(f) : ""), StringComparer.OrdinalIgnoreCase);
        _builtImage = [.. res.Assembly.Image];
        UpdateBuildButton(false, "Up to date: the running ROM was patched from the source on screen.");
        AppLog.Action("build", "patch live: " + res.Note + string.Concat(res.Ranges.Take(12).Select(r => $"\n  {r.Start:X4}-{r.Start + r.Length - 1:X4} {_host.LabelAt(r.Start)}")));
        SetStatus(res.Note + (_host.Emulator.Connected ? (_host.AutoUpload ? "; the emulator gets the changed blocks" : "; the emulator is not uploading changes (Emulator > Upload on changes)") : ""), sticky: true);
        _editor.SetDiagnostics(_diags.Where(d => SamePath(d.File, _current)).Select(d => (d.Line, d.Severity == Severity.Error)).ToList());
        _calibration.Refresh();
        RefreshDisassembly(true);
    }

    void UpdateBuildButton(bool needed, string why)
    {
        _buildBtn.IsEnabled = needed;
        _buildBtn.Content = Toolbar.Label(Toolbar.Build, needed ? "● Build (Ctrl+B)" : "Build (Ctrl+B)");
        ToolTip.SetTip(_buildBtn, why);
    }

    /// Decide whether Build should be enabled: the text on screen matches what was built -> no; it differs -> assemble it quietly in the background and compare the bytes, so an edit that only touches comments or layout leaves Build disabled, and one that changes the opcodes (or breaks the build) enables it.
    void CheckBuildNeeded()
    {
        if (_target == null) return;
        if (_builtImage != null && _builtTexts.All(kv => (ReadBuffer(kv.Key) ?? kv.Value) == kv.Value))
        {
            UpdateBuildButton(false, "Up to date: the loaded image was built from the source on screen.");
            return;
        }
        int gen = ++_checkGeneration;
        var target = _target;
        var snapshot = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (k, v) in _buffers) snapshot[Path.GetFullPath(k)] = v;
        var built = _builtImage;
        Task.Run(() =>
        {
            bool same = false; int errors = 0;
            List<Diagnostic>? fresh = null;
            try
            {
                var r = new OkiAssembler(new AssemblerOptions { ReadFile = f => snapshot.GetValueOrDefault(f) }).AssembleFile(target);
                same = r.Success && built != null && r.Image.AsSpan().SequenceEqual(built);
                errors = r.Diagnostics.Count(d => d.Severity == Severity.Error);
                fresh = r.Diagnostics;
            }
            catch (Exception ex) { errors = 1; AppLog.Error("build", "background check failed", ex); }
            Dispatcher.UIThread.Post(() =>
            {
                if (gen != _checkGeneration) return;
                if (same) UpdateBuildButton(false, "The source was edited but assembles to exactly the bytes that are loaded (comments or layout only).");
                else UpdateBuildButton(true, errors > 0 ? $"The source on screen has {errors} error(s); Build shows and highlights them."
                                                        : "The source on screen assembles to different bytes from the loaded image.");
                // the Problems list follows the source, not the last build: a fixed error clears
                if (fresh != null)
                {
                    _diags = fresh;
                    var ordered2 = _diags.OrderByDescending(d => d.Severity).ToList();
                    ShowProblems(ordered2);
                    _editor.SetDiagnostics(_diags.Where(d => SamePath(d.File, _current)).Select(d => (d.Line, d.Severity == Severity.Error)).ToList());
                }
            });
        });
    }

    // ------------------------------------------------------------------ project

    async void SaveProject()
    {
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Save project",
            SuggestedFileName = Path.GetFileNameWithoutExtension(_target ?? _current ?? "okirom") + ".project.zip",
            DefaultExtension = "zip",
            FileTypeChoices = new[] { new FilePickerFileType("OkiRomSim project") { Patterns = new[] { "*.zip" } } },
        });
        var path = file?.TryGetLocalPath();
        if (path == null) return;
        try
        {
            ProjectFile.Save(path, BuildProject());
            SetStatus($"project saved: {path}");
        }
        catch (Exception ex) { SetStatus("could not save the project: " + ex.Message); }
    }

    /// Everything a project (or a restore point) holds: the sources on screen, the machine state, the calibration, the processor and the settings this ROM was opened with.
    ProjectData BuildProject()
    {
        {
            if (_current != null) _buffers[_current] = EditorText;
            var (machine, ram, rom) = _host.SaveState();
            var s = _host.State();
            RefreshMemory();
            var p = new ProjectData
            {
                Target = _target, Current = _current, CaretLine = _editor.CaretLine, FirstVisibleLine = _editor.FirstVisibleLine,
                Sources = [.. _buffers.Select(kv => new ProjectSource { Path = kv.Key, Text = kv.Value, Unsaved = _dirty.Contains(kv.Key) })],
                MemoryAddress = _memAddr.Text ?? "", DisassemblyAddress = _disAddr.Text ?? "",
                LookupQuery = _lookupQ.Text ?? "", LookupLines = [.. _lookupLines],
                SelectedTab = SelectedTab(), SpeedIndex = _settings.SpeedIndex,
                Package = _chip.CurrentPackage.ToString(), CrystalMHz = Bus.CrystalMHz,
                Machine = machine, Ram = ram, Rom = rom, Definitions = _host.Defs(),
                ProcessorJson = _profile.ToJson(),
                SettingsJson = System.Text.Json.JsonSerializer.Serialize(_settings.RomScoped(), new System.Text.Json.JsonSerializerOptions { WriteIndented = true }),
                TunerMode = _tuner, CalibrationItem = _calibration.ViewState.Item, CalibrationView = _calibration.ViewState.View,
                HitTrace = _hitView.HitMode,
            };
            // the datalog loaded or recorded, as a CSV (every channel and the raw frames)
            var (frames, logName, logPos) = _datalog.SavedLog();
            if (frames.Count > 0)
            {
                var tmp = Path.Combine(Path.GetTempPath(), $"okirom-project-{Environment.ProcessId}.csv");
                try
                {
                    LogFile.SaveCsv(tmp, frames);
                    p.DatalogCsv = File.ReadAllBytes(tmp);
                    p.DatalogName = logName; p.DatalogPosition = logPos;
                }
                catch (Exception ex) { AppLog.Error("project", "the datalog could not be saved with the project", ex); }
                finally { try { File.Delete(tmp); } catch { } }
            }
            p.Views["trace.txt"] = string.Join("\n", s.Trace.Select(t => $"{Hex(t.Pc)}  {t.Label,-22} {t.Text}"));
            p.Views["memory.txt"] = _memory.Text ?? "";
            p.Views["lookup.txt"] = string.Join("\n", _lookupLines);
            p.Views["breakpoints.txt"] = string.Join("\n", s.Breakpoints.Select(b => $"{Hex(b.Address)}  {b.Label}  {b.Source}{(b.Enabled ? "" : "  (off)")}"));
            p.Views["problems.txt"] = string.Join("\n", _diags.Select(d => d.ToString()));
            p.Views["registers.txt"] = RegistersText(s) + "\n\ncall stack:\n" + string.Join("\n", s.Calls);
            p.Views["outputs.txt"] = OutputsText(s.Outputs) + "\n\n" + PortsText(s);
            return p;
        }
    }

    // ------------------------------------------------------------------ restore points

    /// Where the automatic restore points go: one file per session, kept beside the settings so a crash mid-edit costs at most the interval set in Settings > General.
    public static string RestoreDir => Path.Combine(AppSettings.Dir, "restore");

    DispatcherTimer? _autoSave;
    string? _autoSavePath;
    int _autoSaveFailures;

    void StartAutoSave()
    {
        _autoSave?.Stop();
        int minutes = Math.Clamp(_settings.AutoSaveMinutes, 0, 120);
        if (minutes <= 0) { _autoSave = null; return; }
        _autoSave = new DispatcherTimer(TimeSpan.FromMinutes(minutes), DispatcherPriority.Background, (_, _) => AutoSave());
        _autoSave.Start();
    }

    /// Write a restore point, quietly. Nothing open means nothing worth keeping.
    void AutoSave()
    {
        if (_target == null && _current == null && _host.LoadedPath == null) return;
        try
        {
            Directory.CreateDirectory(RestoreDir);
            _autoSavePath ??= Path.Combine(RestoreDir, $"session-{DateTime.Now:yyyyMMdd-HHmmss}.project.zip");
            var tmp = _autoSavePath + ".part";
            ProjectFile.Save(tmp, BuildProject());
            File.Move(tmp, _autoSavePath, overwrite: true);   // a crash mid-write cannot spoil the last good one
            _autoSaveFailures = 0;
            AppLog.Info("app", $"restore point written to {_autoSavePath}");
            SetStatus($"restore point saved ({DateTime.Now:HH:mm})");
            PruneRestorePoints();
        }
        catch (Exception ex)
        {
            AppLog.Error("app", "restore point failed", ex);
            if (++_autoSaveFailures >= 3) { _autoSave?.Stop(); SetStatus("restore points switched off after three failures - see the Debug page"); }
        }
    }

    /// Keep the ten newest restore points.
    static void PruneRestorePoints()
    {
        try
        {
            foreach (var f in new DirectoryInfo(RestoreDir).GetFiles("session-*.project.zip").OrderByDescending(f => f.LastWriteTimeUtc).Skip(10))
                f.Delete();
        }
        catch { }
    }

    public static FileInfo? NewestRestorePoint()
    {
        try
        {
            var dir = new DirectoryInfo(RestoreDir);
            return dir.Exists ? dir.GetFiles("session-*.project.zip").OrderByDescending(f => f.LastWriteTimeUtc).FirstOrDefault() : null;
        }
        catch { return null; }
    }

    async void RestoreLastAutoSave()
    {
        var newest = NewestRestorePoint();
        if (newest == null) { SetStatus("there is no restore point yet (Settings > General sets how often one is written)"); return; }
        if (!await ConfirmReplaceCurrent(newest.FullName)) return;
        try
        {
            OpenProject(newest.FullName);
            SetStatus($"restored the session saved at {newest.LastWriteTime:HH:mm:ss} ({Label(newest.FullName)})", sticky: true);
        }
        catch (Exception ex) { SetStatus("could not restore: " + ex.Message); AppLog.Error("app", "restore failed", ex); }
    }

    void OpenProject(string path)
    {
        var p = ProjectFile.Load(path);
        // the processor and the ROM's settings come first: they decide the clock and names
        if (p.ProcessorJson is { Length: > 0 } pj)
            try { ApplyProfile(ProcessorProfile.FromJson(pj)); }
            catch (Exception ex) { AppLog.Error("project", "processor.json is not valid; keeping the current processor", ex); }
        if (p.SettingsJson is { Length: > 0 } sj)
            try { ApplyRomSettings(System.Text.Json.JsonSerializer.Deserialize<AppSettings>(sj)); }
            catch (Exception ex) { AppLog.Error("project", "settings.json is not valid; keeping the current settings", ex); }
        _buffers.Clear(); _dirty.Clear(); _diags.Clear();
        foreach (var src in p.Sources)
        {
            _buffers[src.Path] = src.Text;
            bool differs = !File.Exists(src.Path) || File.ReadAllText(src.Path) != src.Text;
            if (src.Unsaved || differs) _dirty.Add(src.Path);
        }
        _target = p.Target;
        _current = null;
        var show = p.Current ?? p.Target ?? _buffers.Keys.FirstOrDefault();
        if (show != null) ShowBuffer(show);
        if (_target != null) Build();
        if (p.Machine != null && p.Rom.Length > 0) _host.RestoreState(p.Machine, p.Ram, p.Rom);
        if (p.Definitions != null) _host.ReplaceDefinitions(p.Definitions);
        if (p.Machine != null)
            foreach (var (k, v) in p.Machine.Inputs)
                if (_sliders.TryGetValue(k, out var sl)) sl.Value = Math.Clamp(v, sl.Minimum, sl.Maximum);
        _memAddr.Text = p.MemoryAddress; _disAddr.Text = p.DisassemblyAddress; _lookupQ.Text = p.LookupQuery;
        _lookupLines = p.LookupLines; _lookupRows = [];
        SetItems(_lookupList, _lookupLines);
        _lookupData.SetRows([.. _lookupLines.Select(l => new DataList.Row([new(l.Length > 4 ? l[..4] : l, DataList.Address), new(l.Length > 6 ? l[6..].Trim() : "", DataList.Text)],
            null, l.Length >= 4 && int.TryParse(l[..4], NumberStyles.HexNumber, null, out var la) ? la : -1))]);
        _package.SelectedIndex = p.Package == nameof(ChipView.Package.Qfp64) ? 1 : 0;
        if (p.SelectedTab.Length > 0) SelectTab(p.SelectedTab);
        if (show != null && !SamePath(_current, show)) ShowBuffer(show);
        _lastSourceShown = "";
        _restoreView = (p.FirstVisibleLine, p.CaretLine);
        Dispatcher.UIThread.Post(() =>
        {
            _editor.ScrollToLine(p.FirstVisibleLine);
            _editor.GoToLine(p.CaretLine);
        }, DispatcherPriority.Background);
        RefreshDisassembly(true);
        _hitView.HitMode = p.HitTrace;
        if (p.DatalogCsv is { Length: > 0 } csv)
        {
            var tmp = Path.Combine(Path.GetTempPath(), $"okirom-project-{Environment.ProcessId}.csv");
            try
            {
                File.WriteAllBytes(tmp, csv);
                _datalog.RestoreLog(LogFile.Load(tmp), p.DatalogName.Length > 0 ? p.DatalogName : "project log", p.DatalogPosition);
            }
            catch (Exception ex) { AppLog.Error("project", "the project's datalog could not be read", ex); }
            finally { try { File.Delete(tmp); } catch { } }
        }
        if (p.TunerMode != _tuner) SetTunerMode(p.TunerMode);
        _calibration.RestoreView(p.CalibrationItem, p.CalibrationView);
        SetStatus($"project restored from {Label(path)}: {p.Sources.Count} source file(s), machine state, calibration{(p.DatalogCsv != null ? ", datalog" : "")} and views", sticky: true);
    }
    (int First, int Caret)? _restoreView;

    // ------------------------------------------------------------------ run control & refresh

    void Control(string action)
    {
        _sticky = "";
        _restoreView = null;
        _host.Control(action);
        _lastSourceShown = "";
        SafeRefresh();
        RefreshDisassembly(true);
    }

    void SetStatus(string text, bool sticky = false)
    {
        if (text != _lastLogged) { _lastLogged = text; AppLog.Info("status", text); }
        _status.Text = text;
        if (_tuner) _calibration.ShowStatus(text);
        ToolTip.SetTip(_status, text);
        _sticky = sticky ? text : "";
    }

    string _lastLogged = "";

    // for the --ui-check layout pass
    internal SimHost Host => _host;
    internal DatalogView DatalogPanel => _datalog;
    internal void LookupForCheck(string q) { _lookupQ.Text = q; DoXref(); }
    /// A Demon datalogs over the emulator's own port: when the emulator connects, the datalog is connected too (once per connection, so stopping the datalog by hand is left alone), and disconnecting the emulator stops it.
    int _demonLinked;

    void DemonDatalog()
    {
        var emu = _host.Emulator;
        if (!emu.Connected || emu.Device != "Demon" || emu.Connections == _demonLinked) return;
        _demonLinked = emu.Connections;
        // already logging (the simulator, say): left alone
        if (_datalog.Engine.Running || _datalog.Engine.Watch.Wanted) return;
        // a Demon found by 'auto' too: its datalog is on its own port, whatever port was set before
        _datalog.Port = "emulator";
        _datalog.Start();
        SetStatus("the Demon is connected: datalogging through it as well (same port)");
    }

    void DemonClosed()
    {
        if (_datalog.Engine.IsEmulatorPort(_datalog.Port) && (_datalog.Engine.Running || _datalog.Engine.Watch.Wanted)) _datalog.Stop();
    }

    /// At start-up: ask the website whether anything is newer, and only say so (Settings > Updates fetches it).
    async void CheckUpdatesQuietly()
    {
        try
        {
            await Task.Delay(4000);
            var changes = await Updater.Check(_settings.UpdateSite);
            var offered = changes.Where(c => c.Recommended).ToList();
            if (offered.Count == 0) return;
            bool program = offered.Any(c => c.NeedsRestart);
            SetStatus($"updates are available: {(program ? "a new version of the program" + (offered.Count > 1 ? " and " : "") : "")}" +
                      $"{(offered.Count(c => !c.NeedsRestart) is int t and > 0 ? $"{t} template file(s)" : "")} - Settings > Updates > Check now", sticky: true);
        }
        catch (Exception ex) { AppLog.Info("updates", "start-up check did not reach the website: " + ex.Message); }
    }

    /// Restarting after an update: unsaved work is saved or let go first (false: stay).
    internal Task<bool> ReadyToRestart() => ConfirmReplaceCurrent("the updated program");
    internal List<string> TabNames() => [.. _bottom.Items.OfType<TabItem>().Select(t => t.Tag as string ?? "")];
    internal void ShowTab(string header) => SelectTab(header);
    internal void TunerMode(bool on) => SetTunerMode(on);
    internal void SaveProjectTo(string path) => ProjectFile.Save(path, BuildProject());
    internal void OpenProjectFrom(string path) => OpenProject(path);
    internal bool InTuner => _tuner;
    internal CalibrationView CalibrationPanel => _calibration;
    internal HitTraceView TracePanel => _hitView;

    void SelectTab(string header)
    {
        // pages that were merged: a project saved on one of them opens on the page it went into
        header = header switch { "Hit trace" => "Trace", "Lookup / xref" or "Breakpoints" => "Lookup & breakpoints", _ => header };
        foreach (var item in _bottom.Items)
            if (item is TabItem t && (t.Tag as string) == header) { _bottom.SelectedItem = t; return; }
    }

    int _lastPcShown = -1;
    string _lastSourceShown = "";

    void SafeRefresh()
    {
        if (!_ready) return;
        try { Refresh(); }
        catch (Exception ex) { _status.Text = "refresh failed: " + ex.Message; }
    }

    void Refresh()
    {
        if (_tuner)
        {
            // Tuner mode: no simulator to look at. Where the engine is on the map goes straight from each frame
            // (DatalogView posts it as it arrives); this is the slower rest - values, gauges, the emulator, the overlay
            _datalog.Tick(null);
            _calibration.Tick();
            if ((DateTime.UtcNow - _lastSlowTuner).TotalMilliseconds >= Perf.SidePanelsMs)
            {
                _lastSlowTuner = DateTime.UtcNow;
                _calibration.UpdateEmulator();
                _calibration.SetOverlayChannels(_datalog.Channels(), _settings.OverlayChannel);
            }
            if (_datalog.Engine.Running) _calibration.UpdateOverlay(throttle: true);
            return;
        }
        var s = _host.State();
        bool sidePanes = !_expanded;
        if (!sidePanes) goto Lower;
        _cpu.Update(s, s.Label.Length > 0 ? s.Label : _host.NearestLabel(s.Pc), s.HotWindow > 0
            ? $"hot {Hex(s.HotAddress)} {_host.NearestLabel(s.HotAddress)} {100.0 * s.HotCount / s.HotWindow:F0}% of the recent window · coverage {s.Coverage} addresses"
            : "");
        // the call stack, outputs and ports change less than the registers: a few times a second is plenty (and while
        // stopped, once per step)
        if (!s.Running || (DateTime.UtcNow - _lastSidePanels).TotalMilliseconds >= Perf.SidePanelsMs)
        {
            _lastSidePanels = DateTime.UtcNow;
            _callList.SetRows(CallRows(s.Calls));
            _outList.SetRows(OutputRows(s.Outputs));
            _portList.SetRows(PortRows(s));
        }
        _chip.Update(s);
        _status.Text = s.Running
            ? $"running {(_host.Speed == 0 ? "unlimited" : _host.Speed + "x")}"
            : s.Fault ?? (_sticky.Length > 0 ? _sticky : $"{s.StopReason} @ {Hex(s.Pc)} {s.Label}");

        bool loaded = _host.LoadedPath != null;
        _run.IsEnabled = !s.Running && loaded;
        _pause.IsEnabled = s.Running;
        foreach (var b in new[] { _step, _over, _into, _out, _reset }) b.IsEnabled = !s.Running && loaded;

    Lower:
        if (!sidePanes)
        {
            _status.Text = s.Running ? $"running {(_host.Speed == 0 ? "unlimited" : _host.Speed + "x")}" : s.Fault ?? (_sticky.Length > 0 ? _sticky : $"{s.StopReason} @ {Hex(s.Pc)} {s.Label}");
            _run.IsEnabled = !s.Running && _host.LoadedPath != null; _pause.IsEnabled = s.Running;
        }
        var tab = SelectedTab();
        // the trace box re-lays out all its text on every change: only while it is on screen
        if (tab == "Trace" && !_hitView.HitMode && s.Instructions != _traceShown)
        {
            _traceShown = s.Instructions;
            _traceList.SetRows([.. s.Trace.Select((t, i) => new DataList.Row(
                [new(Hex(t.Pc), DataList.Address), new(t.Label.Length > 0 ? t.Label : _host.NearestLabel(t.Pc), t.Label.Length > 0 ? DataList.Label : DataList.Dim, t.Label.Length > 0), new(t.Text, DataList.MnemonicInk(t.Text))],
                DataList.Code, t.Pc, $"{_host.Where((ushort)t.Pc)}\n{t.Text}", Current: i == s.Trace.Count - 1))], follow: true);
        }
        if (tab == "Lookup & breakpoints" && string.Join(",", s.Breakpoints.Select(b => $"{b.Address}{b.Enabled}")) is var bpKey && bpKey != _bpShown)
        {
            _bpShown = bpKey;
            // a breakpoint switched off: kept in the list, hollow and grey, not stopped at
            _bpList.SetRows([.. s.Breakpoints.Select(b => new DataList.Row(
                [new(b.Enabled ? "●" : "○", b.Enabled ? DataList.Error : DataList.Dim), new(Hex(b.Address), b.Enabled ? DataList.Address : DataList.Dim),
                 new(b.Label + (b.Enabled ? "" : "  (off)"), b.Enabled ? DataList.Label : DataList.Dim), new(b.Source, DataList.Dim)],
                b.Enabled ? DataList.Error : DataList.Dim, b.Address, $"{Hex(b.Address)} {b.Label}{(b.Enabled ? "" : " - switched off")}\n{b.Source}", Tag: b.Enabled))]);
        }

        if (!s.Running && _restoreView == null)
        {
            if (_lastPcShown != s.Pc) { _lastPcShown = s.Pc; RefreshDisassembly(false); }
            var key = s.SourceFile + ":" + s.SourceLine;
            if (s.SourceFile != null && key != _lastSourceShown)
            {
                _lastSourceShown = key;
                ShowSourceLine(s.SourceFile, s.SourceLine);
            }
        }
        if (tab == "Memory") { RefreshMemory(); _memMap?.Refresh(); }
        SyncSliders();

        // after a step: show the table the instruction read
        if (_host.StepSerial != _lastStepSerial && !s.Running)
        {
            _lastStepSerial = _host.StepSerial;
            if (_calibration.FollowReads(_host.LastStepReads) && SelectedTab() != "Calibration") SelectTab("Calibration");
        }
        switch (tab)
        {
            case "Calibration":
                _calibration.Tick();
                _calibration.UpdateEmulator();
                _calibration.SetOverlayChannels(_datalog.Channels(), _settings.OverlayChannel);
                if (_datalog.Engine.Running) _calibration.UpdateOverlay(throttle: true);
                break;
            case "Trace" when _hitView.HitMode: _hitView.Tick(s); break;
            case "Datalog": _datalog.Tick(s); break;
            case "Debug": _debug.Tick(); break;
        }
        if ((DateTime.UtcNow - _lastHitPaint).TotalMilliseconds > 500)
        {
            _lastHitPaint = DateTime.UtcNow;
            _editor.SetHits(_current != null && _hitView.ColourSource && _hitView.HitMode && SelectedTab() == "Trace" ? _hitView.LineHits(_current) : null);
        }
    }
    int _lastStepSerial;
    DateTime _lastHitPaint, _lastSidePanels, _lastSlowTuner;
    string? _bpShown;

    /// Double-click in the source: a label or address of a defined table/setting opens it on the Calibration tab; a code label jumps to it.
    void OnWordDoubleClicked(string word, int line)
    {
        word = word.Trim().TrimStart('#').TrimEnd(',', ':');
        if (word.Length == 0) return;
        var defs = _host.Defs();
        int addr;
        if (!defs.TryResolve(word, out addr))
        {
            var hex = word.EndsWith("h", StringComparison.OrdinalIgnoreCase) ? word[..^1] : word;
            if (!int.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out addr)) return;
        }
        if (addr < Bus.RomSize && _calibration.ShowAddress(addr))
        {
            SelectTab("Calibration");
            SetStatus($"{word} = {Hex(addr)}: opened on the Calibration tab");
            return;
        }
        if (_host.Assembly?.Symbols.TryGetValue(word, out var sym) == true && sym.Kind == SymbolKind.Label && sym.Value < Bus.RomSize)
        {
            var src = _host.Assembly.Lookup((int)sym.Value);
            if (src != null && !(SamePath(src.File, _current) && src.Line == line)) GoToAddress((int)sym.Value);
        }
    }

    /// P2.0-P2.3 carry injectors 1, 3, 4, 2 (measured on the board: the firing order).
    static readonly int[] InjectorNumber = { 1, 3, 4, 2 };

    static string RegistersText(SimHost.Snapshot s) =>
        $"PC   {Hex(s.Pc)} {s.Label}\n" +
        $"A    {Hex(s.A)}   DP {Hex(s.Dp)}   X1 {Hex(s.X1)}   X2 {Hex(s.X2)}\n" +
        $"USP  {Hex(s.Usp)}   SSP {Hex(s.Ssp)}   LRB {Hex(s.Lrb)} -> {Hex(s.Bank, 3)}\n" +
        $"PSW  {Hex(s.Psw)}   er {string.Join(" ", s.Er.Select(v => Hex(v)))}\n" +
        $"{s.SimSeconds:F3} s simulated · {s.Instructions:N0} instructions\n" +
        $"CY {(s.Cy ? 1 : 0)}  Z {(s.Z ? 1 : 0)}  HC {(s.Hc ? 1 : 0)}  DD {(s.Dd ? 1 : 0)}  MIE {(s.Mie ? 1 : 0)}  SCB {s.Scb}   IRQ {Hex(s.Irq)}  IE {Hex(s.Ie)}";

    static readonly System.Text.RegularExpressions.Regex CallLine = new(@"^(irq )?([0-9A-Fa-f]{4}) (.*?)\s+\(returns to ([0-9A-Fa-f]{4})\)");

    /// The call stack as rows: an interrupt or a call, where it went in, the routine and where it goes back to.
    static List<DataList.Row> CallRows(List<string> calls) => [.. calls.Take(24).Select(c =>
    {
        var m = CallLine.Match(c);
        if (!m.Success) return new DataList.Row([new(""), new(""), new(c, DataList.Text)]);
        bool irq = m.Groups[1].Success;
        int entry = int.Parse(m.Groups[2].Value, NumberStyles.HexNumber);
        return new DataList.Row(
            [new(irq ? "irq" : "call", irq ? DataList.Purple : DataList.Call), new(m.Groups[2].Value, DataList.Address), new(m.Groups[3].Value, DataList.Label), new(m.Groups[4].Value, DataList.Dim)],
            irq ? DataList.Purple : DataList.Call, entry, c);
    })];

    static DataList.Cell OnOff(bool on) => new(on ? "ON" : "off", on ? DataList.Good : DataList.Dim, on);

    /// What the ROM is driving, one output a row, the injectors under their own heading.
    static List<DataList.Row> OutputRows(SimHost.OutputState o)
    {
        string Ago(double ms) => ms < 0 ? "never" : ms < 1000 ? $"{ms:F0} ms ago" : $"{ms / 1000:F1} s ago";
        var rows = new List<DataList.Row>
        {
            new([new("Fuel pump relay"), new("8255 PB7", DataList.Address), OnOff(o.FuelPump), new("")], o.FuelPump ? DataList.Good : null),
            new([new("VTEC solenoid"), new("8255 PC0", DataList.Address), OnOff(o.Vtec), new($"pressure switch {(o.VtecPressure ? "closed" : "open")}", DataList.Dim)], o.Vtec ? DataList.Good : null),
            new([new("Ignition coil"), new("timer 3", DataList.Address), new($"{o.SparksPerSec:F0} /s", o.SparksPerSec > 0 ? DataList.Good : DataList.Dim), new("dwell start + fire events", DataList.Dim)], o.SparksPerSec > 0 ? DataList.Good : null),
            new([new("Injectors - firing order 1-3-4-2", DataList.Text)], Heading: true),
        };
        const string injTip = "P2.0-3 latch the pattern (firing order 1-3-4-2), the P3.4 gate pulse from timer 0 opens it";
        for (int n = 0; n < 4; n++)
        {
            bool on = o.InjectorMs[n] > 0;
            rows.Add(new([new($"Injector {InjectorNumber[n]}"), new($"P2.{n}", DataList.Address), new(on ? $"{o.InjectorMs[n]:F2} ms" : "-", on ? DataList.Good : DataList.Dim),
                          new($"{o.InjectorPerSec[n]:F1}/s · {o.InjectorDutyPct[n]:F1} % duty · {Ago(o.InjectorAgoMs[n])}", DataList.Dim)], on ? DataList.Good : null, Tip: injTip));
        }
        rows.Add(new([new("Other outputs", DataList.Text)], Heading: true));
        rows.Add(new([new("Watchdog heartbeat"), new("P2.4", DataList.Address), new($"{o.WatchdogHz:F1} Hz", o.WatchdogHz > 0 ? DataList.Good : DataList.Warning), new("")]));
        rows.Add(new([new("Analog mux select"), new("P2.5-7", DataList.Address), new($"ch {o.MuxChannel}"), new("")]));
        rows.Add(new([new("EGR (PWM0)"), new("P4.2", DataList.Address), new(o.Pwm0Duty < 0 ? "idle" : $"{o.Pwm0Duty:F1} %", o.Pwm0Duty < 0 ? DataList.Dim : DataList.Good), new(o.Pwm0Duty < 0 ? "" : $"at {o.Pwm0Hz:F1} Hz", DataList.Dim)]));
        rows.Add(new([new("A/T lockup (PWM1)"), new("P4.3", DataList.Address), new(o.Pwm1Duty < 0 ? "idle" : $"{o.Pwm1Duty:F1} %", o.Pwm1Duty < 0 ? DataList.Dim : DataList.Good), new(o.Pwm1Duty < 0 ? "" : $"at {o.Pwm1Hz:F1} Hz", DataList.Dim)]));
        rows.Add(new([new("8255 PPI"), new("PA · PB · PC", DataList.Address), new($"{o.PpiA:X2} {o.PpiB:X2} {o.PpiC:X2}"), new("PA is the inputs", DataList.Dim)]));
        return rows;
    }

    /// Every port pin, under a heading for its port with the port's value.
    static List<DataList.Row> PortRows(SimHost.Snapshot s)
    {
        string Ms(double v) => v <= 0 ? "-" : v < 1000 ? $"{v:F2}" : $"{v / 1000:F1} s";
        var rows = new List<DataList.Row>();
        foreach (var r in s.Outputs.Pins)
        {
            if (r.Pin.EndsWith(".0")) rows.Add(new([new($"P{r.Pin[1]}", DataList.Text), new($"= {Hex(s.Ports[r.Pin[1] - '0'], 2)}", DataList.Address)], DataList.Data, Heading: true));
            var dirInk = r.Dir == "out" ? DataList.Code : r.Dir == "in" ? DataList.Data : DataList.Purple;
            rows.Add(new([new(r.Pin, DataList.Address), new(r.Level.ToString(), r.Level != 0 ? DataList.Good : DataList.Dim, r.Level != 0), new(r.Dir, dirInk),
                          new(r.ChangesPerSec > 0 ? $"{r.ChangesPerSec:F1}" : "-", r.ChangesPerSec > 0 ? DataList.Text : DataList.Dim),
                          new(Ms(r.HighMs), DataList.Dim), new(Ms(r.LowMs), DataList.Dim), new(r.Function, DataList.Text), new(r.DrivenBy, DataList.Label)],
                         dirInk, Tip: $"{r.Pin} {r.Function}" + (r.DrivenBy.Length > 0 ? $"\nlast written by {r.DrivenBy}" : "")));
        }
        return rows;
    }

    static string OutputsText(SimHost.OutputState o)
    {
        var sb = new System.Text.StringBuilder();
        string Ago(double ms) => ms < 0 ? "never" : ms < 1000 ? $"{ms:F0} ms ago" : $"{ms / 1000:F1} s ago";
        sb.AppendLine($"Fuel pump relay  8255 PB7 (P0.7)  {(o.FuelPump ? "ON " : "off")}");
        sb.AppendLine($"VTEC solenoid    8255 PC0 (P1.0)  {(o.Vtec ? "ON " : "off")}   pressure sw (4700h.1) {(o.VtecPressure ? "closed" : "open")}");
        sb.AppendLine($"Ignition coil    {o.SparksPerSec,5:F0} timer-3 events/s (dwell start + fire)");
        sb.AppendLine();
        sb.AppendLine("Injector  pattern  pulse ms  events/s  duty %  last event");
        for (int n = 0; n < 4; n++)
            sb.AppendLine($"   {InjectorNumber[n]}      P2.{n}   {(o.InjectorMs[n] > 0 ? o.InjectorMs[n].ToString("F2") : "  -"),8}  {o.InjectorPerSec[n],8:F1}  {o.InjectorDutyPct[n],6:F1}  {Ago(o.InjectorAgoMs[n])}");
        sb.AppendLine("  P2.0-3 latch the pattern (firing order 1-3-4-2), the P3.4 gate pulse from timer 0 opens it");
        sb.AppendLine();
        sb.AppendLine($"Watchdog heartbeat  P2.4  {o.WatchdogHz:F1} Hz");
        sb.AppendLine($"Analog mux select   P2.5-7  channel {o.MuxChannel}");
        sb.AppendLine($"EGR (PWM0)         P4.2  {(o.Pwm0Duty < 0 ? "idle" : $"{o.Pwm0Duty:F1} % at {o.Pwm0Hz:F1} Hz")}");
        sb.AppendLine($"A/T lockup (PWM1)  P4.3  {(o.Pwm1Duty < 0 ? "idle" : $"{o.Pwm1Duty:F1} % at {o.Pwm1Hz:F1} Hz")}");
        sb.Append($"8255 PPI  PA {o.PpiA:X2} (inputs)  PB {o.PpiB:X2}  PC {o.PpiC:X2}");
        return sb.ToString();
    }

    static string PortsText(SimHost.Snapshot s)
    {
        var sb = new System.Text.StringBuilder();
        string Ms(double v) => v <= 0 ? "     -" : v < 1000 ? $"{v,6:F2}" : $"{v / 1000,5:F1}s";
        foreach (var r in s.Outputs.Pins)
        {
            if (r.Pin.EndsWith(".0")) sb.AppendLine($"P{r.Pin[1]}  = {Hex(s.Ports[r.Pin[1] - '0'], 2)}");
            sb.AppendLine($"  {r.Pin}  {r.Level} {r.Dir,-3} {r.ChangesPerSec,7:F1}/s {Ms(r.HighMs)} {Ms(r.LowMs)}  {r.Function}" +
                          (r.DrivenBy.Length > 0 ? $"  [{r.DrivenBy}]" : ""));
        }
        return sb.ToString().TrimEnd();
    }

    void RefreshDisassembly(bool force)
    {
        int? from = null;
        var want = (_disAddr.Text ?? "").Trim();
        if (want.Length > 0 && _host.Definitions?.TryResolve(want, out var a) == true) from = a;
        else if (want.Length > 0 && int.TryParse(want.TrimEnd('h', 'H'), NumberStyles.HexNumber, null, out var hx)) from = hx;
        var lines = _host.Disassemble(from, 60);
        _disasmAddrs = [.. lines.Select(l => l.Addr)];
        _disList.SetRows([.. lines.Select(l => new DataList.Row(
            [new(l.Bp ? "●" : l.Current ? "▶" : "", l.Bp ? DataList.Error : DataList.Good, true), new(Hex(l.Addr), DataList.Address), new(l.Bytes, DataList.Dim),
             new(l.Label, DataList.Label), new(l.Text, DataList.MnemonicInk(l.Text))],
            l.Bp ? DataList.Error : l.Current ? DataList.Good : null, l.Addr, l.Source is { Length: > 0 } src ? src : null, Current: l.Current))]);
        int cur = lines.FindIndex(l => l.Current);
        if (cur >= 0 && from == null) _disList.ScrollTo(cur);
    }

    void RefreshMemory()
    {
        int addr = 0x80;
        var t = (_memAddr.Text ?? "").Trim();
        if (_host.Definitions?.TryResolve(t, out var a) == true) addr = a;
        else if (int.TryParse(t.TrimEnd('h', 'H'), NumberStyles.HexNumber, null, out var hx)) addr = hx;
        var bytes = _host.ReadMemory(addr, 256);
        var sb = new System.Text.StringBuilder();
        for (int row = 0; row < 16; row++)
        {
            sb.Append(Hex(addr + (row * 16))).Append("  ");
            for (int c = 0; c < 16; c++) sb.Append(bytes[(row * 16) + c].ToString("X2")).Append(' ');
            sb.Append(' ');
            for (int c = 0; c < 16; c++)
            {
                byte v = bytes[(row * 16) + c];
                sb.Append(v >= 32 && v < 127 ? (char)v : '.');
            }
            sb.Append('\n');
        }
        _memory.Text = sb.ToString();
    }

    // ------------------------------------------------------------------ lookup / xref

    void DoLookup()
    {
        var rows = _host.Lookup(_lookupQ.Text ?? "");
        _lookupRows = rows;
        _lookupLines = rows.Count == 0
            ? ["nothing matches"]
            : [.. rows.Select(r => $"{Hex(r.Address)}  {r.Name}{(r.Offset != 0 ? " + " + r.Offset : "")}   {r.Kind}")];
        SetItems(_lookupList, _lookupLines);
        _lookupData.Empty = "Nothing matches.";
        _lookupData.SetRows([.. rows.Select(r => new DataList.Row(
            [new(Hex(r.Address), DataList.Address), new(r.Name + (r.Offset != 0 ? " + " + r.Offset : ""), DataList.Label), new(r.Kind, KindInk(r.Kind))],
            KindInk(r.Kind), r.Address, $"{Hex(r.Address)} {r.Name}: {r.Kind}"))]);
    }

    void DoXref()
    {
        var hits = _host.Xref(_lookupQ.Text ?? "");
        _lookupRows = [.. hits.Select(h => (h.Label, h.Address, 0, h.Kind))];
        _lookupLines = hits.Count == 0
            ? ["no references found (or the target could not be resolved)"]
            : [.. hits.Select(h => $"{Hex(h.Address)}  {h.Label,-22} {h.Text,-32} {h.Source}")];
        SetItems(_lookupList, _lookupLines);
        _lookupData.Empty = "No references found (or the target could not be resolved).";
        _lookupData.SetRows([.. hits.Select(h => new DataList.Row(
            [new(Hex(h.Address), DataList.Address), new(h.Label.Length > 0 ? h.Label : _host.NearestLabel(h.Address), h.Label.Length > 0 ? DataList.Label : DataList.Dim),
             new(h.Kind.StartsWith("word") ? "word operand" : h.Kind.StartsWith("direct") ? "direct" : h.Kind, DataList.Dim), new(h.Text, DataList.MnemonicInk(h.Text)), new(h.Source ?? "", DataList.Dim)],
            DataList.Code, h.Address, $"{Hex(h.Address)} {h.Label}\n{h.Text}\n{h.Source}"))]);
    }

    /// What a looked-up name is, as a colour: code, data (a table or a setting), RAM.
    static IBrush KindInk(string kind) =>
        kind.Contains("RAM", StringComparison.OrdinalIgnoreCase) || kind.Contains("SFR", StringComparison.OrdinalIgnoreCase) ? DataList.Jump
        : kind.Contains("label", StringComparison.OrdinalIgnoreCase) || kind.Contains("code", StringComparison.OrdinalIgnoreCase) ? DataList.Code
        : DataList.Data;

    // ------------------------------------------------------------------ keyboard

    void OnKeyDown(object? sender, KeyEventArgs e)
    {
        string? action = _hotKeys.FirstOrDefault(kv => kv.Value.Matches(e)).Key;
        switch (action)
        {
            case null: return;
            case "Run / pause": Control(_host.IsRunning ? "pause" : "run"); break;
            case "Step": Control("step"); break;
            case "Step over": Control("stepover"); break;
            case "Step into": Control("stepinto"); break;
            case "Step out": Control("stepout"); break;
            case "Reset": Control("reset"); break;
            case "Build": Build(); break;
            case "Patch live": PatchLive(false); break;
            case "Open": OpenFileDialog(); break;
            case "Save": SaveCurrent(); break;
            case "Save project": SaveProject(); break;
            case "Expand lower tabs": ToggleExpand(); break;
            case "Settings": OpenSettings(); break;
            case "Tuner mode": SetTunerMode(!_tuner); break;
            case "Compare": OpenCompare(); break;
            case "Toggle breakpoint":
                if (_current != null)
                {
                    var r = _host.ToggleBreakpointAt(Path.GetFullPath(_current), _editor.CaretLine);
                    SetStatus(r.ok ? $"breakpoint {(r.enabled ? "set" : "cleared")} at {Hex(r.address)}" : r.error);
                    RefreshDisassembly(true);
                }
                break;
        }
        e.Handled = true;
    }

    // ------------------------------------------------------------------ processor, compare, ROM settings

    void ApplyProfile(ProcessorProfile p)
    {
        _profile = p;
        _host.ApplyProfile(p);
        _chipTitle.Text = p.Name.ToUpperInvariant();
        _chip.Rebuild();
        if (ProcessorProfile.Builtin(p.Name) != null) _settings.Processor = p.Name;
        SetStatus($"processor {p.Name} on {p.Board}: {p.CrystalMHz:0.##} MHz / {p.ClockDivider}");
    }

    /// Settings saved with a project: those that belong to the ROM (simulation, datalog, emulator), not the window.
    void ApplyRomSettings(AppSettings? r)
    {
        if (r == null) return;
        var s = _settings;
        s.FastBoot = r.FastBoot; s.SpeedIndex = r.SpeedIndex; s.LiveTrace = r.LiveTrace; s.FollowReads = r.FollowReads; s.TrailSeconds = r.TrailSeconds;
        s.DatalogProtocol = r.DatalogProtocol; s.DatalogBaud = r.DatalogBaud; s.DatalogIntervalMs = r.DatalogIntervalMs; s.DatalogDrivesSimulator = r.DatalogDrivesSimulator;
        s.AuxChannels = r.AuxChannels; s.OverlayChannel = r.OverlayChannel; s.StoichAfr = r.StoichAfr;
        s.MoatesBase = r.MoatesBase; s.HitSkipRepeats = r.HitSkipRepeats;
        s.EmulatorType = r.EmulatorType; s.EmulatorBaud = r.EmulatorBaud;
        s.SerialTimeoutMs = r.SerialTimeoutMs; s.SerialWriteTimeoutMs = r.SerialWriteTimeoutMs;
        s.PostWritePauseMs = r.PostWritePauseMs; s.SerialRetries = r.SerialRetries; s.SerialDtrRts = r.SerialDtrRts;
        s.AfrTargetLow = r.AfrTargetLow; s.AfrTargetHigh = r.AfrTargetHigh;
        s.WidebandCorrection = r.WidebandCorrection; s.AnalogCurves = r.AnalogCurves;
        ApplySettings(first: false);
    }

    void OpenCompare()
    {
        Mcp.Program66k? Current()
        {
            try
            {
                if (_host.LoadedPath == null) return null;
                var rom = _host.RomBytes(0, Bus.RomSize);
                var srcs = Dispatcher.UIThread.Invoke(() => _buffers.Select(kv => (kv.Key, kv.Value)).ToList());
                return _host.Assembly is { } asm ? Mcp.Program66k.FromAssembly(_host.LoadedPath, rom, asm, srcs) : Mcp.Program66k.FromImage(rom, _host.LoadedPath);
            }
            catch (Exception ex) { AppLog.Error("compare", "could not prepare the open ROM", ex); return null; }
        }
        new CompareWindow(Current, _host.LoadedPath).Show(this);
    }
}
