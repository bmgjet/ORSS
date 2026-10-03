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

/// Settings: appearance, panel zoom, colours, hot keys, datalogging (ports, protocol, wideband, aux channels), hit trace and the ROM emulator, the processor profile, and the MCP server for other programs. Works on a copy; Save hands it back and the main window applies it.
public sealed class SettingsWindow : Window
{
    static readonly JsonSerializerOptions McpJson = new() { WriteIndented = true };
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
                          Func<(double[] Rpm, double[] Load)>? mapAxes = null, PluginManager? plugins = null)
    {
        _plugins = plugins;
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
        keyBar.Children.Add(Button("Reset hot keys", () => { _s.HotKeys = AppSettings.DefaultHotKeys(); _s.TableHotKeys = TableKeys.Defaults(); Reopen(tabs, "Hot keys", HotKeys()); }));
        _tabs = tabs;
        tabs.Items.Add(Page("Units", UnitsPage(), out var unitBar));
        unitBar.Children.Add(Button("All metric", () => { _s.Units = UnitSettings.Metric(); Reopen(tabs, "Units", UnitsPage()); }));
        unitBar.Children.Add(Button("All imperial (US)", () => { _s.Units = UnitSettings.ImperialUs(); Reopen(tabs, "Units", UnitsPage()); }));
        unitBar.Children.Add(Button("UK mix (mph, lb-ft, °C)", () => { _s.Units = UnitSettings.ImperialUk(); Reopen(tabs, "Units", UnitsPage()); }));
        unitBar.Children.Add(Button("As it was", () => { _s.Units = new UnitSettings(); Reopen(tabs, "Units", UnitsPage()); }));
        tabs.Items.Add(Page("Dyno", DynoPage(), out var dynoBar));
        dynoBar.Children.Add(Button("Restore the default profiles", () =>
        {
            int n = DynoWindow.RestoreDefaultProfiles();
            _dynoNote.Text = $"{n} default profile(s) written to {DynoWindow.ProfilesDir} (any you changed or deleted with those names is put back).";
        }));
        dynoBar.Children.Add(Button("Clear all saved runs…", async () =>
        {
            int count = Directory.Exists(DynoWindow.RunsDir) ? Directory.GetFiles(DynoWindow.RunsDir, "*.json").Length : 0;
            if (count == 0) { _dynoNote.Text = "There are no saved runs."; return; }
            if (!await Dialogs.Confirm(this, "Delete every run?", $"Delete all {count} saved dyno run(s)? They cannot be brought back. The profiles stay.", "Delete them all", "Keep")) return;
            _dynoNote.Text = $"{DynoWindow.ClearAllRuns()} run(s) deleted (an open dyno window shows them until it is opened again).";
        }));
        dynoBar.Children.Add(Button("Open the dyno folder", () =>
        {
            try { Directory.CreateDirectory(DynoWindow.Folder); System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(DynoWindow.Folder) { UseShellExecute = true }); } catch { }
        }));
        dynoBar.Children.Add(Button("Reset these settings", () => { _s.Dyno = new DynoSettings(); Reopen(tabs, "Dyno", DynoPage()); }));
        tabs.Items.Add(Page("Emulator & datalog", EmulatorAndDatalog()));
        tabs.Items.Add(Page("Targets", Targets(), out var targetBar));
        tabs.Items.Add(Page("Corrections", Corrections()));
        targetBar.Children.Add(Button("Start from a sensible AFR table", () =>
        {
            _s.AfrTargetLow = TargetMap.Default().ToText();
            if (_s.AfrTargetHigh.Trim().Length == 0) _s.AfrTargetHigh = _s.AfrTargetLow;
            Reopen(tabs, "Targets", Targets());
        }));
        tabs.Items.Add(Page("Processor", Processor(), out var procBar));
        tabs.Items.Add(Page("MCP server", Mcp()));
        tabs.Items.Add(Page("Plugins", PluginsPage()));
        tabs.Items.Add(Page("Updates", UpdatesPage()));
        tabs.Items.Add(Page("About", AboutPage.Build()));
        // the settings pages plugins add
        foreach (var (title, build) in plugins?.SettingsPages ?? [])
        {
            Control content;
            try { content = build(); } catch (Exception ex) { content = Note($"{title} could not be shown: {ex.Message}"); }
            tabs.Items.Add(Page(title, content));
        }
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
    readonly PluginManager? _plugins;

    /// Settings > Updates: where they come from, whether to look at start-up, and Check now.
    Control UpdatesPage()
    {
        var p = new StackPanel();
        p.Children.Add(Note("The program and its templates (the skeleton ROM, its feature modules, HTS120) can be brought up to date from the website. " +
                            "Checking only compares: each file that differs is listed with what changed - the lines, for a template - and nothing is " +
                            "downloaded until you say so. A replaced template keeps the old one as .bak; a new program takes a restart, which you are asked about."));
        var check = new Button { Content = "Check now", MinWidth = 110 };
        ToolTip.SetTip(check, "Ask the website what it has and list what differs from the files here.");
        check.Click += async (_, _) => await new UpdatesWindow(_s.UpdateSite).ShowDialog(this);
        p.Children.Add(Row("Updates", check, "List what differs from the website; you pick what to download."));
        var site = new Button { Content = "🌐  " + AboutPage.Website, Padding = new Thickness(8, 3) };
        site.Click += (_, _) => AboutPage.Open(AboutPage.Website);
        p.Children.Add(Row("Website", site, "Where updates come from: always the author's website, so an update can only come from there. Click to open it."));
        p.Children.Add(Check("Check for updates when the program starts", _s.CheckUpdatesAtStart, v => _s.CheckUpdatesAtStart = v,
            "Look at the website when the program starts and say on the status line if anything is newer. Nothing is downloaded without asking."));
        p.Children.Add(Row("Installed in", new SelectableTextBlock { Text = Updater.Home, FontFamily = MainWindow.MonoFont, FontSize = 11.5, TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 420 },
            "The folder the program and its Templates are updated in."));
        return Grouped(p);
    }

    /// Settings > Plugins: the .dlls to load, each switched on or off, with what it says it is.
    Control PluginsPage()
    {
        var p = new StackPanel();
        p.Children.Add(Note("A plugin is a .dll that adds to the app: menu entries, buttons, pages, windows, datalog sources (the ScanTool plugin reads an ELM327), " +
                            "anything. It runs inside the app with the app's own rights - it can read and change the ROM and your files - so only add plugins " +
                            "you trust. A plugin added or switched on is loaded when you press Save; one switched off is left out the next time the app starts."));
        var list = new StackPanel { Spacing = 4 };
        void Fill()
        {
            list.Children.Clear();
            if (_s.Plugins.Count == 0) list.Children.Add(Note("No plugins yet: Add… one (a .dll)."));
            foreach (var pl in _s.Plugins.ToList())
            {
                var loaded = _plugins?.Plugins.Where(l => string.Equals(l.Path, pl.Path, StringComparison.OrdinalIgnoreCase)).Select(l => l.Plugin).ToList() ?? [];
                var info = loaded.Count > 0 ? [.. loaded.Select(x => (x.Name, x.Version, x.Description))] : PluginManager.Inspect(pl.Path, out _);
                var head = info.Count > 0 ? string.Join(", ", info.Select(i => $"{i.Name} {i.Version}")) : Path.GetFileName(pl.Path);
                var on = new CheckBox { IsChecked = pl.Enabled, Content = head, FontWeight = FontWeight.SemiBold };
                on.IsCheckedChanged += (_, _) => pl.Enabled = on.IsChecked == true;
                var remove = new Button { Content = "Remove", Padding = new Thickness(8, 1), MinHeight = 0 };
                remove.Click += (_, _) => { _s.Plugins.Remove(pl); Fill(); };
                var row = new DockPanel();
                DockPanel.SetDock(remove, Dock.Right);
                row.Children.Add(remove);
                row.Children.Add(on);
                var box = new StackPanel { Margin = new Thickness(0, 2, 0, 6) };
                box.Children.Add(row);
                var state = loaded.Count > 0 ? "running" : File.Exists(pl.Path) ? (pl.Enabled ? "loads when you press Save" : "switched off") : "the file is not there any more";
                box.Children.Add(Note($"{pl.Path}  ({state})" + (info.Count > 0 ? "\n" + string.Join("\n", info.Select(i => i.Description)) : "")));
                list.Children.Add(box);
            }
        }
        Fill();
        p.Children.Add(list);
        // the plugins that come with the app (its Plugins folder), one click to add
        var shipped = new StackPanel { Spacing = 4 };
        void FillShipped()
        {
            shipped.Children.Clear();
            var dir = Path.Combine(AppContext.BaseDirectory, "Plugins");
            if (!Directory.Exists(dir)) return;
            foreach (var dll in Directory.GetFiles(dir, "*.dll").Where(d => !_s.Plugins.Any(x => string.Equals(x.Path, d, StringComparison.OrdinalIgnoreCase))))
            {
                var info = PluginManager.Inspect(dll, out _);
                if (info.Count == 0) continue;
                var add = new Button { Content = "Add", Padding = new Thickness(8, 1), MinHeight = 0 };
                add.Click += (_, _) => { _s.Plugins.Add(new PluginSetting { Path = dll, Enabled = true }); Fill(); FillShipped(); };
                var row = new DockPanel();
                DockPanel.SetDock(add, Dock.Right);
                row.Children.Add(add);
                row.Children.Add(new TextBlock { Text = string.Join(", ", info.Select(i => $"{i.Name} {i.Version} - {i.Description}")), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center });
                shipped.Children.Add(row);
            }
            if (shipped.Children.Count > 0) shipped.Children.Insert(0, Section("Plugins that come with the app"));
        }
        FillShipped();
        p.Children.Add(shipped);
        p.Children.Add(Button("Add…", async () =>
        {
            var files = await StorageProvider.OpenFilePickerAsync(new Avalonia.Platform.Storage.FilePickerOpenOptions
            {
                Title = "A plugin (.dll)", AllowMultiple = true,
                FileTypeFilter = [new Avalonia.Platform.Storage.FilePickerFileType("Plugin") { Patterns = ["*.dll"] }],
            });
            foreach (var f in files)
            {
                if (f.TryGetLocalPath() is not { } path || _s.Plugins.Any(x => string.Equals(x.Path, path, StringComparison.OrdinalIgnoreCase))) continue;
                if (PluginManager.Inspect(path, out var err).Count == 0)
                {
                    _pluginNote.Text = $"{Path.GetFileName(path)} has no plugin in it{(err != null ? ": " + err : " (a public class that implements IOkiPlugin)")}";
                    continue;
                }
                _s.Plugins.Add(new PluginSetting { Path = path, Enabled = true });
                _pluginNote.Text = "";
            }
            Fill();
        }));
        p.Children.Add(_pluginNote);
        var page = new StackPanel();
        page.Children.Add(Grouped(p));
        var guideHead = new DockPanel { Margin = new Thickness(0, 14, 0, 8) };
        var copyAll = PluginGuide.CopyAll();
        DockPanel.SetDock(copyAll, Dock.Right);
        guideHead.Children.Add(copyAll);
        guideHead.Children.Add(new TextBlock { Text = "Making your own plugin", FontSize = 16, FontWeight = FontWeight.Bold, VerticalAlignment = VerticalAlignment.Center });
        page.Children.Add(guideHead);
        page.Children.Add(PluginGuide.Build());
        return page;
    }
    readonly TextBlock _pluginNote = new() { Foreground = Brushes.OrangeRed, FontSize = 11, TextWrapping = TextWrapping.Wrap };
    readonly TabControl _tabs;

    /// Open on this page ("Hot keys"...).
    public void ShowPage(string header)
    {
        if (_tabs.Items.OfType<TabItem>().FirstOrDefault(t => (string?)t.Tag == header) is { } tab) _tabs.SelectedItem = tab;
    }

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

    /// What a port's Detect found, on the port's own line: one line, cut short with its whole text on hover, so a long message never moves the port box or wraps under it.
    static TextBlock FoundText() => new()
    {
        FontSize = 11, Opacity = 0.8, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0),
        TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 300,
    };

    static void Found(TextBlock t, string text) { t.Text = text; ToolTip.SetTip(t, text); }

    static Control PortRow(Control port, Control detect, TextBlock found)
    {
        var row = new StatusRow();
        port.VerticalAlignment = detect.VerticalAlignment = VerticalAlignment.Center;
        found.MaxWidth = double.PositiveInfinity;
        row.Children.Add(port); row.Children.Add(detect); row.Children.Add(found);
        return row;
    }

    /// The controls side by side, the last (a status message) in whatever room is left, cut short: its length never counts towards the row's width, so a long message never pushes the row under its label.
    sealed class StatusRow : Panel
    {
        protected override Size MeasureOverride(Size avail)
        {
            double w = 0, h = 0;
            for (int i = 0; i < Children.Count - 1; i++)
            {
                var c = Children[i];
                c.Measure(new Size(double.PositiveInfinity, avail.Height));
                w += c.DesiredSize.Width; h = Math.Max(h, c.DesiredSize.Height);
            }
            if (Children.Count > 0)
            {
                double room = double.IsInfinity(avail.Width) ? 0 : Math.Max(0, avail.Width - w);
                Children[^1].Measure(new Size(room, avail.Height));
                h = Math.Max(h, Children[^1].DesiredSize.Height);
                if (!double.IsInfinity(avail.Width)) w += Math.Min(room, Children[^1].DesiredSize.Width);
            }
            return new Size(w, h);
        }

        protected override Size ArrangeOverride(Size size)
        {
            double x = 0;
            for (int i = 0; i < Children.Count; i++)
            {
                var c = Children[i];
                double cw = i == Children.Count - 1 ? Math.Max(0, size.Width - x) : c.DesiredSize.Width;
                c.Arrange(new Rect(x, 0, cw, size.Height));
                x += cw;
            }
            return size;
        }
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
                BorderBrush = AppTheme.Brush(Color.FromArgb(64, 255, 255, 255)),
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

    /// The emulator version query on one port at each baud rate the devices use: the device, or null. Ask one port for an emulator, at the baud rate set first and then the others; stops early once `give up` is set (the port's time is up).
    static (string Port, string Device, int Baud)? ProbeEmulatorPort(string port, int first, Func<bool> givenUp)
    {
        foreach (var baud in new[] { first, 921600, 115200, 38400 }.Distinct())
        {
            if (givenUp()) return null;
            using var m = new MoatesTrace { Kind = "auto", Baud = baud, Retries = 0, TimeoutMs = 200 };
            try
            {
                m.Connect(port);
                return (port, m.Device, baud);
            }
            catch (Exception ex) { AppLog.Write(LogKind.Serial, "emulator", $"detect {port} at {baud}: {ex.Message}"); }
        }
        return null;
    }

    ComboBox? _dlPort, _dlBaud;
    Button? _dlDetect;
    readonly TextBlock _dlDemon = new() { FontSize = 11, Opacity = 0.85, TextWrapping = TextWrapping.Wrap, MaxWidth = 520, Margin = new Thickness(0, 2, 0, 6) };

    /// A Demon datalogs over the emulator's own port: with one fitted, the Datalog page offers only that (or the simulator), and the baud rate and port detection are the Demon's business.
    void DemonDatalog()
    {
        if (_dlPort == null) return;
        bool demon = _s.EmulatorType == "Demon";
        _dlDemon.IsVisible = demon;
        if (_dlBaud != null) _dlBaud.IsEnabled = !demon;
        if (_dlDetect != null) _dlDetect.IsEnabled = !demon;
        var list = demon ? new List<string> { "emulator", "simulator" }
                         : new[] { "simulator", "emulator" }.Concat(SerialLink.Ports()).ToList();
        string keep = demon && _s.DatalogPort != "simulator" ? "emulator" : _s.DatalogPort;
        if (keep.Length > 0 && !list.Contains(keep)) list.Insert(0, keep);
        _dlPort.ItemsSource = list;
        _dlPort.SelectedItem = keep.Length > 0 ? keep : list.FirstOrDefault();
        if (_dlPort.SelectedItem is string now) _s.DatalogPort = now;
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

        var langs = Lang.Available();
        var language = new ComboBox
        {
            ItemsSource = langs.Select(l => l.English.Length > 0 && l.English != l.Language ? $"{l.Language}  ({l.English})" : l.Language).ToList(),
            SelectedIndex = Math.Max(0, langs.FindIndex(l => l.Code.Equals(_s.Language, StringComparison.OrdinalIgnoreCase))), Width = 260,
        };
        language.SelectionChanged += (_, _) => { if (language.SelectedIndex >= 0) _s.Language = langs[language.SelectedIndex].Code; };
        var langRow = new WrapPanel();
        langRow.Children.Add(language);
        var langFolder = new Button { Content = "Folder", Margin = new Thickness(6, 0, 0, 0) };
        ToolTip.SetTip(langFolder, "Open your lang folder: a .json file put here (a copy of one of the program's, changed) is offered in the list the next time the app starts.");
        langFolder.Click += (_, _) =>
        {
            var dir = Path.Combine(AppSettings.Dir, "lang");
            try { Directory.CreateDirectory(dir); System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(dir) { UseShellExecute = true }); } catch { }
        };
        langRow.Children.Add(langFolder);
        var missing = new Button { Content = "Save the text not translated yet", Margin = new Thickness(6, 0, 0, 0) };
        ToolTip.SetTip(missing, "With a language in use: write the English text seen on screen that has no translation yet to lang\\missing-<language>.json in your lang folder, ready to fill in.");
        missing.Click += (_, _) =>
        {
            if (Lang.Current == "en") { missing.Content = "Pick a language and restart first"; return; }
            try { var f = Lang.WriteMissing(); missing.Content = $"{Lang.MissingCount} written to {Path.GetFileName(f)}"; } catch (Exception ex) { missing.Content = ex.Message; }
        };
        langRow.Children.Add(missing);
        p.Children.Add(Row("Language", langRow,
            "The language the app is shown in. Each one is a .json file in the lang folder beside the program (and in yours): English text and its translation, " +
            "easy to edit by hand. Text not in a file stays English. Takes full effect when the app starts again."));

        string[] starts = ["simulator", "tuner", "last"];
        var startIn = new ComboBox
        {
            ItemsSource = new[] { "Simulator - ROM development and simulation", "Tuner - tuning and datalogging", "Whichever was used last" },
            SelectedIndex = Math.Max(0, Array.IndexOf(starts, _s.StartIn)), Width = 320,
        };
        startIn.SelectionChanged += (_, _) => { if (startIn.SelectedIndex >= 0) _s.StartIn = starts[startIn.SelectedIndex]; };
        p.Children.Add(Row("Start in", startIn,
            "The view the app opens in. Simulator: the source, the simulated MCU, its disassembly and every debugging page. Tuner: the maps and " +
            "the datalog, for a car on an emulator. File > Tuner mode / Simulator mode switches at any time."));
        var welcome = new Button { Content = "Ask me again at the next start" };
        welcome.Click += (_, _) => { _s.FirstRunDone = false; welcome.Content = "The welcome screen shows at the next start ✓"; welcome.IsEnabled = false; };
        if (!_s.FirstRunDone) { welcome.Content = "The welcome screen shows at the next start ✓"; welcome.IsEnabled = false; }
        p.Children.Add(Row("Welcome screen", welcome, "Show the first-start screen again - what the app is for, Simulator or Tuner - the next time the app starts."));
        var cores = Environment.ProcessorCount;
        var ramGb = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / (1024.0 * 1024 * 1024);
        p.Children.Add(Check("Low performance mode", _s.LowPerformance ?? Perf.Suggested, v => _s.LowPerformance = v,
            "For a slow laptop. Where the engine is on the map and the datalog itself stay as quick as ever; everything else is updated less often " +
            "(the simulator's side panels, the values list, the gauges, the fading trail, the overlay), the cells are drawn without their shading, " +
            "and in Tuner mode the source editor lets go of its copy of the text until you are back in the simulator (its undo history goes with it). " +
            $"This machine: {cores} core{(cores == 1 ? "" : "s")}, {ramGb:0.#} GB - " + (Perf.Suggested ? "on is suggested." : "off is fine.")));

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

        p.Children.Add(Check("Touch screen mode (big buttons for the tables instead of the keys; bigger controls for a finger)", _s.TouchMode, v => _s.TouchMode = v,
            "For a tablet or a touch screen laptop: a pad of big buttons beside the table (up and down a step, 1 % and 5 %, move the selection, " +
            "interpolate, smooth, a keypad for a value, undo), larger cells, taller buttons and list rows, and zoom buttons and pinch-to-zoom on the 3D view."));
        p.Children.Add(Check("Tuner mode (the calibration editor as the main page, datalogging beside it)", _s.TunerMode, v => _s.TunerMode = v,
            "A simpler layout for tuning: no source, simulator or assembly panels. The live trace on the maps comes from the datalog."));
        p.Children.Add(Check("Reopen the last file at start", _s.ReopenLastFile, v => _s.ReopenLastFile = v, "Open the .asm/.bin/project you had open last time."));
        p.Children.Add(Check("Offer to run Detect when a ROM is created or opened", _s.AskDetectOnOpen, v => _s.AskDetectOnOpen = v,
            "Detect finds the tables and settings of the ROM (by lining it up with the known ROMs and following the code that reads them), so the calibration list and the feature pages fill themselves in."));

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

    /// Settings > Units: the unit each kind of measurement is shown in, any mix of metric and imperial.
    Control UnitsPage()
    {
        var p = new StackPanel();
        p.Children.Add(Note("Every value the app shows - the datalog, its graph and gauges, the maps and settings, the virtual dyno - is shown in these units, " +
                            "and what you type in them is put back into the unit the ROM keeps. Mix them as you like: the buttons above set them all at once. " +
                            "\"as is\" keeps a pressure in the unit the ROM or log has it in (kPa for MAP, mBar on a load axis)."));
        foreach (var q in Enum.GetValues<Quantity>())
        {
            var choices = Units.Choices[q];
            var box = new ComboBox { ItemsSource = choices, Width = 140, SelectedIndex = Math.Max(0, Array.IndexOf(choices, _s.Units.Get(q))) };
            box.SelectionChanged += (_, _) => { if (box.SelectedItem is string u) _s.Units.Set(q, u); };
            p.Children.Add(Row(Units.Names[q], box, $"{Units.Names[q]}: {string.Join(", ", choices)}."));
        }
        p.Children.Add(Note($"Lambda is worked out from AFR with the stoichiometric ratio set on the Emulator & datalog page (now {_s.StoichAfr:0.0#})."));
        return Grouped(p);
    }

    readonly TextBlock _dynoNote = new() { FontSize = 11, Opacity = 0.85, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4) };

    /// Settings > Dyno: what the virtual dyno shows and how it works it out, the same for every profile.
    Control DynoPage()
    {
        var d = _s.Dyno;
        var p = new StackPanel();
        p.Children.Add(_dynoNote);
        p.Children.Add(Note("The dyno window keeps what changes from car to car - the car or the roller, the air on the day, the triggers. These are the same for every profile. " +
                            "Power, torque, weight, speed and pressure are in the units picked on the Units page."));
        NumericUpDown Num(double v, double min, double max, double step, string fmt, Action<double> set)
        {
            var n = new NumericUpDown { Minimum = (decimal)min, Maximum = (decimal)max, Increment = (decimal)step, Value = (decimal)Math.Clamp(v, min, max), FormatString = fmt, Width = 140 };
            n.ValueChanged += (_, e) => { if (e.NewValue is decimal x) set((double)x); };
            return n;
        }
        p.Children.Add(Section("Results"));
        p.Children.Add(Check("Show the crank estimate (else at the wheels)", d.ShowCrank, v => d.ShowCrank = v,
            "The power at the wheels with the drivetrain loss added back: an estimate of what the engine makes at the crank."));
        p.Children.Add(Row("Drivetrain loss (%)", Num(d.DrivetrainLossPct, 0, 50, 1, "0", v => d.DrivetrainLossPct = v), "For the crank estimate: about 12-15 % for a front-wheel-drive manual."));
        p.Children.Add(Row("Smoothing (0-10)", Num(d.Smoothing, 0, 10, 1, "0", v => d.Smoothing = (int)v), "How much the acceleration is smoothed: 0 is raw, 5 suits most logs."));
        p.Children.Add(Row("Rpm step", Num(d.RpmStep, 25, 500, 25, "0", v => d.RpmStep = v), "The curve is averaged in steps of this many rpm."));
        var xs = new[] { "rpm", "time", "speed" };
        var x = new ComboBox { ItemsSource = xs, SelectedIndex = Math.Max(0, Array.IndexOf(xs, d.XAxis)), Width = 140 };
        x.SelectionChanged += (_, _) => { if (x.SelectedItem is string v) d.XAxis = v; };
        p.Children.Add(Row("Graph against", x, "What the graph is drawn against when the dyno opens."));

        p.Children.Add(Section("Correction to standard air"));
        string[] corr = ["None (as measured)", "SAE J1349", "DIN 70020", "SAE J607 (STD)", "ECE / EEC"];
        var c = new ComboBox { ItemsSource = corr, SelectedIndex = (int)d.Correction, Width = 220 };
        c.SelectionChanged += (_, _) => { if (c.SelectedIndex >= 0) d.Correction = (DynoCorrection)c.SelectedIndex; };
        p.Children.Add(Row("Standard", c, "What the engine would make on a standard day: SAE J1349 (25 °C, 99 kPa dry) is the usual one."));
        p.Children.Add(Check("Air temperature and pressure from the ECU (intake air, baro) when it logs them", d.AirFromEcu, v => d.AirFromEcu = v,
            "Else the air on the day typed into the dyno window's profile is used."));
        p.Children.Add(Row("Humidity (%)", Num(d.HumidityPct, 0, 100, 1, "0", v => d.HumidityPct = v), "The air's relative humidity, for the correction."));

        p.Children.Add(Section("AFR"));
        var chans = new[] { "afr", "lambda", "o2_v", "wb_v", "egr_in_v", "b6_in_v", "egr_v", "b6_v", "serin1", "serin2", "serin3", "serin4" };
        var ch = new ComboBox { ItemsSource = chans, SelectedItem = chans.Contains(d.AfrChannel) ? d.AfrChannel : "afr", Width = 140 };
        ch.SelectionChanged += (_, _) => { if (ch.SelectedItem is string v) d.AfrChannel = v; };
        p.Children.Add(Row("From the channel", ch, "afr: a wideband on its own port, or an aux channel. o2_v / wb_v / egr_in_v / b6_in_v: a wideband's analog output wired to an ECU input (convert it below)."));
        p.Children.Add(Check("The channel is volts: convert it", d.AfrFromVolts, v => d.AfrFromVolts = v, "AFR = the AFR at 0 V + (at 5 V - at 0 V) x volts / 5."));
        p.Children.Add(Row("AFR at 0 V", Num(d.AfrAt0V, 0, 30, 0.1, "0.0", v => d.AfrAt0V = v), "From the wideband's manual: most read 10 AFR at 0 V and 20 at 5 V (AEM UEGO: 8.5 - 18)."));
        p.Children.Add(Row("AFR at 5 V", Num(d.AfrAt5V, 0, 40, 0.1, "0.0", v => d.AfrAt5V = v), "The AFR the wideband's output reads at 5 V."));
        p.Children.Add(Row("Offset (AFR)", Num(d.AfrOffset, -5, 5, 0.05, "0.00", v => d.AfrOffset = v), "Added after the conversion: to match a gauge, or a voltage the ECU reads low."));

        p.Children.Add(Section("Runs"));
        var keys = new ComboBox { ItemsSource = VirtualDyno.HotKeys, SelectedItem = VirtualDyno.HotKeys.Contains(d.HotKey) ? d.HotKey : "Space", Width = 140 };
        keys.SelectionChanged += (_, _) => { if (keys.SelectedItem is string v) d.HotKey = v; };
        p.Children.Add(Row("Hotkey", keys, "Starts and ends a run like the Start button, wherever the focus is in the dyno window."));
        p.Children.Add(Check("Auto start on when the dyno opens", d.ArmOnOpen, v => d.ArmOnOpen = v,
            "On: the dyno waits for the start conditions as soon as it opens. Off: it starts idle, and Auto start (or the Start button) begins."));
        p.Children.Add(Note($"Profiles and runs are kept in {DynoWindow.Folder}. A project saves them too (File > Save project)."));
        return Grouped(p);
    }

    static readonly (string Key, string Label)[] Panels =
    {
        ("Source", "Source editor"), ("Pinout", "Chip pinout"), ("Inputs", "Engine inputs"), ("Right", "CPU / disassembly / outputs"),
        ("Problems", "Problems"), ("Trace", "Trace"), ("Memory", "Memory"), ("Calibration", "Calibration"), ("Lookup", "Lookup & breakpoints"),
        ("Datalog", "Datalog"), ("Gauges", "Datalog gauges"), ("Debug", "Debug"), ("Tuner datalog", "Tuner mode datalog panel"),
        ("Tuner gauges", "Tuner mode gauges"),
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
        // the theme: dark (the default), light, or high contrast for the sun
        var theme = new ComboBox { Width = 200, ItemsSource = new[] { "Dark", "Light", "High contrast" }, SelectedIndex = (int)AppTheme.Parse(_s.Theme) };
        theme.SelectionChanged += (_, _) => _s.Theme = AppTheme.Name((AppTheme.Mode)Math.Max(0, theme.SelectedIndex));
        p.Children.Add(Row("Theme", theme,
            "Dark is the default. Light: dark text on white. High contrast, for a laptop out in the sun: every window in black and white, " +
            "with the colours that mean something (outputs, warnings, the graphs' traces) at full strength and faded text brought up. " +
            "Every window changes at once; Ctrl+Shift+H goes round the three."));
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
        p.Children.Add(Note("Click a box and press the key combination. Backspace clears it. A key used twice is shown in orange, with what else it does."));
        var checks = new List<Action>();
        void Recheck() { foreach (var c in checks) c(); }

        // every key set now, and what it does: for the clash warnings
        List<(string Where, string Action, string Key)> AllKeys() =>
        [
            .. _s.HotKeys.Where(kv => kv.Value.Length > 0).Select(kv => ("program", kv.Key, Norm(kv.Value))),
            .. _s.TableHotKeys.SelectMany(kv => kv.Value.Split('|', StringSplitOptions.RemoveEmptyEntries).Select(k => ("table", kv.Key, Norm(k)))),
        ];

        TextBox KeyBox(Func<string> get, Action<string> set)
        {
            var box = new TextBox { Text = Pretty(get()), Width = 170, IsReadOnly = true, FontFamily = MainWindow.MonoFont };
            box.AddHandler(KeyDownEvent, (_, e) =>
            {
                e.Handled = true;
                if (e.Key is Key.LeftCtrl or Key.RightCtrl or Key.LeftShift or Key.RightShift or Key.LeftAlt or Key.RightAlt or Key.LWin or Key.RWin) return;
                if (e.Key == Key.Back && e.KeyModifiers == KeyModifiers.None) { set(""); box.Text = ""; Recheck(); return; }
                var g = new KeyGesture(e.Key, e.KeyModifiers).ToString();
                set(g); box.Text = Pretty(g); Recheck();
            }, Avalonia.Interactivity.RoutingStrategies.Tunnel);
            return box;
        }

        void Clash(TextBox box, string where, string action, Func<string> get)
        {
            checks.Add(() =>
            {
                var key = Norm(get());
                var other = key.Length == 0 ? [] : AllKeys().Where(k => k.Key == key && !(k.Where == where && k.Action == action)).ToList();
                // a table key the same as a program key is fine while the table has the keyboard (the table's wins), but worth knowing a null brush draws nothing: the text went invisible. Clear it back to the theme's colour instead
                if (other.Count > 0) box.Foreground = Brushes.Orange; else box.ClearValue(TextBox.ForegroundProperty);
                ToolTip.SetTip(box, other.Count > 0
                    ? "Also: " + string.Join(", ", other.Select(o => $"{o.Action} ({o.Where})")) +
                      (other.All(o => o.Where != where) ? ". On a table the table's key wins; anywhere else the program's does." : ". Only one of them will work.")
                    : "Click and press the keys. Backspace clears it.");
            });
        }

        p.Children.Add(Section("Program"));
        foreach (var action in _s.HotKeys.Keys.ToList())
        {
            var box = KeyBox(() => _s.HotKeys[action], v => _s.HotKeys[action] = v);
            Clash(box, "program", action, () => _s.HotKeys[action]);
            p.Children.Add(Row(action, box, $"Keyboard shortcut for {action.ToLowerInvariant()}."));
        }

        p.Children.Add(Section("Table editing (the Table, Line and 3D views)"));
        p.Children.Add(Note("Each action takes two keys: the second box is another key that does the same. Arrows move and Shift+arrows select; " +
                            "typing a number edits - those are fixed."));
        foreach (var entry in TableKeys.All)
        {
            var id = entry.Id;
            string[] Parts() { var v = (_s.TableHotKeys.TryGetValue(id, out var t) ? t : entry.Defaults).Split('|'); return [v.ElementAtOrDefault(0) ?? "", v.ElementAtOrDefault(1) ?? ""]; }
            void Put(int i, string key) { var v = Parts(); v[i] = key; _s.TableHotKeys[id] = string.Join("|", v.Where(x => x.Length > 0)); }
            var first = KeyBox(() => Parts()[0], k => Put(0, k));
            var second = KeyBox(() => Parts()[1], k => Put(1, k));
            Clash(first, "table", id, () => Parts()[0]);
            Clash(second, "table", id, () => Parts()[1]);
            var both = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { first, new TextBlock { Text = "or", VerticalAlignment = VerticalAlignment.Center, Opacity = 0.7 }, second } };
            p.Children.Add(Row(id, both, entry.What + "."));
        }
        Recheck();
        return Grouped(p);
    }

    /// A key as it reads ("Page Up", "]"), and as it compares (parsed and written back, so "ctrl+a" and "Ctrl+A" are one key).
    static string Pretty(string key)
    {
        if (key.Length == 0) return "";
        try { return TableKeys.Pretty(KeyGesture.Parse(key)); } catch { return key; }
    }
    static string Norm(string key)
    {
        if (key.Length == 0) return "";
        try { return KeyGesture.Parse(key).ToString(); } catch { return key; }
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
                            "channel's (Settings > Emulator & datalog); the curve is applied after its expression."));
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

    /// The emulator and the datalog on one page - a Demon does both over one port: the emulator first (the device decides where the datalog goes), then the datalog, then the serial timing and reconnecting both share.
    Control EmulatorAndDatalog()
    {
        var emu = Emulator().Children.ToList();
        var log = Datalog().Children.ToList();
        int shared = _sharedTiming == null ? -1 : emu.IndexOf(_sharedTiming);
        if (shared < 0) shared = emu.Count;
        var p = new StackPanel();
        foreach (var c in emu.Take(shared).Concat(log).Concat(emu.Skip(shared)))
        {
            (c.Parent as Panel)?.Children.Remove(c);
            p.Children.Add(c);
        }
        return Grouped(p);
    }

    TextBlock? _sharedTiming;

    StackPanel Datalog()
    {
        var p = new StackPanel();
        p.Children.Add(Section("Datalogging"));
        var dlPort = _dlPort = PortBox(_s.DatalogPort, new[] { "simulator", "emulator" }, v => _s.DatalogPort = v);
        var dlFound = FoundText();
        var dlDetect = new Button { Content = "Detect", Margin = new Thickness(6, 0, 0, 0) };
        ToolTip.SetTip(dlDetect, "Try every serial port with every datalog protocol (each at its own baud rate) and pick the port and protocol the ECU answers on. Takes a few seconds a port; the ignition must be on.");
        var dlRow = PortRow(dlPort, dlDetect, dlFound);
        p.Children.Add(Row("Port", dlRow,
            "Serial port of the car's datalog cable. 'simulator' logs the ROM running in this app through its own serial port (a virtual ECU). " +
            "'emulator' logs through the emulator's port - a Demon asks the ECU itself, so one cable does both. Detect finds it."));
        _dlDemon.Text = "A Demon is the emulator (above): it datalogs the ECU over its own port, so the datalog goes through it " +
                        "('emulator'), or logs the simulator. Connect the emulator first; the protocol is asked for by the Demon.";
        p.Children.Add(_dlDemon);
        var baud = _dlBaud = new ComboBox { ItemsSource = new[] { 9600, 19200, 38400, 57600, 115200 }, SelectedItem = _s.DatalogBaud, Width = 180 };
        baud.SelectionChanged += (_, _) => { if (baud.SelectedItem is int b) _s.DatalogBaud = b; };
        p.Children.Add(Row("Baud rate", baud, "The OBD1 datalogging ROMs all use 38400."));

        p.Children.Add(Section("Smoothing"));
        p.Children.Add(Note("Noise on the line shows up as a value that jumps and comes straight back - 6000 rpm, 28 rpm, 6000 rpm. With smoothing on, " +
                            "each channel's last few readings are looked at together: one far from the middle of them is dropped as a spike, and the " +
                            "good ones are blended. A real change gets through with the next reading. The raw frame is kept as it came. " +
                            "Switch it on in the Datalogging menu (or the box on the Datalog page)."));
        p.Children.Add(Check("Smooth datalog values", _s.DatalogSmooth, v => _s.DatalogSmooth = v,
            "Drop spikes and blend the readings, live and in logs loaded while it is on."));
        var frames = new NumericUpDown { Minimum = 3, Maximum = 15, Increment = 1, Value = _s.DatalogSmoothFrames, Width = 120, FormatString = "0" };
        frames.ValueChanged += (_, e) => { if (e.NewValue is decimal d) _s.DatalogSmoothFrames = (int)d; };
        p.Children.Add(Row("Frames looked at", frames,
            "How many readings are compared and blended: 3 drops a one-frame spike and lags a real change by a frame; more rides out longer bursts " +
            "of noise but smooths (and lags) more."));
        var spike = new NumericUpDown { Minimum = 2, Maximum = 200, Increment = 5, Value = (decimal)_s.DatalogSmoothSpikePercent, Width = 120, FormatString = "0", };
        spike.ValueChanged += (_, e) => { if (e.NewValue is decimal d) _s.DatalogSmoothSpikePercent = (double)d; };
        p.Children.Add(Row("Spike when off by (%)", spike,
            "A reading further than this from the middle of the others is dropped. Each channel also has a floor (250 rpm, 8 kPa, 5 % throttle, " +
            "3 °C...) so small readings are not dropped for moving a little."));
        p.Children.Add(Check("Blend the good readings", _s.DatalogSmoothBlend, v => _s.DatalogSmoothBlend = v,
            "On: the good readings are averaged (smoother). Off: the newest good reading is shown - spikes dropped, nothing averaged."));
        var skip = new TextBox { Text = _s.DatalogSmoothSkip, Width = 260, FontFamily = MainWindow.MonoFont, Watermark = "o2_v, knock" };
        skip.TextChanged += (_, _) => _s.DatalogSmoothSkip = skip.Text ?? "";
        p.Children.Add(Row("Leave these alone", skip,
            "Channels passed through as they come, comma separated: a narrowband O2 switching rich-lean is meant to jump about."));
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
        _dlDetect = dlDetect;
        DemonDatalog();
        dlDetect.Click += async (_, _) =>
        {
            dlDetect.IsEnabled = false;
            var ports = SerialLink.Ports().ToList();
            if (ports.Count == 0) { Found(dlFound, "no serial ports on this computer"); dlDetect.IsEnabled = true; return; }
            string? foundPort = null, foundProto = null;
            foreach (var port in ports)
            {
                Found(dlFound, $"trying {port}…");
                var (proto2, why) = await Task.Run(() => ProbeDatalogPort(port));
                AppLog.Write(LogKind.Serial, "datalog", $"port detection on {port}: {why}");
                if (proto2 != null) { foundPort = port; foundProto = proto2; break; }
            }
            if (foundPort != null)
            {
                _s.DatalogPort = foundPort; _s.DatalogProtocol = foundProto!;
                SetPort(dlPort, foundPort);
                proto.SelectedItem = foundProto;
                Found(dlFound, $"{foundProto} on {foundPort}");
            }
            else Found(dlFound, $"no ECU answered on {string.Join(", ", ports)} (ignition on? cable plugged in? datalog jumper out?)");
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
        return p;
    }

    StackPanel Emulator()
    {
        var p = new StackPanel();
        p.Children.Add(Note("An emulator in the ECU's ROM socket: the Calibration page uploads the ROM to it (and every edit as it is made), and the " +
                            "Trace page (Hit trace ticked) streams the addresses the ECU fetches. Tell it which device is fitted - the version query answers " +
                            "differently on each, and the baud rate is not the same either."));
        p.Children.Add(Section("Emulator"));
        var kind = new ComboBox { ItemsSource = MoatesTrace.Kinds, SelectedItem = MoatesTrace.Kinds.Contains(_s.EmulatorType) ? _s.EmulatorType : "auto", Width = 180 };
        var ebaud = new ComboBox { ItemsSource = new[] { 38400, 115200, 921600 }, SelectedItem = _s.EmulatorBaud, Width = 180 };
        kind.SelectionChanged += (_, _) =>
        {
            _s.EmulatorType = kind.SelectedItem as string ?? "auto";
            // each family has one baud rate it is happiest at
            _s.EmulatorBaud = _s.EmulatorType == "PGMFI RTP" ? 38400 : 921600;
            ebaud.SelectedItem = _s.EmulatorBaud;
            DemonDatalog();
        };
        ebaud.SelectionChanged += (_, _) => { if (ebaud.SelectedItem is int b) _s.EmulatorBaud = b; };
        p.Children.Add(Row("Emulator", kind,
            "Which device is in the socket. 'auto' takes whatever answers the version query: an Ostrich answers 'O', a Demon 'D', " +
            "an RTP 'C', a ROMulator '1' or '2'. Naming it means a wrong answer is reported instead of half-working."));
        p.Children.Add(Row("Baud rate", ebaud, "921600 for an Ostrich 2.0 or a Demon (115200 also works); 38400 for a PGMFI RTP."));
        var emPort = PortBox(_s.MoatesPort, null, v => _s.MoatesPort = v);
        var emFound = FoundText();
        var emDetect = new Button { Content = "Detect", Margin = new Thickness(6, 0, 0, 0) };
        ToolTip.SetTip(emDetect, "Ask every serial port, at each baud rate the devices use, for an emulator's version, and set the port, the device and the baud rate from the one that answers. Disconnect the emulator first if it is connected.");
        var emRow = PortRow(emPort, emDetect, emFound);
        p.Children.Add(Row("Port", emRow, "Serial port of the emulator. Detect finds it."));
        emDetect.Click += async (_, _) =>
        {
            emDetect.IsEnabled = false;
            var ports = MoatesTrace.Ports().ToList();
            if (ports.Count == 0) { Found(emFound, "no serial ports on this computer"); emDetect.IsEnabled = true; return; }
            (string Port, string Device, int Baud)? hit = null;
            foreach (var port in ports)
            {
                Found(emFound, $"trying {port}…");
                // a second a port: one that does not answer in that time (or hangs opening) is left to finish on its own
                bool gaveUp = false;
                var probe = Task.Run(() => ProbeEmulatorPort(port, _s.EmulatorBaud, () => gaveUp));
                bool answered;
                try { await probe.WaitAsync(TimeSpan.FromSeconds(1)); answered = true; } catch (TimeoutException) { answered = false; }
                if (answered) hit = probe.Result;
                else { gaveUp = true; AppLog.Write(LogKind.Serial, "emulator", $"detect {port}: no answer in 1 s, next port"); }
                if (hit != null) break;
            }
            if (hit is { } h)
            {
                _s.MoatesPort = h.Port; _s.EmulatorBaud = h.Baud;
                _s.EmulatorType = MoatesTrace.Kinds.Contains(h.Device) ? h.Device : "auto";
                SetPort(emPort, h.Port);
                kind.SelectedItem = _s.EmulatorType;
                ebaud.SelectedItem = h.Baud;
                Found(emFound, $"{h.Device} on {h.Port} at {h.Baud} baud");
            }
            else Found(emFound, $"no emulator answered on {string.Join(", ", ports)}");
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

        p.Children.Add(_sharedTiming = Section("Serial timing"));
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
        p.Children.Add(Section("Reconnecting"));
        p.Children.Add(Note("When the datalog or the emulator loses its link (a cable pulled, the ECU switched off), its dot on the bar goes orange and blinks " +
                            "while it is tried again in the background; after the last try it goes red."));
        p.Children.Add(Row("Tries", Spin(_s.ReconnectAttempts, 1, 100, 1, v => _s.ReconnectAttempts = v),
            "How many times a lost link is tried again before it is called not connected."));
        p.Children.Add(Row("Pause between tries (ms)", Spin(_s.ReconnectDelayMs, 200, 30000, 100, v => _s.ReconnectDelayMs = v),
            "How long to wait between one try and the next."));
        return p;
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
        p.Children.Add(Note("The MCP server lets any MCP client use this toolchain for its own ROM work: architecture and opcode " +
                            "reference, disassemble .bin, assemble and test-run .asm, explore code, detect and edit calibration tables, compare ROMs, " +
                            "read datalogs and upload to the emulator. Clients on the in-app server work on the ROM open here, and you see every change they make."));
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
        p.Children.Add(Row("Password", pwRow, "Clients send it as 'Authorization: Bearer <password>' (or an X-Api-Key header). Stored encrypted for your Windows account."));
        p.Children.Add(Check("Read-only (clients may read and run, not write files)", _s.McpReadOnly, v => _s.McpReadOnly = v,
            "Refuse file_write / file_edit / assemble output / disassemble output."));

        var roots = new ListBox { Height = 90, ItemsSource = _s.McpRoots.ToList() };
        var addRoot = new Button { Content = "Add folder…" };
        addRoot.Click += async (_, _) =>
        {
            var f = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = "Folder clients may use" });
            var path = f.FirstOrDefault()?.TryGetLocalPath();
            if (path != null && !_s.McpRoots.Contains(path)) { _s.McpRoots.Add(path); roots.ItemsSource = _s.McpRoots.ToList(); }
        };
        var removeRoot = new Button { Content = "Remove", Margin = new Thickness(6, 0) };
        removeRoot.Click += (_, _) => { if (roots.SelectedItem is string r) { _s.McpRoots.Remove(r); roots.ItemsSource = _s.McpRoots.ToList(); } };
        var rootButtons = new WrapPanel { Margin = new Thickness(0, 4) };
        rootButtons.Children.Add(addRoot); rootButtons.Children.Add(removeRoot);
        var rootPanel = new StackPanel { MaxWidth = 440 };
        rootPanel.Children.Add(roots); rootPanel.Children.Add(rootButtons);
        p.Children.Add(Row("Workspace folders", rootPanel, "Clients can only read and write inside these folders. Empty: the folder of the file open in the app."));

        p.Children.Add(Note("Status: " + _mcpStatus()));

        var exe = Environment.ProcessPath ?? "RomSimStudio.exe";
        string root = _s.McpRoots.FirstOrDefault() ?? "<your ROM folder>";
        string stdio = JsonSerializer.Serialize(new { mcpServers = new { okirom = new { command = exe, args = new[] { "--mcp", "--root", root } } } }, McpJson);
        string http = JsonSerializer.Serialize(new
        {
            mcpServers = new { okirom = new { type = "http", url = $"http://{(_s.McpRemote ? Environment.MachineName : "127.0.0.1")}:{_s.McpPort}/mcp", headers = new Dictionary<string, string> { ["Authorization"] = "Bearer <password>" } } },
        }, McpJson);
        p.Children.Add(Code("Local clients over stdio (the client starts the server itself: run \"" + exe + "\" --mcp --root <folder>)", stdio));
        p.Children.Add(Code("Clients connecting to this app's HTTP server (they work on the ROM open here)", http));
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
