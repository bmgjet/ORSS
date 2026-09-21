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
    readonly ListBox _problems = new();
    readonly TextBox _trace = Readonly();
    readonly TextBox _memory = Readonly();
    readonly TextBox _memAddr = Mono(new TextBox { Text = "0080", Width = 80 });
    readonly ListBox _bpList = new();
    readonly TextBox _lookupQ = new() { Watermark = "label, setting or address (3DDE, 0d9h, fuelpump)", Width = 380 };
    readonly ListBox _lookupList = new();
    readonly TabControl _bottom = new();
    readonly CalibrationView _calibration;
    readonly HitTraceView _hitView;
    readonly DatalogView _datalog;
    readonly DebugView _debug;
    readonly Dictionary<string, ZoomHost> _zoom = new();
    ProcessorProfile _profile = ProcessorProfile.Current;
    Control? _simRoot, _tunerRoot;
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
    readonly TextBlock _regs = Mono(new TextBlock { FontSize = 12 });
    readonly TextBlock _flags = Small("");
    readonly TextBlock _calls = Mono(new TextBlock { FontSize = 11, TextWrapping = TextWrapping.NoWrap, LineHeight = 15 });
    const int CallStackLines = 8;
    readonly ListBox _disasm = new();
    readonly TextBox _disAddr = Mono(new TextBox { Watermark = "addr/label", Width = 110 });
    readonly TextBlock _outputs = Mono(new TextBlock { FontSize = 11.5 });
    readonly TextBlock _ports = Mono(new TextBlock { FontSize = 11 });
    readonly TextBlock _hot = Small("");

    // toolbar / status
    readonly TextBlock _status = new() { Text = "ready", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
    string _sticky = "";
    bool _ready;
    readonly Button _run, _pause, _step, _over, _into, _out, _reset, _buildBtn;
    readonly Button _tunerButton;
    AppSettings _settings = AppSettings.Load();
    readonly LayoutTransformControl _scaler = new();
    OkiRomSim.Mcp.McpHttp? _mcpHttp;
    string _mcpState = "off";

    readonly Dictionary<string, string> _buffers = new();        // open file -> text as on screen
    readonly HashSet<string> _dirty = new();                     // differs from the file on disk
    string? _current;
    List<Diagnostic> _diags = new();
    List<(string file, int line)> _problemLoc = new();
    List<int> _disasmAddrs = new();
    List<(string Name, int Address, int Offset, string Kind)> _lookupRows = new();
    List<string> _lookupLines = new();

    // build state: what the loaded image was built from, to decide whether Build is needed
    Dictionary<string, string> _builtTexts = new();
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
        _hitView = new HitTraceView(_host, f => ReadBuffer(Path.GetFullPath(f)) ?? (File.Exists(f) ? File.ReadAllText(f) : null));
        _hitView.GoToAddress += GoToAddress;
        _datalog = new DatalogView(_host, () => GetTopLevel(this));
        _datalog.GoToAddress += GoToAddress;
        _debug = new DebugView(() => GetTopLevel(this));
        _calibration.ExpandRequested += ToggleExpand;
        _calibration.CompareRequested += OpenCompare;
        _calibration.OverlayFrames = () => _datalog.Frames();
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
        _tunerButton = ToolButton("Tuner mode", () => SetTunerMode(!_tuner), "Switch between the full simulator workbench and Tuner mode: the calibration editor as the main page with datalogging beside it.");

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

        ApplySettings(first: true);
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
        if (_settings.TunerMode) SetTunerMode(true);

        _ready = true;
        if (_target == null) UpdateBuildButton(false, "Nothing to build yet: open a .asm or .bin.");
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        timer.Tick += (_, _) => SafeRefresh();
        timer.Start();
    }

    /// The File drop-down: the things done once in a while, out of the way of the everyday buttons.
    Button FileMenu() => Toolbar.Menu("File", Toolbar.Open,
        new Toolbar.Entry(Toolbar.Open, "Open…  (Ctrl+O)", "Open a .asm source, a .bin/.rom image (disassembled to source) or a saved project .zip.", OpenFileDialog),
        new Toolbar.Entry(Toolbar.Save, "Save  (Ctrl+S)", "Write the source on screen to its file.", SaveCurrent),
        new Toolbar.Entry(Toolbar.SaveAs, "Save as…", "Write the source on screen to a new file.", SaveAs),
        Toolbar.Entry.Line,
        new Toolbar.Entry(Toolbar.Project, "Save project…  (Ctrl+Shift+S)",
            "Save everything exactly as it is to a .zip: all source buffers (saved or not), the editor position, the full simulator state (registers, RAM, patched ROM, inputs, breakpoints), calibration definitions, and the Trace, Memory, Lookup and Breakpoint views. Open the .zip to carry on.", SaveProject),
        new Toolbar.Entry(Toolbar.Restore, "Restore last auto save",
            "Open the newest automatic restore point (Settings > General sets how often one is written).", RestoreLastAutoSave),
        Toolbar.Entry.Line,
        new Toolbar.Entry(Toolbar.Clear, "Clear project",
            "Close the ROM and let go of everything - sources, definitions, machine state, hits, datalog frames and caches - leaving the app idle and using as little memory as possible (handy before handing it to an LLM agent).", ClearProject),
        new Toolbar.Entry(Toolbar.Compare, "Compare…",
            "Compare the ROM open here with another .bin or .asm: what changed in the code (routines added, removed, changed) and in the tables.", OpenCompare));

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
        toolbar.Children.Add(new Separator { Width = 8 });
        toolbar.Children.Add(_buildBtn.WithIcon(Toolbar.Build));
        toolbar.Children.Add(new Separator { Width = 8 });
        toolbar.Children.Add(_run); toolbar.Children.Add(_pause); toolbar.Children.Add(_step);
        toolbar.Children.Add(_over); toolbar.Children.Add(_into); toolbar.Children.Add(_out); toolbar.Children.Add(_reset);
        toolbar.Children.Add(new Separator { Width = 8 });
        toolbar.Children.Add(_tunerButton.WithIcon(Toolbar.Tuner));
        toolbar.Children.Add(Toolbar.Button(Toolbar.Settings, "Settings", "UI scale, panel zoom, colours, hot keys, simulation speed, datalogging, the emulator, the processor profile and the MCP server for LLM agents.", OpenSettings));

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
        BuildInputs();
        var inputsBox = new StackPanel();
        inputsBox.Children.Add(inHead);
        inputsBox.Children.Add(_inputs);
        _zInputs = Zoomable("Inputs", inputsBox);
        left.Children.Add(_zInputs);

        // ---- centre
        _problems.SelectionChanged += (_, _) =>
        {
            int i = _problems.SelectedIndex;
            if (i >= 0 && i < _problemLoc.Count) ShowSourceLine(_problemLoc[i].file, _problemLoc[i].line);
        };
        Tip(_problems, "Build errors and warnings. Click one to jump to its line (it is highlighted in the editor).");
        Tip(_trace, "The last instructions executed, oldest first.");
        Tip(_editor, "The source being simulated. Ctrl+B builds, F9 toggles a breakpoint on the caret line.");
        _bottom.Items.Add(Tab("Problems", Zoomable("Problems", _problems), "Build errors and warnings"));
        _bottom.Items.Add(Tab("Trace", Zoomable("Trace", _trace), "Recently executed instructions"));
        _bottom.Items.Add(Tab("Memory", Zoomable("Memory", MemoryPanel()), "RAM / ROM hex view"));
        _zCalibration = Zoomable("Calibration", _calibration);
        _bottom.Items.Add(Tab("Calibration", _zCalibration, "Settings and tables: define, detect, edit, export, emulator"));
        _bottom.Items.Add(Tab("Lookup / xref", Zoomable("Lookup", LookupPanel()), "Find labels, settings and every instruction that references an address"));
        _bottom.Items.Add(Tab("Breakpoints", Zoomable("Breakpoints", BreakpointPanel()), "Breakpoints"));
        _zDatalog = Zoomable("Datalog", _datalog);
        _bottom.Items.Add(Tab("Datalog", _zDatalog, "Log a car (any of the OBD1 protocols) or the simulated ROM, load a datalog, and drive the simulator with it"));
        _bottom.Items.Add(Tab("Hit trace", Zoomable("Hit trace", _hitView), "Which ROM addresses are fetched (simulator, or a real ECU through a Moates Ostrich 2.0 / Demon)"));
        _bottom.Items.Add(Tab("Debug", Zoomable("Debug", _debug), "Everything that happened: actions, errors, MCP calls (and where they came from), serial traffic"));
        // SelectionChanged bubbles: lists inside the tabs raise it too, so react only to the tab strip itself
        _bottom.SelectionChanged += (_, e) => { if (ReferenceEquals(e.Source, _bottom) && SelectedTab() == "Calibration") _calibration.Refresh(); };

        var centre = _centre = new Grid { RowDefinitions = new RowDefinitions("Auto,*,4,360") };
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
        _disasm.DoubleTapped += (_, _) =>
        {
            int i = _disasm.SelectedIndex;
            if (i >= 0 && i < _disasmAddrs.Count)
            {
                _host.ToggleBreakpoint(Hex(_disasmAddrs[i]));
                RefreshDisassembly(true);
            }
        };
        _disasm.SelectionChanged += (_, _) =>
        {
            if (_updatingLists.Contains(_disasm)) return;
            int i = _disasm.SelectedIndex;
            if (i >= 0 && i < _disasmAddrs.Count && _host.Assembly?.Lookup(_disasmAddrs[i]) is { } src) ShowSourceLine(src.File, src.Line, select: false);
        };
        Tip(_disasm, "Instructions around the PC (▶) with breakpoints (●). Click a line to show it in the source; double-click to toggle a breakpoint.");
        Tip(_regs, "CPU registers.");
        Tip(_flags, "PSW flags, interrupt request (IRQ) and enable (IE) masks.");
        Tip(_calls, "Call stack, innermost first: routines entered with CAL/VCAL and interrupt handlers, with where each returns to.");
        Tip(_outputs, "What the ROM is driving: fuel pump, VTEC, injectors (pulse, rate, duty), ignition timer events, watchdog, mux, PWM.");
        Tip(_ports, "Every port pin: level, direction (in/out/sf = on-chip peripheral), changes per second, last high/low time, board function, and the routine that last wrote it.");
        var right = new StackPanel { Margin = new Thickness(6) };
        right.Children.Add(Header("CPU"));
        right.Children.Add(_regs);
        right.Children.Add(_flags);
        right.Children.Add(_hot);
        right.Children.Add(Header("Call stack"));
        // fixed height, so the panels below do not jump as calls come and go
        right.Children.Add(new ScrollViewer
        {
            Content = _calls, Height = CallStackLines * 15 + 4,
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
        });
        var disHeader = new StackPanel { Orientation = Orientation.Horizontal };
        disHeader.Children.Add(Header("Disassembly"));
        disHeader.Children.Add(_disAddr);
        disHeader.Children.Add(ToolButton("Go", () => RefreshDisassembly(true), "Disassemble from the address or label typed."));
        right.Children.Add(disHeader);
        _disasm.Height = 260;
        _disasm.FontFamily = MonoFont;
        right.Children.Add(_disasm);
        right.Children.Add(Header("Outputs"));
        right.Children.Add(_outputs);
        right.Children.Add(Header("Ports (level · direction · changes/s · last high/low · driven by)"));
        right.Children.Add(_ports);

        var main = _mainGrid = new Grid { ColumnDefinitions = new ColumnDefinitions("3*,4,4*,4,3*") };
        var leftScroll = _leftPane = new ScrollViewer { Content = left };
        var rightScroll = _rightPane = new ScrollViewer { Content = Zoomable("Right", right), HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto };
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
        var back = Toolbar.Button(Toolbar.Tuner, "Simulator mode", "Back to the full workbench: source, simulator, disassembly and every tab.", () => SetTunerMode(false));
        bar.Children.Add(back);
        bar.Children.Add(Toolbar.Button(Toolbar.Settings, "Settings", "Datalog port and protocol, wideband, aux channels, emulator port, colours, zoom...", OpenSettings));
        var tunerStatus = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0), Opacity = 0.8, FontSize = 11 };
        tunerStatus.Bind(TextBlock.TextProperty, _status.GetObservable(TextBlock.TextProperty));
        bar.Children.Add(tunerStatus);
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
            SetTabContent("Calibration", UiStyles.Adopt(_zCalibration));
            SetTabContent("Datalog", UiStyles.Adopt(_zDatalog));
            _scaler.Child = _simRoot;
        }
        _calibration.SetTunerMode(on);
        _calibration.Refresh();
        _tunerButton.Content = Toolbar.Label(Toolbar.Tuner, on ? "Simulator mode" : "Tuner mode");
        AppLog.Action("ui", on ? "tuner mode" : "simulator mode");
        SetStatus(on ? "Tuner mode: open a .bin, Detect its maps, connect the datalog (Settings > Datalog) and the emulator" : "Simulator mode");
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
            _savedColumns = _mainGrid.ColumnDefinitions.Select(c => c.Width).ToArray();
            _savedRows = _centre.RowDefinitions.Select(r => r.Height).ToArray();
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
            if (c != null) c.IsVisible = !_expanded;
        _miniInputs.IsVisible = _expanded;
        if (_miniInputs.Tag is Control mini) mini.IsVisible = _expanded;
        _calibration.SetExpanded(_expanded);
    }

    // ------------------------------------------------------------------ settings

    void OpenSettings()
    {
        SaveLayout();
        var w = new SettingsWindow(_settings, () => _mcpState, _profile);
        w.Closed += (_, _) =>
        {
            if (w.Result == null) return;
            var pw = w.Result.McpPassword;
            w.Result.WindowX = _settings.WindowX; w.Result.WindowY = _settings.WindowY;
            w.Result.WindowWidth = _settings.WindowWidth; w.Result.WindowHeight = _settings.WindowHeight; w.Result.Maximized = _settings.Maximized;
            w.Result.LeftColumn = _settings.LeftColumn; w.Result.CentreColumn = _settings.CentreColumn; w.Result.RightColumn = _settings.RightColumn;
            w.Result.BottomPanel = _settings.BottomPanel; w.Result.SelectedTab = _settings.SelectedTab;
            w.Result.Package = _settings.Package; w.Result.LastFile = _settings.LastFile;
            bool tunerChanged = w.Result.TunerMode != _tuner;
            _settings = w.Result;
            _settings.McpPassword = pw;
            _settings.Save();
            if (w.ResultProfile != null) ApplyProfile(w.ResultProfile);
            ApplySettings(first: false);
            if (tunerChanged) SetTunerMode(_settings.TunerMode);
            SetStatus("settings saved");
            AppLog.Action("settings", "saved");
        };
        w.ShowDialog(this);
    }

    /// Put the settings into effect: layout (at start), scale, fonts, colours, simulation options, ports, and the MCP server.
    void ApplySettings(bool first)
    {
        var s = _settings;
        if (first && _mainGrid != null && _centre != null)
        {
            GridLength G(string v, GridLength fallback) { try { return GridLength.Parse(v); } catch { return fallback; } }
            _mainGrid.ColumnDefinitions[0].Width = G(s.LeftColumn, new GridLength(3, GridUnitType.Star));
            _mainGrid.ColumnDefinitions[2].Width = G(s.CentreColumn, new GridLength(4, GridUnitType.Star));
            _mainGrid.ColumnDefinitions[4].Width = G(s.RightColumn, new GridLength(3, GridUnitType.Star));
            _centre.RowDefinitions[3].Height = G(s.BottomPanel, new GridLength(360));
            _package.SelectedIndex = s.Package == nameof(ChipView.Package.Qfp64) ? 1 : 0;
            if (s.SelectedTab.Length > 0) SelectTab(s.SelectedTab);
        }
        double scale = Math.Clamp(s.UiScale, 0.5, 3);
        _scaler.LayoutTransform = Math.Abs(scale - 1) < 0.001 ? null : new ScaleTransform(scale, scale);
        foreach (var (key, z) in _zoom) z.Zoom = s.Zoom(key);        // the source editor's zoom sets its font size
        _host.Speed = s.SpeedIndex switch { 0 => 0.1, 1 => 0.5, 2 => 1, 3 => 4, 4 => 0, _ => 1 };
        TableModel.SetColours(SettingsWindow.Parse(s.TableLow), SettingsWindow.Parse(s.TableMid), SettingsWindow.Parse(s.TableHigh),
            SettingsWindow.Parse(s.TableMax), SettingsWindow.Parse(s.TraceColour), SettingsWindow.Parse(s.TrailColour));
        CodeEditor.SetHitColours(SettingsWindow.Parse(s.HitCodeColour), SettingsWindow.Parse(s.HitDataColour));
        _host.FastBoot = s.FastBoot;
        _calibration.SetOptions(s.LiveTrace, s.FollowReads, s.TrailSeconds);
        _calibration.TargetLow = TargetMap.Parse(s.AfrTargetLow);
        _calibration.TargetHigh = TargetMap.Parse(s.AfrTargetHigh);
        _calibration.WidebandCorrection = LookupCurve.Parse(s.WidebandCorrection);
        _datalog.Port = s.DatalogPort; _datalog.Baud = s.DatalogBaud; _datalog.Protocol = s.DatalogProtocol;
        if (s.DetectedLayout is { Length: > 0 } dl)
            try { _datalog.Engine.Detected = System.Text.Json.JsonSerializer.Deserialize<OkiRomSim.Calibration.DetectedProtocol>(dl); }
            catch (Exception ex) { AppLog.Error("datalog", "saved layout could not be read", ex); }
        _datalog.DriveSimulator = s.DatalogDrivesSimulator;
        _external.Start(s.ExternalFeeds);
        _datalog.Gauges.External = _external;
        var eng = _datalog.Engine;
        eng.IntervalMs = s.DatalogIntervalMs; eng.KeepFrames = s.DatalogKeepFrames;
        var curves = ParseNamedCurves(s.AnalogCurves);
        eng.AuxChannels = s.AuxChannels.Select(a =>
        {
            var ch = a.ToChannel();
            if (curves.TryGetValue(ch.Name, out var curve)) ch.Curve = curve;
            return ch;
        }).ToList();
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
        _calibration.EmulatorPort = s.MoatesPort;
        if (first) _host.AutoUpload = s.EmulatorAutoUpload;
        _calibration.UpdateEmulator();
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

    Dictionary<string, KeyGesture> _hotKeys = new();
    /// Readings polled from outside the ECU (Settings > Datalog), shown on the gauges.
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
            var cols = _expanded && _savedColumns != null ? _savedColumns : _mainGrid.ColumnDefinitions.Select(c => c.Width).ToArray();
            var rows = _expanded && _savedRows != null ? _savedRows : _centre.RowDefinitions.Select(r => r.Height).ToArray();
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
            var session = new AppMcpSession(_host, _datalog,
                () => { if (_current != null) _buffers[_current] = _editor.Text ?? ""; return _buffers.Select(kv => (kv.Key, kv.Value)).ToList(); },
                m => Dispatcher.UIThread.Post(() => SetStatus(m)),
                () => (_settings.DatalogPort, _settings.DatalogProtocol, _settings.DatalogBaud),
                (rom, name) => OpenRomImage(rom, name));
            var workspace = new OkiRomSim.Mcp.Workspace(roots) { ReadOnly = s.McpReadOnly };
            // an agent on another machine can ask for a folder here; the user decides
            workspace.AskToAddRoot = (folder, why) => Dispatcher.UIThread.Invoke(async () =>
            {
                bool yes = await Dialogs.Confirm(this, "Let an agent read this folder?",
                    $"An MCP agent is asking to use files in:\n\n{folder}\n\nWhy: {why}\n\n" +
                    "Allowing it lets the agent read (and, unless the server is read-only, write) files in that folder until this program is closed.",
                    "Allow", "Refuse");
                AppLog.Write(LogKind.Mcp, "mcp", $"workspace_allow {folder}: {(yes ? "allowed" : "refused")}", why);
                if (yes) { _settings.McpRoots = _settings.McpRoots.Append(folder).Distinct().ToList(); _settings.Save(); }
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
    readonly HashSet<ListBox> _updatingLists = new();
    readonly Dictionary<ListBox, string> _lastItems = new();

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
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(4) };
        bar.Children.Add(new TextBlock { Text = "Address ", VerticalAlignment = VerticalAlignment.Center });
        Tip(_memAddr, "Start address (hex) or a label.");
        bar.Children.Add(_memAddr);
        bar.Children.Add(ToolButton("Go", RefreshMemory, "Show 256 bytes from the address."));
        bar.Children.Add(Small("  RAM 0000-0FFF, ROM above 0480"));
        Tip(_memory, "Live hex dump; refreshes while this tab is open.");
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(bar, 0); g.Children.Add(bar);
        Grid.SetRow(_memory, 1); g.Children.Add(_memory);
        return g;
    }

    Control BreakpointPanel()
    {
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(4) };
        var box = Tip(Mono(new TextBox { Watermark = "label or address", Width = 220 }), "Label or hex address to set or clear a breakpoint on.");
        bar.Children.Add(box);
        bar.Children.Add(ToolButton("Toggle", () =>
        {
            var r = _host.ToggleBreakpoint(box.Text ?? "");
            SetStatus(r.ok ? $"breakpoint {(r.enabled ? "set" : "cleared")} at {Hex(r.address)}" : r.error);
        }, "Set or clear a breakpoint at the label/address typed."));
        bar.Children.Add(ToolButton("Clear all", () => _host.ClearBreakpoints(), "Remove every breakpoint."));
        bar.Children.Add(Small("  double-click a disassembly line to toggle, F9 toggles at the caret"));
        _bpList.DoubleTapped += (_, _) =>
        {
            var s = _host.State();
            int i = _bpList.SelectedIndex;
            if (i >= 0 && i < s.Breakpoints.Count) GoToAddress(s.Breakpoints[i].Address);
        };
        Tip(_bpList, "Breakpoints. Double-click one to show it in the source.");
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(bar, 0); g.Children.Add(bar);
        Grid.SetRow(_bpList, 1); g.Children.Add(_bpList);
        return g;
    }

    Control LookupPanel()
    {
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(4) };
        Tip(_lookupQ, "Type a label, a calibration name or an address; Enter looks it up.");
        bar.Children.Add(_lookupQ);
        bar.Children.Add(ToolButton("Look up", DoLookup, "Find labels and settings matching the text, or what lives at an address."));
        bar.Children.Add(ToolButton("Find references", DoXref, "List every instruction that reads or writes the address."));
        _lookupQ.KeyDown += (_, e) => { if (e.Key == Key.Enter) DoLookup(); };
        _lookupList.FontFamily = MonoFont;
        _lookupList.DoubleTapped += (_, _) =>
        {
            int i = _lookupList.SelectedIndex;
            if (i >= 0 && i < _lookupRows.Count) GoToAddress(_lookupRows[i].Address);
            else if (i >= 0 && i < _lookupLines.Count && int.TryParse(_lookupLines[i].Split(' ')[0], NumberStyles.HexNumber, null, out var a)) GoToAddress(a);
        };
        Tip(_lookupList, "Results. Double-click one to go to it in the source (and the disassembly).");
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(bar, 0); g.Children.Add(bar);
        Grid.SetRow(_lookupList, 1); g.Children.Add(_lookupList);
        return g;
    }

    void BuildInputs()
    {
        (string key, string label, double min, double max, double val, string tip)[] defs =
        {
            ("rpm", "RPM", 0, 9000, 800, "Engine speed: drives the crank (CKP), TDC and CYP signals."),
            ("map", "MAP kPa", 10, 250, 33, "Manifold pressure on AI6."),
            ("tps", "TPS %", 0, 100, 0, "Throttle position on AI7 (0.5-4.5 V)."),
            ("ect", "ECT °C", -40, 120, 85, "Coolant temperature (thermistor on mux A channel 0)."),
            ("iat", "IAT °C", -40, 120, 25, "Intake air temperature (thermistor on mux A channel 7)."),
            ("o2", "O2 V", 0, 1, 0.45, "Oxygen sensor voltage (mux B channel 0)."),
            ("vbatt", "Battery V", 8, 16, 14.2, "Battery voltage (AI5)."),
            ("speed", "km/h", 0, 250, 0, "Road speed: drives the vehicle speed sensor pulses on INT0."),
        };
        foreach (var (key, label, min, max, val, tip) in defs)
        {
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("68,*,50"), Margin = new Thickness(0, -3) };
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
        var crank = Tip(new CheckBox { Content = "cranking (starter on)", FontSize = 10.5, Margin = new Thickness(0, 0, 16, 0) },
            "Starter engaged: battery sags. Start at a few hundred rpm for a realistic engine start.");
        crank.IsCheckedChanged += (_, _) => _host.SetInput("cranking", crank.IsChecked == true ? 1 : 0);
        var oil = Tip(new CheckBox { Content = "VTEC oil pressure", FontSize = 10.5, IsChecked = true },
            "Oil pressure reaches the VTEC spool when the solenoid opens; untick to simulate a failed switch or low oil.");
        oil.IsCheckedChanged += (_, _) => _host.SetInput("oilpressure", oil.IsChecked == true ? 1 : 0);
        _host.SetInput("oilpressure", 1);
        checks.Children.Add(crank); checks.Children.Add(oil);
        _crankBox = crank; _oilBox = oil;
        _inputs.Children.Add(checks);
    }
    readonly Dictionary<string, Slider> _sliders = new();
    readonly Dictionary<string, double> _defaults = new();
    CheckBox? _crankBox, _oilBox;
    bool _syncingSliders;

    void ResetInputs()
    {
        foreach (var (k, v) in _defaults)
            if (_sliders.TryGetValue(k, out var sl)) { sl.Value = v; _host.SetInput(k, v); }
        _host.SetInput("baro", 101);
        if (_crankBox != null) _crankBox.IsChecked = false;
        if (_oilBox != null) _oilBox.IsChecked = true;
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
        if (!path.EndsWith(".asm", StringComparison.OrdinalIgnoreCase)) return false;
        return !SamePath(path, _target) && !(_host.Assembly?.SourceMap.Any(e => SamePath(e.File, path)) ?? false);
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

    /// Open a .asm (edit and build it), a .bin/.rom (disassemble it to source, then build that, so the simulator runs exactly the image's bytes with labels and line tracking), or a saved project .zip.
    void OpenFile(string path)
    {
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
                _target = path;
                Build();
            }
        }
        catch (Exception ex) { SetStatus(ex.Message); }
    }

    /// A ROM image that came from somewhere other than a file the user picked (the PROG entry of an .rlog, or an MCP agent uploading one): keep it beside the log / in the temp folder and open it like any other .bin.
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

    void OpenBinary(string path)
    {
        var bytes = File.ReadAllBytes(path);
        ResetForNewRom(path);
        if (bytes.Length == Bus.RomSize + 1 && bytes[^1] == 0) bytes = bytes[..Bus.RomSize];
        if (bytes.Length > Bus.RomSize)
        { SetStatus($"{Label(path)} is {bytes.Length} bytes; a 66207 ROM image is at most {Bus.RomSize}"); return; }
        string note = bytes.Length < Bus.RomSize ? $" (short image, padded from {bytes.Length} bytes with FF)" : "";

        var asmPath = Path.ChangeExtension(path, ".asm");
        if (File.Exists(asmPath)) asmPath = Path.ChangeExtension(path, ".disasm.asm");
        SetStatus("disassembling…");
        var dis = BinDisassembler.Disassemble(bytes, Path.GetFileName(path), text =>
        {
            var r = new OkiAssembler(new AssemblerOptions { ReadFile = f => f == Path.GetFullPath(asmPath) ? text : null })
                .AssembleText(text, asmPath);
            return (r.Success ? r.Image : null, r.Diagnostics.Where(d => d.Severity == Severity.Error).Select(d => d.Line));
        });
        _buffers[asmPath] = dis.Text;
        _dirty.Add(asmPath);
        _target = asmPath;
        ShowBuffer(asmPath);
        Build();
        SetStatus($"{Label(path)}: {dis.CodeInstructions:N0} instructions found by following the code, " +
                  $"{dis.DataBytes:N0} bytes kept as data" +
                  (dis.RoundTrips ? "; rebuilds byte-identical" : " -- " + dis.Note) + note +
                  $". Unsaved: Ctrl+S writes {Label(asmPath)}", sticky: true);
    }

    /// Opening another ROM: forget the one before it (definitions, undo, hits, traces, its source buffers), so Detect and the Calibration page cannot mix the two.
    void ResetForNewRom(string path)
    {
        var keep = Path.GetFullPath(path);
        foreach (var k in _buffers.Keys.ToList())
            if (!SamePath(k, keep) && !_dirty.Contains(k)) _buffers.Remove(k);
        _diags.Clear();
        _problemLoc.Clear();
        SetItems(_problems, Array.Empty<string>());
        _builtTexts = new();
        _builtImage = null;
        _lookupRows = new(); _lookupLines = new();
        SetItems(_lookupList, Array.Empty<string>());
        _lastSourceShown = ""; _lastPcShown = -1;
        _host.ResetRomState();
        _calibration.ResetForNewRom();
        _trace.Text = "";
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
        SetItems(_problems, Array.Empty<string>());
        _lookupRows = new(); _lookupLines = new();
        SetItems(_lookupList, Array.Empty<string>());
        SetItems(_disasm, Array.Empty<string>());
        SetItems(_bpList, Array.Empty<string>());
        _builtTexts = new(); _builtImage = null;
        _suppressEdit = true;
        _editor.Text = "";
        _suppressEdit = false;
        _editor.SetDiagnostics(new List<(int, bool)>());
        _editor.SetHits(null);
        _trace.Text = ""; _memory.Text = "";
        _calibration.ResetForNewRom();
        _datalog.ClearAll();
        _settings.LastFile = null;
        UpdateDocHeader();
        UpdateBuildButton(false, "Nothing to build yet: open a .asm or .bin.");
        SetStatus("project cleared: no ROM open, memory released");
    }

    void ShowBuffer(string path)
    {
        if (_current != null && _buffers.ContainsKey(_current)) _buffers[_current] = _editor.Text ?? "";
        _current = path;
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
        _buffers[_current] = _editor.Text ?? "";
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
        _buffers[_current] = _editor.Text;
        File.WriteAllText(_current, _editor.Text);
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
            FileTypeChoices = new[] { new FilePickerFileType("Assembler source") { Patterns = new[] { "*.asm" } } },
        });
        var path = file?.TryGetLocalPath();
        if (path == null) return;
        var text = _editor.Text ?? "";
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

    // ------------------------------------------------------------------ build

    string? ReadBuffer(string fullPath) => _buffers.FirstOrDefault(kv => SamePath(kv.Key, fullPath)).Value;

    void Build()
    {
        if (_current != null) _buffers[_current] = _editor.Text ?? "";
        UpdateDocHeader();
        var target = _target ?? _current;
        if (target == null || !target.EndsWith(".asm", StringComparison.OrdinalIgnoreCase))
        { SetStatus("open a .asm (or a .bin) to build"); return; }

        SetStatus("building…");
        var res = _host.Build(target, ReadBuffer);
        _diags = res.Diagnostics;
        var ordered = _diags.OrderByDescending(d => d.Severity).ToList();
        _problemLoc = ordered.Select(d => (d.File, d.Line)).ToList();
        SetItems(_problems, ordered.Select(d => $"{d.Severity.ToString().ToLowerInvariant(),-7} {Path.GetFileName(d.File)}:{d.Line}  {d.Message}"));
        if (res.Success && res.Assembly != null)
        {
            // remember exactly what was built, to tell later whether the screen differs
            var files = res.Assembly.SourceMap.Select(e => e.File).Append(Path.GetFullPath(target)).Distinct(StringComparer.OrdinalIgnoreCase);
            _builtTexts = files.ToDictionary(f => f, f => ReadBuffer(f) ?? (File.Exists(f) ? File.ReadAllText(f) : ""), StringComparer.OrdinalIgnoreCase);
            _builtImage = res.Assembly.Image.ToArray();
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
                    _problemLoc = ordered2.Select(d => (d.File, d.Line)).ToList();
                    SetItems(_problems, ordered2.Select(d => $"{d.Severity.ToString().ToLowerInvariant(),-7} {Path.GetFileName(d.File)}:{d.Line}  {d.Message}"));
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
            if (_current != null) _buffers[_current] = _editor.Text ?? "";
            var (machine, ram, rom) = _host.SaveState();
            var s = _host.State();
            RefreshMemory();
            var p = new ProjectData
            {
                Target = _target, Current = _current, CaretLine = _editor.CaretLine, FirstVisibleLine = _editor.FirstVisibleLine,
                Sources = _buffers.Select(kv => new ProjectSource { Path = kv.Key, Text = kv.Value, Unsaved = _dirty.Contains(kv.Key) }).ToList(),
                MemoryAddress = _memAddr.Text ?? "", DisassemblyAddress = _disAddr.Text ?? "",
                LookupQuery = _lookupQ.Text ?? "", LookupLines = _lookupLines.ToList(),
                SelectedTab = SelectedTab(), SpeedIndex = _settings.SpeedIndex,
                Package = _chip.CurrentPackage.ToString(), CrystalMHz = Bus.CrystalMHz,
                Machine = machine, Ram = ram, Rom = rom, Definitions = _host.Defs(),
                ProcessorJson = _profile.ToJson(),
                SettingsJson = System.Text.Json.JsonSerializer.Serialize(_settings.RomScoped(), new System.Text.Json.JsonSerializerOptions { WriteIndented = true }),
            };
            p.Views["trace.txt"] = _trace.Text ?? "";
            p.Views["memory.txt"] = _memory.Text ?? "";
            p.Views["lookup.txt"] = string.Join("\n", _lookupLines);
            p.Views["breakpoints.txt"] = string.Join("\n", s.Breakpoints.Select(b => $"{Hex(b.Address)}  {b.Label}  {b.Source}"));
            p.Views["problems.txt"] = string.Join("\n", _diags.Select(d => d.ToString()));
            p.Views["registers.txt"] = (_regs.Text ?? "") + "\n" + (_flags.Text ?? "") + "\n\ncall stack:\n" + (_calls.Text ?? "");
            p.Views["outputs.txt"] = (_outputs.Text ?? "") + "\n\n" + (_ports.Text ?? "");
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
        _lookupLines = p.LookupLines; _lookupRows = new();
        SetItems(_lookupList, _lookupLines);
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
        SetStatus($"project restored from {Label(path)}: {p.Sources.Count} source file(s), machine state, calibration and views", sticky: true);
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
        ToolTip.SetTip(_status, text);
        _sticky = sticky ? text : "";
    }

    string _lastLogged = "";

    void SelectTab(string header)
    {
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
        var s = _host.State();
        if (_tuner)
        {
            _datalog.Tick(null);
            _calibration.Tick();
            _calibration.UpdateEmulator();
            _calibration.SetOverlayChannels(_datalog.Channels(), _settings.OverlayChannel);
            if (_datalog.Engine.Running) _calibration.UpdateOverlay(throttle: true);
            return;
        }
        bool sidePanes = !_expanded;
        if (!sidePanes) goto Lower;
        _regs.Text =
            $"PC   {Hex(s.Pc)} {s.Label}\n" +
            $"A    {Hex(s.A)}   DP {Hex(s.Dp)}   X1 {Hex(s.X1)}   X2 {Hex(s.X2)}\n" +
            $"USP  {Hex(s.Usp)}   SSP {Hex(s.Ssp)}   LRB {Hex(s.Lrb)} -> {Hex(s.Bank, 3)}\n" +
            $"PSW  {Hex(s.Psw)}   er {string.Join(" ", s.Er.Select(v => Hex(v)))}\n" +
            $"{s.SimSeconds:F3} s simulated · {s.Instructions:N0} instructions" +
            (s.Running && s.Rate > 0 ? $" · {s.Rate:N0}/s" : "");
        _flags.Text = $"CY {(s.Cy ? 1 : 0)}  Z {(s.Z ? 1 : 0)}  HC {(s.Hc ? 1 : 0)}  DD {(s.Dd ? 1 : 0)}  MIE {(s.Mie ? 1 : 0)}  SCB {s.Scb}   IRQ {Hex(s.Irq)}  IE {Hex(s.Ie)}";
        _hot.Text = s.HotWindow > 0
            ? $"hot {Hex(s.HotAddress)} {_host.NearestLabel(s.HotAddress)} {100.0 * s.HotCount / s.HotWindow:F0}% of the recent window · coverage {s.Coverage} addresses"
            : "";
        var calls = s.Calls.Count == 0 ? new List<string> { "(top level)" } : s.Calls.Take(24).ToList();
        while (calls.Count < CallStackLines) calls.Add("");
        _calls.Text = string.Join("\n", calls);
        _outputs.Text = OutputsText(s.Outputs);
        _ports.Text = PortsText(s);
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
        if (tab == "Trace") _trace.Text = string.Join("\n", s.Trace.Select(t => $"{Hex(t.Pc)}  {t.Label,-22} {t.Text}"));
        if (tab == "Breakpoints") SetItems(_bpList, s.Breakpoints.Select(b => $"{Hex(b.Address)}  {b.Label,-24} {b.Source}"));

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
        if (tab == "Memory") RefreshMemory();
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
            case "Hit trace": _hitView.Tick(s); break;
            case "Datalog": _datalog.Tick(s); break;
            case "Debug": _debug.Tick(); break;
        }
        if ((DateTime.UtcNow - _lastHitPaint).TotalMilliseconds > 500)
        {
            _lastHitPaint = DateTime.UtcNow;
            _editor.SetHits(_current != null && _hitView.ColourSource && SelectedTab() == "Hit trace" ? _hitView.LineHits(_current) : null);
        }
    }
    int _lastStepSerial;
    DateTime _lastHitPaint;

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

    static string OutputsText(SimHost.OutputState o)
    {
        var sb = new System.Text.StringBuilder();
        string Ago(double ms) => ms < 0 ? "never" : ms < 1000 ? $"{ms:F0} ms ago" : $"{ms / 1000:F1} s ago";
        sb.AppendLine($"Fuel pump relay  8255 PB7 (P0.7)  {(o.FuelPump ? "ON " : "off")}");
        sb.AppendLine($"VTEC solenoid    8255 PC0 (P1.0)  {(o.Vtec ? "ON " : "off")}   P4.6 {(o.VtecPressure ? "low" : "high")}");
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
        _disasmAddrs = lines.Select(l => l.Addr).ToList();
        SetItems(_disasm, lines.Select(l =>
            (l.Bp ? "●" : " ") + (l.Current ? "▶" : " ") + $"{Hex(l.Addr)}  {l.Bytes,-10} {(l.Label.Length > 0 ? l.Label + ": " : "")}{l.Text}"));
        int cur = lines.FindIndex(l => l.Current);
        if (cur >= 0 && from == null)
            Dispatcher.UIThread.Post(() => { try { _disasm.ScrollIntoView(cur); } catch { } }, DispatcherPriority.Background);
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
            sb.Append(Hex(addr + row * 16)).Append("  ");
            for (int c = 0; c < 16; c++) sb.Append(bytes[row * 16 + c].ToString("X2")).Append(' ');
            sb.Append(' ');
            for (int c = 0; c < 16; c++)
            {
                byte v = bytes[row * 16 + c];
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
            ? new List<string> { "nothing matches" }
            : rows.Select(r => $"{Hex(r.Address)}  {r.Name}{(r.Offset != 0 ? " + " + r.Offset : "")}   {r.Kind}").ToList();
        SetItems(_lookupList, _lookupLines);
    }

    void DoXref()
    {
        var hits = _host.Xref(_lookupQ.Text ?? "");
        _lookupRows = hits.Select(h => (h.Label, h.Address, 0, h.Kind)).ToList();
        _lookupLines = hits.Count == 0
            ? new List<string> { "no references found (or the target could not be resolved)" }
            : hits.Select(h => $"{Hex(h.Address)}  {h.Label,-22} {h.Text,-32} {h.Source}").ToList();
        SetItems(_lookupList, _lookupLines);
    }

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
