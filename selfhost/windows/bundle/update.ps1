# PEK Server for Windows: replaces the program files in this folder with the newest release. Run by "Update PEK Server.bat".
# Your library, accounts and settings live in %LOCALAPPDATA%\PEK Server and are not touched. Nothing updates by itself.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'x64' }
$base = if ($env:PEK_UPDATE_BASE) { $env:PEK_UPDATE_BASE } else { 'https://github.com/Pek-Industries/PEK-TV/releases/download/server-latest' }
$name = "PEK-Server-windows-$arch.zip"
$tmp = Join-Path $env:TEMP ('pek-update-' + [guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    Write-Host "Downloading $name ..."
    Invoke-WebRequest "$base/$name" -OutFile "$tmp\$name" -UseBasicParsing
    Invoke-WebRequest "$base/$name.sha256" -OutFile "$tmp\$name.sha256" -UseBasicParsing
    $want = ((Get-Content "$tmp\$name.sha256" -Raw).Trim() -split '\s+')[0].ToLower()
    $got = (Get-FileHash "$tmp\$name" -Algorithm SHA256).Hash.ToLower()
    if ($want -ne $got) { throw 'The download is damaged (checksum mismatch). Try again.' }
    Expand-Archive "$tmp\$name" -DestinationPath "$tmp\x" -Force
    $src = Get-ChildItem "$tmp\x" -Directory | Select-Object -First 1
    if (-not $src -or -not (Test-Path "$($src.FullName)\pek-server.exe")) { throw 'The download does not contain pek-server.exe.' }

    $running = @(Get-Process pek-server -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) { Write-Host 'Stopping PEK Server ...'; $running | Stop-Process -Force; Start-Sleep -Seconds 2 }
    # Everything except the batch file that is running right now (cmd reads it while it runs).
    Get-ChildItem $src.FullName | Where-Object { $_.Name -ne 'Update PEK Server.bat' } |
        ForEach-Object { Copy-Item $_.FullName -Destination $here -Recurse -Force }
    $ver = & (Join-Path $here 'pek-server.exe') --version
    Write-Host ''
    Write-Host "Done: $ver"
    if ($running.Count -gt 0) {
        Write-Host 'Starting it again ...'
        Start-Process -FilePath (Join-Path $here 'Start PEK Server.bat') -WorkingDirectory $here
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
