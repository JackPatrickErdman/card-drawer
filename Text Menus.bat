@echo off
rem Camera Ingest - the text-menu version (setup, cameras, settings, import)
title Camera Ingest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Menu.ps1"
