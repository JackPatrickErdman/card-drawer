# ============================================================
#  Card Drawer - dispatcher
#  Looks at everything plugged in, works out which of your
#  cameras each card belongs to, and runs the import for each.
#  SPACE afterwards = swap cards and scan again.
# ============================================================

. (Join-Path $PSScriptRoot "Engine.ps1")

function Show-SourceLine($src) {
    $label = $src.label; if (-not $label) { $label = "no label" }
    $what = "{0} photo(s), {1} video(s), {2} MB" -f $src.photos.Count, $src.videos.Count, $src.sizeMB
    $line = "  {0}  ({1}, serial {2})  {3}" -f $src.root, $label, $src.serial, $what
    if ($src.exifModel) { $line += "  model: $($src.exifModel)" }
    Write-Host $line
}

function Read-AgainKey([string]$text) {
    # SPACE = scan again, anything else = finish
    Write-Host ""
    Write-Host "  $text" -ForegroundColor Cyan
    return ((Read-Key) -eq ' ')
}

function Invoke-ScanAndImport($Config, [switch]$Yes, [switch]$Gui) {
    # -Gui: one pass, no key presses (the window app shows the result and has its own buttons).
    # Returns $true if anything went wrong (a failed copy or conversion, a pulled card, another
    # import already running), so the window app can say "Finished with problems".
    if ($Config.cameras.Count -eq 0) {
        Write-Host "  You haven't added any cameras yet - choose 'Add a camera' first." -ForegroundColor Yellow
        return $true
    }
    $problems = $false
    do {
        Write-Title "SCANNING FOR CAMERA MEDIA"
        Write-Host "  Scanning card readers and USB drives" -ForegroundColor Gray
        Write-Host ""
        $sources = @(Get-PluggedInSources)
        $queue = @()
        foreach ($src in $sources) {
            if ($src.media.Count -eq 0) {
                Write-Host ("  [ nothing ]    {0} ({1}) - no photos or videos on it, skipping." -f $src.root, $src.label) -ForegroundColor DarkGray
                continue
            }
            $hit = Find-CameraForSource $Config $src
            if ($hit) {
                Write-Host ("  [ {0} ]  {1} - {2} item(s), recognized by {3}" -f $hit.camera.name, $src.root, $src.media.Count, $hit.reason) -ForegroundColor Green
                $queue += @{ camera = $hit.camera; source = $src }
            } else {
                Write-Host ("  [ unknown ]    {0} - {1} item(s), doesn't match any of your cameras." -f $src.root, $src.media.Count) -ForegroundColor Yellow
                Write-Host  "                 Use 'Add a camera' to teach it this card." -ForegroundColor Yellow
            }
        }

        if ($queue.Count -eq 0) {
            if ($sources.Count -eq 0) {
                Write-Host "  No memory card or USB drive found." -ForegroundColor Yellow
                Write-Host "  (Cameras plugged in directly by USB often show up as a 'portable device'" -ForegroundColor Gray
                Write-Host "   with no drive letter - put the card in a card reader instead.)" -ForegroundColor Gray
            }
            if ($Yes -or $Gui) { return $problems }
            $again = Read-AgainKey "SPACE = scan again      any other key = back"
            continue
        }

        foreach ($job in $queue) {
            $r = Invoke-CameraImport -Config $Config -Camera $job.camera -Source $job.source -Yes:$Yes -Gui:$Gui
            if ($r.failed -gt 0 -or $r.cardLost -or $r.busy) { $problems = $true }
        }
        Write-Host ""
        Write-Host "  ===== ALL MEDIA HANDLED =====" -ForegroundColor Cyan
        if ($Yes -or $Gui) { return $problems }
        $again = Read-AgainKey "SPACE = swap in another card and scan again      any other key = finish"
        if ($again) {
            Write-Host "  Insert the next card. Scanning again shortly." -ForegroundColor Gray
            Start-Sleep -Seconds 4
        }
    } while ($again)
    return $problems
}
