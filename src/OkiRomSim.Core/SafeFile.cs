// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Core;

/// Writing a file the user would be sorry to lose (their source, a ROM image, definitions, a log): the new contents go to a file beside it first and take its place only when complete, so a crash, a full disk or an error while it is made leaves what was there exactly as it was. (File.WriteAllText empties the file before it writes a byte.) A file that does not exist yet, or one that is a link (replacing it would replace the link, not the file it points to), is written as it is.
public static class SafeFile
{
    // The same bytes File.WriteAllText / WriteAllBytes / WriteAllLines write (UTF-8 without a byte order mark; a line ending after every
    // line), but each file is flushed through to the disk before it takes the old one's place. The rename alone only orders the change
    // in the file system's cache: power lost at the car a moment after a save could otherwise leave a .bin or .asm empty or full of
    // zeros, the old one already gone - the one thing this class is for.
    static readonly System.Text.UTF8Encoding Utf8 = new(false);

    public static void WriteAllText(string path, string text) => Write(path, p => Durable(p, Utf8.GetBytes(text)));

    public static void WriteAllBytes(string path, byte[] data) => Write(path, p => Durable(p, data));

    public static void WriteAllLines(string path, IEnumerable<string> lines) => Write(path, p =>
    {
        using var fs = new FileStream(p, FileMode.Create, FileAccess.Write, FileShare.None);
        using (var w = new StreamWriter(fs, Utf8, 65536, leaveOpen: true))
            foreach (var line in lines) w.WriteLine(line);
        fs.Flush(flushToDisk: true);
    });

    /// Push a file just written (by something else: a zip) through to the disk, before it is renamed into place.
    public static void FlushToDisk(string path)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read);
        fs.Flush(flushToDisk: true);
    }

    static void Durable(string path, ReadOnlySpan<byte> data)
    {
        using var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
        fs.Write(data);
        fs.Flush(flushToDisk: true);
    }

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
