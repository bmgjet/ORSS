// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// The small set-up windows the established tuning software keeps on its own pages: the injector calibration, the MAP sensor, and the AFR correction a datalog asks for. They all work the same way: nothing is written until Apply, the preview line says what would change first, and the whole thing lands as one undo step.
static class Form
{
    public static StackPanel Page() => new() { Margin = new Thickness(12, 10), Spacing = 0 };

    /// A titled block, the way a Windows group box reads.
    public static Control Group(string title, params Control[] rows)
    {
        var inner = new StackPanel { Margin = new Thickness(10, 6, 8, 8) };
        foreach (var r in rows) inner.Children.Add(r);
        return new Border
        {
            BorderBrush = new SolidColorBrush(Color.FromArgb(70, 255, 255, 255)),
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4),
            Margin = new Thickness(0, 4, 0, 8),
            Child = new StackPanel
            {
                Children =
                {
                    new TextBlock { Text = title, FontWeight = FontWeight.Bold, FontSize = 12, Margin = new Thickness(10, 6, 0, 0) },
                    inner,
                },
            },
        };
    }

    /// "label  [editor]  unit  note" on one line, with the labels of a block lining up.
    public static Control Row(string label, Control editor, string unit = "", string? note = null, string? tip = null)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("190,Auto,44,*"), Margin = new Thickness(0, 3) };
        var l = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        editor.HorizontalAlignment = HorizontalAlignment.Left;
        var u = new TextBlock { Text = unit, VerticalAlignment = VerticalAlignment.Center, FontSize = 11, Opacity = 0.8, Margin = new Thickness(6, 0, 0, 0) };
        var n = new TextBlock
        {
            Text = note ?? "", VerticalAlignment = VerticalAlignment.Center, FontSize = 11, Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 0, 0, 0),
        };
        Grid.SetColumn(l, 0); g.Children.Add(l);
        Grid.SetColumn(editor, 1); g.Children.Add(editor);
        Grid.SetColumn(u, 2); g.Children.Add(u);
        Grid.SetColumn(n, 3); g.Children.Add(n);
        if (tip != null) ToolTip.SetTip(g, tip);
        return g;
    }

    public static NumericUpDown Num(double value, double min, double max, double step, string format = "0.###")
        => new()
        {
            Value = (decimal)Math.Clamp(value, min, max), Minimum = (decimal)min, Maximum = (decimal)max,
            Increment = (decimal)step, Width = 130, FormatString = format, FontFamily = MainWindow.MonoFont,
        };

    public static double V(NumericUpDown n) => (double)(n.Value ?? 0);

    public static TextBlock Note(string t) => new()
    {
        Text = t, FontSize = 11.5, Opacity = 0.85, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 6),
    };

    public static Button Btn(string text, Action a, string tip, bool def = false)
    {
        var b = new Button { Content = text, MinWidth = 96, IsDefault = def };
        b.Click += (_, _) => a();
        ToolTip.SetTip(b, tip);
        return b;
    }

    /// The bottom bar: a preview line above, Close and Apply on the right.
    public static Grid Shell(Window w, string title, Control body, TextBlock preview, Action apply)
    {
        var chrome = DarkChrome.Apply(w, title);
        var bar = new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Spacing = 6, Margin = new Thickness(12, 4, 12, 12),
        };
        bar.Children.Add(Btn("Close", w.Close, "Close without writing anything."));
        bar.Children.Add(Btn("Apply", apply, "Write these bytes to the ROM as one change (Undo puts them all back).", def: true));
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto,Auto") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        var scroll = new ScrollViewer { Content = body, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        Grid.SetRow(scroll, 1); g.Children.Add(scroll);
        // the preview can list every axis it would move: it scrolls in a box of its own instead of pushing the inputs and the buttons off the window
        preview.Margin = new Thickness(12, 4);
        var previewBox = new ScrollViewer { Content = preview, MaxHeight = 120, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        Grid.SetRow(previewBox, 2); g.Children.Add(previewBox);
        Grid.SetRow(bar, 3); g.Children.Add(bar);
        return g;
    }

    /// The first definition whose name contains one of these words (how a named setting is found in a ROM whose labels came from Detect).
    public static ItemDef? Find(DefinitionSet defs, params string[] words)
    {
        foreach (var word in words)
        {
            var hit = defs.Items.FirstOrDefault(i => !(i.IsTable && i.Count > 1) &&
                i.Name.Replace("_", "").Replace(" ", "").Contains(word, StringComparison.OrdinalIgnoreCase));
            if (hit != null) return hit;
        }
        return null;
    }
}

// ---------------------------------------------------------------- injectors

/// Injector calibration, laid out the way the established tuning software does it: the size the calibration was written for, the size fitted, the multiplier that follows from the two, the injector offset (dead time) and the fuel trims. The multiplier is the whole point: bigger injectors flow more, so the same air needs a shorter pulse, and every fuel table is scaled by stock / fitted. Where the ROM's definitions carry a multiplier, an offset or a trim setting of their own, those are written too, so the ECU is told the same thing twice over rather than only having its maps moved.
public sealed class InjectorWindow : Window
{
    readonly SimHost _host;
    // two lines at most; the whole report is on its tooltip
    readonly TextBlock _preview = new()
    {
        TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.9, MaxLines = 2,
        TextTrimming = TextTrimming.CharacterEllipsis,
    };
    readonly NumericUpDown _stock, _fitted, _offset, _overall, _crank, _postStart, _tipIn;
    readonly TextBlock _multiplier = new() { FontFamily = MainWindow.MonoFont, VerticalAlignment = VerticalAlignment.Center, FontWeight = FontWeight.Bold };
    readonly CheckBox _scaleMaps = new() { Content = "scale every fuel table by the multiplier", IsChecked = true, Margin = new Thickness(0, 6, 0, 0) };
    readonly CheckBox _trimsToo = new() { Content = "set the cranking and tip-in trims to suit the new injectors", Margin = new Thickness(0, 2, 0, 0) };
    readonly ItemDef? _dMult, _dOffset, _dOverall, _dCrank, _dPost, _dTip;
    public bool Applied { get; private set; }

    public InjectorWindow(SimHost host)
    {
        _host = host;
        Title = "Injector calibration";
        // sized to what it holds, so every control is on screen when it opens
        Width = 520; MinWidth = 460; SizeToContent = SizeToContent.Height; MaxHeight = 760;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var defs = _host.Defs();
        _dMult = Form.Find(defs, "injmultiplier", "injectormultiplier", "fuelmultiplier");
        _dOffset = Form.Find(defs, "deadtime", "injoffset", "injectoroffset", "injlatency");
        _dOverall = Form.Find(defs, "totalfueltrim", "overallfuel", "globalfuel", "fueltrim");
        _dCrank = Form.Find(defs, "crankfuel", "crankingtrim", "cranktrim");
        _dPost = Form.Find(defs, "poststartfuel", "poststarttrim", "afterstart");
        _dTip = Form.Find(defs, "tpstipin", "tipin");

        _stock = Form.Num(240, 1, 3000, 10, "0");
        _fitted = Form.Num(310, 1, 3000, 10, "0");
        _offset = Form.Num(Read(_dOffset, 0.9), 0, 10, 0.05, "0.00");
        _overall = Form.Num(Read(_dOverall, 0), -50, 50, 0.5, "0.0");
        _crank = Form.Num(Read(_dCrank, 0), -50, 50, 0.5, "0.0");
        _postStart = Form.Num(Read(_dPost, 0), -50, 50, 0.5, "0.0");
        _tipIn = Form.Num(Read(_dTip, 0), -50, 50, 0.5, "0.0");
        foreach (var n in new[] { _stock, _fitted, _offset, _overall, _crank, _postStart, _tipIn })
            n.ValueChanged += (_, _) => Preview();
        _scaleMaps.IsCheckedChanged += (_, _) => Preview();
        _trimsToo.IsCheckedChanged += (_, _) => Preview();

        // The explanations live in tooltips (hover a row); on the page each row is just the label, the box and the unit, plus a dash when this ROM has no such setting to write.
        var page = Form.Page();
        page.Children.Add(Form.Note("Every fuel table is scaled by stock / fitted. Any unit works for the sizes - only the ratio matters."));
        page.Children.Add(Form.Group("Injector calibration",
            Row("Stock injector", _stock, "cc", null,
                "The injectors the calibration was written for. Together with the size fitted this gives the multiplier."),
            Row("New injector", _fitted, "cc", null,
                "The injectors in the engine now. Bigger ones get a shorter pulse."),
            Row("Final multiplier", _multiplier, "", _dMult,
                "Stock divided by fitted: what every fuel table (and the ROM's own multiplier, where it has one) is scaled by."),
            Row("Injector offset", _offset, "ms", _dOffset,
                "Dead time: how long an injector takes to start flowing after it is switched on."),
            _scaleMaps,
            _trimsToo));
        page.Children.Add(Form.Group("Fuel trim",
            Row("Overall fuel", _overall, "%", _dOverall, "A trim on everything the fuel maps ask for."),
            Row("Cranking trim", _crank, "%", _dCrank, "Extra (or less) fuel while the starter is turning."),
            Row("Post start trim", _postStart, "%", _dPost, "Extra fuel for the first moments after it fires."),
            Row("TPS tip-in", _tipIn, "%", _dTip, "Extra fuel when the throttle is opened quickly.")));
        var tables = FuelTables().ToList();
        var tableNote = Form.Note(tables.Count == 0
            ? "No fuel tables defined yet - press Detect on the Calibration page first."
            : $"{tables.Count} fuel table{(tables.Count == 1 ? "" : "s")} will be scaled (hover for the list).");
        if (tables.Count > 0) ToolTip.SetTip(tableNote, string.Join("\n", tables.Select(t => t.Name)));
        page.Children.Add(tableNote);

        Content = Form.Shell(this, "Injector calibration", page, _preview, Apply);
        Preview();
    }

    double Read(ItemDef? item, double fallback)
    {
        try { return item == null ? fallback : _host.ReadItem(item)[0].Value; } catch { return fallback; }
    }

    static string Where(ItemDef? item) => item == null ? "(no such setting in this ROM's definitions)" : $"writes {item.Name} @ {item.Address:X4}";

    /// A row without the note column: what it does and which setting it writes go in the tooltip, and a setting this ROM does not have shows as a dash beside the unit.
    static Control Row(string label, Control editor, string unit, ItemDef? writes, string tip)
    {
        bool settable = writes != null || unit == "cc";
        var row = Form.Row(label, editor, unit, settable ? null : "\u2013",
            tip + (unit == "cc" ? "" : "\n" + Where(writes)));
        if (!settable) editor.Opacity = 0.6;
        return row;
    }

    IEnumerable<ItemDef> FuelTables() =>
        _host.Defs().Items.Where(i => i.IsTable && i.Count > 1 &&
            (i.ColumnScaleAddress != null || i.Category.Equals("Fuel", StringComparison.OrdinalIgnoreCase)));

    double Factor => Form.V(_fitted) <= 0 ? 1 : Form.V(_stock) / Form.V(_fitted);

    bool _previewing;

    void Preview()
    {
        // filling the trim boxes below raises their own ValueChanged, which comes back here
        if (_previewing) return;
        _previewing = true;
        try { PreviewCore(); }
        finally { _previewing = false; }
    }

    void PreviewCore()
    {
        double f = Factor;
        _multiplier.Text = f.ToString("0.000", CultureInfo.InvariantCulture);
        if (_trimsToo.IsChecked == true)
        {
            double trim = Math.Round((1 - f) * 100, 1);
            _crank.Value = (decimal)Math.Clamp(-trim, -50, 50);
            _tipIn.Value = (decimal)Math.Clamp(-trim, -50, 50);
        }
        var r = Build();
        _preview.Text = r == null || !r.Any
            ? $"multiplier {f:0.000}: nothing would change"
            : $"{r.Patches.Count} byte(s) would change - hover for the details.";
        ToolTip.SetTip(_preview, r == null || !r.Any ? "the sizes are the same, or there is nothing to write" : r.Summary);
    }

    ScaleReport? Build()
    {
        try
        {
            var defs = _host.Defs();
            var rom = _host.RomCopy();
            double f = Factor;
            var report = new ScaleReport($"injectors {Form.V(_stock):0} -> {Form.V(_fitted):0}: fuel x {f:0.###}", 0, 0, 0, []);
            if (_scaleMaps.IsChecked == true && Math.Abs(f - 1) > 1e-6)
                foreach (var t in FuelTables()) report = report.Merge(Rescale.ScaleTable(defs, rom, t, f));
            report = report.Merge(Setting(defs, rom, _dMult, f, "multiplier"));
            report = report.Merge(Setting(defs, rom, _dOffset, Form.V(_offset), "injector offset"));
            report = report.Merge(Setting(defs, rom, _dOverall, Form.V(_overall), "overall fuel"));
            report = report.Merge(Setting(defs, rom, _dCrank, Form.V(_crank), "cranking trim"));
            report = report.Merge(Setting(defs, rom, _dPost, Form.V(_postStart), "post start trim"));
            report = report.Merge(Setting(defs, rom, _dTip, Form.V(_tipIn), "TPS tip-in"));
            return report;
        }
        catch (Exception ex) { return ScaleReport.Nothing("cannot work that out: " + ex.Message); }
    }

    /// One single-value setting, as the bytes it would take to hold `value`.
    static ScaleReport Setting(DefinitionSet defs, byte[] rom, ItemDef? item, double value, string what)
    {
        if (item == null) return new ScaleReport("", 0, 0, 0, []);
        var before = RomData.Read(defs, rom, item)[0].Raw;
        var copy = (byte[])rom.Clone();
        RomData.Write(defs, copy, item, 0, value);
        var patches = new List<BytePatch>();
        for (int a = item.Address; a < item.Address + item.ElementSize && a < rom.Length; a++)
            if (copy[a] != rom[a]) { patches.Add(new BytePatch(a, copy[a])); rom[a] = copy[a]; }
        return patches.Count == 0
            ? new ScaleReport("", 0, 0, 0, [])
            : new ScaleReport($"{item.Name} ({what}) = {value:0.###} (raw {before:0} -> {RomData.ReadRaw(rom, item.Address, item.Type):0})", 1, 0, 0, patches);
    }

    void Apply()
    {
        var r = Build();
        if (r == null || !r.Any) { _preview.Text = r?.Summary ?? "nothing to do"; return; }
        try
        {
            int n = _host.ApplyPatches(r.Patches, $"injectors {Form.V(_stock):0} -> {Form.V(_fitted):0}");
            Applied = true;
            AppLog.Action("calibration", "injector calibration: " + r.Summary);
            // the sizes have moved on: the calibration now matches the injectors fitted
            _stock.Value = _fitted.Value;
            _preview.Text = $"{n} byte(s) written - Undo puts them back.";
            ToolTip.SetTip(_preview, r.Summary);
        }
        catch (Exception ex) { _preview.Text = "could not apply: " + ex.Message; AppLog.Error("calibration", "injector calibration failed", ex); }
    }
}

// ---------------------------------------------------------------- MAP sensor

/// MAP sensor set-up, laid out the way the established tuning software does it: pick the sensor fitted from the list (or type what it reads at 0 V and at 5 V), and every load breakpoint moves to the count that stands for the same real pressure. A sensor is described by two numbers - what it reads at 0 V and what it reads at 5 V - and that is enough: the count a breakpoint holds means a pressure on the old sensor, and this works out the count that means the same pressure on the new one. Scaling by a ratio cannot do that for a sensor with an offset (a 3 bar unit reading -431 mbar at 0 V), which is why both ends are asked for.
public sealed class MapSensorWindow : Window
{
    /// The sensors the tuning software offers, as mBar at 0 V and mBar at 5 V.
    public static readonly (string Name, int Min, int Max)[] Sensors =
    {
        ("Stock 1.75 Bar", -70, 1790),
        ("GM 2 Bar", 8, 2041),
        ("GM 3 Bar", 11, 3155),
        ("GM 4 Bar PN12643955", -350, 4250),
        ("Motorola 2.5 Bar", 70, 2590),
        ("AEM 3.5 Bar", -431, 3844),
        ("AEM 5 Bar", -625, 5625),
        ("Xenocron 3 Bar", 11, 3040),
        ("Xenocron 4 Bar", 35, 4180),
        ("Omnipower 2.5 Bar", 100, 2600),
        ("Omnipower 3 Bar", 11, 3040),
        ("Omnipower 4 Bar", 35, 4180),
        ("Motec 3 Bar", 2, 3047),
        ("Neetronics 2 Bar", 35, 2070),
        ("Neetronics 2.5 Bar", 65, 2525),
        ("Neetronics 3 Bar", 42, 3167),
        ("MSD 3 Bar", -130, 3130),
        ("RDX 2.8 Bar", -200, 2800),
        ("PLM 4 Bar", 31, 4225),
        ("Skunk2 4 Bar", 35, 4180),
        ("Speedfactory 4 Bar", 35, 4180),
        ("DTC 3 Bar", 9, 2955),
        ("Sparkks 4 Bar", -176, 4224),
        ("NXP 2.5 Bar", 100, 2551),
        ("NXP 3 Bar", 14, 3053),
        ("NXP 4 Bar", 35, 4165),
        ("NXP 7 Bar", -155, 7457),
    };

    const double SeaLevelMbar = 1013;

    readonly SimHost _host;
    readonly TextBlock _preview = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.9, MinHeight = 48 };
    readonly ComboBox _oldPick = new() { Width = 220 }, _newPick = new() { Width = 220 };
    readonly NumericUpDown _oldMin, _oldMax, _newMin, _newMax;
    readonly TextBlock _scalar = new() { FontFamily = MainWindow.MonoFont, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _koeo = new() { FontFamily = MainWindow.MonoFont, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _boost = new() { FontFamily = MainWindow.MonoFont, VerticalAlignment = VerticalAlignment.Center };
    bool _filling;
    public bool Applied { get; private set; }

    public MapSensorWindow(SimHost host)
    {
        _host = host;
        Title = "MAP sensor";
        Width = 700; Height = 600; MinWidth = 560; MinHeight = 400;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var names = Sensors.Select(x => $"{x.Name}  ({x.Min} .. {x.Max} mBar)").Append("Custom").ToList();
        _oldPick.ItemsSource = names; _newPick.ItemsSource = names;
        _oldMin = Form.Num(Sensors[0].Min, -2000, 5000, 5, "0");
        _oldMax = Form.Num(Sensors[0].Max, 100, 12000, 10, "0");
        _newMin = Form.Num(Sensors[2].Min, -2000, 5000, 5, "0");
        _newMax = Form.Num(Sensors[2].Max, 100, 12000, 10, "0");
        _oldPick.SelectedIndex = 0; _newPick.SelectedIndex = 2;
        _oldPick.SelectionChanged += (_, _) => Fill(_oldPick, _oldMin, _oldMax);
        _newPick.SelectionChanged += (_, _) => Fill(_newPick, _newMin, _newMax);
        foreach (var (n, pick) in new[] { (_oldMin, _oldPick), (_oldMax, _oldPick), (_newMin, _newPick), (_newMax, _newPick) })
            n.ValueChanged += (_, _) => { if (!_filling) { pick.SelectedIndex = Sensors.Length; } Preview(); };

        var page = Form.Page();
        page.Children.Add(Form.Note(
            "A sensor is described by what it reads at 0 V and at 5 V. Every load breakpoint of every map holds a count that means a pressure " +
            "on the sensor the calibration was written for; Apply moves each one to the count that means the same pressure on the sensor fitted. " +
            "The maps themselves are not touched - only the load axes they are read against."));
        page.Children.Add(Form.Group("Sensor in the calibration",
            Form.Row("Sensor", _oldPick, "", "what the ROM was written for", "The sensor the load breakpoints were set up around."),
            Form.Row("mBar at 0 V (offset)", _oldMin, "mBar"),
            Form.Row("mBar at 5 V", _oldMax, "mBar")));
        page.Children.Add(Form.Group("Sensor fitted",
            Form.Row("Sensor", _newPick, "", "what is on the car now", "Pick one from the list, or type both ends for a sensor that is not on it."),
            Form.Row("mBar at 0 V (offset)", _newMin, "mBar"),
            Form.Row("mBar at 5 V", _newMax, "mBar"),
            Form.Row("mBar / Volt scalar", _scalar, "mBar/V", "(max - min) / 5"),
            Form.Row("Engine off voltage", _koeo, "V", "what it should read at sea level, key on engine off"),
            Form.Row("Full scale boost", _boost, "psi", "gauge pressure at 5 V")));
        var maps = Maps().ToList();
        page.Children.Add(Form.Note(maps.Count == 0
            ? "No map has a load axis in the ROM to move: press Detect on the Calibration page first, or give the maps a column axis in the Definition form."
            : $"Load axes that would move: {string.Join(", ", maps.Select(m => m.ColAxis!.Name ?? m.ColAxis!.Address?.ToString("X4")).Distinct())} " +
              $"(from {string.Join(", ", maps.Select(m => m.Name))})."));

        Content = Form.Shell(this, "MAP sensor", page, _preview, Apply);
        Preview();
    }

    void Fill(ComboBox pick, NumericUpDown min, NumericUpDown max)
    {
        int i = pick.SelectedIndex;
        if (i < 0 || i >= Sensors.Length) { Preview(); return; }
        _filling = true;
        min.Value = Sensors[i].Min; max.Value = Sensors[i].Max;
        _filling = false;
        Preview();
    }

    IEnumerable<ItemDef> Maps() =>
        _host.Defs().Items.Where(i => i.IsTable && i.Cols > 1 && i.ColAxis?.Address != null);

    void Preview()
    {
        double lo = Form.V(_newMin), hi = Form.V(_newMax);
        _scalar.Text = ((hi - lo) / 5).ToString("0.0", CultureInfo.InvariantCulture);
        // what the sensor puts out with the engine off at sea level: its span covers min..max over 5 V
        double span = hi + Math.Abs(lo);
        _koeo.Text = span <= 0 ? "-" : (5.0 / span * (SeaLevelMbar - lo)).ToString("0.00", CultureInfo.InvariantCulture);
        _boost.Text = ((hi * 0.0145037738) - 14.7).ToString("0.0", CultureInfo.InvariantCulture);
        var r = Build();
        _preview.Text = r == null ? "" : r.Any ? r.Summary + $"\n{r.Patches.Count} byte(s) would change." : r.Summary;
    }

    ScaleReport? Build()
    {
        try
        {
            return Rescale.MapSensorRange(_host.Defs(), _host.RomCopy(), Maps(),
                                          Form.V(_oldMin), Form.V(_oldMax), Form.V(_newMin), Form.V(_newMax));
        }
        catch (Exception ex) { return ScaleReport.Nothing("cannot work that out: " + ex.Message); }
    }

    void Apply()
    {
        var r = Build();
        if (r == null || !r.Any) { _preview.Text = r?.Summary ?? "nothing to do"; return; }
        try
        {
            int n = _host.ApplyPatches(r.Patches, $"MAP sensor {Form.V(_oldMax):0} -> {Form.V(_newMax):0} mBar");
            Applied = true;
            AppLog.Action("calibration", "MAP sensor: " + r.Summary);
            // the calibration now belongs to the sensor that was fitted
            _filling = true;
            _oldPick.SelectedIndex = _newPick.SelectedIndex;
            _oldMin.Value = _newMin.Value; _oldMax.Value = _newMax.Value;
            _filling = false;
            _preview.Text = r.Summary + $"\n{n} byte(s) written - Undo puts them back.";
        }
        catch (Exception ex) { _preview.Text = "could not apply: " + ex.Message; AppLog.Error("calibration", "MAP sensor failed", ex); }
    }
}

// ---------------------------------------------------------------- AFR correction

/// The AFR correction a datalog asks for over the cells selected, worked out the way the established tuning software does it. It looks at the logged AFR in every selected cell that has enough samples, averages how far those cells are from target, and offers the percentage that closes the gap - multiplied by a gain, and held between a smallest and a largest change so one pass never does anything wild. A correction can be one figure for the whole selection (the way the software's own grid adjustment offers it) or worked out cell by cell.
public sealed class AfrFixWindow : Window
{
    /// What Apply should do: which cells, and the percentage each one moves by.
    public sealed record Fix(IReadOnlyList<int> Cells, Func<int, double> PerCell, string What)
    {
        public double Percent(int index) => PerCell(index);
    }

    public Fix? Result { get; private set; }

    readonly TextBlock _summary = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11.5, FontFamily = MainWindow.MonoFont };
    readonly TextBlock _preview = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.9, MinHeight = 48 };
    readonly NumericUpDown _target, _gain, _minChange, _maxChange, _minSamples, _coverage;
    readonly RadioButton _whole = new() { Content = "one change for the whole selection", IsChecked = true };
    readonly RadioButton _perCell = new() { Content = "each cell by its own reading" };
    readonly CheckBox _useTargets = new() { Content = "use the AFR target table (Settings > Targets) where it has one", IsChecked = true };

    readonly IReadOnlyList<int> _cells;
    readonly double[] _measured;
    readonly int[] _counts;
    readonly double[]? _targets;

    public AfrFixWindow(string mapName, string channel, IReadOnlyList<int> cells, double[] measured, int[] counts,
                        TargetMap? low, TargetMap? high, DefinitionSet defs, byte[] rom, ItemDef item, bool highCam)
    {
        _cells = cells; _measured = measured; _counts = counts;
        Title = "AFR fix";
        Width = 720; Height = 580; MinWidth = 560; MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var map = highCam ? (high?.Any == true ? high : low) : low;
        try { _targets = map is { Any: true } m ? m.ForTable(defs, rom, item, 14.7) : null; }
        catch { _targets = null; }

        _target = Form.Num(14.7, 5, 30, 0.1, "0.0#");
        _gain = Form.Num(100, 5, 200, 5, "0");
        _minChange = Form.Num(1, 0, 20, 0.5, "0.0#");
        _maxChange = Form.Num(15, 1, 100, 1, "0");
        _minSamples = Form.Num(3, 1, 500, 1, "0");
        _coverage = Form.Num(50, 0, 100, 5, "0");
        foreach (var n in new[] { _target, _gain, _minChange, _maxChange, _minSamples, _coverage })
            n.ValueChanged += (_, _) => Preview();
        _whole.IsCheckedChanged += (_, _) => Preview();
        _useTargets.IsCheckedChanged += (_, _) => Preview();
        _useTargets.IsEnabled = _targets != null;
        if (_targets == null) _useTargets.IsChecked = false;

        var page = Form.Page();
        page.Children.Add(Form.Note(
            $"{cells.Count} cell(s) of {mapName} are selected, with '{channel}' logged over them. " +
            "The correction is how far those cells ran from target, turned into the fuel they are short of (or over on): leaner than target means " +
            "more fuel, in proportion. The gain decides how much of the gap one pass closes, and the smallest and largest change keep it sane."));
        page.Children.Add(Form.Group("Target",
            Form.Row("Target AFR", _target, "AFR", _targets == null ? "no target table set up" : "used where the table has no value",
                     "The AFR you want these cells to run."),
            _useTargets));
        page.Children.Add(Form.Group("Correction",
            Form.Row("Gain", _gain, "%", "100 goes straight to target, less creeps up on it"),
            Form.Row("Smallest change", _minChange, "%", "a correction under this is not worth making"),
            Form.Row("Largest change", _maxChange, "%", "no cell moves further than this in one pass"),
            Form.Row("Minimum samples", _minSamples, "", "a cell with fewer logged samples is left alone"),
            Form.Row("Cells needed", _coverage, "%", "of the selection, before one figure is offered for all of it"),
            _whole, _perCell));
        page.Children.Add(_summary);

        Content = Form.Shell(this, "AFR fix", page, _preview, Apply);
        Preview();
    }

    double TargetFor(int index) =>
        _useTargets.IsChecked == true && _targets != null && index < _targets.Length && !double.IsNaN(_targets[index])
            ? _targets[index] : Form.V(_target);

    /// The cells with enough samples, and how far each is from its target as a percentage of fuel.
    List<(int Index, double Measured, double Want, double Error)> Usable()
    {
        var list = new List<(int, double, double, double)>();
        for (int k = 0; k < _cells.Count; k++)
        {
            int i = _cells[k];
            double v = k < _measured.Length ? _measured[k] : double.NaN;
            int n = k < _counts.Length ? _counts[k] : 0;
            if (double.IsNaN(v) || n < (int)Form.V(_minSamples)) continue;
            double want = TargetFor(i);
            if (want <= 0) continue;
            // leaner than target (measured AFR above it) means the cell is short of fuel
            list.Add((i, v, want, ((v / want) - 1) * 100));
        }
        return list;
    }

    double Clamp(double pct)
    {
        double g = pct * Form.V(_gain) / 100;
        double max = Form.V(_maxChange);
        if (Math.Abs(g) < Form.V(_minChange)) return 0;
        return Math.Clamp(g, -max, max);
    }

    void Preview()
    {
        var usable = Usable();
        if (usable.Count == 0)
        {
            _summary.Text = "";
            _preview.Text = $"none of the {_cells.Count} selected cell(s) has {Form.V(_minSamples):0} or more logged samples";
            return;
        }
        double avgMeasured = usable.Average(u => u.Measured), avgWant = usable.Average(u => u.Want);
        double avgError = usable.Average(u => u.Error);
        double whole = Clamp(avgError);
        double cover = usable.Count * 100.0 / Math.Max(1, _cells.Count);
        _summary.Text =
            $"measured {avgMeasured:0.00} AFR against a target of {avgWant:0.00}\n" +
            $"{usable.Count} of {_cells.Count} cell(s) have enough samples ({cover:0}% of the selection)\n" +
            $"average error {avgError:+0.0;-0.0}%   suggested change {whole:+0.0;-0.0}%";
        if (_whole.IsChecked == true)
        {
            _preview.Text = cover < Form.V(_coverage)
                ? $"only {cover:0}% of the selection has enough samples ({Form.V(_coverage):0}% is asked for): log more, lower the bar, or correct cell by cell"
                : whole == 0
                    ? $"the average error is {avgError:+0.0;-0.0}%, under the smallest change of {Form.V(_minChange):0.##}%: nothing to do"
                    : $"every selected cell would move {whole:+0.0;-0.0}%";
        }
        else
        {
            var moving = usable.Count(u => Clamp(u.Error) != 0);
            _preview.Text = moving == 0
                ? "no cell is far enough from target to be worth changing"
                : $"{moving} cell(s) would move, between {usable.Select(u => Clamp(u.Error)).Where(p => p != 0).Min():+0.0;-0.0}% " +
                  $"and {usable.Select(u => Clamp(u.Error)).Where(p => p != 0).Max():+0.0;-0.0}%";
        }
    }

    void Apply()
    {
        var usable = Usable();
        if (usable.Count == 0) { Preview(); return; }
        if (_whole.IsChecked == true)
        {
            double cover = usable.Count * 100.0 / Math.Max(1, _cells.Count);
            if (cover < Form.V(_coverage)) { Preview(); return; }
            double pct = Clamp(usable.Average(u => u.Error));
            if (pct == 0) { Preview(); return; }
            // one figure for every cell that was selected, samples or not: that is what the established software's grid adjustment does once the selection has earned it
            Result = new Fix(_cells, _ => pct, $"AFR fix {pct:+0.0;-0.0}% over the selection");
        }
        else
        {
            var per = usable.ToDictionary(u => u.Index, u => Clamp(u.Error));
            var moving = per.Where(kv => kv.Value != 0).ToDictionary(kv => kv.Key, kv => kv.Value);
            if (moving.Count == 0) { Preview(); return; }
            Result = new Fix([.. moving.Keys], i => moving[i], $"AFR fix cell by cell ({moving.Count} cells)");
        }
        Close();
    }
}
