# Build Local Chat release artifacts on Windows (APK + optional server folder).
# Usage (from repo root):
#   powershell -ExecutionPolicy Bypass -File tools\build_release.ps1
#   powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -SkipServer
#   powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -SkipApk

param(
    [switch]$SkipApk,
    [switch]$SkipServer,
    [switch]$SkipUpdateZip
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Out = Join-Path $Root "releases"
New-Item -ItemType Directory -Force -Path $Out | Out-Null

if (-not $SkipApk) {
    Write-Host "==> Building split + universal release APKs..." -ForegroundColor Cyan
    Push-Location (Join-Path $Root "flutter_app")
    flutter build apk --release --split-per-abi
    flutter build apk --release
    Pop-Location
    $apkDir = Join-Path $Root "flutter_app\build\app\outputs\flutter-apk"
    $apks = @{
        "app-arm64-v8a-release.apk"   = "LocalChat-android-arm64.apk"
        "app-armeabi-v7a-release.apk" = "LocalChat-android-arm32.apk"
        "app-release.apk"             = "LocalChat-android-universal.apk"
    }
    foreach ($src in $apks.Keys) {
        $path = Join-Path $apkDir $src
        if (-not (Test-Path $path)) { throw "APK not found at $path" }
        Copy-Item $path (Join-Path $Out $apks[$src]) -Force
        Write-Host "    -> releases\$($apks[$src])"
    }
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

if (-not $SkipUpdateZip) {
    # Code-only pack for a running Termux/Linux server: unzip inside server/ and
    # restart. Nothing here touches .venv, data/, media/, or the secrets.
    Write-Host "==> Packing server-update.zip for an existing server..." -ForegroundColor Cyan
    $server = Join-Path $Root "server"
    $stage = Join-Path $env:TEMP ("localchat-update-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        Copy-Item (Join-Path $server "app") $stage -Recurse -Force
        Copy-Item (Join-Path $server "tests") $stage -Recurse -Force
        foreach ($f in @("run.py", "reset_password.py", "requirements.txt",
                         "requirements-termux.txt", "requirements-dev.txt",
                         "start_termux.sh", "start.bat")) {
            Copy-Item (Join-Path $server $f) $stage -Force
        }
        Get-ChildItem $stage -Recurse -Force -Directory |
            Where-Object Name -eq "__pycache__" |
            Remove-Item -Recurse -Force
        $zip = Join-Path $Root "server-update.zip"
        if (Test-Path $zip) { Remove-Item $zip -Force }
        tar -a -cf $zip -C $stage .
        Write-Host "    -> server-update.zip (unzip inside the server folder)"
    }
    finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "==> Done. Upload the files under releases\ to a GitHub Release." -ForegroundColor Green
