using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

/// One check per module behaviour: the module switched on through its calibration, against the same run with it off.
static class Tests
{
    public delegate (double, Action<EngineState, double>) HoldFn(double secs, Action<EngineState> set);

    static RunFn RunRaw = null!;
    /// A run that starts at idle for 3 s (the ROM only starts from idle), then the steps given.
    static RunResult Run(string[] defs, Dictionary<string, byte[]> cal, IEnumerable<(double Secs, Action<EngineState, double> Set)> steps, Action<Simulator>? watch = null, double ect = 85)
        => RunRaw(defs, cal, [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0; e.EctCelsius = ect; }), .. steps], watch);
    static Action<string, bool, string> Check = null!;
    static HoldFn Hold = null!;

    static byte[] B(params int[] v) => [.. v.Select(x => (byte)x)];
    static byte[] W(int v) => [(byte)v, (byte)(v >> 8)];
    /// A crank period word for an rpm (rpm = 1875000 / period), the unit the ROM compares against.
    static int P(double rpm) => (int)Math.Round(1875000 / rpm);

    public static void Register(Skeleton sk, RunFn run, Action<string, bool, string> check, Func<string, bool> wanted, HoldFn hold)
    {
        RunRaw = run; Check = check; Hold = hold;
        foreach (var m in typeof(Tests).GetMethods(System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)
                     .Where(m => m.Name.StartsWith("Test_")))
        {
            var define = "FEAT_" + m.Name[5..].ToUpperInvariant();
            if (sk.Feature(define) == null || !wanted(define)) continue;
            Console.WriteLine($"{define}: {sk.Feature(define)!.Name}");
            try { m.Invoke(null, null); }
            catch (System.Reflection.TargetInvocationException ex) when (Platform.P13)
            {
                // (porting to the P13: one module that does not build yet does not stop the others' checks)
                Check("runs at all", false, (ex.InnerException?.Message ?? ex.Message).Split('\n')[0]);
            }
        }
    }

    // ------------------------------------------------------------------ datalog
    // ------------------------------------------------------------------ datalog: every channel
    static void Test_Dlextra()
    {
        // the functions' own state (module RAM, channels 132-187): rolling idle's dropped injectors come through, named from the build
        {
            var ri = Run(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLEXTRA", "FEAT_ROLLIDLE"], new() { ["rollidle_enable"] = B(1), ["rollidle_every"] = B(5) },
                         [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0; })]);
            ModuleDebug.Name(ri.Asm.Symbols.Values.Where(sy => sy.Kind is SymbolKind.Equate or SymbolKind.Define).Select(sy => (sy.Name, (long)sy.Value)));
            var named = ModuleDebug.Variables.Select(v => v.Name).ToList();
            ChannelStream.Selected = [.. DatalogChannels.Defaults, .. Enumerable.Range(0, ModuleDebug.Bytes).Select(i => $"mod{i}:slow")];
            var lk = new DatalogLayout.SimLink(ri.Sim);
            var cs = new ChannelStream { PostWritePauseMs = 0 };
            bool ok = cs.Handshake(lk, out var hn);
            var seen = new Dictionary<string, double>();
            for (int i = 0; i < 900 && ok && !(seen.ContainsKey("rollidle_injectors") && seen.ContainsKey("rollidle_drops")); i++)
                if (cs.Poll(lk, i * 0.01, out _) is { } f) foreach (var c in f.Channels()) if (f.Get(c) is double v) seen[c] = v;
            Check("the functions' state: rolling idle's dropped injectors and their count come through the stream, named from the build",
                  named.Contains("rollidle_cyl") && seen.GetValueOrDefault("rollidle_injectors") > 0 && seen.GetValueOrDefault("rollidle_drops") > 0,
                  $"{hn}; names {string.Join(",", named)}; injectors {seen.GetValueOrDefault("rollidle_injectors")}, drops {seen.GetValueOrDefault("rollidle_drops")}");
            lk.Write([0x00]); lk.Discard();
        }
        // at a fuel-cut rev limit of 4000 rpm, held at 4500, with RAM address 1 set to the road speed (0B4h)
        var cal = new Dictionary<string, byte[]>
        {
            ["revlimit_low"] = B(1), ["revlimit_cut"] = B(0), ["revlimit_low_set"] = W(P(4000)), ["revlimit_low_reset"] = W(P(3900)),
            ["dlx_user"] = B(Platform.A(0xB4), 0x00),
        };
        var r = Run(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLEXTRA", "FEAT_REVLIMIT"], cal, [Hold(2, e => { e.Rpm = 4500; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = 72; })]);
        var table = r.Asm.Symbols.Values.First(s => s.Name.Equals("dl_channels", StringComparison.OrdinalIgnoreCase)).Value;
        var off = new List<string>();
        for (int i = 0; i < DatalogChannels.TableSizeAll; i++)
        {
            int rom = r.Asm.Image[table + (i * 2)] | (r.Asm.Image[table + (i * 2) + 1] << 8), app = DatalogChannels.RomTable[i];
            if (rom < 0xFE00) rom &= ~0x6000;
            if (app != 0 && rom != 0 && rom != app && (rom & 0xFF00) != 0xFF00 && !(i is 23 or 24)) off.Add($"{i}: ROM {rom:X3}h, app {app:X3}h");
        }
        Check("the app's table matches the ROM's, all 132 channels", off.Count == 0, string.Join("; ", off));
        var link = new DatalogLayout.SimLink(r.Sim);
        // a few picks past the old table, the rest the usual ones: they must come in the frames too
        ChannelStream.Selected = [.. DatalogChannels.Defaults, "cuts", "limiters"];
        {
            var p0 = new ChannelStream { PostWritePauseMs = 0 };
            bool hs0 = p0.Handshake(link, out var note0);
            LogFrame? f0 = null;
            for (int i = 0; i < 40 && hs0 && f0?.Get("limit_revlimit") == null; i++) f0 = p0.Poll(link, i * 0.01, out _) ?? f0;
            Check("the defaults and the rev limit: rev_limit, fuel_cut and limit_revlimit come in the frames", f0?.Get("rev_limit") == 1 && f0?.Get("limit_revlimit") == 1 && f0?.Get("fuel_cut") == 1,
                  $"{note0}; {string.Join(",", f0?.Channels() ?? [])}");
            link.Write([0x00]); link.Discard();
        }
        ChannelStream.Selected = DatalogChannels.Everything(DatalogChannels.TableSizeAll);
        // RAM address 1 is named for what the memory map says is there
        UserRam.Set(0, Platform.A(0xB4), "Road speed");
        string spk = $"ram_{Platform.A(0xB4):x3}_road_speed";
        try
        {
            var p = new ChannelStream { PostWritePauseMs = 0 };
            bool hs = p.Handshake(link, out var note);
            Check("everything: the ident says 188 channels and the slow range; the stream starts", hs && p.Picks.Count > 80, $"{note}; {p.Picks.Count} picks");
            var last = new Dictionary<string, double>();
            int frames = 0;
            for (int i = 0; i < 600 && hs; i++)
                if (p.Poll(link, i * 0.01, out _) is { } f)
                {
                    frames++;
                    foreach (var k in new[] { "rev_limit", "limit_revlimit", "fuel_cut", spk, "idle_target_rpm", "board_options2", "opt_vtec_pressure_switch", "cranking", "since_start_s", "dead_time_ms", "rpm_index_rpm" })
                        if (f.Get(k) is double v) last[k] = v;
                }
            string Got(string k) => last.TryGetValue(k, out var v) ? v.ToString("0.###") : "-";
            Check("  at the rev limiter: rev_limit and limit_revlimit are on, fuel cut", Got("rev_limit") == "1" && Got("limit_revlimit") == "1" && Got("fuel_cut") == "1",
                  $"{frames} frames; rev_limit {Got("rev_limit")}, limit_revlimit {Got("limit_revlimit")}, fuel_cut {Got("fuel_cut")}");
            Check($"  RAM address 1 ({Platform.A(0xB4):X3}h, road speed) reads the speed, logged as {spk}", last.TryGetValue(spk, out var sp) && Math.Abs(sp - 72) <= 2, Got(spk));
            Check("  the far slow channels come round, flag bits by name: idle target, board options 2 (227h), cranking, time since start, dead time, rpm index",
                  // P13: only time since start and the dead time are traced of these (the rest send 00h)
                  (Platform.P13 || (last.ContainsKey("board_options2") && last.ContainsKey("opt_vtec_pressure_switch") && last.ContainsKey("cranking") && last.TryGetValue("idle_target_rpm", out var it) && it is > 400 and < 3000
                  && last.TryGetValue("rpm_index_rpm", out var ri) && Math.Abs(ri - 4500) < 300))
                  && last.ContainsKey("since_start_s") && last.TryGetValue("dead_time_ms", out var dt) && dt is > 0.1 and < 3,
                  string.Join(", ", last.Select(kv => $"{kv.Key} {kv.Value:0.###}")));
        }
        finally { ChannelStream.Selected = DatalogChannels.Defaults; }
    }

    static void Test_Datalog()
    {
        var r = Run(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE"], [], [Hold(1, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; e.SpeedKmh = 90; e.EctCelsius = 85; })]);
        var link = new DatalogLayout.SimLink(r.Sim);
        var (p, report) = DatalogProtocol.Detect(link);
        Check("auto-detect finds the channel stream", p?.Name == "Channel stream", p?.Name ?? report.Split('\n').FirstOrDefault() ?? "");
        if (p == null)
        {
            var dbg = new ChannelStream { PostWritePauseMs = 0 };
            dbg.Handshake(link, out var dn);
            var got = new byte[64];
            int n = link.Read(got, 0, 64, 30);
            Console.WriteLine($"    debug: {dn}; {n} bytes after 71h: {string.Join(" ", got.Take(n).Select(x => x.ToString("X2")))}; state {r.Sim.State}, pc {r.Sim.Cpu.Pc:X4} near {r.Asm.Symbols.Values.Where(s => s.Value <= r.Sim.Cpu.Pc && s.Value > r.Sim.Cpu.Pc - 0x300).OrderByDescending(s => s.Value).Select(s => $"{s.Name}+{r.Sim.Cpu.Pc - s.Value:X}").FirstOrDefault()} fault {r.Sim.FaultMessage}");
            return;
        }
        var frames = new List<LogFrame>();
        for (int i = 0; i < 40; i++) if (p.Poll(link, i * 0.01, out _) is { } f) frames.Add(f);
        var last = frames.LastOrDefault();
        Check("streams frames", frames.Count >= 35, $"{frames.Count} of 40 polls");
        Check("  rpm, MAP, speed and coolant read right", last != null && Math.Abs(last.Rpm!.Value - 3000) < 60 && Math.Abs(last.MapKpa!.Value - 60) < 4
              && Math.Abs(last.SpeedKmh!.Value - 90) < 4 && Math.Abs(last.EctC!.Value - 85) < 4,
              last == null ? "" : $"{last.Rpm} rpm, {last.MapKpa} kPa, {last.SpeedKmh} km/h, {last.EctC} C");
        Check("  no frame lost", ((ChannelStream)p).Lost == 0, $"{((ChannelStream)p).Lost} lost");
        var ticks = frames.Select(f => f.Get("ecu_tick_ms") ?? 0).ToList();
        Check("  the ECU's tick moves on frame to frame", ticks.Zip(ticks.Skip(1)).All(t => t.Second >= t.First || t.First > 130000), $"{ticks.First():0} .. {ticks.Last():0} ms");
        Check("  version 4: the ident says so, and the defaults' coolant, intake air and battery come in turn (slow)",
              ((ChannelStream)p).Version == 4 && ((ChannelStream)p).Picks.Count(x => x.Slow) == 3 && last?.EctC is > 80 and < 90 && last.IatC is > 15 and < 35 && last.BattV is > 12 and < 15,
              last == null ? "" : $"version {((ChannelStream)p).Version}; {last.EctC} C, {last.IatC} C, {last.BattV} V");
        // every fast channel in every frame: 12 channels (15 bytes), status bytes included
        ChannelStream.Selected = ["rpm", "map", "tps", "ect", "speed", "inj", "adv", "pump", "switches", "iacv", "load", "batt"];
        try
        {
            var p2 = new ChannelStream();
            bool hs = p2.Handshake(link, out var hsNote);
            var fr = new List<LogFrame>();
            for (int i = 0; i < 40; i++) if (p2.Poll(link, i * 0.01, out _) is { } f2) fr.Add(f2);
            var l2 = fr.LastOrDefault();
            Check("12 channels (15 bytes) every frame, streamed", hs && p2.Streaming.Count == 12 && fr.Count >= 15 && fr[^1].Raw!.Length == 19, $"{hsNote}; {fr.Count} frames of {fr.LastOrDefault()?.Raw?.Length} bytes");
            Check("  rpm, MAP, speed, injector time, advance, fuel pump and load decode", l2 != null && Math.Abs(l2.Rpm!.Value - 3000) < 60 && Math.Abs(l2.MapKpa!.Value - 60) < 4
                  && Math.Abs(l2.SpeedKmh!.Value - 90) < 4 && l2.InjMs > 0.5 && l2.IgnDeg is > 0 and < 50 && l2.FuelPump == true && l2.Get("load_mbar") is > 450 and < 750,
                  l2 == null ? "" : $"{l2.Rpm} rpm, {l2.MapKpa} kPa, {l2.SpeedKmh} km/h, {l2.InjMs} ms, {l2.IgnDeg} deg, pump {l2.FuelPump}, load {l2.Get("load_mbar")} mbar; raw {string.Join(" ", l2.Raw!.Select(x => x.ToString("X2")))}");
            // fast and slow: the frame short, the slow ones all heard within their turn, as fast as the line goes
            ChannelStream.Selected = ["rpm", "map", "tps", "speed", "ect:slow", "iat:slow", "batt:slow", "codes:slow", "switches:slow", "pump:slow"];
            var p3 = new ChannelStream();
            bool hs3 = p3.Handshake(link, out var n3);
            var f3 = new List<LogFrame>();
            for (int i = 0; i < 80; i++) if (p3.Poll(link, i * 0.01, out _) is { } x) f3.Add(x);
            var l3 = f3.LastOrDefault();
            // the line itself: every frame the ECU sends in half a second
            link.Discard(); link.Run(0.5);
            var raw = new byte[8192];
            int rn = link.Read(raw, 0, raw.Length, 1), whole = 0;
            for (int i = 0; i + 11 <= rn; i++) if (raw[i] == 0xA5 && (raw.Skip(i).Take(11).Sum(b => b) & 0xFF) == 0) { whole++; i += 10; }
            double fps = whole / 0.5;
            Check("fast and slow (the short list, 75h): 5 fast bytes and one slow a frame (11 bytes), every slow one heard, 25+ frames a second (8 bytes a spark calculation at cruise: the byte budget)",
                  hs3 && n3.Contains("version 4") && l3 != null && l3.Raw!.Length == 11 && l3.EctC is > 80 and < 90 && l3.BattV is > 12 and < 15 && l3.Get("dtc0") != null && l3.Get("brake") != null
                  && l3.FuelPump != null && Math.Abs(l3.Rpm!.Value - 3000) < 60 && fps > 25 && p3.Lost == 0,
                  $"{n3}; {l3?.Raw?.Length} bytes, {fps:0} frames/s, {p3.Lost} lost; {l3?.EctC} C, {l3?.BattV} V");
            // a word read in one go: rpm followed across a crank period's 256 boundary (3662 rpm: 0200h) frame by frame
            ChannelStream.Selected = ["rpm", "map", "inj", "iacv", "ect:slow"];
            var p4 = new ChannelStream();
            p4.Handshake(link, out _);
            var r4 = new List<(double Want, double Got)>();
            for (int i = 0; i < 200; i++)
            {
                double want = 3000 + (i * 5);
                r.Sim.Engine.Rpm = want; r.Sim.SyncSensors();
                if (p4.Poll(link, i * 0.01, out _) is { } x && x.Rpm is double got) r4.Add((want, got));
            }
            double worstJump = r4.Zip(r4.Skip(1)).Select(z => Math.Abs(z.Second.Got - z.First.Got)).DefaultIfEmpty(9999).Max();
            Check("  a word's two bytes are one reading: rpm across 0200h moves smoothly", r4.Count > 100 && worstJump < 150 && Math.Abs(r4[^1].Got - r4[^1].Want) < 80,
                  $"{r4.Count} frames, biggest step {worstJump:0} rpm, {r4.FirstOrDefault().Got:0} .. {r4.LastOrDefault().Got:0}");
            r.Sim.Engine.Rpm = 3000; r.Sim.SyncSensors();
            // channel numbers past the table and slow-only lists are fine; a bad checksum is refused
            link.Write([0x00]); link.Wait(20); link.Discard();
            var bad = new byte[] { 0x74, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x55 };
            foreach (var b in bad) { link.Write([b]); link.Wait(1); }
            var ans = new byte[1];
            Check("  a mask with a bad checksum: refused (7Fh)", link.Read(ans, 0, 1, 200) == 1 && ans[0] == 0x7F, $"{ans[0]:X2}");
            // an older logger: the 73h list and its frame (A5h, seq, tick, bytes, checksum)
            link.Discard();
            byte[] ids = [0x73, 3, 0, 1, 2];
            byte[] l73 = [.. ids, (byte)-ids.Skip(1).Sum(b => b)];
            foreach (var b in l73) { link.Write([b]); link.Wait(1); }
            bool took = link.Read(ans, 0, 1, 200) == 1 && ans[0] == 0x70;
            link.Write([0x72]);
            var one = new byte[8];
            int got3 = 0;
            while (got3 < 8 && link.Read(one, got3, 8 - got3, 200) is var k && k > 0) got3 += k;
            int period = one[4] | (one[5] << 8);
            Check("an older logger's 73h list: taken (70h), one frame (72h) of A5h, seq, tick, 3 bytes, checksum",
                  took && got3 == 8 && one[0] == 0xA5 && (one.Sum(b => b) & 0xFF) == 0 && Math.Abs(1875000.0 / Math.Max(1, period) - 3000) < 60,
                  $"{(took ? "70" : ans[0].ToString("X2"))}; {string.Join(" ", one.Take(got3).Select(b => b.ToString("X2")))}");
        }
        finally { ChannelStream.Selected = DatalogChannels.Defaults; }
        // the app's channel table is the ROM's
        var table = r.Asm.Symbols.Values.First(s => s.Name.Equals("dl_channels", StringComparison.OrdinalIgnoreCase)).Value;
        var off = new List<string>();
        for (int i = 0; i < DatalogChannels.TableSize; i++)
        {
            int rom = r.Asm.Image[table + (i * 2)] | (r.Asm.Image[table + (i * 2) + 1] << 8), app = DatalogChannels.RomTable[i];
            if (rom < 0xFE00) rom &= ~0x6000;
            if (app != 0 && rom != 0 && rom != app && (rom & 0xFF00) != 0xFF00 && !(i is 23 or 24)) off.Add($"{i}: ROM {rom:X3}h, app {app:X3}h");
        }
        Check("the app's channel table matches the ROM's (53 channels)", off.Count == 0 && DatalogChannels.RomTable.Length == DatalogChannels.TableSizeAll, string.Join("; ", off));
        // the older loggers still work on the same ROM, the rpm (two bytes of the frame) one reading
        var hts = new MultiByte20Probe().Try(link);
        Check("the HTS 10h/20h frame still answers", hts, "");
        link.Write([0x20]);
        var hf = new byte[52]; int hn = 0;
        while (hn < 52 && link.Read(hf, hn, 52 - hn, 300) is var hk && hk > 0) hn += hk;
        var hd = hn == 52 ? HondaDatalog.Decode(hf[..51], 0) : null;
        Check("  its rpm and injector time read right", hd != null && Math.Abs(hd.Rpm!.Value - 3000) < 60 && hd.InjMs > 0.5, hd == null ? $"{hn} bytes" : $"{hd.Rpm} rpm, {hd.InjMs} ms");
        // for comparison: a 73h list of the same 7 bytes (an older logger), its frames a second and its interrupt time
        {
            link.Write([0x00]); link.Wait(20); link.Discard();
            byte[] ids7 = [0x73, 7, 0, 1, 2, 3, 4, 5, 6];
            byte[] l7 = [.. ids7, (byte)-ids7.Skip(1).Sum(b => b)];
            foreach (var b in l7) { link.Write([b]); link.Wait(1); }
            link.Read(new byte[1], 0, 1, 200);
            link.Write([0x71]); link.Wait(5);
            var w3 = IsrWorst(r.Sim, r.Asm, 0.5);
            r.Sim.Bus.TakeSerialTx();
            link.Discard(); link.Run(0.5);
            var raw3 = new byte[8192];
            int rn3 = link.Read(raw3, 0, raw3.Length, 1), whole3 = 0;
            for (int i = 0; i + 12 <= rn3; i++) if (raw3[i] == 0xA5 && (raw3.Skip(i).Take(12).Sum(b => b) & 0xFF) == 0) { whole3++; i += 11; }
            Console.WriteLine($"    (73h list of 7 bytes: {whole3 * 2} frames a second of 12 bytes, serial interrupt worst {w3.Where(w => w.Key.Contains("serial")).Select(w => w.Value).DefaultIfEmpty(0).Max():0} us)");
            link.Write([0x00]); link.Wait(20); link.Discard();
        }
        // the stream's own interrupt time: the short list, and the masks (19 channel bytes, sparse: channel 52 and slow 40 among them)
        double SerialWorst(string[] picks, bool masks, out string note)
        {
            ChannelStream.Selected = picks;
            var p5 = new ChannelStream();
            p5.Handshake(link, out note);
            var worst = IsrWorst(r.Sim, r.Asm, 0.5);
            note += $"; masks {p5.Masks}; " + string.Join(", ", worst.Where(w => w.Key.Contains("serial", StringComparison.OrdinalIgnoreCase)).Select(w => $"{w.Key} {w.Value:0} us"));
            link.Write([0x00]); link.Wait(20); link.Discard();
            return p5.Masks == masks ? worst.Where(w => w.Key.Contains("serial", StringComparison.OrdinalIgnoreCase)).Select(w => w.Value).DefaultIfEmpty(0).Max() : -1;
        }
        try
        {
            double shortList = SerialWorst(["rpm", "map", "tps", "speed", "inj", "ect:slow", "iat:slow", "batt:slow"], false, out var s1);
            Check("  the serial interrupt with the short list: about as short as the older lists' (under 200 us)", shortList is > 0 and < 200, s1);
            double masks = SerialWorst(["rpm", "map", "tps", "ect", "iat", "speed", "o2", "adv", "load", "batt", "eld", "baro", "gear", "modflags2", "serin1:slow", "codes:slow"], true, out var s2);
            Check("  with the masks (19 channel bytes, sparse): under 260 us", masks is > 0 and < 260, s2);
        }
        finally { ChannelStream.Selected = DatalogChannels.Defaults; }
        // the core alone: the HTS frame, no stream (7Eh unanswered)
        var core = Run(["FEAT_DATALOG"], [], [Hold(1, e => { e.Rpm = 3000; e.MapKpa = 60; })]);
        var cl = new DatalogLayout.SimLink(core.Sim);
        bool coreHts = new MultiByte20Probe().Try(cl);
        var cs0 = new ChannelStream { PostWritePauseMs = 0, Retries = 0 };
        Check("the core alone (FEAT_DATALOG): the HTS frame answers, the channel stream does not", coreHts && !cs0.Handshake(cl, out _), "");
    }

    static void Test_Dlservice() { Service(); CylinderTest(); }

    /// The cylinder test (63h-67h): each cylinder's injector cut in turn - only that one stops, the other three go on - and 63h
    /// puts it back; the check-engine lamp flashes meanwhile; only one is ever cut.
    static void CylinderTest()
    {
        var r = Run(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE"], new(), [Hold(1, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; })]);
        var link = new DatalogLayout.SimLink(r.Sim);
        byte Cmd(byte c) { link.Discard(); link.Write([c]); var a = new byte[1]; return link.Read(a, 0, 1, 300) == 1 ? a[0] : (byte)0; }
        long[] Count(double secs) { var a = (long[])r.Sim.Bus.InjectorEvents.Clone(); link.Run(secs); return [.. r.Sim.Bus.InjectorEvents.Select((v, i) => v - a[i])]; }
        // cylinder -> its injector's P2 bit (wired in firing order 1-3-4-2)
        int[] pin = [0, 3, 1, 2];
        var lampSeen = false;
        var rows = new List<string>();
        bool ok = true;
        for (int cyl = 1; cyl <= 4; cyl++)
        {
            byte ans = Cmd((byte)(0x63 + cyl));
            link.Run(0.3);
            var n = Count(1.0);
            // the lamp: P1.4 on at least once and off at least once over half a second
            bool on = false, off = false;
            for (int k = 0; k < 10; k++) { link.Run(0.05); if ((Platform.Latch(r.Sim, 0x22) & 0x10) != 0) on = true; else off = true; }
            lampSeen |= on && off;
            bool right = ans == 0x63 + cyl && n[pin[cyl - 1]] == 0 && Enumerable.Range(0, 4).Where(i => i != pin[cyl - 1]).All(i => n[i] > 5);
            ok &= right;
            rows.Add($"cyl {cyl} ({ans:X2}h): {string.Join("/", n)}");
        }
        byte back = Cmd(0x63);
        link.Run(0.3);
        var all = Count(1.0);
        Check("the cylinder test: each cylinder's injector cut in turn (only that one, the other three firing), 63h all back, the lamp flashing meanwhile",
              ok && back == 0x63 && all.All(x => x > 5) && lampSeen, $"{string.Join("; ", rows)}; back: {string.Join("/", all)}; lamp flashing {lampSeen}");
        // one at a time: 64h then 67h leaves only cylinder 4 cut; 5Eh (all back to normal) clears it too
        Cmd(0x64); Cmd(0x67); link.Run(0.3);
        var one = Count(1.0);
        Cmd(0x5E); link.Run(0.3);
        var cleared = Count(1.0);
        Check("  one at a time: cutting cylinder 4 after 1 puts 1 back; 'all back to normal' (5Eh) ends it",
              one[pin[3]] == 0 && one[pin[0]] > 5 && cleared.All(x => x > 5), $"after 64h 67h: {string.Join("/", one)}; after 5Eh: {string.Join("/", cleared)}");
    }

    static void Test_Remote() => Remote();

    // ------------------------------------------------------------------ the remote control commands (remote.asm)
    static void Remote()
    {
        string[] defs = ["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_REMOTE"];
        var idleSet = (Action<EngineState>)(e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0; });
        var at4000 = (Action<EngineState>)(e => { e.Rpm = 4000; e.MapKpa = 70; e.TpsPct = 30; e.SpeedKmh = 80; });
        var on = new Dictionary<string, byte[]> { ["rc_enable"] = B(1, 0) };
        // not enabled: every command answered 7Fh
        var (_, na) = Serve(defs, [], [Hold(1, idleSet)], [(0.5, 0x3F)]);
        Check("not enabled: 3Fh answered 7Fh", AnswerAfter(na, 0.5) == 0x7F, Said(na));
        // the rev limit set to 3000 rpm (60) at 4000 rpm: the fuel cut; read back; 2Dh: back to normal
        var (rv, ra) = Serve(defs, on, [Hold(3, at4000), Hold(3, at4000), Hold(3, at4000)],
            [(1.0, 0x3F), (3.05, 0x33), (3.1, 60), (3.3, 0x34), (6.05, 0x2D), (6.3, 0x34)]);
        Check("3Fh: 88h (enabled, unlocked); 33h 3Ch: the rev limit 3000 rpm cuts the fuel at 4000 (answer 3Ch), 34h reads it; 2Dh: normal again (34h 00h)",
            AnswerAfter(ra, 1.0) == 0x88 && rv.InjPerSec[1] < 5 && rv.InjPerSec[2] > 20 && rv.InjPerSec[0] > 20 && AnswerAfter(ra, 3.1) == 60 && AnswerAfter(ra, 3.3) == 60
            && AnswerAfter(ra, 6.05) == 0x2D && AnswerAfter(ra, 6.3) == 0,
            $"{rv.InjPerSec[0]:0} / {rv.InjPerSec[1]:0} / {rv.InjPerSec[2]:0} inj/s; answers {Said(ra)}");
        // the speed limit set to 60 km/h at 80
        var (sp, sa) = Serve(defs, on, [Hold(3, at4000), Hold(3, at4000)], [(3.05, 0x35), (3.1, 60), (3.3, 0x36)]);
        Check("35h 3Ch: the speed limit 60 km/h cuts the fuel at 80 (36h reads it)", sp.InjPerSec[1] < 5 && sp.InjPerSec[0] > 20 && AnswerAfter(sa, 3.3) == 60,
            $"{sp.InjPerSec[0]:0} / {sp.InjPerSec[1]:0} inj/s; answers {Said(sa)}");
        // the fan: on (P0.3 low at port B), off (high), auto
        bool fanOn = false, fanOff = false;
        var (_, fa) = Serve(defs, on, [Hold(1, idleSet), Hold(1, idleSet), Hold(1, idleSet)], [(1.05, 0x31), (2.05, 0x32), (2.9, 0x30)],
            (sim, t) => { if (Math.Abs(t - 1.8) < 0.006) fanOn = (Platform.PortB(sim) & 8) == 0; if (Math.Abs(t - 2.8) < 0.006) fanOff = (Platform.PortB(sim) & 8) != 0; });
        Check("31h: the fan on (P0.3 low), 32h: off (high), 30h: the ECU's again", fanOn && fanOff && AnswerAfter(fa, 1.05) == 0x31 && AnswerAfter(fa, 2.9) == 0x30,
            $"on {fanOn}, off {fanOff}; answers {Said(fa)}");
        // the boost cut and the VTEC point set exactly, read back; 0 = the tune's own
        var (_, ba) = Serve(defs, on, [Hold(1, idleSet)], [(0.2, 0x37), (0.25, 0x64), (0.4, 0x38), (0.55, 0x39), (0.6, 0xA0), (0.75, 0x3A), (0.9, 0x2D), (0.95 + 0.1, 0x38)]);
        Check("37h 64h: the boost cut set (answer 64h), 38h reads it; 39h A0h: the VTEC point (A0h), 3Ah reads it; 2Dh: back to the tune's (38h 00h)",
            AnswerAfter(ba, 0.25) == 0x64 && AnswerAfter(ba, 0.4) == 0x64 && AnswerAfter(ba, 0.6) == 0xA0 && AnswerAfter(ba, 0.75) == 0xA0 && AnswerAfter(ba, 1.05) == 0x00, Said(ba));
        // the boost cut set for real: the tune's 90 kPa, run at 80 kPa; set to 75 kPa and it cuts, set above the tune's and it stays at 90
        var bc = new Dictionary<string, byte[]> { ["rc_enable"] = B(1, 0), ["boostcut_block"] = B(1), ["boostcut_hot"] = B(MapRaw(90)), ["boostcut_cold"] = B(MapRaw(90)) };
        string[] bdefs = [.. defs, "FEAT_BOOSTCUT"];
        var (bl, bla) = Serve(bdefs, bc, [Hold(3, idleSet), At(4000, 80, 100, 80), At(4000, 80, 100, 80), At(4000, 80, 100, 80), At(4000, 80, 100, 80)],
            [(9.05, 0x37), (9.1, (byte)MapRaw(75)), (12.05, 0x37), (12.1, 0xF0)]);
        Check("37h 75 kPa: the cut at 80 kPa (fuel cut, none let through); 37h past the tune's: held at the tune's 90 kPa (runs at 80)",
            bl.InjPerSec[2] > 100 && bl.InjPerSec[3] < 2 && bl.InjPerSec[4] > 100,
            $"{bl.InjPerSec[2]:0} / {bl.InjPerSec[3]:0} / {bl.InjPerSec[4]:0} inj/s; answers {Said(bla)}");
        var (bh, bha) = Serve(bdefs, new(bc) { ["rc_boost_max"] = B(0) }, [Hold(3, idleSet), At(4000, 95, 100, 80), At(4000, 95, 100, 80), At(4000, 95, 100, 80)], [(6.05, 0x37), (6.1, 0xF0)]);
        var (bx, _) = Serve(bdefs, new(bc) { ["rc_boost_max"] = B(0x40) }, [Hold(3, idleSet), At(4000, 95, 100, 80), At(4000, 95, 100, 80), At(4000, 95, 100, 80)], [(6.05, 0x37), (6.1, 0xF0)]);
        Check("  never above the tune's own: 95 kPa against its 90 stays cut even when set to F0h; RemoteBoostMaxUp 40h lets it run",
            bh.InjPerSec[3] < 2 && bx.InjPerSec[3] > 100, $"{bh.InjPerSec[3]:0} / {bx.InjPerSec[3]:0} inj/s; answers {Said(bha)}");
        // the anti-start lock: no password, no start; a wrong one 7Fh; the main one 80h (as tuned); the guest one 81h (valet mode)
        var locked = new Dictionary<string, byte[]> { ["rc_enable"] = B(1, 0), ["rc_lock"] = B(1, 1), ["rc_pw_main"] = B(0xD2, 0x04), ["rc_pw_guest"] = B(0x39, 0x30),
            ["rc_guest"] = B(1), ["rc_valet_rev"] = B(60), ["rc_valet_speed"] = B(0) };
        var (lk, la) = Serve(defs, locked, [Hold(3, idleSet), Hold(3, idleSet)], [(1.0, 0x3F), (2.0, 0x2F), (2.05, 0x11), (2.1, 0x11), (3.05, 0x2F), (3.1, 0x04), (3.15, 0xD2), (4.0, 0x3F)]);
        Check("locked: no fuel, no spark (3Fh C0h); a wrong password 7Fh; the main one 80h and it runs (3Fh 88h)",
            lk.InjPerSec[0] < 2 && lk.IgnPerSec[0] < 2 && Running(lk) && AnswerAfter(la, 1.0) == 0xC0 && AnswerAfter(la, 2.1) == 0x7F && AnswerAfter(la, 3.15) == 0x80 && AnswerAfter(la, 4.0) == 0x88,
            $"{Rates(lk)}; locked {lk.InjPerSec[0]:0} inj/s; answers {Said(la)}");
        var (pf, pa) = Serve(defs, locked, [Hold(3, idleSet), Hold(3, at4000), Hold(3, at4000)], [(1.0, 0x2F), (1.05, 0x30), (1.1, 0x39)]);
        Check("  the guest password: valet mode (81h), its rev limit 3000 cuts at 4000", AnswerAfter(pa, 1.1) == 0x81 && pf.InjPerSec[2] < 5 && pf.InjPerSec[0] > 5,
            $"{pf.InjPerSec[0]:0} / {pf.InjPerSec[1]:0} / {pf.InjPerSec[2]:0} inj/s; answers {Said(pa)}");
        var (pg, _) = Serve(defs, new(locked) { ["rc_guest"] = B(0) }, [Hold(2, idleSet)], [(1.0, 0x2F), (1.05, 0x30), (1.1, 0x39)]);
        var (pz, pza) = Serve(defs, new(locked) { ["rc_pw_main"] = B(0, 0) }, [Hold(2, idleSet), Hold(2, idleSet)], [(1.0, 0x2F), (1.05, 0x00), (1.1, 0x00)]);
        var (pm, pma) = Serve(defs, new(locked) { ["rc_pw_main"] = B(0xFF, 0xFF) }, [Hold(2, idleSet), Hold(2, idleSet)], [(1.0, 0x2F), (1.05, 0xFF), (1.1, 0xFF)]);
        Check("  guest password off: not taken; passwords 0 and 65535 are passwords like any other",
            pg.InjPerSec[0] < 2 && AnswerAfter(pza, 1.1) == 0x80 && Running(pz) && AnswerAfter(pma, 1.1) == 0x80 && Running(pm), $"answers {Said(pza)} / {Said(pma)}");
        // no password (or a wrong one) means valet mode, when set so: it runs, held to valet mode's rev limit, until the main password
        var valet = new Dictionary<string, byte[]>(locked) { ["rc_lock_valet"] = B(1) };
        var (vl, vla) = Serve(defs, valet, [Hold(3, idleSet), Hold(3, at4000), Hold(3, at4000), Hold(3, at4000)],
            [(1.0, 0x3F), (2.0, 0x2F), (2.05, 0x11), (2.1, 0x11), (12.05, 0x2F), (12.1, 0x04), (12.15, 0xD2), (13.0, 0x3F)]);
        Check("lock with valet mode: no password, it runs (3Fh 98h) at valet mode's 3000 rpm limit; a wrong one 7Fh; the main one: as tuned (88h), runs at 4000",
            vl.InjPerSec[1] > 5 && AnswerAfter(vla, 1.0) == 0x98 && vl.InjPerSec[3] < 5 && AnswerAfter(vla, 2.1) == 0x7F && AnswerAfter(vla, 12.15) == 0x80
            && AnswerAfter(vla, 13.0) == 0x88 && vl.InjPerSec[4] > 100,
            $"{string.Join(" / ", vl.InjPerSec.Select(x => x.ToString("0")))} inj/s; answers {Said(vla)}");
        // the keyed values: 2Ch k n sets, 2Bh k reads, a key past the last one 7Fh
        var (_, ka) = Serve(defs, on, [Hold(1, idleSet)], [(0.2, 0x2C), (0.25, 0x00), (0.3, 0x3C), (0.45, 0x2B), (0.5, 0x00), (0.65, 0x34), (0.8, 0x2C), (0.85, 0x0A), (0.9, 0x01)]);
        Check("2Ch 00h 3Ch: the rev limit (3Ch), 2Bh 00h and 34h read it; 2Ch with key 0Ah: 7Fh",
            AnswerAfter(ka, 0.3) == 0x3C && AnswerAfter(ka, 0.5) == 0x3C && AnswerAfter(ka, 0.65) == 0x3C && AnswerAfter(ka, 0.9) == 0x7F, Said(ka));
        // the rev limiter's cut chosen over the cable: an ignition-cut limiter at 4000, at 4040 rpm, made a fuel cut
        var rl4 = new Dictionary<string, byte[]> { ["rc_enable"] = B(1, 0), ["revlimit_low"] = B(1), ["revlimit_cut"] = B(1), ["revlimit_low_set"] = W(P(4000)), ["revlimit_low_reset"] = W(P(3900)) };
        var climb = (Action<EngineState, double>)((e, t) => { e.Rpm = 3500 + 540 * t; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = 80; });
        var at4040 = Hold(3, e => { e.Rpm = 4040; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = 80; });
        string[] rdefs = [.. defs, "FEAT_REVLIMIT"];
        var (ct, cta) = Serve(rdefs, rl4, [Hold(3, idleSet), (3, climb), at4040, at4040], [(12.05, 0x2C), (12.1, 0x05), (12.15, 0x01)]);
        Check("2Ch 05h 01h: the rev limiter's ignition cut made a fuel cut (sparks back, fuel gone)",
            ct.IgnPerSec[3] < 5 && ct.InjPerSec[3] > 100 && ct.InjPerSec[4] < 5 && ct.IgnPerSec[4] > 100 && AnswerAfter(cta, 12.15) == 0x01,
            $"{ct.InjPerSec[3]:0}/{ct.IgnPerSec[3]:0} -> {ct.InjPerSec[4]:0}/{ct.IgnPerSec[4]:0} inj/sparks; answers {Said(cta)}");
        // the launch rpm moved: launch armed always, its tune's 5000, at 4000 standing; set to 3500 and it cuts
        var ln = new Dictionary<string, byte[]> { ["rc_enable"] = B(1, 0), ["launch_block"] = B(1), ["launch_cut"] = B(0), ["launch_input"] = B(0x80), ["launch_speed"] = B(10) };
        var stand4000 = Hold(3, e => { e.Rpm = 4000; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = 0; });
        var (lc, lca) = Serve([.. defs, "FEAT_LAUNCH"], ln, [Hold(3, idleSet), stand4000, stand4000, stand4000], [(9.05, 0x2C), (9.1, 0x06), (9.15, 70)]);
        Check("2Ch 06h 46h: launch control at 3500 rpm instead of the tune's 5000 (cuts at 4000)",
            lc.InjPerSec[2] > 100 && lc.InjPerSec[3] < 5 && AnswerAfter(lca, 9.15) == 70, $"{string.Join(" / ", lc.InjPerSec.Select(x => x.ToString("0")))} inj/s; answers {Said(lca)}");
        // the shift light point: its tune's 8000, at 4000; set to 3000 and the lamp comes on
        var sl = new Dictionary<string, byte[]> { ["rc_enable"] = B(1, 0), ["shiftlight_enable"] = B(0xFF), ["shiftlight_rpm"] = W(P(8000)) };
        bool lampBefore = true, lampAfter = false;
        var (_, sla) = Serve([.. defs, "FEAT_SHIFTLIGHT"], sl, [Hold(3, idleSet), Hold(3, at4000), Hold(3, at4000), Hold(3, at4000)], [(9.05, 0x2C), (9.1, 0x04), (9.15, 60)],
            (sim, t) => { if (Math.Abs(t - 8.5) < 0.006) lampBefore = (Platform.Latch(sim, 0x22) & 0x10) != 0; if (Math.Abs(t - 11.5) < 0.006) lampAfter = (Platform.Latch(sim, 0x22) & 0x10) != 0; });
        Check("2Ch 04h 3Ch: the shift light at 3000 rpm instead of the tune's 8000 (the lamp on at 4000)", !lampBefore && lampAfter && AnswerAfter(sla, 9.15) == 60,
            $"lamp {lampBefore} -> {lampAfter}; answers {Said(sla)}");
        // rolling idle switched on over the cable (off in the tune), then one in 3
        var ri = new Dictionary<string, byte[]> { ["rc_enable"] = B(1, 0), ["rollidle_enable"] = B(0), ["rollidle_input"] = B(0x80), ["rollidle_every"] = B(9) };
        var (rr, rra) = Serve([.. defs, "FEAT_ROLLIDLE"], ri, [Hold(3, idleSet), Hold(3, idleSet), Hold(3, idleSet), Hold(3, idleSet)],
            [(6.05, 0x2C), (6.1, 0x07), (6.15, 0x02), (9.05, 0x2C), (9.1, 0x09), (9.15, 0x03)]);
        double f1 = rr.InjPerSec[2] / rr.InjPerSec[1], f2 = rr.InjPerSec[3] / rr.InjPerSec[1];
        Check("2Ch 07h 02h: rolling idle on (one in 9 left out), 2Ch 09h 03h: one in 3",
            f1 is > 0.82 and < 0.95 && f2 is > 0.58 and < 0.75 && AnswerAfter(rra, 9.15) == 3, $"{rr.InjPerSec[1]:0} -> {rr.InjPerSec[2]:0} -> {rr.InjPerSec[3]:0} inj/s; answers {Said(rra)}");
        // the same through the app's own protocol: value bytes and a password through the channel stream, which streams on after
        var rl = Run([.. defs], locked, [Hold(1, idleSet)]);
        var lnk = new DatalogLayout.SimLink(rl.Sim);
        var str = new ChannelStream { PostWritePauseMs = 0 };
        bool hs = str.Handshake(lnk, out _);
        for (int i = 0; i < 5; i++) str.Poll(lnk, 0, out _);
        var q0 = str.Command(lnk, 0x3F, out _); var pw = str.Command(lnk, [0x2F, 0x30, 0x39], out _); var rv2 = str.Command(lnk, [0x33, 70], out _);
        var rd = str.Command(lnk, 0x34, out _); var q1 = str.Command(lnk, 0x3F, out _);
        int streamed = 0;
        for (int i = 0; i < 20; i++) if (str.Poll(lnk, 0, out _) != null) streamed++;
        Check("through the channel stream: locked (C0h), the guest password (81h), 33h 46h (46h), read back, unlocked valet (98h); remote in the ident; streams on",
            hs && str.HasRemote && q0 == 0xC0 && pw == 0x81 && rv2 == 70 && rd == 70 && q1 == 0x98 && streamed >= 15,
            $"{q0:X2} {pw:X2} {rv2:X2} {rd:X2} {q1:X2}; ident remote {str.HasRemote}; {streamed} of 20 frames after");
        // popcorn: off throttle at 4000 rpm the fuel stays on (no overrun cut), the sparks cut every other slot
        var decel = (Action<EngineState>)(e => { e.Rpm = 4000; e.MapKpa = 20; e.TpsPct = 0; e.SpeedKmh = 80; });
        bool held = false;
        var (pc, ca) = Serve(defs, on, [Hold(3, idleSet), Hold(3, decel), Hold(3, decel), Hold(3, decel)], [(6.05, 0x3D), (9.05, 0x3E)],
            (sim, t) => { if (Math.Abs(t - 8) < 0.006) held = (sim.Bus.Ram[0xFD] & 2) != 0; });
        Check("3Dh: popcorn on the overrun (fuel on, sparks about halved, 0FDh.1 held); 3Eh: off",
            held && pc.InjPerSec[2] > pc.InjPerSec[3] + 50 && pc.IgnPerSec[2] < pc.IgnPerSec[3] * 0.75 && pc.IgnPerSec[2] > pc.IgnPerSec[3] * 0.25
            && pc.InjPerSec[3] < 5 && AnswerAfter(ca, 6.05) == 0x3D && AnswerAfter(ca, 9.05) == 0x3E,
            $"{pc.InjPerSec[1]:0}/{pc.IgnPerSec[1]:0} -> {pc.InjPerSec[2]:0}/{pc.IgnPerSec[2]:0} -> {pc.InjPerSec[3]:0}/{pc.IgnPerSec[3]:0} inj/sparks; answers {Said(ca)}");
    }
    static void Test_Dlstream() { Sync(); Fast(); }     // (the rest with the core, in Test_Datalog)

    /// DatalogFast: the port at 62,500 baud (reload FBh) and the stream right at that speed. Then the byte budget: streaming
    /// flat out, the main loop still works out the spark (nearly) as often as with no stream, and never waits much longer.
    static void Fast()
    {
        ChannelStream.Selected = ["rpm", "map", "tps", "speed", "inj", "adv", "load", "batt", "ect", "iat"];
        try
        {
            (double Bps, int Reload, LogFrame? Last) Go(bool fast)
            {
                var r = Run(["FEAT_DATALOG", "FEAT_DLSTREAM"], fast ? new() { ["dl_fast"] = B(1) } : new(),
                            [Hold(1, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; e.SpeedKmh = 90; })]);
                var link = new DatalogLayout.SimLink(r.Sim);
                link.SetBaud(fast ? 62500 : 38400);
                var cs = new ChannelStream { PostWritePauseMs = 0 };
                if (!cs.Handshake(link, out _)) return (0, r.Sim.Bus.Ram[Platform.P13 ? 0x78 : 0x49], null);
                LogFrame? last = null;
                for (int i = 0; i < 20 && last == null; i++) last = cs.Poll(link, 0, out _);
                link.Discard();
                link.Run(1.0);                                     // a second of the stream: its bytes
                int n = link.Read(new byte[65536], 0, 65536, 0);
                link.Write([0x00]);
                return (n, r.Sim.Bus.Ram[Platform.P13 ? 0x78 : 0x49], last);
            }
            // spark calculations (hook_ign) a second at an rpm: streaming, and not
            (double PerS, double GapMs) Sparks(bool stream, int rpm)
            {
                var r = Run(["FEAT_DATALOG", "FEAT_DLSTREAM"], new(), [Hold(1, e => { e.Rpm = rpm; e.MapKpa = 100; e.TpsPct = 100; e.SpeedKmh = 120; })]);
                int ign = (int)r.Asm.Symbols.Values.First(x => x.Name.Equals("hook_ign", StringComparison.OrdinalIgnoreCase)).Value;
                var link = new DatalogLayout.SimLink(r.Sim);
                if (stream) { var cs = new ChannelStream { PostWritePauseMs = 0 }; if (!cs.Handshake(link, out _)) return (0, 0); cs.Poll(link, 0, out _); }
                link.Run(0.5);
                long n = 0; ulong last = 0, gap = 0;
                r.Sim.BeforeStep = (pc, _) => { if (pc == ign) { n++; if (last != 0) gap = Math.Max(gap, r.Sim.Cpu.Cycles - last); last = r.Sim.Cpu.Cycles; } };
                link.Run(4.0);
                r.Sim.BeforeStep = null;
                if (stream) link.Write([0x00]);
                return (n / 4.0, gap / (Bus.CpuHz / 1000.0));
            }
            var slow = Go(false);
            var fast = Go(true);
            Check("62,500 baud (DatalogFast): the port's reload FBh (F8h without it), the stream read right at that speed",
                  slow.Reload == (Platform.P13 ? 0x07 : 0xF8) && fast.Reload == (Platform.P13 ? 0x04 : 0xFB) && fast.Bps > 200 && fast.Last is { } l && Math.Abs(l.Rpm!.Value - 3000) < 60 && Math.Abs(l.MapKpa!.Value - 60) < 4,
                  $"reload {slow.Reload:X2}h / {fast.Reload:X2}h, {slow.Bps:0} / {fast.Bps:0} bytes a second; last {fast.Last?.Rpm} rpm {fast.Last?.MapKpa} kPa");
            ChannelStream.Selected = ["rpm", "map", "tps", "speed", "inj", "adv", "load", "batt", "ect", "iat", "o2", "switches", "pump"];
            // (the simulator's own spark rate jumps about from one rpm to the next: an average over a few)
            var gate = new[] { 2000, 3000, 5500, 7000 }.Select(rpm => (Rpm: rpm, Quiet: Sparks(false, rpm), Streaming: Sparks(true, rpm))).ToList();
            // (a byte landing just as a cylinder's calculation is due can make the main loop miss that one - the advance worked
            // out for the one before is used again - which the ROM does now and then with no logging too: never two in a row)
            double rate = gate.Average(g => g.Streaming.PerS / Math.Max(1, g.Quiet.PerS));
            Check("the byte budget: streaming 15 bytes a frame from 2000 to 7000 rpm, the spark is worked out at least 90 % as often as with no stream, and never two calculations missed in a row",
                  gate.All(g => g.Quiet.PerS > 0 && g.Streaming.GapMs <= g.Quiet.GapMs * 2.1) && rate >= 0.9,
                  $"{rate * 100:0} % as often; " + string.Join(", ", gate.Select(g => $"{g.Rpm} rpm {g.Streaming.PerS:0.0} / {g.Quiet.PerS:0.0} a second, {g.Streaming.GapMs:0} / {g.Quiet.GapMs:0} ms")));
            // the engine stopped: no spark calculations, and the ECU still talks (the main loop's pass gives the budget)
            var off = Run(["FEAT_DATALOG", "FEAT_DLSTREAM"], new(), [Hold(1, e => { e.Rpm = 0; e.MapKpa = 101; e.TpsPct = 0; e.SpeedKmh = 0; })]);
            var offLink = new DatalogLayout.SimLink(off.Sim);
            var offCs = new ChannelStream { PostWritePauseMs = 0 };
            bool offHs = offCs.Handshake(offLink, out var offNote);
            offLink.Discard(); offLink.Run(1.0);
            int offBytes = offLink.Read(new byte[65536], 0, 65536, 0);
            offLink.Write([0x00]);
            Check("  the engine stopped (key on): the stream still flows", offHs && offBytes > 500, $"{offNote}; {offBytes} bytes a second");
        }
        finally { ChannelStream.Selected = DatalogChannels.Defaults; }
    }

    /// A line that loses or spoils a byte now and then (every `every`th byte the ECU sends: dropped, or changed), as a noisy cable does.
    sealed class NoisyLink(IByteLink inner, int every) : IByteLink
    {
        int _n;
        public string Name => inner.Name + " (noisy)";
        public void Write(byte[] data) => inner.Write(data);
        public void Discard() => inner.Discard();
        public void Wait(int ms) => inner.Wait(ms);
        public int Read(byte[] buffer, int offset, int count, int timeoutMs)
        {
            int got = inner.Read(buffer, offset, count, timeoutMs), w = offset;
            for (int i = offset; i < offset + got; i++)
            {
                if (++_n % every == 0) { if (_n / every % 2 == 0) continue; buffer[i] ^= 0x5A; }   // dropped, or spoilt
                buffer[w++] = buffer[i];
            }
            return w - offset;
        }
    }

    /// Frames read through a noisy line at the rev limit (ignition cut at 7000, and past it the hard fuel cut, so the car slows): every one taken is right, none of two halves.
    static void Sync()
    {
        var cal = new Dictionary<string, byte[]> { ["revlimit_low"] = B(1), ["revlimit_cut"] = B(1), ["revlimit_low_set"] = W(P(7000)), ["revlimit_low_reset"] = W(P(6900)) };
        var r = Run(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_REVLIMIT"], cal, [Hold(1, e => { e.Rpm = 7200; e.MapKpa = 100; e.TpsPct = 100; e.SpeedKmh = 100; })]);
        var noisy = new NoisyLink(new DatalogLayout.SimLink(r.Sim), 61);
        ChannelStream.Selected = ["rpm", "map", "tps", "speed", "ect:slow", "batt:slow"];
        try
        {
            var cs = new ChannelStream { PostWritePauseMs = 0 };
            bool hs = false;
            for (int i = 0; i < 5 && !hs; i++) hs = cs.Handshake(noisy, out _);
            var bad = new List<string>(); int good = 0;
            for (int i = 0; i < 120; i++)
                if (cs.Poll(noisy, 0, out _) is { } f)
                {
                    good++;
                    // (rpm 0: the ECU's own "no reading" FFFFh, which it holds for a moment when the rev limit's cut makes a
                    // crank period unreadable - a true frame; the faster line catches it now and then)
                    if (f.Rpm is not ((> 7000 and < 7400) or 0) || f.MapKpa is not (> 90 and < 110) || f.SpeedKmh is not (> 20 and < 105)) bad.Add($"{f.Rpm} rpm {f.MapKpa} kPa {f.SpeedKmh} km/h");
                }
            Check("channel stream through a line that drops or spoils every 61st byte, at the rev limit: every frame taken is right", hs && good > 60 && bad.Count == 0,
                  $"{good} frames, {cs.Lost} lost; wrong: {string.Join("; ", bad.Take(3))}");
        }
        finally { ChannelStream.Selected = DatalogChannels.Defaults; }
        // the HTS 20h frame, asked and answered, through the same line
        var r2 = Run(["FEAT_DATALOG", "FEAT_REVLIMIT"], cal, [Hold(1, e => { e.Rpm = 7200; e.MapKpa = 100; e.TpsPct = 100; e.SpeedKmh = 100; })]);
        var n2 = new NoisyLink(new DatalogLayout.SimLink(r2.Sim), 61);
        var hts = DatalogProtocol.ByName("Multi-byte 20h")!;
        hts.PostWritePauseMs = 0;
        bool h2 = false;
        for (int i = 0; i < 5 && !h2; i++) h2 = hts.Handshake(n2, out _);
        var bad2 = new List<string>(); int good2 = 0;
        // (past 6500 rpm the ECU sends a byte a spark calculation - its byte budget - so a frame takes a second or two)
        for (int i = 0; i < 12; i++)
            if (hts.Poll(n2, 0, out _) is { } f)
            {
                good2++;
                if (f.Rpm is not (> 7000 and < 7400) || f.MapKpa is not (> 90 and < 110) || f.SpeedKmh is not (> 20 and < 105)) bad2.Add($"{f.Rpm} rpm {f.MapKpa} kPa {f.SpeedKmh} km/h");
            }
        Check("  the HTS 20h frame through it: every frame taken is right", h2 && good2 > 1 && bad2.Count == 0, $"{good2} of 12 polls; wrong: {string.Join("; ", bad2.Take(3))}");
    }

    /// Steps the simulator for `secs` and gives each interrupt handler's worst own time in us: entry to RTI, less the handlers that interrupted it.
    static Dictionary<string, double> IsrWorst(Simulator sim, AssemblyResult asm, double secs)
    {
        var open = new List<(string Name, ulong Since, ulong Own)>();
        var worst = new Dictionary<string, ulong>();
        ulong end = sim.Cpu.Cycles + (ulong)(secs * Bus.CpuHz);
        while (sim.Cpu.Cycles < end)
        {
            var st = sim.StepOne();
            if (st == null) break;
            ulong now = sim.Cpu.Cycles;
            if (st?.Decoded is { } d && d.Mnemonic.StartsWith("RTI", StringComparison.Ordinal) && open.Count > 0)
            {
                var top = open[^1]; open.RemoveAt(open.Count - 1);
                worst[top.Name] = Math.Max(worst.GetValueOrDefault(top.Name), top.Own + (now - top.Since));
                if (open.Count > 0) { var o = open[^1]; open[^1] = (o.Name, now, o.Own); }
            }
            if (sim.LastStepInterrupted)
            {
                if (open.Count > 0) { var o = open[^1]; open[^1] = (o.Name, o.Since, o.Own + (now - o.Since)); }
                open.Add((asm.LabelAt(sim.Cpu.Pc) ?? $"{sim.Cpu.Pc:X4}", now, 0));
            }
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
        }
        return worst.ToDictionary(w => w.Key, w => w.Value / (Bus.CpuHz / 1e6));
    }

    static int SymOf(AssemblyResult a, string n) => (int)a.Symbols.Values.First(s => s.Name.Equals(n, StringComparison.OrdinalIgnoreCase)).Value;

    // ------------------------------------------------------------------ the trigger pattern log (triglog.asm)
    static Func<string>? Dbg;
    static void Test_Triglog()
    {
        // one capture: 61h arms it, 62h sends it (62h, state, scale, 24 teeth, sum)
        static byte[]? Capture(DatalogLayout.SimLink link)
        {
            link.Discard();
            link.Write([0x61]);
            var a = new byte[1];
            if (link.Read(a, 0, 1, 200) != 1 || a[0] != 0x61) { Console.WriteLine($"      (61h answered {a[0]:X2})"); return null; }
            link.Run(0.6);                                  // a cam revolution at 250 rpm is 0.48 s
            link.Discard();
            link.Write([0x62]);
            var r = new byte[28];
            int n = link.Read(r, 0, 28, 1500);
            if (!(n == 28 && (r.Take(27).Sum(b => b) & 0xFF) == r[27])) Console.WriteLine($"      (62h: {n} bytes {Convert.ToHexString(r, 0, n)}; {Dbg?.Invoke()})");
            return n == 28 && (r.Take(27).Sum(b => b) & 0xFF) == r[27] ? r : null;
        }
        static string Show2(byte[] r) => "";
        static string Show(byte[] r) => string.Join(" ", r.Skip(3).Take(24).Select(b => $"{b & 63}{((b & 0x80) != 0 ? "T" : "")}{((b & 0x40) != 0 ? "C" : "")}"));
        foreach (var (rpm, what) in new[] { (3000, "at 3000 rpm"), (250, "cranking (250 rpm)") })
        {
            var r = Run(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_TRIGLOG"], new(), [Hold(1, e => { e.Rpm = rpm; e.MapKpa = rpm < 400 ? 90 : 60; e.TpsPct = 10; e.Cranking = rpm < 400; })]);
            var link = new DatalogLayout.SimLink(r.Sim);
            int nAt = SymOf(r.Asm, "TRG_N");
            Dbg = () => $"state {r.Sim.State}, pc {r.Sim.Cpu.Pc:X4} {r.Asm.Lookup(r.Sim.Cpu.Pc)?.Line} {r.Sim.FaultMessage}, {string.Join(",", r.Asm.Symbols.Values.Where(x => x.Kind == SymbolKind.Label && x.Value <= r.Sim.Cpu.Pc).OrderByDescending(x => x.Value).Take(1).Select(x => x.Name))}, SSP {r.Sim.Bus.Ram[0] | r.Sim.Bus.Ram[1] << 8:X4}, 0FDh {r.Sim.Bus.Ram[0xFD]:X2}, TRG_N {r.Sim.Bus.Ram[nAt]}, buf {Convert.ToHexString(r.Sim.Bus.Ram, nAt - 2, 30)}";
            var c = Capture(link);
            bool ok = c != null && c[0] == 0x62 && c[1] == 25;
            var teeth = c?.Skip(3).Take(24).ToArray() ?? [];
            int[] tdc = [.. Enumerable.Range(0, teeth.Length).Where(i => (teeth[i] & 0x80) != 0)];
            int[] cyp = [.. Enumerable.Range(0, teeth.Length).Where(i => (teeth[i] & 0x40) != 0)];
            bool even = teeth.Length == 24 && teeth.All(t => (t & 63) is >= 12 and <= 33);
            bool tdcSix = tdc.Length == 4 && Enumerable.Range(1, 3).All(i => tdc[i] - tdc[i - 1] == 6);
            // CYP three teeth after one TDC (it may fall off the end of the 24, one capture in four)
            bool cypOk = cyp.Length == 1 && tdc.Any(t => cyp[0] - t == 3) || cyp.Length == 0 && tdc.Any(t => t + 3 >= 24);
            Check($"trigger pattern {what}: 24 even teeth, 4 TDC six teeth apart, the cylinder pulse three teeth after one", ok && even && tdcSix && cypOk,
                  c == null ? "no answer" : $"state {c[1]}, scale {c[2]}: {Show(c)}");
        }
        // the hooks cost nothing until asked: no capture, no tooth hook (0FDh bit 6 clear)
        var idle = Run(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_TRIGLOG"], new(), [Hold(1, e => { e.Rpm = 3000; e.MapKpa = 60; })]);
        Check("  not asked for: the crank hooks stay off", (idle.Sim.Bus.Ram[0xFD] & 0x40) == 0, $"0FDh {idle.Sim.Bus.Ram[0xFD]:X2}");
        // through the app's own path (the channel stream's capture, then the analysis): each simulated sensor fault found, on its sensor
        foreach (var (fault, sensor) in new[] { (TriggerFault.None, ""), (TriggerFault.CkpMissedTooth, "CKP"), (TriggerFault.CkpExtraPulse, "CKP"),
                                                (TriggerFault.TdcMissing, "TDC"), (TriggerFault.CypMissing, "CYP"), (TriggerFault.CypLate, "CYP") })
        {
            var rr = Run(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_TRIGLOG"], new(), [Hold(1, e => { e.Rpm = 2000; e.MapKpa = 45; e.TpsPct = 10; })]);
            rr.Sim.Engine.Trigger = fault;
            var lk = new DatalogLayout.SimLink(rr.Sim);
            lk.Run(0.3);
            ChannelStream.Selected = ["rpm", "map"];
            var cs = new ChannelStream { PostWritePauseMs = 0 };
            bool hs = cs.Handshake(lk, out var hn);
            var tp = hs ? cs.CaptureTrigger(lk, out var tn) : null;
            var found = tp?.Analyse() ?? [];
            bool right = tp is { Complete: true } && (sensor == "" ? found.Count == 0 : found.Any(x => x.Sensor == sensor && x.Level == TriggerPattern.Severity.Fault));
            // and the stream carries on after it
            bool after = hs && Enumerable.Range(0, 20).Any(i => cs.Poll(lk, 0, out _) != null);
            Check($"  {(fault == TriggerFault.None ? "no fault: nothing reported" : $"simulated {fault}: found on {sensor}")}, and the stream carries on after", right && after && cs.HasTriggerLog,
                  tp == null ? $"{hn}; no capture" : $"{tp.Summary()} | {string.Join(" | ", found.Select(x => $"{x.Sensor}: {x.Text[..Math.Min(70, x.Text.Length)]}"))}");
        }
        ChannelStream.Selected = DatalogChannels.Defaults;
        TriggerRepeat();
    }

    /// Captures back to back (the window's real time), as the app takes them: at idle, cruise and two high rpms, and through a line
    /// that loses or spoils every 61st byte - every capture taken a healthy pattern (no false fault), most of them taken, the stream
    /// alive between them.
    static void TriggerRepeat()
    {
        foreach (var (rpm, noisy) in new[] { (850, false), (3000, false), (6500, false), (8000, false), (3000, true) })
        {
            var r = Run(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_TRIGLOG"], new(), [Hold(1, e => { e.Rpm = rpm; e.MapKpa = rpm > 5000 ? 100 : 50; e.TpsPct = rpm > 5000 ? 100 : 15; })]);
            IByteLink lk = noisy ? new NoisyLink(new DatalogLayout.SimLink(r.Sim), 61) : new DatalogLayout.SimLink(r.Sim);
            ChannelStream.Selected = ["rpm", "map", "tps"];
            var cs = new ChannelStream { PostWritePauseMs = 0 };
            bool hs = false;
            for (int i = 0; i < 5 && !hs; i++) hs = cs.Handshake(lk, out _);
            int good = 0, bad = 0, none = 0, frames = 0;
            var wrong = new List<string>(); var noneWhy = new List<string>();
            for (int k = 0; k < 30; k++)
            {
                var p = cs.CaptureTrigger(lk, out var note);
                if (p == null) { none++; noneWhy.Add(note); continue; }
                var f = p.Analyse();
                if (p.Complete && f.Count == 0) good++; else { bad++; wrong.Add($"capture {k}: " + p.Summary() + ": " + string.Join("; ", f.Select(x => x.Text)) + " [" + string.Join(" ", p.Ordered().Select(t => $"{t.Scaled}{(t.Tdc ? "T" : "")}{(t.Cyp ? "C" : "")}")) + "]"); }
                if (cs.Poll(lk, 0, out _) != null) frames++;          // the stream between two
            }
            Check($"  30 captures back to back at {rpm} rpm{(noisy ? " through a noisy line" : "")}: none shows a fault that is not there, {(noisy ? "27" : "all 30")}+ taken, the stream alive between them",
                  hs && bad == 0 && good >= (noisy ? 27 : 30) && frames >= 25, $"{good} healthy, {bad} wrong, {none} with no answer ({string.Join(", ", noneWhy.GroupBy(x => x).Select(g => $"{g.Count()}x {g.Key}"))}), {frames} frames between; {string.Join(" | ", wrong.Take(2))}");
        }
        ChannelStream.Selected = DatalogChannels.Defaults;
    }

    // ------------------------------------------------------------------ serial inputs (dlserialin.asm)
    static void Test_Dlserialin()
    {
        // flex fuel on serial input 4 (its input 7), the ethanol content = the value (0 V -> 0 %, 255 -> 100 %)
        var cal = new Dictionary<string, byte[]> { ["flex_enable"] = B(1), ["flex_input"] = B(7), ["flex_v0"] = B(0), ["flex_v100"] = B(255), ["serin_default"] = B(0, 0, 0, 33, 0, 0, 0, 0) };
        var r = Run(["FEAT_DLSTREAM", "FEAT_DLSERIALIN", "FEAT_FLEX"], cal, [Hold(1, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; })]);
        int ram = SymOf(r.Asm, "SERIN_RAM"), age = SymOf(r.Asm, "SERIN_AGE"), eth = SymOf(r.Asm, "flex_eth");
        var link = new DatalogLayout.SimLink(r.Sim);
        Check("at power-up none has come: the inputs read as their defaults (input 4: 33)", r.Sim.Bus.Ram[age] == 0xFF && Math.Abs(r.Sim.Bus.Ram[eth] - 33) <= 2,
              $"age {r.Sim.Bus.Ram[age]:X2}, ethanol {r.Sim.Bus.Ram[eth]}");
        ChannelStream.Selected = ["rpm", "map", "serin4", "serinage:slow"];
        try
        {
            var cs = new ChannelStream { PostWritePauseMs = 0 };
            bool hs = cs.Handshake(link, out var note);
            int before = 0, after = 0;
            for (int i = 0; i < 10; i++) if (cs.Poll(link, 0, out _) != null) before++;
            cs.SendInputs(link, [(3, 150), (200, 77)]);       // input 3 is the fourth kept; 200 is not kept
            LogFrame? last = null;
            for (int i = 0; i < 40; i++) if (cs.Poll(link, 0, out _) is { } f) { after++; last = f; }
            Check("the ident says serial inputs; FFh 03h 96h stores 150 in input 4 while the stream runs on", hs && cs.HasSerialInputs && r.Sim.Bus.Ram[ram + 3] == 150 && before >= 8 && after >= 30,
                  $"{note}; RAM {r.Sim.Bus.Ram[ram + 3]}, {before} frames before, {after} after");
            Check("  an input the ROM does not keep is let go; the stream logs input 4 and the time since one came",
                  Enumerable.Range(0, 8).All(i => i == 3 || r.Sim.Bus.Ram[ram + i] == 0) && last?.Get("serin4") == 150 && last.Get("serin_age_s") is < 2,
                  $"serin4 {last?.Get("serin4")}, age {last?.Get("serin_age_s")} s");
            cs.SendInputs(link, [(3, 150)]);              // (the one before is close to its 1 s timeout by now)
            link.Run(0.3);
            Check("  flex fuel reads it as its input (150 of 255)", Math.Abs(r.Sim.Bus.Ram[eth] - 150) <= 2, $"ethanol {r.Sim.Bus.Ram[eth]}");
            // a byte lost on the line: FFh starts again; FFh as a value is never one
            foreach (var b in new byte[] { 0xFF, 0x03, 0xFF, 0x03, 0x64 }) { link.Write([b]); link.Wait(1); }
            link.Run(0.05);
            Check("  FFh mid-input starts it again (FFh 03h FFh 03h 64h stores 100)", r.Sim.Bus.Ram[ram + 3] == 100, $"{r.Sim.Bus.Ram[ram + 3]}");
            // none for the timeout (about 1 s): back to the default
            link.Run(1.5);
            Check("  none for 1.5 s: the input reads as its default again (33)", r.Sim.Bus.Ram[age] > 30 && Math.Abs(r.Sim.Bus.Ram[eth] - 33) <= 2,
                  $"age {r.Sim.Bus.Ram[age]}, ethanol {r.Sim.Bus.Ram[eth]}");
        }
        finally { ChannelStream.Selected = DatalogChannels.Defaults; }
        // a serial input as a module's switch: GIO 1 (the purge output) on serial input 2 (C1h), on while it is not 0
        var gio = new Dictionary<string, byte[]> { ["gio1_block"] = GioBlock(2, 600, 500, input: 0xC1), ["serin_timeout"] = B(0) };
        var rg = Run(["FEAT_DATALOG", "FEAT_DLSERIALIN", "FEAT_GIO1"], gio, [Hold(1, e => { e.Rpm = 850; e.MapKpa = 33; })]);
        var lg = new DatalogLayout.SimLink(rg.Sim);
        bool offFirst = (Platform.Latch(rg.Sim, 0x20) & 2) != 0;
        foreach (var b in new byte[] { 0xFF, 0x01, 0x01 }) { lg.Write([b]); lg.Wait(1); }
        lg.Run(0.4);
        bool onThen = (Platform.Latch(rg.Sim, 0x20) & 2) == 0;
        foreach (var b in new byte[] { 0xFF, 0x01, 0x00 }) { lg.Write([b]); lg.Wait(1); }
        lg.Run(0.4);
        bool offAgain = (Platform.Latch(rg.Sim, 0x20) & 2) != 0;
        Check("a serial input as a switch: GIO 1 on serial input 2 is off, on while 1 is sent, off again at 0", offFirst && onThen && offAgain,
              $"{(offFirst ? "off" : "on")} -> {(onThen ? "on" : "off")} -> {(offAgain ? "off" : "on")}");
        // without the stream: the core still takes them
        var r2 = Run(["FEAT_DATALOG", "FEAT_DLSERIALIN"], [], [Hold(1, e => { e.Rpm = 850; e.MapKpa = 33; })]);
        var l2 = new DatalogLayout.SimLink(r2.Sim);
        foreach (var b in new byte[] { 0xFF, 0x00, 0x2A }) { l2.Write([b]); l2.Wait(1); }
        l2.Run(0.05);
        Check("with the HTS frame and no stream: FFh 00h 2Ah stores 42 in input 1, and the 20h frame still answers",
              r2.Sim.Bus.Ram[SymOf(r2.Asm, "SERIN_RAM")] == 42 && new MultiByte20Probe().Try(l2), $"{r2.Sim.Bus.Ram[SymOf(r2.Asm, "SERIN_RAM")]}");
    }

    // ------------------------------------------------------------------ memory read (dlmemread.asm)
    static void Test_Dlmemread()
    {
        var r = Run(["FEAT_DLSTREAM", "FEAT_DLMEMREAD"], [], [Hold(1, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; })]);
        var link = new DatalogLayout.SimLink(r.Sim);
        var cs = new ChannelStream { PostWritePauseMs = 0 };
        bool hs = cs.Handshake(link, out var note);
        for (int i = 0; i < 5; i++) cs.Poll(link, 0, out _);
        var d = cs.ReadMemory(link, 0x0A0, out var n1);
        int period = d == null ? 0 : d[Platform.A(0xAC) - 0xA0] | (d[Platform.A(0xAD) - 0xA0] << 8);
        bool same = d != null && d[Platform.A(0xA3) - 0xA0] == r.Sim.Bus.Ram[Platform.A(0xA3)];
        Check("60h A0h: 32 bytes of RAM, the crank period at 0ACh and MAP at 0A3h as the ECU has them", hs && cs.HasMemoryRead && d != null && Math.Abs(1875000.0 / Math.Max(1, period) - 3000) < 60 && same,
              $"{note}; {n1}; period {period:X4}");
        int frames = 0;
        for (int i = 0; i < 20; i++) if (cs.Poll(link, 0, out _) != null) frames++;
        Check("  the stream carries on after it", frames >= 15, $"{frames} of 20");
        var sfr = cs.ReadMemory(link, 0x020, out var n2);
        var past = cs.ReadMemory(link, 0x470, out var n3);
        var rom = cs.ReadMemory(link, 0x4000, out _);
        Check("  the registers (20h) and past RAM (470h) are refused: the ROM is never sent", sfr == null && n2.Contains("refused") && past == null && n3.Contains("refused") && rom == null, $"{n2}; {n3}");
        var plain = new ChannelStream { PostWritePauseMs = 0 };
        var r2 = Run(["FEAT_DLSTREAM"], [], [Hold(1, e => { e.Rpm = 850; e.MapKpa = 33; })]);
        var l2 = new DatalogLayout.SimLink(r2.Sim);
        plain.Handshake(l2, out _);
        var none = plain.ReadMemory(l2, 0x0A0, out var n4);
        Check("without the module: the ident says so and nothing is asked", !plain.HasMemoryRead && none == null && n4.Contains("no memory read"), n4);
    }

    // ------------------------------------------------------------------ the QD3 frame
    static void Test_Dlqd3()
    {
        var r = Run(["FEAT_DLQD3", "FEAT_DLSTREAM"], [], [Hold(1, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; e.SpeedKmh = 90; e.EctCelsius = 85; })]);
        var link = new DatalogLayout.SimLink(r.Sim);
        var q = DatalogProtocol.ByName("QD3")!;
        q.PostWritePauseMs = 0;
        bool hs = q.Handshake(link, out var note);
        var f = hs ? q.Poll(link, 0, out note) : null;
        Check("QD3: ABh -> BCh, 46h -> the 40-byte frame (46h 26h first) and its checksum", hs && f != null && f.Raw is [0x46, 0x26, ..], note);
        Check("  rpm, MAP, speed and coolant read right", f != null && Math.Abs(f.Rpm!.Value - 3000) < 60 && Math.Abs(f.MapKpa!.Value - 60) < 4
              && Math.Abs(f.SpeedKmh!.Value - 90) < 4 && Math.Abs(f.EctC!.Value - 85) < 4,
              f == null ? "" : $"{f.Rpm} rpm, {f.MapKpa} kPa, {f.SpeedKmh} km/h, {f.EctC} C");
        Check("  the HTS / ISR frame is not there (a different protocol: one or the other)", !new MultiByte20Probe().Try(link), "");
        var cs = new ChannelStream { PostWritePauseMs = 0 };
        Check("  the channel stream goes with it", cs.Handshake(link, out var csNote) && cs.Poll(link, 0, out _) != null, csNote);
    }

    // ------------------------------------------------------------------ the service commands (dlservice.asm)
    /// A run that sends a command byte at each of the given times (seconds from the start, the 3 s of idle
    /// first included) and keeps every byte the ECU sent back, with the time it was read.
    static (RunResult R, List<(double T, byte B)> Answers) Serve(string[] defs, Dictionary<string, byte[]> cal,
        IEnumerable<(double Secs, Action<EngineState, double> Set)> steps, (double At, byte Cmd)[] sends, Action<Simulator, double>? watch = null)
    {
        int k = 0;
        var answers = new List<(double, byte)>();
        var pending = sends.OrderBy(s => s.At).ToList();
        var r = Run(defs, cal, steps, sim =>
        {
            double t = ++k * 0.01;
            foreach (var b in sim.Bus.TakeSerialTx()) answers.Add((t, b));
            while (pending.Count > 0 && pending[0].At <= t) { sim.Bus.QueueSerialRx([pending[0].Cmd], (uint)(Bus.CpuHz * 10 / 38400)); pending.RemoveAt(0); }
            watch?.Invoke(sim, t);
        });
        return (r, answers);
    }

    static string Said(List<(double T, byte B)> a) => string.Join(" ", a.Select(x => $"{x.B:X2}@{x.T:0.00}"));
    static byte? AnswerAfter(List<(double T, byte B)> a, double t) => a.Where(x => x.T > t && x.T < t + 0.2).Select(x => (byte?)x.B).FirstOrDefault();

    static void Service()
    {
        var idleSet = (Action<EngineState>)(e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0; });
        // injectors off at idle, then back on; the lamp flashes meanwhile and stops after
        int flashes = 0, after = 0, pinFlashes = 0; bool? was = null, pinWas = null;
        var (r, a) = Serve(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE"], [], [Hold(3, idleSet), Hold(3, idleSet), Hold(3, idleSet)], [(3.05, 0x51), (6.05, 0x52)],
            (sim, t) =>
            {
                bool lit = (Platform.Latch(sim, 0x22) & 0x10) != 0;
                if (was != null && lit != was) { if (t < 6.1) flashes++; else if (t > 6.3) after++; }
                was = lit;
                // and at the 8255's port C, where the lamp's driver is: the main loop copies the P1 latch there
                bool pin = (Platform.PortC(sim) & 0x10) != 0;
                if (pinWas != null && pin != pinWas && t > 3.1 && t < 6.1) pinFlashes++;
                pinWas = pin;
            });
        Check("  the flashing reaches the lamp's output (8255 port C bit 4), not just the latch", pinFlashes >= 16, $"{pinFlashes} changes at the port in 3 s");
        Check("51h: the injectors off (answer 51h), 52h: back on (52h)", r.InjPerSec[1] < 2 && Running(r) && AnswerAfter(a, 3.05) == 0x51 && AnswerAfter(a, 6.05) == 0x52,
            $"{r.InjPerSec[1]:0} inj/s off, {r.InjPerSec[2]:0} back on; answers {Said(a)}");
        Check("  the check-engine lamp flashes quickly while they are off, and stops after", flashes >= 16 && after == 0, $"{flashes} changes in 3 s, {after} after");
        // cranking with the injectors off: none at all (a flooded engine is cleared this way)
        var crankSet = (Action<EngineState>)(e => { e.Rpm = 250; e.MapKpa = 95; e.TpsPct = 0; });
        var (crank, _) = Serve(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE"], [], [Hold(3, crankSet)], [(0.5, 0x51)]);
        var (crankOn, _) = Serve(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE"], [], [Hold(3, crankSet)], []);
        Check("  cranking with them off: no fuel (with them on it gets its cranking fuel)", crank.InjPerSec[^1] < 1 && crankOn.InjPerSec[^1] > 5,
            $"{crank.InjPerSec[^1]:0} / {crankOn.InjPerSec[^1]:0} inj/s");
        // the timing locked at 16 degrees (58h), then normal again
        var (t, ta) = Serve(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE"], [], [Hold(3, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; }), Hold(3, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; })],
            [(3.05, 0x53), (6.05, 0x54)]);
        var normal = Run(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE"], [], [Hold(3, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; })]);
        Check("53h: the timing locked at 16 degrees (answer 53h), 54h: back to the map's", Math.Abs(t.Advance[1] - 0x58) <= 1 && Math.Abs(t.Advance[2] - normal.Advance[1]) <= (Platform.P13 ? 6 : 2)
              && Math.Abs(normal.Advance[1] - 0x58) > 4 && AnswerAfter(ta, 3.05) == 0x53 && AnswerAfter(ta, 6.05) == 0x54,
            $"advance {t.Advance[1]:0} locked, {t.Advance[2]:0} after, {normal.Advance[1]:0} normally (raw); answers {Said(ta)}");
        // the state (5Fh), everything off (5Eh), a command for a module that is not built (7Fh)
        var (_, sa) = Serve(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE"], [], [Hold(2, idleSet)], [(3.05, 0x51), (3.25, 0x53), (3.45, 0x5F), (3.65, 0x5E), (3.85, 0x5F), (4.05, 0x57), (4.25, 0x58)]);
        Check("5Fh: the state (injectors off, timing locked = 03h); 5Eh: all off (then 00h); maps or GIO not built: 7Fh",
            AnswerAfter(sa, 3.45) == 0x03 && AnswerAfter(sa, 3.65) == 0x5E && AnswerAfter(sa, 3.85) == 0x00 && AnswerAfter(sa, 4.05) == 0x7F && AnswerAfter(sa, 4.25) == 0x7F, Said(sa));
        // the secondary maps chosen over the datalog, whatever their switch says (it is off here)
        Dictionary<string, byte[]> Maps(int v) => new()
        {
            ["IgnitionLow2"] = Enumerable.Repeat((byte)v, 200).ToArray(), ["IgnitionHigh2"] = Enumerable.Repeat((byte)v, 200).ToArray(),
            ["dualmaps_enable"] = B(1, 0x10, 0),
        };
        var cruise = (Action<EngineState>)(e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 30; e.SpeedKmh = 60; });
        int mHi = Platform.P13 ? 0x70 : 0x30, mLo = mHi - 0x10;   // (P13: its cells are (x - 24) / 4 degrees; 70h is well under its stock map at cruise)
        var (m, ma) = Serve(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE", "FEAT_DUALMAPS"], Maps(mHi), [Hold(3, cruise), Hold(3, cruise), Hold(3, cruise)], [(3.05, 0x57), (6.05, 0x55)]);
        var (m2, _) = Serve(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE", "FEAT_DUALMAPS"], Maps(mLo), [Hold(3, cruise), Hold(3, cruise)], [(3.05, 0x57)]);
        var (first, _) = Serve(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE", "FEAT_DUALMAPS"], Maps(mHi), [Hold(3, cruise)], []);
        Check("57h: the secondary maps (their switch off); 55h: the switch again (the first maps)", Math.Abs(m.Advance[1] - m2.Advance[1] - 16) <= 2
              && Math.Abs(m.Advance[2] - first.Advance[1]) <= (Platform.P13 ? 6 : 2) && Math.Abs(m.Advance[1] - first.Advance[1]) > 8
              && AnswerAfter(ma, 3.05) == 0x57 && AnswerAfter(ma, 6.05) == 0x55,
            $"second map 30h / 20h: {m.Advance[1]:0} / {m2.Advance[1]:0}; the switch again {m.Advance[2]:0}, first maps {first.Advance[1]:0}; answers {Said(ma)}");
        // GIO 1 forced on (its rpm is never reached), then back to its own conditions
        // (the ECU LED, output 6, is not on the P13: the spare, output 11 (PB.6, written inverted), there - the lamp is the stock code's too)
        int gOut = Platform.P13 ? 11 : 6, gBit = Platform.P13 ? 0x40 : 0x20;
        bool GOn(Simulator sim) => Platform.P13 ? (~sim.Bus.Ppi.PortB & gBit) != 0 : (Platform.Latch(sim, 0x22) & gBit) != 0;
        var gio = new Dictionary<string, byte[]> { ["gio1_block"] = GioBlock(gOut, 8000, 7800) };
        bool onMid = false, onEnd = true;
        var (g, ga) = Serve(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE", "FEAT_GIO1"], gio, [Hold(3, idleSet), Hold(3, idleSet)], [(3.05, 0x58), (5.05, 0x58)],
            (sim, tt) => { if (Math.Abs(tt - 4.5) < 0.006) onMid = GOn(sim); if (tt > 8.9) onEnd = GOn(sim); });
        Check("58h: GIO 1 forced on (answer 58h), again: back to its conditions (answer 00h)", onMid && !onEnd && AnswerAfter(ga, 3.05) == 0x58 && AnswerAfter(ga, 5.05) == 0x00,
            $"LED {(onMid ? "on" : "off")} forced, {(onEnd ? "on" : "off")} after; answers {Said(ga)}");
        // the same through the app's own protocol: the channel stream stops for a command and streams on after it
        var rs = Run(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE"], [], [Hold(1, idleSet)]);
        var sl = new DatalogLayout.SimLink(rs.Sim);
        var cs = new ChannelStream { PostWritePauseMs = 0 };
        bool hs2 = cs.Handshake(sl, out _);
        for (int i = 0; i < 5; i++) cs.Poll(sl, 0, out _);
        var st0 = cs.Command(sl, 0x5F, out _); var a51 = cs.Command(sl, 0x51, out _); var st1 = cs.Command(sl, 0x5F, out _); var a52 = cs.Command(sl, 0x52, out _);
        int framesAfter = 0;
        for (int i = 0; i < 20; i++) if (cs.Poll(sl, 0, out _) != null) framesAfter++;
        Check("through the channel stream: the state 00h, 51h taken, the state 01h, 52h, and the stream goes on", hs2 && st0 == 0 && a51 == 0x51 && st1 == 1 && a52 == 0x52 && framesAfter >= 15,
            $"{st0:X2} {a51:X2} {st1:X2} {a52:X2}; {framesAfter} of 20 frames after");
        // the stored trouble codes: code 6 (coolant sensor) stored, read in the 20h frame, cleared with 50h
        var bad = Hold(4, e => { e.Rpm = 850; e.MapKpa = 33; e.EctCelsius = -60; });
        var good = Hold(4, e => { e.Rpm = 850; e.MapKpa = 33; e.EctCelsius = 85; });
        byte[]? frame = null;
        var (c, ca) = Serve(["FEAT_DATALOG", "FEAT_DLSTREAM", "FEAT_DLSERVICE", "FEAT_STOCK_DTC"], [], [bad, good, good], [(7.5, 0x20), (8.5, 0x50)],
            (sim, tt) => { });
        var got = ca.Where(x => x.T > 7.5 && x.T < 8.4).Select(x => x.B).ToArray();
        if (got.Length >= 52) frame = got[..52];
        bool inFrame = frame != null && (frame[12] & 0x20) != 0;
        bool cleared = c.Sim.Bus.Ram[Platform.A(0x31A)] == 0 && c.Sim.Bus.Ram[Platform.A(0x112)] == 0 && c.Sim.Bus.Ram[Platform.A(0x212)] == 0;
        Check("code 6 stored and in the 20h frame (byte 12, bit 5); 50h clears it (answer 50h), no reset", inFrame && cleared && !c.Halted && AnswerAfter(ca, 8.5) == 0x50,
            $"frame byte 12 = {(frame == null ? "(no frame)" : frame[12].ToString("X2"))}, stored now {c.Sim.Bus.Ram[Platform.A(0x31A)]:X2}{c.Sim.Bus.Ram[Platform.A(0x31B)]:X2}, halted {c.Halted}");
    }

    /// 10h -> CDh, then 20h -> the 51-byte frame and its checksum.
    sealed class MultiByte20Probe
    {
        public bool Try(IByteLink link)
        {
            link.Write([0x10]); var buf = new byte[64]; int n = link.Read(buf, 0, 64, 200);
            // anything left of the stream is still arriving: find CDh in it
            if (n == 0 || !buf.Take(n).Contains((byte)0xCD)) { link.Discard(); link.Write([0x10]); n = link.Read(buf, 0, 1, 200); if (n < 1 || buf[0] != 0xCD) return false; }
            link.Discard();
            link.Write([0x20]); n = 0; var f = new byte[52];
            while (n < 52) { int k = link.Read(f, n, 52 - n, 300); if (k <= 0) break; n += k; }
            return n == 52 && (f.Take(51).Sum(b => b) & 0xFF) == f[51];
        }
    }

    // the last step's injections and sparks per second, for the checks
    static string Rates(RunResult r) => $"{r.InjPerSec[^1]:0} inj/s, {r.IgnPerSec[^1]:0} sparks/s";
    static bool FuelCut(RunResult r) => r.InjPerSec[^1] < 2;      // no injector opens while any cut is held
    static bool SparkCut(RunResult r) => r.IgnPerSec[^1] < 10;
    static bool Running(RunResult r) => r.InjPerSec[^1] > 20 && r.IgnPerSec[^1] > 20;

    // ------------------------------------------------------------------ rev limiter
    static void Test_RevLimit()
    {
        var low = new Dictionary<string, byte[]> { ["revlimit_low"] = B(1), ["revlimit_cut"] = B(1), ["revlimit_low_set"] = W(P(4000)), ["revlimit_low_reset"] = W(P(3900)) };
        var at4500 = Hold(3, e => { e.Rpm = 4500; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = 80; });
        var at3500 = Hold(3, e => { e.Rpm = 3500; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = 80; });
        var at4040 = Hold(3, e => { e.Rpm = 4040; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = 80; });
        var ign = Run(["FEAT_REVLIMIT"], low, [at3500, (3, (e, t) => { e.Rpm = 3500 + 540 * t; e.MapKpa = 90; e.TpsPct = 80; e.SpeedKmh = 80; }), at4040]);
        Check("ignition cut at 4000: 4040 rpm (climbed to) has no spark, fuel still on", SparkCut(ign) && !FuelCut(ign), Rates(ign));
        var hard = Run(["FEAT_REVLIMIT"], low, [at4500]);
        Check("  4500 rpm, far past it (the ignition cut not holding it): the fuel goes too (the hard limit)", SparkCut(hard) && FuelCut(hard), Rates(hard));
        var below = Run(["FEAT_REVLIMIT"], low, [at3500]);
        Check("  3500 rpm runs", Running(below), Rates(below));
        var fuel = Run(["FEAT_REVLIMIT"], new(low) { ["revlimit_cut"] = B(0) }, [at4500]);
        Check("fuel cut: 4500 rpm has no fuel, spark still on", FuelCut(fuel) && !SparkCut(fuel), Rates(fuel));
        var both = Run(["FEAT_REVLIMIT"], new(low) { ["revlimit_cut"] = B(2) }, [at4500]);
        Check("both: neither", FuelCut(both) && SparkCut(both), Rates(both));
        // hysteresis: cut at 4000, fall to 3950 (inside the band) stays cut, 3850 is back in
        var band = Run(["FEAT_REVLIMIT"], low, [at4500, Hold(1, e => e.Rpm = 3950), Hold(1, e => e.Rpm = 3850)]);
        Check("  stays cut inside the band (3950), back in below it (3850)", band.IgnPerSec[2] < 5 && band.IgnPerSec[3] > 20,
            $"{band.IgnPerSec[2]:0} then {band.IgnPerSec[3]:0} sparks/s");
        // the high cam's own points: VTEC on at 7000 rpm WOT
        var at7000 = Hold(3, e => { e.Rpm = 7000; e.MapKpa = 100; e.TpsPct = 100; e.SpeedKmh = 120; });
        bool vtec = false;
        var hi = Run(["FEAT_REVLIMIT"], new(low) { ["revlimit_high"] = B(1), ["revlimit_high_cut"] = B(1), ["revlimit_high_set"] = W(P(6500)), ["revlimit_high_reset"] = W(P(6400)),
                                                   ["revlimit_low_set"] = W(P(9500)), ["revlimit_low_reset"] = W(P(9400)) }, [at7000], sim => vtec = (Platform.Latch(sim, 0x22) & 1) != 0);
        if (!vtec) { Console.WriteLine("  SKIP  high cam: the simulator does not engage VTEC on the skeleton at 7000 rpm WOT, so the high-cam points cannot be tried"); return; }
        Check("high cam (VTEC on at 7000): its own cut point (6500) applies", SparkCut(hi), Rates(hi));
        var hiOff = Run(["FEAT_REVLIMIT"], new(low) { ["revlimit_high"] = B(1), ["revlimit_high_set"] = W(P(9500)), ["revlimit_high_reset"] = W(P(9400)),
                                                      ["revlimit_low_set"] = W(P(6500)), ["revlimit_low_reset"] = W(P(6400)) }, [at7000]);
        Check("  and the low cam's (6500) does not while VTEC is on", Running(hiOff), Rates(hiOff));
    }

    // ------------------------------------------------------------------ launch control
    static void Test_Launch()
    {
        var on = Armed(new Dictionary<string, byte[]> { ["launch_block"] = B(1), ["launch_set"] = W(P(4000)), ["launch_reset"] = W(P(3900)), ["launch_speed"] = B(5) }, "launch_input");
        // the brake input (20h, the default) reads on in the simulator unless the switch buffer's bit 4 is high (P13: A/C, see Armed)
        var standing = Run(["FEAT_LAUNCH"], on, [Hold(3, e => { e.Rpm = 4500; e.MapKpa = 90; e.TpsPct = 100; e.SpeedKmh = 0; })], InputOn);
        Check("standing, input on, 4500 rpm: held at 4000 (ignition cut)", SparkCut(standing), Rates(standing));
        var moving = Run(["FEAT_LAUNCH"], on, [Hold(3, e => { e.Rpm = 4500; e.MapKpa = 90; e.TpsPct = 100; e.SpeedKmh = 30; })], InputOn);
        Check("rolling (30 km/h): off", Running(moving), Rates(moving));
        var released = Run(["FEAT_LAUNCH"], on, [Hold(3, e => { e.Rpm = 4500; e.MapKpa = 90; e.TpsPct = 100; e.SpeedKmh = 0; })], InputOff);
        Check("input off: off", Running(released), Rates(released));
        var inverted = Run(["FEAT_LAUNCH"], new(on) { ["launch_invert"] = B(1) }, [Hold(3, e => { e.Rpm = 4500; e.MapKpa = 90; e.TpsPct = 100; e.SpeedKmh = 0; })], InputOff);
        Check("inverted input, input off: armed", SparkCut(inverted), Rates(inverted));
        var below = Run(["FEAT_LAUNCH"], on, [Hold(3, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 40; e.SpeedKmh = 0; })]);
        Check("standing below the launch rpm: runs", Running(below), Rates(below));
    }

    static (double, Action<EngineState, double>) At(double rpm, double map, double tps, double kmh, Action<EngineState>? more = null)
        => Hold(3, e => { e.Rpm = rpm; e.MapKpa = map; e.TpsPct = tps; e.SpeedKmh = kmh; more?.Invoke(e); });
    static int MapRaw(double kpa) => (int)Math.Round((kpa * 10 + 59) / 7.221);

    // ------------------------------------------------------------------ full throttle shift
    static void Test_Fts()
    {
        var on = Armed(new Dictionary<string, byte[]> { ["fts_block"] = B(1), ["fts_set"] = W(P(5300)), ["fts_reset"] = W(P(5200)) }, "fts_input");
        var shift = Run(["FEAT_FTS"], on, [At(6000, 100, 100, 60)], InputOn);
        Check("moving, flat out, shift input on, 6000 rpm: held at 5300", SparkCut(shift), Rates(shift));
        var slow = Run(["FEAT_FTS"], on, [At(6000, 100, 100, 5)], InputOn);
        Check("below its road speed (5 km/h): left to launch control", Running(slow), Rates(slow));
        var part = Run(["FEAT_FTS"], on, [At(6000, 70, 50, 60)], InputOn);
        Check("half throttle: off", Running(part), Rates(part));
        var noinput = Run(["FEAT_FTS"], on, [At(6000, 100, 100, 60)], InputOff);
        Check("shift input off: off", Running(noinput), Rates(noinput));
    }

    /// The brake input the launch and flat shift checks arm on: not traced on the P13 (it reads off there), so on it they
    /// arm on the A/C switch (10h) instead. InputOn / InputOff: the input on, off (P30: the brake reads on unless the
    /// switch buffer's bit 4 is high).
    static Dictionary<string, byte[]> Armed(Dictionary<string, byte[]> cal, string input) => Platform.P13 ? new(cal) { [input] = B(0x10) } : cal;
    static Action<Simulator>? InputOn => Platform.P13 ? sim => sim.Engine.AcRequest = true : null;
    static Action<Simulator> InputOff => Platform.P13 ? sim => sim.Engine.AcRequest = false : sim => sim.Bus.SwitchLatch = 0x10;

    // ------------------------------------------------------------------ burnout
    static void Test_Burnout()
    {
        var on = new Dictionary<string, byte[]> { ["burnout_block"] = B(1) };        // A/C input, 3750 rpm, fuel cut, below 20 km/h
        var burn = Run(["FEAT_BURNOUT"], on, [At(4500, 90, 100, 0, e => e.AcRequest = true)]);
        Check("input (A/C) on, standing, 4500 rpm: held at 3750 (fuel cut)", FuelCut(burn), Rates(burn));
        var off = Run(["FEAT_BURNOUT"], on, [At(4500, 90, 100, 0)]);
        Check("input off: runs", Running(off), Rates(off));
        var rolling = Run(["FEAT_BURNOUT"], on, [At(4500, 90, 100, 40, e => e.AcRequest = true)]);
        Check("rolling (40 km/h): runs", Running(rolling), Rates(rolling));
    }

    // ------------------------------------------------------------------ boost cut
    static void Test_BoostCut()
    {
        var on = new Dictionary<string, byte[]> { ["boostcut_block"] = B(1), ["boostcut_hot"] = B(MapRaw(90)), ["boostcut_cold"] = B(MapRaw(70)) };
        var over = Run(["FEAT_BOOSTCUT"], on, [At(4000, 100, 100, 80)]);
        Check("warm, 100 kPa against a 90 kPa cut: fuel cut", FuelCut(over), Rates(over));
        var under = Run(["FEAT_BOOSTCUT"], on, [At(4000, 80, 100, 80)]);
        Check("warm, 80 kPa: runs", Running(under), Rates(under));
        var cold = Run(["FEAT_BOOSTCUT"], on, [At(4000, 80, 100, 80, e => e.EctCelsius = 20)], ect: 20);
        Check("cold (20 C), 80 kPa against the 70 kPa cold cut: fuel cut", FuelCut(cold), Rates(cold));
        var back = Run(["FEAT_BOOSTCUT"], on, [At(4000, 100, 100, 80), At(4000, 88, 100, 80), At(4000, 85, 100, 80)]);
        Check("back in once the pressure drops a little under the cut (88 kPa stays cut, 85 runs)", back.InjPerSec[2] < 5 && back.InjPerSec[3] > 20,
            $"{back.InjPerSec[2]:0} then {back.InjPerSec[3]:0} inj/s");
    }

    // ------------------------------------------------------------------ coolant protection
    static void Test_EctPro()
    {
        var on = new Dictionary<string, byte[]> { ["ectpro_block"] = B(1) };          // 5000 rpm above about 110 C, fuel cut
        var hot = Run(["FEAT_ECTPRO"], on, [At(5500, 90, 80, 100, e => e.EctCelsius = 130)], ect: 130);   // the simulator thermistor reads cooler than the HTS curve: 130 C here is past 110 C there
        Check("130 C, 5500 rpm: held at 5000 (fuel cut)", FuelCut(hot), Rates(hot));
        var warm = Run(["FEAT_ECTPRO"], on, [At(5500, 90, 80, 100)]);
        Check("85 C, 5500 rpm: runs", Running(warm), Rates(warm));
        var hotslow = Run(["FEAT_ECTPRO"], on, [At(3000, 60, 30, 60, e => e.EctCelsius = 118)], ect: 118);
        Check("118 C, 3000 rpm: runs", Running(hotslow), Rates(hotslow));
        // the warm-up limit: 4000 rpm below about 40 C (fuel cut)
        var cold = new Dictionary<string, byte[]> { ["ectpro_cold_block"] = B(1) };
        var coldHigh = Run(["FEAT_ECTPRO"], cold, [At(4500, 90, 80, 100, e => e.EctCelsius = 20)], ect: 20);
        Check("warm-up limit: 20 C, 4500 rpm: held at 4000 (fuel cut)", FuelCut(coldHigh), Rates(coldHigh));
        var coldLow = Run(["FEAT_ECTPRO"], cold, [At(3000, 60, 30, 60, e => e.EctCelsius = 20)], ect: 20);
        Check("  20 C, 3000 rpm: runs", Running(coldLow), Rates(coldLow));
        var warmHigh = Run(["FEAT_ECTPRO"], cold, [At(4500, 90, 80, 100)]);
        Check("  85 C, 4500 rpm: runs", Running(warmHigh), Rates(warmHigh));
        var coldOff = Run(["FEAT_ECTPRO"], on, [At(4500, 90, 80, 100, e => e.EctCelsius = 20)], ect: 20);
        Check("  warm-up limit off: 20 C, 4500 rpm runs", Running(coldOff), Rates(coldOff));
    }

    // ------------------------------------------------------------------ sensor protection
    static void Test_SensorPro()
    {
        // an oil pressure sender on analog input 3 (B6; the P13's TCS pin): under 1.0 V above 3000 rpm for 512 ms cuts fuel and spark
        var on = new Dictionary<string, byte[]> { ["sensorpro_block"] = B(1) };
        var lost = Run(["FEAT_SENSORPRO"], on, [At(4000, 90, 60, 100, e => e.AnalogOverrides[Platform.AuxAdc] = 0.3)]);
        Check("0.3 V at 4000 rpm: cut (fuel and spark)", FuelCut(lost) && SparkCut(lost), Rates(lost));
        var fine = Run(["FEAT_SENSORPRO"], on, [At(4000, 90, 60, 100, e => e.AnalogOverrides[Platform.AuxAdc] = 3.0)]);
        Check("3.0 V at 4000 rpm: runs", Running(fine), Rates(fine));
        var slow = Run(["FEAT_SENSORPRO"], on, [At(2000, 60, 30, 40, e => e.AnalogOverrides[Platform.AuxAdc] = 0.3)]);
        Check("0.3 V at 2000 rpm (under the point): runs", Running(slow), Rates(slow));
        var home = Run(["FEAT_SENSORPRO"], on, [At(4000, 90, 60, 100, e => e.AnalogOverrides[Platform.AuxAdc] = 0.3), At(2500, 60, 30, 60, e => e.AnalogOverrides[Platform.AuxAdc] = 0.3)]);
        Check("cut, then back under the rpm: it lets go", FuelCut(home) == false && Running(home), Rates(home));
        var back = Run(["FEAT_SENSORPRO"], on, [At(4000, 90, 60, 100, e => e.AnalogOverrides[Platform.AuxAdc] = 0.3), At(4000, 90, 60, 100, e => e.AnalogOverrides[Platform.AuxAdc] = 3.0)]);
        Check("cut, then the reading back: it lets go", Running(back), Rates(back));
        var above = new Dictionary<string, byte[]>(on) { ["sensorpro_side"] = B(1) };
        var hi = Run(["FEAT_SENSORPRO"], above, [At(4000, 90, 60, 100, e => e.AnalogOverrides[Platform.AuxAdc] = 3.0)]);
        Check("cut above the level: 3.0 V at 4000 rpm cuts", FuelCut(hi) && SparkCut(hi), Rates(hi));
        var lo = Run(["FEAT_SENSORPRO"], above, [At(4000, 90, 60, 100, e => e.AnalogOverrides[Platform.AuxAdc] = 0.3)]);
        Check("  0.3 V runs", Running(lo), Rates(lo));
        var off = Run(["FEAT_SENSORPRO"], [], [At(4000, 90, 60, 100, e => e.AnalogOverrides[Platform.AuxAdc] = 0.3)]);
        Check("disabled: runs", Running(off), Rates(off));
    }

    // ------------------------------------------------------------------ anti-start
    static void Test_AntiStart()
    {
        var on = new Dictionary<string, byte[]> { ["antistart_enable"] = B(1) };
        var idle = Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.AcRequest = false; });
        var locked = RunRaw(["FEAT_ANTISTART"], on, [idle, idle]);
        Check("enabled: powers up with no fuel and no spark", FuelCut(locked) && SparkCut(locked), Rates(locked));
        var tpsOnly = RunRaw(["FEAT_ANTISTART"], on, [idle, Hold(1, e => e.TpsPct = 100), idle]);
        Check("  full throttle alone does not unlock it", FuelCut(tpsOnly), Rates(tpsOnly));
        var acOnly = RunRaw(["FEAT_ANTISTART"], on, [idle, Hold(1, e => e.AcRequest = true), idle]);
        Check("  the A/C switch alone does not", FuelCut(acOnly), Rates(acOnly));
        var unlocked = RunRaw(["FEAT_ANTISTART"], on, [idle, Hold(1, e => { e.AcRequest = true; e.TpsPct = 95; }), idle]);
        Check("  A/C on with the throttle past the point: unlocked, and it stays so", Running(unlocked), Rates(unlocked));
        var off = RunRaw(["FEAT_ANTISTART"], [], [idle, idle]);
        Check("disabled: starts", Running(off), Rates(off));
        var none = new Dictionary<string, byte[]>(on) { ["antistart_input"] = B(0x80) };
        var thr = RunRaw(["FEAT_ANTISTART"], none, [idle, Hold(1, e => e.TpsPct = 95), idle]);
        Check("input 'none': the throttle alone unlocks it", Running(thr), Rates(thr));
        var inv = new Dictionary<string, byte[]>(on) { ["antistart_invert"] = B(1) };
        // (A/C kept on as the throttle closes: switched off in the same instant, the P13's throttle reading - a main-loop
        // pass behind the switch - is still open for a moment with the inverted input on, which unlocks it)
        var invAc = RunRaw(["FEAT_ANTISTART"], inv, [idle, Hold(1, e => { e.AcRequest = true; e.TpsPct = 95; }), Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.AcRequest = true; })]);
        var invOff = RunRaw(["FEAT_ANTISTART"], inv, [idle, Hold(1, e => { e.AcRequest = false; e.TpsPct = 95; }), idle]);
        Check("inverted: A/C off with the throttle unlocks it, A/C on does not", Running(invOff) && FuelCut(invAc), $"off: {Rates(invOff)}; on: {Rates(invAc)}");
    }

    // ------------------------------------------------------------------ trouble codes: the check-engine mask
    static void Test_Stock_Dtc()
    {
        // the coolant sensor open circuit (code 6): stored, unless the mask switches code 6 off
        var bad = Hold(4, e => { e.Rpm = 850; e.MapKpa = 33; e.EctCelsius = -60; });
        // the stored codes: one bit per code (code n at bit n-1) at 31Ah (kept), 112h and 212h
        // (the P13: 330h-333h, the same bit for each code)
        static bool Stored(RunResult r, int code) => (r.Sim.Bus.Ram[Platform.A(0x31A) + (code - 1) / 8] >> ((code - 1) % 8) & 1) != 0;
        static string Codes(RunResult r) => $"stored {r.Sim.Bus.Ram[Platform.A(0x31A)]:X2}{r.Sim.Bus.Ram[Platform.A(0x31B)]:X2}{r.Sim.Bus.Ram[Platform.A(0x31C)]:X2}{r.Sim.Bus.Ram[Platform.A(0x31D)]:X2}";
        var on = Run(["FEAT_STOCK_DTC"], [], [bad]);
        Check("coolant sensor open: code 6 stored", Stored(on, 6), Codes(on));
        var off = Run(["FEAT_STOCK_DTC"], new() { ["CheckEngineCodes"] = B(0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF) }, [bad]);
        Check("  code 6 switched off for the check-engine lamp: not stored", !Stored(off, 6), Codes(off));
        Check("  and its fail-safe still works (the same coolant value used as with the code on)", on.Sim.Bus.Ram[Platform.A(0xC1)] == off.Sim.Bus.Ram[Platform.A(0xC1)] && Running(off),
            $"coolant byte {on.Sim.Bus.Ram[Platform.A(0xC1)]:X2} / {off.Sim.Bus.Ram[Platform.A(0xC1)]:X2}, {Rates(off)}");
        var good = Run(["FEAT_STOCK_DTC"], [], [Hold(4, e => { e.Rpm = 850; e.MapKpa = 33; })]);
        Check("a good sensor: nothing stored", !Stored(good, 6), Codes(good));
    }

    // ------------------------------------------------------------------ rolling idle
    static void Test_RollIdle()
    {
        var idle = Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0; });
        var cruise = At(3000, 60, 20, 90);
        var baseIdle = Run(["FEAT_ROLLIDLE"], [], [idle, cruise]);
        var inj = Run(["FEAT_ROLLIDLE"], new() { ["rollidle_enable"] = B(1), ["rollidle_every"] = B(5) }, [idle, cruise]);
        double r = inj.InjPerSec[1] / baseIdle.InjPerSec[1];
        Check("injectors, 1 in 5: a fifth of the idle injections left out, the sparks all there", r > 0.72 && r < 0.88 && inj.IgnPerSec[1] > baseIdle.IgnPerSec[1] * 0.95,
            $"{baseIdle.InjPerSec[1]:0} -> {inj.InjPerSec[1]:0} inj/s, {inj.IgnPerSec[1]:0} sparks/s");
        Check("  off at 3000 rpm and 90 km/h", Math.Abs(inj.InjPerSec[2] - baseIdle.InjPerSec[2]) <= Math.Max(3, baseIdle.InjPerSec[2] * 0.05), $"{baseIdle.InjPerSec[2]:0} / {inj.InjPerSec[2]:0} inj/s");
        // for the datalog: the injector left out last and how many have been
        {
            int cylAt = (int)inj.Asm.Symbols.Values.First(x => x.Name.Equals("rollidle_cyl", StringComparison.OrdinalIgnoreCase)).Value;
            byte pat = inj.Sim.Bus.Ram[cylAt], drops = inj.Sim.Bus.Ram[cylAt + 1];
            Check("  the datalog bytes: the injector left out last (1 bits: P2.0-P2.3) and the count of them", pat is > 0 and <= 0x0F && drops > 5,
                  $"pattern {pat:X2}h, {drops} left out");
        }
        uint dwellMax = 0, dwell0 = 0; int seen = 0;
        Run(["FEAT_ROLLIDLE"], [], [idle], sim => dwell0 = Math.Max(dwell0, sim.Bus.LastDwellUs));
        // the miss moves round all four cylinders: each injector loses about the same share
        var per0 = new long[4]; var per1 = new long[4]; int k5 = 0;
        Run(["FEAT_ROLLIDLE"], new() { ["rollidle_enable"] = B(1), ["rollidle_every"] = B(5) }, [idle],
            sim => { k5++; if (k5 == 100) Array.Copy(sim.Bus.InjectorEvents, per0, 4); if (k5 == 300) Array.Copy(sim.Bus.InjectorEvents, per1, 4); });
        var each = per1.Zip(per0, (a, b) => (double)(a - b)).ToArray();
        Check("  1 in 5: every cylinder misses in turn (each injector's count within 10 % of the others)", each.Min() > 0 && each.Min() / each.Max() > 0.9,
            string.Join(" / ", each.Select(x => x.ToString("0"))));
        var ign = Run(["FEAT_ROLLIDLE"], new() { ["rollidle_enable"] = B(1), ["rollidle_mode"] = B(1), ["rollidle_every"] = B(4) }, [idle, cruise],
                      sim => { if (++seen > 300 && seen < 600) dwellMax = Math.Max(dwellMax, sim.Bus.LastDwellUs); });
        double s = ign.IgnPerSec[1] / baseIdle.IgnPerSec[1];
        Check("sparks, set to 4: taken as 1 in 5 (odd), a fifth of the idle sparks left out, the injections all there", s > 0.72 && s < 0.88 && ign.InjPerSec[1] > baseIdle.InjPerSec[1] * 0.95,
            $"{baseIdle.IgnPerSec[1]:0} -> {ign.IgnPerSec[1]:0} sparks/s, {ign.InjPerSec[1]:0} inj/s");
        Check("  every spark that does fire has its normal dwell (none late)", dwellMax <= dwell0 + 500, $"longest dwell {dwellMax / 1000.0:0.0} ms, {dwell0 / 1000.0:0.0} ms without");
        Check("  off at 3000 rpm", Math.Abs(ign.IgnPerSec[2] - baseIdle.IgnPerSec[2]) <= Math.Max(3, baseIdle.IgnPerSec[2] * 0.05) && (ign.Sim.Bus.Ram[0xFC] & 2) == 0,
            $"{baseIdle.IgnPerSec[2]:0} / {ign.IgnPerSec[2]:0} sparks/s");
        // whichever of its two interrupts a spark's count lands on, and whatever the count: one spark in N
        var odd = new List<string>();
        foreach (var (every, lead, real) in new[] { (3, 0.37, 3), (5, 0.61, 5), (7, 1.13, 7), (2, 0.2, 3), (40, 0.5, 19) })
        {
            var x = Run(["FEAT_ROLLIDLE"], new() { ["rollidle_enable"] = B(1), ["rollidle_mode"] = B(1), ["rollidle_every"] = B(every) },
                        [Hold(lead, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 30; }), idle]);
            double want = 1 - 1.0 / real, got = x.IgnPerSec[2] / baseIdle.IgnPerSec[1];
            if (Math.Abs(got - want) > 0.08) odd.Add($"set {every} (1 in {real}): {got:P0} of the sparks, not {want:P0}");
        }
        Check("  1 in 3, 5 and 7, started at different moments; 2 is taken as 3, 40 as 19: that share left out", odd.Count == 0, string.Join("; ", odd));
        var sw = Run(["FEAT_ROLLIDLE"], new() { ["rollidle_enable"] = B(1), ["rollidle_input"] = B(0x10) }, [idle]);
        var swOn = Run(["FEAT_ROLLIDLE"], new() { ["rollidle_enable"] = B(1), ["rollidle_input"] = B(0x10) }, [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.AcRequest = true; })]);
        Check("on the A/C switch: only while it is on", sw.InjPerSec[1] > baseIdle.InjPerSec[1] * 0.95 && swOn.InjPerSec[1] < baseIdle.InjPerSec[1] * 0.9,
            $"off {sw.InjPerSec[1]:0}, on {swOn.InjPerSec[1]:0} inj/s");
    }

    // ------------------------------------------------------------------ speed limiter
    static void Test_SpeedLimit()
    {
        var always = new Dictionary<string, byte[]> { ["speedlim_block"] = B(1), ["speedlim_speed"] = B(96) };
        var fast = Run(["FEAT_SPEEDLIMIT"], always, [At(4000, 70, 40, 100)]);
        Check("always, 100 km/h against 96: fuel cut", FuelCut(fast), Rates(fast));
        var slow = Run(["FEAT_SPEEDLIMIT"], always, [At(3500, 60, 30, 90)]);
        Check("90 km/h: runs", Running(slow), Rates(slow));
        var sw = new Dictionary<string, byte[]>(always) { ["speedlim_input"] = B(0x10) };   // on the A/C switch
        var swOff = Run(["FEAT_SPEEDLIMIT"], sw, [At(4000, 70, 40, 100)]);
        var swOn = Run(["FEAT_SPEEDLIMIT"], sw, [At(4000, 70, 40, 100, e => e.AcRequest = true)]);
        Check("on a switch: only while it is on", Running(swOff) && FuelCut(swOn), $"off: {Rates(swOff)}; on: {Rates(swOn)}");
    }

    // ------------------------------------------------------------------ rpm ceilings by road speed
    static void Test_Ceiling()
    {
        // 50 km/h and up: no ceiling (12500 rpm); below 50: 3000 rpm
        var t = new byte[] { 200, 0x96, 0, 150, 0x96, 0, 100, 0x96, 0, 50, 0x96, 0, 0, (byte)P(3000), (byte)(P(3000) >> 8) };
        var on = new Dictionary<string, byte[]> { ["ceiling_block"] = B(1), ["ceiling_table"] = t };
        var slow = Run(["FEAT_CEILING"], on, [At(4000, 70, 40, 20)]);
        Check("20 km/h, 4000 rpm against a 3000 rpm ceiling: cut", FuelCut(slow), Rates(slow));
        var fast = Run(["FEAT_CEILING"], on, [At(4000, 70, 40, 60)]);
        Check("60 km/h, 4000 rpm (no ceiling there): runs", Running(fast), Rates(fast));
        var low = Run(["FEAT_CEILING"], on, [At(2500, 50, 20, 20)]);
        Check("20 km/h, 2500 rpm: runs", Running(low), Rates(low));
    }

    // an output the modules drive: its latch bit, as the skeleton copies it out
    static bool P0(RunResult r, int bit) => (Platform.Latch(r.Sim, 0x20) & (1 << bit)) != 0;
    static bool P1(RunResult r, int bit) => (Platform.Latch(r.Sim, 0x22) & (1 << bit)) != 0;

    // ------------------------------------------------------------------ IAB
    static void Test_Iab()
    {
        var on = new Dictionary<string, byte[]> { ["iab_enable"] = B(1), ["iab_engage"] = W(P(5000)), ["iab_disengage"] = W(P(4800)), ["iab_output"] = B(2) };
        var high = Run(["FEAT_IAB"], on, [At(6000, 100, 100, 100)]);
        Check("6000 rpm: open (P0.1 driven low)", !P0(high, 1), $"P0 = {Platform.Latch(high.Sim, 0x20):X2}");
        var low = Run(["FEAT_IAB"], on, [At(3000, 60, 30, 60)]);
        Check("3000 rpm: shut (P0.1 back to the skeleton level, high)", P0(low, 1), $"P0 = {Platform.Latch(low.Sim, 0x20):X2}");
        var band = Run(["FEAT_IAB"], on, [At(6000, 100, 100, 100), At(4900, 90, 80, 100)]);
        Check("  opened at 6000, stays open at 4900 (inside the band)", !P0(band, 1), $"P0 = {Platform.Latch(band.Sim, 0x20):X2}");
        var band2 = Run(["FEAT_IAB"], on, [At(6000, 100, 100, 100), At(4700, 90, 80, 100)]);
        Check("  and shuts at 4700", P0(band2, 1), $"P0 = {Platform.Latch(band2.Sim, 0x20):X2}");
        var off = Run(["FEAT_IAB"], [], [At(6000, 100, 100, 100)]);
        Check("disabled: the pin is the skeleton one", P0(off, 1), $"P0 = {Platform.Latch(off.Sim, 0x20):X2}");
    }

    // ------------------------------------------------------------------ rpm switch
    static void Test_RpmSwitch()
    {
        var on = new Dictionary<string, byte[]> { ["rpmsw_enable"] = B(1), ["rpmsw_tps"] = B(127) };   // LED (P1.5), above 4970 rpm and 50 % throttle
        var high = Run(["FEAT_RPMSWITCH"], on, [At(6000, 100, 100, 100)]);
        Check("6000 rpm, full throttle: on (P1.5 high)", P1(high, 5), $"P1 = {Platform.Latch(high.Sim, 0x22):X2}");
        var closed = Run(["FEAT_RPMSWITCH"], on, [At(6000, 40, 10, 100)]);
        Check("6000 rpm, 10 % throttle: off", !P1(closed, 5), $"P1 = {Platform.Latch(closed.Sim, 0x22):X2}");
        var low = Run(["FEAT_RPMSWITCH"], on, [At(3000, 90, 100, 60)]);
        Check("3000 rpm: off", !P1(low, 5), $"P1 = {Platform.Latch(low.Sim, 0x22):X2}");
    }

    // ------------------------------------------------------------------ warning lamp
    static void Test_WarnLamp()
    {
        var on = new Dictionary<string, byte[]> { ["warnlamp_enable"] = B(1) };
        var hot = Run(["FEAT_WARNLAMP"], on, [At(2500, 50, 20, 60, e => e.EctCelsius = 130)], ect: 130);
        Check("130 C: lamp on", P1(hot, 4), $"P1 = {Platform.Latch(hot.Sim, 0x22):X2}");
        var fine = Run(["FEAT_WARNLAMP"], on, [At(2500, 50, 20, 60)]);
        Check("85 C, 14.2 V: lamp off", !P1(fine, 4), $"P1 = {Platform.Latch(fine.Sim, 0x22):X2}");
        var flat = Run(["FEAT_WARNLAMP"], on, [At(2500, 50, 20, 60, e => e.VbattVolts = 11.0)]);
        Check("11.0 V with the engine running: lamp on", P1(flat, 4), $"P1 = {Platform.Latch(flat.Sim, 0x22):X2}");
    }

    static int Word(RunResult r, int a)
    {
        // lib.asm's trim words move with module RAM (31Ah without the stock trouble codes, 3F8h with them): read the build's
        if (a == FuelSum) a = ModSym(r, "MOD_FUELSUM");
        else if (a == IgnSum) a = ModSym(r, "MOD_IGNSUM");
        else a = Platform.A(a);
        return r.Sim.Bus.Ram[a] | (r.Sim.Bus.Ram[a + 1] << 8);
    }
    static int ModSym(RunResult r, string name) => (int)r.Asm.Symbols.Values.First(s => s.Name.Equals(name, StringComparison.OrdinalIgnoreCase)).Value;
    static int Signed(int w) => w >= 0x8000 ? w - 0x10000 : w;
    const int FuelSum = -1, IgnSum = -2;
    static int Gear => Platform.A(0x2FE);
    static int Advance => Platform.A(0x2FC);
    static int Retard => Platform.A(0x2FD);
    /// Rpm per km/h in each gear of the default boundaries' gearbox, and a run at 3000 rpm in that gear.
    static readonly double[] RpmPerKmh = [0, 136, 81, 56, 42, 34];
    static (double, Action<EngineState, double>) InGear(int g, double rpm = 3000, double map = 60, double tps = 30)
        => At(rpm, map, tps, rpm / RpmPerKmh[g]);

    // ------------------------------------------------------------------ gear detection
    static void Test_Gear()
    {
        for (int g = 1; g <= 5; g++)
        {
            var r = Run(["FEAT_GEAR"], [], [InGear(g)]);
            Check($"3000 rpm at {3000 / RpmPerKmh[g]:0} km/h: gear {g}", r.Sim.Bus.Ram[Gear] == g, $"gear {r.Sim.Bus.Ram[Gear]}");
        }
        var stand = Run(["FEAT_GEAR"], [], [At(2000, 40, 10, 0)]);
        Check("standing: gear 0", stand.Sim.Bus.Ram[Gear] == 0, $"gear {stand.Sim.Bus.Ram[Gear]}");
        var clutch = Run(["FEAT_GEAR"], [], [At(1500, 30, 0, 120)]);
        Check("1500 rpm at 120 km/h (no gear that tall: clutch in): gear 0", clutch.Sim.Bus.Ram[Gear] == 0, $"gear {clutch.Sim.Bus.Ram[Gear]}");
    }

    /// The share of the run P4.3 was high, sampled every 10 ms.
    static double Duty(string[] defs, Dictionary<string, byte[]> cal, (double, Action<EngineState, double>) step)
    {
        // the watch runs every 10 ms from the idle start: count only the second step
        int on = 0, n = 0, slice = 0;
        Run(defs, cal, [step, step], sim => { if (++slice <= 600) return; n++; if (Platform.A17(sim)) on++; });
        return n == 0 ? 0 : on * 100.0 / n;
    }

    // ------------------------------------------------------------------ electronic boost control
    static void Test_Ebc()
    {
        var open = new Dictionary<string, byte[]> { ["ebc_enable"] = B(1), ["ebc_duty"] = B(60, 60, 60, 60, 60, 60, 60, 60, 60) };
        double d = Duty(["FEAT_EBC"], open, At(4000, 100, 100, 80));
        Check("open loop, 60 % base duty: P4.3 on about 60 % of the time", Math.Abs(d - 60) < 8, $"{d:0} %");
        double low = Duty(["FEAT_EBC"], open, At(4000, 60, 30, 80));
        Check("throttle below the point: solenoid off", low < 2, $"{low:0} %");
        var closed = new Dictionary<string, byte[]>(open) { ["ebc_gain"] = B(64), ["ebc_target"] = B(Enumerable.Repeat(MapRaw(150), 9).ToArray()) };
        double up = Duty(["FEAT_EBC"], closed, At(4000, 100, 100, 80));
        Check("closed loop, 100 kPa against a 150 kPa target: more duty, held at the 90 % ceiling", Math.Abs(up - 90) < 8, $"{up:0} %");
        double off = Duty(["FEAT_EBC"], [], At(4000, 100, 100, 80));
        Check("disabled: off", off < 2, $"{off:0} %");
        // the cap by gear: 30 % in every gear but 0 (neutral / not known)
        var byGear = new Dictionary<string, byte[]>(open) { ["ebc_gearmax"] = B(100, 30, 30, 30, 30, 30) };
        double inGear = Duty(["FEAT_EBC", "FEAT_GEAR"], byGear, At(4000, 100, 100, 80));
        Check("by gear: 60 % base, 30 % cap in gear: about 30 %", Math.Abs(inGear - 30) < 8, $"{inGear:0} %");
        double neutral = Duty(["FEAT_EBC", "FEAT_GEAR"], byGear, At(4000, 100, 100, 0));
        Check("  standing (gear 0, no cap): 60 %", Math.Abs(neutral - 60) < 8, $"{neutral:0} %");
        double noGear = Duty(["FEAT_EBC"], byGear, At(4000, 100, 100, 80));
        Check("  without gear detection the cap does nothing: 60 %", Math.Abs(noGear - 60) < 8, $"{noGear:0} %");
    }

    // ------------------------------------------------------------------ manual boost
    static void Test_BoostManual()
    {
        var on = new Dictionary<string, byte[]> { ["boostman_enable"] = B(1), ["boostman_duty"] = B(40) };
        double d = Duty(["FEAT_BOOSTMANUAL"], on, At(4500, 100, 100, 80));
        Check("above 3570 rpm, flat out: 40 %", Math.Abs(d - 40) < 8, $"{d:0} %");
        double low = Duty(["FEAT_BOOSTMANUAL"], on, At(3000, 100, 100, 80));
        Check("below the rpm: off", low < 2, $"{low:0} %");
    }

    // ------------------------------------------------------------------ GIO
    // a GIO block: enable, output, invert, input, input invert, rpm on/off, then the windows (any), delays and mode
    static byte[] GioBlock(int output, int rpmOn, int rpmOff, int tpsMin = 0, int input = 0x80, int onDelay = 0, int offDelay = 0, int flash = 0) =>
        [1, (byte)Platform.Out(output), 0, (byte)input, 0, (byte)P(rpmOn), (byte)(P(rpmOn) >> 8), (byte)P(rpmOff), (byte)(P(rpmOff) >> 8),
         (byte)tpsMin, 255, 0, 255, 255, 0, 255, 0, 255, 0, 255, 0, (byte)onDelay, (byte)offDelay, (byte)flash];

    static void Test_Gio1()
    {
        var cal = new Dictionary<string, byte[]> { ["gio1_block"] = GioBlock(2, 4000, 3800, tpsMin: 127) };
        var high = Run(["FEAT_GIO1"], cal, [At(5000, 100, 100, 100)]);
        Check("5000 rpm, full throttle: on (P0.1 low)", !P0(high, 1), $"P0 = {Platform.Latch(high.Sim, 0x20):X2}");
        var part = Run(["FEAT_GIO1"], cal, [At(5000, 60, 30, 100)]);
        Check("  30 % throttle: off", P0(part, 1), $"P0 = {Platform.Latch(part.Sim, 0x20):X2}");
        var band = Run(["FEAT_GIO1"], cal, [At(5000, 100, 100, 100), At(3900, 100, 100, 80)]);
        Check("  on at 5000, still on at 3900 (inside the band)", !P0(band, 1), $"P0 = {Platform.Latch(band.Sim, 0x20):X2}");
        var back = Run(["FEAT_GIO1"], cal, [At(5000, 100, 100, 100), At(3000, 100, 100, 60)]);
        Check("  off again at 3000", P0(back, 1), $"P0 = {Platform.Latch(back.Sim, 0x20):X2}");
        if (Platform.P13)
        {
            // the P13's inputs traced since: the service connector (not jumped), park/neutral (in gear), the VTEC pressure
            // switch (no pressure at 3000 rpm, VTEC off): each reads off, inverted on
            foreach (var (input, name) in new[] { (0x02, "service connector"), (0x40, "park/neutral"), (0x08, "VTEC pressure") })
            {
                bool On(bool inv)
                {
                    var blk = GioBlock(2, 600, 500, input: input); blk[4] = (byte)(inv ? 1 : 0);
                    return !P0(Run(["FEAT_GIO1"], new() { ["gio1_block"] = blk }, [At(3000, 50, 20, 60)]), 1);
                }
                bool plain = On(false), inverted = On(true);
                Check($"  P13 input {input:X2}h ({name}): reads off, inverted on", !plain && inverted, $"{plain} / {inverted}");
            }
            // output 4, the O2 heater pin (P2A.2, low = on): on a build without the stock heater (which the skeleton then holds
            // off, high), a module's hold puts it on through every write the stock code makes to it; no code 27
            int highs = 0, n2 = 0;
            var heat = Run(["FEAT_GIO1", "FEAT_STOCK_DTC"], new() { ["gio1_block"] = GioBlock(4, 600, 500) }, [At(3000, 50, 20, 60)],
                sim => { if (++n2 > 400 && (sim.Bus.Ram[0x25] & 0x04) != 0) highs++; });
            int stockHighs = 0, n3 = 0;
            Run(["FEAT_GIO1"], [], [At(3000, 50, 20, 60)], sim => { if (++n3 > 400 && (sim.Bus.Ram[0x25] & 0x04) != 0) stockHighs++; });
            int lows = highs, stockLows = stockHighs;
            var codes = heat.Sim.Bus.Ram[0x332] | heat.Sim.Bus.Ram[0x333] << 8 | heat.Sim.Bus.Ram[0x330] << 16;
            Check("  P13 output 4 (the O2 heater, P2A.2): held on, through the stock writes; no trouble code", highs == 0 && stockHighs > 0 && codes == 0,
                  $"{highs} samples off (without the hold: {stockHighs} of {n3 - 400}); codes {codes:X6}");
        }
        // the on delay: 60 steps (2 s) - not on after 1 s, on after 3 s
        var slow = new Dictionary<string, byte[]> { ["gio1_block"] = GioBlock(6, 1000, 900, onDelay: 60) };
        var early = Run(["FEAT_GIO1"], slow, [Hold(1, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; })]);
        var late = Run(["FEAT_GIO1"], slow, [Hold(3, e => { e.Rpm = 3000; e.MapKpa = 60; e.TpsPct = 20; })]);
        Check("on delay 2 s: off after 1 s, on after 3 s (the ECU LED, P1.5)", !P1(early, 5) && P1(late, 5), $"{Platform.Latch(early.Sim, 0x22):X2} / {Platform.Latch(late.Sim, 0x22):X2}");
        // flash: the LED toggles while the conditions hold
        int changes = 0; bool? last = null;
        Run(["FEAT_GIO1"], new() { ["gio1_block"] = GioBlock(6, 1000, 900, onDelay: 8, flash: 1) }, [Hold(3, e => { e.Rpm = 3000; e.MapKpa = 60; })],
            sim => { bool on = (Platform.Latch(sim, 0x22) & 0x20) != 0; if (last != null && on != last) changes++; last = on; });
        Check("flash (on delay 262 ms): the LED keeps changing", changes >= 8, $"{changes} changes in 3 s");
    }

    static void Test_Gio2() => GioOn("FEAT_GIO2", "gio2_block");
    static void Test_Gio3() => GioOn("FEAT_GIO3", "gio3_block");
    static void Test_Gio4() => GioOn("FEAT_GIO4", "gio4_block");
    static void GioOn(string feat, string block)
    {
        var cal = new Dictionary<string, byte[]> { [block] = GioBlock(6, 4000, 3800) };
        var on = Run([feat], cal, [At(5000, 100, 100, 100)]);
        var off = Run([feat], cal, [At(2500, 50, 20, 60)]);
        Check("the ECU LED (P1.5) above 4000 rpm, not below", P1(on, 5) && !P1(off, 5), $"{Platform.Latch(on.Sim, 0x22):X2} / {Platform.Latch(off.Sim, 0x22):X2}");
        var all = Run(["FEAT_GIO1", "FEAT_GIO2", "FEAT_GIO3", "FEAT_GIO4"], new()
        {
            ["gio1_block"] = GioBlock(6, 4000, 3800), ["gio2_block"] = GioBlock(5, 4000, 3800),
            ["gio3_block"] = GioBlock(2, 9000, 8800), ["gio4_block"] = GioBlock(0, 4000, 3800),
        }, [At(5000, 100, 100, 100)]);
        Check("  with all four built: each drives only its own output", P1(all, 5) && P1(all, 4) && P0(all, 1), $"P0 {Platform.Latch(all.Sim, 0x20):X2}, P1 {Platform.Latch(all.Sim, 0x22):X2}");
    }

    // ------------------------------------------------------------------ board options
    static void Test_CfgOverride()
    {
        if (Platform.P13)
        {
            // the P13's variant flags: the baro sensor forced off (220h bit 3: baro the fixed F9h, at 1500 m as at sea level),
            // the load input check forced on (221h bit 2); the copies at 120h/121h the same
            var b13 = Run(["FEAT_CFGOVERRIDE"], [], [At(2500, 50, 20, 50, e => e.BaroKpa = 85)]);
            var r13 = Run(["FEAT_CFGOVERRIDE"], new() { ["cfg13_off_220"] = B(0x08), ["cfg13_on_221"] = B(0x04) }, [At(2500, 50, 20, 50, e => e.BaroKpa = 85)]);
            var m0 = b13.Sim.Bus.Ram; var m1 = r13.Sim.Bus.Ram;
            Check("P13: the baro sensor forced off (220h bit 3, baro the fixed F9h), the load check forced on (221h bit 2), copies too",
                  (m0[0x220] & 0x08) != 0 && (m1[0x220] & 0x08) == 0 && (m1[0x120] & 0x08) == 0 && (m1[0x221] & 0x04) != 0 && (m1[0x121] & 0x04) != 0
                  && m1[0xE0] == 0xF9 && m0[0xE0] != 0xF9 && Running(r13),
                  $"220h {m0[0x220]:X2} -> {m1[0x220]:X2}, 221h {m0[0x221]:X2} -> {m1[0x221]:X2}, baro byte {m0[0xE0]:X2} -> {m1[0xE0]:X2}");
            return;
        }
        var baseRun = Run(["FEAT_CFGOVERRIDE"], [], [At(2500, 50, 20, 50)]);
        var r = Run(["FEAT_CFGOVERRIDE"], new() { ["cfg_on_216"] = B(0x08), ["cfg_off_216"] = B(0x20) }, [At(2500, 50, 20, 50)]);
        int b0 = baseRun.Sim.Bus.Ram[0x216], b1 = r.Sim.Bus.Ram[0x216];
        Check("automatic forced on, knock sensor forced off: 216h bits 3 and 5", (b1 & 0x08) != 0 && (b1 & 0x20) == 0 && (b1 & ~0x28) == (b0 & ~0x28) && Running(r),
            $"216h {b0:X2} -> {b1:X2}");
    }

    // ------------------------------------------------------------------ smart alternator
    static void Test_SmartAlt()
    {
        var on = new Dictionary<string, byte[]> { ["smartalt_enable"] = B(1), ["smartalt_tps"] = B(0x7F), ["smartalt_rpm"] = W(P(3000)) };
        var heavy = Run(["FEAT_SMARTALT"], on, [At(4500, 100, 100, 100)]);
        var cruise = Run(["FEAT_SMARTALT"], on, [At(3000, 50, 20, 90)]);
        var baseRun = Run(["FEAT_SMARTALT"], [], [At(4500, 100, 100, 100)]);
        // the alternator control is P0.2 (pin A16; found on the car): read at the 8255's port B, where the pin is
        static bool Pb(RunResult r, int bit) => (Platform.PortB(r.Sim) & (1 << bit)) != 0;
        Check("full throttle at 4500 rpm: the alternator control (P0.2, pin A16) high", Pb(heavy, 2) && !Pb(baseRun, 2), $"port B {Platform.PortB(heavy.Sim):X2}, stock {Platform.PortB(baseRun.Sim):X2}");
        Check("  cruising: left to the stock control", Pb(cruise, 2) == Pb(baseRun, 2), $"port B {Platform.PortB(cruise.Sim):X2}");
        var lowBatt = Run(["FEAT_SMARTALT"], on, [At(4500, 100, 100, 100, e => e.VbattVolts = 11.5)]);
        Check("  battery under the minimum (11.5 V): charging stays on", Pb(lowBatt, 2) == Pb(baseRun, 2), $"port B {Platform.PortB(lowBatt.Sim):X2}");
        // the two outputs added after the car test: GIO 1 on 10 (P0.3, the radiator fan) and on 11 (P4.3, pin A17)
        var fan = Run(["FEAT_GIO1"], new() { ["gio1_block"] = GioBlock(10, 600, 500) }, [At(3000, 50, 20, 90)]);
        var a17 = Run(["FEAT_GIO1"], new() { ["gio1_block"] = GioBlock(11, 600, 500) }, [At(3000, 50, 20, 90)]);
        var none = Run(["FEAT_GIO1"], [], [At(3000, 50, 20, 90)]);        Check("  outputs 10 and 11: GIO 1 drives the fan (P0.3 low at port B) and pin A17 (P4.3)", !Pb(fan, 3) && Pb(none, 3) && Platform.A17(a17.Sim) && !Platform.A17(none.Sim),
              $"port B {Platform.PortB(fan.Sim):X2} (stock {Platform.PortB(none.Sim):X2}), P4 {a17.Sim.Bus.Ram[Bus.SfrP4]:X2} (stock {none.Sim.Bus.Ram[Bus.SfrP4]:X2})");
    }

    // ------------------------------------------------------------------ A/C cut-off
    static void Test_AcCut()
    {
        string[] defs = ["FEAT_STOCK_AC", "FEAT_ACCUT"];
        var on = new Dictionary<string, byte[]> { ["accut_enable"] = B(1) };
        var idle = Run(defs, on, [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.AcRequest = true; })]);
        var wot = Run(defs, on, [Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.AcRequest = true; }), Hold(1, e => { e.Rpm = 5000; e.MapKpa = 100; e.TpsPct = 100; e.SpeedKmh = 80; e.AcRequest = true; })]);
        Check("A/C on at idle: the clutch engaged (P0.0 low)", !P0(idle, 0), $"P0 {Platform.Latch(idle.Sim, 0x20):X2}");
        Check("  full throttle: the clutch off (P0.0 high)", P0(wot, 0), $"P0 {Platform.Latch(wot.Sim, 0x20):X2}");
        var after = Run(defs, on, [Hold(1, e => { e.Rpm = 5000; e.MapKpa = 100; e.TpsPct = 100; e.AcRequest = true; }), Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.AcRequest = true; })]);
        Check("  back at idle after the hold: engaged again", !P0(after, 0), $"P0 {Platform.Latch(after.Sim, 0x20):X2}");
    }

    // ------------------------------------------------------------------ anti-stall
    static void Test_AntiStall()
    {
        var on = new Dictionary<string, byte[]> { ["antistall_enable"] = B(1) };
        int iacv = 0, flag = 0, adv = 0;
        Run(["FEAT_ANTISTALL"], on, [Hold(1.5, e => { e.Rpm = 450; e.MapKpa = 40; })],
            sim => { var m = sim.Bus.Ram; iacv = Math.Max(iacv, m[Platform.A(0xC8)] | m[Platform.A(0xC9)] << 8); flag |= m[0xFD] & 4; adv = Math.Max(adv, m[Advance]); });
        Check("450 rpm: on, the idle valve at 091Fh and 5 degrees added", flag != 0 && iacv >= 0x91F && adv == 20, $"flag {flag}, duty {iacv:X4}, advance {adv / 4.0}");
        var ok = Run(["FEAT_ANTISTALL"], on, [Hold(2, e => { e.Rpm = 850; e.MapKpa = 33; })]);
        Check("  850 rpm: off", (ok.Sim.Bus.Ram[0xFD] & 4) == 0 && ok.Sim.Bus.Ram[Advance] == 0, $"flag {ok.Sim.Bus.Ram[0xFD] & 4}, advance {ok.Sim.Bus.Ram[Advance]}");
        var rec = Run(["FEAT_ANTISTALL"], on, [Hold(1, e => { e.Rpm = 450; e.MapKpa = 40; }), Hold(2, e => { e.Rpm = 900; e.MapKpa = 33; })]);
        Check("  recovered: off after the hold", (rec.Sim.Bus.Ram[0xFD] & 4) == 0 && rec.Sim.Bus.Ram[Advance] == 0, $"flag {rec.Sim.Bus.Ram[0xFD] & 4}");
    }

    // ------------------------------------------------------------------ water / methanol
    static void Test_Wmi()
    {
        var on = new Dictionary<string, byte[]> { ["wmi_enable"] = B(1), ["wmi_out"] = B(2), ["wmi_duty"] = B(0, 0, 0, 0, 50, 50, 50, 50, 50) };
        int n = 0, onCount = 0, steps = 0;
        var wr = Run(["FEAT_WMI"], on, [At(4000, 100, 100, 100)], sim => { if (++n <= 300) return; if ((Platform.Latch(sim, 0x20) & 0x02) == 0) onCount++; });
        long dutyAt = wr.Asm.Symbols.Values.First(x => x.Name == "MOD_SWDUTY").Value;
        steps = wr.Sim.Bus.Ram[dutyAt];
        double duty = onCount / (double)Math.Max(1, n - 300);
        Check("100 kPa, the table at 50 %: the pump output (P0.1, active low) on about half the time", duty > 0.35 && duty < 0.65, $"{duty:P0} ({steps} of 25 steps)");
        int off = 0;
        Run(["FEAT_WMI"], on, [At(3000, 50, 20, 60)], sim => { if ((Platform.Latch(sim, 0x20) & 0x02) == 0) off++; });
        Check("  light load (under the throttle point): off", off == 0, $"{off} samples on");
    }

    // ------------------------------------------------------------------ secondary maps
    static void Test_DualMaps()
    {
        // the final advance is the map's cell plus corrections, so two settings of the second map are compared:
        // 16 counts more in the map is 16 counts more at the coil
        Dictionary<string, byte[]> Ign(int v, bool on, int cells = 200) => new()
        {
            ["IgnitionLow2"] = Enumerable.Repeat((byte)v, cells).ToArray(), ["IgnitionHigh2"] = Enumerable.Repeat((byte)v, cells).ToArray(),
            ["dualmaps_enable"] = B(on ? 1 : 0),
        };
        // (on the P13 the map's cells are (x - 24) / 4 degrees and a floor holds the advance up: higher cells to compare)
        int lo = Platform.P13 ? 0x80 : 0x20, hi = lo + 0x10;
        var a = Run(["FEAT_DUALMAPS"], Ign(lo, true), [At(3000, 60, 30, 60)]);
        var b = Run(["FEAT_DUALMAPS"], Ign(hi, true), [At(3000, 60, 30, 60)]);
        var offA = Run(["FEAT_DUALMAPS"], Ign(lo, false), [At(3000, 60, 30, 60)]);
        var offB = Run(["FEAT_DUALMAPS"], Ign(hi, false), [At(3000, 60, 30, 60)]);
        Check("switched in: the timing follows the second ignition map", Math.Abs(b.Advance[^1] - a.Advance[^1] - 16) <= 2,
            $"second map {lo:X2}h / {hi:X2}h: advance {a.Advance[^1]:0} / {b.Advance[^1]:0}");
        Check("  switched out: the second map does nothing", Math.Abs(offB.Advance[^1] - offA.Advance[^1]) <= 1, $"{offA.Advance[^1]:0} / {offB.Advance[^1]:0}");
        // (P13 applies its fuel maps in open loop only - at part throttle it holds 1.0: the fuel check at full throttle there)
        var fuelAt = Platform.P13 ? At(5000, 100, 100, 100) : At(3000, 60, 30, 60);
        double Inj(Dictionary<string, byte[]> cal) { double s = 0; int n = 0; Run(["FEAT_DUALMAPS"], cal, [fuelAt], sim => { if (++n > 200) s += sim.Bus.Ram[Platform.A(0x3AE)] | sim.Bus.Ram[Platform.A(0x3AF)] << 8; }); return s / Math.Max(1, n - 200); }
        var rich = Enumerable.Repeat((byte)0xF0, 210).ToArray();
        double i0 = Inj(new() { ["dualmaps_enable"] = B(1) }), i1 = Inj(new() { ["dualmaps_enable"] = B(1), ["FuelLow2"] = rich, ["FuelHigh2"] = rich });
        Check("  and the fuel follows the second fuel maps", i1 > i0 * (Platform.P13 ? 1.05 : 1.2), $"injector time {i0:0} -> {i1:0}");
        var ea = Run(["FEAT_DUALMAPS", "FEAT_EXTMAPS"], Ign(lo, true, 400), [At(3000, 60, 30, 60)]);
        var eb = Run(["FEAT_DUALMAPS", "FEAT_EXTMAPS"], Ign(hi, true, 400), [At(3000, 60, 30, 60)]);
        Check("  with extended maps too (20 columns)", Math.Abs(eb.Advance[^1] - ea.Advance[^1] - 16) <= 2, $"advance {ea.Advance[^1]:0} / {eb.Advance[^1]:0}");
    }

    // ------------------------------------------------------------------ watermark
    static void Test_Watermark()
    {
        var r = Run(["FEAT_WATERMARK"], [], [At(2500, 50, 20, 50)]);
        long at = r.Asm.Symbols.Values.First(x => x.Name == "watermark_data").Value;
        var (t0, ok0) = WatermarkCodec.Decode(r.Asm.Image.AsSpan((int)at, WatermarkCodec.Bytes));
        Check("as built: blank and intact", t0 == "" && ok0, $"\"{t0}\" {(ok0 ? "intact" : "modified")}");
        var enc = WatermarkCodec.Encode("BMGJET TUNE 01");
        var (t1, ok1) = WatermarkCodec.Decode(enc);
        Check("  a text written by the app reads back, intact", t1 == "BMGJET TUNE 01" && ok1, $"\"{t1}\"");
        enc[3] ^= 0x01;
        var (_, ok2) = WatermarkCodec.Decode(enc);
        Check("  one byte changed some other way: modified", !ok2, "");
        var run = Run(["FEAT_WATERMARK"], new() { ["watermark_data"] = WatermarkCodec.Encode("TEST") }, [At(3000, 60, 30, 60)]);
        Check("  the engine runs the same with any text", Running(run), Rates(run));
    }

    // ------------------------------------------------------------------ lean protection
    static void Test_LeanPro()
    {
        // wideband on the O2 input, 0 V = 10.0, 5 V = 20.0 AFR; lean past 14.0 above 1075 mbar and 3000 rpm
        var on = new Dictionary<string, byte[]> { ["leanpro_block"] = B(1) };
        var lean = Run(["FEAT_LEANPRO"], on, [At(4000, 120, 100, 100, e => e.O2Volts = 3.0)]);
        Check("16.0 AFR at 120 kPa: cut", FuelCut(lean) && SparkCut(lean), Rates(lean));
        var rich = Run(["FEAT_LEANPRO"], on, [At(4000, 120, 100, 100, e => e.O2Volts = 1.5)]);
        Check("12.5 AFR at 120 kPa: runs", Running(rich), Rates(rich));
        var offboost = Run(["FEAT_LEANPRO"], on, [At(4000, 90, 60, 100, e => e.O2Volts = 3.0)]);
        Check("16.0 AFR at 90 kPa (off boost): runs", Running(offboost), Rates(offboost));
        var backoff = Run(["FEAT_LEANPRO"], on, [At(4000, 120, 100, 100, e => e.O2Volts = 3.0), At(3000, 60, 20, 100, e => e.O2Volts = 2.4)]);
        Check("cut stays until the pressure falls back, then it runs", Running(backoff), Rates(backoff));
    }

    // ------------------------------------------------------------------ closed loop on a wideband
    static void Test_Wbcl()
    {
        var on = new Dictionary<string, byte[]> { ["wbcl_enable"] = B(1) };        // target 14.7 below 60 kPa (the table's first points)
        var lean = Run(["FEAT_WBCL"], on, [At(2500, 40, 15, 60, e => e.O2Volts = 3.0)]);
        Check("16.0 AFR against 14.7: the trim runs up to +15 %", Signed(Word(lean, FuelSum)) == 38, $"trim {Signed(Word(lean, FuelSum)) * 100 / 256.0:0.0} %");
        var rich = Run(["FEAT_WBCL"], on, [At(2500, 40, 15, 60, e => e.O2Volts = 1.0)]);
        Check("12.0 AFR: down to -15 %", Signed(Word(rich, FuelSum)) == -38, $"trim {Signed(Word(rich, FuelSum)) * 100 / 256.0:0.0} %");
        var baseRun = Run(["FEAT_WBCL"], [], [At(2500, 40, 15, 60, e => e.O2Volts = 3.0)]);
        double ratio = Word(lean, 0x146) / (double)Math.Max(1, Word(baseRun, 0x146));
        Check("  and the pulse width grows with it", ratio > 1.10 && ratio < 1.20, $"x {ratio:0.000}");
        var cold = Run(["FEAT_WBCL"], on, [At(2500, 40, 15, 60, e => { e.O2Volts = 3.0; e.EctCelsius = 20; })], ect: 20);
        Check("cold engine: no trim", Word(cold, FuelSum) == 0, $"trim {Signed(Word(cold, FuelSum))}");
    }

    // ------------------------------------------------------------------ flex fuel
    static void Test_Flex()
    {
        var on = new Dictionary<string, byte[]> { ["flex_enable"] = B(1) };          // B6: 0.5 V = 0 %, 4.5 V = 100 %
        var e85 = Run(["FEAT_FLEX"], on, [At(3000, 60, 30, 60, e => e.AnalogOverrides[Platform.AuxAdc] = 4.5)]);
        Check("4.5 V (100 %): +37.5 % fuel, +4 degrees", Signed(Word(e85, FuelSum)) == 96 && e85.Sim.Bus.Ram[Advance] == 16,
            $"fuel {Signed(Word(e85, FuelSum))}/256, advance {e85.Sim.Bus.Ram[Advance] / 4.0} deg");
        var half = Run(["FEAT_FLEX"], on, [At(3000, 60, 30, 60, e => e.AnalogOverrides[Platform.AuxAdc] = 2.5)]);
        Check("2.5 V (50 %): about half of each", Math.Abs(Signed(Word(half, FuelSum)) - 48) <= 2 && Math.Abs(half.Sim.Bus.Ram[Advance] - 8) <= 1,
            $"fuel {Signed(Word(half, FuelSum))}/256, advance {half.Sim.Bus.Ram[Advance] / 4.0} deg");
        var pump = Run(["FEAT_FLEX"], on, [At(3000, 60, 30, 60, e => e.AnalogOverrides[Platform.AuxAdc] = 0.4)]);
        Check("0.4 V (pump fuel): nothing added", Word(pump, FuelSum) == 0 && pump.Sim.Bus.Ram[Advance] == 0, "");
        double adv = e85.Advance[^1] - Run(["FEAT_FLEX"], [], [At(3000, 60, 30, 60)]).Advance[^1];
        Check("  and the spark moves 4 degrees earlier", Math.Abs(adv - 16) <= 4, $"{adv / 4:0.00} deg");
    }

    // ------------------------------------------------------------------ nitrous
    static void Test_Nitrous()
    {
        // the nitrous maps: the low-cam fuel 24 counts richer, its timing 2 degrees (8 quarter-degree counts) later
        var plain = Run(["FEAT_NITROUS"], [], [At(4000, 95, 100, 80)]);
        int Sym(string n) => ModSym(plain, n);
        var img = plain.Asm.Image;
        // (P13: 12 counts - its full-load cells sit high, and twice 24 would run into 255)
        int fuelStep = Platform.P13 ? 12 : 24;
        byte[] fuel2 = [.. Enumerable.Range(0, Platform.P13 ? 200 : 210).Select(i => (byte)(i < 200 ? Math.Min(255, img[Sym("FuelLow") + i] + fuelStep) : img[Sym("FuelLow") + i]))];
        byte[] ign2 = [.. Enumerable.Range(0, 200).Select(i => (byte)Math.Max(0, img[Sym("IgnitionLow") + i] - 8))];
        Dictionary<string, byte[]> Cal(int shotIn, int output = 0) => new()
        {
            ["nos_enable"] = B(1), ["nos_input"] = B(0x80), ["nos_shot_in"] = B(shotIn), ["nos_output"] = B(Platform.Out(output)),
            ["FuelLow2"] = fuel2, ["IgnitionLow2"] = ign2,
        };
        // the injector time the ROM works out (3AEh), averaged over the run once settled
        (double Pw, double Adv) Go(Dictionary<string, byte[]> cal, (double, Action<EngineState, double>) at)
        {
            double sum = 0; int n = 0;
            var r = Run(["FEAT_NITROUS"], cal, [at], sim => { if (++n > 200) sum += sim.Bus.Ram[Platform.A(0x3AE)] | sim.Bus.Ram[Platform.A(0x3AF)] << 8; });
            return (sum / Math.Max(1, n - 200), r.Advance[^1]);
        }
        // (P13: at 70 kPa - at full load its injector time is clamped (against the battery), and a bigger shot
        // would hit the same ceiling)
        double nmap = Platform.P13 ? 70 : 95;
        var (basePw, baseAdv) = Go([], At(4000, nmap, 100, 80));
        var shotR = Go(Cal(0xFF), At(4000, nmap, 100, 80));
        double up1 = shotR.Pw / basePw, ret1 = baseAdv - shotR.Adv;
        Check("armed, full throttle, 4000 rpm: the nitrous maps (more fuel, about 2 degrees less timing)", up1 > 1.04 && ret1 is > 5 and < 11,
              $"pulse x {up1:0.000}, timing {ret1 / 4:0.00} deg less");
        // the shot input on the O2 pin: 2 V is 200 %, twice the change
        var dbl = Go(Cal(0), At(4000, nmap, 100, 80, e => e.O2Volts = 2.0));
        double up2 = dbl.Pw / basePw, ret2 = baseAdv - dbl.Adv;
        Check("2 V on the shot input (200 %): twice the fuel added and twice the timing taken out",
              Math.Abs((up2 - 1) / Math.Max(1e-6, up1 - 1) - 2) < 0.35 && Math.Abs(ret2 / Math.Max(1e-6, ret1) - 2) < 0.35,
              $"pulse x {up2:0.000} (x {(up2 - 1) / Math.Max(1e-6, up1 - 1):0.00} the change), timing {ret2 / 4:0.00} deg less");
        double up15 = Go(Cal(0), At(4000, nmap, 100, 80, e => e.O2Volts = 1.0)).Pw / basePw;
        Check("1 V (150 %): half as much change again, between the two", up15 > up1 && up15 < up2, $"pulse x {up15:0.000}");
        // outside the window: the normal maps
        var low = Go(Cal(0xFF), At(2500, 95, 100, 50)).Pw; var lowBase = Go([], At(2500, 95, 100, 50)).Pw;
        Check("under the minimum rpm (2500 < 3000): the normal maps", Math.Abs(low / lowBase - 1) < 0.01, $"{low:0} / {lowBase:0}");
        var part = Go(Cal(0xFF), At(4000, 60, 40, 80)).Pw; var partBase = Go([], At(4000, 60, 40, 80)).Pw;
        Check("part throttle (40 % < 90 %): the normal maps", Math.Abs(part / partBase - 1) < 0.01, $"{part:0} / {partBase:0}");
        var unarmed = Go(new(Cal(0xFF)) { ["nos_input"] = B(0x00) }, At(4000, nmap, 100, 80)).Pw;
        Check("not armed: the normal maps", Math.Abs(unarmed / basePw - 1) < 0.01, $"{unarmed:0} / {basePw:0}");
        // the solenoid: P1.5 (output 6, the ECU LED) on while spraying
        bool ledOn = false, ledOff = true;
        Run(["FEAT_NITROUS"], Cal(0xFF, 6), [At(4000, 95, 100, 80), At(4000, 60, 40, 80)],
            sim => { ledOn |= (Platform.Latch(sim, 0x22) & 0x20) != 0; });
        var off = Run(["FEAT_NITROUS"], Cal(0xFF, 6), [At(4000, 60, 40, 80)], sim => { if ((Platform.Latch(sim, 0x22) & 0x20) != 0) ledOff = false; });
        Check("the solenoid output (P1.5) on while spraying, off at part throttle", ledOn && ledOff, $"on {ledOn}, stayed off {ledOff}");
    }

    // ------------------------------------------------------------------ injector size / trim
    static void Test_FuelTrim()
    {
        var on = new Dictionary<string, byte[]> { ["fueltrim_enable"] = B(1), ["fueltrim_fitted"] = W(480) };
        var big = Run(["FEAT_FUELTRIM"], on, [At(3000, 60, 30, 60)]);
        var baseRun = Run(["FEAT_FUELTRIM"], [], [At(3000, 60, 30, 60)]);
        double ratio = Word(big, 0x146) / (double)Math.Max(1, Word(baseRun, 0x146));
        Check("240 cc calibration, 480 cc fitted: half the pulse width", Math.Abs(ratio - 0.5) < 0.02, $"x {ratio:0.000}");
        var trim = Run(["FEAT_FUELTRIM"], new() { ["fueltrim_enable"] = B(1), ["fueltrim_trim"] = B(0x80 + 26) }, [At(3000, 60, 30, 60)]);
        double r2 = Word(trim, 0x146) / (double)Math.Max(1, Word(baseRun, 0x146));
        Check("a +10 % trim: 1.10 x", Math.Abs(r2 - 1.10) < 0.02, $"x {r2:0.000}");
        // the size scales the trims too: twice the injector with +10 % is 0.5 x 1.10 = 0.55, not 0.5 + 0.10 = 0.60
        var both = Run(["FEAT_FUELTRIM"], new() { ["fueltrim_enable"] = B(1), ["fueltrim_fitted"] = W(480), ["fueltrim_trim"] = B(0x80 + 26) }, [At(3000, 60, 30, 60)]);
        double r3 = Word(both, 0x146) / (double)Math.Max(1, Word(baseRun, 0x146));
        Check("480 cc fitted and a +10 % trim: 0.55 x (the trim is 10 % of what the engine gets)", Math.Abs(r3 - 0.55) < 0.015, $"x {r3:0.000}");
        // smaller injectors: 240 -> 200 cc is 1.2 x; and the scaling is held to double
        var small = Run(["FEAT_FUELTRIM"], new() { ["fueltrim_enable"] = B(1), ["fueltrim_fitted"] = W(200) }, [At(3000, 60, 30, 60)]);
        double r4 = Word(small, 0x146) / (double)Math.Max(1, Word(baseRun, 0x146));
        Check("200 cc fitted: 1.20 x", Math.Abs(r4 - 1.20) < 0.015, $"x {r4:0.000}");
        var tiny = Run(["FEAT_FUELTRIM"], new() { ["fueltrim_enable"] = B(1), ["fueltrim_fitted"] = W(100) }, [At(3000, 60, 30, 60)]);
        double r5 = Word(tiny, 0x146) / (double)Math.Max(1, Word(baseRun, 0x146));
        Check("100 cc fitted (2.4 x): held to double", Math.Abs(r5 - 2.0) < 0.02, $"x {r5:0.000}");
        var huge = Run(["FEAT_FUELTRIM"], new() { ["fueltrim_enable"] = B(1), ["fueltrim_fitted"] = W(1000) }, [At(3000, 60, 30, 60)]);
        double r6 = Word(huge, 0x146) / (double)Math.Max(1, Word(baseRun, 0x146));
        Check("1000 cc fitted: 0.24 x", Math.Abs(r6 - 0.24) < 0.01, $"x {r6:0.000}");
    }

    // ------------------------------------------------------------------ by gear
    static void Test_GearFuel()
    {
        var on = new Dictionary<string, byte[]> { ["gearfuel_enable"] = B(1), ["gearfuel_table"] = B(0x80, 0x80, 0x80, 0xA0, 0x80, 0x80) };
        var g3 = Run(["FEAT_GEAR", "FEAT_GEARFUEL"], on, [InGear(3)]);
        var g2 = Run(["FEAT_GEAR", "FEAT_GEARFUEL"], on, [InGear(2)]);
        Check("+12.5 % in 3rd only", Signed(Word(g3, FuelSum)) == 32 && Word(g2, FuelSum) == 0, $"3rd {Signed(Word(g3, FuelSum))}, 2nd {Signed(Word(g2, FuelSum))} /256");
    }

    static void Test_GearIgn()
    {
        var on = new Dictionary<string, byte[]> { ["gearign_enable"] = B(1), ["gearign_table"] = B(0x80, 0x78, 0x80, 0x80, 0x80, 0x90) };
        var g5 = Run(["FEAT_GEAR", "FEAT_GEARIGN"], on, [InGear(5)]);
        var g1 = Run(["FEAT_GEAR", "FEAT_GEARIGN"], on, [InGear(1)]);
        Check("+4 degrees in 5th, -2 in 1st", g5.Sim.Bus.Ram[Advance] == 16 && g1.Sim.Bus.Ram[Retard] == 8,
            $"5th advance {g5.Sim.Bus.Ram[Advance] / 4.0}, 1st retard {g1.Sim.Bus.Ram[Retard] / 4.0}");
    }

    // ------------------------------------------------------------------ tip-in retard
    static void Test_TpsRetard()
    {
        var on = new Dictionary<string, byte[]> { ["tpsr_enable"] = B(1) };
        int peak = 0;
        var r = Run(["FEAT_TPSRETARD"], on, [At(2500, 50, 5, 50), Hold(1, e => { e.TpsPct = 90; e.MapKpa = 90; }), Hold(2, e => { })], sim => peak = Math.Max(peak, sim.Bus.Ram[Retard]));
        Check("throttle snapped open: 4 degrees pulled", peak == 16, $"peak {peak / 4.0} deg");
        Check("  and given back", r.Sim.Bus.Ram[Retard] == 0, $"{r.Sim.Bus.Ram[Retard] / 4.0} deg at the end");
        int slow = 0;
        Run(["FEAT_TPSRETARD"], on, [At(2500, 50, 5, 50), (2, (e, f) => { e.TpsPct = 5 + 60 * f; })], sim => slow = Math.Max(slow, sim.Bus.Ram[Retard]));
        Check("opened slowly: nothing", slow == 0, $"peak {slow / 4.0} deg");
    }

    // ------------------------------------------------------------------ traction control
    static void Test_Traction()
    {
        var on = new Dictionary<string, byte[]> { ["tc_enable"] = B(1) };
        var spin = new List<(double, Action<EngineState, double>)>
        {
            Hold(3, e => { e.Rpm = 4000; e.MapKpa = 95; e.TpsPct = 90; e.SpeedKmh = 4000 / 81.0; }),
            (0.5, (e, f) => { e.Rpm = 4000 + 3000 * f; }),
            Hold(0.5, e => { e.Rpm = 7000; }),
            Hold(3, e => { e.Rpm = 4000; }),
        };
        int peak = 0;
        var r = Run(["FEAT_GEAR", "FEAT_TRACTION"], on, spin, sim => peak = Math.Max(peak, sim.Bus.Ram[Retard]));
        Check("2nd gear, rpm climbing 6000 rpm/s at a steady road speed: timing pulled", peak > 0 && peak <= 40, $"peak {peak / 4.0} deg (ceiling 10)");
        Check("  and given back once it grips", r.Sim.Bus.Ram[Retard] == 0, $"{r.Sim.Bus.Ram[Retard] / 4.0} deg at the end");
        int pull = 0;
        Run(["FEAT_GEAR", "FEAT_TRACTION"], on, [Hold(3, e => { e.Rpm = 3000; e.MapKpa = 95; e.TpsPct = 90; e.SpeedKmh = 3000 / 81.0; }),
            (2, (e, f) => { e.Rpm = 3000 + 3000 * f; e.SpeedKmh = e.Rpm / 81.0; })], sim => pull = Math.Max(pull, sim.Bus.Ram[Retard]));
        Check("a hard normal pull (1500 rpm/s, road speed with it): left alone", pull == 0, $"peak {pull / 4.0} deg");
    }

    // ------------------------------------------------------------------ VTEC control
    static void Test_VtecCtl()
    {
        var alt = new Dictionary<string, byte[]> { ["vtecctl_alt"] = B(1), ["vtecctl_invert"] = B(1) };
        var r = Run(["FEAT_VTECCTL"], alt, [At(3000, 60, 30, 60)]);
        Check("alternative output (LED), inverted: on while VTEC is off", P1(r, 5), $"P1 = {Platform.Latch(r.Sim, 0x22):X2}");
        // (P13: 6000 - without VTEC it cuts the fuel before 6500)
        int noVtecRpm = Platform.P13 ? 6000 : 7000;
        var dis = Run(["FEAT_VTECCTL"], new() { ["vtecctl_enable"] = B(0) }, [At(noVtecRpm, 100, 100, 150)]);
        Check("VTEC disabled: the solenoid stays off", !P1(dis, 0) && Running(dis), $"P1 = {Platform.Latch(dis.Sim, 0x22):X2}, {Rates(dis)}");

        // its own engage points: 4812 rpm at 60 % throttle and over, 5500 at 20 % and under, 187 rpm drop-out margin
        var own = new Dictionary<string, byte[]> { ["vtecctl_custom"] = B(1) };
        bool Vtec(RunResult x) => P1(x, 0);
        // the stock gate it keeps: not in the first 5 s after a start
        var idle = Hold(3, e => { e.Rpm = 850; e.MapKpa = 33; e.TpsPct = 0; e.SpeedKmh = 0; });
        var wot = Run(["FEAT_VTECCTL"], own, [idle, At(5200, 100, 100, 80)]);
        Check("own points: 5200 rpm flat out, moving: on", Vtec(wot) && Running(wot), $"P1 = {Platform.Latch(wot.Sim, 0x22):X2}, {Rates(wot)}");
        var under = Run(["FEAT_VTECCTL"], own, [idle, At(4500, 100, 100, 80)]);
        Check("  4500 rpm flat out (under 4812): off", !Vtec(under), $"P1 = {Platform.Latch(under.Sim, 0x22):X2}");
        var cruise = Run(["FEAT_VTECCTL"], own, [idle, At(5200, 40, 10, 80)]);
        var cruiseHi = Run(["FEAT_VTECCTL"], own, [idle, At(5700, 40, 10, 80)]);
        Check("  10 % throttle: off at 5200, on at 5700 (low load point 5500)", !Vtec(cruise) && Vtec(cruiseHi),
              $"P1 = {Platform.Latch(cruise.Sim, 0x22):X2} / {Platform.Latch(cruiseHi.Sim, 0x22):X2}");
        var mid = Run(["FEAT_VTECCTL"], own, [idle, At(5100, 60, 40, 80)]);
        var midHi = Run(["FEAT_VTECCTL"], own, [idle, At(5300, 60, 40, 80)]);
        Check("  40 % throttle (half way): off at 5100, on at 5300 (point about 5150)", !Vtec(mid) && Vtec(midHi),
              $"P1 = {Platform.Latch(mid.Sim, 0x22):X2} / {Platform.Latch(midHi.Sim, 0x22):X2}");
        var hold = Run(["FEAT_VTECCTL"], own, [idle, At(5200, 100, 100, 80), Hold(1, e => e.Rpm = 4700)]);
        var drop = Run(["FEAT_VTECCTL"], own, [idle, At(5200, 100, 100, 80), Hold(1, e => e.Rpm = 4500)]);
        Check("  engaged, back down to 4700: held (margin to 4625); to 4500: out", Vtec(hold) && !Vtec(drop),
              $"P1 = {Platform.Latch(hold.Sim, 0x22):X2} / {Platform.Latch(drop.Sim, 0x22):X2}");
        var still = Run(["FEAT_VTECCTL"], new(own) { ["vtecctl_minspeed"] = B(30) }, [idle, At(6000, 100, 100, 10)]);
        var stillOff = Run(["FEAT_VTECCTL"], new(own) { ["vtecctl_minspeed"] = B(30), ["vtecctl_nospeed"] = B(1) }, [idle, At(6000, 100, 100, 10)]);
        Check("  minimum speed 30 km/h, at 10: off; with the speed check off: on", !Vtec(still) && Vtec(stillOff),
              $"P1 = {Platform.Latch(still.Sim, 0x22):X2} / {Platform.Latch(stillOff.Sim, 0x22):X2}");
        var cold = Run(["FEAT_VTECCTL"], own, [idle, At(6000, 100, 100, 80)], ect: 20);
        var coldOk = Run(["FEAT_VTECCTL"], new(own) { ["vtecctl_notemp"] = B(1) }, [idle, At(6000, 100, 100, 80)], ect: 20);
        Check("  20 C coolant: off; with the temperature check off: on", !Vtec(cold) && Vtec(coldOk),
              $"P1 = {Platform.Latch(cold.Sim, 0x22):X2} / {Platform.Latch(coldOk.Sim, 0x22):X2}");
        var low = Run(["FEAT_VTECCTL"], new(own) { ["vtecctl_minmap"] = B(MapRaw(80)) }, [idle, At(6000, 60, 100, 80)]);
        Check("  minimum load 800 mbar, at 600: off", !Vtec(low), $"P1 = {Platform.Latch(low.Sim, 0x22):X2}");
        var never = Run(["FEAT_VTECCTL"], new(own) { ["vtecctl_enable"] = B(0) }, [idle, At(noVtecRpm, 100, 100, 150)]);
        Check("  own points but VTEC disabled: off", !Vtec(never) && Running(never), $"P1 = {Platform.Latch(never.Sim, 0x22):X2}");
    }

    // ------------------------------------------------------------------ secondary tune
    static void Test_MapSwitch()
    {
        var on = new Dictionary<string, byte[]> { ["mapsw_enable"] = B(1), ["mapsw_fuel"] = B(Enumerable.Repeat(0xA0, 9).ToArray()), ["mapsw_ign"] = B(Enumerable.Repeat(0x70, 9).ToArray()) };
        var sel = Run(["FEAT_MAPSWITCH"], on, [At(3000, 60, 30, 60, e => e.AcRequest = true)]);
        var not = Run(["FEAT_MAPSWITCH"], on, [At(3000, 60, 30, 60)]);
        Check("switch on: +12.5 % fuel, -4 degrees", Signed(Word(sel, FuelSum)) == 32 && sel.Sim.Bus.Ram[Retard] == 16,
            $"fuel {Signed(Word(sel, FuelSum))}/256, retard {sel.Sim.Bus.Ram[Retard] / 4.0}");
        Check("switch off: nothing", Word(not, FuelSum) == 0 && not.Sim.Bus.Ram[Retard] == 0, "");
    }

    // ------------------------------------------------------------------ tach output
    static void Test_Tach()
    {
        foreach (var rpm in new[] { 3000.0, 6000 })
        {
            int toggles = 0, slice = 0;
            var r = Run(["FEAT_TACH"], new() { ["tach_enable"] = B(1) }, [At(rpm, 60, 30, 60), At(rpm, 60, 30, 60)], sim =>
            {
                if (++slice != 300) return;            // from the end of the idle start: the two 3 s steps
                byte last = sim.Bus.Ram[Platform.A(0x1F1)];
                int at = Platform.A(0x1F1);
                sim.Bus.OnDataWrite = (a, _, v) => { if (a == at && ((v ^ last) & 0x08) != 0) toggles++; if (a == at) last = v; };
            });
            double perRev = toggles / 6.0 / (rpm / 60);
            Check($"{rpm} rpm: two pulses (four changes of state) per revolution", Math.Abs(perRev - 4) < 0.3, $"{perRev:0.00} changes per rev");
        }
    }

    // ------------------------------------------------------------------ rev limit by gear
    static void Test_GearLimit()
    {
        var t = new List<byte>();
        foreach (var rpm in new[] { 12500, 4000, 12500, 12500, 12500, 12500 }) t.AddRange(W(P(rpm)));
        var on = new Dictionary<string, byte[]> { ["gearlim_block"] = B(1), ["gearlim_table"] = [.. t] };
        var first = Run(["FEAT_GEAR", "FEAT_GEARLIMIT"], on, [InGear(1, 4500, 80, 60)]);
        Check("1st gear limited to 4000: 4500 rpm cut", FuelCut(first), Rates(first));
        var second = Run(["FEAT_GEAR", "FEAT_GEARLIMIT"], on, [InGear(2, 4500, 80, 60)]);
        Check("2nd gear (no limit): runs", Running(second), Rates(second));
    }

    // ------------------------------------------------------------------ shift light
    static void Test_ShiftLight()
    {
        var on = new Dictionary<string, byte[]> { ["shiftlight_enable"] = B(0xFF), ["shiftlight_rpm"] = W(P(6000)) };
        bool Lamp(RunResult r) => (Platform.Latch(r.Sim, 0x22) & 0x10) != 0;       // P1.4 latch
        var low = Run(["FEAT_SHIFTLIGHT"], on, [Hold(3, e => { e.Rpm = 2500; e.MapKpa = 50; e.TpsPct = 20; })]);
        var high = Run(["FEAT_SHIFTLIGHT"], on, [Hold(3, e => { e.Rpm = 6500; e.MapKpa = 100; e.TpsPct = 100; })]);
        var off = Run(["FEAT_SHIFTLIGHT"], [], [Hold(3, e => { e.Rpm = 6500; e.MapKpa = 100; e.TpsPct = 100; })]);
        Check("lamp off at 2500 rpm", !Lamp(low), "");
        Check("lamp on at 6500 rpm (shift point 6000)", Lamp(high), "");
        Check("switched off: lamp stays off at 6500 rpm", !Lamp(off), "");
        var back = Run(["FEAT_SHIFTLIGHT"], on, [Hold(3, e => { e.Rpm = 6500; e.MapKpa = 100; e.TpsPct = 100; }), Hold(3, e => { e.Rpm = 2500; e.MapKpa = 50; e.TpsPct = 20; })]);
        Check("lamp goes off again after the shift (6500 then 2500 rpm)", !Lamp(back), "");
        var byGear = new Dictionary<string, byte[]> { ["shiftlight_enable"] = B(0xFF), ["shiftlight_gearbased"] = B(0xFF),
            ["shiftlight_rpm_gear"] = [.. W(P(7000)), .. W(P(7000)), .. W(P(4000)), .. W(P(7000)), .. W(P(7000))] };
        var g3 = Run(["FEAT_SHIFTLIGHT", "FEAT_GEAR"], byGear, [InGear(3, 4500, 90, 80)]);
        var g4 = Run(["FEAT_SHIFTLIGHT", "FEAT_GEAR"], byGear, [InGear(4, 4500, 90, 80)]);
        Check("gear based (with gear detection): 4500 rpm lights it in 3rd (4000), not in 4th (7000)", Lamp(g3) && !Lamp(g4), "");
    }

    // ------------------------------------------------------------------ per-cylinder fuel
    static void Test_CylTrim()
    {
        var trims = new Dictionary<string, byte[]> { ["CylinderIGNCorrect"] = B(0xA0, 0xA0, 0xA0, 0xA0) };   // +25 %
        var wot = At(5000, 100, 100, 100);
        // cylinder 1's injector time (3AEh; P13: the first trimmed one, 384h), averaged: it moves with the crank
        int cyl = Platform.P13 ? 0x384 : 0x3AE;
        double Avg(string[] defs, Dictionary<string, byte[]> cal) { double s = 0; int n = 0; Run(defs, cal, [wot], sim => { if (++n > 400) s += sim.Bus.Ram[cyl] | sim.Bus.Ram[cyl + 1] << 8; }); return s / Math.Max(1, n - 400); }
        double baseRun = Avg(["FEAT_CYLTRIM"], []), on = Avg(["FEAT_CYLTRIM"], trims), stock = Avg([], trims);
        Check("+25 % on every cylinder at full throttle (open loop): the injector times grow", on / baseRun > 1.2 && on / baseRun < 1.3, $"x {on / baseRun:0.000}");
        Check("  the stock condition (closed loop only) leaves them alone without it", Math.Abs(stock / baseRun - 1) < 0.03, $"x {stock / baseRun:0.000}");
    }

    // ------------------------------------------------------------------ maps indexing
    static void Test_AlphaN()
    {
        var on = new Dictionary<string, byte[]> { ["alphan_enable"] = B(1), ["alphan_table"] = B(0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40) };
        var baseRun = Run(["FEAT_ALPHAN"], [], [At(3000, 100, 50, 80)]);
        var r = Run(["FEAT_ALPHAN"], on, [At(3000, 100, 50, 80)]);
        // 1D3h: the fuel map's load column; the ignition map's shows in the advance
        Check("always on, a light load in the table at 100 kPa: the maps are looked up there", r.Sim.Bus.Ram[Platform.A(0x2F7)] == 0x40 && r.Sim.Bus.Ram[Platform.A(0x1D3)] < baseRun.Sim.Bus.Ram[Platform.A(0x1D3)]
              && r.Advance[^1] > baseRun.Advance[^1] + 8, $"load {r.Sim.Bus.Ram[Platform.A(0x2F7)]:X2}, fuel column {baseRun.Sim.Bus.Ram[Platform.A(0x1D3)]} -> {r.Sim.Bus.Ram[Platform.A(0x1D3)]}, advance {baseRun.Advance[^1]:0} -> {r.Advance[^1]:0}");
        var cross = new Dictionary<string, byte[]>(on) { ["alphan_tpscross"] = B(0x7F) };   // 50 %
        var below = Run(["FEAT_ALPHAN"], cross, [At(3000, 60, 25, 80)]);
        var above = Run(["FEAT_ALPHAN"], cross, [At(3000, 60, 75, 80)]);
        Check("  crossover at 50 % throttle: MAP below it, the table above", below.Sim.Bus.Ram[Platform.A(0x2F7)] == below.Sim.Bus.Ram[Platform.A(0xA7)] && above.Sim.Bus.Ram[Platform.A(0x2F7)] == 0x40,
            $"25 %: {below.Sim.Bus.Ram[Platform.A(0x2F7)]:X2} (MAP {below.Sim.Bus.Ram[Platform.A(0xA7)]:X2}), 75 %: {above.Sim.Bus.Ram[Platform.A(0x2F7)]:X2}");
    }

    // ------------------------------------------------------------------ TPS end points
    static void Test_TpsCal()
    {
        var on = new Dictionary<string, byte[]> { ["tpscal_enable"] = B(1), ["tpscal_min"] = B(0x4C), ["tpscal_max"] = B(0xE6) };
        int At_(double tps) => Run(["FEAT_TPSCAL"], on, [At(2500, 60, tps, 50)]).Sim.Bus.Ram[Platform.A(0xB9)];
        int closed = At_(25), open = At_(100), shut = At_(0), half = At_(62.5);
        Check("a sensor reading 25 % shut: 0 % (19h) there, 100 % (E5h) wide open", Math.Abs(closed - 0x19) <= 1 && Math.Abs(open - 0xE5) <= 1, $"{closed:X2}, {open:X2}");
        Check("  below its closed point stays at 0 %, half way is 50 %", shut == 0x19 && Math.Abs(half - 0x7F) <= 2, $"{shut:X2}, {half:X2}");
    }

    // ------------------------------------------------------------------ road speed correction
    static void Test_SpeedCorr()
    {
        // against the ECU's own reading at 100 % (80 km/h measured to a count or so, as the main loop's timing falls)
        int asRead = Run(["FEAT_SPEEDCORR"], new() { ["speedcorr_factor"] = B(0x80) }, [At(3000, 60, 30, 80)]).Sim.Bus.Ram[Platform.A(0xB4)];
        var r = Run(["FEAT_SPEEDCORR"], new() { ["speedcorr_factor"] = B(0x90) }, [At(3000, 60, 30, 80)]);   // 112.5 %
        Check("112.5 %: 80 km/h reads 90 (the reading at 100 % x 1.125)", Math.Abs(asRead - 80) <= 1 && Math.Abs(r.Sim.Bus.Ram[Platform.A(0xB4)] - asRead * 1.125) <= 1,
              $"{asRead} -> {r.Sim.Bus.Ram[Platform.A(0xB4)]} km/h");
        var top = Run(["FEAT_SPEEDCORR"], new() { ["speedcorr_factor"] = B(0xFF) }, [At(6000, 100, 100, 200)]);
        Check("  no further than 255", top.Sim.Bus.Ram[Platform.A(0xB4)] == 255, $"{top.Sim.Bus.Ram[Platform.A(0xB4)]} km/h");
    }

    // ------------------------------------------------------------------ ignition cut modifier
    static void Test_IgnCutMod()
    {
        string[] defs = ["FEAT_LAUNCH", "FEAT_IGNCUTMOD"];
        var launch = Armed(new Dictionary<string, byte[]> { ["launch_block"] = B(1), ["launch_set"] = W(P(4000)), ["launch_reset"] = W(P(3900)), ["launch_speed"] = B(5) }, "launch_input");
        var held = At(4500, 90, 100, 0);
        var plain = Run(defs, launch, [held], InputOn);
        Check("built in, off: the launch cut is the plain cut", SparkCut(plain), Rates(plain));
        var mod = new Dictionary<string, byte[]>(launch) { ["icm_enable"] = B(1), ["icm_cut_launch"] = B(24), ["icm_refire"] = B(24) };
        int samples = 0, cutting = 0, n = 0;
        var shaped = Run(defs, mod, [held], sim => { InputOn?.Invoke(sim); if (++n > 400) { samples++; if ((sim.Bus.Ram[0xFC] & 1) != 0) cutting++; } });
        double duty = cutting / (double)Math.Max(1, samples);
        Check("cut 49 ms, re-fire 49 ms: cut half the time, about half the sparks (150/s uncut)", duty > 0.35 && duty < 0.65 && shaped.IgnPerSec[^1] > 45 && shaped.IgnPerSec[^1] < 105,
            $"on {duty:P0}, {Rates(shaped)}");
        var norefire = Run(defs, new(mod) { ["icm_refire"] = B(0) }, [held], InputOn);
        Check("  re-fire 0: the plain cut", SparkCut(norefire), Rates(norefire));
        var extras = new Dictionary<string, byte[]>(mod) { ["icm_enrich"] = B(0x80 + 26), ["icm_static_on"] = B(1), ["icm_static"] = B(0x30) };
        int minAdv = 255, maxAdv = 0;
        var cut = Run(defs, extras, [held], sim => { InputOn?.Invoke(sim); minAdv = Math.Min(minAdv, sim.Bus.Ram[Platform.Adv]); maxAdv = Math.Max(maxAdv, sim.Bus.Ram[Platform.Adv]); });
        Check("while cutting: +10 % fuel", Signed(Word(cut, FuelSum)) == 26, $"{Signed(Word(cut, FuelSum))} /256");
        Check("  and the timing held at the static value", cut.Sim.Bus.Ram[Platform.Adv] == 0x30, $"246h = {cut.Sim.Bus.Ram[Platform.Adv]:X2}");
        var free = Run(defs, extras, [At(3000, 60, 40, 0)], InputOn);
        Check("below the launch rpm: no extra fuel, the timing its own", Word(free, FuelSum) == 0 && free.Sim.Bus.Ram[Platform.Adv] != 0x30 && Running(free),
            $"{Signed(Word(free, FuelSum))} /256, 246h = {free.Sim.Bus.Ram[Platform.Adv]:X2}");
    }

    // ------------------------------------------------------------------ extended maps
    static void Test_ExtMaps()
    {
        foreach (var (rpm, map, tps) in new[] { (850.0, 33.0, 0.0), (2500, 45, 15), (3000, 60, 30), (4500, 85, 70), (6000, 100, 100) })
        {
            double Pulse(string[] defs) { double s = 0; int n = 0; Run(defs, [], [At(rpm, map, tps, 60)], sim => { if (++n > 200) s += sim.Bus.Ram[Platform.A(0x3AE)] | sim.Bus.Ram[Platform.A(0x3AF)] << 8; }); return s / Math.Max(1, n - 200); }
            var a = Run([], [], [At(rpm, map, tps, 60)]); var b = Run(["FEAT_EXTMAPS"], [], [At(rpm, map, tps, 60)]);
            double pa = Pulse([]), pb = Pulse(["FEAT_EXTMAPS"]);
            Check($"{rpm} rpm {map} kPa: 20-column maps give the stock fuel and timing", Math.Abs(pb / pa - 1) < 0.02 && Math.Abs(a.Advance[^1] - b.Advance[^1]) <= 2,   // an average of samples: 2 counts (0.5 deg), as the other same-engine checks
                $"fuel x {pb / pa:0.000}, advance {a.Advance[^1]:0.0} / {b.Advance[^1]:0.0}");
        }
    }
}
