// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Reflection;

namespace OkiRomSim.Core;

/// Every field of the simulated machine - the CPU, the bus and its peripherals, the engine, the board - as text keyed by where it lives ("Bus.Pins.Level"), and put back from it. A project saves the machine this way, so a field added to the simulator later is saved without anyone having to remember to add it; one the saved file does not have keeps its value, and one that no longer exists is ignored. Records rather than state (hit counts, coverage, the decode cache: arrays over MaxArray long, or of objects) and the ROM and RAM images (saved on their own) are left out.
public static class StateSnapshot
{
    const int MaxArray = 8192;
    static readonly HashSet<string> SkipNames = new(StringComparer.Ordinal)
    {
        "Rom", "Ram", "RomReadCount", "RomReadAt", "RomReadLog", "RomReadTotal", "SweepPc", "SweepReads", "_runNext", "_runLen",
        "OnDataRead", "OnDataWrite", "DataReadHook", "Symbols",
    };
    static readonly HashSet<string> SkipTypes = new(StringComparer.Ordinal) { "ProcessorProfile" };

    public static Dictionary<string, string> Capture(object root)
    {
        var d = new Dictionary<string, string>(StringComparer.Ordinal);
        Walk(root, "", d, null, new HashSet<object>(ReferenceEqualityComparer.Instance));
        return d;
    }

    /// Put the saved fields back; returns how many were.
    public static int Restore(object root, IReadOnlyDictionary<string, string> saved)
    {
        int n = 0;
        Walk(root, "", null, saved, new HashSet<object>(ReferenceEqualityComparer.Instance), () => n++);
        return n;
    }

    static string Clean(string field) => field.StartsWith('<') && field.IndexOf('>') is int e and > 0 ? field[1..e] : field;

    static bool IsScalar(Type t)
    {
        t = Nullable.GetUnderlyingType(t) ?? t;
        return t.IsPrimitive || t.IsEnum || t == typeof(string) || t == typeof(decimal);
    }

    static string ToText(object? v) => v switch
    {
        null => "null",
        bool b => b ? "1" : "0",
        double x => x.ToString("R", CultureInfo.InvariantCulture),
        float x => x.ToString("R", CultureInfo.InvariantCulture),
        Enum e => Convert.ToInt64(e, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture),
        IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
        _ => v.ToString() ?? "",
    };

    static object? FromText(string s, Type t)
    {
        if (s == "null") return null;
        var u = Nullable.GetUnderlyingType(t) ?? t;
        if (u == typeof(string)) return s;
        if (u == typeof(bool)) return s == "1";
        if (u.IsEnum) return Enum.ToObject(u, long.Parse(s, CultureInfo.InvariantCulture));
        return Convert.ChangeType(s, u, CultureInfo.InvariantCulture);
    }

    static readonly MethodInfo Refs = typeof(System.Runtime.CompilerServices.RuntimeHelpers).GetMethod(nameof(System.Runtime.CompilerServices.RuntimeHelpers.IsReferenceOrContainsReferences))!;
    static bool Plain(Type t) => !(bool)Refs.MakeGenericMethod(t).Invoke(null, null)!;

    /// Which of the helpers below copies this collection, or null when it holds anything but plain values.
    static string? Collection(Type t)
    {
        var g = t.GetGenericTypeDefinition();
        var args = t.GetGenericArguments();
        if (!args.All(Plain)) return null;
        return g == typeof(List<>) ? nameof(ListBytes) : g == typeof(Queue<>) ? nameof(QueueBytes)
             : g == typeof(HashSet<>) ? nameof(SetBytes) : g == typeof(Dictionary<,>) ? nameof(DictBytes) : null;
    }

    // each: with `load` null, the collection's items as bytes; given bytes, the collection filled from them (and null back)
    static byte[]? ListBytes<T>(List<T> c, byte[]? load) where T : unmanaged
    {
        if (load == null) return System.Runtime.InteropServices.MemoryMarshal.AsBytes(System.Runtime.InteropServices.CollectionsMarshal.AsSpan(c)).ToArray();
        c.Clear(); c.AddRange(System.Runtime.InteropServices.MemoryMarshal.Cast<byte, T>(load).ToArray()); return null;
    }

    static byte[]? QueueBytes<T>(Queue<T> c, byte[]? load) where T : unmanaged
    {
        if (load == null) return System.Runtime.InteropServices.MemoryMarshal.AsBytes(c.ToArray().AsSpan()).ToArray();
        c.Clear(); foreach (var x in System.Runtime.InteropServices.MemoryMarshal.Cast<byte, T>(load).ToArray()) c.Enqueue(x); return null;
    }

    static byte[]? SetBytes<T>(HashSet<T> c, byte[]? load) where T : unmanaged
    {
        if (load == null) return System.Runtime.InteropServices.MemoryMarshal.AsBytes(c.ToArray().AsSpan()).ToArray();
        c.Clear(); foreach (var x in System.Runtime.InteropServices.MemoryMarshal.Cast<byte, T>(load).ToArray()) c.Add(x); return null;
    }

    static byte[]? DictBytes<K, V>(Dictionary<K, V> c, byte[]? load) where K : unmanaged where V : unmanaged
    {
        if (load == null) return System.Runtime.InteropServices.MemoryMarshal.AsBytes(c.ToArray().AsSpan()).ToArray();
        c.Clear();
        foreach (var kv in System.Runtime.InteropServices.MemoryMarshal.Cast<byte, KeyValuePair<K, V>>(load).ToArray()) c[kv.Key] = kv.Value;
        return null;
    }

    static void Walk(object o, string path, Dictionary<string, string>? save, IReadOnlyDictionary<string, string>? load,
                     HashSet<object> seen, Action? restored = null)
    {
        if (!seen.Add(o)) return;
        for (var t = o.GetType(); t != null && t != typeof(object); t = t.BaseType)
            foreach (var f in t.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly))
            {
                var name = Clean(f.Name);
                if (SkipNames.Contains(name)) continue;
                var key = path + name;
                var ft = f.FieldType;
                var v = f.GetValue(o);
                if (IsScalar(ft))
                {
                    if (save != null) save[key] = ToText(v);
                    else if (load!.TryGetValue(key, out var s))
                        try { f.SetValue(o, FromText(s, ft)); restored?.Invoke(); } catch { }
                }
                else if (ft.IsArray && ft.GetElementType() is { IsPrimitive: true } && v is Array arr)
                {
                    if (arr.Length > MaxArray) continue;
                    if (save != null)
                    {
                        var bytes = new byte[Buffer.ByteLength(arr)];
                        Buffer.BlockCopy(arr, 0, bytes, 0, bytes.Length);
                        save[key] = Convert.ToBase64String(bytes);
                    }
                    else if (load!.TryGetValue(key, out var s))
                    {
                        var bytes = Convert.FromBase64String(s);
                        if (bytes.Length == Buffer.ByteLength(arr)) { Buffer.BlockCopy(bytes, 0, arr, 0, bytes.Length); restored?.Invoke(); }
                    }
                }
                else if (ft.IsArray && ft.GetElementType() is { IsArray: true } inner && inner.GetElementType() is { IsPrimitive: true } && v is Array outer)
                {
                    // an array of arrays (the mux inputs): each inner one under its index
                    for (int i = 0; i < outer.Length; i++)
                        if (outer.GetValue(i) is Array a && a.Length <= MaxArray)
                        {
                            var k = $"{key}[{i}]";
                            if (save != null)
                            {
                                var bytes = new byte[Buffer.ByteLength(a)];
                                Buffer.BlockCopy(a, 0, bytes, 0, bytes.Length);
                                save[k] = Convert.ToBase64String(bytes);
                            }
                            else if (load!.TryGetValue(k, out var s) && Convert.FromBase64String(s) is var bytes && bytes.Length == Buffer.ByteLength(a))
                            { Buffer.BlockCopy(bytes, 0, a, 0, bytes.Length); restored?.Invoke(); }
                        }
                }
                else if (v != null && ft.IsGenericType && Collection(ft) is { } kind)
                {
                    // a list, queue, set or dictionary of plain values (the injector pulses still open, the serial bytes on their way in, the pins forced): its items as their bytes
                    var m = typeof(StateSnapshot).GetMethod(kind, BindingFlags.NonPublic | BindingFlags.Static)!.MakeGenericMethod(ft.GetGenericArguments());
                    if (save != null) save[key] = Convert.ToBase64String((byte[])m.Invoke(null, [v, null])!);
                    else if (load!.TryGetValue(key, out var s)) { m.Invoke(null, [v, Convert.FromBase64String(s)]); restored?.Invoke(); }
                }
                else if (v != null && !ft.IsValueType && !typeof(Delegate).IsAssignableFrom(ft) && !SkipTypes.Contains(v.GetType().Name)
                         && v.GetType().Namespace?.StartsWith("OkiRomSim.Core", StringComparison.Ordinal) == true)
                    Walk(v, key + ".", save, load, seen, restored);
            }
    }
}
