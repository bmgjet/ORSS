using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace OkiRomSim.Desktop;

/// Small modal questions, in the same dark chrome as the rest of the program: "you are about to replace what is open - what would you like to do?". Returns which button was pressed, or null when the window was closed without choosing (treated as cancel everywhere).
public static class Dialogs
{
    public static async Task<string?> Ask(Window owner, string title, string message, params string[] buttons)
    {
        var w = new Window
        {
            Title = title,
            Width = 520,
            SizeToContent = SizeToContent.Height,
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false,
        };
        var chrome = DarkChrome.Apply(w, title);

        string? answer = null;
        var text = new TextBlock
        {
            Text = message,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(16, 14, 16, 8),
            Foreground = new SolidColorBrush(DarkChrome.Text),
        };
        var bar = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Spacing = 6,
            Margin = new Thickness(16, 6, 16, 14),
        };
        for (int i = 0; i < buttons.Length; i++)
        {
            var label = buttons[i];
            var b = new Button { Content = label, MinWidth = 96 };
            if (i == buttons.Length - 1) b.IsDefault = true;      // last button is the safe / expected one
            if (label.Equals("Cancel", StringComparison.OrdinalIgnoreCase)) b.IsCancel = true;
            b.Click += (_, _) => { answer = label; w.Close(); };
            bar.Children.Add(b);
        }

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(text, 1); g.Children.Add(text);
        Grid.SetRow(bar, 2); g.Children.Add(bar);
        w.Content = g;

        await w.ShowDialog(owner);
        OkiRomSim.Core.AppLog.Action("ui", $"{title}: {answer ?? "(closed)"}");
        return answer;
    }

    /// Yes / No, where No is also what closing the window means.
    public static async Task<bool> Confirm(Window owner, string title, string message, string yes = "Yes", string no = "No")
        => (await Ask(owner, title, message, yes, no)) == yes;
}
