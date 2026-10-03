// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// The check-engine lamp as the ROM drives it: the dash lamp and the code-flash line live, the codes the flashes decode to, the codes the ROM has stored (what it will flash) and the faults it is detecting right now - with the service check jumper and a backup-fuse clear.
public sealed class MilWindow : Window
{
    readonly SimHost _host;
    readonly Action<bool>? _setScc;
    /// Puts lines into the ROM's source (file, line -> new text); null when the ROM has no source open.
    readonly Func<string, Dictionary<int, string>, bool>? _editSource;
    readonly Ellipse _lamp = new() { Width = 34, Height = 34, StrokeThickness = 2, Stroke = Brushes.DimGray };
    readonly Ellipse _led = new() { Width = 14, Height = 14, StrokeThickness = 1, Stroke = Brushes.DimGray };
    readonly TextBlock _state = new() { FontSize = 13, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap };
    readonly TextBlock _flashing = new() { FontSize = 12, Opacity = 0.8, TextWrapping = TextWrapping.Wrap };
    readonly CheckBox _scc = new() { Content = "Service check connector jumped", FontSize = 12 };
    readonly StackPanel _flashed = new(), _stored = new(), _current = new();
    readonly TextBlock _storedHead = Head(""), _currentHead = Head("");
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(120) };
    string _last = "";
    bool _syncing;

    static readonly IBrush LampOn = AppTheme.Brush(Color.FromRgb(0xFF, 0xA0, 0x10));
    static readonly IBrush LedOn = AppTheme.Brush(Color.FromRgb(0xFF, 0x30, 0x30));
    static readonly IBrush Off = AppTheme.Brush(Color.FromArgb(0x40, 0x80, 0x80, 0x80));

    public MilWindow(SimHost host, Action<bool>? setScc, Func<string, Dictionary<int, string>, bool>? editSource = null)
    {
        _host = host; _setScc = setScc; _editSource = editSource;
        Title = "Check engine (MIL)";
        Width = 520; Height = 600; MinWidth = 420; MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        ToolTip.SetTip(_lamp, "The dash check-engine lamp (P28 P1.4, P13 8255 PC3): on while a code is stored, after the 2 s bulb check at key-on. With the service check connector jumped it flashes the codes.");
        ToolTip.SetTip(_led, "The code-flash line (P28 P1.5, the LED on the ECU board; P13 8255 PC4): flashes the stored codes all the time.");
        ToolTip.SetTip(_scc, "Jump the service check connector (P28 8255 port A bit 7, pin D4): the dash lamp then flashes the codes. Long flashes are tens, short ones units.");
        _scc.IsCheckedChanged += (_, _) => { if (!_syncing) _setScc?.Invoke(_scc.IsChecked == true); };

        var clear = new Button { Content = "Clear codes (backup fuse)", Margin = new Thickness(0, 0, 8, 0) };
        ToolTip.SetTip(clear, "What pulling the backup fuse does: the ECU loses its RAM, stored codes with it, and starts again from reset. The inputs stay as they are.");
        clear.Click += (_, _) => { bool run = _host.IsRunning; _host.Control("reset"); if (run) _host.Control("run"); };

        var lampRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        lampRow.Children.Add(_lamp);
        lampRow.Children.Add(new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { new TextBlock { Text = "CHECK ENGINE", FontWeight = FontWeight.Bold, FontSize = 12 }, new TextBlock { Text = "dash lamp", FontSize = 10, Opacity = 0.7 } } });
        lampRow.Children.Add(new Border { Width = 18 });
        lampRow.Children.Add(_led);
        lampRow.Children.Add(new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { new TextBlock { Text = "ECU LED", FontWeight = FontWeight.Bold, FontSize = 12 }, new TextBlock { Text = "code-flash line", FontSize = 10, Opacity = 0.7 } } });

        var body = new StackPanel { Margin = new Thickness(14, 10), Spacing = 6 };
        body.Children.Add(lampRow);
        body.Children.Add(_state);
        body.Children.Add(_flashing);
        body.Children.Add(new WrapPanel { Children = { clear, _scc } });
        body.Children.Add(Head("Flashed by the lamp"));
        body.Children.Add(_flashed);
        body.Children.Add(_storedHead);
        body.Children.Add(_stored);
        body.Children.Add(_currentHead);
        body.Children.Add(_current);
        body.Children.Add(new TextBlock
        {
            Text = "Codes follow the ROM's own numbering: a fault bit is stored as index n and flashed as code n+1 " +
                   "(except 25→35, 26→36, 27→41, 29→43). Stored codes stay until the backup fuse is pulled.",
            FontSize = 10.5, Opacity = 0.65, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0),
        });
        // the dark title bar the other windows have, instead of the system's white one
        var chrome = DarkChrome.Apply(this, Title);
        var root = new DockPanel();
        DockPanel.SetDock(chrome, Dock.Top);
        root.Children.Add(chrome);
        root.Children.Add(new ScrollViewer { Content = body });
        Content = root;

        _timer.Tick += (_, _) => Refresh();
        Opened += (_, _) => { Refresh(); _timer.Start(); };
        Closed += (_, _) => _timer.Stop();
    }

    static TextBlock Head(string text) => new() { Text = text, FontWeight = FontWeight.SemiBold, FontSize = 12.5, Margin = new Thickness(0, 8, 0, 0) };

    Control Row(int code, string detail, bool canDisable = false)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("44,*,Auto") };
        var c = new TextBlock { Text = code.ToString(), FontFamily = MainWindow.MonoFont, FontSize = 14, FontWeight = FontWeight.Bold };
        var d = new TextBlock { Text = MilMonitor.Name(code) + (detail.Length > 0 ? "   " + detail : ""), FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        Grid.SetColumn(d, 1);
        g.Children.Add(c); g.Children.Add(d);
        if (canDisable)
        {
            var off = new Button { Content = "Hard disable…", FontSize = 11, Padding = new Thickness(6, 1), Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            ToolTip.SetTip(off, $"Take code {code} out of the ROM's code: every instruction that sets its fault bit becomes NOPs of the same length, so the check runs " +
                                "but can never set the fault. Unlike switching the code off on the error codes page, nothing in the calibration can bring it back.");
            off.Click += async (_, _) => await HardDisable(code);
            Grid.SetColumn(off, 2);
            g.Children.Add(off);
        }
        return g;
    }

    /// Take a trouble code out of the code: the sites that set its bits, shown first, then NOPs in the running ROM and, when the ROM has its source open, in the source lines too.
    async Task HardDisable(int code)
    {
        var v = _host.Mil();
        var rom = _host.RomCopy();
        var map = _host.Assembly?.SourceMap.Select(e => (e.Address, e.Length, e.File, e.Line)).ToList();
        var sites = FaultDisable.BitsFor(code).SelectMany(b => FaultDisable.Find(rom, v.FieldBase, b, map)).DistinctBy(s => s.Address).ToList();
        if (sites.Count == 0)
        {
            await Dialogs.Ask(this, "Hard disable", $"Nothing in this ROM's code sets code {code}'s fault bit with an MB or SB instruction, so there is nothing to take out.", "OK");
            return;
        }
        string list = string.Join("\n", sites.Select(s => $"  {s.Address:X4}h  {s.What}" + (s.File != null ? $"   ({System.IO.Path.GetFileName(s.File)} line {s.Line})" : "")));
        if (!await Dialogs.Confirm(this, $"Hard disable code {code}?",
                $"Code {code} ({MilMonitor.Name(code)}) is set by {sites.Count} instruction(s):\n\n{list}\n\n" +
                "Each becomes three NOPs: the check still runs, but can never set the fault, and the lamp never comes on for it. " +
                (_editSource != null && sites.Any(s => s.File != null) ? "The source lines are changed to match (marked 'hard-disabled'), so a rebuild keeps it. " : "Save the ROM to keep it. ") +
                "Undo (Ctrl+Z) puts the bytes back.", "Disable it", "Cancel")) return;
        _host.ApplyPatches(FaultDisable.Patches(sites), $"hard-disable trouble code {code}");
        // the bit as it stands now goes too: nothing will set it again
        foreach (var b in FaultDisable.BitsFor(code))
        {
            int at = v.FieldBase + (b / 8);
            byte now = _host.Sim.Bus.Ram[at];
            _host.WriteRam(at, (byte)(now & ~(1 << (b % 8))));
        }
        if (_editSource != null)
            foreach (var byFile in sites.Where(s => s.File != null).GroupBy(s => s.File!))
                _editSource(byFile.Key, byFile.ToDictionary(s => s.Line, s => FaultDisable.SourceLine(s, code)));
        AppLog.Action("mil", $"code {code} hard-disabled: {sites.Count} instruction(s) at {string.Join(", ", sites.Select(s => s.Address.ToString("X4") + "h"))}");
        _last = "";
        Refresh();
    }

    static TextBlock None(string text) => new() { Text = text, FontSize = 12, Opacity = 0.6 };

    void Refresh()
    {
        var v = _host.Mil();
        _lamp.Fill = v.Lamp ? LampOn : Off;
        _led.Fill = v.Flash ? LedOn : Off;
        _syncing = true; _scc.IsChecked = v.Scc; _scc.IsEnabled = _setScc != null && !Bus.Is66911; _syncing = false;
        _state.Text = !_host.IsRunning ? "Simulator paused" + (v.Stored.Count > 0 ? $" - {v.Stored.Count} code(s) stored" : "")
            : v.Stored.Count == 0 ? (v.Lamp ? "Lamp on (bulb check)" : "No codes stored")
            : v.Scc ? "Flashing the stored codes" : "Lamp on: code(s) stored - jump the service check connector to read them on the dash";
        _flashing.Text = v.Flashing is (int t, int u) ? $"Flashing now: {t} long, {u} short so far" : "";

        // rebuild the lists only when something in them changed
        string key = string.Join(",", v.LastRound) + "|" + string.Join(",", v.CurrentRound) + "|" + string.Join(",", v.Stored) + "|" +
                     string.Join(",", v.Current.Select(c => c.Bit)) + "|" + v.StoredAt + v.FieldBase;
        if (key == _last) return;
        _last = key;

        _flashed.Children.Clear();
        var round = v.LastRound.Count > 0 ? v.LastRound : v.CurrentRound;
        if (round.Count == 0) _flashed.Children.Add(None("nothing decoded yet (a round of flashes takes a few seconds per code)"));
        foreach (var c in round) _flashed.Children.Add(Row(c, ""));
        if (v.LastRound.Count == 0 && v.CurrentRound.Count > 0) _flashed.Children.Add(None("(first round still under way)"));

        _storedHead.Text = v.StoredAt is int at ? $"Stored in the ECU (RAM {at:X3}h)" : "Stored in the ECU (array not found in this ROM)";
        _stored.Children.Clear();
        if (v.Stored.Count == 0) _stored.Children.Add(None("none"));
        foreach (var c in v.Stored) _stored.Children.Add(Row(c, "", canDisable: true));

        _currentHead.Text = $"Detected right now (fault field {v.FieldBase:X2}h)";
        _current.Children.Clear();
        if (v.Current.Count == 0) _current.Children.Add(None("none"));
        foreach (var (bit, c) in v.Current) _current.Children.Add(Row(c, $"(bit {bit}: {v.FieldBase + bit / 8:X2}h.{bit % 8})", canDisable: true));
    }
}
