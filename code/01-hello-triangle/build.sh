#!/bin/bash
# 编译并链接 01-hello-triangle（macOS）
set -euo pipefail
cd "$(dirname "$0")"

# 1) 着色器: .metal -> .air -> default.metallib
xcrun -sdk macosx metal      -c Shaders.metal -o Shaders.air
xcrun -sdk macosx metallib   Shaders.air      -o default.metallib

# 2) Swift 主程序（可执行文件从自身目录加载 metallib）
swiftc -O main.swift -o hello-triangle

rm -f Shaders.air
echo "构建完成 → ./hello-triangle"
