#Requires -Version 5.1
<#
.SYNOPSIS
    System monitoring dashboard — friendly status window for all configured monitors.
.DESCRIPTION
    Reads monitoring_settings.json and renders a colour-coded dashboard showing:
      - Which monitor scripts are running (badge row)
      - Every configured process with its LIVE running/stopped state
      - CPU, memory, disk, and network thresholds from the config
    Auto-refreshes every 15 seconds. Click Refresh to force an immediate update.
#>
param(
    [string]$SettingsFile = (Join-Path $PSScriptRoot '..\monitoring_settings.json')
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Load settings ──────────────────────────────────────────────────────────────
if (-not (Test-Path $SettingsFile)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Settings file not found:`n$SettingsFile", "Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}
$settings  = (Get-Content $SettingsFile -Raw -Encoding UTF8) | ConvertFrom-Json
$startedAt = Get-Date

# ── Colour palette ─────────────────────────────────────────────────────────────
$C = @{
    Bg        = [Drawing.Color]::FromArgb( 13,  20,  35)
    Header    = [Drawing.Color]::FromArgb( 20,  32,  54)
    BadgeRow  = [Drawing.Color]::FromArgb( 16,  26,  44)
    Card      = [Drawing.Color]::FromArgb( 35,  50,  78)
    White     = [Drawing.Color]::White
    Text      = [Drawing.Color]::FromArgb(210, 225, 245)
    Muted     = [Drawing.Color]::FromArgb(115, 140, 175)
    Divider   = [Drawing.Color]::FromArgb( 42,  62, 100)
    Green     = [Drawing.Color]::FromArgb( 40, 210,  96)
    GreenBg   = [Drawing.Color]::FromArgb( 14,  55,  28)
    Yellow    = [Drawing.Color]::FromArgb(240, 190,  40)
    YellowBg  = [Drawing.Color]::FromArgb( 62,  50,  10)
    Red       = [Drawing.Color]::FromArgb(238,  70,  70)
    RedBg     = [Drawing.Color]::FromArgb( 68,  16,  16)
    Blue      = [Drawing.Color]::FromArgb( 82, 162, 255)
    Cyan      = [Drawing.Color]::FromArgb( 50, 210, 220)
    Orange    = [Drawing.Color]::FromArgb(255, 155,  60)
}

# ── Fonts ──────────────────────────────────────────────────────────────────────
$fTitle  = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)
$fBold   = New-Object Drawing.Font('Segoe UI',  9, [Drawing.FontStyle]::Bold)
$fNorm   = New-Object Drawing.Font('Segoe UI',  9)
$fSmall  = New-Object Drawing.Font('Segoe UI',  8)
$fMono   = New-Object Drawing.Font('Consolas',  9)
$fBadge  = New-Object Drawing.Font('Segoe UI',  8, [Drawing.FontStyle]::Bold)
$fSub    = New-Object Drawing.Font('Segoe UI',  8)

# ── Script registry ────────────────────────────────────────────────────────────
$SCRIPTS = [ordered]@{
    processes = 'process_monitor.ps1'
    cpu       = 'monitor_cpu.ps1'
    memory    = 'monitor_memory.ps1'
    disk      = 'monitor_disk.ps1'
    network   = 'monitor_network.ps1'
}

$SCRIPT_LABELS = @{
    processes = 'Processes'
    cpu       = 'CPU'
    memory    = 'Memory'
    disk      = 'Disk'
    network   = 'Network'
}

# ── Status queries ─────────────────────────────────────────────────────────────
function Get-MonitorStatus {
    $allPs  = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)
    $allPs += @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'"       -ErrorAction SilentlyContinue)
    $out = @{}
    foreach ($key in $SCRIPTS.Keys) {
        $file     = $SCRIPTS[$key]
        $fullPath = Join-Path $PSScriptRoot $file
        $exists   = Test-Path $fullPath
        $running  = [bool]($allPs | Where-Object { $_.CommandLine -like "*$file*" })
        $out[$key] = @{ Exists = $exists; Running = $running }
    }
    return $out
}

function Get-LiveProcessStatus {
    $out = @{}
    foreach ($proc in $settings.processes) {
        $exe = $proc.name -replace '(?i)\.exe$', ''
        $out[$proc.name] = [bool]@(Get-Process -Name $exe -ErrorAction SilentlyContinue)
    }
    return $out
}

# ── Badge label references (key → Label control) ───────────────────────────────
$badgeLabels = @{}

function Update-Badges ($monStatus) {
    foreach ($key in $SCRIPTS.Keys) {
        $lbl = $badgeLabels[$key]
        if ($null -eq $lbl) { continue }
        $st = $monStatus[$key]
        if ($st.Running) {
            $lbl.Text      = "  $([char]0x25CF) $($SCRIPT_LABELS[$key])  "
            $lbl.ForeColor = $C.Green
            $lbl.BackColor = $C.GreenBg
        } elseif ($st.Exists) {
            $lbl.Text      = "  $([char]0x25CB) $($SCRIPT_LABELS[$key])  "
            $lbl.ForeColor = $C.Yellow
            $lbl.BackColor = $C.YellowBg
        } else {
            $lbl.Text      = "  $([char]0x2013) $($SCRIPT_LABELS[$key])  "
            $lbl.ForeColor = $C.Muted
            $lbl.BackColor = $C.Card
        }
    }
}

# ── RTB helper ────────────────────────────────────────────────────────────────
function rtb-add {
    param(
        [System.Windows.Forms.RichTextBox]$rtb,
        [string]$text,
        [Drawing.Color]$color,
        [Drawing.Font]$font,
        [bool]$nl = $true
    )
    $rtb.SelectionStart  = $rtb.TextLength
    $rtb.SelectionLength = 0
    $rtb.SelectionColor  = $color
    $rtb.SelectionFont   = $font
    $rtb.AppendText($text)
    if ($nl) { $rtb.AppendText("`n") }
}

# ── Main content builder ───────────────────────────────────────────────────────
function Build-Content {
    param(
        [System.Windows.Forms.RichTextBox]$rtb,
        $monStatus,
        $procStatus
    )

    $rtb.Clear()

    # Shortcut functions — all capture $rtb from the enclosing scope
    function a([string]$t, $clr, $fnt, [bool]$nl = $true) { rtb-add $rtb $t $clr $fnt $nl }
    function nl() { $rtb.AppendText("`n") }
    function div() { rtb-add $rtb ('-' * 60) $C.Divider $fMono }

    function Section-Header([string]$title, [string]$key) {
        nl
        $st = $monStatus[$key]
        if ($st.Running) {
            $icon = "$([char]0x25B6) "; $iClr = $C.Green
            $badge = ' RUNNING ';     $bClr = $C.Green;  $bBg = $C.GreenBg
        } elseif ($st.Exists) {
            $icon = "$([char]0x26A0) "; $iClr = $C.Yellow
            $badge = ' NOT STARTED '; $bClr = $C.Yellow; $bBg = $C.YellowBg
        } else {
            $icon = "$([char]0x25CB) "; $iClr = $C.Muted
            $badge = ' PENDING ';     $bClr = $C.Muted;  $bBg = $C.Card
        }
        a "  $icon" $iClr $fBold $false
        a "  $title  " $C.Cyan $fBold $false
        a $badge $bClr $fBadge
        div
    }

    function Item([string]$main, [string]$detail, [Drawing.Color]$dotColor) {
        a "    $([char]0x25B8) " $dotColor $fBold $false
        a $main $C.Text $fNorm
        if ($detail) { a "      $detail" $C.Muted $fSmall }
    }

    # ═══════════════════════════════════════════════════════════════════════════
    #  PROCESS MONITORING
    # ═══════════════════════════════════════════════════════════════════════════
    Section-Header 'PROCESS MONITORING' 'processes'

    $procList = @($settings.processes)
    if ($procList.Count -eq 0) {
        nl
        a '    No processes are configured in monitoring_settings.json.' $C.Muted $fSmall
    } else {
        foreach ($proc in $procList) {
            $alive  = $procStatus[$proc.name]
            $req    = if ($proc.required) { 'required' } else { 'optional' }
            $dotClr = if ($proc.required) { $C.Green } else { $C.Blue }

            nl
            a "    $([char]0x25B8) " $dotClr $fBold $false
            a "$($proc.display_name) " $C.White $fBold $false
            a "($($proc.name))" $C.Muted $fNorm $false
            a "   " $C.White $fNorm $false
            if ($alive) {
                a "$([char]0x25CF) RUNNING" $C.Green $fBadge
            } else {
                a "$([char]0x25CF) NOT RUNNING" $C.Red $fBadge
            }

            $actions = ($proc.actions.on_not_running | ForEach-Object { $_.type }) -join ', '
            a "      $req  |  check every $($proc.check_interval_sec)s  |  on down: $actions" $C.Muted $fSmall
        }
    }
    nl

    $st = $monStatus['processes']
    if (-not $st.Running -and $st.Exists) {
        a "  $([char]0x26A0)  Monitor script exists but is not running.  Run start_monitoring.bat to start it." $C.Yellow $fSmall
    } elseif (-not $st.Running -and -not $st.Exists) {
        a "  $([char]0x25CB)  Monitor script not yet created." $C.Muted $fSmall
    }
    nl

    # ═══════════════════════════════════════════════════════════════════════════
    #  CPU PERFORMANCE
    # ═══════════════════════════════════════════════════════════════════════════
    Section-Header 'CPU PERFORMANCE' 'cpu'
    a "    Check interval: every $($settings.performance.cpu.check_interval_sec)s" $C.Muted $fSmall
    foreach ($t in $settings.performance.cpu.thresholds) {
        $clr     = if ($t.level -eq 'critical') { $C.Red } else { $C.Yellow }
        $actions = ($t.actions | ForEach-Object { $_.type }) -join ', '
        Item "$($t.level.ToUpper())  -  >= $($t.percent)% sustained $($t.sustain_sec)s" "-> $actions" $clr
    }
    nl

    # ═══════════════════════════════════════════════════════════════════════════
    #  MEMORY PERFORMANCE
    # ═══════════════════════════════════════════════════════════════════════════
    Section-Header 'MEMORY PERFORMANCE' 'memory'
    a "    Check interval: every $($settings.performance.memory.check_interval_sec)s" $C.Muted $fSmall
    foreach ($t in $settings.performance.memory.thresholds) {
        $clr     = if ($t.level -eq 'critical') { $C.Red } else { $C.Yellow }
        $actions = ($t.actions | ForEach-Object { $_.type }) -join ', '
        Item "$($t.level.ToUpper())  -  >= $($t.percent)% sustained $($t.sustain_sec)s" "-> $actions" $clr
    }
    nl

    # ═══════════════════════════════════════════════════════════════════════════
    #  DISK MONITORING
    # ═══════════════════════════════════════════════════════════════════════════
    Section-Header 'DISK MONITORING' 'disk'
    foreach ($drive in $settings.disk) {
        nl
        a "    $($drive.display_name) ($($drive.drive))  |  every $($drive.check_interval_sec)s" $C.Text $fBold
        foreach ($t in $drive.thresholds) {
            $clr     = if ($t.level -eq 'critical') { $C.Red } else { $C.Yellow }
            $actions = ($t.actions | ForEach-Object { $_.type }) -join ', '
            Item "$($t.level.ToUpper())  -  at $($t.percent_used)% used" "-> $actions" $clr
        }
    }
    nl

    # ═══════════════════════════════════════════════════════════════════════════
    #  NETWORK MONITORING
    # ═══════════════════════════════════════════════════════════════════════════
    Section-Header 'NETWORK MONITORING' 'network'
    foreach ($net in $settings.network) {
        nl
        a "    $($net.name)  ($($net.host):$($net.port)  [$($net.protocol.ToUpper())])  |  every $($net.check_interval_sec)s" $C.Text $fBold
        foreach ($t in $net.thresholds) {
            $clr  = if ($t.level -eq 'critical') { $C.Red } else { $C.Yellow }
            $cond = if ($null -ne $t.latency_ms) { "latency > $($t.latency_ms)ms" } else { 'unreachable' }
            $actions = ($t.actions | ForEach-Object { $_.type }) -join ', '
            Item "$($t.level.ToUpper())  -  $cond" "-> $actions" $clr
        }
    }
    nl
    nl

    $rtb.SelectionStart = 0   # scroll back to top after rebuild
}

# ── Form ───────────────────────────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text            = "System Monitor Dashboard"
$form.Size            = New-Object Drawing.Size(590, 740)
$form.MinimumSize     = New-Object Drawing.Size(490, 520)
$form.StartPosition   = 'CenterScreen'
$form.BackColor       = $C.Bg
$form.ForeColor       = $C.White
$form.FormBorderStyle = 'Sizable'
$form.Font            = $fNorm

# ── Header panel ──────────────────────────────────────────────────────────────
$pHeader = New-Object System.Windows.Forms.Panel
$pHeader.Dock      = 'Top'
$pHeader.Height    = 82
$pHeader.BackColor = $C.Header

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = "$([char]0x25A0)  System Monitor Dashboard"
$lblTitle.Location  = New-Object Drawing.Point(18, 13)
$lblTitle.AutoSize  = $true
$lblTitle.ForeColor = $C.Cyan
$lblTitle.Font      = $fTitle

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text      = "v$($settings._meta.version)  |  Started $($startedAt.ToString('HH:mm:ss'))  |  $($startedAt.ToString('dddd, dd MMM yyyy'))"
$lblVersion.Location  = New-Object Drawing.Point(20, 50)
$lblVersion.Size      = New-Object Drawing.Size(550, 16)
$lblVersion.ForeColor = $C.Muted
$lblVersion.Font      = $fSub

$lblCfg = New-Object System.Windows.Forms.Label
$lblCfg.Text      = "Config: $((Resolve-Path $SettingsFile).Path)"
$lblCfg.Location  = New-Object Drawing.Point(20, 64)
$lblCfg.Size      = New-Object Drawing.Size(550, 14)
$lblCfg.ForeColor = [Drawing.Color]::FromArgb(75, 100, 140)
$lblCfg.Font      = New-Object Drawing.Font('Segoe UI', 7)

$pHeader.Controls.AddRange(@($lblTitle, $lblVersion, $lblCfg))
$form.Controls.Add($pHeader)

# ── Badges panel (monitor script status) ──────────────────────────────────────
$pBadges = New-Object System.Windows.Forms.Panel
$pBadges.Dock      = 'Top'
$pBadges.Height    = 40
$pBadges.BackColor = $C.BadgeRow

$lblMonitorsTitle = New-Object System.Windows.Forms.Label
$lblMonitorsTitle.Text      = 'MONITORS'
$lblMonitorsTitle.Location  = New-Object Drawing.Point(18, 12)
$lblMonitorsTitle.AutoSize  = $true
$lblMonitorsTitle.ForeColor = $C.Muted
$lblMonitorsTitle.Font      = $fBadge
$pBadges.Controls.Add($lblMonitorsTitle)

$badgeFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$badgeFlow.Location     = New-Object Drawing.Point(98, 7)
$badgeFlow.Size         = New-Object Drawing.Size(470, 28)
$badgeFlow.BackColor    = $C.BadgeRow
$badgeFlow.WrapContents = $false

foreach ($key in $SCRIPTS.Keys) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = "  $($SCRIPT_LABELS[$key])  "
    $lbl.AutoSize  = $true
    $lbl.ForeColor = $C.Muted
    $lbl.BackColor = $C.Card
    $lbl.Font      = $fBadge
    $lbl.Margin    = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
    $lbl.Padding   = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
    $badgeFlow.Controls.Add($lbl)
    $badgeLabels[$key] = $lbl
}

$pBadges.Controls.Add($badgeFlow)
$form.Controls.Add($pBadges)

# ── Footer panel ──────────────────────────────────────────────────────────────
$pFooter = New-Object System.Windows.Forms.Panel
$pFooter.Dock      = 'Bottom'
$pFooter.Height    = 56
$pFooter.BackColor = $C.Header

$sepLine = New-Object System.Windows.Forms.Panel
$sepLine.Dock      = 'Top'
$sepLine.Height    = 1
$sepLine.BackColor = $C.Divider
$pFooter.Controls.Add($sepLine)

$lblLastRefresh = New-Object System.Windows.Forms.Label
$lblLastRefresh.Text      = 'Last refresh: --'
$lblLastRefresh.Location  = New-Object Drawing.Point(18, 20)
$lblLastRefresh.Size      = New-Object Drawing.Size(160, 16)
$lblLastRefresh.ForeColor = $C.Muted
$lblLastRefresh.Font      = $fSub

function Make-Button([string]$text, [int]$x, [Drawing.Color]$bg, [Drawing.Color]$fg) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $text
    $b.Location  = New-Object Drawing.Point($x, 12)
    $b.Size      = New-Object Drawing.Size(130, 30)
    $b.BackColor = $bg
    $b.ForeColor = $fg
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = $C.Divider
    $b.Font      = $fBold
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    return $b
}

$btnRefresh = Make-Button "$([char]0x21BB)  Refresh"   190  $C.Card  $C.White
$btnStop    = Make-Button "$([char]0x25A0)  Stop All"  330  ([Drawing.Color]::FromArgb(75, 20, 20))  $C.Red
$btnClose   = Make-Button "$([char]0x2715)  Close"     448  $C.Card  $C.White

$pFooter.Controls.AddRange(@($lblLastRefresh, $btnRefresh, $btnStop, $btnClose))
$form.Controls.Add($pFooter)

# ── RichTextBox (main content area) ───────────────────────────────────────────
$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.Dock        = 'Fill'
$rtb.ReadOnly    = $true
$rtb.BackColor   = $C.Bg
$rtb.ForeColor   = $C.White
$rtb.BorderStyle = 'None'
$rtb.Font        = $fNorm
$rtb.ScrollBars  = 'Vertical'
$rtb.Padding     = New-Object System.Windows.Forms.Padding(12, 4, 12, 4)
$form.Controls.Add($rtb)

# Z-order: header top → badges → RTB fill → footer bottom
$form.Controls.SetChildIndex($pHeader,  0)
$form.Controls.SetChildIndex($pBadges,  1)
$form.Controls.SetChildIndex($rtb,      2)
$form.Controls.SetChildIndex($pFooter,  3)

# ── Central refresh function ───────────────────────────────────────────────────
function Do-Refresh {
    $monStatus  = Get-MonitorStatus
    $procStatus = Get-LiveProcessStatus
    Update-Badges  $monStatus
    Build-Content  $rtb $monStatus $procStatus
    $lblLastRefresh.Text = "Last refresh: $(Get-Date -Format 'HH:mm:ss')"
}

# ── Form events ───────────────────────────────────────────────────────────────
$form.Add_Shown({
    try { Do-Refresh }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Error loading status:`n$_", "Dashboard Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnRefresh.Add_Click({
    $btnRefresh.Enabled = $false
    $btnRefresh.Text    = 'Refreshing...'
    try { Do-Refresh } catch { }
    $btnRefresh.Text    = "$([char]0x21BB)  Refresh"
    $btnRefresh.Enabled = $true
})

$btnStop.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "Stop all running monitoring scripts?`nThis will terminate every active monitor.",
        "Confirm Stop All",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($ans -ne 'Yes') { return }

    $allPs  = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)
    $allPs += @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'"       -ErrorAction SilentlyContinue)
    $killed = 0
    foreach ($key in $SCRIPTS.Keys) {
        $file    = $SCRIPTS[$key]
        $targets = $allPs | Where-Object { $_.CommandLine -like "*$file*" }
        foreach ($t in $targets) {
            try { Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop; $killed++ } catch { }
        }
    }
    Start-Sleep -Milliseconds 700
    Do-Refresh
    [System.Windows.Forms.MessageBox]::Show(
        "Stopped $killed monitor process(es).",
        "Stop All - Done",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
})

$btnClose.Add_Click({ $form.Close() })

# Auto-refresh every 15 seconds while the window is open
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 15000
$timer.Add_Tick({ try { Do-Refresh } catch { } })
$timer.Start()

$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })

[System.Windows.Forms.Application]::Run($form)
