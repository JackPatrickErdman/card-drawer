# ============================================================
#  Camera Ingest - dialog checks
#  Opens the Add Camera, Camera Settings, Settings and Welcome
#  dialogs, fills them in with a timer the way a person would,
#  snapshots every tab, presses OK / Cancel, and checks what was
#  saved. Windows appear on screen briefly.
#    powershell -ExecutionPolicy Bypass -File tests\Dialogs-Test.ps1 [-Out <folder for pngs>]
# ============================================================
param([string]$Out = "")

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\src\Retro.ps1")
. (Join-Path $PSScriptRoot "..\src\Common.ps1")
. (Join-Path $PSScriptRoot "..\src\Dialogs.ps1")

$Root = Join-Path $env:TEMP ("camera-ingest-dialogs-" + (Get-Date -Format "yyyyMMddHHmmss"))
New-Item -ItemType Directory -Path $Root -Force | Out-Null
if (-not $Out) { $Out = $Root }
$script:pass = 0; $script:fail = 0
function Check([string]$what, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host "  PASS  $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL  $what" -ForegroundColor Red }
}
function Snap($form, [string]$name) {
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save((Join-Path $Out $name), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
function Get-Tabs($form) { $form.Controls | ForEach-Object { $_.Controls } | Where-Object { $_ -is [System.Windows.Forms.TabControl] } | Select-Object -First 1 }

# A script that runs one step per timer tick against the open dialog whose title matches
function Start-Driver([string]$titleLike, [scriptblock[]]$steps) {
    $script:steps = $steps; $script:stepNo = 0; $script:titleLike = $titleLike; $script:driverErr = ""
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 200
    $t.Add_Tick({
        $f = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -like $script:titleLike }) | Select-Object -First 1
        if (-not $f -or -not $f.Visible) { return }
        if ($script:stepNo -ge $script:steps.Count) { $this.Stop(); return }
        try { & $script:steps[$script:stepNo] $f } catch { $script:driverErr = "$($_.Exception.Message)"; $this.Stop(); $f.Close() }
        $script:stepNo++
    })
    $t.Start()
    return $t
}

$cfg = New-DefaultConfig
$cfg.libraryRoot = Join-Path $Root "Library"
$cfgPath = Join-Path $Root "config.json"
$owner = New-Object System.Windows.Forms.Form   # dialogs need an owner; this one is never shown

# ---- Add Camera: name, date+time naming, then a custom pattern, a model rule, import options ----
$drv = Start-Driver "Add Camera*" @(
    { param($f) $f.Tag.c.name.Text = "Test Cam"; Snap $f "dlg-add-general.png" },
    { param($f) (Get-Tabs $f).SelectedIndex = 2; $f.Tag.c.style[1].Checked = $true },
    { param($f) $script:previewDateTime = $f.Tag.c.preview.Text; Snap $f "dlg-add-files.png" },
    { param($f) $f.Tag.c.styleCustom.Checked = $true; $f.Tag.c.pattern.Text = "{year}-{month} {name} {n:4}" },
    { param($f) $script:previewCustom = $f.Tag.c.preview.Text; $script:labelSynced = $f.Tag.c.label.Text },
    { param($f) (Get-Tabs $f).SelectedIndex = 1; $f.Tag.c.model.Text = "^DSC-X1$"; $f.Tag.c.catchVideos.Checked = $true },
    { param($f) $script:modelHint = $f.Tag.c.modelHint.Text; Snap $f "dlg-add-recognize.png" },
    { param($f) (Get-Tabs $f).SelectedIndex = 3; $f.Tag.c.deleteCard.Checked = $true; $f.Tag.c.autoStart.Checked = $true; $f.Tag.c.reviewNever.Checked = $true
                $f.Tag.c.datesAuto.Checked = $true; $f.Tag.c.staleDays.Value = 400 },
    { param($f) Snap $f "dlg-add-import.png"; $f.Tag.c.ok.PerformClick() }
)
$r = Show-CameraDialog $owner $cfg
$drv.Stop()
Check "add dialog ran without errors ($script:driverErr)" ($script:driverErr -eq "")
Check "add dialog returned the new camera" ($r -and $r.camera.name -eq "Test Cam")
$cam = $cfg.cameras | Where-Object { $_.name -eq "Test Cam" }
Check "camera added to the settings" ($cam -ne $null)
Check "custom naming pattern saved" ($cam.naming -eq "{year}-{month} {name} {n:4}")
Check "{name} label followed the camera name" ($script:labelSynced -eq "Test Cam" -and $cam.prefix -eq "Test Cam")
Check "live preview showed the date+time style ($script:previewDateTime)" ($script:previewDateTime -match '^\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}\.JPG')
Check "live preview followed the custom pattern ($script:previewCustom)" ($script:previewCustom -match '^\d{4}-\d{2} Test Cam 0001\.JPG')
Check "model rule saved and explained ('$script:modelHint')" ($cam.match.exifModel -eq "^DSC-X1$" -and $script:modelHint -eq "'DSC-X1'")
Check "catch-all, delete, auto-start, never-review saved" ($cam.match.content -eq "videos" -and $cam.deleteFromCard -and $cam.autoStart -and $cam.review -eq "never")
Check "'fix only dates older than 400 days' saved" ($cam.dates -eq "auto" -and $cam.staleDays -eq 400)

# ---- Camera Settings: change destination, OK ----
$other = Join-Path $Root "Elsewhere"
$drv = Start-Driver "Camera Properties*" @(
    { param($f) (Get-Tabs $f).SelectedIndex = 2; $f.Tag.c.destOther.Checked = $true; $f.Tag.c.destPath.Text = $other },
    { param($f) $script:browseEnabled = $f.Tag.c.destBrowse.Enabled; Snap $f "dlg-edit-files.png"; $f.Tag.c.ok.PerformClick() }
)
$r = Show-CameraDialog $owner $cfg 0
$drv.Stop()
Check "edit dialog ran without errors ($script:driverErr)" ($script:driverErr -eq "")
Check "destination changed to the chosen folder" ($cfg.cameras[0].destination -eq $other)
Check "Browse button enabled with 'Somewhere else'" ($script:browseEnabled -eq $true)
Check "untouched settings kept (pattern still custom)" ($cfg.cameras[0].naming -eq "{year}-{month} {name} {n:4}")

# ---- Cancel leaves everything as it was ----
$before = ConvertTo-Json -InputObject $cfg -Depth 8
$drv = Start-Driver "Camera Properties*" @(
    { param($f) $f.Tag.c.name.Text = "Should Not Save"; $f.Tag.c.deleteCard.Checked = $false },
    { param($f) $f.Tag.c.cancel.PerformClick() }
)
$r = Show-CameraDialog $owner $cfg 0
$drv.Stop()
Check "Cancel returns nothing" ($null -eq $r)
Check "Cancel changes nothing" ((ConvertTo-Json -InputObject $cfg -Depth 8) -eq $before)

# ---- Settings: change the library folder ----
$newLib = Join-Path $Root "Library2"
$drv = Start-Driver "Settings" @(
    { param($f) $f.Tag.c.library.Text = $newLib; Snap $f "dlg-settings.png" },
    { param($f) $f.Tag.c.ok.PerformClick() }
)
$saved = Show-SettingsDialog $owner $cfg
$drv.Stop()
Check "settings dialog saved the library folder" ($saved -and $cfg.libraryRoot -eq $newLib)

# ---- Welcome: picture, then Cancel ----
$drv = Start-Driver "Camera Ingest Setup*" @(
    { param($f) Snap $f "dlg-welcome.png" },
    { param($f) $f.Tag.c.cancel.PerformClick() }
)
$w = Show-WelcomeDialog $owner
$drv.Stop()
Check "welcome dialog Cancel returns nothing" ($null -eq $w)

# ---- Special camera: name, about, program, OK ----
$prog = Join-Path $Root "Import Stereo Camera.bat"; Set-Content $prog "@echo off" -Encoding ASCII
$drv = Start-Driver "Add External Camera*" @(
    { param($f) $f.Tag.c.name.Text = "Stereo Camera"; $f.Tag.c.about.Text = "Pulls from the Pi over Wi-Fi"; $f.Tag.c.program.Text = $prog },
    { param($f) Snap $f "dlg-special.png"; $f.Tag.c.ok.PerformClick() }
)
$rs = Show-SpecialCameraDialog $owner $cfg
$drv.Stop()
$spc = $cfg.cameras | Where-Object { $_.name -eq "Stereo Camera" }
Check "special camera dialog saved it as a special camera ($script:driverErr)" ($rs -and $spc -and (Test-SpecialCamera $spc) -and $spc.program -eq $prog -and -not $rs.run)
$cfg.cameras = @($cfg.cameras | Where-Object { -not (Test-SpecialCamera $_) })

# ---- the saved file reads back the same ----
Save-Config $cfg $cfgPath
$re = Read-Config $cfgPath
Check "config with dialog-made cameras reads back" ($re.cameras.Count -eq 1 -and $re.cameras[0].naming -eq "{year}-{month} {name} {n:4}" -and $re.cameras[0].autoStart -eq $true)
foreach ($png in @("dlg-add-general.png", "dlg-add-files.png", "dlg-add-recognize.png", "dlg-add-import.png", "dlg-edit-files.png", "dlg-settings.png", "dlg-welcome.png")) {
    if (-not (Test-Path (Join-Path $Out $png))) { Check "snapshot $png" $false }
}

$owner.Dispose()
Write-Host ("  {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -eq 0) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
exit $script:fail
