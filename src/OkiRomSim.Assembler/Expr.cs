// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Assembler;

public abstract class Expr
{
    public int Col;
    public abstract long Eval(EvalContext ctx);
    public virtual IEnumerable<string> Symbols() { yield break; }
}

public sealed class EvalContext
{
    public required Func<string, (bool found, long value)> Lookup;
    public long Pc;
    /// Undefined symbols evaluate to 0 (pass 1). In the final pass they are reported.
    public bool Lenient;
    public List<string> Undefined { get; } = [];
    public Func<string, bool>? IsDefined;
}

sealed class NumExpr(long v) : Expr { public override long Eval(EvalContext c) => v; }
sealed class PcExpr : Expr { public override long Eval(EvalContext c) => c.Pc; }
sealed class SymExpr(string name) : Expr
{
    public string Name => name;
    public override long Eval(EvalContext c)
    {
        var (f, v) = c.Lookup(name);
        if (!f) { c.Undefined.Add(name); return 0; }
        return v;
    }
    public override IEnumerable<string> Symbols() { yield return name; }
}
sealed class DefinedExpr(string name) : Expr
{
    public override long Eval(EvalContext c) => c.IsDefined?.Invoke(name) == true ? 1 : 0;
}
sealed class UnExpr(string op, Expr a) : Expr
{
    public override long Eval(EvalContext c)
    {
        long x = a.Eval(c);
        return op switch { "-" => (int)-x, "~" => (int)~x, "!" => x == 0 ? 1 : 0, _ => x };
    }
    public override IEnumerable<string> Symbols() => a.Symbols();
}
sealed class BinExpr(string op, Expr a, Expr b) : Expr
{
    public override long Eval(EvalContext c)
    {
        long x = a.Eval(c), y = b.Eval(c);
        // operands evaluate as wrapping 32-bit signed ints
        int xi = (int)x, yi = (int)y;
        switch (op)
        {
            case "+": return xi + yi;
            case "-": return xi - yi;
            case "*": return xi * yi;
            case "/": if (yi == 0) throw new AsmException("division by zero"); return xi / yi;
            case "%": if (yi == 0) throw new AsmException("division by zero"); return xi % yi;
            case "&": return xi & yi;
            case "|": return xi | yi;
            case "^": return xi ^ yi;
            case "<<": return xi << (yi & 31);
            case ">>": return xi >> (yi & 31);
            case "==": return xi == yi ? 1 : 0;
            case "!=": return xi != yi ? 1 : 0;
            case "<": return xi < yi ? 1 : 0;
            case "<=": return xi <= yi ? 1 : 0;
            case ">": return xi > yi ? 1 : 0;
            case ">=": return xi >= yi ? 1 : 0;
            case "&&": return (xi != 0 && yi != 0) ? 1 : 0;
            case "||": return (xi != 0 || yi != 0) ? 1 : 0;
        }
        throw new AsmException("bad operator " + op);
    }
    public override IEnumerable<string> Symbols() => a.Symbols().Concat(b.Symbols());
}

public sealed class AsmException(string message) : Exception(message);

/// Precedence-climbing parser. Levels, lowest precedence first: << >> ; & | ^ ; + - ; * / % ; unary minus. `extended` adds comparison/logical operators (lower than all of the above) for if/assert.
public static class ExprParser
{
    static readonly string[][] AsmLevels =
    {
        new[] { "<<", ">>" },
        new[] { "&", "|", "^" },
        new[] { "+", "-" },
        new[] { "*", "/", "%" },
    };
    static readonly string[][] ExtLevels =
    {
        new[] { "||" }, new[] { "&&" }, new[] { "==", "!=", "<", "<=", ">", ">=" },
    };

    public static bool StartsExpr(Token t) =>
        t.Kind is Tk.Number or Tk.Symbol or Tk.Dollar ||
        (t.Kind == Tk.Punct && (t.Text is "(" or "-" or "~" or "!"));

    /// Nesting depth of the expression being parsed. Deep nesting (thousands of brackets or signs, as in a corrupt or hostile file) would otherwise exhaust the stack and take the whole process down, so it is refused as an ordinary error.
    [ThreadStatic] static int _depth;
    const int MaxDepth = 200, MaxTokens = 4000;

    public static Expr Parse(List<Token> toks, ref int pos, bool extended = false)
    {
        if (toks.Count > MaxTokens) throw new AsmException($"line too long ({toks.Count} tokens)");
        if (++_depth > MaxDepth) { _depth = 0; throw new AsmException("expression nested too deeply"); }
        try
        {
            var levels = extended ? [.. ExtLevels, .. AsmLevels] : AsmLevels;
            return ParseLevel(toks, ref pos, levels, 0, extended);
        }
        finally { if (_depth > 0) _depth--; }
    }

    static string? OpText(Token t) => t.Kind switch
    {
        Tk.ShiftL => "<<", Tk.ShiftR => ">>", Tk.Punct => t.Text, _ => null
    };

    static Expr ParseLevel(List<Token> toks, ref int pos, string[][] levels, int lvl, bool ext)
    {
        if (lvl == levels.Length) return ParseUnary(toks, ref pos, ext);
        var left = ParseLevel(toks, ref pos, levels, lvl + 1, ext);
        while (true)
        {
            var op = OpText(toks[pos]);
            if (op == null || Array.IndexOf(levels[lvl], op) < 0) return left;
            int col = toks[pos].Col;
            pos++;
            var right = ParseLevel(toks, ref pos, levels, lvl + 1, ext);
            left = new BinExpr(op, left, right) { Col = col };
        }
    }

    static Expr ParseUnary(List<Token> toks, ref int pos, bool ext)
    {
        var t = toks[pos];
        if (t.Kind == Tk.Punct && (t.Text == "-" || (ext && (t.Text == "~" || t.Text == "!")) || t.Text == "~"))
        {
            pos++;
            if (++_depth > MaxDepth) { _depth = 0; throw new AsmException("expression nested too deeply"); }
            try { return new UnExpr(t.Text, ParseUnary(toks, ref pos, ext)) { Col = t.Col }; }
            finally { if (_depth > 0) _depth--; }
        }
        return ParsePrimary(toks, ref pos, ext);
    }

    static Expr ParsePrimary(List<Token> toks, ref int pos, bool ext)
    {
        var t = toks[pos];
        switch (t.Kind)
        {
            case Tk.Number: pos++; return new NumExpr(t.Value) { Col = t.Col };
            case Tk.Dollar: pos++; return new PcExpr { Col = t.Col };
            case Tk.Symbol:
                pos++;
                if (ext && t.Text.Equals("defined", StringComparison.OrdinalIgnoreCase) &&
                    toks[pos].Kind == Tk.Punct && toks[pos].Text == "(" && toks[pos + 1].Kind == Tk.Symbol &&
                    toks[pos + 2].Kind == Tk.Punct && toks[pos + 2].Text == ")")
                {
                    var name = toks[pos + 1].Text; pos += 3;
                    return new DefinedExpr(name) { Col = t.Col };
                }
                return new SymExpr(t.Text) { Col = t.Col };
            case Tk.Punct when t.Text == "(":
                {
                    pos++;
                    var e = Parse(toks, ref pos, ext);
                    if (toks[pos].Kind != Tk.Punct || toks[pos].Text != ")")
                        throw new AsmException($"expected ')' but found {toks[pos]}");
                    pos++;
                    return e;
                }
        }
        throw new AsmException($"expected an expression but found {(t.Kind == Tk.End ? "end of line" : "'" + t.Text + "'")}");
    }
}
