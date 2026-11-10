using OkiRomSim.Calibration;

/// `--relay`: the datalog through a Demon (EmulatorRelay) against a pretend Demon that answers the way the established
/// tuning software expects one to: DR setups answered 'O', and 'd' answered with status, the ECU's answers, the analog
/// words, a byte and a checksum.
static class RelayCheck
{
    sealed class FakeDemon : IByteLink
    {
        readonly Queue<byte> _out = new();
        readonly List<byte> _in = [];
        (int Len, byte Req)[] _asks = [];
        byte _adc;
        public bool EcuOff;
        public string Name => "fake demon";
        public void Discard() => _out.Clear();
        public int Read(byte[] buffer, int offset, int count, int timeoutMs)
        {
            int n = 0;
            while (n < count && _out.Count > 0) buffer[offset + n++] = _out.Dequeue();
            return n;
        }
        public void Write(byte[] data)
        {
            _in.AddRange(data);
            while (_in.Count > 0)
            {
                if (_in[0] == 'd') { _in.RemoveAt(0); Answer(); continue; }
                if (_in.Count >= 7 && _in[0] == 'D' && _in[1] == 'R')
                {
                    int n = _in[6], total = 7 + (n * 3) + 1;
                    if (_in.Count < total) return;
                    var frame = _in.Take(total).ToArray();
                    _in.RemoveRange(0, total);
                    if (HondaDatalog.Checksum(frame, total - 1) != frame[^1]) { _out.Enqueue((byte)'?'); continue; }
                    _adc = frame[2];
                    _asks = [.. Enumerable.Range(0, n).Select(k => ((int)frame[7 + (k * 3) + 1], frame[7 + (k * 3) + 2]))];
                    _out.Enqueue((byte)'O');
                    continue;
                }
                return;
            }
        }
        void Answer()
        {
            var r = new List<byte> { 0x44 };
            foreach (var (len, req) in _asks)
            {
                if (EcuOff) { r.AddRange(Enumerable.Repeat((byte)0x54, len)); continue; }
                if (req == 0x10 && len == 1) { r.Add(0xCD); continue; }
                var data = Enumerable.Range(0, len - 1).Select(i => (byte)(i * 3)).ToArray();
                data[0] = 0x40; data[1] = 0x1F;          // a crank period, so rpm is not zero
                r.AddRange(data);
                r.Add(HondaDatalog.Checksum(data, data.Length));
            }
            for (int k = 0; k < 5; k++) if ((_adc >> k & 1) != 0) { int v = 200 * (k + 1); r.Add((byte)(v >> 8)); r.Add((byte)v); }
            r.Add(0);
            r.Add(HondaDatalog.Checksum([.. r], r.Count));
            foreach (var b in r) _out.Enqueue(b);
        }
    }

    public static int Run()
    {
        int failures = 0;
        void Check(bool ok, string what) { Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {what}"); if (!ok) failures++; }

        var inner = DatalogProtocol.ByName("Multi-byte 20h")!;
        var relay = new EmulatorRelay(inner) { PostWritePauseMs = 0 };
        var demon = new FakeDemon();
        Check(relay.Handshake(demon, out var note), "handshake through the Demon: " + note);
        var f = relay.Poll(demon, 1.5, out note);
        Check(f != null, "frame through the Demon: " + note);
        if (f != null)
        {
            Check(f.Raw?.Length == HondaDatalog.FrameLength, $"frame is {HondaDatalog.FrameLength} bytes ({f.Raw?.Length})");
            Check(f.Rpm > 0, $"rpm decoded ({f.Rpm})");
            Check(f.Extra.TryGetValue("emu_a1_v", out var a1) && Math.Abs(a1 - (200 * 5.0 / 1023)) < 0.01, $"analog 1 = {a1} V");
            Check(f.Extra.TryGetValue("emu_a5_v", out var a5) && Math.Abs(a5 - (1000 * 5.0 / 1023)) < 0.01, $"analog 5 = {a5} V");
        }
        var off = new FakeDemon { EcuOff = true };
        Check(!new EmulatorRelay(inner) { PostWritePauseMs = 0, Retries = 0 }.Handshake(off, out note) && note.Contains("ECU"), "ECU off is reported: " + note);
        Check(EmulatorRelay.Candidates().Any(p => p.Name == "Multi-byte 90h") && EmulatorRelay.Candidates().All(p => p.Relay != null), "candidates");
        Console.WriteLine(failures == 0 ? "ALL PASS" : $"{failures} FAILED");
        return failures == 0 ? 0 : 1;
    }
}
