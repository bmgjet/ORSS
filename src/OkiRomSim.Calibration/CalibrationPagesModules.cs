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
        "P1.4 (check engine light, A13)", "P1.5 (ECU LED)", "P0.2 high (alternator control, A16)", "P0.2 low (alternator control, A16)",
        "P0.0 held off (A/C clutch disengaged)", "P0.3 (radiator fan)", "P4.3 (pin A17)",
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

    static readonly string[] Cuts = ["Fuel cut", "Ignition cut", "Fuel and ignition cut"];
    const string CutTip = "Fuel cut: the injectors stop - quiet and easy on the exhaust. Ignition cut: the sparks stop and the fuel burns in the " +
                          "exhaust - the crackle, hard on the converter. Both: the hardest cut. Whichever is picked, the engine is never let past the limit.";

    /// The rev limits as the skeleton's limiter modules lay them out: the rev limiter, the speed limiter by switch, the rpm ceilings, the limit by gear and the ignition cut shaping.
    public static CalPage RevLimitModule() => new("revlimit", "Rev limits", "Limits",
        "The limits that cut fuel or spark: the rev limiter (one point for each cam), a road speed limiter worked by a switch, rpm ceilings by road " +
        "speed and by gear, and how an ignition cut is shaped. The lowest limit in force wins; the skeleton's own over-rev cut stays above them all.",
        [
            G("Rev limiter",
                S("revlimit.enable", "Enable rev limiter", "On: cut at the points below. Off: only the skeleton's own over-rev cut is left, as a safety net."),
                C("revlimit.cut", "Low cam cut", Cuts, tip: CutTip),
                V("revlimit.low.set", "Low cam cut at", "rpm", "Cut at this rpm while the low cam is in use."),
                V("revlimit.low.reset", "Low cam back in below", "rpm", "Fuel / spark come back once the rpm falls under this. A little under the cut point (100-200 rpm) for a smooth limiter; further for a harder bounce."),
                S("revlimit.high.enable", "Enable high cam limit", "Normally the same as the low cam's switch. Off: the high cam has no limit of its own (only the over-rev cut)."),
                C("revlimit.high.cut", "High cam cut", Cuts, tip: CutTip),
                V("revlimit.high.set", "High cam cut at", "rpm", "Cut at this rpm while VTEC is engaged."),
                V("revlimit.high.reset", "High cam back in below", "rpm", "Fuel / spark come back once the rpm falls under this.")),
            G("Speed limiter by switch",
                S("revlimit.swlimit.enable", "Enable speed limiter by switch",
                  "A road speed limit that only works while a switch is on (or off, with \"Limit while the input is off\"): a pit lane limiter on a " +
                  "button, a valet limit, or a limit with the A/C on. It cuts like a rev limiter, at a road speed instead of an rpm."),
                C("revlimit.swlimit.cut", "Cut", Cuts, tip: CutTip),
                V("revlimit.swlimit.speed", "Limit to", "km/h", "Cut at this road speed while the switch is on, until the speed drops back under it. 255 = off."),
                C("revlimit.swlimit.input", "Switch", CalPage.InputsAlwaysOn, CalPage.InputValuesAlwaysOn,
                  "Which input turns the limit on. Always on: the limit always applies (a plain speed limiter)."),
                S("revlimit.swlimit.invert", "Limit while the input is off", "The limit applies while the switch is off instead - e.g. until the clutch or a key switch is pressed.")),
            G("Rpm ceilings by road speed",
                S("revlimit.ceiling.enable", "Enable rpm ceilings", "A lower rev limit at low road speeds: easier on the drivetrain pulling away. 12500 rpm in an entry = no ceiling there."),
                C("revlimit.ceiling.cut", "Cut", Cuts, tip: CutTip),
                T("revlimit.ceiling.speed", "Ceiling by road speed", "rpm", "Five points, falling road speed: at or above each km/h, the rpm ceiling beside it.")),
            G("Rev limit by gear",
                S("revlimit.ceiling.gear.enable", "Enable rev limit by gear", "A rev limit for each gear (needs gear detection). 12500 rpm = none in that gear."),
                C("revlimit.ceiling.gear.cut", "Cut", Cuts, tip: CutTip),
                T("revlimit.ceiling.gear", "Limit in each gear", "rpm", "Gear 0 is neutral or not known yet.")),
            G("Ignition cut shaping",
                S("revlimit.icmod", "Shape the ignition cuts", "On: an ignition cut (rev limit, launch, full throttle shift) is held for the times below, " +
                  "with sparks back in between, instead of cutting spark for as long as it is over the limit."),
                V("revlimit.cutdelay", "Cut time", "ms", "How long each cut lasts (the rev limiter and the rest)."),
                V("revlimit.cutdelay.launch", "Launch cut time", "ms", "How long each launch control cut lasts."),
                V("revlimit.cutdelay.fts", "Full throttle shift cut time", "ms", "How long each full throttle shift cut lasts."),
                V("revlimit.refire", "Sparks back for", "ms", "Sparks come back for this long between cuts. 0 = a plain cut."),
                V("revlimit.icenrich", "Extra fuel while cutting", "%", "More fuel while an ignition cut is wanted: cooler, and a louder crackle."),
                S("revlimit.icstatic.on", "Hold the timing while cutting", "Hold the ignition timing at one value while an ignition cut is wanted."),
                V("revlimit.icstatic", "Timing then", "°", "The timing held while cutting (with the switch above on).")),
        ]);

    /// VTEC as the skeleton's VTEC control module lays it out: the HTS page, with the switch between its own engage points and the stock ones, and the outputs a module can drive.
    public static CalPage VtecModule() => new("vtec", "VTEC", "Outputs",
        "Where the cam changes over, the conditions it needs, and the checks that can be switched off. Tick \"Use these engage points\" " +
        "for the points and conditions here; untick it and the stock points (at the bottom) decide, as on a ROM without the module.",
        [
            G("VTEC settings",
                S("vtec.enable", "Enable VTEC", "Off: the solenoid is never switched on - a non-VTEC head, or a conversion not wired yet."),
                S("vtec.custom", "Use these engage points", "On: the rpm, throttle and conditions on this page decide. Off: the stock points below do."),
                V("vtec.minect", "Minimum ECT", "°C"),
                V("vtec.minspeed", "Minimum speed", "km/h", "Above 0 keeps VTEC out at a standstill."),
                V("vtec.minload", "Minimum load", "mBar")),
            G("VTEC RPM",
                V("vtec.rpm.high", "High load engage", "rpm", "Where VTEC comes in at or above the high load throttle."),
                V("vtec.tps.high", "High load above TPS", "%"),
                V("vtec.rpm.low", "Low load engage", "rpm", "Where VTEC comes in at or below the low load throttle; in between, on a straight line."),
                V("vtec.tps.low", "Low load below TPS", "%"),
                V("vtec.disengage", "Disengage delay", "rpm", "Once in, VTEC stays in until the rpm is this far under the engage point, so it does not chatter at the point.")),
            G("VTEC options",
                S("vtec.nospeed", "Disable VTEC speed check"),
                S("vtec.notemp", "Disable VTEC temp check"),
                S("vtec.noerror", "Disable VTEC error check", "Engage even with a sensor fault stored.")),
            G("Alternative output",
                S("vtec.alt.enable", "Enable alternative output"),
                C("vtec.alt.output", "Output", ModOutputs),
                S("vtec.alt.invert", "Invert output")),
            HtsPages.StockVtec,
        ]);

    /// The MAP sensor a ROM built from the skeleton is set up for: the scale its pressures are shown in.
    public static CalPage MapSensor() => new("mapsensor", "MAP sensor", "Sensors",
        "The MAP sensor this ROM is set up for: what it reads at 0 V and at 5 V. The ECU never reads these; the app shows every pressure on " +
        "this scale. To fit another sensor use Tools > MAP sensor size (or the set-up wizard): it moves every load breakpoint and pressure setting " +
        "to suit and sets these. Typing here only changes how the pressures are shown.",
        [
            G("MAP sensor",
                V("mapsensor.zero", "Reads at 0 V", "mBar"),
                V("mapsensor.full", "Reads at 5 V", "mBar")),
        ]);

    /// The every-channel datalog module's own setting: eight RAM addresses of your own to log.
    public static CalPage DatalogExtra() => new("dlextra", "Datalog: RAM addresses", "Datalog",
        "Eight RAM addresses to log as the channels 'RAM address 1-8' (Datalogging > Channels, group Your RAM addresses): any byte from 80h to " +
        "47Fh, 0 for none. The memory map names what each RAM byte holds.",
        [G("RAM addresses to log", T("dlextra.user", "Addresses", "", "One a cell, 1 to 8; type them in hex as 0x1F0 or in decimal."))]);

    public static CalPage RollingIdle() => new("rollidle", "Rolling idle", "Idle",
        "A lumpy, big-cam idle: one injector opening (or one spark) in every few is left out at idle, so a different cylinder misses each " +
        "time round. Only below the rpm and throttle set here, at a standstill and warm.",
        [
            G("Rolling idle", [
                S("rollidle.enable", "Enable rolling idle"),
                C("rollidle.mode", "Leave out", ["An injector opening", "A spark"],
                  tip: "An injector is the gentle way. A spark sends that cylinder's fuel into the exhaust: pops, and heat in the catalyst."),
                V("rollidle.every", "One event in every", "", "3-19, odd only: with four cylinders an even number would always miss on the same one or two, so the ROM takes an even setting as the odd one above it and the miss moves round all four. 5 or 7 rolls, 3 is rough."),
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
                C("antistall.alt", "Alternator", ["Left alone", "Control line P0.2 high", "Control line P0.2 low"], [0, 7, 8],
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
                C("smartalt.level", "Control line level", ["P0.2 low", "P0.2 high"], [8, 7], "The level of the alternator control line (P0.2, pin A16) that turns charging down.")),
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
                Tip: "Up to 16 characters. Rom Sim Studio asks for it before it opens this ROM (.bin, source or project). Only a salted hash of it is kept in the ROM."))]);

    /// The trouble codes the ROM can set, and whether each one is stored and lights the check-engine lamp.
    static readonly (int Code, string What)[] Codes =
    [
        (1, "O2 sensor"), (3, "MAP sensor (electrical)"), (4, "Crank position sensor"), (5, "MAP sensor (vacuum)"),
        (6, "Coolant temperature sensor"), (7, "Throttle position sensor"), (8, "TDC sensor"), (9, "Cylinder position sensor"),
        (10, "Intake air temperature sensor"), (11, "EGR valve lift sensor"), (12, "EGR system"), (13, "Barometric pressure sensor"),
        (14, "Idle air control valve"), (15, "Ignition output signal"), (16, "Fuel injector"), (17, "Road speed sensor"),
        (19, "A/T lock-up solenoid"), (20, "Electrical load detector"), (21, "VTEC solenoid"), (22, "VTEC pressure switch"),
        (23, "Knock sensor"), (24, "Knock sensor circuit check"), (25, "P4.6 feedback check (flashes 35)"), (26, "Analog input 5 out of range (flashes 36)"),
        (27, "O2 sensor heater (flashes 41)"), (29, "Fuel supply system (flashes 43)"),
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

    public static CalPage Nitrous() => new("nitrous", "Nitrous (N2O)", "Fuel",
        "Nitrous mode: while armed, at wide throttle and inside its rpm window, the nitrous maps - the secondary fuel and ignition maps " +
        "(FuelLow2, FuelHigh2, IgnitionLow2, IgnitionHigh2 in the table list), tuned for the base shot - are blended in, and an output " +
        "can drive the solenoid. A shot input (a voltage, or a serial input over the datalog cable) scales how far they are from the " +
        "normal maps, so one tune covers several jets: tune the maps for the base jet, then the shot table says what more each volt means.",
        [
            G("Nitrous", [
                S("nitrous.enable", "Enable nitrous mode", "On: the nitrous maps (and the solenoid) while every condition below is met. Off: the normal maps always."),
                .. Input("nitrous.input", "Arming switch", "The switch that arms it - the dash arming switch, or a serial input from a panel. Always on: armed whenever the rest is met."),
                V("nitrous.tps", "Only above TPS", "%", "Spray only at wide throttle: nitrous at part throttle runs lean and damages engines. 90 % or more is usual."),
                V("nitrous.rpm.min", "From rpm", "rpm", "No shot below this: too low and the shot hammers the engine (and the bottom end)."),
                V("nitrous.rpm.max", "Up to rpm", "rpm", "And none above this: keep it under the rev limit, so the shot is off before the limiter cuts."),
                C("nitrous.output", "Solenoid output", ModOutputs, tip: "The output that switches the nitrous solenoid relay while spraying. None: an external controller sprays; the ROM only changes the maps.")]),
            G("Shot size",
                C("nitrous.shotinput", "Shot input", ["O2 pin (D14)", "ELD pin (D10)", "EGR pin (D12)", "B6 pin", "Serial input 1", "Serial input 2", "Serial input 3", "Serial input 4",
                    "Serial input 5", "Serial input 6", "Serial input 7", "Serial input 8", "None: the maps as tuned"], [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 255],
                    "Where the shot size comes from: a 0-5 V signal on a free pin (a jet selector, a potentiometer), or a serial input sent over the datalog cable (0-255 read as 0-5 V). None: always 100 %."),
                T("nitrous.shot", "Shot table", "%", "How much of the nitrous maps' change from the normal maps is used, by the shot input's volts: 100 % is the maps as tuned " +
                    "(the base jet, e.g. 50 hp), 150 % half as much more fuel added and timing taken out (75 hp), 200 % twice the change (100 hp). Blended between the points.")),
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

    public static CalPage SerialInputs() => new("serialin", "Serial inputs", "Options",
        "Extra inputs that come over the datalog cable instead of a wire: the laptop (Datalogging > Channels… > Send to the ECU) or a " +
        "small board sends FFh, an input number and a value, and the ECU keeps the eight numbers listed here as serial input 1-8. " +
        "Closed loop, lean protection and flex fuel can read them as an analog input (their inputs 4-11); every module with a switch " +
        "input can use them as a switch, on while the value is not 0. If none come for the time set here (a cable pulled out) each " +
        "goes back to its default, so nothing is left stuck on. Example: the laptop's wideband AFR x 10 sent as input 0, closed " +
        "loop set to serial input 1 - closed loop on a wideband with no wire to the ECU.",
        [
            G("Serial inputs",
                T("serialin.number", "Input number kept as serial input 1-8", "", "The number the device sends for each (0-253); 255: that one is not used."),
                T("serialin.default", "Value until one comes", "", "What each reads as from power-up until the first comes, and when they stop coming."),
                V("serialin.timeout", "Back to the defaults after", "ms", "No input for this long and every one reads as its default. 0: keep the last value.")),
        ]);

    /// Added features > Serial port: the datalog cable's settings - the service commands' and the remote control commands'.
    public static CalPage Datalog() => new("datalog", "Serial port", "Added features",
        "What the datalog cable (the ECU's serial port) can do besides logging: its speed, the timing the service commands lock at, and the " +
        "remote control commands - a phone, a tablet or a button box sets the fan, the rev and speed limits, the boost cut, the VTEC " +
        "point, the shift light, the launch rpm, fuel or ignition cut and rolling idle, turns popcorn mode on, and works an anti-start " +
        "lock: no password, no start (or valet mode); the main password runs the engine as tuned, the guest password in valet mode. " +
        "Whatever is set over the cable is forgotten at power-up. Every command is in the documentation (Remote control and serial commands).",
        [
            G("Line speed",
                S("datalog.fast", "62,500 baud instead of 38,400",
                    "Each frame comes in sooner, and more of them with the engine stopped. With the engine running the ECU paces what it sends by its spark " +
                    "calculation (so logging never takes the engine code's time), whatever the line. Needs a cable that can be set to 62,500 exactly (an FTDI " +
                    "one can) and the same rate in Settings > Datalog. HTS and other loggers, and a Demon, want 38,400: leave it off for them. Takes effect at the next power-up.")),
            G("Service commands",
                V("datalog.servicetiming", "Timing locked at", "°", "What Lock timing (53h) holds the timing at, for a timing light.")),
            G("Remote control",
                S("remote.enable", "Take the remote control commands"),
                V("remote.boostmax", "Boost cut may be set above the tune's by", "", "MAP sensor counts past the tune's own cut point. 0: the boost cut can only be set lower over the cable, never above the tune.")),
            G("Anti-start lock",
                S("remote.lock", "No password, no start (locked at every key-on)"),
                S("remote.lockvalet", "No or a wrong password: valet mode instead of no start", "With the lock on: the engine starts, held to valet mode's limits and timing, until the main password is sent. (Off: it will not start at all.)"),
                V("remote.password.main", "Main password (as tuned)", "", "A number 0-65535."),
                S("remote.guest", "Take the guest password (valet mode)"),
                V("remote.password.guest", "Guest password (valet mode)", "", "A number 0-65535, different from the main one.")),
            G("Valet mode (the guest password)",
                V("remote.valet.rev", "Rev limit", "rpm", "0 = the ROM's own. A rev limit set over the cable wins."),
                V("remote.valet.speed", "Speed limit", "", "0 = none. A speed limit set over the cable wins."),
                V("remote.valet.ign", "Timing offset", "°", "Negative = softer.")),
            G("Popcorn mode (decel pops)",
                V("remote.pop.rpm", "Works above", "rpm"),
                V("remote.pop.tps", "With the throttle at or under", ""),
                V("remote.pop.fuel", "Fuel added", "%", "The overrun fuel cut is held off while it pops."),
                V("remote.pop.retard", "Timing taken out", "°", "The sparks are also cut every other tick, so the fuel burns in the exhaust.")),
        ]);

    public static IReadOnlyList<CalPage> All() =>
        [RollingIdle(), AntiStall(), Nitrous(), SmartAlternator(), WaterMeth(), RpmSwitch(), GearFuel(), WarningLamp(), Tach(),
         .. BoardOptions(), Watermark(), CheckEngineCodes(), SerialInputs(), Datalog(), MapSensor(), DatalogExtra()];

    // ---------------------------------------------------------------- the pages for one ROM

    /// The pages for a ROM: every page, with the GPO pages in the skeleton's layout where the ROM has it, each page's extra settings (a slot under the page's key the page does not list) in a "More settings" group, and a page of its own for a feature whose settings no page is keyed for.
    public static List<CalPage> ForRom(DefinitionSet defs)
    {
        var pages = new List<CalPage>();
        foreach (var p in CalPage.All())
        {
            // a skeleton GIO module keys its output the same as the page, but switches on an rpm point and has more windows
            if (p.Key is ['g', 'p', 'o', >= '1' and <= '9'] && defs.Items.Any(i => i.HasSlot(p.Key + ".rpm.on"))) pages.Add(Gio(p.Key[3] - '0'));
            // the skeleton's VTEC control module: its own outputs, and a switch between its points and the stock ones
            else if (p.Key == "vtec" && defs.Items.Any(i => i.HasSlot("vtec.custom"))) pages.Add(VtecModule());
            // the skeleton's limiter modules: their own switches and cuts, and the switch inputs in the module's encoding
            else if (p.Key == "revlimit" && defs.Items.Any(i => i.HasSlot("revlimit.enable") || i.HasSlot("revlimit.swlimit.enable"))) pages.Add(RevLimitModule());
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
