// The world outside the MCU: drives the external levels that Bus's pin logic reads.
//
// Signals in SignalMap are confirmed from the disassembly or schematic and never
// overwritten. Untraced input pins get a selectable behaviour and may be flipped by
// StallMonitor when a ROM provably waits on one; a mapped pin is never touched.

namespace OkiRomSim.Core;

/// What an input pin with no known board mapping does.
public enum UnmappedPinPolicy
{
    /// Read as 0. The old (implicit) behaviour -- kept so existing traces stay reproducible.
    Low,
    /// Read as 1. Many ECU digital inputs are pulled up and switch to ground, so "no switch pressed" is usually high.
    High,
    /// Hold whatever Board.Pins currently says; only StallMonitor changes it.
    Hold,
    /// Flip on every read of the port. Maximises branch coverage at the cost of physical plausibility -- for coverage sweeps, not for behavioural testing.
    ToggleOnRead,
}

/// One externally driven digital signal, with the port/bit it lands on.
public readonly struct PinRef
{
    public readonly int Port;
    public readonly int Bit;
    public PinRef(int port, int bit) { Port = port; Bit = bit; }
    public override string ToString() => $"P{Port}.{Bit}";
}

public sealed class Board
{
    // ---- confirmed pin mappings ------------------------------------------
    // Only signals whose port/bit is actually established go here. Adding a
    // guess to this table would make StallMonitor stop nudging the pin, so
    // a wrong entry is worse than no entry.

    /// P4.1, the run/power-good sense the ROM's shutdown path polls. Documented in Bus (P4RunSense): low = running.
    public static readonly PinRef RunSense = new(Bus.Port4, Bus.P4RunSense);

    /// P4.6, VTEC oil-pressure switch ("vtec_oilpressure_pin_check: MB C, P4.6" in every ROM here). Low = pressure present.
    public static readonly PinRef VtecPressure = new(4, 6);

    /// Signals this model claims to drive correctly. StallMonitor treats every pin listed here as physics and will not touch it.
    public IReadOnlyDictionary<string, PinRef> SignalMap { get; } =
        new Dictionary<string, PinRef>
        {
            ["RunSense"] = RunSense,
            ["VtecPressureSwitch"] = VtecPressure,
        };

    // ---- signal states ----------------------------------------------------

    /// True while the ignition is on and the main relay is holding. When this goes false the ROM sees P4.1 go high and runs its shutdown path.
    public bool PowerGood = true;

    /// Oil pressure is available to the VTEC spool. The switch only sees pressure while the ROM holds the VTEC solenoid (P1.0) open; clear this to simulate a failed switch or low oil.
    public bool VtecPressureSwitch = true;

    Bus? _bus;

    /// Raw externally driven levels for P0..P4, consulted for any bit the ROM has configured as an input and that is not in SignalMap. Seeded from UnmappedPolicy on Reset.
    public byte[] Pins = new byte[5];

    public UnmappedPinPolicy UnmappedPolicy = UnmappedPinPolicy.High;

    /// Pins StallMonitor has flipped, for the run report: "P3.5 was nudged 4 times" is the signal that P3.5 is a real input worth tracing.
    public readonly Dictionary<string, int> NudgeCounts = new();

    private readonly bool[,] _mapped = new bool[5, 8];

    public Board()
    {
        foreach (var pin in SignalMap.Values) _mapped[pin.Port, pin.Bit] = true;
        Reset();
    }

    public void Reset()
    {
        byte seed = UnmappedPolicy == UnmappedPinPolicy.Low ? (byte)0x00 : (byte)0xFF;
        for (int p = 0; p < Pins.Length; p++) Pins[p] = seed;
        NudgeCounts.Clear();
    }

    /// True if (port,bit) has a confirmed board mapping. StallMonitor asks this before nudging anything.
    public bool IsMapped(int port, int bit) => _mapped[port, bit];

    /// Resolve the external level on a pin the ROM has configured as an input. Returns null to mean "no opinion" so Bus falls back to its own PortPins array (which Apply keeps in sync anyway). Levels forced by hand (e.g. clicking a pin in the chip view). They override everything else the harness would drive onto an input pin.
    public readonly Dictionary<(int Port, int Bit), bool> Forced = new();

    public bool? InputLevel(int port, int bit)
    {
        if (Forced.TryGetValue((port, bit), out var forced)) return forced;
        if (port == RunSense.Port && bit == RunSense.Bit) return !PowerGood;
        if (port == VtecPressure.Port && bit == VtecPressure.Bit)
            return !(VtecPressureSwitch && (_bus?.VtecSolenoidActive ?? false));

        if (UnmappedPolicy == UnmappedPinPolicy.ToggleOnRead)
        {
            bool now = (Pins[port] & (1 << bit)) != 0;
            Pins[port] ^= (byte)(1 << bit);
            return now;
        }
        return (Pins[port] & (1 << bit)) != 0;
    }

    /// Flip one unmapped input pin. Refuses to touch a pin in SignalMap -- those are driven by the harness model and flipping them would be a lie, not a nudge. Returns false if the pin was refused.
    public bool Nudge(int port, int bit)
    {
        if (port < 0 || port >= Pins.Length || bit < 0 || bit > 7) return false;
        if (IsMapped(port, bit)) return false;
        Pins[port] ^= (byte)(1 << bit);
        string key = $"P{port}.{bit}";
        NudgeCounts.TryGetValue(key, out int n);
        NudgeCounts[key] = n + 1;
        return true;
    }

    /// Push board state onto the bus. Called once per sensor sync, alongside EngineState.SyncSensorsToBus.
    public void Apply(Bus bus)
    {
        bus.Board = this;
        _bus = bus;
        bus.VtecPressureSwitch = VtecPressureSwitch;
        for (int p = 0; p < Pins.Length && p < bus.PortPins.Length; p++)
        {
            bus.PortPins[p] = Pins[p];
        }
        // P4.1 is driven by PowerGood, not by the raw Pins seed.
        if (PowerGood) bus.PortPins[RunSense.Port] &= (byte)~(1 << RunSense.Bit);
        else bus.PortPins[RunSense.Port] |= (byte)(1 << RunSense.Bit);
    }
}
