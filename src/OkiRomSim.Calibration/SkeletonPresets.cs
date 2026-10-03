// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Calibration;

/// Ready-made picks for File > New ROM > Create.
public static class SkeletonPresets
{
    /// "Default": an HTS120-style ROM cut to what is safe to start from. The stock functions an HTS120 ROM keeps (the fail-safes and trouble codes, the self-tests, closed loop on the narrowband and its heater, the VTEC pressure check, A/C and purge), its datalog frame - with this app's channel stream and service commands - and the HTS120 functions nearly every tune uses: rev limits, coolant protection, ignition cut shaping, launch, full throttle shift, injector scaling, TPS end points, road speed correction, gear detection and the VTEC page (engage points and conditions, or VTEC off). Every module is off until it is switched on in its page, so the ROM runs as stock until then. All of HTS120 does not fit: 33 of its 43 functions fill the 32 KB, and their tick takes about 450 us even switched off, where this one is about 200 us with 2 KB to spare for what you add.
    public static readonly string[] Default =
    [
        "FEAT_STOCK_DTC", "FEAT_STOCK_SELFTEST", "FEAT_STOCK_O2", "FEAT_STOCK_O2HEATER", "FEAT_STOCK_VTECPRESSURE",
        "FEAT_STOCK_AC", "FEAT_STOCK_PURGE",
        "FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE", "FEAT_DLEXTRA",
        "FEAT_REVLIMIT", "FEAT_ECTPRO", "FEAT_IGNCUTMOD", "FEAT_LAUNCH", "FEAT_FTS", "FEAT_FUELTRIM", "FEAT_TPSCAL",
        "FEAT_SPEEDCORR", "FEAT_GEAR", "FEAT_VTECCTL",
    ];

    /// The preset as far as it goes on this skeleton: in order, each function that is there and can be built with the ones before it, then cut from the end until the ROM fits (its space and its module RAM).
    public static List<string> Fit(Skeleton sk, IEnumerable<string> preset)
    {
        var chosen = new List<string>();
        foreach (var d in preset)
            if (sk.Feature(d) != null && sk.Problems([.. chosen, d]).Count == 0) chosen.Add(d);
        while (chosen.Count > 0 && !sk.Build(chosen).Success) chosen.RemoveAt(chosen.Count - 1);
        return chosen;
    }
}
