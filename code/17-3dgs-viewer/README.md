# 17 · 3DGS 最小查看器（ply 往返 · GPU 排序 · instanced splat）

docs/22（3DGS 实操）第 1~2 周的参考实现，docs/27 案例 D 的 MVD 骨架。链路全通：**合成高斯场景 → 写真实 3DGS .ply（17 字段二进制）→ 读回 → 每帧 ulong(key<<32|index) bitonic 排序 → gather 重建远→近实例缓冲 → instanced billboard + premultiplied alpha 混合**。空格开关排序看混合序错乱。

## 运行

```bash
./build.sh
./splat      # 空格: 开关排序; scene.ply 由程序生成
```

## v2 · EWA splatting 升级（各向异性真高斯）

练习清单第 1 项已落地——从圆形 splat 升级为**真各向异性高斯**：

| 步骤 | 实现 |
|---|---|
| 数据 | Splat 64B：pos + colorAlpha + scale.xyz(各向异性半轴) + rot(单位四元数) |
| ply | 21 字段真格式：scale_0..2 线性空间 + rot (w,x,y,z)——与真实训练输出同构 |
| 3D 协方差 | Σ = R·S·Sᵀ·Rᵀ（顶点着色器内：四元数→旋转矩阵→M=R·S→Σ=M·Mᵀ） |
| 2D 投影 | C = J·W·Σ·Wᵀ·Jᵀ（J = f/z 雅可比小角近似 + 0.3 低通核） |
| 椭圆 | 特征分解 → 主/次半轴 (l1,l2) + 主轴角 atan2(2cxy, cxx−cyy)/2 |
| 渲染 | 四角按椭圆旋转缩放的高斯核 α 衰减 |

场景同步升级：圆环面 splat **沿切向拉长**（scale 0.09/0.02/0.03 + 绕 y 旋转对齐）——真实 3DGS 重建出的"贴表面"形态。

**v2 踩坑实录（三连）**：
1. **结构体 stride 想当然**：Swift `SIMD3` 16 对齐 → 新 Splat 实际 stride 64B，手写 48B 截断 1/4 → 键/渲染全乱。修复：`MemoryLayout<Splat>.stride`（14 号 SIMD3 教训的变体——**这次连自己都会忘**）。
2. **NDC 偏移加在透视除法前**：`clip.xy += offset` 被 w≈5.5 缩成亚像素 → 全屏空。修复：先 `ndc = clip.xy/clip.w` 再加偏移、w 置 1。
3. **gather 的 nTotal 参数只在 /tmp harness 里加过、从未进仓库**：`keys[垃圾−1−gid]` 越界 → idx 恒定 → 全屏同一个 splat。回读 sortedBuf 发现 32768 个位置完全相同才暴露。教训：**"在验证器里试过的修复"≠"已修复"——以仓库代码为准**（第三次栽在验证器同步上）。

## v1 要点（基础链路）

| 知识点 | 位置 |
|---|---|
| **3DGS ply 格式**：binary_little_endian、f_dc→颜色的 `(c-0.5)/0.2820948` 逆映射、opacity 的 sigmoid/logit 往返 | `writePLY/readPLY` |
| **排索引不排负载**：key 与原 index 打包进一个 ulong，比较/交换成本减半（16 号练习 3 的落地）| `makeKeys` |
| IEEE754 正数的位模式**保序映射**（float→uint 单调）| 同上 |
| **gather pass**：升序键倒序取 → 远→近的混合序（alpha 合成的正确性根基）| `gather` |
| instanced billboard：`[[instance_id]]` + 顶点着色器自生成四角，屏幕半径 ∝ scale/w | `splatVert` |
| premultiplied alpha 混合（one / oneMinusSourceAlpha）| PSO |
| SH 仅 DC 项、各向同性 scale 的**诚实简化**（真版差距见练习）| 全局 |

**headless 验证**：ply 往返 32768/32768；键单调违例 0/32767；**EWA 各向异性圆环成像**（非背景 24.5%、彩色 12.8%——拉长椭球沿切向排列的贴表面形态）。
**开发实录踩坑**：reader 初版 stride 按 21 字段算（真实 3DGS 含 f_rest×45 时才是 62 字段），与 writer 的 17 字段不符 → 读回 26526 个错位 splats——**资产格式的读写两侧必须共享同一定义**（常量/代码生成），本仓库用"往返计数断言"兜底。

## 与真 3DGS viewer 的差距（练习路线，对照 docs/22 与 docs/27 案例 D）

1. ~~2D 协方差投影~~ **已落地（v2 EWA）**；进阶：完整 J 包含相机朝向的 pitch/roll 项 + AABB tile 剔除
2. f_rest 高阶 SH（视角相关颜色）
3. 键量化 uint16 + GPU radix（16 号练习 2）
4. 真实训练数据：`gsplat`/官方推理输出直接喂本 loader
5. ARKit 摆放 + EDR（docs/27 案例 D 第 7~10 周）
