// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Core;

/// Writing a file the user would be sorry to lose (their source, a ROM image, definitions, a log): the new contents go to a file beside it first and take its place only when complete, so a crash, a full disk or an error while it is made leaves what was there exactly as it was. (File.WriteAllText empties the file before it writes a byte.) A file that does not exist yet, or one that is a link (replacing it would replace the link, not the file it points to), is written as it is.
public static class SafeFile
{
    public static void WriteAllText(string path, string text) => Write(path, p => File.WriteAllText(p, text));

    public static void WriteAllBytes(string path, byte[] data) => Write(path, p => File.WriteAllBytes(p, data));

    public static void WriteAllLines(string path, IEnumerable<string> lines) => Write(path, p => File.WriteAllLines(p, lines));

    static void Write(string path, Action<string> make)
    {
        bool replace;
        try { replace = File.Exists(path) && new FileInfo(path).LinkTarget == null; }
        catch { replace = false; }
        if (!replace) { make(path); return; }
        var temp = path + ".saving";
        try
        {
            make(temp);
            File.Move(temp, path, overwrite: true);
        }
        catch
        {
            try { File.Delete(temp); } catch { }
            throw;
        }
    }
}
