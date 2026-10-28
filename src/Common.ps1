# ============================================================
#  Camera Ingest - shared helpers
#  Config load/save, camera profiles, drive scanning, camera
#  recognition, tool discovery and the small text-menu helpers
#  every screen uses. Dot-sourced by Menu.ps1 and Import.ps1.
#  Plain Windows PowerShell 5.1 - nothing to install.
# ============================================================

$script:AppName    = "Camera Ingest"
$script:AppVersion = "0.1.0"
$script:AppRoot    = Split-Path -Parent $PSScriptRoot

$script:PhotoExts   = @(".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tif", ".tiff")
$script:RawExts     = @(".arw", ".srf", ".sr2", ".dng", ".cr2", ".cr3", ".crw", ".nef", ".nrw", ".orf", ".rw2", ".raf", ".pef", ".x3f")
$script:KeepVidExts = @(".mp4", ".mov", ".m4v")
$script:ConvVidExts = @(".avi", ".mpg", ".mpeg", ".mts", ".m2ts", ".asf", ".wmv", ".3gp", ".mod", ".tod")
$script:SkipFolders = @("System Volume Information", '$RECYCLE.BIN', "LOST.DIR", "MISC", ".Trashes", ".Spotlight-V100")

function Get-MediaKind([string]$ext) {
    $e = $ext.ToLower()
    if ($script:PhotoExts   -contains $e) { return "photo" }
    if ($script:RawExts     -contains $e) { return "raw" }
    if ($script:KeepVidExts -contains $e) { return "video" }
    if ($script:ConvVidExts -contains $e) { return "oldvideo" }
    return ""
}

# ------------------------------------------------------------
#  Config
# ------------------------------------------------------------

function Get-DefaultConfigPath { Join-Path $script:AppRoot "data\config.json" }

function Get-ICloudPhotosFolder {
    # iCloud for Windows puts the synced Photos folder here (both the old and new app)
    foreach ($p in @(
        (Join-Path $env:USERPROFILE "Pictures\iCloud Photos\Photos"),
        (Join-Path $env:USERPROFILE "Pictures\iCloud Photos\Uploads"),
        (Join-Path $env:USERPROFILE "iCloudPhotos\Uploads"))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return ""
}

function New-CameraProfile([string]$name) {
    [ordered]@{
        name           = $name
        match          = [ordered]@{
            serials   = @()     # volume serial(s) of this exact card, e.g. "1A2B3C4D"
            exifModel = ""      # regex against the camera model stored in the first JPEG
            exifMake  = ""      # regex against the camera maker, e.g. "^Canon$" (brand presets)
            fileNames = ""      # regex against file names on the card, e.g. "^KIF_\d{4}"
            drive     = ""      # a drive letter, e.g. "A:" - anything in that drive is this camera's
            content   = ""      # catch-all: "photos", "videos" (videos only) or "any"
        }
        destination    = ""          # where finished media goes; "" = library\<name>\Media
        naming         = "{name} ({n})" # file name pattern - see Format-FileBase for the {tokens}
        prefix         = $name       # what {name} becomes in file names
        dates          = "capture"   # "capture" = keep the camera's clock, "import" = stamp today,
                                     # "auto" = keep it unless it looks wrong (see staleDays)
        staleDays      = 365         # "auto": a date older than this many days, or in the future, counts as wrong
        deleteFromCard = $false      # only ever after a verified copy
        convertVideo   = $true       # AVI/MPG/MTS/ASF... -> MP4 (original kept locally)
        rawMode        = "local"     # "local" = RAW stays on this PC + a JPG goes out, "copy" = send the RAW itself
        review         = "ask"       # after an import: "ask" to open the review window, "always" open it, "never"
        autoStart      = $false      # $true = start importing this camera's cards without asking first
        photoHook      = ""          # advanced: command run on every staged JPG, {file} = its path
        kind           = "card"      # "card" = Camera Ingest imports it; "special" = a camera with its own
                                     # importer (Wi-Fi, cable...) that Camera Ingest lists and launches
        program        = ""          # special: the importer to run - a .bat, .cmd, .ps1 or .exe
        arguments      = ""          # special: what to pass it
        about          = ""          # special: one line on how this camera's photos come in
    }
}

function Test-SpecialCamera($cam) { [string]$cam.kind -eq "special" }

function Get-SpecialLaunch($cam) {
    # how to start a special camera's importer: @{ exe; args; dir }, in its own folder
    $p = [string]$cam.program
    $dir = Split-Path -Parent $p
    switch -Regex ([System.IO.Path]::GetExtension($p).ToLower()) {
        '^\.ps1$'        { return @{ exe = "powershell.exe"; args = "-NoProfile -ExecutionPolicy Bypass -File `"$p`" $($cam.arguments)".Trim(); dir = $dir } }
        '^\.(bat|cmd)$'  {
            # cmd's own rule: /c "<quoted program> <arguments>" - the outer quotes wrap the whole line
            $line = ("`"$p`" " + [string]$cam.arguments).Trim()
            return @{ exe = "cmd.exe"; args = "/c `"$line`""; dir = $dir }
        }
        default          { return @{ exe = $p; args = [string]$cam.arguments; dir = $dir } }
    }
}

function Start-SpecialCamera($cam) {
    # opens the camera's own importer in its own window; returns the process (or throws)
    if (-not $cam.program -or -not (Test-Path -LiteralPath $cam.program)) { throw "Can't find its importer: $($cam.program)" }
    $l = Get-SpecialLaunch $cam
    if ($l.args) { return (Start-Process -FilePath $l.exe -ArgumentList $l.args -WorkingDirectory $l.dir -PassThru) }
    return (Start-Process -FilePath $l.exe -WorkingDirectory $l.dir -PassThru)
}

# ------------------------------------------------------------
#  File naming patterns
#    {name}  the camera's name label      {orig}  the camera's own file name
#    {n}     running count (1, 2, 3...)   {n:4}   zero-padded (0001, 0002...)
#    {date}  2026-06-15   {time} 14-30-05   {year} {month} {day} {hour} {minute} {second}
#  Dates are when the photo was taken (or the import date for a wrong-clock camera).
#  A name that's already taken gets _2, _3... - nothing is ever overwritten.
# ------------------------------------------------------------

$script:NamingStyles = [ordered]@{
    "count"      = "{name} ({n})"
    "datetime"   = "{date} {time}"
    "date-count" = "{date} {name} ({n})"
    "keep"       = "{orig}"
}

function Get-NamingPattern($cam) {
    # older configs said "sequential" / "keep" before patterns existed
    switch ($cam.naming) {
        "sequential" { return $script:NamingStyles["count"] }
        "keep"       { return $script:NamingStyles["keep"] }
        ""           { return $script:NamingStyles["count"] }
        $null        { return $script:NamingStyles["count"] }
    }
    return [string]$cam.naming
}

function Test-PatternCounts([string]$pattern) { $pattern -match '\{n(:\d+)?\}' }

function Format-FileBase([string]$pattern, [string]$name, [int]$n, [datetime]$when, [string]$orig) {
    $out = [regex]::Replace($pattern, '\{(\w+)(?::(\d+))?\}', {
        param($m)
        $width = 0; if ($m.Groups[2].Success) { $width = [int]$m.Groups[2].Value }
        switch ($m.Groups[1].Value.ToLower()) {
            "name"   { $name }
            "orig"   { $orig }
            "n"      { if ($width -gt 0) { $n.ToString("D$width") } else { "$n" } }
            "date"   { $when.ToString("yyyy-MM-dd") }
            "time"   { $when.ToString("HH-mm-ss") }
            "year"   { $when.ToString("yyyy") }
            "month"  { $when.ToString("MM") }
            "day"    { $when.ToString("dd") }
            "hour"   { $when.ToString("HH") }
            "minute" { $when.ToString("mm") }
            "second" { $when.ToString("ss") }
            default  { $m.Value }
        }
    })
    $out = ($out -replace '[\\/:*?"<>|]', '_').Trim().TrimEnd('.')
    if (-not $out) { $out = $orig }
    return $out
}

function Get-PatternRegex([string]$pattern, [string]$name) {
    # A regex matching names THIS camera's pattern produces, with {n} captured - used to find
    # the highest number already handed out, so counting continues across imports. {name} is
    # matched literally, so two cameras sharing a folder never bump each other's count.
    $shapes = @{ date = '\d{4}-\d{2}-\d{2}'; time = '\d{2}-\d{2}-\d{2}'; year = '\d{4}'
                 month = '\d{2}'; day = '\d{2}'; hour = '\d{2}'; minute = '\d{2}'; second = '\d{2}' }
    $rx = '^'
    foreach ($part in [regex]::Split($pattern, '(\{\w+(?::\d+)?\})')) {
        if (-not $part) { continue }
        if ($part -match '^\{n(:\d+)?\}$') { $rx += '(?<n>\d+)' }
        elseif ($part -match '^\{(\w+)(:\d+)?\}$') {
            $tag = $Matches[1].ToLower()
            if ($tag -eq "name") { $rx += [regex]::Escape(($name -replace '[\\/:*?"<>|]', '_')) }
            elseif ($shapes.ContainsKey($tag)) { $rx += $shapes[$tag] }
            else { $rx += '.+' }     # {orig}: greedy, so in "{orig}_{n}" the LAST number is the count
        }
        else { $rx += [regex]::Escape(($part -replace '[\\/:*?"<>|]', '_')) }
    }
    return $rx + '(_\d+)?$'
}

function Test-NamingPattern([string]$pattern) {
    # "" when fine, otherwise what's wrong in plain words
    if (-not $pattern.Trim()) { return "The pattern is empty." }
    foreach ($m in [regex]::Matches($pattern, '\{(\w+)(?::\d+)?\}')) {
        if (@("name", "orig", "n", "date", "time", "year", "month", "day", "hour", "minute", "second") -notcontains $m.Groups[1].Value.ToLower()) {
            return "Unknown tag $($m.Value)."
        }
    }
    if ($pattern -notmatch '\{(n|orig|time|second)(:\d+)?\}') {
        return "Add {n}, {time} or {orig} so each file gets its own name (otherwise most get _2, _3... added)."
    }
    return ""
}

function Get-NamingExample($cam, [string]$pattern = "", $src = $null) {
    # two example names from the card if there is one, otherwise from a made-up shot
    if ((Test-SpecialCamera $cam) -and -not $pattern) { return "Set by external importer" }
    if (-not $pattern) { $pattern = Get-NamingPattern $cam }
    $orig = "DSC00042"; $orig2 = "DSC00043"; $ext = ".JPG"; $when = (Get-Date).Date.AddHours(14).AddMinutes(30).AddSeconds(5)
    $s = @(); if ($src) { $s = @($src.media | Select-Object -First 2) }
    if ($s.Count -gt 0) { $orig = $s[0].BaseName; $ext = $s[0].Extension; $when = $s[0].LastWriteTime; $orig2 = "$orig-2" }
    if ($s.Count -gt 1) { $orig2 = $s[1].BaseName }
    $when = (Get-FileDate $cam $when (Get-Date)).when
    if ($pattern -ne "{orig}") { $ext = $ext.ToUpper() }
    $a = (Format-FileBase $pattern $cam.prefix 1 $when $orig) + $ext
    if (-not (Test-PatternCounts $pattern) -and $pattern -match '\{time\}') { return "$a  (a 2nd shot the same second: ..._2$ext)" }
    $b = (Format-FileBase $pattern $cam.prefix 2 $when.AddSeconds(41) $orig2) + $ext
    if ($a -eq $b) { return "$a, then ..._2$ext, ..._3$ext" }
    return "$a, $b ..."
}

function Get-NamingStyleName($cam) {
    if (Test-SpecialCamera $cam) { return "Set by external importer" }
    $p = Get-NamingPattern $cam
    foreach ($k in $script:NamingStyles.Keys) {
        if ($script:NamingStyles[$k] -eq $p) {
            switch ($k) { "count" { return "Sequential number" } "datetime" { return "Capture date and time" }
                          "date-count" { return "Capture date and sequential number" } "keep" { return "Original camera file name" } }
        }
    }
    return "Custom pattern $p"
}

function Get-ReviewMode($cam) {
    if ($cam.review) { return [string]$cam.review }
    return "ask"
}

function ConvertTo-CameraProfile($obj) {
    # Fill any missing fields with defaults so older/hand-edited configs keep working
    $p = New-CameraProfile ([string]$obj.name)
    foreach ($k in @($p.Keys)) {
        if ($k -eq "match") { continue }
        if ($null -ne $obj.$k) { $p[$k] = $obj.$k }
    }
    if ($obj.match) {
        foreach ($k in @($p.match.Keys)) {
            if ($null -ne $obj.match.$k) { $p.match[$k] = $obj.match.$k }
        }
    }
    $p.match.serials = @($p.match.serials | Where-Object { $_ } | ForEach-Object { ([string]$_).Replace("-", "").ToUpper() })
    # older configs/presets said "floppy": true for what is now the drive rule
    if ($obj.match -and $obj.match.floppy -eq $true -and -not $p.match.drive) { $p.match.drive = "A:" }
    $p.match.drive = ([string]$p.match.drive).Trim().TrimEnd('\').ToUpper()
    if (-not $p.prefix) { $p.prefix = $p.name }
    # older configs: naming "sequential"/"keep", and a yes/no offerReview instead of review
    $p.naming = Get-NamingPattern $p
    if ($null -eq $obj.review -and $null -ne $obj.offerReview) {
        if ($obj.offerReview) { $p.review = "ask" } else { $p.review = "never" }
    }
    if (@("ask", "always", "never") -notcontains $p.review) { $p.review = "ask" }
    $p.autoStart = [bool]$p.autoStart
    if (@("capture", "import", "auto") -notcontains $p.dates) { $p.dates = "capture" }
    $days = 0; if (-not [int]::TryParse([string]$p.staleDays, [ref]$days) -or $days -lt 1) { $days = 365 }
    $p.staleDays = $days
    return $p
}

function Get-FileDate($cam, [datetime]$taken, [datetime]$now) {
    # The date an imported file should carry, and whether it had to be fixed (= the import time
    # replaces the camera's). "auto" fixes only dates that look wrong: older than the camera's
    # staleDays, or more than a day in the future.
    switch ([string]$cam.dates) {
        "import" { return @{ when = $now; fixed = $true } }
        "auto" {
            $days = [int]$cam.staleDays; if ($days -lt 1) { $days = 365 }
            if ($taken -lt $now.AddDays(-$days) -or $taken -gt $now.AddDays(1)) { return @{ when = $now; fixed = $true } }
        }
    }
    return @{ when = $taken; fixed = $false }
}

function Get-DatesText($cam) {
    switch ([string]$cam.dates) {
        "import" { return "Import date (camera clock incorrect)" }
        "auto"   { return "Camera date; import date if older than $($cam.staleDays) days or in the future" }
        default  { return "Camera date" }
    }
}

function New-DefaultConfig {
    [ordered]@{
        version     = 1
        libraryRoot = (Join-Path $env:USERPROFILE "Pictures\Camera Ingest")
        tools       = [ordered]@{ handbrake = ""; ffmpeg = ""; python = "" }
        cameras     = @()
    }
}

function Read-Config([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Host "  The settings file is damaged and couldn't be read:" -ForegroundColor Red
        Write-Host "  $path" -ForegroundColor Red
        Write-Host "  ($($_.Exception.Message))" -ForegroundColor Red
        return $null
    }
    $cfg = New-DefaultConfig
    if ($raw.libraryRoot) { $cfg.libraryRoot = $raw.libraryRoot }
    if ($raw.tools) {
        foreach ($k in @($cfg.tools.Keys)) { if ($raw.tools.$k) { $cfg.tools[$k] = $raw.tools.$k } }
    }
    $cfg.cameras = @($raw.cameras | Where-Object { $_ } | ForEach-Object { ConvertTo-CameraProfile $_ })
    return $cfg
}

function Save-Config($cfg, [string]$path) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # -InputObject keeps one-item arrays as arrays (piping would flatten them)
    $json = ConvertTo-Json -InputObject $cfg -Depth 8
    # write to a temp file first so a crash mid-save can't wipe the config
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# ------------------------------------------------------------
#  Presets - ready-made camera setups, one JSON file each in
#  presets\. Drop a new file in to add one; "Save as a preset"
#  in My cameras writes one you can share.
# ------------------------------------------------------------

function Get-Presets {
    $dir = Join-Path $script:AppRoot "presets"
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try {
            $p = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $p.preset -or -not $p.camera) { continue }
            $out += [ordered]@{
                title       = [string]$p.preset
                description = [string]$p.description
                camera      = $p.camera
                file        = $f.FullName
            }
        } catch {
            Write-Host "  (skipping broken preset file $($f.Name))" -ForegroundColor DarkGray
        }
    }
    return $out
}

function New-CameraFromPreset($preset, [string]$name) {
    # the preset's prefix is only the suggested camera name; files are named after the camera
    $cam = ConvertTo-CameraProfile $preset.camera
    $cam.name = $name
    $cam.prefix = $name
    return $cam
}

function Save-CameraAsPreset($cam, [string]$title, [string]$description, [string]$dir = "") {
    if (-not $dir) { $dir = Join-Path $script:AppRoot "presets" }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $copy = ConvertTo-CameraProfile $cam
    # a shared preset must not carry one person's card serials or folders
    $copy.match.serials = @()
    $copy.destination = ""
    $copy.Remove("name")
    $obj = [ordered]@{ preset = $title; description = $description; camera = $copy }
    $file = Join-Path $dir (($title -replace '[^A-Za-z0-9 _-]', '').Trim().Replace(' ', '-').ToLower() + ".json")
    [System.IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $obj -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    return $file
}

function Get-CameraFolder($cfg, $cam) {
    # every camera keeps its local working folders (staging, originals, ledger) here
    $safe = ($cam.name -replace '[\\/:*?"<>|]', '_').Trim()
    # Path.Combine, not Join-Path: Join-Path errors out when the library's drive is unplugged
    [System.IO.Path]::Combine($cfg.libraryRoot, $safe)
}

function Get-CameraDestination($cfg, $cam) {
    if ($cam.destination) { return $cam.destination }
    [System.IO.Path]::Combine((Get-CameraFolder $cfg $cam), "Media")
}

# ------------------------------------------------------------
#  Tools (all optional - the importer says what it skips)
# ------------------------------------------------------------

function Find-Tool([string]$configured, [string[]]$exeNames, [string[]]$extraPaths) {
    if ($configured -and (Test-Path -LiteralPath $configured)) { return $configured }
    foreach ($p in $extraPaths) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    foreach ($n in $exeNames) {
        $c = Get-Command $n -ErrorAction Ignore | Select-Object -First 1     # Ignore: "not installed" isn't an error
        if ($c -and $c.Source -notmatch 'WindowsApps\\python') { return $c.Source }
    }
    return ""
}

function Get-Tools($cfg) {
    $ErrorActionPreference = "Continue"
    $toolsDir = Join-Path $script:AppRoot "tools"
    $wingetLinks = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links"
    $hb = Find-Tool $cfg.tools.handbrake @("HandBrakeCLI.exe") @(
        (Join-Path $toolsDir "HandBrakeCLI.exe"),
        "C:\Program Files\HandBrake\HandBrakeCLI.exe",
        (Join-Path $wingetLinks "HandBrakeCLI.exe"))
    $ff = Find-Tool $cfg.tools.ffmpeg @("ffmpeg.exe") @(
        (Join-Path $toolsDir "ffmpeg.exe"),
        (Join-Path $wingetLinks "ffmpeg.exe"))
    $py = Find-Tool $cfg.tools.python @("python.exe", "py.exe") @()
    $rawpy = $false
    if ($py) {
        try {
            $null = & $py -c "import rawpy, PIL" 2>&1
            $rawpy = ($LASTEXITCODE -eq 0)
        } catch { }
    }
    [ordered]@{ handbrake = $hb; ffmpeg = $ff; python = $py; rawpy = $rawpy }
}

# ------------------------------------------------------------
#  Drives and card identity
# ------------------------------------------------------------

Add-Type -AssemblyName System.Drawing

function Get-ExifInfo([string]$path) {
    # EXIF tag 271 = maker ("Canon", "SONY"), 272 = model ("DSC-T7"); "" when missing
    $out = @{ make = ""; model = "" }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $ms = New-Object System.IO.MemoryStream(,$bytes)
        $img = [System.Drawing.Image]::FromStream($ms, $false, $false)
        try {
            foreach ($t in @(@(271, "make"), @(272, "model"))) {
                if ($img.PropertyIdList -contains $t[0]) {
                    $out[$t[1]] = ([System.Text.Encoding]::ASCII.GetString($img.GetPropertyItem($t[0]).Value)).Trim([char]0).Trim()
                }
            }
        } finally { $img.Dispose(); $ms.Dispose() }
    } catch { }
    return $out
}

function Get-MediaFiles([string]$root) {
    # a card pulled out between being listed and being read: nothing to see, not a crash
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { Get-MediaKind $_.Extension } |
        Where-Object {
            $path = $_.FullName
            -not ($script:SkipFolders | Where-Object { $path -like "*\$_\*" })
        })
}

function Get-SourceInfo([string]$root, [string]$serial = "", [string]$label = "", [bool]$isFloppy = $false) {
    # Everything the matcher needs to know about one card / drive / folder.
    # ($isFloppy: a drive with no usable card serial or eject - A: and B:)
    $media  = Get-MediaFiles $root
    $photos = @($media | Where-Object { @("photo", "raw") -contains (Get-MediaKind $_.Extension) })
    $videos = @($media | Where-Object { @("video", "oldvideo") -contains (Get-MediaKind $_.Extension) })
    $firstJpg = $photos | Where-Object { $_.Extension -match '^\.jpe?g$' } | Select-Object -First 1
    $exif = @{ make = ""; model = "" }
    if ($firstJpg) { $exif = Get-ExifInfo $firstJpg.FullName }
    [ordered]@{
        root      = $root
        serial    = $serial.Replace("-", "").ToUpper()
        label     = $label
        isFloppy  = $isFloppy
        drive     = $(if ($root -match '^([A-Za-z]:)\\?$') { $Matches[1].ToUpper() } else { "" })
        media     = $media
        photos    = $photos
        videos    = $videos
        exifMake  = $exif.make
        exifModel = $exif.model
        sizeMB    = [math]::Round((($media | Measure-Object Length -Sum).Sum) / 1MB, 1)
    }
}

function Get-PluggedInSources {
    # Removable drives: card readers (SD, CF, Memory Stick...), USB drives, A:/B:.
    # Cameras that show up as "portable devices" (MTP) have no drive letter and aren't seen.
    $out = @()
    $disks = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne "Removable") { continue }
        if (-not $d.IsReady) { continue }
        $letter = $d.Name.TrimEnd('\')
        $serial = [string](($disks | Where-Object { $_.DeviceID -eq $letter } | Select-Object -First 1).VolumeSerialNumber)
        $isFloppy = ($letter -eq "A:" -or $letter -eq "B:")
        $out += Get-SourceInfo $d.Name $serial $d.VolumeLabel $isFloppy
    }
    return $out
}

function Test-CameraIdentity($cam, $src) {
    # Pass 1 rules: something about THIS card/camera specifically. Returns the reason or "".
    $m = $cam.match
    if ($src.serial -and ($m.serials -contains $src.serial)) { return "Card serial $($src.serial)" }
    if ($m.exifModel -and $src.exifModel) {
        try { if ($src.exifModel -match $m.exifModel) { return "Camera model '$($src.exifModel)'" } } catch { }
    }
    if ($m.exifMake -and $src.exifMake) {
        try { if ($src.exifMake -match $m.exifMake) { return "Camera maker '$($src.exifMake)'" } } catch { }
    }
    if ($m.fileNames) {
        try {
            $hit = $src.media | Where-Object { $_.Name -match $m.fileNames } | Select-Object -First 1
            if ($hit) { return "File name pattern ($($hit.Name))" }
        } catch { }
    }
    if ($m.drive -and $src.drive -eq $m.drive) { return "Drive $($m.drive)" }
    return ""
}

function Test-CameraCatchAll($cam, $src) {
    # Pass 2 rules: "any card with photos" style fallbacks
    switch ($cam.match.content) {
        "photos" { if ($src.photos.Count -gt 0) { return "Contains photos" } }
        "videos" { if ($src.photos.Count -eq 0 -and $src.videos.Count -gt 0) { return "Contains only videos" } }
        "any"    { if ($src.media.Count -gt 0) { return "Contains media" } }
    }
    return ""
}

function Find-CameraForSource($cfg, $src) {
    # Specific rules beat catch-alls; within each pass the list order decides.
    # Special cameras have their own importers and never claim a card.
    $cardCams = @($cfg.cameras | Where-Object { -not (Test-SpecialCamera $_) })
    foreach ($cam in $cardCams) {
        $why = Test-CameraIdentity $cam $src
        if ($why) { return @{ camera = $cam; reason = $why } }
    }
    foreach ($cam in $cardCams) {
        $why = Test-CameraCatchAll $cam $src
        if ($why) { return @{ camera = $cam; reason = $why } }
    }
    return $null
}

function Format-Rule([string]$rx) {
    # show a simple "^Exact Name$" rule as plain text; anything fancier as the pattern itself
    $plain = $rx -replace '^\^', '' -replace '\$$', '' -replace '\\(.)', '$1'
    if ($plain -match '^[\w .,+-]+$') {
        if ($rx -match '^\^.*\$$') { return "'$plain'" }
        if ($rx -match '^\^') { return "starting '$plain'" }
        return "containing '$plain'"
    }
    return "matching /$rx/"
}

function Get-MatchSummary($cam) {
    if (Test-SpecialCamera $cam) {
        $how = "External importer"; if ($cam.about) { $how += ": $($cam.about)" }
        return $how
    }
    $m = $cam.match
    $parts = @()
    if ($m.serials.Count -gt 0) { $parts += "Card serial " + ($m.serials -join "/") }
    if ($m.exifModel) { $parts += "Model $(Format-Rule $m.exifModel)" }
    if ($m.exifMake)  { $parts += "Maker $(Format-Rule $m.exifMake)" }
    if ($m.fileNames) { $parts += "File names $(Format-Rule $m.fileNames)" }
    if ($m.drive)     { $parts += "Any media in drive $($m.drive)" }
    switch ($m.content) {
        "photos" { $parts += "Any card containing photos" }
        "videos" { $parts += "Any card containing only videos" }
        "any"    { $parts += "Any card containing media" }
    }
    if ($parts.Count -eq 0) { return "No rules (folder import only)" }
    $parts -join " or "
}

function Invoke-SafeEject([string]$driveRoot) {
    # Software-eject the card so it's safe to pull out
    Write-Host ""
    try {
        $sh = New-Object -ComObject Shell.Application
        $item = $sh.NameSpace(17).ParseName($driveRoot.TrimEnd('\'))
        if (-not $item) { $item = $sh.NameSpace(17).ParseName($driveRoot) }
        if ($item) { $item.InvokeVerb("Eject") }
        Start-Sleep -Seconds 3
        if (-not (Test-Path $driveRoot)) {
            Write-Host "  Card ejected - safe to take out." -ForegroundColor Green
            return
        }
    } catch { }
    Write-Host "  Couldn't confirm the eject - use 'Safely Remove Hardware'" -ForegroundColor Yellow
    Write-Host "  in the system tray before pulling the card." -ForegroundColor Yellow
}

# ------------------------------------------------------------
#  Text-menu helpers
# ------------------------------------------------------------

function Write-Title([string]$text) {
    Write-Host ""
    Write-Host "  ===== $text =====" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Rule { Write-Host "  ---------------------------------------" -ForegroundColor Cyan }

function Read-Choice([string]$prompt, [string[]]$valid, [string]$default = "") {
    # Keep asking until the answer is one of $valid (case-insensitive). Enter = $default.
    while ($true) {
        $hint = ""
        if ($default) { $hint = " [$default]" }
        $a = (Read-Host "  $prompt$hint").Trim()
        if (-not $a -and $default) { return $default.ToUpper() }
        if ($valid -contains $a.ToUpper()) { return $a.ToUpper() }
        Write-Host "  Please type one of: $($valid -join ', ')" -ForegroundColor Yellow
    }
}

function Read-YesNo([string]$prompt, [bool]$default) {
    $d = "N"; if ($default) { $d = "Y" }
    (Read-Choice "$prompt (Y/N)" @("Y", "N") $d) -eq "Y"
}

function Read-Text([string]$prompt, [string]$default = "", [switch]$AllowEmpty) {
    while ($true) {
        $hint = ""
        if ($default) { $hint = " [$default]" }
        $a = (Read-Host "  $prompt$hint").Trim()
        if (-not $a) { $a = $default }
        if ($a -or $AllowEmpty) { return $a }
        Write-Host "  This one can't be blank." -ForegroundColor Yellow
    }
}

function Read-Folder([string]$prompt, [string]$default = "") {
    # Type a path, press Enter for the default, or B for a folder picker window
    while ($true) {
        Write-Host "  $prompt" -ForegroundColor White
        Write-Host "  (type a folder path, B = browse with a window" -NoNewline -ForegroundColor Gray
        if ($default) { Write-Host ", Enter = $default" -NoNewline -ForegroundColor Gray }
        Write-Host ")" -ForegroundColor Gray
        $a = (Read-Host "  Folder").Trim().Trim('"')
        if (-not $a -and $default) { return $default }
        if ($a -eq "B" -or $a -eq "b") {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = $prompt
            if ($default -and (Test-Path -LiteralPath $default)) { $dlg.SelectedPath = $default }
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
            continue
        }
        if ($a) { return $a }
    }
}

function Wait-Key([string]$text = "Press any key to continue") {
    Write-Host ""
    Write-Host "  $text" -ForegroundColor Gray
    if (-not (Test-RealKeyboard)) { Read-Host | Out-Null; return }
    try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Read-Host | Out-Null }
}

function Test-RealKeyboard {
    # single-key prompts need a real console; piped / scheduled / scripted runs use Read-Host
    try { return -not [Console]::IsInputRedirected -and $Host.Name -eq "ConsoleHost" -and -not $global:DriveQueue } catch { return $false }
}

function Read-Key {
    # one key press as a string (" " for SPACE); falls back to a typed line
    if (Test-RealKeyboard) {
        try { return [string]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown").Character } catch { }
    }
    $a = Read-Host "  (type S for SPACE, or just Enter)"
    if ($a -match '^[sS ]') { return " " }
    return ""
}
