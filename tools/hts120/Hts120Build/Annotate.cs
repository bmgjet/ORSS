using OkiRomSim.Calibration;

namespace Hts120Build;

/// Writes the ";@" definition annotations into the source: what the calibration editor would build with
/// Detect and "Guess the rest from the names", done once here so the file opens with its settings defined,
/// typed, scaled and bound to the feature pages. HTS120's own settings get hand-written definitions.
public static class Annotate
{
    /// Labels HTS115.asm got wrong, found by what the code does with them (the page that edits the byte).
    static readonly (string From, string To)[] Renames =
    [
        ("DCode13", "IABSetRPM"),   // 611Ah: the IAB engage rpm the IAB code compares with (code 13 is chkBaro at 61F5h)
    ];

    public static (int Items, int Bound) Run(Doc doc, IReadOnlyList<RomReference>? references = null)
    {
        foreach (var (from, to) in Renames)
        {
            var word = new System.Text.RegularExpressions.Regex($@"\b{from}\b");
            for (int i = 0; i < doc.Lines.Count; i++) doc.Lines[i] = word.Replace(doc.Lines[i], to);
        }
        var r = doc.AssembleOrThrow("annotate");
        var defs = DefinitionBuilder.FromAssembly(r, Path.GetFileName(doc.Path));
        CalibrationDetector.Detect(defs, r, r.Image, [(Path.GetFullPath(doc.Path), string.Join("\n", doc.Lines))], references);
        // every page row bound by address from the HTS 1.15 layout (HTS120's own settings by label)
        CalPage.BindAll(defs, r.Image);
        var log = defs.Items.FirstOrDefault(i => i.Name == "hts120_log_table")
                  ?? AddAt(defs, "hts120_log_table");
        log.Type = CellType.U16; log.Rows = 1; log.Cols = 5; log.Formula = null; log.Category = "HTS120";
        log.Description = "Datalog command 40h: the RAM addresses it sends, 0 ends.";
        // the pages HTS has (its three GPOs and its own pages), not the skeleton modules' ones
        var missing = new[] { CalPage.Gpo(1), CalPage.Gpo(2), CalPage.Gpo(3) }.Concat(HtsPages.All()).SelectMany(p => p.Slots()).Where(sl => CalPage.Bound(defs, sl) == null).ToList();
        if (missing.Count > 0) Console.WriteLine($"  annotate: {missing.Count} page row(s) not in the HTS layout: {string.Join(", ", missing)}");

        // one ";@" line straight above the line that defines each item's label (the annotation takes the
        // address the next statement assembles at); an item with no label line of its own names it with at=
        var labelLine = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < doc.Lines.Count; i++)
            if (Doc.Label(doc.Lines[i]) is string l) labelLine.TryAdd(l, i);
        var inserts = new List<(int Line, string Text)>();
        var orphans = new List<string>();
        foreach (var item in defs.Items)
        {
            var text = DefinitionBuilder.ToAnnotation(item, defs);
            // above its label only when it starts at the label (a table of (input, value) pairs starts a byte after it)
            if (labelLine.TryGetValue(item.Name, out int li) && defs.Symbols.TryGetValue(item.Name, out int la) && la == item.Address) inserts.Add((li, ";@ " + text));
            else orphans.Add($";@ {text} at=0{item.Address:X4}h");
        }
        foreach (var (li, text) in inserts.OrderByDescending(x => x.Line)) doc.Lines.Insert(li, text);
        if (orphans.Count > 0)
        {
            doc.Lines.Add("");
            doc.Lines.Add("; definitions for settings without a label of their own (at= gives the address)");
            doc.Lines.AddRange(orphans);
        }
        return (defs.Items.Count, defs.Items.Count(i => i.Slot != null));
    }

    static ItemDef AddAt(DefinitionSet defs, string label)
    {
        if (!defs.Symbols.TryGetValue(label, out int a)) throw new Exception($"no label {label}");
        var item = new ItemDef { Name = label, Address = a };
        defs.Items.Add(item);
        return item;
    }
}
