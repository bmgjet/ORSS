// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Core;

namespace OkiRomSim.Tests;

// OKI instruction manual 3-55/56/60/61; target hardware manual p.33 defines
// HC as carry/borrow at bit3 for both widths. PSWH arithmetic flags are undefined.
static class IncDecTests
{
    public static void Run()
    {
        T.P30Part();
        var word = new (string Name, byte[] Prefix, ushort Cycles)[]
        {
            ("er0", [0x44], 5), ("er3", [0x47], 5), ("USP", [0xA1], 5), ("SSP", [0xA0], 5),
            ("off", [0xB4, 0xC0], 7), ("direct", [0xB5, 0xC0], 7), ("[DP]", [0xB2], 7),
            ("USP indexed", [0xB3, 4], 8), ("X1 indexed", [0xB0, 6, 0], 9), ("X2 indexed", [0xB1, 6, 0], 9),
        };
        var bytes = new (string Name, byte[] Prefix, ushort Cycles)[]
        {
            ("PSWH", [0xA2], 5), ("PSWL", [0xA3], 5), ("off", [0xC4, 0xC0], 7),
            ("direct", [0xC5, 0xC0], 7), ("[DP]", [0xC2], 7), ("USP indexed", [0xC3, 4], 8),
            ("X1 indexed", [0xC0, 6, 0], 9), ("X2 indexed", [0xC1, 6, 0], 9),
        };
        foreach (bool increment in new[] { false, true })
        {
            byte operation = increment ? (byte)0x16 : (byte)0x17;
            string op = increment ? "INC" : "DEC";
            foreach (var row in word) Cost($"{op} {row.Name}", [.. row.Prefix, operation], row.Cycles);
            foreach (var row in bytes) Cost($"{op}B {row.Name}", [.. row.Prefix, operation], row.Cycles);
            for (int n = 0; n < 3; n++) Cost($"{op} pointer{n}", [(byte)((increment ? 0x70 : 0x80) + n)], 3);
            Cost($"{op} LRB", [increment ? (byte)0xFD : (byte)0xFE], 3);
            for (int n = 0; n < 8; n++) Cost($"{op}B r{n}", [(byte)((increment ? 0xA8 : 0xB8) + n)], 3);
            foreach (bool byteWidth in new[] { false, true })
            {
                bool correct = true;
                foreach (ushort value in new ushort[] { 0, 1, 0x0E, 0x0F, 0x10, 0xFF, 0x100, 0xFFFF })
                foreach (bool dd in new[] { false, true })
                foreach (bool cf in new[] { false, true })
                foreach (bool hc in new[] { false, true })
                {
                    var c = new Cpu { Pc = 0x100, Lrb = 0x40, Dd = dd, Cf = cf, Hc = hc, Zf = true };
                    var b = new Bus();
                    if (byteWidth) b.Rom[0x100] = increment ? (byte)0xA8 : (byte)0xB8;
                    else { b.Rom[0x100] = 0x44; b.Rom[0x101] = operation; }
                    b.Ram[0x200] = (byte)value; b.Ram[0x201] = byteWidth ? (byte)0xA5 : (byte)(value >> 8);
                    ExecStep.Step(c, b);
                    int mask = byteWidth ? 255 : 65535;
                    int expected = (value + (increment ? 1 : -1)) & mask;
                    int actual = b.Ram[0x200] | (byteWidth ? 0 : b.Ram[0x201] << 8);
                    correct &= actual == expected && c.Cf == cf && c.Dd == dd && c.Zf == (expected == 0)
                        && c.Hc == ((value & 15) == (increment ? 15 : 0))
                        && (!byteWidth || b.Ram[0x201] == 0xA5);
                }
                T.Check($"{op}{(byteWidth ? "B" : "")}: result, nibble HC, preserved CF/DD and byte neighbor", correct);
            }
        }
        // INC LRB preserves ZF, including word-memory aliases and its high byte.
        // The corresponding DEC row has no such exception.
        foreach (var form in new (string Name, byte[] Code, bool HighByte, bool PreserveZero)[]
        {
            ("INC LRB", [0xFD], false, true), ("INC direct LRB", [0xB5, 2, 0x16], false, true),
            ("INC [DP] alias LRB", [0xB2, 0x16], false, true), ("INCB LRB high", [0xC5, 3, 0x16], true, true),
            ("DEC LRB", [0xFE], false, false),
        })
        {
            bool correct = true;
            foreach (ushort value in new ushort[] { 0, 0xFF, 0xFF00, 0xFFFF })
            foreach (bool z in new[] { false, true })
            {
                var c = new Cpu { Pc = 0x100, Lrb = value, Zf = z, Cf = true, Dd = false };
                var b = new Bus(); form.Code.CopyTo(b.Rom, 0x100); b.WriteDataU16(0x84, 2);
                ExecStep.Step(c, b);
                ushort expected = (ushort)(value + (form.Name.StartsWith("DEC") ? -1 : form.HighByte ? 256 : 1));
                correct &= c.Lrb == expected && c.Zf == (form.PreserveZero ? z : expected == 0) && c.Cf && !c.Dd;
            }
            T.Check($"{form.Name}: documented ZF rule", correct);
        }
    }

    static void Cost(string name, byte[] bytes, ushort cycles)
    {
        bool correct = true;
        foreach (bool dd in new[] { false, true })
        {
            var d = Decoder.Decode(dd, i => i < bytes.Length ? bytes[i] : (byte)0xFF);
            correct &= d != null && d.Len == bytes.Length && d.Cycles == cycles && d.DdAfter == null;
        }
        T.Check($"{name}: documented INT cost and DD independence", correct);
    }
}