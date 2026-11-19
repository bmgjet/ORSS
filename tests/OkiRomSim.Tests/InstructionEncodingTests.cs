// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Assembler;
using OkiRomSim.Core;

namespace OkiRomSim.Tests;

// Raw vectors from OKI chapter 3, printed 3-79/80 and 3-113.
// Encoding expectations are independent of both the assembler and decoder tables.
static class InstructionEncodingTests
{
    static AssemblyResult Assemble(string instruction) => new OkiAssembler(new AssemblerOptions())
        .AssembleText("ORG 100h\n" + instruction + "\n", Path.Combine(Path.GetTempPath(), "oki-encoding.asm"));

    public static void Run()
    {
        T.P30Part();
        var vectors = new (string Operand, byte[] Prefix, ushort Read, ushort Write)[]
        {
            ("r0", [0x20], 5, 10), ("r7", [0x27], 5, 10),
            ("PSWH", [0xA2], 5, 10), ("PSWL", [0xA3], 5, 10),
            ("off 0B7h", [0xC4, 0xB7], 7, 12), ("0B7h", [0xC5, 0xB7], 7, 12),
            ("[DP]", [0xC2], 7, 12), ("4[USP]", [0xC3, 4], 8, 13),
            ("6[X1]", [0xC0, 6, 0], 9, 14), ("6[X2]", [0xC1, 6, 0], 9, 14),
        };
        foreach (var v in vectors)
        foreach (bool toCarry in new[] { false, true })
        {
            string syntax = toCarry ? $"MBR C, {v.Operand}" : $"MBR {v.Operand}, C";
            byte[] bytes = [.. v.Prefix, (byte)(toCarry ? 0x21 : 0x20)];
            var assembled = Assemble(syntax);
            T.Check($"{syntax}: manufacturer encoding", assembled.Success && assembled.Image.AsSpan(0x100, bytes.Length).SequenceEqual(bytes));
            bool decoded = true, cost = true;
            foreach (bool dd in new[] { false, true })
            {
                var d = Decoder.Decode(dd, i => i < bytes.Length ? bytes[i] : (byte)0xFF);
                decoded &= d != null && d.Len == bytes.Length && d.Mnemonic.StartsWith("MBR ") && d.DdAfter == null;
                cost &= d?.Cycles == (toCarry ? v.Read : v.Write);
                if (d != null)
                {
                    var roundtrip = Assemble(Decoder.Format(d, (ushort)(0x100 + d.Len)));
                    decoded &= roundtrip.Success && roundtrip.Image.AsSpan(0x100, bytes.Length).SequenceEqual(bytes);
                }
            }
            T.Check($"{syntax}: DD-independent decode and round trip", decoded);
            T.Check($"{syntax}: documented INT cycles", cost);
        }

        foreach (bool off in new[] { false, true })
        foreach (bool toCarry in new[] { false, true })
        {
            bool correct = true;
            foreach (bool dd in new[] { false, true })
            for (int bit = 0; bit < 8; bit++)
            foreach (bool set in new[] { false, true })
            {
                var c = new Cpu { Pc = 0x100, A = (ushort)(0xAC00 | bit), Lrb = 0x21, Dd = dd, Cf = set, Zf = true, Hc = true };
                var b = new Bus();
                b.Rom[0x100] = off ? (byte)0xC4 : (byte)0xC5;
                b.Rom[0x101] = 0xB7;
                b.Rom[0x102] = toCarry ? (byte)0x21 : (byte)0x20;
                b.Ram[0xB7] = 0xA5; b.Ram[0x1B7] = 0x5A;
                ushort address = off ? (ushort)0x1B7 : (ushort)0xB7;
                byte before = b.Ram[address];
                ExecStep.Step(c, b);
                byte expected = toCarry ? before : (byte)(set ? before | (1 << bit) : before & ~(1 << bit));
                correct &= b.Ram[address] == expected && b.Ram[off ? 0xB7 : 0x1B7] == (off ? 0xA5 : 0x5A)
                    && c.Cf == (toCarry ? (before & (1 << bit)) != 0 : set) && c.Dd == dd && c.Zf && c.Hc
                    && c.A == (0xAC00 | bit) && c.Pc == 0x103 && c.Lrb == 0x21;
            }
            T.Check($"MBR {(off ? "C4/off" : "C5/direct")} {(toCarry ? "read" : "write")}: page, all bits, flags and neighbors", correct);
        }

        // The legacy assembler grammar has unsupported word-object OR-immediate forms.
        // It must reject them rather than emit the historically erroneous D0/AND bytes.
        // This is a diagnostic contract, not a claim that this valid manufacturer-listed form is invalid.
        foreach (string obj in new[] { "DP", "er0", "off 0B0h", "[DP]" })
            T.Check($"unsupported OR {obj},#1234h fails explicitly", !Assemble($"OR {obj},#1234h").Success);
        var and = Assemble("AND DP,#1234h");
        T.Check("D0 immediate remains AND, never the legacy erroneous OR alias", and.Success
            && and.Image.AsSpan(0x100, 4).SequenceEqual(new byte[] { 0x92, 0xD0, 0x34, 0x12 })
            && Decoder.Decode(true, i => and.Image[0x100 + i])?.Mnemonic.StartsWith("AND ") == true);
        var push = Assemble("PUSHS A");
        T.Check("PUSHS A emits55h and decodes for both DD values", push.Success && push.Image[0x100] == 0x55
            && Decoder.Decode(false, i => i == 0 ? (byte)0x55 : (byte)0xFF)?.Mnemonic == "PUSHS A"
            && Decoder.Decode(true, i => i == 0 ? (byte)0x55 : (byte)0xFF)?.Mnemonic == "PUSHS A");
    }
}