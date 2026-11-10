<# : batch launcher - do not edit these lines
@echo off
setlocal
set "TARGET=%~dp0"
set "SELF=%~nx0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText('%~f0'))"
echo.
pause
exit /b
#>

# ---------------------------------------------------------------------------
#  Folder Report
#  Put this .bat in a folder and double-click it. It lists every file in the
#  folder and all its subfolders in an Excel report: sizes, types, dates,
#  biggest files and biggest folders. Needs Microsoft Excel (otherwise it
#  saves CSV files instead).
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$folder = $env:TARGET.TrimEnd('\')
# Use the full folder name (not the short C:\ABCDEF~1 form) so paths match
Add-Type -Namespace Win32 -Name Path -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern uint GetLongPathName(string s, System.Text.StringBuilder b, uint n);'
$sb = New-Object Text.StringBuilder 2048
if ([Win32.Path]::GetLongPathName($folder, $sb, 2048)) { $folder = $sb.ToString().TrimEnd('\') }

$categories = [ordered]@{
    'Images'     = '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.heic', '.svg', '.ico', '.raw', '.cr2', '.nef'
    'Videos'     = '.mp4', '.m4v', '.mov', '.avi', '.mkv', '.wmv', '.mpg', '.mpeg', '.webm', '.3gp', '.flv', '.ts'
    'Audio'      = '.mp3', '.m4a', '.wav', '.aac', '.wma', '.ogg', '.flac', '.opus'
    'PowerPoint' = '.pptx', '.ppt', '.pptm', '.ppsx', '.pps', '.potx'
    'PDF'        = '.pdf'
    'Word'       = '.docx', '.doc', '.docm', '.rtf', '.odt'
    'Excel'      = '.xlsx', '.xls', '.xlsm', '.xlsb', '.csv', '.ods'
    'Maps / GIS' = '.shp', '.shx', '.dbf', '.prj', '.kml', '.kmz', '.geojson', '.gpkg', '.mxd', '.aprx', '.qgz', '.qgs'
    'Archives'   = '.zip', '.rar', '.7z', '.tar', '.gz', '.iso'
    'Programs'   = '.exe', '.msi', '.bat', '.cmd', '.ps1', '.dll'
    'Text / Web' = '.txt', '.md', '.html', '.htm', '.json', '.xml', '.js', '.css', '.py', '.log'
}
$typeOf = @{}
foreach ($k in $categories.Keys) { foreach ($e in $categories[$k]) { if (-not $typeOf.ContainsKey($e)) { $typeOf[$e] = $k } } }

function TypeOf($f) { $t = $typeOf[$f.Extension.ToLower()]; if ($t) { $t } else { 'Other' } }
function Size([double]$b) { if ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f ($b / 1KB) } }
function Rel([string]$p) { if ($p.Length -le $folder.Length) { '(this folder)' } else { $p.Substring($folder.Length + 1) } }
function Txt([string]$s) { if ($s -match '^[=+\-@]') { "'" + $s } else { $s } }   # stop Excel reading names as formulas

Write-Host ''
Write-Host '  ===== Folder report =====' -ForegroundColor Cyan
Write-Host "  Folder: $folder"
Write-Host ''
Write-Host '  Scanning files ...'

$stamp = Get-Date
$files = @(Get-ChildItem -LiteralPath $folder -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -ne $env:SELF -and $_.Name -notlike 'Folder Report - *' -and $_.Name -notlike '~$*'
})
$dirs = @(Get-ChildItem -LiteralPath $folder -Directory -Recurse -ErrorAction SilentlyContinue)
$total = ($files | Measure-Object Length -Sum).Sum
if (-not $total) { $total = 0 }
Write-Host "  $($files.Count) file(s) in $($dirs.Count) folder(s), $(Size $total) in total."

# ----------------------------- totals -------------------------------------
$byType = @{}
foreach ($f in $files) {
    $t = TypeOf $f
    if (-not $byType.ContainsKey($t)) { $byType[$t] = @{ Count = 0; Bytes = 0L } }
    $byType[$t].Count++; $byType[$t].Bytes += $f.Length
}

# Size of every folder including its subfolders
$dirTotals = @{}
foreach ($d in $dirs) { $dirTotals[$d.FullName] = @{ Count = 0; Bytes = 0L; Modified = $d.LastWriteTime } }
foreach ($f in $files) {
    $p = $f.DirectoryName
    while ($p.Length -gt $folder.Length) {
        if ($dirTotals.ContainsKey($p)) { $dirTotals[$p].Count++; $dirTotals[$p].Bytes += $f.Length }
        $p = Split-Path $p -Parent
    }
}
$topDirs = @($dirs | Where-Object { $_.Parent.FullName.TrimEnd('\') -eq $folder } | Sort-Object { $dirTotals[$_.FullName].Bytes } -Descending)
$looseFiles = @($files | Where-Object { $_.DirectoryName.TrimEnd('\') -eq $folder })

$typeRows = @($byType.GetEnumerator() | Sort-Object { $_.Value.Bytes } -Descending)
Write-Host ''
Write-Host '  By type:'
foreach ($t in $typeRows) { Write-Host ('    {0,-12} {1,7} file(s)   {2,10}' -f $t.Key, $t.Value.Count, (Size $t.Value.Bytes)) }
if ($topDirs) {
    Write-Host ''
    Write-Host '  Biggest folders:'
    foreach ($d in ($topDirs | Select-Object -First 5)) { Write-Host ('    {0,-40} {1,10}' -f $d.Name, (Size $dirTotals[$d.FullName].Bytes)) }
}

# ----------------------------- rows for the sheets ------------------------
$fileHeader = 'File name', 'Type', 'Extension', 'Size (MB)', 'Date modified', 'Date created', 'Folder', 'Open'
function FileRow($f) {
    $link = if ($f.FullName.Length -lt 250) { '=HYPERLINK("' + $f.FullName + '","Open")' } else { '' }
    , @((Txt $f.Name), (TypeOf $f), $f.Extension.ToLower(), [math]::Round($f.Length / 1MB, 3),
        $f.LastWriteTime.ToOADate(), $f.CreationTime.ToOADate(), (Txt (Rel $f.DirectoryName)), $link)
}
Write-Host ''
Write-Host '  Building report ...'
$allRows = New-Object System.Collections.Generic.List[object]
foreach ($f in ($files | Sort-Object DirectoryName, Name)) { $allRows.Add((FileRow $f)) }
$bigRows = New-Object System.Collections.Generic.List[object]
foreach ($f in ($files | Sort-Object Length -Descending | Select-Object -First 100)) { $bigRows.Add((FileRow $f)) }
$dirRows = New-Object System.Collections.Generic.List[object]
foreach ($d in ($dirs | Sort-Object { $dirTotals[$_.FullName].Bytes } -Descending)) {
    $t = $dirTotals[$d.FullName]
    $dirRows.Add(@((Txt (Rel $d.FullName)), $t.Count, [math]::Round($t.Bytes / 1MB, 2), $t.Modified.ToOADate()))
}

$baseName = 'Folder Report - ' + $stamp.ToString('yyyy-MM-dd HHmm')

# ----------------------------- Excel --------------------------------------
$xl = $null
try { $xl = New-Object -ComObject Excel.Application } catch {}
# Never close an Excel that already has the user's workbooks open
$ownExcel = $xl -and $xl.Workbooks.Count -eq 0

if (-not $xl) {
    Write-Host '  Excel is not available - saving CSV files instead.' -ForegroundColor Yellow
    $files | Sort-Object DirectoryName, Name | Select-Object @{ n = 'File name'; e = { $_.Name } }, @{ n = 'Type'; e = { TypeOf $_ } },
        @{ n = 'Extension'; e = { $_.Extension.ToLower() } }, @{ n = 'Size (MB)'; e = { [math]::Round($_.Length / 1MB, 3) } },
        @{ n = 'Date modified'; e = { $_.LastWriteTime } }, @{ n = 'Folder'; e = { Rel $_.DirectoryName } }, @{ n = 'Full path'; e = { $_.FullName } } |
        Export-Csv -LiteralPath (Join-Path $folder "$baseName - Files.csv") -NoTypeInformation -Encoding UTF8
    $dirs | Sort-Object { $dirTotals[$_.FullName].Bytes } -Descending | Select-Object @{ n = 'Folder'; e = { Rel $_.FullName } },
        @{ n = 'Files'; e = { $dirTotals[$_.FullName].Count } }, @{ n = 'Size (MB)'; e = { [math]::Round($dirTotals[$_.FullName].Bytes / 1MB, 2) } } |
        Export-Csv -LiteralPath (Join-Path $folder "$baseName - Folders.csv") -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Host "  Done. Saved $baseName - Files.csv and - Folders.csv" -ForegroundColor Cyan
    return
}

# Write a block of rows to a sheet in one go (fast), with a bold coloured header
function Put-Table($ws, [int]$row, [int]$col, [string[]]$header, $rows) {
    $n = $rows.Count   # (not @($rows) - that fails on a list of arrays in PowerShell 5.1)
    $arr = New-Object 'object[,]' ($n + 1), $header.Count
    for ($c = 0; $c -lt $header.Count; $c++) { $arr[0, $c] = $header[$c] }
    $r = 1
    # .BaseObject strips PowerShell's wrapper - Excel rejects wrapped values
    foreach ($line in $rows) { for ($c = 0; $c -lt $header.Count; $c++) { $v = $line[$c]; if ($null -ne $v) { $arr[$r, $c] = $v.psobject.BaseObject } }; $r++ }
    $rng = $ws.Range($ws.Cells.Item($row, $col), $ws.Cells.Item($row + $n, $col + $header.Count - 1))
    $rng.Value2 = $arr
    $h = $ws.Range($ws.Cells.Item($row, $col), $ws.Cells.Item($row, $col + $header.Count - 1))
    $h.Font.Bold = $true; $h.Font.Color = 0xFFFFFF; $h.Interior.Color = 0x6B3A1F   # dark blue (BGR)
    return $row + $n + 1
}
function Fmt($ws, [int]$col, [int]$from, [int]$to, [string]$format) {
    if ($to -ge $from) { $ws.Range($ws.Cells.Item($from, $col), $ws.Cells.Item($to, $col)).NumberFormat = $format }
}
function Finish-List($ws, [int]$rows, [int]$cols) {
    $ws.Activate()
    $ws.Range($ws.Cells.Item(1, 1), $ws.Cells.Item([math]::Max(2, $rows + 1), $cols)).AutoFilter() | Out-Null
    try { $xl.ActiveWindow.SplitRow = 1; $xl.ActiveWindow.FreezePanes = $true } catch {}
    $ws.UsedRange.Columns.AutoFit() | Out-Null
    for ($c = 1; $c -le $cols; $c++) { if ($ws.Columns.Item($c).ColumnWidth -gt 60) { $ws.Columns.Item($c).ColumnWidth = 60 } }
}

$out = Join-Path $folder "$baseName.xlsx"
try {
    $xl.Visible = $false; $xl.DisplayAlerts = $false; $xl.ScreenUpdating = $false
    $wb = $xl.Workbooks.Add()
    while ($wb.Worksheets.Count -lt 4) { [void]$wb.Worksheets.Add([Type]::Missing, $wb.Worksheets.Item($wb.Worksheets.Count)) }
    $sum = $wb.Worksheets.Item(1); $sum.Name = 'Summary'
    $wsAll = $wb.Worksheets.Item(2); $wsAll.Name = 'All files'
    $wsBig = $wb.Worksheets.Item(3); $wsBig.Name = 'Largest files'
    $wsDir = $wb.Worksheets.Item(4); $wsDir.Name = 'Folders'

    # --- Summary
    # (cells are written as one block - setting text and numbers cell by cell trips a PowerShell/Excel bug)
    $head = New-Object 'object[,]' 9, 2
    $head[0, 0] = 'Folder report'
    $head[1, 0] = $folder
    $head[2, 0] = 'Made on ' + $stamp.ToString('dd MMM yyyy, HH:mm')
    $head[4, 0] = 'Files';      $head[4, 1] = [int]$files.Count
    $head[5, 0] = 'Folders';    $head[5, 1] = [int]$dirs.Count
    $head[6, 0] = 'Total size'; $head[6, 1] = [string](Size $total)
    $head[8, 0] = 'By type'
    $sum.Range('A1:B9').Value2 = $head
    $sum.Range('A1').Font.Size = 16; $sum.Range('A1').Font.Bold = $true
    $sum.Range('A5:A7').Font.Bold = $true; $sum.Range('A9').Font.Bold = $true
    $sum.Range('B5:B7').HorizontalAlignment = -4131   # left
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($t in $typeRows) { $rows.Add(@($t.Key, $t.Value.Count, [math]::Round($t.Value.Bytes / 1MB, 2), $(if ($total) { $t.Value.Bytes / $total } else { 0 }))) }
    $end = Put-Table $sum 10 1 @('Type', 'Files', 'Size (MB)', '% of space') $rows
    Fmt $sum 3 11 ($end - 1) '#,##0.00'; Fmt $sum 4 11 ($end - 1) '0.0%'

    $r = $end + 1
    $title = New-Object 'object[,]' 1, 1; $title[0, 0] = 'Folders (top level)'
    $sum.Range("A$r").Value2 = $title; $sum.Range("A$r").Font.Bold = $true
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($d in $topDirs) { $t = $dirTotals[$d.FullName]; $rows.Add(@((Txt $d.Name), $t.Count, [math]::Round($t.Bytes / 1MB, 2), $(if ($total) { $t.Bytes / $total } else { 0 }))) }
    if ($looseFiles) {
        $lb = ($looseFiles | Measure-Object Length -Sum).Sum
        $rows.Add(@('(files directly in this folder)', $looseFiles.Count, [math]::Round($lb / 1MB, 2), $(if ($total) { $lb / $total } else { 0 })))
    }
    if ($rows.Count) {
        $end = Put-Table $sum ($r + 1) 1 @('Folder', 'Files', 'Size (MB)', '% of space') $rows
        Fmt $sum 3 ($r + 2) ($end - 1) '#,##0.00'; Fmt $sum 4 ($r + 2) ($end - 1) '0.0%'
    }
    $sum.Columns.Item(1).ColumnWidth = 45; $sum.Columns.Item(2).ColumnWidth = 12
    $sum.Columns.Item(3).ColumnWidth = 14; $sum.Columns.Item(4).ColumnWidth = 12

    # --- All files / Largest files
    foreach ($pair in @(@($wsAll, $allRows), @($wsBig, $bigRows))) {
        $ws = $pair[0]; $data = $pair[1]
        [void](Put-Table $ws 1 1 $fileHeader $data)
        Fmt $ws 4 2 ($data.Count + 1) '#,##0.000'
        Fmt $ws 5 2 ($data.Count + 1) 'yyyy-mm-dd hh:mm'
        Fmt $ws 6 2 ($data.Count + 1) 'yyyy-mm-dd hh:mm'
        Finish-List $ws $data.Count $fileHeader.Count
        $ws.Columns.Item(8).Font.Color = 0xC07000
    }

    # --- Folders
    [void](Put-Table $wsDir 1 1 @('Folder (with everything inside it)', 'Files', 'Size (MB)', 'Date modified') $dirRows)
    Fmt $wsDir 3 2 ($dirRows.Count + 1) '#,##0.00'
    Fmt $wsDir 4 2 ($dirRows.Count + 1) 'yyyy-mm-dd hh:mm'
    Finish-List $wsDir $dirRows.Count 4

    $sum.Activate()
    $xl.ScreenUpdating = $true
    $wb.SaveAs($out, 51)
    $wb.Close($false)
}
finally {
    if ($ownExcel) { $xl.Quit() }
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($xl)
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}

Write-Host ''
Write-Host "  Done. Saved: $baseName.xlsx" -ForegroundColor Cyan
Write-Host ''
if ((Read-Host '  Open the report now? (Y/N)').Trim() -eq 'y') { Invoke-Item -LiteralPath $out }
