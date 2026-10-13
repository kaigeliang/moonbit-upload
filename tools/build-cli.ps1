$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $moon = if ($env:MOON) { $env:MOON } else { 'moon' }
    & $moon build --target native --release
    if ($LASTEXITCODE -ne 0) { throw 'MoonBit build failed' }
    New-Item -ItemType Directory -Force bin | Out-Null
    Copy-Item _build/native/release/build/cmd/moonrelay/moonrelay.exe bin/moonrelay.exe
    Copy-Item _build/native/release/build/cmd/upload/upload.exe bin/moon-upload.exe
    Copy-Item _build/native/release/build/cmd/server/server.exe bin/moonrelay-server.exe
    Write-Host 'CLI ready: bin/moonrelay.exe'
} finally { Pop-Location }
