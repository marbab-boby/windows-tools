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
#  Remove Duplicates
#  Put this .bat in a folder and double-click it. It finds files that are
#  exact copies of each other (same content, even if the names differ),
#  keeps one of each and moves the extra copies into a "_Duplicates" folder.
#  Nothing is deleted - you can check the _Duplicates folder and delete it.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$folder = $env:TARGET.TrimEnd('\')
# Use the full folder name (not the short C:\ABCDEF~1 form) so paths match
Add-Type -Namespace Win32 -Name Path -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern uint GetLongPathName(string s, System.Text.StringBuilder b, uint n);'
$sb = New-Object Text.StringBuilder 2048
if ([Win32.Path]::GetLongPathName($folder, $sb, 2048)) { $folder = $sb.ToString().TrimEnd('\') }
$dupDir = Join-Path $folder '_Duplicates'
$imageExt = '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.heic', '.svg'
$videoExt = '.mp4', '.m4v', '.mov', '.avi', '.mkv', '.wmv', '.mpg', '.mpeg', '.webm', '.3gp', '.flv'

function Ask([string]$prompt, [string[]]$valid) {
    do { $a = "$(Read-Host $prompt)".Trim() } until ($a -in $valid)
    return $a
}
function Size([double]$b) { if ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f ($b / 1KB) } }

Write-Host ''
Write-Host '  ===== Remove duplicate files =====' -ForegroundColor Cyan
Write-Host "  Folder: $folder"
Write-Host ''
Write-Host '  What should be checked?'
Write-Host '    1 = Images'
Write-Host '    2 = Videos'
Write-Host '    3 = Images and videos'
Write-Host '    4 = All files'
$what = Ask '  Enter 1-4' '1', '2', '3', '4'
Write-Host ''
$sub = (Ask '  Also look inside subfolders? (Y/N)' 'y', 'n') -eq 'y'

$exts = switch ($what) { '1' { $imageExt } '2' { $videoExt } '3' { $imageExt + $videoExt } '4' { $null } }
$files = @(Get-ChildItem -LiteralPath $folder -File -Recurse:$sub | Where-Object {
    $_.FullName -notlike "$dupDir\*" -and $_.Name -ne $env:SELF -and $_.Name -ne 'duplicates_report.csv' -and
    (-not $exts -or $_.Extension -in $exts)
})
Write-Host ''
Write-Host "  Checking $($files.Count) file(s) ..."

# Only files with the same size can be identical, so hash just those
$candidates = @($files | Group-Object Length | Where-Object { $_.Count -gt 1 -and $_.Name -ne '0' } | ForEach-Object { $_.Group })
$i = 0
$hashed = foreach ($f in $candidates) {
    $i++
    Write-Host "`r  Comparing $i of $($candidates.Count) ..." -NoNewline
    try { [pscustomobject]@{ File = $f; Hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } } catch {}
}
Write-Host ''

# In each set keep the file with the shortest path / name (usually the original), then the oldest
$sets = @($hashed | Group-Object Hash | Where-Object Count -gt 1 | ForEach-Object {
    $sorted = @($_.Group.File | Sort-Object @{ e = { ($_.FullName -split '\\').Count } }, @{ e = { $_.Name.Length } }, LastWriteTime, FullName)
    [pscustomobject]@{ Keep = $sorted[0]; Extra = @($sorted | Select-Object -Skip 1) }
})

if (-not $sets) {
    Write-Host ''
    Write-Host '  No duplicates found.' -ForegroundColor Green
    return
}

$extra = @($sets | ForEach-Object { $_.Extra })
$bytes = ($extra | Measure-Object Length -Sum).Sum
Write-Host ''
Write-Host "  Found $($sets.Count) file(s) that have copies - $($extra.Count) extra copies using $(Size $bytes)." -ForegroundColor Yellow
Write-Host ''
$shown = 0
foreach ($s in $sets) {
    if ($shown -ge 15) { Write-Host "    ... and $($sets.Count - 15) more"; break }
    Write-Host "    KEEP  $($s.Keep.FullName.Substring($folder.Length + 1))" -ForegroundColor Green
    foreach ($x in $s.Extra) { Write-Host "    copy  $($x.FullName.Substring($folder.Length + 1))" -ForegroundColor DarkGray }
    $shown++
}

Write-Host ''
Write-Host '  What now?'
Write-Host '    1 = Move the extra copies to the "_Duplicates" folder (recommended)'
Write-Host '    2 = Only make a report (duplicates_report.csv), change nothing'
Write-Host '    3 = Cancel'
$act = Ask '  Enter 1, 2 or 3' '1', '2', '3'
if ($act -eq '3') { Write-Host '  Cancelled. Nothing was changed.'; return }

$report = New-Object System.Collections.Generic.List[object]
$moved = 0
foreach ($s in $sets) {
    foreach ($x in $s.Extra) {
        $movedTo = ''
        if ($act -eq '1') {
            $rel = $x.FullName.Substring($folder.Length + 1)
            $dest = Join-Path $dupDir $rel
            $destFolder = Split-Path $dest
            if (-not (Test-Path -LiteralPath $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }
            $n = 2
            while (Test-Path -LiteralPath $dest) {
                $dest = Join-Path $destFolder ("{0} ({1}){2}" -f [IO.Path]::GetFileNameWithoutExtension($x.Name), $n, $x.Extension); $n++
            }
            try { Move-Item -LiteralPath $x.FullName -Destination $dest; $movedTo = $dest; $moved++ }
            catch { Write-Host "  [!] Could not move $($x.Name) (is it open?)" -ForegroundColor Red; $movedTo = 'NOT MOVED' }
        }
        $report.Add([pscustomobject]@{ Kept = $s.Keep.FullName; Duplicate = $x.FullName; MovedTo = $movedTo; SizeKB = [math]::Round($x.Length / 1KB) })
    }
}

$reportPath = if ($act -eq '1') { Join-Path $dupDir 'duplicates_report.csv' } else { Join-Path $folder 'duplicates_report.csv' }
$report | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8

Write-Host ''
if ($act -eq '1') {
    Write-Host "  Done. Moved $moved extra copies ($(Size $bytes)) to the _Duplicates folder." -ForegroundColor Cyan
    Write-Host '  Check it, then delete the _Duplicates folder to free the space.'
} else {
    Write-Host "  Done. Report saved: duplicates_report.csv" -ForegroundColor Cyan
}
