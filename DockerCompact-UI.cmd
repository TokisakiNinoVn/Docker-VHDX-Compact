@echo off
rem Double-click to open the Docker VHDX Compact window (asks for Administrator).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0DockerCompact-UI.ps1"
