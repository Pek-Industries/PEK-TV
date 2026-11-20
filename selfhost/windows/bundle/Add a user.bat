@echo off
title PEK Server - add a user
cd /d "%~dp0"
rem Makes an account people sign in with in PEK TV (Settings ^> Account). Their history, resume points and favorites
rem then sync between their devices through this PC. The first account is the owner.
set /p PEKUSER=Username for the new account: 
pek-server.exe --add-user "%PEKUSER%"
echo.
echo Other account commands: pek-server.exe --list-users, --set-password ^<name^>, --remove-user ^<name^>
pause
