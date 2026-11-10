// Copyright (c) bmgjet. All rights reserved.
// A scripted trip through the engine's operating regions: coverage is limited by situations, not speed. Each Phase holds the engine at one operating point for a number of instructions, interpolating toward it so transitions also run. The default cycle runs cold conditions first, before the ECT model warms up.

namespace OkiRomSim.Core;

/// One operating point, held for a while.
public sealed class Phase
{
    public string Name = "";
    /// Instructions to spend on this phase, including the ramp into it.
    public long Instructions = 2_000_000;
    /// Fraction of the phase spent ramping from the previous phase's values. 0 snaps immediately; 0.3 spends the first 30% interpolating.
    public double RampFraction = 0.25;

    public double? Rpm, MapKpa, TpsPct, EctCelsius, IatCelsius, O2Volts,
                   VbattVolts, SpeedKmh, BaroKpa, EldVolts, EgrLiftPct, KnockIntensity;
    public bool? Cranking;
    public bool? VtecPressureSwitch;
    public bool? PowerGood;

    /// Run when the phase starts. For anything the fields above cannot say -- injecting a fault, pushing a serial request, flipping a board pin.
    public Action<Simulator>? OnEnter;
}

public sealed class DriveCycle
{
    public readonly List<Phase> Phases = [];
    public bool Loop = true;
    private long _phaseInstructions;
    private Phase? _current;
    private Phase? _previous;

    public string CurrentPhaseName => _current?.Name ?? "(none)";
    public int CurrentPhaseIndex { get; private set; }
    /// Phase names in the order they were first entered, for the run report.
    public readonly List<string> PhasesVisited = [];

    public void Reset()
    {
        CurrentPhaseIndex = 0;
        _phaseInstructions = 0;
        _current = null;
        _previous = null;
        PhasesVisited.Clear();
    }

    /// Advance the cycle by one instruction's worth of time and write the resulting operating point onto the simulator. Returns false once a non-looping cycle has run out of phases.
    public bool Tick(Simulator sim)
    {
        if (Phases.Count == 0) return false;

        if (_current == null)
        {
            _current = Phases[CurrentPhaseIndex];
            _phaseInstructions = 0;
            PhasesVisited.Add(_current.Name);
            _current.OnEnter?.Invoke(sim);
        }

        double t = _current.RampFraction <= 0.0
            ? 1.0
            : Math.Min(1.0, _phaseInstructions / (_current.Instructions * _current.RampFraction));

        Apply(sim, _previous, _current, t);

        if (++_phaseInstructions >= _current.Instructions)
        {
            _previous = _current;
            CurrentPhaseIndex++;
            if (CurrentPhaseIndex >= Phases.Count)
            {
                if (!Loop) { _current = null; return false; }
                CurrentPhaseIndex = 0;
            }
            _current = null;
        }
        return true;
    }

    private static void Apply(Simulator sim, Phase? from, Phase to, double t)
    {
        var e = sim.Engine;
        var b = sim.Board;

        e.Rpm = Lerp(from?.Rpm, to.Rpm, e.Rpm, t);
        e.MapKpa = Lerp(from?.MapKpa, to.MapKpa, e.MapKpa, t);
        e.TpsPct = Lerp(from?.TpsPct, to.TpsPct, e.TpsPct, t);
        e.EctCelsius = Lerp(from?.EctCelsius, to.EctCelsius, e.EctCelsius, t);
        e.IatCelsius = Lerp(from?.IatCelsius, to.IatCelsius, e.IatCelsius, t);
        e.O2Volts = Lerp(from?.O2Volts, to.O2Volts, e.O2Volts, t);
        e.VbattVolts = Lerp(from?.VbattVolts, to.VbattVolts, e.VbattVolts, t);
        e.SpeedKmh = Lerp(from?.SpeedKmh, to.SpeedKmh, e.SpeedKmh, t);
        e.BaroKpa = Lerp(from?.BaroKpa, to.BaroKpa, e.BaroKpa, t);
        e.EldVolts = Lerp(from?.EldVolts, to.EldVolts, e.EldVolts, t);
        e.EgrLiftPct = Lerp(from?.EgrLiftPct, to.EgrLiftPct, e.EgrLiftPct, t);
        e.KnockIntensity = Lerp(from?.KnockIntensity, to.KnockIntensity, e.KnockIntensity, t);

        if (to.Cranking is bool c) e.Cranking = c;
        if (to.VtecPressureSwitch is bool v) b.VtecPressureSwitch = v;
        if (to.PowerGood is bool p) b.PowerGood = p;
    }

    /// Interpolate between the previous phase's target and this one's. A null target on either side means "leave it where it is", which is what lets a phase specify only the two or three values it cares about.
    private static double Lerp(double? a, double? b, double current, double t)
    {
        if (b == null) return current;
        double start = a ?? current;
        return start + ((b.Value - start) * t);
    }

    /// The default sweep: cold start through to key-off, ordered so each region is reachable when it runs.
    public static DriveCycle Default(long scale = 1_500_000)
    {
        var dc = new DriveCycle();
        void Add(Phase p) { p.Instructions = scale; dc.Phases.Add(p); }

        // Boot happens with the key on but the engine stopped. The ROM's self-test, RAM clear and A/D mux scan all run here.
        Add(new Phase { Name = "key-on, engine off", Rpm = 0, MapKpa = 101, TpsPct = 0,
                        EctCelsius = -5, IatCelsius = -5, VbattVolts = 12.4, SpeedKmh = 0,
                        Cranking = false, RampFraction = 0 });

        Add(new Phase { Name = "cranking (cold)", Rpm = 250, MapKpa = 60, TpsPct = 0,
                        Cranking = true, VbattVolts = 9.2, RampFraction = 0.1 });

        Add(new Phase { Name = "cold idle", Rpm = 1500, MapKpa = 38, TpsPct = 0,
                        EctCelsius = 5, Cranking = false, VbattVolts = 14.2,
                        O2Volts = 0.1 });

        Add(new Phase { Name = "warm-up", Rpm = 1100, EctCelsius = 60, IatCelsius = 20,
                        O2Volts = 0.45, RampFraction = 0.6 });

        Add(new Phase { Name = "warm idle", Rpm = 800, MapKpa = 30, EctCelsius = 88,
                        SpeedKmh = 0 });

        Add(new Phase { Name = "idle + A/C + load", EldVolts = 3.4, Rpm = 900, MapKpa = 34 });

        Add(new Phase { Name = "light cruise", Rpm = 2200, MapKpa = 45, TpsPct = 12,
                        SpeedKmh = 50, O2Volts = 0.45, EgrLiftPct = 25 });

        Add(new Phase { Name = "part throttle accel", Rpm = 3600, MapKpa = 75, TpsPct = 40,
                        SpeedKmh = 80, O2Volts = 0.8, EgrLiftPct = 5 });

        // Every VTEC crossover condition at once: rpm, throttle, temperature, road speed and the oil-pressure switch.
        Add(new Phase { Name = "WOT + VTEC", Rpm = 6200, MapKpa = 98, TpsPct = 100,
                        SpeedKmh = 140, O2Volts = 0.9, EgrLiftPct = 0,
                        VtecPressureSwitch = true });

        Add(new Phase { Name = "knock under load", Rpm = 5200, MapKpa = 95, TpsPct = 85,
                        KnockIntensity = 0.85 });

        Add(new Phase { Name = "rev limit", Rpm = 7400, MapKpa = 99, TpsPct = 100,
                        KnockIntensity = 0 });

        // Closed throttle at speed is decel fuel cut: injectors off, high vacuum, lean O2.
        Add(new Phase { Name = "decel fuel cut", Rpm = 3800, MapKpa = 18, TpsPct = 0,
                        SpeedKmh = 110, O2Volts = 0.05 });

        Add(new Phase { Name = "overrun to idle", Rpm = 850, MapKpa = 30, TpsPct = 0,
                        SpeedKmh = 0, O2Volts = 0.45, RampFraction = 0.7 });

        // High altitude: the baro correction paths only run when the reading moves well away from sea level.
        Add(new Phase { Name = "high altitude cruise", BaroKpa = 72, Rpm = 2600,
                        MapKpa = 40, TpsPct = 15, SpeedKmh = 60 });

        Add(new Phase { Name = "hot soak / low oil pressure", EctCelsius = 108,
                        Rpm = 800, VtecPressureSwitch = false });

        Add(new Phase { Name = "key-off shutdown", PowerGood = false, Rpm = 0,
                        TpsPct = 0, SpeedKmh = 0, Cranking = false, RampFraction = 0 });

        // Back to power-good so a looping cycle reboots cleanly rather than sitting in the shutdown path forever.
        Add(new Phase { Name = "power restored", PowerGood = true, RampFraction = 0,
                        Rpm = 0 });

        return dc;
    }
}
