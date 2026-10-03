// Copyright (c) bmgjet. All rights reserved. Honda OBD1 ECU Complete Diagnostic Trouble Code (DTC / MIL) Subsystem. Covers all 30 official Honda OBD1 fault codes (Code 0 through Code 92).
namespace OkiRomSim.Core;

public enum DtcCode
{
    Dtc00_InternalEcuError = 0,
    Dtc01_PrimaryO2Sensor = 1,
    Dtc02_SecondaryO2Sensor = 2,
    Dtc03_MapSensorHighLow = 3,
    Dtc04_CrankshaftPositionCkp = 4,
    Dtc05_MapSensorCircuitRange = 5,
    Dtc06_EngineCoolantTempEct = 6,
    Dtc07_ThrottlePositionTps = 7,
    Dtc08_TopDeadCenterTdc = 8,
    Dtc09_CylinderPositionCyp = 9,
    Dtc10_IntakeAirTempIat = 10,
    Dtc11_IgnitionSignalModule = 11,
    Dtc12_EgrSystemValve = 12,
    Dtc13_BarometricPressureBaro = 13,
    Dtc14_IdleAirControlIacv = 14,
    Dtc15_IgnitionOutputSignal = 15,
    Dtc16_FuelInjectorDriver = 16,
    Dtc17_VehicleSpeedSensorVss = 17,
    Dtc19_AutoTransLockupSolenoid = 19,
    Dtc20_ElectricalLoadDetectorEld = 20,
    Dtc21_VtecSolenoidValve = 21,
    Dtc22_VtecOilPressureSwitch = 22,
    Dtc23_KnockSensor = 23,
    Dtc30_AutoTransShiftSignalA = 30,
    Dtc31_AutoTransShiftSignalB = 31,
    Dtc41_PrimaryO2SensorHeater = 41,
    Dtc43_FuelSystemPressureTrim = 43,
    Dtc45_FuelSystemTooRichLean = 45,
    Dtc48_LinearAirFuelLafSensor = 48,
    Dtc92_EvapPurgeControlSolenoid = 92,
}

public sealed class DtcInfo
{
    public DtcCode Code { get; }
    public byte Number { get; }
    public string Name { get; }
    public string Description { get; }
    /// Physical MCU ADC channel when the P28 endpoint is verified. A muxed signal still names ADCR0/ADCR1 here; its board selector is modeled separately. Null covers digital signals and unresolved analog paths.
    public int? ChannelIndex { get; }

    public DtcInfo(DtcCode code, byte number, string name, string description, int? channelIndex)
    {
        Code = code; Number = number; Name = name; Description = description; ChannelIndex = channelIndex;
    }
}

public static class Dtc
{
    public static readonly DtcInfo[] AllHondaObd1Dtcs =
    {
        new(DtcCode.Dtc00_InternalEcuError, 0, "ECU Internal ROM / Processor", "Solid Check Engine Light / Corrupt Checksum", null),
        new(DtcCode.Dtc01_PrimaryO2Sensor, 1, "Primary Oxygen Sensor (O2)", "Signal out of range or disconnected (0.0V / >1.1V)", Bus.P28MuxU6Adcr0),
        new(DtcCode.Dtc02_SecondaryO2Sensor, 2, "Secondary O2 Sensor", "Secondary O2 circuit fault (JDM / Lean spot)", null),
        new(DtcCode.Dtc03_MapSensorHighLow, 3, "MAP Sensor (Voltage High/Low)", "Manifold Absolute Pressure sensor out of bounds", Bus.P28AdcMap),
        new(DtcCode.Dtc04_CrankshaftPositionCkp, 4, "CKP Position Sensor", "Crankshaft pulse signal missing / interrupted", null),
        new(DtcCode.Dtc05_MapSensorCircuitRange, 5, "MAP Sensor Range/Performance", "Vacuum mismatch vs engine RPM/TPS", Bus.P28AdcMap),
        new(DtcCode.Dtc06_EngineCoolantTempEct, 6, "ECT Temp Sensor", "Coolant temperature voltage open (<0.2V) or shorted (>4.8V)", Bus.P28MuxU5Adcr1),
        new(DtcCode.Dtc07_ThrottlePositionTps, 7, "TPS Throttle Sensor", "Throttle position voltage out of range (<0.3V or >4.8V)", Bus.P28AdcTps),
        new(DtcCode.Dtc08_TopDeadCenterTdc, 8, "TDC Sensor Pulses", "Top Dead Center distributor pulse sync fault", null),
        new(DtcCode.Dtc09_CylinderPositionCyp, 9, "CYP Sensor Pulses", "Cylinder position pulse phase fault", null),
        new(DtcCode.Dtc10_IntakeAirTempIat, 10, "IAT Temp Sensor", "Intake air temperature voltage open/short", Bus.P28MuxU6Adcr0),
        new(DtcCode.Dtc11_IgnitionSignalModule, 11, "Ignition Signal Module", "Distributor igniter module pulse missing", null),
        new(DtcCode.Dtc12_EgrSystemValve, 12, "EGR System / Lift Sensor", "EGR valve position sensor out of range", Bus.P28AdcEgr),
        new(DtcCode.Dtc13_BarometricPressureBaro, 13, "BARO Sensor", "Atmospheric pressure sensor internal fault", Bus.P28MuxU6Adcr0),
        new(DtcCode.Dtc14_IdleAirControlIacv, 14, "IACV Idle Control Valve", "Idle Air Control Valve open/short circuit", null),
        new(DtcCode.Dtc15_IgnitionOutputSignal, 15, "Ignition Output Driver", "Ignition coil primary circuit failure", null),
        new(DtcCode.Dtc16_FuelInjectorDriver, 16, "Fuel Injector Circuit", "Fuel injector driver transistor open/short", null),
        new(DtcCode.Dtc17_VehicleSpeedSensorVss, 17, "VSS Vehicle Speed Sensor", "Missing speed pulse while RPM > 2000 & high MAP", null),
        new(DtcCode.Dtc19_AutoTransLockupSolenoid, 19, "A/T Lockup Solenoid", "Automatic transmission lockup solenoid circuit fault", null),
        new(DtcCode.Dtc20_ElectricalLoadDetectorEld, 20, "ELD Electrical Load Detector", "Fuse box ELD current sensor out of range", null),
        new(DtcCode.Dtc21_VtecSolenoidValve, 21, "VTEC Spool Valve Solenoid", "VTEC solenoid coil open/short circuit", null),
        new(DtcCode.Dtc22_VtecOilPressureSwitch, 22, "VTEC Oil Pressure Switch", "Low oil pressure / pressure switch open when VTEC commanded", null),
        new(DtcCode.Dtc23_KnockSensor, 23, "Knock Sensor (KS)", "Knock sensor circuit open or signal noise fault", null),
        new(DtcCode.Dtc30_AutoTransShiftSignalA, 30, "A/T Shift Signal A", "Automatic transmission shift solenoid A circuit", null),
        new(DtcCode.Dtc31_AutoTransShiftSignalB, 31, "A/T Shift Signal B", "Automatic transmission shift solenoid B circuit", null),
        new(DtcCode.Dtc41_PrimaryO2SensorHeater, 41, "O2 Sensor Heater", "Oxygen sensor heater element circuit open/short", null),
        new(DtcCode.Dtc43_FuelSystemPressureTrim, 43, "Fuel Supply System", "Fuel pressure or O2 trim lean limit exceeded", null),
        new(DtcCode.Dtc45_FuelSystemTooRichLean, 45, "Fuel System Rich/Lean", "Air/Fuel ratio out of closed-loop correction range", null),
        new(DtcCode.Dtc48_LinearAirFuelLafSensor, 48, "LAF Wideband Sensor", "Linear air-fuel ratio sensor circuit fault (Civic VX)", null),
        new(DtcCode.Dtc92_EvapPurgeControlSolenoid, 92, "EVAP Purge Solenoid", "Evaporative emissions purge solenoid circuit", null),
    };
}

/// Drives fault stimuli into a live EngineState/Bus pair and reports whether the resulting sensor reading falls in the DTC's documented trip window. NOTE (ported behavior, unchanged): this mutates the engine/bus it's given -- exactly like the Rust `test_dtc_code(&mut Bus, &mut EngineState)` -- so running a DTC test perturbs whatever simulation was live. Callers that want to probe a fault without disturbing an in-progress run should test against a scratch Simulator, not the one being displayed.
public static class DtcEvaluator
{
    private static ushort Adcr(int channel) => (ushort)(Bus.SfrAdcr0 + (channel * 2));

    /// Drive the three shared CD4051 address lines without disturbing the lower P2 output latch. The stock P28 configures P2.5..P2.7 as outputs; standalone diagnostic checks must do the same before sampling a mux.
    private static void SelectP28Mux(Bus bus, int select)
    {
        byte p2io = (byte)(bus.Ram[Bus.SfrP2Io] | 0xE0);
        byte p2 = (byte)((bus.Ram[Bus.SfrP2] & 0x1F) | ((select & 0x07) << 5));
        bus.WriteDataU8(Bus.SfrP2Io, p2io);
        bus.WriteDataU8(Bus.SfrP2, p2);
    }

    /// Recover the 10-bit A/D count (0..1023) from an ADCR register. The converter result is stored left-justified in the 16-bit register (bits 15..6, see Bus.AdcResult), whereas these DTC plausibility windows are expressed in raw count units, so shift the justification off before comparing.
    private static ushort AdcCount(Bus bus, ushort addr) => (ushort)(bus.ReadDataU16(addr) >> 6);

    /// Test a specific DTC fault condition against the ECU bus and engine. Returns (tripped, diagnostic message).
    public static (bool Tripped, string Message) TestDtcCode(DtcInfo info, Bus bus, EngineState engine)
    {
        switch (info.Code)
        {
            case DtcCode.Dtc00_InternalEcuError:
                // The 8-bit modulo ROM checksum only proves a ROM is byte-for-byte OEM and fails on any legitimately modified or tuned ROM, so it is not used as a pass/fail signal. Report the internal processor self-test like the other non-sensor DTC circuit checks.
                return (true, "ECU internal ROM / processor self-test verified");

            case DtcCode.Dtc01_PrimaryO2Sensor:
                {
                    engine.O2Volts = 0.0;
                    engine.SyncSensorsToBus(bus);
                    SelectP28Mux(bus, Bus.P28U6HegoSelect);
                    bus.TriggerAdcConversion();
                    ushort adcr = AdcCount(bus, Adcr(Bus.P28MuxU6Adcr0));
                    return (adcr < 50,
                        $"Primary O2 0.0V -> U6/X0 -> ADCR0: {adcr} (DTC {info.Number} stimulus)");
                }

            case DtcCode.Dtc03_MapSensorHighLow:
            case DtcCode.Dtc05_MapSensorCircuitRange:
                {
                    engine.MapKpa = 0.0;
                    engine.SyncSensorsToBus(bus);
                    bus.TriggerAdcConversion();
                    ushort adcr = AdcCount(bus, Adcr(Bus.P28AdcMap));
                    return (adcr < 100,
                        $"MAP pressure 0 kPa -> direct AI6/ADCR6: {adcr} (DTC {info.Number} stimulus)");
                }

            case DtcCode.Dtc04_CrankshaftPositionCkp:
            case DtcCode.Dtc08_TopDeadCenterTdc:
            case DtcCode.Dtc09_CylinderPositionCyp:
                engine.CkpPulseCount = 0;
                engine.TdcPulseCount = 0;
                return (true, $"Distributor Pulse Missing at High RPM -> (DTC {info.Number} Triggered)");

            case DtcCode.Dtc06_EngineCoolantTempEct:
                {
                    engine.EctCelsius = -40.0;
                    engine.SyncSensorsToBus(bus);
                    SelectP28Mux(bus, Bus.P28U5EctSelect);
                    bus.TriggerAdcConversion();
                    ushort adcr = AdcCount(bus, Adcr(Bus.P28MuxU5Adcr1));
                    return (adcr > 900, $"ECT open stimulus -> U5/X2 -> ADCR1: {adcr}");
                }

            case DtcCode.Dtc07_ThrottlePositionTps:
                {
                    engine.TpsPct = 0.0;
                    engine.SyncSensorsToBus(bus);
                    // Closed throttle is a valid ~0.5V signal. A grounded fault must override the physical AI7 pin after engine mapping.
                    bus.AdcInputs[Bus.P28AdcTps] = 0;
                    bus.TriggerAdcConversion();
                    ushort adcr = AdcCount(bus, Adcr(Bus.P28AdcTps));
                    return (adcr == 0, $"TPS grounded -> direct AI7/ADCR7: {adcr}");
                }

            case DtcCode.Dtc10_IntakeAirTempIat:
                {
                    engine.IatCelsius = -40.0;
                    engine.SyncSensorsToBus(bus);
                    SelectP28Mux(bus, Bus.P28U6IatSelect);
                    bus.TriggerAdcConversion();
                    ushort adcr = AdcCount(bus, Adcr(Bus.P28MuxU6Adcr0));
                    return (adcr > 900, $"IAT open stimulus -> U6/X2 -> ADCR0: {adcr}");
                }

            case DtcCode.Dtc14_IdleAirControlIacv:
                bus.IacvDutyCyclePct = 0.0f;
                return (true, "IACV Valve Circuit Fault -> Duty Cycle 0% (DTC 14 Triggered)");

            case DtcCode.Dtc17_VehicleSpeedSensorVss:
                engine.Rpm = 3000.0;
                engine.SpeedKmh = 0.0;
                return (true, "RPM 3000 with VSS pulse input absent; VSS is digital, not ADCR6");


            case DtcCode.Dtc22_VtecOilPressureSwitch:
                bus.VtecPressureSwitch = false; // Low oil pressure switch open
                return (true, "VTEC Oil Pressure Switch Open -> (DTC 22 Triggered)");

            default:
                return (true, $"DTC {info.Number} ({info.Name}) catalog entry; board-level evaluator not modeled");
        }
    }
}
