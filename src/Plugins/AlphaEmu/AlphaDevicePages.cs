// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Text;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Desktop;

namespace AlphaEmuPlugin;

/// Diagnostics: the codes the emulator and the simulated ECU are holding, the checks that say whether
/// this session is safe to tune with, and the datalog insights.
public sealed class AlphaDiagnosticsPage : IAlphaPage
{
    readonly AlphaHub _hub;
    readonly StackPanel _codes = new() { Spacing = 4 };
    readonly TextBlock _codeLine = new() { FontSize = 11.5, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap };
    readonly StackPanel _checks = new() { Spacing = 3 };
    readonly StackPanel _insights = new() { Spacing = 3 };
    readonly Dictionary<string, (Border Row, LedLamp Dot, TextBlock Value)> _checkRows = new();
    readonly TextBlock _insightHead = new() { FontSize = 11.5, Foreground = Alpha.Dim };

    public string Title => "Diagnostics";
    public string Icon => "⚠";
    public Control Content { get; }

    public AlphaDiagnosticsPage(AlphaHub hub)
    {
        _hub = hub;
        // a console (or a window of this screen) can be opened many times over the session: come off
        // the insights event when this copy leaves the visual tree, or every copy would refresh forever
        Action refresh = () => hub.Ui(RefreshInsights);
        _hub.Insights.Changed += refresh;
        Content = new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Alpha.Card("Trouble codes", new StackPanel { Spacing = 6, Children = { _codeLine, _codes } },
                    Alpha.Ghost("Clear the emulator's codes", () => _hub.ClearCodes(), "The device's own clear command - what the backup fuse does on the car."),
                    Alpha.Ghost("Clear the simulator's", () => { _hub.App.Sim.Control("reset"); _hub.Notify("the simulated ECU was reset, which drops its RAM and its stored codes with it"); },
                        "Reset the simulated ECU: it loses its RAM, the stored codes with it, and starts again from reset.")),
                Alpha.Card("Session checks", _checks, Alpha.Ghost("Run again", () => _hub.RunChecks(true), "Ask the emulator and the app again.")),
                Alpha.Card("Datalog insights", new StackPanel { Spacing = 5, Children = { _insightHead, _insights } },
                    Alpha.Ghost("Clear", () => { _hub.Insights.Reset(); RefreshInsights(); }, "Forget the events so far.")),
            }
        };
        Content.DetachedFromVisualTree += (_, _) => _hub.Insights.Changed -= refresh;
        RefreshInsights();
        Refresh();
    }

    public void Refresh()
    {
        var (codes, source) = _hub.Session.TroubleCodes();
        var sim = SafeMil();
        var all = codes.Concat(sim).Distinct().OrderBy(c => c).ToArray();
        _codeLine.Text = all.Length == 0
            ? "no codes from " + (_hub.Session.Phase is AlphaLinkPhase.Linked or AlphaLinkPhase.Logging ? "the emulator" : "the emulator (not linked)") + " and none in the simulated ECU."
            : $"{all.Length} code{(all.Length == 1 ? "" : "s")} - {string.Join(", ", all.Select(c => c + " " + OkiRomSim.Core.MilMonitor.Name(c)))}." +
              (source.Length > 0 ? $" From {source}." : "");
        _codes.Children.Clear();
        foreach (int code in all)
        {
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*") };
            var num = new Border
            {
                Background = Alpha.Tint(Alpha.Red, 45), BorderBrush = Alpha.Tint(Alpha.Red, 150), BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(4), Padding = new Thickness(7, 1), MinWidth = 34,
                Child = new TextBlock { Text = code.ToString(CultureInfo.InvariantCulture), FontFamily = Alpha.Mono, FontWeight = FontWeight.Bold, FontSize = 13, Foreground = Alpha.Ink, TextAlignment = TextAlignment.Center },
            };
            Grid.SetColumn(num, 0); row.Children.Add(num);
            var text = new TextBlock { Text = OkiRomSim.Core.MilMonitor.Name(code), FontSize = 12, Foreground = Alpha.Ink, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(9, 0, 0, 0) };
            Grid.SetColumn(text, 1); row.Children.Add(text);
            _codes.Children.Add(row);
        }
        if (all.Length == 0) _codes.Children.Add(Alpha.Note("Nothing stored. The alert banner on the console only appears when something is."));

        foreach (var c in _hub.RunChecks(false))
        {
            if (!_checkRows.TryGetValue(c.Id, out var row))
            {
                row = Alpha.CheckRow(c.Title, c.Detail);
                _checkRows[c.Id] = row;
                _checks.Children.Add(row.Row);
            }
            row.Dot.On = c.State is "pass" or "warn";
            row.Dot.Colour = c.State switch { "pass" => Alpha.Green, "warn" => Alpha.Amber, "fail" => Alpha.Red, _ => Alpha.DimColour };
            row.Value.Text = $"{c.Value}   {c.Detail}";
            row.Value.Foreground = c.State switch { "pass" => Alpha.GreenBrush, "warn" => Alpha.AmberBrush, "fail" => Alpha.RedBrush, _ => Alpha.Dim };
        }
        RefreshInsights();
    }

    int[] SafeMil()
    {
        try
        {
            var m = _hub.App.Sim.Mil();
            return [.. m.Stored];
        }
        catch { return []; }
    }

    void RefreshInsights()
    {
        var list = _hub.Insights.Events;
        _insightHead.Text = list.Count == 0
            ? "Nothing worth mentioning yet - lean under boost, injector duty, the limiter, temperatures, battery, a dead O2 line, fuel cut and VTEC are all watched."
            : $"{list.Count} event{(list.Count == 1 ? "" : "s")} from the datalog so far.";
        _insights.Children.Clear();
        foreach (var e in list.Take(40))
        {
            var colour = e.Tone switch { "danger" => Alpha.Red, "warn" => Alpha.Amber, _ => Alpha.Blue };
            var left = new StackPanel { Spacing = 0 };
            left.Children.Add(new TextBlock { Text = e.Title, FontSize = 12, FontWeight = FontWeight.SemiBold, Foreground = new SolidColorBrush(colour) });
            left.Children.Add(new TextBlock { Text = e.Detail, FontSize = 11, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap });
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*") };
            var lamp = new LedLamp { Label = e.At.ToString("HH:mm:ss"), Colour = colour, On = true, Dot = 6, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(lamp, 0); g.Children.Add(lamp);
            Grid.SetColumn(left, 1); g.Children.Add(left);
            g.Margin = new Thickness(0, 0, 0, 0);
            _insights.Children.Add(new Border
            {
                Background = Alpha.Tint(colour, 18), BorderBrush = Alpha.Tint(colour, 60), BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(5), Padding = new Thickness(8, 4), Child = g, Margin = new Thickness(0, 0, 0, 2),
            });
        }
    }
}

/// The device screen: what answered, how it is wired, the real-time settings, and the firmware.
public sealed class AlphaDevicePage : IAlphaPage
{
    readonly AlphaHub _hub;
    readonly WrapPanel _chips = new() { Orientation = Orientation.Horizontal };
    readonly TextBlock _identityLine = new() { FontSize = 11.5, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap };
    readonly WrapPanel _caps = new() { Orientation = Orientation.Horizontal };
    readonly ComboBox _transport = new() { Width = 200, FontSize = 12 };
    readonly ComboBox _port = new() { Width = 190, FontSize = 12 };
    readonly TextBox _baud = new() { Width = 90, FontSize = 12 };
    readonly TextBlock _linkState = new() { FontSize = 12, Foreground = Alpha.Ink, TextWrapping = TextWrapping.Wrap };
    readonly ToggleSwitch _autoConnect = new() { On = true };
    /// The simulated device: only when this is on does Connect talk to anything but the real emulator.
    readonly ToggleSwitch _simulate = new();
    readonly ToggleSwitch _realtime = new();
    readonly ToggleSwitch _confirmActive = new();
    readonly TextBox _delay = new() { Width = 70, FontSize = 12 };
    readonly TextBox _patchBytes = new() { Width = 80, FontSize = 12 };
    readonly TextBlock _realtimeLine = new() { FontSize = 11.5, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap };
    readonly TextBlock _firmware = new() { FontSize = 12, FontFamily = Alpha.Mono, Foreground = Alpha.Ink, TextWrapping = TextWrapping.Wrap };
    readonly ProgressBar _fwProgress = new() { Height = 6, IsVisible = false, Maximum = 100 };
    readonly StackPanel _devices = new() { Spacing = 3 };

    public string Title => "Device";
    public string Icon => "⚙";
    public Control Content { get; }

    public AlphaDevicePage(AlphaHub hub)
    {
        _hub = hub;
        _transport.ItemsSource = new List<string> { "USB serial to the emulator", "Bluetooth serial bridge" };
        _transport.SelectedIndex = (int)hub.State.Transport;
        _transport.SelectionChanged += (_, _) =>
        {
            if (_transport.SelectedIndex < 0) return;
            hub.State.Transport = (AlphaTransport)_transport.SelectedIndex;
            _hub.SaveSoon();
            RefreshPorts();
        };
        RefreshPorts();
        _baud.Text = hub.State.Baud.ToString(CultureInfo.InvariantCulture);
        _baud.LostFocus += (_, _) => { if (int.TryParse(_baud.Text, out var b)) { hub.State.Baud = b; _hub.SaveSoon(); } };
        _autoConnect.Changed += on => { hub.State.AutoConnect = on; _hub.SaveSoon(); };
        _simulate.Changed += on =>
        {
            if (on == hub.State.Simulate) return;
            // a different device: whatever link is up is closed first
            _hub.Disconnect();
            hub.State.Simulate = on;
            _hub.SaveSoon();
            _hub.Notify(on ? "the simulated ALPHA NextGEN is on: Connect talks to it, not the real emulator"
                           : "the simulated device is off: Connect goes to the real emulator");
            Refresh();
        };
        _realtime.Changed += _ => _hub.ToggleRealtime();
        _confirmActive.Changed += on => { hub.State.ConfirmActiveSlot = on; _hub.SaveSoon(); };
        _delay.Text = hub.State.RealtimeDelayMs.ToString(CultureInfo.InvariantCulture);
        _delay.LostFocus += (_, _) => { if (int.TryParse(_delay.Text, out var d)) { hub.State.RealtimeDelayMs = d; _hub.SaveSoon(); } };
        _patchBytes.Text = hub.State.MaxPatchBytes.ToString(CultureInfo.InvariantCulture);
        _patchBytes.LostFocus += (_, _) => { if (int.TryParse(_patchBytes.Text, out var p)) { hub.State.MaxPatchBytes = p; _hub.SaveSoon(); } };

        var connectRow = new WrapPanel { Orientation = Orientation.Horizontal, ItemSpacing = 8, LineSpacing = 8 };
        connectRow.Children.Add(Alpha.Primary("Connect", () => _hub.Connect(), "Open the link, read the identity and start the datalog."));
        connectRow.Children.Add(Alpha.Danger("Disconnect", () => _hub.Disconnect(), "Close the link and stop the feed."));
        connectRow.Children.Add(Alpha.Ghost("Re-read identity", () => _hub.Reconnect(), "Close and open the link, and read the identity again."));
        connectRow.Children.Add(new TextBlock { Text = "Port", VerticalAlignment = VerticalAlignment.Center, FontSize = 12 });
        connectRow.Children.Add(_port);
        connectRow.Children.Add(Alpha.Ghost("↻", RefreshPorts, "Look for serial ports again (an adapter plugged in since)."));
        connectRow.Children.Add(new TextBlock { Text = "Baud", VerticalAlignment = VerticalAlignment.Center, FontSize = 12 });
        connectRow.Children.Add(_baud);

        Content = new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Alpha.Card("Who is on the link", new StackPanel { Spacing = 5, Children = { _chips, _caps, _identityLine } }),
                Alpha.Card("Connection", new StackPanel { Spacing = 6, Children =
                {
                    Alpha.Row("Transport", _transport, 116, "How the laptop reaches the ALPHA NextGEN: its USB serial, or a Bluetooth serial bridge."),
                    connectRow,
                    new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14, Children = { _autoConnect, _linkState } },
                    _simulate,
                } }),
                Alpha.Card("Real-time update", new StackPanel { Spacing = 5, Children =
                {
                    new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14, Children = { _realtime, new TextBlock { Text = "push table edits to the running image as they happen", FontSize = 12, Foreground = Alpha.Dim, VerticalAlignment = VerticalAlignment.Center } } },
                    new WrapPanel { Orientation = Orientation.Horizontal, ItemSpacing = 8, LineSpacing = 8, Children = { Text("after a change sits still for"), _delay, Text("ms"), Text("·"), Text("biggest patch"), _patchBytes, Text("bytes"), _confirmActive } },
                    _realtimeLine,
                } }),
                Alpha.Card("Firmware", new StackPanel { Spacing = 5, Children =
                {
                    new WrapPanel { Orientation = Orientation.Horizontal, ItemSpacing = 8, LineSpacing = 8, Children =
                    {
                        Alpha.Ghost("Stage a file…", () => _ = StageFirmwareAsync(), "A firmware image to send; the device is the one that says whether it fits."),
                        Alpha.Primary("Send and apply", SendFirmware, "Stage, apply and follow the device's own progress."),
                        Alpha.Ghost("Ask for status", AskFirmwareStatus, "The device's stage, percent and version."),
                    } },
                    _fwProgress, _firmware,
                } }),
                Alpha.Card("Devices remembered", _devices, Alpha.Note("devices the plugin has talked to, with the port and firmware each used")),
            }
        };
        Refresh();
    }

    static TextBlock Text(string t) => new() { Text = t, FontSize = 11.5, Foreground = Alpha.Dim, VerticalAlignment = VerticalAlignment.Center };

    string _stagedFirmware = "";
    bool _fwBusy;

    void SendFirmware()
    {
        _fwBusy = _hub.ApplyFirmware(
            m => _hub.Ui(() => _firmware.Text = m),
            p => _hub.Ui(() => { _fwBusy = false; _stagedFirmware = ""; _fwProgress.IsVisible = p < 100; _fwProgress.Value = p; }));
        if (!_fwBusy) _fwProgress.IsVisible = false;
    }

    void AskFirmwareStatus()
        => _hub.Session.Run("firmware status", ses => ses.FirmwareStatus(true), r => _firmware.Text = r);

    void RefreshPorts()
    {
        var ports = SafePorts();
        _port.ItemsSource = ports;
        _port.SelectedIndex = _hub.State.Port.Length > 0 ? Array.IndexOf(ports, _hub.State.Port) : -1;
        if (_port.SelectedIndex < 0 && ports.Length > 0 && !_hub.State.Simulate) _port.SelectedIndex = 0;
    }

    static string[] SafePorts()
    {
        try { return SerialLink.Ports(); } catch { return []; }
    }

    async Task StageFirmwareAsync()
    {
        var top = _hub.TopLevel;
        if (top?.StorageProvider == null) return;
        var files = await top.StorageProvider.OpenFilePickerAsync(new Avalonia.Platform.Storage.FilePickerOpenOptions
        {
            Title = "Firmware image", AllowMultiple = false,
            FileTypeFilter = [new Avalonia.Platform.Storage.FilePickerFileType("Images") { Patterns = ["*.bin", "*.hex", "*.fw"] }, Avalonia.Platform.Storage.FilePickerFileTypes.All],
        });
        if (files.Count == 0) return;
        var path = files[0].Path.LocalPath;
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            var bytes = await File.ReadAllBytesAsync(path);
            _stagedFirmware = $"staged {System.IO.Path.GetFileName(path)} ({AlphaState.Bytes(bytes.Length)}) - Send and apply to write it";
            _firmware.Text = _stagedFirmware;
            _hub.FirmwareBytes = bytes;
        }
        catch (Exception ex) { _hub.Notify("Could not read that file: " + ex.Message); }
    }

    public void Refresh()
    {
        var s = _hub.Session;
        var id = s.Identity;
        _chips.Children.Clear();
        _caps.Children.Clear();
        if (id == null)
        {
            _chips.Children.Add(Alpha.Badge("NOT LINKED", Alpha.DimColour, "connect the emulator to read its identity"));
            _identityLine.Text = "Nothing is linked. " + s.Status;
        }
        else
        {
            _chips.Children.Add(Chip("device", id.Kind, Alpha.Cyan));
            _chips.Children.Add(Chip("serial", id.DeviceId, Alpha.Blue));
            _chips.Children.Add(Chip("firmware", id.Firmware, Alpha.Green));
            _chips.Children.Add(Chip("protocol", id.Protocol, Alpha.Teal));
            _chips.Children.Add(Chip("image", AlphaState.Bytes(id.RomSize), Alpha.Sky));
            _chips.Children.Add(Chip("slots", id.SlotCount.ToString(CultureInfo.InvariantCulture), Alpha.Purple));
            _chips.Children.Add(Chip("live", id.ActiveSlot.ToString(CultureInfo.InvariantCulture), Alpha.Amber));
            _chips.Children.Add(Chip("target", id.TargetSlot.ToString(CultureInfo.InvariantCulture), Alpha.Orange));
            foreach (var cap in id.Capabilities) _caps.Children.Add(Alpha.Badge(cap, Alpha.Teal, "the device says it can do this"));
            var r = id.Registration;
            _identityLine.Text = $"identity: {r} · source {r.Source}"
                               + (r.CertificateId.Length > 0 ? $" · certificate {r.CertificateId}" : "")
                               + (r.ExpiresAt.Length > 0 ? $" · to {r.ExpiresAt}" : "")
                               + " · the plugin reports what the hardware says; it does not switch features off on you.";
        }
        _linkState.Text = $"{s.Phase} - {s.Status}";
        _linkState.Foreground = s.Phase switch { AlphaLinkPhase.Logging => Alpha.GreenBrush, AlphaLinkPhase.Linked => Alpha.CyanBrush,
            AlphaLinkPhase.Faulted => Alpha.RedBrush, AlphaLinkPhase.Reconnecting or AlphaLinkPhase.Connecting => Alpha.AmberBrush, _ => Alpha.Dim };
        if (_transport.SelectedIndex != (int)_hub.State.Transport) _transport.SelectedIndex = (int)_hub.State.Transport;
        _realtime.On = s.RealtimeEnabled;
        _confirmActive.On = _hub.State.ConfirmActiveSlot;
        _confirmActive.LabelText = "ask before writing the slot that is running";
        _autoConnect.On = _hub.State.AutoConnect;
        _simulate.On = _hub.State.Simulate;
        _simulate.LabelText = _hub.State.Simulate ? "simulated ALPHA NextGEN - ON: Connect talks to it, not the real emulator"
                                                  : "simulated ALPHA NextGEN (no hardware) - off: Connect goes to the real emulator";
        _autoConnect.LabelText = "connect on start-up and when a ROM is opened";
        _realtimeLine.Text = s.Synced
            ? $"armed against the image in the emulator · {s.PatchesSent:N0} patch event{(s.PatchesSent == 1 ? "" : "s")}, {s.PatchBytesSent:N0} bytes sent · "
              + $"delay {_hub.State.RealtimeDelayMs} ms, biggest patch {_hub.State.MaxPatchBytes:N0} bytes"
            : "no baseline yet: the plugin takes one from the emulator's running image the first time it is asked to patch, "
              + "or you can deploy a slot to put this calibration in there and sync it.";
        // a page that repaints at 300 ms must not put a status command on the wire every tick, must not
        // wait on a serial timeout on the UI thread, and must not scribble over an apply in progress
        if (!_fwBusy)
        {
            string fw = s.Phase is AlphaLinkPhase.Linked or AlphaLinkPhase.Logging ? s.FirmwareStatusCached() : "not linked";
            _firmware.Text = (_stagedFirmware.Length > 0 ? _stagedFirmware + "  ·  " : "") + fw;
        }
        _devices.Children.Clear();
        foreach (var d in _hub.State.Devices.Values.OrderByDescending(d => d.LastSeen))
            _devices.Children.Add(new TextBlock
            {
                Text = $"{d.Kind} · {d.DeviceId} · {(d.Port.Length > 0 ? d.Port + " at " + d.Baud : "no port")} · fw {d.Firmware} · "
                     + $"{AlphaState.Bytes(d.RomSize)} · {d.SlotCount} slots · {d.Registration} · seen {d.LastSeen:yyyy-MM-dd HH:mm}",
                FontSize = 11, FontFamily = Alpha.Mono, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap,
            });
        if (_hub.State.Devices.Count == 0) _devices.Children.Add(Alpha.Note("none yet"));
    }

    static Border Chip(string label, string value, Color colour)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
        sp.Children.Add(new TextBlock { Text = label.ToUpperInvariant(), FontSize = 8.5, LetterSpacing = 1, Foreground = Alpha.Dim });
        sp.Children.Add(new TextBlock { Text = value, FontSize = 11.5, FontFamily = Alpha.Mono, Foreground = new SolidColorBrush(colour), FontWeight = FontWeight.SemiBold });
        return new Border
        {
            Background = Alpha.Tint(colour, 18), BorderBrush = Alpha.Tint(colour, 60), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(5), Padding = new Thickness(7, 2), Margin = new Thickness(0, 0, 5, 3), Child = sp,
        };
    }
}

/// The session log: everything the link sent and answered, and everything the plugin decided.
public sealed class AlphaLogPage : IAlphaPage
{
    readonly AlphaHub _hub;
    readonly TextBox _text = new() { IsReadOnly = true, AcceptsReturn = true, FontFamily = Alpha.Mono, FontSize = 11, MinHeight = 420, TextWrapping = TextWrapping.NoWrap };

    public string Title => "Log";
    public string Icon => "≡";
    public Control Content { get; }

    public AlphaLogPage(AlphaHub hub)
    {
        _hub = hub;
        Content = Alpha.Card("Session log", new StackPanel { Spacing = 6, Children = { _text } },
            Alpha.Ghost("Copy", () => { if (TopLevel.GetTopLevel(_text) is { } t) _ = t.Clipboard?.SetTextAsync(_text.Text); }, "Everything here, on the clipboard."),
            Alpha.Ghost("Save…", () => _hub.SaveLog(_text.Text ?? ""), "Write the log to a file you can attach to a report."));
    }

    public void Refresh()
    {
        string log = _hub.Session.LogText();
        if (log != _text.Text) { _text.Text = log; }
    }
}


