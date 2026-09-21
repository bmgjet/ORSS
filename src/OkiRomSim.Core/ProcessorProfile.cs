using System.Text.Json;
using System.Text.Json.Serialization;

namespace OkiRomSim.Core;

/// Everything the toolchain assumes about the chip and the board around it: the part, its clock, memory map, SFR and vector names, pinout and what the board wires to each pin. Saved with every project as processor.json, so a project for another 66K part (the MSM66911 in OBD0 / P13 ECUs, say) can be described by editing that file by hand.
/// What a profile changes: SFR names the assembler predefines and the disassembler prints, vector names, the clock rate (and so every simulated time base), the chip drawing and pin descriptions, the injector numbering, and what the MCP server tells agents about the part. What it cannot change: the simulator's peripheral model is the MSM66207's (timers, A/D, serial, ports), so a part with different peripherals disassembles, assembles and edits correctly but only runs as far as its peripherals match.
public sealed class ProcessorProfile
{
    public string Name { get; set; } = "MSM66207";
    public string Board { get; set; } = "Honda P28 (OBD1)";
    public string Description { get; set; } = "";
    /// Crystal on OSC0/OSC1, MHz.
    public double CrystalMHz { get; set; } = 10.0;
    /// Oscillator clocks per simulator machine cycle (Decoder.IntCycles counts machine cycles).
    public int ClockDivider { get; set; } = 4;
    public int RomSize { get; set; } = Bus.RomSize;
    public int RamSize { get; set; } = Bus.RamSize;
    /// Last byte of on-chip RAM; data addresses above it go out on the external bus.
    public int InternalRamEnd { get; set; } = 0x047F;
    /// 28 names: reset, BRK, WDT, NMI, the 16 maskable interrupts in IRQ/IE bit order, VCAL 0-7.
    public List<string> VectorNames { get; set; } = BinDisassembler.DefaultVectorNames.ToList();
    /// SFR name -> data address, predefined by the assembler.
    public Dictionary<string, int> Sfrs { get; set; } = new(OkiRomSim.Assembler.OkiAssembler.DefaultSfrs);
    /// Package pin names by pin number - 1 ("P2.0", "P5.7/AI7", "VDD").
    public List<string> SdipPins { get; set; } = new();
    public List<string> QfpPins { get; set; } = new();
    /// What the board connects to each port pin ("P2.0" -> "injector 1 pattern bit").
    public Dictionary<string, string> PinFunctions { get; set; } = new();
    /// Descriptions of the power / control pins ("OSC0" -> "10 MHz crystal").
    public Dictionary<string, string> OtherPins { get; set; } = new();
    /// Cylinder number of each injector pattern bit P2.0..P2.3 (the firing order on the P28).
    public int[] InjectorOrder { get; set; } = { 1, 3, 4, 2 };
    /// External 8255 PPI on the data bus: port A/B/C/control addresses (null when there is none).
    public PpiMap? Ppi { get; set; } = new();
    public string Notes { get; set; } = "";

    public sealed class PpiMap
    {
        public int PortA { get; set; } = 0x0F00;
        public int PortB { get; set; } = 0x1F00;
        public int PortC { get; set; } = 0x2F00;
        public int Control { get; set; } = 0x3F00;
        public string Wiring { get; set; } = "PB = copy of P0 (PB7 fuel pump relay), PC = copy of P1 (PC0 VTEC solenoid), PA = inputs";
    }

    // ------------------------------------------------------------------ the active profile

    public static event Action? Changed;

    /// Make this the active profile: names, clock, drawing. Restart the simulator afterwards so the new clock applies from reset.
    public void Apply()
    {
        Current = this;
        OkiRomSim.Assembler.OkiAssembler.UseSfrs(Sfrs);
        BinDisassembler.UseNames(VectorNames);
        Bus.SetCrystal(CrystalMHz, ClockDivider);
        AppLog.Info("processor", $"profile {Name} on {Board}: {CrystalMHz:0.##} MHz / {ClockDivider}, {Sfrs.Count} SFRs");
        Changed?.Invoke();
    }

    public string PinFunction(int port, int bit) =>
        PinFunctions.TryGetValue($"P{port}.{bit}", out var f) ? f : "";

    // ------------------------------------------------------------------ files

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, DefaultIgnoreCondition = JsonIgnoreCondition.Never };

    public string ToJson() => JsonSerializer.Serialize(this, Json);

    public static ProcessorProfile FromJson(string json)
    {
        var p = JsonSerializer.Deserialize<ProcessorProfile>(json, Json) ?? throw new InvalidDataException("empty processor profile");
        if (p.VectorNames.Count != 28) throw new InvalidDataException($"VectorNames needs 28 entries (4 fixed, 16 interrupts, 8 VCAL), has {p.VectorNames.Count}");
        if (p.ClockDivider <= 0 || p.CrystalMHz <= 0) throw new InvalidDataException("CrystalMHz and ClockDivider must be positive");
        return p;
    }

    public ProcessorProfile Clone() => FromJson(ToJson());

    public static IReadOnlyList<ProcessorProfile> Builtins() => new[] { Msm66207(), Msm66911() };

    public static ProcessorProfile? Builtin(string name) =>
        Builtins().FirstOrDefault(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase) || p.Board.Contains(name, StringComparison.OrdinalIgnoreCase));

    // ------------------------------------------------------------------ built-in parts

    static readonly string[] SdipDefault =
    {
        "P2.3/CLKOUT", "P0.0/AD0", "P0.1/AD1", "P0.2/AD2", "P0.3/AD3", "P0.4/AD4", "P0.5/AD5", "P0.6/AD6",
        "P0.7/AD7", "P1.0/A8", "P1.1/A9", "P1.2/A10", "P1.3/A11", "P1.4/A12", "P1.5/A13", "P1.6/A14",
        "P1.7/A15", "P2.0", "P2.1", "P2.2", "RESOUT", "ALE", "PSEN", "RD",
        "WR", "READY", "EA", "FLT", "RES", "OSC0", "OSC1", "GND",
        "NMI", "P2.4/HOLD", "P2.5/HLDA", "P2.6/TXC", "P2.7/RXC", "P3.0/TXD", "P3.1/RXD", "P3.2/INT0",
        "P3.3/INT1", "P3.4/TM0IO", "P3.5/TM1IO", "P3.6/TM2IO", "P3.7/TM3IO", "P4.0/TM0CK", "P4.1/TM1CK", "P4.2/PWM0",
        "P4.3/PWM1", "P4.4/TRNS0", "P4.5/TRNS1", "P4.6/TRNS2", "P4.7/TRNS3", "P5.0/AI0", "P5.1/AI1", "P5.2/AI2",
        "P5.3/AI3", "P5.4/AI4", "P5.5/AI5", "P5.6/AI6", "P5.7/AI7", "AGND", "VREF", "VDD",
    };

    static readonly string[] QfpDefault =
    {
        "P1.0/A8", "P1.1/A9", "P1.2/A10", "P1.3/A11", "P1.4/A12", "P1.5/A13", "P1.6/A14", "P1.7/A15",
        "P2.0", "P2.1", "P2.2", "P2.3/CLKOUT", "RESOUT", "ALE", "PSEN", "RD",
        "WR", "READY", "EA", "FLT", "RES", "OSC0", "OSC1", "GND",
        "NMI", "P2.4/HOLD", "P2.5/HLDA", "P2.6/TXC", "P2.7/RXC", "P3.0/TXD", "P3.1/RXD", "P3.2/INT0",
        "P3.3/INT1", "P3.4/TM0IO", "P3.5/TM1IO", "P3.6/TM2IO", "P3.7/TM3IO", "P4.0/TM0CK", "P4.1/TM1CK", "P4.2/PWM0",
        "P4.3/PWM1", "P4.4/TRNS0", "P4.5/TRNS1", "P4.6/TRNS2", "P4.7/TRNS3", "P5.0/AI0", "P5.1/AI1", "P5.2/AI2",
        "P5.3/AI3", "P5.4/AI4", "P5.5/AI5", "P5.6/AI6", "P5.7/AI7", "AGND", "VREF", "VDD",
        "P0.0/AD0", "P0.1/AD1", "P0.2/AD2", "P0.3/AD3", "P0.4/AD4", "P0.5/AD5", "P0.6/AD6", "P0.7/AD7",
    };

    public static ProcessorProfile Current { get; private set; } = Msm66207();

    /// The P28 board as measured with a multimeter (injectors, sensors, 8255, 10 MHz crystal).
    public static ProcessorProfile Msm66207() => new()
    {
        Name = "MSM66207",
        Board = "Honda P28 (OBD1)",
        Description = "OKI MSM66207: nX-8/200 core, 32 KB ROM, 1 KB RAM, 4 timers, 8-channel 10-bit A/D, UART, 2 PWM. " +
                      "Honda OBD1 ECUs (P28, P30, P72, P06...).",
        SdipPins = SdipDefault.ToList(),
        QfpPins = QfpDefault.ToList(),
        PinFunctions = new()
        {
            ["P0.7"] = "P0 latch -> 8255 PB7: fuel pump relay (low = on)",
            ["P1.0"] = "P1 latch -> 8255 PC0: VTEC solenoid (high = on)",
            ["P2.0"] = "injector 1 pattern bit (low = selected)",
            ["P2.1"] = "injector 3 pattern bit (low = selected)",
            ["P2.2"] = "injector 4 pattern bit (low = selected)",
            ["P2.3"] = "injector 2 pattern bit (low = selected)",
            ["P2.4"] = "watchdog heartbeat",
            ["P2.5"] = "analog mux select A",
            ["P2.6"] = "analog mux select B",
            ["P2.7"] = "analog mux select C",
            ["P3.0"] = "serial TX (datalog / diagnostics)",
            ["P3.1"] = "serial RX (datalog / diagnostics)",
            ["P3.2"] = "vehicle speed sensor VSS (INT0)",
            ["P3.3"] = "TDC sensor (INT1)",
            ["P3.4"] = "injector gate pulse (timer 0 output: opens the latched pattern)",
            ["P3.5"] = "IACV PWM (idle air control valve)",
            ["P3.6"] = "crank position CKP (timer-2 capture)",
            ["P3.7"] = "timer-3 compare output (ignition timing)",
            ["P4.1"] = "power-good sense (low = on)",
            ["P4.2"] = "EGR (PWM0)",
            ["P4.3"] = "A/T lockup (PWM1)",
            ["P4.4"] = "cylinder position CYP (TRNS0)",
            ["P4.5"] = "ICM test: igniter feedback (TRNS1)",
            ["P4.6"] = "injector test: driver feedback (TRNS2); some ROMs also test it in VTEC logic",
            ["P5.0"] = "U6 mux out: ECT (0), baro (3), IAT (7)",
            ["P5.1"] = "U5 mux out: O2 sensor (0)",
            ["P5.2"] = "ALT FR (alternator field monitor)",
            ["P5.3"] = "EGR lift sensor",
            ["P5.4"] = "spare input (limiter enable)",
            ["P5.5"] = "battery voltage",
            ["P5.6"] = "MAP sensor",
            ["P5.7"] = "throttle position TPS",
        },
        OtherPins = new()
        {
            ["VDD"] = "+5 V supply", ["GND"] = "ground", ["AGND"] = "A/D converter ground", ["VREF"] = "A/D reference (5 V)",
            ["OSC0"] = "10 MHz crystal", ["OSC1"] = "10 MHz crystal", ["RES"] = "reset input", ["NMI"] = "non-maskable interrupt (falling edge)",
            ["EA"] = "high: run from internal ROM", ["ALE"] = "address latch enable (external bus to the 8255 PPI)", ["PSEN"] = "program strobe (external bus)",
            ["RD"] = "read strobe (external bus)", ["WR"] = "write strobe (external bus)", ["READY"] = "wait-state input",
            ["FLT"] = "bus float at reset", ["RESOUT"] = "reset output",
        },
        Notes = "Injectors are not timed per channel: the ROM latches the wanted pattern on P2.0-P2.3 and one timer-0 gate pulse " +
                "on P3.4 opens it. The 8255 at 0F00/1F00/2F00/3F00 (control 90h) mirrors P0 on port B and P1 on port C; the ROM " +
                "reads them back and traps (4Dh) on a mismatch.",
    };

    /// OBD0 / P13 prototype: an MSM66911-family part. Starts as a copy of the 66207 with the vector names the P13 ROM uses (serial baud-rate generator interrupts in place of the 66207's spare IRQ3/IRQ14). Pin functions are unknown until measured: edit processor.json.
    public static ProcessorProfile Msm66911()
    {
        var p = Msm66207();
        p.Name = "MSM66911";
        p.Board = "Honda P13 / OBD0 (prototype)";
        p.Description = "OKI 66911-family part used in OBD0 ECUs. SFRs are taken as the 66207's until checked against the " +
                        "datasheet; the vector layout follows reference/p13-rom/main.asm.";
        p.VectorNames = new()
        {
            "int_start", "int_break", "int_WDT", "int_NMI",
            "int_INT0", "int_serial_rx", "int_serial_tx", "int_serial_rx_BRG",
            "int_timer_0_overflow", "int_timer_0", "int_timer_1_overflow", "int_timer_1",
            "int_timer_2_overflow", "int_timer_2", "int_timer_3_overflow", "int_timer_3",
            "int_a2d_finished", "int_PWM_timer", "int_serial_tx_BRG", "int_INT1",
            "vcal_0", "vcal_1", "vcal_2", "vcal_3", "vcal_4", "vcal_5", "vcal_6", "vcal_7",
        };
        p.PinFunctions = new();
        p.InjectorOrder = new[] { 1, 2, 3, 4 };
        p.Ppi = null;
        p.Notes = "Prototype profile: measure the board and fill in PinFunctions, the package pin lists, the crystal and the " +
                  "injector order. The simulator's peripherals are the 66207's.";
        return p;
    }
}
