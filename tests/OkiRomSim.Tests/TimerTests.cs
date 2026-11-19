// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Core;

namespace OkiRomSim.Tests;

/// MSM66207 user manual, printed pp. 90-95 (mode C/D and tables 9-3/9-4).
/// Direct SFR tests isolate timer semantics from CPU decoding and board feedback.
/// These tests do not establish intra-instruction TCON write/compare arbitration.
static class TimerTests
{
    static Bus Fresh()
    {
        T.P30Part();
        return new Bus();
    }

    static ushort Word(Bus b, ushort a) => (ushort)(b.Ram[a] | b.Ram[a + 1] << 8);
    static void Word(Bus b, ushort a, ushort v)
    {
        b.Ram[a] = (byte)v;
        b.Ram[a + 1] = (byte)(v >> 8);
    }
    static ushort Tm(int i) => (ushort)(Bus.SfrTm0 + 4 * i);
    static ushort Tmr(int i) => (ushort)(Bus.SfrTmr0 + 4 * i);
    static ushort Con(int i) => (ushort)(Bus.SfrTcon0 + i);
    static int Event(int i) => new[] { 5, 7, 9, 11 }[i];

    public static void Run()
    {
        // The command estimate counts a completed LOW interval, not electrical current.
        {
            var b = Fresh();
            b.WriteDataU8(Bus.SfrP3Sf, 0x80);
            b.WriteDataU8(Bus.SfrTcon3, 0x9F);
            T.Check("Timer 3 initial HIGH does not fabricate command completion", b.IgnitionEvents == 0);
            b.Ram[Bus.SfrTrns] &= 0xFD;
            b.WriteDataU8(Bus.SfrTcon3, 0x93);
            b.TickTimers(100);
            T.Check("Timer 3 LOW starts dwell estimate without ignition feedback", b.IgnitionEvents == 0 && (b.Ram[Bus.SfrTrns] & 2) == 0);
            b.WriteDataU8(Bus.SfrTcon3, 0x9F);
            T.Check("Timer 3 rising command completes the observed LOW interval", b.IgnitionEvents == 1 && b.LastDwellUs == 20 && (b.Ram[Bus.SfrTrns] & 2) != 0);
            b.Ram[Bus.SfrTrns] &= 0xFD;
            b.WriteDataU8(Bus.SfrTcon3, 0x9F);
            T.Check("Timer 3 unchanged HIGH creates no duplicate completion", b.IgnitionEvents == 1 && (b.Ram[Bus.SfrTrns] & 2) == 0);
            b.WriteDataU8(Bus.SfrTcon3, 0x93);
            b.TickTimers(200_000);
            T.Check("Timer 3 sustained LOW has no invented timeout or completion", b.IgnitionEvents == 1 && (b.Ram[Bus.SfrTrns] & 2) == 0 && (b.ReadPort(3) & 0x80) == 0);
            b.WriteDataU8(Bus.SfrP3Sf, 0);
            b.WriteDataU8(Bus.SfrTcon3, 0x9F);
            b.WriteDataU8(Bus.SfrP3Sf, 0x80);
            T.Check("Timer 3 remux discards an incomplete inferred command", b.IgnitionEvents == 1);
        }
        int[] oscillatorDivisors = [2, 4, 8, 16, 32, 128, 512];
        for (int i = 0; i < 4; i++)
        for (int sel = 0; sel < 7; sel++)
        {
            var b = Fresh();
            b.WriteDataU8(Con(i), (byte)((sel << 5) | 0x13));
            b.TickTimers(512); // 1024 oscillator clocks at the standard fOSC/2 CPU clock.
            int want = 1024 / oscillatorDivisors[sel];
            T.Check($"TM{i} selector {sel:X}: /{oscillatorDivisors[sel]} oscillator", Word(b, Tm(i)) == want,
                $"expected {want}, got {Word(b, Tm(i))}");
        }
        for (int i = 0; i < 4; i++)
        {
            var b = Fresh();
            b.WriteDataU8(Con(i), 0xF3); // external/unsupported external selector, no external pulses supplied
            b.TickTimers(512);
            T.Check($"TM{i} external selector receives no CPU-derived clock", Word(b, Tm(i)) == 0);

            b = Fresh();
            b.WriteDataU8(Con(i), 0x8B); // stopped, mode D, buffer high
            Word(b, Tmr(i), 1);
            b.TickTimers(100);
            T.Check($"TM{i} RUN=0 freezes counter and compare output",
                Word(b, Tm(i)) == 0 && (b.Ram[Con(i)] & 4) == 0 && Word(b, Bus.SfrIrq) == 0);

            for (int start = 0; start <= 1; start++)
            for (int buffer = 0; buffer <= 1; buffer++)
            {
                b = Fresh();
                b.WriteDataU8(Bus.SfrP3Sf, (byte)(0x10 << i));
                byte con = (byte)(0x93 | start * 4 | buffer * 8); // mode D, fOSC/32
                b.WriteDataU8(Con(i), con);
                Word(b, Tmr(i), 1);
                b.TickTimers(15);
                bool before = (b.Ram[Con(i)] & 4) == start * 4 && (Word(b, Bus.SfrIrq) & (1 << Event(i))) == 0;
                b.TickTimers(1);
                bool after = (b.Ram[Con(i)] & 4) == buffer * 4
                    && (Word(b, Bus.SfrIrq) & (1 << Event(i))) != 0
                    && ((b.ReadPort(3) >> (4 + i)) & 1) == buffer
                    && (b.Ram[Con(i)] & ~4) == (con & ~4)
                    && Word(b, Tm(i)) == 1;
                T.Check($"TM{i} mode D copies buffer {buffer} to output {start} at compare with IE=0", before && after,
                    $"TCON={b.Ram[Con(i)]:X2}, IRQ={Word(b, Bus.SfrIrq):X4}, P3={b.ReadPort(3):X2}");
                b.TickTimers(16 * 65536);
                T.Check($"TM{i} repeated compare with unchanged buffer does not toggle", (b.Ram[Con(i)] & 4) == buffer * 4);
            }

            b = Fresh();
            b.WriteDataU8(Con(i), 0x9B);
            Word(b, Tm(i), 0xFFFE);
            Word(b, Tmr(i), 1);
            b.TickTimers(48);
            T.Check($"TM{i} wrap reaches compare and latches overflow separately",
                Word(b, Tm(i)) == 1 && (b.Ram[Con(i)] & 4) != 0
                && (Word(b, Bus.SfrIrq) & (3 << (Event(i) - 1))) == (3 << (Event(i) - 1)));

            b = Fresh();
            b.WriteDataU8(Con(i), 0x9B);
            Word(b, Tmr(i), 0);
            b.TickTimers(16 * 65536);
            T.Check($"TM{i} full 65536-step batch does not disappear",
                Word(b, Tm(i)) == 0 && (b.Ram[Con(i)] & 4) != 0
                && (Word(b, Bus.SfrIrq) & (3 << (Event(i) - 1))) == (3 << (Event(i) - 1)));

            b = Fresh();
            b.WriteDataU8(Con(i), 0x92); // capture mode: remember equality; publish TCERR at the next capture
            Word(b, Tmr(i), 1);
            b.TickTimers(16);
            T.Check($"TM{i} capture equality waits for the next capture before publishing TCERR",
                (b.Ram[Con(i)] & 4) == 0 && (Word(b, Bus.SfrIrq) & (1 << Event(i))) == 0);
        }

        {
            var b = Fresh();
            b.WriteDataU8(Bus.SfrP3Sf, 0x40);
            b.WriteDataU8(Bus.SfrTcon2, 0x92);
            Word(b, Bus.SfrTmr2, 1);
            b.TickTimers(16);
            b.CaptureTm2();
            T.Check("TM2 next capture publishes remembered equality as TCERR",
                (b.Ram[Bus.SfrTcon2] & 4) != 0 && Word(b, Bus.SfrTmr2) == 1);
            b.TickTimers(32);
            b.CaptureTm2();
            T.Check("TM2 following capture without a wrap clears TCERR",
                (b.Ram[Bus.SfrTcon2] & 4) == 0 && Word(b, Bus.SfrTmr2) == 3);
            b.WriteDataU8(Bus.SfrTcon2, 0x93);
            Word(b, Bus.SfrTm2, 10);
            b.CaptureTm2();
            T.Check("TM2 output mode does not accept capture input", Word(b, Bus.SfrTmr2) == 3);
            b.WriteDataU8(Bus.SfrTcon2, 0x92);
            b.WriteDataU8(Bus.SfrP3Sf, 0);
            b.CaptureTm2();
            T.Check("TM2 without secondary pin selection does not accept capture", Word(b, Bus.SfrTmr2) == 3);
        }
        {
            var b = Fresh();
            b.WriteDataU8(Bus.SfrP3Sf, 0x80);
            b.WriteDataU8(Bus.SfrTcon3, 0x93);
            Word(b, Bus.SfrTmr3, 1);
            b.WriteDataU8(Bus.SfrTcon3, 0x9B);
            T.Check("Writing TRBUF alone leaves TM3IO low", (b.ReadPort(3) & 0x80) == 0);
            b.TickTimers(16);
            T.Check("Compare drives TM3IO high before interrupt service", (b.ReadPort(3) & 0x80) != 0 && b.Pins.Changes[3, 7] == 1);
            b.WriteDataU8(Bus.SfrTcon3, 0x97); // new low buffer, keep live high
            T.Check("Clearing buffer preserves the armed live high output", (b.ReadPort(3) & 0x80) != 0);
            Word(b, Bus.SfrTmr3, 2);
            b.TickTimers(16);
            T.Check("Next compare drives low without completing a Timer 3 ignition command",
                (b.ReadPort(3) & 0x80) == 0 && b.Pins.Changes[3, 7] == 2 && b.IgnitionEvents == 0);
            b.WriteDataU8(Bus.SfrTcon3, 0x97);
            T.Check("Direct TROUT write immediately drives TM3IO high", (b.ReadPort(3) & 0x80) != 0);
            b.WriteDataU8(Bus.SfrTcon3, 0x93);
            T.Check("Direct TROUT clear immediately drives TM3IO low", (b.ReadPort(3) & 0x80) == 0 && b.IgnitionEvents == 1);
            b.WriteDataU8(Bus.SfrP3Sf, 0);
            b.WriteDataU8(Bus.SfrP3Io, 0x80);
            b.WriteDataU8(Bus.SfrP3, 0x80);
            b.WriteDataU8(Bus.SfrTcon3, 0x93);
            T.Check("P3SF=0 leaves the GPIO latch in control", (b.ReadPort(3) & 0x80) != 0);
        }
        {
            var b = Fresh();
            b.WriteDataU8(Bus.SfrP3Sf, 0x80);
            b.WriteDataU8(Bus.SfrTcon3, 0x9F);
            Word(b, Bus.SfrTmr3, 1);
            b.TickTimers(16);
            b.TickTimers(16 * 65536);
            T.Check("Repeated high compares do not fabricate a spark or timeout release",
                b.IgnitionEvents == 0 && (b.ReadPort(3) & 0x80) != 0);
        }
        {
            var batch = Fresh();
            var single = Fresh();
            foreach (var b in new[] { batch, single })
            {
                b.WriteDataU8(Bus.SfrP3Sf, 0x80);
                b.WriteDataU8(Bus.SfrTcon3, 0x9B);
                Word(b, Bus.SfrTmr3, 1);
            }
            batch.TickTimers(160);
            for (int j = 0; j < 160; j++) single.TickTimers(1);
            T.Check("Timer output timestamp is the compare cycle, not the batch end",
                batch.Pins.LastChange[3, 7] == 16 && single.Pins.LastChange[3, 7] == 16);
            T.Check("Timer secondary output has effective output direction", (batch.Pins.Direction[3] & 0x80) != 0);
            foreach (var b in new[] { batch, single })
            {
                b.WriteDataU8(Bus.SfrTcon3, 0x97);
                Word(b, Bus.SfrTmr3, 11);
            }
            batch.TickTimers(32);
            for (int j = 0; j < 32; j++) single.TickTimers(1);
            T.Check("Logical high duration is independent of timer batching",
                batch.Pins.LastChange[3, 7] == 176 && single.Pins.LastChange[3, 7] == 176
                && batch.Pins.LastHighCycles[3, 7] == 160 && single.Pins.LastHighCycles[3, 7] == 160);
        }
        {
            var a = Fresh();
            var b = Fresh();
            a.TickTimers(7); b.TickTimers(7);
            a.WriteDataU8(Bus.SfrTcon1, 0x53); b.WriteDataU8(Bus.SfrTcon1, 0x53);
            a.WriteDataU8(Bus.SfrTcon3, 0x93); b.WriteDataU8(Bus.SfrTcon3, 0x93);
            a.TickTimers(113);
            for (int j = 0; j < 113; j++) b.TickTimers(1);
            T.Check("Shared prescaler phase is independent of TickTimers batching",
                Word(a, Bus.SfrTm1) == Word(b, Bus.SfrTm1) && Word(a, Bus.SfrTm3) == Word(b, Bus.SfrTm3));
        }
    }
}
