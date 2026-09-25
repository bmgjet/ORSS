// Copyright (c) bmgjet. All rights reserved.
// Top-level glue tying Cpu + Bus + EngineState + InterruptController into a runnable simulator. The core step/tick/interrupt loop is:
//
// before = cpu.Cycles ExecStep.Step(cpu, bus) timerIrq = bus.TickTimers(cpu.Cycles - before) distIrq = engine.CheckDistributorPulses(bus, cpu.Cycles, Bus.CpuHz) InterruptController.HandlePendingInterrupts(cpu, bus, timerIrq | distIrq)

using System.Diagnostics.CodeAnalysis;

namespace OkiRomSim.Core;

public enum RunState { Stopped, Running, Halted, Faulted }

/// One decoded+executed instruction, for a live disassembly/trace view.
public readonly struct TraceEntry
{
    public readonly ushort Pc;
    private readonly ushort _pcAfter;
    private readonly string? _prefix;
    public TraceEntry(ushort pc, string text) { Pc = pc; Text = text; Decoded = null; _pcAfter = 0; _prefix = null; }
    /// Lazily formatted: formatting every executed instruction cost more than executing it.
    public TraceEntry(ushort pc, Decoded d, ushort pcAfter, string? prefix = null)
    { Pc = pc; Text = null; Decoded = d; _pcAfter = pcAfter; _prefix = prefix; }
    public Decoded? Decoded { get; }

    [AllowNull]
    public string Text => field ?? (_prefix + (Decoded == null ? "" : Decoder.Format(Decoded, _pcAfter)));
}

public sealed class Simulator
{
    public readonly Cpu Cpu = new();
    public readonly Bus Bus = new();
    public readonly EngineState Engine = new();

    /// The harness outside the chip. Without one, every pin the ROM configures as an input reads 0 forever and any poll on it hangs.
    public readonly Board Board = new();

    /// The check-engine lamp and the codes it flashes, sampled as the ROM runs.
    public readonly MilMonitor Mil = new();

    /// Executed-address and branch-edge coverage. Always collected -- it costs an array index per instruction.
    public readonly Coverage Coverage = new();

    /// Watches for busy-wait loops and, where it safely can, ends them. See StallMonitor for the delay-versus-poll distinction.
    public readonly StallMonitor Stalls = new();

    /// Set true to let StallMonitor act. Off by default so existing runs behave exactly as before; the coverage harness turns it on.
    public bool StallInterventionEnabled;
    /// Called for every data-space read an instruction makes (not the timer block's own reads) - for tools that map which RAM a ROM uses.
    public Action<ushort>? DataReadHook;

    /// Byte-level ROM overrides applied after every load, as addr -> value. Survives reload, which is what makes it useful for working around a blanked region while you iterate on the .asm.
    public readonly Dictionary<ushort, byte> RomPatches = [];

    /// Force a conditional branch at a given address to always go one way. The instruction still costs its normal cycles; only the outcome is decided for it. Use this to steer past a dead end whose real selecting condition you have not reconstructed yet.
    public readonly Dictionary<ushort, bool> ForcedBranches = [];

    /// Every BRK the ROM executes, keyed by (site, trapReasonCode). The ROM writes a reason byte to 0xF5 immediately before most of its BRKs and int_break reads it back to choose a recovery path, so this table says not just "it trapped" but which self-test or guard rejected the run. That is usually the fastest route to why a boot never completes.
    public readonly Dictionary<(ushort Pc, byte Reason), long> TrapLog = [];

    /// Zero-page byte the ROM uses as its trap reason sentinel. Not the same in every ROM (0xF5 in HTS115 and p08, 0xEB in CromeGold and p30, 0xD4 in the P13), so it is read off the ROM's own watchdog handler on load: every one starts "MOVB reason, #44h/48h" (C5 nn 98 ii).
    public ushort TrapReasonCodeAddr { get; private set; } = 0x00F5;

    void DetectTrapReasonAddr()
    {
        int wdt = Bus.ReadCodeU16(0x0004);
        TrapReasonCodeAddr = wdt + 3 < Bus.Rom.Length && Bus.Rom[wdt] == 0xC5 && Bus.Rom[wdt + 2] == 0x98
            ? Bus.Rom[wdt + 1] : (ushort)0x00F5;
    }

    private static readonly string[] ConditionalBranches =
        { "JEQ", "JNE", "JLT", "JLE", "JGT", "JGE", "JBS", "JBR", "JRNZ" };

    public RunState State { get; private set; } = RunState.Stopped;

    /// True when the last step ended by entering an interrupt handler (the handler's frame was pushed after the instruction ran). Debuggers use it to keep a call stack.
    public bool LastStepInterrupted { get; private set; }
    public string? FaultMessage { get; private set; }

    // ---- Hot-address tracking ------------------------------------------ Detects "the CPU is stuck cycling through a small set of addresses" (e.g. a busy-wait it never escapes, or -- as with a ROM that has a redacted code region it BRK-traps into -- a boot sequence that keeps re-entering itself) by counting PC hits over a bounded, sliding window of the most recent instructions, rather than an all-time count that would dilute a loop that starts appearing partway through a long run. Address space is exactly 32,768 entries (RomSize), so a plain array is both the simplest and cheapest structure -- no need for a dictionary.
    private readonly uint[] _pcWindowCounts = new uint[0x10000];   // PC is 16 bit: a runaway ROM can execute outside ROM and the tracker must survive it
    private ushort[] _pcWindowRing = new ushort[50_000];
    private int _pcWindowHead;
    private int _pcWindowFilled;

    /// How many of the most recent instructions the hot-address detector considers. Changing this reallocates and resets the tracker.
    public int HotAddressWindowSize
    {
        get;
        set
        {
            int clamped = Math.Clamp(value, 100, 1_000_000);
            if (clamped == field) return;
            field = clamped;
            _pcWindowRing = new ushort[clamped];
            Array.Clear(_pcWindowCounts);
            _pcWindowHead = 0;
            _pcWindowFilled = 0;
        }
    } = 50_000;

    private void RecordPcForHotAddressTracking(ushort pc)
    {
        if (_pcWindowFilled == _pcWindowRing.Length)
        {
            ushort evicted = _pcWindowRing[_pcWindowHead];
            _pcWindowCounts[evicted]--;
        }
        else
        {
            _pcWindowFilled++;
        }
        _pcWindowRing[_pcWindowHead] = pc;
        _pcWindowCounts[pc]++;
        _pcWindowHead = (_pcWindowHead + 1) % _pcWindowRing.Length;
    }

    /// The most-executed address within the current sliding window, its hit count, and how many instructions the window currently holds (less than HotAddressWindowSize right after a Reset/load, until it fills). Address/Count are 0 if nothing has executed yet.
    public (ushort Address, uint Count, int WindowFilled) GetHottestRecentPc()
    {
        ushort best = 0;
        uint bestCount = 0;
        for (int i = 0; i < _pcWindowCounts.Length; i++)
        {
            if (_pcWindowCounts[i] > bestCount) { bestCount = _pcWindowCounts[i]; best = (ushort)i; }
        }
        return ((ushort)best, bestCount, _pcWindowFilled);
    }

    /// Label -> address table parsed from the loaded .asm source, if the ROM was loaded via LoadAsmFile/LoadRomOrAsmFile with a .asm path. Null for a raw .bin/.rom load, or a .asm file with no recognizable labels.
    public IReadOnlyDictionary<string, ushort>? Symbols { get; private set; }

    /// Addresses where Run should stop before executing the instruction there (Step always ignores breakpoints -- it means "execute exactly one instruction regardless"). Empty by default.
    public HashSet<ushort> Breakpoints { get; } = [];

    /// Addresses of jump/branch/call instructions to neutralize: when PC reaches one, that single instruction is treated as if it weren't there at all -- no PC redirect, no register/flag/stack side effects -- and execution just falls through to the next instruction in memory. Applies to Run *and* Step alike, unlike Breakpoints (which Step always bypasses); ignoring a jump is a standing patch to how the program behaves, not a one-shot pause. Meant for working around a branch that traps you in a loop you don't want (e.g. a self-test retry loop) -- it still costs the instruction's normal cycle count, so timers/interrupts keep advancing normally through it.
    public HashSet<ushort> IgnoredJumps { get; } = [];

    /// Resolve a breakpoint address the user typed: a hex address (with or without "0x"/"h"), or -- if a .asm was loaded -- a label name looked up in Symbols. Returns false with addr=0 if neither resolves.
    public bool TryResolveAddress(string text, out ushort addr)
    {
        addr = 0;
        var t = text.Trim();
        if (t.Length == 0) return false;

        var hex = t;
        if (hex.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) hex = hex[2..];
        else if (hex.EndsWith('h') || hex.EndsWith('H')) hex = hex[..^1];
        if (ushort.TryParse(hex, System.Globalization.NumberStyles.HexNumber,
                System.Globalization.CultureInfo.InvariantCulture, out addr))
        {
            return true;
        }

        return Symbols != null && Symbols.TryGetValue(t, out addr);
    }

    /// Symbol name for an address, if one is known ("" if not). For annotating the trace/breakpoint list, not for resolution.
    public string SymbolAt(ushort address)
    {
        if (Symbols == null) return "";
        foreach (var (name, addr) in Symbols)
            if (addr == address) return name;
        return "";
    }

    /// Reset vector fetched from ROM at 0x0000.
    public void Reset()
    {
        Bus.PowerOnReset();
        Engine.ResetTiming();
        Mil.Reset();
        Board.Reset();
        Board.Apply(Bus);
        Stalls.Reset();
        Coverage.Reset();
        TrapLog.Clear();
        var cpu = Cpu;
        cpu.Pc = Bus.ReadCodeU16(0x0000);
        cpu.A = 0; cpu.Lrb = 0; cpu.Ssp = 0x07FE;
        cpu.Cf = cpu.Zf = cpu.Hc = cpu.Dd = false;
        cpu.PswOther = 0;
        cpu.Cycles = 0; cpu.Instructions = 0; cpu.Halted = false;
        State = RunState.Stopped;
        FaultMessage = null;
        Array.Clear(_pcWindowCounts);
        _pcWindowHead = 0;
        _pcWindowFilled = 0;
    }

    public void LoadRom(byte[] romImage)
    {
        Bus.LoadRomBytes(romImage);
        ApplyRomPatches();
        DetectTrapReasonAddr();
        Symbols = null;
        Reset();
    }

    /// Re-apply RomPatches over the loaded image. Called automatically on load; call it again by hand if you add patches afterwards.
    public void ApplyRomPatches()
    {
        InvalidateDecodeCache();
        foreach (var (addr, val) in RomPatches)
        {
            if (addr < Bus.RomSize) Bus.Rom[addr] = val;
        }
    }

    public void LoadRomFile(string path)
    {
        Bus.LoadRomFile(path);
        InvalidateDecodeCache();
        ApplyRomPatches();
        Symbols = null;
        Reset();
    }

    /// Assemble a .asm source file and load the resulting image. Throws AssemblerException on any assembly failure, with the assembler's own line-numbered diagnostics where available.
    public void LoadAsmFile(string path)
    {
        byte[] image = AsmAssembler.Assemble(path, out var realSymbols);
        LoadRom(image);
        // Prefer the real assembler-derived symbol table: it comes from the assembler's own two-pass label resolution, so it works even on a .asm with no per-line address comments at all. Fall back to the text-scraping parser only when no symbol table was produced.
        Symbols = realSymbols ?? AsmSymbols.Parse(path);
    }

    /// Load either a .bin/.rom image or .asm source, dispatching on the file extension. Convenience wrapper for a single "Load ROM" UI action.
    public void LoadRomOrAsmFile(string path)
    {
        string ext = System.IO.Path.GetExtension(path);
        if (ext.Equals(".asm", StringComparison.OrdinalIgnoreCase))
            LoadAsmFile(path);
        else
            LoadRomFile(path);
    }

    /// Push the current EngineState sensor values onto the bus's ADC inputs. Call this once per UI tick (or scenario change), not per instruction.
    public void SyncSensors()
    {
        Board.Apply(Bus);
        Engine.SyncSensorsToBus(Bus);
    }

    /// Execute a single instruction and process the peripheral/interrupt tick that follows it. Returns the trace text, or null if the CPU is not in a runnable state.
    public TraceEntry? StepOne()
    {
        if (State == RunState.Faulted) return null;

        ushort pcBefore = Cpu.Pc;
        if (FastForwardDelayLoops) TryFastForwardDelayLoop(pcBefore);
        RecordPcForHotAddressTracking(pcBefore);
        Coverage.RecordExecution(pcBefore, Cpu.Cycles + 1);
        Bus.NowCycles = Cpu.Cycles;

        if (StallInterventionEnabled)
        {
            Stalls.Observe(Cpu, Bus, Board, Cpu.Instructions);
        }

        if (ForcedBranches.TryGetValue(pcBefore, out bool forceTaken))
        {
            var forced = TryStepForcedBranch(pcBefore, forceTaken);
            if (forced != null) return forced;
        }

        if (IgnoredJumps.Contains(pcBefore))
        {
            var ignored = TryStepIgnoredJump(pcBefore);
            if (ignored != null) return ignored;
            // Couldn't even decode an instruction here (e.g. the address points at garbage) -- fall through to the normal path below so the real undefined-opcode fault surfaces instead of silently doing nothing.
        }

        ulong before = Cpu.Cycles;
        Decoded d;
        bool branchTaken;
        // Only reads the *instruction* makes are interesting to StallMonitor. TickTimers reads IRQ/IE/TM/PWM on every step, and letting those into the poll set would make every stall look like it was waiting on the timer block.
        Bus.OnDataRead = StallInterventionEnabled ? DataReadHook + Stalls.NoteRead : DataReadHook;
        try
        {
            d = DecodeCached(pcBefore);
            Bus.CurrentPc = pcBefore;
            ExecStep.Execute(Cpu, Bus, d, out branchTaken);
        }
        catch (ExecException ex)
        {
            State = RunState.Faulted;
            FaultMessage = ex.Message;
            return new TraceEntry(pcBefore, $"** {ex.Message} **");
        }

        finally
        {
            Bus.OnDataRead = null;   // TickTimers' own reads stay out of both
        }

        if ((Cpu.Instructions & 255) == 0) Mil.Sample(Bus, Cpu.Cycles);   // ~0.3 ms: the shortest flash is 310 ms
        if (IsConditionalBranch(d)) Coverage.RecordBranch(pcBefore, branchTaken);
        if (IsBrk(d))
        {
            var key = (pcBefore, Bus.Ram[TrapReasonCodeAddr]);
            TrapLog.TryGetValue(key, out long n);
            TrapLog[key] = n + 1;
        }

        uint delta = (uint)(Cpu.Cycles - before);
        ushort timerIrq = Bus.TickTimers(delta);
        ushort distIrq = Engine.CheckDistributorPulses(Bus, Cpu.Cycles, Bus.CpuHz);
        LastStepInterrupted = InterruptController.HandlePendingInterrupts(Cpu, Bus, (ushort)(timerIrq | distIrq),
            accept: !d.Mnemonic.StartsWith("RTI", StringComparison.Ordinal));

        // rel8 targets are relative to the address *after* the instruction, not to wherever a taken branch just landed.
        return new TraceEntry(pcBefore, d, (ushort)(pcBefore + d.Len));
    }

    /// Skip the bulk of pure time-wasting countdown loops such as the boot delay adc_wait_loop: MB r0.0, C JRNZ DP, adc_wait_loop ; DP starts at 0 -> 65,536 passes which the ROMs run eight times before starting (several seconds of chip time). Only loops of JRNZ DP around a body of register-only instructions are touched, and only while no interrupt can be taken; time, timers and the crank signal still advance by exactly the skipped cycles, so the program sees the same state afterwards.
    public bool FastForwardDelayLoops { get; set; }
    public long FastForwardedInstructions { get; private set; }

    private void TryFastForwardDelayLoop(ushort pc)
    {
        if (pc >= Bus.RomSize) return;
        Decoded j;
        try { j = DecodeCached(pc); } catch (ExecException) { return; }
        if (!j.Mnemonic.StartsWith("JRNZ DP", StringComparison.Ordinal)) return;
        int target = pc + j.Len + j.Fields.Rel8;
        if (target >= pc || pc - target > 8) return;
        uint body = 0;
        int count = 0;
        for (int a = target; a < pc;)
        {
            Decoded b;
            try { b = DecodeCached((ushort)a); } catch (ExecException) { return; }
            bool harmless = b.Mnemonic == "NOP" ||
                            (b.Mnemonic.StartsWith("MB r", StringComparison.Ordinal) && b.Mnemonic.EndsWith(", C", StringComparison.Ordinal));
            if (!harmless) return;
            body += b.Cycles; count++;
            a += b.Len;
        }
        // interrupts enabled and unmasked would run during the loop: leave those to real time
        ushort ie = (ushort)(Bus.Ram[0x1A] | (Bus.Ram[0x1B] << 8));
        if (Cpu.Mie() && ie != 0) return;
        int dpAddr = 0x80 + (Cpu.Scb() * 8) + 4;
        int dp = Bus.Ram[dpAddr] | (Bus.Ram[dpAddr + 1] << 8);
        if (dp == 0) dp = 0x10000;
        if (dp <= 2) return;
        long n = dp - 1;                              // iterations to skip; DP ends at 1 so the JRNZ falls through
        ulong per = j.Cycles + 4u + body;             // taken branch costs 4 more
        ulong total = (ulong)n * per;
        const uint chunk = 50_000;
        for (ulong done = 0; done < total;)
        {
            uint step = (uint)Math.Min(chunk, total - done);
            Cpu.Cycles += step;
            done += step;
            Bus.TickTimers(step);
            Engine.CheckDistributorPulses(Bus, Cpu.Cycles, Bus.CpuHz);
        }
        Cpu.Instructions += (ulong)(n * (1 + count));
        FastForwardedInstructions += n * (1 + count);
        Bus.Ram[dpAddr] = 1; Bus.Ram[dpAddr + 1] = 0;
    }

    /// Decode the instruction at `pc` (without executing it), advance PC and Cycles/Instructions by its normal cost, and let timers/interrupts progress by that same elapsed time -- but skip every effect the instruction itself would have had (no branch taken, no register/ flag/stack changes). Returns null if nothing decodes at `pc`.
    private TraceEntry? TryStepIgnoredJump(ushort pc)
    {
        var d = Decoder.Decode(Cpu.Dd, i => Bus.ReadCodeU8((ushort)(pc + i)));
        if (d == null) return null;

        Cpu.Pc = (ushort)(pc + d.Len);
        Cpu.Cycles += d.Cycles;
        Cpu.Instructions += 1;
        if (d.DdAfter is bool v) Cpu.Dd = v;

        ushort timerIrq = Bus.TickTimers(d.Cycles);
        ushort distIrq = Engine.CheckDistributorPulses(Bus, Cpu.Cycles, Bus.CpuHz);
        LastStepInterrupted = InterruptController.HandlePendingInterrupts(Cpu, Bus, (ushort)(timerIrq | distIrq));

        string text = "(ignored) " + Decoder.Format(d, Cpu.Pc);
        return new TraceEntry(pc, text);
    }

    // ---- decode cache --------------------------------------------------- ROM is immutable while running, so each (address, DD) decodes once.
    private readonly Decoded?[] _decodeCacheWord = new Decoded?[Bus.RomSize];
    private readonly Decoded?[] _decodeCacheByte = new Decoded?[Bus.RomSize];
    private static bool[]? _condByIndex;
    private static bool[]? _brkByIndex;

    /// Drop cached decodes (call after changing Bus.Rom by hand).
    public void InvalidateDecodeCache()
    {
        Array.Clear(_decodeCacheWord);
        Array.Clear(_decodeCacheByte);
    }

    public Decoded DecodeCached(ushort pc)
    {
        var cache = Cpu.Dd ? _decodeCacheWord : _decodeCacheByte;
        if (pc < Bus.RomSize && cache[pc] is { } hit) return hit;
        var d = Decoder.Decode(Cpu.Dd, i => Bus.ReadCodeU8((ushort)(pc + i)))
                ?? throw ExecException.UndefinedOpcode(pc, Bus.ReadCodeU8(pc));
        if (pc < Bus.RomSize && pc + d.Len <= Bus.RomSize) cache[pc] = d;
        return d;
    }

    private static bool IsConditionalBranch(Decoded d)
    {
        var t = _condByIndex;
        if (t == null)
        {
            t = new bool[FullOpcodes.Table.Length];
            for (int i = 0; i < t.Length; i++)
                foreach (var m in ConditionalBranches)
                    if (FullOpcodes.Table[i].Mnemonic.StartsWith(m, StringComparison.Ordinal)) t[i] = true;
            _condByIndex = t;
        }
        return t[d.Index];
    }

    private static bool IsBrk(Decoded d)
    {
        var t = _brkByIndex;
        if (t == null)
        {
            t = new bool[FullOpcodes.Table.Length];
            for (int i = 0; i < t.Length; i++) t[i] = FullOpcodes.Table[i].Mnemonic.StartsWith("BRK", StringComparison.Ordinal);
            _brkByIndex = t;
        }
        return t[d.Index];
    }

    /// Execute a conditional branch with its outcome decided by ForcedBranches instead of by the flags. Everything else about the instruction -- length, cycle cost, timer and interrupt progress -- happens normally.
    private TraceEntry? TryStepForcedBranch(ushort pc, bool taken)
    {
        var d = Decoder.Decode(Cpu.Dd, i => Bus.ReadCodeU8((ushort)(pc + i)));
        if (d == null || !IsConditionalBranch(d)) return null;

        ushort next = (ushort)(pc + d.Len);
        Cpu.Pc = taken ? (ushort)(next + d.Fields.Rel8) : next;
        Cpu.Cycles += d.Cycles + (taken ? 4u : 0u);
        Cpu.Instructions += 1;
        if (d.DdAfter is bool v) Cpu.Dd = v;
        Coverage.RecordBranch(pc, taken);

        uint delta = (uint)(d.Cycles + (taken ? 4u : 0u));
        ushort timerIrq = Bus.TickTimers(delta);
        ushort distIrq = Engine.CheckDistributorPulses(Bus, Cpu.Cycles, Bus.CpuHz);
        LastStepInterrupted = InterruptController.HandlePendingInterrupts(Cpu, Bus, (ushort)(timerIrq | distIrq));

        return new TraceEntry(pc, $"(forced {(taken ? "taken" : "not taken")}) " +
                                  Decoder.Format(d, next));
    }

    /// Run a drive cycle for a fixed number of instructions, re-syncing the sensors as the operating point moves. This is the whole-ROM test entry point: RunBatch alone holds the engine at one operating point, which is what limits coverage, not the instruction budget.
    public long RunDriveCycle(DriveCycle cycle, long instructions, int syncEvery = 512)
    {
        StallInterventionEnabled = true;
        long ran = 0;
        for (; ran < instructions; ran++)
        {
            if (!cycle.Tick(this)) break;
            if (ran % syncEvery == 0) SyncSensors();
            if (State == RunState.Faulted) break;
            if (StepOne() == null) break;
        }
        return ran;
    }

    /// Run up to `maxInstructions`, stopping early on fault. Intended to be called from a UI timer tick with a small budget (e.g. a few thousand instructions) to advance real time between frames without blocking.
    public int RunBatch(int maxInstructions)
    {
        int ran = 0;
        for (; ran < maxInstructions; ran++)
        {
            if (State == RunState.Faulted) break;
            if (StepOne() == null) break;
        }
        return ran;
    }
}
