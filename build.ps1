# Build the Claude Usage Tray executable from claude-usage-tray.ps1.
#
# One reproducible command instead of copy-pasting the ps2exe block from the
# README. Run from the project folder:
#
#     ./build.ps1
#
# Requires: ps2exe module (Install-Module ps2exe -Scope CurrentUser).

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

Write-Host "Building Claude Usage Tray.exe (ps2exe)..." -ForegroundColor Cyan
Import-Module ps2exe
Invoke-ps2exe `
    -inputFile   ".\claude-usage-tray.ps1" `
    -outputFile  ".\Claude Usage Tray.exe" `
    -iconFile    ".\claude-usage-tray.ico" `
    -noConsole `
    -title       "Claude Usage Tray" `
    -description "Claude and Claude Code usage limits in the Windows tray"

Write-Host "Done -> .\Claude Usage Tray.exe" -ForegroundColor Green
