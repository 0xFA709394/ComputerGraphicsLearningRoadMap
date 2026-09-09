# 06 · Offscreen + Post-Processing（HDR 离屏链 + Bloom + ACES）

对应 `docs/02 §10`（RenderPass 组织）与 `docs/09 §5`（后处理链）。五条 pass：场景(HDR) → 亮部提取 → 高斯 H → 高斯 V → 合成输出。

## 运行

```bash
./build.sh
./postfx       # 旋转球 + 蓝色发光带 + 高光 bloom 光晕
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| 手动创建 RT（`rgba16Float` HDR + `depth32Float`，usage/renderTarget/shaderRead）| `recreateTargets` |
| **手工 RenderPassDescriptor**（脱离 MTKView 提供的 desc）与 load/store action 纪律 | `passDescriptor` + 各 pass |
| 全屏三角形技巧（3 顶点覆盖屏幕，免顶点缓冲）| `fullscreenVert` |
| 分离高斯 ping-pong（方向 uniform 复用同一 PSO）| `blurFrag` + pass 3/4 |
| 半分辨率 bloom 链（带宽意识）| `bloomA/B` 半尺寸 |
| 线性 HDR 中间 → ACES + gamma 的唯一出口 | `compositeFrag` |

**观察点**：
- 发光带和高光周围有蓝色光晕（bloom），球体其余部分无异常发灰——说明中间链路全程线性
- 调窗口大小：目标自动重建（`drawableSizeWillChange`）
- 深度 pass `storeAction = .dontCare`——后处理不再读深度，不写回显存（07 章带宽纪律的实践）

## 练习

1. 把中间 `rgba16Float` 改成 `rgba8Unorm`（LDR）：发光带严重截断、bloom 变"灰色矩形"——亲手复现 09 章排障表
2. blur 迭代两轮（H→V→H→V）或改 dual-Kawase——观感/性能对比
3. 亮部阈值/knee 参数化（`constant float2 &params`），做成"滑杆调试"的第一步
4. 合成 pass 加 vignette + film grain（docs/17 §10），构成完整风格化链
