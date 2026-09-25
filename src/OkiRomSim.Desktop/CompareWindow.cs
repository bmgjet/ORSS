// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using OkiRomSim.Core;
using OkiRomSim.Mcp;

namespace OkiRomSim.Desktop;

/// Compare the ROM open in the app with another .bin / .asm: what changed in function and features (routines added, removed, changed, moved) and in the calibration tables.
public sealed class CompareWindow : Window
{
    readonly Func<Program66k?> _current;
    readonly TextBox _report = new() { IsReadOnly = true, AcceptsReturn = true, FontFamily = MainWindow.MonoFont, FontSize = 11.5, TextWrapping = TextWrapping.Wrap };
    readonly TextBlock _status = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0), TextWrapping = TextWrapping.Wrap, MaxWidth = 420 };
    readonly CheckBox _functions = new() { Content = "Functions", IsChecked = true };
    readonly CheckBox _tables = new() { Content = "Tables", IsChecked = true };
    string? _a, _b;

    public CompareWindow(Func<Program66k?> current, string? currentName)
    {
        _current = current;
        Title = "Compare ROMs";
        Width = 980; Height = 700; MinWidth = 600; MinHeight = 360;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var chrome = DarkChrome.Apply(this, "Compare ROMs");
        var bar = new WrapPanel { Margin = new Thickness(8, 6) };
        var pickA = new Button { Content = currentName != null ? $"A: {Path.GetFileName(currentName)} (open in the app)" : "A: pick…" };
        pickA.Click += async (_, _) => { if (await Pick("First ROM (A)") is { } p) { _a = p; pickA.Content = "A: " + Path.GetFileName(p); } };
        var pickB = new Button { Content = "B: pick…", Margin = new Thickness(6, 0) };
        pickB.Click += async (_, _) => { if (await Pick("Second ROM (B)") is { } p) { _b = p; pickB.Content = "B: " + Path.GetFileName(p); Run(); } };
        var run = new Button { Content = "Compare", Margin = new Thickness(6, 0) };
        run.Click += (_, _) => Run();
        var save = new Button { Content = "Save report…" };
        save.Click += async (_, _) =>
        {
            var f = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions { Title = "Save the comparison", SuggestedFileName = "compare.txt", DefaultExtension = "txt" });
            if (f?.TryGetLocalPath() is { } path) File.WriteAllText(path, _report.Text ?? "");
        };
        bar.Children.Add(pickA); bar.Children.Add(pickB);
        bar.Children.Add(_functions); bar.Children.Add(_tables);
        _functions.Margin = _tables.Margin = new Thickness(10, 0, 0, 0);
        bar.Children.Add(run); bar.Children.Add(save); bar.Children.Add(_status);
        ToolTip.SetTip(_functions, "Routines reached from the vectors in each ROM, matched by their code: added, removed, changed (with the hardware, calls and tables gained or lost) and moved.");
        ToolTip.SetTip(_tables, "Maps and settings detected in both, compared cell by cell where they sit at the same address.");
        _report.Text = "Pick the ROM to compare with (B). A is the ROM open in the app unless you pick another.";
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(bar, 1); g.Children.Add(bar);
        // the report box scrolls itself and wraps long lines at the window's edge, so nothing runs off the side
        _report.Margin = new Thickness(8, 0, 8, 8);
        ScrollViewer.SetHorizontalScrollBarVisibility(_report, Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled);
        Grid.SetRow(_report, 2); g.Children.Add(_report);
        Content = g;
        Opened += (_, _) => FitToScreen(this);
    }

    /// Never bigger than the screen it opens on (a 980 x 700 window does not fit a small laptop at 150%).
    public static void FitToScreen(Window w)
    {
        if (w.Screens.ScreenFromWindow(w) is not { } scr) return;
        double availW = scr.WorkingArea.Width / scr.Scaling * 0.95, availH = scr.WorkingArea.Height / scr.Scaling * 0.92;
        if (w.Bounds.Width > availW) w.Width = availW;
        if (w.Bounds.Height > availH) w.Height = availH;
        // and back fully on it
        double ww = double.IsNaN(w.Width) ? w.Bounds.Width : w.Width, wh = double.IsNaN(w.Height) ? w.Bounds.Height : w.Height;
        var size = new PixelSize((int)(ww * scr.Scaling), (int)(wh * scr.Scaling));
        var wa = scr.WorkingArea;
        int x = Math.Clamp(w.Position.X, wa.X, Math.Max(wa.X, wa.Right - size.Width));
        int y = Math.Clamp(w.Position.Y, wa.Y, Math.Max(wa.Y, wa.Bottom - size.Height));
        if (x != w.Position.X || y != w.Position.Y) w.Position = new PixelPoint(x, y);
    }

    async Task<string?> Pick(string title)
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = title,
            FileTypeFilter = new[] { new FilePickerFileType("ROM image or source") { Patterns = new[] { "*.bin", "*.rom", "*.asm" } } },
        });
        return files.FirstOrDefault()?.TryGetLocalPath();
    }

    void Run()
    {
        if (_b == null) { _status.Text = "pick B first"; return; }
        _status.Text = "comparing… (following the code of both ROMs)";
        var a = _a; var b = _b;
        var opts = new RomCompare.Options(_functions.IsChecked == true, _tables.IsChecked == true, 200);
        var cur = a == null ? _current() : null;
        Task.Run(() =>
        {
            try
            {
                var pa = a != null ? Program66k.Load(a) : cur ?? throw new InvalidOperationException("nothing is open in the app: pick A");
                var pb = Program66k.Load(b);
                var r = RomCompare.Compare(pa, pb, opts);
                Dispatcher.UIThread.Post(() => { _report.Text = r; _status.Text = "done"; });
                AppLog.Action("compare", $"compared {pa.Path} with {pb.Path}");
            }
            catch (Exception ex)
            {
                Dispatcher.UIThread.Post(() => { _status.Text = "compare failed: " + ex.Message; });
                AppLog.Error("compare", "failed", ex);
            }
        });
    }
}
