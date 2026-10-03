// Copyright (c) bmgjet. All rights reserved.
using System.Security.Cryptography;
using System.Text;

namespace OkiRomSim.Calibration;

/// An open password for a ROM, kept in the ROM itself (the watermark module, p30-features/watermark.asm): Rom Sim Studio asks for it before it opens a ROM that has one set. What is stored is not the password but a PBKDF2-SHA256 hash of it with a random salt, so the password cannot be read back out of the bytes - only checked. The block, 28 bytes: "OKPW" (so it can be found in a ROM with no labels), a version byte, a reserved byte, an 8-byte salt, a 14-byte hash. All 00 or FF after the marker: no password set. This is a lock on opening the ROM in this app, not encryption of the ROM: the ECU runs the ROM whatever, and the code and tables are ordinary bytes any other tool can read. Taking the block out by hand changes the ROM's bytes, so its checksum no longer balances (the ECU's self-test fails and the app reports it) unless that is put right as well.
public static class RomPassword
{
    public const int Bytes = 28;
    static readonly byte[] Marker = "OKPW"u8.ToArray();
    const byte FormatVersion = 1;
    const int SaltBytes = 8, HashBytes = 14, Iterations = 120_000;

    /// The block for a password (a fresh salt each time); an empty password gives the "no password" block.
    public static byte[] Create(string password)
    {
        var b = new byte[Bytes];
        Marker.CopyTo(b, 0);
        if (password.Length == 0) return b;
        b[4] = FormatVersion;
        var salt = RandomNumberGenerator.GetBytes(SaltBytes);
        salt.CopyTo(b, 6);
        Hash(password, salt).CopyTo(b, 6 + SaltBytes);
        return b;
    }

    /// The block with no password set.
    public static byte[] Cleared() => Create("");

    static byte[] Hash(string password, byte[] salt) =>
        Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), salt, Iterations, HashAlgorithmName.SHA256, HashBytes);

    /// A block that holds a password (the marker, a known version, a salt and hash that are not blank).
    public static bool IsSet(ReadOnlySpan<byte> block) =>
        block.Length >= Bytes && block[..4].SequenceEqual(Marker) && block[4] == FormatVersion
        && !block[6..Bytes].ToArray().All(x => x == 0x00) && !block[6..Bytes].ToArray().All(x => x == 0xFF);

    /// Whether a password is the one the block was made from.
    public static bool Check(ReadOnlySpan<byte> block, string password)
    {
        if (!IsSet(block)) return true;
        var salt = block.Slice(6, SaltBytes).ToArray();
        var want = block.Slice(6 + SaltBytes, HashBytes).ToArray();
        return CryptographicOperations.FixedTimeEquals(Hash(password, salt), want);
    }

    /// Where the block is in a ROM image (found by its marker), or -1.
    public static int Find(ReadOnlySpan<byte> rom)
    {
        for (int at = rom.IndexOf(Marker); at >= 0 && at + Bytes <= rom.Length;)
        {
            if (rom[at + 4] is 0 or FormatVersion) return at;
            int next = rom[(at + 1)..].IndexOf(Marker);
            if (next < 0) break;
            at += next + 1;
        }
        return -1;
    }

    /// The block's address when the ROM has a password set, else -1.
    public static int Locked(ReadOnlySpan<byte> rom) => Find(rom) is int at and >= 0 && IsSet(rom[at..]) ? at : -1;
}
