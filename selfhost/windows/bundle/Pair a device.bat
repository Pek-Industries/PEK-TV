@echo off
title PEK Server - pair a device
cd /d "%~dp0"
rem Asks the PEK Server running on this PC for a 6-digit code. Type it on the TV / phone in
rem PEK TV: Settings ^> Library ^> Connect to a server. One code pairs one device and works for 10 minutes.
pek-server.exe --pair %*
pause
