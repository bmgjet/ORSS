// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Where a link to the car stands: not connected (red), connected (green), or lost and being got back (orange, blinking).
public enum LinkState { Off, Connected, Reconnecting }

/// A coloured dot for a link's state, beside the menu that drives it (Emulator, Datalogging).
public sealed class StatusDot : Control
{
    static readonly IBrush Red = new SolidColorBrush(Color.FromRgb(0xe0, 0x44, 0x3c));
    static readonly IBrush Green = new SolidColorBrush(Color.FromRgb(0x3c, 0xd0, 0x5a));
    static readonly IBrush Orange = new SolidColorBrush(Color.FromRgb(0xff, 0x9a, 0x1f));
    readonly DispatcherTimer _blink = new() { Interval = TimeSpan.FromMilliseconds(450) };
    bool _lit = true;

    public StatusDot()
    {
        Width = Height = 10;
        VerticalAlignment = VerticalAlignment.Center;
        _blink.Tick += (_, _) => { _lit = !_lit; InvalidateVisual(); };
    }

    public LinkState State
    {
        get;
        set
        {
            if (field == value) return;
            field = value;
            _lit = true;
            if (value == LinkState.Reconnecting) _blink.Start(); else _blink.Stop();
            InvalidateVisual();
        }
    }

    public override void Render(DrawingContext ctx)
    {
        var brush = State switch { LinkState.Connected => Green, LinkState.Reconnecting => Orange, _ => Red };
        double r = Math.Min(Bounds.Width, Bounds.Height) / 2;
        var c = new Point(Bounds.Width / 2, Bounds.Height / 2);
        if (State != LinkState.Reconnecting || _lit) ctx.DrawEllipse(brush, new Pen(Brushes.Black, 1), c, r, r);
        else ctx.DrawEllipse(null, new Pen(Orange, 1.2), c, r - 0.5, r - 0.5);
    }
}

/// Keeps a link up: once it has been connected, a background check notices it has gone (a cable pulled, the ECU switched off) and tries to get it back - so many times, a pause between each - before giving up and calling it not connected.
public sealed class LinkSupervisor : IDisposable
{
    /// How many times a lost link is tried again, and the pause between tries (Settings > Emulator & datalog > Reconnecting).
    public static int Attempts { get; set; } = 10;
    public static int DelayMs { get; set; } = 1000;

    readonly string _name;
    readonly Func<bool?> _isUp;
    readonly Action _reconnect;
    readonly Thread _thread;
    volatile bool _stop, _wanted;
    readonly object _gate = new();

    /// The link is wanted (the user connected it): orange while it comes up, and from then on a loss is tried again.
    public bool Wanted
    {
        get => _wanted;
        set { _wanted = value; Attempt = 0; State = value ? LinkState.Reconnecting : LinkState.Off; }
    }
    public LinkState State { get; private set; }
    public int Attempt { get; private set; }
    /// A line for the status bar (gone, trying again, back, given up); raised on a background thread.
    public event Action<string>? Message;

    /// isUp: a quick check, on the background thread, that the link still works (null: still coming up, ask again later). reconnect: bring it back (throws when it cannot).
    public LinkSupervisor(string name, Func<bool?> isUp, Action reconnect)
    {
        _name = name; _isUp = isUp; _reconnect = reconnect;
        _thread = new Thread(Loop) { IsBackground = true, Name = name + " watch" };
        _thread.Start();
    }

    /// Run something that talks to the link without the watch trying to reconnect at the same moment.
    public T Exclusive<T>(Func<T> run) { lock (_gate) return run(); }

    void Loop()
    {
        while (!_stop)
        {
            Thread.Sleep(State == LinkState.Reconnecting ? Math.Max(200, DelayMs) : 1000);
            if (_stop) break;
            if (!_wanted) { State = LinkState.Off; continue; }
            lock (_gate)
            {
                bool? up;
                try { up = _isUp(); } catch { up = false; }
                if (up == null) continue;
                if (up == true)
                {
                    if (State == LinkState.Reconnecting) Message?.Invoke($"{_name}: connected again");
                    State = LinkState.Connected; Attempt = 0;
                    continue;
                }
                if (!_wanted) continue;
                if (State != LinkState.Reconnecting) { Message?.Invoke($"{_name}: the link was lost - trying to get it back"); AppLog.Warn(_name, "link lost"); }
                State = LinkState.Reconnecting;
                Attempt++;
                if (Attempt > Math.Max(1, Attempts))
                {
                    _wanted = false; State = LinkState.Off; Attempt = 0;
                    Message?.Invoke($"{_name}: gave up after {Attempts} tries - not connected");
                    AppLog.Warn(_name, $"gave up reconnecting after {Attempts} tries");
                    continue;
                }
                try
                {
                    _reconnect();
                    AppLog.Info(_name, $"reconnect attempt {Attempt} went through");
                }
                catch (Exception ex) { AppLog.Info(_name, $"reconnect attempt {Attempt} of {Attempts}: {ex.Message}"); }
            }
        }
    }

    public void Dispose() { _stop = true; }
}
