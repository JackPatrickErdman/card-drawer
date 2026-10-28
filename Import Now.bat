@echo off
rem Camera Ingest - scan everything plugged in and import it (no menu)
title Camera Ingest - Import
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Import.ps1"
