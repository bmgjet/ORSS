using OkiRomSim.Calibration;

/// `--onboard`: Demon onboard logging (DemonOnboard) against a pretend Demon with sessions in its memory - plain,
/// compressed and one cut short - and a service command through a Demon (EmulatorRelay.Command).
static class OnboardCheck
{
    const int PageSize = 256;

    sealed class FakeDemon : IByteLink
    {
        readonly Queue<byte> _out = new();
        readonly List<byte> _in = [];
        public readonly byte[] Flash = Enumerable.Repeat((byte)0xFF, 2048 * PageSize).ToArray();
        public int Sessions, PageWritten;
        public bool Enabled, Loop, Compressed;
        public byte[] LastDl = [];
        (int Len, byte Req)[] _asks = [];
        byte _adc;
        public string Name => "fake demon";
        public void Discard() => _out.Clear();
        public int Read(byte[] buffer, int offset, int count, int timeoutMs)
        {
            int n = 0;
            while (n < count && _out.Count > 0) buffer[offset + n++] = _out.Dequeue();
            return n;
        }
        void Say(params byte[] b) { foreach (var x in b) _out.Enqueue(x); }
        static bool SumOk(IReadOnlyList<byte> f) => (byte)f.Take(f.Count - 1).Sum(x => x) == f[^1];
        public void Write(byte[] data)
        {
            _in.AddRange(data);
            while (_in.Count > 0)
            {
                if (_in[0] == 'd') { _in.RemoveAt(0); Answer(); continue; }
                if (_in.Count < 2 || _in[0] != 'D') { if (_in[0] != 'D') _in.RemoveAt(0); return; }
                int total = _in[1] switch
                {
                    (byte)'R' when _in.Count >= 7 => 7 + (_in[6] * 3) + 1,
                    (byte)'L' when _in.Count >= 7 => 7 + (_in[6] * 4) + 1,
                    (byte)'O' when _in.Count >= 3 => _in[2] switch { (byte)'E' => 4, (byte)'R' => 7, _ => 5 },
                    _ => int.MaxValue,
                };
                if (_in.Count < total) return;
                var f = _in.Take(total).ToArray();
                _in.RemoveRange(0, total);
                if (!SumOk(f)) { Say((byte)'?'); continue; }
                switch ((char)f[1], (char)f[2])
                {
                    case ('R', _):
                        _asks = [.. Enumerable.Range(0, f[6]).Select(k => ((int)f[7 + (k * 3) + 1], f[7 + (k * 3) + 2]))];
                        _adc = f[2];
                        Say((byte)'O'); break;
                    case ('L', _): LastDl = f; Say((byte)'O'); break;
                    case ('O', 'E'): Array.Fill(Flash, (byte)0xFF); Sessions = 0; PageWritten = 0; Say((byte)'O'); break;
                    case ('O', 'C'): Compressed = f[3] == 'Y'; Say((byte)'O'); break;
                    case ('O', 'L') when f[3] == 'I':
                    {
                        var st = new byte[] { 0, (byte)Sessions, (byte)(PageWritten >> 8), (byte)PageWritten, 1, 0, 0, 0,
                                              (byte)(Enabled ? 'Y' : 'N'), (byte)(Loop ? 'y' : 'n'), (byte)'N', (byte)'N', (byte)(Compressed ? 'Y' : 'N'), 0, 0x07, 0x00, 0 };
                        st[16] = (byte)st.Take(16).Sum(x => x);
                        Say(st); break;
                    }
                    case ('O', 'L'):
                        if (f[3] is (byte)'Y' or (byte)'N') Enabled = f[3] == 'Y'; else Loop = f[3] == 'y';
                        Say((byte)'O'); break;
                    case ('O', 'R'):
                    {
                        int page = (f[3] << 8) | f[4], n = f[5];
                        var d = Flash.Skip(page * PageSize).Take(n * PageSize).ToArray();
                        Say(d); Say((byte)d.Sum(x => x)); break;
                    }
                    default: Say((byte)'?'); break;
                }
            }
        }
        void Answer()
        {
            var r = new List<byte> { (byte)'O' };
            foreach (var (len, req) in _asks)
            {
                if (req == 0x50 && len == 1) { r.Add(0x50); continue; }        // the ECU's answer to "clear the codes"
                var data = Frame(3000, 60);
                r.AddRange(data);
                r.Add(HondaDatalog.Checksum(data, data.Length));
            }
            for (int k = 0; k < 5; k++) if ((_adc >> k & 1) != 0) { int v = 100 * (k + 1); r.Add((byte)(v >> 8)); r.Add((byte)v); }
            r.Add((byte)'O');
            r.Add(HondaDatalog.Checksum([.. r], r.Count));
            foreach (var b in r) _out.Enqueue(b);
        }
    }

    /// A 51-byte frame at this rpm and throttle byte.
    static byte[] Frame(int rpm, int tps)
    {
        var d = new byte[HondaDatalog.FrameLength];
        int p = 1875000 / rpm;
        d[0] = 0x30; d[5] = (byte)tps; d[6] = (byte)p; d[7] = (byte)(p >> 8); d[16] = 80; d[25] = 0x9C;
        return d;
    }

    /// A packet as the Demon keeps it: 'O', the frame and its checksum, five analog words, 'O', the sum.
    static byte[] Packet(int rpm, int tps)
    {
        var r = new List<byte> { (byte)'O' };
        var d = Frame(rpm, tps);
        r.AddRange(d); r.Add(HondaDatalog.Checksum(d, d.Length));
        for (int k = 0; k < 5; k++) { int v = 100 * (k + 1); r.Add((byte)(v >> 8)); r.Add((byte)v); }
        r.Add((byte)'O');
        r.Add(HondaDatalog.Checksum([.. r], r.Count));
        return [.. r];
    }

    static int Put(FakeDemon d, int page, IEnumerable<byte> bytes)
    {
        var b = bytes.ToArray();
        b.CopyTo(d.Flash, page * PageSize);
        d.Sessions++;
        int pages = (b.Length + PageSize - 1) / PageSize;
        d.PageWritten = page + pages;
        return page + pages;
    }

    static byte[] Ascii(string s) => [.. s.Select(c => (byte)c)];

    public static int Run()
    {
        int failures = 0;
        void Check(bool ok, string what) { Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {what}"); if (!ok) failures++; }
        var plan = DatalogProtocol.ByName("Multi-byte 20h")!.Relay!;
        var demon = new FakeDemon();
        // session 1: 30 plain packets; 2: compressed, one plain then 40 changes of rpm; 3: cut short (power lost)
        var s1 = new List<byte>(Ascii("<S>"));
        for (int i = 0; i < 30; i++) { s1.AddRange(Ascii("<D>")); s1.AddRange(Packet(1000 + (i * 100), 30)); s1.AddRange(Ascii("</D>")); }
        s1.AddRange(Ascii("</S>"));
        int page = Put(demon, 0, s1);
        var s2 = new List<byte>(Ascii("<S><D>"));
        var basePkt = Packet(2000, 40);
        s2.AddRange(basePkt); s2.AddRange(Ascii("</D>"));
        var last = basePkt;
        for (int i = 1; i <= 40; i++)
        {
            var next = Packet(2000 + (i * 50), 40);
            var changed = Enumerable.Range(0, next.Length).Where(k => next[k] != last[k]).ToList();
            s2.Add((byte)changed.Count);
            foreach (var k in changed) { s2.Add((byte)k); s2.Add(next[k]); }
            last = next;
        }
        s2.AddRange(Ascii("</S>"));
        page = Put(demon, page, s2);
        var s3 = new List<byte>(Ascii("<S>"));
        for (int i = 0; i < 10; i++) { s3.AddRange(Ascii("<D>")); s3.AddRange(Packet(5000, 200)); s3.AddRange(Ascii("</D>")); }
        Put(demon, page, s3);

        var d = new DemonOnboard(demon);
        var st = d.ReadState(out var note);
        Check(st != null && st.Sessions == 3 && st.PageSize == PageSize && st.Pages == 2048, $"the state: {st?.Sessions} sessions, page {st?.PageWritten}, {st?.PageSize}-byte pages, {st?.Pages} pages ({note})");
        Check(d.Setup(plan, 1, [new(6, 0, 76, 255)], out note) && demon.LastDl is [(byte)'D', (byte)'L', 1, 0, 0, 0, 1, 6, 0, 76, 255, _], $"set up: every 2nd packet, while the throttle byte is 76 or more ({note})");
        Check(d.Compression(true) && demon.Compressed && d.Enable(true, out note) && demon.Enabled && demon.Loop, "compressed, onboard on, its loop on");
        var flash = d.ReadPages(0, st!.PageWritten, st.PageSize);
        Check(flash != null && flash.Length == st.PageWritten * PageSize, $"read back {flash?.Length} bytes");
        var sessions = DemonOnboard.Parse(flash!, st.PageSize, plan, 30);
        Check(sessions.Count == 3, $"{sessions.Count} sessions found");
        if (sessions.Count == 3)
        {
            Check(sessions[0].Frames.Count == 30 && sessions[0].Bad == 0 && !sessions[0].Compressed && !sessions[0].Cut
                  && Math.Abs(sessions[0].Frames[^1].Rpm!.Value - 3900) < 20 && Math.Abs(sessions[0].Frames[^1].T - (29 / 30.0)) < 1e-6,
                  $"session 1: {sessions[0].Frames.Count} plain samples, the last {sessions[0].Frames[^1].Rpm} rpm at {sessions[0].Frames[^1].T:0.00} s");
            Check(sessions[1].Frames.Count == 41 && sessions[1].Compressed && sessions[1].Bad == 0 && Math.Abs(sessions[1].Frames[^1].Rpm!.Value - 4000) < 20,
                  $"session 2: {sessions[1].Frames.Count} compressed samples, the last {sessions[1].Frames[^1].Rpm} rpm, {sessions[1].Bad} bad");
            Check(sessions[2].Frames.Count == 10 && sessions[2].Cut, $"session 3: {sessions[2].Frames.Count} samples, cut short: {sessions[2].Cut}");
            var a = sessions[0].Frames[0].Extra;
            Check(Math.Abs(a["emu_a1_v"] - (100 * 5.0 / 1023)) < 0.001 && Math.Abs(a["emu_a5_v"] - (500 * 5.0 / 1023)) < 0.001, "the Demon's analog inputs decoded");
        }
        Check(d.Erase() && demon.Sessions == 0 && d.ReadState(out _)?.PageWritten == 0, "erased");

        // a service command through the Demon: the command, then the frame request put back
        var relay = new EmulatorRelay(DatalogProtocol.ByName("Multi-byte 20h")!) { PostWritePauseMs = 0 };
        byte[] frameReq = [(byte)'D', (byte)'R', 0x1F, 23, 0, 0, 1, 1, 52, 0x20, 0];
        frameReq[^1] = (byte)frameReq.Take(frameReq.Length - 1).Sum(x => x);
        demon.Write(frameReq);                                                     // (the frame request, as the handshake sets it)
        demon.Discard();
        var answer = relay.Command(demon, TroubleCodes.ClearCodes, out note);
        var after = relay.Poll(demon, 0, out var pollNote);
        Check(answer == 0x50 && after != null && after.Rpm > 0, $"50h through the Demon answered {answer:X2} ({note}); a frame after it: {pollNote}");
        return failures;
    }
}
