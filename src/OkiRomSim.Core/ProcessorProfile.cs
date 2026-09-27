// Copyright (c) bmgjet. All rights reserved.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OkiRomSim.Core;

/// Everything the toolchain assumes about the chip and the board around it: the part, its clock, memory map, SFR and vector names, pinout and what the board wires to each pin. Saved with every project as processor.json, so a project for another 66K part (the MSM66911 in OBD0 / P13 ECUs, say) can be described by editing that file by hand. What a profile changes: SFR names the assembler predefines and the disassembler prints, vector names, the clock rate (and so every simulated time base), which set of on-chip peripherals the simulator models, where the external 8255 is decoded, the chip drawing and pin descriptions, the injector numbering, and what the MCP server tells clients about the part. Two peripheral sets exist - the MSM66207 (OBD1 P28 family) and the MSM66911 (Honda P13 / P14) - so a ROM for either runs, not just disassembles. A third part would need its own set.
public sealed class ProcessorProfile
{
    public string Name { get; set; } = "MSM66207";
    public string Board { get; set; } = "Honda P28 (OBD1)";
    public string Description { get; set; } = "";
    /// Crystal on OSC0/OSC1, MHz.
    public double CrystalMHz { get; set; } = 10.0;
    /// Oscillator clocks per simulator machine cycle (Decoder.IntCycles counts machine cycles).
    public int ClockDivider { get; set; } = 4;
    /// Which on-chip peripherals the simulator should model: "66207" (the OBD1 P28 family) or "66911" (the Honda P13 / P14 part). The two have different register maps, timers, one-shots and injector drivers, so this decides whether a ROM can be *run* as well as read.
    public string Peripherals { get; set; } = "66207";
    public int RomSize { get; set; } = Bus.RomSize;
    public int RamSize { get; set; } = Bus.RamSize;
    /// Last byte of on-chip RAM; data addresses above it go out on the external bus.
    public int InternalRamEnd { get; set; } = 0x047F;
    /// 28 names: reset, BRK, WDT, NMI, the 16 maskable interrupts in IRQ/IE bit order, VCAL 0-7.
    public List<string> VectorNames { get; set; } = [.. BinDisassembler.DefaultVectorNames];
    /// SFR name -> data address, predefined by the assembler.
    public Dictionary<string, int> Sfrs { get; set; } = new(OkiRomSim.Assembler.OkiAssembler.DefaultSfrs);
    /// Package pin names by pin number - 1 ("P2.0", "P5.7/AI7", "VDD").
    public List<string> SdipPins { get; set; } = [];
    public List<string> QfpPins { get; set; } = [];
    /// What the board connects to each port pin ("P2.0" -> "injector 1 pattern bit").
    public Dictionary<string, string> PinFunctions { get; set; } = [];
    /// Descriptions of the power / control pins ("OSC0" -> "10 MHz crystal").
    public Dictionary<string, string> OtherPins { get; set; } = [];
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
        Bus.SetPeripheralSet(Peripherals);
        if (Ppi is { } ppi) Bus.SetPpi(ppi.PortA, ppi.PortB);
        AppLog.Info("processor", $"profile {Name} on {Board}: {CrystalMHz:0.##} MHz / {ClockDivider} " +
                                 $"({1000.0 / (CrystalMHz * 1000 / ClockDivider):0.###} us a machine cycle), " +
                                 $"{Sfrs.Count} SFRs, {Peripherals} peripherals");
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
        return p.ClockDivider <= 0 || p.CrystalMHz <= 0 ? throw new InvalidDataException("CrystalMHz and ClockDivider must be positive") : p;
    }

    public ProcessorProfile Clone() => FromJson(ToJson());

    public static IReadOnlyList<ProcessorProfile> Builtins() => new[] { Msm66207(), Msm66911() };

    public static ProcessorProfile? Builtin(string name) =>
        Builtins().FirstOrDefault(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase) || p.Board.Contains(name, StringComparison.OrdinalIgnoreCase));

    static readonly System.Text.RegularExpressions.Regex DeclaredRe =
        new(@"^\s*;\s*processor\s*[:=]\s*([A-Za-z0-9_]+)", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.Multiline);

    /// The part a source says it was written for, from a comment line "; processor: MSM66911" in its first 200 lines. A comment rather than a directive, so the file still goes through asm662. Null when the source does not say, or names a part there is no built-in profile for.
    public static ProcessorProfile? Declared(string source)
    {
        int end = 0;
        for (int n = 0; n < 200 && end >= 0 && end < source.Length; n++) end = source.IndexOf('\n', end + 1);
        var head = end < 0 ? source : source[..end];
        var m = DeclaredRe.Match(head);
        return m.Success ? Builtin(m.Groups[1].Value) : null;
    }

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
        SdipPins = [.. SdipDefault],
        QfpPins = [.. QfpDefault],
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
            ["P5.0"] = "U6 mux out: O2 sensor (0), IAT (2), baro (3), battery (7)",
            ["P5.1"] = "U5 mux out: ELD (0), ECT (2)",
            ["P5.2"] = "ALT FR (alternator field monitor)",
            ["P5.3"] = "EGR lift sensor",
            ["P5.4"] = "spare input (limiter enable)",
            ["P5.5"] = "spare input (battery voltage is on the U6 mux)",
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

    /// The OKI MSM66911 as used in the Honda P13 / P14 generation (and the P11, P12, P39 - one code base), from a stock P13-N51 image, the public P13 research notes and bench measurements on a real ECU. Nobody in the scene has the OKI datasheet for this part, so everything here is known from what the ROM does with each register and from what the hardware was seen to do; the lines that are still guesses say so. The important thing about it is that it is NOT a 66207 with a different name: 42 of the 66207 SFR names land on different peripherals here, and the interrupt vector at 0x0020 - which a widely-copied listing calls "A/D finished" - is the serial interrupt. Reading a 66911 listing against the 66207 register table is the single most expensive mistake available, so this profile replaces the names outright.
    public static ProcessorProfile Msm66911()
    {
        var p = new ProcessorProfile
        {
            Name = "MSM66911",
            Board = "Honda P13 / P14 (OBD1)",
            Description = "OKI MSM66911: nX-8/500-family core, 32 KB external EPROM, 1 KB RAM (0x0080-0x047F), a 4 us free-running " +
                          "timer with four capture channels, eight one-shot timers (four of them the injector drivers), two PWM " +
                          "channels (IACV and EGR), an 8-channel 12-bit A/D behind two analog multiplexers, and a UART with one " +
                          "shared RX/TX interrupt. Honda P11 / P12 / P13 / P14 / P39.",
            // 5 MHz with no divider: one machine cycle is 200 ns, so NOP - two cycles, one byte, like every 2*len instruction in the table - takes 400 ns. That is what was measured on the bench, and it is the figure the P13 serial-ISR cost estimate was built on (51 instructions, about 285 cycles). The 66207 runs its 10 MHz crystal through a divide-by-four for a 400 ns cycle; this part does not divide.
            CrystalMHz = 5.0,
            ClockDivider = 1,
            Peripherals = "66911",
            InternalRamEnd = 0x047F,
            InjectorOrder = [1, 3, 4, 2],
            VectorNames = [.. Vectors66911],
            Sfrs = Sfrs66911(),
            SdipPins = [.. Pins66911],
            QfpPins = [.. Pins66911],
            PinFunctions = new()
            {
                // P2 (0x28): pins 17-21 and 26-28
                ["P2.0"] = "serial RX (pin 17, CN2 pin 4)",
                ["P2.1"] = "serial TX (pin 18, CN2 pin 3)",
                ["P2.2"] = "ignition command to the ICM (pin 19): LOW = coil charging, HIGH = rest, spark on the rising edge",
                ["P2.3"] = "injector driver feedback (pin 20)",
                ["P2.4"] = "ICM feedback (pin 21) - the DTC 15 detector reads the edge latch for this",
                ["P2.5"] = "knock board clock, 433 Hz (pin 26)",
                ["P2.6"] = "cylinder position CYP (pin 27), one pulse per cycle",
                ["P2.7"] = "TDC sensor (pin 28), four pulses per cycle",
                // P3 (0x24): pins 38-45
                ["P3.0"] = "analog mux select A (pin 38)",
                ["P3.1"] = "analog mux select B (pin 39)",
                ["P3.2"] = "analog mux select C (pin 40)",
                ["P3.3"] = "ICM Sel# (pin 41): 0 = the CPU drives the igniter, 1 = the 7U016 limp-home spark",
                ["P3.4"] = "injector one-shot 0x4C (pin 42), active low while the pulse runs",
                ["P3.5"] = "injector one-shot 0x4E (pin 43)",
                ["P3.6"] = "injector one-shot 0x50 (pin 44)",
                ["P3.7"] = "injector one-shot 0x52 (pin 45)",
                // P4 (0x21): pins 46-53
                ["P4.0"] = "IACV (pin 46, PWM0)",
                ["P4.1"] = "CN3 knock header (pin 47), input as stock",
                ["P4.2"] = "CN3 knock header (pin 48), input as stock",
                ["P4.3"] = "CN3 knock header (pin 49), input as stock",
                ["P4.4"] = "EGR (pin 50, PWM1)",
                ["P4.5"] = "starter signal in (pin 51)",
                ["P4.6"] = "power steering pressure in (pin 52)",
                ["P4.7"] = "O2 heater feedback (pin 53)",
                // P5 (0x1E): analog inputs, pins 54-61
                ["P5.0"] = "mux IC6 output (pin 54)",
                ["P5.1"] = "mux IC5 output (pin 55) - between them: ECT, IAT, O2, ELD, battery, baro, knock",
                ["P5.2"] = "ALT FR, alternator field monitor (pin 56)",
                ["P5.3"] = "EGR lift sensor (pin 57)",
                ["P5.4"] = "IACV current (pin 58)",
                ["P5.5"] = "TCS (pin 59)",
                ["P5.6"] = "MAP sensor (pin 60)",
                ["P5.7"] = "throttle position TPS (pin 61)",
            },
            OtherPins = new()
            {
                ["VDD"] = "+5 V supply", ["GND"] = "ground",
                ["X1"] = "crystal (the frequency is not established; the timer tick it produces is 4.000 us)",
                ["NMI"] = "non-maskable interrupt (pin 33), driven by the 7U016 gate array pin 12 and the TA8903 reset IC",
                ["ALE"] = "address latch enable (pin 22, to the 74HC373 ROM latch IC16)",
                ["PSEN"] = "program strobe (pin 23, the 27C256 EPROM in IC3)",
                ["RD"] = "read strobe (pin 24)", ["WR"] = "write strobe (pin 25)",
                ["CKP"] = "crank position (pin 34), 12 teeth per revolution; captured into 0x58 through Int0",
                ["WDOG"] = "watchdog feed to the 7U016 (pin 35): stop toggling it and the gate array seizes the igniter",
            },
            Ppi = new PpiMap
            {
                PortA = 0x8000, PortB = 0xA000, PortC = 0xC000, Control = 0xE000,
                Wiring = "82C55 on the external bus. Port A = inputs (mirrored to RAM 0x224; its address is inferred from the " +
                         "pattern of the other three). Port B = outputs, written INVERTED (mirror 0x225): 0 A/C clutch, 1 fuel " +
                         "pump, 2 fan, 3 alternator control, 4 IAB, 5 ICS, 6 spare, 7 purge. Port C = outputs, written XOR 0x24 " +
                         "(mirror 0x226): 0/1 knock (CN3), 2 auto TCM, 3 MIL, 4 to 7U016 pin 40, 5 pull-up, 6/7 VTEC. " +
                         "Control: 0x9B at boot (all inputs), then 0x90 (A in, B and C out).",
            },
            Notes = Notes66911,
        };
        return p;
    }

    /// Vector = 0x0008 + 2*N for interrupt N. The 66207's slot names do not apply: 0x0020 is the shared serial RX/TX interrupt, not "A/D finished", and Int1 is triggered by software from Int0 as the crank-synchronous fuel and spark task.
    static readonly string[] Vectors66911 =
    {
        "int_start", "int_break", "int_WDT", "int_NMI",
        "int_ckp_tdc_capture",          // Int0  - CKP or TDC edge, captured into 0x58
        "int_crank_task",               // Int1  - timer 0x56 overflow; set by software from Int0
        "int_halt_timer",               // Int2
        "int_vss_capture",              // Int3  - VSS edge, capture 0x5E
        "int_timer_overflow",           // Int4  - the 0x56 counter wrapping; counted into 0xF7/0xF6
        "int_pwm0_pin",                 // Int5
        "int_pwm0_software",            // Int6
        "int_spare_2B0",                // Int7
        "int_spare_2B4",                // Int8
        "int_pwm1_pin",                 // Int9
        "int_tick_10ms",                // Int10 - the 10.24 ms housekeeping tick; sets 0x9E.3 for the main loop
        "int_adc_complete",             // Int11 - the ROM polls instead
        "int_serial",                   // Int12 - RX and TX share it (vector 0x0020)
        "int_ignition_oneshot",         // Int13
        "int_oneshots_44_4A",           // Int14
        "int_injector_oneshots",        // Int15
        "vcal_table_2byte", "vcal_table_3byte", "vcal_table_search", "vcal_3",
        "vcal_scheduler", "vcal_5", "vcal_negate16", "vcal_negate8",
    };

    /// The 64-pin package as the P13 board uses it. Pins 1-16 are the external bus (the ROM latch and the 27C256), which the notes do not break out pin by pin, so they are marked as such rather than guessed at.
    static readonly string[] Pins66911 =
    {
        "AD0?", "AD1?", "AD2?", "AD3?", "AD4?", "AD5?", "AD6?", "AD7?",
        "A8?", "A9?", "A10?", "A11?", "A12?", "A13?", "A14?", "A15?",
        "P2.0/RXD", "P2.1/TXD", "P2.2/IGN", "P2.3/INJFB", "P2.4/ICMFB", "ALE", "PSEN", "RD",
        "WR", "P2.5/KNKCLK", "P2.6/CYP", "P2.7/TDC", "n/c?", "X1", "X1", "n/c?",
        "NMI", "P2A.0/CKP", "P2A.1/WDOG", "P2A.2/O2H", "P2A.3/VSS", "P3.0/MUXA", "P3.1/MUXB", "P3.2/MUXC",
        "P3.3/ICMSEL", "P3.4/INJ", "P3.5/INJ", "P3.6/INJ", "P3.7/INJ", "P4.0/PWM0", "P4.1/CN3", "P4.2/CN3",
        "P4.3/CN3", "P4.4/PWM1", "P4.5/START", "P4.6/PSP", "P4.7/O2HFB", "P5.0/MUX6", "P5.1/MUX5", "P5.2/ALTFR",
        "P5.3/EGRL", "P5.4/IACVI", "P5.5/TCS", "P5.6/MAP", "P5.7/TPS", "VDD?", "GND?", "VDD?",
    };

    /// The 66911 SFR map as the stock P13 ROM uses it. Nothing here comes from a datasheet: each name is what the register demonstrably does. The boot values the ROM's own SFR integrity test (BRK code 0x4E) insists on are in Notes.
    static Dictionary<string, int> Sfrs66911()
    {
        var d = new Dictionary<string, int>
        {
            ["ASSP"] = 0x00, ["SSPH"] = 0x01, ["ALRB"] = 0x02, ["LRBH"] = 0x03,
            ["PSW"] = 0x04, ["zp_PSWH"] = 0x05, ["ACC"] = 0x06, ["ACCH"] = 0x07,
            ["PCLK"] = 0x0F,                    // clock / prescaler control, boots 0xA4
            ["SBYCON"] = 0x10, ["WDT"] = 0x11, ["STPACP"] = 0x13,
            ["IRQ"] = 0x18, ["IRQH"] = 0x19, ["IE"] = 0x1A, ["IEH"] = 0x1B, ["EXION"] = 0x1C,
            ["P5"] = 0x1E,                      // analog inputs, read-only
            ["P4SF"] = 0x1F, ["P4IO"] = 0x20, ["P4"] = 0x21,
            ["P3SF"] = 0x22, ["P3IO"] = 0x23, ["P3"] = 0x24,
            ["P2A"] = 0x25,                     // upper nibble direction, lower nibble data
            ["P2SF"] = 0x26, ["P2IO"] = 0x27, ["P2"] = 0x28,
            ["TRNSIT"] = 0x29,                  // edge latches, NOT a direction register
            ["PWM0CON"] = 0x2A, ["PWMIE"] = 0x2B, ["PWM1CON"] = 0x2C, ["PWMPRE"] = 0x2D,
            ["PWM0CMP"] = 0x2E, ["PWM0CMPH"] = 0x2F, ["PWM0CNT"] = 0x30, ["PWM0CNTH"] = 0x31,
            ["PWM1CMP"] = 0x3E, ["PWM1CMPH"] = 0x3F, ["PWM1CNT"] = 0x40, ["PWM1CNTH"] = 0x41,
            ["OSIE"] = 0x42,                    // one-shot interrupt enables
            ["TCON"] = 0x54, ["TCON2"] = 0x55,
            ["TIMER"] = 0x56, ["TIMERH"] = 0x57,       // free-running 16-bit up-counter, 4.000 us
            ["IGNCON"] = 0x61,
            ["IGNA"] = 0x62, ["IGNAH"] = 0x63,         // expiry drives pin 19 LOW  (coil on)
            ["IGNB"] = 0x64, ["IGNBH"] = 0x65,         // expiry drives pin 19 HIGH (spark)
            ["ADSCAN"] = 0x66, ["ADSEL"] = 0x67,
            ["STTMR"] = 0x78, ["STTM"] = 0x79,         // TX and RX baud reloads
            ["SCONA"] = 0x7A, ["SCONB"] = 0x7B,
            ["STBUF"] = 0x7C, ["SRBUF"] = 0x7D, ["SRSTAT"] = 0x7E,
        };
        // the four general one-shots (0x44-0x4A; the ROM uses the first three as main-loop stopwatches) and the four injector one-shots (0x4C-0x52, one per cylinder driver)
        for (int i = 0; i < 4; i++)
        {
            d[$"OS{i}"] = 0x44 + (i * 2); d[$"OS{i}H"] = 0x45 + (i * 2);
            d[$"INJ{i}"] = 0x4C + (i * 2); d[$"INJ{i}H"] = 0x4D + (i * 2);
        }
        // four capture registers: 0 = CKP/TDC (Int0), 3 = VSS (Int3); 1 and 2 are never touched
        for (int i = 0; i < 4; i++) { d[$"CAP{i}"] = 0x58 + (i * 2); d[$"CAP{i}H"] = 0x59 + (i * 2); }
        // eight 12-bit A/D results as 16-bit words; the high byte is the "raw" sensor byte a datalog streams
        for (int i = 0; i < 8; i++) { d[$"ADCR{i}"] = 0x68 + (i * 2); d[$"ADCR{i}H"] = 0x69 + (i * 2); }
        return d;
    }

    const string Notes66911 =
        "Known from a stock P13-N51 image, the public P13 research notes and bench work on a real ECU; there is no OKI " +
        "datasheet for this part in circulation.\n\n" +
        "CLOCK: 5 MHz with no divider - one machine cycle is 200 ns, and a NOP (one byte, two cycles) takes 400 ns, measured " +
        "on the bench. Every instruction costs 2 cycles per byte plus its own adjustment, so that single figure sets the whole " +
        "time base. The crystal can has not been read, but the instruction timing leaves little room for anything else.\n\n" +
        "MEMORY: SFRs 0x00-0x7F, pointer/register area 0x80-0x97, usable RAM 0x0080-0x047F. SSP starts at 0x047F and USP is " +
        "used as a frame pointer. The boot RAM test walks 0x86-0x47F and restores every word, so RAM survives a reset and the " +
        "ROM never clears it. ROM header 0x0038-0x003B; code starts at 0x003C. The image's 8-bit sum must be 0 (correction " +
        "byte at 0x7FFF) - checked twice, in full at 0x09B9 and 64 bytes at a time at 0x0CF1, both bypassed when the factory " +
        "debug byte at 0x7FF1 is 0x00.\n\n" +
        "TIMING: the 0x56 counter ticks every 4.000 us with PCLK 0xA4 and TCON 0x89, which is what makes rpm = 1875000 / " +
        "RAM[0x00AE] exact (the ROM averages six CKP tooth periods and shifts right twice, so that word is 45 degrees of " +
        "crank). CKP gives 12 teeth per revolution, TDC four pulses per cycle at teeth 3/9/15/21, CYP one per cycle. Without " +
        "CYP the ROM free-runs, re-aligned to TDC, without complaining. Ignition: pin 19 LOW charges the coil, the rising edge " +
        "is the spark; commanded dwell runs from about 5.9 ms at idle to 3.05 ms at 8000 rpm. Injector one-shots count down and " +
        "hold their pin low while running; 0xFFFF both stops one and is what the ROM writes to kill a pulse. The final fuel " +
        "word (RAM 0x382) is in the same 4 us ticks.\n\n" +
        "WATCHDOGS: two. The 7U016 gate array has to be fed by toggling pin 35, and the ROM has a runaway check of its own at " +
        "0x3944 - the gap between two runs of the 10.24 ms housekeeping routine must stay under 5000 ticks (20.0 ms), or it " +
        "resets with BRK code 0x57. About 9.8 ms of extra stall in the background loop is all it takes. Fuel and spark are not " +
        "in that loop; they run from the crank interrupt.\n\n" +
        "SELF-TESTS (BRK reason in RAM 0xD4, soft-reset budget in 0xD6): 0x46 CPU/PSW, 0x47 unexpected interrupt (every unused " +
        "vector points at 0x0742, which resets the ECU), 0x48 watchdog, 0x4A RAM, 0x4B ROM checksum, 0x4E SFR integrity, 0x4F " +
        "DTC checksum, 0x50 IE read-back, 0x52 serial RX vector not at 0x0043, 0x53 timer, 0x54/0x55 ignition and injector " +
        "one-shots, 0x56 ECU/ROM mismatch, 0x57 runaway, 0x58/0x59 EGR PWM counter, 0x5A IACV PWM counter, 0x63 normal boot.\n\n" +
        "The SFR integrity test at 0x0EBC runs every main-loop pass and insists on: PCLK 0x0F == 0xA4; P4SF & 0xEF == 0x01; " +
        "P4IO == 0x11; P3SF == 0xF0; P3IO == 0xFF; P2A & 0x60 == 0x60; P2SF & 0x0E == 0x06; PWM0CON == 0x03; PWM1CON & 0xEF == " +
        "0x6F; PWMPRE == 0x93; TCON & 0xEF == 0x89; TCON2 & 0x77 == 0; IGNCON & 0xB0 == 0x10; ADSCAN & 0x57 == 0x10; ADSEL & " +
        "0x4F == 0; STTMR == the reload the boot chose; SCONA & 0xF5 == 0x80; SCONB & 0xE5 == 0x80; SRSTAT & 0x30 == 0x20. " +
        "Any change to an SFR init is therefore a two-site edit - the init and this compare. IE must also read back whatever is " +
        "written to all sixteen bits (0x5555 / 0xAAAA), and the stock running value is 0x141B.\n\n" +
        "SERIAL: one interrupt for RX and TX (Int12, vector 0x0020); SRSTAT bit 7 = RX pending, bit 6 = TX done, bits 5/4 their " +
        "enables, and the handler clears the flags itself. Baud reloads in STTMR/STTM: 0x40 = 4800, 0x20 = 9600 (stock), 0x0F = " +
        "19200, 0x07 = 39063 (what everyone calls 38400), 0x04 = 62500. The stock handler at 0x0043 is a Honda diagnostic " +
        "protocol that answers nothing useful; datalogging ROMs replace it, and ROM 0x4E20 checks that the vector still points " +
        "at 0x0043 unless the debug byte is 0x00. CN2 pin 4 = ECU RX, pin 3 = ECU TX; cut J1 for a PC link.\n\n" +
        "UNRESOLVED: the boot value of serial control B - the notes give 0x81 and a self-test of '& 0xE5 == 0x80', and 0x81 " +
        "does not satisfy that, so one of the two is a digit out; the simulator uses 0x80, which is what the test the ROM " +
        "actually runs demands. Also: which cylinder each injector one-shot drives (the community timer notes say " +
        "pins 42/43/44/45 = cylinders 1/3/4/2, the pinout notes say 1/2/3/4, and nobody has put a scope on it - this profile " +
        "uses the firing order); the channel order inside the two analog multiplexers; the 82C55 port A address; pins 1-16; and " +
        "the six unused 16-bit register pairs at 0x32-0x3D.\n\n" +
        "RUNNING one: this part has its own peripheral model (Peripherals66911), so a P13 image runs as well as reads. What is " +
        "modelled: the 0x56 counter at 4 us with its CKP/TDC and VSS captures, Int0/Int1/Int3, Int4 on its wrap, the 10.24 ms Int10 the runaway " +
        "check lives on, all eight one-shots counting down and driving their pins (the four injector drivers measure their own " +
        "pulse widths), the ignition pair working the command pin between them, both PWM counters advancing, the eight A/D " +
        "channels as left-justified 16-bit words, the UART with its shared interrupt and the baud reload table, and the 82C55 " +
        "at 8000/A000/C000/E000. What is not: the PWM prescaler's exact divisor (both counters are ticked at the 4 us rate, " +
        "which is enough for the checks the ROM makes), the channel order inside the two analog multiplexers, and the 7U016 " +
        "gate array beyond its watchdog.";
}
