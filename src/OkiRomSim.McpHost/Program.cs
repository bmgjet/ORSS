// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Mcp;

// okirom-mcp: MCP server for OKI MSM66207 ROM development.
//
// okirom-mcp [--root DIR]... stdio (for local agent launchers) okirom-mcp --http [--port 8765] [--remote] [--password PW] [--cert file.pfx --cert-password PW] [--root DIR]... okirom-mcp --read-only ... refuse every write
//
// The password can also come from the OKIROMSIM_MCP_PASSWORD environment variable (keeps it out of process listings). --remote listens on all interfaces and requires a password.
var roots = new List<string>();
bool http = false, remote = false, readOnly = false;
int port = 8765;
string password = Environment.GetEnvironmentVariable("OKIROMSIM_MCP_PASSWORD") ?? "";
string? cert = null, certPw = null;
for (int i = 0; i < args.Length; i++)
{
    string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{args[i]} needs a value");
    switch (args[i])
    {
        case "--root": roots.Add(Next()); break;
        case "--http": http = true; break;
        case "--port": port = int.Parse(Next()); break;
        case "--remote": remote = true; break;
        case "--password": password = Next(); break;
        case "--cert": cert = Next(); break;
        case "--cert-password": certPw = Next(); break;
        case "--read-only": readOnly = true; break;
        case "-h" or "--help":
            Console.Error.WriteLine("okirom-mcp [--root DIR]... [--read-only] [--http [--port N] [--remote] [--password PW] [--cert f.pfx --cert-password PW]]");
            return 0;
        default: Console.Error.WriteLine($"unknown argument {args[i]}"); return 2;
    }
}
if (roots.Count == 0) roots.Add(Directory.GetCurrentDirectory());
var server = new McpServer(new Workspace(roots) { ReadOnly = readOnly })
{
    Log = c => Console.Error.WriteLine($"{DateTime.Now:HH:mm:ss} {c.Client} {(c.Ok ? "ok " : "ERR")} {c.Tool} {c.Milliseconds} ms {(c.Arguments.Length > 200 ? c.Arguments[..200] + "..." : c.Arguments)}"),
};
if (!http)
{
    // stdout carries the protocol and nothing else: anything else that writes to the console goes to stderr instead, so a stray message cannot corrupt a reply.
    var protocolOut = new StreamWriter(Console.OpenStandardOutput(), new System.Text.UTF8Encoding(false)) { AutoFlush = false };
    Console.SetOut(Console.Error);
    await McpStdio.RunAsync(server, new StreamReader(Console.OpenStandardInput(), System.Text.Encoding.UTF8), protocolOut);
    return 0;
}
if (remote && password.Length < 8) { Console.Error.WriteLine("--remote needs --password (8+ characters) or OKIROMSIM_MCP_PASSWORD"); return 2; }
await using var host = new McpHttp(server, new McpHttpOptions { Port = port, AllowRemote = remote, Password = password, CertificatePath = cert, CertificatePassword = certPw });
host.Log += m => Console.Error.WriteLine(m);
await host.StartAsync();
Console.Error.WriteLine($"workspace: {string.Join(", ", server.Workspace.Roots)}; Ctrl+C to stop");
var done = new TaskCompletionSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; done.TrySetResult(); };
await done.Task;
return 0;
