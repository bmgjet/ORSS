// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Calibration;

/// The functions' own state, logged (the "every channel" module's channels 132-187: every byte of module RAM). Which function keeps what where is decided when the ROM is built, so the names come from the build open: each variable a function keeps there is a channel of its own, named as in its source (rollidle_drops, tc_trim...), with what it means and, for the ones known here, its value in real units as well (rollidle_injectors: the injectors left out last). Bytes no function uses are not logged.
public static class ModuleDebug
{
    public const int Bytes = 56;
    /// The first module RAM channel number.
    public const int FirstChannel = 132;

    /// A variable of module RAM: its name, where it starts (from the base), how many bytes.
    public sealed record Variable(string Name, int Offset, int Size, string About);

    /// The variables of the build open, by the offset of each of their bytes (null: no build, or no symbols).
    static Variable?[] _byOffset = new Variable?[Bytes];
    public static IReadOnlyList<Variable> Variables { get; private set; } = [];

    /// What each known variable is, from the modules' sources.
    static readonly Dictionary<string, string> About = new(StringComparer.OrdinalIgnoreCase)
    {
        ["MOD_FUELSUM"] = "Every function's fuel trim added up (1/256ths)", ["MOD_FUELMUL"] = "The fuel multiplier the functions apply (8000h = 1.0)",
        ["MOD_IGNSUM"] = "Every function's timing trim added up (0.25° steps, + = advance)", ["MOD_PWMSTEP"] = "P4.3 PWM: the step of its 25-step cycle",
        ["MOD_PWMDUTY"] = "P4.3 PWM: how many of the 25 steps are on", ["MOD_SWSTEP"] = "Software PWM: the step of its 25-step cycle",
        ["MOD_SWDUTY"] = "Software PWM: how many of the 25 steps are on", ["MOD_SWOUT"] = "Software PWM: the output it drives",
        ["accut_timer"] = "A/C cut: time left holding the compressor off", ["antistall_trim"] = "Anti-stall: the idle air it is adding",
        ["antistall_timer"] = "Anti-stall: time since it last acted", ["SERIN_RAM"] = "Serial inputs: the values sent to the ECU (1-8)",
        ["SERIN_AGE"] = "Serial inputs: 32.8 ms slots since one came", ["ebc_rpm"] = "Boost control: the rpm row it is on",
        ["ebc_base"] = "Boost control: the base duty before the gear and switch trims", ["flex_ftrim"] = "Flex fuel: the fuel trim for the ethanol content",
        ["flex_itrim"] = "Flex fuel: the timing trim for the ethanol content", ["flex_eth"] = "Flex fuel: the ethanol content read",
        ["fueltrim_value"] = "Fuel trim: the trim it is giving", ["gearfuel_value"] = "Fuel by gear: the trim for the gear now",
        ["gearign_value"] = "Timing by gear: the trim for the gear now", ["gio1_timer"] = "GIO 1: its on / off delay counting", ["gio2_timer"] = "GIO 2: its on / off delay counting",
        ["gio3_timer"] = "GIO 3: its on / off delay counting", ["gio4_timer"] = "GIO 4: its on / off delay counting",
        ["icm_trimword"] = "Ignition cut modifier: the trim it applies", ["leanpro_count"] = "Lean protection: how long it has seen it lean",
        ["mapsw_ftrim"] = "Map switch: the fuel trim of the second tune", ["mapsw_itrim"] = "Map switch: the timing trim of the second tune",
        ["mapsw_rpm"] = "Map switch: the rpm row it is on", ["rollidle_hold"] = "Rolling idle: time left holding a spark out",
        ["rollidle_last"] = "Rolling idle: the tick of the last spark interrupt", ["rollidle_cyl"] = "Rolling idle: what it left out last (injector bits, E0h a spark)",
        ["rollidle_drops"] = "Rolling idle: how many events it has left out (counts round)", ["smartalt_timer"] = "Smart alternator: its delay counting",
        ["tpsr_trim"] = "Throttle retard: the timing it is taking out", ["tpsr_prev"] = "Throttle retard: the throttle a moment ago",
        ["tpsr_now"] = "Throttle retard: the throttle now", ["tpsr_age"] = "Throttle retard: time since the throttle moved",
        ["tc_trim"] = "Traction control: the timing it is taking out", ["tc_prev"] = "Traction control: the rpm rise before",
        ["tc_now"] = "Traction control: the rpm rise now", ["wbcl_trim"] = "Wideband closed loop: the fuel trim it is giving",
        ["wbcl_afr"] = "Wideband closed loop: the AFR it read",
    };

    static readonly HashSet<string> NotVariables = new(StringComparer.OrdinalIgnoreCase) { "MOD_RAM_BASE", "MOD_RAM_END", "MODRAM_NEXT" };

    /// Take the names from a build's equates (not code labels): every one inside module RAM is a variable, sized up to the next one.
    public static void Name(IEnumerable<(string Name, long Value)>? symbols)
    {
        var map = new Variable?[Bytes];
        var list = new List<Variable>();
        var syms = symbols?.ToList() ?? [];
        var baseSym = syms.FirstOrDefault(s => s.Name.Equals("MOD_RAM_BASE", StringComparison.OrdinalIgnoreCase));
        if (baseSym.Name != null)
        {
            long b = baseSym.Value;
            var inside = syms.Where(s => s.Value >= b && s.Value < b + Bytes && !NotVariables.Contains(s.Name) && (About.ContainsKey(s.Name) || s.Value >= b + 10))
                             .GroupBy(s => s.Value).Select(g => g.OrderByDescending(s => About.ContainsKey(s.Name)).First())
                             .OrderBy(s => s.Value).ToList();
            for (int i = 0; i < inside.Count; i++)
            {
                int off = (int)(inside[i].Value - b);
                int next = i + 1 < inside.Count ? (int)(inside[i + 1].Value - b) : Bytes;
                int size = Math.Clamp(next - off, 1, inside[i].Name.Equals("SERIN_RAM", StringComparison.OrdinalIgnoreCase) ? 8 : 2);
                // lower case: the datalog looks its channels up that way
                var v = new Variable(inside[i].Name.ToLowerInvariant(), off, size, About.GetValueOrDefault(inside[i].Name, "kept by a function"));
                list.Add(v);
                for (int k = 0; k < size && off + k < Bytes; k++) map[off + k] ??= v;
            }
        }
        _byOffset = map;
        Variables = list;
    }

    /// The variable a module RAM byte belongs to, or null.
    public static Variable? At(int offset) => offset >= 0 && offset < Bytes ? _byOffset[offset] : null;

    /// What a logged function-state value is (its variable's description), or null.
    public static string? Describe(string key)
    {
        foreach (var v in Variables)
            if (key == v.Name || key.StartsWith(v.Name + "_", StringComparison.Ordinal)) return v.About;
        return key == "rollidle_injectors" ? "Rolling idle: the injectors it left out last (14 = injectors 1 and 4, 0 = a spark)" : null;
    }

    /// What a module RAM channel shows in the Channels window.
    public static string Label(int offset) => At(offset) is { } v
        ? $"{v.Name}{(v.Size > 1 ? $" byte {offset - v.Offset + 1} of {v.Size}" : "")} - {v.About}"
        : "not used by a function in this build";

    /// One byte of module RAM into the frame: under its variable's name (a word's bytes as _lo and _hi, and the word itself once both have come), and the known ones in real units too.
    public static void Decode(LogFrame f, int offset, byte b)
    {
        // a byte no function in this build uses has nothing to say: not logged
        if (At(offset) is not { } v) return;
        if (v.Size == 1) f.Extra[v.Name] = b;
        else
        {
            int k = offset - v.Offset;
            string part = v.Size == 2 ? (k == 0 ? "_lo" : "_hi") : $"_{k + 1}";
            f.Extra[v.Name + part] = b;
            if (v.Size == 2 && f.Extra.TryGetValue(v.Name + "_lo", out var lo) && f.Extra.TryGetValue(v.Name + "_hi", out var hi))
                f.Extra[v.Name] = (short)((int)lo | ((int)hi << 8));
        }
        if (v.Name.Equals("rollidle_cyl", StringComparison.OrdinalIgnoreCase))
        {
            // P2.0 injector 1, P2.1 injector 3, P2.2 injector 4, P2.3 injector 2: as digits ("14": injectors 1 and 4), 0 a spark
            int[] inj = [1, 3, 4, 2];
            f.Extra["rollidle_injectors"] = b == 0xE0 ? 0 : int.Parse("0" + string.Concat(Enumerable.Range(0, 4).Where(i => (b >> i & 1) != 0).Select(i => inj[i]).Order()));
        }
    }
}
