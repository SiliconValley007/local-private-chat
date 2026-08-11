# Build Local Chat release artifacts on Windows (APK + optional server folder).
# Usage (from repo root):
#   powershell -ExecutionPolicy Bypass -File tools\build_release.ps1
#   powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -SkipServer
#   powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -SkipApk

param(
    [switch]$SkipApk,
    [switch]$SkipServer
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Out = Join-Path $Root "releases"
New-Item -ItemType Directory -Force -Path $Out | Out-Null

if (-not $SkipApk) {
    Write-Host "==> Building arm64 APK (phones)..." -ForegroundColor Cyan
    Push-Location (Join-Path $Root "flutter_app")
    flutter build apk --release --split-per-abi
    Pop-Location
    $apk = Join-Path $Root "flutter_app\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
    if (-not (Test-Path $apk)) { throw "APK not found at $apk" }
    Copy-Item $apk (Join-Path $Out "LocalChat-android-arm64.apk") -Force
    Write-Host "    -> releases\LocalChat-android-arm64.apk"
}

if (-not $SkipServer) {
    Write-Host "==> Building Windows server folder with PyInstaller..." -ForegroundColor Cyan
    $server = Join-Path $Root "server"
    $venvPython = Join-Path $server ".venv\Scripts\python.exe"
    if (-not (Test-Path $venvPython)) {
        throw "Create server\.venv first: python -m venv .venv && .\.venv\Scripts\activate && pip install -r requirements.txt"
    }
    & $venvPython -m pip install -q pyinstaller
    Push-Location $server
    & $venvPython -m PyInstaller --noconfirm localchat.spec
    Pop-Location
    $built = Join-Path $server "dist\LocalChatServer"
    if (-not (Test-Path $built)) { throw "PyInstaller output missing: $built" }
    $zip = Join-Path $Out "LocalChatServer-windows-x64.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    # tar avoids Compress-Archive file locks right after PyInstaller finishes
    tar -a -cf $zip -C $built .
    Write-Host "    -> releases\LocalChatServer-windows-x64.zip"
    Write-Host "    Run LocalChatServer.exe from the unzipped folder. Data stays next to the exe."
}

Write-Host "==> Done. Upload the files under releases\ to a GitHub Release." -ForegroundColor Green
