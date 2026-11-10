<?php declare(strict_types=1);

/* ---- Updates for the apps (Settings > Updates in Rom Sim Studio and in RomSimTuner) ----------------------------
 * Each program has its own folder: Rom Sim Studio's under files/, RomSimTuner's under files-tuner/ (asked for with
 * &product=tuner on both requests below). build-release.bat fills both when it stages the site in dist\website.
 * index.php?updates      every file under files/ as JSON: its path, size, SHA-256, when it last changed, a version number
 *                        of its own, and (for a .dll / .exe) the file version built into it.
 * index.php?file=<path>  one of those files.
 * Nothing here is edited by hand: drop the new build and templates into files/ and the list follows. A file's version
 * goes up by one each time its contents change; that is remembered in files/.versions.json when the folder can be
 * written to (otherwise the version is the date it changed). Dot-files are never listed or served. */
define('UPDATE_TUNER', 'tuner' === ($_GET['product'] ?? ''));
const UPDATE_DIR = __DIR__ . (UPDATE_TUNER ? '/files-tuner' : '/files');
const UPDATE_STATE = UPDATE_DIR . '/.versions.json';
const UPDATE_PRODUCT = UPDATE_TUNER ? 'RomSimTuner' : 'RomSimStudio';
const UPDATE_TEXT = ['asm', 'inc', 'md', 'txt', 'json', 'xdf', 'csv', 'ini', 'cfg'];

/** The file version a Windows executable carries (VS_FIXEDFILEINFO), or null. */
function update_pe_version(string $path): ?string
{
    $data = @file_get_contents($path);
    if ($data === false) return null;
    $at = strrpos($data, "\xBD\x04\xEF\xFE");
    if ($at === false || $at + 16 > strlen($data)) return null;
    $v = unpack('Vsig/Vstruc/Vms/Vls', substr($data, $at, 16));
    return sprintf('%d.%d.%d.%d', $v['ms'] >> 16, $v['ms'] & 0xFFFF, $v['ls'] >> 16, $v['ls'] & 0xFFFF);
}

/** Every file under files/ (not dot-files), path relative to it with forward slashes. */
function update_files(): array
{
    $out = [];
    if (!is_dir(UPDATE_DIR)) return $out;
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator(UPDATE_DIR, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $f) {
        if (!$f->isFile()) continue;
        $rel = str_replace('\\', '/', substr($f->getPathname(), strlen(UPDATE_DIR) + 1));
        if (preg_match('#(^|/)\.#', $rel)) continue;
        $out[$rel] = $f->getPathname();
    }
    ksort($out, SORT_STRING | SORT_FLAG_CASE);
    return $out;
}

/** The manifest, with the remembered versions brought up to date. */
function update_manifest(): array
{
    $state = is_file(UPDATE_STATE) ? (json_decode((string)file_get_contents(UPDATE_STATE), true) ?: []) : [];
    $changed = false;
    $files = [];
    foreach (update_files() as $rel => $full) {
        $size = filesize($full);
        $mtime = filemtime($full);
        $s = $state[$rel] ?? null;
        // hashed again only when the size or the date says it may have changed
        if ($s === null || $s['size'] !== $size || $s['mtime'] !== $mtime) {
            $hash = hash_file('sha256', $full);
            if ($s === null || $s['sha256'] !== $hash) {
                $s = ['version' => ($s['version'] ?? 0) + 1, 'sha256' => $hash, 'changed' => gmdate('Y-m-d\TH:i:s\Z', $mtime)];
            }
            $s['size'] = $size;
            $s['mtime'] = $mtime;
            $ext = strtolower(pathinfo($rel, PATHINFO_EXTENSION));
            $s['fileVersion'] = in_array($ext, ['dll', 'exe'], true) ? update_pe_version($full) : null;
            $state[$rel] = $s;
            $changed = true;
        }
        $ext = strtolower(pathinfo($rel, PATHINFO_EXTENSION));
        $files[] = [
            'path' => $rel, 'size' => $s['size'], 'sha256' => $s['sha256'], 'version' => $s['version'],
            'changed' => $s['changed'], 'fileVersion' => $s['fileVersion'], 'text' => in_array($ext, UPDATE_TEXT, true),
        ];
    }
    // files taken away are forgotten
    foreach (array_keys($state) as $rel) if (!in_array($rel, array_column($files, 'path'), true)) { unset($state[$rel]); $changed = true; }
    if ($changed && is_writable(UPDATE_DIR)) @file_put_contents(UPDATE_STATE, json_encode($state, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), LOCK_EX);
    return ['product' => UPDATE_PRODUCT, 'generated' => gmdate('Y-m-d\TH:i:s\Z'), 'files' => $files];
}

if (isset($_GET['updates'])) {
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode(update_manifest(), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}

if (isset($_GET['file'])) {
    $rel = str_replace('\\', '/', (string)$_GET['file']);
    $files = update_files();
    // only a path that is in the list: nothing outside files/, no dot-files
    if (!isset($files[$rel])) { http_response_code(404); header('Content-Type: text/plain'); echo 'no such file'; exit; }
    $full = $files[$rel];
    header('Content-Type: application/octet-stream');
    header('Content-Length: ' . filesize($full));
    header('Content-Disposition: attachment; filename="' . basename($rel) . '"');
    header('Cache-Control: no-store');
    readfile($full);
    exit;
}
/**
 * ORSS — Rom Sim Studio. MSM66207/MSM66911 simulator, assembler, calibration, datalog and MCP
 * toolchain for OBD1 Honda ECUs. Single-file landing page. PHP 8+.
 * Content audited against the D:\OkiRomSim repo: README, test-suite output, and the project's
 * own TableDetector run over roms/HTS115.asm.
 */
$project   = 'ORSS';
$product   = 'Rom Sim Studio';
$studio    = 'RomSimStudio';
$chip      = 'MSM66207';
$tagline   = 'Tune it. Or build your own.';
$zip       = 'romsimstudio.zip';
$zipPath   = __DIR__ . '/' . $zip;
$zipSize   = is_file($zipPath) ? number_format(filesize($zipPath) / 1048576, 1) . ' MB' : null;
$tunerZip  = 'romsimtuner.zip';   // RomSimTuner, the tuning-only build
$tunerZipPath = __DIR__ . '/' . $tunerZip;
$tunerZipSize = is_file($tunerZipPath) ? number_format(filesize($tunerZipPath) / 1048576, 1) . ' MB' : null;
$buildHash = strtoupper(substr(md5(date('Ymd').getmypid().random_int(1,9999)), 0, 8));
$year      = date('Y');
$version   = '0.0.0.8';   // the build reports it everywhere: title bar, Settings, Debug page, MCP handshake
$previous  = '0.0.0.7';   // the changelog below is what changed from that to this
$releaseSub = 'sensor protection for oil and fuel pressure, a warm-up rev limit, boost by gear, and the stock P13 as a Detect reference';

/* The pictures of the program, in docs/img (taken by the app itself: RomSimStudio --ui-check), the size they were
   taken at, and the views the slideshow under the screenshots runs through. */
$shotW = 1936; $shotH = 1056;
$views = [
  ['simulator.png',       'Simulator mode',        'the source running, the chip and engine inputs on the left, the CPU and disassembly on the right'],
  ['tuner.png',           'Tuner mode',            'the maps and settings fill the window, the datalog and its gauges beside them'],
  ['tuner-replay.png',    'A log over the map',    'the four cells the engine reads lit, with a fading trail behind, exactly as the ECU interpolates them'],
  ['new-rom-create.png',  'New ROM > Create',      'pick the functions; the ROM space and module RAM bars, the safety checklist and the warnings below'],
  ['memory.png',          'Memory map',            'every RAM byte named and scaled, with the instruction that last wrote it'],
  ['lookup.png',          'Lookup & breakpoints',  'what a name is, every instruction that touches it, and the breakpoints, on and off'],
  ['datalog-graph.png',   'Datalog graph',         'any channels against time, each on its own scale, with a cursor that reads them all'],
  ['codes-service.png',   'Codes and service',     'stored codes, clear them, injectors off, timing locked, maps chosen - with big buttons'],
  ['import-maps.png',     'Import maps',           'a tune from another ROM family, paired by job and resampled onto these axes'],
  ['check-engine.png',    'Check-engine lamp',     'the flashes decoded as the ROM drives them, the stored codes and the faults it sees now'],
  ['touch.png',           'Touch mode',            'big targets and one-tap actions for a tablet or a touch screen in the car'],
  ['settings.png',        'Settings',              'every part of the program, one page each'],
];

$gallery = [
  'The main window, page by page' => [
    ['page-problems.png',     'Problems',            'build errors, warnings and the safety checks in one list'],
    ['page-trace.png',        'Trace',               'every instruction the ROM runs, live'],
    ['memory.png',            'Memory',              'the hex and the named RAM map'],
    ['page-calibration.png',  'Calibration',         'the maps and settings, as tables in real units'],
    ['lookup.png',            'Lookup and breakpoints', 'what a name is, and everywhere it is used'],
    ['page-datalog.png',      'Datalog',             'connect, record, replay, and watch the gauges'],
    ['page-debug.png',        'Debug',               'the processor, its timers and the engine model'],
  ],
  'Tuner mode' => [
    ['tuner.png',              'Tuner mode',         'maps and settings fill the window'],
    ['tuner-replay.png',       'A log over the map', 'the cells the engine reads, lit, with a trail'],
    ['page-tuner-definition.png', 'Definition view', 'the map, its formula and its axes'],
    ['touch.png',              'Touch mode',         'big targets for a tablet in the car'],
    ['line-view.png',          'Line view',          'a map as one curve per rpm row, with a cursor that reads the value'],
    ['o2-knock-tables.png',    'O2 and knock tables','what the datalog says about each cell'],
    ['datalog-graph.png',      'Datalog graph',      'any channels against time'],
  ],
  'Tools and windows' => [
    ['welcome.png',            'First start',        'tuning and datalogging, or ROM development'],
    ['new-rom.png',            'New ROM',            'start from a template, the skeleton or an existing ROM'],
    ['new-rom-create.png',     'New ROM: create',    'pick the functions; ROM and RAM bars, checklist and warnings'],
    ['compare.png',            'Compare ROMs',       'two ROMs side by side, every difference named'],
    ['import-maps.png',        'Import maps',        'a tune from another ROM, paired by job and resampled'],
    ['scale.png',              'Scale',              'move a whole map when the hardware changes'],
    ['scale-injectors.png',    'Scale: injectors',   'new injector size and latency'],
    ['scale-map-sensor.png',   'Scale: MAP sensor',  'a bigger sensor, the tables follow'],
    ['scale-headroom.png',     'Scale: headroom',    'how far the values can still go'],
    ['map-sensor.png',         'MAP sensor',         'fit a bigger sensor and the load axes are re-read to match'],
    ['injectors.png',          'Injector set-up',    'size, flow and latency'],
    ['codes-service.png',      'Codes and service',  'stored codes, injectors off, timing locked'],
    ['check-engine.png',       'Check-engine lamp',  'the flashes decoded, the codes and live faults'],
    ['demon.png',              'Emulator onboard',   'upload to an Ostrich or Demon, change a cell live'],
    ['trigger-pattern.png',    'Trigger pattern',    'the crank, TDC and cylinder signals as bars: a missed tooth stands out'],
    ['dyno.png',               'Virtual dyno',       'power and torque from a datalog, runs overlaid'],
    ['gauge-editor.png',       'Gauge editor',       'channels, ranges and warning colours'],
    ['updates.png',            'Updates',            'new versions and templates from this site'],
  ],
  'Settings' => [
    ['settings-emulator-datalog.png', 'Emulator and datalog', 'ports, speeds and protocols'],
    ['settings-processor.png', 'Processor',          'the chip the ROM runs on'],
    ['settings-targets.png',   'Targets',            'the air-fuel targets the corrections aim for'],
    ['settings-corrections.png','Corrections',       'how far the datalog may move the maps'],
    ['settings-colours.png',   'Colours',            'cell and gauge colours'],
    ['settings-hot-keys.png',  'Hot keys',           'every shortcut, changeable'],
    ['settings-panel-zoom.png','Panel zoom',         'make any panel bigger or smaller'],
    ['settings-plugins.png',   'Plugins',            'add-ons the program can load'],
    ['settings-mcp-server.png','MCP server',         'let an AI assistant use the program'],
    ['settings-updates.png',   'Updates',            'new versions from this site'],
    ['settings-about.png',     'About',              'version, licence and the Discord link'],
  ],
];

$components = [
  ['OkiRomSim.Core',        'Decoder, chip facts and the ProcessorProfile: MSM66207/P28 measured, MSM66911/P13 &mdash; a ROM for either part <i>runs</i>, not just disassembles. 10 MHz crystal, cycles at fOSC/4, timers /8.'],
  ['OkiRomSim.Sim',         'CPU, bus, on-chip peripherals for each part, the engine model and the simulator, trouble codes and the check-engine lamp, drive cycles and saved machine state.'],
  ['OkiRomSim.Assembler',   'Managed asm662-compatible assembler: embeds asm662\'s own instrs.y, 2,616 productions, plus modern extensions and a source map.'],
  ['OkiRomSim.Calibration', 'Definitions, TableDetector (maps found by reading the code) and TableShapes (1-D tables read from the routine that walks them), feature pages bound by slot, feature patches that expect their bytes, ROM matching against a known source, map import, the RAM map, datalog protocols and channels, checksum, password, watermark, overlays, TunerPro XDF export.'],
  ['OkiRomSim.Cli',         'okisim on the command line: asm, run, disasm, symbols, defs, get, set, xref, formulas, features.'],
  ['OkiRomSim.Desktop',     'RomSimStudio &mdash; the Avalonia IDE: editor, debugger, memory map, calibration, datalogger, hit trace, compare, tuner mode, the New ROM module builder, plugins and the updater. Windows, Linux, macOS.'],
  ['OkiRomSim.Tuner',       'RomSimTuner &mdash; the tuning-only build: the calibration editor, datalogger and ROM emulator from the same source files as RomSimStudio, with its own settings and updater, and no simulator, MCP server or plugins.'],
  ['OkiRomSim.Mcp',         'The MCP server. 47 tools so an LLM agent can assemble, run, explore, calibrate, datalog, annotate and compare &mdash; stdio or HTTPS, for the P30 family and the P13 alike.'],
  ['src/Plugins',            'Plugins for the desktop app, and the plugin API it hosts: menus, tabs, pages, settings, and frames fed straight into the datalog page. ScanTool (ELM327) ships as the worked example.'],
  ['roms/',                  'The ROM sources the toolchain is built around: HTS115, HTS120, P30, P08, P13 and P72-269 as labelled assembly, and two skeletons with their hook tables and info blocks &mdash; the P30 one and the P13 one &mdash; each with 57 feature modules and 13 stock functions.'],
];

$bugs = [
  ['enc'=>'xx D0 nn nn','was'=>'OR &lt;dst&gt;, #N16','is'=>'AND &lt;dst&gt;, #N16',
   'note'=>'D0 is AND; OR is E0. Every interrupt-mask written as "AND IE, #xxxxh" executed as an OR &mdash; <b>enabling</b> the very interrupts the ROM was trying to disable.'],
  ['enc'=>'L / LB / LC / LCB','was'=>'flags untouched','is'=>'Z flag set by the load',
   'note'=>'Every LB A,x / JEQ pair with no compare in between branched on a stale flag. ~230 such pairs in HTS115.'],
  ['enc'=>'xx 13','was'=>'TBR','is'=>'TRB',
   'note'=>'Disassembler spelling only. Meanwhile the interrupt model was rebuilt from ROM behaviour: one instruction always runs after RTI, all timers share one prescaler.'],
];
/* The real 20x10 maps of roms/HTS115.asm, found by the project's own TableDetector
   (code-following, no fixed addresses) and pulled verbatim from the assembled image.
   rows = RPM breakpoints, cols = load in mbar. Scaling: fuel raw*multiplier/4 ms,
   ignition raw*0.25-6 deg BTDC, VE raw*100/128-100 % - the formulas HTS itself uses. */
$maps = [
  ['name'=>'FUEL1_Lo', 'addr'=>'0x6EAD', 'formula'=>'honda_fuel', 'cat'=>'Fuel', 'unit'=>'ms', 'dec'=>2,
   'rows'=>[525.0, 600.0, 700.0, 825.0, 1000.0, 1300.0, 1500.0, 1750.0, 2000.0, 2250.0, 2575.0, 3075.0, 3150.0, 3450.0, 4000.0, 4450.0, 5000.0, 6000.0, 7000.0, 8000.0], 'cols'=>[136.0, 309.3, 424.8, 533.1, 648.7, 764.2, 879.7, 930.3, 980.8, 1038.6],
   'mult'=>[1, 3, 4, 6, 7, 8, 10, 10, 11, 11],
   'data'=>[
     [68, 123, 145, 132, 139, 147, 140, 150, 148, 155],
     [68, 123, 145, 132, 139, 147, 140, 150, 148, 156],
     [68, 123, 146, 131, 140, 148, 140, 151, 149, 160],
     [72, 125, 148, 135, 141, 150, 141, 152, 150, 162],
     [72, 129, 152, 137, 145, 153, 144, 155, 153, 165],
     [72, 135, 158, 142, 150, 158, 150, 157, 153, 165],
     [72, 137, 158, 141, 149, 158, 150, 160, 158, 170],
     [72, 135, 155, 138, 148, 156, 147, 158, 154, 165],
     [76, 144, 165, 147, 158, 166, 155, 166, 170, 182],
     [72, 139, 159, 141, 151, 159, 150, 161, 158, 170],
     [72, 139, 159, 140, 151, 158, 150, 161, 158, 170],
     [72, 140, 160, 141, 150, 158, 150, 160, 156, 168],
     [76, 147, 167, 148, 157, 164, 154, 163, 160, 173],
     [76, 131, 157, 143, 156, 164, 154, 163, 160, 173],
     [80, 151, 176, 159, 171, 181, 170, 184, 179, 211],
     [112, 167, 190, 172, 183, 192, 180, 189, 183, 217],
     [120, 169, 191, 172, 185, 192, 179, 191, 185, 219],
     [80, 148, 172, 157, 170, 173, 166, 177, 172, 204],
     [80, 148, 172, 157, 170, 173, 166, 177, 172, 204],
     [80, 148, 170, 157, 170, 173, 166, 177, 172, 204],
   ]],
  ['name'=>'FUEL1_Hi', 'addr'=>'0x70A5', 'formula'=>'honda_fuel', 'cat'=>'Fuel', 'unit'=>'ms', 'dec'=>2,
   'rows'=>[0.0, 600.0, 1000.0, 1500.0, 2000.0, 2500.0, 3000.0, 3550.0, 4000.0, 4500.0, 4800.0, 5000.0, 5300.0, 5550.0, 6000.0, 6500.0, 7000.0, 7500.0, 8050.0, 9000.0], 'cols'=>[136.0, 309.3, 424.8, 533.1, 648.7, 764.2, 879.7, 930.3, 980.8, 1038.6],
   'mult'=>[1, 3, 4, 6, 7, 8, 9, 10, 11, 11],
   'data'=>[
     [40, 119, 138, 127, 139, 150, 156, 151, 154, 164],
     [40, 119, 138, 127, 139, 150, 156, 151, 154, 164],
     [40, 119, 138, 127, 139, 150, 156, 151, 154, 164],
     [40, 119, 138, 127, 139, 150, 156, 151, 154, 164],
     [40, 119, 138, 127, 139, 150, 156, 151, 154, 164],
     [40, 119, 138, 127, 139, 150, 156, 151, 154, 164],
     [76, 143, 164, 147, 155, 167, 173, 168, 169, 185],
     [24, 120, 150, 140, 151, 165, 176, 171, 174, 186],
     [24, 119, 147, 139, 153, 164, 173, 170, 169, 178],
     [20, 143, 167, 153, 166, 178, 189, 181, 175, 183],
     [60, 143, 168, 157, 171, 184, 191, 182, 176, 184],
     [0, 155, 179, 163, 178, 186, 196, 189, 185, 187],
     [56, 167, 193, 177, 192, 203, 213, 202, 191, 194],
     [96, 179, 204, 185, 199, 206, 212, 203, 192, 200],
     [124, 184, 216, 191, 202, 208, 215, 204, 197, 202],
     [72, 187, 213, 197, 209, 213, 222, 212, 202, 203],
     [92, 161, 199, 195, 209, 214, 218, 217, 200, 203],
     [64, 143, 182, 173, 188, 203, 202, 194, 182, 191],
     [64, 143, 182, 173, 188, 203, 202, 194, 182, 191],
     [64, 143, 182, 173, 188, 203, 202, 194, 182, 191],
   ]],
  ['name'=>'FUEL2_Lo', 'addr'=>'0x765F', 'formula'=>'honda_fuel', 'cat'=>'Fuel', 'unit'=>'ms', 'dec'=>2,
   'rows'=>[525.0, 600.0, 700.0, 825.0, 1000.0, 1300.0, 1500.0, 1750.0, 2000.0, 2250.0, 2575.0, 3075.0, 3150.0, 3450.0, 4000.0, 4450.0, 5000.0, 6000.0, 7000.0, 8000.0], 'cols'=>[],
   'mult'=>[1, 3, 4, 6, 7, 8, 10, 10, 11, 11],
   'data'=>[
     [68, 123, 145, 132, 139, 147, 140, 150, 148, 155],
     [68, 123, 145, 132, 139, 147, 140, 150, 148, 156],
     [68, 123, 146, 131, 140, 148, 140, 151, 149, 160],
     [72, 125, 148, 135, 141, 150, 141, 152, 150, 162],
     [72, 129, 152, 137, 145, 153, 144, 155, 153, 165],
     [72, 135, 158, 142, 150, 158, 150, 157, 153, 165],
     [72, 137, 158, 141, 149, 158, 150, 160, 158, 170],
     [72, 135, 155, 138, 148, 156, 147, 158, 154, 165],
     [76, 144, 165, 147, 158, 166, 155, 166, 170, 182],
     [72, 139, 159, 141, 151, 159, 150, 161, 158, 170],
     [72, 139, 159, 140, 151, 158, 150, 161, 158, 170],
     [72, 140, 160, 141, 150, 158, 150, 160, 156, 168],
     [76, 147, 167, 148, 157, 164, 154, 163, 160, 173],
     [76, 131, 157, 143, 156, 164, 154, 163, 160, 173],
     [80, 151, 176, 159, 171, 181, 170, 184, 179, 211],
     [112, 167, 190, 172, 183, 192, 180, 189, 183, 217],
     [120, 169, 191, 172, 185, 192, 179, 191, 185, 219],
     [80, 148, 172, 157, 170, 173, 166, 177, 172, 204],
     [80, 148, 172, 157, 170, 173, 166, 177, 172, 204],
     [80, 148, 170, 157, 170, 173, 166, 177, 172, 204],
   ]],
  ['name'=>'FUEL2_Hi', 'addr'=>'0x7857', 'formula'=>'honda_fuel', 'cat'=>'Fuel', 'unit'=>'ms', 'dec'=>2,
   'rows'=>[0.0, 600.0, 1000.0, 1500.0, 2000.0, 2500.0, 3000.0, 3550.0, 4000.0, 4500.0, 4800.0, 5000.0, 5300.0, 5550.0, 6000.0, 6500.0, 7000.0, 7500.0, 8050.0, 9000.0], 'cols'=>[],
   'mult'=>[1, 3, 4, 6, 7, 8, 9, 10, 11, 11],
   'data'=>[
     [40, 119, 138, 127, 139, 150, 156, 151, 154, 164],
     [40, 119, 138, 127, 139, 150, 156, 151, 154, 164],
     [40, 119, 138, 127, 139, 150, 156, 151, 154, 164],
     [40, 119, 138, 127, 139, 150, 156, 151, 154, 164],
     [40, 119, 138, 127, 139, 150, 156, 151, 154, 164],
     [40, 119, 138, 127, 139, 150, 156, 151, 154, 164],
     [76, 143, 164, 147, 155, 167, 173, 168, 169, 185],
     [24, 120, 150, 140, 151, 165, 176, 171, 174, 186],
     [24, 119, 147, 139, 153, 164, 173, 170, 169, 178],
     [20, 143, 167, 153, 166, 178, 189, 181, 175, 183],
     [60, 143, 168, 157, 171, 184, 191, 182, 176, 184],
     [0, 155, 179, 163, 178, 186, 196, 189, 185, 187],
     [56, 167, 193, 177, 192, 203, 213, 202, 191, 194],
     [96, 179, 204, 185, 199, 206, 212, 203, 192, 200],
     [124, 184, 216, 191, 202, 208, 215, 204, 197, 202],
     [72, 187, 213, 197, 209, 213, 222, 212, 202, 203],
     [92, 161, 199, 195, 209, 214, 218, 217, 200, 203],
     [64, 143, 182, 173, 188, 203, 202, 194, 182, 191],
     [64, 143, 182, 173, 188, 203, 202, 194, 182, 191],
     [64, 143, 182, 173, 188, 203, 202, 194, 182, 191],
   ]],
  ['name'=>'IGN1_Lo', 'addr'=>'0x729D', 'formula'=>'ign_advance', 'cat'=>'Ignition', 'unit'=>'deg BTDC', 'dec'=>2,
   'rows'=>[525.0, 600.0, 700.0, 825.0, 1000.0, 1300.0, 1500.0, 1750.0, 2000.0, 2250.0, 2575.0, 3075.0, 3150.0, 3450.0, 4000.0, 4450.0, 5000.0, 6000.0, 7000.0, 8000.0], 'cols'=>[136.0, 309.3, 424.8, 533.1, 648.7, 764.2, 879.7, 930.3, 980.8, 1038.6],
   'mult'=>null,
   'data'=>[
     [90, 90, 90, 82, 68, 48, 32, 15, 0, 0],
     [90, 90, 90, 82, 68, 48, 32, 15, 0, 0],
     [90, 90, 90, 82, 68, 48, 32, 15, 0, 0],
     [90, 90, 90, 82, 68, 48, 32, 15, 0, 0],
     [111, 111, 111, 105, 97, 73, 49, 34, 21, 17],
     [135, 135, 135, 125, 115, 89, 64, 51, 36, 32],
     [143, 143, 143, 133, 121, 96, 71, 59, 45, 41],
     [151, 151, 151, 139, 125, 102, 78, 67, 53, 49],
     [158, 158, 158, 145, 133, 114, 90, 79, 66, 62],
     [162, 162, 162, 149, 137, 119, 97, 85, 70, 65],
     [166, 166, 166, 152, 140, 123, 101, 88, 72, 68],
     [175, 175, 175, 161, 147, 132, 111, 95, 78, 74],
     [183, 183, 183, 170, 154, 140, 120, 103, 84, 80],
     [199, 199, 199, 190, 179, 171, 154, 138, 112, 112],
     [199, 199, 199, 190, 179, 171, 154, 141, 124, 124],
     [199, 199, 199, 190, 179, 171, 154, 141, 124, 124],
     [199, 199, 199, 190, 179, 171, 154, 141, 132, 132],
     [199, 199, 199, 190, 179, 171, 154, 141, 132, 132],
     [199, 199, 199, 190, 179, 171, 154, 141, 132, 132],
     [200, 200, 200, 189, 179, 171, 154, 141, 132, 132],
   ]],
  ['name'=>'IGN1_Hi', 'addr'=>'0x747D', 'formula'=>'ign_advance', 'cat'=>'Ignition', 'unit'=>'deg BTDC', 'dec'=>2,
   'rows'=>[0.0, 600.0, 1000.0, 1500.0, 2000.0, 2500.0, 3000.0, 3550.0, 4000.0, 4500.0, 4800.0, 5000.0, 5300.0, 5550.0, 6000.0, 6500.0, 7000.0, 7500.0, 8050.0, 9000.0], 'cols'=>[136.0, 309.3, 424.8, 533.1, 648.7, 764.2, 879.7, 930.3, 980.8, 1038.6],
   'mult'=>null,
   'data'=>[
     [90, 90, 90, 90, 68, 48, 32, 16, 0, 0],
     [90, 90, 90, 90, 68, 48, 32, 16, 0, 0],
     [120, 120, 120, 113, 101, 76, 49, 34, 21, 17],
     [149, 149, 149, 137, 124, 103, 76, 65, 51, 47],
     [162, 162, 162, 149, 137, 119, 97, 85, 73, 69],
     [183, 183, 183, 169, 154, 139, 120, 100, 81, 77],
     [197, 197, 197, 184, 173, 165, 153, 122, 98, 94],
     [199, 199, 199, 186, 179, 171, 161, 141, 115, 115],
     [199, 199, 199, 190, 179, 171, 154, 141, 124, 124],
     [199, 199, 199, 190, 175, 171, 154, 141, 124, 124],
     [200, 200, 200, 193, 178, 174, 154, 141, 128, 128],
     [200, 200, 200, 196, 181, 177, 154, 141, 132, 132],
     [200, 200, 200, 195, 180, 175, 154, 141, 132, 132],
     [200, 200, 200, 192, 180, 173, 154, 141, 132, 132],
     [200, 200, 200, 187, 179, 171, 154, 141, 132, 132],
     [200, 200, 200, 187, 179, 171, 154, 141, 132, 132],
     [200, 200, 200, 187, 179, 171, 154, 141, 132, 132],
     [200, 200, 200, 187, 179, 171, 154, 141, 132, 132],
     [200, 200, 200, 187, 179, 171, 154, 141, 132, 132],
     [200, 200, 200, 187, 179, 171, 154, 141, 132, 132],
   ]],
  ['name'=>'IGN2_Lo', 'addr'=>'0x7A4F', 'formula'=>'ign_advance', 'cat'=>'Ignition', 'unit'=>'deg BTDC', 'dec'=>2,
   'rows'=>[525.0, 600.0, 700.0, 825.0, 1000.0, 1300.0, 1500.0, 1750.0, 2000.0, 2250.0, 2575.0, 3075.0, 3150.0, 3450.0, 4000.0, 4450.0, 5000.0, 6000.0, 7000.0, 8000.0], 'cols'=>[],
   'mult'=>null,
   'data'=>[
     [90, 90, 90, 82, 68, 48, 32, 15, 0, 0],
     [90, 90, 90, 82, 68, 48, 32, 15, 0, 0],
     [90, 90, 90, 82, 68, 48, 32, 15, 0, 0],
     [90, 90, 90, 82, 68, 48, 32, 15, 0, 0],
     [111, 111, 111, 105, 97, 73, 49, 34, 21, 17],
     [135, 135, 135, 125, 115, 89, 64, 51, 36, 32],
     [143, 143, 143, 133, 121, 96, 71, 59, 45, 41],
     [151, 151, 151, 139, 125, 102, 78, 67, 53, 49],
     [158, 158, 158, 145, 133, 114, 90, 79, 66, 62],
     [162, 162, 162, 149, 137, 119, 97, 85, 70, 65],
     [166, 166, 166, 152, 140, 123, 101, 88, 72, 68],
     [175, 175, 175, 161, 147, 132, 111, 95, 78, 74],
     [183, 183, 183, 170, 154, 140, 120, 103, 84, 80],
     [199, 199, 199, 190, 179, 171, 154, 138, 112, 112],
     [199, 199, 199, 190, 179, 171, 154, 141, 124, 124],
     [199, 199, 199, 190, 179, 171, 154, 141, 124, 124],
     [199, 199, 199, 190, 179, 171, 154, 141, 132, 132],
     [199, 199, 199, 190, 179, 171, 154, 141, 132, 132],
     [199, 199, 199, 190, 179, 171, 154, 141, 132, 132],
     [200, 200, 200, 189, 179, 171, 154, 141, 132, 132],
   ]],
  ['name'=>'IGN2_HI', 'addr'=>'0x7C2F', 'formula'=>'ign_advance', 'cat'=>'Ignition', 'unit'=>'deg BTDC', 'dec'=>2,
   'rows'=>[0.0, 600.0, 1000.0, 1500.0, 2000.0, 2500.0, 3000.0, 3550.0, 4000.0, 4500.0, 4800.0, 5000.0, 5300.0, 5550.0, 6000.0, 6500.0, 7000.0, 7500.0, 8050.0, 9000.0], 'cols'=>[],
   'mult'=>null,
   'data'=>[
     [90, 90, 90, 90, 68, 48, 32, 16, 0, 0],
     [90, 90, 90, 90, 68, 48, 32, 16, 0, 0],
     [120, 120, 120, 113, 101, 76, 49, 34, 21, 17],
     [149, 149, 149, 137, 124, 103, 76, 65, 51, 47],
     [162, 162, 162, 149, 137, 119, 97, 85, 73, 69],
     [183, 183, 183, 169, 154, 139, 120, 100, 81, 77],
     [197, 197, 197, 184, 173, 165, 153, 122, 98, 94],
     [199, 199, 199, 186, 179, 171, 161, 141, 115, 115],
     [199, 199, 199, 190, 179, 171, 154, 141, 124, 124],
     [199, 199, 199, 190, 175, 171, 154, 141, 124, 124],
     [200, 200, 200, 193, 178, 174, 154, 141, 128, 128],
     [200, 200, 200, 196, 181, 177, 154, 141, 132, 132],
     [200, 200, 200, 195, 180, 175, 154, 141, 132, 132],
     [200, 200, 200, 192, 180, 173, 154, 141, 132, 132],
     [200, 200, 200, 187, 179, 171, 154, 141, 132, 132],
     [200, 200, 200, 187, 179, 171, 154, 141, 132, 132],
     [200, 200, 200, 187, 179, 171, 154, 141, 132, 132],
     [200, 200, 200, 187, 179, 171, 154, 141, 132, 132],
     [200, 200, 200, 187, 179, 171, 154, 141, 132, 132],
     [200, 200, 200, 187, 179, 171, 154, 141, 132, 132],
   ]],
  ['name'=>'VEhi', 'addr'=>'0x7E0F', 'formula'=>'ve_percent', 'cat'=>'VE', 'unit'=>'%', 'dec'=>1,
   'rows'=>[500.0, 625.0, 725.0, 825.0, 950.0, 1100.0, 1325.0, 1575.0, 1775.0, 2000.0, 2450.0, 2650.0, 2875.0, 3100.0, 3350.0, 3775.0, 4450.0, 5325.0, 6250.0, 8000.0], 'cols'=>[136.0, 309.3, 424.8, 533.1, 648.7, 764.2, 879.7, 930.3, 980.8, 1038.6],
   'mult'=>null,
   'data'=>[
     [142, 142, 142, 142, 142, 142, 142, 151, 151, 151],
     [142, 142, 142, 142, 142, 142, 142, 151, 151, 151],
     [142, 142, 142, 142, 142, 142, 142, 151, 151, 151],
     [142, 142, 142, 142, 142, 142, 142, 151, 151, 151],
     [142, 142, 142, 142, 142, 142, 142, 151, 151, 151],
     [142, 142, 142, 142, 142, 142, 142, 147, 147, 147],
     [142, 142, 142, 142, 142, 142, 142, 147, 147, 147],
     [142, 142, 142, 142, 142, 142, 142, 147, 147, 147],
     [142, 142, 142, 142, 142, 142, 142, 147, 147, 147],
     [142, 142, 142, 142, 142, 142, 142, 147, 147, 147],
     [142, 142, 142, 142, 142, 142, 142, 147, 147, 147],
     [142, 142, 142, 142, 142, 142, 142, 147, 147, 147],
     [142, 142, 142, 142, 142, 142, 142, 147, 147, 147],
     [142, 142, 142, 142, 142, 142, 142, 147, 147, 147],
     [142, 142, 142, 142, 142, 142, 142, 147, 147, 147],
     [142, 142, 142, 142, 142, 142, 142, 147, 147, 147],
     [142, 142, 142, 142, 142, 142, 142, 151, 151, 151],
     [142, 142, 142, 142, 142, 142, 142, 151, 151, 151],
     [142, 142, 142, 142, 142, 151, 151, 154, 154, 154],
     [142, 142, 142, 142, 151, 151, 151, 154, 154, 154],
   ]],
];


/* The scalings the app applies (read out of HTS's own editor code) */
$formulas = [
  ['honda_fuel','(x &times; column multiplier) / 4','injector cells, ms — multiplier row lives right after the map'],
  ['ign_advance','x &times; 0.25 - 6','ignition cells, deg BTDC — verified by test: 64 &rarr; 10 deg'],
  ['ve_percent','x &times; 100 / 128 - 100','VE cells, %'],
  ['rpm_period_word','1875000 / x','16-bit crank period; exact at fOSC/4 timers — the clock is measured, not guessed'],
  ['rpm_axis_byte_log','2^(x>>6) &times; (500 + 7.8125 &times; (x&amp;63))','exponent/mantissa RPM breakpoint'],
  ['map_mbar','x &times; 7.221 - 59','MAP/load axis byte — HTS115\'s load axis ends at 1039 mbar, exactly what HTS shows'],
  ['percent255','x &times; 100 / 255','fractions'],
  ['volts_5v_word','x &times; 5 / 1023','ADC counts as volts'],
];

/* The MCP surface — what an agent gets */
$mcpModes = [
  ['RomSimStudio --mcp --root <folder> [--read-only]','stdio, files only'],
  ['Settings > MCP server in the app','HTTP, working on the ROM open on screen — edits go through undo and reach the emulator'],
];
$mcpTools = [
  ['arch / opcode','the instruction set, DD width, double indirection, every encoding'],
  ['assemble / disassemble / disassemble_range','build + flow-following disassembly'],
  ['run','simulate: rpm, kPa, TPS, ECT, O2, speed, watch expressions, until labels'],
  ['symbols / xref / explore / detect_tables','where things live, who touches them, what a routine does, every map in a ROM'],
  ['compare_bins','byte diff grouped into ranges, named by label'],
  ['cal_list / read / write / define / delete / detect / explain','the whole calibration surface: cells, ranges, grids, set/add/mul/pct, raw or scaled'],
  ['cal_formulas / cal_save','custom expressions; save bin, definitions JSON, TunerPro XDF'],
  ['cal_features','feature-file code patches: which fit this ROM, apply / remove one &mdash; expected bytes checked first, exact restore'],
  ['app_open / transfer_dir','the remote round trip: file_upload into the always-writable transfer folder, app_open lands the ROM on the user\'s screen'],
  ['datalog','status/start/stop/frames/load, detect_layout, overlay + AFR-fuel suggestions, stats'],
  ['emulator / simulator / session_info','connect, upload, auto-upload — live in the app'],
  ['file_* / rom_* / file_edit*','paged workspace files, upload/download as base64 with SHA-256, surgical edits'],
];

$cli = [
  'okisim asm file.asm [-o out.bin] [-D NAME=val] [-I dir] [--compat] [--lst --map --sym]',
  'okisim run file.bin|file.asm [--steps N] [--until label] [--trace N] [--rpm N] [--watch label] [--stall]',
  'okisim disasm file.bin [--from 2528] [--count 40] [--sym file.sym]',
  'okisim symbols <rom> [pattern] [--at ADDR]        okisim xref <rom> <addr> [--max N]',
  'okisim defs <rom> [--defs f.okidef.json] [--filter text] [--category name]',
  'okisim get <rom> <name|label|address> [--type u8] [--formula name] [--rows R --cols C]',
  'okisim set <rom> <name|address> <value> [--cell R,C] [--all] [--add X] [--scale X] [--raw]',
  'okisim formulas [name]                            okisim defs-export <file.asm>',
  'okisim features <rom> [--file features.json] [--apply id,id] [--remove id] [-o out.bin]',
];

$features = [
  'Ctrl+O opens .asm, .bin/.rom or a project .zip — a .bin disassembles itself, verified byte-identical',
  '10 MHz crystal (measured): cycles at fOSC/4 = 2.5 MHz, timers /8 — the ROM rpm word comes out exactly 1,875,000/rpm',
  'Fast Boot skips the 4.5 s key-on A/D scan; speed 0.1x / 0.5x / real / 4x / unlimited in 4 ms UI slices',
  'Live 64-pin view: hover for level, rate, last edge, which routine wrote it; click to force pins, dial analog volts',
  'F5 / F11 Step / F10 Over / Ctrl+F11 Into (force a branch taken) / Shift+F11 Out / F9 breakpoint — shadow call stack for CAL/VCAL/interrupts',
  'Detect reads the code, not an address table: 9 lookup maps + 69 switches found in HTS115, load axis to 1039 mbar — exactly what HTS shows',
  'Maps drawn as HTS draws them (RPM left, load top, cyan-green-yellow-red) + Line and 3D views; type, interpolate, smooth, undo',
  'Live trace marks the cells the running program reads; "follow reads" jumps the page when a step touches a table',
  'Datalog tab: HTS, ISR v2, Crome/QD3, HTS single-byte and raw 10h and P13 46h/20h frames — or connect to the SIMULATOR, a virtual ECU on its own serial port',
  'Detect layout learns an unknown ROM\'s datalog format by interrogating the simulated ROM; every parameter of every frame decoded',
  'Wideband on its own port (AEM, Zeitronix, TechEdge, PLX, Innovate, 14Point7...), aux channels computed from raw frame bytes through an expression',
  'Overlay: measured AFR averaged into every map cell the engine sat in — AFR fix scales the fuel cells toward target',
  'Load HTS .rlog logs: the zip carries the log, the ROM that made it and the settings — all three open together',
  'Hit trace: executed addresses from the simulator or a REAL ECU through a Moates Ostrich 2.0 / Demon, coloured on the source',
  'Compare: routines matched by code shape (moved &ne; changed), maps diffed cell by cell — "only calibration data changed"',
  'Tuner mode (Ctrl+T): calibration editor + compact live datalog, no source — the cell the car is in gets marked',
  'Processor profile in JSON: MSM66207 (P28) and MSM66911 (P13/OBD0) built in, each with its own on-chip peripheral model — a ROM for either part runs',
  'Project .zip: full machine state + processor.json + settings.json — resumes mid-instruction',
  'Debug console: every button, error, serial byte and MCP tool call with client address and duration',
  'Emulator: connect, upload, auto-upload on every save — an agent\'s edit can reach the bench while you watch',
  'Check-engine lamp simulated as the ROM drives it: stored codes, long/short flashes with the ROM\'s own renumbering (25→35, 26→36, 27→41, 29→43), service-check jumper, backup-fuse clear — live in the MIL window',
  'Feature pages: every option on a page laid out like the established tuning software, bound by slot — by address on an HTS ROM, by detected definition on any other',
  'Feature patches: code changes that expect the bytes they replace and restore exactly what was there — per-ROM variants, patterns for unknown ROMs, CLI and MCP too',
  'File > New ROM: Existing copies a template, Create builds a ROM from the skeleton plus the modules you tick - a bar shows what is left of the 32 KB',
 'Injector, MAP-sensor and AFR-correction setup windows; targets and correction curves on grids shaped exactly like the maps',
  'Datalog gets its own graph window; breakpoints add/remove by label or address; the layout scales down to fit smaller laptop screens instead of being squeezed',
 'Build a ROM from feature modules, for the P30 family or the P13: 57 modules plus 13 stock functions on each, hooks at 7F00h, free space read from the ROM\'s own info block, checksum byte kept balanced',
 'Every module annotates its own settings, so it arrives with calibration pages; CATALOGUE.md lists what is built, what is stock and what will not fit this ECU',
 'ROM sources ship with it - HTS120 and the skeleton as templates, P30, P72-269, P08-911-243 and HTS115 as references; an unknown ROM is matched against one to find its tables',
 'Table shapes: a run of bytes previously known as "N bytes" becomes the 1-D tables the VCAL routine that reads it actually walks',
 'Tools > Import maps: the tune from another ROM family into this one - paired by job, moved in real units, resampled onto these axes, previewed as three maps, one undo step',
 'Memory gains a Map tab: every RAM byte named and scaled, with the instruction that wrote it last; write a byte once or Hold it against the ROM',
 'Patch live (Ctrl+Shift+B): only the changed bytes go into the running ROM - no reset, RAM and crank phase intact - and into the emulator if it is uploading',
 'Project files snapshot every field of the simulated machine, so a newer simulator still opens an older session',
 'Datalog: tick the channels the ROM streams, read and clear the stored codes, and drive the service commands - injectors off, timing locked, maps chosen - over the same cable',
 'Moates Demon onboard logging: rate, triggers and compression set here, sessions read back from the dataflash into the datalog page or a CSV',
 'A link dot that blinks orange while a lost link is being rebuilt, and median spike rejection so a 28 rpm reading between two at 6000 never reaches the log',
 'Plugins: one class in a .dll adds menus, buttons, tabs, windows, calibration pages and settings - or feeds the datalog page from its own source (ScanTool on an ELM327 ships as the example)',
 'Updates from the author site, SHA-256 checked, program and templates, nothing downloaded until asked; File > Bin tool for 32 KB ROMs on 64 KB chips',
 'Touch mode for a screen beside the car, a low-performance mode for an old laptop, a first-start question that picks the view, and a watermark plus open password carried in the ROM itself',
 'New ROM checks the pick before it writes it: a module RAM bar, a checklist (rev limiter, fail-safes, datalogging, protection, space) and warnings such as "No safeties in this ROM", from a safe starting pick',
 'Every value written is held to what the ECU and engine can use - rpm, advance, duty, AFR, choices, volts - from the editor, a feature page, MCP or the command line alike; output pins two functions fight over are listed in Problems',
];

/* HTS115 verified run data — unique addresses per the README 3M-instruction run,
   idle pulse from the current test suite, coverage/datalog from its passing tests. */
$rom = ['name'=>'HTS115','addrs'=>5623,'instrs'=>10341,'idle_ms'=>3.49];

/* What 0.0.0.3 brought (from 0.0.0.2): kept for the release history below. */
$release003 = [
 ['head'=>'a_rom_you_build_yourself', 'items'=>[
 'The centre of gravity of this release: <b style="color:#fff">roms/p30-skeleton.asm</b>, a stock P30 (Honda OBD1, OKI MSM66207, P28 board) cut down to what still runs an engine &mdash; <b style="color:#fff">20,729 of 32,768 bytes used, 11,839 free in one block</b>, against stock&#39;s 30,894. Kept: boot and ROM checksum, crank / TDC / CYP sync and sensor conditioning, fuel (one VE map for both cams), ignition and its corrections, rev limiter, VTEC solenoid, idle air, fuel pump, fan, alternator. Gone: the serial link, the trouble codes and their fail-safes, the check-engine lamp, closed loop, knock retard, the speed limiter, EGR, automatic shifts, purge, O2 heater, A/C, the self-tests &mdash; and every table only the removed code read.',
 'The seams are already in it: <b style="color:#fff">eight hook slots at 7F00h</b> (<span style="font-family:var(--mono)">init / main / fuel / ign</span> plus four spares), each <span style="font-family:var(--mono)">RT, NOP, NOP</span> until a module writes <span style="font-family:var(--mono)">J &lt;module&gt;</span> over it and chains to the next module on the same hook. An <b style="color:#fff">info block at 7FE0h</b> tells an editor the layout version and where the free space starts, and the last byte is a checksum the ROM adds up and checks <i>while it runs</i>.',
 'Modules ask for things instead of patching over them: a <b style="color:#fff">fuel-cut word at 1F0h</b> (checked where every path of the cut decision meets, so it holds at idle and cranking too), a <b style="color:#fff">spark-cut word at 0FCh</b> (the coil is left unarmed at the timer-3 compare, which the idle paths otherwise leave set), a retard request at 2FDh, and a <b style="color:#fff">tick at 0FEh</b> that climbs every 2.048&nbsp;ms whatever the rpm &mdash; because the main loop only makes a few passes a second up top.',
 '<b style="color:#fff">File &gt; New ROM &gt; Create</b> is where it lands: pick the base, tick the functions, watch the bar showing what is left of the 32&nbsp;KB, and the app writes the build file (the chosen <span style="font-family:var(--mono)">define FEAT_...</span> lines, then <span style="font-family:var(--mono)">include "p30-skeleton.asm"</span>) and opens it. The assembler places the code and the tables, so <b style="color:#fff">any mix builds in any order without colliding</b>, and a full ROM stops the build with an error instead of quietly overlapping.',
 'Cut one subsystem at a time, and after every cut run the skeleton and stock P30 side by side at <b style="color:#fff">14 operating points</b> &mdash; cranking, cold and warm idle, 1100&nbsp;rpm idle, cruise, part load, WOT at 3000, VTEC at 6500, the 8600 limit, decel, hot WOT, key-on prime, stall, a throttle snap &mdash; comparing pump, VTEC duty, injector rate and pulse width, spark relative to TDC, and IACV duty. Then a per-instruction <i>read trace</i> in both ROMs, which is how a start-up copy loop reading its values through another table&#39;s address, and five instructions that used a calibration address as a plain number, were found. <b style="color:var(--amber)">It has not been run on a car.</b> It is a starting point, not a bolt-on tune.']],
 ['head'=>'fifty_feature_modules', 'items'=>[
 '<b style="color:#fff">50 modules</b> in <span style="font-family:var(--mono)">roms/p30-features/</span>, plus <b style="color:#fff">13 stock functions</b> the skeleton can put back (<span style="font-family:var(--mono)">FEAT_STOCK_DTC</span>, knock, closed loop, A/C, EGR, purge, O2 heater, automatics, self-tests...). Ported from HTS120, HTS115, CromeGold, two custom ROMs, a P13 and stock P30 / P08 &mdash; and some written new because nothing in this family had them.',
 'Every module is one <span style="font-family:var(--mono)">.asm</span> with a <span style="font-family:var(--mono)">;&gt;</span> header (name, category, RAM it owns, conflicts, requires, what it does) that <b style="color:#fff">New ROM reads to build its list</b>, wrapped in <span style="font-family:var(--mono)">ifdef FEAT_X</span> and included at each extension point. <span style="font-family:var(--mono)">CATALOGUE.md</span> lists every function any of these ROMs has and where it stands &mdash; module, stock, in the skeleton, or not portable with the reason. <span style="font-family:var(--mono)">README.md</span> shows how to write one.',
 'A module annotates its own settings with <span style="font-family:var(--mono)">;@</span>, so it arrives with <b style="color:#fff">calibration pages</b>: a new page for functions the established software has none for, the GPO pages in the layout the ROM&#39;s own outputs use, and a <i>More settings</i> group on any page whose module keeps values the page does not list. The same module is also a binary patch in the existing <span style="font-family:var(--mono)">okirom-features</span> format for a ROM already built &mdash; <span style="font-family:var(--mono)">apply</span> writes 18 bytes, <span style="font-family:var(--mono)">remove</span> gives the skeleton back byte for byte.']],
 ['head'=>'the_reference_roms', 'items'=>[
 'The sources are in the box: HTS120 and the skeleton go in as <b style="color:#fff">templates</b>, and <b style="color:#fff">P30, P72-269, P08-911-243 and HTS115 as labelled reference sources</b> under <span style="font-family:var(--mono)">Templates/References</span> &mdash; HTS120 and the skeleton annotated with <span style="font-family:var(--mono)">;@</span> definitions, so their maps open already named. Honda ECUs of one generation share most of their code, so an unknown ROM with <i>no labels at all</i> is now matched against a known one: line the two programs up instruction by instruction, read the operands side by side, and the instruction that reads a table in one reads the same table in the other &mdash; at a different address. Detect reports how many definitions came from a known ROM of the same family.',
 '<b style="color:#fff">Table shapes</b> reads a 1-D table&#39;s layout from the code that reads it. These ROMs interpolate with a handful of routines (the VCALs and their relatives) walking a list of (input, value) entries: which routine says how wide an entry is, the data says how many, and the RAM byte loaded before the call says what the input is (coolant, rpm, throttle...). A run of bytes previously known only as &quot;N bytes&quot; becomes the tables it really holds.',
 'A tune can move between ROM families: <b style="color:#fff">Tools &gt; Import maps</b> pairs each of the other ROM&#39;s tables with the table here that does the same job (same page row, same name, or a fuel / ignition / VE map for the same cam), moves values in real units through each ROM&#39;s own formula, and resamples a map whose breakpoints differ &mdash; by breakpoints, stretched end to end, or cell for cell &mdash; with all three tables previewed in the same Table, Line and 3D views and the whole import a single undo step.',
 'The HTS bindings learned from HTS-master are generated now, and complete: each 1.15 setting knows where it sits in the <b style="color:#fff">earlier layouts</b> (HTS 1.00-1.14, the original eCtune ROMs and the eCtune-format ROMs of other software), and every field carries the conversion HTS itself applies. Formula names say what they convert (<span style="font-family:var(--mono)">map_load_axis</span>, <span style="font-family:var(--mono)">map_sensor_byte</span>) instead of a hash of their text; definitions saved under the old names still load.']],
 ['head'=>'the_whole_machine_on_screen', 'items'=>[
 'The Memory page has a <b style="color:#fff">Map</b> tab beside the hex: every RAM byte the ROM uses, named &mdash; from a definition at that address, from the ROM&#39;s own datalog frame table, from a table whose description says where its result lands, from the source&#39;s <span style="font-family:var(--mono)">EQU</span> names, from the chip&#39;s SFRs, best first &mdash; with its raw value, its value in real units through the right formula, and <b style="color:#fff">which instruction wrote it last</b>, recorded as the simulator runs from power-up. Double-click a row to write it once, or <i>Hold</i> it and whatever the ROM writes there is put back at once.',
 '<b style="color:#fff">Patch live (Ctrl+Shift+B)</b>: assemble the source on screen and put only the bytes that changed into the ROM that is running &mdash; no reset. The program carries on from where it is, RAM and all, with the new code and tables at once, and the emulator gets the changed blocks if it is uploading. It asks first and stands down if the CPU is inside the code being changed.',
 'The byte that keeps the ROM&#39;s 8-bit sum at zero is rebalanced after <i>every</i> write, so an edited calibration, a saved <span style="font-family:var(--mono)">.bin</span> and an emulator upload all pass a ROM that checks itself. A project now saves the machine as a <b style="color:#fff">snapshot of every field</b> the simulator has (registers, bus, peripherals, engine, board), keyed by where it lives &mdash; a field added to the simulator later is saved without anyone having to remember it, and one a saved file mentions that no longer exists is ignored.',
 'The lists the app draws (Trace, Lookup and breakpoints, Problems, Debug, the chip&#39;s side panel, the datalog) are one drawn table: frozen headings, a coloured mark down the left of each row, colour where it means something, a tip per row, double-click to go there &mdash; drawn rather than built of controls, so thousands of rows refreshed several times a second cost almost nothing. A <b style="color:#fff">low performance mode</b> (Settings &gt; General) slows the panels down and drops the drawing effects so an old laptop spends its time on the datalog and the map.']],
 ['head'=>'beside_the_car', 'items'=>[
 'The datalog menu grew the things you reach for with a wrench in your hand. <b style="color:#fff">Channels</b>: tick what the car actually has (no A/C, no knock sensor) so the frames stay short &mdash; 33 of them, grouped, from a skeleton ROM built to stream them. <b style="color:#fff">Codes and service</b>: the codes the ECU has stored and whether the lamp is lit, read out of the datalog as it runs, clear them (50h, as HTS does), and on a skeleton ROM the service commands over the same cable &mdash; injectors off, timing locked for a timing light, the maps chosen, the GIO outputs forced on, with the lamp flashing quickly on the car while injectors or timing are out. Big buttons, because it is used with one hand.',
 '<b style="color:#fff">Demon onboard logging</b>: a Moates Demon can ask the ECU for the datalog itself and keep it in its dataflash with no laptop in the car. Here it is set up (what it asks, every how-many-th packet to keep, the triggers that open a session), switched on and off, and its sessions read back into the datalog panel or a CSV &mdash; compressed packets, page by page, erased when you are done.',
 'A coloured dot on the Emulator and Datalogging menus says where the link stands: red (not connected), green (connected), <b style="color:#fff">blinking orange</b> (lost and being got back), with the attempts and the gap between them in Settings. A <b>Smooth values</b> switch takes the noise out of a reading: the last few frames are looked at together, anything far from their median (6000 rpm, 28 rpm, 6000 rpm &mdash; a spike on the line, not the engine) is dropped and the rest blended into what is shown and recorded; a real change gets through as soon as the next frame agrees, and the raw frame is kept exactly as it came.']],
 ['head'=>'plugins_and_updates', 'items'=>[
 'The app is extensible: a plugin is a class library with one class implementing <span style="font-family:var(--mono)">IOkiPlugin</span>, picked in <b style="color:#fff">Settings &gt; Plugins</b>. A plugin gets the whole app &mdash; the ROM, its definitions, the simulator, the calibration editor, the datalog page, the settings &mdash; and can add menu entries, toolbar buttons, tabs, windows, calibration pages, sections at the bottom of a feature page, its own settings page and data folder, and can <b style="color:#fff">feed the datalog page frames from its own source</b>, so the gauges, graph, recording, map trace and O2 tables use them like any car&#39;s. Settings &gt; Plugins carries the whole guide, every way in with an example to copy.',
 'The example that ships with it: <b style="color:#fff">ScanTool</b> &mdash; an ELM327 on a serial port, standard mode 01 readings mapped onto datalog channels, logging into the same Datalog page. It adds a menu entry, a window and a settings page and nothing else about the app knows it exists.',
 '<b style="color:#fff">Updates come from this site.</b> <span style="font-family:var(--mono)">index.php?updates</span> lists every file it has with its size, SHA-256, its own version number (up one each time the bytes change) and the file version a <span style="font-family:var(--mono)">.dll</span> / <span style="font-family:var(--mono)">.exe</span> carries; the app offers what differs from the files beside it &mdash; the program and its templates &mdash; and downloads nothing until asked. A replaced template keeps a <span style="font-family:var(--mono)">.bak</span> of the old one; the program&#39;s own files move aside as <span style="font-family:var(--mono)">.old</span>, because a running program cannot be written over, and the restart puts the new one in use. The site address is fixed in the binary, so an update can only ever come from the author.',
 'The release bundle got simpler and smaller: <span style="font-family:var(--mono)">build-release.bat</span> publishes the program with its managed libraries <b style="color:#fff">inside RomSimStudio.dll</b> (loaded from there the first time each is needed), leaving only the native drawing and serial bits in the per-platform runtimes folder beside it, the Templates, and the plugin in <span style="font-family:var(--mono)">Plugins/</span> &mdash; then zips it. <span style="font-family:var(--mono)">--selftest-live</span>, <span style="font-family:var(--mono)">--selftest-project</span> and <span style="font-family:var(--mono)">--selftest-smooth</span> check the live-edit paths against a running simulator, a saved session and the datalog smoother without opening a window: PASS / FAIL, exit 0 or 1.']],
 ['head'=>'the_bench_gets_polished', 'items'=>[
 'A <b style="color:#fff">first-start screen</b> asks what the app is for &mdash; writing and simulating ROMs, or tuning a car &mdash; and opens in that view; Settings &gt; General changes it later and can bring it back. <b style="color:#fff">Touch screen mode</b> sizes the controls for a finger across the whole app and puts a pad of big buttons beside the tables for what the keys do. Settings &gt; About says what the program is, who made it and under what licence.',
 '<b style="color:#fff">File &gt; Bin tool</b>: 32 KB ROMs and 64 KB (27C512 / SST27SF512) chips. The ECU sees 32 KB; a 64 KB chip holds two, and the ECU runs whichever half its top address line picks &mdash; so a single ROM goes in the upper half on a board with A15 tied high, or two tunes share one chip on a board with a switch on that line. Make a 64 KB image from one or two ROMs, or split one back in two.',
 'A ROM built from the skeleton can carry a <b style="color:#fff">watermark</b> &mdash; 16 characters stored scrambled plus a check word, so an edit made by anything that does not know about it (a hex editor, another tool) shows up as <i>modified</i> &mdash; and an <b style="color:#fff">open password</b>, kept in the ROM as a PBKDF2-SHA256 hash with a random salt, asked for before the app opens it. It is a lock on opening, not encryption: the ECU runs the ROM either way, and taking the block out changes bytes the ROM sums, so its own checksum test fails.',
 'Also in here: pages remember where you were and can step back through them; tables stretch to fill their panel; feature pages can show only the rows this ROM has; the emulator and datalog settings moved under one roof and Detect can be asked about a ROM on open instead of done silently; an unhandled error in one handler costs one action instead of the session; and a bad ROM, a dead cable or a plugin that throws no longer takes the app with it.']],
];

/* What changed from $previous to $version — read back through what it means at the bench. Rendered by the "New in" section. */
$release005 = [
 ['head'=>'new_languages', 'items'=>[
 '<b style="color:#fff">Eight languages</b>: English, Chinese, Spanish, French, Portuguese, Russian, Hungarian and German, picked in Settings &gt; General. Each is a plain <span style="font-family:var(--mono)">.json</span> file in the <span style="font-family:var(--mono)">lang</span> folder &mdash; English on the left, the translation on the right &mdash; read when the app starts, so you can correct one or add your own language by dropping a file there. Text not in a file stays English; with a language picked, <b style="color:#fff">Save the text not translated yet</b> writes what is still missing, ready to fill in.',
 '<b style="color:#fff">Rom Sim Studio</b>: the program has a new name and a new home, <a href="https://romsimstudio.com" style="color:var(--green)">romsimstudio.com</a>, where updates now come from. It is still the toolchain for OKI MSM66207 / 66911 ECUs; your settings, dyno runs and ROM folders move across by themselves the first time it starts.',
 '<b style="color:#fff">Units</b>: Settings &gt; Units picks the unit for every kind of measurement on its own &mdash; &deg;C or &deg;F, kPa, bar, psi or inHg, km/h or mph, kg or lb, kW, hp or PS, Nm, lb-ft or kgf&middot;m, AFR or lambda and more &mdash; with buttons for all metric, all imperial and the UK mix. The datalog, its graph and gauges, the maps and settings, the trace on the map and the dyno all follow it, and what you type goes back into the unit the ROM keeps.',
 '<b style="color:#fff">Themes</b> in Settings &gt; Colours: <b style="color:#fff">Dark</b> (the default), <b style="color:#fff">Light</b> &mdash; dark text on white, the maps keeping their colours &mdash; and <b style="color:#fff">High contrast</b> for a laptop out in the sun: every window black and white, with the colours that mean something (outputs on and off, warnings, the graphs&#39; traces) at full strength and faded text brought up. Every window changes at once; <b style="color:#fff">Ctrl+Shift+H</b> goes round the three.']],
 ['head'=>'dyno_mode', 'items'=>[
 '<b style="color:#fff">Datalogging &gt; Virtual dyno</b>: power and torque from the ECU&#39;s own datalog. <b style="color:#fff">Inertia</b> mode reads a roller of known inertia spun by the car; <b style="color:#fff">strip</b> mode uses the car&#39;s weight on a straight, flat stretch, with air drag and rolling resistance added back. Weights, drag and frontal area for the Civic EF, EG and EK, CRX, Integra DA, DB and DC, Accord CB, CD, CL and CG and Prelude BA and BB, JDM, EDM and USDM. Correction to SAE J1349, DIN 70020, SAE J607 or ECE from the ECU&#39;s own intake air and baro.',
 'Runs start and stop on triggers &mdash; a hotkey, throttle, MAP or boost, road speed, rpm, gear, all of them or any one &mdash; and <b style="color:#fff">one shot</b> (on by default) logs one pull, then stops so you can look at it. Runs are drawn as they happen and kept with their profile; replay one, race two <b style="color:#fff">head to head</b>, or print a report sheet.',
 'The graph reads every run off where the pointer is, <b style="color:#fff">zooms with the wheel</b> and pans by dragging; <b style="color:#fff">double-click</b> a point to see where the engine was in the fuel and ignition maps of the ROM open, the final ignition, AFR, injector time and VTEC there, and light that cell on the map. <b style="color:#fff">Right-click a line</b> for that run alone: its colour, width, which curves, its own correction, smoothing, drivetrain loss and rpm step, a scale factor, rename, replay, delete.',
 '<b style="color:#fff">Runs from logs</b> searches the log on the datalog page, picked files or a whole folder of logs for every pull that meets the triggers and keeps each one; <b style="color:#fff">Clear all</b> deletes them again. Results, correction, AFR source and hotkey moved to Settings &gt; Dyno, which can also restore the default profiles; a project now saves the dyno&#39;s profiles, runs and view with everything else (<a href="docs/dyno.html" style="color:var(--green)">how</a>).']],
 ['head'=>'improved_datalogging', 'items'=>[
 '<b style="color:#fff">Datalogging: every channel</b> (in Default): 188 channels instead of 53 &mdash; whether the <b style="color:#fff">rev limiter</b> or the overrun is cutting and which limiter module wants a cut, the fuel map&#39;s value before the corrections and every correction after it, each ignition correction and the knock retard, dwell, the idle target, VTEC&#39;s state, the map indexes, the engine&#39;s flag bytes bit by bit, the engine&#39;s flag bytes with <b style="color:#fff">every bit by name</b> (cranking, o2_ready, overrun_cut_armed, sw_brake, opt_knock_sensor...), <b style="color:#fff">eight RAM addresses of your own</b> logged under what the memory map says is there, and <b style="color:#fff">the state of every function in the ROM</b>, named as in its source &mdash; which injectors rolling idle left out last and how many it has, the trim traction control or the wideband loop is giving, a GIO&#39;s delay counting. Datalogging &gt; Channels has a search box and <b style="color:#fff">Everything</b>; the slow ones come round as a range, so the lot fits the ECU&#39;s 16-byte list.',
 '<b style="color:#fff">HTS logs in full</b>: an .rlog or logger file, and a live HTS datalog, now give all of their 90-odd values &mdash; where the engine is in the maps, every fuel and ignition correction, the inputs and outputs, the HTS features&#39; states, the boost controller, the analog and emulator inputs, the wideband and EGT channels &mdash; where they gave 15. Opening a log while logging live shows the log, and the channel lists follow the log open rather than an earlier session.',
 'The simulator&#39;s own datalog connects to HTS115 and HTS120 again: on a slow PC it timed out by the clock before the simulated ECU had answered, and picked the wrong protocol. It now waits in the ECU&#39;s time.',
 'The values list and the graph follow the channels picked, live, and a channel the ROM connected cannot send is said &mdash; greyed in Datalogging &gt; Channels, named on the datalog page with how to add it &mdash; instead of being left out quietly. Picking channels while logging with another protocol offers to switch to the channel stream that sends them.',
 '<b style="color:#fff">Pick several values</b> on the datalog page &mdash; Ctrl+click, Shift+click, or drag a box over them &mdash; and <b style="color:#fff">right-click for gauges</b> of them: dials, bars, numbers, rolling graphs or lamps on the dashboard (or one of each kind that suits), or floating together in a widget; or copy them.']],
 ['head'=>'more_rom_features', 'items'=>[
 '<b style="color:#fff">Hard disable</b> on the Check engine page: a code detected or stored can be taken out of the ROM&#39;s code itself &mdash; every instruction that sets its fault bit becomes NOPs of the same length, and with the source open the lines are changed to match &mdash; rather than only switched off in the calibration.',
 'The chip view has the board&#39;s <b style="color:#fff">8255 GPIO expander</b> behind a tab on the processor &mdash; hover it for what the 8255 does, click to bring it out beside the processor with its <b style="color:#fff">traces</b> from P0 and P1, lit as they switch &mdash; live: port B and C pins with what they drive on the car (A/C clutch, EVAP purge, alternator, fan, A/T lock-up, fuel pump, VTEC, O2 heater, check-engine lamp, the ECU&#39;s LED) and port A&#39;s switches, which a click toggles. P4.2 is the EGR output and P4.3 the EBC&#39;s boost solenoid.',
 '<b style="color:#fff">File &gt; Change functions</b>: add functions to a ROM you already have, or take them out, and keep its tune &mdash; VTEC control after a VTEC conversion, a datalog, launch control. Every setting and map the two builds share is carried across by name to wherever the new build put it. Works from the build file or from a <span style="font-family:var(--mono)">.bin</span> on its own: every skeleton build now carries a few bytes saying which functions it has.',
 '<b style="color:#fff">VTEC</b>: the skeleton&#39;s VTEC page has everything the established software offers &mdash; high and low load engage points against throttle, a disengage margin, minimum coolant, speed and load, each check able to be switched off, VTEC off altogether, and the alternative output &mdash; and the stock points as rows of their own. HTS120&#39;s disengage delay is on its page too. VTEC control is in Default.',
 '<b style="color:#fff">HTS115</b> is a template under File &gt; New ROM: the most fully annotated ROM there is.',
 'A MAP sensor swap now moves every pressure the ROM holds &mdash; the load breakpoints of every map, and settings such as a boost cut or a GIO window &mdash; through each one&#39;s own formula, and records the sensor in the ROM so its pressures and the datalog&#39;s MAP read true.']],
 ['head'=>'injectors_and_fuel_scaling', 'items'=>[
 '<b style="color:#fff">Dead times</b>: Injector size picks the injector from 138 presets &mdash; its dead time against battery voltage and its size together &mdash; or takes its 7 points typed in from the data sheet, and <b style="color:#fff">Save as my own</b> keeps them to pick again on any ROM and in the Set-up wizard.',
 '<b style="color:#fff">The injector offset is in real milliseconds</b>. HTS ROMs add it to every pulse in the injector timer&#39;s 3.2&nbsp;&micro;s counts, checked in the simulator; the established software writes ms &times; 8 there, so the 1.00&nbsp;ms it shows adds 0.026&nbsp;ms &mdash; which is why the wrong value had to be typed to get it right. Here 1.00 is 1.00. An offset set by the other software now shows what it really adds.',
 '<b style="color:#fff">Fuel scaling</b>: a skeleton ROM&#39;s injector size setting now multiplies the fuel, the other functions&#39; trims with it, rather than adding to them: twice the injector with a +10&nbsp;% trim gives 0.55, not 0.60. It reaches from 1/16 to double the fuel. The size change is made once &mdash; the ROM&#39;s own setting or the maps, never both &mdash; and an HTS multiplier past the x2 it holds has the maps take the rest instead of wrapping round to a small number. <b style="color:var(--amber)">Rebuild a skeleton ROM that uses injector scaling with a trim.</b>']],
 ['head'=>'set_up_wizard', 'items'=>[
 '<b style="color:#fff">File &gt; Set-up wizard</b> sets a ROM up the way the established tuning software sets up a new base ROM, page by page, with its presets: the <b style="color:#fff">stock maps of 25 ECUs</b> to start from (D15, D16, B16A, B17, B18, H22, F22 and more), VTEC and the rev limit, the injectors with <b style="color:#fff">138 injector lag curves</b>, the MAP sensor, <b style="color:#fff">14 gearboxes</b>, boost (load columns spread to the boost, fuel and timing per bar and psi, a boost cut) and the ROM options. Offered as soon as a new ROM is made, on HTS115, HTS120 and skeleton ROMs alike; nothing is written until the last page lists it all, and it lands as one undo step (<a href="docs/setup.html" style="color:var(--green)">how</a>).']],
 ['head'=>'a_custom_rom_that_boots_on_the_car', 'items'=>[
 '<b style="color:#fff">In short:</b> a ROM built with some of the extra functions could keep resetting the ECU on a real car. That is fixed &mdash; rebuild any skeleton ROM made with 0.0.0.3. The details, for those who want them:',
 'A skeleton ROM with the stock functions booted on the car; the same ROM with some modules added <b style="color:#fff">never finished booting, and every output strobed</b> &mdash; the ECU resetting over and over. The cause: the stock clock self-test (<span style="font-family:var(--mono)">FEAT_STOCK_SELFTEST</span>) runs on every pass of the main loop, not only at power-up. It reads the timers, lets interrupts in for <i>one instruction</i>, reads them again and resets the ECU (<span style="font-family:var(--mono)">BRK 4Bh</span>) if they moved too far. Stock let timers 0, 1 and 2 into that window; timer 1 is the 2&nbsp;ms tick that also carries the modules&#39; tick code, and with some modules that grows from about 40&nbsp;&micro;s to 300 &mdash; long enough to fail the check whenever it lands in the window. Timer 2 re-enabled everything on its way out, letting the half-millisecond crank interrupt in too. Stock alone never failed because its tick is short.',
 'The fix is one instruction: only timer 0, whose handler never touches the interrupt mask, is let into the window. The check still checks the timers. <b style="color:var(--amber)">Rebuild any skeleton ROM made with 0.0.0.3.</b>',
 'How it was found, and how it stays found: a new <span style="font-family:var(--mono)">--hwcheck</span> in the skeleton test harness runs every build from power-up as real hardware sees it &mdash; RAM full of rubbish rather than zeros, the longest gap between watchdog clears and heartbeat changes against the stock build, every trap with the interrupts taken just before it. <span style="font-family:var(--mono)">--offcheck</span> checks every executed <span style="font-family:var(--mono)">off()</span> operand ran on the RAM page its source meant. Run over 350 builds &mdash; stock with each module, random mixes, every switch on &mdash; none now does worse than stock. A <span style="font-family:var(--mono)">--pairs</span> mode builds every pair of modules the builder lets be ticked together, with every stock function, to run the same check on each.']],
 ['head'=>'more_guard_rails_on_custom_roms', 'items'=>[
 '<b style="color:#fff">An interrupt time bar</b> in File &gt; New ROM &gt; Create counts the time the 2&nbsp;ms tick and the crank interrupt take with the functions picked, measured by running the build, against what the ECU can spare &mdash; amber when it gets close, red when a pick would starve the main loop.',
 '<b style="color:#fff">File &gt; New ROM &gt; Create</b> checks the ROM before it is written. A <b style="color:#fff">module RAM bar</b> beside the ROM-space bar: the 56 bytes modules keep their state in, a colour per module, who has which bytes on the tip, red when the pick wants more than there is. A <b style="color:#fff">checklist</b> of ticks and crosses &mdash; rev limiter, fail-safes, datalogging, engine protection, ROM space, module RAM &mdash; and the warnings that matter, worst first: <i>No datalogging protocols in this ROM</i>, <i>No safeties in this ROM</i>, <i>No fail-safes</i>, <i>Boost control without boost cut</i>, <i>Anti-start</i>, the ROM or RAM nearly full; and the notes: a wideband or ethanol sensor needed, the check-engine lamp shared, modules starting switched off.',
 'Warnings are said once more before anything is written, to go back or create anyway; anything that stops the build keeps Create off. A new pick starts from a <b style="color:#fff">safe base</b>: the skeleton&#39;s own rev limiter (always in), the stock trouble codes and fail-safes, the self-tests, a datalogging protocol and coolant temperature protection.',
 'Programmable outputs pick their pin on a page, which a build cannot see: the <b style="color:#fff">Problems</b> tab now lists two functions switched on and set to the same ECU pin, or a pin a built-in stock function drives too, and the status line says so the moment one is set.']],
 ['head'=>'safe_limits_on_every_value', 'items'=>[
 'Every value written &mdash; a table cell, a setting, a feature page, an MCP client, <span style="font-family:var(--mono)">okisim set</span> &mdash; is held to what the ECU and the engine can use: rpm settings to 12,500, ignition advance to &minus;6&hellip;50&deg;, throttle and duty 0&ndash;100&nbsp;%, AFR 5&ndash;30, a list of choices to the choices it has, a sensor voltage to 0&ndash;5&nbsp;V, and a definition&#39;s own limits on top. A typo is capped, not written; the editors show the range, and a ROM already set outside it is never changed just by opening its page.',
 'The simulator&#39;s engine inputs are held to what their sensors can report, whether set by a slider, a car&#39;s datalog, an MCP client or the command line; a value that is not a number is ignored.']],
 ['head'=>'a_full_review', 'items'=>[
 '<b style="color:#fff">The simulator is about twice as fast</b> (a stock ROM at 1.9 to 3.8 million instructions a second on the command line, identical results). The time went on things done after every single instruction: the timers were worked out with eight 64-bit divisions and read through the full port decode, two tables were built anew, a fresh object and a fresh string were made for each instruction, and the interrupt check wrote its registers back whether or not they had changed. All of that is now direct or worked out once.',
 'On Windows the run loop&#39;s <span style="font-family:var(--mono)">Sleep(1)</span> between slices really slept 10&ndash;15&nbsp;ms, so at &ldquo;unlimited&rdquo; speed three quarters of the time was spent waiting (1.1 million instructions a second where the loop could do 3.5). The program now asks for 1&nbsp;ms sleeps while the simulator or the datalog runs, and gives them back when they stop: a low-power laptop gets its speed and its datalog rate back.',
 '<b style="color:#fff">The MCP server</b> now refuses requests from web pages: a plain-text POST from a page in your browser needed no permission, so with no password set any site could have driven it. It checks the origin and the host name; the lock-out after five wrong passwords now starts counting again once it has run out; and a folder link or junction inside the workspace that points outside it is refused like a file link is.',
 'Smaller: a datalog feed polled from a file or address no longer leaks a JSON document at every poll; settings that are written out reuse one serialiser instead of building one each time; the datalog smoother allocates nothing per reading, and asking for fewer frames now shrinks its window at once (it used to keep the old size until reconnect); the updater&#39;s &ldquo;inside my folder&rdquo; check needs the separator (<span style="font-family:var(--mono)">C:\App2</span> is not inside <span style="font-family:var(--mono)">C:\App</span>); an update found at start-up now asks in a message box.',
 'And a check for the limits: <span style="font-family:var(--mono)">--limitscheck</span> caught three of the new value limits being tighter than values the shipped ROMs hold (throttle axes past 100&nbsp;%, timing trims past 20&deg;, a MAP scaling below 0), and the rpm cap 11,000 below HTS120&#39;s own 12,500 limits: fixed, and the check now runs for every value in every shipped ROM and every choice on every page.']],
 ['head'=>'a_guide_for_everything', 'items'=>[
 'A <a href="docs/" style="color:var(--green)">guide</a> of HTML pages, one per part of the program: getting started, the two modes, the workbench, stepping and breakpoints, memory and hit trace, creating a custom ROM, every function and module, tables and settings, definitions and Detect, datalogging, gauges and widgets, emulators and flashing, projects, the tools, settings, keyboard shortcuts, plugins, the MCP server and command line, troubleshooting and the licence &mdash; with pictures of the program as it is now.',
 'The page of every function is written from the modules&#39; own headers by the test harness (<span style="font-family:var(--mono)">--docs</span>), with each module&#39;s ROM and RAM cost measured by building it &mdash; which caught four headers stating the wrong RAM, now corrected, and five output lists that stopped at 6 when the library drives 0&ndash;9.']],
];

$release006 = [
 ['head'=>'cuts_that_hold', 'items'=>[
 '<b style="color:#fff">A cut is a cut</b>: while a rev limiter, boost cut or any other function cut the fuel, the skeleton only stopped adding injectors to the ones it fires, and an injector already in that set went on firing now and then &mdash; 7 to 24 injections a second still got through a boost cut at full throttle. Now no injector opens at all while any fuel cut is held.',
 '<b style="color:#fff">No more over-rev on a fast-climbing engine</b>: the ECU only works its rpm out every few revolutions, and the limiters looked at it every 33 ms, so an engine climbing 15,000 rpm a second went up to 470 rpm past a rev limit before the fuel went. The rev limits are now also checked in the crank interrupt on every reading, looking ahead while the rpm climbs: in the simulator no injection now fires past the limit at 3,000, 8,000 or 15,000 rpm a second (a very fast climb is cut up to 5 % early instead). An ignition-cut limiter keeps its sound at the limit; only if the engine still gets 1.6 % past it does the fuel go too.',
 'Far past the limit (10,500 rpm and up) the ECU&#39;s rpm reading can fail and read as the engine stopped, and the stock code then started fuelling again as if starting. The over-rev cut now holds through an unreadable reading and lets go only once a good one is back under the limit.',
 'The <b style="color:#fff">boost cut</b> looks at the boost every 2 ms instead of every 33 ms (overshoot at a fast spool-up about halved), and the remote control can no longer raise the boost cut above the tune&#39;s own unless the tune allows it.']],
 ['head'=>'remote_control', 'items'=>[
 '<b style="color:#fff">Remote control commands</b>, a new module: a phone, a tablet or a box of buttons on the datalog cable can switch the <b style="color:#fff">radiator fan</b> on or off, set and read a <b style="color:#fff">rev limit</b> and a <b style="color:#fff">speed limit</b>, set the <b style="color:#fff">boost cut</b> and the <b style="color:#fff">VTEC point</b>, and turn <b style="color:#fff">popcorn mode</b> on &mdash; off the throttle the fuel stays on, the timing comes out and the sparks are cut in turn, for pops on the overrun. Everything set this way is forgotten at the next key-on.',
 '<b style="color:#fff">Codes and service</b> has a Remote control section with every command as a button, so a panel&#39;s behaviour can be tried on the simulator first; the Limiters channel shows the remote limits and popcorn mode while they cut. A new guide page lists <b style="color:#fff">every byte a skeleton ROM understands</b> on its cable, with Python and Arduino examples of a panel (<a href="docs/remote.html" style="color:var(--green)">how to build one</a>).',
 'The speed limiter by switch, and every other module with a one-hot input list, can now take <b style="color:#fff">serial inputs 1&ndash;8</b> as its switch.',
 '<b style="color:#fff">Exact values, no steps</b>: the boost cut and the VTEC point are set to a value you type, like the rev and speed limits &mdash; in your own units in Codes and service, as a byte over the cable &mdash; and each has Set, Clear and Read; everything the ECU has is read when the window opens.',
 '<b style="color:#fff">No password, no start</b>: with the lock on the engine will not run until a password is sent. Two passwords, each a number 0&ndash;65535: the <b style="color:#fff">main</b> one runs the engine as tuned, the <b style="color:#fff">guest</b> one in <b style="color:#fff">valet mode</b> (its own rev limit, speed limit and softer timing).',
 'The remote control settings moved to <b style="color:#fff">Added features &gt; Serial port</b> (the Datalog page renamed: it holds everything on the serial link), beside the service commands.',
 '<b style="color:#fff">Valet mode instead of no start</b>: a new option for the lock &mdash; no password, or a wrong one, starts the engine anyway, held to valet mode&#39;s limits and timing, until the main password is sent; Lock (2Eh) then drops it back to valet mode.',
 '<b style="color:#fff">More to set over the cable</b> (2Ch to set, 2Bh to read): the <b style="color:#fff">shift light</b> point, <b style="color:#fff">fuel or ignition cut</b> for the rev limiter and launch control, the <b style="color:#fff">two-step launch rpm</b>, and <b style="color:#fff">rolling idle</b> on or off, what it leaves out and one in how many. Each checked on the simulated engine; a limiter changing its cut type while cutting never lets the engine past its limit.',
 'Codes and service reads every value when it opens, and a value not set shows the tune&#39;s own (from the ROM open) instead of 0; the boost cut is shown in your boost unit from Settings &gt; Units, as boost above the air outside. Rows for functions the ROM does not have are greyed out.']],
 ['head'=>'annotating_with_a_model', 'items'=>[
 '<b style="color:#fff">Watch a model annotate a ROM</b>: with the ROM open in the app, an MCP client&#39;s renames, comments and file edits show as they are made &mdash; in the editor (your caret and scroll kept), the disassembly, Lookup &amp; breakpoints and the Calibration pages &mdash; built and patched in without a reset, and a change that breaks the build is reported back with its errors.',
 '<b style="color:#fff">One naming standard</b> for every name a model gives, so a ROM named by Qwen, Claude or anyone else reads as one: code labels in lower_snake_case starting with the part of the ECU, calibration data in PascalCase, RAM after what it holds (<a href="docs/mcp.html#annotating" style="color:var(--green)">the standard</a>).',
 'New MCP tools for it: <b style="color:#fff">naming_guide</b>, <b style="color:#fff">annotate_todo</b> (what is still unnamed, most-used first, and how far the ROM is), <b style="color:#fff">rename</b> (everywhere it is used, checked against the standard), <b style="color:#fff">comment</b> and <b style="color:#fff">name_check</b>.',
 'Cross-references now find the branches to a label (JNE, SJ, CAL...), not only its word operands, and no longer report bytes that merely spell the address across two fields.']],
 ['head'=>'tidier_pages_and_fixes', 'items'=>[
 'The settings pages are lined up: every input box, drop-down and tick box the same width and in one column, table buttons no wider than the boxes (the full name on hover), units in a column of their own that wraps, and the reset button no longer covering text.',
 '<b style="color:#fff">Gear detection and gearbox presets</b> on the Transmission page: the gearbox presets of the established software, and <b style="color:#fff">Gear learning</b> &mdash; drive in each gear and press its button, and the ratios are measured from the datalog.',
 'The ROM checksum on the Options page shows green when it is right, and red with a <b style="color:#fff">Recalculate</b> button when it is not.',
 'Tables with a log over them have a button beside <b style="color:#fff">Show as</b> that swaps which number is large in each cell: the map&#39;s value or the logged one.',
 'The Problems list: right-click to copy a message, its line or all of them.',
 'A project saved by someone else now opens with the files its ROM includes: they are saved in the project, and an older one finds them in the templates.',
 'Hard-disabling some trouble codes left the ROM unable to build (an undefined label): the line&#39;s label is kept now, checked for every code.',
 'Clear codes from Codes and service turns the check-engine lamp off in the window at once, as it does on the ECU, instead of after the next frame.',
 'Codes and service: every button shows what the ECU is doing now &mdash; green when in use, red for the injectors off, timing locked, fan held off and popcorn &mdash; where Injectors off, Lock timing and Popcorn mode had lost their background altogether.',
 'The Datalog channels search finds what each row shows and says: <i>rolling</i> finds rolling idle&#39;s bytes, and words are found in any order, with or without spaces and underscores.',
 'The Datalog page&#39;s status is one line; hover it for the whole of it (what the ROM said when the channels were taken).',
 'Codes and service keeps its buttons lined up at any width: every row of buttons in the same four columns, a long label (Lock timing at 16&deg;) wrapping inside its button rather than pushing it onto a line of its own, and the remote values in one grid of names, boxes, units and Set / Clear / Read.',
 '<b style="color:#fff">Rev limits page for the built ROMs</b>: the rev limiter, the <b style="color:#fff">speed limiter by switch</b> (what was listed as &ldquo;Sw limit&rdquo;: a road speed limit worked by a switch &mdash; a pit lane or valet limit on a button), the rpm ceilings, the limit by gear and the ignition cut shaping, each explained; its switch list now matches the module&#39;s inputs.',
 'Every setting of the added functions says what it does on hover: the switches that turn a function on now say what the function does, and a row with no help of its own shows its setting&#39;s description.',
 '<b style="color:#fff">Right-click menus</b>: in the source editor (cut, copy, paste, go to a label&#39;s definition, go to its table, find all references, copy its address, a breakpoint on the line), and the Disassembly and Trace lists (breakpoint, go to the source, find references, copy). Right-clicking the Disassembly again no longer stacks menu on menu.',
 'The skeleton ROM&#39;s source is tidier: the notes left by the tools that made it, and the old addresses and bytes after the vectors, are gone. It also comes out up to 20 bytes smaller with the stock functions in: instructions no path could reach in that build are left out.',
 '<b style="color:#fff">Two stock-function combinations fixed</b>: with the automatic gearbox code but without the trouble codes, the idle routine ran on into the gearbox&#39;s ignition code; and the EVAP purge without the trouble codes lost its coolant and counter checks. Found by a new check that follows every build&#39;s code paths.']],
 ['head'=>'a_double_check_of_every_function', 'items'=>[
 '<b style="color:#fff">Every function driven hard in the simulator</b> &mdash; each module alone and in the biggest mixes that fit, every switch on, through cranking, a cold idle, full boost at 7000 rpm, over-rev, a launch, decel, a hot engine and a low battery &mdash; with a new check that every byte and word instruction runs in the mode its source says (the same opcode is a byte or a word instruction by a CPU flag), and that nothing faults, resets or overflows the stack. The stock P30 ROM is run the same way as the yardstick.',
 '<b style="color:#fff">Boost cut&#39;s 2 ms look read the wrong bytes</b>: it ran on the tick&#39;s RAM page and missed whether the cut was already on. Fixed (found by the page check).',
 '<b style="color:#fff">Over-rev, when the rpm reading fails</b>: far over the limit with many functions built in, the ECU can lose crank teeth and read the engine as stopped, and the over-rev cut then let go. A reading that fails right after one near the limit now cuts the fuel until a good one comes back.',
 '<b style="color:#fff">The tick is faster</b>: it looks at the tick count once and jumps to the functions on that tick&#39;s slot, instead of every function asking whether it is its turn: about 30 us less every 2 ms with many functions in. The remote control commands, the heaviest, now take two slots (their worst tick 686 &rarr; under 460 us).',
 '<b style="color:#fff">Tachometer output</b>: it changed outputs through a routine meant for the tick, from the spark interrupt, where the tick can come in half way through and undo a change; now it flips its own pin directly, with the tick held off for the few instructions it takes, and costs a third less of every spark interrupt.',
 'The New ROM window&#39;s ROM space, module RAM and interrupt time meters are lined up in one grid: the bars start and end together, each figure sits at the right, and what it means &mdash; a warning too &mdash; goes on the line under its bar instead of squeezing it. The timing run also says when the rpm reading failed at 6800, 7000 and 7200 rpm alike: a mix too much for the CPU at high rpm.',
 'New harness checks for anyone building modules: <b style="color:#fff">--modecheck</b>, <b style="color:#fff">--tickprofile</b> and <b style="color:#fff">--hwroms</b> (random mixes for the car, checked in the simulator first).']],
 ['head'=>'nitrous_boost_and_alpha_n', 'items'=>[
 '<b style="color:#fff">Nitrous (N2O)</b>, a new module: while armed, at wide throttle and inside its rpm window, a second fuel and ignition map (tuned for the base shot) is blended in and an output drives the solenoid. A <b style="color:#fff">shot input</b> &mdash; a voltage on a free pin or a serial input over the datalog cable &mdash; scales how far those maps are from the normal ones through a shot table: 100 % at 0 V for the base jet, 150 % at 1 V, 200 % at 2 V (50, 75 and 100 hp), blended between the points.',
 '<b style="color:#fff">Tools &gt; Scale for boost</b>: a base map for a turbo or supercharger conversion from the natural-aspiration maps you have. The load axis keeps its atmospheric part and gains boost columns up to the boost you set; in them the fuel rises with the pressure (100 % = in step with it, 120 % a fifth richer) and the timing comes out a set amount a psi (0.75 degree, say). It checks the MAP sensor can read that much boost first.',
 '<b style="color:#fff">Tools &gt; Scale for alpha-N</b>: the throttle as the load at wider throttle with MAP below a crossover (individual throttle bodies, big cams): the load axis split, the throttle table and crossovers set and alpha-N switched on, the maps resampled to start where they were.',
 'New ROM: a <b style="color:#fff">search box</b> over the function list (part of a name or of what it does, any order). A ROM too big says only &ldquo;Too big: over the limit by X bytes&rdquo; under its bar, and the bar&#39;s tooltip lists what to take out instead of the usual text; the module RAM message says it plainly, with the same in its bar&#39;s tooltip. Long size notes beside a function no longer run off the list.',
 'The tachometer output and the warning lamp used the same state bit; the tach now keeps its own.']],
 ['head'=>'a_faster_datalog_line', 'items'=>[
 '<b style="color:#fff">Logging never takes the engine&#39;s time</b>: every byte costs the ECU about a tenth of a millisecond, and at high rpm a stream sent flat out took most of what its main loop had left &mdash; in the simulator at 8,000 rpm the spark was worked out 3 times a second instead of 19. A ROM made here now paces what it sends by its spark calculation, a few bytes each time, fewer the higher the rpm: the spark is worked out as often as with no logging (97 % on average from idle to 8,000 rpm, never two calculations missed in a row), for about 400 bytes a second at cruise and 50&ndash;80 at the limit. With the engine stopped it sends as fast as the line goes.',
 '<b style="color:#fff">62,500 baud</b>: a ROM made here can run its datalog line at 62,500 instead of 38,400 (Serial port page): frames come in sooner, and faster with the engine stopped. It needs a cable that can be set to exactly 62,500 (an FTDI one can) and the same rate in Settings &gt; Datalog; 38,400 stays the default for HTS and other loggers. The app warns when the ROM and the link are set to different speeds.',
 'The channel stream&#39;s transmit interrupt takes a short way for the bytes it sends most (the frame start, the tick and the fast channels): from 140 to about 100 microseconds a byte, so more data for less of the engine&#39;s time.',
 'The simulator now sends each byte at the rate the ROM set its serial port to (it used a fixed, slower rate before, which is where the old &ldquo;about 870 bytes a second&rdquo; came from). A link set to another speed than the ROM&#39;s reads garbage, as on a car.']],
];

$release007 = [
 ['head'=>'the_p13_builds_too', 'items'=>[
 '<b style="color:#fff">A P13 skeleton</b> (the MSM66911 ECUs of the Prelude and others): stock P13, every reference in it turned into a label so code can move, and the same seams as the P30 one &mdash; hook slots at 7F00h, an info block, a module tick every 2.048 ms, fuel-cut, spark-cut and retard requests, an over-rev latch in the crank interrupt. <b style="color:#fff">All thirteen stock functions</b> can be left out or put back as on the P30 (trouble codes, closed loop, the O2 heater, EGR, knock, VTEC pressure, the speed limiter, the high-cam VE curve, the automatic, purge, A/C, the self-tests and the stock serial link), and <b style="color:#fff">all 56 modules</b> are ported, in their own <span style="font-family:var(--mono)">roms/p13-features</span> folder.',
 '<b style="color:#fff">File &gt; New ROM &gt; Create</b> offers it in the Base list: the app switches to the MSM66911 when it is picked, its Default keeps the stock knock control (P13 engines have the sensor), and its interrupt meter runs the pick on its own part in a second process. A build file says which part it is for, and a P13 .bin is recognised by its vectors.',
 'The stock P13 tables its code reads are named and scaled &mdash; the maps (fuel maps that are open-loop <b style="color:#fff">enrichments</b> on the P13, 100 % = none), the rev limiter, VTEC points, dead time, cranking, warm-up, tip-in, idle targets, decel cut and the rest &mdash; so the calibration pages, the set-up wizard (a bigger MAP sensor, boost) and the datalog work on it as on the P30.',
 'The simulated P13 got truer on the way: the knock processor&#39;s lines, the signals the stock code insists keep changing, the battery input, the EGR lift loop, the O2 sensor going lean in a fuel cut, the VTEC solenoid and its pressure switch, and the starter signal (the simulated ECU thought it was always cranking). A stock P13 now runs in the simulator with no false trouble codes.',
 '<b style="color:var(--amber)">The P13 skeleton has not been run on a car.</b> It is checked in the simulator only &mdash; New ROM says so before it writes one. Simulate it thoroughly and treat the first start with extra care.']],
 ['head'=>'romsimtuner_on_its_own', 'items'=>[
 '<b style="color:#fff">RomSimTuner</b>, a second download: just the tuning part of Rom Sim Studio &mdash; the calibration editor, live datalogging and the ROM emulator, what Tuner mode shows &mdash; as a program of its own, with no simulator, MCP server or plugins in it. Nothing in it but tuning, and it needs only the .NET 10 Runtime (not the ASP.NET Core one). Built from the same source files as Rom Sim Studio, so a fix in one is a fix in both.',
 'It keeps its own settings (the first time it starts it takes Rom Sim Studio&#39;s, so the cable, the emulator and the look carry over), and it can sit in the same folder as Rom Sim Studio or a folder of its own.',
 '<b style="color:#fff">It checks for updates too</b>: Settings &gt; Updates, and a quiet check a few seconds after it opens (it can be turned off). The site keeps a separate list for each program, so one never fetches the other&#39;s files. <span style="font-family:var(--mono)">RomSimTuner --update-check [folder]</span> prints what it would offer; <span style="font-family:var(--mono)">RomSimTuner --selftest &lt;rom.bin|build.asm&gt;</span> runs its tuning paths (open, definitions, an edit, undo, the checksum, save) with no window, PASS / FAIL.']],
 ['head'=>'find_the_fault_on_the_car', 'items'=>[
 '<b style="color:#fff">Datalogging &gt; Trigger pattern</b>: the distributor&#39;s crank (CKP), TDC and cylinder (CYP) signals as the ECU sees them, a cam revolution at a time, as bars &mdash; each crank tooth&#39;s time, the TDC and cylinder pulses under the teeth they came with. A healthy engine gives 24 even bars, a TDC pulse every sixth tooth and one cylinder pulse three teeth after cylinder 1&#39;s TDC; a missed crank pulse shows as a bar twice as tall, noise as two short ones, a TDC or cylinder pulse missing or out of place in its row &mdash; and the window says which sensor and what to check. One capture, or one every 2 s, every 1 s or in real time (back to back, about three a second) to catch a fault that comes and goes; a capture lost on the line is counted and the last good one stays up. In the simulator each fault can be put on the signals to see what it looks like.',
 '<b style="color:#fff">Trigger pattern log</b>, a new ROM function behind it: asked over the datalog cable, the ECU records the next 24 crank teeth (timer 2&#39;s capture, 3.2 us) with the TDC and cylinder pulses that came with each, and sends them back. Until it is asked, it costs one bit test a crank tooth; it works cranking too, for a no-start.',
 '<b style="color:#fff">The cylinder test</b> (Codes and service): cut one cylinder&#39;s injector at a time over the datalog cable &mdash; on an engine running on three, the cylinder whose cut makes no difference is the one not firing. Only one is ever cut (the one before comes back first), the check-engine lamp flashes while it is, and All back to normal or a key cycle ends it.']],
 ['head'=>'a_final_double_check', 'items'=>[
 '<b style="color:#fff">P13: no more resets at over-rev.</b> At 9500 rpm the crank interrupts take most of the P13&#39;s time, and the skeleton&#39;s over-rev latch, worked out on every crank tooth, took enough more that the main program could not get round in 20 ms with the rev limiter module on &mdash; the ECU&#39;s own runaway check then reset it. The latch now works on every third tooth (twice a cylinder, half its six-tooth window new each time), unrolled: the main program gets round 24 times in the over-rev test instead of once.',
 '<b style="color:#fff">P13 tachometer output</b>: it now looks at the coil before saving anything, and does the full work only when its level changes &mdash; it runs on the ignition interrupt, three times a spark, and was one of the things that left the main program short at high rpm.',
 '<b style="color:#fff">P13: three byte/word slips fixed</b> (the CPU&#39;s byte/word mode left over from the instruction before): two boot stores ran as word stores, one writing past a table into 1ABh; and the injector gate for the start-up and asynchronous pulses ANDed a word, so the cylinder test&#39;s mask was read together with the service commands&#39; state. Found by the mode check, now run on the P13 too.',
 '<b style="color:#fff">P13 module RAM</b>: the module library kept two bytes empty that only the P30 needs empty. Freed, the trigger pattern log fits beside the channel stream and a rev limit on the P13 (it was two bytes short).',
 '<b style="color:#fff">New ROM&#39;s interrupt meter</b> now also counts the ECU resetting itself; on a P13 pick it runs on to 9200 rpm, where a mix of very many modules with every stock function is too much for the CPU and is shown in red.',
 'The output clash check (Problems) knew only the P30&#39;s pins: on a P13 ROM it named the wrong pins and could report boost control clashing with the automatic, which the P13 drives elsewhere. It now uses each skeleton&#39;s own pins. The P13 modules&#39; descriptions had the P30&#39;s pins and RAM addresses in places; they are the P13&#39;s now.',
 '<b style="color:#fff">Detect</b> lines an unlabelled ROM up against the shipped sources for its own processor: a P13 .bin against the P13 skeleton, a P28-family one against the P30 and the rest. Before, whichever ROM was opened first decided which of them could be loaded at all.',
 'The MCP server on its own (<span style="font-family:var(--mono)">--mcp</span>, romsim-mcp) works on each file as the part it is for, so a P13 source or .bin assembles and runs as a P13; a P13 .bin disassembled says so in its first lines.',
 'Run as <span style="font-family:var(--mono)">dotnet RomSimStudio.dll</span> (Linux, macOS), the P13 interrupt meter&#39;s helper and the Settings &gt; MCP server snippet started the dotnet host without the program; they start it properly now.',
 'The simulated MSM66911 no longer builds an array on every instruction (or checks eight registers on every RAM write): P13 ROMs run faster on a slow laptop.',
 'Stock P13 calibration holds up to 51.5 degrees at light load: the advance limit on the P13 is 52 degrees, so opening those maps never caps them.',
 'The P30 skeleton&#39;s own notes now say what is true: ROMs built from it have run on a car.']],
 ['head'=>'fixes', 'items'=>[
 'The simulator now lives in a library of its own (OkiRomSim.Sim), apart from the decoder, the profiles and the chip facts the tuner needs; the ROM, its edits, undo and the emulator interlock moved to one place both programs share.',
 '<b style="color:#fff">A regression test runner</b> (<span style="font-family:var(--mono)">tests/OkiRomSim.Tests</span>): the assembler, the decoder, the calibration code, both programs&#39; references and a byte-for-byte image of every skeleton build, P30 and P13 &mdash; a change that moves a byte nobody meant to move fails it. <span style="font-family:var(--mono)">build-release.bat test</span> runs it before building.',
 '<span style="font-family:var(--mono)">build-release.bat</span> / <span style="font-family:var(--mono)">build-release.sh</span> build Rom Sim Studio, RomSimTuner or both, for every platform at once or one only (self-contained, or RomSimTuner as one file), and lay out the web site ready to upload: the page, the guide, both zips and both programs&#39; update lists.',
 'Change functions kept the build but dropped nitrous, remote control and the trigger pattern log from a rebuilt ROM (their numbers were missing from the build info): it keeps them now.',
 'File and Tools no longer shrink a little the first time the pointer goes over them (the emoji icons now have a fixed width).',
 '<b style="color:#fff">RomSimStudio --update-check [folder]</b> prints what the start-up update check would offer for the install in that folder.']],
];

$release = [
 ['head'=>'sensor_protection', 'items'=>[
 '<b style="color:#fff">Sensor protection (oil / fuel pressure)</b>, a new function for the P30 and the P13 skeletons: it watches any analog input &mdash; the ECUone of the board&#39;s four spare inputs, or one of eight more sent in over the serial inputs#39;s O2, ELD, EGR or B6 input, or one of eight more sent in over the datalog cable (the serial inputs) &mdash; and cuts when the reading goes below (or above) a level you set, above an rpm point, for longer than a delay. An oil pressure sender dropping out at 4000 rpm, a fuel pressure sender falling away under boost: the engine is cut before it is hurt. The cut is fuel, spark or both, as you choose; it lets go when the reading is back, or the rpm falls under the point. Its own page, a limiter channel in the datalog, and New ROM counts it as engine protection.']],
 ['head'=>'warm_up_and_boost', 'items'=>[
 '<b style="color:#fff">Coolant temperature protection</b> has a <b style="color:#fff">warm-up rev limit</b> now: a lower limit (4000 rpm, back on at 3800) while the coolant is under 40 &deg;C, so a cold engine is not revved out. It starts switched off; the rows are on the coolant protection page beside the hot-engine limit, which also gained its reset and cut-type rows (they were under More settings).',
 '<b style="color:#fff">Electronic boost control by gear</b>: with gear detection in the ROM, a duty cap for each gear (100 % = no cap), so first and second can be held back while the higher gears get the full boost. The row is <i>Boost by gear</i> on the boost control page.']],
 ['head'=>'fixes', 'items'=>[
 '<b style="color:#fff">Detect</b> has the stock P13 source as a reference too (<span style="font-family:var(--mono)">Templates/References/p13.asm</span>, fully labelled): an unlabelled P13 .bin is lined up against it as well as against the P13 skeleton. A P13 ROM is only compared with P13 sources, as it runs on another processor.',
 'The memory map and the datalog&#39;s names missed the channel stream&#39;s word-sized entries (engine speed at 0ACh, the injector time at 146h): they are named now. The check behind it runs on the P13 too.',
 'The P13 module library&#39;s notes listed the P30&#39;s RAM addresses; they are the P13&#39;s now.',
 'Every picture in the guide and on this page retaken from the current program (Tuner mode on the fuel map with a log replaying, the cylinder test, the dyno, the settings pages), and a picture of the trigger pattern window added to the guide.']],
];

/* Earlier releases, kept below the current one so the history is on the same page. */
$past = [
 ['v'=>'0.0.0.7','from'=>'0.0.0.6',
  'sub'=>'RomSimTuner, the tuning-only program on its own, the P13 builds too, finding the fault on the car (the distributor signals as bars, one cylinder cut at a time), and a final double check',
  'groups'=>$release007],
 ['v'=>'0.0.0.6','from'=>'0.0.0.5',
  'sub'=>'a double check of every function, nitrous, scale for boost and alpha-N, and logging that never takes the engine&#39;s time',
  'groups'=>$release006],
 ['v'=>'0.0.0.5','from'=>'0.0.0.3',
  'sub'=>'eight languages, a virtual dyno, a set-up wizard, and custom ROMs that boot on the car',
  'groups'=>$release005],
 ['v'=>'0.0.0.3','from'=>'0.0.0.2',
  'sub'=>'a ROM you build yourself, a plugin API, and a bench that works with the car, not just the chip',
  'groups'=>$release003],
 ['v'=>'0.0.0.2','from'=>'0.0.0.1',
  'sub'=>'the P13 joins the bench, the check-engine lamp tells the truth, and whole features become patchable',
  'groups'=>[
  ['head'=>'the_p13_runs', 'items'=>[
    'A full <b style="color:#fff">MSM66911 peripheral model</b>: the P13/P14 is not a 66207 with renamed registers &mdash; a free-running crank counter with capture channels, one-shot injector drivers, two PWM counters the ROM watches move before it will run, its own register map and its own 8255 decode (8000/A000/C000/E000).',
    'The processor profile now picks which on-chip peripherals get simulated, with P13 sensor conversions built in. A stock P13-N51 image boots, survives its runaway checks and injects.',
    'Two new datalog protocols, <b style="color:#fff">P13 46h</b> and <b style="color:#fff">P13 20h</b> &mdash; auto-detect probes the fixed-length frames first, because P13 loggers share the 66207 handshake.']],
  ['head'=>'the_lamp_tells_the_truth', 'items'=>[
    'The <b style="color:#fff">check-engine lamp</b> is simulated as the ROM drives it: the stored-code array, long and short flashes at the real cadence, the ROM\'s own renumbering (25&rarr;35, 26&rarr;36, 27&rarr;41, 29&rarr;43), dash lamp vs. flash line, the service-check connector jumper and the backup-fuse clear.',
    'A live <b style="color:#fff">MIL window</b>: the flashes decoding as they go, the codes the ROM has stored, and the faults it is detecting right now.']],
  ['head'=>'feature_pages', 'items'=>[
    'The rest of the ECU\'s options on pages of their own &mdash; the same pages, groups, labels and units as the established tuning software, and they are <b style="color:#fff">data, not code</b>: another page is a dozen lines.',
    'Rows name a slot, not an address: an HTS ROM binds every row by address from the 1.15 calibration layout, any other ROM binds them to its own detected definitions &mdash; and the binding travels with the definition.']],
  ['head'=>'feature_patches', 'items'=>[
    'Changes that add or remove a <i>behaviour</i>, not a map value: disable a trouble code, MIL off, known base-ROM fixes. Every patch carries the bytes it expects and writes only where it expects them &mdash; removing one puts back exactly what was there.',
    'Per-ROM variants, plus byte patterns that find the site in a ROM no variant was written for &mdash; but only where the pattern matches exactly once. At the CLI (<span style="font-family:var(--mono);color:var(--green)">okisim features</span>) and in MCP (<span style="font-family:var(--mono);color:var(--green)">cal_features</span>) too.']],
  ['head'=>'the_studio_grows', 'items'=>[
    '<b style="color:#fff">File &gt; New ROM</b> starts from a finished template. A dedicated datalog <b style="color:#fff">graph window</b>. AFR targets, correction curves and datalog O2/knock tables on grids shaped exactly like the fuel maps &mdash; same cells, same colours, same nudge and paste.',
    'Injector calibration, MAP sensor, and the AFR correction a datalog asks for, each in its own window: a preview line says what would change, nothing lands until Apply, and the whole thing is one undo step.',
    'The layout is drawn for 1080p and <b style="color:#fff">scales to fit smaller screens</b> (a 1366&times;768 laptop) instead of being squeezed. The Breakpoints page gains Add/Remove by label or address.']],
  ['head'=>'the_link_gets_tougher', 'items'=>[
    'Handshake hardening learned from the tools that work on real cars: the 10&nbsp;ms pause between request and answer &mdash; the single most common fix for a link that "does not work" &mdash; retries for an ECU that just saw power, and an echo read as miswiring rather than slowness.',
    'Long logs got lighter: raw-frame byte names are shared per protocol instead of copied into every frame &mdash; over 100&nbsp;MB saved on a long log.']],
  ['head'=>'agents_and_under_the_hood', 'items'=>[
    '<b style="color:#fff">42 MCP tools</b>, up from 39: <span style="font-family:var(--mono)">cal_features</span>, <span style="font-family:var(--mono)">app_open</span>, <span style="font-family:var(--mono)">transfer_dir</span> &mdash; an agent on another computer uploads a ROM into an always-writable transfer folder and opens it on the user\'s screen.',
    'One version number in one file (Directory.Build.props) reaches the title bar, Settings, the Debug page and the MCP handshake. The run loop hands the lock back every 4&nbsp;ms so the UI and the agent get in even at unlimited speed; a bad instruction stops the simulator, not the app.',
    'The P28 A/D mux map re-traced pin by pin against the ROM\'s RAM and its own datalog bytes &mdash; O2, ECT, IAT, battery and the load detector now sit where the datalog says they do; the 8255 decode comes from the profile (P28 0F00h&hellip;, P13 8000h&hellip;).']],
  ]],
];

/* The feature modules that ship with the skeleton ROMs (roms/p30-features, and the same set ported in roms/p13-features): category, name, define. */
$modules = [
 // Limits
 ['Limits','Burnout control','FEAT_BURNOUT'],
 ['Limits','Full throttle shift (flat shift)','FEAT_FTS'],
 ['Limits','Ignition cut modifier','FEAT_IGNCUTMOD'],
 ['Limits','Launch control (two-step)','FEAT_LAUNCH'],
 ['Limits','Rev limit by gear','FEAT_GEARLIMIT'],
 ['Limits','Rev limiter (ignition or fuel cut, per cam)','FEAT_REVLIMIT'],
 ['Limits','Rpm ceilings by road speed','FEAT_CEILING'],
 ['Limits','Speed limiter (always or by switch)','FEAT_SPEEDLIMIT'],
 // Driver aids
 ['Driver aids','Shift light on the check-engine lamp','FEAT_SHIFTLIGHT'],
 // Protection
 ['Protection','Anti-start','FEAT_ANTISTART'],
 ['Protection','Coolant temperature protection','FEAT_ECTPRO'],
 ['Protection','Lean protection','FEAT_LEANPRO'],
 ['Protection','Sensor protection (oil / fuel pressure)','FEAT_SENSORPRO'],
 // Boost
 ['Boost','Boost cut','FEAT_BOOSTCUT'],
 ['Boost','Electronic boost control','FEAT_EBC'],
 ['Boost','Manual boost controller','FEAT_BOOSTMANUAL'],
 ['Boost','Water / methanol injection','FEAT_WMI'],
 // Fuel
 ['Fuel','Closed loop on a wideband','FEAT_WBCL'],
 ['Fuel','Extended maps (20 load columns)','FEAT_EXTMAPS'],
 ['Fuel','Flex fuel','FEAT_FLEX'],
 ['Fuel','Fuel by gear','FEAT_GEARFUEL'],
 ['Fuel','Individual cylinder fuel trims','FEAT_CYLTRIM'],
 ['Fuel','Injector size and fuel trim','FEAT_FUELTRIM'],
 ['Fuel','Maps indexing (alpha-N)','FEAT_ALPHAN'],
 ['Fuel','Nitrous (N2O)','FEAT_NITROUS'],
 ['Fuel','Secondary maps (full fuel and ignition maps)','FEAT_DUALMAPS'],
 ['Fuel','Secondary tune on a switch','FEAT_MAPSWITCH'],
 // Ignition
 ['Ignition','Timing by gear','FEAT_GEARIGN'],
 ['Ignition','TPS tip-in retard','FEAT_TPSRETARD'],
 ['Ignition','Traction control','FEAT_TRACTION'],
 // Idle
 ['Idle','Anti-stall','FEAT_ANTISTALL'],
 ['Idle','Rolling idle','FEAT_ROLLIDLE'],
 // Outputs
 ['Outputs','A/C load disable','FEAT_ACCUT'],
 ['Outputs','GIO 1: programmable output','FEAT_GIO1'],
 ['Outputs','GIO 2: programmable output','FEAT_GIO2'],
 ['Outputs','GIO 3: programmable output','FEAT_GIO3'],
 ['Outputs','GIO 4: programmable output','FEAT_GIO4'],
 ['Outputs','IAB (intake butterflies)','FEAT_IAB'],
 ['Outputs','Rpm-switched output','FEAT_RPMSWITCH'],
 ['Outputs','Smart alternator','FEAT_SMARTALT'],
 ['Outputs','Tachometer output','FEAT_TACH'],
 ['Outputs','VTEC control and alternative output','FEAT_VTECCTL'],
 ['Outputs','Warning lamp (coolant / battery)','FEAT_WARNLAMP'],
 // Sensors
 ['Sensors','Gear detection','FEAT_GEAR'],
 ['Sensors','Road speed correction','FEAT_SPEEDCORR'],
 ['Sensors','TPS sensor end points','FEAT_TPSCAL'],
 // Options
 ['Options','Board options override','FEAT_CFGOVERRIDE'],
 ['Options','Watermark','FEAT_WATERMARK'],
 // Diagnostics
 ['Diagnostics','Datalogging: channel stream','FEAT_DLSTREAM'],
 ['Diagnostics','Datalogging: HTS / ISR frame','FEAT_DATALOG'],
 ['Diagnostics','Datalogging: QD3 frame','FEAT_DLQD3'],
 ['Diagnostics','Datalogging: service commands','FEAT_DLSERVICE'],
 ['Diagnostics','Datalogging: serial inputs','FEAT_DLSERIALIN'],
 ['Diagnostics','Datalogging: memory read','FEAT_DLMEMREAD'],
 ['Diagnostics','Datalogging: every channel','FEAT_DLEXTRA'],
 ['Diagnostics','Trigger pattern log','FEAT_TRIGLOG'],
 ['Diagnostics','Remote control commands','FEAT_REMOTE'],
];
?>

<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title><?= $project ?> &mdash; <?= $product ?>: tune and build ROMs for OBD1 Honda ECUs</title>
<link rel="icon" type="image/x-icon" href="favicon.ico">
<meta name="description" content="<?= $project ?>: a free program to tune OBD1 Honda ECUs (P28, P30, P72 and more) — edit the fuel and ignition maps, datalog the car, upload to an Ostrich or Demon emulator — and to build a ROM of your own from ready-made functions and test it on a simulated ECU and engine. Windows, Linux, macOS.">
<meta name="keywords" content="Honda OBD1 tuning, P28, P30, ECU tuning software, datalogging, fuel map, ignition map, Ostrich, Demon, OKI MSM66207, 66K, nX-8/200, ECU simulator, ROM tuning, HTS115, ECU datalogging, MCP server, LLM tuning, emulator, disassembler, calibration">
<style>
:root{
  --bg:#0a0e14; --bg2:#0f141c; --panel:#121924; --line:#212c3b; --line2:#2a3749;
  --amber:#f2a33a; --amberglow:rgba(242,163,58,.35);
  --green:#5cc8a1; --greendim:rgba(92,200,161,.12); --red:#ef6a5f; --text:#c9d3df; --muted:#8593a5; --head:#f3f6fa;
  --mono:'Cascadia Code','SF Mono','Consolas','Courier New',monospace;
  --sans:Inter,'Segoe UI',system-ui,-apple-system,Roboto,Arial,sans-serif;
  --wide:min(1240px, 94vw);
}
*{margin:0;padding:0;box-sizing:border-box}
html{scroll-behavior:smooth; overflow-x:hidden; scroll-padding-top:72px}
body{background:var(--bg); color:var(--text); font-family:var(--sans); font-size:16px; line-height:1.65; overflow-x:hidden;
  background-image:radial-gradient(1100px 500px at 50% -120px, rgba(242,163,58,.09), transparent 70%); background-repeat:no-repeat}
main,nav,footer{position:relative; z-index:1}
main > section{background:transparent; border:0; margin-bottom:0; border-top:1px solid var(--line)}
main > section:nth-of-type(even){background:var(--bg2)}
#hero{background:transparent !important; border-top:0 !important}
::selection{background:var(--amber); color:#000}
::-webkit-scrollbar{width:10px}::-webkit-scrollbar-track{background:var(--bg)}
::-webkit-scrollbar-thumb{background:#243044;border-radius:5px}
::-webkit-scrollbar-thumb:hover{background:var(--amber)}
@keyframes blink{50%{opacity:.4}}
@keyframes pinpulse{0%,100%{opacity:.35}50%{opacity:1}}
/* ---------- NAV / HERO ---------- */
nav{position:sticky; top:0; display:flex; align-items:center; gap:24px; padding:0 max(3vw,20px); height:60px;
  background:rgba(10,14,20,.88); backdrop-filter:blur(12px); -webkit-backdrop-filter:blur(12px); border-bottom:1px solid var(--line); z-index:10}
nav .logo{font-family:var(--sans); font-weight:800; font-size:1.15rem; letter-spacing:.5px; color:var(--head); white-space:nowrap}
nav .logo b{color:var(--amber)}
nav .links{margin-left:auto; display:flex; gap:22px; align-items:center; flex-wrap:nowrap; overflow-x:auto; scrollbar-width:none}
nav .links::-webkit-scrollbar{display:none}
nav a{color:var(--muted); text-decoration:none; font-family:var(--sans); font-size:.86rem; font-weight:500; white-space:nowrap; transition:color .15s}
nav a:hover{color:var(--head)}
nav a.navcta{color:#111; background:var(--amber); padding:8px 16px; border-radius:8px; font-weight:700}
nav a.navcta:hover{color:#111; filter:brightness(1.08)}
section{max-width:none; margin:0; padding:96px max(3vw,20px) 72px}
section > *{width:100%; max-width:var(--wide); margin-left:auto; margin-right:auto}
#hero > *{width:auto}
.hero-sub{text-transform:none}
.section-title{font-family:var(--sans); font-weight:800; font-size:clamp(1.7rem,3.4vw,2.35rem); line-height:1.2; color:var(--head); letter-spacing:-.5px; margin-bottom:10px}
.section-title span{color:var(--amber)}
.section-sub{font-family:var(--sans); color:var(--muted); font-size:1.05rem; margin-bottom:38px; padding-right:max(0px, calc(var(--wide) - 780px))}
.eyebrow{font-family:var(--sans); font-size:.74rem; font-weight:700; letter-spacing:1.6px; text-transform:uppercase; color:var(--amber); margin-bottom:10px}
.glass{background:var(--panel); border:1px solid var(--line); border-radius:14px; padding:28px;
  box-shadow:0 1px 0 rgba(255,255,255,.03) inset, 0 12px 32px rgba(0,0,0,.28); position:relative}
.glass p{color:var(--text)}
.glass b{color:var(--head)}
.reveal{opacity:0; transform:translateY(16px); transition:opacity .5s ease, transform .5s ease}
.reveal.on{opacity:1; transform:none}
details.rel{border-left:2px solid var(--line2); padding:10px 0 10px 16px; margin-top:14px}
details.rel summary{cursor:pointer; font-family:var(--sans); font-weight:600; font-size:.92rem; color:var(--head); list-style:none}
details.rel summary::-webkit-details-marker{display:none}
details.rel summary::before{content:'+ '; color:var(--amber)}
details.rel[open] summary::before{content:'\2212 '}
details.rel summary:hover{color:var(--amber)}
details.rel .two{grid-template-columns:1fr 1fr; gap:18px}
details.cl>summary{display:flex; align-items:center; gap:13px; flex-wrap:wrap; cursor:pointer; user-select:none; list-style:none;
 font-family:var(--sans); background:var(--panel); border:1px solid var(--line2); border-radius:12px; padding:16px 20px; transition:.15s}
details.cl>summary::-webkit-details-marker{display:none}
details.cl>summary:hover{border-color:var(--amber); background:#151e2b}
details.cl>summary:focus-visible{outline:2px solid var(--amber); outline-offset:2px}
details.cl[open]>summary{margin-bottom:24px; border-color:var(--amber)}
details.cl .chev{flex:0 0 auto; width:0; height:0; border-left:8px solid var(--amber); border-top:6px solid transparent;
 border-bottom:6px solid transparent; transition:transform .2s ease}
details.cl[open] .chev{transform:rotate(90deg)}
details.cl summary b{color:var(--head); font-size:.98rem}
details.cl summary .sub{color:var(--muted); font-size:.85rem}
details.cl summary .hint{margin-left:auto; font-size:.78rem; font-weight:600; color:var(--amber); white-space:nowrap}
details.cl summary .c{display:none}
details.cl[open] summary .o{display:none}
details.cl[open] summary .c{display:inline}
#hero{min-height:0; display:flex; flex-direction:column; justify-content:center; align-items:center; text-align:center; position:relative; padding-top:88px; padding-bottom:72px}
.glitch{font-family:var(--mono); font-weight:800; font-size:clamp(2.6rem,11vw,7rem); letter-spacing:clamp(4px,2vw,10px); color:var(--head)}
.hero-sub{font-family:var(--sans); color:var(--amber); margin-top:14px; font-size:.95rem; font-weight:600; letter-spacing:1.6px; text-transform:uppercase}
.hero-line{max-width:820px; margin-top:22px; color:var(--muted); font-size:1.15rem; line-height:1.75}
.hero-line b{color:var(--head); font-weight:600}
.cta-row{margin-top:36px; display:flex; gap:14px; flex-wrap:wrap; justify-content:center}
.btn{font-family:var(--sans); text-decoration:none; padding:13px 26px; border-radius:10px; font-weight:600;
  font-size:.95rem; transition:.15s; border:1px solid transparent}
.btn-amber{background:var(--amber); color:#111; font-weight:700}
.btn-amber:hover{filter:brightness(1.08); transform:translateY(-1px)}
.btn-ghost{border-color:var(--line2); color:var(--head); background:rgba(255,255,255,.02)}
.btn-ghost:hover{border-color:var(--amber); color:var(--amber)}
.buildhash{margin-top:26px; font-family:var(--sans); font-size:.85rem; color:var(--muted)}
.buildhash b{color:var(--head)} .cursor{display:none}
.chip-wrap{margin-top:44px; opacity:.95}
/* ---------- SHARED WIDGETS ---------- */
.two{display:grid; grid-template-columns:1fr 1fr; gap:24px}
.three{display:grid; grid-template-columns:repeat(3,1fr); gap:24px}
.statrow{display:flex; gap:20px; margin-top:30px; flex-wrap:wrap}
.stat{flex:1; min-width:130px; text-align:center; padding:20px 10px; border:1px solid var(--line); border-radius:12px; background:var(--panel)}
.stat b{display:block; font-family:var(--sans); font-size:2rem; font-weight:800; color:var(--head)}
.stat.g b{color:var(--green)} .stat.r b{color:var(--red)}
.stat span{font-size:.75rem; color:var(--muted); text-transform:uppercase; letter-spacing:1px}
.term{background:#080c11; border:1px solid var(--line); border-radius:12px; font-family:var(--mono); font-size:.8rem; overflow:hidden}
.term .tbar{background:#0d131b; padding:9px 14px; color:var(--muted); border-bottom:1px solid var(--line); display:flex; gap:7px; align-items:center}
.dot{width:10px;height:10px;border-radius:50%}
.term pre{padding:16px; color:var(--green); line-height:1.55; overflow-x:auto}
.term pre .c{color:var(--muted)} .term pre .r{color:var(--red)} .term pre .a{color:var(--amber)}
.catgrid{display:grid; grid-template-columns:repeat(auto-fill,minmax(270px,1fr)); gap:12px}
.cat{font-family:var(--sans); font-size:.86rem; line-height:1.55; padding:14px 16px; border:1px solid var(--line); border-radius:10px; background:rgba(255,255,255,.015); color:var(--muted); transition:.15s}
.cat:hover{border-color:var(--line2); background:rgba(255,255,255,.03)}
.cat i{color:var(--muted); font-style:normal}
.cat span[style]{color:var(--head) !important; font-weight:700}
table.bugtable{width:100%; border-collapse:collapse; font-family:var(--sans); font-size:.9rem}
.bugtable th{text-align:left; text-transform:uppercase; letter-spacing:1px; font-size:.7rem; color:var(--muted); padding:10px 12px}
.bugtable td{border-top:1px solid var(--line); padding:12px; vertical-align:top; line-height:1.6}
.bugtable td.was{color:var(--red); text-decoration:line-through}
.bugtable td.is{color:var(--green)}
.bugtable td.enc{color:var(--head); font-weight:600; white-space:nowrap}
.bugtable td.note{color:var(--muted)} .bugtable td.note b{color:var(--head)}
/* ---------- APP-WINDOW MOCKS ---------- */
.ide,.runwin,.mapwin,.shot{border:1px solid var(--line2); border-radius:12px; overflow:hidden; background:#080c11; margin-top:8px; box-shadow:0 18px 50px rgba(0,0,0,.4)}
.shot{margin:0}
.ide .tbar,.runwin .tbar,.mapwin .tbar,.shot .shotbar{display:flex; align-items:center; gap:8px; background:#0d131b; padding:9px 14px; border-bottom:1px solid var(--line);
  font-family:var(--sans); font-size:.78rem; color:var(--muted); flex-wrap:wrap}
.ide .tbar .g,.runwin .tbar .g,.shot .shotbar .g{color:var(--green)} .ide .tbar .a,.mapwin .tbar .a,.shot .shotbar .a{color:var(--amber)}
.ide{font-family:var(--mono)}
.idebody{display:grid; grid-template-columns:170px 1fr 320px; min-height:460px}
.ide .pins{border-right:1px solid var(--line); padding:10px; background:rgba(0,0,0,.25)}
.ide .center{display:flex; flex-direction:column; min-width:0}
.ide .tabs,.mapwin .tabs{display:flex; gap:6px; padding:9px 12px; border-bottom:1px solid var(--line); background:rgba(0,0,0,.2); flex-wrap:wrap}
.tab{font-family:var(--sans); font-size:.76rem; font-weight:600; padding:6px 12px; border:1px solid var(--line2); border-radius:7px;
  background:transparent; color:var(--muted); cursor:pointer; transition:.15s; touch-action:manipulation}
.tab:hover{border-color:var(--amber); color:var(--head)}
.tab.on{color:#111; background:var(--green); border-color:var(--green)}
.tab.tab-a.on{background:var(--amber); border-color:var(--amber); color:#111}
#idepane{flex:1; overflow:auto; padding:12px 14px; font-size:.74rem; line-height:1.65; white-space:pre; color:var(--text)}
#idepane .ln{color:#3c4756; user-select:none} #idepane .kw{color:var(--green)} #idepane .cm{color:var(--muted)}
#idepane .cal{color:var(--amber)} #idepane .er{color:var(--red)}
.ide .right{border-left:1px solid var(--line); padding:10px; background:rgba(0,0,0,.25); font-size:.7rem; line-height:1.9; overflow:auto}
.ide .right h4{color:var(--muted); font-size:.64rem; text-transform:uppercase; letter-spacing:1px; margin:8px 0 2px}
.ide .right .rv{color:var(--green)} .ide .right .rk{color:var(--muted)} .ide .right .ra{color:var(--amber)}
.ide .ifoot,.mapwin .mfoot,.shot figcaption{display:flex; justify-content:space-between; gap:10px; flex-wrap:wrap; padding:10px 14px; border-top:1px solid var(--line);
  font-family:var(--sans); font-size:.78rem; color:var(--muted); background:rgba(0,0,0,.2); line-height:1.6}
.shot figcaption{display:block}
.ide .ifoot .g,.mapwin .mfoot .g{color:var(--green)} .ide .ifoot .a,.mapwin .mfoot .a{color:var(--amber)} .ide .ifoot .r{color:var(--red)}
.shot figcaption b{color:var(--head)}
.pin{font-size:.6rem; fill:var(--muted)} .pinl{stroke-width:1.4; opacity:.5; animation:pinpulse 1.8s ease-in-out infinite}
.keys{display:flex; gap:8px; flex-wrap:wrap; margin-top:18px; justify-content:center}
.key{font-family:var(--sans); font-size:.8rem; color:var(--muted); border:1px solid var(--line2); border-bottom-width:3px;
  border-radius:6px; padding:5px 11px; background:var(--panel)}
.key b{color:var(--head)}
/* ---------- RUN DEMO ---------- */
.rctrl{display:flex; gap:8px; flex-wrap:wrap; padding:12px 14px; border-bottom:1px solid var(--line); background:rgba(0,0,0,.2); align-items:center}
.rlabel{font-family:var(--sans); font-size:.7rem; font-weight:600; color:var(--muted); text-transform:uppercase; letter-spacing:1px; margin-right:2px}
#rtrace{font-family:var(--mono); font-size:.74rem; line-height:1.6; color:var(--green); padding:12px 14px; height:220px; overflow:hidden; white-space:pre-wrap}
#rtrace .ts{color:var(--muted)} #rtrace .rd{color:var(--red)} #rtrace .am{color:var(--amber)}
.gauges{display:flex; gap:12px; padding:0 14px 14px; flex-wrap:wrap}
.gauge{flex:1; min-width:120px; border:1px solid var(--line); border-radius:9px; background:rgba(255,255,255,.02); padding:10px 14px}
.gauge span{display:block; font-size:.68rem; font-weight:600; color:var(--muted); text-transform:uppercase; letter-spacing:1px}
.gauge b{font-family:var(--mono); font-size:1.25rem; color:var(--green)}
.gauge b.a{color:var(--amber)} .gauge b.r{color:var(--red)}
#rstatus{font-family:var(--sans); font-size:.82rem; padding:10px 14px; border-top:1px solid var(--line); color:var(--green)}
#rstatus.err{color:var(--red)}
#mapwrap{position:relative} #mapview{width:100%; height:auto; display:block}
/* ---------- FLOW ---------- */
.flow{display:flex; align-items:stretch; gap:14px; flex-wrap:wrap; justify-content:center; margin-top:14px}
.flow .node{flex:1; min-width:200px; text-align:center; padding:24px 16px; border:1px solid var(--line); border-radius:12px; background:var(--panel)}
.flow .node b{display:block; font-family:var(--sans); color:var(--head); margin-bottom:8px}
.flow .node p{font-size:.86rem; color:var(--muted); line-height:1.55}
.flow .node .ico{font-family:var(--mono); color:var(--amber); font-size:1.6rem; margin-bottom:8px}
.flow .arr{align-self:center; font-family:var(--mono); color:var(--amber); font-size:1.5rem}
.filepair{display:flex; gap:14px; margin-top:26px; flex-wrap:wrap; justify-content:center}
.filecard{font-family:var(--mono); font-size:.8rem; padding:12px 20px; border-radius:8px; border:1px dashed var(--line2); color:var(--green)}
.filecard b{color:var(--head)}
.dl{display:inline-flex; align-items:center; gap:10px; font-family:var(--sans); font-size:1rem; text-decoration:none;
  border:1px solid var(--amber); color:var(--amber); border-radius:12px; padding:16px 30px; background:rgba(242,163,58,.06); transition:.15s}
.dl:hover{background:rgba(242,163,58,.14); transform:translateY(-1px)}
.dl small{display:block; font-size:.75rem; color:var(--muted); margin-top:3px}
.dl b{color:var(--head)}
footer{margin-top:0; border-top:1px solid var(--line); background:#070a0f; padding:44px 26px; text-align:center;
  font-family:var(--sans); font-size:.85rem; color:var(--muted); line-height:2}
footer .g{color:var(--green)} footer .r{color:var(--red)} footer .a{color:var(--amber)}
footer a{color:var(--head); text-decoration:none} footer a:hover{color:var(--amber)}
.shot img{display:block; width:100%; height:auto; background:#000}
.shot video{display:block; width:100%; height:auto; max-height:60vh; background:#000}
/* ---------- FLOATING DEMO VIDEO ---------- */
#chipdemo{cursor:pointer}
#chipdemo .demohint{opacity:.85; animation:blink 2.2s steps(1) infinite}
#floatvid{position:fixed; z-index:60; left:50%; top:50%; transform:translate(-50%,-50%); width:min(1280px,94vw);
  display:none; border:1px solid var(--line2); border-radius:12px; overflow:hidden; background:#080c11; box-shadow:0 30px 90px rgba(0,0,0,.85)}
#floatvid.show{display:block}
#floatvid .vbar{display:flex; align-items:center; gap:8px; background:#0d131b; padding:9px 14px; border-bottom:1px solid var(--line);
  font-family:var(--sans); font-size:.8rem; color:var(--muted); cursor:move; user-select:none; touch-action:none}
#floatvid .vbar .g{color:var(--green)}
#floatvid .vclose{margin-left:auto; background:none; border:1px solid var(--line2); color:var(--muted);
  font-family:var(--sans); font-size:.75rem; border-radius:6px; padding:3px 10px; cursor:pointer}
#floatvid .vclose:hover{border-color:var(--red); color:var(--red)}
#floatvid video{display:block; width:100%; height:auto; aspect-ratio:16/9; max-height:78vh; object-fit:contain; background:#000}
/* ---------- YOUTUBE ---------- */
.ytwrap{position:relative; border:1px solid var(--line2); border-radius:12px; overflow:hidden; background:#000; margin-top:8px}
.yt169{position:relative; width:100%; aspect-ratio:16/9}
.yt169 > div, .yt169 > iframe{position:absolute; inset:0; width:100%; height:100%; display:block}
.ytunmute{position:absolute; right:10px; top:10px; z-index:2; font-family:var(--sans); font-size:.78rem; font-weight:700;
  color:#111; background:var(--amber); border:none; border-radius:6px; padding:8px 13px; cursor:pointer}
.gallery{display:grid; grid-template-columns:repeat(auto-fill,minmax(250px,1fr)); gap:16px}
.gitem{display:flex; flex-direction:column; gap:4px; text-decoration:none; padding:12px; border:1px solid var(--line); border-radius:12px; background:var(--panel); transition:.15s}
.gitem:hover{border-color:var(--amber); transform:translateY(-2px)}
.gitem .gimg{display:flex; align-items:center; justify-content:center; height:190px; background:#080c11; border-radius:8px; overflow:hidden; margin-bottom:8px}
.gitem img{max-width:100%; max-height:100%; object-fit:contain; display:block}
.gitem b{color:var(--head); font-size:.92rem}
.gitem span:last-child{color:var(--muted); font-size:.8rem; line-height:1.5}
.views3{align-items:start; margin-bottom:26px}
.views3 .vimg{background:#000; aspect-ratio:1000/640; display:flex; align-items:flex-start; justify-content:center; overflow:hidden}
.views3 .vimg img{width:100%; height:auto; display:block}
#spin3d{cursor:grab; touch-action:pan-y; user-select:none}
#spin3d:active{cursor:grabbing}
@media(max-width:1150px){.views3.three{grid-template-columns:1fr}}
/* ---------- RESPONSIVE ---------- */
@media(max-width:1150px){
  .idebody{grid-template-columns:1fr} .ide .pins{display:none} .ide .right{border-left:none; border-top:1px solid var(--line)}
}
@media(max-width:900px){
  nav{gap:14px} nav .links{gap:16px}
  section{padding:64px 16px 44px}
  .two,.three{grid-template-columns:1fr}
  details.rel .two{grid-template-columns:1fr}
  .flow .arr{display:none} .flow .node{min-width:100%}
  .catgrid{grid-template-columns:repeat(auto-fill,minmax(180px,1fr))}
  table.bugtable{font-size:.82rem}
}
@media(max-width:640px){
  .bt-stack{min-width:0 !important; font-size:.82rem}
  .bt-stack tr:first-child{display:none}
  .bt-stack, .bt-stack tbody, .bt-stack tr, .bt-stack td{display:block; width:auto}
  .bt-stack tr{border-top:1px solid var(--line); padding:9px 0}
  .bt-stack td{border:none; padding:2px 0; white-space:normal; word-break:break-word}
  .bt-stack td::before{display:block; font-size:.62rem; letter-spacing:1px; text-transform:uppercase; color:var(--muted)}
  .bt-bug td:nth-child(1)::before{content:'Encoding'} .bt-bug td:nth-child(2)::before{content:'Table said'}
  .bt-bug td:nth-child(3)::before{content:'Silicon says'} .bt-bug td:nth-child(4)::before{content:'Why it mattered'}
  .bt-proto td:nth-child(1)::before{content:'Protocol'} .bt-proto td:nth-child(2)::before{content:'Handshake'}
  .bt-proto td:nth-child(3)::before{content:'Frame'}
  .bt-mem td:nth-child(1)::before{content:'Address'} .bt-mem td:nth-child(2)::before{content:'What'}
  .bt-form td:nth-child(1)::before{content:'Formula'} .bt-form td:nth-child(2)::before{content:'Value'}
  .bt-form td:nth-child(3)::before{content:'Notes'}
  .bt-stack td.enc{white-space:normal}
  nav .logo{font-size:1rem} nav a{font-size:.8rem}
  section{padding:52px 14px 36px}
  .glass{padding:20px 16px}
  .hero-line{font-size:1rem}
  .btn{padding:12px 20px; font-size:.9rem}
  .term pre{font-size:.68rem}
  .gauge{min-width:calc(50% - 8px); padding:8px}
  .gauge b{font-size:1.05rem}
  #rtrace{font-size:.64rem; height:190px}
  #idepane{font-size:.64rem} .ide .right{font-size:.64rem}
  #floatvid{width:96vw}
  .shot video{max-height:40vh}
}

/* ---------- BOOT INTRO / BACKGROUND / EFFECTS ---------- */
:root{--neon:#00ff41}
@keyframes flicker{0%,100%{opacity:1}92%{opacity:1}93%{opacity:.4}94%{opacity:1}97%{opacity:.6}98%{opacity:1}}
@keyframes scan{0%{transform:translateY(-100%)}100%{transform:translateY(60vh)}}
@keyframes pulseGlow{0%,100%{filter:drop-shadow(0 0 6px rgba(0,255,65,.14)) drop-shadow(0 0 14px rgba(242,163,58,.25))}50%{filter:drop-shadow(0 0 14px rgba(0,255,65,.35)) drop-shadow(0 0 30px rgba(242,163,58,.5))}}
#matrix{position:fixed; inset:0; z-index:0; opacity:.62; pointer-events:none}
#boot{position:fixed; inset:0; z-index:50; background:#020403; display:none; flex-direction:column;
  justify-content:center; align-items:center; font-family:var(--mono); cursor:pointer}
#boot.show{display:flex}
#boot .bwin{width:min(780px,92vw); border:1px solid rgba(0,255,65,.3); border-radius:8px; background:rgba(2,6,3,.9);
  box-shadow:0 0 60px rgba(0,255,65,.12); overflow:hidden}
#boot .bt{display:flex; gap:7px; align-items:center; padding:8px 12px; border-bottom:1px solid rgba(0,255,65,.2);
  background:#0a0f0a; color:var(--muted); font-size:.7rem}
#boot .dot{width:10px;height:10px;border-radius:50%}
#boot pre{padding:16px 18px; font-size:clamp(.62rem,1.6vw,.8rem); line-height:1.7; color:var(--neon); min-height:250px; white-space:pre-wrap}
#boot pre .ok{color:var(--neon)} #boot pre .rd{color:var(--red)} #boot pre .mt{color:var(--muted)} #boot pre .am{color:var(--amber)}
#boot .bprog{height:4px; background:#0a150c}
#boot .bprog i{display:block; height:100%; width:0; background:linear-gradient(90deg,var(--neon),#fff); box-shadow:0 0 10px var(--neon); transition:width .12s}
#boot .skip{margin-top:16px; color:var(--muted); font-size:.68rem; letter-spacing:2px}
#linkstat{position:fixed; right:14px; bottom:12px; z-index:2; font-family:var(--mono); font-size:.68rem;
  color:var(--neon); background:rgba(2,6,3,.75); border:1px solid rgba(0,255,65,.25); border-radius:4px;
  padding:6px 10px; opacity:0; transition:opacity .4s; pointer-events:none; text-shadow:0 0 6px rgba(0,255,65,.6)}
#hero .scanline{display:block; position:absolute; left:0; right:0; top:0; height:120px; pointer-events:none;
  background:linear-gradient(180deg, transparent, rgba(242,163,58,.06), transparent); animation:scan 7s linear infinite}
.glitch{position:relative; animation:flicker 6s infinite; text-shadow:0 0 22px rgba(242,163,58,.35)}
.glitch::before,.glitch::after{display:block; content:attr(data-text); position:absolute; inset:0; overflow:hidden}
.glitch::before{color:var(--red); transform:translate(3px,2px); clip-path:inset(20% 0 60% 0); opacity:.8; mix-blend-mode:screen}
.glitch::after{color:var(--neon); transform:translate(-3px,-2px); clip-path:inset(60% 0 10% 0); opacity:.7; mix-blend-mode:screen}
.cursor{display:inline !important; animation:blink 1s steps(1) infinite; color:var(--neon)}
.chip-wrap{animation:pulseGlow 4s ease-in-out infinite}
/* the falling code shows through the sections: glass, not solid */
main > section:nth-of-type(even){background:rgba(15,20,28,.72)}
main > section{backdrop-filter:blur(5px); -webkit-backdrop-filter:blur(5px)}
main > section:not(#hero){background-color:rgba(10,14,20,.6)}
main > section:nth-of-type(even):not(#hero){background-color:rgba(15,20,28,.74)}
.glass{background:rgba(18,25,36,.82)}
nav{background:rgba(10,14,20,.88)}
nav .logo{text-decoration:none; cursor:pointer}
nav .logo:hover{opacity:.85}
/* ---------- ALIGNMENT: one centred column, however wide the screen ---------- */
section{padding-left:max(20px, calc((100% - var(--wide)) / 2)); padding-right:max(20px, calc((100% - var(--wide)) / 2))}
section > *{width:auto; max-width:none; margin-left:0; margin-right:0}
#hero > *{width:auto}
@media(max-width:900px){section{padding-left:16px; padding-right:16px}}
@media(max-width:640px){section{padding-left:14px; padding-right:14px}}
</style>
</head>
<body>

<div id="boot">
  <div class="bwin">
    <div class="bt"><span class="dot" style="background:#e10600"></span><span class="dot" style="background:#ff9f00"></span><span class="dot" style="background:#00ff41"></span>&nbsp;orss --boot --cpu=MSM66207 --board=P28 --mcp=ready</div>
    <pre id="bootlog"></pre>
    <div class="bprog"><i id="bootbar"></i></div>
  </div>
  <div class="skip">[ TAP / CLICK / ESC TO SKIP ]</div>
</div>

<canvas id="matrix"></canvas>
<div id="floatvid" role="dialog" aria-label="ORSS demo video">
  <div class="vbar" id="vdrag"><span class="dot" style="background:#e10600"></span><span class="dot" style="background:#ff9f00"></span><span class="dot" style="background:#00ff41"></span>
    &nbsp;<span class="g">RomSimStudio</span> &mdash; live demo
    <button class="vclose" id="vclose" type="button" aria-label="Close video">&#10005; ESC</button>
  </div>
  <video id="vid" src="ORSS1.mp4" controls preload="metadata" width="1280" height="720"></video>
</div>
<div id="linkstat">4 INJECTORS FIRING &mdash; ISR FRAME STREAMING</div>
<nav>
  <a class="logo" href="#" title="Back to the top" aria-label="ORSS - back to the top"><b>O</b>RSS</a>
  <div class="links">
    <a href="#intro">New here?</a>
    <a href="#studio">The program</a>
    <a href="#datalog">Datalogging</a>
    <a href="#maps">Maps</a>
    <a href="#start">Get started</a>
    <a href="#changelog">What's new in v<?= $version ?></a>
    <a href="#silicon">Under the hood</a>
    <a href="#video">Video</a>
    <a href="docs/">Guide</a>
    <a class="navcta" href="<?= $zip ?>">Download</a>
  </div>
</nav>
<main>

<!-- ================= HERO ================= -->
<section id="hero">
  <div class="scanline"></div>
  <h1 class="glitch" data-text="ORSS">ORSS</h1>
  <div class="hero-sub">Rom Sim Studio &middot; v<?= $version ?><span class="cursor">_</span></div>
  <p class="hero-line">
    A free program for <b>tuning 1990s Honda engine computers</b> (OBD1 ECUs such as the P28, P30, P72 and P13) &mdash;
    and for <b>building and testing the software inside them</b>. Edit the fuel and ignition maps, log the car as you
    drive, and send changes to the car as you make them. Or build a ROM of your own from ready-made functions
    &mdash; launch control, boost control, datalogging, engine protection &mdash; and try it on a <b>simulated ECU and
    engine</b> on your laptop before it ever goes near the car.
    Windows, Linux and macOS.
  </p>
  <div class="cta-row">
    <a class="btn btn-amber" href="<?= $zip ?>">Download</a>
    <a class="btn btn-ghost" href="#tuneronly">Only tuning? RomSimTuner</a>
    <a class="btn btn-ghost" href="#intro">New here? Start here</a>
    <a class="btn btn-ghost" href="docs/">Read the guide</a>
  </div>
  <div class="buildhash">version <b><?= $version ?></b> &mdash; free to use, not to sell &mdash; by bmgjet</div>

  <div class="chip-wrap">
    <svg width="300" height="300" viewBox="0 0 300 300" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="MSM66207 chip schematic">
      <defs>
        <linearGradient id="die" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#0c1116"/><stop offset="1" stop-color="#05080b"/>
        </linearGradient>
      </defs>
      <g stroke="#00ff41" stroke-width="1.5" opacity=".9">
        <?php for ($i = 0; $i < 11; $i++): $y = 40 + $i * 22; ?>
          <line x1="20" y1="<?= $y ?>" x2="70" y2="<?= $y ?>" stroke-dasharray="6 6"><animate attributeName="stroke-dashoffset" from="24" to="0" dur="1.4s" repeatCount="indefinite"/></line>
          <line x1="230" y1="<?= $y ?>" x2="280" y2="<?= $y ?>" stroke-dasharray="6 6"><animate attributeName="stroke-dashoffset" from="0" to="24" dur="1.4s" repeatCount="indefinite"/></line>
        <?php endfor; ?>
      </g>
      <rect x="70" y="30" width="160" height="240" rx="8" fill="url(#die)" stroke="#ff9f00" stroke-width="2"/>
      <rect x="88" y="52" width="124" height="196" rx="4" fill="none" stroke="rgba(0,255,65,.35)" stroke-width="1"/>
      <g id="chipdemo" role="button" tabindex="0" aria-label="Watch the ORSS demo video">
        <title>Click to watch the demo</title>
        <text x="150" y="134" text-anchor="middle" font-family="Consolas,monospace" font-size="22" font-weight="bold" fill="#fff">MSM<tspan fill="#ff9f00">66207</tspan></text>
        <text class="demohint" x="150" y="157" text-anchor="middle" font-family="Consolas,monospace" font-size="8" fill="#00ff41">&#9654; WATCH THE DEMO</text>
      </g>
      <g font-family="Consolas,monospace" font-size="7" fill="#7b8794">
        <?php
          $pinsL = ['CKI','X1','X2','RES','INT0','INT1','TRNS0','TRNS1','TRNS2','TM0','TM2'];
          $pinsR = ['AD0','AD7','AI3','AI4','AI5','AI6','AI7','P10','P4SF','RDY','VDD'];
          for ($i = 0; $i < 11; $i++): $y = 43 + $i * 22; ?>
          <text x="26" y="<?= $y ?>"><?= $pinsL[$i] ?></text>
          <text x="252" y="<?= $y ?>"><?= $pinsR[$i] ?></text>
        <?php endfor; ?>
      </g>
      <circle cx="84" cy="44" r="4" fill="none" stroke="#ff9f00" stroke-width="1.5"/>
    </svg>
  </div>
</section>

<!-- ================= NEW HERE ================= -->
<section id="intro">
  <h2 class="section-title reveal">New Here? <span>Start Here.</span></h2>
  <p class="section-sub reveal">What this is in plain words</p>
  <div class="two">
    <div class="glass reveal">
      <p class="eyebrow">The short version</p>
      <p style="line-height:1.8">Every fuel-injected engine is run by a small computer, the <b style="color:#fff">ECU</b>. It reads
      the sensors (how fast the engine turns, how hard it is breathing, how hot it is) and decides, hundreds of times a second,
      how much fuel to inject and when to fire the spark. Those decisions come from <b style="color:#fff">tables of numbers &mdash;
      the maps</b> &mdash; stored with the ECU's program on a memory chip, the <b style="color:#fff">ROM</b>.</p>
      <p style="line-height:1.8; margin-top:14px"><b style="color:#fff">Tuning</b> is changing those numbers so the engine suits
      its parts &mdash; bigger injectors, a turbo, a new cam &mdash; or runs better than it did from the factory. On 1990s Honda
      ECUs that means reading the ROM, editing the maps, and putting the ROM back in the car.</p>
      <p style="line-height:1.8; margin-top:14px">The ROM also holds the <b style="color:#fff">program</b> that uses the maps,
      written in the language of the ECU's processor (an OKI MSM66207): <b style="color:#fff">assembly</b>. You do not need to
      read it to tune. But if you want the ECU to do something new &mdash; launch control, a shift light &mdash; that is where it
      goes, and this program lets you build, run and test it on a simulated ECU first.</p>
    </div>
    <div class="glass reveal">
      <p class="eyebrow">Two ways to use it</p>
      <p style="line-height:1.8"><b style="color:var(--green)">1. Tune a car.</b> Open the ROM, and the program finds its maps and
      shows them as tables in real units &mdash; milliseconds of fuel, degrees of timing, rpm and pressure. Connect a datalog cable
      and watch where the engine is on the map as you drive; change a cell and, with a ROM emulator in the ECU, the car uses it
      straight away. When the first start asks what it is for, pick <i>Tuning and datalogging</i>.</p>
      <p style="line-height:1.8; margin-top:14px"><b style="color:var(--green)">2. Build and test a ROM.</b> Start from the
      <b style="color:#fff">skeleton</b> &mdash; a stock ROM cut down to what runs the engine &mdash; and tick the functions you want
      from over fifty (a P30-family skeleton, and now a P13 one). The program checks they fit, work together and leave the engine protected (a rev limiter, fail-safes,
      a way to datalog it), writes the ROM, and runs it on a <b style="color:#fff">simulated ECU and engine</b> where you can watch
      every step. Pick <i>ROM development and simulation</i>.</p>
      <p style="line-height:1.8; margin-top:14px; color:var(--muted)">Both are in the same window: <b style="color:#fff">Ctrl+T</b>
      switches between them any time. The <a href="docs/getting-started.html" style="color:var(--green)">guide</a> walks through each one.</p>
    </div>
  </div>
  <div class="glass reveal" style="margin-top:26px">
    <p class="eyebrow">What you need</p>
    <div style="overflow-x:auto"><table class="bugtable bt-stack">
      <tr><th>To</th><th>You need</th></tr>
      <tr><td class="enc">Try it out</td><td class="note">Just a computer. The ECU and the engine are simulated: open a ROM from the Templates and press Run.</td></tr>
      <tr><td class="enc">Log a car</td><td class="note">A datalog cable (USB serial) on the ECU's CN2 header, and a ROM that sends a datalog &mdash; most tuned ROMs, or one you build here with a datalogging function. A stock ROM does not send one.</td></tr>
      <tr><td class="enc">Change the tune live</td><td class="note">A ROM emulator in the ECU's chip socket: a Moates Ostrich 2.0 or Demon.</td></tr>
      <tr><td class="enc">Put a ROM in the car</td><td class="note">A chip (27C256, or a 27C512 holding two tunes) and a chip programmer &mdash; or the emulator. The ECU needs a socket for the chip.</td></tr>
    </table></div>
  </div>
  <div class="glass reveal" style="margin-top:26px">
    <p class="eyebrow">Words you will see</p>
    <div class="catgrid">
      <div class="cat"><span style="color:#fff">ECU</span><br>The engine computer. OBD1 Hondas (about 1992&ndash;1995) use one with an OKI MSM66207 processor; the P13 family an OKI MSM66911.</div>
      <div class="cat"><span style="color:#fff">ROM / .bin</span><br>The ECU's memory chip, and the 32 KB file copied from it: its program and its maps.</div>
      <div class="cat"><span style="color:#fff">Map</span><br>A table the ECU looks things up in &mdash; rpm down the side, engine load across the top.</div>
      <div class="cat"><span style="color:#fff">Datalog</span><br>A recording of what the ECU sees and does while the car runs, over a cable.</div>
      <div class="cat"><span style="color:#fff">Emulator</span><br>A device in place of the ROM chip that the laptop can rewrite while the engine runs.</div>
      <div class="cat"><span style="color:#fff">Assembly / .asm</span><br>The ROM's program in readable form. Building it turns it back into a .bin.</div>
      <div class="cat"><span style="color:#fff">Simulator</span><br>A pretend ECU and engine on your computer: the ROM runs on it exactly as in the car.</div>
      <div class="cat"><span style="color:#fff">Skeleton and modules</span><br>A bare stock ROM, and the functions you can build into it.</div>
      <div class="cat"><span style="color:#fff">AFR / wideband</span><br>Air-fuel ratio, and the sensor that measures it accurately &mdash; how you know the fuel is right.</div>
    </div>
  </div>
  <div class="note reveal" style="margin-top:26px; border-left:3px solid var(--amber); padding:12px 16px; background:rgba(255,159,0,.06); border-radius:0 8px 8px 0; line-height:1.7">
    <b style="color:var(--amber)">Your engine, your risk.</b> A wrong number can damage an engine. Start from a known-good ROM,
    change a little at a time, watch the datalog, and try new ROMs on the simulator first. The program caps values to what the
    ECU and engine can use, but it cannot know your engine.
  </div>
</section>

<!-- ================= STUDIO ================= -->
<section id="studio">
  <h2 class="section-title reveal">The Program: <span>One Window for the Whole Job</span></h2>
  <p class="section-sub reveal">Simulator mode for the ROM &middot; tuner mode for the car &middot; Ctrl+T switches</p>
  <div class="glass reveal" style="margin-bottom:26px">
    <p style="line-height:1.8"><b style="color:#fff">Tuner mode</b> is for the car: the maps and settings fill the window, shown
    as tables in real units (and as lines or in 3D), with the datalog and your gauges beside them. As the engine runs &mdash; or a
    recorded log plays back &mdash; the cells it is using light up, with a trail behind, so you change the part of the map that matters.</p>
    <p style="line-height:1.8; margin-top:14px"><b style="color:#fff">Simulator mode</b> is for the ROM itself: the chip's pins on
    the left with sliders for the engine's sensors, the ROM's program in the middle, and on the right what the processor is doing.
    Run it, pause it, step through it, and see which part of the program reads each map and writes each value. Open a bare
    <span style="font-family:var(--mono)">.bin</span> and it is turned back into readable source for you.</p>
    <p style="line-height:1.8; margin-top:14px; color:var(--muted)">Every part is explained, with pictures, in the
    <a href="docs/" style="color:var(--green)">guide</a>.</p>
  </div>
  <div class="ide reveal">
    <div class="tbar"><span class="dot" style="background:#e10600"></span><span class="dot" style="background:#ff9f00"></span><span class="dot" style="background:#00ff41"></span>
      &nbsp;<span class="g">RomSimStudio</span> &mdash; HTS115.asm &nbsp;|&nbsp; crystal <span class="a">10 MHz</span> (measured) &nbsp;|&nbsp; cycles fOSC/4 &nbsp;|&nbsp; <span class="a">MCP: 1 client</span> &nbsp;|&nbsp; P28 profile
    </div>
    <div class="idebody">
      <div class="pins">
        <svg width="140" height="380" viewBox="0 0 128 380" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="live pinout">
          <rect x="34" y="14" width="60" height="352" rx="6" fill="#070b10" stroke="#ff9f00" stroke-width="1.5"/>
          <text x="64" y="196" text-anchor="middle" font-family="Consolas,monospace" font-size="9" fill="#7b8794" transform="rotate(-90 64 196)">MSM66207 &middot; LIVE</text>
          <?php
            $rowsL = [['CKI','var(--green)',0],['INT0','var(--green)',300],['INT1','var(--green)',600],['TRNS0','#b06bff',900],['TRNS1','#b06bff',1200],['TM2','#b06bff',1500],['AI6','#ff9f00',1800],['AI7','#ff9f00',2100]];
            $rowsR = [['P10','var(--green)',150],['TXD','var(--green)',450],['TRNS2','#b06bff',750],['AD0','var(--green)',1050],['AI3','#ff9f00',1350],['AI5','#ff9f00',1650],['RXD','var(--green)',1950],['VDD','#7b8794',2250]];
            for ($i=0;$i<8;$i++): $y = 34 + $i*44; ?>
            <line class="pinl" x1="10" y1="<?= $y ?>" x2="34" y2="<?= $y ?>" stroke="<?= $rowsL[$i][1] ?>" style="animation-delay:<?= $i*0.22 ?>s"/>
            <text class="pin" x="10" y="<?= $y - 4 ?>"><?= $rowsL[$i][0] ?></text>
            <line class="pinl" x1="94" y1="<?= $y ?>" x2="118" y2="<?= $y ?>" stroke="<?= $rowsR[$i][1] ?>" style="animation-delay:<?= $i*0.31+0.1 ?>s"/>
            <text class="pin" x="96" y="<?= $y - 4 ?>"><?= $rowsR[$i][0] ?></text>
          <?php endfor; ?>
        </svg>
      </div>
      <div class="center">
        <div class="tabs" id="idetabs"></div>
        <div id="idepane"></div>
      </div>
      <div class="right">
        <h4>CPU &mdash; nX-8/200 @ 2.5 MHz</h4>
        <span class="rk">A</span>=<span class="rv" id="regA">4F</span> <span class="rk">B</span>=<span class="rv">00</span> <span class="rk">C</span>=<span class="rv" id="regC">1E</span><br>
        <span class="rk">X</span>=<span class="rv">6EAD</span> <span class="rk">Y</span>=<span class="rv">0002</span><br>
        <span class="rk">PC</span>=<span class="ra" id="regPC">2C4A</span> <span class="rk">SP</span>=<span class="rv">05F2</span><br>
        <span class="rk">PSW</span>=<span class="rv">Z-</span> <span class="rk">cyc</span>=<span class="rv" id="regCyc">0</span><br>
        <h4>Call stack</h4><span class="cm">INT tmr2_isr &larr; CAL table2d_lookup_interp<br>&larr; main_loop</span>
        <h4>Engine</h4><span class="rk">RPM</span> <span class="ra" id="ideRpm">800</span> &middot; <span class="rk">inj</span> <span class="rv">4/4 &middot; 3.49 ms</span><br>
        <span class="rk">rpm word</span> <span class="rv" id="ideWord">2344</span> <span class="cm">(1,875,000/rpm)</span><br>
        <span class="rk">pump</span> <span class="rv">ON</span> &middot; <span class="rk">TPS</span> <span class="rv">0.42 V</span> &middot; <span class="rk">MAP</span> <span class="rv">34.1 kPa</span><br>
        <h4>Datalog (sim port)</h4><span class="rv">ISR v2 &middot; streaming</span><br><span class="cm">frame 51 B + cksum @ 20 Hz<br>rpm 2500 decoded &check; tests</span>
        <h4>Breakpoints</h4><span class="cm">F9 table2d_lookup_interp &mdash; hit x1846<br>F9 nmi_brk &mdash; disabled</span>
      </div>
    </div>
    <div class="ifoot">
      <span id="idestat"><span class="g">RUNNING</span> &mdash; 1.15M instr/s &middot; 5,623 unique addresses &middot; boot scan 4.5 s <span class="a">(Fast Boot skips it)</span></span>
      <span><span class="a">Ctrl+B</span> build &middot; <span class="a">F5</span> run &middot; <span class="r">no errors</span></span>
    </div>
  </div>
  <div class="two" style="margin-top:26px">
    <figure class="shot reveal">
      <div class="shotbar"><span class="dot" style="background:#e10600"></span><span class="dot" style="background:#ff9f00"></span><span class="dot" style="background:#00ff41"></span>
        &nbsp;<span class="g">RomSimStudio</span> &mdash; simulator mode</div>
      <a href="docs/simulator.html"><img src="docs/img/simulator.png" width="<?= $shotW ?>" height="<?= $shotH ?>" loading="lazy" decoding="async"
           alt="RomSimStudio in simulator mode: source editor, live chip view, registers and the lower tabs"
           title="RomSimStudio — simulator mode"></a>
      <figcaption><b>simulator mode</b> &mdash; the whole bench on screen: source with the ROM running, live pins and engine inputs, registers, call stack, disassembly, and the tabs below.</figcaption>
    </figure>
    <figure class="shot reveal">
      <div class="shotbar"><span class="dot" style="background:#e10600"></span><span class="dot" style="background:#ff9f00"></span><span class="dot" style="background:#00ff41"></span>
        &nbsp;<span class="g">RomSimStudio</span> &mdash; <span class="a">Ctrl+T</span> tuner mode</div>
      <a href="docs/tuning.html"><img src="docs/img/tuner-replay.png" width="<?= $shotW ?>" height="<?= $shotH ?>" loading="lazy" decoding="async"
           alt="RomSimStudio in tuner mode: a log playing over the fuel map, the live cells lit with a trail, the datalog on the right"
           title="RomSimStudio — tuner mode (Ctrl+T)"></a>
      <figcaption><b>tuner mode</b> (<span style="font-family:var(--mono);color:var(--amber)">Ctrl+T</span>) &mdash; the maps fill the window, the datalog beside them: the cells the engine reads are lit as a log plays, with a trail behind.</figcaption>
    </figure>
  </div>
  <!-- the program's views, one after another: starts when it scrolls into view, pauses when it scrolls away or is pointed at -->
  <figure class="shot reveal" id="views" style="margin-top:26px">
    <div class="shotbar"><span class="dot" style="background:#e10600"></span><span class="dot" style="background:#ff9f00"></span><span class="dot" style="background:#00ff41"></span>
      &nbsp;<span class="g">RomSimStudio</span> &mdash; views &nbsp;|&nbsp; <span class="a" id="viewname"></span>
      <span style="margin-left:auto; display:flex; gap:6px"><button class="tab" id="viewprev" type="button" aria-label="Previous view">&#9664;</button><button class="tab" id="viewnext" type="button" aria-label="Next view">&#9654;</button></span></div>
    <div style="position:relative; background:#000">
      <?php foreach ($views as $k => [$file, $name, $what]): ?>
      <img src="docs/img/<?= $file ?>" alt="<?= htmlspecialchars($name . ': ' . $what) ?>" loading="lazy" decoding="async" data-name="<?= htmlspecialchars($name) ?>" data-what="<?= htmlspecialchars($what) ?>"
           style="<?= $k === 0 ? '' : 'position:absolute; inset:0; ' ?>width:100%; height:100%; object-fit:contain; opacity:<?= $k === 0 ? 1 : 0 ?>; transition:opacity .6s">
      <?php endforeach; ?>
    </div>
    <figcaption id="viewwhat"></figcaption>
  </figure>
  <div class="keys reveal">
    <span class="key"><b>F5</b> run/pause</span><span class="key"><b>F11</b> Step</span><span class="key"><b>F10</b> Over</span>
    <span class="key"><b>Ctrl+F11</b> Into (forced)</span><span class="key"><b>Shift+F11</b> Out</span><span class="key"><b>F9</b> breakpoint</span>
    <span class="key"><b>Ctrl+B</b> build</span><span class="key"><b>Ctrl+Shift+B</b> patch the running ROM</span><span class="key"><b>Ctrl+T</b> tuner mode</span><span class="key"><b>Ctrl+,</b> settings</span>
  </div>
  <?php foreach ($gallery as $group => $items): ?>
  <h3 class="eyebrow" style="margin-top:44px"><?= htmlspecialchars($group) ?> <span style="color:var(--muted)">&middot; <?= count($items) ?></span></h3>
  <div class="gallery reveal">
    <?php foreach ($items as [$file, $name, $what]): ?>
    <a class="gitem" href="docs/img/<?= $file ?>" target="_blank" rel="noopener">
      <span class="gimg"><img src="docs/img/<?= $file ?>" alt="<?= htmlspecialchars($name . ': ' . $what) ?>" loading="lazy" decoding="async"></span>
      <b><?= htmlspecialchars($name) ?></b><span><?= htmlspecialchars($what) ?></span>
    </a>
    <?php endforeach; ?>
  </div>
  <?php endforeach; ?>
  <div class="catgrid reveal" style="margin-top:26px">
    <?php foreach ($features as $i => $f): ?>
      <div class="cat"><i><?= str_pad((string)($i + 1), 2, '0', STR_PAD_LEFT) ?>.</i> <?= htmlspecialchars($f) ?></div>
    <?php endforeach; ?>
  </div>
</section>

<!-- ================= DATALOG ================= -->
<section id="datalog">
  <h2 class="section-title reveal">Datalogging: <span>See What the Engine Sees</span></h2>
  <p class="section-sub reveal">Connect a cable to the car &mdash; or to the simulator, to practise without one</p>
  <p class="reveal" style="color:var(--muted); line-height:1.8; margin:-18px 0 26px; max-width:1000px">A datalog is a live recording of the ECU's readings &mdash; rpm, pressure, temperatures, injector time, timing, air-fuel ratio &mdash; sent over a cable many times a second. It is how you know what the engine is doing and what to change. The common OBD1 formats are all understood, and the simulator can answer the cable exactly as the ECU would.</p>
  <div class="two">
    <div class="glass reveal">
      <p style="line-height:1.8">The Datalog tab is laid out like HTS's datalogger, but "Connect" can dial
      <b style="color:var(--green)">the simulator</b> instead of a port: the ROM's own serial state machine answers, frame for frame,
      exactly as it would in the car. Protocols auto-detect:</p>
      <div style="overflow-x:auto"><table class="bugtable bt-stack bt-proto" style="margin-top:14px; min-width:480px">
        <tr><th>Protocol</th><th>Handshake</th><th>Frame</th></tr>
        <tr><td class="enc">HTS</td><td class="is">AB &rarr; CD</td><td class="note">90 &rarr; 51 bytes + checksum</td></tr>
        <tr><td class="enc">ISR v2</td><td class="is">10 &rarr; CD</td><td class="note">20 &rarr; 51 bytes + checksum</td></tr>
        <tr><td class="enc">Crome / QD3</td><td class="is">AB &rarr; BC</td><td class="note">46 ('F') &rarr; 40 bytes, starts 46 26</td></tr>
        <tr><td class="enc">HTS single-byte</td><td class="is">&mdash;</td><td class="note">C0+n &rarr; byte n of the main table</td></tr>
        <tr><td class="enc">Raw 10h</td><td class="is">&mdash;</td><td class="note">checksummed frames, any length, requested or streamed</td></tr>
        <tr><td class="enc">P13 46h</td><td class="is">10 &rarr; CD</td><td class="note">46 &rarr; checksummed MSM66911 frame, rpm from the crank word at 00AE</td></tr>
        <tr><td class="enc">P13 20h</td><td class="is">10 &rarr; CD</td><td class="note">20 &rarr; second command byte, other P13 loggers</td></tr>
      </table></div>
      <p style="line-height:1.8; margin-top:14px; color:var(--muted)">Format unknown? <b style="color:#fff">Detect layout</b> reads the ROM's
      serial receive code for the command bytes it compares against, tries each on the simulator until a checksummed frame comes back,
      then wiggles every engine input to see which frame byte follows it. The learned format logs, graphs and overlays like a built-in
      protocol &mdash; and it ships with an MCP tool.</p>
    </div>
    <div class="glass reveal">
      <p style="line-height:1.8" ><b style="color:#fff">Every parameter of every frame</b> is listed decoded, with unit and raw bytes,
      beside a packet monitor of everything sent and received. Playback HTS <span style="font-family:var(--mono)">DATALOGGER</span>
      binaries or CSV &mdash; or a <span style="font-family:var(--mono)">.rlog</span>, whose zip carries the log, the ROM that made it
      and the old settings: all three open together. "Drive the simulator" puts the car's readings next to what the simulated ECU
      did with them and the code that ran.</p>
      <p style="line-height:1.8; margin-top:16px; color:var(--muted)">A wideband (AEM, Zeitronix, TechEdge, PLX, Innovate LC-1/LM-2,
      14Point7 Spartan) on its own port adds <span style="font-family:var(--mono)">afr / lambda</span> to every frame.
      <b style="color:#fff">Aux channels</b> compute new signals from raw bytes through an expression
      (<span style="font-family:var(--mono)">byte:N, word:N, bit:N.B</span>) &mdash; knock count, spare input, 0&ndash;5 V wideband.
      And <b style="color:#fff">Overlay</b> lays measured AFR across the fuel map: every cell the engine sat in gets its average,
      and <b style="color:var(--green)">AFR fix</b> scales the cells by measured / target. Hit trace from a real ECU goes through a
      Moates Ostrich 2.0 / Demon.</p>
    </div>
  </div>
  <div class="statrow">
    <div class="stat reveal"><b>7</b><span>built-in protocols</span></div>
    <div class="stat g reveal"><b>20 Hz</b><span>streamed frames, decoded live</span></div>
    <div class="stat reveal"><b>1</b><span>simulated ECU answering the cable</span></div>
    <div class="stat g reveal"><b>.rlog</b><span>log + ROM + settings, open as one</span></div>
  </div>
</section>

<!-- ================= MAPS ================= -->
<section id="maps">
  <h2 class="section-title reveal">The Maps, <span>Found for You</span></h2>
  <p class="section-sub reveal">Open a ROM &mdash; its fuel and ignition maps are found by reading its program</p>
  <p class="reveal" style="color:var(--muted); line-height:1.8; margin:-18px 0 26px; max-width:1000px">A ROM is just 32 KB of numbers; nothing in it says where the maps are. Most tools need someone to have written that down for each ROM. Here, <b style="color:#fff">Detect</b> reads the program the way the ECU runs it, finds the code that looks the maps up, and so finds the maps, their size and their axes. Below are the real maps of one ROM &mdash; point at a cell.</p>
  <div class="three views3 reveal">
    <figure class="shot">
      <div class="shotbar"><span class="g">Table</span> &mdash; the numbers, coloured</div>
      <div class="vimg"><img src="docs/img/table-grid.png" alt="A fuel map as a coloured table: rpm down the side, load across the top" loading="lazy" decoding="async"></div>
      <figcaption><b>Table</b> &mdash; rpm down the side, load across the top, each cell coloured from low to high. Type a value, nudge with +/&minus;, paste from a spreadsheet.</figcaption>
    </figure>
    <figure class="shot">
      <div class="shotbar"><span class="g">Line</span> &mdash; one curve per rpm row</div>
      <div class="vimg"><img src="docs/img/table-line.png" alt="The same map as lines: one curve per rpm row, with a cursor reading the value" loading="lazy" decoding="async"></div>
      <figcaption><b>Line</b> &mdash; see the shape. Drag a point up or down to change it; a bumpy curve is easy to spot and smooth out.</figcaption>
    </figure>
    <figure class="shot">
      <div class="shotbar"><span class="g">3D</span> &mdash; drag to turn it</div>
      <div class="vimg" id="spin3d" title="Drag to turn the map"><img id="spinimg" src="docs/img/3d/00.png" alt="The same map as a coloured 3D surface, turning round" width="1000" height="640"></div>
      <figcaption><b>3D</b> &mdash; the map as a surface. It turns by itself; drag it to turn it yourself. In the program, right-drag turns it, the wheel zooms, and you can drag points here too.</figcaption>
    </figure>
  </div>
  <div class="glass reveal" style="margin-bottom:26px">
    <p style="line-height:1.8">On HTS115, <b style="color:#fff">Detect</b> finds <b style="color:var(--green)">two-dimensional lookup maps
    + 69 switches &mdash; 460 definitions</b> in one pass, straight out of the code that uses them.
    <span style="font-family:var(--mono);color:var(--green)">SB PSWL.5</span> before the lookup call means "fuel map &mdash; a column-multiplier
    row follows"; the RAM index bytes get traced back to the axis searches that wrote them, so every map arrives with its real RPM
    and load axes. Rows of padding get trimmed to the real column count, and out comes <b style="color:#fff">20&times;10 maps with the load
    axis ending at 1039 mbar &mdash; exactly what HTS shows</b>. Everything on this canvas is verbatim from
    <span style="font-family:var(--mono)">roms/HTS115.asm</span>, scaled by the formulas HTS's own editor uses.
    <b style="color:#fff">Hover a cell</b> &mdash; raw byte, address, multiplier, and the physical value.</p>
  </div>
  <div class="mapwin reveal">
    <div class="tbar"><span class="dot" style="background:#e10600"></span><span class="dot" style="background:#ff9f00"></span><span class="dot" style="background:#00ff41"></span>
      &nbsp;Calibration &mdash; <span class="a" id="maphdr">HTS115 detected maps</span> &nbsp;|&nbsp; 20 &times; 10, stride 24 &nbsp;|&nbsp; live-patch: ARMED
    </div>
    <div class="tabs" id="maptabs"></div>
    <div id="mapwrap"><canvas id="mapview" width="1440" height="680"></canvas></div>
    <div class="mfoot"><span id="mapdesc">&mdash; hover a cell &mdash;</span><span class="g">fuel (raw&times;mult)/4 ms &middot; ign raw&times;0.25&minus;6 &deg; &middot; VE raw/128&times;100&minus;100 % &mdash; HTS's own scalings, edits patch the running ROM</span></div>
  </div>
  <div class="two" style="margin-top:26px">
    <div class="term reveal">
      <div class="tbar"><span class="dot" style="background:#e10600"></span><span class="dot" style="background:#ff9f00"></span><span class="dot" style="background:#00ff41"></span>&nbsp;what the detector pattern-matches</div>
      <pre>MOVB  r0, #018h      <span class="c">; row stride = 24</span>
MOVB  r1, r6         <span class="c">; row index  (rpm)</span>
MOVB  r2, 0c0h       <span class="c">; col index  (load)</span>
MOVB  r3, r4         <span class="c">; col count</span>
MOV   X1, #FUEL1_Lo  <span class="c">; the map</span>
<span class="a">SB    PSWL.5</span>         <span class="c">; set &rArr; multiplier row follows</span>
CAL   table2d_lookup_interp

<span class="c"># follow the index bytes back &rArr; axis searches:</span>
<span class="a">MOV X1, #P_LO_Scaler   ...   STB A, r6</span>
<span class="a">MOV X1, #P_MAP_Scaler  ...   STB A, 0c0h</span>
<span class="c"># 20 RPM rows &times; 10 load cols, load to 1039 mbar.
# Lo/Hi cam &times; primary/secondary &rArr; 4 fuel + 4 ign + VE.</span></pre>
    </div>
    <div class="term reveal">
      <div class="tbar"><span class="dot" style="background:#e10600"></span><span class="dot" style="background:#ff9f00"></span><span class="dot" style="background:#00ff41"></span>&nbsp;the same surface from the CLI and the agent</div>
      <pre><span class="c">$</span> okisim get hts115.bin FUEL1_Lo      <span class="c"># raw or scaled</span>
<span class="c">$</span> okisim set hts115.bin FUEL1_Lo 0 --cell 3,4 --add -2
<span class="c"># in-app MCP, while the ROM runs on screen:</span>
cal_read  { name: "FUEL1_Lo" }
cal_write { name: "FUEL1_Lo", cells: [[3,4,-2]], mode: "add" }
cal_explain { name: "VEhi" }   <span class="c"># who reads it, what they do</span>
<span class="c"># edits land live in the running ROM, then:</span>
[OK ] emulator auto-upload &mdash; bench has the new tune
<span class="c"># cal_save writes bin + .okidef.json + TunerPro XDF</span></pre>
    </div>
  </div>
  <div class="glass reveal" style="margin-top:26px; overflow-x:auto">
    <table class="bugtable bt-stack bt-form">
      <tr><th>Formula</th><th>Value</th><th>Notes</th></tr>
      <?php foreach ($formulas as $f): ?>
      <tr><td class="enc"><?= htmlspecialchars($f[0]) ?></td><td class="is" style="text-decoration:none"><?= $f[1] ?></td><td class="note"><?= htmlspecialchars($f[2]) ?></td></tr>
      <?php endforeach; ?>
    </table>
  </div>
</section>

<!-- ================= RUN DEMO ================= -->
<section id="run">
  <h2 class="section-title reveal">Watch a ROM <span>Run an Engine</span></h2>
  <p class="section-sub reveal">A simulated ECU and engine &mdash; pick an engine speed and press run</p>
  <p class="reveal" style="color:var(--muted); line-height:1.8; margin:-18px 0 26px; max-width:1000px">The simulator feeds the ROM the signals a running engine would &mdash; crank position, pressure, temperature &mdash; and the ROM answers as it would in the car: it starts the fuel pump, fires the injectors, times the spark. Below is a small replay of what that looks like, with numbers from the program's own tests.</p>
  <div class="runwin reveal">
    <div class="tbar"><span class="dot" style="background:#e10600"></span><span class="dot" style="background:#ff9f00"></span><span class="dot" style="background:#00ff41"></span>
      &nbsp;okisim run <span class="g" id="runrom">roms/HTS115.asm</span> &mdash; engine model: 4-cyl OBD1, 24-tooth CKP, VC + CYP + TDC, TRNS0/1/2 feedback, timers 312.5 kHz
    </div>
    <div class="rctrl">
      <span class="rlabel">ROM</span><span class="tab on" style="cursor:default">HTS115 &mdash; 10,341 instructions</span>
      <span class="rlabel" style="margin-left:14px">throttle</span>
      <button class="tab" data-rpm="800">idle 800</button>
      <button class="tab" data-rpm="3000">cruise 3000</button>
      <button class="tab" data-rpm="7200">pull to redline</button>
      <button class="tab" data-rpm="250">crank &amp; start</button>
      <button class="tab on" id="runbtn" style="border-color:var(--green)">RUN &nbsp;F5</button>
    </div>
    <div id="rtrace"></div>
    <div class="gauges">
      <div class="gauge"><span>engine speed</span><b id="gRpm">0</b></div>
      <div class="gauge"><span>rpm word @ 1.875 MHz</span><b class="a" id="gWord">&mdash;</b></div>
      <div class="gauge"><span>injector pulse</span><b id="gPulse">0.00 ms</b></div>
      <div class="gauge"><span>unique addresses</span><b id="gAddr">0</b></div>
      <div class="gauge"><span>throughput</span><b id="gSpeed">&mdash;</b></div>
    </div>
    <div id="rstatus">IDLE &mdash; roms/HTS115.asm loaded &mdash; hit F5.</div>
  </div>
  <div class="two" style="margin-top:26px">
    <div class="glass reveal">
      <p style="line-height:1.8">The clock is <b style="color:#fff">measured, not guessed</b>: a 10 MHz crystal, machine cycles at
      fOSC/4 = 2.5 MHz, timers /8 = 312.5 kHz. The rpm word is then exactly 1,875,000 / rpm and the injector scalings come out
      the same as the OEM tuning software's &mdash; watch the <b style="color:var(--amber)">rpm word</b> gauge: the ROM is
      reading the number the gauge is doing in decimal. The interrupt model matches the ROMs' own self-test: one instruction
      always runs after RTI, all timers share one prescaler. Boot spends ~4.5 s in
      <span style="font-family:var(--mono);color:var(--green)">adc_wait_loop</span> &mdash; that's the check-engine light's
      time at key-on, not a hang &mdash; and Fast Boot skips it in no real time.</p>
    </div>
    <div class="glass reveal">
      <p style="line-height:1.8; color:var(--muted)">Every signal the ROM depends on is modelled: each CKP tooth latches TM2 into
      TMR2 and raises the timer-2 interrupt (that <i>is</i> how these ROMs count rpm); TDC is INT1 every 6th tooth; CYP arrives
      on TRNS0; VSS is INT0. Each coil dwell returns an igniter confirmation on TRNS1 and each completed injection a feedback
      edge on TRNS2 &mdash; without them the ROM logs codes 9/15 and cuts fuel. Sensors land where the code reads them: ECT mux 0,
      baro mux 3, IAT mux 7, O2 on AD1 mux 0, MAP on AI6, TPS on AI7, battery on AI5. Speed runs 0.1x to unlimited in 4 ms
      slices, so <b style="color:#fff">unlimited never freezes the window</b>.</p>
    </div>
  </div>
</section>

<!-- ================= START / DOWNLOAD ================= -->
<section id="start">
  <h2 class="section-title reveal">Get Started <span>in Four Steps</span></h2>
  <p class="section-sub reveal">Windows, Linux or macOS &mdash; it needs the free .NET runtime</p>
  <div class="flow reveal">
    <div class="node"><div class="ico">1</div><b>DOWNLOAD</b><p>Get <b style="color:#fff"><?= $zip ?></b><?= $zipSize ? ' (' . $zipSize . ')' : '' ?> and unzip it to a folder of your own (not Program Files). Run <b style="color:#fff">RomSimStudio</b>.</p></div>
    <div class="arr">&gt;&gt;</div>
    <div class="node"><div class="ico">2</div><b>CHOOSE</b><p>The first start asks what it is for: <i>tuning and datalogging</i>, or <i>ROM development and simulation</i>. You can switch any time with Ctrl+T.</p></div>
    <div class="arr">&gt;&gt;</div>
    <div class="node"><div class="ico">3</div><b>OPEN A ROM</b><p>File &gt; Open your car's .bin &mdash; its maps are found for you &mdash; or File &gt; New ROM to start from a template or build one from the skeleton.</p></div>
    <div class="arr">&gt;&gt;</div>
    <div class="node"><div class="ico">4</div><b>TRY, THEN TUNE</b><p>Press Run to watch it on the simulated engine. Then connect the datalog cable and an emulator, and tune the car a little at a time.</p></div>
  </div>
  <div style="text-align:center; margin-top:36px" class="reveal">
    <a class="dl" href="<?= $zip ?>">&#11015;&nbsp; <span><b><?= $zip ?></b> — <?= $product ?> v<?= $version ?>, compiled<small>Windows · Linux · macOS · x64 + ARM<?= $zipSize ? ' · ' . $zipSize : '' ?> — requires the .NET 10 and ASP.NET Core 10 runtimes</small></span></a>
  </div>
  <div class="glass reveal" id="tuneronly" style="margin:30px auto 0; max-width:900px">
    <p class="eyebrow">Only tuning? RomSimTuner</p>
    <p style="line-height:1.8; margin-top:10px; color:var(--muted)">The tuning part of Rom Sim Studio as a program of its own:
    the calibration editor, live datalogging and the ROM emulator &mdash; what Tuner mode shows &mdash; for the P28, P30, P72, P13 and the
    rest. No simulator, MCP server or plugins, and it needs only the .NET 10 Runtime.
    It has its own settings and checks for its own updates. Unzip it to a folder of your own and run <b style="color:#fff">RomSimTuner</b>.</p>
    <div style="text-align:center; margin-top:18px">
      <a class="dl" href="<?= $tunerZip ?>">&#11015;&nbsp; <span><b><?= $tunerZip ?></b> — RomSimTuner v<?= $version ?>, compiled<small>Windows · Linux · macOS · x64 + ARM<?= $tunerZipSize ? ' · ' . $tunerZipSize : '' ?> — requires the .NET 10 runtime</small></span></a>
    </div>
  </div>
  <p class="reveal" style="text-align:center; color:var(--muted); margin-top:18px">Stuck? The <a href="docs/getting-started.html" style="color:var(--green)">getting started guide</a> and <a href="docs/troubleshooting.html" style="color:var(--green)">troubleshooting</a> cover the common questions. Still stuck, or want to share a tune or a module? Ask on the <a href="https://discord.gg/xynkH3ymkH" style="color:var(--green)">Discord</a>. The files it works with:</p>
  <div class="filepair reveal">
    <div class="filecard"><b>rom.asm</b><br>source — or let the .bin become source</div>
    <div class="filecard"><b>rom.bin</b><br>byte-identical or the build failed</div>
    <div class="filecard"><b>.sym / .map / .lst</b><br>symbols, per-module usage, listing</div>
    <div class="filecard"><b>.okidef.json</b><br>every setting, size and formula</div>
    <div class="filecard"><b>project.zip</b><br>full machine state + settings + processor profile</div>
    <div class="filecard"><b>processor.json</b><br>describe any 66K part — 66207 and 66911 ship with their own peripherals</div>
    <div class="filecard"><b>features.json</b><br>code patches that expect their bytes and restore exactly</div>
  </div>
</section>

<!-- ================= WHAT'S NEW ================= -->
<section id="whatsnew">
 <h2 class="section-title reveal">New in <span><?= $version ?></span></h2>
 <p class="section-sub reveal"><?= $previous ?> &rarr; <?= $version ?> &mdash; <?= $releaseSub ?></p>
 <?php $changes = array_sum(array_map('count', array_column($release, 'items'))); ?>
 <!-- the whole current release stays folded until it is asked for -->
 <details class="cl reveal" id="changelog">
 <summary>
  <span class="chev"></span>
  <b>What changed in <?= $version ?></b>
  <span class="sub"><?= count($release) ?> groups &middot; <?= $changes ?> changes &middot; a <?= count(glob(__DIR__ . '/docs/*.html')) ?>-page guide</span>
  <span class="hint"><span class="o">&#9656; OPEN</span><span class="c">&#9662; CLOSE</span></span>
 </summary>

 <!-- the headline of this release: the skeleton ROM and its modules -->
 <div class="glass" style="margin-bottom:26px">
  <p class="eyebrow">Build your own ROM &mdash; for the P30 and the P13</p>
  <p style="line-height:1.8; color:var(--muted)">Two skeletons: stock P30 (the P28-board family, MSM66207) and, new, stock P13
  (MSM66911), each cut to what still runs the engine with the seams left in on purpose: hook slots at a fixed address, a free
  block measured in <b style="color:#fff">kilobytes</b>, an info block that tells an editor where everything is, and
  <b style="color:#fff">57 feature modules</b> the assembler drops in &mdash; pick them in <b style="color:#fff">File &gt; New ROM &gt;
  Create</b>, which checks the pick fits, works together, keeps the CPU up with the engine and leaves the engine protected
  before it writes the build (<a href="docs/new-rom.html" style="color:var(--green)">how</a>). Rev limit, launch control, flat shift,
  electronic boost control, nitrous, flex fuel, a second map set on a switch, closed loop on a wideband, traction, gear detection,
  four programmable outputs, water injection, a shift light on the dash lamp, remote control over the datalog cable, the trigger
  pattern log. Nothing is hardcoded to one ROM: the modules hook the skeleton&rsquo;s own extension points, so any mix assembles in
  any order, and the app keeps the checksum byte balanced so a ROM that sums itself still boots.</p>
  <p style="line-height:1.8; margin-top:14px; color:var(--muted)">Written in the same toolchain it is tested in &mdash; every
  module built, run and checked in the simulator, alone, in pairs and in the biggest mixes that fit, through over-rev, boost,
  a launch, a hot engine, a low battery and a sender losing oil pressure. <b style="color:#fff">ROMs built from the P30 skeleton have run on a car.</b>
  <b style="color:var(--amber)">The P13 skeleton has not yet</b>: it is checked in the simulator only.</p>
  <div class="filepair">
   <div class="filecard"><b>11,709</b><br>bytes free for modules<br>in the bare P30 skeleton</div>
   <div class="filecard"><b>6,749</b><br>bytes free for modules<br>in the bare P13 skeleton</div>
   <div class="filecard"><b>8</b><br>hook slots<br>at 7F00h</div>
   <div class="filecard"><b>57</b><br>feature modules<br>+ 13 stock functions, each</div>
   <div class="filecard"><b>2</b><br>processors simulated<br>MSM66207 and MSM66911</div>
   <div class="filecard"><b>5</b><br>reference ROM sources<br>in Templates/References</div>
  </div>
  <div style="margin-top:24px; overflow-x:auto">
  <table class="bugtable bt-stack bt-mem">
   <tr><th>P30 skeleton</th><th>What is there</th><th>Why it is pinned</th></tr>
   <tr><td class="enc">0000h-0037h</td><td class="is">Vectors</td><td class="note">Bare, the serial receive vector goes to the spurious-interrupt trap: the skeleton has no serial link until one is ticked, and a stray interrupt would eat the boot.</td></tr>
   <tr><td class="enc">0038h-5142h</td><td class="is">Skeleton code, then calibration</td><td class="note">Everything that runs the engine, one subsystem at a time from stock P30, and its tables packed straight after it &mdash; so stock P30 definitions and XDFs do not line up, and the source carries its own <span style="font-family:var(--mono);color:var(--green)">;@</span> names, layouts and axes for every table.</td></tr>
   <tr><td class="enc">5143h-7EFFh</td><td class="is"><b>Free for modules</b></td><td class="note">Where the assembler places whatever you ticked (the bare skeleton; a stock function put back moves the start up). The address is read from the info block rather than hard-coded.</td></tr>
   <tr><td class="enc">7F00h-7F17h</td><td class="is"><b>Hook table</b></td><td class="note">Eight 3-byte slots &mdash; init, main, fuel, ign and four spares &mdash; <span style="font-family:var(--mono)">RT, NOP, NOP</span> until a module writes <span style="font-family:var(--mono)">J &lt;module&gt;</span> over one.</td></tr>
   <tr><td class="enc">7FE0h-7FFFh</td><td class="is">Info block + checksum</td><td class="note">Layout version, the free range, the hook table and its slot count &mdash; then the byte that makes the 8-bit sum of the image 0, which the ROM can check while it runs. The P13 skeleton keeps the same table at 7F00h and its info block at 7FC0h (7FF0h stays the factory byte the stock code reads).</td></tr>
  </table>
  </div>
  <details class="rel">
   <summary>the <?= count($modules) ?> modules in the box, and the stock functions that can go back in</summary>
   <p style="color:var(--muted); margin-top:12px">Stock functions are the ones the skeleton took out and can rebuild
   (<span style="font-family:var(--mono);color:var(--green)">FEAT_STOCK_...</span>): trouble codes and fail-safes, knock
   retard, closed-loop O2, A/C, EGR, purge, O2 heater, the automatic transmission, the self-tests, the stock speed limiter,
   the stock serial link, the high-cam VE map and the VTEC oil-pressure switch.</p>
   <div class="catgrid" style="margin-top:14px">
   <?php $cat = null; foreach ($modules as $m): if ($m[0] !== $cat): $cat = $m[0]; ?>
    <div class="cat" style="border-left-color:var(--green); background:rgba(0,255,65,.07)"><b style="color:var(--green); font-size:.7rem"><?= htmlspecialchars($cat) ?></b></div>
   <?php endif; ?>
    <div class="cat"><span style="color:#fff"><?= htmlspecialchars($m[1]) ?></span><br><i><?= htmlspecialchars($m[2]) ?></i></div>
   <?php endforeach; ?>
   </div>
  </details>
 </div>

 <div class="two">
 <?php foreach ($release as $r): ?>
 <div class="glass">
 <p class="eyebrow"><?= $r['head'] ?></p>
 <?php foreach ($r['items'] as $it): ?>
 <p style="line-height:1.75; margin-top:12px; color:var(--muted)"><span style="color:var(--green)">[ + ]</span> <?= $it ?></p>
 <?php endforeach; ?>
 </div>
 <?php endforeach; ?>
 </div>
 </details>

 <!-- the releases before this one, so the history stays on the page -->
 <div class="glass reveal" style="margin-top:26px">
 <p class="eyebrow">Release history</p>
 <?php foreach ($past as $rel): ?>
 <details class="rel">
  <summary>v<?= $rel['v'] ?> <span style="color:var(--muted)">(from <?= $rel['from'] ?>)</span> &mdash; <?= $rel['sub'] ?></summary>
  <div class="two" style="margin-top:16px">
  <?php foreach ($rel['groups'] as $r): ?>
  <div style="border-left:3px solid rgba(255,159,0,.35); padding-left:14px">
  <p style="font-family:var(--mono); color:var(--amber); margin-bottom:6px"><?= $r['head'] ?></p>
  <?php foreach ($r['items'] as $it): ?>
  <p style="line-height:1.75; margin-top:10px; color:var(--muted)"><span style="color:var(--green)">[ + ]</span> <?= $it ?></p>
  <?php endforeach; ?>
  </div>
  <?php endforeach; ?>
  </div>
 </details>
 <?php endforeach; ?>
 <p style="color:var(--muted); margin-top:14px; font-size:.8rem">The release above is folded so this page stays short
 &mdash; open it for the <?= $changes ?> changes of <?= $previous ?> &rarr; <?= $version ?>. The releases before it are
 folded the same way, one click each.</p>
 </div>
</section>

<!-- ================= THE SILICON ================= -->
<section id="silicon">
  <h2 class="section-title reveal">Under the Hood: <span>Getting the Processor Right</span></h2>
  <p class="section-sub reveal">For developers &mdash; why the simulator can be trusted</p>
  <p class="reveal" style="color:var(--muted); line-height:1.8; margin:-18px 0 26px; max-width:1000px">You do not need this part to tune. A simulator is only useful if it does exactly what the real chip does: one wrong instruction and a ROM that looks fine on screen misbehaves in the car. This is how that was made sure of.</p>
  <div class="two">
    <div class="glass reveal">
      <p style="line-height:1.75">These ROMs are a minefield: timer-driven crank sync at 24 teeth per cam revolution,
      an A/D boot scan that eats 4.5 seconds, an interrupt storm per injector pulse, a serial datalog state machine built on
      <b style="color:var(--amber)">J [DP]</b> jump tables. The legacy toolchain carried the published opcode table with its
      errors intact and a WPF-only front end. Two decode bugs meant a stock ROM could <i>run</i> while doing the wrong thing.
      You cannot tune a ghost.</p>
      <div style="margin-top:18px" class="filepair">
        <div class="filecard"><b>4,642</b><br>addresses reached, broken decoder</div>
      </div>
    </div>
    <div class="glass reveal">
      <p style="line-height:1.75">The decoder was rebuilt against <b style="color:var(--green)">all 10,341 instructions</b>
      of the full HTS115 disassembly &mdash; the image the test suite rebuilds byte-identical: 0 non-decodes, 0 length
      mismatches, 0 mnemonic mismatches, plus a round trip over all 2,590 grammar rules and 97/97 on the ported CPU assertion suite.
      Loads set the zero flag. D0 is AND. Lazy trace formatting and cached decodes:
      <b style="color:var(--amber)">1.15M instructions/s</b>. The clock question closed too &mdash; the P28 crystal
      <b style="color:#fff">measures 10 MHz</b>: cycles at fOSC/4, timers /8, and the ROMs' rpm word comes out
      <i>exactly</i> 1,875,000/rpm.</p>
      <div style="margin-top:18px" class="filepair">
        <div class="filecard"><b>5,623</b><br>addresses reached, fixed decoder</div>
      </div>
    </div>
  </div>
  <div class="glass reveal" style="margin-top:26px; overflow-x:auto">
    <table class="bugtable bt-stack bt-bug">
      <tr><th>Encoding</th><th>The old table said</th><th>The silicon says</th><th>Why it mattered</th></tr>
      <?php foreach ($bugs as $b): ?>
      <tr>
        <td class="enc"><?= $b['enc'] ?></td>
        <td class="was"><?= $b['was'] ?></td>
        <td class="is"><?= $b['is'] ?></td>
        <td class="note"><?= $b['note'] ?></td>
      </tr>
      <?php endforeach; ?>
    </table>
  </div>
  <div class="statrow">
    <div class="stat g reveal"><b>10,341</b><span>HTS115 instructions verified</span></div>
    <div class="stat g reveal"><b>2,590</b><span>grammar rules round-tripped</span></div>
    <div class="stat reveal"><b>97/97</b><span>ported CPU assertions</span></div>
    <div class="stat reveal"><b>1.15M</b><span>instructions / second</span></div>
    <div class="stat reveal"><b>.NET</b><span>one runtime &mdash; nothing else</span></div>
  </div>
</section>

<!-- ================= ASSEMBLER ================= -->
<section id="assembler">
  <h2 class="section-title reveal">The Assembler: <span>Source In, Exact ROM Out</span></h2>
  <p class="section-sub reveal">For developers &mdash; the same bytes as the original tools</p>
  <p class="reveal" style="color:var(--muted); line-height:1.8; margin:-18px 0 26px; max-width:1000px">An assembler turns the readable program (a .asm file) into the ROM image the ECU runs (a .bin). This one produces exactly the bytes the original Honda-era tool (asm662) does, and refuses mistakes that tool let through silently.</p>
  <div class="two">
    <div class="glass reveal">
      <p style="line-height:1.8">Instead of re-deriving the 66207 instruction grammar, the managed assembler
      <b style="color:#fff">embeds asm662's own generated <span style="font-family:var(--mono);color:var(--green)">instrs.y</span></b>
      &mdash; 2,616 productions &mdash; and interprets its byte templates and <span style="font-family:var(--mono)">$n</span> actions.
      Byte-identity is structural, and the tests still prove it: HTS115 assembles byte-identical to asm662, and its disassembly
      round-trips to identical bytes.</p>
      <p style="line-height:1.8; margin-top:16px; color:var(--muted)">The stock assembler's silences were bugs: an undefined
      symbol warned and substituted 0 &mdash; silently mis-assembling <b style="color:var(--red)">every reference to the missing symbol</b>.
      Here, undefined symbols, duplicate labels, out-of-range branches, double-written addresses and code past end-of-ROM
      are <b style="color:#fff">errors</b>. Need the old behaviour for a bit-exact reproduction?
      <span style="font-family:var(--mono);color:var(--amber)">--compat</span> is one flag.</p>
    </div>
    <div class="term reveal">
      <div class="tbar"><span class="dot" style="background:#e10600"></span><span class="dot" style="background:#ff9f00"></span><span class="dot" style="background:#00ff41"></span>&nbsp;dotnet run --project tests/OkiRomSim.Tests</div>
      <pre><span class="c">$</span> dotnet run --project tests/OkiRomSim.Tests
[OK ] HTS115.asm assembles byte-identical to asm662  <span class="c">(150 ms)</span>
[OK ] HTS115.asm disassembly rebuilds byte-identical  <span class="c">(10,341 instrs)</span>
[OK ] HTS115.asm idles: pump ON, sequential injection <span class="c">(3.49 ms)</span>
[OK ] HTS115 fuel map detected 20x10 as HTS shows it
[OK ] HTS115 ignition map detected 20x10
[OK ] datalog frame decodes rpm 2500
[OK ] decoder == assembler on all 2,590 grammar rules
<span class="c"># extensions asm662 never had:</span>
<span class="a">  include / incbin / ds / align / if / ifdef / module
  assert / error / warning / message / define / undef
  db "strings" / comparison ops inside if &amp; assert</span>
[OK ] outputs: .bin .sym .map .lst + source map</pre>
    </div>
  </div>
</section>

<!-- ================= MCP ================= -->
<section id="mcp">
  <h2 class="section-title reveal">Let an AI Assistant <span>Help</span></h2>
  <p class="section-sub reveal">Optional &mdash; MCP server for Claude and other assistants</p>
  <p class="reveal" style="color:var(--muted); line-height:1.8; margin:-18px 0 26px; max-width:1000px">Optional, and off unless you turn it on. MCP is a standard way for an AI assistant to use a program's tools. Switch it on and an assistant can read your ROM, explain what a table does, run the simulator and make changes &mdash; on the ROM open on your screen, through the same undo and safety limits as your own edits.</p>
  <div class="two">
    <div class="glass reveal">
      <p style="line-height:1.8">The whole toolchain is also an <b style="color:#fff">MCP server</b>. Point an agent at it and it can
      disassemble your ROM, walk a routine like a developer, run it at any rpm, explain what reads a table,
      <b style="color:var(--green)">re-map cells by the dozen</b>, diff two tunes, even interrogate a ROM's own
      datalog format &mdash; and stream back what it saw. On the in-app server the agent works on the ROM
      <i>open on your screen</i>: every edit goes through undo, shows up live, and can auto-upload to the emulator.
      <b style="color:#fff">You watch it tune.</b></p>
      <p style="line-height:1.8; margin-top:16px; color:var(--muted)">Remote agents need no shared disk:
      <span style="font-family:var(--mono);color:var(--green)">file_upload / file_download / rom_upload / rom_download</span>
      move files as base64 chunks with a SHA-256 to check against. Since 0.0.0.2 a whole ROM can travel too:
      <span style="font-family:var(--mono);color:var(--green)">transfer_dir &rarr; file_upload &rarr; app_open</span> lands it on the user&#39;s screen. Hardened: one tool call at a time on its own large-stack
      thread with a time limit, errors returned as tool errors &mdash; never a crash; <span style="font-family:var(--mono)">include/incbin</span>
      confined to the workspace; remote HTTP requires an 8+ char password (constant-time compare, 5 failures lock the address
      out for 5 minutes), stored encrypted via DPAPI on Windows. Every call lands on the Debug page with its client address.</p>
    </div>
    <div class="term reveal">
      <div class="tbar"><span class="dot" style="background:#e10600"></span><span class="dot" style="background:#ff9f00"></span><span class="dot" style="background:#00ff41"></span>&nbsp;three ways to run it</div>
      <pre><?php foreach ($mcpModes as $m): ?><span class="a">$</span> <?= htmlspecialchars($m[0]) ?>   <span class="c"># <?= htmlspecialchars($m[1]) ?></span>
<?php endforeach; ?>
<span class="c"># what the agent sees (help lists them all):</span>
<span class="a">arch opcode assemble disassemble run symbols xref explore
detect_tables compare_bins datalog emulator simulator
cal_list cal_read cal_write cal_define cal_detect cal_explain
cal_formulas cal_save file_* rom_* file_edit file_edit_lines
cal_features app_open transfer_dir</span>
<span class="c"># cal_explain reads the CODE that uses a table, so the
# agent names maps by function, not by hex address.
# cal_save exports bin + defs JSON + TunerPro XDF.</span></pre>
    </div>
  </div>
  <div class="ytwrap reveal" id="mcpytsec" style="margin-top:26px">
    <div class="yt169"><div id="mcpytplayer"></div></div>
    <button class="ytunmute" id="mcpytunmute" type="button" hidden>&#128266; UNMUTE</button>
  </div>
  <div class="glass reveal" style="margin-top:26px">
    <div class="catgrid">
      <?php foreach ($mcpTools as $i => $t): ?>
        <div class="cat"><i>tool <?= str_pad((string)($i + 1), 2, '0', STR_PAD_LEFT) ?>:</i> <span style="color:var(--amber)"><?= htmlspecialchars($t[0]) ?></span><br><?= htmlspecialchars($t[1]) ?></div>
      <?php endforeach; ?>
    </div>
  </div>
</section>

<!-- ================= CLI ================= -->
<section id="cli">
  <h2 class="section-title reveal">A Command Line <span>for Scripts</span></h2>
  <p class="section-sub reveal">For developers &mdash; okisim does from a terminal what the program does in its window</p>
  <div class="term reveal">
    <div class="tbar"><span class="dot" style="background:#e10600"></span><span class="dot" style="background:#ff9f00"></span><span class="dot" style="background:#00ff41"></span>&nbsp;okisim --help</div>
    <pre><span class="c"><?php echo htmlspecialchars(implode("\n", $cli)) ?></span>

<span class="c">$</span> okisim run roms/HTS115.asm --steps 3000000 --rpm 800
[OK ] boot done (adc_wait_loop) &middot; 3,000,000 instr @ ~1.15M/s
[OK ] <span class="a">fuel pump ON &middot; 4/4 injectors firing once per engine cycle &middot; 3.49 ms</span>
[OK ] 5,623 unique addresses &middot; serial answering datalog requests
<span class="c"># the smoke harness (~100 CPU assertions, derived from the symbol
# table, not hardcoded) passes 97/97 against this image.</span></pre>
  </div>
  <div class="glass reveal" style="margin-top:26px; line-height:1.8">
    <p style="color:var(--muted)">The test suite is dependency-free: assembler-extension tests, the
    grammar&harr;decoder round trip over all <b style="color:#fff">2,590</b> rules, calibration tests
    (formulas, geometry, xref, writing the right raw byte), then the stock ROM: the
    .bin&nbsp;&rarr;&nbsp;.asm&nbsp;&rarr;&nbsp;.bin round trip, an 8-second idle run that must end with the pump on and four
    injectors firing, detected-map geometry, and a datalog frame that must decode to the rpm it was driven at.
    Pass <span style="font-family:var(--mono)">file.asm reference.bin</span> pairs to check byte-identity against asm662.</p>
  </div>
</section>

<!-- ================= VIDEO ================= -->
<section id="video">
  <div class="ytwrap reveal">
    <div class="yt169"><div id="ytplayer"></div></div>
    <button class="ytunmute" id="ytunmute" type="button" hidden>&#128266; UNMUTE</button>
  </div>
</section>

</main>
<footer>
  <div>OR<span class="a">S</span>S &mdash; <?= $product ?> v<?= $version ?> &mdash; <?= $tagline ?></div>
  <div>Tune OBD1 Honda ECUs &middot; datalog the car &middot; build a ROM from <span class="g">50</span> ready-made functions &middot; test it on a simulated ECU and engine first.</div>
  <div>Free to use, not to sell &mdash; see the <a href="docs/licence.html">licence</a>. Changing an engine computer is at your own risk.</div>
  <div><a href="<?= $zip ?>">Download</a> &middot; <a href="docs/">Guide</a> &middot; <a href="#intro">New here?</a> &middot; <a href="#mcp">AI assistants</a> &middot; <a href="https://discord.gg/xynkH3ymkH">Discord</a></div>
  <div>HTS115 is property of its respective owner. Not affiliated with Honda Motor Co., Ltd. or OKI.</div>
</footer>
<script>
"use strict";
const ROM = <?php echo json_encode($rom); ?>;
const MAPS = <?php echo json_encode($maps); ?>;
/* ============================================================
   BOOT INTRO
   ============================================================ */
const boot = document.getElementById("boot");
const bootlog = document.getElementById("bootlog");
const bootbar = document.getElementById("bootbar");
const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
const BOOTLINES = [
  '<span class="mt">$</span> orss --boot --workspace . --verify=all',
  '<span class="ok">[ OK ]</span> ecu         simulated Honda OBD1 engine computer (OKI MSM66207) &mdash; powered up',
  '<span class="ok">[ OK ]</span> engine      simulated engine turning &mdash; crank, cam and sensors feeding the ECU',
  '<span class="ok">[ OK ]</span> rom         program loaded &mdash; <span class="am">fuel pump on, injectors firing</span>',
  '<span class="ok">[ OK ]</span> maps        fuel and ignition maps found by reading the program',
  '<span class="ok">[ OK ]</span> datalog     the ECU answering the datalog cable &mdash; 2500 rpm read back',
  '<span class="ok">[ OK ]</span> tuner       tables ready to edit &mdash; the cells the engine uses lit as it runs',
  '<span class="ok">[ OK ]</span> builder     50 functions ready to build into a ROM of your own',
  '<span class="am">ORSS</span> READY. TUNE IT, OR BUILD YOUR OWN.'
];
function bootDone(){
  boot.style.transition = "opacity .45s"; boot.style.opacity = "0";
  setTimeout(() => boot.classList.remove("show"), 500);
}
if (!reduced){
  boot.classList.add("show");
  let li = 0;
  const tick = () => {
    if (li < BOOTLINES.length){
      bootlog.innerHTML += BOOTLINES[li] + "\n";
      li++;
      bootbar.style.width = Math.round(li / BOOTLINES.length * 100) + "%";
      setTimeout(tick, 100 + Math.random() * 190);
    } else setTimeout(bootDone, 420);
  };
  tick();
  boot.addEventListener("click", bootDone);
  addEventListener("keydown", e => { if (e.key === "Escape") bootDone(); });
}

/* ============================================================
   BACKGROUND: dense rain of 66207 glyphs + flying code
   fragments. As you scroll, code assembles into function
   blocks (one per ~1/15 of the page, 15 by the bottom) that
   then bounce around the screen forever.
   ============================================================ */
const cvs = document.getElementById("matrix");
const ctx = cvs.getContext("2d");
let W, H, SP = 0, rain = [], frags = [], funcs = [];
const FS = 12, MAXF = 15;
const GLYPHS = "0123456789ABCDEFh;,#+LCSTBMOVRAJEQNWXYDP_()x";
const FRAGS = [
  "LB A, trapReasonCode", "JNE nmi_brk", "SB TRNS2.0", "CAL table2d_lookup", "LC A, FUEL1_Lo",
  "MOVB TCON1, #0e0h", "CLR IRQ", "MB 020h.7, C", "MOV TM2R, A", "CMPB A, #050h",
  "ADD A, #001h", "STB A, 0C2h", "CAL isr_frame", "ADSCAN mux 6", "LCB A, rpm_row",
  "SJ main_loop", "AND IE, #02A0h", "SUB A, er2", "MULB", "JGE ign_hi_gate",
  "CAL scaler_lookup", "DB 68,123,145", "XCHG A, er2", "MOV DP, X1", "ST A, [DP]",
  "JBR off(212h).4", "SLLB A", "DEC r0", "INC X1", "SWAP", "J [DP]", "RETI",
  "CLR A", "SETSC", "CPL A", "RLCB A", "LC A, [X]+", "STB A, r7", "MOV Y, #0008h",
  "CMPB A, #050h", "CAL 31A0h", "JGE +6", "SJ -4", "MOV X1, #0210h", "AND B, #0Fh", "MOVB r6, #012h"
];
const FUNCS = [
  ["main_loop", ["LB A, trapReasonCode", "JNE nmi_brk", "CAL fuel_main", "SJ main_loop"]],
  ["tmr2_isr", ["MOV TM2R, A", "CAL rpm_filter", "RETI"]],
  ["adc_wait_loop", ["MOVB r0, #008h", "CAL mux_scan", "DEC r0", "JNE adc_wait_loop"]],
  ["table2d_lookup", ["CLR A", "LC A, [X1]", "CAL interp_line", "RT"]],
  ["inj_fire", ["SB TRNS2.0", "MB C, [DP].4", "STB A, 0C2h", "RET"]],
  ["ign_fire", ["MOVB TMR3, #7Eh", "SB P10.3", "MB C, [DP].4", "RET"]],
  ["fuel_main", ["MOV X1, #FUEL1_Lo", "CAL table2d", "MULB", "RET"]],
  ["isr_frame", ["MOV X1, #FRAME_BUF", "CAL checksum", "MOVB A, #20h", "STB A, SOUT"]],
  ["ser_state", ["LC A, [DP]", "MOV DP, A", "J [DP]"]],
  ["vtec_gate", ["CMP rpm, #02E8h", "JLS vtec_off", "SB P10.2", "vtec_off: RET"]],
  ["idle_pid", ["LB A, idle_target", "SUB A, rpm_now", "CAL clamp_helper", "RET"]],
  ["knock_filt", ["LC A, cal_knock", "SUB A, knock_cnt", "STB A, retard", "RET"]],
  ["scaler_lookup", ["MOVB r6, #012h", "CAL scaler_table", "LB A, r6", "RET"]],
  ["datalog_tx", ["CAL isr_frame", "INC frame_no", "STB A, SOUT", "RET"]],
  ["nmi_brk", ["LB A, trapCode", "STB A, 0F5h", "SJ standby"]]
];
const ease = t => t * t * (3 - 2 * t);

function initRain(){
  rain = [];
  const n = Math.ceil(W / FS);
  for (let i = 0; i < n; i++){
    rain.push({ x: i * FS, head: Math.random() * H * 2 - H, speed: 0.3 + Math.random() * 1.7,
      len: 9 + ((Math.random() * 21) | 0), cells: [], dim: Math.random() < 0.25 });
  }
}
function newFrag(s, x, y, burst){
  const sp = burst ? 1 : 0.55;
  return { s, x, y, w: s.length * 6.4,
    vx: (Math.random() - 0.5) * 2 * sp, vy: (Math.random() - 0.5) * 1.6 * sp,
    a: 0.4 + Math.random() * 0.22 + (burst ? 0.45 : 0), ph: Math.random() * 6.28,
    big: Math.random() < 0.1, amber: Math.random() < 0.16 };
}
function initFrags(){
  frags = [];
  const cap = W < 720 ? 260 : 900, floorN = W < 720 ? 120 : 420;
  const n = Math.max(floorN, Math.min(cap, Math.round(W * H / 2200)));
  for (let i = 0; i < n; i++)
    frags.push(newFrag(FRAGS[(Math.random() * FRAGS.length) | 0], Math.random() * W, Math.random() * H));
}
function spawnFunc(){
  const spec = FUNCS[funcs.length % FUNCS.length];
  const fs = W < 720 ? 9 : 12, lh = fs * 1.5, pad = 8;
  ctx.font = fs + "px Consolas,monospace";
  let tw = ctx.measureText(spec[0] + ":").width;
  const cw = ctx.measureText("M").width;
  for (const l of spec[1]) tw = Math.max(tw, ctx.measureText(l).width);
  const w = tw + pad * 2, h = (spec[1].length + 1) * lh + pad * 2;
  const f = { name: spec[0], lines: spec[1], fs, lh, w, h,
    x: 8 + Math.random() * Math.max(20, W - w - 16),
    y: 8 + Math.random() * Math.max(20, H - h - 16),
    vx: (Math.random() < 0.5 ? -1 : 1) * (0.25 + Math.random() * 0.55),
    vy: (Math.random() < 0.5 ? -1 : 1) * (0.18 + Math.random() * 0.45),
    born: performance.now(), chars: [], cw };
  // precompute glyph targets + scatter origins
  let ci = 0;
  const put = (str, row) => { for (let k = 0; k < str.length; k++, ci++)
    f.chars.push({ c: str[k], col: k, row, ox: (Math.random() - 0.5) * 2 * (140 + Math.random() * 260), oy: (Math.random() - 0.5) * 2 * (140 + Math.random() * 260), title: row === 0 }); };
  put(spec[0] + ":", 0);
  spec[1].forEach((l, li) => put(l, li + 1));
  funcs.push(f);
}
function shatterFunc(){
  const f = funcs.pop();
  if (!f) return;
  for (let i = 0; i < f.lines.length; i++)
    frags.push(newFrag(f.lines[i], f.x + 8, f.y + (i + 1.6) * f.lh, true));
  const g = newFrag(f.name + ":", f.x + 8, f.y + 1.6 * f.lh, true); g.amber = true; frags.push(g);
}
addEventListener("scroll", () => {
  const max = document.documentElement.scrollHeight - innerHeight;
  SP = max > 0 ? scrollY / max : 0;
  const want = Math.min(MAXF, Math.round(SP * MAXF));
  while (funcs.length < want) spawnFunc();
  while (funcs.length > want) shatterFunc();
}, { passive: true });
function resize(){
  W = cvs.width = innerWidth; H = cvs.height = innerHeight;
  initRain(); initFrags();
  for (const f of funcs){ f.x = Math.min(f.x, Math.max(6, W - f.w - 6)); f.y = Math.min(f.y, Math.max(6, H - f.h - 6)); }
}
addEventListener("resize", resize); resize();
if (scrollY > 0) addEventListener("load", () => dispatchEvent(new Event("scroll")));
const linkstat = document.getElementById("linkstat");
let frameNo = 0;

function frame(t){
  frameNo++;
  ctx.clearRect(0, 0, W, H);

  /* ---- layer 1: dense glyph rain ---- */
  ctx.font = FS + "px Consolas,monospace";
  for (const col of rain){
    col.head += col.speed * (col.dim ? 0.55 : 1);
    if (col.head - col.len * FS > H){
      col.head = -Math.random() * H * 0.6;
      col.speed = 0.3 + Math.random() * 1.7;
      col.len = 9 + ((Math.random() * 21) | 0);
      col.dim = Math.random() < 0.25; col.cells = [];
    }
    if (col.cells.length === 0 || Math.random() < 0.6) col.cells.unshift(GLYPHS[(Math.random() * GLYPHS.length) | 0]);
    if (col.cells.length > col.len) col.cells.length = col.len;
    const bright = col.dim ? 0.5 : 1;
    for (let k = col.cells.length - 1; k >= 0; k--){
      const y = col.head - k * FS;
      if (y < -FS || y > H + FS) continue;
      let a;
      if (k === 0) a = 0.5 * bright; else if (k < 3) a = 0.4 * bright;
      else a = Math.max(0, 0.3 - k / col.len * 0.4) * bright;
      if (a <= 0.02) continue;
      ctx.fillStyle = k === 0 ? "rgba(210,255,215," + a + ")" : k < 3 ? "rgba(120,255,140," + a + ")" : "rgba(0,255,65," + a + ")";
      ctx.fillText(col.cells[k], col.x, y);
    }
  }

  /* ---- layer 2: flying code fragments ---- */
  for (const fr of frags){
    fr.x += fr.vx; fr.y += fr.vy; fr.ph += 0.02;
    if (fr.x <= 0){ fr.x = 0; fr.vx = Math.abs(fr.vx); }
    else if (fr.x + fr.w >= W){ fr.x = W - fr.w; fr.vx = -Math.abs(fr.vx); }
    if (fr.y <= 10){ fr.y = 10; fr.vy = Math.abs(fr.vy); }
    else if (fr.y >= H - 4){ fr.y = H - 4; fr.vy = -Math.abs(fr.vy); }
    if (fr.a > 0.55) fr.a -= 0.003;
    const a = fr.a * (0.88 + 0.12 * Math.sin(fr.ph));
    ctx.font = (fr.big ? 12 : 9.5) + "px Consolas,monospace";
    ctx.fillStyle = fr.amber ? "rgba(255,190,60," + a + ")" : fr.big ? "rgba(115,235,150," + a + ")" : "rgba(40,255,90," + a + ")";
    ctx.fillText(fr.s, fr.x, fr.y);
  }

  /* ---- layer 3: assembled functions bouncing around ---- */
  for (const f of funcs){
    f.x += f.vx; f.y += f.vy;
    if (f.x < 6 || f.x + f.w > W - 6) f.vx = -f.vx;
    if (f.y < 6 || f.y + f.h > H - 6) f.vy = -f.vy;
    f.x = Math.max(6, Math.min(f.x, W - f.w - 6));
    f.y = Math.max(6, Math.min(f.y, H - f.h - 6));
    const p = ease(Math.max(0, Math.min(1, (t - f.born) / 700)));
    if (p <= 0) continue;
    ctx.fillStyle = "rgba(2,6,3," + (0.72 * p) + ")";
    ctx.fillRect(f.x, f.y, f.w, f.h);
    ctx.strokeStyle = "rgba(255,159,0," + (0.55 * p) + ")";
    ctx.lineWidth = 1;
    ctx.strokeRect(f.x + .5, f.y + .5, f.w - 1, f.h - 1);
    ctx.font = f.fs + "px Consolas,monospace";
    for (const ch of f.chars){
      const tx = f.x + 8 + ch.col * f.cw;
      const ty = f.y + 8 + (ch.row + 0.8) * f.lh;
      const x = tx + ch.ox * (1 - p), y = ty + ch.oy * (1 - p);
      ctx.fillStyle = ch.title
        ? "rgba(255,159,0," + (0.95 * p) + ")"
        : "rgba(0,255,65," + ((p < 1 ? 0.4 + 0.6 * p : 0.9) * 1) + ")";
      ctx.fillText(ch.c, x, y);
    }
  }
  linkstat.style.opacity = funcs.length >= MAXF ? 1 : 0;
  requestAnimationFrame(frame);
}
if (!reduced) requestAnimationFrame(frame);
/* the 3D map: 36 pictures a turn; it turns by itself, and follows a drag */
(() => {
  const box = document.getElementById("spin3d"), img = document.getElementById("spinimg");
  if (!box || !img) return;
  const N = 36, src = k => "docs/img/3d/" + String(((k % N) + N) % N).padStart(2, "0") + ".png";
  let k = 0, drag = null, visible = false, last = 0, loaded = false;
  const show = n => { k = ((n % N) + N) % N; img.src = src(k); };
  const load = () => { if (loaded) return; loaded = true; for (let i = 0; i < N; i++) new Image().src = src(i); };
  new IntersectionObserver(es => { visible = es[0].isIntersecting; if (visible) load(); }, { threshold: .2 }).observe(box);
  box.addEventListener("pointerdown", e => { drag = { x: e.clientX, k }; box.setPointerCapture(e.pointerId); });
  box.addEventListener("pointermove", e => { if (drag) show(drag.k - Math.round((e.clientX - drag.x) / 14)); });
  const end = () => { drag = null; last = performance.now() + 1500; };
  box.addEventListener("pointerup", end); box.addEventListener("pointercancel", end);
  if (!reduced) setInterval(() => { if (visible && !drag && performance.now() > last) show(k + 1); }, 120);
})();
/* ============================================================
   REVEAL ON SCROLL
   ============================================================ */
const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting){ e.target.classList.add("on"); io.unobserve(e.target); } }), { threshold: .12 });
document.querySelectorAll(".reveal").forEach(el => io.observe(el));
/* the changelog is folded by default; linking straight to it opens it */
const CL = document.getElementById("changelog");
if (CL) {
 if (location.hash === "#changelog") CL.open = true;
 document.querySelectorAll('a[href="#changelog"]').forEach(a =>
  a.addEventListener("click", () => { CL.open = true; }));
}
/* ============================================================
   STUDIO MOCK: tabs + live registers
   ============================================================ */
const IDEPanes = {
  "Source": '<span class="ln">1605</span>  <span class="cm">; base ignition map: FUEL/IGN via table2d_lookup_interp -</span>\n' +
'<span class="ln">1606</span>  <span class="cm">; the Detector reads THIS setup to find the 20x10 maps</span>\n' +
'<span class="ln">1607</span>                <span class="kw">MOVB</span>  r0, #018h           <span class="cm">; stride 24</span>\n' +
'<span class="ln">1608</span>                <span class="kw">MOVB</span>  r1, r6              <span class="cm">; rpm row  <- P_LO_Scaler search</span>\n' +
'<span class="ln">1609</span>                <span class="kw">MOVB</span>  r2, 0c0h            <span class="cm">; load col <- P_MAP_Scaler search</span>\n' +
'<span class="ln">1610</span>                <span class="kw">MOV</span>   X1, #IGN1_Lo        <span class="cm">; 0x729D, u8, x*0.25-6</span>\n' +
'<span class="ln">1611</span>  <span class="kw">ignmap_2d_lookup:</span> RB    PSWL.5          <span class="cm">; ign map: no multiplier row</span>\n' +
'<span class="ln">1612</span>                <span class="kw">CAL</span>   table2d_lookup_interp\n' +
'<span class="ln">1613</span>                <span class="kw">MOVB</span>  r0, A\n' +
'<span class="ln">1614</span>  <span class="kw">inj_fire:</span>\n' +
'<span class="ln">1615</span>                <span class="kw">SB</span>    TRNS2.0             <span class="cm">; injection feedback edge</span>\n' +
'<span class="ln">1616</span>                <span class="kw">LC</span>    A, FUEL1_Lo         <span class="cm">; LC sets ZF - fixed in this core</span>',
  "Trace": '2C47  CLR   IRQ\n2C4A  LB    A, ign_row          Z set by load\n2C4E  CAL   table2d_lookup_interp\n      -> 31A0  MOV  Y, #000Ah\n      -> 31A3  LC   A, [X]+      Z set by load\n2C51  ST    A, dwell_target\n3DEE  MB    020h.7, C           fuelpump_relay_drive\n2C54  SB    TRNS2.0             injection feedback\n---- tmr2_isr (VCAL) ----\n1F02  MOV   TM2R, A             CKP tooth 14/24\n1F05  RETI                      1 instruction runs, always\nSER   20h > 51 B + cksum        ISR frame @ 20 Hz',
  "Memory": '6EAD  44 7B 91 84 8B 93 8C 96 - 94 9B A8 A8 A8 A8 A8 A8   <- FUEL1_Lo r00 + stride pad\n6EBD  A8 A8 A8 A8 A8 A8 A8 A8 - 44 7B 91 84 8B 93 8C 96   r01 begins\n6ECD  94 9C A8 ...                                        \n708D  01 03 04 06 07 08 0A 0A - 0B 0B                     column multipliers',
  "Calibration": 'category: Fuel                       [ Detect ] [ + Add ] [ Import... ]\n\nFUEL1_Lo   @ 0x6EAD  20x10 u8  [honda_fuel ms]  mult@708D\nFUEL1_Hi   @ 0x70A5  20x10 u8  [honda_fuel ms]  mult@7285\nIGN1_Lo    @ 0x729D  20x10 u8  [ign_advance deg BTDC]\nVEhi       @ 0x7E0F  20x10 u8  [ve_percent %]\n... 9 maps + 69 switches + 460 defs detected from code\nload axis ends at 1039 mbar  -  exactly what HTS shows\nvalue edits patch the RUNNING ROM instantly - Save .bin keeps a .bak',
  "Datalog": 'port: simulator (virtual ECU)        protocol: auto -> ISR v2\n[CONN] 10h > ... CD < handshake OK     frame: 20h > 51 B + cksum\n\nrpm        2500    (word @1.875MHz)     map    34.1 kPa\ntps        42 %                        inject 3.49 ms\nect        85 C                        afr    14.7 (wideband)\nbatt       14.2 V                      knock  0 (aux: byte:37)\n\npacket monitor: 141 sent / 141 ok / 0 bad checksums\noverlay: AFR fix suggests -2.1% on cells the car sat in',
  "Problems": 'build: HTS115.asm - 150 ms - 0 errors - byte-identical to loaded image\n\nundefined symbols:      0   (asm662 would have warned and subbed 0)\nduplicate labels:       0\nbranch range:           ok  (out-of-range is an error here, not a shrug)\ndouble-written addrs:   0\ncode past end of ROM:   no\n\nnote: 3 comment-only edits since last build - nothing to rebuild.'
};
const idetabs = document.getElementById("idetabs");
const idepane = document.getElementById("idepane");
Object.keys(IDEPanes).forEach((k, i) => {
  const b = document.createElement("div");
  b.className = "tab" + (i === 0 ? " on" : ""); b.textContent = k;
  b.addEventListener("click", () => {
    idetabs.querySelectorAll(".tab").forEach(x => x.classList.remove("on"));
    b.classList.add("on"); idepane.innerHTML = IDEPanes[k];
  });
  idetabs.appendChild(b);
});
idepane.innerHTML = IDEPanes["Source"];

/* ============================================================
   RUN DEMO (numbers quote the README / test suite)
   ============================================================ */
const sim = { target: 800, running: true, rpm: 0, addrs: 0, t: 0, cranking: false };
const rtrace = document.getElementById("rtrace");
const rstatus = document.getElementById("rstatus");
const runbtn = document.getElementById("runbtn");
const gRpm = document.getElementById("gRpm"), gWord = document.getElementById("gWord");
const gPulse = document.getElementById("gPulse"), gAddr = document.getElementById("gAddr"), gSpeed = document.getElementById("gSpeed");
const TRACE_POOL = [
  ["2C4A","LB   A, ign_row","Z set by load"],
  ["2C4E","CAL  table2d_lookup_interp","FUEL1_Lo 20x10"],
  ["3DDE","MB   020h.7, C","fuelpump_relay_drive"],
  ["1F02","MOV  TM2R, A","CKP tooth -> tmr2_isr"],
  ["1F05","RETI","one instruction runs, always"],
  ["22B0","SB   TRNS2.0","injection feedback edge"],
  ["17A6","MB   C, [DP].4","coil charge, TRNS1 confirm"],
  ["--","INT1 < edge","TDC"],
  ["--","TRNS0 > pulse","CYP"],
  ["1042","ADSCAN mux 6","MAP = 34.2 kPa"],
  ["0Axx","SER  20h > frame","ISR 51 B + cksum @ 20 Hz"],
  ["0B20","CAL  table_interp_lookup","rpm word = 1,875,000/rpm"],
  ["18D0","AD1 mux 0","O2 = 450 mV"],
];
function pick(a){ return a[(Math.random() * a.length) | 0]; }
function pushTrace(cls, txt){
  const line = document.createElement("div");
  if (cls === "rd") line.className = "rd";
  else line.innerHTML = '<span class="ts">' + (sim.t * 14) + ' ms</span> ' + txt;
  rtrace.appendChild(line);
  while (rtrace.childElementCount > 12) rtrace.removeChild(rtrace.firstChild);
}
document.querySelectorAll("[data-rpm]").forEach(b => b.addEventListener("click", () => {
  document.querySelectorAll("[data-rpm]").forEach(x => x.classList.remove("on"));
  b.classList.add("on"); sim.target = +b.dataset.rpm;
  sim.cranking = sim.target < 400;
}));
runbtn.addEventListener("click", () => {
  sim.running = !sim.running;
  runbtn.classList.toggle("on", sim.running);
  runbtn.innerHTML = sim.running ? "RUN &nbsp;F5" : "PAUSE F5";
});
addEventListener("keydown", e => {
  if (e.key === "F5" && !boot.classList.contains("show")){ e.preventDefault(); runbtn.click(); }
});
setInterval(() => {
  if (!sim.running) return;
  sim.t++;
  sim.rpm += (sim.target - sim.rpm) * 0.08 + (Math.random() - 0.5) * 10;
  if (sim.cranking && sim.t > 30) sim.cranking = false;
  if (sim.cranking) sim.target = 250 + Math.random() * 120;
  if (sim.rpm < 1) sim.rpm = 0;
  const word = sim.rpm > 60 ? Math.round(1875000 / sim.rpm) : 0;
  if (sim.addrs < ROM.addrs) sim.addrs = Math.min(ROM.addrs, sim.addrs + ((ROM.addrs / 40) | 0) + ((Math.random() * 30) | 0));
  const pulse = sim.rpm < 50 ? 0 : ROM.idle_ms + Math.max(0, sim.rpm - 800) * 0.0011 + Math.random() * 0.04;
  gRpm.textContent = Math.round(sim.rpm);
  gWord.textContent = word.toLocaleString();
  gPulse.textContent = pulse.toFixed(2) + " ms";
  gAddr.textContent = sim.addrs.toLocaleString() + " / " + ROM.addrs.toLocaleString();
  gSpeed.textContent = (1.05 + Math.random() * 0.18).toFixed(2) + "M/s";
  gPulse.className = pulse === 0 ? "r" : "";
  const tr = pick(TRACE_POOL);
  pushTrace("", "<b>" + tr[0].padEnd(5) + "</b>  " + tr[1].padEnd(26) + " <span class=\"ts\">; " + tr[2] + "</span>");
  rtrace.scrollTop = rtrace.scrollHeight;
  rstatus.className = "";
  rstatus.innerHTML = (sim.cranking
    ? "CRANKING &mdash; &lt;400 rpm, starter maps active &mdash; it will catch in a moment&hellip;"
    : "RUNNING &mdash; HTS115 &middot; cycles 2.5 MHz &middot; fuel pump <b>ON</b> &middot; 4/4 injectors once per cycle &middot; ISR frames streaming");
  const iw = document.getElementById("ideWord"); if (iw) iw.textContent = word.toLocaleString();
}, 140);

/* studio register ticker */
setInterval(() => {
  if (document.hidden) return;
  const pc = (0x2000 + ((Math.random() * 0x900) | 0)).toString(16).toUpperCase();
  const el = document.getElementById("regPC"); if (el) el.textContent = pc;
  const cyc = document.getElementById("regCyc");
  if (cyc) cyc.textContent = (parseInt(cyc.textContent.replace(/,/g, "") || "0") + 350000 | 0).toLocaleString();
  const a = document.getElementById("regA"); if (a) a.textContent = ((Math.random() * 255) | 0).toString(16).toUpperCase().padStart(2, "0");
  const ir = document.getElementById("ideRpm"); if (ir) ir.textContent = Math.round(sim.rpm);
}, 400);

/* ============================================================
   THE MAPS — real data, HTS layout: RPM left, load top,
   cyan-green-yellow-red cells, hover = raw + address + value.
   ============================================================ */
const mv = document.getElementById("mapview");
const mctx = mv.getContext("2d");
const mapdesc = document.getElementById("mapdesc");
const maphdr = document.getElementById("maphdr");
const maptabs = document.getElementById("maptabs");
let curMap = 0, hover = null;
const fmtV = (v, d) => v.toFixed(d);
function mapVal(m, r, c){
  const raw = m.data[r][c];
  if (m.formula === "honda_fuel") return raw * (m.mult ? m.mult[c] : 1) / 4;
  if (m.formula === "ign_advance") return raw * 0.25 - 6;
  return raw * 100 / 128 - 100;
}
const GM = { mL: 86, mT: 54, mB: 34, mR: 16 };
function geo(){
  const rows = MAPS[curMap].data.length, cols = MAPS[curMap].data[0].length;
  return { rows, cols, cw: (mv.width - GM.mL - GM.mR) / cols, ch: (mv.height - GM.mT - GM.mB) / rows };
}
function drawMap(){
  const m = MAPS[curMap], g = geo();
  mctx.fillStyle = "#030604"; mctx.fillRect(0, 0, mv.width, mv.height);
  let mn = 1e9, mx = -1e9;
  for (let r = 0; r < g.rows; r++) for (let c = 0; c < g.cols; c++){ const v = mapVal(m, r, c); if (v < mn) mn = v; if (v > mx) mx = v; }
  /* load axis across the top, like HTS */
  mctx.font = "11px Consolas,monospace"; mctx.textAlign = "center"; mctx.textBaseline = "middle";
  mctx.fillStyle = "#ff9f00";
  for (let c = 0; c < g.cols; c++) mctx.fillText(Math.round(m.cols[c]), GM.mL + c * g.cw + g.cw / 2, GM.mT - 14);
  mctx.fillStyle = "#7b8794"; mctx.fillText("LOAD mbar  (map_mbar — axis ends 1039)", GM.mL + (mv.width - GM.mL - GM.mR) / 2, 14);
  for (let r = 0; r < g.rows; r++){
    for (let c = 0; c < g.cols; c++){
      const raw = m.data[r][c], v = mapVal(m, r, c);
      const n = (v - mn) / Math.max(1e-6, mx - mn);
      const x = GM.mL + c * g.cw, y = GM.mT + r * g.ch;
      const hov = hover && hover[0] === r && hover[1] === c;
      /* cyan -> green -> yellow -> red, like HTS */
      mctx.fillStyle = "hsl(" + Math.round(180 - 180 * n) + ",85%," + (hov ? 52 : 13 + 24 * n) + "%)";
      mctx.fillRect(x + 1, y + 1, g.cw - 2, g.ch - 2);
      if (hov){ mctx.strokeStyle = "#fff"; mctx.lineWidth = 2; mctx.strokeRect(x + 1, y + 1, g.cw - 2, g.ch - 2); }
      mctx.fillStyle = n > .55 ? "#fff" : "rgba(220,240,228,.92)";
      mctx.font = "10px Consolas,monospace";
      mctx.fillText(fmtV(v, m.dec), x + g.cw / 2, y + g.ch / 2);
    }
    mctx.fillStyle = "#ff9f00"; mctx.font = "10px Consolas,monospace"; mctx.textAlign = "right";
    mctx.fillText(Math.round(m.rows[r]), GM.mL - 8, GM.mT + r * g.ch + g.ch / 2);
    mctx.textAlign = "center";
  }
  mctx.save(); mctx.translate(14, GM.mT + g.rows * g.ch / 2); mctx.rotate(-Math.PI / 2);
  mctx.fillStyle = "#7b8794"; mctx.fillText("RPM  (rpm_axis_byte_log)", 0, 0); mctx.restore();
  maphdr.innerHTML = "<span class='a'>" + m.name + "</span> @ " + m.addr + " &middot; " + m.formula + " &middot; u8 &middot; 20&times;10" + (m.mult ? " &middot; mult row" : "");
}
MAPS.forEach((m, i) => {
  const b = document.createElement("div");
  b.className = "tab tab-a" + (i === 0 ? " on" : "");
  b.textContent = m.name;
  b.title = m.cat + " — " + m.addr;
  b.addEventListener("click", () => {
    maptabs.querySelectorAll(".tab").forEach(x => x.classList.remove("on"));
    b.classList.add("on"); curMap = i; hover = null; drawMap();
  });
  maptabs.appendChild(b);
});
mv.addEventListener("mousemove", e => {
  const rect = mv.getBoundingClientRect();
  const x = (e.clientX - rect.left) * (mv.width / rect.width);
  const y = (e.clientY - rect.top) * (mv.height / rect.height);
  const g = geo();
  const c = Math.floor((x - GM.mL) / g.cw), r = Math.floor((y - GM.mT) / g.ch);
  const nh = (r >= 0 && r < g.rows && c >= 0 && c < g.cols) ? [r, c] : null;
  if (JSON.stringify(nh) !== JSON.stringify(hover)){ hover = nh; drawMap(); }
  if (hover){
    const m = MAPS[curMap], raw = m.data[r][c], v = mapVal(m, r, c);
    const addr = parseInt(m.addr, 16) + r * 24 + c;
    mapdesc.innerHTML = m.name + " r" + r + ",c" + c + " @ 0x" + addr.toString(16).toUpperCase() +
      " &middot; raw <b>" + raw + "</b>" + (m.mult ? " &times; mult " + m.mult[c] : "") +
      " &rarr; " + m.formula + ": <b>" + fmtV(v, m.dec) + " " + m.unit + "</b>" +
      " &middot; " + Math.round(m.rows[r]) + " rpm &times; " + Math.round(m.cols[c]) + " mbar";
  }
});
mv.addEventListener("mouseleave", () => { hover = null; drawMap(); mapdesc.textContent = "— hover a cell —"; });
drawMap();

/* ============================================================
   FLOATING DEMO VIDEO — click "MSM66207" on the chip.
   The clip is ~18 s but can take a few seconds to start, so
   the window closes on 'ended', with a 30 s fallback timer.
   ============================================================ */
const floatvid = document.getElementById("floatvid");
const vid = document.getElementById("vid");
let vidCloseTimer = null;
function openVid(){
  floatvid.classList.add("show");
  vid.play().catch(() => {});          /* untilted videos can autoplay; controls let the user retry */
  clearTimeout(vidCloseTimer);
  vidCloseTimer = setTimeout(closeVid, 30000);
}
function closeVid(){
  clearTimeout(vidCloseTimer); vidCloseTimer = null;
  floatvid.classList.remove("show");
  vid.pause();
}
vid.addEventListener("ended", closeVid);
const chipBtn = document.getElementById("chipdemo");
chipBtn.addEventListener("click", openVid);
chipBtn.addEventListener("keydown", e => {
  if (e.key === "Enter" || e.key === " "){ e.preventDefault(); openVid(); }
});
document.getElementById("vclose").addEventListener("click", closeVid);
addEventListener("keydown", e => {
  if (e.key === "Escape" && floatvid.classList.contains("show")) closeVid();
});
/* drag it around by its title bar */
(function(){
  const bar = document.getElementById("vdrag");
  let drag = false, ox = 0, oy = 0;
  bar.addEventListener("pointerdown", e => {
    if (e.target.closest(".vclose")) return;
    drag = true;
    const r = floatvid.getBoundingClientRect();
    floatvid.style.transform = "none";
    floatvid.style.left = r.left + "px"; floatvid.style.top = r.top + "px";
    ox = e.clientX - r.left; oy = e.clientY - r.top;
    bar.setPointerCapture(e.pointerId);
  });
  bar.addEventListener("pointermove", e => {
    if (!drag) return;
    floatvid.style.left = Math.min(innerWidth - 60, Math.max(60 - floatvid.offsetWidth + 60, e.clientX - ox)) + "px";
    floatvid.style.top  = Math.max(0, Math.min(innerHeight - 40, e.clientY - oy)) + "px";
  });
  bar.addEventListener("pointerup", () => { drag = false; });
  bar.addEventListener("pointercancel", () => { drag = false; });
})();

/* ============================================================
   VIEWS — the studio's faces one after another under the
   screenshots: runs while in view and not pointed at, ◀ ▶ step.
   ============================================================ */
(() => {
  const box = document.getElementById("views");
  if (!box) return;
  const imgs = [...box.querySelectorAll("img[data-name]")];
  const name = document.getElementById("viewname"), what = document.getElementById("viewwhat");
  let at = 0, seen = false, held = false;
  function show(n) {
    at = (n + imgs.length) % imgs.length;
    imgs.forEach((im, i) => { im.style.opacity = i === at ? 1 : 0; if (i === (at + 1) % imgs.length) im.loading = "eager"; });
    name.textContent = imgs[at].dataset.name;
    what.innerHTML = "<b>" + imgs[at].dataset.name + "</b> &mdash; " + imgs[at].dataset.what;
  }
  show(0);
  setInterval(() => { if (seen && !held && !document.hidden) show(at + 1); }, 4200);
  document.getElementById("viewprev").addEventListener("click", () => show(at - 1));
  document.getElementById("viewnext").addEventListener("click", () => show(at + 1));
  box.addEventListener("pointerenter", () => held = true);
  box.addEventListener("pointerleave", () => held = false);
  new IntersectionObserver(es => es.forEach(e => seen = e.isIntersecting && e.intersectionRatio >= 0.3), { threshold: [0, 0.3, 0.6] }).observe(box);
})();

/* ============================================================
   YOUTUBE — autoplay (muted) when scrolled into view; the
   UNMUTE button is one click away. Same mount for the bottom
   walkthrough and the MCP-in-use demo in the MCP section.
   ============================================================ */
const ytMounts = [
  { sec: "video",    mount: "ytplayer",    btn: "ytunmute",    vid: "st-gk6p_jOo" },
  { sec: "mcpytsec", mount: "mcpytplayer", btn: "mcpytunmute", vid: "dLRFrE-MU20" },
];
const ytPlayers = {};
function ytTryStart(m){
  if (m.started) return;
  const p = ytPlayers[m.mount];
  if (!p || typeof p.playVideo !== "function") return;
  const r = document.getElementById(m.sec).getBoundingClientRect();
  if (r.top > innerHeight * 0.6) return;             /* not in view yet */
  m.started = true;
  p.mute();                                          /* autoplay policy: start muted... */
  try {
    const pr = p.playVideo();
    if (pr && pr.catch) pr.catch(() => { m.started = false; });
  } catch (e){ m.started = false; }
  document.getElementById(m.btn).hidden = false;     /* ...sound handed to the visitor */
}
window.onYouTubeIframeAPIReady = function(){
  ytMounts.forEach(m => {
    ytPlayers[m.mount] = new YT.Player(m.mount, {
      videoId: m.vid,
      playerVars: { rel: 0, playsinline: 1, modestbranding: 1 },
      events: { onReady: () => ytTryStart(m) }
    });
  });
};
(function(){
  const t = document.createElement("script");
  t.src = "https://www.youtube.com/iframe_api";
  document.body.appendChild(t);
})();
ytMounts.forEach(m => {
  new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting && e.intersectionRatio >= 0.4) ytTryStart(m); }),
    { threshold: [0, 0.4, 0.8] }).observe(document.getElementById(m.sec));
  document.getElementById(m.btn).addEventListener("click", () => {
    try { const p = ytPlayers[m.mount]; p.unMute(); p.playVideo(); } catch (e) {}
    document.getElementById(m.btn).hidden = true;
  });
});
</script>
</body>
</html>