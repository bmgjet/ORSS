// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Text;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Calibration;
using OkiRomSim.Desktop;

namespace AlphaEmuPlugin;

/// A saved calibration and what was different about it.
public sealed class AlphaSnapshot
{
    public string Name { get; set; } = "";
    public DateTime At { get; set; }
    public int Bytes { get; set; }
    public int ChangedFromPrevious { get; set; }
    public string File { get; set; } = "";
    public string Note { get; set; } = "";
    public string Sha { get; set; } = "";
}

/// Snapshots and the working recovery: the calibration as it was at a moment, with the byte count that
/// separates it from now, kept in the plugin's own folder. Restoring writes through the app, so the
/// editor's undo still has the change and the emulator gets it from real-time update.
public sealed class AlphaSnapshots
{
    readonly AlphaHub _hub;
    readonly string _folder;
    List<AlphaSnapshot> _list = [];

    public AlphaSnapshots(AlphaHub hub)
    {
        _hub = hub;
        _folder = Path.Combine(hub.Folder, "snapshots");
        Directory.CreateDirectory(_folder);
        try { if (File.Exists(Index)) _list = JsonSerializer.Deserialize<List<AlphaSnapshot>>(File.ReadAllText(Index)) ?? []; } catch { _list = []; }
    }

    string Index => Path.Combine(_folder, "index.json");
    public IReadOnlyList<AlphaSnapshot> All => _list;

    /// Save the ROM as it is now. `name` may be empty, in which case a timestamped one is made.
    public AlphaSnapshot? Capture(string name, string note = "")
    {
        try
        {
            if (!_hub.HasRom) return null;
            var rom = _hub.App.Sim.RomCopy();
            var last = _list.FirstOrDefault();
            int changed = CountDiff(last == null ? null : TryRead(last), rom);
            var snap = new AlphaSnapshot
            {
                Name = string.IsNullOrWhiteSpace(name) ? "snapshot " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") : name.Trim(),
                At = DateTime.Now,
                Bytes = rom.Length,
                ChangedFromPrevious = changed,
                File = "s" + snap_time() + ".bin",
                Note = note,
                Sha = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(rom))[..16].ToLowerInvariant(),
            };
            File.WriteAllBytes(Path.Combine(_folder, snap.File), rom);
            _list.Insert(0, snap);
            while (_list.Count > _hub.State.MaxSnapshots) { var gone = _list[^1]; _list.RemoveAt(_list.Count - 1); Try(() => File.Delete(Path.Combine(_folder, gone.File))); }
            Save();
            return snap;
        }
        catch { return null; }
        string snap_time() => DateTime.Now.ToString("yyyyMMdd-HHmmss-fff");
    }

    /// The self-healing copy: written while the calibration is dirty, so a crash does not lose the session.
    public void RecoveryTick()
    {
        try
        {
            if (!_hub.HasRom || !_hub.App.Sim.RomDirty) return;
            var rom = _hub.App.Sim.RomCopy();
            var file = Path.Combine(_folder, "recovery.bin");
            if (File.Exists(file) && new FileInfo(file).LastWriteTime > DateTime.Now.AddSeconds(-8)) return;
            File.WriteAllBytes(file, rom);
            File.WriteAllText(Path.Combine(_folder, "recovery.txt"),
                $"{DateTime.Now:O}{Environment.NewLine}{_hub.RomName()}{Environment.NewLine}{rom.Length} bytes");
        }
        catch { }
    }

    public (DateTime At, int Bytes, string Rom)? Recovery()
    {
        try
        {
            var file = Path.Combine(_folder, "recovery.bin");
            if (!File.Exists(file)) return null;
            int size = (int)new FileInfo(file).Length;
            string rom = "unknown";
            var meta = Path.Combine(_folder, "recovery.txt");
            if (File.Exists(meta)) { var lines = File.ReadAllLines(meta); if (lines.Length > 1) rom = lines[1]; }
            return (new FileInfo(file).LastWriteTime, size, rom);
        }
        catch { return null; }
    }

    public byte[]? TryRead(AlphaSnapshot s)
    {
        try { var p = Path.Combine(_folder, s.File); return File.Exists(p) ? File.ReadAllBytes(p) : null; } catch { return null; }
    }

    public byte[]? RecoveryBytes()
    {
        try { var f = Path.Combine(_folder, "recovery.bin"); return File.Exists(f) ? File.ReadAllBytes(f) : null; } catch { return null; }
    }

    public void Remove(AlphaSnapshot s)
    {
        _list.Remove(s);
        Try(() => File.Delete(Path.Combine(_folder, s.File)));
        Save();
    }

    static void Try(Action a) { try { a(); } catch { } }

    void Save() { try { File.WriteAllText(Index, JsonSerializer.Serialize(_list, new JsonSerializerOptions { WriteIndented = true })); } catch { } }

    /// How many bytes differ, and where they fall: the tables the definitions say are there.
    public static int CountDiff(byte[]? before, byte[] after)
    {
        if (before == null || before.Length != after.Length) return after.Length;
        int n = 0;
        for (int i = 0; i < after.Length; i++) if (before[i] != after[i]) n++;
        return n;
    }

    public List<(string What, int Cells)> DiffAgainst(byte[] before)
    {
        var result = new List<(string, int)>();
        try
        {
            var rom = _hub.App.Sim.RomCopy();
            if (before.Length != rom.Length) { result.Add(("the image size changed", 0)); return result; }
            var defs = _hub.App.Sim.Defs();
            var hits = new Dictionary<string, int>();
            foreach (var item in defs.Items)
            {
                int n = 0;
                int count = Math.Max(1, item.Count);
                for (int i = 0; i < count; i++)
                {
                    int addr = item.CellAddress(i);
                    for (int b = 0; b < item.ElementSize && addr + b < rom.Length; b++)
                        if (rom[addr + b] != before[addr + b]) { n++; break; }
                }
                if (n > 0) hits[item.Name] = n;
            }
            int claimed = hits.Values.Sum();
            int total = CountDiff(before, rom);
            foreach (var (name, n) in hits.OrderByDescending(h => h.Value).Take(12)) result.Add((name, n));
            if (total - claimed > 0) result.Add(("bytes no table claims (code, scalars, or a table with no definition)", total - claimed));
            if (result.Count == 0) result.Add(("nothing - the ROM is byte for byte as it was", 0));
        }
        catch (Exception ex) { result.Add(("the comparison failed: " + ex.Message, 0)); }
        return result;
    }
}

/// One thing the datalog suggests is worth a look.
public sealed record AlphaEvent(string Type, string Tone, string Title, string Detail, DateTime At);

/// The datalog insights: the same handful of rules ALPHAlink ran over every sample - sustained lean
/// under boost, duty through the roof, the limiter, temperatures, a battery that has dropped out -
/// with the same cooldowns so one long pull does not fill the list.
public sealed class AlphaInsights
{
    readonly Dictionary<string, int> _streak = [];
    readonly Dictionary<string, DateTime> _lastAt = [];
    readonly List<AlphaEvent> _events = [];
    readonly object _gate = new();
    int _seen;

    /// Frames arrive on the datalog thread while the screens read this on the UI thread.
    public IReadOnlyList<AlphaEvent> Events { get { lock (_gate) return [.. _events]; } }
    public event Action? Changed;

    public void Reset() { lock (_gate) { _streak.Clear(); _lastAt.Clear(); _events.Clear(); _seen = 0; } Changed?.Invoke(); }

    public void Look(LogFrame f)
    {
        bool changed = false;
        lock (_gate)
        {
            _seen++;
            if (_seen % 4 != 0) return;          // a quarter as often as the frames: the rules need 3 samples anyway
            double? rpm = f.Rpm, afr = f.Get("afr"), duty = f.Get("inj_duty_pct"), ect = f.EctC, batt = f.BattV, map = f.MapKpa, tps = f.TpsPct;
            double mapKpa = map ?? 0;
            double boost = mapKpa > 101 ? (mapKpa - 101.325) * 0.0145038 : 0;
            bool ValidAfr(double? a) => a is double x && x > 7 && x < 24;

            Sustained("lean_boost", boost >= 1 && rpm > 2500 && ValidAfr(afr) && afr > 15.0, 3, () =>
                changed |= Add("lean_boost", "danger", "Lean under boost", $"{afr:0.0} AFR at {boost:0.0} psi and {rpm:0} rpm."));
            Sustained("rich_boost", boost >= 1 && rpm > 2500 && ValidAfr(afr) && afr < 10.5, 3, () =>
                changed |= Add("rich_boost", "danger", "Very rich under boost", $"{afr:0.0} AFR at {boost:0.0} psi."));
            Sustained("duty", duty >= 90 && rpm > 2500, 3, () =>
                changed |= Add("duty", "danger", "Injector duty at the limit", $"{duty:0}% duty at {rpm:0} rpm - the injectors cannot add more fuel."));
            Sustained("revlimit", rpm >= 8100, 2, () => changed |= Add("revlimit", "info", "Rev limit", $"{rpm:0} rpm - the limiter is in play."));
            Sustained("hot", ect >= 101, 6, () => changed |= Add("hot", "warn", "Coolant at 101 °C and holding", $"{ect:0} °C."));
            Sustained("batt", batt is double b && b < 12.0, 5, () => changed |= Add("batt", "warn", "Battery below 12 V", $"{batt:0.0} V."));
            double o2v = f.O2V ?? 9;
            Sustained("noo2", o2v < 0.05 && rpm > 2000, 8, () => changed |= Add("noo2", "warn", "O2 sensor sitting at zero", $"{o2v:0.00} V at {rpm:0} rpm - sensor cold, or not connected."));
            Sustained("fuelcut", f.Get("fc") > 0 && rpm > 3000, 2, () => changed |= Add("fuelcut", "info", "Fuel cut", $"at {rpm:0} rpm, {tps:0}% throttle."));
            Sustained("vtec", f.Vtec == true, 4, () => changed |= Add("vtec", "info", "VTEC on", $"{rpm:0} rpm, {tps:0}% throttle."));
        }
        if (changed) Changed?.Invoke();
    }

    void Sustained(string key, bool condition, int samples, Action add)
    {
        _streak[key] = condition ? (_streak.TryGetValue(key, out int n) ? n : 0) + 1 : 0;
        if (_streak[key] == samples) add();
    }

    bool Add(string type, string tone, string title, string detail)
    {
        if (_lastAt.TryGetValue(type, out var last) && (DateTime.Now - last).TotalSeconds < 4) return false;
        _lastAt[type] = DateTime.Now;
        _events.Insert(0, new AlphaEvent(type, tone, title, detail, DateTime.Now));
        while (_events.Count > 80) _events.RemoveAt(_events.Count - 1);
        return true;
    }
}

/// The snapshots screen.
public sealed class AlphaSnapshotsPage : IAlphaPage
{
    readonly AlphaHub _hub;
    readonly StackPanel _list = new() { Spacing = 4 };
    readonly TextBlock _recovery = new() { FontSize = 11.5, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap };
    readonly TextBox _name = new() { Width = 260, FontSize = 12, Watermark = "name it (dyno pull 3, 93 octane…)" };
    readonly TextBlock _diff = new() { FontSize = 11.5, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap };

    public string Title => "Snapshots";
    public string Icon => "⏱";
    public Control Content { get; }

    public AlphaSnapshotsPage(AlphaHub hub)
    {
        _hub = hub;
        var top = new WrapPanel { Orientation = Orientation.Horizontal, ItemSpacing = 8, LineSpacing = 8 };
        top.Children.Add(_name);
        top.Children.Add(Alpha.Primary("Snapshot now", () => { _hub.SnapshotNow(_name.Text); _name.Text = ""; }, "Save the calibration as it is, with how many bytes differ from the last one."));
        top.Children.Add(Alpha.Ghost("Restore newest", () => _hub.RestoreSnapshot(_hub.Snapshots.All.FirstOrDefault()), "Put the newest snapshot back into the editor."));
        top.Children.Add(Alpha.Ghost("Recovery…", () => _hub.RestoreRecovery(), "Take back the last working-recovery copy if something went wrong."));
        Content = new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Alpha.Card("Calibration snapshots", new StackPanel { Spacing = 6, Children = { top, _recovery, _list } },
                    Alpha.Note($"the last {_hub.State.MaxSnapshots} are kept, in the plugin's own folder")),
                Alpha.Card("What changed since the newest snapshot", _diff),
            }
        };
        Refresh();
    }

    public void Refresh()
    {
        var rec = _hub.Snapshots.Recovery();
        _recovery.Text = rec is (DateTime at, int bytes, string rom)
            ? $"working recovery: {AlphaState.Bytes(bytes)} of {rom}, written {at:HH:mm:ss}. It is refreshed every few seconds while the calibration is dirty."
            : "no working recovery yet - it appears the first time the calibration goes dirty while ALPHAemu is loaded.";
        _list.Children.Clear();
        if (_hub.Snapshots.All.Count == 0) _list.Children.Add(Alpha.Note("Nothing saved yet."));
        foreach (var s in _hub.Snapshots.All)
        {
            var left = new StackPanel { Spacing = 1 };
            left.Children.Add(new TextBlock { Text = s.Name, FontSize = 12.5, FontWeight = FontWeight.SemiBold, Foreground = Alpha.Ink });
            left.Children.Add(new TextBlock
            {
                Text = $"{s.At:yyyy-MM-dd HH:mm:ss} · {AlphaState.Bytes(s.Bytes)} · {(s.ChangedFromPrevious == 0 ? "identical to the one before" : s.ChangedFromPrevious + " bytes different from the one before")} · sha {s.Sha[..Math.Min(8, s.Sha.Length)]}"
                     + (s.Note.Length > 0 ? " · " + s.Note : ""),
                FontSize = 10.5, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap,
            });
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
            var snap = s;
            buttons.Children.Add(Alpha.Ghost("Restore", () => _hub.RestoreSnapshot(snap), "Write this image back into the editor."));
            buttons.Children.Add(Alpha.Ghost("Diff", () => ShowDiff(snap), "What the tables differ by, table by table."));
            buttons.Children.Add(Alpha.Danger("Delete", () => { _hub.Snapshots.Remove(snap); Refresh(); }));
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
            Grid.SetColumn(left, 0); g.Children.Add(left);
            Grid.SetColumn(buttons, 1); g.Children.Add(buttons);
            _list.Children.Add(new Border
            {
                Background = Alpha.Tint(Alpha.Rgb(0x1f, 0x22, 0x27), 190), BorderBrush = Alpha.Line, BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(6), Padding = new Thickness(9, 5), Child = g,
            });
        }
        var newest = _hub.Snapshots.All.FirstOrDefault();
        if (newest == null) _diff.Text = "no snapshot to compare with yet.";
        else
        {
            var before = _hub.Snapshots.TryRead(newest);
            if (before == null) _diff.Text = "the newest snapshot's bytes are not on disk any more.";
            else
            {
                var parts = _hub.Snapshots.DiffAgainst(before);
                _diff.Text = string.Join("   ·   ", parts.Select(p => $"{p.What}: {p.Cells}"));
            }
        }
    }

    void ShowDiff(AlphaSnapshot s)
    {
        var before = _hub.Snapshots.TryRead(s);
        if (before == null) { _hub.Notify("That snapshot's file is gone."); return; }
        var parts = _hub.Snapshots.DiffAgainst(before);
        _diff.Text = $"against {s.Name}: " + string.Join("   ·   ", parts.Select(p => $"{p.What}: {p.Cells}"));
    }
}




