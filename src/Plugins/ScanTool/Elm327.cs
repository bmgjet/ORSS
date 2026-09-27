// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.IO.Ports;
using System.Text;

namespace ScanToolPlugin;

/// One standard OBD-II mode 01 reading: what it is, the datalog channel it goes to, and how its bytes turn into a value.
public sealed record Pid(byte Code, string Name, string Channel, string Unit, int Bytes, Func<byte[], double> Value);

/// An ELM327 (or a clone) on a serial port: set it up with AT commands, then ask it for mode 01 readings one at a time. Every command is a line ending in CR; every answer ends with the '>' prompt.
public sealed class Elm327 : IDisposable
{
    /// The readings offered, in the order they are asked for. Formulas from SAE J1979 mode 01.
    public static readonly Pid[] Pids =
    [
        new(0x0C, "Engine speed", "rpm", "rpm", 2, b => ((b[0] * 256) + b[1]) / 4.0),
        new(0x0D, "Vehicle speed", "speed_kmh", "km/h", 1, b => b[0]),
        new(0x05, "Coolant temperature", "ect_c", "°C", 1, b => b[0] - 40),
        new(0x0F, "Intake air temperature", "iat_c", "°C", 1, b => b[0] - 40),
        new(0x0B, "Manifold pressure (MAP)", "map_kpa", "kPa", 1, b => b[0]),
        new(0x11, "Throttle position", "tps_pct", "%", 1, b => b[0] * 100.0 / 255),
        new(0x0E, "Timing advance", "ign_deg", "°", 1, b => (b[0] / 2.0) - 64),
        new(0x04, "Engine load", "load_pct", "%", 1, b => b[0] * 100.0 / 255),
        new(0x06, "Short term fuel trim", "stft_pct", "%", 1, b => (b[0] - 128) * 100.0 / 128),
        new(0x07, "Long term fuel trim", "ltft_pct", "%", 1, b => (b[0] - 128) * 100.0 / 128),
        new(0x10, "Air flow (MAF)", "maf_gs", "g/s", 2, b => ((b[0] * 256) + b[1]) / 100.0),
        new(0x14, "O2 sensor voltage (bank 1 sensor 1)", "o2_v", "V", 2, b => b[0] / 200.0),
        new(0x33, "Barometric pressure", "baro_kpa", "kPa", 1, b => b[0]),
        new(0x42, "Control module voltage", "batt_v", "V", 2, b => ((b[0] * 256) + b[1]) / 1000.0),
    ];

    readonly SerialPort _port;
    readonly StringBuilder _buf = new();
    public string Version { get; private set; } = "";
    public string Protocol { get; private set; } = "";
    /// The mode 01 readings the car says it has (from 0100 / 0120 / 0140).
    public HashSet<byte> Supported { get; } = [];
    /// Every line sent and every answer, for the window's log.
    public event Action<string>? Traffic;

    public Elm327(string port, int baud)
    {
        _port = new SerialPort(port, baud, Parity.None, 8, StopBits.One)
        {
            ReadTimeout = 200, WriteTimeout = 1000, NewLine = "\r", Encoding = Encoding.ASCII, DtrEnable = true, RtsEnable = true,
        };
        _port.Open();
    }

    /// Send one command and wait for the prompt: the answer, its lines joined by spaces, without the echo.
    public string Send(string command, int timeoutMs = 2000)
    {
        _port.DiscardInBuffer();
        Traffic?.Invoke("→ " + command);
        _port.Write(command + "\r");
        _buf.Clear();
        var until = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < until)
        {
            int n;
            try { n = _port.ReadByte(); } catch (TimeoutException) { continue; }
            if (n < 0) continue;
            char c = (char)n;
            if (c == '>')
            {
                var text = string.Join(' ', _buf.ToString().Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                    .Where(l => !l.Equals(command, StringComparison.OrdinalIgnoreCase) && !l.StartsWith("SEARCHING", StringComparison.OrdinalIgnoreCase)));
                Traffic?.Invoke("← " + text);
                return text;
            }
            _buf.Append(c);
        }
        throw new TimeoutException($"no answer to {command} from the ELM327 in {timeoutMs} ms");
    }

    /// Reset and set up the adapter, find the car's protocol and what it can report. protocol: "0" automatic, "1".."A".
    public void Start(string protocol)
    {
        Send("ATZ", 4000);                 // reset: the adapter says who it is
        Thread.Sleep(300);
        Send("ATE0");                      // no echo
        Send("ATL0");                      // no line feeds
        Send("ATS1");                      // spaces between bytes
        Send("ATH0");                      // no headers
        Send("ATAT1");                     // adaptive timing
        Version = Send("ATI");
        if (!Version.Contains("ELM", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"the device answered '{Version}', not an ELM327");
        Send("ATSP" + protocol);
        var first = Send("0100", 12000);   // the first request finds the protocol: slow on an automatic search
        if (!first.Contains("41 00")) throw new InvalidOperationException(first.Length > 0 ? $"the car did not answer: {first}" : "the car did not answer");
        Supported.Clear();
        AddSupported(first, 0x00);
        foreach (byte range in new byte[] { 0x20, 0x40 })
        {
            if (!Supported.Contains(range)) break;
            AddSupported(Send($"01{range:X2}"), range);
        }
        Protocol = Send("ATDPN");
    }

    void AddSupported(string answer, byte range)
    {
        var bytes = Data(answer, range, 4);
        if (bytes == null) return;
        uint mask = ((uint)bytes[0] << 24) | ((uint)bytes[1] << 16) | ((uint)bytes[2] << 8) | bytes[3];
        for (int i = 0; i < 32; i++) if ((mask & (1u << (31 - i))) != 0) Supported.Add((byte)(range + i + 1));
    }

    /// The data bytes of a mode 01 answer ("41 0C 1A F8" -> 1A F8), or null.
    static byte[]? Data(string answer, byte pid, int count)
    {
        var parts = answer.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        for (int i = 0; i + 1 < parts.Length; i++)
        {
            if (parts[i] != "41" || !byte.TryParse(parts[i + 1], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var p) || p != pid) continue;
            var data = new List<byte>();
            for (int k = i + 2; k < parts.Length && data.Count < count; k++)
                if (byte.TryParse(parts[k], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var b)) data.Add(b); else break;
            return data.Count == count ? [.. data] : null;
        }
        return null;
    }

    /// One reading, or null when the car did not give it.
    public double? Read(Pid pid)
    {
        var answer = Send($"01{pid.Code:X2}", 1500);
        return Data(answer, pid.Code, pid.Bytes) is { } b ? pid.Value(b) : null;
    }

    /// The supply voltage at the adapter's pin 16 (the battery), when the car has no reading of its own for it.
    public double? Battery()
    {
        var v = Send("ATRV").TrimEnd('V', 'v').Trim();
        return double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : null;
    }

    public void Dispose()
    {
        try { if (_port.IsOpen) _port.Write("ATPC\r"); } catch { }
        try { _port.Close(); } catch { }
        _port.Dispose();
    }
}
