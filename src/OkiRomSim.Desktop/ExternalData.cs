using System.Globalization;
using System.Text.Json;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// A reading that does not come from the ECU: a web endpoint or a JSON file that something else keeps up to date (a weather station, a dyno, another logger, your own script).
public sealed class ExternalFeedSettings
{
    /// Prefix for the channels it produces ("dyno" -> "dyno.torque").
    public string Name { get; set; } = "external";
    /// http(s):// URL, or a path to a JSON file on this machine.
    public string Source { get; set; } = "";
    public int IntervalMs { get; set; } = 1000;
    /// Read this property of the document instead of the whole thing ("data", "result.values").
    public string Path { get; set; } = "";
    public bool Enabled { get; set; } = true;
}

/// Polls the feeds in the background and keeps the last numbers each one produced, so gauges (and anything else that wants them) can read them without waiting on the network.
/// Whatever the source returns is flattened to `name.key` numbers: nested objects join with dots, arrays use their index, true/false become 1/0, and a string that parses as a number counts. Anything else is ignored. A feed that fails is logged once and retried on its own timer, so a dead endpoint cannot stall the UI.
public sealed class ExternalData : IDisposable
{
    readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(5) };
    readonly Dictionary<string, double> _values = new(StringComparer.OrdinalIgnoreCase);
    readonly object _lock = new();
    CancellationTokenSource? _stop;
    List<ExternalFeedSettings> _feeds = new();

    /// Channel -> value, as of the last poll.
    public IReadOnlyDictionary<string, double> Values
    {
        get { lock (_lock) return new Dictionary<string, double>(_values, StringComparer.OrdinalIgnoreCase); }
    }

    public string Status { get; private set; } = "no external feeds";

    public void Start(IEnumerable<ExternalFeedSettings> feeds)
    {
        Stop();
        _feeds = feeds.Where(f => f.Enabled && f.Source.Trim().Length > 0).ToList();
        if (_feeds.Count == 0) { Status = "no external feeds"; return; }
        _stop = new CancellationTokenSource();
        var token = _stop.Token;
        foreach (var feed in _feeds) _ = Task.Run(() => Poll(feed, token), token);
        Status = $"{_feeds.Count} external feed(s)";
        AppLog.Info("external", Status + ": " + string.Join(", ", _feeds.Select(f => $"{f.Name} <- {f.Source}")));
    }

    public void Stop()
    {
        _stop?.Cancel();
        _stop = null;
        lock (_lock) _values.Clear();
    }

    async Task Poll(ExternalFeedSettings feed, CancellationToken token)
    {
        string? lastError = null;
        while (!token.IsCancellationRequested)
        {
            try
            {
                string text = feed.Source.StartsWith("http", StringComparison.OrdinalIgnoreCase)
                    ? await _http.GetStringAsync(feed.Source, token)
                    : await File.ReadAllTextAsync(feed.Source, token);
                var node = JsonDocument.Parse(text).RootElement;
                foreach (var step in feed.Path.Split('.', StringSplitOptions.RemoveEmptyEntries))
                    if (node.ValueKind == JsonValueKind.Object && node.TryGetProperty(step, out var child)) node = child;
                var found = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
                Flatten(feed.Name, node, found, 0);
                lock (_lock)
                    foreach (var (k, v) in found) _values[k] = v;
                if (lastError != null) { AppLog.Info("external", $"{feed.Name} is answering again ({found.Count} values)"); lastError = null; }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                if (ex.Message != lastError)          // one line per fault, not one per poll
                {
                    lastError = ex.Message;
                    AppLog.Error("external", $"{feed.Name} ({feed.Source})", ex);
                }
            }
            try { await Task.Delay(Math.Clamp(feed.IntervalMs, 100, 600_000), token); }
            catch (OperationCanceledException) { return; }
        }
    }

    /// Numbers out of any JSON shape, named after the path that led to them.
    static void Flatten(string prefix, JsonElement e, Dictionary<string, double> into, int depth)
    {
        if (depth > 6 || into.Count > 500) return;
        switch (e.ValueKind)
        {
            case JsonValueKind.Number:
                if (e.TryGetDouble(out var d)) into[prefix] = d;
                break;
            case JsonValueKind.True: into[prefix] = 1; break;
            case JsonValueKind.False: into[prefix] = 0; break;
            case JsonValueKind.String:
                if (double.TryParse(e.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var s)) into[prefix] = s;
                break;
            case JsonValueKind.Object:
                foreach (var p in e.EnumerateObject()) Flatten($"{prefix}.{p.Name}", p.Value, into, depth + 1);
                break;
            case JsonValueKind.Array:
                int i = 0;
                foreach (var v in e.EnumerateArray()) Flatten($"{prefix}.{i++}", v, into, depth + 1);
                break;
        }
    }

    public void Dispose() { Stop(); _http.Dispose(); }
}
