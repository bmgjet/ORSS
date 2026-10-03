// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Calibration;

/// What the engine's flag bytes hold, bit by bit: worked out from the stock code that sets and reads each bit (the skeleton's p30 source). 116h-119h are the main loop's working copies of 216h-219h, so they share names. A bit no code uses has no channel. The board options (216h, 227h, some of 217h and 219h) are set once at start from the ROM's Option bytes.
public static class FlagNames
{
    /// A flag byte: what it is as a whole (its channel's name and the key its raw value is logged under) and its bits.
    public sealed record FlagByte(string Name, string Key, string Group, string About, (string Key, string About)?[] Bits);

    static (string, string)? B(string key, string about) => (key, about);

    static readonly FlagByte Options = new("Board options", "board_options", "Board options",
        "The board's options, decoded from the ROM's Option bytes at start (216h; 116h is the main loop's copy).",
    [
        B("opt_alt_knock_tables", "The alternative knock shift tables are used (OptionAltKnockShiftTables)."),
        null,
        B("opt_low_speed_retard_cap", "The low-speed retard cap is on (OptionLowSpeedRetardCap)."),
        B("opt_automatic", "An automatic gearbox (OptionAutomaticTransmission)."),
        B("opt_vtec_checks", "The VTEC checks are on (OptionVtecChecks)."),
        B("opt_knock_sensor", "A knock sensor is fitted (OptionKnockSensor)."),
        B("opt_alternator_check", "The alternator control check is on (OptionAlternatorControlCheck)."),
        B("opt_egr", "An EGR system is fitted (OptionEgrSystem)."),
    ]);

    static readonly FlagByte Modes = new("Engine modes", "engine_modes", "Engine state",
        "Ignition, start-up and idle modes (217h; 117h is the main loop's copy).",
    [
        B("ign_rpm_band", "The rpm is past the ignition table's band point (with hysteresis)."),
        B("ign_mode", "The ignition calculation's mode flag."),
        B("selftest_irq_mode", "The clock self-test's interrupt mode (which timers it lets in)."),
        B("opt_knock_window_open", "The knock window is always open (OptionKnockWindowAlwaysOpen)."),
        B("cold_start", "A cold start: set when the engine state is reset cold, cleared once it has warmed through."),
        B("warm_idle", "Warm idle mode: the idle valve's warm target and its control are in use."),
        B("opt_idle_valve_type2", "The second idle valve type (OptionIdleValveType2)."),
        null,
    ]);

    static readonly FlagByte Throttle = new("Throttle state", "throttle_state", "Engine state",
        "The throttle against the closed-throttle point the ECU learned (218h; 118h is the main loop's copy).",
    [
        B("throttle_off_closed", "The throttle is off the closed-throttle window."),
        B("throttle_off_closed_prev", "The same, as it was last time round."),
        B("throttle_open", "The throttle is open past the closed point by a step (with hysteresis)."),
        B("throttle_open_prev", "The same, as it was last time round."),
        B("throttle_open_more", "The throttle is open past the closed point by a bigger step."),
        B("freeze_frame_taken", "A freeze frame of the readings was taken with a code."),
        B("freeze_frame_ready", "The freeze frame data has been decoded and checked."),
        B("coolant_band", "The coolant is past the point that switches the threshold tables."),
    ]);

    static readonly FlagByte Warmup = new("Warm-up and inputs", "warmup_state", "Engine state",
        "Warm-up state and sensor options (219h; 119h is the main loop's copy).",
    [
        B("idle_stage", "The idle air staging is in its first stage."),
        B("opt_second_inputs", "The second sensor inputs are used (OptionSecondSensorInputs)."),
        B("iat_above_coolant", "The intake air is hotter than the coolant cross-table says (it picks the intake air fuel correction)."),
        B("o2_heater_conditions", "The conditions for the O2 heater are met (coolant, battery)."),
        B("opt_closed_loop_off", "Closed loop is switched off (OptionClosedLoopOff)."),
        B("cold_accel_fuel", "The coolant is cold enough for the acceleration fuel table."),
        B("after_start_counting", "The after-start count is still running."),
        B("diag_code_match", "The diagnostic code check found a match."),
    ]);

    /// Every flag byte the "every channel" module sends, by its RAM address.
    public static readonly Dictionary<int, FlagByte> Bytes = new()
    {
        [0x0A0] = new("Spark and rpm state", "spark_rpm_state", "Engine state", "Spark timing, rpm and load range flags (0A0h).",
        [
            B("o2_alt_trim_table", "The O2 trim reads its other table (boards with the low-speed retard cap, after an O2 code)."),
            B("vtec_pressure_seen", "The VTEC pressure switch has passed its debounce."),
            B("spark_timer1_wrap", "Spark timer 1's angle went round past its count."),
            B("spark_timer2_wrap", "Spark timer 2's angle went round past its count."),
            B("spark_timer3_wrap", "Spark timer 3's angle went round past its count."),
            B("alt_check_off", "The alternator check is skipped (no second inputs, no alternator check, or a cold start)."),
            B("load_index_clamped", "The load index is held at the end of the map."),
            B("rpm_high_range", "The rpm is worked out in its high range."),
        ]),
        [0x111] = new("Switch inputs", "switch_inputs", "Inputs",
            "The second switch buffer (4700h) as the ECU reads it, bits 1, 3 and 4 inverted (111h).",
        [
            B("sw_start", "Start signal (B9)."),
            B("sw_vtec_pressure", "VTEC pressure switch (D6)."),
            B("sw_ac_request", "A/C request (B5)."),
            B("sw_unused", "Unused by every ROM."),
            B("sw_brake", "Brake switch (D2)."),
            B("sw_park_neutral", "Park / neutral (B7)."),
            B("sw_at_shift1", "A/T shift position 1."),
            B("sw_at_shift2", "A/T shift position 2."),
        ]),
        [0x116] = Options,
        [0x216] = Options,
        [0x117] = Modes,
        [0x217] = Modes,
        [0x118] = Throttle,
        [0x119] = Warmup,
        [0x11D] = new("O2, knock and VTEC state", "o2_knock_vtec_state", "Engine state", "O2 trim, knock window, VTEC and crank sync flags (11Dh).",
        [
            B("o2_trim_running", "The O2 trim is running (closed loop has started)."),
            B("o2_trim_held", "The O2 trim is held at its last value."),
            B("knock_window_closed", "The knock window is closed (accelerating, high rpm, a fuel cut)."),
            B("rpm_above_knock_band", "The rpm is past the knock control's band (with hysteresis)."),
            B("vtec_state_on", "VTEC is in its on state (the high cam's maps)."),
            B("accel_enrich_active", "Acceleration fuel is being added."),
            B("crank_sync_lost", "The crank sync was lost and is being found again."),
            B("crank_edge_clamped", "A crank edge's time was held at its limit."),
        ]),
        [0x123] = new("Fuel state", "fuel_state", "Fuel corrections", "Injector, acceleration fuel and fuel cut flags (123h).",
        [
            B("dead_time_point_high", "The battery is past the dead time's upper point (with hysteresis)."),
            B("dead_time_point_low", "The battery is past the dead time's lower point (with hysteresis)."),
            B("inj_bank_b_late", "Injector timer bank B ends after bank C."),
            B("tipin_after_start", "Tip-in fuel's after-start time is running."),
            B("tps_accel_active", "Throttle acceleration fuel is active."),
            B("ign_map2", "The second ignition map's range is in use."),
            B("tps_accel_high", "The throttle is opening fast (with hysteresis)."),
            B("fuel_cut_recovering", "A fuel cut has just ended: the fuel is coming back."),
        ]),
        [0x124] = new("Acceleration and rpm", "accel_rpm_state", "Fuel corrections", "Acceleration fuel modes and rpm change flags (124h).",
        [
            B("accel_mode", "Acceleration fuel's mode (the step it is in)."),
            B("accel_rpm_mode_low", "Acceleration fuel's low rpm mode."),
            B("accel_rpm_mode_high", "Acceleration fuel's high rpm mode."),
            B("cranking", "The engine is cranking."),
            null,
            B("rpm_above_cyl_ign_point", "The rpm is past the cylinder ignition correction's point."),
            B("rpm_falling", "The rpm is falling."),
            B("rpm_change_clamped", "The rpm change was held at its limit."),
        ]),
        [0x125] = new("O2 state", "o2_state", "Fuel corrections", "Closed loop and O2 sensor flags (125h).",
        [
            B("rpm_above_o2_point", "The rpm is past the O2 trim's high rpm point (with hysteresis)."),
            B("o2_rich", "The O2 sensor reads rich."),
            B("o2_above_reference", "The O2 sensor is above its reference."),
            B("o2_ready", "The O2 sensor is warm and switching: closed loop may run."),
            null,
            B("load_above_o2_point", "The load is past the O2 trim's step point (with hysteresis)."),
            B("rpm_above_inj_point", "The rpm is past the injector timing's point (with hysteresis)."),
            B("throttle_above_inj_point", "The throttle is past the injector timing's point (with hysteresis)."),
        ]),
        [0x126] = new("Overrun state", "overrun_state", "Limiters and cuts", "Overrun fuel cut and deceleration flags (126h).",
        [
            B("decel_cut_load", "The load is under the deceleration cut map."),
            B("overrun_cut_armed", "The overrun fuel cut is armed (throttle closed)."),
            B("rpm_above_overrun_end", "The rpm is past where the overrun cut ends (with hysteresis)."),
            B("rpm_above_overrun_start", "The rpm is past where the overrun cut starts (with hysteresis)."),
            B("overrun_retard", "Ignition is retarded for the overrun."),
            B("decel_fuel_held", "The deceleration fuel is held."),
            B("decel_rpm_drop", "The rpm is dropping on deceleration."),
            B("throttle_hysteresis", "The throttle's hysteresis flag."),
        ]),
        [0x227] = new("Board options 2", "board_options2", "Board options", "More of the board's options, from the ROM's Option bytes at start (227h).",
        [
            null,
            B("opt_idle_strategy2", "The second idle strategy (OptionIdleStrategy2)."),
            B("opt_speed_checks_off", "The road speed checks are off (OptionSpeedChecksOff)."),
            B("opt_gear_detection", "Gear detection is on (OptionGearDetection)."),
            B("opt_baro_sensor", "A baro sensor is fitted (OptionBaroSensor)."),
            B("opt_board_ign_map", "The board's own ignition map is used (OptionBoardIgnitionMap)."),
            B("opt_vtec_pressure_switch", "A VTEC pressure switch is fitted (OptionVtecPressureSwitch)."),
            B("opt_knock_retard_by_iat", "Knock retard against intake air (OptionKnockRetardByIntakeAir)."),
        ]),
    };

    /// A flag byte into the frame: the byte under its name, each bit the code uses as a channel of its own.
    public static void Decode(LogFrame f, int addr, byte b)
    {
        if (!Bytes.TryGetValue(addr, out var fb)) { f.Extra[$"flags_{addr:x3}"] = b; return; }
        f.Extra[fb.Key] = b;
        for (int i = 0; i < 8; i++)
            if (fb.Bits[i] is { } bit) f.Extra[bit.Key] = (b >> i) & 1;
    }

    /// What a bit channel is, for a tooltip or the channel list (null: not a flag bit).
    public static string? About(string key)
    {
        foreach (var fb in Bytes.Values)
        {
            if (fb.Key == key) return fb.About;
            foreach (var bit in fb.Bits) if (bit is { } x && x.Key == key) return x.About;
        }
        return null;
    }
}

/// The eight RAM addresses of your own (the ROM's DatalogUserAddress): which address each is, and what the memory map says is there, so its channel carries that name ("ram_0b4_road_speed") rather than "RAM address 1".
public static class UserRam
{
    static readonly (int Address, string Name)[] _picked = new (int, string)[8];

    /// Set from the ROM open: the address picked in each slot (0 for none) and the memory map's name for it.
    public static void Set(int slot, int address, string? name) { if (slot is >= 0 and < 8) { _picked[slot] = (address, name ?? ""); Known = true; } }

    /// The ROM open said which addresses are picked: a slot with none is not logged. (A car logged with no ROM open: every slot is logged as ram1-8.)
    public static bool Known { get; private set; }

    public static (int Address, string Name) At(int slot) => slot is >= 0 and < 8 ? _picked[slot] : (0, "");

    /// The channel key a slot's byte is logged under; null for a slot the ROM open has no address in.
    public static string? Key(int slot)
    {
        var (a, n) = At(slot);
        if (a == 0) return Known ? null : $"ram{slot + 1}";
        var slug = new string([.. n.ToLowerInvariant().Select(c => char.IsLetterOrDigit(c) ? c : '_')]).Trim('_');
        while (slug.Contains("__")) slug = slug.Replace("__", "_");
        if (slug.Length > 28) slug = slug[..28].Trim('_');
        return slug.Length > 0 ? $"ram_{a:x3}_{slug}" : $"ram_{a:x3}";
    }

    /// What the Channels window says about a slot.
    public static string Label(int slot)
    {
        var (a, n) = At(slot);
        return a == 0 ? "no address picked (the ROM's Datalog page)" : $"{a:X3}h" + (n.Length > 0 ? $"  {n}" : "");
    }
}
