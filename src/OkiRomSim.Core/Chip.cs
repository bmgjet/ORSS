// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Core;

/// The part the program is set up for: its memory sizes, its clock, which on-chip peripherals it has and where the 8255 sits, as the
/// active ProcessorProfile sets them. What only needs to know the part - definitions, datalogging, the calibration editor, the tuner
/// build - reads it here and needs nothing of the simulator; the simulator's Bus reads the same values (Bus.CpuHz and the rest
/// hand on to these).
public static class Chip
{
    public const int RomSize = 32768; // 32KB ROM space (0x0000..0x7FFF)
    public const int RamSize = 4096;  // 4KB Data RAM & SFR space (0x0000..0x0FFF)

    /// The board carries a 10 MHz crystal (measured on OSC0/OSC1). The simulator's cycle counts (Decoder.IntCycles, from the instruction tables) run at fOSC/4 = 2.5 MHz, and the timers divide that by 8 = 312.5 kHz: at exactly that rate the ROMs' crank-period word reads 1,875,000 / rpm and a timer tick is 3.2 us - the tuning software's own rpm and injector scalings - and the boot delay lasts about as long as the check-engine light stays on at key-on (~4.5 s). The active ProcessorProfile sets both numbers.
    public static double CrystalMHz { get; private set; } = 10.0;
    /// Rate of the simulator's machine cycles, Hz (fOSC / 4).
    public static ulong CpuHz { get; private set; } = 2_500_000;
    /// Machine cycles per microsecond.
    public static double CyclesPerUs => CpuHz / 1_000_000.0;

    /// Oscillator clocks per machine cycle.
    public static int ClockDivider { get; private set; } = 4;

    /// Change the crystal (and the clocks per machine cycle). Affects simulators created or reset afterwards.
    public static void SetCrystal(double mhz, int divider = 4)
    {
        CrystalMHz = mhz;
        ClockDivider = Math.Max(1, divider);
        CpuHz = (ulong)(mhz * 1_000_000 / ClockDivider);
    }

    /// Which set of on-chip peripherals to model. "66207" is the OBD1 P28 family; "66911" is the Honda P13 / P14 part, whose registers are somewhere else entirely and whose timers, one-shots and injector drivers work differently (see Peripherals66911). The active ProcessorProfile sets it, and a simulator picks it up when it is created or reset.
    public static string PeripheralSet { get; private set; } = "66207";
    /// (kept as a flag: it is asked several times for every instruction the simulator runs)
    public static bool Is66911 { get; private set; }

    public static void SetPeripheralSet(string set)
    {
        Is66911 = set == "66911";
        PeripheralSet = Is66911 ? "66911" : "66207";
    }

    /// Where the external 82C55 sits. The P28 decodes it at 0F00/1F00/2F00/3F00 (A12-A13 pick the register); the P13 puts it at 8000/A000/C000/E000 (A13-A14). Set from the profile.
    public static int PpiPortA { get; private set; } = 0x0F00;
    public static int PpiStride { get; private set; } = 0x1000;

    public static void SetPpi(int portA, int portB)
    {
        PpiPortA = portA;
        PpiStride = Math.Max(1, portB - portA);
    }
}
