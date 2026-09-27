// Copyright (c) bmgjet. All rights reserved.
using System.Text.RegularExpressions;

namespace OkiRomSim.Calibration;

/// Formula names that say what the formula is. A formula written into a ROM source as an expression (";@ ... formula="x * 3.6105 + 114.3"") is named here from what it converts - the map load axis, the MAP sensor byte - rather than from a hash of its text; and definitions saved under the old names (the hts_ scalings, the inline_ hashes) are read under the new ones.
public static class FormulaNames
{
    /// The old names of the built-in scalings and the names they have now.
    public static readonly Dictionary<string, string> Legacy = new(StringComparer.OrdinalIgnoreCase)
    {
        ["hts_tps_pct"] = "tps_pct",
        ["hts_trim_word"] = "trim_word_pct",
        ["hts_trim_128"] = "trim_byte_pct",
        ["hts_trim_64"] = "trim_byte_64_pct",
        ["hts_signed_trim"] = "trim_signed_pct",
        ["hts_half_step"] = "half_step_signed",
        ["hts_duty_half"] = "duty_half_pct",
        ["hts_x10_ms"] = "time_10ms",
        ["hts_x01_s"] = "time_tenth_s",
        ["hts_quarter"] = "quarter",
        ["hts_quarter_deg"] = "degrees_quarter",
        ["hts_eighth"] = "eighth",
        ["hts_batt_v"] = "battery_v",
        ["hts_dwell_batt_v"] = "dwell_battery_v",
        ["hts_x16"] = "times_16",
        ["hts_map_mbar"] = "map_sensor_preset_mbar",
        ["hts_map_psi"] = "map_sensor_preset_psi",
    };

    /// Expressions the ROM sources give inline, by what they are.
    static readonly Dictionary<string, string> Known = new(StringComparer.OrdinalIgnoreCase)
    {
        ["x*3.6105+114.3"] = "map_load_axis_mbar",
        ["x*1860/255-70"] = "map_sensor_mbar",
        ["x*1875000/53125"] = "rpm_byte_35",
        ["x/32768"] = "ratio_word",
        ["(x+1)*10"] = "sample_time_10ms",
        ["x*10"] = "times_10",
        ["x*100/32768"] = "percent_word",
        ["x*8"] = "rpm_step_8",
        ["570-x*15"] = "injector_size_cc",
        ["x/100"] = "hundredths",
        ["x/16"] = "sixteenths",
        ["x/1024"] = "fraction_1024",
        ["x/16-1"] = "dwell_base",
        ["-x/4"] = "retard_quarter_deg",
        ["x/128"] = "ratio_byte",
        ["((x*1860/255-70)-1013)*0.0145038"] = "map_sensor_boost_psi",
    };

    static string Norm(string? s) => Regex.Replace(s ?? "", @"\s+", "");

    /// The name for a formula given as an expression: a known one's name, a built-in formula that is the same, or one made from the unit and the expression ("mbar_x3_6105_plus_114_3").
    public static string ForInline(string expr, string? inverse, string? unit)
    {
        var n = Norm(expr);
        if (Known.TryGetValue(n, out var known)) return known;
        var same = Builtin.All.FirstOrDefault(f => Norm(f.Expr) == n && string.Equals(f.Unit ?? "", unit ?? "", StringComparison.OrdinalIgnoreCase));
        if (same != null) return same.Name;
        var slug = n.ToLowerInvariant()
            .Replace("*", "_x").Replace("/", "_per").Replace("+", "_plus").Replace("-", "_minus").Replace("^", "_pow").Replace(".", "_");
        slug = Regex.Replace(slug, @"[^a-z0-9_]", "");
        slug = Regex.Replace(slug, @"(?<![a-z])x_", "", RegexOptions.None, TimeSpan.FromSeconds(1));   // "x_x3" -> "x3": the input itself need not be named
        slug = Regex.Replace(slug, "_+", "_").Trim('_');
        var u = Regex.Replace((unit ?? "").ToLowerInvariant(), @"[^a-z0-9]", "");
        var name = (u.Length > 0 ? u + "_" : "value_") + (slug.Length > 0 ? slug : "x");
        return name.Length > 48 ? name[..48].TrimEnd('_') : name;
    }

    static readonly Regex HashName = new("^inline_[0-9a-f]{8}$", RegexOptions.IgnoreCase);

    /// The formula's name as it is now, for one that was saved under an old name (null: not an old name).
    public static string? Renamed(string? name) => name != null && Legacy.TryGetValue(name, out var n) ? n : null;

    /// Definitions saved under the old names: every formula and every reference to one renamed.
    public static void Normalize(DefinitionSet defs)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in defs.Formulas.ToList())
        {
            string? to = Renamed(f.Name) ?? (HashName.IsMatch(f.Name) && f.Expr is { Length: > 0 } ? ForInline(f.Expr, f.Inverse, f.Unit) : null);
            if (to == null) continue;
            map[f.Name] = to;
            if (defs.Formulas.Any(g => g != f && g.Name.Equals(to, StringComparison.OrdinalIgnoreCase))) defs.Formulas.Remove(f);
            else f.Name = to;
        }
        foreach (var (old, now) in Legacy) map.TryAdd(old, now);
        // a reference to a hash-named formula the set does not hold: the shipped ROM sources know it by its new name
        string? Fix(string? n) => n == null ? null : map.TryGetValue(n, out var to) ? to
            : HashName.IsMatch(n) && DefinitionBuilder.KnownFormula(n) is { } k ? k.Name : n;
        foreach (var i in defs.Items)
        {
            i.Formula = Fix(i.Formula);
            if (i.RowAxis != null) i.RowAxis.Formula = Fix(i.RowAxis.Formula);
            if (i.ColAxis != null) i.ColAxis.Formula = Fix(i.ColAxis.Formula);
        }
    }
}
