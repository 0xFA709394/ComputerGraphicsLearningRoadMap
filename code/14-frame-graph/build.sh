#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! xcrun -f metal >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun -sdk macosx metal -c Shaders.metal -o Shaders.air
xcrun -sdk macosx metallib Shaders.air -o default.metallib
swiftc -O main.swift -o framegraph
rm -f Shaders.air
echo "构建完成 → ./framegraph"
