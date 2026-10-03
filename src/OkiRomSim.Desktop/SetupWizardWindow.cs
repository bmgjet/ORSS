// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// File > Set-up wizard: a ROM set up stage by stage, the way the established tuning software sets up a new base ROM - the engine and the stock maps to start from, the injectors, the sensors and the gearbox, boost, and the options - each page offering the presets it has (the stock ECUs, injector lag curves, MAP sensors, gearboxes). Nothing is written until Apply on the last page, which lists everything that will change; then it all lands as one undo step. Works on an HTS 1.15 / HTS120 ROM and on one built from the skeleton: a setting the ROM does not have is greyed out, and the summary says what could not be done.
public sealed class SetupWizardWindow : Window
{
    readonly SimHost _host;
    readonly PresetLibrary? _lib;
    readonly string? _htsTemplate;
    readonly DefinitionSet _defs;
    readonly byte[] _rom;
    public string? Result { get; private set; }

    readonly List<(string Title, string Blurb, Control Body)> _pages = [];
    int _page;
    readonly ContentControl _host2 = new();
    readonly TextBlock _title = new() { FontSize = 16, FontWeight = FontWeight.SemiBold };
    readonly TextBlock _blurb = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.85, Margin = new Thickness(0, 2, 0, 8) };
    readonly TextBlock _steps = new() { FontSize = 11.5, Opacity = 0.75 };
    readonly Button _back = new() { Content = "Back", MinWidth = 90 };
    readonly Button _next = new() { Content = "Next", MinWidth = 90, IsDefault = true };

    // engine
    readonly RadioButton _keepMaps = new() { Content = "Keep this ROM's own maps", GroupName = "maps", IsChecked = true };
    readonly RadioButton _stockMaps = new() { Content = "Start from the maps of a stock ECU:", GroupName = "maps" };
    readonly ListBox _ecus = new() { Height = 190 };
    readonly CheckBox _vtec = new() { Content = "The engine has VTEC" };
    readonly NumericUpDown _vtecRpm = Form.Num(5500, 2000, 9500, 50, "0");
    readonly CheckBox _setLimit = new() { Content = "Set the rev limit" };
    readonly NumericUpDown _limit = Form.Num(7400, 3000, 11000, 50, "0");
    // injectors
    readonly NumericUpDown _stockCc = Form.Num(240, 50, 3000, 10, "0"), _fittedCc = Form.Num(240, 50, 3000, 10, "0");
    readonly TextBlock _mult = new() { FontFamily = MainWindow.MonoFont, VerticalAlignment = VerticalAlignment.Center, FontWeight = FontWeight.Bold };
    readonly ComboBox _lag = new() { Width = 300 };
    List<InjectorPreset> _lags = [];
    readonly NumericUpDown _overall = Form.Num(0, -50, 50, 0.5, "0.0"), _crank = Form.Num(0, -50, 50, 0.5, "0.0"),
                           _post = Form.Num(0, -50, 50, 0.5, "0.0"), _tip = Form.Num(0, -50, 50, 0.5, "0.0");
    readonly CheckBox _suggest = new() { Content = "Suggest the cranking and tip-in trims for the new injectors", IsChecked = true };
    // sensors
    readonly ComboBox _sensor = new() { Width = 300 };
    readonly TextBlock _sensorNow = new() { VerticalAlignment = VerticalAlignment.Center, FontSize = 12 };
    readonly ComboBox _gearbox = new() { Width = 300 };
    // boost
    readonly RadioButton _na = new() { Content = "Naturally aspirated", GroupName = "boost", IsChecked = true };
    readonly RadioButton _boosted = new() { Content = "Turbo or supercharged", GroupName = "boost" };
    readonly NumericUpDown _psi = Form.Num(8, 1, 40, 0.5, "0.0"), _fuelBar = Form.Num(100, 0, 300, 5, "0"),
                           _retard = Form.Num(1.25, 0, 5, 0.25, "0.00"), _cut = Form.Num(11, 0, 45, 0.5, "0.0");
    readonly CheckBox _cutOn = new() { Content = "Boost cut", IsChecked = true };
    // options
    readonly List<(PageRow Row, CheckBox Box, bool Was)> _switches = [];
    // summary
    readonly TextBlock _summary = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, FontFamily = MainWindow.MonoFont };

    bool _filling;

    public SetupWizardWindow(SimHost host)
    {
        _host = host;
        _defs = host.Defs();
        _rom = host.RomCopy();
        var templates = NewRomWindow.Templates();
        try { if (templates != null) _lib = PresetLibrary.Load(Path.Combine(templates, "Presets")); }
        catch (Exception ex) { AppLog.Error("wizard", "presets could not be read", ex); }
        _htsTemplate = templates == null ? null : Path.Combine(templates, "HTS120.asm");

        Title = "Set-up wizard";
        Width = 760; Height = 640; MinWidth = 600; MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _pages.Add(("1  Engine", "The engine the ROM is for: the stock maps to start from, VTEC and the rev limit. Picking a stock ECU fills in its " +
                    "VTEC point, rev limit and injectors on the pages that follow.", EnginePage()));
        _pages.Add(("2  Injectors and fuel", "The injectors the maps were written for and the ones fitted (every pulse is scaled by the two), their " +
                    "lag against battery voltage, and the fuel trims.", InjectorPage()));
        _pages.Add(("3  Sensors and gearbox", "The MAP sensor fitted (every load breakpoint and pressure setting is moved to the same real pressure " +
                    "on it) and the gearbox, for the gear the ROM works out.", SensorPage()));
        _pages.Add(("4  Boost", "Naturally aspirated, or how much boost: the load columns are spread up to it, fuel added and timing taken " +
                    "out past the air outside, and a boost cut above it.", BoostPage()));
        _pages.Add(("5  Options", "The ROM's own switches, ticked as they are now.", OptionsPage()));
        _pages.Add(("6  Summary", "What Apply will change. Nothing has been written yet; Apply writes it all as one undo step.", SummaryPage()));

        _back.Click += (_, _) => Go(_page - 1);
        _next.Click += (_, _) => { if (_page == _pages.Count - 1) Apply(); else Go(_page + 1); };
        var cancel = new Button { Content = "Cancel", MinWidth = 90, IsCancel = true };
        cancel.Click += (_, _) => Close();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(_back); buttons.Children.Add(_next); buttons.Children.Add(cancel);
        var foot = new DockPanel { Margin = new Thickness(14, 6, 14, 12) };
        DockPanel.SetDock(buttons, Dock.Right); foot.Children.Add(buttons);
        foot.Children.Add(_steps);
        _steps.VerticalAlignment = VerticalAlignment.Center;

        var head = new StackPanel { Margin = new Thickness(14, 10, 14, 0) };
        head.Children.Add(_title); head.Children.Add(_blurb);
        var scroll = new ScrollViewer { Content = _host2, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled, Padding = new Thickness(14, 0) };
        var body = new DockPanel();
        DockPanel.SetDock(head, Dock.Top); body.Children.Add(head);
        DockPanel.SetDock(foot, Dock.Bottom); body.Children.Add(foot);
        body.Children.Add(scroll);
        var chrome = DarkChrome.Apply(this, Title);
        var root = new DockPanel();
        DockPanel.SetDock(chrome, Dock.Top); root.Children.Add(chrome);
        root.Children.Add(body);
        Content = root;
        FillFromRom();
        Go(0);
    }

    /// Open on a page (the layout check uses it).
    internal void ShowPage(int page) => Go(page);

    void Go(int page)
    {
        _page = Math.Clamp(page, 0, _pages.Count - 1);
        var (title, blurb, control) = _pages[_page];
        _title.Text = title; _blurb.Text = blurb;
        _host2.Content = control;
        _back.IsEnabled = _page > 0;
        _next.Content = _page == _pages.Count - 1 ? "Apply" : "Next";
        _steps.Text = string.Join("   ", _pages.Select((p, i) => i == _page ? $"[{p.Title.Split("  ")[0]}]" : p.Title.Split("  ")[0]));
        if (_page == _pages.Count - 1) ShowSummary();
    }

    bool Has(string slot) => CalPage.Bound(_defs, slot) != null;
    double? Read(string slot) { try { return CalPage.Bound(_defs, slot) is { } it ? _host.ReadItem(it)[0].Value : null; } catch { return null; } }

    /// A row greyed out (with why in its tip) when the ROM has nothing for it.
    static Control Row(string label, Control editor, string unit, bool here, string tip, string? note = null)
    {
        var r = Form.Row(label, editor, unit, here ? note : "not in this ROM", tip);
        if (!here) { editor.IsEnabled = false; r.Opacity = 0.55; }
        return r;
    }

    // ------------------------------------------------------------------ pages

    Control EnginePage()
    {
        var p = Form.Page();
        _ecus.ItemsSource = _lib?.BaseMaps.Select(b => $"{b}   ·   {(b.Vtec ? $"VTEC {b.VtecRpm}" : "no VTEC")}, limit {b.RevLimit}, {b.InjectorCc} cc").ToList() ?? [];
        _ecus.IsEnabled = false;
        _stockMaps.IsEnabled = _lib is { BaseMaps.Count: > 0 };
        _stockMaps.IsCheckedChanged += (_, _) => { _ecus.IsEnabled = _stockMaps.IsChecked == true; if (_ecus.IsEnabled && _ecus.SelectedIndex < 0) _ecus.SelectedIndex = 0; };
        _ecus.SelectionChanged += (_, _) => PickEcu();
        ToolTip.SetTip(_stockMaps, "The fuel and ignition maps of a stock ECU, brought into this ROM (onto its own breakpoints on a ROM built from the skeleton). " +
                                   "A good start for an engine swap: the maps of the engine that is in the car.");
        p.Children.Add(Form.Group("Base maps", _keepMaps, _stockMaps, _ecus));
        bool vtecHere = Has("vtec.enable") || Has("vtec.rpm.high") || Has("vtec.stock.load.on");
        _vtec.IsEnabled = vtecHere;
        _vtec.IsCheckedChanged += (_, _) => _vtecRpm.IsEnabled = _vtec.IsChecked == true;
        p.Children.Add(Form.Group("VTEC",
            Row("", _vtec, "", vtecHere, "Untick for a non-VTEC head: the solenoid is never switched on (on a ROM built from the skeleton, with VTEC control built in)."),
            Row("VTEC engages at", _vtecRpm, "rpm", vtecHere,
                "Where VTEC comes in with the throttle open. Cruising (light throttle) it waits a little longer, 300 rpm, so it does not hunt on the motorway.")));
        bool limitHere = Has("revlimit.low.set");
        _setLimit.IsEnabled = limitHere;
        _setLimit.IsCheckedChanged += (_, _) => _limit.IsEnabled = _setLimit.IsChecked == true;
        p.Children.Add(Form.Group("Rev limit",
            Row("", _setLimit, "", limitHere, "The rev limiter's cut point, low and high cam alike; it lets go 70 rpm under it."),
            Row("Rev limit", _limit, "rpm", limitHere, "Where the limiter cuts.")));
        return p;
    }

    Control InjectorPage()
    {
        var p = Form.Page();
        foreach (var n in new[] { _stockCc, _fittedCc }) n.ValueChanged += (_, _) => Suggest();
        _suggest.IsCheckedChanged += (_, _) => Suggest();
        bool scaleHere = Has("injector.fitted") || Has("injector.multiplier") || _defs.Items.Any(i => i.Formula == "honda_fuel");
        // your own injectors (Injector calibration > Save as my own) first, then the presets
        _lags = InjectorWindow.AllLags(out var mine);
        var lags = new List<string> { "Leave the lag table as it is" };
        lags.AddRange(_lags.Select((l, i) => (i < mine.Count ? "★ " : "") + l.Name));
        _lag.ItemsSource = lags; _lag.SelectedIndex = 0;
        p.Children.Add(Form.Group("Injectors",
            Row("Injectors the maps were written for", _stockCc, "cc", scaleHere, "The size the fuel maps were tuned on (240 cc on most stock ECUs; filled in from the stock ECU picked on page 1)."),
            Row("Injectors fitted", _fittedCc, "cc", scaleHere, "The size in the engine now. Bigger injectors get a shorter pulse for the same air."),
            Row("Multiplier", _mult, "", scaleHere, "Stock divided by fitted: what every pulse is scaled by."),
            Row("Lag (dead time)", _lag, "", Has("injector.lag"), "The injector's opening time against battery voltage, for the injector picked.")));
        p.Children.Add(Form.Group("Fuel trims",
            Row("Overall fuel", _overall, "%", Has("injector.overall") || Has("injector.trim"), "A trim on all the fuel the maps ask for."),
            Row("Cranking", _crank, "%", Has("injector.crank"), "Extra (or less) fuel while the starter turns."),
            Row("Post start", _post, "%", Has("injector.postfuel"), "Extra fuel for the first moments after it fires."),
            Row("Tip-in", _tip, "%", Has("injector.tipin"), "Extra fuel when the throttle opens quickly."),
            _suggest));
        return p;
    }

    Control SensorPage()
    {
        var p = Form.Page();
        var names = new List<string> { "Leave the sensor as it is" };
        names.AddRange(MapSensorWindow.Sensors.Select(s => $"{s.Name}  ({s.Min} .. {s.Max} mBar)"));
        _sensor.ItemsSource = names; _sensor.SelectedIndex = 0;
        var boxes = new List<string> { "Leave the gearbox as it is" };
        boxes.AddRange(_lib?.Gearboxes.Select(g => g.Name) ?? []);
        _gearbox.ItemsSource = boxes; _gearbox.SelectedIndex = 0;
        bool gearHere = Has("transmission.ratio") || Has("transmission.bounds");
        p.Children.Add(Form.Group("MAP sensor",
            Form.Row("Set up for now", _sensorNow, "", null, "What the ROM says its load breakpoints were written for."),
            Row("Sensor fitted", _sensor, "", _defs.Items.Any(i => i.IsTable && MapSensorScale.IsLoadAxis(_defs, i.ColAxis)),
                "Every load breakpoint and every pressure setting moves to the count that means the same pressure on this sensor, and the ROM is told which sensor it is.")));
        p.Children.Add(Form.Group("Gearbox",
            Row("Gearbox", _gearbox, "", gearHere, "The boundaries between gears the ROM works the gear out from (rpm against road speed); needs gear detection on a ROM built from the skeleton.")));
        return p;
    }

    Control BoostPage()
    {
        var p = Form.Page();
        bool cutHere = Has("boostcut.hot");
        void Enable() { foreach (var c in new Control[] { _psi, _fuelBar, _retard, _cutOn }) c.IsEnabled = _boosted.IsChecked == true; _cut.IsEnabled = _boosted.IsChecked == true && _cutOn.IsChecked == true && cutHere; _cutOn.IsEnabled &= cutHere; }
        _boosted.IsCheckedChanged += (_, _) => Enable();
        _cutOn.IsCheckedChanged += (_, _) => Enable();
        _psi.ValueChanged += (_, _) => { if (!_filling) _cut.Value = (decimal)Math.Round(Form.V(_psi) + 3, 1); };
        p.Children.Add(Form.Group("Induction", _na, _boosted));
        p.Children.Add(Form.Group("Boost",
            Form.Row("Most boost", _psi, "psi", null, "The load columns of the fuel and ignition maps are spread up to this (fit a MAP sensor that reads it on page 3)."),
            Form.Row("Fuel added for each bar", _fuelBar, "%", null, "Past the air outside, each column's fuel is the last one below it, plus this for every bar of boost (100 % follows the air)."),
            Form.Row("Timing taken out for each psi", _retard, "deg", null, "Past the air outside, the timing of the last column below it, less this for every psi."),
            Row("", _cutOn, "", cutHere, "Cut fuel and spark above the pressure below: protection against a stuck wastegate (needs Boost cut on a ROM built from the skeleton)."),
            Row("Boost cut at", _cut, "psi", cutHere, "3 psi over the most boost is a usual start.")));
        Enable();
        return p;
    }

    Control OptionsPage()
    {
        var p = Form.Page();
        var page = CalPage.All().FirstOrDefault(x => x.Key == "romoptions");
        var rows = page?.Groups.SelectMany(g => g.Rows).Where(r => r.Kind == RowKind.Switch && Has(r.Slot)).ToList() ?? [];
        if (rows.Count == 0) { p.Children.Add(Form.Note("This ROM has no switches on its ROM options page.")); return p; }
        var list = new StackPanel { Spacing = 1 };
        foreach (var r in rows)
        {
            bool on = (Read(r.Slot) ?? 0) != 0;
            if (CalPage.Bound(_defs, r.Slot) is { Flag: true } it) on = Math.Abs((_host.ReadItem(it)[0].Raw) - it.OffRaw) > 0.5;
            if (r.Inverted) on = !on;
            var box = new CheckBox { Content = r.Label, IsChecked = on, FontSize = 12.5 };
            if (r.Tip.Length > 0) ToolTip.SetTip(box, r.Tip);
            _switches.Add((r, box, on));
            list.Children.Add(box);
        }
        p.Children.Add(Form.Group(page!.Name, list));
        return p;
    }

    Control SummaryPage()
    {
        var p = Form.Page();
        p.Children.Add(_summary);
        return p;
    }

    // ------------------------------------------------------------------ what the ROM has now

    void FillFromRom()
    {
        _filling = true;
        if (Read("vtec.enable") is double ve) _vtec.IsChecked = ve != 0; else _vtec.IsChecked = Has("vtec.rpm.high") || Has("vtec.stock.load.on");
        if (Read("vtec.rpm.high") is double vr && vr > 1000) _vtecRpm.Value = (decimal)Math.Round(vr / 50) * 50;
        else if (Read("vtec.stock.load.on") is double vs && vs > 1000) _vtecRpm.Value = (decimal)Math.Round(vs / 50) * 50;
        _vtecRpm.IsEnabled = _vtec.IsChecked == true;
        if (Read("revlimit.low.set") is double rl && rl > 1000) _limit.Value = (decimal)Math.Round(rl / 50) * 50;
        _limit.IsEnabled = false;
        if (Read("injector.stock") is double sc && sc > 0) _stockCc.Value = (decimal)sc;
        if (Read("injector.fitted") is double fc && fc > 0) _fittedCc.Value = (decimal)fc;
        _overall.Value = (decimal)(Read("injector.overall") ?? Read("injector.trim") ?? 0);
        _crank.Value = (decimal)(Read("injector.crank") ?? 0);
        _post.Value = (decimal)(Read("injector.postfuel") ?? 0);
        _tip.Value = (decimal)(Read("injector.tipin") ?? 0);
        var s = MapSensorScale.Of(_defs, _rom) ?? MapSensorScale.Stock;
        int at = Array.FindIndex(MapSensorWindow.Sensors, x => Math.Abs(x.Min - s.Zero) < 1 && Math.Abs(x.Max - s.Full) < 1);
        bool stock = Math.Abs(s.Zero - MapSensorScale.Stock.Zero) < 2 && Math.Abs(s.Full - MapSensorScale.Stock.Full) < 2;
        _sensorNow.Text = stock || at == 0 ? "the stock sensor" : at > 0 ? MapSensorWindow.Sensors[at].Name : $"{s.Zero:0} .. {s.Full:0} mBar";
        _suggest.IsChecked = false;
        _filling = false;
        UpdateMultiplier();
    }

    void PickEcu()
    {
        if (_lib == null || _ecus.SelectedIndex < 0 || _ecus.SelectedIndex >= _lib.BaseMaps.Count) return;
        var b = _lib.BaseMaps[_ecus.SelectedIndex];
        _filling = true;
        _vtec.IsChecked = b.Vtec;
        _vtecRpm.Value = b.VtecRpm;
        _setLimit.IsChecked = Has("revlimit.low.set");
        _limit.Value = b.RevLimit;
        _stockCc.Value = b.InjectorCc;
        _overall.Value = b.FuelTrimPct;
        _filling = false;
        UpdateMultiplier();
    }

    void Suggest()
    {
        UpdateMultiplier();
        if (_filling || _suggest.IsChecked != true) return;
        // as the established software works it out: bigger injectors, a leaner start and tip-in by the same share
        double trim = Math.Round((1 - Form.V(_stockCc) / Math.Max(1, Form.V(_fittedCc))) * 100);
        _crank.Value = (decimal)Math.Clamp(-trim, -50, 50);
        _tip.Value = (decimal)Math.Clamp(-trim, -50, 50);
    }

    void UpdateMultiplier() => _mult.Text = (Form.V(_stockCc) / Math.Max(1, Form.V(_fittedCc))).ToString("0.000", CultureInfo.InvariantCulture);

    // ------------------------------------------------------------------ the plan

    SetupChoices Choices()
    {
        var c = new SetupChoices();
        if (_stockMaps.IsChecked == true && _lib != null && _ecus.SelectedIndex >= 0) c.BaseMap = _lib.BaseMaps[_ecus.SelectedIndex];
        bool vtecWas = Read("vtec.enable") is double ve ? ve != 0 : true;
        double? vtecRpmWas = Read("vtec.rpm.high") ?? Read("vtec.stock.load.on");
        if (_vtec.IsEnabled && (_vtec.IsChecked != vtecWas || (_vtec.IsChecked == true && (vtecRpmWas == null || Math.Abs(vtecRpmWas.Value - Form.V(_vtecRpm)) > 40) ) || c.BaseMap != null))
        {
            c.Vtec = _vtec.IsChecked == true;
            c.VtecRpm = Form.V(_vtecRpm);
        }
        if (_setLimit.IsChecked == true) c.RevLimit = Form.V(_limit);
        double sc = Form.V(_stockCc), fc = Form.V(_fittedCc);
        double? stockWas = Read("injector.stock"), fittedWas = Read("injector.fitted");
        if (Math.Abs(sc - fc) > 0.5 || (stockWas is double a && Math.Abs(a - sc) > 0.5) || (fittedWas is double b && Math.Abs(b - fc) > 0.5)) { c.StockCc = sc; c.FittedCc = fc; }
        if (_lag.SelectedIndex > 0 && _lag.SelectedIndex - 1 < _lags.Count) c.Lag = _lags[_lag.SelectedIndex - 1];
        double? Changed(NumericUpDown n, params string[] slots)
        {
            double was = slots.Select(Read).FirstOrDefault(v => v != null) ?? 0;
            return Math.Abs(Form.V(n) - was) > 0.04 ? Form.V(n) : null;
        }
        c.OverallTrim = Changed(_overall, "injector.overall", "injector.trim");
        if (c.OverallTrim != null && c.StockCc == null) { c.StockCc = sc; c.FittedCc = fc; }
        c.CrankTrim = Changed(_crank, "injector.crank");
        c.PostStartTrim = Changed(_post, "injector.postfuel");
        c.TipInTrim = Changed(_tip, "injector.tipin");
        if (_sensor.SelectedIndex > 0) { var s = MapSensorWindow.Sensors[_sensor.SelectedIndex - 1]; c.NewSensor = (s.Min, s.Max); }
        if (_gearbox.SelectedIndex > 0) c.Gearbox = _gearbox.SelectedIndex - 1;
        if (_boosted.IsChecked == true)
        {
            c.BoostPsi = Form.V(_psi);
            c.BoostFuelPerBar = Form.V(_fuelBar);
            c.BoostRetardPerPsi = Form.V(_retard);
            c.BoostCutPsi = _cutOn.IsChecked == true && _cutOn.IsEnabled ? Form.V(_cut) : 0;
        }
        foreach (var (row, box, was) in _switches)
            if ((box.IsChecked == true) != was) c.Switches[row.Slot] = row.Inverted ? box.IsChecked != true : box.IsChecked == true;
        return c;
    }

    SetupPlanner.Plan? _plan;

    void ShowSummary()
    {
        try
        {
            _plan = SetupPlanner.Make(_host.Defs(), _host.RomCopy(), Choices(), _lib, _htsTemplate);
            int bytes = MapImport.Diff(_host.RomCopy(), _plan.Image).Count;
            var lines = new List<string>();
            lines.AddRange(_plan.Done.Select(d => "✔  " + d));
            lines.AddRange(_plan.NotHere.Select(d => "–  " + d));
            _summary.Text = lines.Count == 0 ? "Nothing to change: every page is as the ROM has it now." : string.Join("\n", lines) + $"\n\n{bytes} byte(s) will change.";
            _next.IsEnabled = bytes > 0;
        }
        catch (Exception ex) { _summary.Text = "Could not work that out: " + ex.Message; _next.IsEnabled = false; AppLog.Error("wizard", "plan failed", ex); }
    }

    void Apply()
    {
        if (_plan == null) return;
        try
        {
            var patches = MapImport.Diff(_host.RomCopy(), _plan.Image);
            int n = _host.ApplyPatches(patches, "set-up wizard");
            _host.RefreshMapSensor();
            AppLog.Action("wizard", "set-up wizard: " + string.Join("; ", _plan.Done) + (_plan.NotHere.Count > 0 ? " | not done: " + string.Join("; ", _plan.NotHere) : ""));
            Result = $"set-up wizard: {n} byte(s) written ({_plan.Done.Count} step(s)) - Undo puts them back";
            Close();
        }
        catch (Exception ex) { _summary.Text = "Could not apply: " + ex.Message; AppLog.Error("wizard", "apply failed", ex); }
    }
}
