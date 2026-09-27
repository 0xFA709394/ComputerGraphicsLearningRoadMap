#!/bin/bash
# 编译并链接 03-obj-viewer（macOS）
set -euo pipefail
cd "$(dirname "$0")"
# CLT 无 Metal 工具链时回退到完整 Xcode(Xcode 26 起 Metal 编译器为独立下载组件)
if ! xcrun -f metal >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

xcrun -sdk macosx metal    -c Shaders.metal -o Shaders.air
xcrun -sdk macosx metallib Shaders.air      -o default.metallib
swiftc -O main.swift -o obj-viewer

rm -f Shaders.air
echo "构建完成 → ./obj-viewer"
