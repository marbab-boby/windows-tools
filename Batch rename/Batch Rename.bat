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
#  Batch Rename
#  Put this .bat in a folder and double-click it. Renames files or folders
#  in that folder. Shows a preview first, and the last rename can be undone
#  (option 8) using the _rename_log.csv file it saves.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$folder = $env:TARGET.TrimEnd('\')
# Use the full folder name (not the short C:\ABCDEF~1 form) so paths match
Add-Type -Namespace Win32 -Name Path -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern uint GetLongPathName(string s, System.Text.StringBuilder b, uint n);'
$sb = New-Object Text.StringBuilder 2048
if ([Win32.Path]::GetLongPathName($folder, $sb, 2048)) { $folder = $sb.ToString().TrimEnd('\') }
$logPath = Join-Path $folder '_rename_log.csv'
$skipNames = @($env:SELF, '_rename_log.csv', '_rename_log_undone.csv')

$types = [ordered]@{
    '1' = @{ Label = 'All files';                     Ext = $null }
    '2' = @{ Label = 'Images';                        Ext = '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.heic', '.svg' }
    '3' = @{ Label = 'Videos';                        Ext = '.mp4', '.m4v', '.mov', '.avi', '.mkv', '.wmv', '.mpg', '.mpeg', '.webm', '.3gp', '.flv' }
    '4' = @{ Label = 'PowerPoint';                    Ext = '.pptx', '.ppt', '.pptm', '.ppsx', '.pps', '.potx' }
    '5' = @{ Label = 'PDF';                           Ext = '.pdf' }
    '6' = @{ Label = 'Word / Excel';                  Ext = '.docx', '.doc', '.xlsx', '.xls', '.xlsm', '.csv' }
    '7' = @{ Label = 'Folders';                       Ext = $null }
}

function Ask([string]$prompt, [string[]]$valid) {
    do { $a = "$(Read-Host $prompt)".Trim() } until ($a -in $valid)
    return $a
}
function Clean([string]$s) { ($s -replace '[\\/:*?"<>|]', '').Trim() }
function NaturalKey([string]$s) { [regex]::Replace($s, '\d+', { $args[0].Value.PadLeft(12, '0') }) }
function Depth([string]$p) { ($p -split '\\').Count }

# Rename a group of items in one folder in two steps (old -> temp -> new),
# so names that swap or overlap never clash.
function Rename-Group([string]$parent, $pairs) {
    $done = New-Object System.Collections.Generic.List[object]
    $temp = @()
    foreach ($p in $pairs) {
        $t = '~rn_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        try { Rename-Item -LiteralPath (Join-Path $parent $p.From) -NewName $t; $temp += @{ P = $p; T = $t } }
        catch { Write-Host "  [!] Could not rename $($p.From) (is it open?)" -ForegroundColor Red }
    }
    foreach ($x in $temp) {
        try { Rename-Item -LiteralPath (Join-Path $parent $x.T) -NewName $x.P.To; $done.Add($x.P) }
        catch {
            Rename-Item -LiteralPath (Join-Path $parent $x.T) -NewName $x.P.From
            Write-Host "  [!] Could not rename $($x.P.From)" -ForegroundColor Red
        }
    }
    return $done
}

Write-Host ''
Write-Host '  ===== Batch rename =====' -ForegroundColor Cyan
Write-Host "  Folder: $folder"
Write-Host ''
Write-Host '  What do you want to rename?'
foreach ($k in $types.Keys) { Write-Host "    $k = $($types[$k].Label)" }
Write-Host '    8 = UNDO the last rename'
$what = Ask '  Enter 1-8' '1', '2', '3', '4', '5', '6', '7', '8'

# ----------------------------- undo ---------------------------------------
if ($what -eq '8') {
    if (-not (Test-Path -LiteralPath $logPath)) { Write-Host '  Nothing to undo (no _rename_log.csv in this folder).' -ForegroundColor Yellow; return }
    $rows = @(Import-Csv -LiteralPath $logPath)
    Write-Host "  This will put back $($rows.Count) original name(s)."
    if ((Ask '  Continue? (Y/N)' 'y', 'n') -ne 'y') { Write-Host '  Cancelled.'; return }
    $count = 0
    foreach ($g in ($rows | Group-Object { [int]$_.Group } | Sort-Object { [int]$_.Name } -Descending)) {
        $parent = $g.Group[0].Parent
        $pairs = @($g.Group | ForEach-Object { [pscustomobject]@{ From = $_.NewName; To = $_.OldName } })
        $count += @(Rename-Group $parent $pairs).Count
    }
    Move-Item -LiteralPath $logPath -Destination (Join-Path $folder '_rename_log_undone.csv') -Force
    Write-Host ''
    Write-Host "  Done. $count name(s) restored." -ForegroundColor Cyan
    return
}

# ----------------------------- pick items ---------------------------------
$isFolders = $what -eq '7'
Write-Host ''
$sub = (Ask '  Also rename inside subfolders? (Y/N)' 'y', 'n') -eq 'y'

if ($isFolders) {
    $items = @(Get-ChildItem -LiteralPath $folder -Directory -Recurse:$sub)
} else {
    $ext = $types[$what].Ext
    $items = @(Get-ChildItem -LiteralPath $folder -File -Recurse:$sub | Where-Object {
        $_.Name -notin $skipNames -and (-not $ext -or $_.Extension -in $ext)
    })
}
if (-not $items) { Write-Host '  Nothing found to rename.' -ForegroundColor Yellow; return }
Write-Host "  Found $($items.Count) item(s)."

# ----------------------------- pick method --------------------------------
Write-Host ''
Write-Host '  How do you want to rename?'
Write-Host '    1 = New name + number       e.g.  Flood_001, Flood_002 ...'
Write-Host '    2 = Add text at the start   e.g.  ERC_photo'
Write-Host '    3 = Add text at the end     e.g.  photo_final'
Write-Host '    4 = Replace text            e.g.  "Copy of " -> nothing'
Write-Host '    5 = Add date at the start   e.g.  2026-08-20_photo  (date modified)'
Write-Host '    6 = Clean up names          spaces -> _, removes odd characters'
$how = Ask '  Enter 1-6' '1', '2', '3', '4', '5', '6'

switch ($how) {
    '1' {
        do { $base = Clean (Read-Host '  New name (e.g. Flood)') } until ($base)
        $startIn = "$(Read-Host '  Start numbering from (press Enter for 1)')".Trim()
        $start = if ($startIn -match '^\d+$') { [int]$startIn } else { 1 }
        Write-Host '  Order for numbering:'
        Write-Host '    1 = By name'
        Write-Host '    2 = By date modified (oldest first)'
        $order = Ask '  Enter 1 or 2' '1', '2'
        $sep = if ($base -match '[ _-]$') { '' } else { '_' }
    }
    '2' { do { $text = "$(Read-Host '  Text to add at the start (include _ or space if you want one)')" -replace '[\\/:*?"<>|]', '' } until ($text) }
    '3' { do { $text = "$(Read-Host '  Text to add at the end (include _ or space if you want one)')" -replace '[\\/:*?"<>|]', '' } until ($text) }
    '4' {
        do { $find = "$(Read-Host '  Text to find')" } until ($find)
        $with = "$(Read-Host '  Replace with (press Enter to remove it)')" -replace '[\\/:*?"<>|]', ''
    }
}

# ----------------------------- build new names ----------------------------
$plan = New-Object System.Collections.Generic.List[object]
foreach ($grp in ($items | Group-Object { Split-Path $_.FullName -Parent })) {
    $parent = $grp.Name
    $list = if ($how -eq '1' -and $order -eq '2') { @($grp.Group | Sort-Object LastWriteTime, Name) }
            else { @($grp.Group | Sort-Object { NaturalKey $_.Name }) }
    $digits = [math]::Max(3, "$($start + $list.Count - 1)".Length)

    # names already in this folder that are not being renamed
    $taken = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $renaming = @{}; foreach ($it in $list) { $renaming[$it.Name.ToLower()] = $true }
    foreach ($o in (Get-ChildItem -LiteralPath $parent -Force)) { if (-not $renaming.ContainsKey($o.Name.ToLower())) { [void]$taken.Add($o.Name) } }

    $n = $start
    foreach ($it in $list) {
        $stem = if ($isFolders) { $it.Name } else { [IO.Path]::GetFileNameWithoutExtension($it.Name) }
        $ext  = if ($isFolders) { '' } else { $it.Extension }
        $new = switch ($how) {
            '1' { $base + $sep + $n.ToString("D$digits") }
            '2' { $text + $stem }
            '3' { $stem + $text }
            '4' { $stem.Replace($find, $with) }
            '5' { $it.LastWriteTime.ToString('yyyy-MM-dd') + '_' + $stem }
            '6' { (($stem -replace '[^\w\-\.]+', '_') -replace '_{2,}', '_').Trim('_') }
        }
        $n++
        $new = $new.Trim().TrimEnd('.')
        if (-not $new) { $new = $stem }
        $full = $new + $ext
        $k = 2
        while ($taken.Contains($full)) { $full = "$new ($k)$ext"; $k++ }
        [void]$taken.Add($full)
        if ($full -cne $it.Name) { $plan.Add([pscustomobject]@{ Parent = $parent; From = $it.Name; To = $full }) }
    }
}

if (-not $plan.Count) { Write-Host ''; Write-Host '  Nothing would change - no renames needed.' -ForegroundColor Yellow; return }

# ----------------------------- preview ------------------------------------
Write-Host ''
Write-Host "  Preview ($($plan.Count) item(s) will be renamed):" -ForegroundColor Cyan
foreach ($p in ($plan | Select-Object -First 20)) {
    $rel = if ($p.Parent -eq $folder) { '' } else { $p.Parent.Substring($folder.Length + 1) + '\' }
    Write-Host "    $rel$($p.From)" -NoNewline
    Write-Host "  ->  $($p.To)" -ForegroundColor Green
}
if ($plan.Count -gt 20) { Write-Host "    ... and $($plan.Count - 20) more" }
Write-Host ''
if ((Ask '  Rename now? (Y/N)' 'y', 'n') -ne 'y') { Write-Host '  Cancelled. Nothing was changed.'; return }

# ----------------------------- rename -------------------------------------
# Folders: deepest first, so parent paths stay valid while renaming
$groups = @($plan | Group-Object Parent | Sort-Object @{ e = { Depth $_.Name }; Descending = $true })
$log = New-Object System.Collections.Generic.List[object]
$g = 0
foreach ($grp in $groups) {
    $g++
    foreach ($d in (Rename-Group $grp.Name @($grp.Group))) {
        $log.Add([pscustomobject]@{ Group = $g; Parent = $grp.Name; OldName = $d.From; NewName = $d.To })
    }
}
if ($log.Count) { $log | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding UTF8 }

Write-Host ''
Write-Host "  Done. $($log.Count) item(s) renamed." -ForegroundColor Cyan
Write-Host '  Changed your mind? Run this again and choose 8 = UNDO.'
