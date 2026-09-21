using System.Diagnostics;
using System.Globalization;
using System.IO.Ports;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// A serial port as a byte link for the datalog protocols.
public sealed class SerialLink : IByteLink, IDisposable
{
    readonly SerialPort _port;
    public string Name => _port.PortName;

    public SerialLink(string port, int baud)
    {
        _port = new SerialPort(port, baud, Parity.None, 8, StopBits.One) { ReadTimeout = 300, WriteTimeout = 500 };
        _port.Open();
    }

    public void Write(byte[] data) => _port.Write(data, 0, data.Length);

    public int Read(byte[] buffer, int offset, int count, int timeoutMs)
    {
        _port.ReadTimeout = Math.Max(1, timeoutMs);
        try { return _port.Read(buffer, offset, count); }
        catch (TimeoutException) { return 0; }
    }

    public void Discard() { try { _port.DiscardInBuffer(); } catch { } }
    public void Dispose() { try { _port.Close(); _port.Dispose(); } catch { } }

    public static string[] Ports() => SerialPort.GetPortNames().OrderBy(p => p.Length).ThenBy(p => p).ToArray();
}

/// The simulated ROM's own serial port: the datalog talks to the ROM's datalogging code exactly as it would to a car (a "virtual ECU"). Bytes travel at the cable's baud rate in simulated time, so the simulator must be running for answers to come back.
public sealed class SimLink : IByteLink
{
    readonly SimHost _host;
    public SimLink(SimHost host) { _host = host; }
    public string Name => "simulator";
    public void Write(byte[] data) => _host.SerialToRom(data);
    public void Discard() => _host.SerialDiscard();

    public int Read(byte[] buffer, int offset, int count, int timeoutMs)
    {
        var sw = Stopwatch.StartNew();
        int got = 0;
        while (got < count && sw.ElapsedMilliseconds < timeoutMs)
        {
            int n = _host.SerialFromRom(buffer, offset + got, count - got);
            got += n;
            if (got < count) Thread.Sleep(n > 0 ? 0 : 2);
        }
        return got;
    }
}

/// A wideband O2 controller on its own serial port. The formats these controllers send: AEM (ASCII AFR lines, 9600), Zeitronix (00 01 02 header, AFR x10), TechEdge (5A A5, lambda word / 8192 + 0.5, 19200), PLX (FF-terminated 9-byte frames), Innovate LC-1 / LM-2 (MTS lambda words, 19200), 14Point7 Spartan (asks "G", answers "0:a:14.70").
public sealed class WidebandReader : IDisposable
{
    SerialPort? _port;
    Thread? _thread;
    volatile bool _stop;
    public double? Afr { get; private set; }
    public double? Lambda => Afr / Stoich;
    public double Stoich { get; set; } = 14.7;
    public DateTime LastAt { get; private set; }
    public string Type { get; private set; } = "none";
    public string Status { get; private set; } = "off";
    public bool Running => _thread?.IsAlive == true;
    public bool Fresh => Afr != null && (DateTime.Now - LastAt).TotalSeconds < 2;

    public static readonly string[] Types = { "none", "AEM", "Zeitronix", "TechEdge", "PLX", "Innovate", "Spartan" };

    public static int DefaultBaud(string type) => type switch { "TechEdge" or "PLX" or "Innovate" => 19200, _ => 9600 };

    public void Start(string type, string port, int baud)
    {
        Stop();
        if (type == "none" || port.Length == 0) { Status = "off"; return; }
        Type = type;
        _port = new SerialPort(port, baud > 0 ? baud : DefaultBaud(type), Parity.None, 8, StopBits.One) { ReadTimeout = 500, NewLine = "\n" };
        _port.Open();
        _stop = false;
        Status = $"{type} on {port}: waiting for data";
        _thread = new Thread(Run) { IsBackground = true, Name = "wideband" };
        _thread.Start();
    }

    void Set(double afr)
    {
        if (afr < 5 || afr > 30) return;
        Afr = Math.Round(afr, 2);
        LastAt = DateTime.Now;
        Status = $"{Type}: {Afr:0.00} AFR";
    }

    byte B(SerialPort p) => (byte)p.ReadByte();

    void Run()
    {
        var p = _port!;
        int errors = 0;
        while (!_stop)
        {
            try
            {
                switch (Type)
                {
                    case "AEM":
                        {
                            var line = p.ReadLine().Trim();
                            if (double.TryParse(line, NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) Set(v < 2 ? v * Stoich : v);
                            break;
                        }
                    case "Spartan":
                        {
                            p.WriteLine("G");
                            var line = p.ReadLine();
                            if (line.Contains("0:a:") && double.TryParse(line.Replace("0:a:", "").Replace(">", "").Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) Set(v);
                            Thread.Sleep(50);
                            break;
                        }
                    case "Zeitronix":
                        {
                            if (B(p) != 0 || B(p) != 1 || B(p) != 2) break;
                            var f = new byte[11];
                            for (int i = 0; i < 11; i++) f[i] = B(p);
                            Set(f[0] / 10.0);
                            break;
                        }
                    case "TechEdge":
                        {
                            if (B(p) != 0x5A || B(p) != 0xA5) break;
                            var f = new byte[26];
                            for (int i = 0; i < 26; i++) f[i] = B(p);
                            int word = f[3] << 8 | f[4];                 // frame bytes 5-6
                            if (f[23] == 3 && f[24] == 0) Set((word / 8192.0 + 0.5) * Stoich);
                            break;
                        }
                    case "PLX":
                        {
                            if (B(p) != 0xFF) break;
                            var f = new byte[9];
                            for (int i = 0; i < 9; i++) f[i] = B(p);
                            if (f[8] == 0xFF) Set((f[7] * 0.0026667 + 0.68) * Stoich);
                            break;
                        }
                    case "Innovate":
                        {
                            // MTS: header word (bits 15,13 set, 9 and 7 set), then lambda sub-packets
                            byte h = B(p);
                            if ((h & 0xA2) != 0xA2) break;
                            byte h2 = B(p);
                            if ((h2 & 0x80) != 0x80) break;
                            byte w0 = B(p), w1 = B(p), w2 = B(p), w3 = B(p);
                            int func = (w0 >> 2) & 7;
                            int afrMul = ((w0 & 1) << 7) | (w1 & 0x7F);
                            int lambda = ((w2 & 0x3F) << 7) | (w3 & 0x7F);
                            if (func == 0) Set((lambda + 500) / 1000.0 * (afrMul > 0 ? afrMul / 10.0 : Stoich));
                            break;
                        }
                }
                errors = 0;
            }
            catch (TimeoutException) { Status = $"{Type}: no data"; }
            catch (Exception ex)
            {
                if (++errors > 5) { Status = $"{Type} stopped: {ex.Message}"; AppLog.Error("wideband", "stopped", ex); break; }
            }
        }
    }

    public void Stop()
    {
        _stop = true;
        try { _thread?.Join(600); } catch { }
        try { _port?.Close(); _port?.Dispose(); } catch { }
        _port = null;
        Afr = null;
        Status = "off";
    }

    public void Dispose() => Stop();
}

/// Datalogging from a car (serial) or the simulated ROM (virtual ECU): finds the protocol, polls frames as fast as the ECU answers, adds the wideband and aux channels, keeps every frame and every packet (for the packet monitor), and hands frames to whoever listens. Shared by the Datalog page, Tuner mode and MCP agents.
public sealed class DatalogEngine : IDisposable
{
    readonly SimHost _host;
    IByteLink? _link;
    Thread? _thread;
    volatile bool _stop;
    readonly Stopwatch _clock = new();
    readonly object _lock = new();
    readonly List<LogFrame> _frames = new();
    readonly Queue<Packet> _packets = new();
    long _packetSerial;
    public readonly WidebandReader Wideband = new();

    public event Action<LogFrame>? Frame;
    public int Good, Bad;
    public bool Running => _thread?.IsAlive == true;
    public string Status { get; private set; } = "not connected";
    public DatalogProtocol? Protocol { get; private set; }
    public string Source { get; private set; } = "";
    public LogFrame? Latest { get; private set; }
    public double FramesPerSecond { get; private set; }
    public List<AuxChannel> AuxChannels { get; set; } = new();
    public int KeepFrames { get; set; } = 50_000;
    public int IntervalMs { get; set; }
    public bool PausePackets { get; set; }
    /// A layout worked out from the ROM (DatalogLayout.Detect); used when the protocol is set to its name, and tried after the built-in ones during auto-detection.
    public DetectedProtocol? Detected { get; set; }

    public DatalogEngine(SimHost host) { _host = host; }

    public List<LogFrame> Frames() { lock (_lock) return _frames.ToList(); }
    public int FrameCount { get { lock (_lock) return _frames.Count; } }
    public void ClearFrames() { lock (_lock) _frames.Clear(); }

    /// Packets newer than `after`, with their serial numbers.
    public List<(long Serial, Packet P)> Packets(long after)
    {
        lock (_packets)
        {
            long first = _packetSerial - _packets.Count + 1;
            return _packets.Select((p, i) => (first + i, p)).Where(x => x.Item1 > after).ToList();
        }
    }

    /// Packets logged to the Debug page since this connection started: the handshake and anything unusual always, plus the first few frames, so the wire can still be read back without a monitor on screen taking up room for it.
    int _packetsLogged;

    void OnPacket(Packet p)
    {
        if (PausePackets) return;
        lock (_packets)
        {
            _packets.Enqueue(p);
            _packetSerial++;
            while (_packets.Count > 2000) _packets.Dequeue();
        }
        bool routine = p.Note is "frame" or "";
        if (!routine || _packetsLogged < 20)
        {
            if (routine) _packetsLogged++;
            AppLog.Write(LogKind.Serial, "datalog",
                $"{(p.Dir == PacketDir.Tx ? "→" : "←")} {p.Bytes.Length,3} bytes{(p.Note.Length > 0 ? "  " + p.Note : "")}",
                string.Join(" ", p.Bytes.Take(64).Select(b => b.ToString("X2"))) + (p.Bytes.Length > 64 ? " …" : ""));
        }
    }

    /// Start logging: port "simulator" talks to the simulated ROM; protocol "auto" detects.
    public void Start(string port, string protocol, int baud)
    {
        Stop();
        _link = port.Equals("simulator", StringComparison.OrdinalIgnoreCase) ? new SimLink(_host) : new SerialLink(port, baud);
        Source = _link.Name;
        if (_link is SimLink) { _host.SerialBaud = baud; if (!_host.IsRunning && _host.LoadedPath != null) _host.Control("run"); }
        _stop = false;
        _packetsLogged = 0;
        Good = Bad = 0;
        _clock.Restart();
        var chosen = protocol.Equals("auto", StringComparison.OrdinalIgnoreCase) ? null
                     : Detected is { } det && protocol.Equals(det.Name, StringComparison.OrdinalIgnoreCase) ? det
                     // a name from an older settings file that no longer exists: fall back to detecting it
                     : DatalogProtocol.ByName(protocol);
        if (chosen == null && !protocol.Equals("auto", StringComparison.OrdinalIgnoreCase))
            AppLog.Warn("datalog", $"protocol '{protocol}' is not one of the ones here any more; detecting it instead");
        Status = $"connecting to {Source}...";
        AppLog.Write(LogKind.Serial, "datalog", $"start on {Source} ({protocol}, {baud} baud)");
        _thread = new Thread(() => Run(chosen)) { IsBackground = true, Name = "datalog" };
        _thread.Start();
    }

    void Run(DatalogProtocol? chosen)
    {
        var link = _link!;
        try
        {
            if (chosen == null)
            {
                Status = "detecting the protocol...";
                var (p, report) = DatalogProtocol.Detect(link, OnPacket);
                if (p == null && Detected is { } det2)
                {
                    det2.OnPacket = OnPacket;
                    if (det2.Handshake(link, out _) && det2.Poll(link, 0, out _) != null) p = det2;
                }
                AppLog.Write(LogKind.Serial, "datalog", "protocol detection:\n" + report.TrimEnd());
                if (p == null)
                {
                    Status = "no datalog protocol answered (see the packet monitor and the Debug page). The ROM needs datalogging code; stock ROMs have none.";
                    return;
                }
                Protocol = p;
            }
            else
            {
                chosen.OnPacket = OnPacket;
                if (!chosen.Handshake(link, out var note))
                {
                    Status = $"{chosen.Name}: {note}";
                    AppLog.Warn("datalog", Status);
                    return;
                }
                Protocol = chosen;
            }
            Status = $"logging {Protocol.Name} from {Source}";
            AppLog.Write(LogKind.Serial, "datalog", Status);
            int timeouts = 0;
            var rate = Stopwatch.StartNew(); int inWindow = 0;
            while (!_stop)
            {
                double t = _clock.Elapsed.TotalSeconds;
                var f = Protocol.Poll(link, t, out var note);
                if (f == null)
                {
                    Bad++;
                    if (++timeouts == 10) { Status = $"{Protocol.Name}: {note} - no answers from the ECU"; AppLog.Warn("datalog", Status); }
                    if (timeouts > 30 && !Protocol.Handshake(link, out _)) Thread.Sleep(200);
                    continue;
                }
                if (timeouts >= 10) Status = $"logging {Protocol.Name} from {Source}";
                timeouts = 0;
                Good++;
                Enrich(f);
                lock (_lock)
                {
                    _frames.Add(f);
                    if (_frames.Count > KeepFrames) _frames.RemoveRange(0, _frames.Count - KeepFrames);
                }
                Latest = f;
                inWindow++;
                if (rate.Elapsed.TotalSeconds >= 1) { FramesPerSecond = inWindow / rate.Elapsed.TotalSeconds; inWindow = 0; rate.Restart(); }
                try { Frame?.Invoke(f); } catch (Exception ex) { AppLog.Error("datalog", "frame handler failed", ex); }
                if (IntervalMs > 0) Thread.Sleep(IntervalMs);
            }
        }
        catch (Exception ex)
        {
            Status = "datalog stopped: " + ex.Message;
            AppLog.Error("datalog", "stopped", ex);
        }
    }

    /// Wideband and aux channels onto a frame.
    public void Enrich(LogFrame f)
    {
        if (Wideband.Fresh && Wideband.Afr is double afr)
        {
            f.Extra["afr"] = afr;
            f.Extra["lambda"] = Math.Round(afr / Wideband.Stoich, 3);
        }
        foreach (var c in AuxChannels)
            if (c.Evaluate(f) is double v && !double.IsNaN(v)) f.Extra[c.Name] = Math.Round(v, 4);
    }

    public void Stop()
    {
        _stop = true;
        try { _thread?.Join(800); } catch { }
        _thread = null;
        if (_link is IDisposable d) d.Dispose();
        _link = null;
        if (Status.StartsWith("logging")) Status = $"stopped: {Good} frames, {Bad} missed";
    }

    public void Dispose() { Stop(); Wideband.Stop(); }
}
