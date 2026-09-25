// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;

namespace OkiRomSim.Desktop;

/// File > New ROM: start a ROM from a template (a finished .asm in the Templates folder, copied to a file of your own and opened), or - still to come - build one from a minimal base ROM and a list of features.
public sealed class NewRomWindow : Window
{
    /// The file to open when the window closes, or null when it was cancelled.
    public string? Created { get; private set; }

    readonly ListBox _list = new() { MinHeight = 220 };
    readonly TextBlock _about = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.85, Margin = new Thickness(0, 6, 0, 0) };
    readonly List<string> _files = [];

    public NewRomWindow()
    {
        Title = "New ROM";
        Width = 620; Height = 520; MinWidth = 480; MinHeight = 400;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var existing = new RadioButton { Content = "Existing - start from a template", GroupName = "kind", IsChecked = true, FontWeight = FontWeight.SemiBold };
        // Create (a minimal ROM plus the features you pick) is the next piece of work: hidden until it exists
        var create = new RadioButton { Content = "Create - a minimal ROM and the features you pick", GroupName = "kind", IsEnabled = false, IsVisible = false };
        ToolTip.SetTip(create,
            "Pick a minimal base ROM - the special functions stripped and the stock routines cut down to hooks - then the features " +
            "you want. Each one is added where it fits, with no code or address collisions, until the ROM is full. Not built yet.");

        var folder = Templates();
        if (folder != null) _files.AddRange(Directory.GetFiles(folder, "*.asm").OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase));
        _list.ItemsSource = _files.Select(Path.GetFileNameWithoutExtension).ToList();
        _list.SelectionChanged += (_, _) => Describe();
        _list.DoubleTapped += async (_, _) => await Make();
        if (_files.Count > 0) _list.SelectedIndex = 0;

        var ok = new Button { Content = "Create from template…", IsDefault = true, IsEnabled = _files.Count > 0 };
        ToolTip.SetTip(ok, "Choose where the new ROM's source goes; the template is copied there and opened. The template itself is never changed.");
        ok.Click += async (_, _) => await Make();
        var cancel = new Button { Content = "Cancel", IsCancel = true };
        cancel.Click += (_, _) => Close();
        var openFolder = new Button { Content = "Open templates folder" };
        ToolTip.SetTip(openFolder, "Any .asm put in this folder is offered here.");
        openFolder.Click += (_, _) =>
        {
            if (Templates() is { } dir)
                try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(dir) { UseShellExecute = true }); } catch { }
        };

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        buttons.Children.Add(openFolder);
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);

        var body = new DockPanel { Margin = new Thickness(14, 12) };
        var top = new StackPanel { Spacing = 6 };
        top.Children.Add(existing);
        top.Children.Add(new TextBlock
        {
            Text = folder == null ? "No Templates folder was found next to the app." : $"Templates in {folder}",
            FontSize = 11, Opacity = 0.7, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(22, 0, 0, 0),
        });
        DockPanel.SetDock(top, Dock.Top);
        body.Children.Add(top);
        var bottom = new StackPanel();
        bottom.Children.Add(create);
        bottom.Children.Add(buttons);
        DockPanel.SetDock(bottom, Dock.Bottom);
        body.Children.Add(bottom);
        var mid = new DockPanel { Margin = new Thickness(22, 6, 0, 10) };
        // the description scrolls in a box of its own, so a long one never covers the list
        var aboutBox = new ScrollViewer { Content = _about, MaxHeight = 150, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        DockPanel.SetDock(aboutBox, Dock.Bottom);
        mid.Children.Add(aboutBox);
        _list.MinHeight = 60;
        mid.Children.Add(_list);
        body.Children.Add(mid);
        var chrome = DarkChrome.Apply(this, Title);
        var root = new DockPanel();
        DockPanel.SetDock(chrome, Dock.Top);
        root.Children.Add(chrome);
        root.Children.Add(body);
        Content = root;
        Describe();
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
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Save the new ROM source as",
            SuggestedFileName = Path.GetFileNameWithoutExtension(template) + "_new.asm",
            DefaultExtension = "asm",
            FileTypeChoices = [new FilePickerFileType("Assembler source") { Patterns = ["*.asm"] }],
        });
        var path = file?.TryGetLocalPath();
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
}
