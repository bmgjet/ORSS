// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;

namespace OkiRomSim.Calibration;

/// What each byte of RAM holds, so the memory map can name it and show its value in real units: from what the ROM and its source say, best first. 1. A definition at a RAM address (a ";@" line, or one added on the Calibration page): its name, type and formula. 2. The ROM's datalog frame table (the skeleton's dl_frame_table, HTS's serial_c0_table): each frame byte is a known reading (coolant, MAP, the crank period...) with the formula the loggers use for it. 3. A table whose description names the RAM its result goes to ("(RAM 23Bh)"): the result, in the table's units. 4. The source's own names (EQU) for RAM, and the chip's SFR names.
public sealed record RamEntry(int Address, int Size, string Name, string? Formula, string Unit, string Source, string Description = "");

public static partial class RamMap
{
    /// The end of RAM on the chips here: above it is ROM.
    public const int RamEnd = 0x480;

    // the 51-byte frame's fields (HondaDatalog.Decode): byte index -> name, formula, size, unit
    static readonly Dictionary<int, (string Name, string Formula, int Size, string Unit)> FrameFields = new()
    {
        [0] = ("Coolant temperature", "honda_temp_c", 1, "°C"),
        [1] = ("Intake air temperature", "honda_temp_c", 1, "°C"),
        [2] = ("O2 sensor", "volts_5v_byte", 1, "V"),
        [3] = ("Barometric pressure", "x", 1, ""),
        [4] = ("Manifold pressure (MAP)", "map_kpa", 1, "kPa"),
        [5] = ("Throttle position", "tps_pct", 1, "%"),
        [6] = ("Engine speed (crank period)", "rpm_period_word", 2, "rpm"),
        [16] = ("Road speed", "speed_kmh_byte", 1, "km/h"),
        [17] = ("Injector time", "inj_ms_word", 2, "ms"),
        [19] = ("Ignition advance", "ign_advance", 1, "°"),
        [20] = ("Ignition advance (the map's)", "ign_advance", 1, "°"),
        [25] = ("Battery voltage", "battery_v", 1, "V"),
        [12] = ("Stored trouble codes 1-8", "x", 1, ""),
        [13] = ("Stored trouble codes 9-16", "x", 1, ""),
        [14] = ("Stored trouble codes 17-24", "x", 1, ""),
        [15] = ("Stored trouble codes 25+", "x", 1, ""),
    };

    [GeneratedRegex(@"\bRAM ([0-9A-Fa-f]{2,3})h\b")] private static partial Regex RamMention();

    public static List<RamEntry> Build(DefinitionSet defs, AssemblyResult? asm, byte[] rom)
    {
        var map = new Dictionary<int, RamEntry>();
        void Add(RamEntry e)
        {
            if (e.Address < 0 || e.Address >= RamEnd || map.ContainsKey(e.Address)) return;
            map[e.Address] = e;
            if (e.Size == 2 && !map.ContainsKey(e.Address + 1))
                map[e.Address + 1] = e with { Address = e.Address + 1, Size = 0, Name = e.Name + " (high byte)" };
        }
        // 1. definitions at RAM addresses
        foreach (var i in defs.Items.Where(i => i.Address < RamEnd && i.Text == null && !i.IsTable))
            Add(new RamEntry(i.Address, i.ElementSize, i.Name, i.Formula, Unit(defs, i.Formula), "definition", i.Description));
        // 2. the datalog frame table
        if (asm != null) FromFrameTable(asm, rom).ForEach(Add);
        // 3. tables whose result goes to a RAM byte
        foreach (var i in defs.Items.Where(i => i.IsTable && i.Description.Length > 0))
            foreach (Match m in RamMention().Matches(i.Description))
            {
                int a = int.Parse(m.Groups[1].Value, NumberStyles.HexNumber);
                if (a >= 0x80) Add(new RamEntry(a, 1, i.Name + " (its result)", i.Formula, Unit(defs, i.Formula), "a table's result", $"Looked up from {i.Name}: {i.Description}"));
            }
        // 4. the source's names for RAM, and the SFRs
        if (asm != null)
            foreach (var s in asm.Symbols.Values.Where(s => s.Kind is SymbolKind.Equate or SymbolKind.Sfr).OrderBy(s => s.Kind == SymbolKind.Sfr))
            {
                if (s.Value < 0 || s.Value >= RamEnd) continue;
                if (s.Kind == SymbolKind.Equate && (s.Value < 0x80 || Constant().IsMatch(s.Name))) continue;
                Add(new RamEntry((int)s.Value, 1, s.Name, null, "", s.Kind == SymbolKind.Sfr ? "SFR" : "source name",
                    s.File != null ? $"{Path.GetFileName(s.File)}:{s.Line}" : ""));
            }
        return [.. map.Values.OrderBy(e => e.Address)];
    }

    // names in the source that are numbers, not RAM (tick slots, module bits, counts, builds points)
    [GeneratedRegex(@"^(XP_|SLOT_|MB_|MAP_COLS|DL_NCH|DLSVC_SLOT|MOD_RAM_END|.*_COUNT$|.*_SIZE$)", RegexOptions.IgnoreCase)] private static partial Regex Constant();

    static string Unit(DefinitionSet defs, string? formula)
    {
        try { return formula == null ? "" : defs.Formula(formula).Unit; } catch { return ""; }
    }

    /// The ROM's datalog frame table read into RAM entries: the skeleton's dl_frame_table (a word per frame byte), or HTS's serial_c0_table (a word per reading, 8000h set for a two-byte one).
    static List<RamEntry> FromFrameTable(AssemblyResult asm, byte[] rom)
    {
        var list = new List<RamEntry>();
        long? At(string n) => asm.Symbols.Values.FirstOrDefault(s => s.Name.Equals(n, StringComparison.OrdinalIgnoreCase) && s.Kind == SymbolKind.Label)?.Value;
        int W(long a) => rom[(int)a & 0x7FFF] | (rom[((int)a + 1) & 0x7FFF] << 8);
        if (At("dl_frame_table") is long sk)
        {
            for (int k = 0; k < HondaDatalog.FrameLength; k++)
            {
                if (!FrameFields.TryGetValue(k, out var f)) continue;
                int a = W(sk + (k * 2));
                if (a is 0 or >= 0xFE00) continue;
                list.Add(new RamEntry(a, f.Size, f.Name, f.Formula, f.Unit, "datalog frame", $"Byte {k} of the 51-byte datalog frame."));
            }
        }
        else if (At("serial_c0_table") is long hts)
        {
            int frame = 0;
            for (int k = 0; k < 46 && frame < HondaDatalog.FrameLength; k++)
            {
                int w = W(hts + (k * 2));
                bool word = (w & 0x8000) != 0;
                int a = w & 0x7FFF;
                if (FrameFields.TryGetValue(frame, out var f) && a < RamEnd)
                    list.Add(new RamEntry(a, f.Size, f.Name, f.Formula, f.Unit, "datalog frame", $"Byte {frame} of the 51-byte datalog frame."));
                frame += word ? 2 : 1;
            }
        }
        return list;
    }

    /// The value of an entry from the RAM bytes, through its formula; the raw number when it has none.
    public static (double Raw, string Text) Read(DefinitionSet defs, RamEntry e, ReadOnlySpan<byte> ram)
    {
        int raw = e.Size >= 2 ? ram[e.Address] | (ram[e.Address + 1] << 8) : ram[e.Address];
        if (e.Formula is not { Length: > 0 } f || f is "x" or "raw") return (raw, "");
        try
        {
            var fd = defs.Formula(f);
            return (raw, fd.ToValue(raw).ToString("F" + Math.Clamp(fd.Decimals, 0, 4), CultureInfo.InvariantCulture) + (fd.Unit.Length > 0 ? " " + fd.Unit : ""));
        }
        catch { return (raw, ""); }
    }

    /// The raw number for a value in real units (the formula's inverse), or null when it cannot be worked out.
    public static int? ToRaw(DefinitionSet defs, RamEntry e, double value)
    {
        int max = e.Size >= 2 ? 0xFFFF : 0xFF;
        if (e.Formula is not { Length: > 0 } f || f is "x" or "raw") return (int)Math.Clamp(Math.Round(value), 0, max);
        try { return (int)Math.Round(defs.Formula(f).ToRaw(value, 0, max)); } catch { return null; }
    }
}
