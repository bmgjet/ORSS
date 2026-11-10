// Copyright (c) bmgjet. All rights reserved.
extern alias tuner;
using System.Runtime.InteropServices;
using OkiRomSim.Calibration;
using OkiRomSim.Core;
using Moates = tuner::OkiRomSim.Desktop.MoatesTrace;
using TunerHost = tuner::OkiRomSim.Desktop.RomHost;

namespace OkiRomSim.Tests;

/// The ROM emulator link and the upload interlock, against a mock device on a pseudo-terminal - no hardware is touched. The mock answers
/// the way MoatesTrace says an Ostrich 2.0 does (its protocol notes); it shows the program keeps to that protocol and to its own rules
/// (never write into a ROM it has not matched, never send a blank image, wait long enough for an answer), not that a real device
/// behaves like the mock. That needs a bench test with the device.
static class EmulatorTests
{
    public static void Run()
    {
        if (OperatingSystem.IsWindows())
        {
            T.Skip("the emulator tests", "they need a pseudo-terminal (Linux or macOS); on Windows a virtual serial pair such as com0com would stand in");
            return;
        }
        T.P30Part();
        Identify();
        Transfers();
        Interlock();
        T.P30Part();
    }

    static Moates Link(int timeoutMs = 400, int retries = 0) =>
        new() { Kind = "auto", Baud = 115200, TimeoutMs = timeoutMs, Retries = retries, PostWritePauseMs = 2 };

    static void Identify()
    {
        using (var m = new MockOstrich())
        using (var t = Link())
        {
            string v = ""; Exception? err = null;
            try { v = t.Connect(m.PortName); } catch (Exception ex) { err = ex; }
            T.Check("an Ostrich answering 'V' 'V' is identified, and its bank is asked for", err == null && t.Connected && t.Device == "Ostrich" && m.BankQueries == 1,
                err?.Message ?? $"{v}, bank queries {m.BankQueries}");
        }
        using (var m = new MockOstrich { IdentifyAs = (byte)'X' })
        using (var t = Link())
        {
            Exception? err = null;
            try { t.Connect(m.PortName); } catch (Exception ex) { err = ex; }
            T.Check("a device that does not identify is refused, and the port is closed again (it was left open)", err is IOException && !t.Connected && t.Device == "",
                err?.Message ?? "connected");
        }
    }

    static void Transfers()
    {
        var image = File.ReadAllBytes(T.Roms("p30.bin"));
        using (var m = new MockOstrich())
        using (var t = Link())
        {
            t.Connect(m.PortName);
            t.Upload(image);
            T.Check("Upload writes the whole image in 4 KB frames, each once, to 8000h-FFFFh", m.Snapshot().AsSpan().SequenceEqual(image) && m.FramesWritten == 8 && m.BadFrames == 0,
                $"{m.FramesWritten} frames, {m.BadFrames} bad");
            var (diff, first) = t.Validate(image);
            T.Check("Validate reads it back and finds it the same", diff == 0 && first == -1, $"{diff} differ");
            m.Poke(0x1234, (byte)(image[0x1234] ^ 0x5A));
            (diff, first) = t.Validate(image);
            T.Check("... and finds one changed byte where it is", diff == 1 && first == 0x1234, $"{diff} differ, first at {first:X4}");
            int before = m.FramesWritten;
            t.WriteRange(image, 0x1234, 1);
            T.Check("WriteRange sends just the 256-byte block holding the change", m.FramesWritten == before + 1 && m.LastFrameBytes == 256 && m.Snapshot().AsSpan().SequenceEqual(image),
                $"{m.FramesWritten - before} frame(s) of {m.LastFrameBytes} bytes");
        }
        // an answer that comes after the usual timeout but inside the time the frame takes on the wire at 115200 baud (a 4 KB frame:
        // 357 ms): with no retries allowed, waiting only the usual timeout failed the upload, and with retries it cut the frame off
        using (var m = new MockOstrich { AckDelayMs = 600 })
        using (var t = Link(timeoutMs: 400, retries: 0))
        {
            t.Connect(m.PortName);
            Exception? err = null;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            try { t.WriteRange(image, 0, 0x1000); } catch (Exception ex) { err = ex; }
            T.Check("a 4 KB frame answered 600 ms later (timeout 400 ms) is waited for: the wait covers the frame's time on the wire",
                err == null && m.FramesWritten == 1 && m.Snapshot().AsSpan(0, 0x1000).SequenceEqual(image.AsSpan(0, 0x1000)),
                err?.Message ?? $"{sw.ElapsedMilliseconds} ms, {m.FramesWritten} frame(s)");
        }
    }

    /// The rules RomHost keeps around the emulator (the same class in both programs; this is the tuner's build of it).
    static void Interlock()
    {
        T.P30Part();
        var sk = Skeleton.Load(T.Roms("p30-skeleton.asm"), anyPlatform: true);
        var built = sk.Build([]);
        if (!T.Check("the P30 skeleton builds for the interlock tests", built.Success && built.Assembly != null)) return;
        var image = built.Assembly!.Image;
        using var s = T.NewScratch("emulator");
        var romPath = s.File("p30-skeleton.bin");
        File.WriteAllBytes(romPath, image);

        using (var m = new MockOstrich())
        {
            m.Load(image);                                      // the emulator holds this very ROM
            var host = new TunerHost();
            Configure(host.Emulator);
            host.LoadImage(image, built.Assembly, romPath);
            var item = host.Defs().Items.FirstOrDefault(i => i.IsTable && i.Count > 0 && i.ElementSize == 1 && i.CellAddress(0) is >= 0 and < 0x8000);
            if (!T.Check("the skeleton has a table to edit", item != null)) return;
            byte Raw(int k) => (byte)host.ReadItem(item!)[k].Raw;
            void Nudge(int k) => host.WriteCells(item!, [(k, Raw(k) < 0xFF ? Raw(k) + 1 : Raw(k) - 1)], raw: true, "test");

            host.EmulatorConnect(m.PortName);
            host.AutoUpload = true;
            T.Check("just connected, the emulator is not taken to hold this ROM", !host.EmulatorInSync);
            Nudge(0);
            Thread.Sleep(700);
            T.Check("an edit made before the emulator was compared is not sent into it", m.FramesWritten == 0, $"{m.FramesWritten} frame(s)");
            host.Undo();
            var (diff, _) = host.EmulatorCompare();
            T.Check("compared and found the same, it is in sync", diff == 0 && host.EmulatorInSync, $"{diff} differ");
            Nudge(1);
            bool arrived = WaitFor(() => m.Snapshot().AsSpan().SequenceEqual(host.RomCopy()), 4000);
            T.Check("an edit made in sync goes up on its own, and the emulator then holds exactly the ROM here (the checksum byte too)", arrived,
                $"{m.FramesWritten} frame(s)");

            // the emulator now holds something else (another tool wrote to it); the user keeps it
            m.Poke(0x0100, (byte)(m.Snapshot()[0x0100] ^ 0xFF));
            host.EmulatorValidate();
            T.Check("Validate finds the emulator holding something else", host.LastDifferences == 1, $"{host.LastDifferences} differ");
            host.MarkEmulatorDiverged();
            int frames = m.FramesWritten;
            Nudge(2);
            Thread.Sleep(700);
            T.Check("kept by the user, the emulator's ROM gets none of the edits made here", m.FramesWritten == frames && !host.EmulatorInSync, $"{m.FramesWritten - frames} frame(s)");
            host.EmulatorUploadAll();
            T.Check("Upload sends the whole ROM; in sync again", host.EmulatorInSync && m.Snapshot().AsSpan().SequenceEqual(host.RomCopy()));

            // a rebuild replaces the image here: the emulator still holds the old one, so edits wait for a full upload
            var other = (byte[])image.Clone();
            other[0x7000] ^= 0x01;
            other[0x7FFF] ^= 0x01;                          // (any different image will do; its sum is not the point here)
            host.LoadImage(other, built.Assembly, romPath);
            T.Check("a new image here (a rebuild) leaves the emulator out of sync", !host.EmulatorInSync, host.EmulatorStatus);
            frames = m.FramesWritten;
            Nudge(3);
            Thread.Sleep(700);
            T.Check("... and the next edit is not spliced into the old image in the emulator", m.FramesWritten == frames, $"{m.FramesWritten - frames} frame(s)");
            host.EmulatorDisconnect();
            T.Check("disconnected, not in sync", !host.Emulator.Connected && !host.EmulatorInSync);
        }

        // nothing open, or a blank image: the emulator keeps what it has
        using (var m = new MockOstrich())
        {
            m.Load(image);
            var host = new TunerHost();
            Configure(host.Emulator);
            host.EmulatorConnect(m.PortName);
            T.Check("with nothing open, uploading is refused", !host.CanUpload(out var why) && why.Length > 0, why);
            T.Throws<InvalidOperationException>("... and Upload throws rather than sending anything", () => host.EmulatorUploadAll());
            var blank = new byte[Chip.RomSize];
            Array.Fill(blank, (byte)0xFF);
            host.LoadImage(blank, null, s.File("blank.bin"));
            T.Throws<InvalidOperationException>("a blank (all FFh) image is never uploaded", () => host.EmulatorUploadAll());
            T.Check("... and the emulator still holds its ROM, untouched", m.FramesWritten == 0 && m.Snapshot().AsSpan().SequenceEqual(image));
            host.EmulatorDisconnect();
        }

        // datalogging "through the emulator" with an Ostrich in the socket: refused before a byte goes to it - only a Demon asks the ECU
        // itself, and its set-up and fetch commands would land in the Ostrich's command stream, between the uploads
        using (var m = new MockOstrich())
        {
            m.Load(image);
            var host = new TunerHost();
            Configure(host.Emulator);
            host.LoadImage(image, built.Assembly, romPath);
            host.EmulatorConnect(m.PortName);
            int before = m.Unrecognised;
            using var engine = new tuner::OkiRomSim.Desktop.DatalogEngine(host);
            Exception? err = null;
            try { engine.Start("emulator", "auto", 38400); } catch (Exception ex) { err = ex; }
            Thread.Sleep(300);
            T.Check("datalogging through an Ostrich is refused, and nothing is sent into its command stream (only a Demon asks the ECU)",
                err is IOException && err.Message.Contains("cannot datalog") && m.Unrecognised == before && m.FramesWritten == 0, err?.Message ?? "it started");
            host.EmulatorDisconnect();
        }

        // a definitions file beside the ROM that cannot be read: the ROM opens without it, the same way every time
        {
            var bin = s.File("broken.bin");
            File.WriteAllBytes(bin, image);
            File.WriteAllText(s.File("broken.okidef.json"), "{ this is not json");
            var host = new TunerHost();
            host.LoadImage(image, null, bin);
            DefinitionSet? d1 = null, d2 = null; Exception? err = null;
            try { d1 = host.Defs(); d2 = host.Defs(); } catch (Exception ex) { err = ex; }
            T.Check("an unreadable definitions file beside a ROM: it opens without it (no exception), with the built-in formulas, the same every time",
                err == null && d1 != null && ReferenceEquals(d1, d2) && d1.Formulas.Count > 0, err?.Message ?? $"{d1!.Formulas.Count} formulas");
        }

        // NaN typed into a cell: nothing written (the RomHost edit path)
        {
            var host = new TunerHost();
            host.LoadImage(image, built.Assembly, romPath);
            var item = host.Defs().Items.First(i => i.IsTable && i.Count > 0 && i.ElementSize == 1);
            var before = host.RomCopy();
            try { host.WriteCells(item, [(0, double.NaN)], raw: true, "test"); } catch { }
            T.Check("a NaN written to a cell changes no byte", host.RomCopy().AsSpan().SequenceEqual(before));
        }
    }

    static void Configure(Moates e)
    {
        e.Kind = "auto"; e.Baud = 115200; e.TimeoutMs = 400; e.Retries = 1; e.PostWritePauseMs = 2;
    }

    static bool WaitFor(Func<bool> done, int ms)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < ms) { if (done()) return true; Thread.Sleep(50); }
        return done();
    }
}

/// A mock Ostrich 2.0 on the far end of a pseudo-terminal: what MoatesTrace connects to is the terminal's other end (/dev/pts/N on
/// Linux, /dev/ttysNNN on macOS), a serial port as far as System.IO.Ports can tell. It holds 32 KB at 8000h-FFFFh of bank 0 and
/// answers, as MoatesTrace's protocol notes describe: 'V' 'V' (no checksum) -> major, minor, 'O'; 'B' 'R' 'R' + sum -> 00h;
/// 'Z' 'W' n MMSB MSB data + sum -> 'O' (after AckDelayMs); 'Z' 'R' n MMSB MSB + sum -> data + its sum; 't' -> 'O'.
sealed class MockOstrich : IDisposable
{
    public string PortName { get; }
    public byte IdentifyAs = (byte)'O';
    public int AckDelayMs;
    public int FramesWritten => Volatile.Read(ref _frames);
    public int BadFrames => Volatile.Read(ref _bad);
    public int BankQueries => Volatile.Read(ref _bank);
    /// Bytes that started no command this mock knows (another device's commands, sent to the wrong one).
    public int Unrecognised => Volatile.Read(ref _unknown);
    public int LastFrameBytes { get; private set; }

    readonly byte[] _memory = new byte[0x8000];
    readonly int _master;
    readonly Thread _thread;
    volatile bool _stop;
    int _frames, _bad, _bank, _unknown;
    readonly byte[] _buf = new byte[65536];
    int _have, _at;

    public MockOstrich()
    {
        if (!OperatingSystem.IsLinux() && !OperatingSystem.IsMacOS()) throw new PlatformNotSupportedException("a pseudo-terminal needs Linux or macOS");
        Array.Fill(_memory, (byte)0xFF);
        int flags = OperatingSystem.IsMacOS() ? 0x20002 : 0x102;        // O_RDWR | O_NOCTTY
        _master = posix_openpt(flags);
        if (_master < 0) throw new IOException($"posix_openpt failed ({Marshal.GetLastPInvokeError()})");
        if (grantpt(_master) != 0 || unlockpt(_master) != 0) throw new IOException($"grantpt/unlockpt failed ({Marshal.GetLastPInvokeError()})");
        PortName = Marshal.PtrToStringAnsi(ptsname(_master)) ?? throw new IOException("ptsname failed");
        _thread = new Thread(Serve) { IsBackground = true, Name = "mock-ostrich" };
        _thread.Start();
    }

    public void Load(byte[] image) { lock (_memory) Array.Copy(image, _memory, Math.Min(image.Length, _memory.Length)); }
    public void Poke(int offset, byte value) { lock (_memory) _memory[offset] = value; }
    public byte[] Snapshot() { lock (_memory) return [.. _memory]; }

    public void Dispose()
    {
        _stop = true;
        _thread.Join(2000);
        close(_master);
    }

    void Serve()
    {
        try
        {
            while (!_stop)
            {
                int b = Next();
                if (b < 0) return;
                switch (b)
                {
                    case 'V':
                        if (Next() == 'V') Send(0x14, 0x00, IdentifyAs);
                        break;
                    case 'B':
                        {
                            int b1 = Next(), b2 = Next(), sum = Next();
                            if (sum < 0) return;
                            bool ok = (byte)('B' + b1 + b2) == sum;
                            if (b1 == 'R' && b2 == 'R') { Interlocked.Increment(ref _bank); Send(ok ? (byte)0x00 : (byte)'X'); }
                            else Send(ok ? (byte)'O' : (byte)'X');
                            break;
                        }
                    case 'Z':
                        {
                            int kind = Next(), n = Next(), mm = Next(), m = Next();
                            if (m < 0) return;
                            int off = ((mm << 16) | (m << 8)) - 0x8000, len = n * 256;
                            if (kind == 'W')
                            {
                                var data = new byte[len];
                                for (int i = 0; i < len; i++) { int x = Next(); if (x < 0) return; data[i] = (byte)x; }
                                int sum = Next();
                                if (sum < 0) return;
                                byte mine = (byte)('Z' + 'W' + n + mm + m);
                                foreach (var x in data) mine += x;
                                if (mine != sum || off < 0 || off + len > _memory.Length) { Interlocked.Increment(ref _bad); Send((byte)'X'); break; }
                                lock (_memory) Array.Copy(data, 0, _memory, off, len);
                                LastFrameBytes = len;
                                Interlocked.Increment(ref _frames);
                                if (AckDelayMs > 0) Thread.Sleep(AckDelayMs);
                                Send((byte)'O');
                            }
                            else if (kind == 'R')
                            {
                                int sum = Next();
                                if (sum < 0) return;
                                if ((byte)('Z' + 'R' + n + mm + m) != sum || off < 0 || off + len > _memory.Length) { Interlocked.Increment(ref _bad); break; }
                                byte[] data;
                                lock (_memory) data = _memory[off..(off + len)];
                                byte s = 0;
                                foreach (var x in data) s += x;
                                Send([.. data, s]);
                            }
                            break;
                        }
                    case 't':
                        Send((byte)'O');
                        break;
                    default:
                        Interlocked.Increment(ref _unknown);
                        break;
                }
            }
        }
        catch (Exception ex) { Console.WriteLine("        mock device stopped: " + ex.Message); }
    }

    /// The next byte from the program, or -1 once stopped. Nobody on the other end (between connections) reads as a hang-up: waited out.
    int Next()
    {
        while (_at >= _have)
        {
            if (_stop) return -1;
            var fds = new[] { new PollFd { Fd = _master, Events = PollIn } };
            if (poll(fds, 1, 50) <= 0) continue;
            if ((fds[0].Revents & PollIn) == 0) { Thread.Sleep(20); continue; }
            nint n = read(_master, _buf, (nuint)_buf.Length);
            if (n <= 0) { Thread.Sleep(20); continue; }
            _have = (int)n; _at = 0;
        }
        return _buf[_at++];
    }

    void Send(params byte[] data)
    {
        int off = 0;
        while (off < data.Length && !_stop)
        {
            var rest = data[off..];
            nint n = write(_master, rest, (nuint)rest.Length);
            if (n > 0) off += (int)n; else Thread.Sleep(5);
        }
    }

    const short PollIn = 0x0001;

    [StructLayout(LayoutKind.Sequential)]
    struct PollFd { public int Fd; public short Events; public short Revents; }

    [DllImport("libc", SetLastError = true)] static extern int posix_openpt(int flags);
    [DllImport("libc", SetLastError = true)] static extern int grantpt(int fd);
    [DllImport("libc", SetLastError = true)] static extern int unlockpt(int fd);
    [DllImport("libc", SetLastError = true)] static extern IntPtr ptsname(int fd);
    [DllImport("libc", SetLastError = true)] static extern nint read(int fd, byte[] buf, nuint count);
    [DllImport("libc", SetLastError = true)] static extern nint write(int fd, byte[] buf, nuint count);
    [DllImport("libc", SetLastError = true)] static extern int close(int fd);
    [DllImport("libc", SetLastError = true)] static extern int poll([In, Out] PollFd[] fds, nuint nfds, int timeout);
}
