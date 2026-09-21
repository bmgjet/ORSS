// Best-effort label -> address table, parsed directly from .asm source
// text -- NOT a real assembler symbol table (for that, see AsmAssembler.cs).
// This exists
// so the UI can offer breakpoints and trace annotations by name instead of
// raw hex, for source files annotated in the disassembly style this
// project's sample ROMs use:
//
//   fuelpump_relay_drive:     MB      P0.7, C          ; 3DDE 0 208 180 C5203F
//
// i.e. a label, then an instruction, then a comment whose first token is the
// instruction's 4-hex-digit address. Continuation comment lines ("; 2528
// from 252A ...") don't start with "label:" and are correctly ignored.

using System.Globalization;
using System.Text.RegularExpressions;
namespace OkiRomSim.Core;

public static class AsmSymbols
{
    private static readonly Regex LabelLine = new(
        @"^(\w+):\s+\S.*;\s*([0-9A-Fa-f]{4})\b", RegexOptions.Compiled);

    /// Parse a .asm file into a label -> address table. Returns an empty table (never null/throws) if the file has no recognizable label lines -- this is a convenience feature, not a required capability.
    public static Dictionary<string, ushort> Parse(string asmPath)
    {
        var table = new Dictionary<string, ushort>();
        foreach (var line in File.ReadLines(asmPath))
        {
            var m = LabelLine.Match(line);
            if (!m.Success) continue;
            if (ushort.TryParse(m.Groups[2].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var addr))
            {
                // First definition wins, matching how a real assembler's
                // symbol table would behave for an (erroneous) duplicate --
                // see the idle_pid_result_store bug documented in the README.
                table.TryAdd(m.Groups[1].Value, addr);
            }
        }
        return table;
    }
}
