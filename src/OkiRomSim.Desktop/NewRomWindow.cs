// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// File > New ROM: Existing - copy a finished ROM from the Templates folder to a file of your own and open it. Create   - take a skeleton ROM (a stock ROM cut down to what runs the engine) and pick the functions you want. Every function is a module the assembler places in the free space, so they go in in any mix and any order without colliding, and the bar shows what is left of the 32 KB.
public sealed class NewRomWindow : Window
{
    /// The file to open when the window closes, or null when it was cancelled.
    public string? Created { get; private set; }

    readonly ListBox _list = new() { MinHeight = 60 };
    readonly TextBlock _about = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.85, Margin = new Thickness(0, 6, 0, 0) };
    readonly List<string> _files = [];

    // Create
    readonly List<Skeleton> _skeletons;
    readonly ComboBox _base = new() { MinWidth = 220 };
    readonly TextBlock _baseAbout = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11, Opacity = 0.75, MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly StackPanel _featureList = new() { Spacing = 1 };
    readonly TextBlock _detail = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
    readonly ProgressBar _space = new() { Minimum = 0, Maximum = 32768, Height = 14, MinWidth = 60 };
    readonly TextBlock _spaceText = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _problems = new() { FontSize = 12, Foreground = Brushes.OrangeRed, TextWrapping = TextWrapping.Wrap };
    readonly Dictionary<string, CheckBox> _boxes = new(StringComparer.OrdinalIgnoreCase);
    readonly Button _ok = new() { IsDefault = true };
    SkeletonBuildResult? _last;
    int _buildSerial;
    bool _changing;

    /// Every build made while the window is open, by skeleton and set of functions (without the image, which is not needed to show sizes): ticking a box back, or a set a cost was worked out for, is known at once.
    readonly System.Collections.Concurrent.ConcurrentDictionary<string, SkeletonBuildResult> _built = new(StringComparer.OrdinalIgnoreCase);
    /// What each function took up last time the costs were worked out (by skeleton and function, kept while the app runs): shown at once, marked ≈, while they are worked out again.
    static readonly Dictionary<string, int> LastBytes = new(StringComparer.OrdinalIgnoreCase);

    static string Key(Skeleton sk, IEnumerable<string> set) =>
        sk.Path + "|" + string.Join(",", set.Select(d => d.ToUpperInvariant()).Distinct().Order(StringComparer.Ordinal));

    SkeletonBuildResult BuildCached(Skeleton sk, IEnumerable<string> set)
    {
        var list = set.ToList();
        var key = Key(sk, list);
        if (_built.TryGetValue(key, out var hit)) return hit;
        var r = sk.Build(list) with { Assembly = null };
        _built[key] = r;
        return r;
    }

    bool TryCached(Skeleton sk, IEnumerable<string> set, out SkeletonBuildResult r) => _built.TryGetValue(Key(sk, set), out r!);

    readonly RadioButton _existing = new() { Content = "Existing - start from a finished ROM", GroupName = "kind", IsChecked = true, FontWeight = FontWeight.SemiBold };
    readonly RadioButton _create = new() { Content = "Create - a skeleton ROM and only the functions you want", GroupName = "kind", FontWeight = FontWeight.SemiBold };
    readonly Control _existingPanel, _createPanel;

    public NewRomWindow()
    {
        Title = "New ROM";
        Width = 860; Height = 640; MinWidth = 560; MinHeight = 440;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var folder = Templates();
        _skeletons = Skeleton.Find(folder);
        if (folder != null)
            _files.AddRange(Directory.GetFiles(folder, "*.asm")
                .Where(f => !f.EndsWith("-skeleton.asm", StringComparison.OrdinalIgnoreCase))
                .OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase));
        _list.ItemsSource = _files.Select(Path.GetFileNameWithoutExtension).ToList();
        _list.SelectionChanged += (_, _) => Describe();
        _list.DoubleTapped += async (_, _) => await Make();
        if (_files.Count > 0) _list.SelectedIndex = 0;

        ToolTip.SetTip(_create,
            "A skeleton is a stock ROM with its extra functions taken out. Tick the functions you want - stock ones put back, or modules " +
            "such as launch control and datalogging - and the ROM is assembled with exactly those. Leaving out what you do not need is what " +
            "makes room for what you do: there are more functions than fit in 32 KB.");
        _create.IsEnabled = _skeletons.Count > 0;

        _existingPanel = ExistingPanel(folder);
        _createPanel = CreatePanel();
        // both buttons: the group unchecks the other one, but its change is not always raised when the page is switched back
        _existing.IsCheckedChanged += (_, _) => SwitchMode();
        _create.IsCheckedChanged += (_, _) => SwitchMode();
        _existing.Click += (_, _) => { _existing.IsChecked = true; _create.IsChecked = false; SwitchMode(); };
        _create.Click += (_, _) => { if (!_create.IsEnabled) return; _create.IsChecked = true; _existing.IsChecked = false; SwitchMode(); };

        _ok.Click += async (_, _) => { if (_create.IsChecked == true) await MakeFromSkeleton(); else await Make(); };
        var cancel = new Button { Content = "Cancel", IsCancel = true };
        cancel.Click += (_, _) => Close();
        var openFolder = new Button { Content = "Open templates folder" };
        ToolTip.SetTip(openFolder, "Any .asm put in this folder is offered under Existing; a xxx-skeleton.asm with its xxx-features folder under Create.");
        openFolder.Click += (_, _) =>
        {
            if (Templates() is { } dir)
                try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(dir) { UseShellExecute = true }); } catch { }
        };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        buttons.Children.Add(openFolder);
        buttons.Children.Add(_ok);
        buttons.Children.Add(cancel);

        // where the new ROM goes, typed or picked here: no file dialog is needed (a system one can open taller than a
        // laptop's screen), Browse… opens one for those who want it
        var browse = new Button { Content = "Browse…" };
        ToolTip.SetTip(browse, "Pick the folder and name with the system's file dialog.");
        browse.Click += async (_, _) => { if (await AskWhere(Path.GetFileName(_saveAs.Text ?? "")) is { } picked) _saveAs.Text = picked; };
        ToolTip.SetTip(_saveAs, "The new ROM's source file. Its skeleton and modules are put beside it.");
        var saveRow = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
        var saveLabel = new TextBlock { Text = "Save as", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        DockPanel.SetDock(saveLabel, Dock.Left); saveRow.Children.Add(saveLabel);
        DockPanel.SetDock(browse, Dock.Right); saveRow.Children.Add(browse);
        browse.Margin = new Thickness(6, 0, 0, 0);
        saveRow.Children.Add(_saveAs);
        var foot = new StackPanel();
        foot.Children.Add(saveRow);
        foot.Children.Add(buttons);

        var top = new StackPanel { Spacing = 4, Margin = new Thickness(0, 0, 0, 6) };
        top.Children.Add(_existing);
        top.Children.Add(_create);
        var body = new DockPanel { Margin = new Thickness(14, 12) };
        DockPanel.SetDock(top, Dock.Top); body.Children.Add(top);
        DockPanel.SetDock(foot, Dock.Bottom); body.Children.Add(foot);
        var mid = new Panel();
        mid.Children.Add(_existingPanel);
        mid.Children.Add(_createPanel);
        body.Children.Add(mid);

        var chrome = DarkChrome.Apply(this, Title);
        var root = new DockPanel();
        DockPanel.SetDock(chrome, Dock.Top);
        root.Children.Add(chrome);
        root.Children.Add(body);
        Content = root;
        Describe();
        SwitchMode();
        _list.SelectionChanged += (_, _) => SuggestSaveAs();
        _base.SelectionChanged += (_, _) => SuggestSaveAs();
        SuggestSaveAs();
    }

    readonly TextBox _saveAs = new() { FontFamily = MainWindow.MonoFont };
    string? _suggested;

    /// A name for the new ROM in the ROMs folder that is not taken yet - unless one has been typed or browsed to.
    void SuggestSaveAs()
    {
        if (_saveAs.Text is { Length: > 0 } now && now != _suggested) return;
        string stem = _create.IsChecked == true
            ? (Current is { } sk ? Path.GetFileNameWithoutExtension(sk.Path).Replace("-skeleton", "") + "-custom" : "custom")
            : (_list.SelectedIndex >= 0 && _list.SelectedIndex < _files.Count ? Path.GetFileNameWithoutExtension(_files[_list.SelectedIndex]) + "_new" : "rom_new");
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "OkiRomSim ROMs");
        var path = Path.Combine(dir, stem + ".asm");
        for (int n = 2; File.Exists(path); n++) path = Path.Combine(dir, $"{stem}-{n}.asm");
        _saveAs.Text = _suggested = path;
    }

    /// The path in the Save as box, checked: a folder made for it, and a yes to replacing a file already there.
    async Task<string?> SaveAsPath()
    {
        var path = (_saveAs.Text ?? "").Trim().Trim('"');
        if (path.Length == 0) { _problems.Text = "Type where to save the new ROM (or Browse…)."; return null; }
        try
        {
            path = Path.GetFullPath(path);
            if (!path.EndsWith(".asm", StringComparison.OrdinalIgnoreCase)) path += ".asm";
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        }
        catch (Exception ex) { _problems.Text = "That is not a place a file can go: " + ex.Message; return null; }
        if (File.Exists(path) && !await Dialogs.Confirm(this, "Replace it?", $"{path} is there already. Replace it with the new ROM?", "Replace", "Keep it"))
            return null;
        return path;
    }

    /// Open on Create (the layout check uses it).
    internal void ShowCreate() { if (_create.IsEnabled) _create.IsChecked = true; }

    void SwitchMode()
    {
        bool create = _create.IsChecked == true;
        _existingPanel.IsVisible = !create;
        _createPanel.IsVisible = create;
        if (_saveAs.Parent != null) SuggestSaveAs();
        if (!create)
        {
            if (_list.SelectedIndex < 0 && _files.Count > 0) _list.SelectedIndex = 0;
            Describe();
            _existingPanel.InvalidateMeasure();
        }
        _ok.Content = create ? "Create ROM" : "Create from template";
        ToolTip.SetTip(_ok, create
            ? "Choose where the new ROM's source goes. A build file with the functions you ticked is written there (with a copy of the skeleton beside it) and opened."
            : "Choose where the new ROM's source goes; the template is copied there and opened. The template itself is never changed.");
        UpdateOk();
    }

    void UpdateOk() => _ok.IsEnabled = _create.IsChecked == true ? _last?.Success == true : _files.Count > 0;

    // ------------------------------------------------------------------ existing

    Control ExistingPanel(string? folder)
    {
        var p = new DockPanel { Margin = new Thickness(22, 0, 0, 0) };
        var where = new TextBlock
        {
            Text = folder == null ? "No Templates folder was found next to the app." : $"Templates in {folder}",
            FontSize = 11, Opacity = 0.7, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 6),
        };
        DockPanel.SetDock(where, Dock.Top); p.Children.Add(where);
        // the description scrolls in a box of its own, so a long one never covers the list
        var aboutBox = new ScrollViewer { Content = _about, MaxHeight = 150, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        DockPanel.SetDock(aboutBox, Dock.Bottom); p.Children.Add(aboutBox);
        p.Children.Add(_list);
        return p;
    }

    /// The Templates folder: beside the app, or (running from a source checkout) the one at the repository root.
    public static string? Templates()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            var t = Path.Combine(dir.FullName, "Templates");
            if (Directory.Exists(t)) return t;
        }
        return null;
    }

    /// The template's opening comment block is its description, up to a line with "<end>" on it (the text before the marker on that line is kept).
    void Describe()
    {
        int i = _list.SelectedIndex;
        if (i < 0 || i >= _files.Count) { _about.Text = _files.Count == 0 ? "No templates yet: put a .asm in the Templates folder." : ""; return; }
        try
        {
            var lines = new List<string>();
            foreach (var raw in File.ReadLines(_files[i]).Take(400))
            {
                var t = raw.Trim();
                if (t.Length > 0 && !t.StartsWith(';')) break;
                var text = t.TrimStart(';').Trim();
                int end = text.IndexOf("<end>", StringComparison.OrdinalIgnoreCase);
                if (end >= 0) text = text[..end].Trim();
                // rules of = or - are decoration, not description
                if (text.Length > 0 && !text.StartsWith('@') && text.Any(char.IsLetterOrDigit)) lines.Add(text);
                if (end >= 0) break;
            }
            // a comment block is wrapped by hand at 80 columns: join a line that carries on into the one before it, so the text flows to the width of the window instead of breaking in the middle of sentences
            var sb = new System.Text.StringBuilder();
            foreach (var line in lines)
            {
                if (sb.Length > 0) sb.Append(char.IsLower(line[0]) || !".:!?".Contains(sb[^1]) ? ' ' : '\n');
                sb.Append(line);
            }
            _about.Text = sb.ToString();
        }
        catch (Exception ex) { _about.Text = ex.Message; }
    }

    async Task Make()
    {
        int i = _list.SelectedIndex;
        if (i < 0 || i >= _files.Count) return;
        var template = _files[i];
        var path = await SaveAsPath();
        if (path == null) return;
        if (Path.GetFullPath(path).Equals(Path.GetFullPath(template), StringComparison.OrdinalIgnoreCase))
        {
            _about.Text = "That is the template itself - pick another name or folder so the template stays as it is.";
            return;
        }
        File.Copy(template, path, overwrite: true);
        Created = path;
        Close();
    }

    async Task<string?> AskWhere(string suggested)
    {
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Save the new ROM source as",
            SuggestedFileName = suggested,
            DefaultExtension = "asm",
            FileTypeChoices = [new FilePickerFileType("Assembler source") { Patterns = ["*.asm"] }],
        });
        return file?.TryGetLocalPath();
    }

    // ------------------------------------------------------------------ create

    Control CreatePanel()
    {
        _base.ItemsSource = _skeletons;
        _base.SelectionChanged += (_, _) => FillFeatures();
        ToolTip.SetTip(_base, "The skeleton to build on. Put another xxx-skeleton.asm (with its xxx-features folder) in the Templates folder to add one.");

        var baseRow = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        var baseLabel = new TextBlock { Text = "Base", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        DockPanel.SetDock(baseLabel, Dock.Left); baseRow.Children.Add(baseLabel);
        DockPanel.SetDock(_base, Dock.Left); baseRow.Children.Add(_base);
        _baseAbout.Margin = new Thickness(10, 0, 0, 0);
        baseRow.Children.Add(_baseAbout);

        var tools = new WrapPanel { Margin = new Thickness(0, 2, 0, 4) };
        Button Small(string text, string tip, Action a)
        {
            var b = new Button { Content = text, Padding = new Thickness(8, 2), Margin = new Thickness(0, 0, 6, 0), FontSize = 12 };
            b.Click += (_, _) => a();
            ToolTip.SetTip(b, tip);
            return b;
        }
        tools.Children.Add(Small("None", "Untick everything: the bare skeleton.", () => SetAll(_ => false)));
        tools.Children.Add(Small("Stock", "Every stock function the skeleton took out, and nothing else: the ROM it was made from.", () => SetAll(f => f.Stock)));
        tools.Children.Add(Small("All modules", "Every module that can be built with the others (the first of any pair that cannot).", () => SetAll(f => !f.Stock)));

        var listScroll = new ScrollViewer { Content = _featureList, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        var detailBox = new Border
        {
            Child = new ScrollViewer { Content = _detail, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled },
            BorderBrush = new SolidColorBrush(Color.FromArgb(60, 255, 255, 255)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4),
            Padding = new Thickness(10, 8), Margin = new Thickness(8, 0, 0, 0),
        };
        _detail.Text = "Point at a function to read what it does.";
        var lists = new Grid { ColumnDefinitions = new ColumnDefinitions("3*,2*") };
        Grid.SetColumn(listScroll, 0); lists.Children.Add(listScroll);
        Grid.SetColumn(detailBox, 1); lists.Children.Add(detailBox);

        var spaceRow = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
        var spaceLabel = new TextBlock { Text = "ROM space", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        DockPanel.SetDock(spaceLabel, Dock.Left); spaceRow.Children.Add(spaceLabel);
        _spaceText.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(_spaceText, Dock.Right); spaceRow.Children.Add(_spaceText);
        spaceRow.Children.Add(_space);
        ToolTip.SetTip(spaceRow, "What the ROM with these functions takes of the 32,768 bytes. When a function does not fit, the build says so and Create stays off until something else is left out.");

        var bottom = new StackPanel();
        bottom.Children.Add(spaceRow);
        bottom.Children.Add(_problems);

        var p = new DockPanel { Margin = new Thickness(22, 0, 0, 0) };
        DockPanel.SetDock(baseRow, Dock.Top); p.Children.Add(baseRow);
        DockPanel.SetDock(tools, Dock.Top); p.Children.Add(tools);
        DockPanel.SetDock(bottom, Dock.Bottom); p.Children.Add(bottom);
        p.Children.Add(lists);
        if (_skeletons.Count > 0) _base.SelectedIndex = 0;
        return p;
    }

    Skeleton? Current => _base.SelectedItem as Skeleton;

    void FillFeatures()
    {
        _featureList.Children.Clear();
        _boxes.Clear();
        _costText.Clear();
        var sk = Current;
        if (sk == null) return;
        _baseAbout.Text = sk.Description;
        ToolTip.SetTip(_baseAbout, sk.Description);
        // modules first (what people come here for), then the stock functions
        foreach (var group in sk.Features.GroupBy(f => f.Category).OrderBy(g => g.First().Stock).ThenBy(g => g.Key))
        {
            _featureList.Children.Add(new TextBlock { Text = group.Key, FontWeight = FontWeight.Bold, FontSize = 12.5, Margin = new Thickness(0, 8, 0, 2) });
            foreach (var f in group.OrderBy(f => f.Name))
            {
                var cost = new TextBlock { FontSize = 11, Opacity = 0.75, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                _costText[f.Define] = cost;
                var box = new CheckBox
                {
                    Content = new StackPanel { Orientation = Orientation.Horizontal, Children = { new TextBlock { Text = f.Name }, cost } },
                    Margin = new Thickness(8, 0, 0, 0), Tag = f, FontSize = 12.5,
                };
                ToolTip.SetTip(box, f.About);
                box.PointerEntered += (_, _) => ShowDetail(f);
                box.GotFocus += (_, _) => ShowDetail(f);
                box.IsCheckedChanged += (_, _) => Toggled(f, box.IsChecked == true);
                _boxes[f.Define] = box;
                _featureList.Children.Add(box);
            }
        }
        // on to start with: the stock trouble codes and the fail-safes that go with them (a failed sensor gets a
        // safe default value instead of its raw reading)
        _changing = true;
        foreach (var d in DefaultOn)
            if (_boxes.TryGetValue(d, out var b)) { b.IsChecked = true; ToolTip.SetTip(b, (sk.Feature(d)?.About ?? "") + "\nTicked to start with: it holds the fail-safes."); }
        _changing = false;
        Rebuild();
    }

    void ShowDetail(SkeletonFeature f)
    {
        var sk = Current;
        var lines = new List<string> { f.Name, "", f.About };
        if (f.Ram.Length > 0 && !f.Ram.Equals("none", StringComparison.OrdinalIgnoreCase)) lines.Add("\nRAM: " + f.Ram);
        if (f.Conflicts.Count > 0) lines.Add("\nCannot be built with: " + string.Join(", ", f.Conflicts.Select(c => sk?.Feature(c)?.Name ?? c)));
        if (f.Requires.Count > 0) lines.Add("\nNeeds: " + string.Join(", ", f.Requires.Select(c => sk?.Feature(c)?.Name ?? c)));
        if (_costs.TryGetValue(f.Define, out var c)) lines.Add("\n" + c.Detail);
        lines.Add($"\n{f.Define}");
        _detail.Text = string.Join("\n", lines);
    }

    /// What each function costs with the others ticked now: adding it (with what it needs, less what it cannot be built with) or taking it out (with what needs it). Worked out after every change, in the background.
    readonly Dictionary<string, TextBlock> _costText = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, (string Short, string Detail)> _costs = new(StringComparer.OrdinalIgnoreCase);

    void Toggled(SkeletonFeature f, bool on)
    {
        if (_changing || Current is not { } sk) return;
        _changing = true;
        var notes = new List<string>();
        if (on)
        {
            // take out whatever it cannot be built with, and put in whatever it needs
            foreach (var other in sk.Features.Where(o => o != f && (f.Conflicts.Contains(o.Define, StringComparer.OrdinalIgnoreCase) || o.Conflicts.Contains(f.Define, StringComparer.OrdinalIgnoreCase))))
                if (_boxes.TryGetValue(other.Define, out var b) && b.IsChecked == true) { b.IsChecked = false; notes.Add($"{other.Name} taken out (it cannot be built with {f.Name})"); }
            foreach (var need in f.Requires)
                if (_boxes.TryGetValue(need, out var b) && b.IsChecked != true) { b.IsChecked = true; notes.Add($"{sk.Feature(need)?.Name ?? need} put in ({f.Name} needs it)"); }
        }
        else
        {
            // and whatever needed it goes too
            foreach (var other in sk.Features.Where(o => o.Requires.Contains(f.Define, StringComparer.OrdinalIgnoreCase)))
                if (_boxes.TryGetValue(other.Define, out var b) && b.IsChecked == true) { b.IsChecked = false; notes.Add($"{other.Name} taken out (it needs {f.Name})"); }
        }
        _changing = false;
        _note = string.Join("; ", notes);
        Rebuild();
    }
    string _note = "";

    void SetAll(Func<SkeletonFeature, bool> want)
    {
        if (Current is not { } sk) return;
        _changing = true;
        var chosen = new List<string>();
        foreach (var f in sk.Features)
        {
            bool on = want(f) && sk.Problems([.. chosen, f.Define]).Count == 0;
            if (on) chosen.Add(f.Define);
            if (_boxes.TryGetValue(f.Define, out var b)) b.IsChecked = on;
        }
        _changing = false;
        _note = "";
        Rebuild();
    }

    /// Functions ticked when a skeleton is picked.
    static readonly string[] DefaultOn = ["FEAT_STOCK_DTC"];

    List<string> Chosen() => [.. _boxes.Where(kv => kv.Value.IsChecked == true).Select(kv => kv.Key)];

    /// Assemble the pick (a tenth of a second or so) and show what it takes: at once when that set has been built already, else on a thread of its own, so it never waits behind the cost builds of the pick before.
    void Rebuild()
    {
        if (Current is not { } sk) return;
        var chosen = Chosen();
        int serial = ++_buildSerial;
        _ok.IsEnabled = false;
        var problems = sk.Problems(chosen);
        if (problems.Count > 0 || TryCached(sk, chosen, out _)) Show();
        else
        {
            _spaceText.Text = "building…";
            new Thread(() =>
            {
                try { BuildCached(sk, chosen); } catch (Exception ex) { AppLog.Error("new rom", "skeleton build failed", ex); }
                Dispatcher.UIThread.Post(Show);
            }) { IsBackground = true, Priority = ThreadPriority.AboveNormal, Name = "new ROM build" }.Start();
        }

        void Show()
        {
            {
                if (serial != _buildSerial) return;
                var r = problems.Count == 0 && TryCached(sk, chosen, out var got) ? got : null;
                _last = r;
                if (r == null)
                {
                    _spaceText.Text = "";
                    _problems.Text = string.Join("\n", problems);
                }
                else
                {
                    // a build that does not fit: the bar full and red, and by how much it is over
                    _space.Value = r.Success ? r.UsedBytes : _space.Maximum;
                    _space.Foreground = !r.Success || r.FreeBytes < 512 ? Brushes.OrangeRed : r.FreeBytes < 2048 ? Brushes.Goldenrod : new SolidColorBrush(Color.FromRgb(0x4e, 0xa1, 0xff));
                    _spaceText.Text = r.Success ? $"{r.UsedBytes:N0} of 32,768 bytes used · {r.FreeBytes:N0} free · {chosen.Count} function(s)"
                                    : r.Over > 0 ? $"over the limit by {r.Over:N0} bytes · {chosen.Count} function(s)" : "does not build";
                    var note = _note.Length > 0 ? _note + "\n" : "";
                    _problems.Text = r.Success ? _note
                                   : r.Over > 0 ? note + $"Too big: over the limit by {r.Over:N0} bytes. Working out what to take out…"
                                   : note + "Does not build:\n" + string.Join("\n", r.Errors.Take(4));
                    _problems.Foreground = r.Success ? new SolidColorBrush(Color.FromRgb(0xb0, 0xb6, 0xc0)) : Brushes.OrangeRed;
                }
                UpdateOk();
                if (r != null) Costs(sk, chosen, r, serial);
            }
        }
    }

    /// The pick with one function switched: as a tick of it would switch it (see Toggled).
    static List<string> Switched(Skeleton sk, List<string> chosen, SkeletonFeature f, out List<string> alsoOut)
    {
        var set = new List<string>(chosen);
        alsoOut = [];
        if (set.Contains(f.Define, StringComparer.OrdinalIgnoreCase))
        {
            set.RemoveAll(d => d.Equals(f.Define, StringComparison.OrdinalIgnoreCase)
                               || sk.Feature(d)?.Requires.Contains(f.Define, StringComparer.OrdinalIgnoreCase) == true);
            return set;
        }
        foreach (var o in sk.Features.Where(o => o != f && set.Contains(o.Define, StringComparer.OrdinalIgnoreCase) &&
                     (f.Conflicts.Contains(o.Define, StringComparer.OrdinalIgnoreCase) || o.Conflicts.Contains(f.Define, StringComparer.OrdinalIgnoreCase))))
        { set.Remove(o.Define); alsoOut.Add(o.Name); }
        set.Add(f.Define);
        foreach (var need in f.Requires) if (!set.Contains(need, StringComparer.OrdinalIgnoreCase)) set.Add(need);
        return set;
    }

    /// Build the pick with each function switched, a few at a time in the background, and write what each costs beside it.
    void Costs(Skeleton sk, List<string> chosen, SkeletonBuildResult now, int serial)
    {
        // each function switched on its own: its size, and whether the ROM is then under the limit (green) or over it (red)
        (bool On, int Bytes, int FreeAfter, string Replaces, bool Ok) Cost(SkeletonFeature f, SkeletonBuildResult b, List<string> alsoOut)
        {
            bool on = chosen.Contains(f.Define, StringComparer.OrdinalIgnoreCase);
            bool ok = (b.Success || b.Over > 0) && (now.Success || now.Over > 0);
            int bytes = on ? b.FreeBytes - now.FreeBytes : now.FreeBytes - b.FreeBytes;     // what it takes up
            return (on, bytes, b.FreeBytes, alsoOut.Count > 0 ? string.Join(", ", alsoOut) : "", ok);
        }
        // at once: the sets already built exactly, the rest estimated from what they took up last time (sizes barely move
        // with the other functions), marked ≈ until the exact ones are in
        var quick = new Dictionary<string, (bool On, int Bytes, int FreeAfter, string Replaces, bool Ok)>(StringComparer.OrdinalIgnoreCase);
        var estimated = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in sk.Features)
        {
            var set = Switched(sk, chosen, f, out var alsoOut);
            if (sk.Problems(set).Count > 0) continue;
            if (TryCached(sk, set, out var b)) quick[f.Define] = Cost(f, b, alsoOut);
            else if (LastBytes.TryGetValue(sk.Path + "|" + f.Define, out var was) && alsoOut.Count == 0)
            {
                bool on = chosen.Contains(f.Define, StringComparer.OrdinalIgnoreCase);
                quick[f.Define] = (on, was, on ? now.FreeBytes + was : now.FreeBytes - was, "", now.Success || now.Over > 0);
                estimated.Add(f.Define);
            }
        }
        ShowCosts(sk, now, quick, estimated, [], null);
        if (quick.Count == sk.Features.Count(f => sk.Problems(Switched(sk, chosen, f, out _)).Count == 0) && estimated.Count == 0 && now.Over == 0) return;
        Task.Run(() =>
        {
            var results = new System.Collections.Concurrent.ConcurrentDictionary<string, (bool On, int Bytes, int FreeAfter, string Replaces, bool Ok)>(StringComparer.OrdinalIgnoreCase);
            // the ones on screen first: the list reads top to bottom
            Parallel.ForEach(sk.Features, new ParallelOptions { MaxDegreeOfParallelism = Math.Clamp(Environment.ProcessorCount - 1, 1, 6) }, f =>
            {
                if (serial != _buildSerial) return;
                var set = Switched(sk, chosen, f, out var alsoOut);
                if (sk.Problems(set).Count > 0) return;
                results[f.Define] = Cost(f, BuildCached(sk, set), alsoOut);
            });
            if (serial != _buildSerial) return;
            // over the limit: what to take out. Every one that is enough on its own; if none is, the fewest (largest first)
            // that together are, checked by building it
            var fixes = new List<string>();
            string? together = null;
            if (now.Over > 0)
            {
                fixes = [.. results.Where(kv => kv.Value.On && kv.Value.Ok && kv.Value.FreeAfter >= 0).OrderBy(kv => kv.Value.Bytes).Select(kv => kv.Key)];
                if (fixes.Count == 0)
                {
                    var set = new List<string>(chosen);
                    var taken = new List<string>();
                    foreach (var (d, _) in results.Where(kv => kv.Value.On && kv.Value.Ok && kv.Value.Bytes > 0).OrderByDescending(kv => kv.Value.Bytes))
                    {
                        if (serial != _buildSerial) return;
                        set = Switched(sk, set, sk.Feature(d)!, out _);
                        taken.Add(d);
                        var b = BuildCached(sk, set);
                        if (b.Success)
                        {
                            together = string.Join(", ", taken.Select(x => sk.Feature(x)?.Name ?? x)) + $" (frees {b.FreeBytes - now.FreeBytes:N0} bytes, leaving {b.FreeBytes:N0})";
                            break;
                        }
                    }
                }
            }
            Dispatcher.UIThread.Post(() =>
            {
                if (serial != _buildSerial) return;
                ShowCosts(sk, now, new(results, StringComparer.OrdinalIgnoreCase), [], fixes, together);
            });
        });
    }

    /// Write each function's cost beside it (estimated ones marked ≈ and dimmed), and when the pick is too big, what to take out.
    void ShowCosts(Skeleton sk, SkeletonBuildResult now, Dictionary<string, (bool On, int Bytes, int FreeAfter, string Replaces, bool Ok)> results,
                   HashSet<string> estimated, List<string> fixes, string? together)
    {
        _costs.Clear();
        foreach (var (d, t) in _costText)
        {
            if (!results.TryGetValue(d, out var r)) { t.Text = "…"; t.ClearValue(TextBlock.ForegroundProperty); t.Opacity = 0.6; continue; }
            if (!r.Ok) { t.Text = "?"; t.ClearValue(TextBlock.ForegroundProperty); _costs[d] = ("?", "Does not build with the others ticked now."); continue; }
            bool est = estimated.Contains(d);
            if (!est) LastBytes[sk.Path + "|" + d] = r.Bytes;
            bool under = r.FreeAfter >= 0;
            string replaces = r.Replaces.Length > 0 ? $", instead of {r.Replaces}" : "";
            string size = r.On ? $"{r.Bytes:N0} B" : r.Bytes < 0 ? $"frees {-r.Bytes:N0} B" : $"+{r.Bytes:N0} B";
            t.Text = (est ? "≈ " : "") + size + replaces + (under ? "" : $" · {-r.FreeAfter:N0} over");
            t.Foreground = under ? Brushes.LimeGreen : Brushes.OrangeRed;
            t.Opacity = est ? 0.7 : 1;
            _costs[d] = (t.Text, (est ? "(An estimate from the last time; the exact size is being worked out.) " : "") +
                (r.On ? $"Takes {r.Bytes:N0} bytes with the others ticked now. Taking it out" : $"Adding it{replaces} takes {r.Bytes:N0} bytes; then the ROM")
                + (under ? $" leaves {r.FreeAfter:N0} bytes free." : $" is over the limit by {-r.FreeAfter:N0} bytes."));
        }
        if (now.Over > 0)
        {
            var note = _note.Length > 0 ? _note + "\n" : "";
            if (fixes.Count == 0 && together == null)
                fixes = [.. results.Where(kv => kv.Value.On && kv.Value.Ok && kv.Value.FreeAfter >= 0).OrderBy(kv => kv.Value.Bytes).Select(kv => kv.Key)];
            _problems.Text = note + $"Too big: over the limit by {now.Over:N0} bytes. " + (fixes.Count > 0
                ? $"Taking out any one of these makes it fit: {string.Join(", ", fixes.Select(d => $"{sk.Feature(d)?.Name ?? d} (frees {results[d].Bytes:N0})"))}."
                : together != null ? $"No single function is enough; taking out these together makes it fit: {together}."
                : "Leave something out (the sizes beside each function say what it frees).");
        }
    }

    /// Write the build: the skeleton (and its modules) beside the new file, and the file itself - the chosen functions as defines, then the skeleton - so it can be changed later by editing the define lines.
    async Task MakeFromSkeleton()
    {
        if (Current is not { } sk || _last?.Success != true) return;
        var path = await SaveAsPath();
        if (path == null) return;
        try
        {
            var dir = Path.GetDirectoryName(path)!;
            // the skeleton and its modules go beside the new file. A copy already there that is not exactly the app's (an
            // older one, or one edited by hand for another ROM) is left for the ROMs that use it, and this ROM gets a
            // folder of its own - so a new ROM always starts from the newest skeleton and is never offered an update
            string skName = Path.GetFileName(sk.Path);
            string Target(string d) => Path.Combine(d, skName);
            bool IsApps(string d) => Path.GetFullPath(Target(d)).Equals(Path.GetFullPath(sk.Path), StringComparison.OrdinalIgnoreCase);
            bool Current(string d) => IsApps(d) || (SameFile(Target(d), sk.Path) && (sk.FeaturesDir == null ||
                Directory.GetFiles(sk.FeaturesDir, "*", SearchOption.AllDirectories).All(f =>
                    SameFile(Path.Combine(d, Path.GetFileName(sk.FeaturesDir), Path.GetRelativePath(sk.FeaturesDir, f)), f))));
            string baseDir = dir;
            if (File.Exists(Target(dir)) && !Current(dir)) baseDir = Path.Combine(dir, Path.GetFileNameWithoutExtension(path) + "-base");
            if (Path.GetFullPath(path).Equals(Path.GetFullPath(Target(baseDir)), StringComparison.OrdinalIgnoreCase))
            { _problems.Text = "That is the skeleton's own name - pick another name for the new ROM."; return; }
            Directory.CreateDirectory(baseDir);
            if (!Current(baseDir))
            {
                File.Copy(sk.Path, Target(baseDir), overwrite: true);
                if (sk.FeaturesDir != null) CopyDir(sk.FeaturesDir, Path.Combine(baseDir, Path.GetFileName(sk.FeaturesDir)));
            }
            var include = Path.GetRelativePath(dir, Target(baseDir));
            File.WriteAllText(path, sk.BuildSource(Chosen(), include, Path.GetFileNameWithoutExtension(path)));
            Core.AppLog.Action("new rom", $"created {path} from {sk.Name} with {string.Join(", ", Chosen())}");
            Created = path;
            Close();
        }
        catch (Exception ex) { _problems.Text = "Could not write the ROM: " + ex.Message; }
    }

    static bool SameFile(string a, string b)
    {
        try { return new FileInfo(a).Length == new FileInfo(b).Length && File.ReadAllBytes(a).AsSpan().SequenceEqual(File.ReadAllBytes(b)); }
        catch { return false; }
    }

    static void CopyDir(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var f in Directory.GetFiles(from)) File.Copy(f, Path.Combine(to, Path.GetFileName(f)), overwrite: true);
        foreach (var d in Directory.GetDirectories(from)) CopyDir(d, Path.Combine(to, Path.GetFileName(d)));
    }
}
