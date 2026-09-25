// Copyright (c) bmgjet. All rights reserved.
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

    public GaugeEditor(GaugeSpec spec, IEnumerable<string> channels, bool isEdit = false)
    {
        _spec = spec;
        Title = "Gauge";
        Width = 560; SizeToContent = SizeToContent.Height; MinWidth = 460; MinHeight = 360;
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
        var image = new TextBox { Text = spec.ImagePath, Width = 260, Watermark = "a png or jpg behind the whole gauge" };
        var browse = new Button { Content = "Browse…", Margin = new Thickness(6, 0, 0, 0) };
        var opacity = Num(spec.ImageOpacity * 100, 0, 100, 5);
        var faceImage = new TextBox { Text = spec.FaceImagePath, Width = 260, Watermark = "a png or jpg on the dial face" };
        var faceBrowse = new Button { Content = "Browse…", Margin = new Thickness(6, 0, 0, 0) };
        var faceOpacity = Num(spec.FaceOpacity * 100, 0, 100, 5);
        var label = new TextBox { Text = spec.Label, Width = 200, Watermark = "shown on the gauge (blank: the channel's name)" };
        var unit = new TextBox { Text = spec.Unit, Width = 120, Watermark = "rpm, kPa, °C..." };
        var min = Num(spec.Min); var max = Num(spec.Max);
        var warn = new TextBox { Text = spec.Warn?.ToString("0.###") ?? "", Width = 120, Watermark = "none" };
        var below = new CheckBox { Content = "warn below instead of above", IsChecked = spec.WarnBelow };
        var dec = Num(spec.Decimals, 0, 3, 1);
        var secs = Num(spec.Seconds, 2, 300, 5);

        // the preview keeps the gauge's own shape but is scaled to fit beside the form: a gauge stretched wide on the dashboard must not push the editor off the screen or over its own fields
        var preview = new GaugeControl(spec.Clone());
        var previewFit = new Viewbox { Child = preview, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, Margin = new Thickness(8) };
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
            _spec.FaceImagePath = (faceImage.Text ?? "").Trim();
            _spec.FaceOpacity = (double)(faceOpacity.Value ?? 100) / 100;
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
            preview.Spec.FaceImagePath = p.FaceImagePath; preview.Spec.FaceOpacity = p.FaceOpacity;
            // show it three-quarters of the way up its own channel, so the preview means something
            var sample = new LogFrame { T = 0 };
            sample.Set(p.Channel, p.Min + ((p.Max - p.Min) * 0.75));
            preview.Show(sample);
            preview.InvalidateVisual();
        }
        foreach (var c in new Control[] { kind, channel }) ((ComboBox)c).SelectionChanged += (_, _) => Sync();
        foreach (var t in new[] { label, unit, warn, typed, face, accent, ink, image, faceImage }) t.TextChanged += (_, _) => Sync();
        foreach (var n in new[] { min, max, dec, secs, ticks, opacity, faceOpacity }) n.ValueChanged += (_, _) => Sync();
        channel.SelectionChanged += (_, _) => { if (channel.SelectedItem is string c) typed.Text = c; };
        async Task Pick(TextBox into, string title)
        {
            var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = title, AllowMultiple = false,
                FileTypeFilter = new[] { new FilePickerFileType("Images") { Patterns = new[] { "*.png", "*.jpg", "*.jpeg", "*.bmp", "*.webp" } } },
            });
            if (files.FirstOrDefault()?.TryGetLocalPath() is { } path) { into.Text = path; Sync(); }
        }
        browse.Click += async (_, _) => await Pick(image, "Background picture for the gauge");
        faceBrowse.Click += async (_, _) => await Pick(faceImage, "Picture for the dial face");
        below.IsCheckedChanged += (_, _) => Sync();

        var form = new StackPanel { Margin = new Thickness(12, 8) };
        form.Children.Add(Row("Kind", kind, "Dial with a needle, bar, big number, trigger light, rolling graph, a digital arc sweep, shift lights, or a caption."));
        form.Children.Add(Row("Channel", channel, "Which logged value it shows. Aux channels and a wideband appear here once they are logging."));
        form.Children.Add(Row("Label", label, "What to call it on the gauge."));
        form.Children.Add(Row("Unit", unit, "Printed after the reading."));
        form.Children.Add(Row("Lowest", min, "The bottom of the scale."));
        form.Children.Add(Row("Highest", max, "The top of the scale."));
        form.Children.Add(Row("Warn at", warn, "Past this the gauge turns amber and a light comes on. Leave it empty for no warning."));
        form.Children.Add(below);
        form.Children.Add(Row("Decimals", dec, "Digits after the point."));
        form.Children.Add(Row("Graph seconds", secs, "How much history a graph or bar graph keeps on screen."));
        form.Children.Add(Row("Dial marks / lights", ticks, "How many marks around a dial, or how many lights in a row of shift lights."));
        form.Children.Add(Row("Or type a channel", typed,
            "Anything the log or an external feed produces, including channels that are not logging yet (external feeds are named feed.key)."));
        form.Children.Add(Row("Face colour", face, "Background of the gauge, as #RRGGBB. Empty uses the dark theme's own."));
        form.Children.Add(Row("Needle / fill colour", accent, "The needle, the bar, the graph line and the lamp, as #RRGGBB."));
        form.Children.Add(Row("Text colour", ink, "The reading, as #RRGGBB."));
        var imageRow = new StackPanel { Orientation = Orientation.Horizontal };
        imageRow.Children.Add(image); imageRow.Children.Add(browse);
        var faceRow = new StackPanel { Orientation = Orientation.Horizontal };
        faceRow.Children.Add(faceImage); faceRow.Children.Add(faceBrowse);
        form.Children.Add(Row("Face picture", faceRow, "A picture on the dial face itself, under the scale and the needle - your own dial face, a scale you have made. On the other kinds it fills the gauge."));
        form.Children.Add(Row("Face opacity %", faceOpacity, "How solid the face is - its colour and its picture. Turn it down to let the background picture show through."));
        form.Children.Add(Row("Background", imageRow, "A picture behind the whole gauge - a panel, a carbon weave, a logo."));
        form.Children.Add(Row("Background opacity %", opacity, "How strongly the background picture shows."));

        var ok = new Button { Content = spec.Width > 0 && isEdit ? "OK" : "Add", IsDefault = true, MinWidth = 90 };
        ok.Click += (_, _) => { Sync(); Result = _spec; Close(); };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90 };
        cancel.Click += (_, _) => Close();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 6, Margin = new Thickness(12) };
        buttons.Children.Add(cancel); buttons.Children.Add(ok);

        // the preview sits above the form in a box of its own, so however the gauge is shaped it can never overlap a field; the form scrolls when the screen is too short for all of it
        previewFit.MaxWidth = 500; previewFit.MaxHeight = 170;
        previewFit.HorizontalAlignment = HorizontalAlignment.Center;
        var previewBox = new StackPanel { Margin = new Thickness(12, 8, 12, 0) };
        previewBox.Children.Add(new TextBlock { Text = "preview", FontSize = 11, Opacity = 0.7, Margin = new Thickness(0, 0, 0, 2) });
        previewBox.Children.Add(new Border { Child = previewFit, Height = 186, ClipToBounds = true });
        var scroller = new ScrollViewer { Content = form, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*,Auto") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(previewBox, 1); g.Children.Add(previewBox);
        Grid.SetRow(scroller, 2); g.Children.Add(scroller);
        Grid.SetRow(buttons, 3); g.Children.Add(buttons);
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
