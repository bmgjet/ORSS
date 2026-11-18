// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Core;

namespace OkiRomSim.Tests;

// Independently transcribed byte/cycle rows from OKI chapter 3, printed
// 3-35, 3-36, 3-69, 3-77, 3-82, 3-113 and 3-127. INT operands/stack only.
// External accesses, wait states and interrupt entry are not qualified here.
static class CpuTimingTests
{
    public static void Run()
    {
        T.P30Part();
        var vectors = new (string Name, byte[] Bytes, ushort Cycles)[]
        {
            ("CMP A,er0", [0x48],3), ("CMP A,er3", [0x4B],3),
            ("CMP A,#1234h",[0xC6,0x34,0x12],6),
            ("CMP A,DP",[0x92,0xC2],4), ("CMP A,LRB",[0xA4,0xC2],4),
            ("CMP A,off C4h",[0xC7,0xC4],4), ("CMP A,C4h",[0xB5,0xC4,0xC2],6),
            ("CMP A,[DP]",[0xB2,0xC2],6), ("CMP A,4[USP]",[0xB3,4,0xC2],7),
            ("CMP A,6[X1]",[0xB0,6,0,0xC2],8), ("CMP A,6[X2]",[0xB1,6,0,0xC2],8),
            ("CMP er2,A",[0x46,0xC1],5), ("CMP DP,A",[0x92,0xC1],5),
            ("CMP off C4h,A",[0xB4,0xC4,0xC1],7), ("CMP C4h,A",[0xB5,0xC4,0xC1],7),
            ("CMP [DP],A",[0xB2,0xC1],7), ("CMP 4[USP],A",[0xB3,4,0xC1],8),
            ("CMP 6[X1],A",[0xB0,6,0,0xC1],9), ("CMP 6[X2],A",[0xB1,6,0,0xC1],9),
            ("L A,#1234h",[0x67,0x34,0x12],6), ("L A,er2",[0x36],2),
            ("L A,DP",[0x42],2), ("L A,off C4h",[0xE4,0xC4],4),
            ("L A,C4h",[0xE5,0xC4],4), ("L A,[DP]",[0xE2],4),
            ("L A,4[USP]",[0xE3,4],5), ("L A,6[X1]",[0xE0,6,0],6),
            ("L A,6[X2]",[0xE1,6,0],6),
            ("MB C,r1.3",[0x21,0x2B],5), ("MB C,PSWH.3",[0xA2,0x2B],5),
            ("MB C,off C4h.3",[0xC4,0xC4,0x2B],7), ("MB C,C4h.3",[0xC5,0xC4,0x2B],7),
            ("MB C,[DP].3",[0xC2,0x2B],7), ("MB C,4[USP].3",[0xC3,4,0x2B],8),
            ("MB C,6[X1].3",[0xC0,6,0,0x2B],9), ("MB C,6[X2].3",[0xC1,6,0,0x2B],9),
            ("SB r1.0",[0x21,0x18],7), ("SB PSWH.0",[0xA2,0x18],7),
            ("SB off C4h.0",[0xC4,0xC4,0x18],9), ("SB C4h.0",[0xC5,0xC4,0x18],9),
            ("SB [DP].0",[0xC2,0x18],9), ("SB 4[USP].0",[0xC3,4,0x18],10),
            ("SB 6[X1].0",[0xC0,6,0,0x18],11), ("SB 6[X2].0",[0xC1,6,0,0x18],11),
            ("MOV DP,A",[0x52],2), ("MOV DP,#1234h",[0x62,0x34,0x12],6),
            ("MOV DP,er2",[0x46,0x7A],4), ("MOV DP,X1",[0x90,0x7A],4),
            ("MOV DP,off C4h",[0xB4,0xC4,0x7A],6), ("MOV DP,C4h",[0xB5,0xC4,0x7A],6),
            ("MOV DP,[DP]",[0xB2,0x7A],6), ("MOV DP,4[USP]",[0xB3,4,0x7A],7),
            ("MOV DP,6[X1]",[0xB0,6,0,0x7A],8), ("MOV DP,6[X2]",[0xB1,6,0,0x7A],8),
        };
        foreach(var v in vectors)
        {
            var c = new Cpu { Pc=0x100, Dd=true, Lrb=0x14, A=2 };
            var b = new Bus();
            v.Bytes.CopyTo(b.Rom,0x100);
            b.WriteDataU16(0x80,0x300); b.WriteDataU16(0x82,0x320);
            b.WriteDataU16(0x84,0x280); b.WriteDataU16(0x86,0x340);
            b.WriteDataU16(0x280,2); b.WriteDataU16(0xC4,2); b.WriteDataU16(0xA4,2);
            var d = ExecStep.Step(c,b);
            T.Check($"{v.Name} documented INT cost",d.Cycles==v.Cycles && c.Cycles==v.Cycles,
                $"decoded/executed {d.Cycles}/{c.Cycles}, manual {v.Cycles}");
        }
        foreach(bool dd in new[]{false,true})
        {
            var c = new Cpu { Pc=0x100, Dd=dd, A=0xABCD, Ssp=0x400, Cf=true, Hc=true, Zf=true };
            var b = new Bus(); b.Rom[0x100]=0x55;
            ushort before=c.PswU16();
            var d=ExecStep.Step(c,b);
            T.Check($"PUSHS A is word-wide, DD-independent and preserves flags (DD={dd})",
                c.Ssp==0x3FE && b.ReadDataU16(0x400)==0xABCD && c.PswU16()==before && d.Cycles==3 && c.Cycles==3);
        }
    }
}
