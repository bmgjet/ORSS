// Copyright (c) bmgjet. All rights reserved.
using System.Security.Cryptography;
using OkiRomSim.Desktop;

namespace AlphaEmuPlugin;

/// ALPHAemu in charge of the app's Emulator and Datalogging controls while the plugin is enabled: Connect is the
/// ALPHA link (the datalog comes over it), Upload deploys the ROM open here to the slot that is running, Validate
/// checks that slot against it, Download reads it back into the editor, and Real-time update is the plugin's.
sealed class AlphaTakeover(AlphaHub hub) : IEmulatorTakeover
{
    public string Name => "ALPHAemu";

    AlphaSession S => hub.Session;

    public bool Connected => S.Phase is AlphaLinkPhase.Linked or AlphaLinkPhase.Logging;
    public bool Connecting => S.Phase == AlphaLinkPhase.Connecting;
    public string Status => S.Status;
    public bool RealtimeUpdate => S.RealtimeEnabled;

    public void ToggleConnect()
    {
        if (Connected || Connecting) hub.Disconnect();
        else hub.Connect();
    }

    public void ToggleRealtime() => hub.ToggleRealtime();

    bool Linked()
    {
        if (Connected) return true;
        hub.Notify("connect the emulator first (Emulator > Connect ALPHAemu)");
        return false;
    }

    public void Upload()
    {
        if (!Linked()) return;
        if (!hub.HasRom) { hub.Notify("nothing is open to upload: open or build a ROM first"); return; }
        var rom = hub.App.Sim.RomCopy();
        void Go() => S.Run("upload", s => { int slot = s.ActiveSlot(); return $"slot {slot}: " + s.DeploySlot(slot, rom); }, _ => hub.App.EmulatorChanged());
        if (hub.State.ConfirmActiveSlot)
            hub.Ask("Upload to the running slot", $"Write the ROM open here ({AlphaState.Bytes(rom.Length)}) to the slot the emulator is running? The engine runs it straight away.", Go);
        else Go();
    }

    public void Validate()
    {
        if (!Linked()) return;
        if (!hub.HasRom) { hub.Notify("nothing is open to check against: open a ROM first"); return; }
        string sha = Convert.ToHexString(SHA256.HashData(hub.App.Sim.RomCopy())).ToLowerInvariant();
        S.Run("validate", s => { int slot = s.ActiveSlot(); return $"slot {slot}: " + s.VerifySlot(slot, sha); });
    }

    public void Download()
    {
        if (!Linked()) return;
        S.Run("download", s =>
        {
            var bytes = s.ReadActiveImage() ?? throw new IOException("the emulator did not give its image");
            hub.Ui(() =>
            {
                if (hub.HasRom) { hub.LoadIntoRom(bytes, "the emulator's running image"); return; }
                // nothing open to load it into: kept as a .bin to open
                var file = Path.Combine(hub.Folder, $"alphaemu-{DateTime.Now:yyyyMMdd-HHmmss}.bin");
                File.WriteAllBytes(file, bytes);
                hub.Notify("the emulator's image is saved as " + file + " - open it to work on it");
            });
            return $"{AlphaState.Bytes(bytes.Length)} read";
        });
    }
}
