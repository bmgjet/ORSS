// Copyright (c) bmgjet. All rights reserved.

namespace OkiRomSim.Calibration;

/// What the skeleton ROM's channel stream (p30-features/datalog.asm) can send: every value a logger can tick on or off. A channel is one or two bytes of the ROM's channel table (dl_channels, the 73h list); its number there is fixed, so this list and that table must agree. Version 1 ROMs take RAM addresses instead (70h, at most 8 bytes), and the status bytes (FF0xh) have no address, so those channels need version 2.
public sealed record DatalogChannel(string Key, string Name, string Group, string Unit, int[] Numbers, int[] Addresses,
    Action<LogFrame, byte[]> Decode, string Description = "")
{
    public int Bytes => Numbers.Length;
    public bool NeedsVersion2 => Addresses.Any(a => a >= 0xFF00);
    /// The ROM version the channel needs: its channel numbers came in with it (the table only grows).
    public int MinVersion => Numbers.Any(n => n >= 35) ? 3 : NeedsVersion2 ? 2 : 1;
}

public static class DatalogChannels
{
    /// The ROM's table, channel number -> address: dl_channels in datalog.asm. Channels 23-24 (the module fuel trim) are lib.asm's MOD_FUELSUM, which is 31Ah without the stock trouble codes and 3F8h with them: the ROM's own table always has the right one, and version 2 asks by number, so only a version 1 request would need it.
    public static readonly int[] RomTable =
    [
        0x0AC, 0x0AD, 0x0A3, 0x0B9, 0x0C1, 0x0C0, 0x0C3, 0x0B4, 0x0A4, 0x3BE,
        0x3C6, 0x146, 0x147, 0x246, 0x0A7, 0x2FE, 0xFF01, 0xFF02, 0xFF03, 0x0C8,
        0x0C9, 0x2FD, 0x2FC, 0x3F8, 0x3F9, 0x1F0, 0x0FC, 0x1F1, 0x0FD, 0x020,
        0x022, 0x23B, 0x2F7, 0x067, 0x069, 0xFF04, 0x31A, 0x31B, 0x31C, 0x31D,
    ];

    static DatalogChannel C(string key, string name, string group, string unit, int[] numbers, Action<LogFrame, byte[]> decode, string desc = "") =>
        new(key, name, group, unit, numbers, [.. numbers.Select(n => RomTable[n])], decode, desc);

    static void Bit(LogFrame f, string key, byte b, int bit) => f.Extra[key] = (b >> bit) & 1;

    public static readonly DatalogChannel[] All =
    [
        C("rpm", "Rpm", "Engine", "rpm", [0, 1], (f, b) => { int p = b[0] | (b[1] << 8); f.Rpm = p == 0 || p == 0xFFFF ? 0 : Math.Round(1875000.0 / p); }, "From the crank period (two bytes)."),
        C("map", "MAP", "Engine", "kPa", [2], (f, b) => f.MapKpa = Math.Round(HondaDatalog.MapKpa(b[0]), 1)),
        C("load", "Map load", "Engine", "mbar", [14], (f, b) => f.Extra["load_mbar"] = Math.Round(b[0] * 3.6105 + 114.3), "The load byte the fuel and ignition maps are looked up on."),
        C("tps", "Throttle", "Engine", "%", [3], (f, b) => f.TpsPct = Math.Round(HondaDatalog.TpsPct(b[0]), 1)),
        C("ect", "Coolant", "Engine", "°C", [4], (f, b) => f.EctC = HondaDatalog.ThermistorC(b[0])),
        C("iat", "Intake air", "Engine", "°C", [5], (f, b) => f.IatC = HondaDatalog.ThermistorC(b[0])),
        C("baro", "Barometric pressure", "Engine", "kPa", [8], (f, b) => f.BaroKpa = Math.Round(HondaDatalog.MapKpa((byte)Math.Min(255, b[0] / 2 + 24)), 1)),
        C("batt", "Battery", "Electrical", "V", [6], (f, b) => f.BattV = Math.Round(26.0 * b[0] / 270.0, 2)),
        C("eld", "Electrical load (ELD)", "Electrical", "V", [10], (f, b) => f.Extra["eld_v"] = Math.Round(HondaDatalog.Volts(b[0]), 2)),
        C("speed", "Road speed", "Engine", "km/h", [7], (f, b) => f.SpeedKmh = b[0]),
        C("gear", "Gear", "Engine", "", [15], (f, b) => f.Extra["gear"] = b[0], "Needs gear detection (FEAT_GEAR)."),
        C("o2", "O2 sensor", "Fuel", "V", [9], (f, b) => f.O2V = Math.Round(HondaDatalog.Volts(b[0]), 3)),
        C("inj", "Injector time", "Fuel", "ms", [11, 12], (f, b) => f.InjMs = Math.Round((b[0] | (b[1] << 8)) * 3.2 / 1000, 2)),
        C("fueltrim", "Module fuel trim", "Fuel", "%", [23, 24], (f, b) => f.Extra["fuel_trim_pct"] = Math.Round((short)(b[0] | (b[1] << 8)) * 100.0 / 256, 1), "Every module's fuel trim added up."),
        C("fuelcut", "Fuel cut request", "Fuel", "", [25], (f, b) => f.Extra["fuel_cut"] = b[0] != 0 ? 1 : 0),
        C("pump", "Fuel pump", "Fuel", "", [18], (f, b) => f.FuelPump = (b[0] & 1) != 0),
        C("alphan", "Alpha-N load", "Fuel", "mbar", [32], (f, b) => f.Extra["alphan_mbar"] = Math.Round(b[0] * 3.6105 + 114.3), "Needs maps indexing (FEAT_ALPHAN)."),
        C("adv", "Ignition advance", "Ignition", "°", [13], (f, b) => f.IgnDeg = b[0] * 0.25 - 6),
        C("retard", "Module retard", "Ignition", "°", [21], (f, b) => f.Extra["mod_retard_deg"] = b[0] * 0.25),
        C("advreq", "Module advance", "Ignition", "°", [22], (f, b) => f.Extra["mod_advance_deg"] = b[0] * 0.25),
        C("igncorr", "Ignition correction", "Ignition", "", [31], (f, b) => f.Extra["ign_correction"] = b[0], "The correction the stock code adds against rpm and coolant (raw)."),
        C("sparkcut", "Spark cut request", "Ignition", "", [26], (f, b) => f.Extra["spark_cut"] = b[0] != 0 ? 1 : 0),
        C("vtec", "VTEC solenoid", "Outputs", "", [16], (f, b) => f.Vtec = ((b[0] >> 3) & 1) != 0),
        C("switches", "Switches (park, brake, A/C)", "Inputs", "", [17], (f, b) => { Bit(f, "park_neutral", b[0], 0); Bit(f, "brake", b[0], 1); Bit(f, "ac_request", b[0], 2); }),
        C("p0", "Outputs P0 (A/C clutch, purge, alternator...)", "Outputs", "", [29], (f, b) =>
        {
            f.Extra["ac_clutch"] = (b[0] & 1) == 0 ? 1 : 0; Bit(f, "purge", b[0], 1); Bit(f, "at_lockup", b[0], 4); Bit(f, "alt_control", b[0], 5);
        }, "The P0 latch: bit 0 A/C clutch (low = on), 1 purge, 4 A/T lock-up, 5 alternator control."),
        C("p1", "Outputs P1 (check-engine lamp, LED, O2 heater)", "Outputs", "", [30], (f, b) => { Bit(f, "o2_heater", b[0], 2); Bit(f, "cel", b[0], 4); Bit(f, "ecu_led", b[0], 5); }),
        C("iacv", "Idle valve duty", "Idle", "", [19, 20], (f, b) => f.Extra["iacv_duty"] = b[0] | (b[1] << 8), "The idle valve duty word (raw)."),
        C("modout", "Module outputs", "Modules", "", [27], (f, b) =>
        {
            Bit(f, "iab", b[0], 0); Bit(f, "rpm_switch", b[0], 1); Bit(f, "warn_lamp", b[0], 2);
            for (int i = 0; i < 4; i++) Bit(f, $"gio{i + 1}", b[0], 4 + i);
        }, "IAB, rpm switch, warning lamp and GIO 1-4 states."),
        C("modflags", "Module flags", "Modules", "", [28], (f, b) => { Bit(f, "second_maps", b[0], 0); Bit(f, "anti_stall", b[0], 2); }),
        C("egr_in", "EGR input (analog)", "Inputs", "V", [33], (f, b) => f.Extra["egr_in_v"] = Math.Round(HondaDatalog.Volts(b[0]), 3), "Used by a wideband or a flex sensor wired there."),
        C("b6_in", "B6 input (analog)", "Inputs", "V", [34], (f, b) => f.Extra["b6_in_v"] = Math.Round(HondaDatalog.Volts(b[0]), 3)),
        C("service", "Service state", "Diagnostics", "", [35], (f, b) =>
        {
            Bit(f, "svc_injectors_off", b[0], 0); Bit(f, "svc_timing_locked", b[0], 1); Bit(f, "svc_maps_chosen", b[0], 2); Bit(f, "svc_second_maps", b[0], 3);
            for (int i = 0; i < 4; i++) Bit(f, $"svc_gio{i + 1}", b[0], 4 + i);
        }, "What the service commands have set: injectors off, timing locked, the maps chosen, GIO forced on (ROM version 3)."),
        C("codes", "Trouble codes", "Diagnostics", "", [36, 37, 38, 39], (f, b) => { for (int i = 0; i < 4; i++) f.Extra[$"dtc{i}"] = b[i]; },
            "The stored trouble codes, one bit per code (needs the stock trouble codes built in: FEAT_STOCK_DTC; ROM version 3)."),
    ];

    /// What a fresh setup logs: the channels the stream always used to.
    public static readonly string[] Defaults = ["rpm", "map", "tps", "ect", "iat", "batt", "speed"];

    public static DatalogChannel? Find(string key) => All.FirstOrDefault(c => c.Key.Equals(key, StringComparison.OrdinalIgnoreCase));

    /// The chosen channels in catalogue order, dropped past what fits: `most` bytes, and only what the ROM's version has (version 1: no status bytes).
    public static List<DatalogChannel> Fit(IEnumerable<string> keys, int most, bool version2) => Fit(keys, most, version2 ? 2 : 1);

    public static List<DatalogChannel> Fit(IEnumerable<string> keys, int most, int version)
    {
        var set = new HashSet<string>(keys, StringComparer.OrdinalIgnoreCase);
        var list = new List<DatalogChannel>();
        int bytes = 0;
        foreach (var c in All)
        {
            if (!set.Contains(c.Key) || c.MinVersion > version || bytes + c.Bytes > most) continue;
            list.Add(c); bytes += c.Bytes;
        }
        return list;
    }
}
