#!/bin/bash
# 全仓库可复现验证(本仓库方法论的可执行版):
#   1) C++ 示例: 构建+渲染+产物断言(TGA 统计/探针)
#   2) 纯逻辑单测(可注入控制器)
#   3) Metal 示例: 构建冒烟(真机 GUI 无法无人值守验证, 用 build-all.sh --run 人工触发)
# 用法: ./tools/verify-all.sh [--skip-metal]   (CI 用 --skip-metal: Metal 工具链在无人环境不可控)
set -uo pipefail
SKIP_METAL=no; [ "${1:-}" = "--skip-metal" ] && SKIP_METAL=yes
cd "$(dirname "$0")/.."
FAIL=0
step() { echo; echo "==== $1 ===="; }

step "09 软光栅器: 产物断言"
(cd code/09-software-rasterizer && ./build.sh >/dev/null && ./rasterizer) || FAIL=1
python3 tools/tga_stats.py code/09-software-rasterizer/out.tga --min-lit 40 \
  --probe 400,500,182,182,187,25 || FAIL=1

step "10 路径追踪器: 渲染断言(左红右绿)"
(cd code/10-path-tracer && ./build.sh >/dev/null && ./pathtracer 200 150 32) || FAIL=1
python3 tools/tga_stats.py code/10-path-tracer/out.tga --min-lit 20 \
  --probe 40,75,150,40,35,90 || FAIL=1

step "18 BVH 路径追踪: 加速比 >= 50x"
(cd code/18-bvh-pathtracer && ./build.sh >/dev/null && ./bvhpt 160 120 16 | tee /tmp/bvh_out.txt) || FAIL=1
grep -Eo '加速 [0-9.]+x' /tmp/bvh_out.txt | awk '{v=$2+0; if (v<50) {print "FAIL 加速比", v; exit 1} print "OK", $0}' || FAIL=1

step "20 DRS 控制器: 降档/升档/抗抖动单测"
cat > /tmp/drs_unit_v.swift <<'SWIFT'
import Foundation
var drs = DRSController(budgetMs: 16.6)
for _ in 0..<40 { drs.update(frameMs: 33) }
let lowOK = drs.scale == 0.5
for _ in 0..<200 { drs.update(frameMs: 5) }
let highOK = drs.scale == 1.0
print("降档到0.5: \(lowOK)  升档到1.0: \(highOK)")
exit(lowOK && highOK ? 0 : 1)
SWIFT
python3 - <<'PY'
ctrl = open('code/20-drs/main.swift').read()
open('/tmp/drs_full_v.swift','w').write(ctrl[ctrl.index('/// DRS 控制器'):ctrl.index('struct Uniforms')] + open('/tmp/drs_unit_v.swift').read())
PY
swiftc -O /tmp/drs_full_v.swift -o /tmp/drs_full_v && /tmp/drs_full_v || FAIL=1

if [ "$SKIP_METAL" = no ]; then
    step "Metal 示例: 全量构建"
    (cd code && ./build-all.sh) || FAIL=1
fi

echo
[ "$FAIL" = 0 ] && echo "✅ 全部验证通过" || echo "❌ 存在失败项"
exit $FAIL
