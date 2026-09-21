// Human-readable descriptions of each mnemonic Exec.cs implements, plus a
// search helper over FullOpcodes.Table -- for the App's "Insert Instruction"
// dialog and any future hover-help/tooltip feature. Descriptions are keyed
// by the *base* mnemonic (byte-width "B" suffix stripped the same way
// OperandParser.IsByteVariant does): ADD and ADDB share one description,
// annotated with "(byte form: ...)" where the distinction matters.

namespace OkiRomSim.Core;

public static class InstructionInfo
{
    /// One line per base mnemonic. Not exhaustive ISA documentation -- just enough to remind you what an instruction does while browsing/inserting it, without needing the MSM66201/66207 manual open alongside.
    public static readonly IReadOnlyDictionary<string, string> Descriptions = new Dictionary<string, string>
    {
        ["NOP"] = "No operation. Does nothing for one instruction's worth of cycles.",
        ["L"] = "Load: copy the source operand into the destination. Byte form LB loads 8 bits.",
        ["MOV"] = "Move: copy the source operand into the destination (alias family of L/ST for register-like destinations). MOVB moves a byte.",
        ["ST"] = "Store: copy the source operand into the destination memory location. STB stores a byte.",
        ["LC"] = "Load from Code space: read a byte/word from ROM (code memory) instead of RAM, into the destination.",
        ["XCHG"] = "Exchange the two operands' values with each other.",
        ["CLR"] = "Clear: set the destination to zero.",
        ["ADD"] = "Add the source to the destination, storing the result in the destination. Sets carry on unsigned overflow, zero flag on a zero result. ADDB is the byte form.",
        ["ADC"] = "Add with carry: like ADD, but also adds the current carry flag in (for multi-word/byte addition chains).",
        ["SUB"] = "Subtract the source from the destination. Carry is set on borrow (unsigned underflow), i.e. CF=1 means destination < source. SUBB is the byte form.",
        ["SBC"] = "Subtract with borrow: like SUB, but also subtracts the current carry (borrow) flag.",
        ["CMP"] = "Compare: computes destination - source to set flags (carry/zero) without storing the result. Use JLT/JGE/JGT/JLE afterward to branch on it.",
        ["CMPC"] = "Compare against code space: like CMP, but the source is read from ROM instead of RAM.",
        ["AND"] = "Bitwise AND the source into the destination, storing the result and updating the zero flag.",
        ["OR"] = "Bitwise OR the source into the destination, storing the result and updating the zero flag.",
        ["XOR"] = "Bitwise XOR the source into the destination, storing the result and updating the zero flag.",
        ["INC"] = "Increment the operand by 1 and update the zero flag.",
        ["DEC"] = "Decrement the operand by 1 and update the zero flag.",
        ["MUL"] = "Multiply. Word form: (er1,A) <- A * er0 (32-bit result). Byte form MULB: A <- AL * r0 (16-bit result).",
        ["DIV"] = "Divide. Word form: (er0,A) <- (er0,A) / er2, with the remainder left in er1. Byte form DIVB: A <- A / r0, remainder in r1. Sets carry on divide-by-zero instead of dividing.",
        ["EXTND"] = "Sign-extend the low byte of the accumulator across the full 16-bit accumulator.",
        ["SWAP"] = "Swap halves of the accumulator: the two bytes in word mode, or the two nibbles of the low byte in byte mode (SWAPB).",
        ["ROL"] = "Rotate the operand left through the bit width, carry flag receives the bit rotated out the top.",
        ["ROR"] = "Rotate the operand right through the bit width, carry flag receives the bit rotated out the bottom.",
        ["SLL"] = "Shift the operand left by one bit, filling with 0; carry flag receives the bit shifted out the top.",
        ["SRL"] = "Shift the operand right by one bit (logical, fills with 0); carry flag receives the bit shifted out the bottom.",
        ["SRA"] = "Shift the operand right by one bit, arithmetic (keeps the sign bit); carry flag receives the bit shifted out the bottom.",
        ["SC"] = "Set the carry flag to 1.",
        ["RC"] = "Reset (clear) the carry flag to 0.",
        ["SB"] = "Set the addressed bit to 1. Zero flag reports whether the bit was previously 0.",
        ["RB"] = "Reset (clear) the addressed bit to 0. Zero flag reports whether the bit was previously 0.",
        ["MB"] = "Move a bit: copies a single bit between the carry flag and a bit-addressed operand (direction depends on which side is C).",
        ["MBR"] = "Move bit, register-indirect: like MB, but the bit index comes from A's low 3 bits instead of the encoding.",
        ["SBR"] = "Set bit, register-indirect: sets the bit selected by A's low 3 bits in the operand byte.",
        ["RBR"] = "Reset bit, register-indirect: clears the bit selected by A's low 3 bits in the operand byte.",
        ["TBR"] = "Test bit, register-indirect: sets the zero flag from the bit selected by A's low 3 bits, without modifying it.",
        ["PUSHS"] = "Push the operand onto the system stack (SSP), predecrementing SSP.",
        ["POPS"] = "Pop the top of the system stack (SSP) into the operand, postincrementing SSP.",
        ["PUSHU"] = "Push the operand onto the user stack (USP), predecrementing USP.",
        ["J"] = "Unconditional jump to the given address (absolute, or via a register/memory operand).",
        ["SJ"] = "Short jump: unconditional jump via an 8-bit signed relative offset from the next instruction.",
        ["CAL"] = "Call a subroutine at the given address, pushing the return address onto the system stack.",
        ["SCAL"] = "Short call: like CAL, but the target is an 8-bit signed relative offset (more compact encoding).",
        ["VCAL"] = "Vector call: call through the fixed vector table at 0x0028, indexed by the operand (a small integer 'vector number').",
        ["RT"] = "Return from subroutine: pop the return address off the system stack into PC.",
        ["RTI"] = "Return from interrupt: restores PC, accumulator, LRB and PSW from the system stack (the reverse of the hardware interrupt-entry sequence) and re-enables interrupts per the restored PSW.",
        ["JEQ"] = "Jump if equal (zero flag set) -- branch on the result of a preceding CMP/arithmetic op being zero.",
        ["JNE"] = "Jump if not equal (zero flag clear).",
        ["JLT"] = "Jump if less than, unsigned (carry flag set, i.e. the previous CMP/SUB borrowed).",
        ["JGE"] = "Jump if greater than or equal, unsigned (carry flag clear).",
        ["JGT"] = "Jump if greater than, unsigned (carry clear AND zero clear).",
        ["JLE"] = "Jump if less than or equal, unsigned (carry set OR zero set).",
        ["JBS"] = "Jump if bit set: branch (relative) if the addressed bit is 1.",
        ["JBR"] = "Jump if bit reset: branch (relative) if the addressed bit is 0.",
        ["JRNZ"] = "Decrement the given register, then branch (relative) if it's still nonzero -- a compact counted-loop instruction.",
        ["BRK"] = "Software breakpoint/trap: pushes PSW and PC onto the system stack and jumps through the BRK vector at 0x0002, like a forced interrupt. Often used deliberately by firmware for a self-test-failure trap.",
        ["DAA"] = "Decimal-adjust the accumulator after an addition, correcting it to valid packed-BCD.",
        ["DAS"] = "Decimal-adjust the accumulator after a subtraction, correcting it to valid packed-BCD.",
        ["XNBL"] = "Exchange nibbles: swaps the low nibble of the accumulator's low byte with the low nibble of a memory byte, keeping each operand's high nibble in place.",
        ["SMOVI"] = "String move with increment: copies one byte from [DP] to [X1], then increments both DP and X1 -- used in a loop to block-copy memory.",
    };

    /// Best-effort description lookup: tries the mnemonic as given, then with a trailing "B" stripped (the byte-width variant naming pattern).
    public static string? Describe(string mnemonic)
    {
        if (Descriptions.TryGetValue(mnemonic, out var d)) return d;
        if (mnemonic.Length > 1 && mnemonic.EndsWith('B') &&
            Descriptions.TryGetValue(mnemonic[..^1], out var d2))
        {
            return d2;
        }
        return null;
    }

    /// One row for the Insert Instruction picker: an addressing-mode form from FullOpcodes.Table, with its description resolved.
    public readonly struct SearchResult
    {
        public int Index { get; }
        public string Syntax { get; }
        public string? Description { get; }
        public SearchResult(int index, string syntax, string? description)
        {
            Index = index; Syntax = syntax; Description = description;
        }
    }

    /// Search FullOpcodes.Table for entries whose mnemonic text contains
    /// `query` (case-insensitive), or return every entry for an empty query.
    /// Ordered by base mnemonic then by syntax text, so every addressing
    /// form of e.g. "ADD" sorts together instead of scattered by table index.
    public static IEnumerable<SearchResult> Search(string query)
    {
        var q = query.Trim();
        var table = FullOpcodes.Table;
        var results = new List<SearchResult>(table.Length);
        for (int i = 0; i < table.Length; i++)
        {
            var syntax = table[i].Mnemonic;
            if (q.Length == 0 || syntax.Contains(q, StringComparison.OrdinalIgnoreCase))
            {
                string baseOp = syntax.Split(' ', ',')[0];
                results.Add(new SearchResult(i, syntax, Describe(baseOp)));
            }
        }
        return results.OrderBy(r => r.Syntax.Split(' ', ',')[0], StringComparer.Ordinal)
                       .ThenBy(r => r.Syntax, StringComparer.Ordinal);
    }
}
