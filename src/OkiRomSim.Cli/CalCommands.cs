using System.Globalization;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Cli;

/// Looking things up in an assembled image and editing settings and tables in it.
public static class CalCommands
{
    public const string Usage = """
  okisim symbols <file.asm|.sym|.okidef.json> [pattern] [--at 1234] [--near 3DDE]
      Label <-> address lookup. --at shows what lives at an address (nearest label, bytes,
      disassembly); a pattern filters by substring.
  okisim defs <rom> [--defs file.okidef.json] [--filter text] [--category name]
      List every defined setting/table with its address and current value.
  okisim get <rom> <name|label|address> [--defs f] [--type u8|s8|u16|s16] [--formula name]
             [--rows R --cols C] [--count N]
      Show a scalar or a table. Type/formula/size may be given inline for a quick look at
      something that has no definition yet.
  okisim set <rom> <name|label|address> <value> [--cell R,C] [--index N] [--all]
             [--add X] [--scale X] [--raw] [--defs f] [--type t] [--formula f] [--out file]
      Edit a setting or table cell and write the image back (a .bak copy is kept).
  okisim xref <rom> <name|label|address> [--defs f] [--max 50]
      Every instruction that references an address: the fastest way to work out what a byte
      means and which formula applies.
  okisim formulas [name]
      List the built-in scaling formulas (and what they were derived from).
  okisim defs-export <file.asm> [-o defs.okidef.json]
      Build a definition file from ";@" annotations and the symbol table.
""";

    sealed class Target
    {
        public required byte[] Rom;
        public required DefinitionSet Defs;
        public AssemblyResult? Asm;
        public string Path = "";
    }

    static string? Opt(List<string> a, string name)
    {
        int i = a.IndexOf(name);
        if (i < 0 || i + 1 >= a.Count) return null;
        var v = a[i + 1]; a.RemoveRange(i, 2); return v;
    }
    static bool Flag(List<string> a, string name) { int i = a.IndexOf(name); if (i < 0) return false; a.RemoveAt(i); return true; }

    static Target Load(string path, string? defsPath)
    {
        var t = new Target { Rom = Array.Empty<byte>(), Defs = new DefinitionSet(), Path = path };
        if (path.EndsWith(".asm", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".inc", StringComparison.OrdinalIgnoreCase))
        {
            var r = new OkiAssembler().AssembleFile(path);
            if (!r.Success)
                throw new InvalidDataException(string.Join(Environment.NewLine, r.Diagnostics.Where(d => d.Severity == Severity.Error).Take(10)));
            t.Asm = r;
        }
        else if (path.EndsWith(".okidef.json", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
        {
            t.Defs = DefinitionSet.Load(path);
            t.Rom = new byte[t.Defs.RomSize];
        }
        else t.Rom = File.ReadAllBytes(path);

        if (t.Asm != null)
        {
            t.Rom = t.Asm.Image;
            t.Defs = DefinitionBuilder.FromAssembly(t.Asm, Path.GetFileNameWithoutExtension(path));
        }
        if (defsPath != null)
        {
            var d = DefinitionSet.Load(defsPath);
            // a def file supplied alongside a .bin wins, but keep symbols from both
            foreach (var (k, v) in t.Defs.Symbols) d.Symbols.TryAdd(k, v);
            t.Defs = d;
        }
        else
        {
            // pick up a .sym / .okidef.json sitting next to the image
            var baseName = Path.ChangeExtension(path, null);
            if (File.Exists(baseName + ".okidef.json")) 
            {
                var d = DefinitionSet.Load(baseName + ".okidef.json");
                foreach (var (k, v) in t.Defs.Symbols) d.Symbols.TryAdd(k, v);
                t.Defs = d;
            }
            else if (File.Exists(baseName + ".sym"))
                foreach (var line in File.ReadAllLines(baseName + ".sym"))
                {
                    var p = line.Split(' ', 2);
                    if (p.Length == 2 && int.TryParse(p[0], NumberStyles.HexNumber, null, out var a)) t.Defs.Symbols.TryAdd(p[1].Trim(), a);
                }
        }
        t.Defs.MergeBuiltinFormulas();
        if (t.Defs.Symbols.Count == 0 && t.Asm == null)
            Console.WriteLine("note: no symbols found (pass --defs, or keep the .sym file next to the .bin)");
        return t;
    }

    static ItemDef AdHoc(Target t, string what, List<string> args)
    {
        if (t.Defs.Find(what) is { } known) return known;
        if (!t.Defs.TryResolve(what, out var addr)) throw new InvalidDataException($"'{what}' is not a known item, label or address");
        var item = new ItemDef { Name = what, Address = addr, Formula = Opt(args, "--formula") };
        if (Opt(args, "--type") is { } ty)
            item.Type = ty.ToLowerInvariant() switch
            {
                "s8" => CellType.S8, "u16" or "word" => CellType.U16, "s16" => CellType.S16,
                "u16be" => CellType.U16BE, "s16be" => CellType.S16BE, _ => CellType.U8,
            };
        if (Opt(args, "--rows") is { } r) item.Rows = int.Parse(r);
        if (Opt(args, "--cols") is { } c) item.Cols = int.Parse(c);
        if (Opt(args, "--count") is { } n) { item.Rows = 1; item.Cols = int.Parse(n); }
        return item;
    }

    public static int Run(string cmd, List<string> args)
    {
        switch (cmd)
        {
            case "formulas":
                {
                    var defs = new DefinitionSet();
                    defs.MergeBuiltinFormulas();
                    var filter = args.FirstOrDefault();
                    foreach (var f in defs.Formulas.Where(f => filter == null || f.Name.Contains(filter, StringComparison.OrdinalIgnoreCase)))
                    {
                        Console.WriteLine($"{f.Name,-20} {f.Unit,-9} value = {f.Expr}{(f.Step > 0 ? $"   (quantised to {f.Step})" : "")}");
                        if (f.Notes != null) Console.WriteLine($"{"",-20} {f.Notes}");
                        if (filter != null)
                        {
                            Console.WriteLine($"{"",-20} raw ->");
                            foreach (var raw in new double[] { 0, 1, 32, 64, 128, 200, 255 })
                                Console.WriteLine($"{"",-22} {raw,5} = {f.Format(raw)}");
                        }
                    }
                    return 0;
                }
            case "symbols":
                {
                    var atOpt = Opt(args, "--at") ?? Opt(args, "--near");
                    if (args.Count < 1) { Console.WriteLine(Usage); return 2; }
                    var t = Load(args[0], Opt(args, "--defs"));
                    if (atOpt != null)
                    {
                        if (!t.Defs.TryResolve(atOpt, out var addr)) { Console.Error.WriteLine($"cannot resolve {atOpt}"); return 1; }
                        Console.WriteLine($"0x{addr:X4}");
                        var near = t.Defs.SymbolsAt(addr, 128).Take(5).ToList();
                        foreach (var (nm, a) in near)
                            Console.WriteLine($"  {nm}{(a == addr ? "" : $" + {addr - a}")}   (0x{a:X4})");
                        if (near.Count == 0) Console.WriteLine("  (no label within 128 bytes)");
                        var item = t.Defs.Items.FirstOrDefault(i => i.Contains(addr));
                        if (item != null) Console.WriteLine($"  inside definition '{item.Name}' (index {(addr - item.Address) / item.ElementSize})");
                        Console.Write("  bytes ");
                        for (int i = 0; i < 16 && addr + i < t.Rom.Length; i++) Console.Write($"{t.Rom[addr + i]:X2} ");
                        Console.WriteLine();
                        int pc = addr;
                        for (int i = 0; i < 4 && pc < t.Rom.Length; i++)
                        {
                            int p = pc;
                            var d = Decoder.Decode(false, k => p + k < t.Rom.Length ? t.Rom[p + k] : (byte)0xFF);
                            if (d == null) break;
                            Console.WriteLine($"  {pc:X4}  {Decoder.Format(d, (ushort)(pc + d.Len))}");
                            pc += d.Len;
                        }
                        return 0;
                    }
                    var pattern = args.Count > 1 ? args[1] : null;
                    var list = t.Defs.Symbols
                        .Where(kv => pattern == null || kv.Key.Contains(pattern, StringComparison.OrdinalIgnoreCase))
                        .OrderBy(kv => kv.Value).ToList();
                    foreach (var kv in list.Take(500)) Console.WriteLine($"{kv.Value:X4}  {kv.Key}");
                    Console.WriteLine($"{list.Count} symbol(s){(list.Count > 500 ? " (showing 500)" : "")}");
                    return 0;
                }
            case "defs":
                {
                    if (args.Count < 1) { Console.WriteLine(Usage); return 2; }
                    var t = Load(args[0], Opt(args, "--defs"));
                    var filter = Opt(args, "--filter");
                    var cat = Opt(args, "--category");
                    var items = t.Defs.Items
                        .Where(i => filter == null || i.Name.Contains(filter, StringComparison.OrdinalIgnoreCase) || i.Description.Contains(filter, StringComparison.OrdinalIgnoreCase))
                        .Where(i => cat == null || string.Equals(i.Category, cat, StringComparison.OrdinalIgnoreCase))
                        .OrderBy(i => i.Category).ThenBy(i => i.Address).ToList();
                    if (items.Count == 0) { Console.WriteLine("no definitions (annotate the source with \";@ name=... formula=...\" or pass --defs)"); return 0; }
                    string lastCat = "";
                    foreach (var i in items)
                    {
                        if (i.Category != lastCat) { Console.WriteLine($"\n[{i.Category}]"); lastCat = i.Category; }
                        var f = t.Defs.Formula(i.Formula);
                        string value = i.IsTable
                            ? $"{i.Rows}x{i.Cols} table, {f.Format(RomData.Read(t.Defs, t.Rom, i).Min(c => c.Raw))} .. {f.Format(RomData.Read(t.Defs, t.Rom, i).Max(c => c.Raw))}"
                            : RomData.Read(t.Defs, t.Rom, i)[0].Display;
                        Console.WriteLine($"  {i.Address:X4}  {i.Name,-28} {value,-28} {i.Description}");
                    }
                    return 0;
                }
            case "get":
                {
                    if (args.Count < 2) { Console.WriteLine(Usage); return 2; }
                    var t = Load(args[0], Opt(args, "--defs"));
                    var item = AdHoc(t, args[1], args);
                    Console.Write(RomData.Render(t.Defs, t.Rom, item));
                    return 0;
                }
            case "set":
                {
                    if (args.Count < 3) { Console.WriteLine(Usage); return 2; }
                    var defsPath = Opt(args, "--defs");
                    var outPath = Opt(args, "--out");
                    var cell = Opt(args, "--cell");
                    var indexOpt = Opt(args, "--index");
                    bool all = Flag(args, "--all"), raw = Flag(args, "--raw");
                    var addOpt = Opt(args, "--add");
                    var scaleOpt = Opt(args, "--scale");
                    var t = Load(args[0], defsPath);
                    if (t.Asm != null && outPath == null)
                    { Console.Error.WriteLine("editing assembles from source: pass --out image.bin, or edit the source"); return 1; }
                    var item = AdHoc(t, args[1], args);
                    double value = double.Parse(args[2], CultureInfo.InvariantCulture);
                    var indices = new List<int>();
                    if (all) indices.AddRange(Enumerable.Range(0, item.Count));
                    else if (cell != null)
                    {
                        var rc = cell.Split(',');
                        int r = int.Parse(rc[0]), c = rc.Length > 1 ? int.Parse(rc[1]) : 0;
                        indices.Add(r * Math.Max(item.Cols, 1) + c);
                    }
                    else indices.Add(indexOpt != null ? int.Parse(indexOpt) : 0);

                    var before = RomData.Read(t.Defs, t.Rom, item);
                    foreach (var idx in indices)
                    {
                        if (idx < 0 || idx >= item.Count) { Console.Error.WriteLine($"index {idx} outside {item.Name}"); return 1; }
                        double target = value;
                        if (addOpt != null) target = before[idx].Value + double.Parse(addOpt, CultureInfo.InvariantCulture);
                        else if (scaleOpt != null) target = before[idx].Value * double.Parse(scaleOpt, CultureInfo.InvariantCulture);
                        if (raw) RomData.WriteRaw(t.Rom, item.CellAddress(idx), item.Type, target, item.Bit);
                        else RomData.Write(t.Defs, t.Rom, item, idx, target);
                    }
                    var after = RomData.Read(t.Defs, t.Rom, item);
                    foreach (var idx in indices.Take(12))
                        Console.WriteLine($"  {item.Name}[{idx}] @ {item.CellAddress(idx):X4}: {before[idx].Display} -> {after[idx].Display}  (raw {(long)before[idx].Raw:X2} -> {(long)after[idx].Raw:X2})");
                    if (indices.Count > 12) Console.WriteLine($"  ... {indices.Count - 12} more cells");
                    var dest = outPath ?? args[0];
                    if (File.Exists(dest) && outPath == null)
                    {
                        File.Copy(dest, dest + ".bak", overwrite: true);
                        Console.WriteLine($"  backup: {dest}.bak");
                    }
                    File.WriteAllBytes(dest, t.Rom);
                    Console.WriteLine($"  wrote {dest}");
                    return 0;
                }
            case "xref":
                {
                    if (args.Count < 2) { Console.WriteLine(Usage); return 2; }
                    int max = int.Parse(Opt(args, "--max") ?? "50");
                    var t = Load(args[0], Opt(args, "--defs"));
                    if (!t.Defs.TryResolve(args[1], out var addr)) { Console.Error.WriteLine($"cannot resolve {args[1]}"); return 1; }
                    var labels = t.Defs.Symbols.GroupBy(kv => kv.Value).ToDictionary(g => g.Key, g => g.First().Key);
                    var hits = Xref.Find(t.Rom, addr,
                        boundaries: t.Asm?.SourceMap.Select(e => e.Address),
                        labelAt: a => labels.GetValueOrDefault(a, ""),
                        sourceAt: a => t.Asm?.Lookup(a) is { } e ? $"{Path.GetFileName(e.File)}:{e.Line}" : null,
                        maxHits: max);
                    Console.WriteLine($"{hits.Count} reference(s) to 0x{addr:X4}{(labels.TryGetValue(addr, out var ln) ? " " + ln : "")}:");
                    foreach (var h in hits)
                        Console.WriteLine($"  {h.Address:X4} {h.Label,-24} {h.Text,-34} {h.Source}");
                    if (t.Asm == null)
                        Console.WriteLine("(swept linearly with no source map: a few hits may be data mistaken for code)");
                    return 0;
                }
            case "defs-export":
                {
                    if (args.Count < 1) { Console.WriteLine(Usage); return 2; }
                    var outPath = Opt(args, "-o") ?? Path.ChangeExtension(args[0], ".okidef.json");
                    var t = Load(args[0], null);
                    t.Defs.Save(outPath);
                    Console.WriteLine($"wrote {outPath}: {t.Defs.Items.Count} item(s), {t.Defs.Symbols.Count} symbol(s)");
                    return 0;
                }
        }
        return 2;
    }
}
