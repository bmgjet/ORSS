using System.Text;
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Core;
using Decoder = OkiRomSim.Core.Decoder;

namespace OkiRomSim.Mcp;

/// Follows the code from an entry point the way the CPU would (fall-through, both sides of every branch, calls noted and optionally explored), records what each instruction touches, and guesses what the routine is for from the hardware it drives and the data it reads.
public sealed class Explorer
{
    readonly Program66k _p;
    public Explorer(Program66k p) { _p = p; }

    public sealed class Routine
    {
        public int Entry;
        public string Name = "";
        public SortedDictionary<int, (Decoded D, string Text)> Code = new();
        public SortedSet<int> Calls = new();
        public SortedSet<int> TailJumps = new();
        public List<(int From, int To)> Loops = new();
        public SortedSet<string> RamRead = new(), RamWrite = new(), Sfr = new(), RomData = new(), Bits = new();
        public bool EndsRti, HasBrk, IndirectJump, Truncated;
        public List<string> Evidence = new();
        public string Purpose = "";
    }

    static readonly HashSet<string> Terminal = new() { "RT", "RTI", "BRK" };
    static readonly Regex Branchy = new(@"^(J|SJ|JEQ|JNE|JLT|JGE|JGT|JLE|JBS|JBR|JRNZ)\b");

    public Routine Walk(int entry, int maxInstructions)
    {
        var r = new Routine { Entry = entry, Name = _p.Name(entry) };
        var todo = new Stack<int>();
        todo.Push(entry);
        while (todo.Count > 0)
        {
            int pc = todo.Pop();
            while (pc >= 0 && pc < Bus.RomSize && !r.Code.ContainsKey(pc))
            {
                if (r.Code.Count >= maxInstructions) { r.Truncated = true; break; }
                var d = _p.DecodeAt(pc);
                if (d == null) break;
                string src = _p.SourceAt(pc) is { } s ? Program66k.StripLabel(s.Text) : Decoder.Format(d, (ushort)(pc + d.Len));
                r.Code[pc] = (d, src);
                Analyse(r, pc, d, src);
                string op = d.Mnemonic.Split(' ')[0];
                int next = pc + d.Len;
                if (Terminal.Contains(op)) { if (op == "RTI") r.EndsRti = true; if (op == "BRK") r.HasBrk = true; break; }
                if (op is "CAL" or "SCAL" or "VCAL")
                {
                    if (Target(pc, d) is int t) r.Calls.Add(t);
                    pc = next; continue;
                }
                if (Branchy.IsMatch(d.Mnemonic))
                {
                    int? t = Target(pc, d);
                    if (d.Mnemonic.Contains('[')) { r.IndirectJump = true; break; }
                    if (t is int tt)
                    {
                        if (tt <= pc && r.Code.ContainsKey(tt) || tt <= pc && tt >= entry) r.Loops.Add((pc, tt));
                        if (op is "J" && _p.Labels.ContainsKey(tt) && !r.Code.ContainsKey(tt) && Math.Abs(tt - pc) > 0x800) { r.TailJumps.Add(tt); break; }
                        todo.Push(tt);
                    }
                    if (op is "J" or "SJ") break;       // unconditional
                }
                pc = next;
            }
        }
        Classify(r);
        return r;
    }

    int? Target(int pc, Decoded d)
    {
        string op = d.Mnemonic.Split(' ')[0];
        if (op == "VCAL" && int.TryParse(d.Mnemonic.Split(' ').Last(), out var n))
            return _p.Image[0x28 + n * 2] | _p.Image[0x29 + n * 2] << 8;
        if (d.Mnemonic.Contains("rel8")) return pc + d.Len + d.Fields.Rel8;
        if (d.Mnemonic.Contains("addr16")) return d.Fields.Addr16;
        return null;      // indirect: [DP], [[DP]], [N16[X1]]...
    }

    static readonly HashSet<string> Writers = new() { "ST", "STB", "MOV", "MOVB", "CLR", "CLRB", "INC", "INCB", "DEC", "DECB", "SB", "RB",
        "ADD", "ADDB", "SUB", "SUBB", "ADC", "ADCB", "SBC", "SBCB", "AND", "ANDB", "OR", "ORB", "XOR", "XORB", "SLL", "SLLB", "SRL", "SRLB",
        "SRA", "SRAB", "ROL", "ROLB", "ROR", "RORB", "XCHG", "XCHGB", "POPS", "SBR", "RBR" };

    void Analyse(Routine r, int pc, Decoded d, string src)
    {
        string op = d.Mnemonic.Split(' ')[0];
        var parts = Regex.Match(src, @"^\S+\s*(.*)$").Groups[1].Value.Split(',').Select(x => x.Trim()).Where(x => x.Length > 0).ToList();
        if (op is "LC" or "LCB" or "CMPC" or "CMPCB")
        {
            foreach (var part in parts.Skip(1)) if (RomRef(part) is string rd) r.RomData.Add(rd);
            return;
        }
        for (int i = 0; i < parts.Count; i++)
        {
            string part = parts[i];
            bool isBit = Regex.IsMatch(part, @"\.\d$");
            bool written = op is "ST" or "STB" ? i == 1
                         : op == "MB" ? i == 0 && parts.Count > 1 && parts[1] == "C"
                         : Writers.Contains(op) && i == 0;
            foreach (var (kind, name) in Refs(part))
            {
                string tag = name + (isBit ? "" : "");
                switch (kind)
                {
                    case "sfr": r.Sfr.Add(tag + (written ? " (write)" : " (read)")); break;
                    case "ram": (written ? r.RamWrite : r.RamRead).Add(tag); break;
                    case "rom": r.RomData.Add(tag); break;
                }
                if (isBit) r.Bits.Add(part + (written ? " (write)" : " (read)"));
            }
        }
        if (op is "MOV" && parts.Count == 2 && (parts[0] is "X1" or "X2" or "DP") && parts[1].StartsWith('#') && RomRef(parts[1][1..]) is string tbl)
            r.RomData.Add(tbl + " (pointer)");
    }

    string? RomRef(string part)
    {
        var m = Regex.Match(part, @"[A-Za-z_]\w*");
        if (m.Success && _p.TryResolve(m.Value, out var a) && a >= 0x38 && a < Bus.RomSize && !_p.IsCode(a) &&
            _p.Asm?.Symbols.GetValueOrDefault(m.Value)?.Kind == SymbolKind.Label) return m.Value;
        var n = Regex.Match(part, @"\b0*([0-9A-Fa-f]{3,4})h\b");
        return n.Success ? n.Value : null;
    }

    IEnumerable<(string Kind, string Name)> Refs(string part)
    {
        var asm = _p.Asm;
        // symbols
        foreach (Match m in Regex.Matches(part, @"\b[A-Za-z_]\w*\b"))
        {
            var w = m.Value;
            if (Regex.IsMatch(w, @"^(A|C|r[0-7]|er[0-3]|X1|X2|DP|USP|SSP|LRB|PSWH|PSWL|off)$", RegexOptions.IgnoreCase)) continue;
            if (Regex.IsMatch(w, @"^[0-9A-Fa-f]+h$")) continue;
            if (OkiAssembler.Sfrs.ContainsKey(w.ToUpperInvariant())) { yield return ("sfr", w.ToUpperInvariant()); continue; }
            var s = asm?.Symbols.GetValueOrDefault(w);
            if (s == null) continue;
            if (s.Kind == SymbolKind.Sfr) yield return ("sfr", w);
            else if (s.Value < Bus.RamSize && s.Kind == SymbolKind.Equate) yield return ("ram", $"{w}({s.Value:X3}h)");
            else if (s.Kind == SymbolKind.Label && s.Value < Bus.RomSize && !_p.IsCode((int)s.Value)) yield return ("rom", w);
        }
        // numeric RAM addresses: off(0236h), (001e7h-00180h)[USP], 0d9h, 0404h, N16[X1]
        if (part.StartsWith('#')) yield break;
        var num = Regex.Match(part, @"(?<![\w#])0*([0-9A-Fa-f]{1,4})h\b");
        if (num.Success)
        {
            int v = Convert.ToInt32(num.Groups[1].Value, 16);
            bool off = part.Contains("off", StringComparison.OrdinalIgnoreCase);
            if (!off && v < 0x80 && OkiAssembler.Sfrs.FirstOrDefault(kv => kv.Value == v).Key is string sfr) yield return ("sfr", sfr);
            else if (v < Bus.RamSize) yield return ("ram", $"{v:X3}h" + (part.Contains('[') ? "[idx]" : ""));
        }
    }

    // what known hardware means, for the purpose guess
    static readonly (Regex Pattern, string Meaning)[] Hardware =
    {
        (new(@"^P0\.7"), "switches the fuel pump relay (P0.7)"),
        (new(@"^P1\.0"), "drives the VTEC solenoid (P1.0)"),
        (new(@"^P2\.[0-3]"), "selects injectors (P2.0-P2.3)"),
        (new(@"^P2\.4"), "toggles the board watchdog heartbeat (P2.4)"),
        (new(@"^P2 \(write|^P2\.[5-7]"), "sets the analog mux channel (P2.5-7)"),
        (new(@"^P4\.6"), "reads the VTEC oil-pressure switch (P4.6)"),
        (new(@"^WDT"), "services the watchdog (WDT)"),
        (new(@"^ADCR|^ADSCAN|^ADSEL"), "reads the A/D converter (sensors)"),
        (new(@"^TMR0|^TM0"), "schedules with timer 0 (injector pulse timing)"),
        (new(@"^TMR3|^TM3"), "schedules with timer 3 (ignition timing)"),
        (new(@"^TMR2|^TM2"), "reads timer 2 / its capture (crank period, engine speed)"),
        (new(@"^TMR1|^TM1"), "uses timer 1"),
        (new(@"^SRBUF|^STBUF|^SRCON|^STCON|^STTM"), "talks on the serial port (datalogging / diagnostics)"),
        (new(@"^IE \(write|^IRQ"), "masks or acknowledges interrupts"),
        (new(@"^PWM"), "sets a PWM output (idle air / boost / fan style duty)"),
        (new(@"^TRNS"), "checks the transition detectors (CYP / igniter feedback)"),
    };

    void Classify(Routine r)
    {
        var e = r.Evidence;
        var hw = r.Sfr.Concat(r.Bits).ToList();
        foreach (var (pat, meaning) in Hardware)
            if (hw.Any(h => pat.IsMatch(h)) && !e.Contains(meaning)) e.Add(meaning);
        var ops = r.Code.Values.Select(v => v.D.Mnemonic.Split(' ')[0]).ToList();
        if (r.EndsRti) e.Insert(0, "is an interrupt handler (ends with RTI)");
        if (ops.Contains("MUL") || ops.Contains("MULB")) e.Add("multiplies (scaling / correction factors)");
        if (ops.Contains("DIV") || ops.Contains("DIVB")) e.Add("divides (a ratio, e.g. rpm from a period, or an average)");
        if (r.RomData.Count > 0) e.Add($"reads ROM tables/constants ({string.Join(", ", r.RomData.Take(6))}{(r.RomData.Count > 6 ? ", ..." : "")})");
        var callNames = r.Calls.Select(c => _p.Name(c)).ToList();
        if (callNames.Any(n => Regex.IsMatch(n, "interp|lookup|table|2d", RegexOptions.IgnoreCase)) || r.RomData.Any(x => x.Contains("pointer")))
            e.Add("looks values up in maps (table interpolation)");
        if (r.Loops.Count > 0)
            e.Add(ops.Contains("JRNZ") && r.Code.Count < 8 ? "is a delay/countdown loop" : $"loops ({r.Loops.Count} back-edge{(r.Loops.Count > 1 ? "s" : "")})");
        if (r.HasBrk) e.Add("can raise a BRK trap (fault/self-test failure path)");
        if (r.IndirectJump) e.Add("dispatches through a jump table (indirect J)");
        if (r.Name.Length > 0 && !Regex.IsMatch(r.Name, @"^(sub|loc|lbl|tbl|data)_[0-9A-Fa-f]+$|^[0-9A-F]{4}h$"))
            e.Add($"its label '{r.Name}' suggests: {Regex.Replace(r.Name, "_", " ")}");
        if (r.RamWrite.Count > 0 && e.Count == 0) e.Add($"computes and stores values in RAM ({string.Join(", ", r.RamWrite.Take(5))})");
        r.Purpose = e.Count == 0 ? "no strong clues (pure computation on registers?)" : string.Join("; ", e);
    }

    /// Text report: the entry routine in detail, callees summarised to `depth`.
    public string Report(int entry, int depth, int maxInstructions, int listLines, out string listing)
    {
        var main = Walk(entry, maxInstructions);
        var sb = new StringBuilder();
        sb.AppendLine($"{main.Name} @ {entry:X4}h: {main.Code.Count} instructions reachable{(main.Truncated ? $" (stopped at {maxInstructions}; raise max_instructions)" : "")}");
        if (_p.SourceAt(entry) is { } s0) sb.AppendLine($"source: {Path.GetFileName(s0.File)}:{s0.Line}");
        sb.AppendLine();
        sb.AppendLine("LIKELY PURPOSE: " + main.Purpose);
        sb.AppendLine();
        void Set(string title, IEnumerable<string> items)
        {
            var l = items.ToList();
            if (l.Count > 0) sb.AppendLine($"{title}: {string.Join(", ", l.Take(40))}{(l.Count > 40 ? $" ... (+{l.Count - 40})" : "")}");
        }
        Set("calls", main.Calls.Select(c => $"{_p.Name(c)} ({c:X4}h)"));
        Set("tail-jumps to", main.TailJumps.Select(c => $"{_p.Name(c)} ({c:X4}h)"));
        Set("loops", main.Loops.Select(l => $"{l.From:X4}->{l.To:X4}"));
        Set("hardware (SFR)", main.Sfr);
        Set("bits", main.Bits);
        Set("RAM read", main.RamRead);
        Set("RAM written", main.RamWrite);
        Set("ROM data", main.RomData);

        if (depth > 0 && main.Calls.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("CALLEES:");
            var seen = new HashSet<int> { entry };
            void Sub(int addr, int level)
            {
                if (!seen.Add(addr) || level > depth) return;
                var r = Walk(addr, 400);
                sb.AppendLine($"{new string(' ', level * 2)}- {r.Name} ({addr:X4}h, {r.Code.Count} insns): {r.Purpose}");
                foreach (var c in r.Calls) Sub(c, level + 1);
            }
            foreach (var c in main.Calls) Sub(c, 1);
        }

        var lst = new StringBuilder();
        int? prev = null;
        foreach (var (addr, (d, text)) in main.Code)
        {
            if (prev is int pv && addr != pv) lst.AppendLine("        ...");
            string label = _p.Labels.TryGetValue(addr, out var lb) ? lb + ":" : "";
            string dd = d.DdAfter is bool v ? (v ? " dd=1" : " dd=0") : "";
            string bytes = string.Concat(Enumerable.Range(0, d.Len).Select(i => _p.Image[(addr + i) & 0x7FFF].ToString("X2")));
            string note = "";
            if (d.Mnemonic.StartsWith("CAL") || d.Mnemonic.StartsWith("SCAL") || d.Mnemonic.StartsWith("VCAL"))
                note = Target(addr, d) is int t ? $"   -> {_p.Name(t)}" : "";
            lst.AppendLine($"{addr:X4}  {bytes,-12} {label,-26} {text}{note}{dd}");
            prev = addr + d.Len;
        }
        listing = lst.ToString();
        var lines = listing.Split('\n');
        sb.AppendLine();
        sb.AppendLine($"LISTING (address, bytes, label, instruction; dd= where it changes the data width){(lines.Length > listLines ? $" - first {listLines} of {lines.Length} lines" : "")}:");
        sb.Append(string.Join("\n", lines.Take(listLines)));
        return sb.ToString();
    }
}
