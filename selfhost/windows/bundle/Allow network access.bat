@echo off
rem Lets other devices on your home (Private) network reach PEK Server through Windows Firewall. Needs administrator.
net session >nul 2>&1
if errorlevel 1 (
  echo Right-click this file and choose "Run as administrator".
  pause
  exit /b 1
)
netsh advfirewall firewall delete rule name="PEK Server" >nul 2>&1
netsh advfirewall firewall add rule name="PEK Server" dir=in action=allow program="%~dp0pek-server.exe" enable=yes profile=private
echo.
echo Done: devices on your Private network can now connect.
pause
