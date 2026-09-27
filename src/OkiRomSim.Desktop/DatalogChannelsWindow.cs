// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Calibration;

namespace OkiRomSim.Desktop;

/// Datalog > Channels…: what the channel stream (the skeleton ROM's datalog module) sends. A box for everything it can log, grouped; untick what the car does not have (no A/C, no knock sensor...) so the frames stay short and fast. The ROM takes 16 bytes of channels (8 on a version-1 ROM, which also cannot send the status bytes).
public sealed class DatalogChannelsWindow : Window
{
    const int Most = 16;
    readonly Dictionary<string, CheckBox> _boxes = new(StringComparer.OrdinalIgnoreCase);
    readonly TextBlock _count = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
    public List<string>? Result { get; private set; }

    public DatalogChannelsWindow(IEnumerable<string> selected)
    {
        Title = "Datalog channels";
        Width = 560; Height = 640; MinWidth = 420; MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var chrome = DarkChrome.Apply(this, "Datalog channels");
        var chosen = new HashSet<string>(selected, StringComparer.OrdinalIgnoreCase);

        var list = new StackPanel { Margin = new Thickness(12, 6) };
        list.Children.Add(new TextBlock
        {
            Text = "The channel stream sends only the channels ticked here, so a frame stays short and the log fast. Untick what the car " +
                   "does not have or you do not need. The ROM takes 16 bytes of channels (rpm, injector time, idle valve duty and fuel trim " +
                   "take two); a ROM with the older datalog module takes 8 and cannot send the ones marked (v2).",
            TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.8, Margin = new Thickness(0, 0, 0, 8),
        });
        foreach (var group in DatalogChannels.All.GroupBy(c => c.Group))
        {
            list.Children.Add(new TextBlock { Text = group.Key.ToUpperInvariant(), FontSize = 10.5, FontWeight = FontWeight.Bold, Opacity = 0.7, Margin = new Thickness(0, 8, 0, 2) });
            foreach (var c in group)
            {
                var text = c.Name + (c.Unit.Length > 0 ? $"  ({c.Unit})" : "") + (c.Bytes > 1 ? $"  - {c.Bytes} bytes" : "") + (c.NeedsVersion2 ? "  (v2)" : "");
                var cb = new CheckBox { Content = new TextBlock { Text = text, FontSize = 12 }, IsChecked = chosen.Contains(c.Key), Margin = new Thickness(6, 0) };
                ToolTip.SetTip(cb, (c.Description.Length > 0 ? c.Description + "\n" : "") + "RAM " + string.Join(", ", c.Addresses.Select(a => a >= 0xFF00 ? "status byte" : $"{a:X3}h")));
                cb.IsCheckedChanged += (_, _) => Count();
                _boxes[c.Key] = cb;
                list.Children.Add(cb);
            }
        }

        Button B(string text, Action a, string tip)
        {
            var b = new Button { Content = text, MinWidth = 84 };
            b.Click += (_, _) => a();
            ToolTip.SetTip(b, tip);
            return b;
        }
        var ok = B("OK", () => { Result = [.. Chosen()]; Close(); }, "Use these channels: the stream asks for them the next time it connects.");
        ok.IsDefault = true;
        var cancel = B("Cancel", Close, "Leave the channels as they were.");
        cancel.IsCancel = true;
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(12, 6, 12, 12) };
        bar.Children.Add(_count);
        bar.Children.Add(B("Defaults", () => Set(DatalogChannels.Defaults), "Rpm, MAP, throttle, coolant, intake air, battery and road speed."));
        bar.Children.Add(B("None", () => Set([]), "Untick everything."));
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Right };
        right.Children.Add(cancel); right.Children.Add(ok);
        var foot = new DockPanel();
        DockPanel.SetDock(right, Dock.Right);
        foot.Children.Add(right); foot.Children.Add(bar);

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto") };
        var scroll = new ScrollViewer { Content = list, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(scroll, 1); g.Children.Add(scroll);
        Grid.SetRow(foot, 2); g.Children.Add(foot);
        Content = g;
        Count();
    }

    IEnumerable<string> Chosen() => DatalogChannels.All.Where(c => _boxes[c.Key].IsChecked == true).Select(c => c.Key);

    void Set(IEnumerable<string> keys)
    {
        var set = new HashSet<string>(keys, StringComparer.OrdinalIgnoreCase);
        foreach (var (k, cb) in _boxes) cb.IsChecked = set.Contains(k);
        Count();
    }

    /// The bytes ticked against the 16 the ROM takes; past that, the rest are left out in list order.
    void Count()
    {
        int bytes = DatalogChannels.All.Where(c => _boxes.TryGetValue(c.Key, out var cb) && cb.IsChecked == true).Sum(c => c.Bytes);
        _count.Text = $"{bytes} of {Most} bytes";
        _count.Foreground = bytes > Most ? Brushes.OrangeRed : null;
        ToolTip.SetTip(_count, bytes > Most ? $"More than the ROM takes: the last {bytes - Most} byte(s) in list order are left out." : "What one frame carries.");
    }
}
