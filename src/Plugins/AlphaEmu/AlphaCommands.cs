// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Desktop;

namespace AlphaEmuPlugin;

/// A command the ALPHAemu console knows about: what it is called, what it does, and a few words to
/// search on. The palette is the fastest way into the lot of them, and the same list is what the
/// menu and toolbar entries are built from, so nothing drifts apart.
public sealed record AlphaCommand(string Name, string Hint, string[] Keywords, Action Run, string Group = "ALPHAemu");

/// Type to find, Enter to run: the ALPHAlink command palette, in a window of its own. The window is
/// remembered on the hub, so the menu, the key binding and the commands list all raise the same one.
public sealed class AlphaPalette
{
    readonly AlphaHub _hub;
    Window? Window => _hub.PaletteWindow;

    public AlphaPalette(AlphaHub hub) { _hub = hub; }

    public void Show()
    {
        if (Window is { IsVisible: true }) { Window.Activate(); return; }
        var search = new TextBox { FontSize = 15, Watermark = "type what you want to do…", Padding = new Thickness(8, 6) };
        var list = new ListBox { FontSize = 13 };
        var detail = new TextBlock { FontSize = 11, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(2, 6, 2, 0) };
        var all = _hub.Commands;

        void Fill()
        {
            string q = (search.Text ?? "").Trim();
            var hits = all.Where(c => Score(c, q) > 0).OrderByDescending(c => Score(c, q)).ThenBy(c => c.Group).ThenBy(c => c.Name).Take(80).ToList();
            list.ItemsSource = hits.Select(c => $"{c.Group}   ·   {c.Name}").ToList();
            list.Tag = hits;
            if (hits.Count > 0) list.SelectedIndex = 0;
            detail.Text = hits.Count == 0
                ? "nothing matches that"
                : hits.Count + " of " + all.Count + " commands - Enter runs the top one, Esc closes";
            if (list.SelectedItem is string sel && hits.Count > 0)
            {
                var c = hits[list.SelectedIndex];
                detail.Text = c.Hint + "   ·   " + c.Group;
            }
        }

        void RunSelected()
        {
            if (list.Tag is not List<AlphaCommand> hits) return;
            int i = list.SelectedIndex >= 0 ? list.SelectedIndex : 0;
            if (i < 0 || i >= hits.Count) return;
            var cmd = hits[i];
            _hub.PaletteWindow?.Close();
            cmd.Run();
        }

        search.TextChanged += (_, _) => Fill();
        search.KeyDown += (_, e) =>
        {
            switch (e.Key)
            {
                case Key.Enter: RunSelected(); e.Handled = true; break;
                case Key.Escape: _hub.PaletteWindow?.Close(); e.Handled = true; break;
                case Key.Down when list.Items.Count > 0: list.SelectedIndex = Math.Min(list.Items.Count - 1, list.SelectedIndex + 1); e.Handled = true; break;
                case Key.Up: list.SelectedIndex = Math.Max(0, list.SelectedIndex - 1); e.Handled = true; break;
            }
        };
        list.PointerPressed += (_, e) => { if (e.ClickCount == 2) RunSelected(); };

        var body = new DockPanel { Margin = new Thickness(10) };
        DockPanel.SetDock(search, Dock.Top); body.Children.Add(search);
        var bottom = new StackPanel();
        bottom.Children.Add(new Separator { Margin = new Thickness(0, 6) });
        bottom.Children.Add(detail);
        DockPanel.SetDock(bottom, Dock.Bottom); body.Children.Add(bottom);
        body.Children.Add(new ScrollViewer { Content = list });

        _hub.PaletteWindow = _hub.App.OpenWindow("ALPHAemu commands", body, 640, 460);
        var w = _hub.PaletteWindow;
        if (w != null)
        {
            w.Closed += (_, _) => { if (ReferenceEquals(_hub.PaletteWindow, w)) _hub.PaletteWindow = null; };
            w.Opened += (_, _) => { search.Focus(); Fill(); };
        }
    }

    static int Score(AlphaCommand c, string q)
    {
        if (q.Length == 0) return 1;
        int score = 0;
        if (c.Name.Contains(q, StringComparison.OrdinalIgnoreCase)) score += 40;
        if (c.Name.StartsWith(q, StringComparison.OrdinalIgnoreCase)) score += 30;
        foreach (var k in c.Keywords) if (k.Contains(q, StringComparison.OrdinalIgnoreCase)) score += 12;
        if (c.Group.Contains(q, StringComparison.OrdinalIgnoreCase)) score += 6;
        if (c.Hint.Contains(q, StringComparison.OrdinalIgnoreCase)) score += 3;
        return score;
    }
}


