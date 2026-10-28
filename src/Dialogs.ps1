# ============================================================
#  Camera Ingest - point-and-click dialogs (Windows 98 style)
#    Show-CameraDialog   add or change a camera: a property sheet
#                        with General / Recognize / Files / Import
#                        tabs and a live file-name preview
#    Show-SettingsDialog library folder and the optional tools
#    Show-WelcomeDialog  first-time setup
#  Same settings and rules as the text menus (Menu.ps1); both
#  write the same config file. Needs Retro.ps1 + Common.ps1.
# ============================================================

# ------------------------------------------------------------
#  Small builders: every control positioned by hand, the way
#  98-era dialogs were laid out
# ------------------------------------------------------------

function New-DlgLabel([string]$text, [int]$x, [int]$y, [int]$w = 0, [int]$h = 0) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    if ($w -gt 0) { $l.Size = New-Object System.Drawing.Size($w, [math]::Max($h, 16)) } else { $l.AutoSize = $true }
    return $l
}

function New-DlgText([int]$x, [int]$y, [int]$w, [string]$text = "") {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Width = $w
    $t.Text = $text
    return $t
}

function New-DlgRadio([string]$text, [int]$x, [int]$y, [int]$w = 0) {
    $r = New-Object System.Windows.Forms.RadioButton
    $r.Text = $text
    $r.Location = New-Object System.Drawing.Point($x, $y)
    if ($w -gt 0) { $r.Size = New-Object System.Drawing.Size($w, 18) } else { $r.AutoSize = $true }
    return $r
}

function New-DlgCheck([string]$text, [int]$x, [int]$y) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.AutoSize = $true
    return $c
}

function New-DlgGroup([string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $text
    $g.Location = New-Object System.Drawing.Point($x, $y)
    $g.Size = New-Object System.Drawing.Size($w, $h)
    return $g
}

function New-DlgButton([string]$text, [int]$x, [int]$y, [int]$w = 75) {
    $b = New-RetroButton $text $w
    $b.Height = 23
    $b.Location = New-Object System.Drawing.Point($x, $y)
    return $b
}

function New-RetroDialog([string]$title, [int]$width, [int]$height) {
    # a 98 dialog: the shared frame without minimize, centred on its owner
    $win = New-RetroWindow $title $width $height
    $win.form.StartPosition = "CenterParent"
    $win.form.ShowInTaskbar = $false
    $win.buttons["min"].Visible = $false
    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = "Fill"
    $body.Padding = New-Object System.Windows.Forms.Padding(8)
    $win.form.Controls.Add($body)
    $win.form.Controls.Add($win.title)
    $body.BringToFront()
    $win.body = $body
    return $win
}

function Show-Modal($dialog, $owner) {
    # Show a dialog over its owner, then hand focus straight back to the owner. Without
    # this, Windows can give focus to another program when the dialog closes, and the
    # main window drops behind everything as if it had closed.
    $r = $dialog.ShowDialog($owner)
    if ($owner -and -not $owner.IsDisposed) { $owner.Activate() }
    return $r
}

function Show-DlgMessage($owner, [string]$text, [string]$icon = "Information", [string]$buttons = "OK") {
    return [System.Windows.Forms.MessageBox]::Show($owner, $text, "Camera Ingest", $buttons, $icon)
}

function Test-Regex([string]$rx) {
    if (-not $rx) { return $true }
    try { [void][regex]::new($rx); return $true } catch { return $false }
}

function Get-ExactPattern([string]$text) {
    # "DSC-RX100" -> "^DSC-RX100$" (spaces left readable)
    '^' + ([regex]::Escape($text) -replace '\\ ', ' ') + '$'
}

# ============================================================
#  Camera dialog
# ============================================================

function Copy-Camera($cam) {
    # a deep copy to edit, so Cancel leaves the real profile untouched
    ConvertTo-CameraProfile (ConvertFrom-Json (ConvertTo-Json -InputObject $cam -Depth 8))
}

function Read-CameraDialog($s) {
    # everything on all four tabs -> a camera profile
    $c = $s.c
    $cam = Copy-Camera $s.base
    $cam.name = ($c.name.Text -replace '[\\/:*?"<>|]', '').Trim()
    $m = $cam.match
    $m.serials   = @($c.serials.Items | ForEach-Object { [string]$_ })
    $m.exifModel = $c.model.Text.Trim()
    $m.exifMake  = $c.make.Text.Trim()
    $m.fileNames = $c.files.Text.Trim()
    $dl = $c.drive.Text.Trim().TrimEnd('\').ToUpper()
    if ($dl -match '^[A-Z]$') { $dl += ":" }
    $m.drive = $dl
    $m.content = ""
    if ($c.catchPhotos.Checked) { $m.content = "photos" }
    if ($c.catchVideos.Checked) { $m.content = "videos" }

    $cam.destination = ""
    if ($c.destICloud.Checked -and $s.icloud) { $cam.destination = Join-Path $s.icloud "$($cam.name) Media" }
    if ($c.destOther.Checked) { $cam.destination = $c.destPath.Text.Trim().Trim('"') }

    for ($i = 0; $i -lt $s.styleKeys.Count; $i++) {
        if ($c.style[$i].Checked) { $cam.naming = $script:NamingStyles[$s.styleKeys[$i]] }
    }
    if ($c.styleCustom.Checked) { $cam.naming = $c.pattern.Text }
    $cam.prefix = ($c.label.Text -replace '[\\/:*?"<>|]', '_').Trim()
    if (-not $cam.prefix) { $cam.prefix = $cam.name }
    $cam.dates = "capture"
    if ($c.datesImport.Checked) { $cam.dates = "import" }
    if ($c.datesAuto.Checked) { $cam.dates = "auto" }
    $cam.staleDays = [int]$c.staleDays.Value

    $cam.deleteFromCard = $c.deleteCard.Checked
    $cam.convertVideo   = $c.convert.Checked
    $cam.rawMode = "local"; if ($c.rawCopy.Checked) { $cam.rawMode = "copy" }
    $cam.review = "ask"
    if ($c.reviewAlways.Checked) { $cam.review = "always" }
    if ($c.reviewNever.Checked)  { $cam.review = "never" }
    $cam.autoStart = $c.autoStart.Checked
    return $cam
}

function Write-CameraDialog($s, $cam) {
    # a camera profile -> every control (presets and "learn from card" use this too)
    $c = $s.c
    $s.loading = $true
    $c.name.Text = $cam.name
    $m = $cam.match
    $c.serials.Items.Clear(); foreach ($x in $m.serials) { [void]$c.serials.Items.Add($x) }
    $c.model.Text = $m.exifModel; $c.make.Text = $m.exifMake; $c.files.Text = $m.fileNames; $c.drive.Text = $m.drive
    $c.catchNone.Checked = $true
    if ($m.content -eq "photos") { $c.catchPhotos.Checked = $true }
    if ($m.content -eq "videos") { $c.catchVideos.Checked = $true }

    $c.destLibrary.Checked = $true; $c.destPath.Text = ""
    if ($cam.destination) {
        if ($s.icloud -and $cam.destination -eq (Join-Path $s.icloud "$($cam.name) Media")) { $c.destICloud.Checked = $true }
        else { $c.destOther.Checked = $true; $c.destPath.Text = $cam.destination }
    }

    $pattern = Get-NamingPattern $cam
    $c.styleCustom.Checked = $true
    for ($i = 0; $i -lt $s.styleKeys.Count; $i++) {
        if ($script:NamingStyles[$s.styleKeys[$i]] -eq $pattern) { $c.style[$i].Checked = $true }
    }
    $c.pattern.Text = $pattern
    $c.label.Text = $cam.prefix
    switch ([string]$cam.dates) {
        "import" { $c.datesImport.Checked = $true }
        "auto"   { $c.datesAuto.Checked = $true }
        default  { $c.datesCapture.Checked = $true }
    }
    $c.staleDays.Value = [math]::Max(1, [math]::Min(36500, [int]$cam.staleDays))

    $c.deleteCard.Checked = [bool]$cam.deleteFromCard
    $c.convert.Checked = [bool]$cam.convertVideo
    if ($cam.rawMode -eq "copy") { $c.rawCopy.Checked = $true } else { $c.rawLocal.Checked = $true }
    switch (Get-ReviewMode $cam) {
        "always" { $c.reviewAlways.Checked = $true }
        "never"  { $c.reviewNever.Checked = $true }
        default  { $c.reviewAsk.Checked = $true }
    }
    $c.autoStart.Checked = [bool]$cam.autoStart
    $s.base = Copy-Camera $cam
    $s.loading = $false
    Update-CameraDialog $s
}

function Update-CameraDialog($s) {
    # the live bits: name example, recognition summary, enabled/disabled fields
    if ($s.loading) { return }
    $c = $s.c
    # while adding, the {name} label follows the camera name until you type in the label yourself
    if ($s.adding -and -not $s.labelEdited -and $c.label.Text -ne $c.name.Text) {
        $s.loading = $true; $c.label.Text = $c.name.Text; $s.loading = $false
    }
    $cam = Read-CameraDialog $s
    $c.pattern.Enabled = $c.styleCustom.Checked
    if (-not $c.styleCustom.Checked) {
        $s.loading = $true; $c.pattern.Text = Get-NamingPattern $cam; $s.loading = $false
    }
    $c.destPath.Enabled = $c.destOther.Checked; $c.destBrowse.Enabled = $c.destOther.Checked
    $c.label.Enabled = ($cam.naming -match '\{name\}')

    $problem = Test-NamingPattern $cam.naming
    if ($problem -match '^Unknown|empty') {
        $c.preview.ForeColor = $RetroRed
        $c.preview.Text = $problem
    } else {
        $c.preview.ForeColor = $RetroNavy
        $c.preview.Text = Get-NamingExample $cam "" $s.src
        if ($problem) { $c.preview.Text += "`n(" + $problem + ")" }
    }
    $lib = Copy-Camera $cam; $lib.destination = ""          # what "a folder in your library" would be
    $c.libraryPath.Text = Get-CameraDestination $s.cfg $lib
    $c.summary.Text = Get-MatchSummary $cam
    foreach ($pair in @(@($c.model, $c.modelHint), @($c.make, $c.makeHint), @($c.files, $c.filesHint))) {
        if (-not (Test-Regex $pair[0].Text.Trim())) { $pair[1].Text = "Invalid pattern"; $pair[1].ForeColor = $RetroRed }
        elseif ($pair[0].Text.Trim()) { $pair[1].Text = Format-Rule $pair[0].Text.Trim(); $pair[1].ForeColor = $RetroDark }
        else { $pair[1].Text = "(Not used)"; $pair[1].ForeColor = $RetroDark }
    }
}

function Set-DialogSource($s, $src) {
    # learn what we can from the chosen card: its serial, the camera model in its photos,
    # or its drive letter for disk drives without a serial
    $s.src = $src
    $c = $s.c
    if (-not $src) { $c.srcInfo.Text = "No source selected."; Update-CameraDialog $s; return }
    $c.srcInfo.Text = "{0} photos, {1} videos" -f $src.photos.Count, $src.videos.Count
    if ($src.exifModel) { $c.srcInfo.Text += ". Camera model: $($src.exifModel)" }
    $c.useModel.Enabled = [bool]$src.exifModel
    $c.addSerial.Enabled = [bool]($src.serial -and -not $src.isFloppy)
    if (-not $c.name.Text.Trim() -and $src.exifModel) { $c.name.Text = $src.exifModel }
    if ($src.serial -and -not $src.isFloppy -and $c.serials.Items -notcontains $src.serial) { [void]$c.serials.Items.Add($src.serial) }
    if ($src.isFloppy -and $src.drive) { $c.drive.Text = $src.drive }
    if ($src.exifModel -and -not $c.model.Text.Trim() -and -not $c.make.Text.Trim()) { $c.model.Text = Get-ExactPattern $src.exifModel }
    Update-PresetMarks $s
    Update-CameraDialog $s
}

function Update-PresetMarks($s) {
    # "<- fits this card" next to presets that would recognize the picked card
    $c = $s.c
    if (-not $c.preset) { return }
    $s.loading = $true
    $sel = $c.preset.SelectedIndex
    $c.preset.Items.Clear()
    [void]$c.preset.Items.Add("(None)")
    foreach ($p in $s.presets) {
        $mark = ""
        if ($s.src) {
            $probe = New-CameraFromPreset $p "probe"
            if ((Test-CameraIdentity $probe $s.src) -or (Test-CameraCatchAll $probe $s.src)) { $mark = "   (matches selected media)" }
        }
        [void]$c.preset.Items.Add("$($p.title)$mark")
    }
    $c.preset.SelectedIndex = [math]::Max(0, $sel)
    $s.loading = $false
}

function Use-Preset($s, [int]$i) {
    if ($i -lt 1) { return }
    $p = $s.presets[$i - 1]
    $current = Read-CameraDialog $s
    $name = $current.name; if (-not $name) { $name = $p.camera.prefix }
    if (-not $name) { $name = "Camera" }
    $cam = New-CameraFromPreset $p $name
    # keep what was learned from the card and where files go
    $cam.match.serials = @($current.match.serials)
    if ($s.src -and -not (Test-CameraIdentity $cam $s.src) -and -not (Test-CameraCatchAll $cam $s.src) -and $current.match.exifModel) {
        $cam.match.exifModel = $current.match.exifModel
    }
    $cam.destination = $current.destination
    Write-CameraDialog $s $cam
    $s.c.presetInfo.Text = $p.description
}

function Pick-PluggedCard($owner, [string]$why) {
    # tiny chooser of the cards plugged in right now; $null if none / cancelled
    $sources = @(Get-PluggedInSources | Where-Object { $_.media.Count -gt 0 })
    if ($sources.Count -eq 0) {
        [void](Show-DlgMessage $owner "No memory card containing photos or videos was detected.`n`nInsert a memory card and try again." "Information")
        return $null
    }
    if ($sources.Count -eq 1) { return $sources[0] }
    $d = New-RetroDialog $why 380 200
    $l = New-Object System.Windows.Forms.ListBox
    $l.Location = New-Object System.Drawing.Point(8, 8); $l.Size = New-Object System.Drawing.Size(340, 100)
    foreach ($s in $sources) { [void]$l.Items.Add(("{0}  {1} - {2} item(s) {3}" -f $s.root.TrimEnd('\'), $s.label, $s.media.Count, $s.exifModel)) }
    $l.SelectedIndex = 0
    $ok = New-DlgButton "OK" 192 118; $ok.DialogResult = "OK"
    $cancel = New-DlgButton "Cancel" 273 118; $cancel.DialogResult = "Cancel"
    $d.body.Controls.AddRange(@($l, $ok, $cancel))
    $d.form.AcceptButton = $ok; $d.form.CancelButton = $cancel
    if ((Show-Modal $d.form $owner) -ne "OK") { return $null }
    return $sources[$l.SelectedIndex]
}

function Show-CameraDialog($owner, $cfg, [int]$index = -1) {
    # $index -1 = add a new camera. Returns @{ camera; source } after OK (already saved), else $null.
    $adding = ($index -lt 0)
    $title = "Add Camera"
    if (-not $adding) { $title = "Camera Properties - $($cfg.cameras[$index].name)" }
    $d = New-RetroDialog $title 540 520
    $form = $d.form
    $s = @{ cfg = $cfg; index = $index; adding = $adding; src = $null; loading = $true; c = @{}; result = $null
            presets = @(Get-Presets); icloud = (Get-ICloudPhotosFolder); styleKeys = @($script:NamingStyles.Keys) }
    $form.Tag = $s
    $c = $s.c

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(0, 0); $tabs.Size = New-Object System.Drawing.Size(508, 422)
    $d.body.Controls.Add($tabs)
    function New-Tab([string]$text) { $t = New-Object System.Windows.Forms.TabPage; $t.Text = $text; $t.BackColor = $RetroGray; $t.UseVisualStyleBackColor = $false; [void]$tabs.TabPages.Add($t); $t }
    $tGeneral = New-Tab "General"; $tRecog = New-Tab "Recognize"; $tFiles = New-Tab "Files"; $tImport = New-Tab "Import"

    # ---- General ----
    $tGeneral.Controls.Add((New-DlgLabel "&Name:" 12 16))
    $c.name = New-DlgText 110 13 370; $tGeneral.Controls.Add($c.name)
    $y = 48
    if ($adding) {
        $g = New-DlgGroup "Source Media (Optional)" 10 $y 476 92; $tGeneral.Controls.Add($g)
        $g.Controls.Add((New-DlgLabel "Select a memory card or folder from this camera to detect its identifying details." 10 18 456 16))
        $c.pickCard = New-DlgButton "Use &Card" 10 40 100; $g.Controls.Add($c.pickCard)
        $c.pickFolder = New-DlgButton "Use &Folder" 116 40 100; $g.Controls.Add($c.pickFolder)
        $c.srcInfo = New-DlgLabel "No source selected." 10 68 456 16; $g.Controls.Add($c.srcInfo)
        $y += 102
        $g2 = New-DlgGroup "Preset (Optional)" 10 $y 476 96; $tGeneral.Controls.Add($g2)
        $c.preset = New-Object System.Windows.Forms.ComboBox
        $c.preset.DropDownStyle = "DropDownList"; $c.preset.Location = New-Object System.Drawing.Point(10, 20); $c.preset.Width = 454
        $g2.Controls.Add($c.preset)
        $c.presetInfo = New-DlgLabel "A preset applies typical settings for a camera type. All settings remain editable." 10 50 454 36
        $g2.Controls.Add($c.presetInfo)
        $y += 106
    }
    $g3 = New-DlgGroup "Recognition Summary" 10 $y 476 70; $tGeneral.Controls.Add($g3)
    $c.summary = New-DlgLabel "" 10 20 456 42; $g3.Controls.Add($c.summary)
    $y += 80
    $tGeneral.Controls.Add((New-DlgLabel "Recognition rules are set on the Recognize tab, destination and file naming on the Files tab, and import behavior on the Import tab." 12 $y 470 30))

    # ---- Recognize ----
    $gs = New-DlgGroup "Card Serial Numbers" 10 8 476 104; $tRecog.Controls.Add($gs)
    $c.serials = New-Object System.Windows.Forms.ListBox
    $c.serials.Location = New-Object System.Drawing.Point(10, 20); $c.serials.Size = New-Object System.Drawing.Size(150, 72)
    $gs.Controls.Add($c.serials)
    $c.addSerial = New-DlgButton "&Add Inserted Card" 170 20 140; $gs.Controls.Add($c.addSerial)
    $c.removeSerial = New-DlgButton "&Remove" 170 48 140; $gs.Controls.Add($c.removeSerial)
    $gs.Controls.Add((New-DlgLabel "A serial number changes when the card is formatted on a computer." 316 22 150 60))

    $gm = New-DlgGroup "Image Metadata and File Names" 10 118 476 128; $tRecog.Controls.Add($gm)
    $rows = @(@("Camera &model:", "model", "modelHint"), @("Camera ma&ker:", "make", "makeHint"), @("File &names:", "files", "filesHint"))
    $ry = 22
    foreach ($r in $rows) {
        $gm.Controls.Add((New-DlgLabel $r[0] 10 ($ry + 3)))
        $c[$r[1]] = New-DlgText 100 $ry 170; $gm.Controls.Add($c[$r[1]])
        $c[$r[2]] = New-DlgLabel "" 276 ($ry + 3) 190 16; $gm.Controls.Add($c[$r[2]])
        $ry += 28
    }
    $c.useModel = New-DlgButton "Use &Detected Model" 100 $ry 150; $c.useModel.Enabled = $false; $gm.Controls.Add($c.useModel)
    $gm.Controls.Add((New-DlgLabel "Regular expressions: ^ start, $ end." 256 ($ry + 4)))

    $gd = New-DlgGroup "Drive Letter" 10 252 150 56; $tRecog.Controls.Add($gd)
    $gd.Controls.Add((New-DlgLabel "Any media in:" 10 24))
    $c.drive = New-DlgText 84 21 40; $gd.Controls.Add($c.drive)
    $gc = New-DlgGroup "Unrecognized Media" 166 252 320 82; $tRecog.Controls.Add($gc)
    $c.catchNone   = New-DlgRadio "Ignore" 10 18
    $c.catchPhotos = New-DlgRadio "Import any card containing photos" 10 38
    $c.catchVideos = New-DlgRadio "Import any card containing only videos" 10 58
    $gc.Controls.AddRange(@($c.catchNone, $c.catchPhotos, $c.catchVideos))

    # ---- Files ----
    $gw = New-DlgGroup "Destination" 10 8 476 110; $tFiles.Controls.Add($gw)
    $c.destLibrary = New-DlgRadio "Library folder:" 10 20
    $c.libraryPath = New-DlgLabel "" 26 38 440 16; $c.libraryPath.ForeColor = $RetroDark
    $c.libraryPath.AutoEllipsis = $true          # long paths end in "..." instead of wrapping
    $icloudText = "iCloud Photos (synchronized automatically)"; if (-not $s.icloud) { $icloudText = "iCloud Photos (not installed)" }
    $c.destICloud = New-DlgRadio $icloudText 10 56; $c.destICloud.Enabled = [bool]$s.icloud
    $c.destOther = New-DlgRadio "Other folder:" 10 80
    $c.destPath = New-DlgText 120 78 260; $c.destBrowse = New-DlgButton "&Browse" 386 77 80
    $gw.Controls.AddRange(@($c.destLibrary, $c.libraryPath, $c.destICloud, $c.destOther, $c.destPath, $c.destBrowse))

    $gn = New-DlgGroup "File Naming" 10 124 476 214; $tFiles.Controls.Add($gn)
    $labels = @("Sequential number", "Capture date and time", "Capture date and sequential number", "Original camera file name")
    $c.style = @()
    for ($i = 0; $i -lt 4; $i++) { $rb = New-DlgRadio $labels[$i] 10 (20 + 20 * $i); $c.style += $rb; $gn.Controls.Add($rb) }
    $c.styleCustom = New-DlgRadio "Custom pattern:" 10 100; $gn.Controls.Add($c.styleCustom)
    $c.pattern = New-DlgText 80 98 200; $gn.Controls.Add($c.pattern)
    $tagHelp = New-DlgLabel "{name} {n} {n:4} {orig}`n{date} {time} {year} {month}`n{day} {hour} {minute} {second}" 288 84 182 44
    $tagHelp.ForeColor = $RetroDark
    $gn.Controls.Add($tagHelp)
    $gn.Controls.Add((New-DlgLabel "Name label:" 10 130))
    $c.label = New-DlgText 80 127 200; $gn.Controls.Add($c.label)
    $gn.Controls.Add((New-DlgLabel "Preview:" 10 158))
    $c.preview = New-DlgLabel "" 80 158 386 48; $c.preview.Font = $RetroBold; $gn.Controls.Add($c.preview)


    # ---- Import ----
    $gi = New-DlgGroup "Import Options" 10 8 476 76; $tImport.Controls.Add($gi)
    $c.deleteCard = New-DlgCheck "&Delete files from the card after verification" 10 20
    $c.convert = New-DlgCheck "&Convert AVI, MPG and MTS video to MP4 (originals retained)" 10 44
    $gi.Controls.AddRange(@($c.deleteCard, $c.convert))
    $gr = New-DlgGroup "RAW Files (ARW, NEF, CR2, DNG)" 10 90 476 66; $tImport.Controls.Add($gr)
    $c.rawLocal = New-DlgRadio "Retain RAW locally and export JPEG (recommended for iCloud)" 10 20
    $c.rawCopy = New-DlgRadio "Export RAW files unchanged" 10 42
    $gr.Controls.AddRange(@($c.rawLocal, $c.rawCopy))
    $gv = New-DlgGroup "Review Before Export" 10 162 476 86; $tImport.Controls.Add($gv)
    $c.reviewAsk = New-DlgRadio "Prompt after copying" 10 20
    $c.reviewAlways = New-DlgRadio "Always open the review" 10 40
    $c.reviewNever = New-DlgRadio "Never (export immediately)" 10 60
    $gv.Controls.AddRange(@($c.reviewAsk, $c.reviewAlways, $c.reviewNever))
    $gst = New-DlgGroup "Automation" 10 254 476 50; $tImport.Controls.Add($gst)
    $c.autoStart = New-DlgCheck "&Start import without confirmation" 10 20
    $gst.Controls.Add($c.autoStart)
    $gt = New-DlgGroup "Date Handling (applied to file metadata)" 10 310 476 84; $tImport.Controls.Add($gt)
    $c.datesCapture = New-DlgRadio "Use the camera date" 10 18
    $c.datesImport = New-DlgRadio "Use the import date" 10 38
    $c.datesAuto = New-DlgRadio "Use the import date if older than" 10 58
    $c.staleDays = New-Object System.Windows.Forms.NumericUpDown
    $c.staleDays.Location = New-Object System.Drawing.Point(172, 56); $c.staleDays.Width = 56
    $c.staleDays.Minimum = 1; $c.staleDays.Maximum = 36500; $c.staleDays.Value = 365
    $gt.Controls.AddRange(@($c.datesCapture, $c.datesImport, $c.datesAuto, $c.staleDays,
                            (New-DlgLabel "days or in the future" 234 60)))
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($c.datesAuto, "For cameras whose clock may reset. Photos that are genuinely older than this limit also receive the import date. Unmodified originals are always retained.")

    # ---- OK / Cancel ----
    $okText = "OK"; if ($adding) { $okText = "Add Camera" }
    $c.ok = New-DlgButton $okText 344 430 82
    $c.cancel = New-DlgButton "Cancel" 432 430 76; $c.cancel.DialogResult = "Cancel"
    $d.body.Controls.AddRange(@($c.ok, $c.cancel))
    $form.CancelButton = $c.cancel

    # ---- fill it ----
    if ($adding) {
        $start = New-CameraProfile ""
        Update-PresetMarks $s
    } else {
        $start = $cfg.cameras[$index]
    }
    Write-CameraDialog $s $start
    if ($adding) { $c.name.Text = "" }

    # ---- live updates ----
    $c.label.Add_TextChanged({ $ss = $this.FindForm().Tag; if (-not $ss.loading) { $ss.labelEdited = $true } })
    $refresh = { $ss = $this.FindForm().Tag; Update-CameraDialog $ss }
    foreach ($t in @($c.name, $c.model, $c.make, $c.files, $c.drive, $c.pattern, $c.label, $c.destPath)) { $t.Add_TextChanged($refresh) }
    foreach ($r in @($c.catchNone, $c.catchPhotos, $c.catchVideos, $c.destLibrary, $c.destICloud, $c.destOther, $c.styleCustom,
                     $c.datesCapture, $c.datesImport, $c.datesAuto) + $c.style) { $r.Add_CheckedChanged($refresh) }
    $c.staleDays.Add_ValueChanged($refresh)

    $c.destBrowse.Add_Click({
        $ss = $this.FindForm().Tag
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = "Select the destination folder for this camera."
        if ($fb.ShowDialog($this.FindForm()) -eq "OK") { $ss.c.destPath.Text = $fb.SelectedPath }
    })
    $c.addSerial.Add_Click({
        $ss = $this.FindForm().Tag
        $src = Pick-PluggedCard $this.FindForm() "Select Card"
        if ($src -and $src.serial -and $ss.c.serials.Items -notcontains $src.serial) { [void]$ss.c.serials.Items.Add($src.serial); Update-CameraDialog $ss }
    })
    $c.removeSerial.Add_Click({
        $ss = $this.FindForm().Tag
        if ($ss.c.serials.SelectedIndex -ge 0) { $ss.c.serials.Items.RemoveAt($ss.c.serials.SelectedIndex); Update-CameraDialog $ss }
    })
    $c.useModel.Add_Click({ $ss = $this.FindForm().Tag; if ($ss.src -and $ss.src.exifModel) { $ss.c.model.Text = Get-ExactPattern $ss.src.exifModel } })
    if ($adding) {
        $c.pickCard.Add_Click({
            $ss = $this.FindForm().Tag
            $src = Pick-PluggedCard $this.FindForm() "Select Card"
            if ($src) { Set-DialogSource $ss $src }
        })
        $c.pickFolder.Add_Click({
            $ss = $this.FindForm().Tag
            $fb = New-Object System.Windows.Forms.FolderBrowserDialog
            $fb.Description = "Select a folder of photos from this camera."
            if ($fb.ShowDialog($this.FindForm()) -eq "OK") {
                $this.FindForm().Cursor = "WaitCursor"
                Set-DialogSource $ss (Get-SourceInfo $fb.SelectedPath)
                $this.FindForm().Cursor = "Default"
            }
        })
        $c.preset.Add_SelectedIndexChanged({ $ss = $this.FindForm().Tag; if (-not $ss.loading) { Use-Preset $ss $this.SelectedIndex } })
    }

    $c.ok.Add_Click({
        $f = $this.FindForm(); $ss = $f.Tag
        $cam = Read-CameraDialog $ss
        $problems = @()
        if (-not $cam.name) { $problems += "Enter a camera name (General tab)." }
        for ($i = 0; $i -lt $ss.cfg.cameras.Count; $i++) {
            if ($i -ne $ss.index -and $ss.cfg.cameras[$i].name -eq $cam.name) { $problems += "A camera named '$($cam.name)' already exists." }
        }
        foreach ($rx in @($cam.match.exifModel, $cam.match.exifMake, $cam.match.fileNames)) {
            if (-not (Test-Regex $rx)) { $problems += "Invalid pattern: '$rx' (Recognize tab)." }
        }
        if ($cam.match.drive -and $cam.match.drive -notmatch '^[A-Z]:$') { $problems += "Enter the drive letter in the form A: (Recognize tab)." }
        if ($ss.c.destOther.Checked -and -not $cam.destination) { $problems += "Select a destination folder (Files tab)." }
        $np = Test-NamingPattern $cam.naming
        if ($np -match '^Unknown|empty') { $problems += "File naming: $np (Files tab)" }
        if ($problems.Count -gt 0) { [void](Show-DlgMessage $f ($problems -join "`n") "Warning"); return }
        if ((Get-MatchSummary $cam) -like "No rules*") {
            $go = Show-DlgMessage $f "No recognition rules are defined for $($cam.name). The camera will be available for folder imports only.`n`nSave anyway?" "Question" "YesNo"
            if ($go -ne "Yes") { return }
        }
        if (-not $ss.adding) {
            # renaming moves the camera's own folder (originals, history) along with it
            $oldDir = Get-CameraFolder $ss.cfg $ss.cfg.cameras[$ss.index]
            $newDir = Get-CameraFolder $ss.cfg $cam
            if ($oldDir -ne $newDir -and (Test-Path -LiteralPath $oldDir) -and -not (Test-Path -LiteralPath $newDir)) {
                try { Move-Item -LiteralPath $oldDir -Destination $newDir -ErrorAction Stop }
                catch { [void](Show-DlgMessage $f "The camera folder could not be renamed.`n`n$($_.Exception.Message)`n`nClose any program using the folder and try again." "Warning"); return }
            }
            $ss.cfg.cameras[$ss.index] = $cam
        } else {
            $ss.cfg.cameras = @($ss.cfg.cameras) + ,$cam
        }
        $ss.result = @{ camera = $cam; source = $ss.src }
        $f.DialogResult = "OK"
        $f.Close()
    })

    $tabs.SelectedIndex = 0
    $form.ActiveControl = $c.name
    if ((Show-Modal $form $owner) -ne "OK") { return $null }
    return $s.result
}

# ============================================================
#  Special camera dialog: a camera with its own importer
# ============================================================

function Show-SpecialCameraDialog($owner, $cfg, [int]$index = -1) {
    # $index -1 = add one. Returns @{ camera; run } after OK / Save && Run (run = start it now), else $null.
    $adding = ($index -lt 0)
    $title = "Add External Camera"
    if (-not $adding) { $title = "External Camera - $($cfg.cameras[$index].name)" }
    $d = New-RetroDialog $title 500 360
    $form = $d.form
    $s = @{ cfg = $cfg; index = $index; result = $null; c = @{} }
    $form.Tag = $s
    $c = $s.c
    if ($adding) { $cam = New-CameraProfile ""; $cam.kind = "special" } else { $cam = Copy-Camera $cfg.cameras[$index] }
    $s.base = $cam

    $d.body.Controls.Add((New-DlgLabel "For cameras that transfer images through a dedicated program (Wi-Fi, cable or capture device) rather than a memory card." 0 0 468 30))
    $d.body.Controls.Add((New-DlgLabel "&Name:" 0 44))
    $c.name = New-DlgText 120 41 348 $cam.name; $d.body.Controls.Add($c.name)
    $d.body.Controls.Add((New-DlgLabel "&Description:" 0 74))
    $c.about = New-DlgText 120 71 348 $cam.about; $d.body.Controls.Add($c.about)
    $g = New-DlgGroup "Importer" 0 104 468 92; $d.body.Controls.Add($g)
    $g.Controls.Add((New-DlgLabel "&Program:" 10 24))
    $c.program = New-DlgText 80 21 290 $cam.program; $g.Controls.Add($c.program)
    $c.browse = New-DlgButton "&Browse" 376 20 80; $g.Controls.Add($c.browse)
    $g.Controls.Add((New-DlgLabel "&Arguments:" 10 56))
    $c.args = New-DlgText 80 53 376 $cam.arguments; $g.Controls.Add($c.args)
    $d.body.Controls.Add((New-DlgLabel "Output folder:" 0 208))
    $c.dest = New-DlgText 0 226 380 $cam.destination; $d.body.Controls.Add($c.dest)
    $c.destBrowse = New-DlgButton "B&rowse" 388 225 80; $d.body.Controls.Add($c.destBrowse)

    $okText = "OK"; if ($adding) { $okText = "Add" }
    $c.run = New-DlgButton "Save and &Run" 200 268 100
    $c.ok = New-DlgButton $okText 306 268 80
    $c.cancel = New-DlgButton "Cancel" 392 268 76; $c.cancel.DialogResult = "Cancel"
    $d.body.Controls.AddRange(@($c.run, $c.ok, $c.cancel))
    $form.CancelButton = $c.cancel

    $c.browse.Add_Click({
        $ss = $this.FindForm().Tag
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Programs and scripts (*.bat;*.cmd;*.ps1;*.exe)|*.bat;*.cmd;*.ps1;*.exe"
        if ($ss.c.program.Text -and (Test-Path -LiteralPath $ss.c.program.Text)) { $ofd.InitialDirectory = Split-Path $ss.c.program.Text -Parent }
        if ($ofd.ShowDialog($this.FindForm()) -eq "OK") { $ss.c.program.Text = $ofd.FileName }
    })
    $c.destBrowse.Add_Click({
        $ss = $this.FindForm().Tag
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = "Select the folder where this camera's importer saves its output."
        if ($fb.ShowDialog($this.FindForm()) -eq "OK") { $ss.c.dest.Text = $fb.SelectedPath }
    })
    $save = {
        param($f, [bool]$run)
        $ss = $f.Tag
        $cam = Copy-Camera $ss.base
        $cam.kind = "special"
        $cam.name = ($ss.c.name.Text -replace '[\\/:*?"<>|]', '').Trim()
        $cam.about = $ss.c.about.Text.Trim()
        $cam.program = $ss.c.program.Text.Trim().Trim('"')
        $cam.arguments = $ss.c.args.Text.Trim()
        $cam.destination = $ss.c.dest.Text.Trim().Trim('"')
        $cam.prefix = $cam.name
        $problems = @()
        if (-not $cam.name) { $problems += "Enter a name." }
        for ($i = 0; $i -lt $ss.cfg.cameras.Count; $i++) {
            if ($i -ne $ss.index -and $ss.cfg.cameras[$i].name -eq $cam.name) { $problems += "A camera named '$($cam.name)' already exists." }
        }
        if (-not $cam.program -or -not (Test-Path -LiteralPath $cam.program)) { $problems += "Select the importer program." }
        if ($problems.Count -gt 0) { [void](Show-DlgMessage $f ($problems -join "`n") "Warning"); return }
        if ($ss.index -lt 0) { $ss.cfg.cameras = @($ss.cfg.cameras) + ,$cam } else { $ss.cfg.cameras[$ss.index] = $cam }
        $ss.result = @{ camera = $cam; run = $run }
        $f.DialogResult = "OK"; $f.Close()
    }
    $c.ok.Add_Click({ & $this.FindForm().Tag.save $this.FindForm() $false })
    $c.run.Add_Click({ & $this.FindForm().Tag.save $this.FindForm() $true })
    $s.save = $save
    $form.ActiveControl = $c.name
    if ((Show-Modal $form $owner) -ne "OK") { return $null }
    return $s.result
}

# ============================================================
#  Settings dialog: library folder + optional tools
# ============================================================

function Invoke-ConsoleAndWait($owner, [string]$exe, [string]$arguments) {
    # installers show their own progress in a console window; keep this window painting meanwhile
    $p = Start-Process $exe -ArgumentList $arguments -PassThru
    $owner.Enabled = $false
    try {
        while (-not $p.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    } finally { $owner.Enabled = $true; $owner.Activate() }
    # pick up PATH changes from the install without restarting
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Update-ToolRows($s) {
    $t = Get-Tools $s.cfg
    $s.tools = $t
    foreach ($row in @(@("ffmpeg", $t.ffmpeg), @("handbrake", $t.handbrake), @("python", $t.python))) {
        $lbl = $s.c["$($row[0])State"]
        if ($row[1]) { $lbl.Text = "Installed: $($row[1])"; $lbl.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 0) }
        else { $lbl.Text = "Not installed"; $lbl.ForeColor = $RetroRed }
        $s.c["$($row[0])Install"].Enabled = ($s.winget -and -not $row[1])
    }
    $s.c.rawpyState.Text = $(if ($t.rawpy) { "RAW rendering: ready" } elseif ($t.python) { "RAW rendering: needs rawpy" } else { "RAW rendering: needs Python + rawpy" })
    $s.c.rawpyInstall.Enabled = [bool]($t.python -and -not $t.rawpy)
}

function Show-SettingsDialog($owner, $cfg) {
    # returns $true when something was saved
    $d = New-RetroDialog "Settings" 540 420
    $form = $d.form
    $s = @{ cfg = $cfg; c = @{}; winget = [bool](Get-Command winget -ErrorAction SilentlyContinue) }
    $form.Tag = $s
    $c = $s.c

    $gl = New-DlgGroup "Library Folder" 0 0 508 84; $d.body.Controls.Add($gl)
    $gl.Controls.Add((New-DlgLabel "Stores originals, RAW files, pending photos and import history for each camera. Existing files are not moved when this location changes." 10 18 488 28))
    $c.library = New-DlgText 10 50 400 $cfg.libraryRoot; $gl.Controls.Add($c.library)
    $c.browse = New-DlgButton "&Browse" 418 49 80; $gl.Controls.Add($c.browse)

    $gt = New-DlgGroup "External Tools" 0 92 508 236; $d.body.Controls.Add($gt)
    $gt.Controls.Add((New-DlgLabel "ffmpeg or HandBrakeCLI converts AVI, MPG and MTS video to MP4. Python with rawpy renders RAW-only images to JPEG. Installation uses Windows Package Manager (winget)." 10 18 488 30))
    $y = 54
    foreach ($row in @(@("ffmpeg", "ffmpeg", "Gyan.FFmpeg"), @("handbrake", "HandBrakeCLI", "HandBrake.HandBrake.CLI"), @("python", "Python", "Python.Python.3.12"))) {
        $gt.Controls.Add((New-DlgLabel $row[1] 10 ($y + 4) 90 16))
        $c["$($row[0])State"] = New-DlgLabel "" 100 ($y + 4) 220 16; $c["$($row[0])State"].AutoEllipsis = $true
        $gt.Controls.Add($c["$($row[0])State"])
        $inst = New-DlgButton "Install" 330 $y 80; $inst.Tag = $row[2]; $inst.Enabled = $s.winget
        $c["$($row[0])Install"] = $inst
        $inst.Add_Click({
            $ss = $this.FindForm().Tag
            Invoke-ConsoleAndWait $this.FindForm() "winget" "install --exact --id $($this.Tag) --accept-package-agreements --accept-source-agreements"
            Update-ToolRows $ss
        })
        $find = New-DlgButton "Locate" 416 $y 80; $find.Tag = $row[0]
        $find.Add_Click({
            $ss = $this.FindForm().Tag
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = "Programs (*.exe)|*.exe"
            if ($ofd.ShowDialog($this.FindForm()) -eq "OK") { $ss.cfg.tools[$this.Tag] = $ofd.FileName; Update-ToolRows $ss }
        })
        $gt.Controls.AddRange(@($inst, $find))
        $y += 32
    }
    $c.rawpyState = New-DlgLabel "" 10 ($y + 8) 310 16; $gt.Controls.Add($c.rawpyState)
    $c.rawpyInstall = New-DlgButton "Install rawpy" 330 ($y + 4) 166; $gt.Controls.Add($c.rawpyInstall)
    $c.rawpyInstall.Add_Click({
        $ss = $this.FindForm().Tag
        Invoke-ConsoleAndWait $this.FindForm() $ss.tools.python "-m pip install --user rawpy pillow"
        Update-ToolRows $ss
    })
    if (-not $s.winget) { $gt.Controls.Add((New-DlgLabel "Windows Package Manager is not available. Use Locate to select installed tools." 10 ($y + 36) 488 16)) }

    $c.ok = New-DlgButton "OK" 352 338 75
    $c.cancel = New-DlgButton "Cancel" 433 338 75; $c.cancel.DialogResult = "Cancel"
    $d.body.Controls.AddRange(@($c.ok, $c.cancel))
    $form.CancelButton = $c.cancel
    $c.browse.Add_Click({
        $ss = $this.FindForm().Tag
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = "Select the library folder."
        if ($fb.ShowDialog($this.FindForm()) -eq "OK") { $ss.c.library.Text = $fb.SelectedPath }
    })
    $c.ok.Add_Click({
        $f = $this.FindForm(); $ss = $f.Tag
        $lib = $ss.c.library.Text.Trim().Trim('"')
        if (-not $lib) { [void](Show-DlgMessage $f "Select a library folder." "Warning"); return }
        $ss.cfg.libraryRoot = $lib
        $f.DialogResult = "OK"; $f.Close()
    })
    Update-ToolRows $s
    $before = ConvertTo-Json -InputObject $cfg.tools
    $r = Show-Modal $form $owner
    # tool paths picked with Find... count even after Cancel only if OK was pressed
    if ($r -ne "OK") {
        $orig = ConvertFrom-Json $before
        foreach ($k in @($cfg.tools.Keys)) { $cfg.tools[$k] = [string]$orig.$k }
        return $false
    }
    return $true
}

# ============================================================
#  First-time setup
# ============================================================

function Show-WelcomeDialog($owner) {
    # returns a new config (already saved by the caller) or $null if cancelled
    $d = New-RetroDialog "Camera Ingest Setup" 500 330
    $form = $d.form
    $cfg = New-DefaultConfig
    $tools = Get-Tools $cfg
    $winget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    $s = @{ cfg = $cfg; c = @{} }
    $form.Tag = $s
    $c = $s.c

    $logo = New-DlgLabel "CAMERA`nINGEST" 0 0 110 70
    $logo.BackColor = $RetroNavy; $logo.ForeColor = $RetroWhite; $logo.TextAlign = "MiddleCenter"; $logo.BorderStyle = "Fixed3D"
    $logo.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Bold)
    $d.body.Controls.Add($logo)
    $d.body.Controls.Add((New-DlgLabel "Select the library location. Each camera uses a subfolder of the library for originals and import history.`n`nThe export destination (library, iCloud Photos or another folder) is configured separately for each camera." 122 0 344 92))
    $d.body.Controls.Add((New-DlgLabel "&Library folder:" 0 106))
    $c.library = New-DlgText 0 124 380 $cfg.libraryRoot; $d.body.Controls.Add($c.library)
    $c.browse = New-DlgButton "&Browse" 388 123 80; $d.body.Controls.Add($c.browse)
    $c.ffmpeg = New-DlgCheck "&Install the ffmpeg video converter (approx. 100 MB)" 0 162
    if ($tools.handbrake -or $tools.ffmpeg) { $c.ffmpeg.Text = "Video converter: installed"; $c.ffmpeg.Enabled = $false }
    elseif (-not $winget) { $c.ffmpeg.Text = "Video converter: can be installed later from Settings"; $c.ffmpeg.Enabled = $false }
    else { $c.ffmpeg.Checked = $true }
    $d.body.Controls.Add($c.ffmpeg)
    $d.body.Controls.Add((New-DlgLabel "Camera configuration follows. Refer to the iCloud section of the User Guide before exporting to iCloud Photos." 0 194 468 30))

    $c.ok = New-DlgButton "&Next >" 312 244 80
    $c.cancel = New-DlgButton "Cancel" 398 244 70; $c.cancel.DialogResult = "Cancel"
    $d.body.Controls.AddRange(@($c.ok, $c.cancel))
    $form.CancelButton = $c.cancel
    $c.browse.Add_Click({
        $ss = $this.FindForm().Tag
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = "Select the library folder."
        if ($fb.ShowDialog($this.FindForm()) -eq "OK") { $ss.c.library.Text = $fb.SelectedPath }
    })
    $c.ok.Add_Click({
        $f = $this.FindForm(); $ss = $f.Tag
        $lib = $ss.c.library.Text.Trim().Trim('"')
        try { New-Item -ItemType Directory -Path $lib -Force -ErrorAction Stop | Out-Null }
        catch { [void](Show-DlgMessage $f "The selected folder cannot be used.`n`n$($_.Exception.Message)" "Warning"); return }
        $ss.cfg.libraryRoot = $lib
        if ($ss.c.ffmpeg.Enabled -and $ss.c.ffmpeg.Checked) {
            Invoke-ConsoleAndWait $f "winget" "install --exact --id Gyan.FFmpeg --accept-package-agreements --accept-source-agreements"
        }
        $f.DialogResult = "OK"; $f.Close()
    })
    if ((Show-Modal $form $owner) -ne "OK") { return $null }
    return $cfg
}
