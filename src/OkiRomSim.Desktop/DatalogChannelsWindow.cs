// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Calibration;

namespace OkiRomSim.Desktop;

/// Datalog > Channels…: what the channel stream (the skeleton ROM's datalog module) sends, and what it sends back to the ECU's serial inputs. A box for everything it can log, grouped; untick what the car does not have (no A/C, no knock sensor...) so the frames stay short and fast, and mark the ones that change slowly (temperatures, battery, codes) slow: they take turns, one a frame, instead of riding in every frame. A version 4 ROM takes any number; an older one 16 bytes (8 on version 1, which also cannot send the status bytes).
public sealed class DatalogChannelsWindow : Window
{
    const int OldMost = 16;
    readonly Dictionary<string, (CheckBox On, CheckBox Slow)> _boxes = new(StringComparer.OrdinalIgnoreCase);
    readonly TextBlock _count = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0), TextWrapping = TextWrapping.Wrap, MaxWidth = 330 };
    readonly List<InputRow> _inputs = [];
    readonly ChannelStream? _live;
    public List<string>? Result { get; private set; }
    public List<SerialInputMap>? Inputs { get; private set; }

    sealed record InputRow(CheckBox On, NumericUpDown Input, AutoCompleteBox Channel, NumericUpDown Scale, NumericUpDown Offset);

    public DatalogChannelsWindow(IEnumerable<string> selected, IEnumerable<string> inputs, ChannelStream? live, IEnumerable<string> channelNames)
    {
        _live = live;
        Title = "Datalog channels";
        Width = 640; Height = 720; MinWidth = 480; MinHeight = 440;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var chrome = DarkChrome.Apply(this, "Datalog channels");
        var picks = DatalogChannels.Picks(selected).ToDictionary(p => p.Channel.Key, p => p.Slow, StringComparer.OrdinalIgnoreCase);

        var list = new StackPanel { Margin = new Thickness(12, 6) };
        list.Children.Add(new TextBlock
        {
            Text = "The channel stream sends only the channels ticked here, so a frame stays short and the log fast. Untick what the car " +
                   "does not have or you do not need. A channel marked slow is not in every frame: the slow ones take turns, one a frame, " +
                   "which suits what changes slowly (temperatures, battery, codes) and leaves the frames short for rpm, load and throttle. " +
                   "Rpm, injector time and the other two-byte values are read in one go and always come in every frame. " +
                   "A ROM with an older datalog module takes 16 bytes and sends every channel in every frame.",
            TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.8, Margin = new Thickness(0, 0, 0, 8),
        });
        // a search box: there are over a hundred channels with the every-channel module
        var search = new TextBox { Watermark = "search the channels (knock, idle, limit, VTEC...)", Margin = new Thickness(0, 0, 0, 4) };
        list.Children.Add(search);
        var rows = new List<(Control Row, Control Head, DatalogChannel Ch)>();
        search.TextChanged += (_, _) =>
        {
            var q = (search.Text ?? "").Trim();
            foreach (var (row, _, ch) in rows)
                row.IsVisible = q.Length == 0 || ch.Name.Contains(q, StringComparison.OrdinalIgnoreCase) || ch.Group.Contains(q, StringComparison.OrdinalIgnoreCase)
                                || ch.Key.Contains(q, StringComparison.OrdinalIgnoreCase) || ch.Description.Contains(q, StringComparison.OrdinalIgnoreCase);
            foreach (var g in rows.GroupBy(r => r.Head)) g.Key.IsVisible = g.Any(r => r.Row.IsVisible);
        };
        foreach (var group in DatalogChannels.All.GroupBy(c => c.Group))
        {
            var headText = new TextBlock { Text = group.Key.ToUpperInvariant(), FontSize = 10.5, FontWeight = FontWeight.Bold, Opacity = 0.7, Margin = new Thickness(0, 8, 0, 2) };
            list.Children.Add(headText);
            foreach (var c in group)
            {
                var text = c.Name + (c.Unit.Length > 0 ? $"  ({c.Unit})" : "") + (c.Bytes > 1 ? $"  - {c.Bytes} bytes" : "") +
                           (c.Numbers.Any(n => n >= DatalogChannels.TableSize) ? "  (every-channel module)" : c.MinVersion >= 4 ? "  (v4)" : c.NeedsVersion2 ? "  (v2)" : "");
                // connected: what this ROM's table cannot send is shown as such (it can still be ticked for another ROM)
                bool missing = live is { TableSize: > 0 } lv && c.Numbers.Any(n => n >= lv.TableSize);
                if (missing) text += "  - not in the ROM connected";
                // a function's state: which function's, and what (from the ROM built here)
                if (c.Key.StartsWith("mod") && int.TryParse(c.Key[3..], out int mo)) text = $"+{mo}  {ModuleDebug.Label(mo)}" + (missing ? "  - not in the ROM connected" : "");
                // a RAM address of your own: which address, and what is there
                if (c.Key.StartsWith("ram") && int.TryParse(c.Key[3..], out int ru)) text = $"{c.Name}: {UserRam.Label(ru - 1)}" + (missing ? "  - not in the ROM connected" : "");
                var on = new CheckBox { Content = new TextBlock { Text = text, FontSize = 12, Opacity = missing ? 0.5 : 1 }, IsChecked = picks.ContainsKey(c.Key), Margin = new Thickness(6, 0), MinWidth = 380 };
                var slow = new CheckBox
                {
                    Content = new TextBlock { Text = "slow", FontSize = 11.5 }, IsChecked = picks.TryGetValue(c.Key, out var s) && s,
                    IsEnabled = !c.Word && on.IsChecked == true, VerticalAlignment = VerticalAlignment.Center,
                };
                ToolTip.SetTip(on, (c.Description.Length > 0 ? c.Description + "\n" : "") + "Channel " + string.Join(", ", c.Numbers) +
                                   (c.Addresses.Any(a => a is > 0 and < 0xFF00) ? ", RAM " + string.Join(", ", c.Addresses.Select(a => a >= 0xFF00 || a == 0 ? "-" : $"{a:X3}h")) : ""));
                ToolTip.SetTip(slow, c.Word ? "A two-byte value: always in every frame, so its bytes are one reading."
                                            : "In turn with the other slow channels, one a frame, instead of in every frame.");
                on.IsCheckedChanged += (_, _) => { slow.IsEnabled = !c.Word && on.IsChecked == true; Count(); };
                slow.IsCheckedChanged += (_, _) => Count();
                _boxes[c.Key] = (on, slow);
                var row = new DockPanel();
                DockPanel.SetDock(slow, Dock.Right);
                row.Children.Add(slow);
                row.Children.Add(on);
                list.Children.Add(row);
                rows.Add((row, headText, c));
            }
        }

        // ---------------------------------------------------------------- serial inputs: what goes to the ECU
        list.Children.Add(new TextBlock { Text = "SEND TO THE ECU (SERIAL INPUTS)", FontSize = 10.5, FontWeight = FontWeight.Bold, Opacity = 0.7, Margin = new Thickness(0, 16, 0, 2) });
        list.Children.Add(new TextBlock
        {
            Text = "The cable works both ways: with the serial inputs module in the ROM, values from this log go to the ECU while it " +
                   "streams (20 times a second) and its modules use them as extra inputs. Each row: the input number the ROM listens for " +
                   "(its Serial inputs page keeps eight, as serial input 1-8), the log channel the value comes from, and value = channel x " +
                   "scale + offset, held to 0-254 - the wideband's afr x 10 sends 14.7 as 147. In the ROM, closed loop, lean protection and " +
                   "flex fuel can read a serial input as their analog input, and any module's switch input can be one (on while not 0). " +
                   "Stop logging and after the ROM's timeout every input goes back to its default." +
                   (live is { Version: >= 4 } ? live.HasSerialInputs ? "" : "\nThe ROM connected now has no serial inputs: these are not sent." : ""),
            TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.8, Margin = new Thickness(0, 0, 0, 6),
        });
        var names = channelNames.Concat(["afr", "lambda"]).Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase).ToList();
        var saved = inputs.Select(SerialInputMap.Parse).OfType<SerialInputMap>().ToList();
        var head = new Grid { ColumnDefinitions = new ColumnDefinitions("40,90,*,90,90"), Margin = new Thickness(6, 0) };
        string[] heads = ["on", "input", "from channel", "scale", "offset"];
        for (int i = 0; i < heads.Length; i++)
        {
            var t = new TextBlock { Text = heads[i], FontSize = 10.5, Opacity = 0.65 };
            Grid.SetColumn(t, i); head.Children.Add(t);
        }
        list.Children.Add(head);
        for (int k = 0; k < 8; k++)
        {
            var m = k < saved.Count ? saved[k] : null;
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("40,90,*,90,90"), Margin = new Thickness(6, 1) };
            var on = new CheckBox { IsChecked = m?.Enabled == true, VerticalAlignment = VerticalAlignment.Center };
            var input = new NumericUpDown { Minimum = 0, Maximum = 253, Increment = 1, Value = m?.Input ?? k, FormatString = "0", Width = 84, FontSize = 11.5 };
            var ch = new AutoCompleteBox
            {
                ItemsSource = names, Text = m?.Channel ?? "", MinimumPrefixLength = 0, FilterMode = AutoCompleteFilterMode.Contains,
                Watermark = "a channel (afr, an aux channel...)", Margin = new Thickness(4, 0), FontSize = 11.5,
            };
            ch.GotFocus += (_, _) => { if (string.IsNullOrEmpty(ch.Text)) ch.IsDropDownOpen = true; };
            var scale = new NumericUpDown { Minimum = -1000, Maximum = 1000, Increment = 0.1M, Value = (decimal)(m?.Scale ?? 1), FormatString = "0.###", Width = 84, FontSize = 11.5 };
            var offset = new NumericUpDown { Minimum = -1000, Maximum = 1000, Increment = 1, Value = (decimal)(m?.Offset ?? 0), FormatString = "0.###", Width = 84, FontSize = 11.5 };
            ToolTip.SetTip(input, "The input's number as the ROM's Serial inputs page keeps it (0-253).");
            ToolTip.SetTip(ch, "The channel of each frame the value comes from: the wideband's afr or lambda, an aux channel, any logged value.");
            Control[] cells = [on, input, ch, scale, offset];
            for (int i = 0; i < cells.Length; i++) { Grid.SetColumn(cells[i], i); row.Children.Add(cells[i]); }
            list.Children.Add(row);
            _inputs.Add(new InputRow(on, input, ch, scale, offset));
        }

        Button B(string text, Action a, string tip)
        {
            var b = new Button { Content = text, MinWidth = 84 };
            b.Click += (_, _) => a();
            ToolTip.SetTip(b, tip);
            return b;
        }
        var ok = B("OK", () => { Result = [.. Chosen()]; Inputs = [.. ChosenInputs()]; Close(); },
            "Use these channels: while logging the ECU is sent them at once (no reconnect); otherwise from the next connect.");
        ok.IsDefault = true;
        var cancel = B("Cancel", Close, "Leave the channels as they were.");
        cancel.IsCancel = true;
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        bar.Children.Add(B("Defaults", () => Set(DatalogChannels.Defaults), "Rpm, MAP, throttle and road speed; coolant, intake air and battery slow."));
        bar.Children.Add(B("None", () => Set([]), "Untick everything."));
        bar.Children.Add(B("Everything", () => Set(DatalogChannels.Everything(DatalogChannels.TableSizeAll)),
            "Every channel: rpm, MAP, throttle, injector time, advance, speed, the cut and limiter states every frame, the rest slow, in turn. " +
            "The channels past 52 need the ROM built with Datalogging: every channel; a ROM without it sends what it has."));
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Right };
        right.Children.Add(cancel); right.Children.Add(ok);
        var buttons = new DockPanel();
        DockPanel.SetDock(right, Dock.Right);
        buttons.Children.Add(right); buttons.Children.Add(bar);
        // what a frame carries on a line of its own, the buttons under it
        _count.MaxWidth = double.PositiveInfinity;
        _count.Margin = new Thickness(0, 0, 0, 6);
        var foot = new StackPanel { Margin = new Thickness(12, 6, 12, 12) };
        foot.Children.Add(_count);
        foot.Children.Add(buttons);

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto") };
        var scroll = new ScrollViewer { Content = list, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(scroll, 1); g.Children.Add(scroll);
        Grid.SetRow(foot, 2); g.Children.Add(foot);
        Content = g;
        Count();
    }

    IEnumerable<string> Chosen() => DatalogChannels.All.Where(c => _boxes[c.Key].On.IsChecked == true)
        .Select(c => DatalogChannels.Pick(c.Key, !c.Word && _boxes[c.Key].Slow.IsChecked == true));

    IEnumerable<SerialInputMap> ChosenInputs() => _inputs
        .Where(r => !string.IsNullOrWhiteSpace(r.Channel.Text))
        .Select(r => new SerialInputMap((int)(r.Input.Value ?? 0), r.Channel.Text!.Trim(), (double)(r.Scale.Value ?? 1), (double)(r.Offset.Value ?? 0), r.On.IsChecked == true));

    void Set(IEnumerable<string> picks)
    {
        var want = DatalogChannels.Picks(picks).ToDictionary(p => p.Channel.Key, p => p.Slow, StringComparer.OrdinalIgnoreCase);
        foreach (var (k, b) in _boxes)
        {
            b.On.IsChecked = want.ContainsKey(k);
            b.Slow.IsChecked = want.TryGetValue(k, out var s) && s;
        }
        Count();
    }

    /// What one frame carries and how fast frames come (version 4); and against the 16 bytes an older ROM takes.
    void Count()
    {
        var picks = DatalogChannels.Picks(Chosen());
        var (fps, slowEvery) = DatalogChannels.Rate(picks);
        int all = picks.Sum(p => p.Channel.Bytes);
        _count.Text = $"{DatalogChannels.FrameBytes(picks)} bytes a frame, about {fps:0} frames a second" +
                      (slowEvery > 0 ? $"; each slow one every {(slowEvery < 1 ? $"{slowEvery * 1000:0} ms" : $"{slowEvery:0.0} s")}" : "");
        if (_live is { Version: > 0 and < 4 } && all > OldMost) _count.Foreground = Brushes.OrangeRed;
        else _count.ClearValue(TextBlock.ForegroundProperty);
        ToolTip.SetTip(_count, (all > OldMost ? $"An older ROM (datalog version 3 or less) takes {OldMost} bytes and sends all of them in every frame: " +
                                                $"{all - OldMost} byte(s) would be left out, the slow ones first.\n" : "") +
                               $"The ECU sends about {DatalogChannels.EcuBytesPerSecond:0} bytes a second (it holds its serial interrupt off while its crank task runs), " +
                               "so a shorter frame is more frames. A frame is A5h, the ECU's tick (two bytes), the fast channels, " +
                               "the slow channel's number and byte, and a checksum.");
    }
}
