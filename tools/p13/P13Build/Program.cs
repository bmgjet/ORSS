// P13Build: roms/p13.asm made relocatable (every ROM address a label), checked one stage at a time.
//
//   P13Build scan              list every number in the code that could be a ROM address, with what is there and whether
//                              the running ROM reads data at it (a drive through idle, cruise, full throttle and the limit)
//
// Each stage that only renames must reassemble to the stock bytes exactly.
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Core;
using P13Build;

var root = FindRoot();
var src = Path.Combine(root, "roms", "p13.asm");
ProcessorProfile.Msm66911().Apply();
var doc = new Doc(src, File.ReadAllLines(src));
var r0 = doc.AssembleOrThrow("p13");
var reference = r0.Image;

if (args.Contains("scan")) return Scan();
if (args.Contains("ramrefs"))
{
    // every RAM byte (80h-47Fh) the stock code names anywhere: direct and off() operands (a word op takes two bytes), bit
    // addresses, USP-frame operands "(a-b)[USP]", array bases "a[X1]" (the next 16 bytes counted too), pointers loaded
    // with "#a" (likewise), and register banks (MOV LRB, #n: 8 bytes at n*8). Then the bytes no line names.
    var named = new bool[0x480];
    void Mark(int a, int n) { for (int k = 0; k < n; k++) if (a + k >= 0x80 && a + k < 0x480) named[a + k] = true; }
    var reNum = new Regex(@"(?<![\w#])0*([0-9a-fA-F]{2,4})h\b");
    foreach (var raw in doc.Lines)
    {
        if (Doc.IsData(raw)) continue;
        var body = Doc.Body(raw);
        if (body.Length == 0 || Regex.IsMatch(body, @"\bequ\b", RegexOptions.IgnoreCase)) continue;
        var op = body.Split(' ', 2)[0].ToUpperInvariant();
        if (op is "J" or "SJ" or "CAL" or "SCAL" or "LC" or "LCB" or "CMPC" or "CMPCB" or "VCAL" or "JBS" or "JBR" && !body.Contains("off(")) { }
        bool word = !op.EndsWith('B') || op is "SUB" or "SB" or "RB";
        foreach (Match m in Regex.Matches(body, @"\(0*([0-9a-fA-F]+)h-0*[0-9a-fA-F]+h\)\[USP\]")) Mark(Convert.ToInt32(m.Groups[1].Value, 16), 2);
        foreach (Match m in Regex.Matches(body, @"0*([0-9a-fA-F]{3,4})h\[(X1|X2|DP)\]")) Mark(Convert.ToInt32(m.Groups[1].Value, 16), 16);
        foreach (Match m in Regex.Matches(body, @"#0*([0-9a-fA-F]{2,4})h")) { int v = Convert.ToInt32(m.Groups[1].Value, 16); if (Regex.IsMatch(body, @"^(MOV\s+(DP|X1|X2|USP)|L\s+A)\s*,", RegexOptions.IgnoreCase) && v >= 0x80 && v < 0x480) Mark(v, 16); }
        foreach (Match m in Regex.Matches(body, @"MOV\s+LRB\s*,\s*#0*([0-9a-fA-F]+)h", RegexOptions.IgnoreCase)) Mark(Convert.ToInt32(m.Groups[1].Value, 16) * 8, 8);
        var plain = Regex.Replace(body, @"#0*[0-9a-fA-F]+h", "");
        plain = Regex.Replace(plain, @"\(0*[0-9a-fA-F]+h-0*[0-9a-fA-F]+h\)\[USP\]", "");
        if (op is "LC" or "LCB" or "CMPC" or "CMPCB" or "J" or "SJ" or "CAL" or "SCAL") continue;
        foreach (Match m in reNum.Matches(plain)) { int v = Convert.ToInt32(m.Groups[1].Value, 16); Mark(v, word ? 2 : 1); }
    }
    var runs = new List<string>(); int total = 0;
    for (int a = 0x80; a < 0x480;) { if (named[a]) { a++; continue; } int s0 = a; while (a < 0x480 && !named[a]) a++; runs.Add($"{s0:X3}-{a - 1:X3}({a - s0})"); total += a - s0; }
    Console.WriteLine($"  RAM no line names (80h-47Fh): {total} bytes: {string.Join(" ", runs)}");
    return 0;
}
if (args.Contains("whoreads"))
{
    // which instructions read the given ROM address (hex) in stock, over the speed ramp
    var wantArg = args.SkipWhile(x => x != "whoreads").Skip(1).First().Split('-');
    int want = Convert.ToInt32(wantArg[0], 16), wantHi = wantArg.Length > 1 ? Convert.ToInt32(wantArg[1], 16) : want;
    var labs = r0.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).OrderBy(s => s.Value).ToArray();
    string Near(int a) { var l = labs.LastOrDefault(s => s.Value <= a); return l == null ? $"{a:X4}" : $"{l.Name}+{a - l.Value:X}"; }
    var sim = new Simulator(); sim.LoadRom(reference);
    var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.VbattVolts = 13.8;
    var pcs = new Dictionary<int, int>(); long seen = 0;
    void Go(double secs)
    {
        ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz);
        while (sim.Cpu.Cycles < end && sim.StepOne() != null)
        {
            for (; seen < sim.Bus.RomReadTotal; seen++) { var (ad, pc) = sim.Bus.RomReadLog[seen % sim.Bus.RomReadLog.Length]; if (ad + 1 >= want && ad <= wantHi) pcs[pc] = pcs.GetValueOrDefault(pc) + 1; }
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
        }
    }
    e.Rpm = 0; sim.SyncSensors(); Go(2);
    foreach (var (rpm, kmh) in new[] { (5000, 150.0), (5000, 190.0), (6500, 230.0) }) { e.Rpm = rpm; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = kmh; sim.SyncSensors(); Go(3); }
    foreach (var (pc, c) in pcs.OrderByDescending(x => x.Value)) Console.WriteLine($"  {pc:X4} {Near(pc)}: {c} reads of {want:X4} (or the word before it)");
    return 0;
}
if (args.Contains("skeleton")) return SkeletonStage();
if (args.Contains("mainloop"))
{
    // the main loop's shape: long backward jumps taken outside interrupts at idle and at 6000 rpm, and how often
    var labs = r0.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).OrderBy(s => s.Value).ToArray();
    string Near(int a) { var l = labs.LastOrDefault(s => s.Value <= a); return l == null ? $"{a:X4}" : $"{l.Name}+{a - l.Value:X}"; }
    foreach (var rpm in new[] { 850, 6000 })
    {
        var sim = new Simulator(); sim.LoadRom(reference);
        var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.VbattVolts = 13.8;
        int depth = 0; var jumps = new Dictionary<(int From, int To), long>(); bool on = false; ushort prev = 0;
        sim.BeforeStep = (pc, _) =>
        {
            if (on && depth == 0 && prev != 0 && pc < prev - 0x200 && sim.Bus.ReadCodeU8(prev) is 0x03 or 0xCB) jumps[(prev, pc)] = jumps.GetValueOrDefault((prev, pc)) + 1;
            prev = pc;
        };
        void Go(double secs)
        {
            ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz);
            while (sim.Cpu.Cycles < end)
            {
                var st = sim.StepOne(); if (st == null) break;
                if (st.Value.Decoded is { } dd && dd.Mnemonic.StartsWith("RTI", StringComparison.Ordinal) && depth > 0) depth--;
                if (sim.LastStepInterrupted) { depth++; prev = 0; }
                if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
            }
        }
        e.Rpm = 0; sim.SyncSensors(); Go(2);
        e.Rpm = rpm; e.MapKpa = rpm > 1000 ? 100 : 33; e.TpsPct = rpm > 1000 ? 100 : 0; sim.SyncSensors(); Go(1);
        on = true; Go(2);
        Console.WriteLine($"  {rpm} rpm: long backward jumps outside interrupts (per second):");
        foreach (var ((f, t), c) in jumps.OrderByDescending(x => x.Value).Take(6)) Console.WriteLine($"    {Near(f),-44} -> {Near(t),-40} {c / 2.0:0.#}");
    }
    return 0;
}
if (args.Contains("readsbylabel"))
{
    // stock and another build (any layout) through the speed ramp: the ROM data reads of each named by label + offset; the
    // names one build reads and the other does not
    var path = args.SkipWhile(x => x != "readsbylabel").Skip(1).First();
    var od = new Doc(path, File.ReadAllLines(path)); var orr = od.AssembleOrThrow("other");
    HashSet<string> Named(byte[] img, AssemblyResult asm)
    {
        var sim = new Simulator(); sim.LoadRom(img);
        var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.VbattVolts = 13.8;
        void Go(double secs) { ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz); while (sim.Cpu.Cycles < end && sim.StepOne() != null) if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
        e.Rpm = 0; sim.SyncSensors(); Go(2);
        sim.Bus.ClearRomReads();
        foreach (var (rpm, kmh) in new[] { (5000, 150.0), (5000, 190.0), (6500, 230.0) }) { e.Rpm = rpm; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = kmh; sim.SyncSensors(); Go(3); }
        var labs = asm.Symbols.Values.Where(x => x.Kind == SymbolKind.Label && x.Value < 0x8000).OrderBy(x => x.Value).ToArray();
        var keys = labs.Select(x => (int)x.Value).ToArray();
        var set = new HashSet<string>();
        for (int a = 0; a < 0x7FF0; a++)
            if (sim.Bus.RomReadCount[a] > 0)
            {
                int i = Array.BinarySearch(keys, a); if (i < 0) i = ~i - 1;
                set.Add(i < 0 ? $"{a:X4}" : $"{labs[i].Name}+{a - keys[i]:X}");
            }
        return set;
    }
    var sa = Named(reference, r0); var sb = Named(orr.Image, orr);
    foreach (var x in sa.Except(sb).Take(20)) Console.WriteLine($"  stock only: {x}");
    foreach (var x in sb.Except(sa).Take(20)) Console.WriteLine($"  other only: {x}");
    return 0;
}
if (args.Contains("reads"))
{
    // stock and a build moved by n through the speed ramp: the ROM bytes each reads as data. A stock read at a should be a
    // moved read at a + n (inside the moved part): a read that is not is a reference that did not move with the code.
    var path = args.SkipWhile(x => x != "reads").Skip(1).First();
    int sh = int.Parse(args.SkipWhile(x => x != "--by").Skip(1).FirstOrDefault() ?? "2");
    var other = new Doc(path, File.ReadAllLines(path)).AssembleOrThrow("other").Image;
    uint[] Reads(byte[] img)
    {
        var sim = new Simulator(); sim.LoadRom(img);
        var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.VbattVolts = 13.8;
        void Go(double secs) { ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz); while (sim.Cpu.Cycles < end && sim.StepOne() != null) if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
        e.Rpm = 0; sim.SyncSensors(); Go(2);
        sim.Bus.ClearRomReads();
        foreach (var (rpm, kmh) in new[] { (5000, 150.0), (5000, 190.0), (6500, 230.0) }) { e.Rpm = rpm; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = kmh; sim.SyncSensors(); Go(3); }
        return [.. sim.Bus.RomReadCount.Take(img.Length)];
    }
    var ra = Reads(reference); var rb = Reads(other);
    var labs = r0.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).OrderBy(s => s.Value).ToArray();
    string Near(int a) { var l = labs.LastOrDefault(s => s.Value <= a); return l == null ? $"{a:X4}" : $"{l.Name}+{a - l.Value:X}"; }
    int Moved(int a) => a >= 0x3C && a < 0x7000 ? a + sh : a;
    int shown = 0;
    for (int a = 0; a < 0x7FF0; a++)
    {
        bool inA = ra[a] > 0, inB = Moved(a) < rb.Length && rb[Moved(a)] > 0;
        if (inA != inB && shown++ < 30) Console.WriteLine($"  {a:X4} {Near(a),-40} stock {ra[a]}, moved {(Moved(a) < rb.Length ? rb[Moved(a)] : 0)}");
    }
    for (int b = 0; b < 0x7FF0; b++)
    {
        // moved reads with no stock read where they came from: the un-moved address a stale pointer still uses
        int a = b >= 0x3C + sh && b < 0x7000 + sh ? b - sh : b;
        if (rb[b] > 0 && ra[a] == 0 && shown++ < 40) Console.WriteLine($"  moved build read {b:X4} (stock {a:X4} {Near(a)}) {rb[b]} times, stock none");
    }
    Console.WriteLine($"  {shown} differences");
    return 0;
}
if (args.Contains("tables")) return TablesStage();
if (args.Contains("datacode"))
{
    // code still written as DB: addresses the running ROM executed (RomEquiv --coverage of stock) inside DB lines
    var cover = File.ReadAllLines(Path.Combine(root, "tools", "p13", "cover.txt")).Select(x => Convert.ToInt32(x, 16)).ToHashSet();
    var isData = new bool[reference.Length];
    foreach (var (li, ents) in Doc.ByLine(r0)) if (Doc.IsData(doc.Lines[li])) foreach (var e in ents) for (int k = 0; k < e.Length; k++) isData[e.Address + k] = true;
    var hits = cover.Where(a => a < isData.Length && isData[a]).OrderBy(a => a).ToList();
    var runs = new List<(int Lo, int Hi)>();
    foreach (var a in hits) { if (runs.Count > 0 && a - runs[^1].Hi < 16) runs[^1] = (runs[^1].Lo, a); else runs.Add((a, a)); }
    Console.WriteLine($"  {hits.Count} executed addresses inside DB lines, in {runs.Count} runs: {string.Join(", ", runs.Select(x => $"{x.Lo:X4}-{x.Hi:X4}"))}");
    foreach (var (li, ents) in Doc.ByLine(r0).OrderBy(k => k.Key))
        if (Doc.IsData(doc.Lines[li]) && ents.Any(e => hits.Any(h => h >= e.Address && h < e.Address + e.Length)))
            Console.WriteLine($"    L{li + 1} {ents[0].Address:X4}: {doc.Lines[Math.Max(0, li - 1)].Trim()} || {doc.Lines[li].Trim()}");
    return 0;
}
if (args.Contains("probe"))
{
    // stock and another build through the sensor-fault drive: resets (BRK reasons in 0D4h) and fuel/spark each phase
    var otherDoc = new Doc(args.SkipWhile(x => x != "probe").Skip(1).First(), File.ReadAllLines(args.SkipWhile(x => x != "probe").Skip(1).First()));
    var otherR = otherDoc.AssembleOrThrow("other");
    foreach (var (name, img, asm) in new[] { ("stock", reference, r0), ("other", otherR.Image, otherR) })
    {
        var labs = asm.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).OrderBy(s => s.Value).ToArray();
        string Near(int a) { var l = labs.LastOrDefault(s => s.Value <= a); return l == null ? $"{a:X4}" : $"{l.Name}+{a - l.Value:X}"; }
        var sim = new Simulator(); sim.LoadRom(img);
        var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.VbattVolts = 13.8;
        var brks = new List<string>();
        int startPc = img[0] | img[1] << 8;
        ushort lastPc = 0; bool booted = false;
        var ring = new ushort[24]; int ri = 0;
        sim.BeforeStep = (pc, _) => { if (booted && pc == startPc) brks.Add($"reset (0D4h {sim.Bus.Ram[0xD4]:X2}) after {Near(lastPc)}"); lastPc = pc; ring[ri++ % ring.Length] = pc; };
        void Go(double secs) { ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz); while (sim.Cpu.Cycles < end && sim.StepOne() != null) if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
        e.Rpm = 0; sim.SyncSensors(); Go(2); booted = true;
        foreach (var (ph, set) in new (string, Action<EngineState>)[] {
            ("2000 rpm", x => { x.Rpm = 2000; x.MapKpa = 45; x.TpsPct = 8; }),
            ("ovr 202/102", x => { x.AnalogOverrides[202] = 4.95; x.AnalogOverrides[102] = 0.05; }),
            ("ovr 7=0 6=5", x => { x.AnalogOverrides[7] = 0.0; x.AnalogOverrides[6] = 5.0; }) })
        {
            set(e); sim.SyncSensors();
            long i0 = sim.Bus.InjectorEvents.Sum(); int b0 = brks.Count;
            Go(4);
            Console.WriteLine($"  {name} {ph}: {(sim.Bus.InjectorEvents.Sum() - i0) / 4.0:0} inj/s, 0D4h {sim.Bus.Ram[0xD4]:X2}, {sim.State} {sim.FaultMessage}; {string.Join("; ", brks.Skip(b0).Take(3))}");
            if (sim.State == RunState.Faulted) { Console.WriteLine("    last: " + string.Join(" > ", Enumerable.Range(0, ring.Length).Select(k => ring[(ri + k) % ring.Length]).Select(pc => Near(pc)))); break; }
        }
    }
    return 0;
}
if (args.Contains("compare"))
{
    // the stock image against another build: the boot ROM sum of each (bytes 1-7FFEh twice, 0 and 7FFFh once), and the bytes
    // past where a shifted build should match stock again
    var other = new Doc(args.SkipWhile(x => x != "compare").Skip(1).First(), File.ReadAllLines(args.SkipWhile(x => x != "compare").Skip(1).First())).AssembleOrThrow("other").Image;
    int Sum(byte[] im) { int s = im[0] + im[0x7FFF]; for (int i = 1; i < 0x7FFF; i++) s += 2 * im[i]; return s & 0xFF; }
    Console.WriteLine($"  sum stock {Sum(reference):X2}, other {Sum(other):X2}; tail 7FE0-7FFF stock {Convert.ToHexString(reference, 0x7FE0, 32)}");
    Console.WriteLine($"  other 7FC0-7FDF {Convert.ToHexString(other, 0x7FC0, 32)}");
    Console.WriteLine($"                                         other {Convert.ToHexString(other, 0x7FE0, 32)}");
    int diffs = 0; for (int i = 0x7000; i < 0x8000; i++) if (reference[i] != other[i]) { if (diffs++ < 8) Console.WriteLine($"  {i:X4}: {reference[i]:X2} / {other[i]:X2}"); }
    Console.WriteLine($"  {diffs} bytes differ from 7000h up");
    // a build moved by n: where it stops being stock moved by n (outside the references that moved with it)
    int sh = int.Parse(args.SkipWhile(x => x != "--by").Skip(1).FirstOrDefault() ?? "2"), bad = 0;
    for (int i = 0x3C; i + sh < 0x7FF0; i++)
        if (other[i + sh] != reference[i]) { if (bad++ < 12) Console.WriteLine($"  moved {i:X4}->{i + sh:X4}: stock {reference[i]:X2}, moved {other[i + sh]:X2}"); }
    Console.WriteLine($"  {bad} bytes are not stock moved by {sh} (references that moved account for some)");
    return 0;
}
if (args.Contains("symbolize")) return SymbolizeStage();
if (args.Contains("shift")) return ShiftTest(int.Parse(args.SkipWhile(x => x != "shift").Skip(1).FirstOrDefault() ?? "2"));
Console.WriteLine("P13Build scan | symbolize | shift [n]");
return 2;

void Same(string stage)
{
    var img = doc.AssembleOrThrow(stage).Image;
    int diff = Enumerable.Range(0, img.Length).Count(i => img[i] != reference[i]);
    if (diff != 0) throw new Exception($"{stage}: {diff} bytes differ from stock P13 - a stage that must not change the image did");
    Console.WriteLine($"  {stage}: image unchanged");
}

// ROM addresses written as numbers -> labels. What is a pointer was decided by reading each one in context (scan.txt):
//   - a ROM read (LC / LCB) of a fixed address inside the image
//   - "MOV X1/X2/DP, #n" with n inside a data table (the indexed reads that follow), "ADD X1, #n" (a table base)
//   - "L A, #n" with n inside a data table that then goes into X1 (the fuel cut and O2 trim table pairs)
// and not: test patterns (5555h/AAAAh), rpm periods and other constants, the RAM top, the factory bytes past the image
// (7FF0h-7FF3h: read where they are, 0 on a stock chip) or the ROM sum's start (7FFEh).
int SymbolizeStage()
{
    var r = doc.AssembleOrThrow("symbolize");
    var lineAt = new int[reference.Length]; Array.Fill(lineAt, -1);
    foreach (var (li, ents) in Doc.ByLine(r)) foreach (var e in ents) for (int k = 0; k < e.Length; k++) lineAt[e.Address + k] = li;
    var num = new Regex(@"(?<![\w])(#?)0*([0-9a-fA-F]{4,5})h\b");
    var pointerL = new HashSet<int> { 0x52B3, 0x5297, 0x5249, 0x5253, 0x525D, 0x5262 };   // "L A, #n" that become X1
    var ptrLine = new Regex(@"^(MOV\s+(X1|X2|DP)|ADD\s+X1)\s*,", RegexOptions.IgnoreCase);
    var todo = new List<(int Value, string Token)>();
    for (int li = 0; li < doc.Lines.Count; li++)
    {
        if (Doc.IsData(doc.Lines[li])) continue;
        var code = doc.Lines[li].Split(';', 2)[0];
        var body = Doc.Body(doc.Lines[li]);
        if (body.Length == 0 || Regex.IsMatch(code, @"\bequ\b", RegexOptions.IgnoreCase)) continue;
        var op = body.Split(' ', 2)[0].ToUpperInvariant();
        foreach (Match m in num.Matches(code))
        {
            int v = Convert.ToInt32(m.Groups[2].Value, 16);
            if (v < 0x480 || v >= 0x7FF0 || lineAt[v] < 0) continue;
            bool imm = m.Groups[1].Value == "#";
            bool inData = Doc.IsData(doc.Lines[lineAt[v]]);
            bool take = (op is "LC" or "LCB" or "CMPC" or "CMPCB") && !imm
                     || imm && inData && ptrLine.IsMatch(body)
                     || imm && op == "L" && pointerL.Contains(v);
            if (take) todo.Add((v, m.Value));
        }
    }
    Console.WriteLine($"  {todo.Count} ROM addresses written as numbers");
    // a label at each address: a data byte gets one of its own (the line split there); a byte inside an instruction is
    // that instruction's label plus the offset
    var names = new Dictionary<int, string>();
    foreach (var v in todo.Select(t => t.Value).Distinct().OrderBy(v => v))
    {
        var rr = doc.AssembleOrThrow("label");
        var have = rr.Symbols.Values.FirstOrDefault(s => s.Kind == SymbolKind.Label && s.Value == v);
        if (have != null) { names[v] = have.Name; continue; }
        var la = new int[reference.Length]; Array.Fill(la, -1); var sa = new int[reference.Length];
        foreach (var (li, ents) in Doc.ByLine(rr)) foreach (var e in ents) for (int k = 0; k < e.Length; k++) { la[e.Address + k] = li; sa[e.Address + k] = e.Address; }
        if (Doc.IsData(doc.Lines[la[v]])) names[v] = Labels.At(doc, v, $"rom_{v:x4}");
        else
        {
            int st = sa[v], li = la[v];
            string lab = Doc.Label(doc.Lines[li]) ?? rr.Symbols.Values.FirstOrDefault(s => s.Kind == SymbolKind.Label && s.Value == st)?.Name ?? "";
            if (lab.Length == 0) { lab = $"code_{st:x4}"; doc.Lines[li] = (lab + ":").PadRight(16) + doc.Lines[li].TrimStart(); }
            names[v] = v == st ? lab : $"{lab}+{v - st}";
        }
    }
    // every code line holding one of those tokens in a pointer use (the lines moved as data lines were split)
    int done = 0;
    var anyPtr = new Regex(@"^(MOV\s+(X1|X2|DP)|ADD\s+X1|L\s+A)\s*,", RegexOptions.IgnoreCase);
    foreach (var (v, tok) in todo.Distinct())
        for (int i = 0; i < doc.Lines.Count; i++)
        {
            if (Doc.IsData(doc.Lines[i])) continue;
            var parts = doc.Lines[i].Split(';', 2);
            if (!Regex.IsMatch(parts[0], @"(?<![\w])" + Regex.Escape(tok) + @"(?![\w])")) continue;
            var bodyI = Doc.Body(doc.Lines[i]);
            var opI = bodyI.Split(' ', 2)[0].ToUpperInvariant();
            bool imm = tok.StartsWith('#');
            bool ok = (opI is "LC" or "LCB" or "CMPC" or "CMPCB") && !imm || imm && anyPtr.IsMatch(bodyI);
            if (!ok) continue;
            var nc = Regex.Replace(parts[0], @"(?<![\w])" + Regex.Escape(tok) + @"(?![\w])", (imm ? "#" : "") + names[v]);
            if (nc != parts[0]) { doc.Lines[i] = nc + (parts.Length > 1 ? ";" + parts[1] : ""); done++; }
        }
    Console.WriteLine($"  {done} references now labels");
    Same("symbolize");
    doc.Save();
    return 0;
}

// The two dispatch tables written as DB:
//   - dtc_active_confirm_tbl_2: J [ACC] by fault number into code that was still DB bytes (the per-code confirm steps):
//     the code decoded from the table's entries, then the table made DW labels
//   - int_serial_tbl: the stock tester's commands - a word each, a RAM address to send (int_serial_tbl_2 says 01h) or,
//     where int_serial_tbl_2 says 00h, a handler that J [DP] goes to: those words made labels
int TablesStage()
{
    var r = doc.AssembleOrThrow("tables");
    var img = r.Image;
    int Sym(string n) => (int)r.Symbols.Values.First(s => s.Name == n).Value;
    int dtc = Sym("dtc_active_confirm_tbl_2");
    var entries = new List<int>();
    for (int a = dtc; ; a += 2) { int w = img[a] | img[a + 1] << 8; if (w == 0xFFFF) break; entries.Add(w); }
    Console.WriteLine($"  dtc table: {entries.Count} entries, {entries.Distinct().Count()} handlers");
    int n = Symbolize.Run(doc, entries.Distinct().Select(e => (e, true)), (0, 0), "dtc_step");
    Console.WriteLine($"  {n} instructions decoded from DB");
    Same("tables: decode");
    r = doc.AssembleOrThrow("tables");
    var names = r.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).GroupBy(s => (int)s.Value).ToDictionary(g => g.Key, g => g.First().Name);
    Tables.ToDw(doc, dtc, entries.Count, names, "dtc_active_confirm_tbl_2");
    Same("tables: dtc table");
    // the serial command table
    r = doc.AssembleOrThrow("tables");
    img = r.Image;
    names = r.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).GroupBy(s => (int)s.Value).ToDictionary(g => g.Key, g => g.First().Name);
    int st = Sym2(r, "int_serial_tbl"), kind = Sym2(r, "int_serial_tbl_2");
    var code = new List<int>();
    for (int i = 0; i < 0x80 && st + 2 * i + 1 < kind; i++)
        if (img[kind + i] == 0x00) code.Add(i);
    Console.WriteLine($"  serial table: handlers at entries {string.Join(",", code.Select(i => $"{i:X2}h={img[st + 2 * i] | img[st + 2 * i + 1] << 8:X4}"))}");
    var handlers = code.Select(i => img[st + 2 * i] | img[st + 2 * i + 1] << 8).Where(w => w >= 0x480).Distinct().ToList();
    if (handlers.Count > 0)
    {
        n = Symbolize.Run(doc, handlers.Where(h => !names.ContainsKey(h)).Select(h => (h, true)), (0, 0), "serial_cmd");
        r = doc.AssembleOrThrow("tables");
        names = r.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).GroupBy(s => (int)s.Value).ToDictionary(g => g.Key, g => g.First().Name);
        // the whole table as DW: labels for the handlers, numbers for the RAM addresses
        int count = (kind - st) / 2;
        var dwNames = new Dictionary<int, string>();
        for (int i = 0; i < count; i++)
        {
            int w = img[st + 2 * i] | img[st + 2 * i + 1] << 8;
            dwNames[w] = img[kind + i] == 0x00 && names.TryGetValue(w, out var nm) && w >= 0x480 ? nm : $"0{w:X4}h";
        }
        Tables.ToDwMixed(doc, st, count, i => { int w = img[st + 2 * i] | img[st + 2 * i + 1] << 8; return i < 0x80 && img[kind + i] == 0x00 && w >= 0x480 && names.TryGetValue(w, out var nm) ? nm : $"0{w:X4}h"; }, "int_serial_tbl");
        Same("tables: serial table");
    }
    doc.Save();
    return 0;
}
static int Sym2(AssemblyResult r, string n) => (int)r.Symbols.Values.First(s => s.Name == n).Value;

// roms/p13-skeleton.asm, first cut: stock P13 (relocatable) with the skeleton's frame round it - the extension points the
// feature modules plug into, the FFh padding out so code and calibration pack together, and the module interface at the
// top of the ROM (hooks 7F00h, info block 7FC0h, clear of the factory bytes at 7FF0h-7FF3h; checksum 7FFFh). The stock
// functions are all still in; they become FEAT_STOCK_* switches step by step after this, each step checked against stock.
int SkeletonStage()
{
    var outPath = Path.Combine(root, "roms", "p13-skeleton.asm");
    var lines = new List<string>(doc.Lines);
    var r = doc.AssembleOrThrow("skeleton");
    var byLine = Doc.ByLine(r);
    // 1. the padding: unlabelled DB lines of nothing but FFh, in runs of 32 bytes or more (tables of FFh have labels)
    var remove = new HashSet<int>();
    var run = new List<int>(); int runBytes = 0;
    int minRun = int.Parse(Environment.GetEnvironmentVariable("P13_MINPAD") ?? "32");
    void EndRun() { if (runBytes >= minRun) foreach (var x in run) remove.Add(x); run.Clear(); runBytes = 0; }
    for (int li = 0; li < lines.Count; li++)
    {
        bool pad = Doc.IsData(lines[li]) && Doc.Label(lines[li]) == null && byLine.TryGetValue(li, out var ents)
                   && ents.All(e => Enumerable.Range(e.Address, e.Length).All(a => r.Image[a] == 0xFF)) && ents[0].Address < 0x7FF0;
        if (pad) { run.Add(li); runBytes += byLine[li].Sum(e => e.Length); }
        else if (Doc.Body(lines[li]).Length > 0 || Doc.Label(lines[li]) != null) EndRun();
    }
    EndRun();
    Console.WriteLine($"  {remove.Count} padding lines out ({remove.Sum(li => byLine[li].Sum(e => e.Length))} bytes)");
    // the image's last lines: from the end-of-ROM comment on, the stock tail (factory bytes, checksum) - replaced below
    int tail = lines.FindIndex(l => l.Contains("[info] end of programmed ROM"));
    var body = new List<string>();
    for (int li = 0; li < (tail < 0 ? lines.Count : tail); li++) if (!remove.Contains(li)) body.Add(lines[li]);
    // 2. the header and the definitions point, after the SFR names
    int sfrEnd = body.FindIndex(l => l.StartsWith(";=====") && body.IndexOf(l) > 90);
    int org0 = body.FindIndex(l => Regex.IsMatch(l, @"^\s+org\s+0000h", RegexOptions.IgnoreCase));
    var head = new List<string>
    {
        ";==================================================================================================",
        "; p13-skeleton.asm - Honda P13 (OBD0/OBD1, OKI MSM66911) as the base for building a ROM out of feature modules,",
        "; the way p30-skeleton.asm is for the P30. Built from roms/p13.asm (made relocatable: every ROM address a label)",
        "; by tools/p13/P13Build, then step by step; after every step the simulator compares it with stock P13.",
        ";",
        "; NOT TESTED ON A CAR. Everything here was checked in the Rom Sim Studio simulator only; no P13 has run it yet.",
        ";",
        "; First cut: every stock function is still in; the extension points and the module interface are added.",
        ";==================================================================================================",
    };
    var xp = new List<string>
    {
        "; ---------------------------------------------------------------------------------------------------",
        "; Extension points: the feature modules' features.inc is included at each one (the same modules as the P30, built",
        "; for this ECU: PLATFORM_P13 says which ECU it is). With no feature defined none of them emits a byte.",
        "define PLATFORM_P13",
        "XP_DEFS         EQU     1       ; defines, RAM and requirements, before any code",
        "XP_BOOT         EQU     2       ; once at power-up",
        "XP_MAIN         EQU     3       ; once per main-loop pass",
        "XP_FUEL         EQU     4       ; every fuel calculation",
        "XP_IGN          EQU     5       ; every spark calculation",
        "XP_TICK         EQU     6       ; every module tick (2.048 ms)",
        "XP_OUT          EQU     7       ; after the outputs are set",
        "XP_CAL          EQU     8       ; calibration tables",
        "XP_CODE         EQU     9       ; module code, at the start of the free space",
        "XP_SPARK        EQU     10      ; every spark interrupt",
        "XP_TICKSLOT     EQU     11      ; the modules on this tick's slot",
        "XP_CKP          EQU     12      ; a crank tooth, while 0FDh bit 6 asks for it (the trigger pattern log)",
        "undef XP",
        "define XP XP_DEFS",
        "include \"p13-features/features.inc\"",
    };
    body.InsertRange(org0, xp);
    // drop the stock header (up to the processor line) and put the skeleton's in its place
    int proc = body.FindIndex(l => l.StartsWith("; processor:"));
    body.RemoveRange(0, proc);
    body.InsertRange(0, head);
    // 3. the main loop's point: before the jump back to its top
    int loopEnd = body.FindIndex(l => Doc.Label(l) == "calchecksum_loop_goto_0c7e");
    if (loopEnd < 0) throw new Exception("main loop end not found");
    var lab = "calchecksum_loop_goto_0c7e";
    var rest = body[loopEnd].Substring(body[loopEnd].IndexOf(':') + 1).TrimStart();
    body[loopEnd] = $"{lab}:";
    body.InsertRange(loopEnd + 1, new[]
    {
        "undef XP",
        "define XP XP_MAIN",
        "include \"p13-features/features.inc\"",
        "                CAL     hook_main              ; (skeleton) module slot: once per main-loop pass",
        "                " + rest,
    });
    // 4. the module interface at the top of the ROM
    body.AddRange(new[]
    {
        "undef XP",
        "define XP XP_CAL",
        "include \"p13-features/features.inc\"",
        "undef XP",
        "define XP XP_CODE",
        "include \"p13-features/features.inc\"",
        "skel_free_start:                               ; everything from here to 7EFFh is free for modules",
        "if skel_free_start > 07F00h",
        "                error   \"the ROM is full: the code and tables are {} bytes too big\", skel_free_start - 07F00h",
        "endif",
        "; ================================================================================================",
        "; Module interface: hooks at 7F00h (3 bytes each, RT until a module is installed), the info block at 7FC0h.",
        "; 7FF0h-7FF3h are the factory bytes the stock code reads (FFh on a chip: the normal paths) - left FFh.",
        "; ================================================================================================",
        "; @keep-begin (the hook slots are patched by modules: keep every byte)",
        "                org 07F00h",
        "hook_init:      RT", "                NOP", "                NOP",
        "hook_main:      RT", "                NOP", "                NOP",
        "hook_fuel:      RT", "                NOP", "                NOP",
        "hook_ign:       RT", "                NOP", "                NOP",
        "hook_spare1:    RT", "                NOP", "                NOP",
        "hook_spare2:    RT", "                NOP", "                NOP",
        "hook_spare3:    RT", "                NOP", "                NOP",
        "hook_spare4:    RT", "                NOP", "                NOP",
        "                org 07FC0h",
        ";@ RomId type=u8 count=12 text=ascii category=\"Internal\" desc=\"The skeleton's name and version, 12 characters: the ECU (P13), the ROM's name (OPENH), the skeleton's version (001). What a hex editor shows.\"",
        "RomId:",
        "ifdef ROM_ID_SET",
        "                org 07FCCh",
        "else",
        "                DB  \"P13-OPENH001\"      ; 7FC0",
        "endif",
        ";@ SkeletonVersion type=u8 count=2 formula=raw category=\"Internal\" desc=\"The layout version of the skeleton (not a tuning value).\"",
        "SkeletonVersion:   DB  002h, 000h             ; 7FCC layout version 2.0",
        "skel_free_lo:   DW  skel_free_start        ; 7FCE first free byte",
        ";@ SkeletonLayout type=u16 count=3 formula=raw category=\"Internal\" desc=\"The free space the modules use (not a tuning value).\"",
        "SkeletonLayout:   DW  07EFFh                 ; 7FD0 last free byte",
        "skel_free2_lo:  DW  00000h",
        "skel_free2_hi:  DW  00000h",
        "skel_hooks:     DW  hook_init              ; 7FD6 hook table",
        ";@ SkeletonHookCount type=u8 formula=raw category=\"Internal\" desc=\"Hook table slots (not a tuning value).\"",
        "SkeletonHookCount: DB  8                      ; 7FD8 slots",
        "; @keep-end",
        "; The factory bytes the stock code reads: 7FF0h is 00h on a stock chip (the last byte of the image), 7FF1h-7FF3h",
        "; FFh (past it). Kept exactly so: each one switches stock paths (the debug paths at 0D22h and others).",
        "                org 07FF0h",
        "factory_7ff0:   DB  000h",
        "                org 07FFFh",
        "checksum_fix:   checksum                ; 7FFF: set by the assembler so the 8-bit sum of the image is 0 (the ROM checks it at boot and in the background)",
    });
    var sk = new Doc(outPath, body);
    var rs = sk.AssembleOrThrow("p13-skeleton");
    sk.Save();
    int free = 0x7F00 - (int)rs.Symbols.Values.First(s => s.Name == "skel_free_start").Value;
    Console.WriteLine($"  written roms/p13-skeleton.asm: {free} bytes free for modules");
    return 0;
}

// The relocation check: n filler bytes put in before the first code (and taken off the FFh padding at the end), so every
// address after them moves; the moved build must do exactly what stock does (RomEquiv --exact).
int ShiftTest(int n)
{
    var lines = new List<string>(doc.Lines);
    // the padding trimmed first, by where the lines are now (with the filler in, the image would not fit to assemble)
    var byLine = Doc.ByLine(doc.AssembleOrThrow("shift: before"));
    int trimmed = 0;
    foreach (var li in byLine.Keys.OrderByDescending(k => k))
    {
        if (trimmed >= n) break;
        if (!Doc.IsData(lines[li]) || byLine[li][0].Address < 0x7000 || byLine[li][0].Address >= 0x7FF0) continue;
        var vals = Regex.Matches(Doc.Body(lines[li]), @"0[0-9A-Fa-f]{2}h").Select(m => m.Value).ToList();
        if (vals.Count == 0 || !vals.All(x => x.Equals("0FFh", StringComparison.OrdinalIgnoreCase))) continue;
        int drop = Math.Min(n - trimmed, vals.Count), keep = vals.Count - drop;
        var lab = Doc.Label(lines[li]);
        lines[li] = keep == 0 ? (lab != null ? lab + ":" : "") : $"{(lab != null ? lab + ":" : ""),-16}DB  {string.Join(",", Enumerable.Repeat("0FFh", keep))}";
        trimmed += drop;
    }
    int first = lines.FindIndex(l => Doc.Label(l) == "int_NMI_set_sbycon_bit0");
    if (first < 0) throw new Exception("no first code label");
    lines.Insert(first, $"                DB  {string.Join(",", Enumerable.Repeat("0FFh", n))} ; (relocation check filler)");
    var d2 = new Doc(Path.Combine(root, "tools", "p13", "p13-shifted.asm"), lines);
    var r2 = d2.AssembleOrThrow("shifted");
    d2.Save();
    Console.WriteLine($"  shifted by {n}: {r2.Image.Length} bytes, {trimmed} trimmed off the padding; written to tools/p13/p13-shifted.asm");
    return 0;
}

int Scan()
{
    // what the running ROM reads as data
    var reads = DataReads(reference);
    var labels = r0.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).GroupBy(s => (int)s.Value).ToDictionary(g => g.Key, g => g.First().Name);
    var byLine = Doc.ByLine(r0);
    // address -> the line that produced it, and whether that line is data
    var lineAt = new int[reference.Length]; Array.Fill(lineAt, -1);
    foreach (var (li, ents) in byLine) foreach (var e in ents) for (int k = 0; k < e.Length; k++) lineAt[e.Address + k] = li;
    var num = new Regex(@"(?<![\w])(#?)0*([0-9a-fA-F]{4,5})h\b");
    int n = 0;
    var outp = new List<string>();
    for (int li = 0; li < doc.Lines.Count; li++)
    {
        var code = doc.Lines[li].Split(';', 2)[0];
        if (Doc.IsData(doc.Lines[li]) && !Regex.IsMatch(Doc.Body(doc.Lines[li]), @"^DW\b", RegexOptions.IgnoreCase)) continue;
        if (Regex.IsMatch(code, @"^\s*\w+\s+equ\b", RegexOptions.IgnoreCase) || Regex.IsMatch(Doc.Body(code), @"^org\b", RegexOptions.IgnoreCase)) continue;
        foreach (Match m in num.Matches(code))
        {
            int v = Convert.ToInt32(m.Groups[2].Value, 16);
            if (v < 0x38 || v > 0x7FFF) continue;
            n++;
            string at = labels.TryGetValue(v, out var lab) ? $"label {lab}" : lineAt[v] >= 0 ? (Doc.IsData(doc.Lines[lineAt[v]]) ? $"inside data L{lineAt[v] + 1}" : $"inside code L{lineAt[v] + 1}") : "nothing";
            int readNear = 0;
            for (int k = 0; k < 0x200 && v + k < reference.Length; k++) if (reads[v + k] > 0) { readNear = k + 1; break; }
            outp.Add($"L{li + 1,-6} {Doc.Body(doc.Lines[li]),-40} {(m.Groups[1].Value == "#" ? "imm" : "adr")} {v:X4}  {at,-34} {(reads[v] > 0 ? "READ" : readNear > 0 ? $"read+{readNear - 1:X}" : "-")}");
        }
    }
    File.WriteAllLines(Path.Combine(root, "tools", "p13", "scan.txt"), outp);
    Console.WriteLine($"{n} candidates; written to tools/p13/scan.txt");
    return 0;
}

static uint[] DataReads(byte[] rom)
{
    var sim = new Simulator(); sim.LoadRom(rom);
    var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.VbattVolts = 13.8; e.O2Volts = 0.45;
    void Go(double secs) { ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz); while (sim.Cpu.Cycles < end && sim.StepOne() != null) if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
    e.Rpm = 0; sim.SyncSensors(); Go(2);
    foreach (var (rpm, map, tps, kmh, ect) in new[] { (250, 95.0, 0.0, 0.0, -10.0), (850, 33.0, 0.0, 0.0, 20.0), (850, 33.0, 0.0, 0.0, 85.0), (3000, 55.0, 15.0, 90.0, 85.0),
                                                     (6000, 100.0, 100.0, 120.0, 85.0), (8000, 100.0, 100.0, 140.0, 105.0), (3000, 25.0, 0.0, 90.0, 85.0), (850, 33.0, 0.0, 0.0, 85.0) })
    { e.Rpm = rpm; e.MapKpa = map; e.TpsPct = tps; e.SpeedKmh = kmh; e.EctCelsius = ect; e.Cranking = rpm < 400; sim.SyncSensors(); Go(2.5); }
    var reads = new uint[rom.Length];
    Array.Copy(sim.Bus.RomReadCount, reads, Math.Min(reads.Length, sim.Bus.RomReadCount.Length));
    return reads;
}

static string FindRoot()
{
    var d = new DirectoryInfo(AppContext.BaseDirectory);
    while (d != null && !File.Exists(Path.Combine(d.FullName, "roms", "p13.asm"))) d = d.Parent;
    return d?.FullName ?? throw new Exception("roms/p13.asm not found above " + AppContext.BaseDirectory);
}
