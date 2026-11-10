// Copyright (c) bmgjet. All rights reserved.
using OkiRomSim.Mcp;

// romsim-mcp: MCP server for OKI MSM66207 ROM development.
//
// romsim-mcp [--root DIR]... stdio (for local client launchers) romsim-mcp --http [--port 8765] [--remote] [--password PW] [--cert file.pfx --cert-password PW] [--root DIR]... romsim-mcp --read-only ... refuse every write
//
// The password can also come from the OKIROMSIM_MCP_PASSWORD environment variable (keeps it out of process listings). --remote listens on all interfaces and requires a password.
var roots = new List<string>();
bool http = false, remote = false, readOnly = false;
int port = 8765;
string password = Environment.GetEnvironmentVariable("OKIROMSIM_MCP_PASSWORD") ?? "";
string? cert = null, certPw = null;
for (int i = 0; i < args.Length; i++)
{
    // a missing or bad value is a usage error (exit 2 with a message), not an unhandled exception
    string? Next() => i + 1 < args.Length ? args[++i] : null;
    string? value = args[i] is "--root" or "--port" or "--password" or "--cert" or "--cert-password" ? Next() : "";
    if (value == null) { Console.Error.WriteLine($"{args[i]} needs a value"); return 2; }
    switch (args[i])
    {
        case "--root": roots.Add(value); break;
        case "--http": http = true; break;
        case "--port":
            if (!int.TryParse(value, out port) || port is < 1 or > 65535) { Console.Error.WriteLine($"--port {value}: not a port number (1-65535)"); return 2; }
            break;
        case "--remote": remote = true; break;
        case "--password": password = value; break;
        case "--cert": cert = value; break;
        case "--cert-password": certPw = value; break;
        case "--read-only": readOnly = true; break;
        case "-h" or "--help":
            Console.Error.WriteLine("romsim-mcp [--root DIR]... [--read-only] [--http [--port N] [--remote] [--password PW] [--cert f.pfx --cert-password PW]]");
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
// a service manager's stop (systemd, launchd, docker, `kill`) is SIGTERM: stop cleanly then too - only Ctrl+C was heard before, and the
// server went on serving after it was told to stop
using var onTerm = System.Runtime.InteropServices.PosixSignalRegistration.Create(System.Runtime.InteropServices.PosixSignal.SIGTERM, c => { c.Cancel = true; done.TrySetResult(); });
await done.Task;
return 0;
