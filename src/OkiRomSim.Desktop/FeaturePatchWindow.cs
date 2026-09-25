// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// The code patches in a feature file, against the ROM that is loaded: which ones fit it, which are already in, and Apply / Remove for the one picked. Every change goes through the same undo as any other edit, and a patch is only written where the ROM holds exactly the bytes it expects.
public sealed class FeaturePatchWindow : Window
{
    readonly SimHost _host;
    FeatureFile _file = new();
    string _path;
    readonly ListBox _list = new() { SelectionMode = SelectionMode.Single };
    readonly TextBlock _name = new() { FontWeight = FontWeight.Bold, FontSize = 14, TextWrapping = TextWrapping.Wrap };
    readonly TextBlock _state = new() { FontSize = 12, Margin = new Thickness(0, 2, 0, 6) };
    readonly TextBlock _desc = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
    readonly TextBlock _verified = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11, Opacity = 0.75, Margin = new Thickness(0, 6, 0, 0) };
    readonly TextBlock _sites = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11, FontFamily = MainWindow.MonoFont, Margin = new Thickness(0, 8, 0, 0) };
    readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Margin = new Thickness(12, 4) };
    readonly CheckBox _onlyFits = new() { Content = "only what fits this ROM", IsChecked = true, Margin = new Thickness(0, 0, 0, 4) };
    readonly Button _apply = new() { Content = "Apply", MinWidth = 96 };
    readonly Button _remove = new() { Content = "Remove", MinWidth = 96 };
    public bool Changed { get; private set; }

    public FeaturePatchWindow(SimHost host)
    {
        _host = host;
        Title = "Feature patches";
        Width = 860; Height = 560; MinWidth = 640; MinHeight = 380;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        _path = FeatureFile.DefaultPath;

        var open = new Button { Content = "Open…", MinWidth = 80 };
        ToolTip.SetTip(open, "Load a different feature file.");
        open.Click += async (_, _) => await PickFile();
        _apply.Click += (_, _) => Change(remove: false);
        _remove.Click += (_, _) => Change(remove: true);
        ToolTip.SetTip(_apply, "Write this feature's bytes into the ROM (Undo takes it back).");
        ToolTip.SetTip(_remove, "Put back the bytes this feature replaced.");
        _list.SelectionChanged += (_, _) => ShowSelected();
        _onlyFits.IsCheckedChanged += (_, _) => Fill();

        var left = new DockPanel { Margin = new Thickness(12, 8, 6, 8) };
        var top = new StackPanel { Spacing = 4 };
        top.Children.Add(_onlyFits);
        DockPanel.SetDock(top, Dock.Top); left.Children.Add(top);
        left.Children.Add(_list);

        var right = new ScrollViewer
        {
            Margin = new Thickness(6, 8, 12, 8),
            Content = new StackPanel { Children = { _name, _state, _desc, _verified, _sites } },
        };
        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("340,*") };
        Grid.SetColumn(left, 0); body.Children.Add(left);
        Grid.SetColumn(right, 1); body.Children.Add(right);

        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(12, 4, 12, 12), HorizontalAlignment = HorizontalAlignment.Right };
        var close = new Button { Content = "Close", MinWidth = 96 };
        close.Click += (_, _) => Close();
        bar.Children.Add(open); bar.Children.Add(_remove); bar.Children.Add(_apply); bar.Children.Add(close);

        var chrome = DarkChrome.Apply(this, "Feature patches");
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto,Auto") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(body, 1); g.Children.Add(body);
        Grid.SetRow(_status, 2); g.Children.Add(_status);
        Grid.SetRow(bar, 3); g.Children.Add(bar);
        Content = g;
        Load(_path);
    }

    void Load(string path)
    {
        try
        {
            _file = FeatureFile.Load(path);
            _path = path;
            _status.Text = $"{_file.Features.Count} features from {path}";
            ToolTip.SetTip(_status, _file.About);
        }
        catch (Exception ex)
        {
            _file = new FeatureFile();
            _status.Text = $"no feature file loaded ({ex.Message}) - use Open…";
        }
        Fill();
    }

    async Task PickFile()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Feature file", AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("Feature file") { Patterns = ["*.json"] }],
        });
        if (files.FirstOrDefault()?.TryGetLocalPath() is { } p) Load(p);
    }

    sealed record Row(Feature Feature, FeatureCheck Check)
    {
        public override string ToString() => $"{Mark(Check.State)}  {Feature.Name}";
        static string Mark(FeatureState s) => s switch
        {
            FeatureState.Applied => "●", FeatureState.Available => "○", FeatureState.Partial => "◐", _ => "–",
        };
    }

    void Fill(string? keep = null)
    {
        keep ??= (_list.SelectedItem as Row)?.Feature.Id;
        var rom = _host.RomCopy();
        var rows = _file.Features.Select(f => new Row(f, FeaturePatches.Check(f, rom)))
            .Where(r => _onlyFits.IsChecked != true || r.Check.State != FeatureState.NotApplicable).ToList();
        _list.ItemsSource = rows;
        _list.SelectedItem = rows.FirstOrDefault(r => r.Feature.Id == keep) ?? rows.FirstOrDefault();
        ShowSelected();
    }

    void ShowSelected()
    {
        if (_list.SelectedItem is not Row r)
        {
            _name.Text = _file.Features.Count == 0 ? "" : "Nothing in this file fits the ROM that is loaded.";
            _state.Text = _desc.Text = _verified.Text = _sites.Text = "";
            _apply.IsEnabled = _remove.IsEnabled = false;
            return;
        }
        _name.Text = r.Feature.Name;
        _state.Text = $"{r.Feature.Category} - {r.Check.Detail}";
        _desc.Text = r.Feature.Description;
        _verified.Text = r.Feature.Verified.Length == 0 ? "" : "Checked: " + r.Feature.Verified;
        _sites.Text = r.Check.Variant == null ? "" : string.Join("\n", r.Check.Variant.Sites.Select(s =>
            $"{s.Address}: {s.Original} -> {s.Patched}{(s.Note != null ? "   " + s.Note : "")}"));
        _apply.IsEnabled = r.Check.State is FeatureState.Available or FeatureState.Partial;
        _remove.IsEnabled = r.Check.State is FeatureState.Applied or FeatureState.Partial;
    }

    void Change(bool remove)
    {
        if (_list.SelectedItem is not Row r) return;
        try
        {
            var patches = FeaturePatches.Patches(r.Feature, _host.RomCopy(), remove, _file.ChecksumByte);
            int n = _host.ApplyPatches(patches, $"{(remove ? "remove" : "apply")} feature {r.Feature.Id}");
            Changed |= n > 0;
            AppLog.Action("features", $"{(remove ? "removed" : "applied")} {r.Feature.Id}: {n} byte(s)");
            _status.Text = n == 0 ? "nothing to change" : $"{r.Feature.Name}: {n} byte(s) {(remove ? "restored" : "written")} - Undo takes it back.";
        }
        catch (Exception ex) { _status.Text = "could not change it: " + ex.Message; AppLog.Error("features", "feature patch failed", ex); }
        Fill(r.Feature.Id);
    }
}
