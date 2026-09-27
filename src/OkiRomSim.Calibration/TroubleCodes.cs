// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Core;

namespace OkiRomSim.Calibration;

/// The OBD1 Honda trouble codes a datalog frame carries: four bytes, one bit per code (the 51-byte frame's bytes 12-15, or the skeleton ROM's codes channel) - a copy of the ROM's stored-code array (31Ah-31Dh on P30, 31Eh on the P28 family and HTS), numbered as the ROM's own flash routine numbers them (MilMonitor.FlashCode: bit i is code i+1, but 24 is 35, 25 is 36, 26 is 41 and 28 is 43). The service commands the skeleton ROM's datalog answers (p30-features/dlservice.asm) are here too.
public static class TroubleCodes
{
    /// The code a bit stands for (bit 0-31 of the four bytes).
    public static int CodeOf(int bit) => MilMonitor.FlashCode(bit);

    public static string Describe(int code) => MilMonitor.Name(code);

    /// The codes set in four bytes (low bit of the first byte first).
    public static List<int> Decode(ReadOnlySpan<byte> bytes)
    {
        var list = new List<int>();
        for (int bit = 0; bit < Math.Min(32, bytes.Length * 8); bit++)
            if ((bytes[bit / 8] >> (bit % 8) & 1) != 0 && CodeOf(bit) is int c and > 0) list.Add(c);
        return list;
    }

    /// The four code bytes a frame carries, or null when it carries none: the skeleton ROM's codes channel, or the 51-byte frame (the 20h / 90h table, asked for directly or through a Demon), whose bytes 12-15 they are, or the QD3 frame (bytes 36-39).
    public static byte[]? Bytes(LogFrame f)
    {
        if (f.Get("dtc0") is double d0)
            return [(byte)d0, (byte)(f.Get("dtc1") ?? 0), (byte)(f.Get("dtc2") ?? 0), (byte)(f.Get("dtc3") ?? 0)];
        if (f.Raw is { Length: HondaDatalog.FrameLength } raw && f.Protocol is { } p && !p.StartsWith("Channel stream", StringComparison.Ordinal))
            return raw[12..16];
        // the QD3 frame: bytes 36-39
        if (f.Raw is { Length: 40 } q && q[0] == 0x46 && q[1] == 0x26) return q[36..40];
        return null;
    }

    // ---------------------------------------------------------------- the service commands (dlservice.asm)
    public const byte ClearCodes = 0x50, InjectorsOff = 0x51, InjectorsOn = 0x52, TimingLock = 0x53, TimingNormal = 0x54,
                      MapsBySwitch = 0x55, MapsFirst = 0x56, MapsSecond = 0x57, Gio1 = 0x58, AllNormal = 0x5E, State = 0x5F;
    /// The answer a ROM gives to a command it cannot carry out (the module it needs is not built in).
    public const byte Refused = 0x7F;

    /// The service state byte (the answer to 5Fh), read out.
    public sealed record ServiceState(bool InjectorsOff, bool TimingLocked, bool MapsChosen, bool SecondMaps, bool[] GioForced)
    {
        public static ServiceState From(byte b) => new((b & 1) != 0, (b & 2) != 0, (b & 4) != 0, (b & 8) != 0,
            [(b & 0x10) != 0, (b & 0x20) != 0, (b & 0x40) != 0, (b & 0x80) != 0]);
        public bool Any => InjectorsOff || TimingLocked;
    }
}
