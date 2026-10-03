// Copyright (c) bmgjet. All rights reserved.

namespace OkiRomSim.Calibration;

/// A Moates Demon's onboard datalogging: it asks the ECU for the datalog itself, on its own, and keeps what comes back in its dataflash - with no laptop in the car. From the Moates hardware protocol sheet (Demon, "Onboard for Demon"): 'D' 'R' ...            the request the Demon asks the ECU (the same as datalogging through it: EmulatorRelay) 'D' 'L' a b c d x (TB Tt TC1 TC2)*x chk     how often and when: a = keep every (a+1)th packet; x triggers, each the byte TB of the packet (0 is the Demon's own 'O'), a bit mask Tt (00h: none) and a range TC1..TC2 it must be in. A session is logged while every trigger holds. 'D' 'O' 'L' 'Y' / 'N'  onboard logging on / off        'D' 'O' 'L' 'y' / 'n'  the background request loop on / off 'D' 'O' 'L' 'I'        the state: 16 bytes and a checksum (sessions, the page written to, switches, chip size...) 'D' 'O' 'C' 'Y' / 'N'  compressed / plain packets       'D' 'O' 'E'  erase the dataflash ('O' after about 10 s) 'D' 'O' 'R' mmsb msb n read n pages from page mmsb:msb (256 or 512 bytes a page, by the chip), then a checksum Every command ends in the 8-bit sum of its bytes and is answered 'O'. The Demon keeps the 'D' 'R' request until it loses both USB and key-on power. The dataflash: every session starts on a fresh page with "<S>" and ends "</S>" (the rest of that page blank). A plain session is "<D>" packet "</D>" over and over, each packet the Demon's answer to 'd' ('O', the ECU's answer, the analog inputs, a footer, a checksum). A compressed one starts with one plain packet, then each packet as the bytes that changed: a count n, then n (index, value) pairs.
public sealed class DemonOnboard(IByteLink link)
{
    public int TimeoutMs { get; set; } = 700;
    public Action<Packet>? OnPacket { get; set; }

    /// The Demon's state (DOLI).
    public sealed record State(int Sessions, int PageWritten, bool Enabled, bool LoopOn, bool Compressed, bool SessionOpen, bool Full,
                               int PageSize, int Pages, int Skipped, byte[] Raw)
    {
        public long Bytes => (long)Pages * PageSize;
        public long UsedBytes => (long)PageWritten * PageSize;
    }

    /// A trigger: packet byte `At` (0 = the Demon's 'O', 1 = the ECU's first byte...) must be Low..High (and have a bit of Mask set, when Mask is not 0).
    public sealed record Trigger(int At, byte Mask, byte Low, byte High);

    /// One session read back: its packets as frames, and how they were found.
    public sealed record Session(int Number, int FirstPage, List<LogFrame> Frames, int Bad, bool Compressed, bool Cut);

    static byte[] WithSum(params byte[] b)
    {
        var r = new byte[b.Length + 1];
        b.CopyTo(r, 0);
        r[^1] = (byte)b.Sum(x => x);
        return r;
    }

    byte[] Exchange(byte[] send, int answer, string what, int timeoutMs = 0)
    {
        using var hold = link.Hold();
        link.Discard();
        link.Write(send);
        OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Tx, send, what));
        var buf = new byte[answer];
        int got = 0;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        int limit = timeoutMs > 0 ? timeoutMs : TimeoutMs;
        while (got < answer && sw.ElapsedMilliseconds < limit)
        {
            int n = link.Read(buf, got, answer - got, Math.Max(1, limit - (int)sw.ElapsedMilliseconds));
            if (n <= 0) continue;
            got += n;
        }
        var data = buf[..got];
        OnPacket?.Invoke(new Packet(DateTime.Now, PacketDir.Rx, data.Length > 64 ? data[..64] : data, got < answer ? $"{what}: {got}/{answer} bytes" : what));
        return data;
    }

    /// A command answered 'O'.
    bool Ok(string what, int timeoutMs, params byte[] cmd) => Exchange(WithSum(cmd), 1, what, timeoutMs) is [(byte)'O'];

    public State? ReadState(out string note)
    {
        var r = Exchange(WithSum((byte)'D', (byte)'O', (byte)'L', (byte)'I'), 17, "onboard state");
        if (r.Length < 17) { note = r.Length == 0 ? "no answer from the Demon (is it a Demon, on the emulator port?)" : $"a short answer ({r.Length} of 17 bytes)"; return null; }
        if ((byte)r[..16].Sum(x => x) != r[16]) { note = "the state's checksum is wrong"; return null; }
        // 0 (unused), sessions, flash page mmsb, msb, buffer page, buffer msb, lsb, loop count, log switch, loop switch, session status, session full, compression, packet skips, flash max mmsb, buffer max msb, checksum
        int pageSize = r[15] == 0 ? 256 : 512;
        int pages = (r[14] + 1) * 256;
        note = "ok";
        return new State(r[1], (r[2] << 8) | r[3], r[8] == 'Y', r[9] == 'y', r[12] == 'Y', r[10] == 'Y', r[11] == 'Y', pageSize, pages, r[13], r);
    }

    /// Onboard logging and the Demon's own request loop, on or off (both together, as the tuning software switches them).
    public bool Enable(bool on, out string note)
    {
        bool a = Ok(on ? "onboard on" : "onboard off", 0, (byte)'D', (byte)'O', (byte)'L', (byte)(on ? 'Y' : 'N'));
        bool b = Ok(on ? "request loop on" : "request loop off", 0, (byte)'D', (byte)'O', (byte)'L', (byte)(on ? 'y' : 'n'));
        note = a && b ? "ok" : !a ? $"the Demon did not take onboard {(on ? "on" : "off")}" : $"the Demon did not take the request loop {(on ? "on" : "off")}";
        return a && b;
    }

    public bool Compression(bool on) => Ok(on ? "compressed packets" : "plain packets", 0, (byte)'D', (byte)'O', (byte)'C', (byte)(on ? 'Y' : 'N'));

    /// Erase the dataflash (every session): about ten seconds.
    public bool Erase() => Ok("erase the dataflash", 20000, (byte)'D', (byte)'O', (byte)'E');

    /// What the Demon asks the ECU (the same request as datalogging through it, with its five analog inputs), and when it keeps a packet: every (skip+1)th, while every trigger holds (none: always).
    public bool Setup(RelayPlan plan, int skip, IReadOnlyList<Trigger> triggers, out string note)
    {
        var dr = new List<byte> { (byte)'D', (byte)'R', EmulatorRelay.AdcMask, EmulatorRelay.EcuBaudDivisor, 0, 0, 1, 1, (byte)(plan.Length + 1), plan.Request };
        if (!Ok("the request", 0, [.. dr])) { note = "the Demon did not take the request (D R)"; return false; }
        var dl = new List<byte> { (byte)'D', (byte)'L', (byte)Math.Clamp(skip, 0, 255), 0, 0, 0, (byte)triggers.Count };
        foreach (var t in triggers) { dl.Add((byte)t.At); dl.Add(t.Mask); dl.Add(t.Low); dl.Add(t.High); }
        if (!Ok("when to log", 0, [.. dl])) { note = "the Demon did not take the logging setup (D L)"; return false; }
        note = "ok";
        return true;
    }

    /// Read `count` pages from `first`, a few at a time; null when a read fails.
    public byte[]? ReadPages(int first, int count, int pageSize, Action<double>? progress = null)
    {
        var all = new byte[count * pageSize];
        int per = Math.Max(1, 4096 / pageSize);
        for (int at = 0; at < count; at += per)
        {
            int n = Math.Min(per, count - at), page = first + at;
            byte[]? chunk = null;
            for (int attempt = 0; attempt < 3 && chunk == null; attempt++)
            {
                var r = Exchange(WithSum((byte)'D', (byte)'O', (byte)'R', (byte)(page >> 8), (byte)page, (byte)n), (n * pageSize) + 1, $"read pages {page}-{page + n - 1}", 3000);
                if (r.Length == (n * pageSize) + 1 && (byte)r[..^1].Sum(x => x) == r[^1]) chunk = r[..^1];
            }
            if (chunk == null) return null;
            chunk.CopyTo(all, at * pageSize);
            progress?.Invoke((double)(at + n) / count);
        }
        return all;
    }

    // ---------------------------------------------------------------- the dataflash, read back

    static bool At(byte[] d, int i, string s)
    {
        if (i + s.Length > d.Length) return false;
        for (int k = 0; k < s.Length; k++) if (d[i + k] != s[k]) return false;
        return true;
    }

    /// The length of one packet for a request answered with `length` bytes before its checksum: 'O', the answer and its checksum, the five analog words, the footer and the Demon's checksum.
    public static int PacketLength(RelayPlan plan) => 1 + plan.Length + 1 + (EmulatorRelay.AnalogInputs * 2) + 1 + 1;

    /// The sessions in the dataflash read back, each packet decoded with the request's own layout and timed at `hz` packets a second (the Demon does not stamp them).
    public static List<Session> Parse(byte[] flash, int pageSize, RelayPlan plan, double hz)
    {
        int len = PacketLength(plan);
        var sessions = new List<Session>();
        for (int page = 0; page * pageSize < flash.Length; page++)
        {
            int start = page * pageSize;
            if (!At(flash, start, "<S>")) continue;
            // the session runs to "</S>", or to the next page that starts a session (power lost mid-page), or blank flash
            int end = flash.Length;
            for (int p = page + 1; p * pageSize < flash.Length; p++)
                if (At(flash, p * pageSize, "<S>") || flash.Skip(p * pageSize).Take(8).All(b => b == 0xFF)) { end = p * pageSize; break; }
            var frames = new List<LogFrame>();
            int bad = 0;
            bool compressed = false, cut = true;
            byte[]? last = null;
            int i = start + 3;
            while (i < end)
            {
                if (At(flash, i, "</S>")) { cut = false; break; }
                if (At(flash, i, "<D>") && i + 3 + len <= end)
                {
                    var pkt = flash[(i + 3)..(i + 3 + len)];
                    i += 3 + len;
                    if (At(flash, i, "</D>")) i += 4;
                    last = pkt;
                    Add(pkt);
                    continue;
                }
                if (last == null) { i++; continue; }
                // a compressed packet: n, then n (index, value) pairs on the one before
                int count = flash[i];
                if (count == 0xFF) break;
                if (count > len || i + 1 + (count * 2) > end) { i++; bad++; continue; }
                compressed = true;
                var next = (byte[])last.Clone();
                bool ok = true;
                for (int k = 0; k < count; k++)
                {
                    int idx = flash[i + 1 + (k * 2)];
                    if (idx >= len) { ok = false; break; }
                    next[idx] = flash[i + 2 + (k * 2)];
                }
                i += 1 + (count * 2);
                if (!ok) { bad++; continue; }
                last = next;
                Add(next);
            }
            sessions.Add(new Session(sessions.Count + 1, page, frames, bad, compressed, cut));

            void Add(byte[] pkt)
            {
                // 'O', the ECU's answer (checked), the analog inputs, the footer ('O'; 'T' when the ECU did not answer)
                var data = pkt[1..(1 + plan.Length)];
                if (pkt[0] != 'O' || pkt[1 + plan.Length + 1 + (EmulatorRelay.AnalogInputs * 2)] == 'T' || HondaDatalog.Checksum(data, plan.Length) != pkt[1 + plan.Length])
                { bad++; return; }
                var f = plan.Decode(data, frames.Count / Math.Max(0.1, hz));
                f.Protocol = "Demon onboard";
                for (int k = 0; k < EmulatorRelay.AnalogInputs; k++)
                {
                    int a = 2 + plan.Length + (k * 2);
                    f.Extra[$"emu_a{k + 1}_v"] = Math.Round(((pkt[a] << 8) | pkt[a + 1]) * 5.0 / 1023.0, 3);
                }
                frames.Add(f);
            }
        }
        return sessions;
    }

    /// About how many packets a second the Demon gets from the ECU for this request at 38400 baud (a byte is 10 bits, the request one byte, a little time between), kept every (skip+1)th.
    public static double EstimatedHz(RelayPlan plan, int skip) => 38400.0 / 10 / (plan.Length + 3) * 0.93 / (skip + 1);
}
