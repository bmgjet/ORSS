using System.Net;
using System.Text;
using OkiRomSim.Calibration;

/// `--docs <file>`: the guide's page of every function the skeleton can be built with, written from the modules' own
/// headers and measured by building each one: what it does, what it costs in ROM and module RAM, what it needs and what
/// it cannot be built with. Run it after a module changes so the website says what the ROM does.
static class Docs
{
    public static int Write(Skeleton sk, string path)
    {
        static string H(string s) => WebUtility.HtmlEncode(s);
        var bare = sk.Build([]);
        int bareFree = bare.FreeBytes;
        // modules share a library (the cut requests, the trims, the outputs): it is counted once, apart, so each module's
        // size is what it adds to a ROM that has another module in it already
        const string LibA = "FEAT_ECTPRO", LibB = "FEAT_BOOSTCUT";
        var withLib = sk.Build([LibA]);
        int libBytes = bareFree - withLib.FreeBytes - (sk.Build([LibB]).FreeBytes - sk.Build([LibA, LibB]).FreeBytes);
        var cost = new System.Collections.Concurrent.ConcurrentDictionary<string, (int Rom, int Ram)>();
        Parallel.ForEach(sk.Features, f =>
        {
            // the stock functions against the bare skeleton; a module against a ROM with another module (and anything it needs) in
            var host = f.Stock ? new List<string>() : [f.Define == LibA ? LibB : LibA];
            host.AddRange(f.Requires.Where(r => !host.Contains(r)));
            var b = sk.Build(host);
            var r = sk.Build([.. host, f.Define]);
            cost[f.Define] = r.Success && b.Success ? (b.FreeBytes - r.FreeBytes, (r.Ram?.Used ?? 0) - (b.Ram?.Used ?? 0)) : (-1, -1);
            // the RAM a module's header says it takes, against what the build hands it
            if (!f.Stock && System.Text.RegularExpressions.Regex.Match(f.Ram, @"module RAM \((\d+) byte") is { Success: true } m && int.Parse(m.Groups[1].Value) != cost[f.Define].Ram)
                Console.WriteLine($"HEADER {f.Define}: says module RAM ({m.Groups[1].Value} bytes), the build hands it {cost[f.Define].Ram}");
            else if (!f.Stock && !f.Ram.Contains("module RAM", StringComparison.OrdinalIgnoreCase) && cost[f.Define].Ram > 0)
                Console.WriteLine($"HEADER {f.Define}: takes {cost[f.Define].Ram} bytes of module RAM its header does not mention (ram: {f.Ram})");
        });
        string Name(string d) => sk.Feature(d)?.Name ?? d;
        var sb = new StringBuilder();
        sb.AppendLine("""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{TITLE}} — Rom Sim Studio guide</title>
<link rel="icon" href="../favicon.ico">
<link rel="stylesheet" href="guide.css">
</head>
<body>
<header class="topbar"><button class="menu-btn" aria-label="Contents">☰</button><a class="logo" href="index.html">ROM SIM <b>STUDIO</b></a><span class="sp"></span><span class="links"><a href="../">Website</a> &nbsp;·&nbsp; <a href="../#start">Download</a></span></header>
<div class="frame"><nav class="side"></nav><main>

<h1>{{TITLE}}</h1>
""");
        int modules = sk.Features.Count(f => !f.Stock), stock = sk.Features.Count(f => f.Stock);
        sb.AppendLine($"<p class=\"lead\">The {modules} modules and {stock} stock functions File &gt; New ROM &gt; Create can build into the {sk.Platform} skeleton, from the modules' own headers. " +
                      $"The bare skeleton leaves {bareFree:N0} bytes of the 32 KB free. The modules share a library (the cut requests, the fuel and timing trims, the outputs) of about {libBytes:N0} bytes, " +
                      "built in once with the first module that needs it; the sizes below are what each adds on top of that, with anything it needs counted separately.</p>");
        sb.AppendLine("<p>Every module starts <b>switched off</b>: building one in changes nothing until it is set up and enabled on its page. See <a href=\"new-rom.html\">Creating a custom ROM</a> for how they are picked and checked.</p>");
        sb.Append("<p>");
        var groups = sk.Features.GroupBy(f => f.Category).OrderBy(g => g.First().Stock).ThenBy(g => g.Key).ToList();
        sb.Append(string.Join(" · ", groups.Select(g => $"<a href=\"#{Anchor(g.Key)}\">{H(g.Key)}</a>")));
        sb.AppendLine("</p>");
        foreach (var g in groups)
        {
            sb.AppendLine($"\n<h2 id=\"{Anchor(g.Key)}\">{H(g.Key)}</h2>");
            foreach (var f in g.OrderBy(f => f.Name))
            {
                var (rom, ram) = cost[f.Define];
                sb.AppendLine($"<div class=\"mod\" id=\"{f.Define.ToLowerInvariant()}\"><h3>{H(f.Name)}</h3>");
                sb.AppendLine($"<p>{H(f.About)}</p>");
                var meta = new List<string> { $"<code>{f.Define}</code>" };
                if (rom >= 0) meta.Add($"{rom:N0} bytes of ROM");
                if (ram > 0) meta.Add($"{ram} bytes of module RAM");
                if (!f.Stock && f.Ram.Length > 0 && !f.Ram.Equals("none", StringComparison.OrdinalIgnoreCase)) meta.Add("RAM: " + H(f.Ram));
                if (f.Requires.Count > 0) meta.Add("needs " + string.Join(", ", f.Requires.Select(r => $"<a href=\"#{r.ToLowerInvariant()}\">{H(Name(r))}</a>")));
                var conflicts = f.Conflicts.Concat(sk.Features.Where(o => o.Conflicts.Contains(f.Define, StringComparer.OrdinalIgnoreCase)).Select(o => o.Define))
                                 .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                if (conflicts.Count > 0) meta.Add("cannot be built with " + string.Join(", ", conflicts.Select(c => $"<a href=\"#{c.ToLowerInvariant()}\">{H(Name(c))}</a>")));
                sb.AppendLine($"<p class=\"meta\">{string.Join(" · ", meta)}</p></div>");
            }
        }
        sb.AppendLine("""

<footer>Rom Sim Studio {{VERSION}} · by bmgjet · <a href="licence.html">Licence</a></footer>
</main></div>
<script src="guide.js"></script>
</body>
</html>
""");
        bool p13 = sk.Platform.Equals("P13", StringComparison.OrdinalIgnoreCase);
        var html = sb.ToString().Replace("{{TITLE}}", p13 ? "Every function and module: P13" : "Every function and module")
                                .Replace("{{VERSION}}", OkiRomSim.Core.BuildInfo.Version);
        // the P13 page says what is not known yet, and points to the other
        html = html.Replace("<p>Every module starts <b>switched off</b>", p13
            ? "<div class=\"note warn\"><b>Not tested on a car</b>The P13 skeleton and these modules have only been run in the simulator. Simulate a P13 ROM thoroughly, and treat the first start with extra care.</div>\n<p>The same functions on the P30 skeleton: <a href=\"modules.html\">Every function and module</a>.</p>\n<p>Every module starts <b>switched off</b>"
            : "<p>The same functions on the P13 skeleton: <a href=\"modules-p13.html\">Every function and module: P13</a>.</p>\n<p>Every module starts <b>switched off</b>");
        File.WriteAllText(path, html);
        Console.WriteLine($"wrote {path}: {sk.Features.Count} functions");
        return 0;
    }

    static string Anchor(string s) => new([.. s.ToLowerInvariant().Select(c => char.IsLetterOrDigit(c) ? c : '-')]);
}
