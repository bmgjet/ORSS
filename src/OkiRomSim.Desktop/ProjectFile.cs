using System.IO.Compression;
using System.Text;
using System.Text.Json;
using OkiRomSim.Calibration;

namespace OkiRomSim.Desktop;

/// A saved session: every open source buffer exactly as it is on screen (saved or not), the editor position, the simulator's full machine state (registers, RAM, patched ROM, inputs, breakpoints), calibration definitions, what the Trace / Memory / Lookup / Breakpoint views were showing, the processor profile (processor.json) and the settings in use (settings.json). Stored as a plain .zip so the pieces can be read - and edited - with any tool: change processor.json to describe another 66K part and board.
public sealed class ProjectData
{
    public int Version { get; set; } = 1;
    public string? Target { get; set; }
    public string? Current { get; set; }
    public int CaretLine { get; set; }
    public int FirstVisibleLine { get; set; }
    public List<ProjectSource> Sources { get; set; } = new();
    public string MemoryAddress { get; set; } = "";
    public string DisassemblyAddress { get; set; } = "";
    public string LookupQuery { get; set; } = "";
    public List<string> LookupLines { get; set; } = new();
    public string SelectedTab { get; set; } = "";
    public int SpeedIndex { get; set; }
    public string Package { get; set; } = "";
    public double CrystalMHz { get; set; }

    // not in project.json; carried in their own zip entries
    [System.Text.Json.Serialization.JsonIgnore] public SimHost.MachineState? Machine { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] public byte[] Ram { get; set; } = Array.Empty<byte>();
    [System.Text.Json.Serialization.JsonIgnore] public byte[] Rom { get; set; } = Array.Empty<byte>();
    [System.Text.Json.Serialization.JsonIgnore] public DefinitionSet? Definitions { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] public Dictionary<string, string> Views { get; set; } = new();
    /// processor.json: the chip and board (ProcessorProfile), editable by hand.
    [System.Text.Json.Serialization.JsonIgnore] public string? ProcessorJson { get; set; }
    /// settings.json: the settings in use while the ROM was open (no window layout, no secrets).
    [System.Text.Json.Serialization.JsonIgnore] public string? SettingsJson { get; set; }
}

public sealed class ProjectSource
{
    public string Path { get; set; } = "";
    public string Entry { get; set; } = "";
    public bool Unsaved { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] public string Text { get; set; } = "";
}

public static class ProjectFile
{
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public static void Save(string path, ProjectData p)
    {
        if (File.Exists(path)) File.Delete(path);
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        void Text(string name, string text)
        {
            using var w = new StreamWriter(zip.CreateEntry(name).Open(), new UTF8Encoding(false));
            w.Write(text);
        }
        void Bytes(string name, byte[] data)
        {
            using var s = zip.CreateEntry(name).Open();
            s.Write(data);
        }
        for (int i = 0; i < p.Sources.Count; i++)
        {
            var src = p.Sources[i];
            src.Entry = $"source/{i:D2}_{System.IO.Path.GetFileName(src.Path)}";
            Text(src.Entry, src.Text);
        }
        Text("project.json", JsonSerializer.Serialize(p, Json));
        if (p.Machine != null) Text("machine/state.json", JsonSerializer.Serialize(p.Machine, Json));
        Bytes("machine/ram.bin", p.Ram);
        Bytes("machine/rom.bin", p.Rom);
        if (p.Definitions != null) Text("calibration/definitions.json", JsonSerializer.Serialize(p.Definitions, DefinitionSet.Json));
        foreach (var (name, text) in p.Views) Text($"views/{name}", text);
        if (p.ProcessorJson != null) Text("processor.json", p.ProcessorJson);
        if (p.SettingsJson != null) Text("settings.json", p.SettingsJson);
    }

    public static ProjectData Load(string path)
    {
        using var zip = ZipFile.OpenRead(path);
        string? Text(string name)
        {
            var e = zip.GetEntry(name);
            if (e == null) return null;
            using var r = new StreamReader(e.Open(), Encoding.UTF8);
            return r.ReadToEnd();
        }
        byte[] Bytes(string name)
        {
            var e = zip.GetEntry(name);
            if (e == null) return Array.Empty<byte>();
            using var s = e.Open();
            using var ms = new MemoryStream();
            s.CopyTo(ms);
            return ms.ToArray();
        }
        var p = JsonSerializer.Deserialize<ProjectData>(Text("project.json") ?? throw new InvalidDataException("not an OkiRomSim project (no project.json)"), Json)
                ?? throw new InvalidDataException("project.json is empty");
        foreach (var src in p.Sources) src.Text = Text(src.Entry) ?? "";
        if (Text("machine/state.json") is { } st) p.Machine = JsonSerializer.Deserialize<SimHost.MachineState>(st, Json);
        p.Ram = Bytes("machine/ram.bin");
        p.Rom = Bytes("machine/rom.bin");
        if (Text("calibration/definitions.json") is { } defs) p.Definitions = JsonSerializer.Deserialize<DefinitionSet>(defs, DefinitionSet.Json);
        foreach (var e in zip.Entries.Where(e => e.FullName.StartsWith("views/")))
            p.Views[e.FullName["views/".Length..]] = Text(e.FullName) ?? "";
        p.ProcessorJson = Text("processor.json");
        p.SettingsJson = Text("settings.json");
        return p;
    }
}
