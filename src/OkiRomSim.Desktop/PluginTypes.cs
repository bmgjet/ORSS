// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Desktop;

// The two plugin types the calibration editor, the datalog page and the settings file know about, kept apart from the plugin
// loader (Plugins.cs) so the tuning-only build (RomSimTuner, which loads no plugins) can share those files - and read the settings
// it starts from (Rom Sim Studio's, the first time) without losing the plugin list.

/// An emulator a plugin drives in place of the app's own (TakeOverEmulator): while it is in charge, the Emulator menu
/// (connect, download, upload, validate, real-time update), the Datalogging menu's and the datalog page's Connect, and
/// both status dots go to it. Called on the UI thread; long work belongs on the plugin's own threads.
public interface IEmulatorTakeover
{
    /// What it is ("ALPHAemu"), for the menus and the tooltips.
    string Name { get; }
    /// The link to the device is up.
    bool Connected { get; }
    /// Connecting or reconnecting right now.
    bool Connecting { get; }
    /// One line on how the link is, for the tooltips.
    string Status { get; }
    /// Connect (the emulator and the datalog that comes over it), or disconnect when connected.
    void ToggleConnect();
    /// Read the ROM out of the device and open it.
    void Download();
    /// Send the ROM open here to the device.
    void Upload();
    /// Check the device's ROM against the one here.
    void Validate();
    /// Changes go to the running image as they are made.
    bool RealtimeUpdate { get; }
    void ToggleRealtime();
}

/// One plugin in Settings > Plugins.
public sealed class PluginSetting
{
    public string Path { get; set; } = "";
    public bool Enabled { get; set; } = true;
}
