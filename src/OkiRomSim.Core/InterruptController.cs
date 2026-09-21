// OKI MSM66207 Hardware Interrupt Dispatcher.
namespace OkiRomSim.Core;

public static class InterruptVectors
{
    public const ushort Reset = 0x0000;
    public const ushort Nmi = 0x003C;
    public const ushort Tm0 = 0x0086;
    public const ushort Tm1 = 0x0114;
    public const ushort Tm2 = 0x014D;
    public const ushort Int0 = 0x01D3;
    public const ushort SerialRx = 0x01FD;
    public const ushort Tm2Ovf = 0x02DD;
    public const ushort Tm3 = 0x02FB;
    public const ushort PwmIacv = 0x031E;
    public const ushort Int1 = 0x037B;
}

public static class InterruptController
{
    /// Check if pending IRQs match enabled IE flags and dispatch ISR call.
    /// `accept` false latches the request flags without dispatching: the instruction
    /// after RTI always runs before another interrupt is taken, so pending requests
    /// cannot chain straight from one handler into the next.
    public static bool HandlePendingInterrupts(Cpu cpu, Bus bus, ushort extraIrq, bool accept = true)
    {
        // Peripheral edges set IRQ flags even while an ISR is active or the
        // corresponding IE bit is clear. Latch them before deciding whether
        // the CPU can accept another interrupt.
        ushort currentIrq = (ushort)(bus.ReadDataU16(Bus.SfrIrq) | extraIrq);
        bus.WriteDataU16(Bus.SfrIrq, currentIrq);
        ushort ie = bus.ReadDataU16(Bus.SfrIe);

        // PSW.8 is MIE, the global maskable-interrupt enable. Interrupt entry
        // saves PSW and then clears MIE; firmware may set it again inside an
        // ISR when it deliberately permits nesting.
        if (!accept || !cpu.Mie() || (currentIrq & ie) == 0) return false;

        ushort pending = (ushort)(currentIrq & ie);
        int bit = System.Numerics.BitOperations.TrailingZeroCount((uint)pending);
        // The 16 IRQ/IE bits map directly to 16 little-endian vector words.
        ushort isrVector = bus.ReadCodeU16((ushort)(0x0008 + bit * 2));

        // Clear serviced IRQ bit.
        ushort newIrq = (ushort)(currentIrq & ~(1 << bit));
        bus.WriteDataU16(Bus.SfrIrq, newIrq);

        // Hardware interrupt frame, MSM66201 RTI manual p.3-126: PC, A, LRB
        // and PSW are saved using the system stack's store-then-decrement
        // convention. RTI restores them in reverse order.
        ushort psw = cpu.PswU16();
        bus.WriteDataU16(cpu.Ssp, cpu.Pc);
        cpu.Ssp = (ushort)(cpu.Ssp - 2);
        bus.WriteDataU16(cpu.Ssp, cpu.A);
        cpu.Ssp = (ushort)(cpu.Ssp - 2);
        bus.WriteDataU16(cpu.Ssp, cpu.Lrb);
        cpu.Ssp = (ushort)(cpu.Ssp - 2);
        bus.WriteDataU16(cpu.Ssp, psw);
        cpu.Ssp = (ushort)(cpu.Ssp - 2);

        // Maskable interrupt entry clears MIE after saving the old PSW.
        cpu.SetMie(false);

        cpu.Pc = isrVector;
        return true;
    }
}
