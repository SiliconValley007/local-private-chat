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

# Windows keeps handles on freshly written APKs (antivirus, Explorer preview),
# and the next Gradle run then dies with "Unable to delete directory ... apk\release"
# after the slow part of the build has already succeeded. One retry costs a couple
# of minutes; losing a half-hour build to a file lock costs far more.
function Invoke-FlutterBuild {
    param([string[]]$Arguments, [int]$Attempts = 2)
    $what = "flutter build " + ($Arguments -join " ")
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        & flutter build @Arguments
        if ($LASTEXITCODE -eq 0) { return }
        if ($attempt -eq $Attempts) { throw "$what failed with exit code $LASTEXITCODE" }
        Write-Host "    $what failed; releasing stale APK output and retrying..." -ForegroundColor Yellow
        Start-Sleep -Seconds 20
        Remove-Item (Join-Path $Root "flutter_app\build\app\outputs\apk\release") `
            -Recurse -Force -ErrorAction SilentlyContinue
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
    Invoke-FlutterBuild @("apk", "--release", "--split-per-abi")
    Invoke-FlutterBuild @("apk", "--release")
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
    Write-Host "==> Building single-file Windows server with PyInstaller..." -ForegroundColor Cyan
    $server = Join-Path $Root "server"
    $venvPython = Join-Path $server ".venv\Scripts\python.exe"
    if (-not (Test-Path $venvPython)) {
        throw "Create server\.venv first: python -m venv .venv && .\.venv\Scripts\activate && pip install -r requirements.txt"
    }
    & $venvPython -m pip install -q pyinstaller
    Push-Location $server
    & $venvPython -m PyInstaller --noconfirm --clean localchat.spec
    Assert-LastExitCode "PyInstaller"
    Pop-Location
    $built = Join-Path $server "dist\LocalChatServer.exe"
    Assert-Fresh $built
    Write-Host "==> Verifying frozen server startup and HTTP..." -ForegroundColor Cyan
    & $venvPython (Join-Path $Root "tools\verify_windows_package.py") $built
    Assert-LastExitCode "Windows server package verification"

    $zip = Join-Path $Out "LocalChatServer-windows-x64.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    $stage = Join-Path $env:TEMP ("localchat-windows-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        Copy-Item $built (Join-Path $stage "LocalChatServer.exe") -Force
        @"
LOCAL CHAT SERVER - START HERE
================================

1. Extract this entire ZIP to a normal folder first.
2. Double-click LocalChatServer.exe.
3. Keep the console window open. It prints the address for the phone and logs
   every HTTP request. Closing that window stops the server.
4. Approve the Windows permission prompt on the first run. Windows blocks
   incoming connections by default, so until that rule exists your phones will
   say "Chat server is not running" even though this window looks healthy.

If you missed the prompt, or the console says the firewall is blocking the
port, run this once and approve it:

    LocalChatServer.exe allow-firewall

That allows TCP 8000 from Tailscale (100.64.0.0/10) and your local network
only - never the public internet.

Do not run the EXE while it is still inside the ZIP. The server keeps data,
media and its secret beside the EXE so they survive updates.

Local health check: http://127.0.0.1:8000/api/health
API documentation:  http://127.0.0.1:8000/docs
"@ | Set-Content (Join-Path $stage "START_HERE.txt") -Encoding ASCII
        # tar avoids Compress-Archive file locks right after PyInstaller finishes.
        tar -a -cf $zip -C $stage .
        Assert-LastExitCode "tar (windows server zip)"
    }
    finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "    -> releases\LocalChatServer-windows-x64.zip"
    Write-Host "    Extract first, then double-click LocalChatServer.exe. Data stays next to the exe."
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
        # Every top-level module the server imports has to be here. Shipping
        # run.py without one of them leaves the operator with a server that dies
        # on ModuleNotFoundError; tests/test_unit_update_pack.py enforces the list.
        foreach ($f in @("run.py", "reset_password.py", "set_admin.py", "firewall.py",
                         "requirements.txt",
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
