# ============================================================
#  Camera Ingest - photo viewer demo / check
#  Builds a few test photos, runs the viewer through an "import"
#  and a scripted review (rotate one, delete one), saves a picture
#  of each mode, and checks the files on disk afterwards.
#    powershell -ExecutionPolicy Bypass -File tests\Viewer-Demo.ps1 [-Out <folder for the pngs>]
# ============================================================
param([string]$Out = "")

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\src\Viewer.ps1")

$Root = Join-Path $env:TEMP ("camera-ingest-viewer-" + (Get-Date -Format "yyyyMMddHHmmss"))
New-Item -ItemType Directory -Path (Join-Path $Root "Incoming") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Root "RAW Originals") -Force | Out-Null
if (-not $Out) { $Out = $Root }
$script:pass = 0; $script:fail = 0
function Check([string]$what, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host "  PASS  $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL  $what" -ForegroundColor Red }
}

# coloured test photos with a big number, landscape and portrait
$colors = @("SteelBlue", "IndianRed", "SeaGreen", "Goldenrod", "MediumPurple", "Teal")
$files = @()
for ($i = 1; $i -le 6; $i++) {
    $w = 640; $h = 480; if ($i -eq 3) { $w = 480; $h = 640 }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromName($colors[$i - 1]))
    $g.DrawString("$i", (New-Object System.Drawing.Font("Arial", 120, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::White, 40, 40)
    $g.Dispose()
    $p = Join-Path $Root "Incoming\Demo Cam ($i).JPG"
    $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Jpeg); $bmp.Dispose()
    $files += $p
}
[IO.File]::WriteAllBytes((Join-Path $Root "RAW Originals\Demo Cam (5).ARW"), [byte[]](1..64))   # #5 shot RAW+JPEG

# ---- import mode ----
$v = New-PhotoViewer "Importing - Demo Cam"
Show-Viewer $v
for ($i = 0; $i -lt $files.Count; $i++) {
    Set-ViewerStatus $v ("Copying {0} of {1}:  DSC0000{0}.JPG" -f ($i + 1), ($files.Count + 1)) $i ($files.Count + 1)
    Add-ViewerPhoto $v $files[$i] ("DSC0000{0}.JPG  ->  Demo Cam ({0}).JPG" -f ($i + 1))
    $v.lastBig = [datetime]::MinValue      # demo: show every one big
}
Add-ViewerPhoto $v "" "MOV00007.AVI  ->  Demo Cam (7).MP4" "VIDEO"
Set-ViewerStatus $v "Copied 7 of 7 - getting the review ready..." 7 7
Save-ViewerSnapshot $v (Join-Path $Out "viewer-import.png")
Check "import mode: one tile per file, video as a labelled tile" ($v.strip.Controls.Count -eq 7)

# ---- review mode, driven by the same actions the buttons/keys use ----
$script:step = 0
$driver = New-Object System.Windows.Forms.Timer
$driver.Interval = 250
$driver.Add_Tick({
    $vv = $script:demoViewer
    switch ($script:step) {
        0 { Invoke-ViewerAction $vv "next"; Invoke-ViewerAction $vv "next" }     # to photo 3 (the portrait)
        1 { Invoke-ViewerAction $vv "left" }                                     # turn it upright
        2 { Invoke-ViewerAction $vv "next"; Invoke-ViewerAction $vv "next" }     # to photo 5
        3 { Invoke-ViewerAction $vv "delete" }                                   # mark #5, moves to #6
        4 { Invoke-ViewerAction $vv "back" }                                     # look at the red tile
        5 { Save-ViewerSnapshot $vv $script:reviewPng }
        6 { Invoke-ViewerAction $vv "done"; $this.Stop() }
    }
    $script:step++
})
$script:demoViewer = $v
$script:reviewPng = Join-Path $Out "viewer-review.png"
$driver.Start()
$r = Invoke-ViewerReview $v $files @((Join-Path $Root "RAW Originals")) "Review the imported files. No files have been copied yet." "&Finish Import"
Close-Viewer $v

Check "review reports 1 rotated, 1 deleted ($($r.rotated), $($r.deleted))" ($r.rotated -eq 1 -and $r.deleted -eq 1)
$p3 = [System.Drawing.Image]::FromFile($files[2]); $w3 = $p3.Width; $p3.Dispose()
Check "portrait photo #3 was saved turned (now $w3 wide)" ($w3 -eq 640)
Check "deleted photo #5 is gone" (-not (Test-Path $files[4]))
Check "...and its RAW twin went with it" (-not (Test-Path (Join-Path $Root "RAW Originals\Demo Cam (5).ARW")))
Check "untouched photos still there" ((Test-Path $files[0]) -and (Test-Path $files[5]))
Check "both snapshots written" ((Test-Path (Join-Path $Out "viewer-import.png")) -and (Test-Path $script:reviewPng))
$sh = New-Object -ComObject Shell.Application
foreach ($b in @($sh.NameSpace(10).Items() | Where-Object { $_.Name -like "Demo Cam (5)*" })) { Remove-Item -LiteralPath $b.Path -Force -ErrorAction SilentlyContinue }

# ---- the real engine in window mode: copy, review (delete one, turn one), send ----
. (Join-Path $PSScriptRoot "..\src\Engine.ps1")
$card = Join-Path $Root "card"
New-Item -ItemType Directory -Path (Join-Path $card "DCIM\100") -Force | Out-Null
for ($i = 1; $i -le 4; $i++) {
    $w = 640; $h = 480; if ($i -eq 2) { $w = 480; $h = 640 }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::FromName($colors[$i])); $g.Dispose()
    $p = Join-Path $card "DCIM\100\IMG_000$i.JPG"
    $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Jpeg); $bmp.Dispose()
    (Get-Item $p).LastWriteTime = (Get-Date "2025-09-0$i 10:00")
}
$cfg = New-DefaultConfig; $cfg.libraryRoot = Join-Path $Root "Library"
$cam = New-CameraProfile "Window Cam"; $cam.review = "ask"; $cfg.cameras = @($cam)
$script:step2 = 0
$clicker = New-Object System.Windows.Forms.Timer
$clicker.Interval = 300
$clicker.Add_Tick({
    $f = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -like "Review*" }) | Select-Object -First 1
    if (-not $f -or $f.Tag.mode -ne "review") { return }    # still copying
    switch ($script:step2) {
        0 { Invoke-ViewerAction $f.Tag "next" }      # to photo 2 (portrait)
        1 { Invoke-ViewerAction $f.Tag "right" }     # turn it
        2 { Invoke-ViewerAction $f.Tag "next" }      # to photo 3 (saves the turn)
        3 { Invoke-ViewerAction $f.Tag "delete" }    # reject photo 3
        4 { Invoke-ViewerAction $f.Tag "done"; $this.Stop() }
    }
    $script:step2++
})
$clicker.Start()
$rE = Invoke-CameraImport -Config $cfg -Camera $cam -Source (Get-SourceInfo $card) -FromFolder -Gui 6>$null
$dest = Get-CameraDestination $cfg $cam
$sent = @(Get-ChildItem -LiteralPath $dest -File | Select-Object -ExpandProperty Name)
Check "window-mode import copied all 4 ($($rE.copied))" ($rE.copied -eq 4)
Check "photo deleted in the review never reached the destination ($($sent -join ', '))" ($sent.Count -eq 3 -and $sent -notcontains "Window Cam (3).JPG")
$p2 = [System.Drawing.Image]::FromFile((Join-Path $dest "Window Cam (2).JPG")); $w2 = $p2.Width; $p2.Dispose()
Check "photo turned in the review arrived turned ($w2 wide)" ($w2 -eq 640)
Check "nothing left waiting in Incoming" (@(Get-ChildItem -LiteralPath (Join-Path (Get-CameraFolder $cfg $cam) "Incoming") -File).Count -eq 0)
Check "the photo window closed afterwards" (@([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -like "Review*" -or $_.Text -like "Importing*" }).Count -eq 0)
foreach ($b in @($sh.NameSpace(10).Items() | Where-Object { $_.Name -like "Window Cam (3)*" })) { Remove-Item -LiteralPath $b.Path -Force -ErrorAction SilentlyContinue }

Write-Host ("  {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -eq 0 -and $Out -ne $Root) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
exit $script:fail
