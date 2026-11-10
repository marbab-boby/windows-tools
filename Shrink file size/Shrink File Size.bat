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
#  Shrink File Size
#  Put this .bat in a folder and double-click it. It makes smaller copies of
#  PowerPoint files, PDFs, videos and images in a "_Shrunk" subfolder.
#  The original files are never changed.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem, System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.IO;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

public static class ImgShrink
{
    static ImageCodecInfo jpegCodec;

    static ImageCodecInfo JpegCodec()
    {
        if (jpegCodec == null)
            foreach (var c in ImageCodecInfo.GetImageEncoders())
                if (c.FormatID == ImageFormat.Jpeg.Guid) jpegCodec = c;
        return jpegCodec;
    }

    static bool HasTransparency(Bitmap bmp)
    {
        // Indexed (palette) images can hide transparency in the palette - treat as transparent
        if ((bmp.PixelFormat & PixelFormat.Indexed) != 0) return true;
        if (!Image.IsAlphaPixelFormat(bmp.PixelFormat)) return false;
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            int len = bmp.Width * 4;
            var row = new byte[len];
            for (int y = 0; y < bmp.Height; y++)
            {
                Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), row, 0, len);
                for (int x = 3; x < len; x += 4) if (row[x] != 255) return true;
            }
        }
        finally { bmp.UnlockBits(data); }
        return false;
    }

    // Returns smaller image bytes, or null when the image should be left as it is.
    // outExt is ".jpeg" when a PNG without transparency was turned into a JPEG.
    public static byte[] Shrink(byte[] data, string ext, int maxSide, long quality, bool allowPngToJpg, out string outExt)
    {
        outExt = ext;
        try
        {
            using (var img = Image.FromStream(new MemoryStream(data)))
            {
                var src = img as Bitmap;
                if (src == null) return null;
                if (img.FrameDimensionsList.Length > 0 && img.GetFrameCount(new FrameDimension(img.FrameDimensionsList[0])) > 1) return null;
                foreach (int id in img.PropertyIdList)
                    if (id == 0x0112 && img.GetPropertyItem(id).Value[0] != 1) return null;   // rotated photo - leave alone

                bool isPng = ext == ".png";
                int w = img.Width, h = img.Height;
                double scale = Math.Min(1.0, (double)maxSide / Math.Max(w, h));
                int nw = Math.Max(1, (int)Math.Round(w * scale)), nh = Math.Max(1, (int)Math.Round(h * scale));
                bool alpha = isPng && HasTransparency(src);
                bool toJpg = !isPng || (allowPngToJpg && !alpha && data.Length > 200 * 1024);
                if (isPng && !toJpg && scale >= 1.0) return null;

                using (var bmp = new Bitmap(nw, nh, alpha ? PixelFormat.Format32bppArgb : PixelFormat.Format24bppRgb))
                {
                    bmp.SetResolution(img.HorizontalResolution, img.VerticalResolution);
                    using (var g = Graphics.FromImage(bmp))
                    using (var ia = new ImageAttributes())
                    {
                        if (!alpha) g.Clear(Color.White);
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.SmoothingMode = SmoothingMode.HighQuality;
                        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        g.CompositingQuality = CompositingQuality.HighQuality;
                        ia.SetWrapMode(WrapMode.TileFlipXY);
                        g.DrawImage(img, new Rectangle(0, 0, nw, nh), 0, 0, w, h, GraphicsUnit.Pixel, ia);
                    }
                    var ms = new MemoryStream();
                    if (toJpg)
                    {
                        var ep = new EncoderParameters(1);
                        ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
                        bmp.Save(ms, JpegCodec(), ep);
                        if (isPng) outExt = ".jpeg";
                    }
                    else bmp.Save(ms, ImageFormat.Png);
                    var result = ms.ToArray();
                    if (result.Length < data.Length * 0.95) return result;
                    outExt = ext;
                    return null;
                }
            }
        }
        catch { outExt = ext; return null; }
    }
}
'@

$folder = $env:TARGET.TrimEnd('\')
$outDir = Join-Path $folder '_Shrunk'
$tmpDir = Join-Path $env:TEMP ('shrink_' + [guid]::NewGuid().ToString('N'))
$videoExt = '.mp4', '.m4v', '.mov', '.avi', '.mkv', '.wmv', '.mpg', '.mpeg', '.webm', '.3gp', '.flv'
$noDeflate = '.jpg', '.jpeg', '.png', '.gif', '.mp4', '.m4v', '.mov', '.wmv', '.avi', '.mp3', '.m4a', '.wdp'

function Ask([string]$prompt, [string[]]$valid) {
    do { $a = "$(Read-Host $prompt)".Trim() } until ($a -in $valid)
    return $a
}
function Size([double]$b) { if ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f ($b / 1KB) } }

function Find-Ffmpeg {
    $c = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $paths = @("$env:LOCALAPPDATA\Microsoft\WinGet\Packages\*FFmpeg*\*\bin\ffmpeg.exe",
               "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe", 'C:\ffmpeg\bin\ffmpeg.exe', 'D:\KDENLIVE\bin\ffmpeg.exe')
    $f = Get-ChildItem $paths -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}
function Find-Ghostscript {
    $c = Get-Command gswin64c.exe, gswin32c.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $f = Get-ChildItem "$env:ProgramFiles\gs\*\bin\gswin64c.exe", "${env:ProgramFiles(x86)}\gs\*\bin\gswin32c.exe" -ErrorAction SilentlyContinue |
         Sort-Object FullName -Descending | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}
function Offer-Install([string]$name, [string]$id) {
    Write-Host ''
    Write-Host "  $name is needed for this but is not installed on this PC." -ForegroundColor Yellow
    if ((Ask "  Install $name now (free, needs internet)? (Y/N)" 'y', 'n') -ne 'y') { return $false }
    & winget install --id $id -e --accept-source-agreements --accept-package-agreements | Out-Host
    return $true
}

function Shrink-Video([string]$in, [string]$out) {
    $fa = @('-hide_banner', '-loglevel', 'error', '-stats', '-y', '-i', $in)
    if ($vlimit -and $ffprobe -and (Test-Path -LiteralPath $ffprobe)) {
        try {
            $dims = "$(& $ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 $in)".Trim() -split ','
            if ([int]$dims[0] -gt $vlimit -or [int]$dims[1] -gt $vlimit) {
                $fa += '-vf', "scale=$($vlimit):$($vlimit):force_original_aspect_ratio=decrease:force_divisible_by=2"
            }
        } catch {}
    }
    $fa += '-c:v', 'libx264', '-preset', 'medium', '-crf', "$crf", '-pix_fmt', 'yuv420p',
           '-c:a', 'aac', '-b:a', $abr, '-movflags', '+faststart', $out
    $ErrorActionPreference = 'Continue'
    & $ffmpeg @fa | Out-Host
    $ok = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    Write-Host ''
    return ($ok -and (Test-Path -LiteralPath $out))
}

function Shrink-Pptx($file) {
    $src = [IO.Compression.ZipFile]::OpenRead($file.FullName)
    $out = $null
    try {
        $names = @{}
        foreach ($e in $src.Entries) { $names[$e.FullName] = $true }
        $repl = @{}      # entry -> new name + new content
        $renames = @{}   # media file renamed from .png to .jpeg
        $nImg = 0; $nVid = 0; $i = 0

        foreach ($e in $src.Entries) {
            if ($e.FullName -notlike 'ppt/media/*') { continue }
            $ext = [IO.Path]::GetExtension($e.Name).ToLower()
            $i++
            if ($ext -in '.jpg', '.jpeg', '.png') {
                $ms = New-Object IO.MemoryStream
                $s = $e.Open(); $s.CopyTo($ms); $s.Dispose()
                $outExt = $null
                $bytes = [ImgShrink]::Shrink($ms.ToArray(), $ext, $maxSide, $quality, $true, [ref]$outExt)
                if ($bytes) {
                    $newName = $e.FullName
                    if ($outExt -ne $ext) {
                        $base = $e.FullName.Substring(0, $e.FullName.Length - $ext.Length)
                        $newName = $base + $outExt; $n = 1
                        while ($names.ContainsKey($newName)) { $newName = "$base`_$n$outExt"; $n++ }
                        $names[$newName] = $true
                        $renames[$e.Name] = [IO.Path]::GetFileName($newName)
                    }
                    $repl[$e.FullName] = @{ Name = $newName; Bytes = $bytes }
                    $nImg++
                }
            }
            elseif ($pptVideos -and $ext -in '.mp4', '.m4v', '.mov') {
                Write-Host "      video $($e.Name) ($(Size $e.Length))"
                $vin = Join-Path $tmpDir "v$i$ext"; $vout = Join-Path $tmpDir "v$i-out$ext"
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $vin, $true)
                if ((Shrink-Video $vin $vout) -and (Get-Item -LiteralPath $vout).Length -lt $e.Length * 0.95) {
                    $repl[$e.FullName] = @{ Name = $e.FullName; Path = $vout }
                    $nVid++
                }
            }
        }

        if ($repl.Count -eq 0) { return $null }

        $out = Join-Path $tmpDir ('deck' + [guid]::NewGuid().ToString('N') + $file.Extension)
        $zip = [IO.Compression.ZipFile]::Open($out, 'Create')
        try {
            foreach ($e in $src.Entries) {
                $r = $repl[$e.FullName]
                $name = if ($r) { $r.Name } else { $e.FullName }
                $level = if ([IO.Path]::GetExtension($name).ToLower() -in $noDeflate) { 'NoCompression' } else { 'Optimal' }
                $os = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::$level).Open()
                try {
                    if ($r -and $r.Bytes) { $os.Write($r.Bytes, 0, $r.Bytes.Length) }
                    elseif ($r -and $r.Path) { $fs = [IO.File]::OpenRead($r.Path); $fs.CopyTo($os); $fs.Dispose() }
                    elseif ($renames.Count -and ($e.FullName -like '*.rels' -or $e.FullName -eq '[Content_Types].xml')) {
                        $sr = New-Object IO.StreamReader($e.Open()); $xml = $sr.ReadToEnd(); $sr.Dispose()
                        foreach ($k in $renames.Keys) {
                            $xml = $xml.Replace("media/$k`"", "media/$($renames[$k])`"")
                            $xml = [regex]::Replace($xml, '<Override PartName="/ppt/media/' + [regex]::Escape($renames[$k]) + '"[^>]*/>', '')
                        }
                        if ($e.FullName -eq '[Content_Types].xml' -and $xml -notmatch 'Extension="jpeg"') {
                            $xml = [regex]::Replace($xml, '(<Types[^>]*>)', '$1<Default Extension="jpeg" ContentType="image/jpeg"/>')
                        }
                        $b = (New-Object Text.UTF8Encoding($false)).GetBytes($xml)
                        $os.Write($b, 0, $b.Length)
                    }
                    else { $is = $e.Open(); $is.CopyTo($os); $is.Dispose() }
                } finally { $os.Dispose() }
            }
        } finally { $zip.Dispose() }
        Write-Host "      $nImg image(s) and $nVid video(s) made smaller" -ForegroundColor DarkGray
        return $out
    } finally { $src.Dispose() }
}

# Save the result into _Shrunk only if it really is smaller
function Keep-Result($file, [string]$tempOut, [string]$outName) {
    if (-not $tempOut -or -not (Test-Path -LiteralPath $tempOut)) {
        Write-Host "  = $($file.Name): already compact, nothing saved" -ForegroundColor DarkGray
        return
    }
    $newSize = (Get-Item -LiteralPath $tempOut).Length
    if ($newSize -ge $file.Length * 0.97) {
        Write-Host "  = $($file.Name): already compact, nothing saved" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $tempOut -Force
        return
    }
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
    Move-Item -LiteralPath $tempOut -Destination (Join-Path $outDir $outName) -Force
    $script:totalBefore += $file.Length; $script:totalAfter += $newSize
    $pct = [math]::Round(100 - 100 * $newSize / $file.Length)
    Write-Host ("  + {0}: {1} -> {2}  ({3}% smaller)" -f $file.Name, (Size $file.Length), (Size $newSize), $pct) -ForegroundColor Green
}

# ----------------------------- main ---------------------------------------
Write-Host ''
Write-Host '  ===== Shrink file size =====' -ForegroundColor Cyan
Write-Host "  Folder: $folder"
Write-Host '  Smaller copies go to the "_Shrunk" subfolder. Originals are not changed.'
Write-Host ''

$all = @(Get-ChildItem -LiteralPath $folder -File)
$pptFiles = @($all | Where-Object { $_.Extension -in '.pptx', '.pptm', '.ppsx', '.potx' })
$pdfFiles = @($all | Where-Object { $_.Extension -eq '.pdf' })
$vidFiles = @($all | Where-Object { $_.Extension -in $videoExt })
$imgFiles = @($all | Where-Object { $_.Extension -in '.jpg', '.jpeg', '.png' })

if (-not ($pptFiles.Count + $pdfFiles.Count + $vidFiles.Count + $imgFiles.Count)) {
    Write-Host '  No PowerPoint, PDF, video or image files found in this folder.' -ForegroundColor Red
    return
}

Write-Host '  What do you want to shrink?'
Write-Host "    1 = PowerPoint files   ($($pptFiles.Count) found)"
Write-Host "    2 = PDF files          ($($pdfFiles.Count) found)"
Write-Host "    3 = Videos             ($($vidFiles.Count) found)"
Write-Host "    4 = Images             ($($imgFiles.Count) found)"
Write-Host '    5 = Everything above'
$choice = Ask '  Enter 1-5' '1', '2', '3', '4', '5'
$doPpt = $choice -in '1', '5'; $doPdf = $choice -in '2', '5'
$doVid = $choice -in '3', '5'; $doImg = $choice -in '4', '5'

if (($doPpt -and $pptFiles) -or ($doPdf -and $pdfFiles) -or ($doImg -and $imgFiles)) {
    Write-Host ''
    Write-Host '  How much to shrink (images / PDFs / slides)?'
    Write-Host '    1 = Light   - best quality, smaller saving'
    Write-Host '    2 = Medium  - good balance (recommended)'
    Write-Host '    3 = Strong  - smallest files, lower quality'
    $lvl = Ask '  Enter 1, 2 or 3' '1', '2', '3'
    $maxSide = @{ '1' = 2560; '2' = 1920; '3' = 1280 }[$lvl]
    $quality = @{ '1' = 85; '2' = 75; '3' = 60 }[$lvl]
    $pdfSet  = @{ '1' = '/printer'; '2' = '/ebook'; '3' = '/screen' }[$lvl]
}

$pptVideos = $false
if ($doPpt -and $pptFiles) {
    Write-Host ''
    $pptVideos = (Ask '  Also shrink the videos inside the PowerPoints? (slower) (Y/N)' 'y', 'n') -eq 'y'
}

$ffmpeg = $null; $ffprobe = $null
if (($doVid -and $vidFiles) -or $pptVideos) {
    Write-Host ''
    Write-Host '  Video quality?'
    Write-Host '    1 = High    - same resolution, looks the same'
    Write-Host '    2 = Medium  - up to 1080p (recommended)'
    Write-Host '    3 = Small   - up to 720p, good for WhatsApp / email'
    $vq = Ask '  Enter 1, 2 or 3' '1', '2', '3'
    $crf    = @{ '1' = 23; '2' = 26; '3' = 30 }[$vq]
    $vlimit = @{ '1' = 0; '2' = 1920; '3' = 1280 }[$vq]
    $abr    = @{ '1' = '128k'; '2' = '128k'; '3' = '96k' }[$vq]

    $ffmpeg = Find-Ffmpeg
    if (-not $ffmpeg -and (Offer-Install 'FFmpeg' 'Gyan.FFmpeg')) { $ffmpeg = Find-Ffmpeg }
    if ($ffmpeg) { $ffprobe = Join-Path (Split-Path $ffmpeg) 'ffprobe.exe' }
    else {
        Write-Host '  FFmpeg is not available - videos will be skipped.' -ForegroundColor Yellow
        $doVid = $false; $pptVideos = $false
    }
}

$gs = $null
if ($doPdf -and $pdfFiles) {
    $gs = Find-Ghostscript
    if (-not $gs -and (Offer-Install 'Ghostscript' 'ArtifexSoftware.GhostScript')) { $gs = Find-Ghostscript }
    if (-not $gs) {
        Write-Host '  Ghostscript is not available - PDFs will be skipped.' -ForegroundColor Yellow
        $doPdf = $false
    }
}

$totalBefore = 0; $totalAfter = 0
New-Item -ItemType Directory -Path $tmpDir | Out-Null
try {
    if ($doPpt -and $pptFiles) {
        Write-Host ''; Write-Host '  --- PowerPoint ---' -ForegroundColor Cyan
        foreach ($f in $pptFiles) {
            Write-Host "  Working on $($f.Name) ..."
            try { Keep-Result $f (Shrink-Pptx $f) $f.Name }
            catch { Write-Host "  [!] $($f.Name): $($_.Exception.Message)" -ForegroundColor Red }
        }
    }

    if ($doPdf -and $pdfFiles) {
        Write-Host ''; Write-Host '  --- PDF ---' -ForegroundColor Cyan
        foreach ($f in $pdfFiles) {
            Write-Host "  Working on $($f.Name) ..."
            $tIn = Join-Path $tmpDir 'in.pdf'; $tOut = Join-Path $tmpDir 'out.pdf'
            Copy-Item -LiteralPath $f.FullName -Destination $tIn -Force
            $ErrorActionPreference = 'Continue'
            & $gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.5 "-dPDFSETTINGS=$pdfSet" -dDetectDuplicateImages=true `
                  -dNOPAUSE -dQUIET -dBATCH "-sOutputFile=$tOut" $tIn | Out-Host
            $ok = $LASTEXITCODE -eq 0
            $ErrorActionPreference = 'Stop'
            if ($ok) { Keep-Result $f $tOut $f.Name }
            else { Write-Host "  [!] $($f.Name): could not be processed (password protected or damaged?)" -ForegroundColor Red }
        }
    }

    if ($doVid -and $vidFiles) {
        Write-Host ''; Write-Host '  --- Videos ---' -ForegroundColor Cyan
        $used = @{}
        foreach ($f in $vidFiles) {
            Write-Host "  Working on $($f.Name) ($(Size $f.Length)) ..."
            $outName = $f.BaseName + '.mp4'
            if ($used.ContainsKey($outName)) { $outName = $f.BaseName + '_' + $f.Extension.TrimStart('.') + '.mp4' }
            $used[$outName] = $true
            $tOut = Join-Path $tmpDir ('vid' + [guid]::NewGuid().ToString('N') + '.mp4')
            if (Shrink-Video $f.FullName $tOut) { Keep-Result $f $tOut $outName }
            else { Write-Host "  [!] $($f.Name): could not be processed" -ForegroundColor Red }
        }
    }

    if ($doImg -and $imgFiles) {
        Write-Host ''; Write-Host '  --- Images ---' -ForegroundColor Cyan
        foreach ($f in $imgFiles) {
            $outExt = $null
            # PNG photos without transparency are saved as .jpg (much smaller)
            $bytes = [ImgShrink]::Shrink([IO.File]::ReadAllBytes($f.FullName), $f.Extension.ToLower(), $maxSide, $quality, $true, [ref]$outExt)
            $tOut = $null
            if ($bytes) { $tOut = Join-Path $tmpDir ('img' + [guid]::NewGuid().ToString('N')); [IO.File]::WriteAllBytes($tOut, $bytes) }
            $outName = if ($outExt -eq '.jpeg' -and $f.Extension -eq '.png') { $f.BaseName + '.jpg' } else { $f.Name }
            Keep-Result $f $tOut $outName
        }
    }
}
finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($totalBefore) {
    Write-Host ("  Done. Saved files: {0} -> {1}  ({2}% smaller). See the _Shrunk folder." -f (Size $totalBefore), (Size $totalAfter),
        [math]::Round(100 - 100 * $totalAfter / $totalBefore)) -ForegroundColor Cyan
} else {
    Write-Host '  Done. Nothing could be made smaller.' -ForegroundColor Cyan
}
