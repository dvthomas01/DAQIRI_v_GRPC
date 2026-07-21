# sync_to_spark.ps1 — Copy DAQIRI_GPU project files to DGX Spark.
# Run from anywhere: .\scripts\sync_to_spark.ps1
# Requires OpenSSH (comes with Windows 10 1809+) or WSL for rsync.
#
# Usage:
#   .\scripts\sync_to_spark.ps1
#   .\scripts\sync_to_spark.ps1 -SparkUser nitest -SparkHost 10.1.30.230
param(
    [string]$SparkUser   = "nitest",
    [string]$SparkHost   = "10.1.30.230",
    [string]$RemotePath  = "~/daqiri_gpu"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

Write-Host "=== Syncing to ${SparkUser}@${SparkHost}:${RemotePath} ===" -ForegroundColor Cyan
Write-Host "Local: $ProjectRoot"
Write-Host ""

# Prefer rsync via WSL (handles excludes cleanly); fall back to scp.
$wsl = Get-Command wsl -ErrorAction SilentlyContinue

if ($wsl) {
    Write-Host "Using rsync via WSL..." -ForegroundColor Yellow
    # Convert Windows path to WSL path
    $wslPath = & wsl wslpath ($ProjectRoot.Replace('\', '/'))
    & wsl rsync -av --progress `
        --exclude="build/" `
        --exclude="data/" `
        --exclude=".git/" `
        "${wslPath}/" `
        "${SparkUser}@${SparkHost}:${RemotePath}/"
} else {
    Write-Host "WSL not found — using scp (no exclude support; build/ may transfer)." -ForegroundColor Yellow
    # scp the source directories individually to skip build/ and data/
    foreach ($dir in @("common", "fft", "daqiri", "grpc_direct", "scripts")) {
        $localDir = Join-Path $ProjectRoot $dir
        if (Test-Path $localDir) {
            Write-Host "  Copying $dir/ ..."
            & scp -r $localDir "${SparkUser}@${SparkHost}:${RemotePath}/"
        }
    }
    # Top-level files
    foreach ($file in @("CMakeLists.txt", "ARCHITECTURE.md", "PROGRESS.md",
                         "SHORTTERM_CONTEXT.md", "LONGTERM_CONTEXT.md")) {
        $localFile = Join-Path $ProjectRoot $file
        if (Test-Path $localFile) {
            Write-Host "  Copying $file ..."
            & scp $localFile "${SparkUser}@${SparkHost}:${RemotePath}/"
        }
    }
}

Write-Host ""
Write-Host "Sync complete." -ForegroundColor Green
Write-Host ""
Write-Host "Next — SSH to Spark and build:"
Write-Host "  ssh ${SparkUser}@${SparkHost}"
Write-Host "  cd ${RemotePath} && bash scripts/build.sh"
Write-Host ""
Write-Host "Run FFT validation (M1):"
Write-Host "  ./build/fft/fft_validate"
