@echo off
rem Card Drawer - opens the main window
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\App.ps1"
