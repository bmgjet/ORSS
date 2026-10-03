// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Calibration;

/// The rest of the ECU's features as pages, laid out the way HTS 1.15 lays them out: the same pages, groups, labels and units. They are data, not code - the renderer is <c>FeaturePageView</c> - so another page is a dozen lines here. Every row names a slot rather than an address. On an HTS ROM <see cref="HtsLayout"/> says where each slot lives; on any other ROM the editor binds a slot to one of the ROM's own definitions (remembered in <see cref="ItemDef.Slot"/>, so it travels with them).
public static class HtsPages
{
    // ---------------------------------------------------------------- shorthand

    static PageRow V(string slot, string label, string unit = "", string tip = "", params string[] guess)
        => new(slot, label, RowKind.Value, unit, tip, guess.Length > 0 ? guess : [Squash(slot)]);

    static PageRow S(string slot, string label, string tip = "", bool inverted = false)
        => new(slot, label, RowKind.Switch, "", tip, [Squash(slot)], Inverted: inverted);

    static PageRow MM(string slot, string label, string unit = "", string tip = "")
        => new(slot, label, RowKind.MinMax, unit, tip, [Squash(slot)]);

    static PageRow T(string slot, string label, string unit = "", string tip = "")
        => new(slot, label, RowKind.Table, unit, tip, [Squash(slot)]);

    static PageRow C(string slot, string label, string[] options, int[]? values = null, string tip = "")
        => new(slot, label, RowKind.Choice, "", tip, [Squash(slot)], options, values);

    /// A switch input (one-hot byte) and its invert byte, the pair every HTS input selector is.
    static PageRow[] Input(string slot, string label, bool alwaysOn, string tip = "") =>
    [
        C(slot, label, alwaysOn ? CalPage.InputsAlwaysOn : CalPage.GpoInputs, alwaysOn ? CalPage.InputValuesAlwaysOn : CalPage.InputValues, tip),
        S(slot + ".invert", "Invert input"),
    ];

    static PageGroup G(string title, params PageRow[] rows) => new(title, rows);
    static PageGroup G(string title, PageRow[] first, params PageRow[] rest) => new(title, [.. first, .. rest]);
    static PageGroup Cond(string title, params PageRow[] rows) => new(title, rows, true);

    /// "vtec.rpm.engage" -> "vtecrpmengage", which is what a name is matched against.
    static string Squash(string slot) => slot.Replace(".", "").Replace("_", "");

    const string Deg = "°";
    const string DegC = "°C";

    /// The bits of the switch byte HTS120's speed limiter reads (3B0h), in bit order.
    static readonly string[] SwitchByteInputs =
    {
        "Park / neutral (B7)", "Brake switch (D2)", "A/C request (B5)", "VTEC pressure switch (D6)",
        "Start signal (B9)", "Service check connector (D4)", "VTEC solenoid feedback", "Power steering switch (B8)",
    };
    static readonly int[] Bits = [0, 1, 2, 3, 4, 5, 6, 7];

    static readonly string[] Loads = ["MAP", "Alpha-N", "TPS"];
    static readonly string[] LoadIndexNames = [.. from p in Enumerable.Range(0, 3) from q in Enumerable.Range(0, 3) select $"Primary {Loads[p]}, secondary {Loads[q]}"];
    static readonly int[] LoadIndexValues = [.. from p in Enumerable.Range(0, 3) from q in Enumerable.Range(0, 3) select p | (q << 2)];

    // ---------------------------------------------------------------- fuel

    public static CalPage CloseLoop() => new("closeloop", "Closed loop", "Fuel",
        "The O2 trim that holds the mixture off boost: where the signal comes from, how far the trim may go, and when it hands " +
        "control back to the fuel map.",
        [
            G("Closeloop settings",
                C("closeloop.input", "O2 input", ["ELD (D10)", "EGR (D12)", "B6", "O2 (D14)"]),
                V("closeloop.targetv", "Target O2 voltage", "V"),
                V("closeloop.maxload", "Disable above load", "mBar"),
                V("closeloop.minect", "Disable below ECT", DegC),
                V("closeloop.maxo2v", "Max O2 voltage", "V", "Over this the MIL comes on."),
                S("closeloop.o2heater.disable", "Disable O2 heater")),
            Cond("Term correction", MM("closeloop.adjust", "Max adjustment", "%")),
            G("Disable by TPS",
                T("closeloop.tps.open", "Open loop above TPS", "%"),
                T("closeloop.tps.close", "Closed loop below TPS", "%")),
            G("Rate of change", T("closeloop.rate", "Rate of change", "%/s")),
            G("VE overheat fuel correction",
                S("closeloop.ve", "VE correction", "Ticked when the VE correction is in use (the byte is the 'disable VE' flag).", inverted: true),
                V("closeloop.ve.ect", "Above ECT", DegC),
                S("closeloop.ve.fueldisable", "VE overheat fuel disable"),
                T("closeloop.ve.table", "Fuel correction vs ECT", "%")),
        ]);

    public static CalPage CrankFuel() => new("crankfuel", "Cranking fuel", "Fuel",
        "How much fuel the engine gets while the starter is turning, against coolant temperature, and the rpm and load " +
        "compensations applied on top.",
        [
            G("Cranking fuel",
                T("crankfuel.ect", "Cranking fuel vs ECT", "", "The fuel word / 4 at each coolant temperature, as HTS shows it."),
                V("crankfuel.trim", "Cranking trim", "%")),
            G("RPM / MAP cranking fuel compensation",
                T("crankfuel.rpm", "Compensation vs RPM", "%"),
                T("crankfuel.map", "Compensation vs MAP", "%")),
        ]);

    public static CalPage FuelCut() => new("fuelcut", "Fuel cut", "Fuel",
        "Fuel shut off on a closed throttle above an rpm and let back in as the revs fall; the resume tables decide how it comes " +
        "back so the engine does not stumble.",
        [
            G("Fuel cut on deceleration settings",
                S("fuelcut.enable", "Enable fuel cut"),
                V("fuelcut.rpm", "Above RPM", "rpm"),
                V("fuelcut.tps", "Below TPS", "%"),
                V("fuelcut.load", "Below load", "mBar")),
            G("Vacuum leak",
                S("fuelcut.vacuum.disable", "Disable for vacuum leak"),
                V("fuelcut.vacuum.rpm", "Above RPM", "rpm"),
                V("fuelcut.vacuum.tps", "Below TPS", "%")),
            G("Overrun fuelcut resume (normal)", T("fuelcut.resume.normal", "Resume vs ECT")),
            G("Overrun fuelcut resume (initial)", T("fuelcut.resume.initial", "Resume vs ECT")),
        ]);

    public static CalPage TipInOut() => new("tipinout", "TPS tip in / out", "Fuel",
        "Extra fuel when the throttle is opened quickly and less when it is shut.",
        [
            G("TPS tip in and out fuel corrections",
                V("tipinout.tipin", "TPS tip in", "%"),
                V("tipinout.shiftresponse", "TPS shift response", "%"),
                V("tipinout.disable", "Tip out disable below", "rpm")),
            G("TPS tip in fuel (normal)", T("tipinout.normal", "Tip in vs ECT")),
            G("TPS tip in fuel (initial)", T("tipinout.initial", "Tip in vs ECT")),
        ]);

    public static CalPage Injector() => new("injector", "Injectors", "Fuel",
        "Injector size, lag against battery voltage and the fuel trims that go with a change of injector.",
        [
            G("Injector settings",
                V("injector.multiplier", "Injector multiplier", "x", "Old injector size / new."),
                V("injector.deadtime", "Dead time"),
                V("injector.overall", "Overall fuel trim", "%"),
                V("injector.crank", "Cranking trim", "%"),
                V("injector.postfuel", "Post start trim", "%"),
                V("injector.tipin", "Tip in trim", "%")),
            G("Injector size scaling (added feature)",
                S("injector.enable", "Scale the fuel for different injectors",
                  "Off: the fuel maps as they are. On: every pulse is scaled by the size the maps were written for against the size fitted, and the trim below is added. This never switches the injectors off."),
                V("injector.stock", "Injectors the maps were written for", "cc", "Size in cc/min of the injectors the fuel maps were tuned on (240 cc on a stock P30)."),
                V("injector.fitted", "Injectors fitted", "cc", "Size in cc/min of the injectors in the engine now."),
                V("injector.trim", "Extra fuel trim", "%", "A trim on top of the scaling, richer (+) or leaner (-).")),
            G("Injector lag", T("injector.lag", "Lag vs battery", "ms")),
            G("Injector size",
                V("injector.coldlow", "Cold, low", "cc"),
                V("injector.coldhigh", "Cold, high", "cc"),
                V("injector.hotlow", "Hot, low", "cc"),
                V("injector.hothigh", "Hot, high", "cc")),
            G("Post fuel decay",
                T("injector.postdecay1", "Decay 1"),
                T("injector.postdecay2", "Decay 2"),
                T("injector.postdecay3", "Decay 3")),
        ]);

    public static CalPage FlexFuel() => new("flexfuel", "Flex fuel", "Fuel",
        "An ethanol content sensor on an analog input, and the fuel and timing added as the blend changes.",
        [
            G("Flex fuel", C("flexfuel.input", "Ethanol input", ["Disabled", "Analog D10 (ELD)", "Analog D12 (EGR)", "Analog B6"])),
            G("Fuel compensation", T("flexfuel.fuel", "Fuel vs ethanol")),
            G("Ignition advance compensation", T("flexfuel.ign", "Advance vs ethanol", Deg)),
        ]);

    public static CalPage CylinderTrim() => new("cyltrim", "Individual cylinder trims", "Fuel",
        "A fuel and a timing trim for each cylinder.",
        [
            G("Fuel trim", T("cyltrim.fuel", "Fuel per cylinder", "%")),
            G("Ignition trim", T("cyltrim.ign", "Timing per cylinder", Deg)),
        ]);

    // ---------------------------------------------------------------- ignition

    public static CalPage Dwell() => new("dwell", "Dwell control", "Ignition",
        "How long the coil charges for, against rpm and battery voltage.",
        [
            G("Dwell control",
                T("dwell.base", "Dwell base values vs RPM"),
                T("dwell.rpm", "Dwell vs RPM")),
            G("Battery", T("dwell.batt", "Compensation vs battery", "%")),
        ]);

    public static CalPage TpsRetard() => new("tpsretard", "TPS tip-in retard", "Ignition",
        "Timing pulled out when the throttle is snapped open: a base amount per rpm, a minimum throttle, and multipliers for " +
        "throttle and gear.",
        [
            G("Base retard per RPM", T("tpsretard.base", "Retard vs RPM", Deg)),
            G("Minimum TPS required per RPM", T("tpsretard.mintps", "TPS vs RPM", "%")),
            G("TPS correction multiplier", T("tpsretard.tpsmul", "Multiplier vs TPS")),
            G("Gear correction multiplier", T("tpsretard.gearmul", "Correction per gear", "%")),
            G("Gear duration", T("tpsretard.duration", "Duration per gear", "ms")),
            Cond("Conditions",
                MM("tpsretard.rpm", "RPM", "rpm"),
                MM("tpsretard.speed", "Speed", "km/h"),
                V("tpsretard.ect", "ECT above", DegC)),
        ]);

    public static CalPage IdleIgnCorr() => new("idleigncorr", "Idle ignition correction", "Ignition",
        "Timing moved at idle to hold the target rpm.",
        [
            G("Idle ignition correction",
                S("idleigncorr.enable", "Idle ignition adjustments"),
                V("idleigncorr.ect", "Above ECT", DegC)),
        ]);

    public static CalPage EctCorrections() => new("ectcorr", "ECT corrections", "Ignition",
        "What the ECU does to fuel and timing as the coolant temperature changes, and the post-start enrichment.",
        [
            G("Fuel correction", T("ectcorr.fuel", "Fuel vs ECT", "%")),
            G("Ignition correction", T("ectcorr.ign", "Timing vs ECT", Deg)),
            G("Post start", T("ectcorr.poststart", "Post start vs ECT")),
        ]);

    public static CalPage IatCorrections() => new("iatcorr", "IAT corrections", "Ignition",
        "What the ECU does to fuel and timing as the intake air temperature changes.",
        [
            G("IAT fuel correction", T("iatcorr.fuel", "Fuel vs IAT", "%")),
            G("IAT ignition correction", T("iatcorr.ign", "Timing vs IAT", Deg)),
        ]);

    public static CalPage GearCorr() => new("gearcorr", "Gear corrections", "Ignition",
        "Fuel and timing trims per gear above a load and a speed.",
        [
            G("Gear corrections",
                T("gearcorr.fuel", "Fuel per gear", "%"),
                T("gearcorr.ign", "Ignition per gear", Deg),
                V("gearcorr.load", "Above load", "mBar"),
                V("gearcorr.speed", "Above speed", "km/h")),
        ]);

    // ---------------------------------------------------------------- limits

    public static CalPage RevLimit() => new("revlimit", "Rev limits", "Limits",
        "The limiter: which cut it uses, where it sits on each cam, and the delays that decide how hard it feels. Unticking " +
        "both the ignition and the fuel cut leaves no limiter at all.",
        [
            G("Rev limits settings",
                S("revlimit.igncut", "Ignition cut"),
                S("revlimit.fuelcut", "Fuel cut"),
                V("revlimit.warmect", "Warm above ECT", DegC),
                V("revlimit.low.set", "Low cam cut", "rpm"),
                V("revlimit.low.reset", "Low cam resume", "rpm"),
                V("revlimit.high.set", "High cam cut", "rpm"),
                V("revlimit.high.reset", "High cam resume", "rpm")),
            G("Ignition cut time mod",
                V("revlimit.igndelay", "Ignition cut delay", "ms"),
                V("revlimit.launchdelay", "Launch cut delay", "ms"),
                V("revlimit.ftsdelay", "FTS cut delay", "ms")),
            G("Ignition cut extra mod",
                S("revlimit.mod", "Enable fuel / ignition mod"),
                V("revlimit.enrich", "Enrichment on ignition cut", "FV"),
                V("revlimit.staticign", "Static ignition on ignition cut", Deg)),
            G("Rpm ceilings (HTS120)",
                T("revlimit.ceiling.gear", "Ceiling per gear 0-5", "rpm", "12500 = no ceiling in that gear."),
                T("revlimit.ceiling.speed", "Ceiling by road speed", "rpm", "Falling km/h; the lower of the two ceilings applies.")),
            G("Speed limiter by switch (HTS120)",
                V("revlimit.swlimit.speed", "Speed limit", "km/h", "Fuel and spark are cut at this road speed while the chosen input is on. 255 = off."),
                C("revlimit.swlimit.input", "Input", SwitchByteInputs, Bits, "A bit of the ROM's own switch byte (3B0h)."),
                S("revlimit.swlimit.invert", "Limit while the input is off")),
        ]);

    public static CalPage LaunchControl() => new("launch", "Launch control / 2-step", "Limits",
        "A lower limiter held while the car is stationary, with anti-lag on top of it.",
        [
            G("2-step settings",
                [.. Input("launch.input", "Launch input", alwaysOn: true)],
                C("launch.mode", "Mode", ["Memory based (fixed)", "TPS based (adjustable)"], [0, 255]),
                V("launch.rpm", "Launch RPM (memory based)", "rpm"),
                V("launch.minrpm", "Minimum RPM (TPS based)", "rpm"),
                V("launch.speed", "Below speed", "km/h")),
            G("TPS settings (only for adjustable launch)",
                V("launch.tps.engage", "Engage above", "%"),
                V("launch.tps.disengage", "Disengage below", "%")),
            G("Launch control anti-lag",
                S("launch.antilag.enable", "Enable launch control anti-lag"),
                V("launch.antilag.tps", "Above TPS", "%"),
                V("launch.antilag.enrich", "Enrichment", "FV"),
                V("launch.antilag.retard", "Ignition retard", Deg),
                S("launch.antilag.static", "Static"),
                V("launch.antilag.staticdeg", "Static ignition", Deg)),
        ]);

    public static CalPage FullThrottleShift() => new("fts", "Full throttle shift", "Limits",
        "A momentary cut on a flat-shift input so the next gear can be taken without lifting.",
        [
            G("Full throttle shift settings",
                [.. Input("fts.input", "Full throttle shift input", alwaysOn: true)],
                V("fts.cutrpm", "Cut RPM", "rpm"),
                V("fts.tps", "Above TPS", "%"),
                V("fts.vss", "Above VSS", "km/h"),
                V("fts.igndelay", "Ignition cut delay", "ms"),
                S("fts.strain", "Enable strain cut delay")),
            G("Gear based rev limit",
                S("fts.gearlimit", "Enable gear based revlimit"),
                T("fts.gear", "Cut RPM per gear", "rpm")),
            G("Full throttle shift anti-lag",
                S("fts.antilag", "Enable FTS anti-lag"),
                V("fts.enrich", "Enrichment", "FV"),
                V("fts.retard", "Ignition retard", Deg),
                S("fts.static", "Static"),
                V("fts.staticdeg", "Static ignition", Deg)),
        ]);

    public static CalPage BurnOut() => new("burnout", "Burnout control", "Limits",
        "A limiter held on an input, for warming tyres.",
        [G("Burnout control", [.. Input("burnout.input", "Burnout input", alwaysOn: true)], V("burnout.rpm", "Burnout RPM", "rpm"))]);

    // ---------------------------------------------------------------- protection

    public static CalPage LeanProtection() => new("leanpro", "Lean protection", "Protection",
        "A wideband watching for a lean excursion under load. Two independent stages, so a warning can come before a cut.",
        [
            G("Lean protection settings",
                V("leanpro.minrpm", "Minimum RPM", "rpm"),
                V("leanpro.mintps", "Minimum TPS", "%")),
            G("Lean protection 1",
                S("leanpro.1.enable", "Enable lean protection 1"),
                V("leanpro.1.volts", "Trigger voltage", "V"),
                V("leanpro.1.load", "Above load", "mBar"),
                V("leanpro.1.duration", "Max lean duration", "ms")),
            G("Lean protection 2",
                S("leanpro.2.enable", "Enable lean protection 2"),
                V("leanpro.2.volts", "Trigger voltage", "V"),
                V("leanpro.2.load", "Above load", "mBar"),
                V("leanpro.2.duration", "Max lean duration", "ms")),
        ]);

    public static CalPage EctProtection() => new("ectpro", "ECT protection", "Protection",
        "An rpm ceiling once the coolant is too hot.",
        [
            G("ECT protection",
                S("ectpro.enable", "Enable ECT protection"),
                V("ectpro.ect", "Above ECT", DegC),
                V("ectpro.rpm", "Limit RPM to", "rpm")),
        ]);

    public static CalPage AntiStart() => new("antistart", "Anti-start", "Protection",
        "The ECU powers up with fuel and spark cut until a switch (the A/C switch by default) is on with the throttle past a point. " +
        "Throttle alone would clash with the code-flash request.",
        [
            G("Anti-start protection",
                [S("antistart.enable", "Enable anti-start"),
                 .. Input("antistart.input", "Unlock input", alwaysOn: true, "The switch that unlocks it, with the throttle. Always on: the throttle alone.")],
                V("antistart.tps", "Unlock with TPS at least", "", "Near full throttle.")),
        ]);

    // ---------------------------------------------------------------- boost

    public static CalPage BoostCut() => new("boostcut", "Boost cut", "Boost",
        "The overboost cut, hot and cold.",
        [
            G("Boost cut settings",
                S("boostcut.enable", "Enable boost cut"),
                S("boostcut.dtc", "Enable boost cut if DTC"),
                V("boostcut.hot", "Hot cut", "mBar"),
                V("boostcut.cold", "Cold cut", "mBar"),
                V("boostcut.ect", "Cold below ECT", DegC)),
        ]);

    public static CalPage BoostcontrolEbc() => new("ebc", "Electronic boost control", "Boost",
        "A solenoid on a spare output holding a target boost.",
        [
            G("Input / output",
                [.. Input("ebc.input", "PWM input", alwaysOn: true)],
                C("ebc.hilo.input", "Low / high input", CalPage.InputsAlwaysOn, CalPage.InputValuesAlwaysOn),
                S("ebc.hilo.input.invert", "Invert low / high input"),
                C("ebc.output", "PWM output", ["A11 - EGR (A20 - purge on a dev board)", "A17 - AT lockup / IAB"], [0, 255]),
                C("ebc.dial", "Dial input", ["ELD", "EGR", "B6"])),
            G("PWM settings",
                V("ebc.frequency", "Frequency (period word)", "raw"),
                S("ebc.pwmmode", "PWM mode (0% max, 100% min)")),
            Cond("Solenoid duty", MM("ebc.duty", "Duty", "%")),
            G("Target",
                V("ebc.fixedduty", "Fixed duty cycle", "%", "0 = use the tables."),
                S("ebc.rpmmode", "RPM based target"),
                S("ebc.closeloop", "Closed loop"),
                V("ebc.fastspool", "Fastspool duty", "%")),
            G("Activation points",
                V("ebc.active", "EBC active above", "mBar"),
                V("ebc.wastegate", "Wastegate", "mBar"),
                S("ebc.disabledtc", "Disable PWM if DTC or lean condition")),
            G("Closed loop",
                V("ebc.cl.min", "Closed loop min"),
                V("ebc.cl.max", "Closed loop max"),
                V("ebc.cl.overshoot", "Update timer (negative)", "ms"),
                V("ebc.cl.undershoot", "Update timer (positive)", "ms"),
                V("ebc.cl.deadband", "Dead band", "raw")),
            G("Duty lookup",
                T("ebc.lookup", "Duty vs boost", "%"),
                T("ebc.gear", "Boost per gear", "psi"),
                T("ebc.gearlow", "Low boost per gear", "psi"),
                T("ebc.gearhigh", "High boost per gear", "psi")),
            G("Compensations",
                T("ebc.rpm", "RPM correction"),
                T("ebc.iat", "IAT correction")),
        ]);

    public static CalPage BoostManual() => new("boostmanual", "Manual boost controller", "Boost",
        "Fixed solenoid stages chosen by an input and by speed.",
        [
            G("Manual boost controller",
                [.. Input("boostmanual.input", "Activate input", alwaysOn: true)],
                S("boostmanual.nodtc", "Disable if MIL code"),
                S("boostmanual.nocut", "Disable if FTL / FTS / boost cut active")),
            G("Stages",
                V("boostmanual.2.speed", "Second stage above", "km/h"),
                V("boostmanual.3.speed", "Third stage above", "km/h"),
                V("boostmanual.4.speed", "Fourth stage above", "km/h")),
        ]);

    // ---------------------------------------------------------------- idle and outputs

    public static CalPage Idle() => new("idle", "Idle", "Idle",
        "The idle target against coolant temperature, the air valve and the timing that holds it.",
        [
            G("Idle settings",
                V("idle.rpm", "Target idle", "rpm"),
                S("idle.iacverror.disable", "Disable IACV error (code 14)"),
                V("idle.iacv.duty", "IACV duty", "raw"),
                V("idle.iacv.dutyac", "IACV duty (A/C on)", "raw")),
            G("Target idle vs ECT", T("idle.target", "Target vs ECT", "rpm")),
            G("Low ignition control idle", T("idle.ign.low", "Low idle ignition control")),
            G("High ignition control idle", T("idle.ign.high", "High idle ignition control")),
        ]);

    public static CalPage Vtec() => new("vtec", "VTEC", "Outputs",
        "Where the cam changes over, the conditions it needs, and the checks that can be switched off. A ROM built from the skeleton " +
        "has only the stock points until the VTEC control module is built in (File > Change functions…).",
        [
            G("VTEC settings",
                S("vtec.enable", "Enable VTEC"),
                V("vtec.minect", "Minimum ECT", DegC),
                V("vtec.minspeed", "Minimum speed", "km/h"),
                V("vtec.minload", "Minimum load", "mBar")),
            G("VTEC RPM",
                V("vtec.rpm.high", "High load engage", "rpm"),
                V("vtec.tps.high", "High load above TPS", "%"),
                V("vtec.rpm.low", "Low load engage", "rpm"),
                V("vtec.tps.low", "Low load below TPS", "%"),
                V("vtec.disengage", "Disengage delay", "rpm", "Once in, VTEC stays in until the rpm is this far under the engage point, so it does not chatter at the point.")),
            G("VTEC options",
                S("vtec.nospeed", "Disable VTEC speed check"),
                S("vtec.notemp", "Disable VTEC temp check"),
                S("vtec.noerror", "Disable VTEC error check"),
                S("vtec.nopressure", "Disable VTEC pressure switch")),
            G("Alternative output",
                S("vtec.alt.enable", "Enable alternative output"),
                C("vtec.alt.output", "Output", CalPage.GpoOutputs),
                S("vtec.alt.invert", "Invert output")),
            StockVtec,
        ]);

    /// The stock ECU's own VTEC points (the skeleton's), on both VTEC pages: what decides while no engage points of a module are in use.
    internal static PageGroup StockVtec => G("Stock engage points",
        V("vtec.stock.load.on", "With load: engages above", "rpm", "Above this rpm VTEC comes in when the load is over the curve below."),
        V("vtec.stock.load.off", "With load: drops out below", "rpm"),
        V("vtec.stock.any.on", "Any load: engages above", "rpm", "Above this rpm VTEC comes in whatever the load."),
        V("vtec.stock.any.off", "Any load: drops out below", "rpm"),
        T("vtec.stock.curve", "Load needed against rpm", "", "Between the two engage points, the load VTEC needs at each rpm."));

    public static CalPage Iab() => new("iab", "IAB (intake butterflies)", "Outputs",
        "Where the intake manifold's butterflies open and shut.",
        [
            G("IAB activation",
                S("iab.enable", "Enable IAB"),
                V("iab.engage", "Engage", "rpm"),
                V("iab.disengage", "Disengage", "rpm"),
                S("iab.invert", "Invert IAB output"),
                S("iab.usdm", "USDM ECU")),
            G("Alternate IAB output",
                C("iab.alt.output", "Output", CalPage.GpoOutputs),
                S("iab.alt.invert", "Invert output")),
        ]);

    public static CalPage FanControl() => new("fan", "Fan control", "Outputs",
        "When the radiator fan runs.",
        [
            G("Fan control",
                S("fan.enable", "Enable fan control"),
                V("fan.ect", "Above ECT", DegC),
                V("fan.speed", "Below speed", "km/h"),
                C("fan.output", "Fan output", CalPage.GpoOutputs),
                S("fan.invert", "Invert output")),
        ]);

    public static CalPage AirCon() => new("ac", "Air conditioning", "Outputs",
        "When the compressor is cut out, and the idle around it.",
        [
            G("A/C settings", S("ac.disable", "Disable A/C")),
            G("A/C cutoff",
                S("ac.cutoff.enable", "Enable A/C cutoff"),
                V("ac.cutoff.rpm", "Above RPM", "rpm"),
                V("ac.cutoff.tps", "Above TPS", "%"),
                V("ac.cutoff.speed", "Above speed", "km/h")),
            G("Idle",
                V("ac.idlecut", "Cut below RPM", "rpm"),
                V("ac.idleresume", "Resume above RPM", "rpm")),
        ]);

    public static CalPage ShiftLight() => new("shiftlight", "MIL shift light", "Outputs",
        "The check-engine lamp used as a shift light.",
        [
            G("MIL shiftlight",
                S("shiftlight.enable", "Enable shiftlight"),
                S("shiftlight.gearbased", "Enable gear based shiftlight"),
                V("shiftlight.rpm", "Shift RPM", "rpm"),
                T("shiftlight.gear", "Shift RPM per gear", "rpm")),
        ]);

    public static CalPage Traction() => new("tcc", "Traction control", "Outputs",
        "HTS120: no sensor needed - a wheel that lets go shows as rpm climbing faster than the gear allows, and timing is pulled until it stops.",
        [
            G("Engine-speed traction control",
                S("tc.rpmrate.enable", "Enable"),
                V("tc.rpmrate.sample", "Sample every", "ms"),
                V("tc.rpmrate.speed", "Above speed", "km/h"),
                V("tc.rpmrate.tps", "Above TPS", "V"),
                T("tc.rpmrate.limit", "Allowed rise per gear", "rpm", "Rpm rise per sample, gear 0-5; 0 turns TC off in that gear."),
                V("tc.rpmrate.attack", "Retard step", Deg),
                V("tc.rpmrate.max", "Max retard", Deg),
                V("tc.rpmrate.decay", "Recovery step", Deg)),
        ]);

    // ---------------------------------------------------------------- sensors and options

    public static CalPage MapIndexing() => new("mapindex", "Maps indexing", "Sensors",
        "What the fuel and ignition tables are read against, and where the alpha-N blend crosses over.",
        [
            G("Primary / secondary map load", C("mapindex.loadindex", "Load", LoadIndexNames, LoadIndexValues,
                "Bits 0-1: primary map load, bits 2-3: secondary (0 MAP, 1 alpha-N, 2 TPS).")),
            G("Alpha-N",
                V("mapindex.alpha.tps0", "0% TPS", "%"),
                V("mapindex.alpha.map0", "0% load", "mBar"),
                V("mapindex.alpha.tps100", "100% TPS", "%"),
                V("mapindex.alpha.map100", "100% load", "mBar")),
            G("Crossover",
                V("mapindex.crosstps", "Crossover TPS", "%"),
                V("mapindex.crossmap", "Crossover MAP", "mBar")),
            G("Maps",
                S("mapindex.highcamonly", "High cam maps only"),
                S("mapindex.secondaryonly", "Secondary maps only")),
        ]);

    public static CalPage DualMap() => new("dualmap", "Secondary maps", "Sensors",
        "What puts the ECU onto its second set of fuel and ignition maps.",
        [
            G("Secondary map settings",
                [.. Input("dualmap.input", "Input", alwaysOn: true)],
                C("dualmap.mode", "Mode", ["Disabled", "Input", "Crossover"])),
            G("Crossover",
                S("dualmap.chkrpm", "Above RPM"), V("dualmap.rpm", "RPM", "rpm"),
                S("dualmap.chktps", "Above TPS"), V("dualmap.tps", "TPS", "%"),
                S("dualmap.chkload", "Above load"), V("dualmap.load", "Load", "mBar")),
        ]);

    public static CalPage TpsSensor() => new("tpssensor", "TPS sensor", "Sensors",
        "What the throttle sensor reads shut and wide open, so percentages mean something.",
        [
            G("TPS sensor",
                S("tpssensor.custom", "Enable custom TPS"),
                V("tpssensor.min", "TPS at 0%", "V"),
                V("tpssensor.max", "TPS at 100%", "V")),
        ]);

    public static CalPage Transmission() => new("transmission", "Transmission", "Sensors",
        "The gearbox the ECU works gear out from, and the road-speed correction.",
        [
            G("Transmission",
                V("transmission.preset", "Gearbox preset", "", "FFh = custom ratios below."),
                T("transmission.ratio", "Custom ratios")),
            G("Road speed (HTS120)",
                V("vss.correction", "Speed correction", "%", "100% reads as measured.")),
        ]);

    public static CalPage ServiceConnector() => new("scc", "Service connector / misc", "Options",
        "The fuel pump, the MIL flashes, the ignition lock and the service check connector's own input.",
        [
            G("Service check connector input", [.. Input("scc.input", "SCC input", alwaysOn: true)]),
            G("Fuel pump control",
                C("scc.fuelpump", "Fuel pump", ["Normal", "Always on (drain tank)", "Always off (fuel off)"]),
                V("scc.prime", "Prime duration", "s")),
            G("MIL (malfunction indicator light)", V("scc.milflashes", "MIL flashes", "times")),
            G("Ignition lock",
                S("scc.ignlock.enable", "Lock ignition"),
                V("scc.ignlock.deg", "Lock ignition at", Deg)),
        ]);

    public static CalPage RomOptions() => new("romoptions", "ROM options", "Options",
        "The fault codes and hardware checks a ROM can be told to ignore. Each is there because a sensor has been removed or a " +
        "system deleted - turning one off on a car that still has the part hides a real fault.",
        [
            G("Sensor / hardware options",
                S("romoptions.checksum", "ROM checksum check (resets the ECU when the ROM's sum is wrong: leave off for live tuning)"),
                S("romoptions.dtc13", "Disable code 13 (PA / baro)"),
                S("romoptions.dtc14", "Disable code 14 (idle air control valve)"),
                S("romoptions.dtc16", "Disable code 16 (injector test)"),
                S("romoptions.dtc20", "Disable code 20 (ELD)"),
                S("romoptions.dtc21", "Disable code 21 (VTEC solenoid feedback)"),
                S("romoptions.dtc22", "Disable code 22 (VTEC pressure switch)"),
                S("romoptions.dtc30", "Disable code 30 (automatic transmission A)"),
                S("romoptions.dtc31", "Disable code 31 (automatic transmission B)"),
                S("romoptions.dtc36", "Disable code 36 (traction control)"),
                S("romoptions.dtc41", "Disable code 41 (O2 heater)"),
                S("romoptions.vecorr", "Disable VE correction"),
                S("romoptions.igncorrload", "Disable ignition correction above"),
                V("romoptions.igncorrload.value", "Ignition correction above", "mBar"),
                S("romoptions.starter", "Disable starter input"),
                S("romoptions.purge", "Disable purge valve"),
                S("romoptions.purgeinvert", "Invert purge valve (OBD2b)"),
                S("romoptions.closeloop", "Disable closed loop and VE"),
                S("romoptions.closeloopOnly", "Disable closed loop only", inverted: true),
                S("romoptions.autotranny", "Disable auto transmission"),
                S("romoptions.altc", "Disable alternator control"),
                S("romoptions.debug", "Enable baserom debug mode")),
            G("Important / critical sensors - at your own discretion",
                S("romoptions.dtc6", "Disable code 6 (engine coolant temp)"),
                V("romoptions.dtc6.value", "Fixed ECT", DegC),
                S("romoptions.dtc7", "Disable code 7 (throttle position)"),
                S("romoptions.dtc9", "Disable code 9 (CYP cylinder / cam)", "Engine simulator use only."),
                S("romoptions.dtc10", "Disable code 10 (intake air temp)"),
                V("romoptions.dtc10.value", "Fixed IAT", DegC),
                S("romoptions.dtc17", "Disable code 17 (vehicle speed sensor)"),
                V("romoptions.dtc17.value", "Fixed speed", "km/h")),
        ]);

    /// Every page here, in the order the tuning software lists them.
    public static IReadOnlyList<CalPage> All() =>
    [
        CloseLoop(), CrankFuel(), FuelCut(), TipInOut(), Injector(), FlexFuel(), CylinderTrim(),
        Dwell(), TpsRetard(), IdleIgnCorr(), EctCorrections(), IatCorrections(), GearCorr(),
        RevLimit(), LaunchControl(), FullThrottleShift(), BurnOut(),
        LeanProtection(), EctProtection(), AntiStart(),
        BoostCut(), BoostcontrolEbc(), BoostManual(),
        Idle(), Vtec(), Iab(), FanControl(), AirCon(), ShiftLight(), Traction(),
        MapIndexing(), DualMap(), TpsSensor(), Transmission(),
        ServiceConnector(), RomOptions(),
    ];
}
