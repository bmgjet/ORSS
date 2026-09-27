// Copyright (c) bmgjet. All rights reserved.
using System.Reflection;
using System.Text.RegularExpressions;

namespace OkiRomSim.Assembler;

/// One instruction production parsed from the embedded instrs.y grammar.
public sealed class Rule
{
    public required string Mnemonic;
    /// RHS symbols after the mnemonic, without the trailing NL: terminals like "R_A", "','", "OFFSET", "DOT3", or the non-terminal "expr".
    public required string[] Symbols;
    public required byte[] Template;
    /// (kind, byteIndex, yaccPosition, relInstrSize) - kind: 'B' byte, 'W' word, 'R' rel8
    public required (char Kind, int Index, int Pos, int RelSize)[] Actions;
    public int Order;
    public string Display => Mnemonic + " " + string.Join(" ", Symbols.Select(Pretty)).Replace(" ,", ",");
    static string Pretty(string s) => s switch
    {
        "expr" => "e",
        "OFFSET" => "off",
        _ when s.StartsWith("R_") => s[2..],
        _ when s.StartsWith("DOT") => "." + s[3..],
        _ when s.StartsWith('\'') => s.Trim('\''),
        _ => s
    };
}

public sealed class Grammar
{
    public static Grammar Instance => field ??= Load();

    readonly Dictionary<string, List<Rule>> _byMnemonic = new(StringComparer.OrdinalIgnoreCase);
    public IReadOnlyCollection<string> Mnemonics => _byMnemonic.Keys;
    public int RuleCount { get; private set; }

    public bool IsMnemonic(string s) => _byMnemonic.ContainsKey(s) || s.Equals("VCAL", StringComparison.OrdinalIgnoreCase);
    public IReadOnlyList<Rule> RulesFor(string mnem) =>
        _byMnemonic.TryGetValue(mnem, out var l) ? l : (IReadOnlyList<Rule>)[];
    public IEnumerable<Rule> AllRules => _byMnemonic.Values.SelectMany(x => x).OrderBy(r => r.Order);

    static readonly Regex RuleRe = new(@"^\s*\|\s*(\S+)\s*(.*?)\s*NL\s*\{\s*u8 instr\[(\d+)\] = \{([^}]*)\};(.*?)emit\(instr,\s*\d+\);\s*\}\s*$");
    static readonly Regex ActRe = new(@"instr\[(\d+)\] = \$(\d+);|_SET16\(instr,(\d+),\$(\d+)\);|instr\[(\d+)\] = _REL8\((\d+),\$(\d+)\);");

    static Grammar Load()
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("instrs.y")
            ?? throw new InvalidOperationException("instrs.y resource missing");
        using var rd = new StreamReader(s);
        return Parse(rd.ReadToEnd());
    }

    public static Grammar Parse(string text)
    {
        var g = new Grammar();
        int order = 0;
        foreach (var raw in text.Split('\n'))
        {
            var m = RuleRe.Match(raw);
            if (!m.Success) continue;
            var syms = Regex.Matches(m.Groups[2].Value, @"'[^']'|\S+").Select(x => x.Value).ToArray();
            var tmpl = m.Groups[4].Value.Split(',').Select(x => x.Trim()).Select(x => x.StartsWith("0x") ? Convert.ToByte(x[2..], 16) : (byte)0).ToArray();
            var acts = new List<(char, int, int, int)>();
            foreach (Match a in ActRe.Matches(m.Groups[5].Value))
            {
                if (a.Groups[1].Success) acts.Add(('B', int.Parse(a.Groups[1].Value), int.Parse(a.Groups[2].Value), 0));
                else if (a.Groups[3].Success) acts.Add(('W', int.Parse(a.Groups[3].Value), int.Parse(a.Groups[4].Value), 0));
                else acts.Add(('R', int.Parse(a.Groups[5].Value), int.Parse(a.Groups[7].Value), int.Parse(a.Groups[6].Value)));
            }
            var rule = new Rule
            {
                Mnemonic = m.Groups[1].Value.ToUpperInvariant(), Symbols = syms, Template = tmpl,
                Actions = [.. acts], Order = order++
            };
            if (!g._byMnemonic.TryGetValue(rule.Mnemonic, out var list)) g._byMnemonic[rule.Mnemonic] = list = [];
            list.Add(rule);
        }
        g.RuleCount = order;
        return g;
    }

    /// Try to match the operand tokens (everything after the mnemonic, ending in End) against a rule. On success returns the parsed expressions keyed by yacc position ($n, the mnemonic is $1).
    public static Dictionary<int, Expr>? Match(Rule r, List<Token> toks, int start) => Match(r, toks, start, null);

    /// As Match, with the expressions already parsed on this line (by token position: the expression and where it ended, or null when none parses there) shared between the rules tried, so each is parsed once however many rules are tried.
    public static Dictionary<int, Expr>? Match(Rule r, List<Token> toks, int start, Dictionary<int, (Expr? E, int End)>? parsed)
    {
        int pos = start;
        // the terminals first: most rules fail on one of them, and that costs nothing to find out
        {
            int q = start;
            for (int k = 0; k < r.Symbols.Length; k++)
            {
                var sym = r.Symbols[k];
                if (sym == "expr") break;
                if (!IsTerminal(toks[q], sym)) return null;
                q++;
            }
        }
        Dictionary<int, Expr>? exprs = null;
        for (int k = 0; k < r.Symbols.Length; k++)
        {
            var sym = r.Symbols[k];
            var t = toks[pos];
            if (sym == "expr")
            {
                if (!ExprParser.StartsExpr(t)) return null;
                (Expr? E, int End) got;
                if (parsed == null || !parsed.TryGetValue(pos, out got))
                {
                    int q = pos;
                    try { got = (ExprParser.Parse(toks, ref q), q); }
                    catch (AsmException) { got = (null, pos); }
                    parsed?.Add(pos, got);
                }
                if (got.E == null) return null;
                (exprs ??= [])[k + 2] = got.E;
                pos = got.End;
                continue;
            }
            if (!IsTerminal(t, sym)) return null;
            pos++;
        }
        return toks[pos].Kind == Tk.End ? exprs ?? [] : null;
    }

    /// Whether a token is this grammar terminal ("R_A", "OFFSET", "DOT3", "','", "Number"...), without building its name.
    static bool IsTerminal(Token t, string sym) => t.Kind switch
    {
        Tk.End => false,
        Tk.Register or Tk.Dot or Tk.Keyword or Tk.Mnemonic => t.Text == sym,
        Tk.Punct => sym.Length == t.Text.Length + 2 && sym[0] == '\'' && sym[^1] == '\'' && string.CompareOrdinal(sym, 1, t.Text, 0, t.Text.Length) == 0,
        _ => sym == KindName(t.Kind),
    };

    static readonly string[] KindNames = Enum.GetNames<Tk>();
    static string KindName(Tk k) => KindNames[(int)k];
}
