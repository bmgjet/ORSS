// Copyright (c) bmgjet. All rights reserved.
// Turns a raw 32 KB ROM image into assembler source that rebuilds to the same bytes. Code is found by following control flow from the reset, interrupt and VCAL vectors, carrying the DD (word/byte) mode along each path; unreachable bytes stay as DB data and targets get labels. Any instruction whose text won't rebuild to its original bytes is demoted to DB and re-checked.
using System.Diagnostics.CodeAnalysis;
using System.Text;
using System.Text.RegularExpressions;

namespace OkiRomSim.Core;

public sealed class BinDisassembly
{
    public string Text = "";
    /// Instructions emitted as code, and bytes left as data.
    public int CodeInstructions;
    public int DataBytes;
    /// True when the text was verified to reassemble to the original image.
    public bool RoundTrips;
    public string Note = "";
}

public static class BinDisassembler
{
    /// Names for the 4 fixed vectors and the 16 maskable-interrupt vectors (IRQ/IE bit order), then the 8 VCAL vectors. The MSM66207 names; ProcessorProfile.Apply swaps in another part's.
    public static readonly string[] DefaultVectorNames =
    {
        "int_start", "int_break", "int_WDT", "int_NMI",
        "int_INT0", "int_serial_rx", "int_serial_tx", "int_irq3",
        "int_timer_0_overflow", "int_timer_0", "int_timer_1_overflow", "int_timer_1",
        "int_timer_2_overflow", "int_timer_2", "int_timer_3_overflow", "int_timer_3",
        "int_adc", "int_PWM", "int_irq14", "int_INT1",
        "vcal_0", "vcal_1", "vcal_2", "vcal_3", "vcal_4", "vcal_5", "vcal_6", "vcal_7",
    };
    static string[] VectorNames = DefaultVectorNames;
    const int VectorTableEnd = 0x38;

    /// Vector names (4 fixed, 16 maskable in IRQ bit order, 8 VCAL) and SFR names for another 66K part; null puts the MSM66207 ones back.
    public static void UseNames(IReadOnlyList<string>? vectors)
    {
        VectorNames = vectors is { Count: VectorTableEnd / 2 } ? [.. vectors] : DefaultVectorNames;
        SfrNames = null;
    }

    sealed class Insn
    {
        public int Addr;
        public Decoded D = null!;
        public bool Dd;
        public bool Demoted;
    }

    /// Disassemble `rom`. `assemble` rebuilds text to an image (null on failure) with any failing line numbers; it is used to verify and repair the output. Pass null to skip verification.
    public static BinDisassembly Disassemble(byte[] rom, string title,
        Func<string, (byte[]? image, IEnumerable<int> badLines)>? assemble = null)
    {
        var image = new byte[Bus.RomSize];
        Array.Fill(image, (byte)0xFF);
        Array.Copy(rom, image, Math.Min(rom.Length, Bus.RomSize));

        var insns = new SortedDictionary<int, Insn>();
        var owner = new int[Bus.RomSize];          // address -> start of the instruction covering it, or -1
        Array.Fill(owner, -1);
        var labels = new Dictionary<int, string>();
        var work = new Stack<(int addr, bool dd)>();

        // Vector tables: DW entries pointing at handlers.
        for (int v = 0; v < VectorTableEnd / 2; v++)
        {
            int target = image[v * 2] | (image[(v * 2) + 1] << 8);
            if (target < VectorTableEnd || target >= Bus.RomSize) continue;
            labels.TryAdd(target, VectorNames[v]);
            // Reset starts with PSW cleared (DD=0); handlers inherit whatever was running, and nearly all open with a word load, so try DD=1.
            work.Push((target, v != 0));
        }

        while (work.Count > 0)
        {
            var (start, ddIn) = work.Pop();
            int pc = start; bool dd = ddIn;
            while (pc >= VectorTableEnd && pc < Bus.RomSize)
            {
                if (owner[pc] == pc) break;          // already decoded from here
                if (owner[pc] >= 0) break;           // lands inside another instruction
                int at = pc;
                var d = Decoder.Decode(dd, i => at + i < Bus.RomSize ? image[at + i] : (byte)0xFF);
                if (d == null || at + d.Len > Bus.RomSize) break;
                bool overlaps = false;
                for (int i = 0; i < d.Len; i++) if (owner[at + i] >= 0) { overlaps = true; break; }
                if (overlaps) break;
                for (int i = 0; i < d.Len; i++) owner[at + i] = at;
                insns[at] = new Insn { Addr = at, D = d, Dd = dd };
                if (d.DdAfter is bool v) dd = v;
                int next = at + d.Len;

                string op = Op(d.Mnemonic);
                int? target = Target(d, next);
                if (target is int t && t >= VectorTableEnd && t < Bus.RomSize)
                {
                    labels.TryAdd(t, (op is "CAL" or "SCAL" ? "sub_" : "loc_") + t.ToString("X4"));
                    work.Push((t, dd));
                }
                if (op is "J" or "SJ" or "RT" or "RTI" or "BRK" || IsIndirectJump(d)) break;
                pc = next;
            }
        }

        // Assemble, then demote anything that does not rebuild identically.
        var result = new BinDisassembly();
        for (int attempt = 0; attempt < 12; attempt++)
        {
            var (text, lineToInsn) = Emit(image, insns, labels, title);
            result.Text = text;
            if (assemble == null) { result.Note = "not verified"; break; }
            var (built, badLines) = assemble(text);
            var bad = new HashSet<int>();
            foreach (var line in badLines)
                if (lineToInsn.TryGetValue(line, out var a)) bad.Add(a);
            if (built != null)
                for (int i = 0; i < Bus.RomSize; i++)
                    if (built[i] != image[i] && owner[i] >= 0) bad.Add(owner[i]);
            if (built != null && bad.Count == 0 && built.AsSpan().SequenceEqual(image))
            {
                result.RoundTrips = true;
                break;
            }
            if (bad.Count == 0)
            {
                // Mismatch we cannot attribute to an instruction: give up on code.
                foreach (var ins in insns.Values) ins.Demoted = true;
                result.Note = "output did not rebuild; emitted as data";
                continue;
            }
            foreach (var a in bad)
                if (insns.TryGetValue(a, out var ins)) ins.Demoted = true;
            // A demoted branch target keeps its label but loses nothing else.
        }
        result.CodeInstructions = insns.Values.Count(i => !i.Demoted);
        result.DataBytes = Bus.RomSize - insns.Values.Where(i => !i.Demoted).Sum(i => i.D.Len);
        return result;
    }

    static string Op(string mnemonic)
    {
        int sp = mnemonic.IndexOf(' ');
        return sp < 0 ? mnemonic : mnemonic[..sp];
    }

    static bool IsIndirectJump(Decoded d) => Op(d.Mnemonic) == "J" && d.Mnemonic.Contains('[');

    /// Branch/jump/call destination, if the instruction has a fixed one.
    static int? Target(Decoded d, int pcAfter)
    {
        if (d.Mnemonic.Contains("rel8")) return (ushort)(pcAfter + d.Fields.Rel8);
        return d.Mnemonic.Contains("addr16") ? d.Fields.Addr16 : null;
    }

    static (string text, Dictionary<int, int> lineToInsn) Emit(byte[] image,
        SortedDictionary<int, Insn> insns, Dictionary<int, string> labels, string title)
    {
        var sb = new StringBuilder();
        var lineToInsn = new Dictionary<int, int>();
        int line = 0;
        void Line(string s) { sb.Append(s).Append('\n'); line++; }

        Line($"; {title}");
        Line(";");
        Line("; Disassembled by OkiRomSim from a raw ROM image. Code was found by following");
        Line("; control flow from the reset, interrupt and VCAL vectors; everything that flow");
        Line("; never reached (tables, calibration data, unused space) is kept as DB bytes.");
        Line("; Assembling this file reproduces the original image byte for byte.");
        Line("");
        Line("                org 0000h");

        // Vector table.
        for (int v = 0; v < VectorTableEnd / 2; v++)
        {
            int target = image[v * 2] | (image[(v * 2) + 1] << 8);
            string name = labels.TryGetValue(target, out var n) && n == VectorNames[v] ? n : $"0{target:X4}h";
            if (labels.TryGetValue(target, out var any) && (target >= VectorTableEnd)) name = any;
            Line($"{VectorNames[v] + "_vec:",-26}DW  {name}");
        }

        int pc = VectorTableEnd;
        var data = new List<byte>();
        int dataStart = pc;
        void FlushData()
        {
            for (int i = 0; i < data.Count; i += 8)
            {
                var chunk = data.Skip(i).Take(8).Select(b => $"0{b:X2}h");
                Line($"                DB  {string.Join(",", chunk)} ; {dataStart + i:X4}");
            }
            data.Clear();
        }

        while (pc < Bus.RomSize)
        {
            bool isCode = insns.TryGetValue(pc, out var ins) && !ins.Demoted;
            if (labels.TryGetValue(pc, out var label) || isCode)
            {
                FlushData();
                if (label != null) Line($"{label}:");
            }
            if (isCode)
            {
                string text = Syntax(Decoder.Format(ins!.D, (ushort)(pc + ins.D.Len)), ins.D, pc + ins.D.Len, labels);
                string hex = string.Concat(Enumerable.Range(0, ins.D.Len).Select(i => image[pc + i].ToString("X2")));
                lineToInsn[line + 1] = pc;
                Line($"                {text,-36}; {pc:X4} {(ins.Dd ? 1 : 0)} {hex}");
                pc += ins.D.Len;
                dataStart = pc;
            }
            else
            {
                if (data.Count == 0) dataStart = pc;
                data.Add(image[pc]);
                pc++;
                if (data.Count == 64) { FlushData(); dataStart = pc; }
            }
        }
        FlushData();
        return (sb.ToString(), lineToInsn);
    }

    static readonly Regex OffDirect = new(@"\boff (0[0-9A-F]+h)", RegexOptions.Compiled);
    static readonly Regex Hex4 = new(@"\b0([0-9A-F]{4})h\b", RegexOptions.Compiled);

    [AllowNull]
    static Dictionary<int, string> SfrNames { get => field ??= OkiRomSim.Assembler.OkiAssembler.Sfrs
        .Where(kv => !kv.Key.StartsWith("zp_", StringComparison.Ordinal))
        .GroupBy(kv => kv.Value).ToDictionary(g => g.Key, g => g.First().Key); set;
    }
    /// A plain two-digit direct address operand (not an immediate, not an off() page offset, not an index displacement).
    static readonly Regex DirectSfr = new(@"(?<![#(\w])0([0-9A-F]{2})h(?![\w\[])", RegexOptions.Compiled);

    /// Decoder text -> assembler syntax: "off 024h" -> "off(024h)", SFR addresses -> their names, branch and call targets -> labels.
    static string Syntax(string text, Decoded d, int pcAfter, Dictionary<int, string> labels)
    {
        text = OffDirect.Replace(text, "off($1)");
        text = DirectSfr.Replace(text, m =>
        {
            int a = Convert.ToInt32(m.Groups[1].Value, 16);
            return a < 0x80 && SfrNames.TryGetValue(a, out var n) ? n : m.Value;
        });
        if (Target(d, pcAfter) is int t && labels.TryGetValue(t, out var name))
            text = Hex4.Replace(text, m => Convert.ToInt32(m.Groups[1].Value, 16) == t ? name : m.Value, 1);
        return text;
    }
}
