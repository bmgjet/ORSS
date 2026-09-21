using System.Text;
using Decoder = OkiRomSim.Core.Decoder;
using OkiRomSim.Core;

namespace OkiRomSim.Calibration;

/// What a ROM's datalogging looks like, worked out from the ROM itself rather than from a list of known protocols: the command bytes its serial code compares against, tried in a simulator until one produces a checksummed frame, and then the meaning of each byte found by changing one engine input at a time and watching which bytes follow it.
/// The result can be used straight away (DetectedProtocol) and saved with the project, so a ROM with its own datalog format still logs, graphs and overlays like the known ones.
public sealed class DatalogFieldMap
{
    /// Frame byte index -> channel name ("rpm" is a 16-bit pair, low byte first).
    public Dictionary<int, string> Bytes { get; set; } = new();
    public Dictionary<int, string> Words { get; set; } = new();

    public LogFrame Decode(byte[] raw, double t)
    {
        var f = new LogFrame { T = t, Raw = raw.ToArray() };
        foreach (var (i, name) in Words)
        {
            if (i + 1 >= raw.Length) continue;
            int w = raw[i] | raw[i + 1] << 8;
            switch (name)
            {
                case "rpm": f.Rpm = w == 0 ? 0 : Math.Round(1875000.0 / w); break;
                case "inj_ms": f.InjMs = Math.Round(w * 3.2 / 1000, 2); break;
                default: f.Extra[name] = w; break;
            }
        }
        foreach (var (i, name) in Bytes)
        {
            if (i >= raw.Length) continue;
            byte b = raw[i];
            switch (name)
            {
                case "map_kpa": f.MapKpa = Math.Round(HondaDatalog.MapKpa(b), 1); break;
                case "tps_pct": f.TpsPct = Math.Round(HondaDatalog.TpsPct(b), 1); break;
                case "ect_c": f.EctC = HondaDatalog.ThermistorC(b); break;
                case "iat_c": f.IatC = HondaDatalog.ThermistorC(b); break;
                case "o2_v": f.O2V = Math.Round(HondaDatalog.Volts(b), 3); break;
                case "batt_v": f.BattV = Math.Round(26.0 * b / 270.0, 2); break;
                case "speed_kmh": f.SpeedKmh = b; break;
                case "ign_deg": f.IgnDeg = b * 0.25 - 6; break;
                default: f.Extra[name] = b; break;
            }
        }
        for (int i = 0; i < raw.Length; i++)
            if (!Bytes.ContainsKey(i) && !Words.ContainsKey(i) && !Words.ContainsKey(i - 1)) f.Extra[$"b{i}"] = raw[i];
        return f;
    }

    public string Describe() =>
        string.Join(", ", Words.OrderBy(k => k.Key).Select(k => $"{k.Key}-{k.Key + 1}={k.Value}")
            .Concat(Bytes.OrderBy(k => k.Key).Select(k => $"{k.Key}={k.Value}")));
}

/// A protocol built from what was detected, so an unknown ROM logs like a known one.
public sealed class DetectedProtocol : DatalogProtocol
{
    public byte? HandshakeSend { get; set; }
    public byte? HandshakeReply { get; set; }
    public byte? Request { get; set; }
    public int FrameLength { get; set; }
    public DatalogFieldMap Map { get; set; } = new();
    public string Origin { get; set; } = "detected";

    public override string Name => "Detected layout";
    public override string Description =>
        $"{(HandshakeSend is byte h ? $"{h:X2}->{HandshakeReply:X2}, " : "")}{(Request is byte r ? $"{r:X2} -> " : "streamed ")}" +
        $"{FrameLength} bytes + checksum; {Map.Describe()}";

    public override bool Handshake(IByteLink link, out string note)
    {
        if (HandshakeSend is not byte send || HandshakeReply is not byte want) { note = "no handshake needed"; Drain(link); return true; }
        return HandshakeByte(link, send, want, out note);
    }

    public override LogFrame? Poll(IByteLink link, double t, out string note)
    {
        if (Request is not byte req) { note = "no request byte"; return null; }
        return Framed(link, req, FrameLength, raw => Map.Decode(raw, t), t, out note);
    }
}

public static class DatalogLayout
{
    /// The ROM's own serial port, for probing it.
    sealed class SimLink : IByteLink
    {
        readonly Simulator _sim;
        readonly Queue<byte> _rx = new();
        public SimLink(Simulator sim) { _sim = sim; }
        public string Name => "simulator";
        public void Run(double seconds)
        {
            ulong end = _sim.Cpu.Cycles + (ulong)(seconds * Bus.CpuHz);
            while (_sim.Cpu.Cycles < end && _sim.StepOne() != null)
                if ((_sim.Cpu.Instructions & 1023) == 0) _sim.SyncSensors();
            foreach (var b in _sim.Bus.TakeSerialTx()) _rx.Enqueue(b);
        }
        public void Write(byte[] data) => _sim.Bus.QueueSerialRx(data, (uint)(Bus.CpuHz * 10 / 38400));
        public int Read(byte[] buffer, int offset, int count, int timeoutMs)
        {
            ulong end = _sim.Cpu.Cycles + (ulong)(timeoutMs / 1000.0 * Bus.CpuHz);
            while (_rx.Count < count && _sim.Cpu.Cycles < end)
            {
                for (int i = 0; i < 2000 && _sim.StepOne() != null; i++)
                    if ((_sim.Cpu.Instructions & 1023) == 0) _sim.SyncSensors();
                foreach (var b in _sim.Bus.TakeSerialTx()) _rx.Enqueue(b);
            }
            int n = 0;
            while (n < count && _rx.Count > 0) buffer[offset + n++] = _rx.Dequeue();
            return n;
        }
        public void Discard() { Run(0.002); _rx.Clear(); }
    }

    public sealed record Result(DetectedProtocol? Protocol, DatalogProtocol? Known, string Report);

    /// Boot `rom` in a simulator and work out how to datalog it. `progress` is called with each step for the UI; `extraCommands` are bytes to try first (from the ROM's code).
    public static Result Detect(byte[] rom, Action<string>? progress = null, CancellationToken ct = default)
    {
        var report = new StringBuilder();
        void Say(string s) { report.AppendLine(s); progress?.Invoke(s); }

        var sim = new Simulator { FastForwardDelayLoops = true };
        sim.LoadRom(rom);
        sim.Engine.Rpm = 2500; sim.Engine.MapKpa = 60; sim.Engine.TpsPct = 12; sim.Engine.EctCelsius = 85;
        sim.Engine.IatCelsius = 25; sim.Engine.O2Volts = 0.45; sim.Engine.VbattVolts = 14.2; sim.Engine.SpeedKmh = 40;
        sim.SyncSensors();
        var link = new SimLink(sim);
        Say("booting the ROM...");
        link.Run(5.5);
        link.Discard();

        // the known protocols first: no point detecting what is already understood
        var (known, knownReport) = DatalogProtocol.Detect(link);
        if (known != null)
        {
            Say($"this ROM speaks {known.Name}: {known.Description}");
            return new Result(null, known, report + knownReport);
        }
        Say("none of the known protocols answered; looking at the ROM's own serial code");

        var candidates = CommandBytes(rom).ToList();
        Say($"{candidates.Count} command byte(s) to try: {string.Join(" ", candidates.Select(c => c.ToString("X2")))}");

        byte[] Ask(byte cmd, int expect, int ms = 200)
        {
            link.Discard();
            link.Write(new[] { cmd });
            var buf = new byte[Math.Max(expect, 128)];
            int got = link.Read(buf, 0, buf.Length, ms);
            return buf[..got];
        }

        // one byte back = a handshake; a long checksummed answer = a frame straight away
        var handshakes = new List<(byte Send, byte Reply)>();
        DetectedProtocol? found = null;
        foreach (var c in candidates)
        {
            ct.ThrowIfCancellationRequested();
            var r = Ask(c, 64);
            if (r.Length == 1 && r[0] != c) { handshakes.Add((c, r[0])); Say($"  {c:X2} -> {r[0]:X2} (handshake?)"); }
            else if (r.Length >= 8 && HondaDatalog.Checksum(r, r.Length - 1) == r[^1])
            {
                Say($"  {c:X2} -> {r.Length - 1} bytes + checksum (a frame with no handshake)");
                found = new DetectedProtocol { Request = c, FrameLength = r.Length - 1 };
                break;
            }
        }
        if (found == null)
            foreach (var (send, reply) in handshakes)
            {
                foreach (var c in candidates)
                {
                    ct.ThrowIfCancellationRequested();
                    link.Discard();
                    link.Write(new[] { send });
                    link.Read(new byte[4], 0, 1, 100);
                    var r = Ask(c, 64);
                    if (r.Length < 8 || HondaDatalog.Checksum(r, r.Length - 1) != r[^1]) continue;
                    Say($"  handshake {send:X2}->{reply:X2}, then {c:X2} -> {r.Length - 1} bytes + checksum");
                    found = new DetectedProtocol { HandshakeSend = send, HandshakeReply = reply, Request = c, FrameLength = r.Length - 1 };
                    break;
                }
                if (found != null) break;
            }
        if (found == null)
        {
            Say("no command produced a checksummed frame. The ROM may have no datalogging, or use a format this cannot drive yet (see the packet monitor).");
            return new Result(null, null, report.ToString());
        }

        // what each byte means: change one input at a time and see which bytes follow
        Say("working out what each byte is by changing one engine input at a time...");
        byte[]? Frame()
        {
            for (int tries = 0; tries < 3; tries++)
            {
                if (found.HandshakeSend is byte h)
                {
                    link.Discard();
                    link.Write(new[] { h });
                    link.Read(new byte[4], 0, 1, 100);
                }
                var r = Ask(found.Request!.Value, found.FrameLength + 1, 300);
                if (r.Length >= found.FrameLength + 1 && HondaDatalog.Checksum(r, found.FrameLength) == r[found.FrameLength])
                    return r[..found.FrameLength];
            }
            return null;
        }
        var baseline = Frame();
        if (baseline == null) { Say("the frame stopped coming while mapping it"); return new Result(found, null, report.ToString()); }

        var map = new DatalogFieldMap();
        var used = new HashSet<int>();
        void Vary(string name, Action set, Action back, bool word = false)
        {
            ct.ThrowIfCancellationRequested();
            set();
            sim.SyncSensors();
            link.Run(0.4);
            var f = Frame();
            back();
            sim.SyncSensors();
            link.Run(0.2);
            if (f == null) return;
            var moved = Enumerable.Range(0, found.FrameLength).Where(i => f[i] != baseline[i] && !used.Contains(i)).ToList();
            if (moved.Count == 0) { Say($"  {name}: no byte followed it"); return; }
            if (word)
            {
                // a 16-bit value: two neighbouring bytes, low first
                for (int k = 0; k + 1 < moved.Count; k++)
                    if (moved[k + 1] == moved[k] + 1)
                    {
                        map.Words[moved[k]] = name;
                        used.Add(moved[k]); used.Add(moved[k] + 1);
                        Say($"  {name}: bytes {moved[k]}-{moved[k] + 1}");
                        return;
                    }
            }
            int at = moved[0];
            map.Bytes[at] = name;
            used.Add(at);
            Say($"  {name}: byte {at}");
        }

        var e = sim.Engine;
        Vary("rpm", () => e.Rpm = 5000, () => e.Rpm = 2500, word: true);
        Vary("map_kpa", () => e.MapKpa = 95, () => e.MapKpa = 60);
        Vary("tps_pct", () => e.TpsPct = 80, () => e.TpsPct = 12);
        Vary("ect_c", () => e.EctCelsius = 20, () => e.EctCelsius = 85);
        Vary("iat_c", () => e.IatCelsius = 70, () => e.IatCelsius = 25);
        Vary("o2_v", () => e.O2Volts = 0.9, () => e.O2Volts = 0.45);
        Vary("batt_v", () => e.VbattVolts = 12.0, () => e.VbattVolts = 14.2);
        Vary("speed_kmh", () => e.SpeedKmh = 120, () => e.SpeedKmh = 40);
        found.Map = map;
        found.Origin = "detected from the ROM";
        Say("layout: " + (map.Describe().Length > 0 ? map.Describe() : "nothing identified; every byte is logged raw"));
        return new Result(found, null, report.ToString());
    }

    /// Bytes the ROM's serial receive code compares the incoming byte against - its commands - plus the ones the known protocols use.
    public static IEnumerable<byte> CommandBytes(byte[] rom)
    {
        var found = new List<byte>();
        int rx = rom[0x0A] | rom[0x0B] << 8;                 // the serial receive vector
        if (rx >= 0x38 && rx < rom.Length)
        {
            // follow the handler for a few hundred instructions and collect CMP immediates
            var seen = new HashSet<int>();
            var todo = new Stack<int>();
            todo.Push(rx);
            bool dd = false;
            while (todo.Count > 0 && seen.Count < 600)
            {
                int pc = todo.Pop();
                while (pc >= 0x38 && pc < rom.Length && seen.Add(pc))
                {
                    int at = pc;
                    var d = Decoder.Decode(dd, i => at + i < rom.Length ? rom[at + i] : (byte)0xFF);
                    if (d == null) break;
                    if (d.DdAfter is bool v) dd = v;
                    string op = d.Mnemonic.Split(' ')[0];
                    if (op is "CMPB" && d.Mnemonic.Contains("#N8")) found.Add((byte)d.Fields.N8);
                    if (op is "RT" or "RTI" or "BRK") break;
                    if (d.Mnemonic.Contains("rel8")) todo.Push(pc + d.Len + d.Fields.Rel8);
                    if (op is "J" && d.Mnemonic.Contains("addr16")) { pc = d.Fields.Addr16; continue; }
                    pc += d.Len;
                }
            }
        }
        var order = found.GroupBy(b => b).OrderByDescending(g => g.Count()).Select(g => g.Key).ToList();
        foreach (var b in new byte[] { 0x10, 0x20, 0x90, 0xAB, 0x46, 0xC0, 0xC6 }) if (!order.Contains(b)) order.Add(b);
        return order.Take(40);
    }
}
