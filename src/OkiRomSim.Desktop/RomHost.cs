// Copyright (c) bmgjet. All rights reserved.
using System.Diagnostics;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// The ROM open for tuning, with nothing of the simulator in it: the image, the build it came from and its definitions, every
/// calibration edit (the checksum kept right, undo and redo), and the ROM emulator (connect, compare, upload every change as it is
/// made). The full program's SimHost is one of these with the simulator added - its ROM array is the simulator's own, so the program
/// it runs is the one being tuned - and the tuning-only build (RomSimTuner) uses this on its own. No Avalonia types in here, so it can
/// be driven from a test or another front end.
public class RomHost
{
    protected readonly object _lock = new();
    /// The image. In SimHost this is the simulator's own ROM array (Sim.Bus.Rom), put back here whenever the simulator is replaced.
    protected byte[] Rom = new byte[Chip.RomSize];
    protected Dictionary<long, string> _labels = [];

    public RomHost()
    {
        var u = new Thread(UploadLoop) { IsBackground = true, Name = "emulator-upload" };
        u.Start();
    }

    /// Bumped whenever the ROM image, the build or the definitions change (MCP caches).
    public int Version => _version;
    protected int _version;
    /// Raised (on the thread that changed it) when calibration data or definitions changed outside the Calibration page - an MCP client, undo - so the page can redraw.
    public event Action<string, string?>? CalibrationChanged;
    public void RaiseCalibrationChanged(string what, string? item = null)
    {
        Interlocked.Increment(ref _version);
        try { CalibrationChanged?.Invoke(what, item); } catch { }
    }

    public AssemblyResult? Assembly { get; protected set; }
    public DefinitionSet? Definitions { get; protected set; }
    public string? LoadedPath { get; protected set; }
    public bool RomDirty { get; protected set; }

    /// The ROM's bytes changed in place (an edit, an undo): SimHost drops the simulator's decoded-instruction cache.
    protected virtual void RomBytesChanged() { }

    // ------------------------------------------------------------------ loading

    /// Put a new image in place (a .bin opened, a build) with the build it came from, if any, and where it came from: the definitions
    /// are worked out afresh, the undo history and the unsaved mark start again.
    public virtual void LoadImage(byte[] image, AssemblyResult? asm, string path)
    {
        lock (_lock)
        {
            var fresh = SizedImage(image);
            NoteImageReplaced(image);
            Rom = fresh;
            Assembly = asm;
            ChecksumAddress = RomChecksum.Site(image, asm);
            Definitions = null;
            _labels = asm?.Symbols.Values.Where(s => s.Kind == SymbolKind.Label)
                .GroupBy(s => s.Value).ToDictionary(g => g.Key, g => g.First().Name) ?? [];
            LoadedPath = path;
            RomDirty = false;
            _undo.Clear(); _redo.Clear();
            Interlocked.Increment(ref _version);
        }
    }

    /// The image as the ROM space holds it: exactly 32 KB, or 32 KB and one trailing 00 byte - the sizes the simulator takes
    /// (Bus.LoadRomBytes), so a ROM the full program refuses is refused here too.
    protected static byte[] SizedImage(byte[] image)
    {
        if (image.Length == Chip.RomSize || (image.Length == Chip.RomSize + 1 && image[Chip.RomSize] == 0)) return image[..Chip.RomSize];
        throw new InvalidDataException($"expected a {Chip.RomSize}-byte ROM image (optionally followed by one 00 byte), got {image.Length} bytes");
    }

    /// Under the lock, before a new image replaces the one here: a new image (a full Build, a project) while the emulator is
    /// connected leaves the emulator holding the old one, so uploads of edits are blocked - they would splice blocks of the new layout
    /// into the old image - until the whole ROM is uploaded again.
    protected void NoteImageReplaced(byte[] image)
    {
        if (Emulator.Connected && _emuInSync && !Rom.AsSpan(0, Math.Min(Rom.Length, image.Length)).SequenceEqual(image.AsSpan(0, Math.Min(Rom.Length, image.Length))))
        {
            _emuInSync = false;
            EmulatorStatus = "the ROM here was rebuilt: the emulator still holds the one from before (Emulator > Upload sends this one; edits are not sent until then)";
            AppLog.Warn("emulator", EmulatorStatus);
        }
    }

    /// Make a processor profile active (clock, names, pins). (SimHost also restarts the simulated image from reset, so the new clock applies.)
    public virtual void ApplyProfile(ProcessorProfile profile)
    {
        lock (_lock)
        {
            profile.Apply();
            Interlocked.Increment(ref _version);
        }
    }

    /// Forget everything tied to the ROM that was open: definitions, undo, the emulator's hits. Called when another ROM is opened and by Clear.
    public virtual void ResetRomState()
    {
        lock (_lock)
        {
            Definitions = null;
            _undo.Clear(); _redo.Clear();
            ExternalHits.Clear();
            Interlocked.Increment(ref _version);
        }
    }

    /// Close the ROM and let go of everything: a fresh, low-memory state.
    public virtual void Clear()
    {
        lock (_lock)
        {
            ResetRomState();
            Rom = new byte[Chip.RomSize];
            Assembly = null;
            _labels = [];
            LoadedPath = null;
            ForgetUploads(true);
            RomDirty = false;
        }
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        AppLog.Info("host", "project cleared");
    }

    public string LabelAt(long addr) => _labels.TryGetValue(addr, out var n) ? n : "";

    /// "label+offset" for an address, from the assembled source's labels.
    public string NearestLabel(int addr)
    {
        long best = -1;
        foreach (var k in _labels.Keys) if (k <= addr && k > best) best = k;
        return best < 0 ? "" : addr == best ? _labels[best] : $"{_labels[best]}+{addr - best:X}";
    }


    /// After a patch build: the definitions from the new build, and every one the old set had that the source does not
    /// (found by Detect, or defined by an MCP client with cal_define) carried across, so the Calibration pages lose nothing.
    protected void KeepDefinitions(DefinitionSet? old)
    {
        if (old == null) return;
        var fresh = Defs();
        foreach (var f in old.Formulas.Where(f => !fresh.Formulas.Any(x => x.Name.Equals(f.Name, StringComparison.OrdinalIgnoreCase)))) fresh.Formulas.Add(f);
        foreach (var it in old.Items.Where(it => !fresh.Items.Any(x => x.Name.Equals(it.Name, StringComparison.OrdinalIgnoreCase) || x.Address == it.Address)))
            fresh.Items.Add(it);
    }

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
                // one that cannot be read leaves the ROM without it (and says so in the log): thrown from here, the first read of the
                // ROM failed and every later one found an empty set without the built-in formulas
                if (side != null && File.Exists(side))
                    try { Definitions = DefinitionSet.Load(side); }
                    catch (Exception ex) { AppLog.Warn("definitions", $"{Path.GetFileName(side)} could not be read ({ex.Message}): the ROM is open without it"); }
                var sym = LoadedPath == null ? null : Path.ChangeExtension(LoadedPath, ".sym");
                if (sym != null && File.Exists(sym))
                    try
                    {
                        foreach (var line in File.ReadAllLines(sym))
                        {
                            var p = line.Split(' ', 2);
                            if (p.Length == 2 && int.TryParse(p[0], System.Globalization.NumberStyles.HexNumber, null, out var a))
                                Definitions.Symbols.TryAdd(p[1].Trim(), a);
                        }
                    }
                    catch (Exception ex) { AppLog.Warn("definitions", $"{Path.GetFileName(sym)} could not be read ({ex.Message})"); }
            }
            Definitions.MergeBuiltinFormulas();
            return Definitions;
        }
    }

    protected RamEntry[]? _ramMap;
    object? _ramMapFor;
    /// What each RAM byte holds (RamMap), for the loaded ROM.
    public IReadOnlyList<RamEntry> RamMapNow()
    {
        lock (_lock)
        {
            var defs = Defs();
            if (_ramMap == null || !ReferenceEquals(_ramMapFor, defs)) { _ramMap = [.. RamMap.Build(defs, Assembly, Rom)]; _ramMapFor = defs; }
            return _ramMap;
        }
    }

    /// Put a saved set of definitions (a project's) in place. A ROM built from source keeps what its annotations say now (a module added or taken out since, a table the build moved), with the saved set's own additions on top.
    public void ReplaceDefinitions(DefinitionSet defs)
    {
        lock (_lock)
        {
            if (Assembly != null && Assembly.Annotations.Count > 0)
                defs = DefinitionSet.MergeSaved(DefinitionBuilder.FromAssembly(Assembly, Path.GetFileName(LoadedPath ?? "")), defs);
            defs.MergeBuiltinFormulas();
            Definitions = defs;
            Interlocked.Increment(ref _version);
        }
    }

    /// Run a change to the definitions under the simulator lock.
    public T EditDefinitions<T>(Func<DefinitionSet, T> change)
    {
        lock (_lock) { var r = change(Defs()); Interlocked.Increment(ref _version); return r; }
    }

    /// The MAP sensor the ROM says is fitted: its pressure formulas rebuilt to suit, and the datalog's MAP read on the same scale.
    public void RefreshMapSensor()
    {
        lock (_lock)
        {
            var defs = Defs();
            var rom = RomBytes(0, Chip.RomSize);
            MapSensorScale.ApplyFormulas(defs, rom);
            HondaDatalog.MapSensor = MapSensorScale.Of(defs, rom) ?? MapSensorScale.StockFor;
            var p13Load = MapSensorScale.P13LoadOf(defs, rom);
            HondaDatalog.P13Load = (p13Load.Gain, p13Load.Offset);
            // the functions' state channels are named from this build's symbols
            ModuleDebug.Name(Assembly?.Symbols.Values.Where(sy => sy.Kind is SymbolKind.Equate or SymbolKind.Define).Select(sy => (sy.Name, (long)sy.Value)));
            // ...and the RAM addresses picked on the ROM's Datalog page, for what the memory map says is at each
            var user = defs.Items.FirstOrDefault(i => i.Name.Equals("DatalogUserAddress", StringComparison.OrdinalIgnoreCase) || i.HasSlot("dlextra.user"));
            var ram = user != null ? RamMapNow() : [];
            for (int k = 0; k < 8; k++)
            {
                int at = user == null || user.Address + (k * 2) + 1 >= rom.Length ? 0 : rom[user.Address + (k * 2)] | (rom[user.Address + (k * 2) + 1] << 8);
                if (at is < 0x80 or >= RamMap.RamEnd) at = 0;
                UserRam.Set(k, at, ram.FirstOrDefault(e => e.Address == at)?.Name);
            }
            Interlocked.Increment(ref _version);
        }
    }

    /// Run the calibration detector on the built ROM, reading its sources from disk. Returns the summary, or null when there is nothing built to detect from.
    public string? DetectDefinitions()
    {
        var asm = Assembly;
        if (asm == null) return null;
        var sources = asm.SourceMap.Select(e => e.File).Distinct()
            .Where(File.Exists).Select(f => (Path: f, Text: File.ReadAllText(f))).ToList();
        var rom = RomBytes(0, Chip.RomSize);
        var refs = RomReference.ShippedFor(LoadedPath);
        var r = EditDefinitions(d => CalibrationDetector.Detect(d, asm, rom, sources, refs));
        return r.Summary;
    }

    public List<XrefHit> Xref(string target, int max = 60)
    {
        lock (_lock)
        {
            var defs = Defs();
            if (!defs.TryResolve(target, out var addr)) return [];
            var labels = defs.Symbols.GroupBy(kv => kv.Value).ToDictionary(g => g.Key, g => g.First().Key);
            return Calibration.Xref.Find([.. Rom], addr,
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


    // ------------------------------------------------------------------ building

    public sealed record BuildOutcome(bool Success, List<Diagnostic> Diagnostics, AssemblyResult? Assembly,
        long Milliseconds);

    /// Assemble a .asm and load the result (in the full program, into the simulator too).
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


    // ------------------------------------------------------------------ the emulator's trace

    /// Hits reported by a Moates Ostrich/Demon trace (the simulator's own hits come from its coverage and ROM-read counters).
    public readonly HitStore ExternalHits = new();

    // ------------------------------------------------------------------ calibration

    public CellValue[] ReadItem(ItemDef item)
    {
        lock (_lock) return RomData.Read(Defs(), Rom, item);
    }

    /// The byte that keeps the 8-bit sum of the ROM at 0, for a ROM that checks its own sum (the skeleton's "checksum" byte, or a free byte of a stock image that sums to 0). Every write below puts it right again, so the image in the simulator, in a saved .bin and in the emulator always passes the check.
    public int? ChecksumAddress { get; protected set; }

    /// The ROM checks its own 8-bit sum while it runs and resets when it is wrong: stock Honda code does, the skeleton only with its RomSumCheck switch on, HTS and the tuning ROMs not at all (they do not keep the sum). A change sent to an emulator while the engine runs can land part-way through a pass of that sum.
    public bool ChecksSumWhileRunning
    {
        get
        {
            lock (_lock)
            {
                if (ChecksumAddress == null) return false;
                if (Assembly?.Symbols.Values.FirstOrDefault(s => s.Name.Equals("RomSumCheck", StringComparison.OrdinalIgnoreCase)) is { } sw)
                    return Rom[(int)sw.Value & (Chip.RomSize - 1)] == 1;
                return RomChecksum.Sum(Rom) == 0;
            }
        }
    }

    /// The ROM's 8-bit sum now (0 = what a ROM checking its own sum needs), and the byte kept to balance it, if any.
    public (int Sum, int? Site) ChecksumNow()
    {
        lock (_lock) return (RomChecksum.Sum(Rom), ChecksumAddress);
    }

    /// Make the ROM's sum 0: with its balancing byte, or - a ROM that has none (HTS) - a free byte at the top of the ROM,
    /// which from then on every edit keeps right. What was done, for the status line.
    public string RecalculateChecksum()
    {
        lock (_lock)
        {
            ChecksumAddress ??= RomChecksum.Site(Rom, Assembly) ?? RomChecksum.FreeByte(Rom, Assembly);
            if (ChecksumAddress is not int at) return "no free byte at the top of the ROM to balance the sum with";
            byte was = Rom[at];
            if (RomChecksum.Balance(Rom, at)) QueueUpload(at, 1);
            Interlocked.Increment(ref _version);
            return $"checksum recalculated: byte {at:X4}h {was:X2}h -> {Rom[at]:X2}h, the ROM now sums to {RomChecksum.Sum(Rom):X2}h";
        }
    }

    /// Re-balance the checksum byte after the ROM changed (under the lock).
    protected void BalanceChecksum()
    {
        if (ChecksumAddress is not int at) return;
        if (RomChecksum.Balance(Rom, at)) QueueUpload(at, 1);
    }

    public CellValue WriteItem(ItemDef item, int index, double value, bool raw = false)
    {
        lock (_lock)
        {
            var defs = Defs();
            if (raw) RomData.WriteRawCell(Rom, item, index, value, defs);
            else RomData.Write(defs, Rom, item, index, value);
            BalanceChecksum();
            RomBytesChanged();
            RomDirty = true;
            Interlocked.Increment(ref _version);
            QueueUpload(item.CellAddress(index), item.ElementSize);
            return RomData.Read(defs, Rom, item)[index];
        }
    }

    /// Write several cells as one undoable step (the Calibration page and MCP clients). A definition's cells were written (on the thread that wrote them): the source may keep some of them (the build file of a New ROM keeps the ROM's name and version and the watermark).
    public event Action<ItemDef>? ItemWritten;

    public void WriteCells(ItemDef item, IReadOnlyList<(int Index, double Value)> cells, bool raw, string what)
    {
        WriteCellsCore(item, cells, raw, what);
        try { ItemWritten?.Invoke(item); } catch (Exception ex) { AppLog.Error("calibration", "after-write handler failed", ex); }
    }

    void WriteCellsCore(ItemDef item, IReadOnlyList<(int Index, double Value)> cells, bool raw, string what)
    {
        if (cells.Count == 0) return;
        lock (_lock)
        {
            int lo = cells.Min(c => item.CellAddress(c.Index)), hi = cells.Max(c => item.CellAddress(c.Index)) + item.ElementSize;
            var before = RomBytes(lo, hi - lo);
            var defs = Defs();
            foreach (var (i, v) in cells)
            {
                if (raw) RomData.WriteRawCell(Rom, item, i, v, defs);
                else RomData.Write(defs, Rom, item, i, v);
            }
            BalanceChecksum();
            RomBytesChanged();
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
            if (lo < 0 || hi > Rom.Length) throw new ArgumentOutOfRangeException(nameof(patches), "a patch is outside the ROM");
            var before = RomBytes(lo, hi - lo);
            foreach (var p in patches) Rom[p.Address] = p.Value;
            BalanceChecksum();
            RomBytesChanged();
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
    protected readonly Stack<(int Addr, byte[] Before, byte[] After, string What)> _undo = new(), _redo = new();

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

    /// The Moates Ostrich 2.0 / Demon, shared by the Calibration page (upload), the Trace page's Hit trace and MCP clients.
    public readonly MoatesTrace Emulator = new();
    /// Upload every calibration edit to the emulator as it is made. Switched on, whatever changed before (or while the emulator was away) goes up too.
    public bool AutoUpload { get => _autoUpload; set { _autoUpload = value; if (value) _uploadWake.Set(); } }
    bool _autoUpload;
    public string EmulatorStatus { get; private set; } = "not connected";
    readonly object _uploadLock = new();
    /// The 256-byte blocks changed here since they were last written to the emulator: every edit marks them, connected or not, so nothing is missed when uploading starts later or the link comes back.
    readonly bool[] _notUploaded = new bool[Chip.RomSize / 256];
    readonly AutoResetEvent _uploadWake = new(false);

    protected void QueueUpload(int addr, int len)
    {
        lock (_uploadLock)
            for (int b = Math.Max(0, addr) / 256; b <= Math.Min(Chip.RomSize - 1, addr + Math.Max(1, len) - 1) / 256; b++) _notUploaded[b] = true;
        if (AutoUpload && Emulator.Connected) _uploadWake.Set();
    }

    /// Held while the user is asked whether the emulator's ROM is to be replaced (just connected, and it holds a different one): edits waiting to go up must not land, block by block, in a ROM that may be kept.
    public volatile bool UploadsHeld;

    /// The emulator is known to hold the ROM open here - read back and found the same, or the whole ROM uploaded to it - so the blocks an
    /// edit changes can go up on their own. Cleared on every connect (until the compare), when the user keeps the emulator's own ROM, when
    /// an upload fails part way, and when the image here is replaced by a rebuild: a block written into a different ROM makes a mix of
    /// two images that the car then runs. Every way of connecting goes through this, including the Trace page and MCP clients.
    volatile bool _emuInSync;
    public bool EmulatorInSync => _emuInSync;

    /// The user kept the emulator's own ROM: edits made to the one here are not to be sent into it.
    public void DiscardPendingUploads() => ForgetUploads(true);

    /// The emulator holds a ROM other than this one, and the user kept it (or has not said yet): no edit goes into it until the whole ROM is uploaded.
    public void MarkEmulatorDiverged()
    {
        ForgetUploads(true);
        _emuInSync = false;
    }

    /// How many bytes the emulator holds differently from the ROM here (it is read back), and where the first is. The same: block uploads may go.
    public (int Differences, int FirstAt) EmulatorCompare()
    {
        var r = Emulator.Validate(RomBytes(0, Chip.RomSize));
        if (r.Differences == 0) _emuInSync = true;
        return r;
    }

    /// Bytes that differed at the last Validate.
    public int LastDifferences { get; private set; }

    /// Blocks not yet in the emulator, for the status line.
    public int NotUploadedBlocks { get { lock (_uploadLock) return _notUploaded.Count(x => x); } }

    protected void ForgetUploads(bool all, int lo = 0, int hi = 0)
    {
        lock (_uploadLock)
            if (all) Array.Clear(_notUploaded);
            else for (int b = lo / 256; b < (hi + 255) / 256; b++) _notUploaded[b] = false;
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
            _uploadWake.WaitOne(2000);  // and every so often: a link that came back takes what it missed
            Thread.Sleep(40);      // let a burst of edits coalesce into one write
            if (!AutoUpload || !Emulator.Connected || UploadsHeld || !_emuInSync) return;
            // nothing open (a cleared project): the emulator keeps what it has
            if (!CanUpload(out _)) { ForgetUploads(true); return; }
            // the port for the whole pass, so a full upload (or another pass) cannot land between this pass's snapshot and its writes
            using var port = Emulator.Hold();
            if (!Emulator.Connected || UploadsHeld || !_emuInSync) return;
            // every run of changed blocks, one write each - collected, taken off the list and copied out in one step under the ROM's lock:
            // every edit changes the bytes and marks its blocks under that lock, so an edit is either in this copy (and this pass writes
            // it) or marks its blocks again afterwards (and the next pass writes it). Copying the image first and clearing each run's
            // marks later lost an edit made in between, and could leave the checksum block one edit behind the table it belongs to.
            var runs = new List<(int Lo, int Hi)>();
            byte[] rom;
            lock (_lock)
            {
                lock (_uploadLock)
                    for (int b = 0; b < _notUploaded.Length; b++)
                    {
                        if (!_notUploaded[b]) continue;
                        int e = b;
                        while (e + 1 < _notUploaded.Length && _notUploaded[e + 1]) e++;
                        runs.Add((b * 256, (e + 1) * 256));
                        b = e;
                    }
                if (runs.Count == 0) return;
                // checked again here, under the lock a new image is put in place under: a rebuild between the check above and this copy
                // would otherwise send its blocks into the emulator that still holds the old image
                if (UploadsHeld || !_emuInSync) return;
                foreach (var (lo, hi) in runs) ForgetUploads(false, lo, hi);
                rom = RomBytes(0, Chip.RomSize);
            }
            for (int k = 0; k < runs.Count; k++)
            {
                var (lo, hi) = runs[k];
                try
                {
                    Emulator.WriteRange(rom, lo, hi - lo);
                    EmulatorStatus = $"{Emulator.Version}: uploaded {lo:X4}-{hi - 1:X4} at {DateTime.Now:HH:mm:ss}";
                    AppLog.Write(LogKind.Serial, "emulator", $"uploaded {lo:X4}-{hi - 1:X4}");
                }
                catch (Exception ex)
                {
                    // this run and the ones after it were taken off the list but not written: still to go, tried again on the next pass
                    for (int j = k; j < runs.Count; j++) QueueUpload(runs[j].Lo, runs[j].Hi - runs[j].Lo);
                    EmulatorStatus = "upload failed: " + ex.Message;
                    AppLog.Error("emulator", "upload failed", ex);
                    Thread.Sleep(500);
                    return;
                }
            }
        }
    }

    public string EmulatorConnect(string port)
    {
        // what a device holds is not known until it is read back (EmulatorCompare) or the whole ROM goes to it (EmulatorUploadAll)
        _emuInSync = false;
        var v = Emulator.Connect(port);
        EmulatorStatus = $"{v} on {port}";
        return EmulatorStatus;
    }

    /// Whether what is here may go to the emulator: a ROM has to be open, and the image must not be blank (all FF or all 00) - sending that would wipe what the emulator holds, which is the one thing an upload must never do by accident.
    public bool CanUpload(out string why)
    {
        why = "";
        if (LoadedPath == null) { why = "nothing is open here to upload (Download reads what the emulator has)"; return false; }
        var rom = RomBytes(0, Chip.RomSize);
        if (rom.All(b => b == 0xFF) || rom.All(b => b == 0x00)) { why = "the ROM here is blank: not uploaded, so the emulator keeps what it has"; return false; }
        return true;
    }

    public string EmulatorUploadAll()
    {
        if (!CanUpload(out var why)) { AppLog.Warn("emulator", "upload refused: " + why); throw new InvalidOperationException(why); }
        // the port for the whole upload, and the image copied out as the marks are cleared: an edit made meanwhile marks its blocks again
        // and goes up after; a block-upload pass cannot interleave with this one and write older bytes over it
        using (Emulator.Hold())
        {
            byte[] rom;
            lock (_lock)
            {
                ForgetUploads(true);
                rom = RomBytes(0, Chip.RomSize);
            }
            try { Emulator.Upload(rom); }
            catch
            {
                // part of it may have gone: the emulator holds a mix until the whole ROM goes again
                _emuInSync = false;
                QueueUpload(0, Chip.RomSize);
                throw;
            }
            _emuInSync = true;
        }
        EmulatorStatus = $"{Emulator.Version}: whole ROM uploaded at {DateTime.Now:HH:mm:ss}";
        AppLog.Write(LogKind.Serial, "emulator", "uploaded the whole ROM");
        return EmulatorStatus;
    }

    /// Read the image back out of the emulator and compare it with the one here.
    public string EmulatorValidate()
    {
        var rom = RomBytes(0, Chip.RomSize);
        var (diff, first) = Emulator.Validate(rom);
        LastDifferences = diff;
        if (diff == 0) _emuInSync = true;
        bool can = CanUpload(out var why);
        EmulatorStatus = diff == 0
            ? $"{Emulator.Version}: the emulator matches this ROM ({rom.Length} bytes checked at {DateTime.Now:HH:mm:ss})"
            : $"{Emulator.Version}: {diff} byte(s) differ, first at {first:X4}" + (!can ? " - " + why : "");
        AppLog.Write(LogKind.Serial, "emulator", EmulatorStatus);
        return EmulatorStatus;
    }

    /// Read the whole image out of the emulator into a .bin of its own (in the ROMs folder), to be opened as the ROM.
    public string EmulatorDownload(out string path)
    {
        var there = Emulator.Download(Chip.RomSize);
        var dir = AppPaths.Roms;
        Directory.CreateDirectory(dir);
        path = Path.Combine(dir, $"emulator-{DateTime.Now:yyyyMMdd-HHmmss}.bin");
        SafeFile.WriteAllBytes(path, there);
        EmulatorStatus = $"{Emulator.Version}: read {there.Length} bytes out of the emulator into {path}";
        AppLog.Write(LogKind.Serial, "emulator", EmulatorStatus);
        return EmulatorStatus;
    }

    public void EmulatorDisconnect()
    {
        _emuInSync = false;
        Emulator.Close();
        EmulatorStatus = "not connected";
    }

    /// A copy of the whole ROM image, for working something out without holding the lock (a scaling preview, an export).
    public byte[] RomCopy()
    {
        lock (_lock) return [.. Rom];
    }

    public byte[] RomBytes(int addr, int len)
    {
        lock (_lock)
        {
            var b = new byte[Math.Max(0, len)];
            for (int i = 0; i < b.Length; i++) b[i] = Rom[(addr + i) & (Chip.RomSize - 1)];
            return b;
        }
    }

    /// Put bytes back into the ROM (calibration undo/redo) - in the full program, the one the simulator is running.
    public void PatchRom(int addr, byte[] bytes)
    {
        lock (_lock)
        {
            for (int i = 0; i < bytes.Length; i++) Rom[(addr + i) & (Chip.RomSize - 1)] = bytes[i];
            BalanceChecksum();
            RomBytesChanged();
            RomDirty = true;
            Interlocked.Increment(ref _version);
            QueueUpload(addr, bytes.Length);
        }
    }

    public double[] AxisValues(AxisDef? axis, int count)
    {
        lock (_lock) return RomData.AxisValues(Defs(), Rom, axis, count);
    }

    public void SaveRom(string path)
    {
        lock (_lock)
        {
            if (File.Exists(path)) File.Copy(path, path + ".bak", overwrite: true);
            SafeFile.WriteAllBytes(path, [.. Rom]);
            RomDirty = false;
            LastSavedPath = path;
        }
    }

    /// Where SaveRom last wrote the image (the tuner offers the definitions file beside it).
    public string? LastSavedPath { get; private set; }
}
