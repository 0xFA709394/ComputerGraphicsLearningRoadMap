#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
clang++ -std=c++17 -O2 -Wall main.cpp -o rasterizer
echo "构建完成 → ./rasterizer (输出 out.tga)"
