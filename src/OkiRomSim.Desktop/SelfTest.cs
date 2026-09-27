// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Desktop;

/// `OkiRomSimStudio --selftest-live <build.asm>`: the live-edit paths against a running simulator, without a window - a source change patched in without a reset, RAM held at a value, and who writes RAM. Prints PASS / FAIL, exits 0 or 1.
static class SelfTest
{
    /// `--selftest-smooth`: the datalog smoother on made-up readings - a one-frame spike dropped, a real change let through a frame later, a skipped channel left alone.
    public static int Smooth()
    {
        int bad = 0;
        void Check(bool ok, string what) { Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {what}"); if (!ok) bad++; }
        var sm = new OkiRomSim.Calibration.DatalogSmoother { Enabled = true, Frames = 3, Blend = false };
        List<double> Run(IEnumerable<double> rpms)
        {
            sm.Reset();
            return [.. rpms.Select(r => { var f = new OkiRomSim.Calibration.LogFrame { Rpm = r }; sm.Apply(f); return f.Rpm!.Value; })];
        }
        var spike = Run([6000, 6000, 6000, 28, 6000, 6000]);
        Check(spike.All(v => v == 6000), $"6000, 6000, 6000, 28, 6000, 6000 -> {string.Join(", ", spike)}");
        var step = Run([3000, 3000, 3000, 6000, 6000, 6000]);
        Check(step[3] == 3000 && step[4] == 6000 && step[5] == 6000, $"a real step 3000 -> 6000 gets through a frame later: {string.Join(", ", step)}");
        var up = Run([2000, 2200, 2400, 2600, 2800, 3000]);
        Check(up.SequenceEqual([2000, 2200, 2400, 2600, 2800, 3000]), $"a steady climb is left alone: {string.Join(", ", up)}");
        sm.Blend = true;
        var blend = Run([6000, 6100, 5900, 28, 6000]);
        Check(Math.Abs(blend[3] - 6000) < 1 && Math.Abs(blend[4] - 5950) < 1, $"blended, the spike is left out of the average: {string.Join(", ", blend.Select(v => v.ToString("0.#")))}");
        sm.Reset();
        var o2 = new OkiRomSim.Calibration.LogFrame();
        foreach (var v in new[] { 0.1, 0.9, 0.1, 0.9 }) { o2 = new() { O2V = v }; sm.Apply(o2); }
        Check(o2.O2V == 0.9, "the narrowband O2 is left as it comes");
        sm.Enabled = false;
        var off = Run([6000, 6000, 28]);
        Check(off[2] == 28, "switched off, nothing changes");
        return bad == 0 ? 0 : 1;
    }

    /// `--selftest-project <build.asm>`: the machine saved to a project file and read back into a fresh simulator must carry on exactly as the original does - same instructions, same RAM, same outputs - or something it depends on was not saved.
    public static int Project(string path)
    {
        int bad = 0;
        void Check(bool ok, string what) { Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {what}"); if (!ok) bad++; }
        var a = new SimHost();
        Check(a.Build(path).Success, $"build {Path.GetFileName(path)}");
        a.SetInput("rpm", 2500); a.SetInput("map", 55); a.SetInput("ect", 85); a.SetInput("tps", 12);
        a.Control("run");
        Thread.Sleep(6000);
        a.Control("pause");
        a.HoldRam(0x1F0, [0x5A]);
        a.AddBreakpoint("7FF0");
        a.SetBreakpointEnabled(0x7FF0, false);
        var (st, ram, rom) = a.SaveState();
        var zip = Path.Combine(Path.GetTempPath(), "okirom-selftest.project.zip");
        ProjectFile.Save(zip, new ProjectData { Machine = st, Ram = ram, Rom = rom });
        var p = ProjectFile.Load(zip);
        var b = new SimHost();
        b.Build(path);
        b.RestoreState(p.Machine!, p.Ram, p.Rom);
        Check(b.IsHeld(0x1F0) && b.ReadMemory(0x1F0, 1)[0] == 0x5A, "a held RAM byte is still held at its value");
        var bps = b.State().Breakpoints;
        Check(bps.Any(x => x.Address == 0x7FF0 && !x.Enabled), "a disabled breakpoint is kept, still disabled");
        string Diff()
        {
            var sa = a.State(); var sb = b.State();
            var ra = a.ReadMemory(0, 0x1000); var rb = b.ReadMemory(0, 0x1000);
            int first = Enumerable.Range(0, ra.Length).FirstOrDefault(i => ra[i] != rb[i], -1);
            var diffs = new List<string>();
            if (sa.Pc != sb.Pc) diffs.Add($"PC {sa.Pc:X4}/{sb.Pc:X4}");
            if (sa.Instructions != sb.Instructions) diffs.Add($"instructions {sa.Instructions}/{sb.Instructions}");
            if (Math.Abs(sa.SimSeconds - sb.SimSeconds) > 1e-9) diffs.Add($"time {sa.SimSeconds}/{sb.SimSeconds}");
            if (first >= 0) diffs.Add($"RAM from {first:X3}h ({ra[first]:X2}/{rb[first]:X2}), {Enumerable.Range(0, ra.Length).Count(i => ra[i] != rb[i])} bytes");
            if (sa.Outputs.FuelPump != sb.Outputs.FuelPump || sa.Outputs.Vtec != sb.Outputs.Vtec) diffs.Add("outputs");
            if (string.Join(",", sa.Ports) != string.Join(",", sb.Ports)) diffs.Add($"ports {string.Join(",", sa.Ports)} / {string.Join(",", sb.Ports)}");
            return string.Join("; ", diffs);
        }
        var d0 = Diff();
        Check(d0.Length == 0, "read back, the machine is the same" + (d0.Length > 0 ? ": " + d0 : ""));
        foreach (int n in new[] { 1000, 20000, 200000, 1000000 })
        {
            a.Control("step", n); b.Control("step", n);
            var d = Diff();
            Check(d.Length == 0, $"after {n:N0} more instructions each, still the same" + (d.Length > 0 ? ": " + d : ""));
            if (d.Length > 0) break;
        }
        return bad == 0 ? 0 : 1;
    }

    public static int Live(string path)
    {
        int bad = 0;
        void Check(bool ok, string what) { Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {what}"); if (!ok) bad++; }
        var host = new SimHost();
        var b = host.Build(path);
        Check(b.Success, $"build {Path.GetFileName(path)}");
        if (!b.Success) return 1;
        host.SetInput("rpm", 1500); host.SetInput("map", 40); host.SetInput("ect", 85);
        host.Control("run");
        Thread.Sleep(12000);   // long enough for the ROM sum to get going
        var st = host.State();
        Console.WriteLine($"  running {st.Running}, {st.StopReason}, {st.SimSeconds:0.0} s simulated, PC {st.Pc:X4} {st.Label}");
        // the background ROM sum walks through every table: it must not light them up in the live trace
        var sweeps = Enumerable.Range(0, 0x10000).Where(i => host.Sim.Bus.SweepPc[i]).ToList();
        Check(sweeps.Count > 0 && host.Sim.Bus.SweepReads > 0, $"ROM sum recognised as a sweep ({string.Join(", ", sweeps.Select(i => host.Where((ushort)i)))}; {host.Sim.Bus.SweepReads} reads left out)");
        var defs = host.Defs().Items.Where(i => i.Count > 32).ToList();   // (the crank tooth patterns are read whole every turn)
        int lit = defs.Count(d => host.TableHeat(d, 2.0).Count >= d.Count * 0.9);
        Check(lit == 0, $"no map fully lit by the sweep ({lit} of {defs.Count}: {string.Join(", ", defs.Where(d => host.TableHeat(d, 2.0).Count >= d.Count * 0.9).Select(d => $"{d.Name} {d.Count} @{d.CellAddress(0):X4}"))})");
        // who writes the crank period
        var (pcs, writes) = host.RamWriters(0xAC);
        Check(writes > 0 && pcs.Length > 0, $"0ACh written {writes} times, last by {(pcs.Length > 0 ? host.Where(pcs[0]) : "-")}");
        // a byte held against the ROM's writes
        byte was = host.ReadMemory(0xAC, 1)[0];
        host.HoldRam(0xAC, [0x33]);
        Thread.Sleep(300);
        byte heldNow = host.ReadMemory(0xAC, 1)[0];
        host.HoldRam(0xAC, null);
        Thread.Sleep(300);
        Check(heldNow == 0x33 && host.RamWriters(0xAC).Writes > writes, $"0ACh held at 33h while the ROM kept writing it (was {was:X2}, held {heldNow:X2})");
        // the source changed and patched in: no reset, the new byte in the running ROM
        var skeleton = Directory.GetFiles(Path.GetDirectoryName(Path.GetFullPath(path))!, "*-skeleton.asm").FirstOrDefault();
        if (skeleton == null) { Check(false, "no skeleton beside the build file"); return 1; }
        var text = File.ReadAllText(skeleton);
        const string from = "RomSumCheck:       DB  0FFh", to = "RomSumCheck:       DB  0FEh";
        Check(text.Contains(from), "the skeleton has the RomSumCheck byte to change");
        var changed = text.Replace(from, to);
        long at = host.Assembly!.Symbols.Values.First(s => s.Name.Equals("RomSumCheck", StringComparison.OrdinalIgnoreCase)).Value;
        ulong before = host.Sim.Cpu.Cycles;
        string? Read(string f) => Path.GetFullPath(f).Equals(Path.GetFullPath(skeleton), StringComparison.OrdinalIgnoreCase) ? changed : null;
        var p = host.PatchBuild(path, Read, force: false);
        Thread.Sleep(500);
        byte now = host.ReadMemory((int)at, 1)[0];
        Check(p.Success && p.Bytes == 1 && now == 0xFE && host.Sim.Cpu.Cycles > before && host.IsRunning,
            $"patched live: {p.Note}; {at:X4} now {now:X2}; still running from where it was ({before} -> {host.Sim.Cpu.Cycles} cycles)");
        Check(OkiRomSim.Calibration.RomChecksum.Sum([.. host.Sim.Bus.Rom]) == 0, "the checksum balanced after the patch");
        var again = host.PatchBuild(path, Read, force: false);
        Check(again.Success && again.Bytes == 0, "patching the same source again: nothing to do");
        host.Control("pause");
        return bad == 0 ? 0 : 1;
    }
}
