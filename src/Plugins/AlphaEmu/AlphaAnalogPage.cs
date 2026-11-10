// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Desktop;

namespace AlphaEmuPlugin;

/// The eight ALPHAemu analog inputs: what each one is wired for, what it is reading right now (raw
/// counts, the voltage at the ADC, the voltage at the sensor - with the ALPHAlink jitter filter in the
/// way), what that means as an engineering value, and where it goes: into the datalog as a named
/// channel, and optionally straight into the app's own engine model so the simulated ECU sees it.
public sealed class AlphaAnalogPage : IAlphaPage
{
    readonly AlphaHub _hub;
    readonly StackPanel _rowsPanel = new() { Spacing = 4 };
    readonly TextBlock _note = new() { FontSize = 11, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap };
    readonly TextBlock _wideband = new() { FontSize = 12, FontFamily = Alpha.Mono, Foreground = Alpha.Ink };
    readonly TextBox _poll = new() { Width = 64, FontSize = 12 };
    readonly CheckBox _toSim;
    readonly List<(LedLamp Lamp, TextBlock Name, ComboBox Role, TextBlock Raw, TextBlock Adc, TextBlock Source, TextBlock Value, ToggleSwitch Switch)> _rows = [];

    public string Title => "Analog inputs";
    public string Icon => "⊞";
    public Control Content { get; }

    public AlphaAnalogPage(AlphaHub hub)
    {
        _hub = hub;
        for (int i = 0; i < 8; i++)
        {
            int index = i;
            var input = hub.State.Analog[i];
            var lamp = new LedLamp { Label = "", Colour = Alpha.Green, Dot = 7 };
            var name = new TextBlock { Text = input.Name, FontSize = 12, Width = 160, Foreground = Alpha.Ink, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
            var sw = new ToggleSwitch { On = input.Enabled, LabelText = "" };
            sw.Changed += on => { input.Enabled = on; _hub.SaveSoon(); Refresh(); };
            var role = new ComboBox { Width = 168, FontSize = 12, ItemsSource = AlphaAnalogInput.Roles.Select(r => r.Label).ToList(), SelectedIndex = (int)Array.FindIndex(AlphaAnalogInput.Roles, r => r.Role == input.Role) };
            role.SelectionChanged += (_, _) =>
            {
                if (role.SelectedIndex < 0) return;
                input.Role = AlphaAnalogInput.Roles[role.SelectedIndex].Role;
                _hub.SaveSoon();
                Refresh();
            };
            var raw = Mono("----", 60);
            var adc = Mono("----", 62);
            var src = Mono("----", 62);
            var value = Mono("----", 96);
            value.FontWeight = FontWeight.SemiBold;
            ToolTip.SetTip(value, AlphaAnalogInput.TipOf(input.Role));
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,Auto,Auto,Auto,Auto,Auto,Auto,*") };
            int col = 0;
            foreach (Control c in new Control[] { lamp, name, sw, role, raw, adc, src, value }) { Grid.SetColumn(c, col++); g.Children.Add(c); }
            var row = new Border
            {
                Background = Alpha.Tint(Alpha.Rgb(0x1f, 0x22, 0x27), 190), BorderBrush = Alpha.Line, BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 5), Child = g,
            };
            _rowsPanel.Children.Add(row);
            _rows.Add((lamp, name, role, raw, adc, src, value, sw));
        }

        var head = new WrapPanel { Orientation = Orientation.Horizontal, ItemSpacing = 10, LineSpacing = 10 };
        _poll.Text = hub.State.AnalogPollMs.ToString(CultureInfo.InvariantCulture);
        _poll.LostFocus += (_, _) => { if (int.TryParse(_poll.Text, out var ms)) { hub.State.AnalogPollMs = Math.Clamp(ms, 10, 5000); _poll.Text = hub.State.AnalogPollMs.ToString(CultureInfo.InvariantCulture); _hub.SaveSoon(); } };
        head.Children.Add(new TextBlock { Text = "Poll every", VerticalAlignment = VerticalAlignment.Center, FontSize = 12 });
        head.Children.Add(_poll);
        head.Children.Add(new TextBlock { Text = "ms", VerticalAlignment = VerticalAlignment.Center, FontSize = 12, Foreground = Alpha.Dim });
        _toSim = Alpha.Check("Drive the simulator's inputs with them", hub.State.AnalogToSimulator,
            on => { hub.State.AnalogToSimulator = on; _hub.SaveSoon(); },
            "An enabled input whose role matches one of the app's engine inputs (ECT, IAT, MAP, TPS, battery, O2) is also written into the simulator, so the ROM under test reacts to what you feed the ALPHAemu pins.");
        head.Children.Add(_toSim);
        head.Children.Add(Alpha.Ghost("Wideband sensor…", () => _hub.OpenWideband(), "Choose the wideband profile, stoich and offset, or draw a custom curve."));

        Content = new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Alpha.Card("Analog inputs", new StackPanel { Spacing = 6, Children = { head, _rowsPanel, _note } },
                    Alpha.Note("Enabled inputs are polled while the emulator is linked.")),
                Alpha.Card("Wideband", new StackPanel { Spacing = 4, Children = { _wideband, Alpha.Note("The AFR the datalog and the gauge show comes from the input picked below and the profile in force.") } },
                    Alpha.Ghost("Edit profile", () => _hub.OpenWideband(), "Wideband profile, stoich, offset and custom curve.")),
            }
        };
        Refresh();
    }

    static TextBlock Mono(string text, double width) => new()
    {
        Text = text, FontFamily = Alpha.Mono, FontSize = 11.5, Width = width, Foreground = Alpha.Ink, TextAlignment = TextAlignment.Right,
    };

    public void Refresh()
    {
        var s = _hub.Session;
        for (int i = 0; i < _rows.Count && i < _hub.State.Analog.Count; i++)
        {
            var a = _hub.State.Analog[i];
            var (lamp, name, role, raw, adc, src, value, sw) = _rows[i];
            lamp.On = a.Enabled && a.Fresh;
            lamp.Colour = a.Fresh ? Alpha.Green : Alpha.DimColour;
            sw.On = a.Enabled;
            name.Foreground = a.Enabled ? Alpha.Ink : Alpha.Dim;
            if (role.SelectedIndex != (int)Array.FindIndex(AlphaAnalogInput.Roles, r => r.Role == a.Role)) role.SelectedIndex = (int)Array.FindIndex(AlphaAnalogInput.Roles, r => r.Role == a.Role);
            ToolTip.SetTip(value, AlphaAnalogInput.TipOf(a.Role));
            raw.Text = a.Raw.ToString(CultureInfo.InvariantCulture);
            adc.Text = (a.AdcVolts).ToString("0.000", CultureInfo.InvariantCulture) + " V";
            src.Text = (a.SourceVolts).ToString("0.000", CultureInfo.InvariantCulture) + " V";
            double? v = a.Value(a.SourceVolts, s.Wideband);
            string unit = AlphaAnalogInput.UnitOf(a.Role);
            value.Text = v is double d ? d.ToString("0.##", CultureInfo.InvariantCulture) + " " + unit : a.Enabled ? "no reading" : "off";
            value.Foreground = v is double dv && a.Enabled ? new SolidColorBrush(Scale(a.Role, dv)) : Alpha.Dim;
            // the channel it lands in on a line of its own: on one line the two ran under the switch
            name.Text = $"{a.Name}\n{a.Channel}";
            ToolTip.SetTip(name, $"{a.Name}: logged as {a.Channel}");
        }
        var afrWide = s.AnalogAfr();
        _wideband.Text = $"input {_hub.State.WidebandInput + 1} · {s.Wideband.Summary} · " +
                         (afrWide is double aWide ? $"now {aWide:0.00} AFR" : "no wideband reading") +
                         $" · poll {_hub.State.AnalogPollMs} ms · {(s.AnalogPolls > 0 ? s.AnalogPolls.ToString("N0", CultureInfo.InvariantCulture) + " polls" : "not polling")}";
        _note.Text = _hub.State.AnalogToSimulator
            ? "Enabled inputs are polled while the emulator is linked, land in the datalog as their own channels, and drive the simulator's matching engine input."
            : "Enabled inputs are polled while the emulator is linked and land in the datalog as their own channels. Turn on the box above to also drive the simulator.";
    }

    static Color Scale(AlphaAnalogRole role, double v) => role switch
    {
        AlphaAnalogRole.WidebandAfr => v is < 11.5 or > 16.5 ? Alpha.Red : Alpha.Green,
        AlphaAnalogRole.Ect or AlphaAnalogRole.Iat => v > 105 ? Alpha.Red : v > 90 ? Alpha.Amber : Alpha.Sky,
        AlphaAnalogRole.Tps => v > 95 ? Alpha.Amber : Alpha.Cyan,
        AlphaAnalogRole.Battery => v < 12.2 || v > 14.9 ? Alpha.Red : Alpha.Green,
        _ => Alpha.InkColour,
    };
}

/// The wideband sensor screen: one of the twelve factory volt-to-lambda tables, or a curve you type
/// in, with the stoich and offset the AFR is built from, and a live dot on the curve.
public sealed class AlphaWidebandPage : IAlphaPage
{
    readonly AlphaHub _hub;
    readonly ComboBox _profile = new() { Width = 200, FontSize = 12 };
    readonly ComboBox _input = new() { Width = 190, FontSize = 12 };
    readonly TextBox _stoich = new() { Width = 70, FontSize = 12 };
    readonly TextBox _offset = new() { Width = 70, FontSize = 12 };
    readonly WidebandCurve _curve;
    readonly StackPanel _customRows = new() { Spacing = 3 };
    readonly TextBlock _readout = new() { FontSize = 12, FontFamily = Alpha.Mono, Foreground = Alpha.Ink };
    readonly CheckBox _feed;

    public string Title => "Wideband";
    public string Icon => "≈";
    public Control Content { get; }

    public AlphaWidebandPage(AlphaHub hub)
    {
        _hub = hub;
        _curve = new WidebandCurve(hub.Session.Wideband) { Height = 170 };
        _profile.ItemsSource = AlphaWideband.Profiles.Select(p => p.Label).ToList();
        _profile.SelectedIndex = Math.Max(0, Array.FindIndex(AlphaWideband.Profiles, p => p.Key == hub.State.WidebandProfile));
        _profile.SelectionChanged += (_, _) =>
        {
            if (_profile.SelectedIndex < 0) return;
            hub.State.WidebandProfile = AlphaWideband.Profiles[_profile.SelectedIndex].Key;
            _hub.SaveSoon(); _hub.ApplyWideband(); Refresh();
        };
        _input.ItemsSource = Enumerable.Range(1, 8).Select(i => $"ALPHAemu Analog {i}").ToList();
        _input.SelectedIndex = Math.Clamp(hub.State.WidebandInput, 0, 7);
        _input.SelectionChanged += (_, _) => { if (_input.SelectedIndex >= 0) { hub.State.WidebandInput = _input.SelectedIndex; _hub.SaveSoon(); } };
        _stoich.Text = hub.State.WidebandStoich.ToString("0.00", CultureInfo.InvariantCulture);
        _offset.Text = hub.State.WidebandOffset.ToString("0.00", CultureInfo.InvariantCulture);
        foreach (var box in new[] { _stoich, _offset }) box.LostFocus += (_, _) => ReadNumbers();
        _feed = Alpha.Check("The wideband input is the AFR channel in the datalog", hub.State.FeedWideband,
            on => { hub.State.FeedWideband = on; _hub.SaveSoon(); },
            "Off leaves the app's own wideband reader (Settings) alone and only the raw volts are logged.");

        var numbers = new WrapPanel { Orientation = Orientation.Horizontal, ItemSpacing = 10, LineSpacing = 10 };
        foreach (var (label, box) in new (string, TextBox)[] { ("Stoich", _stoich), ("Offset", _offset) })
        {
            numbers.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, FontSize = 12 });
            numbers.Children.Add(box);
        }
        numbers.Children.Add(Alpha.Ghost("14.7 / 0", () => { _stoich.Text = "14.7"; _offset.Text = "0"; ReadNumbers(); }, "Petrol stoich and no offset."));
        numbers.Children.Add(Alpha.Ghost("E85 9.7", () => { _stoich.Text = "9.7"; _offset.Text = "0"; ReadNumbers(); }, "Ethanol stoich."));
        numbers.Children.Add(Alpha.Ghost("Race fuel 9.0", () => { _stoich.Text = "9.0"; _offset.Text = "0"; ReadNumbers(); }));

        var left = new StackPanel { Spacing = 6, Children = { Alpha.Row("Sensor profile", _profile, 96, "Volts-to-lambda table."), Alpha.Row("Input", _input, 96, "Which ALPHAemu analog input the sensor is on."), numbers, _feed, _readout } };
        var right = new StackPanel { Spacing = 6, Children = { _curve } };
        var top = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*") };
        Grid.SetColumn(left, 0); top.Children.Add(left);
        Grid.SetColumn(right, 1); top.Children.Add(right);

        Content = new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Alpha.Card("Wideband sensor", new StackPanel { Spacing = 8, Children = { top } }),
                Alpha.Card("Custom curve", new StackPanel { Spacing = 5, Children = { _customRows, CustomButtons() } },
                    Alpha.Note("Volts are held to 0-5 V and AFR to 5-30; the rows are converted to lambda by the stoich above.")),
            }
        };
        RebuildCustom();
        Refresh();
    }

    WrapPanel CustomButtons()
    {
        var w = new WrapPanel { Orientation = Orientation.Horizontal, ItemSpacing = 6, LineSpacing = 6 };
        w.Children.Add(Alpha.Ghost("Add point", () => { _hub.State.WidebandCustom.Add(new AlphaWidebandPoint(2.5, 14.7)); RebuildCustom(); _hub.SaveSoon(); }, "Add a point in the middle of the range."));
        w.Children.Add(Alpha.Ghost("Sort", () => { _hub.State.WidebandCustom.Sort((a, b) => a.Voltage.CompareTo(b.Voltage)); RebuildCustom(); _hub.SaveSoon(); }, "Order the rows by volts (they must climb)."));
        w.Children.Add(Alpha.Ghost("Reset", () => { _hub.State.WidebandCustom = AlphaWideband.DefaultCustomRows(); RebuildCustom(); _hub.SaveSoon(); _hub.ApplyWideband(); }, "Back to 0 V = 10 AFR, 5 V = 20 AFR."));
        w.Children.Add(Alpha.Primary("Use this curve", () => { ReadCustom(); _hub.State.WidebandProfile = "custom"; _profile.SelectedIndex = 0; _hub.ApplyWideband(); _hub.SaveSoon(); Refresh(); }, "Switch the profile to Custom and use these rows."));
        return w;
    }

    void RebuildCustom()
    {
        _customRows.Children.Clear();
        for (int i = 0; i < _hub.State.WidebandCustom.Count; i++)
        {
            int index = i;
            var p = _hub.State.WidebandCustom[i];
            var v = new TextBox { Text = p.Voltage.ToString("0.000", CultureInfo.InvariantCulture), Width = 84, FontSize = 12, FontFamily = Alpha.Mono };
            var afr = new TextBox { Text = p.Afr.ToString("0.00", CultureInfo.InvariantCulture), Width = 84, FontSize = 12, FontFamily = Alpha.Mono };
            v.LostFocus += (_, _) => ReadCustom();
            afr.LostFocus += (_, _) => ReadCustom();
            var remove = Alpha.Danger("Remove", () => { _hub.State.WidebandCustom.RemoveAt(index); RebuildCustom(); _hub.ApplyWideband(); _hub.SaveSoon(); });
            var row = new WrapPanel { Orientation = Orientation.Horizontal, ItemSpacing = 8, LineSpacing = 8 };
            row.Children.Add(new TextBlock { Text = $"point {index + 1}", Width = 62, FontSize = 11.5, Foreground = Alpha.Dim, VerticalAlignment = VerticalAlignment.Center });
            row.Children.Add(v);
            row.Children.Add(new TextBlock { Text = "V  =", VerticalAlignment = VerticalAlignment.Center, FontSize = 11.5, Foreground = Alpha.Dim });
            row.Children.Add(afr);
            row.Children.Add(new TextBlock { Text = "AFR", VerticalAlignment = VerticalAlignment.Center, FontSize = 11.5, Foreground = Alpha.Dim });
            row.Children.Add(remove);
            _customRows.Children.Add(row);
        }
        if (_hub.State.WidebandCustom.Count == 0)
            _customRows.Children.Add(Alpha.Note("No points - the curve falls back to 0 V = 10 AFR, 5 V = 20 AFR."));
    }

    void ReadNumbers()
    {
        if (double.TryParse(_stoich.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var s)) _hub.State.WidebandStoich = Math.Clamp(s, 5, 25);
        if (double.TryParse(_offset.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var o)) _hub.State.WidebandOffset = Math.Clamp(o, -5, 5);
        _stoich.Text = _hub.State.WidebandStoich.ToString("0.00", CultureInfo.InvariantCulture);
        _offset.Text = _hub.State.WidebandOffset.ToString("0.00", CultureInfo.InvariantCulture);
        _hub.ApplyWideband();
        _hub.SaveSoon();
        Refresh();
    }

    void ReadCustom()
    {
        foreach (var child in _customRows.Children.OfType<WrapPanel>())
        {
            var boxes = child.Children.OfType<TextBox>().ToList();
            if (boxes.Count < 2) continue;
            int index = _customRows.Children.IndexOf(child);
            if (index < 0 || index >= _hub.State.WidebandCustom.Count) continue;
            if (double.TryParse(boxes[0].Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) _hub.State.WidebandCustom[index].Voltage = AlphaWideband.ClampVolts(v);
            if (double.TryParse(boxes[1].Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var afrValue)) _hub.State.WidebandCustom[index].Afr = AlphaWideband.ClampAfr(afrValue);
        }
        _hub.ApplyWideband();
        _hub.SaveSoon();
    }

    public void Refresh()
    {
        var s = _hub.Session;
        var input = _hub.State.Analog[Math.Clamp(_hub.State.WidebandInput, 0, 7)];
        double volts = input.Fresh ? input.SourceVolts : double.NaN;
        _curve.Volts = volts;
        _readout.Text = !double.IsNaN(volts)
            ? $"at {volts:0.000} V  →  λ {s.Wideband.Lambda(volts):0.000}  →  {s.Wideband.Afr(volts):0.00} AFR"
            : "no reading yet on that input";
        _feed.IsChecked = _hub.State.FeedWideband;
    }
}



