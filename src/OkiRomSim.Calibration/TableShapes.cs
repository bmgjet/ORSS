// Copyright (c) bmgjet. All rights reserved.
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Core;

namespace OkiRomSim.Calibration;

/// A table's layout read from the code that reads it. The Honda ROMs interpolate 1-D tables with a handful of routines (the VCALs and their relatives), each walking a list of (input, value) entries: the input byte (or word) falling from one entry to the next, and the list ending at the entry whose input is 0. Which routine reads a table says how wide its entries are; the data says how many there are; the RAM byte loaded before the call says what the input is (coolant, rpm...). A run of bytes that was only known as "N bytes" becomes the tables it really holds.
public static class TableShapes
{
    /// How a routine reads its table: entry size, input and value widths, and a fixed count (0: walk to the 0 input).
    public sealed record Reader(int Stride, bool WordInput, bool WordValue, int Fixed);

    /// A table found: its input list at AxisAddress, its values after each input, the RAM byte its input comes from.
    public sealed record Found(int AxisAddress, Reader Reader, int Count, int? InputRam, int CodeAddress);

    static readonly Regex Walk = new(@"^CMPC(B?)\s+A,\s*0*([234])h\[X1\]$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    static readonly Regex Clamp = new(@"^CMPC(B?)\s+A,\s*\[X1\]$", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// What kind of table reader the routine at `addr` is, from its first instructions; null when it is not one.
    public static Reader? Classify(byte[] rom, int addr)
    {
        var lines = new List<string>();
        foreach (bool dd in new[] { false, true })
        {
            lines.Clear();
            int pc = addr;
            for (int n = 0; n < 6 && pc < rom.Length; n++)
            {
                int at = pc;
                var d = Decoder.Decode(dd, k => at + k < rom.Length ? rom[at + k] : (byte)0xFF);
                if (d == null) break;
                lines.Add(Regex.Replace(Decoder.Format(d, (ushort)(pc + d.Len)), @"\s+", " ").Trim());
                pc += d.Len;
            }
            if (lines.Count == 0) continue;
            if (Walk.Match(lines[0]) is { Success: true } w)
            {
                int stride = int.Parse(w.Groups[2].Value);
                bool wordIn = w.Groups[1].Value.Length == 0;
                return new Reader(stride, wordIn, stride == 3 || stride == 4, 0);
            }
            if (Clamp.IsMatch(lines[0]))
                foreach (var l in lines.Skip(1))
                    if (Walk.Match(l) is { Success: true } w2)
                    {
                        int stride = int.Parse(w2.Groups[2].Value);
                        bool wordIn = w2.Groups[1].Value.Length == 0;
                        return new Reader(stride, wordIn, stride == 3 || stride == 4, 2);
                    }
        }
        return null;
    }

    /// How many entries a table read by `r` from `axis` has: to the entry with input 0 (the inputs must not rise on the way), or the reader's fixed count. 0 when the bytes there are not such a table.
    public static int Entries(byte[] rom, int axis, Reader r, Func<int, bool> isCode, int limit = 48)
    {
        if (r.Fixed > 0) return axis + r.Fixed * r.Stride <= rom.Length && !Enumerable.Range(axis, r.Fixed * r.Stride).Any(isCode) ? r.Fixed : 0;
        int prev = int.MaxValue;
        for (int e = 0; e < limit; e++)
        {
            int a = axis + e * r.Stride;
            if (a + r.Stride > rom.Length || Enumerable.Range(a, r.Stride).Any(isCode)) return 0;
            int x = r.WordInput ? rom[a] | rom[a + 1] << 8 : rom[a];
            if (e == 0 && x == 0) x = r.WordInput ? 0x10000 : 0x100;     // the top entry's input is never compared: 00 is 256
            if (x > prev) return e >= 3 ? e : 0;      // the inputs rise again: the next table (the input never gets below this one's last)
            if (x == 0) return e >= 1 ? e + 1 : 0;
            prev = x;
        }
        return 0;
    }

    /// Every table the code reads through a table routine: "MOV X1, #table" (maybe moved on by "ADD X1, #n"), then a VCAL or CAL to a reader, the input loaded into A just before.
    public static List<Found> Find(AssemblyResult asm, IReadOnlyDictionary<string, string[]> texts, byte[] rom, Func<int, bool> isCode)
    {
        var code = RomReference.CodeOf(asm, texts);
        var readers = new Dictionary<int, Reader?>();
        Reader? ReaderAt(int addr)
        {
            if (!readers.TryGetValue(addr, out var r)) readers[addr] = r = addr is > 0 and < 0x8000 ? Classify(rom, addr) : null;
            return r;
        }
        var found = new Dictionary<int, Found>();
        var at = new Dictionary<int, int>();
        for (int i = 0; i < code.Count; i++) at.TryAdd(code[i].Addr, i);
        static int? RamLoad(RomReference.CodeLine c) =>
            c.Key is "LB a,#" or "L a,#" or "LB a,off(#)" or "L a,off(#)" && c.Values[0] is long rv && rv < 0x400 ? (int)rv : null;
        static bool LoadsA(string k) => k.StartsWith("LB a,") || k.StartsWith("L a,") || k.StartsWith("CLR a") || k.StartsWith("CLRB a");
        for (int i = 0; i < code.Count; i++)
        {
            bool viaX2 = code[i].Key.StartsWith("MOV x2,##");
            if (!(code[i].Key.StartsWith("MOV x1,##") || viaX2) || code[i].Values.Length != 1 || code[i].Values[0] is not long t0) continue;
            // the input loaded just before the table is picked
            int? ram0 = null;
            for (int b = i - 1; b >= Math.Max(0, i - 4); b--) { if (RamLoad(code[b]) is int r0) { ram0 = r0; break; } if (LoadsA(code[b].Key)) break; }
            // follow the code on from here (both ways at a branch) to the table routine that reads X1
            var work = new Stack<(int Idx, long T, int? Ram, int Steps)>();
            var seen = new HashSet<(int, long)>();
            // a table picked into X2 is read once it is moved into X1 ("MOV X1, X2"): until then X1 is not it (-1)
            work.Push((i + 1, viaX2 ? -1 : t0, ram0, 0));
            while (work.Count > 0)
            {
                var (j, t, ram, steps) = work.Pop();
                if (j >= code.Count || steps > 24 || !seen.Add((j, t))) continue;
                var c = code[j];
                var k = c.Key;
                long? last = c.Values.Length > 0 ? c.Values[^1] : null;
                if (RamLoad(c) is int rl) { work.Push((j + 1, t, rl, steps + 1)); continue; }
                if (LoadsA(k)) { work.Push((j + 1, t, null, steps + 1)); continue; }
                if (k.StartsWith("ADD x1,##") && c.Values[0] is long add) { work.Push((j + 1, t + add, ram, steps + 1)); continue; }
                if (k == "INC x1") { work.Push((j + 1, t + 1, ram, steps + 1)); continue; }
                if (k == "DEC x1") { work.Push((j + 1, t - 1, ram, steps + 1)); continue; }
                if (k == "MOV x1,x2" && viaX2) { work.Push((j + 1, t0, ram, steps + 1)); continue; }
                if (viaX2 && (k.StartsWith("MOV x2,") || k.StartsWith("L x2"))) continue;
                if (k.StartsWith("RT") || k.StartsWith("BRK")) continue;
                // X1 set to something else: the end of an X1 table's path; an X2 one waits on
                if (k.StartsWith("MOV x1,") || k.StartsWith("L x1")) { if (viaX2) work.Push((j + 1, -1, ram, steps + 1)); continue; }
                if (k is "J #" or "SJ #")
                {
                    if (last is long jt && at.TryGetValue((int)jt, out var ji)) work.Push((ji, t, ram, steps + 1));
                    continue;
                }
                int routine = -1;
                if (k == "VCAL #" && c.Values[0] is long v && v is >= 0 and < 8) routine = rom[0x28 + (int)v * 2] | rom[0x29 + (int)v * 2] << 8;
                else if (k is "CAL #" or "SCAL #" && c.Values[0] is long cv) routine = (int)cv;
                if (routine >= 0)
                {
                    // a table routine reading another table through X1 leaves X2 alone
                    if (t < 0 && ReaderAt(routine) != null) { work.Push((j + 1, t, ram, steps + 1)); continue; }
                    if (t >= 0 && ReaderAt(routine) is { } reader)
                    {
                        int axis = (int)t;
                        if (axis >= 0x38 && axis < rom.Length && !isCode(axis) && Entries(rom, axis, reader, isCode) is int n and > 0)
                            found.TryAdd(axis, new Found(axis, reader, n, ram, c.Addr));
                    }
                    continue;           // any other call may change X1
                }
                // a conditional branch: both ways
                if (k.StartsWith("J") && last is long bt && at.TryGetValue((int)bt, out var bi)) work.Push((bi, t, ram, steps + 1));
                work.Push((j + 1, t, ram, steps + 1));
            }
        }
        return [.. found.Values.OrderBy(f => f.AxisAddress)];
    }

    /// Reads through a pointer register: "MOV X1 / X2 / DP, #block" and then "LC(B) A, n[X1]" on the way (jumps followed), each giving the address read and whether as a word.
    public static Dictionary<int, (bool Word, bool Indexed)> IndirectReads(AssemblyResult asm, IReadOnlyDictionary<string, string[]> texts)
    {
        var code = RomReference.CodeOf(asm, texts);
        var at = new Dictionary<int, int>();
        for (int i = 0; i < code.Count; i++) at.TryAdd(code[i].Addr, i);
        var reads = new Dictionary<int, (bool Word, bool Indexed)>();
        var reg = new Regex(@"^MOV (x1|x2|dp),##$");
        for (int i = 0; i < code.Count; i++)
        {
            var m = reg.Match(code[i].Key);
            if (!m.Success || code[i].Values[0] is not long t) continue;
            string r = m.Groups[1].Value;
            var work = new Stack<(int J, int Steps, bool Idx)>();
            var seen = new HashSet<(int, bool)>();
            work.Push((i + 1, 0, false));
            while (work.Count > 0)
            {
                var (j, steps, idx) = work.Pop();
                if (j >= code.Count || steps > 16 || !seen.Add((j, idx))) continue;
                var c = code[j]; var k = c.Key;
                // an index added to the pointer: what is read through it is an array
                if (k == $"ADD {r},a" || k.StartsWith($"ADD {r},er")) { work.Push((j + 1, steps + 1, true)); continue; }
                if (k.StartsWith($"MOV {r},") || k.StartsWith($"L {r}") || k.StartsWith($"INC {r}") || k.StartsWith($"ADD {r}") || k.StartsWith("RT") || k.StartsWith("CAL") || k.StartsWith("VCAL")) continue;
                var rm = Regex.Match(k, $@"^LC(B?) a,(#?)\[{r}\]$");
                if (rm.Success)
                {
                    long off = rm.Groups[2].Value.Length > 0 && c.Values.Length > 0 && c.Values[0] is long o ? o : 0;
                    int a = (int)(t + off);
                    var was = reads.GetValueOrDefault(a);
                    reads[a] = (was.Word || rm.Groups[1].Value.Length == 0, was.Indexed || idx);
                }
                long? last = c.Values.Length > 0 ? c.Values[^1] : null;
                if (k is "J #" or "SJ #") { if (last is long jt && at.TryGetValue((int)jt, out var ji)) work.Push((ji, steps + 1, idx)); continue; }
                if (k.StartsWith("J") && last is long bt && at.TryGetValue((int)bt, out var bi)) work.Push((bi, steps + 1, idx));
                work.Push((j + 1, steps + 1, idx));
            }
        }
        return reads;
    }

    /// The same kind of table, one after another from `start` to `end` (the rest of a labelled block): their input lists.
    public static List<(int Axis, int Count)> Run(byte[] rom, int start, int end, Reader r, Func<int, bool> isCode)
    {
        // a block that is several tables of the first one's size (unused ones padded with 00 inputs): split evenly
        int first = Entries(rom, start, r, isCode);
        if (first > 0 && r.Fixed == 0 && (end - start) % (first * r.Stride) == 0 && (end - start) / (first * r.Stride) > 1)
        {
            var even = new List<(int, int)>();
            bool ok = true;
            for (int a0 = start; a0 < end && ok; a0 += first * r.Stride)
            {
                int prev = int.MaxValue;
                for (int e = 0; e < first && ok; e++)
                {
                    int x = r.WordInput ? rom[a0 + e * r.Stride] | rom[a0 + e * r.Stride + 1] << 8 : rom[a0 + e * r.Stride];
                    if (x > prev || Enumerable.Range(a0 + e * r.Stride, r.Stride).Any(isCode)) ok = false;
                    prev = x;
                }
                if (prev != 0) ok = false;            // each ends at the input 0
                even.Add((a0, first));
            }
            if (ok) return even;
        }
        var list = new List<(int, int)>();
        int a = start;
        while (a < end)
        {
            int n = Entries(rom, a, r, isCode);
            if (n == 0 || a + n * r.Stride > end) break;
            list.Add((a, n));
            a += n * r.Stride;
        }
        return list;
    }

    /// A definition for a table: the values (after each input) as the cells, the inputs as the column axis.
    public static ItemDef Define(string name, int axis, int count, Reader r, string? inputFormula, string category, string origin)
    {
        int inW = r.WordInput ? 2 : 1;
        return new ItemDef
        {
            Name = name, Address = axis + inW, Type = r.WordValue ? CellType.U16 : CellType.U8,
            Rows = 1, Cols = count, ColStride = r.Stride, Formula = "raw", Category = category, Origin = origin,
            Description = $"{count} entries of (input, value), read {(r.Fixed > 0 ? "between two points" : "falling to the input 0")}.",
            ColAxis = new AxisDef
            {
                Name = name + "Input", Address = axis, Count = count, Stride = r.Stride,
                Type = r.WordInput ? CellType.U16 : CellType.U8, Formula = inputFormula ?? "raw",
            },
        };
    }

    /// What each RAM input byte is (its axis formula), learnt from a ROM whose tables are defined: the formula of the input axis of every table the code reads with a table routine, by the RAM byte loaded before the call.
    public static Dictionary<int, FormulaDef> LearnInputs(AssemblyResult asm, IReadOnlyDictionary<string, string[]> texts, IEnumerable<ItemDef> items,
                                                          Func<string, FormulaDef?> formula)
    {
        var byAxis = items.Where(i => i.ColAxis?.Address != null && i.ColAxis.Formula is { } fm && fm != "raw")
                          .GroupBy(i => i.ColAxis!.Address!.Value).ToDictionary(g => g.Key, g => g.First().ColAxis!.Formula!);
        var votes = new Dictionary<int, Dictionary<string, int>>();
        foreach (var f in Find(asm, texts, asm.Image, _ => false))
        {
            if (f.InputRam is not int ram || !byAxis.TryGetValue(f.AxisAddress, out var name)) continue;
            if (!votes.TryGetValue(ram, out var v)) votes[ram] = v = [];
            v[name] = v.GetValueOrDefault(name) + 1;
        }
        var result = new Dictionary<int, FormulaDef>();
        foreach (var (ram, v) in votes)
            if (formula(v.OrderByDescending(x => x.Value).First().Key) is { } fd) result[ram] = fd;
        return result;
    }
}
