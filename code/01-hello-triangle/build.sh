#!/bin/bash
# 编译并链接 01-hello-triangle（macOS）
set -euo pipefail
cd "$(dirname "$0")"
# CLT 无 Metal 工具链时回退到完整 Xcode(Xcode 26 起 Metal 编译器为独立下载组件)
if ! xcrun -f metal >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# 1) 着色器: .metal -> .air -> default.metallib
xcrun -sdk macosx metal      -c Shaders.metal -o Shaders.air
xcrun -sdk macosx metallib   Shaders.air      -o default.metallib

# 2) Swift 主程序（可执行文件从自身目录加载 metallib）
swiftc -O main.swift -o hello-triangle

rm -f Shaders.air
echo "构建完成 → ./hello-triangle"
