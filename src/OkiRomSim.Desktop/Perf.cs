// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Desktop;

/// How often each part of the screen is brought up to date. Not everything needs the same speed: where the engine is on the map follows every datalog frame the moment it arrives, the gauges and the values follow a little behind, the side panels and the overlay far less often. Low performance mode (Settings > General) slows the rest down further and drops the drawing effects, so a slow laptop keeps its time for the datalog and the map.
public static class Perf
{
    public static bool Low { get; private set; }

    /// Raised on the UI thread when the mode changes.
    public static event Action? Changed;

    public static void Set(bool low)
    {
        if (low == Low) return;
        Low = low;
        Changed?.Invoke();
    }

    /// Suggested for a machine this small (2 cores, or 4 GB of memory or less).
    public static bool Suggested =>
        Environment.ProcessorCount <= 2 || GC.GetGCMemoryInfo().TotalAvailableMemoryBytes is > 0 and <= 4L << 30;

    /// The main refresh while something is moving (running, logging, replaying) and while nothing is.
    public static int BusyMs => Low ? 250 : 150;
    public static int IdleMs => Low ? 600 : 300;
    /// The simulator's side panels that change the least: call stack, outputs, ports.
    public static int SidePanelsMs => Low ? 600 : 300;
    /// The datalog's list of values.
    public static int ValuesMs => Low ? 300 : 120;
    /// The gauges, replaying.
    public static int GaugesMs => Low ? 100 : 33;
    /// The trail fading behind the engine on the map (a new frame is drawn at once whatever this is).
    public static int TrailMs => Low ? 250 : 90;
    /// The simulator's read trace on the map.
    public static int TraceMs => Low ? 100 : 45;
    /// The logged-channel overlay on the map.
    public static int OverlayMs => Low ? 3000 : 1000;
    /// Shading and gloss on the cells.
    public static bool Effects => !Low;
}
