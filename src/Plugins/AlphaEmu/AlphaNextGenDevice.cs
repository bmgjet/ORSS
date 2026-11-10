// Copyright (c) bmgjet. All rights reserved.
using System.Security.Cryptography;
using System.Text;

namespace AlphaEmuPlugin;

/// The built-in ALPHA NextGEN: a full answer to every command the plugin sends, driven by the same
/// 24-second drive cycle the ALPHAlink demo ran (idle, a tip-in, three pulls to the limiter, a decel,
/// then settle) with an injector model on top. It exists so every ALPHAemu screen - slots, analog
/// inputs, real-time patches, trouble codes, firmware, the datalog the app logs - can be used and
/// checked with nothing plugged in. Swapping it for SerialAlphaLink changes nothing above this line.
public sealed class AlphaNextGenDevice : IAlphaLink
{
    readonly object _gate = new();
    readonly byte[][] _slots = new byte[4][];
    readonly Random _rng = new();
    Thread? _streamer;
    volatile bool _streaming;
    readonly Queue<byte[]> _out = new();
    int _activeSlot, _targetSlot;
    static readonly double[] _thermistor = BuildThermistor();
    byte[]? _firmwareStage;
    string _firmwareVersion = "1.15.4";
    DateTime _firmwareApplyUntil = DateTime.MinValue;
    string _firmwareStageName = "";
    int _firmwarePct;
    byte[] _dtc = new byte[4];
    bool _dtcHeld;
    DateTime _openedAt = DateTime.Now;
    double _simTime;

    public event Action<string>? Traffic;
    public string Description => "built-in ALPHA NextGEN (" + DeviceId + ")";
    public string DeviceId { get; }
    /// How the device turns the AFR it is running into the volts a wideband controller would output
    /// (the plugin sets this from the wideband profile in force, because the sensor is what it is).
    public Func<double, double> AfrToVolts { get; set; } = a => Math.Clamp((a - 10.0) / 10.0 * 5, 0, 5);

    int _romSize = 0x8000;
    bool _seeded = true;
    /// The image size the device holds in a slot (the app's ROM size, so a slot image can be deployed straight in).
    /// While nothing has been written yet, the factory image in slot 0 follows it.
    public int RomSize
    {
        get => _romSize;
        set
        {
            if (value <= 0 || value == _romSize) return;
            _romSize = value;
            lock (_gate) if (_seeded) _slots[0] = SeedImage(value);
        }
    }

    public AlphaNextGenDevice(string deviceId)
    {
        DeviceId = deviceId;
        for (int i = 0; i < 4; i++) _slots[i] = [];
        // Slot 0 comes with something in it, the way a shipped emulator's first slot has the base calibration.
        _slots[0] = SeedImage(_romSize);
    }

    /// The factory image in slot 0: code-shaped bytes and a plausible set of tables, so reading a slot
    /// back gives something worth looking at rather than zeros.
    static byte[] SeedImage(int size)
    {
        var b = new byte[size];
        var r = new Random(0xA1FA);
        r.NextBytes(b);
        // a recognisable header and a checksum word at the top of the last page
        Encoding.ASCII.GetBytes("ALPHAEMU-BASE-1.15").CopyTo(b, 0);
        for (int i = 0x100; i < Math.Min(size, 0x120); i++) b[i] = 0;
        b[^2] = 0x2A; b[^1] = 0xB7;
        return b;
    }

    public void Open()
    {
        _openedAt = DateTime.Now;
        Traffic?.Invoke("→ " + Description + " online");
    }

    public AlphaReply Command(byte command, byte[] body, int timeoutMs = 2000)
    {
        string Text(byte[] x) => Encoding.ASCII.GetString(x);
        switch (command)
        {
            case AlphaCmd.Echo:
                return Ok(body);

            case AlphaCmd.Identity:
                lock (_gate)
                {
                    bool registered = true;         // the built-in device identifies itself as an authorised ALPHA NextGEN
                    return Ok(Asc(string.Join(';',
                        $"id={DeviceId}", "kind=ALPHA NextGEN", $"fw={_firmwareVersion}", "protocol=AB1",
                        $"romsize={RomSize}", "slots=4", $"active={_activeSlot}", $"target={_targetSlot}",
                        "caps=multimap,analog,realtime,dtc,firmware,stream",
                        $"registered={(registered ? 1 : 0)}", "status=approved", "tier=full",
                        $"cert=LOC-{DeviceId[..Math.Min(8, DeviceId.Length)]}",
                        $"expires={DateTime.Now.AddYears(1):yyyy-MM-dd}", "source=built-in")));
                }

            case AlphaCmd.SlotStatus:
                lock (_gate)
                    return Ok(Asc($"count={_slots.Length};active={_activeSlot};target={_targetSlot};romsize={RomSize}"));

            case AlphaCmd.SlotInfo:
                {
                    int slot = body.Length > 0 ? body[0] : 0;
                    if (slot >= _slots.Length) return AlphaReply.Fail($"this device has no slot {slot}");
                    lock (_gate)
                    {
                        var img = _slots[slot];
                        return Ok(Asc($"slot={slot};size={img.Length};sha={(img.Length > 0 ? Sha(img) : "")};committed={(img.Length > 0 ? 1 : 0)}"
                                     + $";active={(_activeSlot == slot ? 1 : 0)};target={(_targetSlot == slot ? 1 : 0)}"));
                    }
                }

            case AlphaCmd.ActiveSlot:
                {
                    var f = Parse(Text(body));
                    int slot = Int(f, "slot");
                    if (slot < 0 || slot >= _slots.Length) return AlphaReply.Fail($"no slot {slot} on this device");
                    lock (_gate) { if (_slots[slot].Length == 0) return AlphaReply.Fail($"slot {slot} is empty - nothing to run"); _activeSlot = slot; _targetSlot = slot; }
                    Traffic?.Invoke($"active slot is now {slot}");
                    return Ok(Asc($"active={slot}"));
                }

            case AlphaCmd.WriteBegin:
                {
                    var f = Parse(Text(body));
                    int slot = Int(f, "slot"), size = Int(f, "size");
                    if (slot < 0 || slot >= _slots.Length) return AlphaReply.Fail($"no slot {slot} on this device");
                    lock (_gate) { _slots[slot] = new byte[Math.Max(0, size)]; if (slot == 0) _seeded = false; }
                    return Ok(Asc($"slot={slot};ready=1"));
                }

            case AlphaCmd.WriteData:
                {
                    int slot, offset, start;
                    try { (slot, offset, start) = AlphaWire.ReadWriteData(body); }
                    catch (ArgumentException ex) { return AlphaReply.Fail(ex.Message); }
                    lock (_gate)
                    {
                        if (slot >= _slots.Length) return AlphaReply.Fail($"no slot {slot}");
                        var img = _slots[slot];
                        if (offset < 0 || offset + body.Length - start > img.Length) return AlphaReply.Fail($"bytes at {offset} run past the {img.Length} byte image");
                        Buffer.BlockCopy(body, start, img, offset, body.Length - start);
                    }
                    return Ok(Asc($"slot={slot};at={offset};n={body.Length - start}"));
                }

            case AlphaCmd.WriteCommit:
                {
                    var f = Parse(Text(body));
                    int slot = Int(f, "slot");
                    string want = f.GetValueOrDefault("sha", "");
                    lock (_gate)
                    {
                        if (slot < 0 || slot >= _slots.Length || _slots[slot].Length == 0) return AlphaReply.Fail($"slot {slot} has nothing staged in it");
                        string have = Sha(_slots[slot]);
                        if (want.Length > 0 && !string.Equals(want, have, StringComparison.OrdinalIgnoreCase))
                            return AlphaReply.Fail($"slot {slot} does not match what was staged (device says {have[..10]}, you said {want[..10]})");
                    }
                    Traffic?.Invoke($"slot {slot} committed");
                    return Ok(Asc($"slot={slot};committed=1;sha={Sha(_slots[slot])}"));
                }

            case AlphaCmd.Verify:
                {
                    var f = Parse(Text(body));
                    int slot = Int(f, "slot");
                    string want = f.GetValueOrDefault("sha", "");
                    lock (_gate)
                    {
                        if (slot < 0 || slot >= _slots.Length || _slots[slot].Length == 0) return AlphaReply.Fail($"slot {slot} is empty, so there is nothing to compare");
                        string have = Sha(_slots[slot]);
                        bool match = want.Length == 0 || string.Equals(want, have, StringComparison.OrdinalIgnoreCase);
                        return match ? Ok(Asc($"match=1;sha={have};size={_slots[slot].Length}"))
                                     : Ok(Asc($"match=0;sha={have};size={_slots[slot].Length};wanted={want}"));
                    }
                }

            case AlphaCmd.ReadSlot:
                {
                    var f = Parse(Text(body));
                    int slot = Int(f, "slot"), offset = Int(f, "offset", 0), count = Int(f, "count", 8192);
                    lock (_gate)
                    {
                        if (slot < 0 || slot >= _slots.Length || _slots[slot].Length == 0) return AlphaReply.Fail($"slot {slot} is empty");
                        var img = _slots[slot];
                        if (offset < 0) return AlphaReply.Fail($"nothing to read at {offset} of a {img.Length} byte image");
                        count = Math.Min(count, img.Length - offset);
                        if (count <= 0) return AlphaReply.Fail($"nothing to read at {offset} of a {img.Length} byte image");
                        return Ok(AlphaWire.ReadSlotReply(img, offset, count));
                    }
                }

            case AlphaCmd.Patch:
                {
                    if (body.Length < 2) return AlphaReply.Fail("a patch needs a count and then offset/value pairs");
                    int n = AlphaWire.PatchCount(body);
                    if (body.Length < 2 + n * 5) return AlphaReply.Fail("the patch list is shorter than it says");
                    lock (_gate)
                    {
                        var img = _slots[_activeSlot];
                        if (img.Length == 0) return AlphaReply.Fail("no calibration is running in the emulator - commit a slot first");
                        int applied = 0;
                        foreach (var (off, value) in AlphaWire.PatchPairs(body))
                        {
                            if (off < 0 || off >= img.Length) continue;
                            if (img[off] != value) { img[off] = value; applied++; }
                        }
                        return Ok(Asc($"applied={applied};total={n};slot={_activeSlot}"));
                    }
                }

            case AlphaCmd.Analog:
                return Ok(AnalogBank());

            case AlphaCmd.DtcRead:
                lock (_gate) return Ok([.. _dtc]);

            case AlphaCmd.DtcClear:
                lock (_gate) { _dtc = new byte[4]; _dtcHeld = true; }
                Traffic?.Invoke("trouble codes cleared");
                return Ok(Asc("cleared=1"));

            case AlphaCmd.StreamStart:
                {
                    int hz = Int(Parse(Text(body)), "hz", 20);
                    StreamStart(Math.Clamp(hz, 1, 100));
                    return Ok(Asc("streaming=1"));
                }
            case AlphaCmd.StreamStop:
                StreamStop();
                return Ok(Asc("streaming=0"));

            case AlphaCmd.FwInfo:
                return Ok(Asc($"name=ALPHA NextGEN firmware;version={_firmwareVersion};size=0;current=1"));

            case AlphaCmd.FwStage:
                {
                    _firmwareStage = body;
                    _firmwareStageName = $"staged {AlphaState.Bytes(body.Length)}";
                    _firmwarePct = 0;
                    return Ok(Asc($"staged={body.Length}"));
                }

            case AlphaCmd.FwApply:
                {
                    if (_firmwareStage == null || _firmwareStage.Length == 0) return AlphaReply.Fail("nothing was staged");
                    _firmwareApplyUntil = DateTime.Now.AddSeconds(2.2);
                    _firmwarePct = 1;
                    Traffic?.Invoke("firmware: applying");
                    return Ok(Asc("stage=applying;pct=1"));
                }

            case AlphaCmd.FwStatus:
                {
                    if (_firmwareApplyUntil > DateTime.Now)
                    {
                        _firmwarePct = Math.Min(99, (int)(100 * (1 - (_firmwareApplyUntil - DateTime.Now).TotalSeconds / 2.2)));
                        return Ok(Asc($"stage=applying;pct={_firmwarePct}"));
                    }
                    if (_firmwareApplyUntil != DateTime.MinValue && _firmwareStage != null)
                    {
                        var parts = _firmwareVersion.Split('.');
                        _firmwareVersion = $"{parts[0]}.{parts[1]}.{int.Parse(parts[2]) + 1}";
                        _firmwareApplyUntil = DateTime.MinValue;
                        _firmwareStage = null;
                        _firmwarePct = 100;
                        Traffic?.Invoke("firmware: now " + _firmwareVersion);
                        return Ok(Asc($"stage=done;pct=100;version={_firmwareVersion}"));
                    }
                    return Ok(Asc($"stage=idle;pct=0;version={_firmwareVersion}"));
                }

            case AlphaCmd.Sync:
                {
                    string sha = Parse(Text(body)).GetValueOrDefault("sha", "");
                    Traffic?.Invoke("real-time baseline " + (sha.Length > 10 ? sha[..10] : sha));
                    return Ok(Asc("synced=1;sha=" + sha));
                }

            default:
                return AlphaReply.Fail($"this device does not answer {AlphaSerialNaming.Name(command)}");
        }
    }

    static AlphaReply Ok(byte[] body) => new(true, body, "");
    static byte[] Asc(string s) => Encoding.ASCII.GetBytes(s);
    static string Sha(byte[] b) => Convert.ToHexString(SHA256.HashData(b)).ToLowerInvariant();
    static int Int(Dictionary<string, string> f, string key, int fallback = -1) =>
        int.TryParse(f.GetValueOrDefault(key, ""), out var n) ? n : fallback;
    static Dictionary<string, string> Parse(string text)
    {
        var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in text.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            int eq = p.IndexOf('=');
            if (eq > 0) d[p[..eq]] = p[(eq + 1)..];
        }
        return d;
    }

    // ---------------------------------------------------------------- the simulated engine

    /// One 24 s cycle: idle with a little hunt, a tip-in, three pulls to the limiter, a decel, settle.
    /// The shape is ALPHAlink's own demo sweep, at whatever rate the datalog is running.
    void StepSim(double dt)
    {
        _simTime += dt;
        double phase = _simTime % 24;
        double targetTps = 0, targetRpm = 850;
        if (phase < 3) { targetTps = 0; targetRpm = 850 + Math.Sin(_simTime * 4) * 20; }
        else if (phase < 4) { double t = phase - 3; targetTps = Math.Sin(t * Math.PI) * 25; targetRpm = 850 + targetTps * 40; }
        else if (phase < 6) { targetTps = 0; targetRpm = 850; }
        else if (phase < 14)
        {
            double s = phase - 6;
            if (s < 2.5) { targetTps = 100; targetRpm = 1200 + s / 2.5 * 6200; }
            else if (s < 2.8) { targetTps = 0; targetRpm = 4000 - (s - 2.5) * 4000; }
            else if (s < 5.5) { targetTps = 100; targetRpm = 3200 + (s - 2.8) / 2.7 * 5000; }
            else if (s < 5.8) { targetTps = 0; targetRpm = 4800 - (s - 5.5) * 3000; }
            else
            {
                targetTps = 100; targetRpm = 4500 + (s - 5.8) / 2.2 * 3800;
                if (targetRpm > 8200) targetRpm = ((int)(_simTime * 25) & 1) == 0 ? 8250 : 8050;
            }
        }
        else if (phase < 17) { targetTps = 0; double d = phase - 14; targetRpm = Math.Max(1200, 8000 - d * 2200); }
        else { targetTps = 0; double st = phase - 17; targetRpm = 1200 - st / 7 * 350; }

        _rpm = _rpm * 0.7 + targetRpm * 0.3;
        _tps = _tps * 0.7 + targetTps * 0.3;
        double throttle = _tps / 100, charge = Math.Max(0, (_rpm - 2500) / 5500) * 1.4;
        _map = _map * 0.8 + (0.35 + throttle * (0.65 + charge)) * 0.2;                    // bar
        double targetAfr = throttle > 0.8 ? 11.5 + (1 - throttle) * 1.5
                          : throttle < 0.02 && _rpm > 1500 ? 18 : 14.7 + Math.Sin(_simTime * 2.5) * 0.15;
        _afr = _afr * 0.75 + targetAfr * 0.25;
        _ign = Math.Clamp(28 + _rpm / 9000 * 15 - (_map * 100 - 40) * 0.08 + _rng.NextDouble() * 0.4, 10, 42);

        double speedTarget = 0;
        if (phase >= 6 && phase < 14)
        {
            double s = phase - 6;
            speedTarget = s < 2.5 ? 20 + s * 20 : s < 5.5 ? 70 + (s - 2.8) * 25 : 130 + (s - 5.8) * 35;
        }
        else if (phase >= 14 && phase < 17) speedTarget = Math.Max(10, 180 - (phase - 14) * 50);
        _vss = _vss * 0.9 + speedTarget * 0.1;

        // volumetric efficiency in the same shape as ALPHAlink's demo table, then injector pulse for it
        double loadNorm = Math.Clamp((_map * 100 - 20) / 120, 0, 1);
        double ve = Math.Clamp(0.35 + 0.75 * loadNorm + 0.35 * Math.Sin((_rpm - 500) / 7500 * Math.PI), 0.25, 1.35);
        double airGrams = ve * (_map * 100 / 101.325) * 1.184 * 0.4;                      // one cylinder, one cycle, 1.6 litres
        double fuelGrams = airGrams / Math.Max(8, _afr);
        _inj = Math.Clamp(fuelGrams / 3.6 * 1000 + 0.6, 0.6, 40);                         // 3.6 g/s injectors
        _duty = Math.Clamp(_inj / Math.Max(1, 60000 / Math.Max(1, _rpm)) * 100, 0, 105);

        _ect = Math.Clamp(_ect + dt * 0.14 + (Math.Clamp(100 - _ect, 0, 30)) * dt * 0.01, -20, 104);
        _iat = Math.Clamp(_iat * 0.999 + (26 + _map * 3.2 * 0.15) * 0.001, -20, 70);
        _batt = 13.9 + Math.Sin(_simTime * 0.7) * 0.22 + (_rpm > 2000 ? 0.35 : 0);
        _o2 = _afr < 14.7 ? 0.72 + _rng.NextDouble() * 0.18 : 0.12 + _rng.NextDouble() * 0.12;
        _vtec = _rpm > 5500 && _tps > 35;
        _mil = false;
        if (_ect < 25 && _rpm > 1800) _mil = true;                                        // O2 sensor below operating temperature
        if (!_dtcHeld && _mil) _dtc[0] |= 0x01;                                           // code 1 (O2 sensor), once, until it is cleared
        if (_dtcHeld && _ect > 60) _dtc[0] = 0;                                           // and it stays off once the sensor is warm
        if ((_dtc[0] & 0x01) != 0) _mil = true;
        _fuelCut = _rpm > 8150 || (_tps < 2 && _rpm > 5000);
        _bks = _tps > 96 && _rpm > 3000;
        _schg = _batt < 12.2 || _batt > 14.8;
    }

    double _rpm = 850, _tps, _map = 0.35, _afr = 14.7, _ign = 22, _inj = 2.4, _duty = 8, _vss, _batt = 13.9, _o2 = 0.45;
    double _ect = 22, _iat = 26;
    bool _vtec, _mil, _fuelCut, _bks, _schg;

    byte[] AnalogBank()
    {
        // 8 inputs: the wideband, TPS, MAP, ECT, IAT, battery, and two sitting at 0 with their noise
        double[] volts =
        [
            AfrToVolts(_afr),
            0.5 + _tps / 100 * 4.0,
            Math.Clamp(_map / 3.0 * 5.0, 0, 5),
            ThermistorVolts(_ect),
            ThermistorVolts(_iat),
            _batt / 8.0,
            _rng.NextDouble() * 0.012,
            _rng.NextDouble() * 0.012,
        ];
        var b = new byte[1 + volts.Length * 6];
        b[0] = (byte)volts.Length;
        for (int i = 0; i < volts.Length; i++)
        {
            double jitter = volts[i] + (_rng.NextDouble() - 0.5) * 0.006;
            int raw = (int)Math.Clamp(jitter / 5.0 * 1023, 0, 1023);
            int adc = (int)(raw * 5000.0 / 1023);
            int src = (int)(volts[i] * 1000);
            int at = 1 + i * 6;
            b[at] = (byte)(raw & 0xFF); b[at + 1] = (byte)(raw >> 8);
            b[at + 2] = (byte)(adc & 0xFF); b[at + 3] = (byte)(adc >> 8);
            b[at + 4] = (byte)(src & 0xFF); b[at + 5] = (byte)(src >> 8);
        }
        return b;
    }

    /// The ECU's thermistor the other way round: how many volts the sensor sits at for a temperature.
    static double ThermistorVolts(double celsius)
    {
        // built once from the app's own table so the analog input agrees with the datalog decode
        return _thermistor[(int)Math.Clamp((celsius + 40) * 2, 0, 255)];
    }

    static double[] BuildThermistor()
    {
        var table = new double[256];
        for (int i = 0; i < 256; i++)
        {
            double c = OkiRomSim.Calibration.HondaDatalog.ThermistorC((byte)i);
            int t = (int)Math.Clamp((c + 40) * 2, 0, 255);           // -40..87.5 °C across the table
            if (table[t] == 0) table[t] = i / 255.0 * 5.0;
        }
        for (int i = 1; i < 256; i++) if (table[i] == 0) table[i] = table[i - 1];
        return table;
    }

    public void StreamStart(int hertz)
    {
        if (_streaming) return;
        _streaming = true;
        _streamer = new Thread(() => RunStream(hertz)) { IsBackground = true, Name = "alpha nextgen stream" };
        _streamer.Start();
        Traffic?.Invoke($"→ datalog stream at {hertz} Hz");
    }

    public void StreamStop()
    {
        if (!_streaming) return;
        _streaming = false;
        try { _streamer?.Join(500); } catch { }
        _streamer = null;
        Traffic?.Invoke("→ datalog stream stopped");
    }

    void RunStream(int hertz)
    {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        double last = 0;
        double period = 1.0 / hertz;
        while (_streaming)
        {
            double now = clock.Elapsed.TotalSeconds;
            StepSim(now - last); last = now;
            byte flags = (byte)((_vtec ? 1 : 0) | 2 | (_mil ? 4 : 0) | (_fuelCut ? 8 : 0) | (_bks ? 16 : 0) | (_schg ? 32 : 0));
            var frame = AlphaStreamFrame.Encode(_rpm, _tps, _map * 100, _ect, _iat, _o2, _afr, _ign, _inj, _duty,
                                                _vss, _batt, 100, flags, _dtc);
            lock (_out) { _out.Enqueue(frame); while (_out.Count > 256) _out.Dequeue(); }
            double work = clock.Elapsed.TotalSeconds - now;
            Thread.Sleep(Math.Max(1, (int)((period - work) * 1000)));
        }
    }

    public byte[]? ReadStream(int timeoutMs)
    {
        var until = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < until)
        {
            lock (_out) if (_out.Count > 0) return _out.Dequeue();
            Thread.Sleep(4);
        }
        return null;
    }

    public void Dispose()
    {
        StreamStop();
        Traffic?.Invoke("→ " + Description + " offline");
    }
}

/// The command names, shared by the serial link and the built-in device's logs.
static class AlphaSerialNaming
{
    public static string Name(byte cmd) => SerialAlphaLink.Name(cmd);
}




