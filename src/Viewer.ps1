# ============================================================
#  Card Drawer - the photo viewer (one window, two modes)
#    IMPORT  opens when an import starts: the photo just copied
#            shown big, a filmstrip of thumbnails growing along
#            the bottom, old name -> new name, a progress bar.
#    REVIEW  when the copying is done the same window turns into
#            the review: Back / Rotate / Upside down / Delete /
#            Keep & next / Done, or the keys R L U D B Enter Esc.
#            Click any thumbnail to jump to it.
#  Rotations are saved safely (Save-Rotated), deletions go to the
#  Recycle Bin together with the photo's RAW / untouched twin.
#  The caller's code keeps running between photos, so the window
#  is kept alive with Update-Viewer (DoEvents) - no threads.
# ============================================================

. (Join-Path $PSScriptRoot "Retro.ps1")

$ThumbW = 96; $ThumbH = 72

function Load-Unlocked([string]$path, [switch]$Fast) {
    # load via memory stream so the file on disk is never locked
    # -Fast skips the full-picture decode GDI+ does to validate; thumbnails then come from the
    # small preview cameras embed. The big picture keeps the check, so a damaged file fails here.
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $ms = New-Object System.IO.MemoryStream(,$bytes)
    if ($Fast) { return [System.Drawing.Image]::FromStream($ms, $false, $false) }
    return [System.Drawing.Image]::FromStream($ms)
}

function Save-Rotated([System.Drawing.Image]$img, [string]$path) {
    # orientation tag (if any) must say "normal" now that pixels are rotated
    if ($img.PropertyIdList -contains 0x0112) {
        $pi = $img.GetPropertyItem(0x0112)
        $pi.Value = [BitConverter]::GetBytes([UInt16]1)
        $img.SetPropertyItem($pi)
    }
    # the preview the camera embedded still shows the old way round - drop it
    if ($img.PropertyIdList -contains 0x501B) { try { $img.RemovePropertyItem(0x501B) } catch { } }
    $enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
    $ep  = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]95)
    $orig = Get-Item -LiteralPath $path
    $ct = $orig.CreationTime; $wt = $orig.LastWriteTime
    # Never write over the photo directly: save beside it, prove the new file opens,
    # then swap. A crash or full disk mid-save leaves the original untouched.
    $tmp = "$path.rotating.tmp"
    try {
        $img.Save($tmp, $enc, $ep)
        $check = Load-Unlocked $tmp
        $check.Dispose()
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "couldn't save the rotated photo - the original is unchanged ($($_.Exception.Message))"
    }
    $f = Get-Item -LiteralPath $path
    $f.CreationTime  = $ct
    $f.LastWriteTime = $wt
}

function Test-HasRecycleBin([string]$path) {
    # Windows only keeps a Recycle Bin on fixed local drives; anywhere else "delete" is final
    try {
        $full = [System.IO.Path]::GetFullPath($path)
        if ($full.StartsWith("\\")) { return $false }               # network share
        return ((New-Object System.IO.DriveInfo($full.Substring(0, 1))).DriveType -eq "Fixed")
    } catch { return $false }
}

function Remove-Photos([string[]]$paths, [string[]]$companions) {
    # Recycle Bin, never a permanent delete - a wrong click can be undone from there.
    # $companions: folders holding the same shot under the same name (RAW, untouched
    # originals); those twins go to the bin too.
    Add-Type -AssemblyName Microsoft.VisualBasic
    $n = 0
    # list each companion folder once: base name -> files (keys ignore case, as -eq did)
    $byBase = @{}
    foreach ($dir in $companions) {
        if (-not $dir) { continue }
        foreach ($cf in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
            if (-not $byBase.ContainsKey($cf.BaseName)) { $byBase[$cf.BaseName] = New-Object System.Collections.ArrayList }
            [void]$byBase[$cf.BaseName].Add($cf.FullName)
        }
    }
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($p)
        $twins = @(); if ($byBase.ContainsKey($base)) { $twins = @($byBase[$base]) }
        foreach ($f in @($p) + $twins) {
            try {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f, "OnlyErrorDialogs", "SendToRecycleBin")
                if ($f -eq $p) { $n++ }
            } catch {
                Write-Host "  Couldn't delete $(Split-Path $f -Leaf): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
    return $n
}

# ------------------------------------------------------------
#  Thumbnails
# ------------------------------------------------------------

function New-TextTile([string]$text) {
    # stand-in thumbnail for videos, RAW-only shots and files that won't open
    $bmp = New-Object System.Drawing.Bitmap($ThumbW, $ThumbH)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(64, 64, 64))
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = "Center"; $fmt.LineAlignment = "Center"
    $g.DrawString($text, $RetroBold, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 0, $ThumbW, $ThumbH)), $fmt)
    $g.Dispose()
    return $bmp
}

function New-Thumbnail([string]$path) {
    try {
        $img = Load-Unlocked $path -Fast
    } catch { return (New-TextTile "?") }
    try { return (New-ThumbnailFromImage $img) } finally { $img.Dispose() }
}

function New-ThumbnailFromImage([System.Drawing.Image]$img) {
    try {
        $scale = [math]::Min($ThumbW / $img.Width, $ThumbH / $img.Height)
        $w = [math]::Max(1, [int]($img.Width * $scale)); $h = [math]::Max(1, [int]($img.Height * $scale))
        # GetThumbnailImage uses the small preview cameras embed in the JPEG when there is one - fast
        $small = $img.GetThumbnailImage($w, $h, $null, [IntPtr]::Zero)
        $bmp = New-Object System.Drawing.Bitmap($ThumbW, $ThumbH)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Black)
        $g.DrawImage($small, [int](($ThumbW - $w) / 2), [int](($ThumbH - $h) / 2), $w, $h)
        $g.Dispose(); $small.Dispose()
        return $bmp
    } catch {
        return (New-TextTile "?")
    }
}

# ------------------------------------------------------------
#  Filmstrip: one panel that draws only the thumbnails in view.
#  (One control per photo breaks past ~309 photos: Windows can't
#  place a control beyond 32767 px, so later tiles pile up.)
# ------------------------------------------------------------

$TilePitch = $ThumbW + 10     # 102 px tile + 2 px margin each side

function Update-StripScroll($v) {
    $view = [math]::Max(1, $v.strip.ClientSize.Width)
    $total = $v.items.Count * $TilePitch
    if ($total -le $view) { $v.scroll.Value = 0; $v.scroll.Enabled = $false; return }
    $v.scroll.Enabled = $true
    $v.scroll.Maximum = $total - 1
    $v.scroll.LargeChange = $view
    $v.scroll.SmallChange = $TilePitch
    $top = $total - $view
    if ($v.scroll.Value -gt $top) { $v.scroll.Value = $top }
}

function Show-StripItem($v, [int]$i) {
    # scroll just enough to bring tile $i into view
    Update-StripScroll $v
    if ($v.scroll.Enabled) {
        $x = $i * $TilePitch; $view = $v.strip.ClientSize.Width; $top = $v.items.Count * $TilePitch - $view
        $val = $v.scroll.Value
        if ($x -lt $val) { $val = $x } elseif ($x + $TilePitch -gt $val + $view) { $val = $x + $TilePitch - $view }
        $v.scroll.Value = [int][math]::Max(0, [math]::Min($val, $top))
    }
    $v.strip.Invalidate()
}

function Get-StripIndex($v, [int]$x) {
    # which tile is under x (strip coordinates), or -1
    $i = [int][math]::Floor(($x + $v.scroll.Value) / $TilePitch)
    if ($i -lt 0 -or $i -ge $v.items.Count) { return -1 }
    return $i
}

function Draw-Strip($v, [System.Drawing.Graphics]$g) {
    if ($v.items.Count -eq 0) { return }
    $off = $v.scroll.Value
    $first = [int][math]::Max(0, [math]::Floor($off / $TilePitch))
    $last = [int][math]::Min($v.items.Count - 1, [math]::Floor(($off + $v.strip.ClientSize.Width) / $TilePitch))
    for ($i = $first; $i -le $last; $i++) {
        $it = $v.items[$i]
        $x = $i * $TilePitch - $off + 2
        $back = $RetroDark
        if ($it.marked) { $back = $RetroRed } elseif ($i -eq $v.current) { $back = $RetroNavy }
        $br = New-Object System.Drawing.SolidBrush($back)
        $g.FillRectangle($br, $x, 2, ($ThumbW + 6), ($ThumbH + 6)); $br.Dispose()
        if ($it.thumb) { $g.DrawImage($it.thumb, ($x + 3), 5, $ThumbW, $ThumbH) }
    }
}

# ------------------------------------------------------------
#  The window
# ------------------------------------------------------------

function New-PhotoViewer([string]$title) {
    $win = New-RetroWindow $title 900 680 -Maximize
    $form = $win.form
    $form.MinimumSize = New-Object System.Drawing.Size(640, 480)

    $status = New-Object System.Windows.Forms.Label
    $status.Dock = "Top"; $status.Height = 26
    $status.Font = $RetroBold; $status.TextAlign = "MiddleLeft"
    $status.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)

    # the big picture, in a sunken black frame
    $picFrame = New-Object System.Windows.Forms.Panel
    $picFrame.Dock = "Fill"; $picFrame.BorderStyle = "Fixed3D"; $picFrame.BackColor = [System.Drawing.Color]::Black
    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.Dock = "Fill"; $pic.SizeMode = "Zoom"; $pic.BackColor = [System.Drawing.Color]::Black
    $picFrame.Controls.Add($pic)

    $caption = New-Object System.Windows.Forms.Label
    $caption.Dock = "Bottom"; $caption.Height = 22; $caption.TextAlign = "MiddleCenter"

    # filmstrip: one row of thumbnails, scrolling sideways
    $stripFrame = New-Object System.Windows.Forms.Panel
    $stripFrame.Dock = "Bottom"; $stripFrame.Height = ($ThumbH + 30); $stripFrame.BorderStyle = "Fixed3D"; $stripFrame.BackColor = $RetroDark
    $strip = New-Object System.Windows.Forms.PictureBox     # double-buffered, so scrolling doesn't flicker
    $strip.Dock = "Fill"; $strip.BackColor = $RetroDark; $strip.Cursor = "Hand"
    $scroll = New-Object System.Windows.Forms.HScrollBar
    $scroll.Dock = "Bottom"; $scroll.Enabled = $false
    $stripFrame.Controls.Add($strip)
    $stripFrame.Controls.Add($scroll)

    # bottom bar: progress while importing, buttons while reviewing
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = "Bottom"; $bar.Height = 36
    $bar.Width = 880     # its real width BEFORE anchoring children to the right edge, or they drift off
    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Style = "Blocks"; $progress.Location = New-Object System.Drawing.Point(4, 9); $progress.Size = New-Object System.Drawing.Size(872, 18)
    $progress.Anchor = "Left, Right, Top"
    $bar.Controls.Add($progress)

    $buttons = [ordered]@{}
    $x = 4
    foreach ($spec in @(@("back", "< &Back", 70), @("left", "Rotate &Left", 86), @("right", "Rotate &Right", 90), @("flip", "Rotate &180", 90),
                        @("delete", "&Delete", 80), @("next", "&Next >", 80))) {
        $b = New-RetroButton $spec[1] $spec[2]
        $b.Location = New-Object System.Drawing.Point($x, 6); $b.TabStop = $false; $b.Visible = $false
        $b.Tag = $spec[0]
        $bar.Controls.Add($b); $buttons[$spec[0]] = $b
        $x += $spec[2] + 4
    }
    $done = New-RetroButton "Done" 150
    $done.Font = $RetroBold
    $done.Anchor = "Top, Right"; $done.Location = New-Object System.Drawing.Point((880 - 150 - 4), 6)
    $done.TabStop = $false; $done.Visible = $false; $done.Tag = "done"
    $bar.Controls.Add($done); $buttons["done"] = $done

    $hint = New-Object System.Windows.Forms.Label
    $hint.Dock = "Bottom"; $hint.Height = 18; $hint.ForeColor = $RetroDark; $hint.TextAlign = "MiddleCenter"
    $hint.Text = "Import in progress. This window can be minimized."

    # docking order: last added docks first
    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = "Fill"; $body.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 4)
    $body.Controls.Add($picFrame)
    $body.Controls.Add($caption)
    $body.Controls.Add($stripFrame)
    $body.Controls.Add($hint)
    $body.Controls.Add($bar)
    $body.Controls.Add($status)
    $picFrame.BringToFront()
    $form.Controls.Add($body)
    $form.Controls.Add($win.title)
    $body.BringToFront()

    $v = @{
        form = $form; pic = $pic; status = $status; caption = $caption; strip = $strip; scroll = $scroll; progress = $progress
        hint = $hint; buttons = $buttons; items = New-Object System.Collections.ArrayList
        mode = "import"; current = -1; img = $null; rot = 0; finished = $false
        review = @(); pos = 0; rotated = 0; lastBig = [datetime]::MinValue; pending = -1; closing = $false
    }
    $form.Tag = $v

    foreach ($b in $buttons.Values) {
        $b.Add_Click({
            $vv = $this.FindForm().Tag
            Invoke-ViewerAction $vv $this.Tag
            $this.FindForm().ActiveControl = $null   # keys go back to the window, not the button
        })
    }
    $form.Add_KeyDown({
        $vv = $this.Tag
        $e = $_                    # inside the switch below, $_ is the key code instead
        if ($vv.mode -ne "review") { return }
        $act = switch ($e.KeyCode) {
            { $_ -in "Return", "Enter", "Space", "Right" } { "next" }
            { $_ -in "B", "Left" } { "back" }
            "R" { "right" } "L" { "left" } "U" { "flip" }
            { $_ -in "D", "Delete" } { "delete" }
            "Escape" { "done" }
        }
        if ($act) { $e.Handled = $true; $e.SuppressKeyPress = $true; Invoke-ViewerAction $vv $act }
    })
    $form.Add_FormClosing({
        $vv = $this.Tag
        if ($vv.closing) { return }
        $_.Cancel = $true
        if ($vv.mode -eq "review") { Invoke-ViewerAction $vv "done" }     # X = finish the review
        else { $this.WindowState = "Minimized" }                          # X while copying = get out of the way
    })
    $strip.Add_Paint({ $vv = $this.FindForm().Tag; if ($vv) { Draw-Strip $vv $_.Graphics } })
    $strip.Add_MouseDown({
        $vv = $this.FindForm().Tag
        $i = Get-StripIndex $vv $_.X
        if ($i -ge 0) { Select-ViewerItem $vv $i }
    })
    $strip.Add_Resize({ $vv = $this.FindForm().Tag; if ($vv) { Update-StripScroll $vv; $vv.strip.Invalidate() } })
    $scroll.Add_ValueChanged({ $vv = $this.FindForm().Tag; if ($vv) { $vv.strip.Invalidate() } })
    return $v
}

function Update-Viewer($v) {
    if ($v -and -not $v.form.IsDisposed) { [System.Windows.Forms.Application]::DoEvents() }
}

function Show-Viewer($v) {
    $v.form.Show()
    $v.form.TopMost = $true; $v.form.Activate(); $v.form.TopMost = $false   # come to the front once
    Update-Viewer $v
}

function Set-ViewerStatus($v, [string]$text, [int]$done = -1, [int]$total = 0) {
    $v.status.Text = $text
    if ($v.mode -eq "import") { Show-LatestPhoto $v }
    if ($total -gt 0 -and $done -ge 0) {
        $v.progress.Maximum = $total
        $v.progress.Value = [math]::Min($done, $total)
    }
    Update-Viewer $v
}

function New-VideoTile([string]$frame) {
    # a still from the video with a VIDEO banner along the bottom
    $bmp = New-Thumbnail $frame
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $band = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(170, 0, 0, 0))
    $g.FillRectangle($band, 0, $ThumbH - 16, $ThumbW, 16)
    $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = "Center"; $fmt.LineAlignment = "Center"
    $g.DrawString("VIDEO", $RetroBold, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, ($ThumbH - 16), $ThumbW, 16)), $fmt)
    $band.Dispose(); $g.Dispose()
    return $bmp
}

function Add-ViewerPhoto($v, [string]$path, [string]$caption, [string]$placeholder = "", [string]$frame = "") {
    # $placeholder ("VIDEO", "RAW"...): a labelled tile instead of a picture, never reviewed;
    # $frame: a still to show on a VIDEO tile
    $item = @{ path = $path; caption = $caption; isPhoto = (-not $placeholder); marked = $false; thumb = $null }
    if ($placeholder -and $frame -and (Test-Path -LiteralPath $frame)) { $item.thumb = New-VideoTile $frame }
    elseif ($placeholder) { $item.thumb = New-TextTile $placeholder }
    else { $item.thumb = New-Thumbnail $path }
    $idx = $v.items.Add($item)
    Show-StripItem $v $idx
    # big picture follows along, but at most a few times a second (big photos are slow to decode)
    if ($v.mode -eq "import" -and $item.isPhoto -and ([datetime]::Now - $v.lastBig).TotalMilliseconds -gt 400) {
        Show-ViewerItem $v $idx
        $v.lastBig = [datetime]::Now
        $v.pending = -1
    } elseif ($v.mode -eq "import") {
        if ($item.isPhoto) { $v.pending = $idx }    # shown when there's a moment (Show-LatestPhoto)
        $v.caption.Text = $caption
    }
    Update-Viewer $v
}

function Show-LatestPhoto($v, [switch]$Now) {
    # catch the big picture up with the newest photo that arrived too fast to show
    if ($v.pending -ge 0 -and ($Now -or ([datetime]::Now - $v.lastBig).TotalMilliseconds -gt 400)) {
        Show-ViewerItem $v $v.pending
        $v.lastBig = [datetime]::Now
        $v.pending = -1
    }
}

function Set-ViewerHint($v, [string]$text) { $v.hint.Text = $text; Update-Viewer $v }

function Set-TileLook($v, [int]$i) {
    # tile colours (red = marked, navy = current) are drawn by Draw-Strip
    $v.strip.Invalidate()
}

function Show-ViewerItem($v, [int]$i) {
    $prev = $v.current
    $v.current = $i
    if ($prev -ge 0 -and $prev -lt $v.items.Count) { Set-TileLook $v $prev }
    Set-TileLook $v $i
    $it = $v.items[$i]
    if ($v.img) { $v.pic.Image = $null; $v.img.Dispose(); $v.img = $null }
    $v.rot = 0
    $v.caption.Text = $it.caption
    if ($it.isPhoto) {
        try { $v.img = Load-Unlocked $it.path; $v.pic.Image = $v.img }
        catch { $v.caption.Text = "$($it.caption)   (preview not available)" }
    }
    Show-StripItem $v $i
    if ($v.mode -eq "review") { Update-ReviewStatus $v }
}

function Update-ReviewStatus($v) {
    $it = $v.items[$v.current]
    $name = Split-Path $it.path -Leaf
    $text = "[{0} of {1}]  {2}" -f ($v.pos + 1), $v.review.Count, $name
    if ($it.marked) {
        $text += "    Marked for deletion"
        $v.status.ForeColor = $RetroRed
        $v.buttons["delete"].Text = "Un&delete"
    } elseif ($v.rot -ne 0) {
        $text += "    Rotated $($v.rot) degrees"
        $v.status.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 0)
        $v.buttons["delete"].Text = "&Delete"
    } else {
        $v.status.ForeColor = [System.Drawing.Color]::Black
        $v.buttons["delete"].Text = "&Delete"
    }
    if (-not $v.img -and $it.isPhoto) { $text += "    (preview not available)" }
    $v.status.Text = $text
}

function Save-CurrentRotation($v) {
    # a turned photo is written when you leave it (Next, Back, a thumbnail, Done)
    if ($v.current -lt 0 -or $v.rot -eq 0 -or -not $v.img) { return }
    $it = $v.items[$v.current]
    if ($it.marked) { return }
    try {
        Save-Rotated $v.img $it.path
        $v.rotated++
        # the picture in memory is already turned - no need to read the file back
        $old = $it.thumb
        $it.thumb = New-ThumbnailFromImage $v.img
        if ($old) { $old.Dispose() }
        $v.strip.Invalidate()
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($v.form, "$($_.Exception.Message)", "Card Drawer", "OK", "Warning")
    }
    $v.rot = 0
}

function Select-ViewerItem($v, [int]$i) {
    if ($v.mode -ne "review") { Show-ViewerItem $v $i; return }
    $p = [array]::IndexOf($v.review, $i)
    if ($p -lt 0) { return }      # videos / RAW-only tiles aren't part of the review
    Save-CurrentRotation $v
    $v.pos = $p
    Show-ViewerItem $v $i
}

function Invoke-ViewerAction($v, [string]$act) {
    if ($v.mode -ne "review" -or $v.review.Count -eq 0) { return }
    $it = $v.items[$v.current]
    switch ($act) {
        "next" {
            Save-CurrentRotation $v
            if ($v.pos -lt $v.review.Count - 1) { $v.pos++; Show-ViewerItem $v $v.review[$v.pos] }
            else { $v.status.Text = "End of list. Click '$($v.buttons['done'].Text)' to continue."; $v.status.ForeColor = $RetroNavy }
        }
        "back" {
            Save-CurrentRotation $v
            if ($v.pos -gt 0) { $v.pos--; Show-ViewerItem $v $v.review[$v.pos] }
        }
        { $_ -in "left", "right", "flip" } {
            if (-not $v.img -or $it.marked) { return }
            if ($it.path -notmatch '\.jpe?g$') { $v.status.Text = "Only JPEG images can be rotated."; return }
            $turn = @{ left = @("Rotate270FlipNone", 270); right = @("Rotate90FlipNone", 90); flip = @("Rotate180FlipNone", 180) }[$act]
            $v.img.RotateFlip([System.Drawing.RotateFlipType]$turn[0])
            $v.rot = (($v.rot + $turn[1]) % 360 + 360) % 360
            $v.pic.Image = $v.img; $v.pic.Refresh()
            Update-ReviewStatus $v
        }
        "delete" {
            $it.marked = -not $it.marked
            if ($it.marked) {
                # no point keeping a turn; let go of the picture box's reference before disposing
                if ($v.rot -ne 0) { $v.pic.Image = $null; $v.img.Dispose(); $v.img = $null; $v.rot = 0 }
                Set-TileLook $v $v.current
                if ($v.pos -lt $v.review.Count - 1) { $v.pos++; Show-ViewerItem $v $v.review[$v.pos] }
                else { Show-ViewerItem $v $v.current }
            } else {
                Set-TileLook $v $v.current
                Update-ReviewStatus $v
            }
        }
        "done" {
            Save-CurrentRotation $v
            $v.finished = $true
        }
    }
}

function Invoke-ViewerReview($v, [string[]]$files, [string[]]$companions, [string]$intro, [string]$doneText = "Done") {
    # Turn the window into the review and wait until Done. Returns what was changed.
    $shown = @{}; foreach ($it in $v.items) { $shown[$it.path] = $true }
    foreach ($f in $files) {
        if (-not $shown.ContainsKey($f)) { Add-ViewerPhoto $v $f (Split-Path $f -Leaf); $shown[$f] = $true }
    }
    $want = @{}; foreach ($f in $files) { $want[$f] = $true }
    $v.review = @(for ($i = 0; $i -lt $v.items.Count; $i++) { if ($v.items[$i].isPhoto -and $want.ContainsKey($v.items[$i].path)) { $i } })
    if ($v.review.Count -eq 0) { return @{ rotated = 0; deleted = 0 } }

    $v.mode = "review"
    $v.form.Text = $v.form.Text -replace '^Importing', 'Review'
    $v.progress.Visible = $false
    foreach ($b in $v.buttons.Values) { $b.Visible = $true }
    $v.buttons["done"].Text = $doneText
    $v.hint.Text = $intro
    $v.hint.ForeColor = [System.Drawing.Color]::Black
    if ($v.form.WindowState -eq "Minimized") { $v.form.WindowState = "Normal" }
    if (-not $v.form.Visible) { $v.form.Show() }
    $v.form.TopMost = $true; $v.form.Activate(); $v.form.TopMost = $false
    $v.form.ActiveControl = $null
    $v.pos = 0
    Show-ViewerItem $v $v.review[0]

    while (-not $v.finished -and -not $v.form.IsDisposed) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 15
    }
    if ($v.img) { $v.pic.Image = $null; $v.img.Dispose(); $v.img = $null }
    $marked = @($v.items | Where-Object { $_.marked } | ForEach-Object { $_.path })
    # Drives without a Recycle Bin (memory cards, USB sticks, network shares) would delete for
    # good, without asking - so ask here, and keep the photos if the answer is no
    $noBin = @($marked | Where-Object { -not (Test-HasRecycleBin $_) })
    if ($noBin.Count -gt 0 -and -not $v.form.IsDisposed) {
        $ans = [System.Windows.Forms.MessageBox]::Show($v.form, ("{0} of the selected files are on a drive without a Recycle Bin (memory card, USB drive or network folder).`n`nDelete these files permanently?" -f $noBin.Count), "Card Drawer", "YesNo", "Warning", "Button2")
        if ($ans -ne "Yes") { $marked = @($marked | Where-Object { $noBin -notcontains $_ }) }
    }
    $deleted = 0
    if ($marked.Count -gt 0) { $deleted = Remove-Photos $marked $companions }
    return @{ rotated = $v.rotated; deleted = $deleted }
}

function Save-ViewerSnapshot($v, [string]$png) {
    # picture of the window (tests / README)
    Update-Viewer $v
    $bmp = New-Object System.Drawing.Bitmap($v.form.Width, $v.form.Height)
    $v.form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $v.form.Width, $v.form.Height)))
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

function Close-Viewer($v) {
    if (-not $v -or $v.form.IsDisposed) { return }
    $v.closing = $true
    if ($v.img) { $v.pic.Image = $null; $v.img.Dispose(); $v.img = $null }
    foreach ($it in $v.items) { if ($it.thumb) { $it.thumb.Dispose() } }
    $v.form.Close(); $v.form.Dispose()
    [System.Windows.Forms.Application]::DoEvents()
}
