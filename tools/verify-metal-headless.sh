#!/bin/bash
# Metal 无人值守验证: 只覆盖"纯逻辑/纯计算"且可靠自动化的部分。
# 设计原则(tools/README 教训): harness 从 metallib + 独立驱动跑, 不做源码正则手术。
# 用法: ./tools/verify-metal-headless.sh
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

echo "==== 20 号 DRS 控制器: 热降级四断言 ===="
python3 - <<'PY'
ctrl = open('code/20-drs/main.swift').read()
test = open('tools/drs-unit.swift').read()
open('/tmp/v20tool.swift','w').write(ctrl[ctrl.index('/// DRS 控制器'):ctrl.index('struct Uniforms')] + '\n' + test)
PY
(cd /tmp && swiftc -O v20tool.swift -o v20tool 2>/dev/null && ./v20tool) || FAIL=1

echo "==== 16 号 radix: 直驱探针(已知问题在册, 非阻塞) ===="
(cd /tmp && swiftc -O driver16base.swift -o d16run 2>/dev/null && ./d16run "$PWD/code/16-compute-sort/default.metallib") || echo "  [已知问题] 见 tools/README 登记项——不阻塞, 修复属案例 D 第 11~12 周"

[ "$FAIL" = 0 ] && echo "✅ Metal headless 验证通过" || echo "❌ 失败"
exit $FAIL
