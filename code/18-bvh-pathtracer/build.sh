#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
clang++ -std=c++17 -O2 -Wall main.cpp -o bvhpt
echo "构建完成 → ./bvhpt [宽 高 spp] (默认 480 360 96)"
