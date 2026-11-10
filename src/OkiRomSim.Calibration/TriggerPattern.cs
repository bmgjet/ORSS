// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Calibration;

/// One cam revolution of the distributor's signals as the ECU caught them (the skeleton ROM's trigger pattern log, 62h):
/// the 24 crank (CKP) teeth, each one's time since the tooth before, and which teeth the TDC and cylinder (CYP) pulses came
/// with. What a healthy distributor gives: 24 even teeth, a TDC pulse every sixth, one CYP three teeth after cylinder 1's TDC.
public sealed class TriggerPattern
{
    public const int Teeth = 24;
    /// The crank timer's count: 3.2 us on the P30 (timer 2 at 312.5 kHz), 4 us on the P13 (the MSM66911's free-running counter).
    public static double UsPerCount => OkiRomSim.Core.Chip.Is66911 ? 4.0 : 3.2;

    /// One tooth: its time (scaled counts as the ECU sent them: 63 means "63 or more"), and the pulses that came with it.
    public sealed record Tooth(int Index, int Scaled, bool Tdc, bool Cyp)
    {
        public bool Saturated => Scaled >= 63;
    }

    /// How far it got: 25 is a whole revolution; 1-24 the teeth so far + 1 (the crank signal stopped); 0 not even one tooth.
    public int State { get; init; }
    /// Each period was shifted right this many places (FFh: no period came).
    public int Shift { get; init; }
    public List<Tooth> All { get; init; } = [];
    /// The teeth caught (the ones a period came for).
    public List<Tooth> Caught => [.. All.Take(Math.Clamp(State - 1, 0, Teeth))];
    public bool Complete => State == Teeth + 1;
    public DateTime At { get; init; } = DateTime.Now;

    /// From the ECU's answer to 62h: 62h, state, scale, 24 teeth, sum. Null when it is not that.
    public static TriggerPattern? Parse(byte[] r)
    {
        if (r.Length < 28 || r[0] != 0x62 || (r.Take(27).Sum(b => b) & 0xFF) != r[27]) return null;
        return new TriggerPattern
        {
            State = r[1], Shift = r[2],
            All = [.. Enumerable.Range(0, Teeth).Select(i => new Tooth(i, r[3 + i] & 63, (r[3 + i] & 0x80) != 0, (r[3 + i] & 0x40) != 0))],
        };
    }

    /// A tooth's time in milliseconds (the scale undone: to within one scaled step).
    public double Ms(Tooth t) => Shift > 15 ? 0 : t.Scaled * (1 << Shift) * UsPerCount / 1000.0;

    /// The usual tooth (the median), scaled.
    public double Typical
    {
        get
        {
            var v = Caught.Select(t => (double)t.Scaled).Order().ToList();
            return v.Count == 0 ? 0 : v[v.Count / 2];
        }
    }

    /// The engine speed the usual tooth stands for (12 teeth a crank revolution).
    public double Rpm => Typical <= 0 || Shift > 15 ? 0 : 60_000.0 / (Typical * (1 << Shift) * UsPerCount / 1000.0 * 12);

    /// The order to show them in: from the TDC before the cylinder pulse (cylinder 1), else from the first TDC, else as caught.
    public List<Tooth> Ordered()
    {
        var c = Caught;
        if (c.Count < Teeth) return c;
        int cyp = c.FindIndex(t => t.Cyp);
        int start = cyp >= 0 ? Enumerable.Range(0, Teeth).Select(k => (cyp - k + Teeth) % Teeth).FirstOrDefault(i => c[i].Tdc, -1) : c.FindIndex(t => t.Tdc);
        if (start < 0) start = 0;
        return [.. Enumerable.Range(0, Teeth).Select(k => c[(start + k) % Teeth])];
    }

    public enum Severity { Ok, Warn, Fault }
    public sealed record Finding(Severity Level, string Sensor, string Text, int[] Teeth);

    /// What looks wrong, sensor by sensor (an empty CKP / TDC / CYP list means that one looks right).
    public List<Finding> Analyse()
    {
        var f = new List<Finding>();
        var c = Ordered();
        if (State == 0 || c.Count == 0)
        {
            f.Add(new(Severity.Fault, "CKP", "No crank pulse came at all: the engine is stopped, or the crank (CKP) signal is not reaching the ECU (sensor, its wiring, the distributor not turning).", []));
            return f;
        }
        if (!Complete)
            f.Add(new(Severity.Fault, "CKP", $"Only {c.Count} of the {Teeth} crank teeth came before the signal stopped: the engine stalled, or the crank (CKP) signal drops out.", []));
        double typ = Typical;
        // CKP: a tooth twice as long is a pulse missed; one much shorter an extra (noise) pulse - the pulse either side of it short too
        var longT = c.Where(t => t.Scaled >= typ * 1.6).ToList();
        var shortT = c.Where(t => t.Scaled <= typ * 0.65).ToList();
        if (longT.Count > 0)
            f.Add(new(Severity.Fault, "CKP", $"{(longT.Count == 1 ? "Crank tooth" : "Crank teeth")} {string.Join(", ", longT.Select(t => c.IndexOf(t) + 1))} took " +
                $"{string.Join(", ", longT.Select(t => t.Saturated ? "63+" : t.Scaled.ToString()))} against {typ:0} for the others " +
                $"({string.Join(", ", longT.Select(t => $"{t.Scaled / typ:0.0}"))} times): a crank pulse missed{(longT.Count > 1 ? " (one missed pulse can show twice: 24 teeth then span a little more than a revolution)" : "")}. " +
                "A gap at the sensor, a loose connector, a damaged reluctor, or a weak signal at low rpm.", [.. longT.Select(t => c.IndexOf(t))]));
        if (shortT.Count > 0)
            f.Add(new(Severity.Fault, "CKP", $"{(shortT.Count == 1 ? "Crank tooth" : "Crank teeth")} {string.Join(", ", shortT.Select(t => c.IndexOf(t) + 1))} came early ({string.Join(", ", shortT.Select(t => $"{t.Scaled / typ:0.00}"))} times the others): an extra crank pulse. Noise on the CKP line - its shield, a coil lead or plug wire beside it, a bad ground.", [.. shortT.Select(t => c.IndexOf(t))]));
        var uneven = c.Where(t => !longT.Contains(t) && !shortT.Contains(t) && Math.Abs(t.Scaled - typ) > typ * 0.2).ToList();
        if (uneven.Count > 0 && longT.Count == 0 && shortT.Count == 0)
            f.Add(new(Severity.Warn, "CKP", $"The crank teeth vary more than a fifth ({uneven.Count} of them): the engine speeding up or slowing down fast (cranking, a misfire), or a sensor that is losing its signal.", [.. uneven.Select(t => c.IndexOf(t))]));
        if (!Complete) return f;
        // TDC: four, six teeth apart
        var tdc = Enumerable.Range(0, c.Count).Where(i => c[i].Tdc).ToList();
        if (tdc.Count == 0)
            f.Add(new(Severity.Fault, "TDC", "No TDC pulse in a whole cam revolution: the TDC sensor or its wiring.", []));
        else if (tdc.Count != 4)
            f.Add(new(Severity.Fault, "TDC", $"{tdc.Count} TDC pulses in a cam revolution, not 4: {(tdc.Count < 4 ? "one or more missing - a TDC sensor or wiring fault" : "extra ones - noise on the TDC line")}.", [.. tdc]));
        else if (longT.Count == 0 && shortT.Count == 0 && Enumerable.Range(1, 3).Any(i => tdc[i] - tdc[i - 1] != 6))
            f.Add(new(Severity.Fault, "TDC", $"The TDC pulses are not six crank teeth apart (teeth {string.Join(", ", tdc.Select(i => i + 1))}): the TDC sensor or its trigger is out of place.", [.. tdc]));
        // CYP: one, three teeth after a TDC
        var cyp = Enumerable.Range(0, c.Count).Where(i => c[i].Cyp).ToList();
        if (cyp.Count == 0)
            f.Add(new(Severity.Fault, "CYP", "No cylinder (CYP) pulse in a whole cam revolution: the CYP sensor or its wiring. The ECU cannot tell cylinder 1 (it sets code 9).", []));
        else if (cyp.Count > 1)
            f.Add(new(Severity.Fault, "CYP", $"{cyp.Count} cylinder (CYP) pulses in one cam revolution, not 1: noise on the CYP line.", [.. cyp]));
        else if (tdc.Count > 0 && longT.Count == 0 && shortT.Count == 0)
        {
            int after = tdc.Select(t => (cyp[0] - t + Teeth) % Teeth).Min();
            if (after != 3)
                f.Add(new(Severity.Fault, "CYP", $"The cylinder (CYP) pulse came {after} crank teeth after a TDC, not 3: the CYP sensor or its trigger is out of place (or the distributor was moved).", [cyp[0]]));
        }
        return f;
    }

    /// One line for the log and the status: a whole revolution, and whether anything looks wrong.
    public string Summary()
    {
        var f = Analyse();
        string head = Complete ? $"{Teeth} teeth at about {Rpm:0} rpm" : $"{Caught.Count} teeth";
        return f.Count == 0 ? head + ": the crank, TDC and cylinder signals all look right" : head + ": " + string.Join("; ", f.Select(x => $"{x.Sensor} {(x.Level == Severity.Fault ? "fault" : "check")}"));
    }
}
