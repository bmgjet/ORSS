// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Core;

/// The check-engine lamp and the codes behind it, as the Honda OBD1 ROMs here drive them. Traced from the ROMs (HTS115/HTS120 names; every P28-family ROM and the P13 do the same): - A fault sets a bit in the fault field (0B0h.. or 098h..). The DTC scanner turns bit n into a code through the table tbl_cfgvariant_map ([n+1]; the 0B4h word from [33+j]) and stores it with cfgvariant_set_flags: bit (code-1) of the stored-code array (31Eh on HTS, the custom ROMs and P08, 31Ah on P30/CromeGold, 330h on the P13) - the ones a backup-fuse pull clears. - The flash routine walks the stored array: index i flashes as code i+1, except 25->35, 26->36, 27->41 and 29->43. Tens are long flashes (1.3 s), units short ones (0.3 s), 3.5 s between codes. - The flash line always carries the codes (P28: P1.5, the LED on the ECU board; P13: 8255 PC4). The dash lamp (P28: P1.4; P13: PC3) is on while any code is stored and shows the flashes only with the service check connector jumped - after the 2 s bulb check at key-on.
public sealed class MilMonitor
{
    // ---------------------------------------------------------------- code numbering, and where each ROM keeps them (MilCodes)

    /// The code the lamp flashes for stored index i (bit i of the stored array).
    public static int FlashCode(int index) => MilCodes.FlashCode(index);

    /// The flashed code for bit `bit` (0-47) of the fault field, or null when that bit is no code.
    public static int? FaultBitCode(int bit) => MilCodes.FaultBitCode(bit);

    public static IReadOnlyDictionary<int, string> Names => MilCodes.Names;

    public static string Name(int code) => MilCodes.Name(code);

    /// The fault field's first byte: 0B0h or 098h, by which one the ROM latches faults into.
    public static int FaultFieldBase(byte[] rom) => MilCodes.FaultFieldBase(rom);

    /// The stored-code array (MilCodes.StoredArray). Null if not found.
    public static int? StoredArray(byte[] rom) => MilCodes.StoredArray(rom);

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
