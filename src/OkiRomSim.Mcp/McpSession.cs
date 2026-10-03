// Copyright (c) bmgjet. All rights reserved.
using System.Text.Json.Nodes;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;

namespace OkiRomSim.Mcp;

/// The ROM open in the desktop app, as the in-app MCP server sees it. Tools called without a `path` work on it; every change goes through the app, which shows it (the Calibration page selects the table being edited, the Debug page logs the call). The app implements this; the stand-alone romsim-mcp server has no session and works on files only.
public interface IMcpSession
{
    /// One line: what is open, whether it has unsaved changes.
    string Describe();
    string? RomPath { get; }
    /// Bumped whenever the ROM or its build changes, so cached analyses can be refreshed.
    int Version { get; }
    /// A copy of the running ROM image (including calibration edits).
    byte[] Rom();
    AssemblyResult? Assembly { get; }
    /// Source files as they are in the app's editor (unsaved edits included).
    IReadOnlyList<(string Path, string Text)> Sources();
    /// The live definition set. Change it only inside Edit.
    DefinitionSet Definitions();
    /// Run a change to the definitions on the app's terms (its thread / lock), then refresh.
    T Edit<T>(Func<DefinitionSet, T> change, string what, string? showItem = null);
    /// Write one cell of the running ROM (the app records undo and uploads to the emulator when that is switched on).
    CellValue Write(ItemDef item, int index, double value, bool raw);
    /// Several writes as one undo step; `showItem` is selected on the Calibration page.
    void WriteBatch(ItemDef item, IReadOnlyList<(int Index, double Value)> cells, bool raw, string what);
    /// Write scattered bytes (a scaling) as one undo step.
    int ApplyPatches(IReadOnlyList<BytePatch> patches, string what);
    /// Save the running ROM image.
    string SaveRom(string path);
    /// Open a ROM image in the app (a client working from another machine sends one).
    string LoadRom(byte[] rom, string name);
    /// Open a file that is already on the app's machine, exactly as if it had been opened from the File menu: a .asm (assembled and loaded), a .bin / .rom (disassembled and loaded) or a saved project .zip. This is the other half of file_upload for a client on a different computer - send the file, then ask for it to be opened here.
    string OpenFile(string path);
    /// Emulator (Moates Ostrich / Demon): status, connect, upload, disconnect, auto_upload on|off.
    string Emulator(string action, string? port);
    /// Datalog: status, start, stop, latest, frames, clear, load (a file), and the recorded frames.
    string Datalog(string action, JsonObject args);
    IReadOnlyList<LogFrame> DatalogFrames();
    /// Simulator control: run, pause, reset, step, set inputs; returns the state after.
    string Simulator(string action, JsonObject args);
    /// Something for the user to see on screen (the status bar and the Debug page).
    void Notify(string message);
}
