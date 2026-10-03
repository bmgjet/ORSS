// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Assembler;

namespace OkiRomSim.Calibration;

public enum AdviceLevel { Good, Info, Warning, Error }

/// One thing said about a pick of functions: a check it passes (Good), something to know, something that may hurt the engine or the tuning of it, or something that stops it being built.
public sealed record Advice(AdviceLevel Level, string Title, string Detail, string? Check = null);

/// What File > New ROM > Create says about a pick of functions before it is written: what stops it building, what is missing that a car wants (a way to log it, fail-safes, protection), and pairs that build but want care. The checks are by define, so a skeleton without one of these functions is simply not asked about it.
public static class SkeletonAdvice
{
    /// The things every ROM is checked for, shown as a row of ticks and crosses.
    public const string RevLimiter = "Rev limiter", FailSafes = "Fail-safes", Datalogging = "Datalogging", Protection = "Engine protection", RomSpace = "ROM space", ModuleRam = "Module RAM";

    static readonly string[] LogModules = ["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLQD3"];
    static readonly string[] Protections = ["FEAT_ECTPRO", "FEAT_LEANPRO", "FEAT_BOOSTCUT", "FEAT_STOCK_KNOCK", "FEAT_WARNLAMP"];
    static readonly string[] BoostControl = ["FEAT_EBC", "FEAT_BOOSTMANUAL"];
    static readonly string[] RevLimiters = ["FEAT_REVLIMIT", "FEAT_GEARLIMIT", "FEAT_CEILING"];

    public static List<Advice> Check(Skeleton sk, IReadOnlyCollection<string> chosen, SkeletonBuildResult? build)
    {
        var set = new HashSet<string>(chosen, StringComparer.OrdinalIgnoreCase);
        bool Has(string d) => set.Contains(d);
        bool Offers(string d) => sk.Feature(d) != null;
        string Name(string d) => sk.Feature(d)?.Name ?? d;
        var list = new List<Advice>();

        // ---- what stops it being built
        foreach (var p in sk.Problems(set)) list.Add(new(AdviceLevel.Error, "Cannot be built together", p));
        if (build is { Success: false })
        {
            if (build.Over > 0) list.Add(new(AdviceLevel.Error, "Too big for the ROM", $"Over the 32 KB by {build.Over:N0} bytes: leave something out.", RomSpace));
            else if (build.Ram is { Full: true } full) list.Add(new(AdviceLevel.Error, "Module RAM is full", $"These modules want {full.Used} bytes of module RAM and there are {full.Size}: leave one out.", ModuleRam));
            else if (build.Errors.Count > 0) list.Add(new(AdviceLevel.Error, "Does not build", string.Join("\n", build.Errors.Take(3))));
        }

        // ---- the checklist
        var limiters = RevLimiters.Where(Has).Select(Name).ToList();
        if (sk.HasOwnRevLimiter || limiters.Count > 0)
            list.Add(new(AdviceLevel.Good, "Rev limiter", (sk.HasOwnRevLimiter ? "The skeleton's own rev limiter (fuel cut) is always in, whatever is ticked." : "")
                + (limiters.Count > 0 ? $" Also: {string.Join(", ", limiters)}." : ""), RevLimiter));
        else
            list.Add(new(AdviceLevel.Error, "No rev limiter", "Nothing in this ROM stops the engine over-revving. Tick a rev limiter.", RevLimiter));

        if (Offers("FEAT_STOCK_DTC"))
            list.Add(Has("FEAT_STOCK_DTC")
                ? new(AdviceLevel.Good, "Fail-safes", "The stock trouble codes are in: a failed sensor is replaced by a safe value and the check-engine lamp lights.", FailSafes)
                : new(AdviceLevel.Warning, "No fail-safes", "Without the stock trouble codes a failed sensor is used as it reads: a broken coolant sensor can read -40 °C and flood the engine, or 140 °C and lean it out. The check-engine lamp never lights.", FailSafes));

        var logs = LogModules.Where(Has).ToList();
        if (LogModules.Any(Offers))
        {
            if (logs.Count > 0) list.Add(new(AdviceLevel.Good, "Datalogging", $"Logged over the diagnostic connector: {string.Join(", ", logs.Select(Name))}.", Datalogging));
            else if (Has("FEAT_STOCK_SERIAL")) list.Add(new(AdviceLevel.Warning, "No datalogging protocol", "Only the stock Honda tester link is in: this app and the usual datalogging tools cannot log or read this ROM live. Tick a datalogging module instead to tune it on the car.", Datalogging));
            else list.Add(new(AdviceLevel.Warning, "No datalogging protocols in this ROM", "Nothing talks on the diagnostic connector: the ROM cannot be logged, and its codes cannot be read or cleared from a laptop. Tick Datalogging: HTS / ISR frame (or another datalogging module).", Datalogging));
        }

        var guards = Protections.Where(Has).Select(Name).ToList();
        if (Protections.Any(Offers))
            list.Add(guards.Count > 0
                ? new(AdviceLevel.Good, "Engine protection", $"{string.Join(", ", guards)}.", Protection)
                : new(AdviceLevel.Warning, "No safeties in this ROM", "Nothing cuts power when the engine overheats, runs lean or over-boosts, and nothing pulls timing on knock. Consider coolant temperature protection, lean protection, boost cut or the stock knock retard.", Protection));

        if (build is { Success: true })
        {
            list.Add(build.FreeBytes < 512
                ? new(AdviceLevel.Warning, "ROM almost full", $"Only {build.FreeBytes:N0} bytes left: a module added later, or a change to one, may not fit.", RomSpace)
                : new(AdviceLevel.Good, "ROM space", $"{build.FreeBytes:N0} bytes of the 32 KB free.", RomSpace));
            if (build.Ram is { } ram)
                list.Add(ram.Used > ram.Size * 0.85
                    ? new(AdviceLevel.Warning, "Module RAM nearly full", $"{ram.Used} of {ram.Size} bytes taken: there is little room for another module.", ModuleRam)
                    : new(AdviceLevel.Good, "Module RAM", $"{ram.Used} of {ram.Size} bytes taken ({ram.Base:X3}h-{ram.End - 1:X3}h).", ModuleRam));
        }

        // ---- pairs that build but want care
        var boost = BoostControl.Where(Has).ToList();
        if (boost.Count > 0 && Offers("FEAT_BOOSTCUT") && !Has("FEAT_BOOSTCUT"))
            list.Add(new(AdviceLevel.Warning, "Boost control without boost cut", $"{Name(boost[0])} is in but Boost cut is not: a stuck solenoid or a split hose has nothing to stop the boost climbing."));
        if (boost.Count > 0 && Offers("FEAT_STOCK_KNOCK") && !Has("FEAT_STOCK_KNOCK"))
            list.Add(new(AdviceLevel.Info, "Boost without knock retard", "Nothing pulls timing on knock. Tune conservatively, or add the stock knock retard if the engine has a knock sensor."));
        if (boost.Count > 0 && Offers("FEAT_LEANPRO") && !Has("FEAT_LEANPRO"))
            list.Add(new(AdviceLevel.Info, "Boost without lean protection", "With a wideband fitted, lean protection cuts power when it runs lean under boost."));
        if (Has("FEAT_ANTISTART"))
            list.Add(new(AdviceLevel.Warning, "Anti-start", "The engine will not start until it is unlocked. Check the unlock works on the bench before the car depends on it."));
        foreach (var d in new[] { "FEAT_WBCL", "FEAT_LEANPRO" }.Where(Has))
            list.Add(new(AdviceLevel.Info, $"{Name(d)}: needs a wideband", "A wideband controller's analog output wired to one of the ECU's spare inputs, and its 0 V / 5 V AFRs entered on the page."));
        if (Has("FEAT_FLEX"))
            list.Add(new(AdviceLevel.Info, "Flex fuel: needs an ethanol sensor", "An ethanol content sensor wired to the ECU."));
        if (Has("FEAT_STOCK_DTC") && (Has("FEAT_SHIFTLIGHT") || Has("FEAT_WARNLAMP")))
            list.Add(new(AdviceLevel.Info, "The check-engine lamp is shared", $"{Name(Has("FEAT_SHIFTLIGHT") ? "FEAT_SHIFTLIGHT" : "FEAT_WARNLAMP")} lights the same lamp the trouble codes do: a lit lamp may be either."));
        if (Has("FEAT_STOCK_DTC") && build?.Ram is { } r2 && r2.Used > 10)
            list.Add(new(AdviceLevel.Info, "Module RAM beside the stack", $"With the stock trouble codes in, module RAM is {r2.Base:X3}h-{r2.End - 1:X3}h, next to the stack. This has been tested with every module; leaving the trouble codes out moves module RAM well away from it."));
        if (Offers("FEAT_STOCK_SELFTEST") && !Has("FEAT_STOCK_SELFTEST"))
            list.Add(new(AdviceLevel.Info, "No self-tests", "The stock CPU / RAM / clock checks are out: a fault in the ECU itself is only caught by the watchdog."));
        if (Has("FEAT_CFGOVERRIDE"))
            list.Add(new(AdviceLevel.Info, "Board options in software", "The board's option resistors are overridden by the page: set them to match the car before the first start."));
        if (set.Any(d => sk.Feature(d) is { Stock: false }))
            list.Add(new(AdviceLevel.Info, "Modules start switched off", "Every module added here starts with its own switch off, so the ROM runs as the skeleton does until each one is set up and enabled on its page."));
        return list;
    }

    /// The pins behind the module output numbers (lib.asm mod_output), and what a stock function built back in drives on them.
    static readonly string?[] OutputPin = [null, "P0.0", "P0.1", "P0.4", "P1.2", "P1.4", "P1.5", "P0.2", "P0.2", "P0.0", "P0.3", "P4.3"];
    static readonly Dictionary<string, (string Define, string What)> StockOnPin = new()
    {
        ["P0.0"] = ("FEAT_STOCK_AC", "the stock A/C clutch"),
        ["P0.1"] = ("FEAT_STOCK_PURGE", "the stock EVAP purge"),
        ["P0.4"] = ("FEAT_STOCK_AT", "the stock A/T lock-up"),
        ["P4.3"] = ("FEAT_STOCK_AT", "the stock A/T lock-up (PWM)"),
        ["P1.2"] = ("FEAT_STOCK_O2HEATER", "the stock O2 heater"),
        ["P1.4"] = ("FEAT_STOCK_DTC", "the stock check-engine lamp"),
    };

    /// On a ROM built from a skeleton: two functions, switched on, set to drive the same ECU pin, or a pin a stock function that is built in drives as well. Neither stops the ROM building - the output is a setting - but only one of them gets the pin. Empty for any other ROM.
    public static List<string> OutputClashes(AssemblyResult asm, DefinitionSet defs, Func<ItemDef, double> raw)
    {
        var list = new List<string>();
        if (!asm.Files.Any(f => f.EndsWith("-skeleton.asm", StringComparison.OrdinalIgnoreCase))) return list;
        var built = asm.Symbols.Values.Where(s => s.Kind == SymbolKind.Define && s.Value != 0 && s.Name.StartsWith("FEAT_", StringComparison.OrdinalIgnoreCase))
                       .Select(s => s.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        double? Read(string slot) { var it = CalPage.Bound(defs, slot); if (it == null) return null; try { return raw(it); } catch { return null; } }
        bool On(string slot) => Read(slot) is double v && v != 0;
        var users = new List<(string Pin, string Who, int Level)>();
        void Use(string enable, string output, string who)
        {
            if (!On(enable) || Read(output) is not double v || v < 1 || v >= OutputPin.Length) return;
            users.Add((OutputPin[(int)v]!, who, (int)v));
        }
        for (int n = 1; n <= 4; n++) Use($"gpo{n}.enable", $"gpo{n}.output", $"GIO {n}");
        Use("iab.enable", "iab.output", "IAB");
        Use("rpmswitch.enable", "rpmswitch.output", "Rpm switch");
        Use("tach.enable", "tach.output", "Tachometer output");
        Use("warnlamp.enable", "warnlamp.output", "Warning lamp");
        Use("wmi.enable", "wmi.output", "Water / methanol pump");
        Use("vtec.alt.enable", "vtec.alt.output", "VTEC alternative output");
        if (built.Contains("FEAT_SHIFTLIGHT") && On("shiftlight.enable")) users.Add(("P1.4", "Shift light", 5));
        if (built.Contains("FEAT_SMARTALT") && On("smartalt.enable")) users.Add(("P0.2", "Smart alternator", Read("smartalt.level") is double sl ? (int)sl : 7));
        // the boost solenoid is P4.3 (pin A17)
        if (built.Contains("FEAT_EBC") && On("ebc.enable")) users.Add(("P4.3", "Electronic boost control", 11));
        if (built.Contains("FEAT_BOOSTMANUAL") && On("boostmanual.enable")) users.Add(("P4.3", "Manual boost controller", 11));
        if (built.Contains("FEAT_ACCUT") && On("ac.cutoff.enable")) users.Add(("P0.0", "A/C load disable", 9));
        if (built.Contains("FEAT_ANTISTALL") && On("antistall.enable") && Read("antistall.alt") is 7 or 8) users.Add(("P0.2", "Anti-stall (alternator)", (int)Read("antistall.alt")!.Value));
        foreach (var g in users.GroupBy(u => u.Pin).Where(g => g.Count() > 1))
        {
            var who = g.Select(u => u.Who).Distinct().ToList();
            // the alternator line: two that both want it at the same level (charging down) agree, they do not fight
            if (g.Key == "P0.2" && g.Select(u => u.Level).Distinct().Count() == 1) continue;
            // the A/C cut and anti-stall hold the clutch off on purpose; a pair of alternator users both turn charging down
            if (who.Count > 1) list.Add($"{string.Join(" and ", who)} are all set to drive {g.Key}: only one of them gets it.");
        }
        foreach (var (pin, who, _) in users.Where(u => StockOnPin.ContainsKey(u.Pin)).Distinct())
        {
            var (define, what) = StockOnPin[pin];
            // the A/C cut exists to hold the stock clutch off, and the lamp modules share the check-engine lamp by design
            if (!built.Contains(define) || (pin == "P0.0" && who == "A/C load disable") || (pin == "P1.4" && who is "Shift light" or "Warning lamp")) continue;
            list.Add($"{who} takes {pin} over from {what} ({define}, built in) while it is on: {what} does not work then.");
        }
        return list;
    }

    /// The worst level in a list (Good when it is empty).
    public static AdviceLevel Worst(IEnumerable<Advice> list) => list.Select(a => a.Level).DefaultIfEmpty(AdviceLevel.Good).Max();
}
