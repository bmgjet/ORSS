// Parses FullOpcodes' display-text operands once into a tree that Exec evaluates generically.
// Addressing notes that are easy to get wrong:
//   * N8 is an absolute low-RAM/SFR address (0x00..0xFF).
//   * off N8 is LRB-paged: ((LRB >> 5) << 8) | N8.
//   * rN / erN live in the local register bank at base ((LRB >> 5) << 8) | ((LRB & 0x1F) << 3).
//   * LC/CMPC address code space; every other form addresses data space.

namespace OkiRomSim.Core;

public enum Reg { A, Dp, X1, X2, Usp, Ssp, Lrb, Psw, PswL, PswH }

/// How to compute an effective address.
public enum MemKind
{
    Direct,      // N8 -- absolute low RAM / SFR
    DirectAlt,   // N'8 -- second immediate used as an address
    OffPage,     // off N8 -- LRB-paged
    OffPageAlt,  // off N'8
    AtReg,       // [reg]
    AtEr,        // [erN]
    IdxUsp,      // S8[USP]
    IdxReg,      // N16[reg]
    IdxRegAlt,   // N'16[reg] -- displacement in the second 16-bit field (the first is the #N16 source)
    IdxMemN8,    // N16[N8] -- base is the word held at RAM N8
    IdxMemOff,   // N16[off N8] -- base is the word held at the LRB-paged off N8
    Abs16,       // N16 used directly as an address (code-space loads)
}

/// `Mem` addressing-mode value: kind plus whichever extra selector it needs
/// (a Reg for AtReg/IdxReg, or an er-bank index for AtEr).
public readonly struct Mem
{
    public readonly MemKind Kind;
    public readonly Reg Reg;
    public readonly byte ErIndex;

    private Mem(MemKind kind, Reg reg = default, byte erIndex = 0)
    {
        Kind = kind; Reg = reg; ErIndex = erIndex;
    }

    public static Mem Of(MemKind kind) => new(kind);
    public static Mem OfReg(MemKind kind, Reg r) => new(kind, r);
    public static Mem OfEr(byte n) => new(MemKind.AtEr, erIndex: n);
}

public enum ArgKind { Reg, Er, R, Carry, ImmN8, ImmN16, ImmN8Alt, ImmN16Alt, Mem, Bit, Addr16, Rel8, Lit }

/// Operand tree node. Immutable value akin to the Rust `Arg` enum; `Bit` wraps an inner Arg the same way `Arg::Bit(Box<Arg>, u8)` does.
public sealed class Arg
{
    public readonly ArgKind Kind;
    public readonly Reg Reg;
    public readonly byte Index;     // Er/R bank slot, or Lit value
    public readonly Mem Mem;
    public readonly Arg? Inner;     // for Bit
    public readonly byte Bit_;      // bit number, for Bit

    private Arg(ArgKind kind, Reg reg = default, byte index = 0, Mem mem = default, Arg? inner = null, byte bit = 0)
    {
        Kind = kind; Reg = reg; Index = index; Mem = mem; Inner = inner; Bit_ = bit;
    }

    public static Arg OfReg(Reg r) => new(ArgKind.Reg, reg: r);
    public static Arg OfEr(byte n) => new(ArgKind.Er, index: n);
    public static Arg OfR(byte n) => new(ArgKind.R, index: n);
    public static readonly Arg Carry = new(ArgKind.Carry);
    public static readonly Arg ImmN8 = new(ArgKind.ImmN8);
    public static readonly Arg ImmN16 = new(ArgKind.ImmN16);
    public static readonly Arg ImmN8Alt = new(ArgKind.ImmN8Alt);
    public static readonly Arg ImmN16Alt = new(ArgKind.ImmN16Alt);
    public static Arg OfMem(Mem m) => new(ArgKind.Mem, mem: m);
    public static Arg OfBit(Arg inner, byte bit) => new(ArgKind.Bit, inner: inner, bit: bit);
    public static readonly Arg Addr16 = new(ArgKind.Addr16);
    public static readonly Arg Rel8 = new(ArgKind.Rel8);
    public static Arg OfLit(byte n) => new(ArgKind.Lit, index: n);

    public override bool Equals(object? obj) =>
        obj is Arg o && Kind == o.Kind && Reg == o.Reg && Index == o.Index &&
        Mem.Kind == o.Mem.Kind && Mem.Reg == o.Mem.Reg && Mem.ErIndex == o.Mem.ErIndex &&
        Bit_ == o.Bit_ && Equals(Inner, o.Inner);
    public override int GetHashCode() => (Kind, Reg, Index, Mem.Kind, Mem.Reg, Mem.ErIndex, Bit_).GetHashCode();
}

public sealed class Parsed
{
    /// Base mnemonic, e.g. "MOVB".
    public readonly string Op;
    public readonly List<Arg> Args;
    /// Byte-width operation (mnemonic ends in B, and is not a bit/branch op).
    public readonly bool ByteWidth;

    public Parsed(string op, List<Arg> args, bool byteWidth)
    {
        Op = op; Args = args; ByteWidth = byteWidth;
    }
}

public static class OperandParser
{
    private static Reg? ParseReg(string s) => s switch
    {
        "A" => Reg.A,
        "DP" => Reg.Dp,
        "X1" => Reg.X1,
        "X2" => Reg.X2,
        "USP" => Reg.Usp,
        "SSP" => Reg.Ssp,
        "LRB" => Reg.Lrb,
        "PSW" => Reg.Psw,
        "PSWL" => Reg.PswL,
        "PSWH" => Reg.PswH,
        _ => null,
    };

    private static bool TryParseUInt(string s, out byte n)
    {
        return byte.TryParse(s, out n);
    }

    private static Arg? ParseArg(string raw)
    {
        var s = raw.Trim();
        if (s.Length == 0) return null;

        // Bit suffix: "<base>.<n>". Split from the right so "N16[X1].3" works.
        int dot = s.LastIndexOf('.');
        if (dot >= 0 && dot == s.Length - 2)
        {
            char c = s[dot + 1];
            if (c >= '0' && c <= '7')
            {
                var baseArg = ParseArg(s[..dot]);
                if (baseArg != null) return Arg.OfBit(baseArg, (byte)(c - '0'));
            }
        }

        // Immediates.
        if (s.StartsWith('#'))
        {
            var rest = s[1..];
            return rest switch
            {
                "N8" => Arg.ImmN8,
                "N16" => Arg.ImmN16,
                "N'8" => Arg.ImmN8Alt,
                "N'16" => Arg.ImmN16Alt,
                _ => null,
            };
        }

        // Indirect through a register or register-bank slot: "[DP]", "[er0]".
        if (s.StartsWith('[') && s.EndsWith(']'))
        {
            var inner = s[1..^1];
            var r = ParseReg(inner);
            if (r != null) return Arg.OfMem(Mem.OfReg(MemKind.AtReg, r.Value));
            if (inner.StartsWith("er") && TryParseUInt(inner[2..], out var n))
                return Arg.OfMem(Mem.OfEr(n));
            // "[[DP]]", "[off N8]", "[N8]", "[S8[USP]]", "[N16[X1]]": the
            // extra bracket layer is display notation for jump/call targets,
            // where the value fetched *is* the destination. The addressing
            // itself is the inner form.
            return ParseArg(inner);
        }

        // Indexed: "N16[X1]", "S8[USP]", "N16[N8]".
        if (s.EndsWith(']'))
        {
            int open = s.IndexOf('[');
            if (open >= 0)
            {
                var disp = s[..open];
                var basePart = s[(open + 1)..^1];
                MemKind? kind = null;
                Reg? baseReg = null;
                if (disp == "S8" && basePart == "USP") kind = MemKind.IdxUsp;
                else if (disp == "N16" && basePart == "N8") kind = MemKind.IdxMemN8;
                else if (disp == "N16" && basePart == "off N8") kind = MemKind.IdxMemOff;
                else if (disp == "N16") { baseReg = ParseReg(basePart); if (baseReg != null) kind = MemKind.IdxReg; }
                else if (disp == "N'16") { baseReg = ParseReg(basePart); if (baseReg != null) kind = MemKind.IdxRegAlt; }

                if (kind is null) return null;
                return Arg.OfMem(baseReg != null ? Mem.OfReg(kind.Value, baseReg.Value) : Mem.Of(kind.Value));
            }
        }

        // LRB-paged direct.
        if (s.StartsWith("off "))
        {
            var rest = s["off ".Length..].Trim();
            return rest switch
            {
                "N8" => Arg.OfMem(Mem.Of(MemKind.OffPage)),
                "N'8" => Arg.OfMem(Mem.Of(MemKind.OffPageAlt)),
                _ => null,
            };
        }

        var reg = ParseReg(s);
        if (reg != null) return Arg.OfReg(reg.Value);
        if (s == "C") return Arg.Carry;
        if (s.StartsWith("er") && TryParseUInt(s[2..], out var erN)) return Arg.OfEr(erN);
        if (s.Length == 2 && s[0] == 'r' && char.IsDigit(s[1])) return Arg.OfR((byte)(s[1] - '0'));

        switch (s)
        {
            case "addr16": return Arg.Addr16;
            case "rel8": return Arg.Rel8;
            case "N8": return Arg.OfMem(Mem.Of(MemKind.Direct));
            case "N'8": return Arg.OfMem(Mem.Of(MemKind.DirectAlt));
            case "N16": return Arg.OfMem(Mem.Of(MemKind.Abs16));
            default:
                if (byte.TryParse(s, out var lit)) return Arg.OfLit(lit);
                return null;
        }
    }

    /// A trailing B only means "byte variant" when dropping it leaves another real mnemonic: MOVB -> MOV, LB -> L. It must NOT fire for SUB (-> "SU"), SB, RB or MB, whose B is part of the name.
    private static bool IsByteVariant(string op, HashSet<string> all) =>
        op.Length > 1 && op.EndsWith('B') && all.Contains(op[..^1]);

    private static Parsed? ParseOne(string text, HashSet<string> all)
    {
        string op, rest;
        int sp = text.IndexOf(' ');
        if (sp >= 0) { op = text[..sp]; rest = text[(sp + 1)..]; }
        else { op = text; rest = ""; }

        var args = new List<Arg>();
        if (rest.Trim().Length > 0)
        {
            // Operands are comma-separated, and no operand form contains a comma.
            foreach (var part in rest.Split(','))
            {
                // J / CAL: the outer bracket is display notation for "jump to the value of
                // the operand", and the operand inside uses the ordinary addressing. So
                // `J [DP]` (92 22) jumps to the address in DP - the ROMs' jump tables do
                // LC A,[DP] / MOV DP,A / J [DP] - `J [er0]` to the value of er0, and only
                // `J [[DP]]` (B2 22) fetches the destination from memory at DP.
                var operand = part.Trim();
                if (op is "J" or "CAL" && operand.StartsWith('[') && operand.EndsWith(']')) operand = operand[1..^1];
                var a = ParseArg(operand);
                if (a == null) return null;
                args.Add(a);
            }
        }
        return new Parsed(op, args, IsByteVariant(op, all));
    }

    private static Parsed?[]? _table;

    /// Parsed form of every FullOpcodes.Table entry, indexed identically.
    public static Parsed?[] Table()
    {
        if (_table != null) return _table;
        var all = new HashSet<string>(FullOpcodes.Table.Select(p => p.Mnemonic.Split(' ')[0]));
        _table = FullOpcodes.Table.Select(p => ParseOne(p.Mnemonic, all)).ToArray();
        return _table;
    }
}
