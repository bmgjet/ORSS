// Copyright (c) bmgjet. All rights reserved.
using System.Diagnostics;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Controls.Documents;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Updates from the website: the program itself and its templates. The site lists every file it has (index.php?updates: path, size, SHA-256, a version number of its own that goes up whenever the file changes, and the file version of a .dll / .exe); the ones that differ from the files beside the app are offered, with what changed, and nothing is downloaded until it is asked for. A replaced template keeps a .bak of the old one; the program's own files are moved aside (.old, cleared at the next start) because a running program cannot be written over, and a restart puts the new one in use.
public static class Updater
{
    static readonly JsonSerializerOptions Indented = new() { WriteIndented = true };
    public const string DefaultSite = "https://romsimstudio.com/";

    public sealed class ServerFile
    {
        [JsonPropertyName("path")] public string Path { get; set; } = "";
        [JsonPropertyName("size")] public long Size { get; set; }
        [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";
        [JsonPropertyName("version")] public int Version { get; set; }
        [JsonPropertyName("changed")] public DateTime Changed { get; set; }
        [JsonPropertyName("fileVersion")] public string? FileVersion { get; set; }
        [JsonPropertyName("text")] public bool Text { get; set; }
    }

    sealed class Manifest
    {
        [JsonPropertyName("files")] public List<ServerFile> Files { get; set; } = [];
    }

    /// One file that differs from the site's.
    public sealed class Change
    {
        public required ServerFile Server { get; init; }
        public required string LocalPath { get; init; }
        public bool Exists { get; init; }
        public string? LocalSha { get; init; }
        public string? LocalVersion { get; init; }
        /// Offered ticked: an ordinary update. Unticked: yours looks newer, or was edited here, or is a developer build.
        public bool Recommended { get; init; }
        /// What is different, in a line.
        public required string Why { get; init; }
        /// The program itself (a .dll or .exe): takes a restart.
        public bool NeedsRestart => IsProgram(Server.Path);
    }

    static readonly HttpClient Http = MakeClient();

    static HttpClient MakeClient()
    {
        var h = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        h.DefaultRequestHeaders.UserAgent.ParseAdd($"RomSimStudio/{BuildInfo.Version}");
        return h;
    }

    static string Site(string site) => site.Trim().TrimEnd('/') + "/";
    static string ManifestUrl(string site) => Site(site) + "index.php?updates";
    static string FileUrl(string site, string path) => Site(site) + "index.php?file=" + Uri.EscapeDataString(path);

    /// Where the app's own files are (the program, Templates...).
    public static string Home => AppContext.BaseDirectory;

    static bool IsProgram(string path) =>
        !path.Contains('/') && (path.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase));

    /// A build run from its build folder (the libraries beside it, listed in a .deps.json) rather than the distributed one: its program files are the developer's to replace, by building.
    static bool DeveloperBuild => File.Exists(Path.Combine(Home, "RomSimStudio.deps.json"));

    // ---- what was installed from the site, so a file edited here since can be told apart from an old one

    static string RecordPath => Path.Combine(AppSettings.Dir, "updates.json");

    static Dictionary<string, string> Installed()
    {
        try { return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(RecordPath)) ?? []; }
        catch { return []; }
    }

    static void Remember(string path, string sha)
    {
        var d = Installed();
        d[path] = sha;
        try { Directory.CreateDirectory(AppSettings.Dir); SafeFile.WriteAllText(RecordPath, JsonSerializer.Serialize(d, Indented)); }
        catch (Exception ex) { AppLog.Warn("updates", "could not remember what was installed: " + ex.Message); }
    }

    static string Sha(string file)
    {
        using var s = File.OpenRead(file);
        return Convert.ToHexStringLower(SHA256.HashData(s));
    }

    static Version? V(string? text) => Version.TryParse(text, out var v) ? v : null;

    /// Ask the site what it has, and compare it with the files here: the ones that differ.
    public static async Task<List<Change>> Check(string site, CancellationToken cancel = default)
    {
        var json = await Http.GetStringAsync(ManifestUrl(site), cancel);
        var manifest = JsonSerializer.Deserialize<Manifest>(json) ?? new Manifest();
        var installed = Installed();
        var list = new List<Change>();
        foreach (var f in manifest.Files)
        {
            if (f.Path.Length == 0 || f.Path.Contains("..") || Path.IsPathRooted(f.Path)) continue;
            // a Windows program file is no use elsewhere
            if (!OperatingSystem.IsWindows() && f.Path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) continue;
            var local = Path.GetFullPath(Path.Combine(Home, f.Path));
            if (!local.StartsWith(Path.TrimEndingDirectorySeparator(Path.GetFullPath(Home)) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) continue;   // (with the separator: C:\App2 is not inside C:\App)
            bool exists = File.Exists(local);
            // something new at the top (beside the program) that this install does not have is for another kind of install
            if (!exists && !f.Path.Contains('/')) continue;
            string? sha = exists ? await Task.Run(() => Sha(local), cancel) : null;
            if (sha != null && sha.Equals(f.Sha256, StringComparison.OrdinalIgnoreCase)) continue;
            string? localVersion = exists && IsProgram(f.Path) ? FileVersionInfo.GetVersionInfo(local).FileVersion : null;

            bool recommended = true;
            string why;
            if (!exists) why = "new: not here yet";
            else if (IsProgram(f.Path))
            {
                var here = V(localVersion); var there = V(f.FileVersion);
                why = here != null && there != null && here != there ? $"version {here} here, {there} on the site" : $"a newer build of version {f.FileVersion ?? "?"}";
                if (here != null && there != null && here > there) { recommended = false; why = $"yours is newer ({here}; the site has {there})"; }
                if (DeveloperBuild) { recommended = false; why += " - this is a developer build (its libraries sit beside it): build it rather than replace it"; }
            }
            else if (installed.TryGetValue(f.Path, out var was) && !was.Equals(sha, StringComparison.OrdinalIgnoreCase))
            {
                recommended = false;
                why = "changed on the site, and edited here since it was installed (replacing it keeps yours as .bak)";
            }
            else why = "changed on the site";
            list.Add(new Change
            {
                Server = f, LocalPath = local, Exists = exists, LocalSha = sha, LocalVersion = localVersion,
                Recommended = recommended, Why = why,
            });
        }
        AppLog.Info("updates", $"checked {Site(site)}: {manifest.Files.Count} files there, {list.Count} differ from here");
        return list;
    }

    /// The site's copy of a text file, to show what changed (nothing is written).
    public static async Task<string> Fetch(string site, ServerFile f, CancellationToken cancel = default)
    {
        var bytes = await Http.GetByteArrayAsync(FileUrl(site, f.Path), cancel);
        return System.Text.Encoding.UTF8.GetString(bytes);
    }

    /// Download one file, check it is exactly what the site listed, and put it in place.
    public static async Task Install(string site, Change c, IProgress<double>? progress = null, CancellationToken cancel = default)
    {
        var dir = Path.GetDirectoryName(c.LocalPath)!;
        Directory.CreateDirectory(dir);
        var temp = c.LocalPath + ".download";
        using (var resp = await Http.GetAsync(FileUrl(site, c.Server.Path), HttpCompletionOption.ResponseHeadersRead, cancel))
        {
            resp.EnsureSuccessStatusCode();
            long total = resp.Content.Headers.ContentLength ?? c.Server.Size;
            await using var src = await resp.Content.ReadAsStreamAsync(cancel);
            await using var dst = File.Create(temp);
            var buf = new byte[81920];
            long got = 0;
            int n;
            while ((n = await src.ReadAsync(buf, cancel)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n), cancel);
                got += n;
                if (total > 0) progress?.Report((double)got / total);
            }
        }
        var sha = Sha(temp);
        if (!sha.Equals(c.Server.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            try { File.Delete(temp); } catch { }
            throw new IOException($"{c.Server.Path} did not arrive intact (its SHA-256 does not match the site's list); nothing was changed");
        }
        bool movedAside = false;
        if (c.Exists)
        {
            // the program is running from its files: moved aside (allowed while running), then the new one takes its place
            if (c.NeedsRestart) { File.Move(c.LocalPath, c.LocalPath + ".old", overwrite: true); movedAside = true; }
            else File.Copy(c.LocalPath, c.LocalPath + ".bak", overwrite: true);
        }
        try { File.Move(temp, c.LocalPath, overwrite: true); }
        catch
        {
            // the new file could not take its place (a lock, a full disk): put the old program file back, or the program would have none to start from
            if (movedAside) try { File.Move(c.LocalPath + ".old", c.LocalPath, overwrite: true); } catch { }
            try { File.Delete(temp); } catch { }
            throw;
        }
        Remember(c.Server.Path, sha);
        AppLog.Action("updates", $"installed {c.Server.Path} (site version {c.Server.Version}{(c.Server.FileVersion != null ? ", " + c.Server.FileVersion : "")})");
    }

    /// The program files moved aside by the last update: gone once the new ones are running.
    public static void ClearOld()
    {
        try
        {
            foreach (var f in Directory.GetFiles(Home, "*.old"))
                try { File.Delete(f); } catch { /* still in use: next time */ }
            foreach (var f in Directory.GetFiles(Home, "*.download", SearchOption.AllDirectories))
                try { File.Delete(f); } catch { }
        }
        catch { }
    }

    /// Start the program again (the new files) and close this one.
    public static void Restart(Window main)
    {
        var exe = Environment.ProcessPath;
        if (exe == null) return;
        var start = Path.GetFileNameWithoutExtension(exe).Equals("dotnet", StringComparison.OrdinalIgnoreCase)
            ? new ProcessStartInfo(exe) { ArgumentList = { Path.Combine(Home, "RomSimStudio.dll") } }
            : new ProcessStartInfo(exe);
        start.UseShellExecute = false;
        start.WorkingDirectory = Environment.CurrentDirectory;
        main.Closed += (_, _) =>
        {
            try { Process.Start(start); } catch (Exception ex) { AppLog.Error("updates", "could not start the program again", ex); }
        };
        main.Close();
    }

    public static string Size(long bytes) => bytes >= 1 << 20 ? $"{bytes / 1048576.0:0.0} MB" : bytes >= 1024 ? $"{bytes / 1024.0:0} KB" : $"{bytes} bytes";
}

/// Line differences between two texts, as unified-diff hunks (Myers' algorithm, with the common start and end taken off first so a small change to a big template stays quick).
public static class LineDiff
{
    public enum Kind { Same, Removed, Added, Hunk }
    public sealed record Line(Kind Kind, string Text);

    static string[] Lines(string s) => s.Replace("\r\n", "\n").Replace('\r', '\n').TrimEnd('\n').Split('\n');

    /// The hunks (3 lines of context), and how many lines went and came; null when the two are too different to list line by line in reasonable time.
    public static (List<Line> Hunks, int Removed, int Added)? Compare(string before, string after, int context = 3)
    {
        var a = Lines(before); var b = Lines(after);
        var ops = Ops(a, b);
        if (ops == null) return null;
        int removed = ops.Count(o => o.Kind == Kind.Removed), added = ops.Count(o => o.Kind == Kind.Added);
        // hunks: every change with `context` unchanged lines either side
        var outList = new List<Line>();
        int i = 0, lineA = 1, lineB = 1;
        var pos = new List<(int A, int B)>();
        foreach (var o in ops) { pos.Add((lineA, lineB)); if (o.Kind != Kind.Added) lineA++; if (o.Kind != Kind.Removed) lineB++; }
        while (i < ops.Count)
        {
            if (ops[i].Kind == Kind.Same) { i++; continue; }
            int start = Math.Max(0, i - context), end = i;
            // run on while the next change is close enough to share the context
            while (true)
            {
                while (end < ops.Count && ops[end].Kind != Kind.Same) end++;
                int next = end;
                while (next < ops.Count && ops[next].Kind == Kind.Same && next - end < context * 2) next++;
                if (next < ops.Count && ops[next].Kind != Kind.Same) { end = next; continue; }
                end = Math.Min(ops.Count, end + context);
                break;
            }
            int na = ops.Skip(start).Take(end - start).Count(o => o.Kind != Kind.Added), nb = ops.Skip(start).Take(end - start).Count(o => o.Kind != Kind.Removed);
            outList.Add(new Line(Kind.Hunk, $"@@ -{pos[start].A},{na} +{pos[start].B},{nb} @@"));
            for (int k = start; k < end; k++) outList.Add(ops[k]);
            i = end;
        }
        return (outList, removed, added);
    }

    const int MaxD = 4000;

    static List<Line>? Ops(string[] a, string[] b)
    {
        int pre = 0;
        while (pre < a.Length && pre < b.Length && a[pre] == b[pre]) pre++;
        int suf = 0;
        while (suf < a.Length - pre && suf < b.Length - pre && a[a.Length - 1 - suf] == b[b.Length - 1 - suf]) suf++;
        var A = a[pre..(a.Length - suf)]; var B = b[pre..(b.Length - suf)];
        int n = A.Length, m = B.Length, max = n + m;
        var mid = new List<Line>();
        if (max > 0)
        {
            int off = max + 1;
            var v = new int[(2 * max) + 3];
            var trace = new List<int[]>();
            int found = -1;
            for (int d = 0; d <= max && found < 0; d++)
            {
                if (d > MaxD) return null;
                // what this step starts from, for the walk back: v[k] for k in -d-1..d+1
                trace.Add(v[(off - d - 1)..(off + d + 2)]);
                for (int k = -d; k <= d; k += 2)
                {
                    int x = k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) ? v[off + k + 1] : v[off + k - 1] + 1;
                    int y = x - k;
                    while (x < n && y < m && A[x] == B[y]) { x++; y++; }
                    v[off + k] = x;
                    if (x >= n && y >= m) { found = d; break; }
                }
            }
            // walk back from the end
            int cx = n, cy = m;
            var rev = new List<Line>();
            for (int d = found; d > 0; d--)
            {
                var pv = trace[d];
                int P(int k) => pv[k + d + 1];
                int k0 = cx - cy;
                int prevK = k0 == -d || (k0 != d && P(k0 - 1) < P(k0 + 1)) ? k0 + 1 : k0 - 1;
                int px = P(prevK), py = px - prevK;
                // the point just after the one edit: down (a line put in) or across (a line taken out)
                int mx = prevK == k0 + 1 ? px : px + 1, my = prevK == k0 + 1 ? py + 1 : py;
                while (cx > mx && cy > my) { rev.Add(new Line(Kind.Same, A[cx - 1])); cx--; cy--; }
                rev.Add(prevK == k0 + 1 ? new Line(Kind.Added, B[py]) : new Line(Kind.Removed, A[px]));
                cx = px; cy = py;
            }
            while (cx > 0 && cy > 0) { rev.Add(new Line(Kind.Same, A[cx - 1])); cx--; cy--; }
            rev.Reverse();
            mid = rev;
        }
        var all = new List<Line>(pre + mid.Count + suf);
        for (int i = 0; i < pre; i++) all.Add(new Line(Kind.Same, a[i]));
        all.AddRange(mid);
        for (int i = a.Length - suf; i < a.Length; i++) all.Add(new Line(Kind.Same, a[i]));
        return all;
    }
}

/// Settings > Updates > Check now: what differs from the site, what each change is, and a button to fetch the ones ticked.
public sealed class UpdatesWindow : Window
{
    readonly string _site;
    readonly StackPanel _list = new() { Spacing = 2 };
    readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(10, 6) };
    readonly SelectableTextBlock _detail = new() { FontFamily = MainWindow.MonoFont, FontSize = 11.5, TextWrapping = TextWrapping.NoWrap, Margin = new Thickness(8) };
    readonly Button _install = new() { Content = "Download and install…", IsEnabled = false, MinWidth = 150 };
    readonly Dictionary<Updater.Change, CheckBox> _ticks = [];
    readonly Dictionary<string, (List<LineDiff.Line> Hunks, int Removed, int Added)?> _diffs = [];
    CancellationTokenSource _cancel = new();

    static readonly IBrush Gone = AppTheme.Brush(Color.FromRgb(0xff, 0x8a, 0x80)), Came = AppTheme.Brush(Color.FromRgb(0x8c, 0xe0, 0x8c)),
                           HunkInk = AppTheme.Brush(Color.FromRgb(0x7f, 0xb8, 0xff)), SameInk = AppTheme.Brush(Color.FromRgb(0xa8, 0xad, 0xb6));

    public UpdatesWindow(string site)
    {
        _site = site;
        Title = "Updates";
        Width = 1000; Height = 640; MinWidth = 560; MinHeight = 340;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var chrome = DarkChrome.Apply(this, "Updates");

        var split = new Grid { ColumnDefinitions = new ColumnDefinitions("340,4,*"), Margin = new Thickness(8, 0) };
        var listScroll = new ScrollViewer { Content = _list };
        Grid.SetColumn(listScroll, 0); split.Children.Add(listScroll);
        var gs = new GridSplitter { Width = 4 }; Grid.SetColumn(gs, 1); split.Children.Add(gs);
        var detailScroll = new ScrollViewer
        {
            Content = _detail, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
            Background = AppTheme.Brush(Color.FromRgb(0x1a, 0x1b, 0x1f)),
        };
        Grid.SetColumn(detailScroll, 2); split.Children.Add(detailScroll);

        var again = new Button { Content = "Check again" };
        again.Click += (_, _) => _ = Run();
        var close = new Button { Content = "Close", IsCancel = true, MinWidth = 90 };
        close.Click += (_, _) => Close();
        _install.Click += (_, _) => _ = InstallTicked();
        ToolTip.SetTip(_install, "Download the ticked files, check each against the site's list, and put them in place (asks first).");
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 6, Margin = new Thickness(8) };
        buttons.Children.Add(again); buttons.Children.Add(_install); buttons.Children.Add(close);

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*,Auto") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(_status, 1); g.Children.Add(_status);
        Grid.SetRow(split, 2); g.Children.Add(split);
        Grid.SetRow(buttons, 3); g.Children.Add(buttons);
        Content = g;
        Opened += (_, _) => { CompareWindow.FitToScreen(this); _ = Run(); };
        Closed += (_, _) => _cancel.Cancel();
    }

    async Task Run()
    {
        _cancel.Cancel();
        _cancel = new CancellationTokenSource();
        _list.Children.Clear(); _ticks.Clear(); _diffs.Clear();
        _detail.Inlines?.Clear(); _detail.Text = "";
        _install.IsEnabled = false;
        _status.Text = $"asking {_site} what it has…";
        List<Updater.Change> changes;
        try { changes = await Updater.Check(_site, _cancel.Token); }
        catch (OperationCanceledException) { return; }
        catch (Exception ex)
        {
            _status.Text = $"could not check {_site}: {ex.Message}";
            AppLog.Error("updates", "check failed", ex);
            return;
        }
        if (changes.Count == 0) { _status.Text = $"Everything is up to date with {_site} (the program and its templates)."; return; }
        _status.Text = $"{changes.Count} file(s) differ from {_site}. Pick one to see what changed; nothing is downloaded until you press Download and install.";
        foreach (var c in changes.OrderByDescending(c => c.NeedsRestart).ThenBy(c => c.Server.Path, StringComparer.OrdinalIgnoreCase))
        {
            var tick = new CheckBox { IsChecked = c.Recommended, VerticalAlignment = VerticalAlignment.Top };
            tick.IsCheckedChanged += (_, _) => UpdateInstall();
            _ticks[c] = tick;
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = c.Server.Path + (c.NeedsRestart ? "  (the program)" : ""), FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
            text.Children.Add(new TextBlock { Text = c.Why, FontSize = 11, Opacity = 0.8, TextWrapping = TextWrapping.Wrap });
            var row = new DockPanel { Margin = new Thickness(0, 3) };
            DockPanel.SetDock(tick, Dock.Left); row.Children.Add(tick);
            var pick = new Button { Content = text, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(6, 3) };
            ToolTip.SetTip(pick, "Show what changed in this file.");
            pick.Click += (_, _) => _ = Show(c);
            row.Children.Add(pick);
            _list.Children.Add(row);
        }
        UpdateInstall();
        await Show(changes.OrderByDescending(c => c.NeedsRestart).ThenBy(c => c.Server.Path, StringComparer.OrdinalIgnoreCase).First());
    }

    void UpdateInstall() => _install.IsEnabled = _ticks.Values.Any(t => t.IsChecked == true);

    /// The difference for one file: line by line for text, the facts for the program.
    async Task Show(Updater.Change c)
    {
        var f = c.Server;
        var head = new List<string>
        {
            f.Path,
            $"  on the site: version {f.Version} of this file{(f.FileVersion != null ? $" (program version {f.FileVersion})" : "")}, " +
            $"{Updater.Size(f.Size)}, changed {f.Changed.ToLocalTime():yyyy-MM-dd HH:mm}",
            c.Exists
                ? $"  here:        {(c.LocalVersion != null ? $"program version {c.LocalVersion}, " : "")}{Updater.Size(new FileInfo(c.LocalPath).Length)}, " +
                  $"last written {File.GetLastWriteTime(c.LocalPath):yyyy-MM-dd HH:mm}"
                : "  here:        not there yet",
            "  " + c.Why,
            c.NeedsRestart ? "  Replacing it needs the program restarted (you are asked)." : c.Exists ? "  The one here is kept as " + Path.GetFileName(c.LocalPath) + ".bak." : "",
            "",
        };
        if (!f.Text || !c.Exists)
        {
            SetDetail(head, null);
            return;
        }
        if (!_diffs.TryGetValue(f.Path, out var diff))
        {
            SetDetail([.. head, "reading the site's copy to compare (nothing is written)…"], null);
            try
            {
                var there = await Updater.Fetch(_site, f, _cancel.Token);
                var here = await File.ReadAllTextAsync(c.LocalPath, _cancel.Token);
                diff = await Task.Run(() => LineDiff.Compare(here, there));
                _diffs[f.Path] = diff;
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex) { SetDetail([.. head, "could not read the site's copy: " + ex.Message], null); return; }
        }
        if (diff is not { } d) { SetDetail([.. head, "too different to list line by line."], null); return; }
        head.Add($"{d.Removed} line(s) taken out, {d.Added} line(s) put in:");
        head.Add("");
        SetDetail(head, d.Hunks);
    }

    void SetDetail(List<string> head, List<LineDiff.Line>? lines)
    {
        _detail.Text = null;
        var inl = new InlineCollection();
        foreach (var h in head) inl.Add(new Run(h + "\n"));
        const int cap = 6000;
        foreach (var l in (lines ?? []).Take(cap))
            inl.Add(l.Kind switch
            {
                LineDiff.Kind.Hunk => new Run("\n" + l.Text + "\n") { Foreground = HunkInk },
                LineDiff.Kind.Removed => new Run("- " + l.Text + "\n") { Foreground = Gone },
                LineDiff.Kind.Added => new Run("+ " + l.Text + "\n") { Foreground = Came },
                _ => new Run("  " + l.Text + "\n") { Foreground = SameInk },
            });
        if (lines?.Count > cap) inl.Add(new Run($"\n… and {lines.Count - cap} more lines"));
        _detail.Inlines = inl;
    }

    async Task InstallTicked()
    {
        var picked = _ticks.Where(t => t.Value.IsChecked == true).Select(t => t.Key).ToList();
        if (picked.Count == 0) return;
        long total = picked.Sum(c => c.Server.Size);
        bool restart = picked.Any(c => c.NeedsRestart);
        var names = string.Join("\n", picked.Select(c => $"  {c.Server.Path}  ({Updater.Size(c.Server.Size)})"));
        if (!await Dialogs.Confirm(this, "Download the updates?",
                $"Download {picked.Count} file(s), {Updater.Size(total)} in all, from {_site}:\n\n{names}\n\n" +
                "Templates that are replaced are kept as .bak." + (restart ? " The program itself is among them: it needs restarting afterwards." : ""),
                "Download", "Not now")) return;
        _install.IsEnabled = false;
        var done = new List<string>();
        string? failed = null;
        foreach (var c in picked)
        {
            var progress = new Progress<double>(p => _status.Text = $"downloading {c.Server.Path}… {p * 100:0}%");
            try { await Updater.Install(_site, c, progress, _cancel.Token); done.Add(c.Server.Path); }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                failed = $"{c.Server.Path}: {ex.Message}";
                AppLog.Error("updates", "install failed: " + c.Server.Path, ex);
                break;
            }
        }
        _status.Text = failed == null ? $"Installed {done.Count} file(s)." : $"Installed {done.Count} file(s); stopped at {failed}";
        if (done.Count > 0 && restart && picked.Where(c => c.NeedsRestart).All(c => done.Contains(c.Server.Path)))
        {
            var main = (Application.Current?.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.MainWindow;
            if (main is MainWindow mw && await Dialogs.Confirm(this, "Restart the program?",
                    "The program itself was updated. It runs the new version once it is restarted.", "Restart now", "Later")
                && await mw.ReadyToRestart())
            {
                Close();
                Updater.Restart(mw);
                return;
            }
            _status.Text += " The new program runs from the next start.";
        }
        else if (done.Count > 0) _ = Run();
    }
}
