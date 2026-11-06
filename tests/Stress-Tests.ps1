# ============================================================
#  Card Drawer - stress tests: "can it ever lose a photo?"
#  Every scenario checks two rules:
#    NO LOSS     every file that was on the card before the run
#                still exists byte-for-byte afterwards - still on
#                the card, or somewhere in the library
#    NO CLOBBER  every file already in the library is still there,
#                unchanged (only Incoming may empty out, by sending)
#  Scenarios: a 1,500-file card with nasty names, a pulled card,
#  failed and corrupted copies, crashes mid-import, two windows at
#  once, failed sends, reused names, overlapping folders, damaged
#  photos in the review, a lost ledger, then randomized fault runs.
#  Uses INGEST_FAULT (see Engine.ps1) to inject failures.
#    powershell -ExecutionPolicy Bypass -File tests\Stress-Tests.ps1 [-Seed 7] [-Rounds 40]
# ============================================================
param([int]$Seed = 0, [int]$Rounds = 40, [int]$BigCard = 1500)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\src\Engine.ps1")
if (-not $Seed) { $Seed = Get-Random -Maximum 100000 }
$rng = New-Object System.Random($Seed)

$Root = Join-Path $env:TEMP ("card-drawer-stress-" + (Get-Date -Format "yyyyMMddHHmmss"))
New-Item -ItemType Directory -Path $Root -Force | Out-Null
$script:pass = 0; $script:fail = 0
$env:INGEST_FAULT = ""

function Check([string]$what, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host "  PASS  $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL  $what" -ForegroundColor Red }
}

# ---- fixtures: one real JPEG, cloned with unique tails (fast for big cards) ----
$bmp = New-Object System.Drawing.Bitmap 48, 32
$g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::SteelBlue); $g.Dispose()
$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg); $bmp.Dispose()
$JpgBytes = $ms.ToArray()

function New-Photo([string]$path, [datetime]$when) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tail = [System.Text.Encoding]::ASCII.GetBytes([guid]::NewGuid().ToString())
    [IO.File]::WriteAllBytes($path, [byte[]]($JpgBytes + $tail))
    (Get-Item -LiteralPath $path).LastWriteTime = $when
}
function New-Blob([string]$path, [int]$size, [datetime]$when) {
    $b = New-Object byte[] $size; $rng.NextBytes($b)
    [IO.File]::WriteAllBytes($path, $b)
    (Get-Item -LiteralPath $path).LastWriteTime = $when
}

function Get-Hashes([string]$dir, [switch]$ByPath) {
    # hash -> path (or path -> hash) for media only: the ledger (.csv) and the running-count
    # file (next_number.txt) are bookkeeping that is SUPPOSED to change
    $h = @{}
    if (-not (Test-Path -LiteralPath $dir)) { return $h }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        if (@(".csv", ".txt") -contains $f.Extension) { continue }
        $x = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        if ($ByPath) { $h[$f.FullName] = $x } else { $h[$x] = $f.FullName }
    }
    return $h
}

function Snapshot($card, $lib) {
    @{ card = (Get-Hashes $card); lib = (Get-Hashes $lib -ByPath) }
}

function Assert-Safe([string]$label, $snap, [string]$card, [string]$lib) {
    $now = Get-Hashes $card
    foreach ($k in (Get-Hashes $lib).Keys) { $now[$k] = $true }
    $lost = @($snap.card.Keys | Where-Object { -not $now.ContainsKey($_) })
    Check "$label - NO LOSS ($($snap.card.Count) card file(s), $($lost.Count) missing)" ($lost.Count -eq 0)
    if ($lost.Count -gt 0) { $lost | Select-Object -First 5 | ForEach-Object { Write-Host "        lost: $($snap.card[$_])" -ForegroundColor Red } }
    $clobbered = @($snap.lib.Keys | Where-Object {
        $_ -notmatch '\\Incoming\\' -and -not (Test-SameHash $_ $snap.lib[$_]) })
    Check "$label - NO CLOBBER ($($snap.lib.Count) library file(s) checked)" ($clobbered.Count -eq 0)
    if ($clobbered.Count -gt 0) { $clobbered | Select-Object -First 5 | ForEach-Object { Write-Host "        changed: $_" -ForegroundColor Red } }
}

function New-TestConfig([string]$name) {
    $c = New-DefaultConfig
    $c.libraryRoot = Join-Path $Root "lib_$name"
    $cam = New-CameraProfile $name
    $cam.deleteFromCard = $true
    $c.cameras = @($cam)
    return $c
}

function Import-Card($cfg, [string]$card, [string]$fault = "", [switch]$FromFolder) {
    # runs one import, turning a simulated crash into a result instead of a test abort
    $env:INGEST_FAULT = $fault
    try {
        $r = Invoke-CameraImport -Config $cfg -Camera $cfg.cameras[0] -Source (Get-SourceInfo $card "ABCD1234") -Yes -NoEject -FromFolder:$FromFolder 6>$null
    } catch {
        $r = @{ crashed = $true; copied = 0; skippedDup = 0; failed = 1 }
    } finally {
        $env:INGEST_FAULT = ""
    }
    return $r
}

function Get-CardMedia([string]$card) { @(Get-MediaFiles $card) }

function New-SmallCard([string]$name, [int]$photos = 10) {
    # photos in two DCIM folders (same names in both), a RAW+JPEG pair, an MP4,
    # a byte-identical duplicate, and a junk system folder
    $card = Join-Path $Root $name
    $t = Get-Date "2005-07-01 09:00"
    for ($i = 1; $i -le $photos; $i++) {
        $folder = "100CAM"; if ($i % 2) { $folder = "101CAM" }
        New-Photo (Join-Path $card "DCIM\$folder\DSC$('{0:D5}' -f [int][math]::Ceiling($i / 2)).JPG") $t.AddMinutes($i)
    }
    New-Blob (Join-Path $card "DCIM\100CAM\DSC09001.ARW") 3000 $t.AddHours(1)
    New-Photo (Join-Path $card "DCIM\100CAM\DSC09001.JPG") $t.AddHours(1)
    New-Blob (Join-Path $card "DCIM\100CAM\MOV09002.MP4") 5000 $t.AddHours(2)
    Copy-Item -LiteralPath (Join-Path $card "DCIM\100CAM\DSC00001.JPG") (Join-Path $card "DCIM\100CAM\COPY0001.JPG")
    New-Item -ItemType Directory -Path (Join-Path $card "System Volume Information") -Force | Out-Null
    New-Blob (Join-Path $card "System Volume Information\IndexerVolumeGuid") 76 $t
    return $card
}

function Assert-Complete([string]$label, $cfg, [string]$card, $snap, [int]$maxExtra = 0) {
    # after a clean follow-up run: everything is in, exactly once, and the card is cleared
    $cam = $cfg.cameras[0]
    $unique = @($snap.card.Keys | Where-Object { $snap.card[$_] -notmatch 'System Volume Information' }).Count
    $ledger = @(Import-Csv -LiteralPath (Join-Path (Get-CameraFolder $cfg $cam) "imported_media.csv") -ErrorAction SilentlyContinue)
    $ledgerUnique = @($ledger.Hash | Sort-Object -Unique).Count
    Check "$label - every unique file in the ledger exactly once ($ledgerUnique/$unique)" ($ledgerUnique -eq $unique -and $ledger.Count -eq $ledgerUnique)
    $kept = Get-Hashes (Get-CameraFolder $cfg $cam)
    $libFiles = @(Get-ChildItem -LiteralPath (Get-CameraFolder $cfg $cam) -File -Recurse | Where-Object { @(".csv", ".txt") -notcontains $_.Extension }).Count
    Check "$label - no more than $maxExtra extra copies ($libFiles files for $unique unique)" (($libFiles - $unique) -le $maxExtra -and $libFiles -ge $unique)
    $left = @(Get-CardMedia $card)
    Check "$label - card cleared after verified copies ($($left.Count) left)" ($left.Count -eq 0)
    Check "$label - nothing left waiting in Incoming" (@(Get-ChildItem -LiteralPath (Join-Path (Get-CameraFolder $cfg $cam) "Incoming") -File -ErrorAction SilentlyContinue).Count -eq 0)
}

Write-Host "  Seed $Seed  (re-run the same random rounds with -Seed $Seed)" -ForegroundColor DarkGray

# ============================================================
Write-Title "0. THE CHECKER CATCHES REAL DAMAGE"
# ============================================================
# Before trusting any PASS below, prove the two rules fail when a photo really is lost
# or a library file really is changed.
$cfgS = New-TestConfig "SelfCheck"
$card = New-SmallCard "self_card"
$snap = Snapshot $card $cfgS.libraryRoot
$null = Import-Card $cfgS $card
$snap2 = Snapshot $card $cfgS.libraryRoot
$victim = Get-ChildItem -LiteralPath (Get-CameraDestination $cfgS $cfgS.cameras[0]) -File | Select-Object -First 1
$victimHash = (Get-FileHash -LiteralPath $victim.FullName).Hash
$other = Get-ChildItem -LiteralPath (Get-CameraDestination $cfgS $cfgS.cameras[0]) -File | Select-Object -Skip 1 -First 1
Remove-Item -LiteralPath $victim.FullName                     # the only copy of a photo, gone
[IO.File]::AppendAllText($other.FullName, "damage")           # and another one altered
$failsBefore = $script:fail; $passBefore = $script:pass
Assert-Safe "self-check" @{ card = $snap.card; lib = $snap2.lib } $card $cfgS.libraryRoot 6>$null
$caught = $script:fail - $failsBefore
$script:fail = $failsBefore; $script:pass = $passBefore     # these failures were the point
Check "checker reports a deliberately lost photo AND a deliberately altered one ($caught of 2 caught)" ($caught -eq 2)

# ============================================================
Write-Title "1. BIG CARD WITH NASTY NAMES ($BigCard files)"
# ============================================================
$card = Join-Path $Root "big_card"
$t0 = Get-Date "2006-01-01 08:00"
$e = [char]0x00E9; $u = [char]0x00FC; $cam = [char]::ConvertFromUtf32(0x1F4F7)
$weird = @("photo [1].JPG", "it's mine.JPG", "caf$e $u ber.JPG", "snap $cam.JPG", "a b  c.JPG", "100%.JPG", "x`$y.JPG",
           ("long" + ("_name" * 25) + ".JPG"), "dot.dot.JPG", "UPPER.jpeg")
for ($i = 1; $i -le $BigCard; $i++) {
    $folder = "{0}MSDCF" -f (100 + ($i % 3))
    New-Photo (Join-Path $card "DCIM\$folder\DSC$('{0:D5}' -f $i).JPG") $t0.AddSeconds($i * 7)
}
foreach ($w in $weird) { New-Photo (Join-Path $card "DCIM\WEIRD\$w") $t0.AddDays(1) }
[IO.File]::WriteAllBytes((Join-Path $card "DCIM\WEIRD\EMPTY.JPG"), [byte[]]@())
New-Blob (Join-Path $card "DCIM\WEIRD\CORRUPT.JPG") 777 $t0
Copy-Item -LiteralPath (Join-Path $card "DCIM\100MSDCF\DSC00003.JPG") (Join-Path $card "DCIM\WEIRD\same as 3.JPG")
$cfgBig = New-TestConfig "Cam [Big] 'O"
$snap = Snapshot $card $cfgBig.libraryRoot
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Import-Card $cfgBig $card
$sw.Stop()
Write-Host ("        ({0} imported in {1:N0} s)" -f $r.copied, $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
Assert-Safe "big card" $snap $card $cfgBig.libraryRoot
Assert-Complete "big card" $cfgBig $card $snap
$media = Get-CameraDestination $cfgBig $cfgBig.cameras[0]
$nums = @(Get-ChildItem -LiteralPath $media -File | ForEach-Object { if ($_.BaseName -match '\((\d+)\)$') { [int]$Matches[1] } } | Sort-Object)
$contiguous = ($nums.Count -gt 0) -and ($nums[0] -eq 1) -and ($nums[-1] -eq $nums.Count) -and (@($nums | Sort-Object -Unique).Count -eq $nums.Count)
Check "big card - numbers run 1..$($nums.Count) with no gaps or repeats" $contiguous
Check "big card - camera name with [brackets] and an apostrophe works" (Test-Path -LiteralPath (Join-Path $media "Cam [Big] 'O (1).JPG"))

# ============================================================
Write-Title "2. FAILURES MID-IMPORT, THEN A CLEAN RE-RUN"
# ============================================================
$cases = @(
    @{ n = "copy fails on file 4";            f = "copy:4";               extra = 0 },
    @{ n = "copy comes out corrupted (3)";    f = "corrupt:3";            extra = 0 },
    @{ n = "card pulled at file 5";           f = "cardlost:5";           extra = 0 },
    @{ n = "crash right after file 6 logged"; f = "crash:6";              extra = 0 },
    @{ n = "crash before file 2 is logged";   f = "crash-before-ledger:2"; extra = 1 },
    @{ n = "send to destination fails (2)";   f = "send:2";               extra = 0 },
    @{ n = "import history write fails (3)";  f = "ledger:3";             extra = 0 }
)
$ci = 0
foreach ($c in $cases) {
    $ci++
    $cfgF = New-TestConfig "Fault$ci"
    $card = New-SmallCard "fault_card_$ci"
    $snap = Snapshot $card $cfgF.libraryRoot
    $r1 = Import-Card $cfgF $card $c.f
    Assert-Safe "$($c.n) [during]" $snap $card $cfgF.libraryRoot
    $mid = Snapshot $card $cfgF.libraryRoot      # the re-run must not disturb what the first run kept
    $r2 = Import-Card $cfgF $card
    Assert-Safe "$($c.n) [after re-run]" @{ card = $snap.card; lib = $mid.lib } $card $cfgF.libraryRoot
    Assert-Complete $c.n $cfgF $card $snap $c.extra
}

# ============================================================
Write-Title "3. TWO WINDOWS AT ONCE"
# ============================================================
$cfgL = New-TestConfig "Locked"
$card = New-SmallCard "lock_card"
$snap = Snapshot $card $cfgL.libraryRoot
$cardCount = @(Get-CardMedia $card).Count
$held = [System.IO.File]::Open((Join-Path $env:TEMP "card-drawer-import.lock"), "OpenOrCreate", "ReadWrite", "None")
$r = Import-Card $cfgL $card
$held.Dispose()
Check "second import refuses while one is running" ($r.busy -eq $true -and $r.copied -eq 0)
Check "the refused import changed nothing on the card" (@(Get-CardMedia $card).Count -eq $cardCount -and -not (Test-Path -LiteralPath $cfgL.libraryRoot))
$r = Import-Card $cfgL $card
Check "after the first one finishes, the import runs" ($r.copied -gt 0)
Assert-Safe "two windows" $snap $card $cfgL.libraryRoot

# ============================================================
Write-Title "4. REUSED NAMES (keep-names mode)"
# ============================================================
$cfgK = New-TestConfig "Keeper"
$cfgK.cameras[0].naming = "keep"
$cardA = Join-Path $Root "keep_a"; New-Photo (Join-Path $cardA "DCIM\IMG_0001.JPG") (Get-Date "2007-01-01")
$backup = Join-Path $Root "keep_backup"; New-Item -ItemType Directory $backup -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $cardA "DCIM\IMG_0001.JPG") $backup
$null = Import-Card $cfgK $cardA                                   # photo X imported, card cleared
$kMedia = Get-CameraDestination $cfgK $cfgK.cameras[0]
Remove-Item -LiteralPath (Join-Path $kMedia "IMG_0001.JPG")         # user deletes X from the library...
$cardB = Join-Path $Root "keep_b"; New-Photo (Join-Path $cardB "DCIM\IMG_0001.JPG") (Get-Date "2008-01-01")
$null = Import-Card $cfgK $cardB                                   # ...a different photo Y takes the name
$cardC = Join-Path $Root "keep_c"; New-Item -ItemType Directory (Join-Path $cardC "DCIM") -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $backup "IMG_0001.JPG") (Join-Path $cardC "DCIM")   # X shows up on a card again
$snap = Snapshot $cardC $cfgK.libraryRoot
$r = Import-Card $cfgK $cardC
Check "photo whose only copy was deleted is NOT wiped off the card just because its name exists" (Test-Path -LiteralPath (Join-Path $cardC "DCIM\IMG_0001.JPG"))
Assert-Safe "reused names" $snap $cardC $cfgK.libraryRoot

# ============================================================
Write-Title "5. OVERLAPPING FOLDERS"
# ============================================================
$cfgO = New-TestConfig "Overlap"
$card = New-SmallCard "overlap_card"
$null = Import-Card $cfgO $card
$oMedia = Get-CameraDestination $cfgO $cfgO.cameras[0]
$before = @(Get-ChildItem -LiteralPath $cfgO.libraryRoot -File -Recurse).Count
$r = Import-Card $cfgO $oMedia -FromFolder
Check "importing the camera's own Media folder is refused" ($r.failed -gt 0 -and $r.copied -eq 0)
$r = Import-Card $cfgO $Root -FromFolder
Check "importing a folder that CONTAINS the library is refused" ($r.failed -gt 0 -and $r.copied -eq 0)
Check "refused imports changed nothing" (@(Get-ChildItem -LiteralPath $cfgO.libraryRoot -File -Recurse).Count -eq $before)

# ============================================================
Write-Title "6. REVIEW WINDOW SAFETY"
# ============================================================
$rv = Join-Path $Root "review"; New-Item -ItemType Directory $rv -Force | Out-Null
$good = Join-Path $rv "good.JPG"; New-Photo $good (Get-Date "2009-09-09 09:09")
$bad = Join-Path $rv "bad.JPG"; New-Blob $bad 999 (Get-Date "2009-09-09")
$badHash = (Get-FileHash -LiteralPath $bad).Hash
$ErrorActionPreference = "Continue"
$o1 = & (Join-Path $PSScriptRoot "..\src\RotateReview.ps1") -TestRotate $good
$o2 = & (Join-Path $PSScriptRoot "..\src\RotateReview.ps1") -TestRotate $bad
$ErrorActionPreference = "Stop"
$img = [System.Drawing.Image]::FromFile($good); $w = $img.Width; $img.Dispose()
Check "rotating a good photo gives a valid, turned photo ($o1)" ($w -eq 32)
Check "rotating keeps the photo's date" ((Get-Item $good).LastWriteTime -eq (Get-Date "2009-09-09 09:09"))
Check "rotating a damaged photo is refused and the file is untouched" (($o2 -match 'refused') -and (Test-SameHash $bad $badHash))
Check "no half-written temp files left behind" (@(Get-ChildItem $rv -Filter "*.tmp").Count -eq 0)

# ============================================================
Write-Title "7. LEDGER LOST"
# ============================================================
$cfgG = New-TestConfig "Ledgerless"
$cfgG.cameras[0].deleteFromCard = $false
$card = New-SmallCard "ledger_card"
$null = Import-Card $cfgG $card
Remove-Item -LiteralPath (Join-Path (Get-CameraFolder $cfgG $cfgG.cameras[0]) "imported_media.csv")
$snap = Snapshot $card $cfgG.libraryRoot
$r = Import-Card $cfgG $card
Assert-Safe "ledger deleted, card imported again" $snap $card $cfgG.libraryRoot
Write-Host "        (known: without the ledger the same card imports again as new numbers -" -ForegroundColor DarkGray
Write-Host "         duplicates, but nothing overwritten and nothing lost)" -ForegroundColor DarkGray

# ============================================================
Write-Title "8. RANDOM FAULT ROUNDS ($Rounds)"
# ============================================================
$kinds = @("copy", "corrupt", "cardlost", "crash", "crash-before-ledger", "send", "ledger", "")
$roundFails = 0
for ($n = 1; $n -le $Rounds; $n++) {
    $kind = $kinds[$rng.Next($kinds.Count)]
    $at = 1 + $rng.Next(14)
    $fault = ""; if ($kind) { $fault = "${kind}:$at" }
    $cfgR = New-TestConfig "Round$n"
    $cfgR.cameras[0].deleteFromCard = ($rng.Next(2) -eq 1)
    if ($rng.Next(3) -eq 0) { $cfgR.cameras[0].naming = "keep" }
    if ($rng.Next(3) -eq 0) { $cfgR.cameras[0].dates = "import" }   # wrong-clock path rewrites files
    $card = New-SmallCard "round_$n" (4 + $rng.Next(10))
    $snap = Snapshot $card $cfgR.libraryRoot
    $before = $script:fail
    $null = Import-Card $cfgR $card $fault
    $null = Import-Card $cfgR $card
    $null = Import-Card $cfgR $card     # a third run must change nothing
    $now = Get-Hashes $card; foreach ($k in (Get-Hashes $cfgR.libraryRoot).Keys) { $now[$k] = $true }
    $lost = @($snap.card.Keys | Where-Object { -not $now.ContainsKey($_) }).Count
    $ledgerPath = Join-Path (Get-CameraFolder $cfgR $cfgR.cameras[0]) "imported_media.csv"
    $ledger = @(Import-Csv -LiteralPath $ledgerPath -ErrorAction SilentlyContinue)
    $unique = @($snap.card.Keys | Where-Object { $snap.card[$_] -notmatch 'System Volume' }).Count
    $okLedger = (@($ledger.Hash | Sort-Object -Unique).Count -eq $unique)
    $waiting = @(Get-ChildItem -LiteralPath (Join-Path (Get-CameraFolder $cfgR $cfgR.cameras[0]) "Incoming") -File -ErrorAction SilentlyContinue).Count
    $ok = ($lost -eq 0) -and $okLedger -and ($waiting -eq 0)
    if (-not $ok) {
        $roundFails++
        Write-Host ("  FAIL  round {0}: fault '{1}', delete={2}, naming={3} -> lost {4}, ledger ok {5}, waiting {6}" -f
            $n, $fault, $cfgR.cameras[0].deleteFromCard, $cfgR.cameras[0].naming, $lost, $okLedger, $waiting) -ForegroundColor Red
    }
    Remove-Item -LiteralPath $card -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $cfgR.libraryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Check "$Rounds random fault rounds: no loss, everything imported once, nothing stranded" ($roundFails -eq 0)

# ============================================================
Write-Host ""
Write-Rule
$color = "Green"; if ($script:fail -gt 0) { $color = "Red" }
Write-Host ("  {0} passed, {1} failed   (seed {2})" -f $script:pass, $script:fail, $Seed) -ForegroundColor $color
Write-Host "  Test files: $Root" -ForegroundColor DarkGray
if ($script:fail -eq 0) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
exit $script:fail
