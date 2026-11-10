// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// `RomSimTuner --selftest <rom.bin | build.asm>`: the tuning paths with no window and no hardware - the ROM opened as the window opens
/// it, its definitions, a calibration edit, the checksum kept, undo and redo, a save (to the temp folder, never over the file given),
/// and the emulator interlock with nothing connected. Prints PASS / FAIL for each, exits 0 when all pass.
public static class TunerSelfTest
{
    public static int Run(string path)
    {
        int fails = 0;
        void Check(bool ok, string what) { Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {what}"); if (!ok) fails++; }
        try
        {
            path = Path.GetFullPath(path);
            Console.WriteLine($"RomSimTuner self-test on {path}");
            var given = File.ReadAllBytes(path);
            Check(!AppDomain.CurrentDomain.GetAssemblies().Any(a => a.GetName().Name is "OkiRomSim.Sim" or "OkiRomSim.Mcp" or "RomSimStudio"),
                "no simulator, MCP or Rom Sim Studio assembly is loaded in this program");
            var host = new RomHost();
            byte[] original;
            if (path.EndsWith(".asm", StringComparison.OrdinalIgnoreCase))
            {
                var text = File.ReadAllText(path);
                (ProcessorProfile.Declared(text) ?? ProcessorProfile.Msm66207()).Apply();
                var r = host.Build(path);
                Check(r.Success, $"the build assembles ({r.Diagnostics.Count(d => d.Severity == OkiRomSim.Assembler.Severity.Error)} errors)");
                if (!r.Success) return 1;
                original = host.RomCopy();
            }
            else
            {
                var bytes = File.ReadAllBytes(path);
                if (bytes.Length == Chip.RomSize + 1 && bytes[^1] == 0) bytes = bytes[..Chip.RomSize];
                // what the window refuses (or asks about: a 64 KB chip image holds two ROMs) is not opened here either
                if (bytes.Length > Chip.RomSize)
                {
                    Console.WriteLine($"{Path.GetFileName(path)} is {bytes.Length} bytes: the window opens a 64 KB image by asking which half, " +
                                      $"and refuses anything else over {Chip.RomSize} - give the self-test one 32 KB half");
                    return 1;
                }
                (ProcessorProfile.ForImage(bytes) ?? ProcessorProfile.Msm66207()).Apply();
                var sidecar = Path.ChangeExtension(path, null) + ".okidef.json";
                DefinitionSet? saved = File.Exists(sidecar) ? DefinitionSet.Load(sidecar) : null;
                var opened = TunerOpen.Image(bytes, path, saved);
                Check(opened.Image.AsSpan(0, Math.Min(bytes.Length, Chip.RomSize)).SequenceEqual(bytes.AsSpan(0, Math.Min(bytes.Length, Chip.RomSize))),
                    "the image opened holds the file's bytes");
                Console.WriteLine($"     disassembly {(opened.Asm != null ? "rebuilds to exactly these bytes: code names and Detect available" : "does not rebuild: opened without it")}");
                host.LoadImage(opened.Image, opened.Asm, opened.Asm != null ? opened.SourcePath : path);
                if (saved != null) host.ReplaceDefinitions(saved);
                original = host.RomCopy();
                Check(original.AsSpan(0, Math.Min(bytes.Length, Chip.RomSize)).SequenceEqual(bytes.AsSpan(0, Math.Min(bytes.Length, Chip.RomSize))),
                    "the host holds the file's bytes, unchanged by opening it");
                if (opened.Asm != null && host.Defs().Items.Count == 0)
                {
                    var refs = RomReference.ShippedFor(host.LoadedPath);
                    var d = host.EditDefinitions(defs => CalibrationDetector.Detect(defs, opened.Asm, original, [(opened.SourcePath, opened.Text)], refs));
                    Console.WriteLine($"     Detect: {d.Summary}");
                }
            }
            host.RefreshMapSensor();
            Check(!host.RomDirty, "nothing is marked unsaved after opening");
            var defs = host.Defs();
            Console.WriteLine($"     {defs.Items.Count} definitions, checksum byte {(host.ChecksumAddress is int c ? c.ToString("X4") + "h" : "none")}, sum {host.ChecksumNow().Sum:X2}h");
            // one cell of the first table (else the first setting) a step up, raw - as the editor's + key does
            var item = defs.Items.FirstOrDefault(i => i.IsTable && i.Count > 0 && i.CellAddress(0) >= 0 && i.CellAddress(0) < Chip.RomSize)
                       ?? defs.Items.FirstOrDefault(i => i.Count > 0 && i.CellAddress(0) >= 0 && i.CellAddress(0) < Chip.RomSize);
            if (item == null) Console.WriteLine("     no definition to edit: the edit, undo and save checks are skipped");
            else
            {
                int sumBefore = host.ChecksumNow().Sum;
                var cell = host.ReadItem(item)[0];
                double raw = cell.Raw;
                double maxRaw = item.ElementSize >= 2 ? 0xFFFF : 0xFF;
                double next = raw < maxRaw ? raw + 1 : raw - 1;
                host.WriteCells(item, [(0, next)], raw: true, "self-test");
                var edited = host.RomCopy();
                int changed = 0;
                for (int i = 0; i < Chip.RomSize; i++) if (edited[i] != original[i]) changed++;
                Check(host.RomDirty, $"an edit to {item.Name}[0] ({raw} -> {next}) marks the ROM unsaved");
                Check(changed >= 1 && changed <= item.ElementSize + 1, $"only that cell (and the checksum byte) changed: {changed} byte(s)");
                if (host.ChecksumAddress != null) Check(host.ChecksumNow().Sum == sumBefore, $"the 8-bit sum is kept at {sumBefore:X2}h by the checksum byte");
                Check(host.Undo() != null && host.RomCopy().AsSpan().SequenceEqual(original), "undo puts every byte back");
                Check(host.Redo() != null && host.RomCopy().AsSpan().SequenceEqual(edited), "redo makes the edit again");
                var dir = Path.Combine(Path.GetTempPath(), "romsimtuner-selftest-" + Environment.ProcessId);
                Directory.CreateDirectory(dir);
                var outPath = Path.Combine(dir, Path.GetFileNameWithoutExtension(path) + "_tuned.bin");
                host.SaveRom(outPath);
                Check(File.ReadAllBytes(outPath).AsSpan().SequenceEqual(edited), "the saved .bin holds exactly the edited image");
                Check(!host.RomDirty && host.LastSavedPath == outPath, "saving clears the unsaved mark and says where it went");
                host.SaveRom(outPath);
                Check(File.Exists(outPath + ".bak") && File.ReadAllBytes(outPath + ".bak").AsSpan().SequenceEqual(edited), "saving over it keeps the one before as .bak");
                try { Directory.Delete(dir, true); } catch { }
                Check(File.ReadAllBytes(path).AsSpan().SequenceEqual(given), "the file given was not written to: every byte as it was read");
            }
            // the emulator, with nothing connected: nothing is sent, and a blank image is never offered
            host.AutoUpload = true;
            Check(!host.Emulator.Connected && !host.EmulatorInSync, "no emulator: not connected, not in step");
            Check(host.CanUpload(out _), "an open, non-blank ROM may go to an emulator");
            host.Clear();
            Check(!host.CanUpload(out var why) && why.Length > 0, "with nothing open, nothing may go to an emulator: " + why);
        }
        catch (Exception ex) { Console.WriteLine("FAIL " + ex); fails++; }
        Console.WriteLine(fails == 0 ? "ALL PASS" : $"{fails} FAILED");
        return fails == 0 ? 0 : 1;
    }
}
