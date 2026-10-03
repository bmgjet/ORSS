// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Presenters;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Avalonia.VisualTree;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// `RomSimStudio --ui-check <folder>`: opens every window and page at 1920 x 1080 and 1366 x 768, saves a picture of each, and lists every input that is off the window, clipped by the panel it sits in, or lying over a piece of text - the "the box covers its label" and "I have to stretch the window to see the inputs" kind of fault. Writes report.txt to the folder, then quits.
public static class UiCheck
{
    /// Running the check: nothing it does to the windows is saved.
    public static bool Active { get; private set; }

    public static string? Folder(string[] args)
    {
        int i = Array.IndexOf(args, "--ui-check");
        Active |= i >= 0;
        return i < 0 ? null : i + 1 < args.Length ? args[i + 1] : Path.Combine(Path.GetTempPath(), "okirom-ui-check");
    }

    public static async Task Run(MainWindow main, string dir)
    {
        Directory.CreateDirectory(dir);
        var report = new List<string>();
        try
        {
            // OKIROM_UICHECK_HC=1: everything in high contrast OKIROM_UICHECK_THEME=light / contrast: everything in that theme
            AppTheme.Set(AppTheme.Parse(Environment.GetEnvironmentVariable("OKIROM_UICHECK_THEME") ?? (Environment.GetEnvironmentVariable("OKIROM_UICHECK_HC") == "1" ? "contrast" : "dark")));
            await Settle();
            // OKIROM_UICHECK_OPEN=rom.asm: open that ROM first (the windows then show its settings)
            if (Environment.GetEnvironmentVariable("OKIROM_UICHECK_OPEN") is { Length: > 0 } open)
            {
                main.OpenFileForCheck(open);
                for (int i = 0; i < 120 && !string.Equals(main.Host.LoadedPath, Path.GetFullPath(open), StringComparison.OrdinalIgnoreCase); i++) await Task.Delay(250);
                await Task.Delay(1500);
            }
            // OKIROM_UICHECK_INJPICK=550: the injector window with that injector picked, and what it would write
            if (Environment.GetEnvironmentVariable("OKIROM_UICHECK_INJPICK") is { Length: > 0 } pick)
            {
                var iw = new InjectorWindow(main.Host);
                report.Add(iw.PickForCheck(pick));
                File.WriteAllLines(Path.Combine(dir, "report.txt"), report);
                (Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.Shutdown();
                return;
            }
            // OKIROM_UICHECK_PLUGIN=plugin.dll: load it, open everything it adds (its tab, every menu line, its settings page), and report every error it logs or throws on the way
            if (Environment.GetEnvironmentVariable("OKIROM_UICHECK_PLUGIN") is { Length: > 0 } pluginPath && main.PluginsForCheck is { } pm)
            {
                var errors = new List<string>();
                void Logged(LogEntry e) { if (e.Kind is LogKind.Error or LogKind.Warning) lock (errors) errors.Add($"{e.Kind} {e.Source}: {e.Message} {e.Detail}".Trim()); }
                AppLog.Added += Logged;
                void Unhandled(object? _, Avalonia.Threading.DispatcherUnhandledExceptionEventArgs e) { lock (errors) errors.Add("UNHANDLED " + e.Exception); e.Handled = true; }
                Dispatcher.UIThread.UnhandledException += Unhandled;
                int before = pm.MenuItems.Count;
                report.Add("load: " + (pm.Load(pluginPath) ?? "ok"));
                await Settle();
                var lifetime = Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime;
                async Task ShotNew(string label, Func<Task> act)
                {
                    var had = lifetime?.Windows.ToList() ?? [];
                    int e0; lock (errors) e0 = errors.Count;
                    try { await act(); } catch (Exception ex) { lock (errors) errors.Add($"THREW in {label}: {ex}"); }
                    for (int k = 0; k < 4; k++) await Settle();
                    foreach (var w in (lifetime?.Windows.ToList() ?? []).Except(had))
                    {
                        Check(w, $"plugin {label}", dir, report);
                        w.Close();
                        await Settle();
                    }
                    lock (errors) report.Add($"  {label}: {errors.Count - e0} error(s)" + (errors.Count > e0 ? "\n    " + string.Join("\n    ", errors.Skip(e0).Take(4)) : ""));
                }
                // the emulator takeover: the app's Emulator / Datalogging controls go to the plugin; Connect must reach only a real device
                if (pm.Emulator is { } emu)
                {
                    report.Add($"takeover: {emu.Name}, connected {emu.Connected}, status '{emu.Status}', realtime {emu.RealtimeUpdate}");
                    await ShotNew("takeover connect", async () =>
                    {
                        emu.ToggleConnect();
                        for (int k = 0; k < 20 && emu.Connecting; k++) await Task.Delay(250);
                        report.Add($"  after Connect: connected {emu.Connected}, status '{emu.Status}'");
                        if (emu.Connected || emu.Connecting) emu.ToggleConnect();
                    });
                    // OKIROM_UICHECK_PLUGIN_SIM=1: the plugin's simulated device switched on (its own setting), then the whole round
                    if (Environment.GetEnvironmentVariable("OKIROM_UICHECK_PLUGIN_SIM") == "1")
                        await ShotNew("takeover simulated", async () =>
                        {
                            emu.ToggleConnect();
                            for (int k = 0; k < 20 && !emu.Connected; k++) await Task.Delay(250);
                            report.Add($"  simulated: connected {emu.Connected}, status '{emu.Status}'");
                            emu.Validate(); await Task.Delay(1500);
                            emu.ToggleRealtime(); report.Add($"  realtime after toggle: {emu.RealtimeUpdate}");
                            emu.ToggleConnect(); await Task.Delay(500);
                            report.Add($"  after disconnect: connected {emu.Connected}");
                        });
                }
                else report.Add("takeover: none");
                // its tab
                await ShotNew("tab", async () => { main.ShowTab("ALPHAemu"); await Settle(); Check(main, "plugin tab", dir, report); });
                // every menu line it added (Disconnect last)
                var lines = pm.MenuItems.Skip(before).Where(m => !m.Separator).ToList();
                foreach (var m in lines.OrderBy(m => m.Text.StartsWith("Disconnect") ? 1 : 0))
                    await ShotNew(m.Text, () => { m.Run(); return Task.CompletedTask; });
                // its settings pages
                foreach (var (title, build) in pm.SettingsPages)
                    await ShotNew("settings " + title, () =>
                    {
                        var win = new Window { Width = 900, Height = 700, Content = build() };
                        win.Show();
                        return Task.CompletedTask;
                    });
                await ShotNew("unload", () => { pm.Unload(pluginPath); return Task.CompletedTask; });
                AppLog.Added -= Logged;
                Dispatcher.UIThread.UnhandledException -= Unhandled;
                lock (errors) { report.Add($"TOTAL errors {errors.Count}"); report.AddRange(errors); }
                File.WriteAllLines(Path.Combine(dir, "report.txt"), report);
                lifetime?.Shutdown();
                return;
            }
            // OKIROM_UICHECK_ONLY="import maps,main": just those (a quicker look at one window while working on it)
            var only = Environment.GetEnvironmentVariable("OKIROM_UICHECK_ONLY") is { Length: > 0 } o
                ? o.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries) : null;
            bool Wanted(string n) => only == null || only.Contains(n, StringComparer.OrdinalIgnoreCase);
            // OKIROM_UICHECK_RUN=1: run the simulator a few seconds first, and look something up, so the pages have rows
            if (Environment.GetEnvironmentVariable("OKIROM_UICHECK_RUN") == "1")
            {
                main.Host.SetInput("rpm", 1500); main.Host.SetInput("map", 40);
                main.Host.Control("run");
                for (int i = 0; i < 25; i++) await Settle();
                main.Host.Control("pause");
                main.LookupForCheck("0ach");
                await Settle();
            }
            // OKIROM_UICHECK_TABLES=1: the three views of a map - Table, Line and 3D - and the 3D view turned right round, one picture per 10 degrees
            if (Environment.GetEnvironmentVariable("OKIROM_UICHECK_TABLES") == "1")
            {
                async Task Shot(Window w, string file)
                {
                    w.Show(); await Settle();
                    using var bmp = new RenderTargetBitmap(new PixelSize((int)w.Bounds.Width, (int)w.Bounds.Height));
                    bmp.Render(w); bmp.Save(Path.Combine(dir, file + ".png"));
                }
                var grid = new TableGrid { Model = SampleMap(), ReadOnly = true, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Left, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Top };
                var gw = new Window { Width = 620, Height = 218, Content = grid };
                await Shot(gw, "table-grid"); gw.Close();
                var gr = new Window { Width = 1000, Height = 560, Content = new TableGraph { Model = SampleMap() } };
                await Shot(gr, "table-line"); gr.Close();
                var surf = new TableSurface { Model = SampleMap(), ReadOnly = true };
                var sw = new Window { Width = 1000, Height = 640, Content = surf };
                sw.Show(); await Settle();
                for (int k = 0; k < 36; k++)
                {
                    surf.SetAngles(-0.7 + (k * Math.PI / 18), 0.55);
                    await Shot(sw, $"table-3d-{k:00}");
                }
                sw.Close();
                (Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.Shutdown();
                return;
            }
            // OKIROM_UICHECK_STREAM=1: a Default skeleton ROM logged from the simulator by the channel stream; channels picked and unpicked while logging must show up (and go) in the frames, the values list and the channel lists
            if (Environment.GetEnvironmentVariable("OKIROM_UICHECK_STREAM") == "1")
            {
                var sk = Skeleton.Find(NewRomWindow.Templates()).First(s => s.Name.Contains("p30", StringComparison.OrdinalIgnoreCase) || true);
                var dirS = Path.Combine(Path.GetTempPath(), "romsim-streamcheck");
                Directory.CreateDirectory(dirS);
                var rom = Path.Combine(dirS, "streamcheck.asm");
                File.WriteAllText(rom, sk.BuildSource(SkeletonPresets.Default, sk.Path, "streamcheck"));
                main.OpenFileForCheck(rom);
                for (int i = 0; i < 120 && main.Host.LoadedPath == null; i++) await Task.Delay(250);
                await Task.Delay(1500);
                var view = main.DatalogPanel;
                var eng = view.Engine;
                ChannelStream.Selected = [.. DatalogChannels.Defaults];
                eng.Good = 0;
                _ = Task.Run(() => { try { eng.Start("simulator", "auto", 38400); } catch (Exception ex) { report.Add("start: " + ex.Message); } });
                var t0 = DateTime.Now;
                while ((DateTime.Now - t0).TotalSeconds < 30 && eng.Good < 10) await Task.Delay(250);
                report.Add($"connected: {eng.Protocol?.Name ?? "-"}, {eng.Good} frames; channels {string.Join(",", eng.Latest?.Channels() ?? [])}");
                async Task Pick(string[] picks, string what)
                {
                    view.SetPicksForCheck(picks);
                    var t1 = DateTime.Now;
                    while ((DateTime.Now - t1).TotalSeconds < 8) await Task.Delay(250);
                    var ch = eng.Latest?.Channels().ToList() ?? [];
                    report.Add($"{what}: frame has {string.Join(",", ch)}");
                    report.Add($"  values list: {string.Join(",", view.ShownParameterNames())}");
                    report.Add($"  offered channels: {string.Join(",", view.Channels())}");
                }
                await Pick([.. DatalogChannels.Defaults, "cuts", "limiters"], "rev limit added");
                await Pick([.. DatalogChannels.Defaults], "rev limit taken off");
                await Pick([.. DatalogChannels.Everything(DatalogChannels.TableSizeAll)], "everything");
                // the functions' own state: module RAM named from the build
                await Pick([.. DatalogChannels.Defaults, .. Enumerable.Range(0, ModuleDebug.Bytes).Select(i => $"mod{i}")], "function state");
                report.Add($"  module RAM names: {string.Join(",", ModuleDebug.Variables.Select(v => v.Name))}");
                // several values picked, and gauges made of them from the right-click menu
                int before = view.Gauges.Count;
                view.ValuesForCheck.PickKeys(["rpm", "ect_c", "map_kpa"]);
                var items = view.ValuesForCheck.SelectionMenu?.Invoke(view.ValuesForCheck.SelectedRows).ToList() ?? [];
                report.Add($"  picked {view.ValuesForCheck.SelectedRows.Count}: {string.Join(",", view.ValuesForCheck.SelectedRows.Select(r => r.Cells[0].Text))}; menu: {string.Join(" | ", items.Select(i => i.Text))}");
                items.FirstOrDefault().Run?.Invoke();
                await Settle();
                report.Add($"  gauges {before} -> {view.Gauges.Count}");
                main.ShowTab("Datalog"); await Settle();
                Check(main, "datalog values picked", dir, report);
                await Task.Run(eng.Stop);
                File.WriteAllLines(Path.Combine(dir, "report.txt"), report);
                (Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.Shutdown();
                return;
            }
            // OKIROM_UICHECK_SIMDL="a.asm;b.asm": open each ROM and datalog it from the simulator (protocol auto), as Connect does; report what it got
            if (Environment.GetEnvironmentVariable("OKIROM_UICHECK_SIMDL") is { Length: > 0 } simdl)
            {
                foreach (var rom in simdl.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                {
                    main.OpenFileForCheck(rom);
                    for (int i = 0; i < 60 && main.Host.LoadedPath == null; i++) await Task.Delay(250);
                    await Task.Delay(1500);
                    var eng = main.DatalogPanel.Engine;
                    eng.Good = 0;
                    var t0 = DateTime.Now;
                    _ = Task.Run(() => { try { eng.Start("simulator", "auto", 38400); } catch (Exception ex) { report.Add("start: " + ex.Message); } });
                    while ((DateTime.Now - t0).TotalSeconds < 25 && eng.Good < 20) await Task.Delay(250);
                    report.Add($"{Path.GetFileName(rom)}: loaded {main.Host.LoadedPath != null}, running {main.Host.IsRunning}, {eng.Good} frames, {eng.Bad} missed, " +
                               $"protocol {eng.Protocol?.Name ?? "-"}, status '{eng.Status}' after {(DateTime.Now - t0).TotalSeconds:0.0} s\n{eng.DetectReport}");
                    await Task.Run(eng.Stop);
                }
                File.WriteAllLines(Path.Combine(dir, "report.txt"), report);
                (Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.Shutdown();
                return;
            }
            // OKIROM_UICHECK_PERF=seconds: what the app costs - CPU, memory, garbage collections and how late the UI thread answers - sitting in Tuner mode, replaying a log there, and with the simulator running
            if (int.TryParse(Environment.GetEnvironmentVariable("OKIROM_UICHECK_PERF"), out var secs) && secs > 0)
            {
                main.WindowState = WindowState.Maximized;
                var frames = Enumerable.Range(0, 20 * 600).Select(k => new OkiRomSim.Calibration.LogFrame
                {
                    T = k * 0.05, Rpm = 1000 + (k % 400 * 15), MapKpa = 40 + (30 * Math.Sin(k * 0.05)), TpsPct = 20, EctC = 85, IatC = 25, BattV = 14,
                    InjMs = 3, IgnDeg = 20, Raw = new byte[51],
                }).ToList();
                async Task Measure(string what)
                {
                    GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
                    var proc = System.Diagnostics.Process.GetCurrentProcess();
                    proc.Refresh();
                    var cpu0 = proc.TotalProcessorTime; var sw = System.Diagnostics.Stopwatch.StartNew();
                    int g0 = GC.CollectionCount(0), g1 = GC.CollectionCount(1), g2 = GC.CollectionCount(2);
                    long alloc0 = GC.GetTotalAllocatedBytes();
                    var lags = new List<double>();
                    while (sw.Elapsed.TotalSeconds < secs)
                    {
                        var posted = System.Diagnostics.Stopwatch.StartNew();
                        await Dispatcher.UIThread.InvokeAsync(() => { }, DispatcherPriority.Input);
                        lags.Add(posted.Elapsed.TotalMilliseconds);
                        await Task.Delay(50);
                    }
                    proc.Refresh();
                    double cpu = (proc.TotalProcessorTime - cpu0).TotalSeconds / sw.Elapsed.TotalSeconds * 100;
                    lags.Sort();
                    report.Add($"perf {what}: CPU {cpu:0}% of one core, working set {proc.WorkingSet64 / 1048576.0:0} MB, private {proc.PrivateMemorySize64 / 1048576.0:0} MB, " +
                               $"managed heap {GC.GetTotalMemory(false) / 1048576.0:0} MB, allocated {(GC.GetTotalAllocatedBytes() - alloc0) / 1048576.0 / sw.Elapsed.TotalSeconds:0.0} MB/s, " +
                               $"GCs {GC.CollectionCount(0) - g0}/{GC.CollectionCount(1) - g1}/{GC.CollectionCount(2) - g2}, " +
                               $"UI lag median {lags[lags.Count / 2]:0.0} ms, 95% {lags[(int)(lags.Count * 0.95)]:0.0} ms, max {lags[^1]:0.0} ms");
                }
                foreach (var low in new[] { false, true })
                {
                    Perf.Set(low);
                    string m = low ? " [low performance]" : "";
                    main.TunerMode(true);
                    for (int k = 0; k < 6; k++) await Settle();
                    await Measure("tuner idle" + m);
                    main.DatalogPanel.LoadFrames(frames, "perf log");
                    main.DatalogPanel.PlayForCheck();
                    await Measure("tuner replay 1x" + m);
                    main.DatalogPanel.StopPlayback();
                    main.TunerMode(false);
                }
                Perf.Set(false);
                for (int k = 0; k < 6; k++) await Settle();
                main.ShowTab("Calibration");
                main.Host.Control("run");
                await Measure("simulator running (Calibration page)");
                main.ShowTab("Trace");
                await Measure("simulator running (Trace page)");
                main.Host.Control("pause");
                await Measure("simulator paused");
            }
            // OKIROM_UICHECK_PROJECT=1: what is on screen saved to a project, everything cleared away, the project opened: it all comes back
            if (Environment.GetEnvironmentVariable("OKIROM_UICHECK_PROJECT") == "1")
            {
                main.Host.SetInput("rpm", 3000);
                main.Host.Control("run"); for (int k = 0; k < 10; k++) await Settle(); main.Host.Control("pause");
                main.Host.HoldRam(0x1F0, [0x5A]);
                main.Host.AddBreakpoint("7FF0"); main.Host.SetBreakpointEnabled(0x7FF0, false);
                main.Host.AddBreakpoint("7FE0");
                main.TracePanel.HitMode = true;
                var frames = Enumerable.Range(0, 300).Select(k => new OkiRomSim.Calibration.LogFrame { T = k * 0.05, Rpm = 1000 + (k * 10), MapKpa = 50, Raw = [(byte)k, 1, 2] }).ToList();
                main.DatalogPanel.RestoreLog(frames, "check log", 123);
                main.TunerMode(true); await Settle();
                main.CalibrationPanel.RestoreView("FuelHigh", 1); await Settle();
                var before = main.Host.State();
                var path = Path.Combine(dir, "check.project.zip");
                main.SaveProjectTo(path);
                // everything away: another state altogether
                main.TunerMode(false);
                main.TracePanel.HitMode = false;
                main.Host.HoldRam(0x1F0, null); main.Host.ClearBreakpoints(); main.Host.Control("reset");
                main.DatalogPanel.ClearAll();
                await Settle();
                main.OpenProjectFrom(path);
                for (int k = 0; k < 6; k++) await Settle();
                var after = main.Host.State();
                var (logFrames, logName, logPos) = main.DatalogPanel.SavedLog();
                void Is(bool ok, string what) => report.Add($"project {(ok ? "PASS" : "FAIL")} {what}");
                Is(after.Pc == before.Pc && after.Instructions == before.Instructions, $"the machine: PC {before.Pc:X4}/{after.Pc:X4}, {before.Instructions}/{after.Instructions} instructions");
                Is(main.Host.IsHeld(0x1F0) && main.Host.ReadMemory(0x1F0, 1)[0] == 0x5A, "the held RAM byte");
                Is(after.Breakpoints.Count == 2 && after.Breakpoints.Any(b => b.Address == 0x7FF0 && !b.Enabled) && after.Breakpoints.Any(b => b.Address == 0x7FE0 && b.Enabled), "the breakpoints, one of them off");
                Is(main.TracePanel.HitMode, "Hit trace ticked");
                Is(main.InTuner, "Tuner mode");
                Is(main.CalibrationPanel.ViewState == ("FuelHigh", 1), $"the table and its view: {main.CalibrationPanel.ViewState}");
                Is(logFrames.Count == 300 && logPos == 123 && logName == "check log" && logFrames[200].Rpm == 3000 && logFrames[7].Raw?[0] == 7, $"the datalog: {logFrames.Count} frames, at {logPos}, '{logName}'");
                main.TunerMode(false);
            }
            // OKIROM_UICHECK_WIDGETS=1: a widget parented to the main window must still be there after the window is minimized and brought back maximized (it used to go off the screen, or behind the window)
            if (Environment.GetEnvironmentVariable("OKIROM_UICHECK_WIDGETS") == "1")
            {
                var gauges = main.DatalogPanel.Gauges;
                var layout = gauges.Layout;
                layout.Widgets = [new GaugeWidget { Gauges = [new GaugeSpec { Width = 260, Height = 160 }], X = 120, Y = 140, Width = 280, Height = 200, Parented = true }];
                gauges.Apply(layout);
                main.WindowState = WindowState.Normal; main.Width = 1400; main.Height = 900;
                for (int k = 0; k < 4; k++) await Settle();
                string Where() => string.Join("; ", GaugeWindows().Select(w => $"visible {w.IsVisible}, owner {(w.Owner == main ? "main" : w.Owner == null ? "none" : "other")}, at {w.Position}"));
                report.Add("widget before: " + Where());
                foreach (var (from, to) in new[] { (WindowState.Normal, WindowState.Maximized), (WindowState.Maximized, WindowState.Maximized), (WindowState.Maximized, WindowState.Normal) })
                {
                    main.WindowState = from; for (int k = 0; k < 3; k++) await Settle();
                    main.WindowState = WindowState.Minimized; for (int k = 0; k < 4; k++) await Settle();
                    main.WindowState = to; for (int k = 0; k < 8; k++) await Settle();
                    var tl = main.PointToScreen(new Point(0, 0));
                    var mainRect = new PixelRect(tl, new PixelSize((int)(main.Bounds.Width * main.RenderScaling), (int)(main.Bounds.Height * main.RenderScaling)));
                    bool ok = GaugeWindows().Any() && GaugeWindows().All(w => w.IsVisible && w.Owner == main && mainRect.Intersects(new PixelRect(w.Position, w.PixelSize)));
                    report.Add($"widget {(ok ? "PASS" : "FAIL")} after {from} -> minimized -> {to}: {Where()} (main at {mainRect})");
                }
                gauges.CloseWidgets();
            }
            // OKIROM_UICHECK_ONLY=chip: the pinout with the 8255 tucked away (the tab on the processor), then shown with its traces
            if (only != null && Wanted("chip"))
            {
                main.WindowState = WindowState.Maximized;
                main.TunerMode(false);
                main.ChipForCheck.ShowPpiForCheck(false); await Settle();
                Check(main, "chip 8255 hidden", dir, report);
                main.ChipForCheck.ShowPpiForCheck(true); await Settle();
                Check(main, "chip 8255 shown", dir, report);
                main.ChipForCheck.ShowPpiForCheck(false);
            }
            // the window as the app opens it on this screen (fitted to it, maximized), then at a 1366 x 768 laptop's size
            foreach (var (w, h) in new[] { (0, 0), (1366, 768), (2560, 1400) })
            {
                if (!Wanted("main")) break;
                // the simulator's own layout first, whatever the settings opened the app in
                main.TunerMode(false);
                if (w == 0) main.WindowState = WindowState.Maximized;
                else { main.WindowState = WindowState.Normal; main.Width = w; main.Height = h; }
                await Settle();
                string size = $"{main.Bounds.Width:0}x{main.Bounds.Height:0}";
                foreach (var tab in main.TabNames())
                {
                    main.ShowTab(tab);
                    await Settle();
                    Check(main, $"main {size} {tab}", dir, report);
                }
                // Tuner mode: the calibration editor's menus on the File line, the datalog beside it
                main.TunerMode(true);
                await Settle();
                Check(main, $"main {size} tuner mode", dir, report);
                // a log replaying over the map: the cells the engine reads lit, the trail behind it
                if (Environment.GetEnvironmentVariable("OKIROM_UICHECK_REPLAY") == "1")
                {
                    var frames = Enumerable.Range(0, 400).Select(k => new OkiRomSim.Calibration.LogFrame
                    {
                        T = k * 0.05, Rpm = 1500 + (k * 12), MapKpa = 40 + (30 * Math.Sin(k * 0.05)), TpsPct = 20, EctC = 85, IatC = 25,
                    }).ToList();
                    main.DatalogPanel.LoadFrames(frames, "made-up climb");
                    main.DatalogPanel.PlayForCheck();
                    for (int k = 0; k < 14; k++) await Settle();
                    Check(main, $"main {size} tuner mode replay", dir, report);
                    main.DatalogPanel.StopPlayback();
                }
                // the Definition form opened under the map
                var expanders = main.GetVisualDescendants().OfType<Expander>().Where(x => x.IsEffectivelyVisible).ToList();
                foreach (var x in expanders) x.IsExpanded = true;
                await Settle();
                Check(main, $"main {size} tuner mode definition", dir, report);
                foreach (var x in expanders) x.IsExpanded = false;
                await Settle();
                // and for a finger: touch screen mode
                TouchMode.Set(true);
                await Settle();
                Check(main, $"main {size} tuner mode touch", dir, report);
                TouchMode.Set(false);
                await Settle();
                main.TunerMode(false);
                await Settle();
            }

            var host = main.Host;
            var windows = new List<(string Name, Func<Window> Make)>
            {
                ("welcome", () => new WelcomeWindow()),
                ("settings", () => new SettingsWindow(AppSettings.Load(), () => "off", ProcessorProfile.Current)),
                ("settings units", () => { var w = new SettingsWindow(AppSettings.Load(), () => "off", ProcessorProfile.Current); w.ShowPage("Units"); return w; }),
                ("settings dyno", () => { var w = new SettingsWindow(AppSettings.Load(), () => "off", ProcessorProfile.Current); w.ShowPage("Dyno"); return w; }),
                ("virtual dyno imperial", () => { OkiRomSim.Calibration.Units.Now = OkiRomSim.Calibration.UnitSettings.ImperialUs(); var w = new DynoWindow(main.DatalogPanel); w.ForCheck(); w.Closed += (_, _) => OkiRomSim.Calibration.Units.Now = new(); return w; }),
                ("gauge editor", () => new GaugeEditor(new GaugeSpec { Width = 900, Height = 160 }, ["rpm", "map_kpa"])),
                ("scale", () => new ScaleWindow(host, host.Defs().Items.FirstOrDefault(i => i.IsTable && i.ColumnScaleAddress != null))),
                ("compare", () => new CompareWindow(() => null, "some-rom-with-a-long-name.asm")),
                ("check engine", () => new MilWindow(host, _ => { })),
                ("new rom", () => new NewRomWindow()),
                ("new rom create", () => { var w = new NewRomWindow(); w.ShowCreate(); w.ForCheck(); return w; }),
                ("new rom default", () => { var w = new NewRomWindow(); w.ShowCreate(); w.PickDefault(); return w; }),
                ("change functions", () => new NewRomWindow(new NewRomWindow.ChangeRequest(Skeleton.Find(NewRomWindow.Templates()).First(),
                    [.. SkeletonPresets.Default], @"D:\Tunes\p30-custom.asm", true, "p30-custom.asm"))),
                ("setup wizard 1", () => new SetupWizardWindow(host)),
                ("setup wizard 2", () => { var w = new SetupWizardWindow(host); w.ShowPage(1); return w; }),
                ("setup wizard 3", () => { var w = new SetupWizardWindow(host); w.ShowPage(2); return w; }),
                ("setup wizard 4", () => { var w = new SetupWizardWindow(host); w.ShowPage(3); return w; }),
                ("setup wizard 5", () => { var w = new SetupWizardWindow(host); w.ShowPage(4); return w; }),
                ("setup wizard 6", () => { var w = new SetupWizardWindow(host); w.ShowPage(5); return w; }),
                ("virtual dyno", () => { var w = new DynoWindow(main.DatalogPanel); w.ForCheck(); return w; }),
                ("virtual dyno triggers", () => { var w = new DynoWindow(main.DatalogPanel); w.ForCheck(); w.ShowTriggers(); return w; }),
                ("feature patches", () => new FeaturePatchWindow(host)),
                ("injectors", () => new InjectorWindow(host)),
                ("map sensor", () => new MapSensorWindow(host)),
                ("o2 knock tables", () => new LogTableWindow(host, () => [], null)),
                ("datalog graph", () => new DatalogGraphWindow(() => [], _ => { })),
                ("import maps", () =>
                {
                    var w = new ImportMapsWindow(host, null);
                    if (Environment.GetEnvironmentVariable("OKIROM_IMPORT_SOURCE") is { Length: > 0 } src) _ = w.OpenPath(src);
                    return w;
                }),
                ("codes and service", () => new ServiceWindow(main.DatalogPanel.Engine, host)),
                ("datalog channels", () => new DatalogChannelsWindow(DatalogChannels.Defaults, ["4|afr|10|0|1"], null, ["rpm", "map_kpa", "afr", "lambda"])),
                ("demon onboard", () => new OnboardWindow(host, main.DatalogPanel, null)),
                ("updates", () => new UpdatesWindow(Environment.GetEnvironmentVariable("OKIROM_UPDATE_SITE") ?? Updater.DefaultSite)),
                ("line view", () => new Window { Width = 1000, Height = 560, Content = new TableGraph { Model = SampleMap() } }),
            };
            // the virtual dyno driven as a user would: the Start button, the hotkey, auto start
            if (Wanted("dyno run"))
            {
                var dw = new DynoWindow(main.DatalogPanel);
                dw.Show(main);
                await Settle();
                report.Add("dyno run: " + await dw.SelfTest());
                dw.Close();
            }
            foreach (var (name, make) in windows)
            {
                if (!Wanted(name)) continue;
                foreach (var small in new[] { false, true })
                {
                    Window win;
                    try { win = make(); }
                    catch (Exception ex) { report.Add($"{name}: could not open: {ex.Message}"); break; }
                    win.WindowStartupLocation = WindowStartupLocation.CenterScreen;
                    win.Show(main);
                    await Settle();
                    // reading another ROM takes a few seconds
                    if (name == "import maps") for (int k = 0; k < 40 && win.IsVisible; k++) await Settle();
                    // the pick's interrupt time is measured in the simulator in the background (a second or two)
                    if (name is "new rom create" or "new rom default") { await Task.Delay(7000); await Settle(); }
                    // the smallest the window lets itself be made
                    if (small && win.CanResize) { win.Width = Math.Max(win.MinWidth, 200); win.Height = Math.Max(win.MinHeight, 200); await Settle(); }
                    string label = $"{name}{(small ? " (smallest)" : "")}";
                    Check(win, label, dir, report);
                    // every page of a window with tabs
                    foreach (var tabs in win.GetVisualDescendants().OfType<TabControl>().ToList())
                        for (int i = 1; i < tabs.ItemCount; i++)
                        {
                            tabs.SelectedIndex = i;
                            await Settle();
                            Check(win, $"{label} tab {(tabs.SelectedItem as TabItem)?.Tag ?? i}", dir, report);
                        }
                    win.Close();
                }
            }
        }
        catch (Exception ex) { report.Add("check failed: " + ex); }
        File.WriteAllLines(Path.Combine(dir, "report.txt"), report.Count == 0 ? ["no problems found"] : report);
        // in another language: the English text seen with no translation, for filling the gaps
        if (Lang.Current != "en") try { Lang.WriteMissing(dir); } catch { }
        (Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.Shutdown();
    }

    /// A made-up fuel-map shape for the Line view's picture, with the engine sat between two rows.
    static TableModel SampleMap()
    {
        const int rows = 10, cols = 12;
        var v = new double[rows * cols];
        for (int r = 0; r < rows; r++)
            for (int c = 0; c < cols; c++)
                v[(r * cols) + c] = 2 + (c * 0.9) + (r * 0.35) + (Math.Sin((c + r) * 0.6) * 0.4);
        return new TableModel
        {
            Item = new OkiRomSim.Calibration.ItemDef { Name = "sample", Rows = rows, Cols = cols }, Rows = rows, Cols = cols, Values = v, Raw = [.. v],
            RowAxis = [.. Enumerable.Range(0, rows).Select(r => 800.0 + (r * 800))], ColAxis = [.. Enumerable.Range(0, cols).Select(c => 20.0 + (c * 8))],
            RowUnit = "rpm", ColUnit = "kPa", Unit = "ms", ExternalTrace = (4.4, 6.3),
        };
    }

    static IEnumerable<GaugeWindow> GaugeWindows() =>
        (Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.Windows.OfType<GaugeWindow>() ?? [];

    static async Task Settle()
    {
        for (int i = 0; i < 4; i++)
        {
            await Dispatcher.UIThread.InvokeAsync(() => { }, DispatcherPriority.Background);
            await Task.Delay(120);
        }
    }

    static void Check(Window win, string label, string dir, List<string> report)
    {
        var file = string.Concat(label.Select(ch => char.IsLetterOrDigit(ch) ? ch : '_'));
        try
        {
            var size = new PixelSize(Math.Max(1, (int)win.Bounds.Width), Math.Max(1, (int)win.Bounds.Height));
            using var bmp = new RenderTargetBitmap(size);
            bmp.Render(win);
            bmp.Save(Path.Combine(dir, file + ".png"));
        }
        catch (Exception ex) { report.Add($"{label}: picture failed: {ex.Message}"); }

        var inputs = win.GetVisualDescendants().OfType<Control>()
            .Where(c => c is TextBox or ComboBox or NumericUpDown or Button or CheckBox or Slider or RadioButton or ListBox)
            .Where(c => c.IsEffectivelyVisible && c.Bounds.Width > 0 && c.Bounds.Height > 0)
            // parts of another input (a NumericUpDown's own box and buttons, a ComboBox's) are checked with it
            .Where(c => !c.GetVisualAncestors().Any(a => a is TextBox or ComboBox or NumericUpDown or Avalonia.Controls.Primitives.ScrollBar or Slider))
            .ToList();
        var texts = win.GetVisualDescendants().OfType<TextBlock>()
            .Where(t => t.IsEffectivelyVisible && !string.IsNullOrWhiteSpace(t.Text) && t.Bounds.Width > 0)
            .Where(t => !t.GetVisualAncestors().Any(a => a is TextBox or ComboBox or NumericUpDown or Button or CheckBox or RadioButton or ListBox or ToolTip or TabItem))
            .ToList();
        var client = new Rect(win.Bounds.Size);
        int problems = 0;
        foreach (var c in inputs)
        {
            if (c.TransformToVisual(win) is not { } m) continue;
            var r = new Rect(c.Bounds.Size).TransformToAABB(m);
            string what = Describe(c);
            // off the window altogether
            if (r.Right > client.Right + 1 || r.Bottom > client.Bottom + 1 || r.X < -1)
            {
                // below the fold of a page that scrolls is fine; off the side of one that cannot scroll is not
                var sv = c.GetVisualAncestors().OfType<ScrollViewer>().FirstOrDefault();
                bool scrollsDown = sv != null && sv.VerticalScrollBarVisibility != Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled;
                bool scrollsAcross = sv != null && sv.HorizontalScrollBarVisibility != Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled;
                bool sideways = r.Right > client.Right + 1 || r.X < -1;
                if ((sideways && !scrollsAcross) || (!sideways && !scrollsDown))
                { report.Add($"{label}: {what} is off the window ({Fmt(r)} in {Fmt(client)})"); problems++; continue; }
            }
            // clipped by a panel it sits in (cut off at the side)
            foreach (var a in c.GetVisualAncestors().OfType<Control>())
            {
                if (a is ScrollContentPresenter || !a.ClipToBounds || a.TransformToVisual(win) is not { } am) continue;
                var ar = new Rect(a.Bounds.Size).TransformToAABB(am);
                if (r.Right > ar.Right + 2 && r.X < ar.Right - 2 && a.GetVisualAncestors().OfType<ScrollViewer>().FirstOrDefault()?.HorizontalScrollBarVisibility is not Avalonia.Controls.Primitives.ScrollBarVisibility.Auto)
                { report.Add($"{label}: {what} is cut off at the side by {a.GetType().Name} ({Fmt(r)} past {ar.Right:0})"); problems++; break; }
            }
            // lying over text: only the part of the input on screen (one scrolled half out of a list is cut off at its edge)
            foreach (var a in c.GetVisualAncestors().OfType<Control>())
                if (a is ScrollContentPresenter && a.TransformToVisual(win) is { } sm)
                    r = r.Intersect(new Rect(a.Bounds.Size).TransformToAABB(sm));
            foreach (var t in texts)
            {
                if (t.TransformToVisual(win) is not { } tm) continue;
                var tr = new Rect(t.Bounds.Size).TransformToAABB(tm);
                // only the part of the text that is actually on screen (a scrolled box clips the rest away)
                foreach (var a in t.GetVisualAncestors().OfType<Control>())
                    if ((a.ClipToBounds || a is ScrollContentPresenter) && a.TransformToVisual(win) is { } cm)
                        tr = tr.Intersect(new Rect(a.Bounds.Size).TransformToAABB(cm));
                var both = r.Intersect(tr);
                if (both.Width > 4 && both.Height > 4)
                { report.Add($"{label}: {what} covers the text \"{Short(t.Text!)}\""); problems++; }
            }
        }
        report.Add($"-- {label}: {inputs.Count} inputs, {problems} problem(s)");
    }

    static string Describe(Control c) => c switch
    {
        CheckBox k => $"check box \"{Short(k.Content?.ToString() ?? "")}\"",
        Button b => $"button \"{Short(b.Content?.ToString() ?? "")}\"",
        TextBox t => $"text box \"{Short(t.Text ?? t.Watermark ?? "")}\"",
        _ => c.GetType().Name + (ToolTip.GetTip(c) is string tip ? $" ({Short(tip)})" : ""),
    };

    static string Short(string s) => s.Length > 40 ? s[..40] + "…" : s.Replace('\n', ' ');
    static string Fmt(Rect r) => $"{r.X:0},{r.Y:0} {r.Width:0}x{r.Height:0}";
}
