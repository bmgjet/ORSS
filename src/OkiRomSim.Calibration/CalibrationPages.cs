// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Calibration;

/// How one setting appears on a feature page.
public enum RowKind
{
    /// A number, in whatever unit the bound definition's formula gives.
    Value,
    /// A tick box (the definition is a flag or a bit).
    Switch,
    /// One of a fixed list; the raw byte is the index into it, or the matching entry of the row's Values (the one-hot input selections of the established tuning software).
    Choice,
    /// Two numbers side by side under Minimum / Maximum headings. The slots are `<slot>.min` and `<slot>.max`.
    MinMax,
    /// A map, opened in the normal table editor.
    Table,
    /// A short text (a name, the watermark).
    Text,
    /// A setting forced on or off in software, or left to the ECU: two bits, `<slot>.on` and `<slot>.off`, shown as one choice.
    Force,
}

/// One row of a feature page: what it is called, what it is in, and the stable key that says which definition of the ROM fills it.
public sealed record PageRow(
    string Slot,
    string Label,
    RowKind Kind = RowKind.Value,
    string Unit = "",
    string Tip = "",
    /// Words to look for in the definition names when guessing the binding the first time the page is opened.
    string[]? Guess = null,
    /// The list a Choice row offers, in raw-value order.
    string[]? Options = null,
    /// The raw value of each Choice option, when it is not simply its position in the list.
    int[]? Values = null,
    /// A Switch that reads the other way round from its definition (one byte, two pages that ask opposite questions of it).
    bool Inverted = false);

/// A titled block of rows. `Conditions` lays it out as the two-column Minimum / Maximum grid the established tuning software uses.
public sealed record PageGroup(string Title, PageRow[] Rows, bool Conditions = false);

/// A page of the calibration editor that gathers the settings of one ECU feature into the layout the established tuning software gives it, instead of leaving them scattered through a list of addresses. The pages describe themselves; nothing here touches a ROM. Each row carries a slot key, and the editor binds a slot to one of the ROM's definitions (remembered in <see cref="ItemDef.Slot"/>). That indirection is the whole trick: two ROMs keep the same setting at different addresses under different names, and the page does not have to care.
public sealed record CalPage(string Key, string Name, string Category, string Blurb, PageGroup[] Groups)
{
    /// Every slot the page uses, including the two halves of each Minimum / Maximum row.
    public IEnumerable<string> Slots()
    {
        foreach (var g in Groups)
            foreach (var r in g.Rows)
                if (r.Kind == RowKind.MinMax) { yield return r.Slot + ".min"; yield return r.Slot + ".max"; }
                else if (r.Kind == RowKind.Force) { yield return r.Slot + ".on"; yield return r.Slot + ".off"; }
                else yield return r.Slot;
    }

    public static readonly string[] GpoOutputs =
    {
        "ACC (A/C clutch, A15)", "PCS (purge valve, A20)", "PO2H (O2 heater, A6)", "FANC (radiator fan relay, A12)",
        "MIL (check engine light, A13)", "FPR (fuel pump relay, A7)", "IAB (intake butterflies, A17)",
        "ALTC (alternator control, A16)", "None",
    };

    /// The switch inputs, as the established tuning software offers them. The byte it stores is one-hot (one bit per input; the ROM's input routine reads 80h as always on and 00 as never), so the raw values are <see cref="InputValues"/>, not positions. A GPO calls 80h "None": no input is needed.
    public static readonly string[] GpoInputs =
    {
        "Power steering switch (B8)", "Service check connector (D4)", "Start signal (B9)", "VTEC pressure switch (D6)",
        "A/C request (B5)", "Brake switch (D2)", "Park / neutral input (B7)", "None (conditions only)",
    };
    public static readonly int[] InputValues = [1, 2, 4, 8, 16, 32, 64, 128];

    /// The same inputs as the other features offer them: 80h "always on", and 00 "disabled".
    public static readonly string[] InputsAlwaysOn = [.. GpoInputs[..7], "Always on", "Disabled"];
    public static readonly int[] InputValuesAlwaysOn = [1, 2, 4, 8, 16, 32, 64, 128, 0];

    /// A skeleton ROM with the serial inputs built in takes them as switch inputs too: C0h-C7h, on while the value is not 0.
    public static readonly string[] SerialSwitchInputs = [.. Enumerable.Range(1, 8).Select(i => $"Serial input {i} (on when not 0)")];
    public static readonly int[] SerialSwitchValues = [0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7];

    /// A switch-input row's choices for this ROM: the serial inputs added when it has them (SerialInputNumber is the serial inputs module's).
    public static (string[] Options, int[]? Values) WithSerialInputs(DefinitionSet defs, string[] options, int[]? values)
    {
        bool switchRow = values != null && (values.SequenceEqual(InputValues) || values.SequenceEqual(InputValuesAlwaysOn));
        return switchRow && defs.Find("SerialInputNumber") != null ? ([.. options, .. SerialSwitchInputs], [.. values!, .. SerialSwitchValues]) : (options, values);
    }

    /// The general-purpose output pages, laid out exactly as the established tuning software lays them out: the input and output it is wired to, the window of conditions that switches it, and the options.
    public static CalPage Gpo(int n) => new(
        $"gpo{n}", $"General purpose output {n}", "GPO",
        $"A spare output the ROM drives when the engine is inside a window of conditions - a water injection pump, a shift light, a second fuel pump, " +
        $"an intercooler sprayer. Pick what it drives and what switches it, set the window, and turn it on.",
        [
            new PageGroup("Input / output settings",
            [
                new PageRow($"gpo{n}.output", "Output", RowKind.Choice, Options: GpoOutputs, Guess: [$"gpo{n}output", $"gpo{n}out"],
                            Tip: "Which ECU output this takes over. Whatever it normally does stops happening, so pick one the engine does not need."),
                new PageRow($"gpo{n}.output.invert", "Invert output", RowKind.Switch, Guess: [$"gpo{n}outinv", $"gpo{n}invertout"],
                            Tip: "Drive the output low when the conditions are met instead of high."),
                new PageRow($"gpo{n}.input", "Input", RowKind.Choice, Options: GpoInputs, Values: InputValues, Guess: [$"gpo{n}input", $"gpo{n}in"],
                            Tip: "An input that has to agree before the output comes on. Disabled: the conditions alone decide."),
                new PageRow($"gpo{n}.input.invert", "Invert input", RowKind.Switch, Guess: [$"gpo{n}ininv", $"gpo{n}invertin"],
                            Tip: "Take the input the other way round."),
            ]),
            new PageGroup("Conditions",
            [
                new PageRow($"gpo{n}.rpm", "RPM", RowKind.MinMax, "rpm", Guess: [$"gpo{n}rpm"]),
                new PageRow($"gpo{n}.speed", "Speed", RowKind.MinMax, "km/h", Guess: [$"gpo{n}vss", $"gpo{n}speed"]),
                new PageRow($"gpo{n}.ect", "ECT", RowKind.MinMax, "°C", Guess: [$"gpo{n}ect"]),
                new PageRow($"gpo{n}.iat", "IAT", RowKind.MinMax, "°C", Guess: [$"gpo{n}iat"]),
                new PageRow($"gpo{n}.load", "Load", RowKind.MinMax, "mBar", Guess: [$"gpo{n}map"]),
                new PageRow($"gpo{n}.tps", "TPS", RowKind.Value, "%", Guess: [$"gpo{n}tps"],
                            Tip: "Throttle the output needs to be above."),
            ], Conditions: true),
            new PageGroup("Options",
            [
                new PageRow($"gpo{n}.enable", "Enable general purpose output", RowKind.Switch, Guess: [$"gpo{n}enable", $"gpo{n}on"]),
                new PageRow($"gpo{n}.secondary", "Switch to secondary maps on output", RowKind.Switch, Guess: [$"gpo{n}secondary", $"gpo{n}maps"],
                            Tip: "While the output is on, read the second set of fuel and ignition maps."),
                new PageRow($"gpo{n}.nomil", "Disable if MIL code", RowKind.Switch, Guess: [$"gpo{n}mil"],
                            Tip: "Hold the output off while a fault code is stored."),
                new PageRow($"gpo{n}.nocut", "Disable if FTL / FTS / boost cut", RowKind.Switch, Guess: [$"gpo{n}cut", $"gpo{n}ftl"]),
            ]),
            .. (n == 1
                ? new[] { new PageGroup("Fuel and ignition corrections while the output is on",
                  [
                      new PageRow($"gpo{n}.fuel", "Fuel", RowKind.Table, "%", Guess: [$"gpo{n}fuel"],
                                  Tip: "Fuel trim against rpm while the output is on."),
                      new PageRow($"gpo{n}.retard", "Ignition", RowKind.Table, "°", Guess: [$"gpo{n}retard", $"gpo{n}ign"],
                                  Tip: "Timing trim against rpm while the output is on."),
                  ]) }
                : []),
        ]);

    /// The pages the editor offers: the general-purpose outputs, then every other feature the established tuning software gives a page of its own (HtsPages).
    public static IReadOnlyList<CalPage> All() => [Gpo(1), Gpo(2), Gpo(3), Gpo(4), .. HtsPages.All(), .. ModulePages.All(), .. Extra];

    /// Pages added by plugins.
    public static readonly List<CalPage> Extra = [];

    /// The pages for one ROM (<see cref="ModulePages.ForRom"/>): the same, with every setting its feature modules add on a page.
    public static List<CalPage> ForRom(DefinitionSet defs) => ModulePages.ForRom(defs);

    /// The definition bound to a slot, or null.
    public static ItemDef? Bound(DefinitionSet defs, string slot) =>
        defs.Items.FirstOrDefault(i => i.HasSlot(slot));

    /// Every definition bound to a slot: a setting the ROM keeps in more than one place (a patch spread over two operands, a value the code reads from two copies) is written to all of them.
    public static List<ItemDef> BoundAll(DefinitionSet defs, string slot) =>
        [.. defs.Items.Where(i => i.HasSlot(slot))];

    /// Bind a ROM's rows. An HTS 1.15 / HTS120 ROM is bound by address from the HTS layout (every row, typed and scaled); anything still empty after that is guessed from the definition names. Only empty slots are guessed, and only where a name really does contain one of the words, so a wrong guess is rare and always visible (and changeable) on the page.
    public static int BindAll(DefinitionSet defs, byte[] rom)
    {
        int n = HtsLayout.Apply(defs, rom);
        foreach (var page in All()) n += GuessBindings(defs, page);
        CalibrationDetector.ShareScaling(defs);
        return n;
    }

    /// Guess the empty rows of a page from the definition names.
    public static int GuessBindings(DefinitionSet defs, CalPage page)
    {
        int n = 0;
        foreach (var group in page.Groups)
            foreach (var row in group.Rows)
            {
                foreach (var (slot, extra) in Halves(row))
                {
                    if (Bound(defs, slot) != null) continue;
                    var hit = row.Guess is { Length: > 0 } words ? Guess(defs, words, extra, row.Kind) : null;
                    if (hit != null) { hit.AddSlot(slot); n++; }
                }
            }
        return n;
    }

    static IEnumerable<(string Slot, string Extra)> Halves(PageRow row) =>
        row.Kind == RowKind.MinMax ? [(row.Slot + ".min", "min"), (row.Slot + ".max", "max")]
        : row.Kind == RowKind.Force ? [(row.Slot + ".on", "on"), (row.Slot + ".off", "off")]
            : [(row.Slot, "")];

    static ItemDef? Guess(DefinitionSet defs, string[] words, string extra, RowKind kind)
    {
        bool wantTable = kind == RowKind.Table;
        foreach (var word in words)
        {
            var want = word + extra;
            var hit = defs.Items.FirstOrDefault(i =>
                i.Slot == null && (i.IsTable && i.Count > 1) == wantTable &&
                Squash(i.Name).Contains(want, StringComparison.OrdinalIgnoreCase));
            if (hit != null) return hit;
        }
        return null;
    }

    static string Squash(string name) => name.Replace("_", "").Replace(" ", "").Replace("-", "");
}
