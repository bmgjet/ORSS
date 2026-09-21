using System.Collections.Concurrent;

namespace OkiRomSim.Core;

/// Kind of event, for the Debug page's filters.
public enum LogKind { Action, Info, Warning, Error, Mcp, Serial, Sim }

public sealed record LogEntry(long Serial, DateTime Time, LogKind Kind, string Source, string Message, string? Detail = null);

/// Everything that happens, for the Debug page: user actions, errors (with the exception), MCP tool calls and where they came from, serial traffic and simulator events. Thread-safe and bounded: the newest entries are kept, the oldest dropped.
public static class AppLog
{
    const int Capacity = 5000;
    static readonly ConcurrentQueue<LogEntry> Entries = new();
    static long _serial;

    /// Raised on the thread that logged (the UI marshals it itself).
    public static event Action<LogEntry>? Added;

    public static long Latest => Interlocked.Read(ref _serial);

    public static void Write(LogKind kind, string source, string message, string? detail = null)
    {
        try
        {
            var e = new LogEntry(Interlocked.Increment(ref _serial), DateTime.Now, kind, source, message, detail);
            Entries.Enqueue(e);
            while (Entries.Count > Capacity && Entries.TryDequeue(out _)) { }
            Added?.Invoke(e);
        }
        catch { /* logging must never be the thing that fails */ }
    }

    public static void Action(string source, string message) => Write(LogKind.Action, source, message);
    public static void Info(string source, string message) => Write(LogKind.Info, source, message);
    public static void Warn(string source, string message) => Write(LogKind.Warning, source, message);
    public static void Error(string source, string message, Exception? ex = null) =>
        Write(LogKind.Error, source, ex == null ? message : $"{message}: {ex.GetType().Name}: {ex.Message}", ex?.ToString());

    /// Entries newer than `after` (by serial), oldest first.
    public static List<LogEntry> Since(long after) => Entries.Where(e => e.Serial > after).ToList();
    public static List<LogEntry> All() => Entries.ToList();
    public static void Clear() { while (Entries.TryDequeue(out _)) { } }
}
