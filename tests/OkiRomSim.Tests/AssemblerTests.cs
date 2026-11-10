// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Assembler;

namespace OkiRomSim.Tests;

/// The assembler fixes: an expression or a directive that used to throw out of the assembler (taking the build, or the MCP call, with it)
/// is now an ordinary result or an error line, and the cases next to them still assemble as before.
static class AssemblerTests
{
    static AssemblyResult Text(string source)
    {
        T.P30Part();
        return new OkiAssembler(new AssemblerOptions()).AssembleText(source, Path.Combine(Path.GetTempPath(), "okirom-tests-input.asm"));
    }

    static string Errors(AssemblyResult r) => string.Join("; ", r.Diagnostics.Where(d => d.Severity == Severity.Error).Select(d => d.Message).Take(2));

    public static void Run()
    {
        // -2^31 / -1 does not fit a 32-bit int: .NET throws OverflowException for it, which is not an assembler error and was not caught
        AssemblyResult? r = null;
        Exception? thrown = null;
        try { r = Text("        ORG 1000h\n        DB ((-7FFFFFFFh - 1) / -1) & 0FFh\n        DB ((-7FFFFFFFh - 1) % -1) & 0FFh\n        DB (7 / -1) & 0FFh\n        DB (7 % -1) & 0FFh\n"); }
        catch (Exception ex) { thrown = ex; }
        T.Check("-2^31 / -1 and -2^31 % -1 assemble (wrapping, as all arithmetic here does) instead of throwing", thrown == null && r is { Success: true },
            thrown != null ? $"{thrown.GetType().Name}: {thrown.Message}" : r!.Success ? "" : Errors(r));
        if (r is { Success: true })
            T.Check("... with the values 32-bit wrapping gives: 00h, 00h, and 7 / -1 = F9h, 7 % -1 = 00h", r.Image[0x1000] == 0x00 && r.Image[0x1001] == 0x00 && r.Image[0x1002] == 0xF9 && r.Image[0x1003] == 0x00,
                $"{r.Image[0x1000]:X2} {r.Image[0x1001]:X2} {r.Image[0x1002]:X2} {r.Image[0x1003]:X2}");
        var div0 = Text("        DB 5 / 0\n");
        T.Check("division by 0 is still an error line", !div0.Success && Errors(div0).Contains("division by zero"), Errors(div0));

        // ALIGN with a value past the address space made that many bytes of padding (a gigabyte for 40000000h)
        thrown = null; r = null;
        try { r = Text("        ORG 1001h\n        ALIGN 40000000h\n        DB 1\n"); }
        catch (Exception ex) { thrown = ex; }
        T.Check("ALIGN 40000000h is an error line, not a gigabyte of padding", thrown == null && r is { Success: false } && Errors(r).Contains("align", StringComparison.OrdinalIgnoreCase),
            thrown != null ? $"{thrown.GetType().Name}: {thrown.Message}" : Errors(r!));
        var ok = Text("        ORG 1001h\n        ALIGN 100h\n        DB 0AAh\n");
        T.Check("ALIGN 100h still pads to the next 100h", ok.Success && ok.Image[0x1100] == 0xAA && ok.Image[0x10FF] == 0xFF,
            ok.Success ? $"AAh at 1100h: {ok.Image[0x1100]:X2}" : Errors(ok));
        var whole = Text("        ORG 0\n        ALIGN 10000h\n        DB 55h\n");
        T.Check("ALIGN 10000h (the whole address space) is still allowed", whole.Success && whole.Image[0] == 0x55, whole.Success ? "" : Errors(whole));
    }
}
