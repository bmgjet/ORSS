// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Desktop;

/// Where the app keeps what is yours in Documents: Documents\Rom Sim Studio\Dyno (profiles and runs) and the rest. A folder from before the
/// name changed is moved over the first time it is asked for, so nothing made with the older version goes missing.
public static class AppPaths
{
    public static string Documents => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Rom Sim Studio");

    /// The virtual dyno's profiles and runs.
    public static string Dyno => Moved(Path.Combine(Documents, "Dyno"), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "OkiRomSim Dyno"));

    /// ROMs read out of the emulator and new ROMs built from the skeleton.
    public static string Roms => Moved(Path.Combine(Documents, "ROMs"), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "OkiRomSim ROMs"));

    /// Where to write `content` as `path` without losing anything: `path` itself when there is no file there yet (or it already holds
    /// exactly these bytes), else the first free "name-2.bin", "name-3.bin"... beside it. A half of a 64 KB image saved earlier may have
    /// been tuned since: writing the half out again must never quietly replace it.
    public static string Unclobbered(string path, byte[] content)
    {
        try
        {
            if (!File.Exists(path) || File.ReadAllBytes(path).AsSpan().SequenceEqual(content)) return path;
        }
        catch { }
        string dir = Path.GetDirectoryName(path) ?? "", stem = Path.GetFileNameWithoutExtension(path), ext = Path.GetExtension(path);
        for (int n = 2; n < 10_000; n++)
        {
            var candidate = Path.Combine(dir, $"{stem}-{n}{ext}");
            try { if (!File.Exists(candidate) || File.ReadAllBytes(candidate).AsSpan().SequenceEqual(content)) return candidate; }
            catch { }
        }
        return Path.Combine(dir, $"{stem}-{DateTime.Now:yyyyMMdd-HHmmss}{ext}");
    }

    /// The Templates folder: beside the app, or (running from a source checkout) the one at the repository root.
    public static string? Templates()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            var t = Path.Combine(dir.FullName, "Templates");
            if (Directory.Exists(t)) return t;
        }
        return null;
    }

    /// `now`, after moving `old` there when only the old one exists.
    static string Moved(string now, string old)
    {
        try
        {
            if (!Directory.Exists(now) && Directory.Exists(old))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(now)!);
                Directory.Move(old, now);
                OkiRomSim.Core.AppLog.Info("app", $"moved {old} to {now}");
            }
        }
        catch (Exception ex) { OkiRomSim.Core.AppLog.Warn("app", $"could not move {old} to {now}: {ex.Message}"); return Directory.Exists(old) ? old : now; }
        return now;
    }
}
