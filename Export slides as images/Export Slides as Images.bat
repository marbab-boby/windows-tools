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
#  Export Slides as Images
#  Put this .bat in a folder with PowerPoint files and double-click it.
#  Every slide of every presentation is saved as a picture in a subfolder
#  named "<presentation name> - Slides". Needs Microsoft PowerPoint.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$folder = $env:TARGET.TrimEnd('\')

function Ask([string]$prompt, [string[]]$valid) {
    do { $a = "$(Read-Host $prompt)".Trim() } until ($a -in $valid)
    return $a
}

Write-Host ''
Write-Host '  ===== Export slides as images =====' -ForegroundColor Cyan
Write-Host "  Folder: $folder"
Write-Host ''

$decks = @(Get-ChildItem -LiteralPath $folder -File | Where-Object { $_.Extension -in '.pptx', '.ppt', '.pptm', '.ppsx', '.pps', '.potx' })
if (-not $decks) {
    Write-Host '  No PowerPoint files found in this folder.' -ForegroundColor Red
    return
}
Write-Host "  Found $($decks.Count) presentation(s)."
Write-Host ''
Write-Host '  Image format?'
Write-Host '    1 = PNG  - sharpest, bigger files (best for text / maps)'
Write-Host '    2 = JPG  - smaller files (best for photos / WhatsApp)'
$fmt = Ask '  Enter 1 or 2' '1', '2'
$ext = @{ '1' = 'png'; '2' = 'jpg' }[$fmt]

Write-Host ''
Write-Host '  Image size?'
Write-Host '    1 = Normal   - 1280 px wide'
Write-Host '    2 = Full HD  - 1920 px wide (recommended)'
Write-Host '    3 = 4K       - 3840 px wide (for printing)'
$width = @{ '1' = 1280; '2' = 1920; '3' = 3840 }[(Ask '  Enter 1, 2 or 3' '1', '2', '3')]

Write-Host ''
$withHidden = (Ask '  Also export hidden slides? (Y/N)' 'y', 'n') -eq 'y'

$wasRunning = [bool](Get-Process POWERPNT -ErrorAction SilentlyContinue)
try {
    $app = New-Object -ComObject PowerPoint.Application
} catch {
    Write-Host '  Microsoft PowerPoint is needed for this tool but could not be started.' -ForegroundColor Red
    return
}

Write-Host ''
$total = 0
try {
    foreach ($f in $decks) {
        $pres = $null
        try {
            # ReadOnly, not Untitled, no window
            $pres = $app.Presentations.Open($f.FullName, -1, 0, 0)
            $height = [int][math]::Round($width * $pres.PageSetup.SlideHeight / $pres.PageSetup.SlideWidth)
            $out = Join-Path $folder ($f.BaseName.Trim().TrimEnd('.') + ' - Slides')
            if (-not (Test-Path -LiteralPath $out)) { New-Item -ItemType Directory -Path $out | Out-Null }
            $digits = [math]::Max(2, "$($pres.Slides.Count)".Length)
            $n = 0
            foreach ($s in $pres.Slides) {
                if (-not $withHidden -and $s.SlideShowTransition.Hidden -eq -1) { continue }
                $file = Join-Path $out (("Slide {0:D$digits}." -f $s.SlideIndex) + $ext)
                $s.Export($file, $ext.ToUpper(), $width, $height)
                $n++
                Write-Host "`r  $($f.Name): slide $n" -NoNewline
            }
            $total += $n
            Write-Host "`r  + $($f.Name): $n slide(s)  ->  $(Split-Path $out -Leaf)\" -ForegroundColor Green
        }
        catch {
            Write-Host ''
            Write-Host "  [!] $($f.Name): could not export (password protected or damaged?)" -ForegroundColor Red
        }
        finally {
            if ($pres) { $pres.Close(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($pres) }
        }
    }
}
finally {
    # Only close PowerPoint if it was not already open before
    if (-not $wasRunning) { $app.Quit() }
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app)
}

Write-Host ''
Write-Host "  Done. $total slide image(s) saved." -ForegroundColor Cyan
