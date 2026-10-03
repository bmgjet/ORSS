// Copyright (c) bmgjet. All rights reserved.
using System.Text.RegularExpressions;

namespace OkiRomSim.Calibration;

/// The values a setting can sensibly be given, in its own units, from what the ECU and the engine it runs can do - so a typo (12000 for 1200, 90 degrees of advance, 250 % duty) is capped instead of written. A definition's own min / max narrow these further. Every write goes through RomData.Write, so tables, pages, the MCP server and the command line are all held to them.
public static partial class SaneLimits
{
    /// The highest rpm any setting may name: a crank period of 150 timer counts, the shortest the shipped ROMs use for a real limit (an engine on these ECUs is built for 8,000-10,000; a period word under that is a switch-off marker, which the editors keep showing as it is but never write).
    public const double MaxRpm = 12500;

    public static (double Lo, double Hi)? For(ItemDef item, FormulaDef f)
    {
        string unit = f.Unit.Trim().ToLowerInvariant(), name = f.Name.ToLowerInvariant();
        string about = (item.Name + " " + item.Description).ToLowerInvariant();

        // a setting that picks one of a list ("0 = fuel cut, 1 = ignition cut, 2 = both"): no further than the list goes
        if (!item.IsTable && item.Type is CellType.U8 && (item.Formula is null or "raw" or "x") && Choices(item.Description) is int most)
            return (0, most);

        switch (name)
        {
            case "rpm_period_word": return (0, MaxRpm);
            case "ign_advance": return (-6, 50);                 // past 50 degrees before TDC is misfire, not timing
            case "p13_advance": return (-6, 50);
            case "duty_half_pct": return (0, 100);
            // (no limit on tps_pct, ign_trim or the MAP scalings: their raw range is already the real one, and shipped ROMs keep axis and marker values past 0-100 %, +-20 deg and 0 mbar)
            case "volts_5v_byte" or "volts_5v_word" or "p13_volts": return (0, 5);   // the A/D reads 0-5 V
        }
        if (unit == "rpm" && item.Type is CellType.U16 or CellType.S16) return (0, MaxRpm);
        if (unit == "afr") return (5, 30);                        // what a wideband reports at either end
        if (unit == "%" && (name.Contains("duty") || about.Contains("duty"))) return (0, 100);
        if (unit is "cc" or "cc/min") return (50, 3000);          // injector flow
        if (unit is "deg" or "deg btdc" && (about.Contains("retard") || about.Contains("timing") || about.Contains("advance"))) return (-20, 50);
        return null;
    }

    /// The highest number a description's list of choices names ("0 none, 1 P0.0 (A/C clutch), ... 9 P0.0 held off", "4-11 serial input 1-8"), when it has one that starts at 0.
    public static int? Choices(string description)
    {
        if (ChoiceNames(description) is { } names) return names.Length - 1;
        var nums = ChoiceRx().Matches(description).Select(m => int.Parse(m.Groups[1].Value)).Distinct().ToList();
        return nums.Count >= 2 && nums.Contains(0) ? nums.Max() : null;
    }

    /// A description's list of choices by number, when it has one from 0 with no gaps: "...: 0 O2 (D14), 1 ELD (D10), 2 EGR (D12), 3 B6, 4-11 serial input 1-8 (...)." gives "O2 (D14)" ... "Serial input 8". A range names its entries with a range of the same length ("serial input 1-8"), or the one name for all of them.
    public static string[]? ChoiceNames(string description)
    {
        var found = new SortedDictionary<int, string>();
        foreach (Match m in ChoiceListRx().Matches(description))
        {
            int a = int.Parse(m.Groups[1].Value), b = m.Groups[2].Success ? int.Parse(m.Groups[2].Value) : a;
            string name = m.Groups[3].Value.Trim();
            if (b < a || b - a > 64) return null;
            var r = NameRangeRx().Match(name);
            int ra = r.Success ? int.Parse(r.Groups[2].Value) : 0, rb = r.Success ? int.Parse(r.Groups[3].Value) : -1;
            for (int n = a; n <= b; n++)
            {
                string text = a == b ? name
                            : r.Success && rb - ra == b - a ? r.Groups[1].Value + (ra + n - a) + (r.Groups[4].Value.TrimStart().StartsWith('(') ? "" : r.Groups[4].Value)
                            : name;
                found.TryAdd(n, text);
            }
        }
        if (found.Count < 2 || found.Keys.First() != 0 || found.Keys.Last() != found.Count - 1) return null;
        return [.. found.Values.Select(v => v.Length > 0 ? char.ToUpperInvariant(v[0]) + v[1..] : v)];
    }

    [GeneratedRegex(@"(?:^|[:,;]\s*)(\d{1,2})\s*=?\s+[A-Za-z(]")]
    private static partial Regex ChoiceRx();

    // "0 O2 (D14)", "4-11 serial input 1-8 (sent ...)", "1 = ignition cut": up to the next ", <number>", a full stop at the end, or the end
    [GeneratedRegex(@"(?:^|:\s*|[,;]\s+)(\d{1,2})(?:-(\d{1,2}))?\s*=?\s+((?:[A-Za-z(][^,;]*?(?:\([^)]*\))?)+?)\s*(?=,\s*\d|;\s*\d|\.\s*$|\.\s+[A-Z]|$)")]
    private static partial Regex ChoiceListRx();

    // "serial input 1-8 (sent over ...)": the words, the range, what follows
    [GeneratedRegex(@"^(.*?)(\d+)-(\d+)(.*)$")]
    private static partial Regex NameRangeRx();
}
