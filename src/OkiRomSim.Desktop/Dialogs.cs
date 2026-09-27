// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace OkiRomSim.Desktop;

/// Small modal questions, in the same dark chrome as the rest of the program: "you are about to replace what is open - what would you like to do?". Returns which button was pressed, or null when the window was closed without choosing (treated as cancel everywhere).
public static class Dialogs
{
    /// Show a dialog over `owner`, or, when that window is not on screen (closed, not open yet, hidden), over whichever window of the program is; with none on screen, on its own. Returns when it is closed.
    public static async Task ShowModal(Window w, Window? owner)
    {
        owner = owner is { IsVisible: true } ? owner
              : (Avalonia.Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?
                    .Windows.LastOrDefault(x => x.IsVisible && x != w);
        if (owner != null) { await w.ShowDialog(owner); return; }
        w.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var done = new TaskCompletionSource();
        w.Closed += (_, _) => done.TrySetResult();
        w.Show();
        await done.Task;
    }


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

        await ShowModal(w, owner);
        OkiRomSim.Core.AppLog.Action("ui", $"{title}: {answer ?? "(closed)"}");
        return answer;
    }

    /// A question with something to fill in: the message, one control of the caller's (a text box, a number box, a whole panel), then Cancel and OK. True means OK was pressed; whatever the caller put in the control is where the answer is.
    public static async Task<bool> Prompt(Window owner, string title, string message, Control editor, string ok = "OK")
    {
        var w = new Window
        {
            Title = title, Width = 480, SizeToContent = SizeToContent.Height, CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        var chrome = DarkChrome.Apply(w, title);
        bool accepted = false;

        var body = new StackPanel { Margin = new Thickness(16, 14, 16, 8), Spacing = 8 };
        body.Children.Add(new TextBlock
        {
            Text = message, TextWrapping = TextWrapping.Wrap, Foreground = new SolidColorBrush(DarkChrome.Text),
        });
        editor.HorizontalAlignment = HorizontalAlignment.Left;
        body.Children.Add(editor);

        var bar = new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Spacing = 6, Margin = new Thickness(16, 6, 16, 14),
        };
        var cancel = new Button { Content = "Cancel", MinWidth = 96, IsCancel = true };
        cancel.Click += (_, _) => w.Close();
        var accept = new Button { Content = ok, MinWidth = 96, IsDefault = true };
        accept.Click += (_, _) => { accepted = true; w.Close(); };
        bar.Children.Add(cancel); bar.Children.Add(accept);

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(body, 1); g.Children.Add(body);
        Grid.SetRow(bar, 2); g.Children.Add(bar);
        w.Content = g;
        w.Opened += (_, _) => editor.Focus();

        await ShowModal(w, owner);
        OkiRomSim.Core.AppLog.Action("ui", $"{title}: {(accepted ? ok : "cancelled")}");
        return accepted;
    }

    /// Yes / No, where No is also what closing the window means.
    public static async Task<bool> Confirm(Window owner, string title, string message, string yes = "Yes", string no = "No")
        => (await Ask(owner, title, message, yes, no)) == yes;
}
