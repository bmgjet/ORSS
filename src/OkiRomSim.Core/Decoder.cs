// Copyright (c) bmgjet. All rights reserved.
//
// OKI MSM66207 table-driven instruction decoder.
//
// The 66207 encodes the *addressing mode* in the first byte and the *operation* in a later byte (e.g. `C5 EB 98 46` is `MOVB 0ebh, #046h`, where C5 selects the direct-byte operand and 98 selects MOV-immediate). A flat switch on the opcode byte therefore cannot decode this ISA -- patterns have to be matched whole.
//
// Patterns come from FullOpcodes.Table, derived from the 66207.op opcode spec.
//
// The DD flag (word/byte mode) is part of the decode context: some encodings are shared between a word form and a byte form and are told apart only by DD -- 0x18 is `ADC A, er0` when DD=1 but `ADCB A, r0` when DD=0. Instructions marked 'S'/'R' in the table set/reset DD for what follows.

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
    /// INT (internal-memory) machine-cycle count for one instruction, from the MSM66201/66207 instruction manual's "Instruction List" cycle tables (chapter 3 sec.3, the Int*1/Int*2 column). Operand-specific costs are handled explicitly where qualified; the remaining operation classes use the existing length-based estimate.
    public static ushort IntCycles(string mnemonic, int len)
    {
        ushort baseCycles = (ushort)(2 * len);
        int sp = mnemonic.IndexOfAny(new[] { ' ', ',' });
        string op = sp >= 0 ? mnemonic[..sp] : mnemonic;

        // OKI instruction manual, pp. 3-150..3-153 (INT data operands).
        // SRL A / SRLB A are 2; register objects 5; direct/off/[DP] 7;
        // USP displacement 8; X1/X2 displacement 9. Length alone is insufficient.
        if (op is "SRL" or "SRLB")
        {
            string operand = mnemonic[(sp + 1)..].Trim();
            return operand switch
            {
                "A" => 2,
                "[DP]" => 7,
                _ when operand.Contains("[USP]", StringComparison.Ordinal) => 8,
                _ when operand.Contains("[X1]", StringComparison.Ordinal) ||
                       operand.Contains("[X2]", StringComparison.Ordinal) => 9,
                _ when operand.StartsWith("off ", StringComparison.Ordinal) || operand == "N8" => 7,
                _ => 5,
            };
        }


        // Explicit INT rows visually checked in the OKI manual. These costs are not
        // extrapolated to unlisted byte forms, EXT memory, wait states or other mnemonics.
        // Printed pp.3-13/16/35/39/156: accumulator arithmetic/comparison rows.
        // Byte and word register forms are 3 cycles despite their one-byte encoding.
        if ((op is "CMP" or "ADD" or "SUB" or "CMPB" or "ADDB") &&
            mnemonic[(sp + 1)..].StartsWith("A, ", StringComparison.Ordinal))
        {
            string operand = mnemonic[(sp + 4)..];
            if (operand.StartsWith('#')) return (ushort)(op is "CMPB" or "ADDB" ? 4 : 6);
            if (operand.StartsWith("er", StringComparison.Ordinal) ||
                (operand.Length == 2 && operand[0] == 'r' && char.IsAsciiDigit(operand[1]))) return 3;
            if (operand.StartsWith("off ", StringComparison.Ordinal)) return 4;
            if (operand == "N8" || operand == "[DP]") return 6;
            if (operand.Contains("[USP]", StringComparison.Ordinal)) return 7;
            if (operand.Contains("[X1]", StringComparison.Ordinal) || operand.Contains("[X2]", StringComparison.Ordinal)) return 8;
            return 4;
        }
        // Printed pp.3-36/40: object-to-accumulator compare, both widths.
        if ((op is "CMP" or "CMPB") && mnemonic.EndsWith(", A", StringComparison.Ordinal))
            return ObjectCycles(mnemonic[(sp + 1)..^3], 5, 7, 8, 9);
        // Printed pp.3-69/70: L sets DD=1, LB sets DD=0; [DP] accesses memory.
        if ((op is "L" or "LB") && mnemonic[(sp + 1)..].StartsWith("A, ", StringComparison.Ordinal))
        {
            string operand = mnemonic[(sp + 4)..];
            if (operand.StartsWith('#')) return (ushort)(op == "LB" ? 4 : 6);
            return ObjectCycles(operand, 2, 4, 5, 6);
        }
        // Printed pp.3-70/154: byte load and word store indirect/indexed rows.
        if (mnemonic.StartsWith("ST A, ", StringComparison.Ordinal))
            return ObjectCycles(mnemonic[6..], 2, 4, 5, 6);
        // Printed pp.3-55/56/60/61: pointer/LRB and byte-local short forms
        // still take three INT cycles; the other object forms use the full table.
        if (op is "INC" or "INCB" or "DEC" or "DECB")
        {
            string operand = mnemonic[(sp + 1)..];
            if (operand is "DP" or "X1" or "X2" or "LRB"
                || operand.Length == 2 && operand[0] == 'r' && char.IsDigit(operand[1])) return 3;
            return ObjectCycles(operand, 5, 7, 8, 9);
        }
        // Printed pp.3-77..80/114/127: MB/MBR costs depend on the transfer direction and addressing mode.
        if ((op is "MB" or "MBR") && mnemonic[(sp + 1)..].StartsWith("C, ", StringComparison.Ordinal))
            return ObjectCycles(mnemonic[(sp + 4)..], 5, 7, 8, 9);
        if (op is "SB" or "RB")
            return ObjectCycles(mnemonic[3..], 7, 9, 10, 11);
        if ((op is "MB" or "MBR") && mnemonic.EndsWith(", C", StringComparison.Ordinal))
            return ObjectCycles(mnemonic[(sp + 1)..^3], 10, 12, 13, 14);
        // Printed pp.3-27/110: only the object/immediate byte logical forms.
        if ((op is "ANDB" or "ORB") && mnemonic.EndsWith(", #N8", StringComparison.Ordinal)
            && !mnemonic[(sp + 1)..].StartsWith("A, ", StringComparison.Ordinal))
            return ObjectCycles(mnemonic[(sp + 1)..^5], 6, 8, 9, 10);
        // Printed p.3-82: MOV DP,obj is word-wide and does not establish DD.
        if (mnemonic.StartsWith("MOV DP, ", StringComparison.Ordinal))
        {
            string operand = mnemonic[8..];
            if (operand == "A") return 2;
            if (operand.StartsWith('#')) return 6;
            return ObjectCycles(operand, 4, 6, 7, 8);
        }

        // Printed pp.3-84/87: MOV preserves DD; off destination and source
        // each access memory, so an indirect source is not a short register move.
        if (mnemonic.StartsWith("MOV LRB, ", StringComparison.Ordinal))
        {
            string operand = mnemonic[9..];
            if (operand.StartsWith('#')) return 6;
            return ObjectCycles(operand, 4, 6, 7, 8);
        }
        if (mnemonic.StartsWith("MOV off ", StringComparison.Ordinal))
        {
            string operand = mnemonic[(mnemonic.IndexOf(',') + 2)..];
            if (operand.StartsWith('#')) return 10;
            return ObjectCycles(operand, 6, 8, 9, 10);
        }

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


    // Qualified operand classes for the tables above; the decoder supplies a valid mnemonic.
    private static ushort ObjectCycles(string operand, ushort register, ushort direct, ushort usp, ushort indexed)
    {
        if (operand.Contains("[USP]", StringComparison.Ordinal)) return usp;
        if (operand.Contains("[X1]", StringComparison.Ordinal) || operand.Contains("[X2]", StringComparison.Ordinal)) return indexed;
        if (operand.StartsWith("off ", StringComparison.Ordinal) || operand.StartsWith("N8", StringComparison.Ordinal) || operand.StartsWith("N'8", StringComparison.Ordinal)
            || operand.StartsWith("[DP]", StringComparison.Ordinal)) return direct;
        return register;
    }

    private static byte? HexByte(string tok)
    {
        return tok.Length == 2 &&
            Uri.IsHexDigit(tok[0]) && Uri.IsHexDigit(tok[1])
            ? Convert.ToByte(tok, 16)
            : null;
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
        for (int i = 0; i < 256; i++) idx.ByFirst[i] = [];

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
        // Match the most constrained pattern first so a shorter, less specific encoding can never shadow a longer one that also fits.
        foreach (var bucket in idx.ByFirst)
        {
            bucket.Sort((a, b) =>
            {
                var pa = table[a];
                var pb = table[b];
                int c = Specificity(pb.BytesPat).CompareTo(Specificity(pa.BytesPat));
                return c != 0 ? c : pb.BytesPat.Length.CompareTo(pa.BytesPat.Length);
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
                        // Unknown placeholder: treat as a wildcard rather than silently mis-decoding.
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
