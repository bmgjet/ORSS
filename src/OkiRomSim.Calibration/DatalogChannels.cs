// Copyright (c) bmgjet. All rights reserved.

namespace OkiRomSim.Calibration;

/// What the skeleton ROM's channel stream (p30-features/dlstream.asm) can send: every value a logger can tick on or off. A channel is one or more bytes of the ROM's channel table (dl_channels); its number there is fixed, so this list and that table must agree. Version 1 ROMs take RAM addresses instead (70h, at most 8 bytes), and the status bytes (FF0xh) have no address, so those channels need version 2. A word (rpm, injector time) is read in one go by the ROM, its low byte then its high byte, so it is always a fast channel: as a slow one its two bytes would come a frame apart.
public sealed record DatalogChannel(string Key, string Name, string Group, string Unit, int[] Numbers, int[] Addresses,
    Action<LogFrame, byte[]> Decode, string Description = "", bool Slow = false, bool Word = false)
{
    public int Bytes => Numbers.Length;
    public bool NeedsVersion2 => Addresses.Any(a => a >= 0xFF00 || a == 0);
    /// The ROM version the channel needs: its channel numbers came in with it (the table only grows).
    public int MinVersion => Numbers.Any(n => n >= 40) ? 4 : Numbers.Any(n => n >= 35) ? 3 : NeedsVersion2 ? 2 : 1;
}

/// A channel picked for the stream: every frame (fast), or in turn with the other slow ones, one a frame.
public readonly record struct StreamPick(DatalogChannel Channel, bool Slow);

/// One of the ECU's serial inputs fed from the log while the channel stream runs (the serial inputs module): the input number (00h-FDh), the frame's channel it is taken from (the wideband's "afr", an aux channel...), and value = channel x scale + offset, held to 0-254. AFR x 10 fits a byte (14.7 -> 147).
public sealed record SerialInputMap(int Input, string Channel, double Scale = 1, double Offset = 0, bool Enabled = true)
{
    static readonly System.Globalization.CultureInfo Inv = System.Globalization.CultureInfo.InvariantCulture;

    public double ValueFrom(LogFrame f) => f.Get(Channel) is double v && !double.IsNaN(v) ? Math.Clamp(Math.Round(v * Scale + Offset), 0, 254) : double.NaN;

    /// "input|channel|scale|offset|on", as the settings keep it.
    public string Save() => string.Join("|", Input.ToString(Inv), Channel, Scale.ToString(Inv), Offset.ToString(Inv), Enabled ? "1" : "0");

    public static SerialInputMap? Parse(string s)
    {
        var p = s.Split('|');
        if (p.Length < 2 || !int.TryParse(p[0], System.Globalization.NumberStyles.Integer, Inv, out var input) || input is < 0 or > 0xFD) return null;
        double D(int i, double d) => p.Length > i && double.TryParse(p[i], System.Globalization.NumberStyles.Float, Inv, out var v) ? v : d;
        return new(input, p[1].Trim(), D(2, 1), D(3, 0), p.Length <= 4 || p[4] != "0");
    }
}

public static class DatalogChannels
{
    /// The ROM's table, channel number -> address: dl_channels in dlstream.asm, less its 4000h / 2000h word flags. Channels 23-24 (the module fuel trim), 49-51 and the serial inputs (40-48) are in module RAM, which moves with the stock trouble codes: the ROM's own table always has the right one, and version 2 on asks by number, so only a version 1 request would need it (those are 0 here: version 2 and up).
    public static readonly int[] RomTable =
    [
        0x0AC, 0x0AD, 0x0A3, 0x0B9, 0x0C1, 0x0C0, 0x0C3, 0x0B4, 0x0A4, 0x3BE,
        0x3C6, 0x146, 0x147, 0x246, 0x0A7, 0x2FE, 0xFF01, 0xFF02, 0xFF03, 0x0C8,
        0x0C9, 0x2FD, 0x2FC, 0x3F8, 0x3F9, 0x1F0, 0x0FC, 0x1F1, 0x0FD, 0x020,
        0x022, 0x23B, 0x2F7, 0x067, 0x069, 0xFF04, 0x31A, 0x31B, 0x31C, 0x31D,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0x1F6,
        // 53-131: the "every channel" module (dlextra.asm). 1000h-1007h are the RAM addresses picked in the ROM (DatalogUserAddress).
        0x138, 0x14A, 0x14B, 0x13C, 0x13D, 0x144, 0x145, 0x14C, 0x14D, 0x150,
        0x151, 0x156, 0x15A, 0x15B, 0x15C, 0x15D, 0x15E, 0x16F, 0x16D, 0x16E,
        0x171, 0x173, 0x174, 0x175, 0x1E6, 0x1E7, 0x1EC, 0x23A, 0x23C, 0x23D,
        0x23E, 0x23F, 0x238, 0x245, 0x254, 0x24A, 0x24B, 0x258, 0x259, 0x274,
        0x275, 0x27E, 0x27F, 0x290, 0x294, 0x158, 0x159, 0x11F, 0x128, 0x11C,
        0x1F2, 0x1F3, 0x1F4, 0x1F5, 0x12D, 0x12C, 0x0E9, 0x0A0, 0x111, 0x116,
        0x117, 0x118, 0x119, 0x11D, 0x123, 0x124, 0x125, 0x126, 0x216, 0x217,
        0x227, 0x1000, 0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1006, 0x1007,
        // 132-187: every byte of module RAM (where it is moves with the stock trouble codes: 0 here, the ROM's own table has it)
        .. new int[ModuleDebug.Bytes],
    ];

    /// How many channel numbers the ROM's table has (version 4) without the "every channel" module, and with it.
    public const int TableSize = 53;
    public const int TableSizeAll = 188;

    /// The limiter modules, by their bit in lib.asm's cut-request words (MB_...).
    public static readonly string[] Limiters =
        ["revlimit", "launch", "fts", "burnout", "boostcut", "ectpro", "antistart", "speedlimit", "ceiling", "leanpro", "traction", "gearlimit", "watermark"];

    static double RpmLog(int x) => Math.Pow(2, x / 64) * (500 + (7.8125 * (x % 64)));
    static int W(byte[] b) => b[0] | (b[1] << 8);
    static DatalogChannel Raw(string key, string name, string group, int n, string desc, string unit = "") =>
        C(key, name, group, unit, [n], (f, b) => f.Extra[key] = b[0], desc, slow: true);
    static DatalogChannel RawW(string key, string name, string group, int n, string desc) =>
        C(key, name, group, "", [n, n + 1], (f, b) => f.Extra[key] = W(b), desc, word: true);
    /// A flag byte: named for what it holds, each bit the stock code uses a channel of its own under its own name (FlagNames).
    static DatalogChannel Flags(int n, int addr, string copy = "")
    {
        var fb = FlagNames.Bytes[addr];
        var bits = fb.Bits.Where(x => x != null).Select(x => x!.Value.Key).ToList();
        return C($"flags{addr:x3}", fb.Name + copy, fb.Group, "", [n], (f, b) => FlagNames.Decode(f, addr, b[0]),
            $"{fb.About} Each bit is a channel of its own: {string.Join(", ", bits)}.", slow: true);
    }

    static DatalogChannel C(string key, string name, string group, string unit, int[] numbers, Action<LogFrame, byte[]> decode, string desc = "", bool slow = false, bool word = false) =>
        new(key, name, group, unit, numbers, [.. numbers.Select(n => RomTable[n])], decode, desc, slow, word);

    static void Bit(LogFrame f, string key, byte b, int bit) => f.Extra[key] = (b >> bit) & 1;

    public static readonly DatalogChannel[] All =
    [
        C("rpm", "Rpm", "Engine", "rpm", [0, 1], (f, b) => { int p = b[0] | (b[1] << 8); f.Rpm = p == 0 || p == 0xFFFF ? 0 : Math.Round(1875000.0 / p); }, "From the crank period (two bytes, read together).", word: true),
        C("map", "MAP", "Engine", "kPa", [2], (f, b) => f.MapKpa = Math.Round(HondaDatalog.MapKpa(b[0]), 1)),
        C("load", "Map load", "Engine", "mbar", [14], (f, b) => f.Extra["load_mbar"] = Math.Round(b[0] * 3.6105 + 114.3), "The load byte the fuel and ignition maps are looked up on."),
        C("tps", "Throttle", "Engine", "%", [3], (f, b) => f.TpsPct = Math.Round(HondaDatalog.TpsPct(b[0]), 1)),
        C("ect", "Coolant", "Engine", "°C", [4], (f, b) => f.EctC = HondaDatalog.ThermistorC(b[0]), slow: true),
        C("iat", "Intake air", "Engine", "°C", [5], (f, b) => f.IatC = HondaDatalog.ThermistorC(b[0]), slow: true),
        C("baro", "Barometric pressure", "Engine", "kPa", [8], (f, b) => f.BaroKpa = Math.Round(HondaDatalog.MapKpa((byte)Math.Min(255, b[0] / 2 + 24)), 1), slow: true),
        C("batt", "Battery", "Electrical", "V", [6], (f, b) => f.BattV = Math.Round(26.0 * b[0] / 270.0, 2), slow: true),
        C("eld", "Electrical load (ELD)", "Electrical", "V", [10], (f, b) => f.Extra["eld_v"] = Math.Round(HondaDatalog.Volts(b[0]), 2), slow: true),
        C("speed", "Road speed", "Engine", "km/h", [7], (f, b) => f.SpeedKmh = b[0]),
        C("gear", "Gear", "Engine", "", [15], (f, b) => f.Extra["gear"] = b[0], "Needs gear detection (FEAT_GEAR).", slow: true),
        C("o2", "O2 sensor", "Fuel", "V", [9], (f, b) => f.O2V = Math.Round(HondaDatalog.Volts(b[0]), 3)),
        C("inj", "Injector time", "Fuel", "ms", [11, 12], (f, b) => f.InjMs = Math.Round((b[0] | (b[1] << 8)) * 3.2 / 1000, 2), word: true),
        C("fueltrim", "Module fuel trim", "Fuel", "%", [23, 24], (f, b) => f.Extra["fuel_trim_pct"] = Math.Round((short)(b[0] | (b[1] << 8)) * 100.0 / 256, 1), "Every module's fuel trim added up.", word: true),
        C("fuelcut", "Fuel cut request", "Fuel", "", [25], (f, b) => f.Extra["fuel_cut"] = b[0] != 0 ? 1 : 0),
        C("pump", "Fuel pump", "Fuel", "", [18], (f, b) => f.FuelPump = (b[0] & 1) != 0, slow: true),
        C("alphan", "Alpha-N load", "Fuel", "mbar", [32], (f, b) => f.Extra["alphan_mbar"] = Math.Round(b[0] * 3.6105 + 114.3), "Needs maps indexing (FEAT_ALPHAN)."),
        C("adv", "Ignition advance", "Ignition", "°", [13], (f, b) => f.IgnDeg = b[0] * 0.25 - 6),
        C("retard", "Module retard", "Ignition", "°", [21], (f, b) => f.Extra["mod_retard_deg"] = b[0] * 0.25),
        C("advreq", "Module advance", "Ignition", "°", [22], (f, b) => f.Extra["mod_advance_deg"] = b[0] * 0.25),
        C("igntrim", "Module timing trims", "Ignition", "°", [49, 50], (f, b) => f.Extra["ign_trim_deg"] = Math.Round((short)(b[0] | (b[1] << 8)) * 0.25, 2), "Every module's timing trim added up (+ advance).", word: true),
        C("igncorr", "Ignition correction", "Ignition", "", [31], (f, b) => f.Extra["ign_correction"] = b[0], "The correction the stock code adds against rpm and coolant (raw).", slow: true),
        C("sparkcut", "Spark cut request", "Ignition", "", [26], (f, b) => f.Extra["spark_cut"] = b[0] != 0 ? 1 : 0),
        C("vtec", "VTEC solenoid", "Outputs", "", [16], (f, b) => f.Vtec = ((b[0] >> 3) & 1) != 0),
        C("switches", "Switches (park, brake, A/C)", "Inputs", "", [17], (f, b) => { Bit(f, "park_neutral", b[0], 0); Bit(f, "brake", b[0], 1); Bit(f, "ac_request", b[0], 2); }, slow: true),
        C("p0", "Outputs P0 (A/C clutch, fan, alternator...)", "Outputs", "", [29], (f, b) =>
        {
            f.Extra["ac_clutch"] = (b[0] & 1) == 0 ? 1 : 0; Bit(f, "purge", b[0], 1); Bit(f, "alt_control", b[0], 2); Bit(f, "radiator_fan", b[0], 3);
            Bit(f, "at_lockup", b[0], 4);
        }, "The P0 latch: bit 0 A/C clutch (low = on), 1 purge, 2 alternator control, 3 radiator fan, 4 A/T lock-up, 7 fuel pump (low = on).", slow: true),
        C("p1", "Outputs P1 (check-engine lamp, LED, O2 heater)", "Outputs", "", [30], (f, b) => { Bit(f, "o2_heater", b[0], 2); Bit(f, "cel", b[0], 4); Bit(f, "ecu_led", b[0], 5); }, slow: true),
        C("iacv", "Idle valve duty", "Idle", "", [19, 20], (f, b) => f.Extra["iacv_duty"] = b[0] | (b[1] << 8), "The idle valve duty word (raw).", word: true),
        C("boostduty", "Boost solenoid duty", "Modules", "%", [51], (f, b) => f.Extra["boost_duty_pct"] = Math.Min(100, b[0] * 4), "The P4.3 boost solenoid's duty (EBC, manual boost)."),
        C("modout", "Module outputs", "Modules", "", [27], (f, b) =>
        {
            Bit(f, "iab", b[0], 0); Bit(f, "rpm_switch", b[0], 1); Bit(f, "warn_lamp", b[0], 2);
            for (int i = 0; i < 4; i++) Bit(f, $"gio{i + 1}", b[0], 4 + i);
        }, "IAB, rpm switch, warning lamp and GIO 1-4 states.", slow: true),
        C("modflags", "Module flags", "Modules", "", [28], (f, b) => { Bit(f, "second_maps", b[0], 0); Bit(f, "anti_stall", b[0], 2); }, slow: true),
        C("modflags2", "Module flags 2", "Modules", "", [52], (f, b) => { Bit(f, "antistart_locked", b[0], 0); }, "Anti-start locked.", slow: true),
        C("egr_in", "EGR input (analog)", "Inputs", "V", [33], (f, b) => f.Extra["egr_in_v"] = Math.Round(HondaDatalog.Volts(b[0]), 3), "Used by a wideband or a flex sensor wired there."),
        C("b6_in", "B6 input (analog)", "Inputs", "V", [34], (f, b) => f.Extra["b6_in_v"] = Math.Round(HondaDatalog.Volts(b[0]), 3)),
        .. Enumerable.Range(0, 8).Select(i => C($"serin{i + 1}", $"Serial input {i + 1}", "Serial inputs", "", [40 + i], (f, b) => f.Extra[$"serin{i + 1}"] = b[0],
            "What the ECU holds for it (the serial inputs module): the value last sent, 0-254.", slow: true)),
        C("serinage", "Serial inputs: time since one came", "Serial inputs", "s", [48], (f, b) => { if (b[0] != 255) f.Extra["serin_age_s"] = Math.Round(b[0] * 0.032768, 2); },
            "The ECU's own count: past the timeout the inputs read as their defaults.", slow: true),
        C("service", "Service state", "Diagnostics", "", [35], (f, b) =>
        {
            Bit(f, "svc_injectors_off", b[0], 0); Bit(f, "svc_timing_locked", b[0], 1); Bit(f, "svc_maps_chosen", b[0], 2); Bit(f, "svc_second_maps", b[0], 3);
            for (int i = 0; i < 4; i++) Bit(f, $"svc_gio{i + 1}", b[0], 4 + i);
        }, "What the service commands have set: injectors off, timing locked, the maps chosen, GIO forced on (ROM version 3).", slow: true),
        C("codes", "Trouble codes", "Diagnostics", "", [36, 37, 38, 39], (f, b) => { for (int i = 0; i < 4; i++) f.Extra[$"dtc{i}"] = b[i]; },
            "The stored trouble codes, one bit per code (needs the stock trouble codes built in: FEAT_STOCK_DTC; ROM version 3).", slow: true),

        // ---- the "every channel" module (dlextra.asm)
        C("cuts", "Fuel cut: why", "Limiters and cuts", "", [102], (f, b) =>
        {
            Bit(f, "fuel_cut", b[0], 2); Bit(f, "overrun_cut", b[0], 4); Bit(f, "rev_limit", b[0], 5);
        }, "The fuel cut and why: rev_limit (the rev limiter, or a limiter module, is cutting), overrun_cut (closed throttle on overrun), fuel_cut (any cut). RAM 11Ch.", slow: false),
        C("limiters", "Limiters cutting", "Limiters and cuts", "", [103, 104, 105, 106], (f, b) =>
        {
            int fuel = b[0] | (b[1] << 8), spark = b[2] | (b[3] << 8);
            f.Extra["limit_fuel_bits"] = fuel; f.Extra["limit_spark_bits"] = spark;
            for (int i = 0; i < Limiters.Length; i++) f.Extra["limit_" + Limiters[i]] = ((fuel | spark) >> i) & 1;
        }, "Which limiter module wants a cut, fuel or spark: limit_revlimit, limit_launch, limit_fts, limit_boostcut, limit_ectpro, limit_traction... (lib.asm's request words 1F2h / 1F4h).", slow: false),
        C("fuelmap", "Fuel map value", "Fuel corrections", "", [53], (f, b) => f.Extra["fuel_map"] = b[0],
            "The fuel map's value at this rpm and load, before any correction (RAM 138h)."),
        RawW("poststart", "Post-start fuel", "Fuel corrections", 54, "The extra fuel after a start as it decays (RAM 14Ah)."),
        C("deadtime", "Injector dead time", "Fuel corrections", "ms", [56, 57], (f, b) => f.Extra["dead_time_ms"] = Math.Round(W(b) * 3.2 / 1000, 3),
            "The time added to every pulse for the injector to open, from the battery voltage (RAM 13Ch).", word: true),
        RawW("fuelect", "Coolant fuel correction", "Fuel corrections", 58, "The injector correction against coolant temperature (RAM 144h)."),
        RawW("fueliat", "Intake air fuel correction", "Fuel corrections", 60, "The multiplier on the pulse against intake air temperature (RAM 14Ch)."),
        RawW("fuelknock", "Knock fuel correction", "Fuel corrections", 62, "The fuel multiplier for the knock level (RAM 150h)."),
        Raw("fuelbaro2", "Baro fuel correction 2", "Fuel corrections", 64, "Fuel against barometric pressure, with the injector corrections (RAM 156h)."),
        Raw("warmup1", "Warm-up fuel 1", "Fuel corrections", 65, "RAM 15Ah."),
        Raw("warmup2", "Warm-up fuel 2", "Fuel corrections", 66, "Used by the acceleration fuel (RAM 15Bh)."),
        Raw("warmup3", "Warm-up fuel 3", "Fuel corrections", 67, "RAM 15Ch."),
        Raw("warmup4", "Warm-up fuel 4", "Fuel corrections", 68, "RAM 15Dh."),
        Raw("warmup6", "Warm-up fuel 6", "Fuel corrections", 69, "RAM 15Eh."),
        Raw("warmup5", "Warm-up fuel 5", "Fuel corrections", 70, "On the pulse width (RAM 16Fh)."),
        Raw("accelfuel", "Acceleration fuel", "Fuel corrections", 71, "Acceleration fuel against coolant temperature (RAM 16Dh)."),
        Raw("fuelbaro", "Baro fuel correction", "Fuel corrections", 72, "RAM 16Eh."),
        Raw("fuelbaro3", "Baro fuel correction 3", "Fuel corrections", 73, "On the pulse width (RAM 171h)."),
        Raw("accello", "Acceleration fuel scale (low rpm)", "Fuel corrections", 74, "Below 2000 rpm (RAM 173h)."),
        Raw("accelhi", "Acceleration fuel scale", "Fuel corrections", 75, "RAM 174h."),
        Raw("tipinscale", "Tip-in fuel scale", "Fuel corrections", 76, "RAM 175h."),
        RawW("tipinect", "Tip-in against coolant", "Fuel corrections", 77, "RAM 1E6h."),
        Raw("accellimit", "Acceleration fuel limit", "Fuel corrections", 79, "RAM 1ECh."),
        Raw("igniat", "Ignition: intake air correction", "Ignition corrections", 80, "RAM 23Ah."),
        Raw("igntps", "Ignition: throttle correction", "Ignition corrections", 81, "RAM 23Ch."),
        Raw("igncold", "Ignition: cold correction", "Ignition corrections", 82, "Against rpm when cold (RAM 23Dh)."),
        Raw("ignrpmretard", "Ignition: rpm retard", "Ignition corrections", 83, "RAM 23Eh."),
        C("knockretard", "Knock retard", "Ignition corrections", "°", [84], (f, b) => f.Extra["knock_retard_deg"] = b[0] / 4.0,
            "Timing taken out for knock (RAM 23Fh; needs the stock knock control built in).", slow: true),
        Raw("knockretard2", "Knock retard 2", "Ignition corrections", 85, "RAM 238h."),
        Raw("ignrpmcorr", "Ignition: rpm correction", "Ignition corrections", 86, "Added to the final advance (RAM 245h)."),
        Raw("knockect", "Knock control against coolant", "Ignition corrections", 87, "RAM 254h."),
        Raw("dwellrpm", "Dwell against rpm", "Ignition corrections", 88, "RAM 24Ah."),
        Raw("dwellbatt", "Dwell against battery", "Ignition corrections", 89, "RAM 24Bh."),
        C("idletarget", "Idle target", "Idle", "rpm", [90, 91], (f, b) => { int w = W(b); if (w > 0) f.Extra["idle_target_rpm"] = Math.Round(1875000.0 / w); },
            "The idle speed the ECU aims for now (RAM 258h).", word: true),
        RawW("idledecel", "Idle air on deceleration", "Idle", 92, "RAM 274h."),
        RawW("idleiat", "Idle air against intake air", "Idle", 94, "RAM 27Eh."),
        Raw("idlebaro", "Idle baro correction", "Idle", 96, "RAM 290h."),
        C("idlerpm", "Idle rpm threshold", "Idle", "rpm", [97], (f, b) => f.Extra["idle_threshold_rpm"] = Math.Round(RpmLog(b[0])), "RAM 294h.", slow: true),
        Raw("vtecload", "VTEC: load needed", "VTEC", 98, "The stock VTEC points' load needed at this rpm (RAM 158h)."),
        Raw("vtecbaro", "VTEC: baro offset", "VTEC", 99, "RAM 159h."),
        C("vtecstate", "VTEC state", "VTEC", "", [100, 101], (f, b) =>
        {
            Bit(f, "vtec_engaged", b[0], 2); Bit(f, "vtec_above_point1", b[1], 1); Bit(f, "vtec_above_point2", b[1], 2);
            f.Extra["vtec_state_byte"] = b[0]; f.Extra["vtec_points_byte"] = b[1];
        }, "vtec_engaged (the high cam asked for), and whether the rpm is past the stock VTEC points (RAM 11Fh, 128h)."),
        C("rpmindex", "Map rpm index", "Engine state", "", [107], (f, b) => { f.Extra["rpm_index"] = b[0]; f.Extra["rpm_index_rpm"] = Math.Round(RpmLog(b[0])); },
            "The rpm byte the maps and VTEC points are read with (RAM 12Dh)."),
        Raw("loadindex", "Map load index", "Engine state", 108, "The load byte the maps are read with (RAM 12Ch)."),
        C("sincestart", "Time since start", "Engine state", "s", [109], (f, b) => f.Extra["since_start_s"] = b[0] / 10.0,
            "Counts tenths of a second after a start, to 25.5 s (RAM 0E9h; VTEC waits for 5 s).", slow: true),
        Flags(110, 0x0A0),
        Flags(111, 0x111),
        Flags(112, 0x116, " (main loop copy)"),
        Flags(113, 0x117, " (main loop copy)"),
        Flags(114, 0x118),
        Flags(115, 0x119),
        Flags(116, 0x11D),
        Flags(117, 0x123),
        Flags(118, 0x124),
        Flags(119, 0x125),
        Flags(120, 0x126),
        Flags(121, 0x216),
        Flags(122, 0x217),
        Flags(123, 0x227),
        .. Enumerable.Range(0, 8).Select(i => C($"ram{i + 1}", $"RAM address {i + 1}", "Your RAM addresses", "", [124 + i], (f, b) => { if (UserRam.Key(i) is { } k) f.Extra[k] = b[0]; },
            $"The RAM byte picked in DatalogUserAddress {i + 1} (the ROM's Datalog page): any of 80h-47Fh. Logged under its address and what the memory map says is there (ram_0b4_road_speed).", slow: true)),
        // the functions' own state: every byte of module RAM, named from the build open (ModuleDebug)
        .. Enumerable.Range(0, ModuleDebug.Bytes).Select(i => C($"mod{i}", $"Function state +{i}", "Functions (debug)", "", [ModuleDebug.FirstChannel + i],
            (f, b) => ModuleDebug.Decode(f, i, b[0]),
            "A byte of module RAM, where the functions keep their state: the Channels window says which function's and what it is (from the ROM built here).", slow: true)),
    ];

    /// Every channel the ROM can send ("Everything" in the Channels window): the usual fast ones every frame, the rest in turn.
    public static readonly string[] FastWhenEverything = ["rpm", "map", "tps", "inj", "adv", "speed", "cuts", "limiters"];

    public static List<string> Everything(int tableSize) =>
        [.. All.Where(c => c.Numbers.All(n => n < tableSize)).Select(c => Pick(c.Key, !FastWhenEverything.Contains(c.Key) && !c.Word))];

    /// What a fresh setup logs: the channels the stream always used to.
    public static readonly string[] Defaults = ["rpm", "map", "tps", "ect:slow", "iat:slow", "batt:slow", "speed"];

    public static DatalogChannel? Find(string key) => All.FirstOrDefault(c => c.Key.Equals(key, StringComparison.OrdinalIgnoreCase));

    /// A saved pick: "rpm" every frame, "ect:slow" in turn with the other slow ones.
    public static (string Key, bool Slow) Parse(string pick)
    {
        int c = pick.IndexOf(':');
        return c < 0 ? (pick, false) : (pick[..c], pick[(c + 1)..].Equals("slow", StringComparison.OrdinalIgnoreCase));
    }

    public static string Pick(string key, bool slow) => slow ? key + ":slow" : key;

    /// The picks as channels, in catalogue order. A word is never slow (its two bytes would come a frame apart).
    public static List<StreamPick> Picks(IEnumerable<string> picks)
    {
        var want = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in picks) { var (k, s) = Parse(p); want[k] = s; }
        return [.. All.Where(c => want.ContainsKey(c.Key)).Select(c => new StreamPick(c, want[c.Key] && !c.Word))];
    }

    /// The chosen channels in catalogue order, dropped past what fits: `most` bytes, and only what the ROM's version has (version 1: no status bytes). For the version 1-3 lists, which send every channel every frame: the fast ones first, then the slow ones while there is room.
    public static List<DatalogChannel> Fit(IEnumerable<string> keys, int most, bool version2) => Fit(keys, most, version2 ? 2 : 1);

    public static List<DatalogChannel> Fit(IEnumerable<string> keys, int most, int version)
    {
        var picks = Picks(keys);
        var list = new List<DatalogChannel>();
        int bytes = 0;
        foreach (var p in picks.Where(p => !p.Slow).Concat(picks.Where(p => p.Slow)))
        {
            var c = p.Channel;
            if (c.MinVersion > version || bytes + c.Bytes > most) continue;
            list.Add(c); bytes += c.Bytes;
        }
        // in catalogue order, as the frame carries them
        return [.. All.Where(list.Contains)];
    }

    /// One frame's length on the line (version 4): A5h, the tick, the fast bytes, the slow channel's number and byte when there are any, the checksum.
    public static int FrameBytes(IEnumerable<StreamPick> picks)
    {
        var l = picks.ToList();
        return 4 + l.Where(p => !p.Slow).Sum(p => p.Channel.Bytes) + (l.Any(p => p.Slow) ? 2 : 0);
    }

    /// What the ECU sends a second, whatever the line could carry (38400 baud is 3840): it holds its serial interrupt off while its crank task runs, so about this many (measured in the simulator at 3000 rpm). Fewer bytes a frame is more frames.
    public const double EcuBytesPerSecond = 870;

    /// Frames a second, and how often each slow byte comes round.
    public static (double FramesPerSecond, double SlowEverySeconds) Rate(IEnumerable<StreamPick> picks, double bytesPerSecond = EcuBytesPerSecond)
    {
        var l = picks.ToList();
        double fps = bytesPerSecond / FrameBytes(l);
        int slowBytes = l.Where(p => p.Slow).Sum(p => p.Channel.Bytes);
        // past what the list and the masks carry (channels 56 and up), the slow ones are a range: every channel in it comes round
        var slowNums = l.Where(p => p.Slow).SelectMany(p => p.Channel.Numbers).ToList();
        if (l.Sum(p => p.Channel.Bytes) + 1 > 16 && l.Any(p => p.Channel.Numbers.Any(n => n >= 56)) && slowNums.Count > 0)
            slowBytes = slowNums.Max() - slowNums.Min() + 1;
        return (fps, slowBytes == 0 ? 0 : slowBytes / fps);
    }
}
