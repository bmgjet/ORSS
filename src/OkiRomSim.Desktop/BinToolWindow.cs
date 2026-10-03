// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;

namespace OkiRomSim.Desktop;

/// File > Bin tool…: 32 KB ROMs and 64 KB (27C512 / SST27SF512) chips. The ECU sees 32 KB; a 64 KB chip holds two of them, 0000-7FFF and 8000-FFFF, and the ECU runs whichever half its top address line picks - the high half on a board with A15 tied high, so a single ROM goes in the upper half with the lower one blank, or either half on a board with a switch on that line (two tunes on one chip). Make a 64 KB image from one or two ROMs, or split one back in two.
public sealed class BinToolWindow : Window
{
    const int Half = 0x8000;
    readonly Func<byte[]?> _current;
    readonly string _currentName;
    readonly Slot _low, _high;
    readonly ComboBox _fill = new() { ItemsSource = new[] { "FF (erased chip)", "00" }, SelectedIndex = 0, Width = 150 };
    readonly TextBlock _status = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };

    /// One half of the chip: blank, the ROM open now, or a file.
    sealed class Slot
    {
        public readonly ComboBox Source = new() { Width = 200 };
        public readonly TextBlock File = new() { FontSize = 11.5, Opacity = 0.85, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 380 };
        public string? Path;
    }

    public BinToolWindow(Func<byte[]?> current, string currentName)
    {
        _current = current; _currentName = currentName;
        Title = "Bin tool";
        Width = 700; SizeToContent = SizeToContent.Height; CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var chrome = DarkChrome.Apply(this, "Bin tool: 32 KB ROMs and 64 KB chips");
        _low = MakeSlot(0); _high = MakeSlot(1);

        var body = new StackPanel { Margin = new Thickness(14, 8, 14, 12), Spacing = 6 };
        body.Children.Add(new TextBlock
        {
            Text = "The ECU reads 32 KB. A 64 KB chip (27C512, SST27SF512) holds two 32 KB halves: 0000-7FFF and 8000-FFFF. " +
                   "On a board with the top address line tied high the ECU runs the upper half, so one ROM goes there with the lower " +
                   "half padded; with a switch on that line the board can run either half - two tunes on one chip.",
            TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.8, Margin = new Thickness(0, 0, 0, 6),
        });
        body.Children.Add(Heading("Make a 64 KB image"));
        body.Children.Add(Row("Lower half 0000-7FFF", _low));
        body.Children.Add(Row("Upper half 8000-FFFF", _high));
        var fillRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        fillRow.Children.Add(new TextBlock { Text = "Blank half filled with", Width = 160, VerticalAlignment = VerticalAlignment.Center });
        fillRow.Children.Add(_fill);
        ToolTip.SetTip(_fill, "What a blank half holds: FF is what an erased chip reads (and burns fastest); 00 is what HTS writes.");
        body.Children.Add(fillRow);
        body.Children.Add(Btn("Save 64 KB image…", Save64, "Write the two halves one after the other: a 65,536-byte file for a 512 chip."));

        body.Children.Add(Heading("Split a 64 KB image"));
        body.Children.Add(Btn("Split into two 32 KB ROMs…", Split,
            "Pick a 65,536-byte image: its lower half is saved as name_low.bin and its upper half as name_high.bin, beside it."));
        body.Children.Add(_status);

        var close = Btn("Close", Close, "");
        close.IsCancel = true;
        var foot = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(14, 0, 14, 12) };
        foot.Children.Add(close);
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,Auto") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(body, 1); g.Children.Add(body);
        Grid.SetRow(foot, 2); g.Children.Add(foot);
        Content = g;
    }

    Slot MakeSlot(int which)
    {
        var s = new Slot();
        s.Source.ItemsSource = new[] { "Blank", "The ROM open now" + (_currentName.Length > 0 ? $" ({_currentName})" : ""), "A file…" };
        s.Source.SelectedIndex = which == 0 ? 0 : (_current() != null ? 1 : 2);
        s.Source.SelectionChanged += async (_, _) =>
        {
            if (s.Source.SelectedIndex == 2) await PickFile(s);
            Show(s);
        };
        Show(s);
        return s;
    }

    static void Show(Slot s) => s.File.Text = s.Source.SelectedIndex == 2 ? s.Path ?? "(no file picked)" : "";

    async Task PickFile(Slot s)
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "A 32 KB ROM", AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("ROM image") { Patterns = ["*.bin", "*.rom"] }, FilePickerFileTypes.All],
        });
        var p = files.FirstOrDefault()?.TryGetLocalPath();
        if (p == null) { if (s.Path == null) s.Source.SelectedIndex = 0; return; }
        s.Path = p;
    }

    /// A half's 32 KB, or null (with the reason shown) when it cannot be had.
    byte[]? Bytes(Slot s, string which)
    {
        byte fill = (byte)(_fill.SelectedIndex == 0 ? 0xFF : 0x00);
        switch (s.Source.SelectedIndex)
        {
            case 0: { var b = new byte[Half]; Array.Fill(b, fill); return b; }
            case 1:
                if (_current() is { } rom && rom.Length >= Half) return rom[..Half];
                _status.Text = $"The {which} half: no ROM is open."; return null;
            default:
                if (s.Path == null) { _status.Text = $"The {which} half: pick a file."; return null; }
                var data = File.ReadAllBytes(s.Path);
                if (data.Length == Half + 1 && data[^1] == 0) data = data[..Half];        // a burner's trailing byte
                if (data.Length != Half) { _status.Text = $"The {which} half: {System.IO.Path.GetFileName(s.Path)} is {data.Length:N0} bytes, not 32,768."; return null; }
                return data;
        }
    }

    async void Save64()
    {
        try
        {
            var low = Bytes(_low, "lower"); if (low == null) return;
            var high = Bytes(_high, "upper"); if (high == null) return;
            var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
            {
                Title = "Save a 64 KB image", DefaultExtension = "bin",
                SuggestedFileName = (_currentName.Length > 0 ? System.IO.Path.GetFileNameWithoutExtension(_currentName) : "rom") + "_512.bin",
                FileTypeChoices = [new FilePickerFileType("64 KB ROM image") { Patterns = ["*.bin"] }],
            });
            var path = file?.TryGetLocalPath();
            if (path == null) return;
            OkiRomSim.Core.SafeFile.WriteAllBytes(path, [.. low, .. high]);
            _status.Text = $"Saved {path}: 65,536 bytes, the lower half at 0000-7FFF and the upper at 8000-FFFF.";
        }
        catch (Exception ex) { _status.Text = "Could not save: " + ex.Message; }
    }

    async void Split()
    {
        try
        {
            var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "A 64 KB image to split", AllowMultiple = false,
                FileTypeFilter = [new FilePickerFileType("ROM image") { Patterns = ["*.bin", "*.rom"] }, FilePickerFileTypes.All],
            });
            var path = files.FirstOrDefault()?.TryGetLocalPath();
            if (path == null) return;
            var data = File.ReadAllBytes(path);
            if (data.Length != Half * 2) { _status.Text = $"{System.IO.Path.GetFileName(path)} is {data.Length:N0} bytes, not 65,536."; return; }
            var dir = System.IO.Path.GetDirectoryName(path)!;
            var name = System.IO.Path.GetFileNameWithoutExtension(path);
            string lowPath = System.IO.Path.Combine(dir, name + "_low.bin"), highPath = System.IO.Path.Combine(dir, name + "_high.bin");
            OkiRomSim.Core.SafeFile.WriteAllBytes(lowPath, data[..Half]);
            OkiRomSim.Core.SafeFile.WriteAllBytes(highPath, data[Half..]);
            bool lowBlank = data[..Half].All(b => b == 0xFF) || data[..Half].All(b => b == 0);
            _status.Text = $"Saved {System.IO.Path.GetFileName(lowPath)} (0000-7FFF{(lowBlank ? ", blank" : "")}) and {System.IO.Path.GetFileName(highPath)} (8000-FFFF) beside it.";
        }
        catch (Exception ex) { _status.Text = "Could not split: " + ex.Message; }
    }

    static TextBlock Heading(string t) => new() { Text = t, FontWeight = FontWeight.Bold, FontSize = 12.5, Margin = new Thickness(0, 8, 0, 2) };

    static Control Row(string label, Slot s)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        p.Children.Add(new TextBlock { Text = label, Width = 160, VerticalAlignment = VerticalAlignment.Center });
        p.Children.Add(s.Source);
        p.Children.Add(s.File);
        ToolTip.SetTip(s.Source, "Blank (padding), the ROM open now (with its calibration changes), or a 32 KB file.");
        return p;
    }

    static Button Btn(string text, Action a, string tip)
    {
        var b = new Button { Content = text, MinWidth = 96, HorizontalAlignment = HorizontalAlignment.Left };
        b.Click += (_, _) => a();
        if (tip.Length > 0) ToolTip.SetTip(b, tip);
        return b;
    }
}
