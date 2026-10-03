// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Core;

namespace OkiRomSim.Calibration;

/// A trouble code taken out of the ROM's code rather than masked: every instruction that latches its bit of the fault field ("MB 098h.3, C" - C5 98 3B - and "SB 098h.3" - C5 98 1B) is replaced with NOPs of the same length, so the check still runs but can never set the fault, and nothing after it moves. A code switched off on the error codes page can be switched back on by anyone; this one is gone from the ROM until the bytes are put back.
public static class FaultDisable
{
    /// One instruction that sets the fault bit.
    public sealed record Site(int Address, byte[] Original, string What, string? File = null, int Line = 0);

    public const byte Nop = 0x00;

    /// The instructions that set bit `bit` (0-47) of the fault field at `fieldBase`: each one only where an instruction really starts (the build's source map says so), so a table byte that happens to read C5 98 3B is never touched. Without a source map the whole image is searched, which only a raw ROM needs.
    public static List<Site> Find(byte[] rom, int fieldBase, int bit, IReadOnlyList<(int Address, int Length, string File, int Line)>? code = null)
    {
        byte addr = (byte)(fieldBase + (bit / 8));
        int n = bit % 8;
        var found = new List<Site>();
        bool At(int a, out string what)
        {
            what = "";
            if (a < 0 || a + 3 > rom.Length || rom[a] != 0xC5 || rom[a + 1] != addr) return false;
            if (rom[a + 2] == 0x38 + n) { what = $"MB {addr:X2}h.{n}, C"; return true; }
            if (rom[a + 2] == 0x18 + n) { what = $"SB {addr:X2}h.{n}"; return true; }
            return false;
        }
        if (code != null && code.Count > 0)
        {
            foreach (var (a, len, file, line) in code)
                if (len == 3 && At(a, out var what)) found.Add(new Site(a, rom[a..(a + 3)], what, file, line));
        }
        else
            for (int a = 0; a + 3 <= rom.Length; a++)
                if (At(a, out var what)) found.Add(new Site(a, rom[a..(a + 3)], what));
        return found;
    }

    /// The bits of the fault field that flash as `code`.
    public static IEnumerable<int> BitsFor(int code) => Enumerable.Range(0, 48).Where(b => MilMonitor.FaultBitCode(b) == code);

    /// The NOPs that take the sites out.
    public static List<BytePatch> Patches(IEnumerable<Site> sites) =>
        [.. sites.SelectMany(s => Enumerable.Range(0, s.Original.Length).Select(i => new BytePatch(s.Address + i, Nop)))];

    /// The source line a site becomes: the same three bytes of NOP, with what was there and why in its comment.
    public static string SourceLine(Site s, int code, string indent = "    ") =>
        $"{indent}DB      000h, 000h, 000h        ; hard-disabled: {s.What} (trouble code {code}) - put the instruction back to bring the code back";
}
