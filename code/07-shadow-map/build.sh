#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
xcrun -sdk macosx metal -c Shaders.metal -o Shaders.air
xcrun -sdk macosx metallib Shaders.air -o default.metallib
swiftc -O main.swift -o shadow-map
rm -f Shaders.air
echo "构建完成 → ./shadow-map"
