// Copyright (c) bmgjet. All rights reserved.
// OKI MSM66207 / 66201 CPU Registers & Flags. Used in Honda OBD1 ECUs (P28, P30, P72, etc.)
namespace OkiRomSim.Core;

public sealed class Cpu
{
    public ushort Pc;      // Program Counter
    public ushort A;       // 16-bit Accumulator (Word mode: A, Byte mode: AL/AH)
    public ushort Dp;      // Data Pointer (DPH, DPL) -- lives in RAM, mirrored via Bus
    public ushort X1;
    public ushort X2;
    public ushort Usp;     // User Stack Pointer
    public ushort Ssp = 0x07FE; // System Stack Pointer
    // Local Register Bank pointer. Its own 16-bit register (SFR 0x02), NOT a field packed into PSW: bits 5..7 select the RAM page and bits 0..4 select the bank within it. See BankBase() / OffPage().
    public ushort Lrb;

    // PSW flags
    public bool Zf;
    public bool Cf;   // Carry / Borrow (CF=1 on borrow for SUB/CMP)
    public bool Hc;   // Half carry
    public bool Dd;   // Data width mode: true = 16-bit word mode, false = 8-bit byte mode
    // PSW bits with no named flag. The ROM uses several as scratch (PSWH.0 is MIE), so they must survive PUSHS/POPS and interrupt entry/exit rather than being dropped.
    public ushort PswOther;

    public ulong Cycles;
    public ulong Instructions;
    public bool Halted;

    public byte Al => (byte)(A & 0xFF);
    public byte Ah => (byte)((A >> 8) & 0xFF);
    public void SetAl(byte v) => A = (ushort)((A & 0xFF00) | v);
    public void SetAh(byte v) => A = (ushort)((A & 0x00FF) | (v << 8));

    public byte Dpl => (byte)(Dp & 0xFF);
    public byte Dph => (byte)((Dp >> 8) & 0xFF);
    public void SetDpl(byte v) => Dp = (ushort)((Dp & 0xFF00) | v);
    public void SetDph(byte v) => Dp = (ushort)((Dp & 0x00FF) | (v << 8));

    // PSW layout, from the MSM66201/66P201/66207/66P207 datasheet, p.9: bits 0-2 SCB (System Control Base) -- selects pointing register set PR0..PR7, where X1/X2/DP/USP physically live (Fig. 1-5). bits 15-12 CF, ZF, HC, DD bits 9,5,4 user flags; bit 8 master interrupt enable (MIE) Bits 3, 6, 7, 10 and 11 are unimplemented and read as 1, which yields the documented reset PSW of 0x0CC8 with every writable flag cleared.
    private const ushort PswReadsOne = 0x0CC8;
    private const ushort PswStorage = (1 << 9) | (1 << 8) | (1 << 5) | (1 << 4) | 0b0000_0111;

    public const ushort PswCfBit = 1 << 15;
    public const ushort PswZfBit = 1 << 14;
    public const ushort PswHcBit = 1 << 13;
    public const ushort PswDdBit = 1 << 12;
    public const ushort PswMieBit = 1 << 8;

    public ushort PswU16()
    {
        ushort psw = (ushort)((PswOther & PswStorage) | PswReadsOne);
        if (Cf) psw |= PswCfBit;
        if (Zf) psw |= PswZfBit;
        if (Hc) psw |= PswHcBit;
        if (Dd) psw |= PswDdBit;
        return psw;
    }

    public void SetPswU16(ushort val)
    {
        Cf = (val & PswCfBit) != 0;
        Zf = (val & PswZfBit) != 0;
        Hc = (val & PswHcBit) != 0;
        Dd = (val & PswDdBit) != 0;
        PswOther = (ushort)(val & PswStorage);
    }

    public bool Mie() => (PswOther & PswMieBit) != 0;

    public void SetMie(bool enabled)
    {
        if (enabled) PswOther |= PswMieBit;
        else PswOther &= unchecked((ushort)~PswMieBit);
    }

    /// System Control Base: which pointing-register set (PR0..PR7) is live.
    public ushort Scb() => (ushort)(PswOther & 0x07);

    /// Base address of the local register bank holding r0..r7 / er0..er3.
    public ushort BankBase() => (ushort)(((Lrb >> 5) << 8) | ((Lrb & 0x1F) << 3));

    /// Resolve an `off N8` operand: the LRB page with N8 as the offset.
    public ushort OffPage(byte n8) => (ushort)(((Lrb >> 5) << 8) | n8);
}
