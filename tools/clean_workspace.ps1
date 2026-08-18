# Remove regenerable build output and caches from the working tree.
# Nothing here is tracked by git, and nothing here holds data: the venv,
# server\data (chat.db), server\media, and the secrets are left alone.
#
# Usage (from anywhere):
#   powershell -ExecutionPolicy Bypass -File tools\clean_workspace.ps1
#   powershell -ExecutionPolicy Bypass -File tools\clean_workspace.ps1 -DeepFlutter
#
#   -DeepFlutter also drops flutter_app\.dart_tool, which forces a
#   `flutter pub get` and a slower first build afterwards.

param([switch]$DeepFlutter)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

$targets = @(
    "flutter_app\build",
    "server\build",
    "server\dist",
    "server\.pytest_cache",
    ".pytest_cache",
    "tools\.pytest_cache",
    "server-update.zip"
)
if ($DeepFlutter) { $targets += "flutter_app\.dart_tool" }

# The Gradle daemon keeps lint jars under flutter_app\build open, which would
# make the delete fail halfway through.
$gradlew = Join-Path $Root "flutter_app\android\gradlew.bat"
if ((Test-Path $gradlew) -and (Test-Path (Join-Path $Root "flutter_app\build"))) {
    Push-Location (Join-Path $Root "flutter_app\android")
    & $gradlew --stop *> $null
    Pop-Location
}

$freed = 0
foreach ($rel in $targets) {
    $path = Join-Path $Root $rel
    if (-not (Test-Path $path)) { continue }
    $size = (Get-ChildItem $path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $path) {
        Start-Sleep -Seconds 3   # a build tool may still be letting go
        Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $path) {
        Write-Warning "$rel is partly in use; close editors/builds and re-run."
        continue
    }
    $freed += [int64]$size
    Write-Host ("removed {0,-32} {1,8:N1} MB" -f $rel, ($size / 1MB))
}

# Stray bytecode caches anywhere outside the venv.
Get-ChildItem $Root -Recurse -Force -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue |
    Where-Object FullName -notlike "*\.venv\*" |
    ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "removed $($_.FullName.Substring($Root.Length + 1))"
    }

Write-Host ("==> Freed about {0:N0} MB. Kept: .venv, server\data, server\media, secrets, releases\." -f ($freed / 1MB)) -ForegroundColor Green
