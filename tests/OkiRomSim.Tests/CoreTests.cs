// Copyright (c) bmgjet. All rights reserved.
using System.Reflection;
using OkiRomSim.Core;

namespace OkiRomSim.Tests;

/// The core and simulator fixes, each on the smallest program that shows it. (That the shipped ROMs still run exactly as before is the
/// simulation checkpoints in the p30 / p13 / roms groups: none of them uses the instructions changed here.)
static class CoreTests
{
    /// A 32 KB image of FF with the reset vector pointing at 0100h and `code` there.
    static byte[] Program(params byte[] code)
    {
        var img = new byte[Chip.RomSize];
        Array.Fill(img, (byte)0xFF);
        img[0] = 0x00; img[1] = 0x01;
        code.CopyTo(img, 0x100);
        return img;
    }

    static Simulator Load(byte[] image)
    {
        T.P30Part();
        var sim = new Simulator();
        sim.LoadRom(image);
        return sim;
    }

    public static void Run()
    {
        // J [[DP]] (B2 22): the [DP] memory object - the jump goes to the word held at DP. J [DP] (92 22): the register - it goes to DP itself.
        {
            var sim = Load(Program(0xB2, 0x22));
            sim.Bus.Ram[0x84] = 0x80; sim.Bus.Ram[0x85] = 0x02;        // DP (pointing register, SCB 0) = 0280h
            sim.Bus.Ram[0x280] = 0x00; sim.Bus.Ram[0x281] = 0x02;      // the word at 0280h = 0200h
            sim.StepOne();
            T.Check("J [[DP]] goes to the word held at DP (the opcode table's [DP] object, as its comment says)", sim.Cpu.Pc == 0x0200, $"PC {sim.Cpu.Pc:X4}h (DP 0280h, word there 0200h)");
        }
        {
            var sim = Load(Program(0x92, 0x22));
            sim.Bus.Ram[0x84] = 0x80; sim.Bus.Ram[0x85] = 0x02;
            sim.StepOne();
            T.Check("J [DP] still goes to DP itself (the serial dispatch the 66207 ROMs use)", sim.Cpu.Pc == 0x0280, $"PC {sim.Cpu.Pc:X4}h");
        }
        // decimal adjust: 99h + 99h = 132h leaves A = 32h with carry and half carry; DAA makes 98h and keeps the carry (the hundreds)
        {
            var sim = Load(Program(0x93));
            sim.Cpu.A = 0x0032; sim.Cpu.Cf = true; sim.Cpu.Hc = true;
            sim.StepOne();
            T.Check("DAA after 99h + 99h: 98h with the decimal carry kept", (sim.Cpu.A & 0xFF) == 0x98 && sim.Cpu.Cf, $"A {sim.Cpu.A & 0xFF:X2}h, carry {sim.Cpu.Cf}");
        }
        {
            var sim = Load(Program(0x93));
            sim.Cpu.A = 0x0012; sim.Cpu.Cf = false; sim.Cpu.Hc = false;
            sim.StepOne();
            T.Check("DAA with nothing to adjust leaves the value and no carry", (sim.Cpu.A & 0xFF) == 0x12 && !sim.Cpu.Cf, $"A {sim.Cpu.A & 0xFF:X2}h, carry {sim.Cpu.Cf}");
        }
        // 00h - 01h = FFh with borrow and half borrow; DAS makes 99h and keeps the borrow
        {
            var sim = Load(Program(0x94));
            sim.Cpu.A = 0x00FF; sim.Cpu.Cf = true; sim.Cpu.Hc = true;
            sim.StepOne();
            T.Check("DAS after 00h - 01h: 99h with the decimal borrow kept", (sim.Cpu.A & 0xFF) == 0x99 && sim.Cpu.Cf, $"A {sim.Cpu.A & 0xFF:X2}h, borrow {sim.Cpu.Cf}");
        }
        // the serial line: a tool that keeps writing while the simulator is paused does not pile up an endless backlog
        {
            var sim = Load(Program(0x00));
            sim.Bus.QueueSerialRx(new byte[5000], 100);
            var q = typeof(Bus).GetField("_rxIncoming", BindingFlags.NonPublic | BindingFlags.Instance)?.GetValue(sim.Bus) as System.Collections.ICollection;
            if (q == null) T.Skip("the serial receive backlog is capped", "Bus._rxIncoming not found");
            else T.Check("the serial receive backlog is capped (5000 bytes queued while paused)", q.Count <= 512, $"{q.Count} kept");
        }
        // a project's machine state with one entry that is not what it should be: the rest still comes back
        {
            var image = File.ReadAllBytes(T.Roms("p30.bin"));
            var a = Load(image);
            for (int i = 0; i < 200_000; i++) a.StepOne();
            var saved = StateSnapshot.Capture(a);
            // an array entry (base64 with letters in it - a long number alone could pass for base64)
            var key = saved.Keys.FirstOrDefault(k => saved[k].Length > 8 && saved[k].Any(c => char.IsLetter(c) || c is '+' or '/' or '=') && IsBase64(saved[k]));
            if (key != null) saved[key] = "not base64 at all!";
            var b = Load(image);
            int n = -1; Exception? err = null;
            try { n = StateSnapshot.Restore(b, saved); } catch (Exception ex) { err = ex; }
            T.Check("a snapshot with a corrupt entry restores the rest instead of stopping half way", key != null && err == null && n >= saved.Count / 2,
                err?.Message ?? $"{n} of {saved.Count} entries restored, {key ?? "(no array entry found to corrupt)"} skipped");
            // (that an intact snapshot puts the machine back exactly is RomSimStudio --selftest-project, run in the builds group)
        }
        // a processor profile with a list written as null is refused before anything is applied
        {
            T.P30Part();
            var hzBefore = Chip.CpuHz;
            var json = ProcessorProfile.Msm66911().ToJson().Replace("\"VectorNames\": [", "\"VectorNames\": null, \"x\": [");
            T.Throws<InvalidDataException>("a processor profile with a null list is refused", () => ProcessorProfile.FromJson(json));
            T.Check("... while it is read, before Apply: the part in use is still the 66207 at its own clock (Apply used to switch clock and part, then throw)",
                Chip.CpuHz == hzBefore && !Chip.Is66911, $"{Chip.CpuHz} Hz, 66911 {Chip.Is66911}");
        }
        // a ROM loaded from a file finds where it keeps its trap reason, as one loaded from bytes does
        {
            using var s = T.NewScratch("core");
            var path = s.Copy(T.Roms("p13.bin"));
            T.P13Part();
            var fromBytes = new Simulator(); fromBytes.LoadRom(File.ReadAllBytes(path));
            var fromFile = new Simulator(); fromFile.LoadRomFile(path);
            T.Check("LoadRomFile finds the trap-reason byte as LoadRom does", fromFile.TrapReasonCodeAddr == fromBytes.TrapReasonCodeAddr,
                $"{fromFile.TrapReasonCodeAddr:X4}h / {fromBytes.TrapReasonCodeAddr:X4}h");
            T.P30Part();
        }
        // what the tuner relies on: the part's numbers outside the simulator, and the simulator reading the same ones
        T.P13Part();
        bool p13 = Chip.Is66911 && Bus.Is66911 && Chip.CpuHz == Bus.CpuHz && Chip.RomSize == Bus.RomSize;
        T.P30Part();
        T.Check("Chip (no simulator) and Bus (the simulator) agree on the part", p13 && !Chip.Is66911 && !Bus.Is66911 && Chip.CpuHz == Bus.CpuHz);
        T.Check("MilCodes (no simulator) and MilMonitor (the simulator) give the same codes", Enumerable.Range(0, 48).All(b => MilCodes.FaultBitCode(b) == MilMonitor.FaultBitCode(b))
                && Enumerable.Range(0, 32).All(i => MilCodes.FlashCode(i) == MilMonitor.FlashCode(i)));
    }

    static bool IsBase64(string s)
    {
        try { Convert.FromBase64String(s); return true; } catch { return false; }
    }
}
