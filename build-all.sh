#!/bin/bash
#
# build-all.sh
#
# This bash script cross-compiles the StateDB project for multiple target platforms.
# It is designed for use on Linux, macOS, or Windows (with Git Bash or WSL).

# Exit immediately if a command exits with a non-zero status.
set -e

# Ensure the 'release' directory exists. If not, create it.
if [ ! -d "./release" ]; then
    echo "Creating 'release' directory..."
    mkdir -p "./release"
fi

echo -e "\n--- Starting StateDB multi-platform build ---"

# Build for Linux (x86_64)
echo -e "\n[1/4] Building for Linux (x86_64)..."
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSmall --prefix ./release/statedb-x86_64-linux

# Build for Windows (x86_64)
echo -e "\n[2/4] Building for Windows (x86_64)..."
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall --prefix ./release/statedb-x86_64-windows

# Build for macOS (x86_64)
echo -e "\n[3/4] Building for macOS (x86_64)..."
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSmall --prefix ./release/statedb-x86_64-macos

# Build for macOS (aarch64 - Apple Silicon)
echo -e "\n[4/4] Building for macOS (aarch64)..."
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall --prefix ./release/statedb-aarch64-macos

echo -e "\n--- All builds completed successfully! ---"
echo "Artifacts are located in the './release' directory."
