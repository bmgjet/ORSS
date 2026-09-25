// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OkiRomSim.Calibration;

// ---------------------------------------------------------------- formulas

/// A scaling formula: raw byte/word in the ROM -> engineering value, and back. `expr` is in terms of x (the raw value). `inverse` is optional: when it is missing the raw value is found by searching the raw domain, which works for non-invertible or piecewise encodings (e.g. Honda's exponent/mantissa RPM byte).
public sealed class FormulaDef
{
    public string Name { get; set; } = "";
    public string Expr { get; set; } = "x";
    public string? Inverse { get; set; }
    public string Unit { get; set; } = "";
    /// Display rounding (e.g. 50 for RPM axes that the ECU quantises to 50 rpm).
    public double Step { get; set; }
    public int Decimals { get; set; } = 2;
    public string? Notes { get; set; }

    Expression? _e, _i;
    public double ToValue(double raw)
    {
        _e ??= Expression.Parse(Expr);
        double v = _e.Eval(raw);
        if (Step > 0) v = Math.Round(v / Step, MidpointRounding.AwayFromZero) * Step;
        return v;
    }

    /// Inverse. Without an explicit inverse the raw domain is searched, so any monotonic or piecewise formula round-trips; ties pick the smaller raw value.
    public double ToRaw(double value, double rawMin, double rawMax)
    {
        if (Inverse != null)
        {
            _i ??= Expression.Parse(Inverse);
            return Math.Clamp(Math.Round(_i.Eval(value), MidpointRounding.AwayFromZero), rawMin, rawMax);
        }
        double best = rawMin, bestErr = double.MaxValue;
        for (double r = rawMin; r <= rawMax; r++)
        {
            double err = Math.Abs(ToValue(r) - value);
            if (err < bestErr - 1e-12) { bestErr = err; best = r; }
        }
        return best;
    }

    public string Format(double raw) => ToValue(raw).ToString("F" + Decimals, CultureInfo.InvariantCulture) + (Unit.Length > 0 ? " " + Unit : "");
}

/// Tiny expression evaluator over one variable `x`. Supports + - * / % ^, parentheses, comparisons (which yield 1 or 0, so they compose: "x - 256 * (x > 127)"), and the functions round, floor, ceil, abs, min, max, pow, log2, exp2, and the bit operators &, |, >>, <<.
public sealed class Expression
{
    readonly List<Token> _rpn;
    Expression(List<Token> rpn) { _rpn = rpn; }

    readonly record struct Token(char Kind, double Num, string Text); // 'n' number, 'x' var, 'o' op, 'f' func

    public static Expression Parse(string s)
    {
        var output = new List<Token>();
        var ops = new Stack<Token>();
        int i = 0;
        int Prec(string o) => o switch
        {
            "||" => 1, "&&" => 2,
            "<" or ">" or "<=" or ">=" or "==" or "!=" => 3,
            "|" or "&" => 4,
            "<<" or ">>" => 5,
            "+" or "-" => 6,
            "*" or "/" or "%" => 7,
            "^" => 8,
            "u-" => 9,
            _ => -1,
        };
        bool prevValue = false;
        while (i < s.Length)
        {
            char c = s[i];
            if (char.IsWhiteSpace(c)) { i++; continue; }
            if (char.IsAsciiDigit(c) || (c == '.' && i + 1 < s.Length && char.IsAsciiDigit(s[i + 1])))
            {
                int j = i;
                if (s[i] == '0' && i + 1 < s.Length && (s[i + 1] is 'x' or 'X'))
                {
                    j = i + 2;
                    while (j < s.Length && Uri.IsHexDigit(s[j])) j++;
                    output.Add(new Token('n', (double)Convert.ToInt64(s[(i + 2)..j], 16), ""));
                }
                else
                {
                    while (j < s.Length && (char.IsAsciiDigit(s[j]) || s[j] == '.' || s[j] == 'e' ||
                           (s[j] is '+' or '-' && j > i && s[j - 1] == 'e'))) j++;
                    output.Add(new Token('n', double.Parse(s[i..j], CultureInfo.InvariantCulture), ""));
                }
                i = j; prevValue = true; continue;
            }
            if (char.IsAsciiLetter(c) || c == '_')
            {
                int j = i;
                while (j < s.Length && (char.IsAsciiLetterOrDigit(s[j]) || s[j] == '_')) j++;
                var w = s[i..j];
                if (w is "x" or "X" or "raw") { output.Add(new Token('x', 0, w)); prevValue = true; }
                else if (w == "pi") { output.Add(new Token('n', Math.PI, "")); prevValue = true; }
                else { ops.Push(new Token('f', 0, w.ToLowerInvariant())); prevValue = false; }
                i = j; continue;
            }
            if (c == '(') { ops.Push(new Token('o', 0, "(")); i++; prevValue = false; continue; }
            if (c == ')' || c == ',')
            {
                while (ops.Count > 0 && ops.Peek().Text != "(") output.Add(ops.Pop());
                if (c == ')')
                {
                    if (ops.Count == 0) throw new FormatException("unbalanced ')'");
                    ops.Pop();
                    if (ops.Count > 0 && ops.Peek().Kind == 'f') output.Add(ops.Pop());
                    prevValue = true;
                }
                i++; continue;
            }
            string op = c.ToString();
            foreach (var two in new[] { "<<", ">>", "<=", ">=", "==", "!=", "&&", "||" })
                if (s.Length - i >= 2 && s.Substring(i, 2) == two) { op = two; break; }
            if (op == "-" && !prevValue) op = "u-";
            i += op == "u-" ? 1 : op.Length;
            if (Prec(op) < 0) throw new FormatException($"unexpected '{op}' in formula");
            while (ops.Count > 0 && ops.Peek().Kind == 'o' && ops.Peek().Text != "(" &&
                   Prec(ops.Peek().Text) >= Prec(op) && op != "^" && op != "u-")
                output.Add(ops.Pop());
            ops.Push(new Token('o', 0, op));
            prevValue = false;
        }
        while (ops.Count > 0)
        {
            var t = ops.Pop();
            if (t.Text == "(") throw new FormatException("unbalanced '('");
            output.Add(t);
        }
        return new Expression(output);
    }

    public double Eval(double x)
    {
        var st = new Stack<double>();
        double Pop() => st.Count > 0 ? st.Pop() : throw new FormatException("malformed formula");
        foreach (var t in _rpn)
        {
            switch (t.Kind)
            {
                case 'n': st.Push(t.Num); break;
                case 'x': st.Push(x); break;
                case 'f':
                    {
                        switch (t.Text)
                        {
                            case "round": { double a = Pop(); st.Push(Math.Round(a, MidpointRounding.AwayFromZero)); break; }
                            case "floor": st.Push(Math.Floor(Pop())); break;
                            case "ceil": st.Push(Math.Ceiling(Pop())); break;
                            case "abs": st.Push(Math.Abs(Pop())); break;
                            case "log2": st.Push(Math.Log2(Pop())); break;
                            case "exp2": st.Push(Math.Pow(2, Pop())); break;
                            case "sqrt": st.Push(Math.Sqrt(Pop())); break;
                            // the Honda ECT / IAT thermistor curve: byte -> degrees C
                            case "hondatemp": st.Push(HondaDatalog.ThermistorC((byte)Math.Clamp(Math.Round(Pop()), 0, 255))); break;
                            case "min": { double b = Pop(), a = Pop(); st.Push(Math.Min(a, b)); break; }
                            case "max": { double b = Pop(), a = Pop(); st.Push(Math.Max(a, b)); break; }
                            case "pow": { double b = Pop(), a = Pop(); st.Push(Math.Pow(a, b)); break; }
                            default: throw new FormatException($"unknown function '{t.Text}'");
                        }
                        break;
                    }
                default:
                    {
                        if (t.Text == "u-") { st.Push(-Pop()); break; }
                        double y = Pop(), z = Pop();
                        st.Push(t.Text switch
                        {
                            "+" => z + y, "-" => z - y, "*" => z * y,
                            "/" => y == 0 ? 0 : z / y,
                            "%" => y == 0 ? 0 : z % y,
                            "^" => Math.Pow(z, y),
                            "&" => (long)z & (long)y,
                            "|" => (long)z | (long)y,
                            "<<" => (long)z << (int)y,
                            ">>" => (long)z >> (int)y,
                            "<" => z < y ? 1 : 0, ">" => z > y ? 1 : 0,
                            "<=" => z <= y ? 1 : 0, ">=" => z >= y ? 1 : 0,
                            "==" => z == y ? 1 : 0, "!=" => z != y ? 1 : 0,
                            "&&" => (z != 0 && y != 0) ? 1 : 0, "||" => (z != 0 || y != 0) ? 1 : 0,
                            _ => throw new FormatException($"unknown operator '{t.Text}'"),
                        });
                        break;
                    }
            }
        }
        return st.Count == 1 ? st.Pop() : throw new FormatException("malformed formula");
    }
}

// ---------------------------------------------------------------- definitions

public enum CellType { U8, S8, U16, S16, U16BE, S16BE, Bit }

public sealed class AxisDef
{
    public string? Name { get; set; }
    /// Address of the axis data, or null for a "virtual" axis given by Values.
    public int? Address { get; set; }
    public int Count { get; set; }
    public CellType Type { get; set; } = CellType.U8;
    public string? Formula { get; set; }
    public double[]? Values { get; set; }
    public string Unit { get; set; } = "";
    /// Bytes from one axis value to the next; 0 = packed. Honda (x, y) tables keep the axis interleaved with the values (3 bytes a step for a byte x and a word y).
    public int Stride { get; set; }
}

public sealed class ItemDef
{
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";
    public string Category { get; set; } = "General";
    /// Absolute ROM address. Written as "0x1234" in JSON but kept as an int here.
    public int Address { get; set; }
    public CellType Type { get; set; } = CellType.U8;
    /// 0 = scalar, otherwise the number of elements (rows*cols for a table).
    public int Rows { get; set; }
    public int Cols { get; set; }
    public string? Formula { get; set; }
    public AxisDef? RowAxis { get; set; }
    public AxisDef? ColAxis { get; set; }
    /// For Bit items: which bit of the byte.
    public int Bit { get; set; }
    public double? Min { get; set; }
    public double? Max { get; set; }
    public string? Label { get; set; }
    /// Where the definition came from (source file:line, or the def file).
    public string? Origin { get; set; }
    /// Which row of a feature page this definition fills, as a stable key ("gpo1.rpm.min"). A ROM's labels are whatever its author called them (and a disassembled stock ROM has none worth the name), so a feature page laid out the way the established tuning software does it cannot find its settings by name alone: it is told once, here, and the answer travels with the definitions - exported, imported and saved with a project like everything else.
    public string? Slot { get; set; }

    /// One definition can fill several rows (the same byte shown on two pages): Slot then holds them separated by ';'.
    public bool HasSlot(string slot) => Slot != null && Slot.Split(';').Any(x => x.Equals(slot, StringComparison.OrdinalIgnoreCase));
    public void AddSlot(string slot) { if (!HasSlot(slot)) Slot = Slot == null ? slot : Slot + ";" + slot; }
    /// Drop the slots `drop` says to; true when one was dropped.
    public bool RemoveSlots(Func<string, bool> drop)
    {
        if (Slot == null) return false;
        var keep = Slot.Split(';').Where(x => !drop(x)).ToList();
        bool changed = keep.Count != Slot.Split(';').Length;
        Slot = keep.Count == 0 ? null : string.Join(";", keep);
        return changed;
    }
    /// Bytes from the start of one row to the next; 0 = Cols * ElementSize (packed). Honda maps store wider rows than they use (e.g. 24 bytes per row, 16 columns).
    public int Stride { get; set; }
    /// Address of a per-column multiplier row (Honda fuel maps keep it right after the last row): the value shown is formula(cell * multiplier[column]).
    public int? ColumnScaleAddress { get; set; }
    /// An on/off setting: shown as a checkbox, checked when the raw value is not OffRaw.
    public bool Flag { get; set; }
    /// Raw value written when a flag is switched on (off writes OffRaw).
    public double OnRaw { get; set; } = 0xFF;
    public double OffRaw { get; set; }

    /// Bytes from one cell of a row to the next; 0 = packed. Honda (x, y) tables keep the axis between the values, so a byte-x / word-y table steps 3 bytes a cell and a byte / byte one steps 2.
    public int ColStride { get; set; }

    [JsonIgnore] public bool IsTable => Rows > 0 && Cols > 0;
    [JsonIgnore] public int CellStep => ColStride > 0 ? ColStride : ElementSize;
    [JsonIgnore] public int RowStride => Stride > 0 ? Stride : Math.Max(Cols, 1) * CellStep;
    /// ROM address of element `index` (row-major).
    public int CellAddress(int index)
    {
        return !IsTable ? Address + (index * ElementSize) : Address + (index / Cols * RowStride) + (index % Cols * CellStep);
    }
    /// Bytes spanned by the whole definition (rows at their stride, plus the multiplier row).
    [JsonIgnore]
    public int Span => IsTable
        ? Math.Max(((Rows - 1) * RowStride) + ((Cols - 1) * CellStep) + ElementSize, ColumnScaleAddress is int m ? m + Cols - Address : 0)
        : ByteLength;
    public bool Contains(int addr) => addr >= Address && addr < Address + Span;
    /// Row and column of the cell holding `addr`, or null when addr is outside the cells.
    public (int Row, int Col)? CellOf(int addr)
    {
        int off = addr - Address;
        if (off < 0) return null;
        if (!IsTable) return off < ByteLength ? (0, off / ElementSize) : null;
        int r = off / RowStride, inRow = off % RowStride, c = inRow / CellStep;
        return r < Rows && c < Cols && inRow % CellStep < ElementSize ? (r, c) : null;
    }
    [JsonIgnore] public int Count => IsTable ? Rows * Cols : 1;
    [JsonIgnore]
    public int ElementSize => Type switch { CellType.U16 or CellType.S16 or CellType.U16BE or CellType.S16BE => 2, _ => 1 };
    [JsonIgnore] public int ByteLength => Count * ElementSize;
}

public sealed class DefinitionSet
{
    public string Name { get; set; } = "";
    public string? RomId { get; set; }
    public int RomSize { get; set; } = 0x8000;
    public List<FormulaDef> Formulas { get; set; } = [];
    public List<ItemDef> Items { get; set; } = [];
    /// name -> address, for plain label lookups (from the assembler .sym output).
    public Dictionary<string, int> Symbols { get; set; } = [];

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static DefinitionSet Load(string path)
    {
        var d = JsonSerializer.Deserialize<DefinitionSet>(File.ReadAllText(path), Json)
                ?? throw new InvalidDataException("empty definition file");
        d.MergeBuiltinFormulas();
        return d;
    }
    public void Save(string path) => File.WriteAllText(path, JsonSerializer.Serialize(this, Json));

    public FormulaDef Formula(string? name)
    {
        if (name == null) return Builtin.Raw;
        var f = Formulas.FirstOrDefault(f => string.Equals(f.Name, name, StringComparison.OrdinalIgnoreCase))
                ?? Builtin.All.FirstOrDefault(f => string.Equals(f.Name, name, StringComparison.OrdinalIgnoreCase));
        return f ?? throw new KeyNotFoundException($"unknown formula '{name}'");
    }
    public void MergeBuiltinFormulas()
    {
        foreach (var b in Builtin.All)
            if (!Formulas.Any(f => string.Equals(f.Name, b.Name, StringComparison.OrdinalIgnoreCase)))
                Formulas.Add(b);
    }

    public ItemDef? Find(string name) =>
        Items.FirstOrDefault(i => string.Equals(i.Name, name, StringComparison.OrdinalIgnoreCase));

    /// label/symbol or 0x1234 / 1234h / 1234 -> address
    public bool TryResolve(string text, out int address)
    {
        address = 0;
        var t = text.Trim();
        if (Find(t) is { } item) { address = item.Address; return true; }
        if (Symbols.TryGetValue(t, out address)) return true;
        foreach (var (k, v) in Symbols)
            if (string.Equals(k, t, StringComparison.OrdinalIgnoreCase)) { address = v; return true; }
        var hx = t.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? t[2..]
               : t.EndsWith('h') || t.EndsWith('H') ? t[..^1] : t;
        return int.TryParse(hx, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out address);
    }

    /// Every symbol whose address covers `address`, nearest first.
    public IEnumerable<(string Name, int Address)> SymbolsAt(int address, int window = 64) =>
        Symbols.Where(kv => kv.Value <= address && address - kv.Value < window)
               .OrderBy(kv => address - kv.Value).Select(kv => (kv.Key, kv.Value));
}

/// Conversions that come up on OBD1 Honda 66K ROMs. Provenance is in Notes: these were read out of the user's own tuning application (Rom.cs), not measured, so check one against a known-good table before trusting it for a new ROM.
public static class Builtin
{
    public static readonly FormulaDef Raw = new() { Name = "raw", Expr = "x", Unit = "", Decimals = 0, Notes = "the stored number, unscaled" };

    public static readonly List<FormulaDef> All =
    [
        Raw,
        new FormulaDef
        {
            Name = "rpm_period_word", Expr = "1875000 / max(x, 1)", Inverse = "1875000 / max(x, 1)",
            Unit = "rpm", Decimals = 0, Step = 0,
            Notes = "16-bit crank period in 1.875 MHz timer ticks; rpm = 1875000 / period (self-inverse)",
        },
        new FormulaDef
        {
            Name = "rpm_axis_byte", Expr = "1875000 * x / 43520", Unit = "rpm", Decimals = 0, Step = 50,
            Notes = "8-bit RPM axis breakpoint, quantised to 50 rpm (Rom.cs byteToRpmHi8bit, constant 43520)",
        },
        new FormulaDef
        {
            Name = "rpm_axis_byte_log", Expr = "exp2(floor(x / 64)) * (500 + 7.8125 * (x % 64))",
            Unit = "rpm", Decimals = 0, Step = 25,
            Notes = "8-bit exponent(2 bits)/mantissa(6 bits) RPM breakpoint (Rom.cs byteToRpmLow8bit); not invertible in closed form, the raw value is searched",
        },
        new FormulaDef
        {
            Name = "ign_advance", Expr = "x * 0.25 - 6", Inverse = "(x + 6) / 0.25", Unit = "deg BTDC", Decimals = 2,
            Notes = "ignition timing cell, 0.25 deg per count with a -6 deg offset (Rom.cs); a ROM with a sync-base byte shifts this by (16 - (sync*0.25 - 6))",
        },
        new FormulaDef
        {
            Name = "honda_fuel", Expr = "x / 4", Inverse = "x * 4", Unit = "", Decimals = 1,
            Notes = "fuel map cell times its column multiplier, divided by 4 (the value the tuning software shows)",
        },
        new FormulaDef
        {
            Name = "ve_percent", Expr = "x * 100 / 128 - 100", Inverse = "(x + 100) * 128 / 100", Unit = "%", Decimals = 0,
            Notes = "VE map cell as the tuning software shows it: 128 = 0 %, each count 0.78 % (Rom.cs: raw / 128 * 100 - 100)",
        },
        new FormulaDef
        {
            Name = "ign_trim", Expr = "(x - 128) * 0.25", Inverse = "x / 0.25 + 128", Unit = "deg", Decimals = 2,
            Notes = "signed ignition correction, 128 = no change (Rom.cs byteToIgnCorrection)",
        },
        new FormulaDef
        {
            Name = "map_mbar", Expr = "x * 7.221 - 59", Inverse = "(x + 59) / 7.221", Unit = "mbar", Decimals = 0,
            Notes = "MAP sensor preset 1 (Rom.cs byteToMillibar); preset 0 is (x/2 + fuelCutMap) * 7.221 - 59, preset 2 interpolates the ROM's own high/low calibration words",
        },
        new FormulaDef
        {
            Name = "map_kpa", Expr = "(x * 7.221 - 59) / 10", Inverse = "(x * 10 + 59) / 7.221", Unit = "kPa", Decimals = 1,
            Notes = "same as map_mbar in kPa",
        },
        // ---- MSM66911 (Honda P13 / P14). The crank timer ticks every 4 us on that part, which is where its rpm constant comes from; the sensors are its own, not the 66207's.
        new FormulaDef
        {
            Name = "p13_map_mbar", Expr = "x * 1860 / 255 - 70", Inverse = "(x + 70) * 255 / 1860", Unit = "mBar", Decimals = 0,
            Notes = "P13 MAP from the raw A/D high byte: the sensor reads -70 mBar at 0 V and 1790 at 5 V",
        },
        new FormulaDef
        {
            Name = "p13_map_axis", Expr = "(x * 128 + 6144) * 1860 / 65535 - 70", Unit = "mBar", Decimals = 0,
            Notes = "P13 table/axis load byte: the ROM builds it as (Map16 - 0x1800) >> 7, so it covers about 104..1031 mBar " +
                    "(0.47..2.96 V) and cannot represent boost at all",
        },
        new FormulaDef
        {
            Name = "p13_thermistor_c",
            Expr = "((0.1423 * (x/51)^6 - 2.4938 * (x/51)^5 + 17.837 * (x/51)^4 - 68.698 * (x/51)^3 + 154.69 * (x/51)^2 " +
                   "- 232.75 * (x/51) + 284.24) - 32) * 5 / 9",
            Unit = "°C", Decimals = 1,
            Notes = "P13 coolant and intake air share one NTC curve; this is the polynomial in volts (raw/51) the ROM's table follows, converted to Celsius",
        },
        new FormulaDef
        {
            Name = "p13_volts", Expr = "x / 51", Inverse = "x * 51", Unit = "V", Decimals = 2,
            Notes = "P13 plain 0-5 V input (TPS, narrowband O2, ELD): raw / 51",
        },
        new FormulaDef
        {
            Name = "p13_batt_v", Expr = "x * 4.9 / 51", Inverse = "x * 51 / 4.9", Unit = "V", Decimals = 2,
            Notes = "P13 battery voltage (raw 0x66 = 9.8 V)",
        },
        new FormulaDef
        {
            Name = "p13_advance", Expr = "(x - 24) / 4", Inverse = "x * 4 + 24", Unit = "deg BTDC", Decimals = 2,
            Notes = "P13 ignition advance from the streamed byte",
        },
        new FormulaDef
        {
            Name = "p13_inj_ms", Expr = "x * 4.00839 / 1000", Inverse = "x * 1000 / 4.00839", Unit = "ms", Decimals = 3,
            Notes = "P13 injector pulse: the ROM's fuel word in 4.00839 us ticks",
        },
        new FormulaDef
        {
            Name = "p13_rpm8",
            Expr = "7.8125 * (x + 64) * (x < 64) + 15.625 * x * (x >= 64) * (x < 128) " +
                   "+ 31.25 * (x - 64) * (x >= 128) * (x < 192) + 62.5 * (x - 128) * (x >= 192)",
            Unit = "rpm", Decimals = 0, Step = 25,
            Notes = "P13 8-bit rpm byte: four straight lines meeting at 1000, 2000 and 4000 rpm (0xC0 = 4000). " +
                    "0xFE and 0xFF are the ROM's saturation markers, not readings",
        },
        // ---- the scalings the HTS 1.15 pages use (HTS-master Rom.cs), by what they convert
        new FormulaDef { Name = "honda_temp_c", Expr = "hondatemp(x)", Unit = "°C", Decimals = 0, Notes = "ECT / IAT byte through the Honda thermistor curve (HTS method_191 / method_230)" },
        new FormulaDef { Name = "hts_tps_pct", Expr = "(x - 25) / 2.04", Inverse = "x * 2.04 + 25", Unit = "%", Decimals = 0, Notes = "TPS byte as HTS shows it (method_198 / method_228)" },
        new FormulaDef { Name = "hts_trim_word", Expr = "x * 100 / 32768 - 100", Inverse = "(x + 100) * 32768 / 100", Unit = "%", Decimals = 1, Notes = "word trim, 8000h = 0% (method_203 / method_231, divisor 32768)" },
        new FormulaDef { Name = "hts_trim_128", Expr = "x * 100 / 128 - 100", Inverse = "(x + 100) * 128 / 100", Unit = "%", Decimals = 1, Notes = "byte trim, 80h = 0% (method_205, divisor 128)" },
        new FormulaDef { Name = "hts_trim_64", Expr = "x * 100 / 64 - 100", Inverse = "(x + 100) * 64 / 100", Unit = "%", Decimals = 1, Notes = "byte trim, 40h = 0% (method_205, divisor 64)" },
        new FormulaDef { Name = "hts_signed_trim", Expr = "(x - 128) * 100 / 128", Inverse = "x * 128 / 100 + 128", Unit = "%", Decimals = 1, Notes = "byte trim centred on 80h" },
        new FormulaDef { Name = "hts_half_step", Expr = "(x - 128) * 0.5", Inverse = "x / 0.5 + 128", Unit = "", Decimals = 1, Notes = "method_190 / method_222" },
        new FormulaDef { Name = "hts_duty_half", Expr = "x / 2", Inverse = "x * 2", Unit = "%", Decimals = 1, Notes = "solenoid duty, 2 per % (method_207 / method_211)" },
        new FormulaDef { Name = "hts_x10_ms", Expr = "x * 10", Inverse = "x / 10", Unit = "ms", Decimals = 0, Notes = "10 ms steps" },
        new FormulaDef { Name = "hts_x01_s", Expr = "x * 0.1", Inverse = "x / 0.1", Unit = "s", Decimals = 1, Notes = "0.1 s steps" },
        new FormulaDef { Name = "hts_quarter", Expr = "x / 4", Inverse = "x * 4", Unit = "", Decimals = 2, Notes = "quarter steps (method_223)" },
        new FormulaDef { Name = "hts_quarter_deg", Expr = "x / 4", Inverse = "x * 4", Unit = "°", Decimals = 2, Notes = "0.25 degree steps" },
        new FormulaDef { Name = "hts_eighth", Expr = "x / 8", Inverse = "x * 8", Unit = "", Decimals = 2, Notes = "eighth steps" },
        new FormulaDef { Name = "hts_batt_v", Expr = "x * 26 / 270", Inverse = "x * 270 / 26", Unit = "V", Decimals = 2, Notes = "battery through the ECU divider (method_208)" },
        new FormulaDef { Name = "hts_dwell_batt_v", Expr = "x * 0.052 + 6.26", Inverse = "(x - 6.26) / 0.052", Unit = "V", Decimals = 2, Notes = "dwell battery axis" },
        new FormulaDef { Name = "hts_x16", Expr = "x * 16", Inverse = "x / 16", Unit = "", Decimals = 0, Notes = "16 per step" },
        new FormulaDef
        {
            Name = "percent255", Expr = "x * 100 / 255", Inverse = "x * 255 / 100", Unit = "%", Decimals = 1,
            Notes = "byte used as a 0-100% fraction",
        },
        new FormulaDef
        {
            Name = "percent128", Expr = "x * 100 / 128", Inverse = "x * 128 / 100", Unit = "%", Decimals = 1,
            Notes = "byte where 128 = 100% (common for fuel/VE multipliers)",
        },
        new FormulaDef
        {
            Name = "signed_byte", Expr = "x - 256 * (x > 127)", Inverse = "x + 256 * (x < 0)", Unit = "", Decimals = 0,
            Notes = "two's-complement byte read as a signed number",
        },
        new FormulaDef
        {
            Name = "speed_kmh_byte", Expr = "x", Unit = "km/h", Decimals = 0,
            Notes = "road speed byte in km/h (HTS method_197 / method_233 show and store it as is)",
        },
        new FormulaDef
        {
            Name = "volts_5v_byte", Expr = "x * 5 / 255", Inverse = "x * 255 / 5", Unit = "V", Decimals = 3,
            Notes = "8-bit ADC reading as sensor volts (the 66207 ADC is 10-bit; use volts_5v_word when the ROM keeps the full result)",
        },
        new FormulaDef
        {
            Name = "volts_5v_word", Expr = "x * 5 / 1023", Inverse = "x * 1023 / 5", Unit = "V", Decimals = 3,
            Notes = "10-bit ADC result as sensor volts",
        },
        new FormulaDef
        {
            Name = "ms_per_count", Expr = "x / 1000", Inverse = "x * 1000", Unit = "ms", Decimals = 3,
            Notes = "PLACEHOLDER for injector timing in microsecond counts - confirm the tick rate with xref",
        },
    ];
}

// ---------------------------------------------------------------- ROM access

public sealed record CellValue(int Address, double Raw, double Value, string Display);

public static class RomData
{
    public static (double min, double max) RawRange(CellType t) => t switch
    {
        CellType.S8 => (-128, 127),
        CellType.U16 or CellType.U16BE => (0, 65535),
        CellType.S16 or CellType.S16BE => (-32768, 32767),
        CellType.Bit => (0, 1),
        _ => (0, 255),
    };

    public static double ReadRaw(byte[] rom, int addr, CellType t, int bit = 0) => t switch
    {
        CellType.U8 => rom[addr],
        CellType.S8 => (sbyte)rom[addr],
        CellType.U16 => (ushort)(rom[addr] | (rom[addr + 1] << 8)),
        CellType.S16 => (short)(rom[addr] | (rom[addr + 1] << 8)),
        CellType.U16BE => (ushort)((rom[addr] << 8) | rom[addr + 1]),
        CellType.S16BE => (short)((rom[addr] << 8) | rom[addr + 1]),
        CellType.Bit => (rom[addr] >> bit) & 1,
        _ => rom[addr],
    };

    public static void WriteRaw(byte[] rom, int addr, CellType t, double raw, int bit = 0)
    {
        int v = (int)Math.Round(raw, MidpointRounding.AwayFromZero);
        switch (t)
        {
            case CellType.U8: case CellType.S8: rom[addr] = (byte)v; break;
            case CellType.U16: case CellType.S16: rom[addr] = (byte)v; rom[addr + 1] = (byte)(v >> 8); break;
            case CellType.U16BE: case CellType.S16BE: rom[addr] = (byte)(v >> 8); rom[addr + 1] = (byte)v; break;
            case CellType.Bit: rom[addr] = (byte)(v != 0 ? rom[addr] | (1 << bit) : rom[addr] & ~(1 << bit)); break;
        }
    }

    static double Multiplier(byte[] rom, ItemDef item, int index) =>
        item.ColumnScaleAddress is int m && item.IsTable ? Math.Max(1, (int)rom[(m + (index % item.Cols)) & (rom.Length - 1)]) : 1;

    public static CellValue[] Read(DefinitionSet defs, byte[] rom, ItemDef item)
    {
        var f = defs.Formula(item.Formula);
        var result = new CellValue[item.Count];
        for (int i = 0; i < item.Count; i++)
        {
            int a = item.CellAddress(i);
            if (a < 0 || a + item.ElementSize > rom.Length) { result[i] = new CellValue(a, 0, 0, "?"); continue; }
            double raw = ReadRaw(rom, a, item.Type, item.Bit);
            double eff = raw * Multiplier(rom, item, i);
            result[i] = new CellValue(a, raw, f.ToValue(eff), f.Format(eff));
        }
        return result;
    }

    public static void Write(DefinitionSet defs, byte[] rom, ItemDef item, int index, double value)
    {
        var f = defs.Formula(item.Formula);
        var (lo, hi) = RawRange(item.Type);
        if (item.Min is double min && value < min) value = min;
        if (item.Max is double max && value > max) value = max;
        double mult = Multiplier(rom, item, index);
        double raw = mult == 1 ? f.ToRaw(value, lo, hi) : Math.Clamp(Math.Round(f.ToRaw(value, lo * mult, hi * mult) / mult), lo, hi);
        WriteRaw(rom, item.CellAddress(index), item.Type, raw, item.Bit);
    }

    /// Write a raw cell value (no formula), clamped to the type's range.
    public static void WriteRawCell(byte[] rom, ItemDef item, int index, double raw)
    {
        var (lo, hi) = RawRange(item.Type);
        WriteRaw(rom, item.CellAddress(index), item.Type, Math.Clamp(Math.Round(raw), lo, hi), item.Bit);
    }

    public static double[] AxisValues(DefinitionSet defs, byte[] rom, AxisDef? axis, int count)
    {
        if (axis?.Values is { Length: > 0 } v) return v;
        if (axis?.Address is not int addr) return [.. Enumerable.Range(0, count).Select(i => (double)i)];
        var f = defs.Formula(axis.Formula);
        int size = axis.Type is CellType.U16 or CellType.S16 or CellType.U16BE or CellType.S16BE ? 2 : 1;
        var result = new double[count];
        var raws = new double[count];
        for (int i = 0; i < count; i++)
        {
            int a = addr + (i * (axis.Stride > 0 ? axis.Stride : size));
            raws[i] = (axis.Count > 0 && i >= axis.Count) || a < 0 || a + size > rom.Length ? double.NaN : ReadRaw(rom, a, axis.Type);
        }
        // Honda byte axes that climb end on 00 meaning 256 (one past FF); the (x, y) lists that fall from FF end on a real 00
        bool falling = count > 1 && raws[1] < raws[0];
        for (int i = 0; i < count; i++)
        {
            double raw = raws[i];
            if (double.IsNaN(raw)) { result[i] = double.NaN; continue; }
            if (!falling && size == 1 && i > 0 && raw == 0 && axis.Type == CellType.U8) raw = 256;
            result[i] = f.ToValue(raw);
        }
        return result;
    }

    /// Render a table (or a scalar) as text, with axes when they are defined.
    public static string Render(DefinitionSet defs, byte[] rom, ItemDef item)
    {
        var cells = Read(defs, rom, item);
        var f = defs.Formula(item.Formula);
        var sb = new StringBuilder();
        sb.AppendLine($"{item.Name}  @ 0x{item.Address:X4}  {(item.IsTable ? $"{item.Rows}x{item.Cols} " : "")}{item.Type.ToString().ToLowerInvariant()}  [{f.Name}{(f.Unit.Length > 0 ? " " + f.Unit : "")}]");
        if (item.Description.Length > 0) sb.AppendLine("  " + item.Description);
        if (!item.IsTable)
        {
            sb.AppendLine($"  value {cells[0].Display}   (raw {(long)cells[0].Raw} = 0x{(long)cells[0].Raw:X})");
            return sb.ToString();
        }
        var cols = AxisValues(defs, rom, item.ColAxis, item.Cols);
        var rows = AxisValues(defs, rom, item.RowAxis, item.Rows);
        sb.Append("        ");
        for (int c = 0; c < item.Cols; c++) sb.Append($"{cols[c],8:0.##}");
        sb.AppendLine($"   <- {item.ColAxis?.Name ?? "column"}{(item.ColAxis?.Unit.Length > 0 ? " (" + item.ColAxis.Unit + ")" : "")}");
        for (int r = 0; r < item.Rows; r++)
        {
            sb.Append($"{rows[r],8:0.##}");
            for (int c = 0; c < item.Cols; c++) sb.Append($"{cells[(r * item.Cols) + c].Value,8:0.##}");
            sb.AppendLine();
        }
        if (item.RowAxis != null) sb.AppendLine($"   ^ rows: {item.RowAxis.Name ?? "row"}{(item.RowAxis.Unit.Length > 0 ? " (" + item.RowAxis.Unit + ")" : "")}");
        return sb.ToString();
    }
}
