// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Core;

/// The check-engine lamp and the codes behind it, as the Honda OBD1 ROMs here drive them. Traced from the ROMs (HTS115/HTS120 names; every P28-family ROM and the P13 do the same): - A fault sets a bit in the fault field (0B0h.. or 098h..). The DTC scanner turns bit n into a code through the table tbl_cfgvariant_map ([n+1]; the 0B4h word from [33+j]) and stores it with cfgvariant_set_flags: bit (code-1) of the stored-code array (31Eh on HTS, the custom ROMs and P08, 31Ah on P30/CromeGold, 330h on the P13) - the ones a backup-fuse pull clears. - The flash routine walks the stored array: index i flashes as code i+1, except 25->35, 26->36, 27->41 and 29->43. Tens are long flashes (1.3 s), units short ones (0.3 s), 3.5 s between codes. - The flash line always carries the codes (P28: P1.5, the LED on the ECU board; P13: 8255 PC4). The dash lamp (P28: P1.4; P13: PC3) is on while any code is stored and shows the flashes only with the service check connector jumped - after the 2 s bulb check at key-on.
public sealed class MilMonitor
{
    // ---------------------------------------------------------------- code numbering

    /// The code the lamp flashes for stored index i (bit i of the stored array).
    public static int FlashCode(int index) => (index + 1) switch { 25 => 35, 26 => 36, 27 => 41, 29 => 43, var c => c };

    /// tbl_cfgvariant_map from HTS115 (the same layout in every ROM here): fault bit n -> [n+1], bit j of the 0B4h word -> [33+j]; the value is the stored index + 1, 0 = not a code.
    static readonly byte[] FaultTable =
    {
        0x0B, 0x03, 0x06, 0x07, 0x05, 0x01, 0x08, 0x0A, 0x0B, 0x0C, 0x0C, 0x0D, 0x0E, 0x11, 0x00, 0x13,
        0x14, 0x15, 0x16, 0x17, 0x18, 0x1E, 0x1F, 0x00, 0x00, 0x19, 0x1A, 0x1B, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x04, 0x08, 0x09, 0x0F, 0x1E, 0x1F, 0x10, 0x13, 0x04, 0x08, 0x09, 0x00, 0x00, 0x00, 0x00,
    };

    /// The flashed code for bit `bit` (0-47) of the fault field, or null when that bit is no code.
    public static int? FaultBitCode(int bit)
    {
        int at = bit < 32 ? (bit <= 26 ? bit + 1 : -1) : 33 + (bit - 32);
        if (at < 0 || at >= FaultTable.Length || FaultTable[at] == 0) return null;
        return FlashCode(FaultTable[at] - 1);
    }

    public static readonly IReadOnlyDictionary<int, string> Names = new Dictionary<int, string>
    {
        [1] = "O2 sensor", [3] = "MAP sensor (voltage)", [4] = "crank position (CKP)", [5] = "MAP sensor (range)",
        [6] = "coolant temp (ECT)", [7] = "throttle position (TPS)", [8] = "TDC sensor", [9] = "cylinder position (CYP)",
        [10] = "intake air temp (IAT)", [11] = "ECU internal / checksum", [12] = "EGR lift sensor", [13] = "baro sensor",
        [14] = "idle air control (IACV)", [15] = "ignition output", [16] = "fuel injector", [17] = "vehicle speed (VSS)",
        [18] = "ignition timing adjust", [19] = "A/T lockup solenoid", [20] = "electrical load detector (ELD)",
        [21] = "VTEC solenoid", [22] = "VTEC pressure switch", [23] = "knock sensor",
        [24] = "knock circuit check (port A bits 0-2)", [30] = "A/T signal A", [31] = "A/T signal B",
        [35] = "P4.6 test (fault bit 25)", [36] = "P4.6 test (fault bit 26)",
        [41] = "O2 sensor heater", [43] = "fuel supply system",
    };

    public static string Name(int code) => Names.TryGetValue(code, out var n) ? n : "not named in the ROMs here";

    // ---------------------------------------------------------------- where each ROM keeps them

    /// The fault field's first byte: 0B0h or 098h, by which one the ROM latches faults into ("MB 0bXh.n, C" = C5 addr 38+n).
    public static int FaultFieldBase(byte[] rom)
    {
        int b0 = 0, b98 = 0;
        for (int i = 0; i + 2 < rom.Length; i++)
            if (rom[i] == 0xC5 && rom[i + 2] is >= 0x38 and <= 0x3F)
            {
                if (rom[i + 1] is >= 0xB0 and <= 0xB4) b0++;
                else if (rom[i + 1] is >= 0x98 and <= 0x9C) b98++;
            }
        return b98 > b0 ? 0x98 : 0xB0;
    }

    /// The stored-code array: cfgvariant_set_flags ends in a run of "SBR N16[X1]" (C0 lo hi 11), one per copy of the code bitmap; the stored one is the lowest at 300h or above. Null if not found.
    public static int? StoredArray(byte[] rom)
    {
        for (int i = 0; i + 12 <= rom.Length; i++)
        {
            var targets = new List<int>();
            for (int k = i; k + 4 <= rom.Length && rom[k] == 0xC0 && rom[k + 3] == 0x11; k += 4) targets.Add(rom[k + 1] | rom[k + 2] << 8);
            if (targets.Count >= 3 && targets.Where(t => t is >= 0x300 and < 0x440).OrderBy(t => t).FirstOrDefault() is int s and > 0) return s;
        }
        return null;
    }

    // ---------------------------------------------------------------- the lamp, live

    public bool Lamp { get; private set; }
    public bool Flash { get; private set; }
    /// Codes in the most recent complete round of flashes, in flash order.
    public IReadOnlyList<int> LastRound => _lastRound;
    /// Codes flashed so far in the round under way.
    public IReadOnlyList<int> CurrentRound => _round;
    /// The code being flashed right now, so far ("1" long + "3" short = 13), or null between codes.
    public (int Tens, int Units)? Flashing => _tens + _units > 0 ? (_tens, _units) : null;

    readonly List<int> _round = [], _lastRound = [];
    int _tens, _units;
    double _onAt, _offAt;
    bool _any;

    public void Reset()
    {
        _round.Clear(); _lastRound.Clear(); _tens = _units = 0; _onAt = _offAt = 0; _any = false; Lamp = Flash = false;
    }

    /// Called every few hundred instructions (Simulator.StepOne).
    public void Sample(Bus bus, ulong cycles)
    {
        double t = cycles / (double)Bus.CpuHz;
        Lamp = bus.MilLamp;
        bool f = bus.MilFlash;
        if (f && !Flash) _onAt = t;
        if (!f && Flash)
        {
            if (t - _onAt >= 0.8) _tens++; else _units++;
            _offAt = t; _any = true;
        }
        Flash = f;
        if (!f && _tens + _units > 0 && t - _offAt > 2.0)
        {
            int code = _tens * 10 + _units;
            _tens = _units = 0;
            if (_round.Contains(code)) { _lastRound.Clear(); _lastRound.AddRange(_round); _round.Clear(); }
            _round.Add(code);
        }
        // nothing flashed for a while: nothing stored
        if (!f && _any && t - _offAt > 12.0) { _lastRound.Clear(); _round.Clear(); _any = false; }
    }
}
