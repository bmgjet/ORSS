using OkiRomSim.Core;

namespace OkiRomSim.Tests;

/// Raw-byte vectors from the OKI instruction manual, independent of the assembler.
/// References and scope are in docs/msm66207-qualification.txt.
static class CpuInstructionTests
{
    static Simulator Load(params byte[] code)
    {
        T.P30Part();
        var image = new byte[Chip.RomSize];
        Array.Fill(image, (byte)0xFF);
        image[0] = 0; image[1] = 1;
        code.CopyTo(image, 0x100);
        var sim = new Simulator();
        sim.LoadRom(image);
        return sim;
    }

    static ushort Word(Simulator sim, int address) =>
        (ushort)(sim.Bus.Ram[address] | sim.Bus.Ram[address + 1] << 8);

    static void Word(Simulator sim, int address, ushort value)
    {
        sim.Bus.Ram[address] = (byte)value;
        sim.Bus.Ram[address + 1] = (byte)(value >> 8);
    }

    public static void Run()
    {
        Jrnz();
        DelayLoops();
        RomBootLoops();
        ShiftRight();
    }

    static void Jrnz()
    {
        var sim = Load(0x30, 0x80); // JRNZ DP,0082h; displacement is from 0102h.
        foreach (bool dd in new[] { false, true })
        for (int bank = 0; bank < 8; bank++)
        {
            string? failure = null;
            int vectors = 0;
            foreach (int high in new[] { 0, 1, 0x7F, 0xFF })
            for (int low = 0; low < 256; low++)
            foreach (ushort flags in new ushort[] { 0, 0xE230 })
            {
                Array.Fill(sim.Bus.Ram, (byte)0xA5, 0x80, 64);
                int dp = 0x84 + bank * 8;
                Word(sim, dp, (ushort)(high << 8 | low));
                sim.Cpu.SetPswU16((ushort)(flags | bank | (dd ? 0x1000 : 0)));
                ushort psw = sim.Cpu.PswU16();
                sim.Cpu.Pc = 0x100;
                ulong cycles = sim.Cpu.Cycles, instructions = sim.Cpu.Instructions;
                sim.StepOne();
                int nextLow = (low + 255) & 255;
                bool taken = nextLow != 0;
                ushort expected = (ushort)(high << 8 | nextLow);
                bool untouched = Enumerable.Range(0x80, 64).All(a =>
                    a == dp || a == dp + 1 || sim.Bus.Ram[a] == 0xA5);
                bool ok = Word(sim, dp) == expected && untouched &&
                    sim.Cpu.Pc == (taken ? 0x82 : 0x102) && sim.Cpu.PswU16() == psw &&
                    sim.Cpu.Cycles - cycles == (taken ? 11UL : 7UL) &&
                    sim.Cpu.Instructions - instructions == 1;
                if (!ok && failure == null)
                    failure = $"DP {high:X2}{low:X2} -> {Word(sim, dp):X4}, PC {sim.Cpu.Pc:X4}, PSW {sim.Cpu.PswU16():X4}/{psw:X4}, cycles {sim.Cpu.Cycles - cycles}";
                vectors++;
            }
            T.Check($"JRNZ DPL wrap, DPH/flags preserved, SCB {bank}, DD {(dd ? 1 : 0)}",
                failure == null, failure ?? $"{vectors} vectors; 7 cycles fall-through / 11 taken");
        }
        foreach (byte offset in new byte[] { 0, 0x7F, 0xFF })
        {
            sim = Load(0x30, offset);
            Word(sim, 0x84, 2);
            sim.StepOne();
            ushort target = (ushort)(0x102 + unchecked((sbyte)offset));
            T.Check($"JRNZ relative displacement {offset:X2}", sim.Cpu.Pc == target,
                $"PC {sim.Cpu.Pc:X4}, expected {target:X4}");
        }
    }

    static void DelayLoops()
    {
        foreach (bool dd in new[] { false, true })
        foreach (int bank in new[] { 0, 7 })
        foreach (ushort initial in new ushort[] { 0x0000, 0x0100, 0xFF00, 0x0101, 0x0102, 0x01FF })
        {
            var slow = Load(0x00, 0x30, 0xFD); // NOP / JRNZ DP,0100h
            var fast = Load(0x00, 0x30, 0xFD);
            foreach (var sim in new[] { slow, fast })
            {
                sim.Cpu.SetPswU16((ushort)(0xE230 | bank | (dd ? 0x1000 : 0)));
                Word(sim, 0x84 + bank * 8, initial);
                sim.Bus.Ram[Bus.SfrTcon0] = 0x93; // TM0, fOSC/32 = one tick per 16 machine cycles
                Word(sim, Bus.SfrTm0, 0);
            }
            fast.FastForwardDelayLoops = true;
            foreach (var sim in new[] { slow, fast })
                for (int steps = 0; sim.Cpu.Pc != 0x103 && steps < 1024; steps++) sim.StepOne();
            int iterations = (initial & 255) == 0 ? 256 : initial & 255;
            ulong cycles = (ulong)(iterations * 13 - 4); // NOP=2, JRNZ=11 taken / 7 final
            bool ok = slow.Cpu.Pc == 0x103 && fast.Cpu.Pc == 0x103 &&
                slow.Cpu.Cycles == cycles && fast.Cpu.Cycles == cycles &&
                slow.Cpu.Instructions == (ulong)(2 * iterations) && fast.Cpu.Instructions == slow.Cpu.Instructions &&
                slow.Cpu.PswU16() == fast.Cpu.PswU16() &&
                Word(fast, 0x84 + bank * 8) == (initial & 0xFF00) &&
                Word(slow, 0x84 + bank * 8) == (initial & 0xFF00) &&
                Word(slow, Bus.SfrTm0) == cycles / 16 && Word(fast, Bus.SfrTm0) == cycles / 16 &&
                slow.Bus.Ram.AsSpan(0x80, 64).SequenceEqual(fast.Bus.Ram.AsSpan(0x80, 64)) &&
                (iterations <= 2 ? fast.FastForwardedInstructions == 0 : fast.FastForwardedInstructions > 0);
            T.Check($"JRNZ fast/ordinary loop DP {initial:X4}, SCB {bank}, DD {(dd ? 1 : 0)}", ok,
                $"cycles {slow.Cpu.Cycles}/{fast.Cpu.Cycles} expected {cycles}; DP {Word(fast, 0x84 + bank * 8):X4}; TM0 {Word(slow, Bus.SfrTm0)}/{Word(fast, Bus.SfrTm0)}");
        }

        // Starting at the branch need not mean the body has already run. Local register
        // r4 can also alias DPL: MB r4.0,C then changes the loop counter itself.
        foreach (bool alias in new[] { false, true })
        {
            var sim = Load(alias ? (byte)0x24 : (byte)0x20, 0x38, 0x30, 0xFC);
            sim.Cpu.Lrb = alias ? (ushort)0x10 : (ushort)0x30;
            sim.Cpu.Cf = true;
            Word(sim, 0x84, 3);
            sim.Cpu.Pc = 0x102;
            sim.FastForwardDelayLoops = true;
            sim.StepOne(); sim.StepOne(); // JRNZ taken, then MB executes
            T.Check($"JRNZ executes register-writing body (aliases DPL: {alias})",
                sim.FastForwardedInstructions == 0 && sim.Cpu.Pc == 0x102 &&
                Word(sim, 0x84) == (alias ? 3 : 2) &&
                (alias || sim.Bus.Ram[0x180] == 1));
        }

        // An enabled interrupt source must disable the optimization.
        var guarded = Load(0x00, 0x30, 0xFD);
        Word(guarded, 0x84, 0x0100);
        guarded.FastForwardDelayLoops = true;
        guarded.Cpu.SetMie(true);
        Word(guarded, 0x1A, 1);
        guarded.StepOne(); guarded.StepOne();
        T.Check("JRNZ fast-forward remains disabled with interrupts enabled",
            guarded.FastForwardedInstructions == 0 && Word(guarded, 0x84) == 0x01FF &&
            guarded.Cpu.Cycles == 13 && guarded.Cpu.Pc == 0x100);
    }

    static void RomBootLoops()
    {
        // Exercise the first native JRNZ in the upstream test fixtures.
        foreach (string rom in new[] { "p30.bin", "p13.bin" })
        {
            if (rom == "p13.bin") T.P13Part(); else T.P30Part();
            var sim = new Simulator();
            sim.LoadRom(File.ReadAllBytes(T.Roms(rom)));
            bool found = false;
            for (int step = 0; step < 100_000; step++)
            {
                var d = sim.DecodeCached(sim.Cpu.Pc);
                if (d.Mnemonic.StartsWith("JRNZ ", StringComparison.Ordinal))
                {
                    ushort pc = sim.Cpu.Pc, psw = sim.Cpu.PswU16();
                    int dp = 0x84 + sim.Cpu.Scb() * 8;
                    ushort before = Word(sim, dp);
                    int dpl = ((before & 255) + 255) & 255;
                    ulong cycles = sim.Cpu.Cycles;
                    sim.StepOne();
                    ushort target = (ushort)(pc + 2 + (dpl != 0 ? d.Fields.Rel8 : 0));
                    T.Check($"{rom}: first native JRNZ obeys the low-byte counter",
                        Word(sim, dp) == ((before & 0xFF00) | dpl) && sim.Cpu.Pc == target &&
                        sim.Cpu.PswU16() == psw && sim.Cpu.Cycles - cycles == (dpl == 0 ? 7UL : 11UL),
                        $"PC {pc:X4}, DP {before:X4} -> {Word(sim, dp):X4}, next PC {sim.Cpu.Pc:X4}");
                    found = true;
                    break;
                }
                sim.StepOne();
            }
            T.Check($"{rom}: boot reaches JRNZ within 100000 instructions", found);
        }
        T.P30Part();
    }

    static void ShiftRight()
    {
        // Address -1 denotes A; other operands use internal RAM. Explicit obj forms ignore DD.
        var forms = new (string Name, byte[] Code, int Address, bool Byte, ushort Cycles)[]
        {
            ("SRL A", [0x63], -1, false, 2),
            ("SRLB A", [0x63], -1, true, 2),
            ("SRL er1", [0x45, 0xE7], 0x182, false, 5),
            ("SRLB r1", [0x21, 0xE7], 0x181, true, 5),
            ("SRL DP", [0x92, 0xE7], 0x9C, false, 5),
            ("SRL [DP]", [0xB2, 0xE7], 0x280, false, 7),
            ("SRLB [DP]", [0xC2, 0xE7], 0x280, true, 7),
            ("SRL off N8", [0xB4, 0xE0, 0xE7], 0x1E0, false, 7),
            ("SRLB off N8", [0xC4, 0xE0, 0xE7], 0x1E0, true, 7),
            ("SRL N8", [0xB5, 0xE0, 0xE7], 0xE0, false, 7),
            ("SRLB N8", [0xC5, 0xE0, 0xE7], 0xE0, true, 7),
            ("SRL S8[USP]", [0xB3, 0x04, 0xE7], 0x304, false, 8),
            ("SRLB S8[USP]", [0xC3, 0x04, 0xE7], 0x304, true, 8),
            ("SRL N16[X1]", [0xB0, 0x06, 0x00, 0xE7], 0x326, false, 9),
            ("SRLB N16[X1]", [0xC0, 0x06, 0x00, 0xE7], 0x326, true, 9),
            ("SRL N16[X2]", [0xB1, 0x06, 0x00, 0xE7], 0x346, false, 9),
            ("SRLB N16[X2]", [0xC1, 0x06, 0x00, 0xE7], 0x346, true, 9),
        };
        foreach (var form in forms)
        foreach (bool dd in new[] { false, true })
        {
            if (form.Address == -1 && dd == form.Byte) continue;
            string? failure = null;
            foreach (ushort input in new ushort[] { 0, 1, 2, 0x80, 0xFF, 0x8000, 0xFFFF })
            foreach (bool z in new[] { false, true })
            foreach (bool c in new[] { false, true })
            {
                var sim = Load(form.Code);
                sim.Cpu.SetPswU16((ushort)(0x2233 | (dd ? 0x1000 : 0) | (z ? 0x4000 : 0) | (c ? 0x8000 : 0)));
                sim.Cpu.Lrb = 0x30; // local registers 0180h; off-page 0100h
                Word(sim, 0x98, 0x320); Word(sim, 0x9A, 0x340);
                Word(sim, 0x9C, 0x280); Word(sim, 0x9E, 0x300);
                ushort value = form.Byte ? (ushort)(0xA500 | (input & 255)) : input;
                if (form.Address == -1) sim.Cpu.A = value;
                else Word(sim, form.Address, value);
                ushort psw = sim.Cpu.PswU16();
                var decoded = sim.DecodeCached(0x100);
                sim.StepOne();
                ushort expected = form.Byte ? (ushort)(0xA500 | ((input & 255) >> 1)) : (ushort)(input >> 1);
                ushort actual = form.Address == -1 ? sim.Cpu.A : Word(sim, form.Address);
                ushort expectedPsw = (ushort)((psw & ~Cpu.PswCfBit) | ((input & 1) != 0 ? Cpu.PswCfBit : 0));
                if (failure == null && (actual != expected || sim.Cpu.PswU16() != expectedPsw ||
                    decoded.Cycles != form.Cycles || sim.Cpu.Cycles != form.Cycles ||
                    sim.Cpu.Pc != 0x100 + form.Code.Length))
                    failure = $"input {value:X4}, result {actual:X4}/{expected:X4}, PSW {sim.Cpu.PswU16():X4}/{expectedPsw:X4}, cycles {sim.Cpu.Cycles}/{form.Cycles}";
            }
            T.Check($"{form.Name}: value, carry, Z/HC/DD preservation and INT cycles; DD {(dd ? 1 : 0)}",
                failure == null, failure ?? "28 vectors");
        }
    }
}
