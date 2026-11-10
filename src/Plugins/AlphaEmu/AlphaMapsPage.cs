// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Security.Cryptography;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using OkiRomSim.Calibration;
using OkiRomSim.Desktop;

namespace AlphaEmuPlugin;

/// The Multi Map Manager: stage a calibration for each map slot, send it to the emulator, verify the
/// device's copy against the SHA that was staged, commit it, and make it live - the same order the
/// ALPHAlink workflow uses, because that order is what keeps a wrong image from ever running.
/// The ROM's tables are edited in the app's own calibration editor; real-time update sends those edits on.
public sealed class AlphaMapsPage : IAlphaPage
{
    readonly AlphaHub _hub;
    readonly StackPanel _slotRows = new() { Spacing = 5 };
    readonly TextBlock _summary = new() { FontSize = 11.5, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap };
    readonly ProgressBar _progress = new() { Height = 6, IsVisible = false, Minimum = 0, Maximum = 100 };
    readonly TextBlock _message = new() { FontSize = 11, Foreground = Alpha.Dim };
    readonly TextBlock _romLine = new() { FontSize = 11, Foreground = Alpha.Dim };

    readonly List<(Border Row, TextBlock Name, TextBlock Detail, WrapPanel Badges, TextBlock State)> _rows = [];
    bool _busy;

    public string Title => "Multi-map";
    public string Icon => "▤";
    public Control Content { get; }

    public AlphaMapsPage(AlphaHub hub)
    {
        _hub = hub;
        var deploy = Alpha.Primary("Deploy loaded maps", DeployRequested, "Write every staged slot, verify each one, and commit.");
        var stage = Alpha.Ghost("Stage a file…", () => { _ = StageAsync(); }, "Pick a calibration BIN for the selected slot.");

        var head = new StackPanel { Spacing = 5 };
        head.Children.Add(Wrap(new Control[] { Alpha.Head("Map slots", "Staged on this laptop, then written, verified and committed in that order."), deploy, stage }));
        head.Children.Add(_summary);
        head.Children.Add(_progress);
        head.Children.Add(_message);
        head.Children.Add(_romLine);
        foreach (var (label, tip) in new (string, string)[]
                 { ("Slot 0", "Staged calibration for map slot 0"), ("Slot 1", "Staged calibration for map slot 1"),
                   ("Slot 2", "Staged calibration for map slot 2"), ("Slot 3", "Staged calibration for map slot 3") })
        {
            var name = new TextBlock { FontSize = 12.5, FontWeight = FontWeight.SemiBold, Foreground = Alpha.Ink };
            var detail = new TextBlock { FontSize = 10.5, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap };
            var state = new TextBlock { FontSize = 10.5, FontFamily = Alpha.Mono, Foreground = Alpha.Dim, VerticalAlignment = VerticalAlignment.Center };
            var badges = new WrapPanel { Orientation = Orientation.Horizontal };
            var left = new StackPanel { Spacing = 2 };
            var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            titleRow.Children.Add(name); titleRow.Children.Add(badges);
            left.Children.Add(titleRow);
            left.Children.Add(detail);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
            int slot = _rows.Count;
            buttons.Children.Add(Alpha.Ghost("Load…", () => { _ = StageAsync(slot); }, "Choose the calibration for this slot."));
            buttons.Children.Add(Alpha.Ghost("Write", () => DeploySlot(slot), "Write and verify this slot on the emulator."));
            buttons.Children.Add(Alpha.Ghost("Read", () => ReadSlot(slot), "Read the device's copy of this slot back into the editor."));
            buttons.Children.Add(Alpha.Ghost("Live", () => MakeLive(slot), "Ask the emulator to run this slot."));
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
            Grid.SetColumn(left, 0); g.Children.Add(left);
            Grid.SetColumn(buttons, 1); g.Children.Add(buttons);
            var row = new Border
            {
                Background = Alpha.Tint(Alpha.Rgb(0x1f, 0x22, 0x27), 200), BorderBrush = Alpha.Line, BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(7), Padding = new Thickness(9, 6), Child = g,
            };
            _slotRows.Children.Add(row);
            _rows.Add((row, name, detail, badges, state));
        }

        Content = Alpha.Card("Multi Map Manager", new StackPanel { Spacing = 8, Children = { head, _slotRows } },
            Alpha.Note("The tables themselves are edited in the app's calibration editor; with real-time update on, each edit goes to the running image."));
        Refresh();
    }

    static WrapPanel Wrap(Control[] items)
    {
        var w = new WrapPanel { Orientation = Orientation.Horizontal, ItemSpacing = 8, LineSpacing = 8 };
        foreach (var i in items) w.Children.Add(i);
        return w;
    }

    // ---------------------------------------------------------------- the slots

    public void DeployRequested() => DeployAll();

    void DeployAll()
    {
        if (_busy) return;
        var staged = _hub.State.Slots.Where(s => s.Loaded).ToList();
        if (staged.Count == 0) { _hub.Notify("Stage a calibration in at least one slot first."); return; }
        if (_hub.Session.Phase is not (AlphaLinkPhase.Linked or AlphaLinkPhase.Logging)) { _hub.Notify("The emulator is not linked - connect it first."); return; }
        int active = _hub.Session.Identity?.ActiveSlot ?? -1;
        if (_hub.State.ConfirmActiveSlot && staged.Any(s => s.Id == active))
        {
            if (!_hub.Confirm($"Slot {active} is the one running right now",
                    $"Deploying writes slot {active}, so the calibration the engine is running can change immediately. Continue?")) return;
        }
        if (_hub.State.AutoSnapshotOnDeploy) _hub.SnapshotNow("before deploying " + string.Join(", ", staged.Select(s => "slot " + s.Id)));

        _busy = true;
        _progress.IsVisible = true;
        _message.Text = $"deploying {staged.Count} slot{(staged.Count == 1 ? "" : "s")}…";
        int done = 0;
        _hub.Session.Run("deploy", s =>
        {
            var errors = new List<string>();
            foreach (var slot in staged)
            {
                try
                {
                    string result = s.DeploySlot(slot.Id, slot.Bytes!, (at, total) =>
                        _hub.Ui(() => { _progress.Value = 100.0 * (done + (double)at / Math.Max(1, total)) / staged.Count; }));
                    slot.LastResult = result;
                    slot.Verified = slot.Committed = true;
                    _hub.Ui(() => _message.Text = $"slot {slot.Id}: {result}");
                }
                catch (Exception ex) { errors.Add($"slot {slot.Id}: {ex.Message}"); slot.LastResult = "failed: " + ex.Message; }
                done++;
                _hub.Ui(() => { _progress.Value = 100.0 * done / staged.Count; RefreshSlots(); });
            }
            _busy = false;
            _hub.Ui(() =>
            {
                _progress.IsVisible = false;
                _message.Text = errors.Count == 0
                    ? $"{staged.Count} slot{(staged.Count == 1 ? "" : "s")} written, verified and committed."
                    : "stopped: " + string.Join("; ", errors);
                Refresh();
            });
            return errors.Count == 0 ? staged.Count + " slots deployed" : string.Join("; ", errors);
        }, _ => { _busy = false; _hub.Ui(Refresh); });
    }

    void DeploySlot(int slot)
    {
        var s = _hub.State.Slots[slot];
        if (!s.Loaded) { _hub.Notify($"Stage a calibration in slot {slot} first."); return; }
        if (_hub.State.AutoSnapshotOnDeploy) _hub.SnapshotNow($"before writing slot {slot}");
        _busy = true;
        _progress.IsVisible = true;
        _message.Text = $"writing slot {slot}…";
        _hub.Session.Run($"slot {slot}", ses =>
        {
            string result = ses.DeploySlot(slot, s.Bytes!, (at, total) => _hub.Ui(() => _progress.Value = 100.0 * at / Math.Max(1, total)));
            s.Verified = s.Committed = true;
            s.LastResult = result;
            _hub.Ui(() => { _progress.IsVisible = false; _message.Text = $"slot {slot}: {result}"; });
            return result;
        }, _ => { _busy = false; _hub.Ui(Refresh); });
    }

    void ReadSlot(int slot)
    {
        _hub.Session.Run($"read slot {slot}", ses =>
        {
            var info = ses.Command(AlphaCmd.SlotInfo, [(byte)slot]);
            int size = info.Num("size");
            if (size <= 0) throw new IOException($"slot {slot} is empty");
            var bytes = ses.ReadSlotBytes(slot, size) ?? throw new IOException("the device sent nothing back");
            var st = _hub.State;
            st.StageBytes(slot, bytes, $"device slot {slot}");
            _hub.Ui(() =>
            {
                _message.Text = $"slot {slot} read: {AlphaState.Bytes(bytes.Length)}, SHA {st.Slots[slot].ShortSha}";
                if (_hub.Confirm("Slot " + slot + " read", "Put the bytes that were read into the editor as the working calibration?"))
                    _hub.LoadIntoRom(bytes, $"slot {slot}");
                Refresh();
            });
            return $"{AlphaState.Bytes(bytes.Length)} read";
        });
    }

    void MakeLive(int slot) => _hub.Session.Run($"slot {slot} live", ses =>
    {
        string r = ses.SetActiveSlot(slot);
        _hub.Ui(() => _message.Text = r);
        return r;
    });

    async Task StageAsync(int? which = null)
    {
        var top = _hub.TopLevel;
        if (top?.StorageProvider == null) { _hub.Notify("This platform has no file picker."); return; }
        var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Calibration for a map slot", AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("Calibration images") { Patterns = ["*.bin", "*.rom", "*.img"] }, FilePickerFileTypes.All],
        });
        if (files.Count == 0) return;
        var path = files[0].Path.LocalPath;
        if (string.IsNullOrEmpty(path)) return;
        byte[] bytes;
        try { bytes = await File.ReadAllBytesAsync(path); }
        catch (Exception ex) { _hub.Notify("Could not read " + path + ": " + ex.Message); return; }
        int slot = which ?? _hub.State.SelectedSlot;
        int expected = _hub.RomSize();
        string name = System.IO.Path.GetFileName(path);
        if (expected > 0 && bytes.Length != expected)
        {
            if (!_hub.Confirm("Different size",
                    $"{name} is {AlphaState.Bytes(bytes.Length)}, but the ROM in the editor is {AlphaState.Bytes(expected)}. The emulator will refuse a slot image that is not the size it expects. Stage it anyway?"))
                return;
        }
        _hub.State.StageBytes(slot, bytes, name);
        _hub.State.SelectedSlot = slot;
        _hub.State.Save(_hub.Folder);
        _message.Text = $"staged {name} in slot {slot} ({AlphaState.Bytes(bytes.Length)}, SHA {SHA(bytes)})";
        Refresh();
    }

    static string SHA(byte[] b) => Convert.ToHexString(SHA256.HashData(b))[..10].ToLowerInvariant();

    void RefreshSlots()
    {
        var st = _hub.State;
        int active = _hub.Session.Identity?.ActiveSlot ?? -1, target = _hub.Session.Identity?.TargetSlot ?? -1;
        int ready = st.Slots.Count(s => s.Loaded);
        _summary.Text = $"ready {ready} / {st.Slots.Count} · live slot {(active < 0 ? "--" : active.ToString())} · write target {(target < 0 ? "--" : target.ToString())} · "
                      + $"image {AlphaState.Bytes(_hub.RomSize())} · {_hub.Session.LinkName}";
        for (int i = 0; i < _rows.Count && i < st.Slots.Count; i++)
        {
            var s = st.Slots[i];
            var (row, name, detail, badges, state) = _rows[i];
            name.Text = $"{s.Label}   ·   Slot {s.Id}";
            detail.Text = s.Loaded ? $"{s.Filename} · {AlphaState.Bytes(s.StagedBytes)} · sha {s.ShortSha} · staged {s.StagedAt:HH:mm}"
                                   : "nothing staged - Load… picks a calibration BIN for this slot";
            badges.Children.Clear();
            if (i == active) badges.Children.Add(Alpha.Badge("LIVE", Alpha.Green, "the image the emulator is running"));
            if (i == target) badges.Children.Add(Alpha.Badge("TARGET", Alpha.Cyan, "where the next write goes"));
            if (s.Loaded) badges.Children.Add(Alpha.Badge("BIN", Alpha.Blue, "staged on this laptop"));
            if (s.Verified) badges.Children.Add(Alpha.Badge("VERIFIED", Alpha.Teal, "the device's copy matches the staged SHA"));
            if (s.Committed) badges.Children.Add(Alpha.Badge("COMMITTED", Alpha.Purple, "the device has it as a finished image"));
            if (!s.Loaded && i == active) badges.Children.Add(Alpha.Badge("DEVICE", Alpha.Sky, "only what the device holds"));
            state.Text = s.LastResult;
            state.Foreground = s.LastResult.StartsWith("failed", StringComparison.OrdinalIgnoreCase) ? Alpha.RedBrush : Alpha.Dim;
            row.BorderBrush = s.Loaded ? Alpha.Tint(Alpha.Cyan, 90) : Alpha.Line;
        }
    }

    public void Refresh()
    {
        _romLine.Text = _hub.HasRom
            ? $"the ROM open in the editor: {_hub.RomName()} · {_hub.RomSize():N0} bytes"
            : "no ROM is open in the editor";
        RefreshSlots();
    }
}





