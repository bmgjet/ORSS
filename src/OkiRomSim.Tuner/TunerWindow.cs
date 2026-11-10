// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// RomSimTuner's window: what Rom Sim Studio shows in Tuner mode, on its own - the calibration editor filling the window with the
/// datalog beside it, a File menu for ROMs (.bin images, or a .asm build), Settings - and nothing of the simulator. Its host is a
/// RomHost: the ROM, its definitions, every edit (checksum kept, undo and redo) and the emulator interlock, the very code Rom Sim
/// Studio's SimHost is built on.
public sealed class TunerWindow : Window, IRestartAfterUpdate
{
    readonly RomHost _host = new();
    readonly CalibrationView _calibration;
    readonly DatalogView _datalog;
    AppSettings _settings = AppSettings.Load();
    ProcessorProfile _profile = ProcessorProfile.Current;
    readonly LayoutTransformControl _scaler = new();
    readonly StackPanel _tunerSlot = new() { Orientation = Orientation.Horizontal };
    readonly Dictionary<string, ZoomHost> _zoom = [];
    /// Source text the ROM open now was built from that is not on disk: the disassembly made when a .bin was opened (path -> text). Detect reads it.
    readonly Dictionary<string, string> _generated = new(StringComparer.OrdinalIgnoreCase);
    /// The .bin (or .rom) open now, when the ROM came from an image rather than a source.
    string? _openedImage;
    /// The .bin Download read out of the emulator: opening it keeps the emulator and the datalog connected.
    string? _keepLinksFor;
    readonly ExternalData _external = new();
    Dictionary<string, KeyGesture> _hotKeys = [];
    bool _closeConfirmed, _closeAsking, _shutDown;
    int _demonLinked;
    DateTime _lastSlow;
    string _lastLogged = "";
    /// An open under way (its disassembly, the reference ROMs and Detect included), and its file: one at a time (StillOpening).
    bool _opening;
    string _openingName = "";
    Window? _logWindow;

    public const string AppName = "Rom Sim Studio Tuner";

    public TunerWindow(string? openPath)
    {
        Title = $"{AppName} {BuildInfo.Version}";
        AppLog.Info("app", $"{AppName} {BuildInfo.Version} (the tuning-only build) starting on {Environment.OSVersion} ({Environment.ProcessorCount} cores, .NET {Environment.Version})");
        MinWidth = 800; MinHeight = 560;
        try
        {
            var scr = (_settings.WindowX is double sx && _settings.WindowY is double sy ? Screens.ScreenFromPoint(new PixelPoint((int)sx, (int)sy)) : null) ?? Screens.Primary;
            if (ScreenFit.Fit(_settings, scr)) _settings.Save();
            if (scr != null) { MinWidth = Math.Min(MinWidth, ScreenFit.Dip(scr).Width * 0.9); MinHeight = Math.Min(MinHeight, ScreenFit.Dip(scr).Height * 0.9); }
        }
        catch (Exception ex) { AppLog.Error("app", "could not fit the window to the screen", ex); }
        Width = Math.Max(MinWidth, _settings.WindowWidth); Height = Math.Max(MinHeight, _settings.WindowHeight);
        if (_settings.WindowX is double wx && _settings.WindowY is double wy)
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Position = new PixelPoint((int)wx, (int)wy);
        }
        WindowState = _settings.Maximized ? WindowState.Maximized : WindowState.Normal;

        // the processor profile first: it sets the clock and the names everything else uses
        try { _profile = ProcessorProfile.Builtin(_settings.Processor) ?? ProcessorProfile.Msm66207(); _profile.Apply(); }
        catch (Exception ex) { AppLog.Error("processor", "profile failed; using the MSM66207", ex); ProcessorProfile.Msm66207().Apply(); }

        _calibration = new CalibrationView(_host, Sources, () => GetTopLevel(this));
        string FavKey() => Path.GetFileNameWithoutExtension(_host.LoadedPath ?? "").ToLowerInvariant();
        _calibration.OpenSettingsPage += page => OpenSettings(page);
        _calibration.GetFavourites = () => _settings.Favourites.TryGetValue(FavKey(), out var l) ? l : [];
        _calibration.SaveFavourites = list => { _settings.Favourites[FavKey()] = list; _settings.Save(); };
        _calibration.StretchChanged += on => { _settings.TableStretch = on; _settings.Save(); };
        _calibration.CompareRequested += OpenCompare;
        _calibration.OpenDownloaded += OpenDownloaded;
        _calibration.EmulatorClosed += DemonClosed;
        // a password or watermark changed on a ROM built from a New ROM build file: kept in that file too, as Rom Sim Studio keeps it
        _host.ItemWritten += item => Dispatcher.UIThread.Post(() => KeepInBuildFile(item));

        _datalog = new DatalogView(_host, () => GetTopLevel(this), () => _settings);
        _datalog.ShowOnMaps += f => _calibration.ShowPoint(f);
        _datalog.OpenSettingsPage += page => OpenSettings(page);
        _datalog.SettingsChanged += () => _settings.Save();
        _datalog.CurrentFrameChanged += f => _calibration.SetEngineState(f);
        // an .rlog carries the ROM the car was running: offered, never put in place of what is open without asking
        _datalog.RomFromLog += async (rom, name) =>
        {
            if (StillOpening($"the ROM {name} carries can be opened")) return;
            var open = _openedImage ?? _host.LoadedPath;
            bool load = await Dialogs.Confirm(this, "Load the tune from the log?",
                $"{name} carries the ROM the car was running ({rom.Length:N0} bytes).\n\n" +
                (open == null ? "Open it now?" : $"Open it in place of {Path.GetFileName(open)}? The log itself is loaded either way."),
                "Open it", "Keep what I have");
            if (!load) { SetStatus("the log's frames are loaded; the ROM it carries was left alone"); return; }
            if (await ConfirmReplaceCurrent()) OpenRomImage(rom, name);
        };
        _calibration.OverlayFrames = () => _datalog.Frames();
        _calibration.DatalogMenu = (live, setLive) => _datalog.MenuEntries(live, setLive);
        _calibration.DatalogState = _datalog.LinkStatus;
        _calibration.DatalogPortInUse = () => _datalog.Engine.Running && _datalog.Engine.Source is { } src && !src.StartsWith("emulator") ? src : null;
        // the Transmission page: the gearbox presets and Gear learning, above its rows
        FeaturePageView.TopExtensions.Add(("transmission", _ => GearboxPanel.Build(_host, _datalog.Engine, m => SetStatus(m), () => this)));

        // the program files an update moved aside are gone once the new ones run; then, if wanted, a quiet look for anything newer
        Updater.ClearOld();
        if (_settings.CheckUpdatesAtStart) Opened += (_, _) => CheckUpdatesQuietly();

        Closing += (_, e) =>
        {
            // calibration changes not in a file: ask first, the window staying open until the answer
            if (!_closeConfirmed && _host.RomDirty)
            {
                e.Cancel = true;
                if (!_closeAsking) AskBeforeClose();
                return;
            }
            if (_shutDown) return;
            _shutDown = true;
            SaveLayout();
            _datalog.Gauges.SaveLast();
            _external.Dispose();
            _datalog.Gauges.CloseWidgets();
            _datalog.Shutdown();
            _host.EmulatorDisconnect();
        };
        // every button pressed goes to the action log (Debug page)
        Button.ClickEvent.AddClassHandler<Button>((b, _) =>
        {
            string text = b.Content switch { string t => t, TextBlock tb => tb.Text ?? "", _ => b.Content?.ToString() ?? "" };
            if (text.Length > 0) AppLog.Action("ui", $"pressed '{text}'");
        });

        var chrome = DarkChrome.Apply(this, Title!);
        var shell = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(chrome, 0); shell.Children.Add(chrome);
        _scaler.Child = BuildLayout();
        Grid.SetRow(_scaler, 1); shell.Children.Add(_scaler);
        Content = shell;
        KeyDown += OnKeyDown;

        // the shipped ROM sources: the formulas of tables Detect places from them
        DefinitionBuilder.FormulaSources.Add(Path.Combine(AppContext.BaseDirectory, "Templates"));
        ApplySettings(first: true);
        _calibration.SetTunerMode(true);
        _calibration.MoveBarItems(_tunerSlot);
        _datalog.SetCompact(true);
        _calibration.Refresh();

        try
        {
            if (openPath == null && _settings.ReopenLastFile && _settings.LastFile is { } last && File.Exists(last) && Opens(last)) openPath = last;
            if (openPath != null && File.Exists(openPath)) OpenFile(Path.GetFullPath(openPath));
            else SetStatus("open a .bin (File > Open), Detect its maps, then connect the datalog (Settings > Emulator & datalog) and the emulator");
        }
        catch (Exception ex) { SetStatus("could not open " + openPath + ": " + ex.Message); }

        // a bug in a handler should cost one action, not the session: logged, and the program carries on
        Dispatcher.UIThread.UnhandledException += (_, e) =>
        {
            e.Handled = true;
            AppLog.Error("ui", "unhandled error in a handler", e.Exception);
            try { File.AppendAllText(Path.Combine(Path.GetTempPath(), "RomSimTuner-errors.log"), $"{DateTime.Now:s} {e.Exception}\n\n"); } catch { }
            SetStatus("internal error (see the log): " + e.Exception.Message);
        };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        timer.Tick += (_, _) =>
        {
            if (WindowState == WindowState.Minimized) return;
            UpdateTitle();
            SafeRefresh();
            DemonDatalog();
            var want = TimeSpan.FromMilliseconds(_datalog.Engine.Running ? Perf.BusyMs : Perf.IdleMs);
            if (timer.Interval != want) timer.Interval = want;
        };
        timer.Start();
    }

    /// The source files the ROM open now was built from, for Detect: the disassembly made of an opened .bin (not on disk), and a .asm
    /// build's files as they are on disk.
    IEnumerable<(string Path, string Text)> Sources()
    {
        foreach (var kv in _generated) yield return (kv.Key, kv.Value);
        if (_host.Assembly is not { } asm) yield break;
        foreach (var f in asm.SourceMap.Select(e => e.File).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (_generated.ContainsKey(f) || !File.Exists(f)) continue;
            string? text = null;
            try { text = File.ReadAllText(f); } catch { }
            if (text != null) yield return (f, text);
        }
    }

    // ------------------------------------------------------------------ layout

    Control BuildLayout()
    {
        var bar = new WrapPanel { Margin = new Thickness(6, 4) };
        bar.Children.Add(FileMenu());
        bar.Children.Add(new Separator { Width = 8 });
        // the calibration editor's Tools, Emulator, Datalogging, Back, Undo and Redo come onto this line; the status goes beside its Definition bar
        bar.Children.Add(_tunerSlot);
        var zCal = Zoomable("Calibration", _calibration);
        var zDatalog = Zoomable("Tuner datalog", _datalog);
        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("*,4,520") };
        Grid.SetColumn(zCal, 0); body.Children.Add(zCal);
        var gs = new GridSplitter { Width = 4 }; Grid.SetColumn(gs, 1); body.Children.Add(gs);
        Grid.SetColumn(zDatalog, 2); body.Children.Add(zDatalog);
        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(bar, 0); root.Children.Add(bar);
        Grid.SetRow(body, 1); root.Children.Add(body);
        return root;
    }

    ZoomHost Zoomable(string key, Control child)
    {
        var z = new ZoomHost(key, child) { Zoom = _settings.Zoom(key) };
        z.ZoomChanged += (k, zoom) =>
        {
            _settings.PanelZoom[k] = zoom;
            SetStatus($"{k} zoom {zoom * 100:0}% (Ctrl + wheel; reset in Settings > Panel zoom)");
        };
        _zoom[key] = z;
        return z;
    }

    /// The File drop-down.
    Button FileMenu() => Toolbar.Menu("File", Toolbar.Open, () => [
        new Toolbar.Entry(Toolbar.Open, "Open…  (Ctrl+O)", "Open a ROM image (.bin / .rom) - its tables found by Detect, or put back from the definitions file beside it - or a .asm build.", OpenFileDialog),
        Toolbar.Entry.Submenu(Toolbar.Restore, "Recent", "The last ROMs opened.", RecentEntries),
        new Toolbar.Entry(Toolbar.Save, "Save ROM…  (Ctrl+S)", "Write the tuned ROM image to a .bin (an existing file is kept as .bak), and offer the definitions file that keeps its names.", () => _ = SaveRom()),
        Toolbar.Entry.Line,
        new Toolbar.Entry(Toolbar.Settings, "Set-up wizard…",
            "Set the ROM up stage by stage: the stock maps to start from, VTEC and the rev limit, the injectors, the MAP sensor and the gearbox, " +
            "boost, and the options - with the presets for each. Nothing is written until the last page.", () => _ = SetupWizard()),
        new Toolbar.Entry(Toolbar.SaveAs, "Bin tool…",
            "32 KB ROMs and 64 KB (512) chips: pad a ROM into the upper half of a 64 KB image, combine two ROMs on one chip, or split a 64 KB image into its two 32 KB halves.",
            OpenBinTool),
        new Toolbar.Entry(Toolbar.Compare, "Compare…",
            "Compare the ROM open here with another .bin or .asm: what changed in the code and in the tables.", OpenCompare),
        new Toolbar.Entry(Toolbar.Clear, "Close ROM",
            "Close the ROM and let go of it: the definitions, the undo history and the emulator's hits.", () => _ = CloseRom()),
        new Toolbar.Entry(Toolbar.Detect, "Log…",
            "Everything this session has done and said: the actions, the warnings and errors (with their details), and the datalog's and the emulator's traffic - " +
            "where a message that says 'see the log' points.", OpenLog),
        Toolbar.Entry.Line,
        new Toolbar.Entry(Toolbar.Settings, "Settings…",
            "UI scale, panel zoom, colours, hot keys, units, datalogging, the wideband, the emulator and the processor profile.", OpenSettings),
    ]);

    // ------------------------------------------------------------------ settings

    void OpenSettings() => OpenSettings(null);

    void OpenSettings(string? page)
    {
        if (StillOpening("the settings open")) return;
        SaveLayout();
        var original = _settings;
        var originalProfile = _profile;
        bool previewed = false;
        var w = new SettingsWindow(_settings, () => "not in this build", _profile, FuelMapAxes);
        w.Applied += (s, profile) => { previewed = true; UseSettings(s, profile, save: false); SetStatus("settings applied (Save keeps them)"); };
        w.Closed += (_, _) =>
        {
            if (w.Result == null)
            {
                if (previewed) { UseSettings(original, originalProfile != _profile ? originalProfile : null, save: false); SetStatus("settings put back"); }
                return;
            }
            bool newLanguage = !string.Equals(w.Result.Language, original.Language, StringComparison.OrdinalIgnoreCase);
            UseSettings(w.Result, w.ResultProfile, save: true);
            if (newLanguage)
            {
                Lang.Use(_settings.Language);
                _ = Dialogs.Ask(this, "Language", "The new language is used in every window opened from now on; this window changes over fully when the program starts again.", "OK");
            }
            SetStatus("settings saved");
            AppLog.Action("settings", "saved");
        };
        if (page != null) w.ShowPage(page);
        w.ShowDialog(this);
    }

    /// Put settings from the Settings window into effect, keeping the window values it does not edit; `save` writes them to disk.
    void UseSettings(AppSettings r, ProcessorProfile? profile, bool save)
    {
        if (!ReferenceEquals(r, _settings))
        {
            r.WindowX = _settings.WindowX; r.WindowY = _settings.WindowY;
            r.WindowWidth = _settings.WindowWidth; r.WindowHeight = _settings.WindowHeight; r.Maximized = _settings.Maximized;
            r.LeftColumn = _settings.LeftColumn; r.CentreColumn = _settings.CentreColumn; r.RightColumn = _settings.RightColumn;
            r.BottomPanel = _settings.BottomPanel; r.SelectedTab = _settings.SelectedTab;
            r.PanelSizes = _settings.PanelSizes; r.Favourites = _settings.Favourites;
            r.Package = _settings.Package; r.LastFile = _settings.LastFile;
        }
        // "Fit to the screen" ticked again: the scale for this screen is picked now
        if (r.FitToScreen && r.FittedFor.Length == 0) ScreenFit.Fit(r, Screens.ScreenFromWindow(this) ?? Screens.Primary);
        _settings = r;
        if (save) _settings.Save();
        if (profile != null) ApplyProfile(profile);
        ApplySettings(first: false);
    }

    /// The RPM and load breakpoints of the ROM's own fuel map, for the AFR target table on the Settings page. Empty when nothing suitable is open.
    (double[] Rpm, double[] Load) FuelMapAxes()
    {
        try
        {
            var defs = _host.Defs();
            var item = defs.Items.FirstOrDefault(i => i.IsTable && i.Rows > 1 && i.Cols > 1 && i.ColumnScaleAddress != null && MapSide.Side(i) != true)
                       ?? defs.Items.FirstOrDefault(i => i.IsTable && i.Rows > 1 && i.Cols > 1 && i.ColumnScaleAddress != null)
                       ?? defs.Items.FirstOrDefault(i => i.IsTable && i.Rows > 1 && i.Cols > 1 && i.RowAxis?.Address != null && i.ColAxis?.Address != null);
            if (item == null) return ([], []);
            var rpm = _host.AxisValues(item.RowAxis, item.Rows).Where(v => !double.IsNaN(v)).ToArray();
            var load = _host.AxisValues(item.ColAxis, item.Cols).Where(v => !double.IsNaN(v)).ToArray();
            if (load.Length > 0 && load.Max() > 400) load = [.. load.Select(v => Math.Round(v / 10, 1))];
            return (rpm, load);
        }
        catch (Exception ex) { AppLog.Error("settings", "could not read the fuel map axes", ex); return ([], []); }
    }

    /// Put the settings into effect: scale, fonts, colours, units, the datalog, the wideband and the emulator link.
    void ApplySettings(bool first)
    {
        var s = _settings;
        Perf.Set(s.LowPerformance ?? Perf.Suggested);
        double scale = Math.Clamp(s.UiScale, 0.5, 3);
        ScreenFit.UiScale = scale;
        _scaler.LayoutTransform = Math.Abs(scale - 1) < 0.001 ? null : new ScaleTransform(scale, scale);
        foreach (var (key, z) in _zoom) z.Zoom = s.Zoom(key);
        _datalog.ApplyGaugeZoom();
        TableModel.SetColours(SettingsWindow.Parse(s.TableLow), SettingsWindow.Parse(s.TableMid), SettingsWindow.Parse(s.TableHigh),
            SettingsWindow.Parse(s.TableMax), SettingsWindow.Parse(s.TraceColour), SettingsWindow.Parse(s.TrailColour));
        var units = s.Units.Clone();
        units.Stoich = s.StoichAfr;
        bool unitsChanged = System.Text.Json.JsonSerializer.Serialize(units) != System.Text.Json.JsonSerializer.Serialize(Units.Now);
        Units.Now = units;
        if (unitsChanged && !first) _calibration.UnitsChanged();
        _calibration.SetOptions(s.LiveTrace, s.FollowReads, s.TrailSeconds);
        _calibration.TableStretch = s.TableStretch;
        TouchMode.Set(s.TouchMode);
        AppTheme.Set(AppTheme.Parse(s.Theme));
        _calibration.TargetLow = TargetMap.Parse(s.AfrTargetLow);
        _calibration.TargetHigh = TargetMap.Parse(s.AfrTargetHigh);
        _calibration.WidebandCorrection = LookupCurve.Parse(s.WidebandCorrection);
        // a Demon datalogs over the emulator's own port; a "simulator" port (Rom Sim Studio's own) is no port here
        var port = s.EmulatorType == "Demon" ? "emulator" : s.DatalogPort == "simulator" ? "" : s.DatalogPort;
        _datalog.SetLink(port, s.DatalogProtocol, s.DatalogBaud);
        var picks = s.DatalogStreamChannels is { Count: > 0 } sc ? sc : [.. DatalogChannels.Defaults];
        bool picksChanged = !picks.SequenceEqual(ChannelStream.Selected);
        ChannelStream.Selected = picks;
        if (picksChanged && !first) _datalog.Engine.Reconfigure();
        _datalog.Engine.SerialInputs = [.. s.DatalogSerialInputs.Select(SerialInputMap.Parse).OfType<SerialInputMap>()];
        _datalog.GetStreamChannels = () => _settings.DatalogStreamChannels;
        _datalog.SetStreamChannels = list => { _settings.DatalogStreamChannels = list; _settings.Save(); };
        _datalog.GetSerialInputs = () => _settings.DatalogSerialInputs;
        _datalog.SetSerialInputs = list => { _settings.DatalogSerialInputs = list; _settings.Save(); };
        if (s.DetectedLayout is { Length: > 0 } dl)
            try { _datalog.Engine.Detected = System.Text.Json.JsonSerializer.Deserialize<DetectedProtocol>(dl); }
            catch (Exception ex) { AppLog.Error("datalog", "saved layout could not be read", ex); }
        _datalog.DriveSimulator = false;
        _external.Start(s.ExternalFeeds);
        _datalog.Gauges.External = _external;
        var eng = _datalog.Engine;
        eng.IntervalMs = s.DatalogIntervalMs; eng.KeepFrames = s.DatalogKeepFrames;
        var curves = ParseNamedCurves(s.AnalogCurves);
        eng.AuxChannels = [.. s.AuxChannels.Select(a =>
        {
            var ch = a.ToChannel();
            if (curves.TryGetValue(ch.Name, out var curve)) ch.Curve = curve;
            return ch;
        })];
        eng.Wideband.Stoich = s.StoichAfr;
        _datalog.RaiseSettingsApplied();
        if (s.WidebandType != "none" && s.WidebandPort.Length > 0 && (eng.Wideband.Type != s.WidebandType || !eng.Wideband.Running))
        {
            var (type, wport, baud) = (s.WidebandType, s.WidebandPort, s.WidebandBaud);
            Task.Run(() =>
            {
                try { eng.Wideband.Start(type, wport, baud); }
                catch (Exception ex)
                {
                    AppLog.Error("wideband", "could not open " + wport, ex);
                    Dispatcher.UIThread.Post(() => SetStatus("wideband: " + ex.Message));
                }
            });
        }
        else if (s.WidebandType == "none") Task.Run(() => { try { eng.Wideband.Stop(); } catch { } });
        var sm = eng.Smooth;
        sm.Frames = s.DatalogSmoothFrames; sm.SpikePercent = s.DatalogSmoothSpikePercent; sm.Blend = s.DatalogSmoothBlend;
        sm.Skip.Clear();
        foreach (var c in s.DatalogSmoothSkip.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)) sm.Skip.Add(c);
        if (sm.Enabled != s.DatalogSmooth) _datalog.SetSmoothing(s.DatalogSmooth);
        // the emulator link: which device, how fast, and how patient to be with the cable
        var emu = _host.Emulator;
        emu.Kind = s.EmulatorType; emu.Baud = s.EmulatorBaud;
        emu.PostWritePauseMs = Math.Clamp(s.PostWritePauseMs, 0, 500);
        emu.TimeoutMs = Math.Clamp(s.SerialTimeoutMs * 3, 100, 5000);
        emu.Retries = Math.Clamp(s.SerialRetries, 0, 20);
        if (int.TryParse(s.MoatesBase, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var emuBase)) emu.Base = emuBase;
        // the same numbers drive the car's datalog link
        DatalogProtocol.TimeoutMsDefault = Math.Clamp(s.SerialTimeoutMs, 20, 5000);
        DatalogProtocol.PostWritePauseMsDefault = Math.Clamp(s.PostWritePauseMs, 0, 500);
        DatalogProtocol.RetriesDefault = Math.Clamp(s.SerialRetries, 0, 20);
        SerialLink.RaiseDtrRts = s.SerialDtrRts;
        SerialLink.WriteTimeoutMs = Math.Clamp(s.SerialWriteTimeoutMs, 50, 10000);
        _calibration.EmulatorPort = s.MoatesPort;
        _datalog.EmulatorPort = s.MoatesPort;
        if (first) _host.AutoUpload = s.EmulatorAutoUpload;
        _calibration.UpdateEmulator();
        TableKeys.Use(s.TableHotKeys);
        LinkSupervisor.Attempts = Math.Clamp(s.ReconnectAttempts, 1, 100);
        LinkSupervisor.DelayMs = Math.Clamp(s.ReconnectDelayMs, 200, 30000);
        _hotKeys = s.HotKeys.Where(kv => kv.Value.Length > 0)
            .Select(kv => { try { return (kv.Key, Gesture: KeyGesture.Parse(kv.Value)); } catch { return (kv.Key, Gesture: (KeyGesture?)null); } })
            .Where(x => x.Gesture != null).ToDictionary(x => x.Key, x => x.Gesture!);
    }

    /// "name: 0=0, 2.5=50, 5=100" per line, from Settings > Targets.
    static Dictionary<string, LookupCurve> ParseNamedCurves(string text)
    {
        var map = new Dictionary<string, LookupCurve>(StringComparer.OrdinalIgnoreCase);
        foreach (var raw in (text ?? "").Split('\n'))
        {
            var line = raw.Trim();
            int colon = line.IndexOf(':');
            if (colon <= 0) continue;
            var curve = LookupCurve.Parse(line[(colon + 1)..]);
            if (curve.Any) map[line[..colon].Trim()] = curve;
        }
        return map;
    }

    /// Remember the window for next time (in the tuner's own settings file: Rom Sim Studio's window is not moved by it).
    void SaveLayout()
    {
        var s = _settings;
        s.Maximized = WindowState == WindowState.Maximized;
        if (WindowState == WindowState.Normal)
        {
            s.WindowWidth = Width; s.WindowHeight = Height;
            s.WindowX = Position.X; s.WindowY = Position.Y;
        }
        var last = _openedImage ?? _host.LoadedPath;
        if (last != null && File.Exists(last)) s.LastFile = last;
        s.Save();
    }

    void ApplyProfile(ProcessorProfile p)
    {
        _profile = p;
        _host.ApplyProfile(p);
        if (ProcessorProfile.Builtin(p.Name) != null) _settings.Processor = p.Name;
        SetStatus($"processor {p.Name} on {p.Board}: {p.CrystalMHz:0.##} MHz / {p.ClockDivider}");
    }

    static bool IsP13Part(ProcessorProfile p) => p.Name.Equals(ProcessorProfile.Msm66911().Name, StringComparison.OrdinalIgnoreCase);

    // ------------------------------------------------------------------ files

    /// What this program opens: ROM images and .asm builds (a Rom Sim Studio project carries the simulator's state, so it opens there).
    static bool Opens(string path) => Path.GetExtension(path).ToLowerInvariant() is ".bin" or ".rom" or ".asm";

    async void OpenFileDialog()
    {
        if (StillOpening("another ROM can be opened")) return;
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            AllowMultiple = false,
            Title = "Open a ROM image or build",
            FileTypeFilter = new[]
            {
                new FilePickerFileType("ROM image or build") { Patterns = new[] { "*.bin", "*.rom", "*.asm" } },
                new FilePickerFileType("ROM image") { Patterns = new[] { "*.bin", "*.rom" } },
                new FilePickerFileType("Assembler source (a skeleton ROM's build file)") { Patterns = new[] { "*.asm" } },
                new FilePickerFileType("All files") { Patterns = new[] { "*" } },
            },
        });
        var f = files.FirstOrDefault()?.TryGetLocalPath();
        if (f != null && await ConfirmReplaceCurrent()) OpenFile(f);
    }

    /// Restarting after an update: calibration changes not in a file are saved or let go first (false: stay). Answered here, so
    /// the close that follows does not ask again.
    public async Task<bool> ReadyToRestart()
    {
        if (!await ConfirmReplaceCurrent()) return false;
        _closeConfirmed = true;
        return true;
    }

    /// At start-up: ask the website whether anything is newer for RomSimTuner, and only say so (Settings > Updates fetches it).
    async void CheckUpdatesQuietly()
    {
        try
        {
            await Task.Delay(4000);
            var changes = await Updater.Check(_settings.UpdateSite);
            var offered = changes.Where(c => c.Recommended).ToList();
            if (offered.Count == 0) return;
            bool program = offered.Any(c => c.NeedsRestart);
            int templates = offered.Count(c => !c.NeedsRestart);
            string what = (program ? "a new version of RomSimTuner" + (templates > 0 ? " and " : "") : "") + (templates > 0 ? $"{templates} template file(s)" : "");
            SetStatus($"updates are available: {what} - Settings > Updates > Check now");
            // a message box, once per start: nothing is downloaded until it is asked for in the Updates window
            var pick = await Dialogs.Ask(this, "Update available",
                $"There is an update on the website: {what}.\n\nOpen the update window to see what changed and download it? Nothing is downloaded until you ask.",
                "Later", "Open updates");
            if (pick == "Open updates") await Dialogs.ShowModal(new UpdatesWindow(_settings.UpdateSite), this);
        }
        catch (Exception ex) { AppLog.Info("updates", "start-up check did not reach the website: " + ex.Message); }
    }

    /// Before replacing what is open: calibration changes not in a file are saved, let go, or kept by staying. False: stay.
    async Task<bool> ConfirmReplaceCurrent()
    {
        if (!_host.RomDirty) return true;
        var answer = await Dialogs.Ask(this, "Save your changes?",
            "The ROM open now has calibration changes that are not in a file yet.\n\nSave them first, discard them, or stay with the ROM you have open?",
            "Save", "Discard", "Cancel");
        if (answer == "Discard") return true;
        if (answer != "Save") return false;
        return await SaveRom();
    }

    /// File > Recent: the last ten files opened that this program opens (newest first; those no longer there are left out).
    Toolbar.Entry[] RecentEntries()
    {
        var list = _settings.RecentFiles.Where(p => File.Exists(p) && Opens(p)).Take(10).ToList();
        if (list.Count == 0) return [new Toolbar.Entry("", "(nothing yet)", "ROMs you open appear here.", () => { })];
        return [.. list.Select((p, i) => new Toolbar.Entry(i < 9 ? $"{i + 1}" : "0", Path.GetFileName(p), p, async () =>
        {
            if (StillOpening("another ROM can be opened")) return;
            if (await ConfirmReplaceCurrent()) OpenFile(p);
        }))];
    }

    void RememberRecent(string path)
    {
        try
        {
            var full = Path.GetFullPath(path);
            _settings.RecentFiles.RemoveAll(p => string.Equals(p, full, StringComparison.OrdinalIgnoreCase));
            _settings.RecentFiles.Insert(0, full);
            if (_settings.RecentFiles.Count > 10) _settings.RecentFiles.RemoveRange(10, _settings.RecentFiles.Count - 10);
            _settings.Save();
        }
        catch { }
    }

    /// Open a file (a ROM with an open password set - the watermark module - asks for it first).
    void OpenFile(string path) => _ = OpenFileChecked(path);

    async Task OpenFileChecked(string path)
    {
        if (StillOpening($"{Path.GetFileName(path)} can be opened")) return;
        _opening = true;
        _openingName = Path.GetFileName(path);
        try
        {
            if (!Opens(path)) { SetStatus($"{Path.GetFileName(path)}: this program opens ROM images (.bin, .rom) and .asm builds - a project opens in Rom Sim Studio"); return; }
            RememberRecent(path);
            if (path.EndsWith(".asm", StringComparison.OrdinalIgnoreCase)) await OpenBuild(path);
            else await OpenBinary(path);
        }
        catch (Exception ex) { SetStatus($"could not open {Path.GetFileName(path)}: {ex.Message}{StillOpenNote()}"); AppLog.Error("app", "open failed", ex); }
        finally
        {
            _opening = false;
            _openingName = "";
            UpdateTitle();
        }
    }

    /// One ROM opens at a time: an open runs to its end - the disassembly, the reference ROMs and Detect take seconds - before another
    /// starts, the ROM is saved or closed, or the settings change. Two at once left one ROM loaded under the other's processor, with
    /// the other's maps and its name on the status line. True (and a word on the status line) while an open is under way.
    bool StillOpening(string what)
    {
        if (!_opening) return false;
        SetStatus($"still opening {_openingName}: {what} once it is open");
        return true;
    }

    /// What is still open after an open that did not happen, for its message.
    string StillOpenNote() => (_openedImage ?? _host.LoadedPath) is { } open ? $" - {Path.GetFileName(open)} is still open" : "";

    /// A .asm build (a skeleton ROM's build file, or any source): assembled, and its image tuned. Its definitions come from its annotations.
    /// It is assembled first, on the part it is for, and takes the place of the ROM open now only once it has built (and its password,
    /// when it has one, was given): a source that does not assemble leaves that ROM - its definitions, its part - as it was.
    async Task OpenBuild(string path)
    {
        var text = await File.ReadAllTextAsync(path);
        // a source that says which part it is for gets that part; one that does not is a 66207 source. The assembler reads the part's
        // register names, so it is in place while the source assembles (and put back if it does not).
        var before = _profile;
        var want = ProcessorProfile.Declared(text) ?? (IsP13Part(before) ? ProcessorProfile.Msm66207() : before);
        bool otherPart = !want.Name.Equals(before.Name, StringComparison.OrdinalIgnoreCase);
        bool letGo = false;
        if (otherPart)
        {
            // the emulator and the datalog belong to the ROM open now, on the other part: let go before the part changes under them
            letGo = DisconnectLinks(path);
            want.Apply();
        }
        SetStatus($"assembling {Path.GetFileName(path)}…");
        var r = await Task.Run(() => _host.Build(path, load: false));
        string? refused = !r.Success || r.Assembly == null
            ? $"{Path.GetFileName(path)} does not assemble: {r.Diagnostics.FirstOrDefault(d => d.Severity == Severity.Error)}"
            : !await RomPasswordUi.Unlock(this, r.Assembly.Image, Path.GetFileName(path)) ? $"{Path.GetFileName(path)} was not opened: it is protected with a password"
            : null;
        if (refused != null)
        {
            if (otherPart) before.Apply();
            SetStatus(refused + StillOpenNote() + (letGo ? " (the emulator and the datalog were let go)" : ""));
            return;
        }
        ResetForNewRom(path);
        if (otherPart) ApplyProfile(want);
        _host.LoadImage(r.Assembly!.Image, r.Assembly, path);
        _host.RefreshMapSensor();
        _calibration.Refresh();
        SetStatus($"{Path.GetFileName(path)}: built in {r.Milliseconds} ms, {_host.Defs().Items.Count} definitions from its source");
        await OfferDetect(path);
    }

    /// A ROM image: disassembled and assembled again here (in memory) so its code has names and Detect can follow it, but the bytes
    /// tuned and saved are always the file's own: when the disassembly does not rebuild to them, the image is opened without it.
    async Task OpenBinary(string path)
    {
        var bytes = await File.ReadAllBytesAsync(path);
        // a 64 KB (512) chip image holds two ROMs: open the half the ECU would run
        if (bytes.Length == Chip.RomSize * 2)
        {
            bool lowBlank = bytes[..Chip.RomSize].All(b => b == 0xFF) || bytes[..Chip.RomSize].All(b => b == 0);
            var pick = lowBlank ? "Upper half" : await Dialogs.Ask(this, "64 KB image",
                $"{Path.GetFileName(path)} is a 64 KB (512) chip image: two 32 KB ROMs, 0000-7FFF and 8000-FFFF. A board with the top address line tied high runs the upper half. Which one?",
                "Cancel", "Lower half", "Upper half");
            if (pick is null or "Cancel") return;
            bool upper = pick == "Upper half";
            bytes = upper ? bytes[Chip.RomSize..] : bytes[..Chip.RomSize];
            // a half saved beside it before - and perhaps tuned and saved over since - is never written over
            var half = AppPaths.Unclobbered(Path.Combine(Path.GetDirectoryName(path)!, Path.GetFileNameWithoutExtension(path) + (upper ? "_high" : "_low") + ".bin"), bytes);
            if (!File.Exists(half)) SafeFile.WriteAllBytes(half, bytes);
            SetStatus($"{Path.GetFileName(path)}: the {(upper ? "upper" : "lower")} half, saved as {Path.GetFileName(half)} and opened" + (lowBlank ? " (the lower half is blank)" : ""));
            path = half;
        }
        if (bytes.Length == Chip.RomSize + 1 && bytes[^1] == 0) bytes = bytes[..Chip.RomSize];
        if (bytes.Length > Chip.RomSize) { SetStatus($"{Path.GetFileName(path)} is {bytes.Length} bytes; a 66207 ROM image is at most {Chip.RomSize}"); return; }
        if (!await RomPasswordUi.Unlock(this, bytes, Path.GetFileName(path))) { SetStatus($"{Path.GetFileName(path)} was not opened: it is protected with a password"); return; }
        // the part the image was built for, so it is read (disassembled, its maps found) on the right one - in place while it is read,
        // made the window's own once it has been, and put back if it cannot be read: until then the ROM open now stays as it is
        var before = _profile;
        var want = ProcessorProfile.ForImage(bytes) is { } part && IsP13Part(part) != IsP13Part(before) ? part : before;
        bool otherPart = !ReferenceEquals(want, before);
        bool letGo = false;
        if (otherPart) { letGo = DisconnectLinks(path); want.Apply(); }
        SetStatus("disassembling…");
        DefinitionSet? saved = null;
        var sidecar = DefinitionsFileFor(path);
        if (File.Exists(sidecar))
            try { saved = DefinitionSet.Load(sidecar); }
            catch (Exception ex) { AppLog.Error("app", "definitions file unreadable", ex); SetStatus($"{Path.GetFileName(sidecar)} could not be read: {ex.Message}"); }
        TunerOpen.Opened opened;
        try { opened = await Task.Run(() => TunerOpen.Image(bytes, path, saved)); }
        catch (Exception ex)
        {
            if (otherPart) before.Apply();
            SetStatus($"could not open {Path.GetFileName(path)}: {ex.Message}{StillOpenNote()}" + (letGo ? " (the emulator and the datalog were let go)" : ""));
            AppLog.Error("app", "open failed", ex);
            return;
        }
        ResetForNewRom(path);
        if (otherPart) ApplyProfile(want);
        _openedImage = path;
        _generated.Clear();
        if (opened.Asm != null) _generated[opened.SourcePath] = opened.Text;
        _host.LoadImage(opened.Image, opened.Asm, opened.Asm != null ? opened.SourcePath : path);
        if (saved != null)
        {
            _host.ReplaceDefinitions(saved);
            _host.RefreshMapSensor();
            _calibration.Refresh();
            SetStatus($"{Path.GetFileName(path)}: names, tables and page bindings put back from {Path.GetFileName(sidecar)} ({saved.Items.Count} definitions)" + opened.Note);
            return;
        }
        _host.RefreshMapSensor();
        _calibration.Refresh();
        string what = HtsLayout.Describe(opened.Image) is { Length: > 0 } kind ? $"{Path.GetFileName(path)} is {kind}" : $"{Path.GetFileName(path)} opened";
        SetStatus(what + opened.Note);
        // no definitions file beside it: its maps are found now, the way Detect finds them
        if (_host.Assembly != null && _host.Defs().Items.Count == 0)
        {
            await _calibration.DetectAsync();
            int n = _host.Defs().Items.Count;
            SetStatus(n > 0 ? $"{what}  -  Detect found {n} maps and settings{opened.Note}" : $"{what}  -  Detect found no maps in it{opened.Note}");
        }
    }

    /// A ROM image that came from somewhere other than a file the user picked (the ROM carried in an .rlog): kept in the temp folder and opened like any other .bin.
    void OpenRomImage(byte[] rom, string name)
    {
        try
        {
            var dir = Path.Combine(Path.GetTempPath(), "Rom Sim Studio");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, Path.GetFileNameWithoutExtension(name) + ".bin");
            SafeFile.WriteAllBytes(path, rom);
            OpenFile(path);
        }
        catch (Exception ex) { SetStatus("could not open the ROM from the log: " + ex.Message); AppLog.Error("app", "ROM from log failed", ex); }
    }

    /// The .bin Download read out of the emulator: opening it keeps the emulator and the datalog connected.
    async void OpenDownloaded(string path)
    {
        if (StillOpening($"the emulator's ROM ({Path.GetFileName(path)}) can be opened from File")) return;
        if (!await ConfirmReplaceCurrent()) { SetStatus($"the emulator's ROM is saved as {path}; open it from File when you are ready"); return; }
        _keepLinksFor = path;
        OpenFile(path);
    }

    /// Opening another ROM: forget the one before it (definitions, undo, hits), so Detect and the calibration pages cannot mix the two.
    void ResetForNewRom(string path)
    {
        _openedImage = null;
        _generated.Clear();
        _datalog.StopPlayback();
        DisconnectLinks(path);
        if (_keepLinksFor != null && string.Equals(_keepLinksFor, path, StringComparison.OrdinalIgnoreCase)) _keepLinksFor = null;
        _host.ResetRomState();
        _calibration.ResetForNewRom();
        AppLog.Action("app", "opening " + Path.GetFileName(path) + ": previous ROM state cleared");
    }

    /// The emulator and the datalog belong to the ROM that was open: let go when another takes its place (or the part changes for one
    /// about to) - except for the ROM just read out of the emulator, which is the one the car is running. True when something was linked.
    bool DisconnectLinks(string path)
    {
        if (_keepLinksFor != null && string.Equals(_keepLinksFor, path, StringComparison.OrdinalIgnoreCase)) return false;
        bool linked = _host.Emulator.Connected || _datalog.Engine.Running || _datalog.Engine.Watch.Wanted;
        _calibration.DisconnectEmulator();
        if (_datalog.Engine.Running || _datalog.Engine.Watch.Wanted) _datalog.Stop();
        if (linked) SetStatus("another ROM: the emulator and the datalog were disconnected");
        return linked;
    }

    /// File > Close ROM.
    async Task CloseRom()
    {
        if (StillOpening("it can be closed")) return;
        if (!await ConfirmReplaceCurrent()) return;
        _datalog.StopPlayback();
        _calibration.DisconnectEmulator();
        _host.Clear();
        _generated.Clear();
        _openedImage = null;
        _calibration.ResetForNewRom();
        _calibration.Refresh();
        UpdateTitle();
        SetStatus("ROM closed");
    }

    /// The definitions file that goes with a .bin: name.okidef.json beside it.
    static string DefinitionsFileFor(string bin) => Path.ChangeExtension(bin, null) + ".okidef.json";

    /// File > Save ROM: the tuned image to a .bin, then the definitions file offered. False when nothing was saved.
    async Task<bool> SaveRom()
    {
        if (StillOpening("it can be saved")) return false;
        if (_host.LoadedPath == null) { SetStatus("nothing is open to save"); return false; }
        if (!await _calibration.SaveRomAsync()) return false;
        UpdateTitle();
        if (_host.LastSavedPath is { } saved) await OfferDefinitionsFile(saved, _host.Defs(), _host.Assembly);
        return true;
    }

    /// A .bin was saved: offer the definitions file that keeps its names - opened again on its own, a .bin has none.
    async Task OfferDefinitionsFile(string bin, DefinitionSet defs, AssemblyResult? asm)
    {
        try
        {
            var file = DefinitionsFileFor(bin);
            var pick = await Dialogs.Ask(this, "Save a definitions file too?",
                $"{Path.GetFileName(bin)} is saved. Also save {Path.GetFileName(file)} beside it?\n\n" +
                "A .bin holds only the bytes. Opened again on its own, its tables and settings have no names, scaling or page bindings, " +
                "and Detect has to find them again.\n\n" +
                $"The definitions file keeps all of that ({defs.Items.Count} definitions, {defs.Symbols.Count} labels). Keep it next to the .bin with the " +
                "same name, and opening the .bin puts everything back.",
                "Save definitions too", "Just the .bin");
            if (pick != "Save definitions too") return;
            if (File.Exists(file)) File.Copy(file, file + ".bak", overwrite: true);
            if (asm != null)
                defs.Labels = asm.Symbols.Values.Where(x => x.Kind == SymbolKind.Label && x.Value >= 0 && x.Value < asm.Image.Length)
                                 .GroupBy(x => x.Name).ToDictionary(g => g.Key, g => (int)g.First().Value);
            defs.Save(file);
            SetStatus($"saved {Path.GetFileName(bin)} and {Path.GetFileName(file)} - open the .bin to get every name back");
            AppLog.Action("app", "definitions saved to " + file);
        }
        catch (Exception ex) { SetStatus("could not save the definitions file: " + ex.Message); AppLog.Error("app", "definitions file failed", ex); }
    }

    /// Run Detect on a ROM just opened from source, if the user wants it (Settings > General can stop the question).
    async Task OfferDetect(string path)
    {
        try
        {
            if (!_settings.AskDetectOnOpen || _host.Assembly == null || _host.LoadedPath is not { } loaded || !string.Equals(loaded, path, StringComparison.OrdinalIgnoreCase)) return;
            var defs = _host.Defs();
            int items = defs.Items.Count, onPages = CalPage.All().SelectMany(p => p.Slots()).Count(s => CalPage.Bound(defs, s) != null);
            string what = items == 0
                ? "It has no definitions yet: the calibration list and the feature pages are empty until Detect has found its tables and settings."
                : $"It has {items} definition(s) from its source already ({onPages} page row(s) filled in). Detect looks for the tables and settings the source does not describe.";
            var pick = await Dialogs.Ask(this, "Run Detect?",
                $"{Path.GetFileName(path)} is open. Run Detect on it?\n\n{what}\n\nIt lines the ROM up with the known ROMs and follows the code that reads each table; it takes a few seconds. " +
                "It can be run again at any time from the calibration editor's Detect button.",
                "Run Detect", "Not now", "Don't ask again");
            if (pick == "Don't ask again") { _settings.AskDetectOnOpen = false; _settings.Save(); SetStatus("Detect will not be offered again (Settings > General turns it back on)"); return; }
            if (pick != "Run Detect") return;
            await _calibration.DetectAsync();
        }
        catch (Exception ex) { AppLog.Error("app", "detect offer failed", ex); }
    }

    /// File > Set-up wizard.
    async Task SetupWizard()
    {
        if (StillOpening("the set-up wizard opens")) return;
        if (_host.LoadedPath == null) { SetStatus("open a ROM first"); return; }
        var w = new SetupWizardWindow(_host);
        await w.ShowDialog(this);
        if (w.Result is { } done) { SetStatus(done); _calibration.Refresh(); }
    }

    void OpenBinTool()
    {
        if (StillOpening("the bin tool opens")) return;
        var w = new BinToolWindow(() => _host.LoadedPath == null ? null : _host.RomCopy(), Path.GetFileName(_host.LoadedPath ?? ""));
        _ = Dialogs.ShowModal(w, this);
    }

    void OpenCompare()
    {
        if (StillOpening("Compare opens")) return;
        Mcp.Program66k? Current()
        {
            try
            {
                if (_host.LoadedPath == null) return null;
                var rom = _host.RomBytes(0, Chip.RomSize);
                var srcs = Sources().ToList();
                return _host.Assembly is { } asm ? Mcp.Program66k.FromAssembly(_host.LoadedPath, rom, asm, srcs) : Mcp.Program66k.FromImage(rom, _host.LoadedPath);
            }
            catch (Exception ex) { AppLog.Error("compare", "could not prepare the open ROM", ex); return null; }
        }
        new CompareWindow(Current, _host.LoadedPath).Show(this);
    }

    /// File > Log: everything logged this session - the actions, the warnings and errors (with their details), the datalog's and the
    /// emulator's traffic. (Rom Sim Studio shows the same on its Debug page.)
    void OpenLog()
    {
        if (_logWindow != null) { _logWindow.Activate(); return; }
        var w = new Window { Title = $"Log - {AppName}", Width = 960, Height = 620, MinWidth = 500, MinHeight = 300 };
        var view = new DebugView(() => w);
        var chrome = DarkChrome.Apply(w, w.Title);
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(view, 1); g.Children.Add(view);
        w.Content = g;
        var tick = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        tick.Tick += (_, _) => view.Tick();
        w.Opened += (_, _) => { view.Tick(); tick.Start(); };
        w.Closed += (_, _) => { tick.Stop(); _logWindow = null; };
        _logWindow = w;
        w.Show(this);
    }

    /// The ROM open (and ● while it has changes not in a file) in the title, which the bar at the top shows.
    void UpdateTitle()
    {
        var open = _openedImage ?? _host.LoadedPath;
        var title = open == null ? $"{AppName} {BuildInfo.Version}" : $"{Path.GetFileName(open)}{(_host.RomDirty ? " ●" : "")} - {AppName} {BuildInfo.Version}";
        if (Title != title) Title = title;
    }

    /// A password or watermark written to a ROM built from a New ROM build file: kept in that file too (as Rom Sim Studio keeps it), so
    /// building it again does not bring back the old one. Only a build file New ROM made (it says so in its own text) is changed.
    void KeepInBuildFile(ItemDef item)
    {
        try
        {
            if (item.Text is not ("watermark" or "password") || _openedImage != null || _host.LoadedPath is not { } build
                || !build.EndsWith(".asm", StringComparison.OrdinalIgnoreCase) || !File.Exists(build)) return;
            var text = File.ReadAllText(build);
            if (!text.Contains("by File > New ROM > Create")) return;
            var defs = _host.Defs();
            if (defs.Items.FirstOrDefault(i => i.Text == "watermark") is not { } w
                || !defs.Items.Any(i => i.Text == "password" && i.Address == w.Address + WatermarkCodec.Bytes)) return;
            var wm = _host.RomBytes(w.Address, WatermarkCodec.Bytes + RomPassword.Bytes);
            var updated = Skeleton.WithKept(text, null, defs.Items.FirstOrDefault(i => i.Name == "RomId")?.Address ?? 0x7FE0, wm);
            if (updated == text) return;
            SafeFile.WriteAllText(build, updated);
            SetStatus($"the {item.Text} is kept in {Path.GetFileName(build)} too, so building it again keeps it");
            AppLog.Action("app", $"{Path.GetFileName(build)}: watermark kept in the build file");
        }
        catch (Exception ex) { AppLog.Error("app", "could not keep the value in the build file", ex); }
    }

    // ------------------------------------------------------------------ closing

    /// Closing with calibration changes not in a file: save them, leave them, or stay.
    async void AskBeforeClose()
    {
        _closeAsking = true;
        try
        {
            var answer = await Dialogs.Ask(this, "Save your changes?",
                $"Closing {AppName}, and the ROM has calibration changes that are not in a file yet.\n\nSave first, close without saving, or stay?",
                "Save", "Close without saving", "Cancel");
            if (answer is not ("Save" or "Close without saving")) { SetStatus("not closed: your changes are still here"); return; }
            if (answer == "Save" && !await SaveRom()) { SetStatus("not closed: the ROM was not saved"); return; }
            if (answer != "Save") AppLog.Action("app", "closed without saving the calibration changes");
            _closeConfirmed = true;
            Close();
        }
        catch (Exception ex) { AppLog.Error("app", "asking before close failed", ex); }
        finally { _closeAsking = false; }
    }

    // ------------------------------------------------------------------ refresh, status, keys

    void SetStatus(string text)
    {
        if (text != _lastLogged) { _lastLogged = text; AppLog.Info("status", text); }
        _calibration.ShowStatus(text);
    }

    void SafeRefresh()
    {
        try
        {
            // where the engine is on the map goes straight from each frame (DatalogView posts it as it arrives); this is the slower rest
            _datalog.Tick();
            _calibration.Tick();
            if ((DateTime.UtcNow - _lastSlow).TotalMilliseconds >= Perf.SidePanelsMs)
            {
                _lastSlow = DateTime.UtcNow;
                _calibration.UpdateEmulator();
                _calibration.SetOverlayChannels(_datalog.Channels(), _settings.OverlayChannel);
            }
            if (_datalog.Engine.Running) _calibration.UpdateOverlay(throttle: true);
        }
        catch (Exception ex) { SetStatus("refresh failed: " + ex.Message); }
    }

    /// A Demon datalogs over the emulator's own port: when the emulator connects, the datalog is connected too (once per connection).
    void DemonDatalog()
    {
        var emu = _host.Emulator;
        if (!emu.Connected || emu.Device != "Demon" || emu.Connections == _demonLinked) return;
        _demonLinked = emu.Connections;
        if (_datalog.Engine.Running || _datalog.Engine.Watch.Wanted) return;
        _datalog.Port = "emulator";
        _datalog.Start();
        SetStatus("the Demon is connected: datalogging through it as well (same port)");
    }

    void DemonClosed()
    {
        if (_datalog.Engine.IsEmulatorPort(_datalog.Port) && (_datalog.Engine.Running || _datalog.Engine.Watch.Wanted)) _datalog.Stop();
    }

    void NextTheme()
    {
        var next = AppTheme.Next(AppTheme.Now);
        _settings.Theme = AppTheme.Name(next);
        _settings.Save();
        AppTheme.Set(next);
        SetStatus($"{AppTheme.Label(next)} theme (Ctrl+Shift+H for the next; Settings > Colours)");
    }

    void OnKeyDown(object? sender, KeyEventArgs e)
    {
        string? action = _hotKeys.FirstOrDefault(kv => kv.Value.Matches(e)).Key;
        switch (action)
        {
            case null: return;
            case "Open": OpenFileDialog(); break;
            case "Save": _ = SaveRom(); break;
            case "Settings": OpenSettings(); break;
            case "Theme": NextTheme(); break;
            case "Compare": OpenCompare(); break;
            // the simulator's keys (run, step, build, breakpoints...) and the project and mode keys: Rom Sim Studio's
            case "Run / pause" or "Step" or "Step over" or "Step into" or "Step out" or "Reset" or "Build" or "Patch live" or "Toggle breakpoint"
                or "Save project" or "Tuner mode" or "Expand lower tabs":
                SetStatus($"{action}: not in the tuning-only build (Rom Sim Studio has it)");
                break;
            default: return;
        }
        e.Handled = true;
    }
}

/// Opening a ROM image for tuning, with no window (TunerWindow and --selftest): the image as the ROM space holds it, and - when the
/// disassembly made of it assembles back to exactly those bytes - that assembly, for the names of the code and for Detect.
public static class TunerOpen
{
    public sealed record Opened(byte[] Image, AssemblyResult? Asm, string SourcePath, string Text, string Note);

    public static Opened Image(byte[] bytes, string path, DefinitionSet? saved)
    {
        var image = new byte[Chip.RomSize];
        Array.Fill(image, (byte)0xFF);
        Array.Copy(bytes, image, Math.Min(bytes.Length, Chip.RomSize));
        string note = bytes.Length < Chip.RomSize ? $" (a short image: padded from {bytes.Length} bytes with FF)" : "";
        var asmPath = Path.ChangeExtension(path, ".asm");
        if (File.Exists(asmPath)) asmPath = Path.ChangeExtension(path, ".disasm.asm");
        Dictionary<int, string>? names = null;
        if (saved != null)
        {
            names = [];
            foreach (var (n, a) in saved.Labels ?? []) names.TryAdd(a, n);
            foreach (var it in saved.Items) names.TryAdd(it.Address, it.Name);
        }
        var full = Path.GetFullPath(asmPath);
        var dis = BinDisassembler.Disassemble(image, Path.GetFileName(path), text =>
        {
            var r = new OkiAssembler(new AssemblerOptions { ReadFile = f => f == full ? text : null }).AssembleText(text, asmPath);
            return (r.Success ? r.Image : null, r.Diagnostics.Where(d => d.Severity == Severity.Error).Select(d => d.Line));
        }, names);
        AssemblyResult? asm = null;
        try
        {
            var r = new OkiAssembler(new AssemblerOptions { ReadFile = f => f == full ? dis.Text : null }).AssembleText(dis.Text, asmPath);
            if (r.Success && r.Image.Length >= Chip.RomSize && r.Image.AsSpan(0, Chip.RomSize).SequenceEqual(image)) asm = r;
        }
        catch (Exception ex) { AppLog.Error("app", "the disassembly did not assemble", ex); }
        if (asm == null) note += " - its disassembly does not rebuild to exactly these bytes, so it is opened without one: no code names, and Detect cannot run (a definitions file still applies)";
        return new Opened(image, asm, asmPath, dis.Text, note);
    }
}
