// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Core;

namespace OkiRomSim.Tests;

// Manufacturer internal-memory operation rows. The expected numbers
// are transcribed independently from the scanned tables, not Decoder.IntCycles.
// These are instruction-level checks; they do not model intra-instruction SFR phases.
static class TimingCloseoutTests
{
    public static void Run()
    {
        T.P30Part();
        var vectors = new (string Name, bool Dd, byte[] Bytes, ushort Cost)[]
        {
            ("RB register",true,[0x21,0x08],7),
            ("RB off",true,[0xC4,0xC4,0x08],9),
            ("RB direct",true,[0xC5,0xC4,0x08],9),
            ("RB DP indirect",true,[0xC2,0x08],9),
            ("RB USP indexed",true,[0xC3,4,0x08],10),
            ("RB X1 indexed",true,[0xC0,6,0,0x08],11),
            ("RB X2 indexed",true,[0xC1,6,0,0x08],11),
            ("MB register from C",true,[0x21,0x38],10),
            ("MB off from C",true,[0xC4,0xC4,0x38],12),
            ("MB direct from C",true,[0xC5,0xC4,0x38],12),
            ("MB DP indirect from C",true,[0xC2,0x38],12),
            ("MB USP indexed from C",true,[0xC3,4,0x38],13),
            ("MB X1 indexed from C",true,[0xC0,6,0,0x38],14),
            ("MB X2 indexed from C",true,[0xC1,6,0,0x38],14),
            ("LB register",true,[0x7A],2),
            ("LB immediate",true,[0x77,2],4),
            ("LB off",true,[0xF4,0xC4],4),
            ("LB direct",true,[0xF5,0xC4],4),
            ("LB DP indirect",true,[0xF2],4),
            ("LB USP indexed",true,[0xF3,4],5),
            ("LB X1 indexed",true,[0xF0,6,0],6),
            ("LB X2 indexed",true,[0xF1,6,0],6),
            ("ST register",true,[0x8A],2),
            ("ST off",true,[0xD4,0xC4],4),
            ("ST direct",true,[0xD5,0xC4],4),
            ("ST DP indirect",true,[0xD2],4),
            ("ST USP indexed",true,[0xD3,4],5),
            ("ST X1 indexed",true,[0xD0,6,0],6),
            ("ST X2 indexed",true,[0xD1,6,0],6),
            ("ADD register",true,[0x0A],3),
            ("ADD immediate",true,[0x86,1,0],6),
            ("ADD off",true,[0x87,0xC4],4),
            ("ADD direct",true,[0xB5,0xC4,0x82],6),
            ("ADD DP indirect",true,[0xB2,0x82],6),
            ("ADD USP indexed",true,[0xB3,4,0x82],7),
            ("ADD X1 indexed",true,[0xB0,6,0,0x82],8),
            ("SUB register",true,[0x2A],3),
            ("SUB immediate",true,[0xA6,1,0],6),
            ("SUB off",true,[0xA7,0xC4],4),
            ("SUB direct",true,[0xB5,0xC4,0xA2],6),
            ("SUB DP indirect",true,[0xB2,0xA2],6),
            ("SUB USP indexed",true,[0xB3,4,0xA2],7),
            ("SUB X2 indexed",true,[0xB1,6,0,0xA2],8),
            ("CMPB register",false,[0x48],3),
            ("CMPB immediate",false,[0xC6,1],4),
            ("CMPB off",false,[0xC7,0xC4],4),
            ("CMPB direct",false,[0xC5,0xC4,0xC2],6),
            ("CMPB DP indirect",false,[0xC2,0xC2],6),
            ("CMPB USP indexed",false,[0xC3,4,0xC2],7),
            ("CMPB X1 indexed",false,[0xC0,6,0,0xC2],8),
            // Printed p.3-40: reverse byte comparison has its own cost row.
            ("CMPB register from A",true,[0x21,0xC1],5),
            ("CMPB off from A",true,[0xC4,0xC4,0xC1],7),
            ("CMPB direct from A",true,[0xC5,0xC4,0xC1],7),
            ("CMPB DP indirect from A",true,[0xC2,0xC1],7),
            ("CMPB USP indexed from A",true,[0xC3,4,0xC1],8),
            ("CMPB X1 indexed from A",true,[0xC0,6,0,0xC1],9),
            ("CMPB X2 indexed from A",true,[0xC1,6,0,0xC1],9),
            // Printed pp.3-72/159: fixed-width code-load and reverse-comparison forms.
            ("LC DP code indirect",true,[0x92,0xA8],11),
            ("SUB DP immediate",false,[0x92,0xA0,6,0],8),
            ("ADDB register",false,[0x08],3),
            ("ADDB immediate",false,[0x86,1],4),
            ("ADDB off",false,[0x87,0xC4],4),
            ("ADDB direct",false,[0xC5,0xC4,0x82],6),
            ("ADDB DP indirect",false,[0xC2,0x82],6),
            ("ADDB USP indexed",false,[0xC3,4,0x82],7),
            ("ADDB X2 indexed",false,[0xC1,6,0,0x82],8),
            ("MOV LRB immediate",false,[0x57,0x14,0],6),
            ("MOV LRB indirect",false,[0xB2,0x7F],6),
            ("MOV off from er3",false,[0x47,0x7C,0xC4],6),
            ("MOV off from off",false,[0xB4,0xA4,0x7C,0xC4],8),
            ("MOV off from DP indirect",false,[0xB2,0x7C,0xC4],8),
            ("MOV off from USP indexed",false,[0xB3,4,0x7C,0xC4],9),
        };
        foreach(var v in vectors) CheckCost(v.Name,v.Dd,v.Bytes,v.Cost);
        foreach(byte code in new byte[]{0xD0,0xE0})
        {
            string op=code==0xD0 ? "ANDB" : "ORB";
            CheckCost(op+" register immediate",true,[0x21,code,1],6);
            CheckCost(op+" PSWH immediate",true,[0xA2,code,1],6);
            CheckCost(op+" off immediate",true,[0xC4,0xC4,code,1],8);
            CheckCost(op+" direct immediate",true,[0xC5,0xC4,code,1],8);
            CheckCost(op+" DP indirect immediate",true,[0xC2,code,1],8);
            CheckCost(op+" USP indexed immediate",true,[0xC3,4,code,1],9);
            CheckCost(op+" X1 indexed immediate",true,[0xC0,6,0,code,1],10);
            CheckCost(op+" X2 indexed immediate",true,[0xC1,6,0,code,1],10);
        }
        ComparePreservesHalfCarry();
        BranchAndFlags();
        InterruptFrame();
    }

    static void CheckCost(string name,bool dd,byte[] bytes,ushort expected)
    {
        var c=new Cpu{Pc=0x100,Dd=dd,Lrb=0x14,A=2}; var b=new Bus();
        bytes.CopyTo(b.Rom,0x100);
        b.WriteDataU16(0x80,0x300); b.WriteDataU16(0x82,0x320);
        b.WriteDataU16(0x84,0x280); b.WriteDataU16(0x86,0x340);
        b.WriteDataU16(0x280,2); b.WriteDataU16(0xC4,2); b.WriteDataU16(0xA4,2);
        var d=ExecStep.Step(c,b);
        T.Check(name+" manual INT cost",d.Cycles==expected && c.Cycles==expected,
            $"decoded/executed {d.Cycles}/{c.Cycles}; manual {expected}");
    }

    // Printed pp.3-35/39/40/42/43/46: compare changes ZF/CF, not HC.
    // Initial HC is varied independently of the mathematical half-borrow.
    static void ComparePreservesHalfCarry()
    {
        var forms = new (string Name, bool Dd, byte[] Bytes, bool Reverse)[]
        {
            ("CMP immediate",true,[0xC6,1,0],false),
            ("CMPB immediate",false,[0xC6,1],false),
            ("CMP direct from A",false,[0xB5,0xC4,0xC1],true),
            ("CMPB direct from A",true,[0xC5,0xC4,0xC1],true),
            ("CMPC direct",false,[0x90,0x9E,0,3],false),
            ("CMPCB direct",true,[0x90,0x9F,0,3],false),
        };
        foreach(var f in forms) foreach(bool hc in new[]{false,true})
        foreach(ushort value in new ushort[]{0,1,0x10,0x11})
        {
            var c=new Cpu{Pc=0x100,Dd=f.Dd,A=f.Reverse?(ushort)1:value,Hc=hc,Cf=!hc,Zf=hc};
            var b=new Bus();f.Bytes.CopyTo(b.Rom,0x100);b.Rom[0x300]=1;b.Rom[0x301]=0;
            b.WriteDataU16(0xC4,value);ushort a=c.A;
            ExecStep.Step(c,b);
            T.Check($"{f.Name} value={value:X2}, initial HC={hc}: preserves HC/DD/A and compares",
                c.Hc==hc && c.Dd==f.Dd && c.A==a && c.Cf==(value<1) && c.Zf==(value==1));
        }
    }

    static void BranchAndFlags()
    {
        foreach(bool dd in new[]{false,true}) foreach(bool set in new[]{false,true})
        foreach(bool testSet in new[]{false,true})
        {
            var c=new Cpu{Pc=0x100,Dd=dd,Lrb=0x14,Cf=true,Hc=true,Zf=true}; var b=new Bus();
            b.Rom[0x100]=(byte)(testSet ? 0xE8:0xD8); b.Rom[0x101]=0xE6; b.Rom[0x102]=3;
            b.WriteDataU8(0xE6,(byte)(set?1:0)); ushort psw=c.PswU16();
            ExecStep.Step(c,b); bool taken=set==testSet;
            T.Check($"J{(testSet?"BS":"BR")} DD={dd}, bit={set} branch/cost/flags",
                c.Pc==(taken?0x106:0x103) && c.Cycles==(taken?10UL:6UL) && c.PswU16()==psw);
        }
        foreach(bool old in new[]{false,true}) foreach(bool set in new[]{false,true})
        {
            var c=new Cpu{Pc=0x100,Dd=true,Cf=true,Hc=true}; var b=new Bus();
            new byte[]{0xC5,0xE6,(byte)(set?0x18:0x08)}.CopyTo(b.Rom,0x100);
            b.WriteDataU8(0xE6,(byte)(0xA0|(old?1:0))); ExecStep.Step(c,b);
            T.Check($"{(set?"SB":"RB")} old bit {old}: prior-bit ZF, other bits, CF/HC/DD",
                c.Zf==!old && c.Cf && c.Hc && c.Dd && b.ReadDataU8(0xE6)==(0xA0|(set?1:0)));
        }
    }

    static void InterruptFrame()
    {
        var c=new Cpu{Pc=0x2222,A=0xBEEF,Lrb=0x14,Ssp=0x27E,Dd=false,Cf=true,Hc=true,Zf=true};
        c.SetMie(true); var b=new Bus(); b.WriteDataU16(Bus.SfrIe,0x800);
        b.Rom[0x1E]=0; b.Rom[0x1F]=1; b.Rom[0x100]=2;
        ushort psw=c.PswU16(); bool entered=InterruptController.HandlePendingInterrupts(c,b,0x800);
        T.Check("IRQ frame preserves A/LRB/DD and stacks PC,A,LRB,PSW; disables MIE",
            entered && c.Pc==0x100 && c.Ssp==0x276 && c.A==0xBEEF && c.Lrb==0x14 && !c.Dd && !c.Mie()
            && b.ReadDataU16(0x27E)==0x2222 && b.ReadDataU16(0x27C)==0xBEEF
            && b.ReadDataU16(0x27A)==0x14 && b.ReadDataU16(0x278)==psw);
        ulong before=c.Cycles; ExecStep.Step(c,b);
        T.Check("RTI restores saved state and consumes 15 internal-stack cycles",
            c.Pc==0x2222 && c.A==0xBEEF && c.Lrb==0x14 && c.Ssp==0x27E && c.PswU16()==psw && c.Cycles-before==15);
    }
}
