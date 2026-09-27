# 08 · Compute Shader 粒子系统（26 万粒子 · 点精灵 · additive）

对应 `docs/07 §6`（Compute 模式库）与扩展篇 C（GPU 粒子系统完整结构）的简化单 pass 版，及 `docs/02`（同一 command buffer 内 encoder 顺序 = 隐式同步）。软化引力 + 半隐式欧拉驱动的"星系"：compute kernel 每粒子一线程更新，点精灵加色渲染，速度映射颜色。

## 运行

```bash
./build.sh
./particles
```

> Xcode 26 起 Metal 编译器是独立下载组件：若 `metal` 不存在，先 `xcodebuild -downloadComponent MetalToolchain`。build.sh 已做 CLT→Xcode 自动回退。

## 本例要点

| 知识点 | 位置 |
|---|---|
| **compute 管线**（`makeComputePipelineState`，无顶点/片元/附件状态）| `computePSO` 构造 |
| 每粒子一线程：`thread_position_in_grid` + 越界 guard | `particleUpdate` |
| 256 线程/组 × 1024 组；网格向上取整分派 | `dispatchThreadgroups` |
| 半隐式欧拉 + **帧率无关阻尼** `exp(−drag·dt)`（docs/07 扩展 C 原句）| `particleUpdate` |
| 软化引力 `1/r²`（+ε 防奇点）、`rsqrt` | 同上 |
| 超界/NaN → hash 随机重生（球面均匀采样 (z,φ) 法）| 同上 |
| 点精灵：`[[point_size]]` 1/w 透视衰减、`[[point_coord]]` 高斯光斑 | `particleVert/Frag` |
| **additive 混合**（one/one）、无深度附件（粒子 = overdraw 重灾区，docs/07 §7.2）| `renderPSO` |
| 速度→颜色 = 调试视图思想（docs/17）| `particleFrag` |
| encoder 顺序 = 隐式同步：compute 先于 render，无需 fence/event（跨 command buffer/队列才需要，docs/07 §9）| `draw` |

**开发实录踩坑（本机 macOS 26 / Apple GPU 实测）**：

1. `metal` 编译器不在 CommandLineTools 里，Xcode 26 起还需 `xcodebuild -downloadComponent MetalToolchain`（688 MB）——构建脚本的跨机器鲁棒性要考虑工具链分家。
2. `makeBuffer(bytes:options:.storageModePrivate)` **必现 SIGSEGV**（崩溃栈：`AGXG16GFamilyDevice newBufferWithBytes` 内部 memmove）：.private 初值上传的 staging 路径有驱动 bug。教训：统一内存机器上 shared + "创建后 CPU 不再触碰"纪律即可表达 GPU 私有意图，别为语义正确性引入驱动级崩溃。
3. 新 SDK 把 `sourceRGBBlendFunction` 等四个混合属性**改名**为 `*BlendFactor`——旧教程代码直接抄会编译错。

## 观察点与练习

- 观察：核心因 additive + LDR 过曝为白（正是练习 7 的入口）；速度越快越白；吸引子拖着彗尾游走。
1. drag 0.55 → 0.05 / 2.0：云从"蒸发"到"坍缩"的相变，理解阻尼项在积分里的作用
2. `PARTICLE_COUNT` ×4 → 100 万：观察帧时间变化（此 workload 偏带宽，对照 docs/07 §3 内存层级）
3. 固定 `dt=1/60` vs 真实 dt：ProMotion 120Hz 机器上运动速度差一倍——帧率无关性为什么要用 `exp(−drag·dt)` 而不是乘常数
4. 把粒子数改成非 256 倍数并去掉 guard：越界写坏紧邻内存，复现"为什么 guard 必须有"
5. `Particle` 压缩：w 分量利用起来 / half4 存储，32B→16B 带宽减半（docs/07 扩展 E 半精度清单）
6. 升级为 docs/07 扩展 C 完整结构：alive 标志 + scan 压缩 + indirect draw（GPU-driven 最小闭环）
7. 换 HDR 管线：`colorPixelFormat = .rgba16Float` + tone map（docs/09），核心不再硬过曝
8. 用 `dispatchThreads()` 非均匀分派替代手写向上取整

## 通往 Mini-Engine

本例收官 README 阶段 4「必须亲手实现」清单的最后一块（Compute Shader）。下一步按 18 章蓝图推进：粒子挂进 frame graph（M2）、CSM/TAA（M3），并把本例的调试视图升级为引擎的性能面板。
