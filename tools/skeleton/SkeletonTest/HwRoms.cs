// --hwroms <count> <seed> <folder>: random combinations of modules for the real ECU. Each is the four defaults (stock trouble
// codes and self-tests, datalogging, coolant protection - the base every ROM that ran on the car had), now and then a stock
// function or two, and a random handful of modules - the ones not yet in an earlier ROM first, so the set covers every module.
// A combination is kept only when it builds, passes the hardware checks (watchdog, heartbeat, no trap, from zeroed RAM and
// from RAM full of rubbish), runs hard in the simulator with every module on (no fault, reset, wrong-mode instruction or
// stack overflow) and keeps the rpm reading at 7000 rpm. Each ROM is written as built (every module off until switched on
// in the app) with a README of what to switch on and what to look for on the car.
using OkiRomSim.Calibration;
using OkiRomSim.Core;

static class HwRoms
{
    /// What to switch on (its page in the app) and what to look for on the car, per module.
    static readonly Dictionary<string, string> Check = new()
    {
        ["FEAT_DATALOG"] = "Datalog over the cable (Datalogging > Connect): frames come in, values move with the engine.",
        ["FEAT_DLSTREAM"] = "Pick channels (Datalogging > Channels...) and log: about 15+ frames a second, rpm and MAP smooth.",
        ["FEAT_DLQD3"] = "A QD3-style logger reads the frame (Datalogging, protocol QD3).",
        ["FEAT_DLSERIALIN"] = "Send a serial input (Settings > Emulator & datalog: serial inputs) and see it in the log.",
        ["FEAT_DLMEMREAD"] = "Codes and service > ECU memory: Read shows RAM that changes with the engine.",
        ["FEAT_DLEXTRA"] = "Datalogging > Channels: the extra channels can be picked and log.",
        ["FEAT_DLSERVICE"] = "Codes and service: Injectors off stops the engine, Lock timing holds the timing light still.",
        ["FEAT_REMOTE"] = "Serial port page: tick Take the remote control commands. Codes and service: fan on/off, a 3000 rpm rev limit (it holds at 3000), Clear.",
        ["FEAT_SHIFTLIGHT"] = "Shift light page: on, 3000 rpm. The check-engine lamp lights from 3000 rpm in neutral.",
        ["FEAT_WBCL"] = "Closed loop page (needs a wideband on the chosen input): on; the logged trim moves the AFR to the target.",
        ["FEAT_FLEX"] = "Flex fuel page (needs the sensor): on; the logged ethanol % reads the fuel in the tank.",
        ["FEAT_FUELTRIM"] = "Injectors page: a +5 % trim; the logged injector time goes up about 5 %.",
        ["FEAT_GEARFUEL"] = "Fuel by gear (needs gear detection right): +5 % in 2nd; the logged injector time rises in 2nd only.",
        ["FEAT_MAPSWITCH"] = "Secondary tune page: on, a switch input; fuel / timing change when the switch is on.",
        ["FEAT_EXTMAPS"] = "Nothing to switch on: the fuel and ignition maps have 20 load columns. Idles and drives as the tune says.",
        ["FEAT_DUALMAPS"] = "Secondary maps page: on, a switch input; the second maps are used while it is on.",
        ["FEAT_CYLTRIM"] = "Cylinder trims page: a trim on one cylinder; that injector's time changes (log or scope).",
        ["FEAT_ALPHAN"] = "Maps indexing page: alpha-N; idles and revs on the throttle position (check the log's load).",
        ["FEAT_ANTISTALL"] = "Anti-stall page: on; let the clutch out slowly from idle - the rpm is held up.",
        ["FEAT_ROLLIDLE"] = "Rolling idle page: on, 1 in 9, injector; a lumpy idle when warm, normal off idle.",
        ["FEAT_GEARIGN"] = "Timing by gear: -2 degrees in 2nd; the logged timing drops in 2nd only.",
        ["FEAT_TPSRETARD"] = "Tip-in retard page: on; a quick stab of the throttle pulls timing for a moment (log).",
        ["FEAT_TRACTION"] = "Traction control page: on; wheelspin in 1st pulls timing (log). Try somewhere safe.",
        ["FEAT_REVLIMIT"] = "Rev limits page: on, low cam cut at 4000 rpm, fuel cut; free-revving it holds at 4000.",
        ["FEAT_LAUNCH"] = "Launch control page: on, 3500 rpm, an input you can hold; standing still with the input on, it holds 3500.",
        ["FEAT_FTS"] = "Full throttle shift page: on, the clutch input; clutch in at full throttle holds the set rpm.",
        ["FEAT_BURNOUT"] = "Burnout page: on, an input, 3000 rpm; standing with the input on, it holds 3000.",
        ["FEAT_SPEEDLIMIT"] = "Rev limits page, speed limiter: on, 40 km/h, Always on; the car will not go past 40.",
        ["FEAT_CEILING"] = "Rev limits page, rpm ceilings: on, 4000 rpm below 10 km/h; standing, it holds 4000.",
        ["FEAT_GEARLIMIT"] = "Rev limits page, limit by gear: on, 4000 in 1st; in 1st it holds 4000.",
        ["FEAT_IGNCUTMOD"] = "Rev limits page, ignition cut shaping: on, with the rev limiter on ignition cut; the limiter crackles.",
        ["FEAT_WATERMARK"] = "Nothing to switch on: the ROM carries its watermark (Tools > ROM info).",
        ["FEAT_CFGOVERRIDE"] = "Board options page: leave all off first (runs as before), then force one you know (e.g. closed loop off).",
        ["FEAT_IAB"] = "IAB page: on, an output, 5000 rpm; the output switches at 5000 (test light).",
        ["FEAT_RPMSWITCH"] = "Rpm switch page: on, an output, 3000 rpm; the output switches at 3000 (test light).",
        ["FEAT_WARNLAMP"] = "Warning lamp page: on, a coolant point a little over normal; the lamp lights when hot.",
        ["FEAT_GIO1"] = "General purpose output 1: on, an output, 3000 rpm; switches at 3000 (test light).",
        ["FEAT_GIO2"] = "General purpose output 2: as GIO 1, another output.",
        ["FEAT_GIO3"] = "General purpose output 3: as GIO 1, another output.",
        ["FEAT_GIO4"] = "General purpose output 4: as GIO 1, another output.",
        ["FEAT_VTECCTL"] = "VTEC page: use these engage points, 4500 rpm; VTEC engages at 4500 (log / sound).",
        ["FEAT_TACH"] = "Tachometer output page: on, an output; a tach on it reads the engine's rpm.",
        ["FEAT_SMARTALT"] = "Smart alternator page: on; at full throttle the charge voltage drops, back after.",
        ["FEAT_ACCUT"] = "A/C cut page: on, 5000 rpm; A/C on, the clutch drops out above 5000 and at full throttle.",
        ["FEAT_ECTPRO"] = "Nothing to switch on (on by default): the coolant protection page's limits only act when hot.",
        ["FEAT_ANTISTART"] = "Anti-start page: on, a switch; it will not start until the switch (and throttle) unlock it. Have the switch ready.",
        ["FEAT_LEANPRO"] = "Lean protection page (needs a wideband): on; a lean AFR at load cuts. Check the log rather than trying it.",
        ["FEAT_SENSORPRO"] = "Sensor protection page (needs a sender on an analog input): on, the input, a level; the reading past the level above the rpm cuts. Check the log rather than trying it.",
        ["FEAT_GEAR"] = "Gear detection page: set the ratios (or learn them); the logged gear matches the gear you are in.",
        ["FEAT_TPSCAL"] = "TPS sensor page: use these end points, set from the log; the logged throttle reads 0 and 100 %.",
        ["FEAT_SPEEDCORR"] = "Road speed correction: a few %; the logged speed matches a GPS.",
        ["FEAT_BOOSTCUT"] = "Boost cut page (turbo cars): on, a point a little over the boost you run; nothing changes until it is reached.",
        ["FEAT_EBC"] = "Boost control page (turbo, solenoid on P4.3): on, low duty; the boost rises with the duty.",
        ["FEAT_BOOSTMANUAL"] = "Manual boost page (turbo, solenoid): on, low duty; the boost rises with the duty.",
        ["FEAT_WMI"] = "Water / methanol page (pump on an output): on, a point; the pump runs over it (test light).",
    };

    public static int Run(Skeleton sk, int count, int seed, string outDir)
    {
        Directory.CreateDirectory(outDir);
        var rnd = new Random(seed);
        string[] def4 = ["FEAT_STOCK_DTC", "FEAT_STOCK_SELFTEST", "FEAT_DATALOG", "FEAT_ECTPRO"];
        string[] stockExtras = ["FEAT_STOCK_O2", "FEAT_STOCK_O2HEATER", "FEAT_STOCK_AC", "FEAT_STOCK_VTECPRESSURE", "FEAT_STOCK_KNOCK", "FEAT_STOCK_PURGE", "FEAT_STOCK_SPEEDLIMIT", "FEAT_STOCK_HICAMVE"];
        var modules = sk.Features.Where(f => !f.Stock && !def4.Contains(f.Define)).Select(f => f.Define).ToList();
        var covered = new HashSet<string>();
        var baseline = ModeCheck.Baseline(sk);
        var index = new List<string>
        {
            "Ten ROMs for the car, each a random mix of modules (every module is in at least one). Built and checked in the",
            "simulator: they boot from zeroed RAM and from RAM full of rubbish, the watchdog and heartbeat keep time, and driven",
            "hard with every module switched on nothing faults, resets, overflows the stack or loses the rpm reading.",
            "",
            "Every ROM is as built: its modules are OFF until switched on in the app (open the .asm build file or the .bin, the",
            "pages are under each function). Flash one, then:",
            "  1. Start it with everything off: it should start, idle and drive like the base tune.",
            "  2. Switch on the functions listed for it, one at a time, and look for what each line says.",
            "  3. Note: boots and idles / does not start / resets / runs but something is wrong (and what, and when).",
            "",
        };
        int made = 0, tries = 0;
        while (made < count && tries < 400)
        {
            tries++;
            var defs = new List<string>(def4);
            if (rnd.NextDouble() < 0.5) defs.AddRange(stockExtras.OrderBy(_ => rnd.Next()).Take(rnd.Next(1, 4)));
            // modules not covered yet first, then any; 5-12 of them
            int want = rnd.Next(5, 13);
            var pool = modules.Where(m => !covered.Contains(m)).OrderBy(_ => rnd.Next()).Concat(modules.Where(covered.Contains).OrderBy(_ => rnd.Next())).ToList();
            foreach (var m in pool)
            {
                if (defs.Count(d => !d.StartsWith("FEAT_STOCK") && !def4.Contains(d)) >= want) break;
                var f = sk.Feature(m)!;
                List<string> next = [.. defs.Concat(f.Requires).Append(m).Distinct()];
                if (sk.Problems(next).Count == 0) defs = next;
            }
            var b = sk.Build(defs);
            if (b.Assembly is not { Success: true } asm) continue;
            var img = (byte[])asm.Image.Clone();
            var z0 = HwCheck.Run("candidate", (byte[])img.Clone(), asm, null);
            var z1 = HwCheck.Run("candidate", (byte[])img.Clone(), asm, 4321 + tries);
            if (z0.Traps.Count > 0 || z1.Traps.Count > 0 || z0.Faulted || z1.Faulted) { Console.WriteLine($"  rejected (traps): {string.Join(" ", defs)}"); continue; }
            var (problems, summary) = ModeCheck.One(asm, baseline);
            if (problems.Count > 0) { Console.WriteLine($"  rejected ({problems[0]}): {string.Join(" ", defs)}"); continue; }
            var built = IsrTiming.Measure(asm, allOn: false);
            var on = IsrTiming.Measure(asm, allOn: true);
            if (built == null || on == null || built.LostTeeth > 0 || on.LostTeeth > 0 || built.Resets > 0 || on.Resets > 0) { Console.WriteLine($"  rejected (rpm reading lost, or the ECU reset itself, at high rpm): {string.Join(" ", defs)}"); continue; }
            made++;
            foreach (var d in defs) covered.Add(d);
            string file = $"ROM{made:00}";
            File.WriteAllBytes(Path.Combine(outDir, file + ".bin"), img);
            // the build file: open it in the app to switch the functions on (it builds the same ROM)
            File.WriteAllText(Path.Combine(outDir, file + ".asm"), sk.BuildSource(defs, sk.Path, file));
            int sum = 0; foreach (var x in img) sum += x;
            var mods = defs.Where(d => !d.StartsWith("FEAT_STOCK")).ToList();
            var line = $"{file}.bin  {b.FreeBytes} bytes free  module RAM {b.Ram?.Used}/{b.Ram?.Size} B  checksum {((sum & 0xFF) == 0 ? "ok" : "BAD")}  " +
                       $"tick {built.TickWorstUs:0} us ({on.TickWorstUs:0} us all on)  interrupts {on.CpuPercent:0} % of the CPU all on";
            Console.WriteLine(line + "\n    " + string.Join(" ", defs));
            index.Add(line);
            var stockIn = defs.Where(d => d.StartsWith("FEAT_STOCK")).Select(d => sk.Feature(d)?.Name ?? d).ToList();
            index.Add("    stock functions: " + string.Join(", ", stockIn));
            index.Add($"    {mods.Count} modules - switch on and check:");
            foreach (var m in mods) index.Add($"      - {sk.Feature(m)?.Name ?? m}: {Check.GetValueOrDefault(m, "(no check written)")}");
            index.Add("");
        }
        var missing = modules.Where(m => !covered.Contains(m)).ToList();
        if (missing.Count > 0) index.Add("Not in any of these: " + string.Join(", ", missing.Select(m => sk.Feature(m)?.Name ?? m)));
        File.WriteAllLines(Path.Combine(outDir, "README.txt"), index);
        Console.WriteLine($"wrote {made} of {count} to {outDir} ({tries} tried){(missing.Count > 0 ? "; not covered: " + string.Join(" ", missing) : "; every module is in one")}");
        return made == count ? 0 : 1;
    }
}
