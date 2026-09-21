//
// OKI MSM66207 table-driven instruction decoder.
//
// The 66207 encodes the *addressing mode* in the first byte and the
// *operation* in a later byte (e.g. `C5 EB 98 46` is `MOVB 0ebh, #046h`,
// where C5 selects the direct-byte operand and 98 selects MOV-immediate). A
// flat switch on the opcode byte therefore cannot decode this ISA -- patterns
// have to be matched whole.
//
// Patterns come from FullOpcodes.Table, derived from the 66207.op opcode spec.
//
// The DD flag (word/byte mode) is part of the decode context: some encodings
// are shared between a word form and a byte form and are told apart only by
// DD -- 0x18 is `ADC A, er0` when DD=1 but `ADCB A, r0` when DD=0.
// Instructions marked 'S'/'R' in the table set/reset DD for what follows.

namespace OkiRomSim.Core;

/// Longest encoding in the table, used to bound the fetch window.
public static class DecoderConstants
{
    public const int MaxInsnLen = 6;
}

/// Immediate/displacement values captured while matching a pattern.
public struct Fields
{
    public byte N8;
    public ushort N16;
    public sbyte S8;
    public sbyte Rel8;
    public ushort Addr16;
    /// Second immediate, for forms carrying two (`N'8`, `N'16`).
    public byte N8Alt;
    public ushort N16Alt;
}

public sealed class Decoded
{
    /// Index into FullOpcodes.Table.
    public int Index;
    public string Mnemonic = "";
    public int Len;
    public Fields Fields;
    /// DD after this instruction, when it forces a mode; null leaves it unchanged.
    public bool? DdAfter;
    /// INT (internal-memory) machine cycles for this encoding, per IntCycles. For conditional branches this is the *not-taken* cost; Exec adds the taken penalty at run time.
    public ushort Cycles;

    public Decoded Clone() => new()
    {
        Index = Index, Mnemonic = Mnemonic, Len = Len, Fields = Fields,
        DdAfter = DdAfter, Cycles = Cycles
    };
}

public static class Decoder
{
    /// INT (internal-memory) machine-cycle count for one instruction, from the MSM66201/66207 instruction manual's "Instruction List" cycle tables (chapter 3 sec.3, the Int*1/Int*2 column).
    /// Across every operation class the all-internal-operand cost is 2 cycles per instruction byte plus a small per-operation adjustment.
    public static ushort IntCycles(string mnemonic, int len)
    {
        ushort baseCycles = (ushort)(2 * len);
        int sp = mnemonic.IndexOfAny(new[] { ' ', ',' });
        string op = sp >= 0 ? mnemonic[..sp] : mnemonic;

        int extra = op switch
        {
            "MUL" => 23,
            "MULB" => 15,
            "DIV" => 43,
            "DIVB" => 25,
            "RTI" => 13,
            "BRK" => 11,
            "RT" => 5,
            "VCAL" => 9,
            "DAA" or "DAS" => 4,
            "LC" or "CMPC" => 7,
            "LCB" or "CMPCB" => 5,
            "SCAL" => 5,
            "SJ" => 4,
            "PUSHS" or "PUSHU" => 1,
            "POPS" => 2,
            "SB" or "RB" or "SBR" or "RBR" or "MBR" => 3,
            "TBR" => 1,
            "JRNZ" => 3,
            "CAL" => mnemonic.Contains('[') ? 4 : 3,
            "J" => mnemonic.Contains('[') ? 2 : 1,
            "MB" => mnemonic.StartsWith("MB C,") ? 1 : 6,
            _ => 0,
        };
        return (ushort)(baseCycles + extra);
    }

    private static byte? HexByte(string tok)
    {
        if (tok.Length == 2 &&
            Uri.IsHexDigit(tok[0]) && Uri.IsHexDigit(tok[1]))
        {
            return Convert.ToByte(tok, 16);
        }
        return null;
    }

    /// Number of fixed (non-wildcard) bytes in a pattern -- how specific it is.
    private static int Specificity(string[] pat) => pat.Count(t => HexByte(t) != null);

    private sealed class Index
    {
        /// Pattern indices bucketed by leading opcode byte, most specific first.
        public List<int>[] ByFirst = new List<int>[256];
    }

    private static Index? _index;

    private static Index BuildIndex()
    {
        var idx = new Index();
        for (int i = 0; i < 256; i++) idx.ByFirst[i] = new List<int>();

        var table = FullOpcodes.Table;
        for (int i = 0; i < table.Length; i++)
        {
            var p = table[i];
            if (p.BytesPat.Length > 0)
            {
                var first = HexByte(p.BytesPat[0]);
                if (first != null) idx.ByFirst[first.Value].Add(i);
            }
        }
        // Match the most constrained pattern first so a shorter, less specific
        // encoding can never shadow a longer one that also fits.
        foreach (var bucket in idx.ByFirst)
        {
            bucket.Sort((a, b) =>
            {
                var pa = table[a];
                var pb = table[b];
                int c = Specificity(pb.BytesPat).CompareTo(Specificity(pa.BytesPat));
                if (c != 0) return c;
                return pb.BytesPat.Length.CompareTo(pa.BytesPat.Length);
            });
        }
        return idx;
    }

    private static Index GetIndex() => _index ??= BuildIndex();

    /// Decode one instruction. `fetch(i)` supplies the byte at offset `i` from the instruction start. `dd` is the current word/byte mode.
    public static Decoded? Decode(bool dd, Func<int, byte> fetch)
    {
        byte first = fetch(0);
        var idx = GetIndex();
        var table = FullOpcodes.Table;

        foreach (var pi in idx.ByFirst[first])
        {
            var p = table[pi];

            // DD gate: '1' and '0' forms exist only in their respective mode.
            if (p.DdMode == '1' && !dd) continue;
            if (p.DdMode == '0' && dd) continue;

            var f = new Fields();
            bool mismatch = false;
            for (int off = 0; off < p.BytesPat.Length; off++)
            {
                var tok = p.BytesPat[off];
                byte b = fetch(off);
                var expect = HexByte(tok);
                if (expect != null)
                {
                    if (b != expect.Value) { mismatch = true; break; }
                    continue;
                }
                switch (tok)
                {
                    case "N8": f.N8 = b; break;
                    case "NL": f.N16 = (ushort)((f.N16 & 0xFF00) | b); break;
                    case "NH": f.N16 = (ushort)((f.N16 & 0x00FF) | (b << 8)); break;
                    case "S8": f.S8 = unchecked((sbyte)b); break;
                    case "rel8": f.Rel8 = unchecked((sbyte)b); break;
                    case "addrl": f.Addr16 = (ushort)((f.Addr16 & 0xFF00) | b); break;
                    case "addrh": f.Addr16 = (ushort)((f.Addr16 & 0x00FF) | (b << 8)); break;
                    case "N'8": f.N8Alt = b; break;
                    case "N'L": f.N16Alt = (ushort)((f.N16Alt & 0xFF00) | b); break;
                    case "N'H": f.N16Alt = (ushort)((f.N16Alt & 0x00FF) | (b << 8)); break;
                    default:
                        // Unknown placeholder: treat as a wildcard rather than
                        // silently mis-decoding.
                        break;
                }
            }
            if (mismatch) continue;

            return new Decoded
            {
                Index = pi,
                Mnemonic = p.Mnemonic,
                Len = p.BytesPat.Length,
                Fields = f,
                DdAfter = p.DdMode switch { 'S' => true, 'R' => false, _ => (bool?)null },
                Cycles = IntCycles(p.Mnemonic, p.BytesPat.Length),
            };
        }

        return null;
    }

    /// Render a decoded instruction with its immediates substituted in.
    public static string Format(Decoded d, ushort pcAfter)
    {
        var f = d.Fields;
        var s = d.Mnemonic;
        // Longest placeholders first so shorter ones cannot corrupt them.
        var subs = new (string tok, string val)[]
        {
            ("addr16", $"0{f.Addr16:X4}h"),
            ("N'16", $"0{f.N16Alt:X4}h"),
            ("N'8", $"0{f.N8Alt:X2}h"),
            ("N16", $"0{f.N16:X4}h"),
            ("rel8", $"0{(ushort)(pcAfter + f.Rel8):X4}h"),
            ("S8", f.S8.ToString()),
            ("N8", $"0{f.N8:X2}h"),
        };
        foreach (var (tok, val) in subs)
        {
            int pos = s.IndexOf(tok, StringComparison.Ordinal);
            if (pos >= 0) s = s[..pos] + val + s[(pos + tok.Length)..];
        }
        return s;
    }
}
