# ============================================================
#  Card Drawer - one-click / command-line import
#  No arguments: scan everything plugged in and import it
#  (what "Import Now.bat" runs).
#
#    -Source <folder> -Camera <name>  import a folder as that camera
#    -Practice                        practice run (source untouched)
#    -Yes                             no questions (for scheduled tasks)
#    -ConfigPath <file>               use another settings file
# ============================================================
param(
    [string]$ConfigPath = "",
    [string]$Source = "",
    [string]$Camera = "",
    [switch]$Practice,
    [switch]$Yes,
    [switch]$Gui     # started by the window app: no console questions, pop-ups instead
)

. (Join-Path $PSScriptRoot "Dispatch.ps1")

if (-not $ConfigPath) { $ConfigPath = Get-DefaultConfigPath }
$Host.UI.RawUI.WindowTitle = "$($script:AppName) - Import"

$cfg = Read-Config $ConfigPath
if (-not $cfg) {
    Write-Host "  Not set up yet - open Card Drawer.bat first." -ForegroundColor Yellow
    if (-not $Yes -and -not $Gui) { Wait-Key "Press any key to close" }
    exit 1
}

$code = 0
if ($Source) {
    $cam = $cfg.cameras | Where-Object { $_.name -eq $Camera } | Select-Object -First 1
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Host "  No such folder: $Source" -ForegroundColor Red; $code = 1
    } else {
        $src = Get-SourceInfo $Source
        if (-not $cam) {
            $hit = Find-CameraForSource $cfg $src
            if ($hit) { $cam = $hit.camera; Write-Host "  Recognized as $($cam.name) ($($hit.reason))." -ForegroundColor Green }
        }
        if (-not $cam) {
            Write-Host "  Say which camera with -Camera `"<name>`". Yours are: $(($cfg.cameras | ForEach-Object { $_.name }) -join ', ')" -ForegroundColor Red
            $code = 1
        } else {
            $box = ""
            if ($Practice) { $box = Join-Path $cfg.libraryRoot ("_Practice Runs\{0} {1}" -f ($cam.name -replace '[\\/:*?"<>|]', '_'), (Get-Date -Format "yyyyMMdd_HHmmss")) }
            $r = Invoke-CameraImport -Config $cfg -Camera $cam -Source $src -FromFolder -Yes:$Yes -Gui:$Gui -Sandbox $box
            if ($r.failed -gt 0 -or $r.cardLost) { $code = 2 }
        }
    }
} else {
    if (Invoke-ScanAndImport $cfg -Yes:$Yes -Gui:$Gui) { $code = 2 }
}

if (-not $Yes -and -not $Gui) { Wait-Key "Press any key to close" }
exit $code
