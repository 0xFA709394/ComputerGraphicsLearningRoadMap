#!/bin/bash
# 一键构建全部示例（各目录自带 build.sh 则调用之）
# ./build-all.sh          只构建
# ./build-all.sh --run    构建后每个示例冒烟运行 4 秒（GUI 会短暂弹窗; CLI 工具正常退出也算通过）
set -uo pipefail
cd "$(dirname "$0")"
RUN=no; [ "${1:-}" = "--run" ] && RUN=yes
FAIL=0
for d in [0-9]*/; do
  d="${d%/}"
  echo "==> $d"
  if [ ! -x "$d/build.sh" ]; then echo "  [skip] 无 build.sh"; continue; fi
  (cd "$d" && ./build.sh) || { echo "  [FAIL] $d"; FAIL=1; continue; }
  if [ "$RUN" = yes ]; then
    BIN=$(ls -t "$d" | while read -r f; do [ -x "$d/$f" ] && [ -f "$d/$f" ] && echo "$f" && break; done)
    [ -z "$BIN" ] && continue
    (cd "$d" && "./$BIN" >/dev/null 2>&1) & PID=$!
    sleep 4
    if kill -0 $PID 2>/dev/null; then echo "  [run-ok] $BIN (GUI)"; kill $PID 2>/dev/null; wait $PID 2>/dev/null
    elif wait $PID; then echo "  [run-ok] $BIN (CLI 正常退出)"
    else echo "  [run-died] $BIN"; FAIL=1; fi
  fi
done
[ "$FAIL" = 0 ] && echo "全部通过" || echo "存在失败项"
exit $FAIL
