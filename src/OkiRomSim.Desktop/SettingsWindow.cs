// Copyright (c) bmgjet. All rights reserved.
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Settings: appearance, panel zoom, colours, hot keys, datalogging (ports, protocol, wideband, aux channels), hit trace and the ROM emulator, the processor profile, and the MCP server for LLM agents. Works on a copy; Save hands it back and the main window applies it.
public sealed class SettingsWindow : Window
{
    readonly AppSettings _s;
    readonly Func<string> _mcpStatus;
    public AppSettings? Result { get; private set; }
    /// Set when the processor profile was edited or another one picked.
    public ProcessorProfile? ResultProfile { get; private set; }
    ProcessorProfile _profile;
    string _profileJson;

    /// The RPM and load breakpoints of the ROM's own fuel map, so a target table can be laid out against the very same axes the map is tuned on (which is what makes the two comparable). Empty when nothing is open, in which case a sensible default shape is offered.
    readonly Func<(double[] Rpm, double[] Load)>? _mapAxes;

    public SettingsWindow(AppSettings current, Func<string> mcpStatus, ProcessorProfile profile,
                          Func<(double[] Rpm, double[] Load)>? mapAxes = null)
    {
        _mapAxes = mapAxes;
        _s = current.Clone();
        _s.McpPassword = current.McpPassword;
        _mcpStatus = mcpStatus;
        _profile = profile;
        _profileJson = profile.ToJson();
        Title = "Settings";
        Width = 800; Height = 660; MinWidth = 560; MinHeight = 460;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var chrome = DarkChrome.Apply(this, "Settings");

        var tabs = new TabControl
        {
            Margin = new Thickness(8, 4), TabStripPlacement = Dock.Left,
            // one column of pages: the default wrapping strip split into two columns on a short window and took half the width
            ItemsPanel = new Avalonia.Controls.Templates.FuncTemplate<Panel?>(() => new StackPanel()),
        };
        tabs.Items.Add(Page("General", General()));
        tabs.Items.Add(Page("Panel zoom", Zoom(), out var zoomBar));
        zoomBar.Children.Add(Button("Reset every panel to 100%", () => { _s.PanelZoom.Clear(); Reopen(tabs, "Panel zoom", Zoom()); }));
        tabs.Items.Add(Page("Colours", Colours(), out var colourBar));
        colourBar.Children.Add(Button("Reset colours", () =>
        {
            var d = new AppSettings();
            _s.TableLow = d.TableLow; _s.TableMid = d.TableMid; _s.TableHigh = d.TableHigh; _s.TableMax = d.TableMax;
            _s.TraceColour = d.TraceColour; _s.TrailColour = d.TrailColour; _s.HitCodeColour = d.HitCodeColour; _s.HitDataColour = d.HitDataColour;
            Reopen(tabs, "Colours", Colours());
        }));
        tabs.Items.Add(Page("Hot keys", HotKeys(), out var keyBar));
        keyBar.Children.Add(Button("Reset hot keys", () => { _s.HotKeys = AppSettings.DefaultHotKeys(); Reopen(tabs, "Hot keys", HotKeys()); }));
        tabs.Items.Add(Page("Datalog", Datalog()));
        tabs.Items.Add(Page("Targets", Targets(), out var targetBar));
        tabs.Items.Add(Page("Corrections", Corrections()));
        targetBar.Children.Add(Button("Start from a sensible AFR table", () =>
        {
            _s.AfrTargetLow = TargetMap.Default().ToText();
            if (_s.AfrTargetHigh.Trim().Length == 0) _s.AfrTargetHigh = _s.AfrTargetLow;
            Reopen(tabs, "Targets", Targets());
        }));
        tabs.Items.Add(Page("Hit trace & emulator", Emulator()));
        tabs.Items.Add(Page("Processor", Processor(), out var procBar));
        tabs.Items.Add(Page("MCP server", Mcp()));
        _procBar = procBar;
        FillProcessorBar();

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(8), Spacing = 6 };
        var save = new Button { Content = "Save", IsDefault = true, MinWidth = 90 };
        save.Click += (_, _) => Save();
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90 };
        cancel.Click += (_, _) => Close();
        var apply = new Button { Content = "Apply", MinWidth = 90 };
        apply.Click += (_, _) => Apply();
        buttons.Children.Add(cancel); buttons.Children.Add(apply); buttons.Children.Add(save);
        ToolTip.SetTip(save, "Keep these settings and apply them now.");
        ToolTip.SetTip(apply, "Show the changes now (UI scale, colours, zoom...) without keeping them: Save keeps them, Cancel puts back what was there.");
        ToolTip.SetTip(cancel, "Close without keeping anything, and undo whatever Apply showed.");

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(tabs, 1); g.Children.Add(tabs);
        Grid.SetRow(buttons, 2); g.Children.Add(buttons);
        Content = g;

        // never taller than the screen: on a small or scaled display the bottom used to be unreachable
        Opened += (_, _) =>
        {
            if (Screens.ScreenFromWindow(this) is { } scr)
            {
                double avail = scr.WorkingArea.Height / scr.Scaling;
                if (Height > avail * 0.92) Height = avail * 0.92;
                double availW = scr.WorkingArea.Width / scr.Scaling;
                if (Width > availW * 0.95) Width = availW * 0.95;
            }
        };
    }

    readonly WrapPanel _procBar;

    /// Apply was pressed: the settings as they stand (a copy - the page keeps editing its own), and the processor profile when it changed.
    public event Action<AppSettings, ProcessorProfile?>? Applied;

    bool TakeProfile()
    {
        ResultProfile = null;
        if (_profileJson != _profile.ToJson())
        {
            try { ResultProfile = ProcessorProfile.FromJson(_profileJson); }
            catch (Exception ex) { _procError.Text = "The processor profile is not valid JSON: " + ex.Message; return false; }
        }
        else if (!ReferenceEquals(_profile, ProcessorProfile.Current)) ResultProfile = _profile;
        return true;
    }

    void Apply()
    {
        if (!TakeProfile()) return;
        var copy = _s.Clone();
        copy.McpPassword = _s.McpPassword;
        Applied?.Invoke(copy, ResultProfile);
    }

    void Save()
    {
        if (!TakeProfile()) return;
        Result = _s;
        Close();
    }

    // ------------------------------------------------------------------ layout helpers

    static TabItem Page(string header, Control content) => Page(header, content, out _);

    /// A page: a fixed bar for its actions at the top (never scrolled away), then the content in a scroller with room left for the scroll bar and below the last row.
    static TabItem Page(string header, Control content, out WrapPanel actions)
    {
        actions = new WrapPanel { Margin = new Thickness(4, 4, 4, 2), ItemSpacing = 6, LineSpacing = 4 };
        var scroller = new ScrollViewer
        {
            Content = new Border { Child = content, Padding = new Thickness(4, 6, 22, 28) },
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled,
        };
        var dock = new DockPanel();
        DockPanel.SetDock(actions, Dock.Top);
        dock.Children.Add(actions);
        dock.Children.Add(scroller);
        return new TabItem { Header = new TextBlock { Text = header, FontSize = 12.5 }, Content = dock, Tag = header, MinHeight = 30, Padding = new Thickness(10, 3) };
    }

    static void Reopen(TabControl tabs, string header, Control content)
    {
        var tab = tabs.Items.OfType<TabItem>().First(t => (string?)t.Tag == header);
        if (tab.Content is DockPanel d && d.Children.OfType<ScrollViewer>().FirstOrDefault() is { } sv && sv.Content is Border b) b.Child = content;
    }

    static Button Button(string text, Action a)
    {
        var b = new Button { Content = text };
        b.Click += (_, _) => a();
        return b;
    }

    static Control Row(string label, Control editor, string tip)
    {
        var l = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 8, 0) };
        editor.HorizontalAlignment = HorizontalAlignment.Left;
        var row = new FormRow { Margin = new Thickness(0, 3) };
        row.Children.Add(l);
        row.Children.Add(editor);
        ToolTip.SetTip(row, tip);
        return row;
    }

    /// A label and its editor side by side; the label column narrows (and wraps) with the window, and when the editor still would not fit beside it the editor goes underneath - so it is never pushed out of sight or drawn over its label.
    sealed class FormRow : Panel
    {
        bool _stacked;
        double _labelW;

        protected override Size MeasureOverride(Size avail)
        {
            if (Children.Count < 2) return default;
            Control label = Children[0], editor = Children[1];
            double w = double.IsInfinity(avail.Width) ? 600 : avail.Width;
            _labelW = Math.Clamp(w * 0.38, 110, 230);
            editor.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            double natural = double.IsNaN(editor.Width) ? editor.DesiredSize.Width : editor.Width + editor.Margin.Left + editor.Margin.Right;
            _stacked = natural > w - _labelW + 0.5;
            if (_stacked)
            {
                label.Measure(new Size(w, double.PositiveInfinity));
                editor.Measure(new Size(w, double.PositiveInfinity));
                return new Size(w, label.DesiredSize.Height + editor.DesiredSize.Height + 2);
            }
            label.Measure(new Size(_labelW, double.PositiveInfinity));
            editor.Measure(new Size(w - _labelW, double.PositiveInfinity));
            return new Size(w, Math.Max(label.DesiredSize.Height, editor.DesiredSize.Height));
        }

        protected override Size ArrangeOverride(Size size)
        {
            if (Children.Count < 2) return size;
            Control label = Children[0], editor = Children[1];
            if (_stacked)
            {
                double lh = label.DesiredSize.Height;
                label.Arrange(new Rect(0, 0, size.Width, lh));
                editor.Arrange(new Rect(0, lh + 2, size.Width, Math.Max(0, size.Height - lh - 2)));
            }
            else
            {
                label.Arrange(new Rect(0, 0, _labelW, size.Height));
                editor.Arrange(new Rect(_labelW, 0, Math.Max(0, size.Width - _labelW), size.Height));
            }
            return size;
        }
    }

    static TextBlock Note(string t) => new() { Text = t, FontSize = 11, Opacity = 0.75, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6) };

    /// A heading that starts a new block on a settings page. `Grouped` turns each one, and the rows that follow it, into a box of its own, so a page reads as a handful of named groups rather than one long column of rows - which is how the established tuning software lays its settings out, and how anyone looking for one of them expects to find it.
    static TextBlock Section(string t) => new()
    {
        Text = t, FontSize = 12, FontWeight = FontWeight.Bold, Margin = new Thickness(0, 12, 0, 2), Tag = SectionTag,
    };

    const string SectionTag = "section";

    /// Break a page at its Section headings and put each block in a titled box. Rows before the first heading go in a box of their own with no title.
    static Control Grouped(StackPanel page)
    {
        var children = page.Children.ToList();
        page.Children.Clear();
        var outer = new StackPanel();
        StackPanel? body = null;

        void Start(string? title)
        {
            body = new StackPanel { Margin = new Thickness(12, title == null ? 8 : 4, 10, 10) };
            var box = new StackPanel();
            if (title != null)
                box.Children.Add(new TextBlock { Text = title, FontWeight = FontWeight.Bold, FontSize = 12, Margin = new Thickness(12, 8, 0, 0) });
            box.Children.Add(body);
            outer.Children.Add(new Border
            {
                BorderBrush = new SolidColorBrush(Color.FromArgb(64, 255, 255, 255)),
                BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4),
                Margin = new Thickness(0, 0, 0, 10), Child = box,
            });
        }

        foreach (var c in children)
        {
            if (c is TextBlock tb && (tb.Tag as string) == SectionTag) { Start(tb.Text); continue; }
            if (body == null) Start(null);
            body!.Children.Add(c);
        }
        return outer;
    }

    static CheckBox Check(string text, bool value, Action<bool> set, string tip)
    {
        var c = new CheckBox { Content = text, IsChecked = value, Margin = new Thickness(0, 3) };
        c.IsCheckedChanged += (_, _) => set(c.IsChecked == true);
        ToolTip.SetTip(c, tip);
        return c;
    }

    /// "name = source | 500ms | path" per line.
    public static List<ExternalFeedSettings> ParseFeeds(string text)
    {
        var list = new List<ExternalFeedSettings>();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var parts = line.Split('|');
            int eq = parts[0].IndexOf('=');
            if (eq <= 0) continue;
            var feed = new ExternalFeedSettings { Name = parts[0][..eq].Trim(), Source = parts[0][(eq + 1)..].Trim() };
            for (int i = 1; i < parts.Length; i++)
            {
                var bit = parts[i].Trim();
                if (bit.EndsWith("ms", StringComparison.OrdinalIgnoreCase) && int.TryParse(bit[..^2].Trim(), out var ms)) feed.IntervalMs = ms;
                else if (int.TryParse(bit, out var ms2)) feed.IntervalMs = ms2;
                else feed.Path = bit;
            }
            if (feed.Name.Length > 0 && feed.Source.Length > 0) list.Add(feed);
        }
        return list;
    }

    /// Select `port` in a port box, adding it when it was not in the list.
    static void SetPort(ComboBox box, string port)
    {
        var list = (box.ItemsSource as IEnumerable<string> ?? []).ToList();
        if (!list.Contains(port)) { list.Add(port); box.ItemsSource = list; }
        box.SelectedItem = port;
    }

    /// Every datalog protocol on one port (each at its own baud rate, quickly): the one that answered, and why not otherwise.
    static (string? Protocol, string Why) ProbeDatalogPort(string port)
    {
        try
        {
            using var link = new SerialLink(port, 38400);
            var (p, report) = DatalogProtocol.Detect(link, quick: true);
            return (p?.Name, p != null ? "answered " + p.Name : report.Replace('\n', ' ').Trim());
        }
        catch (Exception ex) { return (null, ex.Message); }
    }

    /// The emulator version query on one port at each baud rate the devices use: the device, or null.
    static (string Port, string Device, int Baud)? ProbeEmulatorPort(string port)
    {
        foreach (var baud in new[] { 921600, 115200, 38400 })
        {
            using var m = new MoatesTrace { Kind = "auto", Baud = baud, Retries = 0, TimeoutMs = 250 };
            try
            {
                m.Connect(port);
                return (port, m.Device, baud);
            }
            catch (Exception ex) { AppLog.Write(LogKind.Serial, "emulator", $"detect {port} at {baud}: {ex.Message}"); }
        }
        return null;
    }

    static ComboBox PortBox(string current, IEnumerable<string>? extra, Action<string> set)
    {
        var list = (extra ?? []).Concat(SerialLink.Ports()).ToList();
        if (current.Length > 0 && !list.Contains(current)) list.Insert(0, current);
        var box = new ComboBox { ItemsSource = list, SelectedItem = current.Length > 0 ? current : list.FirstOrDefault(), Width = 180 };
        if (box.SelectedItem is string s0 && current.Length == 0) set(s0);
        box.SelectionChanged += (_, _) => set(box.SelectedItem as string ?? "");
        return box;
    }

    // ------------------------------------------------------------------ pages

    Control General()
    {
        var p = new StackPanel();
        var version = new TextBlock { Text = BuildInfo.Version, VerticalAlignment = VerticalAlignment.Center, FontFamily = MainWindow.MonoFont, IsHitTestVisible = true };
        p.Children.Add(Row("Version", version, "Which build of " + BuildInfo.Product + " this is. Quote it when reporting something so the version can be matched."));

        var scale = new Slider { Minimum = 0.6, Maximum = 2.0, Value = _s.UiScale, Width = 260, TickFrequency = 0.05, IsSnapToTickEnabled = true };
        // a slider that keeps the pointer captured swallows the next clicks (seen on X11, where Save then needed several presses): hand the pointer back as soon as it is released
        scale.PointerReleased += (_, e) => e.Pointer.Capture(null);
        scale.PointerCaptureLost += (_, _) => { };
        var scaleText = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0), Text = $"{_s.UiScale * 100:0}%" };
        var fit = new CheckBox { Content = "Fit to the screen", IsChecked = _s.FitToScreen, Margin = new Thickness(12, 0, 0, 0) };
        ToolTip.SetTip(fit, "Pick the UI scale and how the panels share the window for the screen the app is on - 80% on a 1366 x 768 laptop, 100% on 1080p and up - " +
                            "and pick again when it starts on a different screen. Moving the slider sets the scale yourself and turns this off.");
        bool settingFit = false;
        scale.PropertyChanged += (_, e) =>
        {
            if (e.Property != Slider.ValueProperty) return;
            _s.UiScale = scale.Value; scaleText.Text = $"{scale.Value * 100:0}%";
            if (!settingFit && fit.IsChecked == true) fit.IsChecked = false;
        };
        fit.IsCheckedChanged += (_, _) =>
        {
            _s.FitToScreen = fit.IsChecked == true;
            if (!_s.FitToScreen) return;
            // ticked again: show the scale this screen gets (Apply or Save lays the panels out for it too)
            _s.FittedFor = "";
            if ((Screens.ScreenFromWindow(this) ?? Screens.Primary) is { } scr)
            {
                settingFit = true;
                scale.Value = ScreenFit.ScaleFor(ScreenFit.Dip(scr));
                settingFit = false;
            }
        };
        var scaleRow = new WrapPanel();
        scaleRow.Children.Add(scale); scaleRow.Children.Add(scaleText); scaleRow.Children.Add(fit);
        p.Children.Add(Row("UI scale", scaleRow, "Size of everything in the app, on top of the display scaling. Each panel also zooms on its own with Ctrl + mouse wheel."));

        var font = new NumericUpDown { Minimum = 8, Maximum = 32, Increment = 1, Value = (decimal)_s.EditorFontSize, Width = 120, FormatString = "0" };
        font.ValueChanged += (_, e) => { if (e.NewValue is decimal d) _s.EditorFontSize = (double)d; };
        p.Children.Add(Row("Let the desktop draw the title bar",
            Check("", _s.SystemTitleBar, v => _s.SystemTitleBar = v, "Ticked: the window manager's own title bar (light on most Linux desktops). Unticked: the dark bar drawn here. Takes effect next time the program starts."),
            "Only needed on a Linux desktop whose window manager ignores the request to drop its title bar - if you end up with two bars, tick this."));

        var auto = new NumericUpDown { Minimum = 0, Maximum = 120, Increment = 1, Value = _s.AutoSaveMinutes, Width = 120, FormatString = "0" };
        auto.ValueChanged += (_, e) => { if (e.NewValue is decimal d) _s.AutoSaveMinutes = (int)d; };
        p.Children.Add(Row("Restore point every (minutes)", auto,
            "Save a restore point of the whole session in the background this often, so a crash costs at most this many minutes. 0 turns it off. File > Restore last auto save opens the newest one."));

        p.Children.Add(Row("Source editor font size", font, "Font size of the assembly source (Ctrl + wheel over the editor zooms it on top of this)."));

        p.Children.Add(Check("Tuner mode (the calibration editor as the main page, datalogging beside it)", _s.TunerMode, v => _s.TunerMode = v,
            "A simpler layout for tuning: no source, simulator or assembly panels. The live trace on the maps comes from the datalog."));
        p.Children.Add(Check("Reopen the last file at start", _s.ReopenLastFile, v => _s.ReopenLastFile = v, "Open the .asm/.bin/project you had open last time."));

        p.Children.Add(Section("Simulation"));
        var speed = new ComboBox { ItemsSource = new[] { "0.1x", "0.5x", "real time", "4x", "unlimited" }, SelectedIndex = Math.Clamp(_s.SpeedIndex, 0, 4), Width = 160 };
        speed.SelectionChanged += (_, _) => _s.SpeedIndex = speed.SelectedIndex;
        p.Children.Add(Row("Simulation speed", speed, "How fast the simulator runs relative to the real chip. Unlimited runs as fast as this PC allows (the window stays responsive)."));
        p.Children.Add(Check("Fast boot", _s.FastBoot, v => _s.FastBoot = v,
            "Skip through the ROM's boot delay loops (8 x 65,536 passes, about 4.5 s of ECU time - as long as the check-engine light stays on at key-on) " +
            "in no real time. The simulated clock, timers and crank signal still advance by exactly that time."));
        p.Children.Add(Check("Live trace on the Calibration page", _s.LiveTrace, v => _s.LiveTrace = v, "Colour the table cells the program reads."));
        p.Children.Add(Check("Follow reads when stepping", _s.FollowReads, v => _s.FollowReads = v, "When a step reads a defined table or setting, switch the Calibration page to it."));
        var trail = new NumericUpDown { Minimum = 0.1m, Maximum = 10, Increment = 0.1m, Value = (decimal)_s.TrailSeconds, Width = 120, FormatString = "0.0" };
        trail.ValueChanged += (_, e) => { if (e.NewValue is decimal d) _s.TrailSeconds = (double)d; };
        p.Children.Add(Row("Trace trail (seconds)", trail, "How long a table cell stays highlighted (fading) after the program read it, in simulated seconds."));
        p.Children.Add(Note($"Settings file: {AppSettings.FilePath}. Window size and position, panel sizes and zoom, and the selected tab are remembered automatically."));
        return Grouped(p);
    }

    static readonly (string Key, string Label)[] Panels =
    {
        ("Source", "Source editor"), ("Pinout", "Chip pinout"), ("Inputs", "Engine inputs"), ("Right", "CPU / disassembly / outputs"),
        ("Problems", "Problems"), ("Trace", "Trace"), ("Memory", "Memory"), ("Calibration", "Calibration"), ("Lookup", "Lookup / xref"),
        ("Breakpoints", "Breakpoints"), ("Datalog", "Datalog"), ("Hit trace", "Hit trace"), ("Debug", "Debug"), ("Tuner datalog", "Tuner mode datalog panel"),
    };

    Control Zoom()
    {
        var p = new StackPanel();
        p.Children.Add(Note("Hold Ctrl and turn the mouse wheel over a panel to zoom just that panel; the zoom is remembered. Or set it here."));
        foreach (var (key, label) in Panels)
        {
            var sl = new Slider { Minimum = 0.5, Maximum = 2.5, Value = _s.Zoom(key), Width = 240, TickFrequency = 0.05, IsSnapToTickEnabled = true };
            var txt = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0), Text = $"{_s.Zoom(key) * 100:0}%" };
            sl.PropertyChanged += (_, e) =>
            {
                if (e.Property != Slider.ValueProperty) return;
                _s.PanelZoom[key] = Math.Round(sl.Value, 2);
                txt.Text = $"{sl.Value * 100:0}%";
            };
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(sl); row.Children.Add(txt);
            p.Children.Add(Row(label, row, $"Zoom of the {label} panel."));
        }
        return Grouped(p);
    }

    Control Colours()
    {
        var p = new StackPanel();
        void Colour(string label, Func<string> get, Action<string> set, string tip)
        {
            var picker = new ColorPicker { Color = Parse(get()), Width = 90 };
            picker.PropertyChanged += (_, e) =>
            {
                if (e.Property == ColorView.ColorProperty) set($"#{picker.Color.R:X2}{picker.Color.G:X2}{picker.Color.B:X2}");
            };
            p.Children.Add(Row(label, picker, tip));
        }
        Colour("Table: lowest values", () => _s.TableLow, v => _s.TableLow = v, "Colour of the smallest values in a map (default light cyan).");
        Colour("Table: low-middle", () => _s.TableMid, v => _s.TableMid = v, "Colour just above the lowest values (default light green).");
        Colour("Table: high-middle", () => _s.TableHigh, v => _s.TableHigh = v, "Colour of the middle of the range (default yellow).");
        Colour("Table: highest values", () => _s.TableMax, v => _s.TableMax = v, "Colour of the largest values (default red).");
        Colour("Live trace (read now)", () => _s.TraceColour, v => _s.TraceColour = v, "Cells the program is reading right now.");
        Colour("Live trace trail", () => _s.TrailColour, v => _s.TrailColour = v, "Cells read recently, fading.");
        Colour("Hit trace: code", () => _s.HitCodeColour, v => _s.HitCodeColour = v, "Source lines that ran.");
        Colour("Hit trace: data", () => _s.HitDataColour, v => _s.HitDataColour = v, "Source lines (DB/DW) read as data.");
        return Grouped(p);
    }

    public static Color Parse(string hex)
    {
        try { return Color.Parse(hex); } catch { return Colors.Magenta; }
    }

    Control HotKeys()
    {
        var p = new StackPanel();
        p.Children.Add(Note("Click a box and press the key combination. Backspace clears it."));
        foreach (var action in _s.HotKeys.Keys.ToList())
        {
            var box = new TextBox { Text = _s.HotKeys[action], Width = 200, IsReadOnly = true, FontFamily = MainWindow.MonoFont };
            box.AddHandler(KeyDownEvent, (_, e) =>
            {
                e.Handled = true;
                if (e.Key is Key.LeftCtrl or Key.RightCtrl or Key.LeftShift or Key.RightShift or Key.LeftAlt or Key.RightAlt or Key.LWin or Key.RWin) return;
                if (e.Key == Key.Back && e.KeyModifiers == KeyModifiers.None) { box.Text = ""; _s.HotKeys[action] = ""; return; }
                var g = new KeyGesture(e.Key, e.KeyModifiers).ToString();
                box.Text = g; _s.HotKeys[action] = g;
            }, Avalonia.Interactivity.RoutingStrategies.Tunnel);
            p.Children.Add(Row(action, box, $"Keyboard shortcut for {action.ToLowerInvariant()}."));
        }
        return Grouped(p);
    }

    /// What the engine should be running: the AFR target for each cam, as a table on the same axes as the fuel map.
    Control Targets()
    {
        var p = new StackPanel();
        p.Children.Add(Note("The O2 / knock tables compare what was logged against these, and 'apply offset changes' moves the fuel map towards them. " +
                            "Type a value into a cell and press Enter (it goes into every cell selected), +/- nudge one step, and Ctrl+C / Ctrl+V " +
                            "copy and paste a block - the same as the maps themselves. The breakpoints are yours to set: 'Use the fuel map's axes' " +
                            "lines the table up with the map it is tuning."));
        p.Children.Add(Section("AFR target - low cam"));
        p.Children.Add(TargetTable(() => _s.AfrTargetLow, t => _s.AfrTargetLow = t,
            "The AFR you want on the low cam, cell by cell. A reading between breakpoints is read straight through from the four around it."));
        p.Children.Add(Section("AFR target - high cam"));
        p.Children.Add(TargetTable(() => _s.AfrTargetHigh, t => _s.AfrTargetHigh = t,
            "The same for the high cam (VTEC). Left empty, the low-cam table is used for both."));
        return Grouped(p);
    }

    /// The corrections: what a sensor really means, as a table of readings in against readings out.
    Control Corrections()
    {
        var p = new StackPanel();
        p.Children.Add(Note("A correction is a small table: the reading along the top, what it really means underneath. Readings between two " +
                            "breakpoints are read straight through, and outside the ends the first and last values hold. Type a value into a cell " +
                            "and press Enter; 'Breakpoints' sets what the columns stand for."));
        p.Children.Add(Section("Wideband correction"));
        p.Children.Add(Note("What the controller really means: a bench-checked wideband that reads 12.0 when the mixture is really 12.3 is corrected here, " +
                            "so every AFR the program compares with a target is the true one."));
        p.Children.Add(CurveTable(() => _s.WidebandCorrection, t => _s.WidebandCorrection = t, "AFR in", "AFR", 2,
            "Measured against corrected."));

        p.Children.Add(Section("Analog input curves"));
        p.Children.Add(Note("A curve for an aux channel, so a sensor that is not a straight line reads in the units you want. The name is the aux " +
                            "channel's (Settings > Datalog); the curve is applied after its expression."));
        var host = new StackPanel();
        void Rebuild()
        {
            host.Children.Clear();
            var curves = ParseNamed(_s.AnalogCurves);
            foreach (var entry in curves.ToList())
            {
                var row = entry;
                var name = new TextBox { Text = row.Name, Width = 150, Watermark = "channel name" };
                var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 8, 0, 0) };
                head.Children.Add(new TextBlock { Text = "Channel", VerticalAlignment = VerticalAlignment.Center, FontSize = 11.5 });
                head.Children.Add(name);
                head.Children.Add(Button("Remove", () => { curves.Remove(row); _s.AnalogCurves = WriteNamed(curves); Rebuild(); }));
                var block = new StackPanel();
                block.Children.Add(head);
                block.Children.Add(CurveTable(() => row.Text, t => { row.Text = t; _s.AnalogCurves = WriteNamed(curves); }, "in", "out", 3,
                                              $"What '{row.Name}' reads, and what it should mean."));
                name.LostFocus += (_, _) => { row.Name = (name.Text ?? "").Trim(); _s.AnalogCurves = WriteNamed(curves); };
                host.Children.Add(block);
            }
            if (curves.Count == 0) host.Children.Add(Note("No analog curves yet."));
        }
        Rebuild();
        p.Children.Add(host);
        p.Children.Add(Button("Add a curve", () =>
        {
            var curves = ParseNamed(_s.AnalogCurves);
            curves.Add(new NamedCurve { Name = $"aux{curves.Count + 1}", Text = "0 = 0\n2.5 = 50\n5 = 100" });
            _s.AnalogCurves = WriteNamed(curves);
            Rebuild();
        }));
        return Grouped(p);
    }

    sealed class NamedCurve
    {
        public string Name = "";
        public string Text = "";
    }

    /// "name: 0=0, 2.5=50, 5=100" per line, the way the setting is stored.
    static List<NamedCurve> ParseNamed(string? text)
    {
        var list = new List<NamedCurve>();
        foreach (var raw in (text ?? "").Split('\n'))
        {
            var line = raw.Trim();
            int colon = line.IndexOf(':');
            if (colon <= 0) continue;
            list.Add(new NamedCurve { Name = line[..colon].Trim(), Text = line[(colon + 1)..].Trim() });
        }
        return list;
    }

    static string WriteNamed(IEnumerable<NamedCurve> curves) =>
        string.Join("\n", curves.Where(c => c.Name.Length > 0)
            .Select(c => c.Name + ": " + string.Join(", ", LookupCurve.Parse(c.Text).Points.Select(pt => $"{pt.In:0.###}={pt.Out:0.###}"))));

    /// A correction as a table: the reading along the top, what it means in the one row underneath.
    Control CurveTable(Func<string> get, Action<string> set, string inUnit, string outUnit, int decimals, string tip)
    {
        var grid = new GridBox { Step = 0.1, Height = 86 };
        var points = new TextBox { Width = 260, FontFamily = MainWindow.MonoFont, FontSize = 11.5, Watermark = "0, 2.5, 5" };
        var block = new StackPanel { Margin = new Thickness(0, 2, 0, 8) };

        void Draw()
        {
            var curve = LookupCurve.Parse(get());
            var ins = curve.Points.Count > 0 ? curve.Points.Select(x => x.In).ToArray() : [0, 2.5, 5];
            var outs = curve.Points.Count > 0 ? curve.Points.Select(x => x.Out).ToArray() : [0, 50, 100];
            points.Text = GridBox.AxisText(ins);
            grid.Set([0], ins, outs, outUnit, inUnit, outUnit, decimals);
        }

        void Save(double[] values)
        {
            var ins = GridBox.ParseAxis(points.Text);
            var c = new LookupCurve();
            for (int i = 0; i < ins.Length && i < values.Length; i++)
                if (!double.IsNaN(values[i])) c.Points.Add((ins[i], values[i]));
            set(c.ToText());
        }

        grid.Changed += Save;
        points.LostFocus += (_, _) =>
        {
            // the breakpoints moved: keep what each column meant and redraw against the new ones
            var ins = GridBox.ParseAxis(points.Text);
            var old = LookupCurve.Parse(get());
            var c = new LookupCurve();
            foreach (var x in ins) c.Points.Add((x, old.Any ? Math.Round(old.Apply(x), 4) : x));
            set(c.ToText());
            Draw();
        };
        ToolTip.SetTip(grid, tip);
        ToolTip.SetTip(points, "What the columns stand for: the readings coming in, separated by commas.");
        var head = new WrapPanel { Margin = new Thickness(0, 2), ItemSpacing = 6, LineSpacing = 4 };
        head.Children.Add(new TextBlock { Text = "Breakpoints", VerticalAlignment = VerticalAlignment.Center, FontSize = 11.5, Width = 90 });
        head.Children.Add(points);
        head.Children.Add(Button("Clear", () => { set(""); Draw(); }));
        block.Children.Add(head);
        block.Children.Add(grid);
        Draw();
        return block;
    }

    /// An AFR target map as a table, with its own breakpoints and a button to take the fuel map's.
    Control TargetTable(Func<string> get, Action<string> set, string tip)
    {
        var grid = new GridBox { Step = 0.1 };
        var rpmBox = new TextBox { Width = 250, FontFamily = MainWindow.MonoFont, FontSize = 11.5, Watermark = "800, 2000, 4000, 6000" };
        var loadBox = new TextBox { Width = 250, FontFamily = MainWindow.MonoFont, FontSize = 11.5, Watermark = "20, 40, 60, 80, 100" };
        var count = new TextBlock { FontSize = 11, Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center };

        double[] Rpm() => GridBox.ParseAxis(rpmBox.Text);
        double[] Load() => GridBox.ParseAxis(loadBox.Text);

        void Draw()
        {
            var map = TargetMap.Parse(get());
            var rpm = map.Any ? map.Rpm.ToArray() : Rpm();
            var load = map.Any ? map.Load.ToArray() : Load();
            if (rpm.Length == 0 || load.Length == 0)
            {
                var axes = _mapAxes?.Invoke();
                rpm = rpm.Length > 0 ? rpm : axes is { Rpm.Length: > 0 } a ? a.Rpm : [800, 2000, 3000, 4000, 5000, 6000, 7000, 8000];
                load = load.Length > 0 ? load : axes is { Load.Length: > 0 } b ? b.Load : [20, 40, 60, 80, 100];
            }
            rpmBox.Text = GridBox.AxisText(rpm);
            loadBox.Text = GridBox.AxisText(load);
            var values = new double[rpm.Length * load.Length];
            for (int r = 0; r < rpm.Length; r++)
                for (int c = 0; c < load.Length; c++)
                    values[(r * load.Length) + c] = map.Any ? map.Target(rpm[r], load[c], 14.7) : 14.7;
            grid.Set(rpm, load, values, "rpm", "load", "AFR", 2);
            count.Text = $"{rpm.Length} x {load.Length}";
        }

        void Save(double[] values)
        {
            var rpm = Rpm(); var load = Load();
            if (rpm.Length == 0 || load.Length == 0) return;
            var map = new TargetMap { Rpm = [.. rpm], Load = [.. load] };
            for (int r = 0; r < rpm.Length; r++)
                map.Values.Add([.. Enumerable.Range(0, load.Length).Select(c =>
                {
                    int i = (r * load.Length) + c;
                    return i < values.Length && !double.IsNaN(values[i]) ? values[i] : 14.7;
                })]);
            set(map.ToText());
        }

        grid.Changed += Save;
        void AxisChanged()
        {
            // keep every target where it was in rpm-and-load terms, then redraw on the new grid
            var map = TargetMap.Parse(get());
            var rpm = Rpm(); var load = Load();
            if (rpm.Length == 0 || load.Length == 0) { Draw(); return; }
            var moved = new TargetMap { Rpm = [.. rpm], Load = [.. load] };
            foreach (var r in rpm)
                moved.Values.Add([.. load.Select(c => map.Any ? Math.Round(map.Target(r, c, 14.7), 3) : 14.7)]);
            set(moved.ToText());
            Draw();
        }
        rpmBox.LostFocus += (_, _) => AxisChanged();
        loadBox.LostFocus += (_, _) => AxisChanged();

        ToolTip.SetTip(grid, tip);
        ToolTip.SetTip(rpmBox, "The RPM breakpoints down the left, separated by commas.");
        ToolTip.SetTip(loadBox, "The load breakpoints across the top, separated by commas (kPa).");

        var bar = new WrapPanel { Margin = new Thickness(0, 2) };
        bar.Children.Add(Button("Use the fuel map's axes", () =>
        {
            var axes = _mapAxes?.Invoke();
            if (axes is not { Rpm.Length: > 0, Load.Length: > 0 } a) { count.Text = "no fuel map with axes is open"; return; }
            rpmBox.Text = GridBox.AxisText(a.Rpm);
            loadBox.Text = GridBox.AxisText(a.Load);
            AxisChanged();
        }));
        bar.Children.Add(Button("Fill with 14.7", () =>
        {
            var rpm = Rpm(); var load = Load();
            if (rpm.Length == 0 || load.Length == 0) return;
            Save([.. Enumerable.Repeat(14.7, rpm.Length * load.Length)]);
            Draw();
        }));
        bar.Children.Add(Button("Clear", () => { set(""); Draw(); }));
        bar.Children.Add(count);

        var rows = new StackPanel();
        // one breakpoint list per line, the box filling what is left beside its label, so neither covers the other however narrow the window
        var axisRow = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), RowDefinitions = new RowDefinitions("Auto,Auto"), Margin = new Thickness(0, 2) };
        var l1 = new TextBlock { Text = "RPM rows", VerticalAlignment = VerticalAlignment.Center, FontSize = 11.5, Margin = new Thickness(0, 0, 8, 0) };
        var l2 = new TextBlock { Text = "Load columns", VerticalAlignment = VerticalAlignment.Center, FontSize = 11.5, Margin = new Thickness(0, 0, 8, 0) };
        rpmBox.Width = loadBox.Width = double.NaN;
        rpmBox.MinWidth = loadBox.MinWidth = 120;
        rpmBox.Margin = loadBox.Margin = new Thickness(0, 2);
        Grid.SetColumn(l1, 0); axisRow.Children.Add(l1);
        Grid.SetColumn(rpmBox, 1); axisRow.Children.Add(rpmBox);
        Grid.SetRow(l2, 1); Grid.SetColumn(l2, 0); axisRow.Children.Add(l2);
        Grid.SetRow(loadBox, 1); Grid.SetColumn(loadBox, 1); axisRow.Children.Add(loadBox);
        rows.Children.Add(axisRow);
        rows.Children.Add(bar);
        grid.Height = 240;
        rows.Children.Add(grid);
        Draw();
        return rows;
    }

    Control Datalog()
    {
        var p = new StackPanel();
        p.Children.Add(Section("ECU link"));
        var dlPort = PortBox(_s.DatalogPort, new[] { "simulator" }, v => _s.DatalogPort = v);
        var dlFound = new TextBlock { FontSize = 11, Opacity = 0.8, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0), TextWrapping = TextWrapping.Wrap, MaxWidth = 360 };
        var dlDetect = new Button { Content = "Detect", Margin = new Thickness(6, 0, 0, 0) };
        ToolTip.SetTip(dlDetect, "Try every serial port with every datalog protocol (each at its own baud rate) and pick the port and protocol the ECU answers on. Takes a few seconds a port; the ignition must be on.");
        var dlRow = new WrapPanel();
        dlRow.Children.Add(dlPort); dlRow.Children.Add(dlDetect); dlRow.Children.Add(dlFound);
        p.Children.Add(Row("Port", dlRow,
            "Serial port of the car's datalog cable. 'simulator' logs the ROM running in this app through its own serial port (a virtual ECU). Detect finds it."));
        var baud = new ComboBox { ItemsSource = new[] { 9600, 19200, 38400, 57600, 115200 }, SelectedItem = _s.DatalogBaud, Width = 180 };
        baud.SelectionChanged += (_, _) => { if (baud.SelectedItem is int b) _s.DatalogBaud = b; };
        p.Children.Add(Row("Baud rate", baud, "The OBD1 datalogging ROMs all use 38400."));
        p.Children.Add(Section("External readings"));
        var feeds = new TextBox
        {
            AcceptsReturn = true, MinHeight = 90, MinWidth = 200, MaxWidth = 460, FontFamily = MainWindow.MonoFont, FontSize = 11.5,
            Text = string.Join("\n", _s.ExternalFeeds.Select(f =>
                $"{f.Name} = {f.Source}" + (f.IntervalMs != 1000 ? $" | {f.IntervalMs}ms" : "") + (f.Path.Length > 0 ? " | " + f.Path : ""))),
            Watermark = "dyno = http://192.168.1.50/data.json | 500ms | result",
        };
        feeds.LostFocus += (_, _) => _s.ExternalFeeds = ParseFeeds(feeds.Text ?? "");
        p.Children.Add(Row("Feeds", feeds,
            "One per line: name = http(s) URL or a path to a JSON file, then optionally | how often | which property to read. " +
            "Every number in the answer becomes a channel called name.key (nested objects join with dots), which gauges can show like any logged value."));
        feeds.HorizontalAlignment = HorizontalAlignment.Stretch;

        var protos = new[] { "auto" }.Concat(DatalogProtocol.All().Select(x => x.Name)).ToList();
        var proto = new ComboBox { ItemsSource = protos, SelectedItem = protos.Contains(_s.DatalogProtocol) ? _s.DatalogProtocol : "auto", Width = 180 };
        proto.SelectionChanged += (_, _) => _s.DatalogProtocol = proto.SelectedItem as string ?? "auto";
        p.Children.Add(Row("Protocol", proto, "auto tries each handshake in turn, each at its own baud rate. " + string.Join("  ", DatalogProtocol.All().Select(x => $"{x.Name}: {x.Description}."))));
        dlDetect.Click += async (_, _) =>
        {
            dlDetect.IsEnabled = false;
            var ports = SerialLink.Ports().ToList();
            if (ports.Count == 0) { dlFound.Text = "no serial ports on this computer"; dlDetect.IsEnabled = true; return; }
            string? foundPort = null, foundProto = null;
            foreach (var port in ports)
            {
                dlFound.Text = $"trying {port}…";
                var (proto2, why) = await Task.Run(() => ProbeDatalogPort(port));
                AppLog.Write(LogKind.Serial, "datalog", $"port detection on {port}: {why}");
                if (proto2 != null) { foundPort = port; foundProto = proto2; break; }
            }
            if (foundPort != null)
            {
                _s.DatalogPort = foundPort; _s.DatalogProtocol = foundProto!;
                SetPort(dlPort, foundPort);
                proto.SelectedItem = foundProto;
                dlFound.Text = $"{foundProto} on {foundPort}";
            }
            else dlFound.Text = $"no ECU answered on {string.Join(", ", ports)} (ignition on? cable plugged in? datalog jumper out?)";
            dlDetect.IsEnabled = true;
        };
        var interval = new NumericUpDown { Minimum = 0, Maximum = 2000, Increment = 10, Value = _s.DatalogIntervalMs, Width = 120, FormatString = "0" };
        interval.ValueChanged += (_, e) => { if (e.NewValue is decimal d) _s.DatalogIntervalMs = (int)d; };
        p.Children.Add(Row("Pause between frames (ms)", interval, "0 = as fast as the ECU answers."));
        var keep = new NumericUpDown { Minimum = 1000, Maximum = 5_000_000, Increment = 10000, Value = _s.DatalogKeepFrames, Width = 140, FormatString = "0" };
        keep.ValueChanged += (_, e) => { if (e.NewValue is decimal d) _s.DatalogKeepFrames = (int)d; };
        p.Children.Add(Row("Frames kept in memory", keep, "Older frames are dropped (save the log to keep everything)."));
        p.Children.Add(Check("Drive the simulator with the car's readings", _s.DatalogDrivesSimulator, v => _s.DatalogDrivesSimulator = v,
            "Feed each frame's rpm, MAP, TPS, temperatures, O2, battery and speed into the simulated engine, to see which code the car's conditions run."));

        p.Children.Add(Section("Wideband"));
        var wbType = new ComboBox { ItemsSource = WidebandReader.Types, SelectedItem = WidebandReader.Types.Contains(_s.WidebandType) ? _s.WidebandType : "none", Width = 180 };
        var wbBaud = new ComboBox { ItemsSource = new[] { 9600, 19200, 38400, 57600, 115200 }, SelectedItem = _s.WidebandBaud, Width = 180 };
        wbType.SelectionChanged += (_, _) =>
        {
            _s.WidebandType = wbType.SelectedItem as string ?? "none";
            _s.WidebandBaud = WidebandReader.DefaultBaud(_s.WidebandType);
            wbBaud.SelectedItem = _s.WidebandBaud;
        };
        wbBaud.SelectionChanged += (_, _) => { if (wbBaud.SelectedItem is int b) _s.WidebandBaud = b; };
        p.Children.Add(Row("Controller", wbType, "A wideband O2 controller with a serial output adds 'afr' and 'lambda' channels to every frame (AEM, Zeitronix, TechEdge, PLX, Innovate LC-1/LM-2, 14Point7 Spartan)."));
        p.Children.Add(Row("Port", PortBox(_s.WidebandPort, null, v => _s.WidebandPort = v), "Serial port of the wideband controller."));
        p.Children.Add(Row("Baud rate", wbBaud, "Set when the controller is picked; change it only if yours is configured differently."));
        var stoich = new NumericUpDown { Minimum = 5, Maximum = 20, Increment = 0.1m, Value = (decimal)_s.StoichAfr, Width = 120, FormatString = "0.0" };
        stoich.ValueChanged += (_, e) => { if (e.NewValue is decimal d) _s.StoichAfr = (double)d; };
        p.Children.Add(Row("Stoichiometric AFR", stoich, "14.7 for petrol, 9.8 for E85: converts between AFR and lambda."));
        p.Children.Add(Note("A wideband wired to a spare ECU input instead of a serial port: add an aux channel below for that input's byte (for example 'byte:24' with x / 25.5 + 10)."));

        p.Children.Add(Section("Aux channels"));
        p.Children.Add(Note("Extra channels computed from each frame and overlaid on the maps like the wideband: an analog input (knock sensor, EGR, a 0-5 V wideband output...) " +
                            "or a digital one. Source: byte:N, word:N (little-endian), bit:N.B, or channel:<name>. Expression in x, e.g. 'x * 5 / 255' for volts."));
        var grid = new StackPanel();
        void Rebuild()
        {
            grid.Children.Clear();
            foreach (var ch in _s.AuxChannels.ToList())
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(0, 2) };
                TextBox T(string v, double w, string wm, Action<string> set) { var t = new TextBox { Text = v, Width = w, Watermark = wm, FontFamily = MainWindow.MonoFont }; t.TextChanged += (_, _) => set(t.Text ?? ""); return t; }
                row.Children.Add(T(ch.Name, 110, "name", v => ch.Name = v));
                row.Children.Add(T(ch.Source, 110, "byte:24", v => ch.Source = v));
                row.Children.Add(T(ch.Expr, 170, "x * 5 / 255", v => ch.Expr = v));
                row.Children.Add(T(ch.Unit, 60, "unit", v => ch.Unit = v));
                row.Children.Add(Button("✕", () => { _s.AuxChannels.Remove(ch); Rebuild(); }));
                grid.Children.Add(row);
            }
        }
        Rebuild();
        p.Children.Add(grid);
        p.Children.Add(Button("Add channel", () => { _s.AuxChannels.Add(new AuxChannelSetting { Name = $"aux{_s.AuxChannels.Count + 1}" }); Rebuild(); }));
        var ov = new TextBox { Text = _s.OverlayChannel, Width = 180 };
        ov.TextChanged += (_, _) => _s.OverlayChannel = ov.Text ?? "afr";
        p.Children.Add(Row("Default overlay channel", ov, "Channel offered first for the map overlay (afr, lambda, knock, o2_v, or an aux channel name)."));
        return Grouped(p);
    }

    Control Emulator()
    {
        var p = new StackPanel();
        p.Children.Add(Note("An emulator in the ECU's ROM socket: the Calibration page uploads the ROM to it (and every edit as it is made), and the " +
                            "Hit trace page streams the addresses the ECU fetches. Tell it which device is fitted - the version query answers " +
                            "differently on each, and the baud rate is not the same either."));
        p.Children.Add(Section("Device"));
        var kind = new ComboBox { ItemsSource = MoatesTrace.Kinds, SelectedItem = MoatesTrace.Kinds.Contains(_s.EmulatorType) ? _s.EmulatorType : "auto", Width = 180 };
        var ebaud = new ComboBox { ItemsSource = new[] { 38400, 115200, 921600 }, SelectedItem = _s.EmulatorBaud, Width = 180 };
        kind.SelectionChanged += (_, _) =>
        {
            _s.EmulatorType = kind.SelectedItem as string ?? "auto";
            // each family has one baud rate it is happiest at
            _s.EmulatorBaud = _s.EmulatorType == "PGMFI RTP" ? 38400 : 921600;
            ebaud.SelectedItem = _s.EmulatorBaud;
        };
        ebaud.SelectionChanged += (_, _) => { if (ebaud.SelectedItem is int b) _s.EmulatorBaud = b; };
        p.Children.Add(Row("Emulator", kind,
            "Which device is in the socket. 'auto' takes whatever answers the version query: an Ostrich answers 'O', a Demon 'D', " +
            "an RTP 'C', a ROMulator '1' or '2'. Naming it means a wrong answer is reported instead of half-working."));
        p.Children.Add(Row("Baud rate", ebaud, "921600 for an Ostrich 2.0 or a Demon (115200 also works); 38400 for a PGMFI RTP."));
        var emPort = PortBox(_s.MoatesPort, null, v => _s.MoatesPort = v);
        var emFound = new TextBlock { FontSize = 11, Opacity = 0.8, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0), TextWrapping = TextWrapping.Wrap, MaxWidth = 360 };
        var emDetect = new Button { Content = "Detect", Margin = new Thickness(6, 0, 0, 0) };
        ToolTip.SetTip(emDetect, "Ask every serial port, at each baud rate the devices use, for an emulator's version, and set the port, the device and the baud rate from the one that answers. Disconnect the emulator first if it is connected.");
        var emRow = new WrapPanel();
        emRow.Children.Add(emPort); emRow.Children.Add(emDetect); emRow.Children.Add(emFound);
        p.Children.Add(Row("Port", emRow, "Serial port of the emulator. Detect finds it."));
        emDetect.Click += async (_, _) =>
        {
            emDetect.IsEnabled = false;
            var ports = MoatesTrace.Ports().ToList();
            if (ports.Count == 0) { emFound.Text = "no serial ports on this computer"; emDetect.IsEnabled = true; return; }
            (string Port, string Device, int Baud)? hit = null;
            foreach (var port in ports)
            {
                emFound.Text = $"trying {port}…";
                hit = await Task.Run(() => ProbeEmulatorPort(port));
                if (hit != null) break;
            }
            if (hit is { } h)
            {
                _s.MoatesPort = h.Port; _s.EmulatorBaud = h.Baud;
                _s.EmulatorType = MoatesTrace.Kinds.Contains(h.Device) ? h.Device : "auto";
                SetPort(emPort, h.Port);
                kind.SelectedItem = _s.EmulatorType;
                ebaud.SelectedItem = h.Baud;
                emFound.Text = $"{h.Device} on {h.Port} at {h.Baud} baud";
            }
            else emFound.Text = $"no emulator answered on {string.Join(", ", ports)}";
            emDetect.IsEnabled = true;
        };
        p.Children.Add(Check("Upload every calibration change as it is made", _s.EmulatorAutoUpload, v => _s.EmulatorAutoUpload = v,
            "The default for the Calibration page's 'Upload on changes'. Only the 256-byte blocks that changed are sent."));
        var bse = new TextBox { Text = _s.MoatesBase, Width = 180, FontFamily = MainWindow.MonoFont };
        bse.TextChanged += (_, _) => _s.MoatesBase = bse.Text ?? "78000";
        p.Children.Add(Row("Trace window base (hex)", bse, "Emulator address of ECU address 0000 for the Trace command. A 32 KB image at the top of the 64 KB bank of chip bank 7 is 78000 (the Ostrich Address Tracer uses 70000 + 8000)."));
        p.Children.Add(Check("Skip repeated addresses", _s.HitSkipRepeats, v => _s.HitSkipRepeats = v,
            "Ask the emulator to report an address only when it differs from the previous hit (a loop still shows every pass through it)."));
        p.Children.Add(Check("Colour the source with hits", _s.HitColourSource, v => _s.HitColourSource = v,
            "Tint executed source lines green and data lines read blue, brightest for the most recent hits."));

        p.Children.Add(Section("Serial timing"));
        p.Children.Add(Note("These apply to the car's datalog cable as well as the emulator. The defaults are what the established tuning software uses; " +
                            "raise the timeout and the pause on a Bluetooth or a slow USB-serial cable."));
        p.Children.Add(Row("Read timeout (ms)", Spin(_s.SerialTimeoutMs, 20, 5000, 10, v => _s.SerialTimeoutMs = v),
            "How long to wait for the bytes of one frame before calling it missed."));
        p.Children.Add(Row("Write timeout (ms)", Spin(_s.SerialWriteTimeoutMs, 50, 10000, 50, v => _s.SerialWriteTimeoutMs = v),
            "How long a write may take before it is given up on."));
        p.Children.Add(Row("Pause after writing (ms)", Spin(_s.PostWritePauseMs, 0, 500, 1, v => _s.PostWritePauseMs = v),
            "A wait between sending a command and reading its answer. Several USB-serial cables lose the first byte of the answer without one; 10 ms is the usual figure."));
        p.Children.Add(Row("Retries", Spin(_s.SerialRetries, 0, 20, 1, v => _s.SerialRetries = v),
            "How many times a handshake or a block is tried again before the link is called dead."));
        p.Children.Add(Check("Raise DTR and RTS on the port", _s.SerialDtrRts, v => _s.SerialDtrRts = v,
            "Most OBD1 cables do not care; a few take their power from these lines and read nothing at all without it."));
        return Grouped(p);
    }

    static NumericUpDown Spin(int value, int min, int max, int step, Action<int> set)
    {
        var n = new NumericUpDown
        {
            Value = Math.Clamp(value, min, max), Minimum = min, Maximum = max, Increment = step,
            Width = 140, FormatString = "0", FontFamily = MainWindow.MonoFont,
        };
        n.ValueChanged += (_, e) => { if (e.NewValue is decimal d) set((int)d); };
        return n;
    }

    readonly TextBlock _procError = new() { Foreground = Brushes.OrangeRed, TextWrapping = TextWrapping.Wrap, FontSize = 11 };
    TextBox? _procText;

    void FillProcessorBar()
    {
        _procBar.Children.Clear();
        _procBar.Children.Add(new TextBlock { Text = "Built-in:", VerticalAlignment = VerticalAlignment.Center });
        foreach (var b in ProcessorProfile.Builtins())
        {
            var name = b.Name;
            _procBar.Children.Add(Button($"{b.Name} ({b.Board})", () =>
            {
                _profile = ProcessorProfile.Builtin(name)!;
                _profileJson = "";
                _procText?.Text = _profile.ToJson();
                _s.Processor = name;
            }));
        }
    }

    Control Processor()
    {
        var p = new StackPanel();
        p.Children.Add(Note("The chip and the board: part name, crystal and clock divider, memory map, SFR and vector names, package pinout, what the board wires to each pin, " +
                            "the injector numbering and the 8255. Projects save this as processor.json, so a project for another 66K part - the MSM66911 in OBD0 / P13 ECUs - " +
                            "is described by editing it. The simulator's peripherals stay the MSM66207's."));
        _procText = new TextBox
        {
            Text = _profileJson, AcceptsReturn = true, FontFamily = MainWindow.MonoFont, FontSize = 11, TextWrapping = TextWrapping.NoWrap, Height = 380,
        };
        _procText.TextChanged += (_, _) => { _profileJson = _procText.Text ?? ""; _procError.Text = ""; };
        p.Children.Add(_procText);
        p.Children.Add(_procError);
        return p;
    }

    Control Mcp()
    {
        var p = new StackPanel();
        p.Children.Add(Note("The MCP server lets an LLM agent (Claude, or any MCP client) use this toolchain for its own ROM work: architecture and opcode " +
                            "reference, disassemble .bin, assemble and test-run .asm, explore code, detect and edit calibration tables, compare ROMs, " +
                            "read datalogs and upload to the emulator. Agents on the in-app server work on the ROM open here, and you see every change they make."));
        p.Children.Add(Check("Run the HTTP MCP server while the app is open", _s.McpEnabled, v => _s.McpEnabled = v,
            "Serve MCP over HTTP at http://<this machine>:<port>/mcp. Every request needs the password (Authorization: Bearer <password>). The Debug page logs every call and the address it came from."));
        var port = new NumericUpDown { Minimum = 1024, Maximum = 65535, Value = _s.McpPort, Width = 140, FormatString = "0" };
        port.ValueChanged += (_, e) => { if (e.NewValue is decimal d) _s.McpPort = (int)d; };
        p.Children.Add(Row("Port", port, "TCP port for the HTTP server."));
        p.Children.Add(Check("Allow remote connections (listen on all network interfaces)", _s.McpRemote, v => _s.McpRemote = v,
            "Off: only this computer can connect. On: other machines can too - a password of 8+ characters is then required. " +
            "The connection is plain HTTP: use it on a trusted network or behind a VPN / SSH tunnel / HTTPS reverse proxy."));
        var pw = new TextBox { Text = _s.McpPassword, Width = 220, PasswordChar = '•', FontFamily = MainWindow.MonoFont };
        pw.TextChanged += (_, _) => _s.McpPassword = pw.Text ?? "";
        var gen = new Button { Content = "Generate", Margin = new Thickness(6, 0) };
        gen.Click += (_, _) => { pw.Text = Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(18)).Replace('/', '_').Replace('+', '-'); pw.PasswordChar = '\0'; };
        var show = new Button { Content = "Show" };
        show.Click += (_, _) => pw.PasswordChar = pw.PasswordChar == '\0' ? '•' : '\0';
        var pwRow = new WrapPanel();
        pwRow.Children.Add(pw); pwRow.Children.Add(gen); pwRow.Children.Add(show);
        p.Children.Add(Row("Password", pwRow, "Agents send it as 'Authorization: Bearer <password>' (or an X-Api-Key header). Stored encrypted for your Windows account."));
        p.Children.Add(Check("Read-only (agents may read and run, not write files)", _s.McpReadOnly, v => _s.McpReadOnly = v,
            "Refuse file_write / file_edit / assemble output / disassemble output."));

        var roots = new ListBox { Height = 90, ItemsSource = _s.McpRoots.ToList() };
        var addRoot = new Button { Content = "Add folder…" };
        addRoot.Click += async (_, _) =>
        {
            var f = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = "Folder agents may use" });
            var path = f.FirstOrDefault()?.TryGetLocalPath();
            if (path != null && !_s.McpRoots.Contains(path)) { _s.McpRoots.Add(path); roots.ItemsSource = _s.McpRoots.ToList(); }
        };
        var removeRoot = new Button { Content = "Remove", Margin = new Thickness(6, 0) };
        removeRoot.Click += (_, _) => { if (roots.SelectedItem is string r) { _s.McpRoots.Remove(r); roots.ItemsSource = _s.McpRoots.ToList(); } };
        var rootButtons = new WrapPanel { Margin = new Thickness(0, 4) };
        rootButtons.Children.Add(addRoot); rootButtons.Children.Add(removeRoot);
        var rootPanel = new StackPanel { MaxWidth = 440 };
        rootPanel.Children.Add(roots); rootPanel.Children.Add(rootButtons);
        p.Children.Add(Row("Workspace folders", rootPanel, "Agents can only read and write inside these folders. Empty: the folder of the file open in the app."));

        p.Children.Add(Note("Status: " + _mcpStatus()));

        var exe = Environment.ProcessPath ?? "OkiRomSimStudio.exe";
        string root = _s.McpRoots.FirstOrDefault() ?? "<your ROM folder>";
        string stdio = JsonSerializer.Serialize(new { mcpServers = new { okirom = new { command = exe, args = new[] { "--mcp", "--root", root } } } }, new JsonSerializerOptions { WriteIndented = true });
        string http = JsonSerializer.Serialize(new
        {
            mcpServers = new { okirom = new { type = "http", url = $"http://{(_s.McpRemote ? Environment.MachineName : "127.0.0.1")}:{_s.McpPort}/mcp", headers = new Dictionary<string, string> { ["Authorization"] = "Bearer <password>" } } },
        }, new JsonSerializerOptions { WriteIndented = true });
        p.Children.Add(Code("Local agents over stdio (the agent starts the server itself; e.g. Claude Code: claude mcp add okirom -- \"" + exe + "\" --mcp --root <folder>)", stdio));
        p.Children.Add(Code("Agents connecting to this app's HTTP server (they work on the ROM open here)", http));
        return Grouped(p);
    }

    /// A heading with its Copy button beside it, then the text (the button used to sit under the text where the scroll bar covered it).
    Control Code(string title, string text)
    {
        var head = new DockPanel { Margin = new Thickness(0, 10, 0, 2) };
        var copy = new Button { Content = "Copy", Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Top };
        copy.Click += async (_, _) =>
        {
            try { if (Clipboard is { } cb) await cb.SetTextAsync(text); copy.Content = "Copied"; }
            catch (Exception ex) { AppLog.Error("settings", "copy failed", ex); }
        };
        DockPanel.SetDock(copy, Dock.Right);
        head.Children.Add(copy);
        head.Children.Add(new TextBlock { Text = title, FontSize = 11, Opacity = 0.8, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center });
        var box = new TextBox { Text = text, IsReadOnly = true, AcceptsReturn = true, FontFamily = MainWindow.MonoFont, FontSize = 11, TextWrapping = TextWrapping.Wrap };
        var sp = new StackPanel();
        sp.Children.Add(head); sp.Children.Add(box);
        return sp;
    }
}
