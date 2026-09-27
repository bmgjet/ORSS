// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Calibration;

/// Pages for the functions the skeleton ROMs' feature modules add, which the established tuning software has no page for, and the per-ROM page list: the pages, the GPO pages in the layout the ROM's own outputs use, and a "More settings" group on any page whose feature keeps settings the page does not list (so every setting a module annotates with a slot is on a page).
public static class ModulePages
{
    static PageRow V(string slot, string label, string unit = "", string tip = "") => new(slot, label, RowKind.Value, unit, tip);
    static PageRow S(string slot, string label, string tip = "") => new(slot, label, RowKind.Switch, "", tip);
    static PageRow C(string slot, string label, string[] options, int[]? values = null, string tip = "") => new(slot, label, RowKind.Choice, "", tip, null, options, values);
    static PageRow MM(string slot, string label, string unit = "", string tip = "") => new(slot, label, RowKind.MinMax, unit, tip);
    static PageRow T(string slot, string label, string unit = "", string tip = "") => new(slot, label, RowKind.Table, unit, tip);
    static PageGroup G(string title, params PageRow[] rows) => new(title, rows);
    static PageGroup Cond(string title, params PageRow[] rows) => new(title, rows, true);
    static PageRow[] Input(string slot, string label, string tip = "") =>
    [
        C(slot, label, CalPage.InputsAlwaysOn, CalPage.InputValuesAlwaysOn, tip),
        S(slot + ".invert", "Invert input", "The input has to be off instead."),
    ];

    /// The outputs a skeleton module can drive (lib.asm mod_output), in raw-value order.
    public static readonly string[] ModOutputs =
    [
        "None", "P0.0 (A/C clutch, A15)", "P0.1 (purge valve, A20)", "P0.4 (A/T lock-up)", "P1.2 (O2 heater, A6)",
        "P1.4 (check engine light, A13)", "P1.5 (ECU LED)", "P0.5 high (alternator control, A16)", "P0.5 low (alternator control, A16)",
        "P0.0 held off (A/C clutch disengaged)",
    ];

    /// A general purpose output as the skeleton's GIO modules lay it out: an rpm switch point with its own off point, windows on the other readings, delays and a flash mode.
    public static CalPage Gio(int n) => new(
        $"gpo{n}", $"General purpose output {n}", "GPO",
        "A spare output the ROM drives while the engine is inside a window of conditions - a water injection pump, a shift light, a second " +
        "fuel pump, an intercooler sprayer. Pick what it drives and what switches it, set the window, and turn it on.",
        [
            G("Input / output settings", [
                C($"gpo{n}.output", "Output", ModOutputs, tip: "Which ECU output this takes over. Whatever it normally does stops happening, so pick one the engine does not need."),
                S($"gpo{n}.output.invert", "Invert output", "Drive the output while the conditions are not met instead."),
                .. Input($"gpo{n}.input", "Input", "A switch that has to agree before the output comes on. Always on: the conditions alone decide.")]),
            G("RPM",
                V($"gpo{n}.rpm.on", "On at or above", "rpm"),
                V($"gpo{n}.rpm.off", "Off again below", "rpm", "Set it a little under the on point so the output does not chatter.")),
            Cond("Conditions",
                MM($"gpo{n}.tps", "TPS", "%"),
                MM($"gpo{n}.map", "MAP", "mBar"),
                MM($"gpo{n}.ect", "ECT", "°C"),
                V($"gpo{n}.iat.min", "IAT", "°C", "Intake air at least this warm."),
                MM($"gpo{n}.speed", "Speed", "km/h"),
                MM($"gpo{n}.gear", "Gear", "", "Needs gear detection; 0 = neutral or not known."),
                V($"gpo{n}.batt.min", "Battery", "V", "Battery at least this.")),
            G("Options",
                S($"gpo{n}.enable", "Enable general purpose output"),
                V($"gpo{n}.delay.on", "On delay", "ms", "The conditions must hold this long before it switches on (flash mode: the time on and off)."),
                V($"gpo{n}.delay.off", "Off delay", "ms", "And stop holding this long before it switches off."),
                S($"gpo{n}.flash", "Flash while on", "On and off, each for the on delay, while the conditions hold: a warning light.")),
        ]);

    public static CalPage RollingIdle() => new("rollidle", "Rolling idle", "Idle",
        "A lumpy, big-cam idle: one injector opening (or one spark) in every few is left out at idle, so a different cylinder misses each " +
        "time round. Only below the rpm and throttle set here, at a standstill and warm.",
        [
            G("Rolling idle", [
                S("rollidle.enable", "Enable rolling idle"),
                C("rollidle.mode", "Leave out", ["An injector opening", "A spark"],
                  tip: "An injector is the gentle way. A spark sends that cylinder's fuel into the exhaust: pops, and heat in the catalyst."),
                V("rollidle.every", "One event in every", "", "2-20. With four cylinders an odd number moves the miss round the cylinders: 5 or 7 rolls, 3 is rough."),
                .. Input("rollidle.input", "Input", "A switch that has to be on as well. Always on: no switch.")]),
            G("Only while",
                V("rollidle.rpm.max", "Below RPM", "rpm"),
                V("rollidle.rpm.min", "Above RPM", "rpm", "It lets go below this, before the engine stalls."),
                V("rollidle.tps", "Below TPS", "%"),
                V("rollidle.speed", "At or below speed", "km/h"),
                V("rollidle.ect", "ECT at least", "°C")),
        ]);

    public static CalPage AntiStall() => new("antistall", "Anti-stall", "Idle",
        "When the rpm drops too low with the engine running: the idle valve opened, timing added, and the A/C and the alternator's load " +
        "taken away until it recovers.",
        [
            G("Anti-stall",
                S("antistall.enable", "Enable anti-stall"),
                V("antistall.rpm", "Acts below RPM", "rpm"),
                V("antistall.recover", "Back to normal above RPM", "rpm"),
                V("antistall.running", "Only with the engine above RPM", "rpm", "So it does nothing while cranking or stopped."),
                V("antistall.hold", "Kept on after recovering for", "ms")),
            G("What it does",
                V("antistall.iacv", "Idle valve duty at least", "", "The stock top of its range is 091Fh."),
                V("antistall.advance", "Timing added", "°"),
                S("antistall.ac", "A/C compressor off", "Needs the stock A/C built in."),
                C("antistall.alt", "Alternator", ["Left alone", "Control line P0.5 high", "Control line P0.5 low"], [0, 7, 8],
                  tip: "The level of the alternator control line that turns charging down on this car.")),
        ]);

    public static CalPage SmartAlternator() => new("smartalt", "Smart alternator", "Outputs",
        "The alternator's load taken off the engine when the power is wanted - hard acceleration - as long as the battery is healthy.",
        [
            G("Smart alternator",
                S("smartalt.enable", "Enable smart alternator"),
                V("smartalt.tps", "TPS at least", "%"),
                V("smartalt.map", "Or MAP at least", "mBar"),
                V("smartalt.rpm", "Above RPM", "rpm"),
                V("smartalt.batt", "Battery at least", "V", "Charging is left alone below this."),
                V("smartalt.hold", "Kept off for at least", "ms"),
                C("smartalt.level", "Control line level", ["P0.5 low", "P0.5 high"], [8, 7], "The level of the alternator control line (A16) that turns charging down.")),
        ]);

    public static CalPage WaterMeth() => new("wmi", "Water / methanol injection", "Boost",
        "A water/methanol pump on a spare output, its duty from a table against manifold pressure.",
        [
            G("Water / methanol",
                S("wmi.enable", "Enable water / methanol injection"),
                C("wmi.output", "Output", ModOutputs),
                V("wmi.rpm", "Above RPM", "rpm"),
                V("wmi.tps", "Above TPS", "%"),
                V("wmi.ect", "ECT at least", "°C"),
                T("wmi.duty", "Pump duty against MAP", "%")),
        ]);

    /// The equipment flags the ECU reads at power-up (from its option bytes or the resistors on its board), named after what the code does with them.
    public static readonly (string Key, string Title, string Flag, string What)[] BoardFlags =
    [
        ("automatictransmission", "Automatic transmission", "216h bit 3", "The A/T shift and lock-up control, the A/T idle, decel-cut, tip-in and knock tables, and the A/T checks (codes 17, 19, 30)."),
        ("knocksensor", "Knock sensor (codes 23, 26)", "216h bit 5", "Reads the knock sensor, sets codes 23 and 26, and has the scheduler run the knock task."),
        ("vtecchecks", "VTEC solenoid and pressure checks (codes 21, 22)", "216h bit 4", "Checks the VTEC solenoid feedback (code 21) and the VTEC pressure switch result."),
        ("vtecpressureswitch", "VTEC pressure switch (code 22)", "227h bit 6", "Reads the VTEC oil-pressure switch (code 22), and gates the knock (code 23) check and the road-speed input."),
        ("barosensor", "Barometric pressure sensor (code 13)", "227h bit 4", "Reads the baro sensor; without it baro is the fixed value F9h."),
        ("egr", "EGR system", "216h bit 7", "The EGR valve control and its maps, and which housekeeping task runs."),
        ("closedloopoff", "Closed loop off", "219h bit 4", "The closed-loop O2 trim is held off."),
        ("speedchecksoff", "Road speed checks off (code 17)", "227h bit 2", "The A/T task and the road speed / A/T input checks (code 17) are skipped."),
        ("geardetect", "Gear detection", "227h bit 3", "Gear detection from rpm and road speed, the A/T lock-up state and the alternator control override."),
        ("altcontrolcheck", "Alternator control check", "216h bit 6", "With 'Knock and O2 on the second inputs': the alternator control (ALTC) check; also a condition of the closed-loop O2 gate."),
        ("secondinputs", "Knock and O2 on the second inputs", "219h bit 1", "Knock read from 3CCh instead of 0C7h, the O2 closed-loop gate on 39Bh, codes 10 and 25, and the alternator control check."),
        ("idlevalvealt", "Second idle valve type", "217h bit 6", "The idle valve PID gains and tables for the other valve type, and the intake air check (code 10) skipped."),
        ("idlealt", "Second idle strategy", "227h bit 1", "The other idle speed and state logic and the idle coolant correction."),
        ("ignmapselect", "Ignition map select", "227h bit 5", "Picks the ignition map of the 2-D lookup, and the knock threshold bank."),
        ("altknockshift", "Second knock levels and shift points", "216h bit 0", "Picks the second half of the knock level table and the other A/T shift-point tables; also part of the model code the diagnostic link reports."),
        ("lowspeedretardcap", "Knock retard cap below 45 km/h", "216h bit 2", "Caps the knock retard below 45 km/h, has the stored fuel values checked against the fault flag, and handles code 13."),
        ("knockwindow", "Knock window open at any rpm", "217h bit 3", "The knock window is open whatever the rpm (otherwise only below a set rpm)."),
        ("knockretardiat", "Knock retard limited by intake air", "227h bit 7", "The knock retard is limited by the intake air temperature."),
        ("unused2161", "Unused flag", "216h bit 1", "Set from its option byte at power-up; nothing in the code reads it."),
    ];

    /// One page per board flag: whether the ECU decides it (option bytes / resistors) or it is forced on or off in software.
    public static IEnumerable<CalPage> BoardOptions() => BoardFlags.Select(f => new CalPage($"boardopt.{f.Key}", f.Title, "Board options",
        $"{f.What} The ECU sets this flag ({f.Flag}) at power-up from its option bytes or the resistors on its board; force it here for a swapped engine or a board with the wrong resistors.",
        [G(f.Title, new PageRow($"boardopt.{f.Key}", "Setting", RowKind.Force, Tip: "Left to the ECU, or forced on or off whatever the option bytes and the resistors say."))]));

    public static CalPage Watermark() => new("watermark", "Watermark", "Options",
        "A short text kept in the ROM, stored scrambled with a check word, so a tune can be told as yours. The engine runs the same whatever it says.",
        [G("Watermark",
            new PageRow("watermark.text", "Watermark (the ROM's password)", RowKind.Text,
                Tip: "Up to 16 characters. OkiRomSim asks for it before it opens this ROM (.bin, source or project). Only a salted hash of it is kept in the ROM."))]);

    /// The trouble codes the ROM can set, and whether each one is stored and lights the check-engine lamp.
    static readonly (int Code, string What)[] Codes =
    [
        (1, "O2 sensor"), (3, "MAP sensor (electrical)"), (4, "Crank position sensor"), (5, "MAP sensor (vacuum)"),
        (6, "Coolant temperature sensor"), (7, "Throttle position sensor"), (8, "TDC sensor"), (9, "Cylinder position sensor"),
        (10, "Intake air temperature sensor"), (11, ""), (12, "EGR system"), (13, "Barometric pressure sensor"),
        (14, "Idle air control valve"), (15, "Ignition output signal"), (16, "Fuel injector"), (17, "Road speed sensor"),
        (19, "A/T lock-up solenoid"), (20, "Electrical load detector"), (21, "VTEC solenoid"), (22, "VTEC pressure switch"),
        (23, "Knock sensor"), (24, ""), (25, ""), (26, ""), (27, ""), (29, ""),
    ];

    public static CalPage CheckEngineCodes() => new("celcode", "Check engine codes", "Options",
        "Untick a code to stop it being stored or lighting the check-engine lamp - a sensor that is not fitted, say. " +
        "Its fail-safe still works: the ECU still uses a safe value in place of a sensor it sees has failed.",
        [G("Stored and shown on the check-engine lamp",
            [.. Codes.Select(c => S($"celcode.{c.Code}", c.What.Length > 0 ? $"Code {c.Code}: {c.What}" : $"Code {c.Code}"))])]);

    public static CalPage RpmSwitch() => new("rpmswitch", "RPM switch", "Outputs",
        "An output that comes on above one rpm (and a throttle opening, if set) and goes off below another: a second shift light, " +
        "a nitrous arming signal, an intercooler spray.",
        [
            G("RPM switch",
                S("rpmswitch.enable", "Enable RPM switch"),
                C("rpmswitch.output", "Output", ModOutputs),
                S("rpmswitch.invert", "Invert output", "Drive the output while it is off instead."),
                V("rpmswitch.engage", "On above RPM", "rpm"),
                V("rpmswitch.disengage", "Off below RPM", "rpm"),
                V("rpmswitch.tps", "Only above TPS", "%", "0: any throttle.")),
        ]);

    public static CalPage GearFuel() => new("gearfuel", "Fuel by gear", "Fuel",
        "A fuel change for each gear, on top of the maps. Needs gear detection.",
        [G("Fuel by gear", S("gearfuel.enable", "Enable fuel by gear"), T("gearfuel.table", "Fuel change per gear", "%"))]);

    public static CalPage WarningLamp() => new("warnlamp", "Warning lamp", "Outputs",
        "A lamp on a spare output that lights when the coolant is too hot or the battery too low with the engine running.",
        [
            G("Warning lamp",
                S("warnlamp.enable", "Enable warning lamp"),
                C("warnlamp.output", "Output", ModOutputs),
                V("warnlamp.ect", "Light above ECT", "°C"),
                V("warnlamp.batt", "Light below battery", "V")),
        ]);

    public static CalPage Tach() => new("tach", "Tachometer output", "Outputs",
        "A tachometer signal on a spare output: it changes state at every spark, the signal a 4-cylinder tacho expects.",
        [G("Tachometer output", S("tach.enable", "Enable tachometer output"), C("tach.output", "Output", ModOutputs))]);

    public static IReadOnlyList<CalPage> All() =>
        [RollingIdle(), AntiStall(), SmartAlternator(), WaterMeth(), RpmSwitch(), GearFuel(), WarningLamp(), Tach(),
         .. BoardOptions(), Watermark(), CheckEngineCodes()];

    // ---------------------------------------------------------------- the pages for one ROM

    /// The pages for a ROM: every page, with the GPO pages in the skeleton's layout where the ROM has it, each page's extra settings (a slot under the page's key the page does not list) in a "More settings" group, and a page of its own for a feature whose settings no page is keyed for.
    public static List<CalPage> ForRom(DefinitionSet defs)
    {
        var pages = new List<CalPage>();
        foreach (var p in CalPage.All())
        {
            // a skeleton GIO module keys its output the same as the page, but switches on an rpm point and has more windows
            if (p.Key is ['g', 'p', 'o', >= '1' and <= '9'] && defs.Items.Any(i => i.HasSlot(p.Key + ".rpm.on"))) pages.Add(Gio(p.Key[3] - '0'));
            else pages.Add(p);
        }
        // the password block is kept by the watermark row, not shown as a setting of its own
        var bound = defs.Items.Where(i => i.Slot != null && i.Text != "password")
            .SelectMany(i => i.Slot!.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(s => (Slot: s, Item: i)))
            .ToList();
        var result = new List<CalPage>();
        var onSomePage = pages.SelectMany(p => p.Slots()).ToHashSet(StringComparer.OrdinalIgnoreCase);
        bound.RemoveAll(b => onSomePage.Contains(b.Slot));   // only the settings no page lists yet
        foreach (var p in pages)
        {
            var have = p.Slots().ToHashSet(StringComparer.OrdinalIgnoreCase);
            var extra = bound.Where(b => Prefix(b.Slot).Equals(p.Key, StringComparison.OrdinalIgnoreCase) && !have.Contains(b.Slot))
                             .DistinctBy(b => b.Slot, StringComparer.OrdinalIgnoreCase).ToList();
            result.Add(extra.Count == 0 ? p : p with { Groups = [.. p.Groups, G("More settings", [.. extra.Select(b => RowFor(b.Slot, b.Item, p.Name))])] });
        }
        // features no page is keyed for: a page each, named after their category
        var keys = result.Select(p => p.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var grp in bound.GroupBy(b => Prefix(b.Slot), StringComparer.OrdinalIgnoreCase).Where(g => !keys.Contains(g.Key)))
        {
            var first = grp.First().Item;
            string name = first.Category.Length > 0 ? first.Category : grp.Key;
            result.Add(new CalPage(grp.Key, name, "Added features", $"The settings of {name.ToLowerInvariant()}.",
                [G(name, [.. grp.DistinctBy(b => b.Slot, StringComparer.OrdinalIgnoreCase).Select(b => RowFor(b.Slot, b.Item, name))])]));
        }
        return result;
    }

    static string Prefix(string slot) { int d = slot.IndexOf('.'); return d < 0 ? slot : slot[..d]; }

    /// A row for a setting no page lists: its kind from the definition, its label from its name less the feature's own words.
    static PageRow RowFor(string slot, ItemDef item, string feature)
    {
        var kind = item.Text != null ? RowKind.Text
                 : item.Flag || item.Type == CellType.Bit ? RowKind.Switch
                 : item.IsTable && item.Count > 1 ? RowKind.Table
                 : RowKind.Value;
        string tip = item.Description;
        if (kind == RowKind.Value && slot.EndsWith(".input", StringComparison.OrdinalIgnoreCase) && item.Formula == "raw")
            return new PageRow(slot, Label(item.Name, feature), RowKind.Choice, "", tip, null, CalPage.InputsAlwaysOn, CalPage.InputValuesAlwaysOn);
        if (kind == RowKind.Value && slot.EndsWith(".cut", StringComparison.OrdinalIgnoreCase) && item.Description.Contains("0 = fuel cut"))
            return new PageRow(slot, Label(item.Name, feature), RowKind.Choice, "", tip, null, ["Fuel cut", "Ignition cut", "Fuel and ignition cut"]);
        if (kind == RowKind.Value && slot.EndsWith(".output", StringComparison.OrdinalIgnoreCase) && item.Formula == "raw")
            return new PageRow(slot, Label(item.Name, feature), RowKind.Choice, "", tip, null, ModOutputs);
        return new PageRow(slot, Label(item.Name, feature), kind, "", tip);
    }

    /// "LaunchRPMReset" on the "Launch control" page -> "RPM reset"; "BurnoutEnable" -> "Enable".
    public static string Label(string name, string feature)
    {
        var words = SplitWords(name);
        var drop = SplitWords(feature.Replace(" ", "")).Select(w => w.ToLowerInvariant()).ToHashSet();
        int k = 0;
        while (k < words.Count - 1 && drop.Contains(words[k].ToLowerInvariant())) k++;
        var rest = words.Skip(k).ToList();
        if (rest.Count == 0) return name;
        var text = string.Join(" ", rest.Select((w, i) => w.All(char.IsUpper) && w.Length > 1 ? w : i == 0 ? w : w.ToLowerInvariant()));
        return char.ToUpperInvariant(text[0]) + text[1..];
    }

    static List<string> SplitWords(string s)
    {
        var words = new List<string>();
        int start = 0;
        for (int i = 1; i <= s.Length; i++)
        {
            bool cut = i == s.Length
                || char.IsUpper(s[i]) && (char.IsLower(s[i - 1]) || i + 1 < s.Length && char.IsLower(s[i + 1]) && char.IsUpper(s[i - 1]))
                || char.IsDigit(s[i]) != char.IsDigit(s[i - 1]);
            if (cut) { if (i > start) words.Add(s[start..i]); start = i; }
        }
        return words;
    }
}
