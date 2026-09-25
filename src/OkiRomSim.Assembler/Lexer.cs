// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;

namespace OkiRomSim.Assembler;

public enum Tk
{
    Number, Symbol, String, Keyword, Register, Mnemonic, Dot, Punct, ShiftL, ShiftR, Dollar, End
}

public readonly record struct Token(Tk Kind, string Text, long Value, int Col)
{
    /// Grammar terminal name as it appears in instrs.y (e.g. "R_A", "OFFSET", "DOT3", "','").
    public string Terminal => Kind switch
    {
        Tk.Register => Text,
        Tk.Dot => Text,
        Tk.Punct => "'" + Text + "'",
        Tk.Keyword => Text,
        Tk.Mnemonic => Text,
        _ => Kind.ToString()
    };
    public override string ToString() => Kind == Tk.End ? "end of line" : Text;
}

/// Tokenizer for the assembler source language: keywords are case-insensitive, symbol names are case-sensitive.
public static class Lexer
{
    static readonly Dictionary<string, string> Registers = new(StringComparer.OrdinalIgnoreCase)
    {
        ["A"] = "R_A", ["C"] = "R_C", ["DP"] = "R_DP", ["X1"] = "R_X1", ["X2"] = "R_X2",
        ["USP"] = "R_USP", ["SSP"] = "R_SSP", ["LRB"] = "R_LRB", ["PSWH"] = "R_PSWH", ["PSWL"] = "R_PSWL",
        ["er0"] = "R_er0", ["er1"] = "R_er1", ["er2"] = "R_er2", ["er3"] = "R_er3",
        ["r0"] = "R_r0", ["r1"] = "R_r1", ["r2"] = "R_r2", ["r3"] = "R_r3",
        ["r4"] = "R_r4", ["r5"] = "R_r5", ["r6"] = "R_r6", ["r7"] = "R_r7",
    };
    static readonly Dictionary<string, string> Keywords = new(StringComparer.OrdinalIgnoreCase)
    {
        ["dw"] = "DW", ["db"] = "DB", ["org"] = "ORG", ["equ"] = "EQU", ["off"] = "OFFSET",
        ["preload"] = "PRELOAD", ["romsize"] = "ROMSIZE",
    };

    public static bool IsReservedWord(string s) =>
        Registers.ContainsKey(s) || Keywords.ContainsKey(s) || Grammar.Instance.IsMnemonic(s);

    public static List<Token> Tokenize(string line, out string? error)
    {
        error = null;
        var list = new List<Token>();
        int i = 0, n = line.Length;
        while (i < n)
        {
            char c = line[i];
            if (c == ' ' || c == '\t' || c == '\r') { i++; continue; }
            if (c == ';') break;
            int start = i;
            if (char.IsAsciiDigit(c))
            {
                // longest match among [0-9][0-9a-f]*h, 0x[0-9a-f]+, [0-9]+
                int j = i;
                while (j < n && char.IsAsciiHexDigit(line[j])) j++;
                if (j < n && (line[j] == 'h' || line[j] == 'H'))
                {
                    list.Add(new Token(Tk.Number, line[i..(j + 1)], long.Parse(line[i..j], NumberStyles.HexNumber), start));
                    i = j + 1; continue;
                }
                if (c == '0' && i + 1 < n && (line[i + 1] == 'x' || line[i + 1] == 'X') && i + 2 < n && char.IsAsciiHexDigit(line[i + 2]))
                {
                    j = i + 2;
                    while (j < n && char.IsAsciiHexDigit(line[j])) j++;
                    list.Add(new Token(Tk.Number, line[i..j], long.Parse(line[(i + 2)..j], NumberStyles.HexNumber), start));
                    i = j; continue;
                }
                j = i;
                while (j < n && char.IsAsciiDigit(line[j])) j++;
                list.Add(new Token(Tk.Number, line[i..j], long.Parse(line[i..j]), start));
                i = j; continue;
            }
            if (char.IsAsciiLetter(c) || c == '_')
            {
                int j = i;
                while (j < n && (char.IsAsciiLetterOrDigit(line[j]) || line[j] == '_')) j++;
                string w = line[i..j];
                if (Registers.TryGetValue(w, out var r)) list.Add(new Token(Tk.Register, r, 0, start));
                else if (Keywords.TryGetValue(w, out var k)) list.Add(new Token(Tk.Keyword, k, 0, start));
                else if (Grammar.Instance.IsMnemonic(w)) list.Add(new Token(Tk.Mnemonic, w.ToUpperInvariant(), 0, start));
                else list.Add(new Token(Tk.Symbol, w, 0, start));
                i = j; continue;
            }
            if (c == '"')
            {
                int j = line.IndexOf('"', i + 1);
                if (j < 0) { error = "unterminated string"; return list; }
                list.Add(new Token(Tk.String, line[(i + 1)..j], 0, start));
                i = j + 1; continue;
            }
            if (c == '.' && i + 1 < n && line[i + 1] >= '0' && line[i + 1] <= '7')
            {
                list.Add(new Token(Tk.Dot, "DOT" + line[i + 1], line[i + 1] - '0', start));
                i += 2; continue;
            }
            if (c == '<' && i + 1 < n && line[i + 1] == '<') { list.Add(new Token(Tk.ShiftL, "<<", 0, start)); i += 2; continue; }
            if (c == '>' && i + 1 < n && line[i + 1] == '>') { list.Add(new Token(Tk.ShiftR, ">>", 0, start)); i += 2; continue; }
            if (c == '$') { list.Add(new Token(Tk.Dollar, "$", 0, start)); i++; continue; }
            if ("[](),#+-*/%&|^~:!=<>".IndexOf(c) >= 0)
            {
                // two-char comparison operators (extension, only meaningful in if/assert)
                if (i + 1 < n && (c is '=' or '!' or '<' or '>') && line[i + 1] == '=')
                { list.Add(new Token(Tk.Punct, line.Substring(i, 2), 0, start)); i += 2; continue; }
                if (c == '&' && i + 1 < n && line[i + 1] == '&') { list.Add(new Token(Tk.Punct, "&&", 0, start)); i += 2; continue; }
                if (c == '|' && i + 1 < n && line[i + 1] == '|') { list.Add(new Token(Tk.Punct, "||", 0, start)); i += 2; continue; }
                list.Add(new Token(Tk.Punct, c.ToString(), 0, start)); i++; continue;
            }
            error = $"unexpected character '{c}'";
            return list;
        }
        list.Add(new Token(Tk.End, "", 0, n));
        return list;
    }
}
