@echo off
schtasks /Create /TN "PEK Server" /TR "\"%~dp0pek-server.exe\" --hide-console" /SC ONLOGON /RL LIMITED /F
echo.
echo PEK Server will now start (hidden) each time you sign in to Windows.
pause
