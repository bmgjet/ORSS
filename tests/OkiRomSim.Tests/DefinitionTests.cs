// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Xml.Linq;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Tests;

/// Definitions: what the Calibration page lists for every shipped source and every skeleton build (against a saved snapshot), the
/// annotation fixes (one bad annotation, an at= that names nothing), the TunerPro export of a byte switch, feature-file checks, and the
/// guards that keep NaN and infinity out of the ROM.
static class DefinitionTests
{
    public static void Run()
    {
        Snapshot();
        Annotations();
        XdfSwitches();
        FeatureFiles();
        NumberGuards();
        T.P30Part();
    }

    /// One line per definition, as the tool that compared these before and after the changes wrote them (invariant culture, so the
    /// snapshot reads the same on any PC).
    static void Snap(List<string> lines, string tag, AssemblyResult asm, string name)
    {
        var defs = DefinitionBuilder.FromAssembly(asm, name);
        foreach (var i in defs.Items.OrderBy(i => i.Address).ThenBy(i => i.Name, StringComparer.Ordinal))
            lines.Add(string.Create(CultureInfo.InvariantCulture,
                $"{tag}|{i.Name}|{i.Address:X4}|{i.Rows}x{i.Cols}|{i.Type}|{i.Formula}|{i.Min}|{i.Max}|{i.RowAxis?.Address:X4}|{i.ColAxis?.Address:X4}|{i.Slot}"));
        lines.Add($"{tag}|== {defs.Items.Count} items, {defs.Symbols.Count} symbols");
    }

    static void Snapshot()
    {
        var lines = new List<string>();
        foreach (var src in new[] { "p30", "p13", "HTS115", "HTS120", "p72-269", "p08-911-243" })
        {
            var asm = T.Assemble(T.Roms(src + ".asm"));
            Snap(lines, src, asm, src + ".asm");
        }
        foreach (var skn in new[] { "p30", "p13" })
        {
            var sk = Skeleton.Load(T.Roms(skn + "-skeleton.asm"), anyPlatform: true);
            (ProcessorProfile.Declared(File.ReadAllText(sk.Path)) ?? ProcessorProfile.Msm66207()).Apply();
            var builds = new List<(string, string[])> { ("bare", []) };
            foreach (var f in sk.Features) builds.Add((f.Define, [f.Define, .. f.Requires]));
            builds.Add(("Default", [.. SkeletonPresets.Default]));
            foreach (var (n, defs) in builds)
            {
                if (sk.Problems(defs).Count > 0) { lines.Add($"{skn}/{n}|problems"); continue; }
                var b = sk.Build(defs);
                if (!b.Success || b.Assembly == null) { lines.Add($"{skn}/{n}|FAIL {string.Join(";", b.Errors.Take(1))}"); continue; }
                Snap(lines, $"{skn}/{n}", b.Assembly, Path.GetFileName(sk.Path));
            }
        }
        // per source or build: how many definitions, and a hash of every line of them
        var now = lines.GroupBy(l => l[..l.IndexOf('|')], StringComparer.Ordinal)
            .ToDictionary(g => g.Key, g => $"{g.Count(l => !l.Contains("|== ") && !l.EndsWith("|problems") && !l.Contains("|FAIL "))} {T.Sha256(System.Text.Encoding.UTF8.GetBytes(string.Join("\n", g)))[..16]}");
        var file = T.Data("definitions.txt");
        if (!File.Exists(file))
        {
            T.Skip("definitions of every shipped source and skeleton build as saved", "no saved snapshot; write it with --save-definitions");
            if (Environment.GetCommandLineArgs().Contains("--save-definitions"))
            {
                File.WriteAllLines(file, now.Select(kv => $"{kv.Key}\t{kv.Value}"));
                Console.WriteLine($"        saved {now.Count} to {file}");
            }
            return;
        }
        var saved = T.ReadPairs(file);
        var changed = now.Where(kv => !saved.TryGetValue(kv.Key, out var was) || was != kv.Value).Select(kv => kv.Key)
            .Concat(saved.Keys.Where(k => !now.ContainsKey(k))).ToList();
        int items = lines.Count(l => !l.Contains("|== ") && !l.EndsWith("|problems") && !l.Contains("|FAIL "));
        T.Check($"definitions of the 6 shipped sources and {now.Count - 6} skeleton builds as saved ({items} definitions)", changed.Count == 0,
            changed.Count == 0 ? "definitions.txt" : "changed: " + string.Join(", ", changed.Take(12)));
    }

    static void Annotations()
    {
        T.P30Part();
        var src =
            "        ORG 1000h\n" +
            ";@ name=first_setting type=u8\n" +
            "first_setting:  DB 10h\n" +
            ";@ name=bad_axis rows=1 cols=3 type=u8 cols.values=1,2,x\n" +
            "bad_axis:       DB 1, 2, 3\n" +
            ";@ name=moved_away at=no_such_label type=u8\n" +
            "here:           DB 5\n" +
            ";@ name=second_setting type=u8\n" +
            "second_setting: DB 7\n";
        var asm = new OkiAssembler(new AssemblerOptions()).AssembleText(src, Path.Combine(Path.GetTempPath(), "okirom-tests-defs.asm"));
        if (!T.Check("the annotated test source assembles", asm.Success, string.Join("; ", asm.Diagnostics.Where(d => d.Severity == Severity.Error).Take(2)))) return;
        DefinitionSet? defs = null; Exception? thrown = null;
        try { defs = DefinitionBuilder.FromAssembly(asm, "test.asm"); } catch (Exception ex) { thrown = ex; }
        var names = defs?.Items.Select(i => i.Name).ToHashSet() ?? [];
        T.Check("an annotation with a number that is not one (cols.values=1,2,x) loses that definition only, not the ROM's",
            thrown == null && names.Contains("first_setting") && names.Contains("second_setting") && !names.Contains("bad_axis"),
            thrown != null ? $"{thrown.GetType().Name}: {thrown.Message}" : string.Join(", ", names));
        T.Check("an at= that names nothing here is left out (not defined at the comment's own address, over other bytes)",
            thrown == null && !names.Contains("moved_away") && defs!.Items.All(i => i.Address != 0x1004 || i.Name != "moved_away"),
            string.Join(", ", names));
    }

    static void XdfSwitches()
    {
        var rom = new byte[Chip.RomSize];
        Array.Fill(rom, (byte)0xFF);
        var defs = new DefinitionSet { Name = "switches", RomSize = rom.Length };
        defs.MergeBuiltinFormulas();
        defs.Items.Add(new ItemDef { Name = "switch_off_ff", Address = 0x100, Type = CellType.U8, Flag = true, OnRaw = 0x01, OffRaw = 0xFF });
        defs.Items.Add(new ItemDef { Name = "switch_off_00", Address = 0x101, Type = CellType.U8, Flag = true, OnRaw = 0x01, OffRaw = 0x00 });
        defs.Items.Add(new ItemDef { Name = "a_bit", Address = 0x102, Type = CellType.Bit, Bit = 3 });
        XDocument doc;
        try { doc = XDocument.Parse(XdfExport.Write(defs, rom, "switches")); }
        catch (Exception ex) { T.Check("the XDF export of three switches is well-formed XML", false, ex.Message); return; }
        XElement? Titled(string kind, string title) => doc.Descendants(kind).FirstOrDefault(e => (string?)e.Element("title") == title);
        var ff = Titled("XDFCONSTANT", "switch_off_ff");
        T.Check("a byte switch whose off value is not 0 (on 01h, off FFh) goes out as a number, with both values said",
            ff != null && Titled("XDFFLAG", "switch_off_ff") == null && ((string?)ff.Element("description") ?? "").Contains("01h = on, FFh = off"),
            ff == null ? "no XDFCONSTANT for it" : (string?)ff.Element("description") ?? "(no description)");
        T.Check("a byte switch that is 0 when off is still a TunerPro flag", Titled("XDFFLAG", "switch_off_00") != null);
        T.Check("a bit is still a TunerPro flag", Titled("XDFFLAG", "a_bit") != null);
    }

    static void FeatureFiles()
    {
        var shipped = T.Roms("p30-skeleton-features.json");
        FeatureFile? ff = null; Exception? err = null;
        try { ff = FeatureFile.Load(shipped); } catch (Exception ex) { err = ex; }
        T.Check("the shipped feature file (roms/p30-skeleton-features.json) passes the checks", ff != null, err?.Message ?? $"{ff!.Features.Count} features");

        static string File1(string site, string pattern = "") =>
            "{ \"format\": \"okirom-features\", \"features\": [ { \"id\": \"t1\", \"variants\": [ { \"rom\": \"x\", \"sites\": [ " + site + " ] } ]" +
            (pattern.Length > 0 ? ", \"patterns\": [ " + pattern + " ]" : "") + " } ] }";
        T.Throws<InvalidDataException>("a site address that is not hex is refused when the file is read, saying which feature",
            () => FeatureFile.Parse(File1("{ \"address\": \"12G4\", \"original\": \"00\", \"patched\": \"01\" }")), ex => ex.Message.Contains("t1"));
        T.Throws<InvalidDataException>("a pattern whose patch runs past the bytes it is found by is refused",
            () => FeatureFile.Parse(File1("{ \"address\": \"1234\", \"original\": \"00\", \"patched\": \"01\" }", "{ \"find\": \"AA BB ?? DD\", \"offset\": 3, \"patched\": \"01 02\" }")),
            ex => ex.Message.Contains("runs past"));
        T.Throws<InvalidDataException>("original and patched of different lengths are still refused",
            () => FeatureFile.Parse(File1("{ \"address\": \"1234\", \"original\": \"00 00\", \"patched\": \"01\" }")));
        ff = null; err = null;
        try { ff = FeatureFile.Parse(File1("{ \"address\": \"0x1234\", \"original\": \"00\", \"patched\": \"01\" }", "{ \"find\": \"AA BB ?? DD\", \"offset\": 2, \"patched\": \"01 02\" }")); }
        catch (Exception ex) { err = ex; }
        T.Check("a good site (0x1234) and a pattern patch that ends on the last found byte are accepted", ff != null, err?.Message ?? "");
    }

    static void NumberGuards()
    {
        var rom = new byte[Chip.RomSize];
        rom[0x200] = 0x40; rom[0x201] = 0x12; rom[0x202] = 0x34;
        RomData.WriteRaw(rom, 0x200, CellType.U8, double.NaN);
        RomData.WriteRaw(rom, 0x201, CellType.U16, double.PositiveInfinity);
        T.Check("NaN or an infinity never becomes a byte (it was 00h: (int)NaN is 0)", rom[0x200] == 0x40 && rom[0x201] == 0x12 && rom[0x202] == 0x34,
            $"{rom[0x200]:X2} {rom[0x201]:X2} {rom[0x202]:X2}");
        RomData.WriteRaw(rom, 0x200, CellType.U8, 65.4);
        T.Check("an ordinary value is still written (65.4 -> 41h)", rom[0x200] == 0x41, $"{rom[0x200]:X2}");

        var defs = new DefinitionSet { Name = "scale", RomSize = rom.Length };
        defs.MergeBuiltinFormulas();
        var table = new ItemDef { Name = "a_table", Address = 0x300, Type = CellType.U8, Rows = 2, Cols = 2 };
        defs.Items.Add(table);
        for (int i = 0; i < 4; i++) rom[0x300 + i] = (byte)(0x40 + i);
        var inf = Rescale.ScaleTable(defs, rom, table, double.PositiveInfinity);
        var nan = Rescale.ScaleTable(defs, rom, table, double.NaN);
        T.Check("scaling a table by infinity or NaN changes nothing (infinity used to take every cell to the top of its scale)",
            !inf.Any && !nan.Any && inf.CellsChanged == 0, $"{inf.Summary} / {nan.Summary}");
        var tenPct = Rescale.ScaleTable(defs, rom, table, 1.10);
        T.Check("scaling by 1.10 still changes the cells", tenPct.Any && tenPct.CellsChanged > 0, tenPct.Summary);
    }
}
