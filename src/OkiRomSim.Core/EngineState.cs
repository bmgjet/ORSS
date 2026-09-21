// Honda OBD1 D16Z6 / P28 Engine Simulator.
namespace OkiRomSim.Core;

public sealed class EngineState
{
    public double Rpm = 800.0;             // Normal idle RPM
    public double MapKpa = 30.0;           // Normal idle vacuum (~30 kPa)
    public double TpsPct = 0.0;            // Closed throttle
    public double EctCelsius = 85.0;       // Operating temp
    public double IatCelsius = 25.0;       // Ambient air temp
    public double O2Volts = 0.45;          // Stoichiometric lambda
    public double VbattVolts = 14.2;       // Alternator running voltage
    public double SpeedKmh = 0.0;

    public ulong CkpPulseCount;
    public ulong TdcPulseCount;
    public ulong LastInt0Cycle;

    // ---- crank / run state ------------------------------------------------

    /// True while the starter is turning the engine over. Cranking is its own operating region in the ROM (fixed timing, prime pulse, no closed loop), so it needs to be reachable as a distinct state rather than just "a low RPM".
    public bool Cranking;

    /// Battery sag while the starter is engaged. The ROM's low-voltage compensation branches only run below roughly 10V.
    public double CrankingVbattVolts = 9.2;

    /// Barometric pressure. Sea level ~101 kPa.
    public double BaroKpa = 101.0;

    /// Electrical load detector. Its P28 mux channel has not been traced, so it is kept for scenarios but not published on any ADC input.
    public double EldVolts = 1.5;

    /// Knock sensor intensity, 0..1. Not published: the knock input path is not traced.
    public double KnockIntensity;

    /// EGR valve lift feedback, P5.3/AI3.
    public double EgrLiftPct;

    /// Vehicle speed pulses on INT0. 4 pulses per metre is the usual Honda VSS scaling; the ROM's own speed calibration decides what that reads as.
    public double VssPulsesPerKm = 4000.0;
    public ulong VssPulseCount;
    public ulong LastVssCycle;

    /// 10-bit ADC counts for a voltage on the 5 V reference.
    public static ushort Counts(double volts) => (ushort)Clamp(Math.Round(volts / 5.0 * 1023.0), 0, 1023);

    /// Honda-style NTC thermistor (ECT/IAT) on a 2.2 kOhm pull-up: ~2.8 V at 20 C, ~0.7 V at 80 C, rising towards 5 V when cold.
    public static double ThermistorVolts(double celsius)
    {
        double r = 2250.0 * Math.Exp(3400.0 * (1.0 / (celsius + 273.15) - 1.0 / 298.15));
        return 5.0 * r / (r + 2200.0);
    }

    /// MAP/baro sensor voltage, from the tuning software's MAP byte scaling (kPa = (byte * 7.221 - 59) / 10, byte = volts * 255 / 5).
    public static double PressureVolts(double kpa) => (kpa * 10.0 + 59.0) / 7.221 * 5.0 / 255.0;

    /// Battery voltage through the ECU's input divider (20 V full scale).
    public static double BatteryPinVolts(double vbatt) => vbatt / 4.0;

    /// Update the P28 board's analog inputs from physical sensor parameters. Channel assignments are the ones the ROMs read (see Bus.P28*).
    public void SyncSensorsToBus(Bus bus)
    {
        var u6 = bus.P28MuxInputs[Bus.P28MuxU6Adcr0];
        var u5 = bus.P28MuxInputs[Bus.P28MuxU5Adcr1];

        bus.AdcInputs[Bus.P28AdcMap] = Counts(PressureVolts(MapKpa));
        // TPS: 0.5 V closed .. 4.5 V wide open.
        bus.AdcInputs[Bus.P28AdcTps] = Counts(0.5 + Clamp(TpsPct, 0, 100) / 100.0 * 4.0);
        bus.AdcInputs[Bus.P28AdcEgr] = Counts(0.5 + Clamp(EgrLiftPct, 0, 100) / 100.0 * 4.0);
        bus.AdcInputs[Bus.P28AdcBattery] = Counts(BatteryPinVolts(Cranking ? CrankingVbattVolts : VbattVolts));
        bus.AdcInputs[Bus.P28AdcAux] = 0;

        u6[Bus.P28U6EctSelect] = Counts(ThermistorVolts(EctCelsius));
        u6[Bus.P28U6IatSelect] = Counts(ThermistorVolts(IatCelsius));
        u6[Bus.P28U6BaroSelect] = Counts(PressureVolts(BaroKpa));
        u5[Bus.P28U5HegoSelect] = Counts(O2Volts);

        // Hand-set pin voltages win over the sensor models.
        foreach (var (key, volts) in AnalogOverrides)
        {
            if (key < 8) bus.AdcInputs[key] = Counts(volts);
            else if (key is >= 100 and < 108) u6[key - 100] = Counts(volts);
            else if (key is >= 200 and < 208) u5[key - 200] = Counts(volts);
        }
    }

    /// Voltages set by hand for analog inputs: key 0-7 is the direct pin AIn, 100+n is channel n of the ADCR0 mux (AI0), 200+n channel n of the ADCR1 mux (AI1).
    public readonly Dictionary<int, double> AnalogOverrides = new();

    private static double Clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

    /// Advance the vehicle-speed pulse train. Each pulse is an edge on INT0: the ROM's INT0 handler timestamps it against TM2 (counting TM2 overflows for slow pulses) and the VSS routine turns that period into road speed.
    private ushort AdvanceVss(ulong totalCycles, ulong cpuFreqHz)
    {
        if (SpeedKmh <= 0.0) { LastVssCycle = totalCycles; return 0; }
        double pulsesPerSecond = SpeedKmh * VssPulsesPerKm / 3600.0;
        if (pulsesPerSecond <= 0.0) return 0;
        double cyclesPerPulse = cpuFreqHz / pulsesPerSecond;
        if (totalCycles - LastVssCycle < cyclesPerPulse) return 0;
        // One edge per call is enough; if the model fell far behind (speed
        // just raised from zero) resynchronise rather than burst.
        LastVssCycle = totalCycles - LastVssCycle > 2 * cyclesPerPulse ? totalCycles : LastVssCycle + (ulong)cyclesPerPulse;
        VssPulseCount++;
        return 1 << Bus.IrqInt0;
    }

    private double _nextCkpCycle;

    /// Generate the distributor signals for the elapsed CPU cycles:
    /// * CKP (24 per cam rev): latches TM2 into TMR2 and raises the timer-2
    /// interrupt. The ROM never writes TMR2 after init, reads it as the
    /// tooth timestamp, and derives the crank period from it
    /// (rpm = 1,875,000 / period at the 375 kHz TM2 clock).
    /// * TDC (4 per cam rev, every 6th CKP): INT1.
    /// * CYP (1 per cam rev, 3 teeth after the cylinder-1 TDC): TRNS0 status bit.
    /// * VSS: INT0, see AdvanceVss.
    public ushort CheckDistributorPulses(Bus bus, ulong totalCycles, ulong cpuFreqHz)
    {
        ushort irq = AdvanceVss(totalCycles, cpuFreqHz);
        if (Rpm <= 0.0) { _nextCkpCycle = 0; return irq; }

        double cyclesPerCkp = cpuFreqHz * 60.0 / Rpm / 12.0;
        if (_nextCkpCycle == 0 || _nextCkpCycle > totalCycles + 2 * cyclesPerCkp)
            _nextCkpCycle = totalCycles + cyclesPerCkp;   // engine just started, or RPM jumped up
        if (totalCycles < _nextCkpCycle) return irq;

        _nextCkpCycle += cyclesPerCkp;
        if (_nextCkpCycle < totalCycles) _nextCkpCycle = totalCycles + cyclesPerCkp;  // fell behind: don't burst
        LastInt0Cycle = totalCycles;
        CkpPulseCount += 1;

        bus.CaptureTm2();
        irq |= (ushort)(1 << Bus.IrqTm2);

        if (CkpPulseCount % 6 == 0)
        {
            TdcPulseCount += 1;
            irq |= (ushort)(1 << Bus.IrqInt1);
        }
        // CYP lands three CKP teeth after cylinder 1's TDC: the ROMs' crank
        // sync check expects it with their within-TDC tooth counter at 3
        // (p08: "CMPB 0a2h, #003h") and logs a CYP fault otherwise.
        if (CkpPulseCount % 24 == 3) bus.SignalCyp();
        return irq;
    }
}
