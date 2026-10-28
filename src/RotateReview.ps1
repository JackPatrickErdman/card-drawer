# ============================================================
#  Review Photos - rotate or delete a set of photos
#  Opens the photo viewer (Viewer.ps1) straight in review mode:
#    Back / Rotate Left / Rotate Right / Upside Down / Delete /
#    Keep & Next / Done   (keys: B L R U D Enter Esc)
#  Rotations are saved safely at high JPEG quality with dates
#  kept; deletions go to the Recycle Bin. Run with -Folder (every
#  photo in it) or -Files (what an import just copied).
# ============================================================
param(
    [string[]]$Files = @(),
    [string]$Folder = "",
    [string[]]$Companions = @(),  # folders holding the same shot under the same name (RAW, untouched
                                  # originals); deleting a photo sends those twins to the bin too
    [string]$TestRotate = "",     # internal: rotate one file 90 CW without UI, then exit
    [string[]]$TestDelete = @()   # internal: delete these files (and twins) without UI, then exit
)

. (Join-Path $PSScriptRoot "Viewer.ps1")

if ($TestDelete.Count -gt 0) {
    $n = Remove-Photos $TestDelete $Companions
    Write-Output "test-deleted: $n"
    exit 0
}

if ($TestRotate) {
    try {
        $img = Load-Unlocked $TestRotate
        $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone)
        Save-Rotated $img $TestRotate
        $img.Dispose()
        Write-Output "test-rotated: $TestRotate"
    } catch {
        Write-Output "test-rotate-refused: $($_.Exception.Message)"
    }
    exit 0
}

# ---- Build the photo list ----
if ($Files.Count -eq 0 -and $Folder) {
    $Files = @(Get-ChildItem -LiteralPath $Folder -File | Where-Object { $_.Extension -match '^\.(jpe?g|png|gif|bmp|tiff?)$' } | Sort-Object {
        if ($_.BaseName -match '\((\d+)\)') { [int]$Matches[1] } else { 0 }
    }, Name | Select-Object -ExpandProperty FullName)
}
$Files = @($Files | Where-Object { Test-Path -LiteralPath $_ })
if ($Files.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show("No photos found to review.", "Review Photos") | Out-Null
    exit 0
}

$title = "Review Photos"
if ($Folder) { $title = "Review - $(Split-Path $Folder -Leaf)" }
$v = New-PhotoViewer $title
Show-Viewer $v
Set-ViewerStatus $v "Loading $($Files.Count) photo(s)"
foreach ($f in $Files) { Add-ViewerPhoto $v $f (Split-Path $f -Leaf) }
$r = Invoke-ViewerReview $v $Files $Companions "Rotate or delete anything, then click Done. Deleted photos go to the Recycle Bin." "Done"
Close-Viewer $v
$msg = "Review finished - $($r.rotated) photo(s) rotated"
if ($r.deleted -gt 0) { $msg += ", $($r.deleted) sent to the Recycle Bin" }
Write-Host "$msg."
