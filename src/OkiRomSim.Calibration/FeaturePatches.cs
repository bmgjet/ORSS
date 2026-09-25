// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OkiRomSim.Calibration;

/// A feature file: code patches that add or remove a behaviour, rather than values in a map. Every patch says what it expects to find as well as what it writes, so it is only ever applied to a ROM it was made for, and taking it off again puts back exactly the bytes that were there. <para> A feature has one or more variants - the same change for different ROMs, each a list of sites (address, original bytes, patched bytes) - and may also carry byte patterns, which find the site in a ROM none of the variants was written for. A pattern is only used when it matches exactly one place in the image. </para>
public sealed class FeatureFile
{
    public string Format { get; set; } = "okirom-features";
    public int Version { get; set; } = 1;
    public string About { get; set; } = "";
    /// The ROM's checksum correction byte (hex). When an image's 8-bit byte sum is 0 - the Honda convention, and what the P13 checks at boot (BRK 0x4B) - every apply and remove adjusts this byte so it stays 0. Images whose sum is not 0 are left alone.
    public string? ChecksumByte { get; set; }
    public List<Feature> Features { get; set; } = [];

    static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull, ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static FeatureFile Load(string path) => Parse(File.ReadAllText(path));

    public static FeatureFile Parse(string json)
    {
        var f = JsonSerializer.Deserialize<FeatureFile>(json, Json) ?? throw new InvalidDataException("empty feature file");
        if (f.Format != "okirom-features") throw new InvalidDataException($"not a feature file (format '{f.Format}')");
        foreach (var feat in f.Features)
            foreach (var v in feat.Variants)
                foreach (var s in v.Sites)
                    if (FeaturePatches.Hex(s.Original).Length != FeaturePatches.Hex(s.Patched).Length)
                        throw new InvalidDataException($"{feat.Id} / {v.Rom} @ {s.Address}: original and patched are different lengths");
        return f;
    }

    public string ToJson() => JsonSerializer.Serialize(this, Json);

    /// Where the app looks for the feature file when none has been picked: next to the program.
    public static string DefaultPath => Path.Combine(AppContext.BaseDirectory, "features.json");
}

public sealed class Feature
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Category { get; set; } = "";
    public string Description { get; set; } = "";
    /// How it was checked, so a user can judge how far to trust it.
    public string Verified { get; set; } = "";
    public List<FeatureVariant> Variants { get; set; } = [];
    public List<FeaturePattern> Patterns { get; set; } = [];
}

public sealed class FeatureVariant
{
    /// Which ROM these sites were taken from (informational - the bytes decide).
    public string Rom { get; set; } = "";
    public List<FeatureSite> Sites { get; set; } = [];
}

public sealed class FeatureSite
{
    /// Hex, e.g. "4997".
    public string Address { get; set; } = "";
    /// Hex bytes, spaces allowed.
    public string Original { get; set; } = "";
    public string Patched { get; set; } = "";
    public string? Note { get; set; }
}

public sealed class FeaturePattern
{
    /// Hex bytes with ?? for any byte, e.g. "CD 07 F9 D5 ?? D5 ?? 89 8A 9F 01".
    public string Find { get; set; } = "";
    /// Where the patch starts, counted from the start of the match.
    public int Offset { get; set; }
    public string Patched { get; set; } = "";
}

public enum FeatureState { NotApplicable, Available, Applied, Partial }

public sealed record FeatureCheck(FeatureState State, FeatureVariant? Variant, string Detail);

public static class FeaturePatches
{
    public static byte[] Hex(string s)
    {
        var t = s.Replace(" ", "").Replace("-", "");
        if (t.Length % 2 != 0) throw new FormatException($"odd number of hex digits in '{s}'");
        return Convert.FromHexString(t);
    }

    static int Addr(string s) => int.Parse(s.Trim().TrimEnd('h', 'H').Replace("0x", ""), NumberStyles.HexNumber);

    static bool Matches(byte[] rom, int at, byte[] bytes) =>
        at >= 0 && at + bytes.Length <= rom.Length && rom.AsSpan(at, bytes.Length).SequenceEqual(bytes);

    /// What state this feature is in on this image, and which variant describes it.
    public static FeatureCheck Check(Feature f, byte[] rom)
    {
        foreach (var v in f.Variants.Concat(FromPatterns(f, rom)))
        {
            int orig = 0, patched = 0;
            foreach (var s in v.Sites)
            {
                int a = Addr(s.Address);
                if (Matches(rom, a, Hex(s.Patched))) patched++;
                else if (Matches(rom, a, Hex(s.Original))) orig++;
                else { orig = patched = -1; break; }
            }
            if (orig < 0) continue;
            if (patched == v.Sites.Count) return new(FeatureState.Applied, v, $"applied ({v.Rom})");
            if (orig == v.Sites.Count) return new(FeatureState.Available, v, $"can be applied ({v.Rom})");
            return new(FeatureState.Partial, v, $"partly applied: {patched} of {v.Sites.Count} sites ({v.Rom})");
        }
        return new(FeatureState.NotApplicable, null, "no variant matches this ROM");
    }

    /// Patterns turned into a variant for this image, when they each match exactly once (as the original, or already patched).
    static IEnumerable<FeatureVariant> FromPatterns(Feature f, byte[] rom)
    {
        if (f.Patterns.Count == 0) yield break;
        var sites = new List<FeatureSite>();
        foreach (var p in f.Patterns)
        {
            var find = ParsePattern(p.Find);
            var patched = Hex(p.Patched);
            // the same pattern with the patch laid over it finds a ROM it has already been applied to
            var findPatched = find.ToArray();
            for (int i = 0; i < patched.Length; i++) findPatched[p.Offset + i] = patched[i];
            var hits = Find(rom, find).ToList();
            bool already = false;
            if (hits.Count == 0) { hits = Find(rom, findPatched).ToList(); already = true; }
            if (hits.Count != 1) yield break;
            int at = hits[0] + p.Offset;
            var original = already ? null : rom.AsSpan(at, patched.Length).ToArray();
            if (already)
            {
                // the bytes it replaced are in the pattern (they must be fixed bytes there)
                original = new byte[patched.Length];
                for (int i = 0; i < patched.Length; i++)
                {
                    if (find[p.Offset + i] is not byte b) yield break;
                    original[i] = b;
                }
            }
            sites.Add(new FeatureSite
            {
                Address = at.ToString("X4"), Original = Convert.ToHexString(original!), Patched = Convert.ToHexString(patched),
                Note = "found by pattern",
            });
        }
        yield return new FeatureVariant { Rom = "found by pattern", Sites = sites };
    }

    static byte?[] ParsePattern(string s) =>
        s.Split(' ', StringSplitOptions.RemoveEmptyEntries)
         .Select(t => t is "??" or "?" ? (byte?)null : byte.Parse(t, NumberStyles.HexNumber)).ToArray();

    static IEnumerable<int> Find(byte[] rom, byte?[] pat)
    {
        for (int i = 0; i + pat.Length <= rom.Length; i++)
        {
            bool ok = true;
            for (int k = 0; k < pat.Length && ok; k++) ok = pat[k] is not byte b || rom[i + k] == b;
            if (ok) yield return i;
        }
    }

    /// The bytes that turn this feature on (remove = false) or off again, for this image. Empty when it does not apply or is already in that state. With a checksum byte, an image whose 8-bit sum is 0 gets that byte adjusted too, so it still sums to 0.
    public static List<BytePatch> Patches(Feature f, byte[] rom, bool remove, string? checksumByte)
    {
        var list = Patches(f, rom, remove);
        if (list.Count == 0 || checksumByte == null) return list;
        int at = Addr(checksumByte);
        if (at < 0 || at >= rom.Length || list.Any(p => p.Address == at)) return list;
        int sum = 0;
        foreach (var b in rom) sum += b;
        if ((sum & 0xFF) != 0) return list;
        int delta = list.Sum(p => p.Value - rom[p.Address]);
        list.Add(new BytePatch(at, (byte)((rom[at] - delta) & 0xFF)));
        return list;
    }

    public static List<BytePatch> Patches(Feature f, byte[] rom, bool remove = false)
    {
        var c = Check(f, rom);
        var list = new List<BytePatch>();
        if (c.Variant == null) return list;
        foreach (var s in c.Variant.Sites)
        {
            int a = Addr(s.Address);
            var to = Hex(remove ? s.Original : s.Patched);
            for (int i = 0; i < to.Length; i++)
                if (rom[a + i] != to[i]) list.Add(new BytePatch(a + i, to[i]));
        }
        return list;
    }

    /// Apply (or remove) in place and say what happened.
    public static string Apply(Feature f, byte[] rom, bool remove = false, string? checksumByte = null)
    {
        var c = Check(f, rom);
        if (c.State == FeatureState.NotApplicable) return $"{f.Id}: not for this ROM";
        var p = Patches(f, rom, remove, checksumByte);
        foreach (var b in p) rom[b.Address] = b.Value;
        return p.Count == 0
            ? $"{f.Id}: already {(remove ? "off" : "on")}"
            : $"{f.Id}: {(remove ? "removed" : "applied")}, {p.Count} byte(s) at {string.Join(", ", c.Variant!.Sites.Select(s => s.Address))}";
    }
}
