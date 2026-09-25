// Copyright (c) bmgjet. All rights reserved.
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OkiRomSim.Mcp;

/// One tool the server offers: its name, what it does, the JSON schema of its arguments, and the code that runs it. Handlers return text; anything large is written to a file and the text says where (so an agent does not spend its context on bulk output).
public sealed record McpTool(string Name, string Description, JsonObject InputSchema, Func<JsonObject, string> Run,
                             bool ReadOnly = true);

/// One tool call, for the log: who asked (IP address, or "stdio"), what, and how it went.
public sealed record McpCallInfo(string Client, string Tool, string Arguments, bool Ok, long Milliseconds, string Result);

/// Thrown by a tool for a problem the caller can fix (bad path, unknown label...). Reported to the client as a tool error rather than a protocol error.
public sealed class ToolException(string message) : Exception(message);

/// Model Context Protocol server core: JSON-RPC 2.0 dispatch for initialize, ping, tools/list and tools/call. Transport-independent (see McpStdio and McpHttp).
public sealed class McpServer
{
    public const string ProtocolVersion = "2025-06-18";
    public string Name { get; init; } = "okirom-mcp";
    public string Version { get; init; } = OkiRomSim.Core.BuildInfo.Version;
    public Workspace Workspace { get; }
    readonly Dictionary<string, McpTool> _tools = new(StringComparer.Ordinal);
    public IReadOnlyCollection<McpTool> Tools => _tools.Values;
    /// Called after every tool call, for logging.
    public Action<McpCallInfo>? Log { get; set; }
    /// The ROM open in the desktop app, when the server runs inside it (null for okirom-mcp).
    public IMcpSession? Session { get; }
    /// Longest a tool may run before the caller is told to try again (it keeps running).
    public TimeSpan ToolTimeout { get; set; } = TimeSpan.FromMinutes(5);

    public McpServer(Workspace workspace, IMcpSession? session = null)
    {
        Workspace = workspace;
        Session = session;
        foreach (var t in new OkiTools(workspace, this).All()) _tools[t.Name] = t;
        foreach (var t in new CalTools(workspace, this).All()) _tools[t.Name] = t;
    }

    public const string Instructions =
        "Tools for developing OKI MSM66207 (nX-8/200, 66K) assembly - the CPU in Honda OBD1 ECUs such as the P28. " +
        "Start with `help`, then `arch` (topics: overview, dd, addressing, ...) and `opcode` to learn the instruction set. " +
        "Work on files with file_read / file_search / file_edit (paged, so large .asm files do not flood your context); " +
        "`disassemble` turns a .bin into editable .asm, `assemble` builds it, `run` boots it in the simulator with engine inputs " +
        "and reports what it drives, `explore` follows the code from a label and says what a routine appears to do. " +
        "Calibration: cal_detect finds the maps, cal_list / cal_read / cal_write / cal_define edit them, cal_explain says which code " +
        "reads a table (so it can be named by what it does), cal_save writes .bin / definitions / TunerPro XDF, compare says what " +
        "changed between two ROMs. Inside the desktop app, leave `path` out to work on the ROM open there (the app shows every " +
        "change as it happens), and use `datalog` + `emulator` to tune a car from its logs.";

    /// Handle one JSON-RPC message (or batch). Returns the response JSON, or null for a notification.
    public string? Handle(string json, string client = "local")
    {
        _client.Value = client;
        JsonNode? node;
        try { node = JsonNode.Parse(json); }
        catch (JsonException) { return Error(null, -32700, "parse error").ToJsonString(); }
        if (node is JsonArray batch)
        {
            var responses = new JsonArray();
            foreach (var item in batch)
                if (item is JsonObject o && HandleOne(o) is { } r) responses.Add(r);
            return responses.Count == 0 ? null : responses.ToJsonString();
        }
        return node is not JsonObject msg ? Error(null, -32600, "invalid request").ToJsonString() : (HandleOne(msg)?.ToJsonString());
    }

    JsonObject? HandleOne(JsonObject msg)
    {
        var id = msg["id"]?.DeepClone();
        var method = msg["method"]?.GetValue<string>();
        if (method == null) return id == null ? null : Error(id, -32600, "missing method");
        bool notification = !msg.ContainsKey("id");
        try
        {
            JsonNode? result = method switch
            {
                "initialize" => Initialize(msg["params"] as JsonObject),
                "ping" => [],
                "tools/list" => ListTools(),
                "tools/call" => CallTool(msg["params"] as JsonObject),
                "resources/list" => new JsonObject { ["resources"] = new JsonArray() },
                "prompts/list" => new JsonObject { ["prompts"] = new JsonArray() },
                _ when method.StartsWith("notifications/") => null,
                _ => throw new RpcException(-32601, $"method not found: {method}"),
            };
            return notification ? null : new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["result"] = result ?? new JsonObject() };
        }
        catch (RpcException ex) { return notification ? null : Error(id, ex.Code, ex.Message); }
        catch (Exception ex) { return notification ? null : Error(id, -32603, ex.Message); }
    }

    readonly AsyncLocal<string> _client = new();
    sealed class RpcException(int code, string message) : Exception(message) { public int Code { get; } = code; }

    static JsonObject Error(JsonNode? id, int code, string message) => new()
    {
        ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(),
        ["error"] = new JsonObject { ["code"] = code, ["message"] = message },
    };

    JsonObject Initialize(JsonObject? p)
    {
        string requested = p?["protocolVersion"]?.GetValue<string>() ?? ProtocolVersion;
        return new JsonObject
        {
            ["protocolVersion"] = requested,
            ["capabilities"] = new JsonObject { ["tools"] = new JsonObject { ["listChanged"] = false } },
            ["serverInfo"] = new JsonObject { ["name"] = Name, ["version"] = Version },
            ["instructions"] = Instructions,
        };
    }

    JsonObject ListTools()
    {
        var list = new JsonArray();
        foreach (var t in _tools.Values)
            list.Add(new JsonObject
            {
                ["name"] = t.Name,
                ["description"] = t.Description,
                ["inputSchema"] = t.InputSchema.DeepClone(),
                ["annotations"] = new JsonObject { ["readOnlyHint"] = t.ReadOnly },
            });
        return new JsonObject { ["tools"] = list };
    }

    JsonObject CallTool(JsonObject? p)
    {
        var name = p?["name"]?.GetValue<string>() ?? throw new RpcException(-32602, "missing tool name");
        if (!_tools.TryGetValue(name, out var tool)) throw new RpcException(-32602, $"unknown tool '{name}' (call help for the list)");
        var args = p?["arguments"] as JsonObject ?? [];
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var (text, isError) = RunGuarded(tool, args);
        string argText = args.ToJsonString();
        var info = new McpCallInfo(_client.Value ?? "local", name, argText.Length > 400 ? argText[..400] + "..." : argText, !isError, sw.ElapsedMilliseconds,
                                   text.Length > 300 ? text[..300] + "..." : text);
        try { Log?.Invoke(info); } catch { }
        OkiRomSim.Core.AppLog.Write(isError ? OkiRomSim.Core.LogKind.Warning : OkiRomSim.Core.LogKind.Mcp, "mcp " + info.Client,
            $"{name} {(isError ? "FAILED" : "ok")} in {info.Milliseconds} ms  {info.Arguments}", text.Length > 4000 ? text[..4000] : text);
        return new JsonObject
        {
            ["content"] = new JsonArray { new JsonObject { ["type"] = "text", ["text"] = text } },
            ["isError"] = isError,
        };
    }

    // One tool at a time: tools share caches (loaded programs, the app's ROM). Each runs on its own thread with a large stack, so deep recursion in a hostile or corrupt input is an error for that call rather than the end of the process hosting the server.
    readonly SemaphoreSlim _gate = new(1, 1);

    (string Text, bool IsError) RunGuarded(McpTool tool, JsonObject args)
    {
        if (!_gate.Wait(ToolTimeout)) return ("error: the server is busy with a long-running tool; try again shortly", true);
        string text = ""; bool isError = false;
        var done = new ManualResetEventSlim();
        var t = new Thread(() =>
        {
            try { text = tool.Run(args); }
            catch (ToolException ex) { text = "error: " + ex.Message; isError = true; }
            catch (Exception ex)
            {
                text = $"error: {ex.GetType().Name}: {ex.Message}"; isError = true;
                OkiRomSim.Core.AppLog.Error("mcp", $"tool {tool.Name} threw", ex);
            }
            finally { done.Set(); _gate.Release(); }
        }, 256 * 1024 * 1024) { IsBackground = true, Name = "mcp-" + tool.Name };
        t.Start();
        if (!done.Wait(ToolTimeout)) return ($"error: {tool.Name} is still running after {ToolTimeout.TotalSeconds:0} s; its result will be discarded", true);
        return (text, isError);
    }

    /// Call a tool directly (tests, the desktop app). Throws ToolException on tool errors.
    public string Call(string tool, JsonObject? args = null) =>
        _tools.TryGetValue(tool, out var t) ? t.Run(args ?? []) : throw new ToolException($"unknown tool '{tool}'");
}

/// The directories tools may read and write. Every path an agent passes is resolved against the first root (when relative) and must end up inside one of the roots.
public sealed class Workspace
{
    readonly List<string> _roots;
    public IReadOnlyList<string> Roots => _roots;
    public bool ReadOnly { get; init; }
    /// A folder inside the workspace that an agent on another machine can always write to, for sending a file across and asking for it to be opened. The host sets it (the desktop app keeps one beside its settings and puts it in the workspace); left unset, the first root is used, which is what a head-less server started with --root already means.
    public string? TransferDir { get; set; }

    /// Where an upload lands when no folder was named.
    public string Transfer => TransferDir is { Length: > 0 } t ? t : Roots[0];
    /// Asked before a folder outside the workspace is taken in: the desktop app puts the question to the user. Null (a head-less server) means the answer is no.
    public Func<string, string, bool>? AskToAddRoot { get; set; }

    public Workspace(IEnumerable<string> roots)
    {
        _roots = [.. roots.Select(r => Path.TrimEndingDirectorySeparator(Path.GetFullPath(r))).Distinct()];
        if (_roots.Count == 0) throw new ArgumentException("at least one workspace root is needed");
    }

    /// Take a folder into the workspace for the rest of this run, once the user has said yes. Returns what to tell the agent.
    public string AddRoot(string folder, string why)
    {
        var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
        if (File.Exists(full)) full = Path.GetDirectoryName(full)!;
        if (!Directory.Exists(full)) throw new ToolException($"'{folder}' is not a folder on the machine running the simulator");
        if (Allows(full)) return $"{full} is already in the workspace";
        if (AskToAddRoot == null)
            throw new ToolException("this server cannot be asked to take in another folder (it is not the one inside the desktop app); " +
                                    "start it with --root, or send the file with file_upload / rom_upload instead");
        if (!AskToAddRoot(full, why)) throw new ToolException($"the user did not allow '{full}' to be added to the workspace");
        _roots.Add(full);
        return $"{full} added to the workspace for this session";
    }

    static readonly StringComparison Cmp = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    public string Resolve(string? path, bool mustExist = true, bool forWrite = false)
    {
        if (string.IsNullOrWhiteSpace(path)) throw new ToolException("a path is required");
        if (forWrite && ReadOnly) throw new ToolException("the workspace is read-only");
        string full = Path.GetFullPath(Path.IsPathRooted(path) ? path : Path.Combine(Roots[0], path));
        bool inside = Roots.Any(r => full.Equals(r, Cmp) || full.StartsWith(r + Path.DirectorySeparatorChar, Cmp));
        if (!inside)
            throw new ToolException(
                $"'{path}' is outside the workspace ({string.Join(", ", Roots)}). " +
                "The simulator may be on another machine, so a path you can see is not necessarily a path it can: " +
                "send the file with file_upload (or rom_upload for a ROM to open), or call workspace_allow to ask the user to let this folder in.");
        // refuse links that point out of the workspace
        var info = new FileInfo(full);
        if (info.Exists && info.LinkTarget != null)
        {
            var target = info.ResolveLinkTarget(true)?.FullName ?? "";
            if (!Roots.Any(r => target.StartsWith(r + Path.DirectorySeparatorChar, Cmp))) throw new ToolException($"'{path}' links outside the workspace");
        }
        return mustExist && !File.Exists(full) && !Directory.Exists(full) ? throw new ToolException($"'{path}' does not exist") : full;
    }

    /// True when a full path is inside the workspace (the assembler's include sandbox).
    public bool Allows(string full)
    {
        try
        {
            full = Path.GetFullPath(full);
            return _roots.Any(r => full.Equals(r, Cmp) || full.StartsWith(r + Path.DirectorySeparatorChar, Cmp));
        }
        catch { return false; }
    }

    /// Path shown back to the agent: relative to the first root when inside it.
    public string Show(string full)
    {
        var r = Roots[0];
        return full.StartsWith(r + Path.DirectorySeparatorChar, Cmp) ? full[(r.Length + 1)..].Replace('\\', '/') : full;
    }
}
