// Copyright (c) bmgjet. All rights reserved.
// Execution coverage at two levels: address coverage (was a byte ever executed) and, the one that matters for "hit all branches", EDGE coverage (was each conditional branch seen both taken and not-taken). BranchesHalfCovered lists branches seen only one way, where untested paths hide.
using System.Text;

namespace OkiRomSim.Core;

public sealed class Coverage
{
    private readonly bool[] _executed = new bool[Bus.RomSize];
    private readonly uint[] _hits = new uint[Bus.RomSize];
    private readonly ulong[] _lastAt = new ulong[Bus.RomSize];

    /// Per conditional-branch site: bit 0 = seen taken, bit 1 = seen not-taken. Only populated for addresses that actually decoded to a conditional branch, so Count is the number of branch sites reached.
    private readonly Dictionary<ushort, int> _edges = [];

    public int AddressesExecuted { get; private set; }
    public ulong InstructionsObserved { get; private set; }

    public void Reset()
    {
        Array.Clear(_executed);
        Array.Clear(_hits);
        Array.Clear(_lastAt);
        _edges.Clear();
        AddressesExecuted = 0;
        InstructionsObserved = 0;
    }

    public bool WasExecuted(ushort addr) => _executed[addr & (Bus.RomSize - 1)];
    public uint Hits(ushort addr) => _hits[addr & (Bus.RomSize - 1)];
    /// Machine cycle at which the instruction at `addr` last started (0 = never).
    public ulong LastExecuted(ushort addr) => _lastAt[addr & (Bus.RomSize - 1)];

    public void RecordExecution(ushort pc, ulong cycle = 0)
    {
        int i = pc & (Bus.RomSize - 1);
        _lastAt[i] = cycle;
        if (!_executed[i]) { _executed[i] = true; AddressesExecuted++; }
        if (_hits[i] < uint.MaxValue) _hits[i]++;
        InstructionsObserved++;
    }

    /// Record the outcome of a conditional branch at `pc`.
    public void RecordBranch(ushort pc, bool taken)
    {
        _edges.TryGetValue(pc, out int mask);
        _edges[pc] = mask | (taken ? 1 : 2);
    }

    public int BranchSitesReached => _edges.Count;
    public int BranchSitesFullyCovered => _edges.Count(kv => kv.Value == 3);

    /// Branch sites seen only one way round, with the outcome still missing.
    public IEnumerable<(ushort Pc, bool MissingTaken)> BranchesHalfCovered() =>
        _edges.Where(kv => kv.Value != 3)
              .OrderBy(kv => kv.Key)
              .Select(kv => (kv.Key, (kv.Value & 1) == 0));

    /// Contiguous runs of never-executed ROM, largest first. Filler regions (long stretches of FFh) are reported separately so a 400-byte blanked block does not look like unreached logic.
    public IEnumerable<(ushort Start, int Length, bool IsFiller)> UnreachedRegions(
        Bus bus, int minLength = 8)
    {
        int start = -1;
        for (int i = 0; i <= Bus.RomSize; i++)
        {
            bool unreached = i < Bus.RomSize && !_executed[i];
            if (unreached && start < 0) start = i;
            else if (!unreached && start >= 0)
            {
                int len = i - start;
                if (len >= minLength)
                {
                    bool filler = true;
                    for (int k = start; k < i && filler; k++)
                        if (bus.Rom[k] != 0xFF && bus.Rom[k] != 0x00) filler = false;
                    yield return ((ushort)start, len, filler);
                }
                start = -1;
            }
        }
    }

    public string Summary(Bus bus, IReadOnlyDictionary<string, ushort>? symbols = null)
    {
        var sb = new StringBuilder();
        double pct = 100.0 * AddressesExecuted / Bus.RomSize;
        sb.AppendLine($"Instructions executed : {InstructionsObserved:N0}");
        sb.AppendLine($"ROM bytes reached     : {AddressesExecuted:N0} / {Bus.RomSize:N0} ({pct:F1}%)");
        sb.AppendLine($"Branch sites reached  : {BranchSitesReached:N0}");
        sb.AppendLine($"  both ways covered   : {BranchSitesFullyCovered:N0}");
        sb.AppendLine($"  one way only        : {BranchSitesReached - BranchSitesFullyCovered:N0}");

        if (symbols != null)
        {
            var unreachedLabels = symbols
                .Where(kv => kv.Value < Bus.RomSize && !_executed[kv.Value])
                .OrderBy(kv => kv.Value)
                .ToList();
            sb.AppendLine($"Labels never entered  : {unreachedLabels.Count:N0} / {symbols.Count:N0}");
        }
        return sb.ToString();
    }
}
