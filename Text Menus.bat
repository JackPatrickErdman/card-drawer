@echo off
rem Card Drawer - the text-menu version (setup, cameras, settings, import)
title Card Drawer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Menu.ps1"
