// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Assembler;

namespace OkiRomSim.Calibration;

/// The ROM's own checksum: the ECU adds up every byte of the image and refuses to run (BRK 43h/48h) unless the 8-bit sum is 0. One byte is set aside to make it so; after any change to the image that byte is put right again, so an edited calibration, a saved .bin and an emulator upload all pass.
public static class RomChecksum
{
    public static int Sum(byte[] rom)
    {
        int s = 0;
        foreach (var b in rom) s += b;
        return s & 0xFF;
    }

    /// The byte that balances the sum: the one a "checksum" directive in the source placed, or - for an image that already sums to 0 without one (a stock ROM) - the last byte of the free space at the top of the ROM, which no code or table reads. Null when the image does not keep its sum at 0.
    public static int? Site(byte[] rom, AssemblyResult? asm = null)
    {
        if (asm?.ChecksumAddress is int at) return at;
        if (rom.Length == 0 || Sum(rom) != 0) return null;
        // a run of at least 16 FFh bytes the assembler did not place anything in: the last byte of it
        int run = 0;
        for (int a = rom.Length - 1; a >= rom.Length / 2; a--)
        {
            bool free = rom[a] == 0xFF && (asm == null || a >= asm.Used.Length || !asm.Used[a]);
            run = free ? run + 1 : 0;
            if (run >= 16) return a + 15;
        }
        // a stock image written out as source (or disassembled from a .bin) has its fill as DB bytes, so nothing is "free": a long run of FFh fill (32 or more) is still fill, and its last byte balances the sum without touching anything the code reads (a P72, say, which checks its sum while it runs)
        run = 0;
        for (int a = rom.Length - 2; a >= rom.Length / 2; a--)
        {
            run = rom[a] == 0xFF ? run + 1 : 0;
            if (run >= 32) return a + 31;
        }
        return null;
    }

    /// Set the byte at `at` so the image sums to 0. True when it had to change.
    public static bool Balance(byte[] rom, int at)
    {
        if (at < 0 || at >= rom.Length) return false;
        int s = Sum(rom);
        if (s == 0) return false;
        rom[at] = (byte)(rom[at] - s);
        return true;
    }
}
