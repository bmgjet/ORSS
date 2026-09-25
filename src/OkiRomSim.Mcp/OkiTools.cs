// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;
using Decoder = OkiRomSim.Core.Decoder;

namespace OkiRomSim.Mcp;

/// The tools. Every result is plain text sized for an agent's context: listings, traces and disassemblies go to files (the result names them) and file_read pages through them.
public sealed class OkiTools
{
    readonly Workspace _ws;
    readonly McpServer _server;
    const int InlineLimit = 12_000;

    public OkiTools(Workspace ws, McpServer server) { _ws = ws; _server = server; }

    // ------------------------------------------------------------------ schema helpers

    internal static JsonObject Schema(params (string Name, string Type, string Description, bool Required)[] props)
    {
        var p = new JsonObject();
        var req = new JsonArray();
        foreach (var (name, type, desc, required) in props)
        {
            var o = new JsonObject { ["description"] = desc };
            if (type.EndsWith("[]")) { o["type"] = "array"; o["items"] = new JsonObject { ["type"] = type[..^2] }; }
            else o["type"] = type;
            p[name] = o;
            if (required) req.Add(name);
        }
        return new JsonObject { ["type"] = "object", ["properties"] = p, ["required"] = req };
    }

    internal static string? S(JsonObject a, string k) => a[k] is JsonValue v ? v.ToString() : null;
    internal static string Req(JsonObject a, string k) => S(a, k) is { Length: > 0 } s ? s : throw new ToolException($"'{k}' is required");
    internal static int I(JsonObject a, string k, int def)
    {
        if (a[k] is not JsonValue v) return def;
        if (v.TryGetValue<int>(out var i)) return i;
        return v.TryGetValue<double>(out var d) ? (int)d : int.TryParse(v.ToString(), out i) ? i : def;
    }
    internal static double D(JsonObject a, string k, double def)
    {
        if (a[k] is not JsonValue v) return def;
        return v.TryGetValue<double>(out var d)
            ? d
            : double.TryParse(v.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out d) ? d : def;
    }
    internal static bool B(JsonObject a, string k, bool def) =>
        a[k] is JsonValue v ? (v.TryGetValue<bool>(out var b) ? b : v.ToString().Equals("true", StringComparison.OrdinalIgnoreCase)) : def;

    string Spill(string text, string? requestedPath, string defaultName, string what)
    {
        if (requestedPath == null && text.Length <= InlineLimit) return text;
        var path = _ws.Resolve(requestedPath ?? Path.Combine(".okirom", defaultName), mustExist: false, forWrite: true);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
        int lines = text.Count(c => c == '\n') + 1;
        return $"{what} written to {_ws.Show(path)} ({lines} lines, {text.Length:N0} chars). Page through it with file_read.";
    }

    Program66k Load(JsonObject a, string key = "path")
    {
        var p = S(a, key);
        if ((string.IsNullOrWhiteSpace(p) || p.Equals("session", StringComparison.OrdinalIgnoreCase)) && _server.Session is { } s && s.RomPath != null)
        {
            lock (this)
            {
                if (_sessionProgram == null || _sessionVersion != s.Version)
                {
                    var rom = s.Rom();
                    _sessionProgram = s.Assembly is { } asm ? Program66k.FromAssembly(s.RomPath, rom, asm, s.Sources()) : Program66k.FromImage(rom, s.RomPath);
                    _sessionVersion = s.Version;
                }
                return _sessionProgram;
            }
        }
        return Program66k.Load(_ws.Resolve(Req(a, key)), _ws.Allows);
    }
    Program66k? _sessionProgram;
    int _sessionVersion = -1;

    // ------------------------------------------------------------------ the tools

    public IEnumerable<McpTool> All()
    {
        yield return new McpTool("help", "List every tool with its arguments, and the recommended workflow. Call this first.",
            Schema(("tool", "string", "optional: one tool to describe in detail", false)), Help);

        yield return new McpTool("arch",
            "Architecture guide for the OKI MSM66207 (66K / nX-8/200) and the Honda P28 board. Topics: overview, memory, registers, dd (8/16-bit data descriptor), " +
            "addressing (incl. indirect and double-indirect 'redirect' jumps), instructions, branches, stack, interrupts, p28, maps, assembler, pitfalls, all. No topic lists them.",
            Schema(("topic", "string", "topic name, 'all', or a word to search for", false)), a => Knowledge.Get(S(a, "topic")));

        yield return new McpTool("opcode",
            "Every encoding of an instruction: operand form, bytes (N8 = 8-bit immediate, NL NH = 16-bit little-endian, rel8 = signed branch offset, S8 = signed displacement, addrl addrh = absolute address), " +
            "length, machine cycles, whether it needs DD=1 (word) or DD=0 (byte) or sets/resets DD, and what it does. Accepts a mnemonic (ADD, LB, JBS), a full form ('L A, N16[X1]') or opcode hex bytes ('C4 20 13').",
            Schema(("query", "string", "mnemonic, operand form, or hex bytes", true), ("limit", "integer", "max encodings listed (default 40)", false)), Opcode);

        yield return new McpTool("file_list", "List files in a workspace directory (non-recursive unless recursive=true).",
            Schema(("path", "string", "directory (default: workspace root)", false), ("pattern", "string", "glob, e.g. *.asm", false), ("recursive", "boolean", "descend into subdirectories", false)), FileList);

        yield return new McpTool("file_read", "Read a text file a page at a time, with line numbers. Use start_line / lines to page; the result says how many lines the file has.",
            Schema(("path", "string", "file", true), ("start_line", "integer", "first line, 1-based (default 1)", false), ("lines", "integer", "how many lines (default 200, max 2000)", false)), FileRead);

        yield return new McpTool("file_search", "Search a file (or every .asm/.inc in a directory) with a regular expression; returns matching lines with numbers.",
            Schema(("path", "string", "file or directory", true), ("pattern", "string", ".NET regex, case-insensitive", true),
                   ("max", "integer", "max matches (default 100)", false), ("context", "integer", "lines of context around each match (default 0)", false)), FileSearch);

        yield return new McpTool("file_write", "Create or overwrite a text file (set overwrite=true to replace an existing file).",
            Schema(("path", "string", "file", true), ("content", "string", "full text", true), ("overwrite", "boolean", "allow replacing an existing file", false)), FileWrite, ReadOnly: false);

        yield return new McpTool("workspace_roots",
            "The folders this server can reach, on the machine it runs on. Paths outside them are refused, so check here before passing a path an agent " +
            "can see locally - the simulator may be on another computer.",
            Schema(), _ => $"workspace roots ({(_ws.ReadOnly ? "read-only" : "writable")}):\n  " + string.Join("\n  ", _ws.Roots) +
                           "\nAnything outside these: send it with file_upload / rom_upload, or ask for it with workspace_allow.");

        yield return new McpTool("workspace_allow",
            "Ask the user, in the desktop app, to let a folder on that machine into the workspace for this session. Use it when the file you need is " +
            "there but outside the roots; the user sees the folder and the reason and says yes or no. Only the app's own server can ask.",
            Schema(("path", "string", "folder on the machine running the simulator", true),
                   ("reason", "string", "what it is for, shown to the user", false)), a =>
                _ws.AddRoot(Req(a, "path"), S(a, "reason") ?? "an agent asked to open a file there"), ReadOnly: false);

        yield return new McpTool("transfer_dir",
            "The folder on the simulator's machine that this server can always write to, and the path to give file_upload when you have nowhere else to " +
            "put a file. The whole round trip for an agent on a different computer is: transfer_dir, then file_upload (in chunks) into it, then app_open " +
            "to open what you sent in the desktop app; file_download brings a file back the same way.",
            Schema(), _ => $"transfer folder: {_ws.Transfer}\nupload into it with file_upload path=\"{Path.Combine(_ws.Transfer, "yourfile.bin")}\" " +
                           "(or just \"yourfile.bin\", which is taken as relative to the first workspace root), then open it with app_open.");

        yield return new McpTool("app_open",
            "Open a file that is on the simulator's machine in the desktop app, exactly as the File menu would: a .asm is assembled and loaded, a .bin " +
            "or .rom is disassembled and loaded, a saved project .zip is restored. Use it after file_upload to work on a file you sent from another " +
            "computer. The ROM then answers to cal_detect, the simulator, the datalog and the emulator, and the user sees it open.",
            Schema(("path", "string", "file on the simulator's machine (a path from transfer_dir, or any path inside the workspace)", true)), a =>
            {
                var session = _server.Session ?? throw new ToolException(
                    "no app session: this server is not the one inside the desktop app, so there is no window to open a file in " +
                    "(point your client at the app's HTTP server instead - Settings > MCP server)");
                var path = _ws.Resolve(Req(a, "path"));
                return session.OpenFile(path);
            }, ReadOnly: false);

        yield return new McpTool("file_download",
            "Read any file as base64, in chunks - how an agent on another machine gets a .bin, a log or a project out of the workspace. " +
            "The result gives the total size, this chunk's offset and the file's SHA-256, so a transfer can be resumed and checked.",
            Schema(("path", "string", "file", true), ("offset", "integer", "first byte (default 0)", false),
                   ("max_bytes", "integer", "bytes in this chunk (default 262144, max 4 MB)", false)), FileDownload);

        yield return new McpTool("file_upload",
            "Write base64 into a file, in chunks - how an agent on another machine puts a .bin, .asm or definitions into the workspace. " +
            "offset=0 (or leaving it out) starts a new file; later chunks append at their offset. Returns the size so far and its SHA-256.",
            Schema(("path", "string", "file", true), ("data", "string", "base64 of this chunk", true),
                   ("offset", "integer", "where this chunk goes (default: the end of the file, 0 for a new one)", false),
                   ("sha256", "string", "expected SHA-256 of the whole file, checked once the last chunk lands", false)), FileUpload, ReadOnly: false);

        yield return new McpTool("rom_download",
            "The ROM image the desktop app has open (with every calibration edit), as base64 - for an agent running on another machine.",
            Schema(), _ =>
            {
                var s2 = _server.Session ?? throw new ToolException("no app session: use file_download for a file");
                var rom = s2.Rom();
                return $"{rom.Length} bytes, sha256 {Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(rom))}\n{Convert.ToBase64String(rom)}";
            });

        yield return new McpTool("rom_upload",
            "Send a ROM image (base64) to the desktop app and open it there, as if it had been opened from disk: it is disassembled, built and ready for " +
            "cal_detect, the simulator and the emulator. For an agent working from another machine.",
            Schema(("data", "string", "base64 of the .bin image (leave out when using path)", false),
                   ("path", "string", "a .bin already on the simulator's machine, instead of data (what file_upload wrote)", false),
                   ("name", "string", "name to show it under", false)), a =>
            {
                var s2 = _server.Session ?? throw new ToolException("no app session: write the file with file_upload instead");
                byte[] rom;
                // an image larger than one request, or one already sent across in chunks, comes by path instead: file_upload it into transfer_dir first
                if (S(a, "path") is { Length: > 0 } from) rom = File.ReadAllBytes(_ws.Resolve(from));
                else
                {
                    try { rom = Convert.FromBase64String(Req(a, "data")); }
                    catch (FormatException) { throw new ToolException("data is not valid base64"); }
                }
                return rom.Length is 0 or > Bus.RomSize + 1
                    ? throw new ToolException($"a 66207 image is 1..{Bus.RomSize} bytes, got {rom.Length}")
                    : s2.LoadRom(rom, S(a, "name") ?? "uploaded");
            }, ReadOnly: false);

        yield return new McpTool("file_edit",
            "Replace text in a file: old_text must occur exactly once (or pass all=true). Keeps everything else byte-for-byte. For line-based edits use file_edit_lines.",
            Schema(("path", "string", "file", true), ("old_text", "string", "text to find (exact, including spacing)", true), ("new_text", "string", "replacement", true),
                   ("all", "boolean", "replace every occurrence", false)), FileEdit, ReadOnly: false);

        yield return new McpTool("file_edit_lines",
            "Replace lines start_line..end_line (inclusive) with new text; end_line = start_line - 1 inserts before start_line without removing anything.",
            Schema(("path", "string", "file", true), ("start_line", "integer", "first line to replace, 1-based", true), ("end_line", "integer", "last line to replace", true),
                   ("text", "string", "new lines (may be empty to delete)", true)), FileEditLines, ReadOnly: false);

        yield return new McpTool("assemble",
            "Assemble a .asm (syntax plus include/if/module...). Reports errors/warnings with file:line, bytes used and free space; writes the .bin " +
            "(default next to the source) and optionally .sym/.lst/.map.",
            Schema(("path", "string", ".asm file", true), ("output", "string", "output .bin (default: <source>.bin)", false),
                   ("compat", "boolean", "lenient mode (undefined symbols etc. become warnings)", false),
                   ("listing", "boolean", "also write .lst", false), ("map", "boolean", "also write .map (module sizes, free regions)", false),
                   ("sym", "boolean", "also write .sym (default true)", false), ("write", "boolean", "false = check only, write nothing", false)), Assemble, ReadOnly: false);

        yield return new McpTool("disassemble",
            "Disassemble a .bin/.rom image into an editable .asm: follows the code from the reset/interrupt/VCAL vectors tracking DD, labels branch and call targets, " +
            "names SFRs, keeps unreached bytes as DB, and verifies the text reassembles to the identical image. Writes the file; returns a summary.",
            Schema(("path", "string", ".bin or .rom", true), ("output", "string", "output .asm (default <image>.disasm.asm)", false),
                   ("bit_test_mnemonic", "string", "spell the test-bit opcode TBR (default) or TRB - both assemble to the same bytes", false)), Disassemble, ReadOnly: false);

        yield return new McpTool("disassemble_range", "Show a few instructions at an address or label, with bytes, labels and source line (works on .asm and .bin).",
            Schema(("path", "string", ".asm or .bin (inside the app: leave out for the ROM open there)", false), ("address", "string", "label or hex address", true), ("count", "integer", "instructions (default 30)", false)), DisassembleRange);

        yield return new McpTool("symbols", "Find labels/equates by name (substring or regex) or what is at an address (nearest label, source line, bytes).",
            Schema(("path", "string", ".asm or .bin (inside the app: leave out for the ROM open there)", false), ("filter", "string", "name substring/regex", false), ("at", "string", "address or label to describe", false),
                   ("max", "integer", "max results (default 100)", false)), Symbols);

        yield return new McpTool("xref", "Every instruction that reads, writes, calls or jumps to an address or label.",
            Schema(("path", "string", ".asm or .bin (inside the app: leave out for the ROM open there)", false), ("target", "string", "label or hex address", true), ("max", "integer", "max results (default 80)", false)), Xref);

        yield return new McpTool("explore",
            "Follow the code from a label/address like the CPU would (both sides of every branch, calls noted), and report what it touches (RAM read/written, SFRs, port bits, ROM tables) " +
            "and a guess at its purpose from the hardware it drives; callees are summarised to `depth`. The full annotated listing goes to a file when long.",
            Schema(("path", "string", ".asm or .bin (inside the app: leave out for the ROM open there)", false), ("entry", "string", "label or hex address", true), ("depth", "integer", "callee levels to summarise (default 1)", false),
                   ("max_instructions", "integer", "limit for the entry routine (default 600)", false), ("output", "string", "file for the full listing", false)), Explore);

        yield return new McpTool("detect_tables",
            "Find the fuel/ignition/VE maps from the code that looks them up: address, rows x columns, row stride, fuel multiplier row, RPM and load axes with their scaling.",
            Schema(("path", "string", ".asm or .bin (inside the app: leave out for the ROM open there)", false)), DetectTables);

        yield return new McpTool("run",
            "Boot the ROM (.asm is assembled first) in the MSM66207 simulator with a simulated engine and report: where it is, faults/BRK traps, fuel pump, injector pulse widths and rates, " +
            "ignition events, VTEC, coverage, and optional RAM watches. Stops at `until` (label/address) or after `seconds` of simulated time. Boot delay loops are fast-forwarded.",
            Schema(("path", "string", ".asm or .bin (inside the app: leave out for the ROM open there)", false), ("seconds", "number", "simulated seconds (default 8; the stock ROMs spend ~4.5 s of chip time in a boot delay, fast-forwarded here)", false),
                   ("rpm", "number", "engine rpm (default 800)", false), ("map_kpa", "number", "manifold pressure kPa (default 33)", false),
                   ("tps_pct", "number", "throttle % (default 0)", false), ("ect_c", "number", "coolant C (default 85)", false), ("iat_c", "number", "intake air C (default 25)", false),
                   ("o2_v", "number", "O2 volts (default 0.45)", false), ("batt_v", "number", "battery volts (default 14.2)", false), ("speed_kmh", "number", "road speed (default 0)", false),
                   ("until", "string", "stop when execution reaches this label/address", false), ("watch", "string[]", "RAM addresses/labels to report (byte and word)", false),
                   ("trace", "integer", "also return the last N executed instructions (written to trace_file when large)", false), ("trace_file", "string", "file for the trace", false)), Run, ReadOnly: false);

        yield return new McpTool("compare_bins", "Byte differences between two images, grouped into ranges and named by label (checks a patch changed only what was intended).",
            Schema(("a", "string", "first .bin or .asm", true), ("b", "string", "second .bin or .asm", true), ("max", "integer", "max ranges (default 100)", false)), CompareBins);
    }

    // ------------------------------------------------------------------ help / knowledge

    string Help(JsonObject a)
    {
        var tools = _server.Tools;
        if (S(a, "tool") is { Length: > 0 } name)
        {
            var t = tools.FirstOrDefault(x => x.Name == name) ?? throw new ToolException($"no tool '{name}'");
            var sb1 = new StringBuilder($"{t.Name}: {t.Description}\n\narguments:\n");
            var props = (JsonObject)t.InputSchema["properties"]!;
            var req = ((JsonArray)t.InputSchema["required"]!).Select(x => x!.ToString()).ToHashSet();
            foreach (var (k, v) in props) sb1.AppendLine($"  {k} ({v!["type"]}{(req.Contains(k) ? ", required" : "")}): {v["description"]}");
            return sb1.ToString();
        }
        var sb = new StringBuilder();
        sb.AppendLine("okirom-mcp - OKI MSM66207 (66K) ROM development tools");
        sb.AppendLine($"workspace: {string.Join(", ", _ws.Roots)}{(_ws.ReadOnly ? " (read-only)" : "")} - relative paths start at the first root");
        sb.AppendLine();
        foreach (var t in tools)
        {
            var props = (JsonObject)t.InputSchema["properties"]!;
            var req = ((JsonArray)t.InputSchema["required"]!).Select(x => x!.ToString()).ToHashSet();
            var args = string.Join(", ", props.Select(kv => req.Contains(kv.Key) ? kv.Key : kv.Key + "?"));
            var first = t.Description.Split(". ")[0].TrimEnd('.');
            sb.AppendLine($"{t.Name}({args})\n    {first}.");
        }
        sb.AppendLine();
        sb.AppendLine("""
WORKFLOW
  1. arch (overview, then dd and addressing) - the two things that trip everyone up
  2. disassemble a .bin -> .asm, or start from an existing .asm; symbols / file_search to find code
  3. explore <label> to see what a routine does; opcode <mnemonic> for exact encodings
  4. file_edit / file_edit_lines to change the source, assemble to build (errors carry file:line)
  5. run to boot it: it must reach the main loop with the fuel pump ON, injecting, and no BRK traps;
     compare_bins against the original to confirm only the intended bytes changed
Paths are confined to the workspace. Large outputs go to .okirom/ files - read them with file_read.
""");
        return sb.ToString();
    }

    string Opcode(JsonObject a)
    {
        var q = Req(a, "query").Trim();
        int limit = Math.Clamp(I(a, "limit", 40), 1, 400);
        var table = FullOpcodes.Table;
        IEnumerable<int> hits;
        var hex = Regex.Matches(q, @"\b[0-9A-Fa-f]{2}\b").Select(m => Convert.ToByte(m.Value, 16)).ToArray();
        if (hex.Length > 0 && Regex.IsMatch(q, @"^([0-9A-Fa-f]{2}\s*)+$"))
        {
            var sb0 = new StringBuilder($"bytes {q}:\n");
            foreach (var dd in new[] { true, false })
            {
                var d = Decoder.Decode(dd, i => i < hex.Length ? hex[i] : (byte)0);
                sb0.AppendLine(d == null ? $"  DD={(dd ? 1 : 0)}: no instruction" : $"  DD={(dd ? 1 : 0)}: {Decoder.Format(d, (ushort)d.Len)}  ({d.Mnemonic}, {d.Len} bytes, {d.Cycles} cycles)");
            }
            return sb0.ToString();
        }
        string qu = q.ToUpperInvariant();
        string baseOp = qu.Split(' ', ',')[0];
        string norm(string s) => Regex.Replace(s.ToUpperInvariant(), @"\s+", " ").Replace(" ,", ",");
        if (baseOp == "TRB") { qu = "TBR" + qu[3..]; baseOp = "TBR"; }
        hits = Enumerable.Range(0, table.Length).Where(i =>
            q.Contains(' ') ? norm(table[i].Mnemonic).StartsWith(norm(qu)) : table[i].Mnemonic.Split(' ')[0].Equals(baseOp, StringComparison.OrdinalIgnoreCase));
        var list = hits.ToList();
        if (list.Count == 0) throw new ToolException($"no instruction '{q}'. Instruction groups: arch topic=instructions");
        var sb = new StringBuilder();
        string key = Regex.Replace(baseOp, "B$", "");
        if (InstructionInfo.Descriptions.TryGetValue(baseOp, out var desc) || InstructionInfo.Descriptions.TryGetValue(key, out desc))
            sb.AppendLine($"{baseOp}: {desc}");
        if (baseOp == "TBR") sb.AppendLine("TBR and TRB are two spellings of the same instruction; the assembler accepts both.");
        sb.AppendLine($"{list.Count} encoding(s){(list.Count > limit ? $", first {limit}" : "")}:");
        sb.AppendLine("  form                              bytes                   len  cycles  DD");
        foreach (var i in list.Take(limit))
        {
            var p = table[i];
            string dd = p.DdMode switch { '1' => "needs DD=1 (word)", '0' => "needs DD=0 (byte)", 'S' => "sets DD=1", 'R' => "sets DD=0", _ => "" };
            sb.AppendLine($"  {p.Mnemonic,-33} {string.Join(" ", p.BytesPat),-23} {p.BytesPat.Length,3}  {Decoder.IntCycles(p.Mnemonic, p.BytesPat.Length),6}  {dd}");
        }
        sb.AppendLine("Cycles are internal-memory machine cycles (fOSC/2); a taken conditional branch costs 4 more.");
        return sb.ToString();
    }

    // ------------------------------------------------------------------ files

    string FileList(JsonObject a)
    {
        var dir = _ws.Resolve(S(a, "path") ?? ".");
        if (!Directory.Exists(dir)) throw new ToolException($"{S(a, "path")} is not a directory");
        var opt = B(a, "recursive", false) ? SearchOption.AllDirectories : SearchOption.TopDirectoryOnly;
        var sb = new StringBuilder();
        foreach (var d in Directory.GetDirectories(dir).OrderBy(x => x).Take(200)) sb.AppendLine($"  {_ws.Show(d)}/");
        foreach (var f in Directory.GetFiles(dir, S(a, "pattern") ?? "*", opt).OrderBy(x => x).Take(1000))
            sb.AppendLine($"  {_ws.Show(f),-60} {new FileInfo(f).Length,10:N0} bytes");
        return sb.Length == 0 ? "(empty)" : sb.ToString();
    }

    string FileRead(JsonObject a)
    {
        var path = _ws.Resolve(Req(a, "path"));
        var lines = File.ReadAllLines(path);
        int start = Math.Max(1, I(a, "start_line", 1)), n = Math.Clamp(I(a, "lines", 200), 1, 2000);
        var sb = new StringBuilder($"{_ws.Show(path)}: lines {start}-{Math.Min(lines.Length, start + n - 1)} of {lines.Length}\n");
        for (int i = start; i < start + n && i <= lines.Length; i++) sb.Append(i.ToString().PadLeft(6)).Append("  ").AppendLine(lines[i - 1]);
        if (start + n <= lines.Length) sb.AppendLine($"... ({lines.Length - (start + n - 1)} more; next start_line={start + n})");
        return sb.ToString();
    }

    string FileSearch(JsonObject a)
    {
        var path = _ws.Resolve(Req(a, "path"));
        Regex rx;
        try { rx = new Regex(Req(a, "pattern"), RegexOptions.IgnoreCase, TimeSpan.FromSeconds(2)); }
        catch (ArgumentException ex) { throw new ToolException("bad regex: " + ex.Message); }
        int max = Math.Clamp(I(a, "max", 100), 1, 2000), ctx = Math.Clamp(I(a, "context", 0), 0, 10);
        var files = Directory.Exists(path)
            ? Directory.GetFiles(path, "*.*", SearchOption.AllDirectories).Where(f => f.EndsWith(".asm", StringComparison.OrdinalIgnoreCase) || f.EndsWith(".inc", StringComparison.OrdinalIgnoreCase))
            : new[] { path };
        var sb = new StringBuilder();
        int found = 0;
        foreach (var f in files)
        {
            var lines = File.ReadAllLines(f);
            for (int i = 0; i < lines.Length && found < max; i++)
            {
                if (!rx.IsMatch(lines[i])) continue;
                found++;
                for (int j = Math.Max(0, i - ctx); j <= Math.Min(lines.Length - 1, i + ctx); j++)
                    sb.AppendLine($"{_ws.Show(f)}:{j + 1}{(j == i ? ":" : "-")} {lines[j]}");
                if (ctx > 0) sb.AppendLine("--");
            }
        }
        return found == 0 ? "no matches" : $"{found} match(es){(found >= max ? " (limit reached)" : "")}\n" + sb;
    }

    string FileWrite(JsonObject a)
    {
        var path = _ws.Resolve(Req(a, "path"), mustExist: false, forWrite: true);
        if (File.Exists(path) && !B(a, "overwrite", false)) throw new ToolException("the file exists; pass overwrite=true to replace it (or use file_edit)");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var content = S(a, "content") ?? "";
        File.WriteAllText(path, content);
        return $"wrote {_ws.Show(path)} ({content.Count(c => c == '\n') + 1} lines)";
    }

    string FileEdit(JsonObject a)
    {
        var path = _ws.Resolve(Req(a, "path"), forWrite: true);
        var text = File.ReadAllText(path);
        var old = S(a, "old_text") ?? throw new ToolException("'old_text' is required");
        var neu = S(a, "new_text") ?? "";
        if (old.Length == 0) throw new ToolException("old_text is empty");
        // tolerate \n in the request against \r\n files
        if (!text.Contains(old) && text.Contains("\r\n") && old.Contains('\n') && !old.Contains("\r\n"))
        { old = old.Replace("\n", "\r\n"); neu = neu.Replace("\r\n", "\n").Replace("\n", "\r\n"); }
        int count = Regex.Matches(text, Regex.Escape(old)).Count;
        if (count == 0) throw new ToolException("old_text not found (it must match exactly, including spaces; file_search helps find it)");
        if (count > 1 && !B(a, "all", false)) throw new ToolException($"old_text occurs {count} times; add surrounding lines to make it unique, or pass all=true");
        int line = text[..text.IndexOf(old, StringComparison.Ordinal)].Count(c => c == '\n') + 1;
        text = B(a, "all", false) ? text.Replace(old, neu) : ReplaceFirst(text, old, neu);
        File.WriteAllText(path, text);
        return $"edited {_ws.Show(path)}: {(count > 1 ? count + " replacements" : "1 replacement")} starting at line {line}";
    }

    static string ReplaceFirst(string s, string a, string b)
    {
        int i = s.IndexOf(a, StringComparison.Ordinal);
        return s[..i] + b + s[(i + a.Length)..];
    }

    string FileEditLines(JsonObject a)
    {
        var path = _ws.Resolve(Req(a, "path"), forWrite: true);
        var raw = File.ReadAllText(path);
        string nl = raw.Contains("\r\n") ? "\r\n" : "\n";
        var lines = raw.Replace("\r\n", "\n").Split('\n').ToList();
        int s = I(a, "start_line", -1), e = I(a, "end_line", -1);
        if (s < 1 || s > lines.Count + 1 || e < s - 1 || e > lines.Count) throw new ToolException($"line range {s}..{e} is outside the file (1..{lines.Count})");
        var text = S(a, "text") ?? "";
        var add = text.Length == 0 ? [] : text.Replace("\r\n", "\n").TrimEnd('\n').Split('\n').ToList();
        lines.RemoveRange(s - 1, e - s + 1);
        lines.InsertRange(s - 1, add);
        File.WriteAllText(path, string.Join(nl, lines));
        return $"{_ws.Show(path)}: replaced {e - s + 1} line(s) at {s} with {add.Count}; the file now has {lines.Count} lines";
    }

    // ------------------------------------------------------------------ build

    string Assemble(JsonObject a)
    {
        var src = _ws.Resolve(Req(a, "path"));
        var opt = new AssemblerOptions { LenientMode = B(a, "compat", false), AllowFile = _ws.Allows };
        var r = new OkiAssembler(opt).AssembleFile(src);
        var sb = new StringBuilder();
        int errors = r.Diagnostics.Count(d => d.Severity == Severity.Error), warnings = r.Diagnostics.Count(d => d.Severity == Severity.Warning);
        sb.AppendLine(r.Success ? $"OK: {r.UsedBytes:N0} of {r.Image.Length:N0} bytes used ({100.0 * r.UsedBytes / r.Image.Length:F1}%), {warnings} warning(s)"
                                : $"FAILED: {errors} error(s), {warnings} warning(s)");
        foreach (var d in r.Diagnostics.OrderByDescending(d => d.Severity).Take(60))
            sb.AppendLine($"  {d.Severity.ToString().ToLowerInvariant()} {_ws.Show(d.File)}:{d.Line}: {d.Message}");
        if (r.Diagnostics.Count > 60) sb.AppendLine($"  ... {r.Diagnostics.Count - 60} more");
        if (r.Success)
        {
            var free = r.FreeRegions(64).OrderByDescending(f => f.End - f.Start).Take(5).ToList();
            if (free.Count > 0) sb.AppendLine("largest free (FF-filled) regions: " + string.Join(", ", free.Select(f => $"{f.Start:X4}-{f.End - 1:X4} ({f.End - f.Start} bytes)")));
            if (B(a, "write", true))
            {
                var outPath = _ws.Resolve(S(a, "output") ?? Path.ChangeExtension(src, ".bin"), mustExist: false, forWrite: true);
                File.WriteAllBytes(outPath, r.Image);
                sb.AppendLine($"wrote {_ws.Show(outPath)}");
                if (B(a, "sym", true)) File.WriteAllText(Path.ChangeExtension(outPath, ".sym"), OkiAssembler.WriteSymbolFile(r));
                if (B(a, "listing", false)) { File.WriteAllText(Path.ChangeExtension(outPath, ".lst"), OkiAssembler.WriteListing(r)); sb.AppendLine($"wrote {_ws.Show(Path.ChangeExtension(outPath, ".lst"))}"); }
                if (B(a, "map", false)) { File.WriteAllText(Path.ChangeExtension(outPath, ".map"), OkiAssembler.WriteMap(r)); sb.AppendLine($"wrote {_ws.Show(Path.ChangeExtension(outPath, ".map"))}"); }
            }
        }
        return sb.ToString();
    }

    const int MaxChunk = 4 * 1024 * 1024;

    string FileDownload(JsonObject a)
    {
        var path = _ws.Resolve(Req(a, "path"));
        var info = new FileInfo(path);
        long offset = Math.Clamp(I(a, "offset", 0), 0, Math.Max(0, info.Length));
        int want = Math.Clamp(I(a, "max_bytes", 256 * 1024), 1, MaxChunk);
        var buf = new byte[(int)Math.Min(want, info.Length - offset)];
        using (var fs = File.OpenRead(path))
        {
            fs.Position = offset;
            fs.ReadExactly(buf, 0, buf.Length);
        }
        string sha = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(path)));
        return $"{_ws.Show(path)}: {info.Length} bytes total, sha256 {sha}; this chunk {offset}..{offset + buf.Length - 1}" +
               (offset + buf.Length < info.Length ? $" (ask again with offset={offset + buf.Length})" : " (complete)") +
               "\n" + Convert.ToBase64String(buf);
    }

    string FileUpload(JsonObject a)
    {
        var path = _ws.Resolve(Req(a, "path"), mustExist: false, forWrite: true);
        byte[] chunk;
        try { chunk = Convert.FromBase64String(Req(a, "data")); }
        catch (FormatException) { throw new ToolException("data is not valid base64"); }
        if (chunk.Length > MaxChunk) throw new ToolException($"chunks are at most {MaxChunk} bytes");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        long offset = a["offset"] is { } ? Math.Max(0, I(a, "offset", 0)) : (File.Exists(path) ? new FileInfo(path).Length : 0);
        using (var fs = new FileStream(path, offset == 0 ? FileMode.Create : FileMode.OpenOrCreate, FileAccess.Write))
        {
            if (offset > fs.Length) throw new ToolException($"offset {offset} is past the end of the file ({fs.Length} bytes so far)");
            fs.Position = offset;
            fs.Write(chunk);
            fs.SetLength(offset + chunk.Length);
        }
        var all = File.ReadAllBytes(path);
        string sha = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(all));
        return S(a, "sha256") is { Length: > 0 } want && !sha.Equals(want.Replace("-", ""), StringComparison.OrdinalIgnoreCase)
            ? $"{_ws.Show(path)}: {all.Length} bytes written, but sha256 {sha} does not match the {want} you gave - send the file again"
            : $"{_ws.Show(path)}: {all.Length} bytes, sha256 {sha}";
    }

    string Disassemble(JsonObject a)
    {
        var path = _ws.Resolve(Req(a, "path"));
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length > Bus.RomSize + 1) throw new ToolException($"{bytes.Length} bytes is larger than a 66207 ROM ({Bus.RomSize})");
        var outPath = _ws.Resolve(S(a, "output") ?? Path.ChangeExtension(path, ".disasm.asm"), mustExist: false, forWrite: true);
        var image = new byte[Bus.RomSize];
        Array.Fill(image, (byte)0xFF);
        Array.Copy(bytes, image, Math.Min(bytes.Length, Bus.RomSize));
        var dis = Program66k.Disassemble(image, path, outPath);
        var text = dis.Text;
        if ((S(a, "bit_test_mnemonic") ?? "TBR").Equals("TRB", StringComparison.OrdinalIgnoreCase))
            text = Regex.Replace(text, @"(?m)^(\s*(?:[A-Za-z_]\w*:)?\s*)TBR\b", "${1}TRB");
        File.WriteAllText(outPath, text);
        return $"wrote {_ws.Show(outPath)}: {dis.CodeInstructions:N0} instructions found by following the code, {dis.DataBytes:N0} bytes kept as data, " +
               (dis.RoundTrips ? "reassembles byte-identical." : "NOTE: " + dis.Note) +
               $"\n{text.Count(c => c == '\n')} lines. Next: symbols / file_search to find routines, explore to understand one.";
    }

    string DisassembleRange(JsonObject a)
    {
        var p = Load(a);
        int addr = p.Resolve(Req(a, "address"));
        int count = Math.Clamp(I(a, "count", 30), 1, 500);
        var sb = new StringBuilder();
        for (int n = 0; n < count && addr < Bus.RomSize; n++)
        {
            var d = p.DecodeAt(addr);
            int len = d?.Len ?? 1;
            string bytes = string.Concat(Enumerable.Range(0, len).Select(i => p.Image[(addr + i) & 0x7FFF].ToString("X2")));
            string text = d == null ? $"DB {p.Image[addr]:X2}h" : Decoder.Format(d, (ushort)(addr + len));
            var src = p.SourceAt(addr);
            string label = p.Labels.TryGetValue(addr, out var l) ? l + ":" : "";
            sb.AppendLine($"{addr:X4}  {bytes,-12} {label,-24} {(src != null ? Program66k.StripLabel(src.Value.Text) : text),-40}" +
                          (src != null ? $" ; {Path.GetFileName(src.Value.File)}:{src.Value.Line}" : "") +
                          (d?.DdAfter is bool v ? (v ? " dd=1" : " dd=0") : ""));
            addr += len;
        }
        return sb.ToString();
    }

    // ------------------------------------------------------------------ symbols / xref / explore

    string Symbols(JsonObject a)
    {
        var p = Load(a);
        var sb = new StringBuilder();
        if (S(a, "at") is { Length: > 0 } at)
        {
            int addr = p.Resolve(at);
            sb.AppendLine($"{addr:X4}h = {p.Name(addr)}");
            if (p.SourceAt(addr) is { } s) sb.AppendLine($"  source {_ws.Show(s.File)}:{s.Line}: {s.Text.Trim()}");
            if (addr < Bus.RomSize)
            {
                sb.AppendLine($"  bytes {string.Concat(Enumerable.Range(0, 8).Select(i => p.Image[(addr + i) & 0x7FFF].ToString("X2") + " "))}");
                sb.AppendLine($"  {(p.IsCode(addr) ? "code" : "data")}");
            }
            if (addr < Bus.RamSize && OkiAssembler.Sfrs.FirstOrDefault(kv => kv.Value == addr).Key is string sfr) sb.AppendLine($"  data space: SFR {sfr}");
            return sb.ToString();
        }
        var filter = S(a, "filter") ?? "";
        Regex? rx = null;
        try { if (filter.Length > 0) rx = new Regex(filter, RegexOptions.IgnoreCase); } catch { }
        int max = Math.Clamp(I(a, "max", 100), 1, 5000);
        var syms = (p.Asm?.Symbols.Values ?? Enumerable.Empty<SymbolInfo>())
            .Where(s => s.Kind is SymbolKind.Label or SymbolKind.Equate)
            .Where(s => filter.Length == 0 || (rx?.IsMatch(s.Name) ?? s.Name.Contains(filter, StringComparison.OrdinalIgnoreCase)))
            .OrderBy(s => s.Value).ToList();
        foreach (var s in syms.Take(max))
            sb.AppendLine($"{s.Value:X4}  {s.Kind.ToString().ToLowerInvariant(),-6} {s.Name,-36} {(s.Kind == SymbolKind.Label && s.Value < Bus.RomSize ? (p.IsCode((int)s.Value) ? "code" : "data") : "")}" +
                          (s.File != null ? $"  {Path.GetFileName(s.File)}:{s.Line}" : ""));
        return syms.Count == 0 ? "no symbols match" : $"{syms.Count} symbol(s){(syms.Count > max ? $", first {max}" : "")}\n" + Spill(sb.ToString(), null, "symbols.txt", "symbol list");
    }

    string Xref(JsonObject a)
    {
        var p = Load(a);
        int target = p.Resolve(Req(a, "target"));
        int max = Math.Clamp(I(a, "max", 80), 1, 2000);
        var hits = Calibration.Xref.Find(p.Image, target, p.Asm?.SourceMap.Select(e => e.Address),
            x => p.Labels.GetValueOrDefault(x, ""), x => p.SourceAt(x) is { } s ? $"{Path.GetFileName(s.File)}:{s.Line}" : null, maxHits: max);
        if (hits.Count == 0) return $"nothing references {target:X4}h ({p.Name(target)})";
        var sb = new StringBuilder($"{hits.Count} reference(s) to {p.Name(target)} ({target:X4}h):\n");
        foreach (var h in hits) sb.AppendLine($"  {h.Address:X4}  {p.Name(h.Address),-32} {h.Kind,-6} {h.Text,-34} {h.Source}");
        return sb.ToString();
    }

    string Explore(JsonObject a)
    {
        var p = Load(a);
        int entry = p.Resolve(Req(a, "entry"));
        if (entry >= Bus.RomSize) throw new ToolException($"{entry:X4}h is not in ROM");
        string note = "";
        if (entry < 0x38 && !p.IsCode(entry))
        {
            int target = p.Image[entry & ~1] | (p.Image[(entry & ~1) + 1] << 8);
            note = $"{entry:X4}h is a vector-table entry; following it to {p.Name(target)} ({target:X4}h)\n";
            entry = target;
        }
        var ex = new Explorer(p);
        int depth = Math.Clamp(I(a, "depth", 1), 0, 4), max = Math.Clamp(I(a, "max_instructions", 600), 10, 20000);
        var report = note + ex.Report(entry, depth, max, 120, out var listing);
        if (listing.Count(c => c == '\n') > 120 || S(a, "output") != null)
            report += "\n\n" + Spill(listing, S(a, "output"), $"explore_{p.Name(entry).Replace('+', '_')}.lst", "full listing");
        return report;
    }

    string DetectTables(JsonObject a)
    {
        var p = Load(a);
        if (p.Asm == null) throw new ToolException("the image could not be turned into source");
        var syms = p.Asm.Symbols.Values.Where(s => s.Kind == SymbolKind.Label).GroupBy(s => s.Name).ToDictionary(g => g.Key, g => (int)g.First().Value);
        var found = TableDetector.Detect(p.Sources.Values.Select(l => string.Join("\n", l)), syms, p.Image, p.IsCode);
        if (found.Count == 0) return "no 2D map lookups recognised";
        var defs = new DefinitionSet(); defs.MergeBuiltinFormulas();
        var sb = new StringBuilder($"{found.Count} map(s):\n");
        foreach (var f in found)
        {
            var i = f.Item;
            sb.AppendLine($"{i.Name} @ {i.Address:X4}h  {i.Rows}x{i.Cols} (stride {i.Stride})  {i.Category}  formula {i.Formula}" +
                          (i.ColumnScaleAddress is int m ? $"  multiplier row @ {m:X4}h" : ""));
            if (i.RowAxis?.Address is int ra) sb.AppendLine($"   rows: {i.RowAxis.Name} @ {ra:X4}h ({i.RowAxis.Formula}): {string.Join(" ", RomData.AxisValues(defs, p.Image, i.RowAxis, i.Rows).Select(v => v.ToString("0")))}");
            if (i.ColAxis?.Address is int ca) sb.AppendLine($"   cols: {i.ColAxis.Name} @ {ca:X4}h ({i.ColAxis.Formula}): {string.Join(" ", RomData.AxisValues(defs, p.Image, i.ColAxis, i.Cols).Select(v => v.ToString("0")))}");
        }
        return sb.ToString();
    }

    // ------------------------------------------------------------------ simulation

    string Run(JsonObject a)
    {
        var p = Load(a);
        double seconds = Math.Clamp(D(a, "seconds", 8), 0.01, 60);
        var sim = new Simulator { FastForwardDelayLoops = true };
        sim.LoadRom(p.Image);
        var e = sim.Engine;
        e.Rpm = D(a, "rpm", 800); e.MapKpa = D(a, "map_kpa", 33); e.TpsPct = D(a, "tps_pct", 0);
        e.EctCelsius = D(a, "ect_c", 85); e.IatCelsius = D(a, "iat_c", 25); e.O2Volts = D(a, "o2_v", 0.45);
        e.VbattVolts = D(a, "batt_v", 14.2); e.SpeedKmh = D(a, "speed_kmh", 0);
        sim.SyncSensors();
        int? until = S(a, "until") is { Length: > 0 } u ? p.Resolve(u) : null;
        int traceN = Math.Clamp(I(a, "trace", 0), 0, 100_000);
        var trace = new Queue<TraceEntry>();
        ulong end = (ulong)(seconds * Bus.CpuHz);
        ulong windowStart = end > Bus.CpuHz ? end - Bus.CpuHz : end / 2;
        long[] injAtWindow = new long[4]; long ignAtWindow = 0; ulong windowCycles = 0; bool windowTaken = false;
        string stop = $"ran {seconds:0.###} s";
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (sim.Cpu.Cycles < end)
        {
            if (until is int t && sim.Cpu.Pc == t && sim.Cpu.Instructions > 0) { stop = $"reached {p.Name(t)}"; break; }
            var te = sim.StepOne();
            if (te is TraceEntry entry && traceN > 0) { trace.Enqueue(entry); if (trace.Count > traceN) trace.Dequeue(); }
            if ((sim.Cpu.Instructions & 1023) == 0) sim.SyncSensors();
            if (te == null || sim.State == RunState.Faulted) { stop = "FAULT: " + sim.FaultMessage; break; }
            if (!windowTaken && sim.Cpu.Cycles >= windowStart)
            {
                windowTaken = true; windowCycles = sim.Cpu.Cycles;
                Array.Copy(sim.Bus.InjectorEvents, injAtWindow, 4); ignAtWindow = sim.Bus.IgnitionEvents;
            }
            if (sw.Elapsed.TotalSeconds > 120) { stop = "stopped after 2 minutes of real time"; break; }
        }
        var b = sim.Bus; var c = sim.Cpu;
        double simS = (double)c.Cycles / Bus.CpuHz;
        double win = windowTaken ? (double)(c.Cycles - windowCycles) / Bus.CpuHz : 0;
        var sb = new StringBuilder();
        sb.AppendLine($"{stop}: {simS:F3} s simulated, {c.Instructions:N0} instructions ({sim.FastForwardedInstructions:N0} of them fast-forwarded boot delay), {sw.Elapsed.TotalSeconds:F1} s real time");
        var src = p.SourceAt(c.Pc);
        sb.AppendLine($"PC {c.Pc:X4}h {p.Name(c.Pc)}{(src != null ? $"  ({_ws.Show(src.Value.File)}:{src.Value.Line}: {src.Value.Text.Trim()})" : "")}");
        sb.AppendLine($"A {c.A:X4}  DD {(c.Dd ? 1 : 0)}  CY {(c.Cf ? 1 : 0)}  Z {(c.Zf ? 1 : 0)}  MIE {(c.Mie() ? 1 : 0)}  LRB {c.Lrb:X4}  SSP {c.Ssp:X4}  IE {b.Ram[0x1A] | (b.Ram[0x1B] << 8):X4}");
        sb.AppendLine();
        sb.AppendLine($"inputs: {e.Rpm:0} rpm, MAP {e.MapKpa:0.#} kPa, TPS {e.TpsPct:0.#}%, ECT {e.EctCelsius:0} C, IAT {e.IatCelsius:0} C, O2 {e.O2Volts:0.00} V, {e.VbattVolts:0.0} V, {e.SpeedKmh:0} km/h");
        sb.AppendLine($"fuel pump: {(b.FuelPumpActive ? "ON" : "off")}    VTEC solenoid: {(b.VtecSolenoidActive ? "ON" : "off")}");
        for (int n = 0; n < 4; n++)
        {
            double rate = win > 0 ? (b.InjectorEvents[n] - injAtWindow[n]) / win : 0;
            sb.AppendLine($"injector {n + 1}: {(b.InjectorEvents[n] == 0 ? "never fired" : $"last pulse {b.InjectorPulseUs[n] / 1000.0:F2} ms, {rate:F1} pulses/s over the last {win:F1} s, {b.InjectorEvents[n]} total")}");
        }
        sb.AppendLine($"ignition (timer-3 events): {(win > 0 ? (b.IgnitionEvents - ignAtWindow) / win : 0):F1}/s, {b.IgnitionEvents} total");
        sb.AppendLine($"  (sequential injection at {e.Rpm:0} rpm is about {e.Rpm / 120:F1} pulses/s per injector)");
        if (sim.TrapLog.Count > 0)
        {
            sb.AppendLine("BRK traps (the ROM's fault handler): " + string.Join(", ", sim.TrapLog.OrderByDescending(kv => kv.Value).Take(10)
                .Select(kv => $"{p.Name(kv.Key.Pc)} reason {kv.Key.Reason:X2}h x{kv.Value}")));
        }
        sb.AppendLine($"coverage: {sim.Coverage.AddressesExecuted:N0} ROM addresses executed");
        if (!b.FuelPumpActive && b.InjectorEvents.All(x => x == 0) && sim.Coverage.AddressesExecuted < 2000)
            sb.AppendLine("  note: the program has not reached its main loop yet (still booting?) - run for more seconds");
        var hot = sim.GetHottestRecentPc();
        if (hot.WindowFilled > 0) sb.AppendLine($"hottest recent code: {p.Name(hot.Address)} ({100.0 * hot.Count / hot.WindowFilled:F0}% of the last {hot.WindowFilled} instructions)");
        if (a["watch"] is JsonArray watch && watch.Count > 0)
        {
            sb.AppendLine("watch:");
            foreach (var w in watch)
            {
                var name = w?.ToString() ?? "";
                if (!p.TryResolve(name, out var addr) || addr >= Bus.RamSize) { sb.AppendLine($"  {name}: not a RAM address"); continue; }
                int by = b.Ram[addr], wd = b.Ram[addr] | (b.Ram[(addr + 1) & 0xFFF] << 8);
                sb.AppendLine($"  {name} ({addr:X3}h): byte {by:X2}h ({by})  word {wd:X4}h ({wd})");
            }
        }
        if (traceN > 0)
        {
            var tsb = new StringBuilder();
            foreach (var t in trace) tsb.AppendLine($"{t.Pc:X4}  {p.Name(t.Pc),-30} {t.Text}");
            sb.AppendLine();
            sb.AppendLine($"last {trace.Count} instructions:");
            sb.Append(Spill(tsb.ToString(), S(a, "trace_file"), "trace.txt", "trace"));
        }
        return sb.ToString();
    }

    string CompareBins(JsonObject a)
    {
        var pa = Load(a, "a"); var pb = Load(a, "b");
        int max = Math.Clamp(I(a, "max", 100), 1, 5000);
        var ranges = new List<(int Start, int End)>();
        int? s = null;
        for (int i = 0; i <= Bus.RomSize; i++)
        {
            bool diff = i < Bus.RomSize && pa.Image[i] != pb.Image[i];
            if (diff && s == null) s = i;
            if (!diff && s != null) { ranges.Add((s.Value, i)); s = null; }
        }
        if (ranges.Count == 0) return "identical";
        var sb = new StringBuilder($"{ranges.Count} differing range(s), {ranges.Sum(r => r.End - r.Start)} bytes:\n");
        foreach (var (st, en) in ranges.Take(max))
        {
            string Hex(byte[] img) => string.Concat(Enumerable.Range(st, Math.Min(en - st, 16)).Select(i => img[i].ToString("X2"))) + (en - st > 16 ? ".." : "");
            sb.AppendLine($"  {st:X4}-{en - 1:X4} ({en - st} bytes) {pa.Name(st),-30} a: {Hex(pa.Image)}  b: {Hex(pb.Image)}");
        }
        if (ranges.Count > max) sb.AppendLine($"  ... {ranges.Count - max} more");
        return sb.ToString();
    }
}
