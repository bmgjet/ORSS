// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Calibration;

namespace OkiRomSim.Tests;

/// Datalogging, over a scripted link (no cable, no ECU): the Demon relay's frame checks, auto-detection leaving the line plain when
/// nothing answers, logs saved with a decimal comma, the channel list of a log whose frames carry different extra channels, and the
/// smoother leaving flag bytes alone.
static class DatalogTests
{
    /// A link with nothing on the far end but what the test puts there: each write may queue an answer.
    sealed class ScriptedLink(Func<byte[], byte[]?>? answer = null) : IByteLink
    {
        readonly Queue<byte> _in = new();
        public string Name => "scripted";
        public bool Echo = true;
        public int Baud = -1;
        public int Writes;
        public void Write(byte[] data)
        {
            Writes++;
            if (answer?.Invoke(data) is { } a) foreach (var b in a) _in.Enqueue(b);
        }
        public int Read(byte[] buffer, int offset, int count, int timeoutMs)
        {
            int n = 0;
            while (n < count && _in.Count > 0) buffer[offset + n++] = _in.Dequeue();
            return n;
        }
        public void Discard() => _in.Clear();
        public void SetEcho(bool on) => Echo = on;
        public void SetBaud(int baud) => Baud = baud;
        public void Wait(int ms) { }
    }

    /// The Demon's answer to 'd' for a frame request: status, the 51 frame bytes and the ECU's checksum, five analog words, the footer,
    /// and the Demon's sum of all that (the layout EmulatorRelay reads).
    static byte[] DemonFrame(byte[] frame, byte footer, bool goodEcuSum = true)
    {
        var r = new List<byte> { 0x00 };
        r.AddRange(frame);
        byte ecu = HondaDatalog.Checksum(frame, frame.Length);
        r.Add(goodEcuSum ? ecu : (byte)(ecu + 1));
        for (int k = 0; k < 5; k++) { r.Add(0x01); r.Add(0x00); }
        r.Add(footer);
        r.Add(HondaDatalog.Checksum([.. r], r.Count));
        return [.. r];
    }

    public static void Run()
    {
        // ---- the Demon relay: the footer says whether the ECU answered, not the frame's first byte
        var frame = new byte[HondaDatalog.FrameLength];
        for (int i = 0; i < frame.Length; i++) frame[i] = (byte)(0x30 + i);
        frame[0] = 0x54;     // a first byte of 54h: a reading like any other (it was taken for "the ECU did not answer")
        LogFrame? Poll(byte[] answer, out string note)
        {
            var relay = new EmulatorRelay(new MultiByte90()) { PostWritePauseMs = 0 };
            return relay.Poll(new ScriptedLink(w => w is [(byte)'d'] ? answer : null), 0, out note);
        }
        var f1 = Poll(DemonFrame(frame, 0x00), out var n1);
        T.Check("a relayed frame whose first byte is 54h is taken (the footer, not the first byte, says the ECU answered)", f1 != null, n1);
        if (f1 != null) T.Check("... with the Demon's five analog inputs as channels", Enumerable.Range(1, 5).All(k => f1.Extra.ContainsKey($"emu_a{k}_v")));
        var f2 = Poll(DemonFrame(frame, (byte)'T'), out var n2);
        T.Check("a footer of 'T' is the ECU not answering the Demon: no frame", f2 == null && n2.Contains("did not answer"), n2);
        var f3 = Poll(DemonFrame(frame, 0x00, goodEcuSum: false), out var n3);
        T.Check("a bad ECU checksum is still refused", f3 == null, n3);

        // ---- auto-detection on a line where nothing answers puts the line back to plain, at the datalog's speed
        var silent = new ScriptedLink();
        var (found, report) = DatalogProtocol.Detect(silent, quick: true);
        T.Check("detection on a silent line finds nothing", found == null, report.Split('\n').FirstOrDefault()?.Trim() ?? "");
        T.Check("... and leaves the line plain (no echo) at the datalog's speed, not at the stock tester link's 9600 with echo",
            !silent.Echo && silent.Baud == DatalogChannels.LineBaud, $"echo {silent.Echo}, {silent.Baud} baud (datalog speed {DatalogChannels.LineBaud})");

        // ---- a log saved by a spreadsheet where the decimal mark is a comma
        using (var s = T.NewScratch("datalog"))
        {
            var path = s.File("comma.csv");
            File.WriteAllText(path, "time_s;rpm;map_kpa;afr\r\n0;3000;60,5;14,7\r\n0,05;3100;61,5;14,6\r\n");
            var frames = LogFile.Load(path);
            T.Check("a ';' separated log with decimal commas reads 60,5 as 60.5 (every such value was skipped)",
                frames.Count == 2 && frames[0].MapKpa == 60.5 && frames[0].Get("afr") == 14.7 && Math.Abs(frames[1].T - 0.05) < 1e-9,
                frames.Count == 2 ? $"map {frames[0].MapKpa}, afr {frames[0].Get("afr")}, t {frames[1].T}" : $"{frames.Count} frames");
            var plain = s.File("plain.csv");
            File.WriteAllText(plain, "time_s,rpm,map_kpa\n0,3000,60.5\n0.05,3100,61.5\n");
            var pf = LogFile.Load(plain);
            T.Check("a ',' separated log with decimal points reads as before", pf.Count == 2 && pf[0].MapKpa == 60.5 && pf[1].Rpm == 3100);
        }

        // ---- the channel list of a log: frames with the same number of extra channels but different ones
        var a = new LogFrame { Rpm = 1000 }; a.Extra["afr"] = 14.7;
        var b = new LogFrame { Rpm = 1000 }; b.Extra["knock"] = 2;
        var chans = LogFrame.AllChannels([a, b]);
        T.Check("every channel of every frame is listed (knock after afr was missed: same count, same 'shape')",
            chans.Contains("afr") && chans.Contains("knock"), string.Join(", ", chans));

        // ---- the smoother: measurements are smoothed, flag and code bytes are not
        var sm = new DatalogSmoother { Enabled = true, Frames = 3, Blend = true };
        double[] codes = [0x80, 0x88, 0x80], afr = [14.0, 15.0, 14.0];
        var outCodes = new List<double>(); var outAfr = new List<double>();
        for (int i = 0; i < 3; i++)
        {
            var f = new LogFrame { Rpm = 3000 };
            f.Extra["fault_bits"] = codes[i];
            f.Extra["afr"] = afr[i];
            sm.Apply(f);
            outCodes.Add(f.Extra["fault_bits"]); outAfr.Add(f.Extra["afr"]);
        }
        T.Check("a flag byte (no unit) passes the smoother as it came (80h and 88h averaged made codes that were never set)",
            outCodes.SequenceEqual(codes), string.Join(", ", outCodes.Select(v => ((int)v).ToString("X2"))));
        T.Check("a measurement (afr) is still smoothed", Math.Abs(outAfr[2] - 14.3333) < 0.001, string.Join(", ", outAfr));
    }
}
