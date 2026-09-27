// Copyright (c) bmgjet. All rights reserved.

namespace OkiRomSim.Calibration;

/// The watermark (p30-features/watermark.asm): 16 characters stored scrambled, then a 16-bit check word, 18 bytes. The scrambling keeps the text from showing in a hex view; it is not strong encryption. The check word is worked out from the text, so an edit made without this code (a hex editor, another tool) shows up as "modified". The ROM itself only carries the bytes: it does nothing different either way.
public static class WatermarkCodec
{
    public const int Length = 16, Bytes = Length + 2;

    static byte Key(int i) => (byte)((0x5A + 0x3B * i) ^ (i * 7));

    static ushort Check(ReadOnlySpan<byte> plain)
    {
        ushort c = 0xB3C5;
        for (int i = 0; i < Length; i++)
        {
            c = (ushort)((c << 3) | (c >> 13));
            c ^= (ushort)(plain[i] | (Key(i) << 8));
        }
        return c;
    }

    /// The 18 bytes for a text (cut to 16 characters, padded with spaces; characters outside printable ASCII become '?').
    public static byte[] Encode(string text)
    {
        var plain = new byte[Length];
        for (int i = 0; i < Length; i++)
        {
            char ch = i < text.Length ? text[i] : ' ';
            plain[i] = ch is >= ' ' and <= '~' ? (byte)ch : (byte)'?';
        }
        var b = new byte[Bytes];
        for (int i = 0; i < Length; i++) b[i] = (byte)(plain[i] ^ Key(i));
        ushort c = Check(plain);
        b[Length] = (byte)c; b[Length + 1] = (byte)(c >> 8);
        return b;
    }

    /// The text stored in 18 bytes (trailing spaces dropped), and whether the check word still matches it.
    public static (string Text, bool Intact) Decode(ReadOnlySpan<byte> b)
    {
        if (b.Length < Bytes) return ("", false);
        var plain = new byte[Length];
        for (int i = 0; i < Length; i++) plain[i] = (byte)(b[i] ^ Key(i));
        bool intact = Check(plain) == (ushort)(b[Length] | (b[Length + 1] << 8));
        var text = new string([.. plain.Select(x => x is >= 0x20 and <= 0x7E ? (char)x : '?')]).TrimEnd();
        return (text, intact);
    }
}
