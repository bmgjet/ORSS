// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Text;

namespace OkiRomSim.Calibration;

/// Where the HTS 1.15 pages keep each setting, by address: the calibration layout of HondaTuneSuite 1.15 (HTS-master Rom.cs, LoadECtuneAddresses + NewLocation115 and the code-pattern searches), checked against the code of HTS120 that reads each field. HTS120 keeps the 1.15 calibration where it was, so one table serves both; its own settings are found by label. A name cannot do this job - the page rows are named after what a setting does, the ROMs after the old software's field names, and several fields have more than one name or none - so an HTS ROM is bound by address. <see cref="Apply"/> types, scales and binds every row of every page in one go.
public static partial class HtsLayout
{
    /// One setting: where it is (or, with a Label, the HTS120 label it sits at plus Address), and how to read it, written as the body of a ";@" annotation ("type=u8 formula=honda_temp_c", "count=6 colstride=2 ...").
    public sealed record Field(string Slot, int Address, string Name, string Spec, string Desc = "", string? Label = null);

    // ---------------------------------------------------------------- scalings (HTS method -> formula)

    const string U8 = "type=u8";
    const string U16 = "type=u16";
    const string Ect = "type=u8 formula=honda_temp_c";
    const string Tps = "type=u8 formula=tps_pct";
    const string Vss = "type=u8 formula=speed_kmh_byte";
    const string RpmW = "type=u16 formula=rpm_period_word";             // wordToRpm16bit
    const string RpmL = "type=u8 formula=rpm_axis_byte_log";            // byteToRpmLow8bit
    const string Mbar = "type=u8 formula=map_sensor_preset_mbar";                 // byteToMillibar, from the ROM's own MAP preset
    const string Volt = "type=u8 formula=volts_5v_byte";
    const string TrimW = "type=u16 formula=trim_word_pct";
    const string Trim128 = "type=u8 formula=trim_byte_pct";
    const string X10 = "type=u8 formula=time_10ms";                    // x * 10 ms
    const string Fv = "type=u16 formula=quarter";
    const string QDeg = "type=u8 formula=degrees_quarter";              // x * 0.25 deg
    const string Adv = "type=u8 formula=ign_advance";
    const string Duty = "type=u8 formula=duty_half_pct";
    const string Half = "type=u8 formula=half_step_signed";
    const string On = "type=u8 flag=1 on=255 off=0";                    // ticked when not 00
    const string OnZ = "type=u8 flag=1 on=0 off=255";                   // ticked when 00 (the 1.15 "== 0" checks)
    const string On1 = "type=u8 flag=1 on=1 off=0";                     // HTS120's own switches (00 off, else on)

    /// A Honda (x, y) table: the axis byte, then the value, `count` times - `step` bytes a step.
    static string Pairs(int at, int count, string yFormula, string xFormula, int step = 2, string yType = "u8") =>
        $"type={yType} count={count} colstride={step} formula={yFormula} cols.axis=0{at:X4}h cols.stride={step} cols.formula={xFormula}";

    // ---------------------------------------------------------------- the layout

    static readonly List<Field> All = Build();

    /// Every slot the layout fills, and where.
    public static IReadOnlyList<Field> Fields => All;

    static List<Field> Build()
    {
        var l = new List<Field>();
        void F(string slot, int a, string name, string spec, string desc = "") => l.Add(new(slot, a, name, spec, desc));
        void P(string slot, int a, string name, int count, string y, string x, string desc = "", int step = 2, string yType = "u8") =>
            l.Add(new(slot, a + 1, name, Pairs(a, count, y, x, step, yType), desc));
        void H(string slot, string label, string spec, string desc = "", int offset = 0) => l.Add(new(slot, offset, label, spec, desc, label));

        // --- closed loop
        F("closeloop.input", 0x5FDE, "O2Input", U8, "Where the O2 signal comes from: 0 ELD (D10), 1 EGR (D12), 2 B6, 3 O2 (D14).");
        F("closeloop.targetv", 0x6113, "CloseLoopTargetVolt", Volt, "Closed-loop target O2 voltage.");
        F("closeloop.maxload", 0x6112, "OpenloopMbar", Mbar, "Closed loop is off above this load.");
        F("closeloop.minect", 0x61D5, "CloseLoopECT", Ect, "Closed loop is off below this coolant temperature.");
        F("closeloop.maxo2v", 0x61D4, "CLMaxVoltage", Volt, "O2 voltage over this sets the MIL.");
        F("closeloop.o2heater.disable", 0x61F4, "O2Heater", OnZ, "O2 heater off (and its code 41).");
        F("closeloop.adjust.min", 0x6167, "CLSTFT", TrimW, "Most the closed-loop trim may take away.");
        F("closeloop.adjust.max", 0x6169, "CLSTFV", TrimW, "Most the closed-loop trim may add.");
        P("closeloop.tps.open", 0x63CA, "OpenLoopTPS", 6, "tps_pct", "rpm_axis_byte_log", "Open loop above this throttle, against rpm.");
        P("closeloop.tps.close", 0x63BE, "CloseLoopTPS", 6, "tps_pct", "rpm_axis_byte_log", "Closed loop below this throttle, against rpm.");
        F("closeloop.rate", 0x633E, "CloseLoopRate", "type=u16 count=4 formula=x/16 inverse=x*16 unit=%/s", "How fast the closed-loop trim moves.");
        F("closeloop.ve", 0x610F, "DisableVE", On, "VE correction off.");
        F("closeloop.ve.ect", 0x6110, "VE_ECT", Ect, "VE overheat correction above this coolant temperature.");
        F("closeloop.ve.fueldisable", 0x61F8, "CloseloopO2VE", On, "VE overheat fuel correction off.");
        P("closeloop.ve.table", 0x63B2, "VEFuelCorrect", 6, "trim_byte_pct", "honda_temp_c", "Fuel against coolant temperature once the VE overheat correction is in.");

        // --- cranking fuel
        P("crankfuel.ect", 0x6518, "CrankFuel", 9, "quarter", "honda_temp_c", "Cranking fuel against coolant temperature (the word / 4, as HTS shows it).", step: 3, yType: "u16");
        F("crankfuel.trim", 0x6103, "CrankT", TrimW, "Cranking fuel trim.");
        P("crankfuel.rpm", 0x6533, "CrankFuelComp", 2, "trim_signed_pct", "rpm_axis_byte", "Cranking fuel compensation against rpm.");
        P("crankfuel.map", 0x6537, "CrankFuelMap", 2, "trim_signed_pct", "map_sensor_preset_mbar", "Cranking fuel compensation against manifold pressure.");

        // --- fuel cut
        F("fuelcut.enable", 0x5FCA, "OFCEnable", OnZ, "Fuel cut on deceleration (FFh = off).");
        F("fuelcut.rpm", 0x5FD1, "FuelCutRPM", RpmL);
        F("fuelcut.tps", 0x61F7, "FuelCutTPS", Tps);
        F("fuelcut.load", 0x61F6, "FuelCutMAP", Mbar);
        F("fuelcut.vacuum.disable", 0x5FC5, "VacCut", On);
        F("fuelcut.vacuum.rpm", 0x5FC7, "VacCutRPM", RpmL);
        F("fuelcut.vacuum.tps", 0x5FC6, "VacCutTPS", Tps);
        P("fuelcut.resume.normal", 0x6549, "Overrun_Resume_nor", 7, "times_16", "honda_temp_c", "Fuel-cut resume against coolant temperature.");
        P("fuelcut.resume.initial", 0x653B, "Overrun_Resume_int", 7, "times_16", "honda_temp_c", "Fuel-cut resume against coolant temperature, first cut after start.");

        // --- tip in / out
        F("tipinout.tipin", 0x6109, "TipinT", TrimW);
        F("tipinout.shiftresponse", 0x5FD2, "TPSTipOutTrim", Trim128);
        F("tipinout.disable", 0x5FCE, "tpstipinrpm", RpmL);
        P("tipinout.normal", 0x645A, "Tipintempoffsetnormal", 6, "raw", "honda_temp_c", "Tip-in fuel against coolant temperature.", step: 3, yType: "u16");
        P("tipinout.initial", 0x646C, "Tipintempoffsetinitial", 6, "raw", "honda_temp_c", "Tip-in fuel against coolant temperature, first minutes after start.", step: 3, yType: "u16");

        // --- injectors
        F("injector.deadtime", 0x610D, "Deadtime", "type=u16 formula=x/8 inverse=x*8");
        F("injector.overall", 0x610B, "OverallFT", TrimW, "Overall fuel trim.");
        F("injector.crank", 0x6103, "CrankT", TrimW);
        F("injector.postfuel", 0x6105, "PostfuelT", TrimW);
        F("injector.tipin", 0x6109, "TipinT", TrimW);
        F("injector.multiplier", 0x6101, "INJ_MULT", "type=u16 formula=x/32768 inverse=x*32768 unit=x decimals=3", "Injector size multiplier (old / new).");
        P("injector.lag", 0x6442, "InjectorIndex", 7, "x*3.2/1000 inverse=x*1000/3.2 unit=ms", "battery_v", "Injector lag against battery voltage.", step: 3, yType: "u16");
        F("injector.hotlow", 0x6216, "InjectorTable", "type=u8 formula=570-x*15 inverse=(570-x)/15 unit=cc decimals=0");
        F("injector.hothigh", 0x6217, "InjectorTable_hothigh", "type=u8 formula=570-x*15 inverse=(570-x)/15 unit=cc decimals=0");
        F("injector.coldlow", 0x6219, "InjectorTable_coldlow", "type=u8 formula=570-x*15 inverse=(570-x)/15 unit=cc decimals=0");
        F("injector.coldhigh", 0x621A, "InjectorTable_coldhigh", "type=u8 formula=570-x*15 inverse=(570-x)/15 unit=cc decimals=0");
        F("injector.postdecay1", 0x62F3, "PostFuelDecay", "type=u16 count=4");
        F("injector.postdecay2", 0x62FB, "PostFuelDecay2", "type=u16 count=4");
        F("injector.postdecay3", 0x6303, "PostFuelDecay3", "type=u16 count=4");

        // --- flex fuel
        F("flexfuel.input", 0x61DE, "Flexinput", U8, "Analog input the ethanol sensor is on.");
        P("flexfuel.fuel", 0x5F8A, "EthanolComp", 6, "raw", "percent255", "Fuel against ethanol content.", step: 3, yType: "u16");
        P("flexfuel.ign", 0x5FA4, "EthanolAdvance", 6, "degrees_quarter", "percent255", "Advance against ethanol content.");

        // --- cylinder trims
        F("cyltrim.fuel", 0x6426, "CylinderIGNCorrect", "type=u8 count=4 formula=trim_byte_pct", "Fuel trim per cylinder (despite its name).");
        F("cyltrim.ign", 0x6134, "CylinderIgn", "type=u8 count=4 formula=ign_trim", "Timing trim per cylinder.");

        // --- dwell
        P("dwell.base", 0x6A56, "DwellBaseValues", 8, "x/16-1 inverse=(x+1)*16", "rpm_axis_byte");
        P("dwell.rpm", 0x6A7A, "DwellBaseRPM", 7, "quarter", "rpm_axis_byte");
        P("dwell.batt", 0x6A66, "DwellBattery", 10, "trim_byte_64_pct", "dwell_battery_v");

        // --- TPS tip-in retard
        P("tpsretard.base", 0x6B6A, "TipinRPM", 7, "-x/4 inverse=-x*4 unit=deg", "rpm_axis_byte_log");
        P("tpsretard.mintps", 0x6B5C, "TipinTPS", 7, "tps_pct", "rpm_axis_byte_log");
        P("tpsretard.tpsmul", 0x6B7D, "TipinRetard", 6, "x/128 inverse=x*128 unit=x", "tps_pct");
        F("tpsretard.gearmul", 0x6BA7, "TipinGear", "type=u8 count=5 formula=trim_byte_pct");
        F("tpsretard.duration", 0x6B78, "TipinEnrich_duration", "type=u8 count=5 formula=time_10ms", "Tip-in retard duration per gear.");
        F("tpsretard.rpm.min", 0x6025, "TipinRetardRpmMin", RpmL);
        F("tpsretard.rpm.max", 0x6026, "TipinRetardRpmMax", RpmL);
        F("tpsretard.speed.min", 0x6023, "TipinRetardVssMin", Vss);
        F("tpsretard.speed.max", 0x6024, "TipinRetardVssMax", Vss);
        F("tpsretard.ect", 0x6027, "TipinRetardEct", Ect);

        // --- idle ignition correction
        F("idleigncorr.enable", 0x6021, "idleigncheck", On);
        F("idleigncorr.ect", 0x6022, "IDLEignECT", Ect);

        // --- ECT / IAT corrections
        P("ectcorr.fuel", 0x622E, "ECTFuelCorrect", 9, "trim_byte_pct", "honda_temp_c");
        P("ectcorr.ign", 0x6A96, "ECTIgnCorrect", 10, "ign_trim", "honda_temp_c");
        P("ectcorr.poststart", 0x630B, "PostFuel", 9, "x/1024 inverse=x*1024", "honda_temp_c", step: 3, yType: "u16");
        l.Add(new("iatcorr.fuel", 0x62A3, "IATFuelCorrect",
            "type=u16 size=3x9 stride=27 colstride=3 formula=trim_word_pct cols.axis=062A2h cols.stride=3 cols.formula=honda_temp_c rows.values=1,2,3 rows.name=block",
            "Fuel against intake air temperature, three blocks."));
        P("iatcorr.ign", 0x6AB6, "IATCorrect", 9, "ign_trim", "honda_temp_c");

        // --- gear corrections
        F("gearcorr.fuel", 0x6129, "GearCorrectFuel_cells", "type=u8 count=5 formula=trim_byte_pct", "Fuel trim, gears 1-5.");
        F("gearcorr.ign", 0x612F, "GearCorrectIgn_cells", "type=u8 count=5 formula=ign_trim", "Timing trim, gears 1-5.");
        F("gearcorr.load", 0x5FC8, "GearCorrectMap", Mbar);
        F("gearcorr.speed", 0x6127, "GearCorrectVSS", Vss);

        // --- rev limits
        F("revlimit.igncut", 0x6125, "IGNCUT", On);
        F("revlimit.fuelcut", 0x6126, "FuelCut", OnZ);
        F("revlimit.warmect", 0x6013, "RevlimitWarmC", Ect);
        F("revlimit.low.reset", 0x6591, "RevLimitLowReset", RpmW);
        F("revlimit.low.set", 0x6597, "RevLimitLowSet", RpmW);
        F("revlimit.high.reset", 0x659D, "RevLimitHighReset", RpmW);
        F("revlimit.high.set", 0x65A3, "RevLimitHighSet", RpmW);
        F("revlimit.igndelay", 0x61D8, "IGNCDelay", X10);
        F("revlimit.launchdelay", 0x61E4, "LCDelay", X10);
        F("revlimit.ftsdelay", 0x61E5, "FTSDelay", X10);
        F("revlimit.mod", 0x5F89, "ICFuelMod", On, "Fuel enrichment and static timing while the ignition cut is on.");
        F("revlimit.enrich", 0x61E6, "IGNCFV", Fv);
        F("revlimit.staticign", 0x61E8, "IGNCDEG", Adv);
        H("revlimit.ceiling.gear", "LimitByGear", "type=u16 count=6 formula=rpm_period_word", "Rpm ceiling per gear 0-5 (12500 = none).");
        H("revlimit.ceiling.speed", "LimitBySpeed", "type=u16 count=5 colstride=3 formula=rpm_period_word cols.axis=LimitBySpeed cols.stride=3 cols.formula=speed_kmh_byte",
          "Rpm ceiling by road speed, falling km/h.", offset: 1);
        H("revlimit.swlimit.speed", "SwLimitSpeed", Vss, "Speed limiter by switch: cut at this speed while the input is on (255 = off).");
        H("revlimit.swlimit.input", "SwLimitInput", U8, "Speed limiter input: bit of the switch byte 3B0h.");
        H("revlimit.swlimit.invert", "SwLimitInvert", On1, "Speed limiter works while the input reads off.");

        // --- launch control (FTL)
        F("launch.input", 0x6152, "FTLInput", U8);
        F("launch.input.invert", 0x6153, "FTLInvert", On);
        F("launch.mode", 0x6155, "FTLMode", U8);
        F("launch.rpm", 0x6156, "FTLTPSMin", RpmW, "Launch rpm (memory based).");
        F("launch.minrpm", 0x6165, "FTLRPMMin", RpmW, "Minimum launch rpm (TPS based).");
        F("launch.speed", 0x6154, "FTLRPM", Vss, "Launch control works below this speed.");
        F("launch.tps.engage", 0x6158, "FTLTPSThresh", Tps);
        F("launch.tps.disengage", 0x61CF, "FTLTPSDisp", Tps);
        F("launch.antilag.enable", 0x6164, "EnableAntiLag", On);
        F("launch.antilag.tps", 0x6160, "AntiLagTPS", Tps);
        F("launch.antilag.enrich", 0x6161, "AntiLagFV", Fv);
        F("launch.antilag.retard", 0x6163, "AntiLagRetard", QDeg);
        F("launch.antilag.static", 0x6011, "AntiLagStatic", On);
        F("launch.antilag.staticdeg", 0x6010, "AntiLagRetardDegree", Adv);

        // --- full throttle shift (the code reads the cut rpm from FTLRPMTable, gear 0 when not gear based)
        F("fts.input", 0x6159, "FTL", U8);
        F("fts.input.invert", 0x615A, "FTSInvert", On);
        F("fts.cutrpm", 0x6004, "FTLRPMTable", RpmW, "FTS cut rpm (and the gear-0 entry of the per-gear table).");
        F("fts.tps", 0x6002, "FTLRPM2", Tps);
        F("fts.vss", 0x5FB3, "FTSVSS", Vss);
        F("fts.igndelay", 0x61D8, "IGNCDelay", X10);
        F("fts.strain", 0x61E4, "LCDelay_strain", On, "Strain cut delay (shares its byte with the launch cut delay).");
        F("fts.gearlimit", 0x6003, "GearBasedLimiter", On);
        F("fts.gear", 0x6006, "FTLRPMTable_gears", "type=u16 count=5 formula=rpm_period_word", "FTS cut rpm, gears 1-5.");
        F("fts.antilag", 0x5F58, "FTSAntiLag", On);
        F("fts.enrich", 0x5F56, "FTSAntiLagFV", Fv);
        F("fts.retard", 0x5F55, "FTSAntiLagRetard", QDeg);
        F("fts.static", 0x61EA, "FTSchkStatic", On);
        F("fts.staticdeg", 0x61E9, "FTSStaticIgn", Adv);

        // --- lean protection
        F("leanpro.minrpm", 0x5FDF, "LeanProMinRpm", RpmW);
        F("leanpro.mintps", 0x5FE1, "LeanProMinTps", Tps);
        F("leanpro.1.enable", 0x5FE3, "LeanProcheck1", On);
        F("leanpro.1.volts", 0x5FE5, "LeanProLean1AfrVolt", Volt);
        F("leanpro.1.duration", 0x5FE2, "LeanProLean1Tmr", X10);
        F("leanpro.1.load", 0x5FE4, "LeanProlean1Map", Mbar);
        F("leanpro.2.enable", 0x6034, "LeanProcheck2", On);
        F("leanpro.2.volts", 0x6036, "LeanProLean2AfrVolt", Volt);
        F("leanpro.2.duration", 0x5FE6, "LeanProLean2Tmr", X10);
        F("leanpro.2.load", 0x6035, "LeanProlean2Map", Mbar);

        // --- ECT protection
        F("ectpro.enable", 0x6068, "ECTProtectChk", On);
        F("ectpro.ect", 0x6069, "ECTProtectC", Ect);
        F("ectpro.rpm", 0x5FFB, "ECTProtectionTable", RpmW);

        // --- anti-start (HTS120; the 1.15 page is a stub)
        H("antistart.enable", "AntiStartEnable", On1, "Power up locked (fuel and spark cut) until A/C is on with the throttle past AntiStartTps.");
        H("antistart.tps", "AntiStartTps", Volt, "Throttle (TPS volts) that, with A/C on, unlocks anti-start.");

        // --- boost cut
        F("boostcut.enable", 0x6150, "BoostchkEnable", On);
        F("boostcut.dtc", 0x615D, "BoostcutOnMil", On);
        F("boostcut.hot", 0x615E, "ctrlBoostCutHot", Mbar);
        F("boostcut.cold", 0x6151, "ctrlBoostCutCold", Mbar);
        F("boostcut.ect", 0x615F, "BoostCutECT", Ect);

        // --- electronic boost control
        F("ebc.input", 0x6170, "EBCPWM", U8);
        F("ebc.input.invert", 0x6171, "EBCPWMInvert", On);
        F("ebc.hilo.input", 0x6172, "EBCPWMhi", U8);
        F("ebc.hilo.input.invert", 0x6173, "EBCPWMhiInvert", On);
        F("ebc.output", 0x6198, "bstPWMOutput", U8);
        F("ebc.dial", 0x6033, "bstDial", U8);
        F("ebc.frequency", 0x5FF9, "bstPWMHZ", U16, "PWM period word (HTS: 8, 15, 20, 25, 31 or 40 Hz).");
        F("ebc.duty.min", 0x602B, "bstPWMMin", Duty);
        F("ebc.duty.max", 0x6199, "bstPWMMax", Duty);
        F("ebc.pwmmode", 0x6197, "bstPWMMode", On);
        F("ebc.fixedduty", 0x6178, "bstTargetMode", Duty, "Fixed duty (0 = use the tables).");
        F("ebc.rpmmode", 0x617D, "bstRPMMode", On);
        F("ebc.closeloop", 0x617E, "bstCloseLoop", OnZ);
        F("ebc.fastspool", 0x6177, "FastSpool", Duty);
        F("ebc.active", 0x6175, "EBCMapActive", Mbar);
        F("ebc.wastegate", 0x6176, "EBCWasteGate", Mbar);
        F("ebc.disabledtc", 0x619B, "DuelMapEnable", OnZ, "PWM off on a DTC or lean condition.");
        F("ebc.cl.min", 0x615B, "BoostLimitMode1", Half, "Closed loop: most duty taken away (undershoot).");
        F("ebc.cl.max", 0x615C, "bstCloseLoopmin", Half, "Closed loop: most duty added (overshoot).");
        F("ebc.cl.overshoot", 0x617B, "bstOvershootSens", X10);
        F("ebc.cl.undershoot", 0x617C, "bstUndershootSen", X10);
        F("ebc.cl.deadband", 0x617A, "bstDeadBand", U8);
        P("ebc.lookup", 0x6079, "WasteGateLookup", 11, "duty_half_pct", "map_sensor_preset_psi");
        P("ebc.gear", 0x608F, "wastegateGEAR", 11, "map_sensor_preset_psi", "raw");
        P("ebc.rpm", 0x60A5, "wastegateRPM", 11, "half_step_signed", "rpm_axis_byte");
        P("ebc.iat", 0x60BB, "wastegateIAT", 5, "half_step_signed", "honda_temp_c");
        F("ebc.gearlow", 0x6180, "WGGearLow_cells", "type=u8 count=5 formula=map_sensor_preset_psi");
        F("ebc.gearhigh", 0x6186, "WGGearHi_cells", "type=u8 count=5 formula=map_sensor_preset_psi");

        // --- manual boost
        F("boostmanual.input", 0x61C0, "ManualBstInput1", U8);
        F("boostmanual.input.invert", 0x61C1, "ManualBstInput1invert", On);
        F("boostmanual.nodtc", 0x61C2, "ManualBstchkMil", On);
        F("boostmanual.nocut", 0x61C3, "ManualBstchkFtl", On);
        F("boostmanual.2.speed", 0x61CB, "Stage2Vss", Vss);
        F("boostmanual.3.speed", 0x61CC, "Stage3Vss", Vss);
        F("boostmanual.4.speed", 0x61CD, "Stage4Vss", Vss);

        // --- idle
        F("idle.rpm", 0x6117, "TargetIdle", RpmW);
        F("idle.iacverror.disable", 0x6116, "Dcode14", On);
        F("idle.iacv.duty", 0x6114, "IdleDC", "type=s16", "IACV duty offset (HTS: -10240 to +10240).");
        F("idle.iacv.dutyac", 0x5FCF, "IdleAC", "type=s16", "IACV duty offset with the A/C on (the code reads it here; 1.15's page writes a byte later).");
        l.Add(new("idle.target", 0x6739, "IdleVsECT",
            "type=u16 size=2x7 stride=21 colstride=3 formula=rpm_period_word cols.axis=06738h cols.stride=3 cols.formula=honda_temp_c rows.values=1,2 rows.name=set",
            "Idle target against coolant temperature (two sets)."));
        F("idle.ign.low", 0x6AFC, "IgnControl", "type=u16 count=4 colstride=4", "Low idle ignition control (4-byte entries).");
        F("idle.ign.high", 0x6AEC, "HiIdleIgnControl", "type=u16 count=4 colstride=4", "High idle ignition control (4-byte entries).");

        // --- VTEC
        F("vtec.enable", 0x61F2, "VtecEnable", On);
        F("vtec.nospeed", 0x6209, "VtecVSSCheck", On);
        F("vtec.notemp", 0x611F, "VtecTempCheck", On);
        F("vtec.nopressure", 0x6123, "VTPS", On);
        F("vtec.noerror", 0x611E, "DCode21", On);
        F("vtec.minect", 0x6120, "VtecECTMin", Ect);
        F("vtec.minspeed", 0x6122, "VtecVSSMin", Vss);
        F("vtec.minload", 0x6121, "VtecLoadMin", Mbar);
        F("vtec.tps.high", 0x6657, "VtecSettings", Tps, "VTEC high-load throttle.");
        F("vtec.rpm.high", 0x6658, "VtecSettings_rpmhigh", RpmL);
        F("vtec.tps.low", 0x6659, "VtecSettings_tpslow", Tps);
        F("vtec.rpm.low", 0x665A, "VtecSettings_rpmlow", RpmL);
        F("vtec.alt.enable", 0x5FFF, "ALTVtecEnable", On);
        F("vtec.alt.output", 0x6000, "AltVtecOutput", U8);
        F("vtec.alt.invert", 0x6001, "AltVtecInvert", On);

        // --- IAB
        F("iab.enable", 0x6215, "IABCheck", On);
        F("iab.usdm", 0x6201, "IABVEnable", On);
        F("iab.disengage", 0x6119, "IABValues", RpmL);
        F("iab.engage", 0x611A, "IABValues_set", RpmL);
        F("iab.invert", 0x6037, "IABInvert", On);
        F("iab.alt.output", 0x5FF7, "IABSelection", U8);
        F("iab.alt.invert", 0x5FF8, "IABoutinvert", On);

        // --- fan
        F("fan.enable", 0x616D, "FANChk", On);
        F("fan.ect", 0x616E, "FANECT", Ect);
        F("fan.speed", 0x61EB, "FANVSS", Vss);
        F("fan.output", 0x616F, "FANOUT", U8);
        F("fan.invert", 0x61BF, "FANINVERT", On);

        // --- A/C
        F("ac.disable", 0x619A, "DisableAC", On);
        F("ac.cutoff.enable", 0x613A, "chkAcCut", On);
        F("ac.cutoff.rpm", 0x613B, "ACCutRPM", RpmW);
        F("ac.cutoff.tps", 0x613D, "ACCutTPS", Tps);
        F("ac.cutoff.speed", 0x61EC, "ACCVSSMax", Vss);
        F("ac.idlecut", 0x613E, "IdleCut", RpmW);
        F("ac.idleresume", 0x6140, "IdleRes", RpmW);

        // --- MIL shift light
        F("shiftlight.enable", 0x6142, "MILShiftLight", On);
        F("shiftlight.gearbased", 0x6143, "MILShiftLightGear", On);
        F("shiftlight.rpm", 0x6144, "MILShiftLightRPM", RpmW);
        F("shiftlight.gear", 0x6146, "MILShiftLightIndex", "type=u16 count=5 formula=rpm_period_word", "Shift rpm, gears 1-5.");

        // --- burnout
        F("burnout.input", 0x5FD7, "BURNOUT", U8);
        F("burnout.input.invert", 0x5FD8, "BURNOUTINVERT", On);
        F("burnout.rpm", 0x5FD5, "BURNOUTRPM", RpmW);

        // --- traction control (HTS120, from engine speed)
        H("tc.rpmrate.enable", "TcEnable", On1, "Traction control from engine speed alone.");
        H("tc.rpmrate.sample", "TcSampleTicks", "type=u8 formula=(x+1)*10 inverse=x/10-1 unit=ms decimals=0", "How long each rpm rise is measured over.");
        H("tc.rpmrate.speed", "TcMinSpeed", Vss, "Traction control stays out below this road speed.");
        H("tc.rpmrate.tps", "TcMinTps", Volt, "Traction control stays out below this throttle (TPS volts).");
        H("tc.rpmrate.limit", "TcRateByGear", "type=u8 count=6 formula=x*8 inverse=x/8 unit=rpm decimals=0", "Allowed rpm rise per sample, gear 0-5 (0 = TC off in that gear).");
        H("tc.rpmrate.attack", "TcAttack", QDeg, "Retard added each sample the rise is over the limit.");
        H("tc.rpmrate.max", "TcMaxRetard", QDeg, "Most traction control retard.");
        H("tc.rpmrate.decay", "TcDecay", QDeg, "Retard taken back each sample the rise is under the limit.");

        // --- maps indexing
        F("mapindex.loadindex", 0x6032, "LoadIndex", U8);
        F("mapindex.alpha.tps100", 0x602C, "AlphaN", Tps);
        F("mapindex.alpha.map100", 0x602D, "AlphaN_map100", Mbar);
        F("mapindex.alpha.tps0", 0x602E, "AlphaN_tps0", Tps);
        F("mapindex.alpha.map0", 0x602F, "AlphaN_map0", Mbar);
        F("mapindex.crosstps", 0x6030, "AlphaNTpsCross", Tps);
        F("mapindex.crossmap", 0x6031, "AlphaNMapCross", Mbar);
        F("mapindex.highcamonly", 0x61A6, "chkHighCamOnly", On);
        F("mapindex.secondaryonly", 0x61A8, "SecondaryMapsOnly", On);

        // --- secondary maps
        F("dualmap.mode", 0x619C, "DuelMap", U8);
        F("dualmap.input", 0x619D, "DuelMapinput", U8);
        F("dualmap.input.invert", 0x619E, "DuelMapinvert", On);
        F("dualmap.chkrpm", 0x619F, "DuelMapchkRpm", On);
        F("dualmap.rpm", 0x61A0, "DuelMapRPM", RpmW);
        F("dualmap.chktps", 0x61A4, "DuelMapchkTps", On);
        F("dualmap.tps", 0x61A5, "DuelMapTPS", Tps);
        F("dualmap.chkload", 0x61A2, "DuelMapchkLoad", On);
        F("dualmap.load", 0x61A3, "DuelMapLoad", Mbar);

        // --- TPS sensor
        F("tpssensor.custom", 0x6200, "CustomTPS", On);
        F("tpssensor.max", 0x6203, "TPSSettings", Volt, "TPS volts at 100%.");
        F("tpssensor.min", 0x6205, "TPSSettings_min", Volt, "TPS volts at 0%.");

        // --- transmission
        F("transmission.preset", 0x6213, "GearPresetIndex", U8);
        F("transmission.ratio", 0x664F, "GearCustom", "type=u16 count=4", "Custom gear ratio words.");
        H("vss.correction", "SpeedCorrection", "type=u16 formula=x*100/32768 inverse=x*32768/100 unit=%", "Road speed scale: 100% reads as measured.");

        // --- service connector / misc
        F("scc.input", 0x6138, "SCCInput", U8);
        F("scc.input.invert", 0x6139, "SCCInvert", On);
        F("scc.fuelpump", 0x61A7, "FPMode", U8);
        F("scc.prime", 0x606A, "FPPrimeT", "type=u8 formula=time_tenth_s");
        F("scc.milflashes", 0x6020, "MILFlashCount", U8);
        F("scc.ignlock.enable", 0x5FD4, "Lockigndeg", On);
        F("scc.ignlock.deg", 0x6202, "Lockdeg", Adv);

        // --- general purpose outputs 1-3 (GIO in these ROMs)
        foreach (var (n, g) in new[] {
            (1, new[] { 0x61AA, 0x61AB, 0x61AC, 0x61AD, 0x61AE, 0x61AF, 0x61B0, 0x61B1, 0x61B2, 0x61B4, 0x61B6, 0x61B7, 0x61B8, 0x61B9, 0x61BA, 0x61BB, 0x61BC, 0x61BE, 0x61BD }),
            (2, new[] { 0x603B, 0x603C, 0x603D, 0x603E, 0x603F, 0x6040, 0x6041, 0x6042, 0x6043, 0x6045, 0x6047, 0x6048, 0x6049, 0x604A, 0x604B, 0x604C, 0x604D, 0x604F, 0x604E }),
            (3, new[] { 0x6050, 0x6051, 0x6052, 0x6053, 0x6054, 0x6055, 0x6056, 0x6057, 0x6058, 0x605A, 0x605C, 0x605D, 0x605E, 0x605F, 0x6060, 0x6061, 0x6062, 0x6064, 0x6063 }) })
        {
            string p = $"gpo{n}", gio = $"GIO{n}";
            F($"{p}.enable", g[0], $"{gio}Enable", On);
            F($"{p}.output", g[1], $"{gio}Output", U8);
            F($"{p}.output.invert", g[2], $"{gio}OutInvert", On);
            F($"{p}.input", g[3], $"{gio}Input", U8);
            F($"{p}.input.invert", g[4], $"{gio}InInvert", On);
            F($"{p}.nocut", g[5], $"{gio}DisableLimiters", On);
            F($"{p}.nomil", g[6], $"{gio}chkMil", On);
            F($"{p}.secondary", g[7], $"{gio}chkMaps", On);
            F($"{p}.rpm.min", g[8], $"{gio}RpmMin", RpmW);
            F($"{p}.rpm.max", g[9], $"{gio}RpmMax", RpmW);
            F($"{p}.load.min", g[10], $"{gio}MapMin", Mbar);
            F($"{p}.load.max", g[11], $"{gio}MapMax", Mbar);
            F($"{p}.ect.min", g[12], $"{gio}EctMin", Ect);
            F($"{p}.ect.max", g[13], $"{gio}EctMax", Ect);
            F($"{p}.iat.min", g[14], $"{gio}IATMin", Ect);
            F($"{p}.iat.max", g[15], $"{gio}IATMax", Ect);
            F($"{p}.speed.min", g[16], $"{gio}VSSMin", Vss);
            F($"{p}.speed.max", g[17], $"{gio}VSSMax", Vss);
            F($"{p}.tps", g[18], $"{gio}TPS", Tps);
        }
        l.Add(new("gpo1.fuel", 0x60DC, "GIOAdjustment2",
            "type=u16 count=11 colstride=3 formula=trim_word_pct cols.axis=060DBh cols.stride=3 cols.formula=rpm_axis_byte", "Fuel while GPO 1 is on, against rpm."));
        P("gpo1.retard", 0x60C5, "GIOAdjustment1", 11, "ign_trim", "rpm_axis_byte", "Timing while GPO 1 is on, against rpm.");

        // --- ROM options
        F("romoptions.dtc30", 0x61F3, "AutoA", OnZ);
        F("romoptions.dtc20", 0x620E, "DCode20", OnZ);
        F("romoptions.dtc13", 0x61F5, "chkBaro", OnZ);
        F("romoptions.dtc16", 0x61F9, "DCode16", On);
        F("romoptions.vecorr", 0x610F, "DisableVE", On);
        F("romoptions.igncorrload", 0x611B, "DisableIGNMAP", On);
        F("romoptions.igncorrload.value", 0x611C, "IGNMAP", Mbar);
        F("romoptions.starter", 0x606B, "DisableStarterIN", On);
        F("romoptions.purge", 0x616B, "DisablePurge", On);
        F("romoptions.purgeinvert", 0x616C, "PurgeInvert", On);
        F("romoptions.dtc14", 0x6116, "Dcode14", On);
        F("romoptions.dtc22", 0x6123, "VTPS", On);
        F("romoptions.dtc21", 0x611E, "DCode21", On);
        F("romoptions.closeloop", 0x6111, "CloseloopO2", On);
        F("romoptions.closeloopOnly", 0x61F8, "CloseloopO2VE", On);
        F("romoptions.dtc41", 0x61F4, "O2Heater", OnZ);
        F("romoptions.autotranny", 0x620B, "DisableAuto", OnZ);
        F("romoptions.altc", 0x61CE, "DisableAltC", On);
        F("romoptions.debug", 0x620A, "Debug", On);
        return l;
    }

    /// The code-patch options: the byte (or bytes) HTS finds by a pattern in the code and rewrites. Found by searching the ROM, as HTS does, so they follow the code wherever a build put it.
    static readonly (string Slot, byte[] Pattern, int Offset, string Name, string Spec, string Desc)[] CodePatches =
    [
        ("romoptions.dtc7", [17, 68, 21, 137, 119], 5, "DisableTpsCode", On, "Code 7 (TPS) check off (a byte in the code)."),
        ("romoptions.dtc9", [197, 181, 25, 180, 52], 12, "DisableCypCode", "type=u8 flag=1 on=216 off=232", "Code 9 (CYP) check off (an opcode in the code: D8h = off, E8h = on)."),
        ("romoptions.dtc36", [239, 51, 3, 196, 50], 9, "DisableTcsCode", "type=u16 flag=1 on=52117 off=5853", "Code 36 (traction control) check off (a 3-byte patch: 95 CB 1D off, DD 16 1C on)."),
        ("romoptions.dtc36", [239, 51, 3, 196, 50], 11, "DisableTcsCode_b3", "type=u8 flag=1 on=29 off=28", "Third byte of the code 36 patch."),
        ("romoptions.dtc31", [203, 1, 149, 197, 179], 6, "DisableAutoBCode", "type=u16 flag=1 on=52117 off=5853", "Code 31 (automatic transmission B) check off (95 CB 28 off, DD 16 14 on)."),
        ("romoptions.dtc31", [203, 1, 149, 197, 179], 8, "DisableAutoBCode_b3", "type=u8 flag=1 on=40 off=20", "Third byte of the code 31 patch."),
        ("romoptions.dtc6", [196, 48, 29, 197, 176], 7, "ErrorchkECT", "type=u8 flag=1 on=255 off=0", "Code 6 (ECT) check off; the ECU then uses the fixed ECT below."),
        ("romoptions.dtc6.value", [213, 217, 163, 28, 203], 9, "ErrorECTValue", Ect, "Coolant temperature used while code 6 is off."),
        ("romoptions.dtc6.value", [213, 218, 98, 209, 3], 15, "ErrorECTValue2", Ect, "Coolant temperature used while code 6 is off (second copy)."),
        ("romoptions.dtc10", [196, 25, 46, 197, 176], 7, "ErrorchkIAT", "type=u8 flag=1 on=255 off=0", "Code 10 (IAT) check off; the ECU then uses the fixed IAT below."),
        ("romoptions.dtc10.value", [196, 25, 46, 197, 176], 16, "ErrorIATValue", Ect, "Intake air temperature used while code 10 is off."),
        ("romoptions.dtc10.value", [213, 218, 98, 209, 3], 11, "ErrorIATValue2", Ect, "Intake air temperature used while code 10 is off (second copy)."),
        ("romoptions.dtc17", [196, 28, 44, 197, 177], 8, "ErrorchkVSS", "type=u8 flag=1 on=255 off=0", "Code 17 (VSS) check off; the ECU then uses the fixed speed below."),
        ("romoptions.dtc17.value", [196, 28, 44, 197, 177], 12, "ErrorVSSValue", Vss, "Road speed used while code 17 is off."),
    ];

    // ---------------------------------------------------------------- detection and binding

    /// An HTS ROM carries "HONDATUNESUITE" after its version bytes (1.15: 7FEFh = 1, 1, 5).
    public static bool IsHts(byte[] rom)
    {
        var sig = Encoding.ASCII.GetBytes("HONDATUNESUITE");
        for (int i = 0x7F00; i + sig.Length <= Math.Min(rom.Length, 0x8000); i++)
            if (rom.AsSpan(i, sig.Length).SequenceEqual(sig)) return true;
        return false;
    }

    /// The HTS version the signature says (115 for 1.15), or 0.
    public static int Version(byte[] rom) =>
        IsHts(rom) && rom.Length >= 0x7FF2 ? (rom[0x7FEF] * 100) + (rom[0x7FF0] * 10) + rom[0x7FF1] : 0;

    /// Which layout of the HTS family a ROM has: 1.15 (and HTS120), the earlier one (HTS 1.00-1.14, original eCtune ROMs, and eCtune-format ROMs made by other tuning software), or the P13 base ROM. Found the way HTS-master finds it: the version digits at 7FEFh with the suite's signature, or the eCtune signature word at 7FEFh / 7FF1h.
    public enum Family { None, Hts115, Older, P13 }

    public static (Family Layout, string Name) Identify(byte[] rom)
    {
        if (rom.Length < 0x8000) return (Family.None, "");
        int v = Version(rom);
        if (v is 115 or 120) return (Family.Hts115, $"HTS {v / 100}.{v % 100:00}");
        if (v == 116) return (Family.P13, "HTS P13 base ROM (1.16)");
        if (v is >= 100 and < 115) return (Family.Older, $"HTS {v / 100}.{v % 100:00}");
        // a base ROM of the same family without the suite's name: its version as three digits at 7FEFh and a text of its
        // maker's in the last bytes (HTS-master takes the last byte 'e', or "ITE" / "ple" before it)
        bool digits = rom[0x7FEF] <= 9 && rom[0x7FF0] <= 9 && rom[0x7FF1] <= 9;
        bool tail = rom[0x7FFF] == (byte)'e' || (rom[0x7FFD] == (byte)'I' && rom[0x7FFE] == (byte)'T' && rom[0x7FFF] == (byte)'E');
        int bv = (rom[0x7FEF] * 100) + (rom[0x7FF0] * 10) + rom[0x7FF1];
        if (digits && tail && bv is >= 100 and < 200)
            return bv switch
            {
                115 or 120 => (Family.Hts115, $"base ROM {bv / 100}.{bv % 100:00}"),
                116 => (Family.P13, $"P13 base ROM {bv / 100}.{bv % 100:00}"),
                _ => (Family.Older, $"base ROM {bv / 100}.{bv % 100:00}"),
            };
        int W(int a) => rom[a] | (rom[a + 1] << 8);
        if (W(0x7FF1) == 0xA974)
        {
            if (W(0x7FEF) == 0x4365) return (Family.Older, "an original eCtune ROM");
            if (W(0x7FEF) == 0x4D62) return (Family.Older, $"an eCtune-format ROM from other tuning software (version {rom[0x7FF7]}.{rom[0x7FF8]}.{rom[0x7FF9]})");
        }
        return (Family.None, "");
    }

    /// What kind of ROM this is, for the status line when it is opened: the HTS family (with its layout), a Crome ROM, the custom1 base, or an OBD0 image (a different ECU). Signatures as HTS-master tells them apart (bytes 0210h-0212h, the first reset vectors). Empty when none of these.
    public static string Describe(byte[] rom)
    {
        if (rom.Length < 0x8000) return "";
        var (layout, name) = Identify(rom);
        if (layout != Family.None) return name + (layout == Family.Hts115 ? "" : " - its settings are read with that version's layout");
        (byte, byte, byte) sig = (rom[0x210], rom[0x211], rom[0x212]);
        string? crome = sig switch
        {
            (137, 198, 171) => "Crome Gold", (212, 26, 2) => "Crome P28", (46, 249, 125) => "Crome P30", (228, 248, 162) => "Crome P72",
            (41, 15, 201) or (196, 170, 152) => "Crome P13", (16, 138, 196) => "custom1", _ => null,
        };
        if (crome != null) return $"a {crome} ROM - Detect finds its maps by lining it up with the known ROMs";
        bool obd0 = rom[6] == 143 && rom[7] == 0 && ((rom[0] == 58 && rom[1] == 25) || (rom[0] == 216 && rom[1] == 22) || (rom[0] == 115 && rom[1] == 22))
                    || (rom[2] == 0 && rom[3] == 192 && rom[4] == 224 && rom[5] == 192 && rom[6] == 131 && rom[7] == 192);
        return obd0 ? "an OBD0 ROM - a different ECU from the OKI 66207 this app simulates: it will not run here" : "";
    }

    /// Where a 1.15 address is in a ROM of this layout, or null when that layout has no such setting.
    static int? Place(Family layout, int addr) => layout switch
    {
        Family.Hts115 => addr,
        Family.Older => OlderAddress.TryGetValue(addr, out var o) ? o : null,
        Family.P13 => P13Address.TryGetValue(addr, out var p) ? p : null,
        _ => null,
    };

    /// Define, type, scale and bind every page row the layout knows, on an HTS 1.15 (or HTS120) ROM. The layout is authoritative: a row it fills is taken off whatever it was bound to before, and a definition already at the address is retyped to what the page needs. Returns the rows bound (0 when the ROM is not HTS 1.15).
    public static int Apply(DefinitionSet defs, byte[] rom)
    {
        var layout = Identify(rom).Layout;
        if (layout == Family.None) return 0;
        MapFormulas(defs, rom);
        var pages = CalPage.All();
        string CategoryOf(string slot) =>
            pages.FirstOrDefault(p => p.Slots().Any(s => s.Equals(slot, StringComparison.OrdinalIgnoreCase)))?.Name ?? "HTS";

        var fields = new List<Field>(All);
        foreach (var (slot, pattern, offset, name, spec, desc) in CodePatches)
            if (Find(rom, pattern) is int at) fields.Add(new(slot, at + offset, name, spec, desc));

        // what the layout itself has put at an address in this run, so two readings of one byte get two definitions
        var claimed = new Dictionary<int, (ItemDef Item, string Spec)>();
        var cleared = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        int bound = 0;
        int patchesFrom = All.Count;      // the fields after the fixed ones were found by their code: already where they are
        for (int n = 0; n < fields.Count; n++)
        {
            var f = fields[n];
            int addr = f.Address;
            var spec = f.Spec;
            if (f.Label != null)
            {
                if (!defs.Symbols.TryGetValue(f.Label, out int at)) continue;
                addr = at + f.Address;
            }
            else if (n < patchesFrom && layout != Family.Hts115)
            {
                // an earlier layout: the setting's own address, and any address in its spec (an axis), where that layout has them
                if (Place(layout, addr) is not int moved) continue;
                addr = moved;
                bool missing = false;
                spec = System.Text.RegularExpressions.Regex.Replace(spec, @"\b0([0-9A-Fa-f]{4})h\b", m =>
                {
                    int a = int.Parse(m.Groups[1].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
                    if (Place(layout, a) is int b) return $"0{b:X4}h";
                    missing = true; return m.Value;
                });
                if (missing) continue;
            }
            if (addr < 0 || addr >= rom.Length) continue;
            var template = DefinitionBuilder.Parse(spec, defs, addr);
            if (template == null) continue;

            ItemDef? item;
            if (claimed.TryGetValue(addr, out var c))
                item = c.Spec == f.Spec ? c.Item : null;
            else
                item = defs.Items.FirstOrDefault(i => i.Address == addr && i.Name.Equals(f.Name, StringComparison.OrdinalIgnoreCase))
                       ?? defs.Items.FirstOrDefault(i => i.Address == addr);
            // something only detected there (a guess, or a name from another ROM) takes HTS's name for the field
            if (item != null && !claimed.ContainsKey(addr) && item.Origin?.StartsWith("detected") == true
                && !item.Name.Equals(f.Name, StringComparison.OrdinalIgnoreCase) && defs.Find(f.Name) == null)
                item.Name = f.Name;
            if (item == null)
            {
                // a code patch is named for what it does, not after the routine it sits in
                bool inCode = addr < 0x5F00;
                item = new ItemDef { Address = addr, Name = UniqueName(defs, addr, f.Name, claimed.ContainsKey(addr) || inCode), Category = CategoryOf(f.Slot) };
                defs.Items.Add(item);
            }
            Shape(item, template);
            if (item.Description.Length == 0 || f.Desc.Length > 0) item.Description = f.Desc.Length > 0 ? f.Desc : item.Description;
            claimed.TryAdd(addr, (item, f.Spec));

            // the layout's answer replaces any earlier binding of the row (once per row: a row can be several definitions)
            if (cleared.Add(f.Slot))
                foreach (var other in defs.Items) other.RemoveSlots(s => s.Equals(f.Slot, StringComparison.OrdinalIgnoreCase));
            item.AddSlot(f.Slot);
            bound++;
        }
        defs.Items.Sort((x, y) => x.Address.CompareTo(y.Address));
        ScaleFromLayout(defs, rom);
        DefinitionBuilder.IndexAxes(defs);
        return bound;
    }

    /// Give a scaling to the definitions of an HTS-family ROM that have none (raw), from how HTS-master reads the field at that address. Returns how many got one.
    public static int ScaleFromLayout(DefinitionSet defs, byte[] rom)
    {
        var layout = Identify(rom).Layout;
        if (layout == Family.None) return 0;
        int n = 0;
        foreach (var (addr, (type, formula)) in FieldFormulas)
        {
            if (Place(layout, addr) is not int at) continue;
            foreach (var item in defs.Items.Where(i => i.Address == at && i.Text == null && !i.Flag && i.Type != CellType.Bit
                                                     && i.Formula is null or "raw" or "x"))
            {
                bool word = item.Type is CellType.U16 or CellType.S16;
                if (word != (type == "u16")) continue;          // read another way than HTS reads it: leave it
                item.Formula = formula;
                n++;
            }
        }
        return n;
    }

    static void Shape(ItemDef item, ItemDef t)
    {
        item.Type = t.Type; item.Bit = t.Bit;
        item.Rows = t.Rows; item.Cols = t.Cols; item.Stride = t.Stride; item.ColStride = t.ColStride;
        item.Formula = t.Formula; item.RowAxis = t.RowAxis; item.ColAxis = t.ColAxis;
        item.Flag = t.Flag; item.OnRaw = t.OnRaw; item.OffRaw = t.OffRaw;
        item.Min = t.Min; item.Max = t.Max; item.ColumnScaleAddress = null;
    }

    /// The label at the address when there is one (so the ";@" line lands on it), else the HTS field name.
    static string UniqueName(DefinitionSet defs, int addr, string name, bool second)
    {
        if (!second)
        {
            var label = defs.Symbols.Where(kv => kv.Value == addr).Select(kv => kv.Key)
                            .FirstOrDefault(k => defs.Find(k) == null);
            if (label != null) return label;
        }
        if (defs.Find(name) == null && !defs.Symbols.ContainsKey(name)) return name;
        return $"{name}_{addr:X4}";
    }

    static int? Find(byte[] rom, byte[] pattern)
    {
        for (int i = 0; i + pattern.Length <= rom.Length; i++)
            if (rom.AsSpan(i, pattern.Length).SequenceEqual(pattern)) return i;
        return null;
    }

    /// byteToMillibar depends on the ROM's MAP sensor preset (60FCh): 0 = stock scale offset by the fuel-cut byte, 1 = stock, 2 = the custom high / low calibration words (stored + 32768). The formula is built from this ROM's own bytes, as HTS does every time it shows a pressure.
    static void MapFormulas(DefinitionSet defs, byte[] rom)
    {
        static string N(double v) => v.ToString("0.#####", CultureInfo.InvariantCulture);
        int W(int a) => rom[a] | (rom[a + 1] << 8);
        string expr, inverse;
        switch (rom[0x60FC])
        {
            case 0:
                expr = $"(floor(x / 2) + {rom[0x61F6]}) * 7.221 - 59"; inverse = $"((x + 59) / 7.221 - {rom[0x61F6]}) * 2"; break;
            case 1:
                expr = "x * 7.221 - 59"; inverse = "(x + 59) / 7.221"; break;
            default:
                double hi = W(0x60FD) - 32768.0, lo = W(0x60FF) - 32768.0, span = lo - hi;
                if (Math.Abs(span) < 1) span = 1;
                string plus = hi < 0 ? $"- {N(-hi)}" : $"+ {N(hi)}", minus = hi < 0 ? $"+ {N(-hi)}" : $"- {N(hi)}";
                expr = $"x * {N(span)} / 255 {plus}"; inverse = $"(x {minus}) * 255 / {N(span)}"; break;
        }
        Put(defs, new FormulaDef { Name = "map_sensor_preset_mbar", Expr = expr, Inverse = inverse, Unit = "mBar", Decimals = 0, Notes = "HTS byteToMillibar for this ROM's MAP preset" });
        // mapToPsi against a 1013 mBar sea level, as HTS's wastegate pages show it
        Put(defs, new FormulaDef
        {
            Name = "map_sensor_preset_psi", Expr = $"(({expr}) - 1013) * 0.0145038", Inverse = inverse.Replace("x", "(x / 0.0145038 + 1013)"),
            Unit = "psi", Decimals = 1, Notes = "HTS mapToPsi(byteToMillibar(x)), sea level 1013 mBar",
        });
    }

    static void Put(DefinitionSet defs, FormulaDef f)
    {
        defs.Formulas.RemoveAll(x => x.Name == f.Name);
        defs.Formulas.Add(f);
    }
}
