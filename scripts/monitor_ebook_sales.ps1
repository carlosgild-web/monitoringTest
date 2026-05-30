$ErrorActionPreference = 'Continue'

$ProjectRoot  = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$SettingsFile = Join-Path $ProjectRoot "monitoring_settings.json"
$XlsxFile     = Join-Path $ProjectRoot "docs_Monitorig\PowerBIData.xlsx"
$StateFile    = Join-Path $ProjectRoot "logs\ebook_state.json"

function Get-EbookTotal {
    $excel    = $null
    $workbook = $null
    try {
        $excel               = New-Object -ComObject Excel.Application
        $excel.Visible       = $false
        $excel.DisplayAlerts = $false
        $workbook            = $excel.Workbooks.Open($XlsxFile, $null, $true)

        $sheet = $null
        foreach ($ws in $workbook.Sheets) {
            if ($ws.Name -eq "Actual") { $sheet = $ws; break }
        }
        if ($null -eq $sheet) { return $null }

        $lastRow    = $sheet.UsedRange.Rows.Count
        $lastCol    = $sheet.UsedRange.Columns.Count
        $subtypeCol = $null
        $outCol     = $null

        for ($c = 1; $c -le $lastCol; $c++) {
            $header = $sheet.Cells.Item(1, $c).Value2
            if ($header -eq "Subtype") { $subtypeCol = $c }
            if ($header -eq "Out")     { $outCol     = $c }
        }
        if ($null -eq $subtypeCol -or $null -eq $outCol) { return $null }

        $total = 0.0
        for ($r = 2; $r -le $lastRow; $r++) {
            $subtype = $sheet.Cells.Item($r, $subtypeCol).Value2
            if ($subtype -eq "Ebook") {
                $val = $sheet.Cells.Item($r, $outCol).Value2
                if ($null -ne $val) { $total += [double]$val }
            }
        }
        return [math]::Round($total, 2)
    }
    finally {
        if ($null -ne $workbook) {
            $workbook.Close($false)
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook)
        }
        if ($null -ne $excel) {
            $excel.Quit()
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}

while ($true) {
    try {
        $cfg         = (Get-Content $SettingsFile -Raw -Encoding UTF8) | ConvertFrom-Json
        $ebookCfg    = $cfg.ebook_sales
        $targetUsd   = if ($null -ne $ebookCfg -and $null -ne $ebookCfg.target_usd)        { [double]$ebookCfg.target_usd }        else { 300.0 }
        $checkSec    = if ($null -ne $ebookCfg -and $null -ne $ebookCfg.check_interval_sec) { [int]$ebookCfg.check_interval_sec }    else { 60 }
        $displayName = if ($null -ne $ebookCfg -and $null -ne $ebookCfg.display_name)       { [string]$ebookCfg.display_name }       else { "Total Ebook Sales" }

        $total = Get-EbookTotal
        $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        if ($null -ne $total) {
            $state = [ordered]@{
                updated      = $ts
                display_name = $displayName
                total_sales  = $total
                target_usd   = $targetUsd
            }
        } else {
            $state = [ordered]@{
                updated      = $ts
                display_name = $displayName
                total_sales  = 0.0
                target_usd   = $targetUsd
                error        = "Could not read xlsx data"
            }
        }

        $logsDir = Join-Path $ProjectRoot "logs"
        if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
        $state | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding UTF8
    }
    catch {
        # Silent — keep the loop alive
    }

    Start-Sleep -Seconds $checkSec
}
