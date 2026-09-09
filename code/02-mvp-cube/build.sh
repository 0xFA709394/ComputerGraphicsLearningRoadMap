#!/bin/bash
# 编译并链接 02-mvp-cube（macOS）
set -euo pipefail
cd "$(dirname "$0")"

xcrun -sdk macosx metal    -c Shaders.metal -o Shaders.air
xcrun -sdk macosx metallib Shaders.air      -o default.metallib
swiftc -O main.swift -o mvp-cube

rm -f Shaders.air
echo "构建完成 → ./mvp-cube"
