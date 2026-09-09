#!/bin/bash
# 编译并链接 03-obj-viewer（macOS）
set -euo pipefail
cd "$(dirname "$0")"

xcrun -sdk macosx metal    -c Shaders.metal -o Shaders.air
xcrun -sdk macosx metallib Shaders.air      -o default.metallib
swiftc -O main.swift -o obj-viewer

rm -f Shaders.air
echo "构建完成 → ./obj-viewer"
