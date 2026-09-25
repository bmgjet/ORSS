// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;

namespace OkiRomSim.Calibration;

/// Writes a definition set as a TunerPro XDF: tables as XDFTABLE (axis breakpoints as labels, read from the ROM at export time), single values as XDFCONSTANT, switches as XDFFLAG. The layout follows XDFs TunerPro itself wrote (reference/tunerpro): a plain `<baseoffset>` element, 8-bit label axes with a -32 major stride, and a z axis that carries only the address, element size, row and column counts - a row stride only when the rows are not packed. Anything more (extra attributes, a base-offset element in the newer attribute form) has been seen to make TunerPro read from the wrong place. XDF math is plain arithmetic in X. Formulas that are more than that (the log-scaled rpm axis byte, comparisons) are exported raw with the real formula in the description. Fuel maps multiply each column by a multiplier row, which XDF cannot express per column: the map is exported as stored and the multiplier row as its own table, and the description says so.
public static class XdfExport
{
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// How a padded row is written. The maps here store more bytes per row than they use, and the two readings of TunerPro's `mmedmajorstridebits` in the wild disagree: XDFs written for packed tables carry one element's worth of bits (so it reads as the step from one element to the next), while the attribute is also documented as the step from one row to the next. Written the wrong way round, a padded map comes out shuffled - the values are all there, but rows start in the middle of the table. Both are offered, and the export asks which to use when a map has padded rows.
    public enum Stride
    {
        /// Declare the row as the full stride: a 20 x 10 map whose rows are 24 bytes apart goes out as 20 x 24, the spare columns labelled "pad". Nothing is left to interpretation - TunerPro reads consecutive bytes and every cell lands where it really is - which is why this is the default; the padding columns are simply ignored while tuning.
        PaddingAsColumns,
        /// mmedmajorstridebits = bytes from the start of one row to the start of the next.
        WholeRow,
        /// mmedmajorstridebits = the padding after each row only (row bytes are added by TunerPro).
        PaddingOnly,
    }

    /// How much of the file to write.
    public enum Layout
    {
        /// Exactly the shape of the XDFs written for these ECUs that are known to work - and nothing else. Header: flags, description, baseoffset, DEFAULTS. Tables: a title, the two label axes, the data axis. No definition title, no region, no categories, no per-item descriptions, no side tables. Everything TunerPro needs to read the maps and not one element more, because every extra element is a chance to be read differently by a version of TunerPro nobody here has.
        Reference,
        /// The same, plus a definition title, the binary region, categories, and a description on every item saying where it came from and how the ROM really scales it - and, for a fuel map, its per-column multiplier row as a table of its own. More useful to read; more to go wrong if a TunerPro build disagrees about any of it.
        Annotated,
    }

    /// What the numbers in TunerPro mean.
    public enum Values
    {
        /// The bytes as stored, with the scaling only described in words. This is what the XDFs written for these ECUs by hand do, so the numbers line up with those files - and it is the only honest option for a fuel map, whose per-column multiplier XDF cannot express (applying the rest of the scaling on its own would give a number that is neither the stored byte nor the real value).
        Raw,
        /// The scaling applied, where XDF's arithmetic can express it (degrees, percent, volts). A fuel map with a multiplier row is still written raw.
        Scaled,
    }

    [ThreadStatic] static Stride _stride;
    [ThreadStatic] static Values _values;
    [ThreadStatic] static Layout _layout;

    public static string Write(DefinitionSet defs, byte[] rom, string title, Stride stride = Stride.PaddingAsColumns,
                               Values values = Values.Raw, Layout layout = Layout.Reference)
    {
        _stride = stride;
        _values = values;
        _layout = layout;
        bool full = layout == Layout.Annotated;
        var sb = new StringBuilder();
        var settings = new XmlWriterSettings { Indent = true, IndentChars = "  ", OmitXmlDeclaration = true, Encoding = new UTF8Encoding(false) };
        using (var w = XmlWriter.Create(sb, settings))
        {
            w.WriteComment($" Written {DateTime.Now:MM/dd/yyyy HH:mm:ss} ");
            w.WriteStartElement("XDFFORMAT");
            w.WriteAttributeString("version", "1.50");

            var categories = defs.Items.Select(i => string.IsNullOrWhiteSpace(i.Category) ? "General" : i.Category).Distinct().OrderBy(c => c).ToList();
            w.WriteStartElement("XDFHEADER");
            w.WriteElementString("flags", "0x1");
            if (full) w.WriteElementString("deftitle", title);
            // the reference files carry the element empty rather than leaving it out
            w.WriteElementString("description", full ? $"{defs.Items.Count} definitions for {defs.Name}. 66K ECU, little-endian words." : "");
            w.WriteElementString("baseoffset", "0");
            w.WriteStartElement("DEFAULTS");
            w.WriteAttributeString("datasizeinbits", "8"); w.WriteAttributeString("sigdigits", "2"); w.WriteAttributeString("outputtype", "1");
            bool anyLittleEndianWords = defs.Items.Any(i => i.Type is CellType.U16 or CellType.S16);
            w.WriteAttributeString("signed", "0");
            w.WriteAttributeString("lsbfirst", anyLittleEndianWords ? "1" : "0");
            w.WriteAttributeString("float", "0");
            w.WriteEndElement();
            if (full)
            {
                w.WriteStartElement("REGION");
                w.WriteAttributeString("type", "0xFFFFFFFF"); w.WriteAttributeString("startaddress", "0x0");
                w.WriteAttributeString("size", "0x" + Math.Max(rom.Length, defs.RomSize).ToString("X")); w.WriteAttributeString("regionflags", "0x0");
                w.WriteAttributeString("name", "Binary File"); w.WriteAttributeString("desc", "This region describes the bin file edited by this XDF");
                w.WriteEndElement();
                for (int i = 0; i < categories.Count; i++)
                {
                    w.WriteStartElement("CATEGORY");
                    w.WriteAttributeString("index", "0x" + i.ToString("X"));
                    w.WriteAttributeString("name", categories[i]);
                    w.WriteEndElement();
                }
            }
            w.WriteEndElement(); // XDFHEADER

            int id = 0x100;
            foreach (var item in defs.Items.OrderBy(i => i.Category).ThenBy(i => i.Address))
            {
                if (item.Address < 0 || item.Address + item.Span > Math.Max(rom.Length, defs.RomSize)) continue;
                int cat = categories.IndexOf(string.IsNullOrWhiteSpace(item.Category) ? "General" : item.Category) + 1;
                FormulaDef f;
                try { f = defs.Formula(item.Formula); } catch { f = Builtin.Raw; }
                if (item.Flag || item.Type == CellType.Bit) WriteFlag(w, item, cat, id++);
                else if (item.IsTable && item.Count > 1) id = WriteTable(w, defs, rom, item, f, cat, id);
                else WriteConstant(w, item, f, cat, id++);
            }
            w.WriteEndElement(); // XDFFORMAT
        }
        return sb.ToString();
    }

    /// The formula as XDF math in X for this item, or null when the values are exported as stored (asked for, or forced by a per-column multiplier XDF cannot apply).
    static string? Equation(ItemDef item, FormulaDef f) =>
        _values == Values.Raw || item.ColumnScaleAddress != null ? null : Equation(f);

    /// The formula as XDF math in X, or null when XDF cannot express it.
    public static string? Equation(FormulaDef f)
    {
        var e = Regex.Replace(f.Expr, @"max\(\s*x\s*,\s*1\s*\)", "X", RegexOptions.IgnoreCase);
        e = Regex.Replace(e, @"\bx\b", "X");
        return !Regex.IsMatch(e, @"^[0-9X+\-*/(). ]+$") ? null : e.Replace(" ", "");
    }

    static int Bits(ItemDef item) => item.ElementSize * 8;
    static bool Signed(ItemDef item) => item.Type is CellType.S8 or CellType.S16 or CellType.S16BE;

    static void WriteMath(XmlWriter w, string equation)
    {
        w.WriteStartElement("MATH");
        w.WriteAttributeString("equation", equation);
        w.WriteStartElement("VAR"); w.WriteAttributeString("id", "X"); w.WriteEndElement();
        w.WriteEndElement();
    }

    static void Category(XmlWriter w, int cat)
    {
        if (_layout == Layout.Reference) return;
        w.WriteStartElement("CATEGORYMEM");
        w.WriteAttributeString("index", "0");
        w.WriteAttributeString("category", cat.ToString(Inv));
        w.WriteEndElement();
    }

    static string Describe(ItemDef item, FormulaDef f, string? eq)
    {
        if (_layout == Layout.Reference) return "";
        var d = item.Description;
        if (eq == null && f.Name != "raw") d += (d.Length > 0 ? " " : "") + $"[shown raw: the formula {f.Name} = {f.Expr} cannot be written as XDF math]";
        if (item.Origin != null) d += (d.Length > 0 ? " " : "") + $"({item.Origin})";
        return d;
    }

    /// The stored-data element. Only the attributes TunerPro's own files carry: an address, the element size, and (for tables) the counts and a row stride when the rows are not packed.
    static void EmbeddedData(XmlWriter w, ItemDef item, int? rows = null, int? cols = null)
    {
        w.WriteStartElement("EMBEDDEDDATA");
        if (Signed(item)) w.WriteAttributeString("mmedtypeflags", "0x01");
        w.WriteAttributeString("mmedaddress", "0x" + item.Address.ToString("X"));
        w.WriteAttributeString("mmedelementsizebits", Bits(item).ToString(Inv));
        if (rows is int r && cols is int c)
        {
            int packed = c * item.ElementSize;
            bool padded = item.RowStride != packed;
            if (padded && _stride == Stride.PaddingAsColumns)
            {
                // widen the table to the whole stride: consecutive bytes, nothing to interpret
                w.WriteAttributeString("mmedrowcount", r.ToString(Inv));
                w.WriteAttributeString("mmedcolcount", (item.RowStride / item.ElementSize).ToString(Inv));
                w.WriteEndElement();
                return;
            }
            w.WriteAttributeString("mmedrowcount", r.ToString(Inv));
            w.WriteAttributeString("mmedcolcount", c.ToString(Inv));
            if (padded)
                w.WriteAttributeString("mmedmajorstridebits",
                    ((_stride == Stride.PaddingOnly ? item.RowStride - packed : item.RowStride) * 8).ToString(Inv));
        }
        w.WriteEndElement();
    }

    static void WriteConstant(XmlWriter w, ItemDef item, FormulaDef f, int cat, int id)
    {
        var eq = Equation(item, f);
        w.WriteStartElement("XDFCONSTANT");
        w.WriteAttributeString("uniqueid", "0x" + id.ToString("X"));
        w.WriteElementString("title", item.Name);
        var desc = Describe(item, f, eq);
        if (desc.Length > 0) w.WriteElementString("description", desc);
        Category(w, cat);
        EmbeddedData(w, item);
        if (eq != null && f.Unit.Length > 0) w.WriteElementString("units", f.Unit);
        w.WriteElementString("decimalpl", (eq == null ? 0 : Math.Clamp(f.Decimals, 0, 4)).ToString(Inv));
        w.WriteElementString("outputtype", "1");
        w.WriteElementString("datatype", "0");
        w.WriteElementString("unittype", "0");
        w.WriteStartElement("DALINK"); w.WriteAttributeString("index", "0"); w.WriteEndElement();
        WriteMath(w, eq ?? "X");
        w.WriteEndElement();
    }

    static void WriteFlag(XmlWriter w, ItemDef item, int cat, int id)
    {
        w.WriteStartElement("XDFFLAG");
        w.WriteAttributeString("uniqueid", "0x" + id.ToString("X"));
        w.WriteElementString("title", item.Name);
        if (item.Description.Length > 0) w.WriteElementString("description", item.Description);
        Category(w, cat);
        w.WriteStartElement("EMBEDDEDDATA");
        w.WriteAttributeString("mmedaddress", "0x" + item.Address.ToString("X"));
        w.WriteAttributeString("mmedelementsizebits", "8");
        w.WriteEndElement();
        int mask = item.Type == CellType.Bit ? 1 << item.Bit : Math.Max(1, (int)item.OnRaw) & 0xFF;
        w.WriteElementString("mask", "0x" + mask.ToString("X"));
        w.WriteEndElement();
    }

    static int WriteTable(XmlWriter w, DefinitionSet defs, byte[] rom, ItemDef item, FormulaDef f, int cat, int id)
    {
        var eq = Equation(item, f);
        int rows = Math.Max(1, item.Rows), cols = Math.Max(1, item.Cols);
        w.WriteStartElement("XDFTABLE");
        w.WriteAttributeString("uniqueid", "0x" + id.ToString("X"));
        w.WriteAttributeString("flags", "0x0");
        w.WriteElementString("title", item.Name);
        var desc = Describe(item, f, eq);
        if (_layout == Layout.Annotated)
        {
            if (_stride == Stride.PaddingAsColumns && item.RowStride != cols * item.ElementSize)
                desc += $" The ROM keeps {item.RowStride} bytes per row and uses the first {cols}; the rest are shown as columns marked 'pad' so every cell lands where it really is - leave them alone.";
            if (eq == null && Equation(f) is { } real && real != "X")
                desc += $" Values are the bytes as stored; this ROM reads them as {real.Replace("X", "the stored byte")}{(f.Unit.Length > 0 ? " " + f.Unit : "")}.";
            if (item.ColumnScaleAddress is int ms)
                desc += $" Cells are as stored; the ECU multiplies each column by the byte in {item.Name}_multiplier (at {ms:X4}) before scaling, which XDF cannot do per column.";
        }
        if (desc.Length > 0) w.WriteElementString("description", desc);
        Category(w, cat);
        // when the padding goes out as extra columns, the x axis has to be that wide too
        int shownCols = _stride == Stride.PaddingAsColumns && item.RowStride != cols * item.ElementSize
            ? item.RowStride / item.ElementSize : cols;
        var colLabels = AxisLabels(defs, rom, item.ColAxis, cols);
        if (shownCols > cols)
            colLabels = [.. colLabels, .. Enumerable.Range(cols, shownCols - cols).Select(_ => "pad")];
        WriteAxis(w, "x", shownCols, colLabels, AxisUnits(item.ColAxis, "x"));
        WriteAxis(w, "y", rows, AxisLabels(defs, rom, item.RowAxis, rows), AxisUnits(item.RowAxis, "y"));
        w.WriteStartElement("XDFAXIS");
        w.WriteAttributeString("id", "z");
        EmbeddedData(w, item, rows, cols);
        if (eq != null && f.Unit.Length > 0) w.WriteElementString("units", f.Unit);
        w.WriteElementString("decimalpl", (eq == null ? 2 : Math.Clamp(f.Decimals, 0, 4)).ToString(Inv));
        var (lo, hi) = RomData.RawRange(item.Type);
        double a = eq == null ? lo : f.ToValue(lo), b = eq == null ? hi : f.ToValue(hi);
        w.WriteElementString("min", Math.Min(a, b).ToString("0.000000", Inv));
        w.WriteElementString("max", Math.Max(a, b).ToString("0.000000", Inv));
        w.WriteElementString("outputtype", "1");
        WriteMath(w, eq ?? "X");
        w.WriteEndElement(); // z
        w.WriteEndElement(); // XDFTABLE
        id++;

        // the reference files leave the multiplier rows out altogether; they are only useful alongside a description explaining what they are for
        if (_layout == Layout.Annotated && item.ColumnScaleAddress is int mult)
        {
            var m = new ItemDef
            {
                Name = item.Name + "_multiplier", Address = mult, Rows = 1, Cols = cols, Type = CellType.U8, Category = item.Category,
                Description = $"per-column multiplier row of {item.Name}", ColAxis = item.ColAxis,
            };
            id = WriteTable(w, defs, rom, m, Builtin.Raw, cat, id);
        }
        return id;
    }

    static string[] AxisLabels(DefinitionSet defs, byte[] rom, AxisDef? axis, int count)
    {
        double[] values;
        try { values = axis == null ? [.. Enumerable.Range(0, count).Select(i => (double)i)] : RomData.AxisValues(defs, rom, axis, count); }
        catch { values = [.. Enumerable.Range(0, count).Select(i => (double)i)]; }
        return [.. Enumerable.Range(0, count).Select(i => i < values.Length && !double.IsNaN(values[i]) ? values[i].ToString("0.00", Inv) : i.ToString(Inv))];
    }

    /// The (datatype, unittype) pair the working files carry on a table's label axes. They are TunerPro's own unit codes, and the reference XDF uses 23/20 on the load axis and 6/26 on the rpm axis; anything else gets 0/0, which means "no unit" and is what TunerPro writes when it does not know either.
    static (string Data, string Unit) AxisUnits(AxisDef? axis, string which)
    {
        string unit = (axis?.Unit ?? "").ToLowerInvariant();
        if (unit.Contains("rpm")) return ("6", "26");
        if (unit.Contains("bar") || unit.Contains("kpa") || unit.Contains("psi")) return ("23", "20");
        // nothing said: the reference files still label the axes by position, columns being load
        return which == "x" ? ("23", "20") : ("6", "26");
    }

    /// A label axis: the breakpoints as text, exactly as TunerPro writes them (8-bit elements and a -32 major stride mark an axis that is not read from the file).
    static void WriteAxis(XmlWriter w, string which, int count, string[] labels, (string Data, string Unit) units)
    {
        w.WriteStartElement("XDFAXIS");
        w.WriteAttributeString("id", which);
        w.WriteAttributeString("uniqueid", "0x0");
        w.WriteStartElement("EMBEDDEDDATA");
        w.WriteAttributeString("mmedelementsizebits", "8");
        w.WriteAttributeString("mmedmajorstridebits", "-32");
        w.WriteEndElement();
        w.WriteElementString("indexcount", count.ToString(Inv));
        w.WriteElementString("datatype", units.Data);
        w.WriteElementString("unittype", units.Unit);
        w.WriteStartElement("DALINK"); w.WriteAttributeString("index", "0"); w.WriteEndElement();
        for (int i = 0; i < count; i++)
        {
            w.WriteStartElement("LABEL");
            w.WriteAttributeString("index", i.ToString(Inv));
            w.WriteAttributeString("value", labels[i]);
            w.WriteEndElement();
        }
        WriteMath(w, "X");
        w.WriteEndElement();
    }
}
