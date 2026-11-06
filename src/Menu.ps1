# ============================================================
#  Card Drawer - main menu
#  Everything is set up from here with numbered menus: first-run
#  setup, adding cameras (with the card plugged in, so it can be
#  recognized), editing them, tools, and importing.
# ============================================================
param(
    [string]$ConfigPath = "",
    [string]$Open = ""      # window app: go straight to one screen and close after it -
                            # "setup", "add", "cameras", "camera:<number>", "settings"
)

. (Join-Path $PSScriptRoot "Dispatch.ps1")

if (-not $ConfigPath) { $ConfigPath = Get-DefaultConfigPath }
$Host.UI.RawUI.WindowTitle = $script:AppName

# ------------------------------------------------------------
#  Questions shared by "Add a camera" and "My cameras"
# ------------------------------------------------------------

function Get-NamePattern([string]$fileName) {
    # "KIF_0042.JPG" -> "^KIF_\d{4}" ; "DSC00142.ARW" -> "^DSC\d{5}" ; "" if no letters+digits shape
    $base = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    if ($base -match '^([A-Za-z_\-]+)(\d+)') {
        return '^' + [regex]::Escape($Matches[1]) + '\d{' + $Matches[2].Length + '}'
    }
    return ""
}

function Ask-Destination($cfg, $cam) {
    $icloud = Get-ICloudPhotosFolder
    $default = Join-Path (Get-CameraFolder $cfg $cam) "Media"
    Write-Host ""
    Write-Host "  Where should finished photos and videos for $($cam.name) go?" -ForegroundColor White
    Write-Host "    1  A folder in your library:  $default"
    if ($icloud) {
        Write-Host "    2  iCloud Photos (uploads automatically):  $icloud\$($cam.name) Media"
    } else {
        Write-Host "    2  iCloud Photos  (not found on this PC)" -ForegroundColor DarkGray
    }
    Write-Host "    3  Somewhere else (OneDrive, Google Drive, a NAS, any folder)"
    $c = Read-Choice "Choose 1-3" @("1", "2", "3") "1"
    switch ($c) {
        "1" { $cam.destination = "" }
        "2" {
            if (-not $icloud) {
                Write-Host "  iCloud for Windows isn't set up here, so using the library folder." -ForegroundColor Yellow
                $cam.destination = ""
            } else {
                $cam.destination = Join-Path $icloud "$($cam.name) Media"
                Write-Host "  Note: iCloud uploads a file the moment it lands there. That's why photos" -ForegroundColor Gray
                Write-Host "  wait in a local Incoming folder until you've had the chance to rotate or delete them." -ForegroundColor Gray
            }
        }
        "3" { $cam.destination = Read-Folder "Pick the folder for $($cam.name)'s finished media" }
    }
}

function Ask-Naming($cam, $src = $null) {
    Write-Host ""
    Write-Host "  How should files be named?" -ForegroundColor White
    if ($src -and $src.media.Count -gt 0) { Write-Host "  (examples use the first file on your card)" -ForegroundColor Gray }
    $keys = @($script:NamingStyles.Keys)
    $labels = @("Running count", "Date and time taken", "Date + running count", "Camera's own names")
    for ($i = 0; $i -lt $keys.Count; $i++) {
        Write-Host ("    {0}  {1,-22} {2}" -f ($i + 1), $labels[$i], (Get-NamingExample $cam $script:NamingStyles[$keys[$i]] $src))
    }
    Write-Host "    5  Custom pattern         mix the pieces yourself, e.g. {date}_{name}_{n:4}"
    $cur = Get-NamingPattern $cam
    $d = "5"
    for ($i = 0; $i -lt $keys.Count; $i++) { if ($script:NamingStyles[$keys[$i]] -eq $cur) { $d = "$($i + 1)" } }
    $c = Read-Choice "Choose 1-5" @("1", "2", "3", "4", "5") $d
    if ($c -eq "5") {
        Write-Host ""
        Write-Host "  Pieces you can use:" -ForegroundColor Gray
        Write-Host "    {name}  the camera's label        {orig}  the camera's own file name" -ForegroundColor Gray
        Write-Host "    {n}     running count 1, 2, 3     {n:4}   padded: 0001, 0002" -ForegroundColor Gray
        Write-Host "    {date}  2026-06-15   {time}  14-30-05   {year} {month} {day} {hour} {minute} {second}" -ForegroundColor Gray
        while ($true) {
            $p = Read-Text "Pattern" $cur
            $problem = Test-NamingPattern $p
            if ($problem -and $problem -match '^Unknown|empty') { Write-Host "  $problem" -ForegroundColor Yellow; continue }
            Write-Host "  Preview: $(Get-NamingExample $cam $p $src)" -ForegroundColor Cyan
            if ($problem) { Write-Host "  Note: $problem" -ForegroundColor Yellow }
            if (Read-YesNo "Use this pattern" $true) { $cam.naming = $p; break }
        }
    } else {
        $cam.naming = $script:NamingStyles[$keys[[int]$c - 1]]
    }
    if ($cam.naming -match '\{name\}') {
        $cam.prefix = (Read-Text "Label used for {name} in file names" $cam.prefix) -replace '[\\/:*?"<>|]', '_'
    }
    if ($cam.dates -ne "capture" -and $cam.naming -match '\{time\}') {
        Write-Host "  (When a date is replaced because the clock is wrong, times in names are the import time.)" -ForegroundColor Gray
    }
    Write-Host "  Files will be named like: $(Get-NamingExample $cam '' $src)" -ForegroundColor Cyan
}

function Ask-Dates($cam) {
    Write-Host ""
    Write-Host "  Is this camera's clock set correctly? Many cameras reset their date when" -ForegroundColor White
    Write-Host "  the battery runs flat, and then every photo comes out dated years ago." -ForegroundColor White
    Write-Host "    1  Clock is right - keep the dates"
    Write-Host "    2  Clock is wrong - always use the import date"
    Write-Host "    3  Fix only dates that look wrong (too old, or in the future)"
    $d = "1"; if ($cam.dates -eq "import") { $d = "2" }; if ($cam.dates -eq "auto") { $d = "3" }
    switch (Read-Choice "Choose 1-3" @("1", "2", "3") $d) {
        "1" { $cam.dates = "capture" }
        "2" { $cam.dates = "import" }
        "3" {
            $cam.dates = "auto"
            Write-Host "  Careful: photos that really are that old (a card left for a long time) would get" -ForegroundColor Gray
            Write-Host "  today's date too. The untouched originals are always kept." -ForegroundColor Gray
            while ($true) {
                $n = 0
                if ([int]::TryParse((Read-Text "Older than how many days counts as wrong" "$($cam.staleDays)"), [ref]$n) -and $n -ge 1) { $cam.staleDays = $n; break }
                Write-Host "  Type a number of days, like 365." -ForegroundColor Yellow
            }
        }
    }
}

function Ask-Delete($cam) {
    Write-Host ""
    Write-Host "  After each file is copied AND checked (SHA256 fingerprint match), should" -ForegroundColor White
    Write-Host "  it be deleted from the card? No = the card is never changed." -ForegroundColor White
    $cam.deleteFromCard = Read-YesNo "Delete from the card after a verified copy" ([bool]$cam.deleteFromCard)
}

function Ask-Video($cam) {
    Write-Host ""
    Write-Host "  Convert video formats that phones and photo clouds can't play (AVI, MPG," -ForegroundColor White
    Write-Host "  MTS, ASF, WMV, 3GP) to MP4? The original is kept in this PC's library." -ForegroundColor White
    $cam.convertVideo = Read-YesNo "Convert those videos to MP4" ([bool]$cam.convertVideo)
}

function Ask-Raw($cam) {
    Write-Host ""
    Write-Host "  RAW photos (ARW, NEF, CR2, DNG...):" -ForegroundColor White
    $best = ""; if (Get-ICloudPhotosFolder) { $best = "  (best for iCloud / Google Photos)" }
    Write-Host "    1  Keep the RAW on this PC, send a full-size JPG$best"
    Write-Host "    2  Send the RAW file itself to the destination"
    $d = "1"; if ($cam.rawMode -eq "copy") { $d = "2" }
    if ((Read-Choice "Choose 1-2" @("1", "2") $d) -eq "2") { $cam.rawMode = "copy" } else { $cam.rawMode = "local" }
}

function Ask-Review($cam) {
    Write-Host ""
    Write-Host "  Cameras without a tilt sensor save sideways shots sideways," -ForegroundColor White
    Write-Host "  and every card has a few duds." -ForegroundColor White
    Write-Host "  After each import, before anything goes out, a review window can show the new" -ForegroundColor White
    Write-Host "  photos (R/L to rotate, D to delete, Enter for next)." -ForegroundColor White
    Write-Host "    1  Ask me each time  (type R to open it, Enter to skip)"
    Write-Host "    2  Always open it"
    Write-Host "    3  Never - send photos straight on"
    $d = "1"; if ($cam.review -eq "always") { $d = "2" }; if ($cam.review -eq "never") { $d = "3" }
    switch (Read-Choice "Choose 1-3" @("1", "2", "3") $d) {
        "1" { $cam.review = "ask" }
        "2" { $cam.review = "always" }
        "3" { $cam.review = "never" }
    }
}

function Ask-AutoStart($cam) {
    Write-Host ""
    Write-Host "  When this camera's card is recognized, start right away? Yes = no 'Press Enter" -ForegroundColor White
    Write-Host "  to start' question for this camera. (You still see what it found and what it does.)" -ForegroundColor White
    $cam.autoStart = Read-YesNo "Start this camera's imports without asking" ([bool]$cam.autoStart)
}

function Select-Source([string]$why) {
    # Pick one plugged-in card, or a folder to stand in for one. Returns $null for "no card".
    while ($true) {
        $sources = @(Get-PluggedInSources)
        Write-Host ""
        if ($sources.Count -eq 0) {
            Write-Host "  No memory card or USB drive is plugged in." -ForegroundColor Yellow
        } else {
            Write-Host "  Plugged in right now:" -ForegroundColor White
            for ($i = 0; $i -lt $sources.Count; $i++) {
                Write-Host -NoNewline ("    {0} " -f ($i + 1))
                Show-SourceLine $sources[$i]
            }
        }
        Write-Host ""
        Write-Host "    R  Rescan (plug the card in first)"
        Write-Host "    F  Use a folder of this camera's photos instead"
        Write-Host "    S  Skip - set it up without a card"
        $valid = @("R", "F", "S") + @(1..([math]::Max($sources.Count, 1)) | ForEach-Object { "$_" })
        $c = Read-Choice "$why - choose" $valid
        if ($c -eq "R") { continue }
        if ($c -eq "S") { return $null }
        if ($c -eq "F") {
            $folder = Read-Folder "Pick a folder of photos from this camera"
            if (-not (Test-Path -LiteralPath $folder)) { Write-Host "  That folder doesn't exist." -ForegroundColor Yellow; continue }
            return (Get-SourceInfo $folder)
        }
        $idx = [int]$c - 1
        if ($idx -lt $sources.Count) { return $sources[$idx] }
    }
}

function Set-RulesFromSource($cam, $src) {
    # Offer each way this card/camera could be recognized; specific rules first
    $m = $cam.match
    if ($src.isFloppy) {
        # A:/B: have no card serial to learn, so the drive letter itself is the rule
        if (Read-YesNo "Recognize anything put in drive $($src.drive) as $($cam.name)" $true) { $m.drive = $src.drive }
    }
    if ($src.serial -and -not $src.isFloppy) {
        Write-Host ""
        Write-Host "  This card's serial number is $($src.serial). It changes if the card is formatted" -ForegroundColor Gray
        Write-Host "  in a computer (formatting in the camera usually keeps it)." -ForegroundColor Gray
        if (Read-YesNo "Recognize THIS card by its serial number" $true) {
            if ($m.serials -notcontains $src.serial) { $m.serials = @($m.serials) + $src.serial }
        }
    }
    if ($src.exifModel) {
        Write-Host ""
        Write-Host "  The photos say they came from a '$($src.exifModel)'." -ForegroundColor Gray
        if (Read-YesNo "Recognize ANY card with photos from a '$($src.exifModel)'" $true) {
            $m.exifModel = '^' + ([regex]::Escape($src.exifModel) -replace '\\ ', ' ') + '$'
        }
    }
    $sample = $src.media | Select-Object -First 1
    if ($sample) {
        $pat = Get-NamePattern $sample.Name
        if ($pat) {
            Write-Host ""
            Write-Host "  Files on this card are named like $($sample.Name). Many cameras share the" -ForegroundColor Gray
            Write-Host "  same style (lots of Sonys use DSC0xxxx), so only say yes if it's unusual." -ForegroundColor Gray
            if (Read-YesNo "Also recognize cards with files named like $($sample.Name)" $false) {
                $m.fileNames = $pat
            }
        }
    }
}

function Ask-CatchAll($cam) {
    Write-Host ""
    Write-Host "  Should $($cam.name) also catch cards that match none of your cameras?" -ForegroundColor White
    Write-Host "  (Only one camera should do this. Specific rules always win over this one.)" -ForegroundColor Gray
    Write-Host "    1  No"
    Write-Host "    2  Yes - any unknown card with photos on it"
    Write-Host "    3  Yes - any unknown card with ONLY videos on it (dashcams, DVRs)"
    $d = "1"
    if ($cam.match.content -eq "photos") { $d = "2" }
    if ($cam.match.content -eq "videos") { $d = "3" }
    switch (Read-Choice "Choose 1-3" @("1", "2", "3") $d) {
        "1" { $cam.match.content = "" }
        "2" { $cam.match.content = "photos" }
        "3" { $cam.match.content = "videos" }
    }
}

function Show-CameraSummary($cfg, $cam, [switch]$Numbered) {
    # The camera's whole profile, one line per setting. Numbered, it IS the edit menu:
    # the number on each line is the key that changes it.
    $d = Get-DatesText $cam
    $x = "never - the card is left alone"; if ($cam.deleteFromCard) { $x = "yes, after each verified copy" }
    $v = "copied as they are"; if ($cam.convertVideo) { $v = "AVI/MPG/MTS... converted to MP4" }
    $r = "kept on this PC, a JPG goes out"; if ($cam.rawMode -eq "copy") { $r = "sent as they are" }
    $o = @{ ask = "ask after each import"; always = "always open the review window"; never = "never - send straight on" }[(Get-ReviewMode $cam)]
    $s = "ask 'Press Enter to start'"; if ($cam.autoStart) { $s = "start right away when the card is recognized" }
    $lines = @(
        @("Recognized by", (Get-MatchSummary $cam)),
        @("Goes to",       (Get-CameraDestination $cfg $cam)),
        @("File names",    "$(Get-NamingStyleName $cam): $(Get-NamingExample $cam)"),
        @("Dates",         $d),
        @("Delete card",   $x),
        @("Videos",        $v),
        @("RAW files",     $r),
        @("Review",        $o),
        @("Starting",      $s)
    )
    Write-Host ""
    Write-Host "  $($cam.name)" -ForegroundColor Cyan
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $key = "  "; if ($Numbered) { $key = "{0} " -f ($i + 1) }
        Write-Host ("    {0} {1,-14} {2}" -f $key, $lines[$i][0], $lines[$i][1])
    }
    if ($cam.photoHook) { Write-Host "       Photo hook     $($cam.photoHook)" -ForegroundColor DarkGray }
    Write-Host "       Local folder   $(Get-CameraFolder $cfg $cam)" -ForegroundColor DarkGray
}

function Invoke-PracticeRun($cfg, $cam, $src) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $box = Join-Path $cfg.libraryRoot "_Practice Runs\$($cam.name -replace '[\\/:*?"<>|]', '_') $stamp"
    $null = Invoke-CameraImport -Config $cfg -Camera $cam -Source $src -Sandbox $box -FromFolder:(-not $src.serial)
    Write-Host ""
    Write-Host "  Practice copies are in: $box" -ForegroundColor Magenta
    if (Read-YesNo "Open that folder to look" $true) { Start-Process explorer.exe $box }
}

# ------------------------------------------------------------
#  Screens
# ------------------------------------------------------------

function Select-Preset($src) {
    # Offer the ready-made setups; mark the ones that would recognize the plugged-in card
    $presets = @(Get-Presets)
    if ($presets.Count -eq 0) { return $null }
    Write-Title "START FROM A PRESET?"
    Write-Host "  A preset fills in sensible rules for a kind of camera. You can change anything later."
    Write-Host ""
    $identityPick = ""; $fitPick = ""
    for ($i = 0; $i -lt $presets.Count; $i++) {
        $mark = ""
        if ($src) {
            $probe = New-CameraFromPreset $presets[$i] "probe"
            $why = Test-CameraIdentity $probe $src
            if (-not $why) { $why = Test-CameraCatchAll $probe $src }
            if ($why) {
                $mark = "   <- fits this card ($why)"
                # default = first preset that recognizes this exact camera, else the first that fits at all
                if (Test-CameraIdentity $probe $src) { if (-not $identityPick) { $identityPick = "$($i + 1)" } }
                elseif (-not $fitPick) { $fitPick = "$($i + 1)" }
            }
        }
        Write-Host ("    {0,2}  {1}{2}" -f ($i + 1), $presets[$i].title, $mark) -ForegroundColor White
    }
    $default = "C"
    if ($identityPick) { $default = $identityPick } elseif ($fitPick) { $default = $fitPick }
    Write-Host "     C  Custom - answer every question myself"
    Write-Host "     I  Info - read what a preset does"
    $valid = @("C", "I") + @(1..$presets.Count | ForEach-Object { "$_" })
    while ($true) {
        $c = Read-Choice "Choose" $valid $default
        if ($c -eq "C") { return $null }
        if ($c -eq "I") {
            $n = Read-Choice "Which preset number" (@(1..$presets.Count | ForEach-Object { "$_" }))
            $p = $presets[[int]$n - 1]
            Write-Host ""
            Write-Host "  $($p.title)" -ForegroundColor Cyan
            Write-Host "  $($p.description)"
            Write-Host "  Recognizes: $(Get-MatchSummary (New-CameraFromPreset $p 'x'))" -ForegroundColor Gray
            Write-Host ""
            continue
        }
        return $presets[[int]$c - 1]
    }
}

function Add-FromPreset($cfg, $preset, [string]$name, $src) {
    $cam = New-CameraFromPreset $preset $name
    Write-Title "$($name.ToUpper()) - FROM PRESET '$($preset.title.ToUpper())'"
    Write-Host "  $($preset.description)"
    # Without its own rule (e.g. the dead-clock preset), learn one from the card
    $hasRule = -not ((Get-MatchSummary $cam) -like "No rules*")
    if ($src) {
        $fits = (Test-CameraIdentity $cam $src) -or (Test-CameraCatchAll $cam $src)
        if (-not $hasRule -or -not $fits) {
            Write-Host ""
            Write-Host "  The preset's rules don't pick out this card on their own - let's add one." -ForegroundColor Gray
            Set-RulesFromSource $cam $src
        } elseif ($src.serial -and -not $src.isFloppy) {
            Write-Host ""
            Write-Host "  Tip: adding this exact card's serial means it's recognized even if another" -ForegroundColor Gray
            Write-Host "  camera's rule would also match it." -ForegroundColor Gray
            if (Read-YesNo "Also recognize THIS card by its serial number ($($src.serial))" $false) {
                $cam.match.serials = @($cam.match.serials) + $src.serial
            }
        }
    } elseif (-not $hasRule) {
        Write-Host ""
        Write-Host "  This preset has no recognition rule of its own. Plug a card in later and use" -ForegroundColor Yellow
        Write-Host "  My cameras > Recognition rules > Learn from a plugged-in card." -ForegroundColor Yellow
    }
    # The choices people care most about are always asked; the rest come from the preset
    # and are shown for a yes/no. Deleting from the card is never taken silently.
    Ask-Destination $cfg $cam
    Ask-Naming $cam $src
    Ask-Delete $cam
    Ask-AutoStart $cam
    Show-CameraSummary $cfg $cam
    Write-Host ""
    if (Read-YesNo "Save it with these settings" $true) {
        Complete-NewCamera $cfg $cam $src -Confirmed
        return
    }
    Ask-Dates $cam; Ask-Video $cam; Ask-Raw $cam; Ask-Review $cam
    Complete-NewCamera $cfg $cam $src
}

function Add-CameraWizard($cfg) {
    Write-Title "ADD A CAMERA"
    Write-Host "  Put one of this camera's memory cards in your card reader so it can be"
    Write-Host "  recognized next time. No card handy? Choose S."
    $src = Select-Source "Which one is this camera's"
    $preset = Select-Preset $src

    $suggest = ""
    if ($src -and $src.exifModel) { $suggest = $src.exifModel }
    elseif ($preset -and $preset.camera.prefix) { $suggest = $preset.camera.prefix }
    Write-Host ""
    while ($true) {
        $name = Read-Text "Give this camera a short name (e.g. 'Sony T7', 'Dashcam')" $suggest
        $name = ($name -replace '[\\/:*?"<>|]', '').Trim()
        if (-not $name) { continue }
        if ($cfg.cameras | Where-Object { $_.name -eq $name }) {
            Write-Host "  You already have a camera called '$name'." -ForegroundColor Yellow
            continue
        }
        break
    }
    if ($preset) {
        Add-FromPreset $cfg $preset $name $src
        return
    }
    $cam = New-CameraProfile $name

    Write-Title "HOW TO RECOGNIZE $($name.ToUpper())"
    if ($src) { Set-RulesFromSource $cam $src }
    Ask-CatchAll $cam
    if ((Get-MatchSummary $cam) -like "No rules*") {
        Write-Host ""
        Write-Host "  No recognition rule was picked, so this camera will only be used when you" -ForegroundColor Yellow
        Write-Host "  choose it yourself from 'Import from a folder'. Add rules any time in My cameras." -ForegroundColor Yellow
    }

    Write-Title "WHAT TO DO WITH $($name.ToUpper())'S FILES"
    Ask-Destination $cfg $cam
    Ask-Dates $cam
    Ask-Naming $cam $src
    Ask-Delete $cam
    Ask-Video $cam
    if (-not $src -or @($src.media | Where-Object { (Get-MediaKind $_.Extension) -eq "raw" }).Count -gt 0) { Ask-Raw $cam }
    Ask-Review $cam
    Ask-AutoStart $cam

    Complete-NewCamera $cfg $cam $src
}

function Complete-NewCamera($cfg, $cam, $src, [switch]$Confirmed) {
    if (-not $Confirmed) {
        Write-Title "CHECK IT OVER"
        Show-CameraSummary $cfg $cam
        Write-Host ""
    }
    if (-not $Confirmed -and -not (Read-YesNo "Save this camera" $true)) {
        Write-Host "  Not saved." -ForegroundColor Yellow
        return
    }
    $cfg.cameras = @($cfg.cameras) + ,$cam
    Save-Config $cfg $ConfigPath
    Write-Host "  Saved. $($cam.name) is ready." -ForegroundColor Green

    if ($src) {
        $hit = Find-CameraForSource $cfg $src
        if ($hit -and $hit.camera.name -ne $cam.name) {
            Write-Host "  Heads up: this card is still claimed by '$($hit.camera.name)' ($($hit.reason))," -ForegroundColor Yellow
            Write-Host "  which is higher in the list. Move $($cam.name) up in My cameras if that's wrong." -ForegroundColor Yellow
        }
    }
    if ($src -and $src.media.Count -gt 0) {
        Write-Host ""
        Write-Host "  Want a practice run? It copies this card into a practice folder so you can" -ForegroundColor White
        Write-Host "  see the names and dates. The card is NOT changed and nothing is uploaded." -ForegroundColor White
        if (Read-YesNo "Do a practice run now" $true) { Invoke-PracticeRun $cfg $cam $src }
    }
}

function Edit-RulesMenu($cfg, $cam) {
    while ($true) {
        Write-Title "RECOGNITION RULES: $($cam.name.ToUpper())"
        Write-Host "  Now: $(Get-MatchSummary $cam)"
        Write-Host ""
        Write-Host "    1  Learn from a plugged-in card (serial / camera model / file names)"
        Write-Host "    2  Forget all card serials ($($cam.match.serials.Count) saved)"
        Write-Host "    3  Camera model rule      [$($cam.match.exifModel)]"
        Write-Host "    4  File name rule         [$($cam.match.fileNames)]"
        Write-Host "    5  Drive letter rule      [$($cam.match.drive)]"
        Write-Host "    6  Catch-all for unknown cards"
        Write-Host "    B  Back"
        switch (Read-Choice "Choose" @("1", "2", "3", "4", "5", "6", "B")) {
            "1" { $s = Select-Source "Which card"; if ($s) { Set-RulesFromSource $cam $s } }
            "2" { $cam.match.serials = @() }
            "3" {
                Write-Host "  Type part of the model name as it appears in the photos (e.g. DSC-T7)," -ForegroundColor Gray
                Write-Host "  or leave blank to remove the rule. (Advanced: this is a regular expression.)" -ForegroundColor Gray
                $cam.match.exifModel = Read-Text "Camera model" $cam.match.exifModel -AllowEmpty
            }
            "4" {
                Write-Host "  Example: ^KIF_ matches KIF_0001.JPG. Blank = remove. (Regular expression.)" -ForegroundColor Gray
                $cam.match.fileNames = Read-Text "File name rule" $cam.match.fileNames -AllowEmpty
            }
            "5" {
                Write-Host "  Anything put in this drive belongs to this camera - for a reader that" -ForegroundColor Gray
                Write-Host "  always gets the same letter. Blank = remove the rule." -ForegroundColor Gray
                $dl = (Read-Text "Drive letter (e.g. A:)" $cam.match.drive -AllowEmpty).Trim().TrimEnd('\').ToUpper()
                if ($dl -match '^[A-Z]$') { $dl += ":" }
                if ($dl -eq "" -or $dl -match '^[A-Z]:$') { $cam.match.drive = $dl } else { Write-Host "  That isn't a drive letter." -ForegroundColor Yellow }
            }
            "6" { Ask-CatchAll $cam }
            "B" { return }
        }
        Save-Config $cfg $ConfigPath
    }
}

function Edit-SpecialCameraMenu($cfg, [int]$index) {
    # a camera with its own importer: show what it runs, start it, or remove it
    while ($true) {
        $cam = $cfg.cameras[$index]
        Write-Title "$($cam.name.ToUpper()) (ITS OWN IMPORTER)"
        Write-Host "  $($cam.about)"
        Write-Host "  Runs:  $($cam.program) $($cam.arguments)" -ForegroundColor Gray
        if ($cam.destination) { Write-Host "  Photos end up in: $($cam.destination)" -ForegroundColor Gray }
        Write-Host ""
        Write-Host "    R  Run its importer now"
        Write-Host "    X  Remove this camera from the list"
        Write-Host "    B  Back"
        switch (Read-Choice "Choose" @("R", "X", "B")) {
            "R" {
                try { $p = Start-SpecialCamera $cam; Write-Host "  Started in its own window." -ForegroundColor Green }
                catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Red }
            }
            "X" {
                if (Read-YesNo "Remove $($cam.name) from the list (its own program and files stay)" $false) {
                    $cfg.cameras = @($cfg.cameras | Where-Object { $_ -ne $cam })
                    Save-Config $cfg $ConfigPath
                    return
                }
            }
            "B" { return }
        }
    }
}

function Edit-CameraMenu($cfg, [int]$index) {
    if (Test-SpecialCamera $cfg.cameras[$index]) { Edit-SpecialCameraMenu $cfg $index; return }
    while ($true) {
        $cam = $cfg.cameras[$index]
        Write-Title "EDIT: $($cam.name.ToUpper())"
        Write-Host "  Type a setting's number to change it. Changes save as you go."
        Show-CameraSummary $cfg $cam -Numbered
        Write-Host ""
        Write-Host "    N  Rename this camera        T  Test against plugged-in cards"
        Write-Host "    P  Practice run              O  Open its folders"
        Write-Host "    U  Move up the list          S  Save as a preset (to share or reuse)"
        Write-Host "    X  Remove this camera        B  Back"
        $c = Read-Choice "Choose" @("1", "2", "3", "4", "5", "6", "7", "8", "9", "N", "T", "P", "O", "U", "X", "S", "B")
        switch ($c) {
            "1" { Edit-RulesMenu $cfg $cam }
            "2" { Ask-Destination $cfg $cam }
            "3" { Ask-Naming $cam }
            "4" { Ask-Dates $cam }
            "5" { Ask-Delete $cam }
            "6" { Ask-Video $cam }
            "7" { Ask-Raw $cam }
            "8" { Ask-Review $cam }
            "9" { Ask-AutoStart $cam }
            "N" {
                $old = Get-CameraFolder $cfg $cam
                $new = (Read-Text "New name" $cam.name) -replace '[\\/:*?"<>|]', ''
                if ($new -and $new -ne $cam.name) {
                    if ($cam.prefix -eq $cam.name -and (Read-YesNo "Also use '$new' in file names (only NEW files; numbering carries on)" $false)) { $cam.prefix = $new }
                    $cam.name = $new
                    $newDir = Get-CameraFolder $cfg $cam
                    if ((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $newDir)) {
                        Move-Item -LiteralPath $old -Destination $newDir
                        Write-Host "  Moved its local folder to $newDir" -ForegroundColor Gray
                    }
                }
            }
            "T" {
                $found = $false
                foreach ($s in @(Get-PluggedInSources)) {
                    $found = $true
                    $hit = Find-CameraForSource $cfg $s
                    if ($hit -and $hit.camera.name -eq $cam.name) {
                        Write-Host "  $($s.root): YES - recognized as $($cam.name) by $($hit.reason)" -ForegroundColor Green
                    } elseif ($hit) {
                        Write-Host "  $($s.root): goes to $($hit.camera.name) instead ($($hit.reason))" -ForegroundColor Yellow
                    } else {
                        Write-Host "  $($s.root): not recognized by any camera" -ForegroundColor Yellow
                    }
                }
                if (-not $found) { Write-Host "  Nothing is plugged in." -ForegroundColor Yellow }
                Wait-Key
            }
            "P" {
                $s = Select-Source "Practice with which card"
                if ($s) { Invoke-PracticeRun $cfg $cam $s }
            }
            "O" {
                $d = Get-CameraDestination $cfg $cam
                if (Test-Path -LiteralPath $d) { Start-Process explorer.exe $d }
                $l = Get-CameraFolder $cfg $cam
                if ((Test-Path -LiteralPath $l) -and $l -ne $d) { Start-Process explorer.exe $l }
                if (-not (Test-Path -LiteralPath $d) -and -not (Test-Path -LiteralPath $l)) { Write-Host "  Nothing imported yet, so no folders exist." -ForegroundColor Yellow }
            }
            "U" {
                if ($index -gt 0) {
                    $list = [System.Collections.ArrayList]@($cfg.cameras)
                    $list.RemoveAt($index); $list.Insert($index - 1, $cam)
                    $cfg.cameras = @($list); $index--
                }
            }
            "X" {
                Write-Host "  This only removes the camera from the list. Imported files, originals" -ForegroundColor Gray
                Write-Host "  and its import history stay where they are." -ForegroundColor Gray
                if (Read-YesNo "Remove $($cam.name)" $false) {
                    $cfg.cameras = @($cfg.cameras | Where-Object { $_ -ne $cam })
                    Save-Config $cfg $ConfigPath
                    return
                }
            }
            "S" {
                Write-Host "  Card serials and your folder choices are left out, so it's safe to share." -ForegroundColor Gray
                $title = Read-Text "Preset title" $cam.name
                $desc = Read-Text "One line saying what it's for" "" -AllowEmpty
                $file = Save-CameraAsPreset $cam $title $desc
                Write-Host "  Saved: $file" -ForegroundColor Green
                Write-Host "  Copy that file into another Card Drawer's presets folder to use it there." -ForegroundColor Gray
            }
            "B" { return }
        }
        Save-Config $cfg $ConfigPath
    }
}

function Show-CamerasMenu($cfg) {
    while ($true) {
        Write-Title "MY CAMERAS"
        if ($cfg.cameras.Count -eq 0) {
            Write-Host "  None yet." -ForegroundColor Yellow
            Wait-Key
            return
        }
        Write-Host "  Checked top to bottom: specific rules first, then catch-alls." -ForegroundColor Gray
        Write-Host ""
        for ($i = 0; $i -lt $cfg.cameras.Count; $i++) {
            $c = $cfg.cameras[$i]
            Write-Host ("    {0}  {1}" -f ($i + 1), $c.name) -ForegroundColor White
            Write-Host ("       {0}" -f (Get-MatchSummary $c)) -ForegroundColor DarkGray
        }
        Write-Host "    B  Back"
        $valid = @("B") + @(1..$cfg.cameras.Count | ForEach-Object { "$_" })
        $c = Read-Choice "Pick a camera to view or change" $valid
        if ($c -eq "B") { return }
        Edit-CameraMenu $cfg ([int]$c - 1)
    }
}

function Install-WithWinget([string]$id, [string]$what) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "  winget (Windows' built-in installer) isn't available on this PC." -ForegroundColor Yellow
        return
    }
    Write-Host "  Installing $what with winget ($id). This downloads it from the official source." -ForegroundColor Gray
    & winget install --exact --id $id --accept-package-agreements --accept-source-agreements
    # pick up PATH changes without restarting
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Show-ToolsMenu($cfg) {
    while ($true) {
        $t = Get-Tools $cfg
        Write-Title "TOOLS (all optional)"
        function Line($label, $path, $use) {
            if ($path) { Write-Host ("    {0,-14} found   {1}" -f $label, $path) -ForegroundColor Green }
            else       { Write-Host ("    {0,-14} missing - {1}" -f $label, $use) -ForegroundColor Yellow }
        }
        Line "HandBrakeCLI" $t.handbrake "best video conversion (ffmpeg alone also works)"
        Line "ffmpeg"       $t.ffmpeg    "video conversion + writing dates inside videos"
        Line "Python"       $t.python    "needed only for RAW photos"
        if ($t.python) {
            if ($t.rawpy) { Write-Host "    rawpy          found   (RAW rendering works)" -ForegroundColor Green }
            else          { Write-Host "    rawpy          missing - RAW photos stay RAW-only until installed" -ForegroundColor Yellow }
        }
        Write-Host ""
        Write-Host "    1  Install HandBrakeCLI   (winget)"
        Write-Host "    2  Install ffmpeg         (winget)"
        Write-Host "    3  Install Python         (winget)"
        Write-Host "    4  Install rawpy          (pip, needs Python)"
        Write-Host "    5  Point to a tool I already have"
        Write-Host "    B  Back"
        switch (Read-Choice "Choose" @("1", "2", "3", "4", "5", "B")) {
            "1" { Install-WithWinget "HandBrake.HandBrake.CLI" "HandBrakeCLI" }
            "2" { Install-WithWinget "Gyan.FFmpeg" "ffmpeg" }
            "3" { Install-WithWinget "Python.Python.3.12" "Python" }
            "4" {
                if (-not $t.python) { Write-Host "  Install Python first." -ForegroundColor Yellow }
                else { & $t.python -m pip install --user rawpy pillow }
            }
            "5" {
                Write-Host "    1 HandBrakeCLI.exe   2 ffmpeg.exe   3 python.exe"
                $w = Read-Choice "Which" @("1", "2", "3")
                $p = (Read-Text "Full path to the .exe").Trim('"')
                if (-not (Test-Path -LiteralPath $p)) { Write-Host "  That file doesn't exist." -ForegroundColor Yellow }
                else {
                    switch ($w) { "1" { $cfg.tools.handbrake = $p } "2" { $cfg.tools.ffmpeg = $p } "3" { $cfg.tools.python = $p } }
                    Save-Config $cfg $ConfigPath
                }
            }
            "B" { return }
        }
    }
}

function Show-SettingsMenu($cfg) {
    while ($true) {
        Write-Title "SETTINGS"
        Write-Host "    1  Library folder   $($cfg.libraryRoot)"
        Write-Host "       (each camera's originals, RAW files, staging and import history live here)" -ForegroundColor DarkGray
        Write-Host "    2  Tools (video conversion, RAW)"
        Write-Host "    3  Open the settings file in Notepad (advanced)"
        Write-Host "    B  Back"
        switch (Read-Choice "Choose" @("1", "2", "3", "B")) {
            "1" {
                Write-Host "  Existing files are NOT moved - move them yourself if you change this." -ForegroundColor Gray
                $cfg.libraryRoot = Read-Folder "Pick the library folder" $cfg.libraryRoot
                Save-Config $cfg $ConfigPath
            }
            "2" { Show-ToolsMenu $cfg }
            "3" {
                Write-Host "  Close Notepad when you're done; changes load the next time you start." -ForegroundColor Gray
                Start-Process notepad.exe $ConfigPath -Wait
                $fresh = Read-Config $ConfigPath
                if ($fresh) { $cfg.libraryRoot = $fresh.libraryRoot; $cfg.tools = $fresh.tools; $cfg.cameras = $fresh.cameras }
            }
            "B" { return }
        }
    }
}

function Show-History($cfg) {
    Write-Title "IMPORT HISTORY"
    foreach ($cam in $cfg.cameras) {
        $ledger = Join-Path (Get-CameraFolder $cfg $cam) "imported_media.csv"
        if (Test-Path -LiteralPath $ledger) {
            $rows = @(Import-Csv -LiteralPath $ledger)
            $last = ($rows | Select-Object -Last 1).ImportDate
            Write-Host ("    {0,-24} {1,6} file(s)   last import {2}" -f $cam.name, $rows.Count, $last)
        } else {
            Write-Host ("    {0,-24}      0 file(s)" -f $cam.name) -ForegroundColor DarkGray
        }
    }
    Wait-Key
}

function Import-FromFolder($cfg) {
    Write-Title "IMPORT FROM A FOLDER"
    Write-Host "  For photos already copied to this PC, a scanned folder, a phone backup..."
    Write-Host "  Nothing in the folder is deleted."
    $folder = Read-Folder "Pick the folder to import"
    if (-not (Test-Path -LiteralPath $folder)) { Write-Host "  That folder doesn't exist." -ForegroundColor Yellow; Wait-Key; return }
    $src = Get-SourceInfo $folder
    if ($src.media.Count -eq 0) { Write-Host "  No photos or videos in there." -ForegroundColor Yellow; Wait-Key; return }
    Write-Host ""
    Write-Host ("  {0} photo(s), {1} video(s), {2} MB" -f $src.photos.Count, $src.videos.Count, $src.sizeMB)
    $hit = Find-CameraForSource $cfg $src
    Write-Host ""
    # only cameras Card Drawer imports itself (not the ones with their own importer)
    $choices = @($cfg.cameras | Where-Object { -not (Test-SpecialCamera $_) })
    if ($choices.Count -eq 0) { Write-Host "  Add a camera first." -ForegroundColor Yellow; Wait-Key; return }
    $d = ""
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $mark = ""
        if ($hit -and $hit.camera.name -eq $choices[$i].name) { $mark = "   <- looks like this one ($($hit.reason))"; $d = "$($i + 1)" }
        Write-Host ("    {0}  {1}{2}" -f ($i + 1), $choices[$i].name, $mark)
    }
    Write-Host "    B  Back"
    $c = Read-Choice "Import as which camera" (@("B") + @(1..$choices.Count | ForEach-Object { "$_" })) $d
    if ($c -eq "B") { return }
    $null = Invoke-CameraImport -Config $cfg -Camera $choices[[int]$c - 1] -Source $src -FromFolder
    Wait-Key
}

function Show-Help {
    Write-Title "HELP"
    @(
        "  HOW IT WORKS"
        "  You teach it each camera once (Add a camera, with its card plugged in)."
        "  After that, 'Import now' looks at every card reader and USB drive,"
        "  works out which camera each card came from, and imports it with that"
        "  camera's rules. Swap cards and press SPACE to keep going."
        ""
        "  HOW CARDS ARE RECOGNIZED (first match wins)"
        "    - the card's serial number (that exact card)"
        "    - the camera model or maker written inside the photos"
        "    - the camera's file naming style (e.g. KIF_0001.JPG)"
        "    - a fixed drive letter (for a reader that always gets the same one)"
        "    - then catch-alls: 'any card with photos' / 'any card with only videos'"
        ""
        "  SAFETY"
        "    - Every file is fingerprinted (SHA256). Nothing ever imports twice, even"
        "      if you put the same card in again months later."
        "    - Files are only deleted from a card if you turned that on for the camera,"
        "      and only after the copy's fingerprint matches. Nothing is ever formatted."
        "    - Photos wait in a local Incoming folder until after the optional review"
        "      review, then go to the destination. Interrupted? The next run finds them."
        "    - Photos deleted in the review go to the Recycle Bin, and they're remembered:"
        "      the same shot on the card won't be imported again next time."
        "    - Practice runs copy into a separate folder and never touch the card."
        ""
        "  NOT SUPPORTED"
        "    - Cameras that connect by USB as a 'portable device' with no drive letter."
        "      Use a card reader. Phones are better served by their own photo apps."
        "    - Mac and Linux (this is Windows PowerShell)."
        ""
        "  Your settings are in: $ConfigPath"
    ) | ForEach-Object { Write-Host $_ }
    Wait-Key
}

function Invoke-FirstRunSetup {
    Write-Title "WELCOME TO $($script:AppName.ToUpper())"
    Write-Host "  This takes about two minutes. Every question has a sensible default -"
    Write-Host "  just press Enter to accept it. The full guide is 'How to use.html' in the"
    Write-Host "  Card Drawer folder (or press G in the main menu)."
    if (Get-ICloudPhotosFolder) { Write-Host "  Read its iCloud section before sending photos to iCloud." }
    Write-Host ""
    $cfg = New-DefaultConfig
    Write-Host "  STEP 1 of 3 - Library folder" -ForegroundColor Cyan
    Write-Host "  Each camera gets a folder here for its originals, RAW files and import"
    Write-Host "  history. Finished photos can go here too, or to any other folder."
    $cfg.libraryRoot = Read-Folder "Where should the library live?" $cfg.libraryRoot
    try { New-Item -ItemType Directory -Path $cfg.libraryRoot -Force -ErrorAction Stop | Out-Null }
    catch { Write-Host "  Couldn't create it ($($_.Exception.Message)) - change it later in Settings." -ForegroundColor Yellow }
    Save-Config $cfg $ConfigPath

    Write-Host ""
    Write-Host "  STEP 2 of 3 - Optional tools" -ForegroundColor Cyan
    $t = Get-Tools $cfg
    $winget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    if ($t.handbrake -or $t.ffmpeg) {
        Write-Host "  Video conversion: ready." -ForegroundColor Green
    } else {
        Write-Host "  Some cameras record AVI / MPG / MTS videos that phones and photo clouds won't play."
        Write-Host "  The free tool ffmpeg converts them to MP4 (about 100 MB, from the official source)."
        if ($winget) {
            if (Read-YesNo "Install ffmpeg now" $true) { Install-WithWinget "Gyan.FFmpeg" "ffmpeg" }
        } else {
            Write-Host "  (Windows' winget installer isn't available - see Settings > Tools to point at ffmpeg.exe.)" -ForegroundColor Yellow
        }
    }
    if ($t.rawpy) {
        Write-Host "  RAW photos: ready." -ForegroundColor Green
    } elseif (Read-YesNo "Do any of your cameras shoot RAW (ARW, NEF, CR2, DNG...)" $false) {
        if (-not $t.python -and $winget) { Install-WithWinget "Python.Python.3.12" "Python" }
        $t = Get-Tools $cfg
        if ($t.python) { & $t.python -m pip install --user rawpy pillow }
        else { Write-Host "  Python isn't available yet - finish this later in Settings > Tools." -ForegroundColor Yellow }
    }
    $t = Get-Tools $cfg
    $v = "copied as-is"; if ($t.handbrake -or $t.ffmpeg) { $v = "converted to MP4" }
    $r = "kept as RAW only"; if ($t.rawpy) { $r = "rendered to JPG" }
    Write-Host "  AVI/MPG-style videos will be $v; RAW photos will be $r. Change any time in Settings." -ForegroundColor Gray

    Write-Host ""
    Write-Host "  STEP 3 of 3 - Your first camera" -ForegroundColor Cyan
    if (Read-YesNo "Add a camera now" $true) { Add-CameraWizard $cfg }
    return $cfg
}

# ------------------------------------------------------------
#  Main
# ------------------------------------------------------------

$cfg = Read-Config $ConfigPath
if (-not $cfg) {
    if (Test-Path -LiteralPath $ConfigPath) {
        Write-Host "  Fix or delete that file, then start again." -ForegroundColor Red
        Wait-Key
        exit 1
    }
    $cfg = Invoke-FirstRunSetup
    if ($Open) { exit 0 }    # the window app asked for setup - it's done
}

if ($Open) {
    switch -Regex ($Open) {
        '^add$'          { Add-CameraWizard $cfg }
        '^cameras$'      { Show-CamerasMenu $cfg }
        '^camera:(\d+)$' { if ([int]$Matches[1] -lt $cfg.cameras.Count) { Edit-CameraMenu $cfg ([int]$Matches[1]) } }
        '^settings$'     { Show-SettingsMenu $cfg }
    }
    exit 0
}

while ($true) {
    Write-Title "$($script:AppName.ToUpper())  v$($script:AppVersion)"
    Write-Host "    1  Import now  (scan everything plugged in)"
    Write-Host "    2  Import from a folder"
    Write-Host "    3  Add a camera"
    Write-Host "    4  My cameras  ($($cfg.cameras.Count))"
    Write-Host "    5  Review a folder of photos (rotate / delete)"
    Write-Host "    6  Import history"
    Write-Host "    7  Settings and tools"
    $gtext = "    G  Guide (opens in your browser)"; if (Get-ICloudPhotosFolder) { $gtext += " - iCloud setup is in there" }
    Write-Host $gtext
    Write-Host "    H  Help"
    Write-Host "    Q  Quit"
    switch (Read-Choice "Choose" @("1", "2", "3", "4", "5", "6", "7", "G", "H", "Q")) {
        "G" { Start-Process (Join-Path $script:AppRoot "How to use.html") }
        "1" { $null = Invoke-ScanAndImport $cfg }
        "2" { if ($cfg.cameras.Count -eq 0) { Write-Host "  Add a camera first." -ForegroundColor Yellow } else { Import-FromFolder $cfg } }
        "3" { Add-CameraWizard $cfg }
        "4" { Show-CamerasMenu $cfg }
        "5" {
            $f = Read-Folder "Which folder of photos?"
            if (Test-Path -LiteralPath $f) {
                Write-Host "  Heads up: if this is a cloud-synced folder, the cloud may keep the old" -ForegroundColor Gray
                Write-Host "  orientation of files it already uploaded." -ForegroundColor Gray
                & (Join-Path $PSScriptRoot "RotateReview.ps1") -Folder $f | Out-Host
            }
        }
        "6" { Show-History $cfg }
        "7" { Show-SettingsMenu $cfg }
        "H" { Show-Help }
        "Q" { exit 0 }
    }
}
