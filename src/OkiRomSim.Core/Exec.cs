// Copyright (c) bmgjet. All rights reserved.
// OKI 66207 executor: evaluates the Arg tree that Decoder + OperandParser produce, so each mnemonic is implemented once. Conventions taken from the ISA: * Word ops use the full 16-bit accumulator; byte ops (mnemonic ending in B) use its low half. * CF is set on borrow by SUB/SBC/CMP: JLT = CF, JGE = !CF, JGT = !CF && !ZF, JLE = CF || ZF. * LC/CMPC read code space; everything else reads data space.
namespace OkiRomSim.Core;

public sealed class ExecException : Exception
{
    public ExecException(string message) : base(message) { }

    public static ExecException UndefinedOpcode(ushort pc, byte b) =>
        new($"undefined opcode {b:X2} at {pc:X4}");

    public static ExecException Unimplemented(ushort pc, string mnemonic) =>
        new($"unimplemented instruction `{mnemonic}` at {pc:X4}");
}

internal sealed class Exec
{
    private readonly Cpu _cpu;
    private readonly Bus _bus;
    private readonly Decoded _d;

    public Exec(Cpu cpu, Bus bus, Decoded d)
    {
        _cpu = cpu; _bus = bus; _d = d;
    }

    public bool BranchTaken { get; private set; }

    // ---- operand address / value plumbing ---------------------------------

    /// X1/X2/DP/USP are not CPU registers: they live in RAM at 0x0080 in the pointing-register set selected by PSW's SCB field.
    private ushort? PregAddr(Reg r)
    {
        int? slot = r switch
        {
            Reg.X1 => 0,
            Reg.X2 => 2,
            Reg.Dp => 4,
            Reg.Usp => 6,
            _ => null,
        };
        return slot == null ? null : (ushort)(0x0080 + (_cpu.Scb() * 8) + slot.Value);
    }

    private ushort RegGet(Reg r)
    {
        return PregAddr(r) is ushort a
            ? _bus.ReadDataU16(a)
            : r switch
        {
            Reg.A => _cpu.A,
            Reg.Ssp => _cpu.Ssp,
            Reg.Lrb => _cpu.Lrb,
            Reg.Psw => _cpu.PswU16(),
            Reg.PswL => (ushort)(_cpu.PswU16() & 0xFF),
            Reg.PswH => (ushort)(_cpu.PswU16() >> 8),
            _ => throw new InvalidOperationException("pointing registers handled above"),
        };
    }

    private void RegSet(Reg r, ushort v)
    {
        if (PregAddr(r) is ushort a) { _bus.WriteDataU16(a, v); return; }
        switch (r)
        {
            case Reg.A: _cpu.A = v; break;
            case Reg.Ssp: _cpu.Ssp = v; break;
            case Reg.Lrb: _cpu.Lrb = v; break;
            case Reg.Psw: _cpu.SetPswU16(v); break;
            case Reg.PswL:
                { ushort p = _cpu.PswU16(); _cpu.SetPswU16((ushort)((p & 0xFF00) | (v & 0xFF))); break; }
            case Reg.PswH:
                { ushort p = _cpu.PswU16(); _cpu.SetPswU16((ushort)((p & 0x00FF) | (v << 8))); break; }
            default: throw new InvalidOperationException("pointing registers handled above");
        }
    }

    /// SSP, LRB, PSW and the accumulator are memory-mapped at 0x00..0x07, so `CLR off(PSW)` (a write to 0x0004) has to land on the real PSW rather than on plain RAM.
    private static (Reg reg, bool high)? Alias(ushort addr)
    {
        Reg? reg = (addr & ~1) switch
        {
            0x00 => Reg.Ssp,
            0x02 => Reg.Lrb,
            0x04 => Reg.Psw,
            0x06 => Reg.A,
            _ => null,
        };
        return reg == null ? null : (reg.Value, (addr & 1) == 1);
    }

    private ushort Load(ushort addr, bool byteWidth)
    {
        if (Alias(addr) is var (r, high))
        {
            ushort v = RegGet(r);
            return !byteWidth ? v : high ? (ushort)(v >> 8) : (ushort)(v & 0xFF);
        }
        return byteWidth ? _bus.ReadDataU8(addr) : _bus.ReadDataU16(addr);
    }

    private void Store(ushort addr, bool byteWidth, ushort v)
    {
        if (Alias(addr) is var (r, high))
        {
            ushort cur = RegGet(r);
            ushort next;
            if (!byteWidth) next = v;
            else if (high) next = (ushort)((cur & 0x00FF) | (v << 8));
            else next = (ushort)((cur & 0xFF00) | (v & 0xFF));
            RegSet(r, next);
            return;
        }
        if (byteWidth) _bus.WriteDataU8(addr, (byte)v);
        else _bus.WriteDataU16(addr, v);
    }

    /// Effective address of a memory operand.
    private ushort Ea(Mem m)
    {
        var f = _d.Fields;
        switch (m.Kind)
        {
            case MemKind.Direct: return f.N8;
            case MemKind.DirectAlt: return f.N8Alt;
            case MemKind.OffPage: return _cpu.OffPage(f.N8);
            case MemKind.OffPageAlt: return _cpu.OffPage(f.N8Alt);
            case MemKind.AtReg: return RegGet(m.Reg);
            case MemKind.AtEr:
                {
                    ushort a = (ushort)(_cpu.BankBase() + (m.ErIndex * 2));
                    return _bus.ReadDataU16(a);
                }
            case MemKind.IdxUsp:
                { ushort u = RegGet(Reg.Usp); return (ushort)(u + (ushort)f.S8); }
            case MemKind.IdxReg: return (ushort)(RegGet(m.Reg) + f.N16);
            case MemKind.IdxRegAlt: return (ushort)(RegGet(m.Reg) + f.N16Alt);
            // The base word may be one of the registers mapped at 0x00-0x07: "LC A, table[ACC]" encodes its index as N16[06h], and A lives in the CPU, not in RAM, so go through the register-aware Load.
            case MemKind.IdxMemN8:
                {
                    ushort baseAddr = Load(f.N8, false);
                    return (ushort)(baseAddr + f.N16);
                }
            case MemKind.IdxMemOff:
                {
                    ushort a = _cpu.OffPage(f.N8);
                    ushort baseAddr = Load(a, false);
                    return (ushort)(baseAddr + f.N16);
                }
            case MemKind.Abs16: return f.N16;
            default: throw new InvalidOperationException("unhandled Mem kind");
        }
    }

    /// Where J / CAL go. `J addr16` is absolute. `J [DP]` / `J [er0]` (register object, 92 22 / 44 22) go to the address in the register - the serial dispatch in the 66207 ROMs is "LC A, [DP] / MOV DP, A / J [DP]". `J [N8]`, `J [[DP]]` and the other bracketed memory forms go to the word held in that memory ("J [ACC]" in the P13 DTC dispatch goes to A).
    private ushort JumpTarget(Arg a)
    {
        if (a.Kind == ArgKind.Mem && !a.Deref && a.Mem.Kind is MemKind.AtReg or MemKind.AtEr) return Ea(a.Mem);
        if (a.Kind == ArgKind.Mem && a.Deref) return Load(Ea(a.Mem), false);
        return Read(a, false, false);
    }

    /// Read an operand as a value. `code` selects code space for LC/CMPC.
    private ushort Read(Arg a, bool byteWidth, bool code)
    {
        var f = _d.Fields;
        switch (a.Kind)
        {
            case ArgKind.Reg when a.Reg == Reg.A && byteWidth: return (ushort)(_cpu.A & 0xFF);
            case ArgKind.Reg: return RegGet(a.Reg);
            case ArgKind.Er:
                {
                    ushort addr = (ushort)(_cpu.BankBase() + (a.Index * 2));
                    return _bus.ReadDataU16(addr);
                }
            case ArgKind.R:
                {
                    ushort addr = (ushort)(_cpu.BankBase() + a.Index);
                    return _bus.ReadDataU8(addr);
                }
            case ArgKind.Carry: return (ushort)(_cpu.Cf ? 1 : 0);
            case ArgKind.ImmN8: return f.N8;
            case ArgKind.ImmN16: return f.N16;
            case ArgKind.ImmN8Alt: return f.N8Alt;
            case ArgKind.ImmN16Alt: return f.N16Alt;
            case ArgKind.Mem:
                {
                    ushort addr = Ea(a.Mem);
                    // "LC A, [N8]" and friends: the object is a word in data memory, and the code address is what that word holds ("LC A, [ACC]" reads ROM at A, not at 0x0006)
                    if (code && a.Deref) addr = Load(addr, false);
                    if (code) _bus.NoteRomRead(addr, byteWidth ? 1 : 2);
                    if (byteWidth && code) return _bus.ReadCodeU8(addr);
                    return !byteWidth && code ? _bus.ReadCodeU16(addr) : Load(addr, byteWidth);
                }
            // A bit operand is always one byte (bit 0-7), whatever the DD mode. Reading it word-wide broke the register aliases at odd addresses: "MB C, 007h.7" (ACCH.7) returned ACCL's bit 7 instead.
            case ArgKind.Bit:
                return (ushort)((Read(a.Inner!, true, code) >> a.Bit_) & 1);
            case ArgKind.Addr16: return f.Addr16;
            case ArgKind.Rel8: return unchecked((ushort)f.Rel8);
            case ArgKind.Lit: return a.Index;
            default: throw new InvalidOperationException("unhandled Arg kind");
        }
    }

    private void Write(Arg a, bool byteWidth, ushort v)
    {
        switch (a.Kind)
        {
            case ArgKind.Reg when a.Reg == Reg.A && byteWidth:
                _cpu.A = (ushort)((_cpu.A & 0xFF00) | (v & 0xFF)); break;
            case ArgKind.Reg: RegSet(a.Reg, v); break;
            case ArgKind.Er:
                {
                    ushort addr = (ushort)(_cpu.BankBase() + (a.Index * 2));
                    _bus.WriteDataU16(addr, v);
                    break;
                }
            case ArgKind.R:
                {
                    ushort addr = (ushort)(_cpu.BankBase() + a.Index);
                    _bus.WriteDataU8(addr, (byte)v);
                    break;
                }
            case ArgKind.Carry: _cpu.Cf = (v & 1) != 0; break;
            case ArgKind.Mem:
                {
                    ushort addr = Ea(a.Mem);
                    Store(addr, byteWidth, v);
                    break;
                }
            case ArgKind.Bit:
                {
                    ushort cur = Read(a.Inner!, true, false);
                    ushort next = (v & 1) != 0 ? (ushort)(cur | (1 << a.Bit_)) : (ushort)(cur & ~(1 << a.Bit_));
                    Write(a.Inner!, true, next);
                    break;
                }
            default:
                // Immediates and branch targets are never write destinations.
                break;
        }
    }

    // ---- flag helpers -------------------------------------------------

    private void SetZf(ushort v, bool byteWidth) => _cpu.Zf = byteWidth ? (v & 0xFF) == 0 : v == 0;

    private static ushort Mask(uint v, bool byteWidth) => (ushort)(byteWidth ? v & 0xFF : v & 0xFFFF);

    // ---- stack ----------------------------------------------------------

    private void PushSys(ushort v)
    {
        _bus.WriteDataU16(_cpu.Ssp, v);
        _cpu.Ssp = (ushort)(_cpu.Ssp - 2);
    }

    private ushort PopSys()
    {
        _cpu.Ssp = (ushort)(_cpu.Ssp + 2);
        return _bus.ReadDataU16(_cpu.Ssp);
    }

    // ---- main dispatch ----------------------------------------------------

    public void Run(Parsed p)
    {
        bool byteWidth = p.ByteWidth;
        var args = p.Args;
        // Base name with any byte-width suffix removed, so ADD/ADDB share an arm.
        string baseOp = byteWidth ? p.Op[..^1] : p.Op;

        switch (baseOp)
        {
            case "NOP":
                break;

            // ---- data movement -------------------------------------------
            case "L":
                {
                    // L/LB/LC/LCB update ZF from the loaded value (arch.ml's OP_L/OP_LB/OP_LC/ OP_LCB rules, and the stock ROMs depend on it: the 115 ROM alone has ~230 load-then-JEQ/JNE pairs with no compare in between, e.g. the BRK handler's "LB A, trapReasonCode / JNE nmi_brk"). MOV does not touch the flags.
                    ushort v = Read(args[1], byteWidth, false);
                    Write(args[0], byteWidth, v);
                    SetZf(v, byteWidth);
                    break;
                }
            case "MOV":
                {
                    ushort v = Read(args[1], byteWidth, false);
                    Write(args[0], byteWidth, v);
                    break;
                }
            case "ST":
                {
                    ushort v = Read(args[0], byteWidth, false);
                    Write(args[1], byteWidth, v);
                    break;
                }
            case "LC":
                {
                    ushort v = Read(args[1], byteWidth, true);
                    Write(args[0], byteWidth, v);
                    SetZf(v, byteWidth);
                    break;
                }
            case "XCHG":
                {
                    ushort x = Read(args[0], byteWidth, false);
                    ushort y = Read(args[1], byteWidth, false);
                    Write(args[0], byteWidth, y);
                    Write(args[1], byteWidth, x);
                    break;
                }
            case "CLR":
                Write(args[0], byteWidth, 0);
                break;

            // ---- arithmetic / logic ----------------------------------------
            case "ADD":
            case "ADC":
            case "SUB":
            case "SBC":
            case "CMP":
            case "CMPC":
                {
                    bool code = baseOp == "CMPC";
                    ushort lhs = Read(args[0], byteWidth, false);
                    ushort rhs = Read(args[1], byteWidth, code);
                    uint carryIn = (baseOp == "ADC" || baseOp == "SBC") ? (_cpu.Cf ? 1u : 0u) : 0u;
                    uint a = lhs, b = rhs;
                    uint widthMask = byteWidth ? 0xFFu : 0xFFFFu;
                    uint res; bool carry;
                    if (baseOp is "ADD" or "ADC")
                    {
                        uint r = (a & widthMask) + (b & widthMask) + carryIn;
                        res = r & widthMask;
                        carry = r > widthMask;
                    }
                    else
                    {
                        uint r = (a & widthMask) - (b & widthMask) - carryIn;
                        res = r & widthMask;
                        carry = (a & widthMask) < (b & widthMask) + carryIn;
                    }
                    _cpu.Cf = carry;
                    SetZf((ushort)res, byteWidth);
                    if (baseOp != "CMP" && baseOp != "CMPC") Write(args[0], byteWidth, (ushort)res);
                    break;
                }
            case "AND":
            case "OR":
            case "XOR":
                {
                    ushort lhs = Read(args[0], byteWidth, false);
                    ushort rhs = Read(args[1], byteWidth, false);
                    uint res = baseOp switch
                    {
                        "AND" => (uint)(lhs & rhs),
                        "OR" => (uint)(lhs | rhs),
                        _ => (uint)(lhs ^ rhs),
                    };
                    ushort masked = Mask(res, byteWidth);
                    SetZf(masked, byteWidth);
                    Write(args[0], byteWidth, masked);
                    break;
                }
            case "INC":
            case "DEC":
                {
                    ushort v = Read(args[0], byteWidth, false);
                    uint res = baseOp == "INC" ? (uint)(v + 1) : (uint)(v - 1);
                    ushort masked = Mask(res, byteWidth);
                    SetZf(masked, byteWidth);
                    Write(args[0], byteWidth, masked);
                    break;
                }
            case "MUL":
                // MUL/MULB have no source operands in their mnemonics; operands and destinations are fixed by the ISA: MUL (er1, A) <- A * er0 MULB A <- AL * r0
                if (byteWidth)
                {
                    ushort product = (ushort)(Read(Arg.OfReg(Reg.A), true, false) * Read(Arg.OfR(0), true, false));
                    _cpu.A = product;
                    SetZf(product, false);
                }
                else
                {
                    uint product = (uint)_cpu.A * Read(Arg.OfEr(0), false, false);
                    _cpu.A = (ushort)product;
                    Write(Arg.OfEr(1), false, (ushort)(product >> 16));
                    _cpu.Zf = product == 0;
                }
                break;
            case "DIV":
                // DIV/DIVB likewise use fixed registers: DIV (er0, A) <- (er0, A) / er2; er1 <- remainder DIVB A <- A / r0; r1 <- remainder Divide-by-zero results are undefined on the chip; only CF=1 is specified. Preserve the operands in that case.
                if (byteWidth)
                {
                    ushort divisor = Read(Arg.OfR(0), true, false);
                    if (divisor == 0) _cpu.Cf = true;
                    else
                    {
                        ushort dividend = _cpu.A;
                        ushort quotient = (ushort)(dividend / divisor);
                        ushort remainder = (ushort)(dividend % divisor);
                        _cpu.A = quotient;
                        Write(Arg.OfR(1), true, remainder);
                        _cpu.Cf = false;
                        SetZf(quotient, false);
                    }
                }
                else
                {
                    uint divisor = Read(Arg.OfEr(2), false, false);
                    if (divisor == 0) _cpu.Cf = true;
                    else
                    {
                        uint dividend = ((uint)Read(Arg.OfEr(0), false, false) << 16) | _cpu.A;
                        uint quotient = dividend / divisor;
                        uint remainder = dividend % divisor;
                        Write(Arg.OfEr(0), false, (ushort)(quotient >> 16));
                        _cpu.A = (ushort)quotient;
                        Write(Arg.OfEr(1), false, (ushort)remainder);
                        _cpu.Cf = false;
                        _cpu.Zf = quotient == 0;
                    }
                }
                break;
            case "EXTND":
                {
                    // Sign-extend the low byte across the accumulator.
                    sbyte lo = unchecked((sbyte)(_cpu.A & 0xFF));
                    _cpu.A = unchecked((ushort)(short)lo);
                    break;
                }
            case "SWAP":
                {
                    ushort a2 = _cpu.A;
                    _cpu.A = byteWidth
                        ? (ushort)((a2 & 0xFF00) | ((a2 & 0x0F) << 4) | ((a2 >> 4) & 0x0F))
                        : (ushort)((a2 >> 8) | (a2 << 8));
                    break;
                }

            // ---- shifts and rotates -----------------------------------------
            case "ROL":
            case "ROR":
            case "SLL":
            case "SRL":
            case "SRA":
                {
                    ushort v = Read(args[0], byteWidth, false);
                    int bits = byteWidth ? 8 : 16;
                    uint msb = 1u << (bits - 1);
                    uint mask = (msb * 2) - 1;
                    uint v32 = v & mask;
                    uint res; bool carry;
                    uint cin = _cpu.Cf ? 1u : 0u;
                    switch (baseOp)
                    {
                        // ROL/ROR rotate through carry. The ROMs depend on it: "SRL er1 / ROR A" pairs are 32-bit shifts (scale_mul5_div4), and "MB C, r6.7 / ROLB r6" builds a plain rotate out of the through-carry one.
                        case "ROL":
                            res = ((v32 << 1) | cin) & mask; carry = (v32 & msb) != 0; break;
                        case "ROR":
                            res = (v32 >> 1) | (cin << (bits - 1)); carry = (v32 & 1) != 0; break;
                        case "SLL":
                            res = (v32 << 1) & mask; carry = (v32 & msb) != 0; break;
                        case "SRL":
                            res = v32 >> 1; carry = (v32 & 1) != 0; break;
                        default: // SRA: arithmetic right shift keeps the sign bit.
                            res = (v32 >> 1) | (v32 & msb); carry = (v32 & 1) != 0; break;
                    }
                    _cpu.Cf = carry;
                    SetZf((ushort)res, byteWidth);
                    Write(args[0], byteWidth, (ushort)res);
                    break;
                }

            // ---- carry and bit operations -----------------------------------
            case "SC": _cpu.Cf = true; break;
            case "RC": _cpu.Cf = false; break;
            // Bit set/reset are test-and-modify. ZF is one when the bit's previous value was zero.
            case "SB":
            case "RB":
                {
                    ushort old = (ushort)(Read(args[0], byteWidth, false) & 1);
                    _cpu.Zf = old == 0;
                    Write(args[0], byteWidth, (ushort)(baseOp == "SB" ? 1 : 0));
                    break;
                }
            // MB moves a bit; whichever side is C decides the direction. Does not affect ZF.
            case "MB":
                if (args[0].Equals(Arg.Carry))
                {
                    ushort v = (ushort)(Read(args[1], byteWidth, false) & 1);
                    _cpu.Cf = v != 0;
                }
                else
                {
                    ushort v = (ushort)(_cpu.Cf ? 1 : 0);
                    Write(args[0], byteWidth, v);
                }
                break;
            // Same move, with the bit selected indirectly by A[0:2]. Leaves ZF unchanged.
            case "MBR":
                {
                    ushort mask = (ushort)(1 << (_cpu.A & 0x07));
                    if (args[0].Equals(Arg.Carry))
                    {
                        ushort v = Read(args[1], true, false);
                        bool b = (v & mask) != 0;
                        _cpu.Cf = b;
                    }
                    else
                    {
                        ushort b = (ushort)(_cpu.Cf ? 1 : 0);
                        ushort v = Read(args[0], true, false);
                        ushort next = b != 0 ? (ushort)(v | mask) : (ushort)(v & ~mask);
                        Write(args[0], true, next);
                    }
                    break;
                }
            // "Register Indirect Bit Addressing": no bit index in the encoding; the bit location is bits 0..2 of the accumulator.
            case "SBR":
            case "RBR":
            case "TBR":
                {
                    ushort mask = (ushort)(1 << (_cpu.A & 0x07));
                    ushort v = Read(args[0], true, false);
                    _cpu.Zf = (v & mask) == 0;
                    if (baseOp == "SBR") Write(args[0], true, (ushort)(v | mask));
                    else if (baseOp == "RBR") Write(args[0], true, (ushort)(v & ~mask));
                    // TBR tests only.
                    break;
                }

            // ---- stack ------------------------------------------------------
            case "PUSHS":
                PushSys(Read(args[0], byteWidth, false));
                break;
            case "POPS":
                Write(args[0], byteWidth, PopSys());
                break;
            case "PUSHU":
                {
                    ushort v = Read(args[0], byteWidth, false);
                    ushort u = (ushort)(RegGet(Reg.Usp) - 2);
                    RegSet(Reg.Usp, u);
                    _bus.WriteDataU16(u, v);
                    break;
                }

            // ---- control flow -------------------------------------------------
            case "J":
                _cpu.Pc = JumpTarget(args[0]);
                break;
            case "SJ":
                {
                    short off = _d.Fields.Rel8;
                    _cpu.Pc = (ushort)(_cpu.Pc + off);
                    break;
                }
            case "CAL":
                {
                    ushort target = JumpTarget(args[0]);
                    ushort ret = _cpu.Pc;
                    PushSys(ret);
                    _cpu.Pc = target;
                    break;
                }
            case "SCAL":
                {
                    short off = _d.Fields.Rel8;
                    ushort ret = _cpu.Pc;
                    PushSys(ret);
                    _cpu.Pc = (ushort)(_cpu.Pc + off);
                    break;
                }
            case "VCAL":
                {
                    // Vector call through the table at 0x0028.
                    ushort n = Read(args[0], false, false);
                    ushort ret = _cpu.Pc;
                    PushSys(ret);
                    _cpu.Pc = _bus.ReadCodeU16((ushort)(0x0028 + (n * 2)));
                    break;
                }
            case "RT":
                _cpu.Pc = PopSys();
                break;
            case "RTI":
                {
                    // MSM66201 manual, RTI: hardware restores PSW, LRB, A and PC in that order and advances SSP by eight.
                    ushort psw = PopSys();
                    ushort lrb = PopSys();
                    ushort a3 = PopSys();
                    ushort pc = PopSys();
                    _cpu.SetPswU16(psw);
                    _cpu.Lrb = lrb;
                    _cpu.A = a3;
                    _cpu.Pc = pc;
                    break;
                }
            case "JEQ":
            case "JNE":
            case "JLT":
            case "JGE":
            case "JGT":
            case "JLE":
                {
                    bool z = _cpu.Zf, c = _cpu.Cf;
                    bool take = baseOp switch
                    {
                        "JEQ" => z,
                        "JNE" => !z,
                        "JLT" => c,
                        "JGE" => !c,
                        "JGT" => !c && !z,
                        _ => c || z,
                    };
                    if (take)
                    {
                        short off = _d.Fields.Rel8;
                        _cpu.Pc = (ushort)(_cpu.Pc + off);
                        BranchTaken = true;
                    }
                    break;
                }
            case "JBS":
            case "JBR":
                {
                    ushort bit = (ushort)(Read(args[0], byteWidth, false) & 1);
                    bool take = baseOp == "JBS" ? bit == 1 : bit == 0;
                    if (take)
                    {
                        short off = _d.Fields.Rel8;
                        _cpu.Pc = (ushort)(_cpu.Pc + off);
                        BranchTaken = true;
                    }
                    break;
                }
            case "JRNZ":
                {
                    // Decrement the named register and branch while non-zero.
                    ushort v = (ushort)(Read(args[0], false, false) - 1);
                    Write(args[0], false, v);
                    if (v != 0)
                    {
                        short off = _d.Fields.Rel8;
                        _cpu.Pc = (ushort)(_cpu.Pc + off);
                        BranchTaken = true;
                    }
                    break;
                }
            case "BRK":
                {
                    ushort ret = _cpu.Pc;
                    ushort psw = _cpu.PswU16();
                    PushSys(psw);
                    PushSys(ret);
                    _cpu.Pc = _bus.ReadCodeU16(0x0002);
                    break;
                }

            // ---- misc ---------------------------------------------------------
            case "DAA":
            case "DAS":
                {
                    // Decimal adjust after add/subtract, on the low byte.
                    uint v = (uint)(_cpu.A & 0xFF);
                    uint adjust = ((v & 0x0F) > 9 || _cpu.Hc) ? 6u : 0u;
                    v = baseOp == "DAA" ? v + adjust : v - adjust;
                    uint adjustHi = ((v >> 4) > 9 || _cpu.Cf) ? 0x60u : 0u;
                    v = baseOp == "DAA" ? v + adjustHi : v - adjustHi;
                    _cpu.Cf = v > 0xFF;
                    _cpu.A = (ushort)(((uint)_cpu.A & 0xFF00u) | (v & 0xFF));
                    SetZf((ushort)v, true);
                    break;
                }
            case "XNBL":
                {
                    // Exchange the nibbles of the accumulator low byte with memory.
                    ushort m = Read(args[0], true, false);
                    ushort a4 = (ushort)(_cpu.A & 0xFF);
                    Write(args[0], true, (ushort)((m & 0xF0) | (a4 & 0x0F)));
                    _cpu.A = (ushort)((_cpu.A & 0xFF00) | (a4 & 0xF0) | (m & 0x0F));
                    break;
                }
            case "SMOVI":
                {
                    // Block move [DP] -> [X1], post-incrementing both.
                    ushort src = RegGet(Reg.Dp), dst = RegGet(Reg.X1);
                    byte v = _bus.ReadDataU8(src);
                    _bus.WriteDataU8(dst, v);
                    RegSet(Reg.Dp, (ushort)(src + 1));
                    RegSet(Reg.X1, (ushort)(dst + 1));
                    break;
                }

            default:
                throw ExecException.Unimplemented(_cpu.Pc, _d.Mnemonic);
        }
    }
}

public static class ExecStep
{
    /// Fetch, decode and execute one instruction at PC.
    public static Decoded Step(Cpu cpu, Bus bus) => Step(cpu, bus, out _);

    /// Fetch, decode and execute one instruction at PC, also reporting whether a conditional branch was taken. Coverage needs that outcome: a branch site is only fully covered once both edges have been seen, and the executed-address bitmap alone cannot tell them apart.
    public static Decoded Step(Cpu cpu, Bus bus, out bool branchTaken)
    {
        ushort pc = cpu.Pc;
        var d = Decoder.Decode(cpu.Dd, i => bus.ReadCodeU8((ushort)(pc + i)));
        if (d == null) throw ExecException.UndefinedOpcode(pc, bus.ReadCodeU8(pc));
        Execute(cpu, bus, d, out branchTaken);
        return d;
    }

    /// Execute an already-decoded instruction at PC (the simulator caches decodes per address, since ROM is immutable while running).
    public static void Execute(Cpu cpu, Bus bus, Decoded d, out bool branchTaken)
    {
        branchTaken = false;
        ushort pc = cpu.Pc;

        // PC advances past the instruction before execution, so rel8 targets and pushed return addresses are relative to the *next* instruction.
        cpu.Pc = (ushort)(pc + d.Len);
        cpu.Cycles += d.Cycles;
        cpu.Instructions += 1;

        var parsed = OperandParser.Table()[d.Index];
        if (parsed == null) throw ExecException.Unimplemented(pc, d.Mnemonic);

        var ddAfter = d.DdAfter;
        var ex = new Exec(cpu, bus, d);
        ex.Run(parsed);
        branchTaken = ex.BranchTaken;

        // L/LB-class instructions leave the word/byte mode set for what follows.
        if (ddAfter is bool v) cpu.Dd = v;
        // A taken conditional branch costs four cycles more than fall-through.
        if (branchTaken) cpu.Cycles += 4;
    }
}
