@echo off
title PEK Server - TMDb key
cd /d "%~dp0"
rem PEK Server gets titles, posters and plots from TMDb with YOUR OWN free key (PEK's key is only for the PEK TV apps).
rem Without one, only your own .nfo files and pictures are used.
echo Get a free TMDb key: sign in at themoviedb.org, then Settings ^> API. Copy the "API Key" or the "API Read Access Token".
echo Type off to remove the saved key.
echo.
set /p PEKTMDB=Paste your TMDb key here: 
pek-server.exe --tmdb-key "%PEKTMDB%"
echo.
echo Then restart PEK Server: "Stop PEK Server.bat", then "Start PEK Server.bat".
pause