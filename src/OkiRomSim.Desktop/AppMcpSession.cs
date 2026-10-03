// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using Avalonia.Threading;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;
using OkiRomSim.Mcp;

namespace OkiRomSim.Desktop;

/// The ROM open in the app, for MCP clients on the in-app server: their edits go through the same paths as the user's (undo, emulator upload) and the app shows them as they happen.
public sealed class AppMcpSession : IMcpSession
{
    readonly SimHost _host;
    readonly DatalogView _datalog;
    readonly Func<IReadOnlyList<(string Path, string Text)>> _sources;
    readonly Action<string> _notify;
    readonly Func<(string Port, string Protocol, int Baud)> _datalogSettings;
    readonly Action<byte[], string> _loadRom;
    readonly Action<string> _openFile;

    public AppMcpSession(SimHost host, DatalogView datalog, Func<IReadOnlyList<(string Path, string Text)>> sources, Action<string> notify,
                         Func<(string, string, int)> datalogSettings, Action<byte[], string> loadRom, Action<string> openFile)
    {
        _host = host; _datalog = datalog; _sources = sources; _notify = notify; _datalogSettings = datalogSettings;
        _loadRom = loadRom; _openFile = openFile;
    }

    static T Ui<T>(Func<T> f) => Dispatcher.UIThread.CheckAccess() ? f() : Dispatcher.UIThread.Invoke(f);

    public string Describe()
    {
        var s = _host.State();
        var sb = new StringBuilder();
        sb.AppendLine(_host.LoadedPath == null ? "nothing open" : $"open: {_host.LoadedPath}{(_host.RomDirty ? " (calibration edited, not saved)" : "")}");
        sb.AppendLine($"processor: {ProcessorProfile.Current.Name} on {ProcessorProfile.Current.Board}, {Bus.CrystalMHz:0.##} MHz");
        sb.AppendLine($"build: {(_host.Assembly == null ? "none" : $"{_host.Assembly.UsedBytes} bytes used, {_host.Assembly.SourceMap.Count} source lines")}");
        sb.AppendLine($"definitions: {_host.Defs().Items.Count} ({string.Join(", ", _host.Defs().Items.GroupBy(i => i.Category).Select(g => $"{g.Count()} {g.Key}"))})");
        sb.AppendLine($"simulator: {s.StopReason} at {s.Pc:X4} {s.Label}, {s.SimSeconds:0.00} s simulated, rpm {s.Rpm:0}, MAP {s.Map:0} kPa");
        sb.AppendLine($"emulator: {_host.EmulatorStatus}{(_host.AutoUpload ? ", auto-upload on" : "")}");
        var e = _datalog.Engine;
        sb.Append($"datalog: {e.Status}, {e.FrameCount} frames recorded");
        return sb.ToString();
    }

    public string? RomPath => _host.LoadedPath;
    public int Version => _host.Version;
    public byte[] Rom() => _host.RomBytes(0, Bus.RomSize);
    public AssemblyResult? Assembly => _host.Assembly;
    public IReadOnlyList<(string Path, string Text)> Sources() => Ui(() => _sources());
    public DefinitionSet Definitions() => _host.Defs();

    public T Edit<T>(Func<DefinitionSet, T> change, string what, string? showItem = null)
    {
        var r = _host.EditDefinitions(change);
        _host.RaiseCalibrationChanged(what, showItem);
        return r;
    }

    public CellValue Write(ItemDef item, int index, double value, bool raw)
    {
        _host.WriteCells(item, new[] { (index, value) }, raw, "by MCP");
        _host.RaiseCalibrationChanged($"MCP changed {item.Name}", item.Name);
        return _host.ReadItem(item)[index];
    }

    public void WriteBatch(ItemDef item, IReadOnlyList<(int Index, double Value)> cells, bool raw, string what)
    {
        _host.WriteCells(item, cells, raw, what);
        _host.RaiseCalibrationChanged($"MCP: {item.Name} {cells.Count} cell(s) {what}", item.Name);
    }

    public int ApplyPatches(IReadOnlyList<BytePatch> patches, string what)
    {
        int n = _host.ApplyPatches(patches, what);
        if (n > 0) _host.RaiseCalibrationChanged($"MCP: {what} ({n} bytes)");
        return n;
    }

    public string SaveRom(string path)
    {
        _host.SaveRom(path);
        Notify($"MCP saved the ROM to {path}");
        return $"running ROM -> {path}";
    }

    public string LoadRom(byte[] rom, string name)
    {
        var msg = Ui(() =>
        {
            _loadRom(rom, name);
            return $"{name}: {rom.Length} bytes opened in the app";
        });
        Notify("MCP uploaded a ROM: " + name);
        return msg;
    }

    public string OpenFile(string path)
    {
        if (!File.Exists(path)) throw new ToolException($"'{path}' is not a file on this machine");
        var msg = Ui(() =>
        {
            _openFile(path);
            var sb = new StringBuilder($"opened {path} in the app");
            if (_host.LoadedPath != null) sb.Append("\nROM: ").Append(_host.LoadedPath);
            if (_host.Assembly is { } asm) sb.Append($"\nbuild: {asm.UsedBytes} bytes used, {asm.SourceMap.Count} source lines");
            sb.Append($"\ndefinitions: {_host.Defs().Items.Count}");
            return sb.ToString();
        });
        Notify("MCP opened " + Path.GetFileName(path));
        return msg;
    }

    public string Emulator(string action, string? port)
    {
        switch (action.ToLowerInvariant())
        {
            case "status": return _host.EmulatorStatus + (_host.AutoUpload ? " (auto-upload on)" : "");
            case "connect":
                {
                    var p = port ?? MoatesTrace.Ports().LastOrDefault() ?? throw new ToolException("no serial port found; give port");
                    var r = _host.EmulatorConnect(p);
                    Notify("MCP connected the emulator: " + r);
                    return r;
                }
            case "upload":
                if (!_host.Emulator.Connected) throw new ToolException("the emulator is not connected (action connect first)");
                return _host.EmulatorUploadAll();
            case "disconnect": _host.EmulatorDisconnect(); return "disconnected";
            case "auto_upload_on": _host.AutoUpload = true; Notify("MCP turned emulator auto-upload on"); return "every calibration change is now uploaded as it is made";
            case "auto_upload_off": _host.AutoUpload = false; return "auto-upload off";
            default: throw new ToolException($"unknown action '{action}'");
        }
    }

    public IReadOnlyList<LogFrame> DatalogFrames() => Ui(() => _datalog.Frames());

    public string Datalog(string action, JsonObject args)
    {
        var e = _datalog.Engine;
        string? S(string k) => args[k] is JsonValue v ? v.ToString() : null;
        int I(string k, int def) => args[k] is JsonValue v && int.TryParse(v.ToString(), out var i) ? i : def;
        switch (action)
        {
            case "status":
                return $"{e.Status}; {e.Good} frames, {e.Bad} missed, {e.FramesPerSecond:0.0}/s, {e.FrameCount} kept; protocol {e.Protocol?.Name ?? "-"}; " +
                       $"wideband {e.Wideband.Status}; aux channels: {string.Join(", ", e.AuxChannels.Select(c => c.Name))}";
            case "start":
                {
                    var (port, proto, baud) = _datalogSettings();
                    port = S("port") ?? port; proto = S("protocol") ?? proto;
                    if (port.Length == 0) throw new ToolException("no port: pass port (a serial port, or 'simulator')");
                    Ui(() => { _datalog.Port = port; _datalog.Protocol = proto; _datalog.Stop(); _datalog.Start(); return 0; });
                    Thread.Sleep(1500);
                    Notify($"MCP started datalogging on {port}");
                    return $"started on {port} ({proto}): {e.Status}";
                }
            case "stop": Ui(() => { _datalog.Stop(); return 0; }); return "stopped: " + e.Status;
            case "clear": e.ClearFrames(); return "cleared";
            case "load":
                {
                    var path = S("log") ?? throw new ToolException("give log (a file path)");
                    return Ui(() => _datalog.LoadFile(path));
                }
            case "latest":
                {
                    var f = e.Latest ?? Ui(() => _datalog.Current) ?? throw new ToolException("no frame yet");
                    return string.Join("\n", f.Channels().Select(c => $"{c} = {f.Get(c):0.###} {LogFrame.UnitOf(c)}")) +
                           (f.Raw != null ? $"\nraw: {Convert.ToHexString(f.Raw)}" : "");
                }
            case "frames":
                {
                    var frames = DatalogFrames();
                    int from = Math.Clamp(I("from", Math.Max(0, frames.Count - 20)), 0, Math.Max(0, frames.Count));
                    int count = Math.Clamp(I("count", 20), 1, 500);
                    var chans = (args["channels"] as JsonArray)?.Select(x => x!.ToString()).ToList()
                                ?? frames.Skip(from).FirstOrDefault()?.Channels().ToList() ?? [];
                    var sb = new StringBuilder($"frames {from}-{Math.Min(frames.Count, from + count) - 1} of {frames.Count}\nt," + string.Join(",", chans) + "\n");
                    foreach (var f in frames.Skip(from).Take(count))
                        sb.AppendLine(f.T.ToString("0.00", CultureInfo.InvariantCulture) + "," + string.Join(",", chans.Select(c => f.Get(c)?.ToString("0.###", CultureInfo.InvariantCulture) ?? "")));
                    return sb.ToString();
                }
            default: throw new ToolException($"unknown action '{action}' (status, start, stop, latest, frames, clear, load, overlay, stats, protocols)");
        }
    }

    public string Simulator(string action, JsonObject args)
    {
        switch (action.ToLowerInvariant())
        {
            case "state": break;
            case "run": case "pause": case "reset": _host.Control(action.ToLowerInvariant()); break;
            case "step": _host.Control("step", Math.Clamp(args["count"] is JsonValue v && int.TryParse(v.ToString(), out var n) ? n : 1, 1, 100000)); break;
            case "inputs":
                foreach (var (key, input) in new[] { ("rpm", "rpm"), ("map_kpa", "map"), ("tps_pct", "tps"), ("ect_c", "ect"), ("iat_c", "iat"), ("o2_v", "o2"), ("batt_v", "vbatt"), ("speed_kmh", "speed") })
                    if (args[key] is JsonValue jv && double.TryParse(jv.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d))
                        _host.SetInput(input, d);
                break;
            default: throw new ToolException($"unknown action '{action}'");
        }
        var s = _host.State();
        var o = s.Outputs;
        Notify($"MCP simulator {action}");
        return $"{s.StopReason} at {s.Pc:X4} {s.Label}; {s.SimSeconds:0.000} s simulated; rpm {s.Rpm:0} MAP {s.Map:0.0} TPS {s.Tps:0} ECT {s.Ect:0}; " +
               $"fuel pump {(o.FuelPump ? "on" : "off")}, VTEC {(o.Vtec ? "on" : "off")}, injectors {string.Join("/", o.InjectorMs.Select(x => x.ToString("0.00", CultureInfo.InvariantCulture)))} ms, " +
               $"{o.SparksPerSec:0} ignition events/s" + (s.Fault != null ? $"; FAULT {s.Fault}" : "") +
               (s.Traps.Count > 0 ? "; traps " + string.Join(", ", s.Traps.Select(t => $"{t.Pc:X4} reason {t.Reason:X2} x{t.Count}")) : "");
    }

    public void Notify(string message) => _notify(message);
}
