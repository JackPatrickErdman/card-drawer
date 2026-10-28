# ============================================================
#  Camera Ingest - the window app (retro, Windows 98 style)
#  A plain front end over the same engine as the text menus:
#    - shows the cards plugged in and which camera each belongs to
#      (refreshes by itself when a card goes in or comes out)
#    - Import Now / Import Folder run the engine in the background,
#      with its log and a progress bar in the Activity box
#    - Add Camera, Camera Settings, Settings and first-time setup are
#      point-and-click dialogs (Dialogs.ps1); right-click a camera for
#      practice run / move / remove. Tools > Text Menus is the keyboard version.
#  Plain Windows PowerShell 5.1 + WinForms - nothing to install.
# ============================================================
param(
    [string]$ConfigPath = "",
    [string]$Snapshot = "",    # save a picture of the window to this .png and close (README / tests)
    [string]$DemoFolder = "",  # with -DemoCamera: import this folder on open (snapshot waits for it)
    [string]$DemoCamera = "",
    [string]$SelfTest = ""     # tests: press every button that opens a dialog, log what opened to this file, close
)

. (Join-Path $PSScriptRoot "Retro.ps1")
. (Join-Path $PSScriptRoot "Common.ps1")
. (Join-Path $PSScriptRoot "Dialogs.ps1")
if (-not $ConfigPath) { $ConfigPath = Get-DefaultConfigPath }

# ---- the 98 palette (Retro.ps1) under short names ----
$Gray = $RetroGray; $Navy = $RetroNavy; $White = $RetroWhite
$Font = $RetroFont; $Bold = $RetroBold; $Mono = $RetroMono

$script:cfg = Read-Config $ConfigPath
$script:sources = @()
$script:driveSig = ""
$script:job = $null

function Quote([string]$s) { "'" + $s.Replace("'", "''") + "'" }

# ============================================================
#  Window frame (Retro.ps1): borderless form + hand-drawn title bar
# ============================================================
$win = New-RetroWindow "Camera Ingest" 800 600
$form = $win.form
# Event code runs while dialogs are open, and dialogs have their own $form - so code that
# can run then uses this name, which only ever means the main window
$script:mainForm = $form
$title = $win.title

# ============================================================
#  Menu bar and status bar
# ============================================================
$menu = New-Object System.Windows.Forms.MenuStrip
$menu.RenderMode = "System"
$menu.BackColor = $Gray

function Add-MenuItem($parent, [string]$text, [scriptblock]$action) {
    if ($text -eq "-") { [void]$parent.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)); return }
    $i = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    if ($action) { $i.Add_Click($action) }
    [void]$parent.DropDownItems.Add($i)
    return $i
}
$mFile  = New-Object System.Windows.Forms.ToolStripMenuItem("&File")
$mCams  = New-Object System.Windows.Forms.ToolStripMenuItem("&Cameras")
$mTools = New-Object System.Windows.Forms.ToolStripMenuItem("&Tools")
$mHelp  = New-Object System.Windows.Forms.ToolStripMenuItem("&Help")
[void]$menu.Items.AddRange(@($mFile, $mCams, $mTools, $mHelp))

$status = New-Object System.Windows.Forms.StatusStrip
$status.RenderMode = "System"
$status.SizingGrip = $false
$status.BackColor = $Gray
function New-StatusPanel([int]$width, [bool]$spring) {
    $l = New-Object System.Windows.Forms.ToolStripStatusLabel
    $l.BorderSides = "All"; $l.BorderStyle = "SunkenOuter"
    $l.TextAlign = "MiddleLeft"; $l.Spring = $spring
    if (-not $spring) { $l.AutoSize = $false; $l.Width = $width }
    [void]$status.Items.Add($l)
    return $l
}
$stMain  = New-StatusPanel 0 $true
$stCards = New-StatusPanel 110 $false
$stCams  = New-StatusPanel 110 $false

# ============================================================
#  Body: buttons on the left, three group boxes on the right
# ============================================================
$body = New-Object System.Windows.Forms.Panel
$body.Dock = "Fill"
$body.Padding = New-Object System.Windows.Forms.Padding(6)

$left = New-Object System.Windows.Forms.Panel
$left.Dock = "Left"; $left.Width = 150

$logo = New-Object System.Windows.Forms.Label
$logo.BorderStyle = "Fixed3D"
$logo.BackColor = $Navy; $logo.ForeColor = $White
$logo.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 11, [System.Drawing.FontStyle]::Bold)
$logo.Text = "CAMERA`nINGEST"
$logo.TextAlign = "MiddleCenter"
$logo.Location = New-Object System.Drawing.Point(0, 4)
$logo.Size = New-Object System.Drawing.Size(140, 58)
$left.Controls.Add($logo)

$script:buttonY = 74
function New-SideButton([string]$text, [scriptblock]$action) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.BackColor = $Gray
    $b.FlatStyle = "Standard"
    $b.Location = New-Object System.Drawing.Point(0, $script:buttonY)
    $b.Size = New-Object System.Drawing.Size(140, 28)
    $b.Add_Click($action)
    $left.Controls.Add($b)
    $script:buttonY += 32
    return $b
}

$right = New-Object System.Windows.Forms.TableLayoutPanel
$right.Dock = "Fill"
$right.ColumnCount = 1; $right.RowCount = 3
[void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 22)))
[void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 44)))
[void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle("Percent", 34)))

function New-Group([string]$text, $inner) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $text; $g.Dock = "Fill"
    $g.Padding = New-Object System.Windows.Forms.Padding(6, 4, 6, 6)
    $inner.Dock = "Fill"
    $g.Controls.Add($inner)
    return $g
}
function New-List([string[]]$columns, [int[]]$widths) {
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = "Details"; $lv.FullRowSelect = $true; $lv.GridLines = $true
    $lv.HideSelection = $false; $lv.MultiSelect = $false
    $lv.BorderStyle = "Fixed3D"; $lv.HeaderStyle = "Nonclickable"
    for ($i = 0; $i -lt $columns.Count; $i++) { [void]$lv.Columns.Add($columns[$i], $widths[$i]) }
    return $lv
}

$lvCards = New-List @("Drive", "Label", "Contents", "Camera", "Recognized By") @(44, 80, 220, 100, 170)
$lvCams  = New-List @("Camera", "Recognition", "File Names", "Destination") @(110, 170, 150, 200)

$activity = New-Object System.Windows.Forms.Panel
$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = "Vertical"
$log.BorderStyle = "Fixed3D"; $log.BackColor = $White; $log.Font = $Mono
$log.Dock = "Fill"; $log.MaxLength = 0
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Style = "Blocks"; $progress.Dock = "Bottom"; $progress.Height = 16
$gap = New-Object System.Windows.Forms.Panel; $gap.Dock = "Bottom"; $gap.Height = 4
$activity.Controls.Add($log); $activity.Controls.Add($gap); $activity.Controls.Add($progress)

$right.Controls.Add((New-Group "Inserted Media" $lvCards), 0, 0)
$right.Controls.Add((New-Group "Cameras" $lvCams), 0, 1)
$right.Controls.Add((New-Group "Activity Log" $activity), 0, 2)

$body.Controls.Add($right)
$body.Controls.Add($left)
$right.BringToFront()

# docking order: the last one added docks first (title on top, then menu, status at the bottom)
$script:mainForm.Controls.Add($body)
$script:mainForm.Controls.Add($status)
$script:mainForm.Controls.Add($menu)
$script:mainForm.Controls.Add($title)
$script:mainForm.MainMenuStrip = $menu

# ============================================================
#  Filling the lists
# ============================================================
function Write-Log([string]$text) {
    $log.AppendText(($text -replace "`r?`n", "`r`n"))
}

function Set-Status([string]$text) { $stMain.Text = " $text" }

function Refresh-Cameras {
    $lvCams.BeginUpdate(); $lvCams.Items.Clear()
    if ($script:cfg) {
        foreach ($c in $script:cfg.cameras) {
            $it = New-Object System.Windows.Forms.ListViewItem($c.name)
            [void]$it.SubItems.Add((Get-MatchSummary $c))
            [void]$it.SubItems.Add(((Get-NamingExample $c) -split ', ')[0])
            if (Test-SpecialCamera $c) {
                # cameras with their own importer look different: navy italics, no card rules
                [void]$it.SubItems.Add([string]$c.destination)
                $it.ForeColor = $Navy
                $it.Font = New-Object System.Drawing.Font($Font, [System.Drawing.FontStyle]::Italic)
            } else {
                [void]$it.SubItems.Add((Get-CameraDestination $script:cfg $c))
            }
            [void]$lvCams.Items.Add($it)
        }
        $stCams.Text = " Cameras: $($script:cfg.cameras.Count)"
    } else {
        [void]$lvCams.Items.Add((New-Object System.Windows.Forms.ListViewItem("Not configured. Select Set Up to begin.")))
        $stCams.Text = " Not configured"
    }
    $lvCams.EndUpdate()
}

function Refresh-Cards {
    $script:mainForm.Cursor = "WaitCursor"
    $script:sources = @(Get-PluggedInSources)
    $lvCards.BeginUpdate(); $lvCards.Items.Clear()
    foreach ($s in $script:sources) {
        $it = New-Object System.Windows.Forms.ListViewItem($s.root.TrimEnd('\'))
        $lbl = $s.label; if (-not $lbl) { $lbl = "(None)" }
        [void]$it.SubItems.Add($lbl)
        [void]$it.SubItems.Add(("{0} photos, {1} videos" -f $s.photos.Count, $s.videos.Count))
        $camName = "-"; $why = ""
        if ($s.media.Count -eq 0) { $camName = "-"; $why = "No media" }
        elseif ($script:cfg) {
            $hit = Find-CameraForSource $script:cfg $s
            if ($hit) { $camName = $hit.camera.name; $why = $hit.reason }
            else { $camName = "Unrecognized"; $why = "No matching camera profile" }
        }
        [void]$it.SubItems.Add($camName)
        [void]$it.SubItems.Add($why)
        [void]$lvCards.Items.Add($it)
    }
    if ($script:sources.Count -eq 0) {
        $none = New-Object System.Windows.Forms.ListViewItem("-")
        [void]$none.SubItems.Add("")
        [void]$none.SubItems.Add("No memory card detected")
        [void]$lvCards.Items.Add($none)
    }
    $lvCards.EndUpdate()
    $stCards.Text = " Media: $($script:sources.Count)"
    $script:mainForm.Cursor = "Default"
}

function Get-DriveSignature {
    # cheap check every couple of seconds; the full scan only runs when this changes
    ([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq "Removable" -and $_.IsReady } |
        ForEach-Object { "$($_.Name)$($_.VolumeLabel)$($_.TotalSize)" }) -join "|"
}

# ============================================================
#  Running the engine / the text menus
# ============================================================
$script:actionControls = @()

function Set-Busy([bool]$busy, [string]$text) {
    foreach ($c in $script:actionControls) { $c.Enabled = -not $busy }
    Set-Status $text
}

function Start-Engine([string]$extraArgs, [string]$what) {
    # Import.ps1 in a window-less PowerShell; everything it prints goes to a log file that
    # the timer below copies into the Activity box
    $logFile = Join-Path $env:TEMP ("camera-ingest-run-{0}.log" -f [guid]::NewGuid().ToString("N"))
    $cmd = "& " + (Quote (Join-Path $PSScriptRoot "Import.ps1")) + " -Gui -ConfigPath " + (Quote $ConfigPath) + " $extraArgs *> " + (Quote $logFile)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $log.Clear()
    Write-Log "[$(Get-Date -Format 'HH:mm:ss')] $what started`n"
    $progress.Value = 0
    $script:job = @{ kind = "import"; proc = [System.Diagnostics.Process]::Start($psi); log = $logFile; shown = 0; total = 0; done = 0 }
    Set-Busy $true $what
}

function Read-NewLog {
    $j = $script:job
    if (-not (Test-Path -LiteralPath $j.log)) { return }
    try {
        $fs = [System.IO.File]::Open($j.log, "Open", "Read", "ReadWrite, Delete")
        $sr = New-Object System.IO.StreamReader($fs, $true)
        $all = $sr.ReadToEnd(); $sr.Dispose()
    } catch { return }
    if ($all.Length -le $j.shown) { return }
    $new = $all.Substring($j.shown)
    if (-not $j.proc.HasExited) {
        # only whole lines while it's still writing
        $cut = $new.LastIndexOf("`n"); if ($cut -lt 0) { return }
        $new = $new.Substring(0, $cut + 1)
    }
    $j.shown += $new.Length
    Write-Log $new
    foreach ($line in ($new -split "`n")) {
        if ($line -match 'Source: .* - (\d+) file') { $j.total += [int]$Matches[1] }
        elseif ($line -match 'Copying |previously imported') { $j.done++ }
    }
    if ($j.total -gt 0) { $progress.Value = [math]::Min(100, [int](100 * $j.done / $j.total)) }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$timer.Add_Tick({
    $j = $script:job
    if ($j) {
        if ($j.kind -eq "import") { Read-NewLog }
        if ($j.proc.HasExited) {
            if ($j.kind -eq "import") {
                Read-NewLog
                Remove-Item -LiteralPath $j.log -Force -ErrorAction SilentlyContinue
                $progress.Value = 100
                if ($j.proc.ExitCode -eq 0) { $msg = "Complete" } else { $msg = "Completed with errors. See the activity log." }
            } else { $msg = "Ready" }
            $script:job = $null
            $script:cfg = Read-Config $ConfigPath
            Refresh-Cameras
            Refresh-Cards
            $script:driveSig = Get-DriveSignature
            Set-Busy $false $msg
            Update-SetupState
            # the photo window / another program just closed: come back to the front rather
            # than staying behind whatever Windows switched to
            if ($script:mainForm.WindowState -eq "Minimized") { $script:mainForm.WindowState = "Normal" }
            $script:mainForm.Activate()
        }
        return
    }
    # nothing running: notice cards going in and out
    $sig = Get-DriveSignature
    if ($sig -ne $script:driveSig) {
        $script:driveSig = $sig
        Refresh-Cards
    }
})

# ============================================================
#  Actions
# ============================================================
function Show-Info([string]$text, [string]$icon = "Information") {
    [void][System.Windows.Forms.MessageBox]::Show($script:mainForm, $text, "Camera Ingest", "OK", $icon)
}

function Invoke-ImportNow {
    if (Test-Busy) { return }
    if (-not $script:cfg) { Invoke-SetUp; return }
    Refresh-Cards
    $ready = @()
    foreach ($s in $script:sources) {
        if ($s.media.Count -eq 0) { continue }
        $hit = Find-CameraForSource $script:cfg $s
        if ($hit) { $ready += @{ src = $s; cam = $hit.camera } }
    }
    if ($ready.Count -eq 0) {
        Show-Info "No recognized memory card was detected.`n`nInsert a memory card. A card listed as Unrecognized requires a camera profile (Add Camera)."
        return
    }
    # cameras set to "start without asking" don't get this question
    if (@($ready | Where-Object { -not $_.cam.autoStart }).Count -gt 0) {
        $lines = ($ready | ForEach-Object { "   {0}  {1}  ({2} items)" -f $_.src.root.TrimEnd('\'), $_.cam.name, $_.src.media.Count }) -join "`n"
        $ok = [System.Windows.Forms.MessageBox]::Show($script:mainForm, "The following media will be imported:`n`n$lines`n`nThe settings of each camera profile will be applied. Continue?", "Import", "OKCancel", "Question")
        if ($ok -ne "OK") { return }
    }
    Start-Engine "" "Import"
}

function Invoke-ImportFolder {
    if (Test-Busy) { return }
    if (-not $script:cfg -or @($script:cfg.cameras | Where-Object { -not (Test-SpecialCamera $_) }).Count -eq 0) { Show-Info "No camera profiles are configured. Add a camera first."; return }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select the folder to import. Files in this folder are not modified or deleted."
    if ($dlg.ShowDialog($script:mainForm) -ne "OK") { return }
    $folder = $dlg.SelectedPath
    $script:mainForm.Cursor = "WaitCursor"
    $src = Get-SourceInfo $folder
    $hit = Find-CameraForSource $script:cfg $src
    $script:mainForm.Cursor = "Default"
    if ($src.media.Count -eq 0) { Show-Info "The selected folder contains no photos or videos."; return }

    # camera profile, and practice or real - in the same 98 frame as every other dialog
    $d = New-RetroDialog "Import Folder" 380 214
    $l = New-DlgLabel ("Source: {0}`n{1} photos, {2} videos" -f $folder, $src.photos.Count, $src.videos.Count) 0 0 348 30
    $l.AutoEllipsis = $true
    $l2 = New-DlgLabel "Camera profile:" 0 46
    $combo = New-Object System.Windows.Forms.ComboBox; $combo.DropDownStyle = "DropDownList"
    $combo.Location = New-Object System.Drawing.Point(96, 42); $combo.Width = 252
    foreach ($c in $script:cfg.cameras) { if (-not (Test-SpecialCamera $c)) { [void]$combo.Items.Add($c.name) } }
    $combo.SelectedIndex = 0
    if ($hit) { $combo.SelectedItem = $hit.camera.name }
    $chk = New-DlgCheck "Practice import (copy to a practice folder only)" 0 78
    $ok = New-DlgButton "OK" 192 124; $ok.DialogResult = "OK"
    $cancel = New-DlgButton "Cancel" 273 124; $cancel.DialogResult = "Cancel"
    $d.body.Controls.AddRange(@($l, $l2, $combo, $chk, $ok, $cancel))
    $d.form.AcceptButton = $ok; $d.form.CancelButton = $cancel
    if ((Show-Modal $d.form $script:mainForm) -ne "OK") { return }
    $extra = "-Source " + (Quote $folder) + " -Camera " + (Quote ([string]$combo.SelectedItem))
    $what = "Folder import"
    if ($chk.Checked) { $extra += " -Practice"; $what = "Practice import" }
    Start-Engine $extra $what
}

function Test-Busy {
    # one thing at a time: while an import (or the text menus) runs, other actions wait
    if (-not $script:job) { return $false }
    Show-Info "An operation is in progress. Wait for it to complete before continuing."
    return $true
}

function Save-AppConfig {
    # every dialog edits $script:cfg in place; this writes it and refreshes the window
    try { Save-Config $script:cfg $ConfigPath }
    catch { Show-Info "The settings could not be saved.`n`n$($_.Exception.Message)" "Error"; return $false }
    Update-SetupState
    Refresh-Cameras
    Refresh-Cards
    return $true
}

function Get-SelectedCamera {
    # index of the camera picked in My cameras; with just one camera, that one
    if (-not $script:cfg -or $script:cfg.cameras.Count -eq 0) { return -1 }
    if ($lvCams.SelectedIndices.Count -gt 0) { return [int]$lvCams.SelectedIndices[0] }
    if ($script:cfg.cameras.Count -eq 1) { return 0 }
    return -1
}

function Invoke-SetUp {
    if (Test-Busy) { return }
    $new = Show-WelcomeDialog $script:mainForm
    if (-not $new) { return }
    $script:cfg = $new
    if (-not (Save-AppConfig)) { return }
    Write-Log "Library: $($script:cfg.libraryRoot)`nNext: add a camera.`n"
    Invoke-AddCamera
}

function Invoke-AddCamera {
    if (Test-Busy) { return }
    if (-not $script:cfg) { Invoke-SetUp; return }
    $r = Show-CameraDialog $script:mainForm $script:cfg
    if (-not $r) { return }
    if (-not (Save-AppConfig)) { return }
    Write-Log "Camera added: $($r.camera.name)`n"
    if ($r.source -and $r.source.media.Count -gt 0) {
        $go = [System.Windows.Forms.MessageBox]::Show($script:mainForm, "Run a practice import from this card?`n`nFiles are copied to a practice folder to preview names and dates. The card is not modified and nothing is exported.", "Camera Ingest", "YesNo", "Question")
        if ($go -eq "Yes") { Start-PracticeRun $r.camera.name $r.source.root }
    }
}

function Invoke-EditCamera {
    if (Test-Busy) { return }
    if (-not $script:cfg) { Invoke-SetUp; return }
    if ($script:cfg.cameras.Count -eq 0) { Invoke-AddCamera; return }
    $i = Get-SelectedCamera
    if ($i -lt 0) { Show-Info "Select a camera in the Cameras list."; return }
    if (Test-SpecialCamera $script:cfg.cameras[$i]) { $r = Show-SpecialCameraDialog $script:mainForm $script:cfg $i }
    else { $r = Show-CameraDialog $script:mainForm $script:cfg $i }
    if ($r) { [void](Save-AppConfig); $lvCams.Items[$i].Selected = $true }
    if ($r -and $r.run) { Invoke-RunSpecial }
}

function Invoke-AddSpecial {
    if (Test-Busy) { return }
    if (-not $script:cfg) { Invoke-SetUp; return }
    $r = Show-SpecialCameraDialog $script:mainForm $script:cfg
    if (-not $r) { return }
    [void](Save-AppConfig)
    Write-Log "External camera added: $($r.camera.name)`n"
    $lvCams.Items[$script:cfg.cameras.Count - 1].Selected = $true
    if ($r.run) { Invoke-RunSpecial }
}

function Invoke-RunSpecial {
    # start a special camera's own importer in its own window; Camera Ingest waits for it
    if (Test-Busy) { return }
    $i = Get-SelectedCamera
    if ($i -lt 0 -or -not (Test-SpecialCamera $script:cfg.cameras[$i])) {
        Show-Info "Select an external camera (shown in italics) in the Cameras list."
        return
    }
    $cam = $script:cfg.cameras[$i]
    try { $p = Start-SpecialCamera $cam }
    catch { Show-Info "The importer for $($cam.name) could not be started.`n`n$($_.Exception.Message)`n`nVerify the program path in the camera settings." "Error"; return }
    Write-Log "External importer started: $($cam.name)`n"
    $script:job = @{ kind = "tool"; proc = $p }
    Set-Busy $true "External importer running: $($cam.name)"
}

function Start-PracticeRun([string]$camName, [string]$root) {
    Start-Engine ("-Source " + (Quote $root) + " -Camera " + (Quote $camName) + " -Practice") "Practice import"
}

function Invoke-PracticeCamera {
    if (Test-Busy) { return }
    $i = Get-SelectedCamera
    if ($i -lt 0) { Show-Info "Select a camera in the Cameras list."; return }
    $cam = $script:cfg.cameras[$i]
    if (Test-SpecialCamera $cam) { Show-Info "$($cam.name) uses an external importer. Practice imports are not available for external cameras."; return }
    Refresh-Cards
    $card = $script:sources | Where-Object { $_.media.Count -gt 0 -and (Find-CameraForSource $script:cfg $_).camera.name -eq $cam.name } | Select-Object -First 1
    if ($card) { $root = $card.root }
    else {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "No card for $($cam.name) is inserted. Select a folder of its photos for the practice import."
        if ($dlg.ShowDialog($script:mainForm) -ne "OK") { return }
        $root = $dlg.SelectedPath
    }
    Start-PracticeRun $cam.name $root
}

function Invoke-TestCards {
    if (Test-Busy) { return }
    Refresh-Cards
    $lines = @()
    foreach ($s in $script:sources) {
        if ($s.media.Count -eq 0) { $lines += "$($s.root.TrimEnd('\'))  No media"; continue }
        $hit = Find-CameraForSource $script:cfg $s
        if ($hit) { $lines += "$($s.root.TrimEnd('\'))  ->  $($hit.camera.name)   ($($hit.reason))" }
        else { $lines += "$($s.root.TrimEnd('\'))  ->  Unrecognized" }
    }
    if ($lines.Count -eq 0) { $lines = @("No memory card or USB drive detected.") }
    Show-Info ("Camera assignment for inserted media:`n`n" + ($lines -join "`n"))
}

function Move-SelectedCamera([int]$step) {
    if (Test-Busy) { return }
    # cameras are checked top to bottom, so order decides who wins a card both could claim
    $i = Get-SelectedCamera
    $j = $i + $step
    if ($i -lt 0 -or $j -lt 0 -or $j -ge $script:cfg.cameras.Count) { return }
    $list = [System.Collections.ArrayList]@($script:cfg.cameras)
    $cam = $list[$i]; $list.RemoveAt($i); $list.Insert($j, $cam)
    $script:cfg.cameras = @($list)
    if (Save-AppConfig) { $lvCams.Items[$j].Selected = $true; $lvCams.Focus() }
}

function Remove-SelectedCamera {
    if (Test-Busy) { return }
    $i = Get-SelectedCamera
    if ($i -lt 0) { Show-Info "Select a camera in the Cameras list."; return }
    $name = $script:cfg.cameras[$i].name
    $ok = [System.Windows.Forms.MessageBox]::Show($script:mainForm, "Remove the camera profile $name?`n`nImported files, originals and import history are not affected.", "Camera Ingest", "YesNo", "Question")
    if ($ok -ne "Yes") { return }
    $script:cfg.cameras = @($script:cfg.cameras | Where-Object { $_.name -ne $name })
    [void](Save-AppConfig)
}

function Invoke-Review {
    if (Test-Busy) { return }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select a folder of photos to review."
    if (Get-ICloudPhotosFolder) { $dlg.Description += " Do not select an iCloud Photos folder: deletions there are synchronized to all devices." }
    if ($dlg.ShowDialog($script:mainForm) -ne "OK") { return }
    # -Command with single quotes, not -File "...": a drive root like E:\ would turn \" into an
    # escaped quote and mangle the folder
    $cmd = "& " + (Quote (Join-Path $PSScriptRoot "RotateReview.ps1")) + " -Folder " + (Quote $dlg.SelectedPath)
    $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
    $script:job = @{ kind = "review"; proc = $p }
    Set-Busy $true "Reviewing photos"
}

function Invoke-Settings {
    if (Test-Busy) { return }
    if (-not $script:cfg) { Invoke-SetUp; return }
    if (Show-SettingsDialog $script:mainForm $script:cfg) { [void](Save-AppConfig) }
}

function Invoke-TextMenus {
    if (Test-Busy) { return }
    # the keyboard version of everything, for people who prefer it
    $p = Start-Process powershell.exe -PassThru -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`" -ConfigPath `"{1}`"" -f (Join-Path $PSScriptRoot "Menu.ps1"), $ConfigPath)
    $script:job = @{ kind = "menu"; proc = $p }
    Set-Busy $true "Text mode is open in a separate window"
}

function Invoke-Guide { Start-Process (Join-Path $script:AppRoot "How to use.html") }

function Invoke-OpenLibrary {
    if ($script:cfg -and (Test-Path -LiteralPath $script:cfg.libraryRoot)) { Start-Process explorer.exe $script:cfg.libraryRoot }
    else { Show-Info "The library folder does not exist yet. It is created by the first import." }
}

function Invoke-Shortcut {
    $lnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "Camera Ingest.lnk"
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = "powershell.exe"
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $s.WorkingDirectory = $script:AppRoot
    $s.Description = "Import memory cards by camera"
    $s.Save()
    Show-Info "A Camera Ingest shortcut was created on the desktop."
}

function Invoke-About {
    Show-Info ("Camera Ingest`nVersion $($script:AppVersion)`n`nImports memory cards by camera profile: identifies each card, applies naming, date and conversion rules, and prevents duplicate imports.`n`nMIT License")
}

# ---- buttons ----
$bImport = New-SideButton "&Import Now"       { Invoke-ImportNow }
$bFolder = New-SideButton "Import &Folder" { Invoke-ImportFolder }
$bAdd    = New-SideButton "&Add Camera"      { Invoke-AddCamera }
$bEdit   = New-SideButton "Camera &Settings" { Invoke-EditCamera }
$bReview = New-SideButton "&Review Photos" { Invoke-Review }
$bSet    = New-SideButton "Se&ttings"        { Invoke-Settings }
$bGuide  = New-SideButton "User &Guide"            { Invoke-Guide }

$lvCams.Add_DoubleClick({ Invoke-EditCamera })

# right-click a camera
$camMenu = New-Object System.Windows.Forms.ContextMenuStrip
$camMenu.RenderMode = "System"
function Add-CamMenuItem([string]$text, [scriptblock]$action) {
    if ($text -eq "-") { [void]$camMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)); return }
    $it = New-Object System.Windows.Forms.ToolStripMenuItem($text); $it.Add_Click($action); [void]$camMenu.Items.Add($it); return $it
}
$cmEdit  = Add-CamMenuItem "&Properties" { Invoke-EditCamera }
$cmRun   = Add-CamMenuItem "&Run External Importer" { Invoke-RunSpecial }
$cmPrac  = Add-CamMenuItem "&Practice Import" { Invoke-PracticeCamera }
Add-CamMenuItem "-" $null
$cmUp    = Add-CamMenuItem "Move &Up" { Move-SelectedCamera -1 }
$cmDown  = Add-CamMenuItem "Move &Down" { Move-SelectedCamera 1 }
Add-CamMenuItem "-" $null
$cmRem   = Add-CamMenuItem "&Remove" { Remove-SelectedCamera }
$camMenu.Add_Opening({
    # nothing to act on (no cameras, or busy): don't open
    if (-not $script:cfg -or $script:cfg.cameras.Count -eq 0 -or $script:job) { $_.Cancel = $true; return }
    # show only what fits the camera right-clicked: its own importer, or a practice run
    $i = Get-SelectedCamera
    $special = ($i -ge 0 -and (Test-SpecialCamera $script:cfg.cameras[$i]))
    $cmRun.Visible = $special
    $cmPrac.Visible = -not $special
})
$lvCams.ContextMenuStrip = $camMenu

# ---- menus ----
$miImport = Add-MenuItem $mFile "&Import Now" { Invoke-ImportNow }
$miFolder = Add-MenuItem $mFile "Import from &Folder" { Invoke-ImportFolder }
Add-MenuItem $mFile "-" $null
$miRefresh = Add-MenuItem $mFile "&Refresh Media" { Refresh-Cards }
$miShort = Add-MenuItem $mFile "Create &Desktop Shortcut" { Invoke-Shortcut }
Add-MenuItem $mFile "-" $null
$null = Add-MenuItem $mFile "E&xit" { $script:mainForm.Close() }
$miAdd  = Add-MenuItem $mCams "&Add Camera" { Invoke-AddCamera }
$miAddS = Add-MenuItem $mCams "Add &External Camera" { Invoke-AddSpecial }
$miRunS = Add-MenuItem $mCams "Run External &Importer" { Invoke-RunSpecial }
$miEdit = Add-MenuItem $mCams "Camera &Properties" { Invoke-EditCamera }
$miPrac = Add-MenuItem $mCams "&Practice Import" { Invoke-PracticeCamera }
$miTest = Add-MenuItem $mCams "&Identify Inserted Media" { if ($script:cfg) { Invoke-TestCards } }
Add-MenuItem $mCams "-" $null
$miUp   = Add-MenuItem $mCams "Move &Up" { Move-SelectedCamera -1 }
$miDown = Add-MenuItem $mCams "Move &Down" { Move-SelectedCamera 1 }
$miRem  = Add-MenuItem $mCams "&Remove Camera" { Remove-SelectedCamera }
$miRev  = Add-MenuItem $mTools "&Review Photos" { Invoke-Review }
$miSet  = Add-MenuItem $mTools "&Settings" { Invoke-Settings }
$miLib  = Add-MenuItem $mTools "Open &Library Folder" { Invoke-OpenLibrary }
Add-MenuItem $mTools "-" $null
$miText = Add-MenuItem $mTools "&Text Mode" { Invoke-TextMenus }
$null = Add-MenuItem $mHelp "User &Guide" { Invoke-Guide }
Add-MenuItem $mHelp "-" $null
$null = Add-MenuItem $mHelp "&About Camera Ingest" { Invoke-About }

$script:actionControls = @($bImport, $bFolder, $bAdd, $bEdit, $bReview, $bSet,
                           $miImport, $miFolder, $miRefresh, $miAdd, $miAddS, $miRunS, $miEdit, $miPrac, $miTest, $miUp, $miDown, $miRem,
                           $miRev, $miSet, $miText)

function Update-SetupState {
    # before first-run setup there's only one thing to do
    if ($script:cfg) {
        $bAdd.Text = "&Add Camera"
        $bImport.Enabled = ($script:cfg.cameras.Count -gt 0)
    } else {
        $bAdd.Text = "&Set Up"
        $bImport.Enabled = $false
    }
}

$script:mainForm.Add_FormClosing({
    if ($script:job -and -not $script:job.proc.HasExited) {
        Show-Info "An operation is in progress. Wait for it to complete, or close its window, before exiting." "Warning"
        $_.Cancel = $true
    }
})

$script:mainForm.Add_Shown({
    Update-SetupState
    Refresh-Cameras
    Refresh-Cards
    $script:driveSig = Get-DriveSignature
    if ($script:cfg) {
        Write-Log "Ready. Insert a memory card and select Import Now.`n"
        Set-Status "Ready"
    } else {
        Write-Log "Camera Ingest is not configured. Select Set Up to choose a library folder and add a camera.`n"
        Set-Status "Not configured"
    }
    $timer.Start()
    if ($DemoFolder -and $DemoCamera) {
        Start-Engine ("-Source " + (Quote $DemoFolder) + " -Camera " + (Quote $DemoCamera)) "Folder import"
    }
    if ($Snapshot) {
        $snap = New-Object System.Windows.Forms.Timer
        $snap.Interval = 1500
        $snap.Add_Tick({
            if ($script:job) { return }    # wait for a demo import to finish
            $this.Stop()
            $bmp = New-Object System.Drawing.Bitmap($script:mainForm.Width, $script:mainForm.Height)
            $script:mainForm.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $script:mainForm.Width, $script:mainForm.Height)))
            $bmp.Save($Snapshot, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
            $script:mainForm.Close()
        })
        $snap.Start()
    }
})

if ($SelfTest) {
    # Press each button / menu command that opens a dialog, the way a person would. A watcher
    # closes whatever dialog opens and logs its title; any error is logged too.
    $script:stLog = $SelfTest
    $script:stSteps = @(
        @("Add Camera",          { $bAdd.PerformClick() }),
        @("Camera Properties",   { $lvCams.Items[0].Selected = $true; $bEdit.PerformClick() }),
        @("Settings",            { $bSet.PerformClick() }),
        @("Add External Camera", { $miAddS.PerformClick() }),
        @("External Camera",     { $i = [array]::IndexOf(@($script:cfg.cameras | ForEach-Object { Test-SpecialCamera $_ }), $true)
                                   if ($i -ge 0) { $lvCams.Items[$i].Selected = $true; $miEdit.PerformClick() } else { Add-Content $script:stLog "skip: no special camera" } }),
        # the same dialogs again, closed with their own title-bar X instead
        @("Add Camera (X)",      { $script:stByX = $true; $bAdd.PerformClick() }),
        @("Settings (X)",        { $script:stByX = $true; $bSet.PerformClick() }),
        @("Main still open",     { Add-Content $script:stLog "main window open: $($script:mainForm.Visible -and -not $script:mainForm.IsDisposed)" })
    )
    $script:stByX = $false
    $script:stNext = 0
    $watch = New-Object System.Windows.Forms.Timer; $watch.Interval = 400
    $watch.Add_Tick({
        foreach ($f in @([System.Windows.Forms.Application]::OpenForms)) {
            # (window handles, not -eq: PowerShell wraps the objects, so they never compare equal)
            if ($f.Handle -eq $script:mainForm.Handle -or -not $f.Visible) { continue }
            Add-Content $script:stLog "opened: $($f.Text)"
            if ($script:stByX) {
                # click the dialog's own title-bar X, exactly as a person would
                $script:stByX = $false
                $title = $f.Controls | Where-Object { $_ -is [System.Windows.Forms.Panel] -and $_.Dock -eq "Top" } | Select-Object -First 1
                $x = $title.Controls | Where-Object { $_.Tag -and $_.Tag.kind -eq [System.Windows.Forms.CaptionButton]::Close } | Select-Object -First 1
                $onClick = [System.Windows.Forms.Control].GetMethod("OnClick", [System.Reflection.BindingFlags]"NonPublic, Instance")
                $onClick.Invoke($x, @([System.EventArgs]::Empty))
                Add-Content $script:stLog "closed with X: $($f.Text)"
            } else { $f.Close() }
        }
    })
    $driver = New-Object System.Windows.Forms.Timer; $driver.Interval = 600
    $driver.Add_Tick({
        # one step at a time: a dialog keeps timers running, so pause until this step is over
        $this.Stop()
        if ($script:stNext -ge $script:stSteps.Count) { Add-Content $script:stLog "done"; $script:mainForm.Close(); return }
        $step = $script:stSteps[$script:stNext]; $script:stNext++
        Add-Content $script:stLog "press: $($step[0])"
        $Error.Clear()
        try { & $step[1] } catch { Add-Content $script:stLog "error: $($_.Exception.Message)" }
        foreach ($e in $Error) { Add-Content $script:stLog "error: $($e.Exception.Message)" }
        $this.Start()
    })
    $script:mainForm.Add_Shown({ $watch.Start(); $driver.Start() })
}

[void]$script:mainForm.ShowDialog()
$timer.Stop()
