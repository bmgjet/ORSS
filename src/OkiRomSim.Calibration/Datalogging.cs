// Copyright (c) bmgjet. All rights reserved.
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
    /// Extra channels: "afr", "lambda", "knock", aux channels named in Settings... Made the first time one is set, so a frame without any costs nothing for it.
    public Dictionary<string, double> Extra => _extra ??= new(StringComparer.OrdinalIgnoreCase);
    Dictionary<string, double>? _extra;
    /// Names for the bytes of Raw ("b12", "h05"...), shared by every frame of one protocol and read from Raw when asked for. They used to be copied into Extra for every frame - a few kilobytes a frame, over a hundred megabytes for a long log on a laptop that has little to spare.
    public RawNames? RawChannels;

    public static readonly string[] Fields =
        { "rpm", "map_kpa", "tps_pct", "ect_c", "iat_c", "o2_v", "batt_v", "speed_kmh", "baro_kpa", "inj_ms", "ign_deg", "ign_table_deg", "vtec", "fuel_pump" };

    public static readonly Dictionary<string, string> Units = new(StringComparer.OrdinalIgnoreCase)
    {
        ["rpm"] = "rpm", ["map_kpa"] = "kPa", ["tps_pct"] = "%", ["ect_c"] = "°C", ["iat_c"] = "°C", ["o2_v"] = "V", ["batt_v"] = "V",
        ["speed_kmh"] = "km/h", ["baro_kpa"] = "kPa", ["inj_ms"] = "ms", ["ign_deg"] = "°", ["ign_table_deg"] = "°", ["vtec"] = "", ["fuel_pump"] = "",
        ["afr"] = "AFR", ["lambda"] = "λ", ["tc_retard_deg"] = "°",
    };

    public double? Get(string field) => field.ToLowerInvariant() switch
    {
        "rpm" => Rpm, "map_kpa" => MapKpa, "tps_pct" => TpsPct, "ect_c" => EctC, "iat_c" => IatC, "o2_v" => O2V,
        "batt_v" => BattV, "speed_kmh" => SpeedKmh, "baro_kpa" => BaroKpa, "inj_ms" => InjMs, "ign_deg" => IgnDeg,
        "ign_table_deg" => IgnTableDeg, "vtec" => Vtec is bool v ? (v ? 1 : 0) : null,
        "fuel_pump" => FuelPump is bool f ? (f ? 1 : 0) : null,
        "t" or "time_s" => T,
        var other => _extra != null && _extra.TryGetValue(other, out var x) ? x : RawChannels?.Get(Raw, other),
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
    public IEnumerable<string> Channels() => Fields.Where(f => Get(f) != null).Concat(ExtraNames().OrderBy(k => k, StringComparer.OrdinalIgnoreCase));

    /// The channels beyond the fixed fields: set ones, then the named bytes of Raw.
    public IEnumerable<string> ExtraNames() =>
        (_extra?.Keys ?? Enumerable.Empty<string>()).Concat((RawChannels?.Names ?? []).Where(n => _extra?.ContainsKey(n) != true));

    /// Which channels the frame has, as a number: frames with the same one list the same channels, so a scan over a long log only lists them again when it changes.
    int Shape()
    {
        int mask = 0, bit = 1;
        foreach (var v in new[] { Rpm, MapKpa, TpsPct, EctC, IatC, O2V, BattV, SpeedKmh, BaroKpa, InjMs, IgnDeg, IgnTableDeg })
        { if (v != null) mask |= bit; bit <<= 1; }
        if (Vtec != null) mask |= bit; bit <<= 1;
        if (FuelPump != null) mask |= bit;
        return HashCode.Combine(mask, _extra?.Count ?? 0, RawChannels);
    }

    /// Every channel any frame of a log has, in display order - quick on a long log (see Shape).
    public static List<string> AllChannels(IEnumerable<LogFrame> frames)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var shapes = new HashSet<int>();
        foreach (var f in frames)
            if (shapes.Add(f.Shape())) foreach (var c in f.Channels()) seen.Add(c);
        return [.. Fields.Where(seen.Contains), .. seen.Where(c => !Fields.Contains(c)).OrderBy(c => c, StringComparer.OrdinalIgnoreCase)];
    }
}

/// Names for the bytes of a raw frame, made once per protocol (and frame length) and shared by every frame.
public sealed class RawNames
{
    public readonly string[] Names;
    readonly Dictionary<string, int> _index = new(StringComparer.OrdinalIgnoreCase);

    public RawNames(IEnumerable<(string Name, int Index)> map)
    {
        foreach (var (n, i) in map) _index[n] = i;
        Names = [.. _index.Keys];
    }

    public double? Get(byte[]? raw, string name) => raw != null && _index.TryGetValue(name, out var i) && i < raw.Length ? raw[i] : null;

    static readonly System.Collections.Concurrent.ConcurrentDictionary<string, RawNames> Made = new();

    /// The shared set called `key`, made by `make` the first time.
    public static RawNames Of(string key, Func<RawNames> make) => Made.GetOrAdd(key, _ => make());

    /// "b0", "b1"... for every byte of a frame this long.
    public static RawNames Bytes(int length) => Of("b" + length, () => new(Enumerable.Range(0, length).Select(i => ($"b{i}", i))));
}

/// Honda OBD1 frame layouts and scalings, as the established tuning tools read them.
public static class HondaDatalog
{
    public const int FrameLength = 51;

    public static double Volts(byte b) => b * 5.0 / 255.0;
    public static double MapKpa(byte b) => ((b * 7.221) - 59) / 10;
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
        ushort period = (ushort)(f[6] | (f[7] << 8));
        ushort inj = (ushort)(f[17] | (f[18] << 8));
        return new LogFrame
        {
            T = t, Raw = [.. f],
            EctC = ThermistorC(f[0]), IatC = ThermistorC(f[1]), O2V = Math.Round(Volts(f[2]), 3),
            BaroKpa = f[3] == 0 ? null : Math.Round(MapKpa((byte)Math.Min(255, (f[3] / 2) + 24)), 1),
            MapKpa = Math.Round(MapKpa(f[4]), 1), TpsPct = Math.Round(TpsPct(f[5]), 1),
            Rpm = period == 0 ? 0 : Math.Round(1875000.0 / period),
            SpeedKmh = f[16],
            InjMs = Math.Round(inj * 3.2 / 1000, 2),
            IgnDeg = (f[19] * 0.25) - 6, IgnTableDeg = (f[20] * 0.25) - 6,
            BattV = Math.Round(26.0 * f[25] / 270.0, 2),
            Vtec = ((f[8] >> 3) & 1) != 0,
            FuelPump = (f[22] & 1) != 0,
        };
    }

    /// QD3 frame: 40 bytes, starting 46h 26h.
    public static LogFrame DecodeQd3(byte[] f, double t)
    {
        ushort period = (ushort)(f[2] | (f[3] << 8));
        ushort inj = (ushort)(f[7] | (f[8] << 8));
        var fr = new LogFrame
        {
            T = t, Raw = [.. f],
            Rpm = period == 0 ? 0 : Math.Round(1875000.0 / period),
            IgnDeg = (f[9] * 0.25) - 6,
            O2V = Math.Round(Volts(f[11]), 3),
            SpeedKmh = f[20],
            BattV = Math.Round(26.0 * f[21] / 270.0, 2),
            MapKpa = Math.Round(MapKpa(f[22]), 1),
            TpsPct = Math.Round(TpsPct(f[24]), 1),
            IatC = ThermistorC(f[25]),
            EctC = ThermistorC(f[33]),
        };
        fr.Extra["inj_raw"] = inj;
        fr.Extra["knock_retard_deg"] = f[10] * 0.25;
        fr.Vtec = (f[19] & 1) != 0;
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
    /// A single-wire serial link (the stock Honda tester link): the ECU hears its own bytes. Links that can model it (the simulator) do; a real cable is one already, or is not, whatever is asked here.
    void SetEcho(bool on) { }
    /// Let `ms` pass on the line (a pause between bytes). A real port just waits; a simulated one runs the ROM.
    void Wait(int ms) => Thread.Sleep(ms);
    /// Change the line speed (auto-detection tries each protocol at its own). Links that cannot, ignore it.
    void SetBaud(int baud) { }
    /// Keep the line for one request and its answer, on a link shared with something else (the emulator's port, which uploads go over too); disposing it lets the other user back in. Links of their own need nothing.
    IDisposable? Hold() => null;
}

public enum PacketDir { Tx, Rx }
public sealed record Packet(DateTime Time, PacketDir Dir, byte[] Bytes, string Note);

/// One request and its fixed-length answer, which an emulator can ask the ECU for itself (DatalogProtocol.Relay).
public sealed record RelayPlan(byte Hello, byte HelloAnswer, byte Request, int Length, Func<byte[], double, LogFrame> Decode);

/// One way of datalogging an OBD1 ROM. New ROM families add a subclass and a line in All.
public abstract class DatalogProtocol
{
    public abstract string Name { get; }
    public abstract string Description { get; }
    public virtual int Baud => 38400;
    public int TimeoutMs { get; set; } = TimeoutMsDefault;
    /// A pause between writing a request and reading the answer. Several USB-serial cables drop the first byte of the answer without one, which is why the established tuning software always waits 10 ms here; it is the single thing that most often makes an OBD1 link "not work".
    public int PostWritePauseMs { get; set; } = PostWritePauseMsDefault;
    /// How many times a handshake is tried before the protocol is called wrong.
    public int Retries { get; set; } = RetriesDefault;

    /// What a new protocol object starts with (Settings > Emulator & datalog sets these).
    public static int TimeoutMsDefault = 250, PostWritePauseMsDefault = 10, RetriesDefault = 3;

    /// Called with every packet sent and received (for the packet monitor).
    public Action<Packet>? OnPacket { get; set; }

    /// The protocol as one fixed exchange, for an emulator that asks the ECU itself and hands the answer on (a Demon on the emulator's port): the handshake byte and its answer, the request byte, how many bytes come back before the checksum, and how to read them. Null for a protocol that is more than that.
    public virtual RelayPlan? Relay => null;

    /// Open the conversation; false when the ROM does not speak this protocol.
    public abstract bool Handshake(IByteLink link, out string note);

    /// One command byte between frames and its one-byte answer (TroubleCodes: 50h clears the stored codes, 51h switches the injectors off...), or null when nothing came back. A protocol that streams, or goes through an emulator, puts its own conversation back afterwards.
    public virtual byte? Command(IByteLink link, byte command, out string note)
    {
        using var hold = link.Hold();
        link.Discard();
        Send(link, command);
        var r = Receive(link, 1, $"command {command:X2}");
        note = r.Length == 1 ? $"{command:X2} answered {r[0]:X2}" : $"no answer to {command:X2}";
        return r.Length == 1 ? r[0] : null;
    }
    /// One frame, or null (timeout / bad checksum; `note` says which).
    public abstract LogFrame? Poll(IByteLink link, double t, out string note);

    protected void Send(IByteLink link, params byte[] b)
    {
        link.Write(b);
        OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Tx, b, ""));
        if (PostWritePauseMs > 0) Thread.Sleep(PostWritePauseMs);
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
        // an ECU that has just been powered up, or a cable that was mid-answer, misses the first try: the tuning software retries the handshake several times before giving up on it
        note = "";
        for (int attempt = 0; attempt <= Math.Max(0, Retries); attempt++)
        {
            Drain(link);
            Send(link, send);
            var r = Receive(link, 1, "handshake");
            if (r.Length == 1 && r[0] == expect)
            {
                note = $"handshake {send:X2} -> {expect:X2}" + (attempt > 0 ? $" (after {attempt} retry/retries)" : "");
                return true;
            }
            note = r.Length == 0 ? $"no answer to {send:X2}"
                 : r[0] == send ? $"echo of {send:X2}: the datalog jumper (J12 USDM / J4 JDM) is still fitted"
                 : r.Length == 1 && r[0] == 0xBC ? $"answer BC to {send:X2}: this is a different ROM family, not one that speaks {Name}"
                 : $"answer {r[0]:X2} to {send:X2}, expected {expect:X2}";
            // an echo means the wiring is wrong, not that the ECU is slow: retrying will not help
            if (r.Length == 1 && (r[0] == send || r[0] == 0xBC)) return false;
        }
        return false;
    }

    protected LogFrame? Framed(IByteLink link, byte request, int dataLength, Func<byte[], LogFrame> decode, double t, out string note)
    {
        // Only the buffer is cleared, not the wire: the old code waited for the line to fall quiet before every single request, which cost more than the frame interval itself and, on a fast link, swallowed the beginning of the answer to the request just sent. The tuning software writes the request and reads the answer, and only discards the buffer after something has actually gone wrong.
        link.Discard();
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
        // order matters for Detect: the single-byte probe would accept any ROM that answers C6h, and the 66207 multi-byte handshake is the same one the P13 loggers use, so the protocols that ask for a particular frame length come before the ones that take any
        new ChannelStream(), new MultiByte90(), new IsrMultiByte(), new Qd3Protocol(),
        new P13Protocol(0x46), new P13Protocol(0x20),
        new Custom1Protocol(), new Custom2Protocol(),
        new RawFrame10(), new ByteRequestC0(), new HondaStockTester(),
    };

    /// Older names these protocols were saved under, so a settings file from an earlier build still picks the same protocol. (P13 46h and P13 20h are new, so they have none.)
    static readonly Dictionary<string, string> Aliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["multi-byte"] = "Multi-byte 90h",
        ["ISR"] = "Multi-byte 20h",
        ["single-byte"] = "Byte requests C0h",
        ["raw"] = "Raw 10h frame",
    };

    public static DatalogProtocol? ByName(string name)
    {
        if (Aliases.TryGetValue(name, out var canonical)) name = canonical;
        return All().FirstOrDefault(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
    }

    /// Try every protocol's handshake and first frame; the first that works wins. `quick` tries each handshake once, with short timeouts (Settings > Detect, going through every port).
    public static (DatalogProtocol? Protocol, string Report) Detect(IByteLink link, Action<Packet>? onPacket = null, bool quick = false)
    {
        var report = new StringBuilder();
        foreach (var p in All())
        {
            p.OnPacket = onPacket;
            if (quick) { p.Retries = 0; p.TimeoutMs = Math.Min(p.TimeoutMs, 150); }
            // each at its own line speed (the stock tester link is 9600, the rest 38400), on a plain line
            link.SetEcho(false);
            link.SetBaud(p.Baud);
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

/// Custom 1: 00h, 01h, 02h answer its ID (14h 72h 41h); every byte 10h-5Fh answers one logged value; 0Eh hi lo reads any byte of memory and 0Fh hi lo value writes one. Traced in the simulator one input at a time: 10h-11h the crank period (low, high), 18h throttle, 19h O2, 1Ah MAP, 1Bh baro, 1Ch coolant, 1Dh intake air, 1Eh road speed, 29h battery. The requests go out in one burst; the ECU answers each as it arrives, in order.
public sealed class Custom1Protocol : DatalogProtocol
{
    public override string Name => "Custom 1";
    public override string Description => "00/01/02 -> ID 14 72 41, then one byte per request (10h-1Eh, 29h)";
    /// The requests asked each frame: the ones the decode uses, plus 12h-13h.
    static readonly byte[] Asked = [0x10, 0x11, 0x12, 0x13, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x29];

    public override bool Handshake(IByteLink link, out string note)
    {
        for (int attempt = 0; attempt <= Math.Max(0, Retries); attempt++)
        {
            Drain(link);
            Send(link, 0x00, 0x01, 0x02);
            var r = Receive(link, 3, "Custom 1 ID");
            if (r.Length == 3 && r[0] == 0x14 && r[1] == 0x72 && r[2] == 0x41) { note = "ID 14 72 41"; return true; }
            note = r.Length == 0 ? "no answer to 00 01 02" : $"ID {string.Join(" ", r.Select(b => b.ToString("X2")))}, expected 14 72 41";
            if (r.Length == 3 && r.SequenceEqual(new byte[] { 0, 1, 2 })) { note = "echo of 00 01 02: the datalog jumper is still fitted"; return false; }
        }
        note = "no Custom 1 ID";
        return false;
    }

    public override LogFrame? Poll(IByteLink link, double t, out string note)
    {
        // one request at a time: the ECU has a one-byte receive buffer, and a burst loses bytes to it
        link.Discard();
        var d = new byte[Asked.Length];
        var one = new byte[1];
        for (int i = 0; i < Asked.Length; i++)
        {
            link.Write([Asked[i]]);
            if (link.Read(one, 0, 1, Math.Max(20, TimeoutMs / 4)) != 1) { note = $"no answer to {Asked[i]:X2}"; return null; }
            d[i] = one[0];
        }
        OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Rx, d, "Custom 1 values " + string.Join(" ", Asked.Select(a => a.ToString("X2")))));
        byte V(int cmd) => d[Array.IndexOf(Asked, (byte)cmd)];
        int period = V(0x10) | (V(0x11) << 8);
        var f = new LogFrame
        {
            T = t, Raw = d, Protocol = Name,
            Rpm = period == 0 || period == 0xFFFF ? 0 : Math.Round(1875000.0 / period),
            TpsPct = Math.Round(HondaDatalog.TpsPct(V(0x18)), 1), O2V = Math.Round(HondaDatalog.Volts(V(0x19)), 3),
            MapKpa = Math.Round(HondaDatalog.MapKpa(V(0x1A)), 1), BaroKpa = Math.Round(HondaDatalog.MapKpa(V(0x1B)), 1),
            EctC = HondaDatalog.ThermistorC(V(0x1C)), IatC = HondaDatalog.ThermistorC(V(0x1D)),
            SpeedKmh = V(0x1E), BattV = Math.Round(26.0 * V(0x29) / 270.0, 2),
        };
        f.RawChannels = RawNames.Of("custom1", () => new(Asked.Select((a, i) => ($"n{a:X2}", i))));
        note = "ok";
        return f;
    }
}

/// Custom 2: locked at power-up, it sends a 131-byte frame (82h 81h, random bytes, checksum) over and over; bytes 38h-3Fh of it are the seed. The tool answers straight after a frame with 83h and 83h more bytes: the second picks the key (9105h, or E0A4h if its bit 0 is set), each byte up to 65h runs one round of a 16-bit TEA-like cipher (delta 9E37h) over the seed, bytes 66h-6Dh must be the cipher state after those 99 rounds, and the whole message sums to 00h. It answers 0Fh (F0h if wrong) and stops the seed frames. Then 90h answers 90h, 3Bh and 58 bytes, checksum. The cipher runs inside the receive interrupt, so the message goes a byte at a time with a pause after each. Fields traced in the simulator one input at a time (byte offsets from the 3Bh): 2-3 rpm, 4-5 speed-sensor period, 6-7 MAP in mBar, 8 throttle, 15 O2, 26 gear, 31 baro, 32 coolant, 33 intake air, 35 battery.
public sealed class Custom2Protocol : DatalogProtocol
{
    public override string Name => "Custom 2";
    public override string Description => "seed frames 82 81 -> 83h cipher unlock, then 90h -> 90 3B + 58 bytes + checksum";
    const int SeedFrame = 131, Data = 59;

    public override bool Handshake(IByteLink link, out string note)
    {
        // locked, it sends seed frames without being asked: unlock it, which stops them (they would otherwise share the line with every answer); unlocked, it is quiet and 90h just answers
        string unlock = "";
        for (int attempt = 0; attempt <= Math.Max(0, Retries); attempt++)
        {
            var seed = Seed(link, attempt == 0 ? 400 : 1500);
            if (seed == null) break;
            OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Rx, seed, "Custom 2 seed"));
            var msg = Unlock(seed, 0);
            foreach (var b in msg)
            {
                link.Write([b]);
                // give the cipher round time to finish before the next byte lands in the one-byte buffer
                link.Wait(2);
            }
            OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Tx, msg, "Custom 2 unlock"));
            var r = Receive(link, 1, "Custom 2 unlock answer");
            if (r.Length == 1 && r[0] == 0x0F) { unlock = "unlocked (0F), "; Drain(link); break; }
            unlock = r.Length == 1 && r[0] == 0xF0 ? "unlock refused (F0), " : "no answer to the unlock, ";
        }
        if (Frame90(link) != null) { note = unlock + "90h frame ok"; return true; }
        note = unlock + "no 90h frame";
        return false;
    }

    /// The seed of a whole 82h 81h frame, read only up to its end so an answer goes out in the gap before the next.
    static byte[]? Seed(IByteLink link, int ms)
    {
        var buf = new List<byte>();
        var one = new byte[1];
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < ms)
        {
            if (link.Read(one, 0, 1, 50) == 0) continue;
            buf.Add(one[0]);
            int j = buf.Count - SeedFrame;
            if (j >= 0 && buf[j] == 0x82 && buf[j + 1] == 0x81 && (buf.Skip(j).Take(SeedFrame).Sum(b => b) & 0xFF) == 0)
                return [.. buf.Skip(j + 0x38).Take(8)];
        }
        return null;
    }

    /// The unlock message for a seed: 83h, the key byte, the 99 clocking bytes, the 8 bytes of cipher state, filler, checksum.
    public static byte[] Unlock(byte[] seed, int keyBit)
    {
        ushort W(int i) => (ushort)(seed[i] | (seed[i + 1] << 8));
        ushort a = W(0), b = W(2), c = W(4), d = W(6), s = 0, k = keyBit == 0 ? (ushort)0x9105 : (ushort)0xE0A4;
        for (int r = 0; r < 99; r++)
        {
            a += (ushort)(c ^ s ^ k); a += (ushort)(d ^ s ^ k);
            b += (ushort)(c ^ s ^ k); b += (ushort)(d ^ s ^ k);
            s += 0x9E37;
            c += (ushort)(a ^ s ^ k); c += (ushort)(b ^ s ^ k);
            d += (ushort)(a ^ s ^ k); d += (ushort)(b ^ s ^ k);
        }
        var msg = new byte[0x84];
        msg[0] = 0x83; msg[2] = (byte)keyBit;
        byte[] st = [(byte)a, (byte)(a >> 8), (byte)b, (byte)(b >> 8), (byte)c, (byte)(c >> 8), (byte)d, (byte)(d >> 8)];
        st.CopyTo(msg, 0x66);
        msg[0x83] = (byte)-msg.Take(0x83).Sum(x => x);
        return msg;
    }

    byte[]? Frame90(IByteLink link)
    {
        link.Discard();
        Send(link, 0x90);
        // 90h, 3Bh and the rest, summing to 00h (an unlocked ECU also sends these on its own: any will do)
        var buf = new List<byte>();
        var chunk = new byte[128];
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < Math.Max(TimeoutMs, 120))
        {
            int n = link.Read(chunk, 0, chunk.Length, 20);
            if (n > 0) buf.AddRange(chunk.Take(n));
            for (int j = 0; j + Data + 2 <= buf.Count; j++)
                if (buf[j] == 0x90 && buf[j + 1] == 0x3B && (buf.Skip(j).Take(Data + 2).Sum(b => b) & 0xFF) == 0)
                {
                    var f = buf.Skip(j + 1).Take(Data).ToArray();
                    OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Rx, [.. buf.Skip(j).Take(Data + 2)], "Custom 2 90h frame"));
                    return f;
                }
            if (buf.Count > 400) break;
        }
        return null;
    }

    public override LogFrame? Poll(IByteLink link, double t, out string note)
    {
        var d = Frame90(link);
        if (d == null) { note = "timeout"; return null; }
        int period = d[4] | (d[5] << 8), mbar = d[6] | (d[7] << 8);
        var f = new LogFrame
        {
            T = t, Raw = d, Protocol = Name,
            Rpm = d[2] | (d[3] << 8),
            SpeedKmh = period == 0 || period == 0xFFFF ? 0 : Math.Round(220200.0 / period),
            MapKpa = Math.Round(mbar / 10.0, 1),
            TpsPct = Math.Round(HondaDatalog.TpsPct(d[8]), 1), O2V = Math.Round(HondaDatalog.Volts(d[15]), 3),
            BaroKpa = Math.Round(HondaDatalog.MapKpa(d[31]), 1),
            EctC = HondaDatalog.ThermistorC(d[32]), IatC = HondaDatalog.ThermistorC(d[33]),
            BattV = Math.Round(26.0 * d[35] / 270.0, 2),
        };
        f.Extra["gear"] = d[26];
        f.RawChannels = RawNames.Of("custom2", () => new(Enumerable.Range(0, Data).Select(i => ($"h{i:D2}", i))));
        note = "ok";
        return f;
    }
}

/// The skeleton ROM's datalog module (p30-features/datalog.asm, FEAT_DATALOG): the logger picks the channels it wants (version 2: up to 16 channel numbers from the ROM's table, 73h; version 1: up to 8 RAM addresses, 70h) and the ECU streams just those, back to back, each frame stamped with its own 2.048 ms tick. 7Eh                    -> 7Eh, version, most channels, 00h, checksum (the five sum to 00h) 70h N a1lo a1hi .. chk -> 70h taken / 7Fh refused   (chk: N, the addresses and chk sum to 00h) 71h                    -> frames back to back until any other byte arrives;  72h -> one frame frame: A5h, seq, tick lo, tick hi, the N bytes, chk (the whole frame sums to 00h) The same ROM also answers the HTS 10h/20h frame, so older loggers work on it too; this one is faster.
public sealed class ChannelStream : DatalogProtocol
{
    public override string Name => "Channel stream";
    public override string Description => "7E -> ident; 70 N addresses -> 70; 71 -> A5-framed stream of the chosen RAM bytes";

    /// The channels to ask for (DatalogChannels keys), set from the app's datalog settings. What does not fit the ROM (16 bytes on version 2, 8 on version 1) is left out, in catalogue order.
    public static IReadOnlyList<string> Selected { get; set; } = DatalogChannels.Defaults;
    /// The channels this connection streams, in frame order (set by the handshake).
    public IReadOnlyList<DatalogChannel> Streaming => _chosen;
    List<DatalogChannel> _chosen = DatalogChannels.Fit(DatalogChannels.Defaults, 8, false);
    readonly List<byte> _buf = [];
    int _lastSeq = -1;
    /// Frames the ECU sent that never arrived (a gap in the sequence number).
    public int Lost { get; private set; }

    public override bool Handshake(IByteLink link, out string note)
    {
        for (int attempt = 0; attempt <= Math.Max(0, Retries); attempt++)
        {
            Drain(link);
            Send(link, 0x7E);
            var id = Receive(link, 5, "Channel stream ident");
            if (id.Length < 5 || id[0] != 0x7E || (id.Sum(b => b) & 0xFF) != 0)
            {
                note = id.Length == 0 ? "no answer to 7E" : $"answer {string.Join(" ", id.Select(b => b.ToString("X2")))} is not the stream ident";
                if (id.Length == 1 && id[0] == 0x7E) { note = "echo of 7E: the datalog jumper is still fitted"; return false; }
                continue;
            }
            int version = id[1], most = Math.Max(1, (int)id[2]);
            bool v2 = version >= 2;
            _chosen = DatalogChannels.Fit(Selected, v2 ? Math.Min(most, 16) : Math.Min(most, 8), version);
            if (_chosen.Count == 0) _chosen = DatalogChannels.Fit(DatalogChannels.Defaults, 8, false);
            var msg = new List<byte> { (byte)(v2 ? 0x73 : 0x70) };
            var items = _chosen.SelectMany(c => v2 ? c.Numbers : c.Addresses).ToList();
            msg.Add((byte)items.Count);
            foreach (var x in items) { if (v2) msg.Add((byte)x); else { msg.Add((byte)x); msg.Add((byte)(x >> 8)); } }
            msg.Add((byte)-msg.Skip(1).Sum(b => b));
            Drain(link, 20);
            // a byte at a time with a pause after each: the ECU has a one-byte receive buffer, and a byte that
            // lands while a crank interrupt holds it off overwrites the one before, leaving the ECU waiting for the rest
            foreach (var b in msg) { link.Write([b]); link.Wait(1); }
            OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Tx, [.. msg], "channel list"));
            var ok = Receive(link, 1, "channel list answer");
            if (ok.Length != 1 || ok[0] != 0x70) { note = ok.Length == 1 && ok[0] == 0x7F ? "channel list refused (7F)" : "no answer to the channel list"; continue; }
            _buf.Clear(); _lastSeq = -1; Lost = 0;
            Send(link, 0x71);
            note = $"ident version {id[1]}, {_chosen.Count} channels ({items.Count} bytes), streaming";
            return true;
        }
        note = "no channel stream";
        return false;
    }

    /// The stream stops at any byte from the logger: a byte the ROM ignores (00h) stops it, the line is let go quiet, then the command, then the stream again.
    public override byte? Command(IByteLink link, byte command, out string note)
    {
        Send(link, 0x00);
        Drain(link, 30);
        var answer = base.Command(link, command, out note);
        _buf.Clear();
        Send(link, 0x71);
        return answer;
    }

    public override LogFrame? Poll(IByteLink link, double t, out string note)
    {
        int n = _chosen.Sum(c => c.Bytes), len = 5 + n;
        var chunk = new byte[256];
        var sw = System.Diagnostics.Stopwatch.StartNew();
        byte[]? frame = null;
        while (sw.ElapsedMilliseconds < Math.Max(TimeoutMs, 100))
        {
            int got = link.Read(chunk, 0, chunk.Length, 20);
            if (got > 0) _buf.AddRange(chunk.Take(got));
            // every complete frame that has arrived, in order (so a gap in the sequence is a frame the line
            // lost, not one skipped here); the newest one is what this poll returns
            int j = 0, used = 0;
            while (j + len <= _buf.Count)
            {
                if (_buf[j] == 0xA5 && (_buf.Skip(j).Take(len).Sum(b => b) & 0xFF) == 0)
                {
                    frame = [.. _buf.Skip(j).Take(len)];
                    int seq = frame[1];
                    if (_lastSeq >= 0) Lost += (seq - _lastSeq - 1) & 0xFF;
                    _lastSeq = seq;
                    j += len; used = j;
                }
                else j++;
            }
            if (used > 0) _buf.RemoveRange(0, used);
            if (frame != null) break;
            if (_buf.Count > 2048) _buf.RemoveRange(0, _buf.Count - len);
        }
        if (frame == null)
        {
            // the stream stopped (the ECU restarted, a stray byte ended it): ask for it again
            Send(link, 0x71);
            note = "timeout";
            return null;
        }
        OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Rx, frame, "Channel stream frame"));
        var f = new LogFrame { T = t, Raw = frame, Protocol = Name };
        int at = 4;
        foreach (var c in _chosen)
        {
            try { c.Decode(f, frame[at..(at + c.Bytes)]); } catch (Exception) { }
            at += c.Bytes;
        }
        f.Extra["ecu_tick_ms"] = Math.Round((frame[2] | (frame[3] << 8)) * 2.048, 1);
        f.Extra["frames_lost"] = Lost;
        note = "ok";
        return f;
    }
}

/// The stock Honda ECU's own link (P28 / P30 / P08 and the rest of the OBD1 family, no chip needed): the tester protocol on the single-wire diagnostic link. A request is 20h, 05h, first slot, slot count, checksum; the answer is 00h, its length, one byte per slot, checksum (every frame sums to 00h). The slots are a table in the ROM of RAM addresses, laid out the same way on every ROM checked (P30 and P08 traced in the simulator one input at a time): 03-04 the crank period (high, low), 05 road speed, 13h coolant, 14h intake air, 15h MAP, 16h baro, 17h throttle, 18h O2, 1Ah battery. The ECU sends each byte of its answer as it hears the echo of the one before, and the PC hears its own request back first.
public sealed class HondaStockTester : DatalogProtocol
{
    public override string Name => "Honda stock (tester 20h)";
    public override string Description => "stock ROM, one-wire tester link: 20 05 start count chk -> 00 len slots... chk (9600 baud)";
    public override int Baud => 9600;
    /// Slots 03h up to and including 1Ah: everything the decode uses.
    const int First = 0, Count = 0x18;

    public override bool Handshake(IByteLink link, out string note)
    {
        link.SetEcho(true);
        for (int attempt = 0; attempt <= Math.Max(0, Retries); attempt++)
        {
            Drain(link, 60);
            var r = Exchange(link, 0, 4, out note);
            if (r != null) { note = "tester 20h answered" + (attempt > 0 ? $" (after {attempt} retry/retries)" : ""); return true; }
        }
        note = "no framed answer to 20 05 00 04 (check the baud rate: the stock link is 9600)";
        return false;
    }

    public override LogFrame? Poll(IByteLink link, double t, out string note)
    {
        var d = Exchange(link, First, Count, out note);
        if (d == null) return null;
        byte S(int slot) => d[slot - 3];
        int period = (S(3) << 8) | S(4);
        var f = new LogFrame
        {
            T = t, Raw = d, Protocol = Name,
            Rpm = period == 0 || period == 0xFFFF ? 0 : Math.Round(1875000.0 / period),
            SpeedKmh = S(5),
            EctC = HondaDatalog.ThermistorC(S(0x13)), IatC = HondaDatalog.ThermistorC(S(0x14)),
            MapKpa = Math.Round(HondaDatalog.MapKpa(S(0x15)), 1), BaroKpa = Math.Round(HondaDatalog.MapKpa(S(0x16)), 1),
            TpsPct = Math.Round(HondaDatalog.TpsPct(S(0x17)), 1), O2V = Math.Round(HondaDatalog.Volts(S(0x18)), 3),
            BattV = Math.Round(26.0 * S(0x1A) / 270.0, 2),
        };
        int n = d.Length;
        f.RawChannels = RawNames.Of("stock" + n, () => new(Enumerable.Range(0, n).Select(i => ($"slot_{i + 3:X2}", i))));
        note = "ok";
        return f;
    }

    /// One request and its answer's slot bytes, or null. The PC's own request coming back (a one-wire cable echoes it) is skipped: the answer is found by its 00h, its length and its checksum.
    byte[]? Exchange(IByteLink link, int first, int count, out string note)
    {
        byte[] req = [0x20, 0x05, (byte)first, (byte)count, 0];
        req[4] = (byte)-(req[0] + req[1] + req[2] + req[3]);
        link.Discard();
        Send(link, req);
        int len = count + 3, want = len + req.Length;
        var buf = new List<byte>();
        var chunk = new byte[64];
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < Math.Max(TimeoutMs, 150 + (len * 3)))
        {
            int n = link.Read(chunk, 0, chunk.Length, 20);
            if (n > 0) buf.AddRange(chunk.Take(n));
            for (int j = 0; j + len <= buf.Count; j++)
                if (buf[j] == 0x00 && buf[j + 1] == len && (buf.Skip(j).Take(len).Sum(b => b) & 0xFF) == 0)
                {
                    var frame = buf.Skip(j).Take(len).ToArray();
                    OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Rx, frame, "tester answer"));
                    note = "ok";
                    return frame[2..^1];
                }
            if (buf.Count > want * 3) break;
        }
        OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Rx, [.. buf], $"no tester answer ({buf.Count} bytes)"));
        note = buf.Count == 0 ? "timeout" : "no valid answer";
        return null;
    }
}

/// Multi-byte 90h: handshake ABh -> CDh, then 90h returns the 51-byte main table + checksum.
public sealed class MultiByte90 : DatalogProtocol
{
    public override string Name => "Multi-byte 90h";
    public override string Description => "handshake AB→CD, then 90h → 51 bytes + checksum";
    public override bool Handshake(IByteLink link, out string note) => HandshakeByte(link, 0xAB, 0xCD, out note);
    public override LogFrame? Poll(IByteLink link, double t, out string note) => Framed(link, 0x90, HondaDatalog.FrameLength, f => HondaDatalog.Decode(f, t), t, out note);
    public override RelayPlan Relay => new(0xAB, 0xCD, 0x90, HondaDatalog.FrameLength, HondaDatalog.Decode);
}

/// Multi-byte 20h (the ISR v2 style): handshake 10h -> CDh, then 20h returns the same 51-byte table.
public sealed class IsrMultiByte : DatalogProtocol
{
    public override string Name => "Multi-byte 20h";
    public override string Description => "handshake 10→CD, then 20h → 51 bytes + checksum (ISR v2 style)";
    public override bool Handshake(IByteLink link, out string note) => HandshakeByte(link, 0x10, 0xCD, out note);
    public override LogFrame? Poll(IByteLink link, double t, out string note)
    {
        var f = Framed(link, 0x20, HondaDatalog.FrameLength, x => Decode(x, t), t, out note);
        if (f != null && _hts120 != false) Hts120Extras(link, f);
        return f;
    }

    public override RelayPlan Relay => new(0x10, 0xCD, 0x20, HondaDatalog.FrameLength, Decode);

    static LogFrame Decode(byte[] raw, double t)
    {
        var f = HondaDatalog.Decode(raw, t);
        // ISR's own extras: switch inputs, ELD, EGR, B6, IACV
        f.Extra["clutch"] = raw[21] & 1; f.Extra["brake"] = (raw[21] >> 1) & 1; f.Extra["ac"] = (raw[21] >> 2) & 1;
        f.Extra["eld_v"] = Math.Round(HondaDatalog.Volts(raw[24]), 2);
        f.Extra["egr_v"] = Math.Round(HondaDatalog.Volts(raw[44]), 2);
        f.Extra["b6_v"] = Math.Round(HondaDatalog.Volts(raw[45]), 2);
        f.Extra["iacv"] = raw[49] | (raw[50] << 8);
        return f;
    }

    /// HTS120 adds a second packet on 40h (hts120_log_table: TC retard, status, gear, TPS converter, then a checksum) and leaves the 51-byte 20h frame alone. Asked once; a ROM that answers anything else (HTS 1.15 and the rest say EEh) is not asked again.
    bool? _hts120;
    void Hts120Extras(IByteLink link, LogFrame f)
    {
        link.Discard();
        Send(link, 0x40);
        var r = Receive(link, 5, "HTS120 40h");
        if (r.Length == 5 && HondaDatalog.Checksum(r, 4) == r[4])
        {
            _hts120 = true;
            f.Extra["tc_retard_deg"] = r[0] * 0.25;
            f.Extra["antistart_locked"] = (r[1] >> 7) & 1;
            f.Extra["gear"] = r[2];
            f.Extra["tps_raw"] = r[3];
            return;
        }
        if (_hts120 == null) { _hts120 = false; Drain(link); }
    }
}

/// QD3: handshake ABh to BCh, then 46h returns a 40-byte frame + checksum (frame starts 46h 26h).
public sealed class Qd3Protocol : DatalogProtocol
{
    public override string Name => "QD3";
    public override string Description => "QD3 (AB→BC, 46h → 40 bytes + checksum)";
    public override bool Handshake(IByteLink link, out string note) => HandshakeByte(link, 0xAB, 0xBC, out note);
    public override LogFrame? Poll(IByteLink link, double t, out string note) => Framed(link, 0x46, 40, f => HondaDatalog.DecodeQd3(f, t), t, out note);
    public override RelayPlan Relay => new(0xAB, 0xBC, 0x46, 40, HondaDatalog.DecodeQd3);
}

/// Datalogging through a Moates Demon on the emulator's own port: the Demon asks the ECU itself (on the ECU's datalog line) and hands the answer on, with its own five analog inputs, so one cable does both jobs. The ROM's protocol is the inner one, reduced to a single request (RelayPlan); what goes over the emulator's port is the Demon's: 'D' 'R' adc divisor 0 0 n (1 len req)*n chk -> 'O'   what to ask the ECU: n requests of one byte, each answered with len bytes; adc = which analog inputs to add (1Fh = all five); divisor 23 = the ECU's 38400 baud 'd' -> status, the ECU's answers, the analog inputs (two bytes each, high first, 0-1023), a byte, chk The first byte of the ECU's answer is 54h or 84h when the ECU did not answer the Demon (ignition off, wiring). Worked out from what the established tuning software sends a Demon.
public sealed class EmulatorRelay : DatalogProtocol
{
    readonly DatalogProtocol _inner;
    readonly RelayPlan _plan;
    const byte Adc = AdcMask, Divisor = EcuBaudDivisor;
    const int Analog = AnalogInputs;
    /// The Demon's analog inputs asked for with every packet (all five), and its divisor for the ECU's 38400 baud.
    public const byte AdcMask = 0x1F, EcuBaudDivisor = 23;
    public const int AnalogInputs = 5;
    /// The request this relay asks the ECU for (and the Demon's onboard logging asks too).
    public RelayPlan Plan => _plan;

    public EmulatorRelay(DatalogProtocol inner)
    {
        _inner = inner;
        _plan = inner.Relay ?? throw new ArgumentException($"{inner.Name} cannot go through the emulator: it is not one fixed request");
        TimeoutMs = Math.Max(TimeoutMs, 400);
    }

    public override string Name => $"{_inner.Name} via emulator";
    public override string Description => $"{_inner.Description}, asked by the Demon on the emulator's port";

    /// The protocols a Demon can ask the ECU for itself.
    public static IEnumerable<DatalogProtocol> Candidates() => All().Where(p => p.Relay != null);

    byte[]? Exchange(IByteLink link, byte[] send, int answer, string what)
    {
        using var hold = link.Hold();
        link.Discard();
        Send(link, send);
        var r = Receive(link, answer, what);
        return r.Length == answer ? r : null;
    }

    byte[] Setup(byte adc, params (int Length, byte Request)[] asks)
    {
        var b = new List<byte> { (byte)'D', (byte)'R', adc, Divisor, 0, 0, (byte)asks.Length };
        foreach (var (len, req) in asks) { b.Add(1); b.Add((byte)len); b.Add(req); }
        b.Add(HondaDatalog.Checksum([.. b], b.Count));
        return [.. b];
    }

    /// A 'd' answer: status, the answers, the analog words, one byte, then the sum of all that.
    byte[]? Fetch(IByteLink link, int answers, int analog, string what)
    {
        int n = 1 + answers + (analog * 2) + 1;
        var r = Exchange(link, [(byte)'d'], n + 1, what);
        if (r == null || HondaDatalog.Checksum(r, n) != r[n]) return null;
        return r;
    }

    public override bool Handshake(IByteLink link, out string note)
    {
        note = "no answer through the Demon";
        for (int attempt = 0; attempt <= Math.Max(0, Retries); attempt++)
        {
            // the ECU's handshake, asked three times over by the Demon (as the tuning software asks it)
            var ok = Exchange(link, Setup(0, (1, _plan.Hello), (1, _plan.Hello), (1, _plan.Hello)), 1, "Demon setup (handshake)");
            if (ok == null) { note = "the emulator did not answer the datalog setup: is it a Demon?"; continue; }
            if (ok[0] != 'O') { note = $"the emulator answered {ok[0]:X2} to the datalog setup (a Demon answers 'O')"; continue; }
            var r = Fetch(link, 3, 0, "Demon handshake");
            if (r == null) { note = "no answer from the Demon to 'd'"; continue; }
            if (r[1] is 0x54 or 0x84) { note = "the Demon is there but the ECU did not answer it: ignition on? datalog wiring?"; continue; }
            if (r[1] != _plan.HelloAnswer) { note = $"the ECU answered {r[1]:X2} to {_plan.Hello:X2} through the Demon, expected {_plan.HelloAnswer:X2}"; continue; }
            // now the frame, with the analog inputs
            var go = Exchange(link, Setup(Adc, (_plan.Length + 1, _plan.Request)), 1, "Demon setup (frames)");
            if (go is not [(byte)'O']) { note = "the Demon did not take the frame request"; continue; }
            note = $"handshake {_plan.Hello:X2} -> {_plan.HelloAnswer:X2} through the Demon";
            return true;
        }
        return false;
    }

    /// The Demon asks the ECU for the command instead of the frame, once, and is set back to the frame after (as the tuning software clears the check-engine lamp through a Demon). Its footer is 'T' when the ECU did not answer.
    public override byte? Command(IByteLink link, byte command, out string note)
    {
        byte? answer = null;
        note = $"the Demon did not take the command {command:X2}";
        var ok = Exchange(link, Setup(0, (1, command)), 1, $"Demon setup (command {command:X2})");
        if (ok is [(byte)'O'])
        {
            var r = Fetch(link, 1, 0, $"command {command:X2}");
            if (r == null) note = $"no answer from the Demon to 'd' after {command:X2}";
            else if (r[2] == 'T') note = $"the ECU did not answer {command:X2} (through the Demon)";
            else { answer = r[1]; note = $"{command:X2} answered {r[1]:X2} (through the Demon)"; }
        }
        var back = Exchange(link, Setup(Adc, (_plan.Length + 1, _plan.Request)), 1, "Demon setup (frames)");
        if (back is not [(byte)'O']) note += "; the frame request was not taken back: it is asked again at the next handshake";
        return answer;
    }

    public override LogFrame? Poll(IByteLink link, double t, out string note)
    {
        int len = _plan.Length;
        var r = Fetch(link, len + 1, Analog, "frame");
        if (r == null) { note = "timeout or bad checksum from the Demon"; return null; }
        if (r[1] is 0x54 or 0x84) { note = "the ECU did not answer the Demon"; return null; }
        var data = r[1..(1 + len)];
        if (HondaDatalog.Checksum(data, len) != r[1 + len]) { note = "bad checksum from the ECU"; return null; }
        var f = _plan.Decode(data, t);
        f.T = t; f.Protocol = Name;
        // the Demon's own analog inputs, as volts
        for (int k = 0; k < Analog; k++)
        {
            int at = 2 + len + (k * 2);
            f.Extra[$"emu_a{k + 1}_v"] = Math.Round(((r[at] << 8) | r[at + 1]) * 5.0 / 1023.0, 3);
        }
        note = "ok";
        return f;
    }
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
        { note = $"C6/C7 answered {a[0]:X2} {b[0]:X2} (rpm {1875000.0 / Math.Max(1, a[0] | (b[0] << 8)):0})"; return true; }
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
    readonly List<byte> _buf = [];

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
            for (int off = 0; off < len && off + (3 * len) <= data.Length; off++)
            {
                bool ok = true;
                for (int k = 0; k < 3 && ok; k++)
                    ok = HondaDatalog.Checksum(data[(off + (k * len))..], len - 1) == data[off + (k * len) + len - 1];
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
            while (_buf.Count >= _length && HondaDatalog.Checksum([.. _buf], _length - 1) != _buf[_length - 1]) _buf.RemoveAt(0);
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
        var fr = new LogFrame { T = t, Raw = [.. raw], RawChannels = RawNames.Bytes(raw.Length) };
        return fr;
    }
}

/// The P13 / P14 (MSM66911) datalogging ROMs: the same 10h -> CDh handshake as the 66207 multi-byte ROMs, then a command byte that streams a checksummed frame built from a descriptor table in the ROM. 46h is the table the established tuning software reads; 20h is the shorter one. The frame LENGTH is worked out from the data rather than assumed, because the descriptor table is part of the ROM and every build of a datalogging P13 has a slightly different one (the public tables are 38 and 26 entries, some of them placeholders). What each byte MEANS is likewise a property of that table, not of the protocol, so the bytes are logged raw as b0, b1, ... - and the Datalog page's "Detect layout" is the thing that names them: it probes the ROM in a simulator, changes one engine input at a time and watches which byte of the frame follows it.
public sealed class P13Protocol : DatalogProtocol
{
    readonly byte _request;
    int _length;          // including the checksum byte

    public P13Protocol(byte request) { _request = request; }

    public override string Name => $"P13 {_request:X2}h";
    public override string Description =>
        $"MSM66911 / P13: handshake 10\u2192CD, then {_request:X2}h returns a checksummed frame (its length is found from the data; bytes shown raw)";

    public override bool Handshake(IByteLink link, out string note)
    {
        _length = 0;
        if (!HandshakeByte(link, 0x10, 0xCD, out note)) return false;
        // ask once and see how long the answer is: the frame ends at the byte that makes the additive sum of everything before it come out right
        link.Discard();
        Send(link, _request);
        var buf = new List<byte>();
        var chunk = new byte[256];
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < Math.Max(TimeoutMs, 400) && buf.Count < 256)
        {
            int n = link.Read(chunk, 0, chunk.Length, 60);
            if (n <= 0 && buf.Count > 0) break;
            for (int i = 0; i < n; i++) buf.Add(chunk[i]);
        }
        var data = buf.ToArray();
        OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Rx, data, "frame length probe"));
        if (data.Length < 5) { note = data.Length == 0 ? $"handshake ok, but nothing came back from {_request:X2}h" : $"only {data.Length} bytes answered {_request:X2}h"; return false; }
        // prefer the longest length that fits, so a frame is not cut short by a byte that happens to add up
        for (int len = data.Length; len >= 5; len--)
            if (HondaDatalog.Checksum(data, len - 1) == data[len - 1])
            {
                _length = len;
                note = $"handshake ok, {_request:X2}h returns {len - 1} bytes + checksum";
                return true;
            }
        note = $"{data.Length} bytes answered {_request:X2}h, none of them a valid checksum";
        return false;
    }

    public override LogFrame? Poll(IByteLink link, double t, out string note)
    {
        if (_length == 0) { note = "no handshake"; return null; }
        return Framed(link, _request, _length - 1, raw => Decode(raw, t, Name), t, out note);
    }

    static LogFrame Decode(byte[] raw, double t, string name)
    {
        var f = new LogFrame { T = t, Raw = [.. raw], Protocol = name, RawChannels = RawNames.Bytes(raw.Length) };
        // the one field every P13 datalogger puts in the same place: the crank period, as the 16-bit word the ROM keeps at RAM 0x00AE, from which rpm = 1875000 / period. It is not guessed at here - "Detect layout" is what finds it - but the maths is in Honda66911 for whatever does.
        return f;
    }
}

/// The MSM66911 (Honda P13 / P14) sensor conversions, as the stock ROM implies them. The 66207's numbers are close but not the same, and the crank timer is the reason: it ticks every 4.000 us on this part, which is what makes the rpm constant come out at 1,875,000 - the same figure the 66207 uses, reached a different way.
public static class Honda66911
{
    /// The 16-bit crank period the ROM keeps (1.5 teeth = 45 degrees of crank, in 4 us ticks).
    public const double RpmConstant = 1_875_000;

    public static double Rpm(int period) => period <= 0 ? 0 : RpmConstant / period;

    /// The 8-bit rpm byte the datalog streams, back to rpm. The ROM builds it from the 16-bit period in four bands - byte = 240000/N - 64, 120000/N, 60000/N + 64, 30000/N + 128 - which, with rpm = 1875000/N, come out as four straight lines that meet at 1000, 2000 and 4000 rpm. 0xFE and 0xFF are the ROM's own saturation markers rather than readings.
    public static double Rpm8(byte raw) => raw switch
    {
        0 => 0,                                     // stopped
        1 => 400,                                   // running, below the bottom of the scale (500 rpm)
        0xFE => 7_862,                              // "above about 7862"
        0xFF => 10_053,                             // "above 10053"
        < 0x40 => 7.8125 * (raw + 64),              //  500 - 1000
        < 0x80 => 15.625 * raw,                     // 1000 - 2000
        < 0xC0 => 31.25 * (raw - 64),               // 2000 - 4000
        _ => 62.5 * (raw - 128),                    // 4000 - 8000
    };

    /// MAP from the raw A/D high byte: the sensor reads -70 mBar at 0 V and 1790 at 5 V.
    public static double MapMbar(byte raw) => (raw * (1860.0 / 255)) - 70;

    public static double MapKpa(byte raw) => MapMbar(raw) / 10;

    /// The table/axis domain the ROM compares against: (Map16 - 0x1800) >> 7, which covers 108..1031 mBar. Boost cannot be represented in that byte.
    public static int MapAxisByte(int map16) => Math.Clamp((map16 - 0x1800) >> 7, 0, 255);

    /// The shared NTC curve for coolant and intake air: the polynomial in volts the ROM's own table follows, in degrees C.
    public static double ThermistorC(byte raw)
    {
        double v = raw / 51.0;
        double f = (0.1423 * Math.Pow(v, 6)) - (2.4938 * Math.Pow(v, 5)) + (17.837 * Math.Pow(v, 4))
                   - (68.698 * Math.Pow(v, 3)) + (154.69 * v * v) - (232.75 * v) + 284.24;
        return Math.Round((f - 32) * 5 / 9, 1);
    }

    /// A plain 0-5 V input (TPS, O2, ELD).
    public static double Volts(byte raw) => raw / 51.0;

    /// Battery volts: the divider is not the same as the plain inputs.
    public static double BatteryVolts(byte raw) => Math.Round(raw * 4.9 / 51.0, 2);

    /// Ignition advance from the raw byte the datalog streams.
    public static double AdvanceDeg(byte raw) => (raw - 24) / 4.0;

    /// Injector pulse width from the ROM's fuel word (4.00839 us per count).
    public static double InjectorMs(int ticks) => Math.Round(ticks * 4.00839 / 1000, 3);
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
            case "word" when raw != null && int.TryParse(parts[1], out var w) && w >= 0 && w + 1 < raw.Length: x = raw[w] | (raw[w + 1] << 8); break;
            case "bit" when raw != null:
                {
                    var bb = parts[1].Split('.');
                    if (bb.Length == 2 && int.TryParse(bb[0], out var bi) && int.TryParse(bb[1], out var bit) && bi >= 0 && bi < raw.Length)
                        x = (raw[bi] >> (bit & 7)) & 1;
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
    public double[] Mean = [];
    public double[] Min = [];
    public double[] Max = [];
    public int[] Count = [];
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
                int i = (r * Item.Cols) + c;
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
            if (inside && a1 != a0) return i0 + ((v - a0) / (a1 - a0) * (i1 - i0));
        }
        return asc ? (v < pts[0].a ? pts[0].i : pts[^1].i) : (v > pts[0].a ? pts[0].i : pts[^1].i);
    }

    public static OverlayResult Compute(DefinitionSet defs, byte[] rom, ItemDef item, IEnumerable<LogFrame> frames, string channel,
                                        Func<LogFrame, bool>? filter = null)
    {
        int rows = Math.Max(1, item.Rows), cols = Math.Max(1, item.Cols), n = rows * cols;
        var rowAxis = item.RowAxis == null ? [.. Enumerable.Range(0, rows).Select(i => (double)i)] : RomData.AxisValues(defs, rom, item.RowAxis, rows);
        var colAxis = item.ColAxis == null ? [.. Enumerable.Range(0, cols).Select(i => (double)i)] : RomData.AxisValues(defs, rom, item.ColAxis, cols);
        var (rn, rget) = AxisInput(defs, item.RowAxis, true);
        var (cn, cget) = AxisInput(defs, item.ColAxis, false);
        var res = new OverlayResult
        {
            Item = item, Channel = channel, Mean = new double[n], Min = [.. Enumerable.Repeat(double.MaxValue, n)],
            Max = [.. Enumerable.Repeat(double.MinValue, n)], Count = new int[n], RowSource = rn, ColSource = cn,
        };
        var sum = new double[n];
        filter ??= MapSide.Filter(item);      // don't smear the high-cam map into the low-cam one
        foreach (var f in frames)
        {
            if (filter != null && !filter(f)) continue;
            if (f.Get(channel) is not double v || rget(f) is not double rv || (cols > 1 && cget(f) is not double)) continue;
            int r = item.RowAxis == null && rows == 1 ? 0 : Nearest(rowAxis, rv);
            int c = cols == 1 ? 0 : Nearest(colAxis, cget(f)!.Value);
            int i = (r * cols) + c;
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
        return data.Length > 160 && DecodeLogger(data) is { } dec && IsLoggerFile(dec) ? LoadLogger(dec) : LoadCsv(path);
    }

    static bool IsLoggerFile(byte[] data) =>
        data.Length >= 17 && Encoding.ASCII.GetString(data, 0, 10) is "DATALOGGER" or "eCtune.dlf" or [_, _, _, _, _, _, '.', 'b', 'm', 'l'];

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
                // record order in the file: bytes0-5, rpm word, bytes6-14, inj word, ign x2, inputs, outputs, ..., then the elapsed-ms counters
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
        var extras = LogFrame.AllChannels(all).Where(c => !LogFrame.Fields.Contains(c)).ToList();
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
