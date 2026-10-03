// Copyright (c) bmgjet. All rights reserved.
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using Avalonia;
using Avalonia.Controls;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// A translation: one JSON file in the lang folder, "English text": "the same in this language", easy to edit by hand.
public sealed class LangFile
{
    /// What the language calls itself ("Deutsch", "中文").
    public string Language { get; set; } = "";
    /// Its English name ("German").
    public string English { get; set; } = "";
    /// The file's name without .json ("de"): what Settings keeps.
    [JsonIgnore] public string Code { get; set; } = "";
    public string Author { get; set; } = "";
    public string Notes { get; set; } = "";
    public Dictionary<string, string> Strings { get; set; } = [];
}

/// The app in other languages. English is built in; every other language is a JSON file in the lang folder beside the program (or in the settings folder's lang, for your own), read when the app starts - add a file there and it is offered in Settings > General. Text is translated as it is put on screen: every piece of text whose English is in the file is shown in the other language, and anything not in it stays English (so a file can be partly done, and grows as you go). With a language picked, the English text seen that has no translation yet is gathered, and Settings > General can write it out as a starting point for the translator.
public static class Lang
{
    static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true, ReadCommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    static Dictionary<string, string> _map = new(StringComparer.Ordinal);
    /// The same strings looked up whatever their case: a heading drawn in capitals ("ENGINE INPUTS") finds "Engine inputs".
    static Dictionary<string, string> _anyCase = new(StringComparer.OrdinalIgnoreCase);
    static readonly HashSet<string> _missing = new(StringComparer.Ordinal);
    static readonly object _lock = new();
    static bool _hooked;
    [ThreadStatic] static bool _busy;

    /// The language in use ("en" when none).
    public static string Current { get; private set; } = "en";

    /// The folders searched for translations: the program's own lang folder, then yours (the settings folder's).
    public static IEnumerable<string> Folders =>
        [Path.Combine(AppContext.BaseDirectory, "lang"), Path.Combine(AppSettings.Dir, "lang")];

    /// Every language on offer: English, then each file found.
    public static List<LangFile> Available()
    {
        var list = new List<LangFile> { new() { Code = "en", Language = "English", English = "English" } };
        foreach (var dir in Folders.Where(Directory.Exists))
            foreach (var f in Directory.GetFiles(dir, "*.json").Order(StringComparer.OrdinalIgnoreCase))
            {
                var code = Path.GetFileNameWithoutExtension(f);
                if (code.Equals("en", StringComparison.OrdinalIgnoreCase) || code.StartsWith("missing-", StringComparison.OrdinalIgnoreCase)) continue;
                if (list.Any(l => l.Code.Equals(code, StringComparison.OrdinalIgnoreCase))) continue;     // yours of the same name is not offered twice
                try
                {
                    var lf = JsonSerializer.Deserialize<LangFile>(File.ReadAllText(f), Json) ?? new LangFile();
                    lf.Code = code;
                    if (lf.Language.Length == 0) lf.Language = code;
                    list.Add(lf);
                }
                catch (Exception ex) { AppLog.Warn("lang", $"{Path.GetFileName(f)} could not be read: {ex.Message}"); }
            }
        return list;
    }

    /// Use a language (its code; "en" or one not found is English). Text already on screen changes the next time it is set; windows opened from now on are in it.
    public static void Use(string code)
    {
        Hook();
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        string now = "en";
        if (!string.IsNullOrEmpty(code) && !code.Equals("en", StringComparison.OrdinalIgnoreCase))
        {
            // the program's file first, then yours on top of it (yours wins where both have a string)
            foreach (var dir in Folders)
            {
                var f = Path.Combine(dir, code + ".json");
                if (!File.Exists(f)) continue;
                try
                {
                    var lf = JsonSerializer.Deserialize<LangFile>(File.ReadAllText(f), Json);
                    foreach (var (k, v) in lf?.Strings ?? []) if (k.Length > 0 && !string.IsNullOrEmpty(v)) map[k] = v;
                    now = code;
                }
                catch (Exception ex) { AppLog.Warn("lang", $"{Path.GetFileName(f)} could not be read: {ex.Message}"); }
            }
        }
        var anyCase = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (k, v) in map) anyCase.TryAdd(k, v);
        lock (_lock) { _map = map; _anyCase = anyCase; _values = new HashSet<string>(map.Values, StringComparer.Ordinal); _missing.Clear(); }
        Current = now;
        AppLog.Info("lang", now == "en" ? "English" : $"{now}: {map.Count} strings");
    }

    /// The text in the language in use (unchanged when it has no translation).
    public static string T(string english)
    {
        if (Current == "en" || english.Length == 0) return english;
        if (_values.Contains(english)) return english;          // already in this language (the same text set again)
        if (Find(english) is { } t) return t;
        // the words inside what is round them: an icon in front ("▶ Run"), a hotkey, unit or note behind ("Run (F5)", "Coolant (°C)", "Fuel map value (every-channel module)"), a menu arrow ("File ▾")
        string pre = "", core = english, post = "";
        int sp = core.IndexOf(' ');
        if (sp is > 0 and <= 3 && !char.IsLetterOrDigit(core[0]) && core[0] != '(' && core[0] != '+')
        {
            var after = core[(sp + 1)..].TrimStart();
            pre = core[..(core.Length - after.Length)]; core = after;
        }
        if (core.EndsWith('▾')) { var c2 = core.TrimEnd('▾').TrimEnd(); post = core[c2.Length..]; core = c2; }
        int open = core.LastIndexOf(" (", StringComparison.Ordinal);
        if (open > 0 && core.EndsWith(')') && post.Length == 0)
        {
            var head = core[..open].TrimEnd();
            var inner = core[(open + 2)..^1];
            post = core[head.Length..open] + " (" + (Find(inner) ?? inner) + ")";
            core = head;
        }
        if ((pre.Length > 0 || post.Length > 0) && Find(core) is { } mid) return pre + mid + post;
        Miss(english);
        return english;
    }

    /// Every translation: text already in the language is left alone (and is not reported as missing).
    static HashSet<string> _values = new(StringComparer.Ordinal);

    /// The translation of the whole text: as it is, without a trailing colon or ellipsis, or in any case (a heading in capitals is given back in capitals).
    static string? Find(string s)
    {
        if (_map.TryGetValue(s, out var t)) return t;
        if (s.EndsWith(':') && _map.TryGetValue(s[..^1], out var c)) return c + ":";
        if (s.EndsWith('…') && _map.TryGetValue(s[..^1], out var e)) return e + "…";
        if (_anyCase.TryGetValue(s, out var a)) return s.Any(char.IsLetter) && s.Where(char.IsLetter).All(char.IsUpper) ? a.ToUpperInvariant() : a;
        return null;
    }

    static void Miss(string s)
    {
        if (s.Length > 400 || !s.Any(char.IsLetter) || s.All(ch => char.IsDigit(ch) || char.IsPunctuation(ch) || char.IsWhiteSpace(ch) || char.IsUpper(ch) && s.Length < 4)) return;
        lock (_lock) if (_missing.Count < 20000) _missing.Add(s);
    }

    /// Every piece of text put on screen goes through T: the hook on TextBlock (which buttons, menus, tabs, tool tips and labels all draw with).
    static void Hook()
    {
        if (_hooked) return;
        _hooked = true;
        TextBlock.TextProperty.Changed.AddClassHandler<TextBlock>((tb, e) =>
        {
            if (_busy || Current == "en" || e.NewValue is not string s || s.Length == 0) return;
            var t = T(s);
            if (ReferenceEquals(t, s) || t == s) return;
            _busy = true;
            try { tb.SetCurrentValue(TextBlock.TextProperty, t); } finally { _busy = false; }
        });
        Window.TitleProperty.Changed.AddClassHandler<Window>((w, e) =>
        {
            if (_busy || Current == "en" || e.NewValue is not string s || s.Length == 0) return;
            var t = T(s);
            if (t == s) return;
            _busy = true;
            try { w.SetCurrentValue(Window.TitleProperty, t); } finally { _busy = false; }
        });
    }

    /// The English text seen on screen with no translation in the language in use, written as a language file to fill in: its path.
    public static string WriteMissing(string? folder = null)
    {
        List<string> missing;
        lock (_lock) missing = [.. _missing.Order(StringComparer.Ordinal)];
        var dir = folder ?? Path.Combine(AppSettings.Dir, "lang");
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, $"missing-{Current}.json");
        var lf = new LangFile
        {
            Language = Current, English = Current,
            Notes = "English text seen on screen with no translation yet. Fill in each value, then copy the lines into your language's file (lang\\" + Current + ".json). Empty values are ignored.",
            Strings = missing.ToDictionary(s => s, _ => ""),
        };
        File.WriteAllText(path, JsonSerializer.Serialize(lf, Json));
        return path;
    }

    public static int MissingCount { get { lock (_lock) return _missing.Count; } }
}
