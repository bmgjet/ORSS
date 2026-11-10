// Copyright (c) bmgjet. All rights reserved.
using Avalonia.Media;

namespace OkiRomSim.Desktop;

/// Fonts every window shares (both builds: Rom Sim Studio and the tuning-only RomSimTuner).
public static class UiFonts
{
    /// The fixed-width font for addresses, hex bytes and code: the first of these the system has.
    public static readonly FontFamily Mono = new("Cascadia Mono,Consolas,DejaVu Sans Mono,Menlo,monospace");
}
