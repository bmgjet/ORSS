using System.Globalization;
using System.Text;
namespace OkiRomSim.Calibration;

/// One datalog sample: sensor readings from the car (what drives the simulator on playback), what the ECU reported doing (what the simulator is compared against), and any extra channels (wideband AFR, knock, aux inputs) by name.
public sealed class LogFrame
{
    public double T;                    // seconds from the start of the log
    public double? Rpm, MapKpa, TpsPct, EctC, IatC, O2V, BattV, SpeedKmh, BaroKpa;
    public double? InjMs, IgnDeg, IgnTableDeg;
    public bool? Vtec, FuelPump;
    /// The frame exactly as the ECU sent it, when the log came from its datalog stream.
    public byte[]? Raw;
    public string? Protocol;
    /// Extra channels: "afr", "lambda", "knock", aux channels named in Settings...
    public Dictionary<string, double> Extra { get; } = new(StringComparer.OrdinalIgnoreCase);

    public static readonly string[] Fields =
        { "rpm", "map_kpa", "tps_pct", "ect_c", "iat_c", "o2_v", "batt_v", "speed_kmh", "baro_kpa", "inj_ms", "ign_deg", "ign_table_deg", "vtec", "fuel_pump" };

    public static readonly Dictionary<string, string> Units = new(StringComparer.OrdinalIgnoreCase)
    {
        ["rpm"] = "rpm", ["map_kpa"] = "kPa", ["tps_pct"] = "%", ["ect_c"] = "°C", ["iat_c"] = "°C", ["o2_v"] = "V", ["batt_v"] = "V",
        ["speed_kmh"] = "km/h", ["baro_kpa"] = "kPa", ["inj_ms"] = "ms", ["ign_deg"] = "°", ["ign_table_deg"] = "°", ["vtec"] = "", ["fuel_pump"] = "",
        ["afr"] = "AFR", ["lambda"] = "λ",
    };

    public double? Get(string field) => field.ToLowerInvariant() switch
    {
        "rpm" => Rpm, "map_kpa" => MapKpa, "tps_pct" => TpsPct, "ect_c" => EctC, "iat_c" => IatC, "o2_v" => O2V,
        "batt_v" => BattV, "speed_kmh" => SpeedKmh, "baro_kpa" => BaroKpa, "inj_ms" => InjMs, "ign_deg" => IgnDeg,
        "ign_table_deg" => IgnTableDeg, "vtec" => Vtec is bool v ? (v ? 1 : 0) : null,
        "fuel_pump" => FuelPump is bool f ? (f ? 1 : 0) : null,
        "t" or "time_s" => T,
        var other => Extra.TryGetValue(other, out var x) ? x : null,
    };

    public void Set(string field, double v)
    {
        switch (field.ToLowerInvariant())
        {
            case "rpm": Rpm = v; break; case "map_kpa": MapKpa = v; break; case "tps_pct": TpsPct = v; break;
            case "ect_c": EctC = v; break; case "iat_c": IatC = v; break; case "o2_v": O2V = v; break;
            case "batt_v": BattV = v; break; case "speed_kmh": SpeedKmh = v; break; case "baro_kpa": BaroKpa = v; break;
            case "inj_ms": InjMs = v; break; case "ign_deg": IgnDeg = v; break; case "ign_table_deg": IgnTableDeg = v; break;
            case "vtec": Vtec = v != 0; break; case "fuel_pump": FuelPump = v != 0; break;
            default: Extra[field] = v; break;
        }
    }

    /// Every channel this frame has, in display order.
    public IEnumerable<string> Channels() => Fields.Where(f => Get(f) != null).Concat(Extra.Keys.OrderBy(k => k));
}

/// Honda OBD1 frame layouts and scalings, as the established tuning tools read them.
public static class HondaDatalog
{
    public const int FrameLength = 51;

    public static double Volts(byte b) => b * 5.0 / 255.0;
    public static double MapKpa(byte b) => (b * 7.221 - 59) / 10;
    public static double TpsPct(byte b) => Math.Clamp((b - 25.0) / 2.04, 0, 100);

    /// The coolant / intake temperature curve for these sensors: byte -> degrees C, 0 = 141 C down to 255 = -26 C. The same 256-entry curve the established tuning tools use, so logged temperatures read the same everywhere.
    static readonly double[] TempC =
    {
        140.961, 138.694, 136.479, 134.314, 132.198, 130.129, 128.108, 126.132,
        124.2, 122.312, 120.467, 118.663, 116.9, 115.176, 113.491, 111.843,
        110.232, 108.657, 107.117, 105.611, 104.139, 102.699, 101.29, 99.9123,
        98.5646, 97.2463, 95.9564, 94.6944, 93.4595, 92.251, 91.0682, 89.9104,
        88.7771, 87.6674, 86.5809, 85.5169, 84.4749, 83.4541, 82.454, 81.4742,
        80.5139, 79.5728, 78.6502, 77.7457, 76.8587, 75.9887, 75.1354, 74.2982,
        73.4766, 72.6702, 71.8787, 71.1014, 70.3382, 69.5884, 68.8518, 68.1279,
        67.4164, 66.717, 66.0292, 65.3527, 64.6871, 64.0322, 63.3876, 62.753,
        62.1281, 61.5126, 60.9062, 60.3086, 59.7195, 59.1388, 58.566, 58.001,
        57.4435, 56.8932, 56.35, 55.8136, 55.2838, 54.7603, 54.243, 53.7316,
        53.226, 52.7259, 52.2312, 51.7417, 51.2571, 50.7774, 50.3024, 49.8318,
        49.3656, 48.9035, 48.4455, 47.9913, 47.5409, 47.094, 46.6507, 46.2106,
        45.7738, 45.34, 44.9092, 44.4812, 44.0559, 43.6333, 43.2131, 42.7953,
        42.3799, 41.9666, 41.5554, 41.1461, 40.7388, 40.3333, 39.9295, 39.5274,
        39.1268, 38.7276, 38.3299, 37.9335, 37.5382, 37.1442, 36.7512, 36.3592,
        35.9682, 35.578, 35.1886, 34.8, 34.412, 34.0247, 33.6378, 33.2515,
        32.8655, 32.4799, 32.0946, 31.7096, 31.3247, 30.9399, 30.5552, 30.1706,
        29.7858, 29.401, 29.016, 28.6308, 28.2454, 27.8596, 27.4735, 27.087,
        26.7, 26.3124, 25.9244, 25.5357, 25.1463, 24.7562, 24.3654, 23.9737,
        23.5812, 23.1878, 22.7934, 22.398, 22.0016, 21.6041, 21.2054, 20.8056,
        20.4045, 20.0022, 19.5985, 19.1934, 18.787, 18.3791, 17.9697, 17.5587,
        17.1462, 16.732, 16.3162, 15.8986, 15.4793, 15.0582, 14.6353, 14.2105,
        13.7838, 13.3552, 12.9246, 12.4919, 12.0572, 11.6205, 11.1816, 10.7405,
        10.2973, 9.85183, 9.40413, 8.95416, 8.5019, 8.04731, 7.59037, 7.13106,
        6.66936, 6.20526, 5.73872, 5.26973, 4.79829, 4.32437, 3.84797, 3.36908,
        2.88769, 2.40381, 1.91741, 1.42851, 0.93711, 0.443211, -0.0531673, -0.552034,
        -1.05337, -1.55713, -2.06334, -2.57195, -3.08295, -3.5963, -4.11196, -4.62992,
        -5.15012, -5.67251, -6.19708, -6.72373, -7.25245, -7.78316, -8.31578, -8.85028,
        -9.38656, -9.92454, -10.4642, -11.0053, -11.5479, -12.0919, -12.6371, -13.1835,
        -13.7308, -14.2791, -14.8282, -15.3779, -15.9282, -16.4788, -17.0296, -17.5805,
        -18.1313, -18.6818, -19.2319, -19.7814, -20.33, -20.8776, -21.4239, -21.9688,
        -22.5121, -23.0534, -23.5926, -24.1294, -24.6635, -25.1947, -25.7227, -26.2472,
    };

    public static double ThermistorC(byte b) => Math.Round(TempC[b], 1);

    /// The 51-byte main table (request 90h or 20h, or byte requests C0h+n).
    public static LogFrame Decode(byte[] f, double t)
    {
        ushort period = (ushort)(f[6] | f[7] << 8);
        ushort inj = (ushort)(f[17] | f[18] << 8);
        return new LogFrame
        {
            T = t, Raw = f.ToArray(),
            EctC = ThermistorC(f[0]), IatC = ThermistorC(f[1]), O2V = Math.Round(Volts(f[2]), 3),
            BaroKpa = f[3] == 0 ? null : Math.Round(MapKpa((byte)Math.Min(255, f[3] / 2 + 24)), 1),
            MapKpa = Math.Round(MapKpa(f[4]), 1), TpsPct = Math.Round(TpsPct(f[5]), 1),
            Rpm = period == 0 ? 0 : Math.Round(1875000.0 / period),
            SpeedKmh = f[16],
            InjMs = Math.Round(inj * 3.2 / 1000, 2),
            IgnDeg = f[19] * 0.25 - 6, IgnTableDeg = f[20] * 0.25 - 6,
            BattV = Math.Round(26.0 * f[25] / 270.0, 2),
            Vtec = (f[8] >> 3 & 1) != 0,
            FuelPump = (f[22] & 1) != 0,
        };
    }

    /// QD3 frame: 40 bytes, starting 46h 26h.
    public static LogFrame DecodeQd3(byte[] f, double t)
    {
        ushort period = (ushort)(f[2] | f[3] << 8);
        ushort inj = (ushort)(f[7] | f[8] << 8);
        var fr = new LogFrame
        {
            T = t, Raw = f.ToArray(),
            Rpm = period == 0 ? 0 : Math.Round(1875000.0 / period),
            IgnDeg = f[9] * 0.25 - 6,
            O2V = Math.Round(Volts(f[11]), 3),
            SpeedKmh = f[20],
            BattV = Math.Round(26.0 * f[21] / 270.0, 2),
            MapKpa = Math.Round(MapKpa(f[22]), 1),
            TpsPct = Math.Round(TpsPct(f[24]), 1),
            IatC = ThermistorC(f[25]),
            EctC = ThermistorC(f[33]),
        };
        fr.Extra["inj_raw"] = inj;
        return fr;
    }

    public static byte Checksum(byte[] data, int count)
    {
        byte s = 0;
        for (int i = 0; i < count; i++) s += data[i];
        return s;
    }
}

// ---------------------------------------------------------------- serial protocols

/// A byte pipe to an ECU: a serial port, or the simulated ROM's own UART.
public interface IByteLink
{
    string Name { get; }
    void Write(byte[] data);
    /// Read up to `count` bytes, waiting at most `timeoutMs` for them; returns how many arrived.
    int Read(byte[] buffer, int offset, int count, int timeoutMs);
    void Discard();
}

public enum PacketDir { Tx, Rx }
public sealed record Packet(DateTime Time, PacketDir Dir, byte[] Bytes, string Note);

/// One way of datalogging an OBD1 ROM. New ROM families add a subclass and a line in All.
public abstract class DatalogProtocol
{
    public abstract string Name { get; }
    public abstract string Description { get; }
    public virtual int Baud => 38400;
    public int TimeoutMs { get; set; } = 250;
    /// Called with every packet sent and received (for the packet monitor).
    public Action<Packet>? OnPacket { get; set; }

    /// Open the conversation; false when the ROM does not speak this protocol.
    public abstract bool Handshake(IByteLink link, out string note);
    /// One frame, or null (timeout / bad checksum; `note` says which).
    public abstract LogFrame? Poll(IByteLink link, double t, out string note);

    protected void Send(IByteLink link, params byte[] b)
    {
        link.Write(b);
        OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Tx, b, ""));
    }

    /// Let the line go quiet: read and drop whatever is still arriving (a long answer to an earlier probe), until nothing comes for a while. A buffer discard alone misses the bytes still on the wire.
    protected static void Drain(IByteLink link, int quietMs = 40)
    {
        link.Discard();
        var junk = new byte[256];
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < 600 && link.Read(junk, 0, junk.Length, quietMs) > 0) { }
    }

    protected byte[] Receive(IByteLink link, int count, string what)
    {
        var buf = new byte[count];
        int got = 0;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (got < count && sw.ElapsedMilliseconds < TimeoutMs)
        {
            int n = link.Read(buf, got, count - got, Math.Max(1, TimeoutMs - (int)sw.ElapsedMilliseconds));
            if (n <= 0) break;
            got += n;
        }
        var data = buf[..got];
        OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Rx, data, got < count ? $"{what}: {got}/{count} bytes (timeout)" : what));
        return data;
    }

    protected bool HandshakeByte(IByteLink link, byte send, byte expect, out string note)
    {
        Drain(link);
        Send(link, send);
        var r = Receive(link, 1, "handshake");
        if (r.Length == 1 && r[0] == expect) { note = $"handshake {send:X2} -> {expect:X2}"; return true; }
        note = r.Length == 0 ? $"no answer to {send:X2}" : r[0] == send ? $"echo of {send:X2}: the datalog jumper (J12 USDM / J4 JDM) is still fitted" : $"answer {r[0]:X2} to {send:X2}, expected {expect:X2}";
        return false;
    }

    protected LogFrame? Framed(IByteLink link, byte request, int dataLength, Func<byte[], LogFrame> decode, double t, out string note)
    {
        // the ECU ignores a request that arrives straight on the heels of its handshake answer
        // straight on the heels of their handshake answer
        Drain(link, quietMs: 12);
        Send(link, request);
        var r = Receive(link, dataLength + 1, "frame");
        if (r.Length < dataLength + 1) { note = "timeout"; return null; }
        if (HondaDatalog.Checksum(r, dataLength) != r[dataLength]) { note = "bad checksum"; return null; }
        note = "ok";
        var f = decode(r[..dataLength]);
        f.T = t; f.Protocol = Name;
        return f;
    }

    public static IReadOnlyList<DatalogProtocol> All() => new DatalogProtocol[]
    {
        // order matters for Detect: the single-byte probe would accept any ROM that answers C6h
        new MultiByte90(), new IsrMultiByte(), new Qd3Protocol(), new RawFrame10(), new ByteRequestC0(),
    };

    /// Older names these protocols were saved under, so a settings file from an earlier build still picks the same protocol.
    static readonly Dictionary<string, string> Aliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["multi-byte"] = "Multi-byte 90h",
        ["ISR"] = "Multi-byte 20h", ["BMTune"] = "Multi-byte 20h",
        ["single-byte"] = "Byte requests C0h",
        ["raw"] = "Raw 10h frame",
    };

    public static DatalogProtocol? ByName(string name)
    {
        if (Aliases.TryGetValue(name, out var canonical)) name = canonical;
        return All().FirstOrDefault(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
    }

    /// Try every protocol's handshake and first frame; the first that works wins.
    public static (DatalogProtocol? Protocol, string Report) Detect(IByteLink link, Action<Packet>? onPacket = null)
    {
        var report = new StringBuilder();
        foreach (var p in All())
        {
            p.OnPacket = onPacket;
            try
            {
                if (!p.Handshake(link, out var note)) { report.AppendLine($"{p.Name}: {note}"); continue; }
                LogFrame? f = null; string pn = "";
                for (int i = 0; i < 3 && f == null; i++) f = p.Poll(link, 0, out pn);
                if (f != null) { report.AppendLine($"{p.Name}: {note}, frame ok"); return (p, report.ToString()); }
                report.AppendLine($"{p.Name}: {note}, but no good frame ({pn})");
            }
            catch (Exception ex) { report.AppendLine($"{p.Name}: {ex.Message}"); }
        }
        return (null, report.ToString());
    }
}

/// Multi-byte 90h: handshake ABh -> CDh, then 90h returns the 51-byte main table + checksum.
public sealed class MultiByte90 : DatalogProtocol
{
    public override string Name => "Multi-byte 90h";
    public override string Description => "handshake AB→CD, then 90h → 51 bytes + checksum";
    public override bool Handshake(IByteLink link, out string note) => HandshakeByte(link, 0xAB, 0xCD, out note);
    public override LogFrame? Poll(IByteLink link, double t, out string note) => Framed(link, 0x90, HondaDatalog.FrameLength, f => HondaDatalog.Decode(f, t), t, out note);
}

/// Multi-byte 20h (the ISR v2 / BMTune style): handshake 10h -> CDh, then 20h returns the same 51-byte table.
public sealed class IsrMultiByte : DatalogProtocol
{
    public override string Name => "Multi-byte 20h";
    public override string Description => "handshake 10→CD, then 20h → 51 bytes + checksum (ISR v2 style)";
    public override bool Handshake(IByteLink link, out string note) => HandshakeByte(link, 0x10, 0xCD, out note);
    public override LogFrame? Poll(IByteLink link, double t, out string note)
    {
        var f = Framed(link, 0x20, HondaDatalog.FrameLength, x => HondaDatalog.Decode(x, t), t, out note);
        if (f?.Raw is { } raw)
        {
            // ISR's own extras: switch inputs, ELD, EGR, B6, IACV
            f.Extra["clutch"] = raw[21] & 1; f.Extra["brake"] = raw[21] >> 1 & 1; f.Extra["ac"] = raw[21] >> 2 & 1;
            f.Extra["eld_v"] = Math.Round(HondaDatalog.Volts(raw[24]), 2);
            f.Extra["egr_v"] = Math.Round(HondaDatalog.Volts(raw[44]), 2);
            f.Extra["b6_v"] = Math.Round(HondaDatalog.Volts(raw[45]), 2);
            f.Extra["iacv"] = raw[49] | raw[50] << 8;
        }
        return f;
    }
}

/// QD3: handshake ABh to BCh, then 46h returns a 40-byte frame + checksum (frame starts 46h 26h).
public sealed class Qd3Protocol : DatalogProtocol
{
    public override string Name => "QD3";
    public override string Description => "QD3 (AB→BC, 46h → 40 bytes + checksum)";
    public override bool Handshake(IByteLink link, out string note) => HandshakeByte(link, 0xAB, 0xBC, out note);
    public override LogFrame? Poll(IByteLink link, double t, out string note) => Framed(link, 0x46, 40, f => HondaDatalog.DecodeQd3(f, t), t, out note);
}

/// Byte requests: C0h+n returns byte n of the main table, one at a time. Slower, but needs no multi-byte support in the ROM.
public sealed class ByteRequestC0 : DatalogProtocol
{
    public override string Name => "Byte requests C0h";
    public override string Description => "one byte per request (C0h+n → table byte n)";
    public int Count { get; set; } = 26;       // the bytes the main-table decode uses
    public override bool Handshake(IByteLink link, out string note)
    {
        Drain(link);
        Send(link, 0xC6);
        var a = Receive(link, 1, "probe C6");
        Send(link, 0xC7);
        var b = Receive(link, 1, "probe C7");
        // an echo, an idle line (FF) or one answer to everything ('?' 3F) is not this protocol
        if (a.Length == 1 && b.Length == 1 && !(a[0] == 0xC6 && b[0] == 0xC7) && a[0] != b[0])
        { note = $"C6/C7 answered {a[0]:X2} {b[0]:X2} (rpm {(1875000.0 / Math.Max(1, a[0] | b[0] << 8)):0})"; return true; }
        note = a.Length == 0 ? "no answer to C6" : "answers look like an echo or an idle line";
        return false;
    }
    public override LogFrame? Poll(IByteLink link, double t, out string note)
    {
        var frame = new byte[HondaDatalog.FrameLength];
        for (int n = 0; n < Count; n++)
        {
            link.Discard();
            Send(link, (byte)(0xC0 + n));
            var r = Receive(link, 1, $"byte {n}");
            if (r.Length != 1) { note = $"timeout at byte {n}"; return null; }
            frame[n] = r[0];
        }
        if (frame.Take(Count).Distinct().Count() <= 1) { note = "every request got the same answer: not a single-byte datalog ROM"; return null; }
        note = "ok";
        var f = HondaDatalog.Decode(frame, t);
        f.Protocol = Name;
        return f;
    }
}

/// ROMs that answer 10h with a checksummed frame of their own layout: a 31-byte frame 31-byte frame (+ checksum) continuously once asked. The frame length is found from the data (a length at which consecutive chunks all carry a valid checksum), and each byte is logged raw as a channel b0, b1, ... until its layout is written up.
public sealed class RawFrame10 : DatalogProtocol
{
    public override string Name => "Raw 10h frame";
    public override string Description => "10h → checksummed frames of any length, requested or streamed; bytes shown raw";
    int _length;        // including the checksum byte
    bool _streaming;
    readonly List<byte> _buf = new();

    public override bool Handshake(IByteLink link, out string note)
    {
        Drain(link);
        _buf.Clear();
        Send(link, 0x10);
        var chunk = new byte[256];
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < Math.Max(TimeoutMs, 400) && _buf.Count < 1024)
        {
            int n = link.Read(chunk, 0, chunk.Length, 60);
            if (n <= 0 && _buf.Count > 0) break;          // the answer has ended
            for (int i = 0; i < n; i++) _buf.Add(chunk[i]);
        }
        var data = _buf.ToArray();
        OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Rx, data, "frame length probe"));
        // a single frame: all of it sums to its last byte
        if (data.Length >= 4 && HondaDatalog.Checksum(data, data.Length - 1) == data[^1] && !(data.Length == 1 && data[0] == 0x10))
        {
            _length = data.Length; _streaming = false; _buf.Clear();
            note = $"{_length - 1}-byte frame on request"; return true;
        }
        // a stream: a length and offset at which three chunks in a row are valid frames
        for (int len = 5; len <= 80; len++)
            for (int off = 0; off < len && off + 3 * len <= data.Length; off++)
            {
                bool ok = true;
                for (int k = 0; k < 3 && ok; k++)
                    ok = HondaDatalog.Checksum(data[(off + k * len)..], len - 1) == data[off + k * len + len - 1];
                if (!ok) continue;
                _length = len; _streaming = true;
                _buf.RemoveRange(0, off);
                note = $"{len - 1}-byte frames streamed after 10h"; return true;
            }
        note = data.Length == 0 ? "no answer to 10h" : $"{data.Length} bytes without a valid checksum";
        return false;
    }

    public override LogFrame? Poll(IByteLink link, double t, out string note)
    {
        if (_length == 0) { note = "no handshake"; return null; }
        if (!_streaming)
            return Framed(link, 0x10, _length - 1, raw => Decode(raw, t), t, out note);
        var chunk = new byte[256];
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < TimeoutMs)
        {
            // stay in step: drop bytes until a valid frame starts the buffer
            while (_buf.Count >= _length && HondaDatalog.Checksum(_buf.ToArray(), _length - 1) != _buf[_length - 1]) _buf.RemoveAt(0);
            if (_buf.Count >= _length)
            {
                var raw = _buf.GetRange(0, _length - 1).ToArray();
                _buf.RemoveRange(0, _length);
                OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Rx, raw, "frame"));
                note = "ok";
                var f = Decode(raw, t);
                f.Protocol = Name;
                return f;
            }
            int n = link.Read(chunk, 0, chunk.Length, 50);
            for (int i = 0; i < n; i++) _buf.Add(chunk[i]);
            if (_buf.Count > 4096) _buf.RemoveRange(0, _buf.Count - 1024);
        }
        note = "timeout";
        return null;
    }

    static LogFrame Decode(byte[] raw, double t)
    {
        var fr = new LogFrame { T = t, Raw = raw.ToArray() };
        for (int i = 0; i < raw.Length; i++) fr.Extra[$"b{i}"] = raw[i];
        return fr;
    }
}

// ---------------------------------------------------------------- extra channels

/// A channel computed from each frame: a byte (or word, or bit) of the ECU's raw frame, or another channel, through an expression in x. How an aux analog input wired to a spare ECU input, a knock sensor count, or a digital switch gets into the log.
public sealed class AuxChannel
{
    public string Name { get; set; } = "aux1";
    public string Unit { get; set; } = "";
    /// "byte:N", "word:N" (little-endian), "bit:N.B", or "channel:<name>".
    public string Source { get; set; } = "byte:24";
    /// In x, e.g. "x * 5 / 255" for volts, "x / 10 + 10" for a 0-5 V wideband output as AFR.
    public string Expr { get; set; } = "x";
    /// A curve applied after the expression, for a sensor that is not a straight line (Settings > Targets > analog input curves). Null: the expression is the whole story.
    public LookupCurve? Curve { get; set; }

    public double? Evaluate(LogFrame f)
    {
        double? x = null;
        var parts = Source.Split(':', 2);
        if (parts.Length != 2) return null;
        var raw = f.Raw;
        switch (parts[0].Trim().ToLowerInvariant())
        {
            case "byte" when raw != null && int.TryParse(parts[1], out var i) && i >= 0 && i < raw.Length: x = raw[i]; break;
            case "word" when raw != null && int.TryParse(parts[1], out var w) && w >= 0 && w + 1 < raw.Length: x = raw[w] | raw[w + 1] << 8; break;
            case "bit" when raw != null:
                {
                    var bb = parts[1].Split('.');
                    if (bb.Length == 2 && int.TryParse(bb[0], out var bi) && int.TryParse(bb[1], out var bit) && bi >= 0 && bi < raw.Length)
                        x = raw[bi] >> (bit & 7) & 1;
                    break;
                }
            case "channel": x = f.Get(parts[1].Trim()); break;
        }
        if (x is not double v) return null;
        try
        {
            double value = Expression.Parse(Expr).Eval(v);
            return Curve is { Any: true } c ? c.Apply(value) : value;
        }
        catch { return null; }
    }
}

// ---------------------------------------------------------------- overlays

/// A logged channel laid over a table: the average (and count, min, max) of the channel in every cell the engine sat in, the cell chosen from the frame's rpm and load against the table's axes. How AFR from a wideband is compared with the fuel map, or knock with the ignition map.
public sealed class OverlayResult
{
    public required ItemDef Item { get; init; }
    public required string Channel { get; init; }
    public double[] Mean = Array.Empty<double>();
    public double[] Min = Array.Empty<double>();
    public double[] Max = Array.Empty<double>();
    public int[] Count = Array.Empty<int>();
    public int Frames;
    public string RowSource = "", ColSource = "";

    public string Render(double[] rowAxis, double[] colAxis)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"{Channel} over {Item.Name}: {Frames} frames used; rows by {RowSource}, columns by {ColSource}; mean (samples)");
        sb.Append("          ");
        for (int c = 0; c < Item.Cols; c++) sb.Append($"{(c < colAxis.Length ? colAxis[c] : c),10:0.#}");
        sb.AppendLine();
        for (int r = 0; r < Item.Rows; r++)
        {
            sb.Append($"{(r < rowAxis.Length ? rowAxis[r] : r),8:0.#}  ");
            for (int c = 0; c < Item.Cols; c++)
            {
                int i = r * Item.Cols + c;
                sb.Append(Count[i] == 0 ? "         ." : $"{Mean[i],6:0.##}({Math.Min(Count[i], 99),2})");
            }
            sb.AppendLine();
        }
        return sb.ToString();
    }
}

public static class LogOverlay
{
    /// Which frame channel feeds an axis, from the axis unit (rpm, kPa, mbar, %).
    public static (string Name, Func<LogFrame, double?> Get) AxisInput(DefinitionSet defs, AxisDef? axis, bool rows)
    {
        string unit = axis?.Unit ?? "";
        if (unit.Length == 0 && axis?.Formula != null) try { unit = defs.Formula(axis.Formula).Unit; } catch { }
        unit = unit.ToLowerInvariant();
        if (unit.Contains("rpm")) return ("rpm", f => f.Rpm);
        if (unit.Contains("mbar")) return ("map (mbar)", f => f.MapKpa * 10);
        if (unit.Contains("kpa")) return ("map (kPa)", f => f.MapKpa);
        if (unit.Contains('%')) return ("tps", f => f.TpsPct);
        return rows ? ("rpm", f => f.Rpm) : ("map (kPa)", f => f.MapKpa);
    }

    /// Index of the breakpoint nearest to v (axes may be ascending or descending).
    public static int Nearest(double[] axis, double v)
    {
        int best = 0; double bd = double.MaxValue;
        for (int i = 0; i < axis.Length; i++)
        {
            if (double.IsNaN(axis[i])) continue;
            double d = Math.Abs(axis[i] - v);
            if (d < bd) { bd = d; best = i; }
        }
        return best;
    }

    /// Fractional position of v along an axis (for the live trace marker).
    public static double Position(double[] axis, double v)
    {
        var pts = axis.Select((a, i) => (a, i)).Where(p => !double.IsNaN(p.a)).ToList();
        if (pts.Count == 0) return 0;
        if (pts.Count == 1) return pts[0].i;
        bool asc = pts[^1].a >= pts[0].a;
        for (int k = 0; k + 1 < pts.Count; k++)
        {
            var (a0, i0) = pts[k]; var (a1, i1) = pts[k + 1];
            bool inside = asc ? v >= a0 && v <= a1 : v <= a0 && v >= a1;
            if (inside && a1 != a0) return i0 + (v - a0) / (a1 - a0) * (i1 - i0);
        }
        return asc ? (v < pts[0].a ? pts[0].i : pts[^1].i) : (v > pts[0].a ? pts[0].i : pts[^1].i);
    }

    public static OverlayResult Compute(DefinitionSet defs, byte[] rom, ItemDef item, IEnumerable<LogFrame> frames, string channel,
                                        Func<LogFrame, bool>? filter = null)
    {
        int rows = Math.Max(1, item.Rows), cols = Math.Max(1, item.Cols), n = rows * cols;
        var rowAxis = item.RowAxis == null ? Enumerable.Range(0, rows).Select(i => (double)i).ToArray() : RomData.AxisValues(defs, rom, item.RowAxis, rows);
        var colAxis = item.ColAxis == null ? Enumerable.Range(0, cols).Select(i => (double)i).ToArray() : RomData.AxisValues(defs, rom, item.ColAxis, cols);
        var (rn, rget) = AxisInput(defs, item.RowAxis, true);
        var (cn, cget) = AxisInput(defs, item.ColAxis, false);
        var res = new OverlayResult
        {
            Item = item, Channel = channel, Mean = new double[n], Min = Enumerable.Repeat(double.MaxValue, n).ToArray(),
            Max = Enumerable.Repeat(double.MinValue, n).ToArray(), Count = new int[n], RowSource = rn, ColSource = cn,
        };
        var sum = new double[n];
        filter ??= MapSide.Filter(item);      // don't smear the high-cam map into the low-cam one
        foreach (var f in frames)
        {
            if (filter != null && !filter(f)) continue;
            if (f.Get(channel) is not double v || rget(f) is not double rv || (cols > 1 && cget(f) is not double)) continue;
            int r = item.RowAxis == null && rows == 1 ? 0 : Nearest(rowAxis, rv);
            int c = cols == 1 ? 0 : Nearest(colAxis, cget(f)!.Value);
            int i = r * cols + c;
            sum[i] += v; res.Count[i]++;
            res.Min[i] = Math.Min(res.Min[i], v); res.Max[i] = Math.Max(res.Max[i], v);
            res.Frames++;
        }
        for (int i = 0; i < n; i++)
        {
            res.Mean[i] = res.Count[i] > 0 ? sum[i] / res.Count[i] : double.NaN;
            if (res.Count[i] == 0) { res.Min[i] = double.NaN; res.Max[i] = double.NaN; }
        }
        return res;
    }
}

// ---------------------------------------------------------------- files

/// Loading and saving logs: the common binary logger format ("DATALOGGER" header, 129-byte records), the .rlog archive around it, and CSV (this program's own, or any CSV with recognisable column names).
public static class LogFile
{
    public static List<LogFrame> Load(string path)
    {
        if (IsRlog(path)) return LoadRlog(path).Frames;
        var data = File.ReadAllBytes(path);
        if (IsLoggerFile(data)) return LoadLogger(data);
        // .log files are written encoded; decode and look again
        if (data.Length > 160 && DecodeLogger(data) is { } dec && IsLoggerFile(dec)) return LoadLogger(dec);
        return LoadCsv(path);
    }

    static bool IsLoggerFile(byte[] data) =>
        data.Length >= 17 && Encoding.ASCII.GetString(data, 0, 10) is "DATALOGGER" or "eCtune.dlf" or "BMTune.bml";

    static bool IsRlog(string path)
    {
        if (!path.EndsWith(".rlog", StringComparison.OrdinalIgnoreCase))
        {
            var head = new byte[2];
            using var fs = File.OpenRead(path);
            if (fs.Read(head, 0, 2) < 2 || head[0] != 'P' || head[1] != 'K') return false;
        }
        return true;
    }

    /// An .rlog: a zip of DL (the datalog, encoded), PROG (the ROM image the car ran) and SET (the tuning software's settings XML at the time).
    public sealed record Rlog(List<LogFrame> Frames, byte[]? Rom, string? Settings);

    public static Rlog LoadRlog(string path)
    {
        using var zip = System.IO.Compression.ZipFile.OpenRead(path);
        byte[]? Entry(string name)
        {
            var e = zip.Entries.FirstOrDefault(x => x.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
            if (e == null) return null;
            using var s = e.Open();
            using var ms = new MemoryStream();
            s.CopyTo(ms);
            return ms.ToArray();
        }
        var dl = Entry("DL") ?? throw new InvalidDataException("the .rlog has no DL (datalog) entry");
        var log = IsLoggerFile(dl) ? dl : DecodeLogger(dl) ?? throw new InvalidDataException("the DL entry could not be decoded");
        if (!IsLoggerFile(log)) throw new InvalidDataException("the DL entry is not a datalog in the expected format");
        var set = Entry("SET");
        return new Rlog(LoadLogger(log), Entry("PROG"), set == null ? null : Encoding.UTF8.GetString(set));
    }

    /// The log encoding used by .log and .rlog files: eight 16-byte blocks each shifted by a key byte stored after it, the rest by the last byte; then even bytes minus and odd bytes plus the new last byte. Null when the data is too short to be encoded.
    public static byte[]? DecodeLogger(byte[] b)
    {
        if (b.Length < 140) return null;
        var keys = new[] { b[16], b[33], b[50], b[67], b[84], b[101], b[118], b[135] };
        byte last = b[^1];
        var a = new byte[b.Length - 9];
        int src = 0;
        for (int i = 0; i < a.Length; i++)
        {
            byte k = i >= 128 ? last : keys[i / 16];
            if (i is 16 or 32 or 48 or 64 or 80 or 96 or 112 or 128) src++;
            a[i] = (byte)(b[src] + k);
            src++;
        }
        byte k2 = a[^1];
        var r = new byte[a.Length - 1];
        for (int i = 0; i < r.Length; i++) r[i] = (byte)(i % 2 == 0 ? a[i] - k2 : a[i] + k2);
        return r;
    }

    static List<LogFrame> LoadLogger(byte[] data)
    {
        int size = data[12] + 1;
        var list = new List<LogFrame>();
        for (int pos = 17; pos + 50 <= data.Length; pos += size)
        {
            var r = new BinaryReader(new MemoryStream(data, pos, Math.Min(size, data.Length - pos)));
            try
            {
                var f = new byte[HondaDatalog.FrameLength];
                // record order in the file: bytes0-5, rpm word, bytes6-14, inj word, ign x2,
                // inputs, outputs, ..., then the elapsed-ms counters
                for (int i = 0; i < 6; i++) f[i] = r.ReadByte();
                f[6] = r.ReadByte(); f[7] = r.ReadByte();
                for (int i = 8; i <= 16; i++) f[i] = r.ReadByte();
                f[17] = r.ReadByte(); f[18] = r.ReadByte();
                f[19] = r.ReadByte(); f[20] = r.ReadByte();
                f[21] = r.ReadByte(); f[22] = r.ReadByte(); f[23] = r.ReadByte(); f[24] = r.ReadByte(); f[25] = r.ReadByte();
                long ms = r.ReadInt64();
                var fr = HondaDatalog.Decode(f, ms / 1000.0);
                fr.Protocol = "logger file";
                list.Add(fr);
            }
            catch (EndOfStreamException) { break; }
        }
        // the elapsed counter restarts in some logs; make time strictly increasing
        double t0 = list.Count > 0 ? list[0].T : 0, last = double.NegativeInfinity;
        foreach (var fr in list)
        {
            fr.T -= t0;
            if (fr.T <= last) fr.T = last + 0.05;
            last = fr.T;
        }
        return list;
    }

    // column name (lower case, units stripped) -> field
    static readonly (string[] Names, string Field)[] Columns =
    {
        (new[] { "time_s", "time", "seconds", "t" }, "time_s"),
        (new[] { "duration" }, "time_ms"),
        (new[] { "rpm", "engine speed" }, "rpm"),
        (new[] { "map_kpa", "map kpa" }, "map_kpa"),
        (new[] { "map", "map mbar" }, "map_mbar"),
        (new[] { "tps_pct", "tps" }, "tps_pct"),
        (new[] { "ect_c", "ect" }, "ect_c"),
        (new[] { "iat_c", "iat" }, "iat_c"),
        (new[] { "o2_v", "ecuo2v", "o2v", "o2" }, "o2_v"),
        (new[] { "batt_v", "batv", "battery" }, "batt_v"),
        (new[] { "speed_kmh", "vss", "speed" }, "speed_kmh"),
        (new[] { "baro_kpa" }, "baro_kpa"),
        (new[] { "pa", "baro" }, "baro_mbar"),
        (new[] { "inj_ms", "injdur", "inj" }, "inj_ms"),
        (new[] { "ign_deg", "ignfnl", "ign" }, "ign_deg"),
        (new[] { "ign_table_deg", "igntbl" }, "ign_table_deg"),
        (new[] { "vtec", "outvtsm", "outvts" }, "vtec"),
        (new[] { "fuel_pump", "outfpump" }, "fuel_pump"),
        (new[] { "afr", "wbafr", "wideband" }, "afr"),
        (new[] { "lambda", "wblambda" }, "lambda"),
        (new[] { "knock", "knockcount" }, "knock"),
        (new[] { "protocol" }, "protocol"),
        (new[] { "raw" }, "raw"),
    };

    static string Clean(string h)
    {
        h = h.Trim().Trim('"').ToLowerInvariant();
        int p = h.IndexOf('(');
        if (p > 0) h = h[..p];
        return h.Trim();
    }

    static List<LogFrame> LoadCsv(string path)
    {
        var lines = File.ReadAllLines(path).Where(l => l.Trim().Length > 0).ToList();
        if (lines.Count < 2) throw new InvalidDataException("the log has no data rows");
        char sep = lines[0].Count(c => c == ';') > lines[0].Count(c => c == ',') ? ';' : lines[0].Contains('\t') ? '\t' : ',';
        var header = lines[0].Split(sep).Select(Clean).ToList();
        var map = new Dictionary<int, string>();
        for (int i = 0; i < header.Count; i++)
        {
            foreach (var (names, field) in Columns)
                if (names.Contains(header[i]) && !map.ContainsValue(field)) { map[i] = field; break; }
            // any other numeric column becomes an extra channel under its own name
            if (!map.ContainsKey(i) && header[i].Length > 0) map[i] = "x:" + header[i];
        }
        if (!map.ContainsValue("rpm")) throw new InvalidDataException("no rpm column found (expected headers like rpm, map_kpa, tps_pct, ect_c...)");
        var list = new List<LogFrame>();
        double tAcc = 0;
        for (int n = 1; n < lines.Count; n++)
        {
            var cells = lines[n].Split(sep);
            var f = new LogFrame { T = double.NaN };
            byte[]? raw = null;
            foreach (var (i, field) in map)
            {
                if (i >= cells.Length) continue;
                var cell = cells[i].Trim().Trim('"');
                if (field == "raw")
                {
                    if (cell.Length >= 2 && cell.Length % 2 == 0)
                        try { raw = Convert.FromHexString(cell); } catch { }
                    continue;
                }
                if (field == "protocol") { f.Protocol = cell.Length > 0 ? cell : null; continue; }
                if (!double.TryParse(cell, NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) continue;
                switch (field)
                {
                    case "time_s": f.T = v; break;
                    case "time_ms": tAcc += v / 1000; f.T = tAcc; break;
                    case "map_mbar": f.MapKpa = v / 10; break;
                    case "baro_mbar": f.BaroKpa = v / 10; break;
                    default: f.Set(field.StartsWith("x:") ? field[2..] : field, v); break;
                }
            }
            if (double.IsNaN(f.T)) f.T = list.Count == 0 ? 0 : list[^1].T + 0.05;
            if (raw != null && raw.Length == HondaDatalog.FrameLength && f.Rpm == null)
            {
                var d = HondaDatalog.Decode(raw, f.T);
                foreach (var (k, v) in f.Extra) d.Extra[k] = v;
                f = d;
            }
            else f.Raw = raw;
            list.Add(f);
        }
        double t0 = list[0].T;
        foreach (var f in list) f.T -= t0;
        return list;
    }

    public static void SaveCsv(string path, IEnumerable<LogFrame> frames)
    {
        var all = frames.ToList();
        var extras = all.SelectMany(f => f.Extra.Keys).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(k => k).ToList();
        var sb = new StringBuilder();
        sb.AppendLine("time_s," + string.Join(",", LogFrame.Fields.Concat(extras)) + ",protocol,raw");
        foreach (var f in all)
        {
            sb.Append(f.T.ToString("0.000", CultureInfo.InvariantCulture));
            foreach (var field in LogFrame.Fields.Concat(extras))
                sb.Append(',').Append(f.Get(field)?.ToString("0.###", CultureInfo.InvariantCulture) ?? "");
            sb.Append(',').Append(f.Protocol ?? "");
            sb.Append(',').Append(f.Raw == null ? "" : Convert.ToHexString(f.Raw));
            sb.AppendLine();
        }
        File.WriteAllText(path, sb.ToString());
    }
}
