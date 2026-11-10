// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Windows.Input;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Desktop;

namespace AlphaEmuPlugin;

/// The middleman everything else talks to: the settings, the session, the snapshots, the insights, the
/// commands, and the screens - plus the handful of things the app has to be asked for (a ROM, a dialog,
/// the status bar). One hub per loaded plugin; the screens never reach for the app themselves.
public sealed class AlphaHub
{
    public PluginContext App { get; }
    public AlphaState State { get; }
    public AlphaSession Session { get; }
    public AlphaSnapshots Snapshots { get; }
    public AlphaInsights Insights { get; } = new();
    public string Folder { get; }
    public byte[]? FirmwareBytes { get; set; }

    readonly DispatcherTimer _recovery;

    public AlphaHub(PluginContext app, AlphaState state)
    {
        App = app;
        State = state;
        Folder = app.DataFolder;
        Session = new AlphaSession(app, state);
        Snapshots = new AlphaSnapshots(this);
        Session.FrameArrived += f => { if (State.InsightsEnabled) Insights.Look(f); };
        Session.Logged += line => app.Log(line);
        _recovery = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        _recovery.Tick += (_, _) => Snapshots.RecoveryTick();
        _recovery.Start();
    }

    // ---------------------------------------------------------------- screens (each console makes its own)

    public AlphaMapsPage Maps() => new(this);
    public AlphaAnalogPage Analog() => new(this);
    public AlphaWidebandPage Wideband() => new(this);
    public AlphaSnapshotsPage SnapshotPage() => new(this);
    public AlphaDiagnosticsPage Diagnostics() => new(this);
    public AlphaDevicePage Device() => new(this);
    public AlphaLogPage Log() => new(this);

    /// The channels the console traces, in the app's own channel names, in the ALPHAlink colours.
    public static readonly ScopeTrace[] Traces =
    [
        new("RPM", "rpm", Alpha.Red, 0, 9000),
        new("TPS", "tps_pct", Alpha.Cyan, 0, 100),
        new("MAP", "map_kpa", Alpha.Amber, 0, 300),
        new("AFR", "afr", Alpha.Green, 10, 18),
        new("IGN", "ign_deg", Alpha.Blue, -10, 60),
        new("INJ", "inj_ms", Alpha.Orange, 0, 25, false),
        new("DUTY", "inj_duty_pct", Alpha.Purple, 0, 110, false),
        new("VSS", "speed_kmh", Alpha.Teal, 0, 220, false),
        new("ECT", "ect_c", Alpha.Sky, -20, 130, false),
        new("BATT", "batt_v", Alpha.Lime, 10, 16, false),
    ];

    public TopLevel? TopLevel => App.Window is TopLevel t ? t : null;
    public bool HasRom { get { try { return App.Sim.LoadedPath != null && App.Sim.RomCopy().Length > 0; } catch { return false; } } }
    public int RomSize() { try { return HasRom ? App.Sim.RomCopy().Length : 0x8000; } catch { return 0x8000; } }

    /// The command palette's window, so the menu, the key binding and the commands list all raise the
    /// same one instead of each carrying a palette of their own.
    public Window? PaletteWindow { get; set; }

    public string RomName()
    {
        try
        {
            var p = App.Sim.LoadedPath;
            if (string.IsNullOrEmpty(p)) return "no calibration loaded";
            var name = System.IO.Path.GetFileName(p);
            return App.Sim.RomDirty ? name + "  (unsaved changes)" : name;
        }
        catch { return "no calibration loaded"; }
    }

    // ---------------------------------------------------------------- things the screens ask for

    public void Ui(Action run) => App.Ui(run);
    public void Notify(string message) => App.SetStatus(message);
    public void ApplyWideband() => Session.ApplyWideband();

    DispatcherTimer? _saver;
    public void SaveSoon()
    {
        if (_saver == null)
        {
            var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(700) };
            t.Tick += (_, _) => { t.Stop(); State.Save(Folder); };
            _saver = t;
        }
        _saver.Stop();
        _saver.Start();
    }

    /// Stop everything the hub keeps running (the plugin is being switched off).
    public void Close()
    {
        _recovery.Stop();
        if (_saver != null) { _saver.Stop(); State.Save(Folder); }
        foreach (var (window, timer) in _screens.Values) { try { timer.Stop(); window.Close(); } catch { } }
        _screens.Clear();
        try { Session.Dispose(); } catch { }
    }

    /// A yes/no the caller can wait for, from the UI thread. The app's own dialog, pumped so the window
    /// stays alive while the answer is waited for. Off the UI thread it just waits for the answer.
    public bool Confirm(string title, string message)
    {
        bool? answer = null;
        App.Ui(async () =>
        {
            try { answer = await Dialogs.Confirm(App.Window, title, message); }
            catch { answer = false; }          // a dialog that cannot be shown is answered No, not waited on for minutes
        });
        var until = DateTime.UtcNow.AddMinutes(3);
        while (answer == null && DateTime.UtcNow < until)
        {
            if (Dispatcher.UIThread.CheckAccess()) Dispatcher.UIThread.RunJobs();
            Thread.Sleep(15);
        }
        return answer == true;
    }

    /// The same question for a caller that is not on the UI thread: it asks, and carries on, and the
    /// callback runs on the UI thread when the answer arrives.
    public void Ask(string title, string message, Action onYes)
        => App.Ui(async () => { if (await Dialogs.Confirm(App.Window, title, message)) App.Ui(onYes); });

    public void Connect() { Session.Connect(); if (Session.Phase == AlphaLinkPhase.Faulted) Notify(Session.Status); }
    public void Disconnect() => Session.Disconnect();
    public void Reconnect() { Session.Disconnect(); Session.Connect(); }

    public void ToggleRealtime()
    {
        Session.RealtimeEnabled = !Session.RealtimeEnabled;
        if (Session.RealtimeEnabled && Session.Phase is not (AlphaLinkPhase.Linked or AlphaLinkPhase.Logging))
        {
            Notify("real-time update needs the emulator linked first");
            Session.RealtimeEnabled = false;
            return;
        }
        Notify(Session.RealtimeEnabled
            ? "real-time update on: table edits go to the running image as you make them"
            : "real-time update off");
        SaveSoon();
    }

    public void ClearCodes() => Session.Run("clear codes", s => s.ClearTroubleCodes(),
        r => Notify(r.StartsWith("codes", StringComparison.OrdinalIgnoreCase) ? "the emulator's stored codes are gone" : r));

    /// Ask, then stage and apply. Returns false when nothing was started (no file, or the user said no).
    public bool ApplyFirmware(Action<string>? status, Action<double>? progress)
    {
        var bytes = FirmwareBytes;
        if (bytes == null || bytes.Length == 0) { Notify("pick the firmware file first (Stage a file…)"); return false; }
        if (!Confirm("Write firmware", $"Send {AlphaState.Bytes(bytes.Length)} to the emulator and apply it? The device decides whether it fits.")) return false;
        Session.Run("firmware", s => s.FirmwareApply(bytes, m => status?.Invoke(m)),
            r => { progress?.Invoke(100); Notify(r); });
        return true;
    }

    public void SnapshotNow(string? name)
    {
        var s = Snapshots.Capture(name ?? "");
        Notify(s == null ? "nothing to snapshot - no calibration is loaded"
                         : $"snapshot '{s.Name}' saved ({AlphaState.Bytes(s.Bytes)}, {s.ChangedFromPrevious} byte{(s.ChangedFromPrevious == 1 ? "" : "s")} from the one before)");
    }

    public void RestoreSnapshot(AlphaSnapshot? s)
    {
        if (s == null) { Notify("there is nothing to restore yet"); return; }
        var bytes = Snapshots.TryRead(s);
        if (bytes == null) { Notify("that snapshot's file is not on disk any more"); return; }
        if (!Confirm("Restore snapshot", $"'{s.Name}' ({AlphaState.Bytes(s.Bytes)}, saved {s.At:yyyy-MM-dd HH:mm}) goes into the editor as the working calibration. The editor keeps the undo.")) return;
        LoadIntoRom(bytes, "snapshot " + s.Name);
    }

    public void RestoreRecovery()
    {
        var bytes = Snapshots.RecoveryBytes();
        var rec = Snapshots.Recovery();
        if (bytes == null || rec == null) { Notify("no working recovery has been written yet"); return; }
        if (!Confirm("Restore working recovery", $"The recovery copy is {AlphaState.Bytes(bytes.Length)} of {rec.Value.Rom}, written {rec.Value.At:HH:mm:ss}. Put it in the editor?")) return;
        LoadIntoRom(bytes, "working recovery");
    }

    /// Put an image in the editor as the working calibration (the app keeps the undo, and real-time
    /// update sends it to the emulator if that is switched on).
    public void LoadIntoRom(byte[] bytes, string what)
    {
        try
        {
            var rom = App.Sim.RomCopy();
            int n = Math.Min(bytes.Length, rom.Length);
            if (bytes.Length != rom.Length) { Notify($"{what} is {AlphaState.Bytes(bytes.Length)} but the ROM in the editor is {AlphaState.Bytes(rom.Length)} - not loaded"); return; }
            App.Sim.PatchRom(0, bytes);
            App.Sim.RaiseCalibrationChanged("ALPHAemu " + what);
            Notify($"{what} loaded into the editor ({AlphaState.Bytes(n)}); the app has the undo");
        }
        catch (Exception ex) { Notify("could not load it: " + ex.Message); }
    }

    public void SaveLog(string text)
    {
        try
        {
            var path = Path.Combine(Folder, $"alphaemu-log-{DateTime.Now:yyyyMMdd-HHmmss}.txt");
            File.WriteAllText(path, text);
            Notify("log written to " + path);
        }
        catch (Exception ex) { Notify("could not write the log: " + ex.Message); }
    }

    public void OpenWideband() => OpenScreen("Wideband", 900, 620);

    public void OpenConsole()
    {
        var console = new AlphaConsole(this);
        App.OpenWindow("ALPHAemu console", console, 1180, 780);
    }

    /// One screen at a time in a window of its own, with a timer keeping it alive.
    readonly Dictionary<string, (Window Window, DispatcherTimer Timer)> _screens = new();

    /// Show one of the ALPHAemu screens in its own window, or raise the one already open.
    public void OpenScreen(string title, double width = 980, double height = 660)
    {
        if (_screens.TryGetValue(title, out var open)) { open.Window.Activate(); return; }
        IAlphaPage page = title switch
        {
            "Multi-map" => Maps(),
            "Analog inputs" => Analog(),
            "Wideband" => Wideband(),
            "Snapshots" => SnapshotPage(),
            "Diagnostics" => Diagnostics(),
            "Device" => Device(),
            "Log" => Log(),
            _ => Log(),
        };
        var w = App.OpenWindow("ALPHAemu - " + title, page.Content, width, height);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        timer.Tick += (_, _) => page.Refresh();
        w.Closed += (_, _) => { timer.Stop(); _screens.Remove(title); };
        _screens[title] = (w, timer);
        timer.Start();
    }

    // ---------------------------------------------------------------- the checks

    public record Check(string Id, string Title, string Value, string Detail, string State);

    readonly List<Check> _cached = [];
    DateTime _cachedAt = DateTime.MinValue;

    /// The session health checklist, on both the overview and the diagnostics screens. It only asks the
    /// device once every couple of seconds, whatever is refreshing.
    public List<Check> RunChecks(bool force = false)
    {
        if (!force && (DateTime.UtcNow - _cachedAt).TotalSeconds < 2 && _cached.Count > 0) return _cached;
        _cachedAt = DateTime.UtcNow;
        var s = Session;
        var list = new List<Check>();
        bool linked = s.Phase is AlphaLinkPhase.Linked or AlphaLinkPhase.Logging;
        list.Add(new("link", "Device link", linked ? $"{s.Identity?.Kind} / {s.Identity?.DeviceId}" : s.Phase.ToString(),
            linked ? "the emulator transport is answering" : "connect the emulator before tuning live", linked ? "pass" : "fail"));
        var reg = s.Identity?.Registration;
        list.Add(new("identity", "Authorized identity", reg == null ? (linked ? "waiting for the device" : "not linked") : reg.ToString(),
            reg?.Registered == true ? "the connected serial is authorized for this release"
                                    : "the device says it is not registered - the plugin still shows you everything",
            reg == null ? "idle" : reg.Registered ? "pass" : "warn"));
        list.Add(new("calibration", "Calibration image", HasRom ? $"{RomName()} / {RomSize():N0} bytes" : "none loaded",
            HasRom ? "a working image is available to review, snapshot and recover" : "open one, or read a slot from the emulator", HasRom ? "pass" : "fail"));
        list.Add(new("sync", "Device synchronization", s.Synced ? "editor matches the running image" : linked ? "linked, no baseline yet" : "unavailable",
            s.Synced ? "real-time patches are the difference from the emulator's own bytes" : "deploy a slot, or let real-time update take a baseline",
            s.Synced ? "pass" : linked ? "warn" : "fail"));
        bool fresh = s.LastFrameAt is DateTime at && (DateTime.Now - at).TotalSeconds < 2;
        list.Add(new("datalog", "Datalog feed", s.FeedingDatalog ? $"{s.Frames:N0} frames at {s.FramesPerSecond:0.#} fps"
                                              : s.Streaming ? $"{s.Frames:N0} frames streamed, not fed to the app" : "not streaming",
            s.FeedingDatalog ? (fresh ? "frames are arriving and the app is logging them" : "no frame in the last two seconds - check the stream")
                             : s.Streaming ? "the console traces the stream while the app's own datalog connection stays untouched"
                                           : "connect the emulator to start the stream",
            s.FeedingDatalog ? (fresh ? "pass" : "warn") : s.Streaming ? "idle" : "fail"));
        list.Add(new("realtime", "Real-time update", s.RealtimeEnabled ? (s.Synced ? "armed" : "waiting for a baseline") : "off",
            s.RealtimeEnabled ? "table edits go to the running image as you make them" : "turn it on to tune live without deploying each change",
            s.RealtimeEnabled ? (s.Synced ? "pass" : "warn") : "idle"));
        var wb = State.Analog[Math.Clamp(State.WidebandInput, 0, State.Analog.Count - 1)];
        list.Add(new("wideband", "Wideband input", wb.Enabled && wb.Role == AlphaAnalogRole.WidebandAfr ? (wb.Fresh ? Session.AnalogAfr() is double a ? $"{a:0.00} AFR" : "no reading" : "stale") : "not assigned",
            s.Wideband.Summary, wb.Enabled && wb.Role == AlphaAnalogRole.WidebandAfr && wb.Fresh ? "pass" : "warn"));
        var rec = Snapshots.Recovery();
        list.Add(new("recover", "Working recovery", rec is (DateTime rat, int rbytes, string rrom) ? $"{AlphaState.Bytes(rbytes)} at {rat:HH:mm:ss}" : "none yet",
            rec == null ? "written the first time the calibration goes dirty" : "a crash costs at most a few seconds of edits", rec == null ? "warn" : "pass"));
        _cached.Clear();
        _cached.AddRange(list);
        return _cached;
    }

    // ---------------------------------------------------------------- the commands

    List<AlphaCommand>? _commands;

    public IReadOnlyList<AlphaCommand> Commands => _commands ??= Build();

    List<AlphaCommand> Build() =>
    [
        new("Connect the emulator", "Open the link, read the identity, start the datalog.", ["link", "connect", "start", "serial", "bluetooth"], Connect, "Link"),
        new("Disconnect", "Close the link and stop feeding the datalog.", ["disconnect", "stop", "close"], Disconnect, "Link"),
        new("Re-read identity", "Close and open the link so the device tells you who it is again.", ["identity", "refresh", "device"], Reconnect, "Link"),
        new("Real-Time Update (toggle)", "Send every table edit to the running image as you make it.", ["realtime", "real-time", "patch", "live"], ToggleRealtime, "Link"),
        new("Deploy every staged slot", "Write, verify and commit each staged calibration.", ["deploy", "multimap", "slots", "write"], () => Ui(() => Maps().DeployRequested()), "Multi-map"),
        new("Open the Multi Map Manager", "Stage, write, verify, commit and read the map slots.", ["multimap", "slots", "stage", "bin"], () => Ui(() => OpenScreen("Multi-map")), "Multi-map"),
        new("Read the live slot into the editor", "Read whichever slot the emulator is running and load it as the working calibration.", ["read", "download", "slot"], ReadLiveSlot, "Multi-map"),
        new("Analog inputs", "The eight ALPHAemu inputs, their roles and what they are reading.", ["analog", "inputs", "wideband", "pins"], () => Ui(() => OpenScreen("Analog inputs")), "Sensors"),
        new("Wideband sensor profile", "Pick a factory curve or draw a custom one; set stoich and offset.", ["wideband", "afr", "lambda", "sensor", "stoich"], () => Ui(OpenWideband), "Sensors"),
        new("Create a snapshot", "Save the calibration now, with how many bytes differ from the last one.", ["snapshot", "save", "backup", "history"], () => Ui(() => SnapshotNow("")), "Snapshots"),
        new("Restore the newest snapshot", "Put the last saved calibration back into the editor.", ["restore", "snapshot", "undo", "back"], () => Ui(() => RestoreSnapshot(Snapshots.All.FirstOrDefault())), "Snapshots"),
        new("Restore the working recovery", "Take back the automatic recovery copy.", ["recovery", "crash", "restore", "autosave"], () => Ui(RestoreRecovery), "Snapshots"),
        new("Trouble codes", "What the emulator and the simulated ECU are holding, and clearing them.", ["dtc", "codes", "mil", "diagnostic", "fault"], () => Ui(() => OpenScreen("Diagnostics")), "Diagnostics"),
        new("Clear trouble codes", "Ask the emulator to forget its stored codes.", ["clear", "dtc", "codes"], ClearCodes, "Diagnostics"),
        new("Device and firmware", "Transport, port, identity, real-time settings and the firmware.", ["device", "firmware", "port", "transport", "settings"], () => Ui(() => OpenScreen("Device")), "Device"),
        new("Session log", "Everything the link sent and answered.", ["log", "traffic", "debug"], () => Ui(() => OpenScreen("Log")), "Device"),
        new("Command palette", "This list, in a window of its own.", ["palette", "commands", "search", "find"], () => Ui(() => new AlphaPalette(this).Show()), "ALPHAemu"),
        new("ALPHAemu console", "The whole console in a window of its own.", ["console", "window", "gauges", "dash"], () => Ui(OpenConsole), "ALPHAemu"),
    ];

    void ReadLiveSlot()
    {
        if (Session.Phase is not (AlphaLinkPhase.Linked or AlphaLinkPhase.Logging)) { Notify("the emulator is not linked"); return; }
        Session.Run("read the live slot", s =>
        {
            var bytes = s.ReadActiveImage() ?? throw new IOException("nothing is running in the emulator");
            Ui(() => Ask("Slot read", $"Load the {AlphaState.Bytes(bytes.Length)} image the emulator is running as the working calibration?", () => LoadIntoRom(bytes, "the emulator's running image")));
            return AlphaState.Bytes(bytes.Length) + " read";
        });
    }

    /// A ROM was opened or built: take a snapshot of it and let the real-time baseline go stale.
    public void RomLoaded(string path)
    {
        Notify("calibration opened: " + System.IO.Path.GetFileName(path));
        if (State.AutoSnapshotOnDeploy) SnapshotNow("opened " + System.IO.Path.GetFileName(path));
        State.Save(Folder);
    }
}

/// A small ICommand for the console's key binding.
sealed class RelayCommand(Action run) : ICommand
{
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? o) => true;
    public void Execute(object? o) => run();
}




