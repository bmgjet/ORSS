// Copyright (c) bmgjet. All rights reserved.
using System.Text;
using System.Text.Json;

namespace OkiRomSim.Tests;

static class CheckpointLineageTests
{
    static JsonDocument Lineage() => JsonDocument.Parse(File.ReadAllText(T.Data("sim-checkpoint-lineage.json")));

    public static void Run()
    {
        using var doc = Lineage();
        var lineage = doc.RootElement;
        var original = File.ReadAllText(T.Data(lineage.GetProperty("historical_file").GetString()!)).Replace("\r\n", "\n");
        T.Check("original upstream checkpoint file is retained byte-for-byte after newline normalization",
            T.Sha256(Encoding.UTF8.GetBytes(original)) == lineage.GetProperty("historical_lf_sha256").GetString());
        T.Check("historical verification pins the reviewed upstream source",
            lineage.GetProperty("historical_source").GetString() == "01d678730ccba53f81cd7d64f2037c6c686d0594");
        foreach (string file in new[] { "sim-checkpoints.txt", "sim-checkpoints-qualified.txt" })
        {
            var lines = File.ReadAllLines(T.Data(file)).Where(l => l.Length > 0 && !l.StartsWith('#')).ToList();
            bool complete = lines.Count == 36;
            foreach (var image in lineage.GetProperty("images").EnumerateObject())
                for (long step = SimRun.Every; step <= SimRun.Steps; step += SimRun.Every)
                    complete &= lines.Count(l => l.StartsWith($"{image.Name} @{step}: ", StringComparison.Ordinal)) == 1;
            T.Check($"{file}: all six ROMs retain all six exact checkpoints", complete);
        }
    }

    public static void CheckImage(string name, byte[] image)
    {
        using var doc = Lineage();
        T.Check($"{name}: checkpoint input is the unchanged historical ROM",
            doc.RootElement.GetProperty("images").TryGetProperty(name, out var expected)
            && T.Sha256(image).Equals(expected.GetString(), StringComparison.OrdinalIgnoreCase));
    }
}