// SkeletonTest: builds roms/p30-skeleton.asm with its feature modules and drives the result through the
// simulator, checking that every module builds alone and together, keeps the checksum, leaves the engine
// alone with its default calibration, and does what it says once it is switched on.
//
//   SkeletonTest [--only name]
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

// SKEL=p13: the same checks on roms/p13-skeleton.asm (every module offered, whatever its "platforms:" line says, on the MSM66911)
bool onP13 = Environment.GetEnvironmentVariable("SKEL") is { } skelEnv && skelEnv.Equals("p13", StringComparison.OrdinalIgnoreCase);
if (onP13) ProcessorProfile.Msm66911().Apply(); else ProcessorProfile.Msm66207().Apply();
var root = FindRoot();
// SKEL_FILE=path: that skeleton instead (a snapshot, so the files can be edited while a long run goes on)
var sk = onP13 ? Skeleton.Load(Environment.GetEnvironmentVariable("SKEL_FILE") ?? Path.Combine(root, "roms", "p13-skeleton.asm"), anyPlatform: true) : Skeleton.Load(Path.Combine(root, "roms", "p30-skeleton.asm"));
Platform.P13 = onP13;
// --asmhash file: assemble a source on the current profile (SKEL=p13: the 66911's) and print its image's hash, its errors and
// how many annotations the app makes of it (a comments-only change must leave the hash as it was)
if (args.Contains("--asmhash"))
{
    var file = args.SkipWhile(a => a != "--asmhash").Skip(1).First();
    var ar = new OkiAssembler().AssembleFile(Path.GetFullPath(file));
    Console.WriteLine($"{file}: {(ar.Success ? "ok" : "FAILED " + string.Join(" | ", ar.Diagnostics.Where(d => d.Severity == Severity.Error).Take(3)))}, sha256 {Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(ar.Image))[..16]}, " +
                      $"{(ar.Success ? DefinitionBuilder.FromAssembly(ar, "hash").Items.Count : 0)} items");
    if (ar.Success && Environment.GetEnvironmentVariable("PROBE_ITEMS") is { } pis)
    {
        var dh = DefinitionBuilder.FromAssembly(ar, "hash");
        foreach (var n in pis.Split(','))
            Console.Write(dh.Items.FirstOrDefault(i => i.Name == n) is { } it ? RomData.Render(dh, ar.Image, it) : $"  {n}: not defined\n");
    }
    return 0;
}
if (args.Contains("--offcheck")) return OffCheck.Run(sk);
if (args.Contains("--hwone")) return HwCheck.One(sk, [.. args.SkipWhile(a => a != "--hwone").Skip(1)]);
if (args.Contains("--hwcheck")) return HwCheck.Main(sk, int.Parse(args.SkipWhile(a => a != "--hwcheck").Skip(1).FirstOrDefault(x => !x.StartsWith("--")) ?? "16"));
if (args.Contains("--pairs")) return HwCheck.Pairs(sk, args.Contains("--quick"));
if (args.Contains("--limitscheck")) return LimitsCheck.Run(sk, root);
if (args.Contains("--docs")) return Docs.Write(sk, args.SkipWhile(a => a != "--docs").Skip(1).FirstOrDefault() ?? Path.Combine(root, "Website", "docs", Platform.P13 ? "modules-p13.html" : "modules.html"));
if (args.Contains("--advice"))
{
    // what File > New ROM > Create says about a pick, and its module RAM: --advice [stock] DEFINE...
    var pick = new List<string>();
    foreach (var a in args.SkipWhile(a => a != "--advice").Skip(1))
        if (a == "stock") pick.AddRange(sk.Features.Where(f => f.Stock).Select(f => f.Define)); else pick.Add(a);
    var b = sk.Build(pick);
    Console.WriteLine($"{(b.Success ? "builds" : "FAILS")}, {b.FreeBytes} bytes free");
    if (b.Ram is { } ram)
    {
        Console.WriteLine($"module RAM {ram.Base:X3}h-{ram.End - 1:X3}h: {ram.Used} of {ram.Size} used{(ram.Full ? " FULL" : "")}");
        foreach (var u in ram.Uses) Console.WriteLine($"  {u.Start:X3}h {u.Bytes,3} B {u.Owner}");
    }
    foreach (var a in SkeletonAdvice.Check(sk, pick, b)) Console.WriteLine($"  {a.Level,-7} {a.Title}: {a.Detail}");
    return 0;
}
if (args.Contains("--testroms") || args.Contains("--testromsfile") || args.Contains("--testroms2") || args.Contains("--testroms3") || args.Contains("--testroms4"))
{
    // ten ROMs for the real ECU, each a different set of modules: --testroms <folder>
    var outDir = args.Contains("--testromsfile") ? Path.GetFullPath(args.SkipWhile(a => a != "--testromsfile").Skip(2).FirstOrDefault() ?? "TestRomsX")
        : args.SkipWhile(a => a != "--testroms" && a != "--testroms2" && a != "--testroms3" && a != "--testroms4").Skip(1).FirstOrDefault() ?? Path.Combine(root, args.Contains("--testroms4") ? "TestRoms4" : args.Contains("--testroms3") ? "TestRoms3" : args.Contains("--testroms2") ? "TestRoms2" : "TestRoms");
    Directory.CreateDirectory(outDir);
    string[] def4 = ["FEAT_STOCK_DTC", "FEAT_STOCK_SELFTEST", "FEAT_DATALOG", "FEAT_ECTPRO"];
    string[] Stock() => [.. sk.Features.Where(f => f.Stock).Select(f => f.Define)];
    var sets = new (string Name, string Why, string[] Defs)[]
    {
        ("bare", "The skeleton and nothing else: no stock functions, no modules. If this fails the problem is the skeleton itself or the board.", []),
        ("stock", "Every stock function put back, no modules. The known-good reference (this booted before).", Stock()),
        ("defaults", "What File > New ROM > Create ticks for you: trouble codes, self-tests, datalogging, coolant protection.", def4),
        ("limiters", "Defaults + rev limiter, launch control, full throttle shift, ignition cut modifier. All share the cut-request bytes and cut fuel or spark.", [.. def4, "FEAT_REVLIMIT", "FEAT_LAUNCH", "FEAT_FTS", "FEAT_IGNCUTMOD"]),
        ("fuelign", "Defaults + fuel and timing modules: injector trim, tip-in retard, cylinder trims, 20-column maps. These run inside the fuel and ignition calculation.", [.. def4, "FEAT_FUELTRIM", "FEAT_TPSRETARD", "FEAT_CYLTRIM", "FEAT_EXTMAPS"]),
        ("outputs", "Defaults + modules that drive pins: shift light, tach output, rpm switch, GIO 1, intake butterflies.", [.. def4, "FEAT_SHIFTLIGHT", "FEAT_TACH", "FEAT_RPMSWITCH", "FEAT_GIO1", "FEAT_IAB"]),
        ("sensors", "Defaults + gear detection, road speed correction, TPS end points, anti-stall, rolling idle. Sensor reading and idle control.", [.. def4, "FEAT_GEAR", "FEAT_SPEEDCORR", "FEAT_TPSCAL", "FEAT_ANTISTALL", "FEAT_ROLLIDLE"]),
        ("boost", "Defaults + electronic boost control, water/methanol injection, boost cut. Software PWM outputs.", [.. def4, "FEAT_EBC", "FEAT_WMI", "FEAT_BOOSTCUT"]),
        ("protect", "Defaults + service-command datalogging, lean protection, anti-start, warning lamp. The serial link and the protections.", [.. def4, "FEAT_DLSERVICE", "FEAT_LEANPRO", "FEAT_ANTISTART", "FEAT_WARNLAMP"]),
        ("bigmix", "Every stock function except the stock serial link (datalogging needs that port) plus datalogging, coolant protection, rev limiter, shift light, fuel trim and gear detection: a full-size build.", [.. Stock().Where(d => d != "FEAT_STOCK_SERIAL"), "FEAT_DATALOG", "FEAT_ECTPRO", "FEAT_REVLIMIT", "FEAT_SHIFTLIGHT", "FEAT_FUELTRIM", "FEAT_GEAR"]),
    };
    // "All modules" as File > New ROM > Create ticks it, then that with a part taken out
    var allMods = new List<string>();
    foreach (var f in sk.Features) if (!f.Stock && sk.Problems([.. allMods, f.Define]).Count == 0) allMods.Add(f.Define);
    string[] Without(Func<SkeletonFeature, bool> drop)
    {
        var keep = allMods.Where(d => !drop(sk.Feature(d)!)).ToList();
        for (bool again = true; again;)
        {
            again = false;
            foreach (var d in keep.ToList())
                if (sk.Feature(d)!.Requires.Any(r => !keep.Contains(r, StringComparer.OrdinalIgnoreCase))) { keep.Remove(d); again = true; }
        }
        return [.. keep];
    }
    string[] Only(Func<SkeletonFeature, bool> take) => [.. allMods.Where(d => take(sk.Feature(d)!))];
    int half = allMods.Count / 2;
    var sets2 = new (string Name, string Why, string[] Defs)[]
    {
        ("allmodules", "Exactly what New ROM > Create > All modules gives (the ROM that does not run).", [.. allMods]),
        ("no_outputs", "All modules without the Outputs group (shift light, IAB, rpm switch, GIO 1-4, VTEC control, tach, smart alternator, A/C cut).", Without(f => f.Category == "Outputs")),
        ("no_limits", "All modules without the Limits group (rev limiter, launch, full throttle shift, burnout, speed limiter, ceilings, gear limit, ignition cut modifier).", Without(f => f.Category == "Limits")),
        ("no_fuel", "All modules without the Fuel group (wideband closed loop, flex fuel, fuel trim, gear fuel, map switch, extended maps, dual maps, cyl trim, alpha-N).", Without(f => f.Category == "Fuel")),
        ("no_datalog", "All modules without datalogging (the serial link is untouched by any module).", Without(f => f.Category == "Diagnostics")),
        ("no_boost_protect", "All modules without Boost and Protection (boost control, WMI, boost cut, coolant, lean, anti-start).", Without(f => f.Category is "Boost" or "Protection")),
        ("no_ign_idle_sensors", "All modules without Ignition, Idle and Sensors (gear detection and everything that needs it, tip-in retard, traction, anti-stall, rolling idle).", Without(f => f.Category is "Ignition" or "Idle" or "Sensors")),
        ("first_half", "The first half of the All modules list, in the order it ticks them.", Without(f => allMods.IndexOf(f.Define) >= half)),
        ("second_half", "The second half of the All modules list.", Without(f => allMods.IndexOf(f.Define) < half)),
        ("with_stock", "The second half of the All modules list plus the stock trouble codes and self-tests: the stock services under a load of modules (the whole list plus them is 82 bytes too big).", [.. Without(f => allMods.IndexOf(f.Define) < half), "FEAT_STOCK_DTC", "FEAT_STOCK_SELFTEST"]),
    };
    // the third round: the default four (which ran on the car) plus the modules no ROM that ran had, a few at a time
    string[] tested = ["FEAT_DATALOG", "FEAT_ECTPRO", "FEAT_REVLIMIT", "FEAT_LAUNCH", "FEAT_FTS", "FEAT_IGNCUTMOD", "FEAT_FUELTRIM", "FEAT_TPSRETARD", "FEAT_CYLTRIM", "FEAT_EXTMAPS",
        "FEAT_SHIFTLIGHT", "FEAT_TACH", "FEAT_RPMSWITCH", "FEAT_GIO1", "FEAT_IAB", "FEAT_GEAR", "FEAT_SPEEDCORR", "FEAT_TPSCAL", "FEAT_ANTISTALL", "FEAT_ROLLIDLE", "FEAT_EBC",
        "FEAT_WMI", "FEAT_BOOSTCUT", "FEAT_DLSERVICE", "FEAT_LEANPRO", "FEAT_ANTISTART"];
    var sets3 = new (string Name, string Why, string[] Defs)[]
    {
        ("base", "The four defaults on their own, as ROM03 of the first round (which ran). The control for this round.", def4),
        ("dlstream", "Defaults + Datalogging: channel stream.", [.. def4, "FEAT_DLSTREAM"]),
        ("limits2", "Defaults + burnout control, speed limiter, rpm ceilings (the limiters not tried before).", [.. def4, "FEAT_BURNOUT", "FEAT_SPEEDLIMIT", "FEAT_CEILING"]),
        ("gear", "Defaults + gear detection and everything that uses it: fuel, timing, rev limit and traction control by gear.", [.. def4, "FEAT_GEAR", "FEAT_GEARFUEL", "FEAT_GEARIGN", "FEAT_GEARLIMIT", "FEAT_TRACTION"]),
        ("gio234", "Defaults + programmable outputs GIO 2, 3 and 4.", [.. def4, "FEAT_GIO2", "FEAT_GIO3", "FEAT_GIO4"]),
        ("wbflex", "Defaults + wideband closed loop and flex fuel.", [.. def4, "FEAT_WBCL", "FEAT_FLEX"]),
        ("vtec_maps", "Defaults + VTEC control and the secondary tune on a switch.", [.. def4, "FEAT_VTECCTL", "FEAT_MAPSWITCH"]),
        ("nodtc_mods", "Modules that ran before (fuel trim, tip-in retard, cylinder trims, coolant protection, datalog) but WITHOUT the stock trouble codes and self-tests. Module RAM moves to 31Ah-351h. Every ROM that ran had the stock trouble codes in; every All modules ROM has not.", ["FEAT_DATALOG", "FEAT_ECTPRO", "FEAT_FUELTRIM", "FEAT_TPSRETARD", "FEAT_CYLTRIM", "FEAT_GEAR", "FEAT_ANTISTALL"]),
        ("options", "Defaults + the board options override, the watermark, alpha-N maps indexing and the smart alternator (none of them in a ROM that ran).", [.. def4, "FEAT_CFGOVERRIDE", "FEAT_WATERMARK", "FEAT_ALPHAN", "FEAT_SMARTALT"]),
        ("alltried", "Defaults + every module that already ran, all together (26 modules, less the warning lamp which cannot share the lamp with the shift light): if this fails while the others run, the number of modules is the problem.", [.. def4.Where(d => d != "FEAT_DATALOG" && d != "FEAT_ECTPRO"), .. tested]),
    };
    // the fourth round: the defaults plus 8 .. 26 of the modules that ran singly, to find how many it takes (or which)
    string[] Stk4(int from, int count) => [.. def4.Where(d => d != "FEAT_DATALOG" && d != "FEAT_ECTPRO"), .. tested.Skip(from).Take(count)];
    var sets4 = new (string Name, string Why, string[] Defs)[]
    {
        ("n08", "Stock trouble codes and self-tests + the first 8 of the 26 modules that each ran on their own.", Stk4(0, 8)),
        ("n11", "... the first 11.", Stk4(0, 11)),
        ("n14", "... the first 14.", Stk4(0, 14)),
        ("n17", "... the first 17.", Stk4(0, 17)),
        ("n20", "... the first 20.", Stk4(0, 20)),
        ("n23", "... the first 23.", Stk4(0, 23)),
        ("n26", "... all 26: the same modules as the third round's ROM10 (which did not run).", Stk4(0, 26)),
        ("last13", "... the LAST 13 of the 26 (the other end of the list from n14): does the count matter, or which modules?", Stk4(13, 13)),
        ("last20", "... the last 20.", Stk4(6, 20)),
        ("middle13", "... 13 from the middle of the list (7th to 19th).", Stk4(6, 13)),
    };
    if (args.Contains("--testroms2")) sets = sets2;
    if (args.Contains("--testroms4")) sets = sets4;
    if (args.Contains("--testromsfile"))
        sets = [.. File.ReadAllLines(args.SkipWhile(a => a != "--testromsfile").Skip(1).First()).Where(l => l.Contains('|')).Select(l => l.Split('|')).Select(p => (p[0], p[1], p[2].Split(' ', StringSplitOptions.RemoveEmptyEntries)))];
    if (args.Contains("--testroms3")) sets = sets3;
    var index = new List<string> { "Ten test ROMs for the real ECU. Flash each and note: boots and idles / does not start / resets in a loop / runs but something is wrong.", "" };
    int bad = 0;
    for (int i = 0; i < sets.Length; i++)
    {
        var (name, why, defs) = sets[i];
        var probs = sk.Problems(defs);
        var b = sk.Build(defs);
        string file = $"ROM{i + 1:00}_{name}";
        string line;
        if (!b.Success || b.Assembly == null || probs.Count > 0)
        {
            bad++;
            line = $"{file}: NOT BUILT - {string.Join(" | ", probs.Concat(b.Errors))}";
            Console.WriteLine(line); index.Add(line); continue;
        }
        var img = (byte[])b.Assembly.Image.Clone();
        File.WriteAllBytes(Path.Combine(outDir, file + ".bin"), img);
        var z0 = HwCheck.Run(file, (byte[])img.Clone(), b.Assembly, null);
        var z1 = HwCheck.Run(file, (byte[])img.Clone(), b.Assembly, 1234 + i);
        int sum = 0; foreach (var x in img) sum += x;
        bool ok = z0.Traps.Count == 0 && z1.Traps.Count == 0;
        if (!ok) bad++;
        var ram = b.Ram is { } r ? $"module RAM {r.Used}/{r.Size} B" : "";
        line = $"{file}.bin  {(ok ? "sim ok" : "SIM TRAP")}  {b.FreeBytes} bytes free  {ram}  checksum {((sum & 0xFF) == 0 ? "ok" : "BAD")}";
        Console.WriteLine(line);
        foreach (var t in z0.Traps.Concat(z1.Traps)) Console.WriteLine("    " + t);
        index.Add(line);
        index.Add("    " + why);
        index.Add("    modules: " + (defs.Length == 0 ? "(none)" : string.Join(" ", defs.Select(d => d.StartsWith("FEAT_STOCK_") ? d[5..] : d[5..]))));
        index.Add("");
        File.WriteAllText(Path.Combine(outDir, file + ".defines.txt"), string.Join(Environment.NewLine, defs) + Environment.NewLine);
    }
    File.WriteAllLines(Path.Combine(outDir, "README.txt"), index);
    Console.WriteLine($"wrote {sets.Length - bad} of {sets.Length} to {outDir}");
    return bad;
}
if (args.Contains("--showmap"))
{
    // --showmap <item> [DEFINE...]: a table as the app shows it (axes and cells) for a build
    var a2 = args.SkipWhile(a => a != "--showmap").Skip(1).ToArray();
    var bm = sk.Build(a2.Skip(1));
    var dm = OkiRomSim.Calibration.DefinitionBuilder.FromAssembly(bm.Assembly!, "show");
    dm.MergeBuiltinFormulas();
    var it = dm.Items.First(i => i.Name.Equals(a2[0], StringComparison.OrdinalIgnoreCase));
    var cells = OkiRomSim.Calibration.RomData.Read(dm, bm.Assembly!.Image, it);
    Console.WriteLine($"{it.Name} @ {it.Address:X4}h rows {it.Rows} cols {it.Cols} stride {it.Stride} formula {it.Formula}");
    var rowAx = OkiRomSim.Calibration.RomData.AxisValues(dm, bm.Assembly.Image, it.RowAxis, it.Rows);
    var colAx = OkiRomSim.Calibration.RomData.AxisValues(dm, bm.Assembly.Image, it.ColAxis, it.Cols);
    Console.WriteLine("cols: " + string.Join(" ", colAx.Select(v => v.ToString("0.#"))));
    for (int r = 0; r < it.Rows; r++)
        Console.WriteLine($"{(r < rowAx.Length ? rowAx[r] : double.NaN),6:0} | " + string.Join(" ", Enumerable.Range(0, it.Cols).Select(c => cells[(r * it.Cols) + c].Display.PadLeft(5))));
    return 0;
}
if (args.Contains("--allmodules"))
{
    // what File > New ROM > Create > All modules ticks, and what that builds
    var chosen = new List<string>();
    foreach (var f in sk.Features)
        if (!f.Stock && sk.Problems([.. chosen, f.Define]).Count == 0) chosen.Add(f.Define);
    Console.WriteLine(string.Join(" ", chosen));
    var ba = sk.Build(chosen);
    Console.WriteLine($"{(ba.Success ? "builds" : "FAILS")}, {ba.FreeBytes} bytes free, {chosen.Count} modules");
    if (ba.Ram is { } rr) Console.WriteLine($"module RAM {rr.Used}/{rr.Size} used{(rr.Full ? " FULL" : "")}");
    foreach (var e in ba.Errors) Console.WriteLine("  " + e);
    foreach (var a in SkeletonAdvice.Check(sk, chosen, ba)) Console.WriteLine($"  {a.Level,-7} {a.Title}: {a.Detail}");
    return 0;
}
if (args.Contains("--detectbin"))
{
    // --detectbin <file.bin> [item...]: open a .bin the way the app does (disassemble, Detect) and print those tables
    var ar = args.SkipWhile(a => a != "--detectbin").Skip(1).ToArray();
    var bytes = File.ReadAllBytes(ar[0]);
    string asmPath = Path.ChangeExtension(Path.GetFullPath(ar[0]), ".disasm.asm");
    var dis = OkiRomSim.Core.BinDisassembler.Disassemble(bytes, Path.GetFileName(ar[0]), text =>
    {
        var r0 = new OkiRomSim.Assembler.OkiAssembler(new OkiRomSim.Assembler.AssemblerOptions { ReadFile = f => f == asmPath ? text : null }).AssembleText(text, asmPath);
        return (r0.Success ? r0.Image : null, r0.Diagnostics.Where(d => d.Severity == OkiRomSim.Assembler.Severity.Error).Select(d => d.Line));
    }, null);
    var asm2 = new OkiRomSim.Assembler.OkiAssembler(new OkiRomSim.Assembler.AssemblerOptions { ReadFile = f => f == asmPath ? dis.Text : null }).AssembleText(dis.Text, asmPath);
    var dset = new OkiRomSim.Calibration.DefinitionSet();
    var refs = OkiRomSim.Calibration.RomReference.Shipped(Environment.GetEnvironmentVariable("REFS") ?? Path.Combine(root, "Templates"));
    if (Environment.GetEnvironmentVariable("SHOWREFS") == "1")
        foreach (var rf in refs) foreach (var ri in rf.Items.Where(i => i.Name == "FuelLow"))
            Console.WriteLine($"ref {rf.Name}: {ri.Name} @ {ri.Address:X4} {ri.Rows}x{ri.Cols} stride {ri.Stride} mult {(ri.ColumnScaleAddress is int q ? q.ToString("X4") : "-")}");
    var res = OkiRomSim.Calibration.CalibrationDetector.Detect(dset, asm2, bytes, [(asmPath, dis.Text)], refs);
    Console.WriteLine($"detect: {res.Summary}; {dset.Items.Count} items");
    dset.MergeBuiltinFormulas();
    foreach (var it in dset.Items.Where(i => i.IsTable && i.ColumnScaleAddress is int))
        if (it.ColumnScaleAddress != it.Address + (it.Rows * (it.Stride > 0 ? it.Stride : it.Cols)))
            Console.WriteLine($"MULT? {it.Name} @ {it.Address:X4} {it.Rows}x{it.Cols} stride {it.Stride} mult {it.ColumnScaleAddress:X4} (expected {it.Address + (it.Rows * (it.Stride > 0 ? it.Stride : it.Cols)):X4})");
    if (ar.Skip(1).Contains("--big"))
        foreach (var it in dset.Items)
        {
            try { var cs = OkiRomSim.Calibration.RomData.Read(dset, bytes, it); if (cs.Length > 0 && cs.Max(c => c.Value) > 1000) Console.WriteLine($"BIG {it.Name} @ {it.Address:X4}h {it.Type} {it.Rows}x{it.Cols} {it.Formula} max {cs.Max(c => c.Value):0.#}"); } catch { }
        }
    foreach (var name in ar.Skip(1))
        foreach (var it in dset.Items.Where(i => i.Name.Contains(name, StringComparison.OrdinalIgnoreCase)))
        {
            var cells = OkiRomSim.Calibration.RomData.Read(dset, bytes, it);
            Console.WriteLine($"{it.Name} @ {it.Address:X4}h {it.Type} {it.Rows}x{it.Cols} stride {it.Stride} formula {it.Formula} mult {(it.ColumnScaleAddress is int mm ? mm.ToString("X4") : "-")} origin {it.Origin}: " +
                string.Join(" ", cells.Take(24).Select(c => c.Display)) + $" ... min {cells.Min(c => c.Value):0.#} max {cells.Max(c => c.Value):0.#}");
        }
    return 0;
}
if (args.Contains("--fuelscale"))
{
    // what one fuel-map unit is in injector microseconds: the skeleton run at map breakpoints, pulse width against the cell
    var bf = sk.Build(["FEAT_STOCK_DTC", "FEAT_STOCK_SELFTEST"]);
    var df = OkiRomSim.Calibration.DefinitionBuilder.FromAssembly(bf.Assembly!, "fs"); df.MergeBuiltinFormulas();
    var fl = df.Items.First(i => i.Name == "FuelLow");
    var cells = OkiRomSim.Calibration.RomData.Read(df, bf.Assembly!.Image, fl);
    var rowAx = OkiRomSim.Calibration.RomData.AxisValues(df, bf.Assembly.Image, fl.RowAxis, fl.Rows);
    var colAx = OkiRomSim.Calibration.RomData.AxisValues(df, bf.Assembly.Image, fl.ColAxis, fl.Cols);
    foreach (int ri in new[] { 4, 6, 8, 10 })
        foreach (int ci in new[] { 2, 3, 4, 5 })
        {
            var sim = new Simulator(); sim.LoadRom((byte[])bf.Assembly.Image.Clone());
            var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = rowAx[ri]; e.MapKpa = colAx[ci] / 10.0; e.VbattVolts = 14.0;
            sim.SyncSensors();
            double sum = 0; int n = 0;
            for (ulong end = (ulong)(5 * Bus.CpuHz); sim.Cpu.Cycles < end;)
            {
                sim.StepOne(); if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
                if (sim.Cpu.Cycles > (ulong)(2.5 * Bus.CpuHz) && sim.Bus.InjectorPulseWidthUs > 0 && (sim.Cpu.Instructions & 4095) == 0) { sum += sim.Bus.InjectorPulseWidthUs; n++; }
            }
            double units = cells[(ri * fl.Cols) + ci].Value;
            Console.WriteLine($"rpm {rowAx[ri]:0} map {colAx[ci] / 10:0.0} kPa: cell {units:0.0} units, pulse {(n > 0 ? sum / n : 0):0} us  ratio {(n > 0 ? sum / n / units : 0):0.00} us/unit");
        }
    return 0;
}
if (args.Contains("--outtest"))
{
    // the output test ROMs in the simulator: key on, engine stopped, 4 s - the bit each one flashes changes ~8 times
    var baseDefs = new[] { "FEAT_STOCK_DTC", "FEAT_STOCK_SELFTEST", "FEAT_DATALOG" };
    int bad = 0;
    for (int n = 0; n <= 18; n++)
    {
        // 18: the service commands with the injectors off from power-up - the lamp (P1.4) flashing four times a second
        var b = sk.Build(n == 18 ? [.. baseDefs, "FEAT_DLSERVICE", "DLSVC_TEST=1"] : [.. baseDefs, $"OUTTEST={n}"]);
        if (!b.Success) { Console.WriteLine($"{n}: {string.Join(" | ", b.Errors.Take(2))}"); bad++; continue; }
        var img = (byte[])b.Assembly!.Image.Clone();
        RomChecksum.Balance(img, b.Assembly.ChecksumAddress ?? 0x7FFF);
        var sim = new Simulator(); sim.LoadRom(img);
        var e = sim.Engine; e.EctCelsius = 25; e.IatCelsius = 25; e.Rpm = 0; e.MapKpa = 101; e.VbattVolts = 12.5; sim.SyncSensors();
        int Read() => n < 8 ? sim.Bus.Ppi.PortB : n < 16 || n == 18 ? sim.Bus.Ppi.PortC : sim.Bus.Ram[Bus.SfrP4];
        int bit = n == 16 ? 0x08 : n == 17 ? 0x04 : n == 18 ? 0x10 : 1 << (n & 7), was = -1, changes = 0, others = 0;
        ulong end = sim.Cpu.Cycles + (ulong)(10 * Bus.CpuHz);   // (the boot takes about 4.5 s)
        while (sim.Cpu.Cycles < end && sim.StepOne() != null)
        {
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
            if ((sim.Cpu.Instructions & 255) != 0) continue;
            int v = Read();
            if (was >= 0 && ((v ^ was) & bit) != 0) changes++;
            if (was >= 0 && ((v ^ was) & ~bit & 0xFF) != 0) others++;
            was = v;
        }
        string where = n < 8 ? $"P0.{n} (8255 port B)" : n < 16 ? $"P1.{n - 8} (8255 port C)" : n == 16 ? "P4.3" : n == 17 ? "P4.2" : "service lamp P1.4";
        Console.WriteLine($"{n,2} {where,-22} its bit changed {changes} times in 10 s; other bits of that port changed {others} times; halted {sim.State == RunState.Faulted}");
        if (changes < 5) bad++;
    }
    return bad == 0 ? 0 : 1;
}
if (args.Contains("--preset"))
{
    // New ROM's Default: what fits, its size and module RAM, and its tick (as built and with every module on)
    var pa = args.SkipWhile(a => a != "--preset").Skip(1).ToArray();
    var fit = SkeletonPresets.Fit(sk, pa.Length > 0 ? pa : SkeletonPresets.Default);
    Console.WriteLine($"{fit.Count} of {SkeletonPresets.Default.Length}: dropped {string.Join(" ", SkeletonPresets.Default.Except(fit))}");
    var b = sk.Build(fit);
    Console.WriteLine($"{b.FreeBytes} bytes free, module RAM {b.Ram?.Used} of {b.Ram?.Size}");
    var a = IsrTiming.Measure(b.Assembly!, allOn: false); var o = IsrTiming.Measure(b.Assembly!, allOn: true);
    Console.WriteLine($"tick as built {a?.TickWorstUs:0} us, every module on {o?.TickWorstUs:0} us");
    return 0;
}
if (args.Contains("--ticktime"))
{
    // --ticktime DEFINE...: the New ROM window's measure (IsrTiming), and how long it takes
    var defs = args.SkipWhile(a => a != "--ticktime").Skip(1).ToArray();
    var sw = System.Diagnostics.Stopwatch.StartNew();
    var b = sk.Build(defs);
    if (!b.Success) { Console.WriteLine(string.Join(" | ", b.Errors)); return 2; }
    var r = IsrTiming.Measure(b.Assembly!, allOn: !args.Contains("--asbuilt"));
    Console.WriteLine(r == null ? "did not run" : $"tick worst {r.TickWorstUs:0} us, average {r.TickAverageUs:0.0} us, interrupts {r.CpuPercent:0.0} % of the CPU, rpm reading lost {r.LostTeeth} time(s), reset itself {r.Resets} time(s) ({sw.Elapsed.TotalSeconds:0.0} s)");
    return 0;
}
if (args.Contains("--isrtime"))
{
    // --isrtime DEFINE...: how long each interrupt handler runs by itself (cycles from entry to RTI, less the handlers that interrupted it), worst and average, over an idle-to-WOT run
    var defs = args.SkipWhile(a => a != "--isrtime").Skip(1).ToArray();
    var b = sk.Build(defs);
    if (!b.Success) { Console.WriteLine(string.Join(" | ", b.Errors)); return 2; }
    var asm = b.Assembly!;
    var isrRom = (byte[])asm.Image.Clone();
    // ALLON=1: every module switched on first (as the New ROM window measures)
    if (Environment.GetEnvironmentVariable("ALLON") == "1")
        foreach (var f in OkiRomSim.Calibration.DefinitionBuilder.FromAssembly(asm, "isr").Items.Where(i => i.Flag && i.Address >= 0 && i.Address < isrRom.Length))
        { int v = (int)f.OnRaw; isrRom[f.Address] = (byte)v; if (f.ElementSize == 2) isrRom[f.Address + 1] = (byte)(v >> 8); }
    OkiRomSim.Calibration.RomChecksum.Balance(isrRom, asm.ChecksumAddress ?? 0x7FFF);
    var sim = new Simulator(); sim.LoadRom(isrRom);
    var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 0; e.MapKpa = 101; e.VbattVolts = 13.8; sim.SyncSensors();
    var open = new List<(string Name, ulong Since, ulong Own)>();
    var worst = new Dictionary<string, ulong>(); var total = new Dictionary<string, (ulong Sum, long N)>();
    ulong inIsr = 0, t0 = 0; bool on = false;
    var t1list = new List<(int Slot, ulong Own)>();
    void Go(double secs)
    {
        ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz);
        while (sim.Cpu.Cycles < end && sim.State != RunState.Faulted)
        {
            var st = sim.StepOne();
            if (!on) { if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); continue; }
            ulong now = sim.Cpu.Cycles;
            if (st?.Decoded is { } d && d.Mnemonic.StartsWith("RTI", StringComparison.Ordinal) && open.Count > 0)
            {
                var top = open[^1]; open.RemoveAt(open.Count - 1);
                ulong own = top.Own + (now - top.Since);
                worst[top.Name] = Math.Max(worst.GetValueOrDefault(top.Name), own);
                if (top.Name == "int_timer_1") t1list.Add((sim.Bus.Ram[0xFE] & 0x0F, own));
                var t = total.GetValueOrDefault(top.Name); total[top.Name] = (t.Sum + own, t.N + 1);
                inIsr += now - top.Since;
                if (open.Count > 0) { var o = open[^1]; open[^1] = (o.Name, now, o.Own); }
            }
            if (sim.LastStepInterrupted)
            {
                if (open.Count > 0) { var o = open[^1]; open[^1] = (o.Name, o.Since, o.Own + (now - o.Since)); }
                open.Add((asm.LabelAt(sim.Cpu.Pc), now, 0));
            }
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
        }
    }
    Go(6); on = true; t0 = sim.Cpu.Cycles;
    foreach (var (rpm, map) in new[] { (850, 33), (3000, 60), (6000, 100), (7500, 100) })
    { e.Rpm = rpm; e.MapKpa = map; sim.SyncSensors(); Go(2); }
    double span = sim.Cpu.Cycles - t0;
    Console.WriteLine($"interrupts take {inIsr / span * 100:0.0} % of the CPU over the run");
    if (Environment.GetEnvironmentVariable("BYSLOT") == "1")
        foreach (var g in t1list.GroupBy(x => x.Slot).OrderBy(g => g.Key))
            Console.WriteLine($"  timer_1 on slot {g.Key,2}: average {g.Average(x => (double)x.Own) / (Bus.CpuHz / 1e6),6:0} us, worst {g.Max(x => x.Own) / (Bus.CpuHz / 1e6),4:0} us");
    foreach (var (n, w) in worst.OrderByDescending(x => x.Value))
        Console.WriteLine($"  {n,-24} worst {w / (Bus.CpuHz / 1e6),8:0} us   average {total[n].Sum / (double)total[n].N / (Bus.CpuHz / 1e6),7:0.0} us   x{total[n].N}");
    return 0;
}
if (args.Contains("--modprofile"))
{
    // --modprofile DEFINE...: where the CPU time goes, by module, over an idle-to-WOT run (everything: main loop and interrupts)
    var defs = args.SkipWhile(a => a != "--modprofile").Skip(1).ToArray();
    var b = sk.Build(defs);
    if (!b.Success) { Console.WriteLine(string.Join(" | ", b.Errors)); return 2; }
    var asm = b.Assembly!;
    var owner = new string?[0x8000];
    for (int a = 0; a < owner.Length; a++) if (asm.Lookup(a) is { } le) owner[a] = Path.GetFileNameWithoutExtension(le.File);
    var sim = new Simulator(); sim.LoadRom((byte[])asm.Image.Clone());
    var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 0; e.MapKpa = 101; e.VbattVolts = 13.8; sim.SyncSensors();
    var cyc = new Dictionary<string, ulong>(); ulong all = 0; bool on = false;
    void Go(double secs)
    {
        ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz);
        while (sim.Cpu.Cycles < end && sim.State != RunState.Faulted)
        {
            ulong c0 = sim.Cpu.Cycles; var st = sim.StepOne();
            if (on && st != null) { ulong d = sim.Cpu.Cycles - c0; all += d; string o = st.Value.Pc < owner.Length ? owner[st.Value.Pc] ?? "(skeleton)" : "?"; cyc[o] = cyc.GetValueOrDefault(o) + d; }
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
        }
    }
    Go(6); on = true;
    foreach (var (rpm, map) in new[] { (850, 33), (3000, 60), (6000, 100), (7500, 100) })
    { e.Rpm = rpm; e.MapKpa = map; sim.SyncSensors(); Go(2); }
    foreach (var (n, c) in cyc.OrderByDescending(x => x.Value).Take(18)) Console.WriteLine($"  {n,-28} {c * 100.0 / all,5:0.0} %");
    if (Environment.GetEnvironmentVariable("BYLABEL") == "1")
    {
        var byLabel = new Dictionary<string, ulong>();
        var sim2 = new Simulator(); sim2.LoadRom((byte[])asm.Image.Clone());
        var e2 = sim2.Engine; e2.EctCelsius = 85; e2.IatCelsius = 25; e2.Rpm = 3000; e2.MapKpa = 60; e2.VbattVolts = 13.8; sim2.SyncSensors();
        ulong tot = 0;
        for (ulong end = (ulong)(10 * Bus.CpuHz); sim2.Cpu.Cycles < end;)
        {
            ulong c0 = sim2.Cpu.Cycles; var st = sim2.StepOne(); if (st == null) break;
            if (sim2.Cpu.Cycles > (ulong)(6 * Bus.CpuHz)) { ulong d = sim2.Cpu.Cycles - c0; tot += d; var l = asm.LabelAt(st.Value.Pc); byLabel[l] = byLabel.GetValueOrDefault(l) + d; }
            if ((sim2.Cpu.Instructions & 1023) == 0) sim2.SyncSensors();
        }
        foreach (var (n, c) in byLabel.OrderByDescending(x => x.Value).Take(25)) Console.WriteLine($"    {n,-34} {c * 100.0 / tot,5:0.00} %");
    }
    return 0;
}
if (args.Contains("--tracelabel"))
{
    // --tracelabel LABEL DEFINE...: the instructions run from the first entry of LABEL until it returns, with the cycles each took
    var ta = args.SkipWhile(a => a != "--tracelabel").Skip(1).ToArray();
    var b = sk.Build(ta.Skip(1));
    var asm = b.Assembly!;
    int at = (int)asm.Symbols.Values.First(x => x.Name.Equals(ta[0], StringComparison.OrdinalIgnoreCase)).Value;
    var traceRom = (byte[])asm.Image.Clone();
    if (Environment.GetEnvironmentVariable("ALLON") == "1")     // every module switched on first
        foreach (var f in OkiRomSim.Calibration.DefinitionBuilder.FromAssembly(asm, "trace").Items.Where(i => i.Flag && i.Address >= 0 && i.Address < traceRom.Length))
        { int v = (int)f.OnRaw; traceRom[f.Address] = (byte)v; if (f.ElementSize == 2) traceRom[f.Address + 1] = (byte)(v >> 8); }
    OkiRomSim.Calibration.RomChecksum.Balance(traceRom, asm.ChecksumAddress ?? 0x7FFF);
    var sim = new Simulator(); sim.LoadRom(traceRom);
    var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 3000; e.MapKpa = 60; e.VbattVolts = 13.8; sim.SyncSensors();
    bool tracing = false; int depth = 0; ulong start = 0; int n = 0;
    for (ulong end = (ulong)(15 * Bus.CpuHz); sim.Cpu.Cycles < end;)
    {
        ulong c0 = sim.Cpu.Cycles; ushort pc0 = sim.Cpu.Pc;
        var st = sim.StepOne(); if (st == null) break;
        if (!tracing && pc0 == at && sim.Cpu.Cycles > (ulong)(7 * Bus.CpuHz)) { tracing = true; start = c0; depth = 0; }
        if (tracing)
        {
            var m = st.Value.Decoded?.Mnemonic ?? "?";
            Console.WriteLine($"  {pc0:X4} {asm.LabelAt(pc0),-28} {m,-8} {sim.Cpu.Cycles - c0,3} cy{(sim.LastStepInterrupted ? "  <interrupt>" : "")}");
            if (m.StartsWith("CAL", StringComparison.Ordinal) || m.StartsWith("VCAL", StringComparison.Ordinal)) depth++;
            if (m.StartsWith("RTI", StringComparison.Ordinal) && depth == 0) { Console.WriteLine($"total {(sim.Cpu.Cycles - start) / (Bus.CpuHz / 1e6):0} us"); return 0; }
            if (m.StartsWith("RT", StringComparison.Ordinal) && !m.StartsWith("RTI", StringComparison.Ordinal)) { if (depth == 0) { Console.WriteLine($"total {(sim.Cpu.Cycles - start) / (Bus.CpuHz / 1e6):0} us"); return 0; } depth--; }
            if (++n > 2000) break;
        }
    }
    return 0;
}
if (args.Contains("--cutlatency"))
{
    int latBad = 0;
    void Lat(bool ok, string what) { Console.WriteLine($"{(ok ? "PASS" : "FAIL")}  {what}"); if (!ok) latBad++; }
    // --cutlatency: the rpm swept up through a rev limit at several rates; how far past the limit the last injection
    // still fires (the module rev limiter at 6000, and the skeleton's own at 8296); and the boost through a boost cut
    {
        var abuild = sk.Build(["FEAT_BOOSTCUT"]);
        if (!abuild.Success) Lat(false, $"FEAT_BOOSTCUT: does not build: {string.Join(" | ", abuild.Errors.Take(2))}");
        var ab = abuild.Assembly!;
        int Sb(string n) => (int)ab.Symbols.Values.First(x => x.Name.Equals(n, StringComparison.OrdinalIgnoreCase)).Value;
        const double cutKpa = 140;
        int raw = (int)Math.Round((cutKpa * 10 + 59) / 7.221);
        foreach (double rate in new[] { 100.0, 300.0, 800.0 })
        {
            var img = (byte[])ab.Image.Clone();
            img[Sb("boostcut_block")] = 1; img[Sb("boostcut_hot")] = (byte)raw; img[Sb("boostcut_cold")] = (byte)raw;
            if (RomChecksum.Site(img, ab) is int cs) RomChecksum.Balance(img, cs);
            var sim = new Simulator(); sim.LoadRom(img);
            var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 5000; e.TpsPct = 100; e.SpeedKmh = 80; e.VbattVolts = 13.8; e.MapKpa = 100; sim.SyncSensors();
            long inj = 0; double worst = 0;
            ulong t0 = (ulong)(6 * Bus.CpuHz);
            for (ulong end = t0 + (ulong)((60 / rate + 0.5) * Bus.CpuHz); sim.Cpu.Cycles < end;)
            {
                if (sim.StepOne() == null) break;
                if ((sim.Cpu.Instructions & 255) == 0)
                {
                    double t = sim.Cpu.Cycles < t0 ? -1 : (sim.Cpu.Cycles - t0) / (double)Bus.CpuHz;
                    e.MapKpa = t < 0 ? 110 : Math.Min(cutKpa + 30, 110 + rate * t);
                    sim.SyncSensors();
                }
                long now = sim.Bus.InjectorEvents.Sum();
                if (now != inj) { inj = now; if (e.MapKpa > cutKpa) worst = Math.Max(worst, e.MapKpa); }
            }
            Lat(worst - cutKpa <= (rate <= 100 ? 2 : 12), $"boost cut {cutKpa:0} kPa, rising {rate,4:0} kPa/s: last injection at {worst:0.0} kPa ({(worst > 0 ? worst - cutKpa : 0):+0.0;-0.0;0} over)");
        }
    }
    {
        var asm0 = sk.Build([]).Assembly!;
        foreach (double rpm in new[] { 800.0, 8200, 8400, 9500, 10500, 11000, 12000 })
        {
            var sim = new Simulator(); sim.LoadRom((byte[])asm0.Image.Clone());
            var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.MapKpa = 95; e.TpsPct = 100; e.SpeedKmh = 50; e.VbattVolts = 13.8; e.Rpm = rpm; sim.SyncSensors();
            long i0 = 0;
            for (ulong end = (ulong)(7 * Bus.CpuHz); sim.Cpu.Cycles < end;)
            {
                if (sim.StepOne() == null) break;
                if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
                if (i0 == 0 && sim.Cpu.Cycles > (ulong)(6 * Bus.CpuHz)) i0 = sim.Bus.InjectorEvents.Sum();
            }
            // the bare skeleton's own limit: 8296 rpm on the P30; stock P13's cuts by 7000 (6500 without VTEC in the simulator)
            Lat(rpm < (Platform.P13 ? 7000 : 8300) ? sim.Bus.InjectorEvents.Sum() - i0 > 10 : sim.Bus.InjectorEvents.Sum() - i0 == 0, $"steady {rpm:0}: {sim.Bus.InjectorEvents.Sum() - i0} inj/s, 0ACh {sim.Bus.Ram[0xAC] | sim.Bus.Ram[0xAD] << 8:X4}, 180h {sim.Bus.Ram[0x180] | sim.Bus.Ram[0x181] << 8:X4}, 182h {sim.Bus.Ram[0x182] | sim.Bus.Ram[0x183] << 8:X4}, 11C {sim.Bus.Ram[0x11C]:X2}");
        }
    }
    foreach (var (mods, limit) in new[] { (new[] { "FEAT_REVLIMIT" }, 6000.0), (Array.Empty<string>(), 8296.0) })
    {
        var b = sk.Build(mods);
        if (!b.Success) { Lat(false, $"{string.Join(" ", mods)}: does not build: {string.Join(" | ", b.Errors.Take(2))}"); continue; }
        var asm = b.Assembly!;
        foreach (double rate in new[] { 3000.0, 8000.0, 15000.0 })
        {
            var img = (byte[])asm.Image.Clone();
            if (mods.Length > 0)
            {
                int S(string n) => (int)asm.Symbols.Values.First(x => x.Name.Equals(n, StringComparison.OrdinalIgnoreCase)).Value;
                int Pd(double rpm) => (int)Math.Round(1875000 / rpm);
                img[S("revlimit_low")] = 1; img[S("revlimit_cut")] = 0;
                int set = Pd(limit), reset = Pd(limit - 150);
                img[S("revlimit_low_set")] = (byte)set; img[S("revlimit_low_set") + 1] = (byte)(set >> 8);
                img[S("revlimit_low_reset")] = (byte)reset; img[S("revlimit_low_reset") + 1] = (byte)(reset >> 8);
                if (RomChecksum.Site(img, asm) is int cs) RomChecksum.Balance(img, cs);
            }
            var sim = new Simulator(); sim.LoadRom(img);
            var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.MapKpa = 95; e.TpsPct = 100; e.SpeedKmh = 50; e.VbattVolts = 13.8;
            double start = limit - 1500;
            e.Rpm = 2000; sim.SyncSensors();
            long inj = 0; double lastInjRpm = 0, worst = 0, firstCut = 0, gapFrom = 0; ulong lastInjCy = 0;
            ulong t0 = (ulong)(6 * Bus.CpuHz);
            for (ulong end = t0 + (ulong)((2000 / rate + 0.6) * Bus.CpuHz); sim.Cpu.Cycles < end;)
            {
                if (sim.StepOne() == null) break;
                if ((sim.Cpu.Instructions & 255) == 0)
                {
                    double t = sim.Cpu.Cycles < t0 ? -1 : (sim.Cpu.Cycles - t0) / (double)Bus.CpuHz;
                    e.Rpm = t < 0 ? start : Math.Min(limit + 2000, start + rate * t);
                    sim.SyncSensors();
                }
                long now = sim.Bus.InjectorEvents.Sum();
                // CUTLAT_TRACE2=rate: at each injection near the module limit, the latch's period, the cap and the cut request
                if (now != inj && mods.Length > 0 && Environment.GetEnvironmentVariable("CUTLAT_TRACE2") == rate.ToString() && e.Rpm > limit - 250)
                {
                    int Sy(string n) => asm.Symbols.Values.FirstOrDefault(x => x.Name.Equals(n, StringComparison.OrdinalIgnoreCase)) is { } y ? (int)y.Value : -1;
                    int ovp = Sy("SKEL_OVR_P"), fc = Sy("SVC_FUELCUT"), rc = Sy("MOD_REVCAP"), rpmp = Sy("ENG_RPMP");
                    var m = sim.Bus.Ram;
                    Console.WriteLine($"   inj at {e.Rpm:0} rpm: latch period {(ovp < 0 ? -1 : m[ovp] | m[ovp + 1] << 8)} (= {(ovp < 0 ? 0 : 1875000.0 / Math.Max(1, m[ovp] | m[ovp + 1] << 8)):0} rpm), cap {(rc < 0 ? -1 : m[rc]):X2}, fuel cut {(fc < 0 ? -1 : m[fc]):X2}, rpm word {(rpmp < 0 ? 0 : m[rpmp] | m[rpmp + 1] << 8)}");
                }
                if (now != inj) { if (gapFrom > 0 && sim.Cpu.Cycles - lastInjCy > (ulong)(0.03 * Bus.CpuHz)) { } inj = now; lastInjRpm = e.Rpm; lastInjCy = sim.Cpu.Cycles; if (e.Rpm > limit) worst = Math.Max(worst, e.Rpm); }
                else if (firstCut == 0 && sim.Cpu.Cycles > t0 && sim.Cpu.Cycles - lastInjCy > (ulong)(0.025 * Bus.CpuHz)) firstCut = lastInjRpm;
                if (Environment.GetEnvironmentVariable("CUTLAT_TRACE") == "1" && rate == 3000 && mods.Length == 0 && e.Rpm > limit - 300 && e.Rpm < limit + 400 && (sim.Cpu.Instructions % 3000) == 0 && sim.Cpu.Cycles > t0)
                    Console.WriteLine($"   t {(sim.Cpu.Cycles - t0) / (double)Bus.CpuHz:0.000} rpm {e.Rpm:0} inj {now} 0ACh {sim.Bus.Ram[0xAC] | sim.Bus.Ram[0xAD] << 8:X4} 11C {sim.Bus.Ram[0x11C]:X2} 1F0 {sim.Bus.Ram[0x1F0]:X2} 12D {sim.Bus.Ram[0x12D]:X2}");
            }
            if (mods.Length > 0) { int rc = (int)asm.Symbols.Values.First(x => x.Name.Equals("MOD_REVCAP", StringComparison.OrdinalIgnoreCase)).Value; Console.WriteLine($"    syms revcap {asm.Symbols.ContainsKey("mod_revcap")}/{asm.Symbols.Values.Any(x => x.Name.Equals("mod_revcap", StringComparison.OrdinalIgnoreCase))} roll {asm.Symbols.Values.Any(x => x.Name.Equals("mod_revcap_roll", StringComparison.OrdinalIgnoreCase))} skelcap {asm.Symbols.Values.Any(x => x.Name.Equals("skel_cap_off", StringComparison.OrdinalIgnoreCase))}; cap {rc:X3}: {sim.Bus.Ram[rc]:X2}/{sim.Bus.Ram[rc + 1]:X2} 1F0 {sim.Bus.Ram[0x1F0]:X2} limit period {(int)Math.Round(1875000 / limit):X}"); }
            Lat(worst - limit <= limit * 0.015, $"{(mods.Length > 0 ? "module rev limit" : "skeleton's own"),-18} {limit:0} rpm, rising {rate,6:0} rpm/s: last injection at {worst:0} rpm ({(worst > 0 ? worst - limit : 0):+0;-0;0} over), fuel first stopped at {firstCut:0} rpm");
        }
    }
    Console.WriteLine(latBad == 0 ? "ALL PASS" : $"{latBad} FAILED");
    return latBad;
}
if (args.Contains("--leakprobe"))
{
    // --leakprobe: boost cut held on at WOT; at each injection that still fires, the cut flags and where 11Ch bit 2 was last changed
    var b = sk.Build(Environment.GetEnvironmentVariable("LEAK_RPM") != null ? [] : ["FEAT_BOOSTCUT"]);
    var asm = b.Assembly!;
    var img = (byte[])asm.Image.Clone();
    if (Environment.GetEnvironmentVariable("LEAK_RPM") is { } lr)
    {
        var sm = new Simulator(); sm.LoadRom(img);
        var en = sm.Engine; en.EctCelsius = 85; en.IatCelsius = 25; en.Rpm = double.Parse(lr); en.MapKpa = 95; en.TpsPct = 100; en.SpeedKmh = 80; en.VbattVolts = 13.8; sm.SyncSensors();
        var rec = new Queue<ushort>(); byte lp = 0x0F; int op = 0, wd = 0, z = 0, ch = 0, ff = 0, lac = 0; byte l11 = 0;
        for (ulong end = (ulong)(8 * Bus.CpuHz); sm.Cpu.Cycles < end;)
        {
            ushort pc = sm.Cpu.Pc;
            if (sm.StepOne() == null) break;
            if ((sm.Cpu.Instructions & 1023) == 0) sm.SyncSensors();
            byte p2 = (byte)(sm.Bus.Ram[Bus.SfrP2] & 0x0F);
            if ((~p2 & lp & 0x0F) != 0 && sm.Cpu.Cycles > (ulong)(7 * Bus.CpuHz) && op++ < 6)
                Console.WriteLine($"  P2 {lp:X}->{p2:X} at {pc:X4} {asm.LabelAt(pc)} 11C={sm.Bus.Ram[0x11C]:X2}; recent: {string.Join(" < ", rec.Reverse().Take(30).Select(x => $"{x:X4} {asm.LabelAt(x)}".Trim()))}");
            lp = p2; rec.Enqueue(pc); if (rec.Count > 60) rec.Dequeue();
            byte c11 = sm.Bus.Ram[0x11C];
            if (((c11 ^ l11) & 0x24) != 0 && sm.Cpu.Cycles > (ulong)(6.5 * Bus.CpuHz) && ch++ < 16)
                Console.WriteLine($"  11C {l11:X2}->{c11:X2} at {pc:X4} {asm.LabelAt(pc)} 12D={sm.Bus.Ram[0x12D]:X2} 0ACh={sm.Bus.Ram[0xAC] | sm.Bus.Ram[0xAD] << 8:X4}; recent: {string.Join(" < ", rec.Reverse().Take(12).Select(x => $"{x:X4} {asm.LabelAt(x)}".Trim()))}");
            l11 = c11;
            int acw = sm.Bus.Ram[0xAC] | sm.Bus.Ram[0xAD] << 8;
            if (acw == 0xFFFF && lac != 0xFFFF && sm.Cpu.Cycles > (ulong)(6.5 * Bus.CpuHz) && ff++ < 4)
                Console.WriteLine($"  0ACh {lac:X4}->FFFF at {pc:X4} {asm.LabelAt(pc)}; recent: {string.Join(" < ", rec.Reverse().Take(40).Select(x => $"{x:X4} {asm.LabelAt(x)}".Trim()))}");
            lac = acw;
            if (sm.Bus.WatchdogTripped && wd++ == 0) Console.WriteLine($"  watchdog tripped at {sm.Cpu.Cycles / (double)Bus.CpuHz:0.000}s");
            if (sm.Cpu.Cycles > (ulong)(6.9 * Bus.CpuHz) && sm.Bus.Ram[0x11C] == 0 && z++ == 0) Console.WriteLine($"  11C went 0 at {pc:X4} {asm.LabelAt(pc)}; recent: {string.Join(" < ", rec.Reverse().Take(20).Select(x => $"{x:X4} {asm.LabelAt(x)}".Trim()))}");
        }
        return 0;
    }
    int S(string n) => (int)asm.Symbols.Values.First(x => x.Name.Equals(n, StringComparison.OrdinalIgnoreCase)).Value;
    img[S("boostcut_block")] = 1; img[S("boostcut_hot")] = 0x85; img[S("boostcut_cold")] = 0x85;
    if (RomChecksum.Site(img, asm) is int cs) RomChecksum.Balance(img, cs);
    var sim = new Simulator(); sim.LoadRom(img);
    var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 4000; e.MapKpa = 100; e.TpsPct = 100; e.SpeedKmh = 80; e.VbattVolts = 13.8; sim.SyncSensors();
    var recent = new Queue<ushort>(); byte lastP2 = 0x0F; int opened = 0;
    long inj = 0; int shown = 99; byte last11c = 0; ushort changedAt = 0; ulong changedCy = 0;
    for (ulong end = (ulong)(12 * Bus.CpuHz); sim.Cpu.Cycles < end;)
    {
        ushort pc0 = sim.Cpu.Pc;
        if (sim.StepOne() == null) break;
        if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
        byte p2 = (byte)(sim.Bus.Ram[Bus.SfrP2] & 0x0F);
        if ((~p2 & lastP2 & 0x0F) != 0 && sim.Cpu.Cycles > (ulong)(8 * Bus.CpuHz) && opened++ < 12)
        {
            Console.WriteLine($"  P2 {lastP2:X}->{p2:X} at {pc0:X4} {asm.LabelAt(pc0)}; recent: {string.Join(" < ", recent.Reverse().Take(14).Select(x => $"{x:X4} {asm.LabelAt(x)}".Trim()))}");
        }
        lastP2 = p2;
        recent.Enqueue(pc0); if (recent.Count > 60) recent.Dequeue();
        byte f = sim.Bus.Ram[0x11C];
        if (((f ^ last11c) & 0x14) != 0) { changedAt = pc0; changedCy = sim.Cpu.Cycles; }
        last11c = f;
        long now = sim.Bus.InjectorEvents.Sum();
        if (now != inj)
        {
            if (sim.Cpu.Cycles > (ulong)(8 * Bus.CpuHz) && shown++ < 25)
                Console.WriteLine($"{sim.Cpu.Cycles / (double)Bus.CpuHz:0.0000}s inj at {pc0:X4} {asm.LabelAt(pc0)}: 11C={f:X2} 21C={sim.Bus.Ram[0x21C]:X2} 1F0={sim.Bus.Ram[0x1F0]:X2} 1C6={sim.Bus.Ram[0x1C6] | sim.Bus.Ram[0x1C7] << 8:X4}; 11C bits 2/4 last changed at {changedAt:X4} {asm.LabelAt(changedAt)} {(sim.Cpu.Cycles - changedCy) / (Bus.CpuHz / 1e6):0} us ago");
            inj = now;
        }
    }
    return 0;
}
if (args.Contains("--bootscan"))
{
    // --bootscan <folder>: how long each ROM in a test-ROM folder takes to finish booting (first heartbeat, first injector pulse), in the simulator
    foreach (var f in Directory.GetFiles(args.SkipWhile(a => a != "--bootscan").Skip(1).First(), "*.defines.txt").Order())
    {
        var defs = File.ReadAllLines(f).Select(l => l.Trim()).Where(l => l.Length > 0).ToArray();
        var b = sk.Build(defs);
        if (!b.Success) { Console.WriteLine(Path.GetFileName(f) + ": does not build"); continue; }
        var sim = new Simulator(); sim.LoadRom((byte[])b.Assembly!.Image.Clone());
        var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 0; e.MapKpa = 101; e.VbattVolts = 12.4; sim.SyncSensors();
        double firstBeat = -1, firstInj = -1, firstOut = -1; long beats = 0; int resets = 0;
        e.Rpm = 850; e.MapKpa = 33;
        sim.Bus.OnDataWrite = null;
        for (ulong end = (ulong)(14 * Bus.CpuHz); sim.Cpu.Cycles < end && sim.State != RunState.Faulted;)
        {
            sim.StepOne(); if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
            double t = sim.Cpu.Cycles / Bus.CpuHz;
            if (firstBeat < 0 && sim.Bus.Pins.Changes[2, 4] > 0) firstBeat = t;
            if (firstInj < 0 && sim.Bus.InjectorEvents.Sum() > 0) firstInj = t;
        }
        Console.WriteLine($"{Path.GetFileName(f).Replace(".defines.txt", ""),-28} first heartbeat {firstBeat,5:0.00} s   first injector pulse {firstInj,5:0.00} s   traps {sim.TrapLog.Count}");
    }
    return 0;
}
if (args.Contains("--wdtscan"))
{
    // --wdtscan <folder>: the gaps between watchdog refreshes once the ROM has booted, per ROM, over idle / cruise / WOT / crank
    foreach (var f in Directory.GetFiles(args.SkipWhile(a => a != "--wdtscan").Skip(1).First(), "*.defines.txt").Order())
    {
        var defs = File.ReadAllLines(f).Select(l => l.Trim()).Where(l => l.Length > 0).ToArray();
        var b = sk.Build(defs);
        if (!b.Success) { Console.WriteLine(Path.GetFileName(f) + ": does not build"); continue; }
        var asm = b.Assembly!;
        var sim = new Simulator(); sim.LoadRom((byte[])asm.Image.Clone());
        var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 0; e.MapKpa = 101; e.VbattVolts = 12.4; sim.SyncSensors();
        ulong last = 0; ushort lastPc = 0; var gaps = new List<double>(); bool on = false; string worstAt = ""; double worst = 0;
        sim.Bus.OnDataWrite = (addr, _, val) =>
        {
            if (addr != Bus.SfrWdt || val != 0xC3) return;
            ulong now = sim.Cpu.Cycles;
            if (on) { double ms = (now - last) / (double)Bus.CpuHz * 1000; gaps.Add(ms); if (ms > 60 && Environment.GetEnvironmentVariable("WDTLIST") == "1") Console.WriteLine($"    {ms,6:0.0} ms gap ending at {now / (double)Bus.CpuHz:0.000} s, refreshed at {sim.Bus.CurrentPc:X4} {asm.LabelAt(sim.Bus.CurrentPc)}, previous at {lastPc:X4} {asm.LabelAt(lastPc)}"); if (ms > worst) { worst = ms; worstAt = $"{sim.Bus.CurrentPc:X4} {asm.LabelAt(sim.Bus.CurrentPc)} after {lastPc:X4} {asm.LabelAt(lastPc)} at {now / (double)Bus.CpuHz:0.00}s rpm {e.Rpm:0}"; } }
            last = now; lastPc = sim.Bus.CurrentPc;
        };
        void Go(double secs) { for (ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz); sim.Cpu.Cycles < end && sim.State != RunState.Faulted;) { sim.StepOne(); if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); } }
        Go(Environment.GetEnvironmentVariable("WDTFROM") is { } wf ? double.Parse(wf) : 6); on = true;
        foreach (var (rpm, map, cr) in new[] { (850, 33, false), (3000, 60, false), (7500, 100, false), (250, 90, true), (850, 33, false) })
        { e.Cranking = cr; e.Rpm = rpm; e.MapKpa = map; sim.SyncSensors(); Go(1.5); }
        Console.WriteLine($"{Path.GetFileName(f).Replace(".defines.txt", ""),-28} refreshes {gaps.Count,4}  average gap {(gaps.Count > 0 ? gaps.Average() : 0),6:0.0} ms  worst {worst,6:0.0} ms at {worstAt}");
    }
    return 0;
}
if (args.Contains("--tmr1miss"))
{
    // --tmr1miss DEFINE...: every time the timer 1 compare register (the idle valve's PWM phases) is set, how far ahead of the counter it is; a value already passed waits a whole turn of the timer (52 ms)
    var defs = args.SkipWhile(a => a != "--tmr1miss").Skip(1).ToArray();
    var b = sk.Build(defs);
    if (!b.Success) { Console.WriteLine(string.Join(" | ", b.Errors)); return 2; }
    var sim = new Simulator(); sim.LoadRom((byte[])b.Assembly!.Image.Clone());
    var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 0; e.MapKpa = 101; e.VbattVolts = 13.8; sim.SyncSensors();
    ushort prev = 0; long sets = 0, missed = 0, close = 0; int minAhead = 99999; var samples = new List<int>();
    string phase = "";
    var stats = new Dictionary<string, (long Sets, long Missed, int Min)>();
    void Go(double secs)
    {
        for (ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz); sim.Cpu.Cycles < end && sim.State != RunState.Faulted;)
        {
            sim.StepOne();
            ushort tmr = (ushort)(sim.Bus.Ram[0x36] | (sim.Bus.Ram[0x37] << 8));
            if (tmr != prev)
            {
                prev = tmr;
                ushort tm = (ushort)(sim.Bus.Ram[0x34] | (sim.Bus.Ram[0x35] << 8));
                int ahead = (ushort)(tmr - tm);
                bool past = ahead > 0x8000;
                var st = stats.GetValueOrDefault(phase);
                stats[phase] = (st.Sets + 1, st.Missed + (past ? 1 : 0), Math.Min(st.Min == 0 ? int.MaxValue : st.Min, past ? -1 : ahead));
            }
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
        }
    }
    phase = "boot"; Go(6);
    foreach (var (name, rpm, map, cr, ect) in new[] { ("idle", 850, 33, false, 85), ("cruise", 3000, 60, false, 85), ("WOT", 7000, 100, false, 85), ("cold crank", 250, 90, true, -10), ("cold idle", 1200, 35, false, -10) })
    { phase = name; e.Cranking = cr; e.Rpm = rpm; e.MapKpa = map; e.EctCelsius = ect; sim.SyncSensors(); Go(2); }
    foreach (var (n, st) in stats) Console.WriteLine($"  {n,-11} compare set {st.Sets,5} times, passed already {st.Missed,4}, nearest ahead {st.Min,5} counts ({st.Min * 0.8:0} us)");
    return 0;
}
if (args.Contains("--cmpmiss"))
{
    // --cmpmiss DEFINE...: for timers 0, 1 and 3, how often a compare register is set to a time that has already passed (over the boot and an idle / cruise / WOT / cold-crank run)
    var defs = args.SkipWhile(a => a != "--cmpmiss").Skip(1).ToArray();
    var b = sk.Build(defs);
    if (!b.Success) { Console.WriteLine(string.Join(" | ", b.Errors)); return 2; }
    var sim = new Simulator(); sim.LoadRom((byte[])b.Assembly!.Image.Clone());
    var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 0; e.MapKpa = 101; e.VbattVolts = 13.8; sim.SyncSensors();
    (int Tm, int Tmr, string Name)[] timers = [(0x30, 0x32, "timer 0"), (0x34, 0x36, "timer 1"), (0x3C, 0x3E, "timer 3")];
    var prev = new ushort[3]; var sets = new long[3]; var past = new long[3];
    void Go(double secs)
    {
        for (ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz); sim.Cpu.Cycles < end && sim.State != RunState.Faulted;)
        {
            sim.StepOne();
            for (int i = 0; i < 3; i++)
            {
                ushort tmr = (ushort)(sim.Bus.Ram[timers[i].Tmr] | (sim.Bus.Ram[timers[i].Tmr + 1] << 8));
                if (tmr == prev[i]) continue;
                prev[i] = tmr;
                ushort tm = (ushort)(sim.Bus.Ram[timers[i].Tm] | (sim.Bus.Ram[timers[i].Tm + 1] << 8));
                sets[i]++; if ((ushort)(tmr - tm) > 0x8000) past[i]++;
            }
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
        }
    }
    Go(6);
    foreach (var (rpm, map, cr, ect) in new[] { (850, 33, false, 85), (3000, 60, false, 85), (7000, 100, false, 85), (250, 90, true, -10), (1200, 35, false, -10) })
    { e.Cranking = cr; e.Rpm = rpm; e.MapKpa = map; e.EctCelsius = ect; sim.SyncSensors(); Go(2); }
    Console.WriteLine(string.Join("   ", Enumerable.Range(0, 3).Select(i => $"{timers[i].Name}: {past[i]} of {sets[i]} sets already passed")));
    return 0;
}
if (args.Contains("--hwroms"))
{
    // --hwroms <count> <seed> <folder>: random module mixes for the car, checked in the simulator first (HwRoms.cs)
    var hr = args.SkipWhile(a => a != "--hwroms").Skip(1).ToArray();
    return HwRoms.Run(sk, int.Parse(hr[0]), int.Parse(hr[1]), hr[2]);
}
if (args.Contains("--imagehash")) return ImageHash.Run(sk, args.SkipWhile(a => a != "--imagehash").Skip(1).FirstOrDefault() ?? "check", args.SkipWhile(a => a != "--imagehash").Skip(2).FirstOrDefault() ?? Path.Combine(root, "tools", "p13", "p30-images.txt"));
if (args.Contains("--romrun")) return RomRun.Run([.. args.SkipWhile(a => a != "--romrun").Skip(1)]);
if (args.Contains("--p13try")) return P13Try.Run(root, args);
if (args.Contains("--ramfree")) return RamUse.Run(sk, [.. args.SkipWhile(a => a != "--ramfree").Skip(1)]);
if (args.Contains("--dlrate")) return DlRate.Run(sk, [.. args.SkipWhile(a => a != "--dlrate").Skip(1)]);
if (args.Contains("--tickprofile")) return TickProfile.Run(sk, [.. args.SkipWhile(a => a != "--tickprofile").Skip(1)]);
if (args.Contains("--modecheck")) return ModeCheck.Run(sk, args.Contains("--quick"));
if (args.Contains("--basemaps"))
{
    int bad = 0;
    BaseMaps.Run(sk, (name, ok, detail) => { if (!ok) bad++; Console.WriteLine($"  {(ok ? "PASS" : "FAIL")}  {name,-70} {detail}"); });
    Console.WriteLine(bad == 0 ? "ALL PASS" : $"{bad} FAILED");
    return bad == 0 ? 0 : 1;
}
if (args.Contains("--fallcheck")) return DeadCode.FallCheck(sk, Path.Combine(root, "roms", "p30-skeleton.asm"));
if (args.Contains("--deadcode")) return DeadCode.Run(sk, Path.Combine(root, "roms", "p30-skeleton.asm"), args);
if (args.Contains("--features"))
{
    foreach (var f in sk.Features.OrderBy(f => f.Stock).ThenBy(f => f.Category))
        Console.WriteLine($"{(f.Stock ? "S" : "M")} {f.Define,-26} {f.Category,-14} ram:{f.Ram,-12} req:{string.Join("+", f.Requires),-22} conf:{string.Join("+", f.Conflicts),-20} {f.Name}");
    return 0;
}
if (args.Contains("--faultdisable")) return FaultDisableTest.Run(args.SkipWhile(a => a != "--faultdisable").Skip(1).First(), sk);
if (args.Contains("--hdltest")) return HdlTest.Run();
if (args.Contains("--simdl")) return SimDl.Run([.. args.SkipWhile(a => a != "--simdl").Skip(1)]);
if (args.Contains("--relay")) return RelayCheck.Run();
if (args.Contains("--clearcodes"))
{
    // --clearcodes ROM.asm: a MAP sensor fault (0 V) lights the lamp and stores code 3; the sensor comes back, then the
    // datalog's clear-codes command (50h): what the lamp and the stored codes do after it
    var path = Path.GetFullPath(args.SkipWhile(a => a != "--clearcodes").Skip(1).FirstOrDefault() ?? "D:/PublicOkiRomSim/Templates/HTS120.asm");
    var asmC = new OkiRomSim.Assembler.OkiAssembler().AssembleFile(path);
    if (!asmC.Success) { Console.WriteLine("does not build"); return 1; }
    var sim = new Simulator(); sim.LoadRom((byte[])asmC.Image.Clone());
    var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 900; e.MapKpa = 35; e.VbattVolts = 14; sim.SyncSensors();
    var mil = new MilMonitor();
    int field = MilMonitor.FaultFieldBase(asmC.Image);
    int? stored = MilMonitor.StoredArray(asmC.Image);
    void RunFor(double seconds, Action? every = null)
    {
        ulong end = sim.Cpu.Cycles + (ulong)(seconds * Bus.CpuHz);
        while (sim.Cpu.Cycles < end && sim.StepOne() != null)
        {
            if ((sim.Cpu.Instructions & 1023) == 0) { every?.Invoke(); sim.SyncSensors(); }
            if ((sim.Cpu.Instructions & 255) == 0) mil.Sample(sim.Bus, sim.Cpu.Cycles);
        }
    }
    string State() => $"lamp {(mil.Lamp ? "ON" : "off")}, fault field {Convert.ToHexString(sim.Bus.Ram, field, 6)}" +
                      (stored is int st ? $", stored {Convert.ToHexString(sim.Bus.Ram, st, 4)}" : "") + $", P1 {sim.Bus.Ram[Bus.SfrP1]:X2}";
    RunFor(6);
    Console.WriteLine("running:          " + State());
    e.MapKpa = 0; RunFor(4, () => sim.Engine.MapKpa = 0);
    Console.WriteLine("MAP at 0 V:       " + State());
    e.MapKpa = 35; RunFor(4);
    Console.WriteLine("MAP back:         " + State());
    var link = new DatalogLayout.SimLink(sim);
    link.Write([0x50]);
    RunFor(1);
    var ansBuf = new byte[1]; int got = link.Read(ansBuf, 0, 1, 200);
    RunFor(4);
    Console.WriteLine($"after 50h ({(got > 0 ? ansBuf[0].ToString("X2") : "no answer")}): " + State() + $", state {sim.State}");
    return 0;
}
if (args.Contains("--harddisable"))
{
    // every trouble code hard-disabled in turn, the way the MIL window does it (sites from the source map, each source line
    // replaced keeping its label): the edited source must still build, with the fault's instructions gone
    string[] hdDefs = ["FEAT_STOCK_DTC", "FEAT_STOCK_SELFTEST", "FEAT_DATALOG"];
    var b0 = sk.Build(hdDefs);
    // the build file the app would open: the defines, then the skeleton
    var hdMain = Path.Combine(Path.GetDirectoryName(sk.Path)!, "harddisable-check.asm");
    var hdMainText = sk.BuildSource(hdDefs, Path.GetFileName(sk.Path), "harddisable-check");
    if (!b0.Success) { Console.WriteLine("does not build"); return 1; }
    var asm0 = b0.Assembly!;
    int field = OkiRomSim.Core.MilMonitor.FaultFieldBase(asm0.Image);
    var code = asm0.SourceMap.Select(e => (e.Address, e.Length, e.File, e.Line)).ToList();
    var texts = asm0.Files.Distinct().ToDictionary(f => f, File.ReadAllText, StringComparer.OrdinalIgnoreCase);
    int bad = 0, tried = 0;
    for (int c = 1; c <= 50; c++)
    {
        var sites = FaultDisable.BitsFor(c).SelectMany(bit => FaultDisable.Find(asm0.Image, field, bit, code)).Where(x => x.File != null).ToList();
        if (sites.Count == 0) continue;
        tried++;
        var edited = new Dictionary<string, string>(texts, StringComparer.OrdinalIgnoreCase);
        foreach (var byFile in sites.GroupBy(x => x.File!))
        {
            var src = edited.First(kv => string.Equals(Path.GetFullPath(kv.Key), Path.GetFullPath(byFile.Key), StringComparison.OrdinalIgnoreCase));
            var lines = src.Value.Split('\n').Select(l => l.TrimEnd('\r')).ToList();
            foreach (var x in byFile) lines[x.Line - 1] = FaultDisable.KeepLabel(lines[x.Line - 1], FaultDisable.SourceLine(x, c));
            edited[src.Key] = string.Join("\n", lines);
        }
        var main = hdMain;
        var r = new OkiRomSim.Assembler.OkiAssembler(new OkiRomSim.Assembler.AssemblerOptions
        {
            ReadFile = f => string.Equals(f, Path.GetFullPath(hdMain), StringComparison.OrdinalIgnoreCase) ? hdMainText
                          : edited.FirstOrDefault(kv => string.Equals(Path.GetFullPath(kv.Key), f, StringComparison.OrdinalIgnoreCase)).Value,
        }).AssembleFile(main);
        bool gone = r.Success && sites.All(x => r.Image[x.Address] == 0 && r.Image[x.Address + 1] == 0 && r.Image[x.Address + 2] == 0);
        if (!gone) bad++;
        if (!gone && bad == 1)
        {
            var x0 = sites[0];
            Console.WriteLine($"  site {x0.Address:X4} {x0.File} line {x0.Line}: was {Convert.ToHexString(asm0.Image, x0.Address, 3)}, now {Convert.ToHexString(r.Image, x0.Address, 3)}; files {asm0.Files.Count}, main {main}");
            var src0 = edited.First(kv => string.Equals(Path.GetFullPath(kv.Key), Path.GetFullPath(x0.File!), StringComparison.OrdinalIgnoreCase)).Value.Split('\n')[x0.Line - 1];
            Console.WriteLine($"  edited line: {src0}");
        }
        Console.WriteLine($"{(gone ? "PASS" : "FAIL")} code {c,2}: {sites.Count} site(s){(r.Success ? "" : ": " + string.Join(" | ", r.Diagnostics.Where(d => d.Severity == OkiRomSim.Assembler.Severity.Error).Take(2).Select(d => d.Message)))}");
    }
    Console.WriteLine(bad == 0 ? $"ALL PASS ({tried} codes)" : $"{bad} FAILED");
    return bad == 0 ? 0 : 1;
}
if (args.Contains("--wizard"))
{
    // --wizard ROM.asm: the set-up wizard's plan with each stock ECU as the base maps - how many bytes each would change
    var romPath = Path.GetFullPath(args.SkipWhile(a => a != "--wizard").Skip(1).FirstOrDefault() ?? "../../../../../../roms/HTS115.asm");
    var repo = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../../"));
    var asmW = new OkiRomSim.Assembler.OkiAssembler().AssembleFile(romPath);
    if (!asmW.Success) { Console.WriteLine("does not build"); return 1; }
    var defsW = DefinitionBuilder.FromAssembly(asmW, Path.GetFileNameWithoutExtension(romPath));
    defsW.MergeBuiltinFormulas();
    var imgW = (byte[])asmW.Image.Clone();
    HtsLayout.Apply(defsW, imgW);
    Console.WriteLine($"{Path.GetFileName(romPath)}: identified as {HtsLayout.Identify(imgW).Name}");
    // Detect, as the app's button does (the maps come from it)
    var det = CalibrationDetector.Detect(defsW, asmW, imgW, [(romPath, File.ReadAllText(romPath))], RomReference.ShippedFor(romPath));
    Console.WriteLine($"detect: {det.Maps} maps, {det.Added} added");
    foreach (var m in defsW.Items.Where(i => i.IsTable && i.Rows > 1 && i.Cols > 3))
        Console.WriteLine($"  map {m.Name} role {MapImport.RoleOf(m).Kind} cols {m.Cols} colaxis {(m.ColAxis?.Address is int ca ? ca.ToString("X4") : "-")} formula '{m.ColAxis?.Formula}' unit '{(m.ColAxis == null ? "" : defsW.Formula(m.ColAxis.Formula).Unit)}'");
    var plan0 = SetupPlanner.Make(defsW, imgW, new SetupChoices { BoostPsi = 10 }, null, null);
    Console.WriteLine($"boost 10 psi: {MapImport.Diff(imgW, plan0.Image).Count} bytes | {string.Join("; ", plan0.Done)} | not: {string.Join("; ", plan0.NotHere)}");
    var lib = PresetLibrary.Load(Path.Combine(repo, "Templates", "Presets"));
    foreach (var bm in lib.BaseMaps)
    {
        var plan = SetupPlanner.Make(defsW, imgW, new SetupChoices { BaseMap = bm }, lib, Path.Combine(repo, "Templates", "HTS120.asm"));
        int n = MapImport.Diff(imgW, plan.Image).Count;
        Console.WriteLine($"{n,6} bytes  {bm}  | {string.Join("; ", plan.Done)} | not: {string.Join("; ", plan.NotHere)}");
    }
    return 0;
}
if (args.Contains("--htsdeadtime"))
{
    // HTS120's Deadtime word, in the simulator: what one raw count adds to the injector pulse (the ROM adds it to the
    // timer value of the base pulse), so the setting's formula can be checked against the ECU rather than a guess
    var path = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../../roms/HTS120.asm"));
    var asm = new OkiRomSim.Assembler.OkiAssembler(new OkiRomSim.Assembler.AssemblerOptions()).AssembleText(File.ReadAllText(path), path);
    if (!asm.Success) { Console.WriteLine("HTS120 does not build: " + string.Join(" | ", asm.Diagnostics.Take(2))); return 1; }
    int at = (int)asm.Symbols.Values.First(sy => sy.Name == "Deadtime").Value;
    double Pulse(int raw)
    {
        var img = (byte[])asm.Image.Clone();
        img[at] = (byte)raw; img[at + 1] = (byte)(raw >> 8);
        RomChecksum.Balance(img, asm.ChecksumAddress ?? 0x7FFF);
        var sim = new Simulator(); sim.LoadRom(img);
        var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 30; e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; e.VbattVolts = 14; sim.SyncSensors();
        ulong end = sim.Cpu.Cycles + (ulong)(8 * Bus.CpuHz);
        double sum = 0; int n = 0;
        while (sim.Cpu.Cycles < end && sim.StepOne() != null)
        {
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
            if ((sim.Cpu.Instructions & 4095) == 0 && sim.Cpu.Cycles > end - (ulong)(2 * Bus.CpuHz) && sim.Bus.InjectorPulseWidthUs > 0) { sum += sim.Bus.InjectorPulseWidthUs; n++; }
        }
        return n == 0 ? 0 : sum / n;
    }
    double p0 = Pulse(0), p8 = Pulse(8), p312 = Pulse(312);
    Console.WriteLine($"Deadtime raw 0: {p0:0} us; raw 8 (HTS-master's 1.00 ms): {p8:0} us (+{p8 - p0:0}); raw 312 (1 ms at 3.2 us a count): {p312:0} us (+{p312 - p0:0})");
    Console.WriteLine($"one count = {(p312 - p0) / 312:0.00} us");
    return 0;
}
if (args.Contains("--onboard")) return OnboardCheck.Run();
if (args.Contains("--rammap")) return RamMapCheck.Run(sk);
if (args.Contains("--importcheck")) return ImportCheck.Run(sk, Path.Combine(root, "Templates", "HTS120.asm"));
if (args.Contains("--sumtest")) return Review.SumTest(args.SkipWhile(a => a != "--sumtest").Skip(1).First());
if (args.Contains("--buildinfo"))
{
    var defs = args.SkipWhile(x => x != "--buildinfo").Skip(1).ToArray();
    var bi = sk.Build(defs);
    Console.WriteLine($"{string.Join(" ", defs)}: {(bi.Success ? "builds" : "FAILS")}, {bi.FreeBytes} bytes free");
    if (bi.Assembly != null)
    {
        foreach (var n in new[] { "MOD_RAM_BASE", "MOD_RAM_END", "MOD_FUELSUM", "skel_free_start" })
            if (bi.Assembly.Symbols.Values.FirstOrDefault(x => x.Name.Equals(n, StringComparison.OrdinalIgnoreCase)) is { } sy) Console.WriteLine($"  {n} = {sy.Value:X3}h");
        // where the calibration starts: the lowest annotated setting above the vectors
        var cal = DefinitionBuilder.FromAssembly(bi.Assembly, "info").Items.Where(i => i.Address >= 0x100).MinBy(i => i.Address);
        if (cal != null) Console.WriteLine($"  first calibration {cal.Address:X4}h {cal.Name}");
        foreach (var d in bi.Assembly.Diagnostics.Where(d => d.Severity != OkiRomSim.Assembler.Severity.Info)) Console.WriteLine($"  {d.Severity}: {d.Message}");
    }
    return 0;
}
if (args.Contains("--htspair")) return Review.HtsPair(args.SkipWhile(a => a != "--htspair").Skip(1).First());
if (args.Contains("--where"))
{
    var wa = new OkiRomSim.Assembler.OkiAssembler().AssembleFile(Path.Combine(root, "Templates", "HTS120.asm"));
    foreach (var h in args.SkipWhile(x => x != "--where").Skip(1))
    {
        int ad = Convert.ToInt32(h, 16);
        var e = wa.Lookup(ad);
        Console.WriteLine($"{ad:X4}: {(e == null ? "?" : $"{Path.GetFileName(e.File)}:{e.Line} (entry at {e.Address:X4}, {e.Length} bytes)")}  bytes {string.Join(" ", wa.Image.Skip(ad - 2).Take(6).Select(b => b.ToString("X2")))}");
    }
    return 0;
}
if (args.Contains("--stockram")) return Review.StockRam(sk);
if (args.Contains("--ramuse-stock")) return Review.RamUse("skeleton + stock functions", sk, [.. sk.Features.Where(f => f.Stock && f.Define != "FEAT_STOCK_SELFTEST").Select(f => f.Define)]);
if (args.Contains("--stackmap")) return Review.StackMap(sk, args.SkipWhile(a => a != "--stackmap").Skip(1).ToArray());
if (args.Contains("--ramusedefs")) return Review.RamUse("skeleton", sk, [.. args.SkipWhile(a => a != "--ramusedefs").Skip(1)]);
if (args.Contains("--imagehash")) return ImageHash.Run(sk, args.SkipWhile(a => a != "--imagehash").Skip(1).FirstOrDefault() ?? "check", args.SkipWhile(a => a != "--imagehash").Skip(2).FirstOrDefault() ?? Path.Combine(root, "tools", "p13", "p30-images.txt"));
if (args.Contains("--ramuse")) return Review.RamUse(args.SkipWhile(a => a != "--ramuse").Skip(1).First());
if (args.Contains("--reviewrom")) return Review.One(args.SkipWhile(a => a != "--reviewrom").Skip(1).First());
if (args.Contains("--htsbisect")) return Review.Bisect(Path.Combine(root, "Templates", "HTS120.asm"));
if (args.Contains("--review")) return Review.Run(sk, Path.Combine(root, "Templates", "HTS120.asm"), int.Parse(args.SkipWhile(a => a != "--review").Skip(1).FirstOrDefault(x => !x.StartsWith("--")) ?? "12"));
if (args.Contains("--time")) { Timing.Run(sk); return 0; }
if (args.Contains("--olderhts"))
{
    // HTS-master's base ROMs of the earlier versions (comma-separated bytes): identified, and the page rows bound
    var files = Directory.GetFiles(Path.Combine(root, "HTS-master", "DAT"), "ThisBytes1*.rom").Order().ToList();
    files.Add(Path.Combine(root, "HTS-master", "CDAT", "ThisBytes115.rom"));
    foreach (var file in files)
    {
        var parts = File.ReadAllText(file).Split(',', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 0x8000) { Console.WriteLine($"{Path.GetFileName(file)}: {parts.Length} values"); continue; }
        var rom = parts.Take(0x8000).Select(x => (byte)int.Parse(x.Trim())).ToArray();
        var id = HtsLayout.Identify(rom);
        var d = new DefinitionSet(); d.MergeBuiltinFormulas();
        int n = HtsLayout.Apply(d, rom);
        string Val(string slot) { var it = CalPage.Bound(d, slot); if (it == null) return "-"; try { return RomData.Read(d, rom, it)[0].Display; } catch (Exception ex) { return "!" + ex.Message; } }
        Console.WriteLine($"{Path.GetFileName(file)}: {id.Layout} '{id.Name}', {n} rows bound; revlimit.warmect {Val("revlimit.warmect")}, vtec.minect {Val("vtec.minect")}, inj x {Val("injector.multiplier")}, deadtime {Val("injector.deadtime")}, idle {Val("idle.rpm")}, launch {Val("launch.rpm")}, fuelcut.rpm {Val("fuelcut.rpm")}");
    }
    return 0;
}
if (args.Contains("--readrom"))
{
    foreach (var path in args.SkipWhile(a => a != "--readrom").Skip(1).TakeWhile(a => !a.StartsWith("--")))
    {
        (ProcessorProfile.Declared(File.ReadAllText(path)) ?? ProcessorProfile.Msm66207()).Apply();
        var asm = new OkiAssembler().AssembleFile(path);
        var d = DefinitionBuilder.FromAssembly(asm, "probe");
        int n = HtsLayout.Apply(d, asm.Image);
        if (args.Contains("--detect"))
        {
            var refs = RomReference.Shipped(Path.Combine(root, "src", "OkiRomSim.Desktop", "bin", "Release", "net10.0", "Templates"));
            var srcs = asm.SourceMap.Select(e => e.File).Distinct().Select(f => (f, File.ReadAllText(f))).ToList();
            var r = CalibrationDetector.Detect(d, asm, asm.Image, srcs, refs);
            bool Has(string? f) => f == null || d.Formulas.Any(x => x.Name.Equals(f, StringComparison.OrdinalIgnoreCase)) || f is "raw";
            var missing = d.Items.Where(i => !Has(i.Formula) || !Has(i.RowAxis?.Formula) || !Has(i.ColAxis?.Formula)).Select(i => $"{i.Name}[{i.Formula}]").ToList();
            Console.WriteLine($"  detect: {r.Summary}; without their formula: {missing.Count} {string.Join(" ", missing.Take(8))}");
        }
        foreach (var p in CalPage.ForRom(d)) CalPage.GuessBindings(d, p);
        if (args.Contains("--survey"))
        {
            bool Raw(string? f) => f is null or "raw" or "x";
            var noAxis = d.Items.Where(i => i.IsTable && i.Count > 1 && i.Text == null && ((i.Cols > 1 && i.ColAxis == null) || (i.Rows > 1 && i.RowAxis == null))).ToList();
            // a choice or a switch on a page is shown as one, not as a number; a list with an axis has its headers
            var rowKind = CalPage.ForRom(d).SelectMany(p => p.Groups).SelectMany(g => g.Rows).GroupBy(r => r.Slot).ToDictionary(g => g.Key, g => g.First().Kind);
            bool Shown(ItemDef i) => (i.Slot ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries).Any(sl => rowKind.TryGetValue(sl, out var k) && k is RowKind.Choice or RowKind.Switch or RowKind.Force);
            bool Internal(ItemDef i) => i.Category is "Internal" || System.Text.RegularExpressions.Regex.IsMatch(i.Name, "(?i)spare|pattern|count|number|snapshot|selftest|raminit|serial_|log_table|debounce|vector|index|input|output|selection|mode$|preset");
            var raw = d.Items.Where(i => i.Text == null && !i.Flag && i.Type != CellType.Bit && Raw(i.Formula) && !Shown(i) && !Internal(i) && i.ColAxis == null).ToList();
            Console.WriteLine($"  tables without axis headers: {noAxis.Count}; values shown raw: {raw.Count}");
            foreach (var i in noAxis.Take(80)) Console.WriteLine($"    AXIS {i.Name}@{i.Address:X4} {i.Rows}x{i.Cols} [{i.Formula}] rows:{i.RowAxis?.Name ?? i.RowAxis?.Formula ?? "-"} cols:{i.ColAxis?.Name ?? i.ColAxis?.Formula ?? "-"} ({i.Origin})");
            foreach (var i in raw.Take(120)) Console.WriteLine($"    RAW  {i.Name}@{i.Address:X4} {i.Type} x{i.Count} cat={i.Category} ({i.Origin}) {i.Description[..Math.Min(60, i.Description.Length)]}");
        }
        var bad = new List<string>();
        foreach (var it in d.Items) try { RomData.Read(d, asm.Image, it); } catch (Exception ex) { bad.Add($"{it.Name}@{it.Address:X4} [{it.Formula}] {ex.Message}"); }
        Console.WriteLine($"{Path.GetFileName(path)}: layout {n}, {d.Items.Count} items, {bad.Count} unreadable");
        foreach (var b in bad.Take(60)) Console.WriteLine("  " + b);
    }
    return 0;
}
if (args.Contains("--validrom"))
{
    var path = args.SkipWhile(a => a != "--validrom").Skip(1).First();
    (ProcessorProfile.Declared(File.ReadAllText(path)) ?? ProcessorProfile.Msm66207()).Apply();
    var asm = new OkiAssembler().AssembleFile(path);
    var d = DefinitionBuilder.FromAssembly(asm, "probe");
    Console.WriteLine($"HTS version {HtsLayout.Version(asm.Image)}, layout bound {HtsLayout.Apply(d, asm.Image)}");
    if (args.Contains("--guess")) foreach (var p in CalPage.ForRom(d)) CalPage.GuessBindings(d, p);
    foreach (var p in CalPage.ForRom(d))
    {
        var bound = p.Slots().Where(x => CalPage.Bound(d, x) != null).ToList();
        Console.WriteLine($"{(bound.Count > 0 ? "VALID" : "     ")} {p.Key,-16} {p.Name,-34} {bound.Count}/{p.Slots().Count()}  {string.Join(" ", bound.Take(3).Select(x => x + "=" + CalPage.Bound(d, x)!.Name + "@" + CalPage.Bound(d, x)!.Address.ToString("X4")))}");
    }
    return 0;
}
if (args.Contains("--validpages"))
{
    var defines = args.SkipWhile(a => a != "--validpages").Skip(1).TakeWhile(a => !a.StartsWith("--")).ToArray();
    var b = sk.Build(defines);
    var d = DefinitionBuilder.FromAssembly(b.Assembly!, "probe");
    if (args.Contains("--detect"))
    {
        var refs = RomReference.Shipped(Path.Combine(root, "src", "OkiRomSim.Desktop", "bin", "Release", "net10.0", "Templates"));
        var srcs = b.Assembly!.SourceMap.Select(e => e.File).Distinct().Select(f => (f, File.ReadAllText(f))).ToList();
        var r = CalibrationDetector.Detect(d, b.Assembly, b.Assembly.Image, srcs, refs);
        Console.WriteLine("detect: " + r.Summary);
        var builtin = new DefinitionSet(); builtin.MergeBuiltinFormulas();
        bool Has(string? f) => f == null || d.Formulas.Any(x => x.Name.Equals(f, StringComparison.OrdinalIgnoreCase));
        var missing = d.Items.Where(i => !Has(i.Formula) || !Has(i.RowAxis?.Formula) || !Has(i.ColAxis?.Formula)).Select(i => $"{i.Name}[{i.Formula}]").ToList();
        Console.WriteLine($"items without their formula: {missing.Count} {string.Join(" ", missing.Take(10))}");
    }
    if (args.Contains("--guess")) foreach (var p in CalPage.ForRom(d)) CalPage.GuessBindings(d, p);
    foreach (var p in CalPage.ForRom(d))
    {
        var bound = p.Slots().Where(x => CalPage.Bound(d, x) != null).ToList();
        if (bound.Count > 0) Console.WriteLine($"{p.Key,-16} {p.Name,-34} {bound.Count}/{p.Slots().Count()}  {string.Join(" ", bound.Take(4).Select(x => x + "=" + CalPage.Bound(d, x)!.Name))}");
    }
    return 0;
}
var only = args.SkipWhile(a => a != "--only").Skip(1).FirstOrDefault();
int failures = 0;
void Check(string what, bool ok, string detail)
{
    Console.WriteLine($"  {(ok ? "PASS" : "FAIL")}  {what,-66} {detail}");
    if (!ok) failures++;
}
bool Wanted(string section) => only == null || only.Split(',').Any(o => section.Contains(o, StringComparison.OrdinalIgnoreCase));

// ------------------------------------------------------------------ builds
var modules = sk.Features.Where(f => !f.Stock).ToList();
var stock = sk.Features.Where(f => f.Stock).ToList();
var cache = new Dictionary<string, SkeletonBuildResult>();
SkeletonBuildResult Build(params string[] defs)
{
    var key = string.Join(",", defs.OrderBy(d => d));
    if (!cache.TryGetValue(key, out var r)) cache[key] = r = sk.Build(defs);
    return r;
}
// A mix too big for the ROM made to fit, as the New ROM window offers: module RAM short, the module with the most of it
// out; the ROM full, the one with the most code - and whatever needs what went. `keep` never goes. Returns what went.
List<string> Fit(List<string> mix, params string[] keep)
{
    var gone = new List<string>();
    var b = Build([.. mix]);
    for (int guard = 0; !b.Success && guard < 60 && mix.Count > 1; guard++)
    {
        var can = mix.Where(d => !keep.Contains(d, StringComparer.OrdinalIgnoreCase)).ToList();
        string? drop = null;
        if (b.Ram is { Full: true } ram)
            drop = can.Where(d => sk.Feature(d) is { } f && ram.Uses.Any(u => u.Owner == f.Name))
                      .OrderByDescending(d => ram.Uses.Where(u => u.Owner == sk.Feature(d)!.Name).Sum(u => u.Bytes)).FirstOrDefault();
        else if (b.Errors.Any(e => e.Contains("the ROM is full")))
        {
            var bare0 = Build();
            drop = can.OrderByDescending(d => Build(d) is { Success: true } one ? bare0.FreeBytes - one.FreeBytes : 0).FirstOrDefault();
        }
        if (drop == null) break;
        mix.Remove(drop); gone.Add(drop);
        foreach (var d in mix.Where(d => sk.Feature(d)?.Requires.Contains(drop, StringComparer.OrdinalIgnoreCase) == true).ToList()) { mix.Remove(d); gone.Add(d); }
        b = Build([.. mix]);
    }
    return gone;
}
// every setting a module declares can be read, with a formula that exists (a page row that says "cannot read" otherwise)
if (Wanted("readable"))
{
    foreach (var f in sk.Features)
    {
        var set = new List<string> { f.Define };
        set.AddRange(f.Requires);
        var r = Build([.. set]);
        if (!r.Success || r.Assembly == null) { Check($"{f.Define}: settings readable", false, "does not build"); continue; }
        var defs = DefinitionBuilder.FromAssembly(r.Assembly, "test");
        var bad = new List<string>();
        foreach (var item in defs.Items)
            try { RomData.Read(defs, r.Assembly.Image, item); }
            catch (Exception ex) { bad.Add($"{item.Name}: {ex.Message}"); }
        Check($"{f.Define}: every setting readable", bad.Count == 0, string.Join("; ", bad.Take(4)));
    }
}

// the build file keeps the ROM's name and version and the watermark / password: they survive a rebuild from source
if (Wanted("kept"))
{
    Console.WriteLine("values kept in the build file");
    // (the skeleton the run is on: the P13's name is at 7FC0h; the build file next to it, so it includes that copy)
    string idText = Platform.P13 ? "P13-OPENH001" : "P30-OPENH001"; int idAt = Platform.P13 ? 0x7FC0 : 0x7FE0;
    var tmp = Path.Combine(Path.GetDirectoryName(sk.Path)!, "_kept_test.asm");
    try
    {
        var text = sk.BuildSource(["FEAT_WATERMARK"], Path.GetFileName(sk.Path), "_kept_test");
        File.WriteAllText(tmp, text);
        var a1 = new OkiAssembler().AssembleFile(tmp);
        Check($"  named: builds, and says {idText} at {idAt:X4}", a1.Success && System.Text.Encoding.ASCII.GetString(a1.Image, idAt, 12) == idText,
              a1.Success ? System.Text.Encoding.ASCII.GetString(a1.Image, idAt, 12) : string.Join("; ", a1.Diagnostics.Take(3)));
        int wmAt = (int)a1.Symbols["watermark_data"].Value;
        var wm = new byte[WatermarkCodec.Bytes + RomPassword.Bytes];
        WatermarkCodec.Encode("").CopyTo(wm, 0);
        RomPassword.Create("abcd123").CopyTo(wm, WatermarkCodec.Bytes);
        text = Skeleton.WithKept(text, null, idAt, wm);
        File.WriteAllText(tmp, text);
        var a2 = new OkiAssembler().AssembleFile(tmp);
        Check("  with a password: builds, locked, the name kept, checksum balanced", a2.Success && RomPassword.Locked(a2.Image) == wmAt + WatermarkCodec.Bytes
              && RomPassword.Check(a2.Image.AsSpan(wmAt + WatermarkCodec.Bytes), "abcd123") && System.Text.Encoding.ASCII.GetString(a2.Image, idAt, 12) == idText
              && RomChecksum.Sum(a2.Image) == 0, a2.Success ? "" : string.Join("; ", a2.Diagnostics.Take(3)));
        Check("  the same size as without (the module's own bytes are left out, not doubled)", a2.UsedBytes == a1.UsedBytes, $"{a1.UsedBytes} / {a2.UsedBytes}");
        var bare = Build("FEAT_WATERMARK");
        Check($"  a build without the watermark says {idText} too", System.Text.Encoding.ASCII.GetString(bare.Assembly!.Image, idAt, 12) == idText, "");
    }
    finally { File.Delete(tmp); }
}

// the watermark's open password: set, checked, found by Detect in the bare .bin
if (Wanted("password"))
{
    Console.WriteLine("open password (watermark module)");
    var b = Build("FEAT_WATERMARK");
    var img = (byte[])b.Assembly!.Image.Clone();
    int at = RomPassword.Find(img);
    Check("  the password block is in the build, with none set", at >= 0 && RomPassword.Locked(img) < 0, $"at {at:X4}");
    var block = RomPassword.Create("password123");
    block.CopyTo(img, at);
    RomChecksum.Balance(img, b.Assembly.ChecksumAddress ?? 0x7FFF);
    Check("  set: the ROM is locked and its checksum balances", RomPassword.Locked(img) == at && RomChecksum.Sum(img) == 0, "");
    Check("  the right password opens it, a wrong one does not",
        RomPassword.Check(img.AsSpan(at), "password123") && !RomPassword.Check(img.AsSpan(at), "password124") && !RomPassword.Check(img.AsSpan(at), ""), "");
    Check("  the password is not in the ROM's bytes", img.AsSpan().IndexOf("password123"u8) < 0, "");
    // a .bin with no labels: disassembled, built, Detect finds the block and the watermark before it
    var dis = BinDisassembler.Disassemble(img, "locked.bin");
    var tmp = Path.Combine(Path.GetTempPath(), "locked.asm");
    var asm2 = new OkiAssembler(new AssemblerOptions { ReadFile = f => f == Path.GetFullPath(tmp) ? dis.Text : null }).AssembleText(dis.Text, tmp);
    var d2 = DefinitionBuilder.FromAssembly(asm2, "locked");
    CalibrationDetector.Detect(d2, asm2, asm2.Image, [(tmp, dis.Text)]);
    var pw = d2.Items.FirstOrDefault(i => i.Text == "password");
    var wm = d2.Items.FirstOrDefault(i => i.Text == "watermark");
    Check("  Detect on the bare .bin finds the password block and the watermark", pw?.Address == at && wm?.Address == at - WatermarkCodec.Bytes,
        $"{pw?.Name}@{pw?.Address:X4} {wm?.Name}@{wm?.Address:X4}");
}

if (Wanted("build"))
{
    Console.WriteLine($"{sk.Name}: {modules.Count} modules, {stock.Count} stock functions");
    var bare = Build();
    Check("the bare skeleton builds", bare.Success, $"{bare.UsedBytes} bytes used, {bare.FreeBytes} free");
    Check("  and its checksum byte balances the image", bare.Assembly != null && RomChecksum.Sum(bare.Assembly.Image) == 0, "");
    foreach (var f in sk.Features)
    {
        var r = Build(f.Define);
        Check($"{f.Define} alone", r.Success && RomChecksum.Sum(r.Assembly!.Image) == 0,
            r.Success ? $"{bare.FreeBytes - r.FreeBytes,5} bytes of code and tables, {r.FreeBytes} free" : string.Join("; ", r.Errors.Take(2)));
    }
    // every module together (the first of any conflicting pair), then with every stock function too
    var mix = new List<string>();
    foreach (var f in modules) if (sk.Problems([.. mix, f.Define]).Count == 0) mix.Add(f.Define);
    // every module together wants 60 of the 56 bytes of module RAM: that build must say so (the New ROM window then offers
    // what to leave out); the rest of the checks run with rolling idle, one of the offered ways, left out
    var fullRam = Build([.. mix]);
    Check("every module together: refused for module RAM, not built wrong", !fullRam.Success && fullRam.Ram is { Full: true },
          fullRam.Ram is { } fr ? $"{fr.Used} of {fr.Size} bytes" : string.Join("; ", fullRam.Errors.Take(1)));
    mix.Remove("FEAT_ROLLIDLE");
    mix.Remove("FEAT_REMOTE");
    mix.Remove("FEAT_TPSRETARD");
    // more modules than when that list was made: what still does not fit comes out too
    var leftOut = Fit(mix);
    if (leftOut.Count > 0) Console.WriteLine("  left out as well, to fit: " + string.Join(", ", leftOut));
    var all = Build([.. mix]);
    Check($"all {mix.Count} compatible modules together", all.Success, all.Success ? $"{all.FreeBytes} bytes free" : (all.Ram is { } ar ? $"module RAM {ar.Used} of {ar.Size}; " : "") + string.Join("; ", all.Errors.Take(2)));
    // the free space reported is what is really left: that many bytes, all erased (FFh), right below the hook table
    foreach (var (what, r) in new[] { ("bare", bare), ("all modules", all) })
    {
        if (!r.Success) continue;
        long f0 = Sym(r.Assembly!, "skel_free_start"), hooks = Sym(r.Assembly!, "hook_init");
        int blank = 0;
        for (long a = f0; a < hooks; a++) if (r.Assembly!.Image[a] == 0xFF) blank++;
        long lastUsed = f0 - 1;
        Check($"  {what}: free space {r.FreeBytes} bytes = {f0:X4}h-{hooks - 1:X4}h, all of it unused", blank == r.FreeBytes && hooks - f0 == r.FreeBytes,
            $"{blank} bytes FFh of {hooks - f0}");
    }
    var everything = new List<string>(mix);
    foreach (var f in stock) if (sk.Problems([.. everything, f.Define]).Count == 0) everything.Add(f.Define);
    var full = Build([.. everything]);
    Check($"... and every stock function beside them: fits, or says once by how much it does not", full.Success || full.Errors.Count == 1 && full.Errors[0].Contains("bytes too big"),
        full.Success ? $"{full.FreeBytes} bytes free" : "does not fit: " + full.Errors.First());
    // the order the defines come in makes no difference to the image
    var fwd = Build([.. mix]).Assembly!.Image;
    var rev = sk.Build(Enumerable.Reverse(mix)).Assembly!.Image;
    Check("the order features are picked in makes no difference", fwd.AsSpan().SequenceEqual(rev), "");
}

// ------------------------------------------------------------------ every instruction is one the CPU has
// An encoding the CPU has no opcode for stops the ECU dead the first time it runs: each instruction of each module is
// decoded as the CPU would, in byte or word mode. (Which mode it really runs in - LC and LCB leave the mode as it was,
// and a byte instruction run in word mode can be no instruction at all - only a run shows: the module tests.)
if (Wanted("opcodes"))
{
    var lines = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
    string Src(string file, int line)
    {
        if (!lines.TryGetValue(file, out var l)) lines[file] = l = File.Exists(file) ? File.ReadAllLines(file) : [];
        return line >= 1 && line <= l.Length ? l[line - 1] : "";
    }
    var bad = new List<string>();
    var seen = new HashSet<(string, int)>(); int checkedN = 0;
    foreach (var f in sk.Features.Where(f => !f.Stock).Append(null))
    {
        var r = f == null ? Build() : Build([f.Define, .. f.Requires]);
        if (!r.Success || r.Assembly == null) continue;
        var img = r.Assembly.Image;
        foreach (var e in r.Assembly.SourceMap)
        {
            if (e.Length == 0 || !seen.Add((e.File, e.Line))) continue;
            var text = Src(e.File, e.Line);
            int semi = text.IndexOf(';'); if (semi >= 0) text = text[..semi];
            var words = text.Replace(":", ": ").Split((char[])[' ', '\t'], StringSplitOptions.RemoveEmptyEntries).SkipWhile(w => w.EndsWith(':')).ToList();
            if (words.Count == 0 || words[0].ToUpperInvariant() is "DB" or "DW" or "DS" or "ORG" or "ALIGN" or "CHECKSUM" or "INCLUDE") continue;
            int at = e.Address; checkedN++;
            bool ok = new[] { false, true }.Any(dd => Decoder.Decode(dd, i => at + i < img.Length ? img[at + i] : (byte)0xFF) is { } d && d.Len == e.Length);
            if (!ok) bad.Add($"{Path.GetFileName(e.File)}:{e.Line} '{text.Trim()}' ({string.Join(" ", img.Skip(at).Take(e.Length).Select(b => b.ToString("X2")))})");
        }
    }
    Check("every module's instructions are ones the CPU has (in byte or word mode)", bad.Count == 0, $"{checkedN} instructions; " + string.Join("; ", bad.Take(6)));
}

// ------------------------------------------------------------------ byte and word mode, read from the source
// The mode follows the code: L A / CLR A / MOV A / POPS A / EXTND set word mode, LB A / CLRB A / MOVB A byte mode, and
// nothing else changes it (LC and LCB leave it as it was). An accumulator byte instruction met in word mode, or the
// other way round, is decoded as another instruction - often of another length, and the ECU runs off into the data.
// Straight-line code only: a label, a call or a jump makes the mode unknown, and nothing is said then.
if (Wanted("ddmode") && sk.FeaturesDir is { } fdir)
{
    string[] pairs = ["ADD", "ADC", "SUB", "SBC", "CMP", "AND", "OR", "XOR", "ST", "SLL", "SRL", "SRA", "ROL", "ROR", "INC", "DEC", "NEG", "CPL", "SWAP", "MUL", "DIV", "XCHG"];
    var wordOps = pairs.ToHashSet(); var byteOps = pairs.Select(p => p + "B").ToHashSet();
    var found = new List<string>(); int lineN = 0;
    foreach (var file in Directory.GetFiles(fdir, "*.asm").OrderBy(f => f))
    {
        char mode = '?'; int n = 0;
        foreach (var raw in File.ReadLines(file))
        {
            n++;
            var s = raw.Split(';')[0].Trim();
            if (s.Length == 0) continue;
            var low = s.ToLowerInvariant();
            if (System.Text.RegularExpressions.Regex.IsMatch(low, @"^(if|ifdef|ifndef|else|endif)\b")) { mode = '?'; continue; }
            if (System.Text.RegularExpressions.Regex.IsMatch(low, @"^(include|define|undef|org|end)\b")) continue;
            var m = System.Text.RegularExpressions.Regex.Match(s, @"^([A-Za-z_.$][\w.$]*)\s*:\s*(.*)$");
            if (m.Success) { mode = '?'; s = m.Groups[2].Value.Trim(); if (s.Length == 0) continue; }
            var parts = s.Split((char[])[' ', '\t'], 2, StringSplitOptions.RemoveEmptyEntries);
            string mn = parts[0].ToUpperInvariant(), ops = parts.Length > 1 ? parts[1] : "";
            if (mn is "EQU" or "DB" or "DW" or "DS" || ops.TrimStart().ToUpperInvariant().StartsWith("EQU")) { mode = '?'; continue; }
            lineN++;
            bool a = ops.Split(',')[0].Trim().Equals("A", StringComparison.OrdinalIgnoreCase);
            if (a && byteOps.Contains(mn) && mode == 'W') found.Add($"{Path.GetFileName(file)}:{n} {mn} A in word mode");
            if (a && wordOps.Contains(mn) && mode == 'B') found.Add($"{Path.GetFileName(file)}:{n} {mn} A in byte mode");
            if ((a && mn is "L" or "CLR" or "MOV" or "POPS") || mn == "EXTND") mode = 'W';
            else if (a && mn is "LB" or "CLRB" or "MOVB") mode = 'B';
            else if (mn is "CAL" or "VCAL" or "SCAL" or "J" or "SJ" or "RT" or "RTI" or "BRK") mode = '?';
        }
    }
    Check("every module's accumulator instructions run in the mode they were written for (byte / word)", found.Count == 0, $"{lineN} lines; " + string.Join("; ", found.Take(6)));
}

// ------------------------------------------------------------------ every setting on a page
if (Wanted("pages"))
{
    var mixP = new List<string>();
    foreach (var f in sk.Feature("FEAT_STOCK_DTC") is { } dtcF ? modules.Append(dtcF) : modules) if (sk.Problems([.. mixP, f.Define]).Count == 0) mixP.Add(f.Define);
    var goneP = Fit(mixP, "FEAT_STOCK_DTC", "FEAT_GIO4", "FEAT_WBCL");   // too big: fewer modules (the trouble codes, and the two checked below, kept)
    if (goneP.Count > 0) Console.WriteLine("  left out for the pages check, to fit: " + string.Join(", ", goneP));
    var bp = Build([.. mixP]);
    var defsP = DefinitionBuilder.FromAssembly(bp.Assembly!, "pages");
    var pages = CalPage.ForRom(defsP);
    var onPage = pages.SelectMany(p => p.Slots()).ToHashSet(StringComparer.OrdinalIgnoreCase);
    // the password block is kept by the watermark row, not a row of its own
    var slots = defsP.Items.Where(i => i.Slot != null && i.Text != "password").SelectMany(i => i.Slot!.Split(';')).Distinct().ToList();
    var off = slots.Where(x => !onPage.Contains(x)).ToList();
    Check($"every one of the {slots.Count} settings with a slot is on a page ({mixP.Count} functions built)", off.Count == 0, string.Join(" ", off.Take(8)));
    var more = pages.Where(p => p.Groups.Any(g => g.Title == "More settings")).Select(p => $"{p.Name} ({p.Groups.First(g => g.Title == "More settings").Rows.Length})");
    Console.WriteLine("  pages with a 'More settings' group: " + string.Join(", ", more));
    Console.WriteLine("  pages made for features no page is keyed for: " + string.Join(", ", pages.Where(p => p.Category == "Added features").Select(p => p.Name)));
    var gio4 = pages.FirstOrDefault(p => p.Key == "gpo4");
    Check("  the General purpose output 4 page, in the GIO modules' layout", gio4 != null && gio4.Slots().Contains("gpo4.rpm.on"), gio4?.Name ?? "missing");
    // each module, built in on its own: the pages its header names are there and valid (a setting bound)
    var bad = new List<string>();
    foreach (var f in modules)
    {
        var want = File.ReadLines(f.File!).Select(l => System.Text.RegularExpressions.Regex.Match(l, @"^;>\s*pages:\s*(.+)$")).FirstOrDefault(m => m.Success)?.Groups[1].Value
                       .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries) ?? [];
        var one = Build(f.Define);
        if (!one.Success) { bad.Add($"{f.Define}: does not build"); continue; }
        var d1 = DefinitionBuilder.FromAssembly(one.Assembly!, "one");
        var p1 = CalPage.ForRom(d1);
        foreach (var key in want)
        {
            // a header key names a page, or a family of them ("boardopt": one page per board flag)
            // (the board options: the P13's flags are their own pages, "boardopt.p13...", each platform's only on its ROMs)
            var fam = p1.Where(p => p.Key == key || p.Key.StartsWith(key + "."))
                        .Where(p => !p.Key.StartsWith("boardopt.") || p.Key.StartsWith("boardopt.p13") == Platform.P13).ToList();
            if (fam.Count == 0 || fam.Any(pg => !pg.Slots().Any(x => CalPage.Bound(d1, x) != null))) bad.Add($"{f.Define}: page '{key}'");
        }
        if (want.Length == 0 && File.ReadLines(f.File!).Any(l => l.StartsWith(";@") && l.Contains(" slot="))) bad.Add($"{f.Define}: settings, but no page");
    }
    Check("  every module, built in alone, has its page, and it is valid", bad.Count == 0, string.Join("; ", bad.Take(8)));
    // a project saved before a module was added, opened after: the module's settings and page come with the build
    var savedDefs = DefinitionBuilder.FromAssembly(Build().Assembly!, "saved");
    var withIdle = DefinitionSet.MergeSaved(DefinitionBuilder.FromAssembly(Build("FEAT_ROLLIDLE").Assembly!, "now"), savedDefs);
    Check("  a saved project, rebuilt with rolling idle added: its page is valid", CalPage.ForRom(withIdle).First(p => p.Key == "rollidle").Slots().All(x => CalPage.Bound(withIdle, x) != null), "");
    // a choice row takes the ROM's own list from its description: the skeleton numbers its analog inputs its own way
    var wb = defsP.Find("CloseLoopInput");
    var names = wb == null ? null : SaneLimits.ChoiceNames(wb.Description);
    // (the P13's list: O2, ELD, EGR lift, the TCS pin)
    Check("  an analog input's choices come from the module's own list: O2, ELD, EGR, B6, serial input 1-8", names is { Length: 12 } && names[0] == (Platform.P13 ? "O2" : "O2 (D14)")
          && names[3] == (Platform.P13 ? "The TCS pin (P5.5)" : "B6") && names[11] == "Serial input 8"
          && SaneLimits.Choices(wb!.Description) == 11 && SaneLimits.ChoiceNames("0 = fuel cut, 1 = ignition cut, 2 = both") is { Length: 3 },
          names == null ? "none" : string.Join(" | ", names));
    // (the P13 has no stock trouble codes function to switch codes off in yet)
    if (pages.FirstOrDefault(p => p.Key == "celcode") is { } cel)
    {
        int celBound = cel.Slots().Count(x => CalPage.Bound(defsP, x) != null);
        Check("  the Check engine codes page: a switch for each code the ROM sets", celBound >= 25, $"{celBound} of {cel.Slots().Count()} rows bound");
    }
    else Check("  the Check engine codes page: none on the P13 (no stock trouble codes function)", Platform.P13, "missing");
}

// ------------------------------------------------------------------ change functions: a tuned ROM rebuilt with others, its tune carried
if (Wanted("rebuild"))
{
    Console.WriteLine("File > Change functions: a tuned ROM rebuilt with VTEC control added and launch taken out");
    // a ROM made without VTEC control (as Default was before it had it)
    var from = SkeletonPresets.Fit(sk, SkeletonPresets.Default.Where(d => d != "FEAT_VTECCTL"));   // (as far as it goes on this skeleton)
    var a = Build([.. from]);
    var oldDefs = DefinitionBuilder.FromAssembly(a.Assembly!, "old");
    var tuned = (byte[])a.Assembly!.Image.Clone();
    // the tune: a fuel map cell, the rev limit, the injector scaling and coolant protection switched on
    var fuel = oldDefs.Items.First(i => i.IsTable && i.Rows > 5 && i.Name.Contains("Fuel", StringComparison.OrdinalIgnoreCase));
    var tunedAt = new Dictionary<string, (int Offset, byte Value)>
    {
        [fuel.Name] = (fuel.Span / 2, (byte)(tuned[fuel.Address + fuel.Span / 2] ^ 0x15)),
        ["revlimit_low_set"] = (0, 0x77),
        ["ectpro_block"] = (0, 1),
    };
    foreach (var (n, (off, v)) in tunedAt)
    {
        var it = oldDefs.Items.FirstOrDefault(i => i.Name == n);
        int at = it?.Address ?? (int)Sym(a.Assembly, n);
        tuned[at + off] = v;
    }
    RomChecksum.Balance(tuned, a.Assembly.ChecksumAddress ?? 0x7FFF);
    var said = SkeletonRebuild.FunctionsIn(tuned, sk);
    Check("a build says what it was built with (its build-info table)", said != null && said.Order().SequenceEqual(from.Where(d => sk.Feature(d) != null).Order()),
          said == null ? "none found" : string.Join(", ", said));
    Check("  rebuilt the same, its code matches a tuned image of it (only the tune differs)", SkeletonRebuild.CodeDifferences(Build([.. said!]).Assembly!, oldDefs, tuned) == 0, "");
    var to = from.Where(d => d != "FEAT_LAUNCH").Append("FEAT_VTECCTL").ToList();
    var b = Build([.. to]);
    var newDefs = DefinitionBuilder.FromAssembly(b.Assembly!, "new");
    var image = (byte[])b.Assembly!.Image.Clone();
    var carry = SkeletonRebuild.Carry(oldDefs, tuned, newDefs, image);
    foreach (var p in carry.Patches) image[p.Address] = p.Value;
    RomChecksum.Balance(image, b.Assembly.ChecksumAddress ?? 0x7FFF);
    bool Same(string n, int off)
    {
        var o = oldDefs.Items.FirstOrDefault(i => i.Name == n); var q = newDefs.Items.FirstOrDefault(i => i.Name == n);
        int oa = o?.Address ?? (int)Sym(a.Assembly, n), na = q?.Address ?? (int)Sym(b.Assembly, n);
        return tuned[oa + off] == image[na + off];
    }
    Check("  the tune is carried to where the new build put it (fuel map cell, rev limit, coolant protection on)",
          tunedAt.All(t => Same(t.Key, t.Value.Offset)) && carry.Tuned >= 3 && carry.Skipped.Count == 0,
          $"{carry.Carried} carried, {carry.Tuned} tuned, {carry.Patches.Count} bytes; skipped: {string.Join(", ", carry.Skipped)}");
    Check("  VTEC control's settings start at their factory values", carry.New.Contains("VTECOwnPoints") && newDefs.Items.First(i => i.Name == "VTECOwnPoints") is { } own && image[own.Address] == 0, "");
    var sim = new Simulator(); sim.LoadRom(image);
    var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 850; e.MapKpa = 33; sim.SyncSensors();
    long inj0 = 0;
    for (ulong end = sim.Cpu.Cycles + (ulong)(6 * Bus.CpuHz); sim.Cpu.Cycles < end;)
    {
        if (sim.StepOne() == null) break;
        if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
        if (inj0 == 0 && sim.Cpu.Cycles > (ulong)(4.5 * Bus.CpuHz)) inj0 = sim.Bus.InjectorEvents.Sum();
    }
    Check("  the rebuilt ROM, tune carried, starts and runs", sim.State != RunState.Faulted && sim.Bus.InjectorEvents.Sum() - inj0 > 10, $"{sim.Bus.InjectorEvents.Sum() - inj0} injections in 1.5 s, {sim.State}");
    // the build file: launch commented out, VTEC control switched on, everything else as it was
    var src = sk.BuildSource(from, "p30-skeleton.asm", "test");
    var changed = SkeletonRebuild.WithFunctions(src, sk, to);
    Check("  the build file's define lines follow the pick, the rest of it unchanged", Skeleton.DefinesIn(changed).Order().SequenceEqual(to.Where(d => sk.Feature(d) != null).Order())
          && changed.Split('\n').Length == src.Split('\n').Length, string.Join(", ", Skeleton.DefinesIn(changed)));
}

// ------------------------------------------------------------------ the set-up wizard on both kinds of ROM
// the P13's stock-function switches: what each leaves out, and that the engine still runs without it
if (Platform.P13 && Wanted("p13stock"))
{
    Console.WriteLine("P13 stock functions, in and out");
    // P13STOCK=egr,knock,hicam,vtecpress: only those parts (debugging one switch)
    var parts = (Environment.GetEnvironmentVariable("P13STOCK") ?? "egr,knock,hicam,vtecpress,outputs,selftest,dtc").Split(',');
    (int EgrMax, bool PwmOn, double O2Max, long Inj) StockDrive(string[] defs) { var x = StockDrive2(defs); return (x.EgrMax, x.PwmOn, x.O2Max, x.Inj); }
    (int EgrMax, bool PwmOn, double O2Max, long Inj, bool Heat, int Codes) StockDrive2(string[] defs)
    {
        int egr = 0; bool pwm = false, heat = false; double o2 = 0; int n = 0;
        var r = Run(defs, [], [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; }), Hold(9, e => { e.Rpm = 2500; e.MapKpa = 50; e.TpsPct = 15; e.SpeedKmh = 80; })],
            sim => { var m = sim.Bus.Ram; heat |= (m[0x25] & 0x04) == 0; if (++n < 400) return; egr = Math.Max(egr, m[0x294]); pwm |= (m[0x1F] & 0x10) != 0; o2 = Math.Max(o2, Math.Abs((m[0x160] | m[0x161] << 8) - 0x8000)); });
        var mm = r.Sim.Bus.Ram;
        return (egr, pwm, o2, r.InjPerSec.Count > 0 ? (long)r.InjPerSec[^1] : 0, heat, mm[0x330] | mm[0x331] << 8 | mm[0x332] << 16 | mm[0x333] << 24);
    }
    if (parts.Contains("egr"))
    {
    var all = StockDrive(["FEAT_STOCK_EGR", "FEAT_STOCK_O2"]);
    var none = StockDrive([]);
    Check("  with FEAT_STOCK_EGR: the EGR valve worked (a target, its PWM pin on) at a warm cruise", all.EgrMax > 0 && all.PwmOn, $"target {all.EgrMax}, pin {all.PwmOn}");
    Check("  without it: no target, the pin never on, and the engine runs", none.EgrMax == 0 && !none.PwmOn && none.Inj > 10, $"target {none.EgrMax}, pin {none.PwmOn}, {none.Inj} inj/s");
    var heatOn = StockDrive2(["FEAT_STOCK_O2HEATER", "FEAT_STOCK_DTC"]); var heatOff = StockDrive2(["FEAT_STOCK_DTC"]);
    Check("  with FEAT_STOCK_O2HEATER: the heater on (P2A.2 low) at some point; without it never; no trouble code either way",
          heatOn.Heat && !heatOff.Heat && heatOn.Codes == 0 && heatOff.Codes == 0, $"{heatOn.Heat} / {heatOff.Heat}; codes {heatOn.Codes:X8} / {heatOff.Codes:X8}");
    Check("  with FEAT_STOCK_O2: the narrowband loop moves the O2 correction; without it, 100 % throughout", all.O2Max > 0x100 && none.O2Max == 0, $"{all.O2Max:0} / {none.O2Max:0} from 8000h");
    }
    if (parts.Contains("knock"))
    {
    // knock (the simulator's knock lines report it): retard with the knock unit, none without; no code either way
    (int Retard, double Adv, int Codes) Knocking(string[] defs, double knock)
    {
        int ret = 0, n = 0;
        var r = Run(defs, [], [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; }), Hold(4, e => { e.Rpm = 3500; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = 80; e.KnockIntensity = knock; })],
            sim => { if (++n > 400) ret = Math.Max(ret, Math.Abs((sbyte)sim.Bus.Ram[0x2B4])); });
        var m = r.Sim.Bus.Ram;
        return (ret, r.Advance[^1], m[0x330] | m[0x331] << 8 | m[0x332] << 16 | m[0x333] << 24);
    }
    var kQuiet = Knocking(["FEAT_STOCK_KNOCK", "FEAT_STOCK_DTC"], 0); var kOn = Knocking(["FEAT_STOCK_KNOCK", "FEAT_STOCK_DTC"], 1); var kOff = Knocking(["FEAT_STOCK_DTC"], 1);
    Check("  with FEAT_STOCK_KNOCK: knock takes timing out (none without knock); no trouble code", kQuiet.Retard == 0 && kOn.Retard > 0 && kOn.Adv < kQuiet.Adv && kOn.Codes == 0 && kQuiet.Codes == 0,
          $"retard {kQuiet.Retard} -> {kOn.Retard}, advance {kQuiet.Adv:0} -> {kOn.Adv:0}, codes {kOn.Codes:X8}");
    Check("  without it: no knock retard whatever the knock lines say, no code", kOff.Retard == 0 && kOff.Codes == 0, $"retard {kOff.Retard}, codes {kOff.Codes:X8}");
    }
    // the high-cam VE curve: VTEC engaged (VTEC control's own points), the curve raised to C0h - the fuel moves only with it
    double HiCamPulse(string[] defs, bool doubled)
    {
        double sum = 0; int n = 0;
        var cal = new Dictionary<string, byte[]> { ["vtecctl_custom"] = [1] };
        if (doubled) cal["tbl_fuel_row_mult_hi40"] = Enumerable.Repeat((byte)0xC0, 40).ToArray();
        var r = Run(["FEAT_VTECCTL", .. defs], cal, [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; }), Hold(4, e => { e.Rpm = 6000; e.MapKpa = 95; e.TpsPct = 100; e.SpeedKmh = 120; })],
            sim => { if (++n > 400) sum += sim.Bus.Ram[0x382] | sim.Bus.Ram[0x383] << 8; });
        return (Platform.PortC(r.Sim) & 1) != 0 ? sum / Math.Max(1, n - 400) : -1;
    }
    if (parts.Contains("hicam"))
    {
    double hiOn = HiCamPulse(["FEAT_STOCK_HICAMVE"], false), hiOnX = HiCamPulse(["FEAT_STOCK_HICAMVE"], true), hiOff = HiCamPulse([], false), hiOffX = HiCamPulse([], true);
    Check("  with FEAT_STOCK_HICAMVE: VTEC engaged, the high-cam VE curve sets the fuel; without it, the low-cam one does (the high curve changes nothing)",
          hiOn > 0 && hiOnX > hiOn * 1.1 && hiOff > 0 && Math.Abs(hiOffX / hiOff - 1) < 0.02, $"{hiOn:0} -> {hiOnX:0} with it; {hiOff:0} -> {hiOffX:0} without");
    }
    if (parts.Contains("outputs"))
    {
        // the automatic, purge and A/C: a cold start, then A/C asked for at idle
        (bool AtFlag, bool AtOut, bool Purge, bool Clutch, int Codes, long Inj) Outs(string[] defs)
        {
            bool atOut = false, purge = false, clutch = false; int n = 0;
            var r = Run(defs, [], [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 20; }),
                                   Hold(3, e => { e.Rpm = 2500; e.MapKpa = 50; e.TpsPct = 15; e.SpeedKmh = 60; e.EctCelsius = 20; }),
                                   Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0; e.EctCelsius = 85; e.AcRequest = true; })],
                sim => { var m = sim.Bus.Ram; if (++n < 20) return; atOut |= (m[0x226] & 0x04) != 0; purge |= (m[0x225] & 0x80) != 0; clutch |= (m[0x225] & 0x01) != 0; });
            var mm = r.Sim.Bus.Ram;
            return ((mm[0x220] & 1) != 0, atOut, purge, clutch, mm[0x330] | mm[0x331] << 8 | mm[0x332] << 16 | mm[0x333] << 24, r.InjPerSec.Count > 0 ? (long)r.InjPerSec[^1] : 0);
        }
        var oOn = Outs(["FEAT_STOCK_AT", "FEAT_STOCK_PURGE", "FEAT_STOCK_AC", "FEAT_STOCK_DTC"]); var oOff = Outs(["FEAT_STOCK_DTC"]);
        Check("  with FEAT_STOCK_AT: the automatic flag and its port C output; without it neither (a manual)", oOn.AtFlag && oOn.AtOut && !oOff.AtFlag && !oOff.AtOut, $"{oOn.AtFlag}/{oOn.AtOut} / {oOff.AtFlag}/{oOff.AtOut}");
        Check("  with FEAT_STOCK_PURGE: the purge cut on from a cold start; without it never", oOn.Purge && !oOff.Purge, $"{oOn.Purge} / {oOff.Purge}");
        Check("  with FEAT_STOCK_AC: A/C asked for, the clutch engaged; without it never", oOn.Clutch && !oOff.Clutch, $"{oOn.Clutch} / {oOff.Clutch}");
        Check("  either way: the engine runs, no trouble code", oOn.Codes == 0 && oOff.Codes == 0 && oOn.Inj > 10 && oOff.Inj > 10, $"codes {oOn.Codes:X8} / {oOff.Codes:X8}, {oOn.Inj} / {oOff.Inj} inj/s");
    }
    if (parts.Contains("vtecpts"))
    {
        // the stock VTEC points, now a table: engaged at full load just over its with-load point (CFh, about 4940 rpm), not
        // just under it; with the point moved to C0h (4000 rpm), engaged at 4500
        bool Vtec(double rpm, Dictionary<string, byte[]> cal) =>
            (Platform.PortC(Run([], cal, [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 60; }),
                                          Hold(3, e => { e.Rpm = rpm; e.MapKpa = 100; e.TpsPct = 100; e.SpeedKmh = 80; })]).Sim) & 1) != 0;
        bool under = Vtec(4700, []), over = Vtec(5200, []), moved = Vtec(4500, new() { ["VTECRpmLoad"] = [0xBC, 0xC0, 0xE3, 0xE5, 0x19, 0x1E], ["injector_effective_pw_skip_tbl"] = [0xFF, 0, 0xDC, 0, 0xD9, 0, 0xD4, 0, 0xCF, 0, 0xCD, 0, 0, 0] });
        Check("  the stock VTEC points (VTECRpmLoad): off at 4700, on at 5200 at full load; the with-load point moved to 4000 rpm and the load curve to 0, on at 4500",
              !under && over && moved, $"{under} / {over} / {moved}");
    }
    if (parts.Contains("selftest"))
    {
        // the self-tests: the main loop's RAM test pointer (27Ch) walks with them, stays put without; no reset reason (63h is the running marker) either way
        (int Moves, int Reason, long Inj) SelfTest(string[] defs)
        {
            int moves = 0, last = -1, reason = 0, n = 0;
            var r = Run(defs, [], [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; }), Hold(3, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; e.SpeedKmh = 60; })],
                sim => { var m = sim.Bus.Ram; if (++n < 20) return; int p = m[0x27C] | m[0x27D] << 8; if (last >= 0 && p != last) moves++; last = p; if (m[0xD4] is not (0 or 0x63)) reason = m[0xD4]; });
            return (moves, reason, r.InjPerSec.Count > 0 ? (long)r.InjPerSec[^1] : 0);
        }
        var stOn = SelfTest(["FEAT_STOCK_SELFTEST"]); var stOff = SelfTest([]);
        Check("  with FEAT_STOCK_SELFTEST: the RAM test walks; without it, it never runs; no reset reason (63h is the running marker), the engine runs either way",
              stOn.Moves > 10 && stOff.Moves == 0 && stOn.Reason == 0 && stOff.Reason == 0 && stOn.Inj > 10 && stOff.Inj > 10,
              $"moves {stOn.Moves} / {stOff.Moves}, reason {stOn.Reason:X2} / {stOff.Reason:X2}, {stOn.Inj} / {stOff.Inj} inj/s");
    }
    if (parts.Contains("dtc"))
    {
        // the trouble codes: the coolant sensor open (code 6) - stored and the lamp on with them; without them neither,
        // and the fault check and its fail-safe coolant value the same
        (bool Stored, bool Lamp, bool Latched, int Ect, long Inj) Codes(string[] defs)
        {
            bool lamp = false, latched = false; int n = 0;
            var r = Run(defs, [], [Hold(4, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = -60; })],
                sim => { latched |= (sim.Bus.Ram[0x98] & 0x02) != 0; if (++n > 300) lamp |= (sim.Bus.Ram[0x226] & 0x08) != 0; });
            var m = r.Sim.Bus.Ram;
            return ((m[0x330] & 0x20) != 0, lamp, latched, m[Platform.A(0xC1)], r.InjPerSec.Count > 0 ? (long)r.InjPerSec[^1] : 0);
        }
        var dOn = Codes(["FEAT_STOCK_DTC"]); var dOff = Codes([]);
        Check("  with FEAT_STOCK_DTC: the coolant sensor open is code 6, stored, the lamp on; without it neither",
              dOn.Stored && dOn.Lamp && !dOff.Stored && !dOff.Lamp, $"stored {dOn.Stored} / {dOff.Stored}, lamp {dOn.Lamp} / {dOff.Lamp}");
        Check("  either way: the fault seen and its fail-safe coolant value used, the engine runs",
              (dOn.Latched || dOn.Stored) && dOff.Latched && dOn.Ect == dOff.Ect && dOn.Inj > 10 && dOff.Inj > 10, $"latched {dOn.Latched} / {dOff.Latched}, coolant byte {dOn.Ect:X2} / {dOff.Ect:X2}, {dOn.Inj} / {dOff.Inj} inj/s");
    }
    if (parts.Contains("vtecpress"))
    {
    // the VTEC pressure switch: VTEC engaged with no oil pressure (the switch never closes)
    (bool Vtec, bool Code22) NoPressure(string[] defs)
    {
        bool latched = false;
        var r = Run(["FEAT_VTECCTL", .. defs], new() { ["vtecctl_custom"] = [1] },
            [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; }), Hold(6, e => { e.Rpm = 6000; e.MapKpa = 95; e.TpsPct = 100; e.SpeedKmh = 120; })],
            sim => { sim.Board.VtecPressureSwitch = false; latched |= (sim.Bus.Ram[0x9A] & 0x02) != 0; });
        return ((Platform.PortC(r.Sim) & 1) != 0, latched || (r.Sim.Bus.Ram[0x332] & 0x20) != 0);
    }
    var vpOn = NoPressure(["FEAT_STOCK_VTECPRESSURE", "FEAT_STOCK_DTC"]); var vpOff = NoPressure(["FEAT_STOCK_DTC"]);
    Check("  with FEAT_STOCK_VTECPRESSURE: no oil pressure under VTEC is code 22; without it no code, VTEC stays on", vpOn.Code22 && !vpOff.Code22 && vpOff.Vtec,
          $"code 22 {vpOn.Code22} / {vpOff.Code22}; VTEC {vpOn.Vtec} / {vpOff.Vtec}");
    }
}

// the base fuel against MAP: the fuel maps set to one value everywhere, full throttle (open loop), MAP swept - does the
// injector time follow MAP on its own (the P13's maps then an enrichment over a speed-density base)?
// what a stock table does (a probe, only asked for by name): PROBE_TABLES=label:fmt[,...] (fmt 0 byte pairs, 1 byte x with
// word y, 2 two byte pairs), each table's y values halved in turn; the fuel pulse (382h), the advance and the idle valve (272h)
// against the stock ROM's at a cold idle, a cold cranking-to-idle, a warm idle and a warm cruise
if (Platform.P13 && only != null && only.Contains("tableprobe"))
{
    string[] probeDefs = Environment.GetEnvironmentVariable("PROBE_DEFS")?.Split(',', StringSplitOptions.RemoveEmptyEntries) ?? [];
    var probe = Build(probeDefs);
    var img = probe.Assembly!.Image;
    var allConds = new (string Name, (double, Action<EngineState, double>)[] Steps)[]
    {
        ("crank20", [Hold(0.6, e => { e.Rpm = 250; e.MapKpa = 95; e.TpsPct = 0; e.EctCelsius = 20; e.IatCelsius = 20; })]),
        ("idle20", [Hold(3, e => { e.Rpm = 900; e.MapKpa = 35; e.TpsPct = 0; e.EctCelsius = 20; e.IatCelsius = 20; })]),
        ("wot3000", [Hold(2, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; }), Hold(3, e => { e.Rpm = 3000; e.MapKpa = 100; e.TpsPct = 100; e.SpeedKmh = 80; e.EctCelsius = 85; e.IatCelsius = 30; })]),
        ("batt11", [Hold(3, e => { e.Rpm = 800; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; e.VbattVolts = 11; e.EldVolts = 1.5; })]),
        ("eld4", [Hold(3, e => { e.Rpm = 800; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; e.VbattVolts = 14.2; e.EldVolts = 4; })]),
        ("idle85long", [Hold(70, e => { e.Rpm = 800; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; e.IatCelsius = 30; })]),
        ("idle85", [Hold(3, e => { e.Rpm = 800; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; e.IatCelsius = 30; })]),
        ("cruise85", [Hold(2, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; }), Hold(3, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; e.SpeedKmh = 80; e.EctCelsius = 85; e.IatCelsius = 30; })]),
        ("iat0", [Hold(2, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; e.IatCelsius = 0; }), Hold(3, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; e.SpeedKmh = 80; e.EctCelsius = 85; e.IatCelsius = 0; })]),
        // a closed throttle at 3000 then 1500 rpm, rolling: the overrun cut (inj/s) and where it lets go
        ("decel3000", [Hold(2, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; }), Hold(1.5, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; e.SpeedKmh = 80; e.EctCelsius = 85; }), Hold(2, e => { e.Rpm = 3000; e.MapKpa = 25; e.TpsPct = 0; e.SpeedKmh = 80; e.EctCelsius = 85; })]),
        ("decel1500", [Hold(2, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; }), Hold(1.5, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; e.SpeedKmh = 80; e.EctCelsius = 85; }), Hold(2, e => { e.Rpm = 1500; e.MapKpa = 25; e.TpsPct = 0; e.SpeedKmh = 40; e.EctCelsius = 85; })]),
        // the throttle snapped open at 2500 rpm: the tip-in fuel (the pulse in the first half second)
        ("tipin", [Hold(2, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; }), Hold(1.5, e => { e.Rpm = 2500; e.MapKpa = 45; e.TpsPct = 10; e.SpeedKmh = 50; e.EctCelsius = 85; }), Hold(0.5, e => { e.Rpm = 2500; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = 50; e.EctCelsius = 85; })]),
        ("knock", [Hold(2, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; }), Hold(3, e => { e.Rpm = 3500; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = 80; e.EctCelsius = 85; e.KnockIntensity = 1; })]),
        ("knock6000", [Hold(2, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; }), Hold(3, e => { e.Rpm = 6000; e.MapKpa = 95; e.TpsPct = 100; e.SpeedKmh = 120; e.EctCelsius = 85; e.KnockIntensity = 1; })]),
        // the throttle opened over a quarter of a second (as a foot does), from 10 % to 80 %
        ("tipramp", [Hold(2, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; }), Hold(1.5, e => { e.Rpm = 2500; e.MapKpa = 45; e.TpsPct = 10; e.SpeedKmh = 50; e.EctCelsius = 85; }),
                     (0.6, (e, f) => { double k = Math.Min(1, f / 0.4); e.Rpm = 2500; e.TpsPct = 10 + 70 * k; e.MapKpa = 45 + 45 * k; e.SpeedKmh = 50; e.EctCelsius = 85; })]),
        ("tipramp20", [Hold(2, e => { e.Rpm = 900; e.MapKpa = 35; e.TpsPct = 0; e.EctCelsius = 20; }), Hold(1.5, e => { e.Rpm = 2500; e.MapKpa = 45; e.TpsPct = 10; e.SpeedKmh = 50; e.EctCelsius = 20; }),
                     (0.6, (e, f) => { double k = Math.Min(1, f / 0.4); e.Rpm = 2500; e.TpsPct = 10 + 70 * k; e.MapKpa = 45 + 45 * k; e.SpeedKmh = 50; e.EctCelsius = 20; })]),
        ("tipin20", [Hold(2, e => { e.Rpm = 900; e.MapKpa = 35; e.TpsPct = 0; e.EctCelsius = 20; }), Hold(1.5, e => { e.Rpm = 2500; e.MapKpa = 45; e.TpsPct = 10; e.SpeedKmh = 50; e.EctCelsius = 20; }), Hold(0.5, e => { e.Rpm = 2500; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = 50; e.EctCelsius = 20; })]),
    };
    var wantConds = Environment.GetEnvironmentVariable("PROBE_CONDS")?.Split(',') ;
    var conds = allConds.Where(c => wantConds == null || wantConds.Contains(c.Name)).ToArray();
    // PROBE_WATCH=hex: a RAM word printed every half second of the measured step
    int watchAt = Environment.GetEnvironmentVariable("PROBE_WATCH") is { } pwx ? Convert.ToInt32(pwx, 16) : -1;
    int[] watchBytes = [.. (Environment.GetEnvironmentVariable("PROBE_WATCHB") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries).Select(x => Convert.ToInt32(x, 16))];
    int watchEvery = int.Parse(Environment.GetEnvironmentVariable("PROBE_WATCH_EVERY") ?? "50");
    // measured over the last step only
    // PROBE_PEAK=hex: the highest a RAM word gets over the measured step, reported as "pk"
    int peakAt = Environment.GetEnvironmentVariable("PROBE_PEAK") is { } ppx ? Convert.ToInt32(ppx, 16) : -1;
    (double Pw, double Adv, double Iacv, double Inj, double Peak) Measure(Dictionary<string, byte[]> cal, (double, Action<EngineState, double>)[] steps)
    {
        double pw = 0, adv = 0, iacv = 0, peak = 0; int n = 0;
        double lastFrom = steps.Take(steps.Length - 1).Sum(x => x.Item1), t = 0;
        var r = Run(probeDefs, cal, steps, sim =>
        {
            t += 0.01;
            if (t < lastFrom + (watchAt >= 0 ? -0.05 : 0.1)) return;
            var m = sim.Bus.Ram;
            pw += m[0x382] | m[0x383] << 8; adv += m[Platform.Adv]; iacv += m[0x272] | m[0x273] << 8; n++;
            if (peakAt >= 0) peak = Math.Max(peak, m[peakAt] | m[peakAt + 1] << 8);
            if (watchAt >= 0 && (n - 1) % watchEvery == 0) Console.Write($" [{t:0.00}s {watchAt:X3}h={m[watchAt] | m[watchAt + 1] << 8:X4} E9={m[0xE9]:X2} AB={m[0xAB]:X2}{string.Concat(watchBytes.Select(wb => $" {wb:X}={m[wb]:X2}"))}]");
        });
        return (pw / Math.Max(1, n), adv / Math.Max(1, n), iacv / Math.Max(1, n), r.InjPerSec.Count > 0 ? r.InjPerSec[^1] : 0, peak);
    }
    var baseline = conds.Select(c => Measure([], c.Steps)).ToArray();
    Console.WriteLine("  stock: " + string.Join("  ", conds.Select((c, i) => $"{c.Name}: pw {baseline[i].Pw:0} adv {baseline[i].Adv:0.0} iacv {baseline[i].Iacv:0} inj {baseline[i].Inj:0} pk {baseline[i].Peak:0}")));
    // label:fmt[:mode] - mode h halves the y values (default), d doubles, z zeroes, f sets FFh, x halves the x values
    foreach (var spec in (Environment.GetEnvironmentVariable("PROBE_TABLES") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries))
    {
        var parts2 = spec.Split(':');
        int at = (int)probe.Assembly.Symbols[parts2[0]].Value, fmt = int.Parse(parts2[1]);
        char mode = parts2.Length > 2 ? parts2[2][0] : 'h';
        int step = fmt == 1 ? 3 : 2, len = 0;
        if (fmt == 2) len = 4;
        else if (fmt == 3) { len = 6 * (parts2.Length > 3 ? int.Parse(parts2[3]) : 1); step = 3; }
        else if (fmt == 9) { len = int.Parse(parts2[3]); step = 1; }
        else for (int i = at; ; i += step) { len += step; if (img[i] == 0 || len > 90) break; }
        var bytes = img[at..(at + len)];
        var changed = (byte[])bytes.Clone();
        int? setTo = parts2.Length > 2 && parts2[2].StartsWith("=") ? Convert.ToInt32(parts2[2][1..], 16) : null;
        int Y(int v) => setTo ?? mode switch { 'd' => Math.Min(v * 2, fmt == 1 ? 0xFFFF : 0xFF), 'z' => 0, 'f' => fmt == 1 ? 0xFFFF : 0xFF, _ => v / 2 };
        for (int i = 0; i < len; i += step)
            if (fmt == 9) changed[i] = (byte)Y(changed[i]);
            else if (mode == 'x') { if (changed[i] is not (0 or 0xFF)) changed[i] = (byte)(changed[i] / 2); }
            else if (fmt is 1 or 3) { int y = Y(changed[i + 1] | changed[i + 2] << 8); changed[i + 1] = (byte)y; changed[i + 2] = (byte)(y >> 8); }
            else changed[i + 1] = (byte)Y(changed[i + 1]);
        var cal = new Dictionary<string, byte[]> { [parts2[0]] = changed };
        var res = conds.Select(c => Measure(cal, c.Steps)).ToArray();
        string Rel(double a, double b) => Math.Abs(a - b) < 1e-9 ? "=" : b == 0 ? $"{a:0.###}" : $"{a / b:0.00}x";
        Console.WriteLine($"  {parts2[0]}:{mode} ({len}: {Convert.ToHexString(bytes)}): " +
            string.Join("  ", conds.Select((c, i) => $"{c.Name}: pw {Rel(res[i].Pw, baseline[i].Pw)} adv {res[i].Adv - baseline[i].Adv:+0.0;-0.0;0} iacv {Rel(res[i].Iacv, baseline[i].Iacv)} inj {Rel(res[i].Inj, baseline[i].Inj)} pk {Rel(res[i].Peak, baseline[i].Peak)}")));
    }
}

// the trigger log at 850 rpm, instruction by instruction (a probe, only asked for by name): captures started by poking the
// module's RAM, every TDC edge the simulator makes and every change of the TDC latch and of SKEL_TRG logged, and a capture
// that comes out with fewer than 4 TDC pulses printed with its log
if (Platform.P13 && only != null && only.Split(",").Contains("trgprobe"))
{
    var r = Run(["FEAT_TRIGLOG"], [], [Hold(2, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = 85; })]);
    var sim = r.Sim; var sy = r.Asm.Symbols;
    int TrgSym(string n) => (int)sy.Values.First(x => x.Name.Equals(n, StringComparison.OrdinalIgnoreCase)).Value;
    int trgN = TrgSym("TRG_N"), trgShift = TrgSym("TRG_SHIFT"), trgBuf = TrgSym("TRG_BUF"), hook = TrgSym("skel_ckp_hook");
    var names = sy.Values.Where(x => x.Kind == SymbolKind.Label).GroupBy(x => (int)x.Value).ToDictionary(g => g.Key, g => g.First().Name);
    string Where(int pc) { for (int a = pc; a > pc - 64; a--) if (names.TryGetValue(a, out var n)) return $"{n}+{pc - a}"; return $"{pc:X4}"; }
    int bad = 0;
    for (int cap = 0; cap < 40 && bad < 2; cap++)
    {
        sim.Bus.Ram[trgN] = 0; sim.Bus.Ram[trgShift] = 6; sim.Bus.Ram[0xFD] |= 0x40;
        var log = new List<string>();
        byte lastTr = sim.Bus.Ram[0x29], lastTrg = sim.Bus.Ram[0xFA];
        int teeth = 0;
        for (long i = 0; i < 4_000_000 && sim.Bus.Ram[trgN] < 25; i++)
        {
            int pc = sim.Cpu.Pc;
            if (pc == hook) { teeth++; log.Add($"T{teeth} tr{sim.Bus.Ram[0x29] >> 7} trg{sim.Bus.Ram[0xFA]:X2}"); }
            if (sim.StepOne() == null) break;
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
            byte tr = sim.Bus.Ram[0x29], trg = sim.Bus.Ram[0xFA];
            if ((tr & 0x80) != (lastTr & 0x80)) log.Add((tr & 0x80) != 0 ? "  TDC+" : $"  tdc- @{Where(pc)}");
            if (trg != lastTrg) log.Add($"  trg {lastTrg:X2}->{trg:X2} @{Where(pc)}");
            lastTr = tr; lastTrg = trg;
        }
        int tdcs = Enumerable.Range(0, 24).Count(k => (sim.Bus.Ram[trgBuf + k] & 0x80) != 0);
        if (tdcs != 4)
        {
            bad++;
            Console.WriteLine($"capture {cap}: {tdcs} TDC [{string.Join(" ", Enumerable.Range(0, 24).Select(k => $"{sim.Bus.Ram[trgBuf + k] & 0x3F}{((sim.Bus.Ram[trgBuf + k] & 0x80) != 0 ? "T" : "")}"))}]");
            Console.WriteLine(string.Join("\n", log));
        }
        // a pause between captures
        for (long i = 0; i < 200_000; i++) { if (sim.StepOne() == null) break; if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
    }
    Console.WriteLine($"trgprobe: {bad} bad captures");
}

if (Platform.P13 && only != null && only.Contains("trgprobe2"))
    TrgProbe.Run(Run(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_TRIGLOG"], [], [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0; e.EctCelsius = 85; }), Hold(1, e => { e.Rpm = 850; e.MapKpa = 50; e.TpsPct = 15; })]), 850);

// the axes of the maps as the app shows them (a probe, only asked for by name)
if (only != null && only.Contains("axisprobe"))
{
    var b = Build(Environment.GetEnvironmentVariable("PROBE_DEFS")?.Split(',', StringSplitOptions.RemoveEmptyEntries) ?? []);
    var defs = OkiRomSim.Calibration.DefinitionBuilder.FromAssembly(b.Assembly!);
    foreach (var name in (Environment.GetEnvironmentVariable("PROBE_ITEMS") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries))
        if (defs.Items.FirstOrDefault(i => i.Name == name) is { } pi) Console.Write($"[{defs.Items.Count(i => i.Name == name)} x, desc {pi.Description.Length}] " + OkiRomSim.Calibration.RomData.Render(defs, b.Assembly!.Image, pi));
        else Console.WriteLine($"  {name}: not defined");
    // PROBE_AUDIT=1: every item - an axis that names something that does not resolve, cells that overlap another item's
    // cells (a wrong count or layout), values that come out as NaN
    if (Environment.GetEnvironmentVariable("PROBE_AUDIT") == "1")
    {
        var img = b.Assembly!.Image;
        var cells = new Dictionary<int, string>();
        int problems = 0;
        foreach (var it in defs.Items)
        {
            foreach (var ax in new[] { it.RowAxis, it.ColAxis })
                if (ax != null && ax.Name != null && ax.Address == null && ax.Values == null) { Console.WriteLine($"  axis unresolved: {it.Name} ({ax.Name})"); problems++; }
            for (int c = 0; c < it.Count; c++)
                for (int k = 0; k < it.ElementSize; k++)
                {
                    int at = it.CellAddress(c) + k;
                    if (it.Flag || it.Type == OkiRomSim.Calibration.CellType.Bit) continue;
                    if (cells.TryGetValue(at, out var other) && other != it.Name) { Console.WriteLine($"  overlap: {it.Name} and {other} at {at:X4}"); problems++; goto nextItem; }
                    cells[at] = it.Name;
                }
            try
            {
                var vals = OkiRomSim.Calibration.RomData.Read(defs, img, it);
                if (vals.Any(v => double.IsNaN(v.Value) || double.IsInfinity(v.Value))) { Console.WriteLine($"  NaN values: {it.Name}"); problems++; }
            }
            catch (Exception ex) { Console.WriteLine($"  cannot read {it.Name}: {ex.Message}"); problems++; }
            nextItem:;
        }
        Console.WriteLine($"  audit: {defs.Items.Count} items, {problems} problems");
    }
    // PROBE_COVER=file: labels (one a line, first word) whose address no item covers
    if (Environment.GetEnvironmentVariable("PROBE_COVER") is { } coverFile)
    {
        var spans = new List<(int Address, int End)>();
        foreach (var i in defs.Items)
        {
            int lo = i.Address, hi = i.CellAddress(Math.Max(0, i.Count - 1)) + i.ElementSize;
            foreach (var ax in new[] { i.RowAxis, i.ColAxis })
                if (ax?.Address is int aa) { int n = ax.Count > 0 ? ax.Count : (ax == i.RowAxis ? i.Rows : i.Cols); int st = ax.Stride > 0 ? ax.Stride : (ax.Type is OkiRomSim.Calibration.CellType.U16 or OkiRomSim.Calibration.CellType.S16 ? 2 : 1); lo = Math.Min(lo, aa); hi = Math.Max(hi, aa + n * st); }
            spans.Add((lo, hi));
        }
        foreach (var lab in File.ReadAllLines(coverFile).Skip(1).Select(l => l.Trim().Split(' ')[0]).Where(l => l.Length > 0))
            if (b.Assembly.Symbols.Values.FirstOrDefault(x => x.Name.Equals(lab, StringComparison.OrdinalIgnoreCase)) is { } sym
                && !spans.Any(sp => sym.Value >= sp.Address && sym.Value < sp.End))
                Console.WriteLine($"  not covered: {lab} @{sym.Value:X4}");
    }
    foreach (var it in defs.Items.Where(i => i.Name is "FuelLow" or "FuelHigh" or "IgnitionLow" or "IgnitionHigh"))
    {
        Console.WriteLine($"  {it.Name} {it.Rows}x{it.Cols}: rows {it.RowAxis?.Name}/{it.RowAxis?.Formula}, cols {it.ColAxis?.Name}/{it.ColAxis?.Formula}");
        Console.WriteLine("    rows: " + string.Join(" ", OkiRomSim.Calibration.RomData.AxisValues(defs, b.Assembly!.Image, it.RowAxis, it.Rows).Select(v => v.ToString("0"))));
        Console.WriteLine("    cols: " + string.Join(" ", OkiRomSim.Calibration.RomData.AxisValues(defs, b.Assembly!.Image, it.ColAxis, it.Cols).Select(v => v.ToString("0"))));
    }
}

// the P13's stock rev limit (a probe, only asked for by name): its cut and resume periods (16Ah/16Ch) over a drive
if (Platform.P13 && only != null && only.Contains("p13revprobe"))
{
    int n = 0;
    double t = 0;
    var ect = double.Parse(Environment.GetEnvironmentVariable("PROBE_ECT") ?? "85");
    Run(Environment.GetEnvironmentVariable("PROBE_DEFS")?.Split(',', StringSplitOptions.RemoveEmptyEntries) ?? [], [],
        [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.EctCelsius = ect; }), Hold(6, e => { e.Rpm = 5000; e.MapKpa = 95; e.TpsPct = 100; e.SpeedKmh = 100; e.EctCelsius = ect; }),
         Hold(3, e => { e.Rpm = 8000; e.MapKpa = 95; e.TpsPct = 100; e.SpeedKmh = 140; e.EctCelsius = ect; })],
        sim =>
        {
            t += 0.01;
            if (++n % 50 != 0) return;
            var m = sim.Bus.Ram;
            int W(int a) => m[a] | m[a + 1] << 8;
            Console.WriteLine($"  {t,5:0.0}s cut {W(0x16A):X4} ({1875000.0 / Math.Max(1, W(0x16A)):0} rpm) resume {W(0x16C):X4} ({1875000.0 / Math.Max(1, W(0x16C)):0}) 0AC {W(0xAC):X4} 21D {m[0x21D]:X2} 212 {m[0x212]:X2} 2D0 {m[0x2D0]:X2} 11C {m[0x11C]:X2} rpm {1875000.0 / Math.Max(1, W(0xAE)):0}");
        });
}

if (Wanted("basefuel"))
{
    Console.WriteLine("the base fuel against MAP (fuel maps flat)");
    var probe = Build();
    var flat = new Dictionary<string, byte[]>();
    foreach (var n in new[] { "FuelLow", "FuelHigh" })
        if (probe.Assembly!.Symbols.ContainsKey(n)) flat[n] = Enumerable.Repeat((byte)(Platform.P13 ? 0x90 : 0x60), Platform.P13 ? 200 : 210).ToArray();
    if (Platform.P13 && Environment.GetEnvironmentVariable("MAPFAULT") is { } mf) flat["MapFaultHigh"] = [Convert.ToByte(mf, 16)];
    var pulses = new List<(double Map, double Pw)>();
    foreach (var map in new[] { 40.0, 60, 80, 100, 130, 160 })
    {
        double s = 0; int n = 0;
        int lo = Platform.P13 ? 0x382 : 0x3AE;
        Run([], flat, [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; }), Hold(3, e => { e.Rpm = 3000; e.MapKpa = map; e.TpsPct = 100; e.SpeedKmh = 80; })],
            sim => { if (++n > 500) s += sim.Bus.Ram[lo] | sim.Bus.Ram[lo + 1] << 8; });
        pulses.Add((map, s / Math.Max(1, n - 500)));
    }
    Console.WriteLine("  " + string.Join(", ", pulses.Select(p => $"{p.Map} kPa: {p.Pw:0}")));
    double ratio = pulses[^1].Pw / pulses[1].Pw;
    Console.WriteLine($"  100 kPa / 60 kPa = {ratio:0.00} (MAP ratio {100 / 60.0:0.00}): the base {(ratio > 1.35 ? "follows MAP" : "does not follow MAP")}");
    if (Platform.P13)
    {
        double r100 = pulses.First(p => p.Map == 100).Pw / pulses.First(p => p.Map == 60).Pw;
        Check("P13: the base fuel follows MAP (speed density: its fuel maps are an enrichment over it)", Math.Abs(r100 - 100 / 60.0) < 0.1, $"{r100:0.00}");
        // a 3-bar sensor (11..3155 mBar, read at the pin as one would), the ROM set up for it as the sensor swap does (the load
        // byte's scale, the base fuel with it, the fault limit out of the way): the same fuel as on the stock sensor at part
        // and full load, and on up with the boost
        (double Zero, double Full) big = (11, 3155);
        var ls = MapSensorScale.P13LoadScale(big);
        byte[] W2(int v) => [(byte)v, (byte)(v >> 8)];
        var cal3 = new Dictionary<string, byte[]>(flat)
        {
            ["MapFaultHigh"] = [0xFE], ["MapSensorFuel"] = W2((int)Math.Round(32768 * ls.Fuel)), ["MapLoadGain"] = W2(ls.Gain),
            ["MapLoadOffset"] = W2(ls.Offset), ["BaroLoadGain"] = W2(ls.BaroGain), ["BaroLoadOffset"] = W2(ls.BaroOffset),
        };
        double Pw3(double kpa)
        {
            double s3 = 0; int n3 = 0; double volts = (kpa * 10 - big.Zero) / (big.Full - big.Zero) * 5;
            Run([], cal3, [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.AnalogOverrides[Bus.P28AdcMap] = (330 - big.Zero) / (big.Full - big.Zero) * 5; }),
                           Hold(3, e => { e.Rpm = 3000; e.MapKpa = kpa; e.TpsPct = 100; e.SpeedKmh = 80; e.AnalogOverrides[Bus.P28AdcMap] = volts; })],
                sim => { if (++n3 > 500) s3 += sim.Bus.Ram[0x382] | sim.Bus.Ram[0x383] << 8; });
            return s3 / Math.Max(1, n3 - 500);
        }
        double a60 = Pw3(60), a100 = Pw3(100), a150 = Pw3(150), a200 = Pw3(200);
        double s60 = pulses.First(p => p.Map == 60).Pw, s100 = pulses.First(p => p.Map == 100).Pw;
        Check($"P13 on a 3-bar sensor (load gain {ls.Gain}, offset {ls.Offset}, base fuel x {ls.Fuel:0.000}): 60 and 100 kPa fuel as on the stock sensor, and the fuel climbs with the boost",
              Math.Abs(a60 / s60 - 1) < 0.05 && Math.Abs(a100 / s100 - 1) < 0.05 && a150 / a100 > 1.4 && a200 / a100 > 1.85,
              $"60 kPa {a60:0} / {s60:0}, 100 kPa {a100:0} / {s100:0}; 150 kPa {a150:0}, 200 kPa {a200:0}");
    }
}

if (Wanted("wizard"))
{
    Console.WriteLine("set-up wizard: a B18C's maps, 440 cc injectors, a 3 bar sensor, 10 psi, on the skeleton (Default) and on HTS120");
    var lib = PresetLibrary.Load(Path.Combine(root, "Templates", "Presets"));
    var hts = Path.Combine(root, "Templates", "HTS120.asm");
    Check("the presets load: stock ECUs, injector lag curves, gearboxes", lib.BaseMaps.Count >= 20 && lib.Injectors.Count >= 100 && lib.Gearboxes.Count == 14,
          $"{lib.BaseMaps.Count} ECUs, {lib.Injectors.Count} injectors, {lib.Gearboxes.Count} gearboxes");
    var b18 = lib.BaseMaps.First(b => b.Engine.StartsWith("B18C4"));
    SetupChoices Choices() => new()
    {
        BaseMap = b18, Vtec = true, VtecRpm = 5200, RevLimit = 8200, StockCc = 240, FittedCc = 440, OverallTrim = 2,
        Lag = lib.Injectors.First(i => i.Name.Contains("440") || i.Name.Contains("450")), OldSensor = (-70, 1790), NewSensor = (11, 3155),
        Gearbox = 6, BoostPsi = 10, BoostCutPsi = 13,
    };
    foreach (var (label, asm) in new[] { ("skeleton (Default)", Build([.. SkeletonPresets.Default, .. (Environment.GetEnvironmentVariable("WIZ_DEFS") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries)]).Assembly!), ("HTS120", new OkiAssembler().AssembleFile(hts)) }.Where(x => !Platform.P13 || x.Item1 != "HTS120"))   // (HTS120 is a P30 ROM: not on the P13's part)
    {
        var defs = DefinitionBuilder.FromAssembly(asm, label);
        defs.MergeBuiltinFormulas();
        CalPage.BindAll(defs, asm.Image);
        var plan = SetupPlanner.Make(defs, asm.Image, Choices(), lib, hts);
        if (args.Contains("--wizdebug"))
            foreach (var (n, ch) in new (string, SetupChoices)[] { ("base", new() { BaseMap = b18 }), ("base+sensor", new() { BaseMap = b18, OldSensor = (-70, 1790), NewSensor = (11, 3155) }), ("sensor", new() { OldSensor = (-70, 1790), NewSensor = (11, 3155) }), ("none", new()) })
            {
                var pl = SetupPlanner.Make(defs, asm.Image, ch, lib, hts);
                var d2 = DefinitionBuilder.FromAssembly(asm, "x"); d2.MergeBuiltinFormulas(); CalPage.BindAll(d2, asm.Image); MapSensorScale.ApplyFormulas(d2, pl.Image);
                var fm = d2.Items.First(i => i.IsTable && i.Rows > 5 && MapImport.RoleOf(i) is { Kind: "fuel", Cam: "low" } && i.ColAxis?.Address != null);
                Console.WriteLine($"    {label} {n}: {fm.Name} axis {fm.ColAxis!.Address:X4} {fm.ColAxis.Formula}: " + string.Join(" ", RomData.AxisValues(d2, pl.Image, fm.ColAxis, fm.Cols).Select(v => v.ToString("0"))) + "  raw " + string.Join(" ", pl.Image.Skip(fm.ColAxis.Address!.Value).Take(fm.Cols).Select(b => b.ToString("X2"))) + " stride " + fm.ColAxis.Stride + " type " + fm.ColAxis.Type);
            }
        int changed = plan.Image.Zip(asm.Image).Count(p => p.First != p.Second);
        MapSensorScale.ApplyFormulas(defs, plan.Image);          // (what the app does once the plan is applied)
        double Val(string slot) => CalPage.Bound(defs, slot) is { } it ? RomData.Read(defs, plan.Image, it)[0].Value : double.NaN;
        var fuelMap = defs.Items.First(i => i.IsTable && i.Rows > 5 && MapImport.RoleOf(i) is { Kind: "fuel", Cam: "low" } && i.ColAxis?.Address != null);
        var cols = RomData.AxisValues(defs, plan.Image, fuelMap.ColAxis, fuelMap.Cols);
        var row = RomData.Read(defs, plan.Image, fuelMap).Skip(fuelMap.Cols * 12).Take(fuelMap.Cols).Select(c => c.Value).ToArray();
        Check($"{label}: the plan writes {changed} bytes; nothing it could not do but what it says", changed > 200,
              string.Join("; ", plan.Done.Take(12)) + (plan.NotHere.Count > 0 ? "  NOT: " + string.Join("; ", plan.NotHere) : ""));
        Check($"  VTEC at 5200, rev limit 8200 written", Math.Abs(Val("vtec.rpm.high") - 5200) < 80 && Math.Abs(Val("revlimit.low.set") - 8200) < 60,
              $"vtec {Val("vtec.rpm.high"):0}, limit {Val("revlimit.low.set"):0}");
        // (the P13: its fuel maps are an enrichment over a base fuel that follows the MAP reading - which the sensor swap
        // scaled - so its boost columns keep the full-load enrichment and a little more, not a base map's fuel per bar)
        double atm = row[cols.Count(c => c <= 1053) - 1];
        bool fuelOk = Platform.P13 ? row[^1] >= atm && row[^1] < atm * 1.2 && Val("mapsensor.fuel") > 150 : row[^1] > atm * 1.4;
        Check($"  the load columns reach 10 psi of boost and the fuel climbs with them", cols[^1] > 1650 && fuelOk,
              $"{string.Join(" ", cols.Select(c => c.ToString("0")))} mBar; row 12: {string.Join(" ", row.Select(v => v.ToString("0.##")))}");
        (long Inj, bool Faulted) Idle(byte[] image)
        {
            var sim = new Simulator(); var img = (byte[])image.Clone();
            RomChecksum.Balance(img, asm.ChecksumAddress ?? 0x7FFF);
            sim.LoadRom(img);
            var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 850; e.MapKpa = 33; sim.SyncSensors();
            ulong nextDbg = 0;
            int resetAt = img[0] | img[1] << 8, shownR = 0, lastTw = 0, shownA = 0; byte lastA3 = 0; var ring = new Queue<ushort>();
            for (ulong end = sim.Cpu.Cycles + (ulong)(8 * Bus.CpuHz); sim.Cpu.Cycles < end;)
            {
                ushort pcR = sim.Cpu.Pc;
                int tw = sim.Bus.Ram[0xFE] | sim.Bus.Ram[0xFF] << 8;
                if (sim.Bus.Ram[0xA3] == 0 && lastA3 != 0 && sim.Cpu.Cycles > (ulong)(0.5 * Bus.CpuHz) && shownA++ < 3)
                    Console.WriteLine($"      A3 CLEARED at {sim.Cpu.Cycles / (double)Bus.CpuHz:0.000}s at {pcR:X4} {asm.LabelAt(pcR)} after: {string.Join(" < ", ring.Reverse().Take(40).Select(x => $"{x:X4} {asm.LabelAt(x)}".Trim()))}");
                lastA3 = sim.Bus.Ram[0xA3];
                if (false && tw < lastTw - 5 && shownR++ < 2)
                    Console.WriteLine($"      TICK RESET {lastTw}->{tw} at {sim.Cpu.Cycles / (double)Bus.CpuHz:0.000}s after: {string.Join(" < ", ring.Reverse().Take(40).Select(x => $"{x:X4} {asm.LabelAt(x)}".Trim()))}");
                lastTw = tw;
                if (pcR == resetAt && sim.Cpu.Cycles > 1000 && shownR++ < 2)
                    Console.WriteLine($"      RESET at {sim.Cpu.Cycles / (double)Bus.CpuHz:0.000}s after: {string.Join(" < ", ring.Reverse().Take(25).Select(x => $"{x:X4} {asm.LabelAt(x)}".Trim()))}");
                ring.Enqueue(pcR); if (ring.Count > 40) ring.Dequeue();
                if (sim.StepOne() == null) break;
                if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
                if (false && sim.Cpu.Cycles >= nextDbg && (nextDbg += (ulong)(0.5 * Bus.CpuHz)) > 0)
                    Console.WriteLine($"      dbg {sim.Cpu.Cycles / (double)Bus.CpuHz:0.00}s inj {sim.Bus.InjectorEvents.Sum()} 1F0 {sim.Bus.Ram[0x1F0]:X2} want {sim.Bus.Ram[0x1F2] | sim.Bus.Ram[0x1F3] << 8:X4}/{sim.Bus.Ram[0x1F4] | sim.Bus.Ram[0x1F5] << 8:X4} 11C {sim.Bus.Ram[0x11C]:X2} 0ACh {sim.Bus.Ram[0xAC] | sim.Bus.Ram[0xAD] << 8:X4} A3 {sim.Bus.Ram[0xA3]:X2} cap {sim.Bus.Ram[0x31A + 8]:X2}/{sim.Bus.Ram[0x3F8 + 8]:X2}");
            }
            Console.WriteLine($"      end: state {sim.State}, pc {sim.Cpu.Pc:X4} {asm.LabelAt(sim.Cpu.Pc)}, fault {sim.FaultMessage}, wdt {sim.Bus.WatchdogTripped}, last: {string.Join(" < ", ring.Reverse().Take(20).Select(x => $"{x:X4} {asm.LabelAt(x)}".Trim()))}");
            return (sim.Bus.InjectorEvents.Sum(), sim.State == RunState.Faulted);
        }
        if (label.StartsWith("skeleton"))
        {
            var near = asm.Symbols.Values.Where(x => x.Value >= 0x100 && x.Value < 0x8000).OrderBy(x => x.Value).ToList();
            var runs = new List<string>(); int k = 0;
            while (k < plan.Image.Length)
            {
                if (plan.Image[k] == asm.Image[k]) { k++; continue; }
                int st = k; while (k < plan.Image.Length && plan.Image[k] != asm.Image[k]) k++;
                var sy = near.LastOrDefault(x => x.Value <= st);
                runs.Add($"{st:X4}+{k - st} {sy?.Name}+{(sy == null ? 0 : st - sy.Value):X}");
            }
            Console.WriteLine("      changed: " + string.Join(", ", runs));
            var groups = new Dictionary<string, List<int>>();
            for (int q = 0; q < plan.Image.Length; q++)
                if (plan.Image[q] != asm.Image[q]) { var sy = near.LastOrDefault(x => x.Value <= q); var g = sy?.Name ?? "?"; if (!groups.TryGetValue(g, out var l)) groups[g] = l = []; l.Add(q); }
            foreach (var (g, addrs) in groups)
            {
                var test = (byte[])plan.Image.Clone();
                foreach (var q in addrs) test[q] = asm.Image[q];
                var simT = new Simulator(); RomChecksum.Balance(test, asm.ChecksumAddress ?? 0x7FFF); simT.LoadRom(test);
                var et = simT.Engine; et.EctCelsius = 85; et.IatCelsius = 25; et.Rpm = 850; et.MapKpa = 33; simT.SyncSensors();
                for (ulong end = (ulong)(5 * Bus.CpuHz); simT.Cpu.Cycles < end;) { if (simT.StepOne() == null) break; if ((simT.Cpu.Instructions & 1023) == 0) simT.SyncSensors(); }
                Console.WriteLine($"      without {g}: {simT.Bus.InjectorEvents.Sum()} injections in 5 s");
            }
        }
        var (was, _) = Idle(asm.Image);
        var (now, fault) = Idle(plan.Image);
        Check($"  it starts and idles as the unchanged ROM does", !fault && now > was * 0.8, $"{now} injections in 8 s (unchanged: {was})");
    }
}

// ------------------------------------------------------------------ the virtual dyno's sums
if (Wanted("dyno"))
{
    Console.WriteLine("virtual dyno: runs made up at a known power must give it back");
    // a run at a steady 100 kW at the wheels, in one gear (30 km/h per 1000 rpm), logged at 50 frames a second with a whole-km/h speed sensor
    List<DynoSample> MakeRun(DynoProfile p, double watts, double fromRpm, double toRpm)
    {
        var list = new List<DynoSample>();
        double kPer = 30, v = fromRpm / 1000 * kPer / 3.6, t = 0, dt = 0.02;
        double m = p.Mode == DynoMode.Strip ? (p.VehicleKg + p.DriverKg + p.FuelKg) * (1 + p.RotatingPct / 100)
                                            : p.RollerInertia / Math.Pow(p.RollerDiameterM / 2, 2) + p.WheelsKg;
        double rho = VirtualDyno.AirDensity(p.AirC, p.BaroKpa, p.HumidityPct);
        while (v * 3.6 / kPer * 1000 < toRpm)
        {
            double rpm = v * 3.6 / kPer * 1000;
            list.Add(new DynoSample { T = t, Rpm = Math.Round(rpm), Kmh = Math.Floor(v * 3.6), Tps = 100, MapKpa = 100, Ch = { ["afr"] = 12.5 } });
            double resist = p.Mode == DynoMode.Strip ? 0.5 * rho * p.DragCd * p.FrontalM2 * v * v + p.RollingCrr * (p.VehicleKg + p.DriverKg + p.FuelKg) * 9.80665 : p.ParasiticN;
            double a = (watts / v - resist) / m;
            v += a * dt; t += dt;
        }
        return list;
    }
    foreach (var mode in new[] { DynoMode.Strip, DynoMode.Inertia })
    {
        var p = new DynoProfile { Mode = mode, Correction = DynoCorrection.None, AirFromEcu = false, Smoothing = 5, ParasiticN = mode == DynoMode.Inertia ? 40 : 0 };
        var run = MakeRun(p, 100_000, 3000, 7500);
        var r = VirtualDyno.Compute(run, p);
        var mid = r.Curve.Where(x => x.Rpm is > 3600 and < 7000).ToList();
        double worst = mid.Count == 0 ? 1 : mid.Max(x => Math.Abs(x.WheelW - 100_000)) / 100_000;
        Check($"{mode}: 100 kW at the wheels comes back within 2 % from 3600 to 7000 rpm", mid.Count > 20 && worst < 0.02,
              $"{run.Count} readings over {run[^1].T:0.0} s; worst {worst * 100:0.00} %, peak {r.PeakW / 1000:0.0} kW, {r.KmhPer1000:0.00} km/h per 1000 learned; {r.Note}");
        double tq = r.Curve.First(x => x.Rpm >= 5000).TorqueNm;
        Check($"  torque at 5000 rpm is power / speed (191 Nm)", Math.Abs(tq - 100_000 / (5000 * 2 * Math.PI / 60)) < 4, $"{tq:0.0} Nm");
    }
    double sae = VirtualDyno.CorrectionFactor(DynoCorrection.SaeJ1349, 25, 99 + 0.61078 * Math.Exp(17.27 * 25 / 262.3) * 0, 0);
    Check("SAE J1349 is 1.00 at its own standard day (25 C, 99 kPa dry)", Math.Abs(sae - 1) < 0.005, $"{sae:0.000}");
    // the triggers: throttle over 90 % and above 30 km/h starts it, throttle under 80 % stops it
    var tp = new DynoProfile { Start = [new() { Channel = "tps_pct", Op = ">", Value = 90 }, new() { Channel = "speed_kmh", Op = ">", Value = 30 }], StartAll = true,
                               Stop = [new() { Channel = "tps_pct", Op = "<", Value = 80 }], MinRunS = 1 };
    var trig = new DynoTriggers();
    List<DynoSample>? got = null;
    for (int i = 0; i < 400; i++)
    {
        double t = i * 0.02;
        var s = new DynoSample { T = t, Rpm = 3000 + i * 10, Kmh = 20 + i * 0.1, Tps = t < 1 ? 20 : t < 6 ? 100 : 10 };
        got = trig.Feed(s, tp) ?? got;
    }
    Check("  triggers: starts at throttle over 90 % and over 30 km/h, stops under 80 %", got != null && got[0].Kmh > 30 && got[0].T >= 1 && got[^1].T >= 6 && got[^1].T < 6.1,
          got == null ? "no run" : $"{got[0].T:0.00} s to {got[^1].T:0.00} s, from {got[0].Kmh:0} km/h");
    trig = new DynoTriggers(); got = null;
    var kp = new DynoProfile { Start = [new() { Channel = "key", Op = ">", Value = 0 }], Stop = [] };
    for (int i = 0; i < 300; i++) { trig.KeyDown = i is >= 50 and < 200; got = trig.Feed(new DynoSample { T = i * 0.02, Rpm = 4000 }, kp) ?? got; }
    Check("  the hotkey: held, it runs; let go, it stops", got != null && Math.Abs(got[0].T - 1) < 0.03 && Math.Abs(got[^1].T - 4) < 0.03, got == null ? "no run" : $"{got[0].T:0.00} s to {got[^1].T:0.00} s");
}

// ------------------------------------------------------------------ a run
long Sym(AssemblyResult a, string n) => a.Symbols.Values.First(s => s.Name.Equals(n, StringComparison.OrdinalIgnoreCase)).Value;
RunResult Run(string[] defs, Dictionary<string, byte[]> cal, IEnumerable<(double Secs, Action<EngineState, double> Set)> steps, Action<Simulator>? watch = null)
{
    var b = Build(defs);
    if (!b.Success) throw new Exception(string.Join("\n", b.Errors));
    var rom = (byte[])b.Assembly!.Image.Clone();
    foreach (var (name, bytes) in cal) for (int i = 0; i < bytes.Length; i++) rom[Sym(b.Assembly, name) + i] = bytes[i];
    // TEST_CAL=label=hhxN[,label=hhxN...]: that many bytes of hh at the label, in every run (probing what a table does)
    foreach (var tc in (Environment.GetEnvironmentVariable("TEST_CAL") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries))
    {
        var m = System.Text.RegularExpressions.Regex.Match(tc, @"^(\w+)=([0-9a-fA-F]{2})x(\d+)$");
        if (m.Success) for (int i = 0; i < int.Parse(m.Groups[3].Value); i++) rom[Sym(b.Assembly, m.Groups[1].Value) + i] = Convert.ToByte(m.Groups[2].Value, 16);
    }
    RomChecksum.Balance(rom, b.Assembly.ChecksumAddress ?? 0x7FFF);
    var sim = new Simulator(); sim.LoadRom(rom);
    // TEST_WRITES=hex: every change to that RAM byte, with the code that made it (debugging a check)
    if (Environment.GetEnvironmentVariable("TEST_WRITES") is { } tw)
    {
        var twp = tw.Split('@');   // hex[@secs]: from that time on
        int wa = Convert.ToInt32(twp[0], 16), shown = 0;
        ulong twFrom = twp.Length > 1 ? (ulong)(double.Parse(twp[1], System.Globalization.CultureInfo.InvariantCulture) * Bus.CpuHz) : 0;
        var labs = b.Assembly.Symbols.Values.Where(x => x.Kind == SymbolKind.Label && x.Value < 0x8000).OrderBy(x => x.Value).ToList();
        sim.Bus.OnDataWrite += (x, was, now) =>
        {
            if (x != wa || was == now || sim.Cpu.Cycles < twFrom || shown++ > 60) return;
            int pc = sim.Bus.CurrentPc;
            var l = labs.LastOrDefault(y => y.Value <= pc);
            Console.WriteLine($"    {wa:X3}h {was:X2} -> {now:X2} at {l?.Name}+{pc - (l?.Value ?? 0)}, {(double)sim.Cpu.Cycles / Bus.CpuHz:0.000} s");
        };
    }
    // TEST_BREAK=label: the registers and the P13's self-tested SFRs the first 3 times the code gets there
    if (Environment.GetEnvironmentVariable("TEST_BREAK") is { } tb && b.Assembly.Symbols.TryGetValue(tb, out var tbs))
    {
        int shown = 0;
        var prev = sim.BeforeStep;
        sim.BeforeStep = (pc, dd) =>
        {
            prev?.Invoke(pc, dd);
            if (pc != tbs.Value || shown++ >= 3) return;
            var m = sim.Bus.Ram;
            int bb = sim.Cpu.BankBase();
            Console.WriteLine($"    at {tb}: A={sim.Cpu.A:X4} r0-r3={m[bb]:X2} {m[bb + 1]:X2} {m[bb + 2]:X2} {m[bb + 3]:X2} PC from {sim.Bus.CurrentPc:X4} " +
                $"SFR 0F={m[0x0F]:X2} P4SF={m[0x1C]:X2} P4IO={m[0x20]:X2} P3SF={m[0x22]:X2} P3IO={m[0x23]:X2} P2A={m[0x25]:X2} P2SF={m[0x26]:X2} " +
                $"IGNCON={m[0x61]:X2} ADSCAN={m[0x66]:X2} ADSEL={m[0x67]:X2} STTMR={m[0x78]:X2} SCONA={m[0x7A]:X2} SCONB={m[0x7B]:X2} SRSTAT={m[0x7E]:X2} bank {bb:X3} 11A={m[0x11A]:X2} 21A={m[0x21A]:X2}, {(double)sim.Cpu.Cycles / Bus.CpuHz:0.000} s");
        };
    }
    // TEST_TRACE=label: the 60 instructions from the first time the code gets there, each with its label, A, DP and SSP
    if (Environment.GetEnvironmentVariable("TEST_TRACE") is { } ttRaw && b.Assembly.Symbols.TryGetValue(ttRaw.Split('@')[0], out var tts))
    {
        int left = -1;   // label[@secs]: the first time from then on
        ulong ttFrom = ttRaw.Contains('@') ? (ulong)(double.Parse(ttRaw.Split('@')[1], System.Globalization.CultureInfo.InvariantCulture) * Bus.CpuHz) : 0;
        var labs = b.Assembly.Symbols.Values.Where(x => x.Kind == SymbolKind.Label && x.Value < 0x8000).OrderBy(x => x.Value).ToList();
        var prev = sim.BeforeStep;
        sim.BeforeStep = (pc, dd) =>
        {
            prev?.Invoke(pc, dd);
            if (left < 0 && pc == tts.Value && sim.Cpu.Cycles >= ttFrom) left = 60;
            if (left <= 0) return;
            left--;
            var l = labs.LastOrDefault(y => y.Value <= pc);
            var im = b.Assembly.Image; string by = pc + 4 < im.Length ? $"{im[pc]:X2} {im[pc + 1]:X2} {im[pc + 2]:X2} {im[pc + 3]:X2}" : "";
            Console.WriteLine($"    {pc:X4} [{by}] {l?.Name}+{pc - (l?.Value ?? 0)}  11A={sim.Bus.Ram[0x11A]:X2} 21A={sim.Bus.Ram[0x21A]:X2} A={sim.Cpu.A:X4} DP={sim.Bus.Ram[0x02] | sim.Bus.Ram[0x03] << 8:X4} SSP={sim.Bus.Ram[0x00] | sim.Bus.Ram[0x01] << 8:X4}");
        };
    }
    var e = sim.Engine; e.EctCelsius = 85; e.IatCelsius = 25; e.Rpm = 800; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0;
    var s = new RunResult(sim, b.Assembly);
    var first = steps.First().Set;
    // P13: key on first (engine still, MAP at baro): its boot keeps the MAP it reads then (3A3h), and a running MAP still
    // within 2 counts of it is a hose off to it (code 5) - which a run that powers up already idling would be
    ulong keyOn = Platform.P13 ? sim.Cpu.Cycles + (ulong)(2.6 * Bus.CpuHz) : 0;
    first(e, 0);
    if (Platform.P13) { e.Rpm = 0; e.MapKpa = 101; e.SpeedKmh = 0; e.TpsPct = 0; }   // (its boot, RAM test and all, ends about 2.3 s in)
    sim.SyncSensors();
    for (ulong end = sim.Cpu.Cycles + (ulong)(5 * Bus.CpuHz); sim.Cpu.Cycles < end;)
    {
        if (keyOn != 0 && sim.Cpu.Cycles >= keyOn) { keyOn = 0; e.Rpm = 800; e.MapKpa = 33; first(e, 0); sim.SyncSensors(); }
        Probe.Warmup?.Invoke(sim);
        if (sim.StepOne() == null) break;
        if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
    }
    foreach (var (secs, set) in steps)
    {
        // rates over the last two thirds of a step: a module acts within a few ticks and the ECU filters some
        // readings, so the first moments of a step are not what it settles to
        long inj0 = 0, ign0 = 0;
        double adv = 0; int n = 0;
        for (double t = 0; t < secs - 1e-9; t += 0.01)
        {
            if (Math.Abs(t - secs / 3) < 0.005 || (inj0 == 0 && ign0 == 0 && t >= secs / 3)) { inj0 = sim.Bus.InjectorEvents.Sum(); ign0 = sim.Bus.IgnitionEvents; }
            set(e, t / secs);
            ulong end = sim.Cpu.Cycles + (ulong)(0.01 * Bus.CpuHz);
            while (sim.Cpu.Cycles < end) { if (sim.StepOne() == null) { s.Halted = true; break; } if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors(); }
            watch?.Invoke(sim);
            adv += sim.Bus.Ram[Platform.Adv]; n++;
        }
        s.InjPerSec.Add((sim.Bus.InjectorEvents.Sum() - inj0) / (secs * 2 / 3));
        s.IgnPerSec.Add((sim.Bus.IgnitionEvents - ign0) / (secs * 2 / 3));
        s.Advance.Add(n == 0 ? 0 : adv / n);
    }
    return s;
}
static (double, Action<EngineState, double>) Hold(double secs, Action<EngineState> set) => (secs, (e, _) => set(e));
var idle = Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0; });
var cruise = Hold(3, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; e.SpeedKmh = 90; });
var wot = Hold(3, e => { e.Rpm = 6000; e.MapKpa = 100; e.TpsPct = 100; e.SpeedKmh = 120; });
(double, Action<EngineState, double>)[] Drive = [idle, cruise, wot];

// ------------------------------------------------------------------ no harm with the defaults
if (Wanted("noharm"))
{
    Console.WriteLine("every module left at its default calibration changes nothing about how the engine runs");
    var baseRun = Run([], [], Drive);
    Check("bare skeleton runs (idle, cruise, WOT)", baseRun.InjPerSec.All(x => x > 10) && !baseRun.Halted,
        string.Join(", ", baseRun.InjPerSec.Select(x => $"{x:0}/s")));
    foreach (var f in modules)
    {
        RunResult r;
        try { r = Run([f.Define, .. f.Requires], [], Drive); }
        catch (Exception ex) { Check(f.Define, false, "does not build: " + ex.Message.Split('\n')[0]); continue; }
        bool same = !r.Halted && r.InjPerSec.Zip(baseRun.InjPerSec).All(p => Math.Abs(p.First - p.Second) <= Math.Max(3, p.Second * 0.05))
                    && r.Advance.Zip(baseRun.Advance).All(p => Math.Abs(p.First - p.Second) <= 2);
        Check(f.Define, same, string.Join(", ", r.InjPerSec.Select(x => $"{x:0}/s")) + "  adv " + string.Join(", ", r.Advance.Select(x => $"{x:0}")));
    }
}

// the crank period (0ACh) and its invalid flag (231h.5) every 10 ms through an ignition cut: does the rpm the ROM keeps (and logs) fall to nothing?
if (args.Contains("--cuttrace"))
{
    var extra = args.SkipWhile(a => a != "--cuttrace").Skip(1).ToArray();
    int P0(double rpm) => (int)Math.Round(1875000 / rpm);
    byte[] W0(int v) => [(byte)v, (byte)(v >> 8)];
    var cal = new Dictionary<string, byte[]> { ["revlimit_low"] = [1], ["revlimit_cut"] = [1], ["revlimit_low_set"] = W0(P0(4000)), ["revlimit_low_reset"] = W0(P0(3900)) };
    if (extra.Contains("FEAT_IGNCUTMOD")) { cal["icm_enable"] = [1]; cal["icm_refire"] = [5]; }
    if (extra.Contains("FUELCUT")) { cal["revlimit_cut"] = [0]; extra = [.. extra.Where(x => x != "FUELCUT")]; }
    var seen = new List<(double T, int Period, bool Bad, int Tick, string Codes)>();
    double t0 = 0;
    var rr = Run(["FEAT_REVLIMIT", .. extra], cal, [Hold(2, e => { e.Rpm = 3500; e.MapKpa = 90; e.TpsPct = 80; }), Hold(3, e => { e.Rpm = 4500; e.MapKpa = 90; e.TpsPct = 80; }), Hold(2, e => { e.Rpm = 3500; e.MapKpa = 90; e.TpsPct = 80; })],
        sim => { t0 += 0.01; var m = sim.Bus.Ram; seen.Add((t0, m[0xAC] | (m[0xAD] << 8), (m[0x231] & 0x20) != 0, m[0xFE] | (m[0xFF] << 8), $"{m[0x31A]:X2}{m[0x31B]:X2}{m[0x31C]:X2}{m[0x31D]:X2} 113:{m[0x113]:X2} 9C:{m[0x9C]:X2}{m[0x9D]:X2} EA:{m[0xEA]:X2}")); });
    Console.WriteLine($"sparks/s {string.Join(" ", rr.IgnPerSec.Select(x => x.ToString("0")))}  inj/s {string.Join(" ", rr.InjPerSec.Select(x => x.ToString("0")))}  halted {rr.Halted}");
    foreach (var s in seen.Where((s, i) => i % 10 == 0 || s.Bad || s.Period == 0xFFFF))
        Console.WriteLine($"  {s.T,5:0.00}s period {s.Period:X4} ({(s.Period is 0 or 0xFFFF ? 0 : 1875000.0 / s.Period),5:0} rpm){(s.Bad ? " INVALID" : "")} tick {s.Tick:X4} codes {s.Codes}");
    return 0;
}
if (args.Contains("--probe")) { Probe.Run(Run); return 0; }
if (args.Contains("--svcprobe")) return SvcProbe.Run(Run, [.. args.SkipWhile(x => x != "--svcprobe").Skip(1)]);
if (args.Contains("--names")) { Names.Run(sk); return 0; }
if (args.Contains("--fuzz")) { SpaceFuzz.Run(sk, Check, int.Parse(args.SkipWhile(a => a != "--fuzz").Skip(1).FirstOrDefault() ?? "20")); Console.WriteLine(failures == 0 ? "ALL PASS" : $"{failures} FAILED"); return failures == 0 ? 0 : 1; }
if (args.Contains("--detect")) { DetectEval.Run(root, Check); Console.WriteLine(failures == 0 ? "ALL PASS" : $"{failures} FAILED"); return failures == 0 ? 0 : 1; }
// ------------------------------------------------------------------ the modules, switched on
Tests.Register(sk, Run, Check, Wanted, Hold);

Console.WriteLine(failures == 0 ? "ALL PASS" : $"{failures} FAILED");
return failures == 0 ? 0 : 1;

static string FindRoot()
{
    // from the program, or (built somewhere else) from where it was started - the one with the skeleton in it
    foreach (var start in new[] { AppContext.BaseDirectory, Environment.CurrentDirectory })
    {
        var d = start;
        while (d != null && !File.Exists(Path.Combine(d, "roms", "p30-skeleton.asm"))) d = Path.GetDirectoryName(d);
        if (d != null) return d;
    }
    throw new Exception("cannot find the repository root (a folder with roms/)");
}

public sealed class RunResult(Simulator sim, AssemblyResult asm)
{
    public Simulator Sim { get; } = sim;
    public AssemblyResult Asm { get; } = asm;
    public bool Halted { get; set; }
    public List<double> InjPerSec { get; } = [];
    public List<double> IgnPerSec { get; } = [];
    /// Mean of the final advance byte (246h) over each step, in its own units.
    public List<double> Advance { get; } = [];
}

public delegate RunResult RunFn(string[] defs, Dictionary<string, byte[]> cal, IEnumerable<(double Secs, Action<EngineState, double> Set)> steps, Action<Simulator>? watch = null);

/// Which skeleton the checks run on, and the RAM they read that moved with it.
public static class Platform
{
    public static bool P13;
    /// The final advance byte.
    public static int Adv => P13 ? 0x2B8 : 0x246;
    /// The crank period word.
    public static int Rpm => P13 ? 0xAE : 0xAC;

    /// A P30 RAM address the checks read, where the P13 keeps the same thing (features.inc's platform block).
    static readonly Dictionary<int, int> Moved = new()
    {
        [0xAC] = 0xAE, [0xAD] = 0xAF, [0xA3] = 0xA5, [0xA7] = 0x288, [0x1D3] = 0xED, [0xB9] = 0xAB, [0xC1] = 0xD9, [0xC0] = 0xD8, [0xC3] = 0xDC,
        [0xB4] = 0xDF, [0x146] = 0x1D0, [0x147] = 0x1D1, [0x1F0] = 0x1C0, [0x1F1] = 0x1C1, [0x1F6] = 0x1C6, [0x2F7] = 0x27E,
        [0x2FE] = 0x27F, [0x2FC] = 0x27A, [0x2FD] = 0x27B, [0xC8] = 0x272, [0xC9] = 0x273, [0x246] = 0x2B8, [0x247] = 0x2B9,
        [0x3AE] = 0x1D0, [0x3AF] = 0x1D1,
        // the stored trouble codes and their two copies
        [0x31A] = 0x330, [0x31B] = 0x331, [0x31C] = 0x332, [0x31D] = 0x333, [0x112] = 0x110, [0x113] = 0x111, [0x212] = 0x210, [0x213] = 0x211,
    };
    public static int A(int p30) => P13 && Moved.TryGetValue(p30, out var a) ? a : p30;

    /// The P30's P0 (20h) or P1 (22h) latch as the checks know it. On the P13 it is made from what went out at the 82C55
    /// (port B written inverted, port C XOR 24h; lib.asm's outputs): P0.0 A/C clutch PB.0, P0.1 purge PB.7, P0.2
    /// alternator PB.3, P0.3 fan PB.2, P0.4 A/T PC.2, P0.7 pump PB.1 (low = on, as on the P30); P1.0 VTEC PC.7, P1.4 the
    /// lamp PC.3 (high = on). The O2 heater and the ECU LED are not on the P13: they read low.
    /// The 8255's port B (the P30's P0 out) and port C (P1) as the P30 checks read them; on the P13, the same layout
    /// made from its own outputs (Latch).
    public static byte PortB(Simulator sim) => P13 ? Latch(sim, 0x20) : sim.Bus.Ppi.PortB;
    public static byte PortC(Simulator sim) => P13 ? Latch(sim, 0x22) : sim.Bus.Ppi.PortC;

    public static byte Latch(Simulator sim, int p30)
    {
        if (!P13) return sim.Bus.Ram[p30];
        int b = ~sim.Bus.Ppi.PortB & 0xFF, c = (sim.Bus.Ppi.PortC ^ 0x24) & 0xFF;
        bool B(int n) => (b >> n & 1) != 0;
        bool C(int n) => (c >> n & 1) != 0;
        if (p30 == 0x20)
        {
            int v = 0xFF;
            void Low(int bit, bool on) { if (on) v &= ~(1 << bit); }
            Low(0, B(0)); Low(1, B(7)); Low(2, B(3)); Low(3, B(2)); Low(4, C(2)); Low(7, B(1));
            return (byte)v;
        }
        // (bit 5, the P30's ECU LED: the P13 has none, so the checks' "LED" is its spare output, PB.6 - Out(6))
        return (byte)((C(7) ? 0x01 : 0) | (C(3) ? 0x10 : 0) | (B(6) ? 0x20 : 0) | 0xC0);
    }

    /// Output 11 on: the P30's pin A17 (P4.3, high = on); the P13's spare, PB.6 (port B is written inverted).
    public static bool A17(Simulator sim) => P13 ? (~sim.Bus.Ppi.PortB & 0x40) != 0 : (sim.Bus.Ram[Bus.SfrP4] & 0x08) != 0;

    /// The A/D channel of analog input 3 (lib.asm's mod_analog): the P30's B6 (P5.4), the P13's TCS pin (P5.5, ADCR5).
    public static int AuxAdc => P13 ? 5 : 4;

    /// A module output number as the checks pick it: the ECU LED (6) is not on the P13, its spare output (11) stands in.
    public static int Out(int p30) => P13 && p30 == 6 ? 11 : p30;
}
