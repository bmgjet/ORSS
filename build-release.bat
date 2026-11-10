@echo off
rem Builds the release bundles of Rom Sim Studio (the full program) and RomSimTuner (the tuning-only build: the calibration
rem editor, datalogging and the ROM emulator, with no simulator, MCP server or plugins in it), zips each, and lays out the web
rem site ready to upload.
rem   build-release.bat [full^|tuner^|all] [RID] [sc^|single] [test] [nozip] [noweb]
rem     full / tuner / all   which program(s) (default: all)
rem     RID                  one platform only, e.g. win-x64, win-arm64, linux-x64, osx-arm64: only its native files go in
rem     sc                   with a RID: self-contained - the .NET runtime goes in too, nothing to install first (larger)
rem     single               with a RID: one .exe beside the Templates and lang folders (the tuner; see README "Release builds")
rem     test                 run the regression tests (tests\OkiRomSim.Tests) first, and stop if any fails
rem     nozip                leave the folders, make no zip
rem     noweb                do not lay out dist\website
rem   Output: dist\RomSimStudio\ and dist\romsimstudio.zip (with the ScanTool plugin in Plugins),
rem           dist\RomSimTuner\  and dist\romsimtuner.zip  - a RID adds -RID (and -sc / -single) to the names.
rem   With no RID, also dist\website\: everything to copy to the web host - the Website folder (the page and the guide), both
rem   zips, and each program's files for its updater (files\ = dist\RomSimStudio, files-tuner\ = dist\RomSimTuner).
rem   With no RID: the bundle this file has always made - the libraries inside the program's own .dll (EmbeddedLibraries.cs),
rem   every platform's native files in runtimes\ beside it, framework-dependent (the .NET 10 Runtime installed, and for Rom Sim
rem   Studio the ASP.NET Core 10 Runtime too). Never trimmed.
rem   On Linux and macOS: build-release.sh (the same options). Or plain dotnet commands (README, "Release builds").
setlocal
cd /d "%~dp0"

set WHAT=all
set RID=
set KIND=
set TEST=
set NOZIP=
set NOWEB=
:args
if "%~1"=="" goto argsdone
if /i "%~1"=="full" (set WHAT=full& shift & goto args)
if /i "%~1"=="tuner" (set WHAT=tuner& shift & goto args)
if /i "%~1"=="all" (set WHAT=all& shift & goto args)
if /i "%~1"=="sc" (set KIND=sc& shift & goto args)
if /i "%~1"=="single" (set KIND=single& shift & goto args)
if /i "%~1"=="test" (set TEST=1& shift & goto args)
if /i "%~1"=="nozip" (set NOZIP=1& shift & goto args)
if /i "%~1"=="noweb" (set NOWEB=1& shift & goto args)
set RID=%~1
shift
goto args
:argsdone
if defined KIND if not defined RID (echo *** sc and single need a RID ^(win-x64, say^) & set FAILED=1 & goto end)
rem a runtime identifier has a dash in it (win-x64); with no RID given there is nothing to check (a substitution on an unset
rem variable here broke the parse of the whole line)
if not defined RID goto ridok
echo %RID%| find "-" >nul || (echo *** "%RID%" is neither an option nor a runtime identifier ^(win-x64, linux-x64, osx-arm64...^) & set FAILED=1 & goto end)
:ridok

where dotnet >nul 2>nul || (echo *** The .NET 10 SDK is needed: https://dotnet.microsoft.com/download & set FAILED=1 & goto end)
set DOTNET_CLI_TELEMETRY_OPTOUT=1

rem a name for this kind of build, and its own build folders (a self-contained build must not reuse what another kind left)
set SUFFIX=
set VARIANT=bundle
if defined RID (
  set SUFFIX=-%RID%
  set VARIANT=%RID%-fd
  if "%KIND%"=="sc" (set SUFFIX=-%RID%-sc& set VARIANT=%RID%-sc)
  if "%KIND%"=="single" (set SUFFIX=-%RID%-single& set VARIANT=%RID%-single)
)

if defined TEST (
  echo === Regression tests
  dotnet run --project tests\OkiRomSim.Tests -c Release
  if errorlevel 1 goto failed
)

if not exist dist mkdir dist
if /i "%WHAT%"=="full" call :publish OkiRomSim.Desktop RomSimStudio romsimstudio
if /i "%WHAT%"=="tuner" call :publish OkiRomSim.Tuner RomSimTuner romsimtuner
if /i "%WHAT%"=="all" (
  call :publish OkiRomSim.Desktop RomSimStudio romsimstudio
  if not defined FAILED call :publish OkiRomSim.Tuner RomSimTuner romsimtuner
)
if defined FAILED goto failed
rem the web site serves the bundle (the build with no RID), so only that one is laid out for it
if not defined RID if not defined NOWEB call :website
if defined FAILED goto failed

echo.
echo Done: dist\RomSimStudio%SUFFIX% and dist\RomSimTuner%SUFFIX% (whichever were asked for), and their zips.
if not defined RID if not defined NOWEB echo The web site, ready to copy to the host: dist\website
goto end

rem ---- :publish <project> <program> <zipname>   (paths relative to this folder, where the cd at the top put us)
:publish
set OUT=dist\%2%SUFFIX%
set ZIP=dist\%3%SUFFIX%.zip
set SC=false
if "%KIND%"=="sc" set SC=true
set EXTRA=
if "%KIND%"=="single" set EXTRA=-p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
echo === %2 (%VARIANT%) to %OUT%
if exist "%OUT%" rmdir /s /q "%OUT%"
if exist "%ZIP%" del /q "%ZIP%"
if not defined RID (
  dotnet publish "src\%1\%1.csproj" -c Release -p:Bundle=true -o "%OUT%"
) else (
  dotnet publish "src\%1\%1.csproj" -c Release -r %RID% -p:SelfContained=%SC% -p:IntermediateOutputPath=obj\publish-%VARIANT%\ -p:OutputPath=bin\publish-%VARIANT%\ %EXTRA% -o "%OUT%"
)
if errorlevel 1 (set FAILED=1 & goto :eof)
if /i "%2"=="RomSimStudio" (
  echo === Building the ScanTool plugin
  dotnet build "src\Plugins\ScanTool\ScanTool.csproj" -c Release
  if errorlevel 1 (set FAILED=1 & goto :eof)
  if not exist "%OUT%\Plugins" mkdir "%OUT%\Plugins"
  copy /y "src\Plugins\ScanTool\bin\Release\net10.0\RomSim.ScanTool.dll" "%OUT%\Plugins\" >nul
  if errorlevel 1 (set FAILED=1 & goto :eof)
)
if defined NOZIP goto :eof
echo === Zipping to %ZIP%
powershell -NoProfile -Command "Compress-Archive -Path '%OUT%\*' -DestinationPath '%ZIP%' -Force"
if errorlevel 1 (set FAILED=1 & goto :eof)
goto :eof

rem ---- :website   dist\website = Website + the zips + each program's files for its updater (whatever dist holds for each)
:website
set WEB=dist\website
echo === Web site to %WEB%
if exist "%WEB%" rmdir /s /q "%WEB%"
rem the page and the guide: no dot-files, no Explorer thumbnail caches
robocopy Website "%WEB%" /E /XF Thumbs.db desktop.ini .* /XD .* /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 (set FAILED=1 & goto :eof)
if exist dist\romsimstudio.zip copy /y dist\romsimstudio.zip "%WEB%\" >nul
if exist dist\romsimtuner.zip copy /y dist\romsimtuner.zip "%WEB%\" >nul
rem the updaters' lists (index.php?updates): Rom Sim Studio's in files\, RomSimTuner's in files-tuner\
if exist dist\RomSimStudio\RomSimStudio.dll (
  robocopy dist\RomSimStudio "%WEB%\files" /E /XF Thumbs.db desktop.ini /NFL /NDL /NJH /NJS /NP >nul
  if errorlevel 8 (set FAILED=1 & goto :eof)
  echo     files\        Rom Sim Studio, for its updater
)
if exist dist\RomSimTuner\RomSimTuner.dll (
  robocopy dist\RomSimTuner "%WEB%\files-tuner" /E /XF Thumbs.db desktop.ini /NFL /NDL /NJH /NJS /NP >nul
  if errorlevel 8 (set FAILED=1 & goto :eof)
  echo     files-tuner\  RomSimTuner, for its updater
)
if exist "%WEB%\romsimstudio.zip" echo     romsimstudio.zip
if exist "%WEB%\romsimtuner.zip" echo     romsimtuner.zip
goto :eof

:failed
echo.
echo *** Build failed - see the messages above.
set FAILED=1

:end
rem double-clicked from Explorer: keep the window open to read the result
echo %cmdcmdline% | find /i "%~0" >nul && pause
if defined FAILED exit /b 1
exit /b 0
