// Copyright (c) bmgjet. All rights reserved.
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using OkiRomSim.Calibration;
using OkiRomSim.Desktop;

namespace AlphaEmuPlugin;

/// Where the plugin is up to, as the UI reads it.
public enum AlphaLinkPhase { Off, Connecting, Linked, Logging, Reconnecting, Faulted }

/// Everything that talks to the emulator: the link and its reconnection, the datalog it feeds the app,
/// the analog inputs, and the real-time byte patches. Commands that take time (a slot write, a firmware
/// update) run on their own thread and report through the events; nothing here touches the UI directly.
public sealed class AlphaSession : IDisposable
{
    readonly PluginContext _app;
    public AlphaState State { get; }
    public AlphaWideband Wideband { get; } = new();

    IAlphaLink? _link;
    LinkSupervisor? _watch;
    Thread? _datalog, _analog, _realtime, _command;
    volatile bool _stop;
    volatile bool _opening;
    readonly object _gate = new();

    AlphaIdentity? _identity;
    byte[]? _baseline;                       // the ROM as the emulator has it: real-time patches are the difference to this
    volatile bool _patching;
    int _patchRetries;
    readonly List<string> _log = [];
    DateTime _dtcAt = DateTime.MinValue;
    // nothing read yet: no codes (a default tuple would hand the screens a null array)
    (int[] Codes, string Source) _dtcCache = ([], "");
    bool _dtcFetching;
    readonly object _dtcGate = new();
    DateTime _fwAt = DateTime.MinValue;
    string _fwCache = "";
    readonly object _fwGate = new();

    public AlphaLinkPhase Phase { get; private set; } = AlphaLinkPhase.Off;
    public string Status { get; private set; } = "not connected";
    public long Frames { get; private set; }
    public double FramesPerSecond { get; private set; }
    public DateTime? LastFrameAt { get; private set; }
    public long PatchBytesSent { get; private set; }
    public long PatchesSent { get; private set; }
    public long AnalogPolls { get; private set; }
    public bool RealtimeEnabled { get; set; }
    /// The stream is running and the console can trace it.
    public bool Streaming { get; private set; }
    /// The frames are also being handed to the app's Datalog page (the FeedDatalog setting, live).
    public bool FeedingDatalog { get; private set; }
    public bool Synced => _baseline != null;
    public AlphaIdentity? Identity => _identity;
    public LogFrame? Latest { get; private set; }

    /// Something changed that the screens should notice (any thread).
    public event Action? Changed;
    /// A datalog frame, after it has been fed to the app (any thread).
    public event Action<LogFrame>? FrameArrived;
    /// A line for the log pane and the app's Debug page (any thread).
    public event Action<string>? Logged;

    public AlphaSession(PluginContext app, AlphaState state)
    {
        _app = app;
        State = state;
        ApplyWideband();
    }

    // ---------------------------------------------------------------- the settings that the link needs

    /// Push the wideband settings from AlphaState into the model, and tell the built-in device how a
    /// wideband controller would turn an AFR back into volts.
    public void ApplyWideband()
    {
        Wideband.Profile = State.WidebandProfile;
        Wideband.Stoich = State.WidebandStoich;
        Wideband.Offset = State.WidebandOffset;
        Wideband.Custom = State.WidebandCustom;
        lock (_gate) if (_link is AlphaNextGenDevice d) d.AfrToVolts = a => Wideband.VoltsFor(a);
    }

    public string LinkName => State.Link switch
    {
        AlphaTransport.BuiltInDevice => "built-in ALPHA NextGEN",
        AlphaTransport.BluetoothBridge => $"Bluetooth bridge on {(State.Port.Length > 0 ? State.Port : "no port")}",
        _ => State.Port.Length > 0 ? State.Port : "no port chosen",
    };

    // ---------------------------------------------------------------- connect / disconnect

    public void Connect()
    {
        lock (_gate)
        {
            if (_link != null || _opening) return;
            _stop = false;
            _opening = true;
            Phase = AlphaLinkPhase.Connecting;
            Status = "connecting to " + LinkName + "…";
        }
        Raise();
        if (State.Link == AlphaTransport.BuiltInDevice) { FinishConnect(); return; }        // instant: keep it on the caller's thread
        new Thread(FinishConnect) { IsBackground = true, Name = "alpha connect" }.Start();  // a port open and an identity read can take seconds
    }

    /// Opens and installs a link. On the UI thread for the built-in device, on a worker for anything
    /// with a port behind it; a Disconnect that lands while the port is opening cancels it.
    void FinishConnect()
    {
        IAlphaLink? link = null;
        bool installed = false;
        try
        {
            lock (_gate) if (_stop) { _opening = false; throw new IOException("the connect was cancelled"); }
            link = Open();
            link.Traffic += line => Note(line);
            link.Open();
            lock (_gate)
            {
                if (_stop)                                        // disconnected while the port was opening
                {
                    _opening = false;
                    Phase = AlphaLinkPhase.Off;
                    Status = "not connected";
                    throw new IOException("the connect was cancelled");
                }
                _watch?.Dispose();                                // a second Connect must not leave the first watch watching too
                _watch = null;
                _link = link;
                installed = true;
            }
            ReadIdentity();
            Phase = AlphaLinkPhase.Linked;
            Status = $"linked to {_identity?.Kind ?? "ALPHAemu"} ({_identity?.DeviceId ?? "?"}) - {_identity?.Firmware}";
            _watch = new LinkSupervisor("ALPHAemu", Probe, () => Reconnect());
            LinkSupervisor.Attempts = Math.Max(1, State.ReconnectAttempts);
            LinkSupervisor.DelayMs = Math.Max(200, State.ReconnectDelayMs);
            _watch.Wanted = true;
            _watch.Message += m => { Status = m; Raise(); };
            lock (_gate) _opening = false;
            Note(Status);
            StartDatalog();                                       // the stream drives the console even when the app's log is left alone
            StartAnalog();
            StartRealtime();
            RealtimeEnabled = State.AutoRealtime;                 // Settings > ALPHAemu
        }
        catch (Exception ex)
        {
            if (installed) CloseLink();
            lock (_gate)
            {
                _opening = false;
                if (_stop) { Phase = AlphaLinkPhase.Off; Status = "not connected"; }   // a cancel is not a fault
                else { Phase = AlphaLinkPhase.Faulted; Status = ex.Message; }
            }
            if (!_stop) Note("! " + ex.Message);
        }
        finally
        {
            if (!installed && link != null) { try { link.Dispose(); } catch { } }
            Raise();
        }
    }

    IAlphaLink Open() => State.Link switch
    {
        // only ever when the simulation is switched on (Device page): Connect otherwise goes to the real device
        AlphaTransport.BuiltInDevice when State.Simulate => new AlphaNextGenDevice(DeviceId()),
        AlphaTransport.BuiltInDevice => throw new IOException("the simulated device is switched off: pick the real emulator's port on the Device page"),
        _ when string.IsNullOrWhiteSpace(State.Port) => throw new IOException(State.Transport == AlphaTransport.BluetoothBridge
            ? "pick the Bluetooth bridge's serial port on the Device page"
            : "pick the emulator's serial port on the Device page (plug it in first)"),
        _ => new SerialAlphaLink(State.Port, State.Baud),
    };

    /// A stable id for the built-in device, so it looks like the same emulator every time.
    string DeviceId()
    {
        try
        {
            var file = Path.Combine(_app.DataFolder, "device.id");
            if (File.Exists(file))
            {
                var s = File.ReadAllText(file).Trim();
                if (s.Length > 0) return s;
            }
            var id = "AN-" + Guid.NewGuid().ToString("N")[..12].ToUpperInvariant();
            File.WriteAllText(file, id);
            return id;
        }
        catch { return "AN-000000000000"; }
    }

    bool? Probe()
    {
        var link = _link;
        if (link == null) return false;
        var r = link.Command(AlphaCmd.Echo, [], 800);
        return r.Ok;
    }

    void Reconnect()
    {
        if (_stop) return;
        Note("link lost - trying again");
        CloseLink();
        if (_stop) return;            // the user disconnected while we were between the close and the retry
        lock (_gate)
        {
            if (_link != null || _opening) return;
            _opening = true;
            Phase = AlphaLinkPhase.Reconnecting;
            Status = "reconnecting to " + LinkName + "…";
        }
        Raise();
        FinishConnect();              // already on the watch's thread; no need to spawn another
    }

    public void Disconnect()
    {
        lock (_gate)
        {
            _stop = true;             // tells any reconnect under way to stop
            _watch?.Dispose();
            _watch = null;
            CloseLink();
            Phase = AlphaLinkPhase.Off;
            Status = "not connected";
        }
        Note("disconnected");
        Raise();
    }

    void CloseLink()
    {
        try { _datalog?.Join(600); } catch { } _datalog = null;
        try { _analog?.Join(600); } catch { } _analog = null;
        try { _realtime?.Join(600); } catch { } _realtime = null;
        if (FeedingDatalog) { try { _app.DatalogEngine.EndExternal(); } catch { } FeedingDatalog = false; }
        Streaming = false;
        var l = _link; _link = null;
        if (l == null) return;
        try { l.StreamStop(); l.Dispose(); } catch { }
        _baseline = null;
    }

    void ReadIdentity()
    {
        var link = _link ?? throw new IOException("not linked");
        var r = link.Command(AlphaCmd.Identity, [], 4000);
        if (!r.Ok) throw new IOException(r.Error.Length > 0 ? r.Error : "the emulator did not identify itself");
        var f = r.Fields();
        var reg = new AlphaRegistration
        {
            Registered = f.GetValueOrDefault("registered", "0") == "1",
            Status = f.GetValueOrDefault("status", "unknown"),
            Serial = f.GetValueOrDefault("id", ""),
            Tier = f.GetValueOrDefault("tier", ""),
            CertificateId = f.GetValueOrDefault("cert", ""),
            ExpiresAt = f.GetValueOrDefault("expires", ""),
            Source = f.GetValueOrDefault("source", "device"),
            Features = [.. f.GetValueOrDefault("caps", "").Split(',', StringSplitOptions.RemoveEmptyEntries)],
        };
        _identity = new AlphaIdentity(
            f.GetValueOrDefault("id", "unknown"), f.GetValueOrDefault("kind", "ALPHAemu"),
            f.GetValueOrDefault("fw", "?"), f.GetValueOrDefault("protocol", "?"),
            int.TryParse(f.GetValueOrDefault("romsize"), out var size) ? size : 0x8000,
            int.TryParse(f.GetValueOrDefault("slots"), out var slots) ? slots : 4,
            int.TryParse(f.GetValueOrDefault("active"), out var act) ? act : 0,
            int.TryParse(f.GetValueOrDefault("target"), out var tgt) ? tgt : 0,
            reg.Features, reg);
        if (_link is AlphaNextGenDevice d) d.RomSize = RomSize();
        State.Devices[_identity.DeviceId] = new AlphaDeviceProfile
        {
            DeviceId = _identity.DeviceId, Kind = _identity.Kind, Port = State.Port, Baud = State.Baud,
            Firmware = _identity.Firmware, RomSize = _identity.RomSize, SlotCount = _identity.SlotCount,
            Capabilities = _identity.Capabilities, LastSeen = DateTime.Now, Registration = reg.Status,
        };
    }

    /// The image size to work with: the app's ROM if one is open, otherwise what the device says.
    int RomSize()
    {
        try
        {
            if (_app.Sim.LoadedPath != null) return _app.Sim.RomCopy().Length;
        }
        catch { }
        return _identity?.RomSize ?? 0x8000;
    }

    // ---------------------------------------------------------------- the datalog feed

    void StartDatalog()
    {
        var link = _link;
        if (link == null || _datalog != null) return;
        link.StreamStart(State.DatalogHz);
        Streaming = true;
        FeedingDatalog = State.FeedDatalog;
        if (FeedingDatalog) _app.DatalogEngine.BeginExternal("ALPHAemu on " + LinkName);
        if (Phase == AlphaLinkPhase.Linked) Phase = AlphaLinkPhase.Logging;
        _datalog = new Thread(DatalogLoop) { IsBackground = true, Name = "alpha datalog" };
        _datalog.Start();
        Note("datalog stream running at " + State.DatalogHz + " Hz" + (FeedingDatalog ? "" : " (the app's own datalog left alone)"));
    }

    void DatalogLoop()
    {
        var rate = Stopwatch.StartNew();
        int inWindow = 0;
        while (!_stop)
        {
            var link = _link;
            if (link == null) return;
            byte[]? raw;
            try { raw = link.ReadStream(250); }
            catch (Exception ex) { if (!_stop) Note("! stream: " + ex.Message); return; }
            if (raw == null) continue;
            LogFrame f;
            try { f = AlphaStreamFrame.Decode(raw); }
            catch (Exception ex) { Note("! a stream frame made no sense: " + ex.Message); continue; }

            var analog = AnalogAfr();
            if (analog is double afr && State.FeedWideband)
            {
                f.Extra["afr"] = afr;
                f.Extra["lambda"] = Math.Round(afr / Math.Max(1, Wideband.Stoich), 3);
            }
            foreach (var a in State.Analog)
            {
                if (!a.Enabled || !a.Fresh) continue;
                double? v = a.Value(a.SourceVolts, Wideband);
                if (v != null) f.Extra[a.Channel] = v.Value;
            }
            if (f.MapKpa is double kpa) f.Extra["boost_psi"] = Math.Round((kpa - 101.325) * 0.0145038, 2);

            Frames++;
            Latest = f;
            LastFrameAt = DateTime.Now;

            // the FeedDatalog box can be moved while running: hand over to, or back from, the app's engine
            if (FeedingDatalog != State.FeedDatalog)
            {
                if (State.FeedDatalog) { try { _app.DatalogEngine.BeginExternal("ALPHAemu on " + LinkName); FeedingDatalog = true; } catch { } }
                else { try { _app.DatalogEngine.EndExternal(); } catch { } FeedingDatalog = false; }
            }
            if (State.FeedDatalog) _app.DatalogEngine.Inject(f);
            if (State.DriveSimulator) { try { _app.Sim.ApplyFrame(f); } catch { } }
            FrameArrived?.Invoke(f);
            inWindow++;
            if (rate.Elapsed.TotalSeconds >= 1) { FramesPerSecond = inWindow / rate.Elapsed.TotalSeconds; inWindow = 0; rate.Restart(); }
        }
    }

    /// The wideband AFR from whichever analog input is carrying it, or null.
    public double? AnalogAfr()
    {
        var a = State.Analog[Math.Clamp(State.WidebandInput, 0, State.Analog.Count - 1)];
        if (!a.Enabled || !a.Fresh || a.Role != AlphaAnalogRole.WidebandAfr) return null;
        return Math.Round(Wideband.Afr(a.SourceVolts), 2);
    }

    // ---------------------------------------------------------------- the analog bank

    void StartAnalog()
    {
        if (_link == null || _analog != null) return;
        _analog = new Thread(AnalogLoop) { IsBackground = true, Name = "alpha analog" };
        _analog.Start();
    }

    void AnalogLoop()
    {
        while (!_stop)
        {
            var link = _link;
            if (link == null) return;
            try
            {
                var r = link.Command(AlphaCmd.Analog, [], 800);
                if (r.Ok && r.Body.Length >= 1) ApplyBank(r.Body);
                AnalogPolls++;
            }
            catch (Exception ex) { if (!_stop) { Note("! analog: " + ex.Message); return; } }
            Thread.Sleep(State.AnalogPollMs);
        }
    }

    // the ALPHAlink filter: hold small jitter, follow a real move with a one-pole filter, snap a big one
    const double FilterAlpha = 0.65, DeadbandCounts = 2, DeadbandMillivolts = 8, SnapMillivolts = 180;

    static double Filter(double previous, double next, double deadband, double snap)
    {
        if (!double.IsFinite(previous)) return next;
        if (!double.IsFinite(next)) return previous;
        double delta = next - previous;
        if (Math.Abs(delta) <= deadband) return previous;
        if (Math.Abs(delta) >= snap) return next;
        return previous + delta * FilterAlpha;
    }

    void ApplyBank(byte[] body)
    {
        int count = body[0];
        for (int i = 0; i < count && i < State.Analog.Count; i++)
        {
            int at = 1 + i * 6;
            if (at + 5 >= body.Length + 0 && at + 5 > body.Length - 1) break;
            int raw = body[at] | (body[at + 1] << 8);
            int adcMv = body[at + 2] | (body[at + 3] << 8);
            int srcMv = body[at + 4] | (body[at + 5] << 8);
            var a = State.Analog[i];
            a.Raw = (int)Math.Round(Filter(a.Raw, raw, DeadbandCounts, 64));
            a.AdcVolts = Math.Round(Filter(a.AdcVolts * 1000, adcMv, DeadbandMillivolts, SnapMillivolts) / 1000, 3);
            a.SourceVolts = Math.Round(Filter(a.SourceVolts * 1000, srcMv, DeadbandMillivolts, SnapMillivolts) / 1000, 3);
            a.LastSeen = DateTime.Now;
            if (!State.AnalogToSimulator || !a.Enabled) continue;
            if (a.SimulatorInput is string input && a.Value(a.SourceVolts, Wideband) is double v)
            {
                try { _app.Sim.SetInput(input, v); } catch { }
            }
        }
        Raise();
    }

    // ---------------------------------------------------------------- real-time update

    void StartRealtime()
    {
        if (_realtime != null) return;
        _realtime = new Thread(RealtimeLoop) { IsBackground = true, Name = "alpha realtime" };
        _realtime.Start();
    }

    void RealtimeLoop()
    {
        while (!_stop)
        {
            Thread.Sleep(Math.Max(20, State.RealtimeDelayMs));
            if (!RealtimeEnabled || _patching || _link == null) continue;
            try { Drain(); }
            catch (Exception ex) { Note("! real-time: " + ex.Message); }
        }
    }

    /// Everything the editor has changed since the emulator was last told, in blocks the link can carry.
    void Drain()
    {
        var rom = _app.Sim.RomCopy();
        if (_baseline == null)
        {
            // nothing to compare against yet: make the emulator's running image the baseline, or put this one in
            var inDevice = ReadActiveImage();
            if (inDevice == null) { Note("real-time: nothing is running in the emulator - deploy a slot first"); return; }
            if (inDevice.Length != rom.Length) { Note($"real-time: the emulator holds {inDevice.Length} bytes and the editor has {rom.Length} - deploy to match"); return; }
            _baseline = inDevice;
            Raise();
            return;
        }
        if (_baseline.Length != rom.Length) { Note("real-time: the image size changed - deploy again to re-sync"); _baseline = null; return; }

        var edits = new List<(int Offset, byte Value)>();
        for (int i = 0; i < rom.Length && edits.Count < 4096; i++)
            if (rom[i] != _baseline[i]) edits.Add((i, rom[i]));
        if (edits.Count == 0) return;

        _patching = true;
        try
        {
            int sent = 0;
            int per = Math.Max(16, State.MaxPatchBytes / 5);       // five bytes a pair: 32-bit offset, the byte
            for (int from = 0; from < edits.Count; from += per)
            {
                int take = Math.Min(per, edits.Count - from);
                var r = _link!.Command(AlphaCmd.Patch, AlphaWire.Patch(edits, from, take), 3000);
                if (!r.Ok) throw new IOException(r.Error);
                sent += take;
            }
            foreach (var (offset, value) in edits) _baseline[offset] = value;
            PatchBytesSent += sent;
            PatchesSent++;
            _patchRetries = 0;
            Note($"real-time: {sent} byte{(sent == 1 ? "" : "s")} to the emulator (" +
                 $"{(edits.Count > 0 ? "0x" + edits[0].Offset.ToString("X4") : "-")}{(edits.Count > 1 ? "…" : "")})");
            Raise();
        }
        catch (Exception ex)
        {
            _patchRetries++;
            Note($"! real-time failed ({_patchRetries} of 3): {ex.Message}");
            if (_patchRetries >= 3) { RealtimeEnabled = false; Note("real-time update turned off after 3 failures"); }
        }
        finally { _patching = false; }
    }

/// One command straight to the device (the screens ask for a few things the session does not wrap).
    public AlphaReply Command(byte command, byte[] body, int timeoutMs = 2000) =>
        _link?.Command(command, body, timeoutMs) ?? AlphaReply.Fail("the emulator is not linked");

    /// The slot the emulator is running.
    public int ActiveSlot()
    {
        var link = _link ?? throw new IOException("not connected");
        var info = link.Command(AlphaCmd.SlotStatus, []);
        if (!info.Ok) throw new IOException(info.Error);
        return info.Num("active", 0);
    }

    public byte[]? ReadActiveImage()
    {
        var link = _link;
        if (link == null) return null;
        var info = link.Command(AlphaCmd.SlotStatus, []);
        if (!info.Ok) return null;
        int active = info.Num("active", 0);
        var one = link.Command(AlphaCmd.SlotInfo, [(byte)active]);
        if (!one.Ok || one.Num("size") == 0) return null;
        return ReadSlotBytes(active, one.Num("size"));
    }

    public byte[]? ReadSlotBytes(int slot, int size, Action<int>? progress = null)
    {
        var link = _link;
        if (link == null) return null;
        var img = new byte[size];
        int at = 0;
        while (at < size)
        {
            int want = Math.Min(8192, size - at);
            var r = link.Command(AlphaCmd.ReadSlot, Encoding.ASCII.GetBytes($"slot={slot};offset={at};count={want}"), 4000);
            if (!r.Ok) { Note("! reading slot " + slot + ": " + r.Error); return null; }
            int offset, start;
            try { (offset, start) = AlphaWire.ReadSlotAnswer(r.Body); }
            catch (ArgumentException ex) { Note("! reading slot " + slot + ": " + ex.Message); return null; }
            int got = r.Body.Length - start;
            if (got <= 0 || offset < at || offset + got > size)
            {
                Note($"! reading slot {slot}: an answer for offset {offset} of {got} bytes does not fit what was asked for");
                return null;
            }
            Buffer.BlockCopy(r.Body, start, img, offset, got);
            at = offset + got;
            progress?.Invoke(at);
        }
        return img;
    }

    // ---------------------------------------------------------------- long commands (slots, firmware, codes)

    /// Run a device command off the UI thread with one progress line, then call back on the UI thread.
    public void Run(string what, Func<AlphaSession, string> work, Action<string>? done = null)
    {
        if (_link == null) { done?.Invoke("not connected"); return; }
        _command = new Thread(() =>
        {
            try
            {
                string result = work(this);
                Note(what + ": " + result);
                Raise();
                _app.Ui(() => { _app.SetStatus(what + ": " + result); done?.Invoke(result); });
            }
            catch (Exception ex)
            {
                Note("! " + what + ": " + ex.Message);
                _app.Ui(() => { _app.SetStatus(what + " failed: " + ex.Message); done?.Invoke("failed: " + ex.Message); });
            }
        })
        { IsBackground = true, Name = "alpha command" };
        _command.Start();
    }

    /// Stage a slot's bytes in the device, verify them, and commit - the deployment the multi-map manager does per slot.
    public string DeploySlot(int slot, byte[] bytes, Action<int, int>? progress = null)
    {
        var link = _link ?? throw new IOException("not connected");
        string sha = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        var begin = link.Command(AlphaCmd.WriteBegin, Encoding.ASCII.GetBytes($"slot={slot};size={bytes.Length};sha={sha}"), 3000);
        if (!begin.Ok) throw new IOException(begin.Error);
        int at = 0;
        while (at < bytes.Length)
        {
            int take = Math.Min(1024, bytes.Length - at);
            var w = link.Command(AlphaCmd.WriteData, AlphaWire.WriteData(slot, bytes, at, take), 3000);
            if (!w.Ok) throw new IOException(w.Error);
            at += take;
            progress?.Invoke(at, bytes.Length);
        }
        var commit = link.Command(AlphaCmd.WriteCommit, Encoding.ASCII.GetBytes($"slot={slot};sha={sha}"), 4000);
        if (!commit.Ok) throw new IOException(commit.Error);
        var verify = link.Command(AlphaCmd.Verify, Encoding.ASCII.GetBytes($"slot={slot};sha={sha}"), 3000);
        if (!verify.Ok) throw new IOException(verify.Error);
        if (verify.Num("match") != 1) throw new IOException("the device's copy does not match what was sent");
        return "written, verified and committed";
    }

    public string VerifySlot(int slot, string sha)
    {
        var link = _link ?? throw new IOException("not connected");
        var r = link.Command(AlphaCmd.Verify, Encoding.ASCII.GetBytes($"slot={slot};sha={sha}"), 3000);
        if (!r.Ok) throw new IOException(r.Error);
        string have = r.Str("sha");
        return r.Num("match") == 1 ? "the device's copy matches (" + r.Str("size") + " bytes)"
                                   : $"does not match - device has {(have.Length > 10 ? have[..10] : have)}";
    }

    public string SetActiveSlot(int slot)
    {
        var link = _link ?? throw new IOException("not connected");
        var r = link.Command(AlphaCmd.ActiveSlot, Encoding.ASCII.GetBytes($"slot={slot}"), 3000);
        if (!r.Ok) throw new IOException(r.Error);
        _baseline = null;             // the running image changed under us: the real-time baseline is stale
        return "slot " + slot + " is live";
    }

    /// The codes on hold. The screens ask every refresh (on the UI thread), so the answer is a cache
    /// topped up on a worker: over a real serial link a read must never wait on a timeout in a repaint.
    public (int[] Codes, string Source) TroubleCodes(bool force = false)
    {
        var link = _link;
        if (link == null)
        {
            var f = Latest;
            if (f != null && f.Get("dtc0") is double d0)
                _dtcCache = (CodesOf([(byte)d0, (byte)(f.Get("dtc1") ?? 0), (byte)(f.Get("dtc2") ?? 0), (byte)(f.Get("dtc3") ?? 0)]), "the last datalog frame");
            return _dtcCache;
        }
        if (force || _dtcAt == DateTime.MinValue || (DateTime.Now - _dtcAt).TotalSeconds >= 1)
            lock (_dtcGate)
            {
                if (!_dtcFetching)
                {
                    _dtcFetching = true;
                    _dtcAt = DateTime.Now;
                    new Thread(() =>
                    {
                        try
                        {
                            var r = link.Command(AlphaCmd.DtcRead, [], 1200);
                            if (r.Ok && r.Body.Length >= 4 && ReferenceEquals(link, _link)) _dtcCache = (CodesOf(r.Body), "the emulator");
                        }
                        catch { }
                        finally { lock (_dtcGate) _dtcFetching = false; }
                    })
                    { IsBackground = true, Name = "alpha dtc read" }.Start();
                }
            }
        return _dtcCache;
    }

    public static int[] CodesOf(byte[] four)
    {
        var list = new List<int>();
        for (int bit = 0; bit < 32; bit++)
            if ((four[bit / 8] >> (bit % 8) & 1) != 0)
            {
                int code = OkiRomSim.Core.MilMonitor.FlashCode(bit);
                if (code > 0) list.Add(code);
            }
        return [.. list];
    }

    public string ClearTroubleCodes()
    {
        var link = _link ?? throw new IOException("not connected");
        var r = link.Command(AlphaCmd.DtcClear, [], 2000);
        if (!r.Ok) throw new IOException(r.Error);
        return "codes cleared";
    }

    /// What the device says about its firmware. Cached for a few seconds so a page refreshing at
    /// 300 ms does not put a status command on the wire every tick; force after an apply.
    public string FirmwareStatus(bool force = false)
    {
        if (!force && (DateTime.Now - _fwAt).TotalSeconds < 3 && _fwCache.Length > 0) return _fwCache;
        _fwAt = DateTime.Now;
        var link = _link ?? throw new IOException("not connected");
        var r = link.Command(AlphaCmd.FwStatus, [], 2000);
        if (!r.Ok) throw new IOException(r.Error);
        return _fwCache = $"{r.Str("stage")} {r.Num("pct")}% · {r.Str("version", r.Str("current", "?"))}";
    }

    /// The last status read, with a background top-up when it has gone stale - for pages that refresh
    /// faster than the wire should be asked, and that must not wait on a serial timeout.
    public string FirmwareStatusCached()
    {
        if (_link == null) return _fwCache.Length > 0 ? _fwCache : "not linked";
        lock (_fwGate)
        {
            if ((DateTime.Now - _fwAt).TotalSeconds < 3) return _fwCache.Length > 0 ? _fwCache : "asking…";
            _fwAt = DateTime.Now;
        }
        var link = _link;
        new Thread(() =>
        {
            try
            {
                var r = link.Command(AlphaCmd.FwStatus, [], 2000);
                _fwCache = r.Ok ? $"{r.Str("stage")} {r.Num("pct")}% · {r.Str("version", r.Str("current", "?"))}" : "! " + r.Error;
            }
            catch (Exception ex) { _fwCache = "! " + ex.Message; }
        })
        { IsBackground = true, Name = "alpha firmware status" }.Start();
        return _fwCache.Length > 0 ? _fwCache : "asking…";
    }

    public string FirmwareApply(byte[] image, Action<string>? progress = null)
    {
        var link = _link ?? throw new IOException("not connected");
        var stage = link.Command(AlphaCmd.FwStage, image, 8000);
        if (!stage.Ok) throw new IOException(stage.Error);
        var apply = link.Command(AlphaCmd.FwApply, [], 4000);
        if (!apply.Ok) throw new IOException(apply.Error);
        for (int i = 0; i < 200; i++)
        {
            Thread.Sleep(120);
            var s = link.Command(AlphaCmd.FwStatus, [], 2000);
            progress?.Invoke($"{s.Str("stage")} {s.Num("pct")}%");
            if (s.Str("stage") == "done") { _fwAt = DateTime.MinValue; _fwCache = ""; return "firmware now " + s.Str("version", "?"); }
        }
        _fwAt = DateTime.MinValue;
        return "the device is still applying it";
    }

    // ---------------------------------------------------------------- odds and ends

    public string LogText() { lock (_log) return string.Join('\n', _log); }

    void Note(string line)
    {
        lock (_log) { _log.Add($"{DateTime.Now:HH:mm:ss}  {line}"); if (_log.Count > 300) _log.RemoveRange(0, _log.Count - 300); }
        Logged?.Invoke(line);
    }

    void Raise() => Changed?.Invoke();

    public void Dispose() => Disconnect();
}




