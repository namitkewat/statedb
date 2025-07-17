# build-all.ps1
#
# This PowerShell script cross-compiles the StateDB project for multiple target platforms.
# It is the Windows-compatible equivalent of the bash build script.

# Ensure the 'release' directory exists. If not, create it.
if (-not (Test-Path -Path "./release" -PathType Container)) {
    Write-Host "Creating 'release' directory..."
    New-Item -ItemType Directory -Path "./release" | Out-Null
}

Write-Host "--- Starting StateDB multi-platform build ---" -ForegroundColor Green

# Build for Linux (x86_64)
Write-Host "`n[1/4] Building for Linux (x86_64)..." -ForegroundColor Cyan
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSmall --prefix ./release/statedb-x86_64-linux
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed!" -ForegroundColor Red; exit 1 }

# Build for Windows (x86_64)
Write-Host "`n[2/4] Building for Windows (x86_64)..." -ForegroundColor Cyan
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall --prefix ./release/statedb-x86_64-windows
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed!" -ForegroundColor Red; exit 1 }

# Build for macOS (x86_64)
Write-Host "`n[3/4] Building for macOS (x86_64)..." -ForegroundColor Cyan
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSmall --prefix ./release/statedb-x86_64-macos
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed!" -ForegroundColor Red; exit 1 }

# Build for macOS (aarch64 - Apple Silicon)
Write-Host "`n[4/4] Building for macOS (aarch64)..." -ForegroundColor Cyan
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall --prefix ./release/statedb-aarch64-macos
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed!" -ForegroundColor Red; exit 1 }

Write-Host "`n--- All builds completed successfully! ---" -ForegroundColor Green
Write-Host "Artifacts are located in the './release' directory."
