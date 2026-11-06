@echo off
rem Card Drawer - scan everything plugged in and import it (no menu)
title Card Drawer - Import
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Import.ps1"
