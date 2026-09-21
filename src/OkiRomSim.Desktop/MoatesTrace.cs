using System.IO.Ports;
namespace OkiRomSim.Desktop;

/// Address hits from real hardware: how often and how recently (wall clock) each ROM address was fetched, and the most recent hits in order.
public sealed class HitStore
{
    public readonly uint[] Count = new uint[OkiRomSim.Core.Bus.RomSize];
    public readonly long[] Last = new long[OkiRomSim.Core.Bus.RomSize];
    public readonly int[] Recent = new int[8192];
    public long Total;
    static readonly System.Diagnostics.Stopwatch Clock = System.Diagnostics.Stopwatch.StartNew();
    public static long Now => Clock.ElapsedTicks;
    public static double Seconds(long ticks) => ticks / (double)System.Diagnostics.Stopwatch.Frequency;

    public void Add(int addr)
    {
        addr &= Count.Length - 1;
        if (Count[addr] < uint.MaxValue) Count[addr]++;
        Last[addr] = Now;
        Recent[Total++ % Recent.Length] = addr;
    }

    public void Clear() { Array.Clear(Count); Array.Clear(Last); Total = 0; }
}

/// Moates Ostrich 2.0 / Demon emulator link: identify the device, upload the ROM image, and run its address-hit Trace, which reports every EPROM address the ECU fetches (code and data). Protocol from "Moates Hardware Protocols v19" and the Ostrich Address Tracer: 921.6 kbaud 8-N-1, every command followed by an 8-bit additive checksum; 'V''V' -> version, minor, 'O' (Ostrich) / 'D' (Demon) 'Z''W' n MMSB MSB data(n*256) -> 'O' bulk write (a 32 KB image goes to 8000-FFFF) 'T' x1 x2 x3 y1 y2 sMMSB sMSB sLSB eMMSB eMSB eLSB -> 'O', then 3-byte hit addresses any byte sent while tracing stops it (answered with 'O').
public sealed class MoatesTrace : IDisposable
{
    SerialPort? _port;
    Thread? _thread;
    volatile bool _stop;
    public string Version { get; private set; } = "";
    public bool Connected => _port?.IsOpen == true;
    public bool Tracing => _thread?.IsAlive == true;
    /// Emulation address of ECU address 0 (the reference tracer windows 70000h + 8000h..FFFFh).
    public int Base { get; set; } = 0x78000;
    public long Hits;
    /// ECU address hit, on the trace thread.
    public event Action<int>? Hit;
    public event Action<string>? Status;

    public static string[] Ports() => SerialPort.GetPortNames().OrderBy(p => p.Length).ThenBy(p => p).ToArray();
    public string PortName => _port?.PortName ?? "";
    readonly object _io = new();
    /// Bytes written since connecting (status display).
    public long BytesUploaded { get; private set; }
    public DateTime? LastUpload { get; private set; }

    public string Connect(string portName)
    {
        lock (_io) return ConnectLocked(portName);
    }

    string ConnectLocked(string portName)
    {
        Close();
        _port = new SerialPort(portName, 921600, Parity.None, 8, StopBits.One) { ReadTimeout = 400, WriteTimeout = 1000, Handshake = Handshake.None };
        _port.Open();
        _port.DiscardInBuffer();
        Send((byte)'V', (byte)'V');
        var v = Read(3);
        string kind = v[2] switch { (byte)'O' => "Ostrich", (byte)'D' => "Demon", _ => $"device '{(char)v[2]}'" };
        Version = $"{kind} {v[0]}.{v[1]}";
        OkiRomSim.Core.AppLog.Write(OkiRomSim.Core.LogKind.Serial, "emulator", $"connected {Version} on {portName}");
        return Version;
    }

    void Send(params byte[] bytes)
    {
        var buf = new byte[bytes.Length + 1];
        Array.Copy(bytes, buf, bytes.Length);
        byte cs = 0;
        foreach (var b in bytes) cs += b;
        buf[^1] = cs;
        _port!.Write(buf, 0, buf.Length);
    }

    byte[] Read(int n)
    {
        var buf = new byte[n];
        int got = 0;
        while (got < n) got += _port!.Read(buf, got, n - got);
        return buf;
    }

    /// Upload a ROM image to the top of the 64 KB emulation space (32 KB -> 8000-FFFF).
    public void Upload(byte[] rom, Action<double>? progress = null) => WriteRange(rom, 0, rom.Length, progress);

    /// Write part of the image: the 256-byte blocks covering [start, start+length). Used for uploading calibration edits as they are made. A running trace is paused around it.
    /// Blocks are addressed in the device's own space, not the ECU's: `Base` is where ECU address 0 lives in the emulator (0x78000 on an Ostrich 2.0, whose window is the top of half a megabyte), and the command carries all three bytes of it. Sending the bare ECU address instead is what made the device answer '?' - it was being asked to write at 0x008000, which is outside the window it is emulating.
    public void WriteRange(byte[] rom, int start, int length, Action<double>? progress = null)
    {
        lock (_io)
        {
            if (_port == null) throw new InvalidOperationException("the emulator is not connected");
            bool tracing = Tracing;
            int romSize = rom.Length;
            if (tracing) StopTrace();
            try
            {
                int first = Math.Max(0, start) & ~0xFF, end = Math.Min(romSize, start + Math.Max(1, length));
                for (int off = first; off < end; off += 0x1000)
                {
                    int len = Math.Min(0x1000, end - off);
                    int blocks = (len + 255) / 256;
                    int addr = Base + off;
                    var cmd = new byte[5 + blocks * 256];
                    cmd[0] = (byte)'Z'; cmd[1] = (byte)'W'; cmd[2] = (byte)blocks;
                    cmd[3] = (byte)(addr >> 16); cmd[4] = (byte)(addr >> 8);
                    int avail = Math.Min(blocks * 256, romSize - off);
                    Array.Copy(rom, off, cmd, 5, avail);
                    for (int i = 5 + avail; i < cmd.Length; i++) cmd[i] = 0xFF;
                    Send(cmd);
                    var ok = Read(1);
                    if (ok[0] != 'O')
                        throw new IOException($"upload refused at {addr:X5} (answer {ok[0]:X2}). " +
                                              "Check the emulation base in Settings > Hit trace & emulator: it is where ECU address 0 sits in the " +
                                              "emulator (0x78000 for a 32 KB image in an Ostrich 2.0).");
                    BytesUploaded += blocks * 256;
                    progress?.Invoke((off + len - first) / (double)Math.Max(1, end - first));
                }
                LastUpload = DateTime.Now;
            }
            finally
            {
                if (tracing) StartTrace(romSize, _lastNonRedundant);
            }
        }
    }

    /// Read the image back out of the emulator ('Z' 'R' blocks MMSB MSB -> data, then 'O').
    public byte[] Download(int size, Action<double>? progress = null)
    {
        lock (_io)
        {
            if (_port == null) throw new InvalidOperationException("the emulator is not connected");
            bool tracing = Tracing;
            if (tracing) StopTrace();
            try
            {
                var rom = new byte[size];
                for (int off = 0; off < size; off += 0x1000)
                {
                    int len = Math.Min(0x1000, size - off);
                    int blocks = (len + 255) / 256;
                    int addr = Base + off;
                    _port.DiscardInBuffer();
                    Send((byte)'Z', (byte)'R', (byte)blocks, (byte)(addr >> 16), (byte)(addr >> 8));
                    var data = Read(blocks * 256);
                    var ok = Read(1);
                    if (ok[0] != 'O') throw new IOException($"download refused at {addr:X5} (answer {ok[0]:X2})");
                    Array.Copy(data, 0, rom, off, len);
                    progress?.Invoke((off + len) / (double)size);
                }
                return rom;
            }
            finally
            {
                if (tracing) StartTrace(size, _lastNonRedundant);
            }
        }
    }

    /// Read the image back and compare it with what should be there: how many bytes differ and where the first one is.
    public (int Differences, int FirstAt) Validate(byte[] rom, Action<double>? progress = null)
    {
        var there = Download(rom.Length, progress);
        int diff = 0, first = -1;
        for (int i = 0; i < rom.Length; i++)
            if (there[i] != rom[i]) { diff++; if (first < 0) first = i; }
        return (diff, first);
    }

    bool _lastNonRedundant = true;

    /// Start streaming address hits. nonRedundant drops repeats of the same address in a row.
    public void StartTrace(int romSize, bool nonRedundant)
    {
        if (_port == null) throw new InvalidOperationException("not connected");
        _lastNonRedundant = nonRedundant;
        StopTrace();
        _port.DiscardInBuffer();
        int s = Base, e = Base + romSize - 1;
        byte x1 = (byte)(0x02 | (nonRedundant ? 0x04 : 0));     // B0=0 streaming, B1 windowed, B2 non-redundant, B6-7=0: 3-byte addresses
        Send((byte)'T', x1, 0, 0, 20, 0,
             (byte)(s >> 16), (byte)(s >> 8), (byte)s, (byte)(e >> 16), (byte)(e >> 8), (byte)e);
        var ack = Read(1);
        if (ack[0] != 'O') throw new IOException($"trace not accepted (answer {ack[0]:X2}); the Trace command needs an Ostrich 2.0 or a Demon");
        _stop = false;
        Hits = 0;
        _thread = new Thread(() => Run(romSize)) { IsBackground = true, Name = "moates-trace" };
        _thread.Start();
    }

    void Run(int romSize)
    {
        var buf = new byte[3];
        var port = _port!;
        port.ReadTimeout = 200;
        int got = 0;
        while (!_stop)
        {
            try
            {
                got += port.Read(buf, got, 3 - got);
                if (got < 3) continue;
                got = 0;
                int addr = buf[0] << 16 | buf[1] << 8 | buf[2];
                int ecu = (addr - Base) & (romSize - 1);
                Hits++;
                Hit?.Invoke(ecu);
            }
            catch (TimeoutException) { }
            catch (Exception ex) { Status?.Invoke("trace stopped: " + ex.Message); break; }
        }
    }

    public void StopTrace()
    {
        if (_thread == null) return;
        _stop = true;
        _thread.Join(600);
        _thread = null;
        try
        {
            _port?.Write(new[] { (byte)'t' }, 0, 1);        // soft stop; the device answers 'O'
            Thread.Sleep(50);
            _port?.DiscardInBuffer();
        }
        catch { }
    }

    public void Close()
    {
        StopTrace();
        try { _port?.Close(); _port?.Dispose(); } catch { }
        _port = null;
        Version = "";
    }

    public void Dispose() => Close();
}
