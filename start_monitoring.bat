@echo off
setlocal EnableDelayedExpansion
title Monitoring Launcher
cd /d "%~dp0"
color 0A

echo.
echo  ================================================
echo   Monitoring Solution  ^|  Starting up...
echo  ================================================
echo.

:: ══════════════════════════════════════════════════════════════════════════════
::  MONITOR SCRIPTS
::  Uncomment each line once the corresponding script file has been created.
:: ══════════════════════════════════════════════════════════════════════════════

:: 1. Process Monitor
call :LaunchScript "Process Monitor"      "%~dp0scripts\process_monitor.ps1"

:: 2. Performance Monitor (CPU + Memory)
call :LaunchScript "Performance Monitor"  "%~dp0scripts\performance_monitor.ps1"

:: 3. CPU Monitor        -- uncomment when scripts\monitor_cpu.ps1 exists
:: call :LaunchScript "CPU Monitor"    "%~dp0scripts\monitor_cpu.ps1"

:: 4. Memory Monitor     -- uncomment when scripts\monitor_memory.ps1 exists
:: call :LaunchScript "Memory Monitor" "%~dp0scripts\monitor_memory.ps1"

:: 5. Disk Monitor
call :LaunchScript "Disk Monitor"    "%~dp0scripts\monitor_disk.ps1"

:: 6. Network Monitor
call :LaunchScript "Network Monitor" "%~dp0scripts\monitor_network.ps1"

:: ══════════════════════════════════════════════════════════════════════════════

echo.
echo  Waiting for monitors to initialise...
timeout /t 3 /nobreak >nul

:: Open the Web Monitoring Console
call :LaunchPython "Monitoring Console" "%~dp0MonitoringConsole\monitoring_console.py"

echo.
echo  ================================================
echo   Done.  All monitors are running.
echo   This window will close automatically.
echo  ================================================
echo.
timeout /t 4 /nobreak >nul
endlocal
exit /b 0


:: ══════════════════════════════════════════════════════════════════════════════
::  SUBROUTINE  LaunchPython
::    %1  Window title   %2  Full path to the Python script
::  Skips if already running (checks python.exe / python3.exe command lines).
:: ══════════════════════════════════════════════════════════════════════════════
:LaunchPython
set "_TITLE=%~1"
set "_SCRIPT=%~2"
set "_NAME=%~n2"

if not exist "%_SCRIPT%" (
    echo  [SKIP]   %_TITLE%  -- script not found
    goto :eof
)

for /f "tokens=*" %%R in ('powershell -NoProfile -Command ^
    "$n='%_NAME%';" ^
    "$ps=Get-CimInstance Win32_Process -ErrorAction SilentlyContinue ^| Where-Object {" ^
    "  $_.Name -like 'python*' -and $_.CommandLine -like ('*'+$n+'*')" ^
    "};" ^
    "if ($ps) { 'yes' } else { 'no' }" ^
    2^>nul') do set "_RUNNING=%%R"

if /i "!_RUNNING!"=="yes" (
    echo  [SKIP]   %_TITLE%  -- already running
    goto :eof
)

echo  [START]  %_TITLE%
start "%_TITLE%" python "%_SCRIPT%"
goto :eof


:: ══════════════════════════════════════════════════════════════════════════════
::  SUBROUTINE  LaunchScript
::    %1  Window title shown in the taskbar
::    %2  Full path to the PowerShell script
::
::  Skips launch if the script file does not exist or is already running.
::  Detects both powershell.exe and pwsh.exe instances.
:: ══════════════════════════════════════════════════════════════════════════════
:LaunchScript
set "_TITLE=%~1"
set "_SCRIPT=%~2"
set "_NAME=%~n2"

if not exist "%_SCRIPT%" (
    echo  [SKIP]   %_TITLE%  -- script not found
    goto :eof
)

:: Query both powershell.exe and pwsh.exe, excluding the current process
for /f "tokens=*" %%R in ('powershell -NoProfile -Command ^
    "$n='%_NAME%';" ^
    "$ps=Get-CimInstance Win32_Process -ErrorAction SilentlyContinue ^| Where-Object {" ^
    "  ($_.Name -eq 'powershell.exe' -or $_.Name -eq 'pwsh.exe') -and" ^
    "  $_.ProcessId -ne $PID -and $_.CommandLine -like ('*'+$n+'*')" ^
    "};" ^
    "if ($ps) { 'yes' } else { 'no' }" ^
    2^>nul') do set "_RUNNING=%%R"

if /i "!_RUNNING!"=="yes" (
    echo  [SKIP]   %_TITLE%  -- already running
    goto :eof
)

echo  [START]  %_TITLE%
start "%_TITLE%" powershell -ExecutionPolicy Bypass -NoProfile ^
    -File "%_SCRIPT%"

goto :eof
