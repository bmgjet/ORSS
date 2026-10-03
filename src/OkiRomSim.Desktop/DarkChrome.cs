// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;

using Avalonia.Layout;
namespace OkiRomSim.Desktop;

/// The system title bar is drawn by the OS and stays light on Windows and most Linux desktops, which looks wrong above a dark app. These helpers extend the client area over the decorations and draw a title bar that matches the rest of the window.
public static class DarkChrome
{
    public static readonly Color Background = Color.FromRgb(0x1e, 0x1f, 0x22);
    public static readonly Color Panel = Color.FromRgb(0x26, 0x28, 0x2c);
    public static readonly Color Line = Color.FromRgb(0x3a, 0x3d, 0x44);
    public static readonly Color Accent = Color.FromRgb(0x4e, 0xa1, 0xff);
    public static readonly Color Text = Color.FromRgb(0xd7, 0xda, 0xe0);

    /// Loads the embedded app icon; returns null if the asset is missing so a packaging slip cannot stop the window opening.
    public static Bitmap? LoadIconBitmap()
    {
        try
        {
            using var s = AssetLoader.Open(new Uri("avares://RomSimStudio/Assets/icon.png"));
            return new Bitmap(s);
        }
        catch { return null; }
    }

    public static WindowIcon? LoadWindowIcon()
    {
        try
        {
            using var s = AssetLoader.Open(new Uri("avares://RomSimStudio/Assets/icon.png"));
            return new WindowIcon(s);
        }
        catch { return null; }
    }

    /// Draw our own title bar? Windows and macOS let the app extend over the decorations. On Linux the hint is ignored, so the system bar is asked to go away instead (BorderOnly: the window manager keeps the border and its resize handles, without a light title bar); a window manager that ignores that would show two bars, so `PreferSystemTitleBar` turns ours off again (Settings > General).
    public static bool Custom => !PreferSystemTitleBar;

    /// Set from the settings before any window is built.
    public static bool PreferSystemTitleBar { get; set; }

    /// Turns the window into a borderless dark one and returns the title bar to put at the top of its content (an empty control where the system title bar is kept). Call before assigning Content.
    public static Control Apply(Window w, string title)
    {
        w.Background = AppTheme.Brush(Background);
        w.Icon = LoadWindowIcon();
        w.Opened += (_, _) => ScreenFit.FitWindow(w);
        if (!Custom) { w.SystemDecorations = SystemDecorations.Full; return new Panel { Height = 0 }; }
        if (OperatingSystem.IsWindows() || OperatingSystem.IsMacOS())
        {
            w.SystemDecorations = SystemDecorations.Full;
            w.ExtendClientAreaToDecorationsHint = true;
            w.ExtendClientAreaChromeHints = Avalonia.Platform.ExtendClientAreaChromeHints.NoChrome;
            w.ExtendClientAreaTitleBarHeightHint = -1;
        }
        else
        {
            // X11 / Wayland: keep the frame (so the window can still be resized and snapped) but drop the light title bar and draw ours in its place
            w.SystemDecorations = SystemDecorations.BorderOnly;
        }
        return BuildBar(w, title);
    }

    static Control BuildBar(Window w, string title)
    {
        var bar = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"),
            Height = 34,
            Background = AppTheme.Brush(Panel),
        };

        var left = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 0) };
        var bmp = LoadIconBitmap();
        if (bmp != null)
            left.Children.Add(new Image { Source = bmp, Width = 18, Height = 18, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center });
        var titleText = new TextBlock
        {
            Text = title,
            Foreground = AppTheme.Brush(Text),
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 12,
            FontWeight = FontWeight.SemiBold,
        };
        left.Children.Add(titleText);
        Grid.SetColumn(left, 0);
        bar.Children.Add(left);

        // dragging and double-click maximise, on the empty middle strip and the label
        var drag = new Border { Background = Brushes.Transparent };
        drag.PointerPressed += (_, e) => { if (e.GetCurrentPoint(w).Properties.IsLeftButtonPressed) w.BeginMoveDrag(e); };
        drag.DoubleTapped += (_, _) => Toggle(w);
        Grid.SetColumn(drag, 1);
        bar.Children.Add(drag);
        left.PointerPressed += (_, e) => { if (e.GetCurrentPoint(w).Properties.IsLeftButtonPressed) w.BeginMoveDrag(e); };

        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(CaptionButton("\u2500", () => w.WindowState = WindowState.Minimized, false));
        buttons.Children.Add(CaptionButton("\u2610", () => Toggle(w), false));
        buttons.Children.Add(CaptionButton("\u2715", w.Close, true));
        Grid.SetColumn(buttons, 2);
        bar.Children.Add(buttons);

        // keep the label in step with Window.Title
        w.PropertyChanged += (_, e) =>
        {
            if (e.Property == Window.TitleProperty) titleText.Text = w.Title ?? title;
        };
        return bar;
    }

    static void Toggle(Window w) =>
        w.WindowState = w.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    static Button CaptionButton(string glyph, Action onClick, bool danger)
    {
        var b = new Button
        {
            Content = glyph,
            Width = 44,
            Height = 34,
            Background = Brushes.Transparent,
            Foreground = AppTheme.Brush(Text),
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(0),
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            FontSize = 12,
        };
        b.Click += (_, _) => onClick();
        b.PointerEntered += (_, _) => b.Background = AppTheme.Brush(danger ? Color.FromRgb(0xc0, 0x39, 0x2b) : Line);
        b.PointerExited += (_, _) => b.Background = Brushes.Transparent;
        return b;
    }
}
