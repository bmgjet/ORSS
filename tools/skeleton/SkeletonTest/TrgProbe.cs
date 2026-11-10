// --only trgprobe2 (P13): the trigger log's captures taken over the datalog stream as the app takes them, every
// instruction watched: each TDC edge the simulator makes, each change of the TDC latch (TRNSIT.7) and of SKEL_TRG, each
// crank tooth the hook sees. A capture with other than 4 TDC pulses is printed with its log.
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

static class TrgProbe
{
    /// The simulator's serial port, as DatalogLayout.SimLink, with a look at every instruction.
    sealed class MonLink(Simulator sim, Action<Simulator, int> step) : IByteLink
    {
        readonly Queue<byte> _rx = new();
        uint _byteCycles = (uint)(Bus.CpuHz * 10 / 38400);
        public string Name => "monitored simulator";
        bool Step()
        {
            int pc = sim.Cpu.Pc;
            if (sim.StepOne() == null) return false;
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
            step(sim, pc);
            return true;
        }
        public void Run(double seconds)
        {
            ulong end = sim.Cpu.Cycles + (ulong)(seconds * Bus.CpuHz);
            while (sim.Cpu.Cycles < end && Step()) { }
            foreach (var b in sim.Bus.TakeSerialTx()) _rx.Enqueue(b);
        }
        public void Write(byte[] data) => sim.Bus.QueueSerialRx(data, _byteCycles);
        public int Read(byte[] buffer, int offset, int count, int timeoutMs)
        {
            ulong end = sim.Cpu.Cycles + (ulong)(timeoutMs / 1000.0 * Bus.CpuHz);
            while (_rx.Count < count && sim.Cpu.Cycles < end)
            {
                for (int i = 0; i < 2000 && Step(); i++) { }
                foreach (var b in sim.Bus.TakeSerialTx()) _rx.Enqueue(b);
            }
            int n = 0;
            while (n < count && _rx.Count > 0) buffer[offset + n++] = _rx.Dequeue();
            return n;
        }
        public void Discard() { Run(0.002); _rx.Clear(); }
        public void Wait(int ms) => Run(ms / 1000.0);
        public void SetBaud(int baud) { if (!sim.Bus.SerialEcho) _byteCycles = (uint)(Bus.CpuHz * 10 / (ulong)Math.Max(300, baud)); }
    }

    public static void Run(RunResult r, int rpm)
    {
        var sim = r.Sim; var sy = r.Asm.Symbols;
        int Sym(string n) => (int)sy.Values.First(x => x.Name.Equals(n, StringComparison.OrdinalIgnoreCase)).Value;
        int hook = Sym("skel_ckp_hook");
        var names = sy.Values.Where(x => x.Kind == SymbolKind.Label).GroupBy(x => (int)x.Value).ToDictionary(g => g.Key, g => g.First().Name);
        string Where(int pc) { for (int a = pc; a > pc - 80; a--) if (names.TryGetValue(a, out var n)) return $"{n}+{pc - a}"; return $"{pc:X4}"; }
        var log = new List<string>();
        byte lastTr = 0, lastTrg = 0; int teeth = 0;
        var lk = new MonLink(sim, (s, pc) =>
        {
            byte tr = s.Bus.Ram[0x29], trg = s.Bus.Ram[0xFA];
            if (pc == hook) log.Add($"T{++teeth} tr{lastTr >> 7} trg{lastTrg:X2}");
            if ((tr & 0x80) != (lastTr & 0x80)) log.Add((tr & 0x80) != 0 ? "  TDC+" : $"  tdc- @{Where(pc)}");
            if (trg != lastTrg) log.Add($"  trg {lastTrg:X2}->{trg:X2} @{Where(pc)}");
            lastTr = tr; lastTrg = trg;
            if (log.Count > 4000) log.RemoveRange(0, 2000);
        });
        ChannelStream.Selected = ["rpm", "map", "tps"];
        var cs = new ChannelStream { PostWritePauseMs = 0 };
        bool hs = false;
        for (int i = 0; i < 5 && !hs; i++) hs = cs.Handshake(lk, out _);
        int bad = 0;
        for (int k = 0; k < 30 && bad < 2; k++)
        {
            log.Clear(); teeth = 0;
            var p = cs.CaptureTrigger(lk, out var note);
            if (p == null) { Console.WriteLine($"capture {k}: none ({note})"); continue; }
            int tdcs = p.All.Count(t => t.Tdc);
            if (tdcs != 4 || p.Analyse().Count > 0)
            {
                bad++;
                Console.WriteLine($"capture {k}: {tdcs} TDC [{string.Join(" ", p.All.Select(t => $"{t.Scaled}{(t.Tdc ? "T" : "")}{(t.Cyp ? "C" : "")}"))}]");
                Console.WriteLine(string.Join("\n", log.Where(x => !x.StartsWith("  trg") || true).TakeLast(400)));
            }
            cs.Poll(lk, 0, out _);
        }
        Console.WriteLine($"trgprobe2: handshake {hs}, {bad} bad");
    }
}
