@echo off
title PEK Server - subtitles key
cd /d "%~dp0"
rem Subtitle search on PEK Server uses YOUR OWN free OpenSubtitles key (PEK's shared account is only for the PEK TV apps).
echo Make a free key: sign in at opensubtitles.com, open https://www.opensubtitles.com/en/consumers and create an API consumer.
echo Type off to remove the saved key and login.
echo.
set /p PEKSUBS=Paste your OpenSubtitles API key here: 
pek-server.exe --subtitles-key "%PEKSUBS%"
if errorlevel 1 goto done
echo.
echo Optional: your OpenSubtitles user name gives more subtitle downloads a day. Leave it empty to skip.
set PEKSUBUSER=
set /p PEKSUBUSER=OpenSubtitles user name: 
if not "%PEKSUBUSER%"=="" pek-server.exe --subtitles-user "%PEKSUBUSER%"
:done
echo.
echo Then restart PEK Server: "Stop PEK Server.bat", then "Start PEK Server.bat".
pause
