# ============================================================
#  Card Drawer - main window check
#  Opens the real window on a test setup and presses every button
#  and menu command that opens a dialog (App.ps1 -SelfTest), then
#  checks each dialog actually appeared and nothing errored. This
#  is what catches a window that can't reach a dialog at all.
#    powershell -ExecutionPolicy Bypass -File tests\App-Test.ps1
# ============================================================

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\src\Common.ps1")
$Root = Join-Path $env:TEMP ("card-drawer-app-" + (Get-Date -Format "yyyyMMddHHmmss"))
New-Item -ItemType Directory -Path $Root -Force | Out-Null
$script:pass = 0; $script:fail = 0
function Check([string]$what, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host "  PASS  $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL  $what" -ForegroundColor Red }
}

$cfg = New-DefaultConfig; $cfg.libraryRoot = Join-Path $Root "Library"
$a = New-CameraProfile "Test Camera"; $a.match.content = "photos"
$prog = Join-Path $Root "tool.bat"; Set-Content $prog "@echo off" -Encoding ASCII
$s = New-CameraProfile "Test Special"; $s.kind = "special"; $s.program = $prog
$cfg.cameras = @($a, $s)
Save-Config $cfg (Join-Path $Root "config.json")
$log = Join-Path $Root "selftest.log"

$p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`" -ConfigPath `"{1}`" -SelfTest `"{2}`"" -f (Join-Path $PSScriptRoot "..\src\App.ps1"), (Join-Path $Root "config.json"), $log)
if (-not $p.WaitForExit(90000)) { $p.Kill(); Check "window finished its self-test in time" $false }
$lines = @(Get-Content $log -ErrorAction SilentlyContinue)
$lines | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }

Check "self-test ran to the end" ($lines -contains "done")
Check "no errors from any button" (@($lines | Where-Object { $_ -like "error:*" }).Count -eq 0)
foreach ($want in @("Add Camera", "Camera Properties - Test Camera", "Settings", "Add External Camera", "External Camera - Test Special")) {
    Check "opens: $want" ($lines -contains "opened: $want")
}
Check "closing a dialog with its X leaves the main window open" (($lines -contains "closed with X: Add Camera") -and ($lines -contains "closed with X: Settings") -and ($lines -contains "main window open: True"))
$after = Read-Config (Join-Path $Root "config.json")
Check "closing the dialogs changed no settings" ($after.cameras.Count -eq 2 -and $after.cameras[0].name -eq "Test Camera")

Write-Host ("  {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -eq 0) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
exit $script:fail
