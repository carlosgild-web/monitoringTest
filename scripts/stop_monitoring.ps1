#Requires -Version 5.1
<#
.SYNOPSIS
    Terminates every active monitoring script launched by start_monitoring.bat.
.DESCRIPTION
    Queries Win32_Process for powershell.exe instances whose command line
    matches any known monitor script name, then stops them.
    Called by stop_monitoring.bat — do not run this script on its own
    if you want the formatted bat window output.
#>

$ErrorActionPreference = 'SilentlyContinue'

# Scripts managed by start_monitoring.bat (name without extension)
$MONITOR_SCRIPTS = @(
    'process_monitor',
    'monitor_cpu',
    'monitor_memory',
    'monitor_disk',
    'monitor_network',
    'monitoring_console',
    'show_status'
)

# ─── Helpers ──────────────────────────────────────────────────────────────────
function Write-Line ([string]$text, [ConsoleColor]$color = 'Gray') {
    Write-Host $text -ForegroundColor $color
}

# ─── Discover running monitor processes ───────────────────────────────────────
Write-Line "  Scanning for active monitoring processes..." Gray
$allPs  = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' AND ProcessId!=$PID" -ErrorAction SilentlyContinue)
$allPs += @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' AND ProcessId!=$PID"       -ErrorAction SilentlyContinue)

$found = [System.Collections.Generic.List[object]]::new()

foreach ($scriptName in $MONITOR_SCRIPTS) {
    $matches = @($allPs | Where-Object { $_.CommandLine -like "*$scriptName*" })
    foreach ($proc in $matches) {
        $found.Add([pscustomobject]@{
            Script = $scriptName
            PID    = $proc.ProcessId
        })
    }
}

# ─── Nothing to stop ──────────────────────────────────────────────────────────
if ($found.Count -eq 0) {
    Write-Host ""
    Write-Line "  No active monitoring processes found." Yellow
    return
}

# ─── Stop each process ────────────────────────────────────────────────────────
Write-Host ""
$stopped = 0
$failed  = 0

foreach ($item in $found) {
    try {
        Stop-Process -Id $item.PID -Force -ErrorAction Stop
        Write-Line "  [STOPPED]  $($item.Script)   (PID $($item.PID))" Red
        $stopped++
    }
    catch {
        Write-Line "  [FAILED ]  $($item.Script)   (PID $($item.PID)) - $_" Yellow
        $failed++
    }
}

# ─── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Line "  --------------------------------" DarkGray

if ($stopped -gt 0) {
    Write-Line "  Stopped : $stopped process(es)" Green
}
if ($failed -gt 0) {
    Write-Line "  Failed  : $failed process(es)" Yellow
}
Write-Line "  All monitors are now inactive." Green
