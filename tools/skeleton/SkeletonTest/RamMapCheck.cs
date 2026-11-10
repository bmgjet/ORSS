using OkiRomSim.Calibration;

/// `--rammap`: what the memory map names in a skeleton build with the datalog, and the values it reads.
static class RamMapCheck
{
    public static int Run(Skeleton sk)
    {
        int bad = 0;
        void Check(bool ok, string what) { Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {what}"); if (!ok) bad++; }
        var b = sk.Build(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE", "FEAT_STOCK_DTC"]);
        var defs = DefinitionBuilder.FromAssembly(b.Assembly!, "skeleton");
        defs.MergeBuiltinFormulas();
        var map = RamMap.Build(defs, b.Assembly, b.Assembly!.Image);
        Console.WriteLine($"{map.Count} RAM bytes named");
        foreach (var e in map.Where(e => e.Size > 0).Take(400)) Console.WriteLine($"  {e.Address:X3}h {e.Size} {e.Name,-44} {e.Formula,-16} {e.Source}");
        RamEntry? At(int a) => map.FirstOrDefault(e => e.Address == a);
        // the P13 keeps the same readings in its own RAM (its frame table says where)
        int period = Platform.P13 ? 0x0AE : 0x0AC, ect = Platform.P13 ? 0x0D9 : 0x0C1, inj = Platform.P13 ? 0x1D0 : 0x146;
        Check(At(period) is { Size: 2, Formula: "rpm_period_word" }, $"{period:X3}h: the crank period, a word, as rpm");
        Check(At(ect)?.Formula == "honda_temp_c", $"{ect:X3}h: coolant, through the thermistor curve");
        Check(At(inj)?.Formula == "inj_ms_word", $"{inj:X3}h: injector time in ms");
        if (!Platform.P13)
        {
            Check(At(0x23B)?.Name.StartsWith("IgnitionRpmCorrection") == true, $"23Bh: a table's result ({At(0x23B)?.Name})");
            Check(At(0x2FF)?.Name == "DL_SVC", "2FFh: the source's name (DL_SVC)");
        }
        else Check(At(0x1BD)?.Name == "DL_SVC", "1BDh: the source's name (DL_SVC)");
        var ram = new byte[RamMap.RamEnd];
        ram[period] = 0x71; ram[period + 1] = 0x02;       // 625: 3000 rpm
        ram[ect] = 0x30;
        if (At(period) is { } pe)
        {
            var (_, rpm) = RamMap.Read(defs, pe, ram);
            Check(rpm.StartsWith("3000"), $"the period 0271h reads {rpm}");
            Check(RamMap.ToRaw(defs, pe, 3000) is int r && Math.Abs(r - 625) <= 1, "3000 rpm writes back as 625");
        }
        return bad;
    }
}
