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

# Anything already in the output folder predates this run.
$StartedAt = Get-Date

# ErrorActionPreference does not apply to native exit codes, so a failed
# `flutter build` or PyInstaller run would otherwise sail past and the copy step
# would publish the previous build's file.
function Assert-LastExitCode {
    param([string]$What)
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed with exit code $LASTEXITCODE"
    }
}

function Assert-Fresh {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Expected build output missing: $Path" }
    if ((Get-Item $Path).LastWriteTime -lt $StartedAt) {
        throw "$Path is left over from an earlier build. Refusing to publish it."
    }
}

if (-not $SkipApk) {
    Write-Host "==> Building split + universal release APKs..." -ForegroundColor Cyan
    Push-Location (Join-Path $Root "flutter_app")
    flutter build apk --release --split-per-abi
    Assert-LastExitCode "flutter build apk --split-per-abi"
    flutter build apk --release
    Assert-LastExitCode "flutter build apk"
    Pop-Location
    $apkDir = Join-Path $Root "flutter_app\build\app\outputs\flutter-apk"
    $apks = @{
        "app-arm64-v8a-release.apk"   = "LocalChat-android-arm64.apk"
        "app-armeabi-v7a-release.apk" = "LocalChat-android-arm32.apk"
        "app-release.apk"             = "LocalChat-android-universal.apk"
    }
    foreach ($src in $apks.Keys) {
        $path = Join-Path $apkDir $src
        Assert-Fresh $path
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
    Assert-LastExitCode "PyInstaller"
    Pop-Location
    $built = Join-Path $server "dist\LocalChatServer"
    Assert-Fresh (Join-Path $built "LocalChatServer.exe")
    $zip = Join-Path $Out "LocalChatServer-windows-x64.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    # tar avoids Compress-Archive file locks right after PyInstaller finishes
    tar -a -cf $zip -C $built .
    Assert-LastExitCode "tar (windows server zip)"
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
        foreach ($f in @("run.py", "reset_password.py", "set_admin.py", "requirements.txt",
                         "requirements-termux.txt", "requirements-dev.txt",
                         "start_termux.sh", "start.bat")) {
            Copy-Item (Join-Path $server $f) $stage -Force
        }
        Get-ChildItem $stage -Recurse -Force -Directory |
            Where-Object Name -eq "__pycache__" |
            Remove-Item -Recurse -Force
        # A CR in the shebang makes Termux bash fail with "bad interpreter".
        $lf = New-Object System.Text.UTF8Encoding($false)
        Get-ChildItem $stage -Recurse -File -Filter *.sh | ForEach-Object {
            $text = [IO.File]::ReadAllText($_.FullName) -replace "`r`n", "`n" -replace "`r", "`n"
            [IO.File]::WriteAllText($_.FullName, $text, $lf)
        }
        $zip = Join-Path $Root "server-update.zip"
        if (Test-Path $zip) { Remove-Item $zip -Force }
        tar -a -cf $zip -C $stage .
        Assert-LastExitCode "tar (server-update.zip)"
        Write-Host "    -> server-update.zip (unzip inside the server folder)"
    }
    finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "==> Done. Upload the files under releases\ to a GitHub Release." -ForegroundColor Green
