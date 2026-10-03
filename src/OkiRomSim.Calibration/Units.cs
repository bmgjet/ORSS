// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;

namespace OkiRomSim.Calibration;

/// What a number measures, for picking the unit it is shown in.
public enum Quantity { Temperature, Pressure, Boost, Speed, Distance, Mass, Power, Torque, Length, Area, Inertia, Force, Mixture, FuelFlow, Volume }

/// The unit each kind of measurement is shown in (Settings > Units). Any mix: °C with mph, kW with lb-ft... "as is" for pressure keeps what the ROM or the log has (kPa for MAP, mBar on a load axis).
public sealed class UnitSettings
{
    public string Temperature { get; set; } = "°C";
    public string Pressure { get; set; } = "as is";
    public string Boost { get; set; } = "psi";
    public string Speed { get; set; } = "km/h";
    public string Distance { get; set; } = "km";
    public string Mass { get; set; } = "kg";
    public string Power { get; set; } = "hp";
    public string Torque { get; set; } = "Nm";
    public string Length { get; set; } = "m";
    public string Area { get; set; } = "m²";
    public string Inertia { get; set; } = "kg·m²";
    public string Force { get; set; } = "N";
    public string Mixture { get; set; } = "AFR";
    public string FuelFlow { get; set; } = "cc/min";
    public string Volume { get; set; } = "L";
    /// AFR at lambda 1, for showing AFR as lambda.
    public double Stoich { get; set; } = 14.7;

    public string Get(Quantity q) => q switch
    {
        Quantity.Temperature => Temperature, Quantity.Pressure => Pressure, Quantity.Boost => Boost, Quantity.Speed => Speed,
        Quantity.Distance => Distance, Quantity.Mass => Mass, Quantity.Power => Power, Quantity.Torque => Torque, Quantity.Length => Length,
        Quantity.Area => Area, Quantity.Inertia => Inertia, Quantity.Force => Force, Quantity.Mixture => Mixture, Quantity.FuelFlow => FuelFlow,
        _ => Volume,
    };

    public void Set(Quantity q, string unit)
    {
        switch (q)
        {
            case Quantity.Temperature: Temperature = unit; break; case Quantity.Pressure: Pressure = unit; break; case Quantity.Boost: Boost = unit; break;
            case Quantity.Speed: Speed = unit; break; case Quantity.Distance: Distance = unit; break; case Quantity.Mass: Mass = unit; break;
            case Quantity.Power: Power = unit; break; case Quantity.Torque: Torque = unit; break; case Quantity.Length: Length = unit; break;
            case Quantity.Area: Area = unit; break; case Quantity.Inertia: Inertia = unit; break; case Quantity.Force: Force = unit; break;
            case Quantity.Mixture: Mixture = unit; break; case Quantity.FuelFlow: FuelFlow = unit; break; default: Volume = unit; break;
        }
    }

    public UnitSettings Clone() => (UnitSettings)MemberwiseClone();

    public static UnitSettings Metric() => new()
    {
        Temperature = "°C", Pressure = "as is", Boost = "bar", Speed = "km/h", Distance = "km", Mass = "kg", Power = "kW", Torque = "Nm",
        Length = "m", Area = "m²", Inertia = "kg·m²", Force = "N", Mixture = "AFR", FuelFlow = "cc/min", Volume = "L",
    };

    public static UnitSettings ImperialUs() => new()
    {
        Temperature = "°F", Pressure = "psi", Boost = "psi", Speed = "mph", Distance = "mi", Mass = "lb", Power = "hp", Torque = "lb-ft",
        Length = "in", Area = "ft²", Inertia = "lb·ft²", Force = "lbf", Mixture = "AFR", FuelFlow = "lb/hr", Volume = "US gal",
    };

    /// The UK mix: miles and pounds-feet, but Celsius, kilograms and litres.
    public static UnitSettings ImperialUk() => new()
    {
        Temperature = "°C", Pressure = "as is", Boost = "psi", Speed = "mph", Distance = "mi", Mass = "kg", Power = "hp", Torque = "lb-ft",
        Length = "in", Area = "m²", Inertia = "kg·m²", Force = "N", Mixture = "AFR", FuelFlow = "cc/min", Volume = "L",
    };
}

/// Units: what a value is in, and what it is shown in. Every conversion here is a straight line (a scale and an offset), so a value shown in one unit goes back exactly into the unit it is kept in.
public static class Units
{
    /// The units in use (the app sets these from its settings).
    public static UnitSettings Now { get; set; } = new();

    /// The choices for each quantity, in the order offered.
    public static readonly IReadOnlyDictionary<Quantity, string[]> Choices = new Dictionary<Quantity, string[]>
    {
        [Quantity.Temperature] = ["°C", "°F"],
        [Quantity.Pressure] = ["as is", "kPa", "mbar", "bar", "psi", "inHg"],
        [Quantity.Boost] = ["psi", "bar", "kPa"],
        [Quantity.Speed] = ["km/h", "mph"],
        [Quantity.Distance] = ["km", "mi"],
        [Quantity.Mass] = ["kg", "lb"],
        [Quantity.Power] = ["kW", "hp", "PS"],
        [Quantity.Torque] = ["Nm", "lb-ft", "kgf·m"],
        [Quantity.Length] = ["m", "mm", "in", "ft"],
        [Quantity.Area] = ["m²", "ft²"],
        [Quantity.Inertia] = ["kg·m²", "lb·ft²"],
        [Quantity.Force] = ["N", "lbf", "kgf"],
        [Quantity.Mixture] = ["AFR", "λ"],
        [Quantity.FuelFlow] = ["cc/min", "lb/hr"],
        [Quantity.Volume] = ["L", "US gal", "UK gal"],
    };

    /// What each quantity is, in words (the settings page).
    public static readonly IReadOnlyDictionary<Quantity, string> Names = new Dictionary<Quantity, string>
    {
        [Quantity.Temperature] = "Temperature", [Quantity.Pressure] = "Pressure (MAP, baro)", [Quantity.Boost] = "Boost (above the air outside)",
        [Quantity.Speed] = "Road speed", [Quantity.Distance] = "Distance", [Quantity.Mass] = "Weight", [Quantity.Power] = "Power",
        [Quantity.Torque] = "Torque", [Quantity.Length] = "Length (roller diameter)", [Quantity.Area] = "Area (frontal area)",
        [Quantity.Inertia] = "Inertia (dyno roller)", [Quantity.Force] = "Force (roller friction)", [Quantity.Mixture] = "Mixture",
        [Quantity.FuelFlow] = "Injector flow", [Quantity.Volume] = "Fuel volume",
    };

    /// Each unit as (quantity, value of one of it in the base unit, offset): base = value x scale + offset. The base units are °C, kPa, psi above outside (boost), km/h, km, kg, kW, Nm, m, m², kg·m², N, AFR, cc/min, L.
    static readonly Dictionary<string, (Quantity Q, double Scale, double Offset)> Known = new(StringComparer.OrdinalIgnoreCase)
    {
        ["°C"] = (Quantity.Temperature, 1, 0), ["C"] = (Quantity.Temperature, 1, 0), ["degC"] = (Quantity.Temperature, 1, 0),
        ["°F"] = (Quantity.Temperature, 5.0 / 9, -32 * 5.0 / 9), ["F"] = (Quantity.Temperature, 5.0 / 9, -32 * 5.0 / 9),
        ["kPa"] = (Quantity.Pressure, 1, 0), ["mbar"] = (Quantity.Pressure, 0.1, 0), ["bar"] = (Quantity.Pressure, 100, 0),
        ["psi"] = (Quantity.Pressure, 6.894757, 0), ["inHg"] = (Quantity.Pressure, 3.386389, 0), ["hPa"] = (Quantity.Pressure, 0.1, 0),
        ["psi g"] = (Quantity.Boost, 1, 0), ["bar g"] = (Quantity.Boost, 14.503774, 0), ["kPa g"] = (Quantity.Boost, 0.145038, 0),
        ["km/h"] = (Quantity.Speed, 1, 0), ["kph"] = (Quantity.Speed, 1, 0), ["mph"] = (Quantity.Speed, 1.609344, 0),
        ["km"] = (Quantity.Distance, 1, 0), ["mi"] = (Quantity.Distance, 1.609344, 0),
        ["kg"] = (Quantity.Mass, 1, 0), ["lb"] = (Quantity.Mass, 0.45359237, 0),
        ["kW"] = (Quantity.Power, 1, 0), ["W"] = (Quantity.Power, 0.001, 0), ["hp"] = (Quantity.Power, 0.7456999, 0), ["PS"] = (Quantity.Power, 0.73549875, 0),
        ["Nm"] = (Quantity.Torque, 1, 0), ["lb-ft"] = (Quantity.Torque, 1.3558179, 0), ["lbft"] = (Quantity.Torque, 1.3558179, 0), ["kgf·m"] = (Quantity.Torque, 9.80665, 0),
        ["m"] = (Quantity.Length, 1, 0), ["mm"] = (Quantity.Length, 0.001, 0), ["in"] = (Quantity.Length, 0.0254, 0), ["ft"] = (Quantity.Length, 0.3048, 0),
        ["m²"] = (Quantity.Area, 1, 0), ["ft²"] = (Quantity.Area, 0.09290304, 0),
        ["kg·m²"] = (Quantity.Inertia, 1, 0), ["kg m²"] = (Quantity.Inertia, 1, 0), ["lb·ft²"] = (Quantity.Inertia, 0.04214011, 0),
        ["N"] = (Quantity.Force, 1, 0), ["lbf"] = (Quantity.Force, 4.448222, 0), ["kgf"] = (Quantity.Force, 9.80665, 0),
        ["AFR"] = (Quantity.Mixture, 1, 0),
        ["cc/min"] = (Quantity.FuelFlow, 1, 0), ["lb/hr"] = (Quantity.FuelFlow, 10.5, 0),
        ["L"] = (Quantity.Volume, 1, 0), ["US gal"] = (Quantity.Volume, 3.785411784, 0), ["UK gal"] = (Quantity.Volume, 4.54609, 0),
    };

    /// The quantity a unit measures, or null for one that is not converted (%, V, ms, rpm, degrees of advance...).
    public static Quantity? Of(string unit)
    {
        var u = unit.Trim();
        if (u.Length == 0) return null;
        if (Known.TryGetValue(u, out var k)) return k.Q;
        return u is "λ" or "lambda" ? Quantity.Mixture : null;
    }

    /// The unit `unit` is shown in now.
    public static string Shown(string unit)
    {
        if (Of(unit) is not Quantity q) return unit;
        string want = Now.Get(q);
        if (q == Quantity.Pressure && want == "as is") return unit;
        if (q == Quantity.Boost) return want + " g";
        return want;
    }

    /// A value in `unit`, in the unit it is shown in now.
    public static double Show(double value, string unit) => Convert(value, unit, Shown(unit));

    /// A value as shown, back in `unit` (what it is kept in).
    public static double Back(double shown, string unit) => Convert(shown, Shown(unit), unit);

    /// Both at once: the value and the unit it is shown in.
    public static (double Value, string Unit) Display(double value, string unit) { var s = Shown(unit); return (Convert(value, unit, s), Label(s)); }

    /// A unit as written on screen: boost's "psi g" (above the air outside) is just "psi".
    public static string Label(string unit) => unit.EndsWith(" g", StringComparison.Ordinal) ? unit[..^2] : unit;

    /// From one unit to another of the same quantity (an unknown pair, or two quantities, come back unchanged).
    public static double Convert(double value, string from, string to)
    {
        if (string.Equals(from, to, StringComparison.OrdinalIgnoreCase) || double.IsNaN(value)) return value;
        if (Of(from) == Quantity.Mixture && Of(to) == Quantity.Mixture)
            return IsLambda(from) && !IsLambda(to) ? value * Now.Stoich : !IsLambda(from) && IsLambda(to) ? value / Now.Stoich : value;
        if (!Find(from, out var a) || !Find(to, out var b) || a.Q != b.Q) return value;
        double basev = (value * a.Scale) + a.Offset;
        return (basev - b.Offset) / b.Scale;
    }

    /// How much one step of `unit` is in the unit shown (for a step box: 1 kg is 2.2 lb).
    public static double ScaleOf(string unit) => Math.Abs(Show(1, unit) - Show(0, unit));

    static bool IsLambda(string u) => u is "λ" or "lambda";

    /// Boost is kept in psi; its units are written "psi", "bar", "kPa" on screen but mean "above the air outside".
    static bool Find(string unit, out (Quantity Q, double Scale, double Offset) k)
    {
        if (Known.TryGetValue(unit, out k)) return true;
        return false;
    }

    /// Boost (above the air outside), kept in psi, in the boost unit shown now.
    public static double ShowBoost(double psi) => Now.Boost switch { "bar" => psi / 14.503774, "kPa" => psi * 6.894757, _ => psi };
    public static double BackBoost(double shown) => Now.Boost switch { "bar" => shown * 14.503774, "kPa" => shown / 6.894757, _ => shown };
    public static string BoostUnit => Now.Boost;

    /// A value with its unit, as shown now: "185 °F", "12.6 AFR".
    public static string Format(double value, string unit, string fmt = "0.##")
    {
        var (v, u) = Display(value, unit);
        return v.ToString(fmt, CultureInfo.InvariantCulture) + (u.Length > 0 ? " " + u : "");
    }
}
