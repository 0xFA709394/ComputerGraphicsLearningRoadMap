#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# CommandLineTools 不含 Metal 工具链; 且 Xcode 26 起需 `xcodebuild -downloadComponent MetalToolchain`
if ! xcrun -f metal >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun -sdk macosx metal -c Shaders.metal -o Shaders.air
xcrun -sdk macosx metallib Shaders.air -o default.metallib
swiftc -O main.swift -o particles
rm -f Shaders.air
echo "构建完成 → ./particles"
