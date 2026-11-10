using OkiRomSim.Calibration;
// Hts120Build: roms/HTS115.asm -> roms/HTS120.asm, one checked stage at a time.
//
//   Hts120Build [--stage N] [--out path]
//
// Every stage is a transformation of the source text. After each one the file is assembled; the
// stages that are only meant to make the source relocatable must reproduce HTS115's bytes exactly.
using Hts120Build;
using OkiRomSim.Core;

var root = FindRoot();
var src = Path.Combine(root, "roms", "HTS115.asm");
var outPath = args.SkipWhile(a => a != "--out").Skip(1).FirstOrDefault() ?? Path.Combine(root, "roms", "HTS120.asm");
int lastStage = args.SkipWhile(a => a != "--stage").Skip(1).Select(int.Parse).FirstOrDefault(99);

ProcessorProfile.Msm66207().Apply();
var doc = new Doc(outPath, File.ReadAllLines(src));
var reference = doc.AssembleOrThrow("HTS115").Image;
void Same(string stage)
{
    var img = doc.AssembleOrThrow(stage).Image;
    int diff = Enumerable.Range(0, img.Length).Count(i => img[i] != reference[i]);
    if (diff != 0) throw new Exception($"{stage}: {diff} bytes differ from HTS115 - a stage that must not change the image did");
    Console.WriteLine($"  {stage}: image unchanged");
}

// ---------------------------------------------------------------- stage 1: the serial state machine
if (lastStage >= 1)
{
    Console.WriteLine("stage 1: serial/datalog code back from DB bytes");
    var img = doc.AssembleOrThrow("stage 1").Image;
    const int Table = 0x51C1;
    var entries = new List<(int, bool)>();
    for (int i = 0; i < 16; i++) entries.Add((img[Table + 2 * i] | img[Table + 2 * i + 1] << 8, true));
    // every "MOV er0, #addr" (44 98 lo hi) whose addr is in the serial block is a continuation
    for (int a = 0x38; a + 3 < 0x5F14; a++)
        if (img[a] == 0x44 && img[a + 1] == 0x98)
        {
            int v = img[a + 2] | img[a + 3] << 8;
            if (v >= 0x5000 && v < 0x51C1) entries.Add((v, true));
        }
    int n = Symbolize.Run(doc, entries.Distinct(), (0x5000, 0x51C1), "serial");
    Console.WriteLine($"  {n} instructions recovered");
    Same("stage 1 decode");

    // the command dispatch table: DB bytes -> DW of the handlers
    var r = doc.AssembleOrThrow("stage 1");
    var names = r.Symbols.Values.Where(s => s.Kind == OkiRomSim.Assembler.SymbolKind.Label)
        .GroupBy(s => (int)s.Value).ToDictionary(g => g.Key, g => g.First().Name);
    Tables.ToDw(doc, Table, 16, names, "serial_cmd_table");
    Same("stage 1 dispatch table");
    // continuation addresses written as immediates in code that was already disassembled
    var conts = entries.Select(e => e.Item1).Distinct().Where(names.ContainsKey).ToDictionary(a => a, a => names[a]);
    int li = Symbolize.LabelImmediates(doc, conts, code => System.Text.RegularExpressions.Regex.IsMatch(code, @"\b(MOV\s+(er\d|DP|X1|X2)|L\s+A)\s*,"));
    Console.WriteLine($"  {li} continuation immediates now labels");
    Same("stage 1 labels");
}

// ---------------------------------------------------------------- stage 2: table pointers written as numbers
if (lastStage >= 2)
{
    Console.WriteLine("stage 2: numeric table pointers -> labels");
    var ptr = new System.Text.RegularExpressions.Regex(@"\b(MOV\s+(er\d|DP|X1|X2)|L\s+A)\s*,", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    foreach (var (addr, name) in new[] {
        (0x51C1, "serial_cmd_table"),           // command dispatch (stage 1 made it DW)
        (0x522F, "serial_c0_table"),            // C0h+n single-byte requests: RAM address per n
        (0x5205, "serial_frame_table"),         // the multi-byte frame layout
        (0x4FF7, "tbl_knockwindow_alt"),        // knock window, alternate (0x21F.1) - next to tbl_ignmap2
        (0x5003, "tbl_ect_knock_scale") })      // read with 0D9h (ECT) through table_interp_lookup
    {
        var used = Labels.At(doc, addr, name);
        int n = Labels.Refer(doc, addr, used, ptr);
        Console.WriteLine($"  {addr:X4} {used}: {n} reference(s)");
    }
    Same("stage 2");
}

// ---------------------------------------------------------------- stage 3: dead code out, calibration pinned
// From here the image changes. Calibration keeps its HTS 1.15 addresses (org 05F14h) so the maps are
// where every tuner expects them; the code shrinks towards 003Ch and what it gives up collects in one
// block in front of the calibration, where HTS120's own code goes.
if (lastStage >= 3)
{
    Console.WriteLine("stage 3: dead code and filler out, calibration pinned at 5F14h");
    int cal = Layout.LineAt(doc, 0x5F14);
    doc.Lines.InsertRange(cal, [
        "",
        "; ============================================================================================",
        "; HTS120 code. Everything the cleanup freed ends up here, in front of the calibration, which",
        "; stays at its HTS 1.15 addresses.",
        "; ============================================================================================",
        "hts120_code:",
        "hts120_code_end:",
        "                org 05F14h        ; calibration: same addresses as HTS 1.15",
    ]);
    // nothing reaches these: each follows an RT, no label, no branch, no pointer anywhere in the image
    foreach (var (lo, hi, what) in new[] {
        (0x5408, 0x5416, "orphan routine (PUSHS A; CAL 5373h; CAL 537Eh; POPS A; RT)"),
        (0x51E1, 0x5205, "orphan frame table and its pointers (51E7h/5205h/522Dh), read by nothing"),
        (0x5017, 0x503A, "FF filler"),
        (0x4B52, 0x4B80, "orphan routine after clamp_range_store"),
        (0x4B12, 0x4B2F, "orphan routine after knock_244_helper") })
    {
        Layout.RemoveBytes(doc, lo, hi);
        Console.WriteLine($"  {lo:X4}-{hi - 1:X4} {hi - lo,3} bytes: {what}");
    }
    var r3 = doc.AssembleOrThrow("stage 3");
    Console.WriteLine($"  free code space: {0x5F14 - Sym(r3, "hts120_code")} bytes at {Sym(r3, "hts120_code"):X4}");
}

// ---------------------------------------------------------------- stage 4: J -> SJ where it reaches
if (lastStage >= 4)
{
    Console.WriteLine("stage 4: cfgvariant sign checks as a table; long jumps and calls that fit in 8 bits become SJ/SCAL");
    if (!args.Contains("--no-cfgtable"))
    {
        var before = doc.AssembleOrThrow("stage 4");
        int a = doc.Lines.FindIndex(l => l.StartsWith("cfgvariant_check_v3:"));
        int b = doc.Lines.FindIndex(l => l.StartsWith("cfgvariant_eval_result:"));
        if (a < 0 || b < a) throw new Exception("cfgvariant sign-check chain not where expected");
        doc.Lines.RemoveRange(a, b - a + 1);
        doc.Lines.InsertRange(a, [
            "cfgvariant_check_v3:     MOV     DP, #cfgvariant_sign_inputs",
            "; --- Variants 3, 6, 7, 10, 11, 13, 20 and 26 each test the sign bit of one input byte (0xBB,",
            "; 0x3D4, 0x3A4, 0x3CC, 0x3D2, 0x3CD, 0x3D2 again, 0xD7) and count a set one in r0 -- a",
            "; per-variant \"is this variant's input plausible/connected\" check feeding cfgvariant_eval_result.",
            "; HTS 1.15 spelled it out as one 15-byte compare-and-test block per variant; HTS120 walks",
            "; cfgvariant_sign_inputs (variant, input address) instead. Same tests, same order; any other",
            "; variant goes on to cfgvariant_check_v4 as before. (DP is dead here: the next routine reloads it.)",
            "cfgvariant_sign_next:     LCB     A, [DP]",
            "                JEQ     cfgvariant_check_v4",
            "                INC     DP",
            "                CMPB    r6, A           ; (not CMPB A,r6: LCB leaves DD as it was)",
            "                JEQ     cfgvariant_sign_test",
            "                INC     DP",
            "                INC     DP",
            "                SJ      cfgvariant_sign_next",
            "cfgvariant_sign_test:     LC      A, [DP]",
            "                MOV     DP, A",
            "                LB      A, [DP]",
            "                SLLB    A",
            "                JGE     cfgvariant_eval_result",
            "                INCB    r0",
            "cfgvariant_eval_result:     J       cfgvariant_remap_start",
            "cfgvariant_sign_inputs:  DB  003h",
            "                DW  000bbh",
            "                DB  006h",
            "                DW  003d4h",
            "                DB  007h",
            "                DW  003a4h",
            "                DB  00ah",
            "                DW  003cch",
            "                DB  00bh",
            "                DW  003d2h",
            "                DB  00dh",
            "                DW  003cdh",
            "                DB  014h",
            "                DW  003d2h",
            "                DB  01ah",
            "                DW  000d7h",
            "                DB  000h            ; end: not one of these variants",
        ]);
        var after = doc.AssembleOrThrow("stage 4");
        Console.WriteLine($"  cfgvariant sign checks: {Sym(before, "hts120_code") - Sym(after, "hts120_code")} bytes saved");
    }
    {
        // the code-number remap (19h->23h, 1Ah->24h, 1Bh->29h, 1Dh->2Bh, i.e. 25->35, 26->36, 27->41,
        // 29->43) was written out twice: in the code-flash routine and in the code store. One copy now.
        var before = doc.AssembleOrThrow("stage 4 remap");
        int ReplaceChain(string startsWith, string endLabel, int skip)
        {
            int a = doc.Lines.FindIndex(l => l.StartsWith(startsWith)) + skip;
            int b = doc.Lines.FindIndex(a, l => l.StartsWith(endLabel + ":"));
            if (a < skip || b < 0 || !System.Text.RegularExpressions.Regex.IsMatch(Doc.Body(doc.Lines[a]), @"^CMPB\s+A,\s*#01[9d]h$", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                throw new Exception($"code remap chain at {startsWith} not as expected");
            doc.Lines.RemoveRange(a, b - a);
            doc.Lines.Insert(a, "                CAL     code_remap                     ; 25->35, 26->36, 27->41, 29->43");
            return b - a;
        }
        ReplaceChain("cfgvariant_remap_start:", "cfgvariant_remap_store", 2);
        ReplaceChain("percyl_wrap_check1:", "percyl_bcd_convert", 1);
        int end = doc.Lines.FindIndex(l => l.StartsWith("hts120_code_end:"));
        doc.Lines.InsertRange(end, [
            "; code_remap: the ROM numbers its codes by stored index + 1 but flashes four of them as other",
            "; codes (25->35, 26->36, 27->41, 29->43). Shared by the code store and the code-flash routine.",
            "code_remap:     CMPB    A, #019h",
            "                JNE     code_remap_1a",
            "                LB      A, #023h",
            "                RT",
            "code_remap_1a:  CMPB    A, #01ah",
            "                JNE     code_remap_1b",
            "                LB      A, #024h",
            "                RT",
            "code_remap_1b:  CMPB    A, #01bh",
            "                JNE     code_remap_1d",
            "                LB      A, #029h",
            "                RT",
            "code_remap_1d:  CMPB    A, #01dh",
            "                JNE     code_remap_done",
            "                LB      A, #02bh",
            "code_remap_done: RT",
            "",
        ]);
        var after = doc.AssembleOrThrow("stage 4 remap");
        Console.WriteLine($"  code remap shared: {Sym(before, "hts120_code") - Sym(after, "hts120_code")} bytes saved");

        // inj_accum_direct_add2 ended with the same four instructions as inj_accum1_store_new
        int t = doc.Lines.FindIndex(l => l.StartsWith("inj_accum_direct_add2:"));
        var tail = doc.Lines.Skip(t + 2).Take(4).Select(Doc.Body).ToList();
        if (!System.Text.RegularExpressions.Regex.IsMatch(string.Join("|", tail), @"^ST\s+A,\s*off\(00110h\)\|L\s+A,\s*#00001h\|ST\s+A,\s*off\(00112h\)\|S?J\s+inj_accum_store_114$", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            throw new Exception("inj_accum_direct_add2 tail not as expected: " + string.Join(" | ", tail));
        doc.Lines.RemoveRange(t + 2, 4);
        doc.Lines.Insert(t + 2, "                SJ      inj_accum1_store_new    ; same four instructions as there");
        var merged = doc.AssembleOrThrow("stage 4 tail");
        Console.WriteLine($"  inj_accum tail merged: {Sym(after, "hts120_code") - Sym(merged, "hts120_code")} bytes saved");
    }
    var (nj, nc) = args.Contains("--no-relax") ? (0, 0) : Relax.Run(doc, args.Contains("--timing-control"));
    var r4 = doc.AssembleOrThrow("stage 4");
    Console.WriteLine($"  {nj} jumps and {nc} calls shortened; free code space now {0x5F14 - Sym(r4, "hts120_code")} bytes");
}

// ---------------------------------------------------------------- stage 5: bug fixes
if (lastStage >= 5)
{
    Console.WriteLine("stage 5: bug fixes");
    // Post-ignition limit (ignmap2): with the high cam engaged (127h.1) the table pointer was
    // 4F6Ch/4F60h - bytes in the middle of boot_flag code, so the VTEC-side limit was interpolated
    // out of opcodes. P30/P08 have no high-cam alternative at all: use the real tables for both cams.
    Edit.Replace(doc, @"^MOV\s+X1,\s*#04f6ch$", null);
    Edit.Replace(doc, @"^JBS\s+off\(00127h\)\.1,\s*ignmap2_table_select$", null);
    Edit.Replace(doc, @"^MOV\s+X1,\s*#04f60h$", null);
    Edit.Replace(doc, @"^JBS\s+off\(00127h\)\.1,\s*ignmap2_rpm_gate$", null);
    Console.WriteLine("  ignmap2: high-cam pointers into code removed, both cams use tbl_ignmap2_hi/lo");
    // "IGN1_Lo_Extended" / "FUEL1_Hi_Extended" as immediates are numbers that happen to equal those
    // tables' addresses (a VSS timeout period, a fuel-trim floor). Calibration does not move, so the
    // bytes are right either way, but the names were wrong.
    var r5 = doc.AssembleOrThrow("stage 5");
    foreach (var n in new[] { "IGN1_Lo_Extended", "FUEL1_Hi_Extended" })
    {
        int v = Sym(r5, n);
        int k = Edit.ReplaceAll(doc, @"(L\s+A|MOV\s+X2),\s*#" + n + @"\b", m => m.Groups[1].Value + $", #0{v:X4}h");
        Console.WriteLine($"  #{n} -> #0{v:X4}h ({k} site(s)): a number, not the table");
    }
}

// ---------------------------------------------------------------- stage 6: HTS120 features
if (lastStage >= 6)
{
    Console.WriteLine("stage 6: speed correction, traction control, speed/gear rpm caps, anti-start, limiter catch code");
    // the calibration block goes into the unused FF bytes at the head of the calibration area
    // (size: what Features.Calibration assembles to)
    Layout.RemoveBytes(doc, 0x5F14, 0x5F14 + 47);
    int org = doc.Lines.FindIndex(l => l.Contains("org 05F14h"));
    doc.Lines.InsertRange(org + 1, Features.Calibration);
    // the 40h datalog packet's list, in the unused FF bytes at 5F60h (calibration area: data, not code)
    Layout.RemoveBytes(doc, 0x5F60, 0x5F6A);
    doc.Lines.InsertRange(Layout.LineAt(doc, 0x5F60), [
        "; ---- HTS120 datalog packet (command 40h): RAM addresses, one byte each, 0 ends; checksum follows",
        "hts120_log_table:   DW  000FCh,000FDh,0024Fh,0006Fh,00000h ; TC retard (0.25 deg), HTS120 status (bit 7 anti-start locked), gear, TPS converter (ADCR7H)",
    ]);
    // command 40h (a free slot: HTS 1.15 answered EEh) streams it the way 20h streams serial_c0_table
    int slot = doc.Lines.FindIndex(l => Doc.Body(l) == "DW  serialtx_error_ee" && l.Contains("; 51C9"));
    if (slot < 0) throw new Exception("command table slot 4 not found");
    doc.Lines[slot] = "                DW  serial_cmd_hts120             ; 51C9 (40h: was serialtx_error_ee)";
    int s515e = doc.Lines.FindIndex(l => l.StartsWith("serial_515E:"));
    if (!Doc.Body(doc.Lines[s515e + 1]).StartsWith("SJ serial_5154")) throw new Exception("serial_515E not as expected");
    doc.Lines.InsertRange(s515e + 2, [
        "serial_cmd_hts120: MOV er1, #hts120_log_table     ; HTS120: 40h -> TC/anti-start datalog packet + checksum",
        "                SJ serial_5154",
    ]);

    // hooks: each is one existing call or load pointed somewhere else
    Edit.Replace(doc, @"^CAL\s+doubleup_limiter_target$", "CAL     hts_limiter");
    Edit.Replace(doc, @"^CAL\s+gearcorrect_ign_check$", "CAL     hts_tc_apply", label: "ignmap_lookup_done");
    Edit.Replace(doc, @"^CAL\s+ResetWatchDog$", "CAL     hts_tick", label: "vcal3_main_task");
    Edit.Replace(doc, @"^LCB\s+A,\s*KillInjectors$", "CAL     hts_kill_check", label: "killinjectors_override");
    {
        // the speed division moves into hts_vss_speed (9 bytes out, a 3-byte CAL in: the VSS routine's
        // own short branches keep their reach)
        int i = doc.Lines.FindIndex(l => System.Text.RegularExpressions.Regex.IsMatch(Doc.Body(l), @"^L\s+A,\s*#vssSpeedNumerator$", System.Text.RegularExpressions.RegexOptions.IgnoreCase));
        if (!System.Text.RegularExpressions.Regex.IsMatch(Doc.Body(doc.Lines[i - 1]), @"^MOV\s+er0,\s*#00003h$") || Doc.Body(doc.Lines[i + 1]) != "DIV")
            throw new Exception("VSS speed division not as expected");
        doc.Lines[i - 1] = "                CAL     hts_vss_speed          ; HTS120: speed = 25FB4h / period x SpeedCorrection / 8000h";
        doc.Lines.RemoveRange(i, 2);
    }

    // the code goes into the space the cleanup freed
    int end = doc.Lines.FindIndex(l => l.StartsWith("hts120_code_end:"));
    doc.Lines.InsertRange(end, Features.Code);

    // the new code and the shorter stage 5 paths give the relaxation another go
    var (j6, c6) = Relax.Run(doc);
    Console.WriteLine($"  relaxed again: {j6} jumps, {c6} calls");
    // the header: what this file is, and the 1.15 note the catch code has now answered
    int note = doc.Lines.FindIndex(l => l.Contains("\"Double-up limiter\" / catch-code redirect"));
    if (note >= 0) doc.Lines.RemoveRange(note, 2);
    doc.Lines.InsertRange(0, [
        "; ================================================================================================",
        "; HTS120 - generated from HTS115.asm by tools/hts120/Hts120Build (edit that, not this file).",
        ";",
        "; Calibration keeps its HTS 1.15 addresses (5F14h-7FFFh); code does not, so HTS 1.15/1.20 tuning",
        "; software, which loads its own base code over a ROM, must not be used on it.",
        "; Adds traction control from engine speed, rpm ceilings by gear and road speed, anti-start, a speed",
        "; limiter by switch and a 40h datalog packet, all off by default. <end>",
        ";",
        "; Fixes",
        ";   - Rev limiter \"catch code\" (HTS Rom.cs): while the ignition cut runs, the resume limit counts.",
        ";   - Post-ignition limit (ignmap2) read its high-cam tables from 4F6Ch/4F60h - the middle of",
        ";     boot_flag code. Both cams now use tbl_ignmap2_hi/lo, as P30/P08 do.",
        ";   - Not applied: HTS's \"VE map scaler\" write at 6DFFh. The table there is live (vcal_0, 3-byte",
        ";     entries, FFh sentinel) and HTS's check for \"unset\" matches it; the write would wreck it.",
        ";   (GIO1 trigger 5586h and LeanProtect2 5B17h were already fixed in HTS115.asm.)",
        "; Cleanup",
        ";   - 125 bytes of unreachable code/data and 35 of filler out; the serial/datalog state machine",
        ";     disassembled from DB bytes; cfgvariant sign checks as a table; long branches shortened.",
        ";     All of it lands as one free block in front of the calibration (hts120_code).",
        "; Features (all off / neutral by default; calibration at 5F14h-5F40h)",
        ";   - SpeedCorrection: road speed x value / 8000h.",
        ";   - Traction control from engine speed alone (TcEnable...): hts_tick / hts_tc_apply.",
        ";   - Rpm ceilings by road speed and by gear (LimitBySpeed / LimitByGear): hts_limiter.",
        ";   - Anti-start: locked at power-up (fuel and spark cut) until the A/C",
        ";     switch is on with the throttle past AntiStartTps.",
        ";   - Speed limiter by switch: fuel and spark cut at SwLimitSpeed while a chosen switch is on.",
        ";   - Datalog command 40h: TC retard, HTS120 status, gear, raw TPS + checksum (hts120_log_table);",
        ";     the 51-byte 20h/90h frames are untouched, so existing loggers still work.",
        "; RAM used: 0FCh-0FFh, 388h-38Fh (LRB 71h) - untouched by HTS 1.15.",
        "; ================================================================================================",
        "",
    ]);
    var r6 = doc.AssembleOrThrow("stage 6");
    int used = Sym(r6, "hts120_code_end") - Sym(r6, "hts120_code");
    int free = 0x5F14 - Sym(r6, "hts120_code_end");
    Console.WriteLine($"  HTS120 code {used} bytes at {Sym(r6, "hts120_code"):X4}, {free} bytes left free before the calibration");
    if (free < 0) throw new Exception("HTS120 code runs into the calibration");
}

// ---------------------------------------------------------------- relocation test build (not HTS120 itself)
if (args.SkipWhile(a => a != "--shift-test").Skip(1).FirstOrDefault() is string shiftOut)
{
    var t = new Doc(shiftOut, doc.Lines);
    int cal = Layout.LineAt(t, 0x5F14);
    t.Lines.Insert(cal, "                org 05F14h        ; calibration stays where it was");
    Layout.RemoveBytes(t, 0x5017, 0x503A);
    int code = Layout.LineAt(t, 0x003C);
    t.Lines.Insert(code, "                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; relocation test filler");
    t.AssembleOrThrow("shift test");
    t.Save();
    Console.WriteLine($"wrote relocation test build {shiftOut}");
}

// ---------------------------------------------------------------- stage 6b: fixes to HTS 1.15's own code
// Found by the review (tools/skeleton/SkeletonTest --review): the same size, so nothing moves.
if (lastStage >= 6)
{
    Console.WriteLine("stage 6b: fixes");
    // ErrorchkECT (code 6 check off) jumped to dtc06_ect_latch with whatever carry the MAP check left: code 6 was set at
    // random, and with SCCInvert on the stored-code check trapped (BRK 43h) over and over. The IAT switch next to it
    // already goes to its fault stamp; the ECT one now does the same: the fixed ECT, code 6 left alone.
    Edit.Replace(doc, @"^JNE\s+dtc06_ect_latch$", "JNE     ect_fault_stamp");
    doc.AssembleOrThrow("stage 6b");
}

// ---------------------------------------------------------------- stage 7: definition annotations
if (lastStage >= 7)
{
    Console.WriteLine("stage 7: ;@ definition annotations");
    var before = doc.AssembleOrThrow("stage 7").Image;
    // the stock ROMs whose tables are defined: what HTS120's RAM inputs are, for the input axes of its tables
    var sk = Skeleton.Load(Path.Combine(root, "roms", "p30-skeleton.asm"));
    var refs = new[]
    {
        RomReference.FromFile(sk.Path, sk.Features.Where(f => f.Stock).ToDictionary(f => f.Define, _ => 1L)),
        RomReference.FromFile(Path.Combine(root, "roms", "p72-269.asm")),
    }.Where(r => r != null).Select(r => r!).ToList();
    var (items, bound) = Annotate.Run(doc, refs);
    var after = doc.AssembleOrThrow("stage 7").Image;
    if (!before.SequenceEqual(after)) throw new Exception("annotations changed the image");
    Console.WriteLine($"  {items} settings and tables defined, {bound} bound to feature page rows");
}

doc.Save();
Console.WriteLine($"wrote {outPath}");
// File > New ROM offers the Templates folder: keep its HTS120 the one just built
if (lastStage >= 7 && Path.GetFileName(outPath).Equals("HTS120.asm", StringComparison.OrdinalIgnoreCase))
{
    var templates = Path.Combine(root, "Templates");
    Directory.CreateDirectory(templates);
    File.Copy(outPath, Path.Combine(templates, "HTS120.asm"), overwrite: true);
    Console.WriteLine($"copied to {Path.Combine(templates, "HTS120.asm")}");
}
return 0;

static int Sym(OkiRomSim.Assembler.AssemblyResult r, string name) =>
    (int)r.Symbols.Values.First(s => s.Name.Equals(name, StringComparison.OrdinalIgnoreCase)).Value;

static string FindRoot()
{
    var d = AppContext.BaseDirectory;
    while (d != null && !Directory.Exists(Path.Combine(d, "roms"))) d = Path.GetDirectoryName(d);
    return d ?? throw new Exception("cannot find the repository root (a folder with roms/)");
}
