// Copyright (c) bmgjet. All rights reserved.
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OkiRomSim.Calibration;

/// An injector's dead time (lag) against battery voltage, as the ROM's lag table holds it (slot injector.lag: 7 points, highest voltage first, the lag in the injector timer's 3.2 us counts): read from a ROM, written to one, and the presets - the 138 injectors of Templates/Presets plus your own, kept in a file of their own (injectors.json beside the settings).
public static partial class InjectorLag
{
    /// The ROM's lag table as a preset ("As in the ROM"), or null when this ROM has none bound.
    public static InjectorPreset? Read(DefinitionSet defs, byte[] rom)
    {
        var item = CalPage.Bound(defs, "injector.lag");
        if (item == null || item.Count < 1) return null;
        var cells = RomData.Read(defs, rom, item);
        var ms = cells.Select(c => Math.Round(c.Value, 3)).ToArray();
        var volts = new double[ms.Length];
        if (item.ColAxis?.Address is int ax)
        {
            var f = defs.Formula(item.ColAxis.Formula);
            int step = item.ColAxis.Stride > 0 ? item.ColAxis.Stride : 1;
            for (int i = 0; i < volts.Length; i++) volts[i] = Math.Round(f.ToValue(RomData.ReadRaw(rom, ax + i * step, item.ColAxis.Type)), 2);
        }
        return new InjectorPreset("As in the ROM", volts, ms);
    }

    /// Write a lag curve into the ROM's lag table, and its voltages where the axis is in the ROM. False: no lag table bound.
    public static bool Write(DefinitionSet defs, byte[] rom, InjectorPreset lag)
    {
        var item = CalPage.Bound(defs, "injector.lag");
        if (item == null || item.Count < 1) return false;
        // the points as the preset gives them, highest voltage first like the stock table
        int n = Math.Min(item.Count, lag.LagMs.Length);
        for (int i = 0; i < n; i++) RomData.Write(defs, rom, item, i, lag.LagMs[i]);
        if (item.ColAxis?.Address is int ax)
        {
            var f = defs.Formula(item.ColAxis.Formula);
            int step = item.ColAxis.Stride > 0 ? item.ColAxis.Stride : 1;
            for (int i = 0; i < n; i++)
                if (i < lag.Volts.Length && lag.Volts[i] > 0) RomData.WriteRaw(rom, ax + i * step, item.ColAxis.Type, f.ToRaw(lag.Volts[i], 0, 255));
        }
        return true;
    }

    [GeneratedRegex(@"(\d{2,4})\s*cc", RegexOptions.IgnoreCase)] private static partial Regex Cc();

    /// The injector's size when its name says it ("RC 550cc ..."), else null.
    public static int? SizeCc(string name) => Cc().Match(name) is { Success: true } m && int.TryParse(m.Groups[1].Value, out var cc) && cc is >= 50 and <= 3000 ? cc : null;

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };

    /// Your own lag curves, from the file (none when it is not there or cannot be read).
    public static List<InjectorPreset> LoadUser(string path)
    {
        try { return File.Exists(path) ? JsonSerializer.Deserialize<List<InjectorPreset>>(File.ReadAllText(path), Json) ?? [] : []; }
        catch { return []; }
    }

    public static void SaveUser(string path, IEnumerable<InjectorPreset> presets)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(presets.ToList(), Json));
    }
}
