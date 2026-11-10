#!/usr/bin/env bash
# Release builds of Rom Sim Studio (the full program) and RomSimTuner (the tuning-only build) on Linux and macOS - the same
# builds build-release.bat makes on Windows. Plain dotnet commands for the same: README, "Release builds".
#
#   ./build-release.sh [full|tuner|all] [--rid RID] [--self-contained] [--single-file] [--test] [--no-zip] [--no-web]
#
#   full | tuner | all   which program(s) to build (default: all)
#   --rid RID            for one platform only (linux-x64, linux-arm64, osx-arm64, osx-x64, win-x64...): only that platform's native
#                        libraries go in, instead of every platform's (the default, which runs anywhere .NET 10 does)
#   --self-contained     with --rid: the .NET runtime goes in too, so nothing has to be installed first (larger)
#   --single-file        with --rid: one executable plus the Templates and lang folders (the tuner; see README "Release builds")
#   --test               run the regression tests (tests/OkiRomSim.Tests) first, and stop if any fails
#   --no-zip             leave the folders, make no zip
#   --no-web             do not lay out dist/website
#
# Output: dist/RomSimStudio[-RID[-sc|-single]]/ and dist/RomSimTuner[...]/ - each in a folder of its own - and a .zip of each.
# The default (no --rid) is the bundle build.bat has always made: framework-dependent, the libraries inside the program's own .dll
# (EmbeddedLibraries.cs), every platform's native files beside it in runtimes/. Never trimmed (see README).
# With no --rid, also dist/website/: everything to copy to the web host - the Website folder (the page and the guide), both zips,
# and each program's files for its updater (files/ = dist/RomSimStudio, files-tuner/ = dist/RomSimTuner).
set -euo pipefail
cd "$(dirname "$0")"

what=all; rid=""; sc=false; single=false; test=false; zip=true; web=true
while [ $# -gt 0 ]; do
  case "$1" in
    full|tuner|all) what=$1 ;;
    --rid) rid=${2:?--rid needs a runtime identifier}; shift ;;
    --self-contained) sc=true ;;
    --single-file) single=true ;;
    --test) test=true ;;
    --no-zip) zip=false ;;
    --no-web) web=false ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (--help lists them)" >&2; exit 2 ;;
  esac
  shift
done
if { $sc || $single; } && [ -z "$rid" ]; then echo "--self-contained and --single-file need --rid (one platform)" >&2; exit 2; fi
command -v dotnet >/dev/null || { echo "the .NET 10 SDK is needed: https://dotnet.microsoft.com/download" >&2; exit 1; }
export DOTNET_CLI_TELEMETRY_OPTOUT=1

# a name for this kind of build, and its own intermediate folders: a self-contained build must not reuse what a framework-dependent
# one left (it can carry the runtime into the next)
suffix=""; variant=bundle
if [ -n "$rid" ]; then
  variant=$rid; suffix="-$rid"
  if $single; then variant="$variant-single"; suffix="$suffix-single"; elif $sc; then variant="$variant-sc"; suffix="$suffix-sc"; else variant="$variant-fd"; fi
fi

if $test; then
  echo "=== Regression tests"
  dotnet run --project tests/OkiRomSim.Tests -c Release
fi

publish() {   # project-dir program-name
  local proj=$1 name=$2 out="dist/$2$suffix"
  echo "=== $name ($variant) -> $out"
  rm -rf "$out"
  local args=(publish "src/$proj/$proj.csproj" -c Release -o "$out" -nologo)
  if [ -z "$rid" ]; then
    args+=(-p:Bundle=true)
  else
    args+=(-r "$rid" "-p:SelfContained=$sc" "-p:IntermediateOutputPath=obj/publish-$variant/" "-p:OutputPath=bin/publish-$variant/")
    if $single; then args+=(-p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true); fi
  fi
  dotnet "${args[@]}"
  if [ "$name" = RomSimStudio ]; then
    echo "=== ScanTool plugin"
    dotnet build src/Plugins/ScanTool/ScanTool.csproj -c Release -nologo
    mkdir -p "$out/Plugins"
    cp src/Plugins/ScanTool/bin/Release/net10.0/RomSim.ScanTool.dll "$out/Plugins/"
  fi
  if $zip; then
    local z="dist/$(echo "$name" | tr '[:upper:]' '[:lower:]')$suffix.zip"
    rm -f "$z"
    if command -v zip >/dev/null; then (cd "$out" && zip -qr "../$(basename "$z")" .)
    elif command -v python3 >/dev/null; then python3 -c 'import shutil,sys; shutil.make_archive(sys.argv[1][:-4], "zip", sys.argv[2])' "$z" "$out"
    else echo "    (no zip or python3 here: the folder is left as it is)"; return; fi
    echo "    $z"
  fi
}

mkdir -p dist
case "$what" in
  full) publish OkiRomSim.Desktop RomSimStudio ;;
  tuner) publish OkiRomSim.Tuner RomSimTuner ;;
  all) publish OkiRomSim.Desktop RomSimStudio; publish OkiRomSim.Tuner RomSimTuner ;;
esac

# dist/website = Website + the zips + each program's files for its updater (whatever dist holds for each). The site serves the
# bundle (the build with no --rid), so only that one is laid out for it.
website() {
  local web=dist/website
  echo "=== Web site -> $web"
  rm -rf "$web"
  cp -R Website "$web"
  [ -f dist/romsimstudio.zip ] && cp dist/romsimstudio.zip "$web/" && echo "    romsimstudio.zip"
  [ -f dist/romsimtuner.zip ] && cp dist/romsimtuner.zip "$web/" && echo "    romsimtuner.zip"
  # the updaters' lists (index.php?updates): Rom Sim Studio's in files/, RomSimTuner's in files-tuner/
  [ -f dist/RomSimStudio/RomSimStudio.dll ] && cp -R dist/RomSimStudio "$web/files" && echo "    files/        Rom Sim Studio, for its updater"
  [ -f dist/RomSimTuner/RomSimTuner.dll ] && cp -R dist/RomSimTuner "$web/files-tuner" && echo "    files-tuner/  RomSimTuner, for its updater"
  # no dot-files, no Explorer thumbnail caches
  find "$web" \( -name '.*' -o -iname Thumbs.db -o -iname desktop.ini \) -prune -exec rm -rf {} +
}
if [ -z "$rid" ] && $web; then website; fi

echo
echo "Done. Run: dist/RomSimStudio$suffix/RomSimStudio (or dotnet RomSimStudio.dll) - dist/RomSimTuner$suffix/RomSimTuner"
if [ -z "$rid" ] && $web; then echo "The web site, ready to copy to the host: dist/website"; fi
