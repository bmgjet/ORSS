// Detects the CPU spinning on a handful of addresses, works out what it waits for, and makes it happen if allowed.
// Two kinds of spin, distinguished by watching reads while the loop runs (not from a fixed table):
//   * A DELAY loop spins on a register the CPU decrements, so it always terminates; fast-forward it.
//   * A POLL loop spins on a value the CPU never writes; nudge whatever it reads and report it, since a
//     nudged address is a hardware signal this model does not yet understand.

namespace OkiRomSim.Core;

/// One intervention, for the end-of-run report.
public sealed class StallEvent
{
    public ulong AtInstruction;
    public ushort Pc;
    public string Kind = "";        // "delay" | "poll" | "unresolved"
    public string Action = "";      // what was done about it
    public ushort[] LoopPcs = Array.Empty<ushort>();
    public ushort[] PolledAddresses = Array.Empty<ushort>();

    public override string ToString() =>
        $"{AtInstruction,12:N0}  {Pc:X4}  {Kind,-10}  {Action}";
}

public sealed class StallMonitor
{
    /// How many consecutive instructions confined to a small address set before the loop is called suspicious. A real delay loop hits this almost immediately; ordinary code never does.
    public int SpinThreshold = 20_000;

    /// How many distinct addresses still counts as "a loop" rather than "running normally". The boot delay loop is 2; the largest wait loop in this ROM (the A/D mux scan, including its subroutine call) is ~40.
    public int MaxLoopAddresses = 64;

    /// Collapse delay loops by writing a near-zero value into the counter the loop decrements. Costs nothing in fidelity -- the loop exits at the same instruction it always would -- and turns the boot A/D scan from ~1.05M instructions into a few hundred.
    public bool FastForwardDelayLoops = true;

    /// Flip unmapped input pins when a poll loop is stuck on a port read.
    public bool NudgeUnmappedPins = true;

    /// Last resort: if a poll loop survives several nudges and is stuck on a plain (non-port, non-modeled) SFR or RAM byte, invert that byte. This *will* diverge from real hardware, so it is off unless you are doing a coverage sweep and care more about reaching code than about the state being physical.
    public bool ForceUnstickMemory;

    public readonly List<StallEvent> Events = new();

    /// Addresses StallMonitor must never write. Everything Bus actually simulates lives here: touching it would overwrite real modeled state with noise and make the run meaningless.
    private static readonly HashSet<ushort> Protected = BuildProtectedSet();

    private static HashSet<ushort> BuildProtectedSet()
    {
        var s = new HashSet<ushort>();
        void Range(ushort start, int len) { for (int i = 0; i < len; i++) s.Add((ushort)(start + i)); }

        Range(0x0000, 8);                 // SSP, LRB, PSW, ACC
        Range(Bus.SfrIrq, 2);
        Range(Bus.SfrIe, 2);
        Range(Bus.SfrExion, 2);
        Range(Bus.SfrP0, 16);             // P0..P4 data/mode/sf
        Range(Bus.SfrTm0, 16);            // TM0..TMR3
        Range(Bus.SfrTcon0, 4);
        s.Add(Bus.SfrTrns);
        s.Add(Bus.SfrAdscan);
        s.Add(Bus.SfrAdsel);
        Range(Bus.SfrAdcr0, 16);
        Range(Bus.SfrPwmc0, 12);          // PWM counters/registers/controls
        s.Add(Bus.SfrSrbuf);
        s.Add(Bus.SfrStbuf);
        s.Add(Bus.SfrWdt);
        Range(0x0080, 64);                // pointing register sets PR0..PR7
        return s;
    }

    // ---- spin detection state ---------------------------------------------
    private readonly Dictionary<ushort, int> _loopPcs = new();
    private readonly HashSet<ushort> _readsDuringSpin = new();
    private readonly Dictionary<ushort, int> _nudgeAttempts = new();
    private int _spinLength;
    private bool _collecting;

    public void Reset()
    {
        _loopPcs.Clear();
        _readsDuringSpin.Clear();
        _nudgeAttempts.Clear();
        _spinLength = 0;
        _collecting = false;
        Events.Clear();
    }

    /// Hook this to Bus.OnDataRead while a spin is being characterised.
    public void NoteRead(ushort addr)
    {
        if (_collecting && _readsDuringSpin.Count < 256) _readsDuringSpin.Add(addr);
    }

    /// Call once per instruction, before stepping. Returns true if it intervened this instruction (the caller need not do anything differently -- it is only for logging).
    public bool Observe(Cpu cpu, Bus bus, Board? board, ulong instructionCount)
    {
        ushort pc = cpu.Pc;

        if (_loopPcs.TryGetValue(pc, out int seen))
        {
            _loopPcs[pc] = seen + 1;
            _spinLength++;
        }
        else if (_loopPcs.Count < MaxLoopAddresses)
        {
            _loopPcs[pc] = 1;
            _spinLength++;
        }
        else
        {
            // Wandered outside the candidate loop: not a spin after all.
            ResetSpin(pc);
            return false;
        }

        // Once we are fairly sure this is a loop, start recording what it
        // reads so we know what it is waiting on.
        if (!_collecting && _spinLength > SpinThreshold / 2)
        {
            _collecting = true;
            _readsDuringSpin.Clear();
        }

        if (_spinLength < SpinThreshold) return false;

        bool acted = Intervene(cpu, bus, board, instructionCount);
        // Restart the window either way: if the intervention worked we will
        // leave the loop; if it did not, we get another go one window later
        // and escalate.
        ResetSpin(pc);
        return acted;
    }

    private void ResetSpin(ushort pc)
    {
        _loopPcs.Clear();
        _loopPcs[pc] = 1;
        _spinLength = 1;
        _collecting = false;
        _readsDuringSpin.Clear();
    }

    private bool Intervene(Cpu cpu, Bus bus, Board? board, ulong instructionCount)
    {
        var loop = _loopPcs.Keys.OrderBy(a => a).ToArray();
        var ev = new StallEvent
        {
            AtInstruction = instructionCount,
            Pc = cpu.Pc,
            LoopPcs = loop,
            PolledAddresses = _readsDuringSpin.OrderBy(a => a).ToArray(),
        };

        // --- 1. A counted delay loop? ---------------------------------------
        if (FastForwardDelayLoops && TryFastForwardDelayLoop(cpu, bus, loop, out string what))
        {
            ev.Kind = "delay";
            ev.Action = $"fast-forwarded {what}";
            Events.Add(ev);
            return true;
        }

        // --- 2. Waiting on a port pin? --------------------------------------
        if (NudgeUnmappedPins && board != null &&
            TryNudgePort(bus, board, out string pin))
        {
            ev.Kind = "poll";
            ev.Action = $"nudged {pin} (no confirmed board mapping)";
            Events.Add(ev);
            return true;
        }

        // --- 3. Waiting on some other location ------------------------------
        if (ForceUnstickMemory && TryForceMemory(bus, out string loc))
        {
            ev.Kind = "poll";
            ev.Action = $"forced {loc} (NOT physical -- coverage mode)";
            Events.Add(ev);
            return true;
        }

        if (Events.Count > 20_000) Events.RemoveRange(0, 10_000);
        ev.Kind = "unresolved";
        ev.Action = _readsDuringSpin.Count == 0
            ? "loop reads nothing external; it may simply be very long"
            : "polls " + string.Join(",", ev.PolledAddresses.Take(8).Select(a => a.ToString("X3")));
        Events.Add(ev);
        return false;
    }

    /// A loop of a few addresses containing a JRNZ is a counted delay. Write 1 into the register it decrements so the next pass falls through.
    private bool TryFastForwardDelayLoop(Cpu cpu, Bus bus, ushort[] loop, out string what)
    {
        what = "";
        if (loop.Length > 6) return false;

        foreach (ushort pc in loop)
        {
            var d = Decoder.Decode(cpu.Dd, i => bus.ReadCodeU8((ushort)(pc + i)));
            if (d == null || !d.Mnemonic.StartsWith("JRNZ", StringComparison.Ordinal)) continue;

            // "JRNZ DP, rel8" / "JRNZ erN, rel8" / "JRNZ rN, rel8"
            string operand = d.Mnemonic[4..].TrimStart().Split(',')[0].Trim();
            if (WriteCounter(cpu, bus, operand, 1))
            {
                what = $"{operand} at {pc:X4}";
                return true;
            }
        }
        return false;
    }

    private static bool WriteCounter(Cpu cpu, Bus bus, string operand, ushort value)
    {
        // Pointing registers live in RAM at 0x80 + SCB*8.
        int slot = operand switch { "X1" => 0, "X2" => 2, "DP" => 4, "USP" => 6, _ => -1 };
        if (slot >= 0)
        {
            bus.WriteDataU16((ushort)(0x0080 + cpu.Scb() * 8 + slot), value);
            return true;
        }
        if (operand.Length >= 2 && operand[0] == 'r' && char.IsDigit(operand[1]))
        {
            bus.WriteDataU8((ushort)(cpu.BankBase() + (operand[1] - '0')), (byte)value);
            return true;
        }
        if (operand.StartsWith("er", StringComparison.Ordinal) && operand.Length >= 3 &&
            char.IsDigit(operand[2]))
        {
            bus.WriteDataU16((ushort)(cpu.BankBase() + (operand[2] - '0') * 2), value);
            return true;
        }
        if (operand == "A") { cpu.A = value; return true; }
        return false;
    }

    /// If the spinning loop read a port data register, flip one of that port's unmapped input bits. Preference goes to a bit the ROM has actually configured as an input -- an output bit cannot be what the loop is waiting for.
    private bool TryNudgePort(Bus bus, Board board, out string pin)
    {
        pin = "";
        var portAddrs = new (ushort data, ushort mode, int index)[]
        {
            (Bus.SfrP0, Bus.SfrP0Io, 0), (Bus.SfrP1, Bus.SfrP1Io, 1),
            (Bus.SfrP2, Bus.SfrP2Io, 2), (Bus.SfrP3, Bus.SfrP3Io, 3),
            (Bus.SfrP4, Bus.SfrP4Io, 4),
        };

        foreach (var (data, mode, index) in portAddrs)
        {
            if (!_readsDuringSpin.Contains(data)) continue;
            byte dir = bus.Ram[mode];
            for (int bit = 0; bit < 8; bit++)
            {
                if ((dir & (1 << bit)) != 0) continue;     // configured as output
                if (board.IsMapped(index, bit)) continue;  // physics, not ours to flip
                if (!board.Nudge(index, bit)) continue;
                board.Apply(bus);
                pin = $"P{index}.{bit}";
                return true;
            }
        }
        return false;
    }

    /// Invert a non-modeled byte the loop keeps reading. Tries each candidate once before moving on, so a loop reading several addresses gets each one tried rather than the first one flipped repeatedly.
    private bool TryForceMemory(Bus bus, out string loc)
    {
        loc = "";
        foreach (ushort addr in _readsDuringSpin.OrderBy(a => a))
        {
            if (Protected.Contains(addr)) continue;
            _nudgeAttempts.TryGetValue(addr, out int tries);
            if (tries > 4) continue;
            _nudgeAttempts[addr] = tries + 1;
            byte cur = bus.Ram[addr & (Bus.RamSize - 1)];
            bus.WriteDataU8(addr, (byte)~cur);
            loc = $"{addr:X3}h {cur:X2}->{(byte)~cur:X2}";
            return true;
        }
        return false;
    }

    /// One line per distinct (site, kind, action), with a count. A loop that is fast-forwarded on every pass through its outer wait would otherwise produce hundreds of identical lines and bury the one site that is genuinely unresolved.
    public string Report(Func<ushort, string>? symbolAt = null)
    {
        if (Events.Count == 0) return "No stalls detected.";

        var grouped = Events
            .GroupBy(e => (e.Pc, e.Kind, e.Action))
            .Select(g => new
            {
                g.Key.Pc,
                g.Key.Kind,
                g.Key.Action,
                Count = g.Count(),
                First = g.Min(e => e.AtInstruction),
                Polled = g.First().PolledAddresses,
            })
            .OrderBy(x => x.First)
            .ToList();

        var sb = new System.Text.StringBuilder();
        int unresolved = grouped.Count(g => g.Kind == "unresolved");
        sb.AppendLine($"{Events.Count} stall event(s) at {grouped.Count} distinct site(s); " +
                      $"{unresolved} unresolved.");
        sb.AppendLine("     first-seen    pc  count  kind        action");
        foreach (var g in grouped)
        {
            string label = symbolAt?.Invoke(g.Pc) ?? "";
            sb.AppendLine($"  {g.First,12:N0}  {g.Pc:X4}  {g.Count,5}  {g.Kind,-10}  {g.Action}" +
                          (label.Length > 0 ? $"   [{label}]" : ""));
        }
        return sb.ToString();
    }
}
