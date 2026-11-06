# ============================================================
#  Card Drawer - scripted menu walkthrough
#  Runs the real menus with a list of typed answers, printing
#  every prompt and answer, so the whole first-run experience
#  can be checked without a person at the keyboard.
#    Drive-Menu.ps1 -ConfigPath <temp config> -Answers "a|b||c"
#  (answers separated by |, an empty one = just Enter)
#  Runs out of answers -> stops with a clear message.
# ============================================================
param([string]$ConfigPath, [string]$Answers, [string]$Open = "")

$global:DriveQueue = New-Object System.Collections.Queue
foreach ($a in ($Answers -split '\|')) { $global:DriveQueue.Enqueue($a) }

function global:Read-Host {
    param([Parameter(Position = 0)]$Prompt)
    if ($global:DriveQueue.Count -eq 0) {
        Write-Host ""
        Write-Host "  [walkthrough] out of answers at prompt: $Prompt" -ForegroundColor Magenta
        exit 3
    }
    $a = $global:DriveQueue.Dequeue()
    Write-Host "$($Prompt): " -NoNewline
    Write-Host "<$a>" -ForegroundColor Magenta
    return $a
}

& (Join-Path $PSScriptRoot "..\src\Menu.ps1") -ConfigPath $ConfigPath -Open $Open
