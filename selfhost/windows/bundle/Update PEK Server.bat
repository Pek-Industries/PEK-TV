@echo off
title PEK Server - update
cd /d "%~dp0"
rem PEK Server never updates by itself. This downloads the newest version and replaces the program files in this folder.
rem Your library, accounts and settings (in %LOCALAPPDATA%\PEK Server) are kept.
pek-server.exe --check-update
echo.
choice /m "Download and install the newest PEK Server now"
if errorlevel 2 goto end
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1"
:end
echo.
pause
