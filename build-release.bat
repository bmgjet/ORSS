@echo off
rem Builds the release bundle of Rom Sim Studio: the program with its libraries inside RomSimStudio.dll, the
rem per-platform runtimes folder beside it, the Templates, and the ScanTool plugin in Plugins. Then zips it.
rem   Output:  dist\RomSimStudio\   and   dist\romsimstudio.zip
setlocal
cd /d "%~dp0"

set OUT=%~dp0dist\RomSimStudio
set ZIP=%~dp0dist\romsimstudio.zip

echo === Cleaning %OUT%
if exist "%OUT%" rmdir /s /q "%OUT%"
if exist "%ZIP%" del /q "%ZIP%"

echo === Publishing the bundle
dotnet publish "src\OkiRomSim.Desktop\OkiRomSim.Desktop.csproj" -c Release -p:Bundle=true -o "%OUT%"
if errorlevel 1 goto failed

echo === Building the ScanTool plugin
dotnet build "src\Plugins\ScanTool\ScanTool.csproj" -c Release
if errorlevel 1 goto failed
if not exist "%OUT%\Plugins" mkdir "%OUT%\Plugins"
copy /y "src\Plugins\ScanTool\bin\Release\net10.0\RomSim.ScanTool.dll" "%OUT%\Plugins\" >nul
if errorlevel 1 goto failed

echo === Zipping to %ZIP%
powershell -NoProfile -Command "Compress-Archive -Path '%OUT%\*' -DestinationPath '%ZIP%' -Force"
if errorlevel 1 goto failed

echo.
echo Done: %OUT%
echo       %ZIP%
goto end

:failed
echo.
echo *** Build failed - see the messages above.
set FAILED=1

:end
rem double-clicked from Explorer: keep the window open to read the result
echo %cmdcmdline% | find /i "%~0" >nul && pause
if defined FAILED exit /b 1
exit /b 0
