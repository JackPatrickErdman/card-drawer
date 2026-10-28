# ============================================================
#  Camera Ingest - the Windows 98 look, shared by every window
#  Palette, fonts, and New-RetroWindow: a borderless form with
#  a raised 3D frame and a hand-drawn navy title bar (drag to
#  move, double-click to maximize, real Marlett caption glyphs).
#  Dot-source BEFORE creating any control.
# ============================================================

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# classic grey 3D controls instead of the modern theme
[System.Windows.Forms.Application]::VisualStyleState = [System.Windows.Forms.VisualStyles.VisualStyleState]::NoneEnabled

if (-not ("CiWin" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CiWin {
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);
}
"@
}

$RetroGray    = [System.Drawing.Color]::FromArgb(192, 192, 192)
$RetroDark    = [System.Drawing.Color]::FromArgb(128, 128, 128)
$RetroNavy    = [System.Drawing.Color]::FromArgb(0, 0, 128)
$RetroNavyEnd = [System.Drawing.Color]::FromArgb(16, 132, 208)
$RetroWhite   = [System.Drawing.Color]::White
$RetroRed     = [System.Drawing.Color]::FromArgb(192, 0, 0)
$RetroFont    = New-Object System.Drawing.Font("Microsoft Sans Serif", 8.25)
$RetroBold    = New-Object System.Drawing.Font("Microsoft Sans Serif", 8.25, [System.Drawing.FontStyle]::Bold)
$RetroMono    = New-Object System.Drawing.Font("Lucida Console", 8.25)

function Switch-RetroMaximize($form) {
    # a borderless window would cover the taskbar when maximized - keep to the work area
    if ($form.WindowState -eq "Maximized") { $form.WindowState = "Normal"; return }
    $form.MaximizedBounds = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $form.WindowState = "Maximized"
}

function New-RetroWindow([string]$text, [int]$width, [int]$height, [switch]$Maximize) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $text
    $form.FormBorderStyle = "None"
    $form.Size = New-Object System.Drawing.Size($width, $height)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = $RetroGray
    $form.Font = $RetroFont
    $form.KeyPreview = $true
    $form.Padding = New-Object System.Windows.Forms.Padding(4)
    $form.Add_Paint({
        [System.Windows.Forms.ControlPaint]::DrawBorder3D($_.Graphics, $this.ClientRectangle, [System.Windows.Forms.Border3DStyle]::Raised)
    })
    $form.Add_Resize({ $this.Invalidate() })

    $title = New-Object System.Windows.Forms.Panel
    $title.Dock = "Top"; $title.Height = 20
    $title.Width = $width - 8      # before the right-anchored caption buttons go on, or they drift off the edge
    $title.Add_Paint({
        $r = $this.ClientRectangle
        if ($r.Width -le 0) { return }
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($r, $RetroNavy, $RetroNavyEnd, [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
        $_.Graphics.FillRectangle($brush, $r); $brush.Dispose()
        $_.Graphics.DrawString($this.FindForm().Text, $RetroBold, [System.Drawing.Brushes]::White, 5, 3)
    })
    $title.Add_MouseDown({
        if ($_.Button -eq "Left" -and $_.Clicks -eq 1) {
            [CiWin]::ReleaseCapture() | Out-Null
            [CiWin]::SendMessage($this.FindForm().Handle, 0xA1, 2, 0) | Out-Null   # WM_NCLBUTTONDOWN, HTCAPTION: drag
        }
    })
    if ($Maximize) { $title.Add_DoubleClick({ Switch-RetroMaximize $this.FindForm() }) }
    $form.Add_TextChanged({ $this.Controls | Where-Object { $_ -is [System.Windows.Forms.Panel] -and $_.Dock -eq "Top" } | ForEach-Object { $_.Invalidate() } })

    # Caption buttons drawn by Windows' own classic routine (ControlPaint.DrawCaptionButton):
    # the real 98 close / maximize / minimize boxes, including the pushed-in look
    $kinds = @(,@("close", [System.Windows.Forms.CaptionButton]::Close))   # comma: keep a list of pairs
    if ($Maximize) { $kinds += ,@("max", [System.Windows.Forms.CaptionButton]::Maximize) }
    $kinds += ,@("min", [System.Windows.Forms.CaptionButton]::Minimize)
    $x = $width - 8 - 20
    $buttons = @{}
    foreach ($k in $kinds) {
        $b = New-Object System.Windows.Forms.Label
        $b.Size = New-Object System.Drawing.Size(16, 14)
        $b.Anchor = "Top, Right"
        $b.Location = New-Object System.Drawing.Point($x, 3)
        $b.Tag = @{ kind = $k[1]; pushed = $false }
        $b.Add_Paint({
            $state = [System.Windows.Forms.ButtonState]::Normal
            if ($this.Tag.pushed) { $state = [System.Windows.Forms.ButtonState]::Pushed }
            $kind = $this.Tag.kind
            if ($kind -eq [System.Windows.Forms.CaptionButton]::Maximize -and $this.FindForm().WindowState -eq "Maximized") {
                $kind = [System.Windows.Forms.CaptionButton]::Restore
            }
            [System.Windows.Forms.ControlPaint]::DrawCaptionButton($_.Graphics, $this.ClientRectangle, $kind, $state)
        })
        $b.Add_MouseDown({ $this.Tag.pushed = $true; $this.Invalidate() })
        $b.Add_MouseUp({ $this.Tag.pushed = $false; $this.Invalidate() })
        $title.Controls.Add($b)
        $buttons[$k[0]] = $b
        $x -= 18
        if ($k[0] -eq "close") { $x -= 2 }   # the gap Windows leaves before the close box
    }
    $buttons["close"].Add_Click({ $this.FindForm().Close() })
    $buttons["min"].Add_Click({ $this.FindForm().WindowState = "Minimized" })
    if ($Maximize) { $buttons["max"].Add_Click({ Switch-RetroMaximize $this.FindForm() }) }

    return @{ form = $form; title = $title; buttons = $buttons }
}

function New-RetroButton([string]$text, [int]$width = 90) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.BackColor = $RetroGray
    $b.FlatStyle = "Standard"
    $b.Size = New-Object System.Drawing.Size($width, 24)
    return $b
}
