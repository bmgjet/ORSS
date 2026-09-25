// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Platform;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Fitting the app to the screen it is on. The layout is drawn for a 1080p screen; on a smaller one (a 1366 x 768 laptop) everything is scaled down a little rather than squeezed, the panels are shared out to suit, and any window that would still not fit is scaled down until it does. Settings > General > "Fit to the screen" turns the automatic part off (moving the UI scale does too).
public static class ScreenFit
{
    /// The working area the layout is designed around, in device-independent pixels (1080p less the taskbar).
    const double DesignW = 1920, DesignH = 1040;
    /// Never smaller than this: below it the text gets hard to read on a laptop panel.
    const double Smallest = 0.8;

    /// The UI scale the main window uses now; dialogs open at the same scale.
    public static double UiScale { get; set; } = 1;

    public static string Key(Screen s) => $"{s.WorkingArea.Width}x{s.WorkingArea.Height}@{s.Scaling:0.##}";

    /// Working area in device-independent pixels.
    public static Size Dip(Screen s) => new(s.WorkingArea.Width / s.Scaling, s.WorkingArea.Height / s.Scaling);

    /// The scale that makes the design fit this screen: 1 on 1080p and bigger (the display's own scaling already sizes things for a 4K or 6K monitor), down to 0.8 on a 1366 x 768 laptop.
    public static double ScaleFor(Size dip)
    {
        double k = Math.Min(1, Math.Min(dip.Width / DesignW * 1.13, dip.Height / DesignH * 1.08));
        return Math.Round(Math.Clamp(k, Smallest, 1) * 20) / 20;
    }

    /// Choose the defaults for this screen when it is not the one they were last chosen for: the UI scale, how the columns and the bottom panel share the window, and a window that fills the screen. Returns true when anything changed.
    public static bool Fit(AppSettings s, Screen? scr)
    {
        if (scr == null || !s.FitToScreen) return false;
        var key = Key(scr);
        if (s.FittedFor == key) return false;
        var dip = Dip(scr);
        s.UiScale = ScaleFor(dip);
        double effectiveW = dip.Width / s.UiScale;
        // a narrow screen gives the middle column (source, maps, datalog) more of the width
        (s.LeftColumn, s.CentreColumn, s.RightColumn) = effectiveW < 1800 ? ("2.4*", "4.8*", "2.8*") : ("3*", "4*", "3*");
        // and a short one gives the tabbed panel under the source (maps, datalog) more of the height
        s.BottomPanel = dip.Height / s.UiScale < 1000 ? "1.9*" : "1.5*";
        s.Maximized = dip.Width < 1700 || dip.Height < 950;
        s.WindowWidth = Math.Round(dip.Width * 0.9); s.WindowHeight = Math.Round(dip.Height * 0.9);
        s.WindowX = s.WindowY = null;
        s.FittedFor = key;
        AppLog.Info("app", $"fitted to a {scr.WorkingArea.Width}x{scr.WorkingArea.Height} working area at {scr.Scaling * 100:0}% display scaling: UI scale {s.UiScale * 100:0}%");
        return true;
    }

    /// A window other than the main one, once it is open: drawn at the app's UI scale, and scaled down further if even then it would not fit the screen, so its inputs are never off the edge. Its content goes inside a scaler; everything else about it is untouched.
    public static void FitWindow(Window w)
    {
        if (w is MainWindow || w.Content is not Control content) return;
        var scr = w.Screens.ScreenFromWindow(w) ?? w.Screens.Primary;
        if (scr == null) return;
        var dip = Dip(scr);
        double availW = dip.Width * 0.96, availH = dip.Height * 0.94;

        // the size the window wants at 100%: what it was given, or what its content needs
        double width = double.IsNaN(w.Width) ? w.Bounds.Width : w.Width;
        double height = double.IsNaN(w.Height) ? w.Bounds.Height : w.Height;
        if (w.SizeToContent != SizeToContent.Manual)
        {
            content.Measure(new Size(w.SizeToContent.HasFlag(SizeToContent.Width) ? double.PositiveInfinity : width, double.PositiveInfinity));
            if (w.SizeToContent.HasFlag(SizeToContent.Height)) height = Math.Ceiling(content.DesiredSize.Height) + 2;
            if (w.SizeToContent.HasFlag(SizeToContent.Width)) width = Math.Ceiling(content.DesiredSize.Width) + 2;
            w.SizeToContent = SizeToContent.Manual;
            w.CanResize = true;
        }

        double k = Math.Clamp(UiScale, 0.5, 3);
        double fit = Math.Min(1, Math.Min(availW / (width * k), availH / (height * k)));
        // a very tall form scrolls rather than shrinking to nothing
        k = Math.Max(0.65, k * fit);
        if (Math.Abs(k - 1) > 0.01)
        {
            w.Content = null;
            w.Content = new LayoutTransformControl { Child = content, LayoutTransform = new ScaleTransform(k, k) };
            w.MinWidth *= k; w.MinHeight *= k;
        }
        w.Width = Math.Min(width * k, availW);
        w.Height = Math.Min(height * k, availH);
        // centred again at its new size, and fully on the screen
        var size = new PixelSize((int)(w.Width * scr.Scaling), (int)(w.Height * scr.Scaling));
        var wa = scr.WorkingArea;
        if (w.WindowStartupLocation != WindowStartupLocation.Manual)
        {
            var around = w.Owner is Window o && w.WindowStartupLocation == WindowStartupLocation.CenterOwner
                ? new PixelRect(o.Position, new PixelSize((int)(o.Bounds.Width * scr.Scaling), (int)(o.Bounds.Height * scr.Scaling)))
                : wa;
            w.Position = new PixelPoint(around.X + ((around.Width - size.Width) / 2), around.Y + ((around.Height - size.Height) / 2));
        }
        int x = Math.Clamp(w.Position.X, wa.X, Math.Max(wa.X, wa.Right - size.Width));
        int y = Math.Clamp(w.Position.Y, wa.Y, Math.Max(wa.Y, wa.Bottom - size.Height));
        if (x != w.Position.X || y != w.Position.Y) w.Position = new PixelPoint(x, y);
    }
}
