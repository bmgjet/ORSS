// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Core;

namespace OkiRomSim.Tests;

/// The ROM files themselves: the stock images and the sources they were disassembled into are the references everything else is
/// measured against, so they are checked against the SHA-256 recorded for them (data/rom-manifest.txt) - an edit to one shows up here
/// rather than quietly in a definition or a Detect result - and each source is checked to assemble to exactly its image. (Text files are
/// hashed with their lines ending in LF, as recorded, so a checkout that writes CRLF does not count as a change.)
static class RomFileTests
{
    public static void Run()
    {
        var manifest = T.ReadPairs(T.Data("rom-manifest.txt"));
        var changed = new List<string>();
        var files = manifest.Where(kv => !kv.Key.StartsWith("image:")).ToList();
        foreach (var (file, hash) in files)
        {
            var path = Path.Combine(T.Root, file.Replace('/', Path.DirectorySeparatorChar));
            if (!File.Exists(path)) { changed.Add(file + " missing"); continue; }
            // a text file's lines, whatever ends them (a checkout may turn LF into CRLF): what assembles is the same either way
            var bytes = File.ReadAllBytes(path);
            if (Path.GetExtension(path) is ".asm" or ".sym" or ".json") bytes = System.Text.Encoding.Latin1.GetBytes(System.Text.Encoding.Latin1.GetString(bytes).Replace("\r\n", "\n"));
            if (!T.Sha256(bytes).Equals(hash, StringComparison.OrdinalIgnoreCase)) changed.Add(file);
        }
        T.Check($"the {files.Count} reference ROM files are byte for byte as recorded", changed.Count == 0, changed.Count == 0 ? "rom-manifest.txt" : "changed: " + string.Join(", ", changed));

        foreach (var (src, bin, part) in new (string, string, Action)[] { ("p30.asm", "p30.bin", T.P30Part), ("p13.asm", "p13.bin", T.P13Part) })
        {
            var r = T.Assemble(T.Roms(src));
            var image = File.ReadAllBytes(T.Roms(bin));
            int diff = r.Success ? Enumerable.Range(0, Math.Min(image.Length, r.Image.Length)).Count(i => image[i] != r.Image[i]) : -1;
            T.Check($"{src} assembles to exactly {bin}", r.Success && r.Image.Length == image.Length && diff == 0,
                r.Success ? $"{diff} bytes differ" : string.Join("; ", r.Diagnostics.Where(d => d.Severity == OkiRomSim.Assembler.Severity.Error).Take(2)));
            T.Check($"{bin} sums to 0 (the stock ROM's own check)", T.Sum8(image) == 0, $"{T.Sum8(image):X2}h");
            SimRun.Compare(bin, image, part);
        }
        // the other references assemble, each to the image recorded for it (the stock tuning ROMs do not keep the sum, so it is not asked)
        foreach (var src in new[] { "HTS115.asm", "HTS120.asm", "p72-269.asm", "p08-911-243.asm" })
        {
            var r = T.Assemble(T.Roms(src));
            var key = "image:" + src;
            T.Check($"{src} assembles to the image recorded for it", r.Success && manifest.TryGetValue(key, out var want) && T.Sha256(r.Image).Equals(want, StringComparison.OrdinalIgnoreCase),
                r.Success ? T.Sha256(r.Image)[..16] : "does not assemble");
        }
        T.P30Part();
    }
}
