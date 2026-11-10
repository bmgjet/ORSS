// Copyright (c) bmgjet. All rights reserved.
// Honda OBD1 D16Z6 / P28 Engine Simulator.
namespace OkiRomSim.Core;

/// A distributor sensor playing up, for the trigger pattern screen to find: each happens once a cam revolution (24 crank teeth).
public enum TriggerFault
{
    None,
    /// The crank (CKP) sensor misses one tooth (a gap, a loose connector, a damaged reluctor).
    CkpMissedTooth,
    /// An extra crank pulse halfway between two teeth (noise on the CKP line: a bad shield, a coil lead beside it).
    CkpExtraPulse,
    /// One of the four TDC pulses missing.
    TdcMissing,
    /// No cylinder (CYP) pulse at all.
    CypMissing,
    /// The cylinder pulse two teeth late (a slipped distributor, a misaligned sensor).
    CypLate,
}

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
    /// A/C switch (P28 pin B5), on the 4700h switch buffer bit 2.
    public bool AcRequest;

    public ulong CkpPulseCount;
    public ulong TdcPulseCount;
    public ulong LastInt0Cycle;

    // ---- crank / run state ------------------------------------------------

    /// True while the starter is turning the engine over. Cranking is its own operating region in the ROM (fixed timing, prime pulse, no closed loop), so it needs to be reachable as a distinct state rather than just "a low RPM".
    public bool Cranking;

    /// A distributor sensor fault to simulate (the trigger pattern screen).
    public TriggerFault Trigger;
    private double _extraCkpCycle;

    /// Battery sag while the starter is engaged. The ROM's low-voltage compensation branches only run below roughly 10V.
    public double CrankingVbattVolts = 9.2;

    /// Barometric pressure. Sea level ~101 kPa.
    public double BaroKpa = 101.0;

    /// Electrical load detector, on the ADCR1 multiplexer position 0 (datalog byte 24).
    public double EldVolts = 1.5;

    /// Knock sensor intensity, 0..1. Not published: the knock input path is not traced.
    public double KnockIntensity;

    /// EGR valve lift feedback, P5.3/AI3.
    public double EgrLiftPct;

    /// Vehicle speed pulses on INT0. Honda's VSS gives 2548 pulses per km: that is what the stock speed constant (VSS period -> 0CCh km/h, 25FB4h / period in the P28/P30 family) reads correctly, measured 1.57x high at 4000.
    public double VssPulsesPerKm = 2548.0;
    public ulong VssPulseCount;
    public ulong LastVssCycle;

    /// Forget the pulse-train timing: the CPU's cycle count restarts at 0 on a reset.
    public void ResetTiming()
    {
        CkpPulseCount = TdcPulseCount = LastInt0Cycle = VssPulseCount = LastVssCycle = 0;
        _nextCkpCycle = 0;
    }

    /// 10-bit ADC counts for a voltage on the 5 V reference.
    public static ushort Counts(double volts) => (ushort)Clamp(Math.Round(volts / 5.0 * 1023.0), 0, 1023);

    /// Honda-style NTC thermistor (ECT/IAT) on a 2.2 kOhm pull-up: ~2.8 V at 20 C, ~0.7 V at 80 C, rising towards 5 V when cold.
    public static double ThermistorVolts(double celsius)
    {
        double r = 2250.0 * Math.Exp(3400.0 * ((1.0 / (celsius + 273.15)) - (1.0 / 298.15)));
        return 5.0 * r / (r + 2200.0);
    }

    /// MAP/baro sensor voltage, from the tuning software's MAP byte scaling (kPa = (byte * 7.221 - 59) / 10, byte = volts * 255 / 5).
    public static double PressureVolts(double kpa) => ((kpa * 10.0) + 59.0) / 7.221 * 5.0 / 255.0;

    /// Battery voltage through the ECU's input divider: the scaling the datalog tools read it back with (volts = 26 x byte / 270), i.e. about 24.5 V full scale.
    public static double BatteryPinVolts(double vbatt) => vbatt * 270.0 / 26.0 * 5.0 / 255.0;

    /// Update the P28 board's analog inputs from physical sensor parameters. Channel assignments are the ones the ROMs read (see Bus.P28*).
    public void SyncSensorsToBus(Bus bus)
    {
        var u6 = bus.P28MuxInputs[Bus.P28MuxU6Adcr0];
        var u5 = bus.P28MuxInputs[Bus.P28MuxU5Adcr1];

        bus.AdcInputs[Bus.P28AdcMap] = Counts(PressureVolts(MapKpa));
        // TPS: 0.5 V closed .. 4.5 V wide open.
        bus.AdcInputs[Bus.P28AdcTps] = Counts(0.5 + (Clamp(TpsPct, 0, 100) / 100.0 * 4.0));
        bus.AdcInputs[Bus.P28AdcEgr] = Counts(0.5 + (Clamp(EgrLiftPct, 0, 100) / 100.0 * 4.0));
        bus.AdcInputs[Bus.P28AdcAux] = 0;
        // 4700h buffer: bit 0 start signal (on while cranking), bit 2 A/C request
        bus.SwitchLatch = (byte)((bus.SwitchLatch & ~0x05) | (Cranking ? 0x01 : 0) | (AcRequest ? 0x04 : 0));

        if (Bus.Is66911)
        {
            // P13: where the ROM files each mux position (0x3D0+n for ADCR0, 0x3D8+n for ADCR1) and the code that consumes those slots: 0x3D0 O2, 0x3D2 IAT, 0x3D3 baro, 0x3DA coolant
            // O2: lean (0.05 V) once no injector has fired for 0.2 s with the engine turning - no fuel, no exhaust to read
            // rich. The P13's O2 checks expect it (a stuck reading through a fuel cut is a fault to them).
            ulong sinceFuel = bus.ElapsedCycles - bus.InjectorLastEventAt.Max();
            bool noFuel = Rpm > 0 && !Cranking && sinceFuel > Bus.CpuHz / 5;
            u6[0] = Counts(noFuel ? 0.05 : O2Volts);
            // EGR lift (ADCR3): a valve that does what it is asked. The ROM closes a loop on it (p13.asm, before
            // idle_init_start_load_adcr3h): the closed valve's reading becomes its zero (293h, taken only between 31h and
            // 5Ch: 0.96-1.8 V), the lift it wants is 294h over that, and code 12 follows when the two stay apart. How its
            // PWM1 duty moves a real valve is not established, so the lift here is the target itself, from a 1.2 V closed
            // valve (EgrLiftPct adds to it).
            int closed = Counts(1.2 + (Clamp(EgrLiftPct, 0, 100) / 100.0 * 3.3)), zero = bus.Ram[0x293];
            bus.AdcInputs[Bus.P28AdcEgr] = (ushort)Math.Min(1023, (zero is >= 0x31 and <= 0x5C ? zero * 4 + 2 : closed) + bus.Ram[0x294] * 4);
            u6[2] = Counts(ThermistorVolts(IatCelsius));
            u6[3] = Counts(PressureVolts(BaroKpa));
            // the battery is a direct input on the P13 (ADCR2, 0DCh), through the same divider as the P30's
            bus.AdcInputs[2] = Counts(BatteryPinVolts(Cranking ? CrankingVbattVolts : VbattVolts));
            // ...and on ADCR0's position 7 (0x3D7 -> 0DBh), the battery byte the injector dead time, the dwell and the gates
            // of the code 17 and code 20 checks read
            u6[7] = Counts(BatteryPinVolts(Cranking ? CrankingVbattVolts : VbattVolts));
            u5[2] = Counts(ThermistorVolts(EctCelsius));
            // the electrical load detector: ADCR1's position 0 (0x3D8), as the P30's - code 20 when it reads above DCh or below 0Eh
            u5[0] = Counts(EldVolts);
            bus.Knock = KnockIntensity;
            // the starter signal (P4.5): on while the starter turns - cranking, or turning under 400 rpm - or held on
            bus.StarterSignal = bus.StarterHeld || Cranking || (Rpm > 0 && Rpm < 400);
            // Board coding: mux position 1 of each bank is a fixed divider, not a sensor. The boot (0x0F7C) turns each into a band 0-3, looks band_A * 5 + band_B up at 0x6D56 and resets with BRK 0x56 ("wrong ECU for this ROM") on 0xFF. Only 3,2 (-> 0x12) and 3,3 (-> 0x13) are valid in the stock image; 3.75 V / 2.5 V gives the first.
            u6[1] = Counts(3.75);
            // P5.4 (pin 57, IACVI) is the IACV coil current. The ROM closes a loop on it (0x39E0): PWM0's compare (0xA0..0x800) is wound until ADCR4 meets the idle target in 0x26E, and code 14 is logged when the loop runs out of range. Current follows duty.
            bus.AdcInputs[4] = Counts(4.0 * Clamp((bus.Ram[0x2E] | (bus.Ram[0x2F] << 8)) / 2048.0, 0, 1));
            u5[1] = Counts(3.75);
        }
        else
        {
            u6[Bus.P28U6HegoSelect] = Counts(O2Volts);
            u6[Bus.P28U6IatSelect] = Counts(ThermistorVolts(IatCelsius));
            u6[Bus.P28U6BaroSelect] = Counts(PressureVolts(BaroKpa));
            u6[Bus.P28U6BatterySelect] = Counts(BatteryPinVolts(Cranking ? CrankingVbattVolts : VbattVolts));
            u5[Bus.P28U5EldSelect] = Counts(EldVolts);
            u5[Bus.P28U5EctSelect] = Counts(ThermistorVolts(EctCelsius));
        }

        // Hand-set pin voltages win over the sensor models.
        foreach (var (key, volts) in AnalogOverrides)
        {
            if (key < 8) bus.AdcInputs[key] = Counts(volts);
            else if (key is >= 100 and < 108) u6[key - 100] = Counts(volts);
            else if (key is >= 200 and < 208) u5[key - 200] = Counts(volts);
        }
    }

    /// Voltages set by hand for analog inputs: key 0-7 is the direct pin AIn, 100+n is channel n of the ADCR0 mux (AI0), 200+n channel n of the ADCR1 mux (AI1).
    public readonly Dictionary<int, double> AnalogOverrides = [];

    private static double Clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

    /// Advance the vehicle-speed pulse train. Each pulse is an edge on INT0: the ROM's INT0 handler timestamps it against TM2 (counting TM2 overflows for slow pulses) and the VSS routine turns that period into road speed.
    private ushort AdvanceVss(Bus bus, ulong totalCycles, ulong cpuFreqHz)
    {
        if (SpeedKmh <= 0.0) { LastVssCycle = totalCycles; return 0; }
        double pulsesPerSecond = SpeedKmh * VssPulsesPerKm / 3600.0;
        if (pulsesPerSecond <= 0.0) return 0;
        double cyclesPerPulse = cpuFreqHz / pulsesPerSecond;
        if (totalCycles - LastVssCycle < cyclesPerPulse) return 0;
        // One edge per call is enough; if the model fell far behind (speed just raised from zero) resynchronise rather than burst.
        LastVssCycle = totalCycles - LastVssCycle > 2 * cyclesPerPulse ? totalCycles : LastVssCycle + (ulong)cyclesPerPulse;
        VssPulseCount++;
        // the 66207 reports road speed on INT0; the 66911 captures the free-running counter into 0x5E and calls it Int3
        return Bus.Is66911 ? bus.CaptureVss() : (ushort)(1 << Bus.IrqInt0);
    }

    private double _nextCkpCycle;

    /// Generate the distributor signals for the elapsed CPU cycles: * CKP (24 per cam rev): latches TM2 into TMR2 and raises the timer-2 interrupt. The ROM never writes TMR2 after init, reads it as the tooth timestamp, and derives the crank period from it (rpm = 1,875,000 / period at the 375 kHz TM2 clock). * TDC (4 per cam rev, every 6th CKP): INT1. * CYP (1 per cam rev, 3 teeth after the cylinder-1 TDC): TRNS0 status bit. * VSS: INT0, see AdvanceVss.
    public ushort CheckDistributorPulses(Bus bus, ulong totalCycles, ulong cpuFreqHz)
    {
        ushort irq = AdvanceVss(bus, totalCycles, cpuFreqHz);
        if (Rpm <= 0.0) { _nextCkpCycle = 0; return irq; }

        double cyclesPerCkp = cpuFreqHz * 60.0 / Rpm / 12.0;
        if (_extraCkpCycle > 0 && totalCycles >= _extraCkpCycle)
        {
            // the noise pulse: a capture and its interrupt like any tooth, but no tooth of the pattern
            _extraCkpCycle = 0;
            bus.CaptureTm2();
            if (Bus.Is66911) irq |= bus.TakeCrankIrq(); else irq |= (ushort)(1 << Bus.IrqTm2);
            return irq;
        }
        if (_nextCkpCycle == 0 || _nextCkpCycle > totalCycles + (2 * cyclesPerCkp))
            _nextCkpCycle = totalCycles + cyclesPerCkp;   // engine just started, or RPM jumped up
        if (totalCycles < _nextCkpCycle) return irq;

        _nextCkpCycle += cyclesPerCkp;
        if (_nextCkpCycle < totalCycles) _nextCkpCycle = totalCycles + cyclesPerCkp;  // fell behind: don't burst
        LastInt0Cycle = totalCycles;
        CkpPulseCount += 1;

        // a simulated sensor fault, once a cam revolution: tooth 10 missed, or a noise pulse half a tooth after tooth 14
        if (Trigger == TriggerFault.CkpMissedTooth && CkpPulseCount % 24 == 10) return irq;
        if (Trigger == TriggerFault.CkpExtraPulse && CkpPulseCount % 24 == 14) _extraCkpCycle = totalCycles + (cyclesPerCkp / 2);

        bus.CaptureTm2();
        // The tooth pattern is the same on both parts - twelve teeth a revolution, TDC every sixth, CYP once a cycle - but the registers and interrupts are not. The 66207 captures into TMR2 and calls that interrupt 2; the 66911 captures into 0x58 and calls it Int0, with TDC arriving on the same pin when TCON bit 4 says so.
        if (Bus.Is66911)
        {
            irq |= bus.TakeCrankIrq();
            if (CkpPulseCount % 6 == 0 && !(Trigger == TriggerFault.TdcMissing && CkpPulseCount % 24 == 12)) { TdcPulseCount += 1; bus.SignalTdc(); }
        }
        else
        {
            irq |= (ushort)(1 << Bus.IrqTm2);
            if (CkpPulseCount % 6 == 0 && !(Trigger == TriggerFault.TdcMissing && CkpPulseCount % 24 == 12))
            {
                TdcPulseCount += 1;
                irq |= (ushort)(1 << Bus.IrqInt1);
            }
        }
        // CYP lands three CKP teeth after cylinder 1's TDC: the ROMs' crank sync check expects it with their within-TDC tooth counter at 3 (p08: "CMPB 0a2h, #003h") and logs a CYP fault otherwise.
        if (Trigger != TriggerFault.CypMissing && CkpPulseCount % 24 == (Trigger == TriggerFault.CypLate ? 5UL : 3UL)) bus.SignalCyp();
        return irq;
    }
}
