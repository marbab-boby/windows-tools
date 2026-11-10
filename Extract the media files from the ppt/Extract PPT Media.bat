<# : batch launcher - do not edit these lines
@echo off
setlocal
set "TARGET=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText('%~f0'))"
echo.
pause
exit /b
#>

# ---------------------------------------------------------------------------
#  Extract PPT Media
#  Put this .bat in a folder with PowerPoint files and double-click it.
#  For every .pptx / .pptm / .ppsx / .potx in that folder it creates a
#  subfolder named after the file and copies the embedded images/videos into it.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$folder = $env:TARGET.TrimEnd('\')
$imageExt = '.png','.jpg','.jpeg','.gif','.bmp','.tif','.tiff','.svg','.webp','.emf','.wmf'
$videoExt = '.mp4','.m4v','.mov','.wmv','.avi','.mkv','.mpg','.mpeg','.webm','.3gp'

Write-Host ''
Write-Host '  ===== Extract media from PowerPoint files =====' -ForegroundColor Cyan
Write-Host "  Folder: $folder"
Write-Host ''

$decks = Get-ChildItem -LiteralPath $folder -File | Where-Object { $_.Extension -in '.pptx','.pptm','.ppsx','.potx' }
$oldPpt = Get-ChildItem -LiteralPath $folder -File -Filter *.ppt | Where-Object { $_.Extension -eq '.ppt' }

if ($oldPpt) {
    Write-Host "  Skipping $($oldPpt.Count) old-format .ppt file(s) - open and 'Save As' .pptx first:" -ForegroundColor Yellow
    $oldPpt | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Yellow }
    Write-Host ''
}
if (-not $decks) {
    Write-Host '  No .pptx files found in this folder.' -ForegroundColor Red
    return
}

Write-Host "  Found $($decks.Count) presentation(s)."
Write-Host ''
Write-Host '  What do you want to extract?'
Write-Host '    1 = Images only'
Write-Host '    2 = Videos only'
Write-Host '    3 = Both images and videos'
do { $choice = (Read-Host '  Enter 1, 2 or 3').Trim() } until ($choice -in '1','2','3')

$wantImages = $choice -in '1','3'
$wantVideos = $choice -in '2','3'

# Work out the real type of a file from its first bytes (for files with odd names)
function Get-ExtFromBytes([byte[]]$b) {
    if ($b.Length -lt 12) { return '' }
    if ($b[0] -eq 0xFF -and $b[1] -eq 0xD8) { return '.jpg' }
    if ($b[0] -eq 0x89 -and $b[1] -eq 0x50) { return '.png' }
    if ($b[0] -eq 0x47 -and $b[1] -eq 0x49) { return '.gif' }
    if ($b[0] -eq 0x42 -and $b[1] -eq 0x4D) { return '.bmp' }
    if ($b[0] -eq 0x52 -and $b[1] -eq 0x49 -and $b[8] -eq 0x57) { return '.webp' }
    if ($b[0] -eq 0x52 -and $b[1] -eq 0x49 -and $b[8] -eq 0x41) { return '.avi' }
    if ($b[4] -eq 0x66 -and $b[5] -eq 0x74 -and $b[6] -eq 0x79 -and $b[7] -eq 0x70) { return '.mp4' }
    if ($b[0] -eq 0x30 -and $b[1] -eq 0x26 -and $b[2] -eq 0xB2) { return '.wmv' }
    if ($b[0] -eq 0x1A -and $b[1] -eq 0x45 -and $b[2] -eq 0xDF) { return '.mkv' }
    return ''
}

$totalImg = 0; $totalVid = 0
foreach ($deck in $decks) {
    $name = [IO.Path]::GetFileNameWithoutExtension($deck.Name).Trim().TrimEnd('.')
    $out = Join-Path $folder $name
    $img = 0; $vid = 0

    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($deck.FullName)
    } catch {
        Write-Host "  [!] Could not open '$($deck.Name)' (is it open in PowerPoint or damaged?)" -ForegroundColor Red
        continue
    }

    try {
        foreach ($e in $zip.Entries) {
            if ($e.FullName -notlike 'ppt/media/*' -or -not $e.Name) { continue }

            # Clean names like "image38.jpg?stp=...&oh=..." copied from websites
            $fileName = ($e.Name -split '[?&]')[0] -replace '[\\/:*?"<>|]', '_'
            $ext = [IO.Path]::GetExtension($fileName).ToLower()

            if ($ext -notin $imageExt -and $ext -notin $videoExt) {
                $s = $e.Open(); $buf = New-Object byte[] 16; [void]$s.Read($buf, 0, 16); $s.Dispose()
                $real = Get-ExtFromBytes $buf
                if (-not $real) { continue }          # unknown / .wdp duplicates etc.
                $fileName = [IO.Path]::GetFileNameWithoutExtension($fileName) + $real
                $ext = $real
            }

            $isImg = $ext -in $imageExt
            if (($isImg -and -not $wantImages) -or (-not $isImg -and -not $wantVideos)) { continue }

            if (-not (Test-Path -LiteralPath $out)) { New-Item -ItemType Directory -Path $out | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $out $fileName), $true)
            if ($isImg) { $img++ } else { $vid++ }
        }
    } finally {
        $zip.Dispose()
    }

    $totalImg += $img; $totalVid += $vid
    if ($img + $vid -eq 0) {
        Write-Host "  - $($deck.Name): nothing to extract" -ForegroundColor DarkGray
    } else {
        Write-Host "  + $($deck.Name): $img image(s), $vid video(s)  ->  $name\" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host "  Done. $totalImg image(s) and $totalVid video(s) extracted." -ForegroundColor Cyan
