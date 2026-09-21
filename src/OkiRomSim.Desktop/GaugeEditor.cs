using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using OkiRomSim.Calibration;

namespace OkiRomSim.Desktop;

/// What one gauge shows: its kind, the logged channel behind it, the range it covers and when it should warn. The preview beside the form is the gauge itself, so the numbers are easy to get right before it goes on the dashboard.
public sealed class GaugeEditor : Window
{
    public GaugeSpec? Result { get; private set; }
    readonly GaugeSpec _spec;

    public GaugeEditor(GaugeSpec spec, IEnumerable<string> channels)
    {
        _spec = spec;
        Title = "Gauge";
        Width = 560; SizeToContent = SizeToContent.Height; CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var chrome = DarkChrome.Apply(this, "Gauge");

        var known = channels.Concat(new[] { spec.Channel, "rpm", "map_kpa", "tps_pct", "ect_c", "iat_c", "o2_v", "afr", "lambda", "knock", "inj_ms", "ign_deg", "batt_v", "vtec" })
                            .Where(c => !string.IsNullOrWhiteSpace(c)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(c => c).ToList();

        var kind = new ComboBox { ItemsSource = Enum.GetValues<GaugeKind>().ToList(), SelectedItem = spec.Kind, Width = 160 };
        var channel = new ComboBox
        {
            ItemsSource = known, Width = 200,
            SelectedItem = known.FirstOrDefault(c => c.Equals(spec.Channel, StringComparison.OrdinalIgnoreCase)) ?? known[0],
        };
        // an external feed's channel may not be in the log yet, so it can also be typed
        var typed = new TextBox { Text = spec.Channel, Width = 200, Watermark = "or type a channel, e.g. dyno.torque" };
        var ticks = Num(spec.Ticks, 2, 40, 1);
        var face = new TextBox { Text = spec.FaceColour, Width = 110, Watermark = "#1a1c20" };
        var accent = new TextBox { Text = spec.AccentColour, Width = 110, Watermark = "#4ec97a" };
        var ink = new TextBox { Text = spec.TextColour, Width = 110, Watermark = "#d7dae0" };
        var image = new TextBox { Text = spec.ImagePath, Width = 300, Watermark = "a png or jpg to draw behind it" };
        var browse = new Button { Content = "Browse…", Margin = new Thickness(6, 0, 0, 0) };
        var opacity = Num(spec.ImageOpacity * 100, 5, 100, 5);
        var label = new TextBox { Text = spec.Label, Width = 200, Watermark = "shown on the gauge (blank: the channel's name)" };
        var unit = new TextBox { Text = spec.Unit, Width = 120, Watermark = "rpm, kPa, °C..." };
        var min = Num(spec.Min); var max = Num(spec.Max);
        var warn = new TextBox { Text = spec.Warn?.ToString("0.###") ?? "", Width = 120, Watermark = "none" };
        var below = new CheckBox { Content = "warn below instead of above", IsChecked = spec.WarnBelow };
        var dec = Num(spec.Decimals, 0, 3, 1);
        var secs = Num(spec.Seconds, 2, 300, 5);

        var preview = new GaugeControl(spec.Clone()) { Margin = new Thickness(8) };
        void Sync()
        {
            _spec.Kind = (GaugeKind)(kind.SelectedItem ?? GaugeKind.Dial);
            _spec.Channel = channel.SelectedItem as string ?? "rpm";
            _spec.Label = label.Text ?? "";
            _spec.Unit = unit.Text ?? "";
            _spec.Min = (double)(min.Value ?? 0);
            _spec.Max = (double)(max.Value ?? 1);
            _spec.Warn = double.TryParse(warn.Text, out var wv) ? wv : null;
            _spec.WarnBelow = below.IsChecked == true;
            _spec.Decimals = (int)(dec.Value ?? 0);
            _spec.Seconds = (double)(secs.Value ?? 20);
            _spec.Ticks = (int)(ticks.Value ?? 10);
            _spec.FaceColour = (face.Text ?? "").Trim();
            _spec.AccentColour = (accent.Text ?? "").Trim();
            _spec.TextColour = (ink.Text ?? "").Trim();
            _spec.ImagePath = (image.Text ?? "").Trim();
            _spec.ImageOpacity = (double)(opacity.Value ?? 100) / 100;
            if ((typed.Text ?? "").Trim() is { Length: > 0 } t && !t.Equals(_spec.Channel, StringComparison.OrdinalIgnoreCase)
                && !t.Equals(channel.SelectedItem as string, StringComparison.OrdinalIgnoreCase))
                _spec.Channel = t;
            var p = _spec.Clone();
            p.Width = preview.Spec.Width; p.Height = preview.Spec.Height;
            preview.Spec.Kind = p.Kind; preview.Spec.Channel = p.Channel; preview.Spec.Label = p.Label; preview.Spec.Unit = p.Unit;
            preview.Spec.Min = p.Min; preview.Spec.Max = p.Max; preview.Spec.Warn = p.Warn; preview.Spec.WarnBelow = p.WarnBelow;
            preview.Spec.Decimals = p.Decimals;
            preview.Spec.Ticks = p.Ticks;
            preview.Spec.FaceColour = p.FaceColour; preview.Spec.AccentColour = p.AccentColour; preview.Spec.TextColour = p.TextColour;
            preview.Spec.ImagePath = p.ImagePath; preview.Spec.ImageOpacity = p.ImageOpacity;
            // show it three-quarters of the way up its own channel, so the preview means something
            var sample = new LogFrame { T = 0 };
            sample.Set(p.Channel, p.Min + (p.Max - p.Min) * 0.75);
            preview.Show(sample);
            preview.InvalidateVisual();
        }
        foreach (var c in new Control[] { kind, channel }) ((ComboBox)c).SelectionChanged += (_, _) => Sync();
        foreach (var t in new[] { label, unit, warn, typed, face, accent, ink, image }) t.TextChanged += (_, _) => Sync();
        foreach (var n in new[] { min, max, dec, secs, ticks, opacity }) n.ValueChanged += (_, _) => Sync();
        channel.SelectionChanged += (_, _) => { if (channel.SelectedItem is string c) typed.Text = c; };
        browse.Click += async (_, _) =>
        {
            var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "Picture for the gauge", AllowMultiple = false,
                FileTypeFilter = new[] { new FilePickerFileType("Images") { Patterns = new[] { "*.png", "*.jpg", "*.jpeg", "*.bmp", "*.webp" } } },
            });
            if (files.FirstOrDefault()?.TryGetLocalPath() is { } path) { image.Text = path; Sync(); }
        };
        below.IsCheckedChanged += (_, _) => Sync();

        var form = new StackPanel { Margin = new Thickness(12, 8) };
        form.Children.Add(Row("Kind", kind, "Dial with a needle, bar, big number, trigger light, or a rolling graph."));
        form.Children.Add(Row("Channel", channel, "Which logged value it shows. Aux channels and a wideband appear here once they are logging."));
        form.Children.Add(Row("Label", label, "What to call it on the gauge."));
        form.Children.Add(Row("Unit", unit, "Printed after the reading."));
        form.Children.Add(Row("Lowest", min, "The bottom of the scale."));
        form.Children.Add(Row("Highest", max, "The top of the scale."));
        form.Children.Add(Row("Warn at", warn, "Past this the gauge turns amber and a light comes on. Leave it empty for no warning."));
        form.Children.Add(below);
        form.Children.Add(Row("Decimals", dec, "Digits after the point."));
        form.Children.Add(Row("Graph seconds", secs, "How much history a graph or bar graph keeps on screen."));
        form.Children.Add(Row("Dial marks", ticks, "How many marks around a dial."));
        form.Children.Add(Row("Or type a channel", typed,
            "Anything the log or an external feed produces, including channels that are not logging yet (external feeds are named feed.key)."));
        form.Children.Add(Row("Face colour", face, "Background of the gauge, as #RRGGBB. Empty uses the dark theme's own."));
        form.Children.Add(Row("Needle / fill colour", accent, "The needle, the bar, the graph line and the lamp, as #RRGGBB."));
        form.Children.Add(Row("Text colour", ink, "The reading, as #RRGGBB."));
        var imageRow = new StackPanel { Orientation = Orientation.Horizontal };
        imageRow.Children.Add(image); imageRow.Children.Add(browse);
        form.Children.Add(Row("Picture", imageRow, "A picture drawn behind the gauge - your own dial face, a logo, a scale you have made."));
        form.Children.Add(Row("Picture opacity %", opacity, "How strongly the picture shows through."));

        var ok = new Button { Content = "Add", IsDefault = true, MinWidth = 90 };
        ok.Click += (_, _) => { Sync(); Result = _spec; Close(); };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90 };
        cancel.Click += (_, _) => Close();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 6, Margin = new Thickness(12) };
        buttons.Children.Add(cancel); buttons.Children.Add(ok);

        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        Grid.SetColumn(form, 0); body.Children.Add(form);
        var previewBox = new StackPanel { Margin = new Thickness(6, 12, 12, 12) };
        previewBox.Children.Add(new TextBlock { Text = "preview (three-quarter scale)", FontSize = 11, Opacity = 0.7, Margin = new Thickness(8, 0, 0, 4) });
        previewBox.Children.Add(preview);
        Grid.SetColumn(previewBox, 1); body.Children.Add(previewBox);

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,Auto") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(body, 1); g.Children.Add(body);
        Grid.SetRow(buttons, 2); g.Children.Add(buttons);
        Content = g;
        Sync();
    }

    static NumericUpDown Num(double v, double min = -1e6, double max = 1e6, double step = 1) => new()
    {
        Value = (decimal)v, Minimum = (decimal)min, Maximum = (decimal)max, Increment = (decimal)step,
        Width = 140, FormatString = "0.###", FontFamily = MainWindow.MonoFont,
    };

    static Control Row(string label, Control editor, string tip)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("120,*"), Margin = new Thickness(0, 3) };
        var l = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        editor.HorizontalAlignment = HorizontalAlignment.Left;
        Grid.SetColumn(l, 0); g.Children.Add(l);
        Grid.SetColumn(editor, 1); g.Children.Add(editor);
        ToolTip.SetTip(g, tip);
        return g;
    }
}
