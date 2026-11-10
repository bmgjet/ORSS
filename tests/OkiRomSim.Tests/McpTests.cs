// Copyright (c) bmgjet. All rights reserved.
using System.Text.Json.Nodes;
using OkiRomSim.Calibration;
using OkiRomSim.Mcp;

namespace OkiRomSim.Tests;

/// The MCP server (the same one romsim-mcp and Rom Sim Studio's MCP page run), driven through its JSON-RPC entry point on copies in a
/// scratch folder: a read-only server refuses every call that would change something, cal_save keeps an existing .bin as .bak once
/// and never overwrites the file it was opened from by surprise, paths cannot leave the workspace, and malformed requests are answered.
static class McpTests
{
    static (string Text, bool Error) Tool(McpServer s, string tool, JsonObject args)
    {
        var req = new JsonObject
        {
            ["jsonrpc"] = "2.0", ["id"] = 1, ["method"] = "tools/call",
            ["params"] = new JsonObject { ["name"] = tool, ["arguments"] = args },
        };
        var resp = JsonNode.Parse(s.Handle(req.ToJsonString())!)!.AsObject();
        var result = resp["result"]?.AsObject();
        if (result == null) return (resp["error"]?["message"]?.GetValue<string>() ?? "(no answer)", true);
        return (result["content"]![0]!["text"]!.GetValue<string>(), result["isError"]!.GetValue<bool>());
    }

    /// The P30 build file, its skeleton and the function modules, copied into a scratch folder (what the server works on).
    static string CopyBuild(T.Scratch s)
    {
        s.Copy(T.Roms("p30-build.asm"));
        s.Copy(T.Roms("p30-skeleton.asm"));
        var features = Path.Combine(s.Dir, "p30-features");
        Directory.CreateDirectory(features);
        foreach (var f in Directory.GetFiles(T.Roms("p30-features"))) File.Copy(f, Path.Combine(features, Path.GetFileName(f)));
        return s.File("p30-build.asm");
    }

    public static void Run()
    {
        // a setting of the bare P30 build to change: the first one-byte setting (not a table, not a switch) the definitions list
        using var s = T.NewScratch("mcp");
        var build = CopyBuild(s);
        var asm = T.Assemble(build);
        if (!T.Check("the P30 build assembles", asm.Success)) return;
        var item = DefinitionBuilder.FromAssembly(asm, "p30-build.asm").Items
            .FirstOrDefault(i => !i.IsTable && !i.Flag && i.Type == CellType.U8 && i.Address is > 0 and < 0x7FF0);
        if (!T.Check("the build has a one-byte setting to change", item != null)) return;
        int raw = asm.Image[item!.Address], want = raw < 0xFE ? raw + 1 : raw - 1;

        ReadOnly(build, s, item.Name);
        Saving(s, item, raw, want);
        Paths(s);
        JsonRpc();
    }

    static void ReadOnly(string build, T.Scratch s, string name)
    {
        var ro = new McpServer(new Workspace([s.Dir]) { ReadOnly = true });
        var files = Directory.GetFiles(s.Dir, "*", SearchOption.AllDirectories).Length;
        var refused = new List<string>();
        foreach (var (tool, args) in new (string, JsonObject)[]
        {
            ("cal_write", new JsonObject { ["path"] = "p30-build.asm", ["name"] = name, ["value"] = 1, ["raw"] = true, ["index"] = 0 }),
            ("cal_save", new JsonObject { ["path"] = "p30-build.asm" }),
            ("cal_detect", new JsonObject { ["path"] = "p30-build.asm" }),
            ("file_write", new JsonObject { ["path"] = "new.asm", ["content"] = "; x" }),
            ("emulator", new JsonObject { ["action"] = "connect", ["port"] = "/dev/null" }),
            ("datalog", new JsonObject { ["action"] = "start", ["port"] = "simulator" }),
            ("simulator", new JsonObject { ["action"] = "run" }),
        })
        {
            var (text, err) = Tool(ro, tool, args);
            if (!err || !text.Contains("read-only")) refused.Add($"{tool}: {text[..Math.Min(80, text.Length)]}");
        }
        T.Check("a read-only server refuses every call that changes something (calibration, files, emulator, datalog, simulator)", refused.Count == 0, string.Join("; ", refused));
        var (list, listErr) = Tool(ro, "cal_list", new JsonObject { ["path"] = "p30-build.asm" });
        T.Check("... and still answers the ones that only look", !listErr && list.Contains(name), listErr ? list : "");
        var (status, _) = Tool(ro, "emulator", new JsonObject { ["action"] = "status" });
        T.Check("... (emulator status is not refused as a change)", !status.Contains("read-only"), status);
        T.Check("... and no file in the workspace was written", Directory.GetFiles(s.Dir, "*", SearchOption.AllDirectories).Length == files);
    }

    static void Saving(T.Scratch s, ItemDef item, int raw, int want)
    {
        var rw = new McpServer(new Workspace([s.Dir]));
        var bin = s.File("p30-build.bin");
        var (w, werr) = Tool(rw, "cal_write", new JsonObject { ["path"] = "p30-build.asm", ["name"] = item.Name, ["value"] = want, ["raw"] = true, ["index"] = 0 });
        T.Check($"cal_write on a .asm keeps the change in memory ({item.Name} {raw} -> {want})", !werr && w.Contains("kept in memory") && !File.Exists(bin), w.Split('\n')[0]);
        var (sv, serr) = Tool(rw, "cal_save", new JsonObject { ["path"] = "p30-build.asm" });
        var first = File.Exists(bin) ? File.ReadAllBytes(bin) : [];
        T.Check("cal_save writes p30-build.bin beside it, with the change and the checksum byte balanced (sum 0)",
            !serr && first.Length == 0x8000 && first[item.Address] == want && T.Sum8(first) == 0 && !File.Exists(bin + ".bak"),
            serr ? sv : $"{first.Length} bytes, {item.Name} = {(first.Length > item.Address ? first[item.Address] : -1)}, sum {T.Sum8(first):X2}h");
        Tool(rw, "cal_write", new JsonObject { ["path"] = "p30-build.asm", ["name"] = item.Name, ["value"] = raw, ["raw"] = true, ["index"] = 0 });
        Tool(rw, "cal_save", new JsonObject { ["path"] = "p30-build.asm" });
        T.Check("saved again over that .bin: the one that was there is kept as .bak", File.Exists(bin + ".bak") && File.ReadAllBytes(bin + ".bak").AsSpan().SequenceEqual(first));
        Tool(rw, "cal_write", new JsonObject { ["path"] = "p30-build.asm", ["name"] = item.Name, ["value"] = want, ["raw"] = true, ["index"] = 0 });
        Tool(rw, "cal_save", new JsonObject { ["path"] = "p30-build.asm" });
        T.Check("... once: a third save leaves that .bak as it is (it is the file before the first change)", File.ReadAllBytes(bin + ".bak").AsSpan().SequenceEqual(first));

        // a .bin worked on directly: every change written back to it, the original kept as .bak once - also across server runs
        var car = s.File("car.bin");
        File.Copy(bin, car);
        var original = File.ReadAllBytes(car);
        var (d, derr) = Tool(rw, "cal_save", new JsonObject { ["path"] = "p30-build.asm", ["format"] = "defs", ["output"] = "car" });
        if (!T.Check("cal_save format=defs writes the definitions beside it", !derr && File.Exists(s.File("car.okidef.json")), d)) return;
        Tool(rw, "cal_write", new JsonObject { ["path"] = "car.bin", ["name"] = item.Name, ["value"] = raw, ["raw"] = true, ["index"] = 0 });
        T.Check("cal_write on a .bin writes it back, the original kept as car.bin.bak", File.ReadAllBytes(car)[item.Address] == raw &&
            File.Exists(car + ".bak") && File.ReadAllBytes(car + ".bak").AsSpan().SequenceEqual(original));
        var again = new McpServer(new Workspace([s.Dir]));
        Tool(again, "cal_write", new JsonObject { ["path"] = "car.bin", ["name"] = item.Name, ["value"] = want, ["raw"] = true, ["index"] = 0 });
        T.Check("a second server run writing the same .bin leaves the .bak as the original (it used to copy the changed file over it)",
            File.ReadAllBytes(car)[item.Address] == want && File.ReadAllBytes(car + ".bak").AsSpan().SequenceEqual(original));

        // an upload over a file that is there
        var target = s.File("upload.bin");
        File.WriteAllBytes(target, [1, 2, 3]);
        var (u, uerr) = Tool(rw, "file_upload", new JsonObject { ["path"] = "upload.bin", ["data"] = Convert.ToBase64String([9, 9]), ["offset"] = 0 });
        T.Check("file_upload starting (offset 0) over an existing file is refused without overwrite=true (its first chunk used to empty the file)",
            uerr && File.ReadAllBytes(target).AsSpan().SequenceEqual(new byte[] { 1, 2, 3 }), u);
        (u, uerr) = Tool(rw, "file_upload", new JsonObject { ["path"] = "upload.bin", ["data"] = Convert.ToBase64String([9, 9]), ["offset"] = 0, ["overwrite"] = true });
        T.Check("... and with overwrite=true it replaces it, the old one kept as .bak", !uerr && File.ReadAllBytes(target).AsSpan().SequenceEqual(new byte[] { 9, 9 })
            && File.ReadAllBytes(target + ".bak").AsSpan().SequenceEqual(new byte[] { 1, 2, 3 }), u);
        var sha = T.Sha256(new byte[] { 1, 2, 3 });
        var (c1, _) = Tool(rw, "file_upload", new JsonObject { ["path"] = "chunks.bin", ["data"] = Convert.ToBase64String([1, 2]), ["offset"] = 0, ["sha256"] = sha });
        var (c2, c2err) = Tool(rw, "file_upload", new JsonObject { ["path"] = "chunks.bin", ["data"] = Convert.ToBase64String([3]), ["offset"] = 2, ["sha256"] = sha });
        T.Check("a file sent in two chunks arrives whole; the SHA-256 given is 'not yet' after the first and matches after the last",
            c1.Contains("not yet") && !c2err && !c2.Contains("not yet") && File.ReadAllBytes(s.File("chunks.bin")).AsSpan().SequenceEqual(new byte[] { 1, 2, 3 }), c2);
    }

    static void Paths(T.Scratch s)
    {
        var ws = new Workspace([s.Dir]);
        T.Throws<ToolException>("a path that climbs out of the workspace (../) is refused", () => ws.Resolve("../outside.txt", mustExist: false));
        T.Throws<ToolException>("an absolute path outside the workspace is refused", () => ws.Resolve(Path.Combine(Path.GetTempPath(), "elsewhere.txt"), mustExist: false));
        using var outside = T.NewScratch("mcp-outside");
        File.WriteAllText(outside.File("secret.txt"), "x");
        var link = Path.Combine(s.Dir, "link");
        bool made = false;
        try { Directory.CreateSymbolicLink(link, outside.Dir); made = true; } catch { }
        if (made) T.Throws<ToolException>("a link inside the workspace to a folder outside it is refused", () => ws.Resolve(Path.Combine("link", "secret.txt")), ex => ex.Message.Contains("links outside"));
        else T.Skip("a link inside the workspace to a folder outside it is refused", "no symbolic link could be made here");
        var srv = new McpServer(ws);
        var (text, err) = Tool(srv, "file_list", new JsonObject { ["path"] = ".", ["pattern"] = "../*" });
        T.Check("file_list with a pattern that names a folder (../*) is refused (it listed files outside)", err && !text.Contains("secret"), text);
        if (made) try { Directory.Delete(link); } catch { }
    }

    static void JsonRpc()
    {
        using var s = T.NewScratch("mcp-rpc");
        var srv = new McpServer(new Workspace([s.Dir]));
        static JsonNode? P(string? json) => json == null ? null : JsonNode.Parse(json);
        var empty = P(srv.Handle("[]"));
        T.Check("an empty batch is answered with one 'invalid request'", empty?["error"]?["code"]?.GetValue<int>() == -32600, empty?.ToJsonString() ?? "no answer");
        var batch = P(srv.Handle("[1, {\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\"}]")) as JsonArray;
        T.Check("a batch with a member that is not an object: that member gets an error, the other its answer",
            batch is { Count: 2 } && batch[0]?["error"]?["code"]?.GetValue<int>() == -32600 && batch[1]?["id"]?.GetValue<int>() == 5 && batch[1]?["result"] != null,
            batch?.ToJsonString() ?? "no answer");
        string? dup = null; Exception? thrown = null;
        try { dup = srv.Handle("{\"jsonrpc\":\"2.0\",\"id\":7,\"id\":8,\"method\":\"ping\"}"); } catch (Exception ex) { thrown = ex; }
        T.Check("a request with a key twice is answered with an error (it left a stdio client with no answer)",
            thrown == null && P(dup)?["error"]?["code"]?.GetValue<int>() is -32600 or -32700, thrown?.Message ?? dup ?? "no answer");
        var notString = P(srv.Handle("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":5}"));
        T.Check("a method that is not a string is an invalid request", notString?["error"]?["code"]?.GetValue<int>() == -32600, notString?.ToJsonString() ?? "no answer");
        var unknown = P(srv.Handle("{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"nope\"}"));
        T.Check("an unknown method is 'method not found'", unknown?["error"]?["code"]?.GetValue<int>() == -32601, unknown?.ToJsonString() ?? "no answer");
    }
}
