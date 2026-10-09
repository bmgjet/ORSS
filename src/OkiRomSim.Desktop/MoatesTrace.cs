// Copyright (c) bmgjet. All rights reserved.
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

/// The ROM emulator in the ECU's socket: identify the device, upload the ROM image, read it back, and run its address-hit Trace, which reports every EPROM address the ECU fetches (code and data). Protocol from "Moates Hardware Protocols v19" and the Ostrich Address Tracer, matched against what the established tuning software actually sends, which differs from a plain reading of the document in three ways that each stop the link working: - 'V' 'V' (version) carries NO checksum: it is two bare bytes, and a third is taken as the start of the next command. Every other command is followed by an 8-bit additive checksum of its bytes. - the answer is three bytes: firmware major, minor, and a letter saying what the device is - 'O' Ostrich / ECU-Tamer / Moates1, 'D' Demon, 'C' an RTP or CobraRTP, '1' or '2' ROMulator. - the window a 32 KB image is written to is 8000-FFFF of the bank the device has been told to select ('B' 'R' 'R' resets the bank pointer, answering 00; 'B' 'S' 0 selects bank 0, answering 'O'), so the address bytes of a transfer are 00 80 and up - not the raw offset into the device's half megabyte. 'Z' 'W' n MMSB MSB data(n*256) + checksum -> 'O' writes; 'Z' 'R' n MMSB MSB + checksum answers with the data followed by the device's own additive checksum of it (not an 'O'). The Demon family frames the same two commands differently - 'Z' 'W' 16 then FOUR address bytes and always a whole 4096-byte block, with the address and the data scrambled together by the vendor byte chain (see VendorKey), and a read's answer scrambled from where the request's chain ended. Its checksums are of the bytes as they go over the wire, scrambled. 'T' x1 x2 x3 y1 y2 sMMSB sMSB sLSB eMMSB eMSB eLSB -> 'O', then 3-byte hit addresses; any byte sent while tracing stops it (answered with 'O'). A pause between writing a command and reading its answer matters on several USB-serial cables, so one is configurable in Settings.
public sealed class MoatesTrace : IDisposable
{
    SerialPort? _port;
    Thread? _thread;
    volatile bool _stop;
    public string Version { get; private set; } = "";
    public bool Connected => _port?.IsOpen == true;
    public bool Tracing => _thread?.IsAlive == true;
    /// Where ECU address 0 is in the addresses the Trace command reports (Settings > Emulator & datalog). The trace only: uploads and downloads always go to TransferBase.
    public int Base { get; set; } = 0x8000;
    /// Where uploads and downloads put a 32 KB image: 8000-FFFF of the bank chosen when the link was opened, with the top address byte 00 - exactly what the established tuning software sends (Ostrich 'ZW' 10 00 80.., Demon 'ZW' 10 00 00 00 80..). Writing through the trace base instead (78000 is a common setting there) put the ROM somewhere the ECU does not run from and a download does not read, so it came back blank.
    public const int TransferBase = 0x8000;
    /// Which device this is, as the user set it in Settings ("auto", "Ostrich", "Demon", "ROMulator", "PGMFI RTP", "CobraRTP", "ECU-Tamer", "Moates1").
    public string Kind { get; set; } = "auto";
    /// What the device answered to the version query, once it has been identified.
    public string Device { get; private set; } = "";
    /// Baud rate. The Ostrich family speaks 115200 or 921600; a PGMFI RTP speaks 38400.
    public int Baud { get; set; } = 921600;
    /// A pause between writing a command and reading its answer. Some USB-serial cables need it.
    public int PostWritePauseMs { get; set; } = 10;
    public int TimeoutMs { get; set; } = 400;
    public int Retries { get; set; } = 3;

    /// The devices Settings offers, with the baud rates and the byte their version query answers with.
    public static readonly string[] Kinds = { "auto", "Ostrich", "Demon", "ROMulator", "PGMFI RTP", "CobraRTP", "ECU-Tamer", "Moates1" };
    public long Hits;
    /// ECU address hit, on the trace thread.
    public event Action<int>? Hit;
    public event Action<string>? Status;

    public static string[] Ports() => SerialLink.Ports();
    public string PortName => _port?.PortName ?? "";
    /// Goes up by one each time the link is made (so a new connection can be told from the one before).
    public int Connections { get; private set; }
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
        // the baud rates the devices accept; a PGMFI RTP is the odd one out at 38400
        int baud = Baud > 0 ? Baud : 921600;
        if (Kind == "PGMFI RTP") baud = 38400;
        _port = new SerialPort(portName, baud, Parity.None, 8, StopBits.One)
        {
            ReadTimeout = Math.Max(50, TimeoutMs), WriteTimeout = 1000, Handshake = Handshake.None,
            // the tuning software asks for a buffer this size, and a 4 KB block needs the room
            ReadBufferSize = 8192, WriteBufferSize = 8192, Encoding = System.Text.Encoding.Latin1,
        };
        _port.Open();
        Drain();
        string? why = null;
        for (int attempt = 0; attempt <= Math.Max(0, Retries); attempt++)
        {
            try
            {
                // the version query carries no checksum: it is two bare bytes, and an extra byte after them is taken as the start of the next command
                SendRaw((byte)'V', (byte)'V');
                Pause();
                var v = Read(3);
                if (Identify(v, out var name)) { Version = $"{name} {v[0]}.{v[1]}"; Device = name; Connections++; break; }
                why = $"answered {v[0]:X2} {v[1]:X2} {v[2]:X2} to the version query; its third byte should say which device it is" +
                      (Kind == "auto" ? "" : $", and {Kind} was asked for in Settings");
            }
            catch (TimeoutException) { why = "no answer to the version query"; }
            Drain();
            if (attempt == Math.Max(0, Retries)) throw new IOException(
                $"no emulator answered on {portName} at {baud} baud: {why}. " +
                "Check the port, and that the baud rate in Settings > Emulator & datalog matches the device (115200 or 921600 for an Ostrich).");
        }
        // the banks, the way the established tuning software sets them up on each device:
        //   Ostrich family: BRR asks the read/write bank (00 = bank 0, all is well); anything else, BS 0 (answers 'O')
        //   Demon:          BRR the same, and BR 0 when it is not 0 (answers 'O'); then BER and BES, which answer 01
        //                   on a Demon that is set up to emulate (never BS 0 - the Demon has no business with it)
        if (Device is "Ostrich" or "ECU-Tamer" or "CobraRTP")
        {
            if (!Command("bank read", [(byte)'B', (byte)'R', (byte)'R'], 0x00, soft: true))
                Command("bank select", [(byte)'B', (byte)'S', 0x00], (byte)'O', soft: true);
        }
        else if (Device == "Demon")
        {
            if (!Command("bank read", [(byte)'B', (byte)'R', (byte)'R'], 0x00, soft: true))
                Command("bank set", [(byte)'B', (byte)'R', 0x00], (byte)'O', soft: true);
            Command("emulation bank", [(byte)'B', (byte)'E', (byte)'R'], 0x01, soft: true);
            Command("emulation bank set", [(byte)'B', (byte)'E', (byte)'S'], 0x01, soft: true);
        }
        OkiRomSim.Core.AppLog.Write(OkiRomSim.Core.LogKind.Serial, "emulator", $"connected {Version} on {portName} at {baud} baud");
        return Version;
    }

    /// True for the devices whose bulk transfers carry a scrambled payload (the Demon family).
    bool Scrambled => Device is "Demon" or "RTP";

    /// How much one read or write moves: the fast bulk transfer where the device has it - 4 KB (an Ostrich 2, the Demon family, which only takes whole 4 KB blocks), 2 KB on an ECU-Tamer - and one 256-byte block on the first Moates emulator, which does not (as HTS-master does it).
    int Chunk => Scrambled ? 0x1000 : Kind switch { "ECU-Tamer" => 0x800, "Moates1" => 0x100, _ => 0x1000 };

    /// The 8-byte vendor key the Demon family scrambles a bulk transfer with, and the starting value of the chain, both exactly as the established tuning software has them. The transform is a byte chain, not a cipher: each byte is XORed with the previous *scrambled* byte, then alternately added to and XORed with the eight key bytes. It exists so a transfer only works with the vendor's own tool; there is nothing secret in it, and it is reproduced here purely so this program can talk to a device somebody already owns.
    static readonly byte[] VendorKey = { 0x0F, 0xFC, 0xCE, 0x2C, 0xA3, 0x9F, 0x65, 0x99 };

    static byte ChainStart()
    {
        byte b = 90;                          // 'Z', the value the vendor tool starts from
        foreach (var k in VendorKey) b += k;
        return b;
    }

    /// Scramble buf[from..to) in place and return the last scrambled byte, which is the value the device carries on the chain with (so it is also the starting value for unscrambling the answer).
    static byte Scramble(byte[] buf, int from, int to)
    {
        byte prev = ChainStart();
        for (int i = from; i < to; i++)
        {
            byte v = (byte)(buf[i] ^ prev);
            for (int j = 0; j <= 7; j++) v = (j % 2 == 0) ? (byte)(v + VendorKey[j]) : (byte)(v ^ VendorKey[j]);
            buf[i] = v;
            prev = v;
        }
        return prev;
    }

    /// The inverse, over the data the device sent back. `chain` is what Scramble returned for the request header.
    static void Unscramble(byte chain, byte[] buf, int from, int to)
    {
        byte prev = chain;
        for (int i = from; i < to; i++)
        {
            byte cipher = buf[i];
            byte v = cipher;
            for (int j = 7; j >= 0; j--) v = (j % 2 == 0) ? (byte)(v - VendorKey[j]) : (byte)(v ^ VendorKey[j]);
            buf[i] = (byte)(v ^ prev);
            prev = cipher;
        }
    }

    /// The third byte of the version answer says what the device is; the first two are its firmware version.
    bool Identify(byte[] v, out string name)
    {
        name = "";
        if (v.Length < 3) return false;
        switch (v[2])
        {
            case (byte)'O':
                // an Ostrich says how big it is in the first byte: 10 for a 1.0, 20 for a 2.0
                name = Kind is "ECU-Tamer" or "Moates1" ? Kind : "Ostrich";
                if (Kind is not ("auto" or "Ostrich" or "ECU-Tamer" or "Moates1")) return false;
                return true;
            case (byte)'D': name = "Demon"; return Kind is "auto" or "Demon";
            case (byte)'C': name = Kind == "CobraRTP" ? "CobraRTP" : "RTP"; return Kind is "auto" or "CobraRTP" or "Demon";
            case (byte)'1' or (byte)'2': name = "ROMulator"; return Kind is "auto" or "ROMulator";
            default: return false;
        }
    }

    /// A short command with its checksum, checking the byte it answers with. `soft` logs a wrong answer instead of throwing (the bank commands are not on every device).
    bool Command(string what, byte[] bytes, byte expect, bool soft = false)
    {
        try
        {
            Drain();
            Send(bytes);
            Pause();
            var a = Read(1);
            if (a[0] == expect) return true;
            if (!soft) throw new IOException($"{what} refused (answer {a[0]:X2}, expected {expect:X2})");
            OkiRomSim.Core.AppLog.Warn("emulator", $"{what}: answer {a[0]:X2}, expected {expect:X2} - carrying on");
        }
        catch (TimeoutException)
        {
            if (!soft) throw new IOException($"{what}: no answer");
            OkiRomSim.Core.AppLog.Warn("emulator", what + ": no answer - carrying on");
        }
        return false;
    }

    /// Every command but the version query is followed by an 8-bit additive checksum of its bytes.
    void Send(params byte[] bytes)
    {
        var buf = new byte[bytes.Length + 1];
        Array.Copy(bytes, buf, bytes.Length);
        buf[^1] = Sum(bytes, bytes.Length);
        _port!.Write(buf, 0, buf.Length);
    }

    /// Bytes exactly as given, with nothing added (the version query).
    void SendRaw(params byte[] bytes) => _port!.Write(bytes, 0, bytes.Length);

    static byte Sum(byte[] data, int count)
    {
        byte s = 0;
        for (int i = 0; i < count; i++) s += data[i];
        return s;
    }

    /// The tuning software waits a moment between writing a command and reading its answer; some USB-serial cables lose the first byte without it.
    void Pause()
    {
        if (PostWritePauseMs > 0) Thread.Sleep(PostWritePauseMs);
    }

    void Drain()
    {
        try { _port?.DiscardInBuffer(); _port?.DiscardOutBuffer(); } catch { }
    }

    byte[] Read(int n)
    {
        var buf = new byte[n];
        int got = 0;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        // SerialPort.Read comes back with whatever has arrived, so a block is gathered in pieces
        while (got < n)
        {
            if (sw.ElapsedMilliseconds > Math.Max(500, TimeoutMs * 4)) throw new TimeoutException($"only {got} of {n} bytes arrived");
            int r = _port!.Read(buf, got, n - got);
            if (r <= 0) break;
            got += r;
        }
        if (got < n) throw new TimeoutException($"only {got} of {n} bytes arrived");
        return buf;
    }

    // ---- the port shared with the datalog (a Demon logs the ECU over the same cable)

    /// The emulator's port kept for one exchange: an upload waits until it is let go, and the other way round.
    public IDisposable Hold()
    {
        Monitor.Enter(_io);
        return new Release(_io);
    }

    sealed class Release(object io) : IDisposable
    {
        int _done;
        public void Dispose() { if (Interlocked.Exchange(ref _done, 1) == 0) Monitor.Exit(io); }
    }

    /// Bytes to the device as they are (the datalog's own framing).
    public void LineWrite(byte[] data)
    {
        lock (_io)
        {
            if (_port == null) throw new IOException("the emulator is not connected");
            if (Tracing) StopTrace();
            _port.Write(data, 0, data.Length);
        }
    }

    /// Whatever arrives within `timeoutMs`, up to `count` bytes; 0 when nothing does.
    public int LineRead(byte[] buffer, int offset, int count, int timeoutMs)
    {
        lock (_io)
        {
            if (_port == null) return 0;
            try { _port.ReadTimeout = Math.Max(1, timeoutMs); return _port.Read(buffer, offset, count); }
            catch (TimeoutException) { return 0; }
            catch (InvalidOperationException) { return 0; }
            catch (IOException) { return 0; }
            finally { try { _port.ReadTimeout = Math.Max(50, TimeoutMs); } catch { } }
        }
    }

    public void LineDiscard() { lock (_io) try { _port?.DiscardInBuffer(); } catch { } }

    /// Upload a ROM image to the top of the 64 KB emulation space (32 KB -> 8000-FFFF).
    public void Upload(byte[] rom, Action<double>? progress = null) => WriteRange(rom, 0, rom.Length, progress);

    /// Write part of the image: the blocks covering [start, start+length), at TransferBase + the offset (8000-FFFF, top address byte 00, as the established tuning software writes). Used for uploading calibration edits as they are made. A running trace is paused around it.
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
                // the Demon family only takes whole 4 KB blocks, so a partial write (uploading the one block a calibration edit touched) is rounded out to cover it
                int grain = Scrambled ? 0x1000 : 0x100;
                int first = Math.Max(0, start) & ~(grain - 1), end = Math.Min(romSize, start + Math.Max(1, length));
                if (Scrambled) end = Math.Min(romSize, (end + 0xFFF) & ~0xFFF);
                for (int off = first; off < end; off += Chunk)
                {
                    int len = Math.Min(Chunk, end - off);
                    int blocks = Scrambled ? 16 : (len + 255) / 256;
                    int addr = TransferBase + off;
                    var cmd = Scrambled ? DemonWriteFrame(rom, off, romSize, addr) : new byte[5 + (blocks * 256)];
                    if (!Scrambled)
                    {
                        cmd[0] = (byte)'Z'; cmd[1] = (byte)'W'; cmd[2] = (byte)blocks;
                        cmd[3] = (byte)(addr >> 16); cmd[4] = (byte)(addr >> 8);
                        int avail = Math.Min(blocks * 256, romSize - off);
                        Array.Copy(rom, off, cmd, 5, avail);
                        for (int i = 5 + avail; i < cmd.Length; i++) cmd[i] = 0xFF;
                    }
                    byte answer = 0;
                    for (int attempt = 0; ; attempt++)
                    {
                        try
                        {
                            Drain();
                            Send(cmd);
                            Pause();
                            answer = Read(1)[0];
                            if (answer == 'O') break;
                        }
                        catch (TimeoutException) { answer = 0; }
                        if (attempt >= Math.Max(0, Retries))
                            throw new IOException($"upload refused at {addr:X5} (answer {answer:X2}): check the device picked in Settings, and its baud rate");
                        OkiRomSim.Core.AppLog.Warn("emulator", $"upload at {addr:X5} answered {answer:X2}; retrying");
                    }
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

    /// A Demon bulk-write frame: 'Z' 'W' 16, four address bytes, 4096 data bytes, then an additive checksum of everything before it. The address bytes and the data are scrambled together as one run (the vendor tool leaves the first three bytes in the clear so the device can see what command it is), and the checksum is taken over the frame as it goes out.
    byte[] DemonWriteFrame(byte[] rom, int off, int romSize, int addr)
    {
        var cmd = new byte[4104];
        cmd[0] = (byte)'Z'; cmd[1] = (byte)'W'; cmd[2] = 16;
        cmd[3] = 0; cmd[4] = 0;
        cmd[5] = (byte)(addr >> 16); cmd[6] = (byte)(addr >> 8);
        int avail = Math.Clamp(romSize - off, 0, 4096);
        Array.Copy(rom, off, cmd, 7, avail);
        for (int i = 7 + avail; i < 4103; i++) cmd[i] = 0xFF;
        Scramble(cmd, 3, 4103);
        cmd[4103] = Sum(cmd, 4103);
        return cmd;
    }

    /// Read the image back out of the emulator: 'Z' 'R' blocks MMSB MSB + checksum, and the device answers with the data followed by its own 8-bit additive checksum of that data. (It does not answer 'O' the way a write does, and waiting for one was why Download never came back.)
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
                for (int off = 0; off < size; off += Chunk)
                {
                    int len = Math.Min(Chunk, size - off);
                    int blocks = Scrambled ? 16 : (len + 255) / 256;
                    int addr = TransferBase + off;
                    byte[] data;
                    for (int attempt = 0; ; attempt++)
                    {
                        try
                        {
                            Drain();
                            byte chain = 0;
                            if (Scrambled)
                            {
                                // 'Z' 'R' 16, four address bytes scrambled, then the checksum; the chain value the header ends on is what the answer is scrambled from
                                var req = new byte[8];
                                req[0] = (byte)'Z'; req[1] = (byte)'R'; req[2] = 16;
                                req[3] = 0; req[4] = 0;
                                req[5] = (byte)(addr >> 16); req[6] = (byte)(addr >> 8);
                                chain = Scramble(req, 3, 7);
                                req[7] = Sum(req, 7);
                                _port.Write(req, 0, req.Length);
                            }
                            else Send((byte)'Z', (byte)'R', (byte)blocks, (byte)(addr >> 16), (byte)(addr >> 8));
                            Pause();
                            data = Read(blocks * 256);
                            byte theirs = Read(1)[0];
                            // the checksum is of the bytes as they arrived, before unscrambling
                            if (theirs == Sum(data, data.Length))
                            {
                                if (Scrambled) Unscramble(chain, data, 0, data.Length);
                                break;
                            }
                            if (attempt >= Math.Max(0, Retries))
                                throw new IOException($"download from {addr:X5} came back with a bad checksum ({theirs:X2})");
                        }
                        catch (TimeoutException ex)
                        {
                            if (attempt >= Math.Max(0, Retries)) throw new IOException($"download from {addr:X5} timed out: {ex.Message}");
                        }
                        OkiRomSim.Core.AppLog.Warn("emulator", $"download at {addr:X5} failed; retrying");
                    }
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
                int addr = (buf[0] << 16) | (buf[1] << 8) | buf[2];
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

    /// Let the port go: after anything using it (an upload, a datalog exchange) has finished, so nothing writes to a port that is half closed.
    public void Close()
    {
        lock (_io)
        {
            StopTrace();
            var port = _port;
            _port = null;
            Version = "";
            if (port == null) return;
            try { port.DiscardInBuffer(); port.DiscardOutBuffer(); } catch { }
            try { port.Close(); } catch { }
            try { port.Dispose(); } catch { }
            OkiRomSim.Core.AppLog.Write(OkiRomSim.Core.LogKind.Serial, "emulator", "port closed");
        }
    }

    public void Dispose() => Close();
}
