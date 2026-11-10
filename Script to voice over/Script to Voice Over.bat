<# : batch launcher - do not edit these lines
@echo off
setlocal
set "TARGET=%~dp0"
start "" powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText('%~f0'))"
exit /b
#>

# ---------------------------------------------------------------------------
#  Voice Over Studio  (Script to Voice Over)
#  Double-click this .bat. Type, paste or open a script (.txt, .docx, .md)
#  and it records it with a Microsoft neural voice - "Ryan" (British English)
#  by default, or any of 300+ voices in 140+ languages and accents.
#  Saves a studio-levelled MP3 / WAV plus matching subtitles (.srt).
#
#  Writing the script:
#    - Leave a blank line between paragraphs (gives a longer pause).
#    - [pause] adds a 1 second silence, [pause 2.5] adds 2.5 seconds.
#    - Anything else in [square brackets] is a note and is NOT read aloud,
#      e.g. [MUSIC IN] or [Show the product here].
#    - "NARRATOR:" / "VO:" at the start of a line is not read aloud.
#  Shortcuts: F5 = preview, Ctrl+Enter = create, Space (outside the editor) = play.
#  Needs an internet connection (the voice is made by Microsoft's service).
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern uint GetLongPathName(string s, System.Text.StringBuilder b, uint n);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
'@
[void][Win32.Native]::ShowWindow([Win32.Native]::GetConsoleWindow(), 0)
[void][Win32.Native]::SetCurrentProcessExplicitAppUserModelID('Arbab.VoiceOverStudio')

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;

// Builds the voice track as raw 24 kHz 16-bit mono PCM
public class VoTrack : IDisposable
{
    public const int Rate = 24000;
    FileStream fs;
    long n;

    public VoTrack(string path) { fs = new FileStream(path, FileMode.Create, FileAccess.Write); }
    public double Position { get { return n / (double)Rate; } }

    public void Silence(double sec)
    {
        int c = (int)Math.Round(Math.Max(0, sec) * Rate);
        if (c == 0) return;
        var z = new byte[c * 2];
        fs.Write(z, 0, z.Length);
        n += c;
    }

    static int Amp(byte[] d, int i) { return Math.Abs((int)(short)(d[2 * i] | (d[2 * i + 1] << 8))); }

    static void Scale(byte[] d, int i, double g)
    {
        short s = (short)((short)(d[2 * i] | (d[2 * i + 1] << 8)) * g);
        d[2 * i] = (byte)s; d[2 * i + 1] = (byte)(s >> 8);
    }

    // Appends a clip without its quiet head and tail, so pauses are exact. Returns the seconds cut from the start.
    public double Clip(string raw)
    {
        byte[] d = File.ReadAllBytes(raw);
        int c = d.Length / 2, thr = 180;               // about -45 dB
        int a = 0; while (a < c && Amp(d, a) < thr) a++;
        if (a >= c) return 0;
        int b = c - 1; while (b > a && Amp(d, b) < thr) b--;
        a = Math.Max(0, a - Rate / 20);                // keep 50 ms before the first sound
        b = Math.Min(c - 1, b + Rate / 8);             // and 125 ms after the last (breath release)
        int len = b - a + 1;
        int f = Math.Min(Rate / 200, len / 2);         // 5 ms fades so joins never click
        for (int i = 0; i < f; i++) { Scale(d, a + i, i / (double)f); Scale(d, b - i, i / (double)f); }
        fs.Write(d, a * 2, len * 2);
        n += len;
        return a / (double)Rate;
    }

    // Loudest level in each of n slices of a raw track, scaled 0..1 - used to draw the waveform
    public static float[] Peaks(string raw, int n)
    {
        var p = new float[n];
        long total = new FileInfo(raw).Length / 2, idx = 0;
        if (total == 0) return p;
        using (var f = File.OpenRead(raw))
        {
            var buf = new byte[65536];
            int r;
            while ((r = f.Read(buf, 0, buf.Length)) > 0)
                for (int i = 0; i + 1 < r; i += 2, idx++)
                {
                    int s = (int)(idx * n / total); if (s >= n) s = n - 1;
                    float v = Math.Abs((int)(short)(buf[i] | (buf[i + 1] << 8))) / 32768f;
                    if (v > p[s]) p[s] = v;
                }
        }
        float m = 0; foreach (var v in p) if (v > m) m = v;
        if (m > 0) for (int i = 0; i < n; i++) p[i] /= m;
        return p;
    }

    public void Dispose() { if (fs != null) fs.Dispose(); fs = null; }
}

// Turns word timings into readable subtitle cues (max 2 lines of 42 characters)
public class VoSubs
{
    class Cue { public double A, B; public string T; }
    List<Cue> cues = new List<Cue>();
    Cue cur;

    public int Count { get { return cues.Count + (cur != null ? 1 : 0); } }

    void Flush() { if (cur != null) cues.Add(cur); cur = null; }

    // Chinese / Japanese characters: no spaces between words and each one takes about two columns on screen
    static bool Cjk(char c) { return (c >= 0x3040 && c <= 0x30FF) || (c >= 0x3400 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF); }
    static int Width(string s) { int n = 0; foreach (char c in s) n += Cjk(c) ? 2 : 1; return n; }
    const string SentenceEnd = ".!?\u2026\u3002\uFF01\uFF1F\u06D4\u0964\u061F";
    const string ClauseEnd = ",;:\u2014\uFF0C\u3001\uFF1B\u060C";

    public void Add(string text, double t0, double clipEnd, double[] o, double[] d, string[] w)
    {
        if (w.Length == 0)
        {
            Flush();
            cues.Add(new Cue { A = t0, B = clipEnd, T = text.Trim() });
            return;
        }
        int pos = 0;
        for (int i = 0; i < w.Length; i++)
        {
            bool spaced = pos < text.Length && char.IsWhiteSpace(text[pos]);
            int idx = w[i].Length == 0 ? -1 : text.IndexOf(w[i], pos, StringComparison.OrdinalIgnoreCase);
            if (idx - pos > 30) idx = -1;
            int end = idx < 0 ? pos : idx + w[i].Length;
            if (idx < 0) while (end < text.Length && char.IsWhiteSpace(text[end])) end++;
            while (end < text.Length && !char.IsWhiteSpace(text[end]) && !Cjk(text[end])) end++;
            if (i == w.Length - 1) end = text.Length;
            string tok = text.Substring(pos, end - pos).Trim();
            pos = end;
            if (tok.Length == 0) continue;

            double a = t0 + o[i], b = a + d[i];
            if (cur != null && (Width(cur.T) + 1 + Width(tok) > 84 || b - cur.A > 6.0)) Flush();
            if (cur == null) cur = new Cue { A = a, B = b, T = tok };
            else { cur.T += (spaced ? " " : "") + tok; cur.B = b; }

            string bare = tok.TrimEnd('"', '\'', ')', ']', '\u201D', '\u2019', '\u300D', '\u300F');
            char last = bare.Length > 0 ? bare[bare.Length - 1] : ' ';
            if (SentenceEnd.IndexOf(last) >= 0) Flush();
            else if (ClauseEnd.IndexOf(last) >= 0 && Width(cur.T) > 50) Flush();
        }
        Flush();
    }

    static string Time(double s)
    {
        long ms = (long)Math.Round(Math.Max(0, s) * 1000);
        return string.Format("{0:00}:{1:00}:{2:00},{3:000}", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000);
    }

    static string Wrap(string t)
    {
        if (Width(t) <= 42) return t;
        int mid = t.Length / 2, best = -1;
        for (int i = 0; i < t.Length; i++)
            if (t[i] == ' ' && (best < 0 || Math.Abs(i - mid) < Math.Abs(best - mid))) best = i;
        if (best < 0) return t.Substring(0, mid) + "\r\n" + t.Substring(mid);          // no spaces (Chinese / Japanese)
        return t.Substring(0, best) + "\r\n" + t.Substring(best + 1);
    }

    public string ToSrt()
    {
        Flush();
        var sb = new StringBuilder();
        for (int i = 0; i < cues.Count; i++)
        {
            var c = cues[i];
            double b = Math.Max(c.B + 0.3, c.A + 1.0);                // linger a moment, show at least 1 s
            if (i + 1 < cues.Count) b = Math.Min(b, cues[i + 1].A - 0.04);
            if (b <= c.A) b = c.A + 0.3;
            sb.Append(i + 1).Append("\r\n").Append(Time(c.A)).Append(" --> ").Append(Time(b)).Append("\r\n")
              .Append(Wrap(c.T)).Append("\r\n\r\n");
        }
        return sb.ToString();
    }
}
'@

# Records each line with edge-tts (several at once) and decodes it to raw PCM for the track builder
$helperCode = @'
import asyncio, json, os, subprocess, sys
import edge_tts

def say(*a):
    print(*a, flush=True)

def clean(e):
    return (type(e).__name__ + ': ' + str(e)).encode('ascii', 'replace').decode()[:300]

async def one(job, item, sem):
    base = os.path.join(job['dir'], item['id'])
    async with sem:
        err = None
        for attempt in range(5):
            try:
                c = edge_tts.Communicate(item['text'], job['voice'], rate=job['rate'], pitch=job['pitch'],
                                         boundary='WordBoundary')
                audio, words = bytearray(), []
                async for ch in c.stream():
                    if ch['type'] == 'audio':
                        audio += ch['data']
                    elif ch['type'] == 'WordBoundary':
                        words.append({'o': ch['offset'] / 1e7, 'd': ch['duration'] / 1e7, 't': ch['text']})
                if not audio:
                    raise RuntimeError('no audio received')
                break
            except Exception as e:
                err = e
                await asyncio.sleep(1.5 * (attempt + 1))
        else:
            say('FAIL', item['id'], clean(err))
            return False
    with open(base + '.mp3', 'wb') as f:
        f.write(audio)
    r = await asyncio.to_thread(subprocess.run, [job['ffmpeg'], '-v', 'error', '-y', '-i', base + '.mp3',
                                '-f', 's16le', '-ac', '1', '-ar', '24000', base + '.raw'],
                                capture_output=True, creationflags=0x08000000)
    if r.returncode != 0:
        say('FAIL', item['id'], 'could not decode the audio')
        return False
    with open(base + '.json', 'w', encoding='utf-8') as f:
        json.dump(words, f)
    say('DONE', item['id'])
    return True

async def main():
    with open(sys.argv[1], encoding='utf-8-sig') as f:
        job = json.load(f)
    sem = asyncio.Semaphore(4)
    results = await asyncio.gather(*(one(job, it, sem) for it in job['items']))
    sys.exit(0 if all(results) else 1)

asyncio.run(main())
'@

# Saves Microsoft's current list of voices
$voicesCode = @'
import asyncio, edge_tts, json, os, sys
v = asyncio.run(edge_tts.list_voices())
keep = [{'s': x['ShortName'], 'g': x.get('Gender', ''), 'l': x.get('Locale', ''), 'n': x.get('LocaleName') or x.get('Locale', ''),
         'p': ', '.join((x.get('VoiceTag') or {}).get('VoicePersonalities') or [])} for x in v]
if len(keep) > 20:
    tmp = sys.argv[1] + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(keep, f, ensure_ascii=False)
    os.replace(tmp, sys.argv[1])
'@

# ------------------------------------------------------------------------------
#  Engine - runs on a background thread so the window never freezes.
#  It talks to the window only through the shared $sync table.
# ------------------------------------------------------------------------------
$engine = @'
function Find-Ffmpeg {
    $c = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $paths = @("$env:LOCALAPPDATA\Microsoft\WinGet\Packages\*FFmpeg*\*\bin\ffmpeg.exe",
               "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe", 'C:\ffmpeg\bin\ffmpeg.exe', 'D:\KDENLIVE\bin\ffmpeg.exe')
    $f = Get-ChildItem $paths -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

function Find-Python {
    $cands = @(foreach ($n in 'py', 'python', 'python3') { Get-Command "$n.exe" -ErrorAction SilentlyContinue | ForEach-Object Source })
    $cands += @(Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $ErrorActionPreference = 'Continue'
    foreach ($c in $cands) {
        $v = "$(& $c -c 'import sys; print(sys.version_info[0] * 100 + sys.version_info[1])' 2>$null)".Trim()
        if ($v -match '^\d+$' -and [int]$v -ge 308) { return $c }
    }
    return $null
}

function Test-Engine { $ErrorActionPreference = 'Continue'; & $py -c 'import edge_tts' 2>$null; return $LASTEXITCODE -eq 0 }

function Install-Engine {
    $sync.Status = 'Installing the voice engine (edge-tts) ...'
    $ErrorActionPreference = 'Continue'
    & $py -m pip install --user --upgrade --disable-pip-version-check edge-tts 2>$null | Out-Null
}

# Runs FFmpeg in the work folder and returns its exit code and messages
function Run-Ffmpeg([string[]]$a) {
    $psi = New-Object Diagnostics.ProcessStartInfo $ffmpeg
    $psi.Arguments = ($a | ForEach-Object { if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $tmpDir
    $p = [Diagnostics.Process]::Start($psi)
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Err = $err }
}

function Read-TextFile([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $t = [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
    elseif ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { $t = [Text.Encoding]::BigEndianUnicode.GetString($b, 2, $b.Length - 2) }
    else {
        try { $t = (New-Object Text.UTF8Encoding($false, $true)).GetString($b) }
        catch { $t = [Text.Encoding]::Default.GetString($b) }      # older Notepad (ANSI) files
    }
    return @($t.TrimStart([char]0xFEFF) -split "`r?`n")
}

function Read-Docx([string]$path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $sr = New-Object IO.StreamReader($zip.GetEntry('word/document.xml').Open())
        $xml = [xml]$sr.ReadToEnd()
        $sr.Close()
    } finally { $zip.Dispose() }
    $ns = New-Object Xml.XmlNamespaceManager $xml.NameTable
    $ns.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($p in $xml.SelectNodes('//w:body//w:p[not(.//w:p)]', $ns)) {
        $sb = New-Object Text.StringBuilder
        foreach ($n in $p.SelectNodes('.//w:t|.//w:tab|.//w:br|.//w:cr', $ns)) {
            switch ($n.LocalName) { 't' { [void]$sb.Append($n.InnerText) } 'tab' { [void]$sb.Append(' ') } default { [void]$sb.Append("`n") } }
        }
        foreach ($l in ($sb.ToString() -split "`n")) { $out.Add($l) }
        $out.Add('')                                           # every Word paragraph is its own paragraph
    }
    return $out.ToArray()
}

function Convert-Markdown([string[]]$lines) {
    foreach ($t in $lines) {
        $t = $t -replace '^\s{0,3}#{1,6}\s+', '' -replace '^\s*>\s?', '' -replace '^\s*([-*+]|\d+[.)])\s+', ''
        $t = $t -replace '!\[[^\]]*\]\([^)]*\)', '' -replace '\[([^\]]+)\]\([^)]*\)', '$1'
        $t -replace '(\*\*|__|`)', '' -replace '(?<!\w)[*_](\S[^*_]*?)[*_](?!\w)', '$1'
    }
}

# Each line is cached by its text, so editing a script only re-records the lines that changed
function Key([string]$t) {
    $h = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($t))
    's' + (-join ($h[0..9] | ForEach-Object { $_.ToString('x2') }))
}

# Turns the script into a list of things to say and pauses between them
function Parse-Script([string[]]$lines) {
    $events = New-Object System.Collections.Generic.List[object]
    $para = New-Object System.Collections.Generic.List[string]

    function Add-Speech([string]$t) {
        $t = ($t -replace '\s+', ' ').Trim()
        if ($t -notmatch '[\p{L}\p{N}]') { return }
        # very long paragraphs are recorded in pieces, split at sentence ends
        $pieces = New-Object System.Collections.Generic.List[string]
        while ($t.Length -gt 1500) {
            $cut = $t.LastIndexOfAny([char[]](".!?" + [char]0x3002 + [char]0xFF01 + [char]0xFF1F + [char]0x06D4 + [char]0x0964 + [char]0x061F), 1500)
            if ($cut -lt 300) { $cut = $t.LastIndexOf(' ', 1500) }
            if ($cut -lt 1) { $cut = 1500 }
            $pieces.Add($t.Substring(0, $cut + 1).Trim()); $t = $t.Substring($cut + 1).Trim()
        }
        if ($t) { $pieces.Add($t) }
        for ($k = 0; $k -lt $pieces.Count; $k++) {
            if ($k -gt 0) { $events.Add([pscustomobject]@{ Gap = 'sentence' }) }
            $events.Add([pscustomobject]@{ Key = (Key $pieces[$k]); Text = $pieces[$k] })
        }
    }

    function Add-Line([string]$l) {
        $buf = ''
        foreach ($part in [regex]::Split($l, '(\[[^\]]*\])')) {
            if ($part -match '^\[(.*)\]$') {
                $m = [regex]::Match($Matches[1], '^\s*(pause|break|beat|silence)\s*(\d+([.,]\d+)?)?\s*(s|sec|secs|seconds?)?\s*$', 'IgnoreCase')
                if ($m.Success) {
                    Add-Speech $buf; $buf = ''
                    $sec = if ($m.Groups[2].Success) { [double]::Parse($m.Groups[2].Value.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture) } else { 1.0 }
                    $events.Add([pscustomobject]@{ Gap = 'explicit'; Seconds = [math]::Min($sec, 30) })
                } else { $buf += ' ' }                          # a note / direction - not read aloud
            } else { $buf += $part }
        }
        Add-Speech $buf
    }

    function End-Paragraph {
        foreach ($l in $para) { Add-Line $l; $events.Add([pscustomobject]@{ Gap = 'line' }) }
        if ($para.Count) { $events.Add([pscustomobject]@{ Gap = 'para' }) }
        $para.Clear()
    }

    foreach ($raw in $lines) {
        $t = $raw.Trim() -replace '^(narrator|voice ?over|v\.?o\.?)\s*:\s*', ''
        if ($t -eq '' -or $t -match '^([-*_=]\s*){3,}$') { End-Paragraph; continue }
        # join lines that were hard-wrapped in the middle of a sentence
        if ($para.Count -and $para[$para.Count - 1] -notmatch '[.!?:;"\)\]\u2026\u201D\u2019]$' -and $t -cmatch '^\p{Ll}') {
            $para[$para.Count - 1] += ' ' + $t
        } else { $para.Add($t) }
    }
    End-Paragraph
    return $events.ToArray()
}

function Seg-Dir($s) {
    $d = Join-Path $tmpDir ("$($s.Voice)_r$($s.Rate)_p$($s.Pitch)")
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    return $d
}

function Signed([int]$v) { if ($v -ge 0) { "+$v" } else { "$v" } }

# Records every line that is not recorded yet with these speed / tone settings
function Record-Lines($events, $s) {
    $dir = Seg-Dir $s
    $todo = @($events | Where-Object { $_.Key -and -not (Test-Path -LiteralPath (Join-Path $dir "$($_.Key).json")) } |
              Group-Object Key | ForEach-Object { $_.Group[0] })
    $sync.Total = $todo.Count; $sync.Done = 0
    if (-not $todo) { return }
    $job = @{ voice = $s.Voice; rate = "$(Signed $s.Rate)%"; pitch = "$(Signed $s.Pitch)Hz"; ffmpeg = $ffmpeg; dir = $dir
              items = [object[]]@($todo | ForEach-Object { @{ id = $_.Key; text = $_.Text } }) }
    $jobPath = Join-Path $tmpDir 'job.json'
    [IO.File]::WriteAllText($jobPath, (ConvertTo-Json -InputObject $job -Depth 4), (New-Object Text.UTF8Encoding($false)))

    $sync.Status = 'Recording voice'
    $psi = New-Object Diagnostics.ProcessStartInfo $py
    $psi.Arguments = "`"$helperPath`" `"$jobPath`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $p = [Diagnostics.Process]::Start($psi)
    $sync.Proc = $p
    $errTask = $p.StandardError.ReadToEndAsync()
    $fail = $null
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        if ($line -like 'DONE *') { $sync.Done++ }
        elseif ($line -like 'FAIL *' -and -not $fail) { $fail = ($line -replace '^FAIL \S+ ', '') }
    }
    $p.WaitForExit()
    $sync.Proc = $null
    if ($sync.Cancel) { throw 'Cancelled.' }
    if ($p.ExitCode -ne 0 -or $fail) {
        if (-not $fail) { $fail = (($errTask.Result.Trim() -split "`n") | Select-Object -Last 2) -join ' ' }
        $sync.ErrorKind = 'record'
        throw "Some lines could not be recorded. Please check your internet connection and try again.`n`nDetails: $fail"
    }
}

# Joins the recorded lines with exact pauses into voice.raw and builds the subtitles
function Build-Track($events, $s) {
    $gapFor = switch ($s.Pace) {
        'tight'   { @{ sentence = 0.20; line = 0.25; para = 0.60 } }
        'relaxed' { @{ sentence = 0.35; line = 0.55; para = 1.40 } }
        default   { @{ sentence = 0.30; line = 0.40; para = 0.90 } }
    }
    $dir = Seg-Dir $s
    $subs = New-Object VoSubs
    $track = New-Object VoTrack (Join-Path $tmpDir 'voice.raw')
    try {
        $track.Silence(0.4)
        $pending = 0.0
        foreach ($e in $events) {
            if ($e.Gap) {
                $g = if ($e.Gap -eq 'explicit') { $e.Seconds } else { $gapFor[$e.Gap] }
                $pending = [math]::Max($pending, $g)
                continue
            }
            $track.Silence($pending); $pending = 0.0
            $start = $track.Position
            $lead = $track.Clip((Join-Path $dir "$($e.Key).raw"))
            $words = @(Get-Content -LiteralPath (Join-Path $dir "$($e.Key).json") -Raw -Encoding UTF8 | ConvertFrom-Json)
            $subs.Add($e.Text, $start - $lead, $track.Position, [double[]]@($words | ForEach-Object { $_.o }),
                      [double[]]@($words | ForEach-Object { $_.d }), [string[]]@($words | ForEach-Object { $_.t }))
        }
        $track.Silence([math]::Max(1.0, $pending))
        return [pscustomobject]@{ Duration = $track.Position; Srt = $subs.ToSrt() }
    } finally { $track.Dispose() }
}

# Cleans up the low end, sets broadcast-standard loudness (two-pass) and writes a 48 kHz WAV
function Master-Track($s, [string]$outName, [int]$bits) {
    $in = @('-hide_banner', '-nostats', '-y', '-f', 's16le', '-ar', '24000', '-ac', '1', '-i', 'voice.raw')
    $af = 'highpass=f=70'
    if ($s.Lufs) {
        $ln = "loudnorm=I=$($s.Lufs):TP=-1.5:LRA=20"
        $r = Run-Ffmpeg ($in + @('-af', "$af,$ln`:print_format=json", '-f', 'null', 'NUL'))
        $m = [regex]::Match($r.Err, '(?s)\{\s*"input_i".*?\}')
        $j = if ($m.Success) { $m.Value | ConvertFrom-Json } else { $null }
        if ($j -and "$($j.input_i)" -notmatch 'inf') {
            $af += ",$ln`:measured_I=$($j.input_i):measured_TP=$($j.input_tp):measured_LRA=$($j.input_lra):measured_thresh=$($j.input_thresh):offset=$($j.target_offset):linear=true"
        } else { $af += ",$ln" }
    }
    $af += ',aresample=48000'
    $codec = if ($bits -eq 24) { 'pcm_s24le' } else { 'pcm_s16le' }
    $r = Run-Ffmpeg ($in + @('-af', $af, '-ac', '1', '-c:a', $codec, $outName))
    if ($r.Code -ne 0) { throw "FFmpeg could not process the audio.`n`n$((($r.Err.Trim() -split "`n") | Select-Object -Last 3) -join "`n")" }
}

function Check-Tools([bool]$install, [bool]$upgrade) {
    $sync.Status = 'Checking voice engine ...'
    $global:ffmpeg = Find-Ffmpeg
    if (-not $ffmpeg -and $install) {
        $sync.Status = 'Installing FFmpeg ...'
        & winget install --id Gyan.FFmpeg -e --accept-source-agreements --accept-package-agreements --disable-interactivity 2>$null | Out-Null
        $global:ffmpeg = Find-Ffmpeg
    }
    $global:py = Find-Python
    if (-not $py -and $install) {
        $sync.Status = 'Installing Python ...'
        & winget install --id Python.Python.3.12 -e --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity 2>$null | Out-Null
        $global:py = Find-Python
    }
    $ok = $false
    if ($py) {
        $ok = Test-Engine
        if (($install -and -not $ok) -or $upgrade) { Install-Engine; $ok = Test-Engine }
    }
    if ($ok) {                                  # refresh the list of voices (kept for offline use)
        $sync.Status = 'Loading voices ...'
        $ErrorActionPreference = 'Continue'
        & $py $voicesHelper $voicesPath 2>$null | Out-Null
        $ErrorActionPreference = 'Stop'
    }
    $missing = @()
    if (-not $ffmpeg) { $missing += 'FFmpeg' }
    if (-not $py) { $missing += 'Python' } elseif (-not $ok) { $missing += 'edge-tts' }
    $sync.Result = [pscustomobject]@{ Ready = ($missing.Count -eq 0); Missing = $missing }
}

function Render($r) {
    $s = $r.Settings
    $events = @(Parse-Script $r.Lines)
    if ($r.Kind -eq 'preview') {
        $limit = if ($r.Limit) { $r.Limit } elseif ($r.Selection) { 900 } else { 260 }
        $pv = New-Object System.Collections.Generic.List[object]; $chars = 0
        foreach ($e in $events) {
            if ($e.Key) { if ($chars -ge $limit) { break }; $chars += $e.Text.Length }
            $pv.Add($e)
        }
        $events = $pv.ToArray()
    }
    if (-not @($events | Where-Object { $_.Key })) { throw 'There is nothing to read aloud yet. Type, paste or open a script first.' }

    Record-Lines $events $s
    $sync.Total = 0
    $sync.Status = 'Joining lines and levelling the sound ...'
    $t = Build-Track $events $s
    $peaks = [VoTrack]::Peaks((Join-Path $tmpDir 'voice.raw'), 1600)
    if ($sync.Cancel) { throw 'Cancelled.' }

    if ($r.Kind -eq 'preview') {
        $global:previewNo++
        $name = "preview$previewNo.wav"
        Master-Track $s $name 16
        $sync.Result = [pscustomobject]@{ Play = (Join-Path $tmpDir $name); Peaks = $peaks; Duration = $t.Duration; Files = @() }
        return
    }

    Master-Track $s 'master.wav' 24
    $sync.Status = 'Saving files ...'
    $exts = @(); if ($s.Mp3) { $exts += '.mp3' }; if ($s.Wav) { $exts += '.wav' }; if ($s.Srt) { $exts += '.srt' }
    $name = $r.Name; $k = 2
    while (@($exts | Where-Object { Test-Path -LiteralPath (Join-Path $r.OutDir "$name$_") }).Count) { $name = "$($r.Name) ($k)"; $k++ }
    $saved = New-Object System.Collections.Generic.List[string]
    if ($s.Mp3) {
        $x = Run-Ffmpeg @('-hide_banner', '-nostats', '-y', '-i', 'master.wav', '-c:a', 'libmp3lame', '-b:a', '192k', '-ar', '44100',
                          '-id3v2_version', '3', '-metadata', "title=$($r.Name)", '-metadata', "comment=Voice: $($s.VoiceLabel)", 'out.mp3')
        if ($x.Code -ne 0) { throw 'The MP3 file could not be made.' }
        Move-Item -LiteralPath (Join-Path $tmpDir 'out.mp3') -Destination (Join-Path $r.OutDir "$name.mp3")
        $saved.Add((Join-Path $r.OutDir "$name.mp3"))
    }
    if ($s.Wav) {
        Move-Item -LiteralPath (Join-Path $tmpDir 'master.wav') -Destination (Join-Path $r.OutDir "$name.wav")
        $saved.Add((Join-Path $r.OutDir "$name.wav"))
    }
    if ($s.Srt) {
        [IO.File]::WriteAllText((Join-Path $r.OutDir "$name.srt"), $t.Srt, (New-Object Text.UTF8Encoding($true)))
        $saved.Add((Join-Path $r.OutDir "$name.srt"))
    }
    $sync.Result = [pscustomobject]@{ Play = $saved[0]; Peaks = $peaks; Duration = $t.Duration; Files = $saved.ToArray() }
}

function Invoke-Work($r) {
    $ErrorActionPreference = 'Stop'
    try {
        switch ($r.Kind) {
            'setup'   { Check-Tools $false $false }
            'install' { Check-Tools $true $false }
            'update'  { Check-Tools $true $true }
            default   { Render $r }
        }
    } catch { $sync.Error = $_.Exception.Message }
}
'@

# ------------------------------------------------------------------------------
#  Window
# ------------------------------------------------------------------------------
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Voice Over Studio" Width="1180" Height="780" MinWidth="980" MinHeight="660"
        WindowStartupLocation="CenterScreen" Background="#0D0F13" Foreground="#E8EAEF"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe MDL2 Assets</FontFamily>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#161921"/>
      <Setter Property="BorderBrush" Value="#242833"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#5C6475"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="Field" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#C5CAD3"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="Tiny" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="#5C6475"/>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#E8EAEF"/>
      <Setter Property="Background" Value="#1E222C"/>
      <Setter Property="BorderBrush" Value="#2C3140"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9"/>
              <Border x:Name="hl" Background="White" Opacity="0" CornerRadius="9"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="hl" Property="Opacity" Value="0.06"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="hl" Property="Opacity" Value="0.12"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background">
        <Setter.Value>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#5B7CFA" Offset="0"/><GradientStop Color="#7B6BFA" Offset="1"/>
          </LinearGradientBrush>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Small" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Padding" Value="11,6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="#8FA4FF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <ContentPresenter x:Name="c"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#B9C6FF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Round" TargetType="Button">
      <Setter Property="Width" Value="52"/>
      <Setter Property="Height" Value="52"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Ellipse>
                <Ellipse.Fill>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#5B7CFA" Offset="0"/><GradientStop Color="#7B6BFA" Offset="1"/>
                  </LinearGradientBrush>
                </Ellipse.Fill>
              </Ellipse>
              <Ellipse x:Name="hl" Fill="White" Opacity="0"/>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="hl" Property="Opacity" Value="0.1"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.3"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#AEB4C0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="7" Background="Transparent" Padding="0,7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#252A35"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#5B7CFA"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SegBox" TargetType="Border">
      <Setter Property="Background" Value="#1C2029"/>
      <Setter Property="BorderBrush" Value="#262B36"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="9"/>
      <Setter Property="Padding" Value="3"/>
    </Style>

    <Style x:Key="Chip" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#AEB4C0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="b" CornerRadius="8" BorderThickness="1" BorderBrush="#2C3140" Background="#1C2029" Padding="11,7">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="g" Text="&#xE73E;" FontFamily="{StaticResource Icons}" FontSize="11" Margin="0,1,7,0"
                           Foreground="#8FA4FF" Visibility="Collapsed" VerticalAlignment="Center"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#3A4152"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="#5B7CFA"/>
                <Setter TargetName="b" Property="Background" Value="#1D2545"/>
                <Setter TargetName="g" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TrackPart" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Grid Background="Transparent"><Border Height="4" CornerRadius="2" Background="#2A2F3B"/></Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Slider">
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="IsSnapToTickEnabled" Value="True"/>
      <Setter Property="TickFrequency" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Height="24">
              <Border Width="2" Height="12" Background="#3A4152" HorizontalAlignment="Center" CornerRadius="1"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton><RepeatButton Command="Slider.DecreaseLarge" Style="{StaticResource TrackPart}"/></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Command="Slider.IncreaseLarge" Style="{StaticResource TrackPart}"/></Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Grid Width="18" Height="18">
                          <Ellipse Fill="#5B7CFA" Opacity="0.25" Width="18" Height="18"/>
                          <Ellipse Fill="White" Stroke="#5B7CFA" StrokeThickness="3" Width="14" Height="14"/>
                        </Grid>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Editor" TargetType="TextBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#E8EAEF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="20,16"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="AcceptsReturn" Value="True"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="SelectionBrush" Value="#5B7CFA"/>
      <Setter Property="AllowDrop" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <ScrollViewer x:Name="PART_ContentHost" Padding="{TemplateBinding Padding}" Background="{TemplateBinding Background}"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Foreground" Value="#E8EAEF"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="SelectionBrush" Value="#5B7CFA"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="b" Background="#1C2029" BorderBrush="#262B36" BorderThickness="1" CornerRadius="8" Padding="8,7">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#5B7CFA"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border CornerRadius="3" Background="#353B48" Margin="3,2"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" CornerRadius="2" Background="#232834"/>
              <Border x:Name="PART_Indicator" CornerRadius="2" HorizontalAlignment="Left" Background="#5B7CFA"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Foreground" Value="#E8EAEF"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="#252A34" BorderBrush="#343A47" BorderThickness="1" CornerRadius="6" Padding="9,5">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="22,18,22,22">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- header -->
    <Grid Margin="2,0,2,18">
      <StackPanel Orientation="Horizontal">
        <Border Width="44" Height="44" CornerRadius="12">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
              <GradientStop Color="#5B7CFA" Offset="0"/><GradientStop Color="#9B6BFF" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
          <TextBlock Text="&#xE720;" FontFamily="{StaticResource Icons}" FontSize="20" Foreground="White"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="Voice Over Studio" FontSize="20" FontWeight="SemiBold"/>
          <TextBlock x:Name="HeaderSub" Text="Microsoft neural voices" Foreground="#8A92A3" Margin="0,1,0,0"/>
        </StackPanel>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
        <Button x:Name="InstallBtn" Style="{StaticResource Primary}" Visibility="Collapsed" Margin="0,0,10,0" Content="Set up voice engine"/>
        <Border Background="#161921" BorderBrush="#242833" BorderThickness="1" CornerRadius="16" Padding="13,7">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="EngineDot" Width="8" Height="8" Fill="#F5B83D" VerticalAlignment="Center"/>
            <TextBlock x:Name="EngineText" Text="Checking voice engine" Margin="9,0,0,0" Foreground="#C5CAD3"/>
          </StackPanel>
        </Border>
      </StackPanel>
    </Grid>

    <!-- editor + settings -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="18"/>
        <ColumnDefinition Width="340"/>
      </Grid.ColumnDefinitions>

      <Border Style="{StaticResource Card}">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="1"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="1"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Grid Margin="20,12,12,12">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock Text="Script" FontSize="15" FontWeight="SemiBold"/>
              <TextBlock x:Name="FileLabel" Foreground="#6B7385" Margin="10,1,0,0" VerticalAlignment="Center" MaxWidth="320" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="OpenBtn" Style="{StaticResource Small}" ToolTip="Open a .txt, .docx or .md script - or drag a file onto the editor">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8E5;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Open"/></StackPanel>
              </Button>
              <Button x:Name="SaveBtn" Style="{StaticResource Small}" ToolTip="Save the script as a text file">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74E;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Save"/></StackPanel>
              </Button>
              <Button x:Name="PasteBtn" Style="{StaticResource Small}" ToolTip="Replace the script with the clipboard text">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE77F;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Paste"/></StackPanel>
              </Button>
              <Button x:Name="ClearBtn" Style="{StaticResource Small}" ToolTip="Clear the script">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74D;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Clear"/></StackPanel>
              </Button>
            </StackPanel>
          </Grid>
          <Border Grid.Row="1" Background="#242833"/>
          <TextBox x:Name="ScriptBox" Grid.Row="2" Style="{StaticResource Editor}"/>
          <TextBlock x:Name="Placeholder" Grid.Row="2" Margin="22,16,20,0" FontSize="15" Foreground="#4A5162" IsHitTestVisible="False" TextWrapping="Wrap"
                     Text="Type or paste your script here, or drop a .txt, .docx or .md file."/>
          <Border Grid.Row="3" Background="#242833"/>
          <Grid Grid.Row="4" Margin="20,11">
            <TextBlock FontSize="12" Foreground="#5C6475" VerticalAlignment="Center">
              <Run Text="[pause]" FontFamily="Consolas" Foreground="#8FA4FF"/><Run Text="  "/><Run Text="[pause 2]" FontFamily="Consolas" Foreground="#8FA4FF"/><Run Text="  silence     "/>
              <Run Text="[note]" FontFamily="Consolas" Foreground="#8FA4FF"/><Run Text="  not read aloud     "/>
              <Run Text="blank line" Foreground="#8FA4FF"/><Run Text="  new paragraph"/>
            </TextBlock>
            <TextBlock x:Name="Stats" HorizontalAlignment="Right" Foreground="#8A92A3" FontSize="12" VerticalAlignment="Center"/>
          </Grid>
        </Grid>
      </Border>

      <Border Grid.Column="2" Style="{StaticResource Card}">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="22,20,22,20">
            <TextBlock Text="VOICE" Style="{StaticResource Section}"/>
            <Button x:Name="VoiceBtn" Style="{StaticResource Btn}" HorizontalContentAlignment="Stretch" Padding="10,9" Margin="0,0,0,16"
                    Background="#1C2029" ToolTip="Choose a voice and language">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <Border Width="38" Height="38" CornerRadius="19">
                  <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                      <GradientStop Color="#5B7CFA" Offset="0"/><GradientStop Color="#9B6BFF" Offset="1"/>
                    </LinearGradientBrush>
                  </Border.Background>
                  <TextBlock x:Name="VoiceInitial" Foreground="White" FontSize="15" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <StackPanel Grid.Column="1" Margin="12,0,8,0" VerticalAlignment="Center">
                  <TextBlock x:Name="VoiceName" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                  <TextBlock x:Name="VoiceLang" FontSize="12" Foreground="#8A92A3" TextTrimming="CharacterEllipsis" Margin="0,1,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="Change" Foreground="#8FA4FF" FontSize="12"/>
                  <TextBlock Text="&#xE76C;" FontFamily="{StaticResource Icons}" FontSize="10" Foreground="#8FA4FF" Margin="6,2,0,0"/>
                </StackPanel>
              </Grid>
            </Button>

            <Grid><TextBlock Text="Speed" Style="{StaticResource Field}"/><TextBlock x:Name="SpeedVal" HorizontalAlignment="Right" Foreground="#8FA4FF"/></Grid>
            <Slider x:Name="Speed" Minimum="-30" Maximum="30" Value="0" Margin="0,0,0,14" ToolTip="Left = slower, right = faster. Double-click to reset."/>

            <Grid><TextBlock Text="Tone" Style="{StaticResource Field}"/><TextBlock x:Name="ToneVal" HorizontalAlignment="Right" Foreground="#8FA4FF"/></Grid>
            <Slider x:Name="Tone" Minimum="-10" Maximum="10" Value="0" Margin="0,0,0,14" ToolTip="Left = deeper, right = higher. Double-click to reset."/>

            <TextBlock Text="Pauses" Style="{StaticResource Field}"/>
            <Border Style="{StaticResource SegBox}">
              <UniformGrid Rows="1">
                <RadioButton x:Name="PaceShort" GroupName="pace" Content="Short" Style="{StaticResource Seg}"/>
                <RadioButton x:Name="PaceNatural" GroupName="pace" Content="Natural" Style="{StaticResource Seg}"/>
                <RadioButton x:Name="PaceLong" GroupName="pace" Content="Long" Style="{StaticResource Seg}"/>
              </UniformGrid>
            </Border>

            <Border Height="1" Background="#242833" Margin="0,16"/>
            <TextBlock Text="OUTPUT" Style="{StaticResource Section}"/>

            <TextBlock Text="Loudness" Style="{StaticResource Field}"/>
            <Border Style="{StaticResource SegBox}">
              <UniformGrid Rows="1">
                <RadioButton x:Name="Loud16" GroupName="loud" Content="-16 LUFS" Style="{StaticResource Seg}"/>
                <RadioButton x:Name="Loud23" GroupName="loud" Content="-23 LUFS" Style="{StaticResource Seg}"/>
                <RadioButton x:Name="LoudOff" GroupName="loud" Content="Off" Style="{StaticResource Seg}"/>
              </UniformGrid>
            </Border>
            <TextBlock x:Name="LoudHint" Style="{StaticResource Tiny}" Margin="2,6,0,12" TextWrapping="Wrap"/>

            <TextBlock Text="Files" Style="{StaticResource Field}"/>
            <WrapPanel Margin="0,0,0,4">
              <CheckBox x:Name="FileMp3" Content="MP3" Style="{StaticResource Chip}" ToolTip="192 kbps - for uploading and sharing"/>
              <CheckBox x:Name="FileWav" Content="WAV" Style="{StaticResource Chip}" ToolTip="48 kHz 24-bit - best for video editors (Premiere, DaVinci, CapCut)"/>
              <CheckBox x:Name="FileSrt" Content="Subtitles" Style="{StaticResource Chip}" ToolTip=".srt subtitles timed to the voice"/>
            </WrapPanel>

            <TextBlock Text="File name" Style="{StaticResource Field}"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="OutName" Style="{StaticResource Input}"/>
              <Button x:Name="DirBtn" Grid.Column="1" Style="{StaticResource Small}" Margin="8,0,0,0" Padding="10,7" ToolTip="Choose where to save">
                <TextBlock Text="&#xE838;" FontFamily="{StaticResource Icons}" FontSize="14"/>
              </Button>
            </Grid>
            <TextBlock x:Name="OutDirText" Style="{StaticResource Tiny}" Margin="2,6,0,0" TextTrimming="CharacterEllipsis"/>

            <Button x:Name="ResetBtn" Style="{StaticResource Link}" Margin="0,16,0,0" HorizontalAlignment="Left" Content="Reset to recommended settings"/>
          </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>

    <!-- player -->
    <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0,18,0,0" Padding="18,16">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="PlayBtn" Style="{StaticResource Round}" IsEnabled="False" ToolTip="Play / pause (Space)">
          <TextBlock x:Name="PlayIcon" Text="&#xE768;" FontFamily="{StaticResource Icons}" FontSize="18" Margin="2,0,0,0"/>
        </Button>
        <Grid Grid.Column="1" Margin="18,0,22,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="56"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Canvas x:Name="Wave" Background="Transparent" ClipToBounds="True" Cursor="Hand"/>
          <TextBlock x:Name="WaveHint" Text="Preview or create a voice over to hear it here" Foreground="#4A5162"
                     HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False"/>
          <Grid Grid.Row="1" Margin="0,6,0,0">
            <TextBlock x:Name="CurTime" Text="0:00" Foreground="#6B7385" FontSize="12"/>
            <TextBlock x:Name="Status" HorizontalAlignment="Center" Foreground="#AEB4C0" FontSize="12" TextTrimming="CharacterEllipsis" Margin="60,0"/>
            <TextBlock x:Name="TotTime" Text="0:00" HorizontalAlignment="Right" Foreground="#6B7385" FontSize="12"/>
          </Grid>
          <ProgressBar x:Name="Prog" Grid.Row="2" Margin="0,8,0,0" Maximum="1" Visibility="Hidden"/>
        </Grid>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="FolderBtn" Style="{StaticResource Btn}" Visibility="Collapsed" Margin="0,0,10,0" Padding="16,11" ToolTip="Show the saved files">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE838;" FontFamily="{StaticResource Icons}" Margin="0,1,9,0"/><TextBlock Text="Show files"/></StackPanel>
          </Button>
          <Button x:Name="PreviewBtn" Style="{StaticResource Btn}" Margin="0,0,10,0" Padding="18,11" ToolTip="Hear the first lines - or only the text you selected (F5)">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE767;" FontFamily="{StaticResource Icons}" Margin="0,1,9,0"/><TextBlock x:Name="PreviewText" Text="Preview"/></StackPanel>
          </Button>
          <Button x:Name="CreateBtn" Style="{StaticResource Primary}" Padding="24,11" ToolTip="Record the whole script and save the files (Ctrl+Enter)">
            <StackPanel Orientation="Horizontal"><TextBlock x:Name="CreateIcon" Text="&#xE720;" FontFamily="{StaticResource Icons}" Margin="0,1,9,0"/><TextBlock x:Name="CreateText" Text="Create voice over"/></StackPanel>
          </Button>
        </StackPanel>
      </Grid>
    </Border>

    <!-- voice picker -->
    <Grid x:Name="Overlay" Grid.RowSpan="3" Margin="-22,-18,-22,-22" Background="#B8050608" Visibility="Collapsed">
      <Border Style="{StaticResource Card}" Background="#14171E" Width="660" MaxHeight="640" Margin="20" VerticalAlignment="Center" HorizontalAlignment="Center">
        <Border.Effect><DropShadowEffect BlurRadius="40" ShadowDepth="8" Opacity="0.5" Color="Black"/></Border.Effect>
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="1"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Grid Margin="24,20,16,6">
            <StackPanel>
              <TextBlock Text="Choose a voice" FontSize="18" FontWeight="SemiBold"/>
              <TextBlock x:Name="VoiceCount" Foreground="#8A92A3" Margin="0,3,0,0"/>
            </StackPanel>
            <Button x:Name="CloseBtn" Style="{StaticResource Btn}" Background="Transparent" BorderThickness="0" Padding="10"
                    HorizontalAlignment="Right" VerticalAlignment="Top" ToolTip="Close (Esc)">
              <TextBlock Text="&#xE711;" FontFamily="{StaticResource Icons}" FontSize="12"/>
            </Button>
          </Grid>
          <Grid Grid.Row="1" Margin="24,12,24,12">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Grid>
              <TextBox x:Name="SearchBox" Style="{StaticResource Input}" Padding="30,0,0,0"/>
              <TextBlock Text="&#xE721;" FontFamily="{StaticResource Icons}" Foreground="#6B7385" Margin="12,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
              <TextBlock x:Name="SearchHint" Text="Search language or name, e.g. Urdu, French, Ryan" Foreground="#4A5162"
                         Margin="41,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>
            <Border Grid.Column="1" Style="{StaticResource SegBox}" Margin="10,0,0,0" Width="210">
              <UniformGrid Rows="1">
                <RadioButton x:Name="GenAll" GroupName="gender" Content="All" Style="{StaticResource Seg}" IsChecked="True"/>
                <RadioButton x:Name="GenFemale" GroupName="gender" Content="Female" Style="{StaticResource Seg}"/>
                <RadioButton x:Name="GenMale" GroupName="gender" Content="Male" Style="{StaticResource Seg}"/>
              </UniformGrid>
            </Border>
          </Grid>
          <ListBox x:Name="VoiceList" Grid.Row="2" Margin="14,0,8,8" Background="Transparent" BorderThickness="0" MinHeight="200"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.ScrollUnit="Pixel">
            <ListBox.ItemContainerStyle>
              <Style TargetType="ListBoxItem">
                <Setter Property="Cursor" Value="Hand"/>
                <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                      <Border x:Name="b" CornerRadius="10" Padding="10,8" Margin="0,1,6,1" Background="Transparent" BorderThickness="1" BorderBrush="Transparent">
                        <ContentPresenter/>
                      </Border>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1C2029"/></Trigger>
                        <Trigger Property="IsSelected" Value="True">
                          <Setter TargetName="b" Property="Background" Value="#1D2545"/>
                          <Setter TargetName="b" Property="BorderBrush" Value="#5B7CFA"/>
                        </Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
              </Style>
            </ListBox.ItemContainerStyle>
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Border Width="36" Height="36" CornerRadius="18" Background="#232A3B">
                    <TextBlock Text="{Binding Initial}" Foreground="#B9C6FF" FontSize="14" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <StackPanel Grid.Column="1" Margin="12,0,10,0" VerticalAlignment="Center">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="{Binding Name}" FontSize="14" FontWeight="SemiBold" Foreground="#E8EAEF"/>
                      <Border Visibility="{Binding MultiVis}" Margin="8,1,0,0" CornerRadius="4" Background="#22305A" Padding="6,1" VerticalAlignment="Center">
                        <TextBlock Text="Multilingual" FontSize="10" Foreground="#9DB0FF"/>
                      </Border>
                    </StackPanel>
                    <TextBlock Text="{Binding Details}" FontSize="12" Foreground="#8A92A3" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                  </StackPanel>
                  <TextBlock Grid.Column="2" Text="{Binding Gender}" Foreground="#6B7385" FontSize="12" VerticalAlignment="Center"/>
                </Grid>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
          <Border Grid.Row="3" Background="#242833"/>
          <Grid Grid.Row="4" Margin="24,14">
            <TextBlock x:Name="PickStatus" Foreground="#6B7385" FontSize="12" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,250,0"
                       Text="Multilingual voices can read many languages."/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="SampleBtn" Style="{StaticResource Btn}" Margin="0,0,10,0" Padding="16,10" ToolTip="Hear this voice read the start of your script">
                <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE767;" FontFamily="{StaticResource Icons}" Margin="0,1,9,0"/><TextBlock Text="Hear sample"/></StackPanel>
              </Button>
              <Button x:Name="UseVoiceBtn" Style="{StaticResource Primary}" Padding="20,10" Content="Use this voice"/>
            </StackPanel>
          </Grid>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

# ------------------------------------------------------------------------------
#  App
# ------------------------------------------------------------------------------
$folder = $env:TARGET.TrimEnd('\')
$sbp = New-Object Text.StringBuilder 2048
if ([Win32.Native]::GetLongPathName($folder, $sbp, 2048)) { $folder = $sbp.ToString().TrimEnd('\') }
$tmpDir = Join-Path $env:TEMP ('vo_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir | Out-Null
$helperPath = Join-Path $tmpDir 'voice.py'
[IO.File]::WriteAllText($helperPath, $helperCode, (New-Object Text.UTF8Encoding($false)))
$cfgDir = Join-Path $env:APPDATA 'Voice Over Studio'
if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir | Out-Null }
$cfgPath = Join-Path $cfgDir 'settings.json'
$voicesPath = Join-Path $cfgDir 'voices.json'
$voicesHelper = Join-Path $tmpDir 'voices.py'
[IO.File]::WriteAllText($voicesHelper, $voicesCode, (New-Object Text.UTF8Encoding($false)))
$scriptExt = '.txt', '.docx', '.md'
Invoke-Expression $engine                    # the file readers are used by the window too

$sync = [hashtable]::Synchronized(@{ Status = ''; Done = 0; Total = 0; Result = $null; Error = $null; ErrorKind = $null; Cancel = $false; Proc = $null })
$rs = [runspacefactory]::CreateRunspace()
$rs.ThreadOptions = 'ReuseThread'
$rs.Open()
foreach ($v in 'sync', 'tmpDir', 'helperPath', 'voicesHelper', 'voicesPath') { $rs.SessionStateProxy.SetVariable($v, (Get-Variable $v -ValueOnly)) }
$init = [powershell]::Create(); $init.Runspace = $rs
[void]$init.AddScript($engine).AddScript('$global:previewNo = 0').Invoke()
$init.Dispose()

try {
    $xml = [xml]$xamlText
    $window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xml))
    $ui = @{}
    foreach ($m in [regex]::Matches($xamlText, 'x:Name="(\w+)"')) { $ui[$m.Groups[1].Value] = $window.FindName($m.Groups[1].Value) }

    $state = @{ Kind = $null; PS = $null; Handle = $null; Busy = $false; Ready = $false; Peaks = $null; Duration = 0.0
                Playing = $false; Clip = $null; OutDir = $folder; LastFiles = @() }
    $player = New-Object Windows.Media.MediaPlayer
    $inv = [Globalization.CultureInfo]::InvariantCulture

    function Show-Error([string]$msg) { [void][Windows.MessageBox]::Show($window, $msg, 'Voice Over Studio', 'OK', 'Warning') }
    function Ask-Yes([string]$msg) { [Windows.MessageBox]::Show($window, $msg, 'Voice Over Studio', 'YesNo', 'Question') -eq 'Yes' }
    function Safe([scriptblock]$b) { { param($s, $e) try { & $b $s $e } catch { Show-Error $_.Exception.Message } }.GetNewClosure() }
    function Brush([string]$c) { New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($c)) }
    function Fmt-Time([double]$s) {
        $s = [math]::Max(0, [math]::Floor($s))
        if ($s -ge 3600) { '{0}:{1:D2}:{2:D2}' -f [int][math]::Floor($s / 3600), [int][math]::Floor($s % 3600 / 60), [int]($s % 60) }
        else { '{0}:{1:D2}' -f [int][math]::Floor($s / 60), [int]($s % 60) }
    }
    function Set-Status([string]$t, [string]$color = '#AEB4C0') {
        $ui.Status.Text = $t; $ui.Status.Foreground = Brush $color
        if ($ui.Overlay.Visibility -eq 'Visible') { $ui.PickStatus.Text = $t }
    }

    # ---------------------------- settings ----------------------------
    function Get-Settings {
        $lufs = if ($ui.Loud16.IsChecked) { -16 } elseif ($ui.Loud23.IsChecked) { -23 } else { $null }
        $pace = if ($ui.PaceShort.IsChecked) { 'tight' } elseif ($ui.PaceLong.IsChecked) { 'relaxed' } else { 'natural' }
        @{ Rate = [int]$ui.Speed.Value; Pitch = [int]$ui.Tone.Value; Pace = $pace; Lufs = $lufs
           Mp3 = [bool]$ui.FileMp3.IsChecked; Wav = [bool]$ui.FileWav.IsChecked; Srt = [bool]$ui.FileSrt.IsChecked
           Voice = $state.Voice.Short; VoiceLabel = "Microsoft $($state.Voice.Name) ($($state.Voice.Locale))" }
    }
    function Apply-Settings($c) {
        Set-Voice (Find-Voice $c.Voice)
        $ui.Speed.Value = $c.Rate; $ui.Tone.Value = $c.Pitch
        $ui.PaceShort.IsChecked = $c.Pace -eq 'tight'; $ui.PaceLong.IsChecked = $c.Pace -eq 'relaxed'
        $ui.PaceNatural.IsChecked = $c.Pace -notin 'tight', 'relaxed'
        $ui.Loud16.IsChecked = $c.Lufs -eq -16; $ui.Loud23.IsChecked = $c.Lufs -eq -23; $ui.LoudOff.IsChecked = $c.Lufs -notin -16, -23
        $ui.FileMp3.IsChecked = $c.Mp3; $ui.FileWav.IsChecked = $c.Wav; $ui.FileSrt.IsChecked = $c.Srt
    }
    $defaults = @{ Voice = 'en-GB-RyanNeural'; Rate = 0; Pitch = 0; Pace = 'natural'; Lufs = -16; Mp3 = $true; Wav = $false; Srt = $true }
    function Save-Config {
        try {
            $c = Get-Settings; if ($null -eq $c.Lufs) { $c.Lufs = 0 }
            $c.Remove('VoiceLabel')
            [IO.File]::WriteAllText($cfgPath, (ConvertTo-Json -InputObject $c))
        } catch {}
    }
    function Load-Config {
        $c = $defaults.Clone()
        try {
            if (Test-Path -LiteralPath $cfgPath) {
                $j = [IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json
                foreach ($k in @($c.Keys)) { if ($null -ne $j.$k) { $c[$k] = $j.$k } }
            }
        } catch {}
        return $c
    }

    function Update-Labels {
        $r = [int]$ui.Speed.Value; $p = [int]$ui.Tone.Value
        $ui.SpeedVal.Text = if ($r -eq 0) { 'Natural' } elseif ($r -gt 0) { "$r% faster" } else { "$(-$r)% slower" }
        $ui.ToneVal.Text = if ($p -eq 0) { 'Natural' } elseif ($p -gt 0) { "Higher  +$p" } else { "Deeper  $p" }
        $ui.LoudHint.Text = if ($ui.Loud16.IsChecked) { 'Standard for YouTube, social media and podcasts.' }
                            elseif ($ui.Loud23.IsChecked) { 'TV and broadcast standard (EBU R128).' }
                            else { 'Level left as it comes from the voice service.' }
        Update-Stats
    }

    function Update-Stats {
        $t = $ui.ScriptBox.Text
        $ui.Placeholder.Visibility = if ($t.Length) { 'Collapsed' } else { 'Visible' }
        $plain = $t -replace '\[[^\]]*\]', ' '
        $cjk = [regex]::Matches($plain, '[぀-ヿ㐀-鿿豈-﫿]').Count        # Chinese / Japanese have no spaces
        $words = [regex]::Matches(($plain -replace '[぀-ヿ㐀-鿿豈-﫿]', ' '), '[\p{L}\p{N}][^\s]*').Count
        $paras = [regex]::Matches($t, '(\r?\n\s*){2,}').Count
        $sec = ($words + $cjk * 0.55) / (155.0 * (1 + $ui.Speed.Value / 100.0)) * 60 + $paras * 0.9
        $count = if ($cjk -gt $words) { '{0:N0} characters' -f ($cjk + $words) } else { '{0:N0} words' -f $words }
        $ui.Stats.Text = if ($words + $cjk) { '{0}  {1}  about {2}' -f $count, [char]0x00B7, (Fmt-Time ([math]::Max(1, $sec))) } else { '' }
        $sel = $ui.ScriptBox.SelectionLength -gt 0
        $ui.PreviewText.Text = if ($sel) { 'Preview selection' } else { 'Preview' }
    }

    function Set-OutDir([string]$d) {
        $state.OutDir = $d
        $ui.OutDirText.Text = "Saves to  $d"
        $ui.OutDirText.ToolTip = $d
    }

    # ---------------------------- voices ----------------------------
    $rtl = 'ar', 'he', 'fa', 'ur', 'ps', 'yi', 'sd', 'ug'
    function New-Voice([string]$short, [string]$gender, [string]$locale, [string]$lang, [string]$traits) {
        if (-not $locale) { $locale = ($short -split '-')[0..1] -join '-' }
        if (-not $lang) { try { $lang = ([Globalization.CultureInfo]$locale).DisplayName } catch { $lang = $locale } }
        $name = $short
        if ($short.StartsWith("$locale-")) { $name = $short.Substring($locale.Length + 1) }
        $name = $name -replace 'Neural$', ''
        $multi = $name -match 'Multilingual$'
        $name = $name -replace 'Multilingual$', ''
        $details = if ($traits) { "$lang  $([char]0x00B7)  $traits" } else { $lang }
        [pscustomobject]@{ Short = $short; Name = $name; Locale = $locale; Lang = $lang; Gender = $gender; Initial = $name.Substring(0, 1)
                           Multi = $multi; MultiVis = $(if ($multi) { 'Visible' } else { 'Collapsed' }); Details = $details
                           Search = "$name $lang $short $gender $(if ($multi) { 'multilingual' })".ToLower() }
    }

    # Uses the saved list of Microsoft voices; a few popular ones are built in for the very first start
    function Load-Voices {
        $list = New-Object System.Collections.Generic.List[object]
        try {
            if (Test-Path -LiteralPath $voicesPath) {
                foreach ($v in ([IO.File]::ReadAllText($voicesPath, [Text.Encoding]::UTF8) | ConvertFrom-Json)) { $list.Add((New-Voice $v.s $v.g $v.l $v.n $v.p)) }
            }
        } catch { $list.Clear() }
        if (-not $list.Count) {
            foreach ($v in 'en-GB-RyanNeural|Male', 'en-GB-SoniaNeural|Female', 'en-GB-ThomasNeural|Male', 'en-US-AndrewMultilingualNeural|Male',
                           'en-US-AvaMultilingualNeural|Female', 'en-US-GuyNeural|Male', 'en-AU-WilliamMultilingualNeural|Male', 'en-IN-PrabhatNeural|Male',
                           'ur-PK-AsadNeural|Male', 'ur-PK-UzmaNeural|Female', 'hi-IN-MadhurNeural|Male', 'ar-SA-HamedNeural|Male',
                           'fr-FR-RemyMultilingualNeural|Male', 'de-DE-FlorianMultilingualNeural|Male', 'es-ES-AlvaroNeural|Male', 'zh-CN-YunxiNeural|Male') {
                $p = $v -split '\|'; $list.Add((New-Voice $p[0] $p[1] '' '' ''))
            }
        }
        $state.Voices = @($list | Sort-Object Lang, Name)
        $langs = @($state.Voices | ForEach-Object Locale | Sort-Object -Unique).Count
        $ui.HeaderSub.Text = '{0} Microsoft neural voices  {1}  {2} languages and accents' -f $state.Voices.Count, [char]0x00B7, $langs
        $ui.VoiceCount.Text = $ui.HeaderSub.Text
    }

    function Find-Voice([string]$short) {
        $v = $state.Voices | Where-Object Short -eq $short | Select-Object -First 1
        if (-not $v -and $short) { $v = New-Voice $short '' '' '' '' }
        if (-not $v) { $v = Find-Voice 'en-GB-RyanNeural' }
        return $v
    }

    function Set-Voice($v) {
        $state.Voice = $v
        $ui.VoiceInitial.Text = $v.Initial
        $ui.VoiceName.Text = $v.Name + $(if ($v.Multi) { '  (Multilingual)' })
        $ui.VoiceLang.Text = if ($v.Gender) { "$($v.Lang)  $([char]0x00B7)  $($v.Gender)" } else { $v.Lang }
        $ui.VoiceBtn.ToolTip = "$($v.Short) - click to choose another voice or language"
        $dir = if (($v.Locale -split '-')[0] -in $rtl) { 'RightToLeft' } else { 'LeftToRight' }
        $ui.ScriptBox.FlowDirection = $dir
        $ui.Placeholder.FlowDirection = $dir
    }

    function Filter-Voices {
        $terms = @($ui.SearchBox.Text.ToLower() -split '\s+' | Where-Object { $_ })
        $g = if ($ui.GenFemale.IsChecked) { 'Female' } elseif ($ui.GenMale.IsChecked) { 'Male' } else { $null }
        $list = @($state.Voices | Where-Object {
            $item = $_
            (-not $g -or $item.Gender -eq $g) -and -not @($terms | Where-Object { -not $item.Search.Contains($_) }).Count
        })
        $ui.VoiceList.ItemsSource = [object[]]$list
        $ui.SearchHint.Visibility = if ($ui.SearchBox.Text) { 'Collapsed' } else { 'Visible' }
        $cur = $list | Where-Object Short -eq $state.Voice.Short | Select-Object -First 1
        if (-not $cur -and $list) { $cur = $list[0] }
        if ($cur) { $ui.VoiceList.SelectedItem = $cur; $ui.VoiceList.ScrollIntoView($cur) }
        $ui.PickStatus.Text = if ($list) { '{0} voice(s)  {1}  Multilingual voices can read many languages.' -f $list.Count, [char]0x00B7 } else { 'No voices match your search.' }
    }

    function Open-Picker {
        $ui.SearchBox.Text = ''
        $ui.Overlay.Visibility = 'Visible'
        Filter-Voices
        $ui.SearchBox.Focus() | Out-Null
    }
    function Close-Picker { $ui.Overlay.Visibility = 'Collapsed' }
    function Use-SelectedVoice {
        $v = $ui.VoiceList.SelectedItem
        if ($v) { Set-Voice $v; Update-Stats; Set-Status "Voice: $($v.Name), $($v.Lang)" }
        Close-Picker
    }

    function Load-Script([string]$path) {
        $ext = [IO.Path]::GetExtension($path).ToLower()
        if ($ext -notin $scriptExt) { throw 'Please choose a .txt, .docx or .md file.' }
        try {
            $lines = if ($ext -eq '.docx') { Read-Docx $path } else { Read-TextFile $path }
        } catch { throw "Could not read $([IO.Path]::GetFileName($path)). If it is open in Word, close it and try again." }
        if ($ext -eq '.md') { $lines = @(Convert-Markdown $lines) }
        $text = (($lines -join "`r`n") -replace '(\r\n[ \t]*){3,}', "`r`n`r`n").Trim()
        $ui.ScriptBox.Text = $text
        $ui.ScriptBox.CaretIndex = 0
        $ui.FileLabel.Text = [IO.Path]::GetFileName($path)
        $ui.OutName.Text = [IO.Path]::GetFileNameWithoutExtension($path) + ' - Voice Over'
        Set-OutDir (Split-Path $path)
    }

    # ---------------------------- engine status ----------------------------
    function Set-Engine([string]$mode, [string]$text) {
        $ui.EngineDot.Fill = Brush (@{ ready = '#3CCB7F'; busy = '#F5B83D'; missing = '#F0616D' }[$mode])
        $ui.EngineText.Text = $text
        $ui.InstallBtn.Visibility = if ($mode -eq 'missing') { 'Visible' } else { 'Collapsed' }
        $state.Ready = $mode -eq 'ready'
    }

    # ---------------------------- background work ----------------------------
    function Start-Work([string]$kind, $req) {
        $req.Kind = $kind
        $sync.Status = ''; $sync.Done = 0; $sync.Total = 0; $sync.Result = $null; $sync.Error = $null; $sync.ErrorKind = $null; $sync.Cancel = $false
        $state.Kind = $kind
        $state.PS = [powershell]::Create(); $state.PS.Runspace = $rs
        [void]$state.PS.AddScript('param($r) Invoke-Work $r').AddArgument($req)
        $state.Handle = $state.PS.BeginInvoke()
        Set-Busy $true
    }

    function Set-Busy([bool]$on) {
        $state.Busy = $on
        $render = $state.Kind -in 'preview', 'full'
        $ui.PreviewBtn.IsEnabled = -not $on
        $ui.SampleBtn.IsEnabled = -not $on
        $ui.InstallBtn.IsEnabled = -not $on
        $ui.CreateBtn.IsEnabled = (-not $on) -or $render
        $ui.CreateText.Text = if ($on -and $render) { 'Cancel' } else { 'Create voice over' }
        $ui.CreateIcon.Text = if ($on -and $render) { [string][char]0xE711 } else { [string][char]0xE720 }
        $ui.Prog.Visibility = if ($on -and $render) { 'Visible' } else { 'Hidden' }
        if ($on) { $ui.Prog.Value = 0 }
    }

    function Finish-Work {
        try { $state.PS.EndInvoke($state.Handle) } catch {}
        $state.PS.Dispose(); $state.PS = $null; $state.Handle = $null
        $kind = $state.Kind
        Set-Busy $false
        $res = $sync.Result

        if ($kind -in 'setup', 'install', 'update') {
            if ($sync.Error) { Set-Engine 'missing' 'Voice engine problem'; Show-Error $sync.Error; return }
            if ($res.Ready) {
                Set-Engine 'ready' 'Voice engine ready'
                Load-Voices                                  # the list was just refreshed from Microsoft
                Set-Voice (Find-Voice $state.Voice.Short)
                if ($ui.Overlay.Visibility -eq 'Visible') { Filter-Voices }
            }
            else {
                Set-Engine 'missing' ('Needs ' + ($res.Missing -join ', '))
                if ($kind -ne 'setup') { Show-Error "Setup could not finish ($($res.Missing -join ', ') missing). Check the internet connection and try again." }
            }
            if ($kind -eq 'update' -and $res.Ready) { Set-Status 'Voice engine updated - try again.' '#3CCB7F' }
            return
        }

        if ($sync.Error) {
            if ($sync.Cancel) { Set-Status 'Cancelled.'; return }
            Set-Status 'Something went wrong.' '#F0616D'
            if ($sync.ErrorKind -eq 'record') {
                if (Ask-Yes "$($sync.Error)`n`nIf your internet is working, updating the voice engine usually fixes this.`nUpdate the voice engine now?") {
                    Set-Engine 'busy' 'Updating voice engine'; Start-Work 'update' @{}
                }
            } else { Show-Error $sync.Error }
            return
        }

        Load-Audio $res.Play $res.Peaks $res.Duration
        if ($kind -eq 'preview') {
            Set-Status ('Preview  {0}  {1}' -f [char]0x00B7, (Fmt-Time $res.Duration))
            Toggle-Play
        } else {
            $state.LastFiles = $res.Files
            $names = ($res.Files | ForEach-Object { [IO.Path]::GetFileName($_) })
            Set-Status ("Saved  {0}" -f ($names -join ',  ')) '#3CCB7F'
            $ui.Status.ToolTip = ($res.Files -join "`n")
            $ui.FolderBtn.Visibility = 'Visible'
        }
    }

    # ---------------------------- player ----------------------------
    function Load-Audio([string]$path, $peaks, [double]$dur) {
        $player.Close()
        $state.Playing = $false
        $ui.PlayIcon.Text = [string][char]0xE768
        $player.Open([Uri]$path)
        $state.Peaks = $peaks; $state.Duration = $dur
        $ui.TotTime.Text = Fmt-Time $dur
        $ui.CurTime.Text = '0:00'
        $ui.WaveHint.Visibility = 'Collapsed'
        $ui.PlayBtn.IsEnabled = $true
        Draw-Wave
    }

    function Toggle-Play {
        if (-not $ui.PlayBtn.IsEnabled) { return }
        if ($state.Playing) { $player.Pause(); $state.Playing = $false; $ui.PlayIcon.Text = [string][char]0xE768 }
        else { $player.Play(); $state.Playing = $true; $ui.PlayIcon.Text = [string][char]0xE769 }
    }

    function Draw-Wave {
        $c = $ui.Wave; $W = $c.ActualWidth; $H = $c.ActualHeight
        $c.Children.Clear()
        $p = $state.Peaks
        if (-not $p -or $W -lt 20) { return }
        $n = $p.Length; $bars = [int][math]::Floor($W / 3)
        $sb = New-Object Text.StringBuilder
        for ($b = 0; $b -lt $bars; $b++) {
            $a = [int][math]::Floor($b * $n / $bars); $z = [int][math]::Max($a + 1, [math]::Floor(($b + 1) * $n / $bars)); $m = 0.0
            for ($i = $a; $i -lt $z -and $i -lt $n; $i++) { if ($p[$i] -gt $m) { $m = $p[$i] } }
            $bar = [math]::Max(2.0, [math]::Pow($m, 0.7) * $H * 0.94)
            [void]$sb.AppendFormat($inv, 'M{0},{1:0.#}h2v{2:0.#}h-2Z', $b * 3, ($H - $bar) / 2, $bar)
        }
        $geo = [Windows.Media.Geometry]::Parse($sb.ToString()); $geo.Freeze()
        $back = New-Object Windows.Shapes.Path; $back.Data = $geo; $back.Fill = Brush '#323949'
        $front = New-Object Windows.Shapes.Path; $front.Data = $geo
        $g = New-Object Windows.Media.LinearGradientBrush ([Windows.Media.Color]::FromRgb(0x5B, 0x7C, 0xFA)), ([Windows.Media.Color]::FromRgb(0xA0, 0x6B, 0xFF)), 0
        $g.MappingMode = 'Absolute'; $g.StartPoint = '0,0'; $g.EndPoint = "$W,0"
        $front.Fill = $g
        $state.Clip = New-Object Windows.Media.RectangleGeometry (New-Object Windows.Rect 0, 0, 0, $H)
        $front.Clip = $state.Clip
        [void]$c.Children.Add($back); [void]$c.Children.Add($front)
        Update-Playhead
    }

    function Update-Playhead {
        if (-not $state.Clip -or $state.Duration -le 0) { return }
        $dur = if ($player.NaturalDuration.HasTimeSpan) { $player.NaturalDuration.TimeSpan.TotalSeconds } else { $state.Duration }
        $pos = [math]::Min($player.Position.TotalSeconds, $dur)
        $W = $ui.Wave.ActualWidth
        $state.Clip.Rect = New-Object Windows.Rect 0, 0, ([math]::Max(0, $W * $pos / [math]::Max(0.01, $dur))), $ui.Wave.ActualHeight
        $ui.CurTime.Text = Fmt-Time $pos
    }

    # ---------------------------- actions ----------------------------
    function Do-Preview {
        if ($state.Busy) { return }
        if (-not $state.Ready) { Show-Error 'The voice engine is not set up yet. Click "Set up voice engine" at the top right.'; return }
        $tb = $ui.ScriptBox
        $sel = $tb.SelectionLength -gt 0
        $text = if ($sel) { $tb.SelectedText } else { $tb.Text }
        if (-not $text.Trim()) { Show-Error 'Type, paste or open a script first.'; return }
        if ($state.Playing) { Toggle-Play }
        Set-Status 'Preparing preview ...'
        Start-Work 'preview' @{ Lines = [string[]]($text -split "`r?`n"); Settings = (Get-Settings); Selection = $sel }
    }

    # Plays the voice selected in the picker reading the start of the script
    function Do-Sample {
        if ($state.Busy) { return }
        if (-not $state.Ready) { Show-Error 'The voice engine is not set up yet. Click "Set up voice engine" at the top right.'; return }
        $v = $ui.VoiceList.SelectedItem
        if (-not $v) { return }
        $text = $ui.ScriptBox.Text.Trim()
        if (-not $text) { $text = "Hello, I'm $($v.Name). This is how I sound." }
        if ($state.Playing) { Toggle-Play }
        $s = Get-Settings
        $s.Voice = $v.Short
        Set-Status "Recording a sample of $($v.Name) ..."
        Start-Work 'preview' @{ Lines = [string[]]($text -split "`r?`n"); Settings = $s; Selection = $true; Limit = 150 }
    }

    function Do-Create {
        if ($state.Busy) {
            if ($state.Kind -in 'preview', 'full') {
                $sync.Cancel = $true
                try { if ($sync.Proc -and -not $sync.Proc.HasExited) { $sync.Proc.Kill() } } catch {}
                Set-Status 'Cancelling ...'
            }
            return
        }
        if (-not $state.Ready) { Show-Error 'The voice engine is not set up yet. Click "Set up voice engine" at the top right.'; return }
        $text = $ui.ScriptBox.Text
        if (-not $text.Trim()) { Show-Error 'Type, paste or open a script first.'; return }
        $s = Get-Settings
        if (-not $s.Mp3 -and -not $s.Wav) { Show-Error 'Choose at least one file type to save: MP3 or WAV.'; return }
        $name = ($ui.OutName.Text.Trim() -replace '[\\/:*?"<>|]', '-').Trim(' .')
        if (-not $name) { $name = 'Voice Over'; $ui.OutName.Text = $name }
        if (-not (Test-Path -LiteralPath $state.OutDir)) { Show-Error "The save folder does not exist:`n$($state.OutDir)"; return }
        if ($state.Playing) { Toggle-Play }
        $ui.FolderBtn.Visibility = 'Collapsed'
        $ui.Status.ToolTip = $null
        Set-Status 'Starting ...'
        Start-Work 'full' @{ Lines = [string[]]($text -split "`r?`n"); Settings = $s; OutDir = $state.OutDir; Name = $name }
    }

    # ---------------------------- wiring ----------------------------
    $ui.Speed.Add_ValueChanged({ Update-Labels })
    $ui.Tone.Add_ValueChanged({ Update-Labels })
    $ui.Speed.Add_MouseDoubleClick({ $ui.Speed.Value = 0 })
    $ui.Tone.Add_MouseDoubleClick({ $ui.Tone.Value = 0 })
    foreach ($r in 'Loud16', 'Loud23', 'LoudOff') { $ui[$r].Add_Checked({ Update-Labels }) }
    $ui.ScriptBox.Add_TextChanged({ Update-Stats })
    $ui.ScriptBox.Add_SelectionChanged({ $ui.PreviewText.Text = if ($ui.ScriptBox.SelectionLength -gt 0) { 'Preview selection' } else { 'Preview' } })

    $ui.OpenBtn.Add_Click((Safe {
        $d = New-Object Microsoft.Win32.OpenFileDialog
        $d.Filter = 'Scripts (*.txt;*.docx;*.md)|*.txt;*.docx;*.md|All files (*.*)|*.*'
        $d.InitialDirectory = $state.OutDir
        if ($d.ShowDialog($window)) { Load-Script $d.FileName }
    }))
    $ui.SaveBtn.Add_Click((Safe {
        $d = New-Object Microsoft.Win32.SaveFileDialog
        $d.Filter = 'Text file (*.txt)|*.txt'
        $d.InitialDirectory = $state.OutDir
        $d.FileName = ($ui.OutName.Text -replace ' - Voice Over$', '') -replace '[\\/:*?"<>|]', '-'
        if ($d.ShowDialog($window)) {
            [IO.File]::WriteAllText($d.FileName, $ui.ScriptBox.Text, (New-Object Text.UTF8Encoding($true)))
            $ui.FileLabel.Text = [IO.Path]::GetFileName($d.FileName)
            Set-Status "Script saved: $([IO.Path]::GetFileName($d.FileName))" '#3CCB7F'
        }
    }))
    $ui.PasteBtn.Add_Click((Safe {
        if ([Windows.Clipboard]::ContainsText()) { $ui.ScriptBox.Text = [Windows.Clipboard]::GetText().Trim(); $ui.FileLabel.Text = '' }
    }))
    $ui.ClearBtn.Add_Click((Safe { $ui.ScriptBox.Clear(); $ui.FileLabel.Text = ''; $ui.ScriptBox.Focus() }))
    $ui.DirBtn.Add_Click((Safe {
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Choose where to save the voice over'
        $d.SelectedPath = $state.OutDir
        if ($d.ShowDialog() -eq 'OK') { Set-OutDir $d.SelectedPath }
    }))
    $ui.ResetBtn.Add_Click((Safe { $d = $defaults.Clone(); $d.Voice = $state.Voice.Short; Apply-Settings $d; Update-Labels }))
    $ui.VoiceBtn.Add_Click((Safe { Open-Picker }))
    $ui.CloseBtn.Add_Click((Safe { Close-Picker }))
    $ui.UseVoiceBtn.Add_Click((Safe { Use-SelectedVoice }))
    $ui.SampleBtn.Add_Click((Safe { Do-Sample }))
    $ui.VoiceList.Add_MouseDoubleClick((Safe { Use-SelectedVoice }))
    $ui.SearchBox.Add_TextChanged((Safe { Filter-Voices }))
    foreach ($r in 'GenAll', 'GenFemale', 'GenMale') { $ui[$r].Add_Checked((Safe { if ($state.Voices) { Filter-Voices } })) }
    $ui.Overlay.Add_MouseLeftButtonDown({ param($s, $e) if ($e.OriginalSource -eq $ui.Overlay) { Close-Picker } })
    $ui.SearchBox.Add_PreviewKeyDown({
        param($s, $e)
        $lb = $ui.VoiceList; $n = $lb.Items.Count
        if ($e.Key -eq 'Down' -and $n) { $lb.SelectedIndex = [math]::Min($n - 1, $lb.SelectedIndex + 1); $lb.ScrollIntoView($lb.SelectedItem); $e.Handled = $true }
        elseif ($e.Key -eq 'Up' -and $n) { $lb.SelectedIndex = [math]::Max(0, $lb.SelectedIndex - 1); $lb.ScrollIntoView($lb.SelectedItem); $e.Handled = $true }
    })
    $ui.InstallBtn.Add_Click((Safe {
        $msg = "Voice Over Studio needs a few free tools: FFmpeg, Python and the edge-tts voice engine.`n`nInstall what is missing now? (needs internet, takes a few minutes)"
        if (Ask-Yes $msg) { Set-Engine 'busy' 'Installing voice engine'; Start-Work 'install' @{} }
    }))
    $ui.PreviewBtn.Add_Click((Safe { Do-Preview }))
    $ui.CreateBtn.Add_Click((Safe { Do-Create }))
    $ui.PlayBtn.Add_Click((Safe { Toggle-Play }))
    $ui.FolderBtn.Add_Click((Safe {
        $f = @($state.LastFiles | Where-Object { Test-Path -LiteralPath $_ })
        if ($f) { Start-Process explorer.exe "/select,`"$($f[0])`"" } else { Start-Process explorer.exe "`"$($state.OutDir)`"" }
    }))
    $ui.Wave.Add_SizeChanged({ Draw-Wave })
    $ui.Wave.Add_MouseLeftButtonDown({
        param($s, $e)
        if (-not $state.Peaks) { return }
        $dur = if ($player.NaturalDuration.HasTimeSpan) { $player.NaturalDuration.TimeSpan.TotalSeconds } else { $state.Duration }
        $player.Position = [TimeSpan]::FromSeconds($dur * $e.GetPosition($ui.Wave).X / $ui.Wave.ActualWidth)
        if (-not $state.Playing) { Toggle-Play }
        Update-Playhead
    })
    $player.Add_MediaEnded({ $player.Stop(); $state.Playing = $false; $ui.PlayIcon.Text = [string][char]0xE768; Update-Playhead })

    $drag = { param($s, $e) if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { $e.Effects = 'Copy'; $e.Handled = $true } }
    $ui.ScriptBox.Add_PreviewDragEnter($drag)
    $ui.ScriptBox.Add_PreviewDragOver($drag)
    $ui.ScriptBox.Add_PreviewDrop({
        param($s, $e)
        $f = $e.Data.GetData([Windows.DataFormats]::FileDrop)
        if ($f) { $e.Handled = $true; try { Load-Script $f[0] } catch { Show-Error $_.Exception.Message } }
    })

    $window.Add_PreviewKeyDown({
        param($s, $e)
        $ctrl = ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) -ne 0
        try {
            if ($ui.Overlay.Visibility -eq 'Visible') {
                if ($e.Key -eq 'Escape') { Close-Picker; $e.Handled = $true }
                elseif ($e.Key -eq 'Return') { Use-SelectedVoice; $e.Handled = $true }
                elseif ($e.Key -eq 'F5') { Do-Sample; $e.Handled = $true }
                return
            }
            if ($e.Key -eq 'F5') { Do-Preview; $e.Handled = $true }
            elseif ($ctrl -and $e.Key -eq 'Return') { Do-Create; $e.Handled = $true }
            elseif ($e.Key -eq 'Space' -and -not $ui.ScriptBox.IsKeyboardFocused -and -not $ui.OutName.IsKeyboardFocused) { Toggle-Play; $e.Handled = $true }
        } catch { Show-Error $_.Exception.Message }
    })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(60)
    $timer.Add_Tick({
        if ($state.Handle) {
            if ($state.Kind -in 'preview', 'full' -and -not $sync.Cancel) {
                if ($sync.Total -gt 0) {
                    $ui.Prog.Value = $sync.Done / $sync.Total
                    Set-Status ('Recording voice  {0}  line {1} of {2}' -f [char]0x00B7, [math]::Min($sync.Done + 1, $sync.Total), $sync.Total)
                } elseif ($sync.Status) {
                    if ($sync.Status -notlike 'Recording*') { $ui.Prog.Value = [math]::Max($ui.Prog.Value, 0.92) }
                    Set-Status $sync.Status
                }
            } elseif ($state.Kind -ne 'setup' -and $sync.Status) { $ui.EngineText.Text = $sync.Status.TrimEnd(' ', '.') }
            if ($state.Handle.IsCompleted) { Finish-Work }
        }
        if ($state.Playing) { Update-Playhead }
    })

    $window.Add_SourceInitialized({
        $h = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
        $v = 1; [void][Win32.Native]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)       # dark title bar
    })
    $window.Add_Closing({
        Save-Config
        $timer.Stop()
        $player.Close()
        $sync.Cancel = $true
        try { if ($sync.Proc -and -not $sync.Proc.HasExited) { $sync.Proc.Kill() } } catch {}
    })

    # app icon (taskbar / title bar)
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $ig = New-Object Windows.Media.LinearGradientBrush ([Windows.Media.Color]::FromRgb(0x5B, 0x7C, 0xFA)), ([Windows.Media.Color]::FromRgb(0x9B, 0x6B, 0xFF)), 45
    $dc.DrawRoundedRectangle($ig, $null, (New-Object Windows.Rect 0, 0, 64, 64), 15, 15)
    $ft = New-Object Windows.Media.FormattedText ([string][char]0xE720), $inv, 'LeftToRight', (New-Object Windows.Media.Typeface 'Segoe MDL2 Assets'), 34, ([Windows.Media.Brushes]::White)
    $dc.DrawText($ft, (New-Object Windows.Point ((64 - $ft.Width) / 2), ((64 - $ft.Height) / 2)))
    $dc.Close()
    $icon = New-Object Windows.Media.Imaging.RenderTargetBitmap 64, 64, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $icon.Render($dv)
    $window.Icon = $icon

    # ---------------------------- start ----------------------------
    $wa = [Windows.SystemParameters]::WorkArea
    $window.Height = [math]::Min(860, $wa.Height - 20)
    $window.Width = [math]::Min(1200, $wa.Width - 20)
    Load-Voices
    Apply-Settings (Load-Config)
    Set-OutDir $folder
    $ui.OutName.Text = 'Voice Over'
    $first = Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -in $scriptExt -and $_.Name -notlike '~$*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($first) { try { Load-Script $first.FullName } catch {} }
    Update-Labels
    $timer.Start()
    Start-Work 'setup' @{}

    [void]$window.ShowDialog()
}
catch {
    [void][Windows.MessageBox]::Show("Voice Over Studio could not start:`n`n$($_.Exception.Message)", 'Voice Over Studio', 'OK', 'Error')
}
finally {
    try { $rs.Dispose() } catch {}
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
