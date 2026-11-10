// Copyright (c) bmgjet. All rights reserved.
using System.Diagnostics;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Owns the simulator and its background run loop; the ROM, its build, the calibration state and the emulator are RomHost's, and the
/// ROM array RomHost edits is the simulator's own (Sim.Bus.Rom), so the program it runs is the one being tuned. No Avalonia types in
/// here, so it can be driven from a test or another front end.
public sealed class SimHost : RomHost
{
    bool _running;
    double _speed = 1;
    string _stopReason = "nothing loaded";
    ushort? _skipOnce;
    /// Run until the call stack is back down to this depth (step over / step out).
    int? _runUntilDepth;
    string _runUntilWhy = "";
    /// Shadow call stack, rebuilt as the program runs: CAL/SCAL/VCAL frames and interrupt frames, each with the stack pointer value that identifies it.
    readonly List<Frame> _frames = [];
    /// Wakes the run loop when the simulator is started.
    readonly ManualResetEventSlim _wake = new(false);
    public sealed record Frame(ushort Entry, ushort Return, ushort Ssp, bool Interrupt);
    // executed instructions, oldest first; their text is only formatted when shown
    readonly Queue<TraceEntry> _trace = new();
    DateTime _runStartWall;
    ulong _runStartCycles;
    long _runStartInstr;
    double _rate;
    /// Engine/board inputs as last set from the UI, re-applied to every freshly loaded simulator.
    readonly Dictionary<string, double> _inputs = [];

    public SimHost()
    {
        Rom = Sim.Bus.Rom;
        var t = new Thread(Loop) { IsBackground = true, Name = "sim" };
        t.Start();
    }

    /// The simulator runs the ROM straight out of its own array: a change made in place needs the decoded instructions read afresh.
    protected override void RomBytesChanged() => Sim.InvalidateDecodeCache();

    public Simulator Sim { get; private set; } = new();
    public bool IsRunning { get { lock (_lock) return _running; } }
    /// The simulated clock (CPU cycles): the simulator link's timeouts run on it.
    public ulong SimCycles { get { lock (_lock) return Sim.Cpu.Cycles; } }
    /// The 8255 PPI as it stands: port A (as read), B, C and the control word.
    public (byte A, byte B, byte C, byte Control) PpiState() { lock (_lock) { var p = Sim.Bus.Ppi; return (p.Read(0), p.PortB, p.PortC, p.Control); } }
    /// The simulated VTEC solenoid is on: the ROM is reading the high-cam maps.
    public bool VtecActive { get { lock (_lock) return Sim.Bus.VtecSolenoidActive; } }
    public double Speed { get { lock (_lock) return _speed; } set { lock (_lock) _speed = Math.Max(0, value); } }
    /// Skip the ROM's boot delay loops in no real time (Simulator.FastForwardDelayLoops).
    public bool FastBoot { get; set { lock (_lock) { field = value; Sim.FastForwardDelayLoops = value; } } } = true;

    // ------------------------------------------------------------------ loading

    public override void LoadImage(byte[] image, AssemblyResult? asm, string path)
    {
        lock (_lock)
        {
            var keep = Sim.Breakpoints.ToList();
            bool same = path == LoadedPath;
            NoteImageReplaced(image);
            Sim = new Simulator { FastForwardDelayLoops = FastBoot };
            // the editor's ROM is the new simulator's from here on - also when the load below throws (an image of the wrong size): the
            // calibration, the checksum and the emulator uploads must never work on a different array from the one the simulator runs
            Rom = Sim.Bus.Rom;
            Sim.LoadRom(image);
            Assembly = asm;
            ChecksumAddress = RomChecksum.Site(image, asm);
            Definitions = null;
            _labels = asm?.Symbols.Values.Where(s => s.Kind == SymbolKind.Label)
                .GroupBy(s => s.Value).ToDictionary(g => g.Key, g => g.First().Name) ?? [];
            LoadedPath = path;
            RomDirty = false;
            HookRamWrites();
            if (same) foreach (var b in keep) Sim.Breakpoints.Add(b);
            _running = false;
            _stopReason = "loaded " + Path.GetFileName(path);
            _trace.Clear();
            _frames.Clear();
            foreach (var (k, v) in _inputs) ApplyInput(k, v);
            foreach (var (k, v) in _forced) Sim.Board.Forced[k] = v;
            foreach (var (k, v) in _analog) Sim.Engine.AnalogOverrides[k] = v;
            Sim.SyncSensors();
            ResetRates();
            _undo.Clear(); _redo.Clear();
            Interlocked.Increment(ref _version);
        }
    }

    /// Make a processor profile active (clock, names, pins) and restart the loaded image from reset so the new clock applies.
    public override void ApplyProfile(ProcessorProfile profile)
    {
        lock (_lock)
        {
            profile.Apply();
            if (LoadedPath != null)
            {
                var keepBp = Sim.Breakpoints.ToList();
                var rom = Sim.Bus.Rom.ToArray();
                LoadImage(rom, Assembly, LoadedPath);
                foreach (var b in keepBp) Sim.Breakpoints.Add(b);
                _stopReason = $"processor {profile.Name}: restarted from reset";
            }
        }
    }

    // ------------------------------------------------------------------ hand-set inputs (chip view)

    readonly Dictionary<(int Port, int Bit), bool> _forced = [];
    readonly Dictionary<int, double> _analog = [];

    /// Force an input pin high/low, or pass null to hand it back to the board model.
    public void ForcePin(int port, int bit, bool? level)
    {
        lock (_lock)
        {
            if (level is bool v) { _forced[(port, bit)] = v; Sim.Board.Forced[(port, bit)] = v; }
            else { _forced.Remove((port, bit)); Sim.Board.Forced.Remove((port, bit)); }
        }
    }

    public bool? ForcedLevel(int port, int bit) { lock (_lock) return _forced.TryGetValue((port, bit), out var v) ? v : null; }

    /// Set an analog input voltage by hand (key: 0-7 direct AIn, 100+n / 200+n mux channels), or null to return it to the engine model.
    public void SetAnalog(int key, double? volts)
    {
        lock (_lock)
        {
            if (volts is double v) { _analog[key] = v; Sim.Engine.AnalogOverrides[key] = v; }
            else { _analog.Remove(key); Sim.Engine.AnalogOverrides.Remove(key); }
            Sim.SyncSensors();
        }
    }

    public double? AnalogOverride(int key) { lock (_lock) return _analog.TryGetValue(key, out var v) ? v : null; }

    /// Voltages currently on the analog inputs: direct pins, and both mux banks.
    public (double[] Direct, double[] MuxA, double[] MuxB, int MuxSelect) Analog()
    {
        lock (_lock)
        {
            var b = Sim.Bus;
            double V(ushort counts) => counts * 5.0 / 1023.0;
            int sel = (b.ReadPort(2) >> 5) & 7;
            return (Enumerable.Range(0, 8).Select(i => V(b.AdcInput(i))).ToArray(),
                    b.P28MuxInputs[0].Select(V).ToArray(), b.P28MuxInputs[1].Select(V).ToArray(), sel);
        }
    }

    // ------------------------------------------------------------------ who writes RAM, and RAM held at a value

    /// The last few instructions (distinct, newest first) that wrote each RAM byte, and how many writes it has had: the memory map's "written by". Recorded as the simulator runs, from power-up.
    const int WritersKept = 4;
    readonly ushort[] _writerPc = new ushort[Chip.RamSize * WritersKept];
    readonly byte[] _writerN = new byte[Chip.RamSize];
    readonly long[] _writes = new long[Chip.RamSize];
    /// RAM bytes held at a value (the memory map's Hold): whatever the ROM writes there is put back at once.
    readonly Dictionary<int, byte> _held = [];

    void HookRamWrites()
    {
        Array.Clear(_writerPc); Array.Clear(_writerN); Array.Clear(_writes);
        var bus = Sim.Bus;
        bus.OnDataWrite += (addr, _, _) =>
        {
            if (addr >= RamMap.RamEnd) return;
            int a = addr;
            _writes[a]++;
            ushort pc = bus.CurrentPc;
            int b = a * WritersKept, n = _writerN[a];
            int at = 0;
            while (at < n && _writerPc[b + at] != pc) at++;
            if (at == n) { if (n < WritersKept) _writerN[a] = (byte)(++n); at = n - 1; }
            // newest first: move it (or put it) at the front
            for (int k = at; k > 0; k--) _writerPc[b + k] = _writerPc[b + k - 1];
            _writerPc[b] = pc;
            if (_held.Count > 0 && _held.TryGetValue(a, out var v)) bus.Ram[a] = v;
        };
    }

    /// The instructions that wrote this RAM byte (newest first) and how many writes it has had.
    public (ushort[] Pcs, long Writes) RamWriters(int addr)
    {
        lock (_lock)
        {
            int a = addr & (Chip.RamSize - 1);
            return (_writerPc.AsSpan(a * WritersKept, _writerN[a]).ToArray(), _writes[a]);
        }
    }

    /// Where an instruction is: its label (and how far past it), and the source line.
    public string Where(ushort pc)
    {
        lock (_lock)
        {
            var label = _labels.Where(kv => kv.Key <= pc && pc - kv.Key < 0x200).OrderByDescending(kv => kv.Key).FirstOrDefault();
            string name = label.Value is { } n ? (label.Key == pc ? n : $"{n}+{pc - label.Key}") : "";
            var src = Assembly?.Lookup(pc);
            return $"{pc:X4}" + (name.Length > 0 ? " " + name : "") + (src != null ? $" ({Path.GetFileName(src.File)}:{src.Line})" : "");
        }
    }

    /// Hold RAM bytes at these values (null: let them go): the ROM's own writes are undone as they happen.
    public void HoldRam(int addr, byte[]? bytes, int size = 1)
    {
        lock (_lock)
        {
            for (int i = 0; i < size; i++)
            {
                int a = (addr + i) & (Chip.RamSize - 1);
                if (bytes == null) _held.Remove(a);
                else { _held[a] = bytes[i]; Sim.Bus.Ram[a] = bytes[i]; }
            }
        }
    }

    public bool IsHeld(int addr) { lock (_lock) return _held.ContainsKey(addr & (Chip.RamSize - 1)); }

    /// Write RAM bytes now (the memory map's edit): the ROM may write them again straight after, unless they are held.
    public void WriteRamBytes(int addr, byte[] bytes)
    {
        lock (_lock)
            for (int i = 0; i < bytes.Length; i++)
            {
                int a = (addr + i) & (Chip.RamSize - 1);
                Sim.Bus.Ram[a] = bytes[i];
                if (_held.ContainsKey(a)) _held[a] = bytes[i];
            }
    }

    // ------------------------------------------------------------------ building

    public sealed record PatchOutcome(bool Success, List<Diagnostic> Diagnostics, AssemblyResult? Assembly, int Bytes,
        List<(int Start, int Length)> Ranges, bool RunningInside, string Note);

    /// Assemble again and put only what changed into the running ROM - no reset: the program carries on from where it is, RAM and all, with the new code and tables (and the emulator gets the changed blocks, when it is uploading changes). The bytes compared are the last build and this one, so values changed here since (a table edited on the Calibration page) are kept. Unless `force`, it does nothing while the CPU is inside code that changes (RunningInside): the caller asks first.
    public PatchOutcome PatchBuild(string path, Func<string, string?>? unsavedBuffers, bool force)
    {
        var asm = new OkiAssembler(new AssemblerOptions { ReadFile = unsavedBuffers }).AssembleFile(path);
        var diags = asm.Diagnostics;
        if (!asm.Success || diags.Any(d => d.Severity == Severity.Error)) return new(false, diags, asm, 0, [], false, "the build failed");
        lock (_lock)
        {
            if (Assembly == null || !string.Equals(LoadedPath, path, StringComparison.OrdinalIgnoreCase))
                return new(false, diags, asm, 0, [], false, "this source is not the one loaded: Build it first (Build loads it)");
            var old = Assembly.Image;
            var neu = asm.Image;
            int sumAt = ChecksumAddress ?? -1;
            int end = Math.Min(Chip.RomSize, neu.Length);
            bool Differs(int i) => i != sumAt && (i >= old.Length || old[i] != neu[i]);
            var ranges = new List<(int Start, int Length)>();
            for (int i = 0; i < end; i++)
            {
                if (!Differs(i)) continue;
                int start = i;
                while (i < end && Differs(i)) i++;
                ranges.Add((start, i - start));
            }
            int bytes = ranges.Sum(r => r.Length);
            if (bytes == 0)
            {
                // the same bytes (new names, comments, annotations): the names and definitions are the new build's
                var kept = Definitions;
                Assembly = asm; Definitions = null; _ramMap = null;
                KeepDefinitions(kept);
                _labels = asm.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).GroupBy(s => s.Value).ToDictionary(g => g.Key, g => g.First().Name);
                Interlocked.Increment(ref _version);
                return new(true, diags, asm, 0, ranges, false, "nothing to patch: the bytes are the same");
            }
            // the CPU (or a routine it will return to) inside changed code
            bool Inside(int a) => ranges.Any(r => a >= r.Start - 2 && a < r.Start + r.Length);
            bool running = Inside(Sim.Cpu.Pc) || _frames.Any(f => Inside(f.Return));
            if (running && !force)
                return new(false, diags, asm, bytes, ranges, true, $"the program is running inside code that changes (PC {Sim.Cpu.Pc:X4} {LabelAt(Sim.Cpu.Pc)})");
            foreach (var (start, len) in ranges)
                for (int i = 0; i < len; i++) Sim.Bus.Rom[start + i] = neu[start + i];
            var keptDefs = Definitions;
            Assembly = asm;
            Definitions = null; _ramMap = null;
            KeepDefinitions(keptDefs);
            _labels = asm.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).GroupBy(s => s.Value).ToDictionary(g => g.Key, g => g.First().Name);
            BalanceChecksum();
            Sim.InvalidateDecodeCache();
            RomDirty = true;
            Interlocked.Increment(ref _version);
            foreach (var (start, len) in ranges) QueueUpload(start, len);
            return new(true, diags, asm, bytes, ranges, running, $"{bytes} byte(s) in {ranges.Count} place(s) patched into the running ROM");
        }
    }

    // ------------------------------------------------------------------ running

    public void Control(string action, int count = 1)
    {
        lock (_lock)
        {
            switch (action)
            {
                case "run":
                    if (Sim.State == RunState.Faulted || LoadedPath == null) return;
                    _skipOnce = Sim.Cpu.Pc;
                    _running = true;
                    _wake.Set();
                    _stopReason = "running";
                    _runStartWall = DateTime.UtcNow;
                    _runStartCycles = Sim.Cpu.Cycles;
                    _runStartInstr = (long)Sim.Cpu.Instructions;
                    break;
                case "pause":
                    if (_running) { _running = false; _stopReason = "paused"; }
                    break;
                case "reset":
                    _running = false; Sim.Reset(); _frames.Clear(); foreach (var (k, v) in _inputs) ApplyInput(k, v);
                    Sim.SyncSensors(); _trace.Clear(); _stopReason = "reset"; ResetRates();
                    break;
                case "step":
                    _running = false;
                    LastStepReads = [];
                    for (int i = 0; i < Math.Max(1, count); i++) Step();
                    _stopReason = "step";
                    StepSerial++;
                    break;
                case "stepover":
                    {
                        // Over a call (or an interrupt it triggers): run it to completion. Over a jump or branch: do not take it - carry on at the next instruction, which is what "step over the jump" means here.
                        _running = false;
                        int depth = _frames.Count;
                        LastStepReads = [];
                        long reads = Sim.Bus.RomReadTotal;
                        ushort here = Sim.Cpu.Pc;
                        var kind = ClassifyAt(here);
                        if (kind == StepKind.Conditional) Sim.ForcedBranches[here] = false;
                        else if (kind == StepKind.Jump) Sim.IgnoredJumps.Add(here);
                        try { Step(); }
                        finally { Sim.ForcedBranches.Remove(here); Sim.IgnoredJumps.Remove(here); }
                        if (kind is StepKind.Conditional or StepKind.Jump)
                        {
                            _stopReason = kind == StepKind.Jump ? "step over: the jump was skipped" : "step over: the branch was not taken";
                            StepSerial++;
                            break;
                        }
                        if (_frames.Count > depth)
                        {
                            _runUntilDepth = depth; _runUntilWhy = "step over";
                            Control("run");
                            _runReadsFrom = reads;
                        }
                        else { _stopReason = "step over"; StepSerial++; }
                        break;
                    }
                case "stepinto":
                    {
                        // Follow the jump even when the condition says otherwise.
                        _running = false;
                        LastStepReads = [];
                        ushort here = Sim.Cpu.Pc;
                        var kind = ClassifyAt(here);
                        if (kind == StepKind.Conditional) Sim.ForcedBranches[here] = true;
                        try { Step(); }
                        finally { Sim.ForcedBranches.Remove(here); }
                        _stopReason = kind == StepKind.Conditional ? "step into: the branch was forced taken" : "step into";
                        StepSerial++;
                        break;
                    }
                case "stepout":
                    if (_frames.Count == 0)
                    {
                        _running = false;
                        _stopReason = "not inside a called routine or interrupt handler - nothing to step out of (use Run)";
                        break;
                    }
                    _runUntilDepth = _frames.Count - 1; _runUntilWhy = "step out of " + LabelAt(_frames[^1].Entry);
                    LastStepReads = [];
                    long before = Sim.Bus.RomReadTotal;
                    Control("run");
                    _runReadsFrom = before;
                    break;
            }
        }
    }

    enum StepKind { Plain, Conditional, Jump, Call }

    /// What the instruction at `pc` is, for Over / Into.
    StepKind ClassifyAt(ushort pc)
    {
        var d = Decoder.Decode(Sim.Cpu.Dd, i => Sim.Bus.ReadCodeU8((ushort)(pc + i)));
        if (d == null) return StepKind.Plain;
        string op = d.Mnemonic.Split(' ')[0];
        if (op is "CAL" or "SCAL" or "VCAL") return StepKind.Call;
        if (op is "J" or "SJ") return StepKind.Jump;
        if (op.Length > 1 && op[0] == 'J') return StepKind.Conditional;      // JEQ JNE JLT JGE JGT JLE JBS JBR JRNZ
        return StepKind.Plain;
    }

    /// What Over / Into would do at the current instruction, for the button tooltips.
    public string StepHint()
    {
        lock (_lock)
        {
            return ClassifyAt(Sim.Cpu.Pc) switch
            {
                StepKind.Call => "a call: Over runs it to completion",
                StepKind.Jump => "a jump: Over skips it, Into follows it",
                StepKind.Conditional => "a conditional branch: Over does not take it, Into forces it taken",
                _ => "",
            };
        }
    }

    void Step()
    {
        ushort pc = Sim.Cpu.Pc, ssp = Sim.Cpu.Ssp;
        long readsBefore = Sim.Bus.RomReadTotal;
        var e = Sim.StepOne();
        NoteStepReads(readsBefore);
        if (e is TraceEntry t)
        {
            _trace.Enqueue(t);
            while (_trace.Count > 300) _trace.Dequeue();
        }
        Track(pc, ssp, e);
        if ((Sim.Cpu.Instructions & 1023) == 0) Sim.SyncSensors();
    }

    /// ROM data addresses read by the last Step / Over / Out (for the calibration page to jump to).
    public List<int> LastStepReads { get { lock (_lock) return [.. field]; }

        private set;
    } = [];

    /// Bumped whenever a step / over / out finishes, so the UI can react once per step.
    public int StepSerial { get; private set; }

    void NoteStepReads(long before)
    {
        var b = Sim.Bus;
        long n = Math.Min(b.RomReadTotal - before, b.RomReadLog.Length);
        if (n <= 0) return;
        var list = new List<int>();
        for (long i = b.RomReadTotal - n; i < b.RomReadTotal; i++) list.Add(b.RomReadLog[i % b.RomReadLog.Length].Address);
        LastStepReads = list;
    }

    /// Keep the shadow call stack in step with what the instruction just did.
    void Track(ushort pcBefore, ushort sspBefore, TraceEntry? e)
    {
        ushort ssp = Sim.Cpu.Ssp;
        bool irq = Sim.LastStepInterrupted;
        ushort sspInsn = irq ? (ushort)(ssp + 8) : ssp;           // stack after the instruction itself
        while (_frames.Count > 0 && sspInsn > _frames[^1].Ssp) _frames.RemoveAt(_frames.Count - 1);
        var d = e?.Decoded;
        if (d != null && sspInsn == (ushort)(sspBefore - 2) &&
            (d.Mnemonic.StartsWith("CAL", StringComparison.Ordinal) || d.Mnemonic.StartsWith("SCAL", StringComparison.Ordinal) || d.Mnemonic.StartsWith("VCAL", StringComparison.Ordinal)))
        {
            ushort entry = irq ? Sim.Bus.ReadDataU16(sspInsn) : Sim.Cpu.Pc;
            _frames.Add(new Frame(entry, (ushort)(pcBefore + d.Len), sspInsn, false));
        }
        if (irq) _frames.Add(new Frame(Sim.Cpu.Pc, Sim.Bus.ReadDataU16(sspInsn), ssp, true));
        if (_frames.Count > 256) _frames.RemoveRange(0, _frames.Count - 256);   // runaway recursion guard
    }

    /// Call stack, innermost first, for display.
    public List<string> CallStack()
    {
        lock (_lock)
            return [.. Enumerable.Reverse(_frames).Select(f =>
                $"{(f.Interrupt ? "irq " : "")}{f.Entry:X4} {NearestLabel(f.Entry)}   <- {f.Return:X4} {NearestLabel(f.Return)}")];
    }

    long? _runReadsFrom;

    void Stop(string why)
    {
        if (_runUntilDepth != null && _runReadsFrom is long from)
        {
            // step over / out: the calibration page shows the tables read on the way
            NoteStepReads(Math.Max(from, Sim.Bus.RomReadTotal - 256));
            StepSerial++;
        }
        _runReadsFrom = null;
        _running = false; _stopReason = why; _runUntilDepth = null;
    }

    void Loop()
    {
        while (true)
        {
            // one bad instruction (or a bug here) must stop the simulator, not take the whole program down with it: an exception on this thread would end the process silently
            try { Slice(); }
            catch (Exception ex)
            {
                AppLog.Error("sim", "the run loop stopped on an error", ex);
                lock (_lock) { _running = false; _stopReason = "internal error: " + ex.Message; }
                Thread.Sleep(50);
            }
        }
    }

    bool _timerRaised;

    /// One pass of the run loop: a slice of instructions, playback and the serial port.
    void Slice()
    {
        {
            bool running;
            lock (_lock) running = _running;
            // finer sleeps while running (see HiResTimer), given back when stopped
            if (running && !_timerRaised) { HiResTimer.Begin(); _timerRaised = true; }
            // stopped: sleep until told to run (or 250 ms, for the serial port and playback), not wake 60 times a second for nothing
            if (!running)
            {
                if (_timerRaised) { HiResTimer.End(); _timerRaised = false; }
                _wake.Wait(250); _wake.Reset(); return;
            }
            lock (_lock)
            {
                // Run in short time slices and let go of the lock between them, so the UI (and an MCP client) always gets in - at unlimited speed too.
                int budget = 200_000;
                if (_speed > 0)
                {
                    double wall = (DateTime.UtcNow - _runStartWall).TotalSeconds;
                    if (Sim.Cpu.Cycles - _runStartCycles > wall * _speed * Chip.CpuHz) budget = 0;
                }
                long sliceEnd = Stopwatch.GetTimestamp() + (Stopwatch.Frequency / 250);     // 4 ms
                for (int i = 0; i < budget && _running; i++)
                {
                    if ((i & 511) == 511 && Stopwatch.GetTimestamp() > sliceEnd) break;
                    if (_speed > 0 && (i & 255) == 255)
                    {
                        double wall = (DateTime.UtcNow - _runStartWall).TotalSeconds;
                        if (Sim.Cpu.Cycles - _runStartCycles > wall * _speed * Chip.CpuHz) break;
                    }
                    ushort pc = Sim.Cpu.Pc;
                    if (_skipOnce == pc) _skipOnce = null;
                    else if (Sim.Breakpoints.Contains(pc)) { Stop($"breakpoint {pc:X4} {LabelAt(pc)}"); break; }
                    ushort sspBefore = Sim.Cpu.Ssp;
                    var e = Sim.StepOne();
                    if (e is TraceEntry t)
                    {
                        _trace.Enqueue(t);
                        while (_trace.Count > 300) _trace.Dequeue();
                    }
                    Track(pc, sspBefore, e);
                    if ((Sim.Cpu.Instructions & 1023) == 0) Sim.SyncSensors();
                    if (e == null || Sim.State == RunState.Faulted) { Stop("fault: " + Sim.FaultMessage); break; }
                    if (_runUntilDepth is int depth && _frames.Count <= depth) { Stop(_runUntilWhy); break; }
                }
                double w = (DateTime.UtcNow - _runStartWall).TotalSeconds;
                if (w > 0.25) _rate = ((long)Sim.Cpu.Instructions - _runStartInstr) / w;
                if (_play != null && _running) AdvancePlayback();
                PumpSerialLocked();
            }
            Thread.Sleep(1);
        }
    }

    // ------------------------------------------------------------------ the ROM's serial port (virtual ECU)

    readonly Queue<byte> _romTx = new();
    /// Bytes arrive at the datalog cable's rate (38400 baud: 10 bits each).
    public int SerialBaud { get; set; } = 38400;

    /// The simulated serial line is a single wire: the ROM hears its own bytes (the stock tester protocol needs it).
    public bool SerialEcho
    {
        get { lock (_lock) return Sim.Bus.SerialEcho; }
        set { lock (_lock) { Sim.Bus.SerialEcho = value; Sim.Bus.EchoByteCycles = (uint)Math.Max(1, (long)Chip.CpuHz * 10 / Math.Max(300, SerialBaud)); } }
    }

    /// Send bytes to the simulated ROM's serial port, as a datalogging tool would.
    public void SerialToRom(byte[] data)
    {
        lock (_lock) Sim.Bus.QueueSerialRx(BaudMismatchLocked() ? Garble(data) : data, (uint)Math.Max(1, (long)Chip.CpuHz * 10 / Math.Max(300, SerialBaud)));
    }

    /// The baud rate the ROM set its serial port to (0: it has not, or this chip is not modelled that way).
    public int RomSerialBaud { get { lock (_lock) return Chip.Is66911 ? 0 : Sim.Bus.RomSerialBaud; } }

    /// The ROM's line speed and the cable's more than 4 % apart: as on a car, every byte comes out garbled both ways.
    public bool BaudMismatch { get { lock (_lock) return BaudMismatchLocked(); } }
    bool BaudMismatchLocked()
    {
        int rom = Chip.Is66911 ? 0 : Sim.Bus.RomSerialBaud;
        return rom > 0 && Math.Abs(rom - SerialBaud) > rom * 0.04;
    }
    static byte[] Garble(byte[] data) => [.. data.Select((b, i) => (byte)(b * 37 + 0x5B + i))];

    /// Take up to `max` bytes the ROM has transmitted.
    public int SerialFromRom(byte[] buffer, int offset, int max)
    {
        lock (_lock)
        {
            PumpSerialLocked();
            int n = 0;
            while (n < max && _romTx.Count > 0) buffer[offset + n++] = _romTx.Dequeue();
            return n;
        }
    }

    public void SerialDiscard() { lock (_lock) { PumpSerialLocked(); _romTx.Clear(); } }

    void PumpSerialLocked()
    {
        var tx = Sim.Bus.TakeSerialTx();
        foreach (var b in BaudMismatchLocked() ? Garble(tx) : tx) _romTx.Enqueue(b);
        while (_romTx.Count > 65536) _romTx.Dequeue();
    }

    // ------------------------------------------------------------------ datalog playback

    List<LogFrame>? _play;
    int _playIndex;
    double _playSimStart, _playLogStart;
    public int PlaybackIndex { get { lock (_lock) return _playIndex; } }
    public bool PlaybackActive { get { lock (_lock) return _play != null; } }
    double SimNow => (double)Sim.Cpu.Cycles / Chip.CpuHz;

    /// Drive the engine inputs from a log, frame by frame in simulated time, and run.
    public void StartPlayback(List<LogFrame> frames, int from)
    {
        lock (_lock)
        {
            if (frames.Count == 0 || LoadedPath == null) return;
            _play = frames;
            _playIndex = Math.Clamp(from, 0, frames.Count - 1);
            ApplyFrameLocked(frames[_playIndex]);
            _playSimStart = SimNow;
            _playLogStart = frames[_playIndex].T;
            Control("run");
            _stopReason = "playing log";
        }
    }

    public void StopPlayback()
    {
        lock (_lock)
        {
            _play = null;
            if (_running) { _running = false; _stopReason = "log playback stopped"; }
        }
    }

    /// Put one frame's sensor readings on the engine inputs (live logging uses this too).
    public void ApplyFrame(LogFrame f) { lock (_lock) ApplyFrameLocked(f); }

    void ApplyFrameLocked(LogFrame f)
    {
        void In(string k, double? v) { if (v is double x && !double.IsNaN(x)) { _inputs[k] = x; ApplyInput(k, x); } }
        In("rpm", f.Rpm); In("map", f.MapKpa); In("tps", f.TpsPct); In("ect", f.EctC); In("iat", f.IatC);
        In("o2", f.O2V); In("vbatt", f.BattV); In("speed", f.SpeedKmh); In("baro", f.BaroKpa);
        Sim.SyncSensors();
    }

    void AdvancePlayback()
    {
        var play = _play!;
        double t = SimNow - _playSimStart + _playLogStart;
        bool moved = false;
        while (_playIndex + 1 < play.Count && play[_playIndex + 1].T <= t) { _playIndex++; moved = true; }
        if (moved) ApplyFrameLocked(play[_playIndex]);
        if (_playIndex + 1 >= play.Count && t >= play[^1].T + 0.1) { _play = null; Stop("log playback finished"); }
    }

    /// Current input values, as the Engine inputs panel shows them.
    public Dictionary<string, double> Inputs() { lock (_lock) return new(_inputs); }

    // ------------------------------------------------------------------ hit trace & table trace

    /// Hit state of the simulated ROM: per address, the cycle it last ran as an instruction (0 = never) and the cycle it was last read as data, plus the current cycle.
    // reused between calls: three arrays of 32768 rebuilt several times a second was a lot of rubbish for the collector to clear up
    ulong[]? _hitExec, _hitData;
    uint[]? _hitCount;

    public (ulong Now, ulong[] Exec, ulong[] Data, uint[] DataCount) SimHits()
    {
        lock (_lock)
        {
            _hitExec ??= new ulong[Chip.RomSize];
            _hitData ??= new ulong[Chip.RomSize];
            _hitCount ??= new uint[Chip.RomSize];
            for (int a = 0; a < Chip.RomSize; a++) _hitExec[a] = Sim.Coverage.LastExecuted((ushort)a);
            Array.Copy(Sim.Bus.RomReadAt, _hitData, Chip.RomSize);
            Array.Copy(Sim.Bus.RomReadCount, _hitCount, Chip.RomSize);
            return (Sim.Cpu.Cycles, _hitExec, _hitData, _hitCount);
        }
    }

    /// Recent ROM data reads, newest last: (address, reading instruction).
    public List<(int Address, int Pc)> RecentRomReads(int max)
    {
        lock (_lock)
        {
            var b = Sim.Bus;
            long n = Math.Min(Math.Min(b.RomReadTotal, max), b.RomReadLog.Length);
            var list = new List<(int, int)>((int)n);
            for (long i = b.RomReadTotal - n; i < b.RomReadTotal; i++)
            {
                var e = b.RomReadLog[i % b.RomReadLog.Length];
                list.Add((e.Address, e.Pc));
            }
            return list;
        }
    }

    public void ClearSimHits()
    {
        lock (_lock) { Sim.Bus.ClearRomReads(); Sim.Coverage.Reset(); }
    }

    /// How recently each cell of a table was read by the program: 1 = within the last few milliseconds of simulated time (the "trace"), fading to 0 over `trail` seconds (the "trail"). Which cells of a table the program has read lately, 1 = just now fading to 0 over `trail` seconds. Deliberately lock-free: the read counters are plain arrays the simulator writes as it runs, and a half-updated number only ever means a cell lights up a frame early or late. Taking the simulator's lock here made the trace stutter, because the UI had to wait for the run loop's time slice to end.
    public Dictionary<int, double> TableHeat(ItemDef item, double trail = 1.0, double fresh = 0.03)
    {
        var heat = new Dictionary<int, double>();
        var b = Sim.Bus;
        ulong now = Sim.Cpu.Cycles;
        double hz = Chip.CpuHz;
        int count = item.Count;
        for (int i = 0; i < count; i++)
        {
            int a = item.CellAddress(i);
            if ((uint)a >= Chip.RomSize || b.RomReadCount[a] == 0) continue;
            ulong at = b.RomReadAt[a];
            double age = (now - Math.Min(now, at)) / hz;
            if (age <= fresh) heat[i] = 1;
            else if (age < trail) heat[i] = 0.7 * (1 - ((age - fresh) / (trail - fresh)));
        }
        return heat;
    }

    // ------------------------------------------------------------------ inspection

    public sealed record Snapshot(
        bool Running, string State, string StopReason, string? Fault, int Pc, string Label,
        string? SourceFile, int SourceLine, long Instructions, double SimSeconds, double Rate,
        int A, int Dp, int X1, int X2, int Usp, int Ssp, int Lrb, int Bank, int Psw,
        bool Cy, bool Z, bool Hc, bool Dd, bool Mie, int Scb, int[] Er,
        int[] Ports, int[] PortDir, int Irq, int Ie,
        OutputState Outputs,
        double Rpm, double Map, double Tps, double Ect, double Iat, double O2, double Vbatt, double SpeedKmh, bool Cranking,
        int HotAddress, int HotCount, int HotWindow, int Coverage,
        List<(int Pc, string Label, string Text)> Trace,
        List<(int Address, string Label, string Source, bool Enabled)> Breakpoints,
        List<(int Pc, string Label, int Reason, int Count)> Traps,
        List<string> Calls);

    ushort Preg(int slot) => (ushort)(Sim.Bus.Ram[0x80 + (Sim.Cpu.Scb() * 8) + slot] |
                                      (Sim.Bus.Ram[0x81 + (Sim.Cpu.Scb() * 8) + slot] << 8));

    public Snapshot State()
    {
        lock (_lock)
        {
            var c = Sim.Cpu; var b = Sim.Bus; var en = Sim.Engine;
            var hot = Sim.GetHottestRecentPc();
            var src = Assembly?.Lookup(c.Pc);
            ushort bank = c.BankBase();
            return new Snapshot(
                _running, Sim.State.ToString(), _stopReason, Sim.FaultMessage, c.Pc, LabelAt(c.Pc),
                src?.File, src?.Line ?? 0, (long)c.Instructions, (double)c.Cycles / Chip.CpuHz, _running ? _rate : 0,
                c.A, Preg(4), Preg(0), Preg(2), Preg(6), c.Ssp, c.Lrb, bank, c.PswU16(),
                c.Cf, c.Zf, c.Hc, c.Dd, c.Mie(), c.Scb(),
                [.. Enumerable.Range(0, 4).Select(i => b.Ram[(bank + (i * 2)) & 0xFFF] | (b.Ram[(bank + (i * 2) + 1) & 0xFFF] << 8))],
                [.. Enumerable.Range(0, 5).Select(i => (int)b.ReadPort(i))],
                new int[] { b.Ram[0x21], b.Ram[0x23], b.Ram[0x25], b.Ram[0x29], b.Ram[0x2D] },
                b.Ram[0x18] | (b.Ram[0x19] << 8), b.Ram[0x1A] | (b.Ram[0x1B] << 8),
                Outputs(),
                en.Rpm, en.MapKpa, en.TpsPct, en.EctCelsius, en.IatCelsius, en.O2Volts, en.VbattVolts, en.SpeedKmh, en.Cranking,
                hot.Address, (int)hot.Count, (int)hot.WindowFilled, Sim.Coverage.AddressesExecuted,
                [.. _trace.Reverse().Take(80).Reverse().Select(t => ((int)t.Pc, LabelAt(t.Pc), t.Text))],
                [.. Sim.Breakpoints.Select(x => (x, true)).Concat(_disabledBps.Select(x => (x, false))).OrderBy(x => x.Item1).Select(x =>
                {
                    var s = Assembly?.Lookup(x.Item1);
                    return ((int)x.Item1, LabelAt(x.Item1), s == null ? "" : $"{Path.GetFileName(s.File)}:{s.Line}", x.Item2);
                })],
                [.. Sim.TrapLog.Select(t => ((int)t.Key.Pc, LabelAt(t.Key.Pc), (int)t.Key.Reason, (int)t.Value))],
                [.. Enumerable.Reverse(_frames).Select(f =>
                    $"{(f.Interrupt ? "irq " : "")}{f.Entry:X4} {NearestLabel(f.Entry)}  (returns to {f.Return:X4})")]);
        }
    }

    // ------------------------------------------------------------------ machine state (projects)

    public sealed class MachineState
    {
        public ushort Pc { get; set; }
        public ushort A { get; set; }
        public ushort Ssp { get; set; }
        public ushort Lrb { get; set; }
        public ushort Psw { get; set; }
        public ulong Cycles { get; set; }
        public ulong Instructions { get; set; }
        public ulong Elapsed { get; set; }
        public uint[] TimerAccum { get; set; } = [];
        public uint? AdcCyclesRemaining { get; set; }
        public uint? SerialTxCyclesRemaining { get; set; }
        public bool[] PwmOut { get; set; } = [];
        public ulong LastVssCycle { get; set; }
        public ulong CkpCount { get; set; }
        public ulong TdcCount { get; set; }
        public List<ushort> Breakpoints { get; set; } = [];
        /// Breakpoints switched off (kept, not stopped at).
        public List<ushort> DisabledBreakpoints { get; set; } = [];
        /// RAM bytes held at a value against the ROM's own writes (Memory > Map > Hold).
        public Dictionary<int, byte> HeldRam { get; set; } = [];
        /// Every other field of the machine (StateSnapshot): the peripherals, the engine's crank timing, the watchdog, the serial queues...
        public Dictionary<string, string> Fields { get; set; } = [];
        /// The shadow call stack: "entry return ssp irq" per frame, outermost first.
        public List<string> CallFrames { get; set; } = [];
        public Dictionary<string, double> Inputs { get; set; } = [];
        public List<string> ForcedPins { get; set; } = [];
        public Dictionary<int, double> Analog { get; set; } = [];
        public double CrystalMHz { get; set; }
        public List<string> Trace { get; set; } = [];
    }

    /// Everything needed to put the simulator back exactly where it is: registers, RAM, the (possibly calibration-patched) ROM, timers, crank phase, inputs, breakpoints.
    public (MachineState State, byte[] Ram, byte[] Rom) SaveState()
    {
        lock (_lock)
        {
            var c = Sim.Cpu; var b = Sim.Bus;
            return (new MachineState
            {
                Pc = c.Pc, A = c.A, Ssp = c.Ssp, Lrb = c.Lrb, Psw = c.PswU16(),
                Cycles = c.Cycles, Instructions = c.Instructions, Elapsed = b.ElapsedCycles,
                TimerAccum = [.. b.TimerAccum],
                AdcCyclesRemaining = b.AdcCyclesRemaining, SerialTxCyclesRemaining = b.SerialTxCyclesRemaining,
                PwmOut = [.. b.PwmOut], LastVssCycle = Sim.Engine.LastVssCycle,
                CkpCount = Sim.Engine.CkpPulseCount, TdcCount = Sim.Engine.TdcPulseCount,
                Breakpoints = [.. Sim.Breakpoints.OrderBy(x => x)],
                DisabledBreakpoints = [.. _disabledBps.OrderBy(x => x)],
                HeldRam = new(_held),
                Fields = StateSnapshot.Capture(Sim),
                CallFrames = [.. _frames.Select(f => $"{f.Entry:X4} {f.Return:X4} {f.Ssp:X4} {(f.Interrupt ? 1 : 0)}")],
                Inputs = new(_inputs),
                ForcedPins = [.. _forced.Select(kv => $"{kv.Key.Port}.{kv.Key.Bit}={(kv.Value ? 1 : 0)}")],
                Analog = new(_analog),
                CrystalMHz = Chip.CrystalMHz,
                Trace = [.. _trace.Select(t => $"{t.Pc:X4}|{t.Text}")],
            }, b.Ram.ToArray(), b.Rom.ToArray());
        }
    }

    /// Restore a SaveState() snapshot on top of the image that is loaded now.
    public void RestoreState(MachineState st, byte[] ram, byte[] rom)
    {
        lock (_lock)
        {
            _running = false;
            foreach (var (k, v) in st.Inputs) _inputs[k] = v;
            _forced.Clear();
            foreach (var f in st.ForcedPins)
            {
                var parts = f.Split('=', '.');
                if (parts.Length == 3) _forced[(int.Parse(parts[0]), int.Parse(parts[1]))] = parts[2] == "1";
            }
            _analog.Clear();
            foreach (var (k, v) in st.Analog) _analog[k] = v;
            LoadImage(rom, Assembly, LoadedPath ?? "project");
            var c = Sim.Cpu; var b = Sim.Bus;
            Array.Copy(ram, b.Ram, Math.Min(ram.Length, b.Ram.Length));
            c.Pc = st.Pc; c.A = st.A; c.Ssp = st.Ssp; c.Lrb = st.Lrb; c.SetPswU16(st.Psw);
            c.Cycles = st.Cycles; c.Instructions = st.Instructions; b.ElapsedCycles = st.Elapsed;
            Array.Copy(st.TimerAccum, b.TimerAccum, Math.Min(st.TimerAccum.Length, b.TimerAccum.Length));
            b.AdcCyclesRemaining = st.AdcCyclesRemaining;
            b.SerialTxCyclesRemaining = st.SerialTxCyclesRemaining;
            Array.Copy(st.PwmOut, b.PwmOut, Math.Min(st.PwmOut.Length, b.PwmOut.Length));
            Sim.Engine.LastVssCycle = st.LastVssCycle;
            // everything else the machine had (a project from before these were saved has none: what is above is all it gets)
            if (st.Fields.Count > 0) StateSnapshot.Restore(Sim, st.Fields);
            Array.Copy(ram, b.Ram, Math.Min(ram.Length, b.Ram.Length));
            _frames.Clear();
            foreach (var cf in st.CallFrames)
                if (cf.Split(' ') is [var e, var r, var sp, var irq])
                    _frames.Add(new Frame(Convert.ToUInt16(e, 16), Convert.ToUInt16(r, 16), Convert.ToUInt16(sp, 16), irq == "1"));
            Sim.Engine.CkpPulseCount = st.CkpCount; Sim.Engine.TdcPulseCount = st.TdcCount;
            Sim.Breakpoints.Clear();
            foreach (var bp in st.Breakpoints) Sim.Breakpoints.Add(bp);
            _disabledBps.Clear();
            foreach (var bp in st.DisabledBreakpoints) _disabledBps.Add(bp);
            _held.Clear();
            foreach (var (addr, v) in st.HeldRam) { _held[addr & (Chip.RamSize - 1)] = v; b.Ram[addr & (Chip.RamSize - 1)] = v; }
            RomDirty = !rom.AsSpan().SequenceEqual(Assembly?.Image ?? rom);
            _trace.Clear();
            foreach (var t in st.Trace)
            {
                var i = t.IndexOf('|');
                if (i > 0 && ushort.TryParse(t[..i], System.Globalization.NumberStyles.HexNumber, null, out var pc)) _trace.Enqueue(new TraceEntry(pc, t[(i + 1)..]));
            }
            // the sensor readings the ROM last latched came back with the fields; worked out afresh now they would be
            // this moment's, not the ones it had (an older project, without them, gets fresh ones)
            if (st.Fields.Count == 0) Sim.SyncSensors();
            ResetRates();
            _stopReason = "project restored";
        }
    }

    /// Forget everything tied to the ROM that was open: definitions, undo, coverage, hits, traces and caches. Called when another ROM is opened and by Clear project.
    public override void ResetRomState()
    {
        lock (_lock)
        {
            Definitions = null;
            _undo.Clear(); _redo.Clear();
            _trace.Clear();
            _frames.Clear();
            _play = null;
            ExternalHits.Clear();
            Sim.Bus.ClearRomReads();
            Sim.Coverage.Reset();
            Sim.TrapLog.Clear();
            LastStepReads = [];
            Interlocked.Increment(ref _version);
        }
    }

    /// Close the ROM and let go of everything: a fresh, low-memory state.
    public override void Clear()
    {
        lock (_lock)
        {
            _running = false;
            ResetRomState();
            Sim = new Simulator { FastForwardDelayLoops = FastBoot };
            Rom = Sim.Bus.Rom;
            _hitExec = null; _hitData = null; _hitCount = null;
            Assembly = null;
            _labels = [];
            LoadedPath = null;
            ForgetUploads(true);
            RomDirty = false;
            _stopReason = "nothing loaded";
            ResetRates();
        }
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        AppLog.Info("host", "project cleared");
    }

    // ------------------------------------------------------------------ outputs & pins

    /// One port pin, as the Outputs & Ports panel shows it.
    public sealed record PinRow(string Pin, string Dir, int Level, string Function, double ChangesPerSec,
        double HighMs, double LowMs, string DrivenBy);

    public sealed record OutputState(
        bool FuelPump, bool Vtec, bool VtecPressure,
        double[] InjectorMs, double[] InjectorPerSec, double[] InjectorDutyPct, double[] InjectorAgoMs,
        double SparksPerSec, double WatchdogHz, int MuxChannel,
        double Pwm0Duty, double Pwm0Hz, double Pwm1Duty, double Pwm1Hz,
        List<PinRow> Pins, byte PpiA = 0, byte PpiB = 0, byte PpiC = 0);

    // Rates are measured over a sliding stretch of simulated time.
    ulong _rateCycles;
    readonly long[] _rateInj = new long[4];
    long _rateSparks;
    readonly long[,] _ratePins = new long[5, 8];
    readonly double[] _injPerSec = new double[4];
    double _sparksPerSec;
    readonly double[,] _pinPerSec = new double[5, 8];

    void ResetRates()
    {
        _rateCycles = Sim.Cpu.Cycles;
        Array.Copy(Sim.Bus.InjectorEvents, _rateInj, 4);
        _rateSparks = Sim.Bus.IgnitionEvents;
        Array.Copy(Sim.Bus.Pins.Changes, _ratePins, _ratePins.Length);
        Array.Clear(_injPerSec); _sparksPerSec = 0; Array.Clear(_pinPerSec);
    }

    OutputState Outputs()
    {
        var b = Sim.Bus; var pins = b.Pins; ulong now = Sim.Cpu.Cycles;
        double dt = (double)(now - _rateCycles) / Chip.CpuHz;
        if (dt >= 0.5)
        {
            for (int n = 0; n < 4; n++) { _injPerSec[n] = (b.InjectorEvents[n] - _rateInj[n]) / dt; _rateInj[n] = b.InjectorEvents[n]; }
            _sparksPerSec = (b.IgnitionEvents - _rateSparks) / dt; _rateSparks = b.IgnitionEvents;
            for (int p = 0; p < 5; p++)
                for (int i = 0; i < 8; i++)
                { _pinPerSec[p, i] = (pins.Changes[p, i] - _ratePins[p, i]) / dt; _ratePins[p, i] = pins.Changes[p, i]; }
            _rateCycles = now;
        }
        double Ms(ulong cycles) => cycles * 1000.0 / Chip.CpuHz;
        bool Stale(ulong at) => now - at > Chip.CpuHz;   // nothing for a second: show as stopped
        var injMs = Enumerable.Range(0, 4).Select(n =>
            b.InjectorEvents[n] == 0 || Stale(b.InjectorLastEventAt[n]) ? 0 : b.InjectorPulseUs[n] / 1000.0).ToArray();
        var injAgo = Enumerable.Range(0, 4).Select(n =>
            b.InjectorEvents[n] == 0 ? -1 : Ms(now - b.InjectorLastEventAt[n])).ToArray();
        var duty = Enumerable.Range(0, 4).Select(n => Math.Min(100, injMs[n] / 1000.0 * _injPerSec[n] * 100)).ToArray();
        (double duty, double hz) Pwm(int bit)
        {
            double hi = Ms(pins.LastHighCycles[4, bit]), lo = Ms(pins.LastLowCycles[4, bit]);
            if (hi <= 0 || lo <= 0 || _pinPerSec[4, bit] <= 0) return (-1, 0);   // idle, or a zero-width glitch
            return (100 * hi / (hi + lo), 1000 / (hi + lo));
        }
        var (d0, f0) = Pwm(2);
        var (d1, f1) = Pwm(3);
        var rows = new List<PinRow>();
        for (int p = 0; p < 5; p++)
            for (int i = 0; i < 8; i++)
            {
                bool output = ((pins.Direction[p] >> i) & 1) != 0;
                int sfReg = p switch { 2 => b.Ram[0x26] & 0xF8, 3 => b.Ram[0x2A], 4 => b.Ram[0x2E], _ => 0 };
                bool sf = ((sfReg >> i) & 1) != 0;
                ushort pc = pins.LastDriverPc[p, i];
                rows.Add(new PinRow($"P{p}.{i}", sf ? "sf" : output ? "out" : "in", (b.ReadPort(p) >> i) & 1,
                    ProcessorProfile.Current.PinFunction(p, i), _pinPerSec[p, i],
                    // high/low phase lengths only mean something once the pin has toggled
                    pins.Changes[p, i] >= 3 ? Ms(pins.LastHighCycles[p, i]) : 0,
                    pins.Changes[p, i] >= 3 ? Ms(pins.LastLowCycles[p, i]) : 0,
                    pins.Changes[p, i] == 0 ? "" : $"{pc:X4} {NearestLabel(pc)}"));
            }
        bool pressure = (b.SwitchLatchPins & 0x02) == 0;   // VTEC pressure switch D6: 4700h bit 1, low = pressure
        return new OutputState(b.FuelPumpActive, b.VtecSolenoidActive, pressure,
            injMs, [.. _injPerSec], duty, injAgo, _sparksPerSec, _pinPerSec[2, 4] / 2, (b.ReadPort(2) >> 5) & 7,
            d0, f0, d1, f1, rows, b.Ppi.Read(0), b.Ppi.PortB, b.Ppi.PortC);
    }

    public List<(int Addr, string Label, string Bytes, string Text, bool Bp, bool Current, string Source)> Disassemble(int? from, int count)
    {
        lock (_lock)
        {
            int pc = from ?? Sim.Cpu.Pc;
            if (from == null)
            {
                int back = pc;
                for (int k = 0; k < 6 && back > 0; k++)
                {
                    var prev = Assembly?.Lookup(back - 1);
                    if (prev == null) break;
                    back = prev.Address;
                }
                pc = back;
            }
            bool dd = Sim.Cpu.Dd;
            var list = new List<(int, string, string, string, bool, bool, string)>();
            for (int n = 0; n < count && pc < Chip.RomSize; n++)
            {
                int at = pc;
                var d = Decoder.Decode(dd, i => Sim.Bus.Rom[(at + i) & 0x7FFF]);
                int len = d?.Len ?? 1;
                string text = d == null ? $"DB {Sim.Bus.Rom[pc]:X2}h" : Symbolize(Decoder.Format(d, (ushort)(pc + len)));
                if (d?.DdAfter is bool v) dd = v;
                var s = Assembly?.Lookup(pc);
                list.Add((pc, LabelAt(pc),
                    string.Concat(Enumerable.Range(0, len).Select(i => Sim.Bus.Rom[(pc + i) & 0x7FFF].ToString("X2"))),
                    text, Sim.Breakpoints.Contains((ushort)pc), pc == Sim.Cpu.Pc,
                    s == null ? "" : $"{Path.GetFileName(s.File)}:{s.Line}"));
                pc += len;
            }
            return list;
        }
    }

    string Symbolize(string text) => System.Text.RegularExpressions.Regex.Replace(text, @"\b0([0-9A-F]{4})h\b", m =>
    {
        int v = Convert.ToInt32(m.Groups[1].Value, 16);
        return v >= 0x38 && _labels.TryGetValue(v, out var n) ? n : m.Value;
    });

    public byte[] ReadMemory(int addr, int len)
    {
        lock (_lock)
        {
            var b = new byte[len];
            for (int i = 0; i < len; i++)
            {
                int a = (addr + i) & 0xFFFF;
                b[i] = a >= 0x480 && a < Chip.RomSize ? Sim.Bus.Rom[a] : Sim.Bus.Ram[a & (Chip.RamSize - 1)];
            }
            return b;
        }
    }

    public void WriteRam(int addr, byte value)
    {
        lock (_lock) { if (addr >= 0 && addr < Chip.RamSize) Sim.Bus.WriteDataU8((ushort)addr, value); }
    }

    // ------------------------------------------------------------------ breakpoints & lookup

    public (bool ok, int address, bool enabled, string error) ToggleBreakpointAt(string file, int line)
    {
        lock (_lock)
        {
            if (Assembly == null) return (false, 0, false, "build first so line numbers map to addresses");
            var full = Path.GetFullPath(file);
            var hit = Assembly.SourceMap.Where(e => e.File == full && e.Line >= line).OrderBy(e => e.Line).FirstOrDefault();
            return hit == null || hit.Line - line > 20 ? ((bool ok, int address, bool enabled, string error))(false, 0, false, "no code on that line") : ((bool ok, int address, bool enabled, string error))Toggle((ushort)hit.Address);
        }
    }

    public (bool ok, int address, bool enabled, string error) ToggleBreakpoint(string text)
    {
        lock (_lock)
        {
            return !Defs().TryResolve(text, out var a) ? ((bool ok, int address, bool enabled, string error))(false, 0, false, $"cannot resolve '{text}'") : ((bool ok, int address, bool enabled, string error))Toggle((ushort)a);
        }
    }

    (bool, int, bool, string) Toggle(ushort a)
    {
        if (_disabledBps.Remove(a)) return (true, a, false, "");
        if (Sim.Breakpoints.Contains(a)) { Sim.Breakpoints.Remove(a); return (true, a, false, ""); }
        Sim.Breakpoints.Add(a);
        return (true, a, true, "");
    }

    /// Set a breakpoint at a label or address, whether or not one is already there (Lookup & breakpoints > Break). `added` is false when it was already set.
    public (bool ok, int address, bool added, string error) AddBreakpoint(string text)
    {
        lock (_lock)
        {
            if (!Defs().TryResolve(text, out var a)) return (false, 0, false, $"cannot resolve '{text}'");
            ushort addr = (ushort)a;
            if (_disabledBps.Remove(addr)) { Sim.Breakpoints.Add(addr); return (true, addr, true, ""); }
            if (Sim.Breakpoints.Contains(addr)) return (true, addr, false, "");
            Sim.Breakpoints.Add(addr);
            return (true, addr, true, "");
        }
    }

    /// Take one breakpoint away, leaving the others (Lookup & breakpoints > Remove).
    public bool RemoveBreakpoint(int address) { lock (_lock) return Sim.Breakpoints.Remove((ushort)address) | _disabledBps.Remove((ushort)address); }

    public void ClearBreakpoints() { lock (_lock) { Sim.Breakpoints.Clear(); _disabledBps.Clear(); } }

    /// Breakpoints switched off: kept (listed, saved with a project) but not stopped at.
    readonly HashSet<ushort> _disabledBps = [];

    /// Switch a breakpoint off (kept, not stopped at) or on again.
    public bool SetBreakpointEnabled(int address, bool on)
    {
        lock (_lock)
        {
            var a = (ushort)address;
            if (on) { if (!_disabledBps.Remove(a)) return false; Sim.Breakpoints.Add(a); return true; }
            if (!Sim.Breakpoints.Remove(a)) return false;
            _disabledBps.Add(a);
            return true;
        }
    }

    // ------------------------------------------------------------------ check-engine lamp

    /// What the MIL window shows: the lamp and flash line now, what the flashes decoded to, the codes the ROM has stored (what the lamp will flash) and the fault bits set right now.
    public sealed record MilView(bool Lamp, bool Flash, bool Scc, (int Tens, int Units)? Flashing,
        IReadOnlyList<int> LastRound, IReadOnlyList<int> CurrentRound,
        IReadOnlyList<int> Stored, int? StoredAt, IReadOnlyList<(int Bit, int Code)> Current, int FieldBase);

    int _milRomVersion = -1; int _milField = 0xB0; int? _milStored;

    public MilView Mil()
    {
        lock (_lock)
        {
            if (_milRomVersion != _version)
            {
                _milField = MilMonitor.FaultFieldBase(Sim.Bus.Rom);
                _milStored = MilMonitor.StoredArray(Sim.Bus.Rom);
                _milRomVersion = _version;
            }
            var r = Sim.Bus.Ram; var m = Sim.Mil;
            var stored = _milStored is int a
                ? Enumerable.Range(0, 32).Where(i => (r[a + i / 8] >> (i % 8) & 1) != 0).Select(MilMonitor.FlashCode).ToList()
                : [];
            var current = Enumerable.Range(0, 48)
                .Where(b => (r[_milField + b / 8] >> (b % 8) & 1) != 0 && MilMonitor.FaultBitCode(b) != null)
                .Select(b => (b, MilMonitor.FaultBitCode(b)!.Value)).ToList();
            bool scc = !Chip.Is66911 && (Sim.Bus.Ppi.PortAInput & 0x80) != 0;
            return new MilView(m.Lamp, m.Flash, scc, m.Flashing, [.. m.LastRound], [.. m.CurrentRound], stored, _milStored, current, _milField);
        }
    }

    /// What each engine input can be, from what the sensor or the ECU's input can report: a value from an MCP client, a script or a car's datalog outside these is held to them, and one that is not a number is ignored.
    public static readonly Dictionary<string, (double Min, double Max)> InputLimits = new(StringComparer.OrdinalIgnoreCase)
    {
        ["rpm"] = (0, 12000), ["map"] = (0, 400), ["tps"] = (0, 100), ["ect"] = (-40, 150), ["iat"] = (-40, 150),
        ["o2"] = (0, 5), ["vbatt"] = (0, 20), ["speed"] = (0, 300), ["baro"] = (50, 110), ["eld"] = (0, 5),
        ["egr"] = (0, 100), ["crankvbatt"] = (0, 16),
    };

    public void SetInput(string name, double value)
    {
        if (double.IsNaN(value) || double.IsInfinity(value)) return;
        if (InputLimits.TryGetValue(name, out var lim)) value = Math.Clamp(value, lim.Min, lim.Max);
        lock (_lock)
        {
            _inputs[name] = value;
            ApplyInput(name, value);
            Sim.SyncSensors();
        }
    }

    void ApplyInput(string name, double value)
    {
        {
            var e = Sim.Engine;
            switch (name)
            {
                case "rpm": e.Rpm = value; break;
                case "map": e.MapKpa = value; break;
                case "tps": e.TpsPct = value; break;
                case "ect": e.EctCelsius = value; break;
                case "iat": e.IatCelsius = value; break;
                case "o2": e.O2Volts = value; break;
                case "vbatt": e.VbattVolts = value; break;
                case "speed": e.SpeedKmh = value; break;
                case "cranking": e.Cranking = value != 0; break;
                case "trigfault": e.Trigger = (TriggerFault)(int)value; break;
                case "baro": e.BaroKpa = value; break;
                case "oilpressure": Sim.Board.VtecPressureSwitch = value != 0; break;
                case "eld": e.EldVolts = value; break;
                case "egr": e.EgrLiftPct = value; break;
                case "crankvbatt": e.CrankingVbattVolts = value; break;
                case "ac": e.AcRequest = value != 0; break;
                case "power": Sim.Board.PowerGood = value != 0; break;
                // P13 port 4: the starter signal (pin 51) high while the starter turns; the power-steering switch (pin 52) low when active
                case "starter": Sim.Bus.StarterHeld = value != 0; break;
                case "psp": Sim.Bus.PowerSteeringPressure = value == 0; break;
                // raw switch buffers (P28): 8255 port A, and the 4700h buffer (bit 2 is the A/C switch above)
                case "porta": Sim.Bus.Ppi.PortAInput = (byte)value; break;
                case "sw4700": Sim.Bus.SwitchLatch = (byte)(((byte)value & ~0x04) | (e.AcRequest ? 0x04 : 0)); break;
            }
        }
    }


}
