#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
xcrun -sdk macosx metal -c Shaders.metal -o Shaders.air
xcrun -sdk macosx metallib Shaders.air -o default.metallib
swiftc -O main.swift -o postfx
rm -f Shaders.air
echo "构建完成 → ./postfx"
