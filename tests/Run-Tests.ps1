# ============================================================
#  Card Drawer - self tests
#  Builds fake cards in a temp folder (JPEGs with a camera model
#  in EXIF, a RAW+JPEG pair, an AVI and an MP4) and checks the
#  matcher and the import engine end to end. Never touches real
#  drives, your settings or your library.
#    powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
#  Needs Python + Pillow for the EXIF fixtures and ffmpeg for the
#  video ones; those checks are skipped (and say so) without them.
# ============================================================

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\src\Engine.ps1")

$Root = Join-Path $env:TEMP ("card-drawer-tests-" + (Get-Date -Format "yyyyMMddHHmmss"))
New-Item -ItemType Directory -Path $Root -Force | Out-Null
$script:pass = 0; $script:fail = 0; $script:skip = 0

function Check([string]$what, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host "  PASS  $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL  $what" -ForegroundColor Red }
}
function Skip([string]$what) { $script:skip++; Write-Host "  SKIP  $what" -ForegroundColor Yellow }

# ---- fixture makers ----
$cfg = New-DefaultConfig
$cfg.libraryRoot = Join-Path $Root "Library"
# point the tests at tools that aren't on PATH:  $env:INGEST_TEST_FFMPEG = "C:\...\ffmpeg.exe"
if ($env:INGEST_TEST_FFMPEG)    { $cfg.tools.ffmpeg    = $env:INGEST_TEST_FFMPEG }
if ($env:INGEST_TEST_HANDBRAKE) { $cfg.tools.handbrake = $env:INGEST_TEST_HANDBRAKE }
$tools = Get-Tools $cfg
$py = $tools.python
$hasPil = $false
if ($py) { $null = & $py -c "import PIL" 2>&1; $hasPil = ($LASTEXITCODE -eq 0) }

function New-Jpg([string]$path, [string]$model, [datetime]$when, [string]$make = "") {
    if ($hasPil) {
        # (PowerShell 5.1 drops empty arguments, so a missing model arrives as no argv[2])
        $code = "import sys; from PIL import Image; m = sys.argv[2] if len(sys.argv) > 2 else ''; " +
                "mk = sys.argv[3] if len(sys.argv) > 3 else ''; " +
                "im = Image.new('RGB', (64, 48), (200, 80, 40)); ex = Image.Exif(); ex.update({272: m} if m else {}); " +
                "ex.update({271: mk} if mk else {}); im.save(sys.argv[1], 'JPEG', exif=ex.tobytes())"
        if ($make) { & $py -c $code $path $model $make 2>&1 | Out-Null }
        elseif ($model) { & $py -c $code $path $model 2>&1 | Out-Null }
        else { & $py -c $code $path 2>&1 | Out-Null }
    } else {
        $bmp = New-Object System.Drawing.Bitmap 64, 48
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Jpeg); $bmp.Dispose()
    }
    # make each file unique so the dedup ledger doesn't merge fixtures
    [IO.File]::AppendAllText($path, [guid]::NewGuid().ToString())
    (Get-Item $path).LastWriteTime = $when
}

function New-Card([string]$name) {
    $d = Join-Path $Root $name
    New-Item -ItemType Directory -Path (Join-Path $d "DCIM\100TEST") -Force | Out-Null
    return $d
}

$shotTime = Get-Date "2004-06-15 14:30:00"

# ============================================================
Write-Title "MATCHER"
# ============================================================
$card = New-Card "match_card"
New-Jpg (Join-Path $card "DCIM\100TEST\KIF_0001.JPG") "TESTCAM X1" $shotTime
$vidCard = New-Card "video_card"
[IO.File]::WriteAllBytes((Join-Path $vidCard "VID001.AVI"), [byte[]](1..64))

$bySerial = New-CameraProfile "By Serial";   $bySerial.match.serials = @("ABCD1234")
$byModel  = New-CameraProfile "By Model";    $byModel.match.exifModel = '^TESTCAM X1$'
$byName   = New-CameraProfile "By Name";     $byName.match.fileNames = '^KIF_\d{4}'
$catchP   = New-CameraProfile "Catch Photos"; $catchP.match.content = "photos"
$catchV   = New-CameraProfile "Catch Videos"; $catchV.match.content = "videos"
$byDrive  = New-CameraProfile "By Drive";    $byDrive.match.drive = "A:"

$srcSerial = Get-SourceInfo $card "ABCD-1234" "CARD"
$srcPlain  = Get-SourceInfo $card "FFFF0000" "CARD"
$srcVid    = Get-SourceInfo $vidCard "11112222" "DVR"

if ($hasPil) { Check "EXIF camera model read from JPEG ('$($srcPlain.exifModel)')" ($srcPlain.exifModel -eq "TESTCAM X1") }
else { Skip "EXIF model (no Python+Pillow)" }

$m = New-DefaultConfig; $m.cameras = @($bySerial)
Check "serial match, dash in 'ABCD-1234' normalized" ((Find-CameraForSource $m $srcSerial).camera.name -eq "By Serial")
Check "different serial doesn't match" ($null -eq (Find-CameraForSource $m $srcPlain))
$m.cameras = @($byName, $bySerial)
Check "among specific rules, list order decides" ((Find-CameraForSource $m $srcSerial).camera.name -eq "By Name")
$m.cameras = @($catchP, $bySerial)
Check "specific rule beats a catch-all listed above it" ((Find-CameraForSource $m $srcSerial).camera.name -eq "By Serial")
if ($hasPil) {
    $m.cameras = @($catchP, $byModel)
    Check "EXIF model rule matches" ((Find-CameraForSource $m $srcPlain).camera.name -eq "By Model")
}
$m.cameras = @($catchP, $byName)
Check "file name rule matches" ((Find-CameraForSource $m $srcPlain).camera.name -eq "By Name")
$m.cameras = @($catchV, $catchP)
Check "photos card -> photo catch-all, not the video one" ((Find-CameraForSource $m $srcPlain).camera.name -eq "Catch Photos")
Check "videos-only card -> video catch-all" ((Find-CameraForSource $m $srcVid).camera.name -eq "Catch Videos")
$m.cameras = @($bySerial, $byDrive)
Check "unknown card matches nothing" ($null -eq (Find-CameraForSource $m $srcVid))
$fl = Get-SourceInfo $card "" "" $true; $fl.drive = "A:"     # as if this folder were drive A:
Check "drive-letter rule matches anything in that drive" ((Find-CameraForSource $m $fl).camera.name -eq "By Drive")
$fl.drive = "E:"
Check "drive-letter rule ignores other drives" ($null -eq (Find-CameraForSource $m $fl))
$fl.drive = "A:"
$legacy = ConvertTo-CameraProfile ([PSCustomObject]@{ name = "Old"; match = [PSCustomObject]@{ floppy = $true } })
Check "an older config saying floppy=true becomes drive A:" ($legacy.match.drive -eq "A:")
Check "a drive root gets its letter, a folder gets none" ((Get-SourceInfo "Q:\").drive -eq "Q:" -and (Get-SourceInfo $card).drive -eq "")

# ============================================================
Write-Title "PRESETS"
# ============================================================
$presets = @(Get-Presets)
Check "all preset files load ($($presets.Count))" ($presets.Count -ge 13 -and @($presets | Where-Object { -not $_.title }).Count -eq 0)
function PresetNamed([string]$like) { $presets | Where-Object { $_.title -like $like } | Select-Object -First 1 }
$m.cameras = @((New-CameraFromPreset (PresetNamed "Fixed drive*") "Reader"))
Check "fixed-drive preset claims drive A:" ((Find-CameraForSource $m $fl).camera.name -eq "Reader")
Check "fixed-drive preset ignores a card in another drive" ($null -eq (Find-CameraForSource $m $srcPlain))
$m.cameras = @((New-CameraFromPreset (PresetNamed "Dashcam*") "Dash"))
Check "dashcam preset claims a videos-only card" ((Find-CameraForSource $m $srcVid).camera.name -eq "Dash")
if ($hasPil) {
    $brand = New-Card "brand_card"
    New-Jpg (Join-Path $brand "DCIM\100TEST\DSC00001.JPG") "DSC-T7" $shotTime "SONY"
    $srcBrand = Get-SourceInfo $brand "12340000"
    Check "camera maker read from JPEG ('$($srcBrand.exifMake)')" ($srcBrand.exifMake -eq "SONY")
    $m.cameras = @((New-CameraFromPreset (PresetNamed "Canon*") "Canon"), (New-CameraFromPreset (PresetNamed "Sony Cyber*") "Sony"))
    Check "brand preset picks the Sony card by maker" ((Find-CameraForSource $m $srcBrand).camera.name -eq "Sony")
} else { Skip "brand presets (no Python+Pillow)" }
$shareMe = New-CameraProfile "Mine"; $shareMe.match.serials = @("DEADBEEF"); $shareMe.destination = "C:\Users\someone\Secret"
$pf = Save-CameraAsPreset $shareMe "Shared Test" "test" (Join-Path $Root "presets_out")
$pj = Get-Content $pf -Raw
Check "shared preset leaves out card serials and folders" (-not ($pj -match 'DEADBEEF') -and -not ($pj -match 'Secret'))

# ============================================================
Write-Title "CONFIG ROUND TRIP"
# ============================================================
$cfgPath = Join-Path $Root "config.json"
$c1 = New-DefaultConfig; $one = New-CameraProfile "Solo"; $one.match.serials = @("AAAA1111")
$c1.cameras = @($one)
Save-Config $c1 $cfgPath
$c2 = Read-Config $cfgPath
Check "one camera survives save/load as a list" ($c2.cameras.Count -eq 1 -and $c2.cameras[0].name -eq "Solo")
Check "one serial survives as a list" (@($c2.cameras[0].match.serials).Count -eq 1 -and $c2.cameras[0].match.serials[0] -eq "AAAA1111")
$raw = Get-Content $cfgPath -Raw | ConvertFrom-Json
$raw.cameras[0].PSObject.Properties.Remove("review"); $raw.cameras[0].PSObject.Properties.Remove("autoStart")
$raw | ConvertTo-Json -Depth 8 | Set-Content $cfgPath -Encoding UTF8
Check "missing fields in a hand-edited config get defaults" ((Read-Config $cfgPath).cameras[0].review -eq "ask" -and (Read-Config $cfgPath).cameras[0].autoStart -eq $false)

# ============================================================
Write-Title "FULL IMPORT (sequential names, delete after verify)"
# ============================================================
$card = New-Card "card_a"
$dcim = Join-Path $card "DCIM\100TEST"
New-Jpg (Join-Path $dcim "DSC00001.JPG") "TESTCAM X1" $shotTime
New-Jpg (Join-Path $dcim "DSC00002.JPG") "TESTCAM X1" $shotTime.AddMinutes(1)
# RAW+JPEG pair: the camera's JPG should go out under the RAW's number
[IO.File]::WriteAllBytes((Join-Path $dcim "DSC00003.ARW"), [byte[]](10..200)); (Get-Item (Join-Path $dcim "DSC00003.ARW")).LastWriteTime = $shotTime.AddMinutes(2)
New-Jpg (Join-Path $dcim "DSC00003.JPG") "TESTCAM X1" $shotTime.AddMinutes(2)
# a junk folder the engine must ignore
New-Item -ItemType Directory -Path (Join-Path $card "System Volume Information") -Force | Out-Null
New-Jpg (Join-Path $card "System Volume Information\junk.jpg") "" $shotTime
$haveVideo = [bool]$tools.ffmpeg
if ($haveVideo) {
    & $tools.ffmpeg -y -loglevel error -f lavfi -i testsrc=duration=1:size=160x120:rate=10 -c:v mjpeg (Join-Path $dcim "MOV00004.AVI") 2>$null | Out-Null
    (Get-Item (Join-Path $dcim "MOV00004.AVI")).LastWriteTime = $shotTime.AddMinutes(3)
}
[IO.File]::WriteAllBytes((Join-Path $dcim "CLIP0005.MP4"), [byte[]](50..120)); (Get-Item (Join-Path $dcim "CLIP0005.MP4")).LastWriteTime = $shotTime.AddMinutes(4)

$cam = New-CameraProfile "Test Cam"
$cam.deleteFromCard = $true
$cfg.cameras = @($cam)
$src = Get-SourceInfo $card "ABCD1234" "CARD"
$r = Invoke-CameraImport -Config $cfg -Camera $cam -Source $src -Yes -NoEject 6>$null
$camDir = Get-CameraFolder $cfg $cam
$media = Join-Path $camDir "Media"
$names = @(Get-ChildItem $media -File | Select-Object -ExpandProperty Name)

Check "junk folder ignored" (-not ($names -match 'junk'))
Check "photos numbered Test Cam (1)/(2)" (($names -contains "Test Cam (1).JPG") -and ($names -contains "Test Cam (2).JPG"))
Check "RAW kept locally as Test Cam (3).ARW" (Test-Path (Join-Path $camDir "RAW Originals\Test Cam (3).ARW"))
Check "RAW's own camera JPG sent as Test Cam (3).JPG" ($names -contains "Test Cam (3).JPG")
Check "RAW not sent to the destination" (-not ($names -contains "Test Cam (3).ARW"))
if ($haveVideo) {
    Check "AVI converted to Test Cam (4).MP4" ($names -contains "Test Cam (4).MP4")
    Check "original AVI kept in Converted Originals" (Test-Path (Join-Path $camDir "Converted Originals\Test Cam (4).AVI"))
    $ErrorActionPreference = "Continue"   # ffmpeg prints its info on stderr
    $ct = & $tools.ffmpeg -hide_banner -i (Join-Path $media "Test Cam (4).MP4") 2>&1 | ForEach-Object { "$_" } | Select-String "creation_time" | Select-Object -First 1
    $ErrorActionPreference = "Stop"
    Check "capture date written inside the MP4 ($($ct.Line.Trim()))" ($ct -and $ct.Line -match '2004-06-15')
    $mp4Name = "Test Cam (5).MP4"
} else { Skip "AVI conversion (no ffmpeg)"; $mp4Name = "Test Cam (4).MP4" }
Check "MP4 copied as-is ($mp4Name)" ($names -contains $mp4Name)
Check "capture date kept on photo file" ((Get-Item (Join-Path $media "Test Cam (1).JPG")).LastWriteTime -eq $shotTime)
Check "Incoming emptied after send" (@(Get-ChildItem (Join-Path $camDir "Incoming") -File).Count -eq 0)
$left = @(Get-ChildItem $dcim -File)
Check "card files deleted after verified copy" ($left.Count -eq 0)
Check "junk on card left alone" (Test-Path (Join-Path $card "System Volume Information\junk.jpg"))
$ledgerRows = @(Import-Csv (Join-Path $camDir "imported_media.csv"))
Check "ledger has one row per imported file ($($ledgerRows.Count))" ($ledgerRows.Count -eq $r.copied)

# ============================================================
Write-Title "SAME FILES AGAIN (dedup)"
# ============================================================
$card2 = New-Card "card_a_again"
Copy-Item (Join-Path $media "Test Cam (1).JPG") (Join-Path $card2 "DCIM\100TEST\DSC00001.JPG")
Copy-Item (Join-Path $media "Test Cam (2).JPG") (Join-Path $card2 "DCIM\100TEST\DSC00002.JPG")
New-Jpg (Join-Path $card2 "DCIM\100TEST\DSC00010.JPG") "TESTCAM X1" $shotTime.AddDays(1)
$before = @(Get-ChildItem $media -File).Count
$r2 = Invoke-CameraImport -Config $cfg -Camera $cam -Source (Get-SourceInfo $card2 "ABCD1234") -Yes -NoEject 6>$null
Check "2 duplicates recognized" ($r2.skippedDup -eq 2)
Check "only the 1 new photo imported" ($r2.copied -eq 1 -and @(Get-ChildItem $media -File).Count -eq $before + 1)
$expectNext = if ($haveVideo) { 6 } else { 5 }
Check "numbering continues at Test Cam ($expectNext)" (Test-Path (Join-Path $media "Test Cam ($expectNext).JPG"))
Check "duplicates removed from card (delete mode, copy exists)" (@(Get-ChildItem (Join-Path $card2 "DCIM\100TEST") -File).Count -eq 0)

# ============================================================
Write-Title "KEEP NAMES + IMPORT DATES + NEVER DELETE"
# ============================================================
$cam2 = New-CameraProfile "Keeper"
$cam2.naming = "keep"; $cam2.dates = "import"; $cam2.deleteFromCard = $false
$cfg.cameras = @($cam, $cam2)
$card3 = New-Card "card_keep"
New-Jpg (Join-Path $card3 "DCIM\100TEST\IMG_00001.JPG") "" $shotTime
New-Item -ItemType Directory -Path (Join-Path $card3 "DCIM\101TEST") -Force | Out-Null
New-Jpg (Join-Path $card3 "DCIM\101TEST\IMG_00001.JPG") "" $shotTime   # same name, different content
$t0 = Get-Date
$r3 = Invoke-CameraImport -Config $cfg -Camera $cam2 -Source (Get-SourceInfo $card3 "99998888") -Yes -NoEject 6>$null
$kmedia = Get-CameraDestination $cfg $cam2
Check "camera names kept" (Test-Path (Join-Path $kmedia "IMG_00001.JPG"))
Check "name clash gets _2 instead of overwriting" (Test-Path (Join-Path $kmedia "IMG_00001_2.JPG"))
Check "import date stamped (bad clock mode)" ((Get-Item (Join-Path $kmedia "IMG_00001.JPG")).LastWriteTime -ge $t0.AddSeconds(-2))
Check "card untouched when delete is off" (@(Get-ChildItem $card3 -Recurse -File).Count -eq 2)

# ============================================================
Write-Title "WRONG-CLOCK DATES INSIDE THE FILE"
# ============================================================
if ($hasPil) {
    $dj = Join-Path $Root "dead_clock.JPG"
    & $py -c "import sys; from PIL import Image; ex=Image.Exif(); ex[306]='2001:01:01 00:00:00'; ex[34665]={36867:'2001:01:01 00:00:00', 36868:'2001:01:01 00:00:00'}; im=Image.new('RGB',(64,48),(9,99,199)); im.save(sys.argv[1],'JPEG',exif=ex.tobytes())" $dj 2>&1 | Out-Null
    $before = [IO.File]::ReadAllBytes($dj)
    $pxBefore = & $py -c "import sys,hashlib; from PIL import Image; print(hashlib.sha256(Image.open(sys.argv[1]).tobytes()).hexdigest())" $dj
    $n = Set-JpegDate $dj (Get-Date "2026-10-26 12:34:56")
    $after = [IO.File]::ReadAllBytes($dj)
    $readBack = & $py -c "import sys; from PIL import Image; e=Image.open(sys.argv[1]).getexif(); print(e.get(306), e.get_ifd(34665).get(36867))" $dj
    $pxAfter = & $py -c "import sys,hashlib; from PIL import Image; print(hashlib.sha256(Image.open(sys.argv[1]).tobytes()).hexdigest())" $dj
    Check "all three EXIF dates rewritten ($n)" ($n -eq 3 -and $readBack -eq "2026:10:26 12:34:56 2026:10:26 12:34:56")
    Check "picture pixels identical (no re-compression)" ($pxBefore -eq $pxAfter)
    Check "file size unchanged (dates swapped in place)" ($before.Length -eq $after.Length)
    $nodate = Join-Path $Root "no_date.JPG"; New-Jpg $nodate "" $shotTime
    Check "a photo without EXIF dates is left alone" ((Set-JpegDate $nodate (Get-Date)) -eq 0)
    # through the engine: the card copy is redated, an untouched original kept
    $cardD = New-Card "card_deadclock"
    Copy-Item $dj (Join-Path $cardD "DCIM\100TEST\OLD.JPG")
    & $py -c "import sys; from PIL import Image; ex=Image.Exif(); ex[306]='2001:01:01 00:00:00'; Image.new('RGB',(8,8)).save(sys.argv[1],'JPEG',exif=ex.tobytes())" (Join-Path $cardD "DCIM\100TEST\OLD.JPG") 2>&1 | Out-Null
    $camD = New-CameraProfile "Dead Clock"; $camD.dates = "import"
    $cfg.cameras = @($cam, $camD)
    $null = Invoke-CameraImport -Config $cfg -Camera $camD -Source (Get-SourceInfo $cardD "77776666") -Yes -NoEject 6>$null
    $outD = Join-Path (Get-CameraDestination $cfg $camD) "Dead Clock (1).JPG"
    $dOut = & $py -c "import sys; from PIL import Image; print(Image.open(sys.argv[1]).getexif().get(306))" $outD
    $dKept = & $py -c "import sys; from PIL import Image; print(Image.open(sys.argv[1]).getexif().get(306))" (Join-Path (Get-CameraFolder $cfg $camD) "Unprocessed Originals\Dead Clock (1).JPG")
    Check "imported photo carries today's date inside ($dOut)" ($dOut -like "$((Get-Date).ToString('yyyy:MM:dd'))*")
    Check "untouched original (2001 date) kept in Unprocessed Originals" ($dKept -eq "2001:01:01 00:00:00")
} else { Skip "EXIF date rewriting (no Python+Pillow)" }

# ============================================================
Write-Title "NAMING PATTERNS"
# ============================================================
$t1 = Get-Date "2006-06-15 14:30:05"
$cardN = New-Card "card_names"
New-Jpg (Join-Path $cardN "DCIM\100TEST\A1.JPG") "" $t1
New-Jpg (Join-Path $cardN "DCIM\100TEST\A2.JPG") "" $t1             # same second
New-Jpg (Join-Path $cardN "DCIM\100TEST\A3.JPG") "" $t1.AddMinutes(5)
$camT = New-CameraProfile "Timed"; $camT.naming = "{date} {time}"
$cfg.cameras = @($camT)
$null = Invoke-CameraImport -Config $cfg -Camera $camT -Source (Get-SourceInfo $cardN "12121212") -Yes -NoEject 6>$null
$tm = Get-CameraDestination $cfg $camT
Check "date+time names from when the shot was taken" (Test-Path (Join-Path $tm "2006-06-15 14-30-05.JPG"))
Check "same-second shot gets _2 instead of clashing" (Test-Path (Join-Path $tm "2006-06-15 14-30-05_2.JPG"))
Check "next shot gets its own time" (Test-Path (Join-Path $tm "2006-06-15 14-35-05.JPG"))

$camP = New-CameraProfile "Padded"; $camP.naming = "IMG-{year}-{n:4}"
$cfg.cameras = @($camP)
$null = Invoke-CameraImport -Config $cfg -Camera $camP -Source (Get-SourceInfo $cardN "12121212") -Yes -NoEject 6>$null
$pm = Get-CameraDestination $cfg $camP
Check "custom pattern with padded count (IMG-2006-0001..0003)" ((Test-Path (Join-Path $pm "IMG-2006-0001.JPG")) -and (Test-Path (Join-Path $pm "IMG-2006-0003.JPG")))
$cardN2 = New-Card "card_names2"; New-Jpg (Join-Path $cardN2 "DCIM\100TEST\B1.JPG") "" (Get-Date "2007-01-01")
$camP.prefix = "Renamed"                                                 # label change: count must carry on
$null = Invoke-CameraImport -Config $cfg -Camera $camP -Source (Get-SourceInfo $cardN2 "12121212") -Yes -NoEject 6>$null
Check "count carries on across imports, even in a new year (IMG-2007-0004)" (Test-Path (Join-Path $pm "IMG-2007-0004.JPG"))

# two cameras writing into one shared folder keep their own counts
$shared = Join-Path $Root "shared_dest"
$camS1 = New-CameraProfile "Alpha"; $camS1.destination = $shared
$camS2 = New-CameraProfile "Beta";  $camS2.destination = $shared
$cfg.cameras = @($camS1, $camS2)
$cardS1 = New-Card "card_s1"; foreach ($i in 1..3) { New-Jpg (Join-Path $cardS1 "DCIM\100TEST\S$i.JPG") "" $t1.AddMinutes($i) }
$cardS2 = New-Card "card_s2"; New-Jpg (Join-Path $cardS2 "DCIM\100TEST\Z1.JPG") "" $t1
$null = Invoke-CameraImport -Config $cfg -Camera $camS1 -Source (Get-SourceInfo $cardS1 "1") -Yes -NoEject 6>$null
$null = Invoke-CameraImport -Config $cfg -Camera $camS2 -Source (Get-SourceInfo $cardS2 "2") -Yes -NoEject 6>$null
Check "a second camera in the same folder starts at its own (1)" (Test-Path (Join-Path $shared "Beta (1).JPG"))

# older settings files
$old = ConvertTo-CameraProfile ([PSCustomObject]@{ name = "Old"; naming = "sequential"; offerReview = $false })
$old2 = ConvertTo-CameraProfile ([PSCustomObject]@{ name = "Old2"; naming = "keep" })
Check "older 'sequential' naming becomes the running-count pattern" ($old.naming -eq "{name} ({n})")
Check "older 'keep' naming becomes {orig}" ($old2.naming -eq "{orig}")
Check "older offerReview=false becomes review=never" ($old.review -eq "never")
Check "pattern checker catches unknown tags and non-unique patterns" (((Test-NamingPattern "{nme}") -match 'Unknown') -and ((Test-NamingPattern "{date}") -match 'own name') -and ((Test-NamingPattern "{date} {time}") -eq ""))

# ============================================================
Write-Title "LIBRARY ON A DRIVE THAT ISN'T PLUGGED IN"
# ============================================================
$cfgQ = New-DefaultConfig; $cfgQ.libraryRoot = "Q:\Photos"
$camQ = New-CameraProfile "Unplugged"; $cfgQ.cameras = @($camQ)
Check "paths still work out with the drive missing" ((Get-CameraDestination $cfgQ $camQ) -eq "Q:\Photos\Unplugged\Media")
$cardQ = New-Card "card_unplugged"; New-Jpg (Join-Path $cardQ "DCIM\100TEST\Q1.JPG") "" $t1
$camQ.deleteFromCard = $true
$rQ = Invoke-CameraImport -Config $cfgQ -Camera $camQ -Source (Get-SourceInfo $cardQ "4") -Yes -NoEject 6>$null
Check "import stops cleanly, nothing copied" ($rQ.failed -gt 0 -and $rQ.copied -eq 0)
Check "card left exactly as it was (even with delete-from-card on)" (Test-Path (Join-Path $cardQ "DCIM\100TEST\Q1.JPG"))

# ============================================================
Write-Title "IMPORT HISTORY CAN'T BE WRITTEN"
# ============================================================
# open in Excel = locked: refused up front, nothing touched
$camL = New-CameraProfile "Locked Ledger"; $camL.deleteFromCard = $true
$cfg.cameras = @($camL)
$cardL = New-Card "card_ledger"; foreach ($i in 1..3) { New-Jpg (Join-Path $cardL "DCIM\100TEST\L$i.JPG") "" $t1.AddMinutes($i) }
$null = Invoke-CameraImport -Config $cfg -Camera $camL -Source (Get-SourceInfo $cardL "5") -Yes -NoEject 6>$null   # imports L1-L3
$cardL2 = New-Card "card_ledger2"; foreach ($i in 1..3) { New-Jpg (Join-Path $cardL2 "DCIM\100TEST\M$i.JPG") "" $t1.AddHours($i) }
$ledgerL = Join-Path (Get-CameraFolder $cfg $camL) "imported_media.csv"
$excel = [System.IO.File]::Open($ledgerL, "Open", "Read", "Read")          # how Excel holds a CSV
$rL = Invoke-CameraImport -Config $cfg -Camera $camL -Source (Get-SourceInfo $cardL2 "5") -Yes -NoEject 6>$null
$excel.Dispose()
Check "history open in Excel: import refused before copying anything" ($rL.failed -gt 0 -and $rL.copied -eq 0)
Check "...and the card is untouched" (@(Get-ChildItem (Join-Path $cardL2 "DCIM\100TEST") -File).Count -eq 3)
# fails half-way: the unrecorded copy is undone, the card keeps that file, a re-run finishes cleanly
$env:INGEST_FAULT = "ledger:2"
$rL2 = Invoke-CameraImport -Config $cfg -Camera $camL -Source (Get-SourceInfo $cardL2 "5") -Yes -NoEject 6>$null
$env:INGEST_FAULT = ""
Check "history write fails on file 2: stops after 1 ($($rL2.copied))" ($rL2.copied -eq 1 -and $rL2.failed -gt 0)
Check "...file 2 left on the card, not deleted" (@(Get-ChildItem (Join-Path $cardL2 "DCIM\100TEST") -File).Count -eq 2)
$rL3 = Invoke-CameraImport -Config $cfg -Camera $camL -Source (Get-SourceInfo $cardL2 "5") -Yes -NoEject 6>$null
$rowsL = @(Import-Csv $ledgerL)
Check "re-run imports the rest, nothing twice ($(@($rowsL.Hash | Sort-Object -Unique).Count) unique of $($rowsL.Count) rows)" ($rL3.copied -eq 2 -and @($rowsL.Hash | Sort-Object -Unique).Count -eq $rowsL.Count -and $rowsL.Count -eq 6)
Check "...and no stray copy of file 2 left behind" (@(Get-ChildItem (Get-CameraDestination $cfg $camL) -File).Count -eq 6)

# ============================================================
Write-Title "VIDEOS REACH A CLOUD FOLDER ONCE, FINISHED"
# ============================================================
if ($haveVideo) {
    $ErrorActionPreference = "Continue"     # ffmpeg talks on stderr
    $cloud = Join-Path $Root "cloud_folder"; New-Item -ItemType Directory $cloud -Force | Out-Null
    $camV = New-CameraProfile "Cloud Video"; $camV.destination = $cloud; $camV.dates = "import"
    $cfg.cameras = @($camV)
    $cardV = New-Card "card_video"
    & $tools.ffmpeg -y -loglevel error -f lavfi -i testsrc=duration=1:size=160x120:rate=10 -c:v libx264 -pix_fmt yuv420p -metadata creation_time=2001-01-01T00:00:00Z (Join-Path $cardV "DCIM\100TEST\CLIP1.MP4") 2>$null | Out-Null
    & $tools.ffmpeg -y -loglevel error -f lavfi -i testsrc=duration=1:size=160x120:rate=10 -c:v mjpeg (Join-Path $cardV "DCIM\100TEST\MOV2.AVI") 2>$null | Out-Null
    $watch = New-Object System.IO.FileSystemWatcher($cloud)
    $watch.IncludeSubdirectories = $false; $watch.EnableRaisingEvents = $true
    foreach ($ev in @("Created", "Deleted", "Renamed")) { Register-ObjectEvent $watch $ev -SourceIdentifier "cloud$ev" | Out-Null }
    $rV = Invoke-CameraImport -Config $cfg -Camera $camV -Source (Get-SourceInfo $cardV "6") -Yes -NoEject 6>$null
    Start-Sleep -Milliseconds 500
    $created = @(Get-Event -SourceIdentifier "cloudCreated" -ErrorAction SilentlyContinue).Count
    $removed = @(Get-Event -SourceIdentifier "cloudDeleted" -ErrorAction SilentlyContinue).Count + @(Get-Event -SourceIdentifier "cloudRenamed" -ErrorAction SilentlyContinue).Count
    foreach ($ev in @("Created", "Deleted", "Renamed")) { Unregister-Event -SourceIdentifier "cloud$ev"; Remove-Event -SourceIdentifier "cloud$ev" -ErrorAction SilentlyContinue }
    $watch.Dispose()
    Check "cloud folder saw exactly 2 new files, nothing deleted or swapped ($created created, $removed replaced)" ($created -eq 2 -and $removed -eq 0)
    $ct = (& $tools.ffmpeg -hide_banner -i (Join-Path $cloud "Cloud Video (1).MP4") 2>&1 | ForEach-Object { "$_" } | Select-String "creation_time" | Select-Object -First 1).Line
    Check "the MP4 arrived already re-dated ($($ct.Trim()))" ($ct -match (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd"))
    Check "nothing left in Working" (@(Get-ChildItem (Join-Path (Get-CameraFolder $cfg $camV) "Working") -File).Count -eq 0)
    $frame = Get-VideoFrame (Join-Path $cloud "Cloud Video (1).MP4") $tools
    Check "a still can be taken from a video for the photo window" ($frame -and (Test-Path $frame))
    if ($frame) { Remove-Item $frame -Force }
    $ErrorActionPreference = "Stop"
} else { Skip "videos reach a cloud folder once (no ffmpeg)" }

# a converter that writes something but reports failure must not count as converted
$fake = Join-Path $Root "fake-ffmpeg.cmd"
Set-Content $fake "@echo off`r`nset last=%~1`r`n:loop`r`nif not `"%~2`"==`"`" (set last=%~2& shift & goto loop)`r`necho half-written> `"%last%`"`r`nexit /b 1" -Encoding ASCII
$cfgF = New-DefaultConfig; $cfgF.libraryRoot = Join-Path $Root "LibF"; $cfgF.tools.ffmpeg = $fake; $cfgF.tools.handbrake = Join-Path $Root "no-handbrake.exe"
$camF = New-CameraProfile "Bad Converter"; $cfgF.cameras = @($camF)
$cardF = New-Card "card_badconv"; [IO.File]::WriteAllBytes((Join-Path $cardF "DCIM\100TEST\MOV1.AVI"), [byte[]](1..90))
$rF = Invoke-CameraImport -Config $cfgF -Camera $camF -Source (Get-SourceInfo $cardF "7") -Yes -NoEject 6>$null
Check "converter exit code 1 = conversion failed, even though it wrote a file" ($rF.converted -eq 0 -and $rF.failed -gt 0)
Check "...no half-written MP4 sent out" (@(Get-ChildItem (Get-CameraDestination $cfgF $camF) -File).Count -eq 0)
Check "...original kept in Converted Originals" (Test-Path (Join-Path (Get-CameraFolder $cfgF $camF) "Converted Originals\Bad Converter (1).AVI"))

# ============================================================
Write-Title "LEFTOVERS AND NAME CLASHES ON THE WAY OUT"
# ============================================================
$camO = New-CameraProfile "Outbox"; $camO.naming = "{orig}"
$cfg.cameras = @($camO)
$oDir = Get-CameraFolder $cfg $camO; $oDest = Get-CameraDestination $cfg $camO
New-Item -ItemType Directory (Join-Path $oDir "Incoming"), $oDest -Force | Out-Null
New-Jpg (Join-Path $oDir "Incoming\half.JPG.rotating.tmp") "" $t1               # crash leftover junk
New-Jpg (Join-Path $oDest "IMG_0001.JPG") "" $t1                                # someone else's IMG_0001
$cardO = New-Card "card_outbox"; New-Jpg (Join-Path $cardO "DCIM\100TEST\IMG_0001.JPG") "" $t1
$null = Invoke-CameraImport -Config $cfg -Camera $camO -Source (Get-SourceInfo $cardO "8") -Yes -NoEject 6>$null
Check "a crash's .tmp file is never sent out" (-not (Test-Path (Join-Path $oDest "half.JPG.rotating.tmp")))
Check "a clashing name goes out as _2, the existing file untouched" ((Test-Path (Join-Path $oDest "IMG_0001_2.JPG")) -and (Test-Path (Join-Path $oDest "IMG_0001.JPG")))
$rowO = Import-Csv (Join-Path $oDir "imported_media.csv") | Select-Object -Last 1
Check "import history records the real name it got ($($rowO.ImportedAs))" ($rowO.ImportedAs -eq "IMG_0001_2.JPG")
# a send that finished but couldn't tidy up: next run removes the local copy, doesn't send a second one
$again = Join-Path $oDir "Incoming\IMG_0001_2.JPG"; Copy-Item (Join-Path $oDest "IMG_0001_2.JPG") $again
$null = Invoke-CameraImport -Config $cfg -Camera $camO -Source (Get-SourceInfo $cardO "8") -Yes -NoEject 6>$null
Check "already-sent leftover is tidied, not sent again" (-not (Test-Path $again) -and -not (Test-Path (Join-Path $oDest "IMG_0001_2_2.JPG")))

# ============================================================
Write-Title "SMALL THINGS THE REVIEW FOUND"
# ============================================================
$rxO = Get-PatternRegex "{orig}_{n}" "x"
Check "count found in '{orig}_{n}' names (DSC_0001_5 -> 5)" (("DSC_0001_5" -match $rxO) -and [int]$Matches["n"] -eq 5)
. (Join-Path $PSScriptRoot "..\src\Viewer.ps1")
Check "Recycle Bin: yes on the system drive, no on a network share" ((Test-HasRecycleBin "$env:TEMP\x.jpg") -and -not (Test-HasRecycleBin "\\server\share\x.jpg"))

# ============================================================
Write-Title "FIX ONLY DATES THAT LOOK WRONG"
# ============================================================
$nowT = Get-Date
$camA = New-CameraProfile "Auto Dates"; $camA.dates = "auto"; $camA.staleDays = 365
Check "a 2010 date counts as wrong" ((Get-FileDate $camA (Get-Date "2010-12-31") $nowT).fixed)
Check "yesterday's date is kept" (-not (Get-FileDate $camA $nowT.AddDays(-1) $nowT).fixed)
Check "a date next year counts as wrong" ((Get-FileDate $camA $nowT.AddYears(1) $nowT).fixed)
$camA2 = New-CameraProfile "x"; $camA2.dates = "auto"; $camA2.staleDays = 4000
Check "the cut-off is per camera (4000 days keeps 2020)" (-not (Get-FileDate $camA2 (Get-Date "2020-06-01") $nowT).fixed)
if ($hasPil) {
    $cardA = New-Card "card_autodates"
    $mk = "import sys; from PIL import Image; ex=Image.Exif(); ex[306]=sys.argv[2]; ex[34665]={36867: sys.argv[2]}; Image.new('RGB',(32,24),(200,10,10)).save(sys.argv[1],'JPEG',exif=ex.tobytes())"
    $dates = @(@("OLD.JPG", (Get-Date "2010-12-31 10:00")), @("NEW.JPG", $nowT.AddDays(-1).Date.AddHours(12)), @("FUTURE.JPG", $nowT.AddYears(2).Date))
    foreach ($d in $dates) {
        $p = Join-Path $cardA "DCIM\100TEST\$($d[0])"
        & $py -c $mk $p $d[1].ToString("yyyy:MM:dd HH:mm:ss") 2>&1 | Out-Null
        (Get-Item $p).LastWriteTime = $d[1]
    }
    $cfg.cameras = @($camA)
    $null = Invoke-CameraImport -Config $cfg -Camera $camA -Source (Get-SourceInfo $cardA "9") -Yes -NoEject 6>$null
    $aDir = Get-CameraFolder $cfg $camA; $aDest = Get-CameraDestination $cfg $camA
    $rowsA = @(Import-Csv (Join-Path $aDir "imported_media.csv"))
    $nameOf = @{}; foreach ($r in $rowsA) { $nameOf[$r.OriginalName] = $r.ImportedAs }
    $exif = { param($f) & $py -c "import sys; from PIL import Image; print(Image.open(sys.argv[1]).getexif().get(306))" $f }
    $today = $nowT.ToString("yyyy:MM:dd")
    Check "the 2010 photo got today's date inside" ((& $exif (Join-Path $aDest $nameOf["OLD.JPG"])) -like "$today*")
    Check "the future-dated photo got today's date inside" ((& $exif (Join-Path $aDest $nameOf["FUTURE.JPG"])) -like "$today*")
    Check "yesterday's photo kept its real date" ((& $exif (Join-Path $aDest $nameOf["NEW.JPG"])) -eq $dates[1][1].ToString("yyyy:MM:dd HH:mm:ss"))
    $kept = @(Get-ChildItem (Join-Path $aDir "Unprocessed Originals") -File -ErrorAction SilentlyContinue)
    Check "untouched originals kept for the two that were fixed, none for the good one ($($kept.Count))" ($kept.Count -eq 2)
} else { Skip "fix-wrong-dates import (no Python+Pillow)" }

# ============================================================
Write-Title "SPECIAL CAMERAS (their own importer)"
# ============================================================
$sp = New-CameraProfile "Stereo"; $sp.kind = "special"; $sp.about = "Wi-Fi from the Pi"
$sp.match.content = "photos"; $sp.match.serials = @("12121212")       # rules set by mistake must still be ignored
$plain = New-CameraProfile "Plain"; $plain.match.content = "photos"
$cfgS = New-DefaultConfig; $cfgS.libraryRoot = Join-Path $Root "LibS"; $cfgS.cameras = @($sp, $plain)
$cardS = New-Card "card_special"; New-Jpg (Join-Path $cardS "DCIM\100TEST\S1.JPG") "" $t1
Check "a special camera never claims a card, even listed first with rules" ((Find-CameraForSource $cfgS (Get-SourceInfo $cardS "12121212")).camera.name -eq "Plain")
$rS = Invoke-CameraImport -Config $cfgS -Camera $sp -Source (Get-SourceInfo $cardS "1") -Yes -NoEject 6>$null
Check "the engine refuses to import into a special camera" ($rS.copied -eq 0 -and $rS.failed -gt 0 -and (Test-Path (Join-Path $cardS "DCIM\100TEST\S1.JPG")))
Check "its summary says it has its own importer" ((Get-MatchSummary $sp) -eq "External importer: Wi-Fi from the Pi")
$sp.program = "C:\Tools\My Importer\go.ps1"; $sp.arguments = '-Device "USB Video"'
$l = Get-SpecialLaunch $sp
Check "a .ps1 importer launches through PowerShell with its arguments" ($l.exe -eq "powershell.exe" -and $l.args -match '-File "C:\\Tools\\My Importer\\go\.ps1" -Device "USB Video"$' -and $l.dir -eq "C:\Tools\My Importer")
Save-Config $cfgS (Join-Path $Root "special.json")
$reS = Read-Config (Join-Path $Root "special.json")
Check "special cameras survive save / load" ((Test-SpecialCamera $reS.cameras[0]) -and $reS.cameras[0].program -eq "C:\Tools\My Importer\go.ps1" -and $reS.cameras[0].arguments -eq '-Device "USB Video"')
Check "older settings files read as ordinary card cameras" ((ConvertTo-CameraProfile ([PSCustomObject]@{ name = "Old" })).kind -eq "card")

# ============================================================
Write-Title "HANDS-OFF IMPORT (start without asking, never review)"
# ============================================================
$camH = New-CameraProfile "HandsOff"; $camH.autoStart = $true; $camH.review = "never"
$cfg.cameras = @($camH)
$cardH = New-Card "card_handsoff"; New-Jpg (Join-Path $cardH "DCIM\100TEST\H1.JPG") "" $t1
function global:Read-Host { throw "PROMPTED: $args" }     # any question at all fails this test
$hErr = ""
try { $rH = Invoke-CameraImport -Config $cfg -Camera $camH -Source (Get-SourceInfo $cardH "3") -NoEject 6>$null }
catch { $hErr = $_.Exception.Message }
Remove-Item function:\Read-Host
Check "auto-start camera imports with no questions at all ($hErr)" ($hErr -eq "" -and $rH.copied -eq 1)
Check "...and its photo went straight to the destination" (Test-Path (Join-Path (Get-CameraDestination $cfg $camH) "HandsOff (1).JPG"))

# ============================================================
Write-Title "PRACTICE RUN"
# ============================================================
$card4 = New-Card "card_practice"
New-Jpg (Join-Path $card4 "DCIM\100TEST\P1.JPG") "" $shotTime
$box = Join-Path $Root "practice_box"
$cam.deleteFromCard = $true
$r4 = Invoke-CameraImport -Config $cfg -Camera $cam -Source (Get-SourceInfo $card4 "ABCD1234") -Yes -Sandbox $box 6>$null
Check "practice copies land in the sandbox" (Test-Path (Join-Path $box "Media\Test Cam (1).JPG"))
Check "practice never deletes from the card, even in delete mode" (Test-Path (Join-Path $card4 "DCIM\100TEST\P1.JPG"))
Check "practice doesn't touch the real ledger" (@(Import-Csv (Join-Path $camDir "imported_media.csv")).Count -eq $ledgerRows.Count + 1)

# ============================================================
Write-Title "INTERRUPTED RUN + PHOTO HOOK"
# ============================================================
New-Jpg (Join-Path $camDir "Incoming\Test Cam (99).JPG") "" $shotTime
$cam.photoHook = "echo patched>> {file}"
$card5 = New-Card "card_hook"
New-Jpg (Join-Path $card5 "DCIM\100TEST\H1.JPG") "" $shotTime
$r5 = Invoke-CameraImport -Config $cfg -Camera $cam -Source (Get-SourceInfo $card5 "ABCD1234") -Yes -NoEject 6>$null
Check "leftover photo from an interrupted run gets sent" (Test-Path (Join-Path $media "Test Cam (99).JPG"))
Check "numbering continues past the leftover (Test Cam (100))" (Test-Path (Join-Path $media "Test Cam (100).JPG"))
$hooked = Get-Content (Join-Path $media "Test Cam (100).JPG") -Raw
Check "photo hook ran on the outgoing copy" ($hooked -match 'patched')
Check "untouched original kept in Unprocessed Originals" (-not ((Get-Content (Join-Path $camDir "Unprocessed Originals\Test Cam (100).JPG") -Raw) -match 'patched'))
Check "hook keeps the capture date" ((Get-Item (Join-Path $media "Test Cam (100).JPG")).LastWriteTime -eq $shotTime)

# ============================================================
Write-Title "REVIEW: DELETE"
# ============================================================
$rv = Join-Path $Root "review"
foreach ($d in @("Incoming", "RAW Originals", "Unprocessed Originals")) { New-Item -ItemType Directory -Path (Join-Path $rv $d) -Force | Out-Null }
New-Jpg (Join-Path $rv "Incoming\Test Cam (200).JPG") "" $shotTime
New-Jpg (Join-Path $rv "Incoming\Test Cam (201).JPG") "" $shotTime
[IO.File]::WriteAllBytes((Join-Path $rv "RAW Originals\Test Cam (200).ARW"), [byte[]](1..50))
[IO.File]::WriteAllBytes((Join-Path $rv "RAW Originals\Test Cam (201).ARW"), [byte[]](1..50))
New-Jpg (Join-Path $rv "Unprocessed Originals\Test Cam (200).JPG") "" $shotTime
$ErrorActionPreference = "Continue"
$out = & (Join-Path $PSScriptRoot "..\src\RotateReview.ps1") -TestDelete @((Join-Path $rv "Incoming\Test Cam (200).JPG")) `
    -Companions @((Join-Path $rv "RAW Originals"), (Join-Path $rv "Unprocessed Originals"))
$ErrorActionPreference = "Stop"
Check "deleted photo is gone ($out)" (-not (Test-Path (Join-Path $rv "Incoming\Test Cam (200).JPG")))
Check "its RAW twin went too" (-not (Test-Path (Join-Path $rv "RAW Originals\Test Cam (200).ARW")))
Check "its untouched original went too" (-not (Test-Path (Join-Path $rv "Unprocessed Originals\Test Cam (200).JPG")))
Check "other photos and RAWs untouched" ((Test-Path (Join-Path $rv "Incoming\Test Cam (201).JPG")) -and (Test-Path (Join-Path $rv "RAW Originals\Test Cam (201).ARW")))
$sh = New-Object -ComObject Shell.Application
$inBin = @($sh.NameSpace(10).Items() | Where-Object { $_.Name -like "Test Cam (200)*" })
Check "deleted files are in the Recycle Bin, not gone for good ($($inBin.Count))" ($inBin.Count -ge 1)
foreach ($b in $inBin) { Remove-Item -LiteralPath $b.Path -Force -Recurse -ErrorAction SilentlyContinue }   # tidy the test's own files out of the bin

# a photo deleted in review must not come back from the card next time
$card6 = New-Card "card_reject"
New-Jpg (Join-Path $card6 "DCIM\100TEST\DUD.JPG") "" $shotTime
$cam.photoHook = ""; $cam.deleteFromCard = $false
$r6 = Invoke-CameraImport -Config $cfg -Camera $cam -Source (Get-SourceInfo $card6 "ABCD1234") -Yes -NoEject 6>$null
$dud = Get-ChildItem $media -File | Sort-Object LastWriteTime | Where-Object { $_.Name -eq "Test Cam (101).JPG" }
Remove-Item -LiteralPath $dud.FullName -Force   # as if deleted in the review
$r7 = Invoke-CameraImport -Config $cfg -Camera $cam -Source (Get-SourceInfo $card6 "ABCD1234") -Yes -NoEject 6>$null
Check "rejected photo is not re-imported from the card" ($r7.copied -eq 0 -and $r7.skippedDup -eq 1)
Check "rejected photo is left on the card (it was never safely kept)" (Test-Path (Join-Path $card6 "DCIM\100TEST\DUD.JPG"))

# ============================================================
Write-Host ""
Write-Rule
$color = "Green"; if ($script:fail -gt 0) { $color = "Red" }
Write-Host ("  {0} passed, {1} failed, {2} skipped" -f $script:pass, $script:fail, $script:skip) -ForegroundColor $color
Write-Host "  Test files: $Root" -ForegroundColor DarkGray
if ($script:fail -eq 0) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
exit $script:fail
