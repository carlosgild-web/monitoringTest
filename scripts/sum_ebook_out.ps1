$xlsxPath = Join-Path (Split-Path $PSScriptRoot -Parent) "docs_Monitorig\PowerBIData.xlsx"

if (-not (Test-Path $xlsxPath)) {
    Write-Error "File not found: $xlsxPath"
    exit 1
}

$excel    = $null
$workbook = $null

try {
    $excel                    = New-Object -ComObject Excel.Application
    $excel.Visible            = $false
    $excel.DisplayAlerts      = $false
    $workbook                 = $excel.Workbooks.Open($xlsxPath, $null, $true)

    $sheet = $null
    foreach ($ws in $workbook.Sheets) {
        if ($ws.Name -eq "Actual") { $sheet = $ws; break }
    }
    if ($null -eq $sheet) {
        Write-Error "Sheet 'Actual' not found in workbook."
        exit 1
    }

    $lastRow = $sheet.UsedRange.Rows.Count
    $lastCol = $sheet.UsedRange.Columns.Count

    $subtypeCol = $null
    $outCol     = $null
    for ($c = 1; $c -le $lastCol; $c++) {
        $header = $sheet.Cells.Item(1, $c).Value2
        if ($header -eq "Subtype") { $subtypeCol = $c }
        if ($header -eq "Out")     { $outCol     = $c }
    }

    if ($null -eq $subtypeCol) { Write-Error "Column 'Subtype' not found."; exit 1 }
    if ($null -eq $outCol)     { Write-Error "Column 'Out' not found.";     exit 1 }

    $total = 0.0
    for ($r = 2; $r -le $lastRow; $r++) {
        $subtype = $sheet.Cells.Item($r, $subtypeCol).Value2
        if ($subtype -eq "Ebook") {
            $val = $sheet.Cells.Item($r, $outCol).Value2
            if ($null -ne $val) {
                $total += [double]$val
            }
        }
    }

    Write-Host ('Total "Out" for Subtype = "Ebook": ' + $total)
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
