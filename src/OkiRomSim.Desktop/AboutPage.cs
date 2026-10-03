// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Settings > About: what the program is, who made it, where it comes from, and the licence it is used under.
public static class AboutPage
{
    /// The website: updates and the manual come from here. Fixed, so an update can only ever come from the author.
    public const string Website = Updater.DefaultSite;

    public const string Author = "bmgjet";

    /// The community server: questions, tunes, modules and bug reports.
    public const string Discord = "https://discord.gg/xynkH3ymkH";

    public static readonly string Licence = $$"""
        {{BuildInfo.Product}} licence

        Copyright (c) {{Author}}. All rights not granted below are reserved.

        1. Use
           You may download, install and use this software free of charge, for any purpose, including tuning your own
           vehicles and vehicles you work on for others.

        2. No selling
           You may not sell, rent, lease or sublicense this software, any part of it or any modified version of it, or
           include it in anything that is sold. You may give copies away free of charge, as long as this licence and
           the credits go with them unchanged.

        3. Changes
           You may change the software. If you give a changed version to anyone, or let anyone use it, you must:
             a) make the complete source code of your version publicly available, free of charge, under this licence;
             b) state clearly - in the source, and on the program's About page - that it is a changed version, who
                changed it, what was changed and when;
             c) keep this licence and the credits to the original author as they are.

        4. Credits
           The credit to {{Author}} as the original author must stay in the program, on its About page and in its source.

        5. No warranty
           The software is provided "as is", without warranty of any kind, express or implied, including but not
           limited to the warranties of merchantability, fitness for a particular purpose and non-infringement.

        6. No responsibility for damage
           Changing, flashing, emulating and datalogging an engine computer can damage computers, cables, emulators,
           ECUs, vehicles and engines, and a badly tuned engine can fail or put people at risk. You use this software
           entirely at your own risk. In no event shall the author or anyone who contributed to it be liable for any
           claim, damages or other liability - including damage to your computer, ECU, car or engine, loss of data or
           any loss of use - whether in contract, tort or otherwise, arising from or in connection with the software
           or its use.

        7. The law where you are
           Changes to an engine's calibration can affect its emissions, its roadworthiness and its insurance. Making
           sure a vehicle is legal to use where you are is your responsibility.

        Using the software means you accept these terms.
        """;

    public static Control Build()
    {
        var p = new StackPanel { Spacing = 10, Margin = new Thickness(0, 4) };
        // the program, its version and its author, beside the logo
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        if (DarkChrome.LoadIconBitmap() is { } icon)
            head.Children.Add(new Border { CornerRadius = new CornerRadius(12), ClipToBounds = true, Width = 72, Height = 72, Child = new Image { Source = icon, Width = 72, Height = 72 } });
        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 2 };
        names.Children.Add(new TextBlock { Text = BuildInfo.Product, FontSize = 24, FontWeight = FontWeight.Bold });
        names.Children.Add(new TextBlock { Text = $"version {BuildInfo.Version}", FontSize = 13, Opacity = 0.75 });
        names.Children.Add(new TextBlock { Text = $"by {Author}", FontSize = 13, Foreground = DataList.Label, FontWeight = FontWeight.SemiBold });
        head.Children.Add(names);
        p.Children.Add(head);
        p.Children.Add(Para("An assembler, simulator and debugger for the OKI MSM66207 engine computers in 1990s Hondas, and a calibration editor " +
                            "and datalogger for tuning them: write or change the ROM, run it against a simulated engine, then tune the car with an " +
                            "emulator and a datalog cable."));

        var site = Panels.Button(Website, () => Open(Website), "Open the website in your browser.", "🌐");
        site.HorizontalAlignment = HorizontalAlignment.Left;
        p.Children.Add(Labelled("Website", site));
        var chat = Panels.Button(Discord, () => Open(Discord), "Open the Discord in your browser: questions, tunes, modules and bug reports.", "💬");
        chat.HorizontalAlignment = HorizontalAlignment.Left;
        p.Children.Add(Labelled("Discord", chat));
        p.Children.Add(Labelled("Credits", new SelectableTextBlock
        {
            Text = $"{Author} - author: the program, the simulator, the skeleton ROM and its modules.\n" +
                   "Everyone who has shared what they learnt about these ECUs, their ROMs and their datalogging over the years.",
            TextWrapping = TextWrapping.Wrap, FontSize = 12,
        }));
        p.Children.Add(Labelled("Program folder", new SelectableTextBlock { Text = Updater.Home, FontFamily = MainWindow.MonoFont, FontSize = 11.5 }));

        var text = new TextBox
        {
            Text = Licence, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontFamily = MainWindow.MonoFont,
            FontSize = 11.5, Height = 300, BorderThickness = new Thickness(0), Background = Brushes.Transparent,
        };
        var copy = Panels.Button("Copy", async () =>
        {
            if (TopLevel.GetTopLevel(text)?.Clipboard is { } cb) await cb.SetTextAsync(Licence);
        }, "Copy the licence to the clipboard.");
        copy.Padding = new Thickness(8, 1);
        p.Children.Add(Panels.Card("Licence", text, copy));
        return p;
    }

    static TextBlock Para(string t) => new() { Text = t, TextWrapping = TextWrapping.Wrap, FontSize = 12.5, Opacity = 0.9, LineHeight = 19 };

    static Control Labelled(string label, Control c)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("120,*") };
        var l = new TextBlock { Text = label, Opacity = 0.65, FontSize = 12, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 4, 0, 0) };
        Grid.SetColumn(l, 0); g.Children.Add(l);
        c.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(c, 1); g.Children.Add(c);
        return g;
    }

    public static void Open(string url)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception ex) { AppLog.Error("about", "could not open " + url, ex); }
    }
}
