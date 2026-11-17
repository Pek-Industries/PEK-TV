@echo off
title PEK Server
cd /d "%~dp0"
pek-server.exe %*
echo.
echo PEK Server has stopped.
pause
