// Copyright (c) bmgjet. All rights reserved. Assembles .asm source for the simulator. Uses the managed OkiRomSim.Assembler, driven by the OKI 66207 grammar, so it needs nothing to install and behaves the same on Windows, Linux and macOS (x64 and ARM).
using OkiRomSim.Assembler;

namespace OkiRomSim.Core;

public sealed class AssemblerException : Exception
{
    public AssemblerException(string message) : base(message) { }
}

public static class AsmAssembler
{
    /// Always true; the managed assembler needs nothing external to run.
    public static bool IsAvailable => true;

    public static byte[] Assemble(string asmPath) => Assemble(asmPath, out _);

    /// Assemble a file. Throws AssemblerException listing every error. Undefined symbols are errors here rather than silently resolving to 0.
    public static byte[] Assemble(string asmPath, out IReadOnlyDictionary<string, ushort>? symbols)
    {
        var r = new OkiAssembler().AssembleFile(asmPath);
        if (!r.Success)
            throw new AssemblerException(string.Join(Environment.NewLine,
                r.Diagnostics.Where(d => d.Severity == Severity.Error).Take(50)));
        // labels/equates plus the built-in SFR names
        symbols = r.Symbols.Values.ToDictionary(s => s.Name, s => (ushort)s.Value);
        return r.Image;
    }
}
