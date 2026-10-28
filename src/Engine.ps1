# ============================================================
#  Camera Ingest - the import engine
#  Takes ONE source (card, drive or folder) and ONE camera
#  profile and imports it:
#    - SHA256 ledger per camera: nothing ever imports twice
#    - names from the camera's pattern: running count, date/time
#      taken, the camera's own names, or a custom mix
#    - capture dates kept (or stamped with today, for bad clocks)
#    - photos wait in a local Incoming folder until after the
#      optional review (rotate / delete), THEN go to the destination. Cloud
#      folders (iCloud, OneDrive...) upload a file the moment it
#      appears and may never pick up later edits.
#    - hard-to-play video formats converted to MP4, originals kept locally
#    - RAW files kept locally, a JPG goes to the destination
#    - card copies deleted only after a verified (hashed) copy,
#      and only if the profile says so. Never formats anything.
# ============================================================

. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Viewer.ps1")     # the photo window window-app imports show

function Set-FileTimes([string]$path, [datetime]$when) {
    $i = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($i) { $i.CreationTime = $when; $i.LastWriteTime = $when }
}

function Get-FreeName([string]$dir, [string]$name) {
    # "keep names" mode: never overwrite - add _2, _3... on a clash
    $target = Join-Path $dir $name
    if (-not (Test-Path -LiteralPath $target)) { return $name }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
    $ext  = [System.IO.Path]::GetExtension($name)
    for ($n = 2; ; $n++) {
        $try = "${base}_$n$ext"
        if (-not (Test-Path -LiteralPath (Join-Path $dir $try))) { return $try }
    }
}

$script:FaultCount = @{}
function Test-Fault([string]$kind) {
    # Stress-test hook, inert in normal use: INGEST_FAULT="copy:3,crash:5" makes the 3rd copy
    # fail, the 5th file crash the run, and so on. Lets tests prove a failure never loses a photo.
    if (-not $env:INGEST_FAULT) { return $false }
    $script:FaultCount[$kind] = 1 + [int]$script:FaultCount[$kind]
    foreach ($f in ($env:INGEST_FAULT -split ',')) {
        $k, $n = $f -split ':'
        if ($k -eq $kind -and [int]$n -eq $script:FaultCount[$kind]) { return $true }
    }
    return $false
}

$script:Pump = $null
function Invoke-External([string]$exe, [string[]]$argv) {
    # Run a converter (ffmpeg, HandBrake, Python) and return its exit code (0 = it says it
    # worked). With the photo window open, wait in small steps and keep the window painting,
    # so a long video conversion doesn't freeze it.
    if (-not $script:Pump) {
        & $exe @argv 2>$null | Out-Null
        return [int]$LASTEXITCODE
    }
    $quoted = foreach ($a in $argv) {
        if ($a -eq "" -or $a -match '[\s"]') { '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $a }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = ($quoted -join " ")
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    while (-not $p.HasExited) { & $script:Pump; Start-Sleep -Milliseconds 40 }
    $p.WaitForExit()
    return $p.ExitCode
}

function Test-Output([string]$path, [int]$exitCode) {
    # a converter's output only counts when the program said it worked AND the file has content
    $o = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    return ($exitCode -eq 0 -and $o -and $o.Length -gt 0)
}

function Test-PathInside([string]$inner, [string]$outer) {
    # true when $inner is $outer or somewhere below it
    if (-not $inner -or -not $outer) { return $false }
    try {
        $i = [System.IO.Path]::GetFullPath($inner).TrimEnd('\') + '\'
        $o = [System.IO.Path]::GetFullPath($outer).TrimEnd('\') + '\'
    } catch { return $false }
    return $i.StartsWith($o, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-SameHash([string]$path, [string]$hash) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash -eq $hash
}

function Set-JpegDate([string]$path, [datetime]$when) {
    # "Wrong clock" mode for JPEGs. Photo apps and iCloud place a photo by the date INSIDE
    # it (EXIF), not the file date, so a dead-clock camera's "2001:01:01" has to be replaced
    # there. Done byte-for-byte inside the EXIF block: the date strings are always 19
    # characters, so nothing moves and the picture data is never re-compressed.
    # Returns how many date fields were changed (0 = the photo had none).
    $old = @()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $ms = New-Object System.IO.MemoryStream(,$bytes)
        $img = [System.Drawing.Image]::FromStream($ms, $false, $false)
        foreach ($tag in @(306, 36867, 36868)) {   # DateTime, DateTimeOriginal, DateTimeDigitized
            if ($img.PropertyIdList -contains $tag) {
                $s = [System.Text.Encoding]::ASCII.GetString($img.GetPropertyItem($tag).Value).TrimEnd([char]0)
                if ($s.Length -eq 19 -and $old -notcontains $s) { $old += $s }
            }
        }
        $img.Dispose(); $ms.Dispose()
    } catch { return 0 }
    if ($old.Count -eq 0) { return 0 }

    # find the EXIF (APP1) segment so only bytes inside it can ever be touched
    if ($bytes.Length -lt 4 -or $bytes[0] -ne 0xFF -or $bytes[1] -ne 0xD8) { return 0 }
    $pos = 2; $segStart = -1; $segEnd = -1
    while ($pos + 4 -lt $bytes.Length -and $bytes[$pos] -eq 0xFF) {
        $marker = $bytes[$pos + 1]
        $len = $bytes[$pos + 2] * 256 + $bytes[$pos + 3]
        if ($marker -eq 0xE1 -and [System.Text.Encoding]::ASCII.GetString($bytes, $pos + 4, 4) -eq "Exif") {
            $segStart = $pos + 4; $segEnd = [math]::Min($pos + 2 + $len, $bytes.Length); break
        }
        if ($marker -eq 0xDA) { break }   # image data starts - no EXIF block
        $pos += 2 + $len
    }
    if ($segStart -lt 0) { return 0 }

    $new = [System.Text.Encoding]::ASCII.GetBytes($when.ToString("yyyy:MM:dd HH:mm:ss"))
    $changed = 0
    foreach ($s in $old) {
        $pat = [System.Text.Encoding]::ASCII.GetBytes($s)
        for ($i = $segStart; $i -le $segEnd - 19; $i++) {
            $hit = $true
            for ($j = 0; $j -lt 19; $j++) { if ($bytes[$i + $j] -ne $pat[$j]) { $hit = $false; break } }
            if ($hit) { [Array]::Copy($new, 0, $bytes, $i, 19); $changed++; $i += 18 }
        }
    }
    if ($changed -eq 0) { return 0 }
    # write beside it, prove it still opens, then swap - the original is never half-written
    $tmp = "$path.redate.tmp"
    try {
        [System.IO.File]::WriteAllBytes($tmp, $bytes)
        $ms = New-Object System.IO.MemoryStream(,[System.IO.File]::ReadAllBytes($tmp))
        $chk = [System.Drawing.Image]::FromStream($ms); $chk.Dispose(); $ms.Dispose()
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return 0
    }
    return $changed
}

function Set-VideoDate([string]$path, $tools, [datetime]$when) {
    # Same idea for MP4/MOV: rewrite the creation date inside the file (a lossless remux).
    if (-not $tools.ffmpeg) { return $false }
    $ErrorActionPreference = "Continue"
    $utc = $when.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $tmp = Join-Path $env:TEMP ("ingest_redate_{0}{1}" -f [guid]::NewGuid().ToString("N"), [System.IO.Path]::GetExtension($path))
    $code = Invoke-External $tools.ffmpeg @("-y", "-loglevel", "error", "-i", $path, "-map", "0", "-c", "copy", "-metadata", "creation_time=$utc", $tmp)
    if (Test-Output $tmp $code) {
        Move-Item -LiteralPath $tmp -Destination $path -Force
        return $true
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    return $false
}

function Get-VideoFrame([string]$video, $tools) {
    # one still from half a second in, for the photo window's filmstrip; "" if it can't
    $out = Join-Path $env:TEMP ("ingest_frame_{0}.jpg" -f [guid]::NewGuid().ToString("N"))
    $code = Invoke-External $tools.ffmpeg @("-y", "-loglevel", "error", "-ss", "0.5", "-i", $video, "-frames:v", "1", "-vf", "scale=192:-2", $out)
    if (Test-Output $out $code) { return $out }
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    return ""
}

function Convert-Video([string]$in, [string]$out, $tools, [datetime]$when) {
    # HandBrake if present (then ffmpeg stamps the date inside), else ffmpeg alone.
    # The iCloud / Google Photos timeline reads the date INSIDE the video, not the file date.
    # (HandBrake/ffmpeg chat on stderr; never let a caller's "Stop" preference turn that into a crash)
    $ErrorActionPreference = "Continue"
    $utc = $when.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    if ($tools.handbrake) {
        $code = Invoke-External $tools.handbrake @("-i", $in, "-o", $out, "--preset", "Fast 1080p30")
        if (-not (Test-Output $out $code)) { return $false }
        if ($tools.ffmpeg) {
            $tmp = Join-Path $env:TEMP ("ingest_remux_{0}.mp4" -f [guid]::NewGuid().ToString("N"))
            $code = Invoke-External $tools.ffmpeg @("-y", "-loglevel", "error", "-i", $out, "-c", "copy", "-metadata", "creation_time=$utc", $tmp)
            if (Test-Output $tmp $code) { Move-Item -LiteralPath $tmp -Destination $out -Force }
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        return $true
    }
    if ($tools.ffmpeg) {
        $code = Invoke-External $tools.ffmpeg @("-y", "-loglevel", "error", "-i", $in, "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", "-metadata", "creation_time=$utc", $out)
        return (Test-Output $out $code)
    }
    return $false
}

function Invoke-CameraImport {
    # One import at a time on this PC. Two windows importing at once can hand out the same
    # numbers or step on each other's conversions; the second one waits its turn instead.
    param($Config, $Camera, $Source, [switch]$Yes, [switch]$FromFolder, [string]$Sandbox = "", [switch]$NoEject, [switch]$Gui)
    if (Test-SpecialCamera $Camera) {
        # a camera with its own importer (Wi-Fi, cable...) - never copied from a card or folder here
        Write-Host "  $($Camera.name) uses an external importer. Run it from the camera list." -ForegroundColor Yellow
        return @{ copied = 0; skippedDup = 0; deleted = 0; converted = 0; rendered = 0; failed = 1; cardLost = $false }
    }
    $lockPath = Join-Path $env:TEMP "camera-ingest-import.lock"
    try {
        $lock = [System.IO.File]::Open($lockPath, "OpenOrCreate", "ReadWrite", "None")
    } catch {
        Write-Host ""
        Write-Host "  Another import is in progress." -ForegroundColor Yellow
        Write-Host "  Wait for it to finish, then try again. No changes were made." -ForegroundColor Yellow
        return @{ copied = 0; skippedDup = 0; deleted = 0; converted = 0; rendered = 0; failed = 1; cardLost = $false; busy = $true }
    }
    try {
        $script:FaultCount = @{}
        Invoke-CameraImportCore @PSBoundParameters
    } finally {
        $lock.Dispose()
    }
}

function Invoke-CameraImportCore {
    param(
        $Config,
        $Camera,
        $Source,                 # from Get-SourceInfo
        [switch]$Yes,            # no questions: start right away, skip the review offer
        [switch]$FromFolder,     # source is a plain folder: never delete, never eject
        [string]$Sandbox = "",   # practice run: everything goes under this folder, source untouched
        [switch]$NoEject,        # tests: treat it like a card but don't try to eject
        [switch]$Gui             # run from the window app: no console questions - the click was the
                                 # go-ahead, and the review question comes as a pop-up
    )

    # failures are handled one by one below (copy/hash checks); external tools writing to
    # stderr must not abort the import
    $ErrorActionPreference = "Continue"
    $camDir      = Get-CameraFolder $Config $Camera
    $destination = Get-CameraDestination $Config $Camera
    if ($Sandbox) {
        $camDir      = $Sandbox
        $destination = [System.IO.Path]::Combine($Sandbox, "Media")
    }
    $staging     = [System.IO.Path]::Combine($camDir, "Incoming")
    $origDir     = [System.IO.Path]::Combine($camDir, "Converted Originals")
    $rawDir      = [System.IO.Path]::Combine($camDir, "RAW Originals")
    $unprocDir   = [System.IO.Path]::Combine($camDir, "Unprocessed Originals")
    # videos (and RAW sent as-is) are finished here - converted, re-dated - and only then copied
    # to the destination, so a cloud folder never sees a half-done or soon-replaced file
    $workDir     = [System.IO.Path]::Combine($camDir, "Working")
    $ledger      = [System.IO.Path]::Combine($camDir, "imported_media.csv")
    $deleteOK    = $Camera.deleteFromCard -and -not $FromFolder -and -not $Sandbox
    $pattern     = Get-NamingPattern $Camera
    $counts      = Test-PatternCounts $pattern     # pattern has {n}: names are unique by number
    $keepExt     = ($pattern -eq "{orig}")         # camera's own names keep their own extension case
    $prefix      = $Camera.prefix
    $counterFile = [System.IO.Path]::Combine($camDir, "next_number.txt")
    $reviewMode  = Get-ReviewMode $Camera
    $tools       = Get-Tools $Config
    $rawToJpg    = Join-Path $PSScriptRoot "raw_to_jpg.py"
    $canRaw      = $tools.rawpy -and (Test-Path -LiteralPath $rawToJpg)
    $canConvert  = [bool]($tools.handbrake -or $tools.ffmpeg)

    $result = @{ copied = 0; skippedDup = 0; deleted = 0; converted = 0; rendered = 0; failed = 0; cardLost = $false }
    $ui = @{ viewer = $null }     # the photo window (window-app imports only)

    Write-Title "IMPORTING: $($Camera.name.ToUpper())"

    # The source must not overlap where imports land, in either direction (importing
    # "Pictures" when the library lives in Pictures would feed the output back in)
    foreach ($out in @($camDir, $destination, $Config.libraryRoot)) {
        if ((Test-PathInside $Source.root $out) -or (Test-PathInside $out $Source.root)) {
            Write-Host "  $($Source.root) overlaps the import destination:" -ForegroundColor Red
            Write-Host "  $out" -ForegroundColor Red
            Write-Host "  Select a folder outside the library and camera destination. No changes were made." -ForegroundColor Red
            $result.failed++
            return $result
        }
    }
    if ($Sandbox) {
        Write-Host "  PRACTICE IMPORT - files are copied to $Sandbox" -ForegroundColor Magenta
        Write-Host "  The source is not modified." -ForegroundColor Magenta
        Write-Host ""
    }

    # ---- Folders ----
    try {
        foreach ($d in @($destination, $staging, $origDir, $rawDir, $workDir)) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null }
        }
    } catch {
        Write-Host "  Error: the destination folder could not be created:" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  If it is on an external drive or network share, connect it and try again." -ForegroundColor Red
        Write-Host "  Otherwise verify the camera destination or the library folder in Settings." -ForegroundColor Red
        Write-Host "  No files were copied or deleted." -ForegroundColor Red
        $result.failed++
        return $result
    }

    function Offer-Review([string[]]$paths, [string]$what) {
        # the camera's review setting: "ask" (default), "always" open the window, "never"
        if ($Yes -or $reviewMode -eq "never") { return }
        # numbered names are unique, so a deleted photo's RAW / untouched twin can safely go too
        $twins = @()
        if ($counts) { $twins = @($rawDir, $unprocDir) }
        if ($Gui) {
            # window app: the photo viewer that showed the copying turns into the review
            # ("ask" and "always" both land here - Done is one click away)
            if (-not $ui.viewer) { $ui.viewer = New-PhotoViewer "Review - $($Camera.name)"; Show-Viewer $ui.viewer }
            $where = Split-Path $destination -Leaf
            $null = Invoke-ViewerReview $ui.viewer $paths $twins "Review the imported files. No files have been copied to '$where' yet." "&Finish Import"
            return
        }
        $jpgs = @($paths | Where-Object { $_ -match '\.jpe?g$' })
        if ($jpgs.Count -eq 0) { return }
        $open = ($reviewMode -eq "always")
        if (-not $open) {
            Write-Host ""
            $rev = Read-Host "  Type R + Enter to review $what - rotate or delete - BEFORE they go out (or just Enter to send as-is)"
            $open = ($rev -match '^[rR]')
        }
        if ($open) {
            & (Join-Path $PSScriptRoot "RotateReview.ps1") -Files $jpgs -Companions $twins | Out-Host
        }
    }

    function Close-ImportViewer([int]$lingerMs = 0) {
        if (-not $ui.viewer) { return }
        # hands-off cameras: leave the finished window up a moment so you see it happened
        $until = [datetime]::Now.AddMilliseconds($lingerMs)
        while ([datetime]::Now -lt $until -and -not $ui.viewer.form.IsDisposed) { Update-Viewer $ui.viewer; Start-Sleep -Milliseconds 30 }
        if ($env:INGEST_VIEWER_SNAPSHOT) { Save-ViewerSnapshot $ui.viewer $env:INGEST_VIEWER_SNAPSHOT }   # tests
        Close-Viewer $ui.viewer
        $ui.viewer = $null
        $script:Pump = $null
    }

    function Send-File([string]$sp) {
        # Copy one finished file (a reviewed photo from Incoming, a video from Working) into
        # the destination - which may be a cloud folder that uploads whatever lands in it, so
        # it arrives exactly once, complete. Returns the name it got there, or "" if it didn't
        # make it (then it stays where it was and goes out next run).
        $sf = Get-Item -LiteralPath $sp -ErrorAction SilentlyContinue
        if (-not $sf) { return "" }
        $ct = $sf.CreationTime; $wt = $sf.LastWriteTime
        $want = (Get-FileHash -LiteralPath $sp -Algorithm SHA256).Hash
        if (Test-SameHash (Join-Path $destination $sf.Name) $want) {
            # already there, byte for byte: a previous run sent it but couldn't tidy up
            Remove-Item -LiteralPath $sp -Force -ErrorAction SilentlyContinue
            return $sf.Name
        }
        $finalName = Get-FreeName $destination $sf.Name
        $final = Join-Path $destination $finalName
        try {
            Copy-Item -LiteralPath $sp -Destination $final -ErrorAction Stop
            if (Test-Fault "send") { [IO.File]::AppendAllText($final, "x") }
        } catch { }
        # the local copy is only removed once the outgoing copy is byte-identical
        if (-not (Test-SameHash $final $want)) {
            Remove-Item -LiteralPath $final -Force -ErrorAction SilentlyContinue
            Write-Host "  $($sf.Name) failed verification at the destination and was kept in $(Split-Path (Split-Path $sp -Parent) -Leaf)." -ForegroundColor Yellow
            Write-Host "  It will be sent on the next import." -ForegroundColor Yellow
            return ""
        }
        $chk = Get-Item -LiteralPath $final
        $chk.CreationTime = $ct; $chk.LastWriteTime = $wt
        try { Remove-Item -LiteralPath $sp -Force -ErrorAction Stop }
        catch { Write-Host "     ($($sf.Name) was sent; its local copy will be removed on the next import)" -ForegroundColor Yellow }
        if ($finalName -ne $sf.Name -and $ledgerHashOf.ContainsKey($sp)) { Update-LedgerName $ledgerHashOf[$sp] $sf.Name $finalName }
        return $finalName
    }

    function Send-Staged([string[]]$paths) {
        # Move reviewed photos from Incoming into the destination, dates intact
        $sent = 0
        foreach ($sp in $paths) { if (Send-File $sp) { $sent++ } }
        return $sent
    }

    function Save-Original([string]$path) {
        # keep an untouched copy before anything edits a file; never overwrites an older one
        if (-not (Test-Path -LiteralPath $unprocDir)) { New-Item -ItemType Directory -Path $unprocDir -Force | Out-Null }
        $keep = Join-Path $unprocDir (Get-FreeName $unprocDir (Split-Path $path -Leaf))
        Copy-Item -LiteralPath $path -Destination $keep
        $i = Get-Item -LiteralPath $path
        Set-FileTimes $keep $i.LastWriteTime
        return $keep
    }

    function Add-LedgerRow([string]$hash, [string]$as, [string]$orig) {
        # throws if the row can't be written (file open in Excel, disk full) - callers must stop:
        # a file that isn't in the ledger would be imported again next time
        if (Test-Fault "ledger") { throw "simulated ledger write failure" }
        [PSCustomObject]@{
            Hash = $hash; ImportedAs = $as; OriginalName = $orig
            ImportDate = (Get-Date -Format "yyyy-MM-dd HH:mm"); Camera = $Camera.name
        } | Export-Csv -LiteralPath $ledger -NoTypeInformation -Encoding UTF8 -Append -ErrorAction Stop
        $seen[$hash] = $as
    }

    function Update-LedgerName([string]$hash, [string]$from, [string]$to) {
        # a file that had to take a new name on the way out (_2): record where it really is,
        # so a later "is it already imported?" check finds it. Only that one file's row (by
        # fingerprint) - names repeat across imports. Best effort - never fatal.
        try {
            $rows = @(Import-Csv -LiteralPath $ledger -ErrorAction Stop)
            $hit = $false
            foreach ($r in $rows) { if ($r.Hash -eq $hash -and $r.ImportedAs -eq $from) { $r.ImportedAs = $to; $hit = $true } }
            if (-not $hit) { return }
            $tmp = "$ledger.tmp"
            $rows | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            Move-Item -LiteralPath $tmp -Destination $ledger -Force -ErrorAction Stop
            if ($seen.ContainsKey($hash)) { $seen[$hash] = $to }
        } catch { }
    }

    $seen = @{}            # filled from the ledger below; Update-LedgerName may touch it first
    $ledgerHashOf = @{}    # local path -> the fingerprint its ledger row was written with

    # ---- Leftovers from an interrupted earlier run: review, then send - never blind ----
    # (photos and videos only - a crash can leave *.tmp files behind, and those must never go out)
    $isMedia = { param($f) [bool](Get-MediaKind $f.Extension) }
    $leftover = @(Get-ChildItem -LiteralPath $staging -File -ErrorAction SilentlyContinue | Where-Object { & $isMedia $_ } | Select-Object -ExpandProperty FullName)
    $leftWork = @(Get-ChildItem -LiteralPath $workDir -File -ErrorAction SilentlyContinue | Where-Object { & $isMedia $_ } | Select-Object -ExpandProperty FullName)
    if ($leftWork.Count -gt 0) {
        # finished videos that never made it out - nothing to review, just send them
        $n = 0; foreach ($w in $leftWork) { if (Send-File $w) { $n++ } }
        Write-Host "  $n video(s) from an interrupted import sent to $destination" -ForegroundColor Green
    }
    if ($leftover.Count -gt 0) {
        Write-Host "  $($leftover.Count) photo(s) from an interrupted import are pending." -ForegroundColor Yellow
        Offer-Review $leftover "those leftover photos"
        Close-ImportViewer
        $n = Send-Staged $leftover
        Write-Host "  $n pending photo(s) sent to $destination" -ForegroundColor Green
        Write-Host ""
    }

    # ---- Ledger of everything this camera ever imported ----
    if (Test-Path -LiteralPath $ledger) {
        # it must be writable before anything is copied (Excel locks a CSV it has open)
        try {
            $probe = [System.IO.File]::Open($ledger, "Open", "ReadWrite", "ReadWrite")
            $probe.Dispose()
        } catch {
            Write-Host "  The import history for this camera cannot be written:" -ForegroundColor Red
            Write-Host "  $ledger" -ForegroundColor Red
            Write-Host "  Close any program using the file and try again. No changes were made." -ForegroundColor Red
            $result.failed++
            return $result
        }
        foreach ($row in (Import-Csv -LiteralPath $ledger)) { $seen[$row.Hash] = $row.ImportedAs }
    }

    # ---- What's on the source ----
    # Numbered in shooting order. Same-name files (a RAW+JPEG pair) stay together, sorted
    # by the pair's earliest time, with the RAW first so it can claim its JPG twin.
    $groupTime = @{}
    foreach ($f in $Source.media) {
        $k = Join-Path $f.DirectoryName $f.BaseName
        if (-not $groupTime.ContainsKey($k) -or $f.LastWriteTime -lt $groupTime[$k]) { $groupTime[$k] = $f.LastWriteTime }
    }
    $files = @($Source.media | Sort-Object { $groupTime[(Join-Path $_.DirectoryName $_.BaseName)] }, DirectoryName, BaseName, {
        if ((Get-MediaKind $_.Extension) -eq "raw") { 0 } else { 1 } })
    if ($files.Count -eq 0) {
        Write-Host "  No photos or videos were found on $($Source.root)." -ForegroundColor Yellow
        return $result
    }

    # ---- Next number ----
    # Highest number handed out so far: the saved counter, plus any name on disk or in the
    # ledger that this pattern produced (covers a lost counter file or a renamed pattern)
    $next = 1
    if ($counts) {
        $highest = 0
        try { $highest = [int](Get-Content -LiteralPath $counterFile -ErrorAction Stop | Select-Object -First 1) - 1 } catch { }
        $rx = Get-PatternRegex $pattern $prefix
        $legacy = '^' + [regex]::Escape($prefix) + ' \((?<n>\d+)\)(_\d+)?$'   # names from before patterns existed
        $names = @()
        foreach ($dir in @($destination, $origDir, $rawDir, $staging)) {
            $names += @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
        }
        $names += @($seen.Values | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) })
        foreach ($b in $names) {
            if ($b -match $rx -or $b -match $legacy) { $n = [int]$Matches["n"]; if ($n -gt $highest) { $highest = $n } }
        }
        $next = $highest + 1
    }

    Write-Host ("  Source: {2} - {0} file(s), {1} MB" -f $files.Count, $Source.sizeMB, $Source.root) -ForegroundColor Green
    Write-Host "  Destination: $destination"
    $sample = $files | Select-Object -First 1
    $sampleWhen = (Get-FileDate $Camera $sample.LastWriteTime (Get-Date)).when
    $example = Format-FileBase $pattern $prefix $next $sampleWhen $sample.BaseName
    if ($counts) { Write-Host "  File names: $example$($sample.Extension.ToUpper())  (numbering continues from $next)" }
    else         { Write-Host "  File names: $example$($sample.Extension.ToUpper())" }
    switch ([string]$Camera.dates) {
        "import" { Write-Host "  Dates: import date (camera clock marked as incorrect)." }
        "auto"   { Write-Host "  Dates: camera date; import date if older than $($Camera.staleDays) days or in the future." }
        default  { Write-Host "  Dates: camera date." }
    }
    if ($deleteOK) { Write-Host "  Source files are deleted after verified copy." }
    else           { Write-Host "  Source files are not deleted." }
    Write-Host "  Previously imported files are skipped."
    if (-not $canConvert -and @($files | Where-Object { (Get-MediaKind $_.Extension) -eq "oldvideo" }).Count -gt 0) {
        Write-Host "  HandBrakeCLI and ffmpeg not found. AVI and MPG videos are copied without conversion." -ForegroundColor Yellow
    }
    Write-Host ""
    if (($Camera.autoStart -or $Gui) -and -not $Yes) {
        if (-not $Gui) { Write-Host "  Starting automatically (per camera settings)." -ForegroundColor Gray }
        Write-Host ""
    } elseif (-not $Yes) {
        $go = Read-Host "  Press Enter to start (or type N and Enter to cancel)"
        if ($go -match '^[nN]') {
            Write-Host "  Cancelled. No changes were made." -ForegroundColor Yellow
            return $result
        }
        Write-Host ""
    }

    if ($Gui) {
        # the "now importing" window: each photo shows up as it comes off the card, and the
        # same window becomes the review at the end
        $ui.viewer = New-PhotoViewer "Importing - $($Camera.name)"
        Show-Viewer $ui.viewer
        $script:Pump = { [System.Windows.Forms.Application]::DoEvents() }
    }
    $fileNo = 0
    $ledgerBroken = $false     # set when the import history stops accepting rows: finish this file, then stop

    $staged = @()
    $convertFailed = @()
    $renderFailed = @()
    $consumed = @{}       # camera JPGs already handled alongside their RAW twin
    $deleteFailed = $false
    $now = Get-Date

    foreach ($f in $files) {
        $fileNo++
        if ($consumed.ContainsKey($f.FullName)) { continue }
        $kind = Get-MediaKind $f.Extension
        $extU = $f.Extension.ToUpper()
        $jpgFrom = ""
        if ($ui.viewer) { Set-ViewerStatus $ui.viewer ("Copying {0} of {1}:  {2}" -f $fileNo, $files.Count, $f.Name) ($fileNo - 1) $files.Count }

        # 0. Seen before?
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        if (Test-Fault "cardlost") { $hash = $null }
        if (-not $hash) {
            Write-Host ""
            Write-Host "  $($f.Name) can no longer be read. The card may have been removed." -ForegroundColor Red
            Write-Host "  Import stopped. Files imported so far are safe. Reinsert the card" -ForegroundColor Red
            Write-Host "  and run the import again to continue." -ForegroundColor Red
            $result.cardLost = $true
            break
        }
        if ($seen.ContainsKey($hash)) {
            $prior = $seen[$hash]
            $result.skippedDup++
            # Only clear it off the card if a byte-identical copy really is on the PC. A name
            # match isn't enough: the old copy may have been deleted and the name reused.
            $priorOnDisk = @(@($destination, $origDir, $rawDir, $staging, $unprocDir, $workDir) | Where-Object { Test-SameHash (Join-Path $_ $prior) $hash })
            if ($deleteOK -and $priorOnDisk.Count -gt 0) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "  Skipped $($f.Name): previously imported as '$prior'. Removed from card." -ForegroundColor Yellow
            } else {
                Write-Host "  Skipped $($f.Name): previously imported as '$prior'." -ForegroundColor Yellow
            }
            continue
        }

        # the camera's own time, or the import time if the camera's clock is (or looks) wrong
        $fd = Get-FileDate $Camera $f.LastWriteTime $now
        $when = $fd.when
        $dateFixed = $fd.fixed
        $newBase = Format-FileBase $pattern $prefix $next $when $f.BaseName
        $needsConvert = ($kind -eq "oldvideo") -and $canConvert -and $Camera.convertVideo
        $rawLocal = ($kind -eq "raw") -and ($Camera.rawMode -ne "copy")

        # 1. Copy it off. Photos wait in Incoming until after the review.
        if ($needsConvert)        { $dir = $origDir }
        elseif ($rawLocal)        { $dir = $rawDir }
        elseif ($kind -eq "photo") { $dir = $staging }
        else                      { $dir = $workDir }      # finished locally, sent once in step 2c
        $ext = $extU; if ($keepExt) { $ext = $f.Extension }
        # a taken name gets _2, _3... (same-second burst shots, a lost counter) - never overwritten
        $name = Get-FreeName $dir "$newBase$ext"
        $copyTarget = Join-Path $dir $name

        Write-Host ("  Copying {0} ({1} MB)" -f $f.Name, [math]::Round($f.Length / 1MB, 1)) -ForegroundColor Gray
        try {
            if (Test-Fault "copy") { throw "simulated copy failure" }
            # no -Force: an existing file is never overwritten, the copy fails instead
            Copy-Item -LiteralPath $f.FullName -Destination $copyTarget -ErrorAction Stop
            if (Test-Fault "corrupt") { [IO.File]::AppendAllText($copyTarget, "x") }
        } catch {
            Write-Host "  Copy failed for $($f.Name): $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  Import stopped. This file was not deleted." -ForegroundColor Red
            $result.failed++
            break
        }
        $copyHash = (Get-FileHash -LiteralPath $copyTarget -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        if ($copyHash -ne $hash) {
            Write-Host "  $($f.Name) failed verification. It was left on the card. Import stopped." -ForegroundColor Red
            Remove-Item -LiteralPath $copyTarget -Force -ErrorAction SilentlyContinue
            $result.failed++
            break
        }
        if (Test-Fault "crash-before-ledger") { throw "simulated crash" }
        # Record it the moment a verified copy exists, so a crash later in this file's
        # handling can't lead to it being imported twice
        try {
            Add-LedgerRow $hash $name $f.Name
            $ledgerHashOf[$copyTarget] = $hash
        } catch {
            # Unrecorded = it would come in again next time. Undo this one copy (it's ours,
            # just made), leave the card alone and stop; the next run picks it up cleanly.
            Remove-Item -LiteralPath $copyTarget -Force -ErrorAction SilentlyContinue
            Write-Host "  The import history could not be written ($($_.Exception.Message))." -ForegroundColor Red
            Write-Host "  Import stopped. $($f.Name) was not imported and" -ForegroundColor Red
            Write-Host "  no files were deleted. Close any program using imported_media.csv and try again." -ForegroundColor Red
            $result.failed++
            break
        }
        $result.copied++
        if (Test-Fault "crash") { throw "simulated crash" }
        Set-FileTimes $copyTarget $when
        $finalName = $name
        if ($kind -eq "photo") { $staged += $copyTarget }

        # 1b. Optional per-camera fix-up on JPGs (e.g. a stuck-pixel patcher); the
        #     untouched file is kept in "Unprocessed Originals"
        $isJpg = ($kind -eq "photo" -and $f.Extension -match '^\.jpe?g$')
        $keptOriginal = ""
        if ($Camera.photoHook -and $isJpg) {
            $keptOriginal = Save-Original $copyTarget
            $cmd = $Camera.photoHook.Replace("{file}", "`"$copyTarget`"")
            & cmd.exe /c $cmd 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Set-FileTimes $copyTarget $when
                Write-Host "     Photo hook applied (original in Unprocessed Originals)" -ForegroundColor Gray
            } else {
                Copy-Item -LiteralPath $keptOriginal -Destination $copyTarget -Force
                Set-FileTimes $copyTarget $when
                Write-Host "     Photo hook failed. Photo left unmodified." -ForegroundColor Yellow
            }
        }

        # 1c. Wrong (or wrong-looking) date: put today's date INSIDE the file too, since that's
        #     what iCloud / Google Photos / phones sort by. The untouched file is kept.
        if ($dateFixed -and ($isJpg -or $kind -eq "video")) {
            $savedHere = ""
            if (-not $keptOriginal) { $savedHere = Save-Original $copyTarget }
            if ($isJpg) { $redated = (Set-JpegDate $copyTarget $when) -gt 0 }
            else        { $redated = Set-VideoDate $copyTarget $tools $when }
            Set-FileTimes $copyTarget $when
            if ($redated) {
                $why = "camera clock marked wrong"
                if ($Camera.dates -eq "auto") { $why = "it said $($f.LastWriteTime.ToString('yyyy-MM-dd'))" }
                Write-Host "     Date set to import date ($why). Original in Unprocessed Originals." -ForegroundColor Gray
            } elseif ($savedHere) {
                # nothing inside needed changing (the photo stores no date), so the
                # spare copy just made is identical - don't keep a pointless duplicate
                Remove-Item -LiteralPath $savedHere -Force
            }
        }

        # 2a. RAW: the destination gets a JPG under the same name. A RAW+JPEG camera
        #     already made one (same name next to it) - use that; otherwise render.
        if ($rawLocal) {
            # always a name nothing has yet, so the cleanup below can only ever remove our own file
            $jpgName = Get-FreeName $staging "$newBase.JPG"
            $jpgTarget = Join-Path $staging $jpgName
            $jpgFrom = ""
            $twin = Get-ChildItem -LiteralPath $f.DirectoryName -File -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -eq $f.BaseName -and $_.Extension -match '^\.jpe?g$' } | Select-Object -First 1
            if ($twin) {
                $twinHash = (Get-FileHash -LiteralPath $twin.FullName -Algorithm SHA256).Hash
                if (-not $seen.ContainsKey($twinHash)) {
                    Copy-Item -LiteralPath $twin.FullName -Destination $jpgTarget -ErrorAction SilentlyContinue
                    $chk = (Get-FileHash -LiteralPath $jpgTarget -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
                    $twinRecorded = $false
                    if ($chk -eq $twinHash) {
                        try { Add-LedgerRow $twinHash $jpgName $twin.Name; $twinRecorded = $true; $ledgerHashOf[$jpgTarget] = $twinHash }
                        catch {
                            # same rule as above: unrecorded means undo our copy, leave the card's
                            # JPG where it is, and stop after this file (the RAW itself is recorded)
                            Write-Host "  The import history could not be written. Import stopped after this file." -ForegroundColor Red
                            $ledgerBroken = $true
                            $result.failed++
                        }
                    }
                    if ($twinRecorded) {
                        Set-FileTimes $jpgTarget $when
                        $staged += $jpgTarget
                        $consumed[$twin.FullName] = $true
                        if ($deleteOK) {
                            try { Remove-Item -LiteralPath $twin.FullName -Force -ErrorAction Stop; $result.deleted++ }
                            catch { $deleteFailed = $true }
                        }
                        $result.copied++
                        $jpgFrom = "camera's own JPG"
                    } else {
                        Remove-Item -LiteralPath $jpgTarget -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            if (-not $jpgFrom -and $canRaw -and -not $ledgerBroken) {
                Write-Host "     Rendering RAW to JPEG" -ForegroundColor Gray
                $code = Invoke-External $tools.python @($rawToJpg, $copyTarget, $jpgTarget, $when.ToString("yyyy:MM:dd HH:mm:ss"))
                if (Test-Output $jpgTarget $code) {
                    Set-FileTimes $jpgTarget $when
                    $staged += $jpgTarget
                    $result.rendered++
                    $jpgFrom = "rendered"
                } else {
                    Remove-Item -LiteralPath $jpgTarget -Force -ErrorAction SilentlyContinue
                    $renderFailed += $name
                    Write-Host "  $($f.Name): RAW rendering failed. RAW file kept in RAW Originals." -ForegroundColor Red
                }
            } elseif (-not $jpgFrom) {
                Write-Host "     No RAW renderer configured. RAW file kept in RAW Originals." -ForegroundColor Yellow
            }
            if ($jpgFrom -and $dateFixed) {
                $null = Save-Original $jpgTarget
                $null = Set-JpegDate $jpgTarget $when
                Set-FileTimes $jpgTarget $when
            }
            if ($jpgFrom) { Write-Host "     + $jpgName ($jpgFrom)" -ForegroundColor Gray }
        }

        # 2b. Hard-to-play video formats -> MP4, made in Working; the original stays local
        $toSend = ""
        if ($needsConvert) {
            # the converters overwrite without asking, so never hand them an existing name
            $mp4Name = Get-FreeName $workDir "$newBase.MP4"
            $mp4Target = Join-Path $workDir $mp4Name
            Write-Host "     Converting to MP4" -ForegroundColor Gray
            if (Convert-Video $copyTarget $mp4Target $tools $when) {
                Set-FileTimes $mp4Target $when
                $result.converted++
                $toSend = $mp4Target
            } else {
                Remove-Item -LiteralPath $mp4Target -Force -ErrorAction SilentlyContinue
                $convertFailed += $name
                Write-Host "  $($f.Name): conversion failed. Original kept in Converted Originals." -ForegroundColor Red
            }
        } elseif ($dir -eq $workDir) {
            $toSend = $copyTarget      # a video kept as it is (re-dated above if needed) / RAW sent as-is
        }

        # 2c. Out to the destination: once, complete, fingerprint-checked
        $frame = ""
        if ($toSend) {
            if ($ui.viewer -and $tools.ffmpeg -and @("video", "oldvideo") -contains $kind) { $frame = Get-VideoFrame $toSend $tools }
            $sentAs = Send-File $toSend
            if ($sentAs) { $finalName = $sentAs }
            else {
                $finalName = "$(Split-Path $toSend -Leaf) (waiting in Working - goes out next run)"
                $result.failed++
            }
        }
        Write-Host "  $($f.Name)  ->  $finalName" -ForegroundColor Green
        if ($ui.viewer) {
            $cap = "$($f.Name)  ->  $finalName"
            if ($kind -eq "photo")             { Add-ViewerPhoto $ui.viewer $copyTarget $cap }
            elseif ($rawLocal -and $jpgFrom)   { Add-ViewerPhoto $ui.viewer $jpgTarget "$cap  (+ $jpgName)" }
            elseif ($kind -eq "raw")           { Add-ViewerPhoto $ui.viewer "" $cap "RAW" }
            else                               { Add-ViewerPhoto $ui.viewer "" $cap "VIDEO" $frame }
        }
        if ($frame) { Remove-Item -LiteralPath $frame -Force -ErrorAction SilentlyContinue }

        # 3. Delete from the card (only after the hash-verified copy above)
        if ($deleteOK) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $result.deleted++
            } catch {
                $deleteFailed = $true
                Write-Host "     Copied, but could not be deleted from the card." -ForegroundColor Yellow
            }
        }
        if ($counts) {
            $next++
            try { Set-Content -LiteralPath $counterFile -Value $next -ErrorAction Stop } catch { }
        }
        if ($ledgerBroken) { break }
    }

    # ---- Summary ----
    Write-Host ""
    Write-Rule
    Write-Host "  Import complete: $($result.copied) file(s) imported for $($Camera.name)." -ForegroundColor Cyan
    if ($result.skippedDup -gt 0) { Write-Host "  $($result.skippedDup) previously imported file(s) skipped." -ForegroundColor Cyan }
    if ($result.converted -gt 0)  { Write-Host "  $($result.converted) video(s) converted to MP4 (originals in Converted Originals)." -ForegroundColor Cyan }
    if ($result.rendered -gt 0)   { Write-Host "  $($result.rendered) RAW photo(s) rendered to JPG (RAW files kept in RAW Originals)." -ForegroundColor Cyan }
    if ($deleteOK)                { Write-Host "  $($result.deleted) file(s) deleted from the card." -ForegroundColor Cyan }
    if ($convertFailed.Count -gt 0) {
        Write-Host "  Conversion failed (originals kept):" -ForegroundColor Red
        $convertFailed | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    }
    if ($renderFailed.Count -gt 0) {
        Write-Host "  RAW rendering failed (RAW files kept):" -ForegroundColor Red
        $renderFailed | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    }
    if ($deleteFailed) {
        Write-Host ""
        Write-Host "  Some files could not be deleted from the card. If the card has a write-protect" -ForegroundColor Yellow
        Write-Host "  switch, unlock it and run the import" -ForegroundColor Yellow
        Write-Host "  again. Previously imported files are removed, not imported twice." -ForegroundColor Yellow
    }
    $result.failed += $convertFailed.Count + $renderFailed.Count

    # ---- Eject, then the optional review, THEN the photos go out ----
    if (-not $FromFolder -and -not $Sandbox -and -not $NoEject -and -not $result.cardLost -and -not $Source.isFloppy) {
        Invoke-SafeEject $Source.root
    } elseif ($Source.isFloppy -and -not $FromFolder) {
        Write-Host "  The card can be removed once the drive activity light is off." -ForegroundColor Green
    }
    if ($ui.viewer) {
        Show-LatestPhoto $ui.viewer -Now
        Set-ViewerStatus $ui.viewer ("Copied {0} item(s) for {1}." -f $result.copied, $Camera.name) $files.Count $files.Count
        Set-ViewerHint $ui.viewer "Finished copying."
    }
    if ($staged.Count -gt 0) {
        Offer-Review $staged "the new photos"
        if ($ui.viewer -and $ui.viewer.mode -ne "review") {
            Set-ViewerStatus $ui.viewer ("Sending {0} photo(s) to {1}" -f $staged.Count, (Split-Path $destination -Leaf))
        }
        $sent = Send-Staged $staged
        Write-Host "  $sent photo(s) sent to $destination" -ForegroundColor Green
    }
    if ($ui.viewer) {
        $linger = 0
        if ($ui.viewer.mode -ne "review") {
            Set-ViewerStatus $ui.viewer ("Done - {0} item(s) imported for {1}." -f $result.copied, $Camera.name)
            Set-ViewerHint $ui.viewer "All done. This window closes by itself."
            $linger = 2000
        }
        Close-ImportViewer $linger
    }
    return $result
}
