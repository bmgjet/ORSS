# Plugins

A plugin is a .NET class library that OkiRomSim Studio loads at start-up. Pick plugins in **Settings > Plugins**. The plugins that come with the app are listed there with an **Add** button.

A plugin runs inside the app with the app's own rights. It can read and change the ROM, its definitions and the simulator. It can add menu entries, buttons, tabs, windows, calibration pages, page sections and settings pages, and it can feed the datalog.

## Making one

1. Make a class library for the same .NET as the app (`net10.0`). Reference the app's project, or `OkiRomSimStudio.dll`, without copying it:

   ```xml
   <ProjectReference Include="..\..\OkiRomSim.Desktop\OkiRomSim.Desktop.csproj" Private="false" ExcludeAssets="runtime" />
   ```

   Set `<EnableDynamicLoading>true</EnableDynamicLoading>` and `<CopyLocalLockFileAssemblies>false</CopyLocalLockFileAssemblies>`. The app's own copies of Avalonia, System.IO.Ports and the rest are then the ones used.

2. Add a public class that implements `OkiRomSim.Desktop.IOkiPlugin`:

   ```csharp
   public sealed class HelloPlugin : IOkiPlugin
   {
       public string Name => "Hello";
       public string Description => "Says hello.";
       public string Version => "1.0";
       public void Start(PluginContext app) => app.AddMenuItem("Say hello", () => app.SetStatus("hello"));
       public void Stop() { }
   }
   ```

3. Build it, then add the .dll in **Settings > Plugins**.

## What `PluginContext` gives you

| Member | What it is for |
| --- | --- |
| `Window`, `Sim`, `Calibration`, `Datalog`, `DatalogEngine`, `Settings` | The app itself: anything not covered by the helpers below. |
| `AddMenuItem`, `AddToolbarButton`, `AddTab`, `OpenWindow` | Ways into the UI. |
| `AddCalibrationPage`, `AddPageSection` | Calibration editor pages, and extra controls at the bottom of a feature page (`"*"` for every page). |
| `AddSettingsPage`, `GetSetting`, `SetSetting`, `DataFolder` | The plugin's own settings and files. |
| `DatalogEngine.BeginExternal` / `Inject` / `EndExternal` | Feed the Datalog page frames from your own source. The gauges, graph, recording, map trace and O2 tables then use them. |
| `RomLoaded`, `Frame` | Events for a ROM being opened and for every datalog frame. |
| `SetStatus`, `Log`, `LogError`, `Ui` | The status bar, the Debug page log, and running code on the UI thread. |

`ScanTool` is a complete example. It datalogs from an ELM327 scan tool: it adds a menu entry, a window and a settings page, and it feeds the datalog.
