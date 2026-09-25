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

/// `OkiRomSimStudio --ui-check <folder>`: opens every window and page at 1920 x 1080 and 1366 x 768, saves a picture of each, and lists every input that is off the window, clipped by the panel it sits in, or lying over a piece of text - the "the box covers its label" and "I have to stretch the window to see the inputs" kind of fault. Writes report.txt to the folder, then quits.
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
            await Settle();
            // the window as the app opens it on this screen (fitted to it, maximized), then at a 1366 x 768 laptop's size
            foreach (var (w, h) in new[] { (0, 0), (1366, 768) })
            {
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
            }

            var host = main.Host;
            var windows = new List<(string Name, Func<Window> Make)>
            {
                ("settings", () => new SettingsWindow(AppSettings.Load(), () => "off", ProcessorProfile.Current)),
                ("gauge editor", () => new GaugeEditor(new GaugeSpec { Width = 900, Height = 160 }, ["rpm", "map_kpa"])),
                ("scale", () => new ScaleWindow(host, host.Defs().Items.FirstOrDefault(i => i.IsTable && i.ColumnScaleAddress != null))),
                ("compare", () => new CompareWindow(() => null, "some-rom-with-a-long-name.asm")),
                ("check engine", () => new MilWindow(host, _ => { })),
                ("new rom", () => new NewRomWindow()),
                ("feature patches", () => new FeaturePatchWindow(host)),
                ("injectors", () => new InjectorWindow(host)),
                ("map sensor", () => new MapSensorWindow(host)),
                ("o2 knock tables", () => new LogTableWindow(host, () => [], null)),
                ("datalog graph", () => new DatalogGraphWindow(() => [], _ => { })),
            };
            foreach (var (name, make) in windows)
            {
                foreach (var small in new[] { false, true })
                {
                    Window win;
                    try { win = make(); }
                    catch (Exception ex) { report.Add($"{name}: could not open: {ex.Message}"); break; }
                    win.WindowStartupLocation = WindowStartupLocation.CenterScreen;
                    win.Show(main);
                    await Settle();
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
        (Application.Current?.ApplicationLifetime as Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.Shutdown();
    }

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
            // lying over text
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
