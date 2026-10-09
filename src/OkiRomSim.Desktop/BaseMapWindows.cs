// Copyright (c) bmgjet. All rights reserved.
using Avalonia.Controls;
using Avalonia.Layout;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Scale for boost: a natural-aspiration ROM given boost columns, with fuel and timing written into them (BaseMapScaler.Boost).
public sealed class BoostScaleWindow : Window
{
    readonly SimHost _host;
    readonly NumericUpDown _psi = Form.Num(10, 1, 40, 0.5, "0.#"), _cols = Form.Num(4, 1, 17, 1, "0"), _fuel = Form.Num(110, 50, 200, 5, "0"), _retard = Form.Num(0.75, 0, 4, 0.05, "0.##");
    readonly TextBlock _preview = new() { TextWrapping = Avalonia.Media.TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.9, MinHeight = 48 };
    public bool Applied { get; private set; }

    public BoostScaleWindow(SimHost host)
    {
        _host = host;
        Title = "Scale for boost";
        Width = 760; Height = 620; MinWidth = 560; MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var la = BaseMapScaler.LoadAxis(host.Defs());
        if (la is { } a) _cols.Maximum = Math.Max(1, a.Count - 3);
        if (la is { Count: >= 20 }) _cols.Value = 8;
        var page = Form.Page();
        page.Children.Add(Form.Note(
            "A starting point for a turbo or supercharger conversion, from the maps this ROM has now. The load axis is split: its lower columns keep " +
            "the atmospheric part (the same shape, squeezed into fewer columns, every map resampled so it reads the same at the same load), and the " +
            "top ones go up in even steps to the most boost. In those boost columns each map starts from its value at the last atmospheric column: " +
            "the fuel rises with the pressure, the timing comes out a set amount for every psi. Then tune it on the dyno, from low boost up.\n" +
            "The MAP sensor fitted has to read that much boost: set it first (Tools > MAP sensor size). Set a boost cut too."));
        page.Children.Add(Form.Group("Boost",
            Form.Row("Most boost", _psi, "psi", "the top load column", "The boost the last column stands for (above the air outside). The sensor's range limits it."),
            Form.Row("Boost columns", _cols, "", "of the load columns", "How many of the load columns go above atmospheric pressure. The rest keep the vacuum and part-throttle range.")));
        page.Children.Add(Form.Group("Fuel and timing in boost",
            Form.Row("Fuel follows the pressure", _fuel, "%", "100 % = in step with it",
                "100 %: the fuel rises in step with the absolute pressure - 1 bar of boost is twice the air, so twice the fuel. Above 100 % is richer than that " +
                "(110-120 % is a safe start: boost wants a richer mixture), below it leaner."),
            Form.Row("Timing out per psi", _retard, "deg", "a psi of boost",
                "Taken off the last atmospheric column's timing for every psi of boost. 0.5-1 degree a psi is a usual start on pump fuel.")));
        foreach (var n in new[] { _psi, _cols, _fuel, _retard }) n.ValueChanged += (_, _) => Preview();
        Content = Form.Shell(this, "Scale for boost", page, _preview, Apply);
        Preview();
    }

    BaseMapScaler.BoostPlan Plan() => new(Form.V(_psi), (int)Form.V(_cols), Form.V(_fuel), Form.V(_retard));

    (string Said, List<BytePatch> Patches) Build()
    {
        var rom = _host.RomCopy();
        var work = (byte[])rom.Clone();
        string said;
        try { said = BaseMapScaler.Boost(_host.Defs(), work, Plan()); }
        catch (Exception ex) { return ("cannot work that out: " + ex.Message, []); }
        return (said, MapImport.Diff(rom, work));
    }

    void Preview()
    {
        var (said, patches) = Build();
        _preview.Text = patches.Count == 0 ? said : said + $"\n{patches.Count} byte(s) would change.";
    }

    void Apply()
    {
        var (said, patches) = Build();
        if (patches.Count == 0) { _preview.Text = said; return; }
        int n = _host.ApplyPatches(patches, $"scale for boost: {Form.V(_psi):0.#} psi");
        Applied = true;
        AppLog.Action("calibration", "scale for boost: " + said);
        _preview.Text = said + $"\n{n} byte(s) written - Undo puts them back.";
    }
}

/// Scale for alpha-N: the throttle as the load at wider throttle, MAP below the crossover (BaseMapScaler.AlphaN).
public sealed class AlphaNScaleWindow : Window
{
    readonly SimHost _host;
    readonly NumericUpDown _map = Form.Num(600, 200, 1000, 10, "0"), _tps = Form.Num(20, 0, 95, 1, "0"), _cols = Form.Num(6, 2, 18, 1, "0");
    readonly TextBlock _preview = new() { TextWrapping = Avalonia.Media.TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.9, MinHeight = 48 };
    public bool Applied { get; private set; }

    public AlphaNScaleWindow(SimHost host)
    {
        _host = host;
        Title = "Scale for alpha-N";
        Width = 760; Height = 560; MinWidth = 560; MinHeight = 400;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var la = BaseMapScaler.LoadAxis(host.Defs());
        if (la is { } a) _cols.Maximum = Math.Max(2, a.Count - 2);
        if (la is { Count: >= 20 }) _cols.Value = 12;
        var page = Form.Page();
        page.Children.Add(Form.Note(
            "For individual throttle bodies and big cams, where the MAP barely moves: the throttle becomes the load at wider throttle, with the MAP " +
            "still used below the crossover (idle and light cruise, where it reads well). The load axis is split: its lower columns keep the MAP " +
            "range up to the crossover, the top ones are spread evenly above it, and the throttle table maps the throttle onto them - so each of " +
            "those columns is a throttle position, from the crossover throttle to wide open. The maps are resampled so they start where they were; " +
            "then tune the throttle columns. Needs the ROM built with Maps indexing (alpha-N): File > Change functions."));
        page.Children.Add(Form.Group("Crossover",
            Form.Row("MAP below", _map, "mBar", "MAP as now under this", "Under this manifold pressure (and under the throttle crossover) the maps are read on MAP. 500-700 mBar is usual."),
            Form.Row("Throttle above", _tps, "%", "the throttle from here", "At or over this throttle the throttle is the load. 0 % = always alpha-N.")));
        page.Children.Add(Form.Group("Load columns",
            Form.Row("Throttle columns", _cols, "", "of the load columns", "How many of the top load columns become throttle positions; the rest keep the MAP range.")));
        foreach (var n in new[] { _map, _tps, _cols }) n.ValueChanged += (_, _) => Preview();
        Content = Form.Shell(this, "Scale for alpha-N", page, _preview, Apply);
        Preview();
    }

    (string Said, List<BytePatch> Patches) Build()
    {
        var rom = _host.RomCopy();
        var work = (byte[])rom.Clone();
        string said;
        try { said = BaseMapScaler.AlphaN(_host.Defs(), work, new(Form.V(_map), Form.V(_tps), (int)Form.V(_cols))); }
        catch (Exception ex) { return ("cannot work that out: " + ex.Message, []); }
        return (said, MapImport.Diff(rom, work));
    }

    void Preview()
    {
        var (said, patches) = Build();
        _preview.Text = patches.Count == 0 ? said : said + $"\n{patches.Count} byte(s) would change.";
    }

    void Apply()
    {
        var (said, patches) = Build();
        if (patches.Count == 0) { _preview.Text = said; return; }
        int n = _host.ApplyPatches(patches, "scale for alpha-N");
        Applied = true;
        AppLog.Action("calibration", "scale for alpha-N: " + said);
        _preview.Text = said + $"\n{n} byte(s) written - Undo puts them back.";
    }
}
