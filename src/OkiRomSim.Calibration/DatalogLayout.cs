// Copyright (c) bmgjet. All rights reserved.
using System.Text;
using Decoder = OkiRomSim.Core.Decoder;
using OkiRomSim.Core;

namespace OkiRomSim.Calibration;

/// What a ROM's datalogging looks like, worked out from the ROM itself rather than from a list of known protocols: the command bytes its serial code compares against, tried in a simulator until one produces a checksummed frame, and then the meaning of each byte found by changing one engine input at a time and watching which bytes follow it. The result can be used straight away (DetectedProtocol) and saved with the project, so a ROM with its own datalog format still logs, graphs and overlays like the known ones.
public sealed class DatalogFieldMap
{
    /// Frame byte index -> channel name ("rpm" is a 16-bit pair, low byte first).
    public Dictionary<int, string> Bytes { get; set; } = [];
    public Dictionary<int, string> Words { get; set; } = [];

    RawNames? _rawNames;
    int _rawLength = -1;

    public LogFrame Decode(byte[] raw, double t)
    {
        var f = new LogFrame { T = t, Raw = [.. raw] };
        foreach (var (i, name) in Words)
        {
            if (i + 1 >= raw.Length) continue;
            int w = raw[i] | (raw[i + 1] << 8);
            switch (name)
            {
                case "rpm": f.Rpm = w == 0 ? 0 : Math.Round(1875000.0 / w); break;
                case "inj_ms": f.InjMs = Math.Round(w * 3.2 / 1000, 2); break;
                default: f.Extra[name] = w; break;
            }
        }
        foreach (var (i, name) in Bytes)
        {
            if (i >= raw.Length) continue;
            byte b = raw[i];
            switch (name)
            {
                case "map_kpa": f.MapKpa = Math.Round(HondaDatalog.MapKpa(b), 1); break;
                case "tps_pct": f.TpsPct = Math.Round(HondaDatalog.TpsPct(b), 1); break;
                case "ect_c": f.EctC = HondaDatalog.ThermistorC(b); break;
                case "iat_c": f.IatC = HondaDatalog.ThermistorC(b); break;
                case "o2_v": f.O2V = Math.Round(HondaDatalog.Volts(b), 3); break;
                case "batt_v": f.BattV = Math.Round(26.0 * b / 270.0, 2); break;
                case "speed_kmh": f.SpeedKmh = b; break;
                case "ign_deg": f.IgnDeg = (b * 0.25) - 6; break;
                default: f.Extra[name] = b; break;
            }
        }
        // the bytes with no meaning found for them, by number, read from Raw when asked for
        if (_rawNames == null || _rawLength != raw.Length)
        {
            _rawLength = raw.Length;
            _rawNames = new RawNames(Enumerable.Range(0, raw.Length)
                .Where(i => !Bytes.ContainsKey(i) && !Words.ContainsKey(i) && !Words.ContainsKey(i - 1)).Select(i => ($"b{i}", i)));
        }
        f.RawChannels = _rawNames;
        return f;
    }

    public string Describe() =>
        string.Join(", ", Words.OrderBy(k => k.Key).Select(k => $"{k.Key}-{k.Key + 1}={k.Value}")
            .Concat(Bytes.OrderBy(k => k.Key).Select(k => $"{k.Key}={k.Value}")));
}

/// A protocol built from what was detected, so an unknown ROM logs like a known one.
public sealed class DetectedProtocol : DatalogProtocol
{
    public byte? HandshakeSend { get; set; }
    public byte? HandshakeReply { get; set; }
    public byte? Request { get; set; }
    public int FrameLength { get; set; }
    public DatalogFieldMap Map { get; set; } = new();
    public string Origin { get; set; } = "detected";

    public override string Name => "Detected layout";
    public override string Description =>
        $"{(HandshakeSend is byte h ? $"{h:X2}->{HandshakeReply:X2}, " : "")}{(Request is byte r ? $"{r:X2} -> " : "streamed ")}" +
        $"{FrameLength} bytes + checksum; {Map.Describe()}";

    public override bool Handshake(IByteLink link, out string note)
    {
        if (HandshakeSend is not byte send || HandshakeReply is not byte want) { note = "no handshake needed"; Drain(link); return true; }
        return HandshakeByte(link, send, want, out note);
    }

    public override LogFrame? Poll(IByteLink link, double t, out string note)
    {
        if (Request is not byte req) { note = "no request byte"; return null; }
        return Framed(link, req, FrameLength, raw => Map.Decode(raw, t), t, out note);
    }
}
