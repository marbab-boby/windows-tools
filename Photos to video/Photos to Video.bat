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
#  Photos to Video
#  Put this .bat in a folder of photos and double-click it. It makes a
#  slideshow MP4 of all the photos, with optional fades, captions and music.
#  If an MP3 / M4A / WAV file is in the same folder it can be used as music.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.IO;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Drawing2D;
using System.Drawing.Text;

public static class Slide
{
    static ImageCodecInfo jpeg;

    public static DateTime DateTaken(string path)
    {
        try
        {
            using (var fs = File.OpenRead(path))
            using (var img = Image.FromStream(fs, false, false))
            {
                foreach (int id in img.PropertyIdList)
                    if (id == 0x9003)
                    {
                        string s = System.Text.Encoding.ASCII.GetString(img.GetPropertyItem(id).Value).Trim('\0', ' ');
                        DateTime d;
                        if (DateTime.TryParseExact(s, "yyyy:MM:dd HH:mm:ss", null, System.Globalization.DateTimeStyles.None, out d)) return d;
                    }
            }
        }
        catch { }
        return File.GetLastWriteTime(path);
    }

    static void FixRotation(Image img)
    {
        foreach (int id in img.PropertyIdList)
        {
            if (id != 0x0112) continue;
            switch (img.GetPropertyItem(id).Value[0])
            {
                case 2: img.RotateFlip(RotateFlipType.RotateNoneFlipX); break;
                case 3: img.RotateFlip(RotateFlipType.Rotate180FlipNone); break;
                case 4: img.RotateFlip(RotateFlipType.Rotate180FlipX); break;
                case 5: img.RotateFlip(RotateFlipType.Rotate90FlipX); break;
                case 6: img.RotateFlip(RotateFlipType.Rotate90FlipNone); break;
                case 7: img.RotateFlip(RotateFlipType.Rotate270FlipX); break;
                case 8: img.RotateFlip(RotateFlipType.Rotate270FlipNone); break;
            }
        }
    }

    static void Quality(Graphics g)
    {
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.SmoothingMode = SmoothingMode.HighQuality;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.CompositingQuality = CompositingQuality.HighQuality;
    }

    // Draws one photo onto a W x H frame (fitted, never cropped) and saves it as JPEG
    public static void Render(string src, string dest, int W, int H, bool blurBack, string caption)
    {
        using (var img = Image.FromFile(src))
        using (var frame = new Bitmap(W, H, PixelFormat.Format24bppRgb))
        using (var g = Graphics.FromImage(frame))
        {
            FixRotation(img);
            g.Clear(Color.Black);
            Quality(g);

            if (blurBack)
            {
                // blurred, darkened copy of the photo filling the whole frame
                double cover = Math.Max((double)W / img.Width, (double)H / img.Height);
                int sw = Math.Max(1, W / 24), sh = Math.Max(1, H / 24);
                using (var small = new Bitmap(sw, sh))
                {
                    using (var gs = Graphics.FromImage(small))
                    {
                        Quality(gs);
                        int cw = (int)(img.Width * cover / 24), ch = (int)(img.Height * cover / 24);
                        gs.DrawImage(img, (sw - cw) / 2, (sh - ch) / 2, cw, ch);
                    }
                    g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                    using (var ia = new ImageAttributes())
                    {
                        ia.SetWrapMode(WrapMode.TileFlipXY);
                        g.DrawImage(small, new Rectangle(0, 0, W, H), 0, 0, sw, sh, GraphicsUnit.Pixel, ia);
                    }
                    using (var shade = new SolidBrush(Color.FromArgb(110, 0, 0, 0))) g.FillRectangle(shade, 0, 0, W, H);
                    Quality(g);
                }
            }

            double fit = Math.Min((double)W / img.Width, (double)H / img.Height);
            int w = (int)Math.Round(img.Width * fit), h = (int)Math.Round(img.Height * fit);
            using (var ia = new ImageAttributes())
            {
                ia.SetWrapMode(WrapMode.TileFlipXY);
                g.DrawImage(img, new Rectangle((W - w) / 2, (H - h) / 2, w, h), 0, 0, img.Width, img.Height, GraphicsUnit.Pixel, ia);
            }

            if (!string.IsNullOrEmpty(caption))
            {
                float size = Math.Min(W, H) / 22f;
                using (var font = new Font("Segoe UI", size, FontStyle.Bold, GraphicsUnit.Pixel))
                using (var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center, Trimming = StringTrimming.EllipsisCharacter })
                using (var band = new SolidBrush(Color.FromArgb(150, 0, 0, 0)))
                {
                    g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                    int bh = (int)(size * 2.1f);
                    var r = new RectangleF(0, H - bh - H / 20f, W, bh);
                    g.FillRectangle(band, r);
                    g.DrawString(caption, font, Brushes.White, new RectangleF(r.X + W / 30f, r.Y, r.Width - W / 15f, r.Height), fmt);
                }
            }

            if (jpeg == null)
                foreach (var c in ImageCodecInfo.GetImageEncoders()) if (c.FormatID == ImageFormat.Jpeg.Guid) jpeg = c;
            var ep = new EncoderParameters(1);
            ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 92L);
            frame.Save(dest, jpeg, ep);
        }
    }
}
'@

$folder = $env:TARGET.TrimEnd('\')
$tmpDir = Join-Path $env:TEMP ('p2v_' + [guid]::NewGuid().ToString('N').Substring(0, 8))

function Ask([string]$prompt, [string[]]$valid) {
    do { $a = "$(Read-Host $prompt)".Trim() } until ($a -in $valid)
    return $a
}
function NaturalKey([string]$s) { [regex]::Replace($s, '\d+', { $args[0].Value.PadLeft(12, '0') }) }
function Num([double]$d) { $d.ToString([Globalization.CultureInfo]::InvariantCulture) }

function Find-Ffmpeg {
    $c = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $paths = @("$env:LOCALAPPDATA\Microsoft\WinGet\Packages\*FFmpeg*\*\bin\ffmpeg.exe",
               "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe", 'C:\ffmpeg\bin\ffmpeg.exe', 'D:\KDENLIVE\bin\ffmpeg.exe')
    $f = Get-ChildItem $paths -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

Write-Host ''
Write-Host '  ===== Photos to video =====' -ForegroundColor Cyan
Write-Host "  Folder: $folder"
Write-Host ''

$photos = @(Get-ChildItem -LiteralPath $folder -File | Where-Object { $_.Extension -in '.jpg', '.jpeg', '.png', '.bmp', '.gif', '.tif', '.tiff' })
if ($photos.Count -lt 2) { Write-Host '  Need at least 2 photos in this folder.' -ForegroundColor Red; return }
$music = @(Get-ChildItem -LiteralPath $folder -File | Where-Object { $_.Extension -in '.mp3', '.m4a', '.wav', '.aac', '.wma', '.ogg' })

$ffmpeg = Find-Ffmpeg
if (-not $ffmpeg) {
    Write-Host '  FFmpeg is needed for this tool but is not installed on this PC.' -ForegroundColor Yellow
    if ((Ask '  Install FFmpeg now (free, needs internet)? (Y/N)' 'y', 'n') -ne 'y') { return }
    & winget install --id Gyan.FFmpeg -e --accept-source-agreements --accept-package-agreements | Out-Host
    $ffmpeg = Find-Ffmpeg
    if (-not $ffmpeg) { Write-Host '  FFmpeg could not be found after install. Close this window and try again.' -ForegroundColor Red; return }
}

Write-Host "  Found $($photos.Count) photo(s)."
Write-Host ''
Write-Host '  Photo order?'
Write-Host '    1 = By file name'
Write-Host '    2 = By date taken (oldest first)'
$order = Ask '  Enter 1 or 2' '1', '2'

Write-Host ''
Write-Host '  How long should each photo show?'
Write-Host '    1 = 2 seconds'
Write-Host '    2 = 3 seconds (recommended)'
Write-Host '    3 = 5 seconds'
Write-Host '    4 = Other'
$d = Ask '  Enter 1-4' '1', '2', '3', '4'
$dur = switch ($d) { '1' { 2.0 } '2' { 3.0 } '3' { 5.0 } '4' {
    do { $x = "$(Read-Host '  Seconds per photo (e.g. 4 or 1.5)')".Trim().Replace(',', '.') } until ($x -match '^\d+(\.\d+)?$' -and [double]::Parse($x, [Globalization.CultureInfo]::InvariantCulture) -ge 0.5)
    [double]::Parse($x, [Globalization.CultureInfo]::InvariantCulture) } }

Write-Host ''
Write-Host '  Transition between photos?'
Write-Host '    1 = Smooth fade (recommended)'
Write-Host '    2 = None (straight cut)'
$fade = (Ask '  Enter 1 or 2' '1', '2') -eq '1'

Write-Host ''
Write-Host '  Video shape?'
Write-Host '    1 = Landscape Full HD  1920 x 1080 (recommended)'
Write-Host '    2 = Landscape HD       1280 x 720  (smaller file)'
Write-Host '    3 = Vertical           1080 x 1920 (WhatsApp status / Reels)'
Write-Host '    4 = Square             1080 x 1080'
$shape = Ask '  Enter 1-4' '1', '2', '3', '4'
$W, $H = switch ($shape) { '1' { 1920, 1080 } '2' { 1280, 720 } '3' { 1080, 1920 } '4' { 1080, 1080 } }

Write-Host ''
Write-Host '  Empty space around photos that do not fit the shape?'
Write-Host '    1 = Blurred copy of the photo (recommended)'
Write-Host '    2 = Black'
$blur = (Ask '  Enter 1 or 2' '1', '2') -eq '1'

Write-Host ''
$captions = (Ask '  Show each file name as a caption on the photo? (Y/N)' 'y', 'n') -eq 'y'

$song = $null
if ($music) {
    Write-Host ''
    Write-Host '  Background music?'
    Write-Host '    0 = No music'
    for ($i = 0; $i -lt $music.Count; $i++) { Write-Host "    $($i + 1) = $($music[$i].Name)" }
    $m = Ask "  Enter 0-$($music.Count)" (0..$music.Count | ForEach-Object { "$_" })
    if ($m -ne '0') { $song = $music[[int]$m - 1].FullName }
}

# ----------------------------- order photos -------------------------------
if ($order -eq '2') {
    $photos = @($photos | Sort-Object @{ e = { [Slide]::DateTaken($_.FullName) } }, Name)
} else {
    $photos = @($photos | Sort-Object { NaturalKey $_.Name })
}

# ----------------------------- render frames ------------------------------
New-Item -ItemType Directory -Path $tmpDir | Out-Null
try {
    Write-Host ''
    $frames = New-Object System.Collections.Generic.List[string]
    $i = 0
    foreach ($p in $photos) {
        $i++
        Write-Host "`r  Preparing photo $i of $($photos.Count) ...   " -NoNewline
        $dest = Join-Path $tmpDir ('{0:D4}.jpg' -f $i)
        $cap = if ($captions) { $p.BaseName -replace '[_]+', ' ' } else { $null }
        try { [Slide]::Render($p.FullName, $dest, $W, $H, $blur, $cap); $frames.Add(('{0:D4}.jpg' -f $i)) }
        catch { Write-Host ''; Write-Host "  [!] Skipped $($p.Name) (could not read it)" -ForegroundColor Yellow }
    }
    Write-Host ''
    if ($frames.Count -lt 2) { Write-Host '  Not enough readable photos.' -ForegroundColor Red; return }

    # ----------------------------- build video ----------------------------
    $T = 0.8                                    # fade length in seconds
    $N = $frames.Count
    $useFade = $fade -and $N -le 400            # very long slideshows: straight cuts keep FFmpeg fast
    $total = if ($useFade) { $N * $dur + $T } else { $N * $dur }

    $outName = (Split-Path $folder -Leaf) + ' - Slideshow'
    $out = Join-Path $folder "$outName.mp4"; $k = 2
    while (Test-Path -LiteralPath $out) { $out = Join-Path $folder "$outName ($k).mp4"; $k++ }

    $fa = New-Object System.Collections.Generic.List[string]
    $fa.AddRange([string[]]@('-hide_banner', '-loglevel', 'error', '-stats', '-y'))
    $fps = 30

    if ($useFade) {
        foreach ($f in $frames) { $fa.AddRange([string[]]@('-loop', '1', '-framerate', "$fps", '-t', (Num ($dur + $T)), '-i', $f)) }
        $sb = New-Object Text.StringBuilder
        for ($j = 0; $j -lt $N; $j++) { [void]$sb.Append("[$($j):v]settb=AVTB,fps=$fps,format=yuv420p[i$j];") }
        $prev = 'i0'
        for ($j = 1; $j -lt $N; $j++) {
            [void]$sb.Append("[$prev][i$j]xfade=transition=fade:duration=$(Num $T):offset=$(Num ($j * $dur))[x$j];")
            $prev = "x$j"
        }
        [void]$sb.Append("[$prev]fade=t=in:st=0:d=0.6,fade=t=out:st=$(Num ($total - 0.8)):d=0.8[v]")
    } else {
        $list = Join-Path $tmpDir 'list.txt'
        $lines = foreach ($f in $frames) { "file '$f'"; "duration $(Num $dur)" }
        $lines += "file '$($frames[-1])'"
        [IO.File]::WriteAllLines($list, [string[]]$lines)
        $fa.AddRange([string[]]@('-f', 'concat', '-safe', '0', '-i', 'list.txt'))
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append("[0:v]fps=$fps,format=yuv420p,fade=t=in:st=0:d=0.6,fade=t=out:st=$(Num ($total - 0.8)):d=0.8[v]")
    }
    $script = Join-Path $tmpDir 'filter.txt'
    [IO.File]::WriteAllText($script, $sb.ToString())

    $audioIdx = if ($useFade) { $N } else { 1 }
    if ($song) {
        $fa.AddRange([string[]]@('-stream_loop', '-1', '-i', $song))
        [IO.File]::AppendAllText($script, ";[$($audioIdx):a]afade=t=out:st=$(Num ([math]::Max(0, $total - 3))):d=3[a]")
    }
    # FFmpeg 7+ reads a filter file with "-/filter_complex"; older versions use "-filter_complex_script"
    $ver = "$(& $ffmpeg -hide_banner -version | Select-Object -First 1)"
    $filterOpt = if ($ver -match 'version n?(\d+)\.' -and [int]$Matches[1] -lt 7) { '-filter_complex_script' } else { '-/filter_complex' }
    $fa.AddRange([string[]]@($filterOpt, 'filter.txt', '-map', '[v]'))
    if ($song) { $fa.AddRange([string[]]@('-map', '[a]', '-c:a', 'aac', '-b:a', '160k')) }
    $fa.AddRange([string[]]@('-c:v', 'libx264', '-preset', 'medium', '-crf', '20', '-r', "$fps",
                             '-t', (Num $total), '-movflags', '+faststart', (Join-Path $tmpDir 'out.mp4')))

    Write-Host ''
    $mins = [math]::Floor($total / 60); $secs = [math]::Round($total % 60)
    Write-Host "  Making a $($mins)m $($secs)s video from $N photo(s) - please wait ..."
    Push-Location -LiteralPath $tmpDir              # short file names keep the FFmpeg command small
    $ErrorActionPreference = 'Continue'
    & $ffmpeg @fa | Out-Host
    $ok = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    Pop-Location
    Write-Host ''

    if (-not $ok -or -not (Test-Path -LiteralPath (Join-Path $tmpDir 'out.mp4'))) {
        Write-Host '  [!] The video could not be made.' -ForegroundColor Red
        return
    }
    Move-Item -LiteralPath (Join-Path $tmpDir 'out.mp4') -Destination $out
    $size = (Get-Item -LiteralPath $out).Length / 1MB
    Write-Host ("  Done. Saved: {0}  ({1:N1} MB)" -f (Split-Path $out -Leaf), $size) -ForegroundColor Cyan
}
finally {
    Set-Location -LiteralPath $env:TEMP
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
