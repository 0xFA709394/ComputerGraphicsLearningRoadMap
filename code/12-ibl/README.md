# 12 · IBL 基于图像的光照（split-sum 三件套 + PBR 球阵）

README 阶段 4「必须亲手实现」清单的最后一块：**IBL 环境贴图预滤波 + split-sum 近似 + HDR 环境加载**（此前 8 项已全部落地）。对应 `docs/03 §IBL split-sum`。零资产：HDR 环境图由 CPU 程序化生成（天空渐变 + 太阳 + 两条彩色带光，摄影棚感）。

## 运行

```bash
./build.sh
./ibl
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| **程序化 HDR 环境**（rgba16Float 立方体贴图，CPU 逐纹素生成）| `envRadiance()` |
| 立方体面基向量约定（CPU 写入与 GPU 采样共用一张表，方向自洽）| `FACE_BASIS` |
| **irradiance 图**：余弦半球离散卷积（cosθ·sinθ 加权 × π/N，docs/03 §辐照度）| `irradianceFS` |
| **GGX 预滤波图**：重要性采样 128 样本 + 能量权重（w = NoL/pdf），5 级 mip 对应 roughness 0→1 | `prefilterFS` |
| **BRDF LUT**：F0=1 的 Fresnel 积分 → (scale, bias)，rg32Float | `brdfLutFS` |
| **split-sum 组装**：`kD·albedo·E + prefiltered·(F0·scale + bias)` | `sceneFrag` |
| 每面/每 mip 离屏渲染（立方体切片视图复用 11 的 descriptor API）| `precomputeIBL()` |
| 初始化时一次烤制（运行时可改异步/热更新）| 同上 |
| 背景天空穹顶（复用球网格 + 剔除正面，从内部按方向采样环境）| `bgVert/bgFrag` |
| ACES + gamma 输出（docs/09）| `sceneFrag` |

**开发实录踩坑**：
1. 同一 render pass 描述符开两个 encoder，第二个的 `loadAction = .clear` 把先画的天空整体擦掉——**loadAction 是逐 encoder 生效的**，第二个 pass 必须改 `.load`（或合成到 MTKView 时用 drawable 层叠）。
2. 天空穹顶最初没设剔除：深度 `.always` + 不写深度 + 内外两面都画 → 每个像素"前向/背向"环境采样随机混叠，画面出现噪点碎斑。相机在网格内部时**必须剔除朝外的正面**。

## 观察点与练习

- 观察：25 球矩阵（列 = metallic 0→1，行 = roughness 0.05→0.95）——同一环境下从"亮红塑料"到"镜面金属反射天空"的连续过渡；顶行光滑球里有太阳的小亮点；底行粗糙球是均匀的辐照度渐变。
1. 把太阳强度 ×4（envRadiance 与 sunDir.w 同步）：注意 HDR 溢出与 ACES 的压缩行为
2. 预滤波 mip 级数 5→2：粗糙球出现"块状反射"——分辨率与 roughness 档位的权衡
3. irradiance 卷积步长 ×4：低频差异肉眼几乎不可见——理解"辐照度是超低频信号"
4. 换真实 HDRI：`.hdr` equirect → 立方体的转换自己写一遍（docs/04 §cubemap）
5. 加旋转环境（每帧重新预滤波太贵 → 用 3×3 旋转采样方向代替，工业做法）
6. diffuse 改 SH9 存储（内存 32×6 面 → 9 系数）——docs/11 §2.1 探针的迷你版

## 里程碑状态

至此 README 阶段 4「必须亲手实现的模块」九项全部落地（01~08、12），外加阶段 3 验收对（09/10）与 CSM（11）。下一步只剩 18 章蓝图的综合件：TAA（13）与 Mini-Engine。
