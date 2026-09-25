// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

namespace OkiRomSim.Desktop;

/// MSM66207 pinout (64-pin shrink DIP or 64-pin QFP, from the datasheet), coloured live from the simulator. Hover a pin to see what it is doing; click an input to change it.
public sealed class ChipView : UserControl
{
    public enum Package { Sdip64, Qfp64 }

    /// One package pin. Port 0-4 = P0..P4 bit; port 5 = analog input AIn (P5.n); port -1 = power / control pin.
    sealed record Pin(int Number, string Name, int Port, int Bit);

    static readonly Dictionary<string, (int Port, int Bit)> PortOf = BuildPortOf();
    static Dictionary<string, (int, int)> BuildPortOf()
    {
        var d = new Dictionary<string, (int, int)>();
        for (int p = 0; p < 5; p++) for (int b = 0; b < 8; b++) d[$"P{p}.{b}"] = (p, b);
        for (int b = 0; b < 8; b++) d[$"P5.{b}"] = (5, b);
        return d;
    }

    static OkiRomSim.Core.ProcessorProfile Profile => OkiRomSim.Core.ProcessorProfile.Current;
    static string Func(int port, int bit) => Profile.PinFunction(port, bit);
    static bool HasFunc(int port, int bit, out string f) { f = Func(port, bit); return f.Length > 0; }

    /// Pins the engine model drives as pulse trains; set through the engine inputs instead.
    static readonly Dictionary<(int, int), string> EngineDriven = new()
    {
        [(3, 2)] = "speed", [(3, 3)] = "rpm", [(3, 6)] = "rpm", [(4, 4)] = "rpm",
    };

    readonly SimHost _host;
    readonly Canvas _canvas = new();
    readonly Viewbox _view = new() { Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly };
    // one tooltip control per host: a single TextBlock cannot be the tip of both the pin and its label, because Avalonia reparents it into whichever tooltip opens ("already has a visual parent")
    readonly List<(Pin Pin, Border Box, TextBlock[] Tips)> _pins = [];
    SimHost.Snapshot? _last;
    (double[] Direct, double[] MuxA, double[] MuxB, int MuxSelect) _analog;

    /// Raised when the user asks to change an input; the text is shown in the status bar.
    public event Action<string>? Message;

    public ChipView(SimHost host)
    {
        _host = host;
        _view.Child = _canvas;
        Content = _view;
        Build();
    }

    /// Redraw after the processor profile changed.
    public void Rebuild() { Build(); if (_last != null) Update(_last); }

    public Package CurrentPackage
    {
        get;
        set { if (field != value) { field = value; Build(); if (_last != null) Update(_last); } }
    } = Package.Sdip64;

    // ------------------------------------------------------------------ layout

    const double Pitch = 18, PinW = 14, PinH = 10, LabelW = 128;

    void Build()
    {
        _canvas.Children.Clear();
        _pins.Clear();
        var p = Profile;
        var names = (CurrentPackage == Package.Sdip64 ? p.SdipPins : p.QfpPins).ToArray();
        if (names.Length != 64) names = [.. CurrentPackage == Package.Sdip64 ? OkiRomSim.Core.ProcessorProfile.Msm66207().SdipPins : OkiRomSim.Core.ProcessorProfile.Msm66207().QfpPins];
        var pins = names.Select((n, i) => MakePin(i + 1, n)).ToList();
        if (CurrentPackage == Package.Sdip64) BuildDip(pins); else BuildQfp(pins);
    }

    static Pin MakePin(int number, string name)
    {
        var key = name.Split('/')[0];
        return PortOf.TryGetValue(key, out var pb) ? new Pin(number, name, pb.Port, pb.Bit) : new Pin(number, name, -1, -1);
    }

    void BuildDip(List<Pin> pins)
    {
        double bodyW = 84, top = 20, bodyH = (32 * Pitch) + 10;
        double bodyX = LabelW + PinW;
        _canvas.Width = (bodyX * 2) + bodyW; _canvas.Height = bodyH + (top * 2);
        AddBody(bodyX, top, bodyW, bodyH, $"{Profile.Name}\nSDIP-64", notchTop: true);
        for (int i = 0; i < 32; i++)
        {
            double y = top + 8 + (i * Pitch);
            AddPin(pins[i], bodyX - PinW, y, Side.Left);                  // 1..32 down the left
            AddPin(pins[63 - i], bodyX + bodyW, y, Side.Right);           // 64..33 down the right
        }
    }

    void BuildQfp(List<Pin> pins)
    {
        double body = (16 * Pitch) + 16, margin = LabelW + PinW;
        _canvas.Width = body + (margin * 2); _canvas.Height = body + (margin * 2);
        AddBody(margin, margin, body, body, $"{Profile.Name}\nQFP-64", notchTop: false);
        for (int i = 0; i < 16; i++)
        {
            double off = 8 + (i * Pitch);
            AddPin(pins[i], margin - PinW, margin + off, Side.Left);                       // 1..16 left, top-down
            AddPin(pins[16 + i], margin + off, margin + body, Side.Bottom);                // 17..32 bottom, left-right
            AddPin(pins[32 + i], margin + body, margin + body - off - PinH, Side.Right);   // 33..48 right, bottom-up
            AddPin(pins[48 + i], margin + body - off - PinH, margin - PinW, Side.Top);     // 49..64 top, right-left
        }
    }

    enum Side { Left, Right, Top, Bottom }

    void AddBody(double x, double y, double w, double h, string title, bool notchTop)
    {
        var body = new Border
        {
            Width = w, Height = h, CornerRadius = new CornerRadius(4),
            Background = new SolidColorBrush(Color.FromRgb(38, 40, 46)),
            BorderBrush = new SolidColorBrush(Color.FromRgb(90, 94, 104)), BorderThickness = new Thickness(1.5),
            Child = new TextBlock
            {
                Text = title + $"\n{OkiRomSim.Core.Bus.CrystalMHz:0.##} MHz", TextAlignment = TextAlignment.Center, FontSize = 13,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.7,
            },
        };
        ToolTip.SetTip(body, $"{Profile.Name} on {Profile.Board}. {Profile.Description} Hover a pin for its live reading, click an input pin to change it.");
        Canvas.SetLeft(body, x); Canvas.SetTop(body, y);
        _canvas.Children.Add(body);
        if (notchTop)
        {
            var notch = new Avalonia.Controls.Shapes.Ellipse { Width = 16, Height = 16, Fill = new SolidColorBrush(Color.FromRgb(24, 25, 28)) };
            Canvas.SetLeft(notch, x + (w / 2) - 8); Canvas.SetTop(notch, y - 8);
            _canvas.Children.Add(notch);
        }
    }

    void AddPin(Pin pin, double x, double y, Side side)
    {
        bool vertical = side is Side.Top or Side.Bottom;
        var box = new Border
        {
            Width = vertical ? PinH : PinW, Height = vertical ? PinW : PinH,
            Background = Brushes.Gray, BorderThickness = new Thickness(1), BorderBrush = Brushes.Transparent,
            Cursor = new Cursor(StandardCursorType.Hand),
        };
        static TextBlock NewTip() => new() { FontFamily = MainWindow.MonoFont, FontSize = 12, MaxWidth = 460, TextWrapping = TextWrapping.Wrap };
        var tip = NewTip();
        var labelTip = NewTip();
        ToolTip.SetTip(box, tip);
        ToolTip.SetShowDelay(box, 150);
        box.PointerPressed += (_, e) => { OnPinClicked(pin, box); e.Handled = true; };
        Canvas.SetLeft(box, x); Canvas.SetTop(box, y);
        _canvas.Children.Add(box);

        string func = pin.Port >= 0 && HasFunc(pin.Port, pin.Bit, out var f) ? f : "";
        var label = new TextBlock
        {
            Text = $"{pin.Number,2} {pin.Name}" + (func.Length > 0 ? "  " + Short(func) : ""),
            FontSize = 10.5, FontFamily = MainWindow.MonoFont, Width = LabelW - 4,
            TextTrimming = TextTrimming.CharacterEllipsis, Opacity = pin.Port >= 0 ? 0.95 : 0.55,
            TextAlignment = side is Side.Left or Side.Bottom ? TextAlignment.Right : TextAlignment.Left,
        };
        ToolTip.SetTip(label, labelTip);
        label.PointerPressed += (_, e) => { OnPinClicked(pin, box); e.Handled = true; };
        switch (side)
        {
            case Side.Left: Canvas.SetLeft(label, x - LabelW); Canvas.SetTop(label, y - 3); break;
            case Side.Right: Canvas.SetLeft(label, x + PinW + 4); Canvas.SetTop(label, y - 3); break;
            case Side.Bottom:
                label.RenderTransform = new RotateTransform(-90); label.RenderTransformOrigin = new RelativePoint(0, 0, RelativeUnit.Relative);
                Canvas.SetLeft(label, x - 2); Canvas.SetTop(label, y + PinW + LabelW); break;
            case Side.Top:
                label.RenderTransform = new RotateTransform(-90); label.RenderTransformOrigin = new RelativePoint(0, 0, RelativeUnit.Relative);
                Canvas.SetLeft(label, x - 2); Canvas.SetTop(label, y - 4); break;
        }
        _canvas.Children.Add(label);
        _pins.Add((pin, box, new[] { tip, labelTip }));
    }

    static string Short(string func)
    {
        int p = func.IndexOf('(');
        return (p > 0 ? func[..p] : func).Trim();
    }

    // ------------------------------------------------------------------ live state

    static readonly IBrush OutHigh = new SolidColorBrush(Color.FromRgb(76, 200, 90));
    static readonly IBrush OutLow = new SolidColorBrush(Color.FromRgb(30, 90, 40));
    static readonly IBrush InHigh = new SolidColorBrush(Color.FromRgb(70, 150, 240));
    static readonly IBrush InLow = new SolidColorBrush(Color.FromRgb(20, 60, 130));
    static readonly IBrush Secondary = new SolidColorBrush(Color.FromRgb(160, 100, 220));
    static readonly IBrush Power = new SolidColorBrush(Color.FromRgb(110, 110, 110));
    static readonly IBrush ForcedBorder = new SolidColorBrush(Color.FromRgb(255, 80, 80));

    /// Both tooltips of a pin say the same thing; they are separate controls so either can open.
    static void SetTip(TextBlock[] tips, string text)
    {
        foreach (var t in tips) t.Text = text;
    }

    public void Update(SimHost.Snapshot s)
    {
        _last = s;
        _analog = _host.Analog();
        foreach (var (pin, box, tips) in _pins)
        {
            if (pin.Port < 0)
            {
                box.Background = Power;
                SetTip(tips, $"pin {pin.Number}  {pin.Name}\n{Profile.OtherPins.GetValueOrDefault(pin.Name.Split('/')[0], "")}" +
                           (pin.Name.StartsWith("OSC") ? $"\ncrystal {OkiRomSim.Core.Bus.CrystalMHz:0.##} MHz" : ""));
                continue;
            }
            if (pin.Port == 5)
            {
                double v = _analog.Direct[pin.Bit];
                byte shade = (byte)Math.Clamp(60 + (v / 5.0 * 195), 0, 255);
                box.Background = new SolidColorBrush(Color.FromRgb(shade, (byte)(shade * 0.6), 30));
                bool forced = _host.AnalogOverride(pin.Bit) != null ||
                              (pin.Bit < 2 && Enumerable.Range(0, 8).Any(n => _host.AnalogOverride((pin.Bit == 0 ? 100 : 200) + n) != null));
                box.BorderBrush = forced ? ForcedBorder : Brushes.Transparent;
                SetTip(tips, AnalogTip(pin));
                continue;
            }
            var row = s.Outputs.Pins[(pin.Port * 8) + pin.Bit];
            bool isForced = _host.ForcedLevel(pin.Port, pin.Bit) != null;
            box.BorderBrush = isForced ? ForcedBorder : Brushes.Transparent;
            box.Background = row.Dir switch
            {
                "out" => row.Level == 1 ? OutHigh : OutLow,
                "sf" => Secondary,
                _ => row.Level == 1 ? InHigh : InLow,
            };
            SetTip(tips, DigitalTip(pin, row, isForced, s));
        }
    }

    string DigitalTip(Pin pin, SimHost.PinRow row, bool forced, SimHost.Snapshot s)
    {
        string func = HasFunc(pin.Port, pin.Bit, out var bf) ? bf : "no known board function";
        string dir = row.Dir switch { "out" => "output", "sf" => "secondary function (on-chip peripheral)", _ => "input" };
        var t = $"pin {pin.Number}  {pin.Name}\n{func}\n\nlevel {row.Level} ({(row.Level == 1 ? "high" : "low")}), {dir}";
        if (forced) t += "  -- forced by hand";
        if (row.ChangesPerSec > 0) t += $"\n{row.ChangesPerSec:F1} changes/s";
        if (row.HighMs > 0 || row.LowMs > 0) t += $"\nlast high {Ms(row.HighMs)}, last low {Ms(row.LowMs)}";
        if (row.DrivenBy.Length > 0) t += $"\nlast written by {row.DrivenBy}";
        if (EngineDriven.TryGetValue((pin.Port, pin.Bit), out var src))
            t += src == "rpm" ? $"\n\nsignal from the engine model at {s.Rpm:F0} rpm (RPM slider)"
                              : $"\n\nsignal from the engine model at {s.SpeedKmh:F0} km/h (speed slider)";
        else if (row.Dir == "in") t += "\n\nclick: force high -> force low -> back to the board model";
        else if (row.Dir == "out") t += "\n\ndriven by the ROM";
        return t;
    }

    string AnalogTip(Pin pin)
    {
        string func = HasFunc(5, pin.Bit, out var af) ? af : "unused analog input";
        double v = _analog.Direct[pin.Bit];
        var t = $"pin {pin.Number}  {pin.Name}\n{func}\n\n{v:F3} V  = {(int)Math.Round(v / 5 * 1023)} counts (10-bit)";
        if (pin.Bit < 2)
        {
            var bank = pin.Bit == 0 ? _analog.MuxA : _analog.MuxB;
            t += $"\nmux select now {_analog.MuxSelect} (P2.5-P2.7)\n";
            for (int n = 0; n < 8; n++)
                t += $"\n  channel {n}: {bank[n],6:F3} V  {MuxName(pin.Bit, n)}" +
                     (_host.AnalogOverride((pin.Bit == 0 ? 100 : 200) + n) != null ? "  (set by hand)" : "");
        }
        else if (_host.AnalogOverride(pin.Bit) != null) t += "\nset by hand";
        return t + "\n\nclick to set the voltage by hand";
    }

    static string MuxName(int bank, int n) => (bank, n) switch
    {
        (0, 0) => "ECT", (0, 3) => "baro", (0, 7) => "IAT", (1, 0) => "O2", _ => "",
    };

    static string Ms(double ms) => ms <= 0 ? "-" : ms < 1000 ? $"{ms:F2} ms" : $"{ms / 1000:F2} s";

    // ------------------------------------------------------------------ clicking

    void OnPinClicked(Pin pin, Control anchor)
    {
        if (pin.Port < 0) return;
        if (pin.Port == 5) { ShowAnalogEditor(pin, anchor); return; }
        if (EngineDriven.TryGetValue((pin.Port, pin.Bit), out var src))
        {
            Message?.Invoke($"{pin.Name} carries the {(src == "rpm" ? "crank/cam" : "vehicle speed")} pulse train from the engine model; change it with the {(src == "rpm" ? "RPM" : "speed")} slider.");
            return;
        }
        var row = _last?.Outputs.Pins[(pin.Port * 8) + pin.Bit];
        if (row != null && row.Dir == "out")
        {
            Message?.Invoke($"{pin.Name} is an output driven by the ROM; it cannot be set from outside.");
            return;
        }
        var cur = _host.ForcedLevel(pin.Port, pin.Bit);
        bool? next = cur switch { null => true, true => false, false => null };
        _host.ForcePin(pin.Port, pin.Bit, next);
        Message?.Invoke(next switch
        {
            true => $"{pin.Name} forced high",
            false => $"{pin.Name} forced low",
            null => $"{pin.Name} back to the board model",
        });
        if (_last != null) Update(_last);
    }

    void ShowAnalogEditor(Pin pin, Control anchor)
    {
        var panel = new StackPanel { Spacing = 4, Width = 360 };
        panel.Children.Add(new TextBlock { Text = $"{pin.Name}  {Func(5, pin.Bit)}", FontWeight = FontWeight.Bold });
        if (pin.Bit < 2)
        {
            var bank = pin.Bit == 0 ? _analog.MuxA : _analog.MuxB;
            for (int n = 0; n < 8; n++)
                panel.Children.Add(VoltRow($"ch {n} {MuxName(pin.Bit, n)}", (pin.Bit == 0 ? 100 : 200) + n, bank[n]));
        }
        else panel.Children.Add(VoltRow(pin.Name.Split('/')[0], pin.Bit, _analog.Direct[pin.Bit]));
        panel.Children.Add(new TextBlock
        {
            Text = "Drag to set a voltage by hand; untick to hand the input back to the engine model.",
            FontSize = 11, Opacity = 0.7, TextWrapping = TextWrapping.Wrap,
        });
        new Flyout { Content = panel, Placement = PlacementMode.Right }.ShowAt(anchor);
    }

    Control VoltRow(string name, int key, double current)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("90,*,56,Auto") };
        var label = new TextBlock { Text = name, VerticalAlignment = VerticalAlignment.Center, FontSize = 12 };
        double start = _host.AnalogOverride(key) ?? current;
        var slider = new Slider { Minimum = 0, Maximum = 5, Value = start, SmallChange = 0.01, LargeChange = 0.25 };
        var read = new TextBlock { Text = start.ToString("F2", CultureInfo.InvariantCulture) + " V", VerticalAlignment = VerticalAlignment.Center, FontSize = 12 };
        var hand = new CheckBox { IsChecked = _host.AnalogOverride(key) != null, Content = "by hand" };
        ToolTip.SetTip(slider, "voltage on the pin, 0-5 V");
        ToolTip.SetTip(hand, "ticked: the voltage is held where you put it; unticked: the engine model drives it");
        slider.PropertyChanged += (_, e) =>
        {
            if (e.Property != RangeBase.ValueProperty) return;
            read.Text = slider.Value.ToString("F2", CultureInfo.InvariantCulture) + " V";
            hand.IsChecked = true;
            _host.SetAnalog(key, slider.Value);
        };
        hand.IsCheckedChanged += (_, _) => _host.SetAnalog(key, hand.IsChecked == true ? slider.Value : null);
        Grid.SetColumn(label, 0); grid.Children.Add(label);
        Grid.SetColumn(slider, 1); grid.Children.Add(slider);
        Grid.SetColumn(read, 2); grid.Children.Add(read);
        Grid.SetColumn(hand, 3); grid.Children.Add(hand);
        return grid;
    }
}
