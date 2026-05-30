#Requires -Version 5.1
$ErrorActionPreference = 'Continue'

try { $Host.UI.RawUI.WindowTitle = 'Monitoring Launcher' } catch {}

$scriptDir  = $PSScriptRoot
$rootDir    = Split-Path $scriptDir -Parent
$vbsPath    = Join-Path $scriptDir 'run_hidden.vbs'
$stopScript = Join-Path $scriptDir 'stop_monitoring.ps1'
$consolePy  = Join-Path $rootDir   'MonitoringConsole\monitoring_console.py'

# All monitor scripts required before the console is allowed to open.
# Remove an entry if the script has been decommissioned.
$MONITORS = @(
    [ordered]@{ Label = 'Process Monitor';      File = 'process_monitor.ps1'     }
    [ordered]@{ Label = 'Performance Monitor';  File = 'performance_monitor.ps1' }
    [ordered]@{ Label = 'Disk Monitor';         File = 'monitor_disk.ps1'        }
    [ordered]@{ Label = 'Network Monitor';      File = 'monitor_network.ps1'     }
    [ordered]@{ Label = 'Ebook Sales Monitor';  File = 'monitor_ebook_sales.ps1' }
)

$DIVIDER = '  ' + ('=' * 50)

# ── Helpers ───────────────────────────────────────────────────────
function Test-MonitorRunning ([string]$FileName) {
    $n = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    return [bool](
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name     -like 'power*'   -and
            $_.ProcessId -ne  $PID       -and
            $_.CommandLine -like "*$n*"
        }
    )
}

function Start-MonitorScript ([string]$Path) {
    Start-Process -FilePath 'wscript' `
        -ArgumentList "//nologo `"$vbsPath`" `"$Path`"" `
        -WindowStyle Hidden
}

function Write-StatusPanel ([int]$Elapsed) {
    Clear-Host
    Write-Host ''
    Write-Host $DIVIDER -ForegroundColor DarkCyan
    Write-Host ("   Monitor Status  |  {0,2}s elapsed" -f $Elapsed) -ForegroundColor Cyan
    Write-Host $DIVIDER -ForegroundColor DarkCyan
    Write-Host ''

    $allOk = $true
    foreach ($m in $MONITORS) {
        $path = Join-Path $scriptDir $m.File
        if (-not (Test-Path $path)) {
            Write-Host ("  [ SKIP ]  {0}" -f $m.Label) -ForegroundColor DarkGray
            continue
        }
        if (Test-MonitorRunning $m.File) {
            Write-Host ("  [  OK  ]  {0}" -f $m.Label) -ForegroundColor Green
        } else {
            Write-Host ("  [ WAIT ]  {0}" -f $m.Label) -ForegroundColor Yellow
            $allOk = $false
        }
    }

    Write-Host ''
    return $allOk
}

# ── Step 1: stop existing monitors ────────────────────────────────
Clear-Host
Write-Host ''
Write-Host $DIVIDER -ForegroundColor DarkCyan
Write-Host '   Monitoring Launcher  |  Starting up...' -ForegroundColor Cyan
Write-Host $DIVIDER -ForegroundColor DarkCyan
Write-Host ''
Write-Host '  Stopping any running monitors...' -ForegroundColor Yellow
powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -File $stopScript
Write-Host ''

# ── Step 2: launch all monitor scripts ────────────────────────────
Write-Host '  Launching monitors...' -ForegroundColor Yellow
foreach ($m in $MONITORS) {
    $path = Join-Path $scriptDir $m.File
    if (Test-Path $path) {
        Start-MonitorScript $path
        Write-Host ("  [LAUNCH]  {0}" -f $m.Label) -ForegroundColor Cyan
    } else {
        Write-Host ("  [ SKIP ]  {0}  -- script not found" -f $m.Label) -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host '  Waiting for processes to register...' -ForegroundColor DarkGray
Start-Sleep -Seconds 3

# ── Step 3: live status loop ───────────────────────────────────────
$maxSeconds = 60
$interval   = 2
$elapsed    = 3    # already waited 3s above
$allOk      = $false

while ($true) {
    $allOk = Write-StatusPanel -Elapsed $elapsed

    if ($allOk)              { break }
    if ($elapsed -ge $maxSeconds) { break }

    Write-Host ("  Checking again in {0}s..." -f $interval) -ForegroundColor DarkGray
    Start-Sleep -Seconds $interval
    $elapsed += $interval
}

Write-Host ''

# ── Step 4: open console or halt ──────────────────────────────────
if ($allOk) {
    Write-Host '  All monitors confirmed running.' -ForegroundColor Green
    Write-Host ''

    $consoleRunning = Get-NetTCPConnection -LocalPort 5758 -State Listen -ErrorAction SilentlyContinue
    if ($consoleRunning) {
        Write-Host '  [ SKIP ]  Monitoring Console already running on port 5758.' -ForegroundColor DarkGray
    } elseif (Test-Path $consolePy) {
        Start-Process -FilePath 'pythonw' -ArgumentList "`"$consolePy`""
        Write-Host '  [LAUNCH]  Monitoring Console' -ForegroundColor Cyan
    } else {
        Write-Host '  [ WARN ]  Monitoring Console script not found.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '  Done. This window closes in 5 seconds.' -ForegroundColor DarkGray
    Start-Sleep -Seconds 5

} else {
    Write-Host '  FAILED: the following monitors did not start in time:' -ForegroundColor Red
    Write-Host ''
    foreach ($m in $MONITORS) {
        $path = Join-Path $scriptDir $m.File
        if ((Test-Path $path) -and -not (Test-MonitorRunning $m.File)) {
            Write-Host ("    - {0}  ({1})" -f $m.Label, $m.File) -ForegroundColor Red
        }
    }
    Write-Host ''
    Write-Host '  The monitoring console will NOT be opened.' -ForegroundColor Red
    Write-Host '  Investigate the scripts listed above, then re-run.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Press any key to close...' -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 15 }
}
