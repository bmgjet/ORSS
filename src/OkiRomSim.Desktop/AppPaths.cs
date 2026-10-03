// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Desktop;

/// Where the app keeps what is yours in Documents: Documents\Rom Sim Studio\Dyno (profiles and runs) and the rest. A folder from before the name changed is moved over the first time it is asked for, so nothing made with the older version goes missing.
public static class AppPaths
{
    public static string Documents => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Rom Sim Studio");

    /// The virtual dyno's profiles and runs.
    public static string Dyno => Moved(Path.Combine(Documents, "Dyno"), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "OkiRomSim Dyno"));

    /// ROMs read out of the emulator and new ROMs built from the skeleton.
    public static string Roms => Moved(Path.Combine(Documents, "ROMs"), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "OkiRomSim ROMs"));

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
