// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using OkiRomSim.Calibration;

namespace OkiRomSim.Desktop;

/// Module RAM as a bar: each module's bytes a block of its own colour, the free part dark, red over the whole bar when the modules want more than there is. The tip names every block.
public sealed class RamBar : Control
{
    ModuleRam? _ram;

    public ModuleRam? Ram
    {
        get => _ram;
        set
        {
            _ram = value;
            ToolTip.SetTip(this, value == null ? "No module RAM in this build." :
                $"Module RAM {value.Base:X3}h-{value.End - 1:X3}h: {value.Used} of {value.Size} bytes taken\n" +
                string.Join("\n", value.Uses.Select(u => $"  {u.Start:X3}h  {u.Bytes,3} B  {u.Owner}")) +
                (value.Full ? $"\nFull: {value.Used - value.Size} bytes more than there is." : $"\n  {value.Free} bytes free"));
            InvalidateVisual();
        }
    }

    public RamBar() { Height = 14; MinWidth = 60; }

    static readonly Color[] Hues =
    [
        Color.FromRgb(0x4e, 0xa1, 0xff), Color.FromRgb(0x5c, 0xd6, 0x7a), Color.FromRgb(0xc0, 0x8c, 0xff), Color.FromRgb(0xe6, 0xc0, 0x7a),
        Color.FromRgb(0x3c, 0xc8, 0xc8), Color.FromRgb(0xff, 0x9d, 0x5c), Color.FromRgb(0x9a, 0xd0, 0x4a), Color.FromRgb(0xff, 0x7a, 0xc0),
    ];

    public override void Render(DrawingContext ctx)
    {
        var r = new Rect(Bounds.Size);
        ctx.DrawRectangle(AppTheme.Brush(Color.FromArgb(40, 255, 255, 255)), null, r, 3, 3);
        if (_ram is { Size: > 0 } ram)
        {
            double scale = r.Width / Math.Max(ram.Size, ram.Used);
            if (ram.Full) ctx.DrawRectangle(AppTheme.Brush(Color.FromRgb(0xd0, 0x40, 0x40)), null, r, 3, 3);
            else
                for (int i = 0; i < ram.Uses.Count; i++)
                {
                    var u = ram.Uses[i];
                    double x = (u.Start - ram.Base) * scale, w = Math.Max(1, (u.Bytes * scale) - 1);
                    ctx.DrawRectangle(AppTheme.Brush(Hues[i % Hues.Length]), null, new Rect(x, 0, w, r.Height));
                }
        }
        ctx.DrawRectangle(null, new Pen(AppTheme.Brush(Color.FromArgb(70, 255, 255, 255))), r.Deflate(0.5), 3, 3);
    }
}
