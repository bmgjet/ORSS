// Copyright (c) bmgjet. All rights reserved.
using System.Collections.Concurrent;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace OkiRomSim.Mcp;

/// MCP over stdio: one JSON-RPC message per line in, one per line out. What local client launchers use.
public static class McpStdio
{
    public static async Task RunAsync(McpServer server, TextReader input, TextWriter output, CancellationToken ct = default)
    {
        while (!ct.IsCancellationRequested)
        {
            var line = await input.ReadLineAsync(ct);
            if (line == null) break;
            if (line.Trim().Length == 0) continue;
            string? reply;
            try { reply = server.Handle(line, "stdio"); }
            catch (Exception ex) { reply = null; OkiRomSim.Core.AppLog.Error("mcp stdio", "request failed", ex); }
            if (reply == null) continue;
            await output.WriteLineAsync(reply);
            await output.FlushAsync(ct);
        }
    }
}

/// Settings for the HTTP transport.
public sealed class McpHttpOptions
{
    public int Port { get; set; } = 8765;
    /// Listen on every interface (remote clients) instead of only this machine.
    public bool AllowRemote { get; set; }
    /// Required whenever AllowRemote is on; optional (but honoured) for local use.
    public string Password { get; set; } = "";
    /// Optional TLS certificate (.pfx) for https; strongly recommended for remote use.
    public string? CertificatePath { get; set; }
    public string? CertificatePassword { get; set; }
}

/// MCP "Streamable HTTP" transport: clients POST JSON-RPC to /mcp and get the response as application/json. Every request needs `Authorization: Bearer <password>` (or an `X-Api-Key: <password>` header) when a password is set; wrong passwords are slowed down and an address that keeps failing is locked out for a while.
public sealed class McpHttp : IAsyncDisposable
{
    readonly McpServer _server;
    readonly McpHttpOptions _options;
    WebApplication? _app;
    readonly ConcurrentDictionary<string, (int Failures, DateTime Until)> _failures = new();
    public string Url { get; private set; } = "";
    public event Action<string>? Log;

    public McpHttp(McpServer server, McpHttpOptions options)
    {
        _server = server; _options = options;
        if (options.AllowRemote && options.Password.Length < 8)
            throw new ArgumentException("remote access needs a password of at least 8 characters");
    }

    public async Task StartAsync()
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(k =>
        {
            var ip = _options.AllowRemote ? IPAddress.Any : IPAddress.Loopback;
            k.Listen(ip, _options.Port, l =>
            {
                if (!string.IsNullOrEmpty(_options.CertificatePath)) l.UseHttps(_options.CertificatePath, _options.CertificatePassword);
            });
            k.Limits.MaxRequestBodySize = 16 * 1024 * 1024;
        });
        _app = builder.Build();
        _app.MapPost("/mcp", HandleAsync);
        _app.MapGet("/mcp", (HttpContext c) => Results.StatusCode(405));
        _app.MapGet("/", () => Results.Text("romsim-mcp: POST JSON-RPC to /mcp (Authorization: Bearer <password>)\n"));
        await _app.StartAsync();
        string scheme = string.IsNullOrEmpty(_options.CertificatePath) ? "http" : "https";
        Url = $"{scheme}://{(_options.AllowRemote ? Environment.MachineName : "127.0.0.1")}:{_options.Port}/mcp";
        Log?.Invoke($"listening on {Url}{(_options.Password.Length > 0 ? " (password required)" : "")}");
    }

    async Task HandleAsync(HttpContext ctx)
    {
        try { await HandleCoreAsync(ctx); }
        catch (Exception ex)
        {
            OkiRomSim.Core.AppLog.Error("mcp http", "request failed", ex);
            try { if (!ctx.Response.HasStarted) { ctx.Response.StatusCode = 500; await ctx.Response.WriteAsync("internal error"); } } catch { }
        }
    }

    async Task HandleCoreAsync(HttpContext ctx)
    {
        string who = ctx.Connection.RemoteIpAddress?.ToString() ?? "?";
        // a web page in the user's browser can send a request to this address too (a plain-text POST needs no permission): one that names an origin other than this machine, or a host name that is not this machine's (DNS rebinding), is refused
        if (!FromThisMachine(ctx.Request))
        {
            OkiRomSim.Core.AppLog.Warn("mcp " + who, $"refused: origin '{ctx.Request.Headers.Origin}' / host '{ctx.Request.Host}' is not this machine");
            ctx.Response.StatusCode = 403;
            await ctx.Response.WriteAsync("forbidden: not from this machine's own pages");
            return;
        }
        if (_failures.TryGetValue(who, out var f) && f.Until > DateTime.UtcNow)
        {
            ctx.Response.StatusCode = 429;
            await ctx.Response.WriteAsync("too many failed logins; try later");
            return;
        }
        if (_options.Password.Length > 0 && !Authorized(ctx.Request))
        {
            var n = _failures.AddOrUpdate(who, (1, DateTime.MinValue), (_, v) => v.Until != DateTime.MinValue && v.Until <= DateTime.UtcNow
                ? (1, DateTime.MinValue)                                   // a lock-out that has run its time: counting starts again
                : (v.Failures + 1, v.Failures + 1 >= 5 ? DateTime.UtcNow.AddMinutes(5) : v.Until));
            Log?.Invoke($"rejected {who}: bad or missing password ({n.Failures})");
            OkiRomSim.Core.AppLog.Warn("mcp " + who, $"rejected: bad or missing password (attempt {n.Failures}{(n.Failures >= 5 ? ", locked out for 5 minutes" : "")})");
            await Task.Delay(750);
            ctx.Response.StatusCode = 401;
            ctx.Response.Headers.WWWAuthenticate = "Bearer";
            await ctx.Response.WriteAsync("unauthorized");
            return;
        }
        _failures.TryRemove(who, out _);
        using var reader = new StreamReader(ctx.Request.Body, Encoding.UTF8);
        var body = await reader.ReadToEndAsync();
        string? reply = await Task.Run(() => _server.Handle(body, who));
        if (body.Contains("\"initialize\"") && !ctx.Request.Headers.ContainsKey("Mcp-Session-Id"))
            ctx.Response.Headers["Mcp-Session-Id"] = Guid.NewGuid().ToString("N");
        if (reply == null) { ctx.Response.StatusCode = 202; return; }
        ctx.Response.ContentType = "application/json";
        await ctx.Response.WriteAsync(reply);
    }

    /// True unless the request says it comes from a page on another site (Origin) or names a host that is not this machine's: a program on this computer sends neither, a browser tab always sends a Host, and an Origin when it comes from a page.
    bool FromThisMachine(HttpRequest r)
    {
        static bool Local(string host) => host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || host.Equals("::1", StringComparison.Ordinal)
            || host.Equals("[::1]", StringComparison.Ordinal) || host.EndsWith(".localhost", StringComparison.OrdinalIgnoreCase) || IPAddress.TryParse(host, out var ip) && IPAddress.IsLoopback(ip);
        bool Mine(string host) => Local(host) || (_options.AllowRemote && (host.Equals(Environment.MachineName, StringComparison.OrdinalIgnoreCase)
            || IPAddress.TryParse(host, out _) || host.Contains('.')));   // reached over the network on purpose: the password is what guards it
        if (!_options.AllowRemote && !Local(r.Host.Host)) return false;
        var origin = r.Headers.Origin.ToString();
        if (origin.Length == 0 || origin == "null") return origin.Length == 0;
        return Uri.TryCreate(origin, UriKind.Absolute, out var u) && Mine(u.Host);
    }

    bool Authorized(HttpRequest r)
    {
        string? given = null;
        var auth = r.Headers.Authorization.ToString();
        if (auth.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) given = auth[7..].Trim();
        given ??= r.Headers["X-Api-Key"].FirstOrDefault();
        if (given == null) return false;
        var a = SHA256.HashData(Encoding.UTF8.GetBytes(given));
        var b = SHA256.HashData(Encoding.UTF8.GetBytes(_options.Password));
        return CryptographicOperations.FixedTimeEquals(a, b);
    }

    public async ValueTask DisposeAsync()
    {
        if (_app != null) { await _app.StopAsync(); await _app.DisposeAsync(); _app = null; }
    }
}
