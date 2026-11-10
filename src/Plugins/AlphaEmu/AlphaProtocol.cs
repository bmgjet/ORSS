// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.IO.Ports;
using System.Text;

namespace AlphaEmuPlugin;

/// The commands the ALPHAemu bridge answers. Framing and codes are the plugin's own ALPHAlink-over-
/// serial dialect: the same things the ALPHAlink desktop service was asked to do (identify, stage a
/// slot, verify it, push real-time byte patches, read the analog bank, stream the datalog), written
/// down as bytes so anything that answers them - real hardware, a bridge box, or the built-in device
/// in this plugin - drives the same screens.
public static class AlphaCmd
{
    public const byte Echo = 0x01, Identity = 0x02;
    public const byte SlotStatus = 0x03, SlotInfo = 0x04, ActiveSlot = 0x05;
    public const byte WriteBegin = 0x08, WriteData = 0x09, WriteCommit = 0x0A, Verify = 0x0B, ReadSlot = 0x0C;
    public const byte Patch = 0x10, Analog = 0x20, DtcRead = 0x30, DtcClear = 0x31;
    public const byte StreamStart = 0x40, StreamStop = 0x41, StreamData = 0x42;
    public const byte FwInfo = 0x50, FwStage = 0x51, FwApply = 0x52, FwStatus = 0x53;
    public const byte Sync = 0x60;

    /// A reply has the top bit set; an error reply has both top bits and says why in its body.
    public const byte ReplyBit = 0x80, ErrorBit = 0xC0;
}

/// One request/response: ok or the reason it was not, and the body either way.
public sealed record AlphaReply(bool Ok, byte[] Body, string Error)
{
    public static AlphaReply Fail(string why) => new(false, [], why);
    /// The body read as text ("key=value;key=value").
    public string Text => Ok ? Encoding.ASCII.GetString(Body) : Error;
    /// The values out of a "key=value;key=value" answer.
    public Dictionary<string, string> Fields()
    {
        var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var part in Text.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            int eq = part.IndexOf('=');
            if (eq > 0) d[part[..eq].Trim()] = part[(eq + 1)..].Trim();
        }
        return d;
    }
    public int Num(string key, int fallback = 0) => Fields().TryGetValue(key, out var v) && int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : fallback;
    public string Str(string key, string fallback = "") => Fields().TryGetValue(key, out var v) && v.Length > 0 ? v : fallback;
}

/// Something that answers the ALPHAemu commands: a serial port with hardware on it, or the built-in device.
public interface IAlphaLink : IDisposable
{
    /// What to call this thing in the UI ("COM7 at 921600", "built-in ALPHA NextGEN").
    string Description { get; }
    /// Open the port / start the device. Throw with a plain reason when it cannot.
    void Open();
    /// One command and its answer.
    AlphaReply Command(byte command, byte[] body, int timeoutMs = 2000);
    /// Start and stop the datalog stream; frames arrive on ReadStream.
    void StreamStart(int hertz);
    void StreamStop();
    /// The next streamed frame's payload, or null if none came in time.
    byte[]? ReadStream(int timeoutMs);
    /// Every frame sent and received, for the log pane.
    event Action<string>? Traffic;
}

/// The frame on the wire: A5 5A len-lo len-hi cmd seq body... crc8.
public static class AlphaFrame
{
    public const byte Sync1 = 0xA5, Sync2 = 0x5A;

    public static byte[] Build(byte cmd, byte seq, byte[] body)
    {
        var f = new byte[body.Length + 7];
        f[0] = Sync1; f[1] = Sync2;
        f[2] = (byte)(body.Length & 0xFF); f[3] = (byte)(body.Length >> 8 & 0xFF);
        f[4] = cmd; f[5] = seq;
        body.CopyTo(f, 6);
        f[^1] = Crc(f, 4, body.Length + 2);
        return f;
    }

    /// CRC-8 (poly 0x07), over the command, sequence and body.
    public static byte Crc(byte[] data, int offset, int count)
    {
        byte crc = 0;
        for (int i = offset; i < offset + count; i++)
        {
            crc ^= data[i];
            for (int b = 0; b < 8; b++) crc = (byte)((crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1);
        }
        return crc;
    }

    /// Pull the next whole frame out of the buffer; true when one was taken (cmd, seq, body come back).
    public static bool Take(List<byte> buffer, out byte cmd, out byte seq, out byte[] body)
    {
        cmd = 0; seq = 0; body = [];
        // throw away anything before a sync mark
        int s = 0;
        while (s + 1 < buffer.Count && !(buffer[s] == Sync1 && buffer[s + 1] == Sync2)) s++;
        if (s > 0) buffer.RemoveRange(0, s);
        if (buffer.Count < 7) return false;
        int len = buffer[2] | (buffer[3] << 8);
        if (len > 64 * 1024) { buffer.RemoveRange(0, 2); return false; }        // bogus length: resync
        if (buffer.Count < len + 7) return false;
        byte crc = Crc([.. buffer], 4, len + 2);
        if (crc != buffer[len + 6]) { buffer.RemoveRange(0, 2); return false; }
        cmd = buffer[4]; seq = buffer[5];
        body = new byte[len];
        Buffer.BlockCopy(buffer.ToArray(), 6, body, 0, len);
        buffer.RemoveRange(0, len + 7);
        return true;
    }
}

/// The bodies of the commands that carry an image offset, in one place so the side that sends them
/// and the side that answers them cannot drift apart. Offsets are 32-bit little-endian: Honda images
/// run well past 64 KB and a 16-bit offset would wrap a big image back onto its own start.
public static class AlphaWire
{
    /// WriteData: the slot, the 32-bit offset, then the bytes themselves.
    public static byte[] WriteData(int slot, byte[] image, int at, int take)
    {
        var body = new byte[5 + take];
        body[0] = (byte)slot;
        Put32(body, 1, at);
        Buffer.BlockCopy(image, at, body, 5, take);
        return body;
    }

    /// The parts of a WriteData body: slot, offset and where the bytes start.
    public static (int Slot, int Offset, int DataStart) ReadWriteData(byte[] body)
    {
        if (body.Length < 5) throw new ArgumentException("a slot data frame needs a slot, an offset and some bytes");
        return (body[0], Get32(body, 1), 5);
    }

    /// A ReadSlot answer: the 32-bit offset the bytes belong at, then the bytes.
    public static byte[] ReadSlotReply(byte[] image, int at, int count)
    {
        var r = new byte[count + 4];
        Put32(r, 0, at);
        Buffer.BlockCopy(image, at, r, 4, count);
        return r;
    }

    /// The offset of a ReadSlot answer and where its bytes start.
    public static (int Offset, int DataStart) ReadSlotAnswer(byte[] body)
    {
        if (body.Length < 4) throw new ArgumentException("a slot read answer needs its 4-byte offset");
        return (Get32(body, 0), 4);
    }

    /// A real-time patch: how many pairs follow, then 32-bit-offset / byte pairs.
    public static byte[] Patch(IReadOnlyList<(int Offset, byte Value)> edits, int from, int take)
    {
        var body = new byte[2 + take * 5];
        body[0] = (byte)(take & 0xFF); body[1] = (byte)(take >> 8);
        for (int i = 0; i < take; i++) { Put32(body, 2 + i * 5, edits[from + i].Offset); body[2 + i * 5 + 4] = edits[from + i].Value; }
        return body;
    }

    /// How many pairs a patch body says it carries.
    public static int PatchCount(byte[] body) => body.Length >= 2 ? body[0] | (body[1] << 8) : 0;

    /// The pairs in a patch body, stopping short of anything truncated.
    public static IEnumerable<(int Offset, byte Value)> PatchPairs(byte[] body)
    {
        int n = PatchCount(body);
        for (int i = 0; i < n && 2 + i * 5 + 5 <= body.Length; i++)
            yield return (Get32(body, 2 + i * 5), body[2 + i * 5 + 4]);
    }

    static void Put32(byte[] b, int at, int v)
    {
        b[at] = (byte)(v & 0xFF); b[at + 1] = (byte)(v >> 8 & 0xFF); b[at + 2] = (byte)(v >> 16 & 0xFF); b[at + 3] = (byte)(v >> 24 & 0xFF);
    }
    static int Get32(byte[] b, int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);
}

/// A real ALPHAemu (or a bridge box) hanging off a serial port.
public sealed class SerialAlphaLink : IAlphaLink
{
    readonly string _port;
    readonly int _baud;
    SerialPort? _serial;
    readonly List<byte> _rx = [];
    readonly object _gate = new();
    readonly Dictionary<byte, TaskCompletionSource<AlphaReply>> _waiting = new();
    readonly Queue<byte[]> _stream = new();
    byte _seq;
    bool _streaming;

    public event Action<string>? Traffic;
    public string Description { get; }

    public SerialAlphaLink(string port, int baud)
    {
        _port = port; _baud = baud;
        Description = $"{port} at {baud.ToString("#,0", CultureInfo.InvariantCulture)} baud";
    }

    public void Open()
    {
        Close();
        _serial = new SerialPort(_port, _baud, Parity.None, 8, StopBits.One)
        { ReadTimeout = 50, WriteTimeout = 1000, DtrEnable = true, RtsEnable = true };
        _serial.Open();
        _serial.DataReceived += OnData;
        Traffic?.Invoke("→ opened " + Description);
    }

    void OnData(object? sender, SerialDataReceivedEventArgs e)
    {
        try
        {
            var s = _serial;
            if (s == null || !s.IsOpen) return;
            byte[] chunk = new byte[Math.Max(1, s.BytesToRead)];
            int got = s.Read(chunk, 0, chunk.Length);
            lock (_gate) for (int i = 0; i < got; i++) _rx.Add(chunk[i]);
            while (true)
            {
                byte cmd, seq; byte[] body;
                lock (_gate) { if (!AlphaFrame.Take(_rx, out cmd, out seq, out body)) break; }
                if (cmd == AlphaCmd.StreamData) { lock (_stream) { _stream.Enqueue(body); while (_stream.Count > 256) _stream.Dequeue(); } continue; }
                TaskCompletionSource<AlphaReply>? tcs;
                lock (_gate) { if (!_waiting.TryGetValue(seq, out tcs)) continue; _waiting.Remove(seq); }
                bool err = (cmd & AlphaCmd.ErrorBit) == AlphaCmd.ErrorBit;
                tcs.TrySetResult(new AlphaReply(!err, body, err ? Encoding.ASCII.GetString(body) : ""));
            }
        }
        catch { }
    }

    public AlphaReply Command(byte command, byte[] body, int timeoutMs = 2000)
    {
        var s = _serial;
        if (s is not { IsOpen: true }) return AlphaReply.Fail($"the {Description} port is not open");
        byte seq;
        var tcs = new TaskCompletionSource<AlphaReply>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_gate) { seq = ++_seq; _waiting[seq] = tcs; }
        var frame = AlphaFrame.Build(command, seq, body);
        Traffic?.Invoke("→ " + Name(command) + " (" + body.Length + " bytes)");
        try { s.Write(frame, 0, frame.Length); }
        catch (Exception ex) { lock (_gate) _waiting.Remove(seq); return AlphaReply.Fail("could not write to " + _port + ": " + ex.Message); }
        if (!tcs.Task.Wait(timeoutMs))
        {
            lock (_gate) _waiting.Remove(seq);
            return AlphaReply.Fail($"no answer to {Name(command)} from the {Description} in {timeoutMs} ms");
        }
        var reply = tcs.Task.Result;
        Traffic?.Invoke("← " + Name(command) + (reply.Ok ? " ok" : " " + reply.Error));
        return reply;
    }

    public void StreamStart(int hertz)
    {
        var r = Command(AlphaCmd.StreamStart, Encoding.ASCII.GetBytes("hz=" + hertz));
        if (!r.Ok) throw new IOException(r.Error);
        _streaming = true;
    }

    public void StreamStop()
    {
        if (!_streaming) return;
        _streaming = false;
        Command(AlphaCmd.StreamStop, []);
    }

    public byte[]? ReadStream(int timeoutMs)
    {
        var until = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < until)
        {
            lock (_stream) if (_stream.Count > 0) return _stream.Dequeue();
            Thread.Sleep(4);
        }
        return null;
    }

    void Close()
    {
        var s = _serial; _serial = null;
        if (s == null) return;
        try { s.DataReceived -= OnData; if (s.IsOpen) s.Close(); } catch { }
        s.Dispose();
    }

    public void Dispose() { StreamStop(); Close(); }

    public static string Name(byte cmd) => cmd switch
    {
        AlphaCmd.Echo => "echo", AlphaCmd.Identity => "identity", AlphaCmd.SlotStatus => "slot status",
        AlphaCmd.SlotInfo => "slot info", AlphaCmd.ActiveSlot => "active slot", AlphaCmd.WriteBegin => "begin slot write",
        AlphaCmd.WriteData => "slot data", AlphaCmd.WriteCommit => "commit slot", AlphaCmd.Verify => "verify slot",
        AlphaCmd.ReadSlot => "read slot", AlphaCmd.Patch => "real-time patch", AlphaCmd.Analog => "analog bank",
        AlphaCmd.DtcRead => "trouble codes", AlphaCmd.DtcClear => "clear trouble codes", AlphaCmd.StreamStart => "start stream",
        AlphaCmd.StreamStop => "stop stream", AlphaCmd.FwInfo => "firmware", AlphaCmd.FwStage => "stage firmware",
        AlphaCmd.FwApply => "apply firmware", AlphaCmd.FwStatus => "firmware progress", AlphaCmd.Sync => "sync",
        _ => $"command {cmd:X2}",
    };
}

/// A stream frame's bytes (the 24 bytes the ALPHAemu sends every tick) read out as a LogFrame.
public static class AlphaStreamFrame
{
    public const int Length = 24;

    public static OkiRomSim.Calibration.LogFrame Decode(byte[] p, OkiRomSim.Calibration.LogFrame? template = null)
    {
        if (p.Length < Length) throw new ArgumentException($"an ALPHAemu stream frame is {Length} bytes, this one is {p.Length}");
        int U16(int at) => p[at] | (p[at + 1] << 8);
        var f = template ?? new OkiRomSim.Calibration.LogFrame();
        f.Protocol = "ALPHAemu";
        f.Rpm = U16(0);
        f.TpsPct = p[2] * 100.0 / 255;
        f.MapKpa = U16(3) / 10.0;
        f.EctC = p[5] - 40;
        f.IatC = p[6] - 40;
        f.O2V = Math.Round(p[7] * 5.0 / 255, 3);
        f.Extra["afr"] = U16(8) / 100.0;
        f.IgnDeg = (sbyte)p[10];
        f.InjMs = U16(11) / 10.0;
        f.Extra["inj_duty_pct"] = (double)p[13];
        f.SpeedKmh = p[14];
        f.BattV = U16(15) / 100.0;
        f.BaroKpa = p[17];
        byte flags = p[18];
        f.Vtec = (flags & 1) != 0;
        f.FuelPump = (flags & 2) != 0;
        f.Extra["mil"] = (flags & 4) != 0 ? 1.0 : 0;
        f.Extra["fc"] = (flags & 8) != 0 ? 1.0 : 0;
        f.Extra["bks"] = (flags & 16) != 0 ? 1.0 : 0;
        f.Extra["s_chg"] = (flags & 32) != 0 ? 1.0 : 0;
        f.Extra["dtc0"] = p[19]; f.Extra["dtc1"] = p[20]; f.Extra["dtc2"] = p[21]; f.Extra["dtc3"] = p[22];
        f.Raw = p;
        f.RawChannels = OkiRomSim.Calibration.RawNames.Of("alphaemu24", () => new OkiRomSim.Calibration.RawNames(
            Enumerable.Range(0, Length).Select(i => ($"b{i}", i))));
        return f;
    }

    /// The other way round (the built-in device builds these).
    public static byte[] Encode(double rpm, double tpsPct, double mapKpa, double ectC, double iatC, double o2V, double afr,
                                 double ignDeg, double injMs, double dutyPct, double vssKmh, double battV, double baroKpa,
                                 byte flags, byte[] dtc)
    {
        var p = new byte[Length];
        ushort r = (ushort)Math.Clamp(rpm, 0, 65535);
        p[0] = (byte)(r & 0xFF); p[1] = (byte)(r >> 8);
        p[2] = (byte)Math.Clamp(tpsPct * 255 / 100, 0, 255);
        ushort m = (ushort)Math.Clamp(mapKpa * 10, 0, 65535);
        p[3] = (byte)(m & 0xFF); p[4] = (byte)(m >> 8);
        p[5] = (byte)Math.Clamp(ectC + 40, 0, 255);
        p[6] = (byte)Math.Clamp(iatC + 40, 0, 255);
        p[7] = (byte)Math.Clamp(o2V * 255 / 5, 0, 255);
        ushort a = (ushort)Math.Clamp(afr * 100, 0, 65535);
        p[8] = (byte)(a & 0xFF); p[9] = (byte)(a >> 8);
        p[10] = (byte)(sbyte)Math.Clamp(ignDeg, -64, 63);
        ushort i = (ushort)Math.Clamp(injMs * 10, 0, 65535);
        p[11] = (byte)(i & 0xFF); p[12] = (byte)(i >> 8);
        p[13] = (byte)Math.Clamp(dutyPct, 0, 255);
        p[14] = (byte)Math.Clamp(vssKmh, 0, 255);
        ushort b = (ushort)Math.Clamp(battV * 100, 0, 65535);
        p[15] = (byte)(b & 0xFF); p[16] = (byte)(b >> 8);
        p[17] = (byte)Math.Clamp(baroKpa, 0, 255);
        p[18] = flags;
        for (int k = 0; k < 4; k++) p[19 + k] = k < dtc.Length ? dtc[k] : (byte)0;
        return p;
    }
}


