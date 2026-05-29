#Requires -Version 5.1
param(
    [string]$SettingsFile = (Join-Path $PSScriptRoot '..\monitoring_settings.json'),
    [string]$StateFile    = (Join-Path $PSScriptRoot '..\logs\process_state.json')
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Settings ──────────────────────────────────────────────────────────────────
if (-not (Test-Path $SettingsFile)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Settings file not found:`n$SettingsFile", 'Error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}
$settings = (Get-Content $SettingsFile -Raw -Encoding UTF8) | ConvertFrom-Json

# ── Palette ───────────────────────────────────────────────────────────────────
$BG          = [Drawing.Color]::FromArgb( 14,  21,  38)
$HEADER_BG   = [Drawing.Color]::FromArgb( 19,  31,  57)
$ENGINE_BG   = [Drawing.Color]::FromArgb( 23,  37,  68)
$CARD_BG     = [Drawing.Color]::FromArgb( 30,  46,  80)
$FOOTER_BG   = [Drawing.Color]::FromArgb( 19,  31,  57)
$DIVIDER     = [Drawing.Color]::FromArgb( 40,  60, 105)

$COL_WHITE   = [Drawing.Color]::White
$COL_TEXT    = [Drawing.Color]::FromArgb(208, 224, 248)
$COL_MUTED   = [Drawing.Color]::FromArgb(108, 136, 172)
$COL_CYAN    = [Drawing.Color]::FromArgb( 48, 212, 220)
$COL_GREEN   = [Drawing.Color]::FromArgb( 38, 210,  88)
$COL_GREEN2  = [Drawing.Color]::FromArgb( 26, 150,  62)   # accent bar
$COL_YELLOW  = [Drawing.Color]::FromArgb(240, 185,  38)
$COL_RED     = [Drawing.Color]::FromArgb(238,  66,  66)
$COL_RED2    = [Drawing.Color]::FromArgb(182,  40,  40)   # accent bar
$COL_ORANGE  = [Drawing.Color]::FromArgb(255, 150,  54)

# ── Fonts ─────────────────────────────────────────────────────────────────────
$FNT_TITLE    = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)
$FNT_SECT     = New-Object Drawing.Font('Segoe UI',  8, [Drawing.FontStyle]::Bold)
$FNT_BOLD9    = New-Object Drawing.Font('Segoe UI',  9, [Drawing.FontStyle]::Bold)
$FNT_NORM9    = New-Object Drawing.Font('Segoe UI',  9)
$FNT_SMALL8   = New-Object Drawing.Font('Segoe UI',  8)
$FNT_ENG      = New-Object Drawing.Font('Segoe UI',  9, [Drawing.FontStyle]::Bold)
$FNT_STATUS   = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$FNT_PROCNAME = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)

# ── Helpers ───────────────────────────────────────────────────────────────────
function Format-Age ([DateTime]$dt) {
    $s = [int]((Get-Date) - $dt).TotalSeconds
    if ($s -lt 60)  { return "${s}s ago" }
    $m = [int]($s / 60); $r = $s % 60
    if ($m -lt 60)  { return "${m}m ${r}s ago" }
    $h = [int]($m / 60); $rm = $m % 60
    return "${h}h ${rm}m ago"
}
function Format-Dur ([TimeSpan]$ts) {
    $s = [int]$ts.TotalSeconds
    if ($s -lt 60)  { return "${s}s" }
    $m = [int]($s / 60); $r = $s % 60
    if ($m -lt 60)  { return "${m}m ${r}s" }
    $h = [int]($m / 60); $rm = $m % 60
    return "${h}h ${rm}m"
}
function Parse-Date ([string]$str) {
    try { return [DateTime]::ParseExact($str, 'yyyy-MM-dd HH:mm:ss', $null) }
    catch { return $null }
}

# ── Data ──────────────────────────────────────────────────────────────────────
function Get-EngineInfo {
    $allPs  = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)
    $allPs += @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'"       -ErrorAction SilentlyContinue)
    $hit    = $allPs | Where-Object { $_.CommandLine -like '*process_monitor.ps1*' } | Select-Object -First 1

    $updated = $null; $age = $null
    if (Test-Path $StateFile) {
        try {
            $raw     = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $updated = Parse-Date $raw.updated
            if ($updated) { $age = (Get-Date) - $updated }
        } catch {}
    }
    return [pscustomobject]@{
        Running      = ($null -ne $hit)
        MonPID       = if ($hit) { $hit.ProcessId } else { $null }
        StateUpdated = $updated
        StateAge     = $age
    }
}

function Get-ProcessRows {
    $stateList = $null
    if (Test-Path $StateFile) {
        try {
            $raw = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $upd = Parse-Date $raw.updated
            if ($upd -and ((Get-Date) - $upd).TotalMinutes -le 5) { $stateList = $raw.processes }
        } catch {}
    }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $settings.processes) {
        $e = if ($stateList) { $stateList | Where-Object { $_.name -eq $p.name } | Select-Object -First 1 } else { $null }

        # Pull instructions from the first action that has an 'instructions' field.
        $instrText = ''
        foreach ($act in $p.actions.on_not_running) {
            if ($act.PSObject.Properties['instructions'] -and $act.instructions) {
                $instrText = $act.instructions; break
            }
        }

        if ($e) {
            $downSince = Parse-Date $e.down_since
            $downDur   = if ($downSince) { (Get-Date) - $downSince } else { $null }
            $lastCheck = Parse-Date $e.last_check
            $out.Add([pscustomobject]@{
                DisplayName      = $p.display_name
                Executable       = $p.name
                Required         = [bool]$p.required
                CheckSec         = [int]$p.check_interval_sec
                IsRunning        = [bool]$e.is_running
                DownSince        = $downSince
                DownDuration     = $downDur
                AlertCount       = [int]$e.alert_count
                LastCheck        = $lastCheck
                Actions          = @($p.actions.on_not_running | ForEach-Object { $_.type })
                InstructionsText = $instrText
                Source           = 'state'
            })
        } else {
            $exe     = $p.name -replace '(?i)\.exe$', ''
            $running = [bool]@(Get-Process -Name $exe -ErrorAction SilentlyContinue)
            $out.Add([pscustomobject]@{
                DisplayName      = $p.display_name
                Executable       = $p.name
                Required         = [bool]$p.required
                CheckSec         = [int]$p.check_interval_sec
                IsRunning        = $running
                DownSince        = $null
                DownDuration     = $null
                AlertCount       = 0
                LastCheck        = (Get-Date)
                Actions          = @($p.actions.on_not_running | ForEach-Object { $_.type })
                InstructionsText = $instrText
                Source           = 'live'
            })
        }
    }
    return $out
}

# ── Form ──────────────────────────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Process Monitoring Console'
$form.Size            = New-Object Drawing.Size(660, 600)
$form.MinimumSize     = New-Object Drawing.Size(480, 420)
$form.StartPosition   = 'CenterScreen'
$form.BackColor       = $BG
$form.ForeColor       = $COL_TEXT
$form.FormBorderStyle = 'Sizable'
$form.Font            = $FNT_NORM9

# ── Header ────────────────────────────────────────────────────────────────────
$pHeader = New-Object System.Windows.Forms.Panel
$pHeader.Dock      = 'Top'
$pHeader.Height    = 66
$pHeader.BackColor = $HEADER_BG

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = 'Process Monitoring Console'
$lblTitle.Location  = New-Object Drawing.Point(20, 12)
$lblTitle.AutoSize  = $true
$lblTitle.ForeColor = $COL_CYAN
$lblTitle.Font      = $FNT_TITLE

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text      = "Live status of monitored processes  |  v$($settings._meta.version)"
$lblSub.Location  = New-Object Drawing.Point(22, 46)
$lblSub.AutoSize  = $true
$lblSub.ForeColor = $COL_MUTED
$lblSub.Font      = $FNT_SMALL8

$pHeader.Controls.AddRange(@($lblTitle, $lblSub))
$form.Controls.Add($pHeader)

# ── Engine status section ─────────────────────────────────────────────────────
$pEngine = New-Object System.Windows.Forms.Panel
$pEngine.Dock      = 'Top'
$pEngine.Height    = 80
$pEngine.BackColor = $ENGINE_BG

# Top border line
$engLine = New-Object System.Windows.Forms.Panel
$engLine.Dock      = 'Top'
$engLine.Height    = 1
$engLine.BackColor = $DIVIDER
$pEngine.Controls.Add($engLine)

$lblEngSect = New-Object System.Windows.Forms.Label
$lblEngSect.Text      = 'MONITORING ENGINE'
$lblEngSect.Location  = New-Object Drawing.Point(20, 10)
$lblEngSect.AutoSize  = $true
$lblEngSect.ForeColor = $COL_MUTED
$lblEngSect.Font      = $FNT_SECT
$pEngine.Controls.Add($lblEngSect)

# Engine running status
$lblEngRun = New-Object System.Windows.Forms.Label
$lblEngRun.Location  = New-Object Drawing.Point(18, 28)
$lblEngRun.AutoSize  = $true
$lblEngRun.Font      = $FNT_ENG
$pEngine.Controls.Add($lblEngRun)

# Engine detail (state-file health)
$lblEngHealth = New-Object System.Windows.Forms.Label
$lblEngHealth.Location  = New-Object Drawing.Point(20, 54)
$lblEngHealth.AutoSize  = $true
$lblEngHealth.Font      = $FNT_SMALL8
$pEngine.Controls.Add($lblEngHealth)

$form.Controls.Add($pEngine)

# ── Footer ────────────────────────────────────────────────────────────────────
$pFooter = New-Object System.Windows.Forms.Panel
$pFooter.Dock      = 'Bottom'
$pFooter.Height    = 52
$pFooter.BackColor = $FOOTER_BG

$footLine = New-Object System.Windows.Forms.Panel
$footLine.Dock      = 'Top'
$footLine.Height    = 1
$footLine.BackColor = $DIVIDER
$pFooter.Controls.Add($footLine)

$lblRefresh = New-Object System.Windows.Forms.Label
$lblRefresh.Location  = New-Object Drawing.Point(20, 18)
$lblRefresh.AutoSize  = $true
$lblRefresh.ForeColor = $COL_MUTED
$lblRefresh.Font      = $FNT_SMALL8

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text      = "$([char]0x21BB)  Refresh"
$btnRefresh.Location  = New-Object Drawing.Point(228, 10)
$btnRefresh.Size      = New-Object Drawing.Size(122, 30)
$btnRefresh.BackColor = $CARD_BG
$btnRefresh.ForeColor = $COL_WHITE
$btnRefresh.FlatStyle = 'Flat'
$btnRefresh.FlatAppearance.BorderColor = $DIVIDER
$btnRefresh.Font      = $FNT_BOLD9
$btnRefresh.Cursor    = [System.Windows.Forms.Cursors]::Hand

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text      = "$([char]0x2715)  Close"
$btnClose.Size      = New-Object Drawing.Size(122, 30)
$btnClose.BackColor = $CARD_BG
$btnClose.ForeColor = $COL_WHITE
$btnClose.FlatStyle = 'Flat'
$btnClose.FlatAppearance.BorderColor = $DIVIDER
$btnClose.Font      = $FNT_BOLD9
$btnClose.Cursor    = [System.Windows.Forms.Cursors]::Hand
$btnClose.Anchor    = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

$pFooter.Controls.AddRange(@($lblRefresh, $btnRefresh, $btnClose))
$form.Controls.Add($pFooter)

# ── Scrollable cards area ─────────────────────────────────────────────────────
$pScroll = New-Object System.Windows.Forms.Panel
$pScroll.Dock       = 'Fill'
$pScroll.AutoScroll = $true
$pScroll.BackColor  = $BG
$form.Controls.Add($pScroll)

# Z-order (Top → Engine → Fill → Bottom)
$form.Controls.SetChildIndex($pHeader,  0)
$form.Controls.SetChildIndex($pEngine,  1)
$form.Controls.SetChildIndex($pScroll,  2)
$form.Controls.SetChildIndex($pFooter,  3)

# ── Instructions dialog ───────────────────────────────────────────────────────
function Show-InstructionsDialog ([string]$ProcessName, [string]$Text) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Instructions'
    $dlg.Size            = New-Object Drawing.Size(520, 370)
    $dlg.MinimumSize     = New-Object Drawing.Size(380, 280)
    $dlg.StartPosition   = 'CenterScreen'
    $dlg.BackColor       = $BG
    $dlg.ForeColor       = $COL_TEXT
    $dlg.FormBorderStyle = 'Sizable'
    $dlg.Font            = $FNT_NORM9

    # Header
    $ph = New-Object System.Windows.Forms.Panel
    $ph.Dock      = 'Top'
    $ph.Height    = 58
    $ph.BackColor = $HEADER_BG

    $lT = New-Object System.Windows.Forms.Label
    $lT.Text      = 'Instructions'
    $lT.Location  = New-Object Drawing.Point(18, 10)
    $lT.AutoSize  = $true
    $lT.ForeColor = $COL_CYAN
    $lT.Font      = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold)

    $lS = New-Object System.Windows.Forms.Label
    $lS.Text      = $ProcessName
    $lS.Location  = New-Object Drawing.Point(20, 36)
    $lS.AutoSize  = $true
    $lS.ForeColor = $COL_MUTED
    $lS.Font      = $FNT_SMALL8

    $ph.Controls.AddRange(@($lT, $lS))
    $dlg.Controls.Add($ph)

    # Footer
    $pf = New-Object System.Windows.Forms.Panel
    $pf.Dock      = 'Bottom'
    $pf.Height    = 50
    $pf.BackColor = $HEADER_BG

    $sep = New-Object System.Windows.Forms.Panel
    $sep.Dock = 'Top'; $sep.Height = 1; $sep.BackColor = $DIVIDER
    $pf.Controls.Add($sep)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text      = 'Close'
    $btnClose.Size      = New-Object Drawing.Size(90, 28)
    $btnClose.Anchor    = [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Top
    $btnClose.Location  = New-Object Drawing.Point(412, 10)
    $btnClose.BackColor = $CARD_BG
    $btnClose.ForeColor = $COL_WHITE
    $btnClose.FlatStyle = 'Flat'
    $btnClose.FlatAppearance.BorderColor = $DIVIDER
    $btnClose.Font      = $FNT_BOLD9
    $btnClose.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $btnClose.Add_Click({ $dlg.Close() })
    $pf.Controls.Add($btnClose)
    $dlg.Controls.Add($pf)

    # Instructions text (scrollable, read-only)
    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Dock        = 'Fill'
    $rtb.ReadOnly    = $true
    $rtb.BackColor   = $CARD_BG
    $rtb.ForeColor   = $COL_TEXT
    $rtb.BorderStyle = 'None'
    $rtb.Font        = New-Object Drawing.Font('Segoe UI', 10)
    $rtb.ScrollBars  = 'Vertical'
    $rtb.Padding     = New-Object System.Windows.Forms.Padding(18, 14, 18, 14)
    $rtb.Text        = $Text
    $dlg.Controls.Add($rtb)

    $dlg.Controls.SetChildIndex($ph,  0)
    $dlg.Controls.SetChildIndex($rtb, 1)
    $dlg.Controls.SetChildIndex($pf,  2)

    $dlg.ShowDialog() | Out-Null
    $dlg.Dispose()
}

# ── Card builder ──────────────────────────────────────────────────────────────
function New-ProcessCard ($data, [int]$w) {
    $running = $data.IsRunning
    $barClr  = if ($running) { $COL_GREEN2 } else { $COL_RED2 }
    $statTxt = if ($running) { "$([char]0x25CF) RUNNING" } else { "$([char]0x25CF) NOT RUNNING" }
    $statClr = if ($running) { $COL_GREEN  } else { $COL_RED  }

    $hasDown = (-not $running -and $null -ne $data.DownSince)
    $cardH   = if ($hasDown) { 134 } else { 108 }

    # Outer card panel
    $card = New-Object System.Windows.Forms.Panel
    $card.Width     = $w
    $card.Height    = $cardH
    $card.BackColor = $CARD_BG

    # Left colour accent bar (added first so it docks Left before Fill)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock      = 'Left'
    $bar.Width     = 6
    $bar.BackColor = $barClr
    $card.Controls.Add($bar)

    # Content area fills the rest
    $ip = New-Object System.Windows.Forms.Panel
    $ip.Dock      = 'Fill'
    $ip.BackColor = $CARD_BG
    $card.Controls.Add($ip)

    # Row 1: Status badge  (y=10)
    $lStat = New-Object System.Windows.Forms.Label
    $lStat.Text      = $statTxt
    $lStat.Location  = New-Object Drawing.Point(14, 10)
    $lStat.AutoSize  = $true
    $lStat.ForeColor = $statClr
    $lStat.Font      = $FNT_STATUS
    $ip.Controls.Add($lStat)

    # Row 2: Process display name  (y=30)
    $lName = New-Object System.Windows.Forms.Label
    $lName.Text      = $data.DisplayName
    $lName.Location  = New-Object Drawing.Point(14, 30)
    $lName.AutoSize  = $true
    $lName.ForeColor = $COL_WHITE
    $lName.Font      = $FNT_PROCNAME
    $ip.Controls.Add($lName)

    # Row 3: Executable · Type · Interval  (y=60)
    $req   = if ($data.Required) { 'Required' } else { 'Optional' }
    $meta  = "$($data.Executable)   $([char]0xB7)   $req   $([char]0xB7)   Check every $($data.CheckSec)s"
    $lMeta = New-Object System.Windows.Forms.Label
    $lMeta.Text      = $meta
    $lMeta.Location  = New-Object Drawing.Point(14, 60)
    $lMeta.AutoSize  = $true
    $lMeta.ForeColor = $COL_MUTED
    $lMeta.Font      = $FNT_SMALL8
    $ip.Controls.Add($lMeta)

    if ($running) {
        # Row 4: Last check time + data source  (y=80)
        $ck  = if ($data.LastCheck) { $data.LastCheck.ToString('HH:mm:ss') } else { '--' }
        $src = if ($data.Source -eq 'state') { 'via monitor' } else { 'live check' }
        $lChk = New-Object System.Windows.Forms.Label
        $lChk.Text      = "Last check: $ck  ($src)"
        $lChk.Location  = New-Object Drawing.Point(14, 80)
        $lChk.AutoSize  = $true
        $lChk.ForeColor = $COL_MUTED
        $lChk.Font      = $FNT_SMALL8
        $ip.Controls.Add($lChk)
    } else {
        # Row 4: Down-since  (y=80)
        $durStr = if ($data.DownDuration) { "  ($(Format-Dur $data.DownDuration))" } else { '' }
        $dwnStr = if ($data.DownSince) { "$($data.DownSince.ToString('HH:mm:ss'))$durStr" } else { 'Unknown' }
        $lDwn = New-Object System.Windows.Forms.Label
        $lDwn.Text      = "Down since: $dwnStr"
        $lDwn.Location  = New-Object Drawing.Point(14, 80)
        $lDwn.AutoSize  = $true
        $lDwn.ForeColor = $COL_ORANGE
        $lDwn.Font      = $FNT_SMALL8
        $ip.Controls.Add($lDwn)

        if ($hasDown) {
            # Row 5: Alert count + configured actions  (y=100)
            $actStr = ($data.Actions -join ', ')
            $lAct = New-Object System.Windows.Forms.Label
            $lAct.Text      = "Alerts sent: $($data.AlertCount)   $([char]0xB7)   On down: $actStr"
            $lAct.Location  = New-Object Drawing.Point(14, 100)
            $lAct.AutoSize  = $true
            $lAct.ForeColor = $COL_MUTED
            $lAct.Font      = $FNT_SMALL8
            $ip.Controls.Add($lAct)
        }
    }

    # "Click here for instructions" button — top-right, shown whenever instructions are set.
    if ($data.InstructionsText) {
        $instr = $data.InstructionsText   # captured for the click closure
        $dname = $data.DisplayName
        $btnI = New-Object System.Windows.Forms.Button
        $btnI.Text      = "Click here for instructions"
        $btnI.Size      = New-Object Drawing.Size(190, 24)
        $btnI.BackColor = [Drawing.Color]::FromArgb(32, 52, 90)
        $btnI.ForeColor = $COL_CYAN
        $btnI.FlatStyle = 'Flat'
        $btnI.FlatAppearance.BorderColor = $DIVIDER
        $btnI.Font      = $FNT_SMALL8
        $btnI.Cursor    = [System.Windows.Forms.Cursors]::Hand
        $btnI.Anchor    = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
        $btnI.Location  = New-Object Drawing.Point(400, 8)
        $btnI.Add_Click({
            Show-InstructionsDialog -ProcessName $dname -Text $instr
        })
        $ip.Controls.Add($btnI)
    }

    return $card
}

# ── Refresh helpers ───────────────────────────────────────────────────────────
function Refresh-Engine ($eng) {
    if ($eng.Running) {
        $pidTxt = if ($eng.MonPID) { "   PID $($eng.MonPID)" } else { '' }
        $lblEngRun.Text      = "  $([char]0x25CF) ACTIVE$pidTxt   --   process_monitor.ps1"
        $lblEngRun.ForeColor = $COL_GREEN

        if ($eng.StateAge) {
            $ageTxt  = Format-Age $eng.StateUpdated
            $maxSec  = ($settings.processes | Measure-Object -Property check_interval_sec -Maximum).Maximum
            $healthy = $eng.StateAge.TotalSeconds -lt ($maxSec * 2 + 15)
            if ($healthy) {
                $lblEngHealth.Text      = "State file updated $ageTxt   --   Checks are current"
                $lblEngHealth.ForeColor = $COL_GREEN
            } else {
                $lblEngHealth.Text      = "State file updated $ageTxt   --   Monitor may have stalled"
                $lblEngHealth.ForeColor = $COL_ORANGE
            }
        } else {
            $lblEngHealth.Text      = "Waiting for first check cycle to complete..."
            $lblEngHealth.ForeColor = $COL_YELLOW
        }
    } else {
        $lblEngRun.Text      = "  $([char]0x25CB) NOT ACTIVE   --   process_monitor.ps1 is not running"
        $lblEngRun.ForeColor = $COL_YELLOW
        $lblEngHealth.Text      = "Launch start_monitoring.bat to start the monitoring engine"
        $lblEngHealth.ForeColor = $COL_MUTED
    }
}

function Refresh-Cards ($rows) {
    $pScroll.SuspendLayout()
    $pScroll.Controls.Clear()

    $cw = $pScroll.ClientSize.Width - 32
    if ($cw -lt 200) { $cw = 200 }

    # Section header
    $lSect = New-Object System.Windows.Forms.Label
    $lSect.Text      = "MONITORED PROCESSES  ($($rows.Count) configured)"
    $lSect.Location  = New-Object Drawing.Point(4, 10)
    $lSect.AutoSize  = $true
    $lSect.ForeColor = $COL_MUTED
    $lSect.Font      = $FNT_SECT
    $pScroll.Controls.Add($lSect)

    if ($rows.Count -eq 0) {
        $lEmpty = New-Object System.Windows.Forms.Label
        $lEmpty.Text      = "No processes are configured in monitoring_settings.json."
        $lEmpty.Location  = New-Object Drawing.Point(4, 36)
        $lEmpty.AutoSize  = $true
        $lEmpty.ForeColor = $COL_MUTED
        $lEmpty.Font      = $FNT_NORM9
        $pScroll.Controls.Add($lEmpty)
    } else {
        $y = 30
        foreach ($row in $rows) {
            $card = New-ProcessCard $row $cw
            $card.Location = New-Object Drawing.Point(0, $y)
            $pScroll.Controls.Add($card)
            $y += $card.Height + 10
        }
    }

    $pScroll.ResumeLayout($true)
}

function Do-Refresh {
    $script:settings = (Get-Content $SettingsFile -Raw -Encoding UTF8) | ConvertFrom-Json
    $eng  = Get-EngineInfo
    $rows = Get-ProcessRows
    Refresh-Engine $eng
    Refresh-Cards  $rows
    $lblRefresh.Text = "Last refresh: $(Get-Date -Format 'HH:mm:ss')"
}

# ── Close-button right-align on resize ────────────────────────────────────────
function Align-CloseButton {
    $btnClose.Location = New-Object Drawing.Point(
        ($pFooter.ClientSize.Width - $btnClose.Width - 18), 10)
}

# ── Events ────────────────────────────────────────────────────────────────────
$form.Add_Shown({
    Align-CloseButton
    try { Do-Refresh }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Error loading data:`n$_", 'Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$form.Add_Resize({
    Align-CloseButton
    # Resize process cards to match the new scroll-panel width
    $cw = $pScroll.ClientSize.Width - 32
    if ($cw -lt 200) { $cw = 200 }
    foreach ($ctrl in $pScroll.Controls) {
        if ($ctrl -is [System.Windows.Forms.Panel] -and $ctrl.Height -gt 30) {
            $ctrl.Width = $cw
        }
    }
})

$btnRefresh.Add_Click({
    $btnRefresh.Enabled = $false
    $btnRefresh.Text    = 'Refreshing...'
    try { Do-Refresh } catch {}
    $btnRefresh.Text    = "$([char]0x21BB)  Refresh"
    $btnRefresh.Enabled = $true
})

$btnClose.Add_Click({ $form.Close() })

# Auto-refresh every 12 seconds
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 12000
$timer.Add_Tick({ try { Do-Refresh } catch {} })
$timer.Start()

$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })

[System.Windows.Forms.Application]::Run($form)
