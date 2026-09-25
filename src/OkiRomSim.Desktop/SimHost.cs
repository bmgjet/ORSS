// Copyright (c) bmgjet. All rights reserved.
using System.Diagnostics;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Owns the simulator and its background run loop, plus the build and calibration state. No Avalonia types in here, so it can be driven from a test or another front end.
public sealed class SimHost
{
    readonly object _lock = new();
    bool _running;
    double _speed = 1;
    string _stopReason = "nothing loaded";
    ushort? _skipOnce;
    /// Run until the call stack is back down to this depth (step over / step out).
    int? _runUntilDepth;
    string _runUntilWhy = "";
    /// Shadow call stack, rebuilt as the program runs: CAL/SCAL/VCAL frames and interrupt frames, each with the stack pointer value that identifies it.
    readonly List<Frame> _frames = [];
    public sealed record Frame(ushort Entry, ushort Return, ushort Ssp, bool Interrupt);
    // executed instructions, oldest first; their text is only formatted when shown
    readonly Queue<TraceEntry> _trace = new();
    DateTime _runStartWall;
    ulong _runStartCycles;
    long _runStartInstr;
    double _rate;
    Dictionary<long, string> _labels = [];
    /// Engine/board inputs as last set from the UI, re-applied to every freshly loaded simulator.
    readonly Dictionary<string, double> _inputs = [];

    public SimHost()
    {
        var t = new Thread(Loop) { IsBackground = true, Name = "sim" };
        t.Start();
        var u = new Thread(UploadLoop) { IsBackground = true, Name = "emulator-upload" };
        u.Start();
    }

    /// Bumped whenever the ROM image, the build or the definitions change (MCP caches).
    public int Version => _version;
    int _version;
    /// Raised (on the thread that changed it) when calibration data or definitions changed outside the Calibration page - an MCP agent, undo - so the page can redraw.
    public event Action<string, string?>? CalibrationChanged;
    public void RaiseCalibrationChanged(string what, string? item = null)
    {
        Interlocked.Increment(ref _version);
        try { CalibrationChanged?.Invoke(what, item); } catch { }
    }

    public Simulator Sim { get; private set; } = new();
    public AssemblyResult? Assembly { get; private set; }
    public DefinitionSet? Definitions { get; private set; }
    public string? LoadedPath { get; private set; }
    public bool IsRunning { get { lock (_lock) return _running; } }
    public double Speed { get { lock (_lock) return _speed; } set { lock (_lock) _speed = Math.Max(0, value); } }
    public bool RomDirty { get; private set; }
    /// Skip the ROM's boot delay loops in no real time (Simulator.FastForwardDelayLoops).
    public bool FastBoot { get; set { lock (_lock) { field = value; Sim.FastForwardDelayLoops = value; } } } = true;

    // ------------------------------------------------------------------ loading

    public void LoadImage(byte[] image, AssemblyResult? asm, string path)
    {
        lock (_lock)
        {
            var keep = Sim.Breakpoints.ToList();
            bool same = path == LoadedPath;
            Sim = new Simulator { FastForwardDelayLoops = FastBoot };
            Sim.LoadRom(image);
            Assembly = asm;
            Definitions = null;
            _labels = asm?.Symbols.Values.Where(s => s.Kind == SymbolKind.Label)
                .GroupBy(s => s.Value).ToDictionary(g => g.Key, g => g.First().Name) ?? [];
            LoadedPath = path;
            RomDirty = false;
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
    public void ApplyProfile(ProcessorProfile profile)
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

    public string LabelAt(long addr) => _labels.TryGetValue(addr, out var n) ? n : "";

    public DefinitionSet Defs()
    {
        lock (_lock)
        {
            if (Definitions != null) return Definitions;
            if (Assembly != null) Definitions = DefinitionBuilder.FromAssembly(Assembly, Path.GetFileName(LoadedPath ?? ""));
            else
            {
                Definitions = new DefinitionSet();
                var side = LoadedPath == null ? null : Path.ChangeExtension(LoadedPath, null) + ".okidef.json";
                if (side != null && File.Exists(side)) Definitions = DefinitionSet.Load(side);
                var sym = LoadedPath == null ? null : Path.ChangeExtension(LoadedPath, ".sym");
                if (sym != null && File.Exists(sym))
                    foreach (var line in File.ReadAllLines(sym))
                    {
                        var p = line.Split(' ', 2);
                        if (p.Length == 2 && int.TryParse(p[0], System.Globalization.NumberStyles.HexNumber, null, out var a))
                            Definitions.Symbols.TryAdd(p[1].Trim(), a);
                    }
            }
            Definitions.MergeBuiltinFormulas();
            return Definitions;
        }
    }

    // ------------------------------------------------------------------ building

    public sealed record BuildOutcome(bool Success, List<Diagnostic> Diagnostics, AssemblyResult? Assembly,
        long Milliseconds);

    /// Assemble a .asm and load the result into the simulator.
    public BuildOutcome Build(string path, Func<string, string?>? unsavedBuffers = null, bool load = true)
    {
        var sw = Stopwatch.StartNew();
        AssemblyResult? asm = null;
        var diags = new List<Diagnostic>();
        try
        {
            asm = new OkiAssembler(new AssemblerOptions { ReadFile = unsavedBuffers }).AssembleFile(path);
            diags.AddRange(asm.Diagnostics);
        }
        catch (Exception ex)
        {
            diags.Add(new Diagnostic(Severity.Error, path, 0, 0, ex.Message));
        }
        sw.Stop();
        bool ok = asm != null && diags.All(d => d.Severity != Severity.Error);
        if (ok && load) LoadImage(asm!.Image, asm, path);
        return new BuildOutcome(ok, diags, asm, sw.ElapsedMilliseconds);
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
            (d.Mnemonic.StartsWith("CAL") || d.Mnemonic.StartsWith("SCAL") || d.Mnemonic.StartsWith("VCAL")))
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

    /// One pass of the run loop: a slice of instructions, playback and the serial port.
    void Slice()
    {
        {
            bool running;
            lock (_lock) running = _running;
            if (!running) { Thread.Sleep(15); return; }
            lock (_lock)
            {
                // Run in short time slices and let go of the lock between them, so the UI (and an MCP agent) always gets in - at unlimited speed too.
                int budget = 200_000;
                if (_speed > 0)
                {
                    double wall = (DateTime.UtcNow - _runStartWall).TotalSeconds;
                    if (Sim.Cpu.Cycles - _runStartCycles > wall * _speed * Bus.CpuHz) budget = 0;
                }
                long sliceEnd = Stopwatch.GetTimestamp() + (Stopwatch.Frequency / 250);     // 4 ms
                for (int i = 0; i < budget && _running; i++)
                {
                    if ((i & 511) == 511 && Stopwatch.GetTimestamp() > sliceEnd) break;
                    if (_speed > 0 && (i & 255) == 255)
                    {
                        double wall = (DateTime.UtcNow - _runStartWall).TotalSeconds;
                        if (Sim.Cpu.Cycles - _runStartCycles > wall * _speed * Bus.CpuHz) break;
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

    /// The simulated serial line is a K-line: the ROM hears its own bytes (the stock tester protocol needs it).
    public bool SerialKLine
    {
        get { lock (_lock) return Sim.Bus.KLineEcho; }
        set { lock (_lock) { Sim.Bus.KLineEcho = value; Sim.Bus.KLineByteCycles = (uint)Math.Max(1, (long)Bus.CpuHz * 10 / Math.Max(300, SerialBaud)); } }
    }

    /// Send bytes to the simulated ROM's serial port, as a datalogging tool would.
    public void SerialToRom(byte[] data)
    {
        lock (_lock) Sim.Bus.QueueSerialRx(data, (uint)Math.Max(1, (long)Bus.CpuHz * 10 / Math.Max(300, SerialBaud)));
    }

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
        foreach (var b in Sim.Bus.TakeSerialTx()) _romTx.Enqueue(b);
        while (_romTx.Count > 65536) _romTx.Dequeue();
    }

    // ------------------------------------------------------------------ datalog playback

    List<LogFrame>? _play;
    int _playIndex;
    double _playSimStart, _playLogStart;
    public int PlaybackIndex { get { lock (_lock) return _playIndex; } }
    public bool PlaybackActive { get { lock (_lock) return _play != null; } }
    double SimNow => (double)Sim.Cpu.Cycles / Bus.CpuHz;

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

    /// Hits reported by a Moates Ostrich/Demon trace (the simulator's own hits come from its coverage and ROM-read counters).
    public readonly HitStore ExternalHits = new();

    /// Hit state of the simulated ROM: per address, the cycle it last ran as an instruction (0 = never) and the cycle it was last read as data, plus the current cycle.
    // reused between calls: three arrays of 32768 rebuilt several times a second was a lot of rubbish for the collector to clear up
    ulong[]? _hitExec, _hitData;
    uint[]? _hitCount;

    public (ulong Now, ulong[] Exec, ulong[] Data, uint[] DataCount) SimHits()
    {
        lock (_lock)
        {
            _hitExec ??= new ulong[Bus.RomSize];
            _hitData ??= new ulong[Bus.RomSize];
            _hitCount ??= new uint[Bus.RomSize];
            for (int a = 0; a < Bus.RomSize; a++) _hitExec[a] = Sim.Coverage.LastExecuted((ushort)a);
            Array.Copy(Sim.Bus.RomReadAt, _hitData, Bus.RomSize);
            Array.Copy(Sim.Bus.RomReadCount, _hitCount, Bus.RomSize);
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
        double hz = Bus.CpuHz;
        int count = item.Count;
        for (int i = 0; i < count; i++)
        {
            int a = item.CellAddress(i);
            if ((uint)a >= Bus.RomSize || b.RomReadCount[a] == 0) continue;
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
        List<(int Address, string Label, string Source)> Breakpoints,
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
                src?.File, src?.Line ?? 0, (long)c.Instructions, (double)c.Cycles / Bus.CpuHz, _running ? _rate : 0,
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
                [.. Sim.Breakpoints.OrderBy(x => x).Select(x =>
                {
                    var s = Assembly?.Lookup(x);
                    return ((int)x, LabelAt(x), s == null ? "" : $"{Path.GetFileName(s.File)}:{s.Line}");
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
                Inputs = new(_inputs),
                ForcedPins = [.. _forced.Select(kv => $"{kv.Key.Port}.{kv.Key.Bit}={(kv.Value ? 1 : 0)}")],
                Analog = new(_analog),
                CrystalMHz = Bus.CrystalMHz,
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
            Sim.Engine.CkpPulseCount = st.CkpCount; Sim.Engine.TdcPulseCount = st.TdcCount;
            Sim.Breakpoints.Clear();
            foreach (var bp in st.Breakpoints) Sim.Breakpoints.Add(bp);
            RomDirty = !rom.AsSpan().SequenceEqual(Assembly?.Image ?? rom);
            _trace.Clear();
            foreach (var t in st.Trace)
            {
                var i = t.IndexOf('|');
                if (i > 0 && ushort.TryParse(t[..i], System.Globalization.NumberStyles.HexNumber, null, out var pc)) _trace.Enqueue(new TraceEntry(pc, t[(i + 1)..]));
            }
            Sim.SyncSensors();
            ResetRates();
            _stopReason = "project restored";
        }
    }

    /// Forget everything tied to the ROM that was open: definitions, undo, coverage, hits, traces and caches. Called when another ROM is opened and by Clear project.
    public void ResetRomState()
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
    public void Clear()
    {
        lock (_lock)
        {
            _running = false;
            ResetRomState();
            Sim = new Simulator { FastForwardDelayLoops = FastBoot };
            _hitExec = null; _hitData = null; _hitCount = null;
            Assembly = null;
            _labels = [];
            LoadedPath = null;
            RomDirty = false;
            _stopReason = "nothing loaded";
            ResetRates();
        }
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        AppLog.Info("host", "project cleared");
    }

    public void ReplaceDefinitions(DefinitionSet defs) { lock (_lock) { defs.MergeBuiltinFormulas(); Definitions = defs; Interlocked.Increment(ref _version); } }

    /// Run a change to the definitions under the simulator lock.
    public T EditDefinitions<T>(Func<DefinitionSet, T> change)
    {
        lock (_lock) { var r = change(Defs()); Interlocked.Increment(ref _version); return r; }
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
        double dt = (double)(now - _rateCycles) / Bus.CpuHz;
        if (dt >= 0.5)
        {
            for (int n = 0; n < 4; n++) { _injPerSec[n] = (b.InjectorEvents[n] - _rateInj[n]) / dt; _rateInj[n] = b.InjectorEvents[n]; }
            _sparksPerSec = (b.IgnitionEvents - _rateSparks) / dt; _rateSparks = b.IgnitionEvents;
            for (int p = 0; p < 5; p++)
                for (int i = 0; i < 8; i++)
                { _pinPerSec[p, i] = (pins.Changes[p, i] - _ratePins[p, i]) / dt; _ratePins[p, i] = pins.Changes[p, i]; }
            _rateCycles = now;
        }
        double Ms(ulong cycles) => cycles * 1000.0 / Bus.CpuHz;
        bool Stale(ulong at) => now - at > Bus.CpuHz;   // nothing for a second: show as stopped
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

    /// "label+offset" for an address, from the assembled source's labels.
    public string NearestLabel(int addr)
    {
        long best = -1;
        foreach (var k in _labels.Keys) if (k <= addr && k > best) best = k;
        return best < 0 ? "" : addr == best ? _labels[best] : $"{_labels[best]}+{addr - best:X}";
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
            for (int n = 0; n < count && pc < Bus.RomSize; n++)
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
                b[i] = a >= 0x480 && a < Bus.RomSize ? Sim.Bus.Rom[a] : Sim.Bus.Ram[a & (Bus.RamSize - 1)];
            }
            return b;
        }
    }

    public void WriteRam(int addr, byte value)
    {
        lock (_lock) { if (addr >= 0 && addr < Bus.RamSize) Sim.Bus.WriteDataU8((ushort)addr, value); }
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
        if (Sim.Breakpoints.Contains(a)) { Sim.Breakpoints.Remove(a); return (true, a, false, ""); }
        Sim.Breakpoints.Add(a);
        return (true, a, true, "");
    }

    /// Set a breakpoint at a label or address, whether or not one is already there (the Breakpoints page's Add). `added` is false when it was already set.
    public (bool ok, int address, bool added, string error) AddBreakpoint(string text)
    {
        lock (_lock)
        {
            if (!Defs().TryResolve(text, out var a)) return (false, 0, false, $"cannot resolve '{text}'");
            ushort addr = (ushort)a;
            if (Sim.Breakpoints.Contains(addr)) return (true, addr, false, "");
            Sim.Breakpoints.Add(addr);
            return (true, addr, true, "");
        }
    }

    /// Take one breakpoint away, leaving the others (the Breakpoints page's Remove).
    public bool RemoveBreakpoint(int address) { lock (_lock) return Sim.Breakpoints.Remove((ushort)address); }

    public void ClearBreakpoints() { lock (_lock) Sim.Breakpoints.Clear(); }

    /// Run the calibration detector on the built ROM, reading its sources from disk. Returns the summary, or null when there is nothing built to detect from.
    public string? DetectDefinitions()
    {
        var asm = Assembly;
        if (asm == null) return null;
        var sources = asm.SourceMap.Select(e => e.File).Distinct()
            .Where(File.Exists).Select(f => (Path: f, Text: File.ReadAllText(f))).ToList();
        var rom = RomBytes(0, Bus.RomSize);
        var r = EditDefinitions(d => CalibrationDetector.Detect(d, asm, rom, sources));
        return r.Summary;
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
            bool scc = !Bus.Is66911 && (Sim.Bus.Ppi.PortAInput & 0x80) != 0;
            return new MilView(m.Lamp, m.Flash, scc, m.Flashing, [.. m.LastRound], [.. m.CurrentRound], stored, _milStored, current, _milField);
        }
    }

    public void SetInput(string name, double value)
    {
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
                case "baro": e.BaroKpa = value; break;
                case "oilpressure": Sim.Board.VtecPressureSwitch = value != 0; break;
                case "eld": e.EldVolts = value; break;
                case "egr": e.EgrLiftPct = value; break;
                case "crankvbatt": e.CrankingVbattVolts = value; break;
                case "ac": e.AcRequest = value != 0; break;
                case "power": Sim.Board.PowerGood = value != 0; break;
                // P13 port 4 pins 51/52 read low when active
                case "starter": Sim.Bus.StarterSignal = value == 0; break;
                case "psp": Sim.Bus.PowerSteeringPressure = value == 0; break;
                // raw switch buffers (P28): 8255 port A, and the 4700h buffer (bit 2 is the A/C switch above)
                case "porta": Sim.Bus.Ppi.PortAInput = (byte)value; break;
                case "sw4700": Sim.Bus.SwitchLatch = (byte)(((byte)value & ~0x04) | (e.AcRequest ? 0x04 : 0)); break;
            }
        }
    }

    public List<XrefHit> Xref(string target, int max = 60)
    {
        lock (_lock)
        {
            var defs = Defs();
            if (!defs.TryResolve(target, out var addr)) return [];
            var labels = defs.Symbols.GroupBy(kv => kv.Value).ToDictionary(g => g.Key, g => g.First().Key);
            return Calibration.Xref.Find([.. Sim.Bus.Rom], addr,
                Assembly?.SourceMap.Select(e => e.Address),
                a => labels.GetValueOrDefault(a, ""),
                a => Assembly?.Lookup(a) is { } e ? $"{Path.GetFileName(e.File)}:{e.Line}" : null,
                maxHits: max);
        }
    }

    public List<(string Name, int Address, int Offset, string Kind)> Lookup(string q)
    {
        lock (_lock)
        {
            var defs = Defs();
            q = q.Trim();
            var res = new List<(string, int, int, string)>();
            bool looksHex = q.Length > 0 && (q.All(Uri.IsHexDigit) || q.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ||
                                             q.EndsWith("h", StringComparison.OrdinalIgnoreCase));
            if (looksHex && defs.TryResolve(q, out var addr))
            {
                foreach (var (nm, a) in defs.SymbolsAt(addr, 64).Take(4)) res.Add((nm, a, addr - a, "near"));
                var s = Assembly?.Lookup(addr);
                res.Add(($"0x{addr:X4}", addr, 0, s == null ? "address" : $"{Path.GetFileName(s.File)}:{s.Line}"));
            }
            foreach (var kv in defs.Symbols.Where(kv => kv.Key.Contains(q, StringComparison.OrdinalIgnoreCase))
                         .OrderBy(kv => kv.Key.Length).Take(60))
                res.Add((kv.Key, kv.Value, 0, "symbol"));
            foreach (var i in defs.Items.Where(i => i.Name.Contains(q, StringComparison.OrdinalIgnoreCase)).Take(20))
                res.Add((i.Name, i.Address, 0, "setting"));
            return res;
        }
    }

    // ------------------------------------------------------------------ calibration

    public CellValue[] ReadItem(ItemDef item)
    {
        lock (_lock) return RomData.Read(Defs(), Sim.Bus.Rom, item);
    }

    public CellValue WriteItem(ItemDef item, int index, double value, bool raw = false)
    {
        lock (_lock)
        {
            var defs = Defs();
            if (raw) RomData.WriteRawCell(Sim.Bus.Rom, item, index, value);
            else RomData.Write(defs, Sim.Bus.Rom, item, index, value);
            Sim.InvalidateDecodeCache();
            RomDirty = true;
            Interlocked.Increment(ref _version);
            QueueUpload(item.CellAddress(index), item.ElementSize);
            return RomData.Read(defs, Sim.Bus.Rom, item)[index];
        }
    }

    /// Write several cells as one undoable step (the Calibration page and MCP agents).
    public void WriteCells(ItemDef item, IReadOnlyList<(int Index, double Value)> cells, bool raw, string what)
    {
        if (cells.Count == 0) return;
        lock (_lock)
        {
            int lo = cells.Min(c => item.CellAddress(c.Index)), hi = cells.Max(c => item.CellAddress(c.Index)) + item.ElementSize;
            var before = RomBytes(lo, hi - lo);
            var defs = Defs();
            foreach (var (i, v) in cells)
            {
                if (raw) RomData.WriteRawCell(Sim.Bus.Rom, item, i, v);
                else RomData.Write(defs, Sim.Bus.Rom, item, i, v);
            }
            Sim.InvalidateDecodeCache();
            RomDirty = true;
            var after = RomBytes(lo, hi - lo);
            if (!before.AsSpan().SequenceEqual(after)) PushUndo(lo, before, after, $"{item.Name} {what}");
            Interlocked.Increment(ref _version);
            QueueUpload(lo, hi - lo);
        }
    }

    /// Write scattered bytes (a scaling, an imported section) as one undoable step. The bytes are given as addresses, so a table and the multiplier row beside it change together.
    public int ApplyPatches(IReadOnlyList<BytePatch> patches, string what)
    {
        if (patches.Count == 0) return 0;
        lock (_lock)
        {
            int lo = patches.Min(p => p.Address), hi = patches.Max(p => p.Address) + 1;
            if (lo < 0 || hi > Sim.Bus.Rom.Length) throw new ArgumentOutOfRangeException(nameof(patches), "a patch is outside the ROM");
            var before = RomBytes(lo, hi - lo);
            foreach (var p in patches) Sim.Bus.Rom[p.Address] = p.Value;
            Sim.InvalidateDecodeCache();
            RomDirty = true;
            var after = RomBytes(lo, hi - lo);
            if (before.AsSpan().SequenceEqual(after)) return 0;
            PushUndo(lo, before, after, what);
            Interlocked.Increment(ref _version);
            QueueUpload(lo, hi - lo);
            return patches.Count;
        }
    }

    // undo / redo of ROM edits: (address, bytes before, bytes after, description)
    readonly Stack<(int Addr, byte[] Before, byte[] After, string What)> _undo = new(), _redo = new();

    public void PushUndo(int addr, byte[] before, byte[] after, string what)
    {
        lock (_lock) { _undo.Push((addr, before, after, what)); _redo.Clear(); }
    }

    public string? Undo()
    {
        lock (_lock)
        {
            if (_undo.Count == 0) return null;
            var u = _undo.Pop();
            PatchRom(u.Addr, u.Before);
            _redo.Push(u);
            return u.What;
        }
    }

    public string? Redo()
    {
        lock (_lock)
        {
            if (_redo.Count == 0) return null;
            var u = _redo.Pop();
            PatchRom(u.Addr, u.After);
            _undo.Push(u);
            return u.What;
        }
    }

    // ------------------------------------------------------------------ ROM emulator

    /// The Moates Ostrich 2.0 / Demon, shared by the Calibration page (upload), the Hit trace page (trace) and MCP agents.
    public readonly MoatesTrace Emulator = new();
    /// Upload every calibration edit to the emulator as it is made.
    public bool AutoUpload { get; set; }
    public string EmulatorStatus { get; private set; } = "not connected";
    readonly object _uploadLock = new();
    int _uploadLo = int.MaxValue, _uploadHi = -1;
    readonly AutoResetEvent _uploadWake = new(false);

    void QueueUpload(int addr, int len)
    {
        if (!AutoUpload || !Emulator.Connected) return;
        lock (_uploadLock)
        {
            _uploadLo = Math.Min(_uploadLo, addr);
            _uploadHi = Math.Max(_uploadHi, addr + Math.Max(1, len));
        }
        _uploadWake.Set();
    }

    void UploadLoop()
    {
        while (true)
        {
            try { UploadSlice(); }
            catch (Exception ex) { AppLog.Error("emulator", "upload thread", ex); Thread.Sleep(200); }
        }
    }

    void UploadSlice()
    {
        {
            _uploadWake.WaitOne();
            Thread.Sleep(40);      // let a burst of edits coalesce into one write
            int lo, hi;
            lock (_uploadLock) { lo = _uploadLo; hi = _uploadHi; _uploadLo = int.MaxValue; _uploadHi = -1; }
            if (hi < 0 || !Emulator.Connected) return;
            try
            {
                var rom = RomBytes(0, Bus.RomSize);
                Emulator.WriteRange(rom, lo, hi - lo);
                EmulatorStatus = $"{Emulator.Version}: uploaded {lo:X4}-{hi - 1:X4} at {DateTime.Now:HH:mm:ss}";
                AppLog.Write(LogKind.Serial, "emulator", $"uploaded {lo:X4}-{hi - 1:X4}");
            }
            catch (Exception ex)
            {
                EmulatorStatus = "upload failed: " + ex.Message;
                AppLog.Error("emulator", "upload failed", ex);
            }
        }
    }

    public string EmulatorConnect(string port)
    {
        var v = Emulator.Connect(port);
        EmulatorStatus = $"{v} on {port}";
        return EmulatorStatus;
    }

    public string EmulatorUploadAll()
    {
        var rom = RomBytes(0, Bus.RomSize);
        Emulator.Upload(rom);
        EmulatorStatus = $"{Emulator.Version}: whole ROM uploaded at {DateTime.Now:HH:mm:ss}";
        AppLog.Write(LogKind.Serial, "emulator", "uploaded the whole ROM");
        return EmulatorStatus;
    }

    /// Read the image back out of the emulator and compare it with the one here.
    public string EmulatorValidate()
    {
        var rom = RomBytes(0, Bus.RomSize);
        var (diff, first) = Emulator.Validate(rom);
        EmulatorStatus = diff == 0
            ? $"{Emulator.Version}: the emulator matches this ROM ({rom.Length} bytes checked at {DateTime.Now:HH:mm:ss})"
            : $"{Emulator.Version}: {diff} byte(s) differ, first at {first:X4} - upload again";
        AppLog.Write(LogKind.Serial, "emulator", EmulatorStatus);
        return EmulatorStatus;
    }

    /// Take what is in the emulator and make it the ROM here (undoable in one step).
    public string EmulatorDownload()
    {
        var there = Emulator.Download(Bus.RomSize);
        var here = RomBytes(0, Bus.RomSize);
        var patches = new List<BytePatch>();
        for (int i = 0; i < there.Length; i++) if (there[i] != here[i]) patches.Add(new BytePatch(i, there[i]));
        if (patches.Count == 0)
        {
            EmulatorStatus = $"{Emulator.Version}: the emulator already holds this ROM";
            return EmulatorStatus;
        }
        ApplyPatches(patches, $"downloaded {patches.Count} byte(s) from the emulator");
        EmulatorStatus = $"{Emulator.Version}: {patches.Count} byte(s) taken from the emulator (Undo puts them back)";
        AppLog.Write(LogKind.Serial, "emulator", EmulatorStatus);
        return EmulatorStatus;
    }

    public void EmulatorDisconnect()
    {
        Emulator.Close();
        EmulatorStatus = "not connected";
    }

    /// A copy of the whole ROM image, for working something out without holding the lock (a scaling preview, an export).
    public byte[] RomCopy()
    {
        lock (_lock) return [.. Sim.Bus.Rom];
    }

    public byte[] RomBytes(int addr, int len)
    {
        lock (_lock)
        {
            var b = new byte[Math.Max(0, len)];
            for (int i = 0; i < b.Length; i++) b[i] = Sim.Bus.Rom[(addr + i) & (Bus.RomSize - 1)];
            return b;
        }
    }

    /// Put bytes back into the running ROM (calibration undo/redo).
    public void PatchRom(int addr, byte[] bytes)
    {
        lock (_lock)
        {
            for (int i = 0; i < bytes.Length; i++) Sim.Bus.Rom[(addr + i) & (Bus.RomSize - 1)] = bytes[i];
            Sim.InvalidateDecodeCache();
            RomDirty = true;
            Interlocked.Increment(ref _version);
            QueueUpload(addr, bytes.Length);
        }
    }

    public double[] AxisValues(AxisDef? axis, int count)
    {
        lock (_lock) return RomData.AxisValues(Defs(), Sim.Bus.Rom, axis, count);
    }

    public void SaveRom(string path)
    {
        lock (_lock)
        {
            if (File.Exists(path)) File.Copy(path, path + ".bak", overwrite: true);
            File.WriteAllBytes(path, [.. Sim.Bus.Rom]);
            RomDirty = false;
        }
    }
}
