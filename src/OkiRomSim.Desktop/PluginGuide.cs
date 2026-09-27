// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace OkiRomSim.Desktop;

/// Settings > Plugins: everything needed to write a plugin - the project, the class, and every way into the app, each with an example to copy.
public static class PluginGuide
{
    public sealed record Topic(string Title, string Text, string? Code = null);

    public static readonly Topic[] Topics =
    [
        new("What a plugin is",
            "A .NET class library (a .dll) with a public class that implements IOkiPlugin. The app makes one of it when it starts (or when the " +
            "plugin is added), calls Start on the UI thread with a PluginContext - the way into everything - and Stop when the app closes or the " +
            "plugin is switched off. Each plugin loads in a context of its own, so its own dependencies can sit beside it; the app's assemblies " +
            "(Avalonia, System.IO.Ports, the app itself) are shared. A plugin runs with the app's rights: it can read and change the ROM, the " +
            "definitions and the simulator, your files and the serial ports. Everything it adds through the PluginContext is taken back out " +
            "when it is switched off."),
        new("1. The project",
            "A class library for the same .NET as the app, referencing the app without copying it (the app's own copy is used when it loads). " +
            "Build it and the .dll lands beside the app's Plugins folder if you add the copy step.",
            """
            <Project Sdk="Microsoft.NET.Sdk">
              <PropertyGroup>
                <TargetFramework>net10.0</TargetFramework>
                <ImplicitUsings>enable</ImplicitUsings>
                <Nullable>enable</Nullable>
                <EnableDynamicLoading>true</EnableDynamicLoading>
                <CopyLocalLockFileAssemblies>false</CopyLocalLockFileAssemblies>
              </PropertyGroup>
              <ItemGroup>
                <!-- the app's project, or: <Reference Include="OkiRomSimStudio"><HintPath>path\to\OkiRomSimStudio.dll</HintPath><Private>false</Private></Reference> -->
                <ProjectReference Include="..\..\OkiRomSim.Desktop\OkiRomSim.Desktop.csproj" Private="false" ExcludeAssets="runtime" />
              </ItemGroup>
            </Project>
            """),
        new("2. The class",
            "Name, Description and Version are shown in Settings > Plugins. Start is where the plugin hooks in; Stop is for what the context " +
            "cannot take back itself - threads, ports, files.",
            """
            using OkiRomSim.Desktop;

            public sealed class HelloPlugin : IOkiPlugin
            {
                public string Name => "Hello";
                public string Description => "Says hello.";
                public string Version => "1.0";

                public void Start(PluginContext app) =>
                    app.AddMenuItem("Say hello", () => app.SetStatus("hello"));

                public void Stop() { }
            }
            """),
        new("3. Loading it",
            "Settings > Plugins > Add… and pick the .dll, then Save: it starts at once. A .dll put in the Plugins folder beside the program is " +
            "offered under 'Plugins that come with the app' with an Add button. Untick a plugin to switch it off; it is left out from the next start."),
        new("Menus, buttons, tabs and windows",
            "AddMenuItem puts an entry in the Plugins menu on the bar (it appears once a plugin is loaded). AddToolbarButton adds a button to the " +
            "bar in both Simulator and Tuner mode. AddTab adds a page to the simulator's lower tabs. OpenWindow opens a window of your own in the " +
            "app's dark style. Window is the main window, for anything else.",
            """
            app.AddMenuItem("Open my tool…", OpenTool, "What it does, as a tip");
            app.AddToolbarButton("⚡", "Quick action", "Tip for the button", () => app.SetStatus("done"));
            app.AddTab("My page", new TextBlock { Text = "Hello from a plugin" }, "Tip for the tab");
            var w = app.OpenWindow("My tool", new MyToolView(app), width: 800, height: 600);
            """),
        new("Calibration pages and page sections",
            "AddCalibrationPage puts a page of your own in the calibration editor's list, laid out from groups of rows. Each row has a slot key; " +
            "the editor binds it to one of the ROM's definitions (Guess gives words to look for in the definition names the first time). " +
            "AddPageSection adds controls to the bottom of a feature page - by its key, or \"*\" for every page - made each time the page is shown.",
            """
            app.AddCalibrationPage(new CalPage("my.idle", "My idle", "Plugins", "Idle settings in one place.",
            [
                new PageGroup("Idle speed",
                [
                    new PageRow("idle.target", "Target idle", Unit: "rpm", Guess: ["idle", "target"]),
                    new PageRow("idle.map", "Idle ignition", RowKind.Table, Guess: ["idle", "ignition"]),
                ]),
            ]));

            app.AddPageSection("*", page => new TextBlock { Text = $"{page.Name}: checked by {app.Name}" });
            """),
        new("The ROM and its definitions",
            "app.Sim is the ROM, its definitions and the simulator, all thread-safe. RomCopy and RomBytes read the image; PatchRom writes bytes " +
            "(the checksum is balanced and the change queued for the emulator, but it is not undoable: ApplyPatches is). Defs() is the definition set: Items, Find(name). " +
            "ReadItem gives every cell of a table or setting in real units; WriteItem and WriteCells change them the way the editor does - " +
            "undoable, uploaded to the emulator when it is set to upload changes. EditDefinitions changes the definitions themselves. " +
            "CalibrationChanged and ItemWritten tell you when anything else changed them.",
            """
            var defs = app.Sim.Defs();
            var fuel = defs.Find("FuelLow");                          // null when the ROM has no such map
            if (fuel != null)
            {
                var cells = app.Sim.ReadItem(fuel);                   // CellValue: Address, Raw, Value, Display
                app.Sim.WriteCells(fuel, [(0, cells[0].Value * 1.05)], raw: false, "plugin: +5 % on the first cell");
            }
            app.Sim.CalibrationChanged += (what, item) => app.Ui(() => app.Log($"changed: {what}"));
            app.Sim.ItemWritten += item => app.Log($"{item.Name} written");
            byte[] rom = app.Sim.RomCopy();
            """),
        new("The simulator",
            "Control runs it: \"run\", \"pause\", \"step\", \"stepover\", \"stepinto\", \"stepout\", \"reset\". SetInput moves an engine input " +
            "(rpm, map, tps, ect, iat, o2, vbatt, speed, baro, eld, cranking, starter...). State() is a snapshot of everything on screen: the PC and registers, the outputs " +
            "(injectors, fuel pump, VTEC), the engine inputs, the call stack. ReadMemory / WriteRam / HoldRam read, write and hold RAM; " +
            "RamWriters says which code writes a byte. AddBreakpoint, ToggleBreakpoint and RemoveBreakpoint set breakpoints; Build assembles " +
            "a source and loads it, PatchBuild puts the changed bytes into the running ROM. app.Sim.Sim is the simulator itself (Cpu, Bus) " +
            "for anything deeper - lock nothing yourself, and change it only while it is paused.",
            """
            app.Sim.SetInput("rpm", 3000);
            app.Sim.SetInput("map", 60);
            app.Sim.Control("run");
            var s = app.Sim.State();
            app.Log($"PC {s.Pc:X4} {s.Label}, injector {s.Outputs.InjectorMs[0]:F2} ms, VTEC {(s.Outputs.Vtec ? "on" : "off")}");
            byte[] ram = app.Sim.ReadMemory(0x0080, 16);              // 16 bytes of RAM from 80h
            var (pcs, writes) = app.Sim.RamWriters(0x0AC);            // who writes the crank period, and how often
            var bp = app.Sim.AddBreakpoint("3DDE");                   // a label or a hex address; bp.ok, bp.address
            """),
        new("Datalogging",
            "The Frame event gets every frame the datalog decodes (on the datalog's own thread: go through app.Ui to touch the screen). " +
            "DatalogEngine.Latest is the newest, Frames() all that are kept, Command(byte) sends a service command between frames. " +
            "To feed the log from a source of your own - a scan tool, a CAN adapter, a file - call BeginExternal, then Inject each frame, then " +
            "EndExternal: the gauges, graph, recording, map trace and smoothing all use them as if they came from the cable. ExternalStopped " +
            "fires when the user presses Disconnect. Datalog.LoadFrames shows a list of frames as a loaded log.",
            """
            app.Frame += f =>                                          // the datalog thread
            {
                if (f.Rpm is double rpm && rpm > 7000) app.Ui(() => app.SetStatus($"shift: {rpm:0} rpm"));
            };

            // a source of your own
            app.DatalogEngine.BeginExternal("My adapter");
            var frame = new LogFrame { Rpm = 2500, MapKpa = 45, TpsPct = 12 };
            frame.Set("afr", 14.2);                                    // any other channel by name
            app.DatalogEngine.Inject(frame);                           // timed, enriched, kept and shown
            app.DatalogEngine.ExternalStopped += () => StopMyReader();
            app.DatalogEngine.EndExternal();
            """),
        new("The emulator",
            "app.Sim.Emulator is the Ostrich / Demon link. EmulatorConnect(port), EmulatorUploadAll(), EmulatorValidate() and EmulatorDisconnect() " +
            "do what the Emulator menu does; AutoUpload sends each change as it is made. Datalog.PauseForEmulator / ResumeAfterEmulator stop and " +
            "restart a datalog that shares the emulator's port while you use it."),
        new("Settings, files and the Settings window",
            "GetSetting / SetSetting keep strings of your own with the app's settings (saved at once). DataFolder is a folder of the plugin's own. " +
            "AddSettingsPage adds a page to the Settings window, made each time the window opens. Settings is the app's own AppSettings (read it; " +
            "change it only if you know what you are doing).",
            """
            app.AddSettingsPage("My plugin", () =>
            {
                var box = new TextBox { Text = app.GetSetting("port") ?? "COM3", Width = 120 };
                box.TextChanged += (_, _) => app.SetSetting("port", box.Text ?? "");
                return box;
            });
            File.WriteAllText(Path.Combine(app.DataFolder, "notes.txt"), "kept between runs");
            """),
        new("Status, logging and threads",
            "SetStatus writes the status line (and the Debug page); Log and LogError write the Debug page's log, LogError with the exception's " +
            "stack. Everything on the PluginContext is for the UI thread - Start, menu and button actions already run there; from a thread of " +
            "your own, wrap UI work in app.Ui(...). A plugin's exception in a menu entry or button is caught and logged: it costs that action, " +
            "not the app. Anything the plugin added through the context (menu entries, buttons, tabs, pages, settings pages, Frame handlers) " +
            "comes out again when it is switched off; what you add to Window yourself, you take back in Stop."),
        new("A complete example",
            "src/Plugins/ScanTool in the source reads an ELM327 scan tool: a menu entry, a window, a settings page, and frames fed to the datalog " +
            "with BeginExternal / Inject. Copy it to start your own."),
    ];

    /// The guide as Markdown (Copy).
    public static string Markdown() => "# Making a plugin\n\n" + string.Join("\n\n", Topics.Select(t =>
        $"## {t.Title}\n\n{t.Text}" + (t.Code != null ? $"\n\n```\n{t.Code}\n```" : "")));

    public static Control Build()
    {
        var p = new StackPanel { Spacing = 8 };
        foreach (var t in Topics)
        {
            var box = new StackPanel { Margin = new Thickness(12, 0, 12, 10), Spacing = 8 };
            box.Children.Add(new SelectableTextBlock { Text = t.Text, TextWrapping = TextWrapping.Wrap, FontSize = 12, LineHeight = 18, Opacity = 0.9 });
            if (t.Code != null)
            {
                var code = new SelectableTextBlock { Text = t.Code, FontFamily = MainWindow.MonoFont, FontSize = 11.5, Foreground = DataList.Text };
                box.Children.Add(new Border
                {
                    Background = Dark.Back, CornerRadius = new CornerRadius(4), Padding = new Thickness(10, 8), BorderBrush = Panels.CardLine,
                    BorderThickness = new Thickness(1),
                    Child = new ScrollViewer { Content = code, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto, VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled },
                });
            }
            Control[] extras = t.Code == null ? [] : [Copy(t.Code, "Copy the example")];
            p.Children.Add(Panels.Card(t.Title, box, extras));
        }
        return p;
    }

    static Button Copy(string text, string tip)
    {
        Button? b = null;
        b = Panels.Button("Copy", async () =>
        {
            if (TopLevel.GetTopLevel(b)?.Clipboard is { } cb) await cb.SetTextAsync(text);
        }, tip);
        b.Padding = new Thickness(8, 1);
        return b;
    }

    public static Button CopyAll() => Copy(Markdown(), "Copy the whole guide, as Markdown.");
}
