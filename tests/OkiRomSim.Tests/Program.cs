// Copyright (c) bmgjet. All rights reserved.
// Regression tests for Rom Sim Studio and RomSimTuner. A console program, no test framework:
//   dotnet run --project tests/OkiRomSim.Tests -c Release                       every group
//   dotnet run --project tests/OkiRomSim.Tests -c Release -- --only p30,emulator  the groups named (or part-named)
//   dotnet run --project tests/OkiRomSim.Tests -c Release -- --list               what the groups are
// A baseline in data/ is recorded again only when its file has been deleted and --save-images (P13 images) or --save-definitions
// (the definitions snapshot) is given, or with --save-checkpoints (the simulator runs: the ROMs run are recorded over); the recorded
// file lands in the build output's data folder, to be copied into data/.
// Groups run in this order - the P30 skeleton first (the baseline that runs on cars), then the P13 (work in progress), then the ROM
// files, the core, the assembler, definitions, datalogging, the emulator (a mock device), MCP, and the two builds. Every check prints
// PASS / FAIL / SKIP and what it saw; the exit code is the number of failures. Nothing here writes to a source file of the repository
// or to any hardware: every file a test changes is a copy in a folder of its own under the temp folder, removed afterwards.
using OkiRomSim.Tests;

var groups = new (string Name, string About, Action Run)[]
{
    ("p30", "P30 skeleton: builds, checksum, build-info table, the images and the simulation against the saved baseline", SkeletonTests.P30),
    ("p13", "P13 skeleton (work in progress): the same checks against its own saved baseline", SkeletonTests.P13),
    ("roms", "ROM files: the stock images and sources unchanged, and each source assembling to its image", RomFileTests.Run),
    ("core", "Core and simulator fixes: indirect jumps, decimal adjust, the serial backlog, snapshots, processor profiles", CoreTests.Run),
    ("assembler", "Assembler fixes: division by -1, oversized align", AssemblerTests.Run),
    ("definitions", "Definitions: every shipped source and build against the saved snapshot, bad annotations, XDF switches, feature files", DefinitionTests.Run),
    ("datalog", "Datalogging: the Demon relay's footer, detection leaving the line plain, decimal commas, frame shapes", DatalogTests.Run),
    ("emulator", "ROM emulator on a mock Ostrich (a pseudo-terminal): identify, upload, compare, slow acks, the upload interlock", EmulatorTests.Run),
    ("mcp", "MCP server: read-only refusals, cal_save, workspace escapes, batches", McpTests.Run),
    ("builds", "The two builds: what the tuner references and needs at run time, and both programs' own self-tests", BuildTests.Run),
};

if (args.Contains("--list"))
{
    foreach (var g in groups) Console.WriteLine($"{g.Name,-12} {g.About}");
    return 0;
}
var only = args.SkipWhile(a => a != "--only").Skip(1).FirstOrDefault()?.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
var started = DateTime.UtcNow;
foreach (var g in groups)
{
    if (only != null && !only.Any(o => g.Name.Contains(o, StringComparison.OrdinalIgnoreCase))) continue;
    T.Group(g.Name, g.About);
    try { g.Run(); }
    catch (Exception ex) { T.Check($"{g.Name}: the group ran to the end", false, ex.ToString()); }
}
Console.WriteLine();
Console.WriteLine($"{T.Passed} passed, {T.Failed} failed, {T.Skipped} skipped in {(DateTime.UtcNow - started).TotalSeconds:0.0} s");
foreach (var f in T.Failures) Console.WriteLine("  FAIL " + f);
Console.WriteLine(T.Failed == 0 ? "ALL PASS" : $"{T.Failed} FAILED");
return T.Failed;
