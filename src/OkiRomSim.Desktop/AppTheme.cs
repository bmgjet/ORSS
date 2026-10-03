// Copyright (c) bmgjet. All rights reserved.
using System.Runtime.CompilerServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Shapes;
using Avalonia.Data;
using Avalonia.Media;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;
using Avalonia.VisualTree;

namespace OkiRomSim.Desktop;

/// The app's colours: Dark (the default), Light, or High contrast for a laptop out in the sun (Settings > Colours; Ctrl+Shift+H goes round them). The app is drawn in dark colours; the other two are worked out from them, every colour on its own: Light turns the backgrounds near white and the text near black and keeps each colour's hue, dark enough to read on white; High contrast makes the backgrounds pure black, the text and lines pure white, the colours that mean something (on / off, warnings, the graphs' traces) fully saturated and bright, and brings faded text up nearly to full. It works on every window at once, live: the app's brushes are all made through Brush() and remember their own colour, the theme's controls take Fluent's light variant or a high contrast palette, and anything set from a fixed brush is swapped for one of ours as it is set.
public static class AppTheme
{
    public enum Mode { Dark, Light, Contrast }

    public static Mode Now { get; private set; } = Mode.Dark;
    public static event Action? Changed;

    /// The settings' names for the modes.
    public static Mode Parse(string? s) => s?.Trim().ToLowerInvariant() switch
    {
        "light" => Mode.Light,
        "contrast" or "highcontrast" or "high contrast" => Mode.Contrast,
        _ => Mode.Dark,
    };

    public static string Name(Mode m) => m switch { Mode.Light => "light", Mode.Contrast => "contrast", _ => "dark" };
    public static string Label(Mode m) => m switch { Mode.Light => "Light", Mode.Contrast => "High contrast", _ => "Dark" };

    static FluentTheme? _fluent;
    static ColorPaletteResources? _contrastPalette;

    /// A colour as the dark theme has it; a tile's (a table cell, its text and marks: a palette of its own that reads on any background) stays as it is in Light, and only changes for High contrast.
    sealed class Orig(Color c, bool tile = false) { public Color Color = c; public readonly bool Tile = tile; }
    sealed class OrigOpacity(double o) { public double Opacity = o; }
    static readonly ConditionalWeakTable<SolidColorBrush, Orig> _brushes = new();
    static readonly List<WeakReference<SolidColorBrush>> _brushList = [];
    static readonly ConditionalWeakTable<GradientStop, Orig> _stops = new();
    static readonly List<WeakReference<GradientStop>> _stopList = [];
    static readonly ConditionalWeakTable<TextBlock, OrigOpacity> _opacities = new();
    static readonly List<WeakReference<TextBlock>> _textList = [];
    static bool _busy, _hooked;

    /// A brush of the app's, in its dark colour: shown in the theme picked, and changed with it.
    public static SolidColorBrush Brush(Color c, double opacity = 1, bool tile = false)
    {
        var b = new SolidColorBrush(Map(c, tile), opacity);
        Register(b, c, tile);
        return b;
    }

    /// A gradient of the app's: its stops follow the theme like Brush's colours.
    public static T Track<T>(T g, bool tile = false) where T : GradientBrush
    {
        foreach (var stop in g.GradientStops)
        {
            if (_stops.TryGetValue(stop, out _)) continue;
            _stops.Add(stop, new Orig(stop.Color, tile)); Prune(_stopList); _stopList.Add(new WeakReference<GradientStop>(stop));
            stop.Color = Map(stop.Color, tile);
        }
        return g;
    }

    public static SolidColorBrush Brush(uint argb) => Brush(Color.FromUInt32(argb));

    /// White and black for drawing (outlines on the graphs and tables), following the theme.
    public static readonly SolidColorBrush White = Brush(Colors.White), Black = Brush(Colors.Black);

    static void Register(SolidColorBrush b, Color orig, bool tile = false)
    {
        if (_brushes.TryGetValue(b, out _)) return;
        _brushes.Add(b, new Orig(orig, tile));
        Prune(_brushList);
        _brushList.Add(new WeakReference<SolidColorBrush>(b));
    }

    static void Prune<T>(List<WeakReference<T>> list) where T : class
    {
        // every 4096 additions, drop the ones collected (brushes made each frame by a graph come and go)
        if (list.Count > 0 && list.Count % 4096 == 0) list.RemoveAll(w => !w.TryGetTarget(out _));
    }

    /// The colour shown for one of the app's (dark theme) colours in the theme picked.
    public static Color Map(Color c, bool tile = false) => Now switch { Mode.Light => tile ? c : Light(c), Mode.Contrast => Contrast(c), _ => c };

    static Color Contrast(Color c)
    {
        if (c.A == 0) return c;
        var h = c.ToHsl();
        double l = h.L, s = h.S;
        if (s < 0.18 || l < 0.04 || l > 0.97)
        {
            // greys: the backgrounds and panels black, the dividers and boxes a clear mid grey, the text white
            l = l < 0.2 ? 0 : l < 0.45 ? 0.35 : 1;
            return Grey(c.A, l);
        }
        // colours that mean something: fully saturated; the dark ones (an output that is off, a selection behind text) stay dark, the rest bright
        var o = HslColor.ToRgb(h.H, 1, l < 0.4 ? 0.24 : 0.6, 1);
        return Color.FromArgb(c.A, o.R, o.G, o.B);
    }

    // a dark theme grey's lightness -> the light theme's: the backgrounds near white, the panels a shade under, the lines a clear grey, the text near black and the faded text a mid grey
    static readonly (double In, double Out)[] LightGreys = [(0, 1), (0.12, 0.97), (0.16, 0.94), (0.25, 0.80), (0.45, 0.55), (0.65, 0.35), (0.86, 0.12), (1, 0)];

    static Color Light(Color c)
    {
        if (c.A == 0) return c;
        var h = c.ToHsl();
        double l = h.L, s = h.S;
        if (s < 0.18 || l < 0.04 || l > 0.97)
        {
            int i = 1;
            while (i < LightGreys.Length - 1 && l > LightGreys[i].In) i++;
            var (a, b) = (LightGreys[i - 1], LightGreys[i]);
            double t = b.In > a.In ? (l - a.In) / (b.In - a.In) : 0;
            return Grey(c.A, a.Out + ((b.Out - a.Out) * Math.Clamp(t, 0, 1)));
        }
        // a dark colour (behind text: a selection, an output that is off) becomes a light tint of itself; a bright one (text, a trace, a lamp) becomes deep enough to read on white
        double nl = l < 0.35 ? 0.95 - (l * 0.4) : Math.Clamp(1.05 - l, 0.25, 0.42);
        var o = HslColor.ToRgb(h.H, Math.Max(s, 0.55), nl, 1);
        return Color.FromArgb(c.A, o.R, o.G, o.B);
    }

    static Color Grey(byte a, double l) { byte v = (byte)Math.Round(Math.Clamp(l, 0, 1) * 255); return Color.FromArgb(a, v, v, v); }

    /// Faded text is nearly full in high contrast (hidden text stays hidden).
    static double MapOpacity(double o) => Now != Mode.Contrast || o < 0.05 || o >= 0.999 ? o : 0.75 + (0.25 * o);

    /// Change the theme: every window, live.
    public static void Set(Mode mode)
    {
        Hook();
        if (mode == Now) return;
        Now = mode;
        if (_fluent != null && _contrastPalette != null)
        {
            if (mode == Mode.Contrast) _fluent.Palettes[ThemeVariant.Dark] = _contrastPalette;
            else _fluent.Palettes.Remove(ThemeVariant.Dark);
        }
        if (Application.Current is { } app) app.RequestedThemeVariant = mode == Mode.Light ? ThemeVariant.Light : ThemeVariant.Dark;
        _busy = true;
        try
        {
            foreach (var w in _brushList) if (w.TryGetTarget(out var b) && _brushes.TryGetValue(b, out var o)) b.Color = Map(o.Color, o.Tile);
            foreach (var w in _stopList) if (w.TryGetTarget(out var g) && _stops.TryGetValue(g, out var o)) g.Color = Map(o.Color, o.Tile);
            foreach (var w in _textList) if (w.TryGetTarget(out var t) && _opacities.TryGetValue(t, out var o)) t.Opacity = MapOpacity(o.Opacity);
        }
        finally { _busy = false; }
        // the graphs and tables draw themselves: ask every window to draw again with the new colours
        if (Application.Current?.ApplicationLifetime is Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime d)
            foreach (var win in d.Windows)
                foreach (var v in win.GetVisualDescendants().OfType<Visual>().Prepend(win)) v.InvalidateVisual();
        Changed?.Invoke();
    }

    /// The next theme round (Ctrl+Shift+H): Dark, Light, High contrast.
    public static Mode Next(Mode m) => m switch { Mode.Dark => Mode.Light, Mode.Light => Mode.Contrast, _ => Mode.Dark };

    /// The theme's high contrast palette, and the hooks that catch colours set from fixed brushes (Brushes.Gray...) or as gradients.
    public static void Install(FluentTheme fluent)
    {
        _fluent = fluent;
        _contrastPalette = new ColorPaletteResources
        {
            Accent = Color.FromRgb(0x1a, 0xa3, 0xff), RegionColor = Colors.Black, ErrorText = Color.FromRgb(0xff, 0x50, 0x50),
            AltHigh = Colors.Black, AltLow = Colors.Black, AltMedium = Colors.Black, AltMediumHigh = Colors.Black, AltMediumLow = Colors.Black,
            BaseHigh = Colors.White, BaseMediumHigh = Color.FromRgb(0xf2, 0xf2, 0xf2), BaseMedium = Color.FromRgb(0xe6, 0xe6, 0xe6),
            BaseMediumLow = Color.FromRgb(0xbf, 0xbf, 0xbf), BaseLow = Color.FromRgb(0x5a, 0x5a, 0x5a),
            ChromeAltLow = Colors.White, ChromeBlackHigh = Colors.Black, ChromeBlackLow = Colors.Black, ChromeBlackMedium = Colors.Black, ChromeBlackMediumLow = Colors.Black,
            ChromeDisabledHigh = Color.FromRgb(0x6e, 0x6e, 0x6e), ChromeDisabledLow = Color.FromRgb(0xa0, 0xa0, 0xa0), ChromeGray = Color.FromRgb(0xbf, 0xbf, 0xbf),
            ChromeHigh = Color.FromRgb(0x8c, 0x8c, 0x8c), ChromeLow = Color.FromRgb(0x14, 0x14, 0x14), ChromeMedium = Color.FromRgb(0x1e, 0x1e, 0x1e),
            ChromeMediumLow = Color.FromRgb(0x2a, 0x2a, 0x2a), ChromeWhite = Colors.White, ListLow = Color.FromRgb(0x33, 0x33, 0x33), ListMedium = Color.FromRgb(0x4d, 0x4d, 0x4d),
        };
        Hook();
    }

    static void Hook()
    {
        if (_hooked) return;
        _hooked = true;
        // only what the app's code set (local values); what the theme's styles set comes from Fluent
        foreach (var p in new AvaloniaProperty[]
                 {
                     TemplatedControl.BackgroundProperty, TemplatedControl.BorderBrushProperty, TemplatedControl.ForegroundProperty,
                     Border.BackgroundProperty, Border.BorderBrushProperty, Panel.BackgroundProperty, TextBlock.BackgroundProperty,
                     TextBlock.ForegroundProperty, Shape.FillProperty, Shape.StrokeProperty,
                 })
            p.Changed.Subscribe(new Watcher(e =>
            {
                if (_busy || e.Priority != BindingPriority.LocalValue || e.NewValue is not IBrush brush) return;
                Adopt(e.Sender, e.Property, brush);
            }));
        Visual.OpacityProperty.Changed.Subscribe(new Watcher(e =>
        {
            if (_busy || e.Sender is not TextBlock tb || e.Priority != BindingPriority.LocalValue || e.NewValue is not double o) return;
            if (_opacities.TryGetValue(tb, out var r)) r.Opacity = o;
            else { _opacities.Add(tb, new OrigOpacity(o)); Prune(_textList); _textList.Add(new WeakReference<TextBlock>(tb)); }
            if (Now == Mode.Contrast) { _busy = true; try { tb.Opacity = MapOpacity(o); } finally { _busy = false; } }
        }));
    }

    /// A brush set from code: ours already, or made one of ours.
    static void Adopt(AvaloniaObject target, AvaloniaProperty property, IBrush brush)
    {
        switch (brush)
        {
            case SolidColorBrush s when _brushes.TryGetValue(s, out _):
                return;
            case SolidColorBrush s:
                // a brush of the app's made without Brush(): it remembers its colour from now on
                Register(s, s.Color);
                if (Now != Mode.Dark) { _busy = true; try { s.Color = Map(s.Color); } finally { _busy = false; } }
                return;
            case ISolidColorBrush fixedBrush:
                // a fixed brush (Brushes.Gray...): swapped for one of ours of the same colour
                var mine = Brush(fixedBrush.Color, fixedBrush.Opacity);
                _busy = true;
                try { target.SetValue(property, mine); } finally { _busy = false; }
                return;
            case GradientBrush g:
                foreach (var stop in g.GradientStops)
                {
                    if (!_stops.TryGetValue(stop, out _)) { _stops.Add(stop, new Orig(stop.Color)); Prune(_stopList); _stopList.Add(new WeakReference<GradientStop>(stop)); }
                    if (Now != Mode.Dark) { _busy = true; try { stop.Color = Map(stop.Color); } finally { _busy = false; } }
                }
                return;
        }
    }

    sealed class Watcher(Action<AvaloniaPropertyChangedEventArgs> on) : IObserver<AvaloniaPropertyChangedEventArgs>
    {
        public void OnNext(AvaloniaPropertyChangedEventArgs e) => on(e);
        public void OnError(Exception error) { }
        public void OnCompleted() { }
    }
}
